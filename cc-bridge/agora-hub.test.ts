import { expect, test } from "bun:test"
import { Database } from "bun:sqlite"
import { randomUUID } from "node:crypto"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { WebSocket, type RawData } from "ws"
import {
  AGORA_MAX_BUFFERED_BYTES,
  type AgoraSocket,
  hasValidAgoraToken,
  openAgoraProtocol,
} from "./agora-protocol.ts"
import { AgoraStore } from "./agora-store.ts"
import { AGORA_DATABASE_FILENAME, AGORA_LIMITS } from "./agora-types.ts"

type JsonPrimitive = string | number | boolean | null
type JsonValue = JsonPrimitive | JsonObject | JsonValue[]
interface JsonObject { [key: string]: JsonValue }

class MemorySocket implements AgoraSocket {
  readyState: number = WebSocket.OPEN
  bufferedAmount = 0
  readonly sent: JsonObject[] = []
  closeOnNextSend = false
  closeCode: number | undefined
  closeReason: string | undefined
  private readonly messageListeners: Array<(raw: RawData) => void> = []
  private readonly closeListeners: Array<() => void> = []

  on(event: "message", listener: (raw: RawData) => void): this
  on(event: "close", listener: () => void): this
  on(event: "message" | "close", listener: ((raw: RawData) => void) | (() => void)): this {
    if (event === "message") this.messageListeners.push(listener as (raw: RawData) => void)
    else this.closeListeners.push(listener as () => void)
    return this
  }

  send(data: string): void {
    this.sent.push(JSON.parse(data))
    if (this.closeOnNextSend) this.close()
  }

  receive(value: JsonObject | string): void {
    const raw = Buffer.from(typeof value === "string" ? value : JSON.stringify(value))
    for (const listener of this.messageListeners) listener(raw)
  }

  close(code?: number, reason?: string): void {
    if (this.readyState === WebSocket.CLOSED) return
    this.closeCode = code
    this.closeReason = reason
    this.readyState = WebSocket.CLOSED
    for (const listener of this.closeListeners) listener()
  }
}

