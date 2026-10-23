import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { Database } from "bun:sqlite"
import { randomUUID } from "node:crypto"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { AgoraStore } from "./agora-store.ts"
import {
  AGORA_DATABASE_FILENAME,
  AGORA_LIMITS,
  AgoraStoreError,
  type AgoraActor,
  type AgoraErrorCode,
  type AgoraMessageWriteResult,
} from "./agora-types.ts"

let secretsDir = ""
let previousSecretsDir: string | undefined
let store: AgoraStore
let now = 1_720_000_000_000
let floorId = ""

function expectStoreError(action: () => void, code: AgoraErrorCode): AgoraStoreError {
  try {
    action()
    throw new Error(`Expected AgoraStoreError(${code})`)
  } catch (error) {
    expect(error).toBeInstanceOf(AgoraStoreError)
    const storeError = error as AgoraStoreError
    expect(storeError.code).toBe(code)
    return storeError
  }
}

function onlyMention(result: AgoraMessageWriteResult) {
  const mention = result.mentions[0]
  if (!mention) throw new Error("Expected exactly one mention in fixture")
  return mention
}

function createActors(): { owner: AgoraActor; alice: AgoraActor; bob: AgoraActor } {
  return {
    owner: store.upsertOwnerActor(),
    alice: store.upsertCCActor("mp-cc-alice"),
    bob: store.upsertCCActor("mp-cc-bob"),
  }
}

function createRoom() {
  const actors = createActors()
  const snapshot = store.createRoom({
    floorId,
    title: "Agora MVP",
    clientRequestId: randomUUID(),
    ownerProfile: { handle: "Susu", displayName: "禾禾" },
    members: [
      { actorId: actors.alice.id, handle: "Alice", displayName: "Alice" },
      { actorId: actors.bob.id, handle: "bob", displayName: "Bob" },
    ],
  })
  return { ...actors, ...snapshot }
}

beforeEach(() => {
  previousSecretsDir = process.env.MP_CC_SECRETS_DIR
  secretsDir = mkdtempSync(join(tmpdir(), "agora-store-test-"))
  process.env.MP_CC_SECRETS_DIR = secretsDir
  now = 1_720_000_000_000
  floorId = randomUUID()
  store = AgoraStore.open({ clock: () => now })
})

afterEach(() => {
  store.close()
  if (previousSecretsDir === undefined) delete process.env.MP_CC_SECRETS_DIR
  else process.env.MP_CC_SECRETS_DIR = previousSecretsDir
  rmSync(secretsDir, { recursive: true, force: true })
})

describe("migration and database isolation", () => {
  test("first and repeated open apply migrations once with required pragmas and no FK violations", () => {
    expect(store.databasePath).toBe(join(secretsDir, AGORA_DATABASE_FILENAME))
    expect(store.health()).toEqual({
      foreignKeys: true,
      journalMode: "wal",
      synchronous: 1,
      busyTimeoutMs: 5000,
      migrationVersions: [1, 2, 3, 4, 5, 6],
      foreignKeyViolations: [],
    })

    store.close()
    store = AgoraStore.open({ clock: () => now + 1 })
    expect(store.health().migrationVersions).toEqual([1, 2, 3, 4, 5, 6])
  })

  test("a v1 DDL failure rolls back the migration table and every prior v1 statement", () => {
    store.close()
    const path = join(secretsDir, AGORA_DATABASE_FILENAME)
    rmSync(path, { force: true })
    rmSync(`${path}-shm`, { force: true })
    rmSync(`${path}-wal`, { force: true })
    const raw = new Database(path, { create: true })
    raw.exec("CREATE TABLE agora_actors (broken TEXT)")
    raw.close()

    expect(() => AgoraStore.open({ clock: () => now })).toThrow()
    const inspection = new Database(path)
    const tables = inspection.query<{ name: string }, []>(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    ).all().map(row => row.name)
    expect(tables).toEqual(["agora_actors"])
    inspection.close()

    rmSync(path, { force: true })
    store = AgoraStore.open({ clock: () => now })
  })
})

