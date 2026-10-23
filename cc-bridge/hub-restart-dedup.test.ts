import { test, expect, afterAll } from "bun:test"
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, existsSync, readFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

// 10-11 审：hub 重启后，待投目录里迟到的短前缀（A+B）不能再投一遍。
// 真起两次隔离 hub（随机高位端口、临时 secrets / 待投目录、tmux 干跑），绝不碰 7890。
const PORT = 19000 + Math.floor(Math.random() * 900)
const SECRETS = mkdtempSync(join(tmpdir(), "cc-hub-restart-"))
const SPOOL = join(SECRETS, "spool")
mkdirSync(SPOOL, { recursive: true })
let hub: ReturnType<typeof Bun.spawn> | undefined

async function startHub(): Promise<void> {
  hub = Bun.spawn(["bun", "run", "hub.ts"], {
    cwd: import.meta.dir,
    stdout: "ignore", stderr: "ignore",
    env: {
      ...process.env,
      MP_CC_TMUX_DRY_RUN: "1", MP_CC_HUB_TOKEN: "test-token", MP_CC_HUB_PORT: String(PORT),
      MP_CC_SECRETS_DIR: SECRETS, MP_CC_AGENT_DIR: mkdtempSync(join(tmpdir(), "cc-hub-restart-agent-")),
      MP_CC_WORKDIR: mkdtempSync(join(tmpdir(), "cc-hub-restart-wd-")), MP_CODEX_WORKDIR: join(SECRETS, "gpt-rp"),
      MP_CC_THINKING_SPOOL: SPOOL, MP_CC_REPLY_VIA_TEXT: "all", MP_CC_WARROOM: "0",
      CC_MEMORY_SYNC_DIR: mkdtempSync(join(tmpdir(), "cc-hub-restart-mem-")),
      MP_APNS_KEY_PATH: join(SECRETS, "no-such-key.p8"), MP_CC_LA_INTERVAL_MS: "3600000",
    },
  })
  const deadline = Date.now() + 8_000
  while (Date.now() < deadline) {
    if (hub.exitCode !== null) throw new Error(`test hub exited ${hub.exitCode}`)
    try { if ((await fetch(`http://127.0.0.1:${PORT}/health`)).ok) return } catch {}
    await new Promise(r => setTimeout(r, 100))
  }
  throw new Error("test hub not healthy")
}
async function stopHub(): Promise<void> { hub?.kill(); await hub?.exited; hub = undefined }
afterAll(async () => { await stopHub() })

const post = async (body: object) => (await fetch(`http://127.0.0.1:${PORT}/thinking`, {
  method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
})).json()
function spoolFile(name: string, body: object): string {
  const f = join(SPOOL, name)
  writeFileSync(f, JSON.stringify(body))
  const old = new Date(Date.now() - 60_000); utimesSync(f, old, old)   // 待投目录只补 15s 以前的
  return f
}
const replyLog = () => JSON.parse(readFileSync(join(SECRETS, "reply-log.json"), "utf8")) as any[]

test("先投 ABC → 重启 → 待投目录里的 A+B 才到：不再投（新 hook 合成一条 / 老 hook 只记最后一段两种）", async () => {
  const A = { uuid: "r-a", text: "旁白一" }, B = { uuid: "r-b", text: "旁白二" }, C = { uuid: "r-c", text: "最后一段" }
  const A2 = { uuid: "o-a", text: "旁白一" }, B2 = { uuid: "o-b", text: "旁白二" }, C2 = { uuid: "o-c", text: "最后一段" }
  await startHub()
  // 新 hook：一次带齐 ABC
  expect((await post({ chat_id: "conv-new", session_id: "s", rows: [A, B, C], reply_text: "x", turn_uuid: "r-c" })).replied).toBe("ok")
  // 老 hook：只带 reply_text + 最后一段 uuid；之后轮末兜底带 rows 读到同一轮 → dup，同时把推断出来的前段记账
  expect((await post({ chat_id: "conv-old", session_id: "s", reply_text: "旁白一\n\n旁白二\n\n最后一段", turn_uuid: "o-c" })).replied).toBe("ok")
  expect((await post({ chat_id: "conv-old", session_id: "s", rows: [A2, B2, C2] })).replied).toBe("dup")
  expect(replyLog().find((r) => r.mpMsgId === "s_txt_r-c").rowUuids).toEqual(["r-a", "r-b", "r-c"])
  expect(new Set(replyLog().find((r) => r.mpMsgId === "s_txt_o-c").rowUuids)).toEqual(new Set(["o-a", "o-b", "o-c"]))
  await stopHub()

  // hook 那一刻读早了只拿到 A+B，POST 失败落了待投目录，hub 重启后才补投
  const f1 = spoolFile("0001-new.json", { chat_id: "conv-new", session_id: "s", rows: [A, B], reply_text: "旁白一\n\n旁白二", turn_uuid: "r-b" })
  const f2 = spoolFile("0002-old.json", { chat_id: "conv-old", session_id: "s", rows: [A2, B2], reply_text: "旁白一\n\n旁白二", turn_uuid: "o-b" })
  await startHub()
  for (let i = 0; i < 60 && (existsSync(f1) || existsSync(f2)); i++) await new Promise(r => setTimeout(r, 250))
  expect(existsSync(f1)).toBe(false)
  expect(existsSync(f2)).toBe(false)
  const log = replyLog()
  expect(log.filter((r) => r.chat_id === "conv-new").length).toBe(1)
  expect(log.filter((r) => r.chat_id === "conv-old").length).toBe(1)
}, 40_000)
