# H-B 报告

洞 3 · 工具循环中间请求不记账不 gate。两席接力：codex gpt-5.6-sol 写到 WIP 撞配额墙，opus5 接手审 + 补 + 收口。

## 状态：DONE

## 改了什么（文件:行号 + 一句话）

### `MemoryPalace/Services/ChatService.swift`

| 行 | 改动 |
|---|---|
| `123-129` | `emitPaced` 在吐块**之前**把 `result.usage` 灌进 `accumulated*` 累加器并置 `gotUsage`——非流式整包路径的 `finalUsage` 从此在 `onToolCalls` 触发时就是准的（原来只在 `onComplete` 参数里传，工具终止路径拿不到）。 |
| `1196-1198` | 新增 `ToolCallTerminalState`（每次请求一个），标记本次请求是否已用 tool-call 收尾。 |
| `1248` | `ProviderRouter.sendStreaming` 的 `onToolCalls` 签名改 `(([ToolCallBlock], TokenUsage?) -> Void)?`。 |
| `1264, 1281-1291` | ChatGPT OAuth 分支：tool-call 回调包一层，置 `didEmitToolCalls` + 带上 `oauthProvider.finalUsage`；`onComplete` 加同一个门——OAuth provider 是 `response.completed` 发 tool_calls、随后 `[DONE]` **还会再发一次** `onComplete`，不挡住就同一次请求记两遍账（见「顺手发现」）。 |
| `1331-1335, 1350` | 非 OAuth 分支：`forwardedToolCalls` 适配器读 `chatProvider.finalUsage` 交给上层。**三条触发点（非流式整包 `:158` / OpenAI 流式 `:653` / Anthropic 流式 `:1167`）共用这一个适配器**，`BaseChatProvider.onToolCalls` 的内部签名（`:53`）不动。 |

### `MemoryPalace/ViewModels/ConversationViewModel.swift`

| 行 | 改动 |
|---|---|
| `2414-2416` | 三个常量：收尾 maxTokens 512 / 停止文案 / 收尾指令文案。 |
| `2706-2711` | `toolTurnsEstimateText`：把已有 tool_call + tool_result 摊成文本，给估算器算 token。 |
| `2713-2747` | `preCheckToolRequestBudget`：用**本轮**payload（历史 + 已累积工具回合 + tools schema）过 `BudgetCalculator.estimateCost` → `budgetGate`；放行时把估算写进 `pendingEstimatedCost`（缺 usage 时的扣费兜底），拦下时写 `budgetBlockedMessage`。 |
| `2749-2761` | `addingBudgetSummaryInstruction`：把「不要再调用工具、基于已有结果总结」追加到最后一条 tool_result 尾部。 |
| `2763-2833` | `continueToolLoop`：**回灌递归的唯一入口**。过 gate → `runStreamingTurn`；不过 → 节点追加停止文案 → 组装收尾请求（`tools: nil`、maxTokens 512、带总结指令）→ **收尾也过一次 gate** → 过了就发，没过就直接 `finishAssistantTurn`。 |
| `2850, 2945-2952` | `runStreamingTurn` 加 `isBudgetSummary` 旗标；收尾请求若还回 tool_call，落地一句话直接结束，不再递归。 |
| `2932, 2936` | `onToolCalls` 闭包收 `(calls, usage)`，**进循环体第一件事**就 `commitBudgetSpend(..., recordTurn: false)`——有 usage 按精算、没 usage 落 `pendingEstimatedCost` 估算（⧫ 宁可多扣）。 |
| `2953-2963` | off-by-one：`guard round < maxToolRounds` 从工具执行**后**挪到执行**前**（原来在 `:3138` 附近）。 |
| `1634-1642, 3141-3147` | 两个回灌点（`resumeUserQuestion` 答完问题续跑 / 正常工具轮递归）从 `runStreamingTurn` 改走 `continueToolLoop`——两条路都过 gate。 |

### `MemoryPalaceTests/BudgetGateTests.swift`

从 6 条纯 gate 单测扩到 17 条：新增 `ToolLoopHTTPServer`（本地 `NWListener`，逐请求可编排响应 + 记录**每次请求发出瞬间**的 `GlobalBudgetStore.spentUSD`）、`ToolLoopFixture`（内存 ModelContainer + 真 VM + 真 ProviderRouter），以及 11 条工具循环测试。

## 复现→修→验证

