/// hub 常驻的 tmux 控制模式连接（刀 K1，docs/research-hub-tmux-control-mode.md §2 / §6.1）：
/// 命令一行一条写进 `tmux -C` 的 stdin，回包 %begin…%end|%error 按先进先出配对，不再每条命令 fork 一个 tmux。
/// 连不上 / 卡死 / 被关掉时 tmuxRun 回退 fork-async（forkRun），永不退回 execFileSync。

import type { FileSink, Subprocess } from "bun"
import { fetchTmuxPanes, ProcessTimeoutError, readText, runProcess, TMUX_PANES_CMD } from "./tmux-state"

export type TmuxControlState = "down" | "connecting" | "ready"
export type TmuxNotifyKind = "sessions-changed" | "session-renamed" | "exit" | "ready"

export interface TmuxControlOpts {
  /// 全局前缀：["-u"] + (socket ? ["-L", socket] : [])
  tmuxArgs: string[]
  ctlSession?: string
  /// 最老一条请求超过这么久没回 → 判卡死，杀掉控制进程、后台重连
  wedgeMs?: number
  backoffMinMs?: number
  backoffMaxMs?: number
}

/// tmux 回了 %error（或 fork 退出码非 0）：正文放进 .stderr，现有的 /can't find session/ 这类正则照用
export class TmuxCommandError extends Error {
  constructor(readonly stderr: string) { super(stderr || "tmux error") }
}

/// 结果不明的写后来怎么样了（K1 第 4b 步）：
/// replied = 回执晚到了（ok=false 是 tmux 明确答错，没执行成）；
/// abandoned = 发它的客户端已经没了（控制连接断开 / fork 客户端被杀）且进程已退出：已经送到 server 的那部分还可能被执行，
/// 要等 server 往返一次才算落定（waitTmuxWriteSettled）
export type WriteSettle = { kind: "replied"; ok: boolean; detail: string } | { kind: "abandoned" }

const ABANDONED: WriteSettle = { kind: "abandoned" }

/// 写命令已经发出去（写进控制连接的管道 / fork 客户端起了）却没拿到回执：超时、连接断。可能执行了，也可能没有。
/// 调用方不许当「确定没送进去」整条重发——server 恢复后管道里那条照样执行，就是两遍（审查 R1-2）。
/// `settled`：这条写后来的下落（见 WriteSettle），核对送达要先等它
export class TmuxUncertainError extends Error {
  /// 粘贴的 paste-buffer 结果不明时：那个临时缓冲区的名字（-d 贴完即删，落定后还在 = 没贴过；K1 第 4b 步 · 审查 R1）
  buffer?: string
  constructor(message: string, readonly settled: Promise<WriteSettle> = Promise.resolve(ABANDONED)) { super(message) }
}

/// 请求还没写进管道就被拒（连接没就绪 / 已判定卡住、不再接纳新请求）：确定没执行，换 fork 是安全的
class TmuxNotSentError extends Error {}

/// 控制模式按行喂给 tmux 的命令解析器：参数一律包双引号，\ " $ 转义，开头的 ~ 会展开成 HOME 也要转义，
/// 控制字符写成 \ooo（换行在引号里是 \012，不会断行）
export function quoteArg(s: string): string {
  let out = '"'
  for (const ch of s) {
    const c = ch.codePointAt(0)!
    if (ch === "\\" || ch === '"' || ch === "$" || ch === "~") out += "\\" + ch
    else if (c < 0x20 || c === 0x7f) out += "\\" + c.toString(8).padStart(3, "0")
    else out += ch
  }
  return out + '"'
}

/// 命令名不加引号，只许小写字母和 -（挡住换行 / 空串 / `;` 拼第二条命令）；NUL fork 也传不过去，一律拒
function commandLine(argv: string[]): string {
  if (argv.length === 0 || !/^[a-z][a-z-]*$/.test(argv[0])) throw new Error(`bad tmux command: ${JSON.stringify(argv[0] ?? "")}`)
  if (argv.some(a => a.includes("\0"))) throw new Error("tmux argument contains NUL")
  return [argv[0], ...argv.slice(1).map(quoteArg)].join(" ")
}

