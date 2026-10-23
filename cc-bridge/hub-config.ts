/// hub 自己的配置 + 连上时的 hello 帧（#046 T3，docs/plan-terminal-t3.md 刀 1）。
///
/// 「家」（对话 Agent / 人设 / 收发件箱 / hook）在 cc-workdir.ts；这里管的是另一件事：
/// [+] 开的「新 Claude Code」「新 Codex」窗口在哪个目录干活。没设 = 各自的家 = 以前的行为。
/// 配置文件放 hub 的状态目录（SECRETS_DIR）里，谁连上 hub 谁都能改——能连上的本来就能开 shell。
import { randomBytes } from "node:crypto"
import { type Dirent, type Stats } from "node:fs"
import { timedExecFileSync, timedSyncFs } from "./block-ledger"
const { chmodSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync } = timedSyncFs("hub-config ")
const execFileSync = timedExecFileSync("hub-config ")
import { readFile, stat } from "node:fs/promises"
import { hostname } from "node:os"
import { delimiter, dirname, join } from "node:path"

export interface HubConfig {
  agent_workdir?: string
  /// 只在 MP_CC_HUB_PORT=0（Mac App 内嵌 hub）时用：OS 第一次分配的端口记下来，下次先试它，
  /// 这样手机扫过的二维码重启后还连得上。
  port?: number
}

/// LAN / Tailscale 绑定开关（secrets/bind-config.json）。缺文件 / 坏文件 = 都开
export interface BindPrefs { lan: boolean; tailscale: boolean }
export function parseBindPrefs(raw: string | undefined): BindPrefs {
  return tryParseBindPrefs(raw) ?? { lan: true, tailscale: true }
}
/// 解析不了（坏 JSON / 不是对象）→ undefined
export function tryParseBindPrefs(raw: string | undefined): BindPrefs | undefined {
  try {
    const o: unknown = JSON.parse(raw ?? "")
    if (!o || typeof o !== "object") return undefined
    const r = o as { lan?: unknown; tailscale?: unknown }
    return { lan: r.lan !== false, tailscale: r.tailscale !== false }
  } catch { return undefined }
}

/// K3：开关缓存在内存（30s 自愈重检原来每次同步读盘）。启动同步读一次；set_bind 写盘时一并更新；
/// refresh 只异步 stat，mtime 变了（有人手改文件）才异步重读。refresh 期间 save 过 → 这次读到的作废
export class BindPrefsCache {
  private prefs: BindPrefs
  private mtime: number | undefined | null = null
  private gen = 0
  constructor(private readonly path: string) {
    this.prefs = parseBindPrefs((() => { try { return readFileSync(path, "utf-8") } catch { return undefined } })())
  }
  get(): BindPrefs { return this.prefs }
  save(p: BindPrefs): void {
    this.prefs = p
    this.mtime = null
    this.gen++
    try { writeFileSync(this.path, JSON.stringify(p, null, 2)) } catch (e) { console.warn(`[hub] bind-config save fail: ${(e as Error).message}`) }
  }
  async refresh(): Promise<BindPrefs> {
    const g = this.gen
    // 审查 R1-4：stat 非 ENOENT 失败 / 读失败 / 解析失败 → 留着上次有效的开关、不提交 mtime，下轮重试（文件确实不在才按默认都开）
    const m = await stat(this.path).then((s) => s.mtimeMs, (e: NodeJS.ErrnoException) => e.code === "ENOENT" ? undefined : null)
    if (m === null || m === this.mtime || g !== this.gen) return this.prefs
    const next = m === undefined ? { lan: true, tailscale: true } : tryParseBindPrefs(await readFile(this.path, "utf-8").catch(() => undefined))
    if (!next || g !== this.gen) return this.prefs
    this.mtime = m
    this.prefs = next
    return this.prefs
  }
}

export function loadHubConfig(path: string): HubConfig {
  try {
    const raw = JSON.parse(readFileSync(path, "utf-8"))
    if (!raw || typeof raw !== "object") return {}
    const out: HubConfig = {}
    if (typeof raw.agent_workdir === "string" && raw.agent_workdir) out.agent_workdir = raw.agent_workdir
    if (Number.isInteger(raw.port) && raw.port > 0 && raw.port < 65536) out.port = raw.port
    return out
  } catch {
    return {}
  }
}

