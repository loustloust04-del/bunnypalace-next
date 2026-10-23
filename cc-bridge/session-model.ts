// 会话实际在用的模型：聊天页底部胶囊「cc-模型名」（session_model 帧）+ 上下文窗口百分比按它算。
// 真实来源按时间比新旧：转录里最新一条回复的 message.model（claude）/ turn_context.model（codex）
// 比拉起 / app /model 确认的选择新就用转录的；否则用选择；都没有用打底（记录或 hub 默认）。
// 回复里的 model 不带 [1m]：跟选择是同一个模型时把选择的 [1m] 接回去（4.6 这类只有 [1m] 变体才 1M）。
import { open, readdir, stat, type FileHandle } from "node:fs/promises"
import { join } from "node:path"
import { DEFAULT_MODEL_MARK, entryText, eventTimeMs, standaloneModelArgs, validModelName } from "./cc-model"

/// 某个来源看到的模型和时间（毫秒；没有可信时间 = 0，谁都比它新）
export interface ModelSighting { model: string; atMs: number }

const FAMILIES = ["opus", "sonnet", "haiku", "fable"] as const
type Family = typeof FAMILIES[number]
export interface ClaudeModel { family: Family; major?: number; minor?: number; oneM: boolean }

/// claude-opus-4-6[1m] / claude-sonnet-4-5-20250929 / opus[1m] 这类认得出来；
/// 云厂商 id（us.anthropic.…-v1:0、…@20250805）、老命名（claude-3-5-sonnet-…）、best / default / opusplan 认不出 → null
const CLAUDE_ID_RE = /^(?:claude-)?(opus|sonnet|haiku|fable)(?:-(\d{1,2})(?:-(\d{1,2}))?)?(?:-\d{8})?$/
export function parseClaudeModel(model: string): ClaudeModel | null {
  const s = model.trim().toLowerCase()
  const oneM = /\[1m\]$/.test(s)
  const base = s.replace(/\[[^\]]*\]$/, "")
  const m = CLAUDE_ID_RE.exec(base)
  if (!m || (base.startsWith("claude-") && !m[2])) return null   // claude-opus 不是模型 id
  return { family: m[1] as Family, major: m[2] ? Number(m[2]) : undefined, minor: m[3] ? Number(m[3]) : undefined, oneM }
}

/// 胶囊上的短名：claude-opus-5-5 → opus-5.5，claude-opus-4-6[1m] → opus-4.6-1m，claude-sonnet-4-5-20250929 → sonnet-4.5，
/// opus[1m] → opus-1m，gpt-5.2-codex / best / 云厂商 id → 原样
export function shortModelName(model: string): string {
  const p = parseClaudeModel(model)
  if (!p) return model
  const version = p.major === undefined ? "" : `-${p.major}${p.minor === undefined ? "" : `.${p.minor}`}`
  return `${p.family}${version}${p.oneM ? "-1m" : ""}`
}

/// 天生就是 1M 窗口（不用 [1m] 后缀）的模型。来源 code.claude.com/docs/en/model-config（2026-10-11 查）原文：
/// 「Fable 5.1, Fable 5, Sonnet 5 and later, Haiku 5.5, and Opus 4.7 and later run with the 1M window by default」；
/// 「Opus 4.6 and Sonnet 4.6 reach 1M only through their `[1m]` variant」。Haiku 4.5 不支持 1M。
/// 不带版本的别名（opus / sonnet / haiku）随账号 / 配置解析成不同版本，不猜，只有 fable 全系都是 1M。
/// 没算 CLAUDE_CODE_DISABLE_1M_CONTEXT（开了会把这些也压回 200K）
export function nativeOneM(p: ClaudeModel): boolean {
  if (p.family === "fable") return true
  if (p.major === undefined) return false
  const v = p.major * 100 + (p.minor ?? 0)
  return p.family === "opus" ? v >= 407 : p.family === "sonnet" ? v >= 500 : v >= 505
}

/// 两个是不是同一个模型（不看 [1m]）：版本对得上；一边是不带版本的同族别名也算（opus[1m] 解析出来的就是某个 opus）
function sameClaudeModel(a: ClaudeModel, b: ClaudeModel): boolean {
  if (a.family !== b.family) return false
  if (a.major === undefined || b.major === undefined) return true
  return a.major === b.major && (a.minor ?? 0) === (b.minor ?? 0)
}

