// 跑法：cd cc-bridge && bun run e2e/stream-retire.e2e.ts（真 claude haiku，一次约 1 分钟、几分钱；不进 bun test）
// 隔离 e2e：开关关→stream 会话收回终端。测试 hub 17999 + 独立 tmux socket（TMUX_TMPDIR）+ scratch secrets/workdir，
// 子进程 mcp-server 经 MP_CC_HUB_URL 回连测试 hub——生产 7890 / 粟粟的 tmux server 全程不碰。
import { mkdtempSync, mkdirSync, readFileSync, existsSync, openSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
import { execFileSync } from "node:child_process"

const HUB_DIR = "/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace/cc-bridge"
const PORT = 17999, TOKEN = "e2e-token"
const root = mkdtempSync(join(tmpdir(), "mp-e2e-retire-"))
const dirs = { secrets: join(root, "secrets"), agent: join(root, "agent"), work: join(root, "work"), tmux: mkdtempSync("/tmp/mpe2e-") }   // socket 路径有 104 字节上限，scratchpad 太长
for (const d of Object.values(dirs)) mkdirSync(d, { recursive: true })
console.log(`  tmux socket dir ${dirs.tmux}`)
// 放行 reply 等 MCP 工具（生产 cc-rp 的 settings 里有），Bash 不放行——B 段要靠它出权限卡
mkdirSync(join(dirs.work, ".claude"), { recursive: true })
await Bun.write(join(dirs.work, ".claude", "settings.json"), JSON.stringify({ permissions: { allow: ["mcp__cc-bridge__reply", "mcp__cc-bridge__*"] } }))
await Bun.write(join(dirs.work, "CLAUDE.md"), "收到 <channel> 消息一律用 mcp__cc-bridge__reply 工具回复（chat_id 取消息里的），不要直接输出文字。\n")
const logPath = join(root, "hub.log")
const logFd = openSync(logPath, "a")
const env: Record<string, string> = {
  ...process.env as Record<string, string>,
  MP_CC_HUB_TOKEN: TOKEN, MP_CC_HUB_PORT: String(PORT), MP_CC_HUB_URL: `ws://127.0.0.1:${PORT}/mcp`,
  MP_CC_SECRETS_DIR: dirs.secrets, MP_CC_AGENT_DIR: dirs.agent, MP_CC_WORKDIR: dirs.work,
  MP_CC_MODEL: "haiku", MP_CC_WARROOM: "0", MP_CC_NUDGE_ENABLED: "0",
  MP_APNS_KEY_PATH: join(root, "no-key.p8"), MP_CC_LA_INTERVAL_MS: "3600000",
  MP_CC_STREAM_RETIRE_STAGGER_MS: "1000", TMUX_TMPDIR: dirs.tmux, MP_CC_BOOT_MS: "2000",
}
delete env.TMUX; delete env.TMUX_PANE
const tmux = (...a: string[]) => { try { return execFileSync("tmux", a, { env, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }) } catch { return "" } }
const hub = Bun.spawn(["bun", "run", "hub.ts"], { cwd: HUB_DIR, env, stdout: logFd, stderr: logFd })
const log = () => existsSync(logPath) ? readFileSync(logPath, "utf8") : ""
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
let cursor = 0
const mark = () => { cursor = log().length }   // 阶段边界：之后的 waitLog 只看新日志（A 段的 "stream ready" 别被 B 段误认）
async function waitLog(re: RegExp, ms: number, label = re.source): Promise<string> {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) { const m = log().slice(cursor).match(re); if (m) { console.log(`  ✓ ${label} (+${Date.now() - t0}ms)`); return m[0] }; await sleep(150) }
  throw new Error(`timeout waiting log: ${label}\n--- tail ---\n${log().split("\n").slice(-25).join("\n")}`)
}
const results: string[] = []
const ok = (s: string) => { results.push(`✓ ${s}`); console.log(`✓ ${s}`) }
let cleanupDone = false
async function cleanup() {
  if (cleanupDone) return; cleanupDone = true
  tmux("kill-server")            // 只杀自己 TMUX_TMPDIR 里的 server
  hub.kill(); await sleep(800)
  // 只扫 haiku 的 claude 进程（测试 hub 独有；生产全是 opus），且跳过自己和父 shell——上一版按 "mp-cc-e2e" 字面匹配把跑脚本的 bash 都杀了
  const ps = execFileSync("ps", ["-eo", "pid,command"], { encoding: "utf8" }).split("\n").filter((l) => /^\s*\d+\s+\S*claude (-p|--model) /.test(l) && /--model '?haiku/.test(l))
  for (const l of ps) { const pid = Number(l.trim().split(/\s+/)[0]); if (pid && pid !== process.pid && pid !== process.ppid) try { process.kill(pid, "SIGKILL"); console.log(`  killed leftover pid ${pid}`) } catch {} }
  console.log(`\nhub log: ${logPath}\n${results.join("\n")}`)
}
process.on("SIGINT", () => cleanup().then(() => process.exit(1)))

try {
  for (let i = 0; i < 60; i++) { try { if ((await fetch(`http://127.0.0.1:${PORT}/health`)).ok) break } catch {}; await sleep(200); if (i === 59) throw new Error("hub not healthy") }
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/cc?token=${TOKEN}`)
  const frames: any[] = []
  let autoAllow = true
  const isPerm = (m: any, tool: string) => m.type === "ask_user_question" && String(m.tool_use_id).startsWith("perm:") && String(m.questions?.[0]?.question ?? "").includes(tool)
  ws.onmessage = (e) => {
    const m = JSON.parse(String(e.data)); frames.push(m)
    if (["reply", "ask_user_question", "spawn_cc_ok", "spawn_cc_err", "list_sessions_result"].includes(m.type)) console.log(`  ← ${m.type} ${JSON.stringify(m).slice(0, 140)}`)
    // scratch 目录未信任，-p 不读 .claude/settings.json → reply 工具也弹卡；自动放行（生产 cc-rp 已信任+allow）
    if (autoAllow && isPerm(m, "mcp__cc-bridge__")) { ws.send(JSON.stringify({ type: "ask_user_answer", tool_use_id: m.tool_use_id, answers: [{ indices: [0] }] })); console.log(`  → auto-allow ${m.tool_use_id.slice(0, 20)}`) }
  }
  await new Promise<void>((res, rej) => { ws.onopen = () => res(); ws.onerror = (e) => rej(e) })
  const send = (o: any) => ws.send(JSON.stringify(o))
  async function waitFrame(pred: (m: any) => boolean, ms: number, label: string): Promise<any> {
    const t0 = Date.now(); while (Date.now() - t0 < ms) { const m = frames.find(pred); if (m) return m; await sleep(150) }
    throw new Error(`timeout waiting frame: ${label}`)
  }
  const S = "mp-cc-e2e", CHAT = "e2e-chat"
  // haiku 不一定肯调工具：结果到了却没命中就再催一次，最多 3 轮
  async function sendUntil(id: string, word: string, hit: (m: any) => boolean, label: string): Promise<any> {
    for (let i = 0; i < 3; i++) {
      const before = log().length
      send({ type: "send", chat_id: CHAT, message_id: `${id}-${i}`, content: `必须调用 mcp__cc-bridge__reply 工具回复我（chat_id=${CHAT}，content=${word}），不要直接输出文字。`, user: "e2e", session_name: S })
      const t0 = Date.now()
      while (Date.now() - t0 < 90000) {
        const m = frames.find(hit); if (m) return m
        if (new RegExp(`stream result ${S}`).test(log().slice(before))) break
        await sleep(200)
      }
      console.log(`  … ${label} 第 ${i + 1} 次没命中，再催`)
    }
    throw new Error(`3 次都没命中: ${label}`)
  }

  // ── A：开关开 → stream 会话 → 一轮对话（留 transcript）→ 开关关 → 空闲即收 → 1s 后 tmux --resume 重生
  send({ type: "set_cc_config", newSessionTransport: "stream" })
  send({ type: "spawn_cc", session_name: S, transport: "stream" })
  await waitFrame((m) => m.type === "spawn_cc_ok", 5000, "spawn_cc_ok")
  await waitLog(new RegExp(`stream ready ${S}`), 40000)
  await sendUntil("m1", "好", (m) => m.type === "reply" && m.chat_id === CHAT, "reply(A)")
  await waitLog(new RegExp(`stream result ${S}`), 20000)
  await waitLog(/stream perm allow/, 5000)
  ok("A1 stream 会话就绪并回话（reply 权限卡 allow 路径顺带过）")
  send({ type: "set_cc_config", newSessionTransport: "tmux" })
  await waitLog(new RegExp(`stream retire ${S}（开关已切回 tmux）→ 0s`), 5000)
  await waitLog(new RegExp(`spawned tmux:${S} resume=`), 10000)
  await sleep(1500)
  if (!tmux("ls").includes(S)) throw new Error(`tmux(隔离 socket) 里没有 ${S}: ${tmux("ls")}`)
  frames.length = 0; send({ type: "list_sessions" })
  const ls = await waitFrame((m) => m.type === "list_sessions_result", 5000, "list_sessions_result")
  if (!ls.sessions.includes(S) || ls.stream_sessions.length !== 0) throw new Error(`list_sessions 不对: ${JSON.stringify(ls)}`)
  const map = JSON.parse(readFileSync(join(dirs.secrets, "session-map.json"), "utf8"))
  if (map[S]?.transport !== "tmux") throw new Error(`绑定 transport 没归位: ${map[S]?.transport}`)
  ok(`A2 关开关 → 空闲即收 → tmux --resume 同一会话（binding.transport=${map[S]?.transport}，sid=${String(map[S]?.claudeSessionId).slice(0, 8)}）`)

  // ── B：开关开 → 杀掉 tmux 版 → 发消息按开关 stream 续起 → 卡在权限卡（忙）→ 开关关 → 等本轮 → 答拒绝 → 收 → tmux 重生
  mark()
  send({ type: "set_cc_config", newSessionTransport: "stream" })
  await sleep(11000)   // resume boot = 2000×5，等 sessionReady 再杀：send 走 ready→send fail→清态→按开关续起（真实路径）
  tmux("kill-session", "-t", S); await sleep(500)
  frames.length = 0; autoAllow = false
  const perm = await sendUntil("m2", "嗨", (m) => isPerm(m, "mcp__cc-bridge__"), "perm card(B)")
  await waitLog(new RegExp(`stream spawn ${S} resume=`), 8000)
  await waitLog(new RegExp(`stream ready ${S}`), 40000)
  ok(`B1 tmux 版被杀后 send → 按开关 stream --resume 续起 + 权限卡到 app（${perm.tool_use_id.slice(0, 20)}）`)
  send({ type: "set_cc_config", newSessionTransport: "tmux" })
  await waitLog(new RegExp(`stream ${S} 正在跑一轮，本轮结束后收回终端`), 5000)
  if (log().includes(`stream retire ${S}（开关已切回 tmux）`) && log().split(`stream retire ${S}（开关已切回 tmux）`).length > 2) throw new Error("忙碌中被立刻收了")
  ok("B2 忙碌中不收，挂等本轮"); mark()
  send({ type: "ask_user_answer", tool_use_id: perm.tool_use_id, answers: [{ indices: [1] }] })
  await waitLog(/stream perm deny/, 5000)
  await waitLog(new RegExp(`stream retire ${S}（开关已切回 tmux，本轮跑完）`), 120000)
  await waitLog(new RegExp(`spawned tmux:${S} resume=`), 10000)
  await sleep(1500)
  if (!tmux("ls").includes(S)) throw new Error(`B tmux 里没有 ${S}`)
  ok("B3 本轮跑完（拒绝后 result）→ 收 → tmux --resume 重生")

  // ── C：开关开时不动活着的 tmux 会话
  mark()
  send({ type: "set_cc_config", newSessionTransport: "stream" }); await sleep(800)
  if (!tmux("ls").includes(S)) throw new Error("开关开把 tmux 会话动了")
  if ((await fetch(`http://127.0.0.1:${PORT}/health`)).ok === false) throw new Error("hub 挂了")
  ok("C 开关开 → 活着的 tmux 会话不动")
  const noise = log().split("\n").filter((l) => /can't find window|resize-window failed/.test(l))
  ok(`D 日志无 tmux can't find window（${noise.length} 条）`)
  ws.close()
} catch (e: any) {
  console.error(`\n✗ FAIL: ${e?.message ?? e}`)
  process.exitCode = 1
} finally { await cleanup() }
