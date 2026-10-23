import { test, expect, beforeAll, afterAll } from "bun:test"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, statSync, symlinkSync, writeFileSync } from "node:fs"
import { connect, createServer } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { prepareRelaySocket, relayIngressRequests, relayRequestAllowed } from "./relay-ingress.ts"
import { parseRelayConfig, relayPhoneURL } from "./relay-config.ts"
import { isTrustedLocal } from "./hub.ts"

// 隔离 hub：随机端口、临时 secrets、短 socket 路径；绝不碰生产 7890
const TEST_PORT = 18890 + Math.floor(Math.random() * 1000)
const SECRETS = mkdtempSync(join(tmpdir(), "cc-relay-in-"))
const SOCK_DIR = mkdtempSync(join(tmpdir(), "r-"))
const SOCK = join(SOCK_DIR, "in", "hub.sock")
const SECRET_HEX = "ab".repeat(32)
const WS_KEY = "dGhlIHNhbXBsZSBub25jZQ=="

let hub: ReturnType<typeof Bun.spawn> | undefined

beforeAll(async () => {
  writeFileSync(join(SECRETS, "relay.json"), JSON.stringify({ host: "127.0.0.1", port: 9, secret: SECRET_HEX, tls: false }))
  hub = Bun.spawn(["bun", "run", "hub.ts"], {
    cwd: import.meta.dir,
    env: {
      ...process.env,
      MP_CC_TMUX_DRY_RUN: "1", MP_CC_HUB_TOKEN: "test-token", MP_CC_HUB_PORT: String(TEST_PORT), MP_CC_HUB_HOST: "127.0.0.1",
      MP_CC_SECRETS_DIR: SECRETS, MP_CC_AGENT_DIR: SECRETS, MP_CC_WORKDIR: SECRETS, MP_CODEX_WORKDIR: join(SECRETS, "gpt-rp"),
      MP_APNS_KEY_PATH: join(SECRETS, "no-such-key.p8"), MP_CC_LA_INTERVAL_MS: "3600000",
      MP_CC_RELAY_SOCK: SOCK, MP_CC_RELAY_CONNECTOR: "off", MP_CC_ALLOWED_BUNDLES: "com.test.ok",
    },
  })
  const deadline = Date.now() + 8_000
  while (Date.now() < deadline) {
    if (hub.exitCode !== null) throw new Error(`test hub exited ${hub.exitCode}`)
    if (existsSync(SOCK)) return
    await Bun.sleep(100)
  }
  throw new Error("relay ingress socket did not appear")
})

afterAll(() => { hub?.kill() })

function viaSocket(text: string, timeoutMs = 2000): Promise<Buffer> {
  return new Promise((resolve) => {
    const s = connect(SOCK)
    const chunks: Buffer[] = []
    const done = () => { clearTimeout(timer); s.destroy(); resolve(Buffer.concat(chunks)) }
    const timer = setTimeout(done, timeoutMs)
    s.on("data", (d) => chunks.push(d))
    s.on("close", done)
    s.on("error", done)
    s.write(text)
  })
}

function upgradeText(path: string, extra: string[] = []): string {
  return [`GET ${path} HTTP/1.1`, "Host: relay.example", "Upgrade: websocket", "Connection: Upgrade", `Sec-WebSocket-Key: ${WS_KEY}`, "Sec-WebSocket-Version: 13", ...extra].join("\r\n") + "\r\n\r\n"
}

