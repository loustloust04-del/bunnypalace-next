// 设备密钥对鉴权集成（docs/plan-hub-keypair-auth.md K1 测试）：隔离 hub（随机端口、临时 secrets、tmux 干跑、测试口令），
// 绝不碰 7890。本机连接是信任的、不走挑战，所以挑战路径一律走中继入口 Unix socket（经测试自己开的 TCP 转发）或非回环 listener。
// /agora 不能走中继入口（入口白名单拒它），正向用例走 LAN listener；本机没有非回环地址就跳过那几条。
import { test, expect, beforeAll, afterAll } from "bun:test"
import { randomUUID } from "node:crypto"
import { existsSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs"
import { connect, createServer, type Server, type Socket } from "node:net"
import { networkInterfaces, tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { WebSocket } from "ws"
import { normalizeAud, normalizeManualCode, tokenSecret } from "./device-auth.ts"
import { authFrame, challengeValid, expectedHubProof, makeTestDevice, newConn, v2QueryString, type Challenge, type Conn, type Cred, type TestDevice } from "./device-auth-testkit.ts"

// 测试专用秘密值：跑完全部用例后在 hub 日志里搜它们（T15）
const TEST_TOKEN = "kp-test-口令-7c1f"
const BUNDLE = "com.test.kp"
const SECRET_VALUES = new Set<string>([TEST_TOKEN])
const LAN = Object.values(networkInterfaces()).flat().find((a) => a && a.family === "IPv4" && !a.internal)?.address

interface Rig { hub: ReturnType<typeof Bun.spawn>; port: number; sock: string; secrets: string; out: string[]; proxy: Server; proxyPort: number; lan: boolean }
const rigs: Rig[] = []

async function drain(s: ReadableStream<Uint8Array>, out: string[]): Promise<void> {
  const dec = new TextDecoder()
  for await (const chunk of s) out.push(dec.decode(chunk))
}

/// secrets 给了就复用（模拟重启）；prepare 在 hub 启动前改状态目录（坏钥之类）
async function startRig(o: { secrets?: string; lan?: boolean; prepare?: (dir: string) => void; env?: Record<string, string> } = {}): Promise<Rig> {
  const secrets = o.secrets ?? mkdtempSync(join(tmpdir(), "cc-kp-"))
  const sock = join(mkdtempSync(join(tmpdir(), "kp-")), "in", "hub.sock")
  // 中继入口只要 relay.json 在就开；connector 关掉，不连任何中继
  writeFileSync(join(secrets, "relay.json"), JSON.stringify({ host: "relay.example.test", port: 443, secret: "cd".repeat(32), tls: true }))
  o.prepare?.(secrets)
  const port = 20890 + Math.floor(Math.random() * 1000)
  const lan = !!(o.lan && LAN)
  const hub = Bun.spawn(["bun", "run", "hub.ts"], {
    cwd: import.meta.dir,
    stdout: "pipe", stderr: "pipe",
    env: {
      ...process.env,
      MP_CC_TMUX_DRY_RUN: "1", MP_CC_HUB_TOKEN: TEST_TOKEN, MP_CC_HUB_PORT: String(port), MP_CC_HUB_HOST: "127.0.0.1",
      MP_CC_SECRETS_DIR: secrets, MP_CC_AGENT_DIR: secrets, MP_CC_WORKDIR: secrets, MP_CODEX_WORKDIR: join(secrets, "gpt-rp"),
      MP_APNS_KEY_PATH: join(secrets, "no-such-key.p8"), MP_CC_LA_INTERVAL_MS: "3600000",
      MP_CC_RELAY_SOCK: sock, MP_CC_RELAY_CONNECTOR: "off", MP_CC_ALLOWED_BUNDLES: BUNDLE,
      MP_CC_HUB_EXTRA_HOSTS: lan ? LAN! : "", MP_CC_AUTH_TIMEOUT_MS: "1500",
      TMUX_TMPDIR: secrets,
      ...o.env,
    },
  })
  const out: string[] = []
  void drain(hub.stdout as ReadableStream<Uint8Array>, out)
  void drain(hub.stderr as ReadableStream<Uint8Array>, out)
  // ws 客户端在 Bun 里走不了 Unix socket：开一个本机 TCP 口原样转给中继入口（hub 看到的仍是中继入口进来的连接）
  const proxy = createServer((c) => {
    const u = connect(sock)
    c.pipe(u); u.pipe(c)
    const end = () => { c.destroy(); u.destroy() }
    c.on("error", end); u.on("error", end); c.on("close", end); u.on("close", end)
  })
  await new Promise<void>((r) => proxy.listen(0, "127.0.0.1", r))
  const addr = proxy.address()
  const rig: Rig = { hub, port, sock, secrets, out, proxy, proxyPort: addr && typeof addr === "object" ? addr.port : 0, lan }
  rigs.push(rig)
  const deadline = Date.now() + 10_000
  while (Date.now() < deadline) {
    if (hub.exitCode !== null) throw new Error(`test hub exited ${hub.exitCode}: ${out.join("").slice(-2000)}`)
    if (existsSync(sock) && (!lan || out.join("").includes(`listening on ws://${LAN}:`))) {
      try { if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) return rig } catch {}
    }
    await Bun.sleep(100)
  }
  throw new Error(`test hub not ready: ${out.join("").slice(-2000)}`)
}

async function stopRig(r: Rig): Promise<void> {
  r.hub.kill()
  r.proxy.close()
  await r.hub.exited
}

type Frame = Record<string, unknown> & { type?: string }
interface Client {
  ws: WebSocket
  frames: Frame[]
  closed: Promise<{ code: number; reason: string }>
  next(pred: (f: Frame) => boolean, ms?: number): Promise<Frame>
  send(s: string): void
}

function openClient(url: string): Promise<Client> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url)
    const frames: Frame[] = []
    const waiters: { pred: (f: Frame) => boolean; resolve: (f: Frame) => void }[] = []
    let closeInfo: (v: { code: number; reason: string }) => void = () => {}
    const closed = new Promise<{ code: number; reason: string }>((r) => { closeInfo = r })
    ws.on("message", (raw) => {
      let f: Frame
      try { f = JSON.parse(raw.toString()) } catch { return }
      frames.push(f)
      for (const w of [...waiters]) if (w.pred(f)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(f) }
    })
    ws.on("close", (code, reason) => closeInfo({ code, reason: reason.toString() }))
    ws.on("error", (e) => reject(e))
    const client: Client = {
      ws, frames, closed,
      next(pred, ms = 3000) {
        const hit = frames.find(pred)
        if (hit) return Promise.resolve(hit)
        return new Promise((res, rej) => {
          const t = setTimeout(() => rej(new Error(`等帧超时；收到 ${frames.map((x) => x.type).join(",")}`)), ms)
          waiters.push({ pred, resolve: (f) => { clearTimeout(t); res(f) } })
        })
      },
      send(s) { ws.send(s) },
    }
    ws.on("open", () => resolve(client))
  })
}
const isType = (t: string) => (f: Frame) => f.type === t
const isAuthResult = (f: Frame) => f.type === "auth_ok" || f.type === "auth_fail"

