// AUTONOMY Phase 1：日预算闸（plan-autonomy-network P1.3，形状抄 Hermes IterationBudget）。
// 三段式：80% 软提醒注入 → 100% 拒新任务 → 硬停由 shouldStopAfterTurn 执行。可 refund。
// 持久化 agent/budget-YYYY-MM-DD.json，app 设置页读它显示今日用量。
import { timedSyncFs } from "./block-ledger"
const { readFileSync, writeFileSync, existsSync, mkdirSync } = timedSyncFs("budget ")
import { join } from "node:path"

interface LedgerFile {
  spentUSD: number
  entries: { ts: string; triggerId: string; usd: number; note?: string }[]
}

export class BudgetLedger {
  constructor(
    private dir: string,
    private dailyLimitUSD: number,
    private clock: () => Date = () => new Date(),
  ) {
    mkdirSync(dir, { recursive: true })
  }

  private file(): string {
    return join(this.dir, `budget-${this.clock().toISOString().slice(0, 10)}.json`)
  }

  private load(): LedgerFile {
    const f = this.file()
    if (!existsSync(f)) return { spentUSD: 0, entries: [] }
    try {
      return JSON.parse(readFileSync(f, "utf8")) as LedgerFile
    } catch {
      return { spentUSD: 0, entries: [] }
    }
  }

  spentUSD(): number {
    return this.load().spentUSD
  }

  /** < 100% 才放新任务 */
  canStart(): boolean {
    return this.spentUSD() < this.dailyLimitUSD
  }

  /** ≥ 80%：runner 往 prompt 里注软提醒让模型自己收尾 */
  softWarning(): boolean {
    return this.spentUSD() >= this.dailyLimitUSD * 0.8
  }

  charge(triggerId: string, usd: number, note?: string): void {
    if (!(usd > 0)) return
    const ledger = this.load()
    ledger.spentUSD = Math.round((ledger.spentUSD + usd) * 1e6) / 1e6
    ledger.entries.push({ ts: this.clock().toISOString(), triggerId, usd, note })
    writeFileSync(this.file(), JSON.stringify(ledger, null, 1))
  }

  /** 内部/失败调用退款（Hermes refund 语义） */
  refund(triggerId: string, usd: number): void {
    if (!(usd > 0)) return
    const ledger = this.load()
    ledger.spentUSD = Math.max(0, Math.round((ledger.spentUSD - usd) * 1e6) / 1e6)
    ledger.entries.push({ ts: this.clock().toISOString(), triggerId, usd: -usd, note: "refund" })
    writeFileSync(this.file(), JSON.stringify(ledger, null, 1))
  }
}

/** token 用量 → USD（价目取自 Model.cost，单位 $/MTok） */
export function usageToUSD(
  usage: { input?: number; output?: number; cacheRead?: number; cacheWrite?: number } | undefined,
  cost: { input: number; output: number; cacheRead: number; cacheWrite: number },
): number {
  if (!usage) return 0
  const u = (n?: number) => (n ?? 0) / 1e6
  return u(usage.input) * cost.input + u(usage.output) * cost.output
    + u(usage.cacheRead) * cost.cacheRead + u(usage.cacheWrite) * cost.cacheWrite
}
