import { test, expect } from "bun:test"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { WarroomLedger } from "./warroom-ledger.ts"
import {
  pickRoute, buildT2Command, buildWorkOrderTag, parseT2Output, parseCodexJsonl,
  WarroomDispatcher, type TargetInfo, type DispatcherDeps,
} from "./warroom-dispatch.ts"

const PROT = new Set(["mp-cc", "mp-cc-6", "mp-cc-2521523d"])
const mkTarget = (o: Partial<TargetInfo>): TargetInfo => ({
  sessionId: "aaaa", engine: "claude", alive: false, tmuxSession: null, cwd: "/x", transcriptPath: "/x/a.jsonl", ...o,
})

// ── 选路 ──

test("选路：活+tmux → t1；死+transcript → t2；活无tmux → 拒；无transcript → 拒", () => {
  expect(pickRoute(mkTarget({ alive: true, tmuxSession: "mp-cc-21m" }), PROT)).toEqual({ channel: "t1", tmuxSession: "mp-cc-21m" })
  expect(pickRoute(mkTarget({}), PROT).channel).toBe("t2")
  const t3 = pickRoute(mkTarget({ alive: true }), PROT)
  expect(t3.channel).toBe("reject")
  expect((t3 as any).reason).toContain("T3")
  expect(pickRoute(mkTarget({ transcriptPath: null }), PROT).channel).toBe("reject")
})

test("选路：陪伴会话（tmux 名或 session id 命中保护名单）永拒", () => {
  const byTmux = pickRoute(mkTarget({ alive: true, tmuxSession: "mp-cc-6" }), PROT)
  expect(byTmux.channel).toBe("reject")
  expect((byTmux as any).reason).toContain("陪伴")
  const byId = pickRoute(mkTarget({ sessionId: "mp-cc-2521523d" }), PROT)
  expect(byId.channel).toBe("reject")
})

// ── 命令与工单构造 ──

test("T2 命令：claude 带 resume/-p/json/acceptEdits + Bash 白名单；codex 走 exec resume + sandbox", () => {
  const l = new WarroomLedger(join(mkdtempSync(join(tmpdir(), "wd-")), "l.db"))
  const t = l.createTask({ title: "x", body: "补测试", target_kind: "resume", target_ref: "s1", engine: "claude", created_by: "z" })
  const cmd = buildT2Command(t, "s1")
  expect(cmd.slice(0, 9)).toEqual(["claude", "--resume", "s1", "-p", "补测试", "--output-format", "json", "--permission-mode", "acceptEdits"])
  const allowed = cmd[cmd.indexOf("--allowedTools") + 1]
  expect(allowed).toContain("Bash(bun test:*)")       // 测试类放行（zz-0726-04 实弹教训）
  expect(allowed).not.toMatch(/rm |sudo|push/)         // 危险命令不在名单
  const c = { ...t, engine: "codex" as const }
  const cc = buildT2Command(c, "s2")
  expect(cc.slice(0, 4)).toEqual(["codex", "exec", "resume", "s2"])
  expect(cc).toContain("--json")
  expect(cc).toContain("workspace-write")
  l.close()
})

test("T1 工单文本：含 task_id、收据路径、换行拍平", () => {
  const l = new WarroomLedger(join(mkdtempSync(join(tmpdir(), "wd-")), "l.db"))
  const t = l.createTask({ title: "x", body: "第一行\n第二行", target_kind: "tmux", target_ref: "s1", engine: "claude", created_by: "z" })
  const tag = buildWorkOrderTag(t, "/r")
  expect(tag).toContain(`task_id="${t.task_id}"`)
  expect(tag).toContain(`/r/${t.task_id}.json`)
  expect(tag).not.toContain("\n")
  l.close()
})

// ── 收据解析 ──

test("收据：claude 纯 JSON / 前置日志行 / 坏输出", () => {
  const good = '{"is_error":false,"result":"naked","total_cost_usd":0.5}'
  expect((parseT2Output("claude", good) as any).result).toBe("naked")
  const noisy = "some log line\n" + good
  expect((parseT2Output("claude", noisy) as any).result).toBe("naked")
  expect(parseT2Output("claude", "totally broken")).toBe(null)
})

test("收据：codex JSONL 事件流聚合", () => {
  const raw = [
    '{"msg":{"type":"task_started"}}',
    '{"msg":{"type":"agent_message","message":"done"}}',
    '{"msg":{"type":"token_count","total":123}}',
  ].join("\n")
  const r = parseCodexJsonl(raw) as any
  expect(r.event_count).toBe(3)
  expect(r.last_message.msg.message).toBe("done")
  expect(parseCodexJsonl("")).toBe(null)
})

// ── Dispatcher 端到端（假 deps）──