### 红灯（生产代码未改，commit `7ea1e1f0`）

命令：

```text
xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/BudgetGateTests
```

原始失败输出（节选）：

```text
BudgetGateTests.swift:387: error: ... testNonStreamToolTerminationRetainsUsage ... XCTAssertEqual failed: ("nil") is not equal to ("Optional(...TokenUsage(inputTokens: 31, outputTokens: 7...))")
BudgetGateTests.swift:470: error: ... testThreeToolRoundsCommitEveryRequestUsingEstimateWhenUsageMissing ... XCTAssertGreaterThan failed: ("0.0") is not greater than ("0.0") - 第 1 次工具请求缺 usage 也要用估算值扣费
BudgetGateTests.swift:471: error: ... XCTAssertGreaterThan failed: ("0.0") is not greater than ("0.0") - 第 2 次工具请求要独立扣费
BudgetGateTests.swift:472: error: ... XCTAssertGreaterThan failed: ("0.0") is not greater than ("0.0") - 第 3 次工具请求要独立扣费
BudgetGateTests.swift:507: error: ... testBudgetBlockBeforeSecondToolRoundPreservesResultsAndRunsGatedSummary ... XCTAssertTrue failed - 收尾请求要明确要求基于已有结果回答
BudgetGateTests.swift:510: error: ... XCTAssertTrue failed - 节点上要有可见的停止原因
BudgetGateTests.swift:537: error: ... testToolRoundLimitExecutesEightBatchesAndUsesNinthRequestOnlyToDetectLimit ... XCTAssertEqual failed: ("9") is not equal to ("8") - 文案说 8 轮就只能真正执行 8 批工具
Executed 13 tests, with 8 failures (0 unexpected) in 1.696 (1.716) seconds
** TEST FAILED **
```

那 8 条红灯覆盖三件事：中间轮不记账（3 条）/ 预算不足没有收尾语义（2 条）/ off-by-one 多执行一批（1 条）/ 非流式路径 usage 在工具终止时丢失（2 条）。

### 绿灯（WIP 实现 + 本席补的两条守卫，commit `c8023c91`）

```text
Test Suite 'BudgetGateTests' passed at 2026-09-02 09:49:53.
	 Executed 17 tests, with 0 failures (0 unexpected) in 1.384 (1.389) seconds
Test Suite 'MemoryPalaceTests.xctest' passed
	 Executed 17 tests, with 0 failures (0 unexpected) in 1.384 (1.390) seconds
** TEST SUCCEEDED **
```

（中间态：只有 WIP 实现、未加本席两条守卫时，同命令 `Executed 15 tests, with 0 failures (0 unexpected) in 1.895 (1.899) seconds` / `** TEST SUCCEEDED **`——即前一席的实现方向本身是通的，它只是没来得及跑。）

测试名（17 条，后 11 条是本洞新增）：

**纯 gate 判定（原有 6 条，未动）**
`testFreshInstallUsesDefaultBudgetInsteadOfBlocking` · `testNeverFundedStillBlocksPastDefaultBudget` · `testUserSetBudgetOverridesDefault` · `testExplicitZeroBudgetStillBlocks` · `testFundedBudgetStillGates` · `testDisabledSwitchAlwaysPasses`

**四个触发点各一条：工具终止时 usage 在不在**
- `testNonStreamToolTerminationRetainsUsage`（非流式整包 `emitPaced`）
- `testOpenAIStreamToolTerminationRetainsUsage`（OpenAI 流式 `[DONE]`）
- `testAnthropicStreamToolTerminationRetainsUsage`（Anthropic `message_stop` + `message_delta` usage 合并）
- `testChatGPTOAuthRouterTerminationRetainsUsage`（OAuth `response.completed`）

**router 适配层：usage 真交到 VM 手里**
- `testOpenAIRouterForwardsToolUsageToCallback`（非 OAuth 分支，锁 `forwardedToolCalls`；三条触发点共用它）
- `testChatGPTOAuthRouterForwardsToolUsageOnceAndSuppressesTrailingComplete`（OAuth 分支 + 断言 `completeCount == 0`，锁住重复记账）

