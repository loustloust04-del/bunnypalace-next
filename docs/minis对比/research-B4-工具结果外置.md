# Research：B4 工具结果外置（tool-result offload）

> 2026-09-08 · 粟粟「走流程做 B4」。上游：`对比报告.md` §二 B4 / §二 09-08 复验表。
> 全部行号对着 master `c541dcbd` 亲读。**状态：research，等粟粟确认再进 plan**（plan 草稿已同目录写好，以 research 结论为前提，未确认前不算数）。

## 一句话

同一个 tool loop 里，模型每多跑一轮，前面所有工具结果就原样再发一遍；`fs_read` 和 MCP 的结果没有任何上限。B4 = 结果超阈值就落盘，回灌只给「头 + 尾 + 路径 + 怎么分段取回」，再给 `fs_read` 加范围读让取回真能用。

## 为什么现在急（对比报告没写、09-08 才成立的三件事）

1. **大结果的来源在 08-24 之后翻倍**：沙箱 shell / `run_command` / MCP / 设备工具 / `browse_url` 全是之后落地的。
2. **洞 3 修完（`b93d0684`），真账露出来了**：工具循环每一轮都记账了，账 ≈ (轮数+1)/2 × 单请求上下文。工具结果是上下文里长得最快的部分。默认 $10 闸现在第 3–4 轮就拦。
3. **B4 不碰记忆模块**——B1/B2 都要等记忆方案，B4 是纯无损机械活。

## 现状链路（带行号）

### 1. 结果产生：一个循环、十二个分支、同一句话写两遍

`ConversationViewModel.swift` `runStreamingTurn` 的 `onToolCalls` 闭包，`for call in calls`（`:2975`–`:3119`）。每个分支结尾都是同一对：

```swift
segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: …))   // UI + SwiftData
results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))               // 下一轮请求
```

分支：预检失败 `:2981` · 权限拒 `:2992` · 元工具 `:2997` · `fs_*` `:3005` · 资料卡 `:3019` · 心声 `:3052` · 回忆 `:3060/:3076` · 联网搜索 `:3085` · 问问题 `:3093` · 网页阅读 `:3103` · 设备工具 `:3105` · MCP `:3112`。

循环之后（`:3121`–`:3145`）：`assistantNode.setSegments(segs)` 落库 → 若有问问题就暂存 `otherResults: results` 返回 → 否则 `continueToolLoop(toolTurns: toolTurns + [ToolTurn(calls:results:)], round: round + 1)`。

**收口点天然存在**：循环结束、`setSegments` 之前，`results` 和 `segs` 都在手里，按 `toolUseId` 一一对应。

### 2. 出线：每轮把全部 toolTurns 原样重发

- OpenAI 系：`ChatService.swift:462-473`，每个 result 变成 `{"role":"tool","tool_call_id":…,"content": result.text}`。
- Anthropic：`:845-861`，`tool_result` block 的 `content: result.text`。
- `toolTurns` 是累加数组（上一步 `toolTurns + [ToolTurn(…)]`），**第 k 轮请求带前 k-1 轮所有结果全文**。

### 3. 历史轮不是问题（澄清对比报告的口径）

- 后续用户 turn 重建历史时，工具历史走 `toolHistorySummary`（`:2139-2166`）——只留「· fs_read(path)」这种动作行，**不带结果快照**。
- 「碰过文件全文注入 system」由 `fileLibraryFullContent` 控制，**默认关**（`:2565-2575`，pull 化决策）。
- 所以膨胀**只发生在同一个 tool loop 内**。B4 的范围就是这个 loop，不需要动历史重建。

### 4. 预算估算跟着结果全文走

`preCheckToolRequestBudget`（`:2719-2753`）用 `toolTurnsEstimateText`（`:2712-2717`）把每个 result 的 `text` 全文喂给 `HeuristicEstimator`。外置之后 `results` 里是预览，估算自动变小，**不用改预算代码**。

### 5. 各工具的输出上限现状

