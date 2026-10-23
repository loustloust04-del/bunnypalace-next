// M4a 状态机单测。reducePhase / buildPhaseContentState 是纯函数，
// 但「changed=false 就不推」这条不变量活在调用方 —— 所以这里搭一个跟 hub 的
// `onLaPhaseEvent` 同形的 driver（假 scheduler 只记调用），用它断调用次数。
import { test, expect } from "bun:test"
import { reducePhase, buildPhaseContentState, evaluateLaWatchdog, loadLaPhase, runLaWatchdog, saveLaPhase, LA_DETAIL_MAX, type LaPhaseEvent, type LaPhaseSnapshot, type LaPhaseStore } from "./live-activity-phase.ts"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { type CCActivityState } from "./activity-state.ts"
import { type LaPreview } from "./live-activity-tokens.ts"

/// 三条记录：同一 session 两台设备（一台 full 一台 hidden）+ 另一个 session 一台。
const RECORDS: Array<{ activityId: string; session_name: string; preview: LaPreview }> = [
  { activityId: "act-full", session_name: "mp-cc", preview: "full" },
  { activityId: "act-hidden", session_name: "mp-cc", preview: "hidden" },
  { activityId: "act-other", session_name: "mp-cc-2", preview: "full" },
]

function makeDriver() {
  const sent: Array<{ activityId: string; priority: 5 | 10; contentState: CCActivityState }> = []
  const phases = new Map<string, LaPhaseSnapshot>()
  let seq = 0
  /// 与 hub.ts 的 onLaPhaseEvent 同形（reduce → 存快照 → changed 才 fan-out）。
  function fire(sessionName: string, ev: LaPhaseEvent, now: number): LaPhaseSnapshot {
    const { next, changed } = reducePhase(phases.get(sessionName), ev, now, () => `r-${now}-${++seq}`)
    phases.set(sessionName, next)
    if (!changed) return next
    for (const r of RECORDS) {
      if (r.session_name !== sessionName) continue
      sent.push({ activityId: r.activityId, priority: 10, contentState: buildPhaseContentState(next, undefined, r.preview) })
    }
    return next
  }
  return { fire, sent, phases }
}

test("send → ask_pre → ask_post → reply：四态依次到位，run_id 全程不变，since_unix 只在 send 设一次", () => {
  const d = makeDriver()
  const a = d.fire("mp-cc", { kind: "send" }, 1_756_472_400)
  expect(a.phase).toBe("working")
  expect(a.since_unix).toBe(1_756_472_400)
  expect(a.run_id).toMatch(/^r-1756472400-\d+$/)   // golden 的 r-1756472400-3 同形
  const runId = a.run_id

  const b = d.fire("mp-cc", { kind: "ask_pre", detail: "要不要现在装包？" }, 1_756_472_410)
  expect(b.phase).toBe("waiting")
  expect(b.detail).toBe("要不要现在装包？")
  expect(b.run_id).toBe(runId)
  expect(b.since_unix).toBe(1_756_472_400)

  const c = d.fire("mp-cc", { kind: "ask_post" }, 1_756_472_420)
  expect(c.phase).toBe("working")
  expect(c.detail).toBeUndefined()
  expect(c.run_id).toBe(runId)
  expect(c.since_unix).toBe(1_756_472_400)

  const e = d.fire("mp-cc", { kind: "reply" }, 1_756_472_430)
  expect(e.phase).toBe("done")
  expect(e.detail).toBeUndefined()
  expect(e.run_id).toBe(runId)
  expect(e.since_unix).toBe(1_756_472_400)

  // 四次跳变 × 该 session 的两个 activity
  expect(d.sent.length).toBe(8)
  expect(d.sent.map(s => s.contentState.phase)).toEqual(
    ["working", "working", "waiting", "waiting", "working", "working", "done", "done"],
  )
})

test("done latch 之后再 send：新 run_id + 新 since_unix（D5 每轮重置）", () => {
  const d = makeDriver()
  const a = d.fire("mp-cc", { kind: "send" }, 1_000)
  d.fire("mp-cc", { kind: "reply" }, 1_010)
  const b = d.fire("mp-cc", { kind: "send" }, 2_000)
  expect(b.phase).toBe("working")
  expect(b.since_unix).toBe(2_000)
  expect(b.run_id).not.toBe(a.run_id)
})

