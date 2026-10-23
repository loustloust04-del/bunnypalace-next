import { test, expect } from "bun:test"
import { Database } from "bun:sqlite"
import { mkdtempSync, writeFileSync, appendFileSync, mkdirSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  newAcc, parseCCLine, parseCodexLine, scanFileIncremental,
  matchLiveProcesses, WarroomIndexer, BIG_LINE_BYTES, openIndexerWithRetry,
  type PaneInfo, type ProcInfo,
} from "./warroom-indexer.ts"

// ── parseCCLine ──

test("CC: cwd/sessionId/version 从 record 提取（中文路径无损）", () => {
  const acc = newAcc("claude")
  parseCCLine(JSON.stringify({ type: "attachment", sessionId: "s1", cwd: "/Users/susu/Desktop/记忆宫殿/MemoryPalace", gitBranch: "master", version: "2.1.167", timestamp: "2026-07-01T00:00:00Z" }), acc)
  expect(acc.sessionId).toBe("s1")
  expect(acc.cwd).toBe("/Users/susu/Desktop/记忆宫殿/MemoryPalace")
  expect(acc.gitBranch).toBe("master")
  expect(acc.startedAt).toBe("2026-07-01T00:00:00Z")
})

test("CC: 首条真实 user 消息（跳过 meta/compact/tool_result）", () => {
  const acc = newAcc("claude")
  parseCCLine(JSON.stringify({ type: "user", isCompactSummary: true, message: { content: "compact 摘要" } }), acc)
  parseCCLine(JSON.stringify({ type: "user", isMeta: true, message: { content: "meta" } }), acc)
  parseCCLine(JSON.stringify({ type: "user", message: { content: [{ type: "tool_result", content: "x" }] } }), acc)
  parseCCLine(JSON.stringify({ type: "user", message: { content: "修一下登录 bug" } }), acc)
  parseCCLine(JSON.stringify({ type: "user", message: { content: "第二句" } }), acc)
  expect(acc.firstUserMsg).toBe("修一下登录 bug")
  expect(acc.turns).toBe(2)
})

test("CC: usage 按 requestId 去重累计；tool_use 提取文件和命令", () => {
  const acc = newAcc("claude")
  const mk = (rid: string, blocks: unknown[]) => JSON.stringify({
    type: "assistant", requestId: rid,
    message: { usage: { output_tokens: 10, cache_read_input_tokens: 100, cache_creation_input_tokens: 5 }, content: blocks },
  })
  parseCCLine(mk("r1", [{ type: "tool_use", name: "Edit", input: { file_path: "/a/b.ts" } }]), acc)
  parseCCLine(mk("r1", [{ type: "tool_use", name: "Write", input: { file_path: "/a/c.ts" } }]), acc)  // 同 rid：usage 不重复计
  parseCCLine(mk("r2", [{ type: "tool_use", name: "Bash", input: { command: "bun test x".repeat(50) } }]), acc)
  expect(acc.tokensOut).toBe(20)
  expect(acc.cacheRead).toBe(200)
  expect(acc.filesTouched.has("/a/b.ts")).toBe(true)
  expect(acc.filesTouched.has("/a/c.ts")).toBe(true)
  expect(acc.cmdsRun.length).toBe(1)
  expect(acc.cmdsRun[0].length).toBeLessThanOrEqual(200)
})

test("CC: 大行跳过、坏行返回 false", () => {
  const acc = newAcc("claude")
  expect(parseCCLine("x".repeat(BIG_LINE_BYTES + 1), acc)).toBe(true)   // 大行=已消费
  expect(parseCCLine('{"type":"user","mess', acc)).toBe(false)          // 半行=停
})

// ── parseCodexLine ──

test("Codex: session_meta 一行拿全 + function_call 提取", () => {
  const acc = newAcc("codex")
  parseCodexLine(JSON.stringify({ timestamp: "2026-06-22T14:24:19Z", type: "session_meta", payload: { id: "c1", cwd: "/x/记忆宫殿", originator: "Claude Code", cli_version: "0.137.0" } }), acc)
  parseCodexLine(JSON.stringify({ timestamp: "2026-06-22T14:25:00Z", type: "response_item", payload: { type: "message", role: "user", content: [{ type: "text", text: "改一下 hub.ts 的端口" }] } }), acc)
  parseCodexLine(JSON.stringify({ timestamp: "2026-06-22T14:26:00Z", type: "response_item", payload: { type: "function_call", name: "shell", arguments: '{"command":["bash","-c","vim hub.ts"]}' } }), acc)
  expect(acc.sessionId).toBe("c1")
  expect(acc.cwd).toBe("/x/记忆宫殿")
  expect(acc.originator).toBe("Claude Code")
  expect(acc.firstUserMsg).toBe("改一下 hub.ts 的端口")
  expect(acc.lastActiveAt).toBe("2026-06-22T14:26:00Z")
  expect(acc.cmdsRun[0].startsWith("shell:")).toBe(true)
  expect([...acc.filesTouched].some(f => f.includes("hub.ts"))).toBe(true)
})