function v2URL(r: Rig, dev: TestDevice, path: "/cc" | "/agora", via: "relay" | "lan", aud?: string, extraQuery = ""): { url: string; conn: Conn } {
  const base = via === "relay" ? `ws://127.0.0.1:${r.proxyPort}` : `ws://${LAN}:${r.port}`
  const conn = newConn(path, aud ?? normalizeAud(`${base}${path}`))
  return { url: `${base}${path}?${v2QueryString(dev, conn, BUNDLE)}${extraQuery}`, conn }
}

/// 走一轮新协议：收挑战 → 设备侧核挑战 → 发 auth → 等 auth_ok / auth_fail
async function v2Round(r: Rig, dev: TestDevice, cred: Cred, o: { path?: "/cc" | "/agora"; via?: "relay" | "lan"; aud?: string; then?: string[] } = {}) {
  const { url, conn } = v2URL(r, dev, o.path ?? "/cc", o.via ?? "relay", o.aud)
  const c = await openClient(url)
  const ch = await c.next(isType("auth_challenge")) as unknown as Challenge
  SECRET_VALUES.add(ch.sn); SECRET_VALUES.add(ch.sig_hub); SECRET_VALUES.add(conn.cn)
  expect(challengeValid(dev, ch, conn)).toBe(true)
  const frame = authFrame(dev, ch, conn, cred)
  const parsed = JSON.parse(frame) as { proof?: string; sig_dev: string }
  SECRET_VALUES.add(parsed.sig_dev)
  if (parsed.proof) SECRET_VALUES.add(parsed.proof)
  c.send(frame)
  for (const t of o.then ?? []) c.send(t)
  const result = await c.next(isAuthResult)
  if (typeof result.hub_proof === "string") SECRET_VALUES.add(result.hub_proof)
  return { c, ch, conn, result }
}
const tokenCred = (reauth = false): Cred => ({ kind: "token", secret: tokenSecret(TEST_TOKEN), reauth })

async function pair(r: Rig): Promise<Record<string, unknown>> {
  const body = await (await fetch(`http://127.0.0.1:${r.port}/pair?token=${encodeURIComponent(TEST_TOKEN)}`)).json() as Record<string, unknown>
  for (const k of ["pc", "mc"]) if (typeof body[k] === "string") SECRET_VALUES.add(body[k] as string)
  return body
}
const admin = (r: Rig, path: string, body?: object) => fetch(`http://127.0.0.1:${r.port}${path}?token=${encodeURIComponent(TEST_TOKEN)}`, body ? { method: "POST", body: JSON.stringify(body) } : {})
const devicesFile = (r: Rig) => JSON.parse(readFileSync(join(r.secrets, "devices.json"), "utf-8")) as { v: number; devices: { id: string; revoked_at: number | null; added_via: string; last_from: string | null; reauthorized_at: number | null }[] }

/// 经中继入口发一段原始 HTTP，收到关闭或超时为止
function viaSocket(sock: string, text: string, timeoutMs = 2000): Promise<string> {
  return new Promise((resolve) => {
    const s = connect(sock)
    const chunks: Buffer[] = []
    const done = () => { clearTimeout(timer); s.destroy(); resolve(Buffer.concat(chunks).toString("latin1")) }
    const timer = setTimeout(done, timeoutMs)
    s.on("data", (d) => chunks.push(d))
    s.on("close", done)
    s.on("error", done)
    s.write(text)
  })
}

// ── 原始 WS（T4：两帧挤在同一次 write 里）──
function maskedFrame(text: string): Buffer {
  const payload = Buffer.from(text, "utf8")
  const mask = Buffer.from([1, 2, 3, 4])
  const len = payload.length
  const head = len < 126 ? Buffer.from([0x81, 0x80 | len]) : (() => { const h = Buffer.alloc(4); h[0] = 0x81; h[1] = 0x80 | 126; h.writeUInt16BE(len, 2); return h })()
  const body = Buffer.from(payload.map((b, i) => b ^ mask[i % 4]))
  return Buffer.concat([head, mask, body])
}
function serverFrames(buf: Buffer): { opcode: number; payload: Buffer }[] {
  const at = buf.indexOf("\r\n\r\n")
  if (at < 0) return []
  let i = at + 4
  const out: { opcode: number; payload: Buffer }[] = []
  while (i + 2 <= buf.length) {
    const opcode = buf[i] & 0x0f
    let len = buf[i + 1] & 0x7f
    i += 2
    if (len === 126) { len = buf.readUInt16BE(i); i += 2 } else if (len === 127) { len = Number(buf.readBigUInt64BE(i)); i += 8 }
    if (i + len > buf.length) break
    out.push({ opcode, payload: buf.subarray(i, i + len) })
    i += len
  }
  return out
}
interface RawConn { s: Socket; texts: () => Frame[]; until: (pred: (fs: Frame[]) => boolean, ms?: number) => Promise<Frame[]> }
function rawOpen(r: Rig, query: string): RawConn {
  const s = connect(r.sock)
  let buf = Buffer.alloc(0)
  s.on("data", (d) => { buf = Buffer.concat([buf, d]) })
  s.on("error", () => {})
  s.write([`GET /cc?${query} HTTP/1.1`, "Host: relay.example.test", "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Version: 13"].join("\r\n") + "\r\n\r\n")
  const texts = () => serverFrames(buf).filter((f) => f.opcode === 1).map((f) => JSON.parse(f.payload.toString()) as Frame)
  return {
    s, texts,
    async until(pred, ms = 3000) {
      const end = Date.now() + ms
      while (Date.now() < end) { const fs = texts(); if (pred(fs)) return fs; await Bun.sleep(20) }
      throw new Error(`raw 等帧超时：${texts().map((f) => f.type).join(",")}`)
    },
  }
}

