# H-B —— 洞 3：工具循环中间请求不记账不 gate

先读 `IMPL-COMMON.md`（同目录，纪律 + 跑道 + escape hatch），再读 `docs/minis对比/plan-补洞.md` §二 的「洞 3」一节——那是你的契约，本文只补契约没写的。

## 病根再说一遍（你要自己核实行号）

`ChatService.swift:53`：`internal var onToolCalls: (([ToolCallBlock]) -> Void)?`——签名不带 `TokenUsage`。而 `onComplete` 带（`:45`）。四个触发点都不传 usage：`:151`（非流式整包）/ `:646`（OpenAI 流式）/ `:1160`（Anthropic 流式）/ `:1270`（router 透传）。VM 消费点 `ConversationViewModel.swift:2797` 只拿 calls；最终 cost 只在 `onComplete` 提交一次（`:2655-2684` 附近）；回灌递归 `:2886-2893` 直接 `runStreamingTurn` 不过 `preCheckBudget`。

`preCheckBudget` 现在只在三处：主发送 `:2215` / 重生成 `:3449` / 编辑重发 `:3547`。

后果：8 轮工具 = 9 次模型请求，中间 8 次的 token **花了不记、也不 gate**。全局美元预算闸（`GlobalBudgetStore` + `BudgetCalculator.swift:60-78`）是活的、默认开的（首次默认 $10，`ef54388e`），但只看得见冰山一角。

顺带：`guard round < Self.maxToolRounds` 在工具执行**后**检查、round 从 0 起 → 实际执行 9 批才停，文案说 8 轮。

## 目标（冻结）

1. **tool-call 终止事件带 usage 回 VM**。签名改 `(([ToolCallBlock], TokenUsage?) -> Void)?` 还是另开一条通道——**你定**，但四个触发点都要传、VM 收到立即 commit 到 `GlobalBudgetStore`。`ChatService` 里已经有 `accumulatedInputTokens` 等累加器和 `finalUsage` 计算属性（`:48-57`），tool-call 路径应该能直接用它。
2. **回灌递归前重新 gate**。用**本轮**请求的 payload 估算（不复用首发那份 `pendingEstimatedCost`）。预算不足时的收尾：停止继续调工具、保留已有工具结果、给模型一次「基于现有结果总结」的机会（这次也过 gate，过不了就直接结束并显示原因）。
3. **off-by-one**：文案与实际批次数对齐。改判定位置或改文案，**二选一**，别两边都动。
4. ⧫ usage 缺失时（部分 provider 流式不给中间 usage）用该次请求的估算值扣——**宁可多扣**。

## 不冻结的（你的自由度）

- 签名怎么改、要不要引入中间类型、估算函数放哪。
- 「基于现有结果总结」那一轮的 prompt 措辞——现有 `finishAssistantTurn` 附近应该有类似的收尾路径，看看能不能复用。
- 测试组织。

## 影响面

- **改**：`ChatService.swift` 五处（签名 + 四触发点）、`ConversationViewModel.swift` 工具循环段（消费点 + 回灌递归 + 收尾）、`BudgetGateTests.swift`。
- **不碰**：ccBridge（它不走这条 provider 链）、`GlobalBudgetStore` 和 `BudgetCalculator` 本身（除非 commit 接口不够用，那就最小加一个方法并报告）、`BackupStore` / `SyncStore` / `ContentView`（H-A 的地盘）。
- ⚠️ `ConversationViewModel.swift` 是 5000+ 行的文件，H-A 不碰它但 **H-C（搁置）将来会碰摘要段**。你只动工具循环相关的行，别顺手整理。

## 测试（先红后绿）

- `BudgetGateTests` 扩：mock 一个 3 轮工具循环（现有 mock SSE 夹具应该能复用——`AskUserToolTests` / `RecallToolTests` 里有工具循环的测试骨架，看看怎么搭的），断言 commit 次数 = 4（3 中间 + 1 最终）、每次 usage 或估算值非零。**修前这个断言必然红**（现在只 commit 1 次）。
- 第 2 轮前把预算调到不足 → 断言循环停在第 2 轮、已有工具结果保留在节点上、收尾文案出现。
- off-by-one：断言 `maxToolRounds = N` 时实际发出的模型请求数与文案一致。
- 四个触发点各至少一个最小测试证明 usage 传到了 VM。

## 验收

- 上述测试修前红（贴输出）→ 修后绿（贴输出）。
- `xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS'` 全套绿（贴 `Executed N tests` 行）。
- `xcodebuild -scheme MemoryPalace -destination 'platform=macOS' build` 绿。
- commit 已 push 到你的分支。
- 报告 `docs/minis对比/reports/H-B-report.md` 按 IMPL-COMMON 格式。

## 一个反问（回答进报告）

你改完之后，一个 8 轮工具 turn 的**真实**账单和修前比会差多少倍？拿一个典型的 turn（比如 fs_read 三次 + 一次 search）估个数量级。这个数字粟粟会想知道。