| 工具 | 上限 | 位置 |
|---|---|---|
| `run_command` | stdout/stderr 各 15,000 字符，超出头尾各半，中段**丢弃** | `RunCommandTool.swift:17, :139-144` |
| `browse_url` | 8,000 字 | `BrowseURLTool.swift:21` |
| `read_clipboard` | 20,000 字 | `ClipboardTool.swift:13` |
| `recall` | 有地板/上限/截断（research 决策 5） | `RecallTool.swift:16` |
| **`fs_read`** | **无**，`String(contentsOf:)` 整文件 | `FileLibraryStore.swift:253-258` |
| **MCP** | **无**，`flattenedText` 原样 | `MCPProvider.swift` `callToolText` → `MCPModels.swift:200` |
| `fs_search` / `fs_list` | 无（命中行 / 文件清单全列） | `FileLibraryTools.swift:64-70` |
| 设备工具（日历等） | 紧凑 JSON，自带 `limit` | `CalendarTools.swift:85` |
| `web_search` | 未查证（`WebSearchToolService.swift` 没搜到截断） | — |

`readPreview(_:maxBytes:)` 已存在（`FileLibraryStore.swift:266-274`）但 fs 工具不用。

### 6. `fs_read` 的 schema 只有 `path`

`FileLibraryTools.swift:22`：`(.read, "读取某个文件的全文", ["path": …], ["path"])`。没有 offset/limit。**外置后模型只能把整个文件再读回来，等于白干**——范围读是 B4 的必要组成，不是加分项。

### 7. 文件库的地基（外置落哪、怎么读回）

- 每楼层一库：`Documents/记忆宫殿/floors/<slug>/filesystem/`（`FileLibraryStore.swift:4-6`）。
- `resolve` 防逃逸 + 组件长度 clamp（`:168-190`）；`textExtensions` 含 `txt`（`:745`）；`write` 走 `writeQueue` 原子写、自动建父目录（`:275-289`）。
- **iCloud 开关只影响 `filesystem/`**（`:28`）。放 `filesystem/` 下的东西开了 iCloud 就会同步。
- **`memory/` 虚拟前缀先例**（`:404-453`）：映射到楼层本地目录（永远本地）、`fs_read` 放行 `fs_write` 一律拒（`FileLibraryTools.swift:44-57`）、`list()` 天然不含。**B4 的 `tool-results/` 可以整套镜像这个机制**——不进 iCloud、不进 `fileLibrarySystemHint` 的 50 条清单（`:2554`）、不进用户文件库页、模型只读。
- `list(skippingTopLevelDirs:)`（`:230`）——如果不走虚拟前缀而放 `filesystem/tool-results/`，这里和 `fs_list` 都得加 skip，且用户文件库页会看到一坨。

### 8. UI 侧

`MessageSegmentsView.swift:69-93` 把 `.toolUse` + `.toolResult` 配成 `toolPair`；`ToolCallCardView` 默认折叠、结果显示截 2,000 字可展开（`:438, :456`）。`segments` 全文序列化进 SwiftData `segmentsData`——一次 200KB 的 `cat` 就是 200KB 进库、每次渲染解码。

### 9. 测试基建（能直接用）

- `BudgetGateTests.swift`：`ToolLoopHTTPServer` 记录每个请求体 `requestBodies`（`:33`）；`ToolLoopFixture`（`:133-`）内存 SwiftData + 真 `ProviderManager` + 固定 profile `xctest-tool-loop-profile`，能端到端跑 tool loop 并断言第 N 个请求体里 `role:tool` 的 content。
- `FileLibraryHostFixesTests.swift:8-14`：唯一 `profileId` + `tearDown` 删整个楼层目录——**B4 的测试必须照这个做**（H-Q 教训：`RunCommandToolTests` 没 tearDown 泄了 477 个目录）。
- `ToolCallPreflightTests.swift`：纯函数测试形状，`ToolResultOffload` 照抄。

## 量一下

`HeuristicEstimator`（`TokenEstimator.swift:11-24`）：CJK 一字一 token，其余 3.5 字符一 token。