test("waiting 时 reply 到达且 pending 未清 → 仍 waiting（waiting > done latch），不产生新推送", () => {
  const d = makeDriver()
  d.fire("mp-cc", { kind: "send" }, 1_000)
  d.fire("mp-cc", { kind: "ask_pre", detail: "继续吗？" }, 1_010)
  const before = d.sent.length
  const r = d.fire("mp-cc", { kind: "reply", pendingRemains: true }, 1_020)
  expect(r.phase).toBe("waiting")
  expect(r.detail).toBe("继续吗？")        // 题面不能被 reply 抹掉
  expect(d.sent.length).toBe(before)       // changed=false → 不推
  // pending 清干净后再来的 reply 才落 done
  const r2 = d.fire("mp-cc", { kind: "reply", pendingRemains: false }, 1_030)
  expect(r2.phase).toBe("done")
  expect(d.sent.length).toBe(before + 2)
})

test("ask_pre 的 detail：多行取首个非空行、trim、截到 80", () => {
  const d = makeDriver()
  const multi = d.fire("mp-cc", { kind: "ask_pre", detail: "\n   要装到哪台机器？   \n第二行不要\n" }, 1_000)
  expect(multi.detail).toBe("要装到哪台机器？")

  const d2 = makeDriver()
  const long = d2.fire("mp-cc", { kind: "ask_pre", detail: "题".repeat(200) }, 1_000)
  expect(long.detail!.length).toBe(LA_DETAIL_MAX)

  const d3 = makeDriver()
  expect(d3.fire("mp-cc", { kind: "ask_pre", detail: "   \n  \n" }, 1_000).detail).toBeUndefined()
  expect(d3.fire("mp-cc-2", { kind: "ask_pre" }, 1_000).detail).toBeUndefined()
})

test("两个 session 各自独立：A 的事件不动 B 的快照，也不推到 B 的 activity", () => {
  const d = makeDriver()
  d.fire("mp-cc", { kind: "send" }, 1_000)
  d.fire("mp-cc", { kind: "ask_pre", detail: "A 的题" }, 1_010)
  const b = d.fire("mp-cc-2", { kind: "send" }, 1_020)

  expect(d.phases.get("mp-cc")!.phase).toBe("waiting")
  expect(d.phases.get("mp-cc-2")!.phase).toBe("working")
  expect(b.run_id).not.toBe(d.phases.get("mp-cc")!.run_id)
  expect(d.sent.filter(s => s.activityId === "act-other").length).toBe(1)
  expect(d.sent.filter(s => s.activityId === "act-full").length).toBe(2)
})

test("changed=false（重复 ask_post）→ 一次 enqueue 都不发", () => {
  const d = makeDriver()
  d.fire("mp-cc", { kind: "send" }, 1_000)
  d.fire("mp-cc", { kind: "ask_pre", detail: "?" }, 1_010)
  d.fire("mp-cc", { kind: "ask_post" }, 1_020)
  const before = d.sent.length
  d.fire("mp-cc", { kind: "ask_post" }, 1_030)
  d.fire("mp-cc", { kind: "ask_post" }, 1_040)
  expect(d.sent.length).toBe(before)
})

test("preview 决定 detail 进不进 payload：同 session 两台设备一台看得见一台看不见", () => {
  const d = makeDriver()
  d.fire("mp-cc", { kind: "send" }, 1_000)
  d.sent.length = 0
  d.fire("mp-cc", { kind: "ask_pre", detail: "要不要现在装包？" }, 1_010)
  const full = d.sent.find(s => s.activityId === "act-full")!
  const hidden = d.sent.find(s => s.activityId === "act-hidden")!
  expect(full.contentState.detail).toBe("要不要现在装包？")
  expect("detail" in hidden.contentState).toBe(false)
  expect(hidden.contentState.phase).toBe("waiting")   // 隐私只藏正文，不藏状态
})

test("buildPhaseContentState：用量缺席就不落键（岛上显示 --），updated_unix 跟快照走", () => {
  const snap: LaPhaseSnapshot = { phase: "working", since_unix: 900, run_id: "r-900-1", updated_unix: 950 }
  const bare = buildPhaseContentState(snap, undefined, "full")
  expect(Object.keys(bare).sort()).toEqual(["phase", "run_id", "since_unix", "updated_unix"])
  const withUsage = buildPhaseContentState(snap, { model: "opus", ctx: 42, five_hour: 7, seven_day: 8 }, "full")
  expect(withUsage.model).toBe("opus")
  expect(withUsage.ctx).toBe(42)
  expect(withUsage.updated_unix).toBe(950)
})

// ── M4b ①：看门狗（纯函数，now/mtime/timeout 全注入）──

