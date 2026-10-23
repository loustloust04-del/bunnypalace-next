// K1 第 4b 步 · 审查 R1：送达核对的纯工具和状态账（不起 tmux；流程见 send-track.test.ts，真 tmux 见 hub-send.test.ts）
import { expect, test } from "bun:test"
import { appendFileSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { channelIds, findCodexRollout, hasMarker, locateEditArea, SendStatusBook, TranscriptScanner, transcriptCursor, userTextOfLine, withMarker } from "./send-verify"
import { TmuxUncertainError, waitTmuxWriteSettled, type WriteSettle } from "./tmux-control"

const TAG = `<channel source="memorypalace" chat_id="c-1" message_id="m-42" user="susu" ts="2026-10-11T00:00:00.000Z">你好 "q"</channel>`

test("channelIds：只认开头 memorypalace 标签的属性，带上 ts（第几次发送）", () => {
  expect(channelIds(TAG)).toEqual({ chatId: "c-1", messageId: "m-42", ts: "2026-10-11T00:00:00.000Z" })
  expect(channelIds(`正文里写 message_id="x"`)).toEqual({ chatId: undefined, messageId: undefined, ts: undefined })
})

test("withMarker（审查 R1-4）：app 消息用 message_id、agora 用 claim_token，原文不动；其余由 hub 生成注入 ID 写进开头标签末尾", () => {
  expect(withMarker(TAG)).toEqual({ text: TAG, marker: { text: `message_id="m-42"`, id: "m-42" } })
  const agora = `You have a durable mention.\n<agora_claim>\n{"room_id":"r","mention_id":"mn-1","claim_token":"tok-9","kind":"mention"}\n</agora_claim>`
  expect(withMarker(agora)).toEqual({ text: agora, marker: { text: `"claim_token":"tok-9"`, id: "tok-9" } })
  // 同一段固定说明 + 不同 claim：记号不同（原来的「前 200 字」会撞）
  expect(withMarker(agora.replace("tok-9", "tok-10")).marker.id).toBe("tok-10")
  const keep = `<channel source="cache-keepalive">[缓存保暖 ping] 只回 ok</channel>`
  const k = withMarker(keep, () => "inj-1")
  expect(k.text).toBe(`<channel source="cache-keepalive" inject_id="inj-1">[缓存保暖 ping] 只回 ok</channel>`)
  expect(k.marker).toEqual({ text: `inject_id="inj-1"`, id: "inj-1" })
  const nudge = withMarker(`<channel source="memorypalace-nudge" chat_id="c">hi</channel>`, () => "inj-2")
  expect(nudge.text).toMatch(/^<channel source="memorypalace-nudge" chat_id="c" inject_id="inj-2">/)   // 下游按 source / chat_id 认的正则照认
  const bare = withMarker("裸文本", () => "inj-3")   // 裸文本不改字节；记号认不出 = 只能按不确定处理
  expect(bare.text).toBe("裸文本")
  expect(hasMarker(bare.text, bare.marker)).toBe(false)
})

test("userTextOfLine：claude user 行（字符串 / 块）、codex rollout 两种形状；sidechain / assistant 不算", () => {
  expect(userTextOfLine(JSON.stringify({ type: "user", message: { content: [{ type: "text", text: "a" }] } }))).toBe("a")
  expect(userTextOfLine(JSON.stringify({ type: "user", isSidechain: true, message: { content: "b" } }))).toBeUndefined()
  expect(userTextOfLine(JSON.stringify({ type: "assistant", message: { content: "c" } }))).toBeUndefined()
  expect(userTextOfLine(JSON.stringify({ type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "d" }] } }))).toBe("d")
  expect(userTextOfLine(JSON.stringify({ type: "event_msg", payload: { type: "user_message", message: "e" } }))).toBe("e")
  expect(userTextOfLine("{坏")).toBeUndefined()
})