// ── scanFileIncremental ──

test("增量：第二扫只处理新增行；半行不消费", () => {
  const dir = mkdtempSync(join(tmpdir(), "warroom-"))
  const f = join(dir, "s.jsonl")
  writeFileSync(f, JSON.stringify({ type: "user", sessionId: "s9", message: { content: "第一句" } }) + "\n")
  const acc = newAcc("claude")
  const s1 = scanFileIncremental(f, null, acc, parseCCLine)
  expect(acc.turns).toBe(1)
  // 追加一整行 + 一个半行
  appendFileSync(f, JSON.stringify({ type: "user", sessionId: "s9", message: { content: "第二句" } }) + "\n" + '{"type":"user","messa')
  const s2 = scanFileIncremental(f, s1, acc, parseCCLine)
  expect(acc.turns).toBe(2)                       // 只多了一轮
  expect(s2.offset).toBeLessThan(s2.size)          // 半行没消费
  // 补全半行
  appendFileSync(f, 'ge":{"content":"第三句"}}\n')
  const s3 = scanFileIncremental(f, s2, acc, parseCCLine)
  expect(acc.turns).toBe(3)
  expect(s3.offset).toBe(s3.size)
})

test("增量：中间的坏完整行跳过继续；尾巴半行仍不消费", () => {
  const dir = mkdtempSync(join(tmpdir(), "warroom-"))
  const f = join(dir, "s.jsonl")
  const good = (n: number) => JSON.stringify({ type: "user", sessionId: "s9", message: { content: `第${n}句` } })
  const tail = '{"type":"user","messa'
  // 第 2 行是半截 JSON（offset 曾落在行中间的现场），后面还有两行好的
  writeFileSync(f, [good(1), '"ephemeral_5m_input_tokens":0},"type":"message"}', good(2), good(3)].join("\n") + "\n" + tail)
  const acc = newAcc("claude")
  const s1 = scanFileIncremental(f, null, acc, parseCCLine)
  expect(acc.turns).toBe(3)
  expect(s1.offset).toBe(s1.size - Buffer.byteLength(tail))
})

test("增量：prev.offset 落在行中间也能重新对齐", () => {
  const dir = mkdtempSync(join(tmpdir(), "warroom-"))
  const f = join(dir, "s.jsonl")
  const l1 = JSON.stringify({ type: "user", sessionId: "s9", message: { content: "第一句" } })
  const l2 = JSON.stringify({ type: "user", sessionId: "s9", message: { content: "第二句" } })
  writeFileSync(f, l1 + "\n" + l2 + "\n")
  const acc = newAcc("claude")
  const mid = 10   // 指到 l1 中间
  const s = scanFileIncremental(f, { size: 1, mtimeMs: 0, offset: mid }, acc, parseCCLine)
  expect(acc.turns).toBe(1)          // l1 剩下的半截被跳过，只算 l2
  expect(s.offset).toBe(s.size)
})

test("增量：单行长过一片 → 跳到下一个换行，不永远卡住", () => {
  const dir = mkdtempSync(join(tmpdir(), "warroom-"))
  const f = join(dir, "s.jsonl")
  const huge = "x".repeat(300)
  const good = JSON.stringify({ type: "user", sessionId: "s9", message: { content: "好行" } })
  writeFileSync(f, huge + "\n" + good + "\n")
  const acc = newAcc("claude")
  let st: ReturnType<typeof scanFileIncremental> | null = null
  for (let i = 0; i < 5 && (!st || st.offset < st.size); i++) st = scanFileIncremental(f, st, acc, parseCCLine, 64)
  expect(st!.offset).toBe(st!.size)
  expect(acc.turns).toBe(1)
})

