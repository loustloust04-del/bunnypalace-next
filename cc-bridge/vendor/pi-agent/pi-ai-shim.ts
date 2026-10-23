// pi-ai 0.80.x 把 0.79 时代的 `/base` 面拆成 root（类型+新 API）和 `/compat`（旧自由函数）。
// vendored agent 三件（0.79 era）期望旧 base 面——这里拼回去，vendor 文件只改 import 路径不改逻辑。
export { streamSimple, validateToolArguments } from "@earendil-works/pi-ai/compat";
export { EventStream } from "@earendil-works/pi-ai";
export type {
  AssistantMessage, AssistantMessageEvent, Context, ImageContent,
  Message, Model, SimpleStreamOptions, TextContent, ThinkingBudgets,
  Tool, ToolResultMessage, Transport,
} from "@earendil-works/pi-ai";
