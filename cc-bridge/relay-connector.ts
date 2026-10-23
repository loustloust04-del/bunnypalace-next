// #068 Mac 侧 relay-connector：主动往外连自建中继，保持几条已鉴权的空闲通道（spare）；
// 中继发 OPEN 就把这条通道接到 hub 的中继入口（Unix socket），之后两边原样搬字节。
// 只连 Unix socket，没有 TCP 回退（走 127.0.0.1:PORT 会被当成本机）。协议见 relay/relay.ts。
//
// hub 发现 secrets/relay.json 时拉起本进程（MP_CC_RELAY_SOCK / MP_CC_RELAY_CONFIG）。

import { createHash, X509Certificate } from "node:crypto"
import { connect as netConnect, type Socket } from "node:net"
import { connect as tlsConnect, type TLSSocket } from "node:tls"
import { isIP } from "node:net"
import { loadRelayConfig, type RelayConfig } from "./relay-config.ts"

export type ConnectorOptions = {
  config: RelayConfig
  sockPath: string
  spares?: number
  authMs?: number
  /// 空闲通道这么久没收到中继任何字节（中继每 20s PING）就当它死了
  idleDeadMs?: number
  backoffMinMs?: number
  backoffMaxMs?: number
  /// 空闲通道活过这么久才算「稳定」，之后掉线才清零退避（OK 了马上被断的照样指数退避）
  stableMs?: number
  log?: (line: string) => void
}

export type ConnectorHandle = { stop: () => void; stats: () => { idle: number; pipes: number } }

/// 证书叶子 SPKI 的 sha256（base64），和 app 端 / relay.json 的 pinSpkiSha256 同一定义
export function spkiSha256(cert: Buffer | X509Certificate): string {
  const x = cert instanceof X509Certificate ? cert : new X509Certificate(cert)
  return createHash("sha256").update(x.publicKey.export({ type: "spki", format: "der" })).digest("base64")
}

