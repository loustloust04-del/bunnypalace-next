/// tmux 会话表缓存（plan-hub-instant-connect）：hub 的 hasSession / list / paneTitles 原来每次都
/// execFileSync 一次 tmux，机器一忙单次 0.1–0.5s，broadcastTerminalState 一轮对 27 个会话逐个查
/// → 主循环冻几十秒，/health 和 WS 握手全卡（10-10 实测本机 /health 55s）。
/// 这里后台异步轮询 `tmux list-panes -a`，同步接口读快照；hub 自己 spawn/kill 立刻记账，
/// 等「之后开始的那次轮询」回来再以快照为准。快照过期（tmux 卡死 / 刚启动）返回 undefined，调用方回退同步查。

export interface TmuxStateOpts {
  /// 拿 `list-panes -a -F TMUX_PANES_ARGS` 原文；"" = 没有会话；null = 这次没拿到（不更新）
  fetch: () => Promise<string | null>
  now?: () => number
  staleMs?: number
}

export class TmuxState {
  private panes = new Map<string, PaneInfo>()
  private at = 0
  private inflight: Promise<void> | null = null
  /// hub 自己 spawn(true)/kill(false) 的会话 → 记账时刻；快照比它新才作废
  private overlay = new Map<string, { alive: boolean; at: number }>()
  private readonly fetchRaw: () => Promise<string | null>
  private readonly now: () => number
  private readonly staleMs: number

  constructor(opts: TmuxStateOpts) {
    this.fetchRaw = opts.fetch
    this.now = opts.now ?? Date.now
    this.staleMs = opts.staleMs ?? 10_000
  }

  private fresh(): boolean { return this.at > 0 && this.now() - this.at < this.staleMs }

  has(session: string): boolean | undefined {
    const o = this.overlay.get(session)
    if (o) return o.alive
    return this.fresh() ? this.panes.has(session) : undefined
  }

  /// 不管新旧，最后一次见到的（含 hub 自己记的账）；从没拿到过快照 → undefined
  lastKnown(session: string): boolean | undefined {
    const o = this.overlay.get(session)
    if (o) return o.alive
    return this.at > 0 ? this.panes.has(session) : undefined
  }

  /// `allowStale`：过期了也给最后一份（从没拿到过仍是 undefined）
  list(allowStale = false): string[] | undefined {
    if (!this.usable(allowStale)) return undefined
    const names = new Set(this.panes.keys())
    for (const [s, o] of this.overlay) o.alive ? names.add(s) : names.delete(s)
    return [...names]
  }

  paneTitles(sessionNames: Iterable<string>, allowStale = false): Map<string, string> | undefined {
    return this.pick(sessionNames, p => p.title, allowStale)
  }

  paneMeta(sessionNames: Iterable<string>, allowStale = false): Map<string, PaneMeta> | undefined {
    return this.pick(sessionNames, p => p.meta, allowStale)
  }

  private usable(allowStale: boolean): boolean { return this.fresh() || (allowStale && this.at > 0) }

  private pick<T>(sessionNames: Iterable<string>, get: (p: PaneInfo) => T | undefined, allowStale: boolean): Map<string, T> | undefined {
    if (!this.usable(allowStale)) return undefined
    const out = new Map<string, T>()
    for (const s of sessionNames) {
      const p = this.panes.get(s)
      const v = p && this.overlay.get(s)?.alive !== false ? get(p) : undefined
      if (v !== undefined) out.set(s, v)
    }
    return out
  }

  noteSpawned(session: string): void { this.overlay.set(session, { alive: true, at: this.now() }) }
  noteKilled(session: string): void { this.overlay.set(session, { alive: false, at: this.now() }) }

  /// 上一轮没回就复用它，不叠
  refresh(): Promise<void> {
    if (this.inflight) return this.inflight
    const startedAt = this.now()
    this.inflight = (async () => {
      try {
        const raw = await this.fetchRaw()
        if (raw === null) return
        this.panes = parsePanes(raw)
        this.at = this.now()
        for (const [s, o] of this.overlay) if (o.at < startedAt) this.overlay.delete(s)
      } catch { /* 留旧快照，过期后调用方自己回退 */ }
      finally { this.inflight = null }
    })()
    return this.inflight
  }
}

/// pane 当前目录 + 窗口最后一次有输出的时刻（秒）——shell 标题兜底（#046 T13）和 codex 粗判在干活（T22）用
export interface PaneMeta { activitySec: number; path: string }
interface PaneInfo { title: string; meta?: PaneMeta }

