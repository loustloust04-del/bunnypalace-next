import { afterAll, expect, test } from "bun:test"
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { buildSessionModelFrame, carryContextSuffix, CodexRolloutIndex, FactsParser, modelFromDisplay, parseSetModelOutput, lastClaudeReplyModel, lastCodexTurnModel, LOCATE_CAP_BYTES, MAX_TRACKED_SESSIONS, nativeOneM, PENDING_TTL_MS, TRACKED_SESSION_TTL_MS, sameModelLoose, parseClaudeModel, resolveSessionModel, SessionModelTracker, shortModelName, TranscriptScan } from "./session-model"
import { contextWindowFor } from "./terminal-usage"

test("短名映射：全名 / [1m] / 带日期 / 别名；认不出的原样", () => {
  const table: Array<[string, string]> = [
    ["claude-opus-5-5", "opus-5.5"],
    ["claude-opus-5", "opus-5"],
    ["claude-opus-4-6[1m]", "opus-4.6-1m"],
    ["claude-opus-4-6", "opus-4.6"],
    ["claude-sonnet-4-6[1m]", "sonnet-4.6-1m"],
    ["claude-sonnet-4-5-20250929", "sonnet-4.5"],
    ["claude-opus-4-20250514", "opus-4"],
    ["claude-haiku-4-5", "haiku-4.5"],
    ["claude-fable-5-1", "fable-5.1"],
    ["claude-fable-5[1m]", "fable-5-1m"],
    ["opus", "opus"],
    ["opus[1m]", "opus-1m"],
    ["Claude-Opus-4-7", "opus-4.7"],
    ["best", "best"],
    ["default", "default"],
    ["opusplan", "opusplan"],
    ["claude-opus", "claude-opus"],
    ["claude-3-5-sonnet-20241022", "claude-3-5-sonnet-20241022"],
    ["us.anthropic.claude-opus-4-6-v1:0", "us.anthropic.claude-opus-4-6-v1:0"],
    ["gpt-5.2-codex", "gpt-5.2-codex"],
  ]
  for (const [id, short] of table) expect([id, shortModelName(id)]).toEqual([id, short])
})

test("天生 1M：Opus 4.7+ / Sonnet 5+ / Haiku 5.5 / Fable 全系；4.6 和 Haiku 4.5 不是", () => {
  const yes = ["claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-sonnet-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5", "claude-fable-5-1", "fable"]
  const no = ["claude-opus-4-6", "claude-sonnet-4-6", "claude-sonnet-4-5-20250929", "claude-haiku-4-5", "claude-opus-4-20250514", "opus", "sonnet"]
  for (const m of yes) expect([m, nativeOneM(parseClaudeModel(m)!)]).toEqual([m, true])
  for (const m of no) expect([m, nativeOneM(parseClaudeModel(m)!)]).toEqual([m, false])
})

test("contextWindowFor：[1m] 后缀 / 天生 1M → 1M；其余和认不出的 200K", () => {
  expect(contextWindowFor("claude-opus-4-6[1m]")).toBe(1_000_000)
  expect(contextWindowFor("opus[1m]")).toBe(1_000_000)
  expect(contextWindowFor("claude-opus-5-5")).toBe(1_000_000)
  expect(contextWindowFor("claude-opus-4-7")).toBe(1_000_000)
  expect(contextWindowFor("claude-sonnet-5")).toBe(1_000_000)
  expect(contextWindowFor("claude-fable-5-1")).toBe(1_000_000)
  expect(contextWindowFor("claude-opus-4-6")).toBe(200_000)
  expect(contextWindowFor("claude-haiku-4-5")).toBe(200_000)
  expect(contextWindowFor("gpt-5.2-codex")).toBe(200_000)
})

