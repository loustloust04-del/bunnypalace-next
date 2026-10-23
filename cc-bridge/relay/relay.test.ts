import { test, expect, afterEach } from "bun:test"
import { createHash, randomBytes } from "node:crypto"
import { existsSync, mkdtempSync, readFileSync, statSync, symlinkSync } from "node:fs"
import { connect, type Socket } from "node:net"
import { connect as tlsConnect } from "node:tls"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { parsePhoneHead, startRelay, type RelayHandle, type RelayOptions } from "./relay.ts"

const SECRET = randomBytes(32)
const SECRET_HEX = SECRET.toString("hex")
const SECRET_SHA = createHash("sha256").update(SECRET).digest()
const FAKE_TOKEN = "FAKE-TOKEN-7f3e9a"

let relay: RelayHandle | undefined
let logs: string[] = []
const extraSockets: Socket[] = []

afterEach(async () => {
  for (const s of extraSockets.splice(0)) s.destroy()
  await relay?.close()
  relay = undefined
})

async function start(o: Partial<RelayOptions> = {}): Promise<RelayHandle> {
  logs = []
  relay = await startRelay({ host: "127.0.0.1", port: 0, secretSha256: SECRET_SHA, log: (l) => logs.push(l), ...o })
  return relay
}

/// 收到的全部字节 + 等某段内容出现
function collector(sock: Socket) {
  let buf = Buffer.alloc(0)
  let closed = false
  const waits: (() => void)[] = []
  sock.on("data", (d) => { buf = Buffer.concat([buf, d]); waits.splice(0).forEach((w) => w()) })
  sock.on("close", () => { closed = true; waits.splice(0).forEach((w) => w()) })
  sock.on("error", () => {})
  return {
    get text() { return buf.toString("latin1") },
    get closed() { return closed },
    until(pred: () => boolean, ms = 2000): Promise<boolean> {
      return new Promise((resolve) => {
        const check = () => { if (pred()) { clearTimeout(t); resolve(true) } else waits.push(check) }
        const t = setTimeout(() => resolve(false), ms)
        check()
      })
    },
  }
}

async function connector(port: number, secretHex = SECRET_HEX) {
  const sock = connect(port, "127.0.0.1")
  extraSockets.push(sock)
  const c = collector(sock)
  sock.write(`MPRELAY/1 AUTH ${secretHex}\n`)
  const ok = await c.until(() => c.text.startsWith("OK\n") || c.closed)
  return { sock, c, ok: ok && c.text.startsWith("OK\n") }
}

async function phone(port: number, text: string | string[], ms = 2000) {
  const sock = connect(port, "127.0.0.1")
  extraSockets.push(sock)
  const c = collector(sock)
  for (const part of Array.isArray(text) ? text : [text]) { sock.write(part); await Bun.sleep(5) }
  await c.until(() => c.closed, ms)
  return c
}

const HEALTH = "GET /health HTTP/1.1\r\nHost: relay.example\r\nConnection: keep-alive\r\n\r\n"
const CC = `GET /cc?token=${FAKE_TOKEN}&bundle=com.x HTTP/1.1\r\nHost: relay.example\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`
const HUB_403 = "HTTP/1.1 403 Forbidden\r\nx-mp-hub: 1\r\nConnection: close\r\nContent-Length: 9\r\n\r\nforbidden"

test("Mac 不在线：/health 503，不带 x-mp-hub", async () => {
  const r = await start()
  const res = await phone(r.port, HEALTH)
  expect(res.text.split("\r\n")[0]).toBe("HTTP/1.1 503 Service Unavailable")
  expect(res.text.toLowerCase()).not.toContain("x-mp-hub")
})

test("connector 密钥错：断开，不进池；对：OK 进池", async () => {
  const r = await start()
  const bad = await connector(r.port, "00".repeat(32))
  expect(bad.ok).toBe(false)
  expect(r.stats().spares).toBe(0)
  const good = await connector(r.port)
  expect(good.ok).toBe(true)
  expect(r.stats()).toEqual({ spares: 1, idle: 1, pipes: 0 })
})

