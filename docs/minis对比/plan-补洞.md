# Plan：补 minis 对比挖出的洞（剩五个）

> 2026-09-02 · 粟粟「那几个大漏勺现在补了多少了，是不是还剩一些没补，你去看看并且走流程」。
> research = `对比报告.md` §一（八个洞，全部车头亲验）。本文 = 现状盘点 + 剩余五个的修法契约 + lane 切分。
> **状态：⧫ 粟粟 09-02 拍「H-C 先不管，别的按你推荐」→ go。** 洞 6 整份跳过 / 洞 5 标注 / 洞 7 只修 bug / 洞 2 搁置。

## 一、现状（09-02 车头亲查代码，不是看 log 猜）

| 洞 | 状态 | 证据 |
|---|---|---|
| 1 `fs_write` 缺 content 清空文件 | ✅ **已修** 08-25 `63af9ec2` | `Services/Tools/ToolCallPreflight.swift` 接在 `ConversationViewModel.swift:2820` 所有 executor 之前；`ToolCallPreflightTests` 9 测；`str()` helper 还在但已被前置校验挡住 |
| 4 未知 provider type 清空凭据 | ✅ **已修** 08-25 | `APIProvider.swift:1240-1243` 解码失败不再 `?? []`；enum 注释直接写「对比线洞 4」 |
| 8 流式 O(N²) | ⚪ **已降级** 09-02 | 观感层 `StreamPacer` 早已解决；剩 CPU 债跟 B3（`research-input-jank.md`）走，不在本 plan |
| **2** 摘要跨分支污染 | ❌ 未动 | `SummaryFileStore.swift:76-81` 元数据仍只有 conversationId/coveredCount/updatedAt |
| **3** 工具循环中间请求不记账不 gate | ❌ 未动 | `ChatService.swift:53` `onToolCalls: (([ToolCallBlock]) -> Void)?` 仍不带 usage；`preCheckBudget` 只在主发送/重生成/编辑重发三处，回灌递归（`ConversationViewModel.swift:2886-2893`）无 gate |
| **5** MCP OAuth 是配置壳 | ❌ 未动 | `MCPSettingsView.swift:20-41` 仍让用户填 oauthClientId/Secret；`MCPTransport.swift:12-20` 工厂只读 url+headers |
| **6** 同步/备份还原跨楼层偷数据 | ❌ 未动 | scoped check 三处：`BackupStore.swift:424`、`SyncStore.swift:448`、`SyncStore.swift:514`；两文件零处调用 `crossProfileConflictedConversationIds` |
| **7** 跨楼层通知静默失败 | ❌ 未动 | `ContentView.swift:709-717` 原样：先删 key → 按当前楼层过滤 → 静默 return |

## 二、五个洞的修法契约

冻结**目标和验收**，不冻结机制——实现路径、测试组织、微设计是 worker 的。

### 洞 6 · 同步/备份还原跨楼层偷数据 【天级】

- **病根**：`Conversation.id` 全库 unique、`profileId` 普通列。还原路径按 `id == convId && profileId == pid` 查重，另一楼层同 id 存在时查不到 → insert → SwiftData unique 冲突静默 **upsert** → 改写那行全部属性含 `profileId` → 对话被偷到当前楼层。三处：`BackupStore.swift:424`（`restoreConversation`）、`SyncStore.swift:448`、`SyncStore.swift:514`（`importAll`）。
- **目标**：任何 Conversation/MessageNode insert 之前，先用**已有的** `crossProfileConflictedConversationIds`（`ImportSupport.swift:80`，四处导入路径已在用）查跨楼层冲突。命中 → **整份对话跳过**并计入返回结果（不做部分 insert）。
- **⧫ 设计点**：冲突时「整份跳过」vs「整份确定性改 id」。**推荐跳过**——最安全、可逆、一行调用；改 id 要同时改 conversation/node/parentId/childrenIds/currentNodeId，出错面大，且「同 id 在另一楼层」本身就该让用户知道而不是静默改。跳过的对话数要回到 UI（还原结果 sheet / 同步日志）。
- **验收**：
  - `SyncStoreTests` / 新 `BackupStoreTests`：种子楼层 A 有对话 X；以楼层 B 身份还原/入站一份含 X 的文档 → X 仍属 A、属性未变、B 侧无 X、返回结果报告 1 条跳过。三条路径各一测。
  - 全库还原（若语义上允许覆盖 profile 归属）单独一测，行为按现有语义不变。
