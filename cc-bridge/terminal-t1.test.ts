// #055 刀 5：end_window 帧 + terminal_seen 把 done 翻回 idle。
// 自起一个隔离 hub（env 集同 hub.test.ts / scripts/la-isolated-hub.sh）：随机高位端口、临时 secrets / agent、
// MP_CC_TMUX_DRY_RUN=1 —— 绝不连生产 7890，不碰任何 mp-cc* tmux session。
// PATH 最前面垫一个假 tmux（只记账、exit 1）：hub 里绕过 runner 直接 execFileSync("tmux") 的地方一调就留痕，最后一条测试断言账本是空的。
import { test, expect, beforeAll, afterAll } from "bun:test"
import { WebSocket } from "ws"
import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { randomUUID } from "node:crypto"
import { tmpdir } from "node:os"
import { join } from "node:path"

const TEST_PORT = 18890 + Math.floor(Math.random() * 1000)
const CC_URL = `ws://127.0.0.1:${TEST_PORT}/cc?token=test-token`
const TEST_SECRETS = mkdtempSync(join(tmpdir(), "cc-hub-t1-"))
const TEST_AGENT_DIR = mkdtempSync(join(tmpdir(), "cc-hub-t1-agent-"))
const TEST_CC_WORKDIR = mkdtempSync(join(tmpdir(), "cc-hub-t1-workdir-"))
const DONE_SESSION = `t1test-done-${randomUUID().slice(0, 8)}`
const FAKE_BIN = mkdtempSync(join(tmpdir(), "cc-hub-t1-bin-"))
const TMUX_CALLS = join(FAKE_BIN, "calls.log")
writeFileSync(join(FAKE_BIN, "tmux"), `#!/bin/sh\necho "$*" >> "${TMUX_CALLS}"\nexit 1\n`)
chmodSync(join(FAKE_BIN, "tmux"), 0o755)

writeFileSync(join(TEST_SECRETS, "la-phase.json"), JSON.stringify({
  [DONE_SESSION]: { phase: "done", since_unix: 1_000, run_id: "r-1000-1", updated_unix: 2_000 },
}))

let hubProcess: ReturnType<typeof Bun.spawn> | undefined

beforeAll(async () => {
  hubProcess = Bun.spawn(["bun", "run", "hub.ts"], {
    cwd: import.meta.dir,
    env: {
      ...process.env,
      PATH: `${FAKE_BIN}:${process.env.PATH ?? ""}`,
      MP_CC_TMUX_DRY_RUN: "1", MP_CC_HUB_TOKEN: "test-token", MP_CC_HUB_PORT: String(TEST_PORT),
      MP_CC_SECRETS_DIR: TEST_SECRETS, MP_CC_AGENT_DIR: TEST_AGENT_DIR, MP_CC_WORKDIR: TEST_CC_WORKDIR,
      MP_CC_THINKING_SPOOL: join(TEST_SECRETS, "spool"),
      MP_APNS_KEY_PATH: join(TEST_SECRETS, "no-such-key.p8"),
      MP_CC_LA_INTERVAL_MS: "3600000",
      MP_CC_WARROOM: "0",
    },
  })
  const deadline = Date.now() + 5_000
  while (Date.now() < deadline) {
    if (hubProcess.exitCode !== null) {
      throw new Error(`test hub failed to start (exit=${hubProcess.exitCode}) — refusing to run tests against anything else`)
    }
    try {
      const health = await fetch(`http://127.0.0.1:${TEST_PORT}/health`)
      if (health.ok) return
    } catch {}
    await new Promise(r => setTimeout(r, 100))
  }
  throw new Error("test hub did not become healthy within 5s")
})

afterAll(() => {
  hubProcess?.kill()
})

interface Frame { type: string; [key: string]: unknown }

async function openMP(): Promise<{ ws: WebSocket; frames: Frame[] }> {
  const ws = new WebSocket(CC_URL)
  const frames: Frame[] = []
  ws.on("message", data => frames.push(JSON.parse(data.toString()) as Frame))
  await new Promise<void>((resolve, reject) => {
    ws.on("open", resolve)
    ws.on("error", reject)
    setTimeout(() => reject(new Error("connect timeout")), 2000)
  })
  return { ws, frames }
}

async function waitFor(frames: Frame[], match: (frame: Frame) => boolean, from = 0): Promise<Frame> {
  const deadline = Date.now() + 3_000
  while (Date.now() < deadline) {
    const hit = frames.slice(from).find(match)
    if (hit) return hit
    await new Promise(r => setTimeout(r, 20))
  }
  throw new Error("frame timeout")
}

async function listWindowCodes(ws: WebSocket, frames: Frame[], includeClosed: boolean): Promise<string[]> {
  const from = frames.length
  ws.send(JSON.stringify({ type: "list_windows", include_closed: includeClosed }))
  const result = await waitFor(frames, frame => frame.type === "list_windows_result", from)
  return (result.windows as Array<{ code: string }>).map(window => window.code)
}

