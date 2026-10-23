// 交易 T0.5：档案页「跑研究」→ headless 跑 axismundi /research → 研报回投。
// 可靠性走 book-notes 重量档（pending 落盘 → 广播 → ack 删 → 重连补投）；
// spawn 走夜跑姿势（stdout/stderr 文件 fd，不随 hub 生死——管道读端死会让子进程 SIGPIPE 陪葬）；
// 并发走军机处闸（同 symbol 去重 + 全局 1 + 30min 硬顶 + 失败也回帧不让按钮永久灰）。
import { timedSyncFs } from "./block-ledger"
const { writeFileSync, readFileSync, unlinkSync, mkdirSync, existsSync, readdirSync, statSync, openSync, closeSync, renameSync } = timedSyncFs("trading ")
import { join } from "node:path"
import { agentDir } from "./agent-runner.ts"

const AXISMUNDI = process.env.MP_AXISMUNDI_DIR ?? "/Users/susu/Desktop/susu-project/axismundi"
const CLAUDE_BIN = process.env.MP_CLAUDE_BIN ?? "/Users/susu/.local/bin/claude"
const RESEARCH_TIMEOUT_MS = Number(process.env.MP_RESEARCH_TIMEOUT_MS ?? 60 * 60_000)  // 升级路径实测可到 40min+（update 前置+全量），60 硬顶只防挂死
const STAGE_POLL_MS = 3_000
/** 军机处 T2 白名单 + axismundi 特需（venv python / subagent / push——保留 git 环节粟粟拍的） */
const RESEARCH_ALLOWED_TOOLS =
  "Task Bash(.venv/bin/python:*) " +
  "Bash(git diff:*) Bash(git status:*) Bash(git log:*) Bash(git show:*) Bash(git add:*) Bash(git commit:*) Bash(git push:*) " +
  "Bash(ls:*) Bash(cat:*) Bash(head:*) Bash(tail:*) Bash(wc:*) Bash(grep:*) Bash(rg:*) Bash(mkdir:*)"

const researchInFlight = new Set<string>()

/** hub 启动时注册（frame → 广播给全部 mp clients）；未注册（测试）只写 pending。 */
let broadcaster: ((frame: string) => void) | null = null
export function setTradingBroadcaster(fn: ((frame: string) => void) | null): void {
  broadcaster = fn
}

export function tradingResearchBusy(): string | null {
  return researchInFlight.size > 0 ? [...researchInFlight][0] : null
}

// MARK: 纯函数（可测）

/** 裁决版 = frontmatter + 正文第一段（到第一个 \n---\n 分隔符为止）。手机看这个，全文在电脑。
 *  update/earnings 短 note 本身就是全文=digest，正文里的 markdown 分隔线不是附录分隔符，不截。 */
export function extractDigest(md: string): string {
  if (/^type:\s*(update|earnings)/m.test(md.slice(0, 500))) return md
  let bodyStart = 0
  if (md.startsWith("---\n")) {
    const fmEnd = md.indexOf("\n---", 4)
    if (fmEnd >= 0) bodyStart = md.indexOf("\n", fmEnd + 1) + 1
  }
  const cut = md.indexOf("\n---\n", bodyStart)
  return cut >= 0 ? md.slice(0, cut).trimEnd() + "\n" : md
}

/** 质量闸：frontmatter 带 rating 且正文像样；update/earnings 短 note 阈值放低。 */
export function reportLooksValid(md: string): boolean {
  const hasRating = /^rating:\s*\S+/m.test(md.slice(0, 500))
  const isNote = /^type:\s*(update|earnings)/m.test(md.slice(0, 500))
  return hasRating && md.length > (isNote ? 800 : 5_000)
}

/** 财报书架素材：产物 frontmatter 的 filing_files + filings/manifest.json → 帧附件（base64）。
 *  取第一份（一次进一本书，别轰炸书架）；>20MB 跳过（帧安全）。失败返回 null 不挡回投。 */
