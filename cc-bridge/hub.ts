import { VoiceCalls } from "./voice-calls.ts"
import { WebSocketServer, WebSocket } from "ws"
import { createServer, IncomingMessage, ServerResponse } from "node:http"
import { spawn } from "node:child_process"
import { mkdir, readdir, readFile, stat, unlink } from "node:fs/promises"
import { DirtyDirScanner } from "./dir-watch"
import { blockLedger, describeLagVitals, procSample, timedExecFileSync, timedSyncFs, timeHandler, wsSite } from "./block-ledger.ts"
import { networkInterfaces, homedir, hostname, loadavg } from "node:os"
import { join, basename, extname } from "node:path"
import { LaPayloadTooLargeError, type APNsResult, type LaEvent, sendAPNs, sendLiveActivityAPNs, sendVoIPAPNs } from "./apns.ts"
import { type CCActivityState, validateContentState } from "./activity-state.ts"
import { bundleAllowed, parseAllowedBundles } from "./client-bundles.ts"
import { openRelayIngress, prepareRelaySocket, relayIngressRequests, relaySocketPath } from "./relay-ingress.ts"
import { loadRelayConfig, relayPhoneURL } from "./relay-config.ts"
import { runConnectorMain } from "./relay-connector.ts"
import { isDeadAlertResult, loadPushTokens as readPushTokens, normalizePushInfo, normalizeTopic, savePushTokens as writePushTokens, type PushInfo } from "./push-tokens.ts"
import { emptyLaTokenStore, loadLaTokens, saveLaTokens, registerLaToken, unregisterLaToken, tokenTail, type LaStartRecord, type LaTokenStore, type LaUpdateRecord } from "./live-activity-tokens.ts"
import {
  createLaScheduler, type LaScheduler, type LaUsageSnapshot,
} from "./live-activity-scheduler.ts"
import {
  reducePhase, buildPhaseContentState, loadLaPhase, runLaWatchdog, saveLaPhase,
  type LaPhaseEvent, type LaPhaseSnapshot,
} from "./live-activity-phase.ts"
import { shouldRemoteStart, buildStartEvent } from "./live-activity-start.ts"
import { agentDir, loadConfig as loadAgentConfig } from "./agent-runner.ts"
import { setBookNoteBroadcaster, pendingBookNotes, ackBookNote, deliverBookNote } from "./book-notes.ts"
import {
  initAskUser, handleHookEvent as handleAskUserHook, resolveOnReply as askUserResolveOnReply,
  clearForSession as askUserClearForSession, getPending as askUserPending, pendingList as askUserPendingList,
  askUiAlive, driveAnswer as askUserDrive, markDriven as askUserMarkDriven, formatAnswers as askUserFormatAnswers,
  questionFramePayload as askUserQuestionFrame, resolveDeclined as resolveAskUserDeclined,
  resolvedFrames as askUserResolvedFrames,
  registerExternalQuestion as askUserRegisterExternal, resolveExternal as askUserResolveExternal,
  type AskAnswer, type AskUserIO, type PendingAskUser,
} from "./askuser.ts"
import { parseReaderOutput, buildBookNotePayload } from "./reader-daemon.ts"
import { ccWorkdir, codexWorkdir, ccProjectSlug } from "./cc-workdir.ts"
import {
  BindPrefsCache, type HubConfig, type MachineInfo, type ToolAvailability, buildHelloPayload, buildMcpConfig, detectTools, listDirs,
  loadHubConfig, pickMcpConfig, readMachineInfo, resolveAgentWorkdir, sameDir, saveHubConfig, saveJsonPrivate, validateWorkdir,
} from "./hub-config.ts"
import { CC_MEMORY_DIR, ccMemorySnapshots, fetchFrames, manifest as ccMemoryManifest, MemoryReplies, watchMemoryDir } from "./cc-memory-sync.ts"
import { buildTerminalUsagePayload, readTranscriptUsage, readRateLimits, contextWindowFor } from "./terminal-usage.ts"
import { buildTerminalInitPayload, parseMouseAnyFlag } from "./terminal-init.ts"
import { buildPasteResultPayload, pasteToTmux, type PasteResult } from "./terminal-paste.ts"
import { buildFreshTerminalLaunch, type TerminalLaunch } from "./terminal-launch.ts"
import { TerminalSizeTracker, type TerminalSize } from "./terminal-size.ts"
import {
  type TerminalEngine, type TerminalWindow, type TerminalStateSource, buildTerminalStatePayload,
  sessionNameFor, isWindowSession, codeFromSession, newWindowCode, resolveTerminalTitle, resolveWindowTitle,
  codexPhaseFromActivity, type TerminalPhase,
  addWindow, closeWindow as markWindowClosed, endWindow, endWindowAfterKill, restoreWindow, openWindows, liveWindows,
  loadWindows, saveWindows, setWindowCustomTitle,
} from "./terminal-windows.ts"
import {
  hasValidAgoraToken,
  openAgoraProtocol,
  type AgoraOwnerMentionNotification,
} from "./agora-protocol.ts"
import { AgoraCCExecutor } from "./agora-cc-executor.ts"
import { AgoraStoreError } from "./agora-types.ts"
import { StreamRunner, type ControlRequest, type ControlVerdict, type Respond } from "./stream-runner.ts"
import { StreamTurnTracker, planTransportReconcile, type LiveSession } from "./stream-turn.ts"
import { extractLastChannelTurnFromFile, readTailAsync, parseRows, undeliveredRows, fitRows, type TextRow } from "./turn-extract.ts"
import { ModelPrefs, cliModelFor, parseModelCommand, pickLaunchModel, planModelRecovery, readModelEventWithin, shellQuote, DEFAULT_MODEL_MARK, type LaunchModel } from "./cc-model"
import { buildSessionModelFrame, carryContextSuffix, CodexRolloutIndex, SessionModelTracker } from "./session-model"
import { correctChatId } from "./chat-id-guard.ts"
import { planReap, reapLogLine, reapThresholdMs, reapUnknownLogLine } from "./session-reap"
import { effortArg, effortChange, normalizeEffort } from "./effort.ts"
import { buildSessionPhaseFrame, phaseFrameChanged, sendPhaseAfter, sessionPhaseSnapshotFrames } from "./session-phase.ts"
import { ToolActivityTracker } from "./tool-activity.ts"
// #if PERSONAL_APPS
import { setTradingBroadcaster, pendingTradingReports, ackTradingReport, runTickerResearch, saveWatchlist } from "./trading-research.ts"
import { openIndexerWithRetry, WarroomIndexer } from "./warroom-indexer.ts"
import { k2Enabled, WarroomScanWorker, warroomScanRunner } from "./warroom-scan-client"
import { WarroomLedger, TargetBusy, retryBusy, type TaskRow } from "./warroom-ledger.ts"
import { WarroomDispatcher, realSpawnT2, type TargetInfo } from "./warroom-dispatch.ts"
import { PM_FRAMES, pmRelay } from "./pm-relay.ts"
import { TmuxState, parsePaneTitles, parsePaneMeta, TMUX_PANES_ARGS, type PaneMeta } from "./tmux-state.ts"
import { PaneStream } from "./tmux-pane-stream.ts"
import { chainTmuxWrite, fetchPanes, k1Enabled, sharedTmuxControl, startSharedTmuxControl, TmuxCommandError, TmuxUncertainError, tmuxLoadBuffer, tmuxRun, tmuxRunCounts, waitTmuxWriteSettled } from "./tmux-control"
import { findCodexRollout, locateEditArea, SendStatusBook, transcriptCursor, type EditArea, type SendStatusFrame, type TranscriptCursor } from "./send-verify"
import { SendTracker, type InjectResult } from "./send-track"
import { LagLog, classifyConnect, classifyTerminalOpen, parseConnectReport, parseTerminalReport, appendLedger, FAST_MS } from "./connect-ledger.ts"
import {
  buildInspectorPrompt, buildInspectorCommand, parseVerdict, buildReworkTask, buildDeskNotice,
  reworkDepth, type EvidencePack,
} from "./warroom-inspector.ts"
// #endif

// 阻塞调用账（plan-hub-perf §3.2）：主线程上的同步 tmux / 文件调用全部计时，卡顿时按调用点归因。只计时，行为不变。
// 账本和包装在 block-ledger.ts：hub 带起来的各模块（warroom / agora / 账本…）记进同一本
export { blockLedger }
const execFileSync = timedExecFileSync()
const { unlinkSync, existsSync, readFileSync, writeFileSync, mkdirSync, copyFileSync, statSync, readdirSync, appendFileSync, renameSync } = timedSyncFs("")

// #if PERSONAL_APPS
// 军机处 M0：普查 indexer（startHub 里初始化；null = 未就绪，端点回 503）
let warroomIndexer: WarroomIndexer | null = null
let warroomLastScan: { at: string; scanned: number; changed: number; ms: number } | null = null
// 军机处 M1：奏折账本 + 派发器
let warroomLedger: WarroomLedger | null = null
let warroomDispatcher: WarroomDispatcher | null = null
// dispatch 权限：只有中枢会话（御前）能开/派奏折。header 可伪造无妨——端点本身 loopback+token。
function warroomCentralSessions(): Set<string> {
  const base = ["mp-cc", "mp-cc-6", "mp-cc-2521523d"]
  const extra = (process.env.MP_WARROOM_CENTRAL ?? "").split(",").map(s => s.trim()).filter(Boolean)
  return new Set([...base, ...extra])
}
const WARROOM_DESK_SESSION = process.env.MP_WARROOM_DESK ?? "mp-cc-2521523d"
/** M3：看板快照（app WS 拉取）。奏折按板块分好，统计一并给。 */
export function warroomBoardSnapshot(): object {
  if (!warroomLedger || !warroomIndexer) return { ready: false, tasks: [], stats: {} }
  const tasks = warroomLedger.queryTasks({ limit: 50 }).map(t => {
    let receiptObj: any = null
    try { receiptObj = t.receipt ? JSON.parse(t.receipt) : null } catch {}
    // M5.1/M5.2：可 resume 的完整 uuid——resume/tmux 单查普查表；
    // repo 单用它出生的新会话 id（收据里的 session_id），干完活还能被她 resume 接着聊
    const resumeId = t.target_kind !== "repo"
      ? (warroomLookupTarget(t.target_ref)?.sessionId ?? null)
      : (typeof receiptObj?.session_id === "string" ? receiptObj.session_id : null)
    return {
      task_id: t.task_id, title: t.title, status: t.status, approval: t.approval,
      target_ref: t.target_ref, engine: t.engine, created_by: t.created_by,
      resume_id: resumeId,
      target_kind: t.target_kind,
      parent_task: t.parent_task, epic: t.epic, depends_on: t.depends_on,
      created_at: t.created_at, done_at: t.done_at,
      cost_usd: Math.round(t.cost_usd * 100) / 100,
      verdict: t.verdict ? (() => { try { return JSON.parse(t.verdict!) } catch { return null } })() : null,
      receipt_summary: receiptObj ? String(receiptObj.result ?? receiptObj.summary ?? "").slice(0, 400) : null,
    }
  })
  // M5.2 任务导向布局：需求（EPIC 根）也下发——app 按需求分组显示进度
  const requests = warroomLedger.db.query(
    "SELECT request_id, text, status, created_at FROM requests ORDER BY created_at DESC LIMIT 20").all()
  const s = warroomIndexer.db.query(
    `SELECT COUNT(*) as total,
            SUM(alive) as alive,
            SUM(CASE WHEN alive=1 AND tmux_session IS NULL THEN 1 ELSE 0 END) as zombies
     FROM sessions`).get() as any
  const cost = warroomLedger.db.query("SELECT COALESCE(SUM(cost_usd),0) as c FROM tasks").get() as any
  return {
    ready: true, tasks, requests,
    stats: { sessions_total: s?.total ?? 0, sessions_alive: s?.alive ?? 0, zombies: s?.zombies ?? 0, total_cost_usd: Math.round((cost?.c ?? 0) * 100) / 100 },
  }
}

/// 定时轮（K3 审查 R1-6）：前半（异步）没跑完时下一 tick 整轮跳过；后半一定排在本轮前半之后。
/// 前半抛了照跑后半（只记一行），返回 false = 这一 tick 跳过了
export function serialRound(first: () => Promise<unknown>, then: () => void, onError: (e: unknown) => void): () => boolean {
  let running = false
  return () => {
    if (running) return false
    running = true
    void first().catch(onError).then(() => { running = false; then() }).catch(onError)
    return true
  }
}

/// T1 交卷检测（K3）：只看在等收据的单（dispatched / working）各自的 receipts/<task_id>.json，异步读；
/// 没单在等就不碰盘（原来每 30s 同步列整个目录）。一轮最多看 limit 单，按 task_id 游标轮转（审查 R1-3：
/// 只看最新的会饿死旧单），cursor 由调用方跨轮保存。返回这次收下几份
export async function scanT1Receipts(ledger: WarroomLedger, receiptDir: string, cursor = { after: "" }, limit = 500): Promise<number> {
  const page = (after: string) => ledger.db.query(
    "SELECT task_id FROM tasks WHERE status IN ('dispatched', 'working') AND task_id > ? ORDER BY task_id LIMIT ?",
  ).all(after, limit) as Array<{ task_id: string }>
  let waiting = page(cursor.after)
  if (waiting.length < limit && cursor.after) waiting = [...waiting, ...page("").filter((t) => t.task_id <= cursor.after)].slice(0, limit)
  cursor.after = waiting.length === limit ? waiting[waiting.length - 1].task_id : ""
  let n = 0
  for (const { task_id: taskId } of waiting) {
    const f = `${taskId}.json`
    let raw: string
    try { raw = await readFile(join(receiptDir, f), "utf8") } catch { continue }
    const task = ledger.getTask(taskId)
    if (!task || (task.status !== "dispatched" && task.status !== "working")) continue
    try {
      const receipt = JSON.parse(raw)
      await retryBusy(() => ledger.acceptReceipt(taskId, receipt, "t1-receipt", "evidence_in", "hub", "t1 receipt file arrived"))
      console.log(`[warroom] t1 receipt: ${taskId} → evidence_in`)
      n++
    } catch (e: any) { console.warn(`[warroom] bad receipt ${f}: ${e?.message}`) }
  }
  return n
}

/** 普查表 → TargetInfo（session_id 精确/前缀，或 tmux 名） */
function warroomLookupTarget(ref: string): TargetInfo | null {
  if (!warroomIndexer) return null
  const row = warroomIndexer.db.query(
    `SELECT session_id, engine, alive, tmux_session, cwd, transcript_path FROM sessions
     WHERE session_id = ?1 OR session_id LIKE ?1 || '%' OR tmux_session = ?1
     ORDER BY last_active_at DESC LIMIT 1`
  ).get(ref) as any
  if (!row) return null
  return {
    sessionId: row.session_id, engine: row.engine,
    alive: row.alive === 1, tmuxSession: row.tmux_session,
    cwd: row.cwd, transcriptPath: row.transcript_path,
  }
}
// #endif

// CR-2 阅读在场信号：app 上报的快照落 agent/reading-status.json（消费在 CR-4 触发时机判断）。
// 形状校验 + 尺寸上限，防畸形消息写爆。导出供测试。
export function writeReadingStatus(status: Record<string, unknown>, dir: string = agentDir()): boolean {
  try {
    const json = JSON.stringify(status)
    if (json.length > 10_000) {
      console.warn(`[hub] reading_status 过大（${json.length}B），丢弃`)
      return false
    }
    writeFileSync(join(dir, "reading-status.json"), json)
    return true
  } catch (e) {
    console.warn(`[hub] reading_status 写入失败: ${e}`)
    return false
  }
}

// L2 单词在场信号：app 刷词/复习/收词时上报快照 → 落 agent/vocab-status.json。
// 开关 coRead.vocab（缺省关）在帧分支查，关 = 不落盘。导出供测试。
export function writeVocabStatus(status: Record<string, unknown>, dir: string = agentDir()): boolean {
  try {
    const json = JSON.stringify(status)
    if (json.length > 10_000) {
      console.warn(`[hub] vocab_status 过大（${json.length}B），丢弃`)
      return false
    }
    writeFileSync(join(dir, "vocab-status.json"), json)
    return true
  } catch (e) {
    console.warn(`[hub] vocab_status 写入失败: ${e}`)
    return false
  }
}

// 发语音条：app 上报生成成功的语音条 → 追加写 cc-rp 的「小克的语音条.md」，
// 小克可以自己翻/搜"自己说过的话"。追加制，超 400KB 轮转 .old 防无限增长。导出供测试。
export function appendVoiceNote(
  note: Record<string, unknown>,
  file?: string,
): boolean {
  try {
    const script = typeof note.script === "string" ? note.script.trim() : ""
    if (!script || script.length > 4000) {
      console.warn(`[hub] voice_note 脚本为空或过大，丢弃`)
      return false
    }
    const speaker = typeof note.speaker === "string" && note.speaker ? note.speaker : ccConfig.pushName
    file ??= join(ccWorkdir(), `${speaker.replace(/[\/:]/g, "_")}的语音条.md`)
    const voice = typeof note.voice === "string" && note.voice ? ` · 声音「${note.voice}」` : ""
    const dur = typeof note.duration === "number" && (note.duration as number) > 0 ? `（${Math.round(note.duration as number)} 秒）` : ""
    const stamp = new Date().toLocaleString("sv-SE").slice(0, 16) // 本地时区 "2026-07-12 10:32"
    if (existsSync(file) && statSync(file).size > 400_000) {
      renameSync(file, file + ".old")
    }
    if (!existsSync(file)) {
      appendFileSync(file, `# ${speaker}的语音条\n\napp 里每条生成成功的语音条都记在这（时间 · 声音 · 表演脚本）。\n`)
    }
    appendFileSync(file, `\n## ${stamp} · ${speaker}${voice}${dur}\n\n${script}\n`)
    return true
  } catch (e) {
    console.warn(`[hub] voice_note 写入失败: ${e}`)
    return false
  }
}

// 楼层语音设置 → cc-rp CLAUDE.md 标记块（docs/plan-cc-terminal-mirror.md 二-b）：只替换两个标记之间，
// 标记外是粟粟手写的，不碰。内容没变不写；找不到标记不写；临时文件 + rename 防写一半。导出供测试。
export const MP_VOICE_BEGIN = "<!-- mp-voice:begin -->"
export const MP_VOICE_END = "<!-- mp-voice:end -->"
export function writeVoiceInstructions(
  content: unknown,
  file: string = join(ccWorkdir(), "CLAUDE.md"),
): { ok: boolean; changed?: boolean; reason?: string } {
  if (typeof content !== "string" || Buffer.byteLength(content, "utf8") > 8192
      || content.includes(MP_VOICE_BEGIN) || content.includes(MP_VOICE_END)) {
    console.warn(`[hub] set_voice_instructions 内容非法（非字符串/超 8KB/含标记），丢弃`)
    return { ok: false, reason: "invalid_content" }
  }
  try {
    const text = existsSync(file) ? readFileSync(file, "utf8") : ""
    const b = text.indexOf(MP_VOICE_BEGIN)
    const e = b < 0 ? -1 : text.indexOf(MP_VOICE_END, b + MP_VOICE_BEGIN.length)
    if (e < 0) {
      console.warn(`[hub] set_voice_instructions：${file} 里没找到 mp-voice 标记，不写`)
      return { ok: false, reason: "no_markers" }
    }
    const inner = content.trim() ? `\n${content.trim()}\n` : "\n"
    const next = text.slice(0, b + MP_VOICE_BEGIN.length) + inner + text.slice(e)
    if (next === text) return { ok: true, changed: false }
    const tmp = `${file}.mp-voice-${process.pid}.tmp`
    writeFileSync(tmp, next)
    renameSync(tmp, file)
    console.log(`[hub] set_voice_instructions → ${file} 已更新（${Buffer.byteLength(content, "utf8")}B）`)
    return { ok: true, changed: true }
  } catch (err) {
    console.warn(`[hub] set_voice_instructions 写入失败: ${err}`)
    return { ok: false, reason: "write_failed" }
  }
}

// CR-4 P1 阅读上下文缓存：app 换章推送章文本 → 单文件覆盖（AI 只读她最近读的那一章）。
// 章文本上限 300KB（app 侧已截 60K 字符，这里兜底防畸形）。导出供测试。
export function writeReadingContext(ctx: Record<string, unknown>, dir: string = agentDir()): boolean {
  try {
    const json = JSON.stringify(ctx)
    if (json.length > 300_000) {
      console.warn(`[hub] reading_context 过大（${json.length}B），丢弃`)
      return false
    }
    writeFileSync(join(dir, "reading-context.json"), json)
    return true
  } catch (e) {
    console.warn(`[hub] reading_context 写入失败: ${e}`)
    return false
  }
}

// CR-4 P1 下行投递挪到 book-notes.ts（避免 hub ↔ agent-runner 循环 import）；
// hub 在 wss 建立后注册 broadcaster（见 setBookNoteBroadcaster 调用处）。

// CR-4.5 R5：iOS 看 agent 状态（config/今日用量/活动 tail）——iOS 沙盒读不到 Mac
// 文件（N-D9），经 WS 拉取。导出供测试。
export function agentStatusSnapshot(dir: string = agentDir()): Record<string, unknown> {
  const cfg = loadAgentConfig(dir)
  const day = new Date().toISOString().slice(0, 10)
  let spentUSD: number | null = null
  try {
    const b = JSON.parse(readFileSync(join(dir, `budget-${day}.json`), "utf8"))
    if (typeof b.spentUSD === "number") spentUSD = b.spentUSD
  } catch {}
  let activity: Record<string, unknown>[] = []
  try {
    activity = readFileSync(join(dir, "activity.jsonl"), "utf8")
      .split("\n").filter(Boolean).slice(-50).reverse()
      .map((l) => { try { return JSON.parse(l) } catch { return null } })
      .filter((x): x is Record<string, unknown> => !!x)
  } catch {}
  return {
    config: {
      enabled: cfg.enabled, floors: cfg.floors,
      dailyBudgetUSD: cfg.dailyBudgetUSD, pausedUntil: cfg.pausedUntil ?? null,
      coRead: cfg.coRead,
      // R6：读书模型显示（iOS 设置-读书页）
      model: { id: cfg.model.id, name: cfg.model.name },
    },
    spentUSD, activity,
  }
}

/** R6.1 key 随设置同步：iPhone 的卡 key 不在 Mac Keychain（两台不同 iCloud
 *  钥匙串不互通），iOS 选读书模型时补丁带上 key → 写进本机 Keychain
 *  （keychainAPIKey 同一 service），不落 config.json 明文。 */
export function writeKeychainKey(account: string, key: string): boolean {
  const r = Bun.spawnSync(["security", "add-generic-password", "-U",
    "-s", "com.susu.MemoryPalace.apikey", "-a", account, "-w", key])
  const ok = r.exitCode === 0
  console.log(ok
    ? `[hub] api key synced → keychain account=${account.slice(0, 12)}…`
    : `[hub] api key sync 失败 account=${account} exit=${r.exitCode}`)
  return ok
}

/** iOS 改开关/预算/暂停 → 读-改-写 config.json。只覆盖收到的键，
 *  保留 model/apiKeyAccount 等 hub 侧字段（config 抹字段活雷的教训）。 */
export function applyAgentConfigPatch(
  patch: Record<string, unknown>, dir: string = agentDir(),
  keychainWriter: (account: string, key: string) => boolean = writeKeychainKey,
): boolean {
  const path = join(dir, "config.json")
  let dict: Record<string, unknown> = {}
  try { dict = JSON.parse(readFileSync(path, "utf8")) } catch {}
  if (typeof patch.enabled === "boolean") dict.enabled = patch.enabled
  if (patch.floors && typeof patch.floors === "object") dict.floors = patch.floors
  if (typeof patch.dailyBudgetUSD === "number" && patch.dailyBudgetUSD >= 0) dict.dailyBudgetUSD = patch.dailyBudgetUSD
  // 共读批注开关（daemon/CC/vocab 三路，缺省全关）
  if (patch.coRead && typeof patch.coRead === "object") {
    const c = patch.coRead as Record<string, unknown>
    dict.coRead = { daemon: c.daemon === true, cc: c.cc === true, vocab: c.vocab === true }
  }
  if (patch.pausedUntil === null) delete dict.pausedUntil
  else if (typeof patch.pausedUntil === "string") dict.pausedUntil = patch.pausedUntil
  // R6 读书模型（iOS 设置-读书写入）：形状校验 id/api/baseUrl 必填
  if (patch.model && typeof patch.model === "object") {
    const m = patch.model as Record<string, unknown>
    if (typeof m.id === "string" && typeof m.api === "string" && typeof m.baseUrl === "string") {
      dict.model = m
    }
  }
  if (typeof patch.apiKeyAccount === "string" && patch.apiKeyAccount) dict.apiKeyAccount = patch.apiKeyAccount
  // R6.1：key 只进 Keychain，绝不落 config（也绝不留在 dict 里）
  if (typeof patch.apiKey === "string" && patch.apiKey &&
      typeof patch.apiKeyAccount === "string" && patch.apiKeyAccount) {
    keychainWriter(patch.apiKeyAccount, patch.apiKey)
  }
  delete dict.apiKey
  try {
    writeFileSync(path, JSON.stringify(dict, null, 1))
    return true
  } catch (e) {
    console.warn(`[hub] agent config patch 写入失败: ${e}`)
    return false
  }
}

/// 进程起来时的 PATH。Bun 里 fork 出的子进程（execFileSync / Bun.spawn 不传 env）拿的是这一份，看不到下面对 process.env 的改动（10-11 实测）；
/// 所以原来 fork 建的 tmux 会话里 claude 的 PATH 一直是它。控制连接建会话要显式 -e 同一个（K1-4，见 realTmuxRunner.spawn）
const FORK_CHILD_PATH = process.env.PATH ?? ""
// PATH 增强：Mac app 走 launchctl/Process.run() 启动子进程时 PATH 不含 brew/npm 安装路径，
// 即使用户装了 tmux/claude 也找不到。这里 prepend 三大装机目录（brew arm64/x86 + npm global + bun）。
process.env.PATH = `/usr/local/bin:/opt/homebrew/bin:${process.env.HOME ?? ""}/.bun/bin:${process.env.HOME ?? ""}/.local/bin:${process.env.PATH ?? ""}`

// 端口可 env 覆盖：传 0 让 OS 分配（Mac app 集成模式），第一个 listen 完拿真实端口写 stdout。
// 测试必须用随机端口隔离，严禁绑/连生产 7890（2026-06-11 /clear 事故）。
// 用 let 而非 const，因为 PORT=0 时第一个 listen 完成后要更新成真实端口供后续 listener 用。
let PORT = Number(process.env.MP_CC_HUB_PORT ?? 7890)
const TMUX_SESSION = process.env.MP_CC_TMUX_SESSION ?? "mp-cc"
// CC 的 model 必须 spawn 时显式传：--resume 恢复会丢 /model 设的 [1m]（1M context）
// 后缀，而 --model flag 优先级最高，fresh/resume 都强制生效（实测 contextWindow=1000000）。
const CC_MODEL = process.env.MP_CC_MODEL ?? "claude-opus-4-6[1m]"
// 回复改走文本（docs/plan-strip-thinking.md 十-10.2）：开了的会话，channel 标签后带一句「直接文字回答」，
// Stop hook 把当轮正文投到 /thinking 的 reply_text，省掉 reply 工具之后那趟全上下文空调用（cc-rp 21%）。
// 值：空=关；"all"=全部；逗号分隔 session 名=只对这些开（canary）。改完重启 hub。
const REPLY_VIA_TEXT = (process.env.MP_CC_REPLY_VIA_TEXT ?? "all").trim()   // 缺省全开：带终端也直接说话（省 reply 工具那趟空调用）
// 钉死新会话传输（"tmux"/"stream"）：设了就忽略 app 发来的全局开关，逐条仍可在长按菜单里单独设。
// 09-20：流式只在测试对话用，但全局开关还开着，她新开的对话默认成了不带终端。
const TRANSPORT_LOCK = (process.env.MP_CC_DEFAULT_TRANSPORT ?? "").trim()
export function replyViaTextFor(session: string | undefined): boolean {
  // 不带终端（stream）的会话天然走文本：逐字流式就是靠正文直出（十二）。看**实际在跑的形态**而不是策略/开关
  // （09-20：会话本身是 stream，全局开关被另一台设备发回 tmux，判成不该直接说话）
  if (session && (streamRunner.has(session) || (sessionEngine(session) === "claude" && transportOf(session) === "stream"))) return true
  if (!REPLY_VIA_TEXT) return false
  if (REPLY_VIA_TEXT === "all") return true
  return !!session && REPLY_VIA_TEXT.split(",").map(x => x.trim()).includes(session)
}
const REPLY_VIA_TEXT_HINT = " 直接用文字回答即可，不要调用 reply 工具（要发文件、引用某条、或没人问你时主动开口才用 reply）。"
const HUB_HOST = process.env.MP_CC_HUB_HOST ?? "127.0.0.1"
// Token 来源优先级：MP_CC_HUB_TOKEN 直接值 > MP_CC_HUB_TOKEN_FILE 读文件
// systemd / Docker secrets / 一般 "把 token 写文件" 部署模式靠后者。
let HUB_TOKEN = process.env.MP_CC_HUB_TOKEN
if (!HUB_TOKEN && process.env.MP_CC_HUB_TOKEN_FILE) {
  try {
    HUB_TOKEN = readFileSync(process.env.MP_CC_HUB_TOKEN_FILE, "utf8").trim()
  } catch (e) {
    console.error(`[hub] failed to read MP_CC_HUB_TOKEN_FILE=${process.env.MP_CC_HUB_TOKEN_FILE}: ${(e as Error).message}`)
  }
}
const ALLOWED_BUNDLES = parseAllowedBundles(process.env.MP_CC_ALLOWED_BUNDLES)
// 持久文件目录可 env 重定向：测试必须指到临时目录，绝不写生产 secrets/
// （reply/thinking log 会在 hub 重启后 replay 进 app，测试数据混进去=垃圾回放）
const SECRETS_DIR = process.env.MP_CC_SECRETS_DIR ?? join(import.meta.dir, "secrets")
try { mkdirSync(SECRETS_DIR, { recursive: true }) } catch {}

// ── #046 T3：hub 配置（[+] 窗口的干活目录 / 内嵌 hub 端口）+ hello 帧的素材 ──
const hubConfigPath = join(SECRETS_DIR, "hub-config.json")
let hubConfig: HubConfig = loadHubConfig(hubConfigPath)
/// 内嵌 hub（Mac App）用的 mcp 配置：listen 拿到真实端口后才写（见 writeGeneratedMcpConfig）
const generatedMcpConfigPath = join(SECRETS_DIR, "mcp.json")
const HUB_VERSION = "t3"
const HUB_CAPABILITIES = ["hello", "dirs", "list_dirs", "end_window", "terminal_seen", "terminal_active", "terminal_paste"]
let machineInfo: MachineInfo | null = null
let toolAvailability: ToolAvailability = { tmux: null, claude: null, codex: null }

function agentWorkdirSetting(): string | null {
  return hubConfig.agent_workdir ?? null
}

/// 内嵌 hub（Mac App 给了 MP_CC_MCP_SERVER_BIN）：把连本 hub 真实端口的 mcp 配置写进状态目录。
/// launchd hub 没这个 env，什么都不写，照旧用 cc-bridge/.mcp.json。
/// 只认这次启动写成功的那份：没给二进制 / 写失败 → null，对话 Agent 不带 --mcp-config（不用上次留下的旧端口配置）
let generatedMcpConfigThisBoot: string | null = null
function writeGeneratedMcpConfig(token: string | undefined): void {
  generatedMcpConfigThisBoot = null
  const bin = process.env.MP_CC_MCP_SERVER_BIN
  if (!bin || !existsSync(bin)) return
  try {
    saveJsonPrivate(generatedMcpConfigPath, buildMcpConfig(bin, PORT, token))
    generatedMcpConfigThisBoot = generatedMcpConfigPath
  } catch (e: any) {
    console.warn(`[hub] mcp 配置写不进去，对话 Agent 不带 MCP: ${e?.message}`)
  }
}

export function isLoopback(addr: string | undefined): boolean {
  if (!addr) return false
  return addr === "127.0.0.1" || addr === "::1" || addr === "::ffff:127.0.0.1"
}

// 代理 / 隧道转进来的请求在 TCP 层也是 127.0.0.1，光看来源地址不够（#068 P0）。
// 这些头按「存在」判定（空值也算），不看值。
const FORWARDING_HEADERS = ["x-forwarded-for", "forwarded", "x-real-ip", "cf-connecting-ip", "true-client-ip"]
const LOCAL_HOST_NAMES = new Set(["127.0.0.1", "localhost", "[::1]"])

/// 「本机进程直连」才算本机：来源是 loopback，且没有转发头（代理 / 隧道）、没有 Origin / Sec-Fetch-*（浏览器网页）、
/// Host 是本机名（挡 DNS rebinding）。不加头的 TCP 隧道（frp tcp、ssh -R）挡不住，见 docs/plan-remote-relay.md §3。
export function isTrustedLocal(req: Pick<IncomingMessage, "socket" | "headers">): boolean {
  if (!isLoopback(req.socket.remoteAddress)) return false
  if (relayIngressRequests.has(req)) return false
  const h = req.headers
  if (FORWARDING_HEADERS.some((k) => k in h)) return false
  if ("origin" in h || Object.keys(h).some((k) => k.startsWith("sec-fetch-"))) return false
  return LOCAL_HOST_NAMES.has((h.host ?? "").toLowerCase().replace(/:\d+$/, ""))
}

// 探测本机网卡，按 IP 段分类：Tailscale(100.64-127)/LAN(192,10,172.16-31)/loopback。
// nets 可注入便于测试。出国后 Tailscale 常晚于 hub 启动，故设计成可重复调用（hub 定期重检自愈）。
export function detectInterfaces(nets = networkInterfaces()): { loopback: string; lan?: string; tailscale?: string } {
  let lan: string | undefined, tailscale: string | undefined
  for (const addrs of Object.values(nets)) {
    for (const a of addrs ?? []) {
      if (a.family !== "IPv4" || a.internal) continue
      const o = a.address.split(".").map(Number)
      if (o[0] === 100 && o[1] >= 64 && o[1] <= 127) tailscale ??= a.address      // Tailscale CGNAT
      else if (o[0] === 192 || o[0] === 10 || (o[0] === 172 && o[1] >= 16 && o[1] <= 31)) lan ??= a.address
    }
  }
  return { loopback: "127.0.0.1", lan, tailscale }
}

export interface MPMessage {
  type: "send"
  chat_id: string
  message_id: string
  content: string
  user: string
}

interface MPAck {
  type: "ack"
  message_id: string
}

export function buildChannelTag(msg: MPMessage, ts: string, attachments: string[] = [], replyTo?: string, replyViaText = false): string {
  let safe = msg.content.replace(/\n/g, " ")
  // 防御：超长 content 会让 tmux send-keys -l 失败（如附件提取文本误塞进来）。截断，文件靠 Read 看全。
  if (safe.length > 6000) safe = safe.slice(0, 6000) + " …[截断]"
  if (attachments.length > 0) {
    safe += ` [附件 ${attachments.length} 个，已存到本机，用 Read 工具查看/处理：${attachments.join(" ; ")}]`
  }
  if (replyTo) {
    safe += ` [引用了你的消息 ${replyTo}]`
  }
  const attrs = (attachments.length > 0 ? ` attachments="${attachments.join(";")}"` : "")
    + (replyTo ? ` reply_to="${replyTo}"` : "")
  return `<channel source="memorypalace" chat_id="${msg.chat_id}" message_id="${msg.message_id}" user="${msg.user}" ts="${ts}"${attrs}>${safe}</channel>${replyViaText ? REPLY_VIA_TEXT_HINT : ""}`
}

export interface TmuxRunner {
  /// 注入排进 per-session 串行链（chainSessionSend）：resolve=已注入（Enter 已发/放弃重试），
  /// reject=sendLiteral 都没进去（session 死）。调用方按需 await/attach catch，不许裸 throw 假设。
  send(text: string, session: string): Promise<void>
  /// L3：raw 文本直 send-keys + Enter，跟 send 实现相同，语义区分。
  /// 用于斜杠命令路径——text 不包 buildChannelTag，CC 看到裸 /clear 触发命令系统。
  sendRaw(text: string, session: string): Promise<void>
  /// 单个按键名（如 "Down"/"Enter"），不带 -l —— 用于 boot 期应付 CC 的交互弹窗
  key(keyName: string, session: string): Promise<void>
  /// 当前 pane 文本快照（boot 期检测弹窗用）
  capture(session: string): Promise<string>
  hasSession(session: string): boolean
  list(): string[]
  paneTitles(sessionNames: Iterable<string>): Map<string, string>
  paneMeta?(sessionNames: Iterable<string>): Map<string, PaneMeta>
  spawn(session: string, cwd: string, command: string): Promise<void>
  kill(session: string): Promise<void>
  /// 当「粘贴」送进 pane：pane 开了 bracketed paste 才包（terminal-paste.ts，#053）
  paste(session: string, text: string): Promise<PasteResult>
}

/// Paste mode commit race 兜底：长文本经 `send-keys -l` 写入后会被 claude code TUI
/// 解析为 bracketed paste（`\x1b[200~ ... \x1b[201~`），显示成 `[Pasted text #N]`
/// pending widget。该 widget 的渲染是异步的，紧跟着发的 Enter 在 settle 完成前到达
/// 会被吞掉 → 输入框留住、未 commit（粟粟 IMG_2282 截图证据 + claude code binary
/// 命中 `bracketedPaste`/`[200~`/`[201~`/`[Pasted text #` 字符串）。
///
/// 同 bug 在 obra/claude-session-driver issue #20 已报告："0.1s appears not to be reliable"。
/// 此 helper：发完后 sleep 500ms 给 claude convert；发 Enter；capture-pane 看输入框区域
/// 是否仍有 `[Pasted text` 残留，残留就重发 Enter（最多 3 次重试），仍残留 console.error。
/// 短文本（≤500 字符）不进 paste mode，fast path 跟历史行为一致只多一次条件分支。
///
/// 见 docs/plan-cc-bridge-paste-commit-race.md
export const PASTE_MODE_LENGTH_THRESHOLD = 500
export const PASTE_SETTLE_DELAY_S = 0.5
export const PASTE_RETRY_DELAY_S = 0.4
export const PASTE_RETRY_MAX = 3
export const PASTE_PLACEHOLDER = "[Pasted text"

/// 副作用注入接口，方便测试（生产用 realPasteIO，测试用 spy）
export interface PasteIO {
  sendLiteral: (text: string, session: string) => void | Promise<void>
  /// 终端真·粘贴：tmux 缓冲区 + bracketed paste（ESC[200~ … ESC[201~）。
  /// send-keys -l 只是模拟打字：pty 按 1022 字节分片、无粘贴框定，CC 靠到达间隔猜"是不是粘贴"，
  /// 机器一忙片间拉长就猜错 → 片里的裸 \n 被当 Enter，消息被切成碎片提交（09-02 实证，
  /// docs/research-cc-inject-fragment.md）。括号框住后分片间隔再大也是一整段。
  paste: (text: string, session: string) => void | Promise<void>
  sendKey: (key: string, session: string) => void | Promise<void>
  capturePane: (session: string) => string | Promise<string>
  sleep: (seconds: number) => void | Promise<void>
}

/// K1 第 4 步：发消息 / 问问题卡 / boot 的 tmux 写读全走 tmuxRun（控制连接，K1 关或没就绪走 fork-async），不再 execFileSync 卡主循环。
/// 写命令按会话进 chainTmuxWrite，和终端键入 / 粘贴同一条链，同一会话的写按调用顺序执行
const tmuxSendKeys = (session: string, keys: string[]) =>
  tmuxRun(["send-keys", "-t", session, ...keys], { timeoutMs: TMUX_WRITE_TIMEOUT_MS, write: true, session }).then(() => {})
/// 读失败一律当空屏（与原来 execFileSync 抛错 → "" 一致）
const tmuxCapture = (session: string, extra: string[]) =>
  tmuxRun(["capture-pane", "-t", session, "-p", ...extra], { timeoutMs: TMUX_SYNC_TIMEOUT_MS, write: false }).catch(() => "")

let pasteBufferSeq = 0
export const realPasteIO: PasteIO = {
  sendLiteral: (text, session) => tmuxSendKeys(session, ["-l", text]),
  // load-buffer + paste-buffer 作为一个整体进会话写链，中间插不进别的写（原来是两次紧挨着的同步调用）；
  // job 里的两条不再带 session（带了会排在自己后面，死锁）
  paste: (text, session) => chainTmuxWrite(session, async () => {
    const buf = `mp-${process.pid}-${++pasteBufferSeq}`   // 唯一名 + -d 用完即删，不碰粟粟自己的粘贴板
    try {
      await tmuxLoadBuffer(buf, text, TMUX_WRITE_TIMEOUT_MS)
      await tmuxRun(["paste-buffer", "-p", "-d", "-b", buf, "-t", session], { timeoutMs: TMUX_WRITE_TIMEOUT_MS, write: true })
    } catch (e) {
      // paste-buffer 结果不明：缓冲区先留着，核对时看它还在不在（-d 贴完即删：落定后还在 = 没贴过），由核对删（K1 第 4b 步 · 审查 R1）
      if (e instanceof TmuxUncertainError) { e.buffer = buf; throw e }
      // 失败也删临时缓冲区（原来会留下 mp-<pid>-<n>，审查继承项）
      await tmuxRun(["delete-buffer", "-b", buf], { timeoutMs: TMUX_SYNC_TIMEOUT_MS, write: true }).catch(() => {})
      throw e
    }
  }),
  sendKey: (key, session) => tmuxSendKeys(session, [key]),
  // 读失败抛（K1 第 4b 步 · 审查 R1-3）：提交检查记成「没确认」，不当空屏当成已提交
  capturePane: (session) => tmuxRun(["capture-pane", "-t", session, "-p", "-S", "-5"], { timeoutMs: TMUX_SYNC_TIMEOUT_MS, write: false }),
  // async sleep：paste settle/retry 期间不再冻结事件循环（曾用 execFileSync("sleep")——
  // 一条长消息卡 0.9s+，agora relay 自治高频触发后是 watchdog 误杀螺旋的入口）
  sleep: (s) => new Promise<void>((resolve) => setTimeout(resolve, s * 1000)),
}

export const CODEX_ENTER_RETRY_MAX = 6
export const CODEX_ENTER_RETRY_DELAY_S = 2

/// 返回：committed = 回车后确认提交上了（K1 第 4b 步 · 审查 R1-3：原来忽略，没提交也当成功）；注入失败照旧抛
export async function pasteAwareSendAndEnter(text: string, session: string, io: PasteIO = realPasteIO): Promise<InjectResult> {
  // 长文本或多行 → bracketed paste（见 PasteIO.paste）；短单行维持逐键快路径
  const mayBePaste = text.length > PASTE_MODE_LENGTH_THRESHOLD || text.includes("\n")
  if (mayBePaste) {
    await io.paste(text, session)
    console.log(`[hub] paste-inject ${text.length} chars → ${session}`)
  } else {
    await io.sendLiteral(text, session)
  }
  return { committed: await submitAfterInject(text, session, io, mayBePaste), paste: mayBePaste }
}

/// 文本已经在输入框里之后的提交：回车 + 按引擎核对 / 重试。K1 第 4b 步核对出「停在输入框」时也走这里补回车。
/// 返回 true = 提交上了（或这条路径不检查），false = 重试完还停在输入框 / 中途出错
export async function submitAfterInject(text: string, session: string, io: PasteIO, mayBePaste: boolean): Promise<boolean> {
  // ⚠️ 文本已注入输入框——从这里起任何异常都不能外抛：调用方（ensureSessionAndSend）
  // 的 catch 会当"send 整体失败"重发整条 → 文本注入两遍（"发两遍"事故的雷之一）。
  // Enter/capture 抖动最坏结果 = 消息留在输入框等她手按，绝不重
  try {
    if (sessionEngine(session) === "codex") {
      // codex 无 paste 占位符 widget，但有自己的 Enter 竞态：长文本渲染期/MCP 启动期回车被吞
      //（e2e 实测消息躺输入框不提交）。指纹检测 pane 尾部（输入框区），未提交就重试 Enter。
      await io.sleep(0.4)
      await io.sendKey("Enter", session)
      const fingerprint = text.replace(/\s+/g, " ").trim().slice(-15)
      // resume 后 MCP servers 启动期（~10s）TUI 不收提交（e2e 实测）——retry 窗口罩住启动期。
      // 判定保守：输入框区（pane 尾部）无指纹即视为已提交——绝不重注入
      //（"提交后长回答把原文推出屏"会被宽判定误认为被吞 → 重复消息，比小概率丢一条更糟）。
      for (let i = 0; i < CODEX_ENTER_RETRY_MAX; i++) {
        await io.sleep(CODEX_ENTER_RETRY_DELAY_S)
        const tail = (await io.capturePane(session)).replace(/\s+/g, " ").trim().slice(-200)
        if (!fingerprint || !tail.includes(fingerprint)) return true   // 已提交（输入框清空）
        await io.sendKey("Enter", session)
        console.warn(`[hub] codex enter retry ${i + 1} for ${session}`)
      }
      console.error(`[hub] codex enter gave up after ${CODEX_ENTER_RETRY_MAX} retries for ${session} (消息可能留在输入框)`)
      return false
    }
    if (mayBePaste) await io.sleep(PASTE_SETTLE_DELAY_S)
    await io.sendKey("Enter", session)
    if (!mayBePaste) return true
    for (let i = 0; i < PASTE_RETRY_MAX; i++) {
      await io.sleep(PASTE_RETRY_DELAY_S)
      const pane = await io.capturePane(session)
      if (!pane.includes(PASTE_PLACEHOLDER)) return true   // 已 commit
      await io.sendKey("Enter", session)
      console.warn(`[hub] paste commit retry ${i+1} for ${session}`)
    }
    console.error(`[hub] paste commit gave up after ${PASTE_RETRY_MAX} retries for ${session} (需要手按 Enter)`)
    return false
  } catch (e: any) {
    console.error(`[hub] post-inject enter/capture 失败（文本已在输入框，不重发）: ${e?.message}`)
    return false
  }
}

/// per-session 串行注入链：同 session 顺序保证（第二条的 sendLiteral 绝不插进第一条的
/// paste settle 窗口——pendingSends flush 连发场景），跨 session 并行，事件循环不阻塞。
const sendChains = new Map<string, Promise<void>>()
export function chainSessionSend(session: string, job: () => Promise<void>): Promise<void> {
  const prev = sendChains.get(session) ?? Promise.resolve()
  const next = prev.then(job)
  // 链上失败不断链（下一条照发）；错误由 job 内部处理/上抛给 await 方
  sendChains.set(session, next.catch(() => {}))
  return next
}

// ── K1 第 4b 步：结果不明的消息由 hub 自己核对送达（send-track.ts / send-verify.ts，perf/hub-实验日志.md「K1 第 4b 步」「· 审查 R1」）──
// 核对在会话的发消息链（chainSessionSend）里跑完才放下一条：后面的消息要是先进去，会粘在输入框里那半条后面一起提交，
// 或者排到重发的前面（乱序）。终端键入的写链（chainTmuxWrite）不占，核对只按条发 tmux 命令

/// 走过核对的消息的状态（正常发送不进账）；uncertain / 终态广播 send_status 给所有 app
export const sendStatusBook = new SendStatusBook()
sendStatusBook.watch((f) => { broadcastFrame(JSON.stringify(f)) })
const codexRolloutCache = new Map<string, string>()
const codexRolloutMiss = new Map<string, number>()   // 没找到的 uuid：30s 内不再扫目录
const codexRolloutScans = new Map<string, Promise<string | undefined>>()   // 同一个 uuid 同时只扫一遍
let claudeProjectDirCache: { key: string; dir: string; at: number } | undefined

/// claude transcript 路径（同 claudeTranscriptPath），工作目录缓存 60s：没设 MP_CC_WORKDIR 时 ccWorkdir() 要同步 stat 一次，不放在每次发消息上
function sendTranscriptPath(claudeSessionId: string): string {
  const home = process.env.HOME ?? ""
  const key = `${home}\0${process.env.MP_CC_WORKDIR ?? ""}`
  const now = Date.now()
  if (!claudeProjectDirCache || claudeProjectDirCache.key !== key || now - claudeProjectDirCache.at > 60_000) {
    claudeProjectDirCache = { key, dir: join(home, ".claude", "projects", ccProjectSlug(ccWorkdir())), at: now }
  }
  return join(claudeProjectDirCache.dir, `${claudeSessionId}.jsonl`)
}

function findRolloutOnce(uuid: string): Promise<string | undefined> {
  const missAt = codexRolloutMiss.get(uuid)
  if (missAt !== undefined && Date.now() - missAt < 30_000) return Promise.resolve(undefined)
  let p = codexRolloutScans.get(uuid)
  if (!p) {
    p = findCodexRollout(join(process.env.HOME ?? "", ".codex", "sessions"), uuid).then((found) => {
      if (found) codexRolloutCache.set(uuid, found); else codexRolloutMiss.set(uuid, Date.now())
      return found
    }).finally(() => codexRolloutScans.delete(uuid))
    codexRolloutScans.set(uuid, p)
  }
  return p
}

/// 发送前记下会话绑定的 transcript 的长度（claude 按 claudeSessionId，codex 按 uuid 找 rollout）。最多等 200ms，等不到之后核对一律 unknown
async function sendCursor(session: string): Promise<TranscriptCursor | undefined> {
  const id = sessionMap.get(session)?.claudeSessionId
  if (!id) return undefined
  const engine = sessionEngine(session)
  if (engine === "claude") return transcriptCursor(sendTranscriptPath(id))
  if (engine !== "codex") return undefined
  const path = codexRolloutCache.get(id) ?? await Promise.race([findRolloutOnce(id), Bun.sleep(200).then(() => undefined)])
  return path ? transcriptCursor(path) : undefined
}

/// 当前输入框（只看可见屏）。会话没了（tmux 明确说找不到）和读屏暂时失败分开
async function sendEditArea(session: string): Promise<EditArea> {
  try {
    const pane = await tmuxRun(["capture-pane", "-t", session, "-p"], { timeoutMs: TMUX_SYNC_TIMEOUT_MS, write: false })
    const text = locateEditArea(pane, sessionEngine(session))
    return text === undefined ? { kind: "unlocated" } : { kind: "found", text }
  } catch (e) {
    const detail = e instanceof TmuxCommandError ? e.stderr : String((e as Error)?.message ?? e)
    return e instanceof TmuxCommandError && /can't find (?:session|pane|window)|no server running/.test(detail) ? { kind: "gone", detail } : { kind: "unreadable", detail }
  }
}

export const sendTracker = new SendTracker(sendStatusBook, {
  inject: (text, session) => pasteAwareSendAndEnter(text, session),
  submit: (text, session, paste) => submitAfterInject(text, session, realPasteIO, paste),
  settle: (err, deadlineAt) => waitTmuxWriteSettled(err, deadlineAt),
  bufferExists: async (name) => {
    try { return (await tmuxRun(["list-buffers", "-F", "#{buffer_name}"], { timeoutMs: TMUX_SYNC_TIMEOUT_MS, write: false })).split("\n").includes(name) }
    catch { return undefined }
  },
  deleteBuffer: (name) => tmuxRun(["delete-buffer", "-b", name], { timeoutMs: TMUX_SYNC_TIMEOUT_MS, write: true }).then(() => {}),
  cursor: sendCursor,
  editArea: sendEditArea,
  generation: (session) => lastStartupGen.get(session),
  // 只清就绪：下一条消息重新判活、走拉起。不碰启动中的状态和排队（那是启动互斥的）
  sessionGone: (session) => { sessionReady.delete(session) },
  // 会话表刷新一次再交回原有路径，免得旧快照还说它活着
  requeue: (session, text) => { void tmuxState.refresh().finally(() => ensureSessionAndSend(session, text)) },
  legacyError: (session, messageId, reason) => {
    // 旧版 app 只认 error 帧（新版看 send_status）
    const frame = JSON.stringify({ type: "error", ...(messageId ? { message_id: messageId } : {}), session_name: session, reason: `这条消息没送进 ${session}：${reason}` })
    for (const c of mpClients) { try { c.send(frame) } catch {} }
  },
  sleep: (ms) => Bun.sleep(ms),
  now: Date.now,
})

/// 同步 tmux 调用上限：tmux server 卡住时单次最多拖主循环这么久（原来无上限）
export const TMUX_SYNC_TIMEOUT_MS = 3_000
/// 写操作（send-keys / paste / new-session）给宽一点：超时 = 当成没送进去，宁慢勿丢
export const TMUX_WRITE_TIMEOUT_MS = 10_000
export const tmuxState = new TmuxState({ fetch: () => fetchPanes() })
const TMUX_STATE_POLL_MS = 2_000
/// 启动时 listen 前最多等首份会话表这么久（tmux 卡住也不能拖着不起）
const FIRST_TMUX_SNAPSHOT_WAIT_MS = 2_000
const LOOP_LAG_TICK_MS = 500
/// bench hub（scripts/bench-hub.ts）专用：/health 多带近 15 分钟的卡顿和阻塞调用账。默认关
const BENCH_HEALTH = process.env.MP_HUB_BENCH === "1"
/// 秒连账本：卡顿记录（>200ms 就记，给 connect_report 对账）+ hub 起来的时刻
const lagLog = new LagLog()
const hubStartedAt = Date.now()
const connectLedgerPath = join(SECRETS_DIR, "connect-ledger.jsonl")

export const realTmuxRunner: TmuxRunner = {
  // 和 terminal_input 的 send-keys -H 同一条按会话写链（K1-0 时序风险 7）；pasteToTmux 里的 tmux 调用不带 session（带了死锁）
  paste: (session, text) => chainTmuxWrite(session, () => pasteToTmux(session, text)),
  send(text: string, session: string) {
    return chainSessionSend(session, () => sendTracker.send(text, session))
  },
  sendRaw(text: string, session: string) {
    return chainSessionSend(session, () => pasteAwareSendAndEnter(text, session).then(() => {}))   // 斜杠命令不走送达核对（K1 第 4b 步只管消息）
  },
  key: (keyName: string, session: string) => tmuxSendKeys(session, [keyName]),
  capture: (session: string) => tmuxCapture(session, []),
  // 读 tmuxState 快照（后台异步轮询），快照过期才回退同步查（带超时）——主循环不再排队等 tmux。
  // K1 第 4 步：K1 开时过期也用最后一份快照（同 hasSession 的 lastKnown），不再同步查；
  // 只有 hub 刚起、一份快照都还没拿到时才同步查（K1 开时 listen 前已等首份，这个窗口只剩首份 >2s 的情况）。K1=0 照旧
  hasSession(session: string): boolean {
    // 快照过期（主循环卡过 10s 轮询没落地）也先信最后一次见到的：会话很少变，hub 自己的 spawn/kill 有记账；
    // 外面关掉的下次轮询就知道。同步查只在 hub 刚起、还没拿到过快照时用
    const cached = tmuxState.has(session) ?? tmuxState.lastKnown(session)
    if (cached !== undefined) return cached
    try {
      execFileSync("tmux", ["has-session", "-t", session], { stdio: ["ignore", "ignore", "pipe"], timeout: TMUX_SYNC_TIMEOUT_MS })
      return true
    } catch (e: any) {
      // 只有 tmux 明确答「没有这个会话 / 没起 server」才算没了。超时、连不上 server（也是 exit 1）= 不知道：
      // 误判「没了」会去重复 spawn（10-10 cc66：duplicate session，排队消息被吞；06:38 又误判一次后主循环冻 73s）；
      // 误判「活着」send 失败会走自愈，代价小得多
      if (/can't find session|no server running|error connecting.*No such file or directory/.test(String(e?.stderr ?? ""))) return false
      return tmuxState.lastKnown(session) ?? true
    }
  },
  list(): string[] {
    const cached = tmuxState.list(k1Enabled())
    if (cached) return cached
    try {
      const raw = execFileSync("tmux", ["ls", "-F", "#{session_name}"], { encoding: "utf-8", timeout: TMUX_SYNC_TIMEOUT_MS })
      return raw.split("\n").filter(s => s)
    } catch {
      return []  // tmux ls 在无 session 时 exit 1
    }
  },
  paneTitles(sessionNames: Iterable<string>): Map<string, string> {
    const wanted = new Set(sessionNames)
    if (wanted.size === 0) return new Map()
    const cached = tmuxState.paneTitles(wanted, k1Enabled())
    if (cached) return cached
    try {
      const raw = execFileSync("tmux", TMUX_PANES_ARGS, { encoding: "utf-8", timeout: TMUX_SYNC_TIMEOUT_MS })
      const all = parsePaneTitles(raw)
      return new Map([...all].filter(([s]) => wanted.has(s)))
    } catch { return new Map() /* tmux 没起或某窗口刚死：标题链继续降级 */ }
  },
  paneMeta(sessionNames: Iterable<string>): Map<string, PaneMeta> {
    const wanted = new Set(sessionNames)
    if (wanted.size === 0) return new Map()
    const cached = tmuxState.paneMeta(wanted, k1Enabled())
    if (cached) return cached
    try {
      const raw = execFileSync("tmux", TMUX_PANES_ARGS, { encoding: "utf-8", timeout: TMUX_SYNC_TIMEOUT_MS })
      return new Map([...parsePaneMeta(raw)].filter(([s]) => wanted.has(s)))
    } catch { return new Map() /* 同 paneTitles */ }
  },
  async spawn(session: string, cwd: string, command: string) {
    // -d detached；command 由 spawnSession 按 engine 组装（claude 带 --session-id/--resume，
    // codex 裸跑或 resume <uuid>——不 --continue/--last（多实例抢 most-recent 的老雷）。
    // -e：hook（thinking / askuser / lifecycle）按 MP_CC_HUB_PORT 回传；tmux 里的进程拿的是 tmux server 的环境，
    // Mac App 内嵌 hub 那里是 "0"（OS 分配前的占位）→ 必须把真实端口显式塞进去（#046 审计 F）
    // K1：-e PATH=fork 客户端会带的那个 PATH。控制客户端已 attach，新会话的子进程拿的是 server 全局 PATH 而不是客户端的（R1，claude 全 127 的坑）；
    // fork 时子进程本来就拿客户端的 PATH，加了结果相同。不用 process.env.PATH：那是增强过的，顺序不同，claude 可能解析到另一个二进制。K1=0 照旧不加
    const pathEnv = k1Enabled() ? ["-e", `PATH=${FORK_CHILD_PATH}`] : []
    try {
      await tmuxRun(["new-session", "-d", "-s", session, "-e", `MP_CC_HUB_PORT=${PORT}`, ...pathEnv, "-c", cwd, command],
        { timeoutMs: TMUX_WRITE_TIMEOUT_MS, write: true, session })
    } catch (e: any) {
      if (/duplicate session/.test(String(e?.stderr ?? ""))) { tmuxState.noteSpawned(session); throw new SessionExistsError(session) }
      throw e
    }
    tmuxState.noteSpawned(session)
  },
  async kill(session: string) {
    try { await tmuxRun(["kill-session", "-t", session], { timeoutMs: TMUX_SYNC_TIMEOUT_MS, write: true, session }) } catch { /* 已不存在 */ }
    tmuxState.noteKilled(session)
  }
}

/// spawn 时 tmux 说会话已经在了（会话表误报不在）→ 调用方接管现成的，别当失败
export class SessionExistsError extends Error {
  constructor(session: string) { super(`duplicate session: ${session}`) }
}

// DRY_RUN: 测试用，所有 tmux 调用 noop；hasSession 默认 true 避免误拒 send，kill 过的（再 spawn 之前）算没了
const dryRunKilled = new Set<string>()
const dryRunRunner: TmuxRunner = {
  send: () => Promise.resolve(),
  sendRaw: () => Promise.resolve(),
  key: async () => {},
  capture: async () => "",
  hasSession: (session) => !dryRunKilled.has(session),
  list: () => [],
  paneTitles: () => new Map(),
  spawn: async (session) => { dryRunKilled.delete(session) },
  kill: async (session) => { dryRunKilled.add(session) },
  paste: async () => ({ ok: true }),
}

let baseTmux: TmuxRunner = process.env.MP_CC_TMUX_DRY_RUN ? dryRunRunner : realTmuxRunner
export function setTmuxRunner(runner: TmuxRunner) { baseTmux = runner }

// ── stream 传输（无终端）：hub 当 claude 父进程，stdin/stdout 走 stream-json（stream-runner.ts）。
// 所有 tmux.* 调用点不动：下面这个分发器把 stream 会话截走，其余原样进 tmux。
export const streamRunner = new StreamRunner({
  onReady: (name, sid) => onStreamReady(name, sid),
  onResult: (name, r) => {
    console.log(`[hub] stream result ${name} ${r.subtype} turns=${r.num_turns} cost=$${Number(r.total_cost_usd ?? 0).toFixed(4)}`)
    onStreamTurnEvent(name, r)   // result 不经 onEvent：必须在这里收轮，否则下一轮的字会续写到上一轮的节点（09-18 实测）
    if (streamRetireWhenIdle.has(name) && !streamRunner.isBusy(name)) void retireForTransport(name, "传输策略变了，本轮跑完", 0)
  },
  onControlRequest: (name, req, respond) => onStreamControlRequest(name, req, respond),
  onExit: (name, code, wasReady, stderrTail) => onStreamExit(name, code, wasReady, stderrTail),
  onEvent: (name, m) => {
    if (m.type === "rate_limit_event") console.warn(`[hub] stream ${name} rate_limit ${JSON.stringify(m.rate_limit_info ?? {}).slice(0, 120)}`)
    onStreamTurnEvent(name, m)
  },
})

// ── 逐字流式（十二）：stream_event 增量 → 第一个字建 reply 节点，之后 edit/thinking 帧节流广播 ──
// 节点 id `s_txt_<random>`；text 块完成时把 `s_txt_<转录 uuid>` 记进已见集合并映射到该节点，
// 轮末 Stop hook 的 reply_text 命中 dup、thinking 锚回这个节点。
const streamTurns = new StreamTurnTracker()
const streamLastInbound = new Map<string, { chatId: string; messageId?: string }>()   // 该 session 最近一条 channel 输入
const streamedTurnNode = new Map<string, string>()   // 转录 uuid → 流式建的节点 id（Stop hook 锚定用）
const STREAM_FLUSH_MS = 150
interface StreamFlush { text?: string; thinking?: string; timer?: ReturnType<typeof setTimeout> }
const streamFlush = new Map<string, StreamFlush>()   // pendingId → 待发
function broadcastFrame(payload: string): number {
  let n = 0
  for (const mp of mpClients) if (mp.readyState === mp.OPEN) { try { mp.send(payload); n++ } catch {} }
  return n
}
function flushStream(chatId: string, pendingId: string, final: boolean): void {
  const f = streamFlush.get(pendingId)
  if (!f) return
  if (f.timer) { clearTimeout(f.timer); f.timer = undefined }
  if (f.text !== undefined) {
    broadcastFrame(JSON.stringify({ type: "edit", chat_id: chatId, mp_msg_id: pendingId, content: f.text, streaming: !final }))
    if (final) {
      // 终稿才进 edit 缓存（replay 补发）；中间态不存，免得重连时回放几十帧
      const i = recentReplies.findIndex((r) => r.mpMsgId === pendingId)
      if (i >= 0) recentReplies[i].content = f.text
      recentEdits.push({ chat_id: chatId, mp_msg_id: pendingId, content: f.text, ts: Date.now() })
      while (recentEdits.length > MAX_REPLY_LOG) recentEdits.shift()
      saveReplyLog()
    }
    f.text = undefined
  }
  if (f.thinking !== undefined) {
    broadcastFrame(JSON.stringify({ type: "thinking", chat_id: chatId, mp_msg_id: pendingId, content: f.thinking, thinking_id: `${pendingId}-live`, streaming: !final }))
    f.thinking = undefined
  }
  if (final) streamFlush.delete(pendingId)
}
function scheduleStreamFlush(chatId: string, pendingId: string, patch: { text?: string; thinking?: string }): void {
  const f = streamFlush.get(pendingId) ?? {}
  if (patch.text !== undefined) f.text = patch.text
  if (patch.thinking !== undefined) f.thinking = patch.thinking
  if (!f.timer) f.timer = setTimeout(() => { f.timer = undefined; flushStream(chatId, pendingId, false) }, STREAM_FLUSH_MS)
  streamFlush.set(pendingId, f)
}
function onStreamTurnEvent(name: string, m: any): void {
  if (!replyViaTextFor(name)) return
  const inbound = streamLastInbound.get(name)
  const chatId = inbound?.chatId ?? sessionActivity.get(name)?.lastChatId
  for (const a of streamTurns.handle(name, m)) {
    if (a.kind === "end") {
      // 终稿必须落到 recentReplies（reply-log）：中间帧的 timer 可能已把缓冲清空，final flush 就没东西回填，
      // 重连 replay 发出去的就是空 reply（09-18 粟粟划掉 app 再开看不见小克的话）。用状态机带回的终稿强制发一次。
      if (a.pendingId && chatId) scheduleStreamFlush(chatId, a.pendingId, { text: a.text, ...(a.thinking ? { thinking: a.thinking } : {}) })
      if (a.pendingId) flushStream(chatId ?? "", a.pendingId, true)
      continue
    }
    if (a.kind === "split") {
      if (chatId) { scheduleStreamFlush(chatId, a.pendingId, { text: a.text, ...(a.thinking ? { thinking: a.thinking } : {}) }); flushStream(chatId, a.pendingId, true) }
      continue
    }
    if (!chatId) { console.warn(`[hub] stream ${name} 有增量但不知道 chat_id，丢弃`); continue }
    switch (a.kind) {
      case "create":
        deliverReply({ chat_id: chatId, message_id: inbound?.messageId, content: "", mp_msg_id: a.pendingId, streaming: true }, undefined, "stream")
        break
      case "text": scheduleStreamFlush(chatId, a.pendingId, { text: a.content }); break
      case "thinking": scheduleStreamFlush(chatId, a.pendingId, { thinking: a.content }); break
      case "text_done":
        streamedTurnNode.set(a.uuid, a.pendingId)
        seenMpMsgIds.add(`s_txt_${a.uuid}`)
        scheduleStreamFlush(chatId, a.pendingId, { text: a.content })
        break
      case "thinking_done": scheduleStreamFlush(chatId, a.pendingId, { thinking: a.content }); break
    }
  }
}
const tmux: TmuxRunner = {
  send: (t, s) => streamRunner.has(s) ? streamRunner.send(t, s) : baseTmux.send(t, s),
  sendRaw: (t, s) => streamRunner.has(s) ? streamSendRaw(t, s) : baseTmux.sendRaw(t, s),
  key: async (k, s) => { if (!streamRunner.has(s)) await baseTmux.key(k, s) },
  capture: async (s) => streamRunner.has(s) ? "" : baseTmux.capture(s),
  hasSession: (s) => streamRunner.has(s) || baseTmux.hasSession(s),
  list: () => [...new Set([...baseTmux.list(), ...streamRunner.list()])],
  paneTitles: (names) => baseTmux.paneTitles(names),
  paneMeta: (names) => baseTmux.paneMeta?.(names) ?? new Map(),
  spawn: (s, cwd, cmd) => baseTmux.spawn(s, cwd, cmd),
  kill: async (s) => { if (streamRunner.has(s)) streamRunner.kill(s); else await baseTmux.kill(s) },
  paste: async (s, t) => streamRunner.has(s) ? { ok: false, reason: "这个会话没有终端" } : baseTmux.paste(s, t),
}

// ── 1:1 session 就绪管理 ──
// tmux session 建出来是瞬时的，但里面 claude 要几秒才能接收 send-keys。
// 全新会话发第一条 → 自动 spawn + 排队，claude 就绪后再注入（慢几秒但不丢）。
const BOOT_DELAY_MS = Number(process.env.MP_CC_BOOT_MS) || 6000
const sessionReady = new Set<string>()           // claude 已就绪可收 send-keys
// 思考强度（effort.ts）：app 最近要的档位 / 这个会话现在跑着的档位（启动带了参数或发过 /effort 才算知道）
const wantedEffort = new Map<string, string>()
const sessionEffort = new Map<string, string>()
// 本 hub 正在启动的会话 → 这次启动的代次（审查 R1-1 / R1-2）。所有拉起入口（发消息触发、spawn_cc、boot 恢复、传输切换重生、
// 回收后再拉、启动失败重试）都进 spawnSession：已有在启动的就并进去（消息照旧排队），没有才开新代次；启动链里的重试带着代次续上。
// 清态（clearSessionState / retire / /clear）= 删掉代次：在途那次每个 await 之后核对代次，不是自己的就收手，不再动就绪 / 队列
interface Startup { gen: number; modelOverrides: number }
const sessionSpawning = new Map<string, Startup>()   // 已 spawn、boot 中
let startupSeq = 0
const lastStartupGen = new Map<string, number>()      // 每个会话最近开的代次（回收 await kill 之后按它判断期间有没有新启动）
function ownsStartup(name: string, gen: number): boolean { return sessionSpawning.get(name)?.gen === gen }
/// 结束本代次的启动（就绪 / 放弃 / 失败）；不是自己的代次不动，返回 false
function endStartup(name: string, gen: number): boolean {
  if (!ownsStartup(name, gen)) return false
  sessionSpawning.delete(name)
  return true
}
const pendingSends = new Map<string, string[]>()  // boot 期间排队的 channel tag

/// 对话 Agent 的 --mcp-config：cwd 的 .mcp.json（launchd hub，start_cc.sh 渲染的）→ 内嵌 hub 现写的那份 → 没有（null，不带参数）
function ccMcpConfig(): string | null { return pickMcpConfig(`${process.cwd()}/.mcp.json`, generatedMcpConfigThisBoot) }
function mcpConfigArg(): string {
  const cfg = ccMcpConfig()
  return cfg ? ` --mcp-config '${cfg}'` : ""
}

/// 家目录不存在就建（陌生人机器上 App Support 那份兜底一开始是空的；tmux -c 指向不存在的目录会落到别处）
function ensureDir(dir: string): string {
  try { mkdirSync(dir, { recursive: true }) } catch {}
  return dir
}

/// 对话 Agent（mp-cc-* / mp-codex-*）的命令：一律在家、陪伴配置不变。[+] 窗口走 windowLaunch。
function freshTerminalLaunch(engine: TerminalEngine, claudeSessionId = crypto.randomUUID(), model = CC_MODEL): TerminalLaunch {
  return buildFreshTerminalLaunch(engine, {
    home: homedir(),
    shell: process.env.SHELL || "/bin/zsh",
    ccWorkdir: ccWorkdir(),
    codexWorkdir: codexWorkdir(),
    ccModel: model,
    mcpConfig: ccMcpConfig(),
    claudeSessionId,
  })
}

/// [+] 开的全局窗口（开窗 + 恢复都走这）：Claude / Codex 开在干活目录（hub-config，没设 = 各自的家，#046 T3）；
/// 干活目录不是 Claude 的家时用干净参数（审计 T18）——家里那份是小克的陪伴配置。
function windowLaunch(engine: TerminalEngine): TerminalLaunch {
  const claudeHome = ccWorkdir()
  const claudeCwd = resolveAgentWorkdir(hubConfig, claudeHome)
  const codexCwd = resolveAgentWorkdir(hubConfig, codexWorkdir())
  return buildFreshTerminalLaunch(engine, {
    home: homedir(),
    shell: process.env.SHELL || "/bin/zsh",
    ccWorkdir: claudeCwd,
    codexWorkdir: ensureDir(codexCwd),
    ccModel: CC_MODEL,
    mcpConfig: ccMcpConfig(),
    claudeSessionId: crypto.randomUUID(),
    cleanClaude: !sameDir(claudeCwd, claudeHome),
  })
}

// ── C1.5 换窗口不失忆：tmux session ↔ claude session-id 绑定 ──
// spawn 新会话时由 hub 生成 uuid（--session-id），重 spawn 时 --resume 同一 id → CC 记得该对话历史。
// map 持久化在 secrets/session-map.json（gitignore），key = tmux session 名。
interface SessionBinding { claudeSessionId: string; chatId?: string; updatedAt: string; transport?: "tmux" | "stream" }
const sessionMapPath = join(SECRETS_DIR, "session-map.json")
export const sessionMap = new Map<string, SessionBinding>()
function loadSessionMap(): void {
  try {
    if (!existsSync(sessionMapPath)) return
    const obj = JSON.parse(readFileSync(sessionMapPath, "utf-8")) as Record<string, SessionBinding>
    for (const [k, v] of Object.entries(obj)) { if (v?.claudeSessionId) sessionMap.set(k, v) }
    console.log(`[hub] session-map loaded (${sessionMap.size} bindings)`)
  } catch (e: any) { console.warn(`[hub] session-map load fail: ${e.message}`) }
}
function saveSessionMap(): void {
  try { writeFileSync(sessionMapPath, JSON.stringify(Object.fromEntries(sessionMap), null, 2)) }
  catch (e: any) { console.warn(`[hub] session-map save fail: ${e.message}`) }
}
// 粟粟 /model 切过的模型（cc-model.ts）：key = tmux session 名，拉起时有记录用记录，没有用 CC_MODEL
export const ccModels = new ModelPrefs(join(SECRETS_DIR, "cc-models.json"))
/// 每个会话这次拉起用的模型和来源（日志 / 起不来时判断要不要退回默认）
export const launchedModel = new Map<string, LaunchModel>()
/// 拉起前找转录里最后一次 /model 只读尾部这么多，最多等这么久（超时按记录启动，审查 R1-3）
const MODEL_TAIL_BYTES = 1 << 20
const MODEL_READ_DEADLINE_MS = 1_500

/// 这次拉起用哪个模型：记录 / 默认打底，转录（终端里直接敲的 /model 也在里面）有更新的切换就用转录的，并落成记录。
/// 只给 claude；不抛（读不到转录就当没有）
async function resolveLaunchModel(name: string, bound: SessionBinding | undefined): Promise<LaunchModel> {
  const ver0 = ccModels.version(name)
  let event: Awaited<ReturnType<typeof readModelEventWithin>>["event"] = null
  if (bound) {
    const r = await readModelEventWithin(() => readTailAsync(claudeTranscriptPath(bound.claudeSessionId), MODEL_TAIL_BYTES), MODEL_READ_DEADLINE_MS)
    if (r.problem) console.warn(`[hub] ${name} 读转录找 /model ${r.problem}（按记录 / 默认启动）`)
    event = r.event
    // 读的期间绑定换了（/clear、换新会话）：这份转录不再是它的
    if (event && sessionMap.get(name)?.claudeSessionId !== bound.claudeSessionId) { console.log(`[hub] ${name} 读转录期间绑定换了 → 转录里的切换不作数`); event = null }
  }
  // await 之后重新取记录（审查 R1-7）：期间 app 又选了，就拿新的比，别用旧快照把新选择盖掉
  if (ccModels.version(name) !== ver0) console.log(`[hub] ${name} 读转录期间又选了模型 → 按最新记录比`)
  const record = ccModels.get(name)
  const launch = pickLaunchModel(CC_MODEL, record, event)
  if (event && bound && launch.source.startsWith("转录")) {   // 转录尾部滚走 / 换了新转录也还记得
    const keep = event.kind === "reset" ? DEFAULT_MODEL_MARK : event.model
    if (keep !== record?.model) ccModels.setFromTranscript(name, keep, event.at, bound.claudeSessionId)
  }
  launchedModel.set(name, launch)
  ccModels.touch(name)
  console.log(`[hub] ${name} 拉起模型 ${launch.model}（${launch.source}）`)
  return launch
}

/// app 的斜杠命令 raw 直发（不包 channel tag，CC 看到裸 /clear 触发命令系统）。等写进去确认了才记模型、才回 ack；
/// 写失败 / 结果不明都接住返回原因（原来没 await：异步失败逃出 try = unhandledRejection = hub 退出，而且先记了模型、先回了 ack）
export async function sendSlashCommand(target: string, content: string): Promise<{ ok: true } | { ok: false; reason: string }> {
  try {
    await tmux.sendRaw(content, target)
  } catch (err: any) {
    const uncertain = err instanceof TmuxUncertainError
    console.warn(`[hub] command ${uncertain ? "结果不明" : "失败"} tmux:${target} ${content.slice(0, 60)}: ${err?.message?.split("\n")[0]}`)
    return { ok: false, reason: uncertain ? `tmux 卡住了，命令不确定有没有送进 ${target}（没有自动重发）` : `tmux: ${err?.message}` }
  }
  noteModelCommand(target, content)
  console.log(`[hub] command → tmux:${target} ${content.slice(0, 60)}`)
  return { ok: true }
}

/// app 发来的 `/model <参数>`：claude 终端会话记下来，下次拉起照用；`/model default` 记成要回默认。
/// 不带参数（开选单）不记——选了什么拉起前从转录里找。stream 会话中途切不了（streamSendRaw 不认），不记
export function noteModelCommand(name: string, content: string): void {
  if (sessionEngine(name) !== "claude" || streamRunner.has(name)) return
  const cmd = parseModelCommand(content)
  if (!cmd) return
  const model = cmd.kind === "reset" ? DEFAULT_MODEL_MARK : cmd.model
  ccModels.set(name, model, "app")
  console.log(`[hub] ${name} 模型记下 ${model}（app /model）${cmd.kind === "reset" ? `→ 下次拉起先用 hub 默认 ${CC_MODEL}（--model default 未实测）` : ""}`)
  // 底部胶囊：写进终端 ≠ 切成了（审查 R1-3）。先记请求中，CLI 的输出一般很快落进转录，过一会儿再看两次
  void sessionModels.notePending(name, model, cliModelFor(model, CC_MODEL))
  for (const ms of PENDING_RECHECK_MS) setTimeout(() => { void sessionModels.refresh(name) }, ms).unref?.()
}
const PENDING_RECHECK_MS = [1_500, 6_000]

// ── 会话在用的模型（session-model.ts）：session_model 帧给聊天页底部胶囊，ctx% 按它的窗口算 ──
// 转录按文件增量扫（size+mtime 没变不读、变长只读新增的、第一次从尾部分块往回找），同一会话的重算在途合并
const codexRollouts = new CodexRolloutIndex(() => join(process.env.HOME ?? "", ".codex", "sessions"))
/// app 报到时预热：一次最多读这么多转录（多数会话没变只 stat 一下，不算）
const SESSION_MODEL_WARM_BUDGET = 32 << 20
export const sessionModels = new SessionModelTracker({
  binding: (name) => {
    if (isWindowSession(name)) return undefined
    const id = sessionMap.get(name)?.claudeSessionId
    const kind = sessionEngine(name)
    return id && (kind === "claude" || kind === "codex") ? { id, kind } : undefined
  },
  transcriptPath: async (b) => b.kind === "claude" ? sendTranscriptPath(b.id) : (codexRolloutCache.get(b.id) ?? await codexRollouts.lookup(b.id)),
  // 没有任何选择：claude 按 hub 默认拉起；codex 没有
  fallback: (name) => sessionEngine(name) === "claude" && !isWindowSession(name) ? CC_MODEL : undefined,
  // 落盘的选择带时间进比较（hub 重启后内存里的选择没了）；default 照 (b) 按 hub 默认
  record: (name) => {
    const p = sessionEngine(name) === "claude" ? ccModels.get(name) : undefined
    return p ? { model: cliModelFor(p.model, CC_MODEL), atMs: Date.parse(p.updatedAt), arg: p.model } : undefined
  },
  publish: (name, model) => {
    console.log(`[hub] ${name} 在用模型 ${model ?? "不知道了（清掉后缀）"}`)
    const frame = buildSessionModelFrame(name, model)
    // 同 session_phase：只发报过到（client_info）的 app 连接
    for (const c of mpClients) {
      if (c.readyState === c.OPEN && clientInfoByWS.get(c)?.platform !== undefined) { try { c.send(frame) } catch {} }
    }
  },
  now: Date.now,
  defaultModel: CC_MODEL,
  log: (line) => console.log(line),
})

/// 算 ctx% 用：这条回复的 model 接上选择的 [1m]；没有回复的 model 就按选择 / 打底
export function contextWindowForSession(name: string, recordModel: string | undefined): number {
  const base = sessionModels.suffixSource(name)   // 最新选择的模型不知道（选单选的）→ undefined，不接 [1m]
  return contextWindowFor(recordModel ? carryContextSuffix(recordModel, base) : base ?? CC_MODEL)
}

/// 拉起 / app /model 确认后：记下选择、重算、变了就广播
export function noteSessionModelChoice(name: string, model: string): void {
  void sessionModels.noteChoice(name, model)
}

/// 重算一个会话的模型，变了就广播 session_model；返回算出来的（单测用）
export async function refreshSessionModel(name: string): Promise<string | undefined> {
  await sessionModels.refresh(name)
  return sessionModels.known(name)
}

/// 一轮真的做完了（claude 的 Stop hook / MCP reply）：重算这个会话的模型。不看 phase 变没变（审查 R1-4：终端里连着几轮
/// 都是 done → done，靠 phase 跳变会一直跳过）；重复触发靠转录文件版本去重（没变不读）
export function onSessionTurnEnded(name: string): Promise<number> {
  return sessionModels.refresh(name)
}

/// app 报到：已知的全部补发；还没算过的会话挨个算（异步读盘，算出来走广播）
export function sessionModelSnapshotFrames(): string[] {
  return sessionModels.snapshot().map(([name, model]) => buildSessionModelFrame(name, model))
}
let sessionModelWarming: Promise<void> | null = null
function warmSessionModels(): void {
  if (sessionModelWarming) return
  sessionModelWarming = (async () => {
    // 全部都重算（不只没算过的）：断线期间终端里换了模型也补上；没变的只 stat 一下。没算过的排前面
    const names = [...sessionMap.keys()].sort((a, b) => Number(!!sessionModels.known(a)) - Number(!!sessionModels.known(b)))
    await sessionModels.warm(names, SESSION_MODEL_WARM_BUDGET)
  })().finally(() => { sessionModelWarming = null })
}

/// claude 把 transcript 写在 ~/.claude/projects/<cwd 的 / 全替换成 ->/<sessionId>.jsonl
export function claudeTranscriptPath(claudeSessionId: string): string {
  const projDir = ccProjectSlug(ccWorkdir())
  return join(process.env.HOME ?? "", ".claude", "projects", projDir, `${claudeSessionId}.jsonl`)
}

// spawn 一个 session，安排 boot 完成后标记就绪 + flush 排队消息。
// C1.5：map 有绑定且 transcript 还在 → --resume（带记忆醒来）；否则 --session-id 新 uuid + 落 map。
// resume 的 jsonl 坏/被删时 claude 启动即退出 → boot 检查发现 session 死了 → 清绑定重 spawn 一次（新会话，排队消息不丢）。
/// cont：启动链内部的重试（boot 死了换 fresh、stream 再试一次…）带着本代次续上；外部入口不传。
/// cont.modelOverride：本次恢复一次性用的模型（modelRecoveryFor 给的），不写记录、只管这一次
export async function spawnSession(name: string, chatId?: string, isRetry = false, transport?: "tmux" | "stream", cont?: { gen: number; modelOverride?: string }): Promise<void> {
  // 全局终端窗口不该走这条路：这里全是 claude/codex 专有的事（问问题收账、sessionMap
  // resume 绑定、boot 状态机、死亡重试、pendingSends flush）。它走 spawnTerminalWindow。
  if (isWindowSession(name)) {
    console.warn(`[hub] spawnSession(${name}) 被误用于全局窗口 — 忽略，应走 spawnTerminalWindow`)
    return
  }
  let gen: number
  if (cont) {
    if (!ownsStartup(name, cont.gen)) { console.log(`[hub] ${name} 启动重试作废（这次启动已被清掉 / 取代）`); return }
    gen = cont.gen
  } else {
    if (sessionSpawning.has(name)) { console.log(`[hub] ${name} 已在启动中 → 并进这一次，不再起一份`); return }
    gen = ++startupSeq
    sessionSpawning.set(name, { gen, modelOverrides: 0 })
    lastStartupGen.set(name, gen)
  }
  const bound = sessionMap.get(name)
  const engine = sessionEngine(name)
  // resume 判定：claude 查 transcript 存在性；codex 只看有无绑定（无存在性检查——
  // resume 失败走 finishBoot 的死亡兜底：清绑定重试 fresh，同一条恢复链）
  const canResume = engine === "codex"
    ? !!bound
    : !!bound && existsSync(claudeTranscriptPath(bound.claudeSessionId))
  // stream 传输：spawn_cc 显式指定 > 开关；绑定里的 transport 只做记录不否决（09-04 前绑定优先 → 走过一次 stream
  // 就永远 stream，关开关也回不来）。codex 只有 tmux
  const wantStream = engine === "claude" && (transport ?? transportOf(name)) === "stream"
  // 模型（cc-model.ts）：读转录是 await（进门已占代次，期间进来的消息照旧排队）；回来先核对代次
  let launch: LaunchModel = { model: CC_MODEL, source: "默认" }
  if (engine === "claude" && cont?.modelOverride) {
    launch = { model: cont.modelOverride, source: "本次恢复一次性退回（她的选择不动）" }
    launchedModel.set(name, launch)
    console.log(`[hub] ${name} 拉起模型 ${launch.model}（${launch.source}）`)
  } else if (engine === "claude") {
    launch = await resolveLaunchModel(name, canResume ? bound : undefined)
    if (!ownsStartup(name, gen)) { console.log(`[hub] ${name} 读完模型时这次启动已被清掉 / 取代 → 收手`); return }
  }
  if (engine === "claude") noteSessionModelChoice(name, launch.model)
  else void refreshSessionModel(name)   // codex 没有 --model：只能从 rollout 读（新会话还没有，第一轮做完再算）
  if (wantStream) { askUserClearForSession(name, "respawn"); spawnStreamSession(name, chatId, isRetry, bound, canResume, launch.model, gen); return }
  const spawnedAtMs = Date.now()
  let command: string
  if (engine === "codex") {
    // codex 无启动指定 id 的参数：fresh 裸跑（boot 后收割 uuid 存 map），resume 按收割的 uuid。
    // MCP 工具（reply 等）来自 ~/.codex/config.toml 挂的共享 mcp-server，不走 --mcp-config。
    command = (canResume ? `codex resume ${bound!.claudeSessionId}` : freshTerminalLaunch("codex").command)
      + effortArg("codex", wantedEffort.get(name))
  } else {
    if (canResume) {
      if (bound!.transport === "stream") { sessionMap.set(name, { ...bound!, transport: "tmux" }); saveSessionMap() }   // 记录归位（不否决，见上）
      command = `claude --model ${shellQuote(launch.model)}${mcpConfigArg()} --resume ${bound!.claudeSessionId}`
        + effortArg("claude", wantedEffort.get(name))
    } else {
      const fresh = crypto.randomUUID()
      sessionMap.set(name, { claudeSessionId: fresh, chatId: chatId ?? bound?.chatId, updatedAt: new Date().toISOString() })
      saveSessionMap()
      command = freshTerminalLaunch("claude", fresh, launch.model).command + effortArg("claude", wantedEffort.get(name))
    }
  }
  const startEffort = normalizeEffort(engine, wantedEffort.get(name))
  if (startEffort) sessionEffort.set(name, startEffort)
  // 进门就占了代次：spawn 期间进来的消息照旧排进 pendingSends，不会直发给没就绪的会话
  try {
    await tmux.spawn(name, ensureDir(engine === "codex" ? codexWorkdir() : ccWorkdir()), command)
  } catch (e) {
    if (!endStartup(name, gen)) return   // 期间被清掉 / 取代：别人的事
    if (!(e instanceof SessionExistsError)) { console.error(`[hub] ${name} 启动失败（消息留在队列，下次发再拉起）: ${(e as Error)?.message?.split("\n")[0]}`); throw e }
    // 接管已有会话（不是本 hub 这次起的：机器卡时会话表 / has-session 没答上）：恢复原绑定，排队消息照发
    if (bound) sessionMap.set(name, bound); else sessionMap.delete(name)
    saveSessionMap()
    sessionReady.add(name)
    const queued = pendingSends.get(name) ?? []
    pendingSends.delete(name)
    for (const tag of queued) tmux.send(tag, name).catch((err: any) => console.warn(`[hub] flush fail ${name}: ${err.message}`))
    console.warn(`[hub] ${name} 已经在了（会话表误报不在）→ 接管，补发 ${queued.length} 条`)
    return
  }
  askUserClearForSession(name, "respawn")   // 问问题：旧 TUI 随 session 没了，挂着的按 declined 收账
  // resume 要回放历史（大会话还会自动 compact），就绪远慢于 fresh——flush 打早了消息会被加载中的 TUI 吞掉
  const bootMs = canResume ? BOOT_DELAY_MS * 5 : BOOT_DELAY_MS
  console.log(`[hub] spawned tmux:${name} ${canResume ? `resume=${bound!.claudeSessionId.slice(0, 8)}` : "fresh"} (booting ${bootMs}ms)`)
  let bootPane = ""   // boot 期最后一次截屏：死了的话当模型报错证据看
  const finishBoot = async () => {
    if (!ownsStartup(name, gen)) return   // 这次启动已被清掉 / 取代
    // resume 失败兜底：claude 起不来（如 jsonl 坏）→ tmux session 已死 → 清绑定换新会话重试一次
    if (!tmux.hasSession(name)) {
      // 有模型报错证据（boot 期最后一次截屏里）：本次恢复一次性改用默认、保留绑定再试；没证据按原来的死亡处理
      const override = engine === "claude" ? modelRecoveryFor(name, gen, launch.model, bootPane) : undefined
      if (override) {
        await spawnSession(name, chatId, isRetry, undefined, { gen, modelOverride: override }).catch(() => {})   // 失败已在里面记过、释放过
        return
      }
      if (!isRetry) {
        console.warn(`[hub] ${name} died during boot${canResume ? " (resume failed?)" : ""} → retry with fresh session`)
        sessionMap.delete(name); saveSessionMap()
        await spawnSession(name, chatId, true, undefined, { gen }).catch(() => {})   // pendingSends 保留，重试就绪后照常 flush；失败已在里面记过、释放过
      } else {
        endStartup(name, gen)
        console.error(`[hub] ${name} died again on retry — giving up (queued msgs kept for next send)`)
      }
      return
    }
    endStartup(name, gen)
    sessionReady.add(name)
    if (engine === "codex" && !canResume) {
      // fresh codex 就绪 → 收割它自建的 session uuid（resume 的钥匙）。
      // rollout 文件落盘可晚于 boot 完成（e2e 实测恰好临界），10s 间隔重试 3 次。
      const tryHarvest = (attempt: number) => {
        const harvested = harvestCodexSessionId(spawnedAtMs, codexWorkdir())
        if (harvested) {
          sessionMap.set(name, { claudeSessionId: harvested, chatId: chatId ?? bound?.chatId, updatedAt: new Date().toISOString() })
          saveSessionMap()
          console.log(`[hub] ${name} codex uuid 收割 → ${harvested.slice(0, 8)}${attempt > 0 ? `（第 ${attempt + 1} 次）` : ""}`)
          return
        }
        if (attempt < 3) { setTimeout(() => tryHarvest(attempt + 1), 10_000); return }
        console.warn(`[hub] ${name} codex uuid 收割失败（本次会话不可 resume，下次仍 fresh）`)
      }
      tryHarvest(0)
    }
    const queued = pendingSends.get(name)
    pendingSends.delete(name)
    if (queued?.length) {
      for (const tag of queued) { tmux.send(tag, name).catch((e: any) => console.warn(`[hub] flush fail ${name}: ${e.message}`)) }
      console.log(`[hub] ${name} ready → flushed ${queued.length} queued`)
    }
  }
  // boot 弹窗表：headless 必须替人应答，且弹窗全清之前绝不 finishBoot——
  // flush 的消息打进弹窗 = 文本被吞 + Enter 误确认（e2e 实测差点触发 codex 全局升级）。
  const bootDialogs: Array<[marker: string, keys: string[], label: string]> = engine === "codex"
    ? [
        // trust 弹窗只会出现在我们自己指定的 codexWorkdir（搬家 gpt-rp 首跑实卡过：
        // 消息全被弹窗吞 + uuid 收割超窗，07-20）
        ["Do you trust the contents", ["1", "Enter"], "目录信任 → 信任继续"],
        ["Hooks need review", ["3", "Enter"], "hooks 信任 → 不信任继续"],
        ["Update now", ["2", "Enter"], "更新提示 → 跳过（headless 绝不升级）"],
      ]
    : canResume
      ? [["Resume from summary", ["Down", "Enter"], "resume 摘要弹窗 → 完整恢复不丢记忆"]]
      : []
  const settleBoot = async (round: number) => {
    if (!ownsStartup(name, gen)) return
    if (tmux.hasSession(name) && round < 4) {
      const pane = await tmux.capture(name)
      bootPane = pane
      const dialog = bootDialogs.find(([marker]) => pane.includes(marker))
      if (dialog) {
        try {
          for (const key of dialog[1]) await tmux.key(key, name)
          console.log(`[hub] ${name} boot 弹窗「${dialog[2]}」已应答，再等 ${bootMs}ms`)
        } catch (e: any) { console.warn(`[hub] ${name} boot 弹窗处理失败: ${e.message}`) }
        setTimeout(() => void settleBoot(round + 1), bootMs)
        return
      }
    }
    await finishBoot()
  }
  setTimeout(() => void settleBoot(0), bootMs)
}

// 确保 session 就绪后注入 channel tag（不在→spawn，boot 中→排队，老 session→直接发）。
// ready 态 send 失败 = session 被外部杀了（tmux kill / claude 崩）→ 清态、消息入队、重 spawn（resume 找回记忆），不丢。
/// 带思考强度的发送（effort.ts）：没要求 / 跟现在一样 → 照常发；claude 终端会话先发 `/effort <档>` 再发消息；
/// stream 会话中途改不了（streamSendRaw 只认 /clear），等下次启动带 --effort；codex 跑着就杀掉用同一 id 恢复（带 -c 参数）
/// 普通发送同步入队、返回 undefined（调用方别 await，否则注入会抢在 ack 前面）；只有 codex 重启返回 Promise，等 kill→重起
export function sendWithEffort(name: string, tag: string, chatId: string | undefined, rawEffort: unknown): Promise<void> | undefined {
  const engine = sessionEngine(name)
  const want = normalizeEffort(engine, rawEffort)
  if (want) wantedEffort.set(name, want)
  const live = sessionReady.has(name) && tmux.hasSession(name)
  const change = live ? effortChange(engine, sessionEffort.get(name), want) : { respawn: false }
  if (change.command && !streamRunner.has(name)) {
    const cmd = change.command
    void (async () => {
      try { await tmux.sendRaw(cmd, name); sessionEffort.set(name, want!) ; console.log(`[hub] effort ${name} → ${want}`) }
      catch (e: any) { console.warn(`[hub] effort ${name} 切换失败（照常发消息）: ${e?.message?.split("\n")[0]}`) }
      ensureSessionAndSend(name, tag, chatId)
    })()
    return
  }
  if (change.respawn && sessionMap.get(name)?.claudeSessionId) {
    return (async () => {
      try { await baseTmux.kill(name) } catch (e: any) { console.warn(`[hub] effort 重启 kill ${name} 失败: ${e?.message}`) }
      clearSessionState(name)
      console.log(`[hub] effort ${name} → ${want}：codex 用同一会话 id 重启`)
      ensureSessionAndSend(name, tag, chatId)
    })()
  }
  ensureSessionAndSend(name, tag, chatId)
}

export function ensureSessionAndSend(name: string, tag: string, chatId?: string): void {
  void ensureSessionAndSendAsync(name, tag, chatId).catch(() => {})   // 自愈在 async 版内部，这里吞尾
}

/// async 版：resolve=已注入或已排队（spawn 流程接手），reject=永远不会（自愈内化）。
/// agora executor 用它感知"直接注入失败"（reject 前已重排 spawn，claim 由 lease 兜底）。
export async function ensureSessionAndSendAsync(name: string, tag: string, chatId?: string): Promise<void> {
  if (sessionReady.has(name)) {
    try { await tmux.send(tag, name); return } catch (e: any) {
      // 结果不明（tmux 卡住超时 / 控制连接断，文本可能已经进了输入框）：不清态、不重发，告诉 app（审查 R1-2：原来这里整条重发 = 两遍）。
      // realTmuxRunner.send 已经在会话链里核对完（sendTracked，K1 第 4b 步），不会再抛到这里；这里只兜别的 runner
      if (e instanceof TmuxUncertainError) { reportUncertainSend(name, tag, e); return }
      console.warn(`[hub] send fail ${name}（session 死了？）→ 清态重 spawn: ${e.message?.split("\n")[0]}`)
      clearSessionState(name)   // 掉下去走 spawn 路径，消息不丢
    }
  }
  if (sessionSpawning.has(name)) { const q = pendingSends.get(name) ?? []; q.push(tag); pendingSends.set(name, q); return }
  if (tmux.hasSession(name)) {
    sessionReady.add(name)
    try { await tmux.send(tag, name) } catch (e: any) {
      if (e instanceof TmuxUncertainError) reportUncertainSend(name, tag, e)
      else console.warn(`[hub] send fail ${name}: ${e.message}`)
    }
    return   // hub 重启前就在的老 session，claude 早就绪
  }
  const q = pendingSends.get(name) ?? []; q.push(tag); pendingSends.set(name, q); await spawnSession(name, chatId)  // 全新（或 resume 绑定的记忆）
}

/// 写进 tmux 的那一下结果不明（发出去了没拿到回执）：消息可能已经在输入框里，也可能没有，自动重发会发两遍。
/// 记一行、给所有 app 发一帧 error（带 message_id），由她看一眼终端再决定要不要重发。
/// 最坏要等多久才知道：见 perf/hub-实验日志.md「K1 第 4 步 · 审查 R1」
function reportUncertainSend(name: string, tag: string, e: Error): void {
  const messageId = /message_id="([^"]*)"/.exec(tag)?.[1]
  console.warn(`[hub] send 结果不明 ${name}${messageId ? ` message_id=${messageId}` : ""}（不自动重发）: ${e.message.split("\n")[0]}`)
  const frame = JSON.stringify({
    type: "error",
    ...(messageId ? { message_id: messageId } : {}),
    session_name: name,
    reason: `tmux 卡住了，这条消息不确定有没有送进 ${name}（没有自动重发，看一眼终端再决定要不要重发）`,
  })
  for (const c of mpClients) { try { c.send(frame) } catch {} }
}

export function listSessions(): string[] {
  return tmux.list().filter(sessionName => sessionName.startsWith("mp-cc") || sessionName.startsWith("mp-codex"))
}

/// session 名 → 引擎。mp-codex* 跑 codex CLI，mp-win-* 是裸 shell（全局终端窗口），其余 claude。
///
/// shell 分支是防御性的：现有那些 `sessionEngine(s) === "claude"` 的判断（如 keepalive）
/// 会因此自动排除全局窗口 —— 不会有保暖 ping 被 send-keys 打进你的 shell。
export function sessionEngine(name: string): "claude" | "codex" | "shell" {
  if (name.startsWith("mp-codex")) return "codex"
  if (isWindowSession(name)) return "shell"
  return "claude"
}

// ── stream 会话（无终端）：spawn / ready / exit / 权限桥 / 斜杠命令 ──
// AskUserQuestion 的卡仍由 cc-rp 的 PreToolUse hook 发给 app（-p 下 hooks 照跑，实测），这里只挂 respond；
// 其他工具的权限没有 hook，hub 合成一张"允许 X？"卡走同一条 askuser 路径。
const streamAskPending = new Map<string, { respond: Respond; input: any; toolUseId?: string }>()     // key: session
const streamPermPending = new Map<string, { respond: Respond; input: any; session: string }>()        // key: perm:<request_id>
// PreToolUse hook 的卡比 control_request 先到 hub；app 若在这个窗口里答了，先暂存，control_request 一到立即回
const streamAskEarly = new Map<string, { verdict: ControlVerdict | "skip"; toolUseId: string }>()      // key: session
const streamRetried = new Set<string>()
const STREAM_READY_TIMEOUT_MS = Number(process.env.MP_CC_STREAM_READY_MS) || 30_000

// 开关是唯一真相（09-04 粟粟：关了开关会话不回终端）。
// 关→tmux：活着的 stream 会话空闲即收（正在跑一轮的等 result），kill 后错开几秒按当前开关重生
//（同一 claudeSessionId --resume 进 tmux，对话不丢）；开→stream：不碰活着的 tmux 会话，只管之后新起/续起的。
// spawn_cc 显式 transport 只是建会话那一下的覆盖，下一次 set_cc_config 照样按开关收编。
const streamRetireWhenIdle = new Set<string>()   // 传输不符但正忙的会话（tmux 或 stream），本轮结束后收编
const STREAM_RETIRE_STAGGER_MS = Number(process.env.MP_CC_STREAM_RETIRE_STAGGER_MS) || 8_000   // 几个一起收时错开重生，别同时 resume

// 旧签名保留给测试：全局开关语义 = 所有活着的 stream 会话 want 同一个值
export function planStreamReconcile(
  transport: "tmux" | "stream",
  live: { name: string; busy: boolean }[],
  pending: Iterable<string>,
): { retireNow: string[]; retireLater: string[]; cancel: string[] } {
  return planTransportReconcile(live.map((s) => ({ ...s, transport: "stream" as const })), () => transport, pending)
}

/// 双向收编：活着的 claude 会话里传输 ≠ transportOf(name) 的，空闲立收、忙等本轮；重新符合的取消等待。
function reconcileStreamTransport(): void {
  const live: LiveSession[] = []
  for (const name of streamRunner.list()) live.push({ name, transport: "stream", busy: streamRunner.isBusy(name) })
  for (const name of baseTmux.list()) {
    if (!name.startsWith("mp-cc") || sessionEngine(name) !== "claude" || isWindowSession(name)) continue
    live.push({ name, transport: "tmux", busy: laPhaseBySession.get(name)?.phase === "working" })
  }
  // 只收编她在长按菜单里单独设过的会话。全局开关只管新建（09-19：一台设备打开全局开关，
  // 五条长会话被整体收编成 stream，resume 超时又被换成全新会话）
  const plan = planTransportReconcile(live.filter((s) => transportPolicies.has(s.name)), transportOf, streamRetireWhenIdle)
  for (const n of plan.cancel) streamRetireWhenIdle.delete(n)
  if (plan.cancel.length) console.log(`[hub] transport retire 取消 ${plan.cancel.join(",")}（已符合当前策略）`)
  plan.retireNow.forEach((n, i) => void retireForTransport(n, "传输策略变了", i * STREAM_RETIRE_STAGGER_MS))
  for (const n of plan.retireLater) { streamRetireWhenIdle.add(n); console.log(`[hub] ${n} 正在跑一轮，本轮结束后按新传输重生`) }
}

/// 传输不符的会话：stream 走 retireStreamSession；tmux 会话 kill 后同样延迟按 transportOf 重生（--resume 同一 claudeSessionId）
async function retireForTransport(name: string, why: string, respawnDelayMs: number): Promise<void> {
  if (streamRunner.has(name)) { retireStreamSession(name, why, respawnDelayMs); return }
  const bound = sessionMap.get(name)
  streamRetireWhenIdle.delete(name)
  try { await baseTmux.kill(name) } catch (e: any) { console.warn(`[hub] transport retire kill ${name} fail: ${e?.message}`); return }
  clearSessionState(name)
  askUserClearForSession(name, "transport_retire")
  console.log(`[hub] tmux retire ${name}（${why}）→ ${respawnDelayMs / 1000}s 后按传输策略重生`)
  setTimeout(() => {
    if (tmux.hasSession(name) || sessionSpawning.has(name)) return
    spawnSession(name, bound?.chatId).catch((e: any) => console.warn(`[hub] tmux retire ${name} 重生失败（下次 send 再拉起）: ${e?.message?.split("\n")[0]}`))
  }, respawnDelayMs)
}

/// 收掉一个 stream 会话：kill（不触发 onExit）+ 清态，delay 后按当前开关重生（期间被消息拉起就不重复）
function retireStreamSession(name: string, why: string, respawnDelayMs: number): void {
  const bound = sessionMap.get(name)
  streamRetireWhenIdle.delete(name)
  streamRunner.kill(name)
  sessionReady.delete(name); sessionSpawning.delete(name)
  streamAskPending.delete(name); streamAskEarly.delete(name)
  for (const [k, v] of streamPermPending) if (v.session === name) streamPermPending.delete(k)
  askUserClearForSession(name, "stream_retire")
  console.log(`[hub] stream retire ${name}（${why}）→ ${respawnDelayMs / 1000}s 后按当前开关重生`)
  setTimeout(() => {
    if (tmux.hasSession(name) || sessionSpawning.has(name)) return
    spawnSession(name, bound?.chatId).catch((e: any) => console.warn(`[hub] stream retire ${name} 重生失败（下次 send 再拉起）: ${e?.message?.split("\n")[0]}`))
  }, respawnDelayMs)
}

/// 本次启动死了：有模型报错证据、预算还在 → 本次恢复一次性改用 hub 默认（不写她的记录，下次拉起照旧用她选的）。tmux / stream 共用
function modelRecoveryFor(name: string, gen: number, launched: string, evidence: string): string | undefined {
  const st = sessionSpawning.get(name)
  if (!st || st.gen !== gen) return undefined
  const override = planModelRecovery({ launched, fallback: CC_MODEL, evidence, used: st.modelOverrides })
  if (!override) return undefined
  st.modelOverrides++
  console.warn(`[hub] ${name} 用 ${launched} 起不来、输出里有模型报错 → 本次恢复一次性改用 ${override}（绑定、她的选择都不动）`)
  return override
}

/// 启动失败（进程没就绪就死 / 就绪超时）：重试一次 fresh，再失败放弃（队列消息保留等下次 send）。重试带着本代次，放弃时结束本代次。
/// evidence：进程 stderr 尾巴，有模型报错就先按模型恢复再试（不算进 streamRetried）
function streamBootFailed(name: string, why: string, gen: number, evidence = ""): void {
  if (!ownsStartup(name, gen)) return
  const bound = sessionMap.get(name)
  const launched = launchedModel.get(name)?.model
  const override = launched ? modelRecoveryFor(name, gen, launched, evidence) : undefined
  if (override) {
    void spawnSession(name, bound?.chatId, streamRetried.has(name), "stream", { gen, modelOverride: override }).catch(() => {})
    return
  }
  // 有转录的会话 resume 慢（几十万 token 要读完）≠ 坏了：绝不清绑定换新会话，重试一次 resume，再不行放弃（消息留队列）
  if (bound && existsSync(claudeTranscriptPath(bound.claudeSessionId))) {
    if (!streamRetried.has(name)) {
      console.warn(`[hub] stream ${name} resume 启动失败（${why}）→ 再 resume 一次，保留绑定 ${bound.claudeSessionId.slice(0, 8)}`)
      void spawnSession(name, bound.chatId, true, "stream", { gen }).catch(() => {})   // 失败已在里面记过、释放过
    } else {
      endStartup(name, gen)
      console.error(`[hub] stream ${name} resume 再次失败（${why}）— 放弃，绑定保留，下次 send 再拉起`)
    }
    return
  }
  if (!streamRetried.has(name)) {
    console.warn(`[hub] stream ${name} boot 失败（${why}）→ retry with fresh session`)
    sessionMap.delete(name); saveSessionMap()
    void spawnSession(name, bound?.chatId, true, "stream", { gen }).catch(() => {})
  } else {
    endStartup(name, gen)
    console.error(`[hub] stream ${name} boot 再次失败（${why}）— giving up (queued msgs kept)`)
  }
}

function spawnStreamSession(name: string, chatId: string | undefined, isRetry: boolean, bound: SessionBinding | undefined, canResume: boolean, model: string, gen: number): void {
  let id: string
  if (canResume) {
    id = bound!.claudeSessionId
    if (bound!.transport !== "stream") { sessionMap.set(name, { ...bound!, transport: "stream" }); saveSessionMap() }
  } else {
    id = crypto.randomUUID()
    sessionMap.set(name, { claudeSessionId: id, chatId: chatId ?? bound?.chatId, updatedAt: new Date().toISOString(), transport: "stream" })
    saveSessionMap()
  }
  if (isRetry) streamRetried.add(name); else streamRetried.delete(name)
  try {
    streamRunner.spawn(name, {
      cwd: ensureDir(ccWorkdir()), model, mcpConfig: ccMcpConfig(),
      env: { MP_CC_SESSION_NAME: name, MP_CC_HUB_PORT: String(PORT) },   // hook 回传口：内嵌 hub 的 env 里是 "0"（#046）
      resumeId: canResume ? id : undefined, sessionId: canResume ? undefined : id,
      effort: normalizeEffort("claude", wantedEffort.get(name)),
    })
  } catch (e) {
    // 同步抛错（可执行文件不在、参数不对…）：释放本代次，消息留队列，下次发消息再拉起（审查 R1-2：原来永远卡在 spawning）
    endStartup(name, gen)
    console.error(`[hub] stream ${name} 启动失败（消息留在队列，下次发再拉起）: ${(e as Error)?.message?.split("\n")[0]}`)
    throw e
  }
  console.log(`[hub] stream spawn ${name} ${canResume ? "resume" : "fresh"}=${id.slice(0, 8)}`)
  const readyMs = canResume ? Math.max(STREAM_READY_TIMEOUT_MS, 180_000) : STREAM_READY_TIMEOUT_MS   // 长会话 resume 要读完转录
  setTimeout(() => {
    if (!ownsStartup(name, gen)) return
    if (streamRunner.has(name) && !streamRunner.isReady(name)) {
      const evidence = streamRunner.stderrTail(name)
      streamRunner.kill(name)
      streamBootFailed(name, `${readyMs / 1000}s 无 initialize 应答`, gen, evidence)
    }
  }, readyMs)
}

function onStreamReady(name: string, sid: string): void {
  sessionSpawning.delete(name)
  sessionReady.add(name)
  const bound = sessionMap.get(name)
  if (bound && sid && bound.claudeSessionId !== sid) console.warn(`[hub] stream ${name} init sid=${sid.slice(0, 8)} ≠ 绑定 ${bound.claudeSessionId.slice(0, 8)}`)
  const queued = pendingSends.get(name)
  pendingSends.delete(name)
  for (const tag of queued ?? []) tmux.send(tag, name).catch((e: any) => console.warn(`[hub] stream flush fail ${name}: ${e?.message}`))
  console.log(`[hub] stream ready ${name} sid=${sid.slice(0, 8)}${queued?.length ? ` → flushed ${queued.length}` : ""}`)
}

function onStreamExit(name: string, code: number | null, wasReady: boolean, stderrTail = ""): void {
  const startup = sessionSpawning.get(name)
  sessionReady.delete(name)
  streamRetireWhenIdle.delete(name)
  streamAskPending.delete(name)
  streamAskEarly.delete(name)
  for (const [k, v] of streamPermPending) if (v.session === name) streamPermPending.delete(k)
  askUserClearForSession(name, "stream_exit")
  if (!wasReady && startup) { streamBootFailed(name, `died during boot code=${code}`, startup.gen, stderrTail); return }
  if (startup) sessionSpawning.delete(name)
  console.log(`[hub] stream exit ${name} code=${code}`)
}

function permPreview(tool: string, input: any): string {
  if (!input || typeof input !== "object") return ""
  const v = tool === "Bash" ? input.command : (input.file_path ?? input.path ?? input.pattern ?? input.url)
  return String(v ?? JSON.stringify(input)).slice(0, 300)
}

function onStreamControlRequest(name: string, req: ControlRequest, respond: Respond): void {
  if (req.subtype !== "can_use_tool") {
    console.warn(`[hub] stream ${name} control_request/${req.subtype} 未处理 → deny`)
    respond({ behavior: "deny", message: "unsupported control request" })
    return
  }
  const bound = sessionMap.get(name)
  if (req.tool_name === "AskUserQuestion") {
    const early = streamAskEarly.get(name)
    if (early) {
      streamAskEarly.delete(name)
      if (early.verdict === "skip") { respond({ behavior: "deny", message: "user skipped the question" }); resolveAskUserDeclined(early.toolUseId, "app_skip") }
      else respond({ behavior: "allow", updatedInput: { ...(req.input ?? {}), ...(early.verdict.updatedInput ?? {}) } })
      console.log(`[hub] stream ${name} AskUserQuestion 用早到的答案回 tool_use=${(req.tool_use_id ?? "?").slice(0, 12)}`)
      return
    }
    streamAskPending.set(name, { respond, input: req.input, toolUseId: req.tool_use_id })
    console.log(`[hub] stream ${name} AskUserQuestion 等 app 答 tool_use=${(req.tool_use_id ?? "?").slice(0, 12)}`)
    return
  }
  // chat 来源：绑定里的（spawn 时带的）或最近一次 send 的（spawn_cc 建的会话绑定里没 chat）
  const chatId = bound?.chatId ?? sessionActivity.get(name)?.lastChatId
  const preview = permPreview(req.tool_name ?? "", req.input)
  if (!chatId) {
    console.warn(`[hub] stream ${name} ${req.tool_name} 权限请求但会话未绑 chat → deny`)
    respond({ behavior: "deny", message: "no chat bound to relay the permission prompt" })
    return
  }
  const id = `perm:${req.request_id}`
  streamPermPending.set(id, { respond, input: req.input, session: name })
  askUserRegisterExternal({
    toolUseId: id, chatId, sessionId: bound?.claudeSessionId ?? "", sessionName: name, ts: Date.now(),
    questions: [{ question: `允许 ${req.tool_name}？`, header: "权限", options: [{ label: "允许", description: preview }, { label: "拒绝" }] }],
  })
  onLaPhaseEvent(name, { kind: "ask_pre", detail: `允许 ${req.tool_name}？${preview ? " " + preview : ""}` })   // 进度卡 B：等批准也是「等你」
  console.log(`[hub] stream ${name} 权限卡 → app: ${req.tool_name} ${preview.slice(0, 60)}`)
}

/// stream 会话的答题：不走 TUI 键序，直接回 control_response。返回 true = 已处理
function streamAnswer(p: PendingAskUser, toolUseId: string, answers: AskAnswer[] | null, skip: boolean): boolean {
  const perm = streamPermPending.get(toolUseId)
  if (perm) {
    streamPermPending.delete(toolUseId)
    const allow = !skip && (answers?.[0]?.indices?.[0] ?? -1) === 0
    perm.respond(allow ? { behavior: "allow", updatedInput: perm.input } : { behavior: "deny", message: "denied in app" })
    askUserResolveExternal(toolUseId, { [p.questions[0]?.question ?? "权限"]: allow ? "允许" : "拒绝" })
    onLaPhaseEvent(perm.session, { kind: "ask_post" })
    console.log(`[hub] stream perm ${allow ? "allow" : "deny"} ${toolUseId.slice(0, 20)}`)
    return true
  }
  const session = p.sessionName ?? ""
  if (!streamRunner.has(session)) return false
  const ask = streamAskPending.get(session)
  const formatted = (!skip && answers) ? askUserFormatAnswers(p.questions, answers) : null
  if (!ask) {
    // control_request 还没到（hook 先于它）：暂存，到了立即回
    streamAskEarly.set(session, { verdict: formatted ? { behavior: "allow", updatedInput: { answers: formatted } } : "skip", toolUseId })
    if (formatted) askUserMarkDriven(toolUseId, formatted)
    console.log(`[hub] stream ${session} 答案早于 control_request，暂存 tool_use=${toolUseId.slice(0, 12)}`)
    return true
  }
  streamAskPending.delete(session)
  if (!formatted) {
    ask.respond({ behavior: "deny", message: "user skipped the question" })
    resolveAskUserDeclined(toolUseId, "app_skip")
    return true
  }
  ask.respond({ behavior: "allow", updatedInput: { ...(ask.input ?? {}), answers: formatted } })
  askUserMarkDriven(toolUseId, formatted)
  console.log(`[hub] stream askuser answered tool_use=${toolUseId.slice(0, 12)}`)
  return true
}

/// stream 会话的斜杠命令：-p 不认。/clear = 换新会话重生；其余不支持
async function streamSendRaw(text: string, name: string): Promise<void> {
  const cmd = text.trim()
  if (cmd === "/clear") {
    const bound = sessionMap.get(name)
    streamRunner.kill(name)
    sessionReady.delete(name); sessionSpawning.delete(name)
    streamAskPending.delete(name); streamAskEarly.delete(name)
    askUserClearForSession(name, "clear")
    sessionMap.delete(name); saveSessionMap()
    await spawnSession(name, bound?.chatId)   // 按当前开关：关了就回终端
    console.log(`[hub] stream ${name} /clear → 新会话（按当前开关）`)
    return
  }
  console.warn(`[hub] stream ${name} 不支持斜杠命令 ${cmd.slice(0, 24)}（无终端模式）`)
}

// ── 全局终端窗口 ──
// 跟对话无关的全局终端，从任何对话进 CC 终端页看到的都是同一批。
// 注册表记 code / engine / 建的时间 / 关的时间；tmux session 的死活单独查。
const windowsPath = join(SECRETS_DIR, "windows.json")
const conversationTitlesPath = join(SECRETS_DIR, "terminal-titles.json")
let terminalWindows: TerminalWindow[] = []
const openingWindowCodes = new Set<string>()   // 已抽号、spawn 还在 await、没入表的窗口：并发开窗别撞号
const conversationCustomTitles = new Map<string, string>()

function loadTerminalWindows(): void {
  terminalWindows = loadWindows(windowsPath)
  const open = openWindows(terminalWindows).length
  console.log(`[hub] terminal windows loaded (${open} open / ${terminalWindows.length} total)`)
}

function persistTerminalWindows(): void {
  saveWindows(windowsPath, terminalWindows)
}

function loadConversationTitles(): void {
  try {
    if (!existsSync(conversationTitlesPath)) return
    const stored = JSON.parse(readFileSync(conversationTitlesPath, "utf-8")) as Record<string, string>
    for (const [sessionName, title] of Object.entries(stored)) {
      const clean = resolveTerminalTitle(title, undefined, "shell")
      if (clean) conversationCustomTitles.set(sessionName, clean)
    }
  } catch { /* 标题表坏了只丢手动名，不拖垮 hub */ }
}

function saveConversationTitles(): void {
  try {
    writeFileSync(conversationTitlesPath, JSON.stringify(Object.fromEntries(conversationCustomTitles), null, 2))
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    console.warn(`[hub] terminal titles save fail: ${message}`)
  }
}

/// 起一个全局终端 tmux session。agent 窗口每次都 fresh，不进 sessionMap。
///
/// 完全不走 spawnSession —— 那边的 resume/sessionMap、boot 和 pending send
/// 都是对话语义；全局 agent 窗口跟 shell 一样起好后由人直接操作。
///
/// ⚠️ 必须 login shell：hub 由 launchd 拉起，PATH 不完整（记忆在案：漏了 ~/.local/bin
/// 会让 claude 全 127）。`-l` 加载 .zprofile 才能拿到跟终端里一样的 PATH。
async function spawnTerminalWindow(code: string, engine: TerminalEngine): Promise<void> {
  const name = sessionNameFor(code)
  if (tmux.hasSession(name)) return
  const launch = windowLaunch(engine)
  await tmux.spawn(name, launch.cwd, launch.command)
  console.log(`[hub] spawned ${engine} window tmux:${name}`)
}

/// 同上，但 tmux 抛错（没装 / 起不来）不往外冒：返回给手机看的中文原因，成功返回 null
async function spawnTerminalWindowSafely(code: string, engine: TerminalEngine): Promise<string | null> {
  try {
    await spawnTerminalWindow(code, engine)
    return null
  } catch (e: any) {
    console.warn(`[hub] spawn window ${code} failed: ${e?.message}`)
    return e?.code === "ENOENT" ? "电脑上没装 tmux（brew install tmux）" : "电脑上开不了这个窗口"
  }
}

/// 给 app 的窗口列表：注册表 + 每个的 tmux 存活状态 + 标题 / 引擎 / phase（取法同 terminal_state）。
/// 关掉的不返回（它们只出现在「恢复」菜单里，走 include_closed）。
function windowListPayload(includeClosed: boolean): Array<Record<string, unknown>> {
  const source = includeClosed ? liveWindows(terminalWindows) : openWindows(terminalWindows)
  const names = source.map(w => sessionNameFor(w.code))
  const paneTitles = tmux.paneTitles(names)
  const paneMeta = tmux.paneMeta?.(names) ?? new Map<string, PaneMeta>()
  return source.map(w => {
    const sessionName = sessionNameFor(w.code)
    const engine = w.engine === "claude" || w.engine === "codex" ? w.engine : "shell"
    return {
      code: w.code,
      created_at: w.createdAt,
      closed_at: w.closedAt ?? null,
      alive: tmux.hasSession(sessionName),
      title: windowTitle(w.customTitle, paneTitles.get(sessionName), engine, paneMeta.get(sessionName)),
      engine,
      phase: sessionPhase(sessionName, engine, paneMeta.get(sessionName)) ?? "idle",
    }
  })
}

/// tmux 默认 pane_title = 主机名，几种写法都算（Susus-MacBook.local / Susus-MacBook）
const HOST_NAMES = [...new Set([hostname(), hostname().replace(/\.local$/, ""), hostname().split(".")[0]])]

/// 标题链 + shell 兜底「shell · 目录名」（#046 T13）
function windowTitle(custom: string | undefined, paneTitle: string | undefined, engine: TerminalEngine, meta: PaneMeta | undefined): string | null {
  return resolveWindowTitle(custom, paneTitle, engine, meta?.path, HOST_NAMES, homedir())
}

/// phase：Claude 来自 hook（laPhaseBySession）；Codex 没 hook，按最近有没有输出粗判（#046 T22）；shell 不画
function sessionPhase(sessionName: string, engine: TerminalEngine, meta: PaneMeta | undefined): TerminalPhase | undefined {
  if (engine === "codex") return codexPhaseFromActivity(meta?.activitySec, Math.floor(Date.now() / 1000))
  return laPhaseBySession.get(sessionName)?.phase
}

/// codex 无启动指定 session id 的参数——fresh 跑完后从 ~/.codex/sessions 收割新会话 uuid
/// （rollout-<ts>-<uuid>.jsonl，首行 payload 有 cwd）。按 spawn 时刻 + cwd 双过滤，
/// 防她同时手开 codex 撞车。失败返回 null（不存 map，下次仍 fresh——降级不炸）。
export function harvestCodexSessionId(spawnedAtMs: number, expectCwd: string): string | null {
  const root = `${process.env.HOME}/.codex/sessions`
  let best: { uuid: string; mtime: number } | null = null
  const scanDay = (d: Date) => {
    const dir = `${root}/${d.getFullYear()}/${String(d.getMonth() + 1).padStart(2, "0")}/${String(d.getDate()).padStart(2, "0")}`
    let files: string[] = []
    try { files = readdirSync(dir) } catch { return }
    for (const f of files) {
      const m = f.match(/^rollout-.*-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/)
      if (!m) continue
      const path = `${dir}/${f}`
      let mtime = 0
      try { mtime = statSync(path).mtimeMs } catch { continue }
      if (mtime < spawnedAtMs - 5_000) continue
      try {
        const firstLine = readFileSync(path, "utf8").split("\n", 1)[0]
        const payload = (JSON.parse(firstLine) as { payload?: { id?: string; cwd?: string } }).payload
        if (payload?.cwd !== expectCwd || payload.id !== m[1]) continue
      } catch { continue }
      if (!best || mtime > best.mtime) best = { uuid: m[1], mtime }
    }
  }
  const now = new Date()
  scanDay(now)
  scanDay(new Date(now.getTime() - 86_400_000))   // 跨午夜
  return best?.uuid ?? null
}

// session 被 kill 时清就绪态
function clearSessionState(name: string): void {
  sessionReady.delete(name); sessionSpawning.delete(name); pendingSends.delete(name)
  sessionEffort.delete(name)   // 会话没了：下次启动按 wantedEffort 带参数
}

function reapProtectedSessions(): Set<string> {
  const names = new Set<string>()
  // #if PERSONAL_APPS
  for (const n of warroomCentralSessions()) names.add(n)
  names.add(WARROOM_DESK_SESSION)
  // #endif
  return names
}

async function transcriptMtimeMs(path: string): Promise<number | undefined> {
  try { return (await stat(path)).mtimeMs } catch { return undefined }
}

/// kill 闲置会话，sessionMap 绑定留着：下次发消息 spawnSession 按绑定 --resume 接回上下文
export async function reapIdleSessions(
  sessions: Iterable<string>, now = Date.now(), mtimeMs = transcriptMtimeMs,
): Promise<string[]> {
  const thresholdMs = reapThresholdMs(process.env.MP_CC_REAP_DAYS)
  const plan = await planReap({
    sessions, now, mtimeMs, thresholdMs,
    protectedNames: reapProtectedSessions(),
    busy: (s) => sessionSpawning.has(s) || pendingSends.has(s) || sendTracker.busy(s),
    lastSendAt: (s) => sessionActivity.get(s)?.lastUserSendAt,
    transcriptPath: (s) => {
      const bound = sessionMap.get(s)
      return bound && sessionEngine(s) === "claude" ? claudeTranscriptPath(bound.claudeSessionId) : undefined
    },
  })
  const unknownLine = reapUnknownLogLine(plan.unknown)
  if (unknownLine) console.log(`[hub] ${unknownLine}`)
  const reaped: string[] = []
  for (const c of plan.reap) {
    // stat 的 await 期间她发了消息
    if (sessionSpawning.has(c.session) || pendingSends.has(c.session) || sendTracker.busy(c.session) || (sessionActivity.get(c.session)?.lastUserSendAt ?? 0) > now - thresholdMs) continue
    const genBefore = lastStartupGen.get(c.session)
    try {
      await tmux.kill(c.session)
      sessionActivity.delete(c.session)
      // kill 的 await 期间她发消息又拉起了（新代次）：只清就绪，新启动的代次和排队消息不动（原来无条件清掉）
      if (lastStartupGen.get(c.session) !== genBefore) { sessionReady.delete(c.session); sessionEffort.delete(c.session) }
      else clearSessionState(c.session)
      reaped.push(c.session)
      console.log(`[hub] ${reapLogLine(c)}`)
    } catch (e) { console.warn(`[hub] reap fail ${c.session}: ${e}`) }
  }
  return reaped
}

// ── C2 图片/文件互发 ──
const MAX_IMG_BYTES = 10 * 1024 * 1024    // 图片 10MB
const MAX_FILE_BYTES = 25 * 1024 * 1024   // 任意文件 25MB
function extFromMime(mime?: string): string {
  switch (mime) {
    case "image/png": return "png"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "image/heic": return "heic"
    default: return "jpg"
  }
}
function mimeFromExt(ext: string): string {
  switch (ext.toLowerCase().replace(".", "")) {
    case "jpg": case "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "heic": return "image/heic"
    case "pdf": return "application/pdf"
    case "txt": case "md": case "log": case "csv": return "text/plain"
    case "json": return "application/json"
    case "zip": return "application/zip"
    case "html": case "htm": return "text/html"
    default: return "application/octet-stream"
  }
}
// susu→CC：把 send 帧里的 base64 图写到 mp-inbox，返回落盘路径（给 CC Read）
function saveInboundImages(chatId: string, images: any[]): string[] {
  const dir = join(ccWorkdir(), "mp-inbox", chatId.slice(0, 16))
  const paths: string[] = []
  try { mkdirSync(dir, { recursive: true }) } catch {}
  let i = 0
  for (const img of images) {
    if (typeof img?.b64 !== "string") continue
    const buf = Buffer.from(img.b64, "base64")
    if (buf.length === 0 || buf.length > MAX_IMG_BYTES) continue
    const p = join(dir, `${Date.now()}_${i}.${extFromMime(img.mime)}`)
    try { writeFileSync(p, buf); paths.push(p); i++ } catch (e: any) { console.warn(`[hub] save inbound img fail: ${e.message}`) }
  }
  return paths
}
// susu→CC：把 send 帧里的 base64 文件写到 mp-inbox（保留原名/后缀），返回路径
function saveInboundFiles(chatId: string, files: any[]): string[] {
  const dir = join(ccWorkdir(), "mp-inbox", chatId.slice(0, 16))
  const paths: string[] = []
  try { mkdirSync(dir, { recursive: true }) } catch {}
  let i = 0
  for (const f of files) {
    if (typeof f?.b64 !== "string") continue
    const buf = Buffer.from(f.b64, "base64")
    if (buf.length === 0 || buf.length > MAX_FILE_BYTES) continue
    const safeName = (typeof f.name === "string" && f.name ? f.name : `file_${i}`).replace(/[/\\]/g, "_")
    const p = join(dir, `${Date.now()}_${i}_${safeName}`)
    try { writeFileSync(p, buf); paths.push(p); i++ } catch (e: any) { console.warn(`[hub] save inbound file fail: ${e.message}`) }
  }
  return paths
}
function isImageMime(mime: string): boolean { return mime.startsWith("image/") }
// CC→susu：把 CC 给的任意文件拷到 mp-outbox（持久，供 replay 重读），返回 {name,mime,path}
function stageOutboundFile(chatId: string, srcPath: string): { name: string; mime: string; path: string } | null {
  try {
    const resolved = srcPath.startsWith("/") ? srcPath : join(ccWorkdir(), srcPath)
    if (!existsSync(resolved)) { console.warn(`[hub] outbound file not found: ${resolved}`); return null }
    if (statSync(resolved).size > MAX_FILE_BYTES) { console.warn(`[hub] outbound file too big: ${resolved}`); return null }
    const dir = join(ccWorkdir(), "mp-outbox", chatId.slice(0, 16))
    try { mkdirSync(dir, { recursive: true }) } catch {}
    const name = basename(resolved)
    const dest = join(dir, `${Date.now()}_${name}`)
    copyFileSync(resolved, dest)
    return { name, mime: mimeFromExt(extname(resolved)), path: dest }
  } catch (e: any) { console.warn(`[hub] stage outbound file fail: ${e.message}`); return null }
}
// 读 mp-outbox 文件 → {name,mime,b64,isImage}
function readFileB64(path: string): { name: string; mime: string; b64: string; isImage: boolean } | null {
  try {
    if (!existsSync(path)) return null
    const buf = readFileSync(path)
    if (buf.length === 0 || buf.length > MAX_FILE_BYTES) return null
    const mime = mimeFromExt(extname(path))
    return { name: basename(path), mime, b64: buf.toString("base64"), isImage: isImageMime(mime) }
  } catch { return null }
}

// MP 客户端集合（/cc 路径连接的 MP 客户端）

const mpClients = new Set<WebSocket>()
const memoryReplies = new WeakMap<WebSocket, MemoryReplies>()
function memoryRepliesFor(ws: WebSocket): MemoryReplies {
  let r = memoryReplies.get(ws)
  if (!r) memoryReplies.set(ws, r = new MemoryReplies((frame) => { try { ws.send(frame) } catch {} }))
  return r
}

// ── #046 T3：hello 帧——连上先发，配置 / 工具探测变了再广播（老 App 不认识，default 分支忽略）──
function helloPayload(): string {
  return buildHelloPayload({
    hubVersion: HUB_VERSION,
    machine: machineInfo ?? { host_name: "", host_model_id: null, host_model_name: null },
    claudeHome: ccWorkdir(),
    codexHome: codexWorkdir(),
    agentWorkdir: agentWorkdirSetting(),
    tools: toolAvailability,
    capabilities: ccMcpConfig() ? [...HUB_CAPABILITIES, "mcp"] : HUB_CAPABILITIES,
  })
}

function broadcastHello(): void {
  const payload = helloPayload()
  for (const c of mpClients) {
    if (c.readyState === c.OPEN) {
      try { c.send(payload) } catch { /* 死 socket 等 close 事件清 */ }
    }
  }
}

/// 探测 tmux / claude / codex（按 hub 自己的 PATH，纯查文件）；变了就广播
function refreshToolAvailability(): void {
  const next = detectTools(process.env.PATH)
  const changed = JSON.stringify(next) !== JSON.stringify(toolAvailability)
  toolAvailability = next
  if (changed) broadcastHello()
}

function hubConfigPayload(requestIdValue?: string): string {
  return JSON.stringify({
    type: "hub_config",
    agent_workdir: agentWorkdirSetting(),
    claude_home: ccWorkdir(),
    codex_home: codexWorkdir(),
    ...(requestIdValue ? { request_id: requestIdValue } : {}),
  })
}

/// get_hub_config / set_agent_workdir / list_dirs 的回帧原样带回 request_id，App 按它对回调（astra 实现审 #3：FIFO 会错配）
function requestId(msg: { request_id?: unknown }): string | undefined {
  return typeof msg.request_id === "string" && msg.request_id.length <= 64 ? msg.request_id : undefined
}
function requestIdField(msg: { request_id?: unknown }): { request_id?: string } {
  const id = requestId(msg)
  return id ? { request_id: id } : {}
}

/// 开窗 / 对话起 agent 前：明确探测到没装 → 中文原因；还不知道（null）不拦
function missingToolReason(engine: TerminalEngine, needsTmux = true): string | null {
  if (needsTmux && toolAvailability.tmux === false) return "电脑上没装 tmux（brew install tmux）"
  if (engine === "claude" && toolAvailability.claude === false) return "电脑上还没装 Claude Code"
  if (engine === "codex" && toolAvailability.codex === false) return "电脑上还没装 Codex"
  return null
}

// R3-3 考古按钮：app 请求单词考古 → spawn vocab-daily --word → 完成后全文广播回投。
// 同词防重入；6min 硬顶（脚本自身 5min/词）。烧订阅不烧 API（claude -p）。
const archeologyInFlight = new Set<string>()
// 完成的考古结果缓存 24h：MP client 重连时补投（app 侧 saveLive 幂等，重复投递无害）
const corpusResults = new Map<string, { frame: string; at: number }>()
async function runVocabArcheology(word: string) {
  if (archeologyInFlight.has(word)) return
  archeologyInFlight.add(word)
  console.log(`[hub] vocab_archeology → ${word}`)
  try {
    const script = join(import.meta.dir, "..", "scripts", "vocab", "vocab-daily.ts")
    // 姿势对齐夜跑 runSpawn（stderr pipe / 先 exited 后读流）——那条路径身经百战
    const proc = Bun.spawn([process.execPath, script, "--word", word], { stdout: "pipe", stderr: "pipe" })
    const killer = setTimeout(() => { try { proc.kill() } catch {} }, 6 * 60_000)
    const code = await proc.exited
    clearTimeout(killer)
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    const outfile = out.split("\n").find((l) => l.startsWith("OUTFILE:"))?.slice("OUTFILE:".length)
    let content = ""
    if (code === 0 && outfile) {
      try { content = readFileSync(outfile, "utf8") } catch {}
    }
    const ok = content.length > 500
    const frame = JSON.stringify({ type: "vocab_corpus_result", word, ok, content: ok ? content : "" })
    if (ok) {
      corpusResults.set(word, { frame, at: Date.now() })
      for (const [w, r] of corpusResults) {
        if (Date.now() - r.at > 24 * 3600_000) corpusResults.delete(w)
      }
    }
    for (const c of mpClients) { try { c.send(frame) } catch {} }
    console.log(`[hub] vocab_archeology ${ok ? "✓" : "✗"} ${word}（exit=${code} ${content.length}B → ${mpClients.size} clients）${ok ? "" : " err尾: " + err.slice(-200)}`)
  } catch (e) {
    console.error(`[hub] vocab_archeology 崩: ${(e as Error)?.stack ?? e}`)
    try {
      const frame = JSON.stringify({ type: "vocab_corpus_result", word, ok: false, content: "" })
      for (const c of mpClients) { try { c.send(frame) } catch {} }
    } catch {}
  } finally {
    archeologyInFlight.delete(word)
  }
}
// CR-4：book note 广播出口注册（deliverBookNote 在 book-notes.ts，ReaderDaemon 也调它）
setBookNoteBroadcaster((frame) => {
  for (const c of mpClients) {
    try { c.send(frame) } catch {}
  }
})
// 问问题 CC 桥：pending 记账 + 帧广播出口（同款）
/// hook 的 claude session_id → tmux session 名（sessionMap 反查，驱动键序要用）
function askUserSessionNameOf(sessionId: string): string | undefined {
  if (!sessionId) return undefined
  for (const [name, b] of sessionMap) { if (b.claudeSessionId === sessionId) return name }
  return undefined
}
const askUserIO: AskUserIO = {
  sendLiteral: (text, session) => tmuxSendKeys(session, ["-l", text]),
  sendKey: (key, session) => tmuxSendKeys(session, [key]),
  capturePane: (session) => tmuxCapture(session, ["-S", "-40"]),
  sleep: (s) => new Promise<void>((resolve) => setTimeout(resolve, s * 1000)),
}
// #if PERSONAL_APPS
// 交易 T0.5：研报回投广播出口（同款）
setTradingBroadcaster((frame) => {
  for (const c of mpClients) {
    try { c.send(frame) } catch {}
  }
})
// #endif
// CC 小克 memory 同步（plan-cc-memory-sync）：文件夹一变只广播「变了」，不带内容，手机自己来拉
watchMemoryDir(CC_MEMORY_DIR, () => {
  const frame = JSON.stringify({ type: "cc_memory_changed" })
  for (const c of mpClients) {
    try { c.send(frame) } catch {}
  }
  console.log(`[hub] cc_memory_changed → ${mpClients.size} clients`)
})
// 每个已连 client 当前正聚焦哪个会话（前台 + 在对话页 + 选中该会话）。null/缺=没在看任何会话。
// 用于推送决策：reply 到 chat C 时，没人聚焦 C 才推。
const focusByClient = new Map<WebSocket, string | null>()
// 每个 MP 连接自报的平台（client_info 帧）+ 最近一次收到它消息的时间。
// 本地推特命令固定发手机：数据在手机上，Mac 版 app 连着也不给它（粟粟 2026-09-24）。
export interface MPClientInfo { platform?: string; lastSeen: number }
const clientInfoByWS = new Map<WebSocket, MPClientInfo>()
/// 挑手机：报过 platform=ios 且还开着的连接里，取最近有动静的那个；没有返回 null。
export function pickPhoneClient(clients: Iterable<WebSocket>, info: Map<WebSocket, MPClientInfo>): WebSocket | null {
  let best: WebSocket | null = null
  let bestSeen = -Infinity
  for (const c of clients) {
    const i = info.get(c)
    if (c.readyState !== c.OPEN || i?.platform !== "ios") continue
    if (i.lastSeen > bestSeen) { best = c; bestSeen = i.lastSeen }
  }
  return best
}
// MCP 客户端集合（/mcp 路径连接的 MCP server）
const mcpClients = new Set<WebSocket>()
/// /mcp socket → 宿主 tmux session（mcp_hello 上报；reply 守卫用）
const mcpSessionByWS = new Map<import("ws").WebSocket, string>()
/// agora executor 引用（main 里赋值；reply 守卫查 hasActiveClaim）
let agoraExecutorRef: { hasActiveClaim(sessionName: string): boolean } | null = null

// L4: 每个 tmux session 的终端流订阅状态。
// 多 MP client 共享同一个只读控制客户端（tmux-pane-stream.ts，#087 起替代 pipe-pane → fifo → cat），
// 最后一个 client 离开时关闭整套流。
interface TerminalAttachment {
  sessionName: string
  stream: PaneStream
  /// 已经收到快照、正在收增量的
  mpClients: Set<WebSocket>
  /// attach 了、还在等自己那张快照的：增量不发给它（都在快照里），算观众（最后一个离开才关流）
  joining: Set<WebSocket>
  pendingChunks: Buffer[]
  flushTimer: ReturnType<typeof setTimeout> | null
  /// 把攒着的增量立刻发给 mpClients（快照边界前必须先调，见 captureAtBoundary）
  flush: () => void
}
function terminalWatched(att: TerminalAttachment): boolean {
  return att.mpClients.size > 0 || att.joining.size > 0
}
const terminalAttachments = new Map<string, TerminalAttachment>()
/// 每个连接每个 session 的 attach 代号：attach / detach 各加一，异步读 tmux 回来发现变了就作废
const terminalAttachSeq = new WeakMap<WebSocket, Map<string, number>>()
function bumpTerminalAttachSeq(ws: WebSocket, sessionName: string): number {
  let m = terminalAttachSeq.get(ws)
  if (!m) { m = new Map(); terminalAttachSeq.set(ws, m) }
  const next = (m.get(sessionName) ?? 0) + 1
  m.set(sessionName, next)
  return next
}

// ── 顶卡用量帧（L4 像素顶栏 M4）──
// ctx 由 hub 自己读 transcript 算，5h/7d 读 statusline 落盘（没有就发 undefined，
// app 显示灰 `--`）。30s 一次：ctx 跟着对话走，不需要更密。
const RATE_LIMIT_CACHE = join(homedir(), ".vibe-island", "cache", "rl.json")
export const TERMINAL_USAGE_INTERVAL_MS = 30_000

function terminalUsagePayload(sessionName: string): string {
  const claudeSessionId = sessionMap.get(sessionName)?.claudeSessionId
  const transcript = claudeSessionId
    ? readTranscriptUsage(
        claudeTranscriptPath(claudeSessionId),
        (recordModel) => contextWindowForSession(sessionName, recordModel),
      )
    : null
  const limits = readRateLimits(RATE_LIMIT_CACHE)
  return buildTerminalUsagePayload(sessionName, transcript, limits)
}

function sendTerminalUsage(sessionName: string, targets: Iterable<WebSocket>): void {
  const payload = terminalUsagePayload(sessionName)
  for (const c of targets) {
    if (c.readyState === c.OPEN) {
      try { c.send(payload) } catch { /* 死 socket 等 close 事件清 */ }
    }
  }
}

function terminalStateSources(paneTitles: Map<string, string>, paneMeta: Map<string, PaneMeta>): TerminalStateSource[] {
  const globalWindows: TerminalStateSource[] = openWindows(terminalWindows).map(window => {
    const engine = window.engine === "claude" || window.engine === "codex" ? window.engine : "shell"
    const sessionName = sessionNameFor(window.code)
    return {
      code: window.code,
      sessionName,
      engine,
      title: windowTitle(window.customTitle, paneTitles.get(sessionName), engine, paneMeta.get(sessionName)),
      includeWhenDead: true,
    }
  })
  const conversationSessions: TerminalStateSource[] = Array.from(sessionMap.keys()).map(sessionName => {
    const engine = sessionEngine(sessionName)
    return {
      code: sessionName,
      sessionName,
      engine,
      title: resolveTerminalTitle(conversationCustomTitles.get(sessionName), paneTitles.get(sessionName), engine),
      includeWhenDead: false,
    }
  })
  return [...globalWindows, ...conversationSessions]
}

function sendTerminalState(targets: Iterable<WebSocket>): void {
  const sessionNames = [
    ...openWindows(terminalWindows).map(window => sessionNameFor(window.code)),
    ...sessionMap.keys(),
  ]
  const paneTitles = tmux.paneTitles(sessionNames)
  const paneMeta = tmux.paneMeta?.(sessionNames) ?? new Map<string, PaneMeta>()
  const sources = terminalStateSources(paneTitles, paneMeta)
  const engineOf = new Map(sources.map(s => [s.sessionName, s.engine]))
  const payload = buildTerminalStatePayload(
    sources,
    sessionName => tmux.hasSession(sessionName),
    sessionName => sessionPhase(sessionName, engineOf.get(sessionName) ?? "claude", paneMeta.get(sessionName)),
  )
  for (const client of targets) {
    if (client.readyState === client.OPEN) {
      try { client.send(payload) } catch { /* 死 socket 等 close 事件清 */ }
    }
  }
}

function terminalAttachedClients(): Set<WebSocket> {
  const clients = new Set<WebSocket>()
  for (const attachment of terminalAttachments.values()) {
    for (const client of attachment.mpClients) clients.add(client)
  }
  return clients
}

function broadcastTerminalState(): void {
  const clients = terminalAttachedClients()
  if (clients.size > 0) sendTerminalState(clients)
}


/// 微批窗口：CC 流式输出/spinner 时 pane 每秒吐几十上百个小 chunk，
/// 每 chunk 一条 WS 消息 = iPhone 端 SwiftTerm 高频 feed+重渲染（「终端卡卡的」）。
/// 24ms 聚合人眼无感（~40fps），消息量压一个量级；64KB 上限防大输出攒延迟。
export const TERM_BATCH_MS = 24
export const TERM_BATCH_MAX_BYTES = 64 * 1024

/// 第一个 MP client attach 时：挂一个只读控制客户端，等握手完成。
/// 🔴 控制客户端的 stdout 必须一直读（PaneStream.readLoop），不读 tmux 会给它攒着；微批只延迟 WS 发送
async function createTerminalAttachment(sessionName: string): Promise<TerminalAttachment> {
  let att: TerminalAttachment | undefined
  const stream = new PaneStream(sessionName, {
    onOutput: (chunk) => {
      if (!att) return
      att.pendingChunks.push(chunk)
      let pending = 0
      for (const b of att.pendingChunks) pending += b.length
      if (pending >= TERM_BATCH_MAX_BYTES) { att.flush(); return }
      if (!att.flushTimer) att.flushTimer = setTimeout(att.flush, TERM_BATCH_MS)
    },
    onExit: (reason) => {
      // 自己关的（表里已经摘掉）不吭声；同一会话可能已经开了新的一套：只关自己
      if (!att || terminalAttachments.get(sessionName) !== att) return
      console.log(`[hub] terminal stream exited for ${sessionName}: ${reason}`)
      att.flush()
      void closeTerminalAttachment(sessionName)
    },
  })
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    await Promise.race([
      stream.ready,
      new Promise<never>((_, rej) => { timer = setTimeout(() => rej(new Error(`attach timeout ${TMUX_SYNC_TIMEOUT_MS}ms`)), TMUX_SYNC_TIMEOUT_MS) }),
    ])
  } catch (err) {
    const closing = stream.close()
    terminalAttachmentsClosing.set(sessionName, closing)
    void closing.finally(() => {
      if (terminalAttachmentsClosing.get(sessionName) === closing) terminalAttachmentsClosing.delete(sessionName)
    })
    throw err
  } finally { clearTimeout(timer) }

  const a: TerminalAttachment = {
    sessionName, stream, mpClients: new Set(), joining: new Set(),
    pendingChunks: [], flushTimer: null, flush: () => {},
  }
  a.flush = () => {
    if (a.flushTimer) { clearTimeout(a.flushTimer); a.flushTimer = null }
    if (a.pendingChunks.length === 0) return
    const merged = a.pendingChunks.length === 1 ? a.pendingChunks[0] : Buffer.concat(a.pendingChunks)
    a.pendingChunks = []
    const payload = JSON.stringify({
      type: "terminal_chunk",
      session_name: sessionName,
      bytes: merged.toString("base64"),
    })
    for (const c of a.mpClients) {
      if (c.readyState === c.OPEN) {
        try { c.send(payload) } catch { /* 死 socket 等 close 事件清 */ }
      }
    }
  }
  att = a
  return a
}

/// 同一会话同时来两个 attach（两台设备 / 重连）只开一套流：后来的等先来的开好的那套
const terminalAttachmentsOpening = new Map<string, Promise<TerminalAttachment>>()
const terminalAttachmentsClosing = new Map<string, Promise<void>>()
export function openTerminalAttachment(sessionName: string): Promise<TerminalAttachment> {
  if (terminalAttachmentsClosing.has(sessionName)) return Promise.reject(new Error("terminal stream still closing"))
  const existing = terminalAttachments.get(sessionName)
  if (existing) return Promise.resolve(existing)
  let opening = terminalAttachmentsOpening.get(sessionName)
  if (!opening) {
    opening = createTerminalAttachment(sessionName)
      .then(att => { terminalAttachments.set(sessionName, att); return att })
      .finally(() => terminalAttachmentsOpening.delete(sessionName))
    terminalAttachmentsOpening.set(sessionName, opening)
  }
  return opening
}

/// 表里立刻摘掉，关控制客户端（关 stdin 让它自己退，见 PaneStream.close）；等它退出再返回
export function closeTerminalAttachment(sessionName: string): Promise<void> {
  const att = terminalAttachments.get(sessionName)
  if (!att) return terminalAttachmentsClosing.get(sessionName) ?? Promise.resolve()
  if (att.flushTimer) { clearTimeout(att.flushTimer); att.flushTimer = null }
  terminalAttachments.delete(sessionName)
  const closing = att.stream.close()
  terminalAttachmentsClosing.set(sessionName, closing)
  void closing.finally(() => {
    if (terminalAttachmentsClosing.get(sessionName) === closing) terminalAttachmentsClosing.delete(sessionName)
  })
  return closing
}

/// 抓快照并在流里的快照位置同步调 onSnapshot：先把边界之前攒着的增量发给已经在看的，
/// 之后的增量都排在这张快照后面（#087：快照与增量的边界由 tmux 控制模式的输出顺序保证）
export function captureAtBoundary(att: TerminalAttachment, onSnapshot: (snapshot: string, mouseAny: boolean) => void): Promise<void> {
  return att.stream.snapshot(raw => {
    att.flush()
    const { snapshot, mouseAny } = formatSnapshot(raw.capture, raw.meta, raw.mainCapture)
    onSnapshot(snapshot, mouseAny)
  }, TMUX_SYNC_TIMEOUT_MS)
}

function sleep(ms: number): Promise<void> {
  return new Promise(r => setTimeout(r, ms))
}

/// L4 P0b：terminal_resize 频繁 fire（SwiftTerm layoutSubviews 反复触发）会触发
/// 多次 capture-pane + 重发 init，乱花。debounce 200ms 内只跑最后一次。
const resizeDebounce = new Map<string, ReturnType<typeof setTimeout>>()

/// T51：每台设备报的尺寸，窗口按前台设备里最小的那个来（terminal-size.ts）
const terminalSizes = new TerminalSizeTracker<WebSocket>()

/// 窗口尺寸对齐到目标，返回改没改。读、比、改在同一会话写链的一个 job 里，目标在 job 执行时才算：
/// 排在前面的旧 resize 跑完之后再读再比，已经离开的设备排着的 resize 不会把窗口压回去。null = 不动窗口
export function syncWindowSize(sessionName: string, target: () => TerminalSize | null): Promise<boolean> {
  return chainTmuxWrite(sessionName, async () => {
    const size = target()
    if (!size) return false
    const cur = (await tmuxRun([
      "display-message", "-t", sessionName, "-p", "#{window_width}x#{window_height}",
    ], { timeoutMs: TMUX_SYNC_TIMEOUT_MS, write: false })).trim()
    if (cur === `${size.cols}x${size.rows}`) return false
    // 已经在链上：不带 session，不再入链（入链会排在自己后面）
    await tmuxRun(["resize-window", "-t", sessionName, "-x", String(size.cols), "-y", String(size.rows)],
      { timeoutMs: TMUX_WRITE_TIMEOUT_MS, write: true })
    return true
  })
}

/// T51：目标 = 此刻正在看的前台设备里最小的
function syncTerminalSize(sessionName: string): Promise<boolean> {
  return syncWindowSize(sessionName, () => terminalSizes.effective(sessionName))
}

/// 终端键入（terminal_input）：send-keys -H 逐字节；和 terminal_paste 在同一条按会话写链上，顺序不乱
export function sendTerminalBytes(sessionName: string, bytes: Uint8Array): Promise<string> {
  const hexArgs: string[] = []
  for (const b of bytes) hexArgs.push(b.toString(16).padStart(2, "0"))
  return tmuxRun(["send-keys", "-t", sessionName, "-H", ...hexArgs], { timeoutMs: TMUX_WRITE_TIMEOUT_MS, write: true, session: sessionName })
}

/// 快照重发防抖（见 terminal_resize 那段注释：错位内容 CC 增量重绘不补，必须重发快照对齐）
function scheduleTerminalReissue(sessionName: string): void {
  const t = resizeDebounce.get(sessionName)
  if (t) clearTimeout(t)
  resizeDebounce.set(sessionName, setTimeout(() => {
    resizeDebounce.delete(sessionName)
    void reissueTerminalInit(sessionName)
  }, 400))
}

/// 有人离开 / 退后台后，窗口按剩下前台设备的最小尺寸重设（变了才动 + 重发快照）
async function applyEffectiveSize(sessionName: string): Promise<void> {
  if (!terminalSizes.effective(sessionName) || streamRunner.has(sessionName) || !tmux.hasSession(sessionName)) return
  try {
    if (await syncTerminalSize(sessionName)) scheduleTerminalReissue(sessionName)
  } catch (err: any) {
    console.warn(`[hub] resize-window failed for ${sessionName}: ${err.message}`)
  }
}

/// CUP 光标定位序列（tmux cursor_x/y 是 0-based，CUP 1-based）。
export function cursorRestoreSeq(x: number, y: number): string {
  if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || y < 0) return ""
  return `\x1b[${y + 1};${x + 1}H`
}

/// capture 快照 + CRLF 归一 + 追加光标复位。
/// - CRLF：capture-pane -p 用裸 LF 分行，raw 模式 SwiftTerm 收 LF 只下移不回列首
///   → 列错位/超宽换行；转 \r\n 每行回列首（content/SGR 转义不含 \n，全局替换安全）
/// - ⚠️ capture-pane 只有内容不含光标位置——纯 feed 会把光标丢在文本末尾
///   （粟粟截图：光标孤悬状态栏下一行行首），必须问 tmux 拿真实坐标钉回去
/// 快照、光标、鼠标上报标志在终端流的同一条控制连接上一起取（#087，见 captureAtBoundary），这里只管拼
/// meta = "cursor_x cursor_y mouse_any_flag cursor_flag scroll_region_upper scroll_region_lower alternate_on pane_height alternate_saved_x/y"。
/// #087：客户端收快照先整个复位，capture-pane 又只有字没有状态 —— Claude Code 2.1 的 DECSTBM 渲染器在备用屏里设滚动区，
/// 复位后滚动区变全屏，之后的增量一滚就把输入框 / 状态栏一起卷走、消息区串行（复现见 docs/research-terminal-render-fix.md §2.2）。
/// 所以把备用屏、滚动区、光标显隐按 tmux 的真值补回去：备用屏在内容之前切（内容要写进备用屏），
/// 滚动区在内容之后设（DECSTBM 会把光标挪回左上），最后才钉光标
export function formatSnapshot(raw: string, meta: string, mainRaw = ""): { snapshot: string; mouseAny: boolean } {
  // 尾随换行必须剥：capture-pane 最后一行也带 \n，feed 它会让屏幕多滚一行
  // （内容整体上移）→ CUP 光标复位相对内容偏下一行（粟粟：「光标在输入框下缘出格」）
  const snapshot = raw.replace(/\r?\n/g, "\r\n").replace(/\r\n$/, "")
  const parts = meta.trim().split(/\s+/)
  const restore = parts.length >= 2 ? cursorRestoreSeq(parseInt(parts[0], 10), parseInt(parts[1], 10)) : ""
  const [cursorFlag, upper, lower, alt, height, savedX, savedY] = parts.slice(3)
  const mainScreen = mainRaw.replace(/\r?\n/g, "\r\n").replace(/\r\n$/, "")
  const altScreen = alt === "1"
    ? mainScreen + cursorRestoreSeq(parseInt(savedX, 10), parseInt(savedY, 10)) + "\x1b[?1049h"
    : ""
  // 只在滚动区不是整屏时设（tmux 的 upper/lower 是 0-based，整屏 = 0..pane 高 − 1）
  const top = parseInt(upper, 10), bottom = parseInt(lower, 10), rows = parseInt(height, 10)
  const partialRegion = [top, bottom, rows].every(Number.isFinite) && bottom > top && (top > 0 || bottom < rows - 1)
  const region = partialRegion ? `\x1b[${top + 1};${bottom + 1}r` : ""
  const cursor = cursorFlag === "0" ? "\x1b[?25l" : cursorFlag === "1" ? "\x1b[?25h" : ""
  return { snapshot: altScreen + snapshot + region + cursor + restore, mouseAny: parseMouseAnyFlag(parts[2] ?? "") }
}

/// 重新 capture pane snapshot 并发给该 session 所有订阅 MP client。
/// client 端收 terminal_init 时先 resetToInitialState 再 feed。
async function reissueTerminalInit(sessionName: string): Promise<void> {
  const att = terminalAttachments.get(sessionName)
  if (!att) return
  try {
    await captureAtBoundary(att, (snapshot, mouseAny) => {
      const payload = buildTerminalInitPayload(sessionName, snapshot, mouseAny)
      for (const c of att.mpClients) {
        if (c.readyState === c.OPEN) {
          try { c.send(payload) } catch {}
        }
      }
    })
  } catch (err: any) {
    console.warn(`[hub] reissueTerminalInit failed for ${sessionName}: ${err.message}`)
  }
}

// 最近 reply 缓存：iPhone 网络抖动 / reconnect 时 broadcast 撞空，
// 这里保留 10 分钟滑动窗口，新 MP client 连上时主动 replay 给它。
// reply_id 用来配合 client 端 dedup（避免重复 deliver）。
// 600s 跟 CCBridgeProvider.replyGracePeriod 同步：CC 长思考 + reply 在 grace
// 期内 deliver，buffer 也要足够长才能 cover iPhone 离线-回归这种 case。
interface RecentReply {
  chat_id: string
  message_id?: string
  content: string
  reply_id: string
  ts: number
  filePath?: string   // C2：CC 发的文件在 mp-outbox 的路径（只存路径不存 b64，防 reply-log 膨胀；replay 时重读）
  mpMsgId?: string    // A4：CC 可见消息 id（s_…），app 存到 node 供 edit/引用定位
  replyTo?: string    // A4：引用的消息 id
  rowUuids?: string[] // 10-11：这条合进去的全部正文段的转录 uuid（mpMsgId 只是最后一段）；启动时全部补回去重集合
}
// A4：edit 的会话内补发缓存（内存、非持久——app 已落地编辑后内容，hub 重启无需补；只补会话内重连）
interface RecentEdit { chat_id: string; mp_msg_id: string; content: string; ts: number }
const recentEdits: RecentEdit[] = []
// pocket-browser / 本地推特: CC → /pocket/cmd 或 /twitter/cmd → hub 转发给 MP → 等回包（共用 pending 表）
const pocketPending = new Map<string, { resolve: (v: any) => void; timer: ReturnType<typeof setTimeout> }>()
const replyLogPath = join(SECRETS_DIR, "reply-log.json")
const MAX_REPLY_LOG = 500   // 持久保留最近 N 条 reply，用于重连补发（换 WiFi/断网/hub 重启都不丢）
const recentReplies: RecentReply[] = []
/// reply 幂等（mcp-server 重试帧带同 mp_msg_id）——Set 插入序即最老在前，超上限剔一批。
/// 导出供测试；生产只经 markReplySeen 使用。
export const seenMpMsgIds = new Set<string>()
export function markReplySeen(mpMsgId: string | undefined): boolean {
  if (!mpMsgId) return false          // 老 CC 不带 id → 不去重（容旧，宁重勿丢由 app 端兜）
  if (seenMpMsgIds.has(mpMsgId)) return true
  seenMpMsgIds.add(mpMsgId)
  if (seenMpMsgIds.size > 600) {
    const it = seenMpMsgIds.values()
    for (let i = 0; i < 100; i++) { const v = it.next(); if (!v.done) seenMpMsgIds.delete(v.value) }
  }
  return false
}

// reply 落库 + 广播 + 推送。两个来源：mcp（reply 工具帧）/ hook（Stop hook 投的当轮正文，见 REPLY_VIA_TEXT）。
// 幂等靠 mp_msg_id（mcp 重试帧同 id；hook 用 s_txt_<当轮 assistant uuid>）。返回 false = 重复丢弃。
function deliverReply(msg: any, guardSession: string | undefined, source: "mcp" | "hook" | "stream" | "terminal"): boolean {
    // CC 抄错一位 chat_id（09-17 小克 3E7994B7→3E7194B7，app 找不到对话按设计丢、hub 还推了 APNs）：
    // 已知会话里唯一近似就纠正，优先该 session 最近对话；没有近似原样放行。
    {
      const known = [...recentReplies.map(r => r.chat_id), ...[...sessionActivity.values()].map(a => a.lastChatId), ...focusByClient.values()]
      const fix = correctChatId(msg.chat_id, known.filter((c): c is string => typeof c === "string"), guardSession ? sessionActivity.get(guardSession)?.lastChatId : undefined)
      if (fix.corrected) {
        console.warn(`[hub] reply chat_id 纠正 ${msg.chat_id.slice(0, 8)}→${fix.id.slice(0, 8)} (session=${guardSession ?? "?"})`)
        msg.chat_id = fix.id
      }
    }
    // 幂等：mcp-server 的 reply 有 3 次重试（send 抛错≠帧没送达，帧进 OS 缓冲后
    // 连接异常关闭照样抛）——重试帧带同一个 mp_msg_id，这里按它去重。
    // 不去重的话每条重试帧会分到新 reply_id，app 端 reply_id dedup 全部失效 → 落两遍。
    if (markReplySeen(typeof msg.mp_msg_id === "string" ? msg.mp_msg_id : undefined)) {
      console.warn(`[hub] duplicate reply dropped (mp_msg_id=${msg.mp_msg_id})`)
      return false
    }
    // 生成 reply_id 让 client 去重
    const reply_id = crypto.randomUUID()
    const message_id = typeof msg.message_id === "string" ? msg.message_id : undefined
    // C2：CC 带 file_path → 拷到 mp-outbox（持久）+ 读 base64 进 payload
    const staged = typeof msg.file_path === "string" && msg.file_path
      ? stageOutboundFile(msg.chat_id, msg.file_path) : null
    const file = staged ? readFileB64(staged.path) : null
    if (staged) console.log(`[hub] reply file staged → ${staged.path} (${file ? "ok" : "read-fail"})`)
    const mpMsgId = typeof msg.mp_msg_id === "string" ? msg.mp_msg_id : undefined   // A4：CC 可见消息 id
    const replyTo = typeof msg.reply_to === "string" ? msg.reply_to : undefined     // A4：引用的消息 id
    const ts = Date.now()
    const payload = JSON.stringify({
      type: "reply",
      ts,           // app 记最大值，重连带 since= 只补没收到的
      chat_id: msg.chat_id,
      message_id,   // 可选，client 用来精确匹配 pending 消息
      content: msg.content,
      reply_id,
      file,         // 可选 {name,mime,b64,isImage}
      mp_msg_id: mpMsgId,
      reply_to: replyTo,
      ...(msg.streaming === true && { streaming: true }),   // 流式占位（十二）：app 不标 edited、不滚动
    })
    // 持久缓存（用于 reconnect 补发：换 WiFi/断网/hub 重启都不丢）。保留最近 MAX_REPLY_LOG 条。
    recentReplies.push({
      chat_id: msg.chat_id,
      message_id,
      content: msg.content,
      reply_id,
      ts,
      filePath: staged?.path,   // 只存路径，replay 时重读
      mpMsgId,
      replyTo,
      ...(Array.isArray(msg.row_uuids) && msg.row_uuids.length > 0 && { rowUuids: msg.row_uuids }),
    })
    while (recentReplies.length > MAX_REPLY_LOG) recentReplies.shift()
    saveReplyLog()
    // broadcast
    let broadcastTo = 0
    for (const mp of mpClients) {
      if (mp.readyState === mp.OPEN) {
        try {
          mp.send(payload)
          broadcastTo++
        } catch {
          // 死 socket，等 close 事件清理
        }
      }
    }
    console.log(`[hub] ${probeTs()} reply ← ${source} → broadcast to ${broadcastTo}/${mpClients.size} mp clients (buffered) rid=${reply_id.slice(0, 8)} chat=${String(msg.chat_id).slice(0, 8)}`)
    // 问问题 CC 桥：reply 到达 = turn 结束——还挂着的 pending 兜底收账
    //（Esc declined 无 PostToolUse；驱动过但 hook 断了用暂存答案）
    askUserResolveOnReply(msg.chat_id)
    if (guardSession) onLaPhaseEvent(guardSession, { kind: "reply", pendingRemains: askUserPendingList().some(p => p.sessionName === guardSession) })   // M4a：done latch，waiting 优先
    if (guardSession) void onSessionTurnEnded(guardSession)   // 底部胶囊的模型：codex 没有 Stop hook，靠 reply
    // TG 式：推不推 = 你【在不在看这个会话】，跟 app 连没连无关。
    // 没有任何已连 client 正聚焦该 chat（前台+对话页+选中它）→ 推；有人正盯着 → 不推（live 显示=已读）。
    // reply 已进 recentReplies，回前台重连会 replay 补上（去重防重复），推送只负责「叫你」。
    // 终端轮镜像（她正在终端里）不推：推「找你了」是噪音
    const focusedHere = [...focusByClient.values()].some(c => c === msg.chat_id)
    const shouldPush = source !== "terminal" && !focusedHere && pushTokens.size > 0
    console.log(`[hub] push decision: chat=${msg.chat_id.slice(0, 8)} focusedHere=${focusedHere} source=${source} → ${shouldPush ? "PUSH" : "skip"}`)
    if (shouldPush) {
      const fullPreview = msg.content.replace(/\s+/g, " ").slice(0, 80)
      const chatId = msg.chat_id
      sendRegisteredPushes(ccConfig.pushName, fullPreview, "找你了", chatId)
    }
  return true
}

export function seedSeenFromReplies(replies: Array<{ mpMsgId?: string; rowUuids?: string[] }>): void {
  for (const r of replies) {
    if (r.mpMsgId) markReplySeen(r.mpMsgId)
    for (const u of r.rowUuids ?? []) markReplySeen(`s_txt_${u}`)
  }
}
/// 按段去重推断出来「投过」的前段（老 hook 那条只记了最后一段的 id）：补进去重集合，并记到那条 reply 的 rowUuids 上，
/// 这样 hub 重启后迟到的短前缀（待投目录里的 A+B）也认得出（10-11 审）
function recordInferredRows(done: TextRow[]): void {
  if (done.length === 0) return
  const missing = done.filter((r) => !seenMpMsgIds.has(`s_txt_${r.uuid}`))
  if (missing.length === 0) return
  for (const r of missing) markReplySeen(`s_txt_${r.uuid}`)
  const anchor = done[done.length - 1].uuid
  for (let i = recentReplies.length - 1; i >= 0; i--) {
    const r = recentReplies[i]
    if (r.mpMsgId !== `s_txt_${anchor}` && !r.rowUuids?.includes(anchor)) continue
    r.rowUuids = [...new Set([...(r.rowUuids ?? [anchor]), ...missing.map((m) => m.uuid)])]
    saveReplyLog()
    return
  }
}
function loadReplyLog(): void {
  try {
    if (existsSync(replyLogPath)) {
      const raw = JSON.parse(readFileSync(replyLogPath, "utf8"))
      if (Array.isArray(raw)) recentReplies.push(...raw.slice(-MAX_REPLY_LOG))
    }
  } catch (e: any) { console.warn(`[hub] loadReplyLog failed: ${e.message}`) }
  // 去重集合只在内存：hub 一重启就空了，hook / 待投补投再来同一轮就又发一遍（10-09 18:14 同一 s_txt_e7742a18 两个 reply_id）。
  // 用持久化的 reply-log 把投过的 id 补回来
  seedSeenFromReplies(recentReplies)
}
function saveReplyLog(): void {
  try { writeFileSync(replyLogPath, JSON.stringify(recentReplies)) }
  catch (e: any) { console.warn(`[hub] saveReplyLog failed: ${e.message}`) }
}

// --- 思考链回传：Stop hook POST 来的 thinking，锚定到该 chat 最近一条 reply 的 mp_msg_id，
// app 按消息 id 精确挂载（离线多轮 replay 也不会错挂）。缓存机制同 recentReplies。---
interface RecentThinking { chat_id: string; mp_msg_id: string; content: string; thinking_id: string; ts: number }
const thinkingLogPath = join(SECRETS_DIR, "thinking-log.json")
const MAX_THINKING_LOG = 200
const recentThinkings: RecentThinking[] = []
function loadThinkingLog(): void {
  try {
    if (existsSync(thinkingLogPath)) {
      const raw = JSON.parse(readFileSync(thinkingLogPath, "utf8"))
      if (Array.isArray(raw)) recentThinkings.push(...raw.slice(-MAX_THINKING_LOG))
    }
  } catch (e: any) { console.warn(`[hub] loadThinkingLog failed: ${e.message}`) }
}
function saveThinkingLog(): void {
  try { writeFileSync(thinkingLogPath, JSON.stringify(recentThinkings)) }
  catch (e: any) { console.warn(`[hub] saveThinkingLog failed: ${e.message}`) }
}
/// Stop hook 投来的当轮 thinking / 正文。HTTP 入口和待投目录补发共用（09-19：hub 卡住 3 秒 hook 超时放弃，正文丢了）。
function processThinkingPost(o: any): [number, Record<string, unknown>] {
  const chatId = typeof o.chat_id === "string" ? o.chat_id : ""
  let thinking = typeof o.thinking === "string" ? o.thinking : ""
  const replyText = typeof o.reply_text === "string" ? o.reply_text.trim() : ""
  // 新 hook 带 rows（本轮每段正文 + 转录 uuid）：按段去重，只投没投过的段（见 undeliveredRows）
  const rows = parseRows(o.rows)
  if (!chatId || (!thinking && !replyText && !rows)) { return [400, { ok: false, reason: "invalid_body" }] }
  if (thinking.length > 64_000) thinking = thinking.slice(0, 64_000) + " …[截断]"
  // 当轮正文（REPLY_VIA_TEXT）：先按 reply 落库，thinking 再锚到它
  let replied: "ok" | "dup" | "off" | "streamed" | undefined
  if (rows) {
    const sid = typeof o.session_id === "string" ? o.session_id : ""
    let name: string | undefined
    for (const [n, b] of sessionMap) if (b.claudeSessionId === sid) { name = n; break }
    if (!replyViaTextFor(name)) {
      console.warn(`[hub] ${probeTs()} reply_text 策略外照投（${name ?? sid.slice(0, 8)} 不在文本模式名单）chat=${chatId.slice(0, 8)} rows=${rows.length}`)
    }
    const fresh = undeliveredRows(rows, (u) => seenMpMsgIds.has(`s_txt_${u}`))
    recordInferredRows(rows.slice(0, rows.length - fresh.length))
    if (fresh.length === 0) {
      replied = streamedTurnNode.has(rows[rows.length - 1].uuid) ? "streamed" : "dup"
    } else {
      if (fresh.length < rows.length) console.log(`[hub] ${probeTs()} 本轮前 ${rows.length - fresh.length} 段已投过，只投后 ${fresh.length} 段 chat=${chatId.slice(0, 8)}`)
      // 只发完整放得下的段、只把它们记成投过；超限的留给下一次补投
      const send = fitRows(fresh, 20_000)
      if (send.length < fresh.length) console.warn(`[hub] ${probeTs()} 正文超 20000 字：先投 ${send.length} 段，剩 ${fresh.length - send.length} 段留给补投 chat=${chatId.slice(0, 8)}`)
      const joined = send.map((r) => r.text).join("\n\n")
      // 只有「单段自己就超限」会走到截断：这一段截断后照样记投过（不然它永远发不出去，见 fitRows）
      const body = joined.length > 20_000 ? joined.slice(0, 20_000) + " …[截断]" : joined
      // 终端轮：她那句的引用块只挂在本轮第一条上
      const terminalInput = typeof o.terminal_input === "string" ? o.terminal_input.trim() : ""
      const quote = terminalInput && fresh.length === rows.length
      if (terminalInput) console.log(`[hub] ${probeTs()} terminal mirror ${name ?? sid.slice(0, 8)} chat=${chatId.slice(0, 8)} in=${terminalInput.length} len=${joined.length}`)
      const last = send[send.length - 1].uuid
      const ok = deliverReply({
        chat_id: chatId,
        message_id: typeof o.message_id === "string" ? o.message_id : undefined,
        content: quote ? terminalInput.split("\n").map((l: string) => `> ${l}`).join("\n") + "\n\n" + body : body,
        mp_msg_id: `s_txt_${last}`,
        row_uuids: send.map((r) => r.uuid),
      }, name, terminalInput ? "terminal" : "hook")
      for (const r of send) markReplySeen(`s_txt_${r.uuid}`)
      replied = ok ? "ok" : "dup"
    }
    if (!thinking) { return [200, { ok: replied === "ok", replied }] }
  } else if (replyText) {
    const sid = typeof o.session_id === "string" ? o.session_id : ""
    let name: string | undefined
    for (const [n, b] of sessionMap) if (b.claudeSessionId === sid) { name = n; break }
    // 从不丢：hook 拿到正文说明小克真开口了（用了 reply 工具的轮 hook 自己就不投）。策略说「不该直接说话」
    // 也照投，只记一行——丢消息比多一条严重得多（09-20 mp-cc-74 因全局开关被另一台设备改回 tmux，丢了两轮）
    if (!replyViaTextFor(name)) {
      console.warn(`[hub] ${probeTs()} reply_text 策略外照投（${name ?? sid.slice(0, 8)} 不在文本模式名单）chat=${chatId.slice(0, 8)} len=${replyText.length}`)
    }
    {
      const turn = typeof o.turn_uuid === "string" && o.turn_uuid ? o.turn_uuid : crypto.randomUUID()
      // 终端轮（她在终端里直接打字）：她那句做成引用块放正文前面
      const terminalInput = typeof o.terminal_input === "string" ? o.terminal_input.trim() : ""
      const body = replyText.length > 20_000 ? replyText.slice(0, 20_000) + " …[截断]" : replyText
      if (terminalInput) console.log(`[hub] ${probeTs()} terminal mirror ${name ?? sid.slice(0, 8)} chat=${chatId.slice(0, 8)} in=${terminalInput.length} len=${replyText.length}`)
      const ok = deliverReply({
        chat_id: chatId,
        message_id: typeof o.message_id === "string" ? o.message_id : undefined,
        content: terminalInput ? terminalInput.split("\n").map((l: string) => `> ${l}`).join("\n") + "\n\n" + body : body,
        mp_msg_id: `s_txt_${turn}`,
      }, name, terminalInput ? "terminal" : "hook")
      replied = ok ? "ok" : "dup"
      if (!ok && streamedTurnNode.has(turn)) replied = "streamed"
    }
    if (!thinking) { return [200, { ok: replied === "ok", replied }] }
  }
  let anchor: string | undefined
  if (typeof o.turn_uuid === "string") anchor = streamedTurnNode.get(o.turn_uuid)   // 流式建的节点优先
  for (let i = recentReplies.length - 1; i >= 0; i--) {
    const r = recentReplies[i]
    if (r.chat_id === chatId && r.mpMsgId) { anchor = r.mpMsgId; break }
  }
  if (!anchor) {
    console.log(`[hub] thinking dropped (no_anchor) chat=${chatId.slice(0, 8)} len=${thinking.length}`)
    return [200, { ok: false, reason: "no_anchor" }]
  }
  const entry: RecentThinking = { chat_id: chatId, mp_msg_id: anchor, content: thinking, thinking_id: crypto.randomUUID(), ts: Date.now() }
  recentThinkings.push(entry)
  while (recentThinkings.length > MAX_THINKING_LOG) recentThinkings.shift()
  saveThinkingLog()
  const payload = thinkingFramePayload(entry)
  let n = 0
  for (const mp of mpClients) {
    if (mp.readyState === mp.OPEN) { try { mp.send(payload); n++ } catch {} }
  }
  console.log(`[hub] thinking ← hook chat=${chatId.slice(0, 8)} anchor=${anchor} len=${thinking.length} → broadcast ${n}/${mpClients.size}`)
  return [200, { ok: true, thinking_id: entry.thinking_id, ...(replied && { replied }) }]
}

// 待投目录：thinking-hook 先把 payload 落盘再 POST，成功才删；hub 卡住 / 重启 / 超时时文件留着，这里定时补投。
// 幂等：正文按 s_txt_<turn_uuid> 去重，重投只会得到 dup。
export const THINKING_SPOOL_DIR = process.env.MP_CC_THINKING_SPOOL ?? join(homedir(), ".cc-bridge", "thinking-spool")
/// K3：全异步。返回补投了几个、还留着几个（刚写的 / 补投失败的，下一轮接着看）
export async function drainThinkingSpool(dir = THINKING_SPOOL_DIR): Promise<{ delivered: number; left: number }> {
  let files: string[] = []
  try { files = (await readdir(dir)).filter((f) => f.endsWith(".json")) } catch { return { delivered: 0, left: 0 } }
  let delivered = 0, left = 0
  for (const f of files.sort()) {
    const path = join(dir, f)
    try {
      if (Date.now() - (await stat(path)).mtimeMs < 15_000) { left++; continue }   // 刚写的：hook 可能还在自己 POST，别抢
      const [code, obj] = processThinkingPost(JSON.parse(await readFile(path, "utf8")))
      console.log(`[hub] ${probeTs()} thinking spool 补投 ${f} → ${code} ${JSON.stringify(obj).slice(0, 80)}`)
      await unlink(path); delivered++
    } catch (e: any) {
      console.warn(`[hub] thinking spool ${f} 补投失败: ${e?.message}`)
      try { if (Date.now() - (await stat(path)).mtimeMs > 7 * 86_400_000) await unlink(path); else left++ } catch {}
    }
  }
  return { delivered, left }
}

/// 轮末兜底（09-19：Stop hook 比 CC 写转录早了 0.2 秒，读到空，正文没投）：每轮结束 20s 后自己读转录核对，
/// 本轮是直接说话、没用 reply 工具、还有正文段没进 hub（按段去重，见 undeliveredRows）→ 走同一条 processThinkingPost 补投。
/// 10-11：hook 读早了只投了前两段旁白，最后那段要靠这里补；只补没投过的段，不再整轮重发。
const TURN_SAFETY_NET_MS = Number(process.env.MP_CC_TURN_SAFETY_NET_MS) || 20_000
export async function turnSafetyNetCheck(path: string, claudeSessionId: string, pin = Infinity): Promise<{ post: Record<string, unknown>; fresh: TextRow[] } | null> {
  const t = await extractLastChannelTurnFromFile(path, undefined, pin)
  if (!t || !t.isLatest || t.usedReply || t.rows.length === 0) return null
  const fresh = undeliveredRows(t.rows, (u) => seenMpMsgIds.has(`s_txt_${u}`))
  if (fresh.length === 0) return null
  // 本轮已经投过一部分：thinking 那时候已经跟着投了，这次不再挂一遍
  const partial = fresh.length < t.rows.length
  return {
    fresh,
    post: {
      session_id: claudeSessionId, chat_id: t.chatId, message_id: t.messageId,
      rows: t.rows, ...(partial ? {} : { thinking: t.thinking }),
    },
  }
}
function scheduleTurnSafetyNet(sessionName: string, claudeSessionId: string): void {
  if (!claudeSessionId || streamRunner.has(sessionName) || !replyViaTextFor(sessionName)) return   // stream 会话有自己的流式投递
  const path = claudeTranscriptPath(claudeSessionId)
  // 排的时候就钉住这一轮（Stop 那一刻转录的长度）：20s 内她又发一条，到点读的仍是这一轮，读到下一轮起点为止
  const pinned = stat(path).then((st) => st.size, () => undefined)
  setTimeout(() => {
    void (async () => {
      const pin = await pinned
      if (pin === undefined) return
      const c = await turnSafetyNetCheck(path, claudeSessionId, pin)
      if (!c) return
      const [code, obj] = processThinkingPost(c.post)
      const last = c.fresh[c.fresh.length - 1]
      console.warn(`[hub] ${probeTs()} 轮末兜底补投 ${sessionName} turn=${last.uuid.slice(0, 8)} 段=${c.fresh.length} len=${c.fresh.reduce((n, r) => n + r.text.length, 0)} → ${code} ${JSON.stringify(obj).slice(0, 60)}`)
    })().catch((e: any) => console.warn(`[hub] 轮末兜底 ${sessionName} 失败: ${e?.message}`))
  }, TURN_SAFETY_NET_MS)
}

/// 桥探针时间戳（本地墙钟，跟手机 bridge-probe.log 同格式好对账）
function probeTs(): string {
  const d = new Date(), p = (n: number, w = 2) => String(n).padStart(w, "0")
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`
}

/// 连接 URL 的 since=（毫秒时间戳）；缺省 / 非法 → undefined = 全量重放
export function replaySince(raw: string | null): number | undefined {
  if (!raw) return undefined
  const n = Number(raw)
  return Number.isFinite(n) && n > 0 ? n : undefined
}

function thinkingFramePayload(t: RecentThinking): string {
  return JSON.stringify({ type: "thinking", ts: t.ts, chat_id: t.chat_id, mp_msg_id: t.mp_msg_id, content: t.content, thinking_id: t.thinking_id })
}

// --- Nudge：小克定时主动找 susu（Phase 1 默认值，env 可覆盖；Phase 2 由 app config 覆盖）---
interface SessionActivity {
  lastUserSendAt: number
  lastChatId: string
  lastNudgeAt: number
  thresholdMs: number   // 本静默期的随机阈值，每次 susu 发言重掷
  lastKeepaliveAt?: number   // 上次缓存保暖 ping（cache keepalive）时间
  keepaliveStreak?: number   // 本轮静默里连续保暖了几次（susu 一发言就清零）
}
const sessionActivity = new Map<string, SessionActivity>()

// --- Cache keepalive：滚动刷新 Anthropic prompt cache 的 1h TTL ---
// 长陪伴会话上下文常年几十万 token。TTL 过期后下一条消息 = 全量重烤（1.25x input 价），
// 而 TTL 内的请求只花 cache read（0.1x）。≈12.5 次保暖 = 1 次重烤
// （2026-07 审计主会话 7e2173d0：重烤的 77% 来自 >1h gap，每天 300-850 万 token）。
//
// ⚠️ 那个不等式的前提是「她真的会回来」。2026-08-10 实测：16 个会话同时活着、
// 合计上下文 509 万 token，全保一轮就是 509 万 cache read，而她一晚上只回其中 1 个
// —— 15/16 是烧给空气的。所以保暖有两道闸：
//   ① 单选（pickKeepaliveSession）：一次只保「她最后说话的那个」，跟 nudge 同款策略
//   ② 次数封顶（maxStreak）：连保 6 次人还没回来就停，稳在 12.5 次盈亏平衡点的赚侧
// 窗口：idle ≥ 50min 起保（1h TTL 留 10min 余量），距 susu 最后发言超 12h 放弃；
// 她一发言 recordUserActivity 清零 streak，自动恢复保暖。
// per-session 策略（app 长按对话菜单里设，按 tmux session 存——保暖物理上保的就是
// 那一个进程的那一份 context，共享同一 session 的对话本来就该共享策略）：
//   always 🔥 常驻——不参与单选，无视配额与 12h 放弃线（"我要走很久但一定回来"）
//   auto   ⚙️ 默认——参与单选 + 配额
//   never  ❄️ 不保——完全跳过，回去时吃一次重烤
export type KeepalivePolicy = "always" | "auto" | "never"

export interface KeepaliveOpts { idleMs: number; maxIdleMs: number; maxStreak: number }
export function shouldKeepalive(
  act: { lastUserSendAt: number; lastNudgeAt: number; lastKeepaliveAt?: number; keepaliveStreak?: number },
  now: number,
  o: KeepaliveOpts,
  policy: KeepalivePolicy = "auto",
): boolean {
  if (policy === "never") return false
  // "最后一次打到 API"的近似：用户消息 / nudge / 上一次保暖，取最新。
  // CC 自主活动（cron/agora）hub 看不见——低估 idle 只会多 ping 一次，成本 0.1x，可接受
  const lastApi = Math.max(act.lastUserSendAt, act.lastNudgeAt, act.lastKeepaliveAt ?? 0)
  if (now - lastApi < o.idleMs) return false   // 节流，常驻也要守（否则每 5min 一发）
  if (policy === "always") return true
  if (now - act.lastUserSendAt > o.maxIdleMs) return false
  if ((act.keepaliveStreak ?? 0) >= o.maxStreak) return false
  return true
}

// 排本轮该保谁：所有 always 的 + auto 里「susu 最后说话的那个」。
// auto 单选的第一名不够格就这轮 pass，不 fall back 给次活跃（否则十几个窗口会被轮流
// 保暖，正是要堵的洞）；但被标 never 的不占名次，让位给真正该保的那个。
// alive 判 tmux 里还在不在。
export function planKeepalive(
  sessions: Map<string, { lastUserSendAt: number; lastNudgeAt: number; lastKeepaliveAt?: number; keepaliveStreak?: number }>,
  now: number,
  o: KeepaliveOpts,
  alive: (session: string) => boolean,
  policyOf: (session: string) => KeepalivePolicy,
): string[] {
  const out: string[] = []
  let pick: string | null = null
  let best = -Infinity
  for (const [session, act] of sessions) {
    if (!alive(session)) continue
    const policy = policyOf(session)
    if (policy === "never") continue
    if (policy === "always") {
      if (shouldKeepalive(act, now, o, "always")) out.push(session)
      continue
    }
    if (act.lastUserSendAt > best) { best = act.lastUserSendAt; pick = session }
  }
  if (pick && shouldKeepalive(sessions.get(pick)!, now, o, "auto")) out.push(pick)
  return out
}

// 策略表要落盘：ccConfig 整个是内存态（app 重连重发），但保暖恰恰在她**不在**的时候工作——
// 半夜 watchdog 把 hub 踢重启、app 又不在前台的话，她钉的 🔥 常驻会静悄悄失效。
// 只存 always/never，auto 是默认值不占地方（删掉 = 回到 auto）。
const keepalivePoliciesPath = join(SECRETS_DIR, "keepalive-policies.json")
const keepalivePolicies = new Map<string, Exclude<KeepalivePolicy, "auto">>()
// 常驻不拦（她知道自己在干什么），但超过这个数就在日志里唠叨一句——钉太多 = 退回「大家一起烧」
const KEEPALIVE_PIN_WARN = Number(process.env.MP_CC_KEEPALIVE_PIN_WARN) || 3
function keepalivePolicyOf(session: string): KeepalivePolicy {
  return keepalivePolicies.get(session) ?? "auto"
}
function loadKeepalivePolicies(): void {
  try {
    if (!existsSync(keepalivePoliciesPath)) return
    const raw = JSON.parse(readFileSync(keepalivePoliciesPath, "utf-8"))
    for (const [session, p] of Object.entries(raw as Record<string, string>)) {
      if (p === "always" || p === "never") keepalivePolicies.set(session, p)
    }
  } catch (e: any) { console.warn(`[hub] keepalive-policies load fail: ${e.message}`) }
}
function saveKeepalivePolicies(): void {
  try { writeFileSync(keepalivePoliciesPath, JSON.stringify(Object.fromEntries(keepalivePolicies), null, 2)) }
  catch (e: any) { console.warn(`[hub] keepalive-policies save fail: ${e.message}`) }
}

// --- 传输策略：按 session 设「带终端(tmux)/不带终端(stream)」（十二）。app 长按菜单里设，整表随 set_cc_config 下发；
// 没设的跟随全局开关 ccConfig.newSessionTransport。落盘同 keepalive（hub 重启不丢）。
const transportPoliciesPath = join(SECRETS_DIR, "transport-policies.json")
const transportPolicies = new Map<string, "tmux" | "stream">()
export function transportOf(session: string): "tmux" | "stream" {
  return transportPolicies.get(session) ?? ccConfig.newSessionTransport
}
function loadTransportPolicies(): void {
  try {
    if (!existsSync(transportPoliciesPath)) return
    const raw = JSON.parse(readFileSync(transportPoliciesPath, "utf-8"))
    for (const [session, p] of Object.entries(raw as Record<string, string>)) {
      if (p === "tmux" || p === "stream") transportPolicies.set(session, p)
    }
  } catch (e: any) { console.warn(`[hub] transport-policies load fail: ${e.message}`) }
}
function transportPoliciesFrame(): string {
  return JSON.stringify({ type: "transport_policies", policies: Object.fromEntries(transportPolicies) })
}
function saveTransportPolicies(): void {
  try { writeFileSync(transportPoliciesPath, JSON.stringify(Object.fromEntries(transportPolicies), null, 2)) }
  catch (e: any) { console.warn(`[hub] transport-policies save fail: ${e.message}`) }
}

// --- APNs push tokens（app 注册的 device token；hub 在「无人在看」时推主动消息/nudge）---
const voiceCalls = new VoiceCalls(join(SECRETS_DIR, "voice-calls.json"))
const callInstallByWS = new Map<WebSocket, string>()
function broadcastCall(call: object) {
  const frame = JSON.stringify({ type: "voice_call_state", call })
  for (const c of [...mpClients, ...mcpClients]) { try { c.send(frame) } catch {} }
}
const pushTokensPath = join(SECRETS_DIR, "push-tokens.json")
const pushTokens = new Map<string, PushInfo>()
function loadPushTokens(): void {
  for (const [t, info] of readPushTokens(pushTokensPath)) pushTokens.set(t, info)
}
function savePushTokens(): void {
  writePushTokens(pushTokensPath, pushTokens)
}

// --- Live Activity push token（D6）。跟上面 pushTokens 完全隔离：新 Map、新文件、新消息类型。---
const laTokensPath = join(SECRETS_DIR, "la-tokens.json")
const laTokens: LaTokenStore = emptyLaTokenStore()   // 真正加载在 loadHubState()

function sendRegisteredPushes(
  title: string,
  fullBody: string,
  hiddenBody: string,
  contextId: string,
  metadata: Record<string, string> = {},
): void {
  for (const [token, info] of [...pushTokens]) {
    const body = info.preview === "hidden" ? hiddenBody : fullBody
    const tail = `…${token.slice(-8)} env=${info.env} topic=${info.topic ?? "-"}`
    sendAPNs({ token, env: info.env, topic: info.topic }, title, body, contextId, metadata).then(result => {
      if (result.ok) {
        console.log(`[hub] APNs push → ${tail}`)
        return
      }
      console.warn(`[hub] APNs fail ${tail} status=${result.status} reason=${result.reason}`)
      if (isDeadAlertResult(result)) {
        pushTokens.delete(token)
        savePushTokens()
      }
    })
  }
}

export function agoraMentionPushContent(notification: AgoraOwnerMentionNotification) {
  const preview = notification.content.replace(/\s+/g, " ").slice(0, 80)
  return {
    title: `中庭 · ${notification.roomTitle}`,
    fullBody: `${notification.senderDisplayName} (@${notification.senderHandle})：${preview}`,
    hiddenBody: `${notification.senderDisplayName} 在中庭提到了你`,
    contextId: notification.roomId,
    metadata: { agora_room_id: notification.roomId },
  }
}

/// 状态加载 + 常驻钩子只在 startHub() 里做：import 本文件（hub.test.ts / 脚本）必须是惰性的——
/// 不读生产 secrets、不装定时器、不装 process.exit 的崩溃钩子（09-02 e2e 脚本被定时器拖住 3 分钟；
/// 测试进程装了 unhandledRejection→exit(1) 会把无关异步错误变成整个 runner 退出）。
function loadHubState(): void {
  voiceCalls.load()
  const callTimer = setInterval(() => { for (const c of voiceCalls.expire()) broadcastCall(c) }, 1000)
  callTimer.unref()
  initAskUser(SECRETS_DIR, (frame) => {
    for (const c of mpClients) {
      try { c.send(frame) } catch {}
    }
  })
  Object.assign(laTokens, loadLaTokens(laTokensPath))
  loadPushTokens()
  loadReplyLog()
  loadThinkingLog()
  loadSessionMap()
  ccModels.load()
  loadTerminalWindows()
  loadConversationTitles()
  loadKeepalivePolicies()
  loadTransportPolicies()
}

const NUDGE = {
  enabled: process.env.MP_CC_NUDGE_ENABLED !== "0",
  idleMinMs: (Number(process.env.MP_CC_NUDGE_IDLE_MIN_SEC) || 15 * 60) * 1000,  // 默认 15min
  idleMaxMs: (Number(process.env.MP_CC_NUDGE_IDLE_MAX_SEC) || 30 * 60) * 1000,  // 默认 30min
  cooldownMs: (Number(process.env.MP_CC_NUDGE_COOLDOWN_SEC) || 60 * 60) * 1000, // 默认 1h
  quietStartHour: Number(process.env.MP_CC_NUDGE_QUIET_START ?? 0),  // 00:00（按 tzOffset 算，不是 hub 本地）
  quietEndHour: Number(process.env.MP_CC_NUDGE_QUIET_END ?? 6),      // 06:00
  // 静音时段按哪个时区算。粟粟要东八(+8)，但 hub 跑在 PDT Mac → 必须显式偏移，不能用 Mac 本地小时。
  tzOffsetHours: Number(process.env.MP_CC_NUDGE_TZ_OFFSET ?? 8),
}

// 安全：会被替换进 nudge 的 <channel> body 再喂给 claude 的文本，不得含结构标签——
// 否则能逃逸 channel 包裹 / 伪造 <system>、</channel> 等指令注入给 claude（纵深防御，对应加固 E6）。
// 匹配「< 或 </ 后紧跟字母/!」= HTML/XML 标签起手；不误伤数学比较（"x < 5" 的 < 后是空格/数字）。
const TAG_INJECTION_RE = /<\/?[a-zA-Z!]/
function hasTagInjection(s: string): boolean { return TAG_INJECTION_RE.test(s) }

// 运行时 config（app 经 set_cc_config 覆盖；没收到时用 NUDGE 默认 + 写死默认）。不持久化，app 重连重发。
const DEFAULT_NUDGE_TEMPLATE = "[系统] {name} 已经 {idle} 分钟没说话了。如果你想，可以主动找 {name} 说点什么——用 reply 工具回复（chat_id 见本 channel）。也可以选择不打扰。"
const ccConfig = {
  // 默认 "助手"：app 启动后会发 set_cc_config 覆盖成 UserDefaults.assistantName 全局值；
  // 真正 per-floor 改写在 iOS NSE 里做（按 chat_id 反查楼层），这里是 fallback。
  pushName: "助手",
  userName: "用户",
  nudgeEnabled: NUDGE.enabled,
  idleMinMs: NUDGE.idleMinMs,
  idleMaxMs: NUDGE.idleMaxMs,
  quietStartMin: NUDGE.quietStartHour * 60,   // 休眠起（当天分钟数，按 hub 机器本地时区）
  quietEndMin: NUDGE.quietEndHour * 60,        // 休眠止
  cooldownMs: NUDGE.cooldownMs,
  nudgeTemplate: DEFAULT_NUDGE_TEMPLATE,
  // 新建 claude 会话的传输：tmux（有终端镜像）/ stream（无终端，stdio 直连）。只影响新建，已有会话按绑定
  newSessionTransport: (TRANSPORT_LOCK === "stream" ? "stream" : "tmux") as "tmux" | "stream",
}

function rollNudgeThreshold(): number {
  return ccConfig.idleMinMs + Math.random() * (ccConfig.idleMaxMs - ccConfig.idleMinMs)
}

function recordUserActivity(session: string, chatId: string | undefined) {
  const act = sessionActivity.get(session)
    ?? { lastUserSendAt: 0, lastChatId: "", lastNudgeAt: 0, thresholdMs: rollNudgeThreshold() }
  act.lastUserSendAt = Date.now()
  if (chatId) act.lastChatId = chatId
  act.thresholdMs = rollNudgeThreshold()  // 每次发言重掷下一个静默阈值
  act.keepaliveStreak = 0                 // 她回来了 → 保暖次数配额重置
  sessionActivity.set(session, act)
}

function inQuietHours(d: Date): boolean {
  // 按 hub 机器本地时区（不再硬编码东八；电脑设啥时区就按啥）
  const m = d.getHours() * 60 + d.getMinutes()
  const s = ccConfig.quietStartMin, e = ccConfig.quietEndMin
  if (s === e) return false   // 起=止 → 不静音
  return s < e ? (m >= s && m < e) : (m >= s || m < e)
}

// --- Live Activity 周期推送（M3b）的真实依赖。scheduler 本体在 live-activity-scheduler.ts，
// 这里只负责把 hub 的数据源接上去；定时器在 startHub 里起、wss close 时清。---
// phase/since_unix/run_id 的真相源是 M4a 的状态机；这里只存它写进来的快照，缺省 idle。
// 本 lane 不产生 phase 变化，所以隔离验证时岛上永远是 idle —— 那是预期，不是没接上。
const laPhaseBySession = new Map<string, LaPhaseSnapshot>()
// M4b ②：每次写都落盘。hub 被 supervisor 重启后 startHub 里对账（超时的收尾、活着的接着监控）。
const laPhasePath = join(SECRETS_DIR, "la-phase.json")
export function setLaPhase(sessionName: string, snapshot: LaPhaseSnapshot): void {
  const prev = laPhaseBySession.get(sessionName)
  laPhaseBySession.set(sessionName, snapshot)
  saveLaPhase(laPhasePath, Object.fromEntries(laPhaseBySession))
  if (phaseFrameChanged(prev, snapshot)) broadcastSessionPhase(sessionName, snapshot)
}

/// 进度卡 B（粟粟 10-03）：phase 推给所有 app 连接（聊天页的状态卡），不只开着终端的
function sessionCanStop(sessionName: string): boolean {
  // 「停下」= 往 tmux pane 按 Esc（CC / codex 自己的中断）；无终端（stream）会话没有 pane，先不给
  return !streamRunner.has(sessionName) && tmux.hasSession(sessionName)
}
function sessionChatId(sessionName: string): string | undefined {
  return sessionActivity.get(sessionName)?.lastChatId ?? sessionMap.get(sessionName)?.chatId
}
/// 这一轮用了几次「干活」的工具（粟粟 10-04：纯聊天不出状态卡）。key = session；send 时清空
/// K3：transcript 只异步 stat / 读尾巴（原来每 3 秒每个 working 会话同步 stat 两次）
const statMtime = (path: string): Promise<number | undefined> => stat(path).then((s) => s.mtimeMs, () => undefined)
const toolActivity = new ToolActivityTracker({ stat: statMtime, readTail: readTailAsync, now: Date.now })
const toolActivityBySession = toolActivity.bySession
function toolActivityTarget(sessionName: string): { path: string; since: number } | undefined {
  const snap = laPhaseBySession.get(sessionName)
  if (!snap?.since_unix || sessionEngine(sessionName) !== "claude") return undefined
  const claudeSessionId = sessionMap.get(sessionName)?.claudeSessionId
  return claudeSessionId ? { path: claudeTranscriptPath(claudeSessionId), since: snap.since_unix } : undefined
}
/// 从 transcript 尾巴重数一次；transcript 没动过就不读。返回值有没有变
function refreshToolActivity(sessionName: string): Promise<boolean> {
  const t = toolActivityTarget(sessionName)
  return t ? toolActivity.refresh(sessionName, t.path, t.since) : Promise.resolve(false)
}
/// 每 3 秒：还在干活、transcript 半小时内动过的会话，工具数变了就推一帧（卡住的旧 working 隔一分钟才 stat 一次，不读）
let toolActivityTicking = false
async function toolActivityTick(): Promise<void> {
  if (toolActivityTicking) return
  toolActivityTicking = true
  try {
    for (const [name, snap] of [...laPhaseBySession]) {
      if (snap.phase !== "working") continue
      const t = toolActivityTarget(name)
      if (!t || !(await toolActivity.poll(name, t.path, t.since))) continue
      const cur = laPhaseBySession.get(name)
      if (cur?.phase === "working") broadcastSessionPhase(name, cur)
    }
  } finally { toolActivityTicking = false }
}
function broadcastSessionPhase(sessionName: string, snapshot: LaPhaseSnapshot): void {
  if (snapshot.phase === "working") { sendSessionPhaseFrame(sessionName, snapshot); return }
  // 收尾 / 等你那一刻补数一次（tick 可能还没轮到），「做完了」才知道这一轮动没动过工具。
  // 读完再发；读的时候 phase 又跳了就不发这帧（跳的那次自己会发）
  void sendPhaseAfter(refreshToolActivity(sessionName), snapshot, () => laPhaseBySession.get(sessionName),
                      (cur) => sendSessionPhaseFrame(sessionName, cur))
}
function sendSessionPhaseFrame(sessionName: string, snapshot: LaPhaseSnapshot): void {
  const frame = buildSessionPhaseFrame(sessionName, snapshot, sessionCanStop(sessionName), sessionChatId(sessionName),
                                       toolActivityBySession.get(sessionName))
  // 只发报过到（client_info）的 app 连接：老版本 app / 脚本客户端不认这帧，也不该被插队
  for (const c of mpClients) {
    if (c.readyState === c.OPEN && clientInfoByWS.get(c)?.platform !== undefined) { try { c.send(frame) } catch {} }
  }
}

function laListUpdateRecords(): Array<{ activityId: string; record: LaUpdateRecord }> {
  return Object.entries(laTokens.update).map(([activityId, record]) => ({ activityId, record }))
}

/// 取数逻辑抄 terminalUsagePayload（不调它本身：那个绑死了 WS 帧格式）。
/// codex session 的 transcript 在 ~/.codex/sessions，claudeTranscriptPath 对它无效 →
/// model/ctx 缺席（岛显示 `--`），但 5h/7d 与 session 无关，照发。
function laUsageFor(sessionName: string): LaUsageSnapshot {
  const limits = readRateLimits(RATE_LIMIT_CACHE)
  const base = { five_hour: limits.five_hour, seven_day: limits.seven_day }
  if (sessionEngine(sessionName) !== "claude") return base
  const claudeSessionId = sessionMap.get(sessionName)?.claudeSessionId
  if (!claudeSessionId) return base
  const transcript = readTranscriptUsage(claudeTranscriptPath(claudeSessionId), (recordModel) => contextWindowForSession(sessionName, recordModel))
  return { ...base, model: transcript.model, ctx: transcript.ctx }
}

/// 死 token 清理：只碰 LA store，alert 推送那条链一个字节不动。
function laRemoveRecord(activityId: string): void {
  // 隔离验证专用：假 token 必回 BadDeviceToken，记录被删就只能看到第一条推送。
  // 生产没人设这个 env → 行为一个字节不变。
  if (process.env.MP_CC_LA_KEEP_BAD) {
    console.log(`[hub] la record kept (MP_CC_LA_KEEP_BAD) activity=${activityId}`)
    return
  }
  if (unregisterLaToken(laTokens, { kind: "update", activity_id: activityId }).ok) {
    saveLaTokens(laTokensPath, laTokens)
  }
}

// startHub 里赋值。M4a 的状态跳变（priority 10）走这个 ref，跟周期刷新共用同一条串行队列。
let laSchedulerRef: LaScheduler | null = null
export function laEnqueueState(activityId: string, ev: LaEvent, priority: 5 | 10): Promise<APNsResult | undefined> {
  if (!laSchedulerRef) return Promise.resolve(undefined)
  return laSchedulerRef.enqueueState(activityId, ev, priority)
}

// --- M5 ②：push-to-start 的发送链。刻意跟 update 那条分开：路由身份不同（install_id vs
// activity_id）、死 token 该删的记录也不同（start vs update）、走不走 scheduler 也不同
// （start 没有 activityId，没法进 scheduler 按 activity 排的队）。串行 + 单调 timestamp 同款。---
const LA_START_DEAD_REASONS = new Set(["BadDeviceToken", "Unregistered", "ExpiredToken", "DeviceTokenNotForTopic"])
const laStartChains = new Map<string, Promise<unknown>>()
const laStartLastTs = new Map<string, number>()
async function laSendStart(installId: string, record: LaStartRecord, ev: LaEvent): Promise<APNsResult | undefined> {
  const timestampUnix = Math.max(Math.floor(Date.now() / 1000), (laStartLastTs.get(installId) ?? 0) + 1)
  laStartLastTs.set(installId, timestampUnix)
  const tail = `install=${installId} env=${record.env} topic=${record.topic ?? "-"}`
  try {
    const r = await sendLiveActivityAPNs({ token: record.token, env: record.env, topic: record.topic }, ev, { priority: 10, timestampUnix })
    console.log(`[hub] la start → ${tail} status=${r.status} reason=${r.reason ?? "-"}`)
    if (r.status === 410 || (r.reason !== undefined && LA_START_DEAD_REASONS.has(r.reason))) {
      if (unregisterLaToken(laTokens, { kind: "start", install_id: installId }).ok) saveLaTokens(laTokensPath, laTokens)
      laStartChains.delete(installId)
      laStartLastTs.delete(installId)
      console.log(`[hub] la start → ${tail} record removed (${r.reason ?? r.status})`)
    }
    return r
  } catch (e: any) {
    // 4KB 防线会 throw：一台设备起不来不能掀了整轮 fan-out，更不能顶层 uncaught。
    console.log(`[hub] la start → ${tail} status=0 reason=${e?.message ?? "send_threw"}`)
    return undefined
  }
}
function laEnqueueStart(installId: string, ev: LaEvent): Promise<APNsResult | undefined> {
  const record = laTokens.start[installId]
  if (!record) return Promise.resolve(undefined)
  const run = (laStartChains.get(installId) ?? Promise.resolve()).then(
    () => laSendStart(installId, record, ev),
    () => laSendStart(installId, record, ev),
  )
  laStartChains.set(installId, run.catch(() => undefined))
  return run
}
/// 对该 session 远程起一次岛：每条 start 记录各组一份 contentState ——
/// detail 是**每设备**的隐私决定（同一 session 的两台机可以一台看得见题面、一台看不见）。
function laFanOutStart(sessionName: string, snap: LaPhaseSnapshot, usage: LaUsageSnapshot | undefined): void {
  for (const [installId, record] of Object.entries(laTokens.start)) {
    void laEnqueueStart(installId, buildStartEvent(sessionName, buildPhaseContentState(snap, usage, record.preview)))
  }
}

// 周期与宽限：M3b 的定时器和 M4a 跳变推送的 stale-date 必须同一份，
// 两处各写一个数字迟早会漂（岛提前变灰查不出来）。
const laIntervalMs = Number(process.env.MP_CC_LA_INTERVAL_MS) || 180_000
const laGraceSec = 60
// M5 ⑤：系统给单个 activity 的上限是 8h，27000s(7.5h) 留 30 分钟余量主动换岛。env 只给单测调到秒级。
const laRolloverSec = Number(process.env.MP_CC_LA_ROLLOVER_SEC) || 27_000
/// scheduler 上一轮算出来的用量，跳变推送直接抄。状态跳变不为几个数字再同步读一次
/// transcript（512KB 尾部，会阻塞 hub 的终端流）——没缓存就缺席，岛上显示 `--`。
const laUsageCache = new Map<string, LaUsageSnapshot>()
function laUsageForCached(sessionName: string): LaUsageSnapshot {
  const u = laUsageFor(sessionName)
  laUsageCache.set(sessionName, u)
  return u
}
let laRunSeq = 0
/// M4a 的唯一入口：四个显式事件点各调它一次（send / askuser pre / askuser post / reply）。
/// 只有 phase 或 run_id 真跳了才推 priority 10 —— 跳变稀疏，进 Apple 每小时预算没关系。
function onLaPhaseEvent(sessionName: string, ev: LaPhaseEvent): LaPhaseSnapshot | undefined {
  if (!sessionName) return undefined
  const now = Math.floor(Date.now() / 1000)
  const prev = laPhaseBySession.get(sessionName)
  if (ev.kind === "send") toolActivity.reset(sessionName)   // 新一轮从 0 数
  const { next, changed } = reducePhase(prev, ev, now, () => `r-${now}-${++laRunSeq}`)
  setLaPhase(sessionName, next)
  if (!changed) return next
  broadcastTerminalState()
  console.log(`[hub] la phase ${sessionName} ${prev?.phase ?? "-"}→${next.phase} run=${next.run_id ?? "-"} (${ev.kind})`)
  if (next.phase !== "working" && streamRetireWhenIdle.has(sessionName) && !streamRunner.has(sessionName))
    void retireForTransport(sessionName, "传输策略变了，本轮跑完", 0)
  // M4b ⑧：冷启动（hub 起来后第一个 tick 之前）缓存是空的 → 第一次跳变的岛上全是 `--`。
  // 缓存没命中就同步补算一次（一次 512KB 尾读；跳变本来就稀疏，这点代价可接受）。
  const usage = laUsageCache.get(sessionName) ?? laUsageForCached(sessionName)
  const staleDateUnix = now + Math.round(laIntervalMs / 1000) + laGraceSec
  for (const { activityId, record } of laListUpdateRecords()) {
    if (record.session_name !== sessionName) continue
    // detail 是每 activity 的隐私决定：同一 session 的两台设备可以一台看得见、一台看不见。
    const contentState = buildPhaseContentState(next, usage, record.preview)
    void laEnqueueState(activityId, { event: "update", contentState, staleDateUnix }, 10)
  }
  // M5 ②：这个 session 一个岛都没挂着（上面那圈一条都没发）+ 有设备报过 start token
  // → 远程起一个。app 完全没开也能冒出来；起来后 app 被系统唤醒，M2 的全局监听
  // 会把新岛的 update token 报回来（register_la_token kind=update），后续走 update 链。
  if (shouldRemoteStart(laTokens, sessionName, prev?.phase ?? "idle", next.phase)) laFanOutStart(sessionName, next, usage)
  return next
}
// --- M4b ①：看门狗。「hub 活着但 transcript 不动了」是四个事件点唯一盖不住的死法。---
// 判失败只推 done，**不 end**：数据源在 Mac，岛留着让粟粟回来能看到最后状态。
const laWorkingTimeoutSec = Number(process.env.MP_CC_LA_WORKING_TIMEOUT_SEC) || 1800
/// 只 stat 不读（读 512KB 是 laUsageFor 的事，看门狗每 tick 都跑，不能也去读）。
/// codex session / 没绑定 / 文件不在 → undefined，调用方按 `unknown` 处理（不判超时）。
async function laTranscriptMtime(sessionName: string): Promise<number | undefined> {
  if (sessionEngine(sessionName) !== "claude") return undefined
  const claudeSessionId = sessionMap.get(sessionName)?.claudeSessionId
  if (!claudeSessionId) return undefined
  const mtimeMs = await statMtime(claudeTranscriptPath(claudeSessionId))
  return mtimeMs === undefined ? undefined : Math.floor(mtimeMs / 1000)
}
/// 返回本轮判超时的 session 数（重启对账的 log 要用）。K3：stat 走异步，逐会话按各自的采样时刻判，判超时前再 stat 确认
function laWatchdogTick(): Promise<number> {
  // 只看**有岛在挂**、还在 working 的 session：没岛就没人要这个判定，不是 working 的看门狗本来就不判，白 stat。
  const sessions = [...new Set(laListUpdateRecords().map((e) => e.record.session_name))]
    .filter((s) => laPhaseBySession.get(s)?.phase === "working")
  return runLaWatchdog(sessions, {
    snap: (s) => laPhaseBySession.get(s),
    mtime: laTranscriptMtime,
    now: () => Math.floor(Date.now() / 1000),
    apply: (d) => {
      if (d.kind === "unknown") {
        console.log(`[hub] la watchdog session=${d.session} unknown (no transcript)`)
        return
      }
      setLaPhase(d.session, d.next)
      if (d.kind === "progress") return
      console.log(`[hub] la watchdog timeout session=${d.session} idle=${d.idleSec}s`)
      const staleDateUnix = d.next.updated_unix + 300
      for (const { activityId, record } of laListUpdateRecords()) {
        if (record.session_name !== d.session) continue
        const contentState = buildPhaseContentState(d.next, laUsageCache.get(d.session), record.preview)
        void laEnqueueState(activityId, { event: "update", contentState, staleDateUnix }, 10)
      }
    },
  }, laWorkingTimeoutSec)
}
/// askuser hook body → phase 事件。session 只认 sessionMap 反查（codex session / 未绑定
/// 反查不到）——反查不到就丢事件 + log，不猜。
function onLaAskUserPhase(body: any): void {
  const event = body?.event
  if (event !== "pre" && event !== "post") return
  const sessionName = askUserSessionNameOf(typeof body?.session_id === "string" ? body.session_id : "")
  if (!sessionName) {
    console.log(`[hub] la phase askuser ${event} dropped reason=no_session_for_id`)
    return
  }
  if (event === "post") { onLaPhaseEvent(sessionName, { kind: "ask_post" }); return }
  const q = Array.isArray(body.questions) ? body.questions[0] : undefined
  onLaPhaseEvent(sessionName, { kind: "ask_pre", detail: typeof q?.question === "string" ? q.question : undefined })
}

/// FATAL 退出前等模型记录的写链落盘，最多 1s（审查 R1-12）。故意不为这个新加 SIGTERM 处理：那会改变 launchd 停 hub 的行为
function exitAfterFlush(code: number): void {
  void Promise.race([ccModels.flush(), Bun.sleep(1_000)]).finally(() => process.exit(code))
}

export function startHub(): WebSocketServer {
  if (!HUB_TOKEN) {
    console.error("[hub] MP_CC_HUB_TOKEN (or MP_CC_HUB_TOKEN_FILE) env required (use start_hub.sh or VPS deploy/install.sh)")
    process.exit(1)
  }
  const hubToken = HUB_TOKEN
  loadHubState()
  machineInfo = readMachineInfo()
  refreshToolAvailability()
  setInterval(refreshToolAvailability, 5 * 60_000)
  process.on("uncaughtException", (e) => {
    console.error(`[hub] FATAL uncaughtException: ${e?.stack ?? e}`)
    exitAfterFlush(1)
  })
  process.on("unhandledRejection", (e) => {
    console.error(`[hub] FATAL unhandledRejection: ${(e as Error)?.stack ?? e}`)
    exitAfterFlush(1)
  })
  setInterval(() => {
    for (const [sessionName, att] of terminalAttachments) {
      if (att.mpClients.size === 0) continue   // 没人看就不读盘
      sendTerminalUsage(sessionName, att.mpClients)
    }
    broadcastTerminalState()
  }, TERMINAL_USAGE_INTERVAL_MS)
  const agoraProtocol = openAgoraProtocol(SECRETS_DIR)
  // agora 只允许派生 session（mp-cc-<id> / mp-codex-<id>）当 actor：裸 TMUX_SESSION 是
  // 粟粟的日常对话主 session，claim prompt（40KB 房间转录）绝不能打进去（P0 隔离）。
  // codex 二期入场（07-20 粟粟点的）：claim 注入/enter 重试/agora_complete 工具全链现成。
  const agoraSessionAllowed = (s: string) =>
    (s.startsWith("mp-cc-") || s.startsWith("mp-codex-")) && s !== TMUX_SESSION
  const agoraExecutor = new AgoraCCExecutor(
    agoraProtocol.store,
    {
      listSessions: () => listSessions().filter(agoraSessionAllowed),
      ensureSessionAndSend: (sessionName, prompt) => ensureSessionAndSendAsync(sessionName, prompt),
      isSessionDispatchable: agoraSessionAllowed,
    },
    {
      onMentionUpdates: mentions => agoraProtocol.publishMentionUpdates(mentions),
      onTypingChange: (roomId, actorId, sourceId, isTyping) => {
        agoraProtocol.publishTyping(roomId, actorId, sourceId, isTyping)
      },
    },
  )
  agoraExecutorRef = agoraExecutor
  agoraProtocol.setSessionDirectory(agoraExecutor)
  agoraProtocol.setOwnerMentionNotifier(notification => {
    if (pushTokens.size === 0) return
    const push = agoraMentionPushContent(notification)
    sendRegisteredPushes(
      push.title,
      push.fullBody,
      push.hiddenBody,
      push.contextId,
      push.metadata,
    )
  })
  // 自治调用点全兜底：pump 内部已自吞，recoverExpiredClaims 走 store 仍可能抛（坏数据行）——
  // 这里是 hub 顶层，异常逃逸 = uncaughtException = exit(1) = /cc 日常链路一起 crashloop。
  const agoraSafe = (label: string, fn: () => void) => {
    try { fn() } catch (e) { console.warn(`[agora] ${label} 异常（已吞）: ${e instanceof Error ? e.message : e}`) }
  }
  agoraProtocol.setMentionPump(() => agoraSafe("pump", () => agoraExecutor.pump()))
  const agoraBoot = () => {
    agoraSafe("recover@boot", () => agoraExecutor.recoverExpiredClaims(Date.now()))
    agoraSafe("pump@boot", () => agoraExecutor.pump())
  }
  // K1 第 4 步：启动的 recover / pump 要列会话（tmux.list），这时还没有会话快照 → 原来同步 tmux ls（10-11 现场一次 1008ms）。
  // K1 开时排到首份快照之后（refresh 从不 reject；拿不到快照照旧同步查）。listen 等的也是这一轮，通常 agora 启动仍在 listen 之前；
  // 首份 >2s 时排到 listen 之后，pump 自带防重入，事件触发的 pump 照常，先后不影响结果
  if (baseTmux === realTmuxRunner && k1Enabled()) void tmuxState.refresh().finally(agoraBoot)
  else agoraBoot()
  const agoraRecoveryTimer = setInterval(() => agoraSafe("recover@timer", () => agoraExecutor.recoverExpiredClaims(Date.now())), 60_000)
  // Live Activity 周期推送（M3b）。另起一条，跟上面那条 30s terminal_usage 定时器无关 ——
  // 那条的条件是「有人 attach 才发」，岛正好相反（没人看终端时最需要它）。
  // 3 分钟 + priority 5：Apple 对 Live Activity 有每小时预算，30s×120 必撞墙；
  // priority 5 的更新不计预算（代价是系统可能合并/延迟投递，对「数字慢慢变」正合适）。
  const laScheduler = createLaScheduler({
    now: () => Math.floor(Date.now() / 1000),
    listUpdateRecords: laListUpdateRecords,
    usageFor: laUsageForCached,
    phaseFor: (sessionName) => laPhaseBySession.get(sessionName) ?? { phase: "idle" },
    send: (record, ev, opts) => sendLiveActivityAPNs(record, ev, opts),
    removeRecord: laRemoveRecord,
    // M4b2 ⑤：没有任何 push-to-start 记录就别换岛（end 了没替补，比 8h 自然死还早半小时）。
    hasStartRecord: () => Object.keys(laTokens.start).length > 0,
    // 换岛时用**当前**快照起新岛（不是 idle）：新岛一冒出来就该显示这一轮真实的状态。
    remoteStart: (sessionName) => {
      const snap = laPhaseBySession.get(sessionName)
      if (snap) laFanOutStart(sessionName, snap, laUsageCache.get(sessionName))
    },
    log: (line) => console.log(line),
  }, { intervalMs: laIntervalMs, graceSec: laGraceSec, rolloverSec: laRolloverSec })
  laSchedulerRef = laScheduler
  // 看门狗先跑：它可能把 working 判成 done，tick 的 phaseFor 就能读到新值，少发一条旧状态。
  const laTimer = setInterval(() => { void laWatchdogTick().then(() => laScheduler.tick()) }, laIntervalMs)
  const toolActivityTimer = setInterval(() => void toolActivityTick().catch((e) => console.warn(`[hub] toolActivityTick 失败: ${e}`)), 3_000)   // 进度卡：CC 这一轮动没动工具
  // M4b ②：hub 重启对账。恢复快照后立刻跑一次看门狗 —— 超时的走 ① 的失败路径推 done，
  // 没超时的留在内存里接着被监控。必须在 laSchedulerRef 赋值之后（推送要走它）。
  {
    const restored = loadLaPhase(laPhasePath)
    // 直接写 Map：这一批本来就是从盘上来的，走 setLaPhase 会 N 次重写同一份内容。
    for (const [session, snap] of Object.entries(restored)) laPhaseBySession.set(session, snap)
    void laWatchdogTick().then((timedOut) => console.log(`[hub] la phase restored sessions=${Object.keys(restored).length} timed_out=${timedOut}`))
  }
  // 加固 E1：不绑 0.0.0.0（那会连 VPN/热点等杂接口也监听）。探测本机地址，只绑
  // loopback + LAN(192/10/172.16) + Tailscale(100.64/10) 这几个具体地址，multi-listener。
  // MP_CC_HUB_HOST 设具体值（非 auto）则只绑那个（兼容/手动覆盖）。
  // detectInterfaces 在模块顶层（纯函数，可单测分类逻辑）。出国后 Tailscale 常晚于 hub
  // 启动（launchd 开机自启 / 酒店重连网络），初始绑定后有 30s 自愈重检更新这个 detected。
  let detected = detectInterfaces()
  // 绑定开关：Mac app 经 set_bind 控制 hub 实不实绑 LAN / Tailscale（持久 secrets/bind-config.json）。
  // 关 LAN = hub 不再监听 LAN 接口 = 真正消除 LAN 暴露。loopback 永远绑（本机必须）。
  const bindPrefs = new BindPrefsCache(join(SECRETS_DIR, "bind-config.json"))
  const relayConfigPath = join(SECRETS_DIR, "relay.json")
  let relayIngressOpen = false
  const manualHost = (HUB_HOST && HUB_HOST !== "auto" && HUB_HOST !== "0.0.0.0") ? HUB_HOST : null
  const listeners = new Map<string, ReturnType<typeof createServer>>()

  // GET /health（看门狗探活）+ GET /pair（Mac app 取配对信息）——两者仅 loopback（/pair 含 token）。
  // /pair 只返回**当前实际绑了**的 LAN / Tailscale 地址（关掉的不广播），手机都存自动 fallback。
  const httpHandler = (req: IncomingMessage, res: ServerResponse) => {
    const path = req.url?.split("?")[0]
    // /health 仍 loopback 免鉴权（Phase 2.5 观察后决定是否收紧）
    if (req.method === "GET" && path === "/health") {
      // x-mp-hub：app 连接竞速认这个头，手机代理替不通地址回的 502 没有它（plan-hub-instant-connect）
      if (!isTrustedLocal(req)) { res.writeHead(403, { "x-mp-hub": "1" }); res.end("forbidden"); return }
      res.writeHead(200, { "content-type": "application/json", "x-mp-hub": "1" })
      res.end(JSON.stringify({ ok: true, mp: mpClients.size, mcp: mcpClients.size, uptime: Math.round(process.uptime()),
        tmuxCtl: { state: sharedTmuxControl()?.state ?? "off", ...tmuxRunCounts },
        ...(BENCH_HEALTH ? { bench: { lags: lagLog.list(), block: blockLedger.top(30) } } : {}) }))
      return
    }
    // #if PERSONAL_APPS
    // GET /warroom/sessions（军机处 M0 普查查询）：loopback + token。
    // 参数：cwd=（LIKE 模糊）alive=0|1 engine=claude|codex zombies=1 limit=N
    if (req.method === "GET" && path === "/warroom/sessions") {
      if (!isTrustedLocal(req)) { res.writeHead(403); res.end("forbidden"); return }
      const u = new URL(req.url ?? "", "http://localhost")
      if (u.searchParams.get("token") !== HUB_TOKEN) { res.writeHead(401); res.end("unauthorized"); return }
      if (!warroomIndexer) { res.writeHead(503); res.end(JSON.stringify({ error: "indexer not ready" })); return }
      try {
        const rows = warroomIndexer.querySessions({
          cwd: u.searchParams.get("cwd") ?? undefined,
          alive: u.searchParams.get("alive") ?? undefined,
          engine: u.searchParams.get("engine") ?? undefined,
          zombies: u.searchParams.get("zombies") === "1",
          limit: Number(u.searchParams.get("limit")) || undefined,
        })
        res.writeHead(200, { "content-type": "application/json" })
        res.end(JSON.stringify({ sessions: rows, scan: warroomLastScan }))
      } catch (e: any) {
        res.writeHead(500); res.end(JSON.stringify({ error: e?.message }))
      }
      return
    }
    // GET /warroom/tasks（奏折账本查询）：loopback + token
    if (req.method === "GET" && path === "/warroom/tasks") {
      if (!isTrustedLocal(req)) { res.writeHead(403); res.end("forbidden"); return }
      const u = new URL(req.url ?? "", "http://localhost")
      if (u.searchParams.get("token") !== HUB_TOKEN) { res.writeHead(401); res.end("unauthorized"); return }
      if (!warroomLedger) { res.writeHead(503); res.end(JSON.stringify({ error: "ledger not ready" })); return }
      const rows = warroomLedger.queryTasks({
        status: u.searchParams.get("status") ?? undefined,
        target: u.searchParams.get("target") ?? undefined,
        limit: Number(u.searchParams.get("limit")) || undefined,
      })
      res.writeHead(200, { "content-type": "application/json" })
      res.end(JSON.stringify({ tasks: rows }))
      return
    }
    // POST /warroom/dispatch（开奏折并派发）：loopback + token + 中枢名单
    if (req.method === "POST" && path === "/warroom/dispatch") {
      if (!isTrustedLocal(req)) { res.writeHead(403); res.end("forbidden"); return }
      const u = new URL(req.url ?? "", "http://localhost")
      if (u.searchParams.get("token") !== HUB_TOKEN) { res.writeHead(401); res.end("unauthorized"); return }
      let body = ""
      req.on("data", (c) => { body += c; if (body.length > 100_000) { res.writeHead(413); res.end(); req.destroy() } })
      req.on("end", () => {
        void (async () => {
          const respond = (code: number, obj: object) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(obj)) }
          if (!warroomLedger || !warroomDispatcher) return respond(503, { error: "warroom not ready" })
          let p: any
          try { p = JSON.parse(body) } catch { return respond(400, { error: "bad json" }) }
          const actor = String(p.actor ?? "")
          if (!warroomCentralSessions().has(actor)) return respond(403, { error: `actor "${actor}" 不在中枢名单——只有御前会话可批奏折` })
          if (!p.title || !p.body || !p.target_ref) return respond(400, { error: "need title/body/target_ref" })
          const ledger = warroomLedger, dispatcher = warroomDispatcher
          try {
            const task = await retryBusy(() => ledger.createTask({
              title: String(p.title), body: String(p.body),
              target_kind: p.target_kind === "tmux" ? "tmux" : p.target_kind === "repo" ? "repo" : "resume",
              target_ref: String(p.target_ref),
              engine: p.engine === "codex" ? "codex" : "claude",
              created_by: actor, approval: p.approval === "ask_susu" ? "ask_susu" : undefined,
              filescope: typeof p.filescope === "string" ? p.filescope : null,
              depends_on: Array.isArray(p.depends_on) ? p.depends_on.map(String) : undefined,
              epic: typeof p.epic === "string" ? p.epic : null,
            }))
            if (task.approval === "ask_susu") {
              return respond(200, { task_id: task.task_id, status: task.status, note: "危险工单已立案但未派发——需要粟粟亲批（approval=ask_susu）" })
            }
            if (!ledger.depsSatisfied(task)) {
              return respond(200, { task_id: task.task_id, status: "draft", note: "已立案排队——依赖未全部朱批，DAG 定时器会在前置完成后自动放行" })
            }
            // M2：记 git base——验收时 diff <base> 就是这张奏折的全部变更
            // repo 单的 cwd = target_ref 本身（普查表查不到）
            const baseCwd = task.target_kind === "repo" ? task.target_ref : warroomLookupTarget(task.target_ref)?.cwd
            if (baseCwd) {
              try {
                const base = execFileSync("git", ["rev-parse", "HEAD"], { cwd: baseCwd }).toString().trim()
                await retryBusy(() => ledger.attachEvidence(task.task_id, { git_base: base }, "hub"))
              } catch { /* cwd 无 git，验收官只审 transcript */ }
            }
            const r = await dispatcher.dispatch(task.task_id, actor, p.budget_ok === true)
            return respond(200, { task_id: task.task_id, status: ledger.getTask(task.task_id)!.status, channel: r.channel, note: r.note })
          } catch (e: any) {
            const code = e instanceof TargetBusy ? 409 : 400
            return respond(code, { error: e?.message })
          }
        })()
      })
      return
    }
    // POST /warroom/verdict（御裁签字）：loopback + token + 中枢名单
    if (req.method === "POST" && path === "/warroom/verdict") {
      if (!isTrustedLocal(req)) { res.writeHead(403); res.end("forbidden"); return }
      const u = new URL(req.url ?? "", "http://localhost")
      if (u.searchParams.get("token") !== HUB_TOKEN) { res.writeHead(401); res.end("unauthorized"); return }
      let vbody = ""
      req.on("data", (c) => { vbody += c; if (vbody.length > 50_000) { res.writeHead(413); res.end(); req.destroy() } })
      req.on("end", () => {
        const respond = (code: number, obj: object) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(obj)) }
        if (!warroomLedger) return respond(503, { error: "ledger not ready" })
        let p: any
        try { p = JSON.parse(vbody) } catch { return respond(400, { error: "bad json" }) }
        if (!warroomCentralSessions().has(String(p.actor ?? ""))) return respond(403, { error: "只有御前会话可签朱批" })
        const task = warroomLedger.getTask(String(p.task_id ?? ""))
        if (!task) return respond(404, { error: "task not found" })
        try {
          if (p.decision === "release") {
            // 御批放行：ask_susu 危险单经粟粟点头 → 降 approval 并立即派发
            void (async () => {
              try {
                if (task.approval === "ask_susu") {
                  await retryBusy(() => warroomLedger!.db.query("UPDATE tasks SET approval = 'auto' WHERE task_id = ?").run(task.task_id))
                }
                if (!warroomLedger!.depsSatisfied(warroomLedger!.getTask(task.task_id)!)) {
                  res.writeHead(200, { "content-type": "application/json" })
                  res.end(JSON.stringify({ task_id: task.task_id, status: "draft", note: "已放行但依赖未满足——DAG 定时器会自动派" }))
                  return
                }
                const r = await warroomDispatcher!.dispatch(task.task_id, p.actor, p.budget_ok === true)
                res.writeHead(200, { "content-type": "application/json" })
                res.end(JSON.stringify({ task_id: task.task_id, status: warroomLedger!.getTask(task.task_id)!.status, channel: r.channel, note: `御批放行: ${r.note}` }))
              } catch (e: any) {
                res.writeHead(400, { "content-type": "application/json" })
                res.end(JSON.stringify({ error: e?.message }))
              }
            })()
            return
          }
          if (p.decision !== "approve" && p.decision !== "reject" && p.decision !== "fail") return respond(400, { error: "decision must be approve|reject|fail" })
          // K2 审查 R1-1：账本写撞上 scan worker 的批事务 → 异步退避重试，最终失败照旧回 400
          const ledger = warroomLedger
          void (async () => {
            try {
              if (p.decision === "approve") {
                await retryBusy(() => ledger.attachVerdict(task.task_id, { verdict: "approved", reasons: [String(p.reason ?? "御批")], by: p.actor }, p.actor))
                await retryBusy(() => ledger.transition(task.task_id, "approved", p.actor, String(p.reason ?? "御批")))
              } else if (p.decision === "reject") {
                await retryBusy(() => ledger.attachVerdict(task.task_id, { verdict: "rejected", reasons: [String(p.reason ?? "御驳")], by: p.actor }, p.actor))
                await retryBusy(() => ledger.transition(task.task_id, "rejected", p.actor, String(p.reason ?? "御驳")))
              } else {
                await retryBusy(() => ledger.transition(task.task_id, "failed", p.actor, String(p.reason ?? "废案")))
              }
              respond(200, { task_id: task.task_id, status: ledger.getTask(task.task_id)!.status })
            } catch (e: any) { respond(400, { error: e?.message }) }
          })()
        } catch (e: any) { return respond(400, { error: e?.message }) }
      })
      return
    }
    // #endif
    // /pair：Phase 2 主体收紧——loopback 也强制 ?token= 校验，堵本机原生进程免鉴权拿 token
    if (req.method === "GET" && path === "/pair") {
      const provided = new URL(req.url ?? "", "http://localhost").searchParams.get("token")
      if (provided !== HUB_TOKEN) {
        console.warn(`[hub] /pair auth failed from ${req.socket.remoteAddress}`)
        res.writeHead(401); res.end("unauthorized")
        return
      }
      res.writeHead(200, { "content-type": "application/json" })
      const lanU = detected.lan && listeners.has(detected.lan) ? `ws://${detected.lan}:${PORT}/cc` : null
      const tsU = detected.tailscale && listeners.has(detected.tailscale) ? `ws://${detected.tailscale}:${PORT}/cc` : null
      // #068：中继入口开着才给 u3（手机连中继的 wss 地址）和 p3（自签证书的 SPKI pin）
      const relayCfg = relayIngressOpen ? loadRelayConfig(relayConfigPath) : null
      const relay = relayCfg && typeof relayCfg === "object" ? { u3: relayPhoneURL(relayCfg), p3: relayCfg.pinSpkiSha256 ?? null } : {}
      res.end(JSON.stringify({ mpcc: 1, u: lanU ?? tsU, u2: lanU ? tsU : null, t: HUB_TOKEN ?? "", ...relay }))
      return
    }
    // POST /thinking（仅 loopback）：Stop hook 回传当轮思考链。
    // 锚定到该 chat 最近一条 reply 的 mp_msg_id；锚不上（该轮没 reply）丢弃。
    if (req.method === "POST" && path === "/thinking") {
      if (!isTrustedLocal(req)) { res.writeHead(403); res.end("forbidden"); return }
      let body = ""
      let overflow = false
      req.on("data", (chunk) => {
        body += chunk
        if (body.length > 1_000_000) { overflow = true; res.writeHead(413); res.end(); req.destroy() }   // hook 的 json.dumps 中文转 \uXXXX（6 倍）：thinking 64k + 正文 20k + rows 20k 字
      })
      req.on("end", () => {
        if (overflow) return
        const respond = (code: number, obj: object) => {
          res.writeHead(code, { "content-type": "application/json" })
          res.end(JSON.stringify(obj))
        }
        let o: any
        try { o = JSON.parse(body) } catch { respond(400, { ok: false, reason: "invalid_json" }); return }
        const [code, obj] = processThinkingPost(o)
        respond(code, obj)
      })
      return
    }
    // POST /la/lifecycle（M4b ⑤）：无条件生命周期事件。**不**受 MP_CC_LA_DEBUG 门控 ——
    // 这是生产用的：Stop hook 每轮结束都打一条，跟「有没有 thinking / 锚不锚得上」无关。
    // 守卫照 /thinking（只 loopback，不要 ?token=）而不是 /pair：hook 跑在 tmux 里拿不到
    // MP_CC_HUB_TOKEN，带 token 的版本永远 401，岛就永远卡在 working。最坏后果也只是
    // 本机进程把一个 session 标成 done，不是发真推送 —— 跟 /la/push 的敏感度不是一回事。
    if (req.method === "POST" && path === "/la/lifecycle") {
      if (!isTrustedLocal(req)) { res.writeHead(403); res.end("forbidden"); return }
      let body = ""
      let overflow = false
      req.on("data", (chunk) => {
        body += chunk
        if (body.length > 4_000) { overflow = true; res.writeHead(413); res.end(); req.destroy() }
      })
      req.on("end", () => {
        if (overflow) return
        const respond = (code: number, obj: object) => {
          res.writeHead(code, { "content-type": "application/json" })
          res.end(JSON.stringify(obj))
        }
        let o: any
        try { o = JSON.parse(body) } catch { respond(400, { ok: false, reason: "invalid_json" }); return }
        if (o?.event !== "stop") { respond(400, { ok: false, reason: "unknown_event" }); return }
        // 没有 `sessionNameOf`：claude session_id → tmux session 名的现成反查叫 askUserSessionNameOf。
        const sessionName = askUserSessionNameOf(typeof o.session_id === "string" ? o.session_id : "")
        if (!sessionName) {
          console.log("[hub] la lifecycle stop dropped reason=no_session_for_id")
          respond(200, { ok: false, reason: "no_session_for_id" })
          return
        }
        // pendingRemains 跟 reply 兜底那条同款：还挂着问题时 waiting 优先，别把「等你」抹成 done。
        const snap = onLaPhaseEvent(sessionName, {
          kind: "reply",
          pendingRemains: askUserPendingList().some((p) => p.sessionName === sessionName),
        })
        console.log(`[hub] la lifecycle stop session=${sessionName} → ${snap?.phase ?? "-"}`)
        void onSessionTurnEnded(sessionName)
        scheduleTurnSafetyNet(sessionName, typeof o.session_id === "string" ? o.session_id : "")
        respond(200, { ok: true, session_name: sessionName, phase: snap?.phase })
      })
      return
    }
    // POST /la/push：Live Activity 手推调试口。
    // M3a 的最小可交付线——只证明「hub 能对一个 activity token 发出一条 update」。
    // 不读 la-tokens.json（M2）、不带任何定时器（M3b）：token 和 env 直接由 body 给。
    //
    // 守卫照 /pair 而不是 /thinking：这个入口能拿生产 .p8 对任意 token 发真推送，比 /pair 更敏感。
    // 三重：MP_CC_LA_DEBUG 未设直接 404（调试口不随 macOS app 出货）+ loopback + ?token=HUB_TOKEN。
    if (req.method === "POST" && path === "/la/push") {
      if (!process.env.MP_CC_LA_DEBUG) { res.writeHead(404); res.end("not found"); return }
      if (!isTrustedLocal(req)) { res.writeHead(403); res.end("forbidden"); return }
      if (new URL(req.url ?? "", "http://localhost").searchParams.get("token") !== HUB_TOKEN) {
        console.warn(`[hub] /la/push auth failed from ${req.socket.remoteAddress}`)
        res.writeHead(401); res.end("unauthorized")
        return
      }
      let body = ""
      let overflow = false
      req.on("data", (chunk) => {
        body += chunk
        if (body.length > 20_000) { overflow = true; res.writeHead(413); res.end(); req.destroy() }
      })
      req.on("end", () => {
        if (overflow) return
        const respond = (code: number, obj: object) => {
          res.writeHead(code, { "content-type": "application/json" })
          res.end(JSON.stringify(obj))
        }
        let o: any
        try { o = JSON.parse(body) } catch { respond(400, { ok: false, reason: "invalid_json" }); return }
        // 两种形态：直接给 token（M3a 原样保留），或给 activity_id 从 M2 的 store 取 token/env
        // （M3b 之后调试常态：手上只有 app 报上来的 activity id）。
        const fromStore = typeof o.activity_id === "string" ? laTokens.update[o.activity_id] : undefined
        if (typeof o.activity_id === "string" && !fromStore) {
          respond(404, { ok: false, reason: "unknown_activity_id" })
          return
        }
        // M5 ③：event:"start" 的取值路径。start token 按 install_id 存（它压根没有 activity_id），
        // 所以另开一条；直接给 token 的 M3a 老形态对 start 同样有效。
        const fromStart = typeof o.install_id === "string" ? laTokens.start[o.install_id] : undefined
        if (typeof o.install_id === "string" && !fromStart) {
          respond(404, { ok: false, reason: "unknown_install_id" })
          return
        }
        // M4a 调试：phase_event 走状态机（不需要 state；contentState 由 reducer + 记录的 preview 组）。
        if (typeof o.phase_event === "string") {
          const kind = o.phase_event as LaPhaseEvent["kind"]
          const sessionName = fromStore?.session_name ?? (typeof o.session_name === "string" ? o.session_name : "")
          if (!sessionName || !["send", "ask_pre", "ask_post", "reply"].includes(kind)) {
            respond(400, { ok: false, reason: "invalid_phase_event" })
            return
          }
          const pev: LaPhaseEvent = kind === "ask_pre"
            ? { kind, detail: typeof o.detail === "string" ? o.detail : undefined }
            : kind === "reply" ? { kind, pendingRemains: o.pending_remains === true } : { kind: kind as "send" | "ask_post" }
          const before = laPhaseBySession.get(sessionName)
          const snap = onLaPhaseEvent(sessionName, pev)
          respond(200, {
            ok: true, session_name: sessionName, phase: snap?.phase, run_id: snap?.run_id,
            // 有没有真跳变（=有没有发 priority 10 那条），调试口的可观测出口
            changed: snap?.phase !== before?.phase || snap?.run_id !== before?.run_id,
            // 该 activity 实际会发出去的 contentState（detail 已按记录的 preview 过滤）
            state: snap && fromStore ? buildPhaseContentState(snap, laUsageCache.get(sessionName), fromStore.preview) : undefined,
          })
          return
        }
        const token = fromStore?.token ?? fromStart?.token ?? (typeof o.token === "string" ? o.token : "")
        if (!token || typeof o.state !== "object" || o.state === null) {
          respond(400, { ok: false, reason: "invalid_body" })
          return
        }
        // 拼错一个键名 APNs 照样 200、真机岛静默不动——发出去之前拦。
        const stateErr = validateContentState(o.state)
        if (stateErr) { respond(400, { ok: false, reason: stateErr }); return }
        const state = o.state as CCActivityState
        const env: "sandbox" | "production" = fromStore?.env ?? fromStart?.env ?? (o.env === "production" ? "production" : "sandbox")
        const topic = fromStore?.topic ?? fromStart?.topic ?? normalizeTopic(o.topic)
        const priority: 5 | 10 = o.priority === 5 ? 5 : 10
        const staleDateUnix = typeof o.stale_in_sec === "number"
          ? Math.floor(Date.now() / 1000) + o.stale_in_sec
          : undefined
        let ev: LaEvent
        if (o.event === "start") {
          // attributes 里的 session_name 决定岛属于哪个 session，没有就没法起——不猜。
          const startSession = typeof o.session_name === "string" ? o.session_name : fromStore?.session_name
          if (!startSession) { respond(400, { ok: false, reason: "missing_session_name" }); return }
          ev = buildStartEvent(startSession, state)
        } else if (o.event === "end") {
          ev = { event: "end", contentState: state }
        } else {
          ev = { event: "update", contentState: state, staleDateUnix }
        }
        const tail = `token=…${token.slice(-8)} env=${env} topic=${topic ?? "-"}`
        sendLiveActivityAPNs({ token, env, topic }, ev, { priority }).then((r) => {
          console.log(`[hub] la push → ${tail} status=${r.status} reason=${r.reason ?? "-"}`)
          respond(200, { ok: r.ok, status: r.status, reason: r.reason })
        }).catch((e: any) => {
          // buildLiveActivityPayload 的 4KB 防线会 throw，别让它掀了 hub、也别让请求挂着不回
          const code = e instanceof LaPayloadTooLargeError ? 413 : 500
          console.log(`[hub] la push → ${tail} status=0 code=${code} reason=${e?.message}`)
          respond(code, { ok: false, status: 0, reason: e?.message })
        })
      })
      return
    }
    // POST /agent/ask-user（仅 loopback）：AskUserQuestion hook 上报（pre=题面 / post=答案）。
    // 记账/广播在 askuser.ts；declined（Esc）不触发 PostToolUse，由 reply 到达兜底收账。
    if (req.method === "POST" && path === "/agent/ask-user") {
      if (!isTrustedLocal(req)) { res.writeHead(403); res.end("forbidden"); return }
      let body = ""
      let overflow = false
      req.on("data", (chunk) => {
        body += chunk
        if (body.length > 100_000) { overflow = true; res.writeHead(413); res.end(); req.destroy() }
      })
      req.on("end", () => {
        if (overflow) return
        let o: any
        try { o = JSON.parse(body) } catch {
          res.writeHead(400, { "content-type": "application/json" })
          res.end(JSON.stringify({ ok: false, reason: "invalid_json" }))
          return
        }
        const r = handleAskUserHook(o, askUserSessionNameOf)
        if (r.ok) onLaAskUserPhase(o)   // M4a：pre → waiting（带题面首行）/ post → working
        res.writeHead(r.ok ? 200 : 400, { "content-type": "application/json" })
        res.end(JSON.stringify(r))
      })
      return
    }
    // POST /agent/book-note（loopback-only）：CC 的共读批注 → daemon 同款投递链。
    // 开关 coRead.cc（默认关）；书籍坐标由 reading-context 补全，CC 只管 quote+comment。
    if (req.method === "POST" && path === "/agent/book-note") {
      if (!isTrustedLocal(req)) { res.writeHead(403); res.end("forbidden"); return }
      let body = ""
      let overflow = false
      req.on("data", (chunk) => {
        body += chunk
        if (body.length > 100_000) { overflow = true; res.writeHead(413); res.end(); req.destroy() }
      })
      req.on("end", () => {
        if (overflow) return
        const fail = (msg: string) => {
          res.writeHead(200, { "content-type": "application/json" })
          res.end(JSON.stringify({ ok: false, error: msg }))
        }
        if (loadAgentConfig().coRead.cc !== true) {
          fail(`共读批注开关是关的——${ccConfig.userName}没在 app 设置里打开「CC 共读」，别硬写，想批注可以先跟对方说`); return
        }
        // 复用 daemon 的产出校验（annotations 形状/锚长度/条数上限）
        const output = parseReaderOutput(body)
        if (!output) { fail("参数不合法：annotations[].anchorText(6-200字)+comment 必填，或至少给 message"); return }
        // reading-context 新鲜度：不是今天写的 = 她今天没读书，没有可锚定的页面
        const ctxPath = join(agentDir(), "reading-context.json")
        try {
          const mtime = statSync(ctxPath).mtime
          if (mtime.toDateString() !== new Date().toDateString()) {
            fail(`没有今天的共读上下文——${ccConfig.userName}今天还没翻书，批注没有落点`); return
          }
        } catch { fail("没有共读上下文（reading-context.json 不存在）"); return }
        const payload = buildBookNotePayload(output, agentDir())
        if (!payload) { fail("共读上下文损坏，组不出投递 payload"); return }
        payload.source = "cc"
        if (!deliverBookNote(payload, agentDir())) { fail("投递失败（pending 写入错误）"); return }
        console.log(`[hub] cc book_note → ${payload.safeName} ch${payload.chapter} 批注×${output.notes.length}${output.message ? "+消息" : ""}`)
        res.writeHead(200, { "content-type": "application/json" })
        res.end(JSON.stringify({ ok: true, book: payload.bookName, chapter: payload.chapter, notes: output.notes.length, message: !!output.message }))
      })
      return
    }
    // POST /pocket/cmd（loopback-only）：CC 遥控手机 WebView——转发给 MP，等回包。
    // POST /twitter/cmd（loopback-only）：小克用本地推特（app 端 TwitterCCBridge）——同一套转发。
    const appCmd = req.method === "POST" && path === "/pocket/cmd" ? { frame: "pocket_cmd", maxMs: 120000 }
      : req.method === "POST" && path === "/twitter/cmd" ? { frame: "twitter_cmd", maxMs: 30000 }
      : null
    if (appCmd) {
      if (!isTrustedLocal(req)) { res.writeHead(403); res.end("forbidden"); return }
      let body = ""
      let overflow = false
      req.on("data", (chunk) => {
        body += chunk
        if (body.length > 200_000) { overflow = true; res.writeHead(413); res.end(); req.destroy() }
      })
      req.on("end", () => {
        if (overflow) return
        let cmd: any
        try { cmd = JSON.parse(body) } catch { res.writeHead(400); res.end('{"ok":false,"error":"bad json"}'); return }
        let target: import("ws").WebSocket | null = null
        if (appCmd.frame === "twitter_cmd") {
          target = pickPhoneClient(mpClients, clientInfoByWS)
          if (!target) { res.writeHead(503); res.end('{"ok":false,"error":"手机上的 app 没连着 hub（推特数据在手机上，只发手机）"}'); return }
        } else {
          for (const c of mpClients) { if (c.readyState === c.OPEN) { target = c; break } }
        }
        if (!target) { res.writeHead(503); res.end('{"ok":false,"error":"phone not connected"}'); return }
        const id = crypto.randomUUID()
        const timeoutMs = Math.min(typeof cmd.timeout_ms === "number" ? cmd.timeout_ms : 30000, appCmd.maxMs)
        const timer = setTimeout(() => {
          pocketPending.delete(id)
          res.writeHead(200, { "content-type": "application/json" })
          res.end(JSON.stringify({ ok: false, error: "timeout" }))
        }, timeoutMs)
        pocketPending.set(id, {
          resolve: (result: any) => {
            clearTimeout(timer)
            pocketPending.delete(id)
            res.writeHead(200, { "content-type": "application/json" })
            res.end(JSON.stringify(result))
          },
          timer,
        })
        try {
          target.send(JSON.stringify({ type: appCmd.frame, id, ...cmd }))
          console.log(`[hub] ${appCmd.frame} → MP id=${id.slice(0, 8)} action=${cmd.action ?? cmd.input?.action}`)
        } catch (e: any) {
          clearTimeout(timer)
          pocketPending.delete(id)
          res.writeHead(500, { "content-type": "application/json" })
          res.end(JSON.stringify({ ok: false, error: e.message }))
        }
      })
      return
    }
    res.writeHead(426); res.end("upgrade required")   // 非 WS 非 health/pair/thinking/pocket
  }
  const wss = new WebSocketServer({ noServer: true })

  // 网卡 listener 和中继入口（relay-ingress.ts，先过它自己的路径白名单）共用
  const onUpgrade = (req: IncomingMessage, socket: import("node:stream").Duplex, head: Buffer) => {
    // Origin 头拦截：浏览器 WebSocket 强制发 Origin，原生 client（URLSession/Bun）不发。堵浏览器 drive-by。
    const origin = req.headers.origin
    if (origin) {
      console.warn(`[hub] upgrade rejected origin=${origin} ip=${req.socket.remoteAddress}`)
      socket.destroy()
      return
    }
    // 畸形请求目标（如 "//"）让 new URL 抛错：不接住会走 uncaughtException 让整个 hub 退出
    let upgradeUrl: URL
    try { upgradeUrl = new URL(req.url ?? "", "http://localhost") } catch {
      socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
      return
    }
    if (upgradeUrl.pathname === "/agora" && !hasValidAgoraToken(req.url ?? "", hubToken)) {
      console.warn(`[hub] Agora auth failed from ${req.socket.remoteAddress}`)
      socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
      socket.destroy()
      return
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req))
  }

  /// afterListen：listen 成功、PORT 已是真实端口之后、打 `listening` 那行之前跑（内嵌 hub 要在 Swift 判就绪前写好 mcp 配置）
  function bindHost(host: string, afterListen?: () => void, onError?: (e: any) => void): void {
    if (listeners.has(host)) return
    const srv = createServer(httpHandler)
    srv.on("upgrade", onUpgrade)
    srv.on("error", (e: any) => {
      console.error(`[hub] listen ${host}:${PORT} error: ${e.message}`)
      listeners.delete(host)
      onError?.(e)
    })
    srv.listen(PORT, host, () => {
      // PORT=0 时 OS 分配，listen 后从 server 实例拿真实端口；
      // 第一个 listener 完成时把真实端口写回全局 PORT，让后续 LAN/Tailscale listener 用同一端口。
      // ⚠️ 后续 listener 必须等这里跑完再绑（见下面初始绑定），同步连绑会各自 listen 0、拿到三个不同端口（#046 astra P1-1）。
      const addr = srv.address()
      if (PORT === 0 && addr && typeof addr === "object" && "port" in addr) {
        PORT = addr.port
      }
      afterListen?.()
      // Swift 父进程 parse 第一行 stdout 拿端口（Mac app 集成模式）。
      // 非集成模式（粟粟自己跑 master）也无副作用，多一行 JSON 日志。
      console.log(JSON.stringify({ event: "listening", host, port: PORT, scheme: "ws", paths: ["/cc", "/mcp", "/agora"] }))
      console.log(`[hub] listening on ws://${host}:${PORT}/cc, /mcp and /agora`)
    })
    listeners.set(host, srv)
  }
  function unbindHost(host: string): void {
    const s = listeners.get(host); if (!s) return
    s.close(); listeners.delete(host); console.log(`[hub] unbound ${host}:${PORT}`)
  }

  wss.on("connection", (ws, req) => timeHandler(() => wsSite("ws connect", (req.url ?? "").split("?")[0]), () => {
    // 解析 URL（带 query）
    let reqUrl: URL
    try { reqUrl = new URL(req.url ?? "", "http://localhost") } catch { ws.close(1008, "bad url"); return }
    const pathname = reqUrl.pathname

    // 鉴权：不是本机直连（isTrustedLocal）必须带正确 query token
    // ⚠️ Phase 2 尝试过强制 loopback 也校验，但漏了粟粟 iPhone 模拟器（无 Mac app 生成 QR
    //    路径就没 token）→ 立即 rollback。真正修需要模拟器/iOS client 也走扫码流程或
    //    手动写 keychain，Phase 2.6 补做。
    const remote = relayIngressRequests.has(req) ? "relay" : req.socket.remoteAddress
    const trustedLocal = isTrustedLocal(req)   // 口令 / bundle / set_bind 共用这一个结果
    if (pathname === "/agora") {
      if (!hasValidAgoraToken(req.url ?? "", hubToken)) {
        ws.close(1008, "auth")
        return
      }
    } else if (!trustedLocal) {
      const provided = reqUrl.searchParams.get("token")
      if (provided !== HUB_TOKEN) {
        console.warn(`[hub] auth failed from ${remote} (path=${pathname})`)
        ws.close(1008, "auth")
        return
      }
    }
    // 只认自己的包（MP_CC_ALLOWED_BUNDLES）：口令对了也不行，别人的 app 一律断开。本机豁免同口令规则。
    if (!trustedLocal && !bundleAllowed(ALLOWED_BUNDLES, reqUrl.searchParams.get("bundle"))) {
      console.warn(`[hub] bundle rejected from ${remote} (path=${pathname} bundle=${reqUrl.searchParams.get("bundle") ?? "-"})`)
      ws.close(1008, "bundle")
      return
    }

    if (pathname === "/agora") {
      agoraProtocol.attach(ws)
      console.log(`[hub] Agora owner connected from ${remote}`)
    } else if (pathname === "/cc") {
      mpClients.add(ws)
      try { ws.send(helloPayload()) } catch {}   // #046：主机名 / 机型 / 家 / 干活目录 / 工具，排在所有 replay 前
      const probeConnectedAt = Date.now()   // 桥探针：连接时长，对 app 端 Documents/bridge-probe.log
      console.log(`[hub] ${probeTs()} MP connected (total ${mpClients.size}) from ${remote}`)
      // L4 P0b: 这个 handler 是 async 的，让内部 terminal_attach 路径能 await
      // sleep(80ms) 给 CC SIGWINCH 重排时间，capture-pane 拿到的 snapshot 跟
      // 新 pane size 对齐

      // replay 持久缓冲里全部 reply（最近 MAX_REPLY_LOG 条）给新 client，补发断连期间漏的 reply。
      // ⚠️ client 去重保留条数必须 ≥ MAX_REPLY_LOG，否则 replay 到尾部时去重已被剔 → 重复/错位（见 CCBridgeWebSocketClient.replyDedupKeepCount）。
      // 考古结果补投（app 离线期间完成的，重连即达；幂等）
      for (const [, r] of corpusResults) {
        try { ws.send(r.frame) } catch {}
      }
      // since=：app 收到过的最大 ts（已减安全余量）→ 只补那之后的；老 app 不带就全量（plan-hub-instant-connect）
      const since = replaySince(reqUrl.searchParams.get("since"))
      const replies = since === undefined ? recentReplies : recentReplies.filter(r => r.ts > since)
      console.log(`[hub] connect: replay ${replies.length}/${recentReplies.length} since=${since ?? "-"}`)
      if (replies.length > 0) {
        for (const r of replies) {
          try {
            // C2：有 filePath 就重读 base64（文件没了就只发文字）
            const file = r.filePath ? readFileB64(r.filePath) : null
            ws.send(JSON.stringify({
              type: "reply",
              ts: r.ts,
              chat_id: r.chat_id,
              message_id: r.message_id,
              content: r.content,
              reply_id: r.reply_id,
              file,
              mp_msg_id: r.mpMsgId,
              reply_to: r.replyTo,
            }))
            const ageMs = Date.now() - r.ts
            console.log(`[hub] replay → ${remote}: chat_id=${r.chat_id.slice(0,8)} age=${ageMs}ms reply_id=${r.reply_id.slice(0,8)}`)
          } catch (e: any) {
            console.warn(`[hub] replay failed: ${e?.message}`)
          }
        }
        // A4：补发会话内 edits（在 messages 之后，让 app 先有原消息再应用编辑）
        for (const e of recentEdits) {
          if (since !== undefined && e.ts <= since) continue
          try { ws.send(JSON.stringify({ type: "edit", chat_id: e.chat_id, mp_msg_id: e.mp_msg_id, content: e.content })) } catch {}
        }
      }
      // 思考链 replay：在 replies/edits 之后（先有消息节点再挂思考）。app 端按 thinking_id 去重。
      for (const t of recentThinkings) {
        if (since !== undefined && t.ts <= since) continue
        try { ws.send(thinkingFramePayload(t)) } catch {}
      }

      // CR-4 P1：补投未 ack 的 agent 读书产物（app 端 uuid 去重，重复无害）
      for (const p of pendingBookNotes()) {
        try { ws.send(JSON.stringify({ type: "agent_book_note", ...p })) } catch {}
      }

      // #if PERSONAL_APPS
      // 交易 T0.5：补投未 ack 的研报（app 端 uuid 去重，重复无害）
      for (const p of pendingTradingReports()) {
        try { ws.send(JSON.stringify({ type: "trading_report_result", ...p })) } catch {}
      }
      // #endif

      if (transportPolicies.size) { try { ws.send(transportPoliciesFrame()) } catch {} }   // 传输策略以 hub 为准，连上就对齐
      // 问问题 CC 桥：pending 问题重发（先验 TUI 还挂着；死了/无 session 按 declined 收账）
      // 异步验活放后台跑，下面的 ws.on("message") 必须同步挂上，不能等 capture
      void (async () => {
        for (const p of askUserPendingList()) {
          // stream 会话没有 tmux 画面可抓：看 control_request 还挂没挂（09-19 app 重连把 stream 的题判成拒答，
          // 卡片收了但 CC 还在等答案，整条会话卡死）
          const streamAlive = !!p.sessionName && streamRunner.has(p.sessionName) && (
            streamAskPending.get(p.sessionName)?.toolUseId === p.toolUseId || streamPermPending.has(p.toolUseId))
          if (streamAlive || (p.sessionName && !streamRunner.has(p.sessionName) && askUiAlive(await askUserIO.capturePane(p.sessionName), p.questions))) {
            try { ws.send(askUserQuestionFrame(p)) } catch {}
          } else {
            resolveAskUserDeclined(p.toolUseId, "revalidate")
          }
        }
        // resolved 帧补发（收帧瞬间 app 可能离线，Q/A 泡不能丢；app 端 ccMessageId 去重）
        for (const f of askUserResolvedFrames()) {
          try { ws.send(f) } catch {}
        }
      })()

      let wsType: unknown
      ws.on("message", (raw) => timeHandler(() => wsSite("ws", wsType), async () => {
        wsType = undefined
        let msg: any
        try {
          msg = JSON.parse(raw.toString())
        } catch {
          ws.send(JSON.stringify({ type: "error", reason: "invalid_json" }))
          return
        }
        wsType = msg?.type
        const seen = clientInfoByWS.get(ws) ?? { lastSeen: 0 }
        seen.lastSeen = Date.now()
        if (msg.type === "client_info" && typeof msg.platform === "string") {
          const firstHello = seen.platform === undefined
          seen.platform = msg.platform
          // 进度卡 B：app 报到时补一份还在动的 CC 会话现状（断线期间的跳变）
          if (firstHello) for (const f of sessionPhaseSnapshotFrames(laPhaseBySession, sessionCanStop, sessionChatId, n => toolActivityBySession.get(n))) { try { ws.send(f) } catch {} }
          // K1 第 4b 步 · 审查 R1-10：送达状态快照（核对中 / 重发中的一个不漏，failed 带 retryable；断线期间错过的终态靠它补）
          if (firstHello) { try { ws.send(JSON.stringify({ type: "send_status_snapshot", statuses: sendStatusBook.snapshot() })) } catch {} }
          // 底部胶囊「cc-模型名」：已知的补发，没算过的挨个算（算出来走广播）
          if (firstHello) { for (const f of sessionModelSnapshotFrames()) { try { ws.send(f) } catch {} } warmSessionModels() }
        }
        clientInfoByWS.set(ws, seen)

        if (msg.type === "client_info") {
          console.log(`[hub] client_info ← ${msg.platform}`)
        } else if (msg.type === "connect_report") {
          // 秒连账本：每次连上都记，慢的（>1s）贴理由
          const report = parseConnectReport(msg)
          if (report) {
            report.platform = seen.platform
            const reasons = classifyConnect(report, { lags: lagLog.list(), hubStartedAt })
            appendLedger(connectLedgerPath, { at: Date.now(), from: remote, fast: report.totalMs <= FAST_MS, reasons, ...report })
            if (reasons.length) console.warn(`[hub] ${probeTs()} SLOW connect ${report.totalMs}ms ${report.trigger} from ${remote}: ${reasons.join("；")}`)
          }
        } else if (msg.type === "terminal_report") {
          // 终端出字账本（plan §六）：点开终端 → 第一屏画出来，慢的（>1s）贴理由
          const report = parseTerminalReport(msg)
          if (report) {
            report.platform = seen.platform
            const reasons = classifyTerminalOpen(report, { lags: lagLog.list() })
            appendLedger(connectLedgerPath, { at: Date.now(), from: remote, fast: report.totalMs <= FAST_MS, reasons, ...report })
            if (reasons.length) console.warn(`[hub] ${probeTs()} SLOW terminal ${report.totalMs}ms ${report.session} from ${remote}: ${reasons.join("；")}`)
          }
        } else if (msg.type === "send") {
          // L2：per-session 路由。缺省字段 fallback 默认 mp-cc 兼容旧 MP
          const targetSession = typeof msg.session_name === "string" && msg.session_name
            ? msg.session_name
            : TMUX_SESSION
          // K1 第 4b 步：app 对没送达的消息重发（同 message_id + retry:true）。只接受 hub 记为 failed 且 retryable 的；
          // 其余（送达了 / 还在核对 / 没记录 / 会话改走 stream / 正忙）不发，回当前状态，防重复
          let retryAccepted = false
          if (msg.retry === true && typeof msg.message_id === "string") {
            const r = sendStatusBook.acceptRetry(msg.message_id, String(msg.chat_id ?? ""), targetSession, streamRunner.has(targetSession) || transportOf(targetSession) === "stream")
            if (!r.accepted) {
              console.log(`[hub] retry 不接受 ${msg.message_id}（${r.frame.status}）`)
              const frame: SendStatusFrame = { type: "send_status", chat_id: String(msg.chat_id ?? ""), message_id: msg.message_id, session_name: targetSession, ...r.frame }
              ws.send(JSON.stringify(frame))
              return
            }
            sendTracker.armRetry(r.op)
            retryAccepted = true
            console.log(`[hub] retry 接受 ${msg.message_id} → ${targetSession}`)
          }
          try {
            const ts = new Date().toISOString()
            // C2：susu 发来的图/文件先落盘 mp-inbox，channel 带路径让 CC Read/处理
            const imgPaths = Array.isArray(msg.images) && msg.images.length > 0
              ? saveInboundImages(msg.chat_id, msg.images) : []
            const filePaths = Array.isArray(msg.files) && msg.files.length > 0
              ? saveInboundFiles(msg.chat_id, msg.files) : []
            const userReplyTo = typeof (msg as any).reply_to === "string" ? (msg as any).reply_to : undefined
            const tag = buildChannelTag(msg as MPMessage, ts, [...imgPaths, ...filePaths], userReplyTo, replyViaTextFor(targetSession))
            // 这是这个 message_id 的第几次发送（重新生成 / 重发）：更早那次还没出的结果不再发给 app
            if (typeof msg.message_id === "string") sendStatusBook.attemptStarted(msg.message_id, ts, retryAccepted)
            // 思考强度（effort.ts）：记下想要的档位；会话跑着且档位不同 → claude 先发 /effort，codex 用同一 id 重启
            const restarting = sendWithEffort(targetSession, tag, msg.chat_id, (msg as any).effort)
            if (restarting) await restarting
            recordUserActivity(targetSession, msg.chat_id)   // nudge：记 susu 活跃，重置静默计时
            streamLastInbound.set(targetSession, { chatId: msg.chat_id, messageId: msg.message_id })
            onLaPhaseEvent(targetSession, { kind: "send" })   // M4a：新一轮 → working（新 run_id / since_unix）
            console.log(`[hub] send → tmux:${targetSession} chat_id=${msg.chat_id?.slice(0, 8)} ${msg.content?.slice(0, 50)}`)
            ws.send(JSON.stringify({ type: "ack", message_id: msg.message_id }))
          } catch (err: any) {
            if (retryAccepted) sendTracker.abortRetry(msg.message_id, `重发没发出去：${err.message}`)   // 被接受的重发每条出口都写回终态（审查 R1-8）
            ws.send(JSON.stringify({
              type: "error",
              message_id: msg.message_id,
              reason: `tmux: ${err.message}`,
            }))
          }
        } else if (msg.type === "spawn_cc") {
          const sessionName = typeof msg.session_name === "string" ? msg.session_name : ""
          // 校验：只允许 alphanum + _-. ，长度 1-32
          if (!/^[A-Za-z0-9_.-]{1,32}$/.test(sessionName)) {
            ws.send(JSON.stringify({ type: "spawn_cc_err", session_name: sessionName, reason: "invalid_name" }))
            return
          }
          if (tmux.hasSession(sessionName)) {
            ws.send(JSON.stringify({ type: "spawn_cc_err", session_name: sessionName, reason: "session_exists" }))
            return
          }
          const transport = msg.transport === "stream" || msg.transport === "tmux" ? msg.transport : undefined
          const engine = sessionEngine(sessionName)
          // stream 传输不起 tmux（判法同 spawnSession），缺 tmux 不该拦它
          const wantStream = engine === "claude" && (transport ?? transportOf(sessionName)) === "stream"
          const missing = missingToolReason(engine, !wantStream)
          if (missing) {
            ws.send(JSON.stringify({ type: "spawn_cc_err", session_name: sessionName, reason: missing }))
            return
          }
          try {
            await spawnSession(sessionName, undefined, false, transport)   // spawn + 安排 boot 完就绪（与 send 自动 spawn 同一套）
            ws.send(JSON.stringify({ type: "spawn_cc_ok", session_name: sessionName }))
          } catch (err: any) {
            ws.send(JSON.stringify({
              type: "spawn_cc_err",
              session_name: sessionName,
              reason: err?.message ?? "spawn failed",
            }))
          }
        } else if (msg.type === "list_sessions") {
          // 只返回 mp-cc 前缀的 session（避免暴露用户其它 tmux 工作）
          // ⚠️ 这条给 CC 会话选择器用，**故意不含全局窗口** —— 那是给对话绑 CC 的选择器，
          // shell 窗口混进去没意义。全局窗口走下面的 list_windows。
          const sessions = listSessions()
          ws.send(JSON.stringify({ type: "list_sessions_result", sessions, stream_sessions: streamRunner.list() }))

        // ── 全局终端窗口（跟对话无关）──
        } else if (msg.type === "list_windows") {
          const includeClosed = msg.include_closed === true
          ws.send(JSON.stringify({
            type: "list_windows_result",
            windows: windowListPayload(includeClosed),
          }))

        // ── #046 T3：[+] 窗口的干活目录（手机「我的电脑」页 / Mac 页）──
        } else if (msg.type === "get_hub_config") {
          ws.send(hubConfigPayload(requestId(msg)))
        } else if (msg.type === "set_agent_workdir") {
          const raw = typeof msg.path === "string" ? msg.path : ""
          let next: HubConfig
          if (raw.trim() === "") {
            const { agent_workdir: _cleared, ...rest } = hubConfig
            next = rest
          } else {
            const checked = validateWorkdir(raw, homedir())
            if (!checked.ok) {
              ws.send(JSON.stringify({ type: "hub_config_error", reason: checked.reason, ...requestIdField(msg) }))
              return
            }
            next = { ...hubConfig, agent_workdir: checked.path }
          }
          try {
            saveHubConfig(hubConfigPath, next)
          } catch (e: any) {
            console.warn(`[hub] hub-config save fail: ${e?.message}`)
            ws.send(JSON.stringify({ type: "hub_config_error", reason: "配置写不进去", ...requestIdField(msg) }))
            return
          }
          hubConfig = next
          console.log(`[hub] agent workdir → ${next.agent_workdir ?? "(家)"}`)
          ws.send(hubConfigPayload(requestId(msg)))
          broadcastHello()
        } else if (msg.type === "list_dirs") {
          const listing = listDirs(typeof msg.path === "string" ? msg.path : undefined, homedir())
          ws.send(JSON.stringify({ type: "dir_list", ...listing, ...requestIdField(msg) }))
        } else if (msg.type === "open_window") {
          const engine: TerminalEngine = msg.engine === "claude" || msg.engine === "codex"
            ? msg.engine
            : "shell"
          // 起不来就回 ok:false + 原因、不带 code（老 App 按「hub 没给 code」走失败分支），注册表不留这条（#046 审计 H：
          // 以前没装 tmux 时这里抛出 → unhandledRejection → hub 整个退出）
          const code = newWindowCode([...terminalWindows.map(w => w.code), ...openingWindowCodes])
          openingWindowCodes.add(code)
          const failure = missingToolReason(engine) ?? await spawnTerminalWindowSafely(code, engine)
          openingWindowCodes.delete(code)
          if (failure) {
            console.warn(`[hub] window open failed engine=${engine}: ${failure}`)
            ws.send(JSON.stringify({ type: "window_opened", ok: false, reason: failure }))
            return
          }
          terminalWindows = addWindow(terminalWindows, code, new Date().toISOString(), engine)
          persistTerminalWindows()
          console.log(`[hub] window opened ${code} engine=${engine} (${openWindows(terminalWindows).length} open)`)
          ws.send(JSON.stringify({
            type: "window_opened",
            ok: true,
            code,
            session_name: sessionNameFor(code),
          }))
        } else if (msg.type === "rename_window") {
          const requestedCode = typeof msg.code === "string" ? msg.code : ""
          const title = typeof msg.title === "string" ? msg.title : ""
          const globalCode = codeFromSession(requestedCode) ?? requestedCode
          if (terminalWindows.some(window => window.code === globalCode)) {
            terminalWindows = setWindowCustomTitle(terminalWindows, globalCode, title)
            persistTerminalWindows()
          } else {
            const binding = sessionMap.get(requestedCode)
            if (!binding) return
            const customTitle = resolveTerminalTitle(title, undefined, "shell") ?? undefined
            if (customTitle) conversationCustomTitles.set(requestedCode, customTitle)
            else conversationCustomTitles.delete(requestedCode)
            saveConversationTitles()
          }
          broadcastTerminalState()
        } else if (msg.type === "close_window") {
          // 关 = 只打 closedAt 标记。**tmux session 不动** —— 里面跑的东西不能死，
          // 长按 [+] 的菜单还能把它恢复回来（粟粟明确要求）。
          const code = typeof msg.code === "string" ? msg.code : ""
          if (code) {
            terminalWindows = markWindowClosed(terminalWindows, code, new Date().toISOString())
            persistTerminalWindows()
            console.log(`[hub] window closed ${code} (tmux 保留)`)
          }
          ws.send(JSON.stringify({ type: "window_closed", code }))
        } else if (msg.type === "restore_window") {
          const code = typeof msg.code === "string" ? msg.code : ""
          const window = code ? terminalWindows.find(item => item.code === code && !item.endedAt) : undefined
          let reason: string | null = window ? null : "这个窗口已经结束了"
          if (window) {
            // tmux session 可能在关闭期间被外部杀了（重启 Mac 等）→ 补起一个（开在当时的干活目录）；起不来就别标恢复
            const engine: TerminalEngine = window.engine === "claude" || window.engine === "codex" ? window.engine : "shell"
            if (!tmux.hasSession(sessionNameFor(code))) reason = missingToolReason(engine) ?? await spawnTerminalWindowSafely(code, engine)
          }
          if (!reason) {
            terminalWindows = restoreWindow(terminalWindows, code)
            persistTerminalWindows()
            console.log(`[hub] window restored ${code}`)
          } else if (window) {
            console.warn(`[hub] window restore failed ${code}: ${reason}`)
          }
          ws.send(JSON.stringify({
            type: "window_restored",
            code,
            session_name: sessionNameFor(code),
            ok: !reason,
            ...(reason ? { reason } : {}),
          }))
        } else if (msg.type === "end_window") {
          // 结束 = 真 kill tmux（跟 close 的「只收起」相反），注册表标 ended，之后哪个列表都不再有它。
          const requestedCode = typeof msg.code === "string" ? msg.code : ""
          const code = codeFromSession(requestedCode) ?? requestedCode
          const now = new Date().toISOString()
          const ended = await endWindowAfterKill(terminalWindows, code, tmux)
          if (ended) {
            terminalWindows = endWindow(terminalWindows, code, now)
            persistTerminalWindows()
            broadcastTerminalState()
            console.log(`[hub] window ended ${code} (tmux killed)`)
          } else if (code) {
            console.warn(`[hub] window end failed ${code}`)
          }
          ws.send(JSON.stringify({ type: "window_ended", code, ok: ended }))
        } else if (msg.type === "terminal_seen") {
          // T21：App 真把这个窗口显示在前台了 = 「跑完了」已读，绿点只留给没看过的（attach 本身不算，重连重订阅也会 attach）
          const sessionName = typeof msg.session_name === "string" ? msg.session_name : ""
          if (sessionName && laPhaseBySession.get(sessionName)?.phase === "done") onLaPhaseEvent(sessionName, { kind: "seen" })
        } else if (msg.type === "feedback") {
          // MP 三指双击反馈回传（plan-shake-feedback 方案B）：iOS 端反馈落盘 Mac 的
          // 统一收件箱（和 macOS 端 FeedbackStore 同一目录），小克直接读。
          try {
            const dir = join(homedir(), "Library", "Application Support", "MemoryPalace", "feedback")
            mkdirSync(dir, { recursive: true })
            // stem 消毒：只留安全字符，防路径注入；空则用时间戳
            const rawStem = typeof msg.stem === "string" ? msg.stem : ""
            const stem = rawStem.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 40)
              || new Date().toISOString().replace(/[:.]/g, "-")
            if (typeof msg.md === "string" && msg.md.length > 0) {
              writeFileSync(join(dir, `${stem}.md`), msg.md)
            }
            if (typeof msg.image_b64 === "string" && msg.image_b64.length > 0) {
              writeFileSync(join(dir, `${stem}.jpg`), Buffer.from(msg.image_b64, "base64"))
            }
            // 相册补图（stem-2.jpg 起，与 iOS FeedbackStore 命名一致）；上限防滥发
            if (Array.isArray(msg.extra_images_b64)) {
              msg.extra_images_b64.slice(0, 12).forEach((b64: unknown, i: number) => {
                if (typeof b64 === "string" && b64.length > 0) {
                  writeFileSync(join(dir, `${stem}-${i + 2}.jpg`), Buffer.from(b64, "base64"))
                }
              })
            }
            console.log(`[hub] feedback saved: ${stem}`)
            ws.send(JSON.stringify({ type: "feedback_ack", stem }))
          } catch (err: any) {
            ws.send(JSON.stringify({ type: "feedback_err", reason: err?.message ?? "save failed" }))
          }
        } else if (msg.type === "terminal_attach") {
          // L4: 订阅某 session 的 tmux pane 流（pipe-pane stream + 当前 snapshot）
          const sessionName = typeof msg.session_name === "string" && msg.session_name
            ? msg.session_name
            : TMUX_SESSION
          if (streamRunner.has(sessionName)) {
            ws.send(JSON.stringify({ type: "terminal_error", session_name: sessionName, reason: "stream_session" }))
            return
          }
          if (!tmux.hasSession(sessionName)) {
            ws.send(JSON.stringify({
              type: "terminal_error",
              session_name: sessionName,
              reason: "session_not_found",
            }))
            return
          }
          // 终端出字账本（plan §六）：分步计时随 terminal_init 带回 app
          const attachStart = performance.now()
          let stepAt = attachStart
          const steps: string[] = []
          const step = (name: string) => { const now = performance.now(); steps.push(`${name}=${Math.round(now - stepAt)}`); stepAt = now }
          // 中途有 detach / 再次 attach / 断开 → 这次作废（读 tmux 改成了异步，期间会插进别的帧）
          const seq = bumpTerminalAttachSeq(ws, sessionName)
          const stale = () => ws.readyState !== ws.OPEN || terminalAttachSeq.get(ws)?.get(sessionName) !== seq
          // 🟡 关键：先 resize 让 tmux pane 跟 MP viewport 匹配，再 capture snapshot
          // 否则 snapshot 的 cursor 用 80x24 坐标，iPhone 小 viewport 渲染就溢出叠字符
          const cols = Number(msg.cols) || 0
          const rows = Number(msg.rows) || 0
          if (cols >= 10 && cols <= 500 && rows >= 5 && rows <= 200) {
            try {
              // 只在 pane 尺寸真要变时才 resize + 等 CC 重绘（已是目标尺寸则 capture 本就正确，
              // 跳过避免无谓延迟）。首次 attach 常把 window 从旧宽度(如 80)缩到 iPhone 的 52，
              // CC 这种复杂 TUI SIGWINCH 后全屏重绘 > 80ms；旧的 80ms 太短 → capture 抓到没绘完
              // 的旧宽度画面 → 横向错位「第一次诡异」。idle CC 不自发重绘，错位会挂到下次 resize。
              // 改：变化时等 250ms 让 CC 绘完再 capture。
              // T51：目标 = 正在看的前台设备里最小的（只有这一台时就是它自己）
              terminalSizes.set(sessionName, ws, { cols, rows })
              const othersWatching = [...(terminalAttachments.get(sessionName)?.mpClients ?? [])].some(c => c !== ws)
              const resized = await syncTerminalSize(sessionName)   // 看的都在后台（含它自己）：不动窗口
              step("size")
              if (stale()) return
              if (resized) {
                await sleep(250)
                step("resize")
                if (stale()) return
                if (othersWatching) scheduleTerminalReissue(sessionName)   // 别的设备上的画面也按新尺寸对齐
              }
            } catch (err: any) {
              console.warn(`[hub] resize on attach failed: ${err.message}`)
            }
          }
          // 开流是异步的：等的这段时间这套可能被别人关掉（同一套的另一个等待者 detach 了），那就再开一次
          let att: TerminalAttachment | undefined
          for (let tries = 0; !att && tries < 2; tries++) {
            let opened: TerminalAttachment
            try {
              opened = await openTerminalAttachment(sessionName)
            } catch (err: any) {
              ws.send(JSON.stringify({
                type: "terminal_error",
                session_name: sessionName,
                reason: `attach failed: ${err.message}`,
              }))
              return
            }
            if (stale()) {
              // 开流期间 detach / 断开了（那时它还没进表，detach 摘不到）：没人看就关掉
              if (!terminalWatched(opened) && terminalAttachments.get(sessionName) === opened) void closeTerminalAttachment(sessionName)
              return
            }
            if (terminalAttachments.get(sessionName) === opened) att = opened
          }
          if (!att) {
            ws.send(JSON.stringify({ type: "terminal_error", session_name: sessionName, reason: "attach failed: stream closed" }))
            return
          }
          const joined = att
          joined.joining.add(ws)
          step("pipe")
          // 给这个 client 发当前 snapshot（带 ANSI escape + CRLF 归一 + 光标复位，见 formatSnapshot 注释）。
          // #087：快照在流里的位置发、发完才进观众：快照之前的增量它一个不收（都在快照里），之后的一个不漏
          try {
            await captureAtBoundary(joined, (snapshot, mouseAny) => {
              joined.joining.delete(ws)
              if (stale()) return
              joined.mpClients.add(ws)
              step("capture")
              const hubMs = Math.round(performance.now() - attachStart)
              ws.send(buildTerminalInitPayload(sessionName, snapshot, mouseAny, { ms: hubMs, steps: steps.join(" ") }))
              console.log(`[hub] terminal_attach ${sessionName} ${cols}x${rows} (clients=${joined.mpClients.size}) ${hubMs}ms [${steps.join(" ")}]`)
            })
            if (stale()) return
            // 立刻推一帧用量，不然顶卡要等到下一个 30s 心跳才从 `--` 变成数字
            sendTerminalUsage(sessionName, [ws])
            sendTerminalState([ws])
          } catch (err: any) {
            joined.joining.delete(ws)
            if (!terminalWatched(joined) && terminalAttachments.get(sessionName) === joined) void closeTerminalAttachment(sessionName)
            if (stale()) return
            ws.send(JSON.stringify({
              type: "terminal_error",
              session_name: sessionName,
              reason: `capture failed: ${err.message}`,
            }))
          }
        } else if (msg.type === "terminal_detach") {
          const sessionName = typeof msg.session_name === "string" ? msg.session_name : ""
          bumpTerminalAttachSeq(ws, sessionName)   // 在途的 attach 作废
          const att = terminalAttachments.get(sessionName)
          if (att) {
            att.mpClients.delete(ws)
            att.joining.delete(ws)
            if (!terminalWatched(att)) {
              void closeTerminalAttachment(sessionName)
              console.log(`[hub] terminal stream closed: ${sessionName}`)
            }
          }
          terminalSizes.remove(sessionName, ws)
          void applyEffectiveSize(sessionName)   // T51：剩下的设备恢复自己的尺寸
        } else if (msg.type === "terminal_active") {
          // T51：App 退后台 false / 回前台 true；后台的设备不参与定尺寸
          for (const sessionName of terminalSizes.setActive(ws, msg.active !== false)) void applyEffectiveSize(sessionName)
        } else if (msg.type === "terminal_input") {
          // MP keystroke bytes → tmux send-keys -H hex 序列
          // 支持任意 ANSI escape（如 ↑ = ESC [ A = 0x1b 0x5b 0x41）
          const sessionName = typeof msg.session_name === "string" && msg.session_name
            ? msg.session_name
            : TMUX_SESSION
          const bytesB64 = typeof msg.bytes === "string" ? msg.bytes : ""
          if (!tmux.hasSession(sessionName) || !bytesB64) return
          const bytes = Buffer.from(bytesB64, "base64")
          if (bytes.length === 0) return
          if (bytes.length > 4096) {
            // 新客户端已按 4096 分片（#053 T26），撞到这条 = 老客户端；至少留个痕
            console.warn(`[hub] terminal_input dropped: ${bytes.length} bytes > 4096 (${sessionName})`)
            return
          }
          try {
            await sendTerminalBytes(sessionName, bytes)
          } catch (err: any) {
            ws.send(JSON.stringify({
              type: "terminal_error",
              session_name: sessionName,
              reason: `send-keys: ${err.message}`,
            }))
          }
        } else if (msg.type === "terminal_paste") {
          // 粘贴走 tmux paste-buffer -p：pane 开了 bracketed paste 才包 ESC[200~（#053 T27），
          // 走 stdin 没有 4096 的线（T26）。回 terminal_paste_result，客户端据此决定清不清草稿。
          // 不回 terminal_error：客户端把那个当 OFFLINE。
          const sessionName = typeof msg.session_name === "string" && msg.session_name
            ? msg.session_name
            : TMUX_SESSION
          const requestId = typeof msg.request_id === "string" ? msg.request_id : undefined
          const text = typeof msg.text === "string" ? msg.text : ""
          const result: PasteResult = tmux.hasSession(sessionName)
            ? await tmux.paste(sessionName, text)
            : { ok: false, reason: "终端会话不存在" }
          ws.send(buildPasteResultPayload(sessionName, requestId, result))
        } else if (msg.type === "terminal_resize") {
          const sessionName = typeof msg.session_name === "string" && msg.session_name
            ? msg.session_name
            : TMUX_SESSION
          const cols = Number(msg.cols) || 80
          const rows = Number(msg.rows) || 24
          if (cols < 10 || cols > 500 || rows < 5 || rows > 200) return
          if (streamRunner.has(sessionName)) return   // 无终端会话没有 pane（此前打到 tmux 报 can't find window）
          if (!tmux.hasSession(sessionName)) return
          // T51：只认还在看这个窗口的设备（detach 之后迟到的 resize 不能把它重新算进来压窄别人）
          if (!terminalSizes.has(sessionName, ws)) return
          terminalSizes.set(sessionName, ws, { cols, rows })
          try {
            // 看的都在后台：不动窗口。真改了才记一行（#087：键盘起落会不会改行数，看这行就知道）
            if (await syncTerminalSize(sessionName)) console.log(`[hub] terminal_resize ${sessionName} → ${cols}x${rows}`)
          } catch (err: any) {
            console.warn(`[hub] resize-window failed for ${sessionName}: ${err.message}`)
          }
          // 07-09 恢复 resize 后快照愈合（粟粟报「字/光标经常飘到输入框外」）：
          // 键盘弹起等 viewport 变化窗口期，SwiftTerm 已按新尺寸 reflow 而 CC 输出
          // 还是旧尺寸坐标（或反向）——错位内容 CC 增量重绘不补，必须重发快照对齐。
          // 06-02 砍 reissue 的根因（client 端 ESC c 复位不彻底 → 快照层层叠加）已在
          // client 侧拆除（terminal_init 改 resetToInitialState API 完整复位），重发安全。
          // debounce 400ms：连发 resize 只在末次后重发一次，同时给 CC SIGWINCH 重绘
          // 留时间（attach 路径实测 250ms 内绘完）。
          scheduleTerminalReissue(sessionName)
        } else if (msg.type === "command") {
          // L3：斜杠命令 raw 直发，不包 channel tag —— CC 看到裸 /clear 触发命令系统
          const content = typeof msg.content === "string" ? msg.content : ""
          if (!content.startsWith("/")) {
            ws.send(JSON.stringify({ type: "error", reason: "command must start with /" }))
            return
          }
          const targetSession = typeof msg.session_name === "string" && msg.session_name
            ? msg.session_name
            : TMUX_SESSION
          if (!tmux.hasSession(targetSession)) {
            ws.send(JSON.stringify({
              type: "error",
              reason: `session_not_found: ${targetSession}`,
            }))
            return
          }
          const sent = await sendSlashCommand(targetSession, content)
          ws.send(JSON.stringify(sent.ok ? { type: "command_ack", content } : { type: "error", reason: sent.reason }))
        } else if (msg.type === "register_call_client") {
          try {
            voiceCalls.register(msg)
            callInstallByWS.set(ws, msg.install_id)
            ws.send(JSON.stringify({ type: "voice_call_snapshot", calls: voiceCalls.forDevice(msg.install_id) }))
          } catch (e: any) { ws.send(JSON.stringify({ type: "voice_call_error", reason: e.message })) }
        } else if (msg.type === "voice_call_action") {
          try {
            const install_id = callInstallByWS.get(ws)
            if (!install_id || !["accept", "decline", "hangup", "fail"].includes(msg.action)) throw new Error("call client not registered")
            broadcastCall(voiceCalls.transition(msg.call_id, msg.action, { install_id }))
          } catch (e: any) { ws.send(JSON.stringify({ type: "voice_call_error", call_id: msg.call_id, reason: e.message })) }
        } else if (msg.type === "register_push_token") {
          // app 注册 APNs device token（hub 在「无人在看」时推主动消息/nudge）。
          if (typeof msg.token === "string" && msg.token.length > 0) {
            const isNew = !pushTokens.has(msg.token)
            const info = normalizePushInfo(msg)
            pushTokens.set(msg.token, info)
            savePushTokens()
            console.log(`[hub] push token registered (total ${pushTokens.size}, new=${isNew}) …${msg.token.slice(-8)} env=${info.env} topic=${info.topic ?? "-"} preview=${info.preview}`)
          }
        } else if (msg.type === "register_la_token") {
          // app 注册 Live Activity 的 update / push-to-start token（D6）。
          // 跟 register_push_token 是两条独立的链，别互相借值。
          const res = registerLaToken(laTokens, msg)
          if (res.ok) {
            saveLaTokens(laTokensPath, laTokens)
            const who = msg.kind === "start"
              ? `install=${msg.install_id}`
              : `activity=${msg.activity_id} session=${msg.session_name}`
            console.log(`[hub] la token ${msg.kind} ← ${who} env=${msg.env} topic=${normalizeTopic(msg.topic) ?? "-"} preview=${msg.preview === "full" ? "full" : "hidden"} token=${tokenTail(msg.token)} replaced=${tokenTail(res.replaced)}`)
          } else {
            // 必须回帧：不回的话 app 的 didOpen 全量补报会静默死循环。
            const nak: Record<string, unknown> = { type: "la_token_nak", kind: msg.kind, reason: res.reason }
            if (typeof msg.activity_id === "string") nak.activity_id = msg.activity_id
            if (typeof msg.install_id === "string") nak.install_id = msg.install_id
            ws.send(JSON.stringify(nak))
            console.warn(`[hub] la token rejected: ${res.reason}`)
          }
        } else if (msg.type === "unregister_la_token") {
          if (unregisterLaToken(laTokens, msg).ok) {
            saveLaTokens(laTokensPath, laTokens)
            console.log(`[hub] la token unregister ${msg.kind} ← ${msg.kind === "start" ? `install=${msg.install_id}` : `activity=${msg.activity_id}`}`)
          }
        } else if (msg.type === "la_query") {
          // M4b2 ③：app 冷启动对账。iPhone 上 app 被杀是**正常工作模式**（数据源在 Mac 的 hub），
          // 所以冷启动发现的岛不能无条件 end —— 先问 hub「那一轮还活着吗」。
          // 活 = LA store 里有该 update 记录，就活。phase 表缺这个 session 时按 idle 报
          // —— 08-30 真机 checkpoint 实撞：原来还要求「session 在 phase 表里」，而 phase 表
          // 只在 app send/askuser/reply 事件时才有条目，DEBUG 起的岛 + hub 重启后的岛都没有
          // → hub 误报死亡 → app 把粟粟刚起的岛 end 掉了。token 记录本身就是「hub 认识它」的证据。
          // 没连上 / 不回帧的分支由 app 侧兜（保留，不猜），hub 这边只负责有问必答。
          const ids: string[] = (Array.isArray(msg.activity_ids) ? msg.activity_ids : [])
            .filter((v: unknown): v is string => typeof v === "string" && v.length > 0)
            .slice(0, 32)
          const alive: Record<string, { phase: string; run_id?: string; session_name: string } | null> = {}
          for (const id of ids) {
            const record = laTokens.update[id]
            const snap = record ? laPhaseBySession.get(record.session_name) : undefined
            alive[id] = record
              ? { phase: snap?.phase ?? "idle", ...(snap?.run_id ? { run_id: snap.run_id } : {}), session_name: record.session_name }
              : null
          }
          try { ws.send(JSON.stringify({ type: "la_query_result", alive })) } catch {}
          console.log(`[hub] la query ← ${ids.length} ids → alive=${Object.values(alive).filter((v) => v !== null).length}`)
        } else if (msg.type === "focus") {
          // app 上报「当前在看哪个会话」。空串/非串 = 没在看（后台/列表页/终端页）。
          const c = (typeof msg.chat_id === "string" && msg.chat_id.length > 0) ? msg.chat_id : null
          focusByClient.set(ws, c)
          console.log(`[hub] focus ← ${c ? c.slice(0, 8) : "none"}`)
        } else if (msg.type === "cc_memory_manifest_req") {
          // 只回清单（名字 + 哈希 + 大小）；排除规则在 buildSnapshot 里，被排除的不进清单。同一目录的构建合并、全进程读盘 ≤8（ccMemorySnapshots）。
          // 读盘异步（原来同步逐个读，10-11 现场一次卡主循环 2.4s）；同一连接的清单 / 取文件回包按请求顺序发（审查 R1-3）
          void memoryRepliesFor(ws).push(() => ccMemorySnapshots.fresh().then(
            (snap) => [JSON.stringify({ type: "cc_memory_manifest", ok: true, files: ccMemoryManifest(snap) })],
            (e) => [JSON.stringify({ type: "cc_memory_manifest", ok: false, reason: (e as Error)?.message ?? "read failed", files: [] })],
          ))
        } else if (msg.type === "cc_memory_fetch") {
          // 按名字分批取（每次 ≤20 个、每帧 ≤256KB）；只认快照里有的名字。读盘异步，读失败与原来一样不回帧（只记一行）
          const names = msg.names
          void memoryRepliesFor(ws).push(() => ccMemorySnapshots.recent().then(
            (snap) => fetchFrames(snap, names),
            (e) => { console.warn(`[hub] cc_memory_fetch 读失败：${(e as Error)?.message ?? e}`); return [] },
          ))
        } else if (msg.type === "vocab_archeology") {
          // R3-3 考古按钮（fire-and-forget，结果广播回投）
          if (typeof msg.word === "string" && msg.word.trim() && msg.word.length <= 64) {
            void runVocabArcheology(msg.word.trim().toLowerCase())
          }
        } else if (msg.type === "pocket_result" || msg.type === "twitter_result") {
          const pid = typeof msg.id === "string" ? msg.id : ""
          const p = pocketPending.get(pid)
          if (p) p.resolve({ id: msg.id, ok: msg.ok, result: msg.result, error: msg.error })
        } else if (msg.type === "reading_status") {
          // CR-2 阅读在场信号：app 60s tick 上报快照 → 落 agent/reading-status.json
          // （AUTONOMY 触发时机的输入面；消费在 CR-4）。原样落盘，只做形状校验。
          if (msg.status && typeof msg.status === "object") {
            writeReadingStatus(msg.status as Record<string, unknown>)
          }
        } else if (msg.type === "vocab_status") {
          // L2 单词在场信号：开关 coRead.vocab（缺省关），关 = 静默丢弃（best-effort 信号）
          if (msg.status && typeof msg.status === "object" && loadAgentConfig().coRead.vocab === true) {
            writeVocabStatus(msg.status as Record<string, unknown>)
          }
        } else if (msg.type === "voice_note") {
          // 发语音条：生成成功的语音条记进 cc-rp（小克能翻到"自己说过的话"）
          if (msg.note && typeof msg.note === "object") {
            appendVoiceNote(msg.note as Record<string, unknown>)
          }
        } else if (msg.type === "set_voice_instructions") {
          // 楼层语音设置 → CLAUDE.md 标记块（app 发送前/设置改动时按内容去重同步）
          const r = writeVoiceInstructions(msg.content)
          try { ws.send(JSON.stringify({ type: "voice_instructions_result", ...r })) } catch {}
          // #if PERSONAL_APPS
        } else if (msg.type === "warroom_board") {
          // M3：iOS 军机处看板拉取（快照式——最近奏折 + 普查统计）
          try { ws.send(JSON.stringify({ type: "warroom_board_result", ...warroomBoardSnapshot() })) } catch {}
        } else if (msg.type === "warroom_request") {
          // M5：粟粟在 app 看板上一句话派单 → 存档原文 → 注入中枢拆 EPIC
          const text = typeof msg.text === "string" ? msg.text.trim() : ""
          if (!text || !warroomLedger) {
            try { ws.send(JSON.stringify({ type: "warroom_request_result", ok: false, error: !text ? "empty" : "not ready" })) } catch {}
          } else {
            // K2 审查 R1-1：撞锁异步重试；最终失败回 WS 错误（原来同步抛 → 这个 async 回调 reject → unhandledRejection → hub 退出）
            const ledger = warroomLedger
            void retryBusy(() => ledger.createRequest(text.slice(0, 4000))).then((req) => {
              const desk = process.env.MP_WARROOM_DESK ?? "mp-cc-2521523d"
              const tag = `<channel source="warroom-request" request_id="${req.request_id}">【御笔亲批的新需求 ${req.request_id}】${text.replace(/\n/g, " ")} —— 中枢流程：拆粗颗粒 roadmap → warroom_dispatch 子奏折（epic 一律填 "${req.request_id}"，能并行的并行、有先后的用 depends_on 串；工单正文里要求执行者按 research→plan→执行→review 循环干活）→ 全部终态后 hub 会叫你终审。先用 bridge 回粟粟你拆出的 roadmap。</channel>`
              void ensureSessionAndSendAsync(desk, tag).catch((e: any) => console.warn(`[warroom] request inject fail: ${e?.message}`))
              try { ws.send(JSON.stringify({ type: "warroom_request_result", ok: true, request_id: req.request_id })) } catch {}
              console.log(`[warroom] request ${req.request_id} → desk (${text.slice(0, 60)})`)
            }).catch((e: any) => {
              console.warn(`[warroom] request 存档失败：${e?.message}`)
              try { ws.send(JSON.stringify({ type: "warroom_request_result", ok: false, error: String(e?.message ?? e) })) } catch {}
            })
          }
        } else if (PM_FRAMES.has(msg.type)) {
          // 手机「开发」子应用：只转发给本机 session 看板服务 4793（pm-relay.ts，异步 + 超时，不阻塞消息循环）
          void pmRelay(msg).then((r) => { try { ws.send(JSON.stringify(r)) } catch {} })
          // #endif
        } else if (msg.type === "agent_status") {
          // R5：iOS 拉 agent 状态（config/用量/活动）
          try { ws.send(JSON.stringify({ type: "agent_status_result", ...agentStatusSnapshot() })) } catch {}
        } else if (msg.type === "agent_config_set") {
          // R5：iOS 写 agent 配置（读-改-写保未知键），回最新快照
          if (msg.patch && typeof msg.patch === "object") {
            applyAgentConfigPatch(msg.patch as Record<string, unknown>)
            try { ws.send(JSON.stringify({ type: "agent_status_result", ...agentStatusSnapshot() })) } catch {}
          }
        } else if (msg.type === "ask_user_answer") {
          // 问问题 CC 桥：app 答案 → TUI 键序驱动（per-session 串行链；快照校验失败不盲发键）。
          // 答完的权威收账走 PostToolUse hook；skip=Esc 无 hook，驱动成功后立即 declined 收账。
          const toolUseId = typeof msg.tool_use_id === "string" ? msg.tool_use_id : ""
          const p = toolUseId ? askUserPending(toolUseId) : undefined
          if (!p) {
            try { ws.send(JSON.stringify({ type: "ask_user_stale", tool_use_id: toolUseId })) } catch {}
            return
          }
          const skip = msg.skip === true
          const answers: AskAnswer[] | null = Array.isArray(msg.answers) ? msg.answers : null
          if (streamAnswer(p, toolUseId, answers, skip)) return   // stream 会话：control_response 已回
          chainSessionSend(p.sessionName ?? "", async () => {
            const r = await askUserDrive(p, answers, skip, askUserIO)
            if (r.ok) {
              if (skip) {
                resolveAskUserDeclined(toolUseId, "app_skip")
              } else if (answers) {
                askUserMarkDriven(toolUseId, askUserFormatAnswers(p.questions, answers))
              }
              console.log(`[hub] askuser drive ok tool_use=${toolUseId.slice(0, 12)} skip=${skip}`)
            } else {
              console.warn(`[hub] askuser drive fail (${r.reason}) tool_use=${toolUseId.slice(0, 12)}`)
              try { ws.send(JSON.stringify({ type: "ask_user_stale", tool_use_id: toolUseId, reason: r.reason })) } catch {}
            }
          })
        } else if (msg.type === "agent_book_note_ack") {
          // CR-4 P1：app 处理成功回执 → 删 pending（投递闭环）
          if (typeof msg.uuid === "string") {
            ackBookNote(msg.uuid)
            console.log(`[hub] book_note ack ← ${msg.uuid.slice(0, 8)}`)
          }
          // #if PERSONAL_APPS
        } else if (msg.type === "ticker_research") {
          // 交易 T0.5：档案页「跑研究」→ headless axismundi（mode: full=按钮全量 / auto=夜跑增量优先）
          if (typeof msg.symbol === "string" && /^[A-Z]{1,5}$/.test(msg.symbol)) {
            const mode = typeof msg.mode === "string" ? msg.mode : "full"
            void runTickerResearch(msg.symbol, typeof msg.request_id === "string" ? msg.request_id : "", mode)
          }
        } else if (msg.type === "trading_report_ack") {
          if (typeof msg.uuid === "string") {
            ackTradingReport(msg.uuid)
            console.log(`[hub] trading_report ack ← ${msg.uuid.slice(0, 8)}`)
          }
        } else if (msg.type === "trading_watchlist") {
          // 交易夜跑：app 关注列表 + 夜跑参数全量上报 → 落盘给 trading-daily 读
          saveWatchlist(msg.symbols, msg.nightly ?? null)
          // #endif
        } else if (msg.type === "reading_context") {
          // CR-4 P1：她读到哪，章文本缓存到哪（ReaderDaemon 的阅读材料）
          if (typeof msg.safeName === "string" && typeof msg.text === "string" && Number.isFinite(msg.chapter)) {
            const ok = writeReadingContext({
              floorId: typeof msg.floorId === "string" ? msg.floorId : "",
              userName: typeof msg.userName === "string" ? msg.userName.slice(0, 100) : "",
              safeName: msg.safeName,
              bookName: typeof msg.bookName === "string" ? msg.bookName : msg.safeName,
              chapter: msg.chapter,
              totalChapters: Number.isFinite(msg.totalChapters) ? msg.totalChapters : 0,
              chapterTitle: typeof msg.chapterTitle === "string" ? msg.chapterTitle : "",
              text: String(msg.text).slice(0, 200_000),
              userNotes: Array.isArray(msg.userNotes) ? msg.userNotes.slice(0, 50) : [],
              // R1：楼层人格+记忆快照（daemon 的 system prompt）
              persona: typeof msg.persona === "string" ? msg.persona.slice(0, 30_000) : "",
              updatedAt: new Date().toISOString(),
            })
            if (ok) console.log(`[hub] reading_context ← 《${msg.bookName ?? msg.safeName}》第 ${msg.chapter} 章（${String(msg.text).length} 字）`)
          }
        } else if (msg.type === "set_cc_config") {
          // app 同步 CC 设置（推送名 / nudge 参数 / 系统提示模板）。覆盖 ccConfig，内存不持久化。
          if (typeof msg.pushName === "string" && msg.pushName.trim()) ccConfig.pushName = msg.pushName.trim().slice(0, 100)
          // userName 会替换进 nudge channel body 喂给 claude → 拒绝标签注入
          if (typeof msg.userName === "string" && msg.userName.trim()) {
            const u = msg.userName.trim().slice(0, 100)
            if (hasTagInjection(u)) console.warn(`[hub] set_cc_config: userName 含标签，拒绝（防注入）`)
            else ccConfig.userName = u
          }
          if (typeof msg.nudgeEnabled === "boolean") ccConfig.nudgeEnabled = msg.nudgeEnabled
          if (!TRANSPORT_LOCK && (msg.newSessionTransport === "tmux" || msg.newSessionTransport === "stream")) ccConfig.newSessionTransport = msg.newSessionTransport
          if (Number.isFinite(msg.idleMinMin) && msg.idleMinMin > 0) ccConfig.idleMinMs = msg.idleMinMin * 60_000
          if (Number.isFinite(msg.idleMaxMin) && msg.idleMaxMin > 0) ccConfig.idleMaxMs = Math.max(msg.idleMaxMin * 60_000, ccConfig.idleMinMs)
          const clampMin = (v: any, d: number) => (Number.isFinite(v) && v >= 0 && v < 1440 ? Math.floor(v) : d)
          if (msg.quietStartMin !== undefined) ccConfig.quietStartMin = clampMin(msg.quietStartMin, ccConfig.quietStartMin)
          if (msg.quietEndMin !== undefined) ccConfig.quietEndMin = clampMin(msg.quietEndMin, ccConfig.quietEndMin)
          if (Number.isFinite(msg.cooldownMin) && msg.cooldownMin >= 0) ccConfig.cooldownMs = msg.cooldownMin * 60_000
          if (typeof msg.nudgeTemplate === "string" && msg.nudgeTemplate.trim()) {
            const t = msg.nudgeTemplate.trim().slice(0, 1000)
            if (hasTagInjection(t)) console.warn(`[hub] set_cc_config: nudgeTemplate 含标签，拒绝（防注入），保留原值`)
            else ccConfig.nudgeTemplate = t
          }
          // 保暖策略表：{session: "always"|"auto"|"never"}。整表替换（app 是唯一真相源），
          // 但只有 app 显式带了这个字段才动——老版本 app 不带，不该把她钉的常驻清空。
          if (msg.keepalivePolicies && typeof msg.keepalivePolicies === "object") {
            keepalivePolicies.clear()
            for (const [session, p] of Object.entries(msg.keepalivePolicies as Record<string, unknown>)) {
              if (typeof session !== "string" || !session || session.length > 100) continue
              if (p === "always" || p === "never") keepalivePolicies.set(session, p)   // auto 不存
            }
            saveKeepalivePolicies()
            const pinned = [...keepalivePolicies].filter(([, p]) => p === "always").map(([s]) => s)
            if (pinned.length > KEEPALIVE_PIN_WARN)
              console.warn(`[hub] ⚠️ 钉了 ${pinned.length} 个常驻保暖（${pinned.join(", ")}）——它们全都不参与单选，各烧各的`)
          }
          // 传输策略不再跟 set_cc_config 走（09-19：两台设备各存一份，旧的那台每次重连都把刚设的改回去，
          // 会话来回收编、正说到一半被掐）。只认 set_transport_policy（她点菜单那一下），hub 是唯一真相，改完推给所有设备。
          const hhmm = (m: number) => `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`
          const policySummary = (keepalivePolicies.size ? ` keepalive=${[...keepalivePolicies].map(([s, p]) => `${s}:${p}`).join(",")}` : "")
            + (transportPolicies.size ? ` transport=${[...transportPolicies].map(([s, p]) => `${s}:${p}`).join(",")}` : "")
          console.log(`[hub] set_cc_config: push="${ccConfig.pushName}" transport=${ccConfig.newSessionTransport} nudge=${ccConfig.nudgeEnabled} idle=${ccConfig.idleMinMs / 60000}-${ccConfig.idleMaxMs / 60000}min quiet=${hhmm(ccConfig.quietStartMin)}-${hhmm(ccConfig.quietEndMin)} cd=${ccConfig.cooldownMs / 60000}min${policySummary}`)
          reconcileStreamTransport()
        } else if (msg.type === "set_transport_policy" && typeof msg.session === "string" && msg.session && msg.session.length <= 100) {
          const p = msg.policy
          const before = transportPolicies.get(msg.session) ?? ""
          if (p === "tmux" || p === "stream") transportPolicies.set(msg.session, p)
          else transportPolicies.delete(msg.session)
          const after = transportPolicies.get(msg.session) ?? ""
          if (before !== after) {
            saveTransportPolicies()
            console.log(`[hub] transport policy ${msg.session}: ${before || "全局"} → ${after || "全局"}`)
            reconcileStreamTransport()
          }
          broadcastFrame(transportPoliciesFrame())
        } else if (msg.type === "set_bind") {
          // 绑定开关：只允许本机（hub 所在的 Mac）改——决定 hub 实绑 LAN/Tailscale，关掉=真不监听。
          if (!trustedLocal) { console.warn(`[hub] set_bind 被拒（非本机直连 ${remote}）`); return }
          if (manualHost) { ws.send(JSON.stringify({ type: "bind_state", manual: manualHost })); return }  // 手动绑定模式不受开关控制
          detected = detectInterfaces()   // 重扫网卡：拨开关瞬间若 Tailscale 刚起来也立刻发现
          const lan = msg.lan !== false, ts = msg.tailscale !== false
          bindPrefs.save({ lan, tailscale: ts })
          if (detected.lan) { lan ? bindHost(detected.lan) : unbindHost(detected.lan) }
          if (detected.tailscale) { ts ? bindHost(detected.tailscale) : unbindHost(detected.tailscale) }
          console.log(`[hub] set_bind: lan=${lan} tailscale=${ts} → bound ${[...listeners.keys()].join(",")}`)
          ws.send(JSON.stringify({ type: "bind_state", lan: detected.lan ? listeners.has(detected.lan) : false, tailscale: detected.tailscale ? listeners.has(detected.tailscale) : false, hasLan: !!detected.lan, hasTailscale: !!detected.tailscale }))
        }
      }))

      ws.on("close", (code, reason) => {
        mpClients.delete(ws)
        focusByClient.delete(ws)   // 连接断 = 不聚焦任何会话
        clientInfoByWS.delete(ws)
        callInstallByWS.delete(ws)
        // L4: 兜底清理 terminal 订阅（用户切走 / app 后台 / 网络断 不会显式发 detach）
        for (const att of Array.from(terminalAttachments.values())) {
          if (att.mpClients.has(ws) || att.joining.has(ws)) {
            att.mpClients.delete(ws)
            att.joining.delete(ws)
            if (!terminalWatched(att)) {
              void closeTerminalAttachment(att.sessionName)
            }
          }
        }
        for (const sessionName of terminalSizes.removeClient(ws)) void applyEffectiveSize(sessionName)   // T51
        // pocket: MP 断开 → 所有等它回复的 pending 立即失败（单 client 场景全清）
        for (const [pid, p] of pocketPending) {
          clearTimeout(p.timer); p.resolve({ ok: false, error: "phone disconnected" }); pocketPending.delete(pid)
        }
        console.log(`[hub] ${probeTs()} MP disconnected (total ${mpClients.size}) from ${remote} up=${Math.round((Date.now() - probeConnectedAt) / 1000)}s code=${code} reason=${reason?.toString() || "(empty)"}`)
      })
    } else if (pathname === "/mcp") {
      mcpClients.add(ws)
      console.log(`[hub] MCP connected (total ${mcpClients.size})`)

      let mcpType: unknown
      ws.on("message", (raw) => timeHandler(() => wsSite("mcp", mcpType), () => {
        let msg: any
        mcpType = undefined
        try { msg = JSON.parse(raw.toString()) } catch { return }
        mcpType = msg?.type
        if (msg.type === "mcp_hello" && typeof msg.session_name === "string") {
          // socket ↔ 宿主 session 关联（reply 守卫的钥匙）
          mcpSessionByWS.set(ws, msg.session_name)
          console.log(`[hub] MCP hello ← ${msg.session_name}`)
          return
        }
        if (msg.type === "voice_call_request") {
          const session = mcpSessionByWS.get(ws)
          void (async () => {
            try {
              if (!session || agoraExecutorRef?.hasActiveClaim(session)) throw new Error("call requires bound private session without pending Agora claim")
              let call
              if (msg.action === "ring") {
                const created = voiceCalls.create(msg.call_id, msg.chat_id, msg.install_id, session, sessionActivity.get(session)?.lastChatId ?? sessionMap.get(session)?.chatId, typeof msg.caller === "string" ? msg.caller : session)
                call = created.call
                if (created.fresh) {
                  const device = voiceCalls.device(msg.install_id)!
                  const pushed = await sendVoIPAPNs(device, call)
                  if (!pushed.ok) {
                    call = voiceCalls.transition(call.call_id, "fail", { session })
                    broadcastCall(call)
                    throw new Error(`VoIP push failed: ${pushed.reason ?? pushed.status}`)
                  }
                  call = voiceCalls.get(call.call_id)!
                  broadcastCall(call)
                }
              } else {
                const existing = voiceCalls.get(msg.call_id)
                if (!existing || existing.session !== session) throw new Error("call not owned by session")
                if (msg.action === "cancel") { call = voiceCalls.transition(msg.call_id, "cancel", { session }); broadcastCall(call) }
                else if (msg.action === "status") call = existing
                else throw new Error("invalid call action")
              }
              ws.send(JSON.stringify({ type: "voice_call_result", request_id: msg.request_id, ok: true, call }))
            } catch (e: any) { ws.send(JSON.stringify({ type: "voice_call_result", request_id: msg.request_id, ok: false, error: e.message })) }
          })()
          return
        }
        if (msg.type === "agora_complete") {
          const requestId = typeof msg.request_id === "string" ? msg.request_id : ""
          const isPass = msg.pass === true
          // pass = observe 沉默，content 可缺省；正常完成 content 必填。
          if (
            !requestId
            || typeof msg.mention_id !== "string"
            || typeof msg.claim_token !== "string"
            || (!isPass && typeof msg.content !== "string")
          ) {
            ws.send(JSON.stringify({
              type: "agora_complete_result",
              request_id: requestId,
              ok: false,
              error: { code: "invalid_payload", message: "agora_complete requires request_id, mention_id, claim_token, and content (or pass: true)" },
            }))
            return
          }
          try {
            if (isPass) {
              const result = agoraProtocol.passMention(msg.mention_id, msg.claim_token)
              ws.send(JSON.stringify({
                type: "agora_complete_result",
                request_id: requestId,
                ok: true,
                passed: true,
                idempotent: result.idempotent,
              }))
            } else {
              const result = agoraProtocol.completeMention(msg.mention_id, msg.claim_token, msg.content)
              ws.send(JSON.stringify({
                type: "agora_complete_result",
                request_id: requestId,
                ok: true,
                message_id: result.message.id,
                idempotent: result.idempotent,
              }))
            }
            agoraExecutor.onMentionSettled(msg.mention_id)
          } catch (error) {
            const code = error instanceof AgoraStoreError ? error.code : "internal_error"
            const message = error instanceof AgoraStoreError ? error.message : "Agora completion failed"
            ws.send(JSON.stringify({
              type: "agora_complete_result",
              request_id: requestId,
              ok: false,
              error: { code, message },
            }))
          }
        } else if (msg.type === "reply" && typeof msg.chat_id === "string" && typeof msg.content === "string") {
          // 守卫（audit P2-6，07-20 粟粟真机踩中变体）：session 正被房间 @（claim 未答）时
          // 拦下 reply——老 session 的日常习惯是 reply，会把房间回答误发进私聊对话。
          // 拒绝并教路：完成 agora_complete 后 reply 恢复可用。
          const guardSession = mcpSessionByWS.get(ws)
          if (guardSession && agoraExecutorRef?.hasActiveClaim(guardSession)) {
            try {
              ws.send(JSON.stringify({
                type: "reply_err",
                mp_msg_id: typeof msg.mp_msg_id === "string" ? msg.mp_msg_id : undefined,
                reason: "agora_claim_pending",
                message: "你正被中庭房间 @（有未完成的 mention）：这条回答请用 agora_complete 工具发回房间（带 claim_token），不要用 reply。房间任务完成后 reply 恢复可用。",
              }))
            } catch {}
            console.log(`[hub] reply 被拦（${guardSession} 有未答房间 mention）→ 引导 agora_complete`)
            return
          }
          deliverReply(msg, guardSession, "mcp")
        } else if (msg.type === "edit" && typeof msg.chat_id === "string" && typeof msg.message_id === "string" && typeof msg.content === "string") {
          // A4：编辑发过的消息 → broadcast + 进会话内 edit 缓存（重连补）。app 按 mp_msg_id 找节点改 content。
          recentEdits.push({ chat_id: msg.chat_id, mp_msg_id: msg.message_id, content: msg.content, ts: Date.now() })
          while (recentEdits.length > MAX_REPLY_LOG) recentEdits.shift()
          const editPayload = JSON.stringify({ type: "edit", chat_id: msg.chat_id, mp_msg_id: msg.message_id, content: msg.content })
          let n = 0
          for (const mp of mpClients) { if (mp.readyState === mp.OPEN) { try { mp.send(editPayload); n++ } catch {} } }
          console.log(`[hub] edit ← mcp → ${msg.message_id} broadcast to ${n}/${mpClients.size}`)
        }
      }))

      ws.on("close", () => {
        mcpClients.delete(ws)
        mcpSessionByWS.delete(ws)
        console.log(`[hub] MCP disconnected (total ${mcpClients.size})`)
      })
    } else {
      ws.close(1008, "unknown path")
    }
  }))
  wss.on("close", () => {
    clearInterval(agoraRecoveryTimer)
    clearInterval(laTimer)
    clearInterval(toolActivityTimer)
    clearInterval(spoolTimer)
    spoolScanner.close()
    laScheduler.stop()
    laSchedulerRef = null
    agoraProtocol.close()
  })

  // L4 P0a：hub 端 25 秒主动给 MP client 发 WS ping frame 保活。
  // iOS URLSession 收到 ping 自动回 pong，算 activity → 不会因 idle 60s 默认超时
  // （即使 iOS 端 Timer ping 因 RunLoop mode 跳票，hub 这边 ping 也能兜底）
  // thinking-hook 待投目录：启动 5s 后补一次（hub 重启期间 hook 投不进来的），之后每 20s 看一眼。
  // K3：目录有动静（fs.watch）或还有没投完的才扫，全异步；watch 挂不上就每次都扫，挂上了也每 5 分钟兜底扫一次
  const spoolScanner = new DirtyDirScanner(THINKING_SPOOL_DIR, async () => (await drainThinkingSpool()).left, 5 * 60_000)
  void mkdir(THINKING_SPOOL_DIR, { recursive: true }).then(() => spoolScanner.arm(), () => {})
  setTimeout(() => void spoolScanner.tick(), 5_000)
  const spoolTimer = setInterval(() => void spoolScanner.tick(), 20_000)

  // tmux 会话表后台刷新（plan-hub-instant-connect）：hasSession / list / paneTitles 读这份快照。
  // K1 开时 listen 前先等首份（有超时）：hub 刚起时也不用走同步 has-session / ls / list-panes；K1=0 完全是旧的启动路径
  let firstTmuxSnapshot: Promise<unknown> | null = null
  if (baseTmux === realTmuxRunner) {
    // K1：常驻 tmux 控制连接。会话表走它读；会话增删 / 改名 / （重）连上时立刻刷新，不等 2s 轮询
    if (k1Enabled()) {
      const ctl = startSharedTmuxControl()
      const refreshNow = () => void tmuxState.refresh()
      ctl.onNotify("sessions-changed", refreshNow)
      ctl.onNotify("session-renamed", refreshNow)
      ctl.onNotify("ready", refreshNow)
      const t0 = Date.now()
      firstTmuxSnapshot = Promise.race([
        tmuxState.refresh().then(() => console.log(`[hub] 首份 tmux 会话表 ${Date.now() - t0}ms`)),
        new Promise<void>(r => setTimeout(() => r(), FIRST_TMUX_SNAPSHOT_WAIT_MS)),
      ])
    } else {
      void tmuxState.refresh()
    }
    setInterval(() => void tmuxState.refresh(), TMUX_STATE_POLL_MS)
  }
  // 主循环卡顿探针：定时器迟到 >1s 记一行（/health、WS 握手同样被卡这么久）
  // ≥1s 的附进程体征（上一 tick 到这一 tick 之间）：CPU 用了多少、硬缺页、堆有没有掉，区分 GC / 换页 / JS
  let lagExpectAt = Date.now() + LOOP_LAG_TICK_MS
  let lagPrev = { at: Date.now(), vitals: procSample() }
  setInterval(() => {
    const lag = Date.now() - lagExpectAt
    const now = { at: Date.now(), vitals: procSample() }
    if (lag > 200) lagLog.add({ at: Date.now(), ms: lag })
    if (lag > 1_000) console.warn(`[hub] ${probeTs()} loop lag ${lag}ms：${blockLedger.explainLag(Date.now(), lag)}｜${describeLagVitals(lagPrev.vitals, now.vitals, now.at - lagPrev.at)}`)
    lagPrev = now
    lagExpectAt = Date.now() + LOOP_LAG_TICK_MS
  }, LOOP_LAG_TICK_MS)
  // 阻塞调用账汇总：每 10 分钟按总耗时列前 8 个调用点（启动以来累计）
  setInterval(() => {
    const top = blockLedger.top(8).map(([k, s]) => `${k} ×${s.count} 共${Math.round(s.totalMs)}ms 最长${Math.round(s.maxMs)}ms`)
    if (top.length) console.log(`[block] top：${top.join("；")}`)
  }, 10 * 60_000)

  const HUB_PING_INTERVAL_MS = 25_000
  setInterval(() => {
    for (const c of mpClients) {
      if (c.readyState === c.OPEN) {
        try { c.ping() } catch {}
      }
    }
    for (const c of mcpClients) {
      if (c.readyState === c.OPEN) {
        try { c.ping() } catch {}
      }
    }
  }, HUB_PING_INTERVAL_MS)

  // Nudge 调度：每 2 分钟扫活跃 session。
  // 「只跟最后聊的那个发」：永远只选 lastUserSendAt 最大的那一个 session（= susu 当前在聊的对话）。
  // 第一名静默不够久 / 在冷却 → 这轮 pass，不 fall back 给次活跃的——否则其它窗口会被轮流主动找。
  let lastGlobalNudgeAt = 0
  setInterval(() => {
    if (!ccConfig.nudgeEnabled) return
    const now = Date.now()
    if (inQuietHours(new Date())) return
    if (now - lastGlobalNudgeAt < ccConfig.cooldownMs) return   // 全局冷却：一个窗口只放一个出去
    // 1) 纯按"最近活跃"挑第一名，不看冷却/静默
    let pick: { session: string; act: SessionActivity } | null = null
    for (const [session, act] of sessionActivity) {
      if (!act.lastChatId) continue
      if (!tmux.hasSession(session)) continue
      if (!pick || act.lastUserSendAt > pick.act.lastUserSendAt) pick = { session, act }
    }
    if (!pick) return
    const { session, act } = pick
    // 2) 第一名静默够久吗？冷却过了吗？任一不满足 → 这轮 pass（不让位给次活跃）
    if (now - act.lastUserSendAt < act.thresholdMs) return
    if (now - act.lastNudgeAt < ccConfig.cooldownMs) return
    const idleMin = Math.round((now - act.lastUserSendAt) / 60_000)
    const body = ccConfig.nudgeTemplate.replace(/\{idle\}/g, String(idleMin)).replace(/\{name\}/g, ccConfig.userName)
    const tag = `<channel source="memorypalace-nudge" chat_id="${act.lastChatId}">${body}</channel>`
    try {
      void tmux.send(tag, session).catch((e: any) => console.warn(`[hub] nudge send fail ${session}: ${e?.message}`))
      act.lastNudgeAt = now
      act.thresholdMs = rollNudgeThreshold()
      lastGlobalNudgeAt = now
      console.log(`[hub] nudge → ${session} chat_id=${act.lastChatId.slice(0, 8)} idle=${idleMin}min (单选/全局冷却)`)
    } catch (e: any) {
      console.warn(`[hub] nudge failed for ${session}: ${e.message}`)
    }
  }, (Number(process.env.MP_CC_NUDGE_SCAN_SEC) || 120) * 1000)

  // Cache keepalive 调度：每 5 分钟扫一遍（判定逻辑见 shouldKeepalive 注释）。
  // 跟 nudge 一样单选最活跃的那一个（成本原因，见 shouldKeepalive 上方那段），但不看
  // quiet hours——凌晨保暖数学上仍赚，且 ping 不走 bridge，app 里看不见，不会吵到她。
  // codex 不保：OpenAI 缓存机制/价格结构不同。
  const KEEPALIVE_ENABLED = process.env.MP_CC_KEEPALIVE !== "0"
  const KEEPALIVE_IDLE_MS = (Number(process.env.MP_CC_KEEPALIVE_IDLE_MIN) || 50) * 60_000
  const KEEPALIVE_MAX_MS = (Number(process.env.MP_CC_KEEPALIVE_MAX_HOURS) || 12) * 3_600_000
  const KEEPALIVE_MAX_STREAK = Number(process.env.MP_CC_KEEPALIVE_MAX_STREAK) || 6
  const KEEPALIVE_TAG = `<channel source="cache-keepalive">[缓存保暖 ping，无事发生] 请只回复 "ok" 两个字符：不要调用任何工具，不要展开思考，不要用 bridge 回复。</channel>`
  const keepaliveWriteTag = () => `<channel source="cache-keepalive">[缓存保暖 + 写作提醒] ${ccConfig.userName}离开了。在回复 "ok" 之前：1) 如果这段对话里有想留住的东西，写进你的日记本（如果有）；2) 如果有需要落盘的 memory，现在写。写完之后回复 "ok"。不要用 bridge 回复。</channel>`
  setInterval(() => {
    if (!KEEPALIVE_ENABLED) return
    const now = Date.now()
    const opts = { idleMs: KEEPALIVE_IDLE_MS, maxIdleMs: KEEPALIVE_MAX_MS, maxStreak: KEEPALIVE_MAX_STREAK }
    const plan = planKeepalive(
      sessionActivity, now, opts,
      (s) => sessionEngine(s) === "claude" && tmux.hasSession(s) && !sessionSpawning.has(s),
      keepalivePolicyOf,
    )
    for (const session of plan) {
      const act = sessionActivity.get(session)!
      const policy = keepalivePolicyOf(session)
      const idleMin = Math.round((now - Math.max(act.lastUserSendAt, act.lastNudgeAt, act.lastKeepaliveAt ?? 0)) / 60_000)
      // 第一次保暖（上一次 API 活动不是保暖）→ 发写作提醒版；后续发普通版
      const isFirstKeepalive = !act.lastKeepaliveAt || act.lastKeepaliveAt < Math.max(act.lastUserSendAt, act.lastNudgeAt)
      const tag = isFirstKeepalive ? keepaliveWriteTag() : KEEPALIVE_TAG
      act.lastKeepaliveAt = now
      act.keepaliveStreak = (act.keepaliveStreak ?? 0) + 1
      void tmux.send(tag, session).catch((e: any) => console.warn(`[hub] keepalive send fail ${session}: ${e?.message}`))
      const quota = policy === "always" ? "🔥常驻" : `streak=${act.keepaliveStreak}/${KEEPALIVE_MAX_STREAK}`
      console.log(`[hub] keepalive → ${session} idle=${idleMin}min ${quota}${isFirstKeepalive ? " (write-reminder)" : ""}`)
    }
  }, 5 * 60_000)

  // #if PERSONAL_APPS
  // 军机处 M0：普查 indexer——30s 后首扫（大盘 934MB 只在 scan_state 空时真读全量），
  // 之后每 5min 增量（未变文件 stat 即跳，常态 <100ms）。只读不注入。
  // K2：扫描（stat / 读文件 / sqlite 写）在 Worker 线程跑，主线程只留读查询和奏折账本；MP_HUB_PERF_K2=0 回主线程
  // 粟粟 10-11：军机处先关——默认不起（不开库、不扫、不建定时器、不建收据目录），MP_CC_WARROOM=1 才打开；
  // 关着时 /warroom/* 回 503、看板 ready:false、warroom_request 回 not ready
  if (process.env.MP_CC_WARROOM !== "1") {
    console.log("[warroom] 军机处默认关闭（MP_CC_WARROOM=1 打开）")
  } else {
    const indexerOpts = {
      dbPath: join(SECRETS_DIR, "warroom.db"),
      ccProjectsRoot: process.env.MP_CC_WARROOM_CC_ROOT ?? join(homedir(), ".claude", "projects"),
      codexSessionsRoot: process.env.MP_CC_WARROOM_CODEX_ROOT ?? join(homedir(), ".codex", "sessions"),
    }
    // K2 审查 R1-5：开库（切 WAL）撞上旧连接的活动事务会失败——异步退避重开，拿到库才往下初始化（第一次成功就是同步的）
    openIndexerWithRetry(indexerOpts, (indexer) => { try {
      warroomIndexer = indexer
      // 编译版：bun --compile 只认字符串字面量 + 额外入口的 worker，build-cc-bridge.sh 还没加 → 退回主线程扫描
      const compiledHub = import.meta.path.startsWith("/$bunfs/")
      const mainDb = indexer.db
      // K2 审查 R1-4：worker 真的就绪（发了 ready）才宣布 K2、才把 WAL 检查点交给 worker（主线程的账本写不顺带搬 WAL）；
      // 起不来连试 3 次后退回主线程扫描，恢复主连接自动检查点。空闲 worker 已 unref，hub 的 process.exit 走 exit 钩子终止它
      const scanWorker = k2Enabled() && !compiledHub ? new WarroomScanWorker({
        indexer: indexerOpts,
        onReady: () => { mainDb.exec("PRAGMA wal_autocheckpoint = 0"); console.log("[warroom] 普查扫描：Worker 线程（K2）就绪") },
      }) : null
      if (scanWorker) process.on("exit", () => scanWorker.terminate())
      else console.log(`[warroom] 普查扫描：主线程（K2 关${compiledHub ? "：编译版" : ""}）`)
      const runScan = warroomScanRunner({
        scanMain: () => warroomIndexer!.scanAllAsync(),
        worker: scanWorker,
        load5: () => loadavg()[1],
        onScan: (s) => { warroomLastScan = s },
        onFallback: () => mainDb.exec("PRAGMA wal_autocheckpoint = 1000"),
      })
      setTimeout(() => void runScan("initial"), 30_000)
      setInterval(() => void runScan("incremental"), 5 * 60_000)
      // M1：账本 + 派发器（复用 indexer 同一个 db 文件，单写者=hub 进程）
      warroomLedger = new WarroomLedger(warroomIndexer.db)
      const receiptDir = join(homedir(), ".mp-warroom", "receipts")
      try { mkdirSync(receiptDir, { recursive: true }) } catch {}
      warroomDispatcher = new WarroomDispatcher({
        ledger: warroomLedger,
        lookupTarget: warroomLookupTarget,
        sendTmux: (tag, session) => tmux.send(tag, session),
        spawnT2: realSpawnT2,
        receiptDir,
        onT2Settled: (taskId) => console.log(`[warroom] t2 settled: ${taskId} → ${warroomLedger?.getTask(taskId)?.status}`),
      })
      console.log(`[warroom] ledger + dispatcher armed (central: ${[...warroomCentralSessions()].join(",")})`)

      // ── M2：验收 loop ──
      const DESK_SESSION = WARROOM_DESK_SESSION
      const notifyDesk = (task: TaskRow, verdict: ReturnType<typeof parseVerdict>, event: Parameters<typeof buildDeskNotice>[2]) => {
        const notice = buildDeskNotice(task, verdict, event)
        if (tmux.hasSession(DESK_SESSION)) {
          void tmux.send(notice, DESK_SESSION).catch((e: any) => console.warn(`[warroom] desk notify fail: ${e?.message}`))
        } else console.log(`[warroom] desk offline, notice dropped: ${notice.slice(0, 120)}`)
      }
      // 孤儿恢复：hub 重启会杀掉 in-flight 的 T2/T4 子进程（headless claude 是 hub 的 child），
      // 这些任务的收据永远不会来 → 启动时把 dispatched 状态的 resume/repo 单全部标 failed + 知会。
      // （T1 注入的不算孤儿——对方窗口独立于 hub 活着，收据文件还会来。）
      try {
        const orphans = warroomLedger.queryTasks({ status: "dispatched", limit: 100 })
          .filter(t => t.target_kind === "resume" || t.target_kind === "repo")
        for (const o of orphans) {
          warroomLedger.transition(o.task_id, "failed", "hub", "hub restart orphaned in-flight T2/T4 (子进程已随旧 hub 死亡)")
          notifyDesk(warroomLedger.getTask(o.task_id)!, null, "failed")
          console.warn(`[warroom] orphaned task ${o.task_id} → failed`)
        }
        // reviewing 卡死救援：重启杀掉的是验收官子进程——任务退回 evidence_in，
        // inspection loop 会重新开庭（验收官只读无副作用，重跑幂等）。
        const stuck = warroomLedger.queryTasks({ status: "reviewing", limit: 100 })
        for (const s of stuck) {
          warroomLedger.db.query("UPDATE tasks SET status = 'evidence_in' WHERE task_id = ?").run(s.task_id)
          console.warn(`[warroom] reviewing-stuck task ${s.task_id} → back to evidence_in (验收官重开庭)`)
        }
      } catch (e: any) { console.warn(`[warroom] orphan sweep fail: ${e?.message}`) }
      // T1 交卷检测：receipts/<task_id>.json 落盘 → attachReceipt → evidence_in
      const receiptCursor = { after: "" }
      const scanReceipts = async () => { if (warroomLedger) await scanT1Receipts(warroomLedger, receiptDir, receiptCursor) }
      // 验收官：evidence_in → reviewing → 三分支。并发 1，单任务重试 2 次后升级。
      let inspectorBusy = false
      const inspectRetries = new Map<string, number>()
      const runInspection = async () => {
        if (inspectorBusy || !warroomLedger || !warroomIndexer) return
        const pending = warroomLedger.queryTasks({ status: "evidence_in", limit: 1 })
        if (!pending.length) return
        const task = pending[0]
        inspectorBusy = true
        try {
          const target = warroomLookupTarget(task.target_ref)
          let evObj: Record<string, unknown> = {}
          try { evObj = task.evidence ? JSON.parse(task.evidence) : {} } catch {}
          const pack: EvidencePack = {
            taskId: task.task_id, workOrder: task.body, filescope: task.filescope,
            gitBase: (evObj.git_base as string) ?? null,
            // ⚠️ repo 单的 cwd 就是 target_ref——普查表查不到它，fallback 到 hub cwd 会让
            // 验收官在错误目录开庭制造冤案（zz-0726-10 实案：真实 581 行被判"编造"）
            cwd: task.target_kind === "repo" ? task.target_ref : (target?.cwd ?? null),
            transcriptPath: target?.transcriptPath ?? null,
            receiptJson: task.receipt, reworkRound: reworkDepth(warroomLedger, task),
          }
          const ledger = warroomLedger
          await retryBusy(() => ledger.transition(task.task_id, "reviewing", "inspector", "对手协议开庭"))
          const cmd = buildInspectorCommand(buildInspectorPrompt(pack))
          // spawn cwd 必须与 pack.cwd 一致——上次只修了证据包描述没修进程目录，
          // 验收官在 hub 目录开庭连环制造 cwd 罗生门（zz-0726-13~16 实案）
          const { stdout, exitCode, timedOut } = await realSpawnT2(cmd, pack.cwd, 8 * 60_000)
          // 验收官自己的成本也入账（透明）
          try {
            const outer = JSON.parse(stdout.trim())
            if (typeof outer?.total_cost_usd === "number") await retryBusy(() => ledger.attachEvidence(task.task_id, { inspector_cost_usd: outer.total_cost_usd }, "inspector"))
          } catch {}
          const verdict = timedOut || exitCode !== 0 ? null : parseVerdict(stdout)
          if (!verdict) {
            const n = (inspectRetries.get(task.task_id) ?? 0) + 1
            inspectRetries.set(task.task_id, n)
            if (n <= 2) {
              // 回 evidence_in 等下轮重试（reviewing→evidence_in 不在状态机——直接置回，留审计）
              await retryBusy(() => ledger.db.query("UPDATE tasks SET status = 'evidence_in' WHERE task_id = ?").run(task.task_id))
              console.warn(`[warroom] inspector unparseable for ${task.task_id} (retry ${n}/2)`)
            } else {
              await retryBusy(() => ledger.attachVerdict(task.task_id, { verdict: "unsure", reasons: ["验收官连续失败"] }, "inspector"))
              notifyDesk(task, null, "escalate")
              console.warn(`[warroom] inspector gave up on ${task.task_id} → escalate（停在 reviewing）`)
            }
            return
          }
          await retryBusy(() => ledger.attachVerdict(task.task_id, verdict, "inspector"))
          if (verdict.verdict === "approved") {
            await retryBusy(() => ledger.transition(task.task_id, "approved", "inspector", verdict.reasons.slice(0, 2).join("；")))
            notifyDesk(ledger.getTask(task.task_id)!, verdict, "approved")
          } else if (verdict.verdict === "rejected") {
            await retryBusy(() => ledger.transition(task.task_id, "rejected", "inspector", verdict.reasons.slice(0, 2).join("；")))
            const spec = buildReworkTask(ledger, task, verdict)
            if (spec && warroomDispatcher) {
              try {
                const rework = await retryBusy(() => ledger.createTask(spec))
                await warroomDispatcher.dispatch(rework.task_id, "inspector")
                notifyDesk(task, verdict, "rejected_rework")
                console.log(`[warroom] rework dispatched: ${rework.task_id} (parent ${task.task_id})`)
              } catch (e: any) {
                notifyDesk(task, verdict, "escalate")
                console.warn(`[warroom] rework dispatch fail for ${task.task_id}: ${e?.message} → escalate`)
              }
            } else {
              notifyDesk(task, verdict, "escalate")   // 轮数用尽
            }
          } else {
            notifyDesk(task, verdict, "escalate")      // unsure：停在 reviewing 等御裁
          }
        } catch (e: any) {
          console.warn(`[warroom] inspection error for ${task.task_id}: ${e?.message}`)
        } finally { inspectorBusy = false }
      }
      // M4 DAG 自动放行：依赖全朱批的排队单自动起飞（EPIC 流水线自转）
      const releaseQueued = async () => {
        if (!warroomLedger || !warroomDispatcher) return
        for (const t of warroomLedger.readyQueuedTasks()) {
          try {
            const r = await warroomDispatcher.dispatch(t.task_id, "dag")
            console.log(`[warroom] dag release: ${t.task_id} → ${r.channel}`)
          } catch (e: any) { console.warn(`[warroom] dag release fail ${t.task_id}: ${e?.message}`) }
        }
      }
      // M5 EPIC 终审叫醒：某需求下全部奏折终态 → 注入中枢做对账终审（对照原文，不对照转述）
      const wakeFinalReview = () => {
        if (!warroomLedger) return
        for (const e of warroomLedger.epicsReadyForFinalReview()) {
          warroomLedger.setRequestStatus(e.request_id, "reviewing")
          const tag = `<channel source="warroom-epic-done" request_id="${e.request_id}">【EPIC ${e.request_id} 全部终态，请终审】原始需求原文：「${e.text.replace(/\n/g, " ")}」。战果：${e.total} 张奏折，${e.approved} 张朱批。用 warroom_tasks（epic=${e.request_id}）逐张对照原文：哪些完成、哪些没完成、哪些中途需求变了。终审报告用 bridge 发粟粟，然后不用再动账本。</channel>`
          if (tmux.hasSession(DESK_SESSION)) {
            void tmux.send(tag, DESK_SESSION).catch((err: any) => console.warn(`[warroom] epic-done notify fail: ${err?.message}`))
          }
          console.log(`[warroom] epic ${e.request_id} ready for final review (${e.approved}/${e.total})`)
        }
      }
      // 先收据后开庭：上一轮收据还没读完（swap 时可能 >30s）就整轮跳过，开庭一定排在本轮收据之后
      const warroomRound = serialRound(scanReceipts, () => {
        void runInspection().catch((e) => console.warn(`[warroom] 开庭轮失败: ${e}`))
        void releaseQueued().catch((e) => console.warn(`[warroom] DAG 放行轮失败: ${e}`))
        wakeFinalReview()
      },
                                       (e) => console.warn(`[warroom] 收据 / 开庭轮失败: ${e}`))
      setInterval(warroomRound, 30_000)
      console.log(`[warroom] M2 inspection loop armed (desk: ${DESK_SESSION})`)
    } catch (e: any) { console.warn(`[warroom] indexer init fail: ${e?.message}`) } })
  }
  // #endif

  // 闲置回收（判定见 session-reap.ts）：扫活着的会话而不是内存活动表——后者 hub 一重启就空了。
  // 启动 5 分钟后先扫一次（hub 一小时内重启过就永远等不到整点那次），之后每小时
  const runReap = () => {
    const live = tmuxState.list()
    if (!live) { console.warn("[hub] reap 跳过：tmux 会话快照过期"); return }
    void reapIdleSessions([...live, ...streamRunner.list()]).catch((e) => console.warn(`[hub] reap fail: ${e}`))
  }
  setTimeout(runReap, 5 * 60_000)
  setInterval(runReap, 3_600_000)

  // 初始绑定：loopback 总绑；手动 HUB_HOST 优先；否则按 bind-config 开关绑 LAN/Tailscale。
  // 先绑 loopback，拿到真实端口后再绑其余的（PORT=0 时串行才能共用一个端口）。
  // 内嵌 hub（PORT=0）：上次分到的端口记在 hub-config，先试它，二维码重启后还有效；被占了退回 0（#046 astra P1-1）。
  const embeddedPortMode = PORT === 0
  if (embeddedPortMode && hubConfig.port) PORT = hubConfig.port
  const bindRest = () => {
    if (manualHost) {
      bindHost(manualHost)
    } else {
      const prefs = bindPrefs.get()
      if (prefs.lan && detected.lan) bindHost(detected.lan)
      if (prefs.tailscale && detected.tailscale) bindHost(detected.tailscale)
      console.log(`[hub] bind prefs: lan=${prefs.lan}(${detected.lan ?? "无网卡"}) tailscale=${prefs.tailscale}(${detected.tailscale ?? "无网卡"})`)
    }
    console.log(`[hub] bound: ${[...listeners.keys()].join(", ")}（/health /pair 仅 loopback）`)
  }
  // #068 中继：有 secrets/relay.json 才开 Unix socket 入口（按远程处理，只放 /health 和 /cc）
  const startRelay = async () => {
    const cfg = loadRelayConfig(relayConfigPath)
    if (cfg === null) return
    if (typeof cfg === "string") { console.warn(`[hub] relay.json 不可用：${cfg}，不开中继`); return }
    const sockPath = relaySocketPath(PORT)
    const err = await prepareRelaySocket(sockPath)
    if (err) { console.warn(`[hub] 中继入口不开：${err}（${sockPath}）`); return }
    try { await openRelayIngress(sockPath, httpHandler, onUpgrade) } catch (e: any) {
      console.warn(`[hub] 中继入口 listen 失败：${e?.code ?? e?.message}（${sockPath}）`)
      return
    }
    process.on("exit", () => { try { unlinkSync(sockPath) } catch {} })
    console.log(`[hub] 中继入口 ${sockPath}`)
    relayIngressOpen = true
    if (process.env.MP_CC_RELAY_CONNECTOR !== "off") superviseRelayConnector(sockPath)
  }
  // connector 是 hub 的子进程（不动 launchd，D1）：stdin 管道断了它自己退；崩了退避重启
  const superviseRelayConnector = (sockPath: string) => {
    const { MP_CC_HUB_TOKEN: _token, ...env } = process.env   // connector 用不着 hub 口令
    let failures = 0
    let child: ReturnType<typeof spawn> | null = null
    process.on("exit", () => child?.kill())
    const run = () => {
      const startedAt = Date.now()
      // 编译版（Mac App 内嵌，模块路径在 /$bunfs/ 里）没有 bun CLI 也没有源码，用同一个二进制的子命令
      const compiled = import.meta.path.startsWith("/$bunfs/")
      const args = compiled ? ["--relay-connector"] : ["run", join(import.meta.dir, "relay-connector.ts")]
      child = spawn(process.execPath, args, {
        env: { ...env, MP_CC_RELAY_SOCK: sockPath, MP_CC_RELAY_CONFIG: relayConfigPath },
        stdio: ["pipe", "inherit", "inherit"],
      })
      child.on("exit", (code) => {
        if (Date.now() - startedAt > 60_000) failures = 0
        const delay = Math.min(60_000, 1_000 * 2 ** failures++)
        console.warn(`[hub] relay-connector 退出 code=${code}，${delay}ms 后重启`)
        setTimeout(run, delay)
      })
    }
    run()
  }
  const afterLoopback = () => {
    if (embeddedPortMode && hubConfig.port !== PORT) {
      hubConfig = { ...hubConfig, port: PORT }
      try { saveHubConfig(hubConfigPath, hubConfig) } catch (e: any) { console.warn(`[hub] hub-config save fail: ${e?.message}`) }
    }
    writeGeneratedMcpConfig(hubToken)
    setImmediate(bindRest)
    startRelay().catch((e: any) => console.warn(`[hub] 中继入口没开成：${e?.code ?? e?.message}`))   // unhandledRejection 会让 hub 退出
  }
  const bindLoopback = () => bindHost(detected.loopback, afterLoopback, (e) => {
    if (embeddedPortMode && PORT !== 0 && e?.code === "EADDRINUSE") {
      console.warn(`[hub] 上次的端口 ${PORT} 被占，改让系统分配`)
      PORT = 0
      bindHost(detected.loopback, afterLoopback)
    } else if (!embeddedPortMode) {
      bindRest()   // 固定端口（launchd）照旧：loopback 绑不上也继续试其余接口
    }
  })
  if (firstTmuxSnapshot) void firstTmuxSnapshot.then(bindLoopback)
  else bindLoopback()

  // 自愈重检：出国后 Tailscale 常晚于 hub 启动（launchd 开机自启 / 酒店重连网络），
  // 启动时算的 detected 看不到后来出现的 Tailscale 接口 → 绑不上 → 人在国外无法手动救。
  // 每 30s 重扫：开关为开但接口刚出现的自动补绑；更新 detected 让 /pair 拿最新地址。
  // 只补绑不主动 unbind（Tailscale 短暂抖动不反复拆建 listener；连不上的悬空 listener 无害）。
  if (!manualHost) {
    setInterval(() => void bindPrefs.refresh().then(() => {
      const fresh = detectInterfaces()
      const prefs = bindPrefs.get()
      if (prefs.tailscale && fresh.tailscale && !listeners.has(fresh.tailscale)) {
        console.log(`[hub] 自愈补绑 Tailscale ${fresh.tailscale}`); bindHost(fresh.tailscale)
      }
      if (prefs.lan && fresh.lan && !listeners.has(fresh.lan)) {
        console.log(`[hub] 自愈补绑 LAN ${fresh.lan}`); bindHost(fresh.lan)
      }
      detected = fresh
    }), 30_000)
  }
  return wss
}

// Auto-start only when this file is the entry point (bun run hub.ts)
if (import.meta.main && process.argv.includes("--relay-connector")) {
  runConnectorMain()
} else if (import.meta.main) {
  startHub()
  // AUTONOMY Phase 1：自主 agent 调度器（总开关默认关，app 写 agent/config.json 才动）
  import("./agent-runner.ts").then(m => m.startAgentScheduler())
    .catch(e => console.warn(`[agent] scheduler 启动失败: ${e}`))
}