test("回复里的 model 接上选择的 [1m]：同一个模型才接；同族别名也算", () => {
  expect(carryContextSuffix("claude-opus-4-6", "claude-opus-4-6[1m]")).toBe("claude-opus-4-6[1m]")
  expect(carryContextSuffix("claude-opus-4-6", "opus[1m]")).toBe("claude-opus-4-6[1m]")
  expect(carryContextSuffix("claude-opus-5-5", "claude-opus-4-6[1m]")).toBe("claude-opus-5-5")
  expect(carryContextSuffix("claude-sonnet-4-6", "opus[1m]")).toBe("claude-sonnet-4-6")
  expect(carryContextSuffix("claude-opus-4-6", "claude-opus-4-6")).toBe("claude-opus-4-6")
  expect(carryContextSuffix("claude-opus-4-6", undefined)).toBe("claude-opus-4-6")
  expect(carryContextSuffix("gpt-5.2-codex", "claude-opus-4-6[1m]")).toBe("gpt-5.2-codex")
})

const reply = (model: string, ts: string, extra: Record<string, unknown> = {}) => JSON.stringify({ type: "assistant", timestamp: ts, message: { model }, ...extra })

test("claude 转录：取最后一条主线回复的 model，跳过子 agent、<synthetic>、坏行", () => {
  const lines = [
    reply("claude-opus-4-6", "2026-10-11T01:00:00.000Z"),
    reply("claude-sonnet-5", "2026-10-11T02:00:00.000Z"),
    reply("claude-haiku-4-5", "2026-10-11T03:00:00.000Z", { isSidechain: true }),
    reply("<synthetic>", "2026-10-11T04:00:00.000Z"),
    JSON.stringify({ type: "user", timestamp: "2026-10-11T05:00:00.000Z", message: { content: "hi" } }),
    "{半行",
  ]
  expect(lastClaudeReplyModel(lines)).toEqual({ model: "claude-sonnet-5", atMs: Date.parse("2026-10-11T02:00:00.000Z") })
  expect(lastClaudeReplyModel([])).toBeNull()
})

test("codex rollout：取最后一条 turn_context 的 payload.model", () => {
  const lines = [
    JSON.stringify({ timestamp: "2026-08-02T09:15:00.000Z", type: "session_meta", payload: { id: "x" } }),
    JSON.stringify({ timestamp: "2026-08-02T09:15:01.000Z", type: "turn_context", payload: { cwd: "/w", model: "gpt-5.2-codex" } }),
    JSON.stringify({ timestamp: "2026-08-02T09:20:01.000Z", type: "turn_context", payload: { cwd: "/w", model: "gpt-5.3-codex" } }),
    JSON.stringify({ timestamp: "2026-08-02T09:20:02.000Z", type: "response_item", payload: { type: "message", role: "assistant" } }),
  ]
  expect(lastCodexTurnModel(lines)?.model).toBe("gpt-5.3-codex")
  expect(lastCodexTurnModel(lines.slice(0, 1))).toBeNull()
})

test("新旧：转录比选择新用转录（接 [1m]）；选择更新（刚 /model、刚拉起）用选择；都没有用打底", () => {
  const t = (iso: string) => Date.parse(iso)
  const seen = { model: "claude-opus-4-6", atMs: t("2026-10-11T02:00:00Z") }
  expect(resolveSessionModel(seen, { model: "claude-opus-4-6[1m]", atMs: t("2026-10-11T01:00:00Z") })).toBe("claude-opus-4-6[1m]")
  expect(resolveSessionModel(seen, { model: "sonnet", atMs: t("2026-10-11T03:00:00Z") })).toBe("sonnet")
  expect(resolveSessionModel(seen, undefined, "claude-opus-4-6[1m]")).toBe("claude-opus-4-6[1m]")
  expect(resolveSessionModel({ model: "claude-opus-5-5", atMs: 0 }, undefined, "claude-opus-4-6[1m]")).toBe("claude-opus-5-5")
  expect(resolveSessionModel(null, undefined, "claude-opus-4-6[1m]")).toBe("claude-opus-4-6[1m]")
  expect(resolveSessionModel(null, undefined, undefined)).toBeUndefined()
})

