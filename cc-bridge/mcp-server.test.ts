import { test, expect, beforeAll, afterAll } from "bun:test"
import { WebSocket, type RawData } from "ws"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { randomUUID } from "node:crypto"
import { Database } from "bun:sqlite"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"
import { AgoraStore } from "./agora-store.ts"

// 隔离（2026-06-11 /clear 事故）：随机高位端口，绝不绑/连生产 7890。
const TEST_PORT = 18890 + Math.floor(Math.random() * 1000)
// secrets 也隔离：否则 hub 加载生产 reply-log 回放旧帧（首帧断言挂）+ 测试 reply 反向污染生产 log
const TEST_SECRETS = mkdtempSync(join(tmpdir(), "cc-mcp-test-"))

let hubProc: ReturnType<typeof Bun.spawn> | undefined
let agoraRoomId = ""
let aliceMentionId = ""
let aliceClaimToken = ""
let bobClaimToken = ""

beforeAll(async () => {
  const store = AgoraStore.open({ secretsDir: TEST_SECRETS })
  store.upsertOwnerActor()
  const alice = store.upsertCCActor("mp-cc-mcp-alice")
  const bob = store.upsertCCActor("mp-cc-mcp-bob")
  const created = store.createRoom({
    floorId: randomUUID(),
    title: "MCP Completion",
    clientRequestId: randomUUID(),
    ownerProfile: { handle: "susu", displayName: "Susu" },
    members: [
      { actorId: alice.id, handle: "alice", displayName: "Alice" },
      { actorId: bob.id, handle: "bob", displayName: "Bob" },
    ],
  })
  agoraRoomId = created.room.id
  const alicePost = store.postOwnerMessage(agoraRoomId, randomUUID(), "@alice answer", created.room.floorId)
  const bobPost = store.postOwnerMessage(agoraRoomId, randomUUID(), "@bob answer", created.room.floorId)
  const aliceMention = alicePost.mentions[0]
  const bobMention = bobPost.mentions[0]
  if (!aliceMention || !bobMention) throw new Error("Missing MCP completion fixture mentions")
  const aliceClaim = store.claimMention(aliceMention.id)
  const bobClaim = store.claimMention(bobMention.id)
  aliceMentionId = aliceClaim.mention.id
  aliceClaimToken = aliceClaim.claimToken
  bobClaimToken = bobClaim.claimToken
  store.close()

  hubProc = Bun.spawn(["bun", "run", "hub.ts"], {
    cwd: import.meta.dir,
    env: { ...process.env, MP_CC_TMUX_DRY_RUN: "1", MP_CC_HUB_TOKEN: "test-token", MP_CC_HUB_PORT: String(TEST_PORT), MP_CC_SECRETS_DIR: TEST_SECRETS },
  })
  // 轮询 /health 而不是固定 sleep：冷转译时 400ms 不够，连接全灭（hub.test.ts 同款修法）。
  const deadline = Date.now() + 5_000
  let healthy = false
  while (Date.now() < deadline) {
    // fail-fast：测试 hub 没起来必须炸，绝不能让 client 静默连上别的 hub
    if (hubProc.exitCode !== null) {
      throw new Error(`test hub failed to start (exit=${hubProc.exitCode}) — refusing to run tests against anything else`)
    }
    try {
      const health = await fetch(`http://127.0.0.1:${TEST_PORT}/health`)
      if (health.ok) { healthy = true; break }
    } catch {}
    await new Promise(r => setTimeout(r, 100))
  }
  if (!healthy) throw new Error("test hub did not become healthy within 5s")
})

afterAll(() => hubProc?.kill())