interface Pending {
  resolve: (out: string) => void
  reject: (e: Error) => void
  sentAt: number
  settled: boolean
  timer?: ReturnType<typeof setTimeout>
  write: boolean
  /// 这条请求能等多久才算卡死：写命令 = 自己的超时，读命令 = wedgeMs（见 armWedge）
  patience: number
  /// 写命令超时后：回执晚到 / 连接断开时报下落（TmuxUncertainError.settled）
  late?: (s: WriteSettle) => void
}

function settle(p: Pending, ok: boolean, lines: string[]): void {
  if (p.settled) {
    p.late?.({ kind: "replied", ok, detail: lines.join("\n") })
    p.late = undefined
    return
  }
  p.settled = true
  clearTimeout(p.timer)
  if (ok) p.resolve(lines.length ? lines.join("\n") + "\n" : "")   // 与 fork 的 stdout 逐字节相同
  else p.reject(new TmuxCommandError(lines.join("\n")))
}

interface Conn {
  proc: Subprocess<"pipe", "pipe", "pipe">
  stdout: ReadableStreamDefaultReader<Uint8Array>
  stderr: ReturnType<typeof readText>
  queue: Pending[]
  /// argv 里那条 new-session 的回复，单独消费一次（不进请求队列）
  init: Pending | null
  block: { tail: string; flags: string; lines: string[] } | null
  wedgeTimer?: ReturnType<typeof setTimeout>
}

export class TmuxControl {
  state: TmuxControlState = "down"
  private conn: Conn | null = null
  private closed = true
  private backoffMs: number
  private reconnectTimer?: ReturnType<typeof setTimeout>
  private lastFailure = ""
  private readonly listeners = new Map<TmuxNotifyKind, Set<() => void>>()
  private readonly ctlSession: string
  private readonly wedgeMs: number
  private readonly backoffMinMs: number
  private readonly backoffMaxMs: number

  constructor(private readonly opts: TmuxControlOpts) {
    this.ctlSession = opts.ctlSession ?? "_mp-hub-ctl"
    this.wedgeMs = opts.wedgeMs ?? 3_000
    this.backoffMinMs = opts.backoffMinMs ?? 1_000
    this.backoffMaxMs = opts.backoffMaxMs ?? 30_000
    this.backoffMs = this.backoffMinMs
  }

  start(): void {
    if (!this.closed) return
    this.closed = false
    this.connect()
  }

  onNotify(kind: TmuxNotifyKind, cb: () => void): void {
    let set = this.listeners.get(kind)
    if (!set) this.listeners.set(kind, set = new Set())
    set.add(cb)
  }

  run(argv: string[], timeoutMs: number, write = false): Promise<string> {
    const conn = this.conn
    if (this.state !== "ready" || !conn) return Promise.reject(new TmuxNotSentError(`tmux control ${this.state}`))
    // 最老一条已经超过 wedgeMs 没回：这次卡顿里不再接纳新请求（不往卡住的管道里塞），新请求走 fork；
    // 断开的截止点只从最老那条算，新请求续不了期（审查 R1-2）
    const head = conn.queue[0]
    if (head && Date.now() - head.sentAt > this.wedgeMs) return Promise.reject(new TmuxNotSentError("tmux control stalled"))
    let line: string
    try { line = commandLine(argv) } catch (e) { return Promise.reject(e) }
    return this.send(conn, line, timeoutMs, write)
  }

  close(): void {
    this.closed = true
    clearTimeout(this.reconnectTimer)
    const conn = this.conn
    if (!conn) { this.state = "down"; return }
    this.drop(conn, "closed")
  }

