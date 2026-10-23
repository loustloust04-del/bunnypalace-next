// 粟粟 10-11：军机处默认关闭，MP_CC_WARROOM=1 才打开。
// 自起两个隔离 hub（env 集同 terminal-t1.test.ts）：随机高位端口、临时 secrets / HOME、MP_CC_TMUX_DRY_RUN=1 —— 绝不连生产 7890。
// 一个不设 MP_CC_WARROOM（默认关），一个设 =1（确认开关还能打开）。
import { test, expect, beforeAll, afterAll, describe } from "bun:test"
import { WebSocket } from "ws"
import { existsSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

interface TestHub { port: number; secrets: string; home: string; proc: ReturnType<typeof Bun.spawn>; out: () => string }

async function startHub(warroom: string | undefined): Promise<TestHub> {
  const port = 18890 + Math.floor(Math.random() * 1000)
  const secrets = mkdtempSync(join(tmpdir(), "cc-hub-wroff-"))
  const home = mkdtempSync(join(tmpdir(), "cc-hub-wroff-home-"))
  const { MP_CC_WARROOM: _inherited, ...baseEnv } = process.env   // test-preload 设过 "0"，这里要测真默认
  const proc = Bun.spawn(["bun", "run", "hub.ts"], {
    cwd: import.meta.dir,
    stdout: "pipe", stderr: "pipe",
    env: {
      ...baseEnv,
      HOME: home,
      MP_CC_TMUX_DRY_RUN: "1", MP_CC_HUB_TOKEN: "test-token", MP_CC_HUB_PORT: String(port), MP_CC_HUB_HOST: "127.0.0.1",
      MP_CC_SECRETS_DIR: secrets, MP_CC_AGENT_DIR: secrets, MP_CC_WORKDIR: secrets, MP_CODEX_WORKDIR: join(secrets, "gpt-rp"),
      MP_CC_THINKING_SPOOL: join(secrets, "spool"),
      MP_APNS_KEY_PATH: join(secrets, "no-such-key.p8"), MP_CC_LA_INTERVAL_MS: "3600000",
      MP_CC_WARROOM_CC_ROOT: join(home, "cc-projects"), MP_CC_WARROOM_CODEX_ROOT: join(home, "codex-sessions"),
      ...(warroom === undefined ? {} : { MP_CC_WARROOM: warroom }),
    },
  })
  let out = ""
  const dec = new TextDecoder()
  void (async () => { for await (const c of proc.stdout as ReadableStream<Uint8Array>) out += dec.decode(c) })()
  void (async () => { for await (const c of proc.stderr as ReadableStream<Uint8Array>) out += dec.decode(c) })()
  const deadline = Date.now() + 8_000
  while (Date.now() < deadline) {
    if (proc.exitCode !== null) throw new Error(`test hub failed to start (exit=${proc.exitCode})\n${out}`)
    try { if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) return { port, secrets, home, proc, out: () => out } } catch {}
    await Bun.sleep(100)
  }
  throw new Error(`test hub did not become healthy within 8s\n${out}`)
}

async function waitForLog(hub: TestHub, needle: string, ms = 5_000): Promise<boolean> {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) { if (hub.out().includes(needle)) return true; await Bun.sleep(50) }
  return false
}

async function wsAsk(port: number, msg: Record<string, unknown>, resultType: string): Promise<Record<string, unknown>> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/cc?token=test-token`)
  try {
    await new Promise<void>((resolve, reject) => {
      ws.on("open", resolve); ws.on("error", reject)
      setTimeout(() => reject(new Error("connect timeout")), 2000)
    })
    const got = new Promise<Record<string, unknown>>((resolve, reject) => {
      ws.on("message", (d) => { const f = JSON.parse(d.toString()); if (f.type === resultType) resolve(f) })
      setTimeout(() => reject(new Error(`no ${resultType}`)), 3000)
    })
    ws.send(JSON.stringify(msg))
    return await got
  } finally { ws.close() }
}

const boardSnapshot = (port: number) => wsAsk(port, { type: "warroom_board" }, "warroom_board_result")

describe("默认（不设 MP_CC_WARROOM）", () => {
  let hub: TestHub
  beforeAll(async () => { hub = await startHub(undefined) })
  afterAll(() => { hub?.proc.kill() })

  test("启动打一行默认关闭，不开库、不起 worker、不建收据目录", async () => {
    expect(await waitForLog(hub, "[warroom] 军机处默认关闭（MP_CC_WARROOM=1 打开）")).toBe(true)
    await Bun.sleep(300)
    expect(existsSync(join(hub.secrets, "warroom.db"))).toBe(false)
    expect(existsSync(join(hub.home, ".mp-warroom"))).toBe(false)
    expect(hub.out()).not.toContain("普查扫描")
    expect(hub.out()).not.toContain("ledger + dispatcher armed")
    expect(hub.out()).not.toContain("inspection loop armed")
  })

  test("HTTP /warroom/* 一律 503", async () => {
    const base = `http://127.0.0.1:${hub.port}/warroom`
    expect((await fetch(`${base}/sessions?token=test-token`)).status).toBe(503)
    expect((await fetch(`${base}/tasks?token=test-token`)).status).toBe(503)
    for (const ep of ["dispatch", "verdict"]) {
      const r = await fetch(`${base}/${ep}?token=test-token`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ actor: "mp-cc" }) })
      expect(`${ep} ${r.status}`).toBe(`${ep} 503`)
    }
  })

  test("看板快照 ready:false，空奏折", async () => {
    const snap = await boardSnapshot(hub.port)
    expect(snap.ready).toBe(false)
    expect(snap.tasks).toEqual([])
  })

  test("warroom_request 回 not ready，不建库", async () => {
    const r = await wsAsk(hub.port, { type: "warroom_request", text: "测试需求" }, "warroom_request_result")
    expect(r).toMatchObject({ ok: false, error: "not ready" })
    expect(existsSync(join(hub.secrets, "warroom.db"))).toBe(false)
  })
})

describe("MP_CC_WARROOM=1", () => {
  let hub: TestHub
  beforeAll(async () => { hub = await startHub("1") })
  afterAll(() => { hub?.proc.kill() })

  test("开关打开：开库、账本 + 派发器 + 验收 loop 都起，看板 ready", async () => {
    expect(await waitForLog(hub, "M2 inspection loop armed")).toBe(true)
    expect(hub.out()).not.toContain("军机处默认关闭")
    expect(existsSync(join(hub.secrets, "warroom.db"))).toBe(true)
    expect(existsSync(join(hub.home, ".mp-warroom", "receipts"))).toBe(true)
    expect((await fetch(`http://127.0.0.1:${hub.port}/warroom/tasks?token=test-token`)).status).toBe(200)
    expect((await boardSnapshot(hub.port)).ready).toBe(true)
  })
})