let A: Rig, B: Rig
const devA = makeTestDevice()

beforeAll(async () => { [A, B] = await Promise.all([startRig({ lan: true }), startRig()]) })
afterAll(async () => { for (const r of rigs) { r.hub.kill(); r.proxy.close() } })

// ── /pair（K1-A / K1-C.6）──

test("T13 中继入口 /pair?token=对的 → 404（路由白名单）", async () => {
  const res = await viaSocket(A.sock, `GET /pair?token=${encodeURIComponent(TEST_TOKEN)} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n`)
  expect(res.split("\r\n")[0]).toBe("HTTP/1.1 404 Not Found")
  expect(res).not.toContain(TEST_TOKEN)
})

test("T14 直接远程 /pair?token=对的 → 403（K1-A：带转发头 / Host 不是本机名 / LAN 直连都算远程）", async () => {
  const url = `http://127.0.0.1:${A.port}/pair?token=${encodeURIComponent(TEST_TOKEN)}`
  for (const headers of [{ "x-forwarded-for": "198.51.100.7" }, { forwarded: "for=198.51.100.7" }, { host: "hub.example.test" }]) {
    const res = await fetch(url, { headers })
    expect(`${JSON.stringify(headers)} ${res.status}`).toBe(`${JSON.stringify(headers)} 403`)
    expect(await res.text()).not.toContain(TEST_TOKEN)
  }
  // 远程连口令都不用对就 403（先挡来源，不暴露口令对不对）
  expect((await fetch(`http://127.0.0.1:${A.port}/pair?token=wrong`, { headers: { "x-forwarded-for": "198.51.100.7" } })).status).toBe(403)
  if (A.lan) expect((await fetch(`http://${LAN}:${A.port}/pair?token=${encodeURIComponent(TEST_TOKEN)}`)).status).toBe(403)
  // 本机 + 对的口令照旧 200
  const ok = await fetch(url)
  expect(ok.status).toBe(200)
  expect(((await ok.json()) as { mpcc: number }).mpcc).toBe(1)
})

test("K1-C.6 /pair 合一格式：v1 字段照旧 + v2 的 hid / hk / n / pc / mc / exp；每次出新码", async () => {
  const hello = await (await openClient(`ws://127.0.0.1:${A.port}/cc`)).next(isType("hello"))
  const p = await pair(A)
  expect(p).toMatchObject({ mpcc: 1, t: TEST_TOKEN, v: 2, hid: hello.hub_id })
  expect(Object.keys(p).slice(0, 4)).toEqual(["mpcc", "u", "u2", "t"])
  expect(p.hk).toMatch(/^[A-Za-z0-9_-]{43}$/)
  expect(p.pc).toMatch(/^[A-Za-z0-9_-]{43}$/)
  expect(p.mc).toMatch(/^[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}$/)
  expect(typeof p.n).toBe("string")
  expect(Math.abs((p.exp as number) - (Date.now() / 1000 + 600))).toBeLessThan(5)
  const p2 = await pair(A)
  expect(p2.pc).not.toBe(p.pc)
})

// ── 挑战主流程（/cc 走中继入口）──

test("hello capabilities 带 device_auth；没口令的 v=2 连接先收 auth_challenge（hk 对得上 hub_pub、sig_hub 验得过、hub_id 同 hello）", async () => {
  const hello = await (await openClient(`ws://127.0.0.1:${A.port}/cc`)).next(isType("hello"))
  expect(hello.capabilities).toContain("device_auth")
  const { url, conn } = v2URL(A, devA, "/cc", "relay")
  expect(url).not.toContain("token=")
  const c = await openClient(url)
  const ch = await c.next(isType("auth_challenge")) as unknown as Challenge
  expect(c.frames[0].type).toBe("auth_challenge")
  expect(ch.hub_id).toBe(hello.hub_id as string)
  expect(challengeValid(devA, ch, conn)).toBe(true)
  c.ws.close()
})

test("首次 kind=token：auth_ok（enrolled、hub_proof 对）→ 然后才是 hello；登记进 devices.json（via token、来自 relay）", async () => {
  const { c, ch, conn, result } = await v2Round(A, devA, tokenCred())
  expect(result).toEqual({ type: "auth_ok", via: "token", device_id: devA.did, enrolled: true, hub_proof: expectedHubProof(devA, ch, conn, "token", tokenSecret(TEST_TOKEN), true) })
  const hello = await c.next(isType("hello"))
  expect(c.frames.indexOf(result)).toBe(1)
  expect(c.frames.indexOf(hello)).toBe(2)
  const rec = devicesFile(A).devices.find((d) => d.id === devA.did)
  expect(rec).toMatchObject({ added_via: "token", last_from: "relay", revoked_at: null })
  c.ws.close()
})

test("之后 kind=key：auth_ok 不带 hub_proof，接着 hello；业务帧照常（list_sessions）", async () => {
  const { c, result } = await v2Round(A, devA, { kind: "key" })
  expect(result).toEqual({ type: "auth_ok", via: "key", device_id: devA.did, enrolled: true })
  await c.next(isType("hello"))
  c.send(JSON.stringify({ type: "list_sessions" }))
  expect((await c.next(isType("list_sessions_result"))).type).toBe("list_sessions_result")
  c.ws.close()
})

