# Plan：B4 工具结果外置 + fs_read 范围读

> 2026-09-08 · 前提 = `research-B4-工具结果外置.md`。
> **⧫ 粟粟 09-09 00:05 裁决**：「别的都按你推荐，4000 太少，参考 pi，要点开看全文。2 小时后开始施工」→ D1 改 pi 档位、D2 加「打开完整结果」进 v1、D5/D8/D9 按推荐。**go = 09-09 02:05 PDT**。
> 落点：master 直做（单功能、不建 worktree）。mac 壳 plan 不碰下面任何文件，无锁冲突。

## 目标 / 成功标准

1. 同一 tool loop 内，任何一个工具结果超阈值后，**后续每轮请求里它只占预览大小**（可用 `ToolLoopHTTPServer.requestBodies` 量出来）。
2. 全文一个字不丢：落在楼层本地 `tool-results/`，模型用 `fs_read(path, offset, limit)` 能分段读回。
3. 不改任何工具自身的执行逻辑，不改预算代码，不改 UI 卡片。
4. 测试不往真实 `~/Documents` 泄目录。

## 设计决策（⧫ 处等粟粟拍）

### D1 阈值：pi 档位——2,000 行 或 50KB，先到先算（⧫ 已裁）

对着本机 pi 读的（`/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/tools/truncate.js:10-11`、`read.js:141`、`bash.js:238,314-320`）：

| pi | 做法 |
|---|---|
| 上限 | `DEFAULT_MAX_LINES = 2000` / `DEFAULT_MAX_BYTES = 50 * 1024`，先到先算 |
| `read` | 头截，不切半行；描述里写「Use offset/limit for large files. When you need the full file, continue with offset until complete」；尾注 `[Truncated: showing X of Y lines (2000 line limit)]` |
| `bash` | 尾截（错误在末尾）+ **全文落临时文件**；尾注 `[Showing lines a-b of N. Full output: <path>]` |
| 首行单独超 50KB | 按字节切那一行，标 `firstLineExceedsLimit` |

MP 采用：
- **上限 = 预览 = 2,000 行 / 50KB**，不再另设 4,000 token。代价明说：一个 50KB 纯中文结果 ≈ 17K token，每轮仍重发；这是 pi 的取舍，粟粟拍的。
- **一律头截**（`fs_read` 同 pi read；MCP / 搜索 / 网页等结构在头部）。`run_command` 内层已做头尾各半且 envelope 是**单行 JSON**（换行被转义），不会被行数上限二次截。设备工具同理单行。
- 首行单独超 50KB（单行大 JSON）：按字符边界切到 50KB，尾注说明。
- 全文落 `tool-results/`（pi bash 的做法推广到所有非文件结果）；`fs_read` 特例见 D4。
- `fs_read` 自身也按这个上限头截，尾注引导 `offset` 续读（pi read 同款）；带 `limit` 的范围读同样受 2,000 行 / 50KB 约束。

### D2 落哪：`tool-results/` 虚拟前缀，镜像 `memory/` 机制 ⧫

物理位置 `floors/<slug>/tool-results/<conversationId>/<NNN>-<toolName>.txt`（和 `memory/` 同级，**不在 `filesystem/` 下**）。

得到的性质：永远本地不进 iCloud · 不进 `fileLibrarySystemHint` 的 50 条清单 · 不进 `fs_list` · 不进用户文件库页 · 模型只读（`fs_write/edit/delete` 一律拒，同 `memory/` 的拒绝文案形状）。

- 备选（弃）：放 `filesystem/tool-results/`——开 iCloud 会同步、`list()`/`fs_list` 要加 skip、清单被污染。
- **⧫ 已裁：虚拟前缀 + v1 就做「打开完整结果」**（D2b）。

### D2b 卡片「打开完整结果」（⧫ 粟粟要的，进 v1）

- `MessageSegmentsView` 已持有 `profileId`（`:24`），把它传进 `ToolCallCardView`（现在没有）。
- 卡片判定「有全文可开」：① `resultText` 里匹配到 `tool-results/[^\s」』）\]]+\.txt`（我们自己生成的路径，字符集受控）→ 开那个文件；② `name == "fs_read"` 且结果带截断尾注 → 开 `inputJSON.path` 那个库内文件。两者都走 `FileLibraryStore` 读（`toolResultRead` / `read`），不暴露宿主路径。
- 入口：原地展开体和 sheet 里都在结果下方加一个按钮「打开完整结果」，点开 `DisclosureSheet(title: 文件名)` 全文等宽 + 复制（复用 `ToolCallDetail` 的样式）。文件 > 1MB 只读前 1MB（`readPreview(maxBytes:)`）+ 顶部一行「文件过大，只显示前 1MB」。
- 路径解析放 `ToolResultOffload.embeddedPath(in:)` 纯函数，有测试。
- 不做：文件库页里出现 `tool-results/`、系统分享、Finder 定位（macOS 上路径本来就能 Finder 打开，卡片不管）。

### D3 `fs_read` 加 `offset` / `limit`（可选参数，按行）

