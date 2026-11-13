// CC 设置以 hub 为准（铲屎二期刀 5 D-B1）：落盘、按字段合并、改完回推所有 app。
// 以前 ccConfig 只在内存、app 每次连上整份覆盖 → 最后连上的设备说了算、hub 一重启就回默认、设置页显示的不一定是 hub 在用的。
import { existsSync, readFileSync, writeFileSync } from "node:fs"

export interface CCConfig {
  pushName: string
  userName: string
  nudgeEnabled: boolean
  idleMinMs: number
  idleMaxMs: number
  quietStartMin: number
  quietEndMin: number
  cooldownMs: number
  nudgeTemplate: string
  newSessionTransport: "tmux" | "stream"
}

/// 按字段记修改时间的那几项（wire 名）。推送名 / 称呼跟着当前楼层走，每次连上照收，不进这张表
export const SYNCED_FIELDS = ["nudgeEnabled", "newSessionTransport", "idleMinMin", "idleMaxMin", "quietStartMin", "quietEndMin", "cooldownMin", "nudgeTemplate"] as const

export interface CCConfigState {
  config: CCConfig
  /// wire 名 → 毫秒时间戳（改的那台设备的钟）
  updatedAt: Record<string, number>
  /// 落过盘 / 收过第一份：之后新版 app 只能按字段改
  seeded: boolean
}

export function loadCCConfig(path: string, defaults: CCConfig): CCConfigState {
  const config = { ...defaults }
  try {
    if (!existsSync(path)) return { config, updatedAt: {}, seeded: false }
    const raw = JSON.parse(readFileSync(path, "utf-8"))
    const saved = raw?.config ?? {}
    for (const k of Object.keys(defaults) as (keyof CCConfig)[]) {
      if (typeof saved[k] === typeof defaults[k]) (config as Record<string, unknown>)[k] = saved[k]
    }
    if (config.newSessionTransport !== "tmux" && config.newSessionTransport !== "stream") config.newSessionTransport = defaults.newSessionTransport
    const updatedAt: Record<string, number> = {}
    for (const [k, v] of Object.entries(raw?.updatedAt ?? {})) if (Number.isFinite(v)) updatedAt[k] = Number(v)
    return { config, updatedAt, seeded: true }
  } catch (e: any) {
    console.warn(`[hub] cc-config load fail: ${e.message}`)
    return { config, updatedAt: {}, seeded: false }
  }
}

export function saveCCConfig(path: string, s: CCConfigState): void {
  try { writeFileSync(path, JSON.stringify({ config: s.config, updatedAt: s.updatedAt }, null, 2), { mode: 0o600 }) }
  catch (e: any) { console.warn(`[hub] cc-config save fail: ${e.message}`) }
}

/// app 的 set_cc_config 合进来。新版 app 带 editedAt（本机每项最后一次手改的时间）：
/// hub 还没落过盘 → 第一份整份当初值（老用户的设置不丢）；之后只收比 hub 记的更新的那几项。
/// 老版 app 不带 editedAt：照旧整份覆盖
export function applyCCConfigFrame(s: CCConfigState, msg: any, opts: {
  now: number
  transportLocked: boolean
  defaultTemplate: string
  rejects: (text: string) => boolean
}): void {
  const c = s.config
  if (typeof msg.pushName === "string" && msg.pushName.trim()) c.pushName = msg.pushName.trim().slice(0, 100)
  // userName 会替换进 nudge channel body 喂给 claude → 拒绝标签注入
  if (typeof msg.userName === "string" && msg.userName.trim()) {
    const u = msg.userName.trim().slice(0, 100)
    if (opts.rejects(u)) console.warn(`[hub] set_cc_config: userName 含标签，拒绝（防注入）`)
    else c.userName = u
  }
  const edited = msg.editedAt && typeof msg.editedAt === "object" ? msg.editedAt as Record<string, unknown> : null
  const take = (w: string): boolean => {
    if (!edited || !s.seeded) return true
    const at = Number(edited[w])
    return Number.isFinite(at) && at > (s.updatedAt[w] ?? 0)
  }
  const stamp = (w: string) => { s.updatedAt[w] = edited ? (Number(edited[w]) || 0) : opts.now }

  if (typeof msg.nudgeEnabled === "boolean" && take("nudgeEnabled")) { c.nudgeEnabled = msg.nudgeEnabled; stamp("nudgeEnabled") }
  if (!opts.transportLocked && (msg.newSessionTransport === "tmux" || msg.newSessionTransport === "stream") && take("newSessionTransport")) {
    c.newSessionTransport = msg.newSessionTransport
    stamp("newSessionTransport")
  }
  if (Number.isFinite(msg.idleMinMin) && msg.idleMinMin > 0 && take("idleMinMin")) { c.idleMinMs = msg.idleMinMin * 60_000; stamp("idleMinMin") }
  if (Number.isFinite(msg.idleMaxMin) && msg.idleMaxMin > 0 && take("idleMaxMin")) { c.idleMaxMs = msg.idleMaxMin * 60_000; stamp("idleMaxMin") }
  c.idleMaxMs = Math.max(c.idleMaxMs, c.idleMinMs)
  const clampMin = (v: any, d: number) => (Number.isFinite(v) && v >= 0 && v < 1440 ? Math.floor(v) : d)
  if (msg.quietStartMin !== undefined && take("quietStartMin")) { c.quietStartMin = clampMin(msg.quietStartMin, c.quietStartMin); stamp("quietStartMin") }
  if (msg.quietEndMin !== undefined && take("quietEndMin")) { c.quietEndMin = clampMin(msg.quietEndMin, c.quietEndMin); stamp("quietEndMin") }
  if (Number.isFinite(msg.cooldownMin) && msg.cooldownMin >= 0 && take("cooldownMin")) { c.cooldownMs = msg.cooldownMin * 60_000; stamp("cooldownMin") }
  if (typeof msg.nudgeTemplate === "string" && take("nudgeTemplate")) {
    const t = msg.nudgeTemplate.trim().slice(0, 1000)
    if (!t) {
      // 新版 app 清空 = 回到默认；老版 app 空串本来就不发
      if (edited) { c.nudgeTemplate = opts.defaultTemplate; stamp("nudgeTemplate") }
    } else if (opts.rejects(t)) {
      console.warn(`[hub] set_cc_config: nudgeTemplate 含标签，拒绝（防注入），保留原值`)
    } else {
      c.nudgeTemplate = t
      stamp("nudgeTemplate")
    }
  }
  s.seeded = true
}

/// 推给 app 的权威值（连上回完 set_cc_config / 任何设备改了之后）。模板是默认的就不带，app 那边回到灰字占位
export function ccConfigFrame(s: CCConfigState, defaultTemplate: string): string {
  const c = s.config
  return JSON.stringify({
    type: "cc_config",
    nudgeEnabled: c.nudgeEnabled,
    newSessionTransport: c.newSessionTransport,
    idleMinMin: Math.round(c.idleMinMs / 60_000),
    idleMaxMin: Math.round(c.idleMaxMs / 60_000),
    quietStartMin: c.quietStartMin,
    quietEndMin: c.quietEndMin,
    cooldownMin: Math.round(c.cooldownMs / 60_000),
    ...(c.nudgeTemplate !== defaultTemplate ? { nudgeTemplate: c.nudgeTemplate } : {}),
    updatedAt: s.updatedAt,
  })
}
