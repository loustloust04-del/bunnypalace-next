// CC 里的助手用花园的记忆（粟粟 11-14「把每个记忆都暴露接口…无论是对 api 还是对 cc」）。
//
// 工具和 app 里走 API 的助手是同一套：同名、同参数、同一段说明——定义不在这里手抄，
// `memory-tools.json` 是从 app 的工具金样（MemoryPalaceTests/Fixtures/tools-schema-golden.json）里摘出来的，
// 改了 app 那边的工具定义就跑 `bun run memory-tools.ts` 重新生成（memory-tools.test.ts 对着金样查有没有漂）。
// 这里只加三样：chat_id（定楼层）、开头一句「这是花园的记忆」、个别工具在 CC 这头的补充说明。
// 文件工具八件都在：读 / 写 memory/（写文件 = 写那种记忆）和 .prompt/（这一层的 Prompt，如助手设定）；别的文件库内容 app 那头会拒。
//
// 一次调用：CC → 这里 POST hub `/memory/cmd` → hub 发 `memory_cmd` 帧给 app → app（MemoryCCBridge.swift）
// 在那场对话所在的楼层跑同一个工具、过同一个权限闸 → `memory_result` 原路回来。
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
// 静态 import：编进 Mac App 的那份 mcp-server（bun build --compile）身边没有这个文件，得打进二进制里
import appToolsJson from "./memory-tools.json"

/// 和 MemoryPalace/Services/MemoryCCBridge.swift 的 toolNames 一致
export const MEMORY_TOOL_NAMES = [
  "recall", "memory_card", "remember", "edit_memory", "forget_memory", "pending_notes", "fs_list", "fs_read", "fs_search",
  "fs_write", "fs_append", "fs_edit", "fs_rename", "fs_delete",
] as const

export interface AppTool {
  name: string
  description: string
  input_schema: { type: "object"; properties: Record<string, unknown>; required: string[] }
}

const TOOLS_FILE = join(import.meta.dir, "memory-tools.json")
export const GOLDEN_FILE = join(import.meta.dir, "..", "MemoryPalaceTests", "Fixtures", "tools-schema-golden.json")

/// 从 app 的金样里摘这几个工具（Anthropic 那一份：name / description / input_schema）
export function toolsFromGolden(goldenPath = GOLDEN_FILE): AppTool[] {
  const golden = JSON.parse(readFileSync(goldenPath, "utf8")).anthropic as Record<string, AppTool>
  return MEMORY_TOOL_NAMES.map((name) => {
    const tool = golden[name]
    if (!tool) throw new Error(`金样里没有 ${name}`)
    return { name: tool.name, description: tool.description, input_schema: tool.input_schema }
  })
}

export function loadAppTools(): AppTool[] {
  return appToolsJson as AppTool[]
}

/// 每个工具说明的第一句
export const MEMORY_PREFACE = "【花园记忆】这是对方在记忆花园 app 里的长期记忆，和 app 里走 API 聊天的你用的是同一套；不是你在 CC 这边自己的 memory 文件，也不是这台电脑上的文件。chat_id 必填（<channel> 里那个）：读写的是那场对话所在楼层的记忆。花园 app 没开着、没连上时会直接告诉你没做成。"

const FILES_NOTE = "在 CC 这边文件工具只碰两处：memory/ 下的记忆文件，和 .prompt/ 下这一层的 Prompt（助手设定这些）；花园文件库里别的文件碰不到。memory/self/ 是你自己记的（目录在 memory/self/INDEX.md），memory/cards/ 是记忆条目，memory/pending/ 是待续，memory/timeline/、memory/windows/、memory/sessions/ 是时间轴、窗口总结、段摘要（只读），memory/wiki/ 是 wiki 页。"
const WRITE_NOTE = FILES_NOTE + "写的每一笔对方都看得到是你从 CC 动的；对方可能要先在 app 里那场对话里点允许，所以有时要等一两分钟才回。对方让你把别处的东西（比如 CLAUDE.md）搬进来时：讲你是谁、怎么说话的进 .prompt/fields/characterDescription.txt（助手设定）这类楼层字段，先 fs_read 看现在写了什么再接着写，不要整份盖掉；一条条的事实进记忆条目或你自己的记忆，一条只说一件事。"

