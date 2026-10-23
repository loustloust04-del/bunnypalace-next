// 手机「开发」子应用 → hub → 本机 session 看板服务 4793 的薄转发（docs/plan-pm-board-app.md §2.3）。
// 只转发不计算：不 exec、不扫文件（warroom 扫描螺旋的教训）；每次只读一个几十字节的 token 文件。
// pm_req（docs/plan-dev-subapp-v2.md P0-c）：通用转发，路径白名单在 4793；hub 只查 path 形状 / GET|POST / body ≤ 64K 字。以后 4793 加接口不用再重启 hub。
// 老的 5 种帧原样留着给 v1 app，等 v2 app 装好再删（P2-d-3）。
import { timedSyncFs } from "./block-ledger"
const { readFileSync } = timedSyncFs("pm-relay ")
import { homedir } from "node:os"
import { join } from "node:path"

export const PM_FRAMES = new Set(["pm_board", "pm_session", "pm_send", "pm_open", "pm_doc", "pm_req"])
export const PM_REQ_PATH_RE = /^\/api\/[a-z/]+(\?[\w=&%.-]*)?$/
export const PM_REQ_BODY_MAX = 64 * 1024   // 字符数；plan 写的 8KB 不够 P1-c 路线图状态（一份 ≤ 64KB），一次放够免得再重启 hub
export const PM_TEXT_MAX = 4000
export const PM_TIMEOUT_MS = 3000
export const PM_SEND_TIMEOUT_MS = 10_000   // 打字要 settle + 复查 + 最多 4 次回车，3 秒不够；4793 端按 clientMsgId 幂等，超时重试不会发两遍

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const DOC_NAME_RE = /^plan-[A-Za-z0-9._-]+$/

export interface PmRelayEnv {
  url: string
  tokenFile: string
  fetch: (input: string, init: RequestInit) => Promise<Response>
  timeoutMs: number
  sendTimeoutMs: number
}
export function defaultPmEnv(): PmRelayEnv {
  return {
    url: process.env.MP_PM_URL ?? "http://127.0.0.1:4793",
    tokenFile: process.env.MP_PM_API_TOKEN_FILE ?? join(process.env.MP_PM_Q ?? join(homedir(), ".mp-merge-queue"), "pm-api-token"),
    fetch: (input, init) => fetch(input, init),
    timeoutMs: PM_TIMEOUT_MS,
    sendTimeoutMs: PM_SEND_TIMEOUT_MS,
  }
}

type Json = Record<string, unknown>

function requestOf(msg: Json): { path: string; method: "GET" | "POST"; body?: Json } | { error: string; code?: string } {
  const sid = typeof msg.sid === "string" ? msg.sid : ""
  switch (msg.type) {
    case "pm_board": return { path: "/api/board?view=phone", method: "GET" }
    case "pm_session": {
      if (!UUID_RE.test(sid)) return { error: "sid 不是对话号" }
      const turns = Math.min(60, Math.max(1, Math.floor(Number(msg.turns)) || 20))
      return { path: `/api/session?sid=${sid}&turns=${turns}`, method: "GET" }
    }
    case "pm_send": {
      if (!UUID_RE.test(sid)) return { error: "sid 不是对话号" }
      const text = typeof msg.text === "string" ? msg.text : ""
      if (!text.trim()) return { error: "空消息" }
      if (text.length > PM_TEXT_MAX) return { error: `超过 ${PM_TEXT_MAX} 字` }
      return { path: "/api/send", method: "POST", body: { sid, text, clientMsgId: typeof msg.clientMsgId === "string" ? msg.clientMsgId : "" } }
    }
    case "pm_open": {
      if (!UUID_RE.test(sid)) return { error: "sid 不是对话号" }
      return { path: "/api/open", method: "POST", body: { sid } }
    }
    case "pm_req": {
      const p = typeof msg.path === "string" ? msg.path : ""
      if (!PM_REQ_PATH_RE.test(p) || p.includes("//") || p.includes("..")) return { error: "路径不对（只认 /api/…）", code: "bad-path" }
      if (msg.method !== "GET" && msg.method !== "POST") return { error: "method 只认 GET / POST", code: "bad-path" }
      if (msg.method === "GET") return { path: p, method: "GET" }
      const body = msg.body ?? {}
      if (typeof body !== "object" || Array.isArray(body)) return { error: "body 要是 JSON 对象", code: "bad-path" }
      if (JSON.stringify(body).length > PM_REQ_BODY_MAX) return { error: `body 超过 ${PM_REQ_BODY_MAX} 字`, code: "bad-path" }
      return { path: p, method: "POST", body: body as Json }
    }
    case "pm_doc": {
      const name = typeof msg.name === "string" ? msg.name : ""
      if (!DOC_NAME_RE.test(name)) return { error: "文档名不对（只认 docs/plan-*.html）" }
      return { path: `/api/doc?name=${name}`, method: "GET" }
    }
  }
  return { error: "不认识的帧" }
}

/** 返回要回给 app 的整帧（type = <帧>_result，带回 app 给的 req_id / sid / clientMsgId 方便对号） */
export async function pmRelay(msg: Json, env: PmRelayEnv = defaultPmEnv()): Promise<Json> {
  const echo: Json = { type: `${String(msg.type)}_result` }
  for (const k of ["req_id", "sid", "clientMsgId", "name"]) if (typeof msg[k] === "string") echo[k] = (msg[k] as string).slice(0, 100)
  const fail = (error: string, extra: Json = {}): Json => ({ ...echo, ok: false, error, ...extra })
  const r = requestOf(msg)
  if ("error" in r) return fail(r.error, r.code ? { code: r.code } : {})
  let token: string
  try { token = readFileSync(env.tokenFile, "utf8").trim() } catch { return fail("看板服务没开（没有 pm-api-token）", { code: "pm-down" }) }
  if (!token) return fail("看板服务没开（pm-api-token 是空的）", { code: "pm-down" })
  const timeout = msg.type === "pm_send" ? env.sendTimeoutMs : env.timeoutMs
  try {
    const res = await env.fetch(env.url + r.path, {
      method: r.method,
      headers: { authorization: `Bearer ${token}`, ...(r.body ? { "content-type": "application/json" } : {}) },
      body: r.body ? JSON.stringify(r.body) : undefined,
      signal: AbortSignal.timeout(timeout),
    })
    let data: Json = {}
    try { data = (await res.json()) as Json } catch { return fail(`看板服务回了看不懂的东西（HTTP ${res.status}）`, { http: res.status }) }
    if (!data || typeof data !== "object" || Array.isArray(data)) data = {}
    return { ok: res.ok, ...data, ...echo, http: res.status }
  } catch (e) {
    const name = (e as Error)?.name
    if (name === "TimeoutError" || name === "AbortError") return fail(`看板服务没响应（${timeout / 1000} 秒超时）`, { code: "pm-timeout" })
    return fail("看板服务没开", { code: "pm-down" })
  }
}
