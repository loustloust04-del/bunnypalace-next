// 军机处 M0 · 窗口普查 Indexer
// 只读扫描三个数据源，回答"每个窗口干了啥"：
//   1. CC transcript   ~/.claude/projects/<dir>/*.jsonl（append-only，增量 offset 续读）
//   2. Codex rollout   ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
//   3. 活进程          tmux list-panes × ps argv（--resume/--session-id 直接给 id）
// 设计原则：机械提取零 token；cwd 从 record 内容拿（目录名中文不可逆，见 research 笔记）；
// 大行（base64 图片等）跳过不解析。M0 纯只读——不注入、不指挥、不清理。
import { Database } from "bun:sqlite"
import { timedExecFileSync, timedSyncFs, timeSqlite } from "./block-ledger"
// K2：在 Worker 线程里跑（warroom-scan-worker.ts）时站点名换成 warroom-worker，送回主线程账本后和主线程的 warroom 调用分得开
const SITE = Bun.isMainThread ? "warroom" : "warroom-worker"
const { readdirSync, statSync, openSync, readSync, closeSync, existsSync } = timedSyncFs(`${SITE} `)
const execFileSync = timedExecFileSync(`${SITE} `)
import { join } from "node:path"

export const BIG_LINE_BYTES = 512 * 1024      // 超过则视为低信号大行（图片/巨粘贴），跳过
export const FIRST_MSG_CAP = 500
export const LIST_CAP = 200                    // files/cmds 数组上限
export const CMD_CAP = 200                     // 单条命令截断

// ── 累加器：一个 session 的普查画像 ──
export interface SessionAcc {
  sessionId: string | null
  engine: "claude" | "codex"
  cwd: string | null
  startedAt: string | null
  lastActiveAt: string | null
  turns: number
  firstUserMsg: string | null
  filesTouched: Set<string>
  cmdsRun: string[]
  tokensOut: number
  cacheRead: number
  cacheCreation: number
  gitBranch: string | null
  ccVersion: string | null
  originator: string | null
  seenReqIds: Set<string>   // assistant streaming 会写多行同 requestId 同 usage——去重
}

export function newAcc(engine: "claude" | "codex"): SessionAcc {
  return {
    sessionId: null, engine, cwd: null, startedAt: null, lastActiveAt: null,
    turns: 0, firstUserMsg: null, filesTouched: new Set(), cmdsRun: [],
    tokensOut: 0, cacheRead: 0, cacheCreation: 0,
    gitBranch: null, ccVersion: null, originator: null, seenReqIds: new Set(),
  }
}

function pushCapped(arr: string[], v: string, cap = LIST_CAP): void {
  if (arr.length < cap) arr.push(v)
}

function extractText(content: unknown): string {
  if (typeof content === "string") return content
  if (Array.isArray(content)) {
    return content
      .filter((p: any) => p && typeof p === "object" && p.type === "text" && typeof p.text === "string")
      .map((p: any) => p.text).join(" ")
  }
  return ""
}

// ── CC 单行解析。返回 false = 行不完整/坏 JSON（调用方停在上一完整行）──
export function parseCCLine(line: string, acc: SessionAcc): boolean {
  if (line.length === 0) return true
  if (line.length > BIG_LINE_BYTES) return true   // 大行跳过，仍算已消费
  let d: any
  try { d = JSON.parse(line) } catch { return false }
  if (!d || typeof d !== "object") return true

  if (typeof d.sessionId === "string" && !acc.sessionId) acc.sessionId = d.sessionId
  if (typeof d.cwd === "string" && !acc.cwd) acc.cwd = d.cwd
  if (typeof d.gitBranch === "string") acc.gitBranch = d.gitBranch
  if (typeof d.version === "string") acc.ccVersion = d.version
  if (typeof d.timestamp === "string") {
    if (!acc.startedAt) acc.startedAt = d.timestamp
    acc.lastActiveAt = d.timestamp
  }

  if (d.type === "user") {
    const msg = d.message
    // resume/compact 注入不是本人说话：isMeta、compact summary、tool_result 轮都跳过
    const content = msg?.content
    const isToolResult = Array.isArray(content) && content.some((p: any) => p?.type === "tool_result")
    if (!d.isMeta && !d.isCompactSummary && !isToolResult) {
      acc.turns++
      if (!acc.firstUserMsg) {
        const text = extractText(content).trim()
        if (text) acc.firstUserMsg = text.slice(0, FIRST_MSG_CAP)
      }
    }
  } else if (d.type === "assistant") {
    const msg = d.message
    const u = msg?.usage
    const rid = d.requestId
    if (u && rid && !acc.seenReqIds.has(rid)) {
      acc.seenReqIds.add(rid)
      acc.tokensOut += u.output_tokens ?? 0
      acc.cacheRead += u.cache_read_input_tokens ?? 0
      acc.cacheCreation += u.cache_creation_input_tokens ?? 0
    }
    const content = msg?.content
    if (Array.isArray(content)) {
      for (const block of content) {
        if (block?.type !== "tool_use") continue
        const name = block.name
        const input = block.input ?? {}
        if ((name === "Edit" || name === "Write" || name === "MultiEdit" || name === "NotebookEdit") && typeof input.file_path === "string") {
          if (acc.filesTouched.size < LIST_CAP) acc.filesTouched.add(input.file_path)
        } else if (name === "Bash" && typeof input.command === "string") {
          pushCapped(acc.cmdsRun, input.command.slice(0, CMD_CAP))
        }
      }
    }
  }
  return true
}