| 场景 | 现状每轮重发 | 8 轮累计（重发 7 次） | 外置到 ~2K token 预览后 |
|---|---|---|---|
| `fs_read` 一篇 60K 字中文 | ≈60K token | ≈420K token | ≈14K token |
| MCP 返回 300KB JSON（英文） | ≈86K token | ≈600K token | ≈14K token |

这就是「$10 闸第 3–4 轮就拦」的来源。

## 周边会不会被打坏

| 点 | 结论 |
|---|---|
| 问问题暂停路径 `resumeUserQuestion`（`:1593`）自己拼 Q/A results | Q/A 文本小，不经收口点也无妨；但 `otherResults` 来自收口点之后，天然已外置 ✅ |
| 预算收尾 `addingBudgetSummaryInstruction`（`:2755`）把收尾指令拼在最后一个 result 后 | 拼在预览后面，语义不变 ✅ |
| `touchedFilePaths`（`:2694`）收集 `fs_read` 的 path | 模型 `fs_read tool-results/…` 会被收进去；只在 `fileLibraryFullContent=true` 时注入，默认关。虚拟前缀路径 `FileLibraryStore.read` 读不到会 `continue`（`:2569`）✅ |
| `run_command` 内层已截断、中段丢弃 | B4 不改它（≤15,000 字符直接过阈值以下或临界）；抬内层 cap 交给外置是 v2 |
| 设备工具的 JSON envelope 被头尾切断 | 模型能读残缺 JSON，预览头部要写明「这是截断预览」 |
| MCP 非文本 content（image/resource） | `flattenedText` 已转文本，B4 只看文本长度 |
| iCloud | 走虚拟前缀 → 永远本地，不进同步 ✅ |
| 删对话 | 文件库没有「删对话时清目录」的钩子（grep 无）。tool-results 会残留，v1 记债 |

## B2 复核（更正我 09-08 口头说的「改一个 && 的事」）

`MemoryFlags.contextSummaryEnabled`（`MemoryService.swift:299-301`）确实是 `masterEnabled && …` 一行。但：
- 开关行在 `MemorySettingsTab.swift:183` / `MemoryPageContent.swift`，嵌在记忆总开关区里；
- 总开关不只是 UserDefaults，还写 `PermissionCenter.setLevel(.memory)`（`MemorySettingsTab.swift:143`）。

解绑 = 改一行 + 把开关行搬出总开关区 + 定「记忆权限 notAllowed 时还能不能写摘要文件」的语义。**不是一行**。建议不搭 B4 的车，单独立项（plan 里留 ⧫）。

## 不在 B4 范围里

- B3 token-aware ContextPolicy / 自动 compaction（有损，B4 之后）
- 历史轮的工具结果外置（历史已是动作序列，无需求）
- 并发工具（A3）、循环熔断（A2）
- `run_command` 内层 cap 抬高
- Minis 1.13 的「接近窗口时外置旧图片/写入内容」（`AIChatViewModel+Offloading.swift`，未读码）

## 参考

- Minis 规格（L5 报告转述，**未重新读码**）：结果 > 15,000 字保存到文件，只回首尾或前缀 + 取回路径（`OM/src/ios/Agent/Chat/AIChatViewModel.swift:14-24`、`+ConcurrentTools.swift:918-940`）。L5 的采纳建议原话：「外置应落到 MP 文件库的专用只读 `tool-results/`，并给模型一个受控读取工具，不能把任意宿主路径暴露出去」。
- `docs/minis对比/reports/L5-report.md` §4
- **pi 规格（09-09 对着本机安装读的**，`/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/tools/`）：`truncate.js:10-11` 2,000 行 / 50KB 先到先算，不切半行；`read.js:141` 头截 + `offset/limit` 续读；`bash.js:238,314-320` 尾截 + 全文落临时文件 + `[Showing lines a-b of N. Full output: <path>]`。粟粟 09-09 裁定 B4 按这个档位。
