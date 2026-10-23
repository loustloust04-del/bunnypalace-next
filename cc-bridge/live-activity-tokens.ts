/// Live Activity 的 push token 注册表（D6 协议，`docs/prompts/2026-08-29-live-activity/README.md`）。
///
/// 跟 `pushTokens` / `push-tokens.json` 那套**完全隔离**，不是同一个 token 的两种用法：
/// 作用域（一个 activity vs 一台设备）、topic（`…push-type.liveactivity` vs 默认）、
/// payload（content-state vs alert）、路由身份（activity_id / install_id vs token）四不同。
///
/// 路由身份：update token 按 `activity_id` 存，push-to-start token 按 `install_id` 存。
/// token 轮换是**替换**同一条（Apple 要求服务端让旧 token 失效），不无限追加。
import { timedSyncFs } from "./block-ledger"
const { existsSync, readFileSync, writeFileSync } = timedSyncFs("la-tokens ")
import { normalizeTopic } from "./push-tokens.ts"

export type LaEnv = "sandbox" | "production"
export type LaPreview = "full" | "hidden"

export interface LaUpdateRecord {
  token: string
  /// 只用于 log 与事后对账，hub 不拿它做任何判断（同 key 写入天然 replace）。
  previous_token?: string
  session_name: string
  install_id: string
  env: LaEnv
  preview: LaPreview
  /// 上报它的 app 的 bundle id；老记录没有 → 发送时回退默认 topic。
  topic?: string
  /// 这个 **activity**（不是这个 token）第一次被注册的时刻，毫秒，跟 `updated_at` 同一个钟。
  /// token 轮换（同 activity_id 换 token）**不重置**它 —— 重置了 M5 ⑤ 的 8h 滚动换岛就永远
  /// 等不到阈值。M5 之前的旧记录没有这个字段，读的时候退回 `updated_at`。
  started_at?: number
  updated_at: number
}

export interface LaStartRecord {
  token: string
  previous_token?: string
  install_id: string
  env: LaEnv
  preview: LaPreview
  topic?: string
  updated_at: number
}

export interface LaTokenStore {
  update: Record<string, LaUpdateRecord>
  start: Record<string, LaStartRecord>
}

export function emptyLaTokenStore(): LaTokenStore {
  return { update: {}, start: {} }
}

/// 缺省 `hidden`（往安全倒）。**故意**跟 alert 路径的缺省 `full` 不对称，别「统一」回去。
function normalizePreview(v: unknown): LaPreview {
  return v === "full" ? "full" : "hidden"
}

function isNonEmptyString(v: unknown): v is string {
  return typeof v === "string" && v.length > 0
}

export interface LaRegisterResult {
  ok: boolean
  reason?: string
  /// 被替换掉的旧 token（有就说明是轮换，不是新增），只给 log 用。
  replaced?: string
}

/// 校验 + 落记录。拒绝时调用方**必须回 `la_token_nak`**——
/// 不回帧的话 app 的 didOpen 全量补报会静默死循环。
export function registerLaToken(store: LaTokenStore, msg: any): LaRegisterResult {
  const kind = msg?.kind
  if (kind !== "update" && kind !== "start") return { ok: false, reason: `bad_kind: ${String(kind)}` }
  if (!isNonEmptyString(msg.token)) return { ok: false, reason: "missing_token" }
  if (!isNonEmptyString(msg.install_id)) return { ok: false, reason: "missing_install_id" }
  if (msg.env !== "sandbox" && msg.env !== "production") return { ok: false, reason: `bad_env: ${String(msg.env)}` }

  const preview = normalizePreview(msg.preview)
  const topic = normalizeTopic(msg.topic)
  const previous_token = isNonEmptyString(msg.previous_token) ? msg.previous_token : undefined
  const updated_at = Date.now()

  if (kind === "start") {
    const replaced = store.start[msg.install_id]?.token
    store.start[msg.install_id] = {
      token: msg.token,
      ...(previous_token ? { previous_token } : {}),
      install_id: msg.install_id,
      env: msg.env,
      preview,
      ...(topic ? { topic } : {}),
      updated_at,
    }
    return { ok: true, ...(replaced && replaced !== msg.token ? { replaced } : {}) }
  }

  if (!isNonEmptyString(msg.activity_id)) return { ok: false, reason: "missing_activity_id" }
  if (!isNonEmptyString(msg.session_name)) return { ok: false, reason: "missing_session_name" }
  const existing = store.update[msg.activity_id]
  const replaced = existing?.token
  store.update[msg.activity_id] = {
    token: msg.token,
    ...(previous_token ? { previous_token } : {}),
    session_name: msg.session_name,
    install_id: msg.install_id,
    env: msg.env,
    preview,
    ...(topic ? { topic } : {}),
    started_at: existing?.started_at ?? updated_at,
    updated_at,
  }
  return { ok: true, ...(replaced && replaced !== msg.token ? { replaced } : {}) }
}

/// 岛没了 / app 收到 nak → 删记录。删不存在的不算错（幂等）。
export function unregisterLaToken(store: LaTokenStore, msg: any): { ok: boolean } {
  if (msg?.kind === "start" && isNonEmptyString(msg.install_id)) {
    delete store.start[msg.install_id]
    return { ok: true }
  }
  if (msg?.kind === "update" && isNonEmptyString(msg.activity_id)) {
    delete store.update[msg.activity_id]
    return { ok: true }
  }
  return { ok: false }
}

/// 缺文件 / 坏 JSON 一律当空 store，绝不抛——注册表坏了最多是岛不更新，不能让 hub 起不来。
export function loadLaTokens(path: string): LaTokenStore {
  try {
    if (!existsSync(path)) return emptyLaTokenStore()
    const raw = JSON.parse(readFileSync(path, "utf8"))
    if (!raw || typeof raw !== "object") return emptyLaTokenStore()
    const store = emptyLaTokenStore()
    for (const [id, r] of Object.entries((raw.update ?? {}) as Record<string, LaUpdateRecord>)) {
      if (r && typeof r === "object" && isNonEmptyString(r.token)) store.update[id] = r
    }
    for (const [id, r] of Object.entries((raw.start ?? {}) as Record<string, LaStartRecord>)) {
      if (r && typeof r === "object" && isNonEmptyString(r.token)) store.start[id] = r
    }
    return store
  } catch (e: any) {
    console.warn(`[hub] loadLaTokens failed: ${e?.message}`)
    return emptyLaTokenStore()
  }
}

export function saveLaTokens(path: string, store: LaTokenStore): void {
  try {
    writeFileSync(path, JSON.stringify(store, null, 2))
  } catch (e: any) {
    console.warn(`[hub] saveLaTokens failed: ${e?.message}`)
  }
}

/// log 用：token 只露末 8 位。
export function tokenTail(token: string | undefined): string {
  return token ? `…${token.slice(-8)}` : "none"
}
