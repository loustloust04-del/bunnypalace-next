// 文件夹模式（docs/plan-folder-floor.md P0）：同一份 hub 换配置起第二个实例，工作目录是电脑上的一个文件夹。
// 这里只放纯函数；hub.ts 里的接线都在 `folderMode` 判断后面，主 hub 不设 MP_HUB_MODE 就一行不走。
import { statSync } from "node:fs"
import { homedir } from "node:os"
import { isAbsolute, join } from "node:path"

export interface FolderMode { folder: string }

/// MP_HUB_MODE=folder + MP_HUB_FOLDER=<已存在目录的绝对路径>。没设 = null（主 hub）；设了但不合法 = 抛错，启动就死，不带病跑
export function parseFolderMode(env: Record<string, string | undefined> = process.env): FolderMode | null {
  if (env.MP_HUB_MODE !== "folder") return null
  const raw = env.MP_HUB_FOLDER ?? ""
  if (!isAbsolute(raw)) throw new Error(`MP_HUB_FOLDER 要写绝对路径（现在是「${raw}」）`)
  const folder = raw.length > 1 ? raw.replace(/\/+$/, "") : raw
  if (!statSync(folder, { throwIfNoEntry: false })?.isDirectory()) throw new Error(`MP_HUB_FOLDER 不是一个已存在的文件夹：${folder}`)
  return { folder }
}

// 只属于「家」（小克那台）的帧：语音、记忆同步、自主任务、群聊执行、军机处、交易、单词、共读、推特 / 口袋浏览器、
// Chrome 登录态、反馈、状态巡检、[+] 窗口的干活目录。文件夹模式下整帧拒，一个字节都不处理。
const REJECT_EXACT = new Set([
  "voice_note", "register_call_client", "set_voice_instructions", "set_garden_memory",
  "agora_complete", "ticker_research", "twitter_result", "pocket_result",
  "opencli_req", "set_opencli_enabled", "feedback", "set_agent_workdir",
  "set_transport_policy",   // 文件夹模式第一版只有带终端的传输
])
const REJECT_PREFIX = ["voice_call_", "cc_memory_", "agent_", "warroom_", "trading_", "vocab_", "reading_", "status_"]

export function folderRejectsFrame(type: string): boolean {
  return REJECT_EXACT.has(type) || REJECT_PREFIX.some((p) => type.startsWith(p))
}

// ── 账号 ──
// 一个账号 = Claude Code 的一套登录：配置目录（transcript 在它的 projects/ 下）+ 启动命令。
// 主 hub 没配就是一个默认账号（~/.claude + `claude`），行为和原来一样。

export interface Account { id: string; label: string; configDir: string; command: string }

export const DEFAULT_ACCOUNT_ID = "default"
export function defaultAccount(home: string = process.env.HOME ?? homedir()): Account {
  return { id: DEFAULT_ACCOUNT_ID, label: "默认", configDir: join(home, ".claude"), command: "claude" }
}

const ACCOUNT_ID_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/
/// 启动命令只收路径 / 命令名（不带空格和 shell 元字符）：它会被拼进 tmux 起会话的命令行
const ACCOUNT_COMMAND_RE = /^[A-Za-z0-9_./~-]{1,300}$/

function expandHome(p: string, home: string): string {
  return p === "~" ? home : p.startsWith("~/") ? join(home, p.slice(2)) : p
}

