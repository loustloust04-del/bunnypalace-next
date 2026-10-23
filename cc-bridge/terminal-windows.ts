/// 全局终端窗口注册表。
///
/// 「全局窗口」= 跟对话无关的终端，从任何对话进 CC 终端页看到的都是同一批。
/// 对话绑定的终端（`mp-cc-<hash>` / `mp-codex-<n>`）不归这里管，那条路径一个字节没动。
///
/// 前缀 `mp-win-` 是刻意选的：跟现有三个白名单（`mp-cc` / `mp-cc-` / `mp-codex-`）零重叠，
/// 所以 hub 里那几个按前缀或按 sessionActivity 遍历的定时器（keepalive / nudge / reap / agora）
/// 天然照不到全局窗口 —— 不会有保暖 ping 打进你的 shell，也不会被 7 天回收掉。
import { timedSyncFs } from "./block-ledger"
const { existsSync, readFileSync, writeFileSync } = timedSyncFs("terminal-windows ")
import { randomUUID } from "node:crypto"

export interface TerminalWindow {
  /// 永久身份。显示给用户的是序号（会随开关漂），这个不漂。
  code: string
  createdAt: string
  /// 有值 = 已关闭。**tmux session 不动** —— 关闭只是从导航里收起来，
  /// 里面跑的东西还活着，从长按 [+] 的菜单能恢复回来。
  closedAt?: string
  /// 有值 = 已结束：tmux session 已 kill，哪个列表都不再出现，也恢复不回来。
  endedAt?: string
  customTitle?: string
  engine?: TerminalEngine
}

export type TerminalEngine = "claude" | "codex" | "shell"
export type TerminalPhase = "idle" | "working" | "waiting" | "done"

export interface TerminalStateSource {
  code: string
  sessionName: string
  engine: TerminalEngine
  title: string | null
  includeWhenDead: boolean
}

export function sanitizeTerminalTitle(title: string | undefined): string | null {
  if (!title) return null
  const clean = title.replace(/[\u0000-\u001f\u007f-\u009f]/g, "").trim()
  if (!clean) return null
  return Array.from(clean).slice(0, 64).join("")
}

export function resolveTerminalTitle(
  customTitle: string | undefined,
  paneTitle: string | undefined,
  engine: TerminalEngine,
): string | null {
  return sanitizeTerminalTitle(customTitle)
    ?? sanitizeTerminalTitle(paneTitle)
    ?? (engine === "shell" ? null : engine)
}

/// tmux 的 pane_title 默认是主机名：等于主机名 = 没人设过标题（#046 审计 T13）。
export function isDefaultPaneTitle(paneTitle: string | undefined, hostNames: readonly string[]): boolean {
  const t = paneTitle?.trim()
  return !t || hostNames.includes(t)
}

/// 标题链再加一级兜底：shell 窗口没名字、pane 标题还是默认主机名 → 「shell · 当前目录名」（家目录写 ~）。
export function resolveWindowTitle(
  customTitle: string | undefined,
  paneTitle: string | undefined,
  engine: TerminalEngine,
  panePath: string | undefined,
  hostNames: readonly string[],
  home: string,
): string | null {
  const resolved = resolveTerminalTitle(customTitle, isDefaultPaneTitle(paneTitle, hostNames) ? undefined : paneTitle, engine)
  if (resolved || engine !== "shell" || !panePath) return resolved
  const dir = panePath === home ? "~" : (panePath.split("/").filter(Boolean).pop() ?? "/")
  return sanitizeTerminalTitle(`shell · ${dir}`)
}

/// Codex 没有 Claude 那样的 hook：按窗口最近一次有输出粗判（#046 审计 T22）。
export const CODEX_ACTIVE_WINDOW_SEC = 10
export function codexPhaseFromActivity(activitySec: number | undefined, nowSec: number): TerminalPhase {
  return activitySec && nowSec - activitySec <= CODEX_ACTIVE_WINDOW_SEC ? "working" : "idle"
}

export function buildTerminalStatePayload(
  sources: TerminalStateSource[],
  hasSession: (sessionName: string) => boolean,
  phaseFor: (sessionName: string) => TerminalPhase | undefined,
): string {
  const windows = sources.flatMap(source => {
    const alive = hasSession(source.sessionName)
    if (!alive && !source.includeWhenDead) return []
    return [{
      code: source.code,
      title: source.title,
      engine: source.engine,
      phase: phaseFor(source.sessionName) ?? "idle",
      alive,
    }]
  })
  return JSON.stringify({ type: "terminal_state", windows })
}

export const WINDOW_PREFIX = "mp-win-"
const CODE_LENGTH = 6

