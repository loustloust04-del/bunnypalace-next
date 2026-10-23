import { describe, expect, test } from "bun:test"
import { isChatTool, toolActivitySince, ToolActivityTracker, TOOL_ACTIVITY_DORMANT_MS, TOOL_ACTIVITY_DORMANT_POLL_MS } from "./tool-activity"
import { buildSessionPhaseFrame } from "./session-phase"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { readTail, readTailAsync } from "./turn-extract"

// 粟粟 10-04：普通聊天（ccrp 只回话、没动工具）不出状态卡；真在用工具干活才出
const line = (ts: string, tools: string[], text = "") => JSON.stringify({
  type: "assistant", timestamp: ts,
  message: { role: "assistant", content: [...(text ? [{ type: "text", text }] : []), ...tools.map((name, i) => ({ type: "tool_use", id: `toolu_${i}`, name, input: {} }))] },
})

describe("toolActivitySince", () => {
  const since = Date.parse("2026-10-04T10:00:00Z") / 1000
  test("只数这一轮里的工具，回话用的 cc-bridge 工具不算", () => {
    const lines = [
      line("2026-10-04T09:59:00Z", ["Bash"]),                                   // 上一轮
      line("2026-10-04T10:00:05Z", ["Read", "mcp__cc-bridge__reply"]),
      JSON.stringify({ type: "user", timestamp: "2026-10-04T10:00:06Z", message: { content: [{ type: "tool_result", tool_use_id: "toolu_0" }] } }),
      line("2026-10-04T10:00:09Z", ["Bash"], "跑一下"),
      "not json {\"tool_use\"",
      "",
    ]
    expect(toolActivitySince(lines, since)).toEqual({ count: 2, last: "Bash" })
  })
  test("纯聊天：没有工具", () => {
    expect(toolActivitySince([line("2026-10-04T10:00:05Z", [], "你好呀"), line("2026-10-04T10:00:07Z", ["mcp__cc-bridge__reply"])], since)).toEqual({ count: 0 })
  })
  test("聊天类工具", () => {
    for (const n of ["mcp__cc-bridge__reply", "mcp__cc-bridge__roll_dice", "mcp__cc-bridge__card_guide", "AskUserQuestion"]) expect(isChatTool(n)).toBe(true)
    for (const n of ["Bash", "Edit", "mcp__github__create_issue", "WebSearch"]) expect(isChatTool(n)).toBe(false)
  })
})

describe("session_phase 带工具数", () => {
  test("用过工具才带", () => {
    const f = JSON.parse(buildSessionPhaseFrame("mp-cc", { phase: "working", since_unix: 1, updated_unix: 2 }, true, "c", { count: 3, last: "Bash" }))
    expect(f.tools).toBe(3)
    expect(f.tool).toBe("Bash")
    const plain = JSON.parse(buildSessionPhaseFrame("mp-cc", { phase: "working", since_unix: 1, updated_unix: 2 }, true, "c", { count: 0 }))
    expect(plain.tools).toBeUndefined()
  })
})