/// hub-config.json 的 `accounts`：[{id, label?, config_dir, command}]。默认账号永远排第一个；
/// 写了同名 "default" 的条目 = 覆盖默认账号。坏条目丢掉并在 problems 里说明（启动日志打出来）。
export function parseAccounts(raw: unknown, home: string = process.env.HOME ?? homedir()): { accounts: Account[]; problems: string[] } {
  const problems: string[] = []
  const byId = new Map<string, Account>([[DEFAULT_ACCOUNT_ID, defaultAccount(home)]])
  if (raw !== undefined && !Array.isArray(raw)) problems.push("accounts 不是数组，忽略")
  for (const item of Array.isArray(raw) ? raw : []) {
    const id = typeof item?.id === "string" ? item.id : ""
    if (!ACCOUNT_ID_RE.test(id)) { problems.push(`账号 id 不合法：${JSON.stringify(item?.id)}`); continue }
    const configDir = typeof item.config_dir === "string" ? expandHome(item.config_dir, home) : ""
    if (!isAbsolute(configDir)) { problems.push(`账号 ${id} 的 config_dir 要是绝对路径或 ~/ 开头`); continue }
    const command = typeof item.command === "string" ? expandHome(item.command, home) : ""
    if (!ACCOUNT_COMMAND_RE.test(command)) { problems.push(`账号 ${id} 的 command 只能是命令名或路径`); continue }
    const label = typeof item.label === "string" && item.label.trim() ? item.label.trim().slice(0, 40) : id
    byId.set(id, { id, label, configDir: configDir.replace(/\/+$/, ""), command })
  }
  return { accounts: [...byId.values()], problems }
}

// ── 文件夹模式起 claude ──
// 「家」那套命令是陪伴配置（禁掉进工位 / 跨会话消息等工具、只认 hub 的 MCP、写死模型）；文件夹里的 CC 要正常干活，
// 所以：不禁工具、不 --strict-mcp-config、不传模型（除非她在这条会话里选过），hook 用 --settings 给（不往文件夹里写）。

/// --settings 那份：只有回话（Stop）和问题卡（AskUserQuestion 前后）三个 hook，和文件夹自己的配置叠加
export function buildFolderSettings(hookDir: string): Record<string, unknown> {
  const run = (script: string) => ({ type: "command", command: `python3 '${join(hookDir, script)}'` })
  const ask = { matcher: "AskUserQuestion", hooks: [run("askuser-hook.py")] }
  return {
    showThinkingSummaries: true,
    hooks: { Stop: [{ hooks: [run("thinking-hook.py")] }], PreToolUse: [ask], PostToolUse: [ask] },
  }
}

export interface FolderLaunch {
  command: string            // 账号的启动命令（claude / claude-xiao 的路径）
  mcpConfig: string | null
  settingsPath: string
  /// 她在这条会话里选过模型才有；没有就不传 --model，用账号自己的默认
  model?: string
  session: { fresh: string } | { resume: string }
}

