// MP_CC_HUB_EXTRA_HOSTS（plan-multi-hub A7 ②）：hub 额外多听一个具体地址，经它来的连接来源不是 loopback → 必须口令，
// 伪造 `Host: localhost` 也没用。隔离子进程 + 临时目录 + DRY_RUN + PORT=0，不碰 7890、不碰真 tmux。
// 「VPS 网卡地址」在本机用一块非 internal 的 IPv4 网卡顶替（同机连自己的网卡地址，来源就是那个地址）；没有就跳过。
import { test, expect, describe, afterAll } from "bun:test"
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs"
import { tmpdir, networkInterfaces } from "node:os"
import { connect } from "node:net"
import { join } from "node:path"
import { pairURLs, parseExtraHosts } from "./hub.ts"

describe("parseExtraHosts", () => {
  test("逗号分隔、去空白、去重；空串 / 只有逗号 = 不加", () => {
    expect(parseExtraHosts(" 203.0.113.7 , 198.51.100.2,203.0.113.7 ")).toEqual({ hosts: ["203.0.113.7", "198.51.100.2"], rejected: [] })
    expect(parseExtraHosts(undefined)).toEqual({ hosts: [], rejected: [] })
    expect(parseExtraHosts("")).toEqual({ hosts: [], rejected: [] })
    expect(parseExtraHosts(" , ,")).toEqual({ hosts: [], rejected: [] })
  })
  test("拒全接口地址和非 IP（不让它退化成绑 0.0.0.0）", () => {
    const r = parseExtraHosts("0.0.0.0,::,0:0:0:0:0:0:0:0,::ffff:0.0.0.0,[::],localhost,vps.example.com,2001:db8::5")
    expect(r.hosts).toEqual(["2001:db8::5"])
    expect(r.rejected).toEqual(["0.0.0.0", "::", "0:0:0:0:0:0:0:0", "::ffff:0.0.0.0", "[::]", "localhost", "vps.example.com"])
  })
})

describe("pairURLs（/pair 的 u / u2，B0.3）", () => {
  const on = (...hs: string[]) => (h: string) => hs.includes(h)
  const base = { port: 7890, extraHosts: ["203.0.113.7", "198.51.100.2"] }
  test("有 Tailscale 时不变：LAN + TS → u=LAN u2=TS；只有 TS → u=TS u2=null（extra 不进来）", () => {
    expect(pairURLs({ ...base, lan: "192.168.1.5", tailscale: "100.64.0.9", listening: on("192.168.1.5", "100.64.0.9", "203.0.113.7") }))
      .toEqual({ u: "ws://192.168.1.5:7890/cc", u2: "ws://100.64.0.9:7890/cc" })
    expect(pairURLs({ ...base, tailscale: "100.64.0.9", listening: on("100.64.0.9", "203.0.113.7") }))
      .toEqual({ u: "ws://100.64.0.9:7890/cc", u2: null })
  })
  test("没有 Tailscale、有 LAN：u2 = 第一个在听的 extra；没在听的跳过；跟 u 重复的跳过", () => {
    expect(pairURLs({ ...base, lan: "192.168.1.5", listening: on("192.168.1.5", "203.0.113.7", "198.51.100.2") }))
      .toEqual({ u: "ws://192.168.1.5:7890/cc", u2: "ws://203.0.113.7:7890/cc" })
    // Tailscale 网卡在但没在听（开关关了）= 没有 Tailscale
    expect(pairURLs({ ...base, lan: "203.0.113.7", tailscale: "100.64.0.9", listening: on("203.0.113.7", "198.51.100.2") }))
      .toEqual({ u: "ws://203.0.113.7:7890/cc", u2: "ws://198.51.100.2:7890/cc" })
    expect(pairURLs({ port: 7890, extraHosts: ["203.0.113.7"], lan: "203.0.113.7", listening: on("203.0.113.7") }))
      .toEqual({ u: "ws://203.0.113.7:7890/cc", u2: null })
    expect(pairURLs({ port: 7890, extraHosts: [], listening: on() })).toEqual({ u: null, u2: null })
  })
  test("LAN + TS 都没有：u = 第一个在听的 extra，u2 = null（app 拒 u 为空的码）", () => {
    expect(pairURLs({ ...base, listening: on("203.0.113.7", "198.51.100.2") }))
      .toEqual({ u: "ws://203.0.113.7:7890/cc", u2: null })
    expect(pairURLs({ ...base, listening: on("198.51.100.2") }))
      .toEqual({ u: "ws://198.51.100.2:7890/cc", u2: null })
    // LAN / TS 网卡在但没在听（手动 HOST 模式）同样算没有
    expect(pairURLs({ ...base, lan: "192.168.1.5", tailscale: "100.64.0.9", listening: on("198.51.100.2") }))
      .toEqual({ u: "ws://198.51.100.2:7890/cc", u2: null })
  })
  test("IPv6 extra 地址加方括号", () => {
    expect(pairURLs({ port: 7890, extraHosts: ["2001:db8::5"], listening: on("2001:db8::5") }))
      .toEqual({ u: "ws://[2001:db8::5]:7890/cc", u2: null })
  })
})

