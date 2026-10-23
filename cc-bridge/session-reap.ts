import { isWindowSession } from "./terminal-windows"

/// 闲置回收的判定（hub 每小时跑一次）。最后活动 = max(内存里她最后发言, claude transcript mtime)；
/// 内存记录 hub 重启就清空，transcript 才是跨重启的那份。两样都没有 → 不知道多久没动，不收。

export type ReapBasis = "transcript" | "send"
export interface ReapCandidate { session: string; idleMs: number; basis: ReapBasis }
export interface ReapPlan { reap: ReapCandidate[]; unknown: string[] }

export interface ReapInput {
  sessions: Iterable<string>
  now: number
  thresholdMs: number
  /// 军机处常驻会话等，名字在里面就不收
  protectedNames: ReadonlySet<string>
  /// 正在 spawn / 有排队消息
  busy: (session: string) => boolean
  lastSendAt: (session: string) => number | undefined
  /// claude 会话绑定的 transcript；codex / 无绑定 → undefined
  transcriptPath: (session: string) => string | undefined
  mtimeMs: (path: string) => Promise<number | undefined>
}

export const DEFAULT_REAP_DAYS = 1

export function reapThresholdMs(raw: string | undefined): number {
  const days = Number(raw)
  return (Number.isFinite(days) && days > 0 ? days : DEFAULT_REAP_DAYS) * 86_400_000
}

/// "mp-cc" 不带尾 dash → 主会话不在回收范围
export function reapEligible(session: string, protectedNames: ReadonlySet<string>, busy: (session: string) => boolean): boolean {
  if (!session.startsWith("mp-cc-") && !session.startsWith("mp-codex-")) return false
  if (isWindowSession(session) || protectedNames.has(session)) return false
  return !busy(session)
}

export async function planReap(input: ReapInput): Promise<ReapPlan> {
  const plan: ReapPlan = { reap: [], unknown: [] }
  for (const session of new Set(input.sessions)) {
    if (!reapEligible(session, input.protectedNames, input.busy)) continue
    const sent = input.lastSendAt(session)
    const path = input.transcriptPath(session)
    const mtime = path ? await input.mtimeMs(path) : undefined
    if (sent === undefined && mtime === undefined) { plan.unknown.push(session); continue }
    const basis: ReapBasis = (mtime ?? -Infinity) >= (sent ?? -Infinity) ? "transcript" : "send"
    const idleMs = input.now - Math.max(sent ?? -Infinity, mtime ?? -Infinity)
    if (idleMs >= input.thresholdMs) plan.reap.push({ session, idleMs, basis })
  }
  return plan
}

export function reapLogLine(c: ReapCandidate): string {
  return `reaped idle session ${c.session}（闲 ${(c.idleMs / 3_600_000).toFixed(1)}h，依据 ${c.basis}）`
}

export function reapUnknownLogLine(unknown: string[]): string | null {
  return unknown.length ? `reap 跳过 ${unknown.length} 个无活动记录的会话（无发言记录、无 transcript）：${unknown.join(", ")}` : null
}
