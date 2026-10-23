// K3（plan-hub-perf）：按需扫目录。fs.watch 看到目录有动静才置脏，tick 只在脏的时候扫；
// 扫完还有剩的（没到点 / 失败的）保持脏，下个 tick 接着扫。watch 起不来 / 漏事件 / 目录被删重建，靠兜底周期。
import { watch, type FSWatcher } from "node:fs"

export class DirtyDirScanner {
  private dirty = true
  private running = false
  private lastScan = Number.NEGATIVE_INFINITY
  private watcher: FSWatcher | null = null

  /// scan 返回还剩几个要下次再看
  constructor(
    private readonly dir: string,
    private readonly scan: () => Promise<number>,
    private readonly fallbackMs: number,
    private readonly now: () => number = Date.now,
  ) {}

  get watching(): boolean { return this.watcher !== null }

  /// 挂 watch；目录不在 / 挂不上就算了（兜底周期还在），下次 tick 再试
  arm(): void {
    if (this.watcher) return
    try {
      const w = watch(this.dir, () => { this.dirty = true })
      w.on("error", () => { w.close(); if (this.watcher === w) this.watcher = null; this.dirty = true })
      this.watcher = w
    } catch { this.watcher = null }
  }

  async tick(): Promise<boolean> {
    if (this.running) return false
    if (!this.watcher) this.arm()
    if (!this.dirty && this.watcher && this.now() - this.lastScan < this.fallbackMs) return false
    this.dirty = false
    this.running = true
    this.lastScan = this.now()
    try {
      if (await this.scan() > 0) this.dirty = true
    } catch { this.dirty = true } finally { this.running = false }
    return true
  }

  close(): void { this.watcher?.close(); this.watcher = null }
}
