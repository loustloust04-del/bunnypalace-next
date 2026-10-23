// APNs 推送发送器：用 .p8 签 ES256 JWT（token-based auth）+ HTTP/2 POST 到 APNs。
// Bun fetch 支持 h2（APNs 要求），crypto.subtle 支持 ES256。
//
// 上架 stub（v1.1）：cert 不存在时（用户机上没 secrets/.p8）静默 skip 所有推送调用，
// 不抛错不打扰主 hub。粟粟自己 master 跑保留完整推送功能。
import { timedSyncFs } from "./block-ledger"
const { existsSync, readFileSync } = timedSyncFs("apns ")
import { join } from "node:path"
import http2 from "node:http2"
import { type CCActivityState, encodeContentState } from "./activity-state.ts"

const KEY_PATH = process.env.MP_APNS_KEY_PATH || join(import.meta.dir, "secrets", "AuthKey_A2VBYSJK8V.p8")
const KEY_ID = process.env.MP_APNS_KEY_ID || "A2VBYSJK8V"
const TEAM_ID = process.env.MP_APNS_TEAM_ID || "GQN42B462A"
/// token 没带 topic（老 app / 老记录）时用的 topic。
export const DEFAULT_TOPIC = process.env.MP_APNS_TOPIC || "com.susu.MemoryPalace.ios"
// host 按 token 记录的 env 选；MP_APNS_HOST 显式设了则一律覆盖（调试口）。
const HOST_OVERRIDE = process.env.MP_APNS_HOST

export function hostFor(env: "sandbox" | "production"): string {
  return HOST_OVERRIDE || (env === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com")
}

// 启动时一次性检查 cert——避免每次 sendAPNs() 都 fs.statSync 拖性能。
// 上架版用户机上 cert 永远不存在 → APNS_ENABLED=false → sendAPNs 直接返回 cert-missing。
let apnsEnabled = existsSync(KEY_PATH)
if (!apnsEnabled) {
  console.log(`[apns] cert not found at ${KEY_PATH}, push disabled (上架版预期行为)`)
}

// 测试缝（仅 *.test.ts 用）：把「传输」和「cert 读取」两处外部依赖抽成可替换的模块级 let。
// 生产路径的值就是原来的直接调用，行为零变化。
let connectImpl: typeof http2.connect = http2.connect
let readKeyPem = (): string => readFileSync(KEY_PATH, "utf8")

export function __setAPNsTestHooks(h: {
  connect?: typeof http2.connect
  enabled?: boolean
  readKeyPem?: () => string
} = {}): void {
  connectImpl = h.connect ?? http2.connect
  apnsEnabled = h.enabled ?? existsSync(KEY_PATH)
  readKeyPem = h.readKeyPem ?? (() => readFileSync(KEY_PATH, "utf8"))
  cachedKey = null
  cachedJWT = { token: "", iat: 0 }
}

function b64url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

let cachedKey: CryptoKey | null = null
async function importKey(): Promise<CryptoKey> {
  if (cachedKey) return cachedKey
  const pem = readKeyPem()
  const der = Buffer.from(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""), "base64")
  cachedKey = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"])
  return cachedKey
}

let cachedJWT = { token: "", iat: 0 }
async function makeJWT(): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  if (cachedJWT.token && now - cachedJWT.iat < 3000) return cachedJWT.token  // <50min 复用（APNs 要求 < 1h）
  const enc = new TextEncoder()
  const header = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: KEY_ID })))
  const payload = b64url(enc.encode(JSON.stringify({ iss: TEAM_ID, iat: now })))
  const signingInput = `${header}.${payload}`
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await importKey(), enc.encode(signingInput))
  cachedJWT = { token: `${signingInput}.${b64url(new Uint8Array(sig))}`, iat: now }
  return cachedJWT.token
}

export interface APNsResult { ok: boolean; status: number; reason?: string }

