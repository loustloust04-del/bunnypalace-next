import { afterAll, beforeAll, expect, test } from "bun:test"
import { execFileSync } from "node:child_process"
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { buildPasteResultPayload, MAX_PASTE_BYTES, pasteToTmux } from "./terminal-paste"
import { CTL_SET_BUFFER_MAX_BYTES, startSharedTmuxControl, stopSharedTmuxControl, tmuxRunCounts } from "./tmux-control"

// 隔离 tmux server（-L 独立 socket），不碰默认 server / 生产 hub；pasteToTmux 经 MP_CC_TMUX_SOCKET 落到这里
const SOCKET = `mp053-${process.pid}`
const PREFIX = ["-L", SOCKET]
const savedEnv = { socket: process.env.MP_CC_TMUX_SOCKET, k1: process.env.MP_HUB_PERF_K1 }
process.env.MP_CC_TMUX_SOCKET = SOCKET
delete process.env.MP_HUB_PERF_K1
let dir = ""

function tmux(...args: string[]) {
  return execFileSync("tmux", [...PREFIX, ...args]).toString()
}

/// pane 里跑：可选开 2004 → raw 模式 → 把收到的字节原样写进 out 文件
function startPane(name: string, bracketed: boolean): string {
  const out = join(dir, `${name}.out`)
  const ready = join(dir, `${name}.ready`)
  const enable = bracketed ? `printf '\\033[?2004h';` : ""
  tmux("new-session", "-d", "-s", name, "-x", "80", "-y", "24",
    `sh -c "${enable} stty raw -echo; touch '${ready}'; exec cat > '${out}'"`)
  const deadline = Date.now() + 5000
  while (!existsSync(ready)) {
    if (Date.now() > deadline) throw new Error(`pane ${name} 没起来`)
    Bun.sleepSync(20)
  }
  return out
}

function readUntil(path: string, needle: string): string {
  const deadline = Date.now() + 5000
  while (Date.now() < deadline) {
    const s = existsSync(path) ? readFileSync(path, "utf8") : ""
    if (s.includes(needle)) return s
    Bun.sleepSync(20)
  }
  return existsSync(path) ? readFileSync(path, "utf8") : ""
}

/// 两档：ctl = 控制连接就绪（set-buffer 走它）；fork = K1=0（load-buffer 走 stdin，与原来的同步版同一条命令）
async function inMode<T>(mode: "ctl" | "fork", body: () => Promise<T>): Promise<T> {
  if (mode === "fork") process.env.MP_HUB_PERF_K1 = "0"
  else {
    const ctl = startSharedTmuxControl({ backoffMinMs: 50, backoffMaxMs: 200, wedgeMs: 10_000 })
    const deadline = Date.now() + 5000
    while (ctl.state !== "ready") {
      if (Date.now() > deadline) throw new Error("控制连接没就绪")
      await Bun.sleep(10)
    }
  }
  try { return await body() } finally {
    delete process.env.MP_HUB_PERF_K1
    stopSharedTmuxControl()
  }
}

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), "mp053-"))
  tmux("new-session", "-d", "-s", "base", "sleep 86400")
})
afterAll(() => {
  stopSharedTmuxControl()
  try { tmux("kill-server") } catch {}
  if (savedEnv.socket === undefined) delete process.env.MP_CC_TMUX_SOCKET
  else process.env.MP_CC_TMUX_SOCKET = savedEnv.socket
  if (savedEnv.k1 === undefined) delete process.env.MP_HUB_PERF_K1
  else process.env.MP_HUB_PERF_K1 = savedEnv.k1
  rmSync(dir, { recursive: true, force: true })
})