test("end_window：回 window_ended ok，之后 list_windows（含 include_closed）都不再有它", async () => {
  const { ws, frames } = await openMP()
  ws.send(JSON.stringify({ type: "open_window", engine: "shell" }))
  const opened = await waitFor(frames, frame => frame.type === "window_opened")
  const code = opened.code as string
  ws.send(JSON.stringify({ type: "open_window", engine: "shell" }))
  const other = (await waitFor(frames, frame => frame.type === "window_opened" && frame.code !== code)).code as string
  ws.send(JSON.stringify({ type: "close_window", code: other }))
  await waitFor(frames, frame => frame.type === "window_closed" && frame.code === other)

  expect(await listWindowCodes(ws, frames, true)).toEqual(expect.arrayContaining([code, other]))

  ws.send(JSON.stringify({ type: "end_window", code }))
  expect(await waitFor(frames, frame => frame.type === "window_ended" && frame.code === code)).toEqual({ type: "window_ended", code, ok: true })
  ws.send(JSON.stringify({ type: "end_window", code: `mp-win-${other}` }))
  expect(await waitFor(frames, frame => frame.type === "window_ended" && frame.code === other)).toEqual({ type: "window_ended", code: other, ok: true })

  expect(await listWindowCodes(ws, frames, false)).not.toContain(code)
  const withClosed = await listWindowCodes(ws, frames, true)
  expect(withClosed).not.toContain(code)
  expect(withClosed).not.toContain(other)

  ws.send(JSON.stringify({ type: "restore_window", code: other }))
  expect((await waitFor(frames, frame => frame.type === "window_restored" && frame.code === other)).ok).toBe(false)
  expect(await listWindowCodes(ws, frames, true)).not.toContain(other)

  const stored = JSON.parse(readFileSync(join(TEST_SECRETS, "windows.json"), "utf-8")) as Array<{ code: string; endedAt?: string }>
  expect(stored.find(window => window.code === code)?.endedAt).toBeString()
  ws.close()
})

test("restore_window 收起的窗口：ok=true，回到开着的列表", async () => {
  const { ws, frames } = await openMP()
  ws.send(JSON.stringify({ type: "open_window", engine: "shell" }))
  const code = (await waitFor(frames, frame => frame.type === "window_opened")).code as string
  ws.send(JSON.stringify({ type: "close_window", code }))
  await waitFor(frames, frame => frame.type === "window_closed" && frame.code === code)
  ws.send(JSON.stringify({ type: "restore_window", code }))
  expect((await waitFor(frames, frame => frame.type === "window_restored" && frame.code === code)).ok).toBe(true)
  expect(await listWindowCodes(ws, frames, false)).toContain(code)
  ws.close()
})

test("list_windows 每个窗口带 title / engine / phase", async () => {
  const { ws, frames } = await openMP()
  ws.send(JSON.stringify({ type: "open_window", engine: "claude" }))
  const code = (await waitFor(frames, frame => frame.type === "window_opened")).code as string
  ws.send(JSON.stringify({ type: "rename_window", code, title: "跑测试" }))
  const from = frames.length
  ws.send(JSON.stringify({ type: "list_windows", include_closed: true }))
  const result = await waitFor(frames, frame => frame.type === "list_windows_result", from)
  const window = (result.windows as Array<Record<string, unknown>>).find(item => item.code === code)
  expect(window).toMatchObject({ code, title: "跑测试", engine: "claude", phase: "idle", alive: true })
  ws.close()
})

test("end_window 未知 code：ok=false", async () => {
  const { ws, frames } = await openMP()
  ws.send(JSON.stringify({ type: "end_window", code: "nope00" }))
  expect(await waitFor(frames, frame => frame.type === "window_ended")).toEqual({ type: "window_ended", code: "nope00", ok: false })
  ws.close()
})

test("terminal_seen：done 的 session 翻回 idle 并推 session_phase", async () => {
  const { ws, frames } = await openMP()
  ws.send(JSON.stringify({ type: "client_info", platform: "test" }))
  await waitFor(frames, frame => frame.type === "session_phase" && frame.session_name === DONE_SESSION && frame.phase === "done")
  const from = frames.length
  ws.send(JSON.stringify({ type: "terminal_seen", session_name: DONE_SESSION }))
  await waitFor(frames, frame => frame.type === "session_phase" && frame.session_name === DONE_SESSION && frame.phase === "idle", from)
  const stored = JSON.parse(readFileSync(join(TEST_SECRETS, "la-phase.json"), "utf-8")) as Record<string, { phase: string; run_id?: string }>
  expect(stored[DONE_SESSION].phase).toBe("idle")
  expect(stored[DONE_SESSION].run_id).toBe("r-1000-1")
  ws.close()
})

test("全程没有一次真实 tmux 调用", () => {
  expect(existsSync(TMUX_CALLS) ? readFileSync(TMUX_CALLS, "utf-8") : "").toBe("")
})
