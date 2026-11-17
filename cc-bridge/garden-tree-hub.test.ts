import { afterAll, beforeAll, expect, test } from "bun:test"
import { WebSocket } from "ws"
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { RECEIPTS_FILE, SAVED_DIR, SYNC_DIR } from "./garden-tree.ts"
import { FakeGarden } from "./garden-tree-testkit.ts"

// 端到端（不靠真设备）：真的 hub 进程（临时端口）+ 假花园（经 WebSocket 说 app 那头的帧）+ 临时目录当 CC 家。
// 「CC 改文件」就是测试直接改那个临时目录里的文件。绝不碰 7890 和真的 ~/Desktop/cc-rp。全虚构

const PORT = 19890 + Math.floor(Math.random() * 1000)
const SECRETS = mkdtempSync(join(tmpdir(), "garden-hub-secrets-"))
const AGENT = mkdtempSync(join(tmpdir(), "garden-hub-agent-"))
const WORKDIR = mkdtempSync(join(tmpdir(), "garden-hub-cchome-"))
const FLOOR = "星砚楼"
const CARD = "memory/cards/岚舟/ab12cd34.md"
const PERSONA = ".prompt/fields/characterDescription.txt"
const TIMELINE = "memory/timeline/2026-11-12.md"
const card = (tags: string) => `---\nid: ab12cd34-0000-4000-8000-000000000000\nstate: Archive\nabout: 岚舟\ntags: [${tags}]\npinned: no\n---\n\n岚舟每周三去槐序巷皮影作坊学雕皮影。\n`

let hubProcess: ReturnType<typeof Bun.spawn> | undefined

async function startHub(): Promise<void> {
  hubProcess = Bun.spawn(["bun", "run", "hub.ts"], {
    cwd: import.meta.dir,
    stdout: "ignore", stderr: "ignore",
    env: {
      ...process.env,
      MP_CC_TMUX_DRY_RUN: "1", MP_CC_HUB_TOKEN: "test-token", MP_CC_HUB_PORT: String(PORT),
      MP_CC_SECRETS_DIR: SECRETS, MP_CC_AGENT_DIR: AGENT, MP_CC_WORKDIR: WORKDIR, MP_CODEX_WORKDIR: join(SECRETS, "gpt-rp"),
      MP_CC_THINKING_SPOOL: join(SECRETS, "spool"), CC_MEMORY_SYNC_DIR: join(SECRETS, "cc-memory"),
      MP_APNS_KEY_PATH: join(SECRETS, "no-such-key.p8"), MP_CC_LA_INTERVAL_MS: "3600000", MP_CC_WARROOM: "0",
      MP_GARDEN_TREE_SETTLE_MS: "200",
    },
  })
  const deadline = Date.now() + 8_000
  while (Date.now() < deadline) {
    if (hubProcess.exitCode !== null) throw new Error(`测试 hub 没起来（exit=${hubProcess.exitCode}）`)
    try { if ((await fetch(`http://127.0.0.1:${PORT}/health`)).ok) return } catch {}
    await new Promise((r) => setTimeout(r, 100))
  }
  throw new Error("测试 hub 8 秒内没起来")
}

async function stopHub(): Promise<void> {
  hubProcess?.kill()
  await hubProcess?.exited
  hubProcess = undefined
}

