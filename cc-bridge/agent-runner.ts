// AUTONOMY Phase 1：agent runner + scheduler（plan-autonomy-network P1.3/P1.4/hub 接线）。
// 配置由 app 写 agent/config.json（总开关/楼层开关默认关 = D6），hub 每 tick 读。
import { timedSyncFs } from "./block-ledger"
const { readFileSync, writeFileSync, existsSync, mkdirSync, appendFileSync, openSync, closeSync } = timedSyncFs("agent ")
import { join } from "node:path"
import { homedir } from "node:os"
import { randomUUID } from "node:crypto"
import { Agent } from "./vendor/pi-agent/agent.ts"
import type { Model } from "./vendor/pi-agent/pi-ai-shim.ts"
import { loadTriggers, isDue, renderPrompt, type TriggerSpec } from "./triggers.ts"
import { BudgetLedger, usageToUSD } from "./budget.ts"
import { readerGate, loadReaderMaterial, loadReaderPersona, readerUserName, parseReaderOutput, buildBookNotePayload, appendReaderHistory } from "./reader-daemon.ts"
import { deliverBookNote } from "./book-notes.ts"

export function agentDir(): string {
  // MP_CC_AGENT_DIR：测试隔离用（hub.test.ts 起的子进程绝不读写真实 agent 目录）
  const dir = process.env.MP_CC_AGENT_DIR
    || join(homedir(), "Library", "Application Support", "MemoryPalace", "agent")
  mkdirSync(dir, { recursive: true })
  return dir
}

// MARK: - 配置（app 写，hub 读；缺文件 = 全关）

export interface AgentConfig {
  enabled: boolean
  floors: Record<string, boolean>
  dailyBudgetUSD: number
  pausedUntil?: string
  apiKeyAccount: string
  model: Model<"anthropic-messages">
  /** 共读批注开关（daemon=Agent 自主共读轮 / cc=CC 的 book_note 工具 / vocab=单词在场上行落盘）。缺省全关。 */
  coRead: { daemon: boolean; cc: boolean; vocab: boolean }
}

const DEFAULT_MODEL: Model<"anthropic-messages"> = {
  id: "claude-sonnet-4-5",
  name: "Claude Sonnet 4.5",
  api: "anthropic-messages",
  provider: "anthropic",
  baseUrl: "https://api.anthropic.com",
  reasoning: false,
  input: ["text"],
  cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
  contextWindow: 200_000,
  maxTokens: 8_192,
}

export function loadConfig(dir: string = agentDir()): AgentConfig {
  const defaults: AgentConfig = {
    enabled: false, floors: {}, dailyBudgetUSD: 0.5,
    apiKeyAccount: "anthropic", model: DEFAULT_MODEL,
    coRead: { daemon: false, cc: false, vocab: false },
  }
  const f = join(dir, "config.json")
  if (!existsSync(f)) return defaults
  try {
    const raw = JSON.parse(readFileSync(f, "utf8")) as Partial<AgentConfig>
    return {
      ...defaults, ...raw,
      model: { ...DEFAULT_MODEL, ...(raw.model ?? {}) },
      floors: raw.floors ?? {},
      coRead: { daemon: raw.coRead?.daemon === true, cc: raw.coRead?.cc === true, vocab: raw.coRead?.vocab === true },
    }
  } catch {
    return defaults
  }
}

function isPaused(cfg: AgentConfig, now: Date): boolean {
  return !!cfg.pausedUntil && new Date(cfg.pausedUntil) > now
}

// MARK: - 活动 log（设置页「最近 50 次触发」的数据源）

export function logActivity(entry: Record<string, unknown>, dir: string = agentDir()): void {
  appendFileSync(join(dir, "activity.jsonl"), JSON.stringify({ ts: new Date().toISOString(), ...entry }) + "\n")
}

// MARK: - Keychain（app 与 hub 同一钥匙串，service = KeychainStore.service）

