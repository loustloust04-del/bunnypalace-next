import { test, expect, beforeAll, afterAll } from "bun:test"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

// thinking-hook.py 单测：fake hub（Bun.serve 随机端口）+ python3 子进程喂 stdin
// 验证：channel 定位 / 本轮 thinking 收集 / sidechain 排除 / 无数据不 POST

const HOOK = join(import.meta.dir, "thinking-hook.py")
const HOOK_PORT = 18900 + Math.floor(Math.random() * 1000)
const FIXTURE_DIR = mkdtempSync(join(tmpdir(), "cc-hook-test-"))

let received: any[] = []
/// M4b ⑤：无条件 Stop 端点收到的 body。M5 ⑥：端点改成 loopback 免鉴权，
/// 所以这里连带验「hook 就算手里有 token 也不再往 URL 上挂」。
let lifecycle: Array<{ body: any; token: string | null }> = []
let server: ReturnType<typeof Bun.serve> | undefined

beforeAll(() => {
  server = Bun.serve({
    port: HOOK_PORT,
    hostname: "127.0.0.1",
    async fetch(req) {
      const u = new URL(req.url)
      if (req.method === "POST" && u.pathname === "/thinking") {
        received.push(await req.json())
        return Response.json({ ok: true, thinking_id: "t-test" })
      }
      if (req.method === "POST" && u.pathname === "/la/lifecycle") {
        lifecycle.push({ body: await req.json(), token: u.searchParams.get("token") })
        return Response.json({ ok: true, phase: "done" })
      }
      return new Response("nope", { status: 404 })
    },
  })
})

afterAll(() => { server?.stop(true) })

function line(obj: object): string { return JSON.stringify(obj) }
function userChannel(chatId: string, text = "hi"): string {
  return line({ type: "user", message: { role: "user", content: `<channel source="memorypalace" chat_id="${chatId}" message_id="m1" user="susu" ts="t">${text}</channel>` } })
}
function assistantThinking(thinking: string, extra: object = {}): string {
  return line({ type: "assistant", ...extra, message: { role: "assistant", content: [{ type: "thinking", thinking, signature: "sig" }] } })
}

async function runHook(transcriptLines: string[], name: string): Promise<number> {
  const path = join(FIXTURE_DIR, `${name}.jsonl`)
  writeFileSync(path, transcriptLines.join("\n") + "\n")
  const proc = Bun.spawn(["python3", HOOK], {
    stdin: new TextEncoder().encode(JSON.stringify({ transcript_path: path, session_id: "sess-1" })),
    env: { ...process.env, MP_CC_HOOK_REREAD_TRIES: "2", MP_CC_THINKING_SPOOL: join(FIXTURE_DIR, "spool"), MP_CC_HUB_PORT: String(HOOK_PORT), MP_CC_HUB_TOKEN: "tok-test" },
  })
  return await proc.exited
}

test("hook posts joined thinking of the last turn", async () => {
  received = []
  const code = await runHook([
    userChannel("conv-old"),
    assistantThinking("stale thought from old turn"),
    userChannel("conv-42"),
    assistantThinking("first thought"),
    line({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "正文" }] } }),
    assistantThinking("second thought"),
  ], "happy")
  expect(code).toBe(0)
  expect(received.length).toBe(1)
  expect(received[0].chat_id).toBe("conv-42")
  expect(received[0].thinking).toBe("first thought\n\nsecond thought")
  expect(received[0].session_id).toBe("sess-1")
})

test("hook excludes sidechain thinking", async () => {
  received = []
  const code = await runHook([
    userChannel("conv-43"),
    assistantThinking("subagent noise", { isSidechain: true }),
    assistantThinking("main thought"),
  ], "sidechain")
  expect(code).toBe(0)
  expect(received.length).toBe(1)
  expect(received[0].thinking).toBe("main thought")
})

test("hook does not post when no channel tag in transcript", async () => {
  received = []
  const code = await runHook([
    line({ type: "user", message: { role: "user", content: "plain coding prompt" } }),
    assistantThinking("thought"),
  ], "nochannel")
  expect(code).toBe(0)
  expect(received.length).toBe(0)
})

test("hook does not post when thinking is empty (redacted)", async () => {
  received = []
  const code = await runHook([
    userChannel("conv-44"),
    assistantThinking(""),
  ], "redacted")
  expect(code).toBe(0)
  expect(received.length).toBe(0)
})