describe("actors, rooms, and memberships", () => {
  test("owner and CC actor upserts are stable by external key", () => {
    const firstOwner = store.upsertOwnerActor()
    const secondOwner = store.upsertOwnerActor()
    const firstCC = store.upsertCCActor("mp-cc-alice")
    const secondCC = store.upsertCCActor("mp-cc-alice")
    expect(secondOwner).toEqual(firstOwner)
    expect(secondCC).toEqual(firstCC)
    expect(firstOwner.externalKey).toBe("owner:v1")
    expect(firstCC.externalKey).toBe("cc-session:mp-cc-alice")
    expectStoreError(() => store.upsertCCActor("bad session"), "invalid_session_name")
  })

  test("room creation is atomic, normalizes handles, derives executor config, and is idempotent", () => {
    const { owner, alice, bob } = createActors()
    const requestId = randomUUID()
    const created = store.createRoom({
      floorId: ` ${floorId} `,
      title: " Agora MVP ",
      clientRequestId: requestId,
      ownerProfile: { handle: "SUSU", displayName: " 禾禾 " },
      members: [
        { actorId: alice.id, handle: "ALICE", displayName: " Alice " },
        { actorId: bob.id, handle: "bob", displayName: "Bob" },
      ],
    })
    expect(created.room.floorId).toBe(floorId)
    expect(created.room.title).toBe("Agora MVP")
    expect(created.room.ownerActorId).toBe(owner.id)
    expect(new Set(created.memberships.map(member => member.handle))).toEqual(new Set(["susu", "alice", "bob"]))
    expect(created.memberships.find(member => member.handle === "alice")?.executorConfigJson)
      .toBe('{"session_name":"mp-cc-alice"}')

    const retried = store.createRoom({
      floorId: randomUUID(),
      title: "Different title",
      clientRequestId: requestId,
      ownerProfile: { handle: "other", displayName: "Other" },
      members: [],
    })
    expect(retried.room.id).toBe(created.room.id)
    expect(retried.room.title).toBe("Agora MVP")
    expect(store.listRooms(floorId)).toHaveLength(1)
  })

  test("duplicate actors and case-insensitive handles roll back membership insertion", () => {
    const { room, alice } = createRoom()
    const charlie = store.upsertCCActor("mp-cc-charlie")
    expectStoreError(
      () => store.addMember(room.id, { actorId: charlie.id, handle: "ALICE", displayName: "Charlie" }),
      "duplicate_handle",
    )
    expectStoreError(
      () => store.addMember(room.id, { actorId: alice.id, handle: "alice-2", displayName: "Alice Again" }),
      "duplicate_membership",
    )
    expect(store.listMemberships(room.id)).toHaveLength(3)
  })

  test("direct rooms contain one agent, deduplicate by floor and peer, and keep membership fixed", () => {
    const { alice, bob } = createActors()
    const created = store.createRoom({
      floorId,
      title: "Alice",
      clientRequestId: randomUUID(),
      isDM: true,
      ownerProfile: { handle: "susu", displayName: "禾禾" },
      members: [{ actorId: alice.id, handle: "alice", displayName: "Alice" }],
    })
    expect(created.room.isDM).toBe(true)
    expect(created.room.dmPeerActorId).toBe(alice.id)
    expect(created.memberships).toHaveLength(2)

    const canonical = store.createRoom({
      floorId,
      title: "Renamed Alice",
      clientRequestId: randomUUID(),
      isDM: true,
      ownerProfile: { handle: "owner", displayName: "Owner" },
      members: [{ actorId: alice.id, handle: "alice-new", displayName: "Alice New" }],
    })
    expect(canonical.idempotent).toBe(true)
    expect(canonical.room.id).toBe(created.room.id)
    expect(store.listRooms(floorId).filter(snapshot => snapshot.room.isDM)).toHaveLength(1)

    const otherFloor = store.createRoom({
      floorId: randomUUID(),
      title: "Alice elsewhere",
      clientRequestId: randomUUID(),
      isDM: true,
      ownerProfile: { handle: "susu", displayName: "禾禾" },
      members: [{ actorId: alice.id, handle: "alice", displayName: "Alice" }],
    })
    expect(otherFloor.room.id).not.toBe(created.room.id)

    expectStoreError(
      () => store.addMember(created.room.id, { actorId: bob.id, handle: "bob", displayName: "Bob" }),
      "dm_membership_fixed",
    )

    expectStoreError(() => store.createRoom({
      floorId,
      title: "Invalid DM",
      clientRequestId: randomUUID(),
      isDM: true,
      ownerProfile: { handle: "susu", displayName: "禾禾" },
      members: [],
    }), "invalid_dm_members")
  })

  test("room creation rejects more than sixteen memberships before writing anything", () => {
    const { alice } = createActors()
    const members = Array.from({ length: AGORA_LIMITS.membershipsPerRoom }, (_, index) => ({
      actorId: alice.id,
      handle: `member-${index}`,
      displayName: `Member ${index}`,
    }))
    expectStoreError(() => store.createRoom({
      floorId,
      title: "Too Large",
      clientRequestId: randomUUID(),
      ownerProfile: { handle: "susu", displayName: "Susu" },
      members,
    }), "membership_limit_exceeded")
    expect(store.listRooms(floorId)).toHaveLength(0)
  })

  test("room creation rate limit allows five per hour, preserves idempotent retries, and resets in memory", () => {
    const { alice, bob } = createActors()
    const requestIds: string[] = []
    for (let index = 0; index < AGORA_LIMITS.roomCreationsPerHour; index += 1) {
      const clientRequestId = randomUUID()
      requestIds.push(clientRequestId)
      store.createRoom({
        floorId: randomUUID(),
        title: `Room ${index}`,
        clientRequestId,
        ownerProfile: { handle: "susu", displayName: "Susu" },
        members: [
          { actorId: alice.id, handle: "alice", displayName: "Alice" },
          { actorId: bob.id, handle: "bob", displayName: "Bob" },
        ],
      })
    }

    const retried = store.createRoom({
      floorId: randomUUID(),
      title: "Ignored retry payload",
      clientRequestId: requestIds[0],
      ownerProfile: { handle: "other", displayName: "Other" },
      members: [],
    })
    expect(retried.idempotent).toBe(true)
    expect(retried.room.title).toBe("Room 0")

    const limited = expectStoreError(() => store.createRoom({
      floorId: randomUUID(),
      title: "One Too Many",
      clientRequestId: randomUUID(),
      ownerProfile: { handle: "susu", displayName: "Susu" },
      members: [],
    }), "rate_limit_exceeded")
    expect(limited.details).toEqual({
      limit: AGORA_LIMITS.roomCreationsPerHour,
      retry_after_ms: AGORA_LIMITS.roomRateWindowMs,
    })

    store.close()
    store = AgoraStore.open({ clock: () => now })
    for (let index = 0; index < AGORA_LIMITS.roomCreationsPerHour; index += 1) {
      store.createRoom({
        floorId: randomUUID(),
        title: `Restarted room ${index}`,
        clientRequestId: randomUUID(),
        ownerProfile: { handle: "susu", displayName: "Susu" },
        members: [],
      })
    }
    expectStoreError(() => store.createRoom({
      floorId: randomUUID(),
      title: "Restarted One Too Many",
      clientRequestId: randomUUID(),
      ownerProfile: { handle: "susu", displayName: "Susu" },
      members: [],
    }), "rate_limit_exceeded")

    now += AGORA_LIMITS.roomRateWindowMs
    const boundary = store.createRoom({
      floorId: randomUUID(),
      title: "Boundary Room",
      clientRequestId: randomUUID(),
      ownerProfile: { handle: "susu", displayName: "Susu" },
      members: [],
    })
    expect(boundary.idempotent).toBe(false)
  })

  test("member join enforces the sixteen-membership ceiling without a partial insert", () => {
    const { room } = createRoom()
    for (let index = 0; index < 13; index += 1) {
      const actor = store.upsertCCActor(`mp-cc-cap-${index}`)
      store.addMember(room.id, {
        actorId: actor.id,
        handle: `cap-${index}`,
        displayName: `Cap ${index}`,
      })
    }
    expect(store.listMemberships(room.id)).toHaveLength(AGORA_LIMITS.membershipsPerRoom)
    const overflow = store.upsertCCActor("mp-cc-overflow")
    expectStoreError(
      () => store.addMember(room.id, { actorId: overflow.id, handle: "overflow", displayName: "Overflow" }),
      "membership_limit_exceeded",
    )
    expect(store.listMemberships(room.id)).toHaveLength(AGORA_LIMITS.membershipsPerRoom)
  })

  test("room open and cursor reads return messages in ascending seq order", () => {
    const { room } = createRoom()
    for (let index = 1; index <= 5; index += 1) {
      store.postOwnerMessage(room.id, randomUUID(), `message ${index}`, floorId)
      now += 1
    }
    expect(store.openRoom(room.id, undefined, 2).messages.map(message => message.seq)).toEqual([4, 5])
    expect(store.openRoom(room.id, 4, 2).messages.map(message => message.seq)).toEqual([2, 3])
    expect(store.listMessagesAfter(room.id, 2, 2).map(message => message.seq)).toEqual([3, 4])
  })
})

