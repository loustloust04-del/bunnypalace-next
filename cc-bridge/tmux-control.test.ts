import { afterAll, beforeAll, expect, test } from "bun:test"
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fetchPanes, quoteArg, startSharedTmuxControl, stopSharedTmuxControl, TmuxCommandError, TmuxControl, TmuxUncertainError, tmuxLoadBuffer, tmuxRun, tmuxRunCounts, waitTmuxWriteSettled } from "./tmux-control"
import { fetchTmuxPanes, parsePanes, TmuxState } from "./tmux-state"

// 真 tmux，独立 socket（-L）：永不碰默认 server；tmuxRun 的 fork 回退也经 MP_CC_TMUX_SOCKET 落到这里
const SOCKET = `mp-test-${process.pid}-${Math.random().toString(36).slice(2, 8)}`
const PREFIX = ["-L", SOCKET]
const SERVER_PATH = `${process.env.PATH}:/SERVER-START`
const savedEnv = { socket: process.env.MP_CC_TMUX_SOCKET, k1: process.env.MP_HUB_PERF_K1 }
process.env.MP_CC_TMUX_SOCKET = SOCKET
delete process.env.MP_HUB_PERF_K1
let dir = ""
let ctl: TmuxControl

function tmux(args: string[], env?: Record<string, string | undefined>) {
  const r = Bun.spawnSync(["tmux", "-u", ...PREFIX, ...args], { env: env ?? process.env })
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() }
}

/// server 的全局环境取自起它的那个客户端：PATH 末尾带 /SERVER-START，好分辨子进程的 PATH 是谁给的
function ensureServer() {
  if (tmux(["has-session", "-t", "base"]).code === 0) return
  const r = tmux(["new-session", "-d", "-s", "base", "-x", "80", "-y", "24", "sleep 86400"], { ...process.env, PATH: SERVER_PATH })
  if (r.code !== 0) throw new Error(`起测试 tmux server 失败：${r.err}`)
}

async function waitFor(cond: () => boolean, ms = 5_000, what = "条件") {
  const deadline = Date.now() + ms
  while (!cond()) {
    if (Date.now() > deadline) throw new Error(`等 ${what} 超时`)
    await Bun.sleep(10)
  }
}

/// pane 里 raw 模式把收到的字节原样写进文件；返回文件路径
async function rawPane(name: string, reader: string): Promise<string> {
  const out = join(dir, `${name}.out`)
  const ready = join(dir, `${name}.ready`)
  tmux(["new-session", "-d", "-s", name, "-x", "80", "-y", "24", `sh -c "stty raw -echo; touch '${ready}'; ${reader} > '${out}'"`])
  await waitFor(() => existsSync(ready), 5_000, `${name} 就绪`)
  return out
}

function startCtl(opts: { wedgeMs?: number } = {}): TmuxControl {
  return startSharedTmuxControl({ backoffMinMs: 50, backoffMaxMs: 200, wedgeMs: opts.wedgeMs ?? 10_000 })
}

beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), "mp-tmuxctl-"))
  ensureServer()
  ctl = startCtl()
  await waitFor(() => ctl.state === "ready", 5_000, "控制连接就绪")
})

afterAll(() => {
  stopSharedTmuxControl()
  tmux(["kill-server"])
  if (savedEnv.socket === undefined) delete process.env.MP_CC_TMUX_SOCKET
  else process.env.MP_CC_TMUX_SOCKET = savedEnv.socket
  if (savedEnv.k1 === undefined) delete process.env.MP_HUB_PERF_K1
  else process.env.MP_HUB_PERF_K1 = savedEnv.k1
  rmSync(dir, { recursive: true, force: true })
})

test("1 quoteArg：刁钻串、控制字符、~、64KB / 1MB 经 set-buffer 写进去，fork show-buffer 读回逐字相同", async () => {
  const big = (n: number) => "abc中文\"'$\\;~\n".repeat(Math.ceil(n / 12)).slice(0, n)
  const cases = [
    "plain", `it's "quoted" \\ back`, "$HOME ~ #{session_name} ; { } # comment", "多行\n第二行\r\nCRLF\ttab",
    "emoji 🎩🐭 中文", "\x1b[31mred\x1b[0m bell\x07", " leading/trailing space ", "-dash-first", ";", "\\;",
    "~", "~/foo", "a~b", "%if 1", "\x7f del", "\x01\x1f", big(64 * 1024), big(1 << 20),
  ]
  for (const t of cases) {
    await ctl.run(["set-buffer", "-b", "qt", "--", t], 30_000)
    const back = tmux(["show-buffer", "-b", "qt"]).out
    expect({ len: back.length, same: back === t, head: t.slice(0, 40) }).toEqual({ len: t.length, same: true, head: t.slice(0, 40) })
  }
  expect(quoteArg("a;b")).toBe('"a;b"')
  expect(await ctl.run(["display-message", "-p", "SENTINEL"], 3_000)).toBe("SENTINEL\n")
}, 60_000)

