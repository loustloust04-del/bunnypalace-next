export const AGORA_LIMITS = {
  titleCharacters: 120,
  displayNameCharacters: 80,
  handleCharacters: 32,
  messageCharacters: 32_000,
  membershipsPerRoom: 16,
  mentionsPerMessage: 8,
  messagePageSize: 100,
  claimLeaseMs: 15 * 60 * 1_000,
  maxMentionAttempts: 3,
  messagePostsPerMinute: 10,
  roomCreationsPerHour: 5,
  messageRateWindowMs: 60_000,
  roomRateWindowMs: 60 * 60_000,
  maxBridgeTurns: 50,
  maxChainDepth: 6,
} as const

export const AGORA_OWNER_EXTERNAL_KEY = "owner:v1"
export const AGORA_DATABASE_FILENAME = "agora.sqlite"

export type AgoraActorKind = "owner" | "cc_bridge"
export type AgoraMemberRole = "owner" | "member"
export type AgoraExecutorKind = "none" | "cc_bridge"
export type AgoraMentionState = "pending" | "claimed" | "completed" | "failed"
/// direct = 被显式 @，必答；observe = 自由发言档的旁听机会，可 pass 沉默。
export type AgoraMentionKind = "direct" | "observe"
/// mention_only = 只有 owner @ 才派发；relay = AI 回复里 @ 成员接力（链深闸封顶）；
/// free = relay + 每条消息给其余成员发 observe；
/// round_robin = 回合制：owner 发言后按进房顺序逐个 direct 点名（可 pass 跳过），圈满静默等 owner。
export type AgoraSpeechMode = "mention_only" | "relay" | "free" | "round_robin"
export const AGORA_SPEECH_MODES: readonly AgoraSpeechMode[] = ["mention_only", "relay", "free", "round_robin"]
export type AgoraBridgeStatus = "active" | "completed" | "stopped" | "failed"
export type AgoraBridgeTurnState = "pending" | "claimed" | "completed" | "cancelled" | "failed"
export type AgoraBridgeEvent = "started" | "advanced" | "stopped" | "completed" | "failed"

export interface AgoraActor {
  id: string
  kind: AgoraActorKind
  externalKey: string
  createdAtMs: number
  disabledAtMs: number | null
}

export interface AgoraRoom {
  id: string
  floorId: string
  title: string
  ownerActorId: string
  clientRequestId: string
  isDM: boolean
  dmPeerActorId: string | null
  nextSeq: number
  isEnabled: boolean
  createdAtMs: number
  updatedAtMs: number
}

export interface AgoraTypingPresence {
  roomId: string
  actorId: string
  membershipId: string
  handle: string
  displayName: string
  isTyping: boolean
  updatedAtMs: number
}

export interface AgoraBridge {
  id: string
  roomId: string
  ownerActorId: string
  clientRequestId: string
  firstActorId: string
  secondActorId: string
  prompt: string
  status: AgoraBridgeStatus
  maxTurns: number
  turnsCompleted: number
  stopReason: string | null
  lastError: string | null
  createdAtMs: number
  updatedAtMs: number
  completedAtMs: number | null
}

export interface AgoraBridgeTurn {
  id: string
  bridgeId: string
  turnIndex: number
  sourceMessageId: string
  mentionId: string
  expectedActorId: string
  replyMessageId: string | null
  state: AgoraBridgeTurnState
  error: string | null
  createdAtMs: number
  claimedAtMs: number | null
  completedAtMs: number | null
}

export interface AgoraMembership {
  id: string
  roomId: string
  actorId: string
  handle: string
  displayName: string
  avatarRef: string | null
  role: AgoraMemberRole
  executorKind: AgoraExecutorKind
  executorConfigJson: string
  isEnabled: boolean
  joinedAtMs: number
}

export interface AgoraMessage {
  id: string
  roomId: string
  seq: number
  actorId: string
  clientMessageId: string
  content: string
  createdAtMs: number
  editedAtMs: number | null
  isDeleted: boolean
  deletedAtMs: number | null
}

export interface AgoraMessageEdit {
  id: string
  messageId: string
  editorActorId: string
  previousContent: string
  editedAtMs: number
}

export interface AgoraMention {
  id: string
  roomId: string
  sourceMessageId: string
  targetMembershipId: string
  state: AgoraMentionState
  /// observe 的沉默完成态 = state 'completed' + resultMessageId null（pass 不插消息）。
  kind: AgoraMentionKind
  /// 链深：owner 消息派生 = 0，AI 消息派生 = 源 mention depth + 1；cc 目标超 maxChainDepth 不生成。
  depth: number
  claimedAtMs: number | null
  leaseExpiresAtMs: number | null
  completedAtMs: number | null
  resultMessageId: string | null
  attemptCount: number
  lastError: string | null
  createdAtMs: number
}

export interface AgoraRoomMemberSpec {
  actorId: string
  handle: string
  displayName: string
  avatarRef?: string | null
}

export interface AgoraOwnerProfile {
  handle: string
  displayName: string
  avatarRef?: string | null
}

export interface AgoraCreateRoomInput {
  floorId: string
  title: string
  clientRequestId: string
  isDM?: boolean
  ownerProfile: AgoraOwnerProfile
  members: AgoraRoomMemberSpec[]
}

export interface AgoraRoomSnapshot {
  room: AgoraRoom
  memberships: AgoraMembership[]
}

export interface AgoraRoomCreateResult extends AgoraRoomSnapshot {
  idempotent: boolean
}

export interface AgoraRoomOpenResult extends AgoraRoomSnapshot {
  messages: AgoraMessage[]
  mentionCounts: Record<AgoraMentionState, number>
  bridge: AgoraBridgeState | null
}

