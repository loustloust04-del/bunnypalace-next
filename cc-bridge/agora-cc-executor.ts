import { AgoraStore } from "./agora-store.ts"
import {
  AGORA_LIMITS,
  AgoraStoreError,
  type AgoraActor,
  type AgoraClaimResult,
  type AgoraMention,
  type AgoraMentionDispatch,
  type AgoraMentionKind,
} from "./agora-types.ts"

export const AGORA_CONTEXT_MESSAGE_LIMIT = 80
export const AGORA_CONTEXT_TRANSCRIPT_CHARACTER_LIMIT = 40_000
export const AGORA_OBSERVE_CONTEXT_MESSAGE_LIMIT = 20
export const AGORA_OBSERVE_TRANSCRIPT_CHARACTER_LIMIT = 10_000

const SESSION_NAME_PATTERN = /^[A-Za-z0-9_.-]{1,32}$/
const CC_SESSION_PREFIX = "cc-session:"

interface ExecutorConfig {
  session_name?: string
}

interface ContextMessage {
  seq: number
  actor_id: string
  actor_handle: string | null
  actor_display_name: string | null
  content: string
}

function encodeStructuredPayload(value: object): string {
  return JSON.stringify(value).replace(/</g, "\\u003c").replace(/>/g, "\\u003e")
}

export interface AgoraCCExecutorAdapter {
  pump(): void
  recoverExpiredClaims(nowMs: number): void
  onMentionSettled(mentionId: string): void
}

export interface AgoraCCSessionManager {
  listSessions(): readonly string[]
  /** 注入可以是异步的（hub 生产实现走 per-session 串行链，不阻塞事件循环）；
   *  reject/throw = 注入失败，executor release claim 重试。 */
  ensureSessionAndSend(sessionName: string, prompt: string): void | Promise<void>
  /** 派发白名单：false = 该 session 受保护（如日常主 session），mention 直接 fail 不注入。缺省全允许。 */
  isSessionDispatchable?(sessionName: string): boolean
}

export interface AgoraCCExecutorOptions {
  leaseMs?: number
  onMentionUpdates?: (mentions: readonly AgoraMention[]) => void
  onTypingChange?: (roomId: string, actorId: string, sourceId: string, isTyping: boolean) => void
}

function sessionNameForDispatch(dispatch: AgoraMentionDispatch): string {
  if (dispatch.targetMembership.executorKind !== "cc_bridge") {
    throw new Error(`unsupported executor kind: ${dispatch.targetMembership.executorKind}`)
  }
  if (!dispatch.targetActor.externalKey.startsWith(CC_SESSION_PREFIX)) {
    throw new Error("CC actor external key is not a cc-session route")
  }
  const actorSession = dispatch.targetActor.externalKey.slice(CC_SESSION_PREFIX.length)
  let config: ExecutorConfig
  try {
    config = JSON.parse(dispatch.targetMembership.executorConfigJson) as ExecutorConfig
  } catch {
    throw new Error("executor_config_json is not valid JSON")
  }
  if (
    !config
    || typeof config !== "object"
    || Object.keys(config).length !== 1
    || typeof config.session_name !== "string"
    || !SESSION_NAME_PATTERN.test(config.session_name)
    || config.session_name !== actorSession
  ) {
    throw new Error("executor_config_json does not match the CC actor route")
  }
  return config.session_name
}

function fitSingleMessage(message: ContextMessage, characterLimit: number): ContextMessage {
  if (encodeStructuredPayload([message]).length <= characterLimit) return message
  const suffix = "…[truncated]"
  let low = 0
  let high = message.content.length
  while (low < high) {
    const middle = Math.ceil((low + high) / 2)
    const candidate = { ...message, content: message.content.slice(0, middle) + suffix }
    if (encodeStructuredPayload([candidate]).length <= characterLimit) low = middle
    else high = middle - 1
  }
  return { ...message, content: message.content.slice(0, low) + suffix }
}