- **影响面**：只动两个 Service 文件的三个函数 + 测试。UI 侧只是把跳过数展示出来（若现有结果结构已有计数字段就复用）。
- **前置**：无。

### 洞 7 · 跨楼层通知点了没反应 【天级】

- **病根**：`ContentView.consumePendingPushTarget`（`:709-717`）① 先 `removeObject` pending key ② 用**当前楼层** pid 过滤 ③ fetch 空就 `return`。推送 `chat_id` 是全局 unique 的 `Conversation.id`，属于非当前楼层时三步叠加 = 点了通知、app 打开、什么都不发生、key 已没了。
- **目标**：按 id **全库**查到对话 → 读它真实的 `profileId` → 不同就先 `ProfileManager.switchTo`（`MemoryPalaceApp.swift:206`，注意它同步广播清旧 SwiftData 引用再切 currentProfile，导航必须等 subtree 就绪）→ 导航 → **成功或明确 terminal failure（对话已永久删除 / 楼层已删除）之后才消费 pending key**。
- **⧫ 设计点**：要不要顺手做 `AppRoute` 统一路由（对比报告 §二 C2）？**推荐不做**——本条只修 bug，C2 是新功能等 App Intents 一起立项。但修法应该写成一个独立的 `resolvePushTarget(chatId) -> (Conversation, needsSwitchTo: Profile?)?` 之类的纯函数，C2 来的时候直接复用。
- **验收**：
  - 单测：resolve 函数三个 case——同楼层 / 异楼层 / 不存在。
  - 模拟器实证：楼层 A 对话 X，切到楼层 B，用 `xcrun simctl push` 投一条 `chat_id=X` 的通知 → 点开 → 落在 A 的 X 上；再投一条不存在的 id → 不崩、key 被清、有可见反馈（toast 或日志，至少不是静默）。
- **影响面**：`ContentView.swift` 一个函数 + 可能一个新 helper 文件 + 测试。不动 `PushNotifications.swift`（存 key 那边没错）。
- **前置**：无。可与洞 6 同一条 lane（同一类病：scoped fetch 漏楼层）。

### 洞 3 · 工具循环中间请求不记账不 gate 【天级】

- **病根**：`onToolCalls` 签名不带 `TokenUsage`（`ChatService.swift:53`），四个触发点（`:151` 非流式整包 / `:646` OpenAI 流式 / `:1160` Anthropic 流式 / `:1270` router 透传）都不传 usage；VM 消费点（`ConversationViewModel.swift:2797`）只在最终 `onComplete` 提交一次 cost；回灌递归（`:2886-2893`）直接再请求不过 `preCheckBudget`。8 轮工具 = 9 次请求，中间 8 次的 token **花了不记、也不 gate**。顺带：`guard round < maxToolRounds` 在工具执行**后**检查、round 从 0 起 → 实际执行 9 批才停，文案说 8 轮（off-by-one）。
- **目标**：
  1. tool-call 终止事件带 usage 回 VM（签名改 `(([ToolCallBlock], TokenUsage?) -> Void)?`，或另开一条 `onToolCallsUsage` 通道——机制 worker 定）；四个触发点都传；VM 收到立即 commit 到 `GlobalBudgetStore`。
  2. 回灌递归前重新 `preCheckBudget`（估算用**本轮**请求的 payload，不复用首发那份 `pendingEstimatedCost`）；预算不足时的收尾语义：停止继续调工具、保留已有工具结果、给模型一次「基于现有结果总结」的机会（这次也要过 gate，过不了就直接结束并显示）。
  3. off-by-one：文案与实际批次数对齐（改判定位置或改文案，二选一，不要两边都动）。
