// 文件夹模式集成测试（docs/plan-folder-floor.md P0）：起一个真的 hub 子进程（干跑 tmux、隔离端口和各状态目录），
// 验：hello 报模式 / 账号、只属于家的帧整帧拒、附件不落进文件夹、起 claude 的命令、账号定了不能换、文件夹里零写入。
import { test, expect, beforeAll, afterAll } from "bun:test"
import { WebSocket } from "ws"
import { mkdtempSync, readdirSync, readFileSync, writeFileSync, existsSync, realpathSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const PORT = 18900 + Math.floor(Math.random() * 900)
const URL = `ws://127.0.0.1:${PORT}/cc?token=folder-token`
const tmp = (p: string) => realpathSync(mkdtempSync(join(tmpdir(), p)))
const SECRETS = tmp("cc-folder-secrets-")
const FOLDER = tmp("cc-folder-target-")
const AGENT = tmp("cc-folder-agent-")
// 账号的启动器：起会话前 hub 会先跑一遍 `<命令> --version`（启动检查）。一个过的、一个不过的
const XIAO_CMD = join(SECRETS, "fake-claude-xiao")
writeFileSync(XIAO_CMD, "#!/bin/sh\nexit 0\n", { mode: 0o755 })
const BAD_CMD = join(SECRETS, "fake-claude-bad")
writeFileSync(BAD_CMD, "#!/bin/sh\necho '查出口…' >&2\necho '⛔ 出口不对，不启动' >&2\nexit 1\n", { mode: 0o755 })
writeFileSync(join(SECRETS, "hub-config.json"), JSON.stringify({
  accounts: [
    { id: "xiao", label: "🍆", config_dir: join(SECRETS, "claude-c"), command: XIAO_CMD },
    { id: "bad", label: "坏账号", config_dir: join(SECRETS, "claude-bad"), command: BAD_CMD },
  ],
}))

// 假的看板服务：文件夹模式的 hub 启动时会来登记、手机要列表时会来问。不设的话测试 hub 会去找本机真的 4793
const pmCalls: { method: string; path: string; folderHeader: string | null; auth: string | null; body: any }[] = []
const PM_TOKEN = "f".repeat(64)
writeFileSync(join(SECRETS, "pm-api-token"), PM_TOKEN + "\n")
const pm = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  async fetch(req) {
    const u = new globalThis.URL(req.url)
    const body = req.method === "POST" ? await req.json().catch(() => null) : null
    pmCalls.push({ method: req.method, path: u.pathname + u.search, folderHeader: req.headers.get("x-mp-folder"), auth: req.headers.get("authorization"), body })
    if (u.pathname === "/api/folder/register") return Response.json({ ok: true, id: "fid123" })
    if (u.pathname === "/api/folder/sessions") return Response.json({ ok: true, seq: 7, pending: false, gone: [], sessions: [{ key: "xiao:11111111-0000-4000-8000-000000000000", title: "假的", turns: 2, epoch: 1, seq: 7 }] })
    if (u.pathname === "/api/folder/turns") return Response.json({ ok: true, epoch: 1, total: 1, from: 0, next: null, turns: [{ id: "u1", from: "human", text: "问", parts: [] }] })
    return new Response("404", { status: 404 })
  },
})

let hub: ReturnType<typeof Bun.spawn> | undefined
let out = ""

beforeAll(async () => {
  hub = Bun.spawn(["bun", "run", "hub.ts"], {
    cwd: import.meta.dir,
    stdout: "pipe",
    env: {
      ...process.env,
      MP_HUB_MODE: "folder", MP_HUB_FOLDER: FOLDER + "/",
      MP_CC_TMUX_DRY_RUN: "empty", MP_CC_HUB_TOKEN: "folder-token", MP_CC_HUB_PORT: String(PORT),
      MP_CC_SECRETS_DIR: SECRETS, MP_CC_AGENT_DIR: AGENT, MP_CC_THINKING_SPOOL: join(SECRETS, "spool"),
      MP_APNS_KEY_PATH: join(SECRETS, "no-such-key.p8"), MP_CC_LA_INTERVAL_MS: "3600000", MP_CC_RELAY_CONNECTOR: "off",
      MP_PM_URL: `http://127.0.0.1:${pm.port}`, MP_PM_API_TOKEN_FILE: join(SECRETS, "pm-api-token"),
    },
  })
  void (async () => {
    const dec = new TextDecoder()
    for await (const chunk of hub!.stdout as ReadableStream<Uint8Array>) out += dec.decode(chunk)
  })()
  const deadline = Date.now() + 8_000
  while (Date.now() < deadline) {
    if (hub.exitCode !== null) throw new Error(`文件夹模式 hub 没起来（exit=${hub.exitCode}）`)
    try { if ((await fetch(`http://127.0.0.1:${PORT}/health`)).ok) return } catch {}
    await new Promise((r) => setTimeout(r, 100))
  }
  throw new Error("文件夹模式 hub 8 秒内没就绪")
})

