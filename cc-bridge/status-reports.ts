// 状态面板 hub 侧（docs/plan-status-panel.html §7）：外部检修源的报告校验 / 落盘 / 小芽提醒判定 / 静音 / 「立即检修」。
import { spawn, type ChildProcess } from "node:child_process"
import { randomUUID } from "node:crypto"
import { homedir } from "node:os"
import { isAbsolute, join } from "node:path"
import { timedSyncFs } from "./block-ledger"
import { agentDir } from "./agent-runner.ts"
import { saveJsonPrivate } from "./hub-config.ts"
const { readFileSync, readdirSync, existsSync } = timedSyncFs("status-reports ")

export const STATUS_BODY_MAX_BYTES = 64 * 1024
export const DEFAULT_STALE_HOURS = 36
export const REPEAT_AFTER_MS = 24 * 3_600_000
export const RUN_TIMEOUT_MS = 3 * 60_000
const NAME_MAX = 80
const DETAIL_MAX = 300
const TITLE_MAX = 80
const ITEMS_MAX = 100

export interface StatusItem { name: string; ok: boolean; detail: string }
export interface StatusReport {
  id: string
  title: string
  checkedAt: string
  staleAfterHours: number
  items: StatusItem[]
  receivedAt: string
}
export interface StatusSourceConfig { title?: string; run?: string; staleAfterHours?: number }
export interface QuietConfig { start: string; end: string; tz: string }
export type AlertKind = "bad" | "recovered"
export interface StatusAlert {
  id: string
  source: string
  title: string
  kind: AlertKind
  text: string
  names: string[]
  createdAt: string
}
export interface StatusPush { alertId: string; source: string; kind: AlertKind; text: string }
export interface SourceAlertState { notifiedKey: string; notifiedAt: string | null; notifiedBad: boolean; lastAlertId: string | null }
export interface AlertState { sources: Record<string, SourceAlertState>; deferredPushes: StatusPush[] }
export interface ParsedBody { title?: string; checkedAt: string; staleAfterHours?: number; items: StatusItem[] }

export const DEFAULT_QUIET: QuietConfig = { start: "23:30", end: "08:30", tz: "Asia/Shanghai" }

export function isoSeconds(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, "Z")
}

export function isValidStatusId(id: string): boolean {
  return /^[a-z0-9_-]{1,32}$/.test(id)
}

function clip(s: string, max: number): string {
  const cps = Array.from(s)
  return cps.length > max ? cps.slice(0, max).join("") : s
}

function isPositiveNumber(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v) && v > 0
}

export function parseStatusBody(raw: string): { ok: true; body: ParsedBody } | { ok: false; reason: string } {
  let o: unknown
  try { o = JSON.parse(raw) } catch { return { ok: false, reason: "body 不是 JSON" } }
  if (!o || typeof o !== "object" || Array.isArray(o)) return { ok: false, reason: "body 要是 JSON 对象" }
  const r = o as Record<string, unknown>
  if (typeof r.checkedAt !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(r.checkedAt) || Number.isNaN(Date.parse(r.checkedAt))) {
    return { ok: false, reason: "checkedAt 要是能解析的 ISO8601 时间" }
  }
  if (r.title !== undefined && typeof r.title !== "string") return { ok: false, reason: "title 要是字符串" }
  if (r.staleAfterHours !== undefined && !isPositiveNumber(r.staleAfterHours)) return { ok: false, reason: "staleAfterHours 要是正数" }
  if (!Array.isArray(r.items) || r.items.length < 1 || r.items.length > ITEMS_MAX) return { ok: false, reason: `items 要是 1–${ITEMS_MAX} 项的数组` }
  const items: StatusItem[] = []
  for (const [i, it] of r.items.entries()) {
    if (!it || typeof it !== "object") return { ok: false, reason: `items[${i}] 要是对象` }
    const e = it as Record<string, unknown>
    const name = typeof e.name === "string" ? e.name.replace(/[\r\n]/g, " ").trim() : ""
    if (!name) return { ok: false, reason: `items[${i}].name 必填` }
    if (typeof e.ok !== "boolean") return { ok: false, reason: `items[${i}].ok 要是 true/false` }
    if (e.detail !== undefined && typeof e.detail !== "string") return { ok: false, reason: `items[${i}].detail 要是字符串` }
    items.push({ name: clip(name, NAME_MAX), ok: e.ok, detail: clip(typeof e.detail === "string" ? e.detail : "", DETAIL_MAX) })
  }
  const title = typeof r.title === "string" && r.title.trim() ? clip(r.title.trim(), TITLE_MAX) : undefined
  return { ok: true, body: { title, checkedAt: r.checkedAt, staleAfterHours: r.staleAfterHours as number | undefined, items } }
}