describe("owner post transaction", () => {
  test("only the original actor can edit while preserving seq and durable edit history", () => {
    const { owner, alice, room } = createRoom()
    const posted = store.postOwnerMessage(room.id, randomUUID(), "original", floorId)
    now += 25
    const edited = store.editMessage(posted.message.id, owner.id, "updated")
    expect(edited).toMatchObject({
      id: posted.message.id,
      seq: posted.message.seq,
      content: "updated",
      editedAtMs: now,
    })
    expect(store.listMessageEdits(posted.message.id)).toEqual([expect.objectContaining({
      messageId: posted.message.id,
      editorActorId: owner.id,
      previousContent: "original",
      editedAtMs: now,
    })])
    expectStoreError(() => store.editMessage(posted.message.id, alice.id, "forged"), "not_message_owner")
    expect(store.getMessage(posted.message.id)?.content).toBe("updated")
    expect(store.getRoom(room.id)?.nextSeq).toBe(2)

    store.close()
    store = AgoraStore.open({ clock: () => now + 1 })
    expect(store.getMessage(posted.message.id)?.editedAtMs).toBe(now)
    expect(store.listMessageEdits(posted.message.id)).toHaveLength(1)
  })

  test("owner can soft-delete any message while actors can only delete their own", () => {
    const { owner, alice, bob, room } = createRoom()
    const source = store.postOwnerMessage(room.id, randomUUID(), "@alice answer", floorId)
    const claim = store.claimMention(onlyMention(source).id)
    const answer = store.completeMention(claim.mention.id, claim.claimToken, "agent answer")

    expectStoreError(
      () => store.deleteMessage(answer.message.id, bob.id),
      "message_delete_forbidden",
    )
    const actorDeleted = store.deleteMessage(answer.message.id, alice.id)
    expect(actorDeleted.message).toMatchObject({
      id: answer.message.id,
      seq: 2,
      content: "",
      isDeleted: true,
      deletedAtMs: now,
    })

    const pending = store.postOwnerMessage(room.id, randomUUID(), "@bob pending", floorId)
    const ownerDeleted = store.deleteMessage(pending.message.id, owner.id)
    expect(ownerDeleted.message.seq).toBe(3)
    expect(ownerDeleted.mentions[0]).toMatchObject({ state: "failed", lastError: "source message deleted" })
    expect(store.getRoom(room.id)?.nextSeq).toBe(4)
    expect(store.openRoom(room.id).messages.map(message => message.seq)).toEqual([1, 2, 3])
  })

  test("one multi-target post writes one message and one pending mention per distinct target", () => {
    const { room, memberships } = createRoom()
    const result = store.postOwnerMessage(
      room.id,
      randomUUID(),
      "@Alice review this, @bob give a second opinion, @ALICE again",
      floorId,
    )
    expect(result.idempotent).toBe(false)
    expect(result.message.seq).toBe(1)
    expect(result.mentions).toHaveLength(2)
    const aliceMembership = memberships.find(member => member.handle === "alice")
    const bobMembership = memberships.find(member => member.handle === "bob")
    if (!aliceMembership || !bobMembership) throw new Error("Missing member fixture")
    expect(result.mentions.map(mention => mention.targetMembershipId)).toEqual([
      aliceMembership.id,
      bobMembership.id,
    ])
    expect(result.mentions.every(mention => mention.state === "pending")).toBe(true)
    expect(store.openRoom(room.id).room.nextSeq).toBe(2)
  })

  test("client_message_id retry returns the original write before revalidating content", () => {
    const { room } = createRoom()
    const clientMessageId = randomUUID()
    const first = store.postOwnerMessage(room.id, clientMessageId, "@alice hello", floorId)
    const retry = store.postOwnerMessage(room.id, clientMessageId, "   ", floorId)
    expect(retry.idempotent).toBe(true)
    expect(retry.message.id).toBe(first.message.id)
    expect(retry.mentions.map(mention => mention.id)).toEqual(first.mentions.map(mention => mention.id))
    const next = store.postOwnerMessage(room.id, randomUUID(), "no mention", floorId)
    expect(next.message.seq).toBe(2)
  })

  test("message rate limit allows ten per minute, preserves idempotent retries, and resets in memory", () => {
    const { room } = createRoom()
    const clientMessageIds: string[] = []
    for (let index = 0; index < AGORA_LIMITS.messagePostsPerMinute; index += 1) {
      const clientMessageId = randomUUID()
      clientMessageIds.push(clientMessageId)
      store.postOwnerMessage(room.id, clientMessageId, `message ${index}`, floorId)
    }

    const retried = store.postOwnerMessage(room.id, clientMessageIds[0], "   ", floorId)
    expect(retried.idempotent).toBe(true)
    expect(retried.message.seq).toBe(1)

    const limited = expectStoreError(
      () => store.postOwnerMessage(room.id, randomUUID(), "one too many", floorId),
      "rate_limit_exceeded",
    )
    expect(limited.details).toEqual({
      limit: AGORA_LIMITS.messagePostsPerMinute,
      retry_after_ms: AGORA_LIMITS.messageRateWindowMs,
    })
    expect(store.getRoom(room.id)?.nextSeq).toBe(AGORA_LIMITS.messagePostsPerMinute + 1)

    store.close()
    store = AgoraStore.open({ clock: () => now })
    for (let index = 0; index < AGORA_LIMITS.messagePostsPerMinute; index += 1) {
      store.postOwnerMessage(room.id, randomUUID(), `restarted message ${index}`, floorId)
    }
    expectStoreError(
      () => store.postOwnerMessage(room.id, randomUUID(), "restarted one too many", floorId),
      "rate_limit_exceeded",
    )

    now += AGORA_LIMITS.messageRateWindowMs
    const boundary = store.postOwnerMessage(room.id, randomUUID(), "boundary message", floorId)
    expect(boundary.message.seq).toBe((AGORA_LIMITS.messagePostsPerMinute * 2) + 1)
  })

  test("unknown, self, and disabled targets each roll back message, mentions, seq, and room timestamp", () => {
    const { room, memberships } = createRoom()
    const initialRoom = store.getRoom(room.id)
    expectStoreError(
      () => store.postOwnerMessage(room.id, randomUUID(), "@missing hello", floorId),
      "unknown_handle",
    )
    expectStoreError(
      () => store.postOwnerMessage(room.id, randomUUID(), "@susu hello", floorId),
      "self_mention_not_allowed",
    )
    const aliceMembership = memberships.find(member => member.handle === "alice")
    if (!aliceMembership) throw new Error("Missing Alice membership fixture")
    store.setMembershipEnabled(aliceMembership.id, false)
    expectStoreError(
      () => store.postOwnerMessage(room.id, randomUUID(), "@alice hello", floorId),
      "disabled_handle",
    )
    expect(store.openRoom(room.id).messages).toEqual([])
    expect(store.listMentions(room.id)).toEqual([])
    expect(store.getRoom(room.id)?.nextSeq).toBe(1)
    expect(store.getRoom(room.id)?.updatedAtMs).toBe(initialRoom?.updatedAtMs)
  })

  test("floor mismatch, disabled room, and disabled owner membership reject canonical writes", () => {
    const { room, memberships } = createRoom()
    expectStoreError(
      () => store.postOwnerMessage(room.id, randomUUID(), "hello", randomUUID()),
      "floor_mismatch",
    )
    store.setRoomEnabled(room.id, false)
    expectStoreError(
      () => store.postOwnerMessage(room.id, randomUUID(), "hello", floorId),
      "room_disabled",
    )
    store.setRoomEnabled(room.id, true)
    store.setMembershipEnabled(memberships[0].id, false)
    expectStoreError(
      () => store.postOwnerMessage(room.id, randomUUID(), "hello", floorId),
      "membership_disabled",
    )
    expect(store.openRoom(room.id).messages).toEqual([])
  })

  test("message length and distinct target limits fail before seq allocation", () => {
    const { room } = createRoom()
    expectStoreError(
      () => store.postOwnerMessage(room.id, randomUUID(), "   ", floorId),
      "invalid_message",
    )
    expectStoreError(
      () => store.postOwnerMessage(room.id, randomUUID(), "x".repeat(AGORA_LIMITS.messageCharacters + 1), floorId),
      "invalid_message",
    )
    const handles: string[] = ["alice", "bob"]
    for (let index = 0; index < 7; index += 1) {
      const actor = store.upsertCCActor(`mp-cc-extra-${index}`)
      const handle = `extra-${index}`
      handles.push(handle)
      store.addMember(room.id, { actorId: actor.id, handle, displayName: `Extra ${index}` })
    }
    expectStoreError(
      () => store.postOwnerMessage(room.id, randomUUID(), handles.map(handle => `@${handle}`).join(" "), floorId),
      "mention_limit_exceeded",
    )
    expect(store.openRoom(room.id).messages).toEqual([])
    expect(store.getRoom(room.id)?.nextSeq).toBe(1)
  })
})

