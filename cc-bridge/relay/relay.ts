// #068 自建中继（单房间：一个中继服务一台 Mac）。规则见 docs/plan-remote-relay.md §2。
//
// 同一个端口收两种连接，看头几个字节分流：
//   - Mac 的 relay-connector：`MPRELAY/1 AUTH <secret hex>\n` → 进 spare 池，等着被配对
//   - 手机：HTTP 请求，只认 GET /health 和 WS GET /cc；读完请求头，取一条 IDLE spare，
//     发 `OPEN\n` + 改写后的请求头，之后两边原样搬字节（一条管道只承载一个请求）
// 中继自己发出的回应（400 / 503 / 504 …）永远不带 x-mp-hub：app 只认带这个头的回应为「hub 活着」。
//
// 运行：MP_RELAY_SECRET_SHA256=<hex> MP_RELAY_CERT=<pem> MP_RELAY_KEY=<pem> bun relay/relay.ts
//   MP_RELAY_HOST（默认 0.0.0.0）、MP_RELAY_PORT（默认 8443）；不给证书只准绑 127.0.0.1（测试用）。

import { createHash, timingSafeEqual } from "node:crypto"
import { readFileSync } from "node:fs"
import { createServer as createTcpServer, type Server, type Socket } from "node:net"
import { createServer as createTlsServer } from "node:tls"

export type RelayTimings = {
  authMs: number
  headMs: number
  pingIntervalMs: number
  pongMs: number
  spareWaitMs: number
  firstByteMs: number
  pipeIdleMs: number
}

export type RelayLimits = {
  /// TCP 接入起算（含 TLS 握手、分类、读头、鉴权、spare、管道）
  connections: number
  connectionsPerIp: number
  unclassifiedPerIp: number
  pendingHeads: number
  phonePerIp: number
  phonePerIpPerMinute: number
  pipes: number
  pendingAuth: number
  /// 鉴权**失败**每 IP 每分钟（合法补池不计，免得匿名探活把 Mac 的补池额度耗光）
  authFailPerIpPerMinute: number
  spares: number
}

export const DEFAULT_TIMINGS: RelayTimings = {
  authMs: 5_000, headMs: 10_000, pingIntervalMs: 20_000, pongMs: 25_000,
  spareWaitMs: 1_000, firstByteMs: 10_000, pipeIdleMs: 600_000,
}

export const DEFAULT_LIMITS: RelayLimits = {
  connections: 512, connectionsPerIp: 64,
  unclassifiedPerIp: 8, pendingHeads: 256, phonePerIp: 8, phonePerIpPerMinute: 30,
  pipes: 64, pendingAuth: 8, authFailPerIpPerMinute: 20, spares: 16,
}

export type RelayOptions = {
  host: string
  port: number
  /// sha256(32 字节密钥原文)
  secretSha256: Buffer
  tls?: { cert: string | Buffer; key: string | Buffer }
  timings?: Partial<RelayTimings>
  limits?: Partial<RelayLimits>
  log?: (line: string) => void
}

export type RelayHandle = { port: number; close: () => Promise<void>; stats: () => { spares: number; idle: number; pipes: number } }

const CONNECTOR_PREFIX = "MPRELAY/"
const AUTH_LINE_MAX = 256
const HEAD_MAX = 8 * 1024
const TOKEN_RE = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/
const STRIPPED_FOR_HEALTH = new Set(["connection", "keep-alive", "upgrade", "x-forwarded-for"])

type LogFields = { conn?: number; method?: string; path?: string; status?: number; ms?: number }

function response(status: number, reason: string): string {
  return `HTTP/1.1 ${status} ${reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`
}

function normalizeIp(addr: string | undefined): string {
  if (!addr) return "-"
  return addr.startsWith("::ffff:") ? addr.slice(7) : addr
}

export type ParsedHead = { method: string; path: "/health" | "/cc"; rewritten: string } | { status: number; reason: string }

