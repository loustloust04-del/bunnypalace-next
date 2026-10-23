/// 秒连账本（plan-hub-instant-connect §五）：app 每连上一次就报一段「从需要连接到连上」的明细。
/// 起点按粟粟口径：冷启动 = 点开图标（进程起点），回前台 = 即将进前台那一刻，掉线 / 换网 = 发生那一刻
/// （connect_report 帧），hub 对上自己的主循环卡顿 / 重启时刻，给每一次 >1s 的连接标上理由，
/// 追加进 <secrets>/connect-ledger.jsonl。统计：`bun scripts/connect-ledger.ts`。

import { timedSyncFs } from "./block-ledger"
const { appendFileSync } = timedSyncFs("connect-ledger ")

export const FAST_MS = 1_000

export interface ConnectAttempt {
  h: string          // 候选 host
  r: string          // ok | timeout | refused | nothub:<status> | unreachable | ws:<错误> | err:<code>
  ms: number
}

export interface ConnectReport {
  trigger: string    // launch | foreground | drop | path | connect
  t0: number         // 手机墙钟 ms：这一段开始
  openAt: number     // 手机墙钟 ms：WS 打开
  totalMs: number    // openAt - t0 - bgMs
  bgMs?: number      // 期间 app 在后台的时长（不算慢）
  waitMs?: number    // 退避定时器等待
  launchMs?: number  // 冷启动：t0（点开图标 = 进程起点）到 app 开始连
  prewarm?: boolean  // iOS 预热过：进程起点早于点开，t0 退到开始连那一刻
  mainDelayMs?: number  // 回调排主线程的最大延迟
  path?: string      // NWPath 签名：status|接口名
  host?: string      // 最终连上的 host
  attempts?: ConnectAttempt[]
  platform?: string
  // —— 尺子 connectV2（plan-app-instant-connect §2）。缺 = 旧 app。*Ms 都是单调时钟、从「连接入口」（app 开这一段）算起 ——
  rev?: string           // harnessRevision，如 connectV2-r2
  build?: string         // debug | release | perf（编译宏，不等于实现版本）
  run?: string           // 进程 runId
  dev?: string           // app 自生成的匿名设备 id（随机 UUID，存 UserDefaults）
  bin?: string           // 实际在跑的镜像 LC_UUID（= 哪个包）
  sw?: Record<string, string>   // A 刀开关有效值
  ep?: number            // 进程内第几段
  counts?: RunCounts     // 进程内计数（截至这份报告）
  firstReqMs?: number    // 入口 → 首个 HTTP 探测 / WS resume
  wsAttempt?: number; wsGen?: number
  wsVia?: string         // 最终 WS 由哪个探测候选发起（候选 id），单候选直连 = "direct"
  wsResumeMs?: number    // 入口 → 最终那次 WS resume
  wsOpenMs?: number      // 入口 → URLSession didOpen 委托回调（回调线程）
  uiMs?: number          // 入口 → 主线程进入（didOpen 排到主线程的 block 首行）
  clientInfoMs?: number  // 入口 → client_info 交给当前 task：计划定义的终点
  finishMs?: number      // 入口 → finishEpisode 开始组报告（= 旧 openAt 那一刻）
  wsInvalid?: number     // didOpen 归属对不上（旧 task / 旧代次 / 别段的尝试）的次数，对不上的时间戳没记
  firstRequestAt?: number; wsOpenAt?: number; uiConnectedAt?: number   // 手机墙钟 ms，只做跨端对齐
  candidates?: ConnectCandidate[]
  candDropped?: number   // 候选只留最近 32 条，丢掉的条数
  busyMs?: number        // 入口 → 主线程进入 窗口内主线程 runloop 忙总和（双观察者，裁到 60s deadline）
  busyN50?: number       // 其中 >50ms 的块数
  busyMaxMs?: number
  busyWindowMs?: number  // 忙段实际覆盖的窗口长度
  busyCapped?: boolean   // 窗口超过 60s 被截断
  segs?: Record<string, number>   // 冷启动分段：各点距 AppEntry.main 的 ms（单调）；connect = 这一段的 entry
  preMainMs?: number     // 进程起点（p_starttime）→ AppEntry.main，墙钟；预热 / 读失败不给
  launchFail?: boolean   // p_starttime 读失败：旧 t0 / totalMs 是从连接入口算的，偏低
  launchSrc?: string     // prewarm | push | icon | voip | unknown
  recovery?: string[]    // 这次启动走过的恢复 / 迁移分支
}

