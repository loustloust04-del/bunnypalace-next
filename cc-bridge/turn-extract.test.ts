import { test, expect } from "bun:test"
import { extractLastChannelTurn, extractLastChannelTurnFromFile, extractChannelTurnAt, readTailWithOffsets, fitRows, undeliveredRows, parseRows } from "./turn-extract"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const L = (o: object) => JSON.stringify(o)
const chan = (chat: string, mid = "m1") => L({ type: "user", message: { role: "user", content: `<channel source="memorypalace" chat_id="${chat}" message_id="${mid}" user="禾禾" ts="t">hi</channel> 直接用文字回答即可` } })
const asst = (content: object[], uuid = "u") => L({ type: "assistant", uuid, message: { role: "assistant", content } })

test("取最后一轮：正文 + thinking + message_id + 最后一段正文的 uuid", () => {
  const t = extractLastChannelTurn([chan("old"), asst([{ type: "text", text: "旧" }]), chan("C1", "M9"),
    asst([{ type: "thinking", thinking: "想" }], "u1"), asst([{ type: "text", text: "在的" }], "u2")])!
  expect(t).toEqual({ chatId: "C1", messageId: "M9", text: "在的", thinking: "想", turnUuid: "u2", usedReply: false, isLatest: true, rows: [{ uuid: "u2", text: "在的" }] })
})

test("tool_result 不算新一轮；用了 reply 工具标 usedReply；保暖 ping 在后面则 isLatest=false", () => {
  const tr = L({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "x", content: "ok" }] } })
  const t = extractLastChannelTurn([chan("C"), asst([{ type: "tool_use", name: "mcp__cc-bridge__reply", input: {} }]), tr, asst([{ type: "text", text: "内心" }])])!
  expect(t.usedReply).toBe(true)
  expect(t.isLatest).toBe(true)
  const ka = L({ type: "user", message: { role: "user", content: `<channel source="cache-keepalive">ping</channel>` } })
  expect(extractLastChannelTurn([chan("C"), asst([{ type: "text", text: "a" }]), ka, asst([{ type: "text", text: "ok" }])])!.isLatest).toBe(false)
})

test("没有 channel → null；坏行跳过", () => {
  expect(extractLastChannelTurn(["{bad", L({ type: "user", message: { content: "终端打字" } })])).toBeNull()
})

// ---------- 10-11 吞 / 重复 ----------
test("rows：本轮每段正文带转录 uuid，按序", () => {
  const t = extractLastChannelTurn([chan("C"), asst([{ type: "text", text: "旁白一" }], "r1"), asst([{ type: "tool_use", name: "Bash", input: {} }], "r2"),
    asst([{ type: "text", text: " 旁白二 " }], "r3"), asst([{ type: "text", text: "最后的话" }], "r4")])!
  expect(t.rows).toEqual([{ uuid: "r1", text: "旁白一" }, { uuid: "r3", text: "旁白二" }, { uuid: "r4", text: "最后的话" }])
  expect(t.turnUuid).toBe("r4")
})

test("undeliveredRows：最后一个投过的段之前都算投过，只给后面的", () => {
  const rows = [{ uuid: "a", text: "1" }, { uuid: "b", text: "2" }, { uuid: "c", text: "3" }]
  expect(undeliveredRows(rows, () => false)).toEqual(rows)
  expect(undeliveredRows(rows, (u) => u === "b")).toEqual([{ uuid: "c", text: "3" }])   // 老 hook 只记了最后一段的 id
  expect(undeliveredRows(rows, (u) => u === "c")).toEqual([])
})

test("parseRows：格式不对整个不认（回落到老的 reply_text）", () => {
  expect(parseRows([{ uuid: "a", text: " x " }])).toEqual([{ uuid: "a", text: "x" }])
  expect(parseRows([])).toBeUndefined()
  expect(parseRows("x")).toBeUndefined()
  expect(parseRows([{ uuid: "", text: "x" }])).toBeUndefined()
  expect(parseRows([{ uuid: "a", text: "  " }])).toBeUndefined()
})

