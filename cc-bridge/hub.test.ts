import { test, expect, beforeAll, afterAll } from "bun:test"
import { WebSocket } from "ws"
import { mkdtempSync, writeFileSync, utimesSync, readdirSync, existsSync, unlinkSync, mkdirSync, readFileSync, realpathSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { buildChannelTag, setTmuxRunner, isLoopback, pasteAwareSendAndEnter, planStreamReconcile, writeReadingStatus, writeVocabStatus, writeReadingContext, appendVoiceNote, markReplySeen, seenMpMsgIds, cursorRestoreSeq, PASTE_MODE_LENGTH_THRESHOLD, PASTE_RETRY_MAX, type PasteIO } from "./hub.ts"
import { deliverBookNote, pendingBookNotes, ackBookNote } from "./book-notes.ts"
import { agentStatusSnapshot, applyAgentConfigPatch, writeVoiceInstructions, MP_VOICE_BEGIN, MP_VOICE_END } from "./hub.ts"
// 仅对 in-process tmux 调用生效（目前没有 in-process 测试用到 tmux）。
// 集成测试由 spawn 子进程跑，子进程通过 MP_CC_TMUX_DRY_RUN=1 跳过真实 tmux。
setTmuxRunner({
  send: () => {},
  sendRaw: () => {},
  key: async () => {},
  capture: async () => "",
  hasSession: () => true,
  list: () => [],
  paneTitles: () => new Map(),
  spawn: async () => {},
  kill: async () => {},
  paste: async () => ({ ok: true }),
})

// ⚠️ 本文件全部集成用例都依赖 loopback fetch 不走代理，这件事由 `cc-bridge/.env` 保证
// （NO_PROXY 必须在 bun 启动时就在环境里，写在这里已经晚了——理由见那个文件的注释）。
// 所以 `bun test` 不需要再手动前缀 no_proxy=…；跑不通先看 .env 还在不在。

// 隔离（2026-06-11 /clear 事故）：随机高位端口，绝不绑/连生产 7890。
const TEST_PORT = 17890 + Math.floor(Math.random() * 1000)
// Phase 2：所有连接（含 loopback）都要带 token。测试 hub token 由下方 beforeAll 设为 "test-token"。
const CC_URL = `ws://127.0.0.1:${TEST_PORT}/cc?token=test-token`
const MCP_URL = `ws://127.0.0.1:${TEST_PORT}/mcp?token=test-token`
const CC_URL_NO_TOKEN = `ws://127.0.0.1:${TEST_PORT}/cc`
// secrets 也隔离：reply/thinking 测试帧绝不能写生产 secrets/（hub 重启会 replay 进 app）
const TEST_SECRETS = mkdtempSync(join(tmpdir(), "cc-hub-test-"))
// agent 目录也隔离：book-note 端点读 config/reading-context，绝不能碰真实 agent/
const TEST_AGENT_DIR = mkdtempSync(join(tmpdir(), "cc-hub-agent-"))
// CC 工作目录也隔离：set_voice_instructions 会改 <workdir>/CLAUDE.md，绝不能碰真 ~/Desktop/cc-rp
const TEST_CC_WORKDIR = mkdtempSync(join(tmpdir(), "cc-hub-workdir-"))
// CC memory 同步目录也隔离（清单 / 取文件的 WS 用例），不读真 ~/.claude/projects
const TEST_MEMORY_DIR = mkdtempSync(join(tmpdir(), "cc-hub-memory-"))
writeFileSync(join(TEST_MEMORY_DIR, "MEMORY.md"), "# 索引\n- [剧场](project_theater.md)\n- [钥匙](private_key.md)\n")
writeFileSync(join(TEST_MEMORY_DIR, "project_theater.md"), "---\nname: 剧场\ndescription: 猫狗\n---\n正文\n")
writeFileSync(join(TEST_MEMORY_DIR, "private_key.md"), "SECRET")
// 待投目录：hub 启动前放一个「hook 投不进去」的旧文件，启动 5s 后应被自动补投（见末尾用例）
{
  const { mkdirSync } = await import("node:fs")
  const spool = join(TEST_SECRETS, "spool")
  mkdirSync(spool, { recursive: true })
  const f = join(spool, "0001-spool-turn.json")
  writeFileSync(f, JSON.stringify({ chat_id: "conv-spool", session_id: "sess-x", reply_text: "待投补发", turn_uuid: "spool-turn" }))
  const old = new Date(Date.now() - 60_000); utimesSync(f, old, old)
}

let hubProcess: ReturnType<typeof Bun.spawn> | undefined

beforeAll(async () => {
  hubProcess = Bun.spawn(["bun", "run", "hub.ts"], {
    cwd: import.meta.dir,
    env: {
      ...process.env,
      MP_CC_TMUX_DRY_RUN: "1", MP_CC_HUB_TOKEN: "test-token", MP_CC_HUB_PORT: String(TEST_PORT),
      MP_CC_SECRETS_DIR: TEST_SECRETS, MP_CC_AGENT_DIR: TEST_AGENT_DIR, MP_CC_WORKDIR: TEST_CC_WORKDIR, MP_CODEX_WORKDIR: join(TEST_SECRETS, "gpt-rp"), MP_CC_THINKING_SPOOL: join(TEST_SECRETS, "spool"), MP_CC_REPLY_VIA_TEXT: "all",
      CC_MEMORY_SYNC_DIR: TEST_MEMORY_DIR,
      // /la/push 调试口默认 404；测试要走它就得显式开。
      MP_CC_LA_DEBUG: "1",
      // 钉死一个不存在的 .p8：APNs 走 cert-missing 分支 → 测试永远不发真流量到 Apple。
      MP_APNS_KEY_PATH: join(TEST_SECRETS, "no-such-key.p8"),
      // 周期推送定时器在测试里不该自己跑（store 里只有测试塞的假 token）。
      MP_CC_LA_INTERVAL_MS: "3600000",
    },
  })
  // 轮询 /health 而不是固定 sleep：冷转译（单跑本文件）时 300ms 不够，bind 前的连接全灭。
  const deadline = Date.now() + 5_000
  while (Date.now() < deadline) {
    // fail-fast：测试 hub 没起来（如端口被占）必须炸，绝不能让 client 静默连上别的 hub
    if (hubProcess.exitCode !== null) {
      throw new Error(`test hub failed to start (exit=${hubProcess.exitCode}) — refusing to run tests against anything else`)
    }
    try {
      const health = await fetch(`http://127.0.0.1:${TEST_PORT}/health`)
      if (health.ok) return
    } catch {}
    await new Promise(r => setTimeout(r, 100))
  }
  throw new Error("test hub did not become healthy within 5s")
})

afterAll(() => {
  hubProcess?.kill()
})

test("/health 带 tmuxCtl：干跑不建控制连接（K1）", async () => {
  const body = await (await fetch(`http://127.0.0.1:${TEST_PORT}/health`)).json()
  expect(body.ok).toBe(true)
  expect(body.tmuxCtl).toEqual({ state: "off", ctl: 0, fork: 0 })
  expect(body.bench).toBeUndefined()   // MP_HUB_BENCH 没开：不带卡顿 / 阻塞账
})

test("hub accepts MP WebSocket connection on /cc", async () => {
  const ws = new WebSocket(CC_URL)
  await new Promise<void>((resolve, reject) => {
    ws.on("open", resolve)
    ws.on("error", reject)
    setTimeout(() => reject(new Error("connect timeout")), 2000)
  })
  expect(ws.readyState).toBe(WebSocket.OPEN)
  ws.close()
})

// Phase 2 尝试过强制 loopback 也校验，但漏了 iPhone 模拟器（无 Mac 生成 QR 路径就没 token）
// → rollback，loopback /cc 仍免鉴权。此断言记录当前行为，Phase 2.6 补上模拟器 token 拿法后再收
test("hub accepts loopback WebSocket without token on /cc (Phase 2 rollback)", async () => {
  const ws = new WebSocket(CC_URL_NO_TOKEN)
  await new Promise<void>((resolve, reject) => {
    ws.on("open", resolve)
    ws.on("error", reject)
    setTimeout(() => reject(new Error("connect timeout")), 2000)
  })
  expect(ws.readyState).toBe(WebSocket.OPEN)
  ws.close()
})

test("hub rejects loopback GET /pair without token (Phase 2)", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/pair`)
  expect(res.status).toBe(401)
})

test("hub accepts loopback GET /pair with correct token (Phase 2)", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/pair?token=test-token`)
  expect(res.status).toBe(200)
  const body = await res.json() as { mpcc: number; t: string }
  expect(body.mpcc).toBe(1)
  expect(body.t).toBe("test-token")
})

/// 连上就开始收，免得 hello 在 open 回调前到了被漏掉
function firstFrame(ws: WebSocket): Promise<any> {
  return new Promise(resolve => ws.once("message", data => resolve(JSON.parse(data.toString()))))
}

test("#046 hello：连上第一帧，带主机名 / 两个家 / 工具探测 / 能力表；不带干活目录时是 null", async () => {
  const ws = new WebSocket(CC_URL)
  const hello = firstFrame(ws)
  await new Promise<void>((resolve, reject) => {
    ws.on("open", resolve)
    ws.on("error", reject)
    setTimeout(() => reject(new Error("connect timeout")), 2000)
  })
  const frame = await hello
  expect(frame.type).toBe("hello")
  expect(typeof frame.host_name).toBe("string")
  expect(frame.dirs.agent_workdir).toBeNull()
  expect(typeof frame.dirs.claude_home).toBe("string")
  expect(typeof frame.dirs.codex_home).toBe("string")
  expect(Object.keys(frame.tools).sort()).toEqual(["claude", "codex", "tmux"])
  expect(frame.capabilities).toContain("dirs")
  ws.close()
})

test("hub acks send messages", async () => {
  const ws = await openMP()

  ws.send(JSON.stringify({
    type: "send",
    chat_id: "test-conv-1",
    message_id: "msg-1",
    content: "hello",
    user: "susu",
  }))

  const ack = await new Promise<{ type: string; message_id: string }>((resolve) => {
    ws.on("message", (data) => resolve(JSON.parse(data.toString())))
  })

  expect(ack.type).toBe("ack")
  expect(ack.message_id).toBe("msg-1")
  ws.close()
})

test("K1 第 4b 步：retry 帧只接受 hub 记为 failed 的 message_id；没记录的不发、不 ack，回 send_status failed；正常 send 不带 send_status", async () => {
  const ws = await openMP()
  const frames: any[] = []
  ws.on("message", (data) => frames.push(JSON.parse(data.toString())))
  ws.send(JSON.stringify({ type: "send", chat_id: "conv-4b", message_id: "m-4b-retry", content: "再来一次", user: "susu", session_name: "mp-cc-4b", retry: true }))
  ws.send(JSON.stringify({ type: "send", chat_id: "conv-4b", message_id: "m-4b-plain", content: "普通", user: "susu", session_name: "mp-cc-4b" }))
  const deadline = Date.now() + 3_000
  while (!frames.some((f) => f.type === "ack") && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20))
  await new Promise((r) => setTimeout(r, 200))
  const mine = frames.filter((f) => f.message_id === "m-4b-retry" || f.message_id === "m-4b-plain")
  expect(mine.map((f) => `${f.type}:${f.message_id}`)).toEqual(["send_status:m-4b-retry", "ack:m-4b-plain"])
  expect(mine[0]).toMatchObject({ chat_id: "conv-4b", session_name: "mp-cc-4b", status: "failed", retryable: false })
  expect(typeof mine[0].reason).toBe("string")
  ws.close()
})

test("K1 第 4b 步 · 审查 R1-10：client_info 之后补发一份 send_status_snapshot（每个连接一次）", async () => {
  const ws = await openMP()
  const frames: any[] = []
  ws.on("message", (data) => frames.push(JSON.parse(data.toString())))
  ws.send(JSON.stringify({ type: "client_info", platform: "ios" }))
  ws.send(JSON.stringify({ type: "client_info", platform: "ios" }))
  const deadline = Date.now() + 3_000
  while (!frames.some((f) => f.type === "send_status_snapshot") && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20))
  await new Promise((r) => setTimeout(r, 200))
  const snaps = frames.filter((f) => f.type === "send_status_snapshot")
  expect(snaps.length).toBe(1)
  expect(snaps[0].statuses).toEqual([])
  ws.close()
})

test("buildChannelTag wraps message in channel xml", () => {
  const tag = buildChannelTag({
    type: "send",
    chat_id: "conv-1",
    message_id: "msg-1",
    content: "hello",
    user: "susu",
  }, "2026-05-18T03:00:00.000Z")

  expect(tag).toContain('source="memorypalace"')
  expect(tag).toContain('chat_id="conv-1"')
  expect(tag).toContain('message_id="msg-1"')
  expect(tag).toContain('user="susu"')
  expect(tag).toContain('ts="2026-05-18T03:00:00.000Z"')
  expect(tag).toContain("hello")
  expect(tag.startsWith("<channel")).toBe(true)
  expect(tag.endsWith("</channel>")).toBe(true)
})

test("buildChannelTag replaces newlines with spaces", () => {
  const tag = buildChannelTag({
    type: "send",
    chat_id: "c1",
    message_id: "m1",
    content: "line1\nline2\nline3",
    user: "susu",
  }, "2026-05-18T00:00:00.000Z")

  expect(tag).not.toContain("line1\nline2")
  expect(tag).toContain("line1 line2 line3")
})

test("isLoopback recognizes IPv4 loopback", () => {
  expect(isLoopback("127.0.0.1")).toBe(true)
})

test("isLoopback recognizes IPv6 loopback", () => {
  expect(isLoopback("::1")).toBe(true)
})

test("isLoopback recognizes IPv4-mapped IPv6 loopback", () => {
  expect(isLoopback("::ffff:127.0.0.1")).toBe(true)
})

test("isLoopback rejects LAN IP", () => {
  expect(isLoopback("192.168.31.5")).toBe(false)
})

test("isLoopback rejects undefined", () => {
  expect(isLoopback(undefined)).toBe(false)
})

// 测试轮询可能正好读到既有写入的 truncate/write 中间半份 JSON。
// 仅有界轮询把此刻视为尚未就绪；最终 WS 返回仍完整断言。
async function pollJSON(path: string): Promise<any> {
  try { return await Bun.file(path).json() }
  catch (e) { if (e instanceof SyntaxError) return {}; throw e }
}

// ---------- L2: per-session routing + spawn / list ----------

async function openMP(): Promise<WebSocket> {
  const ws = new WebSocket(CC_URL)
  const hello = firstFrame(ws)
  await new Promise<void>((resolve, reject) => {
    ws.on("open", resolve)
    ws.on("error", reject)
    setTimeout(() => reject(new Error("connect timeout")), 2000)
  })
  expect((await hello).type).toBe("hello")   // #046：连上第一帧永远是 hello
  return ws
}

function nextMsg<T = any>(ws: WebSocket): Promise<T> {
  return new Promise(resolve => {
    ws.once("message", data => resolve(JSON.parse(data.toString())))
  })
}