export function sessionNameFor(code: string): string {
  return `${WINDOW_PREFIX}${code}`
}

export function isWindowSession(name: string): boolean {
  return name.startsWith(WINDOW_PREFIX)
}

export function codeFromSession(name: string): string | null {
  return isWindowSession(name) ? name.slice(WINDOW_PREFIX.length) : null
}

/// 6 位小写 base36。碰撞就重抽（窗口数量个位数，实际永远不会撞）。
export function newWindowCode(existing: Iterable<string> = []): string {
  const taken = new Set(existing)
  for (let attempt = 0; attempt < 50; attempt++) {
    const code = randomUUID().replace(/-/g, "").slice(0, CODE_LENGTH)
    if (!taken.has(code)) return code
  }
  // 50 次全撞几乎不可能；真撞了就加时间戳兜底，绝不返回重复 code
  return `${Date.now().toString(36).slice(-CODE_LENGTH)}`
}

// ── 纯函数状态变更（好测，IO 在下面单独放）──

export function addWindow(
  windows: TerminalWindow[],
  code: string,
  now: string,
  engine: TerminalEngine = "shell",
): TerminalWindow[] {
  if (windows.some(w => w.code === code)) return windows
  return [...windows, { code, createdAt: now, engine }]
}

/// 关闭 = 打 closedAt 标记。不删记录（否则恢复不回来），不碰 tmux。
export function closeWindow(windows: TerminalWindow[], code: string, now: string): TerminalWindow[] {
  return windows.map(w => (w.code === code && !w.closedAt ? { ...w, closedAt: now } : w))
}

/// 结束 = 真 kill（hub 负责）+ 打 endedAt。记录留着只为 code 不被重抽。
export function endWindow(windows: TerminalWindow[], code: string, now: string): TerminalWindow[] {
  return windows.map(w => (w.code === code && !w.endedAt ? { ...w, endedAt: now } : w))
}

/// 结束一个窗口的 tmux 那一半：先 kill，确认 tmux 里真没了才返回 true；session 还在 = kill 没成。
/// 不碰注册表：kill 要 await，调用方拿到 true 后在**最新的**表上 endWindow（旧快照整体赋回会盖掉并发改动）。
export async function endWindowAfterKill(
  windows: TerminalWindow[],
  code: string,
  tmux: { kill(session: string): void | Promise<void>; hasSession(session: string): boolean },
): Promise<boolean> {
  if (!code || !windows.some(w => w.code === code)) return false
  const session = sessionNameFor(code)
  await tmux.kill(session)
  return !tmux.hasSession(session)
}

export function restoreWindow(windows: TerminalWindow[], code: string): TerminalWindow[] {
  return windows.map(w => {
    if (w.code !== code || !w.closedAt || w.endedAt) return w
    const { closedAt, ...rest } = w
    return rest
  })
}

export function setWindowCustomTitle(
  windows: TerminalWindow[],
  code: string,
  title: string | undefined,
): TerminalWindow[] {
  const customTitle = sanitizeTerminalTitle(title) ?? undefined
  return windows.map(window => {
    if (window.code !== code) return window
    if (customTitle) return { ...window, customTitle }
    const { customTitle: _removed, ...rest } = window
    return rest
  })
}

export function openWindows(windows: TerminalWindow[]): TerminalWindow[] {
  return windows.filter(w => !w.closedAt && !w.endedAt)
}

export function closedWindows(windows: TerminalWindow[]): TerminalWindow[] {
  return windows.filter(w => w.closedAt && !w.endedAt)
}

export function liveWindows(windows: TerminalWindow[]): TerminalWindow[] {
  return windows.filter(w => !w.endedAt)
}

// ── 落盘 ──

/// 坏 JSON / 缺字段一律当空列表，绝不抛 —— 注册表坏了最多是窗口列表空了，
/// 不能让 hub 起不来。
export function loadWindows(path: string): TerminalWindow[] {
  try {
    if (!existsSync(path)) return []
    const raw = JSON.parse(readFileSync(path, "utf-8"))
    if (!Array.isArray(raw)) return []
    return raw.filter(
      (w: unknown): w is TerminalWindow =>
        !!w && typeof w === "object"
        && typeof (w as TerminalWindow).code === "string"
        && (w as TerminalWindow).code.length > 0
    )
  } catch {
    return []
  }
}

export function saveWindows(path: string, windows: TerminalWindow[]): void {
  try {
    writeFileSync(path, JSON.stringify(windows, null, 2))
  } catch (e: any) {
    console.warn(`[hub] windows save fail: ${e?.message}`)
  }
}