  private connect(): void {
    this.state = "connecting"
    const env: Record<string, string | undefined> = { ...process.env }
    delete env.TMUX
    delete env.TMUX_PANE
    let proc: Conn["proc"]
    try {
      // -N：server 不在就直接失败，不替她拉起一个只剩隐藏会话的 server；-A：有就接上、没有就建
      proc = Bun.spawn(["tmux", ...this.opts.tmuxArgs, "-N", "-C", "new-session", "-A", "-s", this.ctlSession, "-x", "20", "-y", "5", "cat"],
        { stdin: "pipe", stdout: "pipe", stderr: "pipe", env })
    } catch (e) {
      this.fail(`spawn: ${(e as Error).message}`)
      return
    }
    const conn: Conn = { proc, stdout: proc.stdout.getReader(), stderr: readText(proc.stderr), queue: [], init: null, block: null }
    this.conn = conn
    const attached = new Promise<string>((resolve, reject) => {
      const init: Pending = { resolve, reject, sentAt: Date.now(), settled: false, write: false, patience: this.wedgeMs }
      // 握手慢（server 停住 / 极忙）只记一行、接着等，不杀不重连：见 drop()。等的这段时间 tmuxRun 走 fork
      init.timer = setTimeout(() => console.warn(`[tmux-ctl] attach ${this.wedgeMs}ms 还没回，继续等`), this.wedgeMs)
      conn.init = init
    })
    void this.readLoop(conn)
    attached
      .then(() => this.send(conn, "refresh-client -f no-output,ignore-size", this.wedgeMs))
      .then(() => {
        if (this.conn !== conn) return
        this.state = "ready"
        this.backoffMs = this.backoffMinMs
        if (this.lastFailure) console.log(`[tmux-ctl] ready（${this.ctlSession}）`)
        this.lastFailure = ""
        this.emit("ready")
      })
      .catch((e: Error) => this.drop(conn, e.message))   // 已经断了的 drop 是空操作
  }

  private async readLoop(conn: Conn): Promise<void> {
    const dec = new TextDecoder()
    let buf = ""
    try {
      for (;;) {
        const { done, value } = await conn.stdout.read()
        if (done) break
        buf += dec.decode(value, { stream: true })
        let i: number
        while ((i = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, i)
          buf = buf.slice(i + 1)
          this.onLine(conn, line)
        }
      }
    } catch {}
    if (this.conn !== conn) return
    const err = await Promise.race([conn.stderr.text, new Promise<string>(r => setTimeout(() => r(""), 500))])
    this.drop(conn, err.trim() || "eof")
  }

  private onLine(conn: Conn, line: string): void {
    if (this.conn !== conn) return
    if (conn.block) {
      if (line !== "%end" + conn.block.tail && line !== "%error" + conn.block.tail) { conn.block.lines.push(line); return }
      const { flags, lines } = conn.block
      conn.block = null
      const ok = line.startsWith("%end")
      // flags=1 才是 stdin 发的命令；0 = argv 里的初始命令或 hook 产生的块（tmux cmd-queue.c）。
      // 初始命令总是第一个 0 块，之后的 0 块（hook）丢掉，不能消费请求队列，否则回包整体错位
      if (flags !== "1") {
        const init = conn.init
        conn.init = null
        if (init) settle(init, ok, lines)
        return
      }
      const p = conn.queue.shift()
      this.armWedge(conn)
      if (p) settle(p, ok, lines)
      return
    }
    if (line.startsWith("%begin ")) {
      const tail = line.slice("%begin".length)
      conn.block = { tail, flags: tail.slice(tail.lastIndexOf(" ") + 1), lines: [] }
      return
    }
    if (line === "%sessions-changed") this.emit("sessions-changed")
    else if (line.startsWith("%session-renamed ")) this.emit("session-renamed")
  }