test("不认识的设备 kind=key → auth_fail unknown_device + 1008 auth，一帧业务都不发", async () => {
  const { c, result } = await v2Round(A, makeTestDevice(), { kind: "key" })
  expect(result).toEqual({ type: "auth_fail", reason: "unknown_device" })
  expect(await c.closed).toEqual({ code: 1008, reason: "auth" })
  expect(c.frames.map((f) => f.type)).toEqual(["auth_challenge", "auth_fail"])
})

test("配对码：/pair 的 mc 混写小写也能配（kind=code，hub_proof 用 mc）；同一码再用 → bad_proof", async () => {
  const p = await pair(A)
  const dev = makeTestDevice()
  const typed = (p.mc as string).toLowerCase().replace("-", " - ")
  const r1 = await v2Round(A, dev, { kind: "code", secret: normalizeManualCode(typed) })
  expect(r1.result).toEqual({ type: "auth_ok", via: "code", device_id: dev.did, enrolled: true, hub_proof: expectedHubProof(dev, r1.ch, r1.conn, "code", normalizeManualCode(p.mc as string), true) })
  r1.c.ws.close()
  const r2 = await v2Round(A, makeTestDevice(), { kind: "code", secret: p.pc as string })
  expect(r2.result).toEqual({ type: "auth_fail", reason: "bad_proof" })
  expect(devicesFile(A).devices.find((d) => d.id === dev.did)?.added_via).toBe("code")
})

test("T4 auth 和下一帧挤在同一次 write：attach 一次、下一帧不丢", async () => {
  const conn = newConn("/cc", "relay.example.test:443")
  const raw = rawOpen(A, v2QueryString(devA, conn, BUNDLE))
  const [ch] = await raw.until((fs) => fs.length >= 1) as unknown as Challenge[]
  raw.s.write(Buffer.concat([maskedFrame(authFrame(devA, ch, conn, { kind: "key" })), maskedFrame(JSON.stringify({ type: "list_sessions" }))]))
  await raw.until((xs) => xs.some((f) => f.type === "list_sessions_result"))
  await Bun.sleep(200)
  const types = raw.texts().map((f) => f.type)
  expect(types.filter((t) => t === "auth_ok").length).toBe(1)
  expect(types.filter((t) => t === "hello").length).toBe(1)
  expect(types.filter((t) => t === "list_sessions_result").length).toBe(1)
  expect(types.indexOf("auth_ok")).toBeLessThan(types.indexOf("hello"))
  raw.s.destroy()
})

test("T4 鉴权完成后再来 auth（同一次 write 里紧跟着也算）→ auth_fail bad_request + 1008，后面的业务帧不再分派（K1 返修 r1）", async () => {
  const conn = newConn("/cc", "relay.example.test:443")
  const raw = rawOpen(A, v2QueryString(devA, conn, BUNDLE))
  const [ch] = await raw.until((fs) => fs.length >= 1) as unknown as Challenge[]
  const auth = authFrame(devA, ch, conn, { kind: "key" })
  raw.s.write(Buffer.concat([maskedFrame(auth), maskedFrame(auth), maskedFrame(JSON.stringify({ type: "list_sessions" }))]))
  await raw.until((xs) => xs.some((f) => f.type === "auth_fail"))
  await Bun.sleep(300)
  const types = raw.texts().map((f) => f.type)
  expect(types.filter((t) => t === "auth_ok").length).toBe(1)
  expect(types.filter((t) => t === "hello").length).toBe(1)
  expect(raw.texts().find((f) => f.type === "auth_fail")).toEqual({ type: "auth_fail", reason: "bad_request" })
  expect(types).not.toContain("list_sessions_result")
  raw.s.destroy()
  // 鉴权完成后单独再发一次（不同 write）也一样；/agora 那条也一样（不会被当成错误业务 envelope 回 agora_response）
  const late = await v2Round(A, devA, { kind: "key" })
  await late.c.next(isType("hello"))
  late.c.send(authFrame(devA, late.ch, late.conn, { kind: "key" }))
  expect(await late.c.next((f) => f.type === "auth_fail")).toEqual({ type: "auth_fail", reason: "bad_request" })
  expect(await late.c.closed).toEqual({ code: 1008, reason: "auth" })
  if (!A.lan) return console.warn("本机无非回环地址，跳过 /agora 重复 auth")
  const ag = await v2Round(A, devA, { kind: "key" }, { path: "/agora", via: "lan" })
  ag.c.send(authFrame(devA, ag.ch, ag.conn, { kind: "key" }))
  expect(await ag.c.next((f) => f.type === "auth_fail")).toEqual({ type: "auth_fail", reason: "bad_request" })
  expect(await ag.c.closed).toEqual({ code: 1008, reason: "auth" })
  expect(ag.c.frames.some((f) => f.type === "agora_response")).toBe(false)
})

test("鉴权首帧 binary → bad_request；恰好 8192 字节照常验、8193 字节 bad_request", async () => {
  const bin = await openClient(v2URL(A, devA, "/cc", "relay").url)
  await bin.next(isType("auth_challenge"))
  bin.ws.send(Buffer.from('{"type":"auth"}'), { binary: true })
  expect(await bin.next(isAuthResult)).toEqual({ type: "auth_fail", reason: "bad_request" })
  for (const [size, want] of [[8192, "auth_ok"], [8193, "auth_fail"]] as const) {
    const { url, conn } = v2URL(A, devA, "/cc", "relay")
    const c = await openClient(url)
    const ch = await c.next(isType("auth_challenge")) as unknown as Challenge
    const base = authFrame(devA, ch, conn, { kind: "key" }, { pad: "" })
    const frame = base.replace('"pad":""', `"pad":"${"x".repeat(size - Buffer.byteLength(base))}"`)
    expect(Buffer.byteLength(frame)).toBe(size)
    c.send(frame)
    const r = await c.next(isAuthResult)
    expect(`${size} ${r.type} ${r.reason ?? ""}`).toBe(`${size} ${want} ${want === "auth_fail" ? "bad_request" : ""}`)
    c.ws.close()
  }
})