// ── Codex rollout 单行解析 ──
export function parseCodexLine(line: string, acc: SessionAcc): boolean {
  if (line.length === 0) return true
  if (line.length > BIG_LINE_BYTES) return true
  let d: any
  try { d = JSON.parse(line) } catch { return false }
  if (!d || typeof d !== "object") return true

  if (typeof d.timestamp === "string") {
    if (!acc.startedAt) acc.startedAt = d.timestamp
    acc.lastActiveAt = d.timestamp
  }
  const p = d.payload
  if (d.type === "session_meta" && p) {
    if (typeof p.id === "string") acc.sessionId = p.id
    if (typeof p.cwd === "string") acc.cwd = p.cwd
    if (typeof p.originator === "string") acc.originator = p.originator
    if (typeof p.cli_version === "string") acc.ccVersion = p.cli_version
  } else if (d.type === "response_item" && p) {
    if (p.type === "message" && p.role === "user") {
      acc.turns++
      if (!acc.firstUserMsg) {
        const text = extractText(p.content).trim()
        if (text) acc.firstUserMsg = text.slice(0, FIRST_MSG_CAP)
      }
    } else if (p.type === "function_call") {
      const args = typeof p.arguments === "string" ? p.arguments : JSON.stringify(p.arguments ?? "")
      pushCapped(acc.cmdsRun, `${p.name ?? "?"}:${args.slice(0, CMD_CAP)}`)
      // apply_patch/write 类调用里挖文件路径（粗提，够用）
      const m = args.match(/[/\w.-]+\.(ts|js|swift|py|md|json|tsx|rs|go|css|html)\b/g)
      if (m) for (const f of m.slice(0, 5)) { if (acc.filesTouched.size < LIST_CAP) acc.filesTouched.add(f) }
    }
  }
  return true
}

// ── 增量文件扫描：从 offset 续读，停在最后一个完整行 ──
export interface ScanState { size: number; mtimeMs: number; offset: number }

// 单次最多消费 1MB：正常负载下一片 ≈100ms 同步工作；8MB 时实测单片 1s+，机器过载放大后
// 撑不过 watchdog 的 5s /health（2026-09-01 螺旋事故）。56MB 大文件分 56 轮，靠 round 循环续。
export const SCAN_CHUNK_BYTES = 1024 * 1024

// 从 from 起找下一个 \n 的绝对位置；到 EOF 没有返回 -1
function findNewlineFrom(fd: number, from: number, size: number): number {
  const buf = Buffer.alloc(64 * 1024)
  for (let pos = from; pos < size; pos += buf.length) {
    const n = readSync(fd, buf, 0, Math.min(buf.length, size - pos), pos)
    if (n <= 0) return -1
    const i = buf.subarray(0, n).indexOf(0x0a)
    if (i !== -1) return pos + i
  }
  return -1
}

