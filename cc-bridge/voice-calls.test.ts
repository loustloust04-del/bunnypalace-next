import { test, expect } from "bun:test"
import { VoiceCalls } from "./voice-calls"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
const chat = crypto.randomUUID(), device = crypto.randomUUID()
function setup(path?: string) {
  let time = 1000
  const calls = new VoiceCalls(path, () => time)
  calls.register({ install_id: device, token: "a".repeat(64), env: "sandbox", topic: "com.example.test" })
  return { calls, tick: () => { time += 60_001 } }
}
test("explicit opt-in, bound private chat, no broadcast and one active call", () => {
  const { calls } = setup(), id = crypto.randomUUID()
  expect(() => calls.create(id, chat, device, "s", "other", "AI")).toThrow()
  expect(() => calls.create(id, chat, "absent", "s", chat, "AI")).toThrow()
  expect(calls.create(id, chat, device, "s", chat, "AI").fresh).toBe(true)
  expect(calls.create(id, chat, device, "s", chat, "AI").fresh).toBe(false)
  expect(() => calls.create(crypto.randomUUID(), chat, device, "s", chat, "AI")).toThrow()
  expect(() => calls.transition(id, "accept", { install_id: "other" })).toThrow()
  expect(() => calls.transition(id, "accept", { session: "s" })).toThrow()
  expect(calls.transition(id, "accept", { install_id: device }).status).toBe("accepted")
  expect(calls.transition(id, "accept", { install_id: device }).status).toBe("accepted")
  expect(calls.transition(id, "hangup", { install_id: device }).status).toBe("ended")
  expect(calls.transition(id, "accept", { install_id: device }).status).toBe("ended")
})
test("expired/canceled calls cannot revive; disable removes VoIP route", () => {
  const { calls, tick } = setup(), id = crypto.randomUUID()
  calls.create(id, chat, device, "s", chat, "AI"); tick()
  expect(calls.transition(id, "accept", { install_id: device }).status).toBe("missed")
  const second = crypto.randomUUID()
  calls.create(second, chat, device, "s", chat, "AI")
  expect(calls.transition(second, "cancel", { session: "s" }).status).toBe("canceled")
  expect(calls.transition(second, "accept", { install_id: device }).status).toBe("canceled")
  calls.register({ install_id: device, enabled: false })
  expect(calls.device(device)).toBeUndefined()
})
test("restart closes accepted call and retains bounded history", () => {
  const dir = mkdtempSync(join(tmpdir(), "calls-test-")), path = join(dir, "calls.json")
  try {
    const { calls } = setup(path), id = crypto.randomUUID()
    calls.create(id, chat, device, "s", chat, "AI")
    calls.transition(id, "accept", { install_id: device })
    const restored = new VoiceCalls(path, () => 1001); restored.load()
    expect(restored.get(id)?.status).toBe("ended")
    expect(restored.device(device)?.topic).toBe("com.example.test")
  } finally { rmSync(dir, { recursive: true }) }
})
