// 文件夹模式的 hub → 本机 session 看板服务（scripts/pm，4793）的文件夹接口（docs/plan-folder-floor.md P2-4）。
// 只转发不计算：hub 不扫 session 文件、不读历史，索引在看板服务的 Worker 里。
// 和 pm-relay.ts 分开：手机发来的 folder_req 只能选「列表 / 某条的内容」，文件夹是哪个由 hub 自己的配置登记，手机改不了；
// 看板服务这组接口要多带一个头，通用的 pm_req 转发带不了，借不到。
import { timedSyncFs } from "./block-ledger"
const { readFileSync } = timedSyncFs("folder-relay ")
import { homedir } from "node:os"
import { join } from "node:path"

export const FOLDER_REQ_TIMEOUT_MS = 5000
const KEY_RE = /^[\w.-]{1,40}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

type Json = Record<string, unknown>
export interface FolderRegistration { folder: string; accounts: { id: string; config_dir: string }[]; notify: string }
export interface FolderRelayEnv {
  url: string
  tokenFile: string
  fetch: (input: string, init: RequestInit) => Promise<Response>
  timeoutMs: number
}
export function defaultFolderEnv(): FolderRelayEnv {
  return {
    url: process.env.MP_PM_URL ?? "http://127.0.0.1:4793",
    tokenFile: process.env.MP_PM_API_TOKEN_FILE ?? join(process.env.MP_PM_Q ?? join(homedir(), ".mp-merge-queue"), "pm-api-token"),
    fetch: (input, init) => fetch(input, init),
    timeoutMs: FOLDER_REQ_TIMEOUT_MS,
  }
}

type Reply = { http: number; data: Json } | { error: string; code: string }

export function makeFolderRelay(reg: () => FolderRegistration, env: FolderRelayEnv = defaultFolderEnv()) {
  let id: string | null = null

  async function call(path: string, method: "GET" | "POST", body?: Json): Promise<Reply> {
    let token: string
    try { token = readFileSync(env.tokenFile, "utf8").trim() } catch { return { error: "看板服务没开（没有 pm-api-token）", code: "pm-down" } }
    if (!token) return { error: "看板服务没开（pm-api-token 是空的）", code: "pm-down" }
    try {
      const res = await env.fetch(env.url + path, {
        method,
        headers: { authorization: `Bearer ${token}`, "x-mp-folder": "1", ...(body ? { "content-type": "application/json" } : {}) },
        body: body ? JSON.stringify(body) : undefined,
        signal: AbortSignal.timeout(env.timeoutMs),
      })
      let data: Json = {}
      try { data = (await res.json()) as Json } catch { return { error: `看板服务回了看不懂的东西（HTTP ${res.status}）`, code: "pm-bad" } }
      if (!data || typeof data !== "object" || Array.isArray(data)) data = {}
      return { http: res.status, data }
    } catch (e) {
      const name = (e as Error)?.name
      if (name === "TimeoutError" || name === "AbortError") return { error: `看板服务没响应（${env.timeoutMs / 1000} 秒超时）`, code: "pm-timeout" }
      return { error: "看板服务没开", code: "pm-down" }
    }
  }

  /** 向看板服务登记这台 hub 的文件夹。成功返回 null，失败返回原因 */
  async function register(): Promise<{ error: string; code: string } | null> {
    const r = await call("/api/folder/register", "POST", reg() as unknown as Json)
    if ("error" in r) return r
    if (r.http !== 200 || typeof r.data.id !== "string") return { error: typeof r.data.message === "string" ? r.data.message : `登记不了（HTTP ${r.http}）`, code: "register" }
    id = r.data.id
    return null
  }

  /** 手机的 folder_req → 回给手机的整帧（type = folder_req_result，带回 req_id）。extra = hub 自己知道、要一起带回去的东西 */
  async function request(msg: Json, extra: (op: string) => Json = () => ({})): Promise<Json> {
    const echo: Json = { type: "folder_req_result" }
    if (typeof msg.req_id === "string") echo.req_id = msg.req_id.slice(0, 100)
    const op = typeof msg.op === "string" ? msg.op : ""
    echo.op = op.slice(0, 20)
    const fail = (error: string, code: string): Json => ({ ...echo, ok: false, error, code })
    const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? Math.floor(v) : 0)
    let path: (fid: string) => string
    if (op === "sessions") path = (fid) => `/api/folder/sessions?id=${fid}&after=${num(msg.after)}`
    else if (op === "turns") {
      const key = typeof msg.key === "string" ? msg.key : ""
      if (!KEY_RE.test(key)) return fail("key 不对", "bad-req")
      path = (fid) => `/api/folder/turns?id=${fid}&key=${encodeURIComponent(key)}&from=${num(msg.from)}`
    } else return fail("不认识的 op", "bad-req")

    for (let attempt = 0; attempt < 2; attempt++) {
      if (!id) { const e = await register(); if (e) return fail(e.error, e.code) }
      const r = await call(path(id!), "GET")
      if ("error" in r) return fail(r.error, r.code)
      if (r.http === 404 && attempt === 0 && op === "sessions") { id = null; continue }   // 看板服务那头的登记没了（换过状态目录）：重新登记再来一次
      if (r.http !== 200) return { ...echo, ...r.data, ok: false, http: r.http }
      return { ...r.data, ...extra(op), ...echo, ok: true }
    }
    return fail("看板服务不认这个文件夹", "register")
  }

  return { register, request }
}