export async function keychainAPIKey(account: string): Promise<string | null> {
  if (process.env.ANTHROPIC_API_KEY) return process.env.ANTHROPIC_API_KEY
  const proc = Bun.spawn(["security", "find-generic-password", "-w",
    "-s", "com.susu.MemoryPalace.apikey", "-a", account])
  const out = await new Response(proc.stdout).text()
  return (await proc.exited) === 0 ? out.trim() : null
}

// MARK: - 单 trigger 执行

export interface RunDeps {
  dir: string
  ledger: BudgetLedger
  getApiKey?: (account: string) => Promise<string | null>
}

export async function runTrigger(spec: TriggerSpec, cfg: AgentConfig, deps: RunDeps): Promise<void> {
  const now = new Date()
  // 楼层开关默认关（D6）：floorId 缺省视为全局 trigger，仍要求总开关
  if (spec.floorId && cfg.floors[spec.floorId] !== true) {
    logActivity({ triggerId: spec.id, status: "skipped-floor-off" }, deps.dir)
    return
  }

  // 共读批注开关（默认关）：闸在 LLM 调用前，关着不跑不花钱
  if (spec.sink === "bookNote" && cfg.coRead.daemon !== true) {
    logActivity({ triggerId: spec.id, status: "skipped-coread-off" }, deps.dir)
    return
  }

  // spawn 型（CR-3）：固定命令，不走 LLM/预算，fire-and-forget 不卡 scheduler tick
  if (spec.action === "spawn") {
    runSpawn(spec, deps)
    return
  }

  let prompt = renderPrompt(spec, now)
  let systemPrompt = "你是记忆宫殿的后台自主 agent。直接输出结果，不要寒暄。"

  // CR-4 ReaderDaemon：gate（她在读让路/没材料不跑）+ 注入阅读材料
  // R1：她的 AI 的人格与记忆随材料上行——daemon 用它当 system prompt（有则替换通用兜底）
  if (spec.contextLoader === "currentBook") {
    const gate = readerGate(deps.dir, now)
    if (!gate.ok) {
      logActivity({ triggerId: spec.id, status: gate.reason }, deps.dir)
      return
    }
    const material = loadReaderMaterial(deps.dir)
    if (!material) {
      logActivity({ triggerId: spec.id, status: "skipped-no-material" }, deps.dir)
      return
    }
    // 通用 app：模板里的 {{user}} 用上行的 Profile.userName 替换（缺省"用户"）
    prompt = `${material}\n\n${prompt.replaceAll("{{user}}", readerUserName(deps.dir))}`
    const persona = loadReaderPersona(deps.dir)
    if (persona) systemPrompt = persona
  }

  // echo 短路：调度验收用，不过 LLM 不烧钱（"echo:" 前缀）
  if (prompt.startsWith("echo:")) {
    logActivity({ triggerId: spec.id, status: "ok", echo: prompt.slice(5).trim(), usd: 0 }, deps.dir)
    return
  }

  if (!deps.ledger.canStart()) {
    logActivity({ triggerId: spec.id, status: "skipped-budget", spentUSD: deps.ledger.spentUSD() }, deps.dir)
    return
  }

  const apiKey = await (deps.getApiKey ?? keychainAPIKey)(cfg.apiKeyAccount)
  if (!apiKey) {
    logActivity({ triggerId: spec.id, status: "error", error: `无 API key（Keychain account=${cfg.apiKeyAccount}）` }, deps.dir)
    return
  }

  const soft = deps.ledger.softWarning()
  const fullPrompt = soft ? `${prompt}\n\n（今日预算将尽，请用最短的方式完成或直接收尾）` : prompt

  const agent = new Agent({
    initialState: { systemPrompt, model: cfg.model, thinkingLevel: "off", tools: [] },
    getApiKey: async () => apiKey,
  })

  try {
    // 总超时守卫（flagellum postmortem 教训：fetch 无 timeout = catch 永远
    // 等不到错误）——LLM/网络挂死会卡住整个 trigger 调度循环（heartbeat 一起停）。
    // 超时 abort（signal 透传到 pi-ai fetch），prompt 以 stopReason=aborted 收尾。
    const watchdog = setTimeout(() => agent.abort(), 180_000)
    try {
      await agent.prompt(fullPrompt)
    } finally {
      clearTimeout(watchdog)
    }
    const msgs = agent.state.messages
    const last = [...msgs].reverse().find((m) => m.role === "assistant") as
      | { role: string; content?: unknown; stopReason?: string; errorMessage?: string
          usage?: { input?: number; output?: number; cacheRead?: number; cacheWrite?: number; cost?: { total?: number } } }
      | undefined

    // ⚠️ pi 的 agent.prompt 对 LLM 失败**不抛错**——把错误塞进 message.stopReason/errorMessage。
    // 不检查就会把 404/401/超限记成 status:ok（真调用冒烟抓到的 bug）。失败按退款处理不计费。
    if (!last || last.stopReason === "error" || last.stopReason === "aborted") {
      const reason = last?.stopReason === "aborted" ? "LLM 调用超时（180s watchdog abort）"
        : (last?.errorMessage ?? "无 assistant 回复")
      logActivity({ triggerId: spec.id, status: "error", error: reason.slice(0, 200) }, deps.dir)
      return
    }

    const text = extractText(last.content)
    // pi 自带按 provider 价目算好的 cost.total，优先用它；缺省再按 Model.cost 兜底估
    const usd = last.usage?.cost?.total ?? usageToUSD(last.usage, cfg.model.cost)
    deps.ledger.charge(spec.id, usd)

    if (spec.sink === "outbox" && spec.floorId) {
      writeOutbox(deps.dir, spec, text, now)
    }
    // CR-4：读书产出解析 → 投递（批注+短消息）。解析失败记 error 不投（宁缺毋滥）。
    if (spec.sink === "bookNote") {
      const output = parseReaderOutput(text)
      if (!output) {
        logActivity({ triggerId: spec.id, status: "error", error: "产出解析失败", usd, preview: text.slice(0, 200) }, deps.dir)
        return
      }
      const payload = buildBookNotePayload(output, deps.dir)
      if (payload && deliverBookNote(payload, deps.dir)) {
        // R3：记共读足迹（下轮材料注入"你上次读到…你当时说…"）
        appendReaderHistory({
          ts: now.toISOString(),
          bookName: String(payload.bookName ?? ""),
          safeName: String(payload.safeName ?? ""),
          chapter: Number(payload.chapter ?? 0),
          comments: output.notes.map((n) => n.comment),
          message: output.message,
        }, deps.dir)
        logActivity({
          triggerId: spec.id, status: "ok", usd,
          preview: `批注×${output.notes.length}${output.message ? " + 消息" : ""}：${(output.notes[0]?.comment ?? output.message).slice(0, 80)}`,
        }, deps.dir)
      } else {
        logActivity({ triggerId: spec.id, status: "error", error: "payload 组装/投递失败", usd }, deps.dir)
      }
      return
    }
    logActivity({ triggerId: spec.id, status: "ok", usd, preview: text.slice(0, 120) }, deps.dir)
  } catch (e) {
    logActivity({ triggerId: spec.id, status: "error", error: String(e).slice(0, 200) }, deps.dir)
  }
}

