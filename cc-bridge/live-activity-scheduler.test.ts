import { test, expect } from "bun:test"
import { createLaScheduler, type LaPhaseSnapshot, type LaSchedulerDeps, type LaUsageSnapshot } from "./live-activity-scheduler.ts"
import { buildLiveActivityPayload, type APNsResult, type LaEvent } from "./apns.ts"
import { type LaPreview, type LaUpdateRecord } from "./live-activity-tokens.ts"

function rec(session: string, preview: LaPreview = "hidden", startedAtMs?: number): LaUpdateRecord {
  return {
    token: "a".repeat(64),
    session_name: session,
    install_id: "install-1",
    env: "sandbox",
    preview,
    ...(startedAtMs !== undefined ? { started_at: startedAtMs } : {}),
    updated_at: 0,
  }
}

interface SentCall {
  record: LaUpdateRecord
  ev: LaEvent
  priority: 5 | 10
  timestampUnix: number
}

function harness(o: {
  records?: Array<[string, string, LaPreview?, number?]>   // [activityId, sessionName, preview?, started_at(ms)?]
  phase?: LaPhaseSnapshot
  usage?: (s: string) => LaUsageSnapshot
  result?: APNsResult
  send?: (call: SentCall) => Promise<APNsResult>
  intervalMs?: number
  graceSec?: number
  rolloverSec?: number
  onRemoteStart?: (sessionName: string) => void
  hasStartRecord?: boolean
  now?: number
} = {}) {
  const records = new Map<string, LaUpdateRecord>(
    (o.records ?? [["act-1", "mp-cc-a"]]).map(([id, s, p, startedAtMs]) => [id, rec(s, p, startedAtMs)]),
  )
  const sent: SentCall[] = []
  const usageCalls: string[] = []
  const removed: string[] = []
  const logs: string[] = []
  const started: string[] = []
  const deps: LaSchedulerDeps = {
    now: () => o.now ?? 1_000,
    listUpdateRecords: () => [...records].map(([activityId, record]) => ({ activityId, record })),
    usageFor: (s) => { usageCalls.push(s); return o.usage ? o.usage(s) : { model: "Opus", ctx: 42, five_hour: 7, seven_day: 8 } },
    phaseFor: () => o.phase ?? { phase: "idle" },
    send: (record, ev, opts) => {
      const call: SentCall = { record, ev, priority: opts.priority, timestampUnix: opts.timestampUnix }
      sent.push(call)
      if (o.send) return o.send(call)
      return Promise.resolve(o.result ?? { ok: true, status: 200 })
    },
    removeRecord: (id) => { removed.push(id); records.delete(id) },
    hasStartRecord: () => o.hasStartRecord ?? true,
    remoteStart: (s) => { started.push(s); o.onRemoteStart?.(s) },
    log: (line) => { logs.push(line) },
  }
  const scheduler = createLaScheduler(deps, {
    intervalMs: o.intervalMs ?? 180_000,
    graceSec: o.graceSec ?? 60,
    // 默认大到永远不触发：只有 ⑤ 的用例显式调小。
    rolloverSec: o.rolloverSec ?? 27_000,
  })
  return { scheduler, sent, usageCalls, removed, logs, records, started }
}

test("每 session 只算一次用量，再 fan-out 到组内每个 activity", async () => {
  const h = harness({ records: [["a1", "sA"], ["a2", "sA"], ["a3", "sB"], ["a4", "sB"]] })
  await h.scheduler.tick()
  expect(h.usageCalls.sort()).toEqual(["sA", "sB"])
  expect(h.sent.length).toBe(4)
  expect(h.sent.every(c => c.priority === 5)).toBe(true)
  expect(h.sent.map(c => c.ev.event)).toEqual(["update", "update", "update", "update"])
})

test("同一 activity 的两次 enqueue 串行，且 timestamp 严格递增", async () => {
  let releaseFirst: (() => void) | undefined
  const gate = new Promise<void>(r => { releaseFirst = r })
  let calls = 0
  const h = harness({
    send: async () => {
      calls++
      if (calls === 1) await gate
      return { ok: true, status: 200 }
    },
  })
  const state = { phase: "idle" as const }
  const p1 = h.scheduler.enqueueState("act-1", { event: "update", contentState: state }, 5)
  const p2 = h.scheduler.enqueueState("act-1", { event: "update", contentState: state }, 10)
  await Bun.sleep(5)
  expect(h.sent.length).toBe(1)          // 第二条还没开始：队列串行
  releaseFirst!()
  await Promise.all([p1, p2])
  expect(h.sent.length).toBe(2)
  expect(h.sent[1]!.timestampUnix).toBeGreaterThan(h.sent[0]!.timestampUnix)
})

