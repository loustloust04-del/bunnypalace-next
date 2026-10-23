import { afterAll, beforeAll, expect, test } from "bun:test"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { buildChannelTag, claudeTranscriptPath, ensureSessionAndSendAsync, realTmuxRunner, sendStatusBook, SessionExistsError, sessionMap, setTmuxRunner, tmuxState } from "./hub"
import { startSharedTmuxControl, stopSharedTmuxControl, tmuxRunCounts } from "./tmux-control"

// K1 第 4 步：发消息（send-keys -l / Enter / paste / capture）、spawn / kill / key / capture 走 tmuxRun。
// 真 tmux，独立 socket（-L），永不碰默认 server；两档：ctl = 控制连接就绪，fork = K1=0（fork-async）
const SOCKET = `mp-hsend-${process.pid}-${Math.random().toString(36).slice(2, 6)}`
const PREFIX = ["-L", SOCKET]
const savedEnv = { socket: process.env.MP_CC_TMUX_SOCKET, k1: process.env.MP_HUB_PERF_K1 }
process.env.MP_CC_TMUX_SOCKET = SOCKET
delete process.env.MP_HUB_PERF_K1
const SERVER_PATH = `${process.env.PATH}:/SERVER-START`
let dir = ""

function tmux(args: string[], env?: Record<string, string | undefined>) {
  const r = Bun.spawnSync(["tmux", "-u", ...PREFIX, ...args], { env: env ?? process.env })
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() }
}

async function waitFor(cond: () => boolean, ms = 5_000, what = "条件") {
  const deadline = Date.now() + ms
  while (!cond()) {
    if (Date.now() > deadline) throw new Error(`等 ${what} 超时`)
    await Bun.sleep(10)
  }
}

/// pane 里 raw 模式把收到的字节原样写进文件（可选先开 bracketed paste）
async function rawPane(name: string, bracketed = false): Promise<string> {
  const out = join(dir, `${name}.out`)
  const ready = join(dir, `${name}.ready`)
  const enable = bracketed ? `printf '\\033[?2004h';` : ""
  tmux(["new-session", "-d", "-s", name, "-x", "80", "-y", "24", `sh -c "${enable} stty raw -echo; touch '${ready}'; exec cat > '${out}'"`])
  await waitFor(() => existsSync(ready), 5_000, `${name} 就绪`)
  return out
}

const readOut = (p: string) => existsSync(p) ? readFileSync(p, "utf8") : ""

async function inMode<T>(mode: "ctl" | "fork", body: () => Promise<T>): Promise<T> {
  if (mode === "fork") process.env.MP_HUB_PERF_K1 = "0"
  else {
    const ctl = startSharedTmuxControl({ backoffMinMs: 50, backoffMaxMs: 200, wedgeMs: 10_000 })
    await waitFor(() => ctl.state === "ready", 5_000, "控制连接就绪")
  }
  try { return await body() } finally {
    delete process.env.MP_HUB_PERF_K1
    stopSharedTmuxControl()
  }
}

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), "mp-hsend-"))
  // server 的全局 PATH 末尾带 /SERVER-START：好分辨新会话子进程的 PATH 是谁给的（R1）
  const r = tmux(["new-session", "-d", "-s", "base", "-x", "80", "-y", "24", "sleep 86400"], { ...process.env, PATH: SERVER_PATH })
  if (r.code !== 0) throw new Error(`起测试 tmux server 失败：${r.err}`)
})

afterAll(() => {
  stopSharedTmuxControl()
  tmux(["kill-server"])
  rmSync(join(process.env.TMUX_TMPDIR || "/tmp", `tmux-${process.getuid?.() ?? 0}`, SOCKET), { force: true })   // kill-server 不删 socket 文件
  if (savedEnv.socket === undefined) delete process.env.MP_CC_TMUX_SOCKET
  else process.env.MP_CC_TMUX_SOCKET = savedEnv.socket
  if (savedEnv.k1 === undefined) delete process.env.MP_HUB_PERF_K1
  else process.env.MP_HUB_PERF_K1 = savedEnv.k1
  rmSync(dir, { recursive: true, force: true })
})

