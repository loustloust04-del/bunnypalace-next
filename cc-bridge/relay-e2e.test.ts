// #068 全链路：真中继（进程内）+ 隔离 hub（子进程，自己拉起 relay-connector）+ 手机侧客户端。
// 绝不碰生产 hub：随机端口、临时 secrets、短 socket 路径、假口令。
import { test, expect, afterAll } from "bun:test"
import { createHash, randomBytes } from "node:crypto"
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { connect, type Socket } from "node:net"
import { connect as tlsConnect } from "node:tls"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { WebSocket } from "ws"
import { startRelay, type RelayHandle } from "./relay/relay.ts"
import { spkiSha256 } from "./relay-connector.ts"

const HUB_TOKEN = "e2e-FAKE-hub-token-41c9"
const BUNDLE = "com.test.e2e"
const WS_KEY = "dGhlIHNhbXBsZSBub25jZQ=="

type Rig = { relay: RelayHandle; hub: ReturnType<typeof Bun.spawn>; hubPort: number; relayLogs: string[]; hubOut: () => string; secretHex: string }
const rigs: Rig[] = []

afterAll(async () => {
  for (const r of rigs) { r.hub.kill(); await r.relay.close() }
})

async function drain(stream: ReadableStream<Uint8Array>, sink: string[]): Promise<void> {
  const dec = new TextDecoder()
  for await (const chunk of stream) sink.push(dec.decode(chunk))
}

async function rig(tls?: { cert: Buffer; key: Buffer }): Promise<Rig> {
  const secret = randomBytes(32)
  const relayLogs: string[] = []
  const relay = await startRelay({ host: "127.0.0.1", port: 0, secretSha256: createHash("sha256").update(secret).digest(), tls, log: (l) => relayLogs.push(l) })
  const secrets = mkdtempSync(join(tmpdir(), "cc-e2e-"))
  const sock = join(mkdtempSync(join(tmpdir(), "e2e-")), "s", "hub.sock")
  const relayCfg: Record<string, unknown> = { host: "127.0.0.1", port: relay.port, secret: secret.toString("hex"), tls: !!tls }
  if (tls) relayCfg.pinSpkiSha256 = spkiSha256(Buffer.from(tls.cert.toString().replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""), "base64"))
  writeFileSync(join(secrets, "relay.json"), JSON.stringify(relayCfg))
  const hubPort = 19890 + Math.floor(Math.random() * 1000)
  const hub = Bun.spawn(["bun", "run", "hub.ts"], {
    cwd: import.meta.dir,
    stdout: "pipe", stderr: "pipe",
    env: {
      ...process.env,
      MP_CC_TMUX_DRY_RUN: "1", MP_CC_HUB_TOKEN: HUB_TOKEN, MP_CC_HUB_PORT: String(hubPort), MP_CC_HUB_HOST: "127.0.0.1",
      MP_CC_SECRETS_DIR: secrets, MP_CC_AGENT_DIR: secrets, MP_CC_WORKDIR: secrets, MP_CODEX_WORKDIR: join(secrets, "gpt-rp"),
      MP_APNS_KEY_PATH: join(secrets, "no-such-key.p8"), MP_CC_LA_INTERVAL_MS: "3600000",
      MP_CC_RELAY_SOCK: sock, MP_CC_ALLOWED_BUNDLES: BUNDLE,
    },
  })
  const out: string[] = []
  void drain(hub.stdout as ReadableStream<Uint8Array>, out)
  void drain(hub.stderr as ReadableStream<Uint8Array>, out)
  const r: Rig = { relay, hub, hubPort, relayLogs, hubOut: () => out.join(""), secretHex: secret.toString("hex") }
  rigs.push(r)
  const deadline = Date.now() + 10_000
  while (Date.now() < deadline && relay.stats().idle < 3) {
    if (hub.exitCode !== null) throw new Error(`hub exited ${hub.exitCode}: ${r.hubOut().slice(-2000)}`)
    await Bun.sleep(100)
  }
  if (relay.stats().idle < 3) throw new Error(`connector did not fill pool: ${r.hubOut().slice(-2000)}`)
  return r
}

function rawVia(open: () => Socket, text: string, until: (s: string) => boolean, ms = 3000): Promise<string> {
  return new Promise((resolve) => {
    const s = open()
    let buf = ""
    const done = () => { clearTimeout(t); s.destroy(); resolve(buf) }
    const t = setTimeout(done, ms)
    s.on("data", (d) => { buf += d.toString("latin1"); if (until(buf)) done() })
    s.on("close", done)
    s.on("error", done)
    s.write(text)
  })
}

const upgrade = (q: string) => `GET /cc${q} HTTP/1.1\r\nHost: relay.example\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${WS_KEY}\r\nSec-WebSocket-Version: 13\r\n\r\n`

function selfSigned(): { cert: Buffer; key: Buffer } {
  const dir = mkdtempSync(join(tmpdir(), "e2e-tls-"))
  const gen = Bun.spawnSync(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1",
    "-subj", "/CN=relay.test", "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", join(dir, "key.pem"), "-out", join(dir, "cert.pem")])
  if (gen.exitCode !== 0) throw new Error("openssl failed")
  return { cert: readFileSync(join(dir, "cert.pem")), key: readFileSync(join(dir, "key.pem")) }
}

