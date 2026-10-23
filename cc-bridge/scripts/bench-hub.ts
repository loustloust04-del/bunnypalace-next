#!/usr/bin/env bun
/// bench hub（docs/plan-hub-perf.md §3.3）：起一个完全隔离的 hub，模拟粟粟的三个操作跑 N 轮，出 p50/p75/p95 + loop lag + 阻塞调用账。
///
///   bun scripts/bench-hub.ts [--rounds 12] [--sessions 27] [--k1 1,0,1,0] [--profile idle|stress] [--out x.json] [--keep]
///
/// - A 打开连上：new WebSocket → open（随即发 client_info）；另记收到 hello 的时刻
/// - B 终端出字：发 terminal_attach → 收到 terminal_init；然后 terminal_detach
/// - C 发消息：发 send 帧 → 假 CC 读到这一行（= 文本进了输入框且回车了）
/// --k1 是组序列，每组单独起一个 hub（MP_HUB_PERF_K1 进程启动读一次）；同档两组 = A/A 噪声带。
///
/// 隔离（逐项见 perf/hub-实验日志.md「基线 · 空闲档」）：
/// - hub 进程的 env 是白名单拼的，不继承本 shell：HOME / TMPDIR / TMUX_TMPDIR / secrets / 工作目录 / spool 全在临时目录
/// - tmux 用 TMUX_TMPDIR 整体隔离（hub 的同步 execFileSync 不认 MP_CC_TMUX_SOCKET），结束只 kill 这个目录下的 server
/// - 会话里跑的是假 CC（/bin/sh 读一行记一行）；PATH 最前面放假 claude / codex，万一 hub 去 spawn 也只会记账，bench 判红
/// - 端口随机（≠7890），只连 127.0.0.1；APNs 钥匙指向不存在的文件 + host 指向 127.0.0.1:9
///
/// ⚠️ --profile stress 会把整机压到负载 >80、吃几个 G 内存：她的 CC、手机连 hub、终端都会变卡。
///    必须先问粟粟，再加 --confirm-stress 才跑。
import { appendFileSync, chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync, openSync, readSync, closeSync } from "node:fs"
import { createServer } from "node:net"
import { loadavg, tmpdir } from "node:os"
import { join } from "node:path"

// 本进程连 127.0.0.1 不许走代理（本机 shell 带 http_proxy，Bun fetch 会认）
for (const k of ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"]) delete process.env[k]
process.env.NO_PROXY = process.env.no_proxy = "127.0.0.1,localhost"

// ── 参数 ──
const argv = process.argv.slice(2)
const opt = (k: string, d: string) => { const i = argv.indexOf(k); return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d }
const flag = (k: string) => argv.includes(k)
const ROUNDS = Number(opt("--rounds", "12"))
const SESSIONS = Number(opt("--sessions", "27"))
const K1_SEQ = opt("--k1", "1,0,1,0").split(",").map(s => s.trim())
const PROFILE = opt("--profile", "idle")
const OUT = opt("--out", "")
const KEEP = flag("--keep")
const COLS = Number(opt("--cols", "46")), ROWS = Number(opt("--rows", "40"))
const OP_TIMEOUT_MS = Number(opt("--timeout-ms", "20000"))
const GAP_MS = Number(opt("--gap-ms", "300"))
const STRESS_CPU = Number(opt("--stress-cpu", "100"))
const STRESS_MEM_GB = Number(opt("--stress-mem-gb", "4"))
const STRESS_LOAD = Number(opt("--stress-load", "80"))
const SWAP_FLOOR_MB = 1536
const STRESS_RAMP_MAX_MS = 15 * 60_000

if (!Number.isInteger(ROUNDS) || ROUNDS < 1 || !Number.isInteger(SESSIONS) || SESSIONS < 1 || SESSIONS > 99) throw new Error("--rounds / --sessions 不合法")
if (K1_SEQ.some(k => k !== "0" && k !== "1")) throw new Error("--k1 只认 0 / 1（逗号分隔的组序列）")
if (PROFILE !== "idle" && PROFILE !== "stress") throw new Error("--profile 只认 idle / stress")
if (PROFILE === "stress" && !flag("--confirm-stress")) {
  console.error("压力档会让整机变卡（负载 >80、吃内存），先问粟粟，同意后加 --confirm-stress 再跑")
  process.exit(2)
}

// ── 小工具 ──
const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms))
const sh = (cmd: string[], env?: Record<string, string>): { out: string; code: number } => {
  const r = Bun.spawnSync(cmd, { env, stdout: "pipe", stderr: "pipe" })
  return { out: r.stdout.toString() + r.stderr.toString(), code: r.exitCode ?? -1 }
}
function machineState() {
  const [l1, l5, l15] = loadavg()
  return {
    at: new Date().toISOString(),
    uptime: sh(["/usr/bin/uptime"]).out.trim(),
    swap: sh(["/usr/sbin/sysctl", "-n", "vm.swapusage"]).out.trim(),
    load: [l1, l5, l15].map(x => Math.round(x * 100) / 100),
  }
}
async function freePort(): Promise<number> {
  for (;;) {
    const port = await new Promise<number>((resolve, reject) => {
      const s = createServer()
      s.once("error", reject)
      s.listen(0, "127.0.0.1", () => { const a = s.address(); const p = typeof a === "object" && a ? a.port : 0; s.close(() => resolve(p)) })
    })
    if (port && port !== 7890) return port
  }
}
/// 粟粟的默认 tmux server：只读计数（不带 TMUX_TMPDIR / TMUX）
function defaultTmuxCount(): number {
  const env: Record<string, string> = {}
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined && k !== "TMUX" && k !== "TMUX_PANE" && k !== "TMUX_TMPDIR") env[k] = v
  return sh(["tmux", "ls"], env).out.split("\n").filter(l => /^[^:]+: \d+ windows/.test(l)).length
}
/// 生产 hub 还在不在（只读：lsof 看 7890 的监听进程，不发任何请求）
function prodHubPids(): string {
  return sh(["/usr/sbin/lsof", "-nP", "-iTCP:7890", "-sTCP:LISTEN", "-t"]).out.trim().split("\n").filter(Boolean).sort().join(",")
}
function pct(xs: number[], p: number): number | null {
  if (!xs.length) return null
  const s = [...xs].sort((a, b) => a - b)
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil(p * s.length) - 1))]
}
const r0 = (x: number) => Math.round(x)