function msgOfType(ws: WebSocket, type: string, ms = 3_000): Promise<any> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ws.off("message", on); reject(new Error(`等 ${type} 超时`)) }, ms)
    const on = (data: unknown) => {
      const m = JSON.parse(String(data))
      if (m.type !== type) return
      clearTimeout(timer); ws.off("message", on); resolve(m)
    }
    ws.on("message", on)
  })
}

test("cc_memory 清单 / 取文件：异步读盘后回包，排除的不进清单也取不到", async () => {
  const ws = await openMP()
  const manifestP = msgOfType(ws, "cc_memory_manifest")
  ws.send(JSON.stringify({ type: "cc_memory_manifest_req" }))
  const m = await manifestP
  expect(m.ok).toBe(true)
  expect(m.files.map((f: { name: string }) => f.name)).toEqual(["MEMORY.md", "project_theater.md"])
  const filesP = msgOfType(ws, "cc_memory_files")
  ws.send(JSON.stringify({ type: "cc_memory_fetch", names: ["MEMORY.md", "private_key.md", "project_theater.md"] }))
  const f = await filesP
  expect(f.files.map((x: { name: string }) => x.name)).toEqual(["MEMORY.md", "project_theater.md"])
  expect(JSON.stringify(f)).not.toContain("SECRET")
  expect(f.files[0].content).not.toContain("private_key.md")
  ws.close()
})

test("L2: send with session_name = mp-cc-2 acks ok (DRY_RUN hasSession=true)", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({
    type: "send",
    chat_id: "conv-l2",
    message_id: "m-l2-1",
    content: "hi",
    user: "susu",
    session_name: "mp-cc-2",
  }))
  const ack = await nextMsg(ws)
  expect(ack.type).toBe("ack")
  expect(ack.message_id).toBe("m-l2-1")
  ws.close()
})

test("L2: send without session_name still works (backward compat)", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({
    type: "send",
    chat_id: "conv-old",
    message_id: "m-old-1",
    content: "hi",
    user: "susu",
  }))
  const ack = await nextMsg(ws)
  expect(ack.type).toBe("ack")
  ws.close()
})

test("L2: spawn_cc with invalid name returns spawn_cc_err invalid_name", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({ type: "spawn_cc", session_name: "has space" }))
  const reply = await nextMsg(ws)
  expect(reply.type).toBe("spawn_cc_err")
  expect(reply.reason).toBe("invalid_name")
  ws.close()
})

test("L2: spawn_cc with existing session returns session_exists (DRY_RUN hasSession=true)", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({ type: "spawn_cc", session_name: "mp-cc-2" }))
  const reply = await nextMsg(ws)
  expect(reply.type).toBe("spawn_cc_err")
  expect(reply.session_name).toBe("mp-cc-2")
  expect(reply.reason).toBe("session_exists")
  ws.close()
})

test("L2: spawn_cc with too-long name returns invalid_name", async () => {
  const ws = await openMP()
  const longName = "mp-cc-" + "x".repeat(40)
  ws.send(JSON.stringify({ type: "spawn_cc", session_name: longName }))
  const reply = await nextMsg(ws)
  expect(reply.type).toBe("spawn_cc_err")
  expect(reply.reason).toBe("invalid_name")
  ws.close()
})

test("L2: list_sessions returns array (empty in DRY_RUN)", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({ type: "list_sessions" }))
  const reply = await nextMsg(ws)
  expect(reply.type).toBe("list_sessions_result")
  expect(Array.isArray(reply.sessions)).toBe(true)
  ws.close()
})

// ---------- L3: 斜杠命令 raw 直发 ----------

test("L3: command frame /clear acks command_ack", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({ type: "command", content: "/clear" }))
  const reply = await nextMsg(ws)
  expect(reply.type).toBe("command_ack")
  expect(reply.content).toBe("/clear")
  ws.close()
})

test("L3: command frame without leading / returns error", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({ type: "command", content: "clear" }))
  const reply = await nextMsg(ws)
  expect(reply.type).toBe("error")
  expect(reply.reason).toBe("command must start with /")
  ws.close()
})

test("L3: command frame with session_name routes correctly (DRY_RUN)", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({
    type: "command",
    content: "/model claude-opus-4-6[1M]",
    session_name: "mp-cc-2",
  }))
  const reply = await nextMsg(ws)
  expect(reply.type).toBe("command_ack")
  expect(reply.content).toBe("/model claude-opus-4-6[1M]")
  ws.close()
})

// 底部胶囊「cc-模型名」（审查 R1-3）：/model 写进终端 ≠ 切成了，CLI 没表态前不广播 session_model
test("session_model：app 发 /model 后、CLI 确认前不广播", async () => {
  const ws = await openMP()
  const frames: any[] = []
  ws.on("message", d => frames.push(JSON.parse(d.toString())))
  ws.send(JSON.stringify({ type: "client_info", platform: "ios" }))
  await new Promise(r => setTimeout(r, 50))
  ws.send(JSON.stringify({ type: "command", content: "/model claude-opus-5-5", session_name: "mp-cc-sm-t" }))
  await new Promise(r => setTimeout(r, 300))
  expect(frames.some(f => f.type === "command_ack")).toBe(true)
  expect(frames.some(f => f.type === "session_model" && f.session_name === "mp-cc-sm-t" && f.model_id === "claude-opus-5-5")).toBe(false)
  ws.close()
})

// ---------- L4: 嵌入终端 attach / input / resize ----------
// 注：DRY_RUN 下 createTerminalAttachment 会调真的 mkfifo + tmux pipe-pane，
// 子进程 hub 在 MP_CC_TMUX_DRY_RUN=1 时跑的是真的 hub.ts，但 setTmuxRunner
// 不影响 createTerminalAttachment（它直接调 execFileSync）。
// 因此这里只测帧路由层正确性（hasSession 通过 DRY_RUN 返回 true → 走 happy path
// 但 mkfifo 真的会跑），就测响应类型即可。

test("#046 干活目录：不存在回中文错误；合法目录写进 hub-config 并广播新 hello；空串恢复默认", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({ type: "set_agent_workdir", path: join(TEST_SECRETS, "no-such-dir") }))
  const err = await nextMsg(ws)
  expect(err).toEqual({ type: "hub_config_error", reason: "电脑上没有这个目录" })

  const proj = realpathSync(mkdtempSync(join(tmpdir(), "t3-proj-")))
  ws.send(JSON.stringify({ type: "set_agent_workdir", path: proj }))
  const cfg = await nextMsg(ws)
  expect(cfg.type).toBe("hub_config")
  expect(cfg.agent_workdir).toBe(proj)
  const hello = await nextMsg(ws)
  expect(hello.type).toBe("hello")
  expect(hello.dirs.agent_workdir).toBe(proj)
  expect(JSON.parse(readFileSync(join(TEST_SECRETS, "hub-config.json"), "utf-8")).agent_workdir).toBe(proj)

  ws.send(JSON.stringify({ type: "get_hub_config" }))
  expect((await nextMsg(ws)).agent_workdir).toBe(proj)

  // request_id 原样带回（App 按它对回调，astra 实现审 #3）
  ws.send(JSON.stringify({ type: "get_hub_config", request_id: "r-get" }))
  expect((await nextMsg(ws)).request_id).toBe("r-get")
  ws.send(JSON.stringify({ type: "set_agent_workdir", path: "/no/such/dir", request_id: "r-bad" }))
  expect(await nextMsg(ws)).toEqual({ type: "hub_config_error", reason: "电脑上没有这个目录", request_id: "r-bad" })
  ws.send(JSON.stringify({ type: "set_agent_workdir", path: "/tmp/\u0000x", request_id: "r-nul" }))
  expect((await nextMsg(ws)).request_id).toBe("r-nul")   // 带 NUL 的路径回人话，hub 不崩

  ws.send(JSON.stringify({ type: "set_agent_workdir", path: "" }))
  expect((await nextMsg(ws)).agent_workdir).toBeNull()
  expect((await nextMsg(ws)).dirs.agent_workdir).toBeNull()
  ws.close()
})

test("#046 list_dirs：只列子文件夹；读不了给 error", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "t3-ld-")))
  mkdirSync(join(root, "alpha"))
  mkdirSync(join(root, ".git"))
  writeFileSync(join(root, "README.md"), "x")
  const ws = await openMP()
  ws.send(JSON.stringify({ type: "list_dirs", path: root }))
  expect(await nextMsg(ws)).toEqual({ type: "dir_list", path: root, parent: dirname(root), dirs: ["alpha"], truncated: false })
  ws.send(JSON.stringify({ type: "list_dirs", path: join(root, "nope") }))
  expect((await nextMsg(ws)).error).toBe("电脑上没有这个目录")
  ws.send(JSON.stringify({ type: "list_dirs", path: root, request_id: "r-ls" }))
  expect((await nextMsg(ws)).request_id).toBe("r-ls")
  ws.close()
})

test("#046 restore_window 不认识的窗口：ok=false + 中文原因", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({ type: "restore_window", code: "zzzzzz" }))
  const res = await nextMsg(ws)
  expect(res.type).toBe("window_restored")
  expect(res.ok).toBe(false)
  expect(res.reason).toBe("这个窗口已经结束了")
  ws.close()
})

test("L4: terminal_attach unknown session returns terminal_error", async () => {
  const ws = await openMP()
  // DRY_RUN 下 hasSession 默认 true，没法测 session_not_found 分支；
  // 但 attach 后会真的 mkfifo + tmux pipe-pane，tmux 不存在的 session
  // 会让 execFileSync throw → 包成 attach failed
  ws.send(JSON.stringify({ type: "terminal_attach", session_name: "definitely-nonexistent-xyz-test" }))
  const reply = await nextMsg(ws)
  expect(["terminal_error", "terminal_init"]).toContain(reply.type)
  expect(reply.session_name).toBe("definitely-nonexistent-xyz-test")
  ws.close()
})

test("L4: terminal_input with empty bytes is silently dropped (no crash)", async () => {
  const ws = await openMP()
  // 不期待回包；只确保 hub 不挂
  ws.send(JSON.stringify({ type: "terminal_input", session_name: "mp-cc", bytes: "" }))
  // 给 hub 一点时间处理 + 不挂
  await new Promise(r => setTimeout(r, 100))
  expect(ws.readyState).toBe(WebSocket.OPEN)
  ws.close()
})

test("L4: terminal_resize with out-of-range values is silently dropped", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({ type: "terminal_resize", session_name: "mp-cc", cols: 99999, rows: -1 }))
  await new Promise(r => setTimeout(r, 100))
  expect(ws.readyState).toBe(WebSocket.OPEN)
  ws.close()
})

test("L4: terminal_detach for unknown session is silently dropped", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({ type: "terminal_detach", session_name: "never-attached" }))
  await new Promise(r => setTimeout(r, 100))
  expect(ws.readyState).toBe(WebSocket.OPEN)
  ws.close()
})

test("L4: terminal_paste 回 terminal_paste_result，带回 request_id（#053）", async () => {
  const ws = await openMP()
  ws.send(JSON.stringify({ type: "terminal_paste", session_name: "mp-cc", text: "echo a\necho b", request_id: "r-053" }))
  const reply = await nextMsg(ws)
  expect(reply).toEqual({ type: "terminal_paste_result", session_name: "mp-cc", request_id: "r-053", ok: true })
  ws.close()
})

// ---------- 思考链回传：POST /thinking + 锚定 + 广播 + replay ----------

async function openMCP(): Promise<WebSocket> {
  const ws = new WebSocket(MCP_URL)
  await new Promise<void>((resolve, reject) => {
    ws.on("open", resolve)
    ws.on("error", reject)
    setTimeout(() => reject(new Error("connect timeout")), 2000)
  })
  return ws
}

function postThinking(body: unknown): Promise<Response> {
  return fetch(`http://127.0.0.1:${TEST_PORT}/thinking`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  })
}

test("thinking: invalid json returns 400", async () => {
  const res = await postThinking("not-json{")
  expect(res.status).toBe(400)
  const o = await res.json()
  expect(o.reason).toBe("invalid_json")
})

test("thinking: missing fields returns 400 invalid_body", async () => {
  const res = await postThinking({ chat_id: "conv-x" })
  expect(res.status).toBe(400)
  const o = await res.json()
  expect(o.reason).toBe("invalid_body")
})

test("thinking: no anchor (chat without any reply) is dropped", async () => {
  const res = await postThinking({ chat_id: "conv-never-replied", thinking: "some thought" })
  expect(res.status).toBe(200)
  const o = await res.json()
  expect(o.ok).toBe(false)
  expect(o.reason).toBe("no_anchor")
})

test("thinking: anchored to latest reply mp_msg_id and broadcast to mp clients", async () => {
  const mp = await openMP()
  const mcp = await openMCP()
  const received: any[] = []
  mp.on("message", d => received.push(JSON.parse(d.toString())))

  // 两条 reply：锚必须取最新一条（s_late）
  mcp.send(JSON.stringify({ type: "reply", chat_id: "conv-think", content: "早", mp_msg_id: "s_early" }))
  mcp.send(JSON.stringify({ type: "reply", chat_id: "conv-think", content: "晚", mp_msg_id: "s_late" }))
  // 别的 chat 的 reply 不该被当锚
  mcp.send(JSON.stringify({ type: "reply", chat_id: "conv-other", content: "x", mp_msg_id: "s_other" }))
  await new Promise(r => setTimeout(r, 200))

  const res = await postThinking({ chat_id: "conv-think", thinking: "turn thought summary" })
  const o = await res.json()
  expect(o.ok).toBe(true)
  expect(typeof o.thinking_id).toBe("string")

  await new Promise(r => setTimeout(r, 200))
  const frame = received.find(m => m.type === "thinking")
  expect(frame).toBeDefined()
  expect(frame.chat_id).toBe("conv-think")
  expect(frame.mp_msg_id).toBe("s_late")
  expect(frame.content).toBe("turn thought summary")
  expect(frame.thinking_id).toBe(o.thinking_id)
  mp.close(); mcp.close()
})

test("thinking: replayed to new client after replies", async () => {
  // 上一个 test 已留下 conv-think 的 replies + thinking；新 client 连上应先收 reply 再收 thinking
  // 从连上那一刻就收（hello 之后紧跟着就是 replay，等 openMP 返回再挂监听会漏）
  const mp = new WebSocket(CC_URL)
  const received: any[] = []
  mp.on("message", d => received.push(JSON.parse(d.toString())))
  await new Promise(r => setTimeout(r, 400))
  expect(received[0]?.type).toBe("hello")

  const replyIdx = received.findIndex(m => m.type === "reply" && m.mp_msg_id === "s_late")
  const thinkIdx = received.findIndex(m => m.type === "thinking" && m.mp_msg_id === "s_late")
  expect(replyIdx).toBeGreaterThanOrEqual(0)
  expect(thinkIdx).toBeGreaterThan(replyIdx)
  mp.close()
})