test("TranscriptScanner（审查 R1-6）：只看发送前位置之后的；增量读；超过上限 / 文件变短 = unknown，不当没提交；文件原本没有 = not-seen", async () => {
  const dir = mkdtempSync(join(tmpdir(), "mp-scan-"))
  const path = join(dir, "t.jsonl")
  const line = (content: string) => JSON.stringify({ type: "user", message: { content } }) + "\n"
  const m = { text: `message_id="m-42"`, id: "m-42" }
  // 发送前就有同一个 message_id（重新生成复用了 id）：不算
  writeFileSync(path, line(TAG) + "x".repeat(100) + "\n")
  const c = (await transcriptCursor(path))!
  expect(c.offset).toBeGreaterThan(0)
  const s = new TranscriptScanner(c, m)
  expect(await s.poll()).toBe("not-seen")
  appendFileSync(path, line("别的"))
  expect(await s.poll()).toBe("not-seen")
  appendFileSync(path, line(TAG))
  expect(await s.poll()).toBe("seen")
  // 发送后又写了一大堆：超过上限 = unknown
  const big = new TranscriptScanner(c, m, 50)
  expect(await big.poll()).toBe("unknown")
  // 文件变短（被换掉）= unknown
  const gone = new TranscriptScanner({ path, offset: 10 ** 9 }, m)
  expect(await gone.poll()).toBe("unknown")
  // 发送前文件还没有、现在也没有：什么都没写
  const fresh = (await transcriptCursor(join(dir, "none.jsonl")))!
  expect(fresh.offset).toBe(0)
  expect(await new TranscriptScanner(fresh, m).poll()).toBe("not-seen")
  // 没游标 = unknown
  expect(await new TranscriptScanner(undefined, m).poll()).toBe("unknown")
})

test("locateEditArea（审查 R1-5）：claude 认最后两条整行横线中间、以 ❯ / > 开头的那段；历史里的文字和对话框不算；codex 认 ›", () => {
  const claude = [
    `> <channel message_id="old">历史里的旧消息</channel>`,
    "● 回答……",
    "─".repeat(60),
    `❯ <channel source="memorypalace" chat_id="c-1" message_i`,
    `  d="m-42" user="susu">你好</channel>`,
    "─".repeat(60),
    "  ? for shortcuts",
  ].join("\n")
  const area = locateEditArea(claude, "claude")!
  expect(hasMarker(area, { text: `message_id="m-42"`, id: "m-42" })).toBe(true)
  expect(hasMarker(area, { text: `message_id="old"`, id: "old" })).toBe(false)
  expect(locateEditArea(["─".repeat(60), "❯ ", "─".repeat(60)].join("\n"), "claude")).toBe("")
  expect(locateEditArea(["─".repeat(60), "  1. Yes", "─".repeat(60)].join("\n"), "claude")).toBeUndefined()   // 中间不是提示符
  expect(locateEditArea("没有输入框", "claude")).toBeUndefined()
  expect(locateEditArea(["历史", "› 正在输入的字", "  第二行", "", "  ⏎ send"].join("\n"), "codex")).toBe("正在输入的字\n第二行")
  expect(locateEditArea("历史", "codex")).toBeUndefined()
})

test("findCodexRollout：按 uuid 找，日期目录从新往旧；找不到 undefined", async () => {
  const root = mkdtempSync(join(tmpdir(), "mp-rollout-"))
  const uuid = "019a0000-1111-2222-3333-444455556666"
  mkdirSync(join(root, "2026", "09", "30"), { recursive: true })
  mkdirSync(join(root, "2026", "10", "11"), { recursive: true })
  writeFileSync(join(root, "2026", "09", "30", `rollout-2026-09-30T01-02-03-${uuid}.jsonl`), "")
  expect(await findCodexRollout(root, uuid)).toBe(join(root, "2026", "09", "30", `rollout-2026-09-30T01-02-03-${uuid}.jsonl`))
  expect(await findCodexRollout(root, "019a0000-0000-0000-0000-000000000000")).toBeUndefined()
  expect(await findCodexRollout(join(root, "nope"), uuid)).toBeUndefined()
})

test("SendStatusBook：retry 只接受 failed + retryable；进行中 / 送达 / 没记录 / 跨 transport / 正忙都拒，带 retryable:false 或限流 true", () => {
  let now = 1_000
  const book = new SendStatusBook(3_600_000, 3, 2, () => now)
  const seen: string[] = []
  book.watch((f) => seen.push(`${f.message_id}:${f.status}:${f.retryable}`))
  const a = book.begin("a", "c", "s", undefined, undefined)!
  expect(book.acceptRetry("a", "c", "s", false)).toMatchObject({ accepted: false, frame: { status: "uncertain", retryable: false } })   // 还在核对
  book.finish(a, { status: "failed", retryable: true, reason: "可能已经进去了" })
  const b = book.begin("b", "c", "s", undefined, undefined)!
  book.finish(b, { status: "delivered", retryable: false, reason: "已经提交了" })
  expect(book.acceptRetry("b", "c", "s", false)).toMatchObject({ accepted: false, frame: { status: "delivered", retryable: false } })
  expect(book.acceptRetry("zzz", "c", "s", false)).toMatchObject({ accepted: false, frame: { status: "failed", retryable: false } })
  expect(book.acceptRetry("a", "c", "s", true)).toMatchObject({ accepted: false, frame: { status: "failed", retryable: false } })   // 会话改走 stream
  const r = book.acceptRetry("a", "c", "s", false)
  expect(r.accepted).toBe(true)
  expect(book.acceptRetry("a", "c", "s", false)).toMatchObject({ accepted: false, frame: { status: "uncertain" } })   // 连点两下
  // 进行中的上限 2：再一个就限流（retryable:true，过会儿再点）
  const c = book.begin("c", "c", "s", undefined, undefined)!
  book.finish(c, { status: "failed", retryable: true, reason: "x" })
  book.begin("d", "c", "s", undefined, undefined)
  expect(book.acceptRetry("c", "c", "s", false)).toMatchObject({ accepted: false, frame: { status: "failed", retryable: true } })
  expect(seen).toEqual(["a:uncertain:false", "a:failed:true", "b:uncertain:false", "b:delivered:false", "c:uncertain:false", "c:failed:true", "d:uncertain:false"])
  // 1 小时过期
  now += 3_600_001
  expect(book.record("c")).toBeUndefined()
})

