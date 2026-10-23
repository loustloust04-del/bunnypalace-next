import { afterAll, expect, test } from "bun:test"
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { cliModelFor, DEFAULT_MODEL_MARK, lastModelEvent, modelFailureEvidence, ModelPrefs, parseModelCommand, pickLaunchModel, planModelRecovery, readModelEventWithin, shellQuote, type ModelPref } from "./cc-model"

const dir = mkdtempSync(join(tmpdir(), "cc-model-test-"))
afterAll(() => rmSync(dir, { recursive: true, force: true }))
const DEF = "claude-opus-4-6[1m]"

test("parseModelCommand：带参记原文，default 归位，不带参 / 别的命令 / 怪参数不记", () => {
  expect(parseModelCommand("/model claude-opus-5-5")).toEqual({ kind: "set", model: "claude-opus-5-5" })
  expect(parseModelCommand("  /model   sonnet[1m]  ")).toEqual({ kind: "set", model: "sonnet[1m]" })
  expect(parseModelCommand("/model opus")).toEqual({ kind: "set", model: "opus" })
  expect(parseModelCommand("/model default")).toEqual({ kind: "reset" })
  expect(parseModelCommand("/model Default")).toEqual({ kind: "reset" })
  expect(parseModelCommand("/model")).toBeNull()          // 开交互选单
  expect(parseModelCommand("/model   ")).toBeNull()
  expect(parseModelCommand("/models opus")).toBeNull()
  expect(parseModelCommand("/effort high")).toBeNull()
  expect(parseModelCommand("帮我 /model opus")).toBeNull()
  expect(parseModelCommand("/model a\nb")).toBeNull()      // 控制字符
  expect(parseModelCommand("/model a\u0000b")).toBeNull()   // NUL
  expect(parseModelCommand("/model x'; touch pwned")).toBeNull()   // 引号 / 空白 / 分号：不是模型名
  expect(parseModelCommand("/model us.anthropic.claude-opus-4-1-20250805-v1:0")?.kind).toBe("set")   // 云厂商 id
  expect(parseModelCommand("/model claude-opus-4-1@20250805")?.kind).toBe("set")
  expect(parseModelCommand(`/model ${"x".repeat(201)}`)).toBeNull()
})

test("shellQuote：引号 / 空格 / $() / 反引号 / 分号原样过 shell，不会被执行", () => {
  const nasty = [`a'b`, `x'; touch ${dir}/pwned; echo '`, "$(touch " + dir + "/pwned2)", "`id`", "a b\tc", "''", "sonnet[1m]", "*"]
  for (const s of nasty) {
    const r = Bun.spawnSync(["sh", "-c", `printf %s ${shellQuote(s)}`], { cwd: dir })
    expect(r.stdout.toString()).toBe(s)
  }
  expect(existsSync(join(dir, "pwned"))).toBe(false)
  expect(existsSync(join(dir, "pwned2"))).toBe(false)
  expect(shellQuote("claude-opus-4-6[1m]")).toBe("'claude-opus-4-6[1m]'")   // 普通名字跟原来 '…' 一样
})

const user = (text: string, ts: string, extra: object = {}) => JSON.stringify({ type: "user", timestamp: ts, message: { role: "user", content: text }, ...extra })
const userParts = (text: string, ts: string) => JSON.stringify({ type: "user", timestamp: ts, message: { role: "user", content: [{ type: "text", text }] } })
const reply = (model: string, ts: string, extra: object = {}) => JSON.stringify({ type: "assistant", timestamp: ts, message: { role: "assistant", model, content: [{ type: "text", text: "嗯" }] }, ...extra })
const modelCmd = (args: string) => `<command-message>model</command-message>\n<command-name>/model</command-name>\n<command-args>${args}</command-args>`

