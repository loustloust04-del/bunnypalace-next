// 刀 K2（docs/plan-hub-perf.md）：warroom 普查扫描搬进 Worker 线程——主线程这一侧。
// 10-11 现场 `[block] top` 全是 warroom 的同步 stat / sqlite（10 分钟约 3 万次，尾巴 0.5–1.2s，CPU≈0 在等盘），
// 挪走后主线程只剩读查询（querySessions / lookupTarget / 看板）和奏折账本写。
// worker 入口见 warroom-scan-worker.ts；MP_HUB_PERF_K2=0 退回主线程 scanAllAsync。
import { blockLedger as mainLedger, type BlockLedger, type BlockStat } from "./block-ledger"
import type { CheckpointResult, IndexerOptions } from "./warroom-indexer"

/// kind=checkpoint：只做一次 WAL 检查点（扫描被过载跳过时也要有人回写 WAL，K2 审查 R1-3）
export interface ScanRequest { id: number; kind: "scan" | "checkpoint"; opts: IndexerOptions; liveness: "real" | "none" }
/// ready：worker 模块加载完（import 都成功）后主动发一次——收到它之前出的错都算「启动不可用」，不算单轮失败
export type ScanReply =
  | { type: "ready" }
  | { type: "done"; id: number; scanned: number; changed: number; ms: number; block: Array<[string, BlockStat]>; checkpoint: CheckpointResult | null }
  | { type: "fail"; id: number; error: string; block: Array<[string, BlockStat]> }

export function k2Enabled(): boolean { return process.env.MP_HUB_PERF_K2 !== "0" }

/// 一轮的上限：主线程版首扫在 swap 打满时 2–3 分钟。30 分钟还没回就当 worker 卡死了，杀掉、下一轮重建
///（已提交的批次都在库里，从断点续）
export const SCAN_TIMEOUT_MS = 30 * 60_000
/// K2 审查 R1-4：worker 起不来（入口 ModuleNotFound、加载就崩、迟迟不发 ready）连试几次，都不行就判「不可用」，
/// 普查轮退回主线程扫描（hub 进程这辈子不再试 K2）
export const MAX_START_ATTEMPTS = 3
export const READY_TIMEOUT_MS = 30_000
export const START_BACKOFF_MS = 1_000

/// Bun 的 Worker 有 ref / unref（DOM 类型里没有）
type BunWorker = Worker & { ref(): void; unref(): void }
const refWorker = (w: Worker, on: boolean) => { const b = w as BunWorker; if (on) b.ref(); else b.unref() }

/// worker 起不来，普查轮据此退回主线程
export class WorkerUnavailable extends Error {}

export interface ScanWorkerOptions {
  indexer: IndexerOptions
  liveness?: "real" | "none"          // none = 不跑 tmux / ps（测试用，按「没有活进程」刷新）
  workerUrl?: string | URL            // 测试换成会崩的假 worker
  ledger?: BlockLedger                // worker 送回的阻塞账并进哪本（默认 hub 主账）
  timeoutMs?: number
  readyTimeoutMs?: number
  startBackoffMs?: number
  onReady?: () => void                // 第一次 ready（hub 在这时才关主连接检查点、打「K2 就绪」）
  log?: (line: string) => void
}

export interface ScanSummary { at: string; scanned: number; changed: number; ms: number }

