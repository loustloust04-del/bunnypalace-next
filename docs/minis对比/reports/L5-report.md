# L5 —— Agent 上下文治理对比报告

> 取证日期：2026-08-24。纯静态阅读；未 build、未跑测试、未做 Git 操作。  
> 下文 `OM/` 指 COMMON 冻结的 OpenMinis clone 根目录下相对路径；`MP/` 指本仓库 `MemoryPalace/` 源码目录。

## TL;DR

| 发现 | 差距性质 | 采纳建议 | 代价档位 |
|---|---|---|---|
| **P0：先加 schema 驱动的工具预检，堵住缺参写空文件** | 能力缺失 | **改造搬**：先只校验，不做激进修复 | 天级 |
| **P1：把“8 轮硬停”升级为按参数与结果判断的循环熔断** | 能力缺失 | **改造搬**：保留 8 轮总闸，再加语义检测 | 天级 |
| **P1：MP 的摘要必须绑定分支路径；OM 的线性 marker 不能直接搬** | 实现更优（仅在线性会话内） | **只借思路**：按 MP 树原生实现 path fingerprint | 周级 |
| **P1：从“消息条数窗”升级为 model/token-aware ContextPolicy + 工具结果外置** | 实现更优 | **改造搬**：每次模型请求前重算，输出保留空间 | 周级 |
| **P1：个人记忆与会话压缩必须解耦，不能共用总开关** | 实现更优（职责边界） | **只借思路**：分 store、分开关、分健康状态 | 天级 |
| **P1：保留 MP 的美元预算，但补齐工具循环逐请求计费与门控** | 我们更好（但有缺口） | **改造搬**：单位继续用 USD，另记请求/轮次 | 天级 |
| **P2：真正可搬的 `RequestBudget` 是 25MB 图片字节预算** | 能力缺失 | **改造搬**：最新图片优先，旧图变可取回指针 | 天级 |
| **P2：并发工具只开放给声明为只读、互不冲突的调用** | 实现更优 | **只借思路**：有界并发 + 原顺序回灌 | 周级 |
| **P2：增加请求重试与模型降级链，但须先解决计费和副作用边界** | 能力缺失 | **改造搬**：错误分类、候选去重、空响应检测 | 架构级 |
| **P3：`@文件` 只学显式选择 UX，不搬全设备目录扫描** | 能力缺失（低优先级） | **只借思路** | 天级 |

## 前提冲突与证据口径（escape hatch）

任务书的三个前提已经被当前源码推翻，不能继续按旧前提下结论：

1. **MP 不是“基本没有 Compaction”**。MP 已有累计摘要、自动触发、手动压缩、覆盖条数、可见状态和摘要锚定窗口：`MP/Services/ContextSummarizer.swift:31-63`、`MP/ViewModels/ConversationViewModel.swift:2095-2122`、`MP/Views/PersonaSettingsTab.swift:1438-1478`。真正的问题是它按**消息条数**而不是 token 触发，且摘要没有分支身份。
2. **`GlobalBudgetStore` 不是死代码**。主发送在建节点前调用预算预检：`MP/ViewModels/ConversationViewModel.swift:2199-2204`；全局预算闸会在未拨款或预计超额时阻断：`MP/Utils/BudgetCalculator.swift:60-78`；最终响应会提交花费：`MP/ViewModels/ConversationViewModel.swift:2679-2684`。真正的问题是工具循环的中间模型请求漏账。
3. **OM 的 `RequestBudget` 不是 token / 钱 / 轮数预算**，而是单次请求的图片字节预算；它以最近图片优先分配字节：`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:11-61`。因此不能拿它替换 MP 的美元预算。

病历仍然改变建议口径。2026-07-07 真机快照证明记忆提取曾静默停摆 11 天，约 4000 条新消息没有产出记忆：`docs/report-记忆现状-2026-07-07.md:9-44`；当时还存在垃圾条、重复条和无阈值召回：`docs/report-记忆现状-2026-07-07.md:46-52`。当前源码已经补了失败健康状态、向量阈值和编辑 UI：`MP/Services/MemoryService.swift:1216-1230`、`MP/Services/MemoryService.swift:433-475`、`MP/Views/MemorySettingsTab.swift:542-559`。但本 lane 禁止运行与查真机数据，所以这些只能证明“修复代码现在存在”，**不能证明当前设备的记忆供水已恢复或存量质量已健康**。

