/// alert 推送的 device token 注册表（`push-tokens.json`）。跟 `live-activity-tokens.ts` 那套隔离。
///
/// 每个 token 自带 topic（= 上报它的 app 的 bundle id）和 env：同一个 hub 下可能同时挂着
/// `.ios`（开发签名 → sandbox）和 `.susu`（Ad Hoc → production）两种包，topic / host 必须跟着 token 走。
/// 老记录没有 topic → 发送时回退 `DEFAULT_TOPIC`。
import { timedSyncFs } from "./block-ledger"
const { existsSync, readFileSync, writeFileSync } = timedSyncFs("push-tokens ")
import type { APNsResult } from "./apns.ts"

export type PushEnv = "sandbox" | "production"
/// preview: "full"（剧透前 80 字）| "hidden"（只「小克找你了」）
export type PushInfo = { env: PushEnv; preview: "full" | "hidden"; topic?: string }

const LA_TOPIC_SUFFIX = ".push-type.liveactivity"

/// 只收 bundle id 形状的字符串；不合格当没带（调用方回退默认 topic），不拒注册。
/// 派生的 liveactivity topic 由 hub 自己拼，客户端报上来的一律不收。
export function normalizeTopic(v: unknown): string | undefined {
  if (typeof v !== "string" || !/^[A-Za-z0-9.-]{1,155}$/.test(v) || v.endsWith(LA_TOPIC_SUFFIX)) return undefined
  return v
}

export function normalizePushInfo(raw: any): PushInfo {
  const topic = normalizeTopic(raw?.topic)
  return {
    env: raw?.env === "production" ? "production" : "sandbox",
    preview: raw?.preview === "hidden" ? "hidden" : "full",
    ...(topic ? { topic } : {}),
  }
}

export function loadPushTokens(path: string): Map<string, PushInfo> {
  const tokens = new Map<string, PushInfo>()
  try {
    if (!existsSync(path)) return tokens
    const raw = JSON.parse(readFileSync(path, "utf8"))
    if (Array.isArray(raw)) {
      // 老格式 ["token"] → 迁移，默认完整预览
      for (const t of raw) if (typeof t === "string") tokens.set(t, normalizePushInfo(undefined))
    } else if (raw && typeof raw === "object") {
      for (const [t, info] of Object.entries(raw)) tokens.set(t, normalizePushInfo(info))
    }
  } catch (e: any) { console.warn(`[hub] loadPushTokens failed: ${e.message}`) }
  return tokens
}

export function savePushTokens(path: string, tokens: Map<string, PushInfo>): void {
  try { writeFileSync(path, JSON.stringify(Object.fromEntries(tokens))) }
  catch (e: any) { console.warn(`[hub] savePushTokens failed: ${e.message}`) }
}

/// 该删 token 的失败。DeviceTokenNotForTopic：token 跟这次的 topic 不配——app 每次重连都会
/// 带着正确 topic 重报，删了会自己回来，不删则修好前每条推送都白打一次。
const DEAD_ALERT_REASONS = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"])
export function isDeadAlertResult(r: APNsResult): boolean {
  return r.status === 410 || (r.reason !== undefined && DEAD_ALERT_REASONS.has(r.reason))
}