function workingSnap(o: Partial<LaPhaseSnapshot> = {}): LaPhaseSnapshot {
  return { phase: "working", since_unix: 1_000, run_id: "r-1000-1", updated_unix: 1_000, last_progress_at: 1_000, ...o }
}

test("看门狗：mtime 前进 → progress，last_progress_at 推到 now，不判超时", () => {
  const d = evaluateLaWatchdog(
    [{ session: "sA", snap: workingSnap({ last_mtime_unix: 1_000 }), mtimeUnix: 5_000 }],
    9_000,
    1_800,
  )
  expect(d.length).toBe(1)
  expect(d[0]!.kind).toBe("progress")
  const next = (d[0] as { next: LaPhaseSnapshot }).next
  expect(next.last_progress_at).toBe(9_000)
  expect(next.last_mtime_unix).toBe(5_000)
  expect(next.phase).toBe("working")
})

test("看门狗：mtime 不动且超时 → timeout，落 done latch（不 end）", () => {
  const d = evaluateLaWatchdog(
    [{ session: "sA", snap: workingSnap({ last_mtime_unix: 5_000, last_progress_at: 5_000 }), mtimeUnix: 5_000 }],
    7_000,
    1_800,
  )
  expect(d.length).toBe(1)
  expect(d[0]!.kind).toBe("timeout")
  expect((d[0] as { idleSec: number }).idleSec).toBe(2_000)
  const next = (d[0] as { next: LaPhaseSnapshot }).next
  expect(next.phase).toBe("done")
  expect(next.updated_unix).toBe(7_000)
  expect(next.run_id).toBe("r-1000-1")     // 同一轮，不换 run_id
  expect(next.since_unix).toBe(1_000)
})

// K3 审查 R1-2：异步 stat 后的看门狗
function watchdogRig(snaps: Record<string, LaPhaseSnapshot>) {
  const s = { clock: 0, mtimes: {} as Record<string, number>, onStat: {} as Record<string, () => void>, applied: [] as string[], stats: 0 }
  const io = {
    snap: (x: string) => snaps[x],
    mtime: async (x: string) => { s.stats++; s.onStat[x]?.(); return s.mtimes[x] },
    now: () => s.clock,
    apply: (d: { session: string; kind: string; next?: LaPhaseSnapshot }) => { s.applied.push(`${d.session}:${d.kind}`); if (d.next) snaps[d.session] = d.next },
  }
  return { s, io }
}

test("看门狗（异步）：A 的采样不被 B 的慢 stat 拖到更晚时刻判超时", async () => {
  const snaps = { sA: workingSnap({ last_mtime_unix: 5_000, last_progress_at: 5_000 }), sB: workingSnap({ last_mtime_unix: 5_000, last_progress_at: 5_000 }) }
  const { s, io } = watchdogRig(snaps)
  s.clock = 6_799   // A 闲 1799s，没到 1800
  s.mtimes = { sA: 5_000, sB: 6_000 }
  // B 的 stat 慢了 2 秒，这期间 A 又写了
  s.onStat.sB = () => { s.clock += 2; s.mtimes.sA = 6_800 }
  expect(await runLaWatchdog(["sA", "sB"], io, 1_800)).toBe(0)
  expect(s.applied).toEqual(["sB:progress"])
  expect(snaps.sA.phase).toBe("working")
})

test("看门狗（异步）：判超时前再 stat 一次，期间写过就只记 progress；确认还是不动才落 done", async () => {
  const snaps = { sA: workingSnap({ last_mtime_unix: 5_000, last_progress_at: 5_000 }), sC: workingSnap({ last_mtime_unix: 5_000, last_progress_at: 5_000 }) }
  const { s, io } = watchdogRig(snaps)
  s.clock = 7_000
  s.mtimes = { sA: 5_000, sC: 5_000 }
  let firstA = true
  s.onStat.sA = () => { if (firstA) firstA = false; else s.mtimes.sA = 7_000 }   // 第二次 stat 时它已经写了
  expect(await runLaWatchdog(["sA", "sC"], io, 1_800)).toBe(1)
  expect(s.applied).toEqual(["sA:progress", "sC:timeout"])
  expect(snaps.sA.phase).toBe("working")
  expect(snaps.sC.phase).toBe("done")
  expect(s.stats).toBe(4)
  // stat 抛了按拿不到 transcript 处理，不 reject
  const r = watchdogRig({ sX: workingSnap() })
  r.io.mtime = async () => { throw new Error("EIO") }
  expect(await runLaWatchdog(["sX"], r.io, 1_800)).toBe(0)
  expect(r.s.applied).toEqual(["sX:unknown"])
})