// MARK: - spawn 型执行（CR-3 续写触发器）

/** 同 trigger 上一轮还没跑完就跳过（vocab 夜跑 30 词可能个把小时） */
const runningSpawns = new Set<string>()

function runSpawn(spec: TriggerSpec, deps: RunDeps): void {
  const cmd = spec.spawnCommand
  if (!cmd || cmd.length === 0) {
    logActivity({ triggerId: spec.id, status: "error", error: "spawn 型缺 spawnCommand" }, deps.dir)
    return
  }
  if (runningSpawns.has(spec.id)) {
    logActivity({ triggerId: spec.id, status: "skipped-already-running" }, deps.dir)
    return
  }
  runningSpawns.add(spec.id)
  try {
    // stdout/stderr 走文件不走管道：管道读端在 hub 进程里，hub 崩溃重启会让跑到一半的
    // 子进程下次 print 时 SIGPIPE 陪葬（07-12/07-20 两次夜跑腰斩的根因）。文件 fd 不随 hub 生死，
    // 完成记录另有脚本自报的 vocab-run 账兜底。
    const logPath = join(deps.dir, `spawn-${spec.id}.log`)
    const fd = openSync(logPath, "w")
    const proc = Bun.spawn(cmd, { stdout: fd, stderr: fd })
    closeSync(fd)   // 子进程持有自己的 fd 副本，父进程这份即关
    logActivity({ triggerId: spec.id, status: "spawned", pid: proc.pid }, deps.dir)
    void (async () => {
      const killer = setTimeout(() => proc.kill(), 4 * 3600_000)  // 4h 硬顶防挂死
      const code = await proc.exited
      clearTimeout(killer)
      runningSpawns.delete(spec.id)
      let tail = ""
      try { tail = readFileSync(logPath, "utf8").slice(-300) } catch {}
      logActivity({
        triggerId: spec.id,
        status: code === 0 ? "ok" : "error",
        exitCode: code,
        preview: tail,   // 脚本末尾是 summary 行，取尾部（stdout/stderr 已合流）
      }, deps.dir)
    })()
  } catch (e) {
    runningSpawns.delete(spec.id)
    logActivity({ triggerId: spec.id, status: "error", error: String(e).slice(0, 200) }, deps.dir)
  }
}