test("hook exits 0 on garbage stdin", async () => {
  const proc = Bun.spawn(["python3", HOOK], {
    stdin: new TextEncoder().encode("not json"),
    env: { ...process.env, MP_CC_HOOK_REREAD_TRIES: "2", MP_CC_THINKING_SPOOL: join(FIXTURE_DIR, "spool"), MP_CC_HUB_PORT: String(HOOK_PORT) },
  })
  expect(await proc.exited).toBe(0)
})

// ── M4b ⑤：Stop 端点无条件先发 ──
// 「这轮结束了」跟「有没有 thinking / 锚不锚得上」无关：thinking 那条链的每一个
// return 都会让灵动岛卡在 working。所以 /la/lifecycle 必须在它们之前发。

test("无 thinking 也照发 /la/lifecycle（原 thinking 逻辑仍然不发）", async () => {
  received = []
  lifecycle = []
  const code = await runHook([
    userChannel("conv-45"),
    assistantThinking(""),
  ], "lifecycle-no-thinking")
  expect(code).toBe(0)
  expect(received.length).toBe(0)
  expect(lifecycle.length).toBe(1)
  expect(lifecycle[0]!.body).toEqual({ event: "stop", session_id: "sess-1" })
  // M5 ⑥：hook 跑在 tmux 里拿不到 MP_CC_HUB_TOKEN，带 token 的版本永远 401 —— 现在不带了
  expect(lifecycle[0]!.token).toBeNull()
})

test("连 channel tag 都没有（纯编码轮）也照发 /la/lifecycle", async () => {
  received = []
  lifecycle = []
  const code = await runHook([
    line({ type: "user", message: { role: "user", content: "plain coding prompt" } }),
    assistantThinking("thought"),
  ], "lifecycle-no-channel")
  expect(code).toBe(0)
  expect(received.length).toBe(0)
  expect(lifecycle.length).toBe(1)
})

test("transcript 不存在也照发 /la/lifecycle，且 exit 0", async () => {
  lifecycle = []
  const proc = Bun.spawn(["python3", HOOK], {
    stdin: new TextEncoder().encode(JSON.stringify({ transcript_path: "/nope/missing.jsonl", session_id: "sess-2" })),
    env: { ...process.env, MP_CC_HOOK_REREAD_TRIES: "2", MP_CC_THINKING_SPOOL: join(FIXTURE_DIR, "spool"), MP_CC_HUB_PORT: String(HOOK_PORT), MP_CC_HUB_TOKEN: "tok-test" },
  })
  expect(await proc.exited).toBe(0)
  expect(lifecycle.length).toBe(1)
  expect(lifecycle[0]!.body.session_id).toBe("sess-2")
})

// ---------- REPLY_VIA_TEXT：当轮正文投递（docs/plan-strip-thinking.md 十-10.2）----------
function assistantText(text: string, uuid = "a-1"): string {
  return line({ type: "assistant", uuid, message: { role: "assistant", content: [{ type: "text", text }] } })
}
function assistantReplyTool(): string {
  return line({ type: "assistant", uuid: "a-tool", message: { role: "assistant", content: [{ type: "tool_use", id: "tu1", name: "mcp__cc-bridge__reply", input: { chat_id: "c", content: "x" } }] } })
}
function toolResult(): string {
  return line({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "tu1", content: "ok" }] } })
}

test("text mode: 当轮正文 + message_id + turn_uuid 一起投，tool_result 行不算新一轮", async () => {
  received = []
  const code = await runHook([
    userChannel("conv-t", "在吗"),
    assistantThinking("想一下"),
    line({ type: "assistant", uuid: "a-bash", message: { role: "assistant", content: [{ type: "tool_use", id: "tu1", name: "Bash", input: {} }] } }),
    toolResult(),
    assistantText("在的，怎么了", "a-9"),
  ], "text-mode")
  expect(code).toBe(0)
  expect(received.length).toBe(1)
  expect(received[0].reply_text).toBe("在的，怎么了")
  expect(received[0].message_id).toBe("m1")
  expect(received[0].turn_uuid).toBe("a-9")
  expect(received[0].thinking).toBe("想一下")
})

test("text mode: 本轮用了 reply 工具就不投正文（防双发），thinking 照发", async () => {
  received = []
  const code = await runHook([
    userChannel("conv-t2"),
    assistantThinking("想"),
    assistantReplyTool(),
    toolResult(),
    assistantText("（内心：发完了）"),
  ], "text-mode-reply-used")
  expect(code).toBe(0)
  expect(received.length).toBe(1)
  expect(received[0].reply_text).toBeUndefined()
  expect(received[0].thinking).toBe("想")
})