test("tick 期间再 tick 是 no-op（inFlight 防重入）", async () => {
  let releaseFirst: (() => void) | undefined
  const gate = new Promise<void>(r => { releaseFirst = r })
  const h = harness({ records: [["a1", "sA"]], send: async () => { await gate; return { ok: true, status: 200 } } })
  const first = h.scheduler.tick()
  await Bun.sleep(5)
  await h.scheduler.tick()               // 第二次：直接 return
  expect(h.sent.length).toBe(1)
  expect(h.usageCalls.length).toBe(1)
  releaseFirst!()
  await first
})

test("BadDeviceToken → 删记录；timeout → 保留", async () => {
  const dead = harness({ result: { ok: false, status: 400, reason: "BadDeviceToken" } })
  await dead.scheduler.tick()
  expect(dead.removed).toEqual(["act-1"])
  expect(dead.logs.some(l => l.includes("record removed"))).toBe(true)

  const flaky = harness({ result: { ok: false, status: 0, reason: "timeout" } })
  await flaky.scheduler.tick()
  expect(flaky.removed).toEqual([])
})

test("410 也删（Apple 用状态码而不是 reason 报废 token 的那条路）", async () => {
  const h = harness({ result: { ok: false, status: 410, reason: "Unregistered" } })
  await h.scheduler.tick()
  expect(h.removed).toEqual(["act-1"])
})

test("codex session（用量为空）照发，state 里 model/ctx 缺席", async () => {
  const h = harness({ records: [["a1", "mp-codex-1"]], usage: () => ({ five_hour: 3, seven_day: 4 }) })
  await h.scheduler.tick()
  expect(h.sent.length).toBe(1)
  const s = h.sent[0]!.ev.contentState
  expect(s.ctx).toBeUndefined()
  expect(s.model).toBeUndefined()
  expect(s.five_hour).toBe(3)
  expect(s.seven_day).toBe(4)
})

test("stale-date = now + interval + grace；updated_unix = 本次计算时刻", async () => {
  const h = harness({ now: 5_000, intervalMs: 180_000, graceSec: 60 })
  await h.scheduler.tick()
  const ev = h.sent[0]!.ev
  expect(ev.event).toBe("update")
  expect(ev.event === "update" ? ev.staleDateUnix : undefined).toBe(5_000 + 180 + 60)
  expect(ev.contentState.updated_unix).toBe(5_000)
})

// M4b 改写：M3b 原用例是「detail 永远不进 payload」，理由是隐私开关的消费方还在 M4a。
// M4a 落地后 detail 由**每条记录**的 preview 决定，原不变量已被取代（周期刷新一律不发
// detail = 每 3 分钟把 waiting 的题面从岛上抹一次，M4a 报告 §7 第 1 条）。
test("周期刷新按每条记录的 preview 决定 detail：hidden 无、full 有", async () => {
  const h = harness({
    records: [["a-hidden", "sA", "hidden"], ["a-full", "sA", "full"]],
    phase: { phase: "waiting", since_unix: 900, run_id: "r-900-1", detail: "选哪个分支？" },
  })
  await h.scheduler.tick()
  expect(h.usageCalls).toEqual(["sA"])            // 用量仍每 session 只算一次
  const hidden = h.sent.find(c => c.record.preview === "hidden")!
  const full = h.sent.find(c => c.record.preview === "full")!
  expect("detail" in hidden.ev.contentState).toBe(false)
  expect(buildLiveActivityPayload(hidden.ev, hidden.timestampUnix)).not.toContain("detail")
  expect(full.ev.contentState.detail).toBe("选哪个分支？")
  expect(full.ev.contentState.phase).toBe("waiting")
  expect(full.ev.contentState.since_unix).toBe(900)
  expect(full.ev.contentState.run_id).toBe("r-900-1")
})

test("非法 contentState 只 log + skip，不发不抛", async () => {
  const h = harness()
  const r = await h.scheduler.enqueueState(
    "act-1",
    { event: "update", contentState: { phase: "bogus" as never } },
    5,
  )
  expect(r).toBeUndefined()
  expect(h.sent.length).toBe(0)
  expect(h.logs.some(l => l.includes("bad_phase"))).toBe(true)
})

test("未注册的 activity_id → skip，不发", async () => {
  const h = harness()
  const r = await h.scheduler.enqueueState("nope", { event: "update", contentState: { phase: "idle" } }, 5)
  expect(r).toBeUndefined()
  expect(h.sent.length).toBe(0)
  expect(h.logs.some(l => l.includes("no_record"))).toBe(true)
})

test("send 抛异常（如 4KB 超限）被吞：本轮 skip，其它 activity 照发", async () => {
  const h = harness({
    records: [["a1", "sA"], ["a2", "sA"]],
    send: async (call) => {
      if (call.record === undefined) throw new Error("unreachable")
      if (h.sent.length === 1) throw new Error("live activity payload 5000 bytes > 4096 (APNs 上限)")
      return { ok: true, status: 200 }
    },
  })
  await h.scheduler.tick()
  expect(h.sent.length).toBe(2)
  expect(h.removed).toEqual([])
  expect(h.logs.some(l => l.includes("4096"))).toBe(true)
})

