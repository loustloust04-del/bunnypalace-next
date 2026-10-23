import { test, expect } from "bun:test"
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { loadConfig, runTrigger } from "./agent-runner.ts"
import { BudgetLedger } from "./budget.ts"
import type { TriggerSpec } from "./triggers.ts"

function makeDir(config?: Record<string, unknown>): string {
  const dir = mkdtempSync(join(tmpdir(), "cc-agent-"))
  if (config) writeFileSync(join(dir, "config.json"), JSON.stringify(config))
  return dir
}

function lastActivity(dir: string): Record<string, unknown> | null {
  const f = join(dir, "activity.jsonl")
  if (!existsSync(f)) return null
  const lines = readFileSync(f, "utf8").trim().split("\n")
  return JSON.parse(lines[lines.length - 1])
}

// MARK: coRead 配置

test("loadConfig: coRead 缺省 = 全关", () => {
  const dir = makeDir({ enabled: true })
  const cfg = loadConfig(dir)
  expect(cfg.coRead).toEqual({ daemon: false, cc: false, vocab: false })
})

test("loadConfig: coRead 显式开", () => {
  const dir = makeDir({ enabled: true, coRead: { daemon: true, cc: true, vocab: true } })
  expect(loadConfig(dir).coRead).toEqual({ daemon: true, cc: true, vocab: true })
})

test("loadConfig: coRead 半开 + 脏值不当真", () => {
  const dir = makeDir({ enabled: true, coRead: { daemon: true, cc: "yes" } })
  expect(loadConfig(dir).coRead).toEqual({ daemon: true, cc: false, vocab: false })
})

// MARK: coRead 闸（runTrigger）

const bookNoteSpec: TriggerSpec = {
  id: "reader-daemon-test", type: "cron", schedule: "0 0 * * *",
  promptTemplate: "读书", contextLoader: "currentBook", sink: "bookNote", enabled: true,
}

test("runTrigger: coRead.daemon 关 → skipped-coread-off（不碰 LLM/预算）", async () => {
  const dir = makeDir()
  const cfg = loadConfig(dir)   // 缺省全关
  cfg.enabled = true
  await runTrigger(bookNoteSpec, cfg, { dir, ledger: new BudgetLedger(dir, 1) })
  expect(lastActivity(dir)?.status).toBe("skipped-coread-off")
})

test("runTrigger: coRead.daemon 开 → 通过闸（走到后面的 gate/材料检查）", async () => {
  const dir = makeDir()
  const cfg = loadConfig(dir)
  cfg.enabled = true
  cfg.coRead = { daemon: true, cc: false, vocab: false }
  await runTrigger(bookNoteSpec, cfg, { dir, ledger: new BudgetLedger(dir, 1) })
  // 没有 reading-context 材料 → 走到 readerGate 的 skip，而不是 coread 闸
  expect(lastActivity(dir)?.status).not.toBe("skipped-coread-off")
})

test("runTrigger: 非 bookNote 触发器不受 coRead 影响", async () => {
  const dir = makeDir()
  const cfg = loadConfig(dir)
  cfg.enabled = true
  const echoSpec: TriggerSpec = {
    id: "echo-t", type: "cron", schedule: "0 0 * * *",
    promptTemplate: "echo: hi", contextLoader: "none", sink: "log", enabled: true,
  }
  await runTrigger(echoSpec, cfg, { dir, ledger: new BudgetLedger(dir, 1) })
  expect(lastActivity(dir)?.status).toBe("ok")
})