**端到端工具循环记账与 gate**
- `testThreeToolRoundsCommitEveryRequestUsingEstimateWhenUsageMissing`（3 中间 + 1 最终 = 4 次请求，逐次扣费严格递增）
- `testMissingUsageRoundChargesEstimateNotPreviousRoundUsage`（第 0 轮有 usage 按精算 $0.00035、第 1 轮缺 usage 按本轮估算 >$0.041）
- `testBudgetBlockBeforeSecondToolRoundPreservesResultsAndRunsGatedSummary`（停在第 2 轮前、工具结果保留、收尾请求无 tools + max_tokens=512 + 带指令、节点有停止原因）
- `testBudgetBlockEndsDirectlyWhenSummaryAlsoCannotFit`（收尾也过不了 gate → 只发 1 次请求就结束）
- `testToolRoundLimitExecutesEightBatchesAndUsesNinthRequestOnlyToDetectLimit`（9 次请求 / 8 批工具 / 文案说 8）

## 全套测试 + build 结果（原始尾部输出）

### 全套测试

```text
xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS'
```

```text
/…/MemoryPalaceTests/RunCommandToolTests.swift:42: error: -[MemoryPalaceTests.RunCommandToolTests testTimeoutKillsWholeTree] : XCTAssertLessThan failed: ("9.085480093955994") is not less than ("4.0") - 超时后应 ~1.5s 内返回
Test Case '-[MemoryPalaceTests.RunCommandToolTests testTimeoutKillsWholeTree]' failed (9.616 seconds).
/…/MemoryPalaceTests/RunCommandToolTests.swift:93: error: -[MemoryPalaceTests.RunCommandToolTests testUnboundedOutputStaysBounded] : XCTAssertLessThan failed: ("10.584735989570618") is not less than ("6.0")
Test Case '-[MemoryPalaceTests.RunCommandToolTests testUnboundedOutputStaysBounded]' failed (10.659 seconds).
	 Executed 836 tests, with 2 failures (0 unexpected) in 113.282 (113.578) seconds
** TEST FAILED **
```

本 lane 的 suite 在同一次全套里：

```text
Test Suite 'BudgetGateTests' passed at 2026-09-02 09:32:47.507.
	 Executed 17 tests, with 0 failures (0 unexpected) in 1.366 (1.375) seconds
```

**那 2 条失败不是本 lane 的。** 派单时车头已预告这台机器上 `RunCommandToolTests` 有 2 条墙钟 flake（H-A 也撞过）。三条独立证据：

1. 断言全是**墙钟阈值**（`9.08 < 4.0` / `10.58 < 6.0`），不是行为断言。
2. 被测对象 `RunCommandTool` 跟本 lane 改的三处（`ChatService` 的 router 适配 / `ConversationViewModel` 工具循环段 / `BudgetGateTests`）没有调用关系。
3. 单独重跑（机器空闲、没有 build 排在后面）的结果贴在下面。

```text
xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/RunCommandToolTests
```

```text
RunCommandToolTests.swift:42: error: ... testTimeoutKillsWholeTree : XCTAssertLessThan failed: ("9.683278918266296") is not less than ("4.0") - 超时后应 ~1.5s 内返回
RunCommandToolTests.swift:93: error: ... testUnboundedOutputStaysBounded : XCTAssertLessThan failed: ("10.972141981124878") is not less than ("6.0")
	 Executed 23 tests, with 2 failures (0 unexpected) in 93.739 (93.746) seconds
** TEST FAILED **
```

同样 2 条、同样的量级（9.68s / 10.97s，全套里是 9.09s / 10.58s），**机器空闲时照样红**——说明不是「全套跑得挤」造成的偶发抖动，是这台机器上这两条测试的**稳定**环境问题（超时后进程树回收实际要 ~9-11s，阈值写的 4s / 6s）。按派单指示不追。

### Build

```text
xcodebuild -scheme MemoryPalace -destination 'platform=macOS' build
```

```text
note: Removed stale file '/…/Build/Products/Debug/记忆花园.app/Contents/PlugIns'

** BUILD SUCCEEDED **
```

（只跑 macOS。iOS build / 装机 / 模拟器按粟粟明令一律没碰。）

### 本 lane 改动足迹（相对 lane 自己的 base `d7a9d163`）

```text
 MemoryPalace/Services/ChatService.swift            |  34 +-
 MemoryPalace/ViewModels/ConversationViewModel.swift| 176 +++++-
 MemoryPalaceTests/BudgetGateTests.swift            | 623 +++++++++++++++++++++
 docs/minis对比/reports/H-B-report.md               |  55 ++
 4 files changed, 868 insertions(+), 20 deletions(-)
```

