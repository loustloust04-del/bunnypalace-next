import { test, expect, afterEach } from "bun:test"
import { createHash, randomBytes } from "node:crypto"
import { mkdtempSync, readFileSync } from "node:fs"
import { connect, createServer, type Server, type Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { startRelay, type RelayHandle } from "./relay/relay.ts"
import { spkiSha256, startConnector, type ConnectorHandle } from "./relay-connector.ts"
import type { RelayConfig } from "./relay-config.ts"

const SECRET = randomBytes(32)
const SECRET_HEX = SECRET.toString("hex")
const SECRET_SHA = createHash("sha256").update(SECRET).digest()
const HUB_403 = "HTTP/1.1 403 Forbidden\r\nx-mp-hub: 1\r\nConnection: close\r\nContent-Length: 9\r\n\r\nforbidden"
const HEALTH = "GET /health HTTP/1.1\r\nHost: relay.example\r\n\r\n"

let relay: RelayHandle | undefined
let conn: ConnectorHandle | undefined
const servers: Server[] = []
const sockets: Socket[] = []
let connLogs: string[] = []

afterEach(async () => {
  conn?.stop(); conn = undefined
  for (const s of sockets.splice(0)) s.destroy()
  for (const s of servers.splice(0)) s.close()
  await relay?.close(); relay = undefined
})

function sockPath(): string {
  return join(mkdtempSync(join(tmpdir(), "rc-")), "h.sock")
}

/// 假 hub 的中继入口：记下收到的字节，按 reply 回
function fakeHub(path: string, reply: (got: string, s: Socket) => void): Promise<{ got: () => string }> {
  let all = ""
  const srv = createServer((s) => {
    sockets.push(s)
    let got = ""
    s.on("data", (d) => { got += d.toString("latin1"); all += d.toString("latin1"); reply(got, s) })
    s.on("error", () => {})
  })
  servers.push(srv)
  return new Promise((r) => srv.listen(path, () => r({ got: () => all })))
}

function startConn(cfg: Partial<RelayConfig> & { port: number }, path: string, extra: Partial<Parameters<typeof startConnector>[0]> = {}) {
  connLogs = []
  conn = startConnector({
    config: { host: "127.0.0.1", secret: SECRET_HEX, tls: false, ...cfg },
    sockPath: path, backoffMinMs: 50, backoffMaxMs: 200, log: (l) => connLogs.push(l), ...extra,
  })
  return conn
}

async function waitFor(pred: () => boolean, ms = 3000): Promise<boolean> {
  const end = Date.now() + ms
  while (Date.now() < end) { if (pred()) return true; await Bun.sleep(20) }
  return pred()
}

function phone(port: number, text: string, ms = 3000): Promise<string> {
  return new Promise((resolve) => {
    const s = connect(port, "127.0.0.1")
    sockets.push(s)
    let buf = ""
    const t = setTimeout(() => resolve(buf), ms)
    s.on("data", (d) => { buf += d.toString("latin1") })
    s.on("close", () => { clearTimeout(t); resolve(buf) })
    s.on("error", () => {})
    s.write(text)
  })
}

function selfSigned(): { cert: Buffer; key: Buffer } {
  const dir = mkdtempSync(join(tmpdir(), "rc-tls-"))
  const gen = Bun.spawnSync(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1",
    "-subj", "/CN=relay.test", "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", join(dir, "key.pem"), "-out", join(dir, "cert.pem")])
  if (gen.exitCode !== 0) throw new Error("openssl failed")
  return { cert: readFileSync(join(dir, "cert.pem")), key: readFileSync(join(dir, "key.pem")) }
}

function certDer(pem: Buffer): Buffer {
  return Buffer.from(pem.toString().replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""), "base64")
}

test("connector 连上中继保持 3 条 spare；/health 经 Unix socket 到 hub、回应原样回手机，用掉的立刻补上", async () => {
  relay = await startRelay({ host: "127.0.0.1", port: 0, secretSha256: SECRET_SHA, log: () => {} })
  const path = sockPath()
  const hub = await fakeHub(path, (got, s) => { if (got.includes("\r\n\r\n")) s.end(HUB_403) })
  startConn({ port: relay.port }, path)
  expect(await waitFor(() => relay!.stats().idle === 3)).toBe(true)
  expect(await phone(relay.port, HEALTH)).toBe(HUB_403)
  expect(hub.got()).toContain("GET /health HTTP/1.1\r\n")
  expect(hub.got()).toContain("X-Forwarded-For: 127.0.0.1\r\n")
  expect(hub.got()).not.toContain("OPEN")
  expect(await waitFor(() => relay!.stats().idle === 3 && conn!.stats().pipes === 0)).toBe(true)
})

test("中继的 PING 自动回 PONG，spare 不掉", async () => {
  relay = await startRelay({ host: "127.0.0.1", port: 0, secretSha256: SECRET_SHA, log: () => {}, timings: { pingIntervalMs: 40, pongMs: 120 } })
  startConn({ port: relay.port }, sockPath(), { spares: 2 })
  expect(await waitFor(() => relay!.stats().idle === 2)).toBe(true)
  await Bun.sleep(500)
  expect(relay.stats().spares).toBe(2)
  expect(connLogs.filter((l) => l.includes("spare_lost"))).toEqual([])
})