describe("claim, completion, lease, and recovery", () => {
  test("actors, room, memberships, messages, and claimed mentions survive reopen and recover by lease", () => {
    const { room, memberships } = createRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "@alice persistent", floorId)
    const claim = store.claimMention(onlyMention(post).id, 10)
    store.close()
    now += 10
    store = AgoraStore.open({ clock: () => now })

    expect(store.getRoom(room.id)?.id).toBe(room.id)
    expect(store.listMemberships(room.id).map(member => member.id).sort())
      .toEqual(memberships.map(member => member.id).sort())
    expect(store.openRoom(room.id).messages.map(message => message.id)).toEqual([post.message.id])
    expect(store.listMentions(room.id)[0]?.state).toBe("claimed")
    const recovered = store.recoverExpiredClaims()
    expect(recovered).toHaveLength(1)
    expect(recovered[0]?.id).toBe(claim.mention.id)
    expect(recovered[0]?.state).toBe("pending")
  })

  test("claim uses a 32-byte capability, serializes one CC actor, and preserves source order", () => {
    const { room } = createRoom()
    const first = store.postOwnerMessage(room.id, randomUUID(), "@alice first", floorId)
    now += 1
    store.postOwnerMessage(room.id, randomUUID(), "@alice second", floorId)
    const claim = store.claimNextMentionForSession("mp-cc-alice")
    expect(claim?.mention.id).toBe(onlyMention(first).id)
    expect(Buffer.from(claim?.claimToken ?? "", "base64url")).toHaveLength(32)
    const inspection = new Database(store.databasePath, { readonly: true })
    const stored = inspection.query<{ claimTokenHash: string | null }, [string]>(
      "SELECT claim_token_hash AS claimTokenHash FROM agora_mentions WHERE id = ?",
    ).get(claim?.mention.id ?? "")
    inspection.close()
    expect(stored?.claimTokenHash).toHaveLength(64)
    expect(stored?.claimTokenHash).not.toBe(claim?.claimToken)
    expect(store.claimNextMentionForSession("mp-cc-alice")).toBeNull()
    expectStoreError(() => store.claimMention(store.listMentions(room.id, "pending")[0].id), "mention_already_claimed_for_actor")
  })

  test("completion writes the agent result and original completion atomically", () => {
    const { room } = createRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "@alice please answer", floorId)
    const claim = store.claimMention(onlyMention(post).id)
    now += 1
    const completed = store.completeMention(claim.mention.id, claim.claimToken, "Answer for everyone; @bob continue")
    expect(completed.idempotent).toBe(false)
    expect(completed.message.seq).toBe(2)
    expect(completed.message.actorId).toBe(claim.targetActor.id)
    expect(completed.message.clientMessageId).toBe(`mention:${claim.mention.id}`)
    // 缺省档 mention_only：CC 回复里 @bob 不派发
    expect(completed.mentions).toHaveLength(0)
    const original = store.listMentions(room.id).find(mention => mention.id === claim.mention.id)
    expect(original?.state).toBe("completed")
    expect(original?.resultMessageId).toBe(completed.message.id)

    const retry = store.completeMention(claim.mention.id, claim.claimToken, "")
    expect(retry.idempotent).toBe(true)
    expect(retry.message.id).toBe(completed.message.id)
    expect(store.openRoom(room.id).messages.map(message => message.seq)).toEqual([1, 2])
    expectStoreError(
      () => store.completeMention(claim.mention.id, "wrong-token", "different"),
      "mention_not_claimed",
    )
  })

  test("mention_only 档：CC 回复 @其他 AI 不派发，@owner 的 mention 保留（离线推送靠它）", () => {
    const { room, owner } = createRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "@alice kick off", floorId)
    const aliceClaim = store.claimMention(onlyMention(post).id)
    now += 1
    const aliceDone = store.completeMention(aliceClaim.mention.id, aliceClaim.claimToken, "sure; @bob your turn, @susu done")
    expect(aliceDone.mentions).toHaveLength(1)
    const ownerMembership = store.listMemberships(room.id).find(member => member.actorId === owner.id)
    if (!ownerMembership) throw new Error("Missing owner membership fixture")
    expect(onlyMention(aliceDone).targetMembershipId).toBe(ownerMembership.id)
    expect(onlyMention(aliceDone).kind).toBe("direct")
    expect(onlyMention(aliceDone).depth).toBe(1)
    expect(store.claimNextMentionForSession("mp-cc-bob")).toBeNull()
  })

  test("agent completion rate limit leaves the eleventh claim active until the window resets", () => {
    const { room } = createRoom()
    const mentionIds: string[] = []
    for (let index = 0; index <= AGORA_LIMITS.messagePostsPerMinute; index += 1) {
      const post = store.postOwnerMessage(room.id, randomUUID(), `@alice task ${index}`, floorId)
      mentionIds.push(onlyMention(post).id)
      now += 6_001
    }

    const completedClaims = mentionIds.slice(0, AGORA_LIMITS.messagePostsPerMinute).map((mentionId, index) => {
      const claim = store.claimMention(mentionId)
      store.completeMention(claim.mention.id, claim.claimToken, `answer ${index}`)
      return claim
    })
    const nextSeqBeforeLimit = store.getRoom(room.id)?.nextSeq
    const limitedClaim = store.claimMention(mentionIds[AGORA_LIMITS.messagePostsPerMinute])
    const limited = expectStoreError(
      () => store.completeMention(limitedClaim.mention.id, limitedClaim.claimToken, "answer limited"),
      "rate_limit_exceeded",
    )
    expect(limited.details.limit).toBe(AGORA_LIMITS.messagePostsPerMinute)
    expect(limited.details.retry_after_ms).toBe(AGORA_LIMITS.messageRateWindowMs)
    expect(store.getRoom(room.id)?.nextSeq).toBe(nextSeqBeforeLimit)
    expect(store.listMentions(room.id).find(mention => mention.id === limitedClaim.mention.id)?.state).toBe("claimed")

    const retriedCompletion = store.completeMention(
      completedClaims[0].mention.id,
      completedClaims[0].claimToken,
      "",
    )
    expect(retriedCompletion.idempotent).toBe(true)

    now += AGORA_LIMITS.messageRateWindowMs
    const boundary = store.completeMention(limitedClaim.mention.id, limitedClaim.claimToken, "answer after reset")
    expect(boundary.idempotent).toBe(false)
  })

  test("wrong and cross-mention claim tokens cannot create a result message", () => {
    const { room } = createRoom()
    const alicePost = store.postOwnerMessage(room.id, randomUUID(), "@alice answer", floorId)
    const bobPost = store.postOwnerMessage(room.id, randomUUID(), "@bob answer", floorId)
    const aliceClaim = store.claimMention(onlyMention(alicePost).id)
    const bobClaim = store.claimMention(onlyMention(bobPost).id)
    expectStoreError(
      () => store.completeMention(aliceClaim.mention.id, "wrong-token", "forged"),
      "claim_token_invalid",
    )
    expectStoreError(
      () => store.completeMention(aliceClaim.mention.id, bobClaim.claimToken, "cross claim"),
      "claim_token_invalid",
    )
    expect(store.openRoom(room.id).messages.map(message => message.seq)).toEqual([1, 2])
    expect(store.getRoom(room.id)?.nextSeq).toBe(3)
  })

  test("unknown, self, disabled, and expired completion failures preserve the active claim and seq", () => {
    const { room, memberships } = createRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "@alice answer", floorId)
    const claim = store.claimMention(onlyMention(post).id, 100)
    expectStoreError(
      () => store.completeMention(claim.mention.id, claim.claimToken, "@missing nope"),
      "unknown_handle",
    )
    expectStoreError(
      () => store.completeMention(claim.mention.id, claim.claimToken, "@alice self"),
      "self_mention_not_allowed",
    )
    const bobMembership = memberships.find(member => member.handle === "bob")
    if (!bobMembership) throw new Error("Missing Bob membership fixture")
    store.setMembershipEnabled(bobMembership.id, false)
    expectStoreError(
      () => store.completeMention(claim.mention.id, claim.claimToken, "@bob disabled"),
      "disabled_handle",
    )
    expect(store.openRoom(room.id).messages.map(message => message.seq)).toEqual([1])
    expect(store.getRoom(room.id)?.nextSeq).toBe(2)
    expect(store.listMentions(room.id).find(mention => mention.id === claim.mention.id)?.state).toBe("claimed")
    now += 100
    expectStoreError(
      () => store.completeMention(claim.mention.id, claim.claimToken, "too late"),
      "claim_lease_expired",
    )
  })

  test("expired claims return pending, exceed three attempts into failed, reject stale tokens, and retry in place", () => {
    const { owner, room } = createRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "@alice retry me", floorId)
    const mentionId = onlyMention(post).id
    let firstToken = ""
    for (let attempt = 1; attempt <= 4; attempt += 1) {
      const claim = store.claimMention(mentionId, 10)
      if (attempt === 1) firstToken = claim.claimToken
      now += 10
      const recovered = store.recoverExpiredClaims(now)
      expect(recovered).toHaveLength(1)
      expect(recovered[0].attemptCount).toBe(attempt)
      expect(recovered[0].state).toBe(attempt > AGORA_LIMITS.maxMentionAttempts ? "failed" : "pending")
    }
    expectStoreError(
      () => store.completeMention(mentionId, firstToken, "stale"),
      "mention_not_claimed",
    )
    const retried = store.retryFailedMention(mentionId, owner.id)
    expect(retried.id).toBe(mentionId)
    expect(retried.state).toBe("pending")
    expect(retried.attemptCount).toBe(4)
    expect(store.openRoom(room.id).messages).toHaveLength(1)
  })

  test("tmux send failure releases a claim, records a concise error, and eventually fails", () => {
    const { room } = createRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "@alice deliver", floorId)
    const mentionId = onlyMention(post).id
    for (let attempt = 1; attempt <= 4; attempt += 1) {
      const claim = store.claimMention(mentionId)
      const released = store.releaseClaimAfterFailure(
        mentionId,
        claim.claimToken,
        ` send failed\nwith details ${"x".repeat(600)} `,
      )
      expect(released.attemptCount).toBe(attempt)
      expect((released.lastError ?? "").length).toBeLessThanOrEqual(500)
      expect(released.state).toBe(attempt > AGORA_LIMITS.maxMentionAttempts ? "failed" : "pending")
    }
  })
})

