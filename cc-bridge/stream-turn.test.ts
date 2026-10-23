import { test, expect } from "bun:test"
import { StreamTurnTracker, planTransportReconcile } from "./stream-turn"

const ev = (event: object) => ({ type: "stream_event", event })
const start = (index: number, cb: object) => ev({ type: "content_block_start", index, content_block: cb })
const tdelta = (text: string) => ev({ type: "content_block_delta", index: 1, delta: { type: "text_delta", text } })
const kdelta = (thinking: string) => ev({ type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking } })

test("thinking 先流、再正文流、块完成带 uuid、result 收尾", () => {
  let n = 0
  const t = new StreamTurnTracker(() => `id${++n}`)
  expect(t.handle("s", start(0, { type: "thinking" }))).toEqual([])
  expect(t.handle("s", kdelta("想"))).toEqual([{ kind: "create", pendingId: "s_txt_id1" }, { kind: "thinking", pendingId: "s_txt_id1", content: "想" }])
  expect(t.handle("s", kdelta("一下"))).toEqual([{ kind: "thinking", pendingId: "s_txt_id1", content: "想一下" }])
  expect(t.handle("s", { type: "assistant", uuid: "u-think", message: { content: [{ type: "thinking", thinking: "想一下" }] } }))
    .toEqual([{ kind: "thinking_done", pendingId: "s_txt_id1", content: "想一下" }])
  t.handle("s", start(1, { type: "text" }))
  expect(t.handle("s", tdelta("在"))).toEqual([{ kind: "text", pendingId: "s_txt_id1", content: "在" }])
  expect(t.handle("s", tdelta("的"))).toEqual([{ kind: "text", pendingId: "s_txt_id1", content: "在的" }])
  expect(t.handle("s", { type: "assistant", uuid: "u-text", message: { content: [{ type: "text", text: "在的" }] } }))
    .toEqual([{ kind: "text_done", pendingId: "s_txt_id1", content: "在的", uuid: "u-text" }])
  expect(t.handle("s", { type: "result", subtype: "success" })).toEqual([{ kind: "end", pendingId: "s_txt_id1", textUuids: ["u-text"], text: "在的", thinking: "想一下" }])
  expect(t.has("s")).toBe(false)
})

test("本轮出现 reply 工具 → 之后的正文不再投；不同 session 互不影响", () => {
  const t = new StreamTurnTracker(() => "x")
  t.handle("a", start(0, { type: "tool_use", name: "mcp__cc-bridge__reply" }))
  expect(t.handle("a", tdelta("内心独白"))).toEqual([])
  expect(t.handle("b", tdelta("正常"))).toEqual([{ kind: "create", pendingId: "s_txt_x" }, { kind: "text", pendingId: "s_txt_x", content: "正常" }])
  expect(t.handle("a", { type: "result" })).toEqual([{ kind: "end", pendingId: undefined, textUuids: [], text: "", thinking: "" }])
})

test("没有任何 delta 的轮（只调了 Bash 工具）result 不产生节点", () => {
  const t = new StreamTurnTracker()
  t.handle("s", start(0, { type: "tool_use", name: "Bash" }))
  expect(t.handle("s", { type: "result" })).toEqual([{ kind: "end", pendingId: undefined, textUuids: [], text: "", thinking: "" }])
})

test("planTransportReconcile：不符且空闲立收、忙等、重新符合的取消", () => {
  const want = (n: string) => (n === "a" || n === "b" || n === "c") ? "stream" : "tmux"
  const live = [
    { name: "a", transport: "tmux" as const, busy: false },
    { name: "b", transport: "tmux" as const, busy: true },
    { name: "c", transport: "stream" as const, busy: true },
    { name: "d", transport: "stream" as const, busy: false },
    { name: "e", transport: "tmux" as const, busy: false },
  ]
  expect(planTransportReconcile(live, want, ["c", "b"])).toEqual({ retireNow: ["a", "d"], retireLater: [], cancel: ["c"] })
  expect(planTransportReconcile(live, want, [])).toEqual({ retireNow: ["a", "d"], retireLater: ["b"], cancel: [] })
})

test("AskUserQuestion 前有正文 → split 封稿，答完的字另起节点；只有 thinking 时不拆", () => {
  let n = 0
  const t = new StreamTurnTracker(() => `id${++n}`)
  t.handle("s", tdelta("先问你一句"))
  expect(t.handle("s", start(1, { type: "tool_use", name: "AskUserQuestion" })))
    .toEqual([{ kind: "split", pendingId: "s_txt_id1", text: "先问你一句", thinking: "" }])
  expect(t.handle("s", tdelta("好的"))).toEqual([{ kind: "create", pendingId: "s_txt_id2" }, { kind: "text", pendingId: "s_txt_id2", content: "好的" }])
  const t2 = new StreamTurnTracker(() => "only")
  t2.handle("s", kdelta("想"))
  expect(t2.handle("s", start(1, { type: "tool_use", name: "AskUserQuestion" }))).toEqual([])
  expect(t2.handle("s", tdelta("答"))).toEqual([{ kind: "text", pendingId: "s_txt_only", content: "答" }])
})