/// 一次 APNs HTTP/2 POST。调用方只给受限头（apns-topic / apns-push-type / apns-priority…），
/// authorization 与 content-type 由这里加且不可被覆盖（spread 在前，这两个在后）。
export interface APNsRequest { host: string; path: string; headers: Record<string, string>; payload: string }

export async function postAPNs(req: APNsRequest, opts: { timeoutMs?: number } = {}): Promise<APNsResult> {
  const jwt = await makeJWT()
  const timeoutMs = opts.timeoutMs ?? 15_000
  return new Promise<APNsResult>((resolve) => {
    // family:4 钉死 IPv4——bun http2 走 IPv6 连 APNs 时 ALPN 拿不到 h2（间歇 "h2 is not
    // supported"，2026-08-07 实测 v6 命中即炸/v4 100% 通，log 814 次 fail 全是它）
    const client = connectImpl(req.host, { family: 4 })
    let settled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    const done = (r: APNsResult) => {
      if (settled) return
      settled = true
      if (timer) clearTimeout(timer)
      try { client.close() } catch {}
      resolve(r)
    }
    // 原实现从连接到结束没有超时，卡住的连接会一直挂着；周期推送（M3b）不能带这个洞。
    timer = setTimeout(() => done({ ok: false, status: 0, reason: "timeout" }), timeoutMs)
    client.on("error", (e: any) => done({ ok: false, status: 0, reason: e.message }))
    const stream = client.request({
      ":method": "POST",
      ":path": req.path,
      ...req.headers,
      authorization: `bearer ${jwt}`,
      "content-type": "application/json",
    })
    let status = 0
    let data = ""
    stream.on("response", (headers: any) => { status = Number(headers[":status"]) || 0 })
    stream.on("data", (chunk: Buffer) => { data += chunk })
    stream.on("error", (e: any) => done({ ok: false, status, reason: e.message }))
    stream.on("end", () => {
      if (status === 200) return done({ ok: true, status })
      let reason = data
      try { reason = JSON.parse(data).reason } catch {}
      done({ ok: false, status, reason })
    })
    stream.write(req.payload)
    stream.end()
  })
}

/// 给单个 device token 发一条 alert 推送（APNs 只走 HTTP/2，用 node:http2）。
/// host / apns-topic 跟着 token 自己的 env / topic 走；没带就是 sandbox + DEFAULT_TOPIC（老记录原行为）。
/// cert 不存在时直接返回 skip，hub 调用方不感知差异（上架 stub 路径）。
export async function sendAPNs(
  target: { token: string; env?: "sandbox" | "production"; topic?: string },
  title: string,
  body: string,
  chatId: string,
  metadata: Record<string, string> = {},
): Promise<APNsResult> {
  if (!apnsEnabled) {
    return { ok: false, status: 0, reason: "cert-missing" }
  }
  // mutable-content: 1 让 iOS 叫醒 app 的 NSE（MemoryPalacePushNSE）改写 title +
  // 塞楼层 AI 头像（Communication Notification）。NSE 在 app 端按 chat_id 反查 App Group
  // 索引拿楼层 assistantName/avatar。没 NSE 的端（macOS/旧 app）这字段无副作用，照旧弹 title。
  const payload = JSON.stringify({
    aps: { alert: { title, body }, sound: "default", "mutable-content": 1 },
    chat_id: chatId,
    ...metadata,
  })
  return postAPNs({
    host: hostFor(target.env ?? "sandbox"),
    path: `/3/device/${target.token}`,
    headers: { "apns-topic": target.topic ?? DEFAULT_TOPIC, "apns-push-type": "alert" },
    payload,
  })
}

// ——— Live Activity 推送（ActivityKit remote update）———
// 字段名逐字按 Apple：content-state / stale-date / dismissal-date / attributes-type / input-push-token。

export interface LaAlert { title: string; body: string }

