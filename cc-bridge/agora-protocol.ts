import { randomUUID } from "node:crypto"
import { WebSocket, type RawData } from "ws"
import { AgoraPresenceStore, EXECUTOR_TYPING_TTL_MS } from "./agora-presence.ts"
import { AgoraStore } from "./agora-store.ts"
import {
  AGORA_LIMITS,
  AGORA_SPEECH_MODES,
  AgoraStoreError,
  type AgoraAction,
  type AgoraActor,
  type AgoraBridge,
  type AgoraBridgeEvent,
  type AgoraBridgeState,
  type AgoraBridgeTurn,
  type AgoraEventKind,
  type AgoraMembership,
  type AgoraMention,
  type AgoraMentionState,
  type AgoraMessage,
  type AgoraMessageWriteResult,
  type AgoraPassResult,
  type AgoraRoom,
  type AgoraRoomMemberSpec,
  type AgoraSpeechMode,
  type AgoraTypingPresence,
} from "./agora-types.ts"

type JsonPrimitive = string | number | boolean | null
type JsonValue = JsonPrimitive | JsonObject | JsonValue[]
interface JsonObject { [key: string]: JsonValue }

export interface AgoraSocket {
  readyState: number
  bufferedAmount?: number
  on(event: "message", listener: (raw: RawData) => void): this
  on(event: "close", listener: () => void): this
  send(data: string): void
  close(code?: number, reason?: string): void
}

interface PendingEvent {
  roomId: string
  kind: AgoraEventKind
  data: JsonObject
  eventId?: string
}

interface DispatchResult {
  data: JsonObject
  events: PendingEvent[]
  directEvents?: PendingEvent[]
  mentionsAvailable?: boolean
  activeRoomId?: string
  typingUpdate?: { presence: AgoraTypingPresence; changed: boolean }
}

export interface AgoraCCSessionDirectory {
  listAvailableActors(): AgoraActor[]
  upsertAvailableActor(sessionName: string): AgoraActor
}

export interface AgoraOwnerMentionNotification {
  roomId: string
  roomTitle: string
  senderHandle: string
  senderDisplayName: string
  content: string
}

const REQUEST_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const ACTIONS = new Set<AgoraAction>([
  "sync.resume",
  "actor.list",
  "actor.upsert_cc",
  "room.list",
  "room.create",
  "room.open",
  "message.after",
  "message.post",
  "message.edit",
  "message.delete",
  "typing.start",
  "typing.stop",
  "bridge.start",
  "bridge.stop",
  "bridge.status",
  "mention.list",
  "mention.retry",
  "settings.get",
  "settings.update",
])
const MENTION_STATES = new Set<AgoraMentionState>(["pending", "claimed", "completed", "failed"])

export const AGORA_MAX_BUFFERED_BYTES = 1_000_000
export const AGORA_RESUME_EVENT_LIMIT = 500
export const AGORA_RESUME_ROOM_LIMIT = 100
export const AGORA_MIN_SPEAK_INTERVAL_MAX_MS = 600_000

function isObject(value: JsonValue | undefined): value is JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function requireObject(value: JsonValue | undefined, label: string): JsonObject {
  if (!isObject(value)) throw new AgoraStoreError("invalid_payload", `${label} must be an object`)
  return value
}

function requireString(value: JsonValue | undefined, label: string): string {
  if (typeof value !== "string") throw new AgoraStoreError("invalid_payload", `${label} must be a string`)
  return value
}

function optionalString(value: JsonValue | undefined, label: string): string | null | undefined {
  if (value === undefined) return undefined
  if (value === null) return null
  if (typeof value !== "string") throw new AgoraStoreError("invalid_payload", `${label} must be a string or null`)
  return value
}

function requireInteger(value: JsonValue | undefined, label: string): number {
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new AgoraStoreError("invalid_payload", `${label} must be an integer`)
  }
  return value
}

function optionalInteger(value: JsonValue | undefined, label: string, fallback: number): number {
  return value === undefined ? fallback : requireInteger(value, label)
}

function optionalBoolean(value: JsonValue | undefined, label: string, fallback: boolean): boolean {
  if (value === undefined) return fallback
  if (typeof value !== "boolean") throw new AgoraStoreError("invalid_payload", `${label} must be a boolean`)
  return value
}

function requireExactKeys(value: JsonObject, allowed: readonly string[], label: string): void {
  const allowedKeys = new Set(allowed)
  const unexpected = Object.keys(value).find(key => !allowedKeys.has(key))
  if (unexpected) throw new AgoraStoreError("invalid_payload", `${label} contains unexpected field: ${unexpected}`)
}

function errorDetailsDTO(error: AgoraStoreError): JsonObject {
  const details: JsonObject = {}
  if (error.details.unknown_handles) details.unknown_handles = error.details.unknown_handles
  if (error.details.disabled_handles) details.disabled_handles = error.details.disabled_handles
  if (error.details.handle !== undefined) details.handle = error.details.handle
  if (error.details.limit !== undefined) details.limit = error.details.limit
  if (error.details.state !== undefined) details.state = error.details.state
  if (error.details.retry_after_ms !== undefined) details.retry_after_ms = error.details.retry_after_ms
  return details
}