export interface RunCounts { started: number; ok: number; replaced: number; reportFailed: number }

/// 尺子：每个探测候选。queue = 完成回调 → 排进主线程；handle = 主线程处理（赢家含开 WS）
export interface ConnectCandidate {
  id: string         // 「代次.序号」
  round: number      // probeGeneration
  h: string
  atMs?: number      // 入口 → 这个候选 resume
  taskMs?: number    // URLSessionTaskMetrics.taskInterval：task 创建 → 完成的生命周期（不是纯网络）
  cbMs?: number      // resume → 完成回调（单调，含委托队列调度）
  queueMs: number
  handleMs: number
  won: boolean
  late?: boolean     // 已有赢家后才到
}

/// 冷启动分段的固定顺序（app 端 LaunchMarks 名）和每段（上一点 → 这一点）的中文名
export const LAUNCH_SEGS: [string, string][] = [
  ["entry", "进程起点→入口"],
  ["props", "入口→属性初始化"],
  ["propProviders", "主题+Provider"],
  ["propCards", "卡库（属性）"],
  ["initBegin", "其余属性"],
  ["bootstrapEligible", "init→可早连（字体 + pending import）"],
  ["container", "可早连→建库完（archive 清理 + 建库）"],
  ["profiles", "楼层"],
  ["cards", "卡库（init）"],
  ["initEnd", "init 其余"],
  ["splashRelease", "init 完→开屏内容门"],
  ["contentAppear", "内容门→首屏 onAppear"],
  ["connect", "onAppear→开始连"],
]

export interface LaunchSeg { key: string; label: string; ms: number }

/// 冷启动逐段耗时。缺的点跳过（mac 没开屏），跨过缺点的段名写成「上一点→这一点」。
/// entry 段 = preMainMs（墙钟）；预热 / 读失败没有。按固定顺序出现负段 = 逆序（A2 会主动打乱顺序）→ ordered=false，不可分解。
export function launchSegments(r: ConnectReport): { segs: LaunchSeg[]; ordered: boolean } {
  const segs = r.segs
  if (!segs) return { segs: [], ordered: true }
  const out: LaunchSeg[] = []
  if (r.preMainMs !== undefined && !r.prewarm && !r.launchFail) out.push({ key: "entry", label: LAUNCH_SEGS[0][1], ms: r.preMainMs })
  let prev: string | undefined
  let prevIdx = -1
  LAUNCH_SEGS.forEach(([key, label], i) => {
    const at = segs[key]
    if (at === undefined) return
    if (prev !== undefined) {
      out.push({ key, label: prevIdx === i - 1 ? label : `${prev}→${key}`, ms: at - segs[prev] })
    }
    prev = key; prevIdx = i
  })
  return { segs: out, ordered: out.every(s => s.ms >= 0) }
}

/// 最终 WS 对应的探测候选（按 wsVia 找）；直连 / 没找到 → undefined
export function finalCandidate(r: ConnectReport): ConnectCandidate | undefined {
  if (!r.wsVia || r.wsVia === "direct") return undefined
  return r.candidates?.find(c => c.id === r.wsVia)
}

export interface LagEvent { at: number; ms: number }   // at = 卡顿结束时刻（hub 墙钟）