test("Indexer: offset 不前进的文件一轮后剔除，不重扫 200 轮", () => {
  const root = mkdtempSync(join(tmpdir(), "warroom-stuck-"))
  const ccRoot = join(root, "projects"); const cxRoot = join(root, "codex")
  mkdirSync(join(ccRoot, "-p"), { recursive: true })
  // 一行好的 + 2KB 没写完的尾巴（流式 assistant 行正在写）
  writeFileSync(join(ccRoot, "-p/a.jsonl"),
    JSON.stringify({ type: "user", sessionId: "cc-a", cwd: "/x", message: { content: "任务" } }) + "\n" + '{"type":"assistant","message":"' + "y".repeat(2048))
  const idx = new WarroomIndexer({ dbPath: join(root, "w.db"), ccProjectsRoot: ccRoot, codexSessionsRoot: cxRoot })
  let calls = 0
  const orig = idx.scanOne.bind(idx)
  idx.scanOne = (p, e) => { calls++; return orig(p, e) }
  idx.scanAll()
  expect(calls).toBeLessThanOrEqual(2)   // 第 1 轮消费好行，第 2 轮没进展 → 剔除
  expect((idx.querySessions({}) as any[]).length).toBe(1)
  idx.close()
})

test("listTargetsAsync 与同步版列出同一批文件（cc 项目 + codex 多层目录）", async () => {
  const root = mkdtempSync(join(tmpdir(), "warroom-list-"))
  const ccRoot = join(root, "projects"); const cxRoot = join(root, "codex")
  mkdirSync(join(ccRoot, "-a"), { recursive: true }); mkdirSync(join(ccRoot, "-b"), { recursive: true })
  mkdirSync(join(cxRoot, "2026/10/10"), { recursive: true })
  for (const p of ["-a/1.jsonl", "-a/x.txt", "-b/2.jsonl"]) writeFileSync(join(ccRoot, p), "")
  for (const p of ["2026/10/10/r.jsonl", "top.jsonl"]) writeFileSync(join(cxRoot, p), "")
  const idx = new WarroomIndexer({ dbPath: join(root, "w.db"), ccProjectsRoot: ccRoot, codexSessionsRoot: cxRoot })
  let yields = 0
  const got = await idx.listTargetsAsync(async () => { yields++ })
  const key = (t: { path: string; engine: string }) => `${t.engine}:${t.path}`
  expect(got.map(key).sort()).toEqual(idx.listTargets().map(key).sort())
  expect(got.length).toBe(4)
  expect(yields).toBeGreaterThanOrEqual(2)
  idx.close()
})

test("增量：文件没变直接跳过（返回同 state）", () => {
  const dir = mkdtempSync(join(tmpdir(), "warroom-"))
  const f = join(dir, "s.jsonl")
  writeFileSync(f, JSON.stringify({ type: "user", sessionId: "sx", message: { content: "hi" } }) + "\n")
  const acc = newAcc("claude")
  const s1 = scanFileIncremental(f, null, acc, parseCCLine)
  const s2 = scanFileIncremental(f, s1, acc, parseCCLine)
  expect(s2).toBe(s1)
  expect(acc.turns).toBe(1)
})

// ── matchLiveProcesses ──

const panes: PaneInfo[] = [
  { tmuxSession: "mp-cc-6", panePid: 100, cwd: "/Users/susu/Desktop/cc-rp" },
]

test("匹配：--resume argv → exact + tmux 关联（ppid 链）", () => {
  const procs: ProcInfo[] = [
    { pid: 101, ppid: 100, command: "claude --model x --resume 7e2173d0-c8e7-43fc-bd83-3c621a91ab3d" },
  ]
  const m = matchLiveProcesses(panes, procs)
  expect(m.length).toBe(1)
  expect(m[0].sessionId).toBe("7e2173d0-c8e7-43fc-bd83-3c621a91ab3d")
  expect(m[0].confidence).toBe("exact")
  expect(m[0].tmuxSession).toBe("mp-cc-6")
})

test("匹配：--continue 无 id → fuzzy + pane cwd；孤儿进程无 tmux", () => {
  const procs: ProcInfo[] = [
    { pid: 102, ppid: 100, command: "claude --continue" },
    { pid: 200, ppid: 1, command: "claude --resume 4be07e97-ddeb-4d14-bf20-5157f31a8456" },  // 僵尸：无 pane
    { pid: 300, ppid: 1, command: "grep claude" },   // 非 CLI，忽略
  ]
  const m = matchLiveProcesses(panes, procs)
  expect(m.length).toBe(2)
  const fuzzy = m.find(x => x.pid === 102)!
  expect(fuzzy.confidence).toBe("fuzzy")
  expect(fuzzy.cwd).toBe("/Users/susu/Desktop/cc-rp")
  const zombie = m.find(x => x.pid === 200)!
  expect(zombie.tmuxSession).toBe(null)
  expect(zombie.confidence).toBe("exact")
})