export function buildAgoraClaimPrompt(store: AgoraStore, claim: AgoraClaimResult): string {
  // observe 是旁听：上下文瘦身省 input token（围观不该和发言烧一样多）
  const isObserve = claim.mention.kind === "observe"
  const messageLimit = isObserve ? AGORA_OBSERVE_CONTEXT_MESSAGE_LIMIT : AGORA_CONTEXT_MESSAGE_LIMIT
  const characterLimit = isObserve ? AGORA_OBSERVE_TRANSCRIPT_CHARACTER_LIMIT : AGORA_CONTEXT_TRANSCRIPT_CHARACTER_LIMIT
  const memberships = store.listMemberships(claim.room.id)
  const identityByActor = new Map(memberships.map(member => [member.actorId, member]))
  const candidates: ContextMessage[] = store
    .listMessagesThrough(claim.room.id, claim.sourceMessage.seq, messageLimit)
    .filter(message => !message.isDeleted)   // 软删消息不进 CC 上下文（空 content 条目只会误导模型）
    .map(message => {
      const identity = identityByActor.get(message.actorId)
      return {
        seq: message.seq,
        actor_id: message.actorId,
        actor_handle: identity?.handle ?? null,
        actor_display_name: identity?.displayName ?? null,
        content: message.content,
      }
    })

  const messages: ContextMessage[] = []
  for (let index = candidates.length - 1; index >= 0; index -= 1) {
    const candidate = fitSingleMessage(candidates[index], characterLimit)
    const next = [candidate, ...messages]
    if (encodeStructuredPayload(next).length > characterLimit) break
    messages.unshift(candidate)
  }

  const claimPayload = {
    room_id: claim.room.id,
    mention_id: claim.mention.id,
    claim_token: claim.claimToken,
    kind: claim.mention.kind,
    lease_expires_at_ms: claim.mention.leaseExpiresAtMs,
  }
  const contextPayload = {
    room: { id: claim.room.id, title: claim.room.title },
    target_member: {
      id: claim.targetMembership.id,
      handle: claim.targetMembership.handle,
      display_name: claim.targetMembership.displayName,
    },
    members: memberships.filter(member => member.isEnabled).map(member => ({
      id: member.id,
      actor_id: member.actorId,
      handle: member.handle,
      display_name: member.displayName,
      role: member.role,
    })),
    messages,
  }

  const speechMode = store.getSpeechMode()
  const instructions = claim.mention.kind === "observe"
    ? [
      "A new message arrived in a Memory Palace Agora room you are part of. You were NOT mentioned — you are listening in.",
      "If you have something worth adding, call agora_complete exactly once with mention_id, claim_token, and your reply.",
      "If not, call agora_complete with mention_id, claim_token, and pass: true to stay silent. Staying silent is normal — do not feel obliged to speak every time.",
    ]
    : [
      "You have a durable mention in a Memory Palace Agora room.",
      "Answer it by calling agora_complete exactly once with mention_id, claim_token, and your complete reply.",
    ]
  if (speechMode !== "mention_only") {
    instructions.push("Mentioning another member with @handle in your reply dispatches them to respond (chain depth is capped).")
  }
  instructions.push("Do not call the legacy reply tool for this Agora mention.")
  return [
    ...instructions,
    "<agora_claim>",
    encodeStructuredPayload(claimPayload),
    "</agora_claim>",
    "<agora_context_json>",
    encodeStructuredPayload(contextPayload),
    "</agora_context_json>",
  ].join("\n")
}

export class AgoraCCExecutor implements AgoraCCExecutorAdapter {
  private readonly activeBySession = new Map<string, { mentionId: string; roomId: string; actorId: string; kind: AgoraMentionKind }>()

  /// 该 session 是否有未答的房间 mention（hub 的 reply 守卫用：先答房间再回日常）。
  hasActiveClaim(sessionName: string): boolean {
    const active = this.activeBySession.get(sessionName)
    if (!active) return false
    return this.store.getMention(active.mentionId)?.state === "claimed"
  }
  private readonly leaseMs: number
  private readonly onMentionUpdates: (mentions: readonly AgoraMention[]) => void
  private readonly onTypingChange: (roomId: string, actorId: string, sourceId: string, isTyping: boolean) => void
  private pumping = false
  private deferredPumpTimer: ReturnType<typeof setTimeout> | null = null