/// 卡顿环形记录：只留最近 15 分钟
export class LagLog {
  private events: LagEvent[] = []
  constructor(private readonly keepMs = 15 * 60_000) {}
  add(e: LagEvent): void {
    this.events.push(e)
    const cut = e.at - this.keepMs
    while (this.events.length && this.events[0].at < cut) this.events.shift()
  }
  list(): LagEvent[] { return this.events }
}

/// 卡顿区间 [at-ms, at] 与 [from, to] 的重叠毫秒和
export function lagOverlapMs(lags: LagEvent[], from: number, to: number): number {
  let sum = 0
  for (const l of lags) {
    const a = Math.max(l.at - l.ms, from), b = Math.min(l.at, to)
    if (b > a) sum += b - a
  }
  return sum
}

/// 给一次连接贴理由。快的返回 []；慢的至少一条（找不到就「未知」）。
export function classifyConnect(r: ConnectReport, ctx: { lags: LagEvent[]; hubStartedAt: number }): string[] {
  if (r.totalMs <= FAST_MS) return []
  const why: string[] = []
  if (ctx.hubStartedAt > r.t0 - 1_000) why.push(`hub 重启中（连接开始后 ${Math.max(0, ctx.hubStartedAt - r.t0)}ms 才起来）`)
  // 有尺子墙钟时只看「请求发出 → WS 打开」。两端墙钟未校准、窗口里还有 app 排队 / 退避：只能说时间上重叠（相关），不是成因
  if (r.rev !== undefined) {
    const lag = lagOverlapMs(ctx.lags, r.firstRequestAt ?? r.t0, r.wsOpenAt ?? r.openAt)
    if (lag >= 300) why.push(`hub 主循环卡顿与连接窗口重叠 ${lag}ms（相关，非因果）`)
  } else {
    const lag = lagOverlapMs(ctx.lags, r.t0, r.openAt)
    if (lag >= 300) why.push(`hub 主循环卡 ${lag}ms`)
  }
  const attempts = r.attempts ?? []
  const count = (pred: (a: ConnectAttempt) => boolean) => attempts.filter(pred).length
  const timeouts = count(a => a.r === "timeout")
  const notHub = attempts.filter(a => a.r.startsWith("nothub"))
  const refused = count(a => a.r === "refused")
  const ws = attempts.filter(a => a.r.startsWith("ws:"))
  const other = attempts.filter(a => a.r.startsWith("err:") || a.r === "unreachable")
  if (timeouts) why.push(`探测超时 ${timeouts} 次（${[...new Set(attempts.filter(a => a.r === "timeout").map(a => a.h))].join(", ")}）`)
  if (notHub.length) why.push(`代理替答 ${notHub.length} 次（${[...new Set(notHub.map(a => `${a.h} ${a.r.slice(7)}`))].join(", ")}）`)
  if (refused) why.push(`端口拒连 ${refused} 次（hub 没在听）`)
  if (ws.length) why.push(`握手失败 ${ws.length} 次（${[...new Set(ws.map(a => a.r.slice(3)))].join("; ")}）`)
  if (other.length) why.push(`网络错误 ${other.length} 次（${[...new Set(other.map(a => `${a.h} ${a.r}`))].join(", ")}）`)
  if ((r.waitMs ?? 0) >= 300) why.push(`退避等待 ${r.waitMs}ms`)
  if (r.rev !== undefined) why.push(...rulerReasons(r))
  else {
    if ((r.mainDelayMs ?? 0) >= 300) why.push(`app 主线程忙 ${r.mainDelayMs}ms`)
    if ((r.launchMs ?? 0) >= 500) why.push(`点开后 ${r.launchMs}ms app 才开始连`)
  }
  if (r.path && !/\ben\d/.test(r.path)) why.push(`不在 Wi-Fi（${r.path}）`)
  if (why.length === 0) why.push("未知（看 attempts）")
  return why
}