test("SendStatusBook（审查 R1-7）：历史上限只挤终态，进行中的重发不会被挤掉", () => {
  const book = new SendStatusBook(3_600_000, 2, 10)
  const a = book.begin("a", "c", "s", undefined, undefined)!
  book.finish(a, { status: "failed", retryable: true, reason: "x" })
  expect(book.acceptRetry("a", "c", "s", false).accepted).toBe(true)
  for (let i = 0; i < 50; i++) book.finish(book.begin(`h${i}`, "c", "s", undefined, undefined)!, { status: "delivered", retryable: false, reason: "" })
  expect(book.active.get("a")?.retry).toBe(true)
})

test("SendStatusBook：同一个 message_id 新的一次发送开始后，旧的那次的结果不再发；快照只带进行中（uncertain）和 failed", () => {
  const book = new SendStatusBook()
  const seen: string[] = []
  book.watch((f) => seen.push(`${f.message_id}:${f.status}`))
  book.attemptStarted("m", "t1", false)
  const old = book.begin("m", "c", "s", undefined, "t1")!
  book.attemptStarted("m", "t2", false)   // 重新生成
  expect(book.finish(old, { status: "failed", retryable: true, reason: "x" })).toBe(false)
  expect(book.begin("m", "c", "s", undefined, "t1")).toBeUndefined()   // 旧的那次之后才进核对：也不进账
  expect(seen).toEqual(["m:uncertain"])
  // 快照
  const f = book.begin("f", "c", "s", undefined, undefined)!
  book.finish(f, { status: "failed", retryable: true, reason: "可能已经进去了" })
  const d = book.begin("d", "c", "s", undefined, undefined)!
  book.finish(d, { status: "delivered", retryable: false, reason: "" })
  book.begin("u", "c", "s", undefined, undefined)
  const snap = book.snapshot().map((x) => `${x.message_id}:${x.status}:${x.retryable}`).sort()
  expect(snap).toEqual(["f:failed:true", "u:uncertain:false"])
  // 重发：被接受的那次登记成最新
  expect(book.acceptRetry("f", "c", "s", false).accepted).toBe(true)
  book.attemptStarted("f", "t9", true)
  expect(book.active.get("f")?.attempt).toBe("t9")
  expect(book.snapshot().find((x) => x.message_id === "f")?.status).toBe("uncertain")
})

test("waitTmuxWriteSettled：回执晚到 = executed / not-executed；客户端没了要探针连续成功 2 次；截止前没落定 = timeout", async () => {
  const err = (s: WriteSettle) => new TmuxUncertainError("x", Promise.resolve(s))
  expect(await waitTmuxWriteSettled(err({ kind: "replied", ok: true, detail: "" }), Date.now() + 1_000, async () => false)).toEqual({ kind: "executed" })
  expect(await waitTmuxWriteSettled(err({ kind: "replied", ok: false, detail: "can't find pane" }), Date.now() + 1_000, async () => false)).toEqual({ kind: "not-executed", detail: "can't find pane" })
  const answers = [true, false, true, true]
  let probes = 0
  expect(await waitTmuxWriteSettled(err({ kind: "abandoned" }), Date.now() + 5_000, async () => { probes++; return answers.shift()! })).toEqual({ kind: "settled" })
  expect(probes).toBe(4)
  expect(await waitTmuxWriteSettled(err({ kind: "abandoned" }), Date.now() + 300, async () => false)).toEqual({ kind: "timeout" })
})
