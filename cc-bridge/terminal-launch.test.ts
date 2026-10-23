import { expect, test } from "bun:test"
import { buildFreshTerminalLaunch, CC_DISALLOWED_TOOLS } from "./terminal-launch"

const config = {
  home: "/Users/test",
  shell: "/bin/zsh",
  ccWorkdir: "/work/cc-rp",
  codexWorkdir: "/work/gpt-rp",
  ccModel: "claude-opus-4-6[1m]",
  mcpConfig: "/work/cc-bridge/.mcp.json",
  claudeSessionId: "11111111-2222-4333-8444-555555555555",
}

test("open_window engine 三分支使用各自的 fresh 命令与工作目录", () => {
  expect(buildFreshTerminalLaunch("shell", config)).toEqual({
    cwd: "/Users/test",
    command: "/bin/zsh -l",
  })
  expect(buildFreshTerminalLaunch("claude", config)).toEqual({
    cwd: "/work/cc-rp",
    command: `claude --model 'claude-opus-4-6[1m]' --mcp-config '/work/cc-bridge/.mcp.json' --strict-mcp-config --disallowedTools '${CC_DISALLOWED_TOOLS.join(",")}' --session-id 11111111-2222-4333-8444-555555555555`,
  })
  expect(buildFreshTerminalLaunch("codex", config)).toEqual({
    cwd: "/work/gpt-rp",
    command: "codex",
  })
})

test("#046：干活目录不是家时 [+] Claude Code 用干净参数；没有 mcp 配置时不带 --mcp-config", () => {
  expect(buildFreshTerminalLaunch("claude", { ...config, ccWorkdir: "/proj", cleanClaude: true })).toEqual({
    cwd: "/proj",
    command: "claude --session-id 11111111-2222-4333-8444-555555555555",
  })
  expect(buildFreshTerminalLaunch("claude", { ...config, mcpConfig: null }).command)
    .toBe(`claude --model 'claude-opus-4-6[1m]' --strict-mcp-config --disallowedTools '${CC_DISALLOWED_TOOLS.join(",")}' --session-id 11111111-2222-4333-8444-555555555555`)
})
