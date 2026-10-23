/// CC 终端顶卡的用量数据源。
///
/// 拆两条路，故意不对称：
/// - ctx% 走 **transcript 自算**（hub 本来就知道 session-id 和 transcript 路径），永远可用
/// - 5h/7d 走 statusline 落盘文件，**读不到就 undefined**，顶栏显示灰 `--`
///
/// 为什么不都走 statusline：那是第三方（Vibe Island）装的脚本占着 CC 唯一的 statusLine 槽位，
/// 卸载/换版本就没了。app 的基础功能不能依赖它存在 —— 外部依赖只能是可选增强。
import { timedSyncFs } from "./block-ledger"
import { nativeOneM, parseClaudeModel } from "./session-model"
const { existsSync, openSync, readSync, closeSync, statSync, readFileSync } = timedSyncFs("terminal-usage ")

export interface UsageSnapshot {
  model?: string
  ctx?: number
  five_hour?: number
  seven_day?: number
}

export function buildTerminalUsagePayload(
  sessionName: string,
  transcript: Pick<UsageSnapshot, "model" | "ctx"> | null,
  limits: Pick<UsageSnapshot, "five_hour" | "seven_day">,
): string {
  return JSON.stringify({
    type: "terminal_usage",
    session_name: sessionName,
    model: transcript ? transcript.model : null,
    ctx: transcript ? transcript.ctx : null,
    five_hour: limits.five_hour,
    seven_day: limits.seven_day,
  })
}

/// transcript 可能几十 MB，只读尾部这么多字节反向找。
export const TRANSCRIPT_TAIL_BYTES = 512 * 1024

/// 带 `[1m]` 后缀（`claude-opus-4-6[1m]`）或天生 1M 的模型（Opus 4.7+ / Sonnet 5+ / Haiku 5.5 / Fable，清单和来源见
/// session-model.ts nativeOneM）→ 1_000_000；其余（含认不出的）200_000。
/// 传会话真实模型（hub 的 sessionModelFor：回复里的 model 接上选择的 [1m]），别传 hub 默认
export function contextWindowFor(model: string): number {
  if (/\[1m\]$/i.test(model.trim())) return 1_000_000
  const p = parseClaudeModel(model)
  return p && nativeOneM(p) ? 1_000_000 : 200_000
}

/// `claude-opus-4-6` + 1M → `Opus 4.6 · 1M`，顶栏就这么窄，全称塞不下（M0 实测）。
export function prettyModel(modelId: string | undefined, contextWindow: number): string | undefined {
  if (!modelId) return undefined
  const family = /opus/i.test(modelId) ? "Opus"
    : /sonnet/i.test(modelId) ? "Sonnet"
    : /haiku/i.test(modelId) ? "Haiku"
    : /fable/i.test(modelId) ? "Fable"
    : null
  const version = modelId.match(/-(\d+)-(\d+)/)
  const name = family
    ? (version ? `${family} ${version[1]}.${version[2]}` : family)
    : modelId
  const window = contextWindow >= 1_000_000 ? "1M" : `${Math.round(contextWindow / 1000)}K`
  return `${name} · ${window}`
}

/// 反向扫 transcript 尾部，取最后一条带 usage 的 assistant 记录。
///
/// ⚠️ 不能直接读最后一行：末尾常是 system / attachment / summary 记录，没有 usage。
/// ctx 用的是**当前上下文占用**，四项都要算进去 —— cache_read 才是大头（实测 10 万量级，
/// 而 input_tokens 只有个位数），漏掉它算出来会接近 0。
/// contextWindow 可以给函数：拿这条记录的 message.model 算窗口（会话中途 /model 换了，按这条回复实际用的模型算）。
export function readTranscriptUsage(
  transcriptPath: string,
  contextWindow: number | ((recordModel: string | undefined) => number),
): { model?: string; ctx?: number } {
  if (!existsSync(transcriptPath)) return {}

  let tail: string
  try {
    const size = statSync(transcriptPath).size
    const start = Math.max(0, size - TRANSCRIPT_TAIL_BYTES)
    const length = size - start
    if (length <= 0) return {}
    const buf = Buffer.allocUnsafe(length)
    const fd = openSync(transcriptPath, "r")
    try { readSync(fd, buf, 0, length, start) } finally { closeSync(fd) }
    tail = buf.toString("utf-8")
  } catch { return {} }

  const lines = tail.split("\n")
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim()
    if (!line || line[0] !== "{") continue          // 尾部截断的半行
    let rec: any
    try { rec = JSON.parse(line) } catch { continue }
    if (rec?.type !== "assistant") continue
    const usage = rec?.message?.usage
    if (!usage) continue

    const used = (usage.input_tokens ?? 0)
      + (usage.cache_creation_input_tokens ?? 0)
      + (usage.cache_read_input_tokens ?? 0)
      + (usage.output_tokens ?? 0)
    if (used <= 0) continue

    const recordModel = typeof rec?.message?.model === "string" ? rec.message.model : undefined
    const window = typeof contextWindow === "function" ? contextWindow(recordModel) : contextWindow
    return {
      model: prettyModel(recordModel, window),
      ctx: Math.min(100, Math.round((used / window) * 100)),
    }
  }
  return {}
}

/// statusline 落盘的账号级用量。格式：
/// `{"five_hour":{"used_percentage":18},"seven_day":{"used_percentage":71}}`
/// 读不到 / 格式不对 → 全 undefined，顶栏显示灰 `--`，绝不让它拖垮 ctx。
export function readRateLimits(rlPath: string): { five_hour?: number; seven_day?: number } {
  try {
    if (!existsSync(rlPath)) return {}
    const obj = JSON.parse(readFileSync(rlPath, "utf-8"))
    const pick = (v: any): number | undefined => {
      const n = v?.used_percentage
      return typeof n === "number" && isFinite(n) ? Math.max(0, Math.min(100, Math.round(n))) : undefined
    }
    return { five_hour: pick(obj?.five_hour), seven_day: pick(obj?.seven_day) }
  } catch { return {} }
}