test("session_model 帧", () => {
  expect(JSON.parse(buildSessionModelFrame("mp-cc-1", "claude-opus-4-6[1m]"))).toEqual({
    type: "session_model", session_name: "mp-cc-1", model: "opus-4.6-1m", model_id: "claude-opus-4-6[1m]",
  })
})

// ── 审查 R1-5：转录增量扫描 ──
const tmp = mkdtempSync(join(tmpdir(), "session-model-test-"))
afterAll(() => rmSync(tmp, { recursive: true, force: true }))
let fileSeq = 0
const newFile = (lines: string[]) => { const p = join(tmp, `t${++fileSeq}.jsonl`); writeFileSync(p, lines.map((l) => l + "\n").join("")); return p }
const turnCtx = (model: string, ts: string) => JSON.stringify({ timestamp: ts, type: "turn_context", payload: { cwd: "/w", model } })
/// codex 一轮里的长输出：n 行、每行约 kb KB，不含 turn_context
const bigOutput = (n: number, kb = 64) => Array.from({ length: n }, (_, i) => JSON.stringify({ timestamp: "2026-10-11T01:00:00Z", type: "response_item", payload: { type: "function_call_output", output: `${i}:` + "x".repeat(kb * 1024) } }))

test("R1-5：codex 轮首的 turn_context 被 2MB 输出挤出 512KB 尾部，第一次定位分块往回找得到", async () => {
  const p = newFile([turnCtx("gpt-5.2-codex", "2026-10-11T01:00:00Z"), ...bigOutput(32)])
  const scan = new TranscriptScan(p, "codex")
  const read = await scan.update()
  expect(scan.facts.reply?.model).toBe("gpt-5.2-codex")
  expect(read).toBeGreaterThan(512 * 1024)
})

test("R1-5：变长了只读新增的部分；轮首换了模型、后面又是长输出，也认得出（不是「尾部没找到 = 没变」）", async () => {
  const p = newFile([turnCtx("gpt-5.2-codex", "2026-10-11T01:00:00Z"), ...bigOutput(4)])
  const scan = new TranscriptScan(p, "codex")
  await scan.update()
  const before = Bun.file(p).size
  appendFileSync(p, [turnCtx("gpt-5.3-codex", "2026-10-11T02:00:00Z"), ...bigOutput(32)].map((l) => l + "\n").join(""))
  const read = await scan.update()
  expect(read).toBe(Bun.file(p).size - before)
  expect(scan.facts.reply?.model).toBe("gpt-5.3-codex")
  expect(await scan.update()).toBe(0)   // size + mtime 没变：不读
})

test("R1-5：写到一半的行不吃，等写完整了再认", async () => {
  const p = newFile([reply("claude-opus-4-6", "2026-10-11T01:00:00Z")])
  const scan = new TranscriptScan(p, "claude")
  await scan.update()
  const line = reply("claude-sonnet-5", "2026-10-11T02:00:00Z")
  appendFileSync(p, line.slice(0, 20))
  await scan.update()
  expect(scan.facts.reply?.model).toBe("claude-opus-4-6")
  appendFileSync(p, line.slice(20) + "\n")
  await scan.update()
  expect(scan.facts.reply?.model).toBe("claude-sonnet-5")
})

test("R1-5：文件被截短 / 换掉 → 重新定位；往回找有上限", async () => {
  const p = newFile([reply("claude-opus-4-6", "2026-10-11T01:00:00Z"), reply("claude-sonnet-5", "2026-10-11T02:00:00Z")])
  const scan = new TranscriptScan(p, "claude")
  await scan.update()
  writeFileSync(p, reply("claude-haiku-4-5", "2026-10-11T03:00:00Z") + "\n")
  await scan.update()
  expect(scan.facts.reply?.model).toBe("claude-haiku-4-5")
  const far = newFile([turnCtx("gpt-5.2-codex", "2026-10-11T01:00:00Z"), ...bigOutput(LOCATE_CAP_BYTES / (64 * 1024) + 8)])
  const capped = new TranscriptScan(far, "codex")
  expect(await capped.update()).toBeLessThanOrEqual(LOCATE_CAP_BYTES)
  expect(capped.facts.reply).toBeUndefined()
})

