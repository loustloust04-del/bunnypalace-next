import { test, expect, beforeEach } from "bun:test"
import { mkdtempSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
import {
  initAskUser, handleHookEvent, resolveOnReply, clearForSession, getPending, pendingList,
  askUiAlive, buildKeySequence, formatAnswers, driveAnswer, markDriven, _resetForTest,
  type AskUserQuestionSpec, type AskAnswer, type PendingAskUser, type AskUserIO, type KeyStep,
} from "./askuser.ts"

const Q_SINGLE: AskUserQuestionSpec = {
  question: "超能力选哪个?",
  options: [{ label: "读心" }, { label: "暂停" }, { label: "口袋" }],
  multiSelect: false,
}
const Q_MULTI: AskUserQuestionSpec = {
  question: "今晚吃什么？",
  options: [{ label: "火锅" }, { label: "寿司" }, { label: "披萨" }],
  multiSelect: true,
}

let frames: any[] = []
beforeEach(() => {
  _resetForTest()
  frames = []
  initAskUser(mkdtempSync(join(tmpdir(), "askuser-")), (json) => frames.push(JSON.parse(json)))
})

function preBody(toolUseId = "tu1", questions: AskUserQuestionSpec[] = [Q_SINGLE]) {
  return { event: "pre", session_id: "sid1", tool_use_id: toolUseId, chat_id: "chat1", questions }
}

// ── hook 事件 ──

test("pre 记账 + 广播题面帧；post 权威收账 + resolved 帧", () => {
  const r = handleHookEvent(preBody(), () => "mp-cc-9")
  expect(r.ok).toBe(true)
  expect(getPending("tu1")?.sessionName).toBe("mp-cc-9")
  expect(frames[0].type).toBe("ask_user_question")
  expect(frames[0].chat_id).toBe("chat1")
  expect(frames[0].questions.length).toBe(1)

  const r2 = handleHookEvent({ event: "post", tool_use_id: "tu1", chat_id: "chat1", answers: { "超能力选哪个?": "口袋" } }, () => undefined)
  expect(r2.ok).toBe(true)
  expect(getPending("tu1")).toBeUndefined()
  expect(frames[1].type).toBe("ask_user_resolved")
  expect(frames[1].answers["超能力选哪个?"]).toBe("口袋")
  expect(frames[1].declined).toBeUndefined()
})

test("post 无 pending 幂等；非法 body 拒", () => {
  expect(handleHookEvent({ event: "post", tool_use_id: "nope", chat_id: "c" }, () => undefined).ok).toBe(true)
  expect(handleHookEvent({ event: "pre", tool_use_id: "", chat_id: "c" }, () => undefined).ok).toBe(false)
  expect(handleHookEvent({ event: "pre", tool_use_id: "t", chat_id: "c", questions: [] }, () => undefined).ok).toBe(false)
  expect(handleHookEvent({ event: "wat", tool_use_id: "t", chat_id: "c" }, () => undefined).ok).toBe(false)
})

test("pending 持久化跨 init", () => {
  const dir = mkdtempSync(join(tmpdir(), "askuser-"))
  initAskUser(dir, () => {})
  handleHookEvent(preBody(), () => "mp-cc-9")
  _resetForTest()
  initAskUser(dir, () => {})
  expect(getPending("tu1")?.chatId).toBe("chat1")
})

// ── 清理钩子 ──

test("resolveOnReply：未驱动=declined，驱动过=用暂存答案", () => {
  handleHookEvent(preBody("tu1"), () => "s")
  handleHookEvent(preBody("tu2"), () => "s")
  markDriven("tu2", { "超能力选哪个?": "暂停" })
  frames = []
  resolveOnReply("chat1")
  expect(pendingList().length).toBe(0)
  const declined = frames.find(f => f.tool_use_id === "tu1")
  const driven = frames.find(f => f.tool_use_id === "tu2")
  expect(declined.declined).toBe(true)
  expect(driven.answers["超能力选哪个?"]).toBe("暂停")
})

test("resolveOnReply 只清同 chat", () => {
  handleHookEvent(preBody("tu1"), () => "s")
  handleHookEvent({ ...preBody("tu2"), chat_id: "other" }, () => "s")
  resolveOnReply("chat1")
  expect(getPending("tu1")).toBeUndefined()
  expect(getPending("tu2")).toBeDefined()
})

test("clearForSession：declined 收账", () => {
  handleHookEvent(preBody(), () => "mp-cc-9")
  frames = []
  clearForSession("mp-cc-9", "respawn")
  expect(pendingList().length).toBe(0)
  expect(frames[0].declined).toBe(true)
})

// ── 存活校验 ──

test("askUiAlive：结构锚=题面前缀+编号行（不锚页脚）", () => {
  const alive = "超能力选哪个?\n❯ 1. 读心\n  2. 暂停\nEnter to select · Esc to cancel"
  expect(askUiAlive(alive, [Q_SINGLE])).toBe(true)
  expect(askUiAlive("随便什么输入框", [Q_SINGLE])).toBe(false)
  expect(askUiAlive("Esc to cancel", [Q_SINGLE])).toBe(false)          // 页脚在但结构不在
  expect(askUiAlive("超能力选哪个? 提一嘴而已", [Q_SINGLE])).toBe(false) // 题面在但无编号行
  // 题面折行也认（快照去空白比对）
  const wrapped = "超能力选\n哪个?\n❯ 1. 读心"
  expect(askUiAlive(wrapped, [Q_SINGLE])).toBe(true)
})

test("askUiAlive：52 列窄 pane 页脚被截断仍判活（2026-08-06 实案）", () => {
  // 多题长页脚在窄 pane 整段被省略号吃掉，只剩题面+选项
  const narrow = "←  ☐ 词义  ☐ 用法  ✔ Submit  →\n\nWhich word means \"to give up\"?\n\n❯ 1. abandon\n     放弃\n  2. absorb\n     吸收\n  Enter to select · Tab/Arrow keys to naviga…"
  const q = { question: "Which word means \"to give up\"?", options: [{ label: "abandon" }, { label: "absorb" }], multiSelect: false }
  expect(askUiAlive(narrow, [q, Q_MULTI])).toBe(true)
})

// ── 键序生成 ──

function kinds(steps: KeyStep[]): string[] {
  return steps.filter(s => s.kind !== "sleep").map(s => s.kind === "key" ? `key:${s.key}` : `${s.kind}:${(s as any).text}`)
}

test("单选=数字；单题无 Submit 步", () => {
  const steps = buildKeySequence([Q_SINGLE], [{ indices: [2] }])!
  expect(kinds(steps)).toEqual(["digit:3"])
})

test("多选=逐数字+Tab", () => {
  const steps = buildKeySequence([Q_MULTI], [{ indices: [0, 2] }])!
  expect(kinds(steps)).toEqual(["digit:1", "digit:3", "key:Tab"])
})

test("自由文本=Type something 行号+文本+Enter", () => {
  const steps = buildKeySequence([Q_SINGLE], [{ text: "既要又要" }])!
  expect(kinds(steps)).toEqual(["digit:4", "text:既要又要", "key:Enter"])
})

test("混合多题按序拼接", () => {
  const steps = buildKeySequence([Q_SINGLE, Q_MULTI], [{ indices: [0] }, { indices: [1] }])!
  expect(kinds(steps)).toEqual(["digit:1", "digit:2", "key:Tab"])
})

test("键序校验拒：长度不齐/越界/单选多答/空答案", () => {
  expect(buildKeySequence([Q_SINGLE], [])).toBeNull()
  expect(buildKeySequence([Q_SINGLE], [{ indices: [9] }])).toBeNull()
  expect(buildKeySequence([Q_SINGLE], [{ indices: [0, 1] }])).toBeNull()
  expect(buildKeySequence([Q_SINGLE], [{}])).toBeNull()
  expect(buildKeySequence([Q_SINGLE, Q_MULTI], [{ indices: [0] }, null as any])).toBeNull()
})

test("formatAnswers：多选逗号空格 join 与 CC 一致；文本原样", () => {
  const out = formatAnswers([Q_SINGLE, Q_MULTI], [{ text: "都不要" }, { indices: [0, 1] }])
  expect(out["超能力选哪个?"]).toBe("都不要")
  expect(out["今晚吃什么？"]).toBe("火锅, 寿司")
})

// ── 驱动 ──

function fakeIO(snapshots: string[]): { io: AskUserIO; sent: string[] } {
  const sent: string[] = []
  let i = 0
  return {
    sent,
    io: {
      sendLiteral: (t) => { sent.push(`lit:${t}`) },
      sendKey: (k) => { sent.push(`key:${k}`) },
      capturePane: () => snapshots[Math.min(i++, snapshots.length - 1)],
      sleep: () => {},
    },
  }
}

function mkPending(questions: AskUserQuestionSpec[] = [Q_SINGLE]): PendingAskUser {
  return { toolUseId: "tu", chatId: "c", sessionId: "s", sessionName: "mp-cc-9", questions, ts: 0 }
}

const ALIVE = "超能力选哪个?\n❯ 1. 读心\n  2. 暂停"
const ALIVE_MULTI = "今晚吃什么？\n❯ 1. [ ] 火锅\n  2. [ ] 寿司"
const REVIEW = "Review your answers\n1. Submit answers"   // 实测：Review 页没有 Esc to cancel 页脚
const GONE = "❯ 普通输入框"

test("驱动单选：卡收即 ok", async () => {
  const { io, sent } = fakeIO([ALIVE, GONE])
  const r = await driveAnswer(mkPending(), [{ indices: [1] }], false, io)
  expect(r.ok).toBe(true)
  expect(sent).toEqual(["lit:2"])
})

test("驱动多选：Review 页补 Submit '1'", async () => {
  const { io, sent } = fakeIO([ALIVE_MULTI, REVIEW, GONE])
  const r = await driveAnswer(mkPending([Q_MULTI]), [{ indices: [0, 1] }], false, io)
  expect(r.ok).toBe(true)
  expect(sent).toEqual(["lit:1", "lit:2", "key:Tab", "lit:1"])
})

test("skip=Esc", async () => {
  const { io, sent } = fakeIO([ALIVE])
  const r = await driveAnswer(mkPending(), null, true, io)
  expect(r.ok).toBe(true)
  expect(sent).toEqual(["key:Escape"])
})

test("卡不在=stale 不发键", async () => {
  const { io, sent } = fakeIO([GONE])
  const r = await driveAnswer(mkPending(), [{ indices: [0] }], false, io)
  expect(r.ok).toBe(false)
  expect(r.reason).toBe("ui_gone")
  expect(sent).toEqual([])
})

test("无 sessionName=no_session；非法答案=invalid_answers", async () => {
  const { io } = fakeIO([ALIVE])
  const p = mkPending(); (p as any).sessionName = undefined
  expect((await driveAnswer(p, [{ indices: [0] }], false, io)).reason).toBe("no_session")
  expect((await driveAnswer(mkPending(), [{}], false, io)).reason).toBe("invalid_answers")
})

test("Review 页卡死=submit_unconfirmed（重试 1 后放弃）", async () => {
  const { io, sent } = fakeIO([ALIVE_MULTI, REVIEW, REVIEW, REVIEW, REVIEW])
  const r = await driveAnswer(mkPending([Q_MULTI]), [{ indices: [0] }], false, io)
  expect(r.ok).toBe(false)
  expect(r.reason).toBe("submit_unconfirmed")
  expect(sent.filter(x => x === "lit:1").length).toBeGreaterThanOrEqual(2)   // digit 1 + submit 重试
})

test("提交后卡仍在=submit_unconfirmed", async () => {
  const { io } = fakeIO([ALIVE, ALIVE, ALIVE, ALIVE, ALIVE])
  const r = await driveAnswer(mkPending(), [{ indices: [0] }], false, io)
  expect(r.ok).toBe(false)
  expect(r.reason).toBe("submit_unconfirmed")
})
