import { afterAll, beforeAll, expect, test } from "bun:test"
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { captureAtBoundary, closeTerminalAttachment, formatSnapshot, openTerminalAttachment, realTmuxRunner, sendTerminalBytes, syncWindowSize } from "./hub"
import { decodeControlOutput } from "./tmux-pane-stream"
import { TerminalSizeTracker } from "./terminal-size"
import { chainTmuxWrite, startSharedTmuxControl, stopSharedTmuxControl, type TmuxControl } from "./tmux-control"

// K1 第 3 步：终端键入 / 粘贴走 tmuxRun；#087 起终端流走每会话一个只读控制客户端。真 tmux，独立 socket（-L），永不碰默认 server
const SOCKET = `mp-hterm-${process.pid}-${Math.random().toString(36).slice(2, 6)}`
const PREFIX = ["-L", SOCKET]
const savedEnv = { socket: process.env.MP_CC_TMUX_SOCKET, k1: process.env.MP_HUB_PERF_K1 }
process.env.MP_CC_TMUX_SOCKET = SOCKET
delete process.env.MP_HUB_PERF_K1
let dir = ""
let ctl: TmuxControl

function tmux(args: string[]) {
  const r = Bun.spawnSync(["tmux", "-u", ...PREFIX, ...args])
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() }
}

async function waitFor(cond: () => boolean, ms = 5_000, what = "条件") {
  const deadline = Date.now() + ms
  while (!cond()) {
    if (Date.now() > deadline) throw new Error(`等 ${what} 超时`)
    await Bun.sleep(10)
  }
}

/// pane 里 raw 模式把收到的字节原样写进文件（不回显）
async function rawPane(name: string): Promise<string> {
  const out = join(dir, `${name}.out`)
  const ready = join(dir, `${name}.ready`)
  tmux(["new-session", "-d", "-s", name, "-x", "80", "-y", "24", `sh -c "stty raw -echo; touch '${ready}'; cat > '${out}'"`])
  await waitFor(() => existsSync(ready), 5_000, `${name} 就绪`)
  return out
}

beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), "mp-hterm-"))
  const r = tmux(["new-session", "-d", "-s", "base", "-x", "80", "-y", "24", "sleep 86400"])
  if (r.code !== 0) throw new Error(`起测试 tmux server 失败：${r.err}`)
  ctl = startSharedTmuxControl({ backoffMinMs: 50, backoffMaxMs: 200, wedgeMs: 10_000 })
  await waitFor(() => ctl.state === "ready", 5_000, "控制连接就绪")
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

test("K1-0 风险 7：terminal_input 与 terminal_paste 交错调用，同一会话按调用顺序到达（控制连接 / fork 回退两档）", async () => {
  for (const k1 of ["1", "0"]) {
    if (k1 === "0") process.env.MP_HUB_PERF_K1 = "0"
    try {
      const session = `order${k1}`
      const out = await rawPane(session)
      const ops = ["a", "B", "c", "D", "e", "F", "g"]
      // 一口气发出去不 await：大写走粘贴（pasteToTmux：set-buffer / load-buffer + paste-buffer），小写走 send-keys -H，两者同一条会话写链
      const pending = ops.map(op => op === op.toUpperCase()
        ? realTmuxRunner.paste(session, op).then(r => { if (!r.ok) throw new Error(r.reason) })
        : sendTerminalBytes(session, new TextEncoder().encode(op)))
      await Promise.all(pending)
      await waitFor(() => existsSync(out) && statSync(out).size >= ops.length, 5_000, "pane 收齐")
      expect({ k1, got: readFileSync(out, "utf8") }).toEqual({ k1, got: ops.join("") })
    } finally { delete process.env.MP_HUB_PERF_K1 }
  }
})

/// 假 WebSocket：只记 hub 发给它的帧
function fakeClient() {
  const frames: { type: string; bytes?: string }[] = []
  const ws = { OPEN: 1, readyState: 1, send: (p: string) => { frames.push(JSON.parse(p)) } }
  return { ws: ws as unknown as import("ws").WebSocket, frames }
}
const listClients = (session: string) => tmux(["list-clients", "-t", session, "-F", "#{client_control_mode}"]).out.trim()

