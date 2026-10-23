import { afterEach, beforeEach, expect, test } from "bun:test"
import { randomUUID } from "node:crypto"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  AGORA_CONTEXT_MESSAGE_LIMIT,
  AGORA_CONTEXT_TRANSCRIPT_CHARACTER_LIMIT,
  AGORA_OBSERVE_CONTEXT_MESSAGE_LIMIT,
  AGORA_OBSERVE_TRANSCRIPT_CHARACTER_LIMIT,
  AgoraCCExecutor,
} from "./agora-cc-executor.ts"
import { AgoraPresenceStore, EXECUTOR_TYPING_TTL_MS } from "./agora-presence.ts"
import { AgoraStore } from "./agora-store.ts"
import { AgoraStoreError, type AgoraMessageWriteResult } from "./agora-types.ts"

interface SentPrompt {
  sessionName: string
  prompt: string
}

function sessionManager(sent: SentPrompt[], available = ["mp-cc-executor-alice", "mp-cc-executor-bob"]) {
  return {
    listSessions: () => available,
    ensureSessionAndSend: (sessionName: string, prompt: string) => sent.push({ sessionName, prompt }),
  }
}

interface ClaimPayload {
  room_id: string
  mention_id: string
  claim_token: string
  lease_expires_at_ms: number
}

interface ContextPayload {
  room: { id: string; title: string }
  members: Array<{ handle: string }>
  messages: Array<{ seq: number; content: string }>
}

let secretsDir = ""
let store: AgoraStore
let now = 1_720_000_000_000
let floorId = ""

function onlyMention(result: AgoraMessageWriteResult) {
  const mention = result.mentions[0]
  if (!mention) throw new Error("Expected one mention")
  return mention
}

function createRoom() {
  store.upsertOwnerActor()
  const alice = store.upsertCCActor("mp-cc-executor-alice")
  const bob = store.upsertCCActor("mp-cc-executor-bob")
  return store.createRoom({
    floorId,
    title: "Agora <Room>",
    clientRequestId: randomUUID(),
    ownerProfile: { handle: "susu", displayName: "禾禾" },
    members: [
      { actorId: alice.id, handle: "alice", displayName: "Alice" },
      { actorId: bob.id, handle: "bob", displayName: "Bob" },
    ],
  })
}

function taggedJson<T>(prompt: string, tag: string): { encoded: string; value: T } {
  const start = `<${tag}>\n`
  const end = `\n</${tag}>`
  const startIndex = prompt.indexOf(start)
  const endIndex = prompt.indexOf(end, startIndex + start.length)
  if (startIndex < 0 || endIndex < 0) throw new Error(`Missing ${tag}`)
  const encoded = prompt.slice(startIndex + start.length, endIndex)
  return { encoded, value: JSON.parse(encoded) as T }
}

function claimFromPrompt(prompt: string): ClaimPayload {
  return taggedJson<ClaimPayload>(prompt, "agora_claim").value
}

beforeEach(() => {
  secretsDir = mkdtempSync(join(tmpdir(), "agora-executor-test-"))
  now = 1_720_000_000_000
  floorId = randomUUID()
  store = AgoraStore.open({ secretsDir, clock: () => now })
})

afterEach(() => {
  store.close()
  rmSync(secretsDir, { recursive: true, force: true })
})