function actorDTO(actor: AgoraActor): JsonObject {
  return {
    id: actor.id,
    kind: actor.kind,
    session_name: actor.externalKey.startsWith("cc-session:")
      ? actor.externalKey.slice("cc-session:".length)
      : null,
    created_at_ms: actor.createdAtMs,
    disabled_at_ms: actor.disabledAtMs,
  }
}

function memberDTO(member: AgoraMembership): JsonObject {
  return {
    id: member.id,
    room_id: member.roomId,
    actor_id: member.actorId,
    handle: member.handle,
    display_name: member.displayName,
    avatar_ref: member.avatarRef,
    role: member.role,
    executor_kind: member.executorKind,
    is_enabled: member.isEnabled,
    joined_at_ms: member.joinedAtMs,
  }
}

function roomDTO(room: AgoraRoom, memberships: readonly AgoraMembership[]): JsonObject {
  return {
    id: room.id,
    floor_id: room.floorId,
    title: room.title,
    owner_actor_id: room.ownerActorId,
    is_dm: room.isDM,
    dm_peer_actor_id: room.dmPeerActorId,
    next_seq: room.nextSeq,
    is_enabled: room.isEnabled,
    created_at_ms: room.createdAtMs,
    updated_at_ms: room.updatedAtMs,
    member_count: memberships.length,
    members: memberships.map(memberDTO),
  }
}

function messageDTO(message: AgoraMessage): JsonObject {
  return {
    id: message.id,
    room_id: message.roomId,
    seq: message.seq,
    actor_id: message.actorId,
    client_message_id: message.clientMessageId,
    content: message.content,
    created_at_ms: message.createdAtMs,
    edited_at_ms: message.editedAtMs,
    is_deleted: message.isDeleted,
    deleted_at_ms: message.deletedAtMs,
  }
}

function typingDTO(presence: AgoraTypingPresence): JsonObject {
  return {
    room_id: presence.roomId,
    actor_id: presence.actorId,
    membership_id: presence.membershipId,
    handle: presence.handle,
    display_name: presence.displayName,
    is_typing: presence.isTyping,
    updated_at_ms: presence.updatedAtMs,
  }
}

function bridgeDTO(bridge: AgoraBridge): JsonObject {
  return {
    id: bridge.id,
    room_id: bridge.roomId,
    owner_actor_id: bridge.ownerActorId,
    client_request_id: bridge.clientRequestId,
    first_actor_id: bridge.firstActorId,
    second_actor_id: bridge.secondActorId,
    prompt: bridge.prompt,
    status: bridge.status,
    max_turns: bridge.maxTurns,
    turns_completed: bridge.turnsCompleted,
    stop_reason: bridge.stopReason,
    last_error: bridge.lastError,
    created_at_ms: bridge.createdAtMs,
    updated_at_ms: bridge.updatedAtMs,
    completed_at_ms: bridge.completedAtMs,
  }
}

function bridgeTurnDTO(turn: AgoraBridgeTurn): JsonObject {
  return {
    id: turn.id,
    bridge_id: turn.bridgeId,
    turn_index: turn.turnIndex,
    source_message_id: turn.sourceMessageId,
    mention_id: turn.mentionId,
    expected_actor_id: turn.expectedActorId,
    reply_message_id: turn.replyMessageId,
    state: turn.state,
    error: turn.error,
    created_at_ms: turn.createdAtMs,
    claimed_at_ms: turn.claimedAtMs,
    completed_at_ms: turn.completedAtMs,
  }
}

function bridgeStateDTO(state: AgoraBridgeState): JsonObject {
  return {
    bridge: bridgeDTO(state.bridge),
    current_turn: state.currentTurn ? bridgeTurnDTO(state.currentTurn) : null,
  }
}

function mentionDTO(
  mention: AgoraMention,
  sourceMessage: AgoraMessage,
  targetMember: AgoraMembership,
): JsonObject {
  return {
    id: mention.id,
    room_id: mention.roomId,
    source_message_id: mention.sourceMessageId,
    source_seq: sourceMessage.seq,
    source_preview: sourceMessage.content.replace(/\s+/g, " ").slice(0, 160),
    target_membership_id: mention.targetMembershipId,
    target_member: memberDTO(targetMember),
    state: mention.state,
    kind: mention.kind,
    depth: mention.depth,
    claimed_at_ms: mention.claimedAtMs,
    lease_expires_at_ms: mention.leaseExpiresAtMs,
    completed_at_ms: mention.completedAtMs,
    result_message_id: mention.resultMessageId,
    attempt_count: mention.attemptCount,
    last_error: mention.lastError,
    created_at_ms: mention.createdAtMs,
  }
}

function mentionEventId(mention: AgoraMention): string {
  return [
    "mention",
    mention.id,
    mention.state,
    mention.attemptCount,
    mention.claimedAtMs ?? 0,
    mention.completedAtMs ?? 0,
  ].join(":")
}

export class AgoraProtocol {
  private readonly clients = new Set<AgoraSocket>()
  private readonly clientIds = new Map<AgoraSocket, string>()
  private readonly activeRoomByClient = new Map<AgoraSocket, string>()
  private readonly presence: AgoraPresenceStore
  private presenceSweeper: ReturnType<typeof setInterval> | null = null
  private onMentionsAvailable: () => void = () => {}
  private onOwnerMention: (notification: AgoraOwnerMentionNotification) => void = () => {}
  private sessionDirectory: AgoraCCSessionDirectory | null = null