  private enqueue(conn: Conn, timeoutMs: number, write: boolean): Promise<string> {
    return new Promise((resolve, reject) => {
      const p: Pending = { resolve, reject, sentAt: Date.now(), settled: false, write, patience: write ? timeoutMs : this.wedgeMs }
      // 超时只拒绝调用方；队列位置保留，晚到的回包照样按先进先出吃掉。写命令超时 = 结果不明
      p.timer = setTimeout(() => {
        if (p.settled) return
        p.settled = true
        const msg = `tmux control timeout ${timeoutMs}ms`
        if (!write) { reject(new Error(msg)); return }
        reject(new TmuxUncertainError(msg, new Promise<WriteSettle>((r) => { p.late = r })))
      }, timeoutMs)
      conn.queue.push(p)
      if (conn.queue.length === 1) this.armWedge(conn)
    })
  }

  private send(conn: Conn, line: string, timeoutMs: number, write = false): Promise<string> {
    const reply = this.enqueue(conn, timeoutMs, write)
    // write / flush 遇到背压时返回 Promise，管道断了（server 停住被判卡死、断开）它会以 EPIPE 拒绝：
    // 同步异常和异步失败都要接住、统一走断开清理，否则成了 unhandledRejection，hub 整个退出（审查 R1-1）
    const fail = (e: unknown) => this.drop(conn, `write: ${(e as Error)?.message ?? e}`)
    try {
      const sink: FileSink = conn.proc.stdin
      void Promise.resolve(sink.write(line + "\n")).catch(fail)
      void Promise.resolve(sink.flush()).catch(fail)
    } catch (e) {
      fail(e)
    }
    return reply
  }

  /// 卡死判定：截止点 = 最老那条没回的请求发出时刻 + 队里最长的耐心（读命令 wedgeMs，写命令自己的超时）。
  /// 只从最老那条算：最老那条超过 wedgeMs 后 run() 不再接纳新请求，所以一次卡顿的截止点最多是「第一条卡住的 + 写超时」，
  /// 后来的写续不了期（审查 R1-2）。有写在途时等到写超时再断：断开不证明管道里的写没执行，早断只会多出结果不明的写
  private wedgeDeadline(conn: Conn): number {
    let patience = 0
    for (const p of conn.queue) patience = Math.max(patience, p.patience)
    return conn.queue[0].sentAt + patience
  }

  private armWedge(conn: Conn): void {
    clearTimeout(conn.wedgeTimer)
    const head = conn.queue[0]
    if (!head) return
    conn.wedgeTimer = setTimeout(() => {
      if (conn.queue[0] !== head) return
      if (this.wedgeDeadline(conn) > Date.now()) { this.armWedge(conn); return }   // 头一条的 wedgeMs 内又进了写：截止点仍从头一条算
      this.drop(conn, `wedged（最老一条 ${Date.now() - head.sentAt}ms 没回）`)
    }, Math.max(0, this.wedgeDeadline(conn) - Date.now()))
  }

  private drop(conn: Conn, reason: string): void {
    if (this.conn !== conn) return
    this.conn = null
    clearTimeout(conn.wedgeTimer)
    // 完整清理：杀进程、关 stdin、取消两个管道的读（server 停住时等不到 EOF，不取消就漏 fd）。
    // 只杀已经 attach 上的：握手中（server 还没处理到）的控制客户端被杀，tmux 3.6a 恢复后给它发通知时
    // control_write 空指针 segfault，整个 server 连同她的会话一起没（审查 R1-2 返工实测 4/4）；握手中的只关 stdin，让它自己退
    if (!conn.init) { try { conn.proc.kill("SIGKILL") } catch {} }
    try { void Promise.resolve(conn.proc.stdin.end()).catch(() => {}) } catch {}
    void conn.stdout.cancel().catch(() => {})
    conn.stderr.cancel()
    // 已经写进管道的写：断开不证明它没执行（server 恢复后照样读到），按结果不明拒绝
    const msg = `tmux control down: ${reason}`
    // 下落：控制客户端进程退出之后才算「没了」（被杀之前它还可能往 server 递东西）
    const gone = conn.proc.exited.then(() => ABANDONED, () => ABANDONED)
    for (const p of [...(conn.init ? [conn.init] : []), ...conn.queue.splice(0)]) {
      if (p.settled) {
        const late = p.late
        p.late = undefined
        if (late) void gone.then(late)
        continue
      }
      p.settled = true
      clearTimeout(p.timer)
      p.reject(p.write ? new TmuxUncertainError(msg, gone) : new Error(msg))
    }
    conn.init = null
    const wasReady = this.state === "ready"
    this.state = "down"
    if (wasReady) this.emit("exit")
    if (this.closed) return
    this.fail(reason)
  }

