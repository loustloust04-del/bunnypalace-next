// 军机处 M2 · 验收官（三号骰子的制度化）
// 哲学：不信自我报告，信证据。验收官被 prompt 成对手——开场就假设工作是错的，
// 找不到反证才允许 approved。工具锁死只读+跑测试（无 Edit/Write）：改代码=造假。
import type { TaskRow, WarroomLedger } from "./warroom-ledger.ts"

export interface EvidencePack {
  taskId: string
  workOrder: string              // 原工单正文
  filescope: string | null
  gitBase: string | null         // dispatch 时记录的 HEAD
  cwd: string | null
  transcriptPath: string | null
  receiptJson: string | null
  reworkRound: number            // 当前是第几轮返工（0 = 首次）
}

export const INSPECTOR_ALLOWED_TOOLS =
  "Read Grep Glob Bash(git diff:*) Bash(git log:*) Bash(git status:*) Bash(git show:*) Bash(bun test:*) Bash(bun run:*) Bash(npm test:*) Bash(npx vitest:*) Bash(swift test:*) Bash(xcodebuild test:*) Bash(python3 -m pytest:*) Bash(tail:*) Bash(head:*) Bash(wc:*)"

export const MAX_REWORK_ROUNDS = Number(process.env.MP_WARROOM_MAX_REWORK ?? 2)

/** 对手协议 prompt。语言要素：定罪开场 / 证据规则 / 强制翻面 / 严格 JSON 输出。 */
export function buildInspectorPrompt(ev: EvidencePack): string {
  const parts: string[] = []
  parts.push(`你是军机处验收官。一份声称完成的工作摆在你面前。**假设它是错的、没做完的、或在糊弄——你的任务是找出证据证明这一点。**`)
  parts.push(`【工单 ${ev.taskId}${ev.reworkRound > 0 ? `（第 ${ev.reworkRound} 轮返工后复验）` : ""}】\n${ev.workOrder}`)
  if (ev.filescope) parts.push(`【允许触碰的文件范围】${ev.filescope}\n——diff 里出现范围外的改动 = 越界，直接 rejected。`)
  if (ev.gitBase && ev.cwd) parts.push(`【取证 · diff】在本目录跑 \`git diff ${ev.gitBase}\` 和 \`git status\`——这就是这张工单造成的全部变更。逐文件对照工单目标。`)
  if (ev.transcriptPath) parts.push(`【取证 · 过程】执行者的完整过程记录在 ${ev.transcriptPath}（jsonl，用 Read/Grep 查）。重点：它声称跑过的每一个测试，在记录里找到**原始输出行**（pass/fail 字样）。找不到原始输出 = 它在转述 = 不可信。`)
  if (ev.receiptJson) parts.push(`【它的自我报告（收据）】\n${ev.receiptJson.slice(0, 3000)}\n——记住：收据是它自己写的。每一条声称都要用 diff/transcript/重跑测试对证。`)
  parts.push(`【取证规则】
1. 声称"测试通过"→ 你亲自重跑一遍（工具已允许 bun test / npm test 等），以你跑出来的为准。
2. diff 里出现 TODO、占位符、空函数体、被注释掉的断言 = 未完成。
3. 只改了测试没改实现、或删测试让它变绿 = 糊弄，rejected。
4. 你没有 Edit/Write 权限——你是验收官不是修理工，发现问题就写进返工指令。`)
  parts.push(`【强制翻面】列完你能找到的所有反证之后：如果每一条都被证据推翻了，才允许 approved。拿不准的地方（证据不足、无法重跑、工单本身歧义）用 unsure，不要硬判。`)
  parts.push(`【输出】只输出一个 JSON 对象，不要任何其他文字：
{"verdict":"approved"|"rejected"|"unsure","reasons":["…每条一句话，附证据指针…"],"rework_instruction":"仅 rejected 时——给执行者的具体返工指令，可执行、可验证"}`)
  return parts.join("\n\n")
}

/** 验收官命令行（在 target cwd 跑；只读+测试工具；sonnet 省钱） */
export function buildInspectorCommand(prompt: string): string[] {
  const model = process.env.MP_WARROOM_INSPECTOR_MODEL ?? "sonnet"
  return [
    "claude", "-p", prompt,
    "--output-format", "json",
    "--model", model,
    "--allowedTools", INSPECTOR_ALLOWED_TOOLS,
  ]
}