for (const mode of ["ctl", "fork"] as const) {
  test(`[${mode}] 短消息：send-keys -l 原样 + Enter，pane 收到的字节与原来一致；ctl 档全程不 fork`, () => inMode(mode, async () => {
    const out = await rawPane(`short-${mode}`)
    const text = `hi 中文 "q" $HOME ~/x \\; #{pane_id} end;`
    const before = { ...tmuxRunCounts }
    await realTmuxRunner.send(text, `short-${mode}`)
    await waitFor(() => readOut(out).endsWith("\r"), 5_000, "Enter 到达")
    expect(readOut(out)).toBe(`${text}\r`)
    if (mode === "ctl") expect(tmuxRunCounts.fork).toBe(before.fork)
    else expect(tmuxRunCounts.ctl).toBe(before.ctl)
  }))

  test(`[${mode}] 多行消息走粘贴：bracketed paste 一整段 + settle 后 Enter；临时缓冲区用完即删`, () => inMode(mode, async () => {
    const out = await rawPane(`paste-${mode}`, true)
    const text = "第一行 $x\n第二行 \"q\" ~\n第三行;"
    const before = { ...tmuxRunCounts }
    await realTmuxRunner.send(text, `paste-${mode}`)
    expect(readOut(out)).toBe(`\x1b[200~${text.replace(/\n/g, "\r")}\x1b[201~\r`)
    expect(tmux(["list-buffers", "-F", "#{buffer_name}"]).out).not.toContain(`mp-${process.pid}-`)
    if (mode === "ctl") expect(tmuxRunCounts.fork).toBe(before.fork)
    else expect(tmuxRunCounts.ctl).toBe(before.ctl)
  }))

  test(`[${mode}] spawn：子进程 PATH = hub 的 PATH（不是 server 全局的）、带 MP_CC_HUB_PORT；重复 spawn 抛 SessionExistsError；kill 后没了`, () => inMode(mode, async () => {
    const session = `sp-${mode}`
    const envFile = join(dir, `${session}.env`)
    await realTmuxRunner.spawn(session, dir, `echo "$PATH" > '${envFile}.tmp'; echo "$MP_CC_HUB_PORT" >> '${envFile}.tmp'; mv '${envFile}.tmp' '${envFile}'; sleep 86400`)
    await waitFor(() => existsSync(envFile), 5_000, "env 落盘")
    const [path, port] = readFileSync(envFile, "utf8").trim().split("\n")
    // 原来 fork 建的会话：子进程 PATH = fork 客户端的 = 本进程起来时的环境（Bun 的子进程看不到 process.env 的改动，hub 还改过 PATH）
    expect(path).toBe(Bun.spawnSync(["/usr/bin/printenv", "PATH"]).stdout.toString().trim())
    expect(path.endsWith("/SERVER-START")).toBe(false)
    expect(port).toMatch(/^\d+$/)
    await expect(realTmuxRunner.spawn(session, dir, "sleep 86400")).rejects.toBeInstanceOf(SessionExistsError)
    await realTmuxRunner.kill(session)
    expect(tmux(["has-session", "-t", session]).code).not.toBe(0)
    await realTmuxRunner.kill(session)   // 已经没了：照旧吞掉
  }))

  test(`[${mode}] key / capture：按键到达；会话不存在时 capture 回空串、key 抛错`, () => inMode(mode, async () => {
    const out = await rawPane(`key-${mode}`)
    await realTmuxRunner.key("Escape", `key-${mode}`)
    await waitFor(() => readOut(out) === "\x1b", 5_000, "Escape 到达")
    expect(await realTmuxRunner.capture("no-such-session")).toBe("")
    await expect(realTmuxRunner.key("Enter", "no-such-session")).rejects.toThrow(/can't find/)
  }))
}

test("[fork] 审查继承项：多行消息粘贴失败（会话不存在）也删掉临时缓冲区", () => inMode("fork", async () => {
  await expect(realTmuxRunner.send("第一行\n第二行", "no-such-session")).rejects.toThrow(/can't find/)
  expect(tmux(["list-buffers", "-F", "#{buffer_name}"]).out).not.toContain(`mp-${process.pid}-`)
}))

// ── K1 第 4b 步：结果不明的消息由 hub 自己核对送达 ──
// 假 CC：pane 里一个小 TUI，键入的字显示在「输入框」（长文本 / 粘贴显示成 [Pasted text #1 …] 占位），回车提交时往 transcript 写一行 user 消息

const FAKE_TUI = `
import { appendFileSync } from "node:fs"
const transcript = process.argv[2]
const START = "\\x1b[200~", END = "\\x1b[201~"
let buf = "", inPaste = false, pasted = false, pend = ""
const dec = new TextDecoder()
const RULE = "─".repeat(60)
// 照 claude 2.1.x 的输入框画：上下两条整行横线，中间第一行以 ❯ 开头（raw 模式下换行要 \\r\\n）
const render = () => process.stdout.write("\\x1b[2J\\x1b[H● 历史\\r\\n" + RULE + "\\r\\n❯ " + (pasted ? "[Pasted text #1 +" + buf.split("\\n").length + " lines]" : buf) + "\\r\\n" + RULE + "\\r\\n  ? for shortcuts")
render()
for await (const chunk of Bun.stdin.stream()) {
  pend += dec.decode(chunk, { stream: true })
  while (pend.length) {
    if (pend.startsWith(START)) { inPaste = true; pasted = true; pend = pend.slice(START.length); continue }
    if (pend.startsWith(END)) { inPaste = false; pend = pend.slice(END.length); continue }
    if (pend[0] === "\\x1b" && (START.startsWith(pend) || END.startsWith(pend))) break
    const ch = pend[0]
    pend = pend.slice(1)
    if (ch === "\\r" && !inPaste) {
      if (buf) appendFileSync(transcript, JSON.stringify({ type: "user", timestamp: new Date().toISOString(), message: { role: "user", content: buf } }) + "\\n")
      buf = ""
      pasted = false
    } else buf += ch === "\\r" ? "\\n" : ch
  }
  render()
}
`

const savedHome = { home: process.env.HOME, workdir: process.env.MP_CC_WORKDIR }

/// 起一个假 CC 会话：绑定一个 claude session id，transcript 落在临时 HOME 下（和 hub 找 transcript 的路径规则一致）
async function fakeCC(session: string): Promise<{ transcript: string; submitted: () => string[] }> {
  process.env.HOME = join(dir, "home")
  process.env.MP_CC_WORKDIR = join(dir, "work")
  const id = `00000000-0000-4000-8000-${String(Math.floor(Math.random() * 1e12)).padStart(12, "0")}`
  sessionMap.set(session, { claudeSessionId: id, updatedAt: new Date().toISOString() })
  const transcript = claudeTranscriptPath(id)
  mkdirSync(dirname(transcript), { recursive: true })
  const script = join(dir, "fake-tui.ts")
  if (!existsSync(script)) writeFileSync(script, FAKE_TUI)
  const ready = join(dir, `${session}.ready`)
  tmux(["new-session", "-d", "-s", session, "-x", "80", "-y", "24", `sh -c "stty raw -echo; touch '${ready}'; exec '${process.execPath}' '${script}' '${transcript}'"`])
  await waitFor(() => existsSync(ready), 5_000, `${session} 就绪`)
  await waitFor(() => tmux(["capture-pane", "-t", session, "-p"]).out.includes("❯"), 5_000, `${session} 画出输入框`)
  tmuxState.noteSpawned(session)   // 会话表认它活着（不让 hasSession 去同步查默认 socket）
  const submitted = () => readOut(transcript).split("\n").filter(Boolean).map((l) => JSON.parse(l).message.content as string)
  return { transcript, submitted }
}

function restoreHome() {
  if (savedHome.home === undefined) delete process.env.HOME
  else process.env.HOME = savedHome.home
  if (savedHome.workdir === undefined) delete process.env.MP_CC_WORKDIR
  else process.env.MP_CC_WORKDIR = savedHome.workdir
}

const tag = (id: string, content: string) => buildChannelTag({ type: "send", chat_id: "chat-4b", message_id: id, content, user: "susu" }, "2026-10-11T00:00:00.000Z")
const quiet = async () => {}
const quietRunner = () => setTmuxRunner({ ...realTmuxRunner, send: quiet, sendRaw: quiet, key: quiet, capture: async () => "", hasSession: () => true, list: () => [], paneTitles: () => new Map(), spawn: quiet, kill: quiet, paste: async () => ({ ok: true }) })

/// 停住测试 server 跑 body；无论如何 SIGCONT（看门狗兜底），回来后确认它在跑
async function whileStopped<T>(body: () => Promise<T>, watchdogMs = 25_000): Promise<T> {
  const pid = Number(tmux(["display-message", "-p", "#{pid}"]).out.trim())
  expect(Bun.spawnSync(["ps", "-o", "command=", "-p", String(pid)]).stdout.toString()).toContain(SOCKET)   // 只停测试 server
  process.kill(pid, "SIGSTOP")
  const watchdog = setTimeout(() => process.kill(pid, "SIGCONT"), watchdogMs)
  try { return await body() } finally {
    clearTimeout(watchdog)
    process.kill(pid, "SIGCONT")
    expect(Bun.spawnSync(["ps", "-o", "stat=", "-p", String(pid)]).stdout.toString()).not.toContain("T")
  }
}

for (const mode of ["ctl", "fork"] as const) {
  test(`[${mode}] 4b：tmux 卡住 11.2s，发消息结果不明 → 等原写入落定再核对 → 这条恰好提交一遍；卡住期间排在后面的消息不乱序、不粘连；正常发送不发 send_status`, () => inMode(mode, async () => {
    const session = `v4b-${mode}`
    const cc = await fakeCC(session)
    const frames: string[] = []
    const unwatch = sendStatusBook.watch((f) => frames.push(`${f.message_id}:${f.status}`))
    setTmuxRunner(realTmuxRunner)
    try {
      await ensureSessionAndSendAsync(session, tag(`m0-${mode}`, "先来一条"))   // 正常发：会话标成就绪
      await waitFor(() => cc.submitted().length === 1, 5_000, "第一条提交")
      expect(frames).toEqual([])
      expect(sendStatusBook.record(`m0-${mode}`)).toBeUndefined()
      const t0 = Date.now()
      const [one, two] = await whileStopped(async () => {
        const one = ensureSessionAndSendAsync(session, tag(`m1-${mode}`, "卡住时发的"))
        await Bun.sleep(100)
        const two = ensureSessionAndSendAsync(session, tag(`m2-${mode}`, "后面一条"))
        await Bun.sleep(11_100)
        return [one, two]
      })
      await one
      await two
      await waitFor(() => cc.submitted().length >= 3, 5_000, "两条都提交")   // 回车发出去了，假 CC 写 transcript 要一会儿
      const got = cc.submitted()
      expect(got.length).toBe(3)
      expect(got[1]).toContain(`message_id="m1-${mode}"`)
      expect(got[1]).not.toContain(`m2-${mode}`)   // 没和后面那条粘成一次提交
      expect(got[2]).toContain(`message_id="m2-${mode}"`)
      expect(frames).toEqual([`m1-${mode}:uncertain`, `m1-${mode}:delivered`])
      const rec = sendStatusBook.record(`m1-${mode}`)!
      // fork：被杀的客户端已经交进 socket 的那条恢复后照样执行 → 停在输入框 → 补回车（不重发）
      if (mode === "fork") expect(rec.reason).toBe("停在输入框里，补了回车")
      console.log(`[test] ${mode} 核对结局：${rec.reason}，用时 ${Date.now() - t0}ms`)
      await Bun.sleep(1_000)
      expect(cc.submitted().length).toBe(3)   // 没有迟到的那一遍
    } finally {
      unwatch()
      quietRunner()
      restoreHome()
    }
  }), 60_000)
}

test("[ctl] 4b app 重发：只对 failed 接受；transcript 里已经有了就不再注入，没进才发；送达后再 retry 不接受", () => inMode("ctl", async () => {
  const session = "v4b-retry"
  const cc = await fakeCC(session)
  const frames: string[] = []
  const unwatch = sendStatusBook.watch((f) => frames.push(`${f.message_id}:${f.status}`))
  try {
    // 她在终端里自己按过回车：transcript 里已经有这条。app 重发 → 不再注入
    await realTmuxRunner.send(tag("r-in", "其实进了"), session)
    await waitFor(() => cc.submitted().length === 1, 5_000, "提交")
    const cursor = { path: cc.transcript, offset: 0 }
    sendStatusBook.finish(sendStatusBook.begin("r-in", "chat-4b", session, cursor, undefined)!, { status: "failed", retryable: true, reason: "tmux 卡了" })
    expect(sendStatusBook.acceptRetry("r-in", "chat-4b", session, false).accepted).toBe(true)
    await realTmuxRunner.send(tag("r-in", "其实进了"), session)
    await Bun.sleep(300)
    expect(cc.submitted().length).toBe(1)
    expect(sendStatusBook.record("r-in")?.status).toBe("delivered")
    // 真没进：重发照常注入、提交，回 delivered
    sendStatusBook.finish(sendStatusBook.begin("r-out", "chat-4b", session, { path: cc.transcript, offset: Bun.file(cc.transcript).size }, undefined)!, { status: "failed", retryable: true, reason: "可能已经进去了" })
    expect(sendStatusBook.acceptRetry("r-out", "chat-4b", session, false).accepted).toBe(true)
    await realTmuxRunner.send(tag("r-out", "真没进"), session)
    await waitFor(() => cc.submitted().length === 2, 5_000, "重发提交")
    expect(cc.submitted()[1]).toContain(`message_id="r-out"`)
    expect(frames).toEqual(["r-in:uncertain", "r-in:failed", "r-in:delivered", "r-out:uncertain", "r-out:failed", "r-out:delivered"])
    // 送达了的再 retry：不接受，回 delivered
    expect(sendStatusBook.acceptRetry("r-out", "chat-4b", session, false)).toMatchObject({ accepted: false, frame: { status: "delivered" } })
  } finally {
    unwatch()
    restoreHome()
  }
}), 30_000)
