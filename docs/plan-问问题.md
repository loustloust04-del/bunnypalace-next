# Plan：问问题（ask_user 选项卡）

> Research: [research-问问题.md](research-问问题.md)（已确认）
> 粟粟已拍：①卡片 = 底部小 sheet，**复用仿官端思考链 ThinkingSheet 的形态**（`.sheet` + detents + 居中头 + GlassBackButton，不自己画 chrome）②多问题 = 同卡翻页 ③X 关闭 = 方案 a（回灌「用户跳过了」让模型收尾）

## 端到端流程

```
模型调 ask_user(questions:[…])
  → onToolCalls：其他工具照常执行攒 results；ask_user 存 pendingUserQuestion，不递归，return
  → CardFlowView 看到 pending 且对话匹配 → 弹 AskUserQuestionSheet（ThinkingSheet 同款壳）
  → 用户逐题作答（点选项/多选确认/自由输入），翻页；X 或拖拽关闭 = 剩余题跳过
  → vm.finishUserQuestion：拼 Q/A 文本 result → 存 .toolResult segment → 清 pending
     → runStreamingTurn(toolTurns+本轮, round+1) 恢复循环，模型接着说话
  → 聊天流里该 toolPair 渲染成右对齐灰底「Q: … A: …」卡（官端已答样式）
```

## 模块拆解

### M1 工具层 `Services/Tools/AskUserTool.swift`（新，纯函数可测）

- `toolName = "ask_user"`；`definition: ToolDefinition`：
  ```
  questions: array(1-4) of {
    question: string（必填）,
    options: array of string（2-6，必填）,
    multiSelect: bool（可选，默认 false）
  }
  ```
  description 写清使用时机（需要用户在选项里做选择/收集偏好时；不要用于寒暄闲聊）+ 用户永远可以自由输入替代选项
- `struct ParsedQuestion { question; options; multiSelect }`
- `parse(inputJSON:) -> [ParsedQuestion]?`：解析失败/空题/选项<2 → nil（调用侧回 isError result，模型自纠）
- `resultText(questions:, answers: [String?]) -> String`：`Q: …\nA: …` 成对，多题空行分隔；answer nil → `A: （用户没有选择，跳过了这个问题）`
- `historyLine(inputJSON:, resultText:) -> String`：给 toolHistorySummary 用——返回 resultText 全文（Q/A 必须进后续轮历史，不然模型下轮失忆）

### M2 注册 `ToolRegistry.swift`

- +1 Entry：`enabledIf { _ in true }`（无新设置项，受 sendToolsEnabled 总开关连坐；双家都发）

### M3 循环层 `ConversationViewModel.swift`

- `struct PendingUserQuestion`（@MainActor 内存态，不落盘）：
  - `conversationId` + 本轮 `calls`/已执行完的 `otherResults` + ask call 的 `[（call, [ParsedQuestion]）]`
  - 恢复参数打包：payload/systemPrompt/model/providerManager/conversation/assistantNode(Id)/profile/preset/context/tools/toolTurns/round（即 runStreamingTurn 全参）
- published `var pendingUserQuestion: PendingUserQuestion?`
- onToolCalls 分发链 +1 分支（在 MCP fallback 之前）：
  - parse 失败 → 立即回 isError result（照常循环，不暂停）
  - parse 成功 → 存 `.toolUse` segment，ask call 攒进 pending 列表；for 循环结束后若有 ask → 存 pending + save + **return（不递归）**
  - 同轮多个 ask_user call：全进同一 pending，sheet 里题目顺排，各自回灌各自 id
- `finishUserQuestion(answers:)`：拼 result → `.toolResult` segments + ToolResultBlock → save → 清 pending → runStreamingTurn(round+1)
- `skipRemainingUserQuestion()`：未答题全 nil，走同一 finish 路径（已答的保留——答了 1/3 题后 X，前 1 题答案照发）
- `cancelAssistantTurn`（:1522）：+1 行清 pending（stop 按钮期间挂着问题卡的情形）
- `toolHistorySummary`（:1879）：name == ask_user → 找配对 toolResult，用 `AskUserTool.historyLine` 带全文；找不到配对（杀 app 孤儿）→ 现状 `· ask_user`
- 覆盖面：regenerate/editAndResend 都走 runStreamingTurn 单入口，分支自动生效，无需另接

### M4 UI `Views/AskUserQuestionSheet.swift`（新，双端）