test("在途合并：同一会话并发重算只跑一份、算完补一遍；结果不乱", async () => {
  const p = newFile([reply("claude-opus-4-6", "2026-10-11T01:00:00Z")])
  let opens = 0
  const published: Array<string | undefined> = []
  const tracker = new SessionModelTracker({
    binding: () => ({ id: "x", kind: "claude" }),
    transcriptPath: async () => { opens++; await Bun.sleep(5); return p },
    fallback: () => undefined,
    publish: (_n, m) => published.push(m),
    now: Date.now,
  })
  await Promise.all([tracker.refresh("s"), tracker.refresh("s"), tracker.refresh("s")])
  expect(opens).toBe(2)
  expect(published).toEqual(["claude-opus-4-6"])
})

// ── 审查 R1-8：codex 历史目录走一遍建索引；预热有读盘上限 ──
test("R1-8：几十个 uuid 只走一遍目录；过期才重建；找不到的不触发重扫", async () => {
  const root = join(tmp, "codex-sessions")
  const ids = Array.from({ length: 30 }, (_, i) => `${String(i).padStart(8, "0")}-aaaa-bbbb-cccc-000000000000`)
  ids.forEach((id, i) => {
    const dir = join(root, "2026", "09", String(1 + (i % 28)).padStart(2, "0"))
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, `rollout-2026-09-01T00-00-00-${id}.jsonl`), turnCtx("gpt-5.2-codex", "2026-09-01T00:00:00Z") + "\n")
  })
  let now = 0
  const index = new CodexRolloutIndex(() => root, 60_000, () => now)
  for (const id of ids) expect(await index.lookup(id)).toContain(id)
  expect(await index.lookup("ffffffff-aaaa-bbbb-cccc-000000000000")).toBeUndefined()
  expect(index.builds).toBe(1)
  now = 61_000
  await Promise.all([index.lookup(ids[0]), index.lookup(ids[1])])
  expect(index.builds).toBe(2)
})

test("R1-8：预热按读盘量封顶，剩下的不算", async () => {
  const files = [1, 2, 3].map(() => newFile([...bigOutput(8), reply("claude-opus-4-6", "2026-10-11T01:00:00Z")]))   // 每个约 512KB
  const published: Array<string | undefined> = []
  const tracker = new SessionModelTracker({
    binding: (n) => ({ id: n, kind: "claude" }),
    transcriptPath: async (b) => files[Number(b.id)],
    fallback: () => undefined,
    publish: (n) => published.push(n),
    now: Date.now,
  })
  expect(await tracker.warm(["0", "1", "2"], 600 * 1024)).toBe(2)
  expect(published).toEqual(["0", "1"])
})

// ── 审查 R1-1：转录里的 /model（CLI 接受了的）也算选择，按时间比 ──
const ESC = "\u001b"
const cmdLine = (args: string, ts: string) => JSON.stringify({ type: "user", timestamp: ts, message: { role: "user", content: `<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>${args}</command-args>` } })
const stdoutLine = (text: string, ts: string) => JSON.stringify({ type: "user", timestamp: ts, message: { role: "user", content: `<local-command-stdout>${text}</local-command-stdout>` } })