// ── 隔离目录 ──
// tmux socket 路径有 104 字节上限：scratchpad 太长，用系统 tmpdir 下的短目录
const ROOT = mkdtempSync(join(tmpdir(), "mpbench-"))
const HOME = join(ROOT, "home")
const FAKEBIN = join(HOME, ".local", "bin")
const TMP = join(ROOT, "tmp")
const TMUXDIR = join(ROOT, "tmux")
const RECV = join(ROOT, "recv")
const FAKE_LOG = join(ROOT, "fake-invoked.log")
for (const d of [HOME, FAKEBIN, TMP, TMUXDIR, RECV]) mkdirSync(d, { recursive: true })
const SOCKET = join(TMUXDIR, `tmux-${process.getuid!()}`, "default")
if (SOCKET.length >= 104) throw new Error(`tmux socket 路径太长：${SOCKET}`)

// 假 claude / codex：万一 hub 去 spawn，只记一笔然后挂着（bench 看到这个文件非空就判红）
for (const name of ["claude", "codex"]) {
  const p = join(FAKEBIN, name)
  writeFileSync(p, `#!/bin/sh\necho "$(date +%s) ${name} $*" >> '${FAKE_LOG}'\nexec sleep 3600\n`)
  chmodSync(p, 0o755)
}
// 假 CC：读一行（hub 注入的文本 + 回车）追加到日志，回一行短确认
const FAKE_CC = join(ROOT, "fake-cc.sh")
writeFileSync(FAKE_CC, `#!/bin/sh\nlog="$1"\nprintf 'fake-cc ready\\n'\nwhile IFS= read -r line; do\n  printf '%s\\n' "$line" >> "$log"\n  printf 'ok\\n'\ndone\n`)
chmodSync(FAKE_CC, 0o755)

