// Live Activity 周期推送调度器（M3b）。纯逻辑，全部外部依赖注入 → 单测不碰网络/文件系统。
//
// 三条不变量，都是被 APNs 的行为逼出来的：
//   1. 每 session 每轮只算一次用量再 fan-out —— readTranscriptUsage 是同步读 512KB 尾部，
//      按 activity 数重复读会阻塞 hub 的终端流/agora/keepalive。
//   2. 每个 activity 一条串行队列 + 单调递增 timestamp —— APNs 允许重排，低优先级的数字
//      刷新和高优先级的状态跳变（M4a）会并发，岛上必须以「后发的赢」收敛。
//   3. inFlight 防重入 —— 一轮还没发完就被下一个 interval 叫醒时直接跳过，不叠加。
import { type APNsResult, type LaEvent } from "./apns.ts"
import { type CCPhase, validateContentState } from "./activity-state.ts"
import { buildPhaseContentState } from "./live-activity-phase.ts"
import { type LaUpdateRecord } from "./live-activity-tokens.ts"
import { activityStartedAt, needsRollover } from "./live-activity-start.ts"

/// 一个 session 一轮的用量快照。codex session 拿不到 transcript → model/ctx 缺席（岛上显示 `--`），
/// 但 5h/7d 来自 statusline 落盘、与 session 无关，照发。
export interface LaUsageSnapshot {
  model?: string
  ctx?: number
  five_hour?: number
  seven_day?: number
}

/// phase/since_unix/run_id/detail 的真相源是 M4a 的状态机，本模块只读不猜。
export interface LaPhaseSnapshot {
  phase: CCPhase
  since_unix?: number
  run_id?: string
  /// 题面首行（只有 waiting 期间有值）。进不进 payload 由**每条记录**的 preview 决定 ——
  /// M4b：周期刷新以前一律不填 detail，等于每 3 分钟把 waiting 的题面从岛上抹一次。
  detail?: string
}

export interface LaSchedulerDeps {
  /// unix 秒
  now(): number
  listUpdateRecords(): Array<{ activityId: string; record: LaUpdateRecord }>
  usageFor(sessionName: string): LaUsageSnapshot
  phaseFor(sessionName: string): LaPhaseSnapshot
  send(record: LaUpdateRecord, ev: LaEvent, opts: { priority: 5 | 10; timestampUnix: number }): Promise<APNsResult>
  removeRecord(activityId: string): void
  /// M5 ⑤：旧岛 end 掉之后，对该 session 的每条 push-to-start 记录起一个新岛。
  /// 本模块不认识 start 记录（它按 activity 排队，start 按 install 排），所以只发号施令。
  remoteStart(sessionName: string): void
  /// M4b2 ⑤：换岛前问一句「有替补吗」。start 记录按 **install** 存、不按 session 分，
  /// 所以「该 session 的 start 记录」在现协议下等价于「有没有任何 start 记录」（同 shouldRemoteStart）。
  hasStartRecord(): boolean
  log(line: string): void
}

export interface LaSchedulerOpts {
  intervalMs: number
  /// stale-date 在「下一次预期推送时刻」之后再留的宽限，防网络抖动导致岛提前变灰。
  graceSec: number
  /// M5 ⑤：activity 活到这个岁数（秒）就换岛。默认 27000（7.5h），留 30 分钟余量给
  /// 系统的 8h 硬上限 —— 撞上去岛会自己消失，我们就再也没有机会体面收尾。
  rolloverSec: number
}

export interface LaScheduler {
  tick(): Promise<void>
  /// 也是 M4a 状态跳变的入口：同一条串行队列里塞 priority 10 的 update/end，
  /// 与本模块的周期刷新共享单调 timestamp，不会被 APNs 重排成「旧状态覆盖新状态」。
  enqueueState(activityId: string, ev: LaEvent, priority: 5 | 10): Promise<APNsResult | undefined>
  stop(): void
}

/// 这些 = 设备/token 已经死了，留着只会每轮白发一次。跟 alert 路径同语义，但只碰 LA store。
const DEAD_TOKEN_REASONS = new Set(["BadDeviceToken", "Unregistered", "ExpiredToken", "DeviceTokenNotForTopic"])