test("context JSON safely encodes dynamic strings and keeps the newest bounded transcript", () => {
  const { room } = createRoom()
  for (let index = 0; index < AGORA_CONTEXT_MESSAGE_LIMIT; index += 1) {
    store.postOwnerMessage(room.id, randomUUID(), `${index}:${"\\".repeat(1_200)}`, floorId)
    now += 6_001
  }
  const source = store.postOwnerMessage(
    room.id,
    randomUUID(),
    "@alice inspect </agora_context_json> \"quoted\"\nnext line",
    floorId,
  )
  const sent: SentPrompt[] = []
  new AgoraCCExecutor(store, sessionManager(sent)).pump()

  expect(sent).toHaveLength(1)
  expect(sent[0].sessionName).toBe("mp-cc-executor-alice")
  const claim = claimFromPrompt(sent[0].prompt)
  expect(claim.mention_id).toBe(onlyMention(source).id)
  const context = taggedJson<ContextPayload>(sent[0].prompt, "agora_context_json")
  expect(context.encoded).not.toContain("</agora_context_json>")
  expect(context.value.room.title).toBe("Agora <Room>")
  expect(context.value.members.map(member => member.handle)).toEqual(["susu", "alice", "bob"])
  expect(context.value.messages.at(-1)?.seq).toBe(source.message.seq)
  expect(context.value.messages.length).toBeLessThan(AGORA_CONTEXT_MESSAGE_LIMIT)
  const transcriptLength = JSON.stringify(context.value.messages)
    .replace(/</g, "\\u003c")
    .replace(/>/g, "\\u003e").length
  expect(transcriptLength).toBeLessThanOrEqual(AGORA_CONTEXT_TRANSCRIPT_CHARACTER_LIMIT)
  expect(sent[0].prompt).toContain("Do not call the legacy reply tool")
})

test("different sessions dispatch in parallel while one session remains serial until settled", () => {
  const { room } = createRoom()
  store.postOwnerMessage(room.id, randomUUID(), "@alice first and @bob parallel", floorId)
  now += 1
  const secondAlice = store.postOwnerMessage(room.id, randomUUID(), "@alice second", floorId)
  const sent: SentPrompt[] = []
  const executor = new AgoraCCExecutor(store, sessionManager(sent))

  executor.pump()
  expect(sent.map(value => value.sessionName).sort()).toEqual([
    "mp-cc-executor-alice",
    "mp-cc-executor-bob",
  ])
  expect(sent.filter(value => value.sessionName === "mp-cc-executor-alice")).toHaveLength(1)

  const firstAlicePrompt = sent.find(value => value.sessionName === "mp-cc-executor-alice")
  if (!firstAlicePrompt) throw new Error("Missing first Alice dispatch")
  const firstAliceClaim = claimFromPrompt(firstAlicePrompt.prompt)
  store.completeMention(firstAliceClaim.mention_id, firstAliceClaim.claim_token, "first done")
  executor.onMentionSettled(firstAliceClaim.mention_id)

  const alicePrompts = sent.filter(value => value.sessionName === "mp-cc-executor-alice")
  expect(alicePrompts).toHaveLength(2)
  expect(claimFromPrompt(alicePrompts[1].prompt).mention_id).toBe(onlyMention(secondAlice).id)
  expect(sent.filter(value => value.sessionName === "mp-cc-executor-bob")).toHaveLength(1)
})

test("restart recovery rejects the stale token and re-dispatches after the lease", () => {
  const { room } = createRoom()
  const source = store.postOwnerMessage(room.id, randomUUID(), "@alice recover", floorId)
  const firstSent: SentPrompt[] = []
  new AgoraCCExecutor(
    store,
    sessionManager(firstSent),
    { leaseMs: 10 },
  ).pump()
  const firstClaim = claimFromPrompt(firstSent[0].prompt)

  now += 10
  const restartedSent: SentPrompt[] = []
  const restarted = new AgoraCCExecutor(
    store,
    sessionManager(restartedSent),
    { leaseMs: 10 },
  )
  restarted.recoverExpiredClaims(now)

  expect(restartedSent).toHaveLength(1)
  const secondClaim = claimFromPrompt(restartedSent[0].prompt)
  expect(secondClaim.mention_id).toBe(onlyMention(source).id)
  expect(secondClaim.claim_token).not.toBe(firstClaim.claim_token)
  try {
    store.completeMention(firstClaim.mention_id, firstClaim.claim_token, "stale")
    throw new Error("Expected stale claim rejection")
  } catch (error) {
    expect(error).toBeInstanceOf(AgoraStoreError)
    expect((error as AgoraStoreError).code).toBe("claim_token_invalid")
  }
  expect(store.openRoom(room.id).messages).toHaveLength(1)
})

