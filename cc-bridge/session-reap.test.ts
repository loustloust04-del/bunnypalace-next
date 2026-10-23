import { test, expect } from "bun:test"
import { planReap, reapThresholdMs, reapLogLine, reapUnknownLogLine, type ReapInput } from "./session-reap"

const H = 3_600_000
const NOW = 1_800_000_000_000
const DAY = 24 * H

function input(over: Partial<ReapInput> & { sends?: Record<string, number>; mtimes?: Record<string, number> }): ReapInput {
  const sends = over.sends ?? {}
  const mtimes = over.mtimes ?? {}
  return {
    sessions: [],
    now: NOW,
    thresholdMs: DAY,
    protectedNames: new Set(),
    busy: () => false,
    lastSendAt: (s) => sends[s],
    transcriptPath: (s) => (s in mtimes ? `/t/${s}.jsonl` : undefined),
    mtimeMs: async (p) => mtimes[p.slice(3, -6)],
    ...over,
  }
}

test("reap: 内存无记录、transcript 旧 → 回收，依据 transcript", async () => {
  const plan = await planReap(input({ sessions: ["mp-cc-a"], mtimes: { "mp-cc-a": NOW - 30 * H } }))
  expect(plan.reap).toEqual([{ session: "mp-cc-a", idleMs: 30 * H, basis: "transcript" }])
  expect(plan.unknown).toEqual([])
})

test("reap: transcript 新 → 不回收（哪怕内存发言记录很旧）", async () => {
  const plan = await planReap(input({ sessions: ["mp-cc-a"], sends: { "mp-cc-a": NOW - 3 * DAY }, mtimes: { "mp-cc-a": NOW - 2 * H } }))
  expect(plan.reap).toEqual([])
})

test("reap: transcript 旧但刚发过言 → 不回收", async () => {
  const plan = await planReap(input({ sessions: ["mp-cc-a"], sends: { "mp-cc-a": NOW - H }, mtimes: { "mp-cc-a": NOW - 3 * DAY } }))
  expect(plan.reap).toEqual([])
})

test("reap: 两样都没有 → 不回收，记进 unknown", async () => {
  const plan = await planReap(input({ sessions: ["mp-cc-a", "mp-codex-b"] }))
  expect(plan.reap).toEqual([])
  expect(plan.unknown).toEqual(["mp-cc-a", "mp-codex-b"])
})

test("reap: codex 没 transcript，只看内存发言记录", async () => {
  const plan = await planReap(input({ sessions: ["mp-codex-b"], sends: { "mp-codex-b": NOW - 2 * DAY } }))
  expect(plan.reap).toEqual([{ session: "mp-codex-b", idleMs: 2 * DAY, basis: "send" }])
})

test("reap: 主会话 mp-cc / 全局窗口 / 常驻会话 / 非 mp 会话 → 不回收也不进 unknown", async () => {
  const old = NOW - 10 * DAY
  const names = ["mp-cc", "mp-win-abc123", "mp-cc-desk", "work", "mp-cc-x"]
  const plan = await planReap(input({
    sessions: names,
    protectedNames: new Set(["mp-cc-desk"]),
    mtimes: Object.fromEntries(names.map(n => [n, old])),
  }))
  expect(plan.reap.map(c => c.session)).toEqual(["mp-cc-x"])
  expect(plan.unknown).toEqual([])
})

test("reap: 正在 spawn / 有排队消息 → 不回收", async () => {
  const plan = await planReap(input({
    sessions: ["mp-cc-a", "mp-cc-b"],
    busy: (s) => s === "mp-cc-a",
    mtimes: { "mp-cc-a": NOW - 3 * DAY, "mp-cc-b": NOW - 3 * DAY },
  }))
  expect(plan.reap.map(c => c.session)).toEqual(["mp-cc-b"])
})

test("reap: 阈值默认 1 天，MP_CC_REAP_DAYS 可覆盖且允许小数", () => {
  expect(reapThresholdMs(undefined)).toBe(DAY)
  expect(reapThresholdMs("")).toBe(DAY)
  expect(reapThresholdMs("abc")).toBe(DAY)
  expect(reapThresholdMs("0")).toBe(DAY)
  expect(reapThresholdMs("7")).toBe(7 * DAY)
  expect(reapThresholdMs("0.5")).toBe(12 * H)
})

test("reap: 日志格式", () => {
  expect(reapLogLine({ session: "mp-cc-a", idleMs: 30.25 * H, basis: "transcript" })).toBe("reaped idle session mp-cc-a（闲 30.3h，依据 transcript）")
  expect(reapUnknownLogLine([])).toBeNull()
  expect(reapUnknownLogLine(["mp-cc-a", "mp-cc-b"])).toContain("2 个")
})
