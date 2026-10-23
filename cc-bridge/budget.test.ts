import { test, expect } from "bun:test"
import { mkdtempSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
import { BudgetLedger, usageToUSD } from "./budget.ts"

const COST = { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 }

test("三段式：80% 软提醒，100% 拒新任务", () => {
  const ledger = new BudgetLedger(mkdtempSync(join(tmpdir(), "bud-")), 1.0)
  expect(ledger.canStart()).toBe(true)
  expect(ledger.softWarning()).toBe(false)

  ledger.charge("t1", 0.85)
  expect(ledger.softWarning()).toBe(true)   // ≥80%
  expect(ledger.canStart()).toBe(true)      // <100% 仍可开

  ledger.charge("t1", 0.2)
  expect(ledger.canStart()).toBe(false)     // ≥100% 拒
  expect(ledger.spentUSD()).toBeCloseTo(1.05, 6)
})

test("refund 语义 + 持久化跨实例", () => {
  const dir = mkdtempSync(join(tmpdir(), "bud-"))
  const a = new BudgetLedger(dir, 1.0)
  a.charge("t1", 0.6)
  a.refund("t1", 0.2)
  const b = new BudgetLedger(dir, 1.0)   // 新实例读同一账本
  expect(b.spentUSD()).toBeCloseTo(0.4, 6)
  b.refund("t1", 99)                      // 退款下限 0
  expect(b.spentUSD()).toBe(0)
})

test("usageToUSD：按 $/MTok 换算", () => {
  const usd = usageToUSD({ input: 1_000_000, output: 100_000 }, COST)
  expect(usd).toBeCloseTo(3 + 1.5, 6)
  expect(usageToUSD(undefined, COST)).toBe(0)
})
