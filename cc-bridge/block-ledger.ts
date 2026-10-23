/// 阻塞调用账（plan-hub-perf §3.2）：hub 主线程上每个同步调用都计时。
/// - 按调用点（"tmux send-keys"、"fs.writeFileSync session-map.json"…）累计次数 / 总耗时 / 最大
/// - 单次 ≥ SLOW_MS 记进近期环（给卡顿归因），≥ LOG_MS 立刻打一行 `[block]`
/// - 主循环卡顿时 attribute(from, to) 给出这段时间里各调用点占了多少，剩下的 = GC / 换页 / JS 本身
/// 零行为改动：只包一层计时，异常照抛。
import type { Database, Statement } from "bun:sqlite"
import { execFileSync } from "node:child_process"
import * as fs from "node:fs"

export const SLOW_MS = 20
export const LOG_MS = 500
const RING_MS = 5 * 60_000
export const MAX_SITES = 512
export const OTHER_SITE = "（其他）"

export interface BlockStat { count: number; totalMs: number; maxMs: number }
interface BlockEvent { site: string; end: number; ms: number }

export class BlockLedger {
  readonly stats = new Map<string, BlockStat>()
  private recent: BlockEvent[] = []
  constructor(
    private readonly now: () => number = Date.now,
    private readonly log: (line: string) => void = (l) => console.warn(l),
  ) {}

  record(site: string, ms: number): void {
    // 累计表有上限（审查 R1-5）：满了之后新站点并进「其他」；近期环 / 日志行照用原名
    const key = this.stats.has(site) || this.stats.size < MAX_SITES - 1 ? site : OTHER_SITE
    const s = this.stats.get(key) ?? { count: 0, totalMs: 0, maxMs: 0 }
    s.count++; s.totalMs += ms; if (ms > s.maxMs) s.maxMs = ms
    this.stats.set(key, s)
    if (ms < SLOW_MS) return
    const end = this.now()
    this.recent.push({ site, end, ms })
    while (this.recent.length && this.recent[0].end < end - RING_MS) this.recent.shift()
    if (ms >= LOG_MS) this.log(`[block] ${site} ${Math.round(ms)}ms`)
  }

  /// 别的线程（K2 warroom worker）送回来的累计表并进来：只进累计表，不进近期环——
  /// 那边的阻塞不占主循环，不能被 explainLag 算成主线程卡顿
  mergeStats(entries: Iterable<readonly [string, BlockStat]>): void {
    for (const [site, add] of entries) {
      const key = this.stats.has(site) || this.stats.size < MAX_SITES - 1 ? site : OTHER_SITE
      const s = this.stats.get(key) ?? { count: 0, totalMs: 0, maxMs: 0 }
      s.count += add.count; s.totalMs += add.totalMs; if (add.maxMs > s.maxMs) s.maxMs = add.maxMs
      this.stats.set(key, s)
    }
  }

  time<T>(site: string, fn: () => T): T {
    const t0 = performance.now()
    try { return fn() } finally { this.record(site, performance.now() - t0) }
  }

  /// [from, to] 里各调用点的阻塞毫秒（按重叠算），降序
  attribute(from: number, to: number): Array<[string, number]> {
    const by = new Map<string, number>()
    for (const e of this.recent) {
      const a = Math.max(e.end - e.ms, from), b = Math.min(e.end, to)
      if (b > a) by.set(e.site, (by.get(e.site) ?? 0) + (b - a))
    }
    return [...by].map(([k, v]) => [k, Math.round(v)] as [string, number]).sort((x, y) => y[1] - x[1])
  }

  /// [from, to] 里被记过账的时间（区间并集：ws 处理和它里面的 fs 调用重叠，只算一次）
  covered(from: number, to: number): number {
    const spans = this.recent
      .map((e) => [Math.max(e.end - e.ms, from), Math.min(e.end, to)] as const)
      .filter(([a, b]) => b > a)
      .sort((x, y) => x[0] - y[0])
    let total = 0, curA = -Infinity, curB = -Infinity
    for (const [a, b] of spans) {
      if (a > curB) { if (curB > curA) total += curB - curA; curA = a; curB = b } else if (b > curB) curB = b
    }
    if (curB > curA) total += curB - curA
    return total
  }

  /// 卡顿一行说明：「其中 tmux send-keys 2300ms、fs.statSync 400ms；其余 1200ms（GC / 换页 / JS）」
  explainLag(end: number, lagMs: number): string {
    const parts = this.attribute(end - lagMs, end)
    const known = this.covered(end - lagMs, end)
    const top = parts.slice(0, 4).map(([k, v]) => `${k} ${v}ms`).join("、")
    return `${top ? `其中 ${top}；` : ""}其余 ${Math.max(0, Math.round(lagMs - known))}ms（GC / 换页 / JS）`
  }