const PATH = [FAKEBIN, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(":")
/// 白名单 env：不继承本 shell 的任何东西（TMUX、口令、API key、CLAUDE_CONFIG_DIR…）
const baseEnv: Record<string, string> = {
  PATH, HOME, TMPDIR: TMP + "/", TMUX_TMPDIR: TMUXDIR, SHELL: "/bin/sh",
  USER: process.env.USER ?? "bench", LOGNAME: process.env.USER ?? "bench", LANG: "en_US.UTF-8",
}
const tmux = (args: string[]) => sh(["tmux", "-u", ...args], baseEnv)
const sessionNames = Array.from({ length: SESSIONS }, (_, i) => `mp-cc-bench${String(i + 1).padStart(2, "0")}`)
const recvPath = (s: string) => join(RECV, `${s}.log`)

// ── 清理（任何退出路径都走） ──
let hubProc: ReturnType<typeof Bun.spawn> | null = null
const stressProcs: Array<ReturnType<typeof Bun.spawn>> = []
let cleaned = false
function cleanup(): void {
  if (cleaned) return
  cleaned = true
  try { hubProc?.kill("SIGKILL") } catch {}
  for (const p of stressProcs) { try { p.kill("SIGKILL") } catch {} }
  // 只 kill 自己 TMUX_TMPDIR 下的 server：socket 必须在 ROOT 里才动
  if (existsSync(SOCKET) && SOCKET.startsWith(ROOT)) tmux(["kill-server"])
  if (!KEEP) { try { rmSync(ROOT, { recursive: true, force: true }) } catch {} }
}
process.on("exit", cleanup)
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(sig, () => { cleanup(); process.exit(130) })

// ── 压力档（只在 --confirm-stress 时跑） ──
async function startStress(deadlineSec: number): Promise<Record<string, unknown>> {
  // CPU：perl 忙等，自带截止时间（bench 崩了也会自己退）
  for (let i = 0; i < STRESS_CPU; i++) {
    stressProcs.push(Bun.spawn(["/usr/bin/perl", "-e", `my $e=time+${deadlineSec}; 1 while time<$e`], { stdout: "ignore", stderr: "ignore" }))
  }
  // 内存：256MB 一块往上加，每块前看 swap 余量（< 1.5G 就不再加），之后每 10s 把每页摸一遍保持常驻；同样自带截止
  const memScript = `
    const target = ${STRESS_MEM_GB} * 1024, floor = ${SWAP_FLOOR_MB}, end = Date.now() + ${deadlineSec * 1000}
    const free = () => { const m = /free = ([\\d.]+)M/.exec(Bun.spawnSync(["/usr/sbin/sysctl","-n","vm.swapusage"]).stdout.toString()); return m ? Number(m[1]) : 0 }
    const blocks = []
    while (blocks.length * 256 < target && free() > floor) { const b = Buffer.alloc(256 * 1024 * 1024, 1); blocks.push(b) }
    console.log("mem-hog " + blocks.length * 256 + "MB")
    const touch = () => { for (const b of blocks) for (let i = 0; i < b.length; i += 4096) b[i] = (b[i] + 1) & 255; if (Date.now() > end) process.exit(0); setTimeout(touch, 10000) }
    touch()`
  const mem = Bun.spawn([process.execPath, "-e", memScript], { stdout: "pipe", stderr: "ignore", env: baseEnv })
  stressProcs.push(mem)
  // 口径是 5 分钟负载 >STRESS_LOAD：100 个忙等进程从 ~2 爬到 80 约 8–10 分钟，最多等 15 分钟
  const t0 = Date.now()
  while (loadavg()[1] < STRESS_LOAD && Date.now() - t0 < STRESS_RAMP_MAX_MS) await sleep(5_000)
  return { cpuProcs: STRESS_CPU, memTargetGB: STRESS_MEM_GB, rampMs: Date.now() - t0, reached: loadavg()[1] >= STRESS_LOAD, machine: machineState() }
}

// ── 一个 WS 客户端（只认这次连的这个端口） ──
class Client {
  ws: WebSocket
  frames: Array<{ at: number; msg: any }> = []
  waiters: Array<{ pred: (m: any) => boolean; resolve: (m: { at: number; msg: any }) => void }> = []
  firstFrameAt = 0
  constructor(url: string) {
    this.ws = new WebSocket(url)
    this.ws.onmessage = (ev) => {
      const at = performance.now()
      if (!this.firstFrameAt) this.firstFrameAt = at
      let msg: any
      try { msg = JSON.parse(String(ev.data)) } catch { return }
      const w = this.waiters.findIndex(x => x.pred(msg))
      if (w >= 0) { const [x] = this.waiters.splice(w, 1); x.resolve({ at, msg }) }
      else this.frames.push({ at, msg })
    }
  }
  open(): Promise<number> {
    return new Promise((resolve, reject) => {
      this.ws.onopen = () => resolve(performance.now())
      this.ws.onerror = () => reject(new Error("ws error"))
      this.ws.onclose = (e) => reject(new Error(`ws closed ${e.code}`))
    })
  }
  wait(pred: (m: any) => boolean): Promise<{ at: number; msg: any }> {
    const i = this.frames.findIndex(f => pred(f.msg))
    if (i >= 0) return Promise.resolve(this.frames.splice(i, 1)[0])
    return new Promise(resolve => this.waiters.push({ pred, resolve }))
  }
  send(o: object): void { this.ws.send(JSON.stringify(o)) }
  async close(): Promise<void> {
    if (this.ws.readyState === WebSocket.CLOSED) return
    await Promise.race([new Promise<void>(r => { this.ws.onclose = () => r(); this.ws.close() }), sleep(2_000)])
  }
}
async function withTimeout<T>(p: Promise<T>, what: string): Promise<T> {
  let t: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([p, new Promise<T>((_, rej) => { t = setTimeout(() => rej(new Error(`${what} 超时 ${OP_TIMEOUT_MS}ms`)), OP_TIMEOUT_MS) })])
  } finally { if (t) clearTimeout(t) }
}
/// 等假 CC 的日志里出现 nonce（2ms 轮询文件尺寸，只读新增部分）
async function waitLine(session: string, nonce: string, fromSize: number): Promise<number> {
  const p = recvPath(session)
  const deadline = Date.now() + OP_TIMEOUT_MS + 1_000
  let off = fromSize, buf = ""
  while (Date.now() < deadline) {
    let size = 0
    try { size = statSync(p).size } catch {}
    if (size > off) {
      const fd = openSync(p, "r")
      const chunk = Buffer.alloc(size - off)
      readSync(fd, chunk, 0, chunk.length, off)
      closeSync(fd)
      off = size
      buf += chunk.toString("utf8")
      if (buf.includes(nonce)) return performance.now()
    }
    await sleep(2)
  }
  return Number.NaN   // 超时：外面的 withTimeout 已经判失败
}
const fileSize = (p: string) => { try { return statSync(p).size } catch { return 0 } }