export type LaEvent =
  | { event: "update"; contentState: CCActivityState; staleDateUnix?: number; alert?: LaAlert; relevanceScore?: number }
  | { event: "end"; contentState: CCActivityState; dismissalDateUnix?: number; alert?: LaAlert }
  | { event: "start"; contentState: CCActivityState; attributesType: string; attributes: object; alert: LaAlert; inputPushToken?: true }

/// APNs 对 Live Activity 载荷的硬上限是 4 KB，恰好 4096 合法。
export const LA_PAYLOAD_MAX_BYTES = 4096

export class LaPayloadTooLargeError extends Error {
  constructor(readonly bytes: number) {
    super(`live activity payload ${bytes} bytes > ${LA_PAYLOAD_MAX_BYTES} (APNs 上限)`)
    this.name = "LaPayloadTooLargeError"
  }
}

/// 纯函数，可测。超 4 KB throw LaPayloadTooLargeError，交调用方降级（截 detail / 丢字段）。
export function buildLiveActivityPayload(ev: LaEvent, timestampUnix: number): string {
  const aps: Record<string, unknown> = {
    timestamp: timestampUnix,
    event: ev.event,
    // 走 ④ 那一份编码器（键字母序、undefined 不落键），与 Swift/golden 同一套字节
    "content-state": JSON.parse(encodeContentState(ev.contentState)),
  }
  if (ev.event === "start") {
    aps["attributes-type"] = ev.attributesType
    aps.attributes = ev.attributes
    if (ev.inputPushToken) aps["input-push-token"] = 1
  }
  if (ev.event === "update") {
    if (ev.staleDateUnix !== undefined) aps["stale-date"] = ev.staleDateUnix
    if (ev.relevanceScore !== undefined) aps["relevance-score"] = ev.relevanceScore
  }
  if (ev.event === "end" && ev.dismissalDateUnix !== undefined) aps["dismissal-date"] = ev.dismissalDateUnix
  if (ev.alert) aps.alert = ev.alert

  const json = JSON.stringify({ aps })
  const bytes = Buffer.byteLength(json, "utf8")
  if (bytes > LA_PAYLOAD_MAX_BYTES) throw new LaPayloadTooLargeError(bytes)
  return json
}

/// 给一个已注册的 activity push token 发一条 Live Activity 更新。
/// host 按 record.env 选，topic 按 record.topic 派生（老记录回退 DEFAULT_TOPIC）。
/// 日志由调用方（M3b/M4）打，这里只返回结果。
export async function sendLiveActivityAPNs(
  record: { token: string; env: "sandbox" | "production"; topic?: string },
  ev: LaEvent,
  opts: { priority: 5 | 10; timestampUnix?: number },
): Promise<APNsResult> {
  if (!apnsEnabled) {
    return { ok: false, status: 0, reason: "cert-missing" }
  }
  const host = hostFor(record.env)
  const payload = buildLiveActivityPayload(ev, opts.timestampUnix ?? Math.floor(Date.now() / 1000))
  return postAPNs({
    host,
    path: `/3/device/${record.token}`,
    headers: {
      "apns-topic": `${record.topic ?? DEFAULT_TOPIC}.push-type.liveactivity`,
      "apns-push-type": "liveactivity",
      "apns-priority": String(opts.priority),
    },
    payload,
  })
}

/** VoIP 只用于新的实际来电；撤回/状态走 WS，绝不拿 VoIP 当后台保活。 */
export async function sendVoIPAPNs(target: { token: string; env: "sandbox" | "production"; topic: string }, call: { call_id: string; chat_id: string; caller: string; created_at: number; expires_at: number }): Promise<APNsResult> {
  if (!apnsEnabled) return { ok: false, status: 0, reason: "cert-missing" }
  return postAPNs({ host: hostFor(target.env), path: `/3/device/${target.token}`,
    headers: { "apns-topic": `${target.topic}.voip`, "apns-push-type": "voip", "apns-priority": "10", "apns-expiration": "0" },
    payload: JSON.stringify({ aps: { "content-available": 1 }, ...call }),
  })
}