const sq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`

export function buildFolderLaunchCommand(l: FolderLaunch): string {
  const parts = [l.command]
  if (l.model) parts.push("--model", sq(l.model))
  if (l.mcpConfig) parts.push("--mcp-config", sq(l.mcpConfig))
  parts.push("--settings", sq(l.settingsPath))
  parts.push(..."fresh" in l.session ? ["--session-id", l.session.fresh] : ["--resume", l.session.resume])
  return parts.join(" ")
}

/// 文件夹没在 Claude Code 里信任过时，claude 一起来就停在「信任这个文件夹吗」上（默认选中「No, exit」）。
/// hub 不替人点信任——那是她的决定；认出来就收掉会话、把原因回给手机（11-16 探针实测的屏幕文字）
const TRUST_PROMPT_MARKERS = ["Yes, I trust this folder", "Is this a project you created or one you trust"]
export function isFolderTrustPrompt(pane: string): boolean {
  return TRUST_PROMPT_MARKERS.some((m) => pane.includes(m))
}
export const FOLDER_UNTRUSTED_MESSAGE = "这个文件夹还没在 Claude Code 里点过信任：在电脑上进这个文件夹跑一次 claude、选信任，再回来发"

// ── 账号的启动检查 ──
// 自带启动器的账号（先查出口再起 claude 的包装脚本这类）：检查不过时进程秒退，tmux 里的屏幕来不及截，真实原因拿不到。
// 所以起会话前先跑一遍 `<命令> --version`：包装脚本会先做它自己的检查，不过就把它 stderr 的最后一行带回去。

export interface PreflightRun { code: number | null; stderr: string; timedOut: boolean }
export const PREFLIGHT_TIMEOUT_MS = 15_000

async function runPreflight(command: string, timeoutMs: number): Promise<PreflightRun> {
  const proc = Bun.spawn([command, "--version"], { stdin: "ignore", stdout: "ignore", stderr: "pipe" })
  let timedOut = false
  const timer = setTimeout(() => { timedOut = true; proc.kill() }, timeoutMs)
  try {
    const [code, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()])
    return { code, stderr, timedOut }
  } finally { clearTimeout(timer) }
}

/// null = 过了；否则是给人看的原因（一行）
export async function accountPreflight(
  a: Account,
  run: (command: string, timeoutMs: number) => Promise<PreflightRun> = runPreflight,
): Promise<string | null> {
  let r: PreflightRun
  try { r = await run(a.command, PREFLIGHT_TIMEOUT_MS) } catch (e) {
    return `启动命令跑不起来（${a.command}）：${(e as Error).message.split("\n")[0].slice(0, 160)}`
  }
  if (r.timedOut) return `启动检查 ${PREFLIGHT_TIMEOUT_MS / 1000} 秒没结束（${a.command}）`
  if (r.code === 0) return null
  const last = r.stderr.split(/\r?\n/).map((l) => l.trim()).filter(Boolean).pop()
  return (last ?? `启动命令退出码 ${r.code}（${a.command}）`).slice(0, 240)
}

// ── 会话 ↔ 账号 ──
// 一条会话第一次起的时候定账号，之后不改（后来带别的账号来也照原来的）：它的 transcript 在那个账号的配置目录里，换了就续不上。
// 存 secrets/session-accounts.json（会话名 → 账号 id），只记非默认的；绑定被清掉重起时账号还在。

export class SessionAccounts {
  private readonly map = new Map<string, string>()
  /// 已经起过（或定过账号）的会话：之后帧里再带别的账号一律拒
  private readonly settled = new Set<string>()

  constructor(
    private readonly accounts: Account[],
    private readonly store?: { read(): string | undefined; write(text: string): void },
  ) {
    try {
      const obj = JSON.parse(store?.read() ?? "{}")
      for (const [k, v] of Object.entries(obj ?? {})) if (typeof v === "string") { this.map.set(k, v); this.settled.add(k) }
    } catch { /* 坏文件当空的 */ }
  }

  get list(): Account[] { return this.accounts }

  /// 这条会话用哪个账号。记着的账号已经不在配置里 → null（调用方拒绝，不回落到默认账号去读错目录）
  of(session: string): Account | null {
    const id = this.map.get(session)
    if (id === undefined) return this.accounts[0]
    return this.accounts.find((a) => a.id === id) ?? null
  }

  /// 会话已经存在（有绑定 / 起过）= 账号定了
  markStarted(session: string): void { this.settled.add(session) }

  /// 帧里带了 account：第一次就记下；账号不认识 → 拒；没带 = 不动。
  /// 已经定过且不一样 → 照原来定的用，不报错：手机上账号是按楼层选的，她改了楼层的账号以后，
  /// 老对话带着新账号发过来，应该照旧接着聊（界面上写的就是「已经开过的对话不跟着变」）
  claim(session: string, accountId: unknown): { ok: true } | { ok: false; reason: string } {
    if (accountId === undefined || accountId === null) return { ok: true }
    const acct = typeof accountId === "string" ? this.accounts.find((a) => a.id === accountId) : undefined
    if (!acct) return { ok: false, reason: `这台电脑没有账号「${String(accountId).slice(0, 40)}」` }
    if ((this.map.get(session) ?? this.accounts[0].id) === acct.id) { this.settled.add(session); return { ok: true } }
    if (this.settled.has(session)) return { ok: true }
    this.settled.add(session)
    this.map.set(session, acct.id)
    try { this.store?.write(JSON.stringify(Object.fromEntries(this.map), null, 2)) } catch { /* 落盘失败：这次进程内仍然有效 */ }
    return { ok: true }
  }
}
