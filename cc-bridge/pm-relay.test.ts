// pm-relay 单测：假 fetch，不起 hub、不连 7890 / 4793（docs/plan-pm-board-app.md P1-2）
import { test, expect, beforeAll } from "bun:test"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pmRelay, PM_FRAMES, type PmRelayEnv } from "./pm-relay.ts"

const SID = "aaaaaaaa-0000-4000-8000-000000000001"
let dir: string
beforeAll(() => { dir = mkdtempSync(join(tmpdir(), "pm-relay-")); writeFileSync(join(dir, "tok"), "abc123\n") })

interface Call { url: string; init: RequestInit }
function env(respond: (c: Call) => Promise<Response>, o: Partial<PmRelayEnv> = {}): { env: PmRelayEnv; calls: Call[] } {
  const calls: Call[] = []
  return { calls, env: { url: "http://127.0.0.1:1", tokenFile: join(dir, "tok"), timeoutMs: 50, sendTimeoutMs: 80, fetch: (url, init) => { const c = { url, init }; calls.push(c); return respond(c) }, ...o } }
}
const ok = (o: object, status = 200) => async () => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } })

test("帧表", () => { expect([...PM_FRAMES].sort()).toEqual(["pm_board", "pm_doc", "pm_open", "pm_req", "pm_send", "pm_session"]) })

test("通：pm_board → GET 瘦身看板，带 Bearer，回 pm_board_result + req_id", async () => {
  const { env: e, calls } = env(ok({ view: "phone", counts: { wait: 1 } }))
  const r = await pmRelay({ type: "pm_board", req_id: "r1" }, e)
  expect(calls[0].url).toBe("http://127.0.0.1:1/api/board?view=phone")
  expect((calls[0].init.headers as Record<string, string>).authorization).toBe("Bearer abc123")
  expect(r).toMatchObject({ type: "pm_board_result", req_id: "r1", ok: true, view: "phone", http: 200 })
})

test("pm_session：sid 校验、turns 夹到 1–60", async () => {
  const { env: e, calls } = env(ok({ sid: SID, turns: [] }))
  expect(await pmRelay({ type: "pm_session", sid: "../../x" }, e)).toMatchObject({ ok: false, error: "sid 不是对话号" })
  expect(calls.length).toBe(0)
  await pmRelay({ type: "pm_session", sid: SID, turns: 999 }, e)
  expect(calls[0].url).toBe(`http://127.0.0.1:1/api/session?sid=${SID}&turns=60`)
})

test("pm_send：POST JSON 原样转；4793 的拒发（409）原样带回", async () => {
  const { env: e, calls } = env(ok({ ok: false, result: "refused", code: "awaiting", message: "它卡在权限弹窗上" }, 409))
  const r = await pmRelay({ type: "pm_send", sid: SID, text: "你好", clientMsgId: "c-123456" }, e)
  expect(calls[0].init.method).toBe("POST")
  expect(JSON.parse(String(calls[0].init.body))).toEqual({ sid: SID, text: "你好", clientMsgId: "c-123456" })
  expect(r).toMatchObject({ type: "pm_send_result", ok: false, code: "awaiting", http: 409, clientMsgId: "c-123456" })
})

test("pm_doc 通：GET /api/doc?name=，回 pm_doc_result 带 html / mtime / name / req_id", async () => {
  const { env: e, calls } = env(ok({ ok: true, name: "plan-open-source", html: "<h1>路线图</h1>", mtime: 1790000000000 }))
  const r = await pmRelay({ type: "pm_doc", name: "plan-open-source", req_id: "d1" }, e)
  expect(calls[0].url).toBe("http://127.0.0.1:1/api/doc?name=plan-open-source")
  expect(calls[0].init.method).toBe("GET")
  expect((calls[0].init.headers as Record<string, string>).authorization).toBe("Bearer abc123")
  expect(r).toMatchObject({ type: "pm_doc_result", req_id: "d1", name: "plan-open-source", ok: true, html: "<h1>路线图</h1>", mtime: 1790000000000, http: 200 })
})

test("pm_doc：name 不合法 → hub 直接拒，不转", async () => {
  const { env: e, calls } = env(ok({}))
  for (const name of ["notes", "plan-../../etc/passwd", "../docs/plan-x", "plan-x&name=y", "", 42]) {
    expect(await pmRelay({ type: "pm_doc", name }, e)).toMatchObject({ type: "pm_doc_result", ok: false, error: "文档名不对（只认 docs/plan-*.html）" })
  }
  expect(await pmRelay({ type: "pm_doc" }, e)).toMatchObject({ ok: false })
  expect(calls.length).toBe(0)
})

test("pm_doc：4793 不在 → 看板服务没开", async () => {
  const { env: e } = env(async () => { throw new TypeError("Unable to connect. Is the computer able to access the url?") })
  expect(await pmRelay({ type: "pm_doc", name: "plan-open-source", req_id: "d2" }, e)).toMatchObject({ type: "pm_doc_result", req_id: "d2", ok: false, code: "pm-down", error: "看板服务没开" })
})

test("超长 / 空文本：hub 直接拒，不转", async () => {
  const { env: e, calls } = env(ok({}))
  expect(await pmRelay({ type: "pm_send", sid: SID, text: "x".repeat(4001), clientMsgId: "c-1" }, e)).toMatchObject({ ok: false, error: "超过 4000 字" })
  expect(await pmRelay({ type: "pm_send", sid: SID, text: "  ", clientMsgId: "c-1" }, e)).toMatchObject({ ok: false, error: "空消息" })
  expect(calls.length).toBe(0)
})