- **⧫ 设计点**：usage 缺失时（部分 provider 流式不给中间 usage）用该次请求的估算值扣。**推荐**估算扣而不是不扣——宁可多扣。
- **验收**：
  - `BudgetGateTests` 扩：mock 一个 3 轮工具循环，断言 commit 次数 = 4（3 中间 + 1 最终）、每次 usage 或估算值非零；第 2 轮前把预算调到不足 → 断言循环停在第 2 轮、已有结果保留、收尾文案出现。
  - 4 个触发点各一个最小测试（已有的 mock SSE 夹具应该能复用）。
- **影响面**：`ChatService.swift` 5 处 + `ConversationViewModel.swift` 工具循环段 + `BudgetGateTests`。**不动** ccBridge（它不走这条 provider 链）。
- **前置**：无。

### 洞 5 · MCP OAuth 是配置壳 【小时级】

- **病根**：`MCPServerConfig` 有 `oauthClientId/oauthClientSecret`，`MCPSettingsView.swift:20-41` 让用户填，secret 还进 Keychain；`MCPTransportFactory.makeTransport`（`MCPTransport.swift:12-20`）只消费 url + headers。全仓无授权 URL、PKCE、token 交换、refresh、注入 header 的路径。用户填完以为配好了，什么都不发生。
- **⧫ 设计点**：**这次只做标注，不做实现**。实现是周级（static PKCE + 双端回调 + Keychain + 单飞 refresh），且 MCP 本身现在是全局生效没有作用域（对比报告 §二 F1），OAuth 实现应该跟作用域一起立项。推荐本次：编辑 sheet 里两个 oauth 字段加「暂未支持——填写不会生效」的副文案（按 MP 设置页文案规则：只描述功能，不写为什么），或直接隐藏字段保留模型不动。**二选一粟粟拍**：标注（诚实、不丢数据）/ 隐藏（干净、用户看不到没做的东西）。
- **验收**：模拟器截图一张（标注版）或字段确实不露出（隐藏版）；`MCPServerConfig` 模型不改、已存的值不丢。
- **影响面**：`MCPSettingsView.swift` 一处。
- **前置**：无。**车头自己做，不派 lane。**

### 洞 2 · 摘要跨分支污染 【周级】

- **病根**：`SummaryFileStore` 一个对话**一份**摘要，按 conversationId 前 8 位寻址（`:19-21, 36-42`），元数据只有 conversationId/coveredCount/updatedAt（`:76-81`）。消息是树（`Conversation.swift:94-114` parentId/childrenIds），切分支只改 `branchChoices` 重建 `currentPath`，摘要寻址不看分支 → 分支 A 生成的摘要切到 B 后照样注入。自动摘要把当时 `currentPath` 拍进 detached task 写回同一文件（`ConversationViewModel.swift:3160-3175`），切分支时不取消、无 stale-write 守卫。
- **目标**：摘要记录带**分支身份**；发送前只在当前路径匹配时注入；异步写回带 generation token，旧路径任务晚到就丢弃。
- **⧫ 设计点（架构方向，必须粟粟拍）**：
  - **A · 每分支一份摘要**：文件名/key = conversationId + 从 root 到 anchor 的路径指纹（稳定 hash）。切分支 = 换 key 找文件，找不到就从头积累。**简单、可逆、文件多**（一个对话有几条活跃分支就几份）。
  - **B · 共享前缀 + 分支尾**：公共祖先段一份、各分支尾各一份，注入时拼。**复用高、identity 复杂**（编辑/软删/恢复都要处理 fingerprint 失效）。
  - **推荐 A**——MP 现在就是「一对话一份」，改成「一（对话+路径）一份」是最小改动；B 是优化，等 A 跑起来看文件量再说。Minis 的线性 `lastCompactedMessageId` marker **不搬**（它的会话是线性的）。