  private fail(reason: string): void {
    this.state = "down"
    if (reason !== this.lastFailure) console.warn(`[tmux-ctl] down：${reason}，${this.backoffMs}ms 后重连（期间走 fork）`)
    this.lastFailure = reason
    clearTimeout(this.reconnectTimer)
    this.reconnectTimer = setTimeout(() => { if (!this.closed && !this.conn) this.connect() }, this.backoffMs)
    this.backoffMs = Math.min(this.backoffMaxMs, this.backoffMs * 2)
  }

  private emit(kind: TmuxNotifyKind): void {
    for (const cb of this.listeners.get(kind) ?? []) {
      try { cb() } catch (e) { console.warn(`[tmux-ctl] ${kind} 回调抛错：${(e as Error).message}`) }
    }
  }
}

export function k1Enabled(): boolean { return process.env.MP_HUB_PERF_K1 !== "0" }

export function tmuxSocketArgs(): string[] {
  const s = process.env.MP_CC_TMUX_SOCKET
  return s ? ["-L", s] : []
}

let shared: TmuxControl | null = null
/// 走了哪条路（/health 看，bench 对照用）
export const tmuxRunCounts = { ctl: 0, fork: 0 }

export function startSharedTmuxControl(opts: Partial<TmuxControlOpts> = {}): TmuxControl {
  shared?.close()
  shared = new TmuxControl({ tmuxArgs: ["-u", ...tmuxSocketArgs()], ...opts })
  shared.start()
  return shared
}

export function sharedTmuxControl(): TmuxControl | null { return shared }

export function stopSharedTmuxControl(): void {
  shared?.close()
  shared = null
}

function readyControl(): TmuxControl | null {
  return k1Enabled() && shared?.state === "ready" ? shared : null
}

/// fork 的 argv tmux 也要过一遍命令解析：以 ; 结尾的参数被当成命令分隔符（abc; → abc，; → 空，\; → ;）。
/// 末尾的 ; 写成 \; 才是字面量，这样两条通道收到的参数一致
function forkArg(a: string): string {
  return a.endsWith(";") ? a.slice(0, -1) + "\\;" : a
}

/// fork 一个 tmux 客户端（-u：launchd 起的 hub 没有 LANG，格式输出里的中文 / tab 会变 _）。退出码非 0 = tmux 明确答错；超时 / 起不来：读命令按答错抛（同原来），
/// 写命令按结果不明抛（客户端可能已经把命令交给 server 了）
async function forkRun(argv: string[], timeoutMs: number, write: boolean): Promise<string> {
  tmuxRunCounts.fork++
  let r: { out: string; err: string; code: number }
  try { r = await runProcess(["tmux", "-u", ...tmuxSocketArgs(), argv[0], ...argv.slice(1).map(forkArg)], timeoutMs) }
  catch (e) {
    if (!write) throw new TmuxCommandError((e as Error).message)
    // 超时被 SIGKILL：等它真退出才算「没了」；起都没起来（spawn 抛错）= 什么也没递给 server
    const gone = e instanceof ProcessTimeoutError ? e.exited.then(() => ABANDONED, () => ABANDONED) : Promise.resolve(ABANDONED)
    throw new TmuxUncertainError((e as Error).message, gone)
  }
  if (r.code !== 0) throw new TmuxCommandError(r.err.trim() || `tmux ${argv[0]} exit ${r.code}`)
  return r.out
}

