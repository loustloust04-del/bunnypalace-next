import { AgoraStore } from "./agora-store.ts"
import { AgoraStoreError, type AgoraTypingPresence } from "./agora-types.ts"

interface PresenceUpdate {
  presence: AgoraTypingPresence
  changed: boolean
}

/// owner 客户端 3s 无输入本来就发 stop——10s TTL 是断网/换房竞态的兜底。
export const OWNER_TYPING_TTL_MS = 10_000
/// CC executor 的 typing 由 pump 每轮续命（见 executor），120s 罩住两轮 60s 定时器；
/// CC 进程死掉后最迟 2 分钟熄灭（此前靠 15 分钟 lease 兜底才清）。
export const EXECUTOR_TYPING_TTL_MS = 120_000

export class AgoraPresenceStore {
  /// roomId:actorId → (sourceId → expiresAtMs)
  private readonly sourcesByRoomActor = new Map<string, Map<string, number>>()

  constructor(
    private readonly store: AgoraStore,
    private readonly clock: () => number = Date.now,
  ) {}

  setTyping(roomId: string, actorId: string, sourceId: string, isTyping: boolean,
            ttlMs: number = OWNER_TYPING_TTL_MS): PresenceUpdate {
    const room = this.store.getRoom(roomId)
    if (!room) throw new AgoraStoreError("room_not_found", `Agora room not found: ${roomId}`)
    if (!room.isEnabled) throw new AgoraStoreError("room_disabled", `Agora room is disabled: ${roomId}`)
    const membership = this.store.listMemberships(roomId).find(member => member.actorId === actorId)
    if (!membership) {
      throw new AgoraStoreError("membership_not_found", `Actor is not a member of room: ${actorId}`)
    }
    if (!membership.isEnabled) {
      throw new AgoraStoreError("membership_disabled", `Agora membership is disabled: ${membership.id}`)
    }

    const key = this.key(roomId, actorId)
    const sources = this.sourcesByRoomActor.get(key) ?? new Map<string, number>()
    this.dropExpired(sources)
    const wasTyping = sources.size > 0
    if (isTyping) sources.set(sourceId, this.clock() + ttlMs)
    else sources.delete(sourceId)
    if (sources.size > 0) this.sourcesByRoomActor.set(key, sources)
    else this.sourcesByRoomActor.delete(key)
    const nowTyping = sources.size > 0
    return {
      presence: this.presenceFor(roomId, actorId, membership, nowTyping),
      changed: wasTyping !== nowTyping,
    }
  }

  /// 过期 source 清扫：typing 悬挂的服务端兜底（客户端漏发 stop / 换房竞态 / CC 死亡）。
  /// 返回因此熄灭的 presence（调用方广播 typing=false）。
  sweepExpired(): AgoraTypingPresence[] {
    const stopped: AgoraTypingPresence[] = []
    for (const [key, sources] of this.sourcesByRoomActor) {
      this.dropExpired(sources)
      if (sources.size > 0) continue
      this.sourcesByRoomActor.delete(key)
      const presence = this.presenceForKey(key)
      if (presence) stopped.push(presence)
    }
    return stopped
  }

  clearSource(sourceId: string): AgoraTypingPresence[] {
    const stopped: AgoraTypingPresence[] = []
    for (const [key, sources] of this.sourcesByRoomActor) {
      if (!sources.delete(sourceId)) continue
      if (sources.size > 0) continue
      this.sourcesByRoomActor.delete(key)
      const presence = this.presenceForKey(key)
      if (presence) stopped.push(presence)
    }
    return stopped
  }

  clear(): void {
    this.sourcesByRoomActor.clear()
  }

  private dropExpired(sources: Map<string, number>): void {
    const now = this.clock()
    for (const [sourceId, expiresAt] of sources) {
      if (expiresAt <= now) sources.delete(sourceId)
    }
  }

  private presenceForKey(key: string): AgoraTypingPresence | null {
    const [roomId, actorId] = key.split(":", 2)
    const membership = this.store.listMemberships(roomId).find(member => member.actorId === actorId)
    if (!membership) return null
    return this.presenceFor(roomId, actorId, membership, false)
  }

  private presenceFor(
    roomId: string, actorId: string,
    membership: { id: string; handle: string; displayName: string },
    isTyping: boolean,
  ): AgoraTypingPresence {
    return {
      roomId,
      actorId,
      membershipId: membership.id,
      handle: membership.handle,
      displayName: membership.displayName,
      isTyping,
      updatedAtMs: this.clock(),
    }
  }

  private key(roomId: string, actorId: string): string {
    return `${roomId}:${actorId}`
  }
}