- **验收**：
  - 单测：对话 X 在分支 A 积累摘要 S_A → 切到分支 B → 组装 prompt 断言不含 S_A → B 上积累 S_B → 切回 A 断言注入 S_A 不含 S_B。
  - 单测：A 上触发自动摘要（detached）→ 未完成时切到 B → 任务回来 → 断言 A 的文件被更新、B 的不受影响、无 stale write 进错文件。
  - 现有摘要文件的迁移：老文件（无路径指纹）挂到「当前 currentPath」一次性迁移，或标为 legacy 只在主分支注入——**worker 定，plan 里说清即可**。
- **影响面**：`SummaryFileStore.swift`、`ContextSummarizer.swift`、`ConversationViewModel.swift` 摘要触发/组装/写回三段、`PromptAssembler` 注入点、迁移。**这是五个里最重的**，且碰 prompt 组装——粟粟本周在想记忆方案，这条要不要现在做值得单独问。
- **前置**：无硬前置，但**建议排最后**。

## 三、lane 切分与席位

| lane | 洞 | 席位 | 代价 | 隔离 |
|---|---|---|---|---|
| H-A | 6 + 7（同病：scoped fetch 漏楼层） | opus5（Agent，`isolation: worktree`） | 天级 | worktree |
| H-B | 3（工具循环记账） | codex gpt-5.6-sol | 天级 | worktree |
| H-C | 2（摘要分支身份） | opus5 | 周级 | worktree，**⧫ 是否本批做** |
| — | 5（标注/隐藏） | 车头自己 | 小时级 | master 直接改 |
| H-Q | QA：全套测试 + 双端 build + 洞 7 **模拟器**实证 | codex fresh | — | 收口时跑。**⧫ 粟粟 09-02：千万别装实机——本批次任何环节不装 Air / 14，模拟器为止** |

席位跨两个 family（opus5 / codex）且跨两个配额池（08-24 教训）。`seat-quota` 09-02：claude 5h 1% / codex 5h 0%——都空。

**A/B 可并行**，C 若做则并行；三条互不碰同一文件（A: BackupStore/SyncStore/ContentView · B: ChatService/ConversationViewModel 工具循环段 · C: SummaryFileStore/ContextSummarizer/ConversationViewModel 摘要段）。**B 和 C 都碰 `ConversationViewModel.swift`** 但不同段——合并时可能撞 hunk，收口时车头亲手合，不让 worker 互相 rebase。

## 四、实施纪律（写进每份任务书）

- 「你是执行阶段，MP 的 research→plan→wait 三步流程不适用于你」——08-25 教训，worker 读 CLAUDE.md 会自己停下等批。
- **先写失败测试复现，再修，再绿**。每个洞至少一条测试是「修前红、修后绿」。
- `xcodebuild` 走 `~/.local/bin` shim，**禁 `-derivedDataPath`**（09-01 机器过载事故）。子 agent 想 build 就排队。
- 每完成一项 commit + push（worktree 分支），报告先写骨架再逐节覆盖（08-28 教训）。
- lane 在飞期间**车头不在 master 工作树做任何 git 操作**（08-30 教训）。
- 收隔离进程只从 `$!` 拿 pid，禁 `pgrep -f`。

## 五、todo

**等 ⧫ 的决策点（四个）**：
- [x] 洞 6 冲突时：**整份跳过** ⧫
- [x] 洞 5：**标注** ⧫
- [x] 洞 2：**本批不做** ⧫（「H-C 先不管」）
- [x] 洞 7：**只修 bug，不做 AppRoute** ⧫

**实施（go 之后）**：
- [ ] 车头：洞 5 标注/隐藏，master 直接 commit
- [ ] 车头：读 worker-profiles（08-30 改过）+ 写三份任务书到 `trace/`
- [ ] H-A 派单（洞 6+7）
- [ ] H-B 派单（洞 3）
- [~] ~~H-C 派单（洞 2）~~ 搁置
- [ ] 收货：逐份亲读报告 + diff 抽查
- [ ] H-Q：全套测试 + 双端 build + 洞 7 模拟器实证（**不装实机** ⧫）
- [ ] 合并 master + xcodegen + build + push
- [ ] 更新 `对比报告.md` §一 状态列 + NOW.md
- [ ] review-补洞.md（边界 / 与记忆方案的交互 / 技术债）