test("超时与成功同刻（超时前后几毫秒内发 auth，压测非确定性）：每条连接要么 auth_ok + hello，要么 expired 关闭，绝不两样都有", async () => {
  // 测试 hub 的 MP_CC_AUTH_TIMEOUT_MS=1500：挑战到手后在 1480–1520ms 之间发 auth
  const runs = await Promise.all(Array.from({ length: 12 }, async (_, i) => {
    const { url, conn } = v2URL(A, devA, "/cc", "relay")
    const c = await openClient(url)
    const ch = await c.next(isType("auth_challenge")) as unknown as Challenge
    await Bun.sleep(1480 + i * 4)
    try { c.send(authFrame(devA, ch, conn, { kind: "key" })) } catch {}
    await Bun.sleep(600)
    c.ws.close()
    return c.frames.map((f) => f.type)
  }))
  for (const types of runs) {
    const ok = types.includes("auth_ok"), expired = types.includes("auth_fail")
    expect(`${types.join(",")} ${ok !== expired}`).toBe(`${types.join(",")} true`)
    if (ok) expect(types.filter((t) => t === "hello").length).toBe(1)
    else expect(types).not.toContain("hello")
  }
})

test("T4 鉴权前先来别的帧 → bad_request；鉴权中断开 / 超时 → hub 照常；超时回 expired", async () => {
  const { url } = v2URL(A, devA, "/cc", "relay")
  const c1 = await openClient(url)
  await c1.next(isType("auth_challenge"))
  c1.send(JSON.stringify({ type: "list_sessions" }))
  expect(await c1.next(isAuthResult)).toEqual({ type: "auth_fail", reason: "bad_request" })
  expect((await c1.closed).code).toBe(1008)
  expect(c1.frames.some((f) => f.type === "hello" || f.type === "list_sessions_result")).toBe(false)
  const c2 = await openClient(v2URL(A, devA, "/cc", "relay").url)
  await c2.next(isType("auth_challenge"))
  c2.ws.terminate()
  const c3 = await openClient(v2URL(A, devA, "/cc", "relay").url)
  await c3.next(isType("auth_challenge"))
  expect(await c3.next(isAuthResult, 4000)).toEqual({ type: "auth_fail", reason: "expired" })
  expect(await c3.closed).toEqual({ code: 1008, reason: "auth" })
  expect((await fetch(`http://127.0.0.1:${A.port}/health`)).ok).toBe(true)
})