export function startConnector(opts: ConnectorOptions): ConnectorHandle {
  const cfg = opts.config
  const want = opts.spares ?? 3
  const authMs = opts.authMs ?? 5_000
  const idleDeadMs = opts.idleDeadMs ?? 60_000
  const minMs = opts.backoffMinMs ?? 1_000
  const maxMs = opts.backoffMaxMs ?? 30_000
  const stableMs = opts.stableMs ?? 30_000
  const log = (event: string) => (opts.log ?? console.log)(`[relay-connector] ${event}`)
  let stopped = false
  let idle = 0
  let pipes = 0
  const live = new Set<Socket>()
  const timers = new Set<ReturnType<typeof setTimeout>>()

  const later = (ms: number, fn: () => void) => {
    const t = setTimeout(() => { timers.delete(t); fn() }, ms)
    timers.add(t)
  }

  const dial = (): Socket => {
    if (!cfg.tls) return netConnect(cfg.port, cfg.host)
    const servername = isIP(cfg.host) ? undefined : cfg.host
    // 配了 pin：自签证书也接受，但握手后 SPKI 必须对上（对不上直接断，不回退）；没配：系统 CA 正常校验
    return tlsConnect({ host: cfg.host, port: cfg.port, servername, rejectUnauthorized: !cfg.pinSpkiSha256, minVersion: "TLSv1.2" })
  }

  /// 一个槽位：连上 → 鉴权 → 空闲等 OPEN；被 OPEN 用掉或断了就再连一条
  const slot = (failures: number) => {
    if (stopped) return
    const retry = () => {
      if (stopped) return
      const base = Math.min(maxMs, minMs * 2 ** failures)
      later(Math.round(base * (0.5 + Math.random() * 0.5)), () => slot(failures + 1))
    }
    const sock = dial()
    live.add(sock)
    let state: "CONNECTING" | "AUTH" | "IDLE" | "PIPE" | "DEAD" = "CONNECTING"
    let readyAt = 0
    let buf = ""
    let deadTimer: ReturnType<typeof setTimeout> | undefined
    const armDead = () => { clearTimeout(deadTimer); deadTimer = setTimeout(() => sock.destroy(), idleDeadMs) }
    const authTimer = setTimeout(() => sock.destroy(), authMs)

    const sendAuth = () => {
      state = "AUTH"
      sock.write(`MPRELAY/1 AUTH ${cfg.secret}\n`)
    }
    if (cfg.tls) {
      sock.once("secureConnect", () => {
        if (cfg.pinSpkiSha256) {
          // Bun 的 getPeerCertificate(false) 拿到的是空对象，用 getPeerX509Certificate
          let ok = false
          try {
            const peer = (sock as TLSSocket).getPeerX509Certificate()
            ok = !!peer && spkiSha256(peer) === cfg.pinSpkiSha256
          } catch {}
          if (!ok) { log("pin_mismatch"); sock.destroy(); return }
        }
        sendAuth()
      })
    } else {
      sock.once("connect", sendAuth)
    }

    const onData = (d: Buffer) => {
      buf += d.toString("latin1")
      if (state === "IDLE") armDead()
      let i: number
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i)
        buf = buf.slice(i + 1)
        if (state === "AUTH" && line === "OK") {
          clearTimeout(authTimer)
          state = "IDLE"
          idle++
          readyAt = Date.now()
          armDead()
          log("spare_ready")
        } else if (state === "IDLE" && line === "PING") {
          sock.write("PONG\n")
        } else if (state === "IDLE" && line === "OPEN") {
          openPipe(buf)
          return
        } else {
          sock.destroy()
          return
        }
      }
      if (buf.length > 64) sock.destroy()
    }

    const openPipe = (rest: string) => {
      state = "PIPE"
      idle--
      pipes++
      clearTimeout(deadTimer)
      sock.removeListener("data", onData)
      later(0, () => slot(0))   // 立刻补一条 spare
      const hub = netConnect(opts.sockPath)
      live.add(hub)
      hub.on("error", () => {})
      if (rest) hub.write(Buffer.from(rest, "latin1"))
      sock.pipe(hub)
      hub.pipe(sock)
      let closed = false
      const done = () => {
        if (closed) return
        closed = true
        pipes--
        live.delete(hub)
        setTimeout(() => { sock.destroy(); hub.destroy() }, 5_000).unref()
        log("pipe_closed")
      }
      hub.on("close", () => { sock.end(); done() })
      sock.on("close", () => { hub.end(); done() })
      log("pipe_open")
    }

    sock.on("data", onData)
    sock.on("error", (e: any) => { if (state !== "PIPE") log(`connect_error code=${e?.code ?? "-"}`) })
    sock.on("close", () => {
      clearTimeout(authTimer); clearTimeout(deadTimer)
      live.delete(sock)
      if (state === "PIPE") return
      if (state === "IDLE") {
        idle--
        log("spare_lost")
        if (Date.now() - readyAt >= stableMs) { later(Math.round(Math.random() * minMs), () => slot(0)); return }
        state = "DEAD"
        retry()
        return
      }
      if (state === "AUTH") log("auth_rejected")
      state = "DEAD"
      retry()
    })
  }

  for (let i = 0; i < want; i++) slot(0)
  return {
    stats: () => ({ idle, pipes }),
    stop: () => {
      stopped = true
      for (const t of timers) clearTimeout(t)
      for (const s of live) s.destroy()
    },
  }
}

/// 进程入口：源码模式 `bun run relay-connector.ts`；Mac App 内嵌的编译版 hub 用同一个二进制 `hub --relay-connector`
export function runConnectorMain(): void {
  const sockPath = process.env.MP_CC_RELAY_SOCK
  const cfgPath = process.env.MP_CC_RELAY_CONFIG
  if (!sockPath || !cfgPath) { console.error("[relay-connector] 需要 MP_CC_RELAY_SOCK 和 MP_CC_RELAY_CONFIG"); process.exit(1) }
  const cfg = loadRelayConfig(cfgPath)
  if (!cfg || typeof cfg === "string") { console.error(`[relay-connector] relay.json 不可用：${cfg ?? "不存在"}`); process.exit(1) }
  startConnector({ config: cfg, sockPath })
  // hub 退出时管道关闭 → 跟着退（hub 用 stdin pipe 拉起本进程）
  process.stdin.on("end", () => process.exit(0))
  process.stdin.on("close", () => process.exit(0))
  process.stdin.resume()
}

if (import.meta.main) runConnectorMain()
