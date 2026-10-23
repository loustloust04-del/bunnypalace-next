// 对话会话的模型记忆：粟粟用 /model 切过的模型，会话被重新拉起（hub 重启恢复 / 闲置回收后 --resume / 死了重 spawn）时照用，
// 没切过才用 hub 默认（MP_CC_MODEL，缺省 claude-opus-4-6[1m]）。key = tmux session 名，落 secrets/cc-models.json。
// 来源两路：app 发来的 `/model <参数>`（即时记）；拉起前读绑定的转录尾部，终端里直接敲的 /model 也算（转录比记录新就用转录）。
// 参数原文存、原文传给 --model：别名（opus / sonnet[1m] / best…）和全名在 /model 与 --model 两边通用
//（code.claude.com/docs/en/model-config「Model aliases」表）。/model default 记成 "default"（≠ 从没选过），拉起时见 cliModelFor。
import { randomBytes } from "node:crypto"
import { rename, unlink, writeFile } from "node:fs/promises"
import { timedSyncFs } from "./block-ledger"
const { existsSync, readFileSync } = timedSyncFs("cc-model ")

/// updatedAt = 这次选择发生的时间（app：hub 收到命令；转录：转录里那条命令的 timestamp），新旧比较只看它；
/// seenAt = 转录来源被 hub 发现的时间，transcript = 哪份转录（claude session id）——两者分开存（审查 R1-7）
export interface ModelPref { model: string; updatedAt: string; source: "app" | "转录"; usedAt?: string; seenAt?: string; transcript?: string }
const PREF_SOURCES: readonly string[] = ["app", "转录"]
export type ModelCommand = { kind: "set"; model: string } | { kind: "reset" }
/// 转录里最后一次切模型。picker = 终端里不带参数开选单选的：参数是空的，模型取它之后第一条回复的 message.model（不带 [1m]）
export type TranscriptModelEvent = ModelCommand & { at?: string; picker?: boolean }
export interface LaunchModel { model: string; source: string }

/// 模型名的样子：别名（opus / sonnet[1m]）、全名（claude-opus-4-6[1m]）、云厂商 id（us.anthropic.…-v1:0 / …@20250805 / arn:aws:…/…）。
/// 记 / 读盘 / 转录回复里的 model 共用这一个校验（审查 R1-11）：别的字符（空白、引号、控制字符、NUL…）和超长的一律不收
export const MODEL_NAME_RE = /^[A-Za-z0-9._:\/@\[\]-]{1,200}$/
export function validModelName(s: unknown): s is string { return typeof s === "string" && MODEL_NAME_RE.test(s) }
const MODEL_ARG_OK = MODEL_NAME_RE
/// 记录最多留这么多个会话，超了按最近使用淘汰（审查 R1-13）
export const MAX_MODEL_PREFS = 500

/// `/model <参数>` → 记什么。不是 /model、不带参数（开交互选单）、参数不像模型名 → null（不记）
export function parseModelCommand(text: string): ModelCommand | null {
  const m = /^\/model(?:\s+([\s\S]*))?$/.exec(text.trim())
  if (!m) return null
  const arg = (m[1] ?? "").trim()
  if (!arg || !MODEL_ARG_OK.test(arg)) return null
  if (arg.toLowerCase() === "default") return { kind: "reset" }
  return { kind: "set", model: arg }
}

