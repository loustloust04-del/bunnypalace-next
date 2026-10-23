import type { TerminalEngine } from "./terminal-windows"
import { shellQuote } from "./cc-model"

export interface FreshTerminalLaunchConfig {
  home: string
  shell: string
  ccWorkdir: string
  codexWorkdir: string
  ccModel: string
  /// null = 没有可用的 mcp-server（内嵌 hub 没给二进制）→ 不带 --mcp-config
  mcpConfig: string | null
  claudeSessionId: string
  /// [+] 窗口开在家以外的干活目录（#046 T3 / 审计 T18）：用户自己敲 `claude` 的样子，不带陪伴配置
  cleanClaude?: boolean
}

// 陪伴会话用不到的内置工具（cc-rp 全历史 14126 次 tool_use 里 0 次），砍掉省 ~16K 固定上下文；
// --strict-mcp-config 跳过全局 MCP / claude.ai connectors（再省 ~3K，也不再每次启动报 mobai 缺模块）。
// 实测见 docs/plan-strip-thinking.md 七-7.4-4。Cron 三件 / Artifact / Agent / Skill 小克用过，留。
export const CC_DISALLOWED_TOOLS = [
  "NotebookEdit", "LSP", "Workflow", "DesignSync", "EnterPlanMode", "ExitPlanMode", "EnterWorktree", "ExitWorktree",
  "ReportFindings", "RemoteTrigger", "ScheduleWakeup", "EndConversation", "FetchInboxMessage", "ListMcpResourcesTool",
  "ReadMcpResourceTool", "ReadMcpResourceDirTool", "SendFeedback", "SendMessage", "ListAgents", "PushNotification",
  "ReadNotifications", "TaskStop", "TaskOutput", "Monitor",
]

export interface TerminalLaunch {
  cwd: string
  command: string
}

export function buildFreshTerminalLaunch(
  engine: TerminalEngine,
  config: FreshTerminalLaunchConfig,
): TerminalLaunch {
  if (engine === "claude") {
    if (config.cleanClaude) return { cwd: config.ccWorkdir, command: `claude --session-id ${config.claudeSessionId}` }
    const mcp = config.mcpConfig ? `--mcp-config '${config.mcpConfig}' ` : ""
    return {
      cwd: config.ccWorkdir,
      command: `claude --model ${shellQuote(config.ccModel)} ${mcp}--strict-mcp-config --disallowedTools '${CC_DISALLOWED_TOOLS.join(",")}' --session-id ${config.claudeSessionId}`,
    }
  }
  if (engine === "codex") return { cwd: config.codexWorkdir, command: "codex" }
  return { cwd: config.home, command: `${config.shell} -l` }
}