## 发现

### 1. P0：先加 schema 驱动的工具预检，堵住缺参写空文件

- **OM 怎么做**：工具 schema 的 `required` 是预检真相源；调用前拦截缺字段、`null` 与不允许的空字符串：`OM/src/ios/Agent/Chat/AIChatViewModel+ToolPreflight.swift:203-281`。流参数异常时先尝试有限修复，但一旦写工具的参数流被截断，就明确拒绝执行，避免把半截内容写进文件：`OM/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift:151-240`。预检失败会变成可见且可回灌给模型的错误结果：`OM/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift:242-269`。
- **一句话回答 ToolPreflight 防什么**：它在 executor 之前，用模型刚看过的同一份 schema 拦住空参数、缺参、`null` 与截断写入，防止坏 tool call 变成真实副作用。
- **MP 现状**：MP 已有统一 `ToolDefinition.required`，但它只用于把 schema 发给模型，执行分发仍在 ViewModel：`MP/Services/Tools/ToolDefinition.swift:3-12`。例如 `fs_write` 明确要求 `path` 与 `content`：`MP/Services/FileLibraryTools.swift:19-28`；执行端却把 JSON 解析失败降成空字典，并把缺失字符串统一降成 `""`：`MP/Services/FileLibraryTools.swift:42-45`、`MP/Services/FileLibraryTools.swift:226-227`。`fs_write` 随后直接把这个空内容交给原子写：`MP/Services/FileLibraryTools.swift:72-77`、`MP/Services/FileLibraryStore.swift:214-222`。所以一个合法 JSON `{"path":"x.md"}`（缺 `content`）会通过执行分支并把文件写空；这是静态调用链直接推出的结果，不是仅凭 grep 的猜测。
- **差距性质**：能力缺失。
- **采纳建议**：**改造搬**。按 MP 架构原生加一个 `ToolCallPreflight`：从 `ToolDefinition` / MCP schema 取 required、类型、enum；在任何 executor 前统一验证。第一版只做确定性拒绝，不做 fuzzy 改名或类型强转。错误必须作为 `ToolResultBlock(isError: true)` 回灌并显示。后续若加截断修复，只允许读类工具；写、删、改名永远不自动补闭合后执行。
- **代价档位**：天级。
- **风险与前置**：需要把动态 MCP schema 与内建注册表汇成同一种可查询 spec；`new_string == ""` 这类“空字符串是合法语义”的字段必须有白名单，OM 也专门处理了这个例外：`OM/src/ios/Agent/Chat/AIChatViewModel+ToolPreflight.swift:212-227`。这是本 lane **第一优先级**：改动小，直接保护用户数据，也是后续重试、并发、降级安全上线的前置。

### 2. P1：把“8 轮硬停”升级为按参数与结果判断的循环熔断

- **OM 怎么做**：OM 维护最近 30 次工具调用，默认在重复 10 次时警告、20 次时阻断、30 次时全局熔断，并单独识别未知工具：`OM/src/ios/Agent/ToolLoopDetector.swift:31-56`。它对参数做稳定 JSON hash，忽略 UI 标题；对结果先去时间戳、耗时、请求 ID 等易变噪声再 hash：`OM/src/ios/Agent/ToolLoopDetector.swift:218-300`。执行前可短路，执行后把警告追加到模型可见结果：`OM/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift:123-149`、`OM/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift:960-973`。另有 200 次总迭代硬上限作为最后后挡：`OM/src/ios/Agent/Chat/AIChatViewModel.swift:66-77`、`OM/src/ios/Agent/Chat/AIChatViewModel.swift:5694-5710`。
- **MP 现状**：MP 只有全局 `maxToolRounds = 8`：`MP/ViewModels/ConversationViewModel.swift:2335-2340`，以及 recall 单工具的本轮次数闸：`MP/ViewModels/ConversationViewModel.swift:2792-2800`。其余工具没有“相同参数 + 相同结果 = 无进展”的检测。工具结果执行完后才检查 `round < 8` 再递归：`MP/ViewModels/ConversationViewModel.swift:2876-2893`。**静态推断**：初始 `round=0`，因此 0…8 都会先执行工具，第 9 批执行后才显示“达到 8 轮”；文案与实际批次数有一轮偏差。
- **差距性质**：能力缺失。
- **采纳建议**：**改造搬**。保留 MP 的 8 轮低总闸，再加三层：未知/空名连续失败、同名同参同结果无进展、同名同参总重复。MP 阈值不能照抄 OM 的 10/20/30——它们比 MP 总闸还大；建议先以第 3 次警告、第 5 次阻断、总闸 8 为量级，并让阈值可由遥测校准。参数 hash 忽略显示字段，结果 hash 去易变噪声。
- **代价档位**：天级。
- **风险与前置**：要先统一工具调用规范化（发现 1）。不要逐字照搬 OM：它在未知工具达到阈值后把自造的 `"[LOOP BLOCKED] ... unavailable tool"` 再记入历史：`OM/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift:125-136`；但未知工具提取只认 `unknown tool` 或 `tool X not found/is not available`：`OM/src/ios/Agent/ToolLoopDetector.swift:303-319`。尾部这个自造记录可能让下一次未知 streak 从头计数：`OM/src/ios/Agent/ToolLoopDetector.swift:357-368`。MP 应持久记录明确的 `blockedReason/toolName`，不要再从人类文案反解析。

