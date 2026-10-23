#!/usr/bin/env bun
import { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js"
import { WebSocket, type RawData } from "ws"
import { readFileSync, readdirSync } from "node:fs"
import { rollDice } from "./dice"
import { CARD_GUIDE_INDEX, CARD_KINDS, cardGuideFor } from "./card-guide"

const HUB_URL_BASE = process.env.MP_CC_HUB_URL ?? "ws://127.0.0.1:7890/mcp"
const PING_INTERVAL_MS = 15_000
const AGORA_COMPLETION_TIMEOUT_MS = 10_000
const AGORA_COMPLETION_ATTEMPTS = 3

interface AgoraCompleteResultFrame {
  type: "agora_complete_result"
  request_id: string
  ok: boolean
  message_id?: string
  passed?: boolean
  idempotent?: boolean
  error?: { code: string; message: string }
}

interface PendingAgoraCompletion {
  resolve: (frame: AgoraCompleteResultFrame) => void
  reject: (error: Error) => void
  timer: ReturnType<typeof setTimeout>
}

const pendingVoiceCalls = new Map<string, { resolve: (frame: any) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>()
async function requestVoiceCall(args: any) {
  const ws = await connectHub(), request_id = crypto.randomUUID()
  return await new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => { pendingVoiceCalls.delete(request_id); reject(new Error("call request timed out; query status using the same call_id before retrying")) }, 20_000)
    pendingVoiceCalls.set(request_id, { resolve, reject, timer })
    try { ws.send(JSON.stringify({ ...args, type: "voice_call_request", request_id })) }
    catch (e) { clearTimeout(timer); pendingVoiceCalls.delete(request_id); reject(e) }
  })
}
const pendingAgoraCompletions = new Map<string, PendingAgoraCompletion>()

// Phase 2：hub 强制 token。mcp-server 由 CC 通过 .mcp.json 启动，env 里没有 MP_CC_HUB_TOKEN。
// 优先 env（测试/手动配置），fallback 读 launchd plist（同 UID 权限）。
function getHubToken(): string {
  if (process.env.MP_CC_HUB_TOKEN) return process.env.MP_CC_HUB_TOKEN
  try {
    const dir = `${process.env.HOME}/Library/LaunchAgents`
    const name = readdirSync(dir).filter(n => n.endsWith(".cc-bridge-hub.plist")).sort()[0]
    if (!name) return ""
    const plistPath = `${dir}/${name}`
    const xml = readFileSync(plistPath, "utf8")
    const match = xml.match(/<key>MP_CC_HUB_TOKEN<\/key>\s*<string>([^<]+)<\/string>/)
    return match?.[1] ?? ""
  } catch {
    return ""
  }
}

function hubUrlWithToken(): string {
  const token = getHubToken()
  if (!token) return HUB_URL_BASE
  const sep = HUB_URL_BASE.includes("?") ? "&" : "?"
  return `${HUB_URL_BASE}${sep}token=${encodeURIComponent(token)}`
}

let hubWS: WebSocket | null = null
let connectingPromise: Promise<WebSocket> | null = null
let reconnectTimer: ReturnType<typeof setTimeout> | null = null
let pingTimer: ReturnType<typeof setInterval> | null = null
let reconnectDelay = 1_000  // 1s → 2 → 4 → 8 → 16 → 30 (capped)

function rejectPendingAgoraCompletions(reason: string): void {
  for (const p of pendingVoiceCalls.values()) { clearTimeout(p.timer); p.reject(new Error(reason)) }
  pendingVoiceCalls.clear()
  for (const [requestId, pending] of pendingAgoraCompletions) {
    clearTimeout(pending.timer)
    pending.reject(new Error(reason))
    pendingAgoraCompletions.delete(requestId)
  }
}