/// 原子写 + 0600。目标是软链就拒写（防被人换成指向别处的链接后写穿）；临时文件随机名 + 独占创建（wx），
/// 已有同名（含软链）直接失败，不会写穿到别处。
export function saveJsonPrivate(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  if (lstatSync(path, { throwIfNoEntry: false })?.isSymbolicLink()) throw new Error(`${path} 是软链，不写`)
  const tmp = `${path}.tmp-${process.pid}-${randomBytes(6).toString("hex")}`
  try {
    writeFileSync(tmp, JSON.stringify(value, null, 2), { mode: 0o600, flag: "wx" })
    chmodSync(tmp, 0o600)
    renameSync(tmp, path)
  } catch (e) {
    try { unlinkSync(tmp) } catch { /* 没建出来 */ }
    throw e
  }
}

/// stat 出任何错（循环软链 / 没权限 / 路径带 NUL）都当「没有」，不往上抛——hub 消息处理里抛出去会整个退出
function safeStat(path: string): Stats | undefined {
  try { return statSync(path, { throwIfNoEntry: false }) } catch { return undefined }
}

export function saveHubConfig(path: string, config: HubConfig): void {
  saveJsonPrivate(path, config)
}

function expandHome(raw: string, home: string): string {
  if (raw === "~") return home
  if (raw.startsWith("~/")) return join(home, raw.slice(2))
  return raw
}

/// 用户给的干活目录：展开 ~，必须是绝对路径、存在、是目录（软链指向目录也行），返回 realpath。
export function validateWorkdir(raw: string, home: string): { ok: true; path: string } | { ok: false; reason: string } {
  const expanded = expandHome(raw.trim(), home)
  if (!expanded.startsWith("/") || expanded.includes("\0")) return { ok: false, reason: "要填完整路径（以 / 或 ~ 开头）" }
  const st = safeStat(expanded)
  if (!st) return { ok: false, reason: "电脑上没有这个目录" }
  if (!st.isDirectory()) return { ok: false, reason: "这是个文件，不是目录" }
  try {
    return { ok: true, path: realpathSync(expanded) }
  } catch {
    return { ok: false, reason: "这个目录读不了" }
  }
}

/// [+] 窗口实际用的目录：配置里那个还在且是目录就用它，否则回到这个引擎的家。
export function resolveAgentWorkdir(config: HubConfig, engineHome: string): string {
  const dir = config.agent_workdir
  if (dir && safeStat(dir)?.isDirectory()) return dir
  return engineHome
}

/// 两个路径是不是同一个目录（realpath 比；任一不存在就按字面比）。
export function sameDir(a: string, b: string): boolean {
  const real = (p: string) => { try { return realpathSync(p) } catch { return p } }
  return real(a) === real(b)
}

export const LIST_DIRS_LIMIT = 500

export type DirListing =
  | { path: string; parent: string | null; dirs: string[]; truncated: boolean }
  | { path: string; error: string }

/// 手机上「选干活目录」一级级点进去用：只列子文件夹（软链指向文件夹的也算），不列点开头的，按名字排。
export function listDirs(raw: string | undefined, home: string, limit = LIST_DIRS_LIMIT): DirListing {
  const requested = expandHome((raw ?? "").trim() || "~", home)
  let path: string
  try {
    path = realpathSync(requested)
  } catch {
    return { path: requested, error: "电脑上没有这个目录" }
  }
  let entries: Dirent[]
  try {
    entries = readdirSync(path, { withFileTypes: true })
  } catch {
    return { path, error: "这个目录读不了（可能没有权限）" }
  }
  // 只对软链额外 stat（普通文件 / 文件夹 Dirent 自带类型），文件再多也不逐个 stat
  const dirs = entries
    .filter(e => !e.name.startsWith(".") && (e.isDirectory() || (e.isSymbolicLink() && !!safeStat(join(path, e.name))?.isDirectory())))
    .map(e => e.name)
    .sort((x, y) => x.localeCompare(y))
  return { path, parent: path === "/" ? null : dirname(path), dirs: dirs.slice(0, limit), truncated: dirs.length > limit }
}