export interface AgoraMessageWriteResult {
  message: AgoraMessage
  mentions: AgoraMention[]
  idempotent: boolean
  bridgeUpdate?: AgoraBridgeUpdate
  /// owner 发言抢权：本次 post 作废掉的 pending 接力 mention（depth > 0），协议层要广播 mention.updated。
  supersededMentions?: AgoraMention[]
}

export interface AgoraPassResult {
  mention: AgoraMention
  idempotent: boolean
  /// round_robin 轮次 pass 推进出的下一位 direct mention（其余情况不存在）。
  mentions?: AgoraMention[]
}

export interface AgoraBridgeStartInput {
  roomId: string
  clientRequestId: string
  firstActorId: string
  secondActorId: string
  prompt: string
  maxTurns: number
}

export interface AgoraBridgeState {
  bridge: AgoraBridge
  currentTurn: AgoraBridgeTurn | null
}

export interface AgoraBridgeStartResult extends AgoraBridgeState {
  message: AgoraMessage
  mention: AgoraMention
  idempotent: boolean
}

export interface AgoraBridgeUpdate extends AgoraBridgeState {
  event: Exclude<AgoraBridgeEvent, "started" | "stopped">
  completedTurn: AgoraBridgeTurn
  nextMention: AgoraMention | null
}

export interface AgoraBridgeStopResult extends AgoraBridgeState {
  stoppedMentions: AgoraMention[]
  idempotent: boolean
}

export interface AgoraMessageDeleteResult {
  message: AgoraMessage
  mentions: AgoraMention[]
}

export interface AgoraClaimResult {
  mention: AgoraMention
  sourceMessage: AgoraMessage
  targetMembership: AgoraMembership
  targetActor: AgoraActor
  room: AgoraRoom
  claimToken: string
}

export interface AgoraMentionDispatch {
  mention: AgoraMention
  sourceMessage: AgoraMessage
  targetMembership: AgoraMembership
  targetActor: AgoraActor
  room: AgoraRoom
}

export interface AgoraErrorDetails {
  unknown_handles?: string[]
  disabled_handles?: string[]
  handle?: string
  limit?: number
  state?: string
  retry_after_ms?: number
}

export type AgoraAction =
  | "sync.resume"
  | "actor.list"
  | "actor.upsert_cc"
  | "room.list"
  | "room.create"
  | "room.open"
  | "message.after"
  | "message.post"
  | "message.edit"
  | "message.delete"
  | "typing.start"
  | "typing.stop"
  | "bridge.start"
  | "bridge.stop"
  | "bridge.status"
  | "mention.list"
  | "mention.retry"
  | "settings.get"
  | "settings.update"

export type AgoraEventKind =
  | "room.created"
  | "room.updated"
  | "message.created"
  | "message.updated"
  | "typing.start"
  | "typing.stop"
  | "bridge.started"
  | "bridge.advanced"
  | "bridge.stopped"
  | "bridge.completed"
  | "bridge.failed"
  | "mention.updated"
  | "settings.updated"

export interface AgoraRequestEnvelope<TPayload extends object> {
  type: "agora_request"
  request_id: string
  action: AgoraAction
  payload: TPayload
}

export interface AgoraProtocolError {
  code: string
  message: string
  details?: AgoraErrorDetails
}

export type AgoraResponseEnvelope<TData extends object> =
  | { type: "agora_response"; request_id: string; ok: true; data: TData }
  | { type: "agora_response"; request_id: string; ok: false; error: AgoraProtocolError }

export interface AgoraEventEnvelope<TData extends object> {
  type: "agora_event"
  event_id: string
  room_id: string
  kind: AgoraEventKind
  data: TData
}

export type AgoraErrorCode =
  | "invalid_request"
  | "invalid_request_id"
  | "unknown_action"
  | "invalid_payload"
  | "invalid_id"
  | "invalid_floor_id"
  | "invalid_title"
  | "invalid_display_name"
  | "invalid_handle"
  | "invalid_session_name"
  | "session_not_available"
  | "invalid_message"
  | "message_not_found"
  | "not_message_owner"
  | "message_delete_forbidden"
  | "invalid_limit"
  | "rate_limit_exceeded"
  | "room_not_found"
  | "room_disabled"
  | "floor_mismatch"
  | "owner_not_found"
  | "owner_disabled"
  | "owner_membership_required"
  | "actor_not_found"
  | "actor_disabled"
  | "actor_kind_mismatch"
  | "membership_not_found"
  | "membership_disabled"
  | "membership_limit_exceeded"
  | "invalid_dm_members"
  | "dm_membership_fixed"
  | "duplicate_membership"
  | "duplicate_handle"
  | "unknown_handle"
  | "disabled_handle"
  | "self_mention_not_allowed"
  | "mention_limit_exceeded"
  | "mention_not_found"
  | "mention_not_pending"
  | "mention_already_claimed_for_actor"
  | "mention_not_claimed"
  | "claim_token_invalid"
  | "claim_lease_expired"
  | "mention_not_failed"
  | "not_room_owner"
  | "invalid_executor_config"
  | "bridge_not_found"
  | "bridge_already_active"
  | "bridge_not_active"
  | "bridge_actor_invalid"
  | "bridge_turn_mismatch"
  | "pass_not_allowed"
  | "invalid_speech_mode"
  | "invalid_min_speak_interval"
  | "migration_version_unsupported"

export class AgoraStoreError extends Error {
  constructor(
    public readonly code: AgoraErrorCode,
    message: string,
    public readonly details: AgoraErrorDetails = {},
  ) {
    super(message)
    this.name = "AgoraStoreError"
  }
}