test("v=2 query 坏 / 重复 → bad_request；没 bundle / bundle 不对 → 1008 bundle（挑战都不发）", async () => {
  const bad = await openClient(`ws://127.0.0.1:${A.proxyPort}/cc?v=2&did=short&cn=x&aud=a:1&bundle=${BUNDLE}`)
  expect(await bad.next(isAuthResult)).toEqual({ type: "auth_fail", reason: "bad_request" })
  const { url } = v2URL(A, devA, "/cc", "relay")
  const dup = await openClient(`${url}&did=${devA.did}`)
  expect(await dup.next(isAuthResult)).toEqual({ type: "auth_fail", reason: "bad_request" })
  const dupTok = await openClient(`ws://127.0.0.1:${A.proxyPort}/cc?token=${encodeURIComponent(TEST_TOKEN)}&token=x&bundle=${BUNDLE}`)
  expect(await dupTok.next(isAuthResult)).toEqual({ type: "auth_fail", reason: "bad_request" })
  const noBundle = await openClient(url.replace(`&bundle=${BUNDLE}`, ""))
  expect(await noBundle.closed).toEqual({ code: 1008, reason: "bundle" })
  expect(noBundle.frames).toEqual([])
  // 重复 bundle（第一个还不合法）也是 bad_request，不是 bundle
  const dupBundle = await openClient(`${url.replace(`&bundle=${BUNDLE}`, "&bundle=com.bad")}&bundle=${BUNDLE}`)
  expect(await dupBundle.next(isAuthResult)).toEqual({ type: "auth_fail", reason: "bad_request" })
  // 本机 /agora?v=2 也走挑战，重复 query 一样拒
  const { url: agUrl } = v2URL(A, devA, "/agora", "relay")
  const localAgora = await openClient(`${agUrl.replace(`ws://127.0.0.1:${A.proxyPort}`, `ws://127.0.0.1:${A.port}`)}&cn=${"A".repeat(43)}`)
  expect(await localAgora.next(isAuthResult)).toEqual({ type: "auth_fail", reason: "bad_request" })
})

test("T9 aud 不在地址集合也能连，只记 aud_known=no；LAN listener 的 aud 记 yes", async () => {
  const r = await v2Round(A, devA, { kind: "key" }, { aud: "proxy.example.test:443" })
  expect(r.result.type).toBe("auth_ok")
  r.c.ws.close()
  await Bun.sleep(100)
  expect(A.out.join("")).toMatch(new RegExp(`auth ok did=${devA.did.slice(0, 8)} kind=key path=/cc from=relay enrolled=1 aud_known=no`))
  if (!A.lan) return console.warn("本机无非回环地址，跳过 LAN aud_known=yes")
  const l = await v2Round(A, devA, { kind: "key" }, { via: "lan" })
  expect(l.result.type).toBe("auth_ok")
  l.c.ws.close()
  await Bun.sleep(100)
  expect(A.out.join("")).toContain(`kind=key path=/cc from=lan enrolled=1 aud_known=yes`)
})

// ── /agora（LAN listener；中继入口本来就拒）──

test("/agora v=2：auth_ok 即 ready、不等 hello，agora 请求照常；没口令也没 v=2 照旧 401", async () => {
  if (!A.lan) return console.warn("本机无非回环地址，跳过 /agora 正向")
  const { c, result } = await v2Round(A, devA, { kind: "key" }, { path: "/agora", via: "lan" })
  expect(result).toEqual({ type: "auth_ok", via: "key", device_id: devA.did, enrolled: true })
  const rid = randomUUID()
  c.send(JSON.stringify({ type: "agora_request", request_id: rid, action: "room.list", payload: { floor_id: randomUUID() } }))
  const resp = await c.next((f) => f.type === "agora_response" && f.request_id === rid)
  expect(resp.ok).toBe(true)
  expect(c.frames.some((f) => f.type === "hello")).toBe(false)
  c.ws.close()
  await expect(openClient(`ws://${LAN}:${A.port}/agora?bundle=${BUNDLE}`)).rejects.toBeDefined()
})

// ── 管理接口 + 吊销（K1-D / K1-C.7 / T7）──

test("管理接口：远程 403、口令错 401；列表 / 改名校验 / 出邀请码（不含口令、mpcc:2）", async () => {
  expect((await fetch(`http://127.0.0.1:${A.port}/admin/devices?token=${encodeURIComponent(TEST_TOKEN)}`, { headers: { "x-forwarded-for": "1.2.3.4" } })).status).toBe(403)
  expect((await fetch(`http://127.0.0.1:${A.port}/admin/devices?token=x`)).status).toBe(401)
  expect((await viaSocket(A.sock, `GET /admin/devices?token=${encodeURIComponent(TEST_TOKEN)} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n`)).split("\r\n")[0]).toBe("HTTP/1.1 404 Not Found")
  const list = await (await admin(A, "/admin/devices")).json() as { available: boolean; devices: { id: string; name: string }[]; legacy_last: unknown }
  expect(list.available).toBe(true)
  expect(list.devices.some((d) => d.id === devA.did && d.name === "测试设备")).toBe(true)
  expect(JSON.stringify(list)).not.toContain("pub")
  expect((await admin(A, "/admin/devices/rename", { device_id: devA.did, name: "  " })).status).toBe(400)
  expect((await admin(A, "/admin/devices/rename", { device_id: "nobodynobodynobodynobo", name: "x" })).status).toBe(404)
  expect(await (await admin(A, "/admin/devices/rename", { device_id: devA.did, name: " 小手机 " })).json()).toEqual({ ok: true })
  const inv = await (await admin(A, "/admin/pair-code", {})).json() as { ok: boolean; pc: string; mc: string; exp: number; qr: string }
  SECRET_VALUES.add(inv.pc); SECRET_VALUES.add(inv.mc)
  const qr = JSON.parse(inv.qr) as Record<string, unknown>
  expect(qr).toMatchObject({ mpcc: 2, v: 2, pc: inv.pc, mc: inv.mc })
  expect("t" in qr).toBe(false)
  expect(inv.qr).not.toContain(TEST_TOKEN)
})

test("T7 吊销：/cc + /agora 在线连接都收 auth_fail revoked + 1008；之后 key / token 都 revoked；手动填口令（reauth）才回来", async () => {
  const dev = makeTestDevice()
  ;(await v2Round(A, dev, tokenCred())).c.ws.close()
  const cc = await v2Round(A, dev, { kind: "key" })
  await cc.c.next(isType("hello"))
  const ag = A.lan ? await v2Round(A, dev, { kind: "key" }, { path: "/agora", via: "lan" }) : null
  const rv = await (await admin(A, "/admin/devices/revoke", { device_id: dev.did })).json() as { ok: boolean; kicked: number }
  expect(rv).toEqual({ ok: true, kicked: A.lan ? 2 : 1 })
  for (const c of [cc.c, ag?.c].filter((x): x is Client => !!x)) {
    expect(await c.next((f) => f.type === "auth_fail")).toEqual({ type: "auth_fail", reason: "revoked" })
    expect(await c.closed).toEqual({ code: 1008, reason: "auth" })
  }
  expect(devicesFile(A).devices.find((d) => d.id === dev.did)?.revoked_at).toBeNumber()
  expect((await v2Round(A, dev, { kind: "key" })).result).toEqual({ type: "auth_fail", reason: "revoked" })
  expect((await v2Round(A, dev, tokenCred())).result).toEqual({ type: "auth_fail", reason: "revoked" })
  const back = await v2Round(A, dev, tokenCred(true))
  expect(back.result).toMatchObject({ type: "auth_ok", via: "token", enrolled: true })
  back.c.ws.close()
  expect(devicesFile(A).devices.find((d) => d.id === dev.did)).toMatchObject({ revoked_at: null })
  expect((await admin(A, "/admin/devices/revoke", { device_id: "nobodynobodynobodynobo" })).status).toBe(404)
})

// ── 两台 hub / 限速（T5）──

test("T5 同一 did 登记到两台 hub：A 的挑战签的 auth 登不进 B；A 吊销不影响 B", async () => {
  const dev = makeTestDevice()
  ;(await v2Round(A, dev, tokenCred())).c.ws.close()
  ;(await v2Round(B, dev, tokenCred())).c.ws.close()
  const a = await openClient(v2URL(A, dev, "/cc", "relay").url)
  const aCh = await a.next(isType("auth_challenge")) as unknown as Challenge
  const { url, conn } = v2URL(B, dev, "/cc", "relay")
  const b = await openClient(url)
  const bCh = await b.next(isType("auth_challenge")) as unknown as Challenge
  expect(bCh.hub_id).not.toBe(aCh.hub_id)
  b.send(authFrame(dev, { ...aCh, sn: bCh.sn }, conn, { kind: "key" }))
  expect(await b.next(isAuthResult)).toEqual({ type: "auth_fail", reason: "bad_sig" })
  a.ws.close()
  await admin(A, "/admin/devices/revoke", { device_id: dev.did })
  expect((await v2Round(A, dev, { kind: "key" })).result.reason).toBe("revoked")
  const okB = await v2Round(B, dev, { kind: "key" })
  expect(okB.result.type).toBe("auth_ok")
  okB.c.ws.close()
})

test("没有全局限速：A 设备连着乱试口令 / 配对码，B 设备同时用对的口令立即登录；错证明的连接要拖 ~1.5 秒才回 bad_proof（K1 返修 r1）", async () => {
  const attacker = makeTestDevice(), dev = makeTestDevice()
  const t0 = Date.now()
  const flood = Promise.all(Array.from({ length: 8 }, (_, i) => v2Round(B, attacker, i % 2 ? { kind: "code", secret: `wrong-${i}` } : { kind: "token", secret: `wrong-口令-${i}` })))
  await Bun.sleep(100)
  const t1 = Date.now()
  const ok = await v2Round(B, dev, tokenCred())
  expect(ok.result).toMatchObject({ type: "auth_ok", via: "token" })
  expect(Date.now() - t1).toBeLessThan(1000)
  ok.c.ws.close()
  for (const r of await flood) expect(r.result).toEqual({ type: "auth_fail", reason: "bad_proof" })
  expect(Date.now() - t0).toBeGreaterThanOrEqual(1400)
  // 乱试完，攻击者那台自己用对的口令也立即过（码不作废、没有累计等待）
  const p = await pair(B)
  const t2 = Date.now()
  const viaCode = await v2Round(B, makeTestDevice(), { kind: "code", secret: p.pc as string })
  expect(viaCode.result.type).toBe("auth_ok")
  expect(Date.now() - t2).toBeLessThan(1000)
  viaCode.c.ws.close()
})

test("K1.25 老 app 帧序：口令原文经中继入口连上，跟本机连接收到的帧序一字不差（第一帧 hello，没有 auth_*）；legacy-seen 记一笔", async () => {
  const local = await openClient(`ws://127.0.0.1:${B.port}/cc`)
  const legacy = await openClient(`ws://127.0.0.1:${B.proxyPort}/cc?token=${encodeURIComponent(TEST_TOKEN)}&bundle=${BUNDLE}`)
  await Bun.sleep(600)
  const norm = (fs: Frame[]) => fs.map((f) => JSON.stringify(f))
  expect(legacy.frames[0].type).toBe("hello")
  expect(legacy.frames.some((f) => String(f.type).startsWith("auth_"))).toBe(false)
  expect(norm(legacy.frames)).toEqual(norm(local.frames))
  local.ws.close(); legacy.ws.close()
  const seen = JSON.parse(readFileSync(join(B.secrets, "legacy-seen.json"), "utf-8")) as { last_at: number; last_from: string }
  expect(seen.last_from).toBe("relay")
  expect(Date.now() - seen.last_at).toBeLessThan(60_000)
})

// ── 状态文件（T10 / §0.8）──

test("T10 吊销与 touch / 登记交错后重启 hub，吊销还在", async () => {
  const C = await startRig()
  const dev = makeTestDevice(), other = makeTestDevice()
  ;(await v2Round(C, dev, tokenCred())).c.ws.close()
  ;(await v2Round(C, dev, { kind: "key" })).c.ws.close()
  await admin(C, "/admin/devices/revoke", { device_id: dev.did })
  ;(await v2Round(C, other, tokenCred())).c.ws.close()
  ;(await v2Round(C, other, { kind: "key" })).c.ws.close()
  const hk = (await pair(C)).hk
  await stopRig(C)
  const C2 = await startRig({ secrets: C.secrets })
  expect((await pair(C2)).hk).toBe(hk)
  expect((await v2Round(C2, dev, { kind: "key" })).result).toEqual({ type: "auth_fail", reason: "revoked" })
  const o = await v2Round(C2, other, { kind: "key" })
  expect(o.result.type).toBe("auth_ok")
  o.c.ws.close()
  await stopRig(C2)
})

test("hub-key.pem 坏了 / 是软链写不进：hub 照起、capabilities 不报 device_auth、/pair 只给 v1、v=2 回 unavailable、口令照常", async () => {
  const bad = await startRig({ prepare: (d) => writeFileSync(join(d, "hub-key.pem"), "garbage") })
  const link = await startRig({ prepare: (d) => symlinkSync(join(d, "nowhere", "x.pem"), join(d, "hub-key.pem")) })
  for (const r of [bad, link]) {
    const hello = await (await openClient(`ws://127.0.0.1:${r.port}/cc`)).next(isType("hello"))
    expect(hello.capabilities).not.toContain("device_auth")
    const p = await pair(r)
    expect("hk" in p || "pc" in p || "v" in p).toBe(false)
    expect(p).toMatchObject({ mpcc: 1, t: TEST_TOKEN })
    const c = await openClient(v2URL(r, devA, "/cc", "relay").url)
    expect(await c.next(isAuthResult)).toEqual({ type: "auth_fail", reason: "unavailable" })
    expect((await c.closed).code).toBe(1008)
    const legacy = await openClient(`ws://127.0.0.1:${r.proxyPort}/cc?token=${encodeURIComponent(TEST_TOKEN)}&bundle=${BUNDLE}`)
    expect((await legacy.next(isType("hello"))).type).toBe("hello")
    legacy.ws.close()
  }
  expect(readFileSync(join(bad.secrets, "hub-key.pem"), "utf-8")).toBe("garbage")
  expect(bad.out.join("")).toContain("hub-key.pem 坏了")
  expect(link.out.join("")).toContain("hub-key.pem 写不进去")
  await Promise.all([stopRig(bad), stopRig(link)])
})

test("devices.json 坏了：key / code 回 unavailable、口令照常放行（enrolled:false），原文件不动", async () => {
  const D = await startRig({ prepare: (d) => writeFileSync(join(d, "devices.json"), "{broken") })
  const dev = makeTestDevice()
  expect((await v2Round(D, dev, { kind: "key" })).result).toEqual({ type: "auth_fail", reason: "unavailable" })
  const p = await pair(D)
  expect((await v2Round(D, dev, { kind: "code", secret: p.pc as string })).result).toEqual({ type: "auth_fail", reason: "unavailable" })
  const t = await v2Round(D, dev, tokenCred())
  expect(t.result).toMatchObject({ type: "auth_ok", via: "token", enrolled: false })
  await t.c.next(isType("hello"))
  t.c.ws.close()
  expect(readFileSync(join(D.secrets, "devices.json"), "utf-8")).toBe("{broken")
  await stopRig(D)
})

// ── devices.ts CLI（K1-D：只调本机管理接口）──

function cli(r: Rig | { port: number }, ...args: string[]): { out: string; code: number } {
  // 「没装 qrencode」用例：PATH 只留 bun 所在目录
  const noQr = args[0] === "--no-qrencode"
  if (noQr) args = args.slice(1)
  const p = Bun.spawnSync([process.execPath, "run", "devices.ts", ...args, "--port", String(r.port)], {
    cwd: import.meta.dir, stdout: "pipe", stderr: "pipe",
    env: { PATH: noQr ? dirname(process.execPath) : process.env.PATH ?? "", HOME: mkdtempSync(join(tmpdir(), "kp-home-")), MP_CC_HUB_TOKEN: TEST_TOKEN, NO_PROXY: "127.0.0.1", no_proxy: "127.0.0.1" },
  })
  return { out: p.stdout.toString() + p.stderr.toString(), code: p.exitCode ?? -1 }
}

test("devices.ts：list / rename / revoke（id 前缀）/ pair；hub 没在跑就说清楚", async () => {
  const dev = makeTestDevice()
  ;(await v2Round(B, dev, tokenCred())).c.ws.close()
  expect(cli(B, "list").out).toContain(dev.did)
  const rn = cli(B, "rename", dev.did.slice(0, 8), "CLI", "改的名")
  expect(rn).toMatchObject({ code: 0 })
  expect(cli(B, "list").out).toContain(`${dev.did}  CLI 改的名`)
  expect(cli(B, "rename", dev.did.slice(0, 8), " ").code).toBe(1)
  expect(cli(B, "revoke", "zzzzzzzz").code).toBe(1)
  const rv = cli(B, "revoke", dev.did.slice(0, 8))
  expect(rv.code).toBe(0)
  expect(devicesFile(B).devices.find((d) => d.id === dev.did)?.revoked_at).toBeNumber()
  expect(cli(B, "list").out).not.toContain(dev.did)
  const p = cli(B, "pair")
  expect(p.code).toBe(0)
  expect(p.out).toMatch(/手填配对码：[0-9A-Z]{5}-[0-9A-Z]{5}/)
  for (const m of p.out.match(/[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}/g) ?? []) SECRET_VALUES.add(m)
  // 没装 qrencode：不崩，手填配对码 / 地址 / 口令照样打（K1 返修 r1）
  const noQr = cli(B, "--no-qrencode", "pair")
  expect(noQr.code).toBe(0)
  expect(noQr.out).toContain("画不了二维码")
  expect(noQr.out).toMatch(/手填配对码：[0-9A-Z]{5}-[0-9A-Z]{5}/)
  expect(noQr.out).toContain(`口令：${TEST_TOKEN}`)
  for (const m of noQr.out.match(/[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}/g) ?? []) SECRET_VALUES.add(m)
  const dead = cli({ port: 1 }, "list")
  expect(dead.code).toBe(1)
  expect(dead.out).toContain("hub 没在跑")
})

// ── T15：测试秘密值不进日志（放最后）──

test("T15 远端塞进 close reason / Origin / bundle / 路径里的秘密不进日志（K1 返修 r1）", async () => {
  // v2 会话正常登进来，再把刚收到的 hub_proof 当 close reason 关掉
  const r = await v2Round(A, makeTestDevice(), tokenCred())
  await r.c.next(isType("hello"))
  const proof = r.result.hub_proof as string
  SECRET_VALUES.add(proof)
  r.c.ws.close(4000, proof)
  // 口令原文会话也一样
  const legacy = await openClient(`ws://127.0.0.1:${A.proxyPort}/cc?token=${encodeURIComponent(TEST_TOKEN)}&bundle=${BUNDLE}`)
  await legacy.next(isType("hello"))
  legacy.ws.close(4000, TEST_TOKEN)
  const sneaky = `sneaky-${randomUUID()}`
  SECRET_VALUES.add(sneaky)
  await viaSocket(A.sock, [`GET /cc?token=x&bundle=${BUNDLE} HTTP/1.1`, "Host: relay.example.test", "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Version: 13", `Origin: https://${sneaky}.example`].join("\r\n") + "\r\n\r\n", 500)
  const badBundle = await openClient(`ws://127.0.0.1:${A.proxyPort}/cc?token=${encodeURIComponent(TEST_TOKEN)}&bundle=${sneaky}`)
  expect((await badBundle.closed).reason).toBe("bundle")
  if (A.lan) {
    // 未知路径（远端可控）只记成 path=other
    const badPath = await openClient(`ws://${LAN}:${A.port}/x-${sneaky}?bundle=${BUNDLE}`)
    expect((await badPath.closed).code).toBe(1008)
  }
  await Bun.sleep(300)
  const logs = A.out.join("")
  expect(logs).toContain("MP disconnected")
  expect(logs.includes(proof) || logs.includes(sneaky) || logs.includes(TEST_TOKEN)).toBe(false)
})

test("T15 跑完全部用例：hub 日志 / 异常输出里搜不到口令、配对码、proof、签名、nonce", async () => {
  await Bun.sleep(200)
  const logs = rigs.map((r) => r.out.join("")).join("\n")
  expect(logs.length).toBeGreaterThan(0)
  expect(SECRET_VALUES.size).toBeGreaterThan(20)
  const leaked = [...SECRET_VALUES].filter((v) => v.length >= 8 && logs.includes(v))
  expect(leaked).toEqual([])
  // mc 手填形（去横线）也查
  const mcs = [...SECRET_VALUES].filter((v) => /^[0-9A-Z]{5}-[0-9A-Z]{5}$/.test(v)).map((v) => v.replace("-", ""))
  expect(mcs.filter((v) => logs.includes(v))).toEqual([])
})