describe("bridge auto-relay", () => {
  test("progresses expected actors transactionally and completes exactly at max turns", () => {
    const { alice, bob, room } = createRoom()
    const requestId = randomUUID()
    const started = store.startBridge({
      roomId: room.id,
      clientRequestId: requestId,
      firstActorId: alice.id,
      secondActorId: bob.id,
      prompt: "Discuss the launch plan",
      maxTurns: 2,
    })
    expect(started.idempotent).toBe(false)
    expect(started.currentTurn?.turnIndex).toBe(0)
    expect(started.currentTurn?.expectedActorId).toBe(alice.id)
    expect(started.message.seq).toBe(1)
    expect(started.message.content).toBe("@alice Discuss the launch plan")

    const retried = store.startBridge({
      roomId: room.id,
      clientRequestId: requestId,
      firstActorId: alice.id,
      secondActorId: bob.id,
      prompt: "Discuss the launch plan",
      maxTurns: 2,
    })
    expect(retried.idempotent).toBe(true)
    expect(retried.bridge.id).toBe(started.bridge.id)

    const aliceClaim = store.claimMention(started.mention.id)
    const firstReply = store.completeMention(aliceClaim.mention.id, aliceClaim.claimToken, "Alice's view")
    expect(firstReply.bridgeUpdate?.event).toBe("advanced")
    expect(firstReply.bridgeUpdate?.bridge.turnsCompleted).toBe(1)
    expect(firstReply.bridgeUpdate?.currentTurn?.turnIndex).toBe(1)
    expect(firstReply.bridgeUpdate?.currentTurn?.expectedActorId).toBe(bob.id)
    expect(firstReply.mentions).toHaveLength(1)

    const bobClaim = store.claimMention(firstReply.mentions[0].id)
    const finalReply = store.completeMention(bobClaim.mention.id, bobClaim.claimToken, "Bob's conclusion")
    expect(finalReply.bridgeUpdate?.event).toBe("completed")
    expect(finalReply.bridgeUpdate?.bridge.status).toBe("completed")
    expect(finalReply.bridgeUpdate?.bridge.turnsCompleted).toBe(2)
    expect(finalReply.bridgeUpdate?.currentTurn).toBeNull()
    expect(finalReply.mentions).toEqual([])
    expect(store.listBridgeTurns(started.bridge.id).map(turn => turn.state)).toEqual(["completed", "completed"])
    expect(store.openRoom(room.id).messages.map(message => message.seq)).toEqual([1, 2, 3])
  })

  test("owner stop cancels the durable turn and prevents a late completion", () => {
    const { owner, alice, bob, room } = createRoom()
    const started = store.startBridge({
      roomId: room.id,
      clientRequestId: randomUUID(),
      firstActorId: alice.id,
      secondActorId: bob.id,
      prompt: "Stop-safe discussion",
      maxTurns: 5,
    })
    const claim = store.claimMention(started.mention.id)
    const stopped = store.stopBridge(started.bridge.id, owner.id)
    expect(stopped.idempotent).toBe(false)
    expect(stopped.bridge.status).toBe("stopped")
    expect(stopped.currentTurn).toBeNull()
    expect(stopped.stoppedMentions.map(mention => mention.state)).toEqual(["failed"])
    expect(store.listBridgeTurns(started.bridge.id)[0].state).toBe("cancelled")
    expectStoreError(
      () => store.completeMention(claim.mention.id, claim.claimToken, "late reply"),
      "mention_not_claimed",
    )
    expect(store.stopBridge(started.bridge.id, owner.id).idempotent).toBe(true)
  })

  test("transient executor failure recovers the same turn while terminal failure ends the bridge", () => {
    const { alice, bob, room } = createRoom()
    const started = store.startBridge({
      roomId: room.id,
      clientRequestId: randomUUID(),
      firstActorId: alice.id,
      secondActorId: bob.id,
      prompt: "Recoverable discussion",
      maxTurns: 3,
    })
    const firstClaim = store.claimMention(started.mention.id, 10)
    now += 10
    const recovered = store.recoverExpiredClaims(now)
    expect(recovered[0].id).toBe(firstClaim.mention.id)
    expect(recovered[0].state).toBe("pending")
    expect(store.getBridgeState(started.bridge.id).bridge.status).toBe("active")
    expect(store.getBridgeState(started.bridge.id).currentTurn?.state).toBe("pending")

    const recoveredClaim = store.claimMention(started.mention.id)
    const advanced = store.completeMention(recoveredClaim.mention.id, recoveredClaim.claimToken, "Recovered")
    expect(advanced.bridgeUpdate?.event).toBe("advanced")
    const nextMention = advanced.mentions[0]
    store.failMention(nextMention.id, "executor route unavailable")
    const failed = store.getBridgeState(started.bridge.id)
    expect(failed.bridge.status).toBe("failed")
    expect(failed.bridge.lastError).toBe("executor route unavailable")
    expect(store.listBridgeTurns(started.bridge.id).at(-1)?.state).toBe("failed")
  })
})