async function runOnce(argv: string[], timeoutMs: number, write: boolean): Promise<string> {
  const ctl = readyControl()
  if (ctl) {
    tmuxRunCounts.ctl++
    try { return await ctl.run(argv, timeoutMs, write) }
    catch (e) {
      // tmux 明确答错 / 写命令结果不明 → 原样上抛（写不重试，R7）；没发出去（没就绪 / 卡住不接纳）或读命令失败 → 换 fork 一次
      if (e instanceof TmuxCommandError || e instanceof TmuxUncertainError) throw e
      if (write && !(e instanceof TmuxNotSentError)) throw new TmuxUncertainError((e as Error).message)
    }
  }
  return forkRun(argv, timeoutMs, write)
}

/// 控制连接上 set-buffer 的上限，再大走 fork load-buffer：1MB 的 set-buffer 要 ~650ms，堵住这条连接上后面所有命令（research R5）
export const CTL_SET_BUFFER_MAX_BYTES = 64 * 1024

/// 把文本放进 tmux 命名缓冲区（粘贴的前一半，后一半是 paste-buffer）。
/// 控制连接上 `load-buffer -` 静默无效（stdin 就是命令通道，R4）→ 改发 `set-buffer -b <名> -- <文本>`；
/// 超过 64KB（R5）、含 NUL（参数是 C 字符串，会被截断）、K1 关或连接没就绪 → fork `load-buffer -b <名> -`，文本走 stdin，与原来一致。
/// 只设缓冲区、不碰 pane，同名重设是幂等的：控制连接层失败（断 / 卡 / 超时）换 fork 再来一次；tmux 明确答错原样上抛
export async function tmuxLoadBuffer(name: string, text: string, timeoutMs: number): Promise<void> {
  const ctl = readyControl()
  if (ctl && !text.includes("\0") && Buffer.byteLength(text, "utf8") <= CTL_SET_BUFFER_MAX_BYTES) {
    tmuxRunCounts.ctl++
    try { await ctl.run(["set-buffer", "-b", name, "--", text], timeoutMs); return }
    catch (e) { if (e instanceof TmuxCommandError) throw e }
  }
  tmuxRunCounts.fork++
  let r: { err: string; code: number }
  try { r = await runProcess(["tmux", "-u", ...tmuxSocketArgs(), "load-buffer", "-b", name, "-"], timeoutMs, text) }
  catch (e) { throw new TmuxCommandError((e as Error).message) }
  if (r.code !== 0) throw new TmuxCommandError(r.err.trim() || `tmux load-buffer exit ${r.code}`)
}

const writeChains = new Map<string, Promise<unknown>>()

/// 同一会话的写按调用顺序执行（R8）。tmuxRun 的写命令和不走 tmuxRun 的整段写（pasteToTmux）共用这条链；
/// job 里不能再对同一会话 tmuxRun 写（会排在自己后面，死锁）
export function chainTmuxWrite<T>(session: string, job: () => T | Promise<T>): Promise<T> {
  const next = (writeChains.get(session) ?? Promise.resolve()).then(job)
  const tail = next.catch(() => {})
  writeChains.set(session, tail)
  void tail.then(() => { if (writeChains.get(session) === tail) writeChains.delete(session) })
  return next
}

/// hub 的 tmux 入口：K1 开且控制连接就绪 → 控制连接；否则 fork-async。
/// 写命令按会话串行（R8）：不管这一条走哪个通道，同一会话的写都按调用顺序执行
export function tmuxRun(argv: string[], opts: { timeoutMs: number; write: boolean; session?: string }): Promise<string> {
  try { commandLine(argv) } catch (e) { return Promise.reject(e) }
  const job = () => runOnce(argv, opts.timeoutMs, opts.write)
  const session = opts.session
  if (!opts.write || session === undefined) return job()
  return chainTmuxWrite(session, job)
}