  constructor(
    private readonly store: AgoraStore,
    private readonly sessions: AgoraCCSessionManager,
    options: AgoraCCExecutorOptions = {},
  ) {
    this.leaseMs = options.leaseMs ?? AGORA_LIMITS.claimLeaseMs
    this.onMentionUpdates = options.onMentionUpdates ?? (() => {})
    this.onTypingChange = options.onTypingChange ?? (() => {})
  }

  listAvailableActors(): AgoraActor[] {
    return this.availableSessionNames().map(sessionName => this.store.upsertCCActor(sessionName))
  }

  upsertAvailableActor(sessionName: string): AgoraActor {
    if (!this.availableSessionNames().includes(sessionName)) {
      throw new AgoraStoreError("session_not_available", `CC session is not available: ${sessionName}`)
    }
    return this.store.upsertCCActor(sessionName)
  }

  private availableSessionNames(): string[] {
    return [...new Set(this.sessions.listSessions())]
      .filter(sessionName => SESSION_NAME_PATTERN.test(sessionName))
      .sort()
  }

  pump(): void {
    if (this.pumping) return
    this.pumping = true
    // pump 是自治入口（启动/定时器/事件回调都会调）：任何单条 mention 的异常只能 fail 那一条，
    // 绝不允许逃出 pump 炸 hub（uncaughtException=exit(1)，会把 /cc 日常链路一起带进 crashloop）。
    try {
      for (const [sessionName, active] of this.activeBySession) {
        if (this.store.getMention(active.mentionId)?.state === "claimed") {
          // typing 续命：presence 有 120s TTL，pump 每轮（事件/60s 定时器）对仍在作答的
          // mention 重置过期戳（presence 无状态变化不会重复广播）。
          // observe 旁听可能 pass 沉默，亮灯是误报——从不点灯也就无灯可续。
          if (active.kind === "direct") this.onTypingChange(active.roomId, active.actorId, active.mentionId, true)
          continue
        }
        this.activeBySession.delete(sessionName)
        this.onTypingChange(active.roomId, active.actorId, active.mentionId, false)
      }
      this.listAvailableActors()
      const pendings = this.store.listPendingMentions()
      const gate = this.computeSpeakGate(pendings)
      const processedSessions = new Set<string>()
      for (const pending of pendings) {
        try {
          this.pumpOne(pending, processedSessions, gate.roomIds)
        } catch (error) {
          console.warn(`[agora] pump: mention ${pending.mention.id} 处理异常，跳过: ${error instanceof Error ? error.message : error}`)
        }
      }
      this.scheduleDeferredPump(gate.earliestUnblockAtMs)
    } catch (error) {
      console.warn(`[agora] pump 整体异常（已吞，等下一轮）: ${error instanceof Error ? error.message : error}`)
    } finally {
      this.pumping = false
    }
  }

  /// 房间级发言闸：interval 内说过话的房间，pending 里的 observe/接力被闸（owner 直接 @ 豁免）。
  /// 只看受闸 mention 所在的房间，返回被闸房间集合 + 最早解禁时刻（deferred re-pump 用）。
  private computeSpeakGate(
    pendings: readonly AgoraMentionDispatch[],
  ): { roomIds: Set<string>; earliestUnblockAtMs: number | null } {
    const roomIds = new Set<string>()
    let earliestUnblockAtMs: number | null = null
    const intervalMs = this.store.getMinSpeakIntervalMs()
    if (intervalMs <= 0) return { roomIds, earliestUnblockAtMs }
    const now = this.store.nowMs()
    const unblockAtByRoom = new Map<string, number | null>()
    for (const pending of pendings) {
      if (pending.mention.kind !== "observe" && pending.mention.depth === 0) continue
      const roomId = pending.room.id
      if (!unblockAtByRoom.has(roomId)) {
        const lastAt = this.store.lastAIMessageAtMs(roomId)
        unblockAtByRoom.set(roomId, lastAt === null ? null : lastAt + intervalMs)
      }
      const unblockAt = unblockAtByRoom.get(roomId) ?? null
      if (unblockAt === null || unblockAt <= now) continue
      roomIds.add(roomId)
      if (earliestUnblockAtMs === null || unblockAt < earliestUnblockAtMs) earliestUnblockAtMs = unblockAt
    }
    return { roomIds, earliestUnblockAtMs }
  }

