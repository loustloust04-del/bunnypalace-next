// stream 传输：hub 当 claude 的父进程，走官方 `-p --input-format stream-json` stdio 协议。
// 消息 = 往 stdin 写一行 JSON（不经 pty，毫秒级，--replay-user-messages 回显当送达回执）；
// 权限/问问题 = stdout 的 control_request，宿主回 control_response。没有 TUI，没有弹窗。
// 契约实测见 docs/research-cc-dual-transport.md（2.1.258 五项全过）。
import type { Subprocess } from "bun"

export interface StreamSpawnOpts {
  cwd: string
  model: string
  mcpConfig: string | null   // null = 没有可用的 mcp-server（内嵌 hub 没给二进制）→ 不带 --mcp-config
  resumeId?: string      // 有 transcript → --resume
  sessionId?: string     // fresh → --session-id
  effort?: string        // 思考强度（effort.ts 校验过的档位）→ --effort
  bin?: string[]         // 测试注入假 claude；默认 ["claude"]
  env?: Record<string, string | undefined>
}

export interface ControlRequest {
  request_id: string
  subtype: string
  tool_name?: string
  input?: any
  tool_use_id?: string
  [k: string]: any
}
export interface ControlVerdict { behavior: "allow" | "deny"; updatedInput?: any; message?: string }
export type Respond = (v: ControlVerdict) => void

export interface StreamHooks {
  onReady?(name: string, sessionId: string): void
  onResult?(name: string, result: any): void
  onControlRequest?(name: string, req: ControlRequest, respond: Respond): void
  /// stderrTail：进程 stderr 最后一段（起不来时当报错证据用）
  onExit?(name: string, code: number | null, wasReady: boolean, stderrTail: string): void
  onEvent?(name: string, msg: any): void   // assistant / rate_limit_event 等，按需消费
  log?(line: string): void
}

interface PendingEcho { text: string; resolve: () => void; timer: ReturnType<typeof setTimeout> }
interface Proc {
  proc: Subprocess<"pipe", "pipe", "pipe">
  ready: boolean
  sessionId?: string
  echoes: PendingEcho[]
  seq: number
  silenced: boolean   // kill() 主动杀的：调用方自己记账，不再触发 onExit（否则 /clear 重生时旧进程的退出会误清新会话状态）
  inflight: number    // 已发 user 消息数 − 已收 result 数；>0 = 一轮在跑（含挂在权限卡上的）
  stderrTail: string  // stderr 最后 STDERR_TAIL_CHARS 个字
}

export const STDERR_TAIL_CHARS = 4096

export const ECHO_TIMEOUT_MS = 120_000   // 回显记账的清理期限（回显 = 模型开始回答，见 send）

export function buildStreamArgs(o: StreamSpawnOpts): string[] {
  const args = [
    ...(o.bin ?? ["claude"]),
    "-p", "--model", o.model, ...(o.mcpConfig ? ["--mcp-config", o.mcpConfig] : []),
    "--input-format", "stream-json", "--output-format", "stream-json",
    "--replay-user-messages", "--permission-prompt-tool", "stdio", "--verbose",
    "--include-partial-messages",   // 逐字流式：stream_event 里的 text_delta / thinking_delta（stream-turn.ts）
  ]
  if (o.resumeId) args.push("--resume", o.resumeId)
  else if (o.sessionId) args.push("--session-id", o.sessionId)
  if (o.effort) args.push("--effort", o.effort)
  return args
}

export class StreamRunner {
  private procs = new Map<string, Proc>()
  constructor(private hooks: StreamHooks = {}) {}

  private log(s: string) { (this.hooks.log ?? console.log)(s) }
  has(name: string): boolean { return this.procs.has(name) }
  list(): string[] { return [...this.procs.keys()] }
  isReady(name: string): boolean { return this.procs.get(name)?.ready ?? false }
  isBusy(name: string): boolean { return (this.procs.get(name)?.inflight ?? 0) > 0 }
  sessionIdOf(name: string): string | undefined { return this.procs.get(name)?.sessionId }
  stderrTail(name: string): string { return this.procs.get(name)?.stderrTail ?? "" }

  spawn(name: string, o: StreamSpawnOpts): void {
    if (this.procs.has(name)) throw new Error(`stream session ${name} already running`)
    const proc = Bun.spawn(buildStreamArgs(o), {
      cwd: o.cwd, stdin: "pipe", stdout: "pipe", stderr: "pipe",
      env: { ...process.env, ...(o.env ?? {}) },
    })
    const p: Proc = { proc, ready: false, echoes: [], seq: 0, silenced: false, inflight: 0, stderrTail: "" }
    this.procs.set(name, p)
    this.write(p, { type: "control_request", request_id: `init-${++p.seq}`, request: { subtype: "initialize" } })
    void this.pump(name, p)
    const stderrDone = this.pumpStderr(name, p)
    void proc.exited.then(async (code) => {
      const wasReady = p.ready
      if (this.procs.get(name) === p) this.procs.delete(name)
      for (const e of p.echoes) { clearTimeout(e.timer); e.resolve() }
      if (p.silenced) return
      await Promise.race([stderrDone, Bun.sleep(200)])   // 退出时 stderr 可能还没读完；孙进程占着管道也最多等 200ms
      this.hooks.onExit?.(name, code, wasReady, p.stderrTail)
    })
  }