test("connector AUTH 行分片到达也认；AUTH 后多带字节 / 超长行断开", async () => {
  const r = await start()
  const sock = connect(r.port, "127.0.0.1"); extraSockets.push(sock)
  const c = collector(sock)
  const line = `MPRELAY/1 AUTH ${SECRET_HEX}\n`
  for (const ch of [line.slice(0, 3), line.slice(3, 20), line.slice(20)]) { sock.write(ch); await Bun.sleep(10) }
  expect(await c.until(() => c.text === "OK\n")).toBe(true)

  const extra = connect(r.port, "127.0.0.1"); extraSockets.push(extra)
  const ce = collector(extra)
  extra.write(`MPRELAY/1 AUTH ${SECRET_HEX}\nGARBAGE`)
  expect(await ce.until(() => ce.closed)).toBe(true)
  expect(ce.text).toBe("")

  const long = connect(r.port, "127.0.0.1"); extraSockets.push(long)
  const cl = collector(long)
  long.write("MPRELAY/1 AUTH " + "a".repeat(300))
  expect(await cl.until(() => cl.closed)).toBe(true)
  expect(r.stats().spares).toBe(1)
})

test("/health 配对：connector 收到 OPEN + 改写后的头（Connection: close、插 XFF），hub 的回应原样回手机", async () => {
  const r = await start()
  const mac = await connector(r.port)
  const p = phone(r.port, HEALTH)
  expect(await mac.c.until(() => mac.c.text.includes("\r\n\r\n"))).toBe(true)
  const got = mac.c.text.slice("OK\n".length)
  expect(got.startsWith("OPEN\nGET /health HTTP/1.1\r\n")).toBe(true)
  expect(got).toContain("Connection: close\r\n")
  expect(got).not.toContain("keep-alive")
  expect(got).toContain("X-Forwarded-For: 127.0.0.1\r\n")
  mac.sock.end(HUB_403)
  const res = await p
  expect(res.text).toBe(HUB_403)
  expect(r.stats().spares).toBe(0)
})

test("/health 后手机多发的请求（keep-alive / 管线）不转给 Mac", async () => {
  const r = await start()
  const mac = await connector(r.port)
  const p = phone(r.port, [HEALTH + HEALTH, "GET /cc HTTP/1.1\r\n\r\n"])
  await mac.c.until(() => mac.c.text.includes("\r\n\r\n"))
  await Bun.sleep(100)
  expect(mac.c.text.split("GET ").length - 1).toBe(1)
  mac.sock.end(HUB_403)
  await p
})

test("请求头校验：带 body / 非 GET / 别的路径 / 裸 LF / 折行 / 非法头名 / 太大", async () => {
  const r = await start()
  await connector(r.port)
  const cases: [string, string][] = [
    ["GET /health HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n", "400"],
    ["GET /cc HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n", "400"],
    ["POST /health HTTP/1.1\r\nHost: x\r\n\r\n", "405"],
    ["GET /mcp HTTP/1.1\r\nHost: x\r\n\r\n", "404"],
    ["GET /pocket/cmd HTTP/1.1\r\nHost: x\r\n\r\n", "404"],
    ["GET http://evil/cc HTTP/1.1\r\nHost: x\r\n\r\n", "400"],
    ["GET /health HTTP/1.0\r\nHost: x\r\n\r\n", "400"],
    ["GET /health HTTP/1.1\r\nHost: x\nX-A: 1\r\n\r\n", "400"],
    ["GET /health HTTP/1.1\r\nHost: x\r\n folded\r\n\r\n", "400"],
    ["GET /health HTTP/1.1\r\nBad Name: x\r\n\r\n", "400"],
    ["GET /cc HTTP/1.1\r\nHost: x\r\n\r\n", "400"],
    [`GET /health HTTP/1.1\r\nX-Big: ${"a".repeat(9000)}\r\n\r\n`, "431"],
  ]
  for (const [req, code] of cases) {
    const res = await phone(r.port, req)
    const label = JSON.stringify(req.slice(0, 40))
    expect(`${label} → ${res.text.split(" ")[1]}`).toBe(`${label} → ${code}`)
    expect(res.text.toLowerCase()).not.toContain("x-mp-hub")
  }
  expect(r.stats().spares).toBe(1)   // 被拒的请求不占 spare
})

test("请求头迟迟不完：408", async () => {
  const r = await start({ timings: { headMs: 200 } })
  const res = await phone(r.port, "GET /health HTTP/1.1\r\n")
  expect(res.text.split("\r\n")[0]).toBe("HTTP/1.1 408 Request Timeout")
})