test("thinking: terminal_input → 她那句做成引用块放正文前，s_txt_<turn> 去重", async () => {
  const mp = await openMP()
  const received: any[] = []
  mp.on("message", d => received.push(JSON.parse(d.toString())))
  await new Promise(r => setTimeout(r, 200))
  const body = { session_id: "sess-term", chat_id: "conv-term", thinking: "她在终端找我", reply_text: "在这儿呢", turn_uuid: "term-turn", terminal_input: "我爸比人呢？！\n快出来" }
  const o = await (await postThinking(body)).json()
  expect(o.ok).toBe(true)
  expect(o.replied).toBe("ok")
  await new Promise(r => setTimeout(r, 200))
  const frame = received.find(m => m.type === "reply" && m.mp_msg_id === "s_txt_term-turn")
  expect(frame).toBeDefined()
  expect(frame.content).toBe("> 我爸比人呢？！\n> 快出来\n\n在这儿呢")
  expect(frame.message_id).toBeUndefined()
  const again = await (await postThinking(body)).json()
  expect(again.replied).toBe("dup")
  mp.close()
})

test("thinking: oversize body is rejected", async () => {
  const res = await postThinking({ chat_id: "conv-think", thinking: "x".repeat(1_100_000) }).catch(() => null)
  // hub 413 或直接断连（req.destroy）都算拒绝
  if (res) expect(res.status).toBe(413)
})

// ────────── pasteAwareSendAndEnter（claude code paste mode commit race 防御）──────────
// 见 docs/plan-cc-bridge-paste-commit-race.md。helper 用依赖注入 PasteIO 接口，
// 测试用 spy 验证 send/sleep/capture 顺序和次数，不真调 tmux/sleep。

function makeSpyIO(captureScript: string[]): { io: PasteIO, calls: string[] } {
  const calls: string[] = []
  let captureIdx = 0
  const io: PasteIO = {
    sendLiteral: (text, _session) => { calls.push(`literal:${text.length}`) },
    paste: (text, _session) => { calls.push(`paste:${text.length}`) },
    sendKey: (key, _session) => { calls.push(`key:${key}`) },
    capturePane: (_session) => {
      const ret = captureScript[Math.min(captureIdx, captureScript.length - 1)]
      captureIdx++
      calls.push(`capture→${ret.includes("[Pasted text") ? "stuck" : "clear"}`)
      return ret
    },
    sleep: (s) => { calls.push(`sleep:${s}`) },
  }
  return { io, calls }
}

test("paste-race: short text (<= threshold) uses fast path — no sleep, no capture, no retry", async () => {
  const { io, calls } = makeSpyIO([])
  await pasteAwareSendAndEnter("a".repeat(PASTE_MODE_LENGTH_THRESHOLD), "mp-cc", io)  // 边界 = 不进 paste 路径
  expect(calls).toEqual(["literal:500", "key:Enter"])
})

test("paste-race: long text settles after first capture clean — no retry", async () => {
  const { io, calls } = makeSpyIO(["normal claude UI no placeholder"])
  await pasteAwareSendAndEnter("a".repeat(PASTE_MODE_LENGTH_THRESHOLD + 1), "mp-cc", io)
  expect(calls).toEqual(["paste:501", "sleep:0.5", "key:Enter", "sleep:0.4", "capture→clear"])
})

test("paste-race: long text stuck once, retries Enter, then clears", async () => {
  const { io, calls } = makeSpyIO(["[Pasted text #1] hi", "ok cleared"])
  await pasteAwareSendAndEnter("a".repeat(800), "mp-cc", io)
  // literal + sleep + Enter（首发）+ sleep + capture(stuck) + Enter(retry1) + sleep + capture(clear, return)
  expect(calls).toEqual([
    "paste:800", "sleep:0.5", "key:Enter",
    "sleep:0.4", "capture→stuck", "key:Enter",
    "sleep:0.4", "capture→clear",
  ])
})

test("paste-race: all retries fail — give up after PASTE_RETRY_MAX retries", async () => {
  const stuck = Array(PASTE_RETRY_MAX + 1).fill("[Pasted text #1] stuck")
  const { io, calls } = makeSpyIO(stuck)
  await pasteAwareSendAndEnter("a".repeat(800), "mp-cc", io)
  const enterCount = calls.filter(c => c === "key:Enter").length
  const captureCount = calls.filter(c => c.startsWith("capture→")).length
  expect(enterCount).toBe(1 + PASTE_RETRY_MAX)   // 首发 1 + 3 重试
  expect(captureCount).toBe(PASTE_RETRY_MAX)
})

test("paste-race: short but multi-line → bracketed paste + settle（裸 \\n 打字进去会被当 Enter）", async () => {
  const { io, calls } = makeSpyIO(["normal claude UI no placeholder"])
  await pasteAwareSendAndEnter("第一行\n第二行", "mp-cc", io)
  expect(calls).toEqual(["paste:7", "sleep:0.5", "key:Enter", "sleep:0.4", "capture→clear"])
})

test("paste-race: codex long text also goes through bracketed paste", async () => {
  const { io, calls } = makeSpyIO(["ok"])
  await pasteAwareSendAndEnter("a".repeat(800), "mp-codex-1", io)
  expect(calls[0]).toBe("paste:800")
})

test("paste-race: capture returning empty (session gone) silently breaks retry loop", async () => {
  // 空字符串不包含 [Pasted text → 视为已 clear → return（实际是 session 死了，capture 失败回空）
  const { io, calls } = makeSpyIO(["", ""])
  await pasteAwareSendAndEnter("a".repeat(800), "mp-cc", io)
  expect(calls.filter(c => c === "key:Enter").length).toBe(1)
})

// CR-2 阅读在场信号落盘
test("writeReadingStatus writes snapshot to dir", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-reading-"))
  const ok = writeReadingStatus({ date: "2026-07-06", todaySeconds: 120, currentBook: "b", currentChapter: 3 }, dir)
  expect(ok).toBe(true)
  const written = JSON.parse(require("node:fs").readFileSync(join(dir, "reading-status.json"), "utf8"))
  expect(written.todaySeconds).toBe(120)
})

test("writeReadingStatus rejects oversized payload", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-reading-"))
  const ok = writeReadingStatus({ blob: "x".repeat(20_000) }, dir)
  expect(ok).toBe(false)
})

// L2 单词在场信号

test("writeVocabStatus writes snapshot to dir", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-vocab-"))
  const ok = writeVocabStatus({ date: "2026-07-15", activity: "reviewing", recentWords: ["collateral"], streak: 4 }, dir)
  expect(ok).toBe(true)
  const written = JSON.parse(require("node:fs").readFileSync(join(dir, "vocab-status.json"), "utf8"))
  expect(written.recentWords).toEqual(["collateral"])
})

test("writeVocabStatus rejects oversized payload", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-vocab-"))
  const ok = writeVocabStatus({ blob: "x".repeat(20_000) }, dir)
  expect(ok).toBe(false)
})

/** vocab_status 帧：开 WS 发帧，poll 落盘文件（fire-and-forget 无 ack）。 */
async function sendVocabStatusFrame(status: Record<string, unknown>): Promise<void> {
  const ws = new WebSocket(CC_URL)
  await new Promise<void>((resolve, reject) => {
    ws.on("open", resolve)
    ws.on("error", reject)
    setTimeout(() => reject(new Error("connect timeout")), 2000)
  })
  ws.send(JSON.stringify({ type: "vocab_status", status }))
  await new Promise((r) => setTimeout(r, 300))   // 无 ack，给 hub 处理窗口
  ws.close()
}

test("vocab_status 帧: 开关关（缺省）→ 不落盘", async () => {
  writeFileSync(join(TEST_AGENT_DIR, "config.json"), JSON.stringify({ enabled: true, coRead: { daemon: false, cc: false, vocab: false } }))
  const f = join(TEST_AGENT_DIR, "vocab-status.json")
  if (existsSync(f)) unlinkSync(f)
  await sendVocabStatusFrame({ date: "2026-07-15", streak: 1 })
  expect(existsSync(f)).toBe(false)
})

test("vocab_status 帧: 开关开 → 落盘 agent/vocab-status.json", async () => {
  writeFileSync(join(TEST_AGENT_DIR, "config.json"), JSON.stringify({ enabled: true, coRead: { daemon: false, cc: false, vocab: true } }))
  const f = join(TEST_AGENT_DIR, "vocab-status.json")
  if (existsSync(f)) unlinkSync(f)
  await sendVocabStatusFrame({ date: "2026-07-15", activity: "studying", recentWords: ["clutch", "clumsy"], streak: 2 })
  expect(existsSync(f)).toBe(true)
  const written = JSON.parse(require("node:fs").readFileSync(f, "utf8"))
  expect(written.activity).toBe("studying")
  expect(written.recentWords).toEqual(["clutch", "clumsy"])
})

// 楼层语音设置 → CLAUDE.md 标记块（docs/plan-cc-terminal-mirror.md 二-b）
test("writeVoiceInstructions 只换标记之间，标记外原样；内容没变不写；没标记/非法内容拒绝", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-voice-md-"))
  const file = join(dir, "CLAUDE.md")
  const head = "# 人设\n\n## 语音条\n禾禾手写的写法\n"
  const tail = "\n## 别的段\n不许动\n"
  writeFileSync(file, `${head}${MP_VOICE_BEGIN}\n旧块\n${MP_VOICE_END}${tail}`)
  expect(writeVoiceInstructions("当前楼层语音设置\n- 语音条模型：eleven_v4", file)).toEqual({ ok: true, changed: true })
  const fs = require("node:fs")
  expect(fs.readFileSync(file, "utf8")).toBe(`${head}${MP_VOICE_BEGIN}\n当前楼层语音设置\n- 语音条模型：eleven_v4\n${MP_VOICE_END}${tail}`)
  const mtime = fs.statSync(file).mtimeMs
  expect(writeVoiceInstructions("当前楼层语音设置\n- 语音条模型：eleven_v4", file)).toEqual({ ok: true, changed: false })
  expect(fs.statSync(file).mtimeMs).toBe(mtime)
  expect(fs.readdirSync(dir)).toEqual(["CLAUDE.md"])   // 临时文件 rename 掉了
  expect(writeVoiceInstructions(`x${MP_VOICE_END}`, file)).toEqual({ ok: false, reason: "invalid_content" })
  expect(writeVoiceInstructions("长".repeat(3000), file)).toEqual({ ok: false, reason: "invalid_content" })
  expect(writeVoiceInstructions(42, file)).toEqual({ ok: false, reason: "invalid_content" })
  const bare = join(dir, "bare.md")
  writeFileSync(bare, "没有标记\n")
  expect(writeVoiceInstructions("块", bare)).toEqual({ ok: false, reason: "no_markers" })
  expect(fs.readFileSync(bare, "utf8")).toBe("没有标记\n")
  expect(writeVoiceInstructions("块", join(dir, "missing.md"))).toEqual({ ok: false, reason: "no_markers" })
})

test("set_voice_instructions 帧：写测试工作目录的 CLAUDE.md，回 voice_instructions_result", async () => {
  const file = join(TEST_CC_WORKDIR, "CLAUDE.md")
  writeFileSync(file, `前\n${MP_VOICE_BEGIN}\n${MP_VOICE_END}\n后\n`)
  const mp = await openMP()
  const received: any[] = []
  mp.on("message", d => received.push(JSON.parse(d.toString())))
  const result = async (): Promise<any> => {
    for (let i = 0; i < 20; i++) {
      const r = received.find(m => m.type === "voice_instructions_result")
      if (r) { received.splice(received.indexOf(r), 1); return r }
      await new Promise(r => setTimeout(r, 50))
    }
    return undefined
  }
  mp.send(JSON.stringify({ type: "set_voice_instructions", content: "当前楼层没配声音，不要输出 voice 块。" }))
  expect(await result()).toEqual({ type: "voice_instructions_result", ok: true, changed: true })
  expect(require("node:fs").readFileSync(file, "utf8")).toBe(`前\n${MP_VOICE_BEGIN}\n当前楼层没配声音，不要输出 voice 块。\n${MP_VOICE_END}\n后\n`)
  mp.send(JSON.stringify({ type: "set_voice_instructions", content: "当前楼层没配声音，不要输出 voice 块。" }))
  expect(await result()).toEqual({ type: "voice_instructions_result", ok: true, changed: false })
  writeFileSync(file, "标记被删了\n")
  mp.send(JSON.stringify({ type: "set_voice_instructions", content: "块" }))
  expect(await result()).toEqual({ type: "voice_instructions_result", ok: false, reason: "no_markers" })
  mp.close()
})

// 发语音条：语音条记录追加进 cc-rp
test("appendVoiceNote creates file with header then appends entries", () => {
  const file = join(mkdtempSync(join(tmpdir(), "cc-voice-")), "小克的语音条.md")
  expect(appendVoiceNote({ script: "[softly] 我在。", speaker: "小克", voice: "暖暖", duration: 3.6 }, file)).toBe(true)
  expect(appendVoiceNote({ script: "[rushed] 来了来了。" }, file)).toBe(true)
  const text = require("node:fs").readFileSync(file, "utf8")
  expect(text.startsWith("# 小克的语音条")).toBe(true)
  expect(text).toContain("声音「暖暖」")
  expect(text).toContain("（4 秒）")
  expect(text).toContain("[softly] 我在。")
  expect(text).toContain("[rushed] 来了来了。")
  expect(text.match(/^## /gm)?.length).toBe(2)
})

test("appendVoiceNote 默认写进 CC 工作目录，文件名跟着说话的人（没给 speaker 用推送名）", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-voice-wd-"))
  const prev = process.env.MP_CC_WORKDIR
  process.env.MP_CC_WORKDIR = dir
  try {
    expect(appendVoiceNote({ script: "早。", speaker: "阿青" })).toBe(true)
    expect(appendVoiceNote({ script: "晚安。" })).toBe(true)
    const fs = require("node:fs")
    expect(fs.readFileSync(join(dir, "阿青的语音条.md"), "utf8").startsWith("# 阿青的语音条")).toBe(true)
    expect(fs.readFileSync(join(dir, "助手的语音条.md"), "utf8")).toContain("晚安。")
  } finally {
    if (prev === undefined) delete process.env.MP_CC_WORKDIR
    else process.env.MP_CC_WORKDIR = prev
  }
})

test("appendVoiceNote rejects empty or oversized script", () => {
  const file = join(mkdtempSync(join(tmpdir(), "cc-voice-")), "v.md")
  expect(appendVoiceNote({ script: "" }, file)).toBe(false)
  expect(appendVoiceNote({ script: "x".repeat(5000) }, file)).toBe(false)
  expect(require("node:fs").existsSync(file)).toBe(false)
})

// CR-4 P1 阅读上下文缓存
test("writeReadingContext caches chapter snapshot", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-rctx-"))
  const ok = writeReadingContext({ safeName: "b", bookName: "书", chapter: 5, text: "章节正文", userNotes: [], updatedAt: "t" }, dir)
  expect(ok).toBe(true)
  const w = JSON.parse(require("node:fs").readFileSync(join(dir, "reading-context.json"), "utf8"))
  expect(w.chapter).toBe(5)
  expect(w.text).toBe("章节正文")
})

test("writeReadingContext rejects oversized chapter", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-rctx-"))
  expect(writeReadingContext({ text: "x".repeat(400_000) }, dir)).toBe(false)
})