function mkDeps(target: TargetInfo, spawnResult: { stdout: string; exitCode: number; timedOut: boolean }) {
  const l = new WarroomLedger(join(mkdtempSync(join(tmpdir(), "wd-")), "l.db"))
  const sent: string[] = []
  let settled: (() => void) | null = null
  const settledPromise = new Promise<void>((r) => { settled = r })
  const deps: DispatcherDeps = {
    ledger: l,
    lookupTarget: () => target,
    sendTmux: async (tag, session) => { sent.push(`${session}::${tag}`) },
    spawnT2: async () => spawnResult,
    receiptDir: "/r",
    onT2Settled: () => settled?.(),
  }
  return { l, sent, deps, settledPromise }
}

test("Dispatcher：T1 路径注入 + 状态 dispatched", async () => {
  const { l, sent, deps } = mkDeps(mkTarget({ alive: true, tmuxSession: "mp-cc-21m" }), { stdout: "", exitCode: 0, timedOut: false })
  const d = new WarroomDispatcher(deps)
  const t = l.createTask({ title: "x", body: "跑一遍测试", target_kind: "tmux", target_ref: "s1", engine: "claude", created_by: "z" })
  const r = await d.dispatch(t.task_id, "z")
  expect(r.channel).toBe("t1")
  expect(sent.length).toBe(1)
  expect(sent[0]).toContain("mp-cc-21m::")
  expect(l.getTask(t.task_id)!.status).toBe("dispatched")
})

test("Dispatcher：T2 成功 → 收据入账 + evidence_in + cost 记账", async () => {
  const receipt = '{"is_error":false,"result":"done","total_cost_usd":0.42}'
  const { l, deps, settledPromise } = mkDeps(mkTarget({}), { stdout: receipt, exitCode: 0, timedOut: false })
  const d = new WarroomDispatcher(deps)
  const t = l.createTask({ title: "x", body: "补文档", target_kind: "resume", target_ref: "s1", engine: "claude", created_by: "z" })
  const r = await d.dispatch(t.task_id, "z")
  expect(r.channel).toBe("t2")
  await settledPromise
  const after = l.getTask(t.task_id)!
  expect(after.status).toBe("evidence_in")
  expect(after.cost_usd).toBeCloseTo(0.42)
  expect(JSON.parse(after.receipt!).result).toBe("done")
})

test("Dispatcher：T2 超时 → failed；is_error → failed", async () => {
  const a = mkDeps(mkTarget({}), { stdout: "", exitCode: 1, timedOut: true })
  const d1 = new WarroomDispatcher(a.deps)
  const t1 = a.l.createTask({ title: "x", body: "y", target_kind: "resume", target_ref: "s1", engine: "claude", created_by: "z" })
  await d1.dispatch(t1.task_id, "z"); await a.settledPromise
  expect(a.l.getTask(t1.task_id)!.status).toBe("failed")

  const b = mkDeps(mkTarget({}), { stdout: '{"is_error":true,"result":"boom"}', exitCode: 0, timedOut: false })
  const d2 = new WarroomDispatcher(b.deps)
  const t2 = b.l.createTask({ title: "x", body: "y", target_kind: "resume", target_ref: "s2", engine: "claude", created_by: "z" })
  await d2.dispatch(t2.task_id, "z"); await b.settledPromise
  expect(b.l.getTask(t2.task_id)!.status).toBe("failed")
})

test("Dispatcher：ask_susu 工单拒绝自动派", async () => {
  const { l, deps } = mkDeps(mkTarget({}), { stdout: "", exitCode: 0, timedOut: false })
  const d = new WarroomDispatcher(deps)
  const t = l.createTask({ title: "危险", body: "rm -rf dist", target_kind: "resume", target_ref: "s1", engine: "claude", created_by: "z" })
  expect(t.approval).toBe("ask_susu")
  await expect(d.dispatch(t.task_id, "z")).rejects.toThrow(/approval/)
  expect(l.getTask(t.task_id)!.status).toBe("draft")
})

test("repo 锁：不同 target 同 cwd → 第二张拒；不同 cwd → 放行", async () => {
  const l = new WarroomLedger(join(mkdtempSync(join(tmpdir(), "wd-")), "l.db"))
  const targets: Record<string, TargetInfo> = {
    "s1": mkTarget({ sessionId: "s1", cwd: "/repo/A" }),
    "s2": mkTarget({ sessionId: "s2", cwd: "/repo/A" }),   // 同 repo！
    "s3": mkTarget({ sessionId: "s3", cwd: "/repo/B" }),
  }
  const deps: DispatcherDeps = {
    ledger: l,
    lookupTarget: (ref) => targets[ref] ?? null,
    sendTmux: async () => {},
    spawnT2: () => new Promise(() => {}),   // 永不结算——保持 in-flight
    receiptDir: "/r",
  }
  const d = new WarroomDispatcher(deps)
  const t1 = l.createTask({ title: "a", body: "x", target_kind: "resume", target_ref: "s1", engine: "claude", created_by: "z" })
  await d.dispatch(t1.task_id, "z")
  const t2 = l.createTask({ title: "b", body: "y", target_kind: "resume", target_ref: "s2", engine: "claude", created_by: "z" })
  await expect(d.dispatch(t2.task_id, "z")).rejects.toThrow(/repo busy/)
  const t3 = l.createTask({ title: "c", body: "z", target_kind: "resume", target_ref: "s3", engine: "claude", created_by: "z" })
  const r3 = await d.dispatch(t3.task_id, "z")
  expect(r3.channel).toBe("t2")
  l.close()
})