test("text mode: 最后一条真人输入是保暖 ping，不投正文", async () => {
  received = []
  const code = await runHook([
    userChannel("conv-t3"),
    assistantText("回她的话"),
    line({ type: "user", message: { role: "user", content: `<channel source="cache-keepalive">[缓存保暖 ping] 只回 ok</channel>` } }),
    assistantText("ok"),
  ], "text-mode-keepalive")
  expect(code).toBe(0)
  expect(received.length).toBe(0)
})

test("投递成功后待投文件被删；hub 不通时留在待投目录", async () => {
  const { readdirSync, existsSync } = await import("node:fs")
  const spool = join(FIXTURE_DIR, "spool")
  received = []
  await runHook([userChannel("conv-sp"), assistantText("在的", "a-sp")], "spool-ok")
  expect(received.length).toBe(1)
  expect(existsSync(spool) ? readdirSync(spool).filter((f: string) => f.includes("a-sp")).length : 0).toBe(0)
  // hub 不通：换一个没人监听的端口
  const path = join(FIXTURE_DIR, "spool-dead.jsonl")
  writeFileSync(path, [userChannel("conv-dead"), assistantText("留着", "a-dead")].join("\n") + "\n")
  const proc = Bun.spawn(["python3", HOOK], {
    stdin: new TextEncoder().encode(JSON.stringify({ transcript_path: path, session_id: "sess-1" })),
    env: { ...process.env, MP_CC_HOOK_REREAD_TRIES: "2", MP_CC_THINKING_SPOOL: spool, MP_CC_HUB_PORT: "1" },
  })
  expect(await proc.exited).toBe(0)
  expect(readdirSync(spool).filter((f: string) => f.includes("a-dead")).length).toBe(1)
}, 30_000)

test("正文晚到：hook 先读到空，0.5s 后重读拿到正文再投", async () => {
  received = []
  const { appendFileSync } = await import("node:fs")
  const path = join(FIXTURE_DIR, "late.jsonl")
  writeFileSync(path, userChannel("conv-late") + "\n")
  const proc = Bun.spawn(["python3", HOOK], {
    stdin: new TextEncoder().encode(JSON.stringify({ transcript_path: path, session_id: "sess-1" })),
    env: { ...process.env, MP_CC_HOOK_REREAD_TRIES: "10", MP_CC_THINKING_SPOOL: join(FIXTURE_DIR, "spool"), MP_CC_HUB_PORT: String(HOOK_PORT) },
  })
  setTimeout(() => appendFileSync(path, assistantText("晚到的话", "a-late") + "\n"), 1200)
  expect(await proc.exited).toBe(0)
  expect(received.length).toBe(1)
  expect(received[0].reply_text).toBe("晚到的话")
}, 20_000)

// ---------- 终端轮（docs/plan-cc-terminal-mirror.md）：她在终端里直接打字，正文也进 MP ----------
function userTerminal(text: string, extra: object = {}): string {
  return line({ type: "user", ...extra, message: { role: "user", content: text } })
}

test("终端轮：正文 + thinking 取她那句之后，chat_id 用最后一条 MP channel，带 terminal_input 不带 message_id", async () => {
  received = []
  const code = await runHook([
    userChannel("conv-bound", "MP 里说的"),
    assistantThinking("上一轮的想法"),
    assistantText("上一轮回 MP", "a-prev"),
    userTerminal("我爸比人呢？！"),
    assistantThinking("她在终端找我"),
    assistantText("在这儿呢", "a-term"),
  ], "terminal-turn")
  expect(code).toBe(0)
  expect(received.length).toBe(1)
  expect(received[0].chat_id).toBe("conv-bound")
  expect(received[0].reply_text).toBe("在这儿呢")
  expect(received[0].thinking).toBe("她在终端找我")
  expect(received[0].terminal_input).toBe("我爸比人呢？！")
  expect(received[0].turn_uuid).toBe("a-term")
  expect(received[0].message_id).toBeUndefined()
})

test("终端轮：terminal_input 截 500 字", async () => {
  received = []
  await runHook([userChannel("conv-long"), userTerminal("长".repeat(800)), assistantText("嗯", "a-long")], "terminal-long")
  expect(received.length).toBe(1)
  expect(received[0].terminal_input.length).toBe(500)
})

test("终端轮：转录里没有 MP channel → 不投", async () => {
  received = []
  const code = await runHook([userTerminal("随便聊聊"), assistantText("好", "a-nochat")], "terminal-no-chat")
  expect(code).toBe(0)
  expect(received.length).toBe(0)
})