function handleHubMessage(raw: RawData): void {
  let frame: AgoraCompleteResultFrame
  try {
    frame = JSON.parse(raw.toString()) as AgoraCompleteResultFrame
  } catch {
    return
  }
  if ((frame as any).type === "voice_call_result") {
    const p = pendingVoiceCalls.get(frame.request_id)
    if (p) { clearTimeout(p.timer); pendingVoiceCalls.delete(frame.request_id); p.resolve(frame) }
    return
  }
  if (frame.type !== "agora_complete_result" || typeof frame.request_id !== "string") return
  const pending = pendingAgoraCompletions.get(frame.request_id)
  if (!pending) return
  clearTimeout(pending.timer)
  pendingAgoraCompletions.delete(frame.request_id)
  pending.resolve(frame)
}

function waitForAgoraCompletion(
  ws: WebSocket,
  frame: { type: "agora_complete"; request_id: string; mention_id: string; claim_token: string; content: string; pass?: boolean },
): Promise<AgoraCompleteResultFrame> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pendingAgoraCompletions.delete(frame.request_id)
      reject(new Error("agora_complete timed out"))
    }, AGORA_COMPLETION_TIMEOUT_MS)
    pendingAgoraCompletions.set(frame.request_id, { resolve, reject, timer })
    try {
      ws.send(JSON.stringify(frame))
    } catch (error) {
      clearTimeout(timer)
      pendingAgoraCompletions.delete(frame.request_id)
      reject(error instanceof Error ? error : new Error("agora_complete send failed"))
    }
  })
}

async function requestAgoraCompletion(args: {
  mention_id: string
  claim_token: string
  content: string
  pass?: boolean
}): Promise<AgoraCompleteResultFrame> {
  const frame = {
    type: "agora_complete" as const,
    request_id: crypto.randomUUID(),
    mention_id: args.mention_id,
    claim_token: args.claim_token,
    content: args.content,
    pass: args.pass === true ? true : undefined,
  }
  let lastError = new Error("agora_complete failed")
  for (let attempt = 0; attempt < AGORA_COMPLETION_ATTEMPTS; attempt += 1) {
    try {
      const ws = await connectHub()
      return await waitForAgoraCompletion(ws, frame)
    } catch (error) {
      lastError = error instanceof Error ? error : lastError
      if (attempt + 1 < AGORA_COMPLETION_ATTEMPTS) {
        await new Promise(resolve => setTimeout(resolve, 500 * (attempt + 1)))
      }
    }
  }
  throw new Error(`hub unreachable after agora_complete retries: ${lastError.message}`)
}

// 永不 throw、永不喷 stderr：CC 的 MCP host 看到 stderr 可能判定 unhealthy
// 然后 disable + kill 这个子进程。要不计代价保持 silent + alive。
process.on("uncaughtException", () => { /* swallow */ })
process.on("unhandledRejection", () => { /* swallow */ })

function scheduleReconnect() {
  if (reconnectTimer) return
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null
    connectHub().catch(() => {
      reconnectDelay = Math.min(reconnectDelay * 2, 30_000)
      scheduleReconnect()
    })
  }, reconnectDelay)
}

function startPing() {
  stopPing()
  pingTimer = setInterval(() => {
    if (hubWS && hubWS.readyState === WebSocket.OPEN) {
      try { hubWS.ping() } catch { /* let close handler clean up */ }
    }
  }, PING_INTERVAL_MS)
}

function stopPing() {
  if (pingTimer) {
    clearInterval(pingTimer)
    pingTimer = null
  }
}

/// 宿主 tmux session 名：mcp-server 被 claude/codex spawn，继承 TMUX_PANE env。
function hostTmuxSession(): string | null {
  const explicit = process.env.MP_CC_SESSION_NAME
  if (explicit && /^[A-Za-z0-9_-]{1,100}$/.test(explicit)) return explicit
  const pane = process.env.TMUX_PANE
  if (!pane) return null
  try {
    const out = Bun.spawnSync(["tmux", "display-message", "-p", "-t", pane, "#S"]).stdout.toString().trim()
    return out || null
  } catch { return null }
}