  /// 按总耗时排的前 n 个调用点
  top(n = 15): Array<[string, BlockStat]> {
    return [...this.stats].sort((a, b) => b[1].totalMs - a[1].totalMs).slice(0, n)
  }
}

/// 调用点标签：命令 + 第一个参数（tmux send-keys / git rev-parse）；文件只留文件名
export function execSite(file: string, args: readonly string[] | undefined): string {
  return args && args.length ? `${file} ${args[0]}` : file
}
export function fsSite(op: string, path: unknown): string {
  const p = typeof path === "string" ? path : typeof path === "number" ? "fd" : String(path)
  // transcript / fifo / 原子写临时文件这类带 uuid / 随机后缀 / 时间戳的归成一类，免得调用点表无限长
  const name = p.slice(p.lastIndexOf("/") + 1)
    .replace(/\.tmp[-.][^/]*$/i, ".tmp-*")
    .replace(/[0-9a-f]{8}-[0-9a-f-]{27,}/gi, "*")
    .replace(/\d{4}-\d{2}-\d{2}T[\d:.-]+/g, "*")
    .replace(/(?<![0-9a-z])[0-9a-f]{8,}(?![0-9a-z])/gi, "*")
    .replace(/\d{6,}/g, "*")
    .replace(/\*{2,}/g, "*")
  return `fs.${op} ${name}`
}

// ── hub 进程共用一本账：hub.ts 和它带起来的各模块（warroom / agora / 账本…）的同步调用都记这里 ──
export const blockLedger = new BlockLedger()

type SyncFn = (...a: never[]) => unknown
const call = (f: SyncFn, a: unknown[]): unknown => (f as (...x: unknown[]) => unknown)(...a)

/// 同步 fs 函数套计时；prefix 区分模块（"warroom " → `warroom fs.statSync *.jsonl`）
export function timedFs<F extends SyncFn>(op: string, f: F, prefix = "", ledger = blockLedger): F {
  return ((...a: unknown[]) => ledger.time(prefix + fsSite(op, a[0]), () => call(f, a))) as unknown as F
}

/// 一个模块常用的同步 fs 全套计时版：`const { readFileSync } = timedSyncFs("warroom ")`
export function timedSyncFs(prefix: string, ledger = blockLedger) {
  const t = <F extends SyncFn>(op: string, f: F) => timedFs(op, f, prefix, ledger)
  return {
    readFileSync: t("readFileSync", fs.readFileSync), writeFileSync: t("writeFileSync", fs.writeFileSync),
    appendFileSync: t("appendFileSync", fs.appendFileSync), existsSync: t("existsSync", fs.existsSync),
    statSync: t("statSync", fs.statSync), lstatSync: t("lstatSync", fs.lstatSync), fstatSync: t("fstatSync", fs.fstatSync),
    readdirSync: t("readdirSync", fs.readdirSync), mkdirSync: t("mkdirSync", fs.mkdirSync),
    renameSync: t("renameSync", fs.renameSync), unlinkSync: t("unlinkSync", fs.unlinkSync), rmSync: t("rmSync", fs.rmSync),
    copyFileSync: t("copyFileSync", fs.copyFileSync), chmodSync: t("chmodSync", fs.chmodSync),
    openSync: t("openSync", fs.openSync), readSync: t("readSync", fs.readSync), writeSync: t("writeSync", fs.writeSync),
    closeSync: t("closeSync", fs.closeSync), fsyncSync: t("fsyncSync", fs.fsyncSync),
    realpathSync: t("realpathSync", fs.realpathSync), mkdtempSync: t("mkdtempSync", fs.mkdtempSync),
  }
}

/// execFileSync 套计时（站点 = 命令 + 第一个参数）
export function timedExecFileSync(prefix = "", ledger = blockLedger): typeof execFileSync {
  return ((file: string, args?: readonly string[], opts?: object) =>
    ledger.time(prefix + execSite(file, args), () => call(execFileSync, [file, args, opts]))) as unknown as typeof execFileSync
}

