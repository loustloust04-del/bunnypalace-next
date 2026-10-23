// Live Activity 的 phase 状态机（M4a）。纯函数：不碰时钟、不碰网络、不碰 hub 状态 ——
// 事件从 hub 的四个**显式**来源进来，快照出去给 scheduler 读。
//
// 为什么不猜 transcript mtime（原 plan 的做法，两轮 codex 审后否决）：
//   假阳 —— nudge / keepalive / system 记录都会推 mtime；
//   假阴 —— 一次长工具调用期间 transcript 一个字节都不写。
// 所以 phase 只由 hub 手里已经有的四个事件驱动：send / askuser pre / askuser post / reply。
//
// 优先级 `waiting > done latch > working > idle`（2026-08-28 粟粟拍板 compactTrailing 优先「等你」）：
// reply 与 pending 问题撞车时岛上显示 waiting，不显示 done。
import { timedSyncFs } from "./block-ledger"
const { existsSync, readFileSync, writeFileSync } = timedSyncFs("la-phase ")
import { type CCActivityState, type CCPhase } from "./activity-state.ts"
import { type LaUsageSnapshot } from "./live-activity-scheduler.ts"
import { type LaPreview } from "./live-activity-tokens.ts"

export type LaPhaseEvent =
  | { kind: "send" }
  /// detail = 原始题面（可多行），由 reducer 规范化成首行 ≤80 字符。
  | { kind: "ask_pre"; detail?: string }
  | { kind: "ask_post" }
  /// pendingRemains：同一 session 还挂着别的 askuser pending（调用方先让
  /// `resolveOnReply` 清完再问）。有它才能实现 `waiting > done` 的优先级 ——
  /// 否则「回答到了但另一个问题还开着」会被打成 done，岛上把「等你」抹掉。
  | { kind: "reply"; pendingRemains?: boolean }
  /// 终端 attach（T21）：done 已被看过 → idle；别的 phase 不动。
  | { kind: "seen" }

/// `live-activity-scheduler.ts` 的同名类型是这个的只读子集（phase/since_unix/run_id），
/// 结构上兼容 —— 这份快照可以直接喂给 scheduler 的 `phaseFor`。
export interface LaPhaseSnapshot {
  phase: CCPhase
  /// 本轮开始时刻。只在 `send` 时重置（D5：每轮重置 since_unix + run_id）。
  since_unix?: number
  run_id?: string
  /// 题面首行，只有 `waiting` 期间有值。进不进 payload 由 activity 记录的 preview 决定。
  detail?: string
  updated_unix: number
  /// M4b ①：最后一次「观察到有进展」的时刻。`send` / `ask_post`（新一轮开跑）时 = now，
  /// 之后由看门狗按 transcript mtime 推进。只给看门狗用，不进 payload。
  last_progress_at?: number
  /// 上一次看门狗读到的 transcript mtime，用来判「mtime 有没有前进」。
  last_mtime_unix?: number
}

/// 岛上一行放得下的字数上限；也顺带保证 detail 不可能顶爆 4KB payload 防线。
export const LA_DETAIL_MAX = 80

/// 首个非空行 + trim + 截断。空/全空白 → undefined（宁可不显示，不显示空条）。
function normalizeDetail(raw: string | undefined): string | undefined {
  if (typeof raw !== "string") return undefined
  const line = raw.split(/\r?\n/).map((s) => s.trim()).find((s) => s.length > 0)
  return line ? line.slice(0, LA_DETAIL_MAX) : undefined
}