// CR-4 P1 下行投递闭环
test("deliverBookNote persists pending until ack", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-booknote-"))
  const ok = deliverBookNote({ uuid: "n-1", safeName: "b", notes: [{ anchorText: "a", comment: "c" }] }, dir)
  expect(ok).toBe(true)
  expect(pendingBookNotes(dir).length).toBe(1)
  expect(pendingBookNotes(dir)[0].uuid).toBe("n-1")

  ackBookNote("n-1", dir)
  expect(pendingBookNotes(dir).length).toBe(0)
})

test("deliverBookNote rejects bad uuid", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-booknote-"))
  expect(deliverBookNote({ uuid: "../evil" }, dir)).toBe(false)
  expect(deliverBookNote({ notes: [] }, dir)).toBe(false)
  expect(pendingBookNotes(dir).length).toBe(0)
})

// R5 iOS agent 可见性
test("applyAgentConfigPatch preserves unknown keys (model!)", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-agentcfg-"))
  const fs = require("node:fs")
  fs.writeFileSync(join(dir, "config.json"), JSON.stringify({
    enabled: false, dailyBudgetUSD: 0.5,
    model: { id: "google/gemini-3.1-flash-lite" }, apiKeyAccount: "openrouter",
  }))
  expect(applyAgentConfigPatch({ enabled: true, dailyBudgetUSD: 1.0 }, dir)).toBe(true)
  const after = JSON.parse(fs.readFileSync(join(dir, "config.json"), "utf8"))
  expect(after.enabled).toBe(true)
  expect(after.dailyBudgetUSD).toBe(1.0)
  expect(after.model.id).toBe("google/gemini-3.1-flash-lite")   // 未知键保住（抹字段活雷回归）
  expect(after.apiKeyAccount).toBe("openrouter")
})

test("applyAgentConfigPatch: coRead 开关往返（脏值不当真）", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-agentcfg-"))
  const fs = require("node:fs")
  fs.writeFileSync(join(dir, "config.json"), JSON.stringify({ enabled: true }))
  expect(applyAgentConfigPatch({ coRead: { daemon: true, cc: "yes", vocab: true } }, dir)).toBe(true)
  const after = JSON.parse(fs.readFileSync(join(dir, "config.json"), "utf8"))
  expect(after.coRead).toEqual({ daemon: true, cc: false, vocab: true })
  // 快照带回 coRead（iOS 设置页显示用）
  expect((agentStatusSnapshot(dir).config as any).coRead).toEqual({ daemon: true, cc: false, vocab: true })
})

test("agentStatusSnapshot reads config + activity tail", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-agentstat-"))
  const fs = require("node:fs")
  fs.writeFileSync(join(dir, "config.json"), JSON.stringify({ enabled: true, floors: { f1: true }, dailyBudgetUSD: 0.8 }))
  fs.writeFileSync(join(dir, "activity.jsonl"),
    Array.from({ length: 60 }, (_, i) => JSON.stringify({ ts: `t${i}`, triggerId: "x", status: "ok" })).join("\n") + "\n")
  const snap = agentStatusSnapshot(dir)
  expect((snap.config as any).enabled).toBe(true)
  expect((snap.config as any).dailyBudgetUSD).toBe(0.8)
  expect((snap.activity as any[]).length).toBe(50)   // tail 50
  expect((snap.activity as any[])[0].ts).toBe("t59") // 最新在前
})

// R6 读书模型补丁
test("applyAgentConfigPatch accepts valid model and rejects malformed", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-agentmodel-"))
  const fs = require("node:fs")
  fs.writeFileSync(join(dir, "config.json"), JSON.stringify({ enabled: true }))

  applyAgentConfigPatch({ model: { id: "claude-sonnet-4-5", api: "anthropic-messages", baseUrl: "https://api.anthropic.com", name: "Sonnet" }, apiKeyAccount: "cred-abc" }, dir)
  let after = JSON.parse(fs.readFileSync(join(dir, "config.json"), "utf8"))
  expect(after.model.id).toBe("claude-sonnet-4-5")
  expect(after.apiKeyAccount).toBe("cred-abc")
  expect(after.enabled).toBe(true)

  // 缺 api/baseUrl 的畸形 model 不写入
  applyAgentConfigPatch({ model: { id: "broken" } }, dir)
  after = JSON.parse(fs.readFileSync(join(dir, "config.json"), "utf8"))
  expect(after.model.id).toBe("claude-sonnet-4-5")
})

// R6.1 key 随设置同步（iPhone 卡 key 不在 Mac Keychain 的修复）
test("applyAgentConfigPatch syncs apiKey to keychain, never to config", () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-agentkey-"))
  const fs = require("node:fs")
  fs.writeFileSync(join(dir, "config.json"), JSON.stringify({ enabled: true }))

  const written: Array<[string, string]> = []
  const spy = (account: string, key: string) => { written.push([account, key]); return true }

  applyAgentConfigPatch({ apiKeyAccount: "cred-xyz", apiKey: "sk-secret-123" }, dir, spy)
  expect(written).toEqual([["cred-xyz", "sk-secret-123"]])
  const after = JSON.parse(fs.readFileSync(join(dir, "config.json"), "utf8"))
  expect(after.apiKey).toBeUndefined()          // key 绝不落 config 明文
  expect(after.apiKeyAccount).toBe("cred-xyz")

  // 无 apiKey 的补丁不碰 keychain；缺 account 的 key 也不写
  applyAgentConfigPatch({ enabled: false }, dir, spy)
  applyAgentConfigPatch({ apiKey: "sk-orphan" }, dir, spy)
  expect(written.length).toBe(1)
})

// ────────── 「发两遍」双雷防回归（2026-07-07 粟粟报偶发重复）──────────

// 雷一：文本注入后 Enter/capture 抛错不得外抛——调用方 catch 会重发整条 → 注入两遍
test("pasteAwareSendAndEnter swallows post-inject failures (no rethrow → no double send)", () => {
  const calls: string[] = []
  const io: PasteIO = {
    sendLiteral: (t) => { calls.push("literal") },
    paste: (t) => { calls.push("paste") },
    sendKey: () => { calls.push("key"); throw new Error("tmux flake") },
    capturePane: () => "",
    sleep: () => {},
  }
  // 短文本：Enter 抛错 → 吞掉不外抛
  expect(() => pasteAwareSendAndEnter("hi", "mp-cc", io)).not.toThrow()
  expect(calls).toEqual(["literal", "key"])
  // 长文本：同样不外抛
  calls.length = 0
  expect(() => pasteAwareSendAndEnter("a".repeat(PASTE_MODE_LENGTH_THRESHOLD + 1), "mp-cc", io)).not.toThrow()
  // sendLiteral 本身失败仍要抛（文本没进去，调用方重发是安全且必要的）
  const failInject: PasteIO = { ...io, sendLiteral: () => { throw new Error("inject fail") } }
  expect(() => pasteAwareSendAndEnter("hi", "mp-cc", failInject)).toThrow()
})

// 雷二：mcp-server reply 重试帧（同 mp_msg_id）必须幂等丢弃
test("markReplySeen dedupes retried reply frames by mp_msg_id", () => {
  seenMpMsgIds.clear()
  expect(markReplySeen("s_abc")).toBe(false)   // 首见 → 放行
  expect(markReplySeen("s_abc")).toBe(true)    // 重试帧 → 丢弃
  expect(markReplySeen("s_def")).toBe(false)
  expect(markReplySeen(undefined)).toBe(false) // 老 CC 无 id → 不去重（容旧）
  expect(markReplySeen(undefined)).toBe(false)
  // 滚动淘汰：超 600 剔最老一批，新的仍去重
  seenMpMsgIds.clear()
  for (let i = 0; i < 601; i++) markReplySeen(`s_${i}`)
  expect(seenMpMsgIds.size).toBeLessThanOrEqual(600)
  expect(markReplySeen("s_600")).toBe(true)    // 最新的还在
  seenMpMsgIds.clear()
})

// MARK: POST /agent/book-note（CC 共读批注入口）

const BOOK_NOTE_URL = `http://127.0.0.1:${TEST_PORT}/agent/book-note`
const GOOD_NOTE = { annotations: [{ anchorText: "这一章的正文内容读到这里", comment: "这句我也停了很久" }], message: "" }

function setCoRead(cc: boolean): void {
  writeFileSync(join(TEST_AGENT_DIR, "config.json"), JSON.stringify({ enabled: true, coRead: { daemon: false, cc } }))
}
function writeFreshContext(): void {
  writeFileSync(join(TEST_AGENT_DIR, "reading-context.json"), JSON.stringify({
    floorId: "f1", safeName: "b1", bookName: "测试书", chapter: 3, totalChapters: 10,
    chapterTitle: "第三章", text: "这一章的正文内容读到这里。", userName: "测试用户",
  }))
}

async function postBookNote(body: unknown): Promise<any> {
  const res = await fetch(BOOK_NOTE_URL, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  })
  return res.json()
}

test("book-note: 开关关 → 拒绝且不投递", async () => {
  setCoRead(false)
  writeFreshContext()
  const r = await postBookNote(GOOD_NOTE)
  expect(r.ok).toBe(false)
  expect(r.error).toContain("开关")
})

test("book-note: 开关开 + 今日上下文 → 投递进 pending", async () => {
  setCoRead(true)
  writeFreshContext()
  const r = await postBookNote(GOOD_NOTE)
  expect(r.ok).toBe(true)
  expect(r.book).toBe("测试书")
  expect(r.chapter).toBe(3)
  expect(r.notes).toBe(1)
  const pending = readdirSync(join(TEST_AGENT_DIR, "pending-notes")).filter((f) => f.endsWith(".json"))
  expect(pending.length).toBeGreaterThan(0)
})

test("book-note: 上下文过期（昨天的 mtime）→ 拒绝", async () => {
  setCoRead(true)
  writeFreshContext()
  const yesterday = new Date(Date.now() - 26 * 3600_000)
  utimesSync(join(TEST_AGENT_DIR, "reading-context.json"), yesterday, yesterday)
  const r = await postBookNote(GOOD_NOTE)
  expect(r.ok).toBe(false)
  expect(r.error).toContain("今天")
})

test("book-note: 烂参数 → 拒绝（锚太短/缺 comment）", async () => {
  setCoRead(true)
  writeFreshContext()
  const r = await postBookNote({ annotations: [{ anchorText: "短", comment: "" }] })
  expect(r.ok).toBe(false)
  expect(r.error).toContain("参数")
})

// 光标复位序列（capture-pane 快照不含光标位置——feed 后光标孤悬文本末尾的修复）
test("cursorRestoreSeq builds 1-based CUP and rejects garbage", () => {
  expect(cursorRestoreSeq(0, 0)).toBe("\x1b[1;1H")
  expect(cursorRestoreSeq(4, 37)).toBe("\x1b[38;5H")
  expect(cursorRestoreSeq(-1, 5)).toBe("")
  expect(cursorRestoreSeq(NaN, 2)).toBe("")
})

// ---------- codex bridge（engine 分流） ----------

import { sessionEngine, harvestCodexSessionId } from "./hub.ts"
import { mkdirSync as mkdirSyncCodex, writeFileSync as writeFileSyncCodex } from "node:fs"

test("sessionEngine: mp-codex* → codex, everything else → claude", () => {
  expect(sessionEngine("mp-codex-1")).toBe("codex")
  expect(sessionEngine("mp-codex")).toBe("codex")
  expect(sessionEngine("mp-cc")).toBe("claude")
  expect(sessionEngine("mp-cc-2")).toBe("claude")
})

test("paste-race: codex commits with fingerprint check — clean pane means done", async () => {
  const { io, calls } = makeSpyIO(["ready > _"])   // pane 尾部无指纹 = 已提交
  await pasteAwareSendAndEnter("a".repeat(800), "mp-codex-1", io)
  expect(calls).toEqual(["paste:800", "sleep:0.4", "key:Enter", "sleep:2", "capture→clear"])
})

test("paste-race: codex retries Enter while fingerprint remains in pane tail", async () => {
  const text = "b".repeat(800)
  const stuckPane = `history\n> ${text.slice(-30)}`   // 输入框还躺着文本尾巴
  const { io, calls } = makeSpyIO([stuckPane, "clean pane"])
  await pasteAwareSendAndEnter(text, "mp-codex-1", io)
  // literal → sleep → Enter → sleep → capture(stuck) → Enter(retry) → sleep → capture(clear)
  expect(calls.filter(c => c === "key:Enter")).toHaveLength(2)
})

test("harvestCodexSessionId picks newest rollout matching cwd since spawn time", () => {
  const home = process.env.HOME
  const d = new Date()
  const dir = `${home}/.codex/sessions/${d.getFullYear()}/${String(d.getMonth() + 1).padStart(2, "0")}/${String(d.getDate()).padStart(2, "0")}`
  mkdirSyncCodex(dir, { recursive: true })
  const uuid = "019faaaa-1111-7000-8000-1234567890ab"
  const path = `${dir}/rollout-2026-07-18T00-00-00-${uuid}.jsonl`
  const cwd = mkdtempSync(join(tmpdir(), "codex-harvest-"))
  writeFileSyncCodex(path, JSON.stringify({ payload: { id: uuid, cwd } }) + "\n")
  try {
    expect(harvestCodexSessionId(Date.now() - 60_000, cwd)).toBe(uuid)
    expect(harvestCodexSessionId(Date.now() - 60_000, "/nonexistent/cwd")).toBe(null)   // cwd 不匹配
    expect(harvestCodexSessionId(Date.now() + 60_000, cwd)).toBe(null)                  // spawn 之后无新文件
  } finally {
    unlinkSync(path)
  }
})

// --- Cache keepalive 判定 ---
import { shouldKeepalive, planKeepalive } from "./hub.ts"

const KA = { idleMs: 50 * 60_000, maxIdleMs: 12 * 3_600_000, maxStreak: 6 }
const MIN = 60_000

test("keepalive: idle 不足 50min 不保", () => {
  const now = Date.now()
  expect(shouldKeepalive({ lastUserSendAt: now - 30 * MIN, lastNudgeAt: 0 }, now, KA)).toBe(false)
})

test("keepalive: idle 过 50min 保", () => {
  const now = Date.now()
  expect(shouldKeepalive({ lastUserSendAt: now - 55 * MIN, lastNudgeAt: 0 }, now, KA)).toBe(true)
})

test("keepalive: 上次保暖后重新计时（不连环 ping）", () => {
  const now = Date.now()
  const act = { lastUserSendAt: now - 120 * MIN, lastNudgeAt: 0, lastKeepaliveAt: now - 10 * MIN }
  expect(shouldKeepalive(act, now, KA)).toBe(false)
  act.lastKeepaliveAt = now - 51 * MIN
  expect(shouldKeepalive(act, now, KA)).toBe(true)
})

test("keepalive: nudge 也算 API 活动", () => {
  const now = Date.now()
  expect(shouldKeepalive({ lastUserSendAt: now - 120 * MIN, lastNudgeAt: now - 20 * MIN }, now, KA)).toBe(false)
})

