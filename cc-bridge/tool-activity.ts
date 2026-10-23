// 进度卡 B 补丁（粟粟 10-04「普通对话聊天，没调用工具那些的 ccrp，就不用开了」）：
// 这一轮 CC 真的用了工具才出状态卡。工具数从 claude 自己的 transcript 尾巴里数（hub 已经在读它算用量），
// 回话用的 cc-bridge 工具（reply / 骰子 / card_guide…）和 AskUserQuestion（走「等你」）不算干活。

export interface ToolActivity { count: number; last?: string }

export function isChatTool(name: string): boolean {
  return name.startsWith("mcp__cc-bridge__") || name === "AskUserQuestion"
}

/// lines：transcript 尾部按行；sinceUnix：这一轮开始（send 时刻）
export function toolActivitySince(lines: string[], sinceUnix: number): ToolActivity {
  let count = 0
  let last: string | undefined
  for (const raw of lines) {
    if (!raw.includes('"tool_use"')) continue          // 先粗筛，绝大多数行不用 parse
    let o: any
    try { o = JSON.parse(raw) } catch { continue }
    if (o?.type !== "assistant") continue
    const ts = Date.parse(o.timestamp ?? "") / 1000
    if (!(ts >= sinceUnix)) continue
    const content = o.message?.content
    if (!Array.isArray(content)) continue
    for (const c of content) {
      if (c?.type !== "tool_use" || typeof c.name !== "string" || isChatTool(c.name)) continue
      count++
      last = c.name
    }
  }
  return last ? { count, last } : { count }
}

export interface ToolActivityIO {
  /// transcript 的 mtimeMs；不存在 / 读不了 → undefined
  stat(path: string): Promise<number | undefined>
  readTail(path: string, maxBytes: number): Promise<string[]>
  now(): number
}

export const TOOL_ACTIVITY_TAIL_BYTES = 256 << 10
/// transcript 这么久没动的 working 当卡住的旧轮（不读）；它们隔 DORMANT_POLL_MS 才 stat 一次
export const TOOL_ACTIVITY_DORMANT_MS = 30 * 60_000
export const TOOL_ACTIVITY_DORMANT_POLL_MS = 60_000

/// 进度卡工具数（K3）：transcript 只异步 stat / 读尾巴，主线程不碰同步盘。
/// 同一会话的刷新串行；reset（新一轮）之后才落地的旧结果作废。
export class ToolActivityTracker {
  readonly bySession = new Map<string, ToolActivity>()
  private readonly readMtime = new Map<string, number>()
  private readonly seen = new Map<string, { at: number; mtimeMs: number }>()
  private readonly gen = new Map<string, number>()
  private readonly chains = new Map<string, Promise<boolean>>()
  constructor(private readonly io: ToolActivityIO) {}

  reset(session: string): void {
    this.bySession.delete(session)
    this.readMtime.delete(session)
    this.gen.set(session, (this.gen.get(session) ?? 0) + 1)
  }

  /// 定时轮询用：半小时没动过的隔一分钟才 stat 一次，没动过的不读
  poll(session: string, path: string, sinceUnix: number): Promise<boolean> {
    const s = this.seen.get(session)
    const now = this.io.now()
    if (s && now - s.mtimeMs > TOOL_ACTIVITY_DORMANT_MS && now - s.at < TOOL_ACTIVITY_DORMANT_POLL_MS) return Promise.resolve(false)
    return this.refresh(session, path, sinceUnix, TOOL_ACTIVITY_DORMANT_MS)
  }

  /// transcript 动过就重数；返回工具数 / 最后一个工具变没变
  refresh(session: string, path: string, sinceUnix: number, maxAgeMs?: number): Promise<boolean> {
    const g = this.gen.get(session) ?? 0
    // 整段兜住：这条链的 Promise 永不 reject（hub 的 unhandledRejection = 退出）；数失败不提交 mtime，下次重读
    const job = async (): Promise<boolean> => {
      try {
        const mtimeMs = await this.io.stat(path)
        if (mtimeMs === undefined) return false
        this.seen.set(session, { at: this.io.now(), mtimeMs })
        if (maxAgeMs !== undefined && this.io.now() - mtimeMs > maxAgeMs) return false
        if (this.readMtime.get(session) === mtimeMs) return false
        const next = toolActivitySince(await this.io.readTail(path, TOOL_ACTIVITY_TAIL_BYTES), sinceUnix)
        if ((this.gen.get(session) ?? 0) !== g) return false
        this.readMtime.set(session, mtimeMs)
        const prev = this.bySession.get(session)
        this.bySession.set(session, next)
        return prev?.count !== next.count || prev?.last !== next.last
      } catch { return false }
    }
    const p = (this.chains.get(session) ?? Promise.resolve(false)).then(job, job)
    this.chains.set(session, p)
    const clear = () => { if (this.chains.get(session) === p) this.chains.delete(session) }
    p.then(clear, clear)
    return p
  }
}
