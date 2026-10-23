// K1 第 4b 步 · 审查 R1：送达核对流程（假 IO，时间缩小；真 tmux 的见 hub-send.test.ts）
import { expect, test } from "bun:test"
import { appendFileSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { locateEditArea, SendStatusBook, type EditArea } from "./send-verify"
import { SendTracker, type InjectResult, type TrackDeps } from "./send-track"
import { TmuxCommandError, TmuxUncertainError, type WriteFate } from "./tmux-control"

const T = { settleMs: 1_000, confirmMs: 300, consumeMs: 50, holdMs: 400, pollMs: 10, retryMaxMs: 200 }
const tag = (id: string, ts = "t1") => `<channel source="memorypalace" chat_id="c" message_id="${id}" user="susu" ts="${ts}">hi</channel>`
const area = (text: string): EditArea => ({ kind: "found", text })
const EMPTY = area("")

interface Fake {
  tracker: SendTracker
  book: SendStatusBook
  frames: string[]
  calls: string[]
  transcript: string
  /// 往 transcript 里追加一条已提交的
  submitLine: (text: string) => void
  setArea: (...seq: EditArea[]) => void
  gen: { v: number }
  legacy: string[]
}

function fake(o: {
  inject?: ((text: string) => Promise<InjectResult>)[]
  fate?: WriteFate | WriteFate[]
  buffer?: boolean | undefined
  submit?: (f: Fake) => boolean
  timings?: Partial<typeof T>
} = {}): Fake {
  const dir = mkdtempSync(join(tmpdir(), "mp-track-"))
  const transcript = join(dir, "t.jsonl")
  writeFileSync(transcript, "")
  const book = new SendStatusBook()
  const frames: string[] = []
  book.watch((fr) => frames.push(`${fr.message_id}:${fr.status}${fr.status === "failed" ? `:${fr.retryable}` : ""}`))
  const calls: string[] = []
  let areas: EditArea[] = [EMPTY]
  const gen = { v: 1 }
  const legacy: string[] = []
  const f = {} as Fake
  const deps: TrackDeps = {
    inject: async (text) => { calls.push("inject"); const n = o.inject?.shift(); return n ? n(text) : { committed: true, paste: false } },
    submit: async () => { calls.push("submit"); return o.submit ? o.submit(f) : true },
    settle: async () => {
      calls.push("settle")
      const q = Array.isArray(o.fate) ? o.fate : [o.fate ?? { kind: "settled" }]
      return q.length > 1 ? q.shift()! : q[0]
    },
    bufferExists: async () => { calls.push("buffer?"); return o.buffer },
    deleteBuffer: async () => { calls.push("delbuf") },
    cursor: async () => ({ path: transcript, offset: Bun.file(transcript).size }),
    editArea: async () => (areas.length > 1 ? areas.shift()! : areas[0]),
    generation: () => gen.v,
    sessionGone: () => { calls.push("gone") },
    requeue: () => { calls.push("requeue") },
    legacyError: (_s, id, reason) => { legacy.push(`${id}:${reason}`) },
    sleep: (ms) => Bun.sleep(ms),
    now: Date.now,
  }
  Object.assign(f, {
    tracker: new SendTracker(book, deps, { ...T, ...o.timings }), book, frames, calls, transcript, gen, legacy,
    submitLine: (text: string) => appendFileSync(transcript, JSON.stringify({ type: "user", message: { content: text } }) + "\n"),
    setArea: (...seq: EditArea[]) => { areas = seq },
  })
  return f
}
const uncertain = (buffer?: string) => { const e = new TmuxUncertainError("tmux control timeout 10000ms"); if (buffer) e.buffer = buffer; return e }

test("正常发送：只注入一次，不进账、不发 send_status", async () => {
  const f = fake()
  await f.tracker.send(tag("n"), "s")
  expect(f.calls).toEqual(["inject"])
  expect(f.frames).toEqual([])
  expect(f.book.record("n")).toBeUndefined()
})

test("审查 R1-1：落定后 TUI 还没消费（屏上暂时没有）不重发——等它出现在输入框里再补回车", async () => {
  const f = fake({ inject: [async () => { throw uncertain() }] })
  f.setArea(EMPTY, EMPTY, EMPTY, area(tag("a")), EMPTY)   // 晚了几拍才进输入框；补回车后清空
  await f.tracker.send(tag("a"), "s")
  expect(f.calls.filter((c) => c === "inject").length).toBe(1)
  expect(f.calls).toContain("submit")
  expect(f.frames).toEqual(["a:uncertain", "a:delivered"])
})

test("审查 R1-1：不确定、窗口里一直没看到 → failed retryable，不重发", async () => {
  const f = fake({ inject: [async () => { throw uncertain() }] })
  await f.tracker.send(tag("b"), "s")
  expect(f.calls.filter((c) => c === "inject").length).toBe(1)
  expect(f.frames).toEqual(["b:uncertain", "b:failed:true"])
  expect(f.book.record("b")?.reason).toContain("可能已经进去了")
  expect(f.legacy.length).toBe(1)   // 旧版 app 的 error 帧
})

test("确定没执行（tmux 明确答错）才自动重发一次", async () => {
  const f = fake({ inject: [async () => { throw uncertain() }], fate: { kind: "not-executed", detail: "can't find pane" } })
  await f.tracker.send(tag("c"), "s")
  expect(f.calls).toEqual(["inject", "settle", "inject"])
  expect(f.frames).toEqual(["c:uncertain", "c:delivered"])
})

test("粘贴：落定后缓冲区还在 = paste-buffer 没执行 → 删缓冲区、重发一次；不在 = 贴进去了 → 认占位、补回车，不重发", async () => {
  const a = fake({ inject: [async () => { throw uncertain("mp-1-1") }], buffer: true })
  await a.tracker.send(tag("p1"), "s")
  expect(a.calls).toEqual(["inject", "settle", "buffer?", "delbuf", "inject"])
  expect(a.frames.at(-1)).toBe("p1:delivered")
  const b = fake({ inject: [async () => { throw uncertain("mp-1-2") }], buffer: false })
  b.setArea(EMPTY, area("[Pasted text #1 +3 lines]"), EMPTY)
  await b.tracker.send(tag("p2"), "s")
  expect(b.calls).toEqual(["inject", "settle", "buffer?", "submit"])
  expect(b.frames.at(-1)).toBe("p2:delivered")
  // 查不了缓冲区：不确定，占位不认身份（审查 R1-5）
  const c = fake({ inject: [async () => { throw uncertain("mp-1-3") }], buffer: undefined })
  c.setArea(area("[Pasted text #1 +3 lines]"))
  await c.tracker.send(tag("p3"), "s")
  expect(c.calls.filter((x) => x === "inject" || x === "submit")).toEqual(["inject"])
  expect(c.frames.at(-1)).toBe("p3:failed:true")
})

test("审查 R1-5：不确定时，粘贴占位 / 别处的文字都不算这条在输入框", async () => {
  const f = fake({ inject: [async () => { throw uncertain() }] })
  f.setArea(area(`[Pasted text #3 +9 lines] message_id="other"`))
  await f.tracker.send(tag("d"), "s")
  expect(f.calls).not.toContain("submit")
  expect(f.frames.at(-1)).toBe("d:failed:true")
})

test("transcript 从发送前的位置往后有这条 → delivered（之前就有的同 id 不算，审查 R1-6）", async () => {
  const f = fake({ inject: [async () => { throw uncertain() }] })
  f.submitLine(tag("e"))   // 重新生成前的那次
  const sending = f.tracker.send(tag("e", "t2"), "s")
  await Bun.sleep(30)
  expect(f.frames).toEqual(["e:uncertain"])
  f.submitLine(tag("e", "t2"))
  await sending
  expect(f.frames).toEqual(["e:uncertain", "e:delivered"])
})

test("审查 R1-2：失败后会话继续堵着——旧写没落定不放行；落定后输入框里有这条（迟到的写）也不放行，读屏确认清空才放", async () => {
  // 第一次等落定超时 → failed；堵着期间再等：先超时两次，然后落定
  const f = fake({ inject: [async () => { throw uncertain() }], fate: [{ kind: "timeout" }, { kind: "timeout" }, { kind: "timeout" }, { kind: "settled" }], timings: { holdMs: 3_000 } })
  f.setArea(EMPTY)
  let done = false
  const p = f.tracker.send(tag("h"), "s").then(() => { done = true })
  await Bun.sleep(100)
  expect(f.frames.at(-1)).toBe("h:failed:true")
  expect(done).toBe(false)   // 落定之前，输入框是空的也不放行（字还可能迟到）
  f.setArea(area(tag("h")))   // 迟到的写落进了输入框
  await Bun.sleep(2_200)
  expect(done).toBe(false)
  f.setArea(EMPTY)            // 她手动处理掉了
  await p
  expect(done).toBe(true)
}, 10_000)

test("审查 R1-2：一直清不掉 → holdMs 到点放行，failed 原因补一句", async () => {
  const f = fake({ inject: [async () => { throw uncertain() }], submit: () => false })
  f.setArea(EMPTY, area(tag("j")))   // 进了输入框，补回车也提交不上
  const t0 = Date.now()
  await f.tracker.send(tag("j"), "s")
  expect(Date.now() - t0).toBeGreaterThanOrEqual(T.holdMs)
  expect(f.book.record("j")?.reason).toContain("后面的消息已经放行")
  expect(f.frames.filter((x) => x.startsWith("j:failed")).length).toBe(2)   // 失败一帧 + 补原因一帧
})

test("审查 R1-3：重发后回车没提交上，不报 delivered", async () => {
  const f = fake({ inject: [async () => { throw uncertain() }, async () => ({ committed: false, paste: false })], fate: { kind: "not-executed", detail: "x" } })
  f.setArea(area(tag("k")))   // 一直停在输入框
  await f.tracker.send(tag("k"), "s")
  expect(f.frames.at(-1)).toBe("k:failed:true")
})

test("审查 R1-3：正常发送回车后没确认提交 → 进核对（原来记一行就放行）；输入框清空了 = 收下了", async () => {
  const f = fake({ inject: [async () => ({ committed: false, paste: true })] })
  f.setArea(EMPTY)
  await f.tracker.send(tag("l"), "s")
  expect(f.frames).toEqual(["l:uncertain", "l:delivered"])
})

test("会话代次变了（重新拉起过）：旧核对不往新会话里补回车", async () => {
  const f = fake({ inject: [async () => { throw uncertain() }] })
  f.setArea(EMPTY, area(tag("g1")))
  const p = f.tracker.send(tag("g1"), "s")
  f.gen.v = 2
  await p
  expect(f.calls).not.toContain("submit")
  expect(f.frames.at(-1)).toBe("g1:failed:true")
})

test("审查 R1-9：核对时会话没了 → 清就绪、failed retryable（终端都没了，没提交的字跟着没了）；核对中算忙，不被回收", async () => {
  const f = fake({ inject: [async () => { throw uncertain() }] })
  f.setArea({ kind: "gone", detail: "can't find session: s" })
  const p = f.tracker.send(tag("x"), "s")
  await Bun.sleep(0)
  expect(f.tracker.busy("s")).toBe(true)
  await p
  expect(f.tracker.busy("s")).toBe(false)
  expect(f.calls).toContain("gone")
  expect(f.frames.at(-1)).toBe("x:failed:true")
})

test("重发（retry）：先看现场——原来那条其实提交过 → 不注入；停在输入框 → 补回车；没进 → 发", async () => {
  const f = fake()
  const op0 = f.book.begin("r", "c", "s", { path: f.transcript, offset: 0 }, undefined)!
  f.book.finish(op0, { status: "failed", retryable: true, reason: "可能已经进去了" })
  f.submitLine(tag("r"))   // 她在终端里自己按了回车
  const a = f.book.acceptRetry("r", "c", "s", false)
  expect(a.accepted).toBe(true)
  await f.tracker.send(tag("r", "t2"), "s")
  expect(f.calls).toEqual([])
  expect(f.frames.at(-1)).toBe("r:delivered")

  const g = fake()
  g.book.finish(g.book.begin("q", "c", "s", { path: g.transcript, offset: 0 }, undefined)!, { status: "failed", retryable: true, reason: "x" })
  g.book.acceptRetry("q", "c", "s", false)
  g.setArea(area(tag("q")), EMPTY)   // 输入框里认出这条 → 补回车 → 清空
  await g.tracker.send(tag("q", "t2"), "s")
  expect(g.calls).toEqual(["submit"])
  expect(g.frames.at(-1)).toBe("q:delivered")

  const h = fake()
  h.book.finish(h.book.begin("w", "c", "s", { path: h.transcript, offset: 0 }, undefined)!, { status: "failed", retryable: true, reason: "x" })
  h.book.acceptRetry("w", "c", "s", false)
  await h.tracker.send(tag("w", "t2"), "s")
  expect(h.calls).toEqual(["inject"])
  expect(h.frames.at(-1)).toBe("w:delivered")
})

test("审查 R1-9：重发时会话不在了 → 交回原有路径重新拉起（身份留在账上）；再不在 → failed", async () => {
  const f = fake()
  f.book.finish(f.book.begin("z", "c", "s", undefined, undefined)!, { status: "failed", retryable: true, reason: "x" })
  f.book.acceptRetry("z", "c", "s", false)
  f.setArea({ kind: "gone", detail: "can't find session: s" })
  await f.tracker.send(tag("z", "t2"), "s")
  expect(f.calls).toEqual(["gone", "requeue"])
  expect(f.book.active.get("z")?.started).toBe(false)
  await f.tracker.send(tag("z", "t2"), "s")   // 排队那次又碰上会话不在
  expect(f.frames.at(-1)).toBe("z:failed:true")
  expect(f.book.active.has("z")).toBe(false)
})

test("审查 R1-8：被接受的重发——注入前失败写回终态；一直没结果有看门狗", async () => {
  const f = fake()
  f.book.finish(f.book.begin("v", "c", "s", undefined, undefined)!, { status: "failed", retryable: true, reason: "x" })
  f.book.acceptRetry("v", "c", "s", false)
  f.tracker.abortRetry("v", "重发没发出去：附件落盘失败")
  expect(f.frames.at(-1)).toBe("v:failed:true")
  const r = f.book.acceptRetry("v", "c", "s", false)
  expect(r.accepted).toBe(true)
  if (r.accepted) f.tracker.armRetry(r.op)
  await Bun.sleep(T.retryMaxMs + 50)
  expect(f.frames.at(-1)).toBe("v:failed:true")
  expect(f.book.active.has("v")).toBe(false)
})

test("重发明确失败（会话没了）→ 交回原有路径：抛出去，身份留着等重新拉起后再发", async () => {
  const f = fake({ inject: [async () => { throw new TmuxCommandError("can't find pane: s") }] })
  f.book.finish(f.book.begin("y", "c", "s", undefined, undefined)!, { status: "failed", retryable: true, reason: "x" })
  f.book.acceptRetry("y", "c", "s", false)
  await expect(f.tracker.send(tag("y", "t2"), "s")).rejects.toBeInstanceOf(TmuxCommandError)
  expect(f.book.active.get("y")?.started).toBe(false)
})

test("重新生成：旧的那次核对完的结果不发（app 分不清是哪一次的）", async () => {
  const f = fake({ inject: [async () => { throw uncertain() }] })
  f.book.attemptStarted("m", "t1", false)
  const p = f.tracker.send(tag("m", "t1"), "s")
  await Bun.sleep(20)
  f.book.attemptStarted("m", "t2", false)
  await p
  expect(f.frames).toEqual(["m:uncertain"])
  expect(f.legacy).toEqual([])
})

test("codex 空输入框显示的是灰字占位（`› Ask Codex to do anything`，下面一行状态栏）：不含这条的记号 = 空，失败后立刻放行，不堵满 holdMs", async () => {
  // 粟粟 codex 会话的只读 capture（10-11 协调方核过）；占位文案会变，不按原文认，只看里面有没有这次的记号 / 粘贴占位
  const pane = ["• 上一轮的回答……", "", "› Ask Codex to do anything", "  GPT-6.1-Sol medium · ~/Desktop/x · 100% context left"].join("\n")
  const text = locateEditArea(pane, "codex")
  expect(text).toBeDefined()
  const f = fake({ inject: [async () => { throw uncertain() }], timings: { holdMs: 5_000 } })
  f.setArea(area(text!))
  const t0 = Date.now()
  await f.tracker.send(tag("cx"), "mp-codex-1")
  expect(f.frames.at(-1)).toBe("cx:failed:true")
  expect(Date.now() - t0).toBeLessThan(2_000)   // 确认窗口 0.3s + 放行；堵满会是 5s
  // 换个占位文案也一样；输入框里真有这条就不放行（由上面 R1-2 的用例管）
  const other = locateEditArea(["› Find and fix a bug in @filename", "  status"].join("\n"), "codex")!
  expect(other.includes("cx")).toBe(false)
})