afterAll(() => { hub?.kill(); pm.stop(true) })

async function open(): Promise<{ ws: WebSocket; hello: any }> {
  const ws = new WebSocket(URL)
  const first = new Promise<any>((resolve) => ws.once("message", (d) => resolve(JSON.parse(d.toString()))))
  await new Promise<void>((resolve, reject) => {
    ws.on("open", resolve); ws.on("error", reject)
    setTimeout(() => reject(new Error("connect timeout")), 3000)
  })
  return { ws, hello: await first }
}

function frame(ws: WebSocket, match: (m: any) => boolean, ms = 4000): Promise<any> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ws.off("message", on); reject(new Error("等帧超时")) }, ms)
    const on = (data: unknown) => {
      const m = JSON.parse(String(data))
      if (!match(m)) return
      clearTimeout(timer); ws.off("message", on); resolve(m)
    }
    ws.on("message", on)
  })
}

async function until(cond: () => boolean, ms = 4000): Promise<void> {
  const deadline = Date.now() + ms
  while (!cond()) {
    if (Date.now() > deadline) throw new Error("等条件超时")
    await new Promise((r) => setTimeout(r, 50))
  }
}

const spawnLine = (session: string) => out.split("\n").find((l) => l.startsWith(`[dry-run] spawn ${session} `))

test("hello 报文件夹模式、文件夹路径（去掉结尾斜杠）、账号", async () => {
  const { ws, hello } = await open()
  expect(hello.type).toBe("hello")
  expect(hello.mode).toBe("folder")
  expect(hello.folder).toBe(FOLDER)
  expect(hello.accounts).toEqual([{ id: "default", label: "默认" }, { id: "xiao", label: "🍆" }, { id: "bad", label: "坏账号" }])
  expect(hello.capabilities).toContain("folder")
  expect(hello.capabilities).toContain("mcp")
  expect(hello.dirs.claude_home).toBe(FOLDER)
  ws.close()
})

test("MCP 配置和 hook 设置写在状态目录里，连的是本实例的端口和口令", () => {
  const mcp = JSON.parse(readFileSync(join(SECRETS, "mcp.json"), "utf-8")).mcpServers["cc-bridge"]
  expect(mcp.env).toEqual({ MP_CC_HUB_URL: `ws://127.0.0.1:${PORT}/mcp`, MP_CC_HUB_TOKEN: "folder-token" })
  expect(mcp.args).toEqual([join(import.meta.dir, "mcp-server.ts")])
  const settings = JSON.parse(readFileSync(join(SECRETS, "folder-settings.json"), "utf-8"))
  expect(Object.keys(settings.hooks)).toEqual(["Stop", "PreToolUse", "PostToolUse"])
})

test("只属于家的帧整帧拒：回 folder_unsupported，带回 request_id，文件夹里不出现 CLAUDE.md / 语音条", async () => {
  const { ws } = await open()
  for (const type of ["set_voice_instructions", "voice_note", "feedback", "cc_memory_manifest_req", "agent_status", "set_garden_memory", "set_agent_workdir"]) {
    const got = frame(ws, (m) => m.type === "folder_unsupported" && m.frame === type)
    ws.send(JSON.stringify({ type, request_id: `r-${type}`, content: "x", text: "x", path: "/tmp", speaker: "s" }))
    expect((await got).request_id).toBe(`r-${type}`)
  }
  expect(readdirSync(FOLDER)).toEqual([])
  ws.close()
})

