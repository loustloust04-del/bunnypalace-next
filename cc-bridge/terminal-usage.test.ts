import { test, expect } from "bun:test"
import { mkdtempSync, writeFileSync, rmSync } from "fs"
import { join } from "path"
import { tmpdir } from "os"
import {
  buildTerminalUsagePayload, contextWindowFor, prettyModel, readTranscriptUsage, readRateLimits,
} from "./terminal-usage"

function scratch(): string { return mkdtempSync(join(tmpdir(), "term-usage-")) }

const assistant = (usage: Record<string, unknown>, model = "claude-opus-4-6") =>
  JSON.stringify({ type: "assistant", message: { model, usage } })

test("contextWindowFor 认 [1m] 后缀", () => {
  expect(contextWindowFor("claude-opus-4-6[1m]")).toBe(1_000_000)
  expect(contextWindowFor("claude-opus-4-6")).toBe(200_000)
})

test("窗口给函数：按这条回复实际用的模型算（会话中途换了模型也对）", () => {
  const dir = scratch()
  const p = join(dir, "t.jsonl")
  writeFileSync(p, assistant({ input_tokens: 0, cache_read_input_tokens: 100_000, output_tokens: 0 }, "claude-opus-5-5") + "\n")
  const asked: Array<string | undefined> = []
  const r = readTranscriptUsage(p, (m) => { asked.push(m); return contextWindowFor(m ?? "") })
  expect(asked).toEqual(["claude-opus-5-5"])
  expect(r).toEqual({ model: "Opus 5.5 · 1M", ctx: 10 })   // 天生 1M：按 200K 算会报 50%
  rmSync(dir, { recursive: true })
})

test("prettyModel 压成顶栏塞得下的短名", () => {
  expect(prettyModel("claude-opus-4-6", 1_000_000)).toBe("Opus 4.6 · 1M")
  expect(prettyModel("claude-sonnet-4-5", 200_000)).toBe("Sonnet 4.5 · 200K")
  expect(prettyModel(undefined, 1_000_000)).toBeUndefined()
})

test("ctx 把四项 token 全算进去 —— cache_read 是大头，漏了会接近 0", () => {
  const dir = scratch()
  const p = join(dir, "t.jsonl")
  writeFileSync(p, assistant({
    input_tokens: 3, cache_creation_input_tokens: 269,
    cache_read_input_tokens: 106_258, output_tokens: 82,
  }) + "\n")

  const r = readTranscriptUsage(p, 1_000_000)
  expect(r.ctx).toBe(11)                    // 106612 / 1M
  expect(r.model).toBe("Opus 4.6 · 1M")

  // 只算 input+output 的话是 0% —— 这就是漏掉 cache 的后果
  expect(Math.round((3 + 82) / 1_000_000 * 100)).toBe(0)
  rmSync(dir, { recursive: true })
})

test("跳过末尾的 system / attachment 记录，反向找到 assistant", () => {
  const dir = scratch()
  const p = join(dir, "t.jsonl")
  writeFileSync(p, [
    assistant({ input_tokens: 1, cache_read_input_tokens: 50_000, output_tokens: 10 }),
    JSON.stringify({ type: "attachment", attachment: {} }),
    JSON.stringify({ type: "system", hasOutput: true }),
    JSON.stringify({ type: "summary", messageCount: 42 }),
  ].join("\n") + "\n")

  expect(readTranscriptUsage(p, 1_000_000).ctx).toBe(5)
  rmSync(dir, { recursive: true })
})

test("取的是最后一条 assistant，不是第一条", () => {
  const dir = scratch()
  const p = join(dir, "t.jsonl")
  writeFileSync(p, [
    assistant({ cache_read_input_tokens: 10_000 }),
    assistant({ cache_read_input_tokens: 900_000 }),
  ].join("\n") + "\n")

  expect(readTranscriptUsage(p, 1_000_000).ctx).toBe(90)
  rmSync(dir, { recursive: true })
})

test("尾部截断的半行不能让整个解析崩掉", () => {
  const dir = scratch()
  const p = join(dir, "t.jsonl")
  // 模拟只读到尾部时首行是半截 JSON
  writeFileSync(p, `sistant","message":{"usage":{"input_tokens":1}}}\n`
    + assistant({ cache_read_input_tokens: 200_000 }) + "\n")

  expect(readTranscriptUsage(p, 1_000_000).ctx).toBe(20)
  rmSync(dir, { recursive: true })
})

test("ctx 封顶 100，不给顶栏喂出三位数", () => {
  const dir = scratch()
  const p = join(dir, "t.jsonl")
  writeFileSync(p, assistant({ cache_read_input_tokens: 5_000_000 }) + "\n")
  expect(readTranscriptUsage(p, 1_000_000).ctx).toBe(100)
  rmSync(dir, { recursive: true })
})

test("transcript 不存在 / 没有 usage → 空对象，不抛", () => {
  expect(readTranscriptUsage("/nope/nope.jsonl", 1_000_000)).toEqual({})

  const dir = scratch()
  const p = join(dir, "t.jsonl")
  writeFileSync(p, JSON.stringify({ type: "system" }) + "\n")
  expect(readTranscriptUsage(p, 1_000_000)).toEqual({})
  rmSync(dir, { recursive: true })
})

test("rate limits 读得到就用，读不到全 undefined（可选增强不能拖垮 ctx）", () => {
  const dir = scratch()
  const p = join(dir, "rl.json")
  writeFileSync(p, JSON.stringify({
    five_hour: { used_percentage: 18 }, seven_day: { used_percentage: 71 },
  }))
  expect(readRateLimits(p)).toEqual({ five_hour: 18, seven_day: 71 })

  expect(readRateLimits(join(dir, "missing.json"))).toEqual({})

  writeFileSync(p, "{ 这不是 json")
  expect(readRateLimits(p)).toEqual({})

  writeFileSync(p, JSON.stringify({ five_hour: { used_percentage: "x" } }))
  expect(readRateLimits(p)).toEqual({ five_hour: undefined, seven_day: undefined })
  rmSync(dir, { recursive: true })
})

test("mp-win usage payload 仍带账号用量，model/ctx 显式为 null", () => {
  const payload = JSON.parse(buildTerminalUsagePayload(
    "mp-win-abc123",
    null,
    { five_hour: 18, seven_day: 71 },
  ))
  expect(payload).toEqual({
    type: "terminal_usage",
    session_name: "mp-win-abc123",
    model: null,
    ctx: null,
    five_hour: 18,
    seven_day: 71,
  })
})

test("对话 session usage payload 保留 model/ctx 行为", () => {
  const payload = JSON.parse(buildTerminalUsagePayload(
    "mp-cc-2",
    { model: "Opus 4.6 · 1M", ctx: 37 },
    { five_hour: 18, seven_day: 71 },
  ))
  expect(payload.model).toBe("Opus 4.6 · 1M")
  expect(payload.ctx).toBe(37)
  expect(payload.five_hour).toBe(18)
  expect(payload.seven_day).toBe(71)
})