/// 校验并改写手机的请求头（不含结尾空行）。只认 GET /health 和 WS GET /cc；带 body 的一律拒；
/// 不接受裸 CR / LF、折行、非法头名——中继和 hub 对同一段字节的理解必须一致。
export function parsePhoneHead(head: string, phoneIp: string): ParsedHead {
  const lines = head.split("\r\n")
  if (lines.some((l) => /[\r\n\0]/.test(l))) return { status: 400, reason: "Bad Request" }
  const parts = lines[0].split(" ")
  if (parts.length !== 3 || parts[2] !== "HTTP/1.1") return { status: 400, reason: "Bad Request" }
  const [method, target] = parts
  if (!target.startsWith("/")) return { status: 400, reason: "Bad Request" }
  const path = target.split("?")[0]
  if (path !== "/health" && path !== "/cc") return { status: 404, reason: "Not Found" }
  if (method !== "GET") return { status: 405, reason: "Method Not Allowed" }
  const headers: [string, string][] = []
  for (const line of lines.slice(1)) {
    if (line.startsWith(" ") || line.startsWith("\t")) return { status: 400, reason: "Bad Request" }
    const i = line.indexOf(":")
    if (i <= 0) return { status: 400, reason: "Bad Request" }
    const name = line.slice(0, i)
    if (!TOKEN_RE.test(name)) return { status: 400, reason: "Bad Request" }
    headers.push([name, line.slice(i + 1).trim()])
  }
  const has = (n: string) => headers.some(([k]) => k.toLowerCase() === n)
  const get = (n: string) => headers.filter(([k]) => k.toLowerCase() === n).map(([, v]) => v).join(",")
  if (has("content-length") || has("transfer-encoding")) return { status: 400, reason: "Bad Request" }
  let kept: [string, string][]
  if (path === "/cc") {
    // Connection 按逗号拆开精确比 token：`x-upgrade` 这种中继放行、hub 却当普通请求的，会让后续字节被当成第二个请求
    const connTokens = get("connection").split(",").map((t) => t.trim().toLowerCase())
    if (get("upgrade").toLowerCase() !== "websocket" || !connTokens.includes("upgrade")) return { status: 400, reason: "Bad Request" }
    kept = headers.filter(([k]) => k.toLowerCase() !== "x-forwarded-for")
  } else {
    kept = [...headers.filter(([k]) => !STRIPPED_FOR_HEALTH.has(k.toLowerCase())), ["Connection", "close"]]
  }
  kept.push(["X-Forwarded-For", phoneIp])
  return { method, path, rewritten: [lines[0], ...kept.map(([k, v]) => `${k}: ${v}`)].join("\r\n") + "\r\n\r\n" }
}

type Spare = { sock: Socket; state: "IDLE" | "PINGING"; buf: string; pingTimer?: ReturnType<typeof setTimeout>; pongTimer?: ReturnType<typeof setTimeout> }

/// 每 IP 每分钟计数（固定窗口）
class RateWindow {
  private map = new Map<string, { start: number; count: number }>()
  constructor(private perMinute: number) {}
  hit(ip: string, now = Date.now()): boolean {
    const w = this.map.get(ip)
    if (!w || now - w.start >= 60_000) { this.map.set(ip, { start: now, count: 1 }); return true }
    w.count++
    return w.count <= this.perMinute
  }
  /// 只看不记（鉴权失败计数：先查再在失败时 hit）
  exceeded(ip: string, now = Date.now()): boolean {
    const w = this.map.get(ip)
    return !!w && now - w.start < 60_000 && w.count >= this.perMinute
  }
  prune(now = Date.now()): void { for (const [ip, w] of this.map) if (now - w.start >= 60_000) this.map.delete(ip) }
}

function bump(map: Map<string, number>, ip: string, d: number): void {
  const n = (map.get(ip) ?? 0) + d
  if (n <= 0) map.delete(ip); else map.set(ip, n)
}