  constructor(
    readonly store: AgoraStore,
    private readonly ownerActor: AgoraActor,
  ) {
    this.presence = new AgoraPresenceStore(store)
    // typing 悬挂服务端兜底：5s 扫过期 source（owner 10s / executor 120s TTL），
    // 熄灭即广播 typing.stop。unref 不阻止进程退出（测试免 dispose）。
    this.presenceSweeper = setInterval(() => {
      try {
        for (const stopped of this.presence.sweepExpired()) {
          this.broadcastRoom(stopped.roomId, [this.typingEvent(stopped)])
        }
      } catch { /* presence 兜底自身绝不抛 */ }
    }, 5_000)
    ;(this.presenceSweeper as unknown as { unref?: () => void }).unref?.()
  }

  setMentionPump(handler: () => void): void {
    this.onMentionsAvailable = handler
  }

  setSessionDirectory(directory: AgoraCCSessionDirectory): void {
    this.sessionDirectory = directory
  }

  setOwnerMentionNotifier(handler: (notification: AgoraOwnerMentionNotification) => void): void {
    this.onOwnerMention = handler
  }

  attach(ws: AgoraSocket): void {
    this.clients.add(ws)
    this.clientIds.set(ws, randomUUID())
    ws.on("message", (raw: RawData) => this.handleRaw(ws, raw))
    ws.on("close", () => {
      this.clients.delete(ws)
      this.activeRoomByClient.delete(ws)
      const sourceId = this.clientIds.get(ws)
      this.clientIds.delete(ws)
      if (!sourceId) return
      for (const stopped of this.presence.clearSource(sourceId)) {
        this.broadcastRoom(stopped.roomId, [this.typingEvent(stopped)])
      }
    })
  }

  close(): void {
    if (this.presenceSweeper) { clearInterval(this.presenceSweeper); this.presenceSweeper = null }
    this.clients.clear()
    this.clientIds.clear()
    this.activeRoomByClient.clear()
    this.presence.clear()
    this.store.close()
  }

  private safeSend(ws: AgoraSocket, value: JsonObject): boolean {
    if (ws.readyState !== WebSocket.OPEN) return false
    const payload = JSON.stringify(value)
    if ((ws.bufferedAmount ?? 0) + Buffer.byteLength(payload) > AGORA_MAX_BUFFERED_BYTES) {
      try { ws.close(1013, "backpressure") } catch {}
      return false
    }
    try {
      ws.send(payload)
      return true
    } catch {
      return false
    }
  }

  private handleRaw(ws: AgoraSocket, raw: RawData): void {
    let requestId = ""
    try {
      const rawText = Array.isArray(raw)
        ? Buffer.concat(raw).toString()
        : raw instanceof ArrayBuffer
          ? Buffer.from(raw).toString()
          : raw.toString()
      if (Buffer.byteLength(rawText) > 128_000) {
        throw new AgoraStoreError("invalid_request", "Agora request is too large")
      }
      let decoded: JsonValue
      try {
        decoded = JSON.parse(rawText)
      } catch {
        throw new AgoraStoreError("invalid_request", "Agora request is not valid JSON")
      }
      const envelope = requireObject(decoded, "request")
      if (typeof envelope.request_id === "string") requestId = envelope.request_id
      if (envelope.type !== "agora_request") {
        throw new AgoraStoreError("invalid_request", "Expected agora_request envelope")
      }
      if (!REQUEST_ID_PATTERN.test(requestId)) {
        throw new AgoraStoreError("invalid_request_id", "request_id must be a UUID")
      }
      requireExactKeys(envelope, ["type", "request_id", "action", "payload"], "request")
      const actionValue = requireString(envelope.action, "action")
      if (!ACTIONS.has(actionValue as AgoraAction)) {
        throw new AgoraStoreError("unknown_action", `Unknown Agora action: ${actionValue}`)
      }
      const result = this.dispatch(actionValue as AgoraAction, requireObject(envelope.payload, "payload"), ws)
      if (result.activeRoomId) this.activeRoomByClient.set(ws, result.activeRoomId)
      if (result.directEvents) this.sendEvents(ws, result.directEvents)
      this.safeSend(ws, {
        type: "agora_response",
        request_id: requestId,
        ok: true,
        data: result.data,
      })
      this.broadcast(result.events)
      if (result.typingUpdate?.changed) {
        this.broadcastRoom(
          result.typingUpdate.presence.roomId,
          [this.typingEvent(result.typingUpdate.presence)],
          ws,
        )
      }
      if (result.mentionsAvailable) this.onMentionsAvailable()
    } catch (error) {
      if (error instanceof AgoraStoreError) {
        this.safeSend(ws, {
          type: "agora_response",
          request_id: requestId,
          ok: false,
          error: {
            code: error.code,
            message: error.message,
            details: errorDetailsDTO(error),
          },
        })
        return
      }
      console.error(`[hub] Agora request failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`)
      this.safeSend(ws, {
        type: "agora_response",
        request_id: requestId,
        ok: false,
        error: { code: "internal_error", message: "Agora request failed" },
      })
    }
  }

  private broadcast(events: readonly PendingEvent[]): void {
    for (const client of this.clients) this.sendEvents(client, events)
  }