test("匹配：codex resume <uuid> 也认", () => {
  const procs: ProcInfo[] = [
    { pid: 103, ppid: 100, command: "codex resume 019f7f74-0000-7000-8000-52d0dbaaecac" },
  ]
  const m = matchLiveProcesses(panes, procs)
  expect(m[0].engine).toBe("codex")
  expect(m[0].sessionId).toBe("019f7f74-0000-7000-8000-52d0dbaaecac")
})

// ── WarroomIndexer 端到端（tmp 目录迷你项目树）──

test("Indexer: 两轮扫描 + 查询 + 僵尸过滤", () => {
  const root = mkdtempSync(join(tmpdir(), "warroom-e2e-"))
  const ccRoot = join(root, "projects"); const cxRoot = join(root, "codex")
  mkdirSync(join(ccRoot, "-Users-x-proj"), { recursive: true })
  mkdirSync(join(cxRoot, "2026/07/26"), { recursive: true })
  writeFileSync(join(ccRoot, "-Users-x-proj/aaa.jsonl"),
    JSON.stringify({ type: "user", sessionId: "cc-aaa", cwd: "/Users/x/真实路径", timestamp: "2026-07-26T01:00:00Z", message: { content: "任务A" } }) + "\n")
  writeFileSync(join(cxRoot, "2026/07/26/rollout-x.jsonl"),
    JSON.stringify({ timestamp: "2026-07-26T02:00:00Z", type: "session_meta", payload: { id: "cx-bbb", cwd: "/Users/x/proj2", originator: "Claude Code" } }) + "\n")

  const idx = new WarroomIndexer({ dbPath: join(root, "w.db"), ccProjectsRoot: ccRoot, codexSessionsRoot: cxRoot })
  // 注入假活进程：cc-aaa 活着但无 tmux（僵尸形态）
  const r1 = idx.scanAll()
  expect(r1.changed).toBe(2)
  idx.refreshLiveness([{ pid: 999, engine: "claude", sessionId: "cc-aaa", confidence: "exact", tmuxSession: null, cwd: null }])

  const all = idx.querySessions({}) as any[]
  expect(all.length).toBe(2)
  const cc = all.find(s => s.session_id === "cc-aaa")!
  expect(cc.cwd).toBe("/Users/x/真实路径")
  expect(cc.first_user_msg).toBe("任务A")
  expect(cc.alive).toBe(1)

  const zombies = idx.querySessions({ zombies: true }) as any[]
  expect(zombies.length).toBe(1)
  expect(zombies[0].session_id).toBe("cc-aaa")

  const codexOnly = idx.querySessions({ engine: "codex" }) as any[]
  expect(codexOnly.length).toBe(1)
  expect(codexOnly[0].originator).toBe("Claude Code")

  // 第二轮：没变化
  const r2 = idx.scanAll()
  expect(r2.changed).toBe(0)
  idx.close()
})

test("K2 审查 R1-5：旧 DELETE 库被别的连接拿着读事务 → 切 WAL 失败、新连接关掉、异步退避重开成功", async () => {
  const root = mkdtempSync(join(tmpdir(), "warroom-wal-"))
  const opts = { dbPath: join(root, "w.db"), ccProjectsRoot: join(root, "p"), codexSessionsRoot: join(root, "c") }
  const old = new Database(opts.dbPath)          // 旧 hub / sqlite3 CLI：DELETE 模式 + 活动读事务
  old.exec("CREATE TABLE IF NOT EXISTS junk (x)")
  old.exec("BEGIN")
  old.query("SELECT COUNT(*) FROM junk").get()

  const t0 = performance.now()
  expect(() => new WarroomIndexer(opts)).toThrow(/locked|busy|WAL/i)
  expect(performance.now() - t0).toBeLessThan(500)          // 原来 busy_timeout=5000：同步卡 5s

  const logs: string[] = []
  const opened = new Promise<WarroomIndexer>((resolve) => openIndexerWithRetry(opts, resolve, { delaysMs: [30, 30, 30], log: (l) => logs.push(l) }))
  setTimeout(() => old.exec("COMMIT"), 50)
  const idx = await opened
  expect(logs.length).toBeGreaterThanOrEqual(1)
  expect(logs[0]).toMatch(/开库失败（第 1 次）/)
  expect((idx.db.query("PRAGMA journal_mode").get() as { journal_mode: string }).journal_mode).toBe("wal")
  idx.close()

  // 已是 WAL：不再切模式，别的连接拿着读事务也照开
  old.exec("BEGIN")
  old.query("SELECT COUNT(*) FROM junk").get()
  const again = new WarroomIndexer(opts)
  expect((again.querySessions({}) as unknown[]).length).toBe(0)
  old.exec("COMMIT")
  again.close(); old.close()
})