function connectHub(): Promise<WebSocket> {
  if (hubWS && hubWS.readyState === WebSocket.OPEN) return Promise.resolve(hubWS)
  if (connectingPromise) return connectingPromise

  connectingPromise = new Promise((resolve, reject) => {
    const ws = new WebSocket(hubUrlWithToken())
    hubWS = ws
    ws.on("open", () => {
      connectingPromise = null
      reconnectDelay = 1_000  // 成功后重置退避
      // 不要 console.error — CC 的 MCP host 可能据此判定 unhealthy
      // 上报宿主 tmux session（hub 用它把本 socket 关联到 session → reply 守卫：
      // 有未答的房间 mention 时 reply 会被拦、引导 agora_complete）。拿不到就不报（守卫失效但无害）。
      const sessionName = hostTmuxSession()
      if (sessionName) {
        try { ws.send(JSON.stringify({ type: "mcp_hello", session_name: sessionName })) } catch {}
      }
      startPing()
      resolve(ws)
    })
    ws.on("message", handleHubMessage)
    ws.on("error", (err) => {
      connectingPromise = null
      hubWS = null
      stopPing()
      reject(err)
    })
    ws.on("close", () => {
      hubWS = null
      stopPing()
      rejectPendingAgoraCompletions("hub disconnected during agora_complete")
      // hub 重启 / 网络抖动 → 自动重连，不等下次 reply tool call
      scheduleReconnect()
    })
  })
  return connectingPromise
}