没碰 `BackupStore` / `SyncStore` / `ContentView`（H-A 地盘）、没碰 `ChatGPTOAuthProvider`、没碰 `project.yml` / `.gitignore` / `CLAUDE.md` / `NOW.md`（post-commit hook 自动改了 NOW.md 的 HEAD 戳，已 checkout 还原）。

⚠️ **给收口车头**：`git diff origin/master..HEAD` 会显示一大堆 vocab-corpus / cc-bridge / docs 的「删除」——那是因为本 lane 从**较早的 master**（`d7a9d163`）分出来，master 之后往前走了；那些是 master 的新增，不是本 lane 删的。按纪律本 lane 不做 rebase / merge master。合并时以上面这 3 个源文件 + 报告为准。

## 与契约的偏离

1. **ChatGPT OAuth 触发点的位置**（前一席记录，本席复核后沿用）。任务书把 OAuth 工具终止归到 `ChatService.swift:1270` router 透传；**实际 emit 在 `Services/ChatGPTOAuth/ChatGPTOAuthProvider.swift:211-220`**（`emitCollectedToolCalls`），那个文件不在本 lane 地盘。处理：在 `ProviderRouter` 的 OAuth 分支包一层适配 usage，不越界改 OAuth provider。**复核结论：这个决定对**，而且顺带让本席发现了 OAuth 路径的重复记账 bug（见「顺手发现」1）。

2. **`onToolCalls` 基类签名没改。** 任务书目标 1 写「签名改 `(([ToolCallBlock], TokenUsage?) -> Void)?` 还是另开一条通道——你定」。实现只改了 **`ProviderRouter.sendStreaming` 的对外签名**（`:1248`），`BaseChatProvider.onToolCalls`（`:53`）和三个子类的 `sendStreaming` 形参保持 `([ToolCallBlock]) -> Void`；usage 由 router 在 emit 瞬间读 `provider.finalUsage` 补上。理由：四个触发点在 `cb(calls)` 之前累加器都已经写好了（Anthropic 的 `output_tokens` 在 `message_delta`、OpenAI 的在 usage chunk、非流式的由本次新增的 `:123-129` 补齐），router 一处适配等价于四处传参，改面小四倍。**契约冻结的是「usage 要到 VM」，机制是自由度**，符合 IMPL-COMMON §escape hatch 第 3 条。

3. **off-by-one 选了「改判定位置」而不是「改文案」。** 二选一，没两边都动：`guard round < maxToolRounds` 挪到工具执行前，现在 `maxToolRounds = 8` → 真执行 8 批、第 9 次模型请求只用来确认是否收尾，文案「工具调用达到上限 8 轮」属实。第 9 次请求本身仍然记账（它花了钱）。

4. **本席补的两条测试不是「先红后绿」。** 它们是在 WIP 实现已经存在时补的回归守卫，没实跑过红。诚实标注：`testOpenAIRouterForwardsToolUsageToCallback` 在修前**编译就过不了**（旧签名只有一个参数）；`testMissingUsageRoundChargesEstimateNotPreviousRoundUsage` 在修前 `checkpoints[1] - checkpoints[0]` 恒为 0（中间轮压根不扣费），必红。本洞的「先红后绿」由前一席那 8 条满足。

## 顺手发现（契约外的问题，不修只报）

1. **【已在本 lane 内顺手修掉，因为它就在 ProviderRouter 里】ChatGPT OAuth 路径同一次请求记两遍账。** `ChatGPTOAuthProvider.swift:174-177` 在 `response.completed` 调 `emitCollectedToolCalls()`，紧接着 `:140-147` 的 `[DONE]` 分支**无条件**再调 `onComplete?(streamingContent, finalUsage)`。OpenAI（`:653`）和 Anthropic（`:1167`）都是 `if tool_calls {...} else { onComplete }` 互斥，只有 OAuth 是「两个都发」。后果不止记账：VM 的 `onComplete` 会跑 `finishAssistantTurn()` + 抽记忆 + 触发摘要，等于工具循环还在跑就把 turn 收了。修法落在 `ProviderRouter`（`:1264/1281-1291` 的 `ToolCallTerminalState`），没碰 OAuth provider 文件。`testChatGPTOAuthRouterForwardsToolUsageOnceAndSuppressesTrailingComplete` 锁住。**建议上游**：真正干净的修法是在 `ChatGPTOAuthProvider` 里让两条路互斥，router 这层门是隔着地盘的补丁。

