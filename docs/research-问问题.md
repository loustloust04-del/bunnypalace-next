# Research：问问题（AskUserQuestion 式选项卡）

> 目标：官端同款——AI 发起选择题，底部弹卡片（问题 + 编号选项 + 自由输入 + X 关闭），
> 用户点选后以「Q: … A: …」灰底用户气泡落在对话里，AI 拿到答案继续说话。
> 支持多个问题 + 自由输入答案。回灌走标准 tool_result（粟粟已拍）。

## 一、现有地基（全部可复用，加工具本身很便宜）

| 环节 | 位置 | 现状 |
|---|---|---|
| 工具定义 | `Services/Tools/ToolDefinition.swift:6` | 一份 spec 双家渲染（openAI/anthropic），加工具 = 一个 `ToolDefinition` |
| 注册/门控 | `Services/Tools/ToolRegistry.swift:16` | 加一个 `Entry(definition:enabledIf:)` 就进注入链 |
| 注入 | `ConversationViewModel.swift:2094 toolInjection` | ccBridge 不下发（CC 有自己的 AskUserQuestion，不归我们管）；其余所有 provider 双家都发 ✅ 符合「所有 provider 都得能用」 |
| 工具循环 | `ConversationViewModel.swift:2457 onToolCalls` | 按 `call.name` 链式分发 → 执行 → 存 `.toolUse`/`.toolResult` segments → 递归下一轮（`toolTurns` 配对回灌，max 8 轮） |
| 双家回灌格式 | `ChatService.swift:349`（openAI `role:tool`）/ `:702`（anthropic `tool_result` block） | 已有，零改动 |
| 流式收集 | `ChatService.swift:510`（openAI [DONE] 时）/ `:979`（anthropic stop_reason==tool_use 时） | 双家都走 `onToolCalls` 回调，零改动；空名覆盖守卫已有（历史教训已修） |
| 渲染 | `Views/MessageSegmentsView.swift:66` | toolUse+toolResult 按 id 配对成 `ToolCallCardView`；**按 name 特判换渲染器即可**（citation 卡有先例） |

## 二、唯一的结构缺口：没有「暂停等用户」机制

现有 16 个工具全是**立即执行**：`onToolCalls` 里同步/异步跑完就递归下一轮。
`ask_user` 本质不同——必须**中断循环 → 渲染卡片 → 等用户点 → 再恢复循环**。

### 恢复所需状态（全在 `runStreamingTurn` 参数里，打包即可）

`payload / systemPrompt / model / providerManager / conversation / assistantNode(Id) / profile / preset / context / tools / toolTurns / round`，外加本轮 `calls` 和已执行完的其他工具 `results`。

### 建议做法：显式 pending 状态机（不用 continuation）

```
onToolCalls 里：
  1. 先照常执行本轮所有非 ask_user 工具，攒 results
  2. 发现 ask_user call → 把「calls + results + 恢复参数」存进
     vm.pendingUserQuestion（@Observable published struct）→ return（不递归）
  3. UI 看到 pendingUserQuestion 非 nil → 输入条位置换渲染问题卡
  4. 用户答完 → resumeUserQuestion(answers)：
     拼 ToolResultBlock + 存 segments → 清 pending → runStreamingTurn(round+1)
```

不用 CheckedContinuation 的原因：等待跨越任意长的用户交互，continuation 挂在 Task 里
取消路径极易漏 resume（记忆教训：TaskGroup+continuation 超时挂死）。显式状态 + 恢复函数
可测、可被 cancel 清理、跨对话切换语义清晰。

### 与现有 turn 语义的交互（都有现成钩子）

- **等待期间 `assistantTurnInFlight` 保持 true**：正常消息自动进 `pendingSends` 队列（`:1924` turn guard 已有），答完 turn 结束自动 drain——不打架
- **stop 按钮 / cancelAssistantTurn（`:1522`）**：加一行清 `pendingUserQuestion`；孤儿 toolUse segment 渲染有防御分支（`MessageSegmentsView.swift:80`），历史压平走 `toolHistorySummary` 不产生 user+user 连排 → 安全
- **切对话**：卡片只在 `selectedConversation.id == pending.conversationId` 时显示；pending 持有的引用不失效，切回来还能答
- **杀 app**：pending 内存态丢失，节点里留孤儿 toolUse → 渲染成折叠工具卡，下轮历史正常。可接受（官端同样丢）
- **API 安全性**：跨 turn 历史只回放 `(role, content)` 纯文本（`buildAPIMessages :1777`），tool 块不回放 → 弃答/中断不会造成悬空 tool_use 400

## 三、schema 设计（对齐官端 AskUserQuestion，砍到截图所见）