### 3. P1：MP 的摘要必须绑定分支路径；OM 的线性 marker 不能直接搬

- **OM 怎么做**：OM 的 `RawMessage` 只有 `sessionId`、role、parts、时间和 `sortOrder`，没有 parent/children：`OM/src/ios/Agent/Chat/ChatStore.swift:360-374`。其 compaction marker 用一个线性历史中的 `lastCompactedMessageId` 做锚，定义“锚及以前已压缩，锚以后仍活跃”：`OM/src/ios/Agent/Chat/ChatStore.swift:317-348`；推理时按该锚切出 warm tail、注入摘要、再接锚后消息：`OM/src/ios/Agent/Chat/AIChatViewModel+Persistence.swift:1516-1684`。摘要 prompt 强制保留路径、URL、标识符、命令结果、决策理由、错误与工具状态：`OM/src/ios/Agent/Chat/AIChatViewModel+Compaction.swift:1078-1105`；过大或非网络错误会最多递归分成 8 个叶段再合并：`OM/src/ios/Agent/Chat/AIChatViewModel+Compaction.swift:944-1025`。用户会看到 compacting 状态、分隔线和灰掉的旧历史，并可撤回最新 marker：`OM/src/ios/Agent/Chat/AIChatViewModel+Compaction.swift:409-468`、`OM/src/ios/Agent/Chat/AIChatViewModel+Compaction.swift:805-857`。所谓 fork 也是把消息深拷贝到一个**新 session**，新 session 内仍线性：`OM/src/ios/Agent/Session/SessionForkManager.swift:14-50`。因此 OM compaction 的线性假设已查证。
- **MP 现状**：MP 的消息原生有 `parentId` / `childrenIds`：`MP/Models/Conversation.swift:94-114`；切分支只改 `branchChoices` 并重建 `currentPath`：`MP/ViewModels/ConversationViewModel.swift:1009-1048`、`MP/ViewModels/ConversationViewModel.swift:1064-1069`。但摘要文件只按 conversationId 前 8 位找唯一文件：`MP/Services/SummaryFileStore.swift:19-21`、`MP/Services/SummaryFileStore.swift:36-42`，元数据只有 `conversationId` 与 `coveredCount`：`MP/Services/SummaryFileStore.swift:74-88`。组装时无条件按 conversationId 读摘要：`MP/ViewModels/ConversationViewModel.swift:1833-1836`；切分支没有清摘要。`coveredCount` 的锚定失效只让历史退回滑动窗：`MP/ViewModels/ConversationViewModel.swift:2095-2122`，**不会阻止旧分支摘要继续注入**。自动摘要又把当时 `currentPath` 拍成数组后在 detached task 写回同一会话文件：`MP/ViewModels/ConversationViewModel.swift:3160-3175`，切分支也没有取消或 stale-write guard。
- **差距性质**：实现更优（仅在线性会话内）。
- **采纳建议**：**只借思路**，按 MP 树原生实现。摘要记录至少要带：`anchorNodeId`、从 root 到 anchor 的稳定 path fingerprint、covered node IDs 或边界版本、生成 epoch。发送前只在当前路径仍包含同一锚且 fingerprint 匹配时注入；分支切换后旧摘要可保留给原分支，但不得跨分支复用。异步写回要比较 generation token，旧路径任务晚到时丢弃。不要把 OM 的 sortOrder marker 直接移植。
- **代价档位**：周级。
- **风险与前置**：这是增强 compaction 前必须先修的正确性门槛。需要决定“每分支一份摘要”还是“共享前缀摘要 + 分支尾摘要”；前者简单但文件多，后者复用高但 identity 更复杂。还要处理节点编辑、软删除、恢复使 fingerprint 失效的规则。