/// hub 的普查轮（原来写在 hub.ts startHub 里，K2 抽出来好测）：首扫慢，定时器不许叠；
/// 机器过载（5 分钟负载 > 40）跳过增量，最多跳 30 分钟。worker = null（K2 关）走主线程 scanAllAsync
export function warroomScanRunner(d: {
  scanMain: () => Promise<{ scanned: number; changed: number }>
  worker: Pick<WarroomScanWorker, "scan" | "checkpoint" | "unavailable"> | null
  load5: () => number
  onScan: (s: ScanSummary) => void
  onFallback?: () => void              // worker 判不可用、退回主线程那一刻（hub 恢复主连接自动检查点）
  log?: (line: string) => void
  warn?: (line: string) => void
  now?: () => number
}): (label: string) => Promise<void> {
  const now = d.now ?? Date.now
  const log = d.log ?? ((l) => console.log(l))
  const warn = d.warn ?? ((l) => console.warn(l))
  let scanRunning = false
  let lastScanAt = 0
  return async (label) => {
    if (scanRunning) return
    // 机器过载先跳过：一轮扫 7700 个文件在 swap 打满时要 2–3 分钟（10-10）。最多跳 30 分钟，到了照扫
    if (label !== "initial" && d.load5() > 40 && now() - lastScanAt < 30 * 60_000) {
      // K2 审查 R1-3：扫描跳过也要回写 WAL（主连接关了自动检查点）——只做检查点，在 worker 里做，不在主线程
      if (d.worker && !d.worker.unavailable) {
        scanRunning = true
        try { await d.worker.checkpoint() } catch (e) { warn(`[warroom] 检查点失败：${(e as Error)?.message}`) }
        finally { scanRunning = false }
      }
      return
    }
    scanRunning = true
    lastScanAt = now()
    const t0 = now()
    try {
      let r: { scanned: number; changed: number }
      if (d.worker && !d.worker.unavailable) {
        try { r = await d.worker.scan() } catch (e) {
          if (!(e instanceof WorkerUnavailable)) throw e
          warn(`[warroom] ${(e as Error).message}，普查扫描退回主线程`)
          d.onFallback?.()
          r = await d.scanMain()
        }
      } else r = await d.scanMain()
      d.onScan({ at: new Date(now()).toISOString(), scanned: r.scanned, changed: r.changed, ms: now() - t0 })
      if (r.changed > 0 || label === "initial") log(`[warroom] ${label} scan: ${r.scanned} files, ${r.changed} changed, ${now() - t0}ms`)
    } catch (e) { warn(`[warroom] ${label} scan fail: ${(e as Error)?.message}`) }
    finally { scanRunning = false }
  }
}

/// Bun 的 worker 错误消息带源码片段，日志只留「error: …」那一行
function errorLine(message: string): string {
  const lines = String(message ?? "").split("\n").map((l) => l.trim())
  return lines.find((l) => l.startsWith("error: ")) ?? lines[0] ?? ""
}

/// 一次只跑一轮；worker 崩了 / 退了 / 超时 → 本轮 reject，扔掉 worker，下一轮 scan() 重建。
/// 起不来（ready 之前就失败）连试 MAX_START_ATTEMPTS 次，都不行 → WorkerUnavailable，此后 unavailable=true。永远不抛同步异常。
/// 空闲时 unref（不拖住进程自然退出），有请求在跑时 ref
export class WarroomScanWorker {
  private worker: Worker | null = null
  private inflight: { id: number; resolve: (r: Extract<ScanReply, { type: "done" }>) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> } | null = null
  private busy = false
  private seq = 0
  private everReady = false
  private starting: Worker | null = null
  private stopped = false
  unavailable = false
  private readonly ledger: BlockLedger
  private readonly log: (line: string) => void

  constructor(private readonly o: ScanWorkerOptions) {
    this.ledger = o.ledger ?? mainLedger
    this.log = o.log ?? ((l) => console.warn(l))
  }

  async scan(): Promise<{ scanned: number; changed: number }> {
    const r = await this.request("scan")
    return { scanned: r.scanned, changed: r.changed }
  }

  /// 只做一次 WAL 检查点（worker 起着就用它，没起就先起）
  async checkpoint(): Promise<CheckpointResult | null> {
    return (await this.request("checkpoint")).checkpoint
  }

  private async request(kind: ScanRequest["kind"]): Promise<Extract<ScanReply, { type: "done" }>> {
    if (this.unavailable) throw new WorkerUnavailable("scan worker 不可用")
    if (this.stopped) throw new Error("scan worker 已终止")
    if (this.busy) throw new Error("上一轮还没扫完")
    this.busy = true
    try {
      const w = await this.ensureReady()
      return await this.send(w, kind)
    } finally { this.busy = false }
  }

  /// hub 退出时调；在跑的一轮 reject（调用方都在 try 里 await）
  terminate(): void {
    this.stopped = true
    try { this.starting?.terminate() } catch {}
    const w = this.worker
    this.worker = null
    if (w) w.terminate()
    const f = this.inflight
    this.inflight = null
    if (f) { clearTimeout(f.timer); f.reject(new Error("scan worker 已终止")) }
  }

  get alive(): boolean { return this.worker !== null }