function extractText(content: unknown): string {
  if (typeof content === "string") return content
  if (Array.isArray(content)) {
    return content
      .filter((b) => b && typeof b === "object" && (b as { type?: string }).type === "text")
      .map((b) => (b as { text?: string }).text ?? "")
      .join("\n")
  }
  return ""
}

/** outbox 消息对（D2 outbox+drain；D1 不折叠——app 端按普通消息落库，带 agentOrigin 字段） */
function writeOutbox(dir: string, spec: TriggerSpec, assistantText: string, now: Date): void {
  const outDir = join(dir, "outbox", spec.floorId!)
  mkdirSync(outDir, { recursive: true })
  const uuid = randomUUID()
  const payload = {
    v: 1, uuid, triggerId: spec.id, floorId: spec.floorId,
    createdAt: now.toISOString(),
    userSeed: `（自主任务 · ${spec.id}）`,
    assistantText,
  }
  writeFileSync(join(outDir, `${now.toISOString().replace(/[:.]/g, "-")}-${uuid}.json`), JSON.stringify(payload, null, 1))
}

// MARK: - Scheduler（hub 接线入口）

export function startAgentScheduler(intervalMs = 30_000): () => void {
  const dir = agentDir()
  let since = new Date()
  let busy = false
  console.log(`[agent] scheduler armed（tick=${intervalMs / 1000}s，配置 ${join(dir, "config.json")}）`)

  const timer = setInterval(async () => {
    if (busy) return
    busy = true
    try {
      const now = new Date()
      const cfg = loadConfig(dir)
      if (!cfg.enabled || isPaused(cfg, now)) { since = now; return }
      const triggers = loadTriggers(join(dir, "triggers.json"))
      const ledger = new BudgetLedger(dir, cfg.dailyBudgetUSD)
      for (const spec of triggers) {
        if (isDue(spec, since, now)) {
          await runTrigger(spec, cfg, { dir, ledger })
        }
      }
      since = now
    } catch (e) {
      console.warn(`[agent] tick 失败: ${e}`)
    } finally {
      busy = false
    }
  }, intervalMs)
  return () => clearInterval(timer)
}
