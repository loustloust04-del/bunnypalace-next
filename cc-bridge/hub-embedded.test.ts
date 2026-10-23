// #046 T3：Mac App 内嵌 hub 的启动链（MP_CC_HUB_PORT=0）。隔离子进程 + 临时目录 + DRY_RUN，不碰 7890、不碰真 tmux。
import { test, expect } from "bun:test"
import { mkdtempSync, mkdirSync, readFileSync, statSync, writeFileSync, chmodSync, existsSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const SECRETS = mkdtempSync(join(tmpdir(), "cc-hub-embedded-"))
const FAKE_MCP_BIN = join(SECRETS, "mcp-server-fake")
writeFileSync(FAKE_MCP_BIN, "#!/bin/sh\n")
chmodSync(FAKE_MCP_BIN, 0o755)
// 假 HOME：hub 里凡是默认落在 ~ 下的状态（thinking spool、codex 会话、~/.cc-bridge…）都落到临时目录，碰不到粟粟的真数据
const FAKE_HOME = join(SECRETS, "home")
mkdirSync(FAKE_HOME)

/// 起一个内嵌模式 hub，等 stdout 的 listening 行，返回端口；拿到后杀掉
async function bootOnce(): Promise<number> {
  const proc = Bun.spawn(["bun", "run", "hub.ts"], {
    cwd: import.meta.dir,
    env: {
      ...process.env,
      HOME: FAKE_HOME,
      MP_CC_THINKING_SPOOL: join(SECRETS, "spool"),
      MP_CC_LA_INTERVAL_MS: "3600000",
      MP_CC_TMUX_DRY_RUN: "1", MP_CC_HUB_TOKEN: "embedded-token", MP_CC_HUB_PORT: "0",
      MP_CC_HUB_HOST: "127.0.0.1",   // 测试只绑本机，不碰 LAN / Tailscale
      MP_CC_SECRETS_DIR: SECRETS, MP_CC_AGENT_DIR: join(SECRETS, "agent"),
      MP_CC_WORKDIR: join(SECRETS, "cc-rp"), MP_CODEX_WORKDIR: join(SECRETS, "gpt-rp"),
      MP_CC_MCP_SERVER_BIN: FAKE_MCP_BIN, MP_APNS_KEY_PATH: join(SECRETS, "no-such-key.p8"),
    },
    stdout: "pipe", stderr: "pipe",
  })
  const reader = proc.stdout.getReader()
  const decoder = new TextDecoder()
  let buf = ""
  // 硬超时：一次 read() 挂住 deadline 也打断不了，到点直接杀进程（read 随之结束）
  const killer = setTimeout(() => proc.kill(), 15_000)
  try {
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      buf += decoder.decode(value)
      for (const line of buf.split("\n")) {
        if (!line.startsWith("{")) continue
        try {
          const o = JSON.parse(line)
          if (o.event === "listening" && o.host === "127.0.0.1") return o.port
        } catch { /* 半行 */ }
      }
    }
    throw new Error(`内嵌 hub 没打出 listening 行：\n${buf.slice(-2000)}`)
  } finally {
    clearTimeout(killer)
    proc.kill()
    await proc.exited
  }
}

test("内嵌 hub：端口 0 → OS 分配并记进 hub-config；listening 之前 mcp.json 已写好（0600、连真实端口）；重启复用同一端口", async () => {
  const first = await bootOnce()
  expect(first).toBeGreaterThan(0)
  expect(first).not.toBe(7890)
  const cfg = JSON.parse(readFileSync(join(SECRETS, "hub-config.json"), "utf-8"))
  expect(cfg.port).toBe(first)

  const mcpPath = join(SECRETS, "mcp.json")
  expect(existsSync(mcpPath)).toBe(true)
  expect(statSync(mcpPath).mode & 0o777).toBe(0o600)
  const mcp = JSON.parse(readFileSync(mcpPath, "utf-8"))
  expect(mcp.mcpServers["cc-bridge"].command).toBe(FAKE_MCP_BIN)
  expect(mcp.mcpServers["cc-bridge"].env.MP_CC_HUB_URL).toBe(`ws://127.0.0.1:${first}/mcp`)
  expect(mcp.mcpServers["cc-bridge"].env.MP_CC_HUB_TOKEN).toBe("embedded-token")

  const second = await bootOnce()
  expect(second).toBe(first)
}, 40_000)