export function startRelay(opts: RelayOptions): Promise<RelayHandle> {
  if (!opts.tls && opts.host !== "127.0.0.1") return Promise.reject(new Error("没有证书只准绑 127.0.0.1（测试用）"))
  if (opts.secretSha256.length !== 32) return Promise.reject(new Error("secretSha256 必须是 32 字节"))
  const T = { ...DEFAULT_TIMINGS, ...opts.timings }
  const L = { ...DEFAULT_LIMITS, ...opts.limits }
  const log = (event: string, f: LogFields = {}) => {
    const parts = [event]
    if (f.conn !== undefined) parts.push(`conn=${f.conn}`)
    if (f.method) parts.push(`method=${f.method}`)
    if (f.path) parts.push(`path=${f.path}`)
    if (f.status !== undefined) parts.push(`status=${f.status}`)
    if (f.ms !== undefined) parts.push(`ms=${f.ms}`)
    ;(opts.log ?? console.log)(`[relay] ${parts.join(" ")}`)
  }

  let nextConn = 1
  const spares: Spare[] = []
  const waiters: ((s: Spare | undefined) => void)[] = []
  const unclassifiedByIp = new Map<string, number>()
  const phonesByIp = new Map<string, number>()
  const phoneRate = new RateWindow(L.phonePerIpPerMinute)
  const authFail = new RateWindow(L.authFailPerIpPerMinute)
  const connsByIp = new Map<string, number>()
  let connections = 0
  let pendingHeads = 0
  let pendingAuth = 0
  let pipes = 0
  const allSockets = new Set<Socket>()
  const pruneTimer = setInterval(() => { phoneRate.prune(); authFail.prune() }, 60_000)

  /// 拒绝后统一收尾：end 把回应送出去，5s 不关硬断
  const endThenKill = (s: Socket, last?: string) => {
    if (s.destroyed) return
    if (last) s.end(last); else s.end()
    setTimeout(() => s.destroy(), 5_000).unref()
  }

  const removeSpare = (s: Spare) => {
    const i = spares.indexOf(s)
    if (i >= 0) spares.splice(i, 1)
    clearTimeout(s.pingTimer); clearTimeout(s.pongTimer)
  }

  const schedulePing = (s: Spare) => {
    clearTimeout(s.pingTimer)
    s.pingTimer = setTimeout(() => {
      if (s.state !== "IDLE") return
      s.state = "PINGING"
      s.sock.write("PING\n")
      s.pongTimer = setTimeout(() => s.sock.destroy(), T.pongMs)
    }, T.pingIntervalMs)
  }

  const becameIdle = (s: Spare) => {
    s.state = "IDLE"
    clearTimeout(s.pongTimer)
    const w = waiters.shift()
    if (w) { removeSpare(s); w(s); return }
    schedulePing(s)
  }

  const takeSpare = (): Promise<Spare | undefined> => {
    const idle = spares.find((s) => s.state === "IDLE")
    if (idle) { removeSpare(idle); return Promise.resolve(idle) }
    if (spares.length === 0) return Promise.resolve(undefined)
    return new Promise((resolve) => {
      const w = (s: Spare | undefined) => { clearTimeout(t); resolve(s) }
      const t = setTimeout(() => { const i = waiters.indexOf(w); if (i >= 0) waiters.splice(i, 1); resolve(undefined) }, T.spareWaitMs)
      waiters.push(w)
    })
  }

  const handleConnector = (sock: Socket, ip: string, conn: number, initial: string, release: () => void) => {
    if (pendingAuth >= L.pendingAuth || authFail.exceeded(ip)) { log("connector_limited", { conn }); sock.destroy(); return }
    pendingAuth++
    let buf = initial
    let done = false
    const finish = () => { if (!done) { done = true; pendingAuth--; clearTimeout(timer); release() } }
    const timer = setTimeout(() => { finish(); sock.destroy() }, T.authMs)
    sock.on("close", finish)
    const tryAuth = () => {
      const nl = buf.indexOf("\n")
      if (nl < 0) { if (buf.length > AUTH_LINE_MAX) { finish(); authFail.hit(ip); sock.destroy() } return }
      sock.removeListener("data", onData)
      const line = buf.slice(0, nl)
      const rest = buf.slice(nl + 1)
      finish()
      const m = /^MPRELAY\/1 AUTH ([0-9a-f]{64})$/.exec(line)
      const ok = !!m && timingSafeEqual(createHash("sha256").update(Buffer.from(m[1], "hex")).digest(), opts.secretSha256)
      if (!ok || rest.length > 0) { authFail.hit(ip); log("connector_auth_fail", { conn }); sock.destroy(); return }
      if (spares.length >= L.spares) { log("connector_pool_full", { conn }); sock.destroy(); return }
      const spare: Spare = { sock, state: "IDLE", buf: "" }
      spares.push(spare)
      sock.setKeepAlive(true, 30_000)
      sock.on("data", (d: Buffer) => {
        spare.buf += d.toString("latin1")
        let i: number
        while ((i = spare.buf.indexOf("\n")) >= 0) {
          const l = spare.buf.slice(0, i)
          spare.buf = spare.buf.slice(i + 1)
          if (l === "PONG" && spare.state === "PINGING") becameIdle(spare)
          else { sock.destroy(); return }
        }
        if (spare.buf.length > 16) sock.destroy()
      })
      sock.on("close", () => removeSpare(spare))
      sock.write("OK\n")
      log("connector_ready", { conn })
      becameIdle(spare)
    }
    const onData = (d: Buffer) => { buf += d.toString("latin1"); tryAuth() }
    sock.on("data", onData)
    tryAuth()
  }

  const handlePhone = (sock: Socket, ip: string, conn: number, initial: Buffer, release: () => void) => {
    if ((phonesByIp.get(ip) ?? 0) >= L.phonePerIp || !phoneRate.hit(ip)) { release(); log("phone_limited", { conn }); endThenKill(sock, response(429, "Too Many Requests")); return }
    bump(phonesByIp, ip, 1)
    sock.on("close", () => bump(phonesByIp, ip, -1))
    const started = Date.now()
    let buf = initial
    let headDone = false
    let rejected = false
    const endHead = () => { if (!headDone) { headDone = true; release(); clearTimeout(headTimer) } }
    sock.on("close", endHead)
    // 拒绝是终态：摘掉解析监听、丢掉缓冲，迟到的字节不会再走到 open
    const reject = (status: number, reason: string, f: LogFields = {}) => {
      if (rejected) return
      rejected = true
      sock.removeListener("data", onData)
      buf = Buffer.alloc(0)
      endHead()
      log("phone_reject", { conn, status, ...f })
      endThenKill(sock, response(status, reason))
    }
    const headTimer = setTimeout(() => reject(408, "Request Timeout"), T.headMs)
    const onData = (d: Buffer) => { buf = Buffer.concat([buf, d]); tryHead() }
    const tryHead = () => {
      if (rejected) return
      const at = buf.indexOf("\r\n\r\n")
      if (at < 0) { if (buf.length > HEAD_MAX) { sock.removeListener("data", onData); reject(431, "Request Header Fields Too Large") } return }
      if (at > HEAD_MAX) { sock.removeListener("data", onData); reject(431, "Request Header Fields Too Large"); return }
      sock.removeListener("data", onData)
      endHead()
      const parsed = parsePhoneHead(buf.subarray(0, at).toString("latin1"), ip)
      if ("status" in parsed) { reject(parsed.status, parsed.reason); return }
      const rest = buf.subarray(at + 4)
      sock.pause()
      void open(parsed, rest)
    }
    const open = async (p: Exclude<ParsedHead, { status: number }>, rest: Buffer) => {
      // 等 spare 之前就占住管道名额：多个等待者同时拿到 spare 也不会超过上限
      if (pipes >= L.pipes) { reject(503, "Service Unavailable", { method: p.method, path: p.path }); return }
      pipes++
      const spare = await takeSpare()
      if (sock.destroyed) { pipes--; if (spare) spare.sock.destroy(); return }
      if (!spare || spare.sock.destroyed) { pipes--; reject(503, "Service Unavailable", { method: p.method, path: p.path }); return }
      const mac = spare.sock
      mac.removeAllListeners("data")
      let macSent = false
      let finished = false
      const finish = () => {
        if (finished) return
        finished = true
        pipes--
        clearTimeout(firstByte)
        log("pipe_closed", { conn, method: p.method, path: p.path, ms: Date.now() - started })
      }
      let timedOut = false
      const firstByte = setTimeout(() => {
        if (macSent) return
        timedOut = true
        log("phone_reject", { conn, status: 504, method: p.method, path: p.path })
        endThenKill(sock, response(504, "Gateway Timeout"))
        mac.destroy()
      }, T.firstByteMs)
      mac.on("data", (d: Buffer) => { macSent = true; if (!sock.write(d)) mac.pause() })
      sock.on("drain", () => mac.resume())
      mac.on("close", () => {
        if (macSent) endThenKill(sock)
        else if (!timedOut) { log("phone_reject", { conn, status: 502, method: p.method, path: p.path }); endThenKill(sock, response(502, "Bad Gateway")) }
        finish()
      })
      sock.on("close", () => { endThenKill(mac); finish() })
      sock.setTimeout(T.pipeIdleMs, () => { sock.destroy(); mac.destroy() })
      mac.write(`OPEN\n${p.rewritten}`)
      if (p.path === "/cc") {
        if (rest.length) mac.write(rest)
        sock.on("data", (d: Buffer) => { if (!mac.write(d)) sock.pause() })
        mac.on("drain", () => sock.resume())
      } else {
        sock.on("data", () => {})   // /health：之后手机再发的字节丢掉
      }
      sock.resume()
      log("pipe_open", { conn, method: p.method, path: p.path })
    }
    sock.on("data", onData)
    tryHead()
  }

  /// TCP 接入就记账（TLS 握手还没完成的也算），所有阶段共用这两个上限
  const onTcp = (raw: Socket) => {
    allSockets.add(raw)
    raw.on("error", () => {})
    const ip = normalizeIp(raw.remoteAddress)
    if (connections >= L.connections || (connsByIp.get(ip) ?? 0) >= L.connectionsPerIp) { raw.destroy(); return }
    connections++
    bump(connsByIp, ip, 1)
    raw.on("close", () => { allSockets.delete(raw); connections--; bump(connsByIp, ip, -1) })
  }

  const onSocket = (sock: Socket) => {
    if (sock.destroyed) return   // onTcp 已按上限拒掉
    allSockets.add(sock)
    sock.on("close", () => allSockets.delete(sock))
    sock.on("error", () => {})
    const ip = normalizeIp(sock.remoteAddress)
    const conn = nextConn++
    if ((unclassifiedByIp.get(ip) ?? 0) >= L.unclassifiedPerIp || pendingHeads >= L.pendingHeads) { sock.destroy(); return }
    // 从接入起占「待读头 / 待鉴权」名额，读完头 / 鉴权完才放
    pendingHeads++
    let released = false
    const release = () => { if (!released) { released = true; pendingHeads-- } }
    sock.on("close", release)
    bump(unclassifiedByIp, ip, 1)
    let classified = false
    let buf = Buffer.alloc(0)
    const classify = () => { if (!classified) { classified = true; bump(unclassifiedByIp, ip, -1); clearTimeout(timer) } }
    const timer = setTimeout(() => { classify(); sock.destroy() }, T.headMs)
    sock.on("close", classify)
    const onData = (d: Buffer) => {
      buf = Buffer.concat([buf, d])
      const n = Math.min(buf.length, CONNECTOR_PREFIX.length)
      const head = buf.subarray(0, n).toString("latin1")
      if (CONNECTOR_PREFIX.startsWith(head) && n < CONNECTOR_PREFIX.length) return
      sock.removeListener("data", onData)
      classify()
      if (head === CONNECTOR_PREFIX) handleConnector(sock, ip, conn, buf.toString("latin1"), release)
      else handlePhone(sock, ip, conn, buf, release)
    }
    sock.on("data", onData)
  }

  const server: Server = opts.tls
    ? createTlsServer({ cert: opts.tls.cert, key: opts.tls.key, minVersion: "TLSv1.2", handshakeTimeout: T.authMs }, onSocket)
    : createTcpServer(onSocket)
  // net.Server 的 connection 就是 onSocket 那一下；TLS 时它在握手前，先记账（必须先于 onSocket 注册）
  if (opts.tls) server.on("connection", onTcp)
  else server.prependListener("connection", onTcp)
  // TLS 握手失败不进 onSocket；只记一行，不带对方信息
  server.on("tlsClientError", () => log("tls_error"))
  return new Promise((resolve, reject) => {
    server.once("error", reject)
    server.listen(opts.port, opts.host, () => {
      const addr = server.address()
      const port = addr && typeof addr === "object" ? addr.port : opts.port
      log(`listening ${opts.tls ? "tls" : "plain"} port=${port}`)
      resolve({
        port,
        stats: () => ({ spares: spares.length, idle: spares.filter((s) => s.state === "IDLE").length, pipes }),
        close: () => new Promise<void>((r) => {
          clearInterval(pruneTimer)
          for (const s of spares) removeSpare(s)
          for (const s of allSockets) s.destroy()
          server.close(() => r())
        }),
      })
    })
  })
}

if (import.meta.main) {
  const env = process.env
  const sha = env.MP_RELAY_SECRET_SHA256 ?? ""
  if (!/^[0-9a-f]{64}$/.test(sha)) { console.error("[relay] 需要 MP_RELAY_SECRET_SHA256（64 位 hex，见 relay/new-secret.ts）"); process.exit(1) }
  const tls = env.MP_RELAY_CERT && env.MP_RELAY_KEY ? { cert: readFileSync(env.MP_RELAY_CERT), key: readFileSync(env.MP_RELAY_KEY) } : undefined
  startRelay({ host: env.MP_RELAY_HOST ?? (tls ? "0.0.0.0" : "127.0.0.1"), port: Number(env.MP_RELAY_PORT ?? 8443), secretSha256: Buffer.from(sha, "hex"), tls })
    .catch((e) => { console.error(`[relay] 起不来：${e?.message}`); process.exit(1) })
}