### 4. P1：从“消息条数窗”升级为 model/token-aware ContextPolicy + 工具结果外置

- **OM 怎么做**：ContextPolicy 按模型窗口分层：小于 32K 不自动压缩，32–64K 只 offload，64K 以上再自动 compact，并为输出留下 10K–40K 空间：`OM/src/ios/Agent/Chat/ContextPolicy.swift:3-52`；发送前得出 ok / needsCompact / exhausted：`OM/src/ios/Agent/Chat/ContextPolicy.swift:55-90`。每个 agent 迭代还会再次 offload 与检查，最多在同一 turn 自动压缩 3 次，仍满就可恢复地停止：`OM/src/ios/Agent/Chat/AIChatViewModel.swift:4713-4760`。工具结果超过 15000 字会保存到文件，只回首尾或前缀和取回路径：`OM/src/ios/Agent/Chat/AIChatViewModel.swift:14-24`、`OM/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift:918-940`；接近窗口时还能把旧的大工具结果、写入内容和图片外置：`OM/src/ios/Agent/Chat/AIChatViewModel+Offloading.swift:372-428`、`OM/src/ios/Agent/Chat/AIChatViewModel+Offloading.swift:444-544`。
- **MP 现状**：MP 的 preset 虽保存 `maxContextSize`：`MP/Models/Preset.swift:39-50`，但全仓搜索 `maxContextSize` 只找到模型定义和酒馆 JSON 编解码，没有发送/摘要治理调用。实发窗口按 `contextDepth` 的**消息条数**截：`MP/ViewModels/ConversationViewModel.swift:2095-2122`。活动工具循环会把每轮原始 `result.text` 继续塞回请求：`MP/Services/ChatService.swift:348-359`；`fs_read` 可返回全文：`MP/Services/FileLibraryTools.swift:61-71`，MCP 也直接回 `flattenedText`：`MP/Services/MCP/MCPProvider.swift:270-303`。MP 的历史落盘会压成动作行：`MP/ViewModels/ConversationViewModel.swift:2125-2149`，这对**下一用户轮**有利，但同一个 active tool loop 内的 `toolTurns` 仍会持续膨胀。
- **差距性质**：实现更优。
- **采纳建议**：**改造搬**。建立单一 `ContextBudgetSnapshot`，输入包括 system、当前树路径、摘要、记忆/世界书、tool schema、active tool turns、图片估算和输出保留。每次模型请求前（包括工具回灌后的下一轮）检查。先做通用 tool-result 上限与外置指针，再做自动 compaction；这样大量 MCP/fs 输出先被无损外置，仍过窗才有损摘要。
- **代价档位**：周级。
- **风险与前置**：模型窗口来源要有可信优先级（模型目录 → 用户 preset override → 保守默认）；tokenizer 不可用时要有偏保守估算。MP 没有 OM 的 `/var/minis` 通用沙箱，外置应落到 MP 文件库的专用只读 `tool-results/`，并给模型一个受控读取工具，不能把任意宿主路径暴露出去。

### 5. P1：个人记忆与会话压缩必须解耦，不能共用总开关