test("4793 不在（连不上）→ 看板服务没开", async () => {
  const { env: e } = env(async () => { throw new TypeError("Unable to connect. Is the computer able to access the url?") })
  expect(await pmRelay({ type: "pm_board" }, e)).toMatchObject({ type: "pm_board_result", ok: false, code: "pm-down", error: "看板服务没开" })
})

test("超时：看板 50ms / 发送 80ms 各按各的上限", async () => {
  const hang = (c: Call) => new Promise<Response>((_, rej) => c.init.signal!.addEventListener("abort", () => rej(c.init.signal!.reason)))
  const { env: e } = env(hang)
  const t0 = Date.now()
  expect(await pmRelay({ type: "pm_board" }, e)).toMatchObject({ ok: false, code: "pm-timeout" })
  expect(Date.now() - t0).toBeLessThan(1000)
  expect(await pmRelay({ type: "pm_send", sid: SID, text: "hi", clientMsgId: "c-1" }, e)).toMatchObject({ ok: false, code: "pm-timeout" })
})

test("没有 token 文件 → 看板服务没开，不发请求", async () => {
  const { env: e, calls } = env(ok({}), { tokenFile: join(dir, "none") })
  expect(await pmRelay({ type: "pm_board" }, e)).toMatchObject({ ok: false, code: "pm-down" })
  expect(calls.length).toBe(0)
})

test("回的不是 JSON → 报错不崩", async () => {
  const { env: e } = env(async () => new Response("<html>502</html>", { status: 502 }))
  expect(await pmRelay({ type: "pm_board" }, e)).toMatchObject({ ok: false, http: 502 })
})

// ---------- pm_req：通用转发（docs/plan-dev-subapp-v2.md P0-c） ----------

test("pm_req GET：原样转到 4793 路径，带 Bearer，回 pm_req_result + req_id", async () => {
  const { env: e, calls } = env(ok({ view: "home", people: [] }))
  const r = await pmRelay({ type: "pm_req", req_id: "q1", method: "GET", path: "/api/home" }, e)
  expect(calls[0].url).toBe("http://127.0.0.1:1/api/home")
  expect(calls[0].init.method).toBe("GET")
  expect(calls[0].init.body).toBeUndefined()
  expect((calls[0].init.headers as Record<string, string>).authorization).toBe("Bearer abc123")
  expect(r).toMatchObject({ type: "pm_req_result", req_id: "q1", ok: true, http: 200, view: "home" })
  await pmRelay({ type: "pm_req", req_id: "q2", method: "GET", path: `/api/session?sid=${SID}` }, e)
  expect(calls[1].url).toBe(`http://127.0.0.1:1/api/session?sid=${SID}`)
})

test("pm_req POST：body 原样 JSON 转；4793 的 4xx 原样带回", async () => {
  const { env: e, calls } = env(ok({ ok: false, code: "not-found", message: "找不到这个对话" }, 404))
  const body = { sid: SID, text: "你好", clientMsgId: "c-123456" }
  const r = await pmRelay({ type: "pm_req", req_id: "q3", method: "POST", path: "/api/send", body }, e)
  expect(calls[0].init.method).toBe("POST")
  expect(JSON.parse(String(calls[0].init.body))).toEqual(body)
  expect((calls[0].init.headers as Record<string, string>)["content-type"]).toBe("application/json")
  expect(r).toMatchObject({ type: "pm_req_result", req_id: "q3", ok: false, http: 404, code: "not-found" })
})

test("pm_req：路径 / method / body 不对 → hub 直接拒（bad-path），不转", async () => {
  const { env: e, calls } = env(ok({}))
  const bad: Record<string, unknown>[] = [
    { method: "GET", path: "/kpi" }, { method: "GET", path: "/api/../kpi" }, { method: "GET", path: "/api//board" },
    { method: "GET", path: "http://evil/api/x" }, { method: "GET", path: "/api/board?x=<script>" }, { method: "GET", path: "/API/home" },
    { method: "DELETE", path: "/api/home" }, { method: "POST", path: "/api/send", body: [1] }, { method: "POST", path: "/api/send", body: { t: "x".repeat(64 * 1024) } },
    { method: "GET" }, { path: "/api/home" },
  ]
  for (const b of bad) expect(await pmRelay({ type: "pm_req", req_id: "b", ...b }, e)).toMatchObject({ type: "pm_req_result", req_id: "b", ok: false, code: "bad-path" })
  expect(calls.length).toBe(0)
})

test("pm_req：4793 不在 / 超时 → pm-down / pm-timeout（3 秒档）", async () => {
  const { env: down } = env(async () => { throw new TypeError("Unable to connect") })
  expect(await pmRelay({ type: "pm_req", req_id: "d", method: "GET", path: "/api/home" }, down)).toMatchObject({ ok: false, code: "pm-down" })
  const hang = (c: Call) => new Promise<Response>((_, rej) => c.init.signal!.addEventListener("abort", () => rej(c.init.signal!.reason)))
  const { env: slow } = env(hang)
  const t0 = Date.now()
  expect(await pmRelay({ type: "pm_req", req_id: "t", method: "POST", path: "/api/send", body: {} }, slow)).toMatchObject({ ok: false, code: "pm-timeout" })
  expect(Date.now() - t0).toBeLessThan(80)   // 走的是 50ms 读档，不是 80ms 老发送档
})