test("lastModelEvent：取最后一次 /model；带参原文、default、选单（取之后第一条回复的模型）", () => {
  expect(lastModelEvent([])).toBeNull()
  expect(lastModelEvent([user("你好", "t1"), reply("claude-opus-4-6", "t2")])).toBeNull()
  expect(lastModelEvent([
    user(modelCmd("sonnet"), "2026-10-01T00:00:00Z"), reply("claude-sonnet-5", "t"),
    user(modelCmd("claude-opus-5-5[1m]"), "2026-10-02T00:00:00Z"), reply("claude-opus-5-5", "t"),
  ])).toEqual({ kind: "set", model: "claude-opus-5-5[1m]", at: "2026-10-02T00:00:00Z" })
  expect(lastModelEvent([userParts(modelCmd("default"), "2026-10-03T00:00:00Z")])).toEqual({ kind: "reset", at: "2026-10-03T00:00:00Z" })
  // 选单：参数空，取它之后最近的一条主线回复（子代理 / <synthetic> 不算）
  expect(lastModelEvent([
    reply("claude-opus-4-6", "t0"),
    user(modelCmd(""), "2026-10-04T00:00:00Z"),
    reply("claude-haiku-5", "t", { isSidechain: true }),
    reply("<synthetic>", "t"),
    reply("claude-opus-5-5", "t1"),
    reply("claude-opus-5-5", "t2"),
  ])).toEqual({ kind: "set", model: "claude-opus-5-5", at: "2026-10-04T00:00:00Z", picker: true })
  expect(lastModelEvent([reply("claude-opus-4-6", "t0"), user(modelCmd(""), "t1")])).toBeNull()   // 选完还没回复：不知道
  expect(lastModelEvent(["{半行", "", user(modelCmd("opus"), "t")])).toEqual({ kind: "set", model: "opus", at: "t" })
  // 不是 /model 的斜杠命令、正文里提到 /model 的不算
  expect(lastModelEvent([user("<command-name>/effort</command-name><command-args>high</command-args>", "t"), user("我想 /model opus", "t")])).toBeNull()
})

test("审查 R1-9：只认独立的命令记录——正文 / channel 里提到命令标签的不算", () => {
  const tag = "<command-name>/model</command-name><command-args>haiku</command-args>"
  expect(lastModelEvent([user(`切模型的记录长这样：${tag}`, "t")])).toBeNull()
  expect(lastModelEvent([user(`<channel source="memorypalace" chat_id="c">${tag}</channel>`, "t")])).toBeNull()
  expect(lastModelEvent([userParts(`${tag}\n顺便问一句`, "t")])).toBeNull()
  expect(lastModelEvent([user(`${tag}<command-name>/model</command-name>`, "t")])).toBeNull()   // 两个命令名：结构不完整
  expect(lastModelEvent([user(`  <command-args>haiku</command-args>\n<command-name>/model</command-name>  `, "2026-10-01T00:00:00Z")]))
    .toEqual({ kind: "set", model: "haiku", at: "2026-10-01T00:00:00Z" })   // 顺序不限
  // 真命令在前、正文冒充在后：取真命令
  expect(lastModelEvent([user(modelCmd("opus"), "t1"), reply("claude-opus-5-5", "t2"), user(`看这个 ${tag}`, "t3")])).toMatchObject({ model: "opus" })
})

test("审查 R1-8：选单之后还没回复，不遮住更早的有效选择", () => {
  expect(lastModelEvent([
    user(modelCmd("sonnet[1m]"), "2026-10-01T00:00:00Z"), reply("claude-sonnet-5", "t"),
    user(modelCmd(""), "2026-10-02T00:00:00Z"),
  ])).toEqual({ kind: "set", model: "sonnet[1m]", at: "2026-10-01T00:00:00Z" })
  // 更早的是选单：取那次之后、后一个选单之前的回复
  expect(lastModelEvent([
    user(modelCmd(""), "2026-10-01T00:00:00Z"), reply("claude-opus-5-5", "t"),
    user(modelCmd(""), "2026-10-02T00:00:00Z"),
  ])).toEqual({ kind: "set", model: "claude-opus-5-5", at: "2026-10-01T00:00:00Z", picker: true })
  // 参数不像模型名（没切成）也不遮
  expect(lastModelEvent([user(modelCmd("opus"), "t1"), user(modelCmd("a\u0001b"), "t2")])).toMatchObject({ model: "opus" })
})

