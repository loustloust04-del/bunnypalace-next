// 思考强度（MemoryPalace docs/research-reasoning-effort.md §2.3）：app 发消息时带 effort，hub 让会话真的切过去。
// claude：新开 / 恢复带 `--effort`，跑着的会话发一条 `/effort <档>`（每条消息都能改）
// codex：开 / 恢复带 `-c model_reasoning_effort="<档>"`；跑着的会话改了要用同一个 id 重启（codex 没有中途改的口）
export type EffortEngine = "claude" | "codex" | "shell"

export const CLAUDE_EFFORTS = ["low", "medium", "high", "xhigh", "max"] as const
export const CODEX_EFFORTS = ["low", "medium", "high", "xhigh"] as const

/// app 发来的值 → 这个引擎认的档位；不认 / 「默认」(auto) / shell → undefined（不动会话）
export function normalizeEffort(engine: EffortEngine, raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined
  const v = raw.trim().toLowerCase()
  if (engine === "claude") return (CLAUDE_EFFORTS as readonly string[]).includes(v) ? v : undefined
  if (engine === "codex") return (CODEX_EFFORTS as readonly string[]).includes(v) ? v : undefined
  return undefined
}

/// 拼到启动命令后面的参数（前面带空格）；没有就空串
export function effortArg(engine: EffortEngine, effort: string | undefined): string {
  const e = normalizeEffort(engine, effort)
  if (!e) return ""
  if (engine === "claude") return ` --effort ${e}`
  if (engine === "codex") return ` -c model_reasoning_effort="${e}"`
  return ""
}

/// 跑着的会话要不要动：claude → 先发这条斜杠命令；codex → 重启；一样 / 没要求 → 不动
export function effortChange(
  engine: EffortEngine, current: string | undefined, want: string | undefined,
): { command?: string; respawn: boolean } {
  const w = normalizeEffort(engine, want)
  if (!w || w === current) return { respawn: false }
  if (engine === "claude") return { command: `/effort ${w}`, respawn: false }
  if (engine === "codex") return { respawn: true }
  return { respawn: false }
}