test("discovers actors only from live hub sessions and rejects placeholder registration", () => {
  const sent: SentPrompt[] = []
  const executor = new AgoraCCExecutor(
    store,
    sessionManager(sent, ["mp-cc-live", "bad session", "mp-cc-live"]),
  )

  expect(executor.listAvailableActors().map(actor => actor.externalKey)).toEqual(["cc-session:mp-cc-live"])
  expect(executor.upsertAvailableActor("mp-cc-live").externalKey).toBe("cc-session:mp-cc-live")
  expect(() => executor.upsertAvailableActor("mp-cc-placeholder")).toThrow("CC session is not available")
})

test("known room session is restarted through session manager when no tmux session is currently live", () => {
  const { room } = createRoom()
  store.postOwnerMessage(room.id, randomUUID(), "@alice restart", floorId)
  const sent: SentPrompt[] = []
  const executor = new AgoraCCExecutor(store, sessionManager(sent, []))

  executor.pump()

  expect(sent.map(value => value.sessionName)).toEqual(["mp-cc-executor-alice"])
})

test("executor publishes agent typing while a claimed mention is composing", () => {
  const { room } = createRoom()
  store.postOwnerMessage(room.id, randomUUID(), "@alice compose", floorId)
  const sent: SentPrompt[] = []
  const typing: Array<{ roomId: string; actorId: string; sourceId: string; isTyping: boolean }> = []
  const executor = new AgoraCCExecutor(store, sessionManager(sent), {
    onTypingChange: (roomId, actorId, sourceId, isTyping) => {
      typing.push({ roomId, actorId, sourceId, isTyping })
    },
  })

  executor.pump()
  const claim = claimFromPrompt(sent[0].prompt)
  expect(typing).toHaveLength(1)
  expect(typing[0]).toMatchObject({ roomId: room.id, sourceId: claim.mention_id, isTyping: true })

  store.completeMention(claim.mention_id, claim.claim_token, "done")
  executor.onMentionSettled(claim.mention_id)
  expect(typing.map(value => value.isTyping)).toEqual([true, false])
})

test("observe claims stay dark: no typing on claim or renewal, no stop broadcast after pass", () => {
  store.setSpeechMode("free")
  const { room } = createRoom()
  store.postOwnerMessage(room.id, randomUUID(), "@alice 你来说说", floorId)
  const sent: SentPrompt[] = []
  // 复刻 hub 接线（publishTyping = presence.setTyping + changed 才广播），断言到广播层
  const presence = new AgoraPresenceStore(store, () => now)
  const raw: Array<{ sourceId: string; isTyping: boolean }> = []
  const broadcasts: string[] = []
  const executor = new AgoraCCExecutor(store, sessionManager(sent), {
    onTypingChange: (roomId, actorId, sourceId, isTyping) => {
      raw.push({ sourceId, isTyping })
      if (presence.setTyping(roomId, actorId, sourceId, isTyping, EXECUTOR_TYPING_TTL_MS).changed) {
        broadcasts.push(isTyping ? `start:${actorId}` : `stop:${actorId}`)
      }
    },
  })

  executor.pump()
  expect(sent).toHaveLength(2)
  const direct = claimFromPrompt(sent.find(entry => entry.sessionName === "mp-cc-executor-alice")?.prompt ?? "")
  const observe = claimFromPrompt(sent.find(entry => entry.sessionName === "mp-cc-executor-bob")?.prompt ?? "")
  // direct 亮灯一次，observe 不亮
  expect(raw).toEqual([{ sourceId: direct.mention_id, isTyping: true }])

  executor.pump()   // 续命轮：只续 direct，observe 依旧无 typing=true
  expect(raw.filter(entry => entry.isTyping && entry.sourceId === observe.mention_id)).toHaveLength(0)

  store.passMention(observe.mention_id, observe.claim_token)
  executor.onMentionSettled(observe.mention_id)
  // teardown 的 false 对没亮过灯的 observe 是 no-op：广播层只有 direct 的 start，无任何 stop
  const aliceActorId = store.upsertCCActor("mp-cc-executor-alice").id
  expect(broadcasts).toEqual([`start:${aliceActorId}`])
})