const pref = (model: string, at: string, source: ModelPref["source"] = "app"): ModelPref => ({ model, updatedAt: at, source })

test("pickLaunchModel：无记录用默认；有记录用记录；转录更新用转录；default 回默认；选单同一模型保住 [1m]", () => {
  expect(pickLaunchModel(DEF)).toEqual({ model: DEF, source: "默认" })
  expect(pickLaunchModel(DEF, pref("claude-opus-5-5", "2026-10-01T00:00:00Z")).model).toBe("claude-opus-5-5")
  expect(pickLaunchModel(DEF, pref(DEFAULT_MODEL_MARK, "2026-10-01T00:00:00Z")).model).toBe(DEF)
  // 转录比记录新 → 转录；比记录旧 → 记录
  const rec = pref("claude-opus-5-5", "2026-10-02T00:00:00Z")
  expect(pickLaunchModel(DEF, rec, { kind: "set", model: "sonnet[1m]", at: "2026-10-03T00:00:00Z" })).toEqual({ model: "sonnet[1m]", source: "转录" })
  expect(pickLaunchModel(DEF, rec, { kind: "set", model: "sonnet[1m]", at: "2026-10-01T00:00:00Z" }).model).toBe("claude-opus-5-5")
  expect(pickLaunchModel(DEF, rec, { kind: "set", model: "sonnet[1m]" }).model).toBe("claude-opus-5-5")   // 没时间戳信记录
  expect(pickLaunchModel(DEF, undefined, { kind: "set", model: "opus" }).model).toBe("opus")
  expect(pickLaunchModel(DEF, rec, { kind: "reset", at: "2026-10-03T00:00:00Z" }).model).toBe(DEF)
  // 明确要回默认的记录比转录新 → 默认（转录里更早的切换不冒出来）
  expect(pickLaunchModel(DEF, pref(DEFAULT_MODEL_MARK, "2026-10-05T00:00:00Z"), { kind: "set", model: "opus", at: "2026-10-04T00:00:00Z" }).model).toBe(DEF)
  // 选单只知道回复里的 id：跟打底同一个 → 不动（不把 [1m] 丢了）；不同 → 用它
  expect(pickLaunchModel(DEF, undefined, { kind: "set", model: "claude-opus-4-6", picker: true }).model).toBe(DEF)
  expect(pickLaunchModel(DEF, undefined, { kind: "set", model: "claude-opus-5-5", picker: true })).toEqual({ model: "claude-opus-5-5", source: "转录（选单）" })
})

test("ModelPrefs：记下 → 异步原子落盘 → 新实例（hub 重启）读回；连发并成一次写，不留临时文件", async () => {
  const path = join(dir, "cc-models.json")
  const a = new ModelPrefs(path)
  a.load()   // 文件不存在：空
  expect(a.get("mp-cc-x")).toBeUndefined()
  const t = new Date("2026-10-11T01:02:03Z")
  a.set("mp-cc-x", "sonnet[1m]", "app", t)
  a.set("mp-cc-y", "claude-opus-5-5", "转录", t)
  a.set("mp-cc-x", "claude-opus-5-5", "app", t)
  await a.flush()
  const b = new ModelPrefs(path)
  b.load()
  expect(b.get("mp-cc-x")).toEqual({ model: "claude-opus-5-5", updatedAt: t.toISOString(), source: "app", usedAt: t.toISOString() })
  expect(b.get("mp-cc-y")?.model).toBe("claude-opus-5-5")
  expect(readdirSync(dir).filter((f) => f.includes(".tmp-"))).toEqual([])
  expect((Bun.spawnSync(["stat", "-f", "%Lp", path]).stdout.toString().trim())).toBe("600")
  b.set("mp-cc-x", DEFAULT_MODEL_MARK, "app", t)
  await b.flush()
  expect(JSON.parse(readFileSync(path, "utf-8"))["mp-cc-x"].model).toBe(DEFAULT_MODEL_MARK)
})