- `offset` 1-based 起始行，`limit` 行数；都可选，缺省 = 全文（行为不变）。
- 带范围时结果首行加 `（第 a–b 行 / 共 n 行）`；越界返回 isError 带总行数。
- 三种路径都支持：普通 / `memory/` / `tool-results/`。
- schema 描述改成「读取文件；大文件用 offset/limit 分段读」。`required` 仍只有 `path`，预检不用改。

### D4 `fs_read` 特例：不复制、指针指原文件

`fs_read` 读库内真实文件超阈值 → 不落 `tool-results/`，预览尾部的取回指引直接指**原路径**（`用 fs_read(path: "<原路径>", offset, limit) 分段读，共 n 行`）。只有非文件来源（MCP / `run_command` / `browse_url` / `fs_search` / 设备工具…）才复制到 `tool-results/`。

### D5 收口点：循环后一次扫描，不动十二个分支 ⧫

在 `ConversationViewModel.swift:3121`（`for call in calls` 结束、`guard gen == self.turnGeneration` 之前）加一段：遍历 `results`，对每个调 `ToolResultOffload.apply(...)`，被外置的就替换 `results[i]` 并按 `toolUseId` 回写 `segs` 里对应的 `.toolResult`。约 15 行。

- 备选（弃）：把 12 处 `segs.append + results.append` 收成一个局部闭包 `emit(...)`。去重更彻底，但要改 12 处、diff 大。
- **⧫ 已裁：后置扫描。**

### D6 预览格式（回灌给模型 = 卡片显示的同一份）

pi 同款尾注，中文：

```
<头 2,000 行或 50KB，不切半行>

[已截断：显示第 1–2000 行 / 共 5,480 行（2000 行上限）。完整结果已保存到 tool-results/<conv>/<id>-search_docs.txt，用 fs_read(path: "tool-results/<conv>/<id>-search_docs.txt", offset: 2001) 续读]
```

按字节截时括号写 `（50KB 上限）`；首行单独超限写 `[首行超过 50KB，已按 50KB 切断。完整结果…]`。`fs_read` 特例：`用 fs_read(path: "<原路径>", offset: 2001) 续读`，不提 tool-results。文件名 `<toolUseId 清洗后>-<toolName>.txt`（唯一、不用扫目录取序号）。

### D7 UI / 落库：seg 与 result 同文本

`.toolResult` 的 `text` 就是预览+指针。全文只在文件里，SwiftData 不再吃大结果。卡片代码零改动（2,000 字折叠照旧）。

### D8 保留策略 ⧫

每个对话目录最多保留 **50** 个文件，写入时超了删最旧（按修改时间）。删对话不清理（v1 记债，文件库现在也没有删对话钩子）。**⧫ 已裁：50。**

### D9 B2 不搭车 ⧫

research §B2 复核：解绑要搬开关行 + 定权限语义，不是一行。**⧫ 已裁：单独立项**，B4 不碰记忆设置页。

## 改动清单

| 文件 | 改什么 | 量 |
|---|---|---|
| **新** `Services/Tools/ToolResultOffload.swift` | `enum ToolResultOffload`：`maxLines = 2000` / `maxBytes = 50 * 1024`；`truncateHead(_:) -> (text, truncated, totalLines, totalBytes, by: lines/bytes/firstLine)`（pi `truncateHead` 同构，不切半行）；`apply(text:isError:call:conversationId:profileId:) -> (text: String, offloaded: Bool)`；`fs_read` 特例；`embeddedPath(in:)`；纯函数 + 一次 `FileLibraryStore.toolResultWrite` | ~110 行 |
| `Services/FileLibraryStore.swift` | `toolResultsVirtualPrefix` / `toolResultsRoot` / `resolveToolResult` / `toolResultWrite(conversationId:toolName:content:) -> 虚拟路径`（含 50 上限）/ `toolResultRead`；`readLines(_:offset:limit:)` 通用范围读（三种路径共用） | ~70 行 |
| `Services/FileLibraryTools.swift` | `fs_read` spec 加 `offset`/`limit` + 描述（pi read 同款：「大文件用 offset/limit 分段读；要全文就用 offset 续读到完」）；`tool-results/` 前缀分支（读放行、写拒）；`.read` 分支走范围读 + 头截尾注 | ~35 行 |
| `ViewModels/ConversationViewModel.swift` | `:3121` 前后置扫描 ~15 行；`fileLibrarySystemHint` 的固定文案句尾加一句「tool-results/ 是过长工具结果的存档，只读，按路径 fs_read 取」 | ~18 行 |
| `Views/MessageSegmentsView.swift` | `ToolCallCardView` 加 `profileId` 入参（两处构造点传入）；「打开完整结果」按钮 + 全文 sheet（D2b） | ~45 行 |
| **新** `MemoryPalaceTests/ToolResultOffloadTests.swift` | 见测试清单 | ~120 行 |
| `MemoryPalaceTests/BudgetGateTests.swift` | 加 1 条端到端 | ~40 行 |
| `manual/facts/` | 文件库 / 工具一节加事实行（带文件:行号） | 2 行 |
| `NOW.md` | 登记 → 完成同 commit 更新 | — |