export interface Verdict {
  verdict: "approved" | "rejected" | "unsure"
  reasons: string[]
  rework_instruction?: string
}

/** 从验收官的 stdout JSON（claude -p 的 result 字段里是它输出的文本）解析 verdict */
export function parseVerdict(claudeStdout: string): Verdict | null {
  let outer: any
  try { outer = JSON.parse(claudeStdout.trim()) } catch {
    const i = claudeStdout.indexOf("{")
    if (i < 0) return null
    try { outer = JSON.parse(claudeStdout.slice(i)) } catch { return null }
  }
  if (outer?.is_error) return null
  const text = typeof outer?.result === "string" ? outer.result : claudeStdout
  // result 里找 JSON（验收官可能包了 ```json 块）
  const m = text.match(/\{[\s\S]*\}/)
  if (!m) return null
  let v: any
  try { v = JSON.parse(m[0]) } catch { return null }
  if (v?.verdict !== "approved" && v?.verdict !== "rejected" && v?.verdict !== "unsure") return null
  return {
    verdict: v.verdict,
    reasons: Array.isArray(v.reasons) ? v.reasons.map(String).slice(0, 20) : [],
    rework_instruction: typeof v.rework_instruction === "string" ? v.rework_instruction : undefined,
  }
}

/** 数返工链深度：task → parent → parent…（防无限 loop 的关键数字） */
export function reworkDepth(ledger: WarroomLedger, task: TaskRow): number {
  let depth = 0
  let cur: TaskRow | null = task
  while (cur?.parent_task && depth < 10) {
    cur = ledger.getTask(cur.parent_task)
    depth++
  }
  return depth
}

/** rejected → 生成返工奏折（parent 链）。返回 null = 轮数用尽，该升级惊动主人了。 */
export function buildReworkTask(ledger: WarroomLedger, orig: TaskRow, verdict: Verdict): {
  title: string; body: string; target_kind: "tmux" | "resume"; target_ref: string
  engine: "claude" | "codex"; created_by: string; parent_task: string; filescope: string | null
} | null {
  if (reworkDepth(ledger, orig) >= MAX_REWORK_ROUNDS) return null
  const instruction = verdict.rework_instruction?.trim() || verdict.reasons.join("；")
  return {
    title: `返工: ${orig.title}`.slice(0, 80),
    body: `【返工奏折——上一轮验收未通过】\n原工单：${orig.body}\n\n验收官指出的问题：\n${verdict.reasons.map((r, i) => `${i + 1}. ${r}`).join("\n")}\n\n本轮要求：${instruction}\n完成后同样等待验收，不要声称完成没做过的事。`,
    target_kind: orig.target_kind as "tmux" | "resume",
    target_ref: orig.target_ref,
    engine: orig.engine as "claude" | "codex",
    created_by: "inspector",
    parent_task: orig.task_id,
    filescope: orig.filescope,
  }
}

/** warroom-desk 通知文本（注入中枢会话用） */
export function buildDeskNotice(task: TaskRow, verdict: Verdict | null, event: "approved" | "rejected_rework" | "escalate" | "failed"): string {
  const head = `【军机处呈报】奏折 ${task.task_id}「${task.title}」`
  const body = event === "approved"
    ? `验收通过，已朱批归档。理由：${verdict?.reasons.slice(0, 3).join("；") ?? "—"}。花费 $${task.cost_usd.toFixed(2)}。无需回应，用 warroom_tasks 可查详情。`
    : event === "rejected_rework"
      ? `验收未过（${verdict?.reasons.slice(0, 3).join("；") ?? "—"}），已自动生成返工奏折派回原窗口。无需回应。`
      : event === "escalate"
        ? `⚠️ 需要御裁：${verdict ? `验收官拿不准（${verdict.reasons.slice(0, 3).join("；")}）` : "返工轮数用尽仍未通过"}。用 warroom_tasks 查证据后 warroom_verdict 签字，或转呈主人。`
        : `❌ 执行失败（超时/崩溃），已标 failed。用 warroom_tasks 查残骸。`
  return `<channel source="warroom-desk" task_id="${task.task_id}">${head} ${body}</channel>`
}