/// 有尺子字段时替代旧的「主线程忙 max / 点开后才开始连」两条：拆成启动某段慢 / 排主线程 / URLSession 生命周期 / WS 回调。
/// 各条是标签不是分解：忙段和排队会重叠，不能相加。
function rulerReasons(r: ConnectReport): string[] {
  const why: string[] = []
  if (r.trigger === "launch") {
    if (r.launchFail) why.push("进程起点读不到（全程从连接入口算，偏低）")
    const { segs, ordered } = launchSegments(r)
    if (!ordered) why.push("启动分段逆序（不可分解）")
    else for (const s of segs) if (s.ms >= 300) why.push(`启动慢：${s.label} ${s.ms}ms`)
  }
  if ((r.wsInvalid ?? 0) > 0) why.push(`WS 时间戳归属对不上 ${r.wsInvalid} 次（作废未记）`)
  if ((r.firstReqMs ?? 0) >= 300) why.push(`开始连→发出首个请求 ${r.firstReqMs}ms`)
  const win = finalCandidate(r)
  if (win) {
    if ((win.taskMs ?? 0) >= 300) why.push(`URLSession 任务生命周期 ${win.taskMs}ms（探测 ${win.h}）`)
    if (win.queueMs >= 300) why.push(`排主线程：探测结果等 ${win.queueMs}ms`)
    if (win.handleMs >= 300) why.push(`主线程处理探测结果（含开 WS）${win.handleMs}ms`)
  }
  if (r.wsResumeMs !== undefined && r.wsOpenMs !== undefined && r.wsOpenMs - r.wsResumeMs >= 300) {
    why.push(`WS resume→delegate 回调 ${r.wsOpenMs - r.wsResumeMs}ms`)
  }
  if (r.wsOpenMs !== undefined && r.uiMs !== undefined && r.uiMs - r.wsOpenMs >= 300) {
    why.push(`排主线程：连上后等 ${r.uiMs - r.wsOpenMs}ms`)
  }
  if (r.uiMs !== undefined && r.clientInfoMs !== undefined && r.clientInfoMs - r.uiMs >= 300) {
    why.push(`主线程进入→client_info 发出 ${r.clientInfoMs - r.uiMs}ms`)
  }
  if (r.busyCapped) why.push(`连接窗口超时截断（只记前 ${r.busyWindowMs ?? "?"}ms，其中主线程忙 ${r.busyMs ?? "?"}ms）`)
  else if ((r.busyMs ?? 0) >= 300) why.push(`连接窗口主线程忙 ${r.busyMs}ms（>50ms 块 ${r.busyN50 ?? 0} 个，最长 ${r.busyMaxMs ?? 0}ms）`)
  return why
}

/// 帧 → 报告；字段不对返回 null
export function parseConnectReport(o: any): ConnectReport | null {
  if (!o || typeof o !== "object") return null
  const num = (v: unknown) => typeof v === "number" && Number.isFinite(v) ? Math.round(v) : undefined
  const t0 = num(o.t0), openAt = num(o.open_at), totalMs = num(o.total_ms)
  if (t0 === undefined || openAt === undefined || totalMs === undefined) return null
  const attempts: ConnectAttempt[] = Array.isArray(o.attempts)
    ? o.attempts.filter((a: any) => typeof a?.h === "string" && typeof a?.r === "string")
        .slice(0, 50).map((a: any) => ({ h: a.h, r: a.r.slice(0, 120), ms: num(a.ms) ?? 0 }))
    : []
  return {
    trigger: typeof o.trigger === "string" ? o.trigger : "?",
    t0, openAt, totalMs,
    bgMs: num(o.bg_ms), waitMs: num(o.wait_ms), launchMs: num(o.launch_ms), mainDelayMs: num(o.main_delay_ms),
    prewarm: o.prewarm === true ? true : undefined,
    path: typeof o.path === "string" ? o.path : undefined,
    host: typeof o.host === "string" ? o.host : undefined,
    attempts,
    ...parseRuler(o, num),
  }
}