function nextFrame(socket: WebSocket, type: string): Promise<Record<string, object | string | boolean>> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${type} timeout`)), 2_000)
    const listener = (raw: RawData) => {
      const frame = JSON.parse(raw.toString()) as Record<string, object | string | boolean>
      if (frame.type !== type) return
      clearTimeout(timer)
      socket.off("message", listener)
      resolve(frame)
    }
    socket.on("message", listener)
  })
}

test("MCP reply broadcasts to MP clients with matching chat_id and content", async () => {
  // 1. Open MP-side WS first
  const mp = new WebSocket(`ws://127.0.0.1:${TEST_PORT}/cc?token=test-token`)
  await new Promise<void>((resolve, reject) => {
    mp.on("open", resolve)
    mp.on("error", reject)
    setTimeout(() => reject(new Error("mp connect timeout")), 2000)
  })

  const mpReceived = new Promise<{ type: string; chat_id: string; content: string }>(resolve => {
    mp.on("message", (data) => {
      const msg = JSON.parse(data.toString())
      if (msg.type === "reply") resolve(msg)
    })
  })

  // 2. Connect MCP-side WS, send reply
  const mcp = new WebSocket(`ws://127.0.0.1:${TEST_PORT}/mcp?token=test-token`)
  await new Promise<void>((resolve, reject) => {
    mcp.on("open", resolve)
    mcp.on("error", reject)
    setTimeout(() => reject(new Error("mcp connect timeout")), 2000)
  })

  mcp.send(JSON.stringify({
    type: "reply",
    chat_id: "conv-test-1",
    content: "hi from cc",
  }))

  const reply = await mpReceived
  expect(reply.chat_id).toBe("conv-test-1")
  expect(reply.content).toBe("hi from cc")
  expect(reply.type).toBe("reply")

  mp.close()
  mcp.close()
})

test("hub completion rejects wrong and cross-mention tokens and retries idempotently", async () => {
  const mcp = new WebSocket(`ws://127.0.0.1:${TEST_PORT}/mcp?token=test-token`)
  await new Promise<void>((resolve, reject) => {
    mcp.on("open", resolve)
    mcp.on("error", reject)
    setTimeout(() => reject(new Error("mcp connect timeout")), 2_000)
  })

  const complete = async (claimToken: string, content: string) => {
    const requestId = randomUUID()
    const result = nextFrame(mcp, "agora_complete_result")
    mcp.send(JSON.stringify({
      type: "agora_complete",
      request_id: requestId,
      mention_id: aliceMentionId,
      claim_token: claimToken,
      content,
    }))
    const frame = await result
    expect(frame.request_id).toBe(requestId)
    return frame
  }

  const wrong = await complete("wrong-token", "forged")
  expect(wrong.ok).toBe(false)
  expect((wrong.error as { code: string }).code).toBe("claim_token_invalid")
  const crossed = await complete(bobClaimToken, "crossed")
  expect(crossed.ok).toBe(false)
  expect((crossed.error as { code: string }).code).toBe("claim_token_invalid")

  const first = await complete(aliceClaimToken, "durable MCP result")
  expect(first.ok).toBe(true)
  expect(first.idempotent).toBe(false)
  const retry = await complete(aliceClaimToken, "ignored retry body")
  expect(retry.ok).toBe(true)
  expect(retry.idempotent).toBe(true)
  expect(retry.message_id).toBe(first.message_id)

  const database = new Database(join(TEST_SECRETS, "agora.sqlite"), { readonly: true })
  const count = database.query<{ count: number }, [string]>(
    "SELECT COUNT(*) AS count FROM agora_messages WHERE room_id = ?",
  ).get(agoraRoomId)?.count
  database.close()
  expect(count).toBe(3)
  mcp.close()
})

test("MCP server lists agora_complete and waits for the explicit idempotent result", async () => {
  const transport = new StdioClientTransport({
    command: "bun",
    args: ["run", "mcp-server.ts"],
    cwd: import.meta.dir,
    env: {
      ...process.env,
      MP_CC_HUB_URL: `ws://127.0.0.1:${TEST_PORT}/mcp`,
      MP_CC_HUB_TOKEN: "test-token",
    },
    stderr: "pipe",
  })
  const client = new Client({ name: "agora-mcp-test", version: "1.0.0" })
  await client.connect(transport)
  const tools = await client.listTools()
  expect(tools.tools.map(tool => tool.name)).toContain("agora_complete")
  const result = await client.callTool({
    name: "agora_complete",
    arguments: {
      mention_id: aliceMentionId,
      claim_token: aliceClaimToken,
      content: "retry through MCP SDK",
    },
  })
  expect(result.isError).not.toBe(true)
  expect(JSON.stringify(result.content)).toContain("idempotent: true")
  await client.close()
})