- **OM 怎么做**：OM 的持久 memory 是两层 Markdown：用户维护的 `GLOBAL.md` 与最近 3 个 daily log 会被注入：`OM/src/ios/Agent/Chat/AIChatViewModel+MemoryTools.swift:9-60`；模型可把偏好、项目模式和重要上下文写入当天日志：`OM/src/ios/Agent/Chat/AIChatViewModel+MemoryTools.swift:63-120`。`memoryEnabled` 同时门控 memory fragments 与 memory tools：`OM/src/ios/Agent/Chat/AIChatViewModel.swift:4473-4490`、`OM/src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift:30-38`；context 检查与 compaction 则在普通发送路径独立运行：`OM/src/ios/Agent/Chat/AIChatViewModel.swift:2217-2259`。
- **MP 现状**：MP 的核心个人记忆是跨会话原子事实，带 category、衰减、出处、楼层隔离与向量：`MP/Models/Memory.swift:16-50`；提取器明确要求原子事实、人物语境、去噪与剧情隔离：`MP/Services/MemoryService.swift:931-966`。这是“记住这个人”。MP 的 ContextSummary 则是会话旧历史的累计有损压缩：`MP/Services/ContextSummarizer.swift:67-110`，这是“让当前对话续得上”。但 `contextSummaryEnabled` 被 `masterEnabled` 连坐：`MP/Services/MemoryService.swift:281-301`。用户因病历问题关闭个人记忆总开关时，会话压缩也被关掉；这两个故障域不该绑定。
- **差距性质**：实现更优（职责边界）。
- **采纳建议**：**只借思路**。把三种东西明确拆开：① Persona Memory（MP 原子事实/画像，跨会话、用户可编辑）；② Session Compaction（当前分支的短期有损摘要，按上下文压力运行）；③ Agent Workspace Memory（项目/任务日志，可选，用文件库或任务 capsule）。保留 MP 的陪伴型核心，不用 OM daily log 替换它；只在 agent 工作流确有跨 session 项目连续性时增加第三层。
- **代价档位**：天级（先拆开关与健康状态）；若新建 workspace memory 则架构级。
- **风险与前置**：先用当前健康状态 UI 在真机确认提取是否恢复，不能从“代码有修复”推断“资产已健康”。Session Compaction 不应因提取模型离线而停摆；其摘要模型失败也应有独立健康状态和 last-success 时间。

### 6. P1：保留 MP 的美元预算，但补齐工具循环逐请求计费与门控

- **OM 怎么做**：点名文件的 RequestBudget 只管理图片字节，不管理美元、token 或轮数：`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:7-38`。OM 的 agent 总次数有 200 次硬上限：`OM/src/ios/Agent/Chat/AIChatViewModel.swift:66-77`，但在本 lane 读到的 iOS 代码里没有与 MP 等价的全局 USD 保险闸。
- **MP 现状**：`GlobalBudgetStore` 默认启用，统一保存 budgetUSD / spentUSD，按实际 cost 累加：`MP/Models/GlobalBudgetStore.swift:3-32`、`MP/Models/GlobalBudgetStore.swift:48-59`；预算 gate 在未拨款、预计超额时阻断，80% 起警告：`MP/Utils/BudgetCalculator.swift:60-78`。但 streaming provider 在有工具调用时走 `onToolCalls(calls)`，不把已经累计的 `finalUsage` 传出去；只有无工具收尾才 `onComplete(..., finalUsage)`：`MP/Services/ChatService.swift:44-57`、`MP/Services/ChatService.swift:506-517`。ViewModel 也只在最终 `onComplete` 提交一次 cost：`MP/ViewModels/ConversationViewModel.swift:2655-2684`；工具回灌递归直接再请求，没有再次预算预检：`MP/ViewModels/ConversationViewModel.swift:2876-2893`。因此一个 8 轮工具 turn 的中间模型调用既不逐次 gate，也不逐次入账。
- **差距性质**：我们更好（但有缺口）。
- **采纳建议**：**改造搬**，不是搬 OM RequestBudget。预算主单位继续用 USD，因为 MP 支持不同价位 provider/model；每次 outbound model request 另记 input/output token、request count、agent round。provider 的 tool-call terminal event也必须带 usage 回 ViewModel，立即 commit；下一次工具回灌请求前重新 gate。若 usage 缺失，用**该次**请求估算值扣，不要复用首发的一份 `pendingEstimatedCost`。
- **代价档位**：天级。
- **风险与前置**：要定义一次用户 turn 内预算不足时如何收尾：停止继续调用工具、保留已有结果、给模型一次低成本“基于现有结果总结”是否会再次超预算。并发与 fallback 上线前必须先完成逐请求记账，否则它们会把漏账放大。

### 7. P2：真正可搬的 `RequestBudget` 是 25MB 图片字节预算