test("密钥错：中继不收，connector 退避重试，不刷屏", async () => {
  relay = await startRelay({ host: "127.0.0.1", port: 0, secretSha256: SECRET_SHA, log: () => {} })
  startConn({ port: relay.port, secret: "00".repeat(32) }, sockPath(), { spares: 1 })
  await Bun.sleep(600)
  expect(relay.stats().spares).toBe(0)
  const rejects = connLogs.filter((l) => l.includes("auth_rejected")).length
  expect(rejects).toBeGreaterThan(0)
  expect(rejects).toBeLessThan(12)   // 50ms 起步指数退避，600ms 内不该超过这个数
})

test("hub 入口不在：手机拿到 502，connector 照样补 spare", async () => {
  relay = await startRelay({ host: "127.0.0.1", port: 0, secretSha256: SECRET_SHA, log: () => {} })
  startConn({ port: relay.port }, sockPath(), { spares: 1 })
  expect(await waitFor(() => relay!.stats().idle === 1)).toBe(true)
  expect((await phone(relay.port, HEALTH)).split("\r\n")[0]).toBe("HTTP/1.1 502 Bad Gateway")
  expect(await waitFor(() => relay!.stats().idle === 1)).toBe(true)
})

test("自签 TLS：pin 对 → 进池；pin 错 → 握手后直接断、密钥一个字节都不发；没 pin → 系统校验不过", async () => {
  const { cert, key } = selfSigned()
  const relayLogs: string[] = []
  relay = await startRelay({ host: "127.0.0.1", port: 0, secretSha256: SECRET_SHA, tls: { cert, key }, log: (l) => relayLogs.push(l) })
  const pin = spkiSha256(certDer(cert))

  startConn({ port: relay.port, tls: true, pinSpkiSha256: pin }, sockPath(), { spares: 1 })
  expect(await waitFor(() => relay!.stats().idle === 1)).toBe(true)
  conn!.stop()
  await waitFor(() => relay!.stats().spares === 0)

  startConn({ port: relay.port, tls: true, pinSpkiSha256: createHash("sha256").update("other").digest("base64") }, sockPath(), { spares: 1 })
  await Bun.sleep(400)
  expect(connLogs.some((l) => l.includes("pin_mismatch"))).toBe(true)
  expect(relay.stats().spares).toBe(0)
  expect(relayLogs.some((l) => l.includes("connector_auth_fail"))).toBe(false)   // 没把密钥发给对不上 pin 的服务器
  conn!.stop()

  startConn({ port: relay.port, tls: true }, sockPath(), { spares: 1 })
  await Bun.sleep(400)
  expect(relay.stats().spares).toBe(0)
  expect(connLogs.some((l) => l.includes("spare_ready"))).toBe(false)
})

test("协议细节：控制行分片到达、OPEN 和首段数据粘包、OPEN 之后的 OPEN/PING 都当业务字节", async () => {
  const path = sockPath()
  const hub = await fakeHub(path, () => {})
  let relaySide: Socket | undefined
  let fromConnector = ""
  const fake = createServer((s) => {
    sockets.push(s)
    if (relaySide) return   // OPEN 后 connector 会补连一条新 spare，只看第一条
    relaySide = s
    s.on("data", (d) => { fromConnector += d.toString("latin1") })
    s.on("error", () => {})
  })
  servers.push(fake)
  await new Promise<void>((r) => fake.listen(0, "127.0.0.1", () => r()))
  const port = (fake.address() as { port: number }).port
  startConn({ port }, path, { spares: 1 })
  expect(await waitFor(() => fromConnector.startsWith(`MPRELAY/1 AUTH ${SECRET_HEX}\n`))).toBe(true)
  for (const part of ["O", "K\nPI", "NG", "\n"]) { relaySide!.write(part); await Bun.sleep(15) }
  expect(await waitFor(() => fromConnector.endsWith("PONG\n"))).toBe(true)
  relaySide!.write("OPEN\nHEAD-AND-")
  await Bun.sleep(30)
  relaySide!.write("MORE\nOPEN\nPING\n")
  expect(await waitFor(() => hub.got() === "HEAD-AND-MORE\nOPEN\nPING\n")).toBe(true)
  await Bun.sleep(50)
  expect(fromConnector.split("PONG").length - 1).toBe(1)   // OPEN 之后不再回 PONG
})

test("鉴权成功后马上被断：照样指数退避，不会 0–1s 一直重连", async () => {
  let accepts = 0
  const fake = createServer((s) => {
    sockets.push(s); accepts++
    s.on("error", () => {})
    s.once("data", () => { s.write("OK\n"); setTimeout(() => s.destroy(), 5) })
  })
  servers.push(fake)
  await new Promise<void>((r) => fake.listen(0, "127.0.0.1", () => r()))
  startConn({ port: (fake.address() as { port: number }).port }, sockPath(), { spares: 1, backoffMinMs: 50, backoffMaxMs: 5000 })
  await Bun.sleep(900)
  // 50→100→200→400ms（各打 5–10 折抖动），900ms 内最多 6 次左右；没退避的话 0–50ms 一次会有十几次
  expect(accepts).toBeGreaterThan(1)
  expect(accepts).toBeLessThan(8)
})

test("空闲通道收到不认识的控制行：断开重连", async () => {
  let relaySide: Socket | undefined
  let accepts = 0
  const fake = createServer((s) => { sockets.push(s); relaySide = s; accepts++; s.on("error", () => {}) })
  servers.push(fake)
  await new Promise<void>((r) => fake.listen(0, "127.0.0.1", () => r()))
  startConn({ port: (fake.address() as { port: number }).port }, sockPath(), { spares: 1 })
  await waitFor(() => accepts === 1)
  relaySide!.write("OK\nWHAT\n")
  expect(await waitFor(() => accepts === 2)).toBe(true)
})