describe("speech modes and free speech", () => {
  test("speech mode defaults to mention_only, persists updates, and rejects unknown values", () => {
    expect(store.getSpeechMode()).toBe("mention_only")
    expect(store.setSpeechMode("relay")).toBe("relay")
    expect(store.getSpeechMode()).toBe("relay")
    store.setSpeechMode("free")
    expect(store.getSpeechMode()).toBe("free")
    expectStoreError(() => store.setSpeechMode("loud" as never), "invalid_speech_mode")
    expect(store.getSpeechMode()).toBe("free")
  })

  test("relay 档：@ 链逐跳递增 depth，到 maxChainDepth 闸住", () => {
    store.setSpeechMode("relay")
    const { room } = createRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "@alice ping", floorId)
    let mention = onlyMention(post)
    expect(mention.depth).toBe(0)
    for (let depth = 1; depth <= AGORA_LIMITS.maxChainDepth; depth += 1) {
      const claim = store.claimMention(mention.id)
      now += 10_000
      const target = depth % 2 === 1 ? "@bob" : "@alice"
      const done = store.completeMention(claim.mention.id, claim.claimToken, `hop ${depth}: ${target} go`)
      expect(done.mentions).toHaveLength(1)
      mention = onlyMention(done)
      expect(mention.depth).toBe(depth)
      expect(mention.kind).toBe("direct")
    }
    const claim = store.claimMention(mention.id)
    now += 10_000
    const target = (AGORA_LIMITS.maxChainDepth + 1) % 2 === 1 ? "@bob" : "@alice"
    const over = store.completeMention(claim.mention.id, claim.claimToken, `over the cap: ${target}`)
    expect(over.mentions).toHaveLength(0)
  })

  test("relay 档：owner 发言抢权——pending 接力作废，claimed 让它说完", () => {
    store.setSpeechMode("relay")
    const { room } = createRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "@alice ping", floorId)
    const aliceClaim = store.claimMention(onlyMention(post).id)
    now += 1
    const done = store.completeMention(aliceClaim.mention.id, aliceClaim.claimToken, "@bob your turn")
    const relayMention = onlyMention(done)
    now += 1
    const second = store.postOwnerMessage(room.id, randomUUID(), "wait, let me think", floorId)
    expect(second.mentions).toHaveLength(0)
    expect(second.supersededMentions?.map(mention => mention.id)).toEqual([relayMention.id])
    expect(store.getMention(relayMention.id)?.state).toBe("failed")
    expect(store.getMention(relayMention.id)?.lastError).toBe("superseded_by_owner")

    const third = store.postOwnerMessage(room.id, randomUUID(), "@alice again", floorId)
    const claim2 = store.claimMention(onlyMention(third).id)
    now += 1
    const done2 = store.completeMention(claim2.mention.id, claim2.claimToken, "@bob take it")
    const relay2 = onlyMention(done2)
    store.claimMention(relay2.id)
    now += 1
    const fourth = store.postOwnerMessage(room.id, randomUUID(), "hold on", floorId)
    expect(fourth.supersededMentions ?? []).toHaveLength(0)
    expect(store.getMention(relay2.id)?.state).toBe("claimed")
  })

  test("free 档：owner 消息 @ 到的是 direct，其余成员收 observe", () => {
    store.setSpeechMode("free")
    const { room, alice, bob } = createRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "@alice look at this", floorId)
    expect(post.mentions).toHaveLength(2)
    const members = store.listMemberships(room.id)
    const aliceMembership = members.find(member => member.actorId === alice.id)
    const bobMembership = members.find(member => member.actorId === bob.id)
    if (!aliceMembership || !bobMembership) throw new Error("Missing membership fixtures")
    const direct = post.mentions.find(mention => mention.targetMembershipId === aliceMembership.id)
    const observe = post.mentions.find(mention => mention.targetMembershipId === bobMembership.id)
    expect(direct?.kind).toBe("direct")
    expect(direct?.depth).toBe(0)
    expect(observe?.kind).toBe("observe")
    expect(observe?.depth).toBe(0)
  })

  test("free 档：无 @ 消息全员 observe；AI 插话给其他成员发新 observe 并顶替旧的", () => {
    store.setSpeechMode("free")
    const { room, alice, bob } = createRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "大家怎么看？", floorId)
    expect(post.mentions).toHaveLength(2)
    expect(post.mentions.every(mention => mention.kind === "observe")).toBe(true)
    const members = store.listMemberships(room.id)
    const aliceMembership = members.find(member => member.actorId === alice.id)
    const bobMembership = members.find(member => member.actorId === bob.id)
    if (!aliceMembership || !bobMembership) throw new Error("Missing membership fixtures")
    const aliceObserve = post.mentions.find(mention => mention.targetMembershipId === aliceMembership.id)
    const bobObserve = post.mentions.find(mention => mention.targetMembershipId === bobMembership.id)
    if (!aliceObserve || !bobObserve) throw new Error("Missing observe fixtures")
    const claim = store.claimMention(aliceObserve.id)
    now += 1
    const done = store.completeMention(claim.mention.id, claim.claimToken, "我觉得可以")
    expect(done.mentions).toHaveLength(1)
    expect(onlyMention(done).targetMembershipId).toBe(bobMembership.id)
    expect(onlyMention(done).kind).toBe("observe")
    expect(onlyMention(done).depth).toBe(1)
    expect(done.supersededMentions?.map(mention => mention.id)).toEqual([bobObserve.id])
    expect(store.getMention(bobObserve.id)?.state).toBe("failed")
    expect(store.getMention(bobObserve.id)?.lastError).toBe("superseded_by_newer_message")
  })

  test("observe 可 pass 沉默：不插消息、幂等；pass 后 complete 重试报错；direct 拒绝 pass", () => {
    store.setSpeechMode("free")
    const { room } = createRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "随便聊聊", floorId)
    const observe = post.mentions[0]
    const claim = store.claimMention(observe.id)
    now += 1
    const passed = store.passMention(claim.mention.id, claim.claimToken)
    expect(passed.idempotent).toBe(false)
    expect(passed.mention.state).toBe("completed")
    expect(passed.mention.resultMessageId).toBeNull()
    expect(store.openRoom(room.id).messages).toHaveLength(1)
    const retried = store.passMention(claim.mention.id, claim.claimToken)
    expect(retried.idempotent).toBe(true)
    expectStoreError(
      () => store.completeMention(claim.mention.id, claim.claimToken, "changed my mind"),
      "mention_not_claimed",
    )
    const directPost = store.postOwnerMessage(room.id, randomUUID(), "@alice 必须答", floorId)
    const directMention = directPost.mentions.find(mention => mention.kind === "direct")
    if (!directMention) throw new Error("Missing direct mention fixture")
    const directClaim = store.claimMention(directMention.id)
    expectStoreError(() => store.passMention(directClaim.mention.id, directClaim.claimToken), "pass_not_allowed")
  })

  test("同 session 排队时 direct 优先于更早的 observe", () => {
    store.setSpeechMode("free")
    const { room, bob } = createRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "@alice hi", floorId)
    const directAlice = post.mentions.find(mention => mention.kind === "direct")
    if (!directAlice) throw new Error("Missing alice direct fixture")
    const aliceClaim = store.claimMention(directAlice.id)
    now += 1
    const done = store.completeMention(aliceClaim.mention.id, aliceClaim.claimToken, "收到")
    expect(onlyMention(done).kind).toBe("observe")
    now += 1
    const roomB = store.createRoom({
      floorId,
      title: "Second room",
      clientRequestId: randomUUID(),
      ownerProfile: { handle: "susu", displayName: "禾禾" },
      members: [{ actorId: bob.id, handle: "bob", displayName: "Bob" }],
    })
    const postB = store.postOwnerMessage(roomB.room.id, randomUUID(), "@bob answer this", floorId)
    const next = store.claimNextMentionForSession("mp-cc-bob")
    expect(next?.mention.kind).toBe("direct")
    expect(next?.mention.id).toBe(onlyMention(postB).id)
    expect(next?.room.id).toBe(roomB.room.id)
  })

  test("openRoom mentionCounts 与 kind 过滤的 listMentions 只算 direct", () => {
    store.setSpeechMode("free")
    const { room } = createRoom()
    store.postOwnerMessage(room.id, randomUUID(), "@alice 一个任务", floorId)
    const counts = store.openRoom(room.id).mentionCounts
    expect(counts.pending).toBe(1)
    expect(store.listMentions(room.id, undefined, 100, "direct")).toHaveLength(1)
    expect(store.listMentions(room.id)).toHaveLength(2)
  })
})