test("keepalive: susu 超 12h 没来 → 放弃保暖", () => {
  const now = Date.now()
  const act = { lastUserSendAt: now - 13 * 3_600_000, lastNudgeAt: 0, lastKeepaliveAt: now - 55 * MIN }
  expect(shouldKeepalive(act, now, KA)).toBe(false)
})

test("keepalive: susu 回来发言后恢复保暖资格", () => {
  const now = Date.now()
  // 昨天断保，刚才她说话了，51min 后又静默 → 恢复保
  const act = { lastUserSendAt: now - 51 * MIN, lastNudgeAt: 0, lastKeepaliveAt: now - 14 * 3_600_000 }
  expect(shouldKeepalive(act, now, KA)).toBe(true)
})

// --- 次数封顶：连保 maxStreak 次人还没回来 → 停（盈亏平衡点 ≈12.5 次，6 次稳在赚的一侧）---
test("keepalive: streak 未到上限继续保", () => {
  const now = Date.now()
  const act = { lastUserSendAt: now - 5 * 3_600_000, lastNudgeAt: 0, lastKeepaliveAt: now - 51 * MIN, keepaliveStreak: 5 }
  expect(shouldKeepalive(act, now, KA)).toBe(true)
})

test("keepalive: streak 到上限 → 停保", () => {
  const now = Date.now()
  const act = { lastUserSendAt: now - 6 * 3_600_000, lastNudgeAt: 0, lastKeepaliveAt: now - 51 * MIN, keepaliveStreak: 6 }
  expect(shouldKeepalive(act, now, KA)).toBe(false)
})

test("keepalive: 她发言重置 streak 后恢复保暖", () => {
  const now = Date.now()
  // 保满 6 次停了，她回来说话 → recordUserActivity 清零 streak → 静默 51min 后重新保
  const act = { lastUserSendAt: now - 51 * MIN, lastNudgeAt: 0, lastKeepaliveAt: now - 3 * 3_600_000, keepaliveStreak: 0 }
  expect(shouldKeepalive(act, now, KA)).toBe(true)
})

// --- 闲置回收：hub 层接线（排除名单 + 绑定保留）；判定细节见 session-reap.test.ts ---
import { reapIdleSessions, sessionMap } from "./hub"

test("reapIdleSessions: transcript 旧 → 回收且 sessionMap 绑定还在；主会话 / 军机处 / 窗口 / 无记录不收", async () => {
  const now = Date.now()
  const bind = (name: string, id: string) => sessionMap.set(name, { claudeSessionId: id, updatedAt: new Date(now).toISOString() })
  bind("mp-cc-reap-old", "reap-old-uuid")
  bind("mp-cc-6", "reap-central-uuid")
  bind("mp-cc", "reap-main-uuid")
  bind("mp-cc-reap-fresh", "reap-fresh-uuid")
  const mtimes: Record<string, number> = {
    "reap-old-uuid": now - 2 * 86_400_000,
    "reap-central-uuid": now - 30 * 86_400_000,
    "reap-main-uuid": now - 30 * 86_400_000,
    "reap-fresh-uuid": now - 3_600_000,
  }
  const mtimeMs = async (path: string) => mtimes[path.split("/").pop()!.replace(".jsonl", "")]
  try {
    const reaped = await reapIdleSessions(
      ["mp-cc-reap-old", "mp-cc-6", "mp-cc", "mp-cc-reap-fresh", "mp-win-abc123", "mp-cc-reap-unknown"], now, mtimeMs,
    )
    expect(reaped).toEqual(["mp-cc-reap-old"])
    expect(sessionMap.get("mp-cc-reap-old")?.claudeSessionId).toBe("reap-old-uuid")
  } finally {
    for (const n of ["mp-cc-reap-old", "mp-cc-6", "mp-cc", "mp-cc-reap-fresh"]) sessionMap.delete(n)
  }
})

// --- 单选最活跃：auto 的会话一次只保一个（她一次只在一个对话框里说话）---
const ALL_AUTO = () => "auto" as const
const ALIVE = () => true

test("planKeepalive: 选 lastUserSendAt 最大的那个", () => {
  const now = Date.now()
  const map = new Map([
    ["mp-cc-a", { lastUserSendAt: now - 3 * 3_600_000, lastNudgeAt: 0 }],
    ["mp-cc-b", { lastUserSendAt: now - 51 * MIN, lastNudgeAt: 0 }],
    ["mp-cc-c", { lastUserSendAt: now - 8 * 3_600_000, lastNudgeAt: 0 }],
  ])
  expect(planKeepalive(map, now, KA, ALIVE, ALL_AUTO)).toEqual(["mp-cc-b"])
})

test("planKeepalive: 第一名不够格 → 这轮不保，不让位给次活跃", () => {
  const now = Date.now()
  // b 最活跃但刚说完话（idle 不足）；a 静默够久但不是第一名 → 都不保
  const map = new Map([
    ["mp-cc-a", { lastUserSendAt: now - 3 * 3_600_000, lastNudgeAt: 0 }],
    ["mp-cc-b", { lastUserSendAt: now - 5 * MIN, lastNudgeAt: 0 }],
  ])
  expect(planKeepalive(map, now, KA, ALIVE, ALL_AUTO)).toEqual([])
})

test("planKeepalive: 跳过 tmux 里已经没了的 session", () => {
  const now = Date.now()
  const map = new Map([
    ["mp-cc-dead", { lastUserSendAt: now - 51 * MIN, lastNudgeAt: 0 }],
    ["mp-cc-live", { lastUserSendAt: now - 2 * 3_600_000, lastNudgeAt: 0 }],
  ])
  expect(planKeepalive(map, now, KA, (s) => s !== "mp-cc-dead", ALL_AUTO)).toEqual(["mp-cc-live"])
})

test("planKeepalive: 全都不够格 → 空", () => {
  const now = Date.now()
  const map = new Map([["mp-cc-a", { lastUserSendAt: now - 2 * MIN, lastNudgeAt: 0 }]])
  expect(planKeepalive(map, now, KA, ALIVE, ALL_AUTO)).toEqual([])
})

// --- per-session 策略：❄️never 跳过 / 🔥always 常驻（不参与单选、无视配额与放弃条件）---
test("policy never: 就算是最活跃的也不保", () => {
  const now = Date.now()
  const map = new Map([
    ["mp-cc-cold", { lastUserSendAt: now - 51 * MIN, lastNudgeAt: 0 }],
    ["mp-cc-warm", { lastUserSendAt: now - 3 * 3_600_000, lastNudgeAt: 0 }],
  ])
  // cold 最活跃但被标 never → 让位给次活跃的 warm（它才是真正该保的那个）
  const plan = planKeepalive(map, now, KA, ALIVE, (s) => (s === "mp-cc-cold" ? "never" : "auto"))
  expect(plan).toEqual(["mp-cc-warm"])
})

test("policy always: 无视 streak 配额", () => {
  const now = Date.now()
  const map = new Map([
    ["mp-cc-pin", { lastUserSendAt: now - 5 * 3_600_000, lastNudgeAt: 0, lastKeepaliveAt: now - 51 * MIN, keepaliveStreak: 99 }],
  ])
  expect(planKeepalive(map, now, KA, ALIVE, () => "always")).toEqual(["mp-cc-pin"])
})

test("policy always: 无视 12h 放弃线", () => {
  const now = Date.now()
  const map = new Map([
    ["mp-cc-pin", { lastUserSendAt: now - 40 * 3_600_000, lastNudgeAt: 0, lastKeepaliveAt: now - 51 * MIN }],
  ])
  expect(planKeepalive(map, now, KA, ALIVE, () => "always")).toEqual(["mp-cc-pin"])
})

test("policy always: 仍受 50min 节流（不连环 ping）", () => {
  const now = Date.now()
  const map = new Map([
    ["mp-cc-pin", { lastUserSendAt: now - 5 * 3_600_000, lastNudgeAt: 0, lastKeepaliveAt: now - 10 * MIN }],
  ])
  expect(planKeepalive(map, now, KA, ALIVE, () => "always")).toEqual([])
})

test("policy always: 多个一起保，且不吃掉 auto 的单选名额", () => {
  const now = Date.now()
  const map = new Map([
    ["mp-cc-pin1", { lastUserSendAt: now - 20 * 3_600_000, lastNudgeAt: 0 }],
    ["mp-cc-pin2", { lastUserSendAt: now - 30 * 3_600_000, lastNudgeAt: 0 }],
    ["mp-cc-auto1", { lastUserSendAt: now - 51 * MIN, lastNudgeAt: 0 }],
    ["mp-cc-auto2", { lastUserSendAt: now - 2 * 3_600_000, lastNudgeAt: 0 }],
  ])
  const plan = planKeepalive(map, now, KA, ALIVE, (s) => (s.startsWith("mp-cc-pin") ? "always" : "auto"))
  // 两个 pin 全保 + auto 里最活跃的 auto1；auto2 落选
  expect(plan.sort()).toEqual(["mp-cc-auto1", "mp-cc-pin1", "mp-cc-pin2"])
})

// ── M2 · Live Activity token 注册链（D6）WS 往返 ──
// 全部落在 TEST_SECRETS（临时目录），跟生产 secrets/ 无关。

async function openCC(): Promise<InstanceType<typeof WebSocket>> {
  return openMP()
}

test("register_la_token → TEST_SECRETS/la-tokens.json 出现且内容对，push-tokens.json 未被创建/修改", async () => {
  const laPath = join(TEST_SECRETS, "la-tokens.json")
  const pushPath = join(TEST_SECRETS, "push-tokens.json")
  const pushBefore = existsSync(pushPath) ? await Bun.file(pushPath).text() : null

  const ws = await openCC()
  ws.send(JSON.stringify({
    type: "register_la_token", kind: "update",
    activity_id: "ACT-WS", token: "0011223344556677", session_name: "mp-cc",
    install_id: "INSTALL-WS", env: "sandbox", preview: "full",
  }))
  ws.send(JSON.stringify({
    type: "register_la_token", kind: "start",
    token: "8899aabbccddeeff", install_id: "INSTALL-WS", env: "sandbox",
  }))

  const deadline = Date.now() + 3000
  let store: any = null
  while (Date.now() < deadline) {
    if (existsSync(laPath)) {
      store = await Bun.file(laPath).json()
      if (store?.update?.["ACT-WS"] && store?.start?.["INSTALL-WS"]) break
    }
    await new Promise(r => setTimeout(r, 50))
  }
  expect(store?.update?.["ACT-WS"]?.token).toBe("0011223344556677")
  expect(store?.update?.["ACT-WS"]?.session_name).toBe("mp-cc")
  expect(store?.update?.["ACT-WS"]?.preview).toBe("full")
  expect(store?.update?.["ACT-WS"]?.env).toBe("sandbox")
  // preview 缺字段 → hidden（LA 路径缺省往安全倒）
  expect(store?.start?.["INSTALL-WS"]?.token).toBe("8899aabbccddeeff")
  expect(store?.start?.["INSTALL-WS"]?.preview).toBe("hidden")

  const pushAfter = existsSync(pushPath) ? await Bun.file(pushPath).text() : null
  expect(pushAfter).toEqual(pushBefore)
  ws.close()
})

test("register_la_token env 非法 → 回 la_token_nak，不落表", async () => {
  const ws = await openCC()
  const nak = new Promise<any>((resolve, reject) => {
    ws.on("message", (raw: any) => {
      const msg = JSON.parse(raw.toString())
      if (msg.type === "la_token_nak") resolve(msg)
    })
    setTimeout(() => reject(new Error("no la_token_nak within 3s")), 3000)
  })
  ws.send(JSON.stringify({
    type: "register_la_token", kind: "update",
    activity_id: "ACT-BAD", token: "deadbeef", session_name: "mp-cc",
    install_id: "INSTALL-WS", env: "staging", preview: "full",
  }))
  const msg = await nak
  expect(msg.kind).toBe("update")
  expect(msg.activity_id).toBe("ACT-BAD")
  expect(msg.reason).toContain("bad_env")

  const store = await Bun.file(join(TEST_SECRETS, "la-tokens.json")).json()
  expect(store.update["ACT-BAD"]).toBeUndefined()
  ws.close()
})

// ── M3b · /la/push 按 activity_id 从 store 取 token/env ──
// APNs 走 cert-missing（harness 钉了不存在的 .p8）→ 不发真流量，只验路由与取值。

test("/la/push 带 activity_id → 从 la-tokens.json 取记录（不是 400 invalid_body）", async () => {
  const ws = await openCC()
  ws.send(JSON.stringify({
    type: "register_la_token", kind: "update",
    activity_id: "ACT-PUSH", token: "cafebabe", session_name: "mp-cc",
    install_id: "INSTALL-WS", env: "sandbox", preview: "hidden",
  }))
  const laPath = join(TEST_SECRETS, "la-tokens.json")
  const deadline = Date.now() + 3000
  while (Date.now() < deadline) {
    if (existsSync(laPath) && (await pollJSON(laPath)).update?.["ACT-PUSH"]) break
    await new Promise(r => setTimeout(r, 50))
  }

  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/la/push?token=test-token`, {
    method: "POST",
    body: JSON.stringify({ activity_id: "ACT-PUSH", state: { phase: "working" } }),
  })
  expect(res.status).toBe(200)
  const body = await res.json() as { ok: boolean; reason?: string }
  expect(body.ok).toBe(false)
  expect(body.reason).toBe("cert-missing")   // 走到了真正的发送调用 = token/env 取到了
  ws.close()
})

test("/la/push 带未注册的 activity_id → 404，不落到发送", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/la/push?token=test-token`, {
    method: "POST",
    body: JSON.stringify({ activity_id: "ACT-NOPE", state: { phase: "idle" } }),
  })
  expect(res.status).toBe(404)
  expect((await res.json() as { reason: string }).reason).toBe("unknown_activity_id")
})