壳照抄 ThinkingSheet（`ThinkingSheet.swift:61`）：
- iOS `.presentationDetents([.fraction(0.6), .large])`；macOS `frame(minWidth: 480, minHeight: 420)`；背景 `Theme.mainBg`
- 头部：左 X（iOS GlassBackButton / macOS 圆钮，ThinkingSheet 同款）；多题时居中小灰字 `1 / 3`
- 正文（对照截图）：
  - 问题文本大字左对齐（size 17 semibold，textPrimary）
  - 选项行：编号圆片（`Theme.accent` 底 + textPrimary 数字）+ label，行间细分隔线；单选点了即答并翻下一题
  - multiSelect：行尾勾选态（`Theme.branchIndicator`）+ 底部「确定」钮
  - 底部自由输入：铅笔 icon + TextField「输入你的答案…」，提交即答该题
- 交互：最后一题答完 → `finishUserQuestion`（sheet 自动收）；X / 拖拽关闭 → `skipRemainingUserQuestion`
- 挂载：CardFlowView 现有 sheet 群（:1140 附近）+1 个，绑定派生 binding（pending 非 nil 且 `pending.conversationId == selectedConversation?.id`），`onDismiss` 里 skip-if-still-pending（正常答完先清 pending 再收，不会误 skip）

### M5 已答渲染 `MessageSegmentsView.swift`

- `items` 配对处按 name 特判：`toolPair(name: ask_user)` → 新 `AskUserAnswerCard`（灰底圆角右对齐，逐行渲 Q/A 文本，Q 行 textMuted 小字、A 行 textPrimary；复用 user 气泡灰 `Theme.accent` 系）
- resultText == nil（等待中/孤儿）→ EmptyView（官端聊天流等待期也不显示）
- 形态差异说明：文章模式 = 官端一致的独立右侧灰卡；气泡模式 segmented 整体在 assistant 泡内（`ChatBubbleStyle.swift:337`），灰卡在泡内右对齐——不为此重构气泡包裹

### M6 测试 `MemoryPalaceTests/AskUserToolTests.swift`（新）

- parse：合法单题/多题/multiSelect 默认 false/缺 question/选项 1 个/非 JSON → nil
- resultText：单题/多题/含跳过/自由输入
- historyLine：有 result 带全文
- schema 渲染：双家 render 后含 ask_user 且形状正确（openAI function 包壳 / anthropic input_schema）

### M7 收口

- `xcodegen generate && xcodebuild`（macOS + iOS 双端）+ 全测试绿
- 模拟器 GUI 实测：让模型真调一次 ask_user（提示词逼一下）→ 弹卡 → 点选 → Q/A 气泡 → 模型接话；X 跳过路径一次
- commit push + NOW.md

## 边界回查（research §二已核，plan 落点）

| 边界 | 落点 |
|---|---|
| 等待期用户发消息 | turn guard 已排队（:1924），答完自动 drain，不动 |
| stop 按钮 | cancelAssistantTurn 清 pending（M3） |
| 切对话 | sheet binding 带 conversationId 匹配，切走卡收、切回再弹 |
| 杀 app | pending 丢，孤儿 toolUse → M5 渲 EmptyView，历史走现状 `· ask_user` |
| maxToolRounds | 不豁免，8 轮连坐够用 |
| 弃答 API 安全 | 跨 turn 不回放 tool 块（research §二），方案 a 本轮配对也完整 |

## Todo Checklist

- [x] M1 AskUserTool.swift：definition + parse + resultText + pairedResultText ✅
- [x] M6a 纯函数测试先行（parse/resultText/pairedResultText/双家 schema）7 测绿 ✅
- [x] M2 ToolRegistry +1 Entry（golden fixture + 中性导出 count 同步 17）✅
- [x] M3a PendingUserQuestion struct + published 字段 ✅
- [x] M3b onToolCalls ask_user 分支（含 parse 失败即回 error、多 call 同 pending）✅
- [x] M3c resumeUserQuestion 统一出口（答完/跳过同路）+ cancel/楼层切换清理 ✅
- [x] M3d toolHistorySummary ask_user 特判（〔我用选择卡问过用户〕段）✅
- [x] M4a AskUserQuestionSheet 壳 + 单选题渲染 ✅
- [x] M4b 多题翻页 + multiSelect 确认 + 自由输入 ✅
- [x] M4c CardFlowView 挂 sheet（派生 binding + set(false) skip 语义）✅
- [x] M5 MessageSegmentsView 特判 + AskUserAnswerCard ✅
- [x] M7a 双端 build 绿 + 574 测全绿 ✅
- [x] M7b 临时模拟器 GUI E2E（mock SSE server 零 API 消耗）：答题路径（单选翻页+多选确定→Q/A 灰卡→模型接话 echo 实证 tool_result 原文到达）+ X 跳过路径（方案 a 实证）+ 历史注入实证（下轮请求 assistant 历史带 Q/A 全文）✅
- [x] M7c commit push + NOW.md ✅

—— 全部完成（2026-08-04），复盘见 [review-问问题.md](review-问问题.md)