describe("min speak interval", () => {
  test("间隔设置默认 0、持久化，拒绝负数/非整数", () => {
    expect(store.getMinSpeakIntervalMs()).toBe(0)
    expect(store.setMinSpeakIntervalMs(5_000)).toBe(5_000)
    expect(store.getMinSpeakIntervalMs()).toBe(5_000)
    expectStoreError(() => store.setMinSpeakIntervalMs(-1), "invalid_min_speak_interval")
    expectStoreError(() => store.setMinSpeakIntervalMs(1.5), "invalid_min_speak_interval")
    expect(store.getMinSpeakIntervalMs()).toBe(5_000)
  })

  test("lastAIMessageAtMs 只认 AI 消息；被闸房间 claim 排除 observe，owner 直接 @ 豁免", () => {
    store.setSpeechMode("free")
    const { room } = createRoom()
    store.postOwnerMessage(room.id, randomUUID(), "开场", floorId)
    expect(store.lastAIMessageAtMs(room.id)).toBeNull()

    const aliceClaim = store.claimNextMentionForSession("mp-cc-alice")
    if (!aliceClaim) throw new Error("Missing alice claim fixture")
    now += 5
    store.completeMention(aliceClaim.mention.id, aliceClaim.claimToken, "我先说")
    expect(store.lastAIMessageAtMs(room.id)).toBe(now)

    // bob 手里只剩 alice 插话顶替出的 observe → 被闸房间里 claim 不到
    expect(store.claimNextMentionForSession("mp-cc-bob", AGORA_LIMITS.claimLeaseMs, [room.id])).toBeNull()

    now += 5
    const urgent = store.postOwnerMessage(room.id, randomUUID(), "@bob 你直接说", floorId)
    const direct = onlyMention(urgent)
    expect(direct.kind).toBe("direct")
    const gatedClaim = store.claimNextMentionForSession("mp-cc-bob", AGORA_LIMITS.claimLeaseMs, [room.id])
    expect(gatedClaim?.mention.id).toBe(direct.id)
    if (!gatedClaim) throw new Error("Missing gated claim fixture")

    // bob 接力 @alice → depth 1 direct：被闸房间同样排除，不闸可正常领取
    now += 5
    const relayed = store.completeMention(gatedClaim.mention.id, gatedClaim.claimToken, "@alice 你接着说")
    const relay = relayed.mentions.find(mention => mention.kind === "direct")
    if (!relay) throw new Error("Missing relay direct fixture")
    expect(relay.depth).toBe(1)
    expect(store.claimNextMentionForSession("mp-cc-alice", AGORA_LIMITS.claimLeaseMs, [room.id])).toBeNull()
    expect(store.claimNextMentionForSession("mp-cc-alice")?.mention.id).toBe(relay.id)
  })
})