test("CLI 的 Set model to 输出（obelisk 里查到的真实样子：ANSI 粗体 / 反引号 / 带 effort / 存成默认）", () => {
  expect(parseSetModelOutput(`Set model to ${ESC}[1mOpus 4.6 (1M context)${ESC}[22m and saved as your default for new sessions`)).toBe("Opus 4.6 (1M context)")
  expect(parseSetModelOutput("Set model to `Opus 5.5` and saved as your default for new sessions with `high` effort")).toBe("Opus 5.5")
  expect(parseSetModelOutput(`Set model to ${ESC}[1mOpus 4.7${ESC}[22m with ${ESC}[1mhigh${ESC}[22m effort`)).toBe("Opus 4.7")
  expect(parseSetModelOutput(`Set model to ${ESC}[1mOpus 4.7${ESC}[22m`)).toBe("Opus 4.7")
  expect(parseSetModelOutput("Model 'claude-bogus' not found")).toBeUndefined()
})

test("CLI 显示名 → 模型 id；天生 1M 的不加 [1m]", () => {
  expect(modelFromDisplay("Opus 4.6 (1M context)")).toBe("claude-opus-4-6[1m]")
  expect(modelFromDisplay("Opus 4.6")).toBe("claude-opus-4-6")
  expect(modelFromDisplay("Opus 5.5 (1M context)")).toBe("claude-opus-5-5")
  expect(modelFromDisplay("Opus 5 (1M context) (default)")).toBe("claude-opus-5")
  expect(modelFromDisplay("Sonnet 4.6 (default)")).toBe("claude-sonnet-4-6")
  expect(modelFromDisplay("claude-fable-5[1m] (1M context)")).toBe("claude-fable-5[1m]")
  expect(modelFromDisplay("Fable")).toBe("fable")
  expect(modelFromDisplay("Default (recommended)")).toBeUndefined()
})

test("/model 后面是 Set model to → 算一次切换；是别的输出 → 没接受；选单从显示名推", () => {
  const p = new FactsParser("claude", "claude-opus-4-6[1m]")
  p.consume(cmdLine("claude-sonnet-4-6", "2026-10-11T01:00:00Z"))
  p.consume(stdoutLine(`Set model to ${ESC}[1mSonnet 4.6${ESC}[22m`, "2026-10-11T01:00:01Z"))
  expect(p.facts.switch).toEqual({ atMs: Date.parse("2026-10-11T01:00:00Z"), arg: "claude-sonnet-4-6", display: "Sonnet 4.6", model: "claude-sonnet-4-6" })
  p.consume(cmdLine("claude-bogus", "2026-10-11T02:00:00Z"))
  p.consume(stdoutLine("Model 'claude-bogus' not found", "2026-10-11T02:00:01Z"))
  expect(p.facts.switch?.arg).toBe("claude-sonnet-4-6")
  expect(p.facts.rejected).toEqual({ atMs: Date.parse("2026-10-11T02:00:00Z"), arg: "claude-bogus" })
  p.consume(cmdLine("", "2026-10-11T03:00:00Z"))
  p.consume(stdoutLine("Set model to `Opus 4.6 (1M context)`", "2026-10-11T03:00:05Z"))
  expect(p.facts.switch?.model).toBe("claude-opus-4-6[1m]")
  p.consume(cmdLine("default", "2026-10-11T04:00:00Z"))
  p.consume(stdoutLine("Set model to `Opus 5.5 (default)`", "2026-10-11T04:00:01Z"))
  expect(p.facts.switch?.model).toBe("claude-opus-4-6[1m]")   // /model default 照之前定的 (b) 按 hub 默认
  // 正文里提到 <local-command-stdout> 但前面没有 /model：不算
  const q = new FactsParser("claude")
  q.consume(stdoutLine("Set model to `Opus 5.5`", "2026-10-11T05:00:00Z"))
  expect(q.facts.switch).toBeUndefined()
})