function nicIPv4(): string | undefined {
  for (const addrs of Object.values(networkInterfaces())) {
    for (const a of addrs ?? []) if (a.family === "IPv4" && !a.internal) return a.address
  }
  return undefined
}
const NIC = nicIPv4()
const TOKEN = "extra-hosts-test-token"
const tmpRoots: string[] = []
afterAll(() => { for (const d of tmpRoots) rmSync(d, { recursive: true, force: true }) })

/// 起一个隔离 hub，等到 extra 地址的 listening 行；返回端口和收尾函数
async function bootHub(host: string, bindConfig?: object): Promise<{ port: number; stop: () => Promise<void> }> {
  const root = mkdtempSync(join(tmpdir(), "cc-hub-extra-"))
  tmpRoots.push(root)
  const secrets = join(root, "secrets")
  const home = join(root, "home")
  mkdirSync(secrets); mkdirSync(home)
  if (bindConfig) writeFileSync(join(secrets, "bind-config.json"), JSON.stringify(bindConfig))
  const proc = Bun.spawn(["bun", "run", "hub.ts"], {
    cwd: import.meta.dir,
    env: {
      ...process.env,
      HOME: home,
      MP_CC_THINKING_SPOOL: join(root, "spool"),
      MP_CC_LA_INTERVAL_MS: "3600000",
      MP_CC_TMUX_DRY_RUN: "1", MP_CC_WARROOM: "0", MP_CC_RELAY_CONNECTOR: "off",
      MP_CC_HUB_TOKEN: TOKEN, MP_CC_HUB_PORT: "0",
      MP_CC_HUB_HOST: host, MP_CC_HUB_EXTRA_HOSTS: `${NIC}, 0.0.0.0`,
      MP_CC_SECRETS_DIR: secrets, MP_CC_AGENT_DIR: join(root, "agent"),
      MP_CC_WORKDIR: join(root, "cc-rp"), MP_CODEX_WORKDIR: join(root, "gpt-rp"),
      MP_APNS_KEY_PATH: join(root, "no-such-key.p8"),
    },
    stdout: "pipe", stderr: "pipe",
  })
  const stop = async () => { proc.kill(); await proc.exited }
  const reader = proc.stdout.getReader()
  const decoder = new TextDecoder()
  let buf = ""
  const killer = setTimeout(() => proc.kill(), 15_000)
  try {
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      buf += decoder.decode(value)
      for (const line of buf.split("\n")) {
        if (!line.startsWith("{")) continue
        try {
          const o = JSON.parse(line)
          if (o.event === "listening" && o.host === NIC) { reader.releaseLock(); return { port: o.port, stop } }
        } catch { /* 半行 */ }
      }
    }
    throw new Error(`hub 没在 extra 地址上 listening：\n${buf.slice(-2000)}`)
  } catch (e) { await stop(); throw e } finally { clearTimeout(killer) }
}