test("/la/push 直接给 token 的老形态仍在（M3a 不回归）", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/la/push?token=test-token`, {
    method: "POST",
    body: JSON.stringify({ token: "0011223344556677", env: "sandbox", state: { phase: "done" } }),
  })
  expect(res.status).toBe(200)
  expect((await res.json() as { reason?: string }).reason).toBe("cert-missing")
})

// ── M4a · /la/push 的 phase_event 驱动状态机（不开 CC 也能走完四态）──
// detail 是**每 activity** 的隐私决定：同一 session 的两台设备，full 的看得见题面、hidden 的看不见。

test("/la/push phase_event：四态跳变 + detail 受该记录的 preview 控制", async () => {
  const laPath = join(TEST_SECRETS, "la-tokens.json")
  const ws = await openCC()
  ws.send(JSON.stringify({
    type: "register_la_token", kind: "update",
    activity_id: "ACT-PHASE-FULL", token: "aaaabbbbccccdddd", session_name: "mp-cc-phase",
    install_id: "INSTALL-PHASE", env: "sandbox", preview: "full",
  }))
  ws.send(JSON.stringify({
    type: "register_la_token", kind: "update",
    activity_id: "ACT-PHASE-HIDDEN", token: "eeeeffff00001111", session_name: "mp-cc-phase",
    install_id: "INSTALL-PHASE2", env: "sandbox", preview: "hidden",
  }))
  const deadline = Date.now() + 3000
  while (Date.now() < deadline) {
    if (existsSync(laPath)) {
      const st = await Bun.file(laPath).json()
      if (st.update?.["ACT-PHASE-FULL"] && st.update?.["ACT-PHASE-HIDDEN"]) break
    }
    await new Promise(r => setTimeout(r, 50))
  }
  const fire = async (activity_id: string, phase_event: string, extra: object = {}) => {
    const res = await fetch(`http://127.0.0.1:${TEST_PORT}/la/push?token=test-token`, {
      method: "POST", body: JSON.stringify({ activity_id, phase_event, ...extra }),
    })
    expect(res.status).toBe(200)
    return await res.json() as { phase: string; run_id?: string; changed: boolean; state?: Record<string, unknown> }
  }

  const working = await fire("ACT-PHASE-FULL", "send")
  expect(working.phase).toBe("working")
  expect(working.changed).toBe(true)
  expect(working.run_id).toMatch(/^r-\d+-\d+$/)
  expect(working.state?.detail).toBeUndefined()

  // preview=full → 题面首行进 payload（多行只取首行）
  const waiting = await fire("ACT-PHASE-FULL", "ask_pre", { detail: "要不要现在装包？\n第二行不该出现" })
  expect(waiting.phase).toBe("waiting")
  expect(waiting.state?.detail).toBe("要不要现在装包？")
  expect(waiting.run_id).toBe(working.run_id)              // 同一轮不换 run_id
  expect(waiting.state?.since_unix).toBe(working.state?.since_unix)   // since_unix 只在 send 设

  // preview=hidden 的同 session 记录：状态照给，正文不给
  const back = await fire("ACT-PHASE-HIDDEN", "ask_post")
  expect(back.phase).toBe("working")
  expect(back.changed).toBe(true)
  const waitingHidden = await fire("ACT-PHASE-HIDDEN", "ask_pre", { detail: "要不要现在装包？" })
  expect(waitingHidden.phase).toBe("waiting")
  expect(waitingHidden.changed).toBe(true)
  expect(waitingHidden.state?.detail).toBeUndefined()
  expect(waitingHidden.state?.phase).toBe("waiting")

  // pending 未清的 reply 不夺走 waiting；清了才 done latch
  const stillWaiting = await fire("ACT-PHASE-FULL", "reply", { pending_remains: true })
  expect(stillWaiting.phase).toBe("waiting")
  expect(stillWaiting.changed).toBe(false)
  const done = await fire("ACT-PHASE-FULL", "reply")
  expect(done.phase).toBe("done")
  expect(done.run_id).toBe(working.run_id)

  // 重复事件不跳变 → 不发 priority 10
  expect((await fire("ACT-PHASE-FULL", "reply")).changed).toBe(false)

  // 下一轮：新 run_id
  const nextRound = await fire("ACT-PHASE-FULL", "send")
  expect(nextRound.phase).toBe("working")
  expect(nextRound.run_id).not.toBe(working.run_id)
  ws.close()
})

test("/la/push phase_event 认不出 session → 400，不猜", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/la/push?token=test-token`, {
    method: "POST", body: JSON.stringify({ phase_event: "send" }),
  })
  expect(res.status).toBe(400)
  expect((await res.json() as { reason: string }).reason).toBe("invalid_phase_event")
})

test("/la/push phase_event 非法值 → 400", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/la/push?token=test-token`, {
    method: "POST", body: JSON.stringify({ session_name: "mp-cc-phase", phase_event: "bogus" }),
  })
  expect(res.status).toBe(400)
})

// ── M5 ⑥ · /la/lifecycle 改成 loopback 免鉴权 ──
// Stop hook 跑在 tmux 里拿不到 MP_CC_HUB_TOKEN，带 ?token= 的版本永远 401，
// 岛就永远卡在 working。改完必须能不带 token 走通。

test("/la/lifecycle 不带 ?token= 也能进（不再 401）", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/la/lifecycle`, {
    method: "POST", body: JSON.stringify({ event: "stop", session_id: "no-such-claude-session" }),
  })
  expect(res.status).toBe(200)
  // 认不出 session 是 M4b 的既有行为（不猜）；能拿到这个 reason 就说明过了守卫
  expect((await res.json() as { reason?: string }).reason).toBe("no_session_for_id")
})

test("/la/lifecycle 仍拒非法 body / 未知 event", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/la/lifecycle`, {
    method: "POST", body: JSON.stringify({ event: "bogus" }),
  })
  expect(res.status).toBe(400)
  expect((await res.json() as { reason: string }).reason).toBe("unknown_event")
})

// ── M5 ③ · /la/push 的 event:"start" 直通 ──
// start token 按 install_id 存，没有 activity_id；APNs 仍走 cert-missing（不发真流量），
// 拿到 cert-missing = 路由/取值都到了真正的发送调用。

test("/la/push event:start 带 install_id → 从 start store 取 token/env", async () => {
  const laPath = join(TEST_SECRETS, "la-tokens.json")
  const ws = await openCC()
  ws.send(JSON.stringify({
    type: "register_la_token", kind: "start",
    token: "5555666677778888", install_id: "INSTALL-START", env: "sandbox", preview: "hidden",
  }))
  const deadline = Date.now() + 3000
  while (Date.now() < deadline) {
    if (existsSync(laPath) && (await pollJSON(laPath)).start?.["INSTALL-START"]) break
    await new Promise(r => setTimeout(r, 50))
  }
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/la/push?token=test-token`, {
    method: "POST",
    body: JSON.stringify({
      install_id: "INSTALL-START", event: "start",
      session_name: "mp-cc-start", state: { phase: "working" },
    }),
  })
  expect(res.status).toBe(200)
  expect((await res.json() as { reason?: string }).reason).toBe("cert-missing")
  ws.close()
})

test("/la/push event:start 未注册的 install_id → 404", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/la/push?token=test-token`, {
    method: "POST",
    body: JSON.stringify({ install_id: "INSTALL-NOPE", event: "start", session_name: "s", state: { phase: "working" } }),
  })
  expect(res.status).toBe(404)
  expect((await res.json() as { reason: string }).reason).toBe("unknown_install_id")
})

test("/la/push event:start 直接给 token 也行（M3a 老形态）", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/la/push?token=test-token`, {
    method: "POST",
    body: JSON.stringify({ token: "99aabbccddeeff00", env: "sandbox", event: "start", session_name: "mp-cc-start", state: { phase: "waiting" } }),
  })
  expect(res.status).toBe(200)
  expect((await res.json() as { reason?: string }).reason).toBe("cert-missing")
})

test("/la/push event:start 没有 session_name → 400，不猜岛属于谁", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/la/push?token=test-token`, {
    method: "POST",
    body: JSON.stringify({ token: "99aabbccddeeff00", event: "start", state: { phase: "working" } }),
  })
  expect(res.status).toBe(400)
  expect((await res.json() as { reason: string }).reason).toBe("missing_session_name")
})

test("unregister_la_token → 记录被删，另一条不受影响", async () => {
  const laPath = join(TEST_SECRETS, "la-tokens.json")
  const ws = await openCC()
  ws.send(JSON.stringify({ type: "unregister_la_token", kind: "update", activity_id: "ACT-WS" }))

  const deadline = Date.now() + 3000
  let store: any = null
  while (Date.now() < deadline) {
    store = await Bun.file(laPath).json()
    if (!store.update["ACT-WS"]) break
    await new Promise(r => setTimeout(r, 50))
  }
  expect(store.update["ACT-WS"]).toBeUndefined()
  expect(store.start["INSTALL-WS"]?.token).toBe("8899aabbccddeeff")
  ws.close()
})

// ── M4b2 ③ · la_query 往返（app 冷启动对账）──
// 「活」= LA store 有该 update 记录。phase 表缺条目时按 idle 报（08-30 真机实撞修正：
// 原「两条件同时成立」会在 hub 重启 / DEBUG 起岛后误报死亡，app 把粟粟刚起的岛 end 掉了）。

test("la_query → 注册且有 phase 的回快照，没注册的回 null", async () => {
  const laPath = join(TEST_SECRETS, "la-tokens.json")
  const ws = await openCC()
  ws.send(JSON.stringify({
    type: "register_la_token", kind: "update",
    activity_id: "ACT-Q1", token: "1122334455667788", session_name: "mp-cc-query",
    install_id: "INSTALL-Q", env: "sandbox", preview: "hidden",
  }))
  const deadline = Date.now() + 3000
  while (Date.now() < deadline) {
    if (existsSync(laPath) && (await pollJSON(laPath)).update?.["ACT-Q1"]) break
    await new Promise(r => setTimeout(r, 50))
  }
  // phase 表这一格由状态机写；调试口走一次 send 事件把 mp-cc-query 送进 working。
  const phaseRes = await fetch(`http://127.0.0.1:${TEST_PORT}/la/push?token=test-token`, {
    method: "POST", body: JSON.stringify({ activity_id: "ACT-Q1", phase_event: "send" }),
  })
  expect((await phaseRes.json() as { phase?: string }).phase).toBe("working")

  const result = new Promise<any>((resolve, reject) => {
    ws.on("message", (raw: any) => {
      const msg = JSON.parse(raw.toString())
      if (msg.type === "la_query_result") resolve(msg)
    })
    setTimeout(() => reject(new Error("no la_query_result within 3s")), 3000)
  })
  ws.send(JSON.stringify({ type: "la_query", activity_ids: ["ACT-Q1", "ACT-GHOST"] }))
  const msg = await result
  expect(msg.alive["ACT-Q1"]).toMatchObject({ phase: "working", session_name: "mp-cc-query" })
  expect(typeof msg.alive["ACT-Q1"].run_id).toBe("string")
  // 键必须在（app 靠「回了但值是 null」判死），值必须是 null
  expect(Object.keys(msg.alive)).toContain("ACT-GHOST")
  expect(msg.alive["ACT-GHOST"]).toBeNull()
  ws.close()
})

test("la_query 只注册没 phase → 回 idle 快照（有 token 记录就算活；hub 重启/DEBUG 岛不误杀）", async () => {
  const laPath = join(TEST_SECRETS, "la-tokens.json")
  const ws = await openCC()
  ws.send(JSON.stringify({
    type: "register_la_token", kind: "update",
    activity_id: "ACT-Q2", token: "2233445566778899", session_name: "mp-cc-no-phase",
    install_id: "INSTALL-Q", env: "sandbox", preview: "hidden",
  }))
  const deadline = Date.now() + 3000
  while (Date.now() < deadline) {
    if (existsSync(laPath) && (await pollJSON(laPath)).update?.["ACT-Q2"]) break
    await new Promise(r => setTimeout(r, 50))
  }
  const result = new Promise<any>((resolve, reject) => {
    ws.on("message", (raw: any) => {
      const msg = JSON.parse(raw.toString())
      if (msg.type === "la_query_result") resolve(msg)
    })
    setTimeout(() => reject(new Error("no la_query_result within 3s")), 3000)
  })
  ws.send(JSON.stringify({ type: "la_query", activity_ids: ["ACT-Q2"] }))
  const alive = (await result).alive["ACT-Q2"]
  expect(alive).toMatchObject({ phase: "idle", session_name: "mp-cc-no-phase" })
  expect(alive.run_id).toBeUndefined()
  ws.close()
})

// ── 双传输开关收编（09-04）：开关是唯一真相 ──
import { test as testReconcile, expect as expectReconcile } from "bun:test"
testReconcile("planStreamReconcile：关→tmux 空闲即收、忙的等本轮、已挂等的不重复；开→stream 取消挂等", () => {
  const live = [{ name: "a", busy: false }, { name: "b", busy: true }, { name: "c", busy: true }]
  expectReconcile(planStreamReconcile("tmux", live, ["c"])).toEqual({ retireNow: ["a"], retireLater: ["b"], cancel: [] })
  expectReconcile(planStreamReconcile("stream", live, ["b", "c"])).toEqual({ retireNow: [], retireLater: [], cancel: ["b", "c"] })
  expectReconcile(planStreamReconcile("tmux", [], [])).toEqual({ retireNow: [], retireLater: [], cancel: [] })
})

// ---------- REPLY_VIA_TEXT：Stop hook 投当轮正文 → 按 reply 落库广播，thinking 锚到它 ----------
test("thinking+reply_text: 先广播 reply 帧再广播 thinking 帧，锚定到 s_txt_<turn>", async () => {
  const mp = await openMP()
  const received: any[] = []
  mp.on("message", d => received.push(JSON.parse(d.toString())))
  await new Promise(r => setTimeout(r, 100))
  const res = await postThinking({ chat_id: "conv-txt", session_id: "sess-unbound", reply_text: "在的，怎么了", message_id: "m-in", turn_uuid: "turn-1", thinking: "想一下" })
  expect(res.status).toBe(200)
  const o = await res.json()
  expect(o.ok).toBe(true)
  expect(o.replied).toBe("ok")
  await new Promise(r => setTimeout(r, 200))
  const reply = received.find(m => m.type === "reply" && m.chat_id === "conv-txt")
  expect(reply).toBeDefined()
  expect(reply.content).toBe("在的，怎么了")
  expect(reply.message_id).toBe("m-in")
  expect(reply.mp_msg_id).toBe("s_txt_turn-1")
  const think = received.find(m => m.type === "thinking" && m.chat_id === "conv-txt")
  expect(think).toBeDefined()
  expect(think.mp_msg_id).toBe("s_txt_turn-1")
  // 同一 turn 重投 → dup，不再广播
  const before = received.filter(m => m.type === "reply" && m.chat_id === "conv-txt").length
  const res2 = await postThinking({ chat_id: "conv-txt", session_id: "sess-unbound", reply_text: "在的，怎么了", turn_uuid: "turn-1" })
  expect((await res2.json()).replied).toBe("dup")
  await new Promise(r => setTimeout(r, 200))
  expect(received.filter(m => m.type === "reply" && m.chat_id === "conv-txt").length).toBe(before)
  mp.close()
})

// ---------- 10-11 按段去重：读早了少段只补缺的段，读到旧轮的段不重发 ----------
test("rows：先投前两段，补读到全轮只投第三段；再来一遍是 dup（不吞也不重复）", async () => {
  const mp = await openMP()
  const got: any[] = []
  mp.on("message", d => got.push(JSON.parse(d.toString())))
  await new Promise(r => setTimeout(r, 100))
  const A = { uuid: "row-a", text: "正在逐块放大读那三张图" }, B = { uuid: "row-b", text: "Files are in place." }, C = { uuid: "row-c", text: "图存好了" }
  // Stop hook 读早了：只有前两段旁白
  let o = await (await postThinking({ chat_id: "conv-rows", session_id: "sess-unbound", rows: [A, B], reply_text: "x", turn_uuid: "row-b", thinking: "想" })).json()
  expect(o.replied).toBe("ok")
  // 轮末兜底读到全轮（老逻辑会换 uuid 整轮重发 → 前两段重复）
  o = await (await postThinking({ chat_id: "conv-rows", session_id: "sess-unbound", rows: [A, B, C] })).json()
  expect(o.replied).toBe("ok")
  // 同一轮第三次（重复 Stop / 待投补投）
  o = await (await postThinking({ chat_id: "conv-rows", session_id: "sess-unbound", rows: [A, B, C] })).json()
  expect(o.replied).toBe("dup")
  await new Promise(r => setTimeout(r, 200))
  const replies = got.filter(m => m.type === "reply" && m.chat_id === "conv-rows")
  expect(replies.map(m => [m.mp_msg_id, m.content])).toEqual([
    ["s_txt_row-b", "正在逐块放大读那三张图\n\nFiles are in place."],
    ["s_txt_row-c", "图存好了"],
  ])
  mp.close()
})