  private broadcastRoom(roomId: string, events: readonly PendingEvent[], excluding?: AgoraSocket): void {
    for (const client of this.clients) {
      if (client === excluding || this.activeRoomByClient.get(client) !== roomId) continue
      this.sendEvents(client, events)
    }
  }

  private sendEvents(client: AgoraSocket, events: readonly PendingEvent[]): void {
    for (const event of events) {
      const envelope: JsonObject = {
        type: "agora_event",
        event_id: event.eventId ?? randomUUID(),
        room_id: event.roomId,
        kind: event.kind,
        data: event.data,
      }
      if (!this.safeSend(client, envelope)) return
    }
  }

  publishMentionUpdates(mentions: readonly AgoraMention[]): void {
    const events: PendingEvent[] = []
    const bridgeIds = new Set<string>()
    for (const mention of mentions) {
      const members = this.store.listMemberships(mention.roomId)
      events.push({
        roomId: mention.roomId,
        kind: "mention.updated",
        data: { mention: this.mentionDTOForRoom(mention, members) },
        eventId: mentionEventId(mention),
      })
      const state = this.store.getBridgeStateForMention(mention.id)
      if (state && !bridgeIds.has(state.bridge.id)) {
        bridgeIds.add(state.bridge.id)
        const event: AgoraBridgeEvent = state.bridge.status === "failed" ? "failed" : "advanced"
        events.push(this.bridgeEvent(state, event))
      }
    }
    this.broadcast(events)
  }

  /// executor 路径（CC 的 typing）：TTL 放宽到 120s，pump 每轮续命——CC 死后最迟 2min 熄灭。
  publishTyping(roomId: string, actorId: string, sourceId: string, isTyping: boolean): void {
    const update = this.presence.setTyping(roomId, actorId, sourceId, isTyping, EXECUTOR_TYPING_TTL_MS)
    if (update.changed) this.broadcastRoom(roomId, [this.typingEvent(update.presence)])
  }

  private typingEvent(presence: AgoraTypingPresence): PendingEvent {
    return {
      roomId: presence.roomId,
      kind: presence.isTyping ? "typing.start" : "typing.stop",
      data: { typing: typingDTO(presence) },
    }
  }

  private bridgeEvent(state: AgoraBridgeState, event: AgoraBridgeEvent): PendingEvent {
    return {
      roomId: state.bridge.roomId,
      kind: `bridge.${event}` as AgoraEventKind,
      data: bridgeStateDTO(state),
      eventId: `bridge:${state.bridge.id}:${event}:${state.bridge.updatedAtMs}`,
    }
  }

  completeMention(mentionId: string, claimToken: string, content: string): AgoraMessageWriteResult {
    const result = this.store.completeMention(mentionId, claimToken, content)
    if (result.idempotent) return result
    const completed = this.store.getMention(mentionId)
    if (!completed) throw new Error(`Completed Agora mention disappeared: ${mentionId}`)
    const members = this.store.listMemberships(completed.roomId)
    const events: PendingEvent[] = [
      {
        roomId: completed.roomId,
        kind: "message.created",
        data: { message: messageDTO(result.message) },
        eventId: `message:${result.message.id}`,
      },
      {
        roomId: completed.roomId,
        kind: "mention.updated",
        data: { mention: this.mentionDTOForRoom(completed, members) },
        eventId: mentionEventId(completed),
      },
      ...result.mentions.map(mention => ({
        roomId: completed.roomId,
        kind: "mention.updated" as const,
        data: { mention: this.mentionDTOForRoom(mention, members) },
        eventId: mentionEventId(mention),
      })),
      ...(result.supersededMentions ?? []).map(mention => ({
        roomId: completed.roomId,
        kind: "mention.updated" as const,
        data: { mention: this.mentionDTOForRoom(mention, members) },
        eventId: mentionEventId(mention),
      })),
      this.roomEvent(completed.roomId),
    ]
    if (result.bridgeUpdate) {
      events.push(this.bridgeEvent(result.bridgeUpdate, result.bridgeUpdate.event))
    }
    this.broadcast(events)
    this.notifyOfflineOwnerMentions(result, completed.roomId, members)
    if (result.mentions.length > 0) this.onMentionsAvailable()
    return result
  }

  passMention(mentionId: string, claimToken: string): AgoraPassResult {
    const result = this.store.passMention(mentionId, claimToken)
    if (result.idempotent) return result
    const members = this.store.listMemberships(result.mention.roomId)
    this.broadcast([{
      roomId: result.mention.roomId,
      kind: "mention.updated",
      data: { mention: this.mentionDTOForRoom(result.mention, members) },
      eventId: mentionEventId(result.mention),
    }])
    return result
  }

  private notifyOfflineOwnerMentions(
    result: AgoraMessageWriteResult,
    roomId: string,
    members: readonly AgoraMembership[],
  ): void {
    if ([...this.clients].some(client => client.readyState === WebSocket.OPEN)) return
    const room = this.store.getRoom(roomId)
    const sender = members.find(member => member.actorId === result.message.actorId)
    if (!room || !sender) return
    for (const mention of result.mentions) {
      const target = members.find(member => member.id === mention.targetMembershipId)
      if (target?.actorId !== this.ownerActor.id) continue
      this.onOwnerMention({
        roomId,
        roomTitle: room.title,
        senderHandle: sender.handle,
        senderDisplayName: sender.displayName,
        content: result.message.content,
      })
    }
  }