interface Sample { round: number; session: string; A: number; hello: number; B: number; bHub: number | null; bSteps: string | null; C: number; ack: number }
interface Health { ok: boolean; tmuxCtl?: { state: string; ctl: number; fork: number }; bench?: { lags: Array<{ at: number; ms: number }>; block: Array<[string, { count: number; totalMs: number; maxMs: number }]> } }

async function health(port: number): Promise<Health | null> {
  try { const r = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(5_000) }); return r.ok ? await r.json() as Health : null } catch { return null }
}

async function round(port: number, session: string, r: number): Promise<Sample> {
  // A：连上 + client_info
  const tA = performance.now()
  const c = new Client(`ws://127.0.0.1:${port}/cc`)
  const openAt = await withTimeout(c.open(), "A open")
  c.send({ type: "client_info", platform: "bench" })
  const helloAt = (await withTimeout(c.wait(m => m?.type === "hello"), "A hello")).at
  try {
    // B：terminal_attach → terminal_init
    const tB = performance.now()
    c.send({ type: "terminal_attach", session_name: session, cols: COLS, rows: ROWS })
    const init = await withTimeout(c.wait(m => (m?.type === "terminal_init" || m?.type === "terminal_error") && m.session_name === session), "B terminal_init")
    if (init.msg.type !== "terminal_init") throw new Error(`B terminal_error: ${init.msg.reason}`)
    const B = init.at - tB
    c.send({ type: "terminal_detach", session_name: session })
    // C：send 帧 → 假 CC 读到这一行
    const nonce = `bench-${process.pid}-${r}-${Math.random().toString(36).slice(2, 8)}`
    const from = fileSize(recvPath(session))
    const tC = performance.now()
    c.send({ type: "send", session_name: session, chat_id: `bench-chat-${session}`, message_id: nonce, user: "bench", content: `bench 测量 ${nonce}` })
    const line = waitLine(session, nonce, from)
    const ack = await withTimeout(c.wait(m => (m?.type === "ack" || m?.type === "error") && m.message_id === nonce), "C ack")
    if (ack.msg.type !== "ack") throw new Error(`C error: ${ack.msg.reason}`)
    const lineAt = await withTimeout(line, "C 假 CC 收到")
    return { round: r, session, A: openAt - tA, hello: helloAt - tA, B, bHub: init.msg.hub_ms ?? null, bSteps: init.msg.hub_steps ?? null, C: lineAt - tC, ack: ack.at - tC }
  } finally { await c.close() }
}