test("预算防线：大 transcript 拒派并给出估算；budget_ok=true 放行；活 target 不受限", async () => {
  const l = new WarroomLedger(join(mkdtempSync(join(tmpdir(), "wd-")), "l.db"))
  const big = mkTarget({ sessionId: "big", cwd: "/repo/C" })
  const deps: DispatcherDeps = {
    ledger: l, lookupTarget: () => big,
    sendTmux: async () => {}, spawnT2: async () => ({ stdout: '{"is_error":false}', exitCode: 0, timedOut: false }),
    receiptDir: "/r",
    transcriptSize: () => 20 * 1024 * 1024,   // 20MB ≈ 2.6M tokens ≈ $49 —— 远超 $2 阈值
  }
  const d = new WarroomDispatcher(deps)
  const t = l.createTask({ title: "x", body: "y", target_kind: "resume", target_ref: "big", engine: "claude", created_by: "z" })
  await expect(d.dispatch(t.task_id, "z")).rejects.toThrow(/budget guard.*\$/)
  expect(l.getTask(t.task_id)!.status).toBe("draft")
  // 明示 budget_ok → 放行
  const r = await d.dispatch(t.task_id, "z", true)
  expect(r.channel).toBe("t2")
  l.close()
})

// ── M4：T4 repo 通道 ──

test("T4：命令无 --resume；目录不存在拒；成功走收据闭环到 evidence_in", async () => {
  const l = new WarroomLedger(join(mkdtempSync(join(tmpdir(), "wd-")), "l.db"))
  let settled: (() => void) | null = null
  const settledPromise = new Promise<void>((r) => { settled = r })
  let spawnedCwd: string | null = null
  const deps: DispatcherDeps = {
    ledger: l, lookupTarget: () => null,
    sendTmux: async () => {},
    spawnT2: async (cmd, cwd) => { spawnedCwd = cwd; return { stdout: '{"is_error":false,"result":"42 行","total_cost_usd":0.05}', exitCode: 0, timedOut: false } },
    receiptDir: "/r",
    repoExists: (d) => d === "/repo/ok",
    onT2Settled: () => settled?.(),
  }
  const d = new WarroomDispatcher(deps)
  const bad = l.createTask({ title: "x", body: "y", target_kind: "repo", target_ref: "/repo/nope", engine: "claude", created_by: "z" })
  await expect(d.dispatch(bad.task_id, "z")).rejects.toThrow(/dir not found/)
  const t = l.createTask({ title: "统计", body: "数行数", target_kind: "repo", target_ref: "/repo/ok", engine: "claude", created_by: "z" })
  const { buildT4Command } = await import("./warroom-dispatch.ts")
  expect(buildT4Command(t)).not.toContain("--resume")
  const r = await d.dispatch(t.task_id, "z")
  expect(r.channel).toBe("t4")
  await settledPromise
  const after = l.getTask(t.task_id)!
  expect(after.status).toBe("evidence_in")
  expect(after.cost_usd).toBeCloseTo(0.05)
  expect(spawnedCwd).toBe("/repo/ok")
  l.close()
})

test("DAG 派发闸：依赖未满足 dispatch 拒", async () => {
  const l = new WarroomLedger(join(mkdtempSync(join(tmpdir(), "wd-")), "l.db"))
  const deps: DispatcherDeps = {
    ledger: l, lookupTarget: () => null, sendTmux: async () => {},
    spawnT2: async () => ({ stdout: "", exitCode: 0, timedOut: false }),
    receiptDir: "/r", repoExists: () => true,
  }
  const d = new WarroomDispatcher(deps)
  const a = l.createTask({ title: "a", body: "x", target_kind: "repo", target_ref: "/rA", engine: "claude", created_by: "z" })
  const b = l.createTask({ title: "b", body: "y", target_kind: "repo", target_ref: "/rB", engine: "claude", created_by: "z", depends_on: [a.task_id] })
  await expect(d.dispatch(b.task_id, "z")).rejects.toThrow(/依赖未满足/)
  l.close()
})