test("新开对话：命令在文件夹里起、不带陪伴参数、hook 走 --settings；附件落在状态目录", async () => {
  const { ws } = await open()
  const ack = frame(ws, (m) => m.type === "ack" && m.message_id === "m-f1")
  ws.send(JSON.stringify({
    type: "send", chat_id: "conv-folder-aaaa-bbbb", message_id: "m-f1", content: "hi", user: "susu", session_name: "mp-cc-f1",
    images: [{ b64: Buffer.from("png-bytes").toString("base64"), mime: "image/png" }],
  }))
  await ack
  await until(() => !!spawnLine("mp-cc-f1"))
  const line = spawnLine("mp-cc-f1")!
  expect(line).toContain(`cwd=${FOLDER} :: claude --mcp-config '${join(SECRETS, "mcp.json")}' --settings '${join(SECRETS, "folder-settings.json")}' --session-id `)
  expect(line).not.toContain("disallowedTools")
  expect(line).not.toContain("strict-mcp-config")
  expect(line).not.toContain("--model")
  const inbox = join(SECRETS, "mp-inbox", "conv-folder-aaaa")
  expect(readdirSync(inbox).length).toBe(1)
  expect(readdirSync(FOLDER)).toEqual([])
  ws.close()
})

test("带账号新开：用那个账号的启动命令；之后带别的账号来也照原来的", async () => {
  const { ws } = await open()
  const ack = frame(ws, (m) => m.type === "ack" && m.message_id === "m-x1")
  ws.send(JSON.stringify({ type: "send", chat_id: "conv-xiao", message_id: "m-x1", content: "hi", user: "susu", session_name: "mp-cc-x1", account: "xiao" }))
  await ack
  await until(() => !!spawnLine("mp-cc-x1"))
  expect(spawnLine("mp-cc-x1")).toContain(` :: ${XIAO_CMD} --mcp-config `)
  expect(JSON.parse(readFileSync(join(SECRETS, "session-accounts.json"), "utf-8"))).toEqual({ "mp-cc-x1": "xiao" })

  // 之后带别的账号来（她改了这一层的账号）：不报错，照原来那个账号接着聊
  const ack2 = frame(ws, (m) => m.type === "ack" && m.message_id === "m-x2")
  ws.send(JSON.stringify({ type: "send", chat_id: "conv-xiao", message_id: "m-x2", content: "hi", user: "susu", session_name: "mp-cc-x1", account: "default" }))
  await ack2
  expect(JSON.parse(readFileSync(join(SECRETS, "session-accounts.json"), "utf-8"))).toEqual({ "mp-cc-x1": "xiao" })

  const unknown = frame(ws, (m) => JSON.stringify(m).includes("没有账号"))
  ws.send(JSON.stringify({ type: "send", chat_id: "conv-n", message_id: "m-n1", content: "hi", user: "susu", session_name: "mp-cc-n1", account: "nope" }))
  expect((await unknown).message_id).toBe("m-n1")
  expect(spawnLine("mp-cc-n1")).toBeUndefined()
  ws.close()
})

test("账号的启动检查没过：不起会话，消息回它的原话，那条对话的状态收回（不一直转圈）", async () => {
  const { ws } = await open()
  const err = frame(ws, (m) => m.type === "error" && m.message_id === "m-b1")
  const blocked = frame(ws, (m) => m.type === "session_blocked" && m.session_name === "mp-cc-b1")
  ws.send(JSON.stringify({ type: "send", chat_id: "conv-bad", message_id: "m-b1", content: "hi", user: "susu", session_name: "mp-cc-b1", account: "bad" }))
  expect((await err).reason).toBe("账号「坏账号」起不来：⛔ 出口不对，不启动")
  expect(await blocked).toMatchObject({ reason: "launch_failed", message: "账号「坏账号」起不来：⛔ 出口不对，不启动" })
  expect(spawnLine("mp-cc-b1")).toBeUndefined()
  await until(() => out.includes("la phase mp-cc-b1 working→idle"))
  ws.close()
})

test("Codex 第一版不支持：[+] 开 Codex 窗口被拒", async () => {
  const { ws } = await open()
  const opened = frame(ws, (m) => m.type === "window_opened")
  ws.send(JSON.stringify({ type: "open_window", engine: "codex" }))
  expect(await opened).toMatchObject({ ok: false, reason: "文件夹模式第一版不支持 Codex" })
  ws.close()
})

