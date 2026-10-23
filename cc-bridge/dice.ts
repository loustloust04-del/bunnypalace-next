// 聊天卡片 · 骰子（与 app 端 DiceExpression / DiceTool 同规则，research-chat-cards §8.1 / §9；
// 输入契约见 plan-chat-cards-dice-tool v1.1 I1）
export function parseDice(expr: string): { count: number; sides: number; modifier: number } | null {
  const m = expr.replace(/ /g, "").match(/^(\d{0,2})d(\d{1,4})(?:([+-])(\d{1,4}))?$/i)
  if (!m) return null
  const count = m[1] === "" ? 1 : Number(m[1])
  const sides = Number(m[2])
  let modifier = 0
  if (m[3]) {
    const k = Number(m[4])
    if (k > 1000) return null
    modifier = m[3] === "-" ? -k : k
  }
  if (count < 1 || count > 20 || sides < 2 || sides > 1000) return null
  return { count, sides, modifier }
}

function cryptoRandom(n: number): number {
  const buf = new Uint32Array(1)
  const limit = Math.floor(0x1_0000_0000 / n) * n        // 拒绝采样，去掉取模偏差
  do { crypto.getRandomValues(buf) } while (buf[0] >= limit)
  return buf[0] % n
}

// 8 位：CC 看不到对话里已有的 id，靠长度把撞车概率压到可忽略（v1.1 I4）
function newId(): string {
  const buf = new Uint32Array(1)
  crypto.getRandomValues(buf)
  return "d-" + buf[0].toString(16).padStart(8, "0")
}

/// 与 app 的 ChatCard.blockText 一致：sortedKeys JSON；内容里有反引号时围栏加长
export function blockText(card: Record<string, unknown>): string {
  const sorted = (v: unknown): unknown =>
    Array.isArray(v) ? v.map(sorted)
      : v && typeof v === "object"
        ? Object.fromEntries(Object.keys(v as object).sort().map(k => [k, sorted((v as any)[k])]))
        : v
  const body = JSON.stringify(sorted(card))
  const longest = Math.max(0, ...(body.match(/`+/g) ?? []).map(s => s.length))
  const fence = "`".repeat(Math.max(3, longest + 1))
  return `${fence}card-dice\n${body}\n${fence}`
}

// 替对方掷已有的卡时沿用它的 id（终审 I2）；与 app DiceTool.cardId 同规则
const CARD_ID = /^d-[0-9A-Za-z_-]{1,32}$/

type Field<T> = { kind: "absent" } | { kind: "value"; value: T } | { kind: "invalid" }
const ABSENT = { kind: "absent" } as const
const INVALID = { kind: "invalid" } as const

function stringField(args: Record<string, unknown>, key: string): Field<string> {
  if (!(key in args) || args[key] === undefined) return ABSENT
  const raw = args[key]
  if (typeof raw !== "string") return INVALID
  const trimmed = raw.trim()
  return trimmed === "" ? ABSENT : { kind: "value", value: trimmed }
}

function stringsField(args: Record<string, unknown>, key: string): Field<string[]> {
  if (!(key in args) || args[key] === undefined) return ABSENT
  const raw = args[key]
  if (!Array.isArray(raw) || raw.some(s => typeof s !== "string")) return INVALID
  const out = (raw as string[]).map(s => s.trim()).filter(s => s !== "")
  return out.length === 0 ? ABSENT : { kind: "value", value: out }
}

export function rollDice(
  input: unknown,
  random: (n: number) => number = cryptoRandom,
): { ok: true; text: string } | { ok: false; error: string } {
  if (!input || typeof input !== "object" || Array.isArray(input)) return { ok: false, error: "参数不是合法 JSON 对象" }
  const args = input as Record<string, unknown>
  const titleField = stringField(args, "title")
  if (titleField.kind === "invalid") return { ok: false, error: "title 必须是字符串" }
  const title = titleField.kind === "value" ? titleField.value : ""
  const idField = stringField(args, "id")
  if (idField.kind === "invalid" || (idField.kind === "value" && !CARD_ID.test(idField.value))) {
    return { ok: false, error: "id 必须是 d- 开头的骰子卡 id（替对方掷已有的卡时才给）" }
  }
  const dice = stringField(args, "dice")
  const options = stringsField(args, "options")
  if (dice.kind === "invalid") return { ok: false, error: "dice 必须是字符串" }
  if (options.kind === "invalid") return { ok: false, error: "options 必须是字符串数组" }
  if (dice.kind === "value" && options.kind === "value") return { ok: false, error: "dice 和 options 只能给一个" }
  if (dice.kind === "absent" && options.kind === "absent") return { ok: false, error: "要给 dice 或 options" }

  const id = idField.kind === "value" ? idField.value : newId()
  let card: Record<string, unknown>
  let result: Record<string, unknown>
  let summary: string
  if (dice.kind === "value") {
    const expr = parseDice(dice.value)
    if (!expr) return { ok: false, error: `骰子表达式不合法：${dice.value}（格式 NdM±K，N 1–20，M 2–1000，K ≤ 1000）` }
    const rolls = Array.from({ length: expr.count }, () => random(expr.sides) + 1)
    const total = rolls.reduce((a, b) => a + b, 0) + expr.modifier
    result = { rolls, total }
    const parts = rolls.map(String).concat(expr.modifier === 0 ? [] : [expr.modifier > 0 ? `${expr.modifier}` : `(${expr.modifier})`])
    summary = `${dice.value} → ${parts.join(" + ")} = ${total}`
    card = { id, title, dice: dice.value, result }
  } else {
    const opts = (options as { kind: "value"; value: string[] }).value
    if (opts.length < 2) return { ok: false, error: "options 至少要 2 个" }
    const pick = random(opts.length)
    result = { pick }
    summary = `抽中：${opts[pick]}`
    card = { id, title, options: opts, result }
  }
  // 卡片块原文 + 空行 + 摘要：模型把第一段原样放进回复即可，不必解 JSON（终审 I1）
  return { ok: true, text: `${blockText(card)}\n\n${summary}` }
}