test("ModelPrefs：坏文件不炸，当没有", async () => {
  const path = join(dir, "bad.json")
  await Bun.write(path, "{坏")
  const p = new ModelPrefs(path)
  p.load()
  expect(p.get("x")).toBeUndefined()
})

test("审查 R1-11：load / set 共用模型名校验，坏记录逐条丢（NUL、超长、坏时间、未知来源）", async () => {
  const path = join(dir, "mixed.json")
  const ok = { model: "claude-opus-5-5", updatedAt: "2026-10-01T00:00:00Z", source: "app" }
  await Bun.write(path, JSON.stringify({
    good: ok,
    nul: { ...ok, model: "a\u0000b" },
    long: { ...ok, model: "x".repeat(500_000) },
    quote: { ...ok, model: "x'y" },
    time: { ...ok, updatedAt: "不是时间" },
    src: { ...ok, source: "黑客" },
    used: { ...ok, usedAt: 5 },
    notObj: "opus",
  }))
  const p = new ModelPrefs(path)
  p.load()
  expect(p.size).toBe(1)
  expect(p.get("good")?.model).toBe("claude-opus-5-5")
  expect(p.set("x", "a b", "app")).toBe(false)
  expect(p.set("x", "x".repeat(201), "app")).toBe(false)
  expect(p.get("x")).toBeUndefined()
  // 坏时间戳的记录进不来，也就压不住后来正确的转录
  expect(pickLaunchModel(DEF, p.get("time"), { kind: "set", model: "opus", at: "2026-10-02T00:00:00Z" }).model).toBe("opus")
  await p.flush()
})

test("审查 R1-13：最多留 N 个会话，按最近使用淘汰；拉起算使用；显式删除清掉", async () => {
  const path = join(dir, "cap.json")
  const p = new ModelPrefs(path, 3)
  const at = (h: number) => new Date(Date.UTC(2026, 9, 1, h))
  p.set("a", "opus", "app", at(1))
  p.set("b", "opus", "app", at(2))
  p.set("c", "opus", "app", at(3))
  p.touch("a", at(4))            // a 刚被拉起过
  p.set("d", "opus", "app", at(5))   // 超了：淘汰最久没用的 b
  expect([...["a", "b", "c", "d"]].filter((k) => p.get(k))).toEqual(["a", "c", "d"])
  p.delete("c")
  expect(p.get("c")).toBeUndefined()
  await p.flush()
  const q = new ModelPrefs(path, 3)
  q.load()
  expect(q.size).toBe(2)
})

test("审查 R1-12：flush 等到最后一次写落盘（子进程 set 后立刻 flush 再退出）", () => {
  const path = join(dir, "exit.json")
  const script = `import { ModelPrefs } from ${JSON.stringify(join(import.meta.dir, "cc-model.ts"))}
const p = new ModelPrefs(${JSON.stringify(path)}); p.set("mp-cc-exit", "opus", "app"); await p.flush(); process.exit(0)`
  const r = Bun.spawnSync(["bun", "-e", script], { cwd: dir })
  expect(r.exitCode).toBe(0)
  expect(JSON.parse(readFileSync(path, "utf-8"))["mp-cc-exit"].model).toBe("opus")
})

test("审查 R1-3：读转录带截止时间——卡住按超时返回；迟到的结果 / 出错都不抛", async () => {
  let lateResolve: ((l: string[]) => void) | undefined
  const t0 = Date.now()
  const r = await readModelEventWithin(() => new Promise<string[]>((res) => { lateResolve = res }), 50)
  expect(r).toEqual({ event: null, problem: "超过 50ms" })
  expect(Date.now() - t0).toBeLessThan(1_000)
  lateResolve!([user(modelCmd("opus"), "t")])   // 迟到的结果：没人接，也不炸
  expect(await readModelEventWithin(() => Promise.reject(new Error("EACCES: 没权限\n第二行")), 50)).toEqual({ event: null, problem: "失败：EACCES: 没权限" })
  expect((await readModelEventWithin(async () => [user(modelCmd("opus"), "t")], 50)).event).toEqual({ kind: "set", model: "opus", at: "t" })
})