test("protected sessions are never injected — the mention fails visibly", () => {
  const { room } = createRoom()
  const post = store.postOwnerMessage(room.id, randomUUID(), "@alice hello", floorId)
  const sent: SentPrompt[] = []
  const executor = new AgoraCCExecutor(store, {
    ...sessionManager(sent),
    isSessionDispatchable: () => false,
  })
  executor.pump()
  expect(sent).toHaveLength(0)
  expect(store.getMention(onlyMention(post).id)?.state).toBe("failed")
})

test("pump swallows store poison instead of throwing into the hub", () => {
  const sent: SentPrompt[] = []
  const executor = new AgoraCCExecutor(store, sessionManager(sent))
  ;(store as unknown as { listPendingMentions: () => never }).listPendingMentions = () => {
    throw new Error("poison row")
  }
  expect(() => executor.pump()).not.toThrow()
  expect(sent).toHaveLength(0)
})

test("async delivery rejection releases the claim for lease retry", async () => {
  const { room } = createRoom()
  const post = store.postOwnerMessage(room.id, randomUUID(), "@alice hello", floorId)
  const executor = new AgoraCCExecutor(store, {
    listSessions: () => ["mp-cc-executor-alice"],
    ensureSessionAndSend: () => Promise.reject(new Error("tmux gone")),
  })
  executor.pump()
  await new Promise(resolve => setTimeout(resolve, 0))   // 冲 deliverClaim 的 microtask
  const mention = store.getMention(onlyMention(post).id)
  expect(mention?.state).toBe("pending")   // release 后回 pending 等重试
})

test("codex sessions are dispatchable actors (二期入场)", () => {
  const { room } = createRoom()
  store.upsertCCActor("mp-codex-1")
  // 白名单语义在 hub 注入层——这里验证 executor 对 codex externalKey 的路由解析不报错
  const sent: SentPrompt[] = []
  const executor = new AgoraCCExecutor(store, {
    listSessions: () => ["mp-cc-executor-alice", "mp-codex-1"],
    ensureSessionAndSend: (s, p) => sent.push({ sessionName: s, prompt: p }),
  })
  const actors = executor.listAvailableActors()
  expect(actors.some(a => a.externalKey === "cc-session:mp-codex-1")).toBe(true)
})

test("observe claim prompt offers pass and relay mode advertises @dispatch", () => {
  store.setSpeechMode("free")
  const { room } = createRoom()
  store.postOwnerMessage(room.id, randomUUID(), "@alice 你来说说", floorId)
  const sent: SentPrompt[] = []
  new AgoraCCExecutor(store, sessionManager(sent)).pump()
  expect(sent).toHaveLength(2)
  const alicePrompt = sent.find(entry => entry.sessionName === "mp-cc-executor-alice")?.prompt ?? ""
  const bobPrompt = sent.find(entry => entry.sessionName === "mp-cc-executor-bob")?.prompt ?? ""
  // direct（alice）：必答文案，无 pass
  expect(alicePrompt).toContain("You have a durable mention")
  expect(alicePrompt).not.toContain("pass: true")
  // observe（bob）：旁听文案 + 可 pass
  expect(bobPrompt).toContain("you are listening")
  expect(bobPrompt).toContain("pass: true")
  expect(taggedJson<{ kind: string }>(bobPrompt, "agora_claim").value.kind).toBe("observe")
  // 非 mention_only 档都告知 @ 会派发
  expect(alicePrompt).toContain("dispatches them to respond")
  expect(bobPrompt).toContain("dispatches them to respond")
})

