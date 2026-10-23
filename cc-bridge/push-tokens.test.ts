import { expect, test } from "bun:test"
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { isDeadAlertResult, loadPushTokens, normalizePushInfo, normalizeTopic, savePushTokens } from "./push-tokens.ts"

const tmpFile = (content?: string) => {
  const p = join(mkdtempSync(join(tmpdir(), "push-tokens-")), "push-tokens.json")
  if (content !== undefined) writeFileSync(p, content)
  return p
}

test("老数组格式 → sandbox + full，无 topic", () => {
  const m = loadPushTokens(tmpFile(JSON.stringify(["t1", "t2"])))
  expect([...m]).toEqual([
    ["t1", { env: "sandbox", preview: "full" }],
    ["t2", { env: "sandbox", preview: "full" }],
  ])
})

test("老对象格式（无 topic，env 可缺）照读", () => {
  const m = loadPushTokens(tmpFile(JSON.stringify({
    a: { env: "sandbox", preview: "full" },
    b: { preview: "hidden" },
  })))
  expect(m.get("a")).toEqual({ env: "sandbox", preview: "full" })
  expect(m.get("b")).toEqual({ env: "sandbox", preview: "hidden" })
})

test("带 topic + production 的新记录照读", () => {
  const m = loadPushTokens(tmpFile(JSON.stringify({
    c: { env: "production", preview: "full", topic: "com.susu.MemoryPalace.susu" },
  })))
  expect(m.get("c")).toEqual({ env: "production", preview: "full", topic: "com.susu.MemoryPalace.susu" })
})

test("缺文件 / 坏 JSON → 空表，不抛", () => {
  expect(loadPushTokens(tmpFile()).size).toBe(0)
  expect(loadPushTokens(tmpFile("{not json")).size).toBe(0)
})

test("normalizePushInfo：env 只认 production、preview 只认 hidden、坏 topic 丢掉", () => {
  expect(normalizePushInfo({ env: "prod", preview: "x", topic: "bad topic!" })).toEqual({ env: "sandbox", preview: "full" })
  expect(normalizePushInfo({ env: "production", preview: "hidden", topic: "com.susu.MemoryPalace.susu" }))
    .toEqual({ env: "production", preview: "hidden", topic: "com.susu.MemoryPalace.susu" })
  expect(normalizePushInfo(undefined)).toEqual({ env: "sandbox", preview: "full" })
})

test("normalizeTopic：只收 bundle id 形状，拒 liveactivity 派生 topic", () => {
  expect(normalizeTopic("com.susu.MemoryPalace.ios")).toBe("com.susu.MemoryPalace.ios")
  expect(normalizeTopic("com.susu.MemoryPalace.ios.push-type.liveactivity")).toBeUndefined()
  expect(normalizeTopic("")).toBeUndefined()
  expect(normalizeTopic("a/b")).toBeUndefined()
  expect(normalizeTopic("x".repeat(156))).toBeUndefined()
  expect(normalizeTopic(42)).toBeUndefined()
})

test("save → load 往返；无 topic 的记录不落 topic 键（老记录写回形状不变）", () => {
  const p = tmpFile()
  const m = new Map([
    ["old", normalizePushInfo({ env: "sandbox", preview: "full" })],
    ["new", normalizePushInfo({ env: "production", preview: "hidden", topic: "com.susu.MemoryPalace.susu" })],
  ])
  savePushTokens(p, m)
  expect(JSON.parse(readFileSync(p, "utf8"))).toEqual({
    old: { env: "sandbox", preview: "full" },
    new: { env: "production", preview: "hidden", topic: "com.susu.MemoryPalace.susu" },
  })
  expect([...loadPushTokens(p)]).toEqual([...m])
})

test("isDeadAlertResult：410 / BadDeviceToken / Unregistered / DeviceTokenNotForTopic 删，其余留", () => {
  expect(isDeadAlertResult({ ok: false, status: 410, reason: "Whatever" })).toBe(true)
  expect(isDeadAlertResult({ ok: false, status: 400, reason: "BadDeviceToken" })).toBe(true)
  expect(isDeadAlertResult({ ok: false, status: 400, reason: "Unregistered" })).toBe(true)
  expect(isDeadAlertResult({ ok: false, status: 400, reason: "DeviceTokenNotForTopic" })).toBe(true)
  expect(isDeadAlertResult({ ok: false, status: 400, reason: "TopicDisallowed" })).toBe(false)
  expect(isDeadAlertResult({ ok: false, status: 0, reason: "timeout" })).toBe(false)
  expect(isDeadAlertResult({ ok: false, status: 0, reason: "cert-missing" })).toBe(false)
})