- **OM 怎么做**：OM 从最新图向旧图反向分配 25MB 请求预算，单图按 5MB 计，优先保留最近图片：`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:36-61`。被淘汰的图换成文字指针；有 Linux path 时模型可 `read_image` 取回，没有 path 才要求用户重传：`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:64-110`。应用预算时同时覆盖普通 image part 与工具结果图片，并给用户 toast：`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:113-189`。
- **MP 现状**：MP 只限制**单图** 8MB：`MP/Models/ChatAttachment.swift:22-30`、`MP/Models/ChatAttachment.swift:65-78`；历史只按图片**数量**默认留 20 张：`MP/ViewModels/ConversationViewModel.swift:2027-2056`。OpenAI 请求构建会把命中的每张图全部 base64 内联，没有累计字节闸：`MP/Services/ChatService.swift:410-420`。按现有两个上限，静态最大组合可到 20 × 8MB = 160MB 解码图片数据，远高于 OM 的 25MB 请求闸；真实图片通常更小，但当前 guard 本身允许这个上界。
- **差距性质**：能力缺失。
- **采纳建议**：**改造搬**。在 provider request body 生成前做累计 decoded-byte 预算；最近图片优先，旧图优先使用已生成的文字转述，其次写入 MP 附件/文件库的受控位置并回一个可再取路径。预算值按 provider 能力取最小安全值，不必硬编码所有家都 25MB。
- **代价档位**：天级。
- **风险与前置**：需要保证 placeholder 在 OpenAI、Anthropic、OAuth 三条 wire format 上一致，并防止图片 key 以 message content 作为索引时发生同文碰撞。还应分别统计 base64 wire bytes 与 decoded bytes，provider 报错口径不同。

### 8. P2：并发工具只开放给声明为只读、互不冲突的调用

- **OM 怎么做**：同批 tool uses 最多 10 个并发：`OM/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift:21-25`。TaskGroup 在达到 cap 时先回收完成项；所有结果按原 tool_use 下标重新拼回，满足 provider 的顺序约束：`OM/src/ios/Agent/Chat/AIChatViewModel.swift:5492-5539`。取消会给尚未执行的工具补成配对的错误结果：`OM/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift:92-112`。
- **MP 现状**：MP 对一批 calls 用普通 `for call in calls` 顺序执行；其中 meta/MCP/search/browse 都可能 await：`MP/ViewModels/ConversationViewModel.swift:2730-2753`、`MP/ViewModels/ConversationViewModel.swift:2802-2850`。这保证写入顺序简单，但多个独立 read/search 也被串行化。回灌本身按 call 顺序追加，配对结构是正确的：`MP/Models/ChatToolTypes.swift:19-24`。
- **差距性质**：实现更优。
- **采纳建议**：**只借思路**。在 ToolDefinition 增加 effect 元数据：`readOnly`、`resourceKey(args)`、`requiresMainActor`。只并发 `readOnly` 且 resource 不冲突的 MCP/search/browse/fs_read；fs_write/edit/append/rename/delete、ask_user、会改 turn 状态的工具继续串行。最终仍按模型原始下标回灌。
- **代价档位**：周级。
- **风险与前置**：必须先做预检、逐请求预算和结果大小闸。MP 当前 executor 与 `@MainActor` UI/SwiftData 状态深度耦合，不能简单包 TaskGroup；同批两个写同一文件若并行会破坏模型声明的顺序语义。

### 9. P2：增加请求重试与模型降级链，但须先解决计费和副作用边界