test("observe claim context 只带最近 20 条，同房间 direct 不受影响", () => {
  const { room } = createRoom()
  for (let index = 0; index < 25; index += 1) {
    store.postOwnerMessage(room.id, randomUUID(), `filler ${index}`, floorId)
    now += 6_001
  }
  store.setSpeechMode("free")
  const source = store.postOwnerMessage(room.id, randomUUID(), "@alice 收个尾", floorId)
  const sent: SentPrompt[] = []
  new AgoraCCExecutor(store, sessionManager(sent)).pump()

  expect(sent).toHaveLength(2)
  const bobPrompt = sent.find(entry => entry.sessionName === "mp-cc-executor-bob")?.prompt ?? ""
  const alicePrompt = sent.find(entry => entry.sessionName === "mp-cc-executor-alice")?.prompt ?? ""
  const bobContext = taggedJson<ContextPayload>(bobPrompt, "agora_context_json").value
  expect(bobContext.messages).toHaveLength(AGORA_OBSERVE_CONTEXT_MESSAGE_LIMIT)
  expect(bobContext.messages.at(-1)?.seq).toBe(source.message.seq)
  const aliceContext = taggedJson<ContextPayload>(alicePrompt, "agora_context_json").value
  expect(aliceContext.messages.length).toBeGreaterThan(AGORA_OBSERVE_CONTEXT_MESSAGE_LIMIT)
  expect(aliceContext.messages.at(-1)?.seq).toBe(source.message.seq)
})

test("observe claim transcript 走 10k 字符 cap，direct 仍用 40k", () => {
  const { room } = createRoom()
  for (let index = 0; index < 8; index += 1) {
    store.postOwnerMessage(room.id, randomUUID(), `${index}:${"\\".repeat(1_200)}`, floorId)
    now += 6_001
  }
  store.setSpeechMode("free")
  const source = store.postOwnerMessage(room.id, randomUUID(), "@alice 看看", floorId)
  const sent: SentPrompt[] = []
  new AgoraCCExecutor(store, sessionManager(sent)).pump()

  expect(sent).toHaveLength(2)
  const measure = (messages: ContextPayload["messages"]) => JSON.stringify(messages)
    .replace(/</g, "\\u003c")
    .replace(/>/g, "\\u003e").length
  const bobPrompt = sent.find(entry => entry.sessionName === "mp-cc-executor-bob")?.prompt ?? ""
  const alicePrompt = sent.find(entry => entry.sessionName === "mp-cc-executor-alice")?.prompt ?? ""
  const bobMessages = taggedJson<ContextPayload>(bobPrompt, "agora_context_json").value.messages
  expect(measure(bobMessages)).toBeLessThanOrEqual(AGORA_OBSERVE_TRANSCRIPT_CHARACTER_LIMIT)
  expect(bobMessages.at(-1)?.seq).toBe(source.message.seq)
  const aliceMessages = taggedJson<ContextPayload>(alicePrompt, "agora_context_json").value.messages
  expect(measure(aliceMessages)).toBeGreaterThan(AGORA_OBSERVE_TRANSCRIPT_CHARACTER_LIMIT)
  expect(measure(aliceMessages)).toBeLessThanOrEqual(AGORA_CONTEXT_TRANSCRIPT_CHARACTER_LIMIT)
})

test("mention_only claim prompt does not advertise @dispatch", () => {
  const { room } = createRoom()
  store.postOwnerMessage(room.id, randomUUID(), "@alice 只有你", floorId)
  const sent: SentPrompt[] = []
  new AgoraCCExecutor(store, sessionManager(sent)).pump()
  expect(sent).toHaveLength(1)
  expect(sent[0].prompt).not.toContain("dispatches them to respond")
})

function createSoloRoom() {
  store.upsertOwnerActor()
  const alice = store.upsertCCActor("mp-cc-executor-alice")
  return store.createRoom({
    floorId,
    title: "Solo",
    clientRequestId: randomUUID(),
    ownerProfile: { handle: "susu", displayName: "禾禾" },
    members: [{ actorId: alice.id, handle: "alice", displayName: "Alice" }],
  })
}