  /// 往 stdin 写一条 user 消息；写入即 resolve（进程活着、管道通 = 送达）。
  /// 09-04 实测：--replay-user-messages 的回显是模型开始回答那一刻才回放（和首个 assistant 帧同时到，
  /// opus 长会话动辄 >10s），不是收件回执——拿它当回执会让 send 白等 10s 再 timeout。回显现在只用来记账。
  send(text: string, name: string): Promise<void> {
    const p = this.procs.get(name)
    if (!p) return Promise.reject(new Error(`stream session ${name} not running`))
    const echo: PendingEcho = {
      text, resolve: () => {},
      timer: setTimeout(() => { const i = p.echoes.indexOf(echo); if (i >= 0) p.echoes.splice(i, 1) }, ECHO_TIMEOUT_MS),
    }
    p.echoes.push(echo)
    p.inflight++
    this.write(p, { type: "user", message: { role: "user", content: text } })
    return Promise.resolve()
  }

  kill(name: string): void {
    const p = this.procs.get(name)
    if (!p) return
    p.silenced = true
    this.procs.delete(name)
    try { p.proc.stdin.end() } catch {}
    try { p.proc.kill() } catch {}
  }

  private write(p: Proc, o: unknown): void {
    try { p.proc.stdin.write(JSON.stringify(o) + "\n"); p.proc.stdin.flush() }
    catch (e: any) { this.log(`[stream] stdin write fail: ${e?.message}`) }
  }

  private async pumpStderr(name: string, p: Proc): Promise<void> {
    try {
      for await (const chunk of p.proc.stderr) {
        const raw = new TextDecoder().decode(chunk)
        p.stderrTail = (p.stderrTail + raw).slice(-STDERR_TAIL_CHARS)
        const s = raw.trim()
        if (s) this.log(`[stream] ${name} stderr: ${s.slice(0, 200)}`)
      }
    } catch {}
  }

  private async pump(name: string, p: Proc): Promise<void> {
    let buf = ""
    try {
      for await (const chunk of p.proc.stdout) {
        buf += new TextDecoder().decode(chunk)
        let i: number
        while ((i = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, i); buf = buf.slice(i + 1)
          if (line.trim()) this.handle(name, p, line)
        }
      }
    } catch (e: any) { this.log(`[stream] ${name} stdout pump fail: ${e?.message}`) }
  }

  private handle(name: string, p: Proc, line: string): void {
    let m: any
    try { m = JSON.parse(line) } catch { this.log(`[stream] ${name} bad json: ${line.slice(0, 80)}`); return }
    switch (m.type) {
      case "system":
        // init 是每轮开始才发（首条 user 消息之后），不能当就绪信号；只取 session_id
        if (m.subtype === "init" && typeof m.session_id === "string") p.sessionId = m.session_id
        return
      case "user": {
        // 回显：content 为字符串且与最早未确认的发送匹配 → 送达。tool_result 类 user 帧跳过。
        const c = m.message?.content
        if (typeof c !== "string" || p.echoes.length === 0) return
        const idx = p.echoes.findIndex((e) => e.text === c)
        if (idx >= 0) { const [e] = p.echoes.splice(idx, 1); clearTimeout(e.timer); e.resolve() }
        return
      }
      case "result":
        p.inflight = Math.max(0, p.inflight - 1)
        this.hooks.onResult?.(name, m)
        return
      case "control_request": {
        const req: ControlRequest = { request_id: m.request_id, ...(m.request ?? {}) }
        const respond: Respond = (v) => this.write(p, {
          type: "control_response",
          response: { subtype: "success", request_id: m.request_id, response: v },
        })
        if (this.hooks.onControlRequest) this.hooks.onControlRequest(name, req, respond)
        else respond({ behavior: "deny", message: "no permission handler" })
        return
      }
      case "control_response":
        // initialize 握手的应答 = CLI 已起来在读 stdin → 就绪（实测 1.4s，早于任何 user 消息）
        if (!p.ready && String(m.response?.request_id ?? "").startsWith("init-")) {
          p.ready = true
          this.hooks.onReady?.(name, p.sessionId ?? "")
        }
        return
      default:
        this.hooks.onEvent?.(name, m)
    }
  }
}