  private mentionDTOForRoom(mention: AgoraMention, members: readonly AgoraMembership[]): JsonObject {
    const source = this.store.getMessage(mention.sourceMessageId)
    const target = members.find(member => member.id === mention.targetMembershipId)
    if (!source || !target) throw new Error(`Agora mention ${mention.id} has broken references`)
    return mentionDTO(mention, source, target)
  }

  private roomEvent(roomId: string): PendingEvent {
    const room = this.store.getRoom(roomId)
    if (!room) throw new Error(`Agora room disappeared after commit: ${roomId}`)
    const members = this.store.listMemberships(room.id)
    return {
      roomId,
      kind: "room.updated",
      data: { room: roomDTO(room, members) },
      eventId: `room:${room.id}:${room.updatedAtMs}`,
    }
  }

  private dispatch(action: AgoraAction, payload: JsonObject, ws: AgoraSocket): DispatchResult {
    switch (action) {
      case "sync.resume":
        return this.resume(payload)
      case "actor.list": {
        requireExactKeys(payload, [], "payload")
        if (!this.sessionDirectory) throw new Error("Agora CC session discovery is not configured")
        return { data: { actors: this.sessionDirectory.listAvailableActors().map(actorDTO) }, events: [] }
      }
      case "actor.upsert_cc": {
        requireExactKeys(payload, ["session_name"], "payload")
        if (!this.sessionDirectory) throw new Error("Agora CC session discovery is not configured")
        const actor = this.sessionDirectory.upsertAvailableActor(requireString(payload.session_name, "session_name"))
        return { data: { actor: actorDTO(actor) }, events: [] }
      }
      case "room.list": {
        requireExactKeys(payload, ["floor_id"], "payload")
        const rooms = this.store.listRooms(requireString(payload.floor_id, "floor_id"))
        return { data: { rooms: rooms.map(snapshot => roomDTO(snapshot.room, snapshot.memberships)) }, events: [] }
      }
      case "room.create":
        return this.createRoom(payload)
      case "room.open":
        return this.openRoom(payload)
      case "message.after":
        return this.messagesAfter(payload)
      case "message.post":
        return this.postMessage(payload)
      case "message.edit":
        return this.editMessage(payload)
      case "message.delete":
        return this.deleteMessage(payload)
      case "typing.start":
        return this.setTyping(payload, ws, true)
      case "typing.stop":
        return this.setTyping(payload, ws, false)
      case "bridge.start":
        return this.startBridge(payload)
      case "bridge.stop":
        return this.stopBridge(payload)
      case "bridge.status":
        return this.bridgeStatus(payload)
      case "mention.list":
        return this.listMentions(payload)
      case "mention.retry":
        return this.retryMention(payload)
      case "settings.get":
        requireExactKeys(payload, [], "payload")
        return {
          data: {
            speech_mode: this.store.getSpeechMode(),
            min_speak_interval_ms: this.store.getMinSpeakIntervalMs(),
          },
          events: [],
        }
      case "settings.update":
        return this.updateSettings(payload)
    }
  }

  private updateSettings(payload: JsonObject): DispatchResult {
    // 可选键集：至少带一个，逐个校验后写入。
    requireExactKeys(payload, ["speech_mode", "min_speak_interval_ms"], "payload")
    if (payload.speech_mode === undefined && payload.min_speak_interval_ms === undefined) {
      throw new AgoraStoreError("invalid_payload", "payload must include speech_mode or min_speak_interval_ms")
    }
    if (payload.speech_mode !== undefined) {
      const value = requireString(payload.speech_mode, "speech_mode")
      if (!AGORA_SPEECH_MODES.includes(value as AgoraSpeechMode)) {
        throw new AgoraStoreError("invalid_speech_mode", `Unknown Agora speech mode: ${value}`)
      }
      this.store.setSpeechMode(value as AgoraSpeechMode)
    }
    if (payload.min_speak_interval_ms !== undefined) {
      const intervalMs = requireInteger(payload.min_speak_interval_ms, "min_speak_interval_ms")
      if (intervalMs < 0 || intervalMs > AGORA_MIN_SPEAK_INTERVAL_MAX_MS) {
        throw new AgoraStoreError(
          "invalid_min_speak_interval",
          `min_speak_interval_ms must be an integer between 0 and ${AGORA_MIN_SPEAK_INTERVAL_MAX_MS}`,
        )
      }
      this.store.setMinSpeakIntervalMs(intervalMs)
    }
    const settings = {
      speech_mode: this.store.getSpeechMode(),
      min_speak_interval_ms: this.store.getMinSpeakIntervalMs(),
    }
    return {
      data: { ...settings },
      // settings 是全局的，room_id 留空——broadcast 不看 room，全客户端可见（Mac/iPhone 同步）。
      // eventId 不给：来回切换会撞死复用 id，让 sendEvents 落到 randomUUID。
      events: [{
        roomId: "",
        kind: "settings.updated",
        data: { ...settings },
      }],
    }
  }