test("发言闸：间隔内 observe 不派发，owner 直接 @ 豁免", () => {
  store.setSpeechMode("free")
  store.setMinSpeakIntervalMs(60_000)
  const { room } = createSoloRoom()
  const sent: SentPrompt[] = []
  const executor = new AgoraCCExecutor(store, sessionManager(sent))
  store.postOwnerMessage(room.id, randomUUID(), "@alice hi", floorId)
  executor.pump()
  expect(sent).toHaveLength(1)
  const claim = claimFromPrompt(sent[0].prompt)
  now += 1
  store.completeMention(claim.mention_id, claim.claim_token, "收到")   // AI 消息落库，闸门起表
  executor.onMentionSettled(claim.mention_id)

  now += 1
  const chat = store.postOwnerMessage(room.id, randomUUID(), "接着聊", floorId)
  const observe = onlyMention(chat)
  expect(observe.kind).toBe("observe")
  executor.pump()
  expect(sent).toHaveLength(1)   // 间隔内 observe 被闸，不派发
  expect(store.getMention(observe.id)?.state).toBe("pending")

  now += 1
  const urgent = store.postOwnerMessage(room.id, randomUUID(), "@alice 快说", floorId)
  executor.pump()
  expect(sent).toHaveLength(2)   // owner 直接 @（depth 0 direct）不受闸
  expect(claimFromPrompt(sent[1].prompt).mention_id).toBe(onlyMention(urgent).id)
})

test("发言闸：间隔内接力深链（depth>0 direct）不派发，解禁后放行", () => {
  store.setSpeechMode("relay")
  store.setMinSpeakIntervalMs(60_000)
  const { room } = createRoom()
  const sent: SentPrompt[] = []
  const executor = new AgoraCCExecutor(store, sessionManager(sent))
  store.postOwnerMessage(room.id, randomUUID(), "@bob 先说", floorId)
  executor.pump()
  expect(sent).toHaveLength(1)
  expect(sent[0].sessionName).toBe("mp-cc-executor-bob")
  const claim = claimFromPrompt(sent[0].prompt)
  now += 1
  const relayed = store.completeMention(claim.mention_id, claim.claim_token, "@alice 你接着说")   // AI 消息落库，闸门起表
  executor.onMentionSettled(claim.mention_id)
  const relay = relayed.mentions.find(mention => mention.kind === "direct")
  if (!relay) throw new Error("Missing relay direct fixture")
  expect(relay.depth).toBe(1)

  now += 1
  executor.pump()
  expect(sent).toHaveLength(1)   // 间隔内接力深链被闸，不派发
  expect(store.getMention(relay.id)?.state).toBe("pending")

  now += 60_001
  executor.pump()
  expect(sent).toHaveLength(2)   // 解禁后放行
  expect(sent[1].sessionName).toBe("mp-cc-executor-alice")
  expect(claimFromPrompt(sent[1].prompt).mention_id).toBe(relay.id)
})

test("解禁后 deferred pump 自动放行被闸 observe", async () => {
  store.setSpeechMode("free")
  store.setMinSpeakIntervalMs(150)
  const { room } = createSoloRoom()
  const sent: SentPrompt[] = []
  const executor = new AgoraCCExecutor(store, sessionManager(sent))
  store.postOwnerMessage(room.id, randomUUID(), "@alice hi", floorId)
  executor.pump()
  const claim = claimFromPrompt(sent[0].prompt)
  now += 1
  store.completeMention(claim.mention_id, claim.claim_token, "收到")
  executor.onMentionSettled(claim.mention_id)

  now += 10
  const chat = store.postOwnerMessage(room.id, randomUUID(), "接着聊", floorId)
  const observe = onlyMention(chat)
  executor.pump()
  expect(sent).toHaveLength(1)   // 被闸，等 deferred re-pump

  now += 300   // 假时钟越过解禁点；真实 ~140ms 后 timer 自动重跑 pump
  await new Promise(resolve => setTimeout(resolve, 250))
  expect(sent).toHaveLength(2)
  expect(sent[1].sessionName).toBe("mp-cc-executor-alice")
  expect(claimFromPrompt(sent[1].prompt).mention_id).toBe(observe.id)
})