export function scanFileIncremental(
  path: string,
  prev: ScanState | null,
  acc: SessionAcc,
  parseLine: (line: string, acc: SessionAcc) => boolean,
  maxBytes = SCAN_CHUNK_BYTES,
): ScanState {
  const st = statSync(path)
  if (prev && prev.size === st.size && prev.mtimeMs === st.mtimeMs && prev.offset >= st.size) return prev   // 没动且读完，跳过
  const start = prev && prev.size <= st.size ? prev.offset : 0   // 缩小 = 文件被重写，从头
  const fd = openSync(path, "r")
  let consumed = start
  try {
    const len = Math.min(st.size - start, maxBytes)
    if (len <= 0) return { size: st.size, mtimeMs: st.mtimeMs, offset: start }
    const buf = Buffer.alloc(len)
    const n = readSync(fd, buf, 0, len, start)
    const text = buf.toString("utf8", 0, n)
    let lineStart = 0
    while (true) {
      const nl = text.indexOf("\n", lineStart)
      if (nl === -1) break                       // 尾部无 \n = 半行（正在写），不消费
      // 有 \n 的行就是完整行；parse 失败 = 坏行或 offset 曾落在行中间——跳过继续，不然永远卡在这
      parseLine(text.slice(lineStart, nl), acc)
      lineStart = nl + 1
      consumed = start + Buffer.byteLength(text.slice(0, lineStart), "utf8")
    }
    // 整片一个 \n 都没有且片是满的 = 单行比一片还长（>512KB 本来就当低信号跳过）→ 找到行尾直接跳过
    if (lineStart === 0 && n === maxBytes && start + n < st.size) {
      const nl = findNewlineFrom(fd, start + n, st.size)
      if (nl !== -1) consumed = nl + 1
    }
  } finally { closeSync(fd) }
  return { size: st.size, mtimeMs: st.mtimeMs, offset: consumed }
}

// ── 活进程匹配（纯函数，可测）──
export interface PaneInfo { tmuxSession: string; panePid: number; cwd: string }
export interface ProcInfo { pid: number; ppid: number; command: string }
export interface LiveMatch {
  pid: number
  engine: "claude" | "codex"
  sessionId: string | null        // argv 有 --resume/--session-id 就是 exact
  confidence: "exact" | "fuzzy"
  tmuxSession: string | null
  cwd: string | null              // fuzzy 匹配时从 pane 拿
}

const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i

export function matchLiveProcesses(panes: PaneInfo[], procs: ProcInfo[]): LiveMatch[] {
  const ppidMap = new Map<number, number>()
  for (const p of procs) ppidMap.set(p.pid, p.ppid)
  const paneByPid = new Map<number, PaneInfo>()
  for (const pane of panes) paneByPid.set(pane.panePid, pane)

  const findPane = (pid: number): PaneInfo | null => {
    // pane_pid 可能就是进程本身，也可能是它的 shell 祖先——向上走 4 级
    let cur: number | undefined = pid
    for (let i = 0; i < 4 && cur !== undefined; i++) {
      const pane = paneByPid.get(cur)
      if (pane) return pane
      cur = ppidMap.get(cur)
    }
    return null
  }

  const out: LiveMatch[] = []
  for (const proc of procs) {
    const cmd = proc.command
    // 只认真实的 claude/codex CLI 进程：第一个 token 的 basename 必须是 claude/codex
    //（排除 "grep claude"、"tmux new-session … claude …" 这类包装/引用行）
    const firstTok = cmd.trim().split(/\s+/)[0] ?? ""
    const base = firstTok.split("/").pop() ?? ""
    const isClaude = base === "claude"
    const isCodex = base === "codex"
    if (!isClaude && !isCodex) continue
    const engine = isClaude ? "claude" as const : "codex" as const
    let sessionId: string | null = null
    const flagMatch = cmd.match(/--(?:resume|session-id)[= ]+([0-9a-f-]{36})/i)
      ?? (isCodex ? cmd.match(new RegExp(`resume\\s+(${UUID_RE.source})`, "i")) : null)
    if (flagMatch) sessionId = flagMatch[1].toLowerCase()
    const pane = findPane(proc.pid)
    out.push({
      pid: proc.pid, engine, sessionId,
      confidence: sessionId ? "exact" : "fuzzy",
      tmuxSession: pane?.tmuxSession ?? null,
      cwd: pane?.cwd ?? null,
    })
  }
  return out
}

// 生产采集器（薄壳，测试不走这里）
// 分隔符必须是可打印序列，不能用 \t：launchd 环境无 LANG，tmux 判非 UTF-8 后
// 会把 format 输出里的控制字符 sanitize 成 "_"，三个字段黏死（2026-07-26 部署实测）。
const PANE_SEP = "|;|"
const PANES_CMD = ["tmux", "list-panes", "-a", "-F", `#{session_name}${PANE_SEP}#{pane_pid}${PANE_SEP}#{pane_current_path}`]
const PROCS_CMD = ["ps", "-axo", "pid=,ppid=,command="]

function parsePanes(outText: string): PaneInfo[] {
  return outText.trim().split("\n").filter(Boolean).map((l) => {
    const [tmuxSession, pid, cwd] = l.split(PANE_SEP)
    const panePid = Number(pid)
    return Number.isFinite(panePid) ? { tmuxSession, panePid, cwd: cwd ?? "" } : null
  }).filter((x): x is PaneInfo => x !== null)
}