2. **`pendingEstimatedCost` 是单一实例字段，跨并发 turn 会串。** `ConversationViewModel` 全局一个，`preCheckBudget` / `preCheckToolRequestBudget` 写、`commitBudgetSpend` 读完清零。当前设计是串行单流（`assistantTurnInFlight` 全局单值 + `pendingSends` 队列），所以踩不到；但后台 agent（`:3339` 记忆抽取、`:3507`）也调 `commitBudgetSpend`，如果哪天并发放开，估算兜底会张冠李戴。不修，记一笔。

3. **`GlobalBudgetStore` 是全局单例，测试之间靠 `isolateBudget()/restoreBudget()` 快照互不干扰。** 这几条工具循环测试会真的改全局预算再恢复，**不能并行跑**（XCTest 默认串行，现状安全）。将来若开 `-parallel-testing-enabled` 会互相打架。

4. **修完之后「气泡脚注的钱」和「预算表的钱」会公开打架。** 预算账现在记全部 9 次请求，但落到消息节点上的展示费用 `recordUsage`（`ConversationViewModel.swift:4015-4029`，只在 `onComplete` 调一次）依然只记**最后一次**请求的 usage → `node.usagePromptTokens` / `usageCompletionTokens` / `usageCostUSD`。同理 `lastTurnUsage`（`:1815`，中间轮传的是 `recordTurn: false`）也只反映最后一次。后果：一个 8 轮工具 turn，气泡脚注写「$0.048」，预算表那边却少了「$0.229」。**这是本次修复暴露出来的新不一致，不是我引入的 bug，但它是修完之后用户最可能来问的那个问题。** 不修的理由：`recordUsage` 是展示语义、不在「工具循环段」范围内，改它要一并想清楚「一条消息 = 一次请求还是一个 turn」。**建议上游**：要么中间轮也累加进节点（turn 语义），要么在脚注上标明「本条只算最后一次请求」。

5. **`BudgetCalculator.actualCost` 不看 cache token。** `TokenUsage` 有 `cacheReadTokens/cacheWriteTokens`，`displayCost` 会按 0.1×/1.25× 折算，但真正进预算的 `actualCost`（`BudgetCalculator.swift:48-58`）只用 `inputTokens × 单价`。工具循环把同一段前缀反复发送，正是 prompt cache 命中率最高的场景——**修完之后预算会系统性高估**（缓存命中的部分按全价扣）。文件里有注释说「预算扣费等精算+缓存自动路由一起再动」（`:100-101`），是已知债不是我引入的。方向上跟 ⧫「宁可多扣」一致，但工具循环放大了这个偏差，值得单独立项。

## 建议上游

- 上面「顺手发现」1 的根治（`ChatGPTOAuthProvider` 内部互斥）和 4 的 cache-aware 精算，都出本 lane 地盘。
- `addingBudgetSummaryInstruction` 靠「把指令追加到最后一条 tool_result 文本尾部」传达收尾意图。如果最后一轮**所有**工具都没产出 result（理论上不会：预检失败/权限拒绝也会回灌 isError result），指令就丢了，收尾请求退化成「无 tools 的普通请求」——模型多半还是会总结，但没有明确指令。更干净的做法是加一条 system/user 消息，但那要动 payload 组装链（`prepareRouterPayload` 一带），超出「工具循环段」范围。

## 未验证（诚实清单）

- **只跑了 macOS。** iOS build / 装机 / 模拟器一律没碰（粟粟明令）。工具循环代码是共用源码、没有 `#if os()` 分支，但 iOS 侧未编译验证。
- **没有真实 provider 实测。** 全部走本地 `NWListener` mock。真实 OpenAI/Anthropic/OAuth 端点的 usage 字段时序（尤其中转站不回 usage 的情况）只按已有解析逻辑推断。
- **`ChatGPTOAuthProvider` 的重复记账修复只在 router 层验证。** 走的是 mock SSE，没验真实 codex 端点的 `response.completed` → `[DONE]` 时序。
- **收尾请求的 prompt 措辞没做效果验证。** 只断言了「请求体里含这句话」「不下发 tools」「max_tokens=512」，没验模型真的会照做。
- **`maxToolRounds` 之外的中断路径（用户 stop / 切楼层）没补新测试。** 现有 `turnGeneration` 守卫逻辑未改，沿用。
- **多 turn 并发下的 `pendingEstimatedCost` 串号**（顺手发现 2）没测——当前架构串行，构造不出来。

