import { afterEach, beforeEach, expect, test } from "bun:test"
import { randomUUID } from "node:crypto"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { AgoraPresenceStore } from "./agora-presence.ts"
import { AgoraStore } from "./agora-store.ts"

let secretsDir = ""
let store: AgoraStore
let presence: AgoraPresenceStore
let roomId = ""
let ownerId = ""

beforeEach(() => {
  secretsDir = mkdtempSync(join(tmpdir(), "agora-presence-test-"))
  store = AgoraStore.open({ secretsDir })
  ownerId = store.upsertOwnerActor().id
  const agent = store.upsertCCActor("typing-agent")
  roomId = store.createRoom({
    floorId: randomUUID(),
    title: "Typing",
    clientRequestId: randomUUID(),
    ownerProfile: { handle: "susu", displayName: "Susu" },
    members: [{ actorId: agent.id, handle: "alice", displayName: "Alice" }],
  }).room.id
  presence = new AgoraPresenceStore(store, () => 1234)
})

afterEach(() => {
  store.close()
  rmSync(secretsDir, { recursive: true, force: true })
})

test("typing presence is ephemeral and reference-counted by source", () => {
  const first = presence.setTyping(roomId, ownerId, "phone", true)
  expect(first.changed).toBe(true)
  expect(first.presence).toMatchObject({ displayName: "Susu", isTyping: true, updatedAtMs: 1234 })
  expect(presence.setTyping(roomId, ownerId, "tablet", true).changed).toBe(false)
  expect(presence.setTyping(roomId, ownerId, "phone", false).presence.isTyping).toBe(true)
  const stopped = presence.clearSource("tablet")
  expect(stopped).toHaveLength(1)
  expect(stopped[0]).toMatchObject({ roomId, actorId: ownerId, isTyping: false })
})

test("typing presence requires an enabled room membership", () => {
  expect(() => presence.setTyping(randomUUID(), ownerId, "phone", true)).toThrow("room not found")
  const ownerMembership = store.listMemberships(roomId).find(member => member.actorId === ownerId)
  if (!ownerMembership) throw new Error("Missing owner membership")
  store.setMembershipEnabled(ownerMembership.id, false)
  expect(() => presence.setTyping(roomId, ownerId, "phone", true)).toThrow("membership is disabled")
})

test("sweepExpired extinguishes stale typing after TTL and respects renewals", () => {
  let now = 10_000
  const ttlPresence = new AgoraPresenceStore(store, () => now)
  ttlPresence.setTyping(roomId, ownerId, "phone", true)   // 默认 owner TTL 10s

  // TTL 内不熄
  now += 9_000
  expect(ttlPresence.sweepExpired()).toHaveLength(0)

  // 续命重置过期戳
  ttlPresence.setTyping(roomId, ownerId, "phone", true)
  now += 9_000
  expect(ttlPresence.sweepExpired()).toHaveLength(0)

  // 过期熄灭并回报 typing=false
  now += 2_000
  const stopped = ttlPresence.sweepExpired()
  expect(stopped).toHaveLength(1)
  expect(stopped[0]).toMatchObject({ roomId, actorId: ownerId, isTyping: false })
  // 幂等：再扫无事
  expect(ttlPresence.sweepExpired()).toHaveLength(0)
})

test("custom ttl (executor path) outlives owner ttl", () => {
  let now = 0
  const ttlPresence = new AgoraPresenceStore(store, () => now)
  ttlPresence.setTyping(roomId, ownerId, "executor", true, 120_000)
  now = 60_000
  expect(ttlPresence.sweepExpired()).toHaveLength(0)
  now = 120_001
  expect(ttlPresence.sweepExpired()).toHaveLength(1)
})