test("/cc：头里的早到字节随 OPEN 一起送过去，之后双向原样搬", async () => {
  const r = await start()
  const mac = await connector(r.port)
  const sock = connect(r.port, "127.0.0.1"); extraSockets.push(sock)
  const pc = collector(sock)
  sock.write(CC + "EARLY")
  await mac.c.until(() => mac.c.text.includes("EARLY"))
  const got = mac.c.text.slice("OK\n".length)
  expect(got.startsWith(`OPEN\nGET /cc?token=${FAKE_TOKEN}&bundle=com.x HTTP/1.1\r\n`)).toBe(true)
  expect(got).toContain("Upgrade: websocket\r\n")
  expect(got.endsWith("\r\n\r\nEARLY")).toBe(true)
  mac.sock.write("HTTP/1.1 101 Switching Protocols\r\n\r\nFROM-HUB")
  expect(await pc.until(() => pc.text.endsWith("FROM-HUB"))).toBe(true)
  sock.write("FROM-PHONE")
  expect(await mac.c.until(() => mac.c.text.endsWith("FROM-PHONE"))).toBe(true)
  expect(r.stats().pipes).toBe(1)
  sock.destroy()
  await mac.c.until(() => mac.c.closed)
  await Bun.sleep(20)
  expect(r.stats().pipes).toBe(0)
})

test("OPEN 后 Mac 一直不回：504（不带 x-mp-hub）", async () => {
  const r = await start({ timings: { firstByteMs: 200 } })
  await connector(r.port)
  const res = await phone(r.port, HEALTH)
  expect(res.text.split("\r\n")[0]).toBe("HTTP/1.1 504 Gateway Timeout")
  expect(res.text.toLowerCase()).not.toContain("x-mp-hub")
})

test("OPEN 后 Mac 一个字节没回就断：502", async () => {
  const r = await start()
  const mac = await connector(r.port)
  const p = phone(r.port, HEALTH)
  await mac.c.until(() => mac.c.text.includes("OPEN\n"))
  mac.sock.destroy()
  const res = await p
  expect(res.text.split("\r\n")[0]).toBe("HTTP/1.1 502 Bad Gateway")
})

test("PING/PONG：回了留在池里；不回到期断开", async () => {
  const r = await start({ timings: { pingIntervalMs: 50, pongMs: 150 } })
  const live = await connector(r.port)
  live.sock.on("data", (d) => { if (d.toString().includes("PING")) live.sock.write("PONG\n") })
  const dead = await connector(r.port)
  expect(r.stats().spares).toBe(2)
  await Bun.sleep(400)
  expect(dead.c.closed).toBe(true)
  expect(live.c.closed).toBe(false)
  expect(r.stats().spares).toBe(1)
})

test("没 PING 过却回 PONG / 乱发字节：断开（不会串进业务流）", async () => {
  const r = await start()
  const a = await connector(r.port)
  a.sock.write("PONG\n")
  expect(await a.c.until(() => a.c.closed)).toBe(true)
  const b = await connector(r.port)
  b.sock.write("HELLO\n")
  expect(await b.c.until(() => b.c.closed)).toBe(true)
  expect(r.stats().spares).toBe(0)
})

test("PINGING 的 spare 不配对；等期内回了 PONG 就配上，否则 503", async () => {
  const r = await start({ timings: { pingIntervalMs: 30, pongMs: 5000, spareWaitMs: 300 } })
  const mac = await connector(r.port)
  await mac.c.until(() => mac.c.text.includes("PING\n"))
  // 正在 PINGING：手机来了先等着
  const p = phone(r.port, HEALTH)
  await Bun.sleep(100)
  expect(mac.c.text.includes("OPEN")).toBe(false)
  mac.sock.write("PONG\n")
  expect(await mac.c.until(() => mac.c.text.includes("OPEN\nGET /health"))).toBe(true)
  // OPEN 之后中继不再发 PING
  const before = mac.c.text.split("PING").length
  await Bun.sleep(150)
  expect(mac.c.text.split("PING").length).toBe(before)
  mac.sock.end(HUB_403)
  expect((await p).text).toBe(HUB_403)

  const silent = await connector(r.port)
  await silent.c.until(() => silent.c.text.includes("PING\n"))
  const res = await phone(r.port, HEALTH)
  expect(res.text.split("\r\n")[0]).toBe("HTTP/1.1 503 Service Unavailable")
})

test("限额：每 IP 同时连接数 / 每分钟次数", async () => {
  const r = await start({ limits: { phonePerIp: 2, phonePerIpPerMinute: 4 }, timings: { firstByteMs: 2000 } })
  await connector(r.port)
  await connector(r.port)

  // 两条挂着的 /cc 占满每 IP 并发
  const hold = [connect(r.port, "127.0.0.1"), connect(r.port, "127.0.0.1")]
  for (const s of hold) { extraSockets.push(s); collector(s); s.write(CC) }
  await Bun.sleep(50)
  const third = await phone(r.port, HEALTH)
  expect(third.text.split("\r\n")[0]).toBe("HTTP/1.1 429 Too Many Requests")
  for (const s of hold) s.destroy()
  await Bun.sleep(50)
  // 并发超限那次不计数：本分钟第 3、4 次放行（没 spare 了 → 503），第 5 次超频
  expect((await phone(r.port, HEALTH)).text.split(" ")[1]).toBe("503")
  expect((await phone(r.port, HEALTH)).text.split(" ")[1]).toBe("503")
  expect((await phone(r.port, HEALTH)).text.split("\r\n")[0]).toBe("HTTP/1.1 429 Too Many Requests")
})