  private send(w: Worker, kind: ScanRequest["kind"]): Promise<Extract<ScanReply, { type: "done" }>> {
    const id = ++this.seq
    const timeoutMs = this.o.timeoutMs ?? SCAN_TIMEOUT_MS
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.fail(w, `scan worker ${Math.round(timeoutMs / 1000)}s 没回，杀掉重建`), timeoutMs)
      this.inflight = { id, resolve, reject, timer }
      refWorker(w, true)
      const req: ScanRequest = { id, kind, opts: this.o.indexer, liveness: this.o.liveness ?? "real" }
      try { w.postMessage(req) } catch (e) { this.fail(w, `发不出扫描请求：${(e as Error)?.message ?? e}`) }
    })
  }

  private async ensureReady(): Promise<Worker> {
    if (this.worker) return this.worker
    const attempts = MAX_START_ATTEMPTS
    let last = ""
    for (let i = 1; i <= attempts; i++) {
      try {
        const w = await this.spawnOnce()
        this.attach(w)
        if (!this.everReady) { this.everReady = true; this.o.onReady?.() }
        return w
      } catch (e) {
        if (this.stopped) throw new Error("scan worker 已终止")
        last = (e as Error)?.message ?? String(e)
        this.log(`[warroom] scan worker 起不来（第 ${i}/${attempts} 次）：${last}`)
        if (i < attempts) await Bun.sleep((this.o.startBackoffMs ?? START_BACKOFF_MS) * i)
      }
    }
    this.unavailable = true
    throw new WorkerUnavailable(`scan worker 连续 ${attempts} 次起不来（${last}）`)
  }

  /// 起一个 worker，等它发 ready；之前的 error / close / 超时都算这次启动失败
  private spawnOnce(): Promise<Worker> {
    return new Promise((resolve, reject) => {
      let w: Worker
      try { w = new Worker(this.o.workerUrl ?? new URL("./warroom-scan-worker.ts", import.meta.url)) } catch (e) { reject(e); return }
      this.starting = w
      const done = (err: string | null) => {
        clearTimeout(timer)
        this.starting = null
        w.removeEventListener("message", onMessage)
        w.removeEventListener("error", onError)
        w.removeEventListener("close", onClose)
        if (err === null && this.stopped) err = "scan worker 已终止"
        if (err === null) { resolve(w); return }
        try { w.terminate() } catch {}
        reject(new Error(err))
      }
      const onMessage = (ev: MessageEvent<ScanReply>) => { if (ev.data?.type === "ready") done(null) }
      const onError = (ev: ErrorEvent) => done(errorLine(ev.message))
      const onClose = () => done("还没就绪就退出了")
      const timer = setTimeout(() => done(`${Math.round((this.o.readyTimeoutMs ?? READY_TIMEOUT_MS) / 1000)}s 没就绪`), this.o.readyTimeoutMs ?? READY_TIMEOUT_MS)
      w.addEventListener("message", onMessage)
      w.addEventListener("error", onError)
      w.addEventListener("close", onClose)
    })
  }

  private attach(w: Worker): void {
    w.addEventListener("message", (ev: MessageEvent<ScanReply>) => this.onReply(w, ev.data))
    w.addEventListener("error", (ev: ErrorEvent) => this.fail(w, `scan worker 出错：${errorLine(ev.message)}`))
    w.addEventListener("messageerror", () => this.fail(w, "scan worker 回包解不开"))
    w.addEventListener("close", () => this.fail(w, "scan worker 退出了"))
    refWorker(w, false)
    this.worker = w
  }

  private onReply(w: Worker, m: ScanReply): void {
    if (m?.type === "ready") return
    if (Array.isArray(m?.block)) this.ledger.mergeStats(m.block)
    const f = this.inflight
    if (!f || f.id !== m?.id) return
    this.inflight = null
    clearTimeout(f.timer)
    refWorker(w, false)
    if (m.type === "done") f.resolve(m)
    else f.reject(new Error(m.error))
  }

  private fail(w: Worker, why: string): void {
    if (this.worker !== w) return           // 已经扔掉的 worker 迟到的 error / close
    this.worker = null
    try { w.terminate() } catch {}
    const f = this.inflight
    this.inflight = null
    if (f) { clearTimeout(f.timer); f.reject(new Error(why)) }
    else this.log(`[warroom] ${why}（空闲时），下一轮重建`)
  }
}