/// `newRunId` 注入而不是内生：run_id 的形状（`r-<since_unix>-<n>`）要跟 golden 对齐，
/// 而序号是 hub 进程级的，纯函数不该自己攒计数器。
export function reducePhase(
  prev: LaPhaseSnapshot | undefined,
  ev: LaPhaseEvent,
  now: number,
  newRunId: () => string,
): { next: LaPhaseSnapshot; changed: boolean } {
  // ask_pre / ask_post / reply 都在**同一轮**里，不换 run_id、不重置 since_unix。
  const round = {
    since_unix: prev?.since_unix, run_id: prev?.run_id,
    last_progress_at: prev?.last_progress_at, last_mtime_unix: prev?.last_mtime_unix,
  }
  let next: LaPhaseSnapshot
  switch (ev.kind) {
    case "send":
      next = { phase: "working", since_unix: now, run_id: newRunId(), updated_unix: now, last_progress_at: now }
      break
    case "ask_pre":
      next = { phase: "waiting", ...round, detail: normalizeDetail(ev.detail), updated_unix: now }
      break
    case "ask_post":
      // 答完继续跑 = 一次真实进展；不重置的话看门狗会把「刚回答完」算进 idle。
      next = { phase: "working", ...round, updated_unix: now, last_progress_at: now }
      break
    case "reply":
      // done 是 latch：保持到下一次 send（→working）或 M4b 的超时，不自动回 idle。
      next = ev.pendingRemains && prev?.phase === "waiting"
        ? { phase: "waiting", ...round, detail: prev?.detail, updated_unix: now }
        : { phase: "done", ...round, updated_unix: now }
      break
    case "seen":
      next = prev?.phase === "done" ? { phase: "idle", ...round, updated_unix: now } : prev ?? { phase: "idle", updated_unix: now }
      break
  }
  // detail 变化不算跳变：状态跳变推送是稀疏的高优先级流量，不为一行文案再花一次预算。
  const changed = next.phase !== prev?.phase || next.run_id !== prev?.run_id
  return { next, changed }
}

/// 快照 + 用量 + 该 activity 的隐私开关 → 一条 contentState。
/// preview=hidden 的 activity 永远拿不到 detail（同一个 session 的两台设备可以一台看得见一台看不见）。
export function buildPhaseContentState(
  snap: LaPhaseSnapshot,
  usage: LaUsageSnapshot | undefined,
  preview: LaPreview,
): CCActivityState {
  const detail = preview === "full" ? snap.detail : undefined
  return {
    phase: snap.phase,
    ...(usage?.model !== undefined ? { model: usage.model } : {}),
    ...(usage?.ctx !== undefined ? { ctx: usage.ctx } : {}),
    ...(usage?.five_hour !== undefined ? { five_hour: usage.five_hour } : {}),
    ...(usage?.seven_day !== undefined ? { seven_day: usage.seven_day } : {}),
    ...(detail !== undefined ? { detail } : {}),
    ...(snap.since_unix !== undefined ? { since_unix: snap.since_unix } : {}),
    ...(snap.run_id !== undefined ? { run_id: snap.run_id } : {}),
    updated_unix: snap.updated_unix,
  }
}

// ── M4b ①：hub 看门狗 ──────────────────────────────────────────────
// 「hub 活着但 transcript 不动了」（CC 卡住 / 跑完没人收）没有任何显式事件会到 ——
// 这是四个事件点唯一盖不住的死法。mtime 在这里**只当 heartbeat**（还在不在动），
// 绝不当 phase 判据（M4a 否决过：nudge/keepalive 推 mtime 是假阳，长工具调用是假阴）。

export interface LaWatchdogInput {
  session: string
  snap: LaPhaseSnapshot
  /// transcript 的 mtime（unix 秒）。undefined = 拿不到（codex session 没 transcript / 文件不在）。
  mtimeUnix?: number
}

export type LaWatchdogDecision =
  /// mtime 前进了：写回快照即可，不推送。
  | { session: string; kind: "progress"; next: LaPhaseSnapshot }
  /// 拿不到 transcript：不更新、不判超时（codex session 的死活本 lane 不猜）。
  | { session: string; kind: "unknown" }
  /// 判失败：调用方推一条 done（**不 end** —— 岛留着显示最后状态，end 归 8h 上限或用户划掉）。
  | { session: string; kind: "timeout"; idleSec: number; next: LaPhaseSnapshot }