async function connect(device = "device-a"): Promise<{ ws: WebSocket; garden: FakeGarden }> {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/cc?token=test-token`)
  await new Promise<void>((resolve, reject) => { ws.on("open", () => resolve()); ws.on("error", reject) })
  const garden = new FakeGarden((frame) => { if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(frame)) }, FLOOR, device)
  ws.on("message", (raw) => { try { garden.receive(JSON.parse(raw.toString())) } catch {} })
  return { ws, garden }
}

const disk = (path: string) => join(WORKDIR, "garden-memory", FLOOR, path)
const read = (path: string) => readFileSync(disk(path), "utf8")
const put = (path: string, content: string) => { mkdirSync(dirname(disk(path)), { recursive: true }); writeFileSync(disk(path), content) }
const receipts = () => { try { return readFileSync(disk(`${SYNC_DIR}/${RECEIPTS_FILE}`), "utf8") } catch { return "" } }
async function until(what: string, ok: () => boolean, ms = 12_000): Promise<void> {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) { if (ok()) return; await new Promise((r) => setTimeout(r, 100)) }
  throw new Error(`等不到：${what}\n回执现在是：\n${receipts()}`)
}
function tree(dir = join(WORKDIR, "garden-memory", FLOOR), rel = ""): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const child = rel === "" ? e.name : `${rel}/${e.name}`
    if (child === SYNC_DIR) return []
    return e.isDirectory() ? tree(join(dir, e.name), child) : [child]
  }).sort()
}
const expectMirrors = (g: FakeGarden) => {
  expect(tree()).toEqual([...g.files.keys()].sort())
  for (const [path, content] of g.files) expect(read(path)).toBe(content)
}

beforeAll(startHub)
afterAll(async () => {
  await stopHub()
  for (const dir of [SECRETS, AGENT, WORKDIR]) rmSync(dir, { recursive: true, force: true })
})

test("花园导出 → 电脑上改一条记忆条目的 tags、改助手设定、新建一条 → 落下 → 两边一致、回执三笔；再加冲突和只读", async () => {
  const { ws, garden } = await connect()
  garden.files.set("README.md", "# 花园记忆 · 星砚楼\n")
  garden.files.set(CARD, card("皮影, 周三"))
  garden.files.set(TIMELINE, "# 2026-11-12\n\n主调：雕皮影。\n")
  garden.files.set(PERSONA, "星砚说话慢，爱用比喻。\n")
  expect(await garden.sync()).toMatchObject({ ok: true, files: 4, written: 4 })
  expectMirrors(garden)

  put(CARD, card("皮影, 周三, 槐序巷"))
  put(PERSONA, "星砚说话慢，爱用比喻，不催人。")
  put("memory/cards/岚舟/新条目.md", "---\ntags: [纸鸢]\n---\n\n岚舟想要一只燕子形的纸鸢。")
  await until("三笔都落下", () => (receipts().match(/· 落下了 ·/g)?.length ?? 0) === 3)
  expect(garden.files.get(CARD)).toContain("tags: [皮影, 周三, 槐序巷]")
  expect(garden.files.get(PERSONA)).toBe("星砚说话慢，爱用比喻，不催人。\n")
  expect(garden.files.get("memory/cards/岚舟/c0000001.md")).toContain("燕子形的纸鸢")
  expectMirrors(garden)
  expect(await garden.sync()).toMatchObject({ ok: true, written: 0, removed: 0, pending: 0 })
  expectMirrors(garden)
  expect(receipts()).toContain("memory/cards/岚舟/新条目.md → memory/cards/岚舟/c0000001.md")

  // 冲突：花园里先变了
  garden.files.set(CARD, card("皮影, 周四"))
  put(CARD, card("CC 照旧版改的"))
  // 只读：时间轴
  put(TIMELINE, "# 2026-11-12\n\nCC 改的主调。\n")
  await until("冲突和只读都有回执", () => receipts().includes("· 冲突，没落 ·") && receipts().includes("· 只读，没落 ·"))
  expect(read(CARD)).toBe(card("皮影, 周四"))
  expect(read(TIMELINE)).toBe("# 2026-11-12\n\n主调：雕皮影。\n")
  const saved = readdirSync(disk(`${SYNC_DIR}/${SAVED_DIR}`))
  expect(saved.some((name) => readFileSync(disk(`${SYNC_DIR}/${SAVED_DIR}/${name}`), "utf8").includes("CC 照旧版改的"))).toBe(true)
  expectMirrors(garden)
  ws.close()
}, 40_000)

test("app 不在线：改动排着、回执看得出没落；hub 重启后还在；app 连上按顺序落下", async () => {
  const first = await connect()
  first.garden.files.set("README.md", "# 花园记忆 · 星砚楼\n")
  first.garden.files.set(PERSONA, "星砚说话慢。\n")
  expect((await first.garden.sync(true)).ok).toBe(true)
  first.ws.close()
  await new Promise((r) => setTimeout(r, 200))

  put(PERSONA, "app 不在的时候 CC 改的。")
  put("memory/cards/岚舟/离线新条目.md", "岚舟周末要去放纸鸢。")
  await until("回执写着还没落", () => receipts().includes("## 还没落进花园（2）") && receipts().includes("花园没连着，连上就送"))
  expect(read(PERSONA)).toBe("app 不在的时候 CC 改的。")

  await stopHub()
  await startHub()
  expect(read(PERSONA)).toBe("app 不在的时候 CC 改的。")
  expect(existsSync(disk("memory/cards/岚舟/离线新条目.md"))).toBe(true)

  const back = await connect()
  back.garden.files = first.garden.files
  expect(await back.garden.sync()).toMatchObject({ ok: true, pending: 2 })
  await until("两笔落下", () => receipts().includes("## 还没落进花园（0）"))
  expect(back.garden.files.get(PERSONA)).toBe("app 不在的时候 CC 改的。\n")
  expect([...back.garden.files.keys()].some((p) => /^memory\/cards\/岚舟\/c\d+\.md$/.test(p))).toBe(true)
  expectMirrors(back.garden)
  back.ws.close()
}, 60_000)