test("看门狗：mtime 不动但没到阈值 → 什么都不做", () => {
  expect(evaluateLaWatchdog(
    [{ session: "sA", snap: workingSnap({ last_mtime_unix: 5_000, last_progress_at: 5_000 }), mtimeUnix: 5_000 }],
    6_000,
    1_800,
  )).toEqual([])
})

test("看门狗：拿不到 transcript（codex）→ unknown，永不判超时", () => {
  const d = evaluateLaWatchdog(
    [{ session: "mp-codex-1", snap: workingSnap({ last_progress_at: 0 }) }],
    999_999,
    1_800,
  )
  expect(d).toEqual([{ session: "mp-codex-1", kind: "unknown" }])
})

test("看门狗：waiting / done / idle 一概不计超时（等人是合法的长时间）", () => {
  const stale = { since_unix: 1_000, run_id: "r-1000-1", updated_unix: 1_000, last_progress_at: 1_000, last_mtime_unix: 1_000 }
  const d = evaluateLaWatchdog([
    { session: "w", snap: { phase: "waiting", detail: "选哪个？", ...stale }, mtimeUnix: 1_000 },
    { session: "d", snap: { phase: "done", ...stale }, mtimeUnix: 1_000 },
    { session: "i", snap: { phase: "idle", updated_unix: 1_000 }, mtimeUnix: 1_000 },
  ], 999_999, 1_800)
  expect(d).toEqual([])
})

test("send / ask_post 把 last_progress_at 推到 now（看门狗的起算点）", () => {
  const a = reducePhase(undefined, { kind: "send" }, 100, () => "r-100-1").next
  expect(a.last_progress_at).toBe(100)
  const b = reducePhase(a, { kind: "ask_pre", detail: "?" }, 200, () => "x").next
  expect(b.last_progress_at).toBe(100)                 // 等人期间不推进
  const c = reducePhase(b, { kind: "ask_post" }, 300, () => "x").next
  expect(c.last_progress_at).toBe(300)                 // 答完继续跑 = 一次真实进展
  expect(c.run_id).toBe("r-100-1")
})

// ── M4b ②：phase 快照落盘 ──

test("loadLaPhase / saveLaPhase 往返；缺文件、坏 JSON、坏条目都当空/丢掉，不抛", () => {
  const dir = mkdtempSync(join(tmpdir(), "la-phase-"))
  const path = join(dir, "la-phase.json")
  expect(loadLaPhase(path)).toEqual({})                       // 缺文件

  const store: LaPhaseStore = {
    "mp-cc-a": { phase: "working", since_unix: 10, run_id: "r-10-1", updated_unix: 10, last_progress_at: 10, last_mtime_unix: 9 },
    "mp-cc-b": { phase: "waiting", detail: "选哪个？", updated_unix: 20 },
  }
  saveLaPhase(path, store)
  expect(loadLaPhase(path)).toEqual(store)

  writeFileSync(path, "{ not json")
  expect(loadLaPhase(path)).toEqual({})                       // 坏 JSON

  writeFileSync(path, JSON.stringify({
    good: { phase: "done", updated_unix: 1 },
    bad_phase: { phase: "bogus", updated_unix: 1 },
    bad_ts: { phase: "done", updated_unix: "1" },
    nul: null,
  }))
  expect(Object.keys(loadLaPhase(path))).toEqual(["good"])
})

test("seen（终端 attach）：done → idle，保留本轮 run_id；别的 phase 不动", () => {
  const d = makeDriver()
  d.fire("mp-cc", { kind: "send" }, 100)
  const done = d.fire("mp-cc", { kind: "reply" }, 200)
  expect(done.phase).toBe("done")
  const sentBefore = d.sent.length
  const seen = d.fire("mp-cc", { kind: "seen" }, 300)
  expect(seen.phase).toBe("idle")
  expect(seen.run_id).toBe(done.run_id)
  expect(seen.updated_unix).toBe(300)
  expect(d.sent.length).toBeGreaterThan(sentBefore)

  const working = d.fire("mp-cc", { kind: "send" }, 400)
  const sentWorking = d.sent.length
  expect(d.fire("mp-cc", { kind: "seen" }, 500)).toEqual(working)
  expect(d.sent.length).toBe(sentWorking)

  d.fire("mp-cc-2", { kind: "send" }, 100)
  const waiting = d.fire("mp-cc-2", { kind: "ask_pre", detail: "选哪个？" }, 200)
  expect(d.fire("mp-cc-2", { kind: "seen" }, 300)).toEqual(waiting)
})