describe("ToolActivityTracker（K3：异步 stat / 读尾巴）", () => {
  const since = Date.parse("2026-10-04T10:00:00Z") / 1000
  const fake = (start: number) => {
    let clock = start
    let mtime: number | undefined = start
    let lines = [line("2026-10-04T10:00:05Z", ["Bash"])]
    const calls = { stat: 0, read: 0 }
    let gate: Promise<void> | null = null
    const t = new ToolActivityTracker({
      stat: async () => { calls.stat++; return mtime },
      readTail: async () => { calls.read++; if (gate) await gate; return lines },
      now: () => clock,
    })
    return {
      t, calls,
      set clock(v: number) { clock = v }, get clock() { return clock },
      set mtime(v: number | undefined) { mtime = v },
      set lines(v: string[]) { lines = v },
      hold() { let release!: () => void; gate = new Promise<void>((r) => { release = r }); return () => { gate = null; release() } },
    }
  }

  test("transcript 动过才读；没动过只 stat", async () => {
    const f = fake(Date.parse("2026-10-04T10:01:00Z"))
    expect(await f.t.refresh("s", "/x.jsonl", since)).toBe(true)
    expect(f.t.bySession.get("s")).toEqual({ count: 1, last: "Bash" })
    expect(await f.t.refresh("s", "/x.jsonl", since)).toBe(false)
    expect(f.calls).toEqual({ stat: 2, read: 1 })
    f.mtime = f.clock + 1
    f.lines = [line("2026-10-04T10:00:05Z", ["Bash"]), line("2026-10-04T10:00:09Z", ["Edit"])]
    expect(await f.t.refresh("s", "/x.jsonl", since)).toBe(true)
    expect(f.t.bySession.get("s")).toEqual({ count: 2, last: "Edit" })
  })

  test("半小时没动的 working：不读，隔一分钟才再 stat", async () => {
    const start = Date.parse("2026-10-04T12:00:00Z")
    const f = fake(start)
    f.mtime = start - TOOL_ACTIVITY_DORMANT_MS - 1
    expect(await f.t.poll("s", "/x.jsonl", since)).toBe(false)
    expect(f.calls).toEqual({ stat: 1, read: 0 })
    f.clock = start + TOOL_ACTIVITY_DORMANT_POLL_MS - 1
    expect(await f.t.poll("s", "/x.jsonl", since)).toBe(false)
    expect(f.calls.stat).toBe(1)
    // 又动了：一分钟到点 stat 到新 mtime，照常读
    f.clock = start + TOOL_ACTIVITY_DORMANT_POLL_MS
    f.mtime = f.clock
    expect(await f.t.poll("s", "/x.jsonl", since)).toBe(true)
    expect(f.calls).toEqual({ stat: 2, read: 1 })
    // 活跃的每次 poll 都 stat
    expect(await f.t.poll("s", "/x.jsonl", since)).toBe(false)
    expect(f.calls.stat).toBe(3)
  })

  test("新一轮 reset 之后才落地的旧结果作废", async () => {
    const f = fake(Date.parse("2026-10-04T10:01:00Z"))
    const release = f.hold()
    const p = f.t.refresh("s", "/x.jsonl", since)
    await Promise.resolve(); await Promise.resolve()
    f.t.reset("s")
    release()
    expect(await p).toBe(false)
    expect(f.t.bySession.has("s")).toBe(false)
    // reset 后同一 mtime 也要重读（新一轮从 0 数）
    expect(await f.t.refresh("s", "/x.jsonl", since)).toBe(true)
    expect(f.calls.read).toBe(2)
  })

  test("同一会话的刷新串行；stat 失败 / 文件不在 → false 不抛", async () => {
    const f = fake(Date.parse("2026-10-04T10:01:00Z"))
    const release = f.hold()
    const a = f.t.refresh("s", "/x.jsonl", since)
    const b = f.t.refresh("s", "/x.jsonl", since)
    await new Promise((r) => setTimeout(r, 5))
    expect(f.calls).toEqual({ stat: 1, read: 1 })   // b 排在 a 后面，还没开始
    release()
    expect(await a).toBe(true)
    expect(await b).toBe(false)                     // a 读过同一 mtime
    f.mtime = undefined
    expect(await f.t.refresh("s", "/x.jsonl", since)).toBe(false)
    const bad = new ToolActivityTracker({ stat: () => Promise.reject(new Error("EIO")), readTail: async () => [], now: Date.now })
    expect(await bad.refresh("s", "/x.jsonl", since)).toBe(false)
  })

  test("畸形 transcript（content 是对象 / 读尾巴抛错 / toolActivitySince 抛错）：不 reject、不留悬空 rejection，mtime 不提交下次重读", async () => {
    const unhandled: unknown[] = []
    const onUnhandled = (e: unknown) => { unhandled.push(e) }
    process.on("unhandledRejection", onUnhandled)
    try {
      const weird = JSON.stringify({ type: "assistant", timestamp: "2026-10-04T10:00:05Z", message: { content: { type: "tool_use", name: "Bash" } } })
      expect(toolActivitySince([weird, line("2026-10-04T10:00:06Z", ["Edit"])], since)).toEqual({ count: 1, last: "Edit" })
      let reads = 0, mode: "throw" | "ok" = "throw"
      const t = new ToolActivityTracker({
        stat: async () => 1_000,
        readTail: async () => { reads++; if (mode === "throw") throw new TypeError("boom"); return [line("2026-10-04T10:00:06Z", ["Edit"])] },
        now: () => 2_000,
      })
      const p = t.refresh("s", "/x.jsonl", since)
      await expect(p).resolves.toBe(false)
      await new Promise((r) => setTimeout(r, 10))
      mode = "ok"
      expect(await t.refresh("s", "/x.jsonl", since)).toBe(true)   // 同一 mtime：上次失败没提交，照读
      expect(reads).toBe(2)
      // toolActivitySince 本身抛（模拟没覆盖到的畸形形状）也兜住
      const bad = new ToolActivityTracker({ stat: async () => 1, readTail: async () => { const a: string[] = []; Object.defineProperty(a, Symbol.iterator, { value: () => { throw new Error("iter") } }); return a }, now: () => 2 })
      expect(await bad.refresh("s", "/x.jsonl", since)).toBe(false)
      await new Promise((r) => setTimeout(r, 10))
      expect(unhandled).toEqual([])
    } finally { process.off("unhandledRejection", onUnhandled) }
  })

  test("readTailAsync 与 readTail 结果一致", async () => {
    const dir = mkdtempSync(join(tmpdir(), "cc-bridge-tail-"))
    const p = join(dir, "t.jsonl")
    writeFileSync(p, "aaaa\nbbbb\ncccc\n")
    expect(await readTailAsync(p, 7)).toEqual(readTail(p, 7))
    expect(await readTailAsync(p)).toEqual(readTail(p))
    await expect(readTailAsync(join(dir, "missing"))).rejects.toThrow()
  })
})