function parseProcs(outText: string): ProcInfo[] {
  return outText.split("\n").filter(Boolean).map((l) => {
    const m = l.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/)
    return m ? { pid: Number(m[1]), ppid: Number(m[2]), command: m[3] } : null
  }).filter((x): x is ProcInfo => x !== null)
}

export function collectPanes(): PaneInfo[] {
  try { return parsePanes(execFileSync(PANES_CMD[0], PANES_CMD.slice(1)).toString()) } catch { return [] }
}

export function collectProcs(): ProcInfo[] {
  try { return parseProcs(execFileSync(PROCS_CMD[0], PROCS_CMD.slice(1)).toString()) } catch { return [] }
}

// 异步版给 hub 用：tmux server 忙（CC 流式长输出）时 execFileSync 会卡住整个事件循环
async function runCapture(cmd: string[]): Promise<string> {
  try {
    const p = Bun.spawn(cmd, { stdout: "pipe", stderr: "ignore" })
    const out = await new Response(p.stdout).text()
    await p.exited
    return out
  } catch { return "" }
}
export async function collectPanesAsync(): Promise<PaneInfo[]> { return parsePanes(await runCapture(PANES_CMD)) }
export async function collectProcsAsync(): Promise<ProcInfo[]> { return parseProcs(await runCapture(PROCS_CMD)) }

// ── Indexer 本体 ──
export interface IndexerOptions {
  dbPath: string
  ccProjectsRoot: string       // ~/.claude/projects
  codexSessionsRoot: string    // ~/.codex/sessions
  busyTimeoutMs?: number       // 默认 MAIN_BUSY_TIMEOUT_MS（主线程）；worker 传 WORKER_BUSY_TIMEOUT_MS
}

/// K2 审查 R1-1：主连接撞锁只同步忙等 20ms（sqlite 的退避实际 ~30ms，在 50ms 慢调用线以下）。
/// 理由：worker 一批常态 COMMIT 几 ms、负载 50+ 时见过 30ms 左右——大多数撞锁 20ms 内放开；等不到就抛 SQLITE_BUSY，
/// 由账本调用方 retryBusy 异步退避（warroom-ledger.ts），等待期间主循环不停。原来给 5s 是同步等，审查实测卡死主循环 5.2s
export const MAIN_BUSY_TIMEOUT_MS = 20
/// worker 连接等主线程的账本写：等多久都只卡 worker 线程
export const WORKER_BUSY_TIMEOUT_MS = 10_000
/// K2 worker 攒多少个文件的写进一个事务：事务里只有写（读盘 / 解析都在事务外），主线程的账本写撞上时最多等一个批次
export const WRITE_BATCH = 8

/// scanOne 的写库半段：一个文件的三条写
export interface ScanWrite { path: string; acc: SessionAcc; next: ScanState }
export type ScanOneResult = "unchanged" | "partial" | "done" | "stuck"
export type LivenessSource = () => Promise<LiveMatch[]>
/// wal_checkpoint 的结果：log = WAL 里的帧数，checkpointed = 已回写的帧数（相等 = 下一次写会从头复用 WAL）
export interface CheckpointResult { busy: number; log: number; checkpointed: number }
export const realLiveness: LivenessSource = async () => matchLiveProcesses(await collectPanesAsync(), await collectProcsAsync())

function journalMode(db: Database): string {
  return String((db.query("PRAGMA journal_mode").get() as { journal_mode?: unknown } | null)?.journal_mode ?? "").toLowerCase()
}

/// 开库重试的退避（最后一档一直用）：启动时旧 hub / sqlite3 CLI 还拿着读事务，几秒到几分钟就放开
export const OPEN_RETRY_DELAYS_MS = [2_000, 5_000, 15_000, 60_000, 300_000]

/// K2 审查 R1-5：开库（含切 WAL）失败别让 warroom 初始化永久跳过——第一次同步试（成功就和原来一样同步初始化），
/// 失败了（新连接已在构造里关掉）按退避异步重试，直到拿到能用的 indexer 才调 onOpen
export function openIndexerWithRetry(opts: IndexerOptions, onOpen: (idx: WarroomIndexer) => void, o: {
  delaysMs?: readonly number[]
  log?: (line: string) => void
  open?: (opts: IndexerOptions) => WarroomIndexer
} = {}): void {
  const delays = o.delaysMs ?? OPEN_RETRY_DELAYS_MS
  const log = o.log ?? ((l) => console.warn(l))
  const open = o.open ?? ((x) => new WarroomIndexer(x))
  const attempt = (i: number): void => {
    let idx: WarroomIndexer
    try { idx = open(opts) } catch (e) {
      const d = delays[Math.min(i, delays.length - 1)]
      log(`[warroom] 开库失败（第 ${i + 1} 次）：${(e as Error)?.message ?? e}，${Math.round(d / 1000)}s 后重试`)
      setTimeout(() => attempt(i + 1), d)
      return
    }
    onOpen(idx)
  }
  attempt(0)
}