test("#087 terminal_attach 一套：只读控制客户端开流；键入 → 快照边界后出字 → 快照里有；关掉后控制客户端退出", async () => {
  tmux(["new-session", "-d", "-s", "att", "-x", "60", "-y", "20", "cat"])
  tmux(["set-environment", "-t", "att", "SSH_AUTH_SOCK", "/tmp/mp-087-preserved"])
  const att = await openTerminalAttachment("att")
  expect(tmux(["show-environment", "-t", "att", "SSH_AUTH_SOCK"]).out.trim()).toBe("SSH_AUTH_SOCK=/tmp/mp-087-preserved")
  expect(listClients("att")).toBe("1")
  const { ws, frames } = fakeClient()
  let snapshot = ""
  await captureAtBoundary(att, s => { snapshot = s; att.mpClients.add(ws) })
  expect(snapshot).toMatch(/\x1b\[\d+;\d+H$/)
  await sendTerminalBytes("att", new TextEncoder().encode("hello-087 中文\r"))
  const streamed = () => frames.filter(f => f.type === "terminal_chunk").map(f => Buffer.from(f.bytes!, "base64").toString()).join("")
  await waitFor(() => streamed().includes("hello-087 中文"), 5_000, "流出字")
  let again = ""
  await captureAtBoundary(att, s => { again = s })
  expect(again).toContain("hello-087 中文")
  await closeTerminalAttachment("att")
  expect(listClients("att")).toBe("")
})

test("#087 同一会话并发两个 attach 只开一套；会话不存在 → 拒绝且不留控制客户端", async () => {
  tmux(["new-session", "-d", "-s", "att2", "-x", "60", "-y", "20", "cat"])
  const [a, b] = await Promise.all([openTerminalAttachment("att2"), openTerminalAttachment("att2")])
  expect(a).toBe(b)
  expect(listClients("att2")).toBe("1")
  await closeTerminalAttachment("att2")
  expect(listClients("att2")).toBe("")
  await expect(openTerminalAttachment("no-such-session")).rejects.toThrow(/can't find/)
})

test("#087 decodeControlOutput：\\ooo 还原控制字节和反斜杠，0x80 以上原样（中文不经 TextDecoder）", () => {
  const line = Buffer.concat([Buffer.from("%output %1 "), Buffer.from("\\033[1m\\134中\\015\\012"), Buffer.from([0xff])])
  expect([...decodeControlOutput(line, "%output %1 ".length)]).toEqual([...Buffer.concat([Buffer.from("\x1b[1m\\中\r\n"), Buffer.from([0xff])])])
})

/// 模拟 Claude Code（Ink）主缓冲区相对重绘：擦上一帧（ESC[2K ESC[1A …）再画新帧，不时把一行「定稿」顶上去
const INK_SIM = `
const out = (s) => process.stdout.write(s)
let prev = 0, tick = 0, done = 0
const erase = () => { let s = ""; for (let i = 0; i < prev; i++) s += "\\x1b[2K" + (i < prev - 1 ? "\\x1b[1A" : ""); return s + "\\r" }
const end = Date.now() + Number(process.argv[2])
function step() {
  tick++
  let s = erase()
  if (tick % 5 === 0) { done++; s += "● 定稿 " + done + "：图存好了 " + "y".repeat(done % 20) + "\\r\\n" }
  const f = ["⠋ 工具调用中 tick=" + tick]
  for (let i = 1; i < 2 + (tick % 4); i++) f.push("  ⎿ 输出第" + i + "行 " + "x".repeat((tick * 7 + i) % 30))
  f.push("> 输入框")
  s += f.join("\\r\\n"); prev = f.length; out(s)
  if (Date.now() < end) setTimeout(step, 8 + Math.random() * 30)
  else { out(erase() + "● 结束 " + done + "\\r\\n$ "); setTimeout(() => {}, 1e9) }
}
step()
`

/// 模拟 Claude Code 2.1 的 DECSTBM 渲染器：备用屏 + 滚动区（上面消息区滚，底下分隔线 / 输入框 / 状态栏固定）+ 藏光标
const REGION_SIM = `
const out = (s) => process.stdout.write(s)
const dur = Number(process.argv[2]), R = Number(process.argv[3])
out("\\x1b[?1049h\\x1b[?25l\\x1b[2J\\x1b[1;" + (R - 3) + "r")
let n = 0
const footer = () => "\\x1b7\\x1b[" + (R - 2) + ";1H\\x1b[2K──────\\x1b[" + (R - 1) + ";1H\\x1b[2K> 输入框 " + n + "\\x1b[" + R + ";1H\\x1b[2K状态栏 " + n + "\\x1b8"
out("\\x1b[" + (R - 3) + ";1H" + footer())
const end = Date.now() + dur
function step() {
  n++
  out("\\x1b[" + (R - 3) + ";1H\\r\\n● 消息 " + n + "：图存好了 " + "z".repeat(n % 25) + footer())
  if (Date.now() < end) setTimeout(step, 10 + Math.random() * 30)
  else { out("\\x1b[" + R + ";1H\\x1b[2K● 结束 " + n); setTimeout(() => {}, 1e9) }
}
step()
`

test("#087 formatSnapshot：备用屏在内容前切、滚动区与藏光标在内容后补、最后钉光标；整屏滚动区不发", () => {
  const { snapshot, mouseAny } = formatSnapshot("a\nb\n", "3 1 1 0 0 16 1 20")
  expect(snapshot).toBe("\x1b[?1049ha\r\nb\x1b[1;17r\x1b[?25l\x1b[2;4H")
  expect(mouseAny).toBe(true)
  expect(formatSnapshot("a\n", "0 0 0 1 0 19 0 20").snapshot).toBe("a\x1b[?25h\x1b[1;1H")
  expect(formatSnapshot("alt\n", "2 3 0 1 0 19 1 20 4 5", "main\n").snapshot)
    .toBe("main\x1b[6;5H\x1b[?1049halt\x1b[?25h\x1b[4;3H")
  expect(formatSnapshot("a\n", "0 0 0").snapshot).toBe("a\x1b[1;1H")   // 老格式：只钉光标
})

test("#087 回归：输出正忙时 attach，快照 + 之后的增量 = tmux 真屏（pipe-pane 时代 Ink 场景 15/30 对不上；滚动区场景不补状态 6/6 对不上）", async () => {
  const sims = { ink: join(dir, "inksim.js"), region: join(dir, "regionsim.js") }
  writeFileSync(sims.ink, INK_SIM)
  writeFileSync(sims.region, REGION_SIM)
  for (let i = 0; i < 6; i++) {
    const s = `busy${i}`
    const kind = i % 2 ? "region" : "ink"
    tmux(["new-session", "-d", "-s", s, "-x", "54", "-y", "20", `${process.execPath} ${sims[kind]} 1500 20`])
    const att = await openTerminalAttachment(s)
    await captureAtBoundary(att, () => {})   // 先认 pane（生产里第一个观众的快照同样起这个作用）
    if (i === 1) {
      // 快照之后新建的窗口大输出也不能让目标 pane 的增量越过下一张快照的边界。
      tmux(["new-window", "-d", "-t", s, "yes x | head -c 2000000; sleep 60"])
    }
    await Bun.sleep(200 + Math.random() * 600)
    const { ws, frames } = fakeClient()
    await captureAtBoundary(att, (snapshot) => {
      frames.push({ type: "terminal_init", bytes: Buffer.from(snapshot).toString("base64") })
      att.mpClients.add(ws)
    })
    // 等画面真稳下来再比：真屏出现结束行，而且我们这边 300ms 没再收到增量（机器忙时模拟程序本身就会跑慢）
    const received = () => frames.reduce((n, f) => n + (f.bytes?.length ?? 0), 0)
    await waitFor(() => tmux(["capture-pane", "-t", s, "-p"]).out.includes("● 结束"), 20_000, `${s} 跑完`)
    const streamText = () => { att.flush(); return Buffer.concat(frames.map(f => Buffer.from(f.bytes!, "base64"))).toString() }
    await waitFor(() => streamText().includes("● 结束"), 20_000, `${s} 结束行流到`)
    for (let last = -1; received() !== last;) { last = received(); await Bun.sleep(300); att.flush() }
    const truth = tmux(["capture-pane", "-t", s, "-p"]).out
    expect(frames[0].type).toBe("terminal_init")   // 快照之前的增量一个都不该发给它
    const replay = join(dir, `${s}.replay`)
    writeFileSync(replay, Buffer.concat([Buffer.from("\x1bc"), ...frames.map(f => Buffer.from(f.bytes!, "base64"))]))
    tmux(["new-session", "-d", "-s", `${s}r`, "-x", "54", "-y", "20", `cat '${replay}'; sleep 60`])
    await Bun.sleep(300)
    const got = tmux(["capture-pane", "-t", `${s}r`, "-p"]).out
    const norm = (t: string) => t.split("\n").map(l => l.trimEnd()).join("\n").trimEnd()
    expect({ i, kind, screen: norm(got) }).toEqual({ i, kind, screen: norm(truth) })
    await closeTerminalAttachment(s)
    tmux(["kill-session", "-t", s]); tmux(["kill-session", "-t", `${s}r`])
  }
}, 120_000)

test("#087 握手超时后重试不再创建客户端，server 恢复后才能重开", async () => {
  tmux(["new-session", "-d", "-s", "stalled", "sleep 60"])
  const pid = Number(tmux(["display-message", "-p", "#{pid}"]).out.trim())
  process.kill(pid, "SIGSTOP")
  try {
    await expect(openTerminalAttachment("stalled")).rejects.toThrow(/attach timeout/)
    for (let i = 0; i < 5; i++) await expect(openTerminalAttachment("stalled")).rejects.toThrow(/still closing/)
  } finally { process.kill(pid, "SIGCONT") }
  let att: Awaited<ReturnType<typeof openTerminalAttachment>> | undefined
  const deadline = Date.now() + 5_000
  while (!att && Date.now() < deadline) {
    try { att = await openTerminalAttachment("stalled") } catch { await Bun.sleep(10) }
  }
  expect(att).toBeDefined()
  expect(listClients("stalled")).toBe("1")
  await closeTerminalAttachment("stalled")
  expect(listClients("stalled")).toBe("")
}, 15_000)

test("#087 备用屏中 attach 后退出，返回保存的主屏和光标", async () => {
  const script = join(dir, "alternate.js"), gate = join(dir, "alternate-exit")
  writeFileSync(script, `
    process.stdout.write("主屏第一行\\r\\n主屏第二行\\x1b[2;5H\\x1b[?1049h\\x1b[2J备用屏\\x1b[?25l")
    const timer = setInterval(() => {
      if (require("node:fs").existsSync(${JSON.stringify(gate)})) {
        clearInterval(timer)
        process.stdout.write("\\x1b[?1049l\\x1b[?25h")
        setInterval(() => {}, 1000)
      }
    }, 10)
  `)
  tmux(["new-session", "-d", "-s", "alternate", "-x", "54", "-y", "20", `${process.execPath} '${script}'`])
  await waitFor(() => tmux(["capture-pane", "-t", "alternate", "-p"]).out.includes("备用屏"))
  const att = await openTerminalAttachment("alternate")
  const { ws, frames } = fakeClient()
  await captureAtBoundary(att, snapshot => {
    frames.push({ type: "terminal_init", bytes: Buffer.from(snapshot).toString("base64") })
    att.mpClients.add(ws)
  })
  writeFileSync(gate, "exit")
  await waitFor(() => { att.flush(); return frames.some(f => Buffer.from(f.bytes!, "base64").includes(Buffer.from("\x1b[?1049l"))) })
  const replay = join(dir, "alternate-replay")
  writeFileSync(replay, Buffer.concat([Buffer.from("\x1bc"), ...frames.map(f => Buffer.from(f.bytes!, "base64"))]))
  tmux(["new-session", "-d", "-s", "alternate-replay", "-x", "54", "-y", "20", `cat '${replay}'; sleep 60`])
  await waitFor(() => tmux(["capture-pane", "-t", "alternate-replay", "-p"]).out.includes("主屏第二行"))
  const state = (s: string) => ({
    screen: tmux(["capture-pane", "-t", s, "-p"]).out,
    meta: tmux(["display-message", "-t", s, "-p", "#{alternate_on} #{cursor_x} #{cursor_y} #{cursor_flag}"]).out,
  })
  expect(state("alternate-replay")).toEqual(state("alternate"))
  await closeTerminalAttachment("alternate")
  tmux(["kill-session", "-t", "alternate"])
  tmux(["kill-session", "-t", "alternate-replay"])
})

test("审查 R1-2：排着的 resize 与 detach 交错，最终尺寸 = 剩下的设备要的", async () => {
  tmux(["new-session", "-d", "-s", "rsz", "-x", "80", "-y", "24", "cat"])
  const size = () => tmux(["display-message", "-t", "rsz", "-p", "#{window_width}x#{window_height}"]).out.trim()
  const sizes = new TerminalSizeTracker<string>()
  const target = () => sizes.effective("rsz")
  sizes.set("rsz", "phone", { cols: 52, rows: 24 })
  expect(await syncWindowSize("rsz", target)).toBe(true)
  expect(size()).toBe("52x24")
  sizes.set("rsz", "mac", { cols: 80, rows: 24 })
  sizes.remove("rsz", "phone")
  expect(await syncWindowSize("rsz", target)).toBe(true)
  expect(size()).toBe("80x24")

  // 窗口 80；手机又来了，它的 resize 排在一条没跑完的写后面；手机随即离开、恢复逻辑跑：两条都按执行时的设备算
  let release = () => {}
  const gate = chainTmuxWrite("rsz", () => new Promise<void>(r => { release = r }))
  sizes.set("rsz", "phone", { cols: 52, rows: 24 })
  const phoneResize = syncWindowSize("rsz", target)
  sizes.remove("rsz", "phone")
  const restore = syncWindowSize("rsz", target)
  await Bun.sleep(20)
  release()
  await gate
  expect([await phoneResize, await restore]).toEqual([false, false])
  expect(size()).toBe("80x24")
})