function object(value: JsonValue | undefined, label: string): JsonObject {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} is not an object`)
  }
  return value
}

function array(value: JsonValue | undefined, label: string): JsonValue[] {
  if (!Array.isArray(value)) throw new Error(`${label} is not an array`)
  return value
}

function string(value: JsonValue | undefined, label: string): string {
  if (typeof value !== "string") throw new Error(`${label} is not a string`)
  return value
}

function request(
  socket: MemorySocket,
  action: string,
  payload: JsonObject,
  requestId = randomUUID(),
): { response: JsonObject; events: JsonObject[] } {
  const start = socket.sent.length
  socket.receive({ type: "agora_request", request_id: requestId, action, payload })
  const frames = socket.sent.slice(start)
  const response = frames[0]
  if (!response) throw new Error(`Missing response for ${action}`)
  expect(response.type).toBe("agora_response")
  expect(response.request_id).toBe(requestId)
  return { response, events: frames.slice(1) }
}

function upsertActor(socket: MemorySocket, sessionName: string): string {
  const { response } = request(socket, "actor.upsert_cc", { session_name: sessionName })
  expect(response.ok).toBe(true)
  return string(object(object(response.data, "data").actor, "actor").id, "actor.id")
}

function createRoom(
  socket: MemorySocket,
  floorId: string,
  members: JsonObject[],
  clientRequestId = randomUUID(),
): { roomId: string; clientRequestId: string } {
  const { response, events } = request(socket, "room.create", {
    client_request_id: clientRequestId,
    floor_id: floorId,
    title: "Agora Integration",
    owner_profile: { handle: "susu", display_name: "禾禾" },
    member_specs: members,
  })
  expect(response.ok).toBe(true)
  expect(events.map(event => event.kind)).toEqual(["room.created"])
  const room = object(object(response.data, "data").room, "room")
  return { roomId: string(room.id, "room.id"), clientRequestId }
}

function withProtocol(
  run: (socket: MemorySocket, secretsDir: string, protocol: ReturnType<typeof openAgoraProtocol>) => void,
): void {
  const secretsDir = mkdtempSync(join(tmpdir(), "agora-hub-test-"))
  const protocol = openAgoraProtocol(secretsDir)
  protocol.setSessionDirectory({
    listAvailableActors: () => protocol.store.listCCActors(),
    upsertAvailableActor: sessionName => protocol.store.upsertCCActor(sessionName),
  })
  const socket = new MemorySocket()
  protocol.attach(socket)
  try {
    run(socket, secretsDir, protocol)
  } finally {
    socket.close()
    protocol.close()
    rmSync(secretsDir, { recursive: true, force: true })
  }
}

test("hub startup opens agora.sqlite and migration failure fails closed", () => {
  withProtocol((_socket, secretsDir) => {
    const store = AgoraStore.open({ secretsDir })
    expect(store.health().migrationVersions).toEqual([1, 2, 3, 4, 5, 6])
    store.close()
  })

  const brokenDir = mkdtempSync(join(tmpdir(), "agora-hub-broken-"))
  const database = new Database(join(brokenDir, AGORA_DATABASE_FILENAME), { create: true })
  database.exec("CREATE TABLE agora_actors (broken TEXT)")
  database.close()
  expect(() => openAgoraProtocol(brokenDir)).toThrow()
  const inspection = new Database(join(brokenDir, AGORA_DATABASE_FILENAME))
  const tables = inspection.query<{ name: string }, []>(
    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
  ).all().map(row => row.name)
  inspection.close()
  expect(tables).toEqual(["agora_actors"])
  rmSync(brokenDir, { recursive: true, force: true })
})

test("/agora token validation has no loopback free pass", () => {
  expect(hasValidAgoraToken("/agora", "secret")).toBe(false)
  expect(hasValidAgoraToken("/agora?token=wrong", "secret")).toBe(false)
  expect(hasValidAgoraToken("/agora?token=secret", "secret")).toBe(true)
  expect(hasValidAgoraToken("/cc?token=secret", "secret")).toBe(false)
})

test("request envelope correlates errors and rejects unknown actions", () => {
  withProtocol(socket => {
    const invalidTypeId = randomUUID()
    socket.receive({ type: "wrong", request_id: invalidTypeId, action: "actor.list", payload: {} })
    const invalidType = socket.sent.at(-1)
    if (!invalidType) throw new Error("Missing invalid type response")
    expect(invalidType.request_id).toBe(invalidTypeId)
    expect(object(invalidType.error, "error").code).toBe("invalid_request")

    const unknownId = randomUUID()
    socket.receive({ type: "agora_request", request_id: unknownId, action: "room.destroy", payload: {} })
    const unknown = socket.sent.at(-1)
    if (!unknown) throw new Error("Missing unknown action response")
    expect(unknown.request_id).toBe(unknownId)
    expect(object(unknown.error, "error").code).toBe("unknown_action")

    socket.receive("not-json{")
    const invalidJson = socket.sent.at(-1)
    if (!invalidJson) throw new Error("Missing invalid JSON response")
    expect(invalidJson.request_id).toBe("")
    expect(object(invalidJson.error, "error").code).toBe("invalid_request")
  })
})

test("actor and room actions are idempotent and floor scoped", () => {
  withProtocol(socket => {
    const actorId = upsertActor(socket, "mp-cc-hub-actions")
    expect(upsertActor(socket, "mp-cc-hub-actions")).toBe(actorId)
    const actorList = request(socket, "actor.list", {})
    expect(array(object(actorList.response.data, "data").actors, "actors")
      .some(value => object(value, "actor").id === actorId)).toBe(true)

    const floorId = randomUUID()
    const created = createRoom(socket, floorId, [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    const retry = request(socket, "room.create", {
      client_request_id: created.clientRequestId,
      floor_id: randomUUID(),
      title: "Ignored retry values",
      owner_profile: { handle: "other", display_name: "Other" },
      member_specs: [],
    })
    expect(retry.response.ok).toBe(true)
    expect(object(retry.response.data, "data").idempotent).toBe(true)
    expect(retry.events).toEqual([])
    expect(string(object(object(retry.response.data, "data").room, "room").id, "room.id")).toBe(created.roomId)

    const listed = request(socket, "room.list", { floor_id: floorId })
    expect(array(object(listed.response.data, "data").rooms, "rooms")).toHaveLength(1)
    const isolated = request(socket, "room.list", { floor_id: randomUUID() })
    expect(array(object(isolated.response.data, "data").rooms, "rooms")).toHaveLength(0)
  })
})

test("room.create returns one canonical direct room per floor and agent", () => {
  withProtocol(socket => {
    const actorId = upsertActor(socket, "mp-cc-dm")
    const floorId = randomUUID()
    const payload = {
      client_request_id: randomUUID(),
      floor_id: floorId,
      title: "Alice",
      is_dm: true,
      owner_profile: { handle: "susu", display_name: "禾禾" },
      member_specs: [{ actor_id: actorId, handle: "alice", display_name: "Alice" }],
    }
    const first = request(socket, "room.create", payload)
    expect(first.response.ok).toBe(true)
    const firstRoom = object(object(first.response.data, "data").room, "room")
    expect(firstRoom.is_dm).toBe(true)
    expect(firstRoom.dm_peer_actor_id).toBe(actorId)

    const second = request(socket, "room.create", { ...payload, client_request_id: randomUUID() })
    expect(second.response.ok).toBe(true)
    expect(object(second.response.data, "data").idempotent).toBe(true)
    expect(object(object(second.response.data, "data").room, "room").id).toBe(firstRoom.id)
    expect(second.events).toEqual([])

    const listed = request(socket, "room.list", { floor_id: floorId })
    expect(array(object(listed.response.data, "data").rooms, "rooms")).toHaveLength(1)
  })
})

test("message.post rejects actor spoofing without a canonical write", () => {
  withProtocol(socket => {
    const actorId = upsertActor(socket, "mp-cc-hub-spoof")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    const spoof = request(socket, "message.post", {
      room_id: roomId,
      client_message_id: randomUUID(),
      content: "forged",
      actor_id: actorId,
    })
    expect(spoof.response.ok).toBe(false)
    expect(object(spoof.response.error, "error").code).toBe("invalid_payload")
    const opened = request(socket, "room.open", { room_id: roomId, limit: 100 })
    expect(array(object(opened.response.data, "data").messages, "messages")).toHaveLength(0)
  })
})

test("message post commits before ordered events and retries emit nothing", () => {
  withProtocol(socket => {
    const aliceId = upsertActor(socket, "mp-cc-hub-events-a")
    const bobId = upsertActor(socket, "mp-cc-hub-events-b")
    const { roomId } = createRoom(socket, randomUUID(), [
      { actor_id: aliceId, handle: "alice", display_name: "Alice" },
      { actor_id: bobId, handle: "bob", display_name: "Bob" },
    ])
    const clientMessageId = randomUUID()
    const posted = request(socket, "message.post", {
      room_id: roomId,
      client_message_id: clientMessageId,
      content: "@alice first opinion, @bob second opinion",
    })
    expect(posted.response.ok).toBe(true)
    expect(posted.events.map(event => event.kind)).toEqual([
      "message.created",
      "mention.updated",
      "mention.updated",
      "room.updated",
    ])
    const data = object(posted.response.data, "data")
    expect(array(data.mentions, "mentions")).toHaveLength(2)

    const retry = request(socket, "message.post", {
      room_id: roomId,
      client_message_id: clientMessageId,
      content: "",
    })
    expect(retry.response.ok).toBe(true)
    expect(object(retry.response.data, "data").idempotent).toBe(true)
    expect(retry.events).toEqual([])
    expect(string(object(object(retry.response.data, "data").message, "message").id, "message.id"))
      .toBe(string(object(data.message, "message").id, "message.id"))
  })
})

test("message.edit updates the canonical message and broadcasts message.updated", () => {
  withProtocol(socket => {
    const actorId = upsertActor(socket, "mp-cc-hub-edit")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    const posted = request(socket, "message.post", {
      room_id: roomId,
      client_message_id: randomUUID(),
      content: "before",
    })
    const messageId = string(object(object(posted.response.data, "data").message, "message").id, "message.id")
    const edited = request(socket, "message.edit", { message_id: messageId, content: "after" })
    expect(edited.response.ok).toBe(true)
    expect(edited.events.map(event => event.kind)).toEqual(["message.updated"])
    const message = object(object(edited.response.data, "data").message, "message")
    expect(message.content).toBe("after")
    expect(message.seq).toBe(1)
    expect(typeof message.edited_at_ms).toBe("number")
  })
})

test("message.delete clears content, preserves seq, and broadcasts the tombstone", () => {
  withProtocol(socket => {
    const actorId = upsertActor(socket, "mp-cc-hub-delete")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    const posted = request(socket, "message.post", {
      room_id: roomId,
      client_message_id: randomUUID(),
      content: "delete me",
    })
    const messageId = string(object(object(posted.response.data, "data").message, "message").id, "message.id")
    const deleted = request(socket, "message.delete", { message_id: messageId })
    expect(deleted.response.ok).toBe(true)
    expect(deleted.events.map(event => event.kind)).toEqual(["message.updated"])
    const message = object(object(deleted.response.data, "data").message, "message")
    expect(message.content).toBe("")
    expect(message.seq).toBe(1)
    expect(message.is_deleted).toBe(true)
    expect(typeof message.deleted_at_ms).toBe("number")
  })
})

test("message rate limit returns retry metadata through the WebSocket protocol", () => {
  withProtocol(socket => {
    const actorId = upsertActor(socket, "mp-cc-hub-rate-limit")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    for (let index = 0; index < AGORA_LIMITS.messagePostsPerMinute; index += 1) {
      const posted = request(socket, "message.post", {
        room_id: roomId,
        client_message_id: randomUUID(),
        content: `message ${index}`,
      })
      expect(posted.response.ok).toBe(true)
    }

    const limited = request(socket, "message.post", {
      room_id: roomId,
      client_message_id: randomUUID(),
      content: "one too many",
    })
    expect(limited.response.ok).toBe(false)
    const error = object(limited.response.error, "error")
    expect(error.code).toBe("rate_limit_exceeded")
    const details = object(error.details, "error.details")
    expect(details.limit).toBe(AGORA_LIMITS.messagePostsPerMinute)
    expect(typeof details.retry_after_ms).toBe("number")
    expect(limited.events).toEqual([])
  })
})

test("room.open and message.after recover pagination gaps in seq order", () => {
  withProtocol(socket => {
    const actorId = upsertActor(socket, "mp-cc-hub-gap")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    for (let seq = 1; seq <= 5; seq += 1) {
      const posted = request(socket, "message.post", {
        room_id: roomId,
        client_message_id: randomUUID(),
        content: `message ${seq}`,
      })
      expect(posted.events.map(event => event.kind)).toEqual(["message.created", "room.updated"])
    }

    const latest = request(socket, "room.open", { room_id: roomId, limit: 2 })
    expect(array(object(latest.response.data, "data").messages, "messages")
      .map(value => object(value, "message").seq)).toEqual([4, 5])
    const older = request(socket, "room.open", { room_id: roomId, before_seq: 4, limit: 2 })
    expect(array(object(older.response.data, "data").messages, "messages")
      .map(value => object(value, "message").seq)).toEqual([2, 3])
    const gap = request(socket, "message.after", { room_id: roomId, after_seq: 2, limit: 2 })
    expect(array(object(gap.response.data, "data").messages, "messages")
      .map(value => object(value, "message").seq)).toEqual([3, 4])
    expect(object(gap.response.data, "data").has_more).toBe(true)
    const tail = request(socket, "message.after", { room_id: roomId, after_seq: 4, limit: 2 })
    expect(array(object(tail.response.data, "data").messages, "messages")
      .map(value => object(value, "message").seq)).toEqual([5])
    expect(object(tail.response.data, "data").has_more).toBe(false)
  })
})

test("sync.resume replays missed messages with stable event ids before its ack", () => {
  withProtocol(socket => {
    const actorId = upsertActor(socket, "mp-cc-hub-resume")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    const messageIds: string[] = []
    for (let seq = 1; seq <= 3; seq += 1) {
      const posted = request(socket, "message.post", {
        room_id: roomId,
        client_message_id: randomUUID(),
        content: `message ${seq}`,
      })
      messageIds.push(string(object(object(posted.response.data, "data").message, "message").id, "message.id"))
    }

    socket.sent.length = 0
    const requestId = randomUUID()
    socket.receive({
      type: "agora_request",
      request_id: requestId,
      action: "sync.resume",
      payload: { cursors: { [roomId]: 1 } },
    })

    expect(socket.sent.map(frame => frame.type)).toEqual(["agora_event", "agora_event", "agora_response"])
    expect(socket.sent.slice(0, 2).map(frame => object(object(frame.data, "data").message, "message").seq))
      .toEqual([2, 3])
    expect(socket.sent.slice(0, 2).map(frame => frame.event_id))
      .toEqual(messageIds.slice(1).map(id => `message:${id}`))
    const response = socket.sent.at(-1)
    if (!response) throw new Error("Missing sync.resume response")
    expect(response.request_id).toBe(requestId)
    expect(object(response.data, "data")).toEqual({ replayed_count: 2, has_more: false })
  })
})

test("slow Agora clients are closed with retry-later backpressure code", () => {
  withProtocol(socket => {
    socket.bufferedAmount = AGORA_MAX_BUFFERED_BYTES
    socket.receive({
      type: "agora_request",
      request_id: randomUUID(),
      action: "actor.list",
      payload: {},
    })

    expect(socket.sent).toEqual([])
    expect(socket.readyState).toBe(WebSocket.CLOSED)
    expect(socket.closeCode).toBe(1013)
    expect(socket.closeReason).toBe("backpressure")
  })
})

test("mention.list returns inbox context and mention.retry updates the same row", () => {
  withProtocol((socket, secretsDir) => {
    const actorId = upsertActor(socket, "mp-cc-hub-mentions")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    const posted = request(socket, "message.post", {
      room_id: roomId,
      client_message_id: randomUUID(),
      content: "@alice inspect this",
    })
    const mention = object(array(object(posted.response.data, "data").mentions, "mentions")[0], "mention")
    const mentionId = string(mention.id, "mention.id")

    const pending = request(socket, "mention.list", { room_id: roomId, state: "pending", limit: 20 })
    const pendingRows = array(object(pending.response.data, "data").mentions, "mentions")
    expect(pendingRows).toHaveLength(1)
    expect(object(pendingRows[0], "mention").source_seq).toBe(1)
    expect(object(object(pendingRows[0], "mention").target_member, "target_member").handle).toBe("alice")

    const directStore = AgoraStore.open({ secretsDir })
    directStore.failMention(mentionId, "integration failure")
    directStore.close()
    const failed = request(socket, "mention.list", { room_id: roomId, state: "failed", limit: 20 })
    expect(array(object(failed.response.data, "data").mentions, "mentions")).toHaveLength(1)

    const retried = request(socket, "mention.retry", { mention_id: mentionId })
    expect(retried.events.map(event => event.kind)).toEqual(["mention.updated"])
    const retriedMention = object(object(retried.response.data, "data").mention, "mention")
    expect(retriedMention.id).toBe(mentionId)
    expect(retriedMention.state).toBe("pending")
  })
})

test("offline owner mention emits one push notice and stays out of the CC executor queue", () => {
  withProtocol((socket, _secretsDir, protocol) => {
    const actorId = upsertActor(socket, "mp-cc-hub-owner-push")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    const posted = request(socket, "message.post", {
      room_id: roomId,
      client_message_id: randomUUID(),
      content: "@alice please answer",
    })
    const sourceMention = object(
      array(object(posted.response.data, "data").mentions, "mentions")[0],
      "mention",
    )
    const claim = protocol.store.claimMention(string(sourceMention.id, "mention.id"))
    const notices: Array<{ roomId: string; senderHandle: string; content: string }> = []
    protocol.setOwnerMentionNotifier(notice => notices.push(notice))
    socket.close()

    protocol.completeMention(claim.mention.id, claim.claimToken, "@susu owner attention")

    expect(notices).toEqual([{
      roomId,
      senderHandle: "alice",
      content: "@susu owner attention",
      roomTitle: "Agora Integration",
      senderDisplayName: "Alice",
    }])
    expect(protocol.store.listPendingMentions()).toEqual([])
    expect(protocol.store.listMentions(roomId, "pending")).toHaveLength(1)
  })
})

test("connected Agora owner suppresses mention push notice", () => {
  withProtocol((socket, _secretsDir, protocol) => {
    const actorId = upsertActor(socket, "mp-cc-hub-owner-live")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    const posted = request(socket, "message.post", {
      room_id: roomId,
      client_message_id: randomUUID(),
      content: "@alice please answer",
    })
    const sourceMention = object(
      array(object(posted.response.data, "data").mentions, "mentions")[0],
      "mention",
    )
    const claim = protocol.store.claimMention(string(sourceMention.id, "mention.id"))
    const notices: string[] = []
    protocol.setOwnerMentionNotifier(notice => notices.push(notice.roomId))

    protocol.completeMention(claim.mention.id, claim.claimToken, "@susu live owner")

    expect(notices).toEqual([])
  })
})

test("events broadcast to every connected Agora client in transaction order", () => {
  const secretsDir = mkdtempSync(join(tmpdir(), "agora-hub-broadcast-"))
  const protocol = openAgoraProtocol(secretsDir)
  protocol.setSessionDirectory({
    listAvailableActors: () => protocol.store.listCCActors(),
    upsertAvailableActor: sessionName => protocol.store.upsertCCActor(sessionName),
  })
  const first = new MemorySocket()
  const second = new MemorySocket()
  protocol.attach(first)
  protocol.attach(second)
  try {
    const actorId = upsertActor(first, "mp-cc-hub-broadcast")
    const { roomId } = createRoom(first, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    second.sent.length = 0
    const posted = request(first, "message.post", {
      room_id: roomId,
      client_message_id: randomUUID(),
      content: "@alice broadcast",
    })
    expect(posted.events.map(event => event.kind)).toEqual([
      "message.created", "mention.updated", "room.updated",
    ])
    expect(second.sent.map(event => event.kind)).toEqual([
      "message.created", "mention.updated", "room.updated",
    ])
    expect(second.sent.every(event => event.type === "agora_event" && event.room_id === roomId)).toBe(true)
  } finally {
    first.close()
    second.close()
    protocol.close()
    rmSync(secretsDir, { recursive: true, force: true })
  }
})

test("typing presence reaches only other clients viewing the same room and clears on disconnect", () => {
  const secretsDir = mkdtempSync(join(tmpdir(), "agora-hub-typing-"))
  const protocol = openAgoraProtocol(secretsDir)
  protocol.setSessionDirectory({
    listAvailableActors: () => protocol.store.listCCActors(),
    upsertAvailableActor: sessionName => protocol.store.upsertCCActor(sessionName),
  })
  const sender = new MemorySocket()
  const sameRoom = new MemorySocket()
  const otherRoom = new MemorySocket()
  protocol.attach(sender)
  protocol.attach(sameRoom)
  protocol.attach(otherRoom)
  try {
    const actorId = upsertActor(sender, "mp-cc-hub-typing")
    const floorId = randomUUID()
    const first = createRoom(sender, floorId, [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    const second = createRoom(sender, floorId, [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    request(sender, "room.open", { room_id: first.roomId, limit: 100 })
    request(sameRoom, "room.open", { room_id: first.roomId, limit: 100 })
    request(otherRoom, "room.open", { room_id: second.roomId, limit: 100 })
    sender.sent.length = 0
    sameRoom.sent.length = 0
    otherRoom.sent.length = 0

    const started = request(sender, "typing.start", { room_id: first.roomId })
    expect(started.events).toEqual([])
    expect(object(object(started.response.data, "data").typing, "typing").is_typing).toBe(true)
    expect(sameRoom.sent.map(frame => frame.kind)).toEqual(["typing.start"])
    expect(otherRoom.sent).toEqual([])

    sender.close()
    expect(sameRoom.sent.map(frame => frame.kind)).toEqual(["typing.start", "typing.stop"])
    expect(object(object(sameRoom.sent[1].data, "data").typing, "typing").display_name).toBe("禾禾")
  } finally {
    sender.close()
    sameRoom.close()
    otherRoom.close()
    protocol.close()
    rmSync(secretsDir, { recursive: true, force: true })
  }
})

test("bridge protocol starts, reports, advances to max turns, and stops", () => {
  withProtocol((socket, _secretsDir, protocol) => {
    const aliceId = upsertActor(socket, "bridge-alice")
    const bobId = upsertActor(socket, "bridge-bob")
    const { roomId } = createRoom(socket, randomUUID(), [
      { actor_id: aliceId, handle: "alice", display_name: "Alice" },
      { actor_id: bobId, handle: "bob", display_name: "Bob" },
    ])

    const started = request(socket, "bridge.start", {
      room_id: roomId,
      client_request_id: randomUUID(),
      first_actor_id: aliceId,
      second_actor_id: bobId,
      prompt: "Compare the two approaches.",
      max_turns: 1,
    })
    expect(started.response.ok).toBe(true)
    expect(started.events.map(event => event.kind)).toEqual([
      "message.created",
      "mention.updated",
      "bridge.started",
      "room.updated",
    ])
    const startedData = object(started.response.data, "start.data")
    const bridge = object(startedData.bridge, "start.bridge")
    const turn = object(startedData.current_turn, "start.current_turn")
    const claim = protocol.store.claimMention(string(turn.mention_id, "turn.mention_id"))
    const frameStart = socket.sent.length
    protocol.completeMention(claim.mention.id, claim.claimToken, "Alice's conclusion")
    expect(socket.sent.slice(frameStart).map(frame => frame.kind)).toContain("bridge.completed")

    const status = request(socket, "bridge.status", { room_id: roomId })
    const statusState = object(object(status.response.data, "status.data").bridge_state, "bridge_state")
    expect(object(statusState.bridge, "status.bridge").status).toBe("completed")

    const second = request(socket, "bridge.start", {
      room_id: roomId,
      client_request_id: randomUUID(),
      first_actor_id: bobId,
      second_actor_id: aliceId,
      prompt: "Now challenge the conclusion.",
      max_turns: 5,
    })
    const secondBridge = object(object(second.response.data, "second.data").bridge, "second.bridge")
    const stopped = request(socket, "bridge.stop", { bridge_id: string(secondBridge.id, "second.bridge.id") })
    expect(stopped.response.ok).toBe(true)
    expect(stopped.events.map(event => event.kind)).toEqual(["mention.updated", "bridge.stopped"])
  })
})

test("client disconnect while ack is sent cannot roll back the transaction", () => {
  withProtocol((socket, secretsDir) => {
    const actorId = upsertActor(socket, "mp-cc-hub-disconnect")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    const clientMessageId = randomUUID()
    socket.closeOnNextSend = true
    const posted = request(socket, "message.post", {
      room_id: roomId,
      client_message_id: clientMessageId,
      content: "survive disconnect",
    })
    expect(posted.response.ok).toBe(true)
    expect(posted.events).toEqual([])

    const inspection = AgoraStore.open({ secretsDir })
    const recovered = inspection.listMessagesAfter(roomId, 0, 20)
    inspection.close()
    expect(recovered).toHaveLength(1)
    expect(recovered[0].clientMessageId).toBe(clientMessageId)
  })
})

test("sync.resume replays edits and soft-deletes of already-seen messages as message.updated", () => {
  withProtocol(socket => {
    const actorId = upsertActor(socket, "mp-cc-hub-mutations")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    const messageIds: string[] = []
    for (let seq = 1; seq <= 3; seq += 1) {
      const posted = request(socket, "message.post", {
        room_id: roomId,
        client_message_id: randomUUID(),
        content: `message ${seq}`,
      })
      messageIds.push(string(object(object(posted.response.data, "data").message, "message").id, "message.id"))
    }
    // client 在 cursor=3 断线（全部见过）——随后 seq1 被编辑、seq2 被软删
    request(socket, "message.edit", { message_id: messageIds[0], content: "edited later" })
    request(socket, "message.delete", { message_id: messageIds[1] })

    socket.sent.length = 0
    socket.receive({
      type: "agora_request",
      request_id: randomUUID(),
      action: "sync.resume",
      payload: { cursors: { [roomId]: 3 } },
    })

    const events = socket.sent.filter(frame => frame.type === "agora_event")
    expect(events.map(frame => frame.kind)).toEqual(["message.updated", "message.updated"])
    const bySeq = events.map(frame => object(object(frame.data, "data").message, "message"))
    expect(bySeq.map(m => m.seq)).toEqual([1, 2])
    expect(bySeq[0].content).toBe("edited later")
    expect(bySeq[1].is_deleted).toBe(true)
    expect(bySeq[1].content).toBe("")
  })
})

test("sync.resume from cursor 0 (fresh open path) does not double-replay mutations", () => {
  withProtocol(socket => {
    const actorId = upsertActor(socket, "mp-cc-hub-mut-zero")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    const posted = request(socket, "message.post", {
      room_id: roomId,
      client_message_id: randomUUID(),
      content: "hello",
    })
    const messageId = string(object(object(posted.response.data, "data").message, "message").id, "message.id")
    request(socket, "message.edit", { message_id: messageId, content: "hello v2" })

    socket.sent.length = 0
    socket.receive({
      type: "agora_request",
      request_id: randomUUID(),
      action: "sync.resume",
      payload: { cursors: { [roomId]: 0 } },
    })
    // cursor=0：created 回放已带最新态（hello v2），不再补 message.updated
    const events = socket.sent.filter(frame => frame.type === "agora_event")
    expect(events.map(frame => frame.kind)).toEqual(["message.created"])
    expect(object(object(events[0].data, "data").message, "message").content).toBe("hello v2")
  })
})

test("settings.get defaults to mention_only and settings.update broadcasts then rejects unknown modes", () => {
  withProtocol(socket => {
    const got = request(socket, "settings.get", {})
    expect(got.response.ok).toBe(true)
    expect(object(got.response.data, "data").speech_mode).toBe("mention_only")

    const updated = request(socket, "settings.update", { speech_mode: "free" })
    expect(updated.response.ok).toBe(true)
    expect(object(updated.response.data, "data").speech_mode).toBe("free")
    expect(updated.events.map(event => event.kind)).toEqual(["settings.updated"])
    expect(object(updated.events[0]?.data, "event.data").speech_mode).toBe("free")

    const again = request(socket, "settings.get", {})
    expect(object(again.response.data, "data").speech_mode).toBe("free")

    const rejected = request(socket, "settings.update", { speech_mode: "loud" })
    expect(rejected.response.ok).toBe(false)
    expect(object(rejected.response.error, "error").code).toBe("invalid_speech_mode")
  })
})

test("settings.update 收 round_robin：设置/读取/广播齐全，非法值仍拒", () => {
  withProtocol(socket => {
    const updated = request(socket, "settings.update", { speech_mode: "round_robin" })
    expect(updated.response.ok).toBe(true)
    expect(object(updated.response.data, "data").speech_mode).toBe("round_robin")
    expect(updated.events.map(event => event.kind)).toEqual(["settings.updated"])
    expect(object(updated.events[0]?.data, "event.data").speech_mode).toBe("round_robin")

    const got = request(socket, "settings.get", {})
    expect(object(got.response.data, "data").speech_mode).toBe("round_robin")

    const rejected = request(socket, "settings.update", { speech_mode: "round-robin" })
    expect(rejected.response.ok).toBe(false)
    expect(object(rejected.response.error, "error").code).toBe("invalid_speech_mode")

    // 拒绝之后已设模式不被污染
    const after = request(socket, "settings.get", {})
    expect(object(after.response.data, "data").speech_mode).toBe("round_robin")
  })
})

test("settings.update 可选键集：单独改 min_speak_interval_ms，广播带两个字段", () => {
  withProtocol(socket => {
    const got = request(socket, "settings.get", {})
    expect(object(got.response.data, "data").min_speak_interval_ms).toBe(0)

    const updated = request(socket, "settings.update", { min_speak_interval_ms: 30_000 })
    expect(updated.response.ok).toBe(true)
    const data = object(updated.response.data, "data")
    expect(data.speech_mode).toBe("mention_only")   // 未带的键不动
    expect(data.min_speak_interval_ms).toBe(30_000)
    expect(updated.events.map(event => event.kind)).toEqual(["settings.updated"])
    const eventData = object(updated.events[0]?.data, "event.data")
    expect(eventData.speech_mode).toBe("mention_only")
    expect(eventData.min_speak_interval_ms).toBe(30_000)

    const again = request(socket, "settings.get", {})
    expect(object(again.response.data, "data").min_speak_interval_ms).toBe(30_000)

    const both = request(socket, "settings.update", { speech_mode: "free", min_speak_interval_ms: 0 })
    const bothData = object(both.response.data, "data")
    expect(bothData.speech_mode).toBe("free")
    expect(bothData.min_speak_interval_ms).toBe(0)

    const empty = request(socket, "settings.update", {})
    expect(empty.response.ok).toBe(false)
    expect(object(empty.response.error, "error").code).toBe("invalid_payload")

    const negative = request(socket, "settings.update", { min_speak_interval_ms: -5 })
    expect(negative.response.ok).toBe(false)
    expect(object(negative.response.error, "error").code).toBe("invalid_min_speak_interval")
  })
})

test("settings.update min_speak_interval_ms 边界：600000 收，超上限/非整数拒", () => {
  withProtocol(socket => {
    const atMax = request(socket, "settings.update", { min_speak_interval_ms: 600_000 })
    expect(atMax.response.ok).toBe(true)
    expect(object(atMax.response.data, "data").min_speak_interval_ms).toBe(600_000)
    expect(object(atMax.events[0]?.data, "event.data").min_speak_interval_ms).toBe(600_000)

    const overMax = request(socket, "settings.update", { min_speak_interval_ms: 600_001 })
    expect(overMax.response.ok).toBe(false)
    expect(object(overMax.response.error, "error").code).toBe("invalid_min_speak_interval")

    const fractional = request(socket, "settings.update", { min_speak_interval_ms: 1.5 })
    expect(fractional.response.ok).toBe(false)
    expect(object(fractional.response.error, "error").code).toBe("invalid_payload")

    const stringValue = request(socket, "settings.update", { min_speak_interval_ms: "30000" })
    expect(stringValue.response.ok).toBe(false)
    expect(object(stringValue.response.error, "error").code).toBe("invalid_payload")

    // 拒绝之后设置不被污染
    const after = request(socket, "settings.get", {})
    expect(object(after.response.data, "data").min_speak_interval_ms).toBe(600_000)
  })
})

test("free mode observe passes silently through the protocol without posting a message", () => {
  withProtocol((socket, _secretsDir, protocol) => {
    const actorId = upsertActor(socket, "mp-cc-hub-pass")
    const { roomId } = createRoom(socket, randomUUID(), [{
      actor_id: actorId,
      handle: "alice",
      display_name: "Alice",
    }])
    request(socket, "settings.update", { speech_mode: "free" })
    const posted = request(socket, "message.post", {
      room_id: roomId,
      client_message_id: randomUUID(),
      content: "no mention here, just thinking out loud",
    })
    const mentions = array(object(posted.response.data, "data").mentions, "mentions")
    expect(mentions).toHaveLength(1)
    const observeMention = object(mentions[0], "mention")
    expect(observeMention.kind).toBe("observe")
    expect(observeMention.depth).toBe(0)

    const claim = protocol.store.claimMention(string(observeMention.id, "mention.id"))
    const start = socket.sent.length
    const result = protocol.passMention(claim.mention.id, claim.claimToken)
    expect(result.idempotent).toBe(false)
    const frames = socket.sent.slice(start)
    expect(frames.map(frame => frame.kind)).toEqual(["mention.updated"])
    expect(object(object(frames[0]?.data, "event.data").mention, "mention").state).toBe("completed")
    expect(protocol.store.openRoom(roomId).messages).toHaveLength(1)

    const retried = protocol.passMention(claim.mention.id, claim.claimToken)
    expect(retried.idempotent).toBe(true)
  })
})

test("mention.list keeps observe mentions out of the inbox", () => {
  withProtocol(socket => {
    const aliceId = upsertActor(socket, "mp-cc-hub-inbox-a")
    const bobId = upsertActor(socket, "mp-cc-hub-inbox-b")
    const { roomId } = createRoom(socket, randomUUID(), [
      { actor_id: aliceId, handle: "alice", display_name: "Alice" },
      { actor_id: bobId, handle: "bob", display_name: "Bob" },
    ])
    request(socket, "settings.update", { speech_mode: "free" })
    request(socket, "message.post", {
      room_id: roomId,
      client_message_id: randomUUID(),
      content: "@alice a task for you",
    })
    const pending = request(socket, "mention.list", { room_id: roomId, state: "pending", limit: 20 })
    const rows = array(object(pending.response.data, "data").mentions, "mentions")
    expect(rows).toHaveLength(1)
    expect(object(rows[0], "mention").kind).toBe("direct")
    expect(object(object(rows[0], "mention").target_member, "target_member").handle).toBe("alice")
  })
})