  private resume(payload: JsonObject): DispatchResult {
    requireExactKeys(payload, ["cursors"], "payload")
    const cursors = requireObject(payload.cursors, "cursors")
    const entries = Object.entries(cursors)
    if (entries.length > AGORA_RESUME_ROOM_LIMIT) {
      throw new AgoraStoreError(
        "invalid_limit",
        `Reconnect resume accepts at most ${AGORA_RESUME_ROOM_LIMIT} room cursors`,
        { limit: AGORA_RESUME_ROOM_LIMIT },
      )
    }

    const directEvents: PendingEvent[] = []
    let hasMore = false
    for (const [roomId, value] of entries.sort(([left], [right]) => left.localeCompare(right))) {
      const afterSeq = requireInteger(value, `cursors.${roomId}`)
      if (afterSeq < 0) throw new AgoraStoreError("invalid_payload", `cursors.${roomId} must be non-negative`)
      let cursor = afterSeq
      while (directEvents.length < AGORA_RESUME_EVENT_LIMIT) {
        const remaining = Math.min(AGORA_LIMITS.messagePageSize, AGORA_RESUME_EVENT_LIMIT - directEvents.length)
        const messages = this.store.listMessagesAfter(roomId, cursor, remaining)
        if (messages.length === 0) break
        for (const message of messages) {
          directEvents.push({
            roomId,
            kind: "message.created",
            data: { message: messageDTO(message) },
            eventId: `message:${message.id}`,
          })
        }
        cursor = messages.at(-1)?.seq ?? cursor
        if (messages.length < remaining) break
      }
      // 补放 mutation：断连期间对旧消息（seq ≤ cursor）的编辑/软删不产生新 seq，
      // 上面的 created 回放看不见——按 cursor 消息的 created_at 做时间水位，把之后
      // 发生过 mutation 的消息以 message.updated 重放（已见过的由 client 幂等 merge 吸收）。
      // 软删"内容不再可见"的隐私预期依赖这条通路。时钟回拨是已知边界（单机 hub 可忽略）。
      if (afterSeq > 0 && directEvents.length < AGORA_RESUME_EVENT_LIMIT) {
        const sinceMs = this.store.messageCreatedAt(roomId, afterSeq)
        for (const mutated of this.store.listMutatedSince(roomId, sinceMs,
          Math.min(AGORA_LIMITS.messagePageSize, AGORA_RESUME_EVENT_LIMIT - directEvents.length))) {
          if (mutated.seq > afterSeq) continue   // cursor 之后的新消息已按最新态回放过
          directEvents.push({
            roomId,
            kind: "message.updated",
            data: { message: messageDTO(mutated) },
            eventId: `message:${mutated.id}:m${mutated.deletedAtMs ?? mutated.editedAtMs ?? 0}`,
          })
        }
      }
      const room = this.store.getRoom(roomId)
      if (!room) throw new AgoraStoreError("room_not_found", `Agora room not found: ${roomId}`)
      if (cursor < room.nextSeq - 1) hasMore = true
      if (directEvents.length >= AGORA_RESUME_EVENT_LIMIT) {
        hasMore ||= entries.some(([candidate]) => candidate > roomId)
        break
      }
    }
    return {
      data: { replayed_count: directEvents.length, has_more: hasMore },
      events: [],
      directEvents,
    }
  }

  private createRoom(payload: JsonObject): DispatchResult {
    requireExactKeys(
      payload,
      ["client_request_id", "floor_id", "title", "is_dm", "owner_profile", "member_specs"],
      "payload",
    )
    const ownerProfile = requireObject(payload.owner_profile, "owner_profile")
    requireExactKeys(ownerProfile, ["handle", "display_name", "avatar_ref"], "owner_profile")
    if (!Array.isArray(payload.member_specs)) {
      throw new AgoraStoreError("invalid_payload", "member_specs must be an array")
    }
    const members: AgoraRoomMemberSpec[] = payload.member_specs.map((value, index) => {
      const member = requireObject(value, `member_specs[${index}]`)
      requireExactKeys(member, ["actor_id", "handle", "display_name", "avatar_ref"], `member_specs[${index}]`)
      return {
        actorId: requireString(member.actor_id, `member_specs[${index}].actor_id`),
        handle: requireString(member.handle, `member_specs[${index}].handle`),
        displayName: requireString(member.display_name, `member_specs[${index}].display_name`),
        avatarRef: optionalString(member.avatar_ref, `member_specs[${index}].avatar_ref`),
      }
    })
    const created = this.store.createRoom({
      clientRequestId: requireString(payload.client_request_id, "client_request_id"),
      floorId: requireString(payload.floor_id, "floor_id"),
      title: requireString(payload.title, "title"),
      isDM: optionalBoolean(payload.is_dm, "is_dm", false),
      ownerProfile: {
        handle: requireString(ownerProfile.handle, "owner_profile.handle"),
        displayName: requireString(ownerProfile.display_name, "owner_profile.display_name"),
        avatarRef: optionalString(ownerProfile.avatar_ref, "owner_profile.avatar_ref"),
      },
      members,
    })
    const room = roomDTO(created.room, created.memberships)
    return {
      data: { room, idempotent: created.idempotent },
      events: created.idempotent
        ? []
        : [{
            roomId: created.room.id,
            kind: "room.created",
            data: { room },
            eventId: `room-created:${created.room.id}`,
          }],
    }
  }