/// 手搓一次 WS 升级（Host 头完全自己写，等于攻击者经隧道发来的原始字节）。
/// 返回 HTTP 状态码 + 101 之后 hub 发来的第一帧：close 帧给 code，文本帧给前 200 字
function upgrade(addr: string, port: number, path: string, hostHeader: string): Promise<{ status: number; close?: number; text?: string }> {
  return new Promise((resolve, reject) => {
    const sock = connect({ host: addr, port })
    let raw = Buffer.alloc(0)
    const t = setTimeout(() => { sock.destroy(); reject(new Error(`升级超时：${raw.toString("latin1").slice(0, 300)}`)) }, 8_000)
    const done = (r: { status: number; close?: number; text?: string }) => { clearTimeout(t); sock.destroy(); resolve(r) }
    sock.on("connect", () => sock.write(
      `GET ${path} HTTP/1.1\r\nHost: ${hostHeader}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
      `Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`))
    sock.on("data", (chunk) => {
      raw = Buffer.concat([raw, chunk])
      const end = raw.indexOf("\r\n\r\n")
      if (end < 0) return
      const status = Number(raw.subarray(0, end).toString("latin1").split(" ")[1])
      if (status !== 101) return done({ status })
      const f = raw.subarray(end + 4)
      if (f.length < 2) return
      const op = f[0] & 0x0f
      let len = f[1] & 0x7f, off = 2
      if (len === 126) { if (f.length < 4) return; len = f.readUInt16BE(2); off = 4 }
      else if (len === 127) { if (f.length < 10) return; len = Number(f.readBigUInt64BE(2)); off = 10 }
      if (op === 0x8) { if (f.length < off + 2) return; return done({ status, close: f.readUInt16BE(off) }) }
      if (op === 0x1) return done({ status, text: f.subarray(off, Math.min(f.length, off + len, off + 200)).toString("utf-8") })
    })
    sock.on("error", (e) => { clearTimeout(t); reject(e) })
  })
}

const maybe = NIC ? test : test.skip

maybe("手动 HOST 模式：extra 地址来的不带口令 + 伪造 Host: localhost → 1008；带口令 → 进得来；同样的伪造包打 loopback 是放行的（对照）", async () => {
  const hub = await bootHub("127.0.0.1")
  try {
    const forged = await upgrade(NIC!, hub.port, "/cc", "localhost")
    expect(forged).toEqual({ status: 101, close: 1008 })
    const forgedPort = await upgrade(NIC!, hub.port, "/cc", `localhost:${hub.port}`)
    expect(forgedPort.close).toBe(1008)
    const withToken = await upgrade(NIC!, hub.port, `/cc?token=${TOKEN}`, `${NIC}:${hub.port}`)
    expect(withToken.status).toBe(101)
    expect(withToken.close).toBeUndefined()
    expect(withToken.text).toContain("hello")
    // 对照：同一个伪造包从 loopback 进来就免口令——这正是 socat 转 127.0.0.1 不能用的原因
    const loop = await upgrade("127.0.0.1", hub.port, "/cc", "localhost")
    expect(loop.close).toBeUndefined()
    expect(loop.text).toContain("hello")
  } finally { await hub.stop() }
}, 40_000)

maybe("auto 模式 + bind-config 关掉 LAN / Tailscale：extra 地址照样绑上，伪造 Host 照样被拒", async () => {
  const hub = await bootHub("auto", { lan: false, tailscale: false })
  try {
    expect(await upgrade(NIC!, hub.port, "/cc", "localhost")).toEqual({ status: 101, close: 1008 })
    const ok = await upgrade(NIC!, hub.port, `/cc?token=${TOKEN}`, `${NIC}:${hub.port}`)
    expect(ok.text).toContain("hello")
  } finally { await hub.stop() }
}, 40_000)

maybe("B0.3 /pair：u 一定是 ws 地址；extra 地址在 u / u2 里出现（网卡同时是 LAN / Tailscale 时就是 u，不重复）", async () => {
  const hub = await bootHub("127.0.0.1")
  try {
    const body = await (await fetch(`http://127.0.0.1:${hub.port}/pair?token=${TOKEN}`)).json() as { u: string | null; u2: string | null }
    expect(body.u).toStartWith("ws://")
    expect([body.u, body.u2]).toContain(`ws://${NIC}:${hub.port}/cc`)
    expect(body.u).not.toBe(body.u2)
  } finally { await hub.stop() }
}, 40_000)