/// SQL → 站点名里的动作 + 表（`SELECT tasks` / `INSERT mentions` / `BEGIN`）
export function sqlVerb(sql: string): string {
  const s = sql.trim()
  const w = /^(INSERT(?:\s+OR\s+\w+)?\s+INTO|REPLACE\s+INTO|UPDATE(?:\s+OR\s+\w+)?|DELETE\s+FROM)\s+["`]?(\w+)/i.exec(s)
  if (w) return `${w[1].split(/\s+/)[0].toUpperCase()} ${w[2]}`
  const verb = (/^\w+/.exec(s)?.[0] ?? "?").toUpperCase()
  if (verb === "SELECT" || verb === "WITH") { const f = /\bFROM\s+["`]?(\w+)/i.exec(s); return f ? `SELECT ${f[1]}` : "SELECT" }
  return verb
}

const timedDbs = new WeakSet<Database>()
/// bun:sqlite 库套计时：query / prepare 出来的语句 run / get / all / values，以及 exec / run。
/// 站点 `sqlite <label> <动作 表>`。语句对象被 db 缓存复用，同一个只包一次
export function timeSqlite(db: Database, label: string, ledger = blockLedger): Database {
  if (timedDbs.has(db)) return db
  timedDbs.add(db)
  const wrapped = new WeakSet<Statement>()
  const wrap = (s: Statement, sql: string): Statement => {
    if (wrapped.has(s)) return s
    wrapped.add(s)
    const site = `sqlite ${label} ${sqlVerb(sql)}`
    for (const m of ["run", "get", "all", "values"] as const) {
      const orig = s[m] as SyncFn
      Object.defineProperty(s, m, { value: (...a: unknown[]) => ledger.time(site, () => call(orig.bind(s), a)), writable: true, configurable: true })
    }
    return s
  }
  const query = db.query.bind(db), prepare = db.prepare.bind(db), exec = db.exec.bind(db), run = db.run.bind(db)
  db.query = ((sql: string) => wrap(query(sql), sql)) as typeof db.query
  db.prepare = ((sql: string, ...a: unknown[]) => wrap(call(prepare, [sql, ...a]) as Statement, sql)) as typeof db.prepare
  db.exec = ((sql: string, ...a: unknown[]) => ledger.time(`sqlite ${label} ${sqlVerb(sql)}`, () => call(exec, [sql, ...a]))) as typeof db.exec
  db.run = ((sql: string, ...a: unknown[]) => ledger.time(`sqlite ${label} ${sqlVerb(sql)}`, () => call(run, [sql, ...a]))) as typeof db.run
  return db
}

/// 事件处理计时阈值：WS 一条消息 / 一次连上的处理 ≥ 这么久才记
export const HANDLER_MS = 50
/// WS 处理的站点名：`ws client_info` / `ws connect /cc`。名字来自客户端，不像标识符的一律 `?`，免得调用点表被刷爆
export function wsSite(prefix: string, kind: unknown): string {
  return `${prefix} ${typeof kind === "string" && /^\/?[A-Za-z0-9_]{1,40}$/.test(kind) ? kind : "?"}`
}
/// 事件处理器计时：只量同步那一段（到第一个 await 为止，那才占着主循环）；≥ minMs 才记，站点名处理完再取
export function timeHandler<R>(site: () => string, fn: () => R, minMs = HANDLER_MS, ledger = blockLedger): R {
  const t0 = performance.now()
  try { return fn() } finally {
    const ms = performance.now() - t0
    if (ms >= minMs) ledger.record(site(), ms)
  }
}

// ── 卡顿时的进程体征：区分 GC / 换页 / 纯 JS ──
/// switches：macOS 上 involuntaryContextSwitches 其实是全部上下文切换（阻塞等待也算进来），
/// voluntaryContextSwitches 恒 +0 所以不采；minorFaults 含内存压缩器解压（不算硬缺页）
export interface ProcSample { cpuMs: number; majorFaults: number; heapMB: number; rssMB: number; switches: number; minorFaults: number }
export function procSample(): ProcSample {
  const r = process.resourceUsage()
  const m = process.memoryUsage()
  return { cpuMs: (r.userCPUTime + r.systemCPUTime) / 1000, majorFaults: r.majorPageFault, heapMB: m.heapUsed / 2 ** 20, rssMB: m.rss / 2 ** 20, switches: r.involuntaryContextSwitches, minorFaults: r.minorPageFault }
}
/// 「CPU 800ms/5162ms、硬缺页 +3400、堆 180→95MB（回收过）、rss 140MB、切换 +900、软缺页 +1200」
/// CPU 远小于卡顿 + 硬缺页多 = 在等换页；CPU ≈ 卡顿 + 堆掉了 = GC；CPU ≈ 卡顿 + 堆没掉 = JS
/// CPU 远小于卡顿 + 软缺页多 = 在解压被压缩的页；切换只有个位数 = 一直睡在某个阻塞调用里（本机实测 sleep 1s 切换 +2~12，满载空转 1s +900~1800）
export function describeLagVitals(prev: ProcSample, cur: ProcSample, lagMs: number): string {
  const r = Math.round
  const gc = cur.heapMB < prev.heapMB - 1 ? "（回收过）" : ""
  return `CPU ${r(cur.cpuMs - prev.cpuMs)}ms/${r(lagMs)}ms、硬缺页 +${cur.majorFaults - prev.majorFaults}、堆 ${r(prev.heapMB)}→${r(cur.heapMB)}MB${gc}、rss ${r(cur.rssMB)}MB、切换 +${cur.switches - prev.switches}、软缺页 +${cur.minorFaults - prev.minorFaults}`
}