- **OM 怎么做**：网络/瞬时错误在同模型按 3、5、10、15、30 秒重试，并在倒计时期间允许用户换模型：`OM/src/ios/Agent/Chat/AIChatViewModel+Fallback.swift:9-77`。rate limit、invalid key、provider rejection 立即前进到 group 下一个模型；网络重试耗尽后也 fallback，并用 tried set 防回环：`OM/src/ios/Agent/Chat/AIChatViewModel+Fallback.swift:81-111`、`OM/src/ios/Agent/Chat/AIChatViewModel+Fallback.swift:172-223`、`OM/src/ios/Agent/Chat/AIChatViewModel+Fallback.swift:278-358`。HTTP 200 但无文本、无工具、无 reasoning 的“幽灵响应”也会前进候选，直到候选耗尽：`OM/src/ios/Agent/Chat/AIChatViewModel+Fallback.swift:363-438`。
- **MP 现状**：ProviderRouter 为所选 model 解析一张 credential，随后把请求交给这一条 provider；找不到卡/key 就直接 onError：`MP/Services/ChatService.swift:1043-1107`、`MP/Services/ChatService.swift:1110-1139`。ViewModel 收到 onError 后保留 partial、写错误并结束 turn：`MP/ViewModels/ConversationViewModel.swift:2699-2715`。OpenRouter 特定配置可以让上游 provider 自己 fallback：`MP/Services/ChatService.swift:402-405`，但这不是跨 MP credential/model 的通用降级链，也覆盖不了 Anthropic 直连或 OAuth。
- **差距性质**：能力缺失。
- **采纳建议**：**改造搬**。先建立明确错误分类和候选组；同 endpoint 的瞬时网络错误可有限重试，鉴权/限流/永久拒绝换候选；空响应单独识别。每个候选最多一次，完整记录 trail 给用户。切模型时必须重算 max tokens、上下文窗口、tool schema 能力和价格，不能只换 model id。
- **代价档位**：架构级。
- **风险与前置**：重试模型请求本身通常还没执行工具，但流中断可能已经产生部分 tool call；必须先定义“未完整 parse 的 tool call 不执行”和 idempotency key。发现 1、4、6 是前置。否则 fallback 会把缺参写、超窗和漏账各放大一遍。

### 10. P3：`@文件` 只学显式选择 UX，不搬全设备目录扫描

- **OM 怎么做**：OM 的 mention index 分三层扫描 session、shared/skills/memory、外部 mounts，10 分钟缓存、渐进发布，mount 深度 3、总预算 5000、结果上限 100：`OM/src/ios/Agent/Chat/FileMentionIndex.swift:81-116`、`OM/src/ios/Agent/Chat/FileMentionIndex.swift:180-238`。选择后只是把 `@/var/minis/...` 路径写进输入框，不直接塞文件正文：`OM/src/ios/Agent/Chat/AIChatViewModel+MentionMenu.swift:207-244`。
- **MP 现状**：全仓对 `FileMention`、`mentionFilter`、`mentionMenu`、`@提及` 的 Swift 搜索无命中，故没有等价输入菜单。MP 已把文件库内容改成 pull：system 只列最多 50 个名字，正文让模型按需 fs_read；可选旧开关才内联全文：`MP/ViewModels/ConversationViewModel.swift:2461-2498`。因此能力缺失只在“用户显式挑一个上下文文件”的 UX，不在 pull 机制本身。
- **差距性质**：能力缺失（低优先级）。
- **采纳建议**：**只借思路**。在 MP composer 提供 `@文件库路径` 选择器，数据源只用现成 `FileLibraryStore.list` 与当前附件，不扫描任意外部 mount；发送后把 path 变成结构化 context reference，让模型按需 fs_read。
- **代价档位**：天级。
- **风险与前置**：要定义路径 rename 后的历史显示与解析；不要把 5000 项扫描、10 分钟缓存、外部目录权限复杂度一起搬进陪伴型客户端。

## 优先级排序

1. **先做 ToolPreflight**：它直接挡住缺 `content` 把文件写空，且已有统一 schema，可用最小改动落地。
2. **再修摘要的分支身份，并拆开个人记忆/会话压缩开关**：否则越积极压缩，越可能把旧分支背景带到新分支。
3. **补 ToolLoopDetector + 每次模型请求的预算 gate/usage**：一个防转圈，一个防漏账；二者共享“每请求/每工具调用观测”地基。
4. **做 token-aware ContextPolicy 与工具结果外置**：先无损减重，再有损摘要；每个工具回灌轮都检查。
5. **补图片累计字节预算**：实现局部，能避免 provider 413/空响应与大 body 内存峰值。
6. **最后才是 fallback、并发工具、`@文件`**：它们提升可用性或速度，却也会增加请求数与副作用面，必须建立在前五项之上。

## 已核对但无需重复立项