test("鉴权额度只算失败：合法补池连续 25 次不受限；失败 2 次后同 IP 连对的也先拒", async () => {
  const r = await start({ limits: { authFailPerIpPerMinute: 2 } })
  for (let i = 0; i < 25; i++) {
    const c = await connector(r.port)
    expect(c.ok).toBe(true)
    c.sock.destroy()
    await c.c.until(() => c.c.closed)
  }
  expect((await connector(r.port, "00".repeat(32))).ok).toBe(false)
  expect((await connector(r.port, "00".repeat(32))).ok).toBe(false)
  expect((await connector(r.port)).ok).toBe(false)
  expect(logs.some((l) => l.includes("connector_limited"))).toBe(true)
})

test("TCP 接入就记账：每 IP 连接数上限；还没分类的连接也占待读头名额", async () => {
  const r = await start({ limits: { connectionsPerIp: 3 } })
  const socks = [0, 1, 2, 3].map(() => { const s = connect(r.port, "127.0.0.1"); extraSockets.push(s); return collector(s) })
  expect(await socks[3].until(() => socks[3].closed)).toBe(true)
  await Bun.sleep(50)
  expect(socks.slice(0, 3).every((c) => !c.closed)).toBe(true)

  await relay!.close()
  const r2 = await start({ limits: { pendingHeads: 2 } })
  const silent = [0, 1, 2].map(() => { const s = connect(r2.port, "127.0.0.1"); extraSockets.push(s); return collector(s) })
  await Bun.sleep(30)
  // 前两条一个字节没发就占住了名额，第三条被拒
  for (const s of extraSockets.slice(-3)) s.write("G")
  expect(await silent[2].until(() => silent[2].closed)).toBe(true)
})

test("Connection 不是精确的 upgrade token：400（x-upgrade / upgrade-foo）", async () => {
  const r = await start()
  const ok = await connector(r.port)
  for (const conn of ["x-upgrade", "upgrade-foo", "keep-alive"]) {
    const res = await phone(r.port, `GET /cc HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: ${conn}\r\n\r\n`)
    expect(`${conn} → ${res.text.split(" ")[1]}`).toBe(`${conn} → 400`)
  }
  expect(ok.c.text.includes("OPEN")).toBe(false)
  const p = phone(r.port, `GET /cc HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n\r\n`, 300)
  expect(await ok.c.until(() => ok.c.text.includes("OPEN\n"), 1000)).toBe(true)
  await p
})

test("请求头超时之后补齐也不会被转发（拒绝是终态）", async () => {
  const r = await start({ timings: { headMs: 150 } })
  const mac = await connector(r.port)
  const sock = connect(r.port, "127.0.0.1"); extraSockets.push(sock)
  const pc = collector(sock)
  sock.write("GET /health HTTP/1.1\r\n")
  expect(await pc.until(() => pc.text.includes("408"))).toBe(true)
  sock.write("Host: x\r\n\r\n")
  await Bun.sleep(150)
  expect(mac.c.text.includes("OPEN")).toBe(false)
  expect(r.stats().spares).toBe(1)
})

test("管道上限在等待 spare 时也不会被多个等待者一起突破", async () => {
  const r = await start({ limits: { pipes: 1 }, timings: { pingIntervalMs: 30, pongMs: 5000, spareWaitMs: 500, firstByteMs: 2000 } })
  const a = await connector(r.port)
  const b = await connector(r.port)
  await a.c.until(() => a.c.text.includes("PING\n"))
  await b.c.until(() => b.c.text.includes("PING\n"))
  // 两个 spare 都在 PINGING：两个手机都进等待
  const p1 = phone(r.port, HEALTH, 800)
  const p2 = phone(r.port, HEALTH, 800)
  await Bun.sleep(50)
  a.sock.write("PONG\n"); b.sock.write("PONG\n")
  const [r1, r2] = await Promise.all([p1, p2])
  const opened = [a, b].filter((x) => x.c.text.includes("OPEN\n")).length
  expect(opened).toBe(1)
  expect([r1.text, r2.text].some((t) => t.startsWith("HTTP/1.1 503"))).toBe(true)
})

test("没给证书不准绑 127.0.0.1 以外", async () => {
  await expect(startRelay({ host: "0.0.0.0", port: 0, secretSha256: SECRET_SHA })).rejects.toThrow()
})