/// 一行 = 会话名 \t 标题 [\t 窗口活动秒 \t 当前目录]；标题里带 tab 也不错位（目录取最后一段）。
/// 同一会话多个 pane 取第一个（与原 paneTitles 一致）
export function parsePanes(raw: string): Map<string, PaneInfo> {
  const panes = new Map<string, PaneInfo>()
  for (const line of raw.split("\n")) {
    const split = line.indexOf("\t")
    if (split <= 0) continue
    const name = line.slice(0, split)
    if (panes.has(name)) continue
    const rest = line.slice(split + 1).split("\t")
    if (rest.length < 3) { panes.set(name, { title: rest.join("\t") }); continue }
    const path = rest.pop()!
    const activity = rest.pop()!
    panes.set(name, { title: rest.join("\t"), meta: { activitySec: Number(activity) || 0, path } })
  }
  return panes
}

export function parsePaneTitles(raw: string): Map<string, string> {
  return new Map([...parsePanes(raw)].map(([s, p]) => [s, p.title]))
}

export function parsePaneMeta(raw: string): Map<string, PaneMeta> {
  const out = new Map<string, PaneMeta>()
  for (const [s, p] of parsePanes(raw)) if (p.meta) out.set(s, p.meta)
  return out
}

// -u：launchd 起的 hub 没有 LANG，tmux 会把格式输出里的 tab / 中文全换成 _ → 会话表解析成空表，hub 以为一个会话都没有（10-10）
export const TMUX_PANES_CMD = ["list-panes", "-a", "-F", "#{session_name}\t#{pane_title}\t#{window_activity}\t#{pane_current_path}"]
export const TMUX_PANES_ARGS = ["-u", ...TMUX_PANES_CMD]

/// 读完一个管道；cancel() 立刻释放 reader 和 fd，不等 EOF
export function readText(stream: ReadableStream<Uint8Array>): { text: Promise<string>; cancel: () => void } {
  const reader = stream.getReader()
  const dec = new TextDecoder()
  const text = (async () => {
    let s = ""
    try {
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        s += dec.decode(value, { stream: true })
      }
    } catch { /* cancel 之后 */ }
    return s + dec.decode()
  })()
  return { text, cancel: () => void reader.cancel().catch(() => {}) }
}

/// runProcess 超时：子进程已 SIGKILL，exited 是它真退出的时刻（结果不明的写要等客户端真退出了再判落定，K1 第 4b 步）
export class ProcessTimeoutError extends Error {
  constructor(message: string, readonly exited: Promise<number>) { super(message) }
}

/// fork 一个子进程（tmux 客户端 / mkfifo）跑完拿输出；超时 SIGKILL、取消两个管道的读并立刻拒绝。不能等管道 EOF：server 停住时
/// 客户端交过去的 stdout fd 还卡在 socket 队列里，客户端死了管道也不关（SIGTERM 更是杀不掉）；
/// 不取消读，每次超时漏两个 fd，server 停多久漏多久（K1 测试 11b、审查 R1-2 实测）
/// `input`：写进 stdin 的内容（load-buffer -）；不给就不接 stdin
export function runProcess(argv: string[], timeoutMs: number, input?: string): Promise<{ out: string; err: string; code: number }> {
  const p = Bun.spawn(argv, { stdin: input === undefined ? "ignore" : new TextEncoder().encode(input), stdout: "pipe", stderr: "pipe" })
  const out = readText(p.stdout)
  const err = readText(p.stderr)
  let timer: ReturnType<typeof setTimeout> | undefined
  const timedOut = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      p.kill("SIGKILL")
      out.cancel()
      err.cancel()
      reject(new ProcessTimeoutError(`tmux timeout ${timeoutMs}ms`, p.exited))
    }, timeoutMs)
  })
  const done = Promise.all([out.text, err.text, p.exited]).then(([out, err, code]) => ({ out, err, code }))
  return Promise.race([done, timedOut]).finally(() => clearTimeout(timer))
}

/// 生产用：异步跑 tmux。没起 server（没有任何会话）算空表，其他失败返回 null。
export async function fetchTmuxPanes(timeoutMs = 5_000, socketArgs: string[] = []): Promise<string | null> {
  try {
    const { out, err, code } = await runProcess(["tmux", ...socketArgs, ...TMUX_PANES_ARGS], timeoutMs)
    if (code === 0) return out
    // 只有「没起 server」算空表；连不上（server 卡住 / 资源不够）算没拿到，不能当所有会话都没了
    return /no server running|error connecting.*No such file or directory/.test(err) ? "" : null
  } catch { return null }
}