/// 回复里的 model（不带 [1m]）+ 当时的选择 → 带上选择的 [1m]（同一个模型才接）。其余原样
export function carryContextSuffix(actual: string, choice: string | undefined): string {
  if (!choice || /\[[^\]]*\]$/.test(actual) || !/\[1m\]$/i.test(choice)) return actual
  const a = parseClaudeModel(actual), c = parseClaudeModel(choice)
  return a && c && sameClaudeModel(a, c) ? `${actual}[1m]` : actual
}

function sighting(model: unknown, at: unknown): ModelSighting | null {
  if (!validModelName(model) || model.includes("<")) return null   // <synthetic> 之类不是模型
  const t = eventTimeMs(typeof at === "string" ? at : undefined)
  return { model, atMs: Number.isFinite(t) ? t : 0 }
}

export type TranscriptKind = "claude" | "codex"
/// 转录里一次 /model：arg = 命令参数原文（选单是空串），display = CLI 回的「Set model to …」里那个名字，
/// model = 能确定的模型（参数；选单 / 参数是 default 时从 display 推；推不出 undefined）
export interface SwitchEvent { atMs: number; arg: string; display?: string; model?: string }
/// 转录里跟模型有关的事实，按文件顺序喂行、只留最新的。
/// switch = 最后一次 CLI 接受了的 /model（后面跟着 Set model to 的输出）；rejected = 最后一次没接受的（后面的输出不是 Set model to）
export interface TranscriptFacts { reply?: ModelSighting; switch?: SwitchEvent; rejected?: SwitchEvent }