- **MCP 工具海方向已落地**：超过 16 个时 MP 用 `tool_search / tool_inspect / tool_invoke`，不再全量内联：`MP/ViewModels/ConversationViewModel.swift:2337-2381`、`MP/ViewModels/ConversationViewModel.swift:2405-2415`。OM 的 canonical ToolDefinitions 只是固定内建工具 + 条件 memory/read_image：`OM/src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift:30-38`、`OM/src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift:124-194`，没有比 MP 更好的 defer 方案。
- **MCP 可用性已不绑 live connection**：MP 用持久化工具列表暴露 schema，调用时按需重连并失败后再重连一次：`MP/Services/MCP/MCPProvider.swift:232-245`、`MP/Services/MCP/MCPProvider.swift:270-303`。文件顶部第 35 行的旧注释仍写“connected + tool.enabled”，但实现已经相反；这是注释漂移，不是功能缺口：`MP/Services/MCP/MCPProvider.swift:34-38`。
- **验证边界**：没有运行 app、没有看网络 trace、没有查当前真机 store、没有测 token 估算或延迟；所以报告不声称 compaction、记忆提取、fallback 或预算在真实设备上工作。静态上“当前代码路径存在”不等于运行时已验收。

## §反向发现

1. **MP 的 `ask_user` 暂停/恢复比 OM 完整**。MP 把整轮恢复参数、既有工具结果和题面封装进 pending 状态：`MP/ViewModels/ConversationViewModel.swift:1480-1507`；回答后落成真实 user 节点，再把严格配对的 tool result 接回工具循环：`MP/ViewModels/ConversationViewModel.swift:1569-1636`。OM 的 canonical iOS 工具定义中没有 ask-user 工具：`OM/src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift:30-194`；另以 `rg -n "ask_user|AskUser" OM/src/ios/Agent` 确认无命中。MP 这块不要重写成普通文本追问。
2. **MP 的全局 USD 保险闸比 OM 此 lane 的 RequestBudget 更贴合多 provider 产品**。MP 在请求前估价、发送后按 usage 精算：`MP/ViewModels/ConversationViewModel.swift:3778-3829`；OM 点名文件只管图片字节：`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:11-61`。应修 MP 的工具轮漏账，而不是换掉单位。
3. **MP 对工具海的 defer/meta-tools 已领先**。MP 只在 MCP catalog >16 时换 3 个元工具：`MP/ViewModels/ConversationViewModel.swift:2337-2381`；OM 的 `makeAgentTools` 返回固定大 schema，并无目录式按需暴露：`OM/src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift:30-194`。
4. **MP 的个人记忆可审计性更适合陪伴产品**。Memory 有逐字 quote 与 source node：`MP/Models/Memory.swift:27-34`；新增记忆必须通过 quote 机械校验并定位来源：`MP/Services/MemoryService.swift:1003-1036`；用户可手动添加和编辑：`MP/Views/MemorySettingsTab.swift:385-417`、`MP/Views/MemorySettingsTab.swift:542-559`。OM daily memory 是模型把自由 Markdown prepend 到当天文件：`OM/src/ios/Agent/Chat/AIChatViewModel+MemoryTools.swift:63-120`。病历说明 MP 的运行质量曾不健康，但不改变“来源锚 + 可编辑原子事实”更符合陪伴定位的架构优势。
5. **MP 的低总闸更省钱**。MP 名义上 8 轮即停：`MP/ViewModels/ConversationViewModel.swift:2335-2340`、`MP/ViewModels/ConversationViewModel.swift:2876-2885`；OM 允许 200 个 agent turns：`OM/src/ios/Agent/Chat/AIChatViewModel.swift:66-77`。MP 需要修 off-by-one 并补进展检测，但不应把总闸抬到 200。

## §不建议学

1. **不搬 OM 的 200-turn 总上限与 10/20/30 默认阈值**。对手机陪伴客户端和私人 key 来说代价过高，也与 MP 的 8 轮产品选择冲突。借检测策略，阈值按 MP 成本边界重定。
2. **不搬 OM 的线性 `lastCompactedMessageId` 作为 MP 唯一摘要身份**。MP 是一棵树；必须携带当前分支 path fingerprint / anchor node，而不是把树临时当 list。
3. **不让 OM daily logs 替换 MP 原子个人记忆**。daily log 适合“这个项目做过什么”，不适合稳定回答“这个人是谁”；需要项目连续性时加第三层 workspace memory，不能混库。
4. **不搬 OM 的全 mount `@` 扫描和固定大工具 schema**。MP 已有文件库边界与 meta-tools；扩大到宿主目录会带来权限、隐私、索引和缓存复杂度，收益不成比例。
5. **不照搬模糊字段名/类型强转到写工具**。OM 已经因为截断写入风险而专门拒绝 file_write/file_edit：`OM/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift:186-240`。MP 第一版应宁可报错让模型重发，也不要猜用户文件写入参数。