```json
ask_user {
  "questions": [           // 1-4 个
    {
      "question": "如果你现在可以立刻获得一种超能力，你选哪个?",
      "options": ["读取猫的想法", "任意时间暂停…", "…"],   // 2-6 个纯字符串
      "multiSelect": false   // 可选，默认 false
    }
  ]
}
```

- options 用纯字符串（截图里就是纯 label；官端的 header/description 在移动卡上不展示，不搬）
- 自由输入框**永远存在**（官端「Other」自动提供的等价物），不进 schema
- description 里写清使用时机（「需要用户在几个选项里做选择/收集偏好时使用，别用于寒暄」），防模型滥调
- 门控：无新设置项，`enabledIf { _ in true }`（受现有工具总开关 `sendToolsEnabled` 连坐，官端也没开关）

### tool_result 格式（纯文本，双家通吃）

```
Q: 如果你现在可以立刻获得一种超能力，你选哪个?
A: 每天多出一个不会被任何人打扰的平行时间口袋（4小时）
```

多问题多组 Q/A 空行分隔；自由输入直接当 A；跳过 → `A: （用户跳过了这个问题）`。

## 四、渲染（两处新 UI + 一处特判 + 一处历史）

1. **问题卡**（新组件 `AskUserQuestionCard`）：挂输入条三分支
   - iOS：`InputBarStack.content`（`InputBarStack.swift:46` 三分支加第四分支，pending 时替换 ChatInputBar——官端就是卡片占据输入区）
   - macOS：`CardFlowView.swift:593` 底栏同款分支
   - 样式照截图：圆角大卡、问题标题 + 右上 X、编号圆片 + 选项行 + 分隔线、底部铅笔 icon + 自由输入框；暖奶白系，编号圆片用 `Theme.mainBg`，选中态 `Theme.branchIndicator`
   - 多问题：同一张卡内分页（答完一题进下一题，顶部可加个 1/3 小标），全部答完才回灌一次 tool_result
2. **已答气泡**：`MessageSegmentsView` 的 toolPair 按 `name == ask_user` 特判 → 渲染成**右对齐灰底用户样式气泡**「Q: … A: …」（复用 user 气泡配色），不走 ToolCallCardView
3. **等待中**：pending 的 toolUse segment（无 result）渲染成 EmptyView（官端聊天流里也不显示）
4. **历史可见**：`toolHistorySummary`（`:1879`）现在只记工具名——ask_user 特判为把配对 result 的 Q/A 全文带进后续轮历史，否则模型下一轮就忘了用户答了什么

## 五、X 关闭的语义（需要拍板 ⧫）

- **方案 a（推荐）**：X → 回灌 `A: （用户没有选择，跳过了）` → 恢复循环让模型收尾说话。配对干净，模型知道发生了什么，体感接近官端（Claude Code 的 ESC 就是回「declined to answer」）
- 方案 b：X → 直接结束 turn（不再发请求）。省一轮请求，但模型下轮才从历史里发现被跳过

## 六、改动清单预估

| 文件 | 改动 |
|---|---|
| `Services/Tools/AskUserTool.swift`（新） | definition + 参数解析 + result 拼文（纯函数，可测） |
| `ToolRegistry.swift` | +1 Entry |
| `ConversationViewModel.swift` | pending 状态 struct + onToolCalls 分支 + resume/skip 函数 + cancel 清理 + toolHistorySummary 特判 |
| `Views/AskUserQuestionCard.swift`（新） | 问题卡（双端共用，注意平台 #if 教训） |
| `InputBarStack.swift` / `CardFlowView.swift` | 各 +1 分支挂卡 |
| `MessageSegmentsView.swift` | toolPair 特判 ask_user → Q/A 气泡 |
| 测试 | schema 双家渲染 golden / result 拼文 / pending→resume/skip/cancel 状态机 |

## 七、风险 / 边界

- **模型滥调**：description 约束 + 不加轮次特殊豁免（受 maxToolRounds=8 连坐，够用）
- **iOS 输入区雷区**：卡片进的是 InputBarStack 现成三分支容器（keyboardLayoutGuide 那套已稳定），不另凿层级；卡内自由输入聚焦时键盘避让走同一容器，风险最低路径
- **多 ask_user 并发调用**（一轮里模型发两个 ask_user call）：按 calls 顺序全部进同一张卡的分页队列，逐个答，各自回灌各自 id 的 result
- **DeepSeek 等 OpenAI 系**：带参工具流式拼接无空名坑（历史教训确认带参不踩）；照常走
- ccBridge 对话没有这个工具（上游 CC 自带 AskUserQuestion），不在本刀范围