export function buildFilingAttachment(md: string, symbol: string, dataDate: string): Record<string, unknown> | null {
  try {
    const m = md.slice(0, 800).match(/^filing_files:\s*\[([^\]]*)\]/m)
    if (!m || !m[1].trim()) return null
    const first = m[1].split(",")[0].trim().replace(/^["']|["']$/g, "")
    if (!/^[\w.-]+$/.test(first)) return null
    const dir = join(AXISMUNDI, "desk", "tickers", symbol, "data", dataDate, "filings")
    const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8")) as Array<Record<string, string>>
    const meta = manifest.find((x) => x.filename === first)
    if (!meta) return null
    const buf = readFileSync(join(dir, first))
    if (buf.byteLength > 20 * 1024 * 1024) {
      console.warn(`[hub] filing ${first} 超 20MB，跳过书架回投（Mac 侧仍有原文）`)
      return null
    }
    return { filename: first, format: meta.format, book_name: meta.book_name, data: buf.toString("base64") }
  } catch (e) {
    console.warn(`[hub] filing 附件组装失败（不挡回投）: ${e}`)
    return null
  }
}

/** 找 spawn 之后新产出的研报（mtime >= since 的最新 md）。 */
export function findFreshReport(dir: string, since: number): string | null {
  if (!existsSync(dir)) return null
  let best: { path: string; mtime: number } | null = null
  for (const f of readdirSync(dir)) {
    if (!f.endsWith(".md")) continue
    const p = join(dir, f)
    try {
      const m = statSync(p).mtimeMs
      if (m >= since && (!best || m > best.mtime)) best = { path: p, mtime: m }
    } catch {}
  }
  return best?.path ?? null
}

// MARK: watchlist（app 上报关注列表，夜跑自动档的目标源）

export function saveWatchlist(symbols: unknown, nightly: unknown = null, dir: string = agentDir()): boolean {
  if (!Array.isArray(symbols)) return false
  const clean = symbols.filter((s): s is string => typeof s === "string" && /^[A-Z]{1,5}$/.test(s)).slice(0, 50)
  // 夜跑参数（app 设置是真相源，这里存镜像给 trading-daily 读）：只收白名单字段
  let params: Record<string, unknown> | null = null
  if (nightly && typeof nightly === "object") {
    const n = nightly as Record<string, unknown>
    params = {
      enabled: n.enabled === false ? false : true,
      freshDays: Number.isFinite(Number(n.freshDays)) ? Math.max(1, Math.min(60, Number(n.freshDays))) : 7,
      maxPerNight: Number.isFinite(Number(n.maxPerNight)) ? Math.max(1, Math.min(5, Number(n.maxPerNight))) : 1,
    }
  }
  try {
    writeFileSync(join(dir, "trading-watchlist.json"),
                  JSON.stringify({ symbols: clean, nightly: params, updatedAt: new Date().toISOString() }))
    return true
  } catch (e) {
    console.warn(`[hub] trading_watchlist 写入失败: ${e}`)
    return false
  }
}

// MARK: pending 三件套（book-notes 同构，目录 pending-reports）

// WS 单帧闸门：app 侧上限 64MB，超过这个值的 filing 不 inline（PDF 原件在磁盘，full_path 还在）。
// 超限帧会让 app 1009 断连 → 永不 ack → 重连死循环（2026-08-03 AMD 4.8MB filing 实锤 1659 次循环）。
export const MAX_INLINE_PAYLOAD = 32 * 1024 * 1024

export function deliverTradingReport(payload: Record<string, unknown>, dir: string = agentDir()): boolean {
  const uuid = typeof payload.uuid === "string" ? payload.uuid : ""
  if (!uuid || !/^[\w-]+$/.test(uuid)) return false
  if (payload.filing != null && JSON.stringify(payload).length > MAX_INLINE_PAYLOAD) {
    console.warn(`[hub] trading_report ${uuid.slice(0, 8)} filing 超 ${MAX_INLINE_PAYLOAD >> 20}MB，降级不 inline`)
    payload = { ...payload, filing: null, filing_too_large: true }
  }
  // 只有 ok 的报告值得 pending 持久化；失败帧广播一次即可（app 在场解锁按钮，不在场靠客户端超时兜底）
  if (payload.ok === true) {
    try {
      const pendingDir = join(dir, "pending-reports")
      mkdirSync(pendingDir, { recursive: true })
      writeFileSync(join(pendingDir, `${uuid}.json`), JSON.stringify(payload))
    } catch (e) {
      console.warn(`[hub] trading_report pending 写入失败: ${e}`)
      return false
    }
  }
  broadcaster?.(JSON.stringify({ type: "trading_report_result", ...payload }))
  return true
}

export function pendingTradingReports(dir: string = agentDir()): Record<string, unknown>[] {
  const pendingDir = join(dir, "pending-reports")
  if (!existsSync(pendingDir)) return []
  const out: Record<string, unknown>[] = []
  for (const f of readdirSync(pendingDir)) {
    if (!f.endsWith(".json")) continue
    try {
      // 毒丸防御：超限 pending 永不重投（会锁死 app 重连循环），改名留底人工处理
      if (statSync(join(pendingDir, f)).size > MAX_INLINE_PAYLOAD) {
        renameSync(join(pendingDir, f), join(pendingDir, `${f}.oversize`))
        console.warn(`[hub] trading pending ${f} 超 ${MAX_INLINE_PAYLOAD >> 20}MB，隔离为 .oversize 不重投`)
        continue
      }
      out.push(JSON.parse(readFileSync(join(pendingDir, f), "utf8")))
    } catch {
      try { unlinkSync(join(pendingDir, f)) } catch {}
    }
  }
  return out
}

export function ackTradingReport(uuid: string, dir: string = agentDir()): void {
  if (!/^[\w-]+$/.test(uuid)) return
  try { unlinkSync(join(dir, "pending-reports", `${uuid}.json`)) } catch {}
}

// MARK: 主流程

export async function runTickerResearch(symbol: string, requestId: string, mode: string = "full"): Promise<void> {
  const sym = symbol.toUpperCase()
  if (researchInFlight.has(sym)) return   // 同标的去重（app 侧也闸，双保险）
  const busyWith = tradingResearchBusy()
  if (busyWith) {
    // 全局并发 1：即时回 busy（不进 pending），app 解锁按钮给提示
    broadcaster?.(JSON.stringify({
      type: "trading_report_result", uuid: requestId || `busy-${Date.now()}`,
      symbol: sym, ok: false, error: `研究台正忙（$${busyWith} 在跑），稍后再试`,
    }))
    return
  }
  researchInFlight.add(sym)

  const reportDir = join(AXISMUNDI, "desk", "tickers", sym, "research")
  // auto=增量优先；earnings=财报解读；无报告一律全量兜底
  const hasReports = existsSync(reportDir) && readdirSync(reportDir).some((f) => f.endsWith(".md"))
  const command = !hasReports ? "/research"
    : mode === "earnings" ? "/earnings"
    : (mode === "update" || mode === "auto") ? "/update"
    : "/research"
  console.log(`[hub] ticker_research → ${sym} (${command} mode=${mode})`)
  const stageFile = join(AXISMUNDI, "desk", "tickers", sym, ".research-stage")
  const start = Date.now()
  let lastStage = ""
  let stagePoller: ReturnType<typeof setInterval> | null = null

  try {
    const logPath = join(agentDir(), `research-${sym}.log`)
    const fd = openSync(logPath, "w")
    const proc = Bun.spawn(
      [CLAUDE_BIN, "-p", `${command} ${sym}`,
       "--output-format", "json",
       "--permission-mode", "acceptEdits",
       "--allowedTools", RESEARCH_ALLOWED_TOOLS],
      { cwd: AXISMUNDI, stdout: fd, stderr: fd }
    )
    closeSync(fd)   // 子进程持有自己的 fd 副本
    const killer = setTimeout(() => { try { proc.kill() } catch {} }, RESEARCH_TIMEOUT_MS)

    // 阶段心跳：/research 编排每阶段写 .research-stage 一行，轮询变化即转发
    stagePoller = setInterval(() => {
      try {
        const s = readFileSync(stageFile, "utf8").trim()
        if (s && s !== lastStage) {
          lastStage = s
          const sp = s.indexOf(" ")
          broadcaster?.(JSON.stringify({
            type: "trading_report_progress", symbol: sym,
            stage: sp > 0 ? s.slice(0, sp) : s,
            label: sp > 0 ? s.slice(sp + 1) : "",
          }))
        }
      } catch {}   // 文件还没出现是常态
    }, STAGE_POLL_MS)

    const code = await proc.exited
    clearTimeout(killer)

    const product = findFreshReport(reportDir, start)
    const md = product ? readFileSync(product, "utf8") : ""
    const ok = code === 0 && reportLooksValid(md)
    const filename = product ? product.split("/").pop()! : ""
    const mins = Math.round((Date.now() - start) / 60_000)
    console.log(`[hub] ticker_research ${sym} exit=${code} ok=${ok} ${mins}min → ${filename || "无产物"}`)

    // 财报书架素材（earnings 产物带 filing_files 时）：base64 随帧回投，app 端进书架
    const dataDate = ok ? (md.slice(0, 800).match(/^data_date:\s*(\S+)/m)?.[1] ?? "") : ""
    const filing = ok && dataDate ? buildFilingAttachment(md, sym, dataDate) : null

    deliverTradingReport({
      uuid: requestId || crypto.randomUUID(),
      symbol: sym, ok,
      filename,
      content: ok ? extractDigest(md) : "",
      full_path: ok ? product : "",
      ...(filing ? { filing } : {}),
      error: ok ? null : (code !== 0 ? `研究进程退出码 ${code}（${mins}min）` : "产物缺失或不完整"),
    })
  } catch (e) {
    console.error(`[hub] ticker_research ${sym} 异常: ${(e as Error)?.stack ?? e}`)
    // 静默死教训：异常也必须回帧解锁按钮
    deliverTradingReport({
      uuid: requestId || crypto.randomUUID(),
      symbol: sym, ok: false, filename: "", content: "", full_path: "",
      error: `hub 侧异常：${(e as Error)?.message ?? e}`,
    })
  } finally {
    if (stagePoller) clearInterval(stagePoller)
    try { unlinkSync(stageFile) } catch {}
    researchInFlight.delete(sym)
  }
}