/// TmuxState 的读源：控制连接就绪时 list-panes 走它，失败或没就绪回退 fetchTmuxPanes（没起 server 算空表）。
/// 不直接用 tmuxRun：它的 fork 回退在没起 server 时是抛错，这里要的是空表，而且会多 fork 一次
export async function fetchPanes(timeoutMs = 5_000): Promise<string | null> {
  const ctl = readyControl()
  if (ctl) {
    tmuxRunCounts.ctl++
    try { return await ctl.run(TMUX_PANES_CMD, timeoutMs) } catch { /* 回退 fork */ }
  }
  tmuxRunCounts.fork++
  return fetchTmuxPanes(timeoutMs, tmuxSocketArgs())
}

/// 结果不明的写落定之后是什么情况：executed = 回执晚到、确定执行过；not-executed = tmux 明确答错；
/// settled = 发它的客户端没了、server 也已经往返过（见 waitTmuxWriteSettled），这条要么执行过要么永远不会执行，看现场才知道；
/// timeout = 截止前没落定（server 一直卡着），什么都说不准
export type WriteFate = { kind: "executed" } | { kind: "not-executed"; detail: string } | { kind: "settled" } | { kind: "timeout" }

const TMUX_PROBE_TIMEOUT_MS = 3_000
/// 落定探针要连续成功几次：tmux 一轮事件循环（libevent kqueue）一次最多取 nevents 个就绪 fd，余下的挪到下一轮，多问一次留余量
export const SETTLE_PROBES = 2

/// 往返探针：新起一个 tmux 客户端问一句。server 答了（含答错）/ server 已经没了 = true；超时、连不上 = false
export async function probeTmuxServer(timeoutMs: number): Promise<boolean> {
  tmuxRunCounts.fork++
  try {
    const r = await runProcess(["tmux", "-u", ...tmuxSocketArgs(), "display-message", "-p", "ok"], timeoutMs)
    return r.code === 0 || !/error connecting|server exited/.test(r.err)
  } catch { return false }
}

/// 等一条结果不明的写确定落定（K1 第 4b 步）。tmux 3.6a 源码结论（perf/hub-实验日志.md「K1 第 4b 步」）：
/// - 回执晚到 = 执行过（同一客户端的命令按序执行、按序回）；
/// - 客户端没了（控制连接被杀、fork 客户端被杀）之后，它已经写进 socket / 管道的命令还可能被执行，但在 server 恢复后头一两轮事件循环里就见分晓；
///   新客户端要先 accept 再读命令，至少晚一轮，所以「客户端进程已退出 + 之后新客户端往返成功」= 旧的下落已定，不会再有迟到的写。
/// deadlineAt 前没落定 → timeout
export async function waitTmuxWriteSettled(err: TmuxUncertainError, deadlineAt: number, probe: (timeoutMs: number) => Promise<boolean> = probeTmuxServer): Promise<WriteFate> {
  const left = () => deadlineAt - Date.now()
  let timer: ReturnType<typeof setTimeout> | undefined
  const s = await Promise.race([err.settled, new Promise<null>((r) => { timer = setTimeout(() => r(null), Math.max(0, left())) })])
  clearTimeout(timer)
  if (!s) return { kind: "timeout" }
  if (s.kind === "replied") return s.ok ? { kind: "executed" } : { kind: "not-executed", detail: s.detail }
  for (let ok = 0; ok < SETTLE_PROBES;) {
    if (left() <= 0) return { kind: "timeout" }
    if (await probe(Math.min(TMUX_PROBE_TIMEOUT_MS, left()))) ok++
    else { ok = 0; await Bun.sleep(Math.min(500, Math.max(0, left()))) }
  }
  return { kind: "settled" }
}