test("rows：跨会话消息叫醒的一轮（isMeta，不算新一轮）带着上一轮的段 → 只投新段", async () => {
  const mp = await openMP()
  const got: any[] = []
  mp.on("message", d => got.push(JSON.parse(d.toString())))
  await new Promise(r => setTimeout(r, 100))
  // 上一轮老 hook 投的：只带 reply_text + 最后一段 uuid
  await postThinking({ chat_id: "conv-meta", session_id: "sess-unbound", reply_text: "上一轮的话", turn_uuid: "meta-e" })
  const o = await (await postThinking({ chat_id: "conv-meta", session_id: "sess-unbound", rows: [{ uuid: "meta-e", text: "上一轮的话" }, { uuid: "meta-n", text: "工作爸比查清了" }] })).json()
  expect(o.replied).toBe("ok")
  await new Promise(r => setTimeout(r, 200))
  expect(got.filter(m => m.type === "reply" && m.chat_id === "conv-meta").map(m => m.content)).toEqual(["上一轮的话", "工作爸比查清了"])
  mp.close()
})

test("rows：终端轮的引用块只挂第一条，补投的后几段不再挂", async () => {
  const mp = await openMP()
  const got: any[] = []
  mp.on("message", d => got.push(JSON.parse(d.toString())))
  await new Promise(r => setTimeout(r, 100))
  await postThinking({ chat_id: "conv-rterm", session_id: "sess-unbound", terminal_input: "在吗", rows: [{ uuid: "rt-1", text: "在" }] })
  await postThinking({ chat_id: "conv-rterm", session_id: "sess-unbound", terminal_input: "在吗", rows: [{ uuid: "rt-1", text: "在" }, { uuid: "rt-2", text: "怎么了" }] })
  await new Promise(r => setTimeout(r, 200))
  expect(got.filter(m => m.type === "reply" && m.chat_id === "conv-rterm").map(m => m.content)).toEqual(["> 在吗\n\n在", "怎么了"])
  mp.close()
})

test("轮末兜底（10-11 实例）：一轮带大图撑过 4MB、hook 只投了前两段 → 兜底找得到本轮，只补最后一段、不再挂 thinking", async () => {
  const { turnSafetyNetCheck } = await import("./hub.ts")
  const dir = mkdtempSync(join(tmpdir(), "safety-net-"))
  const path = join(dir, "t.jsonl")
  const L = (o: object) => JSON.stringify(o)
  const asst = (uuid: string, content: object[], stop_reason: string) => L({ type: "assistant", uuid, message: { role: "assistant", stop_reason, content } })
  const img = L({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "x", content: [{ type: "image", source: { data: "A".repeat(5 << 20) } }] }] } })
  writeFileSync(path, [
    L({ type: "user", message: { role: "user", content: `<channel source="memorypalace" chat_id="conv-net" message_id="m-net" user="s" ts="t">存图</channel>` } }),
    asst("net-t", [{ type: "thinking", thinking: "想" }], "tool_use"),
    asst("net-a", [{ type: "text", text: "正在逐块放大读那三张图" }], "tool_use"),
    img,
    asst("net-b", [{ type: "text", text: "Files are in place." }], "tool_use"),
    asst("net-c", [{ type: "text", text: "图存好了" }], "end_turn"),
  ].join("\n") + "\n")
  markReplySeen("s_txt_net-b")   // hook 读早了投的那条（老 hook 只记最后一段的 id）
  const c = await turnSafetyNetCheck(path, "sess-net")
  expect(c?.fresh).toEqual([{ uuid: "net-c", text: "图存好了" }])
  expect(c?.post.chat_id).toBe("conv-net")
  expect(c?.post.thinking).toBeUndefined()
  markReplySeen("s_txt_net-c")
  expect(await turnSafetyNetCheck(path, "sess-net")).toBeNull()
})

test("轮末兜底钉轮（10-11 审）：上一轮漏了最后一段，20s 内她又发了一条 → 补的仍是上一轮那段", async () => {
  const { turnSafetyNetCheck } = await import("./hub.ts")
  const dir = mkdtempSync(join(tmpdir(), "safety-pin-"))
  const path = join(dir, "t.jsonl")
  const L = (o: object) => JSON.stringify(o)
  const chan = (c: string, m: string) => L({ type: "user", message: { role: "user", content: `<channel source="memorypalace" chat_id="${c}" message_id="${m}" user="s" ts="t">hi</channel>` } })
  const asst = (uuid: string, text: string) => L({ type: "assistant", uuid, message: { role: "assistant", content: [{ type: "text", text }] } })
  const head = [chan("conv-pin1", "m1"), asst("pin-a", "旁白")].join("\n") + "\n"
  const pin = Buffer.byteLength(head)   // Stop 那一刻转录的长度
  writeFileSync(path, head + [asst("pin-b", "最后一段"), chan("conv-pin2", "m2"), asst("pin-c", "下一轮的话")].join("\n") + "\n")
  markReplySeen("s_txt_pin-a")   // hook 读早了只投了旁白
  const c = await turnSafetyNetCheck(path, "sess-pin", pin)
  expect(c?.post.chat_id).toBe("conv-pin1")
  expect(c?.post.message_id).toBe("m1")
  expect(c?.fresh).toEqual([{ uuid: "pin-b", text: "最后一段" }])
})

test("rows 超 20000 字：只投完整放得下的段，剩下的不记投过，下次补投能补上", async () => {
  const mp = await openMP()
  const got: any[] = []
  mp.on("message", d => got.push(JSON.parse(d.toString())))
  await new Promise(r => setTimeout(r, 100))
  const A = { uuid: "big-a", text: "甲".repeat(15_000) }, B = { uuid: "big-b", text: "乙".repeat(15_000) }
  expect((await (await postThinking({ chat_id: "conv-big", session_id: "sess-unbound", rows: [A, B] })).json()).replied).toBe("ok")
  expect((await (await postThinking({ chat_id: "conv-big", session_id: "sess-unbound", rows: [A, B] })).json()).replied).toBe("ok")
  expect((await (await postThinking({ chat_id: "conv-big", session_id: "sess-unbound", rows: [A, B] })).json()).replied).toBe("dup")
  // 单段自己超限：截断后照样记投过（不然永远发不出去）
  const H = { uuid: "huge", text: "丙".repeat(25_000) }
  expect((await (await postThinking({ chat_id: "conv-big", session_id: "sess-unbound", rows: [H] })).json()).replied).toBe("ok")
  expect((await (await postThinking({ chat_id: "conv-big", session_id: "sess-unbound", rows: [H] })).json()).replied).toBe("dup")
  await new Promise(r => setTimeout(r, 200))
  const replies = got.filter(m => m.type === "reply" && m.chat_id === "conv-big")
  expect(replies.map(m => [m.mp_msg_id, m.content.length])).toEqual([["s_txt_big-a", 15_000], ["s_txt_big-b", 15_000], ["s_txt_huge", 20_000 + " …[截断]".length]])
  const log = JSON.parse(await Bun.file(join(TEST_SECRETS, "reply-log.json")).text())
  expect(log.find((r: any) => r.mpMsgId === "s_txt_big-a").rowUuids).toEqual(["big-a"])
  mp.close()
})

test("hub 重启后从 reply-log 补回去重集合：重启前投过的一轮再来是 dup（10-09 18:14 同 id 两个 reply_id）", async () => {
  const { seedSeenFromReplies } = await import("./hub.ts")
  expect(seenMpMsgIds.has("s_txt_preseed-turn")).toBe(false)
  seedSeenFromReplies([{ mpMsgId: "s_txt_preseed-turn" }, {}, { mpMsgId: "s_txt_pre-c", rowUuids: ["pre-a", "pre-b", "pre-c"] }])
  expect(markReplySeen("s_txt_preseed-turn")).toBe(true)
  expect(markReplySeen("s_txt_pre-a")).toBe(true)   // 合成一条发的前段也补回来
  expect(markReplySeen("s_txt_pre-b")).toBe(true)
})

test("thinking 待投目录：hub 启动后自动补投并删文件", async () => {
  const f = join(TEST_SECRETS, "spool", "0001-spool-turn.json")
  for (let i = 0; i < 40 && existsSync(f); i++) await new Promise(r => setTimeout(r, 250))
  expect(existsSync(f)).toBe(false)
  const log = JSON.parse(await Bun.file(join(TEST_SECRETS, "reply-log.json")).text())
  expect(log.some((r: any) => r.mpMsgId === "s_txt_spool-turn" && r.content === "待投补发")).toBe(true)
}, 20_000)

// 本地推特固定发手机（粟粟 2026-09-24）：只挑报过 platform=ios 的连接，多个取最近有动静的
test("pickPhoneClient: 只选 iOS，取最近活跃；没有手机就 null", async () => {
  const { pickPhoneClient } = await import("./hub.ts")
  const mac = { readyState: 1, OPEN: 1 }, phoneOld = { readyState: 1, OPEN: 1 }, phoneNew = { readyState: 1, OPEN: 1 }, closed = { readyState: 3, OPEN: 1 }
  const info = new Map<any, any>([
    [mac, { platform: "macos", lastSeen: 300 }],
    [phoneOld, { platform: "ios", lastSeen: 100 }],
    [phoneNew, { platform: "ios", lastSeen: 200 }],
    [closed, { platform: "ios", lastSeen: 999 }],
  ])
  expect(pickPhoneClient([mac, phoneOld, phoneNew, closed] as any, info)).toBe(phoneNew as any)
  expect(pickPhoneClient([mac] as any, info)).toBeNull()
  expect(pickPhoneClient([{ readyState: 1, OPEN: 1 }] as any, info)).toBeNull()   // 旧版 app 没报 platform
})

// 进度卡 B（粟粟 10-03）：报过到的 app 连接收得到 CC 会话 phase；没报到的（脚本 / 老 app）不插队
test("session_phase：client_info 报到后 send → 收到 working 帧", async () => {
  const ws = await openMP()
  const frames: any[] = []
  ws.on("message", d => frames.push(JSON.parse(d.toString())))
  ws.send(JSON.stringify({ type: "client_info", platform: "ios" }))
  await new Promise(r => setTimeout(r, 50))
  ws.send(JSON.stringify({ type: "send", chat_id: "conv-phase", message_id: "m-phase-1", content: "hi", user: "susu", session_name: "mp-phase-t" }))
  await new Promise(r => setTimeout(r, 150))
  const phase = frames.find(f => f.type === "session_phase" && f.session_name === "mp-phase-t")
  expect(phase?.phase).toBe("working")
  expect(phase?.chat_id).toBe("conv-phase")
  expect(typeof phase?.since_unix).toBe("number")
  expect(frames.some(f => f.type === "ack" && f.message_id === "m-phase-1")).toBe(true)
  ws.close()
})

test("voice call MCP requires session binding and returns a correlated failure", async () => {
  const ws = new WebSocket(MCP_URL)
  await new Promise<void>((resolve, reject) => { ws.once("open", resolve); ws.once("error", reject) })
  try {
    const response = new Promise<any>(resolve => ws.on("message", raw => {
      const frame = JSON.parse(raw.toString()); if (frame.type === "voice_call_result") resolve(frame)
    }))
    ws.send(JSON.stringify({ type: "voice_call_request", request_id: "call-test", action: "ring", call_id: crypto.randomUUID(), chat_id: crypto.randomUUID(), install_id: crypto.randomUUID() }))
    const result = await response
    expect(result.request_id).toBe("call-test"); expect(result.ok).toBe(false)
    expect(result.error).toContain("bound private session")
  } finally { ws.close() }
})

test("voice call client gets an isolated snapshot and foreign call action fails", async () => {
  const ws = await openMP(), install_id = crypto.randomUUID()
  try {
    const response = new Promise<any>(resolve => ws.on("message", raw => {
      const frame = JSON.parse(raw.toString()); if (frame.type === "voice_call_snapshot") resolve(frame)
    }))
    ws.send(JSON.stringify({ type: "register_call_client", install_id, enabled: false }))
    expect((await response).calls).toEqual([])
    const error = new Promise<any>(resolve => ws.on("message", raw => {
      const frame = JSON.parse(raw.toString()); if (frame.type === "voice_call_error") resolve(frame)
    }))
    ws.send(JSON.stringify({ type: "voice_call_action", call_id: crypto.randomUUID(), action: "accept" }))
    expect((await error).reason).toContain("not owned")
  } finally { ws.close() }
})

// ---------- 秒连（plan-hub-instant-connect）：/health 身份头 + since 游标重放 ----------