test("看历史：启动时向看板服务登记自己的文件夹和账号，带专用头", async () => {
  await until(() => pmCalls.some((c) => c.path === "/api/folder/register"))
  const reg = pmCalls.find((c) => c.path === "/api/folder/register")!
  expect(reg).toMatchObject({ method: "POST", folderHeader: "1", auth: `Bearer ${PM_TOKEN}` })
  expect(reg.body.folder).toBe(FOLDER)
  expect(reg.body.notify).toBe(`http://127.0.0.1:${PORT}/folder/changed`)
  expect(reg.body.accounts.map((a: any) => a.id)).toEqual(["default", "xiao", "bad"])
  expect(reg.body.accounts[1].config_dir).toBe(join(SECRETS, "claude-c"))
})

test("看历史：folder_req 只转列表和内容；列表里带上这台 hub 自己开的会话；手机传不了文件夹", async () => {
  const { ws, hello } = await open()
  expect(hello.capabilities).toContain("folder_history")
  const list = frame(ws, (m) => m.type === "folder_req_result" && m.req_id === "r1")
  ws.send(JSON.stringify({ type: "folder_req", req_id: "r1", op: "sessions", after: 3, folder: "/etc", id: "别的文件夹" }))
  const got = await list
  expect(got).toMatchObject({ ok: true, op: "sessions", seq: 7, sessions: [{ title: "假的" }] })
  expect(Object.values(got.hub_sessions as Record<string, string>).some((n) => n.startsWith("mp-cc"))).toBe(true)
  expect(Object.keys(got.hub_sessions).every((k) => /^[a-z0-9_-]+:[0-9a-f-]{36}$/.test(k))).toBe(true)
  expect(pmCalls.at(-1)).toMatchObject({ method: "GET", path: "/api/folder/sessions?id=fid123&after=3", folderHeader: "1" })

  const page = frame(ws, (m) => m.type === "folder_req_result" && m.req_id === "r2")
  ws.send(JSON.stringify({ type: "folder_req", req_id: "r2", op: "turns", key: "xiao:11111111-0000-4000-8000-000000000000", from: 5 }))
  expect(await page).toMatchObject({ ok: true, op: "turns", total: 1 })
  expect(pmCalls.at(-1)!.path).toBe("/api/folder/turns?id=fid123&key=xiao%3A11111111-0000-4000-8000-000000000000&from=5")

  const n = pmCalls.length
  const bad = frame(ws, (m) => m.type === "folder_req_result" && m.req_id === "r3")
  ws.send(JSON.stringify({ type: "folder_req", req_id: "r3", op: "turns", key: "../../etc/passwd" }))
  expect(await bad).toMatchObject({ ok: false, code: "bad-req" })
  const other = frame(ws, (m) => m.type === "folder_req_result" && m.req_id === "r4")
  ws.send(JSON.stringify({ type: "folder_req", req_id: "r4", op: "register", folder: "/etc" }))
  expect(await other).toMatchObject({ ok: false, code: "bad-req" })
  expect(pmCalls.length).toBe(n)
  ws.close()
})

test("看历史：看板服务说有变化 → 连着的手机收到 folder_changed；只认本机来的", async () => {
  const { ws } = await open()
  const changed = frame(ws, (m) => m.type === "folder_changed")
  const res = await fetch(`http://127.0.0.1:${PORT}/folder/changed`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ id: "fid123", keys: ["xiao:11111111-0000-4000-8000-000000000000", 42] }) })
  expect(await res.json()).toMatchObject({ ok: true, sent: 1 })
  expect(await changed).toEqual({ type: "folder_changed", keys: ["xiao:11111111-0000-4000-8000-000000000000"] })
  const forwarded = await fetch(`http://127.0.0.1:${PORT}/folder/changed`, { method: "POST", headers: { "content-type": "application/json", "x-forwarded-for": "1.2.3.4" }, body: "{}" })
  expect(forwarded.status).toBe(403)
  ws.close()
})

test("跑完以后文件夹里一个文件都没多", () => {
  expect(readdirSync(FOLDER)).toEqual([])
  expect(existsSync(join(FOLDER, "mp-inbox"))).toBe(false)
})
