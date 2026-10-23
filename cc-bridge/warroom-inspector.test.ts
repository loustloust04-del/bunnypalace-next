import { test, expect } from "bun:test"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { WarroomLedger } from "./warroom-ledger.ts"
import {
  buildInspectorPrompt, buildInspectorCommand, parseVerdict,
  reworkDepth, buildReworkTask, buildDeskNotice,
  INSPECTOR_ALLOWED_TOOLS, MAX_REWORK_ROUNDS, type EvidencePack,
} from "./warroom-inspector.ts"

const EV: EvidencePack = {
  taskId: "zz-0726-05", workOrder: "补 reader-daemon 测试",
  filescope: "cc-bridge/reader-daemon*", gitBase: "abc1234",
  cwd: "/x", transcriptPath: "/x/t.jsonl",
  receiptJson: '{"status":"done","summary":"测试全过"}', reworkRound: 0,
}

test("对手协议 prompt：定罪开场 / 原始输出要求 / 强制翻面 / 越界规则 / JSON 输出", () => {
  const p = buildInspectorPrompt(EV)
  expect(p).toContain("假设它是错的")
  expect(p).toContain("原始输出")
  expect(p).toContain("强制翻面")
  expect(p).toContain("git diff abc1234")
  expect(p).toContain("越界")
  expect(p).toContain('"verdict"')
  expect(p).toContain("收据是它自己写的")
})

test("验收官命令：只读工具锁、无 Edit/Write、sonnet", () => {
  const cmd = buildInspectorCommand("prompt")
  expect(cmd).toContain("--allowedTools")
  expect(INSPECTOR_ALLOWED_TOOLS).not.toMatch(/\bEdit\b|\bWrite\b/)
  expect(INSPECTOR_ALLOWED_TOOLS).toContain("Bash(git diff:*)")
  expect(INSPECTOR_ALLOWED_TOOLS).toContain("Bash(bun test:*)")
  expect(cmd[cmd.indexOf("--model") + 1]).toBe("sonnet")
})

test("verdict 解析：干净 JSON / 包在 result 里 / ```json 块 / 坏输出", () => {
  const wrap = (result: string) => JSON.stringify({ is_error: false, result })
  const v1 = parseVerdict(wrap('{"verdict":"rejected","reasons":["测试没真跑"],"rework_instruction":"真跑一遍"}'))
  expect(v1!.verdict).toBe("rejected")
  expect(v1!.rework_instruction).toBe("真跑一遍")
  const v2 = parseVerdict(wrap('前置说明\n```json\n{"verdict":"approved","reasons":["diff 与工单一致"]}\n```'))
  expect(v2!.verdict).toBe("approved")
  expect(parseVerdict(wrap("我觉得挺好的"))).toBe(null)                       // 没 JSON
  expect(parseVerdict(wrap('{"verdict":"maybe","reasons":[]}'))).toBe(null)   // 非法枚举
  expect(parseVerdict(JSON.stringify({ is_error: true, result: "x" }))).toBe(null)
})

test("返工链：depth 计数 + 轮数守卫 + 返工奏折内容", () => {
  const l = new WarroomLedger(join(mkdtempSync(join(tmpdir(), "wi-")), "l.db"))
  const base = { title: "补测试", body: "补 reader 测试", target_kind: "resume" as const, target_ref: "s1", engine: "claude" as const, created_by: "z" }
  const t0 = l.createTask(base)
  expect(reworkDepth(l, t0)).toBe(0)
  const verdict = { verdict: "rejected" as const, reasons: ["测试没真跑", "有 TODO"], rework_instruction: "真跑测试并去掉 TODO" }

  const spec1 = buildReworkTask(l, t0, verdict)!
  expect(spec1.parent_task).toBe(t0.task_id)
  expect(spec1.body).toContain("测试没真跑")
  expect(spec1.body).toContain("真跑测试并去掉 TODO")
  // 模拟第一轮返工单入库（先把 t0 走到终态释放锁）
  l.transition(t0.task_id, "dispatched", "hub"); l.transition(t0.task_id, "evidence_in", "hub"); l.transition(t0.task_id, "rejected", "inspector")
  const t1 = l.createTask(spec1)
  expect(reworkDepth(l, t1)).toBe(1)

  l.transition(t1.task_id, "dispatched", "hub"); l.transition(t1.task_id, "evidence_in", "hub"); l.transition(t1.task_id, "rejected", "inspector")
  const spec2 = buildReworkTask(l, t1, verdict)!
  const t2 = l.createTask(spec2)
  expect(reworkDepth(l, t2)).toBe(2)
  expect(MAX_REWORK_ROUNDS).toBe(2)
  expect(buildReworkTask(l, t2, verdict)).toBe(null)   // 轮数用尽 → 升级
  l.close()
})

test("desk 通知：四种事件文案", () => {
  const l = new WarroomLedger(join(mkdtempSync(join(tmpdir(), "wi-")), "l.db"))
  const t = l.createTask({ title: "x", body: "y", target_kind: "resume", target_ref: "s1", engine: "claude", created_by: "z" })
  const ok = buildDeskNotice(t, { verdict: "approved", reasons: ["一致"] }, "approved")
  expect(ok).toContain("warroom-desk")
  expect(ok).toContain("验收通过")
  expect(buildDeskNotice(t, { verdict: "rejected", reasons: ["糊弄"] }, "rejected_rework")).toContain("返工")
  expect(buildDeskNotice(t, null, "escalate")).toContain("御裁")
  expect(buildDeskNotice(t, null, "failed")).toContain("failed")
  l.close()
})