export interface ToolAvailability {
  tmux: boolean | null
  claude: boolean | null
  codex: boolean | null
}

/// 按 hub 自己的 PATH 找命令——tmux 起 agent 命令用的就是这个环境（不是登录 shell 的）。纯查文件，不起子进程。
export function detectTools(pathEnv: string | undefined): ToolAvailability {
  const dirs = (pathEnv ?? "").split(delimiter).filter(Boolean)
  const has = (name: string) => dirs.some(dir => {
    const st = safeStat(join(dir, name))
    return !!st && st.isFile() && (st.mode & 0o111) !== 0
  })
  return { tmux: has("tmux"), claude: has("claude"), codex: has("codex") }
}

export interface MachineInfo {
  host_name: string
  host_model_id: string | null
  host_model_name: string | null
}

function run(cmd: string, args: string[]): string | null {
  try {
    const out = execFileSync(cmd, args, { encoding: "utf-8", timeout: 2000, stdio: ["ignore", "pipe", "ignore"] }).trim()
    return out || null
  } catch {
    return null
  }
}

/// IODeviceTree 的 product-name：`"product-name" = <"MacBook Air (15-inch, M5)">`（Intel 机器没有）。
export function parseProductName(ioregOutput: string): string | null {
  const m = ioregOutput.match(/"product-name"\s*=\s*<"([^"]+)">/)
  return m ? m[1].replace(/\0/g, "").trim() || null : null
}

/// 启动时取一次（几个子进程各 ≤2s），首页 3D 小电脑按机型选外形（#064）。
/// 写绝对路径：launchd 起的 hub PATH 里没有 /usr/sbin，三个命令全找不到 → 机型为空、名字退成 hostname（粟粟 10-11）。
export function readMachineInfo(): MachineInfo {
  const name = run("/usr/sbin/scutil", ["--get", "ComputerName"]) ?? hostname().replace(/\.local$/, "")
  const modelId = run("/usr/sbin/sysctl", ["-n", "hw.model"])
  const ioreg = run("/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformDevice", "-k", "product-name"])
  return { host_name: name, host_model_id: modelId, host_model_name: ioreg ? parseProductName(ioreg) : null }
}

export interface HelloInput {
  hubVersion: string
  machine: MachineInfo
  claudeHome: string
  codexHome: string
  agentWorkdir: string | null
  tools: ToolAvailability
  capabilities: string[]
}

export function buildHelloPayload(input: HelloInput): string {
  const frame: Record<string, unknown> = {
    type: "hello",
    hub_version: input.hubVersion,
    host_name: input.machine.host_name,
    dirs: { claude_home: input.claudeHome, codex_home: input.codexHome, agent_workdir: input.agentWorkdir },
    tools: input.tools,
    capabilities: input.capabilities,
  }
  if (input.machine.host_model_id) frame.host_model_id = input.machine.host_model_id
  if (input.machine.host_model_name) frame.host_model_name = input.machine.host_model_name
  return JSON.stringify(frame)
}

/// 内嵌 hub（Mac App）没有 cc-bridge/.mcp.json：用 App 带的 mcp-server 二进制现写一份，连本 hub 的真实端口。
export function buildMcpConfig(serverBin: string, port: number, token: string | undefined): Record<string, unknown> {
  const env: Record<string, string> = { MP_CC_HUB_URL: `ws://127.0.0.1:${port}/mcp` }
  if (token) env.MP_CC_HUB_TOKEN = token
  return { mcpServers: { "cc-bridge": { command: serverBin, args: [], env } } }
}

/// 对话 Agent 的 --mcp-config：cwd 有 .mcp.json（粟粟的 launchd hub，start_cc.sh 渲染的）就用它；
/// 否则用这次启动成功生成的那份（上次启动留下的旧文件不算：端口 / 二进制可能都变了）；
/// 都没有（内嵌却没给 mcp-server 二进制、或这次没写成）→ null = 不带 --mcp-config。
export function pickMcpConfig(cwdConfig: string, generatedThisBoot: string | null): string | null {
  if (existsSync(cwdConfig)) return cwdConfig
  if (generatedThisBoot && existsSync(generatedThisBoot)) return generatedThisBoot
  return null
}
