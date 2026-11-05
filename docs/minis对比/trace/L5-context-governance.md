# L5 —— Agent 上下文治理：压缩、预算、工具循环、失败降级

先读 `COMMON.md`（同目录）。本文件只写这条 lane 独有的东西。

## 这条轴问什么

**长对话 + 工具调用跑起来之后，怎么不让上下文炸掉、不让钱烧光、不让模型转圈。**

OM 的 `AIChatViewModel` 被拆成 20 个 `+扩展` 文件，其中一整组是治理机制：Compaction（压缩）、ContextPolicy（上下文策略）、RequestBudget（请求预算）、ToolPreflight（工具预检）、ConcurrentTools（并发工具）、Fallback（降级），外加一个独立的 `ToolLoopDetector.swift`。
**这组机制 MP 基本没有对等物，而 MP 正在往 agent 化走**（cc-bridge、MCP 工具、自主触发器、夜跑研究）。这条轴大概率是本批次最直接可采纳的一条。

## OM 侧读什么

- `src/ios/Agent/ToolLoopDetector.swift` —— **独立文件，说明它足够重要**。检测什么循环？怎么判定？触发后做什么？
- `src/ios/Agent/Chat/ContextPolicy.swift` —— 上下文策略的真相源，整个读。
- `src/ios/Agent/Chat/AIChatViewModel+Compaction.swift` —— 压缩：什么时候触发、压什么、压完怎么保证不丢关键信息、用户看得见吗。
- `+RequestBudget.swift` —— 预算：单位是什么（token？钱？轮数？）、超了怎么办、谁能改。
- `+ToolPreflight.swift` —— **工具预检**。这个概念 MP 没有，重点搞清它在防什么。
- `+ConcurrentTools.swift` —— 并发工具调用的编排与安全。
- `+Fallback.swift` —— 失败降级链。
- `+ToolDefinitions.swift` —— 工具定义怎么组织、怎么按需暴露（**注意 token 成本**：工具多了定义本身就吃上下文）。
- `Agent/Chat/FileMentionIndex.swift` + `+MentionMenu.swift` —— @ 提及索引（把文件塞进上下文的另一条路）。
- 顺带：`Agent/Chat/AIChatViewModel+SlashCommands.swift`、`+TitleGeneration.swift`（小但都是产品细节）。

## MP 侧对照坐标

- MP 的记忆模块：每轮异步提取原子事实，衰减引擎（hot/warm/cold），2000 token 预算。`Models/Memory.swift`、`Services/` 下的记忆管线。
- MP 的 preset 插槽：酒馆式 prompt 组装（`PromptSlot` + `SamplingParams`），`PromptAssembler`。**这是 MP 的上下文组装真相源**，先读懂它再谈治理。
- MP 的工具：MCP 接入 + 内置工具。`Models/ChatToolTypes.swift` 等。
- MP 的预算：`Models/GlobalBudgetStore.swift`（60 行，⚪ 60 天没动）。

## 车头给的额外情报（你查不到的，重要）

1. **MP 的记忆模块是带病资产，不是健康资产**。病历在 `docs/report-记忆现状-2026-07-07.md`（**请你读它**）：提取停摆 / 召回无阈值 / 条目不可编辑。
   → 做建议时不要默认「MP 已有记忆，只需增强」。它可能需要的是先修，或者被 OM 的机制替换掉一部分。
   → 另：这个模块的曾用名 AUDN 已弃用，**术语一律叫「记忆模块」**。
2. **MP 的工具海问题已有结论**：工具多了不该在路由层解决，该用 defer / meta-tools（tool_search / tool_inspect / tool_invoke，阈值 16）。这是粟粟已认可的方向。
   → 去看 OM 的 `+ToolDefinitions.swift` 是不是同一个思路，或者他们有更好的解法。
3. **MCP 工具可用性别绑 live 连接**：iOS 切后台连接会抖，如果 `enabledTools` 要求 `status == connected`，工具会时有时无 → 模型没工具可调。MP 的修法是缓存工具列表 + 调用时按需重连。
4. **MP 有 `ask_user` / 问问题机制**（模型主动提问，工具循环暂停、pending 状态机打包恢复参数、答完落成真实 user 节点）。这是 MP 比多数客户端**更完整**的一块，别把它漏进「我们没有」。
5. MP 有自主触发器（AUTONOMY Phase 0+1 已落地）、夜跑研究（headless CC 跑投研）——**MP 的 agent 化是真在跑的**，不是纸面计划。所以治理机制的紧迫性是真的。
6. 已知事故参照：MP 曾出现「8 轮空调用」（就是上面第 4 条的 tool_call 空名，属 L4 轴），以及 headless CC「同日已研究会停下问人」导致夜跑卡死（靠 prompt 加铁律修的）。
   → 这两个都是「循环 / 卡死」类，正好对照 `ToolLoopDetector` 判断它能不能兜住。

## 特别要回答的

1. **Compaction 对 MP 意味着什么？** MP 的对话是**树**（有分支），OM 的压缩机制假设线性历史吗？如果是，MP 的分支树会不会让压缩语义失效？（先查证 OM 会话结构，别猜）
2. `ToolPreflight` 到底在防什么——用一句话说清，然后判断 MP 现在有没有等价的防线、缺了会怎样。
3. MP 的记忆模块（提取原子事实 + 衰减）和 OM 的 Compaction + 持久 memory 是**两种不同哲学**。把这个分歧讲清楚：各自的代价、各自适合什么产品。MP 是陪伴型（记住这个人），OM 是干活型（记住这个项目）——这个定位差异会不会让 OM 的机制不适用？
4. 预算机制：MP 的 `GlobalBudgetStore` 60 行 60 天没动，基本是死的。OM 的 RequestBudget 值不值得搬？搬的话单位取什么？
5. **给一个优先级排序**：这条 lane 的发现里，MP 该先做哪一个。理由是什么。