/** 标题：配置 title > body title > id */
export function resolveTitle(id: string, conf: StatusSourceConfig | undefined, bodyTitle: string | undefined): string {
  return conf?.title || bodyTitle || id
}

export function normalizeReport(id: string, body: ParsedBody, conf: StatusSourceConfig | undefined, now: Date): StatusReport {
  return {
    id,
    title: resolveTitle(id, conf, body.title),
    checkedAt: isoSeconds(new Date(body.checkedAt)),
    staleAfterHours: conf?.staleAfterHours ?? body.staleAfterHours ?? DEFAULT_STALE_HOURS,
    items: body.items,
    receivedAt: isoSeconds(now),
  }
}

export function badNames(items: StatusItem[]): string[] {
  return items.filter((i) => !i.ok).map((i) => i.name)
}

export function badKey(items: StatusItem[]): string {
  return badNames(items).sort().join("\n")
}

function minutesOf(hhmm: string): number {
  const [h, m] = hhmm.split(":").map(Number)
  return h * 60 + m
}

export function isValidHHmm(s: unknown): s is string {
  return typeof s === "string" && /^([01]\d|2[0-3]):[0-5]\d$/.test(s)
}

export function isValidTimeZone(tz: unknown): tz is string {
  if (typeof tz !== "string" || !tz) return false
  try { new Intl.DateTimeFormat("en-US", { timeZone: tz }); return true } catch { return false }
}

/** 按 quiet.tz（IANA）的墙钟判断，不看 hub 本机时区；start > end 为跨午夜区间；start == end 视为没有静音 */
export function isQuietAt(now: Date, quiet: QuietConfig): boolean {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: quiet.tz, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(now)
  const h = Number(parts.find((p) => p.type === "hour")?.value ?? 0)
  const m = Number(parts.find((p) => p.type === "minute")?.value ?? 0)
  const cur = h * 60 + m
  const s = minutesOf(quiet.start)
  const e = minutesOf(quiet.end)
  if (s === e) return false
  return s < e ? cur >= s && cur < e : cur >= s || cur < e
}

export function badText(title: string, names: string[]): string {
  return `${title}掉了 ${names.length} 颗：${names.slice(0, 3).join("、")}${names.length > 3 ? "等" : ""}。点我看原因。`
}

export function recoveredText(title: string, n: number): string {
  return `${title}又串满了，刚才那 ${n} 条都通了。`
}

const EMPTY_SOURCE_STATE: SourceAlertState = { notifiedKey: "", notifiedAt: null, notifiedBad: false, lastAlertId: null }

export interface DecideInput {
  state: AlertState
  source: string
  title: string
  items: StatusItem[]
  now: Date
  quiet: QuietConfig
  newId?: () => string
}
export interface DecideResult { state: AlertState; alert: StatusAlert | null; push: StatusPush | null }

/** §7.4 提醒判定。纯函数：不改入参，返回新 state + 要投的提醒 + 要立刻推的推送（静音中进 deferredPushes） */
export function decide(input: DecideInput): DecideResult {
  const { source, title, items, now, quiet } = input
  const newId = input.newId ?? randomUUID
  const prev = input.state.sources[source] ?? EMPTY_SOURCE_STATE
  let deferred = input.state.deferredPushes
  const key = badKey(items)
  const names = badNames(items)
  const withSource = (s: SourceAlertState, d: StatusPush[]): AlertState => ({ sources: { ...input.state.sources, [source]: s }, deferredPushes: d })

  let alert: StatusAlert | null = null
  let next: SourceAlertState = prev
  if (key) {
    const since = prev.notifiedAt ? now.getTime() - Date.parse(prev.notifiedAt) : Infinity
    if (key === prev.notifiedKey && since < REPEAT_AFTER_MS) return { state: input.state, alert: null, push: null }
    alert = { id: newId(), source, title, kind: "bad", text: badText(title, names), names, createdAt: isoSeconds(now) }
    next = { notifiedKey: key, notifiedAt: isoSeconds(now), notifiedBad: true, lastAlertId: alert.id }
  } else {
    if (!prev.notifiedBad) return { state: input.state, alert: null, push: null }
    const was = prev.notifiedKey ? prev.notifiedKey.split("\n") : []
    alert = { id: newId(), source, title, kind: "recovered", text: recoveredText(title, was.length), names: was, createdAt: isoSeconds(now) }
    next = { ...prev, notifiedKey: "", notifiedBad: false, lastAlertId: alert.id }
    if (deferred.some((p) => p.source === source && p.kind === "bad")) {
      deferred = deferred.filter((p) => p.source !== source)
      return { state: withSource(next, deferred), alert, push: null }
    }
  }
  const push: StatusPush = { alertId: alert.id, source, kind: alert.kind, text: alert.text }
  if (isQuietAt(now, quiet)) {
    deferred = [...deferred.filter((p) => p.source !== source), push]
    return { state: withSource(next, deferred), alert, push: null }
  }
  return { state: withSource(next, deferred.filter((p) => p.source !== source)), alert, push }
}