test("R1-1：先选 sonnet-4-6[1m]，终端里再切成不带 [1m] 的 → 不接旧后缀，180K 占用按 200K 算 90%", async () => {
  const t0 = Date.parse("2026-10-11T01:00:00Z")
  const p = newFile([reply("claude-sonnet-4-6", "2026-10-11T00:59:00Z")])
  let now = t0
  const published: Array<string | undefined> = []
  const tracker = new SessionModelTracker({
    binding: () => ({ id: "x", kind: "claude" }),
    transcriptPath: async () => p,
    fallback: () => "claude-opus-4-6[1m]",
    publish: (_n, m) => published.push(m),
    now: () => now,
  })
  await tracker.noteChoice("s", "claude-sonnet-4-6[1m]")   // 拉起
  appendFileSync(p, [reply("claude-sonnet-4-6", "2026-10-11T01:01:00Z")].map((l) => l + "\n").join(""))
  await tracker.refresh("s")
  expect(tracker.known("s")).toBe("claude-sonnet-4-6[1m]")
  appendFileSync(p, [cmdLine("claude-sonnet-4-6", "2026-10-11T01:02:00Z"), stdoutLine("Set model to `Sonnet 4.6`", "2026-10-11T01:02:01Z"),
    reply("claude-sonnet-4-6", "2026-10-11T01:03:00Z")].map((l) => l + "\n").join(""))
  now = t0 + 10 * 60_000
  await tracker.refresh("s")
  expect(tracker.known("s")).toBe("claude-sonnet-4-6")
  const window = contextWindowFor(carryContextSuffix("claude-sonnet-4-6", tracker.suffixSource("s")))
  expect(window).toBe(200_000)
  expect(Math.round(180_000 / window * 100)).toBe(90)
  expect(published).toEqual(["claude-sonnet-4-6[1m]", "claude-sonnet-4-6"])
})

test("R1-1：CLI 没接受的 /model 不算切换；选单选的模型认不出 → 不接旧 [1m]", async () => {
  const p = newFile([reply("claude-opus-4-6", "2026-10-11T01:01:00Z")])
  const tracker = new SessionModelTracker({
    binding: () => ({ id: "x", kind: "claude" }),
    transcriptPath: async () => p,
    fallback: () => undefined,
    publish: () => {},
    now: () => Date.parse("2026-10-11T01:00:00Z"),
  })
  await tracker.noteChoice("s", "claude-opus-4-6[1m]")
  appendFileSync(p, [cmdLine("claude-bogus", "2026-10-11T01:02:00Z"), stdoutLine("Model not found", "2026-10-11T01:02:01Z")].map((l) => l + "\n").join(""))
  await tracker.refresh("s")
  expect(tracker.known("s")).toBe("claude-opus-4-6[1m]")
  appendFileSync(p, [cmdLine("", "2026-10-11T01:03:00Z"), stdoutLine("Set model to `Something New`", "2026-10-11T01:03:05Z"),
    reply("claude-opus-4-6", "2026-10-11T01:04:00Z")].map((l) => l + "\n").join(""))
  await tracker.refresh("s")
  expect(tracker.known("s")).toBe("claude-opus-4-6")
  expect(tracker.suffixSource("s")).toBeUndefined()
})

// ── 审查 R1-3：app 的 /model 先是请求中 ──
test("回复对不对得上请求：同族同版本 / 别名同族 / 认不出比原文", () => {
  expect(sameModelLoose("claude-sonnet-5", "sonnet")).toBe(true)
  expect(sameModelLoose("claude-opus-4-6", "claude-opus-4-6[1m]")).toBe(true)
  expect(sameModelLoose("claude-opus-4-6", "claude-opus-4-7")).toBe(false)
  expect(sameModelLoose("claude-opus-5-5", "sonnet")).toBe(false)
  expect(sameModelLoose("gpt-5.2-codex", "gpt-5.2-codex")).toBe(true)
})