test("stop() 之后 tick / enqueue 都不再发（定时器清了但队列里还有排队的情况）", async () => {
  const h = harness()
  h.scheduler.stop()
  await h.scheduler.tick()
  expect(await h.scheduler.enqueueState("act-1", { event: "update", contentState: { phase: "idle" } }, 5)).toBeUndefined()
  expect(h.sent.length).toBe(0)
})

// ── M5 ⑤：8h 滚动换岛 ──
// 时间轴：记录 started_at=0ms，deps.now()=1000s → 岁数 1000s。阈值调到秒级来验。

test("过阈值 + working → end(带 dismissal-date, prio 10) + 删记录 + 该 session 起新岛", async () => {
  const h = harness({
    records: [["act-1", "sA", "hidden", 0]],
    phase: { phase: "working" },
    rolloverSec: 100,
  })
  await h.scheduler.tick()
  expect(h.sent.length).toBe(1)
  expect(h.sent[0]!.ev.event).toBe("end")
  expect((h.sent[0]!.ev as { dismissalDateUnix?: number }).dismissalDateUnix).toBe(1_000)
  expect(h.sent[0]!.priority).toBe(10)
  expect(h.removed).toEqual(["act-1"])
  expect(h.started).toEqual(["sA"])
  expect(h.logs.some((l) => l.includes("la rollover") && l.includes("age=1000s"))).toBe(true)
})

test("换过之后记录已删 → 下一个 tick 不再 end，也不再起第二个岛", async () => {
  const h = harness({
    records: [["act-1", "sA", "hidden", 0]],
    phase: { phase: "working" },
    rolloverSec: 100,
  })
  await h.scheduler.tick()
  await h.scheduler.tick()
  expect(h.sent.length).toBe(1)
  expect(h.started).toEqual(["sA"])
})

test("同 session 两个岛同时到点 → 两条 end，但只起一次新岛", async () => {
  const h = harness({
    records: [["act-1", "sA", "hidden", 0], ["act-2", "sA", "full", 0]],
    phase: { phase: "working" },
    rolloverSec: 100,
  })
  await h.scheduler.tick()
  expect(h.sent.filter((c) => c.ev.event === "end").length).toBe(2)
  expect(h.started).toEqual(["sA"])
})

test("没到点 / phase 是 done → 照常周期 update，不 end 不换岛", async () => {
  const young = harness({
    records: [["act-1", "sA", "hidden", 900_000]],   // 岁数 100s
    phase: { phase: "working" },
    rolloverSec: 27_000,
  })
  await young.scheduler.tick()
  expect(young.sent[0]!.ev.event).toBe("update")
  expect(young.started).toEqual([])

  const doneOld = harness({
    records: [["act-1", "sA", "hidden", 0]],
    phase: { phase: "done" },
    rolloverSec: 100,
  })
  await doneOld.scheduler.tick()
  expect(doneOld.sent[0]!.ev.event).toBe("update")
  expect(doneOld.removed).toEqual([])
  expect(doneOld.started).toEqual([])
})

test("先 end 再 start：remoteStart 在这一轮全部推送 await 完之后才调（反过来会有一瞬两个岛）", async () => {
  const order: string[] = []
  const h = harness({
    records: [["act-1", "sA", "hidden", 0]],
    phase: { phase: "working" },
    rolloverSec: 100,
    send: async (call) => { order.push(`send:${call.ev.event}`); return { ok: true, status: 200 } },
    onRemoteStart: (s) => { order.push(`start:${s}`) },
  })
  await h.scheduler.tick()
  expect(order).toEqual(["send:end", "start:sA"])
})

// ── M4b2 ⑤：没替补就别换岛 ──
// 没有任何 push-to-start 记录时 end 掉旧岛 = 岛直接没了，比系统 8h 自然死还早半小时。

test("过阈值但没有 start 记录 → 不 end 不删记录，只 log 一行 skipped", async () => {
  const h = harness({
    records: [["act-1", "sA", "hidden", 0]],
    phase: { phase: "working" },
    rolloverSec: 100,
    hasStartRecord: false,
  })
  await h.scheduler.tick()
  expect(h.sent.length).toBe(0)
  expect(h.removed).toEqual([])
  expect(h.started).toEqual([])
  expect(h.logs.some((l) => l === "[hub] la rollover skipped: no start token session=sA")).toBe(true)
})

test("DeviceTokenNotForTopic 也删（token 跟 topic 不配，app 重连会带对的 topic 重报）", async () => {
  const h = harness({ result: { ok: false, status: 400, reason: "DeviceTokenNotForTopic" } })
  await h.scheduler.tick()
  expect(h.removed).toEqual(["act-1"])
})