/** 出了静音时段：取出全部延后推送，队列清空 */
export function releaseDeferred(state: AlertState, now: Date, quiet: QuietConfig): { state: AlertState; pushes: StatusPush[] } {
  if (state.deferredPushes.length === 0 || isQuietAt(now, quiet)) return { state, pushes: [] }
  return { state: { ...state, deferredPushes: [] }, pushes: state.deferredPushes }
}

// MARK: - 落盘（agent/ 下，§7.3）

function readJson(path: string): unknown {
  try { return JSON.parse(readFileSync(path, "utf8")) } catch { return undefined }
}

export function loadStatusSources(dir: string = agentDir()): Record<string, StatusSourceConfig> {
  const raw = readJson(join(dir, "status-sources.json"))
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {}
  const out: Record<string, StatusSourceConfig> = {}
  for (const [id, v] of Object.entries(raw as Record<string, unknown>)) {
    if (!isValidStatusId(id) || !v || typeof v !== "object") continue
    const c = v as Record<string, unknown>
    const conf: StatusSourceConfig = {}
    if (typeof c.title === "string" && c.title.trim()) conf.title = clip(c.title.trim(), TITLE_MAX)
    if (typeof c.run === "string" && c.run.trim()) conf.run = c.run.trim()
    if (isPositiveNumber(c.staleAfterHours)) conf.staleAfterHours = c.staleAfterHours
    out[id] = conf
  }
  return out
}

function isStatusReport(v: unknown): v is StatusReport {
  if (!v || typeof v !== "object") return false
  const r = v as Record<string, unknown>
  return typeof r.id === "string" && typeof r.title === "string" && typeof r.checkedAt === "string"
    && typeof r.staleAfterHours === "number" && Array.isArray(r.items) && typeof r.receivedAt === "string"
}

export function saveStatusReport(report: StatusReport, dir: string = agentDir()): void {
  saveJsonPrivate(join(dir, "status", `${report.id}.json`), report)
}

export function listStatusReports(dir: string = agentDir()): StatusReport[] {
  const d = join(dir, "status")
  if (!existsSync(d)) return []
  const out: StatusReport[] = []
  for (const f of readdirSync(d)) {
    if (!f.endsWith(".json") || !isValidStatusId(f.slice(0, -5))) continue
    const r = readJson(join(d, f))
    if (isStatusReport(r) && r.id === f.slice(0, -5)) out.push(r)
  }
  return out.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
}

export function loadAlertState(dir: string = agentDir()): AlertState {
  const raw = readJson(join(dir, "status-alert-state.json"))
  if (!raw || typeof raw !== "object") return { sources: {}, deferredPushes: [] }
  const r = raw as Record<string, unknown>
  const sources = r.sources && typeof r.sources === "object" ? (r.sources as Record<string, SourceAlertState>) : {}
  const deferredPushes = Array.isArray(r.deferredPushes) ? (r.deferredPushes as StatusPush[]) : []
  return { sources, deferredPushes }
}

export function saveAlertState(state: AlertState, dir: string = agentDir()): void {
  saveJsonPrivate(join(dir, "status-alert-state.json"), state)
}

export function parseQuiet(v: unknown): QuietConfig | null {
  if (!v || typeof v !== "object") return null
  const r = v as Record<string, unknown>
  if (!isValidHHmm(r.start) || !isValidHHmm(r.end) || !isValidTimeZone(r.tz)) return null
  return { start: r.start, end: r.end, tz: r.tz }
}

export function loadQuiet(dir: string = agentDir()): QuietConfig {
  return parseQuiet(readJson(join(dir, "status-quiet.json"))) ?? DEFAULT_QUIET
}

export function saveQuiet(quiet: QuietConfig, dir: string = agentDir()): void {
  saveJsonPrivate(join(dir, "status-quiet.json"), quiet)
}