test("R1-3 以 ; 结尾的参数：控制通道和 fork 回退读回一致", async () => {
  const cases = ["abc;", ";", "\\;", "a\\\\;", ";;", "a ; b", "{", "}", "x;y"]
  for (const k1 of ["1", "0"]) {
    process.env.MP_HUB_PERF_K1 = k1
    try {
      for (const t of cases) {
        await tmuxRun(["set-buffer", "-b", "semi", "--", t], { timeoutMs: 3_000, write: false })
        expect({ k1, t, back: tmux(["show-buffer", "-b", "semi"]).out }).toEqual({ k1, t, back: t })
      }
    } finally { delete process.env.MP_HUB_PERF_K1 }
  }
})

test("2 100 条并发按发出顺序回包", async () => {
  const rs = await Promise.all(Array.from({ length: 100 }, (_, i) => ctl.run(["display-message", "-p", `n${i}`], 5_000)))
  expect(rs).toEqual(Array.from({ length: 100 }, (_, i) => `n${i}\n`))
})

test("3 %error → TmuxCommandError，.stderr 能被 /can't find session/ 匹配；fork 回退同款", async () => {
  const viaCtl = await ctl.run(["has-session", "-t", "nope"], 3_000).catch(e => e)
  expect(viaCtl).toBeInstanceOf(TmuxCommandError)
  expect(viaCtl.stderr).toMatch(/can't find session/)
  process.env.MP_HUB_PERF_K1 = "0"
  try {
    const viaFork = await tmuxRun(["has-session", "-t", "nope"], { timeoutMs: 3_000, write: false }).catch(e => e)
    expect(viaFork).toBeInstanceOf(TmuxCommandError)
    expect(viaFork.stderr).toMatch(/can't find session/)
  } finally { delete process.env.MP_HUB_PERF_K1 }
})

test("4 命令名含换行 / 空 / 拼 ; / 参数含 NUL 被拒，连接不受影响", async () => {
  for (const argv of [["display-message\nkill-server"], [""], [], ["has-session;kill-server"], ["display-message", "-p", "a\0b"]]) {
    await expect(ctl.run(argv, 1_000)).rejects.toThrow()
    await expect(tmuxRun(argv, { timeoutMs: 1_000, write: false })).rejects.toThrow()
  }
  expect(ctl.state).toBe("ready")
  expect(await ctl.run(["display-message", "-p", "still alive"], 3_000)).toBe("still alive\n")
  expect(tmux(["has-session", "-t", "base"]).code).toBe(0)
})

test("5 capture-pane -e -S -200 与 fork 的 stdout 逐字节相同（250 行彩色 + 中文）", async () => {
  const script = join(dir, "colors.sh")
  writeFileSync(script, `i=1; while [ $i -le 250 ]; do printf '\\033[3%dm行%03d 中文 \\033[1mbold\\033[0m\\n' $((i%7+1)) $i; i=$((i+1)); done; sleep 86400\n`)
  tmux(["new-session", "-d", "-s", "cap", "-x", "100", "-y", "30", `sh '${script}'`])
  await waitFor(() => tmux(["capture-pane", "-t", "cap", "-p"]).out.includes("行250"), 5_000, "彩色输出")
  const viaFork = tmux(["capture-pane", "-t", "cap", "-p", "-e", "-S", "-200"]).out
  const viaCtl = await ctl.run(["capture-pane", "-t", "cap", "-p", "-e", "-S", "-200"], 3_000)
  expect(viaCtl.includes("\x1b[")).toBe(true)
  expect(viaCtl.includes("中文")).toBe(true)
  expect(viaCtl).toBe(viaFork)
})

test("6 send-keys -H：NUL / ^C / ESC / 中文 / DEL 逐字节到达 pane", async () => {
  const bytes = [0x68, 0x69, 0x20, 0xe4, 0xb8, 0xad, 0x1b, 0x5b, 0x41, 0x7f, 0x09, 0x0d, 0x00, 0x03, 0x5a]
  const out = await rawPane("hex", `head -c ${bytes.length}`)
  await ctl.run(["send-keys", "-t", "hex", "-H", ...bytes.map(b => b.toString(16).padStart(2, "0"))], 3_000)
  await waitFor(() => existsSync(out) && statSync(out).size >= bytes.length, 5_000, "pane 收齐字节")
  expect([...readFileSync(out)]).toEqual(bytes)
})

test("7 控制连接发 new-session：不带 -e 子进程拿 server 的 PATH（R1 的坑），带 -e PATH= 拿到给的那个", async () => {
  const hubPath = `${process.env.PATH}:/HUB-PATH`
  const without = join(dir, "path-without")
  const withE = join(dir, "path-with")
  await ctl.run(["new-session", "-d", "-s", "path0", `printenv PATH > '${without}'; sleep 86400`], 3_000)
  await ctl.run(["new-session", "-d", "-s", "path1", "-e", `PATH=${hubPath}`, `printenv PATH > '${withE}'; sleep 86400`], 3_000)
  await waitFor(() => existsSync(without) && existsSync(withE) && statSync(without).size > 0 && statSync(withE).size > 0, 5_000, "PATH 落盘")
  expect(readFileSync(without, "utf8").trim()).toBe(SERVER_PATH)
  expect(readFileSync(withE, "utf8").trim()).toBe(hubPath)
})

test("8 没有 LANG：带 -u 的控制连接保住 \\t 和中文，不带 -u 被换成 _", async () => {
  tmux(["new-session", "-d", "-s", "lang", "sleep 86400"])
  tmux(["select-pane", "-t", "lang", "-T", "标题 中文"])
  const saved = { LANG: process.env.LANG, LC_ALL: process.env.LC_ALL, LC_CTYPE: process.env.LC_CTYPE }
  delete process.env.LANG; delete process.env.LC_ALL; delete process.env.LC_CTYPE
  // 本用例只验编码。先建会话再接控制客户端，避开 tmux 3.6a 两个控制客户端同时 new-session
  // 时 control_notify_session_created → control_write 空指针崩 server（#087 合跑的 crash report）。
  tmux(["new-session", "-d", "-s", "_mp-ctl-u", "cat"])
  tmux(["new-session", "-d", "-s", "_mp-ctl-nou", "cat"])
  const withU = new TmuxControl({ tmuxArgs: ["-u", ...PREFIX], ctlSession: "_mp-ctl-u", backoffMinMs: 50 })
  const noU = new TmuxControl({ tmuxArgs: [...PREFIX], ctlSession: "_mp-ctl-nou", backoffMinMs: 50 })
  try {
    withU.start(); noU.start()
    await waitFor(() => withU.state === "ready" && noU.state === "ready", 5_000, "两条连接就绪")
    const fmt = ["display-message", "-t", "lang", "-p", "#{session_name}\t#{pane_title}"]
    expect(await withU.run(fmt, 3_000)).toBe("lang\t标题 中文\n")
    expect(await noU.run(fmt, 3_000)).not.toContain("\t")
  } finally {
    withU.close(); noU.close()
    for (const [k, v] of Object.entries(saved)) if (v !== undefined) process.env[k] = v
    tmux(["kill-session", "-t", "_mp-ctl-u"]); tmux(["kill-session", "-t", "_mp-ctl-nou"])
  }
})

test("9 ctl 会话被杀 → down → tmuxRun 回退 fork 照样能用 → 自动重连后回到控制连接", async () => {
  const seen: string[] = []
  ctl.onNotify("exit", () => seen.push("exit"))
  ctl.onNotify("ready", () => seen.push("ready"))
  tmux(["kill-session", "-t", "_mp-hub-ctl"])
  await waitFor(() => ctl.state !== "ready", 3_000, "判断断线")
  const fork0 = tmuxRunCounts.fork
  expect(await tmuxRun(["display-message", "-p", "via-fork"], { timeoutMs: 3_000, write: false })).toBe("via-fork\n")
  expect(tmuxRunCounts.fork).toBe(fork0 + 1)
  await waitFor(() => ctl.state === "ready", 5_000, "重连")
  const ctl0 = tmuxRunCounts.ctl
  expect(await tmuxRun(["display-message", "-p", "via-ctl"], { timeoutMs: 3_000, write: false })).toBe("via-ctl\n")
  expect(tmuxRunCounts.ctl).toBe(ctl0 + 1)
  expect(seen).toEqual(["exit", "ready"])
})

test("K1=0：控制连接就绪也不用它", async () => {
  expect(ctl.state).toBe("ready")
  const { ctl: c0, fork: f0 } = tmuxRunCounts
  process.env.MP_HUB_PERF_K1 = "0"
  try { expect(await tmuxRun(["display-message", "-p", "k1-off"], { timeoutMs: 3_000, write: false })).toBe("k1-off\n") }
  finally { delete process.env.MP_HUB_PERF_K1 }
  expect(tmuxRunCounts).toEqual({ ctl: c0, fork: f0 + 1 })
})

test("12 同一会话的写命令按调用顺序到达：控制连接和 fork 回退两种都验", async () => {
  for (const k1 of ["1", "0"]) {
    process.env.MP_HUB_PERF_K1 = k1
    try {
      const name = `ord${k1}`
      const out = await rawPane(name, "exec cat")
      const sends = Array.from({ length: 40 }, (_, i) =>
        tmuxRun(["send-keys", "-t", name, "-l", `${i},`], { timeoutMs: 5_000, write: true, session: name }))
      await Promise.all(sends)
      const want = Array.from({ length: 40 }, (_, i) => `${i},`).join("")
      await waitFor(() => existsSync(out) && readFileSync(out, "utf8").length >= want.length, 5_000, `${name} 收齐`)
      expect(readFileSync(out, "utf8")).toBe(want)
    } finally { delete process.env.MP_HUB_PERF_K1 }
  }
}, 30_000)

test("K1-2 fetchPanes：就绪时走控制连接，与 fork 的 list-panes 原文相同；K1=0 走 fork", async () => {
  const { ctl: c0, fork: f0 } = tmuxRunCounts
  const viaCtl = await fetchPanes()
  expect(tmuxRunCounts).toEqual({ ctl: c0 + 1, fork: f0 })
  expect(viaCtl).toBe(await fetchTmuxPanes(5_000, PREFIX))
  expect(parsePanes(viaCtl ?? "").get("lang")?.title).toBe("标题 中文")
  process.env.MP_HUB_PERF_K1 = "0"
  try { expect(await fetchPanes()).toBe(viaCtl) } finally { delete process.env.MP_HUB_PERF_K1 }
  expect(tmuxRunCounts).toEqual({ ctl: c0 + 1, fork: f0 + 1 })
})

test("K1-2 TmuxState 接控制连接通知：外面建 / 改名 / 杀会话，不等轮询就刷新", async () => {
  const st = new TmuxState({ fetch: () => fetchPanes() })
  const refreshNow = () => void st.refresh()
  ctl.onNotify("sessions-changed", refreshNow)
  ctl.onNotify("session-renamed", refreshNow)
  await st.refresh()
  expect(st.has("evt1")).toBe(false)
  tmux(["new-session", "-d", "-s", "evt1", "sleep 86400"])
  await waitFor(() => st.has("evt1") === true, 2_000, "建会话后刷新")
  tmux(["rename-session", "-t", "evt1", "evt2"])
  await waitFor(() => st.has("evt2") === true && st.has("evt1") === false, 2_000, "改名后刷新")
  tmux(["kill-session", "-t", "evt2"])
  await waitFor(() => st.has("evt2") === false, 2_000, "杀会话后刷新")
})

test("R1-1 全局 hook 产生的块（flags=0）不消费请求队列：启动 / 出错 / 建会话后的 hook 都不让回包错位", async () => {
  const hooks = ["client-attached", "session-created", "after-new-session", "command-error"]
  for (const h of hooks) tmux(["set-hook", "-g", h, `display-message -p HOOK-${h}`])
  try {
    ctl = startCtl()   // 带着 hook 重新 attach
    await waitFor(() => ctl.state === "ready", 5_000, "带 hook 就绪")
    expect(await ctl.run(["display-message", "-p", "FIRST"], 3_000)).toBe("FIRST\n")
    const [err, next, third] = await Promise.allSettled([
      ctl.run(["has-session", "-t", "nope"], 3_000),
      ctl.run(["display-message", "-p", "NEXT"], 3_000),
      ctl.run(["display-message", "-p", "THIRD"], 3_000),
    ])
    expect(err.status === "rejected" && err.reason instanceof TmuxCommandError && /can't find session/.test(err.reason.stderr)).toBe(true)
    expect([next, third]).toEqual([{ status: "fulfilled", value: "NEXT\n" }, { status: "fulfilled", value: "THIRD\n" }])
    const st = new TmuxState({ fetch: () => fetchPanes() })
    const [, ...snaps] = await Promise.all([
      tmuxRun(["new-session", "-d", "-s", "hk1", "sleep 86400"], { timeoutMs: 3_000, write: true, session: "hk1" }),
      fetchPanes(), fetchPanes(), st.refresh().then(() => null),
    ])
    for (const raw of snaps) if (raw !== null) expect(parsePanes(raw).has("base")).toBe(true)
    await st.refresh()
    expect(st.list()).toEqual(expect.arrayContaining(["base", "hk1"]))
    expect(st.has("hk1")).toBe(true)
  } finally {
    for (const h of hooks) tmux(["set-hook", "-gu", h])
  }
})

// 控制模式下命令 I/O 由 server 直接读写客户端交过去的 stdin/stdout，SIGSTOP 客户端进程卡不住它（实测）。
// 能卡住的是：这条连接的命令队列被队头堵死（11a），或者 tmux server 本身停了（11b）
test("11a 队头被堵（run-shell sleep）→ 最老一条超时判卡死 → 读命令回退 fork 拿到结果 → 后台重连恢复", async () => {
  ctl = startCtl({ wedgeMs: 400 })
  await waitFor(() => ctl.state === "ready", 5_000, "就绪")
  const blocker = ctl.run(["run-shell", "sleep 3"], 5_000).catch(e => e)
  const t0 = Date.now()
  expect(await tmuxRun(["display-message", "-p", "after-wedge"], { timeoutMs: 3_000, write: false })).toBe("after-wedge\n")
  expect(Date.now() - t0).toBeLessThan(2_500)
  await blocker
  await waitFor(() => ctl.state === "ready", 5_000, "重连")
  expect(await ctl.run(["display-message", "-p", "back"], 3_000)).toBe("back\n")
}, 15_000)

test("11b tmux server 被 SIGSTOP → 判卡死、请求按时失败不挂死 → SIGCONT 后重连恢复", async () => {
  ctl = startCtl({ wedgeMs: 400 })
  await waitFor(() => ctl.state === "ready", 5_000, "就绪")
  const pid = Number((await ctl.run(["display-message", "-p", "#{pid}"], 3_000)).trim())
  expect(Bun.spawnSync(["ps", "-o", "command=", "-p", String(pid)]).stdout.toString()).toContain(SOCKET)   // 只停测试 server
  process.kill(pid, "SIGSTOP")
  const watchdog = setTimeout(() => process.kill(pid, "SIGCONT"), 8_000)   // 万一下面挂住，也别把测试 server 留在停住的状态
  try {
    const t0 = Date.now()
    await expect(tmuxRun(["display-message", "-p", "x"], { timeoutMs: 1_000, write: false })).rejects.toThrow()
    expect(Date.now() - t0).toBeLessThan(3_000)
    expect(ctl.state).not.toBe("ready")
  } finally {
    clearTimeout(watchdog)
    process.kill(pid, "SIGCONT")
  }
  await waitFor(() => ctl.state === "ready", 5_000, "SIGCONT 后重连")
  expect(await ctl.run(["display-message", "-p", "back"], 3_000)).toBe("back\n")
}, 15_000)

test("K1-4 写命令在自己的超时内不判卡死：server 停 1.2s（> wedgeMs）期间发的 send-keys 照常成功、只到一次，连接不断", async () => {
  ctl = startCtl({ wedgeMs: 300 })
  await waitFor(() => ctl.state === "ready", 5_000, "就绪")
  const out = await rawPane("patient", "exec cat")
  const pid = Number((await ctl.run(["display-message", "-p", "#{pid}"], 3_000)).trim())
  expect(Bun.spawnSync(["ps", "-o", "command=", "-p", String(pid)]).stdout.toString()).toContain(SOCKET)   // 只停测试 server
  process.kill(pid, "SIGSTOP")
  const watchdog = setTimeout(() => process.kill(pid, "SIGCONT"), 8_000)
  let write: Promise<string>
  try {
    write = tmuxRun(["send-keys", "-t", "patient", "-l", "once"], { timeoutMs: 5_000, write: true, session: "patient" })
    await Bun.sleep(1_200)
    // 旧规则：最老一条 300ms 没回就断开，这条写被拒（可能已经写进管道，server 恢复后照样执行）→ 调用方重发 = 两遍
    expect(ctl.state).toBe("ready")
  } finally {
    clearTimeout(watchdog)
    process.kill(pid, "SIGCONT")
  }
  expect(await write).toBe("")
  await waitFor(() => existsSync(out) && readFileSync(out, "utf8").includes("once"), 5_000, "写到达")
  await Bun.sleep(200)
  expect(readFileSync(out, "utf8")).toBe("once")
  expect(ctl.state).toBe("ready")
}, 15_000)

test("K1-4 审查 R1-2 卡顿的截止点从第一条卡住的算、后来的写续不了期：卡住后的新请求不进卡住的管道（走 fork）；到期断开，在途的写按结果不明拒绝", async () => {
  ctl = startCtl({ wedgeMs: 300 })
  await waitFor(() => ctl.state === "ready", 5_000, "就绪")
  const pid = Number((await ctl.run(["display-message", "-p", "#{pid}"], 3_000)).trim())
  expect(Bun.spawnSync(["ps", "-o", "command=", "-p", String(pid)]).stdout.toString()).toContain(SOCKET)   // 只停测试 server
  tmux(["new-session", "-d", "-s", "dl", "sleep 86400"])
  process.kill(pid, "SIGSTOP")
  const watchdog = setTimeout(() => process.kill(pid, "SIGCONT"), 8_000)
  try {
    const t0 = Date.now()
    const a = tmuxRun(["send-keys", "-t", "dl", "-l", "A"], { timeoutMs: 2_000, write: true, session: "dl" }).catch(e => e)
    await Bun.sleep(1_000)
    const forks = tmuxRunCounts.fork
    // 旧规则：这条写进卡住的连接，最晚期限后移到 t0+3000，连接 2.4s 时还 ready
    const b = tmuxRun(["send-keys", "-t", "dl", "-l", "B"], { timeoutMs: 2_000, write: true }).catch(e => e)
    await Bun.sleep(50)
    expect(tmuxRunCounts.fork).toBe(forks + 1)   // 卡住期间不再接纳：B 没往控制连接里塞，直接走 fork
    await waitFor(() => ctl.state !== "ready", 2_000, "截止点到期断开")
    expect(Date.now() - t0).toBeLessThan(2_600)
    const ea = await a
    expect(ea).toBeInstanceOf(TmuxUncertainError)   // 已经写进管道：断开不证明没执行
    expect(await b).toBeInstanceOf(TmuxUncertainError)   // fork 客户端超时：同样结果不明
  } finally {
    clearTimeout(watchdog)
    process.kill(pid, "SIGCONT")
  }
  await waitFor(() => ctl.state === "ready", 5_000, "SIGCONT 后重连")
  // 读命令失败照旧换 fork 再试，不受影响；tmux 明确答错仍是 TmuxCommandError
  await expect(tmuxRun(["send-keys", "-t", "no-such", "x"], { timeoutMs: 2_000, write: true })).rejects.toBeInstanceOf(TmuxCommandError)
}, 20_000)

test("K1-4 审查 R1-1 背压中断连：server 停住时 5 份大 set-buffer 塞满管道 → 判卡死断开，flush 的 EPIPE 不成 unhandledRejection；恢复后照常", async () => {
  ctl = startCtl({ wedgeMs: 300 })
  await waitFor(() => ctl.state === "ready", 5_000, "就绪")
  const pid = Number((await ctl.run(["display-message", "-p", "#{pid}"], 3_000)).trim())
  expect(Bun.spawnSync(["ps", "-o", "command=", "-p", String(pid)]).stdout.toString()).toContain(SOCKET)   // 只停测试 server
  const unhandled: unknown[] = []
  const onUnhandled = (e: unknown) => { unhandled.push(e) }
  process.on("unhandledRejection", onUnhandled)
  process.kill(pid, "SIGSTOP")
  const watchdog = setTimeout(() => process.kill(pid, "SIGCONT"), 8_000)
  let loads: Promise<PromiseSettledResult<void>[]>
  try {
    const big = "\x01".repeat(64 * 1024)   // 转义后每份约 256KB，远超管道缓冲
    loads = Promise.allSettled(Array.from({ length: 5 }, (_, i) => tmuxLoadBuffer(`bp${i}`, big, 3_000)))
    await waitFor(() => ctl.state !== "ready", 3_000, "判卡死断开")
    await Bun.sleep(300)
  } finally {
    clearTimeout(watchdog)
    process.kill(pid, "SIGCONT")
  }
  await loads
  await Bun.sleep(200)
  process.off("unhandledRejection", onUnhandled)
  expect(unhandled.map(String)).toEqual([])
  await waitFor(() => ctl.state === "ready", 5_000, "SIGCONT 后重连")
  expect(await ctl.run(["display-message", "-p", "back"], 3_000)).toBe("back\n")
}, 20_000)

test("R1-2 server 停住期间反复超时：不漏 fd；握手中的控制客户端不杀，恢复后 server 不 segfault", async () => {
  ctl = startCtl({ wedgeMs: 200 })
  await waitFor(() => ctl.state === "ready", 5_000, "就绪")
  const pid = Number((await ctl.run(["display-message", "-p", "#{pid}"], 3_000)).trim())
  expect(Bun.spawnSync(["ps", "-o", "command=", "-p", String(pid)]).stdout.toString()).toContain(SOCKET)   // 只停测试 server
  const fds = () => readdirSync("/dev/fd").length
  const before = fds()
  process.kill(pid, "SIGSTOP")
  const watchdog = setTimeout(() => process.kill(pid, "SIGCONT"), 10_000)
  try {
    for (let i = 0; i < 12; i++) {
      await expect(tmuxRun(["display-message", "-p", "x"], { timeoutMs: 150, write: false })).rejects.toThrow()
    }
    Bun.gc(true)
    await Bun.sleep(50)
    // 允许一次正在握手的重连尝试（三个管道）；旧实现每次超时漏 2 个，12 次 +24
    expect(fds() - before).toBeLessThanOrEqual(3)
  } finally {
    clearTimeout(watchdog)
    process.kill(pid, "SIGCONT")
  }
  await waitFor(() => ctl.state === "ready", 5_000, "SIGCONT 后重连")
  // 恢复后建会话会给所有控制客户端发 session-created；旧实现杀过的握手中客户端会让 server 在这里崩
  tmux(["new-session", "-d", "-s", "after-stop", "sleep 86400"])
  await Bun.sleep(300)
  expect(() => process.kill(pid, 0)).not.toThrow()
  expect(await ctl.run(["has-session", "-t", "after-stop"], 3_000)).toBe("")
}, 20_000)

/// 停住测试 server 跑 body，无论如何都 SIGCONT（看门狗兜底）
async function whileStopped<T>(pid: number, body: () => Promise<T>, watchdogMs = 8_000): Promise<T> {
  expect(Bun.spawnSync(["ps", "-o", "command=", "-p", String(pid)]).stdout.toString()).toContain(SOCKET)   // 只停测试 server
  process.kill(pid, "SIGSTOP")
  const watchdog = setTimeout(() => process.kill(pid, "SIGCONT"), watchdogMs)
  try { return await body() } finally {
    clearTimeout(watchdog)
    process.kill(pid, "SIGCONT")
  }
}

test("K1-4b 回执晚到：写超时（结果不明）但连接没断，server 恢复后 settled = replied ok，落定判 executed；只到一次", async () => {
  ctl = startCtl({ wedgeMs: 10_000 })
  await waitFor(() => ctl.state === "ready", 5_000, "就绪")
  const out = await rawPane("late", "exec cat")
  const pid = Number((await ctl.run(["display-message", "-p", "#{pid}"], 3_000)).trim())
  const err = await whileStopped(pid, async () => {
    const head = ctl.run(["display-message", "-p", "x"], 8_000).catch(() => "")   // 队头是读：卡死截止点按 wedgeMs（10s）算，写超时时连接还在
    const e = await tmuxRun(["send-keys", "-t", "late", "-l", "L"], { timeoutMs: 400, write: true, session: "late" }).catch(e => e)
    expect(e).toBeInstanceOf(TmuxUncertainError)
    expect(ctl.state).toBe("ready")
    void head
    return e as TmuxUncertainError
  })
  expect(await err.settled).toEqual({ kind: "replied", ok: true, detail: "" })
  expect(await waitTmuxWriteSettled(err, Date.now() + 3_000)).toEqual({ kind: "executed" })
  await waitFor(() => readFileSync(out, "utf8").includes("L"), 3_000, "L 到达")
  await Bun.sleep(200)
  expect(readFileSync(out, "utf8")).toBe("L")
}, 20_000)

test("K1-4b 客户端没了：控制连接被判卡死断开 / fork 客户端超时被杀 → settled = abandoned（进程退出后）；server 恢复、探针往返后下落已定，之后不会再有迟到的写", async () => {
  ctl = startCtl({ wedgeMs: 300 })
  await waitFor(() => ctl.state === "ready", 5_000, "就绪")
  const outA = await rawPane("gone-a", "exec cat")
  const outB = await rawPane("gone-b", "exec cat")
  const pid = Number((await ctl.run(["display-message", "-p", "#{pid}"], 3_000)).trim())
  const [ea, eb] = await whileStopped(pid, async () => {
    const a = tmuxRun(["send-keys", "-t", "gone-a", "-l", "A"], { timeoutMs: 1_000, write: true, session: "gone-a" }).catch(e => e)
    await waitFor(() => ctl.state !== "ready", 3_000, "截止点到期断开")
    process.env.MP_HUB_PERF_K1 = "0"   // B 走 fork：客户端起来、把命令交进 socket，1s 超时被 SIGKILL
    try {
      const b = await tmuxRun(["send-keys", "-t", "gone-b", "-l", "B"], { timeoutMs: 1_000, write: true, session: "gone-b" }).catch(e => e)
      const ea = await a as TmuxUncertainError
      expect(ea).toBeInstanceOf(TmuxUncertainError)
      expect(b).toBeInstanceOf(TmuxUncertainError)
      // server 还停着：两个客户端进程都已经退出，下落报 abandoned（不是 replied）
      expect(await ea.settled).toEqual({ kind: "abandoned" })
      expect(await (b as TmuxUncertainError).settled).toEqual({ kind: "abandoned" })
      expect(readFileSync(outB, "utf8")).toBe("")
      return [ea, b as TmuxUncertainError]
    } finally { delete process.env.MP_HUB_PERF_K1 }
  })
  expect(await waitTmuxWriteSettled(ea, Date.now() + 8_000)).toEqual({ kind: "settled" })
  expect(await waitTmuxWriteSettled(eb, Date.now() + 8_000)).toEqual({ kind: "settled" })
  const a1 = readFileSync(outA, "utf8"), b1 = readFileSync(outB, "utf8")
  // tmux 3.6a：fork 客户端被杀前已经交进 socket 的命令，server 恢复后照样执行（先读到数据、下一轮才读到 EOF）
  expect(b1).toBe("B")
  // 控制连接：管道里的命令和客户端断开在同一轮事件里谁先谁后不定，执行了就一遍，没执行就没有
  expect(["", "A"]).toContain(a1)
  console.log(`[test] 控制连接断开后管道里那条：${a1 ? "执行了" : "没执行"}`)
  await Bun.sleep(1_000)
  expect([readFileSync(outA, "utf8"), readFileSync(outB, "utf8")]).toEqual([a1, b1])   // 落定之后不再变
  await waitFor(() => ctl.state === "ready", 5_000, "SIGCONT 后重连")
}, 25_000)

test("10 kill-server 之后 -N 重连不会把 server 拉起来；server 回来后重连上", async () => {
  ctl = startCtl()
  await waitFor(() => ctl.state === "ready", 5_000, "就绪")
  tmux(["kill-server"])
  await waitFor(() => ctl.state !== "ready", 3_000, "判断断线")
  const noServer = /no server running|error connecting/
  await waitFor(() => noServer.test(tmux(["ls"]).err), 5_000, "server 退出")   // kill-server 是异步的，server 要过一会儿才真退
  expect(await fetchPanes()).toBe("")   // 没起 server：回退 fork，算空表（不是 null）
  await Bun.sleep(800)   // 退避 50→200ms，这段时间里重连了好几次
  const ls = tmux(["ls"])
  expect(ls.code).not.toBe(0)
  expect(ls.err).toMatch(noServer)
  expect(ctl.state).not.toBe("ready")
  ensureServer()
  await waitFor(() => ctl.state === "ready", 5_000, "server 回来后重连")
}, 15_000)