/// 纯函数：一批 session 的当前快照 + 各自 mtime → 该做什么。now/timeout 都注入。
export function evaluateLaWatchdog(
  inputs: LaWatchdogInput[],
  now: number,
  timeoutSec: number,
): LaWatchdogDecision[] {
  const out: LaWatchdogDecision[] = []
  for (const { session, snap, mtimeUnix } of inputs) {
    // 只管 working：waiting 是等人（合法的长时间），done/idle 本来就没在跑。
    if (snap.phase !== "working") continue
    if (mtimeUnix === undefined) { out.push({ session, kind: "unknown" }); continue }
    if (mtimeUnix > (snap.last_mtime_unix ?? 0)) {
      out.push({ session, kind: "progress", next: { ...snap, last_mtime_unix: mtimeUnix, last_progress_at: now } })
      continue
    }
    const idleSec = now - (snap.last_progress_at ?? snap.updated_unix)
    if (idleSec > timeoutSec) {
      // done 是 latch（跟 reply 同一个语义）：保持到下一次 send。
      out.push({ session, kind: "timeout", idleSec, next: { ...snap, phase: "done", updated_unix: now } })
    }
  }
  return out
}

export interface LaWatchdogIO {
  snap(session: string): LaPhaseSnapshot | undefined
  /// 异步 stat transcript（unix 秒）
  mtime(session: string): Promise<number | undefined>
  now(): number
  apply(d: LaWatchdogDecision): void
}
/// K3（审查 R1-2）：逐会话采样、各用自己的采样时刻判（别的会话的慢 stat 不算进它的闲置时长）；
/// 判超时前再 stat 一次确认（第一次采样到判定之间它可能又写了）。每个会话判完立刻 apply。返回判超时的个数
export async function runLaWatchdog(sessions: string[], io: LaWatchdogIO, timeoutSec: number): Promise<number> {
  let timedOut = 0
  const decide = async (session: string): Promise<LaWatchdogDecision | undefined> => {
    const mtimeUnix = await io.mtime(session).catch(() => undefined)
    const now = io.now()
    const snap = io.snap(session)
    return snap ? evaluateLaWatchdog([{ session, snap, mtimeUnix }], now, timeoutSec)[0] : undefined
  }
  for (const session of sessions) {
    let d = await decide(session)
    if (d?.kind === "timeout") d = await decide(session)
    if (!d) continue
    io.apply(d)
    if (d.kind === "timeout") timedOut++
  }
  return timedOut
}

// ── M4b ②：phase 快照落盘 ─────────────────────────────────────────
// hub 自己死了 → launchd KeepAlive 拉起新进程 → 内存里的 `working` 全没了，
// 岛却还挂在手机上等更新。落盘让新 hub 起来时能对账（超时的收尾、没超时的接着监控）。
// 形状照 `live-activity-tokens.ts`：坏文件一律当空，**绝不抛**（注册表坏了最多岛不更新，
// 不能让 hub 起不来）；模块顶层只读不写，路径由调用方给。

export type LaPhaseStore = Record<string, LaPhaseSnapshot>

const VALID_PHASES = new Set<CCPhase>(["idle", "working", "waiting", "done"])

export function loadLaPhase(path: string): LaPhaseStore {
  try {
    if (!existsSync(path)) return {}
    const raw = JSON.parse(readFileSync(path, "utf8"))
    if (!raw || typeof raw !== "object") return {}
    const store: LaPhaseStore = {}
    for (const [session, v] of Object.entries(raw as Record<string, LaPhaseSnapshot>)) {
      if (!session || !v || typeof v !== "object") continue
      if (!VALID_PHASES.has(v.phase) || typeof v.updated_unix !== "number") continue
      store[session] = v
    }
    return store
  } catch (e: any) {
    console.warn(`[hub] loadLaPhase failed: ${e?.message}`)
    return {}
  }
}

export function saveLaPhase(path: string, store: LaPhaseStore): void {
  try {
    writeFileSync(path, JSON.stringify(store, null, 2))
  } catch (e: any) {
    console.warn(`[hub] saveLaPhase failed: ${e?.message}`)
  }
}