test("明文中继：/health 经中继到真 hub（403 + x-mp-hub）；WS 带口令能收 hello、发消息拿 ack；没口令 / bundle 错 1008；/pair 不出 u3", async () => {
  const r = await rig()
  const health = await rawVia(() => connect(r.relay.port, "127.0.0.1"), "GET /health HTTP/1.1\r\nHost: relay.example\r\n\r\n", () => false)
  expect(health.split("\r\n")[0]).toBe("HTTP/1.1 403 Forbidden")
  expect(health.toLowerCase()).toContain("x-mp-hub: 1")

  const ws = new WebSocket(`ws://127.0.0.1:${r.relay.port}/cc?token=${HUB_TOKEN}&bundle=${BUNDLE}`)
  const frames: any[] = []
  ws.on("message", (d) => frames.push(JSON.parse(d.toString())))
  await new Promise((res, rej) => { ws.on("open", res); ws.on("error", rej) })
  ws.send(JSON.stringify({ type: "send", chat_id: "e2e-conv", message_id: "e2e-msg-1", content: "hello via relay", user: "susu" }))
  const deadline = Date.now() + 3000
  while (Date.now() < deadline && !frames.some((f) => f.type === "ack")) await Bun.sleep(20)
  expect(frames[0]?.type).toBe("hello")
  expect(frames.find((f) => f.type === "ack")?.message_id).toBe("e2e-msg-1")
  ws.close()

  const noToken = await rawVia(() => connect(r.relay.port, "127.0.0.1"), upgrade(`?bundle=${BUNDLE}`), (s) => s.includes("auth"))
  expect(noToken.startsWith("HTTP/1.1 101")).toBe(true)
  expect(noToken).toContain("\x03\xf0auth")   // close 1008 "auth"
  const badBundle = await rawVia(() => connect(r.relay.port, "127.0.0.1"), upgrade(`?token=${HUB_TOKEN}&bundle=com.evil`), (s) => s.includes("bundle"))
  expect(badBundle).toContain("\x03\xf0bundle")

  // hub 日志里中继来的连接记成 relay
  expect(r.hubOut()).toContain("from relay")

  const pair = await (await fetch(`http://127.0.0.1:${r.hubPort}/pair?token=${HUB_TOKEN}`)).json() as Record<string, unknown>
  expect(pair.u3).toBeNull()   // 没开 TLS 的测试配置不出 u3（app 只接 wss）
})

test("自签 TLS + pin：connector 经 TLS 进池，/health 和 WS 握手都走通；/pair 出 u3 / p3", async () => {
  const tls = selfSigned()
  const r = await rig(tls)
  const viaTls = () => tlsConnect({ port: r.relay.port, host: "127.0.0.1", ca: tls.cert })
  const health = await rawVia(viaTls, "GET /health HTTP/1.1\r\nHost: relay.example\r\n\r\n", () => false)
  expect(health.split("\r\n")[0]).toBe("HTTP/1.1 403 Forbidden")
  expect(health.toLowerCase()).toContain("x-mp-hub: 1")
  const ws = await rawVia(viaTls, upgrade(`?token=${HUB_TOKEN}&bundle=${BUNDLE}`), (s) => s.includes("\"hello\""))
  expect(ws.startsWith("HTTP/1.1 101")).toBe(true)
  expect(ws).toContain("\"type\":\"hello\"")

  const pair = await (await fetch(`http://127.0.0.1:${r.hubPort}/pair?token=${HUB_TOKEN}`)).json() as Record<string, unknown>
  expect(pair.u3).toBe(`wss://127.0.0.1:${r.relay.port}/cc`)
  expect(pair.p3).toBe(spkiSha256(Buffer.from(tls.cert.toString().replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""), "base64")))
})

test("日志里没有口令 / 密钥（成功、失败、畸形请求跑完之后）", async () => {
  const r = rigs[0]
  await rawVia(() => connect(r.relay.port, "127.0.0.1"), `GET /mcp?token=${HUB_TOKEN} HTTP/1.1\r\n\r\n`, () => false, 500)
  await rawVia(() => connect(r.relay.port, "127.0.0.1"), `GET /cc?token=${HUB_TOKEN} HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc`, () => false, 500)
  await rawVia(() => connect(r.relay.port, "127.0.0.1"), `MPRELAY/1 AUTH ${"cd".repeat(32)}\n`, () => false, 500)
  for (const rr of rigs) {
    const all = rr.relayLogs.join("\n") + "\n" + rr.hubOut()
    expect(all).not.toContain(HUB_TOKEN)
    expect(all).not.toContain(rr.secretHex)
    expect(all).not.toContain("cd".repeat(32))
  }
})

test("Mac 掉线（hub 进程没了）：中继 spare 清空，/health 503 不带 x-mp-hub", async () => {
  const r = rigs[0]
  r.hub.kill("SIGKILL")
  const deadline = Date.now() + 5000
  while (Date.now() < deadline && r.relay.stats().spares > 0) await Bun.sleep(50)
  expect(r.relay.stats().spares).toBe(0)
  const health = await rawVia(() => connect(r.relay.port, "127.0.0.1"), "GET /health HTTP/1.1\r\nHost: relay.example\r\n\r\n", () => false)
  expect(health.split("\r\n")[0]).toBe("HTTP/1.1 503 Service Unavailable")
  expect(health.toLowerCase()).not.toContain("x-mp-hub")
})