/// 拼进 shell 命令（tmux new-session 的命令串）的单引号转义：' → '\''
export function shellQuote(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`
}

export function entryText(content: unknown): string {
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return ""
  return content.map((p) => (p && typeof p === "object" && typeof (p as { text?: unknown }).text === "string" ? (p as { text: string }).text : "")).join("")
}

/// 一条 user 记录是不是一次独立的 /model 命令：整条内容只能是 `<command-message>` / `<command-name>` / `<command-args>`
///（各至多一个、顺序不限）加空白，命令名正好是 /model。普通正文 / channel 注入里提到这些标签的都不算（审查 R1-9）。
/// 是 → 返回参数原文（选单 = 空串）；不是 → null
export function standaloneModelArgs(text: string): string | null {
  const tags = ["command-message", "command-name", "command-args"]
  const found = new Map<string, string>()
  let rest = text
  for (const t of tags) {
    const re = new RegExp(`<${t}>([\\s\\S]*?)</${t}>`, "g")
    const all = [...rest.matchAll(re)]
    if (all.length > 1) return null
    if (all.length === 1) { found.set(t, all[0][1]); rest = rest.replace(all[0][0], "") }
  }
  if (rest.trim() || found.get("command-name")?.trim() !== "/model") return null
  return found.get("command-args") ?? ""
}

/// 转录尾部（按行）里最后一次有效的 /model。斜杠命令在转录里是一条独立的 user 记录（见 standaloneModelArgs）。
/// 选单（参数空）取它之后最近一条主线回复的 message.model；它之后还没有回复 = 不知道选了啥，接着往前找更早的有效切换，
/// 不让它遮住之前的选择（审查 R1-8）。都没有 → null
export function lastModelEvent(lines: string[]): TranscriptModelEvent | null {
  let replyModel: string | undefined   // 倒着走：遇到 /model 之前见过的回复都在它之后，留最早那条（最靠近 /model 的）
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim()
    if (!line || line[0] !== "{") continue
    let rec: { type?: string; isSidechain?: boolean; timestamp?: string; message?: { content?: unknown; model?: unknown } }
    try { rec = JSON.parse(line) } catch { continue }
    if (rec?.isSidechain) continue
    if (rec?.type === "assistant") {
      const model = rec.message?.model
      if (typeof model === "string" && MODEL_ARG_OK.test(model) && !model.includes("<")) replyModel = model   // <synthetic> 之类不是模型
      continue
    }
    if (rec?.type !== "user") continue
    const args = standaloneModelArgs(entryText(rec.message?.content))
    if (args === null) continue
    const at = typeof rec.timestamp === "string" ? rec.timestamp : undefined
    if (args.trim()) {
      const cmd = parseModelCommand(`/model ${args}`)
      if (cmd) return { ...cmd, at }
      replyModel = undefined
      continue   // 参数不像模型名：当没切成，往前找
    }
    if (replyModel) return { kind: "set", model: replyModel, at, picker: true }
    // 选单之后还没回复：往前找，期间的回复归更早那次（replyModel 保持 undefined）
  }
  return null
}

/// 同一个模型（不看 [1m] 这类后缀、大小写）
function sameModel(a: string, b: string): boolean {
  const base = (s: string) => s.replace(/\[[^\]]*\]$/, "").trim().toLowerCase()
  return base(a) === base(b)
}

/// 记录里的 "default" = 她明确要回默认（/model default）：留着这条而不是删记录，免得转录里更早的切换又冒出来
export const DEFAULT_MODEL_MARK = "default"

/// 选择 → 传给 --model 的值。"default"（她发过 /model default）先映射成 hub 默认 fallback：
/// `--model default` 文档没写明合法、也没实测（审查 R1-10，10-11 定先这样），确认之后改这一行即可
export function cliModelFor(choice: string, fallback: string): string {
  return choice === DEFAULT_MODEL_MARK ? fallback : choice
}
const DEFAULT_NOTE = "--model default 未实测，先用 hub 默认"

/// 转录事件时间晚于此刻（时钟回拨 / 转录带未来时间）就当没有时间：不让它一直压过之后 app 里的选择
const FUTURE_SLACK_MS = 60_000
export function eventTimeMs(at: string | undefined, now = Date.now()): number {
  const t = Date.parse(at ?? "")
  return Number.isFinite(t) && t <= now + FUTURE_SLACK_MS ? t : NaN
}

/// 拉起用哪个模型：记录 / 默认打底；转录里有更新的切换就用转录的。
/// 选单那种只知道回复里的模型 id（不带 [1m]）：跟打底的是同一个就还用打底的（保住 [1m]）
export function pickLaunchModel(fallback: string, record?: ModelPref, event?: TranscriptModelEvent | null, now = Date.now()): LaunchModel {
  const base: LaunchModel = !record ? { model: fallback, source: "默认" }
    : record.model === DEFAULT_MODEL_MARK ? { model: cliModelFor(record.model, fallback), source: `默认（${record.source} 要回默认；${DEFAULT_NOTE}）` }
    : { model: record.model, source: `记录（${record.source}）` }
  if (!event) return base
  if (record && !(eventTimeMs(event.at, now) >= Date.parse(record.updatedAt))) return base   // 记录更新（或转录没有可信时间）→ 信记录
  if (event.kind === "reset") return { model: cliModelFor(DEFAULT_MODEL_MARK, fallback), source: `转录（/model default；${DEFAULT_NOTE}）` }
  if (event.picker && sameModel(event.model, base.model)) return base
  return { model: event.model, source: event.picker ? "转录（选单）" : "转录" }
}

const validTime = (s: unknown): s is string => typeof s === "string" && s.length <= 40 && Number.isFinite(Date.parse(s))

/// 盘上的一条记录能不能用：模型名、时间、来源都对才收（坏的逐条丢，不连累别的）
export function validPref(v: unknown): v is ModelPref {
  if (!v || typeof v !== "object") return false
  const p = v as Record<string, unknown>
  return validModelName(p.model) && validTime(p.updatedAt) && typeof p.source === "string" && PREF_SOURCES.includes(p.source)
    && (p.usedAt === undefined || validTime(p.usedAt)) && (p.seenAt === undefined || validTime(p.seenAt))
    && (p.transcript === undefined || (typeof p.transcript === "string" && /^[A-Za-z0-9-]{1,100}$/.test(p.transcript)))
}

// ── 起不来时的模型恢复（审查 R1-4/5/6）：tmux、stream 共用 ──
// 只在有明确的模型报错证据时，本次恢复一次性改用 hub 默认；不写她的记录、不跟时间戳竞争，每次启动最多一次。
// 证据来源：stream 是进程退出前的 stderr 尾巴；tmux 只有 boot 期最后一次截屏（会话死了就截不到，多半没有证据 → 不降级）。
// 报错文案按 Claude Code 常见说法匹配，未实测（不能跑真 claude）：认不出来就当没有证据，按原来的死亡处理走
export const MODEL_OVERRIDE_BUDGET = 1
const MODEL_ERROR_RE = /issue with the selected model|model[^\n]{0,80}(not[ _]found|does not exist|may not exist|not available|not supported|invalid|unknown|no access|not have access)|(invalid|unknown|unsupported) model/i

/// 一段输出里有没有「这个模型不行」的证据：要有模型报错的说法，且提到了这次用的模型（同一模型不看 [1m] 后缀）
export function modelFailureEvidence(text: string, model: string): boolean {
  if (!text || !MODEL_ERROR_RE.test(text)) return false
  const base = model.replace(/\[[^\]]*\]$/, "").toLowerCase()
  return text.toLowerCase().includes(base)
}

/// 本次启动死了：该不该、改用哪个模型再试。返回 undefined = 不降级（没证据 / 已经是默认 / 预算用完）
export function planModelRecovery(o: { launched: string; fallback: string; evidence: string; used: number }): string | undefined {
  if (o.used >= MODEL_OVERRIDE_BUDGET || sameModel(o.launched, o.fallback)) return undefined
  return modelFailureEvidence(o.evidence, o.launched) ? o.fallback : undefined
}

/// 读转录找最后一次 /model，带截止时间（审查 R1-3）：超时 / 出错 → event=null（按记录启动）。
/// 迟到的读结果没人用：不会再写记录、也碰不到启动状态
export async function readModelEventWithin(read: () => Promise<string[]>, ms: number): Promise<{ event: TranscriptModelEvent | null; problem?: string }> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<"timeout">((r) => { timer = setTimeout(() => r("timeout"), ms) })
  try {
    const r = await Promise.race([read().then((lines) => ({ lines }), (error: unknown) => ({ error })), timeout])
    if (r === "timeout") return { event: null, problem: `超过 ${ms}ms` }
    if ("error" in r) return { event: null, problem: `失败：${String((r.error as Error)?.message ?? r.error).split("\n")[0]}` }
    return { event: lastModelEvent(r.lines) }
  } finally { clearTimeout(timer) }
}

export class ModelPrefs {
  private readonly map = new Map<string, ModelPref>()
  private chain: Promise<void> = Promise.resolve()
  private queued = false
  constructor(private readonly path: string, private readonly max = MAX_MODEL_PREFS) {}

  /// 启动时读一次（同 session-map）；坏记录逐条丢
  load(): void {
    try {
      if (!existsSync(this.path)) return
      const obj = JSON.parse(String(readFileSync(this.path, "utf-8"))) as Record<string, unknown>
      let bad = 0
      for (const [k, v] of Object.entries(obj ?? {})) { if (validPref(v)) this.map.set(k, v); else bad++ }
      this.evict()
      console.log(`[hub] cc-models loaded (${this.map.size}${bad ? `，丢了 ${bad} 条坏记录` : ""})`)
    } catch (e) { console.warn(`[hub] cc-models load fail: ${(e as Error).message}`) }
  }

  private readonly versions = new Map<string, number>()
  get(name: string): ModelPref | undefined { return this.map.get(name) }
  get size(): number { return this.map.size }
  /// 这个会话的记录改过几次（进程内）：异步读转录前后对一下，变了就按新记录比（审查 R1-7）
  version(name: string): number { return this.versions.get(name) ?? 0 }
  private bump(name: string): void { this.versions.set(name, this.version(name) + 1) }

  /// 记一次选择；模型名不合格不记（返回 false）
  set(name: string, model: string, source: ModelPref["source"], now = new Date()): boolean {
    if (!validModelName(model)) return false
    const at = now.toISOString()
    this.map.set(name, { model, updatedAt: at, source, usedAt: at })
    this.bump(name)
    this.evict()
    void this.save()
    return true
  }

  /// 从转录发现的切换：updatedAt 用转录里那条命令的时间（不可信就用发现时间），另存发现时间和哪份转录
  setFromTranscript(name: string, model: string, eventAt: string | undefined, transcript: string, now = new Date()): boolean {
    if (!validModelName(model)) return false
    const seen = now.toISOString()
    const t = eventTimeMs(eventAt, now.getTime())
    this.map.set(name, { model, updatedAt: Number.isFinite(t) ? new Date(t).toISOString() : seen, source: "转录", usedAt: seen, seenAt: seen, transcript })
    this.bump(name)
    this.evict()
    void this.save()
    return true
  }

  /// 拉起时用到了：刷新最近使用（淘汰按它排）
  touch(name: string, now = new Date()): void {
    const p = this.map.get(name)
    if (!p) return
    p.usedAt = now.toISOString()
    void this.save()
  }

  /// 会话被显式删除时清掉（闲置回收不清：绑定留着，下次 --resume 还要用）
  delete(name: string): void {
    if (this.map.delete(name)) { this.bump(name); void this.save() }
  }

  /// 等写链落完（受控退出前用）
  flush(): Promise<void> { return this.chain }

  private evict(): void {
    if (this.map.size <= this.max) return
    const used = (p: ModelPref) => Date.parse(p.usedAt ?? p.updatedAt) || 0
    const order = [...this.map].sort((a, b) => used(a[1]) - used(b[1]))
    for (const [k] of order.slice(0, this.map.size - this.max)) this.map.delete(k)
  }

  /// 异步原子写（临时文件 + rename），串行；排着没开写的那次直接并进去（写的是写那一刻的全量）
  save(): Promise<void> {
    if (this.queued) return this.chain
    this.queued = true
    this.chain = this.chain.then(async () => {
      this.queued = false
      const tmp = `${this.path}.tmp-${process.pid}-${randomBytes(6).toString("hex")}`
      try {
        await writeFile(tmp, JSON.stringify(Object.fromEntries(this.map), null, 2), { mode: 0o600, flag: "wx" })
        await rename(tmp, this.path)
      } catch (e) {
        await unlink(tmp).catch(() => {})
        console.warn(`[hub] cc-models save fail: ${(e as Error).message}`)
      }
    })
    return this.chain
  }
}