/// 尺子字段（connectV2）：没 rev 就当旧 app，一个都不出
function parseRuler(o: any, num: (v: unknown) => number | undefined): Partial<ConnectReport> {
  if (typeof o.rev !== "string") return {}
  const str = (v: unknown, max: number) => typeof v === "string" ? v.slice(0, max) : undefined
  const candidates: ConnectCandidate[] = Array.isArray(o.candidates)
    ? o.candidates.filter((c: any) => typeof c?.h === "string").slice(0, 50).map((c: any) => ({
        id: str(c.id, 24) ?? "?", round: num(c.round) ?? -1, h: c.h.slice(0, 120),
        atMs: num(c.at_ms), taskMs: num(c.task_ms), cbMs: num(c.cb_ms),
        queueMs: num(c.queue_ms) ?? 0, handleMs: num(c.handle_ms) ?? 0, won: c.won === true,
        ...(c.late === true ? { late: true } : {}),
      }))
    : []
  const record = (v: unknown, keep: (x: unknown) => any): Record<string, any> | undefined => {
    if (!v || typeof v !== "object" || Array.isArray(v)) return undefined
    const out: Record<string, any> = {}
    for (const [k, x] of Object.entries(v).slice(0, 64)) { const y = keep(x); if (y !== undefined) out[k.slice(0, 40)] = y }
    return out
  }
  const c = o.counts && typeof o.counts === "object" ? o.counts : undefined
  const out: Partial<ConnectReport> = {
    rev: str(o.rev, 40), build: str(o.build, 20), run: str(o.run, 40), dev: str(o.dev, 40), bin: str(o.bin, 40),
    sw: record(o.sw, x => typeof x === "string" ? x.slice(0, 40) : undefined), ep: num(o.ep),
    counts: c ? { started: num(c.started) ?? 0, ok: num(c.ok) ?? 0, replaced: num(c.replaced) ?? 0, reportFailed: num(c.report_failed) ?? 0 } : undefined,
    firstReqMs: num(o.first_req_ms), wsAttempt: num(o.ws_attempt), wsGen: num(o.ws_gen), wsVia: str(o.ws_via, 24),
    wsResumeMs: num(o.ws_resume_ms), wsOpenMs: num(o.ws_open_ms), uiMs: num(o.ui_ms), clientInfoMs: num(o.client_info_ms),
    finishMs: num(o.finish_ms), wsInvalid: num(o.ws_invalid),
    firstRequestAt: num(o.first_request_at), wsOpenAt: num(o.ws_open_at), uiConnectedAt: num(o.ui_connected_at),
    candidates, candDropped: num(o.cand_dropped),
    busyMs: num(o.busy_ms), busyN50: num(o.busy_n50), busyMaxMs: num(o.busy_max_ms), busyWindowMs: num(o.busy_window_ms),
    busyCapped: o.busy_capped === true ? true : undefined,
    segs: record(o.segs, num), preMainMs: num(o.pre_main_ms), launchFail: o.launch_fail === true ? true : undefined,
    launchSrc: str(o.launch_src, 20),
    recovery: Array.isArray(o.recovery) ? o.recovery.filter((x: unknown) => typeof x === "string").slice(0, 16).map((x: string) => x.slice(0, 60)) : undefined,
  }
  for (const k of Object.keys(out) as (keyof ConnectReport)[]) if (out[k] === undefined) delete out[k]
  return out
}

/// 统计口径版本（scripts/connect-ledger.ts 打在标题上）：r2 起分位数用 nearest-rank、按设备 × 包 × 开关分组
export const STATS_REV = "ledgerStats-r2"