  private openRoom(payload: JsonObject): DispatchResult {
    requireExactKeys(payload, ["room_id", "before_seq", "limit"], "payload")
    const beforeSeq = payload.before_seq === undefined
      ? undefined
      : requireInteger(payload.before_seq, "before_seq")
    const opened = this.store.openRoom(
      requireString(payload.room_id, "room_id"),
      beforeSeq,
      optionalInteger(payload.limit, "limit", AGORA_LIMITS.messagePageSize),
    )
    return {
      data: {
        room: roomDTO(opened.room, opened.memberships),
        members: opened.memberships.map(memberDTO),
        messages: opened.messages.map(messageDTO),
        mention_counts: opened.mentionCounts,
        bridge: opened.bridge ? bridgeStateDTO(opened.bridge) : null,
        has_more: opened.messages.length > 0 && opened.messages[0].seq > 1,
      },
      events: [],
      activeRoomId: opened.room.id,
    }
  }

  private setTyping(payload: JsonObject, ws: AgoraSocket, isTyping: boolean): DispatchResult {
    requireExactKeys(payload, ["room_id"], "payload")
    const roomId = requireString(payload.room_id, "room_id")
    // start 要求房间在场；stop 放宽——换房时 room.open 可能先于 typing.stop 到达
    //（客户端 stop 是不 await 的 detached Task），拒掉 stop = 旧房间 typing 悬挂到 TTL。
    if (isTyping && this.activeRoomByClient.get(ws) !== roomId) {
      throw new AgoraStoreError("invalid_payload", "typing presence requires the room to be open")
    }
    const sourceId = this.clientIds.get(ws)
    if (!sourceId) throw new AgoraStoreError("invalid_request", "Agora client is not attached")
    const update = this.presence.setTyping(roomId, this.ownerActor.id, sourceId, isTyping)
    return {
      data: { typing: typingDTO(update.presence) },
      events: [],
      typingUpdate: update,
    }
  }

  private startBridge(payload: JsonObject): DispatchResult {
    requireExactKeys(
      payload,
      ["room_id", "client_request_id", "first_actor_id", "second_actor_id", "prompt", "max_turns"],
      "payload",
    )
    const started = this.store.startBridge({
      roomId: requireString(payload.room_id, "room_id"),
      clientRequestId: requireString(payload.client_request_id, "client_request_id"),
      firstActorId: requireString(payload.first_actor_id, "first_actor_id"),
      secondActorId: requireString(payload.second_actor_id, "second_actor_id"),
      prompt: requireString(payload.prompt, "prompt"),
      maxTurns: requireInteger(payload.max_turns, "max_turns"),
    })
    const state: AgoraBridgeState = { bridge: started.bridge, currentTurn: started.currentTurn }
    const members = this.store.listMemberships(started.bridge.roomId)
    const mention = this.mentionDTOForRoom(started.mention, members)
    const data: JsonObject = {
      ...bridgeStateDTO(state),
      message: messageDTO(started.message),
      mention,
    }
    if (started.idempotent) return { data, events: [] }
    return {
      data,
      events: [
        {
          roomId: started.bridge.roomId,
          kind: "message.created",
          data: { message: messageDTO(started.message) },
          eventId: `message:${started.message.id}`,
        },
        {
          roomId: started.bridge.roomId,
          kind: "mention.updated",
          data: { mention },
          eventId: mentionEventId(started.mention),
        },
        this.bridgeEvent(state, "started"),
        this.roomEvent(started.bridge.roomId),
      ],
      mentionsAvailable: true,
    }
  }

  private stopBridge(payload: JsonObject): DispatchResult {
    requireExactKeys(payload, ["bridge_id"], "payload")
    const stopped = this.store.stopBridge(
      requireString(payload.bridge_id, "bridge_id"),
      this.ownerActor.id,
    )
    const members = this.store.listMemberships(stopped.bridge.roomId)
    return {
      data: { ...bridgeStateDTO(stopped), idempotent: stopped.idempotent },
      events: stopped.idempotent
        ? []
        : [
            ...stopped.stoppedMentions.map(mention => ({
              roomId: stopped.bridge.roomId,
              kind: "mention.updated" as const,
              data: { mention: this.mentionDTOForRoom(mention, members) },
              eventId: mentionEventId(mention),
            })),
            this.bridgeEvent(stopped, "stopped"),
          ],
      mentionsAvailable: !stopped.idempotent,
    }
  }

  private bridgeStatus(payload: JsonObject): DispatchResult {
    requireExactKeys(payload, ["room_id"], "payload")
    const state = this.store.getBridgeStateForRoom(requireString(payload.room_id, "room_id"))
    return { data: { bridge_state: state ? bridgeStateDTO(state) : null }, events: [] }
  }

  private messagesAfter(payload: JsonObject): DispatchResult {
    requireExactKeys(payload, ["room_id", "after_seq", "limit"], "payload")
    const roomId = requireString(payload.room_id, "room_id")
    const messages = this.store.listMessagesAfter(
      roomId,
      requireInteger(payload.after_seq, "after_seq"),
      optionalInteger(payload.limit, "limit", AGORA_LIMITS.messagePageSize),
    )
    const room = this.store.getRoom(roomId)
    if (!room) throw new Error(`Agora room disappeared during cursor read: ${roomId}`)
    return {
      data: {
        messages: messages.map(messageDTO),
        has_more: messages.length > 0 && messages[messages.length - 1].seq < room.nextSeq - 1,
      },
      events: [],
    }
  }

