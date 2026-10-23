// CC 工作目录：MP_CC_WORKDIR → 老装法 ~/Desktop/cc-rp（已存在才用）→ Application Support（跟 mac app 内置 hub 的 CCHubProcess 同一处）。
// app 端 CCThinkingHookInstaller.workdir、start_cc.sh 是同一套顺序，改一处三处一起改。
// 这是「家」（#046 T3）：对话 Agent、人设 CLAUDE.md、收发件箱、hook 都在这；[+] 开的窗口另走 hub-config 的干活目录。
import { timedSyncFs } from "./block-ledger"
const { statSync } = timedSyncFs("cc-workdir ")
import { homedir } from "node:os"
import { join } from "node:path"

export function ccWorkdir(env: Record<string, string | undefined> = process.env, home: string = homedir()): string {
  if (env.MP_CC_WORKDIR) return env.MP_CC_WORKDIR
  const legacy = join(home, "Desktop", "cc-rp")
  if (statSync(legacy, { throwIfNoEntry: false })?.isDirectory()) return legacy
  return join(home, "Library", "Application Support", "MemoryPalace", "cc-bridge", "cc-rp")
}

/// codex 的家（07-20 粟粟拍：不和小克挤 cc-rp）——AGENTS.md/记忆都在这。兜底顺序同 ccWorkdir。
export function codexWorkdir(env: Record<string, string | undefined> = process.env, home: string = homedir()): string {
  if (env.MP_CODEX_WORKDIR) return env.MP_CODEX_WORKDIR
  const legacy = join(home, "Desktop", "gpt-rp")
  if (statSync(legacy, { throwIfNoEntry: false })?.isDirectory()) return legacy
  return join(home, "Library", "Application Support", "MemoryPalace", "cc-bridge", "gpt-rp")
}

/** Claude Code 的 project 目录名：路径里非字母数字一律换成 "-"（transcript 和 memory 都在这个目录下） */
export function ccProjectSlug(workdir: string): string {
  return workdir.replace(/[^a-zA-Z0-9]/g, "-")
}

export function ccProjectMemoryDir(workdir: string, home: string = homedir()): string {
  return join(home, ".claude", "projects", ccProjectSlug(workdir), "memory")
}
