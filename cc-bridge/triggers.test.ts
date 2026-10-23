import { test, expect } from "bun:test"
import { writeFileSync, mkdtempSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
import { loadTriggers, isDue, renderPrompt, type TriggerSpec } from "./triggers.ts"

const base: TriggerSpec = {
  id: "t1", type: "cron", schedule: "*/5 * * * *", promptTemplate: "echo: hi",
  contextLoader: "none", sink: "log", enabled: true,
}

test("isDue：窗口内有 cron 命中才 due", () => {
  const since = new Date("2026-07-05T10:02:00Z")
  expect(isDue(base, since, new Date("2026-07-05T10:06:00Z"))).toBe(true)   // 10:05 命中
  expect(isDue(base, since, new Date("2026-07-05T10:04:00Z"))).toBe(false)  // 还没到 10:05
  expect(isDue({ ...base, enabled: false }, since, new Date("2026-07-05T10:06:00Z"))).toBe(false)
  expect(isDue({ ...base, schedule: "not-a-cron" }, since, new Date("2026-07-05T10:06:00Z"))).toBe(false)
})

test("loadTriggers：坏条目跳过不炸", () => {
  const dir = mkdtempSync(join(tmpdir(), "trig-"))
  const f = join(dir, "triggers.json")
  writeFileSync(f, JSON.stringify([
    base,
    { id: "no-prompt" },                                  // 缺 promptTemplate
    { id: "no-sched", type: "cron", promptTemplate: "x" }, // 缺 schedule
    "garbage",
  ]))
  const specs = loadTriggers(f)
  expect(specs.length).toBe(1)
  expect(specs[0].id).toBe("t1")
  expect(loadTriggers(join(dir, "missing.json"))).toEqual([])
})

test("renderPrompt：变量替换", () => {
  const spec = { ...base, promptTemplate: "楼层{{floor}}，今天{{date}}", floorId: "F1" }
  expect(renderPrompt(spec, new Date("2026-07-05T10:00:00Z"))).toBe("楼层F1，今天2026-07-05")
})