export class WarroomIndexer {
  readonly db: Database
  private opts: IndexerOptions

  constructor(opts: IndexerOptions) {
    this.opts = opts
    this.db = timeSqlite(new Database(opts.dbPath, { create: true, strict: true }), SITE)
    // K2：主线程（读查询 + 奏折账本）和 scan worker 各一条连接写同一个库。WAL：读不等写、写不等读，
    // 只剩写写互斥；bun:sqlite 默认 busy_timeout=0（撞锁立刻抛 SQLITE_BUSY），主线程给很短的同步等待（见 MAIN_BUSY_TIMEOUT_MS）。
    // journal_mode 落在库文件里，开一次以后 K2=0 也是 WAL（只是更快，不影响语义）
    // K2 审查 R1-5：先看实际模式，已是 WAL 就不碰（切 WAL 要排他锁，撞上别的连接的活动读事务会 BUSY）；
    // 切不成 / 建表失败都关掉这条新连接再抛，由 openIndexerWithRetry 异步退避重开
    try {
      this.db.exec(`PRAGMA busy_timeout = ${opts.busyTimeoutMs ?? MAIN_BUSY_TIMEOUT_MS}`)
      if (journalMode(this.db) !== "wal") {
        this.db.exec("PRAGMA journal_mode = WAL")
        const mode = journalMode(this.db)
        if (mode !== "wal") throw new Error(`切 WAL 没成功（仍是 ${mode}）`)
      }
      this.createTables()
    } catch (e) {
      this.db.close()
      throw e
    }
  }