// MARK: - 编排（hub 接线调这几个）

export type IngestResult = { ok: true; alert: StatusAlert | null; push: StatusPush | null } | { ok: false; reason: string }

/** POST /agent/status/:id 的全部逻辑：校验 → 存报告 → 判定 → 投递成功才落「已通知」状态（投递失败 = 这次当没喊，下次报告重判） */
export function ingestStatusReport(id: string, raw: string, deliver: (alert: StatusAlert) => boolean, now: Date = new Date(), dir: string = agentDir()): IngestResult {
  if (!isValidStatusId(id)) return { ok: false, reason: "源 id 要匹配 ^[a-z0-9_-]{1,32}$" }
  const parsed = parseStatusBody(raw)
  if (!parsed.ok) return parsed
  const report = normalizeReport(id, parsed.body, loadStatusSources(dir)[id], now)
  saveStatusReport(report, dir)
  const r = decide({ state: loadAlertState(dir), source: id, title: report.title, items: report.items, now, quiet: loadQuiet(dir) })
  if (!r.alert) return { ok: true, alert: null, push: null }
  let delivered: boolean
  try { delivered = deliver(r.alert) } catch (e) { console.warn(`[hub] status ${id} 小芽提醒投递抛错: ${e}`); delivered = false }
  if (!delivered) {
    console.warn(`[hub] status ${id} 小芽提醒没投出去，不推送、不记已通知`)
    return { ok: true, alert: null, push: null }
  }
  saveAlertState(r.state, dir)
  return { ok: true, alert: r.alert, push: r.push }
}

/** 巡检：出了静音时段就把延后推送全取出来（并落盘清空） */
export function takeDuePushes(now: Date = new Date(), dir: string = agentDir()): StatusPush[] {
  const state = loadAlertState(dir)
  const r = releaseDeferred(state, now, loadQuiet(dir))
  if (r.pushes.length) saveAlertState(r.state, dir)
  return r.pushes
}

export interface StatusResultFrame {
  type: "status_result"
  sources: (StatusReport & { canRun: boolean; running: boolean })[]
  quiet: QuietConfig
}

export function statusResultFrame(isRunning: (id: string) => boolean, dir: string = agentDir()): StatusResultFrame {
  const conf = loadStatusSources(dir)
  const sources = listStatusReports(dir).map((r) => ({
    ...r,
    title: conf[r.id]?.title ?? r.title,
    staleAfterHours: conf[r.id]?.staleAfterHours ?? r.staleAfterHours,
    canRun: !!conf[r.id]?.run,
    running: isRunning(r.id),
  }))
  return { type: "status_result", sources, quiet: loadQuiet(dir) }
}

export function expandScriptPath(raw: string, home: string = homedir()): string | null {
  const p = raw === "~" ? home : raw.startsWith("~/") ? join(home, raw.slice(2)) : raw
  return isAbsolute(p) && !p.includes("\0") ? p : null
}

/** 「立即检修」：只跑 status-sources.json 里配了 run 的源；同一源正在跑就忽略；超时整组 kill */
export class StatusRunner {
  private readonly running = new Map<string, ChildProcess>()
  constructor(private readonly onChange: () => void, private readonly timeoutMs: number = RUN_TIMEOUT_MS, private readonly dir: () => string = agentDir) {}

  isRunning(id: string): boolean {
    return this.running.has(id)
  }

  run(id: string): boolean {
    if (!isValidStatusId(id) || this.running.has(id)) return false
    const raw = loadStatusSources(this.dir())[id]?.run
    const script = raw ? expandScriptPath(raw) : null
    if (!script) return false
    let child: ChildProcess
    try {
      child = spawn("bash", [script], { stdio: "ignore", detached: true })
      child.unref()
    } catch (e) {
      console.warn(`[hub] status_run ${id} 起不来: ${e}`)
      return false
    }
    this.running.set(id, child)
    const timer = setTimeout(() => {
      console.warn(`[hub] status_run ${id} 超时 ${this.timeoutMs}ms，kill`)
      try { if (child.pid) process.kill(-child.pid, "SIGKILL") } catch { child.kill("SIGKILL") }
    }, this.timeoutMs)
    timer.unref()
    const done = () => {
      clearTimeout(timer)
      if (this.running.get(id) !== child) return
      this.running.delete(id)
      this.onChange()
    }
    child.once("exit", done)
    child.once("error", (e) => { console.warn(`[hub] status_run ${id} 失败: ${e}`); done() })
    this.onChange()
    return true
  }
}