test("审查 R1-7 / R1-4：转录记录分开存事件时间和发现时间；未来时间不可信，压不过之后的选择", async () => {
  const p = new ModelPrefs(join(dir, "times.json"))
  const now = new Date("2026-10-11T10:00:00Z")
  const v0 = p.version("s")
  p.setFromTranscript("s", "opus", "2026-10-02T00:00:00Z", "aaaaaaaa-1111", now)
  expect(p.get("s")).toMatchObject({ model: "opus", source: "转录", updatedAt: "2026-10-02T00:00:00.000Z", seenAt: now.toISOString(), transcript: "aaaaaaaa-1111" })
  expect(p.version("s")).toBe(v0 + 1)
  p.setFromTranscript("f", "opus", "2099-01-01T00:00:00Z", "aaaaaaaa-1111", now)   // 未来时间：按发现时间记
  expect(p.get("f")?.updatedAt).toBe(now.toISOString())
  // app 之后选了 haiku：未来时间的转录事件压不过它
  const rec = pref("haiku", "2026-10-11T09:00:00Z")
  expect(pickLaunchModel(DEF, rec, { kind: "set", model: "opus", at: "2099-01-01T00:00:00Z" }, now.getTime()).model).toBe("haiku")
  expect(pickLaunchModel(DEF, undefined, { kind: "set", model: "opus", at: "2099-01-01T00:00:00Z" }, now.getTime()).model).toBe("opus")   // 没记录：还是用它
  await p.flush()
})

test("审查 R1-10：显式 default 和从没选过分开存；拉起时 default 先映射成 hub 默认（--model default 未实测）", () => {
  expect(cliModelFor(DEFAULT_MODEL_MARK, DEF)).toBe(DEF)
  expect(cliModelFor("opus", DEF)).toBe("opus")
  const explicit = pickLaunchModel(DEF, pref(DEFAULT_MODEL_MARK, "2026-10-01T00:00:00Z"))
  expect(explicit.model).toBe(DEF)
  expect(explicit.source).toContain("未实测")
  expect(pickLaunchModel(DEF)).toEqual({ model: DEF, source: "默认" })
})

test("审查 R1-4/5/6：只有明确的模型报错证据才降级，一次为限；已是默认 / 别的原因死掉不动", () => {
  const err = "API Error: There's an issue with the selected model (claude-bad-9). It may not exist or you may not have access to it."
  expect(modelFailureEvidence(err, "claude-bad-9")).toBe(true)
  expect(modelFailureEvidence("Error: model claude-bad-9 not found", "claude-bad-9[1m]")).toBe(true)   // [1m] 不影响认
  expect(modelFailureEvidence("Error: model claude-bad-9 not found", "opus")).toBe(false)              // 报的不是这次用的模型
  expect(modelFailureEvidence("Segmentation fault", "claude-bad-9")).toBe(false)
  expect(modelFailureEvidence("", "claude-bad-9")).toBe(false)
  expect(planModelRecovery({ launched: "claude-bad-9", fallback: DEF, evidence: err, used: 0 })).toBe(DEF)
  expect(planModelRecovery({ launched: "claude-bad-9", fallback: DEF, evidence: err, used: 1 })).toBeUndefined()   // 预算用完
  expect(planModelRecovery({ launched: "claude-bad-9", fallback: DEF, evidence: "jsonl 坏了", used: 0 })).toBeUndefined()
  expect(planModelRecovery({ launched: "claude-opus-4-6", fallback: DEF, evidence: "model claude-opus-4-6 not found", used: 0 })).toBeUndefined()   // 已经是默认那个
})
