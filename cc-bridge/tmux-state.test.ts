import { describe, expect, test } from "bun:test"
import { TmuxState, parsePaneTitles, parsePaneMeta, TMUX_PANES_ARGS } from "./tmux-state.ts"

function harness(initial: string | null) {
  let clock = 1_000
  let raw: string | null = initial
  let calls = 0
  let release: (() => void) | null = null
  let gate = false
  const st = new TmuxState({
    now: () => clock,
    staleMs: 10_000,
    fetch: async () => {
      calls++
      if (gate) await new Promise<void>(r => { release = r })
      return raw
    },
  })
  return {
    st,
    tick: (ms: number) => { clock += ms },
    set: (r: string | null) => { raw = r },
    calls: () => calls,
    hold: () => { gate = true },
    open: () => { gate = false; release?.() },
  }
}

describe("TmuxState", () => {
  test("没刷新过 → undefined（调用方回退同步查）", () => {
    const h = harness("a\tt1\n")
    expect(h.st.has("a")).toBeUndefined()
    expect(h.st.list()).toBeUndefined()
    expect(h.st.paneTitles(["a"])).toBeUndefined()
  })

  test("快照命中 / 未命中 / 标题取第一个 pane", async () => {
    const h = harness("a\tt1\na\tt2\nb\t\n")
    await h.st.refresh()
    expect(h.st.has("a")).toBe(true)
    expect(h.st.has("zz")).toBe(false)
    expect(h.st.list()!.sort()).toEqual(["a", "b"])
    expect(h.st.paneTitles(["a", "b", "zz"])).toEqual(new Map([["a", "t1"], ["b", ""]]))
  })

  test("过期 → undefined；拿不到（null）不覆盖旧快照", async () => {
    const h = harness("a\tt\n")
    await h.st.refresh()
    h.set(null)
    h.tick(5_000)
    await h.st.refresh()
    expect(h.st.has("a")).toBe(true)
    h.tick(6_000)
    expect(h.st.has("a")).toBeUndefined()
  })

  test("没有 tmux server（空串）= 空表，不是过期", async () => {
    const h = harness("")
    await h.st.refresh()
    expect(h.st.has("a")).toBe(false)
    expect(h.st.list()).toEqual([])
  })

  test("spawn 后立刻可见，哪怕快照过期；之后开始的轮询回来才以快照为准", async () => {
    const h = harness("")
    h.st.noteSpawned("new")
    expect(h.st.has("new")).toBe(true)
    await h.st.refresh()   // 这次轮询开始时刻 == 记账时刻（同一 clock）→ 不作废
    expect(h.st.has("new")).toBe(true)
    h.tick(1)
    await h.st.refresh()   // 之后开始的轮询：tmux 里确实没有 → 以快照为准
    expect(h.st.has("new")).toBe(false)
  })

  test("spawn 期间在途的旧轮询回来不抹掉新会话", async () => {
    const h = harness("")
    h.hold()
    const p = h.st.refresh()       // 旧轮询在途（看不到 new）
    h.tick(10)
    h.st.noteSpawned("new")
    h.open(); await p
    expect(h.st.has("new")).toBe(true)
    expect(h.st.list()).toContain("new")
  })

  test("kill 后立刻不可见，标题也不给", async () => {
    const h = harness("a\tt\n")
    await h.st.refresh()
    h.tick(1)
    h.st.noteKilled("a")
    expect(h.st.has("a")).toBe(false)
    expect(h.st.list()).toEqual([])
    expect(h.st.paneTitles(["a"])).toEqual(new Map())
  })

  test("lastKnown：过期也给最后一次见到的；从没拿到过 → undefined", async () => {
    const h = harness("a\tt\n")
    expect(h.st.lastKnown("a")).toBeUndefined()
    await h.st.refresh()
    h.tick(60_000)
    expect(h.st.has("a")).toBeUndefined()
    expect(h.st.lastKnown("a")).toBe(true)
    expect(h.st.lastKnown("zz")).toBe(false)
    h.st.noteKilled("a")
    expect(h.st.lastKnown("a")).toBe(false)
  })

  test("K1-4 allowStale：过期也给最后一份快照（叠加层照算）；从没拿到过仍是 undefined", async () => {
    const h = harness("a\tt1\t5\t/x\nb\tt2\n")
    expect(h.st.list(true)).toBeUndefined()
    expect(h.st.paneTitles(["a"], true)).toBeUndefined()
    await h.st.refresh()
    h.tick(60_000)
    expect(h.st.list()).toBeUndefined()
    expect(h.st.paneTitles(["a"])).toBeUndefined()
    h.st.noteKilled("b")
    h.st.noteSpawned("c")
    expect(h.st.list(true)!.sort()).toEqual(["a", "c"])
    expect(h.st.paneTitles(["a", "b"], true)).toEqual(new Map([["a", "t1"]]))
    expect(h.st.paneMeta(["a"], true)).toEqual(new Map([["a", { activitySec: 5, path: "/x" }]]))
  })

  test("在途时再 refresh 复用同一次，不叠", async () => {
    const h = harness("a\tt\n")
    h.hold()
    const p1 = h.st.refresh()
    const p2 = h.st.refresh()
    expect(p1).toBe(p2)
    h.open(); await p1
    expect(h.calls()).toBe(1)
  })
})

// 10-10：launchd 起的 hub 没 LANG，不带 -u 时 tmux 把 tab 换成 _ → 会话表空 → hub 以为一个会话都没有
test("会话表的 tmux 调用强制 UTF-8（-u）", () => {
  expect(TMUX_PANES_ARGS[0]).toBe("-u")
  expect(parsePaneTitles("mp-cc_title\n").size).toBe(0)   // 没 -u 时的样子：tab 变 _，一条都解析不出
})

test("parsePaneTitles 跳过空行 / 无 tab 行", () => {
  expect(parsePaneTitles("a\tx\n\nnotab\n\tnoname\n")).toEqual(new Map([["a", "x"]]))
})

test("#046：快照带窗口活动秒 + 当前目录；标题里有 tab 不错位；旧两段格式没有 meta", async () => {
  const raw = "mp-win-1\tmimiair\t1760000000\t/Users/x/proj\nmp-win-2\ta\tb\t1760000005\t/tmp\nold\ttitle\n"
  expect(parsePaneTitles(raw)).toEqual(new Map([["mp-win-1", "mimiair"], ["mp-win-2", "a\tb"], ["old", "title"]]))
  expect(parsePaneMeta(raw)).toEqual(new Map([
    ["mp-win-1", { activitySec: 1760000000, path: "/Users/x/proj" }],
    ["mp-win-2", { activitySec: 1760000005, path: "/tmp" }],
  ]))
  const st = new TmuxState({ fetch: async () => raw })
  await st.refresh()
  expect(st.paneMeta(["mp-win-1", "old"])).toEqual(new Map([["mp-win-1", { activitySec: 1760000000, path: "/Users/x/proj" }]]))
  st.noteKilled("mp-win-1")
  expect(st.paneMeta(["mp-win-1"])).toEqual(new Map())
})