## 真实账单估算（8 轮工具 turn）

**修前记账 = 只记最后一次请求；修后 = 9 次请求全记。差的不是 9 倍，是等差数列求和 ÷ 最后一项。**

工具循环每一轮都要把**之前所有**的 tool_call + tool_result 重新发一遍，所以第 k 次请求的 input ≈ `B + k·R`（B = 基础上下文：system + 预设 + 历史 + tools schema；R = 每轮新增的调用+结果）。

取一个典型 turn（`fs_read` 三次 + 一次 `search`，claude-sonnet-4-5，$3/$15 per MTok）：
- B ≈ 3000 tok（system 800 + 历史 1200 + tools schema 1000）
- R ≈ 1240 tok（tool_call 40 + 结果 1200：一段源码 / 一页搜索结果）
- 中间轮 output ≈ 40 tok（就一个 tool_call），最终 output ≈ 600 tok

| | 4 轮（5 次请求） | 8 轮（9 次请求） |
|---|---|---|
| 修前记的（只有最后一次） | 7960 in / 600 out = **$0.033** | 12920 in / 600 out = **$0.048** |
| 修后记的（全部请求求和） | 27400 in / 760 out = **$0.094** | 71640 in / 920 out = **$0.229** |
| **倍数** | **2.9×** | **4.8×** |

一般规律：**倍数 ≈ (轮数 + 1) / 2**（B 相对 R 越小越贴近这个上界；上表 B≈2.4R，所以略低于 4.5 的理论值反而偏高一点是因为最后一次请求的 input 也在分母里）。

**对粟粟的意思**：默认 $10 的保险闸，如果一个楼层经常跑 8 轮工具，修前的仪表盘显示「花了 $10」时，**账单实际已经 $48 左右**。闸门不是不准，是只看得见冰山尖。修完之后同样一个 turn，闸会在第 3-4 轮就把你拦下来——这是对的，但**粟粟大概率需要把默认额度往上调**，否则会觉得「怎么突然这么容易被拦」。这不是回归，是第一次看见真账。

（另注：见「顺手发现」4，修后账**还会偏高**——prompt cache 命中的部分目前按全价扣，而工具循环恰恰是缓存命中率最高的场景。所以真实倍数介于「修前的 4.8 倍」和「4.8 倍再打个缓存折扣」之间，方向是 ⧫ 认可的「宁可多扣」。）

## 本 lane 全部 commit

```text
$ git log --oneline origin/master..HEAD
8e5a5fe4 洞3：报告补 commit 清单 + 交接说明（前一席 WIP 实测已绿，本席是审+补+收口不是续做）
bfb7e4c4 洞3：H-B 报告收口 DONE——17 测试全绿 / 全套 836 只剩 2 条已知墙钟 flake / macOS build 绿
c8023c91 洞3：补两条回归守卫——router 非 OAuth 分支转发 usage / 缺 usage 轮按本轮估算扣
813507c9 WIP(洞3): codex 撞配额墙前的未完成实现——onToolCalls 带 usage / 回灌前 gate / 收尾文案已写，测试未跑绿（车头代收工作树，opus5 接手）
7ea1e1f0 洞3：补工具循环记账红灯测试
c1f8ce5e 洞3：建立 H-B 实施报告骨架
```

（本节自身还有一次「补 commit 清单」的小 commit 落在 `8e5a5fe4` 之后，见分支实际 HEAD。）

分支：`origin/worktree-h-b-tool-loop`。前三条是 codex 席位留下的（`813507c9` 是车头代收的未完成工作树），后两条是 opus5 接手做的。

**接手时的实际状态与派单描述的出入**：派单说 `813507c9` 是「WIP，测试没跑绿」。本席第一件事是照原样跑一遍 `BudgetGateTests`，结果是 **`Executed 15 tests, with 0 failures` / `** TEST SUCCEEDED **`**——前一席的实现其实已经是完整可用的，它只是在**跑测试之前**撞了配额墙，所以自己不知道。本席的工作因此不是「续做」而是「审 + 补 + 收口」：逐行复核了 WIP 的三处改动方向（router 适配 usage / `continueToolLoop` 前置 gate / off-by-one 挪判定），确认全部正确，没有推翻重做任何一块；额外补了两条它没覆盖的回归守卫，跑了全套 + build，写了报告。