test("extractLastChannelTurnFromFile：本轮起点不在尾巴里（大图把一轮撑到好几 MB）就放大再读", async () => {
  const dir = mkdtempSync(join(tmpdir(), "turn-extract-"))
  const path = join(dir, "t.jsonl")
  const bigResult = L({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "x", content: [{ type: "image", source: { data: "A".repeat(200_000) } }] }] } })
  writeFileSync(path, [chan("C-big"), asst([{ type: "text", text: "旁白" }], "b1"), bigResult, asst([{ type: "text", text: "图存好了" }], "b2")].join("\n") + "\n")
  expect(extractLastChannelTurn((await Bun.file(path).text()).split("\n").slice(-2))).toBeNull()   // 老兜底：尾巴里没有 channel
  const t = await extractLastChannelTurnFromFile(path, [1000, 1 << 20])
  expect(t?.chatId).toBe("C-big")
  expect(t?.rows.map((r) => r.uuid)).toEqual(["b1", "b2"])
  expect(await extractLastChannelTurnFromFile(path, [1000])).toBeNull()
})

// ---------- 10-11 审 ----------
test("fitRows：只取完整放得下的段；第一段自己超限照取（调用方截断）", () => {
  const r = (uuid: string, n: number) => ({ uuid, text: "字".repeat(n) })
  expect(fitRows([r("a", 5), r("b", 5)], 12).map((x) => x.uuid)).toEqual(["a", "b"])   // 5 + 2 + 5
  expect(fitRows([r("a", 5), r("b", 6)], 12).map((x) => x.uuid)).toEqual(["a"])
  expect(fitRows([r("a", 20), r("b", 1)], 12).map((x) => x.uuid)).toEqual(["a"])
})

test("钉轮：pin 之后她又发了一条，取的仍是 pin 那一轮，读到下一轮起点为止", () => {
  const lines = [chan("C1", "M1"), asst([{ type: "text", text: "旁白" }], "p1"), asst([{ type: "text", text: "最后一段" }], "p2"),
    chan("C2", "M2"), asst([{ type: "text", text: "下一轮" }], "p3")]
  const offsets = lines.map((_, i) => i * 100)
  const t = extractChannelTurnAt(lines, offsets, 150)!   // Stop 时只写到第 2 行，最后一段是之后落盘的
  expect(t.chatId).toBe("C1")
  expect(t.messageId).toBe("M1")
  expect(t.isLatest).toBe(true)
  expect(t.rows.map((r) => r.uuid)).toEqual(["p1", "p2"])
  expect(extractLastChannelTurn(lines)!.chatId).toBe("C2")   // 不钉就挑成新一轮（老 bug）
})

test("readTailWithOffsets：每行的起始字节对得上（含中文、尾巴切掉半行）", async () => {
  const dir = mkdtempSync(join(tmpdir(), "turn-extract-"))
  const path = join(dir, "o.jsonl")
  const ls = ["第一行", "second", "第三行中文"]
  writeFileSync(path, ls.join("\n") + "\n")
  const all = await readTailWithOffsets(path, 1 << 20)
  expect(all.lines).toEqual(ls)
  expect(all.offsets).toEqual([0, Buffer.byteLength("第一行\n"), Buffer.byteLength("第一行\nsecond\n")])
  const tail = await readTailWithOffsets(path, Buffer.byteLength("cond\n第三行中文\n"))
  expect(tail.lines).toEqual(["第三行中文"])
  expect(tail.offsets).toEqual([Buffer.byteLength("第一行\nsecond\n")])
})

test("放大读同一时刻只跑一个，其余排队；第一档不排队", async () => {
  let inFlight = 0, maxBig = 0
  const read = async (_: string, n: number) => {
    if (n > 10) { inFlight++; maxBig = Math.max(maxBig, inFlight) }
    await new Promise((r) => setTimeout(r, 30))
    if (n > 10) inFlight--
    return { lines: [], offsets: [] }
  }
  const t0 = Date.now()
  const rs = await Promise.all([1, 2, 3].map(() => extractLastChannelTurnFromFile("x", [10, 100, 1000], Infinity, read)))
  expect(rs).toEqual([null, null, null])
  expect(maxBig).toBe(1)
  expect(Date.now() - t0).toBeGreaterThanOrEqual(6 * 30 - 5)   // 6 次放大读串行
})