不碰：`ChatService` / 预算 / `RunCommandTool` / `MCPProvider` / 任何设置页。

## 测试清单

**`ToolResultOffloadTests`**（唯一 profileId + tearDown 删楼层目录，照 `FileLibraryHostFixesTests:8-14`）
1. 2,000 行以内且 ≤50KB 原样返回、不落盘、`offloaded == false`
2. 2,001 行短行 → 按行截（尾注写 2000 行上限）；1,000 行但 60KB → 按字节截（尾注写 50KB 上限）；单行 80KB JSON → 首行切断尾注
3. 外置后：文件全文 == 原文；预览 = 前 2,000 行 + 尾注，尾注含路径、`offset: 2001`、总行数
4. 尾注里的路径能被 `fs_read` 读回，`offset/limit` 取到的行 == 原文对应行；`embeddedPath(in:)` 能从预览里抠出同一路径
5. `fs_read` 特例：读库内大文件 → `tool-results/` 目录**不出现**，尾注指原路径 + `offset: 2001`
6. `tool-results/` 写拒：`fs_write` / `fs_edit` / `fs_delete` 返回 isError
7. 50 上限：写 52 个 → 目录里 50 个，最旧两个没了
8. 不切半行：头截边界在换行处；UTF-8 多字节字符不被字节切坏（中文 50KB 边界）

**`FileLibraryTools` 范围读**
9. `offset/limit` 缺省 = 全文（老行为不变）；越界 → isError 带总行数；`memory/` 前缀也能范围读

**`BudgetGateTests` 端到端**
10. 假 server 第 1 轮回一个 MCP 风格大结果（或 `fs_read` 一个 3,000 行文件），第 2 轮回纯文本收尾。断言第 2 个请求体里 `role:tool` 的 content ≤ 2,000 行且含「已截断」尾注；节点 segments 里的 `.toolResult` 同文本。

## 验证步骤

1. `xcodegen generate && xcodebuild -scheme MemoryPalace build`（macOS）+ iOS 指定模拟器 build，0 error
2. `xcodebuild test -scheme MemoryPalaceTests`：新增 10 条全绿，原 851+ 不退
3. 跑完 `ls ~/Documents/记忆宫殿/floors/ | grep -c test` **不增长**
4. 模拟器手测（不装实机）：文件库放一篇 3,000 行的文章 → 让模型「读一下并总结」→ 卡片显示头 2,000 行 + 尾注；模型若追读，`fs_read offset` 卡片显示行号范围；**点「打开完整结果」能看到整篇**
5. 手测第二条：`run_command` `seq 1 20000`（单行 envelope，验证不被二次截）+ 一个多行大输出（`cat` 一个 5,000 行文件）→ 卡片预览 + `tool-results/` 目录里有全文 + 「打开完整结果」能开

## 影响范围 / 文件锁

`ConversationViewModel.swift`（只 `:3121` 附近 + hint 一句）· `FileLibraryStore.swift` · `FileLibraryTools.swift` · `MessageSegmentsView.swift`（只 `ToolCallCardView`）· 新增两文件。NOW.md 文件锁登记这五个。

## 不做

- B3 / 自动 compaction / 历史轮外置 / A2 / A3
- `run_command` 内层 cap 抬高（v2）
- 删对话时清 `tool-results/`（记债）
- B2（D9，单独立项）

## Todo

- [x] ⧫ 全部批完，粟粟 go（09-09 02:05 开工）
- [x] `FileLibraryStore`：`tool-results/` 前缀 + 写/读 + 50 上限 + `readAny`（范围切行放 `ToolResultOffload.fileRead`，Store 只管 IO）
- [x] `FileLibraryTools`：`fs_read` offset/limit + 前缀分支 + 头截尾注
- [x] `ToolResultOffload.swift`（truncateHead / apply / fileRead / embeddedPath）
- [x] `ConversationViewModel` 后置扫描 + hint 一句
- [x] `ToolCallCardView` profileId + 「打开完整结果」sheet（D2b）
- [x] `ToolResultOffloadTests` 1–9（11 条，含 embeddedPath）
- [x] `BudgetGateTests` 第 10 条 `testOversizedToolResultIsOffloadedBeforeNextRound`
- [x] 双端 build 绿 + 测试：macOS 874 条，3 红 = golden（`5d6b12d1` 重生成后绿）+ RunCommandToolTests 2 条计时老账；iOS build 0 error；本类测试 floors 615→615（全量跑 +10 是老泄漏）
- [ ] 模拟器手测 4、5 → **needsusu**（需要真实 provider key，我不填；粟粟自己的模拟器上跑）
- [x] `manual/facts/` 事实行 → 没有文件库/工具 facts 文件（只有 data-import / model-api），记债 review §三 #3，M4 派批时补
- [x] `review-B4-工具结果外置.md`（边界 / 与 B3 的接口 / 债）
- [x] NOW.md + 对比报告 §二 B4 行打勾 · commit · push