test("终端轮：斜杠命令 / 系统注入 / 中断 / compact 续写都不算，也不把 thinking 错锚到上一条 MP 回复", async () => {
  const notTerminal: Array<[string, string]> = [
    ["slash", userTerminal("/clear")],
    ["command-name", userTerminal("<command-name>/model</command-name>")],
    ["interrupted", userTerminal("[Request interrupted by user]")],
    ["continued", userTerminal("This session is being continued from a previous conversation...")],
    ["compact-flag", userTerminal("摘要正文", { isCompactSummary: true })],
  ]
  for (const [name, human] of notTerminal) {
    received = []
    const code = await runHook([
      userChannel("conv-nt"),
      assistantText("回 MP", "a-mp"),
      human,
      assistantThinking("这轮的想法"),
      assistantText("这轮的话", `a-${name}`),
    ], `not-terminal-${name}`)
    expect(code).toBe(0)
    expect(received.length).toBe(0)
  }
}, 30_000)

test("保暖轮有 thinking 也不投（以前会错锚到上一条 MP 回复）", async () => {
  received = []
  const code = await runHook([
    userChannel("conv-ka"),
    assistantText("回她的话", "a-ka"),
    line({ type: "user", message: { role: "user", content: `<channel source="cache-keepalive">[缓存保暖 ping] 只回 ok</channel>` } }),
    assistantThinking("保暖轮的想法"),
    assistantText("ok", "a-ka2"),
  ], "keepalive-thinking")
  expect(code).toBe(0)
  expect(received.length).toBe(0)
})

test("终端轮只有 thinking 没正文 → 不投（没有能锚的节点）", async () => {
  received = []
  const code = await runHook([
    userChannel("conv-tt"),
    assistantText("回 MP", "a-tt"),
    userTerminal("想想"),
    assistantThinking("只想不说"),
  ], "terminal-thinking-only")
  expect(code).toBe(0)
  expect(received.length).toBe(0)
})

test("终端轮用了 reply 工具 → 不投正文，也就整条不投", async () => {
  received = []
  const code = await runHook([
    userChannel("conv-tr"),
    userTerminal("去 MP 回我"),
    assistantThinking("想"),
    assistantReplyTool(),
    toolResult(),
    assistantText("发完了", "a-tr"),
  ], "terminal-reply-tool")
  expect(code).toBe(0)
  expect(received.length).toBe(0)
})

test("终端轮正文晚到：重读拿到正文再投", async () => {
  received = []
  const { appendFileSync } = await import("node:fs")
  const path = join(FIXTURE_DIR, "terminal-late.jsonl")
  writeFileSync(path, [userChannel("conv-tl"), userTerminal("在吗"), assistantThinking("先想")].join("\n") + "\n")
  const proc = Bun.spawn(["python3", HOOK], {
    stdin: new TextEncoder().encode(JSON.stringify({ transcript_path: path, session_id: "sess-1" })),
    env: { ...process.env, MP_CC_HOOK_REREAD_TRIES: "10", MP_CC_THINKING_SPOOL: join(FIXTURE_DIR, "spool"), MP_CC_HUB_PORT: String(HOOK_PORT) },
  })
  setTimeout(() => appendFileSync(path, assistantText("在", "a-tl") + "\n"), 1200)
  expect(await proc.exited).toBe(0)
  expect(received.length).toBe(1)
  expect(received[0].reply_text).toBe("在")
  expect(received[0].thinking).toBe("先想")
  expect(received[0].terminal_input).toBe("在吗")
}, 20_000)

// ---------- 10-11 吞：Stop hook 比 CC 写最后一段早，只读到中间旁白就投了 ----------
function spawnHook(path: string, stdinExtra: object, tries: string) {
  return Bun.spawn(["python3", HOOK], {
    stdin: new TextEncoder().encode(JSON.stringify({ transcript_path: path, session_id: "sess-1", ...stdinExtra })),
    env: { ...process.env, MP_CC_HOOK_REREAD_TRIES: tries, MP_CC_THINKING_SPOOL: join(FIXTURE_DIR, "spool"), MP_CC_HUB_PORT: String(HOOK_PORT) },
  })
}
function assistantRow(content: object[], uuid: string, stop_reason: string): string {
  return line({ type: "assistant", uuid, message: { role: "assistant", stop_reason, content } })
}

