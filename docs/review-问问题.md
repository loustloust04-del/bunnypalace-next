# Review：问问题（ask_user 选项卡）

> Plan: [plan-问问题.md](plan-问问题.md) 14/14 ✅（2026-08-04）
> 实测方法：临时模拟器 + 本地 mock SSE server（OpenAI 兼容，round1 吐 ask_user tool_call / round2 echo tool_result）——零 API 消耗、echo 内容 = tool_result 到达的直接证据。

## 〇、二刀（08-04 上午，粟粟打回首版 Q/A 渲染）

首版把已答 Q/A 做成 assistant 消息内部的 segment 手搓灰卡——嵌在 assistant 容器里，
字体/内边距/右缘永远只能近似 user 气泡（「预览必须复用真实路径」的 UI 版翻车）。
二刀改**数据层复用**：`resumeUserQuestion` 把 Q/A 落成**真实 user MessageNode**
（parent=原 assistant），AI 接话进新 assistant 节点——渲染 100% 走正常用户气泡路径
（行头/操作行/气泡 chrome 全同，零自绘），历史重建天然带 Q/A（原 qaBlocks 特判撤掉，
换单行标记「〔我弹出选择卡问了用户，回答见下一条用户消息〕」防纯 ask 轮 assistant
空消息被过滤 → user+user 连排）。`AskUserAnswerCard`/`pairedResultText` 删除。
二刀 E2E 复验：答题全流程 + 下一轮历史结构
`user(问) → assistant(标记+前言) → user(Q/A) → assistant(接话) → user(新消息)` mock log 实证。

## 一、E2E 实证清单

| 路径 | 证据 |
|---|---|
| 工具下发 | mock log round1 `has_ask_tool: true` |
| 卡片弹出 | 截图 askuser_card_q1.png：题面+右上X+1/2 页码+编号选项+自由输入，官端对照一致 |
| 单选即答翻页 | 点选项 3 → 卡切到 2/2 多选题 |
| 多选+确定 | 火锅+寿司 → 「火锅、寿司」顿号拼接进 result |
| tool_result 回灌 | mock round2 收到完整双 Q/A 原文；模型 echo 渲染在聊天里 |
| Q/A 灰卡 | 已答 toolPair 渲染成右对齐灰泡（工具卡不出现） |
| X 跳过（方案 a） | 双题全「（用户没有选择，跳过了这个问题）」回灌，模型接话收尾 |
| 历史注入 | 下一轮请求 assistant 历史带「〔我用选择卡问过用户，用户的回答〕+Q/A 全文」（M3d 实证） |
| 记忆提取旁路 | 同模型无工具请求正常（不会递归弹卡） |
| 流式 text+tool_call 同轮 | 「好嘞！来选一选～」正常存 segment 渲染在 Q/A 卡前 |

## 二、边界情况（设计已覆盖但 GUI 未实测）

- **stop 按钮清 pending**（cancelAssistantTurn +1 行，guard 保护）——未实测按钮时序
- **切对话再切回重弹卡**：binding 按 conversationId 匹配。⚠️ 理论风险：切走时若 SwiftUI 对程序性 dismiss 也调 `set(false)` 会误触发 skip（resumeUserQuestion 会把题按跳过回灌）。iOS 上 sheet 全屏挡着切不了对话，实际暴露面是 **macOS 侧栏切对话**——粟粟日用如果撞到「切对话回来卡没了且多了条跳过回答」就是这条，修法=set 里加 conversationId 仍匹配才 skip
- **杀 app 丢 pending**：孤儿 toolUse → 渲染 EmptyView + 历史降级 `· ask_user`（代码路径简单，未实测）
- **自由输入提交**：与选项同走 submitAnswer，组件级同路（GUI 只测了选项路径）
- **同轮多个 ask_user call**：askItems 列表逻辑支持，mock 只测单 call 双题
- **round==maxToolRounds 时 ask**：暂停优先于轮次断头，答完仍发请求（模型再要工具才断）

## 三、与下一模块交互的风险

- **ccBridge 零影响**（toolInjection 对 ccBridge 返回 nil，CC 有自己的 AskUserQuestion）
- **cc-bridge/tools-schema.json 未重导出**：当前无 TS 消费方；下次跑 `scripts/export-tool-schemas.sh` 会带上 ask_user——hub 若接 Phase 1 需过滤（hub 侧无选择卡执行器）
- **toolHistorySummary 输出格式**多了 qaBlocks 段；唯一消费方 buildAPIMessages 拼 content，无 schema 依赖
- **模型滥调**：description 已写「不要用于寒暄/答案显而易见的问题」；真实模型（非 mock）的调用频率待日用观察，烦了可以在 description 加更硬的门槛或加设置开关

## 四、技术债务

- ~~气泡模式下 Q/A 卡在 assistant 泡内右对齐~~ 二刀后不存在：Q/A 是真实 user 节点，两种模式都是原生用户气泡
- **pending 状态机无单测**：PendingUserQuestion 持 SwiftData/manager 引用，VM 级测试太重——纯函数测 + GUI E2E 兜底
- **纯 ask 轮中断留尾**：答完后接话流被 cancel/杀 app → 树尾是空的新 assistant 节点（cancel 会写「已停止」，杀 app 留空壳被历史过滤）——与现有杀 app 中断流式同类暴露，不新增处理
- 测试期发现（非本刀）：新装 app 预算限额开关默认 on 且额度 0.00——真实新用户首发消息会被预算拦。**建议单独看一眼默认值**
- 测试期发现（非本刀）：**临时模拟器新装 app 会自动 loopback 连生产 hub 并收 replay**（`ccSeenReplyIds` 实证收了整批重投；fresh 库无 dedup 记录，靠 ccMessageId 查库兜底拦复读）。测试 sim 若 ack 了 pending 可能影响真机补投语义——二刀已在测试种子里把 `ccBridgeBaseURLOverride` 指死端口隔离；**以后测试 sim 一律带这个种子**