  /// 被闸 mention 没有新事件推它，解禁时刻自动重跑 pump（每轮重算重设，防饿死）。
  private scheduleDeferredPump(unblockAtMs: number | null): void {
    if (this.deferredPumpTimer !== null) {
      clearTimeout(this.deferredPumpTimer)
      this.deferredPumpTimer = null
    }
    if (unblockAtMs === null) return
    const delayMs = Math.max(1, unblockAtMs - this.store.nowMs())
    this.deferredPumpTimer = setTimeout(() => {
      this.deferredPumpTimer = null
      this.pump()
    }, delayMs)
    this.deferredPumpTimer.unref?.()
  }

  private pumpOne(pending: AgoraMentionDispatch, processedSessions: Set<string>, gatedRoomIds: Set<string>): void {
    let sessionName: string
    try {
      sessionName = sessionNameForDispatch(pending)
    } catch (error) {
      const failed = this.store.failMention(
        pending.mention.id,
        error instanceof Error ? error.message : "invalid CC executor route",
      )
      this.onMentionUpdates([failed])
      return
    }
    // 派发白名单：日常主 session 等受保护 session 一律不注入（P0：40KB claim prompt
    // 打进日常对话）。存量 actor 指向受保护 session 的 mention 直接 fail 可见化。
    if (this.sessions.isSessionDispatchable && !this.sessions.isSessionDispatchable(sessionName)) {
      const failed = this.store.failMention(
        pending.mention.id,
        `session is protected from agora dispatch: ${sessionName}`,
      )
      this.onMentionUpdates([failed])
      return
    }
    if (processedSessions.has(sessionName) || this.activeBySession.has(sessionName)) return
    processedSessions.add(sessionName)
    const claim = this.store.claimNextMentionForSession(sessionName, this.leaseMs, [...gatedRoomIds])
    if (!claim) return
    const active = {
      mentionId: claim.mention.id,
      roomId: claim.room.id,
      actorId: claim.targetActor.id,
      kind: claim.mention.kind,
    }
    this.activeBySession.set(sessionName, active)
    this.onMentionUpdates([claim.mention])
    if (active.kind === "direct") this.onTypingChange(active.roomId, active.actorId, active.mentionId, true)
    // 注入异步化：activeBySession 已占位（同 session 不会双 claim），失败在 deliver 内 release。
    void this.deliverClaim(sessionName, claim, active)
  }

  private async deliverClaim(
    sessionName: string,
    claim: AgoraClaimResult,
    active: { mentionId: string; roomId: string; actorId: string },
  ): Promise<void> {
    try {
      await this.sessions.ensureSessionAndSend(sessionName, buildAgoraClaimPrompt(this.store, claim))
    } catch (error) {
      const released = this.store.releaseClaimAfterFailure(
        claim.mention.id,
        claim.claimToken,
        error instanceof Error ? error.message : "CC executor delivery failed",
      )
      this.activeBySession.delete(sessionName)
      this.onTypingChange(active.roomId, active.actorId, active.mentionId, false)
      this.onMentionUpdates([released])
    }
  }

  recoverExpiredClaims(nowMs: number): void {
    const recovered = this.store.recoverExpiredClaims(nowMs)
    if (recovered.length === 0) return
    const recoveredIds = new Set(recovered.map(mention => mention.id))
    for (const [sessionName, active] of this.activeBySession) {
      if (!recoveredIds.has(active.mentionId)) continue
      this.activeBySession.delete(sessionName)
      this.onTypingChange(active.roomId, active.actorId, active.mentionId, false)
    }
    this.onMentionUpdates(recovered)
    this.pump()
  }

  onMentionSettled(mentionId: string): void {
    for (const [sessionName, active] of this.activeBySession) {
      if (active.mentionId !== mentionId) continue
      this.activeBySession.delete(sessionName)
      this.onTypingChange(active.roomId, active.actorId, active.mentionId, false)
    }
    this.pump()
  }
}