/// 「Set model to Opus 4.6 (1M context) and saved as your default …」里的名字。输出带 ANSI 粗体或反引号（obelisk 里查到的真实样子）
export function parseSetModelOutput(stdout: string): string | undefined {
  const plain = stdout.replace(/\u001b\[[0-9;]*m/g, "").replace(/`/g, "").trim()
  const m = /^Set model to (.+?)(?: and saved\b| with \S+ effort\b|$)/.exec(plain)
  return m?.[1].trim() || undefined
}

/// CLI 显示的名字 → 模型 id：「Opus 4.6 (1M context)」→ claude-opus-4-6[1m]，「Sonnet 5 (default)」→ claude-sonnet-5，
/// 「claude-fable-5[1m] (1M context)」→ 原样；天生 1M 的不加 [1m]。认不出 → undefined
export function modelFromDisplay(display: string): string | undefined {
  const oneM = /\(1M context\)/i.test(display)
  const base = display.replace(/\s*\([^)]*\)/g, "").trim()
  const withOneM = (id: string) => {
    const p = parseClaudeModel(id)
    return oneM && p && !p.oneM && !nativeOneM(p) ? `${id}[1m]` : id
  }
  if (/^claude-/i.test(base) && validModelName(base) && parseClaudeModel(base)) return withOneM(base)   // CLI 直接显示 id
  const m = /^(opus|sonnet|haiku|fable)(?:\s+(\d{1,2})(?:\.(\d{1,2}))?)?$/i.exec(base)
  if (!m) return undefined
  const fam = m[1].toLowerCase()
  return withOneM(m[2] ? `claude-${fam}-${m[2]}${m[3] ? `-${m[3]}` : ""}` : fam)
}

const MODEL_CMD_MARK = "<command-name>/model</command-name>"
const STDOUT_MARK = "<local-command-stdout>"

/// 按行喂（文件顺序）。claude：主线 assistant 的 message.model + /model 命令和它后面 CLI 的输出；codex：turn_context 的 payload.model（每轮开头一条）
export class FactsParser {
  facts: TranscriptFacts = {}
  /// 见过 /model 命令、还没见到它的输出
  private cmd?: { atMs: number; arg: string }
  constructor(readonly kind: TranscriptKind, private readonly defaultModel?: string) {}

  /// 要找的记录里一定有的字样：没有就不跑 JSON.parse（几 MB 的工具输出行）
  static markers(kind: TranscriptKind): string[] {
    return kind === "claude" ? [`"assistant"`, MODEL_CMD_MARK, STDOUT_MARK] : [`"turn_context"`]
  }
  static relevant(kind: TranscriptKind, line: string): boolean {
    return FactsParser.markers(kind).some((m) => line.includes(m))
  }

  consume(raw: string): void {
    const line = raw.trim()
    if (!line || line[0] !== "{" || !FactsParser.relevant(this.kind, line)) return
    let rec: { type?: string; isSidechain?: boolean; timestamp?: unknown; content?: unknown; message?: { model?: unknown; content?: unknown }; payload?: { model?: unknown } }
    try { rec = JSON.parse(line) } catch { return }
    if (this.kind === "codex") {
      if (rec?.type !== "turn_context") return
      const s = sighting(rec.payload?.model, rec.timestamp)
      if (s) this.facts.reply = s
      return
    }
    if (rec?.isSidechain) return
    if (rec?.type === "assistant") {
      const s = sighting(rec.message?.model, rec.timestamp)
      if (s) this.facts.reply = s
      return
    }
    if (rec?.type !== "user" && rec?.type !== "system") return
    const text = entryText(rec.message?.content) || (typeof rec.content === "string" ? rec.content : "")
    const t = eventTimeMs(typeof rec.timestamp === "string" ? rec.timestamp : undefined)
    const atMs = Number.isFinite(t) ? t : 0
    const args = standaloneModelArgs(text)
    if (args !== null) { this.cmd = { atMs, arg: args.trim() }; return }
    const out = /<local-command-stdout>([\s\S]*?)<\/local-command-stdout>/.exec(text)
    if (!out || !this.cmd) return
    const cmd = this.cmd
    this.cmd = undefined
    const display = parseSetModelOutput(out[1])
    if (!display) { this.facts.rejected = { atMs: cmd.atMs, arg: cmd.arg }; return }
    const explicit = cmd.arg && cmd.arg.toLowerCase() !== DEFAULT_MODEL_MARK && validModelName(cmd.arg) ? cmd.arg : undefined
    // /model default：沿用之前定的 (b)，按 hub 默认（cliModelFor）
    const model = explicit ?? (cmd.arg.toLowerCase() === DEFAULT_MODEL_MARK && this.defaultModel ? this.defaultModel : modelFromDisplay(display))
    this.facts.switch = { atMs: cmd.atMs, arg: cmd.arg, display, model }
  }

  /// 往回找到哪就够了（第一次定位用）：codex 要一条 turn_context；claude 要一条回复，再往回最多 SWITCH_LOOKBACK_BYTES 找最近一次 /model
  satisfied(scannedBytes: number): boolean {
    if (!this.facts.reply) return false
    return this.kind === "codex" || !!(this.facts.switch || this.facts.rejected) || scannedBytes >= SWITCH_LOOKBACK_BYTES
  }
}
/// 第一次定位时，找到回复之后为了找 /model 最多往回读这么多（多数会话从没切过，不能每个都读满 8MB）
export const SWITCH_LOOKBACK_BYTES = 2 << 20

function parseLines(kind: TranscriptKind, lines: string[]): TranscriptFacts {
  const p = new FactsParser(kind)
  for (const l of lines) p.consume(l)
  return p.facts
}
/// claude 转录尾部（按行）里最后一条主线回复的 message.model。没有 → null
export function lastClaudeReplyModel(lines: string[]): ModelSighting | null { return parseLines("claude", lines).reply ?? null }
/// codex rollout 尾部里最后一条 turn_context 的 payload.model。没有 → null
export function lastCodexTurnModel(lines: string[]): ModelSighting | null { return parseLines("codex", lines).reply ?? null }

const NL = 0x0a
export const SCAN_CHUNK_BYTES = 1 << 20
/// 第一次定位最多往回读这么多（找不到就当没有）
export const LOCATE_CAP_BYTES = 8 << 20

/// 一个转录文件的增量扫描（审查 R1-5）：
/// - size + mtime + inode 没变 → 不读（文件版本缓存）
/// - 变长了 → 从上次读到的最后一个完整行之后接着读新增的部分，分块喂，事实按文件顺序更新（轮首的 turn_context 被长输出挤出尾部也不丢）
/// - 第一次 / 被截短 / 换了文件 → 从尾部分块往回找，找到需要的记录或读满 LOCATE_CAP_BYTES 为止
export class TranscriptScan {
  private parser: FactsParser
  private size = -1
  private mtimeMs = -1
  private ino = -1
  private offset = 0
  constructor(readonly path: string, readonly kind: TranscriptKind, private readonly defaultModel?: string) { this.parser = new FactsParser(kind, defaultModel) }

  get facts(): TranscriptFacts { return this.parser.facts }

  /// 返回这次读了多少字节；文件没了 / 读不了抛出
  async update(): Promise<number> {
    const st = await stat(this.path)
    if (st.size === this.size && st.mtimeMs === this.mtimeMs && st.ino === this.ino) return 0
    const fh = await open(this.path, "r")
    try {
      const fresh = this.size < 0 || st.ino !== this.ino || st.size < this.offset
      const n = fresh ? await this.locate(fh, st.size) : await this.forward(fh, st.size)
      this.size = st.size
      this.mtimeMs = st.mtimeMs
      this.ino = st.ino
      return n
    } finally { await fh.close() }
  }

  private async forward(fh: FileHandle, size: number): Promise<number> {
    let pos = this.offset
    let carry: Buffer = Buffer.alloc(0)
    while (pos < size) {
      const len = Math.min(SCAN_CHUNK_BYTES, size - pos)
      const buf = Buffer.alloc(len)
      const { bytesRead } = await fh.read(buf, 0, len, pos)
      if (bytesRead <= 0) break
      pos += bytesRead
      const data = carry.length ? Buffer.concat([carry, buf.subarray(0, bytesRead)]) : buf.subarray(0, bytesRead)
      const cut = data.lastIndexOf(NL)
      if (cut < 0) { carry = data; continue }
      for (const l of data.subarray(0, cut).toString("utf8").split("\n")) this.parser.consume(l)
      carry = Buffer.from(data.subarray(cut + 1))
    }
    const read = pos - this.offset
    this.offset = pos - carry.length
    return read
  }

  private async locate(fh: FileHandle, size: number): Promise<number> {
    this.parser = new FactsParser(this.kind, this.defaultModel)
    const chunks: Buffer[] = []
    let start = size
    while (start > 0 && size - start < LOCATE_CAP_BYTES) {
      const len = Math.min(SCAN_CHUNK_BYTES, start)
      const buf = Buffer.alloc(len)
      const { bytesRead } = await fh.read(buf, 0, len, start - len)
      if (bytesRead < len) break
      start -= len
      chunks.unshift(buf)
      if (!FactsParser.markers(this.kind).some((m) => buf.includes(m))) continue   // 这一块里没有要找的记录，不用重解析
      const p = new FactsParser(this.kind)
      for (const l of this.completeLines(Buffer.concat(chunks), start)) p.consume(l)
      if (p.satisfied(size - start)) break
    }
    const data = Buffer.concat(chunks)
    for (const l of this.completeLines(data, start)) this.parser.consume(l)
    this.offset = start + data.lastIndexOf(NL) + 1   // 没有完整行（-1 + 1 = 0）就从 start 起，下次 forward 再读
    return size - start
  }

  /// 往回读的那段里完整的行：开头不在文件头就丢掉被切开的半行，结尾没换行的半行留给下次 forward
  private completeLines(data: Buffer, start: number): string[] {
    const head = start > 0 ? data.indexOf(NL) + 1 : 0
    const end = data.lastIndexOf(NL)
    if (head <= 0 && start > 0 || end < head) return []
    return data.subarray(head, end).toString("utf8").split("\n")
  }
}

/// 一次选择：model 可能不知道（终端里开选单选的、CLI 回的名字认不出），但它照样让更早的选择作废
export interface ChoiceEvent { model?: string; atMs: number; arg?: string }

/// 最新的那次选择（同一时刻取后面的）
export function latestChoice(cands: Array<ChoiceEvent | undefined>): ChoiceEvent | undefined {
  let best: ChoiceEvent | undefined
  for (const c of cands) if (c && (!best || c.atMs >= best.atMs)) best = c
  return best
}

/// 这个会话现在是哪个模型。choice = 最新的那次选择（拉起 / app / 转录里的 /model）。
/// 回复比它新（或没有选择）→ 回复的，[1m] 只从这次选择接（没有选择才从打底接；选择的模型不知道就不接）；
/// 否则选择的；选择的不知道就用回复 / 打底。都没有 → undefined
export function resolveSessionModel(seen: ModelSighting | null, choice: ChoiceEvent | undefined, fallback?: string): string | undefined {
  if (seen && (!choice || seen.atMs >= choice.atMs)) return carryContextSuffix(seen.model, choice ? choice.model : fallback)
  return choice?.model ?? seen?.model ?? fallback
}

/// modelId undefined = 不知道了（codex 换了新会话还没第一轮…）：model / model_id 发 null，app 清掉后缀
export function buildSessionModelFrame(sessionName: string, modelId: string | undefined): string {
  return JSON.stringify({ type: "session_model", session_name: sessionName, model: modelId ? shortModelName(modelId) : null, model_id: modelId ?? null })
}

// ── codex rollout 定位（审查 R1-8）──
// rollout 在 <root>/YYYY/MM/DD/rollout-<时间>-<uuid>.jsonl。原来每个 uuid 都从最新日期把整个历史目录走一遍，
// 冷启动几十个绑定 = 会话数 × 目录数。改成走一遍建 uuid → 路径的索引，过期（默认 60s）才重建，同时只建一份
const ROLLOUT_RE = /^rollout-.*-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/
export class CodexRolloutIndex {
  private map = new Map<string, string>()
  private builtAt = -Infinity
  private building?: Promise<void>
  /// 建过几次（单测看）
  builds = 0
  constructor(private readonly root: () => string, private readonly ttlMs = 60_000, private readonly now: () => number = Date.now) {}

  async lookup(uuid: string): Promise<string | undefined> {
    if (this.now() - this.builtAt > this.ttlMs) await this.rebuild()
    return this.map.get(uuid)
  }

  private rebuild(): Promise<void> {
    this.building ??= (async () => {
      const root = this.root()
      const next = new Map<string, string>()
      const list = async (dir: string) => { try { return await readdir(dir) } catch { return [] } }
      for (const y of await list(root)) for (const m of await list(join(root, y))) for (const d of await list(join(root, y, m))) {
        for (const f of await list(join(root, y, m, d))) {
          const id = ROLLOUT_RE.exec(f)?.[1]
          if (id) next.set(id, join(root, y, m, d, f))
        }
      }
      this.map = next
      this.builtAt = this.now()
      this.builds++
    })().finally(() => { this.building = undefined })
    return this.building
  }
}

// ── 每个会话的在用模型（hub 持有一份）──

/// hub 收到 app 的 /model 就落盘，转录里那条命令晚一点才写：比较时差这么多以内算同一次
export const RECORD_SLACK_MS = 5_000
/// app 的 /model 请求中最多等这么久（等不到 CLI 的输出也等不到回复）
export const PENDING_TTL_MS = 10 * 60_000

/// 同一个 /model 参数（default 大小写不论）
function sameArg(a: string | undefined, b: string | undefined): boolean {
  return a !== undefined && b !== undefined && a.trim().toLowerCase() === b.trim().toLowerCase()
}

/// 回复的模型跟请求的对不对得上：同族同版本（不看 [1m]）；一边是不带版本的别名，同族就算；认不出的比原文
export function sameModelLoose(a: string, b: string): boolean {
  const pa = parseClaudeModel(a), pb = parseClaudeModel(b)
  if (pa && pb) return sameClaudeModel(pa, pb)
  const strip = (x: string) => x.replace(/\[[^\]]*\]$/, "").toLowerCase()
  return strip(a) === strip(b)
}

export interface ModelBinding { id: string; kind: TranscriptKind }
export interface TrackerDeps {
  /// 会话现在绑的转录（claude session id / codex uuid）；没有绑定 → undefined
  binding(name: string): ModelBinding | undefined
  /// 绑定对应的转录文件；找不到 → undefined
  transcriptPath(b: ModelBinding): Promise<string | undefined>
  /// 打底 = 「没有任何选择」时（claude：hub 默认；codex 没有）
  fallback(name: string): string | undefined
  /// 落盘的选择（cc-models.json，带 updatedAt；arg = 记录原文）：hub 重启后内存里的选择没了靠它（审查 R1-2）
  record?(name: string): ChoiceEvent | undefined
  /// 算出来的变了：发 session_model（undefined = 不知道了，app 清掉后缀）
  publish(name: string, model: string | undefined): void
  now(): number
  /// /model default 按它算（之前定的 (b)：hub 默认）
  defaultModel?: string
  log?(line: string): void
}

/// app 发的 /model：写进终端了，CLI 还没表态（审查 R1-3）
interface PendingSwitch { arg: string; model: string; atMs: number }

interface SessionModelState {
  /// 拉起用的模型 / 确认过的 app /model（带时刻）
  choice?: ModelSighting
  /// app 的 /model 请求中：不发布，等转录里 CLI 的输出或下一条回复确认 / 撤销
  pending?: PendingSwitch
  /// 撤销了的那次（同一参数的落盘记录也跟着不算）
  revoked?: { arg: string; atMs: number }
  scan?: TranscriptScan
  known?: string
  /// 这些转录事实是哪个绑定的（claude session id / codex uuid）：换绑定（/clear、新会话）就清掉（审查 R1-9）
  bindingId?: string
  touchedAt: number
  inflight?: Promise<number>
  again?: boolean
}

/// 最多记这么多个会话；超了先清最久没碰过的（在算的不清）。闲置回收不算删除：绑定还在，状态照留
export const MAX_TRACKED_SESSIONS = 300
/// 这么久没碰过的会话清掉（下次用到从转录重算）
export const TRACKED_SESSION_TTL_MS = 7 * 24 * 3600_000

export class SessionModelTracker {
  private readonly states = new Map<string, SessionModelState>()
  constructor(private readonly deps: TrackerDeps) {}

  private state(name: string): SessionModelState {
    const now = this.deps.now()
    let s = this.states.get(name)
    if (!s) {
      this.evict(now)
      s = { touchedAt: now }
      this.states.set(name, s)
    }
    s.touchedAt = now
    return s
  }

  get size(): number { return this.states.size }

  private evict(now: number): void {
    for (const [n, st] of this.states) if (!st.inflight && now - st.touchedAt > TRACKED_SESSION_TTL_MS) this.states.delete(n)
    if (this.states.size < MAX_TRACKED_SESSIONS) return
    const idle = [...this.states].filter(([, st]) => !st.inflight).sort((a, b) => a[1].touchedAt - b[1].touchedAt)
    for (const [n] of idle.slice(0, this.states.size - MAX_TRACKED_SESSIONS + 1)) this.states.delete(n)
  }

  known(name: string): string | undefined { return this.states.get(name)?.known }

  /// 已知的全部（app 报到补发）：只发现在还有绑定、或这个进程里拉起过的会话，绑定换了还没重算的不发旧值
  snapshot(): Array<[string, string]> {
    return [...this.states].flatMap(([n, s]) => {
      if (!s.known) return []
      const b = this.deps.binding(n)
      const live = b ? b.id === s.bindingId : !!s.choice
      return live ? [[n, s.known] as [string, string]] : []
    })
  }

  /// 拉起 / app /model：记下选择并重算
  noteChoice(name: string, model: string): Promise<number> {
    const s = this.state(name)
    s.choice = { model, atMs: this.deps.now() }
    s.pending = undefined   // 拉起用的就是她最新的选择（记录里已经有了）
    return this.refresh(name)
  }

  /// app 发的 /model 写进终端了（审查 R1-3）：先记成请求中，不发布。确认：转录里这次命令后面是「Set model to」，
  /// 或下一条回复的模型对得上；撤销：CLI 回的是别的，或下一条回复对不上；PENDING_TTL_MS 没下文就丢掉
  notePending(name: string, arg: string, model: string): Promise<number> {
    this.state(name).pending = { arg, model, atMs: this.deps.now() }
    return this.refresh(name)
  }

  pendingOf(name: string): string | undefined { return this.states.get(name)?.pending?.model }

  private settlePending(s: SessionModelState, name: string): void {
    const p = s.pending
    if (!p) return
    const f = s.scan?.facts
    const near = (at: number) => at >= p.atMs - RECORD_SLACK_MS
    const done = (how: string, keep?: boolean) => {
      s.pending = undefined
      if (keep === false) s.revoked = { arg: p.arg, atMs: p.atMs }
      this.deps.log?.(`[hub] ${name} app /model ${p.arg} ${how}`)
    }
    if (f?.switch && near(f.switch.atMs) && sameArg(f.switch.arg, p.arg)) return done("CLI 接受了")   // 转录里的切换本身就是候选
    if (f?.rejected && near(f.rejected.atMs) && sameArg(f.rejected.arg, p.arg)) return done("CLI 没接受 → 撤销", false)
    if (f?.reply && f.reply.atMs > p.atMs) {
      if (sameModelLoose(f.reply.model, p.model)) { s.choice = { model: p.model, atMs: p.atMs }; return done(`下一条回复对上了（${f.reply.model}）`) }
      return done(`下一条回复是 ${f.reply.model}，对不上 → 撤销`, false)
    }
    if (this.deps.now() - p.atMs > PENDING_TTL_MS) done("一直没下文 → 丢掉", false)
  }

  /// 最新的一次选择：拉起 / app 的，和转录里 CLI 接受了的 /model 比时间（审查 R1-1：终端里后来去掉 [1m] 的不能被旧的 [1m] 盖掉）
  private effectiveChoice(s: SessionModelState, name: string): ChoiceEvent | undefined {
    return latestChoice([s.choice, this.liveRecord(s, name), s.scan?.facts.switch])
  }

  /// 落盘的选择算不算数：转录里在它之后（差 RECORD_SLACK_MS 以内也算）CLI 明确没接受同一个参数 → 不算
  private liveRecord(s: SessionModelState, name: string): ChoiceEvent | undefined {
    const r = this.deps.record?.(name)
    if (!r || !Number.isFinite(r.atMs)) return undefined
    const rej = s.scan?.facts.rejected
    if (rej && sameArg(rej.arg, r.arg) && rej.atMs >= r.atMs - RECORD_SLACK_MS) return undefined
    // hub 收到 /model 就落盘了：请求中 / 撤销了的那次不能借记录溜进来
    for (const x of [s.pending, s.revoked]) if (x && sameArg(x.arg, r.arg) && Math.abs(x.atMs - r.atMs) <= RECORD_SLACK_MS) return undefined
    return r
  }

  /// 接 [1m] 用的选择：最新的一次选择；没有选择用打底（ctx% 窗口也用它）
  suffixSource(name: string): string | undefined {
    const c = this.effectiveChoice(this.state(name), name)
    return c ? c.model : this.deps.fallback(name)
  }

  /// 挨个重算（串行），读盘总量到 budgetBytes 就停：剩下的等下次报到 / 那个会话一轮做完再算。返回算了几个
  async warm(names: string[], budgetBytes: number): Promise<number> {
    let spent = 0, done = 0
    for (const n of names) {
      if (spent >= budgetBytes) break
      spent += await this.refresh(n)
      done++
    }
    return done
  }

  /// 重算一个会话，变了就 publish。返回这次读了多少字节（预热算预算）。不抛。
  /// 在途合并：同一会话正在算时再要求算，并进这一次、算完再补算一遍（增量扫描不能并发读同一个文件）
  refresh(name: string): Promise<number> {
    const s = this.state(name)
    if (s.inflight) { s.again = true; return s.inflight }
    const run = async () => {
      let bytes = 0
      do { s.again = false; bytes += await this.refreshOnce(name, s) } while (s.again)
      return bytes
    }
    s.inflight = run().finally(() => { s.inflight = undefined })
    return s.inflight
  }

  private async refreshOnce(name: string, s: SessionModelState): Promise<number> {
    let bytes = 0
    const b = this.deps.binding(name)
    if (s.bindingId !== b?.id) { s.scan = undefined; s.bindingId = b?.id }   // 换绑定：旧转录的事实不作数（选择留着：/clear 不换模型）
    try {
      const path = b ? await this.deps.transcriptPath(b) : undefined
      if (!b || !path) s.scan = undefined
      else {
        if (s.scan?.path !== path) s.scan = new TranscriptScan(path, b.kind, this.deps.defaultModel)
        bytes = await s.scan.update()
      }
    } catch { s.scan = undefined }   // 转录还没写出来 / 读不了：按选择 / 打底
    // 读的期间绑定换了：这次的结果不作数，再算一遍
    if (this.deps.binding(name)?.id !== b?.id) { s.again = true; s.scan = undefined; return bytes }
    this.settlePending(s, name)
    const model = resolveSessionModel(s.scan?.facts.reply ?? null, this.effectiveChoice(s, name), this.deps.fallback(name))
    if (model !== s.known) {
      s.known = model
      this.deps.publish(name, model)
    }
    return bytes
  }
}