const server = new Server(
  { name: "cc-bridge-mcp", version: "0.2.0" },
  { capabilities: { tools: {} }, instructions: CARD_GUIDE_INDEX }  // 聊天卡片目录进 CC 系统提示；完整写法走 card_guide 工具（粟粟 10-03）
)

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [{
    name: "card_guide",
    description: "查聊天卡片的写法。要在回复里发卡片（待办、骰子、计时器、图表、音乐、生词、时间线、提问 / 表单、html 网页卡）之前先调它，kinds 传要用的种类，按返回的格式写。不发卡片不用调。",
    inputSchema: {
      type: "object",
      properties: {
        kinds: { type: "array", items: { type: "string", enum: [...CARD_KINDS] }, description: "要查的卡片种类，可以一次查几种" },
      },
      required: ["kinds"],
    },
  }, {
    name: "roll_dice",
    description: "掷骰子或从选项里随机抽一个（真随机）。给 dice（如 \"2d6+1\"、\"d20\"）或 options（至少 2 个）二选一，可加 title；替对方掷已有的骰子卡时再给那张卡的 id。返回一段 card-dice 代码块和一行结果摘要——把代码块原样放进你给对方的回复正文，对方会看到带结果的骰子卡。不要自己编结果。",
    inputSchema: {
      type: "object",
      properties: {
        dice: { type: "string", description: "骰子表达式 NdM±K（N 1–20，M 2–1000，K ≤ 1000）" },
        options: { type: "array", items: { type: "string" }, description: "抽签选项（至少 2 个）" },
        title: { type: "string", description: "卡片标题，可空" },
        id: { type: "string", description: "替对方掷已有的骰子卡时填它的 id（d- 开头）；新掷不填" },
      },
    },
  }, {
    name: "voice_call",
    description: "Ring one explicitly selected opted-in iOS device for this session's bound private chat, query status, or cancel. Requires a UUID call_id chosen once per call; retries must reuse it. Do not call without the user's permission to place a call. install_id is displayed in that device's native-call settings. No broadcast or automatic fallback.",
    inputSchema: { type: "object", properties: {
      action: { type: "string", enum: ["ring", "status", "cancel"] },
      call_id: { type: "string" }, chat_id: { type: "string" }, install_id: { type: "string" }, caller: { type: "string" }
    }, required: ["action", "call_id"] },
  }, {
    name: "reply",
    description: "Send a message to a Memory Palace conversation. Normally used to respond to <channel source=\"memorypalace\"> input (pass its chat_id + message_id). You can ALSO use it proactively at any time to message a conversation without a preceding <channel> — just pass that conversation's chat_id (omit message_id). The message appears as a new message from you. Returns the new message's id (s_...) — keep it if you may want to edit_message it later (e.g. streaming updates).",
    inputSchema: {
      type: "object",
      properties: {
        chat_id: { type: "string", description: "The chat_id from the <channel> tag" },
        message_id: { type: "string", description: "The message_id from the <channel> tag. Pass it back verbatim so the reply is matched to the exact message (prevents stale replies being mis-routed)." },
        content: { type: "string", description: "Your reply text" },
        file_path: { type: "string", description: "Optional: absolute path (or relative to your cwd) of ANY file to send to the user — image OR document/code/zip/etc. Images show as photos; other files show as a downloadable file card they can save. Use this to send them files you generated or have on disk." },
        reply_to: { type: "string", description: "Optional: the id of a message to quote-reply (the inbound message_id, or an s_... id returned by a previous reply). Shows a quote of that message above yours." },
      },
      required: ["chat_id", "content"],
    },
  }, {
    name: "agora_complete",
    description: "Complete the durable Agora mention from an <agora_claim>. Pass mention_id and claim_token exactly as provided. For an observe claim (kind: observe) you may stay silent by sending pass: true instead of content. This is the only completion tool for Agora room mentions; do not use legacy reply.",
    inputSchema: {
      type: "object",
      properties: {
        mention_id: { type: "string", description: "The mention_id from <agora_claim>" },
        claim_token: { type: "string", description: "The claim_token from <agora_claim>" },
        content: { type: "string", description: "Your complete Agora room reply (omit when pass is true)" },
        pass: { type: "boolean", description: "observe claims only: true = stay silent, no message is posted" },
      },
      required: ["mention_id", "claim_token"],
    },
  }, {
    name: "edit_message",
    description: "Edit the text of a message you already sent. Pass the s_... id returned by reply. Use for streaming updates (send a placeholder, then edit it to the full answer) or fixing typos.",
    inputSchema: {
      type: "object",
      properties: {
        chat_id: { type: "string", description: "The chat_id of the conversation" },
        message_id: { type: "string", description: "The s_... id returned by the reply that created this message" },
        content: { type: "string", description: "The new full text (replaces the old)" },
      },
      required: ["chat_id", "message_id", "content"],
    },
  }, {
    name: "book_note",
    description: "Write a margin note into the book the user is currently reading (it appears as a rose-colored highlight + note on the page, like handwriting in their book margins). BEFORE calling: read ~/Library/Application Support/MemoryPalace/agent/reading-context.json to see the chapter text they're on — `quote` MUST be copied VERBATIM from that text (20-60 chars; fuzzy/paraphrased quotes fail anchoring and are silently dropped). Requires the user to have the「CC 共读」switch on in app settings and to have read the book today; the tool tells you if either is missing. Optionally pass `message` to also drop a short line into the main conversation.",
    inputSchema: {
      type: "object",
      properties: {
        quote: { type: "string", description: "Verbatim excerpt from the current chapter text (20-60 chars) — the anchor your note attaches to" },
        comment: { type: "string", description: "Your margin note (short, sincere, like writing to them on the page — max 600 chars)" },
        reply_to_anchor: { type: "string", description: "Optional: when replying to one of THEIR annotations, the verbatim text of their annotation" },
        message: { type: "string", description: "Optional: a short message dropped into the main conversation alongside the note (e.g. 'I left something on page 27')" },
      },
      required: ["quote", "comment"],
    },
  }, {
    // 跟 app 里楼层 AI 的 TwitterAITool 同一个工具（MemoryPalace/Services/Twitter/TwitterAITool.swift），改那边记得同步这里
    name: "local_twitter",
    description: `Memory Palace 里本楼层的推特——只在 app 里、楼层的账号之间，跟真 X 无关（真推特是另一个桥，别弄混）。你在这里有自己的号（第一次用自动开，名字头像跟楼层 AI 资料同步），可以像刷推一样用它。用户的推、书签、赞也都在这里。
每次调用做一件事（action）：
· post 发推（text）｜reply 回复（tweet_id + text）｜quote 引用（tweet_id + text）
· like / unlike 点赞、取消赞（tweet_id）｜repost 转帖（tweet_id）
· follow / unfollow 关注、取关（handle）
· timeline 刷时间线（feed：local 本站所有号 / following 你关注的号；limit）
· search 搜推（text 当关键词）｜view 看一条推和它下面的回复（tweet_id）
· user 看某个号的资料和最近的推（handle）｜mentions 看谁 @ 了你、回复了你
· accounts 看你有哪些号｜create_account 再开一个号（name + handle）
默认用你的主号；用别的号就在 as 里填它的 handle。不能用用户的号。推文 id 在各种列表里都会给出，回复/引用/点赞用它。
楼层：填 chat_id（<channel> 里那个）就用那个会话所在的楼层；不填用 app 当前打开的楼层。命令只发给手机上的 app（数据在手机上），手机 app 要连着 hub。`,
    inputSchema: {
      type: "object",
      properties: {
        action: { type: "string", enum: ["post", "reply", "quote", "like", "unlike", "repost", "follow", "unfollow", "timeline", "search", "view", "user", "mentions", "accounts", "create_account"], description: "要做什么" },
        text: { type: "string", description: "推文正文；search 时是关键词" },
        tweet_id: { type: "string", description: "目标推文 id" },
        handle: { type: "string", description: "目标账号的 handle（带不带 @ 都行）；create_account 时是新号的 handle" },
        name: { type: "string", description: "create_account 时新号的名字" },
        feed: { type: "string", enum: ["local", "following"], description: "timeline 看哪条：本站 / 关注，默认 local" },
        limit: { type: "integer", description: "列表最多几条，默认 20，最多 50" },
        as: { type: "string", description: "用你的哪个号（handle）；不填用主号" },
        chat_id: { type: "string", description: "可选：会话 id，决定用哪个楼层；不填 = app 当前楼层" },
      },
      required: ["action"],
    },
  }, {
    name: "pocket",
    description: "Control the user's phone browser remotely. The phone must have '遥控浏览器' enabled in CC settings. Uses the phone's real login sessions (cookies shared with the built-in browser). 5 actions: ping (heartbeat), goto (navigate to URL), js (evaluate JavaScript and return result — use this for clicking, filling forms, reading DOM), html (read full page HTML), screenshot (capture the current page as PNG). For multi-step browsing: goto a URL, then use js to interact, screenshot to see results.",
    inputSchema: {
      type: "object",
      properties: {
        action: { type: "string", enum: ["ping", "goto", "js", "html", "screenshot"], description: "The browser action to perform" },
        url: { type: "string", description: "URL to navigate to (required for 'goto')" },
        js: { type: "string", description: "JavaScript code to evaluate (required for 'js'). The return value of the last expression is sent back." },
        timeout_ms: { type: "number", description: "Timeout in ms (default 30000, max 120000). Increase for screenshot or slow pages." },
      },
      required: ["action"],
    },
  }],
}))

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const args = req.params.arguments as any
  if (req.params.name === "card_guide") {
    // 本地查，不经 hub；参数坏了也全给，别让模型卡住
    return { content: [{ type: "text", text: cardGuideFor(args?.kinds) }] }
  }
  if (req.params.name === "roll_dice") {
    // 本地算，不经 hub；业务错误回 isError 让模型改参数重试（v1.1 I2）
    const r = rollDice(args ?? {})
    if (!r.ok) return { content: [{ type: "text", text: r.error }], isError: true }
    return { content: [{ type: "text", text: r.text }] }
  }
  // mcp-server 自己生成消息 id（fire-and-forget，不等 hub 回）→ 返回给 CC，供后续 edit/引用
  const mpMsgId = "s_" + crypto.randomUUID().slice(0, 8)
  let frame: any
  let okText: string
  if (req.params.name === "voice_call") {
    const result = await requestVoiceCall(args)
    return { content: [{ type: "text", text: JSON.stringify(result) }], isError: !result.ok }
  } else if (req.params.name === "agora_complete") {
    const result = await requestAgoraCompletion({
      mention_id: args.mention_id,
      claim_token: args.claim_token,
      content: typeof args.content === "string" ? args.content : "",
      pass: args.pass === true,
    })
    if (!result.ok) {
      const code = result.error?.code ?? "completion_failed"
      const message = result.error?.message ?? "Agora completion failed"
      throw new Error(`agora_complete failed (${code}): ${message}`)
    }
    return {
      content: [{
        type: "text",
        text: result.passed
          ? `passed (stayed silent, idempotent: ${result.idempotent === true})`
          : `completed (message_id: ${result.message_id}, idempotent: ${result.idempotent === true})`,
      }],
    }
  } else if (req.params.name === "reply") {
    frame = {
      type: "reply",
      chat_id: args.chat_id,
      message_id: args.message_id,   // 可选，回带用于精确匹配
      content: args.content,
      file_path: args.file_path ?? args.image_path,   // 可选，发任意文件
      mp_msg_id: mpMsgId,            // 服务端消息 id（CC 可用于 edit/引用）
      reply_to: args.reply_to,       // 可选，引用的消息 id
    }
    okText = `ok (id: ${mpMsgId})`
  } else if (req.params.name === "edit_message") {
    frame = { type: "edit", chat_id: args.chat_id, message_id: args.message_id, content: args.content }
    okText = `edited (id: ${args.message_id})`
  } else if (req.params.name === "book_note") {
    const httpBase = HUB_URL_BASE.replace(/^ws/, "http").replace(/\/mcp$/, "")
    // hub 端复用 daemon 的 parseReaderOutput 校验，字段名按它的契约转（quote→anchorText）
    const note: Record<string, string> = { anchorText: args.quote ?? "", comment: args.comment ?? "" }
    if (typeof args.reply_to_anchor === "string" && args.reply_to_anchor.trim()) note.replyToAnchor = args.reply_to_anchor
    const resp = await fetch(`${httpBase}/agent/book-note`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ annotations: [note], message: args.message ?? "" }),
    })
    const result = await resp.json() as any
    const text = result.ok
      ? `ok — 批注已投递（《${result.book}》第 ${result.chapter} 章${result.message ? "，附带消息" : ""}）。用户翻到那页就能看见。`
      : `失败：${result.error}`
    return { content: [{ type: "text", text }] }
  } else if (req.params.name === "local_twitter") {
    const httpBase = HUB_URL_BASE.replace(/^ws/, "http").replace(/\/mcp$/, "")
    const { chat_id, ...input } = args ?? {}
    const resp = await fetch(`${httpBase}/twitter/cmd`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id, input }),
    })
    const result = await resp.json() as any
    const text = typeof result.result === "string" ? result.result : (result.error ?? "unknown error")
    return { content: [{ type: "text", text }], isError: result.ok !== true }
  } else if (req.params.name === "pocket") {
    const httpBase = HUB_URL_BASE.replace(/^ws/, "http").replace(/\/mcp$/, "")
    const resp = await fetch(`${httpBase}/pocket/cmd`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(args),
    })
    const result = await resp.json() as any
    if (args.action === "screenshot" && result.ok && typeof result.result === "string" && result.result.startsWith("data:image/png;base64,")) {
      const b64 = result.result.replace("data:image/png;base64,", "")
      return { content: [{ type: "image", data: b64, mimeType: "image/png" }] }
    }
    if (args.action === "html" && result.ok && typeof result.result === "string" && result.result.length > 50_000) {
      return { content: [{ type: "text", text: result.result.slice(0, 50_000) + `\n\n…(truncated, full ${result.result.length} chars)` }] }
    }
    return { content: [{ type: "text", text: JSON.stringify(result) }] }
  } else {
    throw new Error(`unknown tool: ${req.params.name}`)
  }
  // 如果 hub 这一刻断了，等一次重连尝试（最多 retry 几次再放弃）
  let lastErr: Error | undefined
  for (let i = 0; i < 3; i++) {
    try {
      const ws = await connectHub()
      ws.send(JSON.stringify(frame))
      return { content: [{ type: "text", text: okText }] }
    } catch (err) {
      lastErr = err as Error
      await new Promise(r => setTimeout(r, 500 * (i + 1)))
    }
  }
  throw new Error(`hub unreachable after retries: ${lastErr?.message ?? "unknown"}`)
})

// 启动时立刻连 hub（不等第一次 reply tool call 才 lazy connect）
// hub 没起时 fail 后自动 backoff 重连，不阻塞 stdio
connectHub().catch(() => scheduleReconnect())

const transport = new StdioServerTransport()
await server.connect(transport)
