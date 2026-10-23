import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { randomUUID } from "node:crypto"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { AgoraStore } from "./agora-store.ts"
import { AGORA_LIMITS, AgoraStoreError, type AgoraActor } from "./agora-types.ts"

let secretsDir = ""
let store: AgoraStore
let owner: AgoraActor
let alice: AgoraActor
let bob: AgoraActor
let roomId = ""

function expectCode(action: () => void, code: string): void {
  try {
    action()
    throw new Error(`Expected ${code}`)
  } catch (error) {
    expect(error).toBeInstanceOf(AgoraStoreError)
    expect((error as AgoraStoreError).code).toBe(code)
  }
}

function start(maxTurns: number) {
  return store.startBridge({
    roomId,
    clientRequestId: randomUUID(),
    firstActorId: alice.id,
    secondActorId: bob.id,
    prompt: "Discuss the safest migration plan.",
    maxTurns,
  })
}

beforeEach(() => {
  secretsDir = mkdtempSync(join(tmpdir(), "agora-bridge-test-"))
  store = AgoraStore.open({ secretsDir })
  owner = store.upsertOwnerActor()
  alice = store.upsertCCActor("alice")
  bob = store.upsertCCActor("bob")
  roomId = store.createRoom({
    floorId: randomUUID(),
    title: "Bridge Room",
    clientRequestId: randomUUID(),
    ownerProfile: { handle: "susu", displayName: "Susu" },
    members: [
      { actorId: alice.id, handle: "alice", displayName: "Alice" },
      { actorId: bob.id, handle: "bob", displayName: "Bob" },
    ],
  }).room.id
})

afterEach(() => {
  store.close()
  rmSync(secretsDir, { recursive: true, force: true })
})

describe("Agora bridge turn progression", () => {
  test("alternates the expected actor and completes exactly at max turns", () => {
    const started = start(3)
    expect(started.bridge.status).toBe("active")
    expect(started.currentTurn?.expectedActorId).toBe(alice.id)
    expect(started.message.content).toStartWith("@alice ")

    const firstClaim = store.claimMention(started.mention.id)
    const first = store.completeMention(firstClaim.mention.id, firstClaim.claimToken, "Alice reply")
    expect(first.bridgeUpdate?.event).toBe("advanced")
    expect(first.bridgeUpdate?.currentTurn?.turnIndex).toBe(1)
    expect(first.bridgeUpdate?.currentTurn?.expectedActorId).toBe(bob.id)
    expect(first.mentions).toHaveLength(1)

    const secondClaim = store.claimMention(first.mentions[0].id)
    const second = store.completeMention(secondClaim.mention.id, secondClaim.claimToken, "Bob reply")
    expect(second.bridgeUpdate?.currentTurn?.expectedActorId).toBe(alice.id)

    const thirdClaim = store.claimMention(second.mentions[0].id)
    const third = store.completeMention(thirdClaim.mention.id, thirdClaim.claimToken, "Alice conclusion")
    expect(third.bridgeUpdate?.event).toBe("completed")
    expect(third.mentions).toEqual([])
    expect(third.bridgeUpdate?.bridge).toMatchObject({
      status: "completed",
      turnsCompleted: 3,
      stopReason: "max_turns_reached",
    })
    expect(store.listBridgeTurns(started.bridge.id).map(turn => turn.state)).toEqual([
      "completed",
      "completed",
      "completed",
    ])
  })

  test("enforces participant and active-bridge invariants", () => {
    start(2)
    expectCode(() => start(2), "bridge_already_active")
    expectCode(() => store.startBridge({
      roomId,
      clientRequestId: randomUUID(),
      firstActorId: alice.id,
      secondActorId: alice.id,
      prompt: "invalid",
      maxTurns: 2,
    }), "bridge_actor_invalid")
    expectCode(() => store.startBridge({
      roomId,
      clientRequestId: randomUUID(),
      firstActorId: alice.id,
      secondActorId: bob.id,
      prompt: "invalid",
      maxTurns: AGORA_LIMITS.maxBridgeTurns + 1,
    }), "invalid_limit")
  })
})

describe("Agora bridge terminal behavior", () => {
  test("stop cancels the active turn and rejects a late claimed reply", () => {
    const started = start(5)
    const claim = store.claimMention(started.mention.id)
    const stopped = store.stopBridge(started.bridge.id, owner.id)
    expect(stopped.bridge.status).toBe("stopped")
    expect(stopped.bridge.stopReason).toBe("user_stopped")
    expect(stopped.stoppedMentions[0].state).toBe("failed")
    expect(store.listBridgeTurns(started.bridge.id)[0].state).toBe("cancelled")
    expectCode(
      () => store.completeMention(claim.mention.id, claim.claimToken, "too late"),
      "mention_not_claimed",
    )
    expect(store.stopBridge(started.bridge.id, owner.id).idempotent).toBe(true)
  })

  test("transient executor failures return the turn to pending and terminal failure closes the bridge", () => {
    const started = start(5)
    let mentionId = started.mention.id
    for (let attempt = 0; attempt <= AGORA_LIMITS.maxMentionAttempts; attempt += 1) {
      const claim = store.claimMention(mentionId)
      const mention = store.releaseClaimAfterFailure(mentionId, claim.claimToken, `provider failure ${attempt}`)
      const state = store.getBridgeState(started.bridge.id)
      if (attempt < AGORA_LIMITS.maxMentionAttempts) {
        expect(mention.state).toBe("pending")
        expect(state.bridge.status).toBe("active")
        expect(state.currentTurn?.state).toBe("pending")
      } else {
        expect(mention.state).toBe("failed")
        expect(state.bridge.status).toBe("failed")
        expect(state.bridge.stopReason).toBe("executor_failure")
        expect(store.listBridgeTurns(started.bridge.id)[0].state).toBe("failed")
      }
      mentionId = mention.id
    }
  })
})