test("TLS：自签证书起中继，TLS 上走 connector 鉴权 + /health 配对", async () => {
  const dir = mkdtempSync(join(tmpdir(), "relay-tls-"))
  const gen = Bun.spawnSync(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1",
    "-subj", "/CN=relay.test", "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", join(dir, "key.pem"), "-out", join(dir, "cert.pem")])
  expect(gen.exitCode).toBe(0)
  const cert = readFileSync(join(dir, "cert.pem")), key = readFileSync(join(dir, "key.pem"))
  const r = await start({ tls: { cert, key } })
  const mac = tlsConnect({ port: r.port, host: "127.0.0.1", ca: cert })
  extraSockets.push(mac)
  const mc = collector(mac)
  mac.write(`MPRELAY/1 AUTH ${SECRET_HEX}\n`)
  expect(await mc.until(() => mc.text === "OK\n")).toBe(true)
  const ph = tlsConnect({ port: r.port, host: "127.0.0.1", ca: cert })
  extraSockets.push(ph)
  const pc = collector(ph)
  ph.write(HEALTH)
  await mc.until(() => mc.text.includes("\r\n\r\n"))
  mac.end(HUB_403)
  expect(await pc.until(() => pc.text === HUB_403)).toBe(true)
})

test("new-secret.ts：relay.json 0600、不覆盖已有文件、密钥不打到终端；中继用它打印的 sha256 能认这把密钥", async () => {
  const dir = mkdtempSync(join(tmpdir(), "relay-secret-"))
  const out = join(dir, "relay.json")
  const run = () => Bun.spawnSync(["bun", join(import.meta.dir, "new-secret.ts"), "relay.example.com", "8443", "--out", out])
  const first = run()
  expect(first.exitCode).toBe(0)
  const cfg = JSON.parse(readFileSync(out, "utf8"))
  expect(statSync(out).mode & 0o777).toBe(0o600)
  const stdout = first.stdout.toString()
  expect(stdout).not.toContain(cfg.secret)
  const sha = /MP_RELAY_SECRET_SHA256=([0-9a-f]{64})/.exec(stdout)![1]
  expect(run().exitCode).not.toBe(0)   // 已存在不覆盖
  expect(JSON.parse(readFileSync(out, "utf8")).secret).toBe(cfg.secret)
  // 悬空符号链接：不顺着写到链接目标
  const dangling = join(dir, "dangling.json")
  symlinkSync(join(dir, "target.json"), dangling)
  expect(Bun.spawnSync(["bun", join(import.meta.dir, "new-secret.ts"), "relay.example.com", "8443", "--out", dangling]).exitCode).not.toBe(0)
  expect(existsSync(join(dir, "target.json"))).toBe(false)

  const r = await start({ secretSha256: Buffer.from(sha, "hex") })
  expect((await connector(r.port, cfg.secret)).ok).toBe(true)
})

test("parsePhoneHead：手机自带的 X-Forwarded-For 换成中继看到的地址", () => {
  const p = parsePhoneHead("GET /health HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 127.0.0.1", "203.0.113.9")
  expect("rewritten" in p && p.rewritten).toBe("GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\nX-Forwarded-For: 203.0.113.9\r\n\r\n")
})

test("日志只有白名单字段：没有密钥 / 口令 / query / IP", async () => {
  const r = await start({ timings: { firstByteMs: 100, headMs: 200 } })
  await connector(r.port, "11".repeat(32))
  const mac = await connector(r.port)
  const p = phone(r.port, CC + "x")
  await mac.c.until(() => mac.c.text.includes(FAKE_TOKEN))
  mac.sock.write("HTTP/1.1 101 Switching Protocols\r\n\r\n")
  mac.sock.destroy()
  await p
  await phone(r.port, `GET /nope?token=${FAKE_TOKEN} HTTP/1.1\r\n\r\n`)
  await phone(r.port, `GET /health?token=${FAKE_TOKEN} HTTP/1.1\r\n`)
  await phone(r.port, HEALTH)
  expect(logs.length).toBeGreaterThan(5)
  for (const l of logs) {
    expect(l).not.toContain(FAKE_TOKEN)
    expect(l).not.toContain(SECRET_HEX)
    expect(l).not.toContain("11".repeat(32))
    expect(l).not.toContain("127.0.0.1")
    expect(l).not.toContain("?")
    expect(l).toMatch(/^\[relay\] [a-z_]+( listening.*| (conn|method|path|status|ms)=[A-Za-z0-9/]+)*$|^\[relay\] listening (tls|plain) port=\d+$/)
  }
})
