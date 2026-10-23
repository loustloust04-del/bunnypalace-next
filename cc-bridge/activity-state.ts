// Live Activity 的 ContentState / Attributes 编码（TS 半边）。
// 与 Swift 侧 JSONEncoder(.sortedKeys) 逐字节一致是硬契约：键按字母序、无空白、
// undefined 不落键。对拍靠 fixtures/live-activity/*.golden.json，两边各测各的、比同一份 golden。

export type CCPhase = "idle" | "working" | "waiting" | "done"

export interface CCActivityState {
  phase: CCPhase
  model?: string
  ctx?: number
  five_hour?: number
  seven_day?: number
  detail?: string
  since_unix?: number
  updated_unix?: number
  run_id?: string
}

export interface CCActivityAttributes {
  session_name: string
}

export const CC_PHASES: readonly CCPhase[] = ["idle", "working", "waiting", "done"]

/// 合同里的全部键（字母序）。多一个少一个都会让 Swift 侧解码失败或静默丢字段。
export const CC_ACTIVITY_STATE_KEYS: readonly string[] = [
  "ctx", "detail", "five_hour", "model", "phase", "run_id", "seven_day", "since_unix", "updated_unix",
]

/// 校验来自网络的 state。返回 null=合法，否则给出拒绝理由。
/// 拼错一个键名 APNs 照样回 200、真机岛静默不动、链路上没有任何地方报错——所以必须在发出去之前拦。
export function validateContentState(o: Record<string, unknown>): string | null {
  if (typeof o.phase !== "string" || !CC_PHASES.includes(o.phase as CCPhase)) return "bad_phase"
  const extra = Object.keys(o).filter((k) => !CC_ACTIVITY_STATE_KEYS.includes(k))
  if (extra.length) return `unknown_keys:${extra.join(",")}`
  return null
}

/// 键全 ASCII snake_case，所以 JS 的 UTF-16 码元排序与 Swift .sortedKeys 的字节序等价。
function stable(o: Record<string, string | number | undefined>): string {
  const parts: string[] = []
  for (const k of Object.keys(o).sort()) {
    const v = o[k]
    if (v === undefined) continue
    parts.push(`${JSON.stringify(k)}:${JSON.stringify(v)}`)
  }
  return `{${parts.join(",")}}`
}

/// 字面量里的键就按字母序写，跟 Swift 的 CodingKeys 一一对上，肉眼可核。
export function encodeContentState(s: CCActivityState): string {
  return stable({
    ctx: s.ctx,
    detail: s.detail,
    five_hour: s.five_hour,
    model: s.model,
    phase: s.phase,
    run_id: s.run_id,
    seven_day: s.seven_day,
    since_unix: s.since_unix,
    updated_unix: s.updated_unix,
  })
}

export function encodeAttributes(a: CCActivityAttributes): string {
  return stable({ session_name: a.session_name })
}