describe("round_robin 回合制", () => {
  function createTrioRoom() {
    const owner = store.upsertOwnerActor()
    const alice = store.upsertCCActor("mp-cc-alice")
    const bob = store.upsertCCActor("mp-cc-bob")
    const carol = store.upsertCCActor("mp-cc-carol")
    const snapshot = store.createRoom({
      floorId,
      title: "Round robin",
      clientRequestId: randomUUID(),
      ownerProfile: { handle: "Susu", displayName: "禾禾" },
      members: [
        { actorId: alice.id, handle: "Alice", displayName: "Alice" },
        { actorId: bob.id, handle: "bob", displayName: "Bob" },
        { actorId: carol.id, handle: "carol", displayName: "Carol" },
      ],
    })
    // 期望轮转顺序 = 快照口径（joined_at_ms, membership id；同毫秒建房退化为 id 序）
    const roster = snapshot.memberships
      .filter(member => member.role === "member")
      .sort((a, b) => a.joinedAtMs - b.joinedAtMs || (a.id < b.id ? -1 : 1))
    return { owner, room: snapshot.room, roster }
  }

  function answerTurn(mentionId: string, content: string) {
    const claim = store.claimMention(mentionId)
    now += 1_000
    return store.completeMention(claim.mention.id, claim.claimToken, content)
  }

  test("三成员圈：owner 只点 order[0]，逐个完成轮转，@ 不接力，圈满静默", () => {
    expect(store.setSpeechMode("round_robin")).toBe("round_robin")
    expect(store.getSpeechMode()).toBe("round_robin")
    const { room, roster } = createTrioRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "大家轮流说", floorId)
    expect(post.mentions).toHaveLength(1)
    const first = onlyMention(post)
    expect(first.kind).toBe("direct")
    expect(first.depth).toBe(0)
    expect(first.targetMembershipId).toBe(roster[0].id)

    const second = answerTurn(first.id, "第一位说完")
    expect(second.mentions).toHaveLength(1)
    expect(onlyMention(second).targetMembershipId).toBe(roster[1].id)
    expect(onlyMention(second).kind).toBe("direct")
    expect(onlyMention(second).depth).toBe(0)

    // @ 其他 AI 不生成链式 direct，也没有 observe，只按圈推进
    const third = answerTurn(onlyMention(second).id, "第二位说完 @Alice 你说呢")
    expect(third.mentions).toHaveLength(1)
    expect(onlyMention(third).targetMembershipId).toBe(roster[2].id)

    const done = answerTurn(onlyMention(third).id, "第三位说完")
    expect(done.mentions).toHaveLength(0)
    expect(store.listMentions(room.id, "pending")).toHaveLength(0)
  })

  test("中途 pass 跳到下一位：轮次 direct 可 pass、不产生消息、幂等重试不重复推进", () => {
    store.setSpeechMode("round_robin")
    const { room, roster } = createTrioRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "轮流来", floorId)
    const claim = store.claimMention(onlyMention(post).id)
    now += 1_000
    const passed = store.passMention(claim.mention.id, claim.claimToken)
    expect(passed.idempotent).toBe(false)
    expect(passed.mention.resultMessageId).toBeNull()
    expect(passed.mentions).toHaveLength(1)
    const next = passed.mentions?.[0]
    expect(next?.targetMembershipId).toBe(roster[1].id)
    expect(next?.kind).toBe("direct")
    expect(next?.sourceMessageId).toBe(post.message.id)
    expect(store.openRoom(room.id).messages).toHaveLength(1)
    const retry = store.passMention(claim.mention.id, claim.claimToken)
    expect(retry.idempotent).toBe(true)
    expect(store.listMentions(room.id, "pending")).toHaveLength(1)
  })

  test("owner 中途插话重开新圈：旧轮次作废，order 重新快照 cursor 归零", () => {
    store.setSpeechMode("round_robin")
    const { room, roster } = createTrioRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "第一圈", floorId)
    const firstTurn = answerTurn(onlyMention(post).id, "第一位答完")
    const staleMention = onlyMention(firstTurn)
    now += 1_000
    const interject = store.postOwnerMessage(room.id, randomUUID(), "等等我补一句", floorId)
    expect(interject.supersededMentions?.map(mention => mention.id)).toContain(staleMention.id)
    expect(store.getMention(staleMention.id)?.state).toBe("failed")
    expect(store.getMention(staleMention.id)?.lastError).toBe("superseded_by_owner")
    expect(interject.mentions).toHaveLength(1)
    expect(onlyMention(interject).targetMembershipId).toBe(roster[0].id)
    const roundTwo = answerTurn(onlyMention(interject).id, "新圈第一位")
    expect(onlyMention(roundTwo).targetMembershipId).toBe(roster[1].id)
  })

  test("free/relay 行为不受 round_robin 影响", () => {
    store.setSpeechMode("free")
    const { room } = createTrioRoom()
    const post = store.postOwnerMessage(room.id, randomUUID(), "自由发言", floorId)
    expect(post.mentions).toHaveLength(3)
    expect(post.mentions.every(mention => mention.kind === "observe")).toBe(true)
    store.setSpeechMode("relay")
    now += 1_000
    const relayPost = store.postOwnerMessage(room.id, randomUUID(), "@Alice 你说", floorId)
    expect(relayPost.mentions).toHaveLength(1)
    expect(onlyMention(relayPost).kind).toBe("direct")
    const claim = store.claimMention(onlyMention(relayPost).id)
    now += 1_000
    const relayed = store.completeMention(claim.mention.id, claim.claimToken, "@bob 接力")
    expect(relayed.mentions).toHaveLength(1)
    expect(onlyMention(relayed).depth).toBe(1)
  })
})
