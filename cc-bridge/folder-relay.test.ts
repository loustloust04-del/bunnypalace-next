// 文件夹转发的单测（docs/plan-folder-floor.md P2-4）：假 fetch，不起服务。
import { test, expect } from "bun:test"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { makeFolderRelay, type FolderRelayEnv } from "./folder-relay.ts"

const dir = mkdtempSync(join(tmpdir(), "folder-relay-"))
const tokenFile = join(dir, "token")
writeFileSync(tokenFile, "tok\n")
const REG = { folder: "/repo", accounts: [{ id: "default", config_dir: "/home/.claude" }], notify: "http://127.0.0.1:7891/folder/changed" }
const KEY = "default:11111111-0000-4000-8000-000000000000"

function relay(handler: (path: string, init: RequestInit) => Response | Promise<Response>, over: Partial<FolderRelayEnv> = {}) {
  const calls: string[] = []
  const env: FolderRelayEnv = {
    url: "http://pm", tokenFile, timeoutMs: 200,
    fetch: async (input, init) => { const p = input.replace("http://pm", ""); calls.push(`${init.method} ${p}`); return handler(p, init) },
    ...over,
  }
  return { r: makeFolderRelay(() => REG, env), calls }
}
const ok = (o: object, status = 200) => new Response(JSON.stringify(o), { status })

test("第一次来先登记，之后直接问；带回 req_id 和 hub 附带的东西", async () => {
  const { r, calls } = relay((p) => (p === "/api/folder/register" ? ok({ ok: true, id: "f1" }) : ok({ ok: true, seq: 3, sessions: [] })))
  const a = await r.request({ type: "folder_req", req_id: "q1", op: "sessions" }, () => ({ hub_sessions: { [KEY]: "mp-cc-1" } }))
  expect(a).toEqual({ type: "folder_req_result", req_id: "q1", op: "sessions", ok: true, seq: 3, sessions: [], hub_sessions: { [KEY]: "mp-cc-1" } })
  await r.request({ type: "folder_req", op: "sessions", after: 3 })
  expect(calls).toEqual(["POST /api/folder/register", "GET /api/folder/sessions?id=f1&after=0", "GET /api/folder/sessions?id=f1&after=3"])
})

test("登记带的是 hub 自己的配置和专用头；手机帧里的 folder / id 不进任何请求", async () => {
  let seen: RequestInit | undefined
  const { r, calls } = relay((p, init) => { if (p.endsWith("register")) seen = init; return p.endsWith("register") ? ok({ ok: true, id: "f1" }) : ok({ ok: true }) })
  await r.request({ type: "folder_req", op: "turns", key: KEY, from: 2, folder: "/etc", id: "x" })
  expect(JSON.parse(String(seen!.body))).toEqual(REG)
  expect((seen!.headers as Record<string, string>)["x-mp-folder"]).toBe("1")
  expect((seen!.headers as Record<string, string>).authorization).toBe("Bearer tok")
  expect(calls[1]).toBe(`GET /api/folder/turns?id=f1&key=${encodeURIComponent(KEY)}&from=2`)
})

test("op / key 不对：不发请求", async () => {
  const { r, calls } = relay(() => ok({}))
  expect(await r.request({ op: "register", folder: "/etc" })).toMatchObject({ ok: false, code: "bad-req" })
  expect(await r.request({ op: "turns", key: "a/../b" })).toMatchObject({ ok: false, code: "bad-req" })
  expect(calls).toEqual([])
})

test("看板服务那头不认这个文件夹了：重新登记再问一次", async () => {
  let n = 0
  const { r, calls } = relay((p) => {
    if (p.endsWith("register")) return ok({ ok: true, id: `f${++n}` })
    return p.includes("id=f1") ? ok({ ok: false, message: "这个文件夹没登记" }, 404) : ok({ ok: true, seq: 1, sessions: [] })
  })
  expect(await r.request({ op: "sessions" })).toMatchObject({ ok: true, seq: 1 })
  expect(calls).toEqual(["POST /api/folder/register", "GET /api/folder/sessions?id=f1&after=0", "POST /api/folder/register", "GET /api/folder/sessions?id=f2&after=0"])
})

test("看板服务没开 / 没 token / 超时 / 登记被拒：回原因，不抛", async () => {
  const down = relay(() => { throw new Error("ECONNREFUSED") })
  expect(await down.r.request({ op: "sessions", req_id: "q" })).toEqual({ type: "folder_req_result", req_id: "q", op: "sessions", ok: false, error: "看板服务没开", code: "pm-down" })
  const noToken = relay(() => ok({}), { tokenFile: join(dir, "没有") })
  expect(await noToken.r.request({ op: "sessions" })).toMatchObject({ ok: false, code: "pm-down" })
  const slow = relay((_p, init) => new Promise<Response>((_res, rej) => init.signal!.addEventListener("abort", () => rej(Object.assign(new Error("t"), { name: "TimeoutError" })))))
  expect(await slow.r.request({ op: "sessions" })).toMatchObject({ ok: false, code: "pm-timeout" })
  const refused = relay(() => ok({ ok: false, message: "这个文件夹在排除名单里" }, 403))
  expect(await refused.r.request({ op: "sessions" })).toMatchObject({ ok: false, code: "register", error: "这个文件夹在排除名单里" })
})

test("某条对话没有：把看板服务的话带回去，不当成要重新登记", async () => {
  const { r, calls } = relay((p) => (p.endsWith("register") ? ok({ ok: true, id: "f1" }) : ok({ ok: false, message: "没有这条对话" }, 404)))
  expect(await r.request({ op: "turns", key: KEY })).toMatchObject({ ok: false, http: 404, message: "没有这条对话" })
  expect(calls).toHaveLength(2)
})