function blockDiff(before: Health["bench"], after: Health["bench"]) {
  // 调用点名里带 fifo 的随机目录（execSite 取第一个参数），归成一类
  const norm = (k: string) => k.replace(/\S*\/cc-bridge-\w+\//g, "…/")
  const sum = (rows: NonNullable<Health["bench"]>["block"]) => {
    const m = new Map<string, { count: number; totalMs: number; maxMs: number }>()
    for (const [k, s] of rows) {
      const o = m.get(norm(k)) ?? { count: 0, totalMs: 0, maxMs: 0 }
      m.set(norm(k), { count: o.count + s.count, totalMs: o.totalMs + s.totalMs, maxMs: Math.max(o.maxMs, s.maxMs) })
    }
    return m
  }
  const b = sum(before?.block ?? [])
  return [...sum(after?.block ?? [])].map(([k, s]) => {
    const o = b.get(k) ?? { count: 0, totalMs: 0, maxMs: 0 }
    return { site: k, count: s.count - o.count, totalMs: r0(s.totalMs - o.totalMs), maxMsSinceStart: r0(s.maxMs) }
  }).filter(x => x.count > 0).sort((x, y) => y.totalMs - x.totalMs).slice(0, 10)
}

async function runGroup(gi: number, k1: string) {
  const g = join(ROOT, `g${gi}`)
  const dirs = { secrets: join(g, "secrets"), agent: join(g, "agent"), cc: join(g, "cc-rp"), codex: join(g, "gpt-rp"), spool: join(g, "spool"), mem: join(g, "memsync"), pmq: join(g, "pmq"), ax: join(g, "axismundi"), wcc: join(g, "warroom-cc"), wcx: join(g, "warroom-codex") }
  for (const d of Object.values(dirs)) mkdirSync(d, { recursive: true })
  tmux(["kill-session", "-t", "_mp-hub-ctl"])   // 上一组 K1 hub 留下的控制会话，别让下一组多一个会话
  const port = await freePort()
  const env: Record<string, string> = {
    ...baseEnv,
    MP_CC_HUB_TOKEN: `bench-${Math.random().toString(36).slice(2)}`, MP_CC_HUB_PORT: String(port), MP_CC_HUB_HOST: "127.0.0.1",
    MP_CC_SECRETS_DIR: dirs.secrets, MP_CC_AGENT_DIR: dirs.agent, MP_CC_WORKDIR: dirs.cc, MP_CODEX_WORKDIR: dirs.codex,
    MP_CC_THINKING_SPOOL: dirs.spool, CC_MEMORY_SYNC_DIR: dirs.mem, MP_PM_Q: dirs.pmq, MP_PM_URL: "http://127.0.0.1:9",
    MP_APNS_KEY_PATH: join(g, "no-such-key.p8"), MP_APNS_HOST: "https://127.0.0.1:9", MP_CC_LA_INTERVAL_MS: "3600000",
    MP_CC_WARROOM: "0", MP_CC_WARROOM_CC_ROOT: dirs.wcc, MP_CC_WARROOM_CODEX_ROOT: dirs.wcx,
    MP_CC_RELAY_CONNECTOR: "off", MP_CC_NUDGE_ENABLED: "0", MP_CC_KEEPALIVE: "0", MP_CC_DEFAULT_TRANSPORT: "tmux",
    MP_CLAUDE_BIN: join(FAKEBIN, "claude"), MP_AXISMUNDI_DIR: dirs.ax,
    MP_HUB_PERF_K1: k1, MP_HUB_BENCH: "1",
  }
  const log = join(g, "hub.log")
  const before = machineState()
  const tStart = Date.now()
  hubProc = Bun.spawn([process.execPath, "run", join(import.meta.dir, "..", "hub.ts")], { cwd: g, env, stdout: "pipe", stderr: "pipe" })
  for (const s of [hubProc.stdout, hubProc.stderr]) {
    if (!(s instanceof ReadableStream)) continue
    void (async () => { for await (const ch of s) appendFileSync(log, ch) })()
  }
  // 起来：/health 通；K1=1 再等控制连接 ready（最多 10s）
  let h: Health | null = null
  while (Date.now() - tStart < 60_000) {
    if (hubProc.exitCode !== null) throw new Error(`g${gi} hub 起不来 exit=${hubProc.exitCode}：${readFileSync(log, "utf8").slice(-2000)}`)
    h = await health(port)
    if (h?.ok) break
    await sleep(100)
  }
  if (!h?.ok) throw new Error(`g${gi} hub 60s 没起来`)
  const healthyMs = Date.now() - tStart
  if (!h.bench) throw new Error("hub 没带 bench 字段（MP_HUB_BENCH 没生效？）")
  if (k1 === "1") { const t = Date.now(); while (h?.tmuxCtl?.state !== "ready" && Date.now() - t < 10_000) { await sleep(200); h = await health(port) } }
  await sleep(3_000)   // 让启动期的定时器 / 首轮会话表落地
  await round(port, sessionNames[0], -1)   // 热身一轮，丢掉
  const hBefore = await health(port)
  const samples: Sample[] = []
  const failures: string[] = []
  const t0 = Date.now()
  for (let r = 0; r < ROUNDS; r++) {
    const s = sessionNames[r % sessionNames.length]
    try { samples.push(await round(port, s, r)) } catch (e) { failures.push(`r${r} ${s}: ${(e as Error).message}`) }
    await sleep(GAP_MS)
  }
  const t1 = Date.now()
  await sleep(700)   // 最后一段卡顿要等下一个 500ms 探针才记
  const hAfter = await health(port)
  // 用 capture 抽验最后一条确实进了 pane（假 CC 回显）
  const lastS = sessionNames[(ROUNDS - 1) % sessionNames.length]
  const lastNonce = samples.length ? samples[samples.length - 1] : null
  const pane = tmux(["capture-pane", "-t", lastS, "-p", "-J", "-S", "-50"]).out
  const captureOk = !!lastNonce && pane.includes(`bench-${process.pid}-${lastNonce.round}-`)
  hubProc.kill("SIGTERM")
  await Promise.race([hubProc.exited, sleep(5_000)])
  if (hubProc.exitCode === null) hubProc.kill("SIGKILL")
  await hubProc.exited
  hubProc = null
  const logText = readFileSync(log, "utf8")
  const lags = (hAfter?.bench?.lags ?? []).filter(l => l.at >= t0 && l.at - l.ms <= t1 + 600)
  const red: string[] = []
  if (failures.length) red.push(`${failures.length} 轮失败`)
  if (/spawned tmux:|stream spawn /.test(logText)) red.push("hub spawn 了会话（应该只用现成的假 CC）")
  if (existsSync(FAKE_LOG) && readFileSync(FAKE_LOG, "utf8").trim()) red.push("假 claude / codex 被调用过")
  if (/FATAL/.test(logText)) red.push("hub FATAL")
  if (!captureOk) red.push("capture 抽验没看到最后一条")
  return {
    group: gi, k1, port, healthyMs, tmuxCtl: hAfter?.tmuxCtl ?? null,
    machineBefore: before, machineAfter: machineState(), windowMs: t1 - t0,
    samples, failures, red,
    lag: { over200: lags.length, maxMs: lags.reduce((m, l) => Math.max(m, l.ms), 0), list: lags },
    block: blockDiff(hBefore?.bench, hAfter?.bench),
    blockLogLines: logText.split("\n").filter(l => l.includes("[block]") || l.includes("loop lag")).slice(0, 20),
  }
}

// ── 主流程 ──
const ops = ["A", "hello", "B", "C", "ack"] as const
function stats(samples: Sample[]) {
  const o: Record<string, { n: number; p50: number | null; p75: number | null; p95: number | null; max: number | null }> = {}
  for (const k of ops) {
    const xs = samples.map(s => s[k])
    const f = (v: number | null) => v === null ? null : r0(v)
    o[k] = { n: xs.length, p50: f(pct(xs, 0.5)), p75: f(pct(xs, 0.75)), p95: f(pct(xs, 0.95)), max: f(pct(xs, 1)) }
  }
  return o
}

const tmuxBefore = defaultTmuxCount()
const prodBefore = prodHubPids()
console.log(`[bench] root=${ROOT} socket=${SOCKET}`)
console.log(`[bench] 默认 tmux server 会话数 ${tmuxBefore}（只读）；生产 hub 监听进程 ${prodBefore || "无"}（只读 lsof，不发请求）`)

// 隔离 tmux server + N 个假 CC 会话（窗口直接建成手机尺寸：B 测的是不 resize 的常态路径）
for (const s of sessionNames) {
  const r = tmux(["new-session", "-d", "-s", s, "-x", String(COLS), "-y", String(ROWS), `/bin/sh '${FAKE_CC}' '${recvPath(s)}'`])
  if (r.code !== 0) throw new Error(`建会话 ${s} 失败：${r.out}`)
}
if (!existsSync(SOCKET)) throw new Error(`隔离 socket 不在预期位置：${SOCKET}`)
const listed = tmux(["ls", "-F", "#{session_name}"]).out.trim().split("\n")
if (listed.length !== SESSIONS) throw new Error(`隔离 server 会话数 ${listed.length} ≠ ${SESSIONS}`)

const stress = PROFILE === "stress" ? await startStress(STRESS_RAMP_MAX_MS / 1000 + K1_SEQ.length * (ROUNDS * 5 + 120) + 300) : null
const groups = []
for (let i = 0; i < K1_SEQ.length; i++) {
  const g = await runGroup(i, K1_SEQ[i])
  console.log(`[bench] g${i} K1=${g.k1} ${g.samples.length}/${ROUNDS} 轮 lag>200 ${g.lag.over200} 次 max ${g.lag.maxMs}ms ${g.red.length ? `RED: ${g.red.join("；")}` : "GREEN"}`)
  groups.push(g)
}
const arms: Record<string, ReturnType<typeof stats>> = {}
for (const k of new Set(K1_SEQ)) arms[`K1=${k}`] = stats(groups.filter(g => g.k1 === k).flatMap(g => g.samples))
// 噪声带：同档相邻两组的 p75 差 / 两组均值
const noise: Record<string, Record<string, number | null>> = {}
for (const k of new Set(K1_SEQ)) {
  const gs = groups.filter(g => g.k1 === k)
  if (gs.length < 2) continue
  const [a, b] = [stats(gs[0].samples), stats(gs[1].samples)]
  noise[`K1=${k}`] = Object.fromEntries(ops.map(op => {
    const x = a[op].p75, y = b[op].p75
    return [op, x === null || y === null || x + y === 0 ? null : Math.round(200 * Math.abs(x - y) / (x + y))]
  }))
}
const tmuxAfter = defaultTmuxCount()
const prodAfter = prodHubPids()
const result = {
  argv, profile: PROFILE, rounds: ROUNDS, sessions: SESSIONS, k1Seq: K1_SEQ, cols: COLS, rows: ROWS, stress,
  guard: { defaultTmuxBefore: tmuxBefore, defaultTmuxAfter: tmuxAfter, prodHubBefore: prodBefore, prodHubAfter: prodAfter },
  groups: groups.map(g => ({ ...g, stats: stats(g.samples) })), arms, noiseP75Pct: noise,
}

console.log("\n组    K1  操作    n   p50   p75   p95   max  (ms)")
for (const g of result.groups) for (const op of ops) {
  const s = g.stats[op]
  console.log(`g${g.group}    ${g.k1}   ${op.padEnd(6)} ${String(s.n).padStart(2)} ${String(s.p50).padStart(5)} ${String(s.p75).padStart(5)} ${String(s.p95).padStart(5)} ${String(s.max).padStart(5)}`)
}
console.log("\n合并（每档两组）")
for (const [arm, st] of Object.entries(arms)) for (const op of ops) {
  const s = st[op]
  console.log(`${arm}  ${op.padEnd(6)} ${String(s.n).padStart(2)} ${String(s.p50).padStart(5)} ${String(s.p75).padStart(5)} ${String(s.p95).padStart(5)} ${String(s.max).padStart(5)}`)
}
console.log(`\n噪声带（同档两组 p75 相对差 %）：${JSON.stringify(noise)}`)
console.log(`默认 tmux 会话数 ${tmuxBefore} → ${tmuxAfter}；生产 hub ${prodBefore} → ${prodAfter}`)
if (OUT) { writeFileSync(OUT, JSON.stringify(result, null, 2)); console.log(`[bench] 结果 → ${OUT}`) }
// 默认 server 会话数 / 生产 hub 进程只记录不判红：她别的 session 开关窗口也会让它变
const red = result.groups.some(g => g.red.length)
cleanup()
process.exit(red ? 1 : 0)