test("转录最后一行还停在工具调用：等最后一段落盘再投，rows 带每段 uuid", async () => {
  received = []
  const { appendFileSync } = await import("node:fs")
  const path = join(FIXTURE_DIR, "swallow.jsonl")
  writeFileSync(path, [
    userChannel("conv-sw"),
    assistantRow([{ type: "text", text: "正在逐块放大读那三张图" }], "sw-1", "tool_use"),
    assistantRow([{ type: "tool_use", id: "tu1", name: "Read", input: {} }], "sw-2", "tool_use"),
    toolResult(),
    assistantRow([{ type: "text", text: "Files are in place." }], "sw-3", "tool_use"),
    assistantRow([{ type: "tool_use", id: "tu2", name: "Bash", input: {} }], "sw-4", "tool_use"),
    toolResult(),
  ].join("\n") + "\n")
  const proc = spawnHook(path, {}, "10")
  setTimeout(() => appendFileSync(path, assistantRow([{ type: "text", text: "图存好了" }], "sw-5", "end_turn") + "\n"), 1200)
  expect(await proc.exited).toBe(0)
  expect(received.length).toBe(1)
  expect(received[0].reply_text).toBe("正在逐块放大读那三张图\n\nFiles are in place.\n\n图存好了")
  expect(received[0].turn_uuid).toBe("sw-5")
  expect(received[0].rows).toEqual([
    { uuid: "sw-1", text: "正在逐块放大读那三张图" }, { uuid: "sw-3", text: "Files are in place." }, { uuid: "sw-5", text: "图存好了" },
  ])
}, 20_000)

test("CC 给了 last_assistant_message：转录正文没以它结尾就接着等", async () => {
  received = []
  const { appendFileSync } = await import("node:fs")
  const path = join(FIXTURE_DIR, "lam.jsonl")
  writeFileSync(path, [userChannel("conv-lam"), assistantText("旁白", "lam-1")].join("\n") + "\n")
  const proc = spawnHook(path, { last_assistant_message: "最后 的话" }, "10")
  setTimeout(() => appendFileSync(path, assistantText("最后的话", "lam-2") + "\n"), 1200)
  expect(await proc.exited).toBe(0)
  expect(received.length).toBe(1)
  expect(received[0].reply_text).toBe("旁白\n\n最后的话")
  expect(received[0].rows.map((r: any) => r.uuid)).toEqual(["lam-1", "lam-2"])
}, 20_000)

test("只有 thinking 还没正文：等正文（以前先投 thinking，错锚到上一条回复）", async () => {
  received = []
  const { appendFileSync } = await import("node:fs")
  const path = join(FIXTURE_DIR, "think-first.jsonl")
  writeFileSync(path, [userChannel("conv-tf"), assistantRow([{ type: "thinking", thinking: "想", signature: "s" }], "tf-1", "end_turn")].join("\n") + "\n")
  const proc = spawnHook(path, {}, "10")
  setTimeout(() => appendFileSync(path, assistantRow([{ type: "text", text: "说" }], "tf-2", "end_turn") + "\n"), 1200)
  expect(await proc.exited).toBe(0)
  expect(received.length).toBe(1)
  expect(received[0].reply_text).toBe("说")
  expect(received[0].thinking).toBe("想")
}, 20_000)

test("等到超时还没齐：照投已有的（rows 带着，hub 轮末兜底只补缺的段）", async () => {
  received = []
  const code = await runHook([
    userChannel("conv-to"),
    assistantRow([{ type: "text", text: "旁白" }], "to-1", "tool_use"),
    assistantRow([{ type: "tool_use", id: "tu1", name: "Bash", input: {} }], "to-2", "tool_use"),
    toolResult(),
  ], "timeout-partial")
  expect(code).toBe(0)
  expect(received.length).toBe(1)
  expect(received[0].reply_text).toBe("旁白")
  expect(received[0].rows).toEqual([{ uuid: "to-1", text: "旁白" }])
}, 20_000)

test("rows 超 20000 字：只带完整放得下的段（截过的段 hub 会当投过），第一段自己超限才截断照带", async () => {
  received = []
  await runHook([userChannel("conv-big"), assistantText("甲".repeat(15_000), "big-1"), assistantText("乙".repeat(15_000), "big-2")], "rows-budget")
  expect(received.length).toBe(1)
  expect(received[0].rows.map((r: any) => [r.uuid, r.text.length])).toEqual([["big-1", 15_000]])
  received = []
  await runHook([userChannel("conv-huge"), assistantText("丙".repeat(25_000), "huge-1"), assistantText("丁", "huge-2")], "rows-huge")
  expect(received[0].rows.map((r: any) => [r.uuid, r.text.length])).toEqual([["huge-1", 20_000]])
})