export function createLaScheduler(deps: LaSchedulerDeps, opts: LaSchedulerOpts): LaScheduler {
  const chains = new Map<string, Promise<unknown>>()
  const lastTs = new Map<string, number>()
  let inFlight = false
  let stopped = false

  async function doSend(
    activityId: string,
    record: LaUpdateRecord,
    ev: LaEvent,
    priority: 5 | 10,
  ): Promise<APNsResult | undefined> {
    if (stopped) return undefined
    // 单调：APNs 用 aps.timestamp 判新旧，同秒内的两条会被岛当成同一时刻。
    const timestampUnix = Math.max(deps.now(), (lastTs.get(activityId) ?? 0) + 1)
    lastTs.set(activityId, timestampUnix)
    const tail = `activity=${activityId} session=${record.session_name} env=${record.env} prio=${priority}`
    try {
      const r = await deps.send(record, ev, { priority, timestampUnix })
      deps.log(`[hub] la push ${tail} status=${r.status} reason=${r.reason ?? "-"}`)
      if (r.status === 410 || (r.reason !== undefined && DEAD_TOKEN_REASONS.has(r.reason))) {
        deps.removeRecord(activityId)
        chains.delete(activityId)
        lastTs.delete(activityId)
        deps.log(`[hub] la push ${tail} → record removed (${r.reason ?? r.status})`)
      }
      return r
    } catch (e: any) {
      // LaPayloadTooLargeError（4KB 防线）走这儿。本 lane 不发 detail，理论上到不了，
      // 但一条发不出去不能掀了整轮 fan-out，更不能把 hub 顶层 uncaught 掉。
      deps.log(`[hub] la push ${tail} status=0 reason=${e?.message ?? "send_threw"}`)
      return undefined
    }
  }

  function enqueueState(activityId: string, ev: LaEvent, priority: 5 | 10): Promise<APNsResult | undefined> {
    if (stopped) return Promise.resolve(undefined)
    const found = deps.listUpdateRecords().find((r) => r.activityId === activityId)
    if (!found) {
      deps.log(`[hub] la push activity=${activityId} skipped reason=no_record`)
      return Promise.resolve(undefined)
    }
    // 拼错一个键名 APNs 照样回 200、真机岛静默不动 —— 发出去之前拦。
    const stateErr = validateContentState(ev.contentState as unknown as Record<string, unknown>)
    if (stateErr) {
      deps.log(`[hub] la push activity=${activityId} skipped reason=${stateErr}`)
      return Promise.resolve(undefined)
    }
    const prev = chains.get(activityId) ?? Promise.resolve()
    const run = prev.then(
      () => doSend(activityId, found.record, ev, priority),
      () => doSend(activityId, found.record, ev, priority),
    )
    chains.set(activityId, run.catch(() => undefined))
    return run
  }

  async function tick(): Promise<void> {
    if (stopped || inFlight) return
    inFlight = true
    try {
      const bySession = new Map<string, Array<{ activityId: string; record: LaUpdateRecord }>>()
      for (const entry of deps.listUpdateRecords()) {
        const list = bySession.get(entry.record.session_name)
        if (list) list.push(entry)
        else bySession.set(entry.record.session_name, [entry])
      }
      const now = deps.now()
      const staleDateUnix = now + Math.round(opts.intervalMs / 1000) + opts.graceSec
      const pending: Array<Promise<unknown>> = []
      const rolling = new Set<string>()
      for (const [sessionName, entries] of bySession) {
        // 用量仍每 session 只算一次（不变量 1）；contentState 每 activity 组一次 ——
        // detail 是**每条记录**的隐私决定，一份共享的 contentState 只能一刀切成「都不发」。
        const usage = deps.usageFor(sessionName)
        const ph = deps.phaseFor(sessionName)
        for (const { activityId, record } of entries) {
          const contentState = buildPhaseContentState({ ...ph, updated_unix: now }, usage, record.preview)
          if (needsRollover(record, ph.phase, now, opts.rolloverSec)) {
            // M4b2 ⑤：没有 start 记录 = 端了旧岛没人接班，等于比系统 8h 自然死还早半小时把岛掐了。
            if (!deps.hasStartRecord()) {
              deps.log(`[hub] la rollover skipped: no start token session=${sessionName}`)
              continue
            }
            // 记录必须跟着 end 一起删：留着的话下一个 tick 会对同一条再 end 一次、再起一个岛。
            deps.log(`[hub] la rollover activity=${activityId} session=${sessionName} age=${now - activityStartedAt(record)}s`)
            pending.push(enqueueState(activityId, { event: "end", contentState, dismissalDateUnix: now }, 10))
            deps.removeRecord(activityId)
            rolling.add(sessionName)
            continue
          }
          pending.push(enqueueState(activityId, { event: "update", contentState, staleDateUnix }, 5))
        }
      }
      await Promise.all(pending)
      // 先 end 再 start：反过来会有一瞬间两个岛（M5 的单 activity 互斥说了不许）。
      for (const sessionName of rolling) deps.remoteStart(sessionName)
    } finally {
      inFlight = false
    }
  }

  return {
    tick,
    enqueueState,
    stop() {
      stopped = true
      chains.clear()
      lastTs.clear()
    },
  }
}