/// 个别工具在 CC 这头多说的一段（放在 app 原说明前面）
export const MEMORY_NOTES: Partial<Record<(typeof MEMORY_TOOL_NAMES)[number], string>> = {
  memory_card: "每一笔对方都能在记忆日志里看到是你从 CC 动的，能撤回；对方可能要先在 app 里那场对话里点允许，所以这个工具有时要等一两分钟才回。对方让你把别处的东西搬进来时：一条只说一件事，写成不看上下文也读得懂的一句完整的话，一条一条 add，不要整段贴；先搜一下有没有（recall，或 fs_search 搜关键词、看 memory/cards/ 下的命中），已经有的不重复加。",
  remember: "这是你自己的记忆，写了以后 app 里的你每次聊天都带着目录。对方让你把别处的东西搬进来 = 对方让你记的，asked_by_user 填 true；一条只记一件事，不要把一大段原样贴进来。",
  fs_list: FILES_NOTE,
  fs_read: FILES_NOTE,
  fs_search: FILES_NOTE,
  fs_write: WRITE_NOTE,
  fs_append: WRITE_NOTE,
  fs_edit: WRITE_NOTE,
  fs_rename: FILES_NOTE,
  fs_delete: FILES_NOTE,
}

const CHAT_ID_PROPERTY = { type: "string", description: "<channel> 里的 chat_id：决定读写哪一层楼的记忆。必填" }

export interface McpTool {
  name: string
  description: string
  inputSchema: { type: "object"; properties: Record<string, unknown>; required: string[] }
}

/// 发给 CC 的工具清单：app 的定义 + chat_id + 开头那几句
export function memoryMcpTools(appTools: AppTool[] = loadAppTools()): McpTool[] {
  return appTools.map((tool) => ({
    name: tool.name,
    description: [MEMORY_PREFACE, MEMORY_NOTES[tool.name as (typeof MEMORY_TOOL_NAMES)[number]], tool.description].filter(Boolean).join("\n"),
    inputSchema: {
      type: "object",
      properties: { chat_id: CHAT_ID_PROPERTY, ...tool.input_schema.properties },
      required: ["chat_id", ...tool.input_schema.required],
    },
  }))
}

export function isMemoryTool(name: string): boolean {
  return (MEMORY_TOOL_NAMES as readonly string[]).includes(name)
}

/// hub 等 app 回包的时限：动记忆条目可能要等对方在审批卡上点（app 那头比这个早 10 秒收口，见 MemoryCCBridge.transportMargin）
export const MEMORY_TIMEOUT_MS = 120_000
/// 回给 CC 的正文上限（fs_list / fs_search 在记忆多的楼层会很长）
export const MEMORY_RESULT_LIMIT = 50_000

export interface McpToolResult {
  content: { type: "text"; text: string }[]
  isError?: boolean
}

/// 调一次：成功回 app 的原话；没做成（hub 连不上 / app 没连着 / 超时 / 被拒）回一句明白话 + isError，不装成功
export async function callMemoryTool(httpBase: string, name: string, args: Record<string, unknown> | undefined,
                                     fetchImpl: typeof fetch = fetch): Promise<McpToolResult> {
  const { chat_id, ...input } = args ?? {}
  const fail = (text: string): McpToolResult => ({ content: [{ type: "text", text }], isError: true })
  let result: { ok?: boolean; result?: unknown; error?: unknown }
  let resp: Response
  try {
    resp = await fetchImpl(`${httpBase}/memory/cmd`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id, tool: name, input, timeout_ms: MEMORY_TIMEOUT_MS }),
    })
  } catch (e) {
    return fail(`连不上花园的 hub（${(e as Error)?.message ?? e}），这次没做成，不要当成已经读到 / 记下了。`)
  }
  try {
    result = await resp.json() as typeof result
  } catch {
    // 还没重启的旧 hub 不认识 /memory/cmd，回的是 426 纯文本
    return fail(`hub 回的不是能认的格式（HTTP ${resp.status}）：多半是 hub 还没重启到带花园记忆的版本。这次没做成，不要当成已经读到 / 记下了。`)
  }
  if (result.ok === true && typeof result.result === "string") {
    const text = result.result.length > MEMORY_RESULT_LIMIT
      ? result.result.slice(0, MEMORY_RESULT_LIMIT) + `\n…（太长，只给了前 ${MEMORY_RESULT_LIMIT} 字，共 ${result.result.length} 字；换更具体的词搜，或直接读某一个文件）`
      : result.result
    return { content: [{ type: "text", text }] }
  }
  if (result.error === "timeout") {
    return fail(`花园 app 在 ${MEMORY_TIMEOUT_MS / 1000} 秒内没回话（app 可能在后台、版本还不认识这个工具，或者对方没在审批卡上点）。这一笔很可能没做成；要确认先用 recall / fs_search 查一下，再决定要不要重试。`)
  }
  const why = typeof result.result === "string" ? result.result : typeof result.error === "string" ? result.error : "未知错误"
  return fail(why)
}

// `bun run memory-tools.ts`：从金样重新生成 memory-tools.json
if (import.meta.main) {
  if (!existsSync(GOLDEN_FILE)) throw new Error(`找不到金样 ${GOLDEN_FILE}（要在仓库里跑）`)
  writeFileSync(TOOLS_FILE, JSON.stringify(toolsFromGolden(), null, 2) + "\n")
  console.log(`memory-tools.json ← ${MEMORY_TOOL_NAMES.length} 个工具`)
}