test("R1-3：请求中不发布、不当 [1m] 来源；一直没下文过了期限就丢掉", async () => {
  const p = newFile([reply("claude-opus-4-6", "2026-10-11T00:59:00Z")])
  let now = Date.parse("2026-10-11T01:00:00Z")
  const published: Array<string | undefined> = []
  const tracker = new SessionModelTracker({
    binding: () => ({ id: "x", kind: "claude" }),
    transcriptPath: async () => p,
    fallback: () => "claude-opus-4-6[1m]",
    publish: (_n, m) => published.push(m),
    now: () => now,
  })
  await tracker.notePending("s", "claude-sonnet-5", "claude-sonnet-5")
  expect(published).toEqual(["claude-opus-4-6[1m]"])
  expect(tracker.suffixSource("s")).toBe("claude-opus-4-6[1m]")
  now += PENDING_TTL_MS + 1
  await tracker.refresh("s")
  expect(tracker.pendingOf("s")).toBeUndefined()
  expect(published).toEqual(["claude-opus-4-6[1m]"])
})

// ── 审查 R1-9：绑定代次、清掉、容量 / 期限 ──
test("R1-9：codex 换了新会话还没 rollout → 清掉旧模型（发 null）；快照不发没绑定的", async () => {
  const a = newFile([turnCtx("gpt-5.2-codex", "2026-10-11T01:00:00Z")])
  let bound: string | undefined = "A"
  const published: Array<[string, string | undefined]> = []
  const tracker = new SessionModelTracker({
    binding: () => (bound ? { id: bound, kind: "codex" } : undefined),
    transcriptPath: async (b) => (b.id === "A" ? a : undefined),
    fallback: () => undefined,
    publish: (n, m) => published.push([n, m]),
    now: Date.now,
  })
  await tracker.refresh("mp-codex-1")
  expect(tracker.snapshot()).toEqual([["mp-codex-1", "gpt-5.2-codex"]])
  bound = "B"
  expect(tracker.snapshot()).toEqual([])   // 绑定换了还没重算：不补发旧值
  await tracker.refresh("mp-codex-1")
  expect(published).toEqual([["mp-codex-1", "gpt-5.2-codex"], ["mp-codex-1", undefined]])
  expect(JSON.parse(buildSessionModelFrame("mp-codex-1", undefined))).toEqual({ type: "session_model", session_name: "mp-codex-1", model: null, model_id: null })
})

test("R1-9：读转录期间绑定换了 → 这次结果不作数，按新绑定再算", async () => {
  const a = newFile([turnCtx("gpt-5.2-codex", "2026-10-11T01:00:00Z")])
  const b = newFile([turnCtx("gpt-5.3-codex", "2026-10-11T02:00:00Z")])
  let bound = "A"
  const published: Array<string | undefined> = []
  const tracker = new SessionModelTracker({
    binding: () => ({ id: bound, kind: "codex" }),
    transcriptPath: async (x) => { const p = x.id === "A" ? a : b; bound = "B"; return p },   // 第一次读的时候换了
    fallback: () => undefined,
    publish: (_n, m) => published.push(m),
    now: Date.now,
  })
  await tracker.refresh("s")
  expect(published).toEqual(["gpt-5.3-codex"])
})

test("R1-9：会话数有上限、久没碰的清掉", async () => {
  let now = 0
  const tracker = new SessionModelTracker({
    binding: () => undefined, transcriptPath: async () => undefined, fallback: () => "claude-opus-4-6[1m]", publish: () => {}, now: () => now,
  })
  for (let i = 0; i < MAX_TRACKED_SESSIONS + 50; i++) { now++; await tracker.refresh(`s${i}`) }
  expect(tracker.size).toBeLessThanOrEqual(MAX_TRACKED_SESSIONS)
  expect(tracker.known(`s${MAX_TRACKED_SESSIONS + 49}`)).toBe("claude-opus-4-6[1m]")
  expect(tracker.known("s0")).toBeUndefined()
  now += TRACKED_SESSION_TTL_MS + 1
  await tracker.refresh("fresh")
  expect(tracker.size).toBe(1)
})