test("/health 带 x-mp-hub 头（app 竞速据此排除手机代理替答的 502）", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/health`)
  expect(res.status).toBe(200)
  expect(res.headers.get("x-mp-hub")).toBe("1")
})

test("reply 帧带 ts；重连带 since= 只补之后的，不带 / 非法就全量", async () => {
  const mcp = await openMCP()
  const live = await openMP()
  const got: any[] = []
  live.on("message", d => got.push(JSON.parse(d.toString())))
  await new Promise(r => setTimeout(r, 200))
  mcp.send(JSON.stringify({ type: "reply", chat_id: "conv-since", content: "旧", mp_msg_id: "s_since_old" }))
  await new Promise(r => setTimeout(r, 200))
  const old = got.find(m => m.type === "reply" && m.mp_msg_id === "s_since_old")
  expect(typeof old?.ts).toBe("number")
  await new Promise(r => setTimeout(r, 20))
  mcp.send(JSON.stringify({ type: "reply", chat_id: "conv-since", content: "新", mp_msg_id: "s_since_new" }))
  await new Promise(r => setTimeout(r, 200))
  live.close()

  const collect = async (url: string) => {
    const ws = new WebSocket(url)
    const frames: any[] = []
    ws.on("message", d => frames.push(JSON.parse(d.toString())))
    await new Promise<void>((resolve, reject) => { ws.on("open", resolve); ws.on("error", reject) })
    await new Promise(r => setTimeout(r, 300))
    ws.close()
    return frames.filter(m => m.type === "reply" && m.chat_id === "conv-since").map(m => m.mp_msg_id)
  }
  expect(await collect(`${CC_URL}&since=${old.ts}`)).toEqual(["s_since_new"])
  expect(await collect(CC_URL)).toEqual(["s_since_old", "s_since_new"])
  expect(await collect(`${CC_URL}&since=garbage`)).toEqual(["s_since_old", "s_since_new"])
  mcp.close()
})

test("connect_report 进秒连账本：快的不贴理由，慢的贴", async () => {
  const { readFileSync } = await import("node:fs")
  const mp = await openMP()
  const now = Date.now()
  mp.send(JSON.stringify({ type: "connect_report", trigger: "launch", t0: now - 60, open_at: now, total_ms: 60, attempts: [{ h: "127.0.0.1", r: "ok", ms: 5 }] }))
  mp.send(JSON.stringify({ type: "connect_report", trigger: "foreground", t0: now - 5_000, open_at: now, total_ms: 5_000, attempts: [{ h: "100.110.76.9", r: "nothub:502", ms: 3 }] }))
  await new Promise(r => setTimeout(r, 300))
  mp.close()
  const rows = readFileSync(join(TEST_SECRETS, "connect-ledger.jsonl"), "utf8").trim().split("\n").map(l => JSON.parse(l))
  const fast = rows.find(r => r.trigger === "launch" && r.t0 === now - 60)
  const slow = rows.find(r => r.trigger === "foreground" && r.t0 === now - 5_000)
  expect(fast.fast).toBe(true)
  expect(fast.reasons).toEqual([])
  expect(slow.fast).toBe(false)
  expect(slow.reasons.join("|")).toContain("代理替答")
})

test("terminal_report 进账本：trigger=terminal，慢的拆段贴理由", async () => {
  const { readFileSync } = await import("node:fs")
  const mp = await openMP()
  const now = Date.now()
  mp.send(JSON.stringify({ type: "terminal_report", session: "mp-cc-t", t0: now - 3_000, open_at: now, total_ms: 3_000, layout_ms: 2_100, bridge_ms: 0, hub_ms: 400, hub_steps: "size=20 resize=260 pipe=30 capture=90" }))
  await new Promise(r => setTimeout(r, 300))
  mp.close()
  const rows = readFileSync(join(TEST_SECRETS, "connect-ledger.jsonl"), "utf8").trim().split("\n").map(l => JSON.parse(l))
  const row = rows.find(r => r.trigger === "terminal" && r.t0 === now - 3_000)
  expect(row.session).toBe("mp-cc-t")
  expect(row.fast).toBe(false)
  expect(row.reasons.join("|")).toContain("app 等终端布局 2100ms")
  expect(row.reasons.join("|")).toContain("hub 开终端 400ms")
})

// 10-10 cc66：机器卡时会话表说「不在」→ 去 spawn → tmux 报 duplicate → 排队消息被吞。现在要接管现成的、照发
test("spawn 撞上已在的会话：接管并补发，不丢消息", async () => {
  const { ensureSessionAndSendAsync, SessionExistsError } = await import("./hub.ts")
  const sent: string[] = []
  let spawns = 0
  const quiet = { sendRaw: () => {}, key: async () => {}, capture: async () => "", list: () => [], paneTitles: () => new Map<string, string>(), kill: async () => {}, paste: async () => ({ ok: true as const }) }
  setTmuxRunner({
    ...quiet,
    send: async (text: string) => { sent.push(text) },
    hasSession: () => false,
    spawn: async (s: string) => { spawns++; throw new SessionExistsError(s) },
  })
  try {
    await ensureSessionAndSendAsync("mp-cc-dup-test", "第一条")
    expect(spawns).toBe(1)
    expect(sent).toEqual(["第一条"])
    await ensureSessionAndSendAsync("mp-cc-dup-test", "第二条")   // 已接管为就绪：直接发，不再 spawn
    expect(spawns).toBe(1)
    expect(sent).toEqual(["第一条", "第二条"])
  } finally {
    setTmuxRunner({ ...quiet, send: () => {}, hasSession: () => true, spawn: async () => {} })
  }
})

// K1-0 审查 R1-2：spawn 进行中（还没 await 完）同栈又来一条，必须排队而不是再 spawn / 直发；接管后按序补发
test("spawn 进行中同栈并发两条：只 spawn 一次，按序补发", async () => {
  const { ensureSessionAndSendAsync, SessionExistsError } = await import("./hub")
  const sent: string[] = []
  let spawns = 0
  const quiet = { sendRaw: async () => {}, key: async () => {}, capture: async () => "", list: () => [], paneTitles: () => new Map<string, string>(), kill: async () => {}, paste: async () => ({ ok: true as const }) }
  setTmuxRunner({
    ...quiet,
    send: async (text: string) => { sent.push(text) },
    hasSession: () => false,
    spawn: async (s: string) => { spawns++; throw new SessionExistsError(s) },
  })
  try {
    await Promise.all([
      ensureSessionAndSendAsync("mp-cc-race-test", "一"),
      ensureSessionAndSendAsync("mp-cc-race-test", "二"),
    ])
    expect(spawns).toBe(1)
    expect(sent).toEqual(["一", "二"])
  } finally {
    setTmuxRunner({ ...quiet, send: async () => {}, hasSession: () => true, spawn: async () => {} })
  }
})

// K1-0 审查 R1-1：普通发送同步入队、不让调用方等投递，否则排好的注入会抢在状态更新 / ack 前面
test("普通 send：ack 早于 sendLiteral", async () => {
  const { sendWithEffort, chainSessionSend } = await import("./hub")
  const calls: string[] = []
  const quiet = { sendRaw: async () => {}, key: async () => {}, capture: async () => "", list: () => [], paneTitles: () => new Map<string, string>(), kill: async () => {}, paste: async () => ({ ok: true as const }) }
  setTmuxRunner({
    ...quiet,
    send: (text: string, session: string) => chainSessionSend(session, async () => { calls.push(`sendLiteral:${text}`) }),
    hasSession: () => true,
    spawn: async () => {},
  })
  try {
    const restarting = sendWithEffort("mp-cc-order-test", "消息", undefined, undefined)   // 同 hub send 处理：只有重启才 await
    expect(restarting).toBeUndefined()
    if (restarting) await restarting
    calls.push("ack")
    await new Promise((r) => setTimeout(r, 0))
    expect(calls).toEqual(["ack", "sendLiteral:消息"])
  } finally {
    setTmuxRunner({ ...quiet, send: async () => {}, hasSession: () => true, spawn: async () => {} })
  }
})

// ── #068 P0：本机信任只认「本机进程直连」（转发头 / 浏览器头 / 非本机 Host 都不算），畸形请求目标不掀 hub ──
import { isTrustedLocal } from "./hub.ts"
import { connect as netConnect } from "node:net"

function fakeReq(remoteAddress: string | undefined, headers: Record<string, string>) {
  return { socket: { remoteAddress }, headers } as unknown as Parameters<typeof isTrustedLocal>[0]
}

test("#068 isTrustedLocal：loopback + 本机 Host + 无转发 / 浏览器头才算本机", () => {
  expect(isTrustedLocal(fakeReq("127.0.0.1", { host: "127.0.0.1:7890" }))).toBe(true)
  expect(isTrustedLocal(fakeReq("::1", { host: "[::1]:7890" }))).toBe(true)
  expect(isTrustedLocal(fakeReq("::ffff:127.0.0.1", { host: "LOCALHOST" }))).toBe(true)
  expect(isTrustedLocal(fakeReq("192.168.31.5", { host: "127.0.0.1:7890" }))).toBe(false)
  expect(isTrustedLocal(fakeReq(undefined, { host: "127.0.0.1:7890" }))).toBe(false)
  for (const h of ["x-forwarded-for", "forwarded", "x-real-ip", "cf-connecting-ip", "true-client-ip", "origin", "sec-fetch-site", "sec-fetch-mode"]) {
    expect(isTrustedLocal(fakeReq("127.0.0.1", { host: "127.0.0.1:7890", [h]: "" }))).toBe(false)
  }
  // 值是 127.0.0.1 也不信：按存在判定
  expect(isTrustedLocal(fakeReq("127.0.0.1", { host: "127.0.0.1:7890", "x-forwarded-for": "127.0.0.1" }))).toBe(false)
  for (const host of ["", "evil.example", "evil.example:7890", "127.0.0.1.evil.example", "127.0.0.1:abc", "localhost."]) {
    expect(isTrustedLocal(fakeReq("127.0.0.1", { host }))).toBe(false)
  }
  expect(isTrustedLocal(fakeReq("127.0.0.1", {}))).toBe(false)
})

/// 原样发一段 HTTP 报文（头大小写 / 重复头 / 畸形目标都由测试自己控制），收到连接关闭或超时为止
function rawHttp(text: string, timeoutMs = 2000): Promise<string> {
  return new Promise((resolve) => {
    const sock = netConnect(TEST_PORT, "127.0.0.1")
    let buf = ""
    const done = () => { clearTimeout(timer); sock.destroy(); resolve(buf) }
    const timer = setTimeout(done, timeoutMs)
    sock.on("data", (d) => { buf += d.toString("latin1") })
    sock.on("close", done)
    sock.on("error", done)
    sock.write(text)
  })
}

function rawPost(path: string, extraHeaders: string[], host = `127.0.0.1:${TEST_PORT}`): Promise<string> {
  const body = "{}"
  const head = [`POST ${path} HTTP/1.1`, ...(host ? [`Host: ${host}`] : []), "Content-Type: application/json", `Content-Length: ${body.length}`, "Connection: close", ...extraHeaders]
  return rawHttp(head.join("\r\n") + "\r\n\r\n" + body)
}

const UNTRUSTED_VARIANTS: { name: string; headers: string[]; host?: string }[] = [
  { name: "X-Forwarded-For 空值", headers: ["X-Forwarded-For: "] },
  { name: "x-forwarded-for 重复", headers: ["x-forwarded-for: 1.2.3.4", "x-forwarded-for: 127.0.0.1"] },
  { name: "Forwarded", headers: ["Forwarded: for=1.2.3.4"] },
  { name: "X-Real-IP", headers: ["X-REAL-IP: 1.2.3.4"] },
  { name: "CF-Connecting-IP", headers: ["CF-Connecting-IP: 1.2.3.4"] },
  { name: "True-Client-IP", headers: ["True-Client-IP: 1.2.3.4"] },
  { name: "Origin", headers: ["Origin: https://evil.example"] },
  { name: "Sec-Fetch-Site", headers: ["Sec-Fetch-Site: cross-site"] },
  { name: "Host 非本机（DNS rebinding）", headers: [], host: "evil.example:7890" },
]

test("#068 本机专用 HTTP 端点：带转发头 / 浏览器头 / 非本机 Host 一律 403；不带照旧放行", async () => {
  for (const path of ["/pocket/cmd", "/twitter/cmd", "/thinking", "/la/lifecycle", "/agent/ask-user", "/agent/book-note"]) {
    for (const v of UNTRUSTED_VARIANTS) {
      const res = await rawPost(path, v.headers, v.host)
      expect(`${path} ${v.name} → ${res.split("\r\n")[0]}`).toBe(`${path} ${v.name} → HTTP/1.1 403 Forbidden`)
    }
    const noHost = await rawPost(path, [], "")
    expect(`${path} 无 Host → ${noHost.split("\r\n")[0]}`).not.toContain(" 200 ")
  }
  // 本机直连照旧过守卫：/thinking 收到空对象 → 400 invalid_body（不是 403）
  const ok = await rawPost("/thinking", [])
  expect(ok.split("\r\n")[0]).toBe("HTTP/1.1 400 Bad Request")
})

test("#068 /health：本机直连 200；带转发头 403 但仍带 x-mp-hub（app 竞速认活）", async () => {
  const plain = await rawHttp(`GET /health HTTP/1.1\r\nHost: 127.0.0.1:${TEST_PORT}\r\nConnection: close\r\n\r\n`)
  expect(plain.split("\r\n")[0]).toBe("HTTP/1.1 200 OK")
  const fwd = await rawHttp(`GET /health HTTP/1.1\r\nHost: 127.0.0.1:${TEST_PORT}\r\nX-Forwarded-For: 1.2.3.4\r\nConnection: close\r\n\r\n`)
  expect(fwd.split("\r\n")[0]).toBe("HTTP/1.1 403 Forbidden")
  expect(fwd.toLowerCase()).toContain("x-mp-hub: 1")
})

function wsOutcome(url: string, headers: Record<string, string>): Promise<{ opened: boolean; code?: number }> {
  return new Promise((resolve) => {
    const ws = new WebSocket(url, { headers })
    let opened = false
    const timer = setTimeout(() => { ws.terminate(); resolve({ opened }) }, 2000)
    ws.on("open", () => { opened = true })
    ws.on("close", (code) => { clearTimeout(timer); resolve({ opened, code }) })
    ws.on("error", () => {})
  })
}

test("#068 WS /cc 无口令：带转发头 / Sec-Fetch / 非本机 Host 都按远程处理 → 1008；带对口令照常连上", async () => {
  const variants: Record<string, string>[] = [{ "X-Forwarded-For": "" }, { "Forwarded": "for=1.2.3.4" }, { "Sec-Fetch-Site": "cross-site" }, { "Host": "evil.example:80" }]
  for (const headers of variants) {
    const r = await wsOutcome(CC_URL_NO_TOKEN, headers)
    expect({ headers, code: r.code }).toEqual({ headers, code: 1008 })
  }
  const withToken = await new Promise<boolean>((resolve) => {
    const ws = new WebSocket(CC_URL, { headers: { "X-Forwarded-For": "1.2.3.4" } })
    ws.on("open", () => { resolve(true); ws.close() })
    ws.on("close", () => resolve(false))
    ws.on("error", () => resolve(false))
    setTimeout(() => resolve(false), 2000)
  })
  expect(withToken).toBe(true)
})

function bindStateReply(ws: WebSocket, waitMs: number): Promise<any> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(null), waitMs)
    ws.on("message", (d) => {
      const m = JSON.parse(d.toString())
      if (m.type === "bind_state") { clearTimeout(timer); resolve(m) }
    })
  })
}

test("#068 set_bind：带口令但经转发的连接被拒（不回 bind_state）；本机直连照旧能改", async () => {
  const fwd = new WebSocket(CC_URL, { headers: { "X-Forwarded-For": "1.2.3.4" } })
  await new Promise((r) => fwd.on("open", r))
  const fwdReply = bindStateReply(fwd, 800)
  fwd.send(JSON.stringify({ type: "set_bind", lan: true, tailscale: true }))
  expect(await fwdReply).toBeNull()
  fwd.close()

  const local = new WebSocket(CC_URL_NO_TOKEN)
  await new Promise((r) => local.on("open", r))
  const localReply = bindStateReply(local, 2000)
  local.send(JSON.stringify({ type: "set_bind", lan: true, tailscale: true }))
  expect(await localReply).not.toBeNull()
  local.close()
})

test("#068 畸形请求目标（new URL 会抛）只断这一条，hub 不退出", async () => {
  for (const target of ["//", "//a:b@", "http://["]) {
    const res = await rawHttp(`GET ${target} HTTP/1.1\r\nHost: 127.0.0.1:${TEST_PORT}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`)
    expect(res.startsWith("HTTP/1.1 101")).toBe(false)
  }
  await new Promise(r => setTimeout(r, 300))
  expect(hubProcess?.exitCode).toBeNull()
  const health = await fetch(`http://127.0.0.1:${TEST_PORT}/health`)
  expect(health.status).toBe(200)
})