for (const mode of ["ctl", "fork"] as const) {
  test(`[${mode}] 应用开了 bracketed paste：包 ESC[200~ … ESC[201~，换行变 CR，不逐行执行`, () => inMode(mode, async () => {
    const out = startPane(`bp-on-${mode}`, true)
    const before = { ...tmuxRunCounts }
    expect(await pasteToTmux(`bp-on-${mode}`, "echo a\necho b")).toEqual({ ok: true })
    expect(readUntil(out, "\x1b[201~")).toBe("\x1b[200~echo a\recho b\x1b[201~")
    // ctl 档两条（set-buffer + paste-buffer）都不 fork；fork 档两条都 fork
    if (mode === "ctl") expect([tmuxRunCounts.ctl - before.ctl, tmuxRunCounts.fork - before.fork]).toEqual([2, 0])
    else expect([tmuxRunCounts.ctl - before.ctl, tmuxRunCounts.fork - before.fork]).toEqual([0, 2])
  }))

  test(`[${mode}] 应用没开：不包（跟 Terminal.app 一样）`, () => inMode(mode, async () => {
    const out = startPane(`bp-off-${mode}`, false)
    expect(await pasteToTmux(`bp-off-${mode}`, "ls\npwd")).toEqual({ ok: true })
    expect(readUntil(out, "pwd")).toBe("ls\rpwd")
  }))

  test(`[${mode}] 超过 4096 字节（T26 的线）完整到达，中文不碎；引号 / $ / ~ / 反斜杠 / 结尾 ; 原样`, () => inMode(mode, async () => {
    const out = startPane(`big-${mode}`, true)
    const text = "长".repeat(5000) + `"q" $HOME ~/x \\n \\; #{pane_id} END;`   // 15000+ 字节，仍在控制连接 set-buffer 的上限内
    expect(await pasteToTmux(`big-${mode}`, text)).toEqual({ ok: true })
    expect(readUntil(out, "\x1b[201~")).toBe(`\x1b[200~${text}\x1b[201~`)
  }))

  test(`[${mode}] 失败要回原因，不静默`, () => inMode(mode, async () => {
    const r = await pasteToTmux("no-such-session", "x")
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toMatch(/^paste: can't find/)
    expect(await pasteToTmux("bp-on-ctl", "")).toEqual({ ok: false, reason: "空内容" })
    expect((await pasteToTmux("bp-on-ctl", "a".repeat(MAX_PASTE_BYTES + 1))).ok).toBe(false)
    // 失败时临时 buffer 不残留
    expect(tmux("list-buffers", "-F", "#{buffer_name}")).not.toContain("mp-paste-")
  }))
}

test("控制连接就绪时：>64KB / 含 NUL 的粘贴走 fork load-buffer（stdin），paste-buffer 仍走控制连接；内容逐字到达", () => inMode("ctl", async () => {
  const out = startPane("huge", true)
  const text = "大".repeat(Math.ceil(CTL_SET_BUFFER_MAX_BYTES / 3) + 10) + "TAIL"
  let before = { ...tmuxRunCounts }
  expect(await pasteToTmux("huge", text)).toEqual({ ok: true })
  expect(readUntil(out, "\x1b[201~")).toBe(`\x1b[200~${text}\x1b[201~`)
  expect([tmuxRunCounts.ctl - before.ctl, tmuxRunCounts.fork - before.fork]).toEqual([1, 1])

  const nulOut = startPane("nul", false)
  before = { ...tmuxRunCounts }
  expect(await pasteToTmux("nul", "a\0b")).toEqual({ ok: true })
  expect(readUntil(nulOut, "b")).toBe("a\0b")
  expect([tmuxRunCounts.ctl - before.ctl, tmuxRunCounts.fork - before.fork]).toEqual([1, 1])
}))

test("terminal_paste_result 帧", () => {
  expect(JSON.parse(buildPasteResultPayload("mp-win-1", "r1", { ok: true }))).toEqual({
    type: "terminal_paste_result", session_name: "mp-win-1", request_id: "r1", ok: true,
  })
  expect(JSON.parse(buildPasteResultPayload("mp-win-1", "r2", { ok: false, reason: "x" }))).toEqual({
    type: "terminal_paste_result", session_name: "mp-win-1", request_id: "r2", ok: false, reason: "x",
  })
})
