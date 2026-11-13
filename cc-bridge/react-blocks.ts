/// 推送预览用：剥掉 ```react 表情块（plan-cc-reactions 2a）。
/// 规则和 app 端 MemoryPalace/Services/ChatReactionIntent.swift 的 strip 一致：
/// 只删「开头 ```react / 一行表情 / 收尾 ```（或结尾被截断的 0–2 个反引号）」，
/// 普通 React 代码块（内容多行、不是单个 emoji）原样留着。
const OPEN = "```react"
const segmenter = new Intl.Segmenter()

type Kind = "complete" | "cutClose" | "unclosed"
interface Found { start: number; end: number; kind: Kind }

function bare(line: string): string {
  return line.endsWith("\r") ? line.slice(0, -1) : line
}

function isOpenFence(line: string): boolean {
  const b = bare(line)
  if (!b.startsWith(OPEN)) return false
  for (const c of b.slice(OPEN.length)) if (c !== " " && c !== "\t") return false
  return true
}

function closeText(line: string): string {
  return bare(line).replace(/[ \t]+$/, "")
}

function firstGrapheme(s: string): string {
  for (const { segment } of segmenter.segment(s)) return segment
  return ""
}

function isEmoji(g: string): boolean {
  if (!g) return false
  if (/^\p{Emoji_Presentation}/u.test(g)) return true
  const cps = Array.from(g)
  return cps.length > 1 && /^\p{Emoji}/u.test(cps[0])
}

/// 内容行：一个 emoji，后面没字或空一格接提示
function isIntentLine(line: string): boolean {
  const g = firstGrapheme(line)
  if (!isEmoji(g)) return false
  const rest = line.slice(g.length)
  return rest === "" || rest.startsWith(" ")
}

function scan(lines: string[]): Found[] {
  const found: Found[] = []
  let i = 0
  const last = lines.length - 1
  while (i <= last) {
    if (!isOpenFence(lines[i])) { i++; continue }
    if (i >= last) { found.push({ start: i, end: i + 1, kind: "unclosed" }); break }
    const body = bare(lines[i + 1])
    if (i + 1 === last) {
      if (body === "" || isIntentLine(body)) found.push({ start: i, end: i + 2, kind: "unclosed" })
      break
    }
    const close = closeText(lines[i + 2])
    if (close === "```") {
      if (isIntentLine(body)) found.push({ start: i, end: i + 3, kind: "complete" })
      i += 3
      continue
    }
    if (i + 2 === last && (close === "" || close === "`" || close === "``")) {
      if (isIntentLine(body)) found.push({ start: i, end: i + 3, kind: "cutClose" })
      else if (body === "") found.push({ start: i, end: i + 3, kind: "unclosed" })
      break
    }
    i++
  }
  return found
}

export function stripReactBlocks(text: string): string {
  if (!text.includes(OPEN)) return text
  const lines = text.split("\n")
  const picked = scan(lines).filter(f => f.kind !== "unclosed")
  if (picked.length === 0) return text
  const drop = new Set<number>()
  for (const f of picked) for (let i = f.start; i < f.end; i++) drop.add(i)
  let out = lines.filter((_, i) => !drop.has(i)).join("\n")
  while (out.includes("\n\n\n")) out = out.replace(/\n\n\n/g, "\n\n")
  return out.trim()
}
