import { test, expect, afterEach } from "bun:test"
import { sendVoIPAPNs, __setAPNsTestHooks } from "./apns"
import { installTransport, respondWith } from "./apns-fake-transport"
afterEach(() => __setAPNsTestHooks())
const target = { token: "a".repeat(64), topic: "com.example.call", env: "sandbox" as const }
const call = { call_id: crypto.randomUUID(), chat_id: crypto.randomUUID(), caller: "AI", created_at: 1000, expires_at: 61_000 }
test("VoIP uses separate topic/type, immediate expiry, no alert payload", async () => {
  const t = installTransport(respondWith(200))
  expect((await sendVoIPAPNs(target, call)).ok).toBe(true)
  const h = t.clients[0].headers!
  expect(h["apns-topic"]).toBe("com.example.call.voip")
  expect(h["apns-push-type"]).toBe("voip"); expect(h["apns-expiration"]).toBe("0")
  expect(h["apns-priority"]).toBe("10")
  expect(JSON.parse(t.clients[0].stream.payloads[0])).toEqual({ aps: { "content-available": 1 }, ...call })
})
test("no certificate never attempts network", async () => {
  const t = installTransport(respondWith(200)); __setAPNsTestHooks({ ...t.hooks, enabled: false })
  expect((await sendVoIPAPNs(target, call)).reason).toBe("cert-missing")
  expect(t.connects.length).toBe(0)
})