/// 分组：同设备、同包（LC_UUID）、同开关才能比；不用 from（网络地址，中继统一 "relay"、换网就变）
export function rulerGroupKey(r: ConnectReport): string {
  const short = (s?: string) => s ? s.slice(0, 8) : "?"
  const sw = Object.entries(r.sw ?? {}).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${k}=${v}`).join(",")
  return `${r.trigger} · ${r.platform ?? "?"} · dev ${short(r.dev)} · bin ${short(r.bin)}(${r.build ?? "?"}) · sw{${sw}} · ${r.rev}`
}

/// 一组样本里每个进程（runId）取计数最大值再求和：开了几段 / 连上几段 / 被换掉几段 / 报告发送失败几份
export function runTotals(rows: ConnectReport[]): RunCounts & { runs: number } {
  const byRun = new Map<string, RunCounts>()
  for (const r of rows) {
    if (!r.run || !r.counts) continue
    const cur = byRun.get(r.run) ?? { started: 0, ok: 0, replaced: 0, reportFailed: 0 }
    byRun.set(r.run, {
      started: Math.max(cur.started, r.counts.started), ok: Math.max(cur.ok, r.counts.ok),
      replaced: Math.max(cur.replaced, r.counts.replaced), reportFailed: Math.max(cur.reportFailed, r.counts.reportFailed),
    })
  }
  const t = { started: 0, ok: 0, replaced: 0, reportFailed: 0, runs: byRun.size }
  for (const c of byRun.values()) { t.started += c.started; t.ok += c.ok; t.replaced += c.replaced; t.reportFailed += c.reportFailed }
  return t
}

/// 尺子拆分统计（scripts/connect-ledger.ts 用）：只取带 rev 的行；冷启动去掉预热。
/// 截断窗口的忙段、逆序的启动分段、ws 归属作废的都不进分位数，单独计数。
export type RulerMetric = { name: string; values: number[] }
export interface RulerSplit { metrics: RulerMetric[]; capped: number; disordered: number; invalid: number; prewarm: number }
export function rulerMetrics(rows: ConnectReport[]): RulerSplit {
  const m = new Map<string, number[]>()
  const add = (name: string, v: number | undefined) => { if (v !== undefined && Number.isFinite(v)) m.set(name, [...(m.get(name) ?? []), v]) }
  const res = { capped: 0, disordered: 0, invalid: 0, prewarm: 0 }
  for (const r of rows) {
    if (r.rev === undefined) continue
    if (r.trigger === "launch" && r.prewarm) { res.prewarm++; continue }
    if (r.trigger === "launch") {
      const { segs, ordered } = launchSegments(r)
      if (!ordered) res.disordered++
      else {
        for (const s of segs) add(`启动 ${s.label}`, s.ms)
        const pre = r.launchFail ? undefined : r.preMainMs
        const at = (k: string) => (pre === undefined || r.segs?.[k] === undefined) ? undefined : pre + r.segs[k]
        add("启动 进程起点→可早连", at("bootstrapEligible"))
        add("启动 进程起点→开始连", at("connect"))
        if (r.segs?.bootstrapEligible !== undefined && r.segs?.connect !== undefined) add("启动 可早连→开始连", r.segs.connect - r.segs.bootstrapEligible)
        const c = at("connect")
        if (c !== undefined && r.clientInfoMs !== undefined) add("全程 进程起点→client_info 发出", c + r.clientInfoMs)
      }
    }
    if ((r.wsInvalid ?? 0) > 0) res.invalid++
    add("开始连→首个请求", r.firstReqMs)
    const win = finalCandidate(r)
    add("探测 URLSession 任务生命周期", win?.taskMs)
    add("探测 resume→完成回调", win?.cbMs)
    add("探测 回调→主线程", win?.queueMs)
    add("探测 主线程处理（含开 WS）", win?.handleMs)
    if (r.wsResumeMs !== undefined && r.wsOpenMs !== undefined) add("WS resume→delegate 回调", r.wsOpenMs - r.wsResumeMs)
    if (r.wsOpenMs !== undefined && r.uiMs !== undefined) add("WS 回调→主线程进入", r.uiMs - r.wsOpenMs)
    if (r.uiMs !== undefined && r.clientInfoMs !== undefined) add("主线程进入→client_info", r.clientInfoMs - r.uiMs)
    add("开始连→主线程进入", r.uiMs)
    add("开始连→client_info 发出（终点）", r.clientInfoMs)
    if (r.busyCapped) res.capped++
    else { add("窗口主线程忙", r.busyMs); add("窗口 >50ms 块数", r.busyN50) }
  }
  return { metrics: [...m].map(([name, values]) => ({ name, values: values.sort((a, b) => a - b) })), ...res }
}

/// 分位数：nearest-rank（第 ⌈p·n⌉ 小的那个样本，取真实样本值、不插值）。n=4 时 p50 是第 2 个、p75 是第 3 个
export function quantile(sorted: number[], p: number): number {
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(p * sorted.length) - 1))]
}

/// 一行分布：n<5 直接列原始值（小样本的分位数会被单条极值决定）
export function describeDist(sorted: number[]): string {
  if (sorted.length < 5) return `n=${sorted.length}  原始值 ${sorted.join(" / ")}`
  return `n=${String(sorted.length).padStart(3)}  p50 ${quantile(sorted, 0.5)}  p75 ${quantile(sorted, 0.75)}  p90 ${quantile(sorted, 0.9)}`
}

/// 终端出字（plan-hub-instant-connect §六）：从点开某个终端到第一屏文字画出来。
/// app 拆三段自报（等布局 / 等桥 / 全程），hub 在 terminal_init 里带下自己处理 attach 花的时间和分步。
export interface TerminalReport {
  trigger: "terminal"
  session: string
  t0: number         // 手机墙钟 ms：终端页出现
  openAt: number     // 手机墙钟 ms：第一屏画完
  totalMs: number
  layoutMs?: number  // 出现 → 发 attach（等 SwiftTerm 给出真实行列，兜底 2s）
  bridgeMs?: number  // 发 attach 时桥没连上，等到连上的时长
  hubMs?: number     // hub 收到 attach → 发出 terminal_init
  hubSteps?: string  // hub 分步，如 "size=3 resize=260 pipe=12 capture=40"
  platform?: string
}

export function parseTerminalReport(o: any): TerminalReport | null {
  if (!o || typeof o !== "object" || typeof o.session !== "string") return null
  const num = (v: unknown) => typeof v === "number" && Number.isFinite(v) ? Math.round(v) : undefined
  const t0 = num(o.t0), openAt = num(o.open_at), totalMs = num(o.total_ms)
  if (t0 === undefined || openAt === undefined || totalMs === undefined) return null
  return {
    trigger: "terminal", session: o.session.slice(0, 80), t0, openAt, totalMs,
    layoutMs: num(o.layout_ms), bridgeMs: num(o.bridge_ms), hubMs: num(o.hub_ms),
    hubSteps: typeof o.hub_steps === "string" ? o.hub_steps.slice(0, 120) : undefined,
  }
}

export function classifyTerminalOpen(r: TerminalReport, ctx: { lags: LagEvent[] }): string[] {
  if (r.totalMs <= FAST_MS) return []
  const why: string[] = []
  const layout = r.layoutMs ?? 0, bridge = r.bridgeMs ?? 0, hub = r.hubMs ?? 0
  if (layout >= 300) why.push(`app 等终端布局 ${layout}ms`)
  if (bridge >= 300) why.push(`桥没连上 ${bridge}ms`)
  if (hub >= 300) why.push(`hub 开终端 ${hub}ms（${r.hubSteps ?? "?"}）`)
  const lag = lagOverlapMs(ctx.lags, r.t0, r.openAt)
  if (lag >= 300) why.push(`hub 主循环卡 ${lag}ms`)
  const rest = r.totalMs - layout - bridge - hub
  if (rest >= 300) why.push(`传输 / 排队 / 画屏 ${rest}ms`)
  if (why.length === 0) why.push("未知（各段都不到 300ms）")
  return why
}

export function appendLedger(path: string, entry: object): void {
  try { appendFileSync(path, JSON.stringify(entry) + "\n") } catch (e: any) { console.warn(`[hub] connect ledger write fail: ${e?.message}`) }
}