  private createTables(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        engine TEXT NOT NULL,
        cwd TEXT,
        transcript_path TEXT NOT NULL,
        tmux_session TEXT,
        pid INTEGER,
        alive INTEGER NOT NULL DEFAULT 0,
        alive_confidence TEXT NOT NULL DEFAULT 'none',
        started_at TEXT, last_active_at TEXT,
        turns INTEGER NOT NULL DEFAULT 0,
        first_user_msg TEXT,
        files_touched TEXT NOT NULL DEFAULT '[]',
        cmds_run TEXT NOT NULL DEFAULT '[]',
        tokens_out INTEGER NOT NULL DEFAULT 0,
        cache_read INTEGER NOT NULL DEFAULT 0,
        cache_creation INTEGER NOT NULL DEFAULT 0,
        git_branch TEXT, cc_version TEXT, originator TEXT,
        summary TEXT,
        indexed_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_sessions_cwd ON sessions(cwd);
      CREATE INDEX IF NOT EXISTS idx_sessions_last_active ON sessions(last_active_at);
      CREATE TABLE IF NOT EXISTS scan_state (
        path TEXT PRIMARY KEY,
        size INTEGER NOT NULL, mtime_ms REAL NOT NULL, offset INTEGER NOT NULL,
        session_id TEXT
      );
      CREATE TABLE IF NOT EXISTS acc_cache (
        path TEXT PRIMARY KEY,
        acc_json TEXT NOT NULL
      );
    `)
  }

  /** 序列化累加器（增量续读要接着上次的画像继续累） */
  private loadAcc(path: string, engine: "claude" | "codex"): SessionAcc {
    const row = this.db.query("SELECT acc_json FROM acc_cache WHERE path = ?").get(path) as { acc_json: string } | null
    if (!row) return newAcc(engine)
    try {
      const j = JSON.parse(row.acc_json)
      const acc = newAcc(engine)
      Object.assign(acc, j, {
        filesTouched: new Set(j.filesTouched ?? []),
        seenReqIds: new Set(j.seenReqIds ?? []),
      })
      return acc
    } catch { return newAcc(engine) }
  }

  private saveAcc(path: string, acc: SessionAcc): void {
    const j = { ...acc, filesTouched: [...acc.filesTouched], seenReqIds: [...acc.seenReqIds].slice(-2000) }
    this.db.query("INSERT INTO acc_cache(path, acc_json) VALUES (?, ?) ON CONFLICT(path) DO UPDATE SET acc_json = excluded.acc_json")
      .run(path, JSON.stringify(j))
  }

  private getScanState(path: string): ScanState | null {
    const row = this.db.query("SELECT size, mtime_ms, offset FROM scan_state WHERE path = ?").get(path) as any
    return row ? { size: row.size, mtimeMs: row.mtime_ms, offset: row.offset } : null
  }

  private saveScanState(path: string, s: ScanState, sessionId: string | null): void {
    this.db.query(`INSERT INTO scan_state(path, size, mtime_ms, offset, session_id) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(path) DO UPDATE SET size=excluded.size, mtime_ms=excluded.mtime_ms, offset=excluded.offset, session_id=excluded.session_id`)
      .run(path, s.size, s.mtimeMs, s.offset, sessionId)
  }

  private upsertSession(acc: SessionAcc, transcriptPath: string): void {
    if (!acc.sessionId) return   // 没解析出 id 的文件（空/纯坏行）不入库
    this.db.query(`INSERT INTO sessions(
        session_id, engine, cwd, transcript_path, started_at, last_active_at, turns,
        first_user_msg, files_touched, cmds_run, tokens_out, cache_read, cache_creation,
        git_branch, cc_version, originator, indexed_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(session_id) DO UPDATE SET
        cwd=excluded.cwd, transcript_path=excluded.transcript_path,
        started_at=excluded.started_at, last_active_at=excluded.last_active_at,
        turns=excluded.turns, first_user_msg=excluded.first_user_msg,
        files_touched=excluded.files_touched, cmds_run=excluded.cmds_run,
        tokens_out=excluded.tokens_out, cache_read=excluded.cache_read,
        cache_creation=excluded.cache_creation, git_branch=excluded.git_branch,
        cc_version=excluded.cc_version, originator=excluded.originator,
        indexed_at=excluded.indexed_at`)
      .run(
        acc.sessionId, acc.engine, acc.cwd, transcriptPath, acc.startedAt, acc.lastActiveAt, acc.turns,
        acc.firstUserMsg, JSON.stringify([...acc.filesTouched]), JSON.stringify(acc.cmdsRun),
        acc.tokensOut, acc.cacheRead, acc.cacheCreation,
        acc.gitBranch, acc.ccVersion, acc.originator, new Date().toISOString(),
      )
  }

  /** 扫一个 jsonl 文件（增量分片）。unchanged = 没动过；partial = 消费了一片还有剩（大文件）；
   *  done = 本轮消费到尾；stuck = 有剩但 offset 没前进（尾巴是正在写的半行）——本轮别再排它，
   *  不然 round 循环会把同一文件重扫 200 轮（2026-09-01 事故：每 5min 300MB 无用读取）。 */
  scanOne(path: string, engine: "claude" | "codex"): ScanOneResult {
    const { result, write } = this.readOne(path, engine)
    if (write) this.writeOne(write)
    return result
  }

  /** scanOne 的读盘半段：查上次进度 + stat + 读一片 + 解析，不写库（K2 worker 拿它攒批） */
  private readOne(path: string, engine: "claude" | "codex"): { result: ScanOneResult; write: ScanWrite | null } {
    const prev = this.getScanState(path)
    let st
    try { st = statSync(path) } catch { return { result: "unchanged", write: null } }
    if (prev && prev.size === st.size && prev.mtimeMs === st.mtimeMs && prev.offset >= st.size) return { result: "unchanged", write: null }
    const resume = !!prev && prev.size <= st.size
    const acc = resume ? this.loadAcc(path, engine) : newAcc(engine)
    const parse = engine === "claude" ? parseCCLine : parseCodexLine
    const next = scanFileIncremental(path, prev, acc, parse)
    if (next.offset <= (resume ? prev!.offset : 0) && next.offset < next.size) return { result: "stuck", write: null }
    // offset 落后 size 超一行残余 = 还有整片没读（半行残余不算 backlog）
    return { result: next.offset + 1024 < next.size ? "partial" : "done", write: { path, acc, next } }
  }

  private writeOne(w: ScanWrite): void {
    this.saveAcc(w.path, w.acc)
    this.saveScanState(w.path, w.next, w.acc.sessionId)
    this.upsertSession(w.acc, w.path)
  }

  /** 枚举全部待扫文件（不读内容，只走目录树） */
  listTargets(): Array<{ path: string; engine: "claude" | "codex" }> {
    const out: Array<{ path: string; engine: "claude" | "codex" }> = []
    if (existsSync(this.opts.ccProjectsRoot)) {
      for (const dir of readdirSync(this.opts.ccProjectsRoot)) {
        const dp = join(this.opts.ccProjectsRoot, dir)
        let entries: string[]
        try { entries = readdirSync(dp) } catch { continue }
        for (const f of entries) if (f.endsWith(".jsonl")) out.push({ path: join(dp, f), engine: "claude" })
      }
    }
    if (existsSync(this.opts.codexSessionsRoot)) {
      const walk = (d: string, depth: number): void => {
        let entries: string[]
        try { entries = readdirSync(d) } catch { return }
        for (const e of entries) {
          const p = join(d, e)
          let s
          try { s = statSync(p) } catch { continue }
          if (s.isDirectory() && depth < 3) walk(p, depth + 1)
          else if (e.endsWith(".jsonl")) out.push({ path: p, engine: "codex" })
        }
      }
      walk(this.opts.codexSessionsRoot, 0)
    }
    return out
  }

  /** listTargets 的让步版：每个项目目录 / codex 子目录之间让出事件循环 */
  async listTargetsAsync(yieldLoop: () => Promise<void>): Promise<Array<{ path: string; engine: "claude" | "codex" }>> {
    const out: Array<{ path: string; engine: "claude" | "codex" }> = []
    if (existsSync(this.opts.ccProjectsRoot)) {
      for (const dir of readdirSync(this.opts.ccProjectsRoot)) {
        const dp = join(this.opts.ccProjectsRoot, dir)
        let entries: string[]
        try { entries = readdirSync(dp) } catch { continue }
        for (const f of entries) if (f.endsWith(".jsonl")) out.push({ path: join(dp, f), engine: "claude" })
        await yieldLoop()
      }
    }
    if (existsSync(this.opts.codexSessionsRoot)) {
      const walk = async (d: string, depth: number): Promise<void> => {
        let entries: string[]
        try { entries = readdirSync(d) } catch { return }
        for (const e of entries) {
          const p = join(d, e)
          if (e.endsWith(".jsonl")) { out.push({ path: p, engine: "codex" }); continue }
          let s
          try { s = statSync(p) } catch { continue }
          if (s.isDirectory() && depth < 3) { await walk(p, depth + 1); await yieldLoop() }
        }
      }
      await walk(this.opts.codexSessionsRoot, 0)
    }
    return out
  }

  /** 全量走目录（首扫/增量共用；增量时未变文件 stat 后立即跳过）。
   *  ⚠️ 同步版仅供测试/CLI——hub 内必须用 scanAllAsync：934MB 首扫同步跑会把
   *  事件循环卡死 1min+，WS 心跳/消息注入全停（2026-07-26 部署实测翻车）。 */
  scanAll(): { scanned: number; changed: number } {
    let scanned = 0, changed = 0
    let pending = this.listTargets()
    for (let round = 0; round < 200 && pending.length; round++) {
      const next: typeof pending = []
      for (const t of pending) {
        if (round === 0) scanned++
        const r = this.scanOne(t.path, t.engine)
        if (r !== "unchanged" && r !== "stuck") changed++
        if (r === "partial") next.push(t)   // 大文件下一圈继续消费；stuck 不排（本轮再来也没进展）
      }
      pending = next
    }
    this.refreshLiveness()
    return { scanned, changed }
  }

  /** 异步分片版：文件间 + 大文件片间都让出事件循环。
   *  单片 >50ms 按耗时等比 sleep（上限 5s）：机器过载时扫描自动减速，hub 的 /health、WS 都能插进来。 */
  async scanAllAsync(liveness: LivenessSource = realLiveness): Promise<{ scanned: number; changed: number }> {
    // 10-10：swap 打满时单个 stat + sqlite 查一次就要几百 ms，8 个一让 = 主循环一卡好几秒（一轮扫 154s，
    // 期间手机连不上、终端不出字）→ 每个文件都让
    const CHUNK = 1
    let scanned = 0, changed = 0, sinceYield = 0
    const yieldLoop = () => new Promise<void>((r) => setImmediate(r))
    let pending = await this.listTargetsAsync(yieldLoop)
    for (let round = 0; round < 200 && pending.length; round++) {
      const next: typeof pending = []
      for (const t of pending) {
        if (round === 0) scanned++
        const t0 = Date.now()
        const r = this.scanOne(t.path, t.engine)
        if (r !== "unchanged" && r !== "stuck") changed++
        if (r === "partial") next.push(t)
        const dt = Date.now() - t0
        if (dt > 50) { sinceYield = 0; await Bun.sleep(Math.min(dt, 5000)) }
        else if (++sinceYield >= CHUNK) { sinceYield = 0; await yieldLoop() }
      }
      pending = next
      await yieldLoop()
    }
    this.refreshLiveness(await liveness())
    return { scanned, changed }
  }

  /** K2：Worker 线程里跑的版本（warroom-scan-worker.ts）。主线程不等它，所以不用让出事件循环；
   *  和 scanAllAsync 同样的轮次 / 分片 / 过载减速，结果一致。区别只在写库：stat / 读文件 / 解析都在事务外，
   *  每 WRITE_BATCH 个文件的写进一个短事务（原来每条写各自一个隐式事务）；活进程刷新整个进一个事务，
   *  主线程不会读到「全表刚清零、还没置位」的中间态。一轮结束前必须落盘：下一轮的 partial 文件要读本轮写的进度 */
  async scanAllBatched(liveness: LivenessSource = realLiveness): Promise<{ scanned: number; changed: number }> {
    let scanned = 0, changed = 0
    const batch: ScanWrite[] = []
    const writeBatch = this.db.transaction((ws: ScanWrite[]) => { for (const w of ws) this.writeOne(w) })
    const flush = () => { if (batch.length) writeBatch.immediate(batch.splice(0)) }
    let pending = this.listTargets()
    for (let round = 0; round < 200 && pending.length; round++) {
      const next: typeof pending = []
      for (const t of pending) {
        if (round === 0) scanned++
        const t0 = Date.now()
        const { result: r, write } = this.readOne(t.path, t.engine)
        if (write) batch.push(write)
        if (r !== "unchanged" && r !== "stuck") changed++
        if (r === "partial") next.push(t)
        if (batch.length >= WRITE_BATCH) flush()
        const dt = Date.now() - t0
        if (dt > 50) { flush(); await Bun.sleep(Math.min(dt, 5000)) }
      }
      flush()
      pending = next
    }
    const live = await liveness()
    this.db.transaction(() => this.refreshLiveness(live)).immediate()
    return { scanned, changed }
  }

  /** K2 审查 R1-3：把 WAL 回写进库文件（PASSIVE：不等读者 / 写者）。K2 开时主连接关了自动检查点，由 worker 每轮扫完调 */
  checkpoint(): CheckpointResult {
    const r = this.db.query("PRAGMA wal_checkpoint(PASSIVE)").get() as { busy: number; log: number; checkpointed: number } | null
    return { busy: r?.busy ?? 0, log: r?.log ?? 0, checkpointed: r?.checkpointed ?? 0 }
  }

  /** 活进程状态刷新：全表清零后按当前 ps/tmux 置位 */
  refreshLiveness(matches?: LiveMatch[]): void {
    const live = matches ?? matchLiveProcesses(collectPanes(), collectProcs())
    this.db.exec("UPDATE sessions SET alive = 0, alive_confidence = 'none', tmux_session = NULL, pid = NULL")
    const exactUpd = this.db.query("UPDATE sessions SET alive=1, alive_confidence='exact', tmux_session=?, pid=? WHERE session_id=?")
    const fuzzyUpd = this.db.query(`UPDATE sessions SET alive=1, alive_confidence='fuzzy', tmux_session=?, pid=?
      WHERE session_id = (SELECT session_id FROM sessions WHERE engine=? AND cwd=? ORDER BY last_active_at DESC LIMIT 1)`)
    for (const m of live) {
      if (m.sessionId) exactUpd.run(m.tmuxSession, m.pid, m.sessionId)
      else if (m.cwd) fuzzyUpd.run(m.tmuxSession, m.pid, m.engine, m.cwd)
    }
  }

  /** 查询（HTTP 端点用） */
  querySessions(q: { cwd?: string; alive?: string; engine?: string; limit?: number; zombies?: boolean }): unknown[] {
    const conds: string[] = []
    const params: unknown[] = []
    if (q.cwd) { conds.push("cwd LIKE ?"); params.push(`%${q.cwd}%`) }
    if (q.alive === "1" || q.alive === "0") { conds.push("alive = ?"); params.push(Number(q.alive)) }
    if (q.engine) { conds.push("engine = ?"); params.push(q.engine) }
    if (q.zombies) conds.push("alive = 1 AND tmux_session IS NULL")
    const where = conds.length ? `WHERE ${conds.join(" AND ")}` : ""
    const limit = Math.min(Math.max(q.limit ?? 100, 1), 1000)
    return this.db.query(`SELECT * FROM sessions ${where} ORDER BY last_active_at DESC LIMIT ${limit}`).all(...(params as any[]))
  }

  close(): void { this.db.close() }
}
