// #068 中继入口：hub 在 Unix socket 上多开一个监听，只给本机 relay-connector 用（docs/plan-remote-relay.md §4 S2）。
// 从这里进来的请求一律按「远程」处理（要口令、要 bundle），且只放 GET /health 和 WS /cc。
// 中继流量永远不走 127.0.0.1:PORT，所以 loopback 信任判断碰不到它。

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http"
import { chmodSync, lstatSync, mkdirSync, realpathSync, unlinkSync } from "node:fs"
import { connect, type Socket } from "node:net"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"

/// 经中继入口进来的请求对象（WS 的 connection 拿到的是同一个 req）
export const relayIngressRequests = new WeakSet<object>()

/// macOS 的 sockaddr_un.sun_path 是 104 字节（含结尾 0）
const MAX_SOCKET_PATH_BYTES = 103

export function relaySocketPath(port: number, env: NodeJS.ProcessEnv = process.env): string {
  return env.MP_CC_RELAY_SOCK || join(tmpdir(), "mp-cc-relay", `hub-${port}.sock`)
}

export function relayRequestAllowed(method: string | undefined, url: string | undefined, upgrade: boolean): boolean {
  const path = (url ?? "").split("?")[0]
  return method === "GET" && path === (upgrade ? "/cc" : "/health")
}

/// 一条路径上每一层都不能被别的用户改名替换：属于自己或 root，且别人不可写（除非带 sticky 位，如 /tmp）。
/// 字面路径（lstat，符号链接本身也要是自己 / root 的）和解析后的真实路径两条都查。
function chainSafe(dir: string): boolean {
  const me = process.getuid?.()
  const ok = (p: string, follow: boolean) => {
    const st = follow ? lstatSync(realpathSync(p)) : lstatSync(p)
    if (st.uid !== me && st.uid !== 0) return false
    if (st.isSymbolicLink()) return true
    return (st.mode & 0o022) === 0 || (st.mode & 0o1000) !== 0
  }
  const walk = (start: string, follow: boolean) => {
    for (let p = start; ; p = dirname(p)) {
      if (!ok(p, follow)) return false
      if (p === dirname(p)) return true
    }
  }
  try { return walk(resolve(dir), false) && walk(realpathSync(dir), true) } catch { return false }
}

function ensurePrivateDir(dir: string): string | null {
  if (!chainSafe(dirname(resolve(dir)))) return "上层目录可能被别人替换（不属于自己 / root，或别人可写）"
  try { mkdirSync(dir, { mode: 0o700 }) } catch (e: any) { if (e?.code !== "EEXIST") return `建不了目录（${e?.code}）` }
  const st = lstatSync(dir)
  if (st.isSymbolicLink() || !st.isDirectory()) return "目录位置是符号链接或不是目录"
  if (st.uid !== process.getuid?.()) return "目录不属于当前用户"
  if ((st.mode & 0o077) !== 0) chmodSync(dir, 0o700)
  return null
}

/// 只有「没人在听」的错误才算旧文件：ECONNREFUSED，或 ENOENT——Bun（node:net 和 Bun.connect 都是）把 Unix socket
/// 的 connect 错误一律报成 ENOENT，内核的 ECONNREFUSED / EACCES 分不出来（实测）。所以调用方先排除「自己没读写权限」
/// 这个会被误判的情况，再来这里探
function socketState(path: string): Promise<"alive" | "stale" | "unknown"> {
  return new Promise((done) => {
    const s = connect(path)
    s.once("connect", () => { s.destroy(); done("alive") })
    s.once("error", (e: any) => done(e?.code === "ECONNREFUSED" || e?.code === "ENOENT" ? "stale" : "unknown"))
  })
}

/// 检查目录 / 长度 / 旧文件。返回 null = 可以 listen；否则是拒绝原因（不带路径以外的敏感信息）。
/// 旧 socket 只在「是 socket + 属于自己 + 连不上」时删。
export async function prepareRelaySocket(path: string): Promise<string | null> {
  if (Buffer.byteLength(path) > MAX_SOCKET_PATH_BYTES) return `路径超过 ${MAX_SOCKET_PATH_BYTES} 字节`
  const dirErr = ensurePrivateDir(dirname(path))
  if (dirErr) return dirErr
  let st
  try { st = lstatSync(path) } catch (e: any) { return e?.code === "ENOENT" ? null : `读不了旧文件（${e?.code}）` }
  if (!st.isSocket() || st.uid !== process.getuid?.()) return "位置上已有不是自己的文件"
  if ((st.mode & 0o600) !== 0o600) return "判断不了旧 socket 有没有人在用（自己没读写权限）"
  const state = await socketState(path)
  if (state === "alive") return "已有别的 hub 在用这个 socket"
  if (state === "unknown") return "判断不了旧 socket 有没有人在用"
  // 探测期间被换掉就不删
  const again = lstatSync(path)
  if (again.ino !== st.ino || again.dev !== st.dev || !again.isSocket()) return "旧 socket 在检查期间变了"
  unlinkSync(path)
  return null
}

export function openRelayIngress(
  path: string,
  onRequest: (req: IncomingMessage, res: ServerResponse) => void,
  onUpgrade: (req: IncomingMessage, socket: Socket, head: Buffer) => void,
): Promise<Server> {
  const srv = createServer((req, res) => {
    relayIngressRequests.add(req)
    if (!relayRequestAllowed(req.method, req.url, false)) { res.writeHead(404); res.end("not found"); return }
    onRequest(req, res)
  })
  srv.on("upgrade", (req: IncomingMessage, socket: Socket, head: Buffer) => {
    relayIngressRequests.add(req)
    if (!relayRequestAllowed(req.method, req.url, true)) {
      socket.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")   // Bun 里 write + destroy 会丢掉这段
      return
    }
    onUpgrade(req, socket, head)
  })
  return new Promise((resolve, reject) => {
    const oldMask = process.umask(0o077)
    srv.once("error", (e) => { process.umask(oldMask); reject(e) })
    srv.listen(path, () => {
      process.umask(oldMask)
      chmodSync(path, 0o600)
      resolve(srv)
    })
  })
}