/// 101 之后的服务器帧（服务器帧不加掩码）
function frames(buf: Buffer): { opcode: number; payload: Buffer }[] {
  const at = buf.indexOf("\r\n\r\n")
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

function closeCode(buf: Buffer): number | null {
  const c = frames(buf).find((f) => f.opcode === 8)
  return c && c.payload.length >= 2 ? c.payload.readUInt16BE(0) : null
}

test("#068 S2 入口 socket 0600、所在目录 0700", () => {
  expect(statSync(SOCK).mode & 0o777).toBe(0o600)
  expect(statSync(join(SOCK_DIR, "in")).mode & 0o777).toBe(0o700)
})

test("#068 S2 入口 /health 按远程：403 + x-mp-hub", async () => {
  const res = (await viaSocket("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")).toString("latin1")
  expect(res.split("\r\n")[0]).toBe("HTTP/1.1 403 Forbidden")
  expect(res.toLowerCase()).toContain("x-mp-hub: 1")
})

test("#068 S2 入口只放 GET /health 和 WS /cc：其余 HTTP 一律 404", async () => {
  for (const req of [
    "GET /pair?token=test-token HTTP/1.1",
    "POST /pocket/cmd HTTP/1.1",
    "POST /thinking HTTP/1.1",
    "GET /warroom/sessions?token=test-token HTTP/1.1",
    "POST /health HTTP/1.1",
  ]) {
    const res = (await viaSocket(`${req}\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}`)).toString("latin1")
    expect(`${req} → ${res.split("\r\n")[0]}`).toBe(`${req} → HTTP/1.1 404 Not Found`)
  }
})

// Bun 的 upgrade 回调里写出的非 101 回应发不出去（write / end 都一样），客户端只看到连接被关
test("#068 S2 入口 upgrade：/mcp /agora / 带 Origin 都不升级、直接断", async () => {
  for (const path of ["/mcp?token=test-token", "/agora?token=test-token"]) {
    const res = (await viaSocket(upgradeText(path))).toString("latin1")
    expect(`${path} → ${res.slice(0, 12)}`).not.toBe(`${path} → HTTP/1.1 101`)
    expect(res).not.toContain("hello")
  }
  const withOrigin = (await viaSocket(upgradeText("/cc?token=test-token&bundle=com.test.ok", ["Origin: https://evil.example"]))).toString("latin1")
  expect(withOrigin.startsWith("HTTP/1.1 101")).toBe(false)
})

test("#068 S2 入口 WS /cc：没口令 1008、bundle 不对 1008、全对收到 hello", async () => {
  expect(closeCode(await viaSocket(upgradeText("/cc"), 1000))).toBe(1008)
  expect(closeCode(await viaSocket(upgradeText("/cc?token=wrong&bundle=com.test.ok"), 1000))).toBe(1008)
  expect(closeCode(await viaSocket(upgradeText("/cc?token=test-token&bundle=com.bad"), 1000))).toBe(1008)
  const ok = await viaSocket(upgradeText("/cc?token=test-token&bundle=com.test.ok"), 1000)
  expect(ok.toString("latin1").startsWith("HTTP/1.1 101")).toBe(true)
  const first = frames(ok)[0]
  expect(first.opcode).toBe(1)
  expect(JSON.parse(first.payload.toString()).type).toBe("hello")
})

test("#068 S2 本机 TCP 端口照旧：直连 /health 200", async () => {
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}/health`)
  expect(res.status).toBe(200)
})

test("#068 S2 isTrustedLocal：中继入口进来的请求就算 loopback 也不信", () => {
  const req = { socket: { remoteAddress: "127.0.0.1" }, headers: { host: "127.0.0.1" } } as unknown as Parameters<typeof isTrustedLocal>[0]
  expect(isTrustedLocal(req)).toBe(true)
  relayIngressRequests.add(req)
  expect(isTrustedLocal(req)).toBe(false)
})

test("#068 S2 relayRequestAllowed", () => {
  expect(relayRequestAllowed("GET", "/health", false)).toBe(true)
  expect(relayRequestAllowed("GET", "/health?x=1", false)).toBe(true)
  expect(relayRequestAllowed("GET", "/cc", false)).toBe(false)
  expect(relayRequestAllowed("GET", "/cc?token=t", true)).toBe(true)
  expect(relayRequestAllowed("GET", "/health", true)).toBe(false)
  expect(relayRequestAllowed("POST", "/cc", true)).toBe(false)
  expect(relayRequestAllowed("GET", "/cc/../mcp", true)).toBe(false)
})

test("#068 S2 prepareRelaySocket：长度 / 符号链接 / 权限 / 旧文件", async () => {
  const base = mkdtempSync(join(tmpdir(), "rp-"))
  expect(await prepareRelaySocket(join(base, "x".repeat(120), "s.sock"))).toContain("字节")

  const real = join(base, "real"); mkdirSync(real)
  symlinkSync(real, join(base, "link"))
  expect(await prepareRelaySocket(join(base, "link", "s.sock"))).toContain("符号链接")

  const loose = join(base, "loose"); mkdirSync(loose, { mode: 0o755 }); chmodSync(loose, 0o755)
  expect(await prepareRelaySocket(join(loose, "s.sock"))).toBeNull()
  expect(statSync(loose).mode & 0o777).toBe(0o700)

  const file = join(loose, "file.sock"); writeFileSync(file, "x")
  expect(await prepareRelaySocket(file)).toContain("不是自己的")

  // 旧 socket：bind 了但进程已退出 → 连不上 → 删掉
  const stale = join(loose, "stale.sock")
  Bun.spawnSync(["python3", "-c", `import socket; socket.socket(socket.AF_UNIX).bind(${JSON.stringify(stale)})`])
  expect(existsSync(stale)).toBe(true)
  expect(await prepareRelaySocket(stale)).toBeNull()
  expect(existsSync(stale)).toBe(false)

  // 活着的 socket：不删，拒绝
  const alive = join(loose, "alive.sock")
  const srv = createServer().listen(alive)
  await new Promise((r) => srv.once("listening", r))
  expect(await prepareRelaySocket(alive)).toContain("别的 hub")
  expect(existsSync(alive)).toBe(true)

  // 自己没读写权限时连不上可能是 EACCES（Bun 报不出来）：不能当旧文件删
  chmodSync(alive, 0o000)
  expect(await prepareRelaySocket(alive)).toContain("判断不了")
  expect(existsSync(alive)).toBe(true)
  srv.close()

  // 上层目录别人可写（没有 sticky）：可能被整个换掉，拒绝
  const open = join(base, "open"); mkdirSync(open); chmodSync(open, 0o777)
  mkdirSync(join(open, "sub"), { mode: 0o700 })
  expect(await prepareRelaySocket(join(open, "sub", "in", "s.sock"))).toContain("上层目录")
})

test("#068 relay.json 校验 + 手机地址", () => {
  const ok = parseRelayConfig({ host: "relay.example.com", port: 8443, secret: SECRET_HEX })
  expect(typeof ok).toBe("object")
  expect(relayPhoneURL(ok as Exclude<typeof ok, string>)).toBe("wss://relay.example.com:8443/cc")
  expect(relayPhoneURL(parseRelayConfig({ host: "1.2.3.4", port: 443, secret: SECRET_HEX }) as any)).toBe("wss://1.2.3.4/cc")
  expect(relayPhoneURL(parseRelayConfig({ host: "2001:db8::1", port: 8443, secret: SECRET_HEX }) as any)).toBe("wss://[2001:db8::1]:8443/cc")
  expect(relayPhoneURL(parseRelayConfig({ host: "127.0.0.1", port: 8443, secret: SECRET_HEX, tls: false }) as any)).toBeNull()
  expect(parseRelayConfig({ host: "relay.example.com", port: 8443, secret: "short" })).toContain("secret")
  expect(parseRelayConfig({ host: "relay.example.com/x", port: 8443, secret: SECRET_HEX })).toContain("host")
  expect(parseRelayConfig({ host: "relay.example.com", port: 70000, secret: SECRET_HEX })).toContain("port")
  expect(parseRelayConfig({ host: "relay.example.com", port: 8443, secret: SECRET_HEX, tls: false })).toContain("本机")
  expect(parseRelayConfig({ host: "relay.example.com", port: 8443, secret: SECRET_HEX, pinSpkiSha256: "nope" })).toContain("pin")
})