  private postMessage(payload: JsonObject): DispatchResult {
    requireExactKeys(payload, ["room_id", "client_message_id", "content"], "payload")
    const roomId = requireString(payload.room_id, "room_id")
    const room = this.store.getRoom(roomId)
    if (!room) throw new AgoraStoreError("room_not_found", `Agora room not found: ${roomId}`)
    const result = this.store.postOwnerMessage(
      roomId,
      requireString(payload.client_message_id, "client_message_id"),
      requireString(payload.content, "content"),
      room.floorId,
    )
    const members = this.store.listMemberships(roomId)
    const mentionDTOs = result.mentions.map(mention => this.mentionDTOForRoom(mention, members))
    const data: JsonObject = {
      message: messageDTO(result.message),
      mentions: mentionDTOs,
      idempotent: result.idempotent,
    }
    if (result.idempotent) return { data, events: [] }
    const events: PendingEvent[] = [
      {
        roomId,
        kind: "message.created",
        data: { message: messageDTO(result.message) },
        eventId: `message:${result.message.id}`,
      },
      ...result.mentions.map((mention, index) => ({
        roomId,
        kind: "mention.updated" as const,
        data: { mention: mentionDTOs[index] },
        eventId: mentionEventId(mention),
      })),
      ...(result.supersededMentions ?? []).map(mention => ({
        roomId,
        kind: "mention.updated" as const,
        data: { mention: this.mentionDTOForRoom(mention, members) },
        eventId: mentionEventId(mention),
      })),
      this.roomEvent(roomId),
    ]
    return { data, events, mentionsAvailable: result.mentions.length > 0 }
  }

  private editMessage(payload: JsonObject): DispatchResult {
    requireExactKeys(payload, ["message_id", "content"], "payload")
    const message = this.store.editMessage(
      requireString(payload.message_id, "message_id"),
      this.ownerActor.id,
      requireString(payload.content, "content"),
    )
    const dto = messageDTO(message)
    return {
      data: { message: dto },
      events: [{
        roomId: message.roomId,
        kind: "message.updated",
        data: { message: dto },
        eventId: `message-edit:${message.id}:${message.editedAtMs ?? 0}`,
      }],
    }
  }

  private deleteMessage(payload: JsonObject): DispatchResult {
    requireExactKeys(payload, ["message_id"], "payload")
    const result = this.store.deleteMessage(
      requireString(payload.message_id, "message_id"),
      this.ownerActor.id,
    )
    const dto = messageDTO(result.message)
    const members = this.store.listMemberships(result.message.roomId)
    return {
      data: { message: dto },
      events: [
        {
          roomId: result.message.roomId,
          kind: "message.updated",
          data: { message: dto },
          eventId: `message-delete:${result.message.id}:${result.message.deletedAtMs ?? 0}`,
        },
        ...result.mentions.map(mention => ({
          roomId: result.message.roomId,
          kind: "mention.updated" as const,
          data: { mention: this.mentionDTOForRoom(mention, members) },
          eventId: mentionEventId(mention),
        })),
      ],
    }
  }

  private listMentions(payload: JsonObject): DispatchResult {
    requireExactKeys(payload, ["room_id", "state", "limit"], "payload")
    let state: AgoraMentionState | undefined
    if (payload.state !== undefined) {
      const value = requireString(payload.state, "state")
      if (!MENTION_STATES.has(value as AgoraMentionState)) {
        throw new AgoraStoreError("invalid_payload", `Invalid mention state: ${value}`)
      }
      state = value as AgoraMentionState
    }
    const roomId = requireString(payload.room_id, "room_id")
    const members = this.store.listMemberships(roomId)
    // 收件箱只关心必答的：observe 旁听机会不进列表（沉默/作废是正常态不是任务）。
    const mentions = this.store.listMentions(
      roomId,
      state,
      optionalInteger(payload.limit, "limit", AGORA_LIMITS.messagePageSize),
      "direct",
    )
    return {
      data: { mentions: mentions.map(mention => this.mentionDTOForRoom(mention, members)) },
      events: [],
    }
  }

  private retryMention(payload: JsonObject): DispatchResult {
    requireExactKeys(payload, ["mention_id"], "payload")
    const mention = this.store.retryFailedMention(
      requireString(payload.mention_id, "mention_id"),
      this.ownerActor.id,
    )
    const members = this.store.listMemberships(mention.roomId)
    const dto = this.mentionDTOForRoom(mention, members)
    return {
      data: { mention: dto },
      events: [{
        roomId: mention.roomId,
        kind: "mention.updated",
        data: { mention: dto },
        eventId: mentionEventId(mention),
      }],
      mentionsAvailable: true,
    }
  }
}

export function openAgoraProtocol(secretsDir: string): AgoraProtocol {
  const store = AgoraStore.open({ secretsDir })
  try {
    return new AgoraProtocol(store, store.upsertOwnerActor())
  } catch (error) {
    store.close()
    throw error
  }
}

export function hasValidAgoraToken(requestUrl: string, hubToken: string): boolean {
  const url = new URL(requestUrl, "http://localhost")
  return url.pathname === "/agora" && url.searchParams.get("token") === hubToken
}
