# L1 报告：系统公民身份——入口、快捷指令、扩展、深链

## TL;DR

| 发现 | 差距性质 | 采纳建议 | 代价档位 |
|---|---|---|---|
| L1-1. 先把“楼层 / 对话”做成系统实体，再上 4 个基础 App Intents | 能力缺失 | 改造搬：按 MP 架构原生实现 `楼层实体 + 对话实体 + 打开对话 + 问记忆花园 + 发送/继续对话`；状态查询放第二阶段 | 天级 |
| L1-2. 无头 Shortcuts 不能直连现有 WebSocket；先建持久化 run 与 bridge ack | 能力缺失；OM 的可观测性实现更优 | 只借思路：返回持久化 `runId`，以 accepted/running/completed/failed 为真相；不搬 OM 的静音音频保活 | 架构级 |
| L1-3. Share Extension 值得做，但 MP 的对等物应是“分享收件箱 + 目的地选择” | 能力缺失 | 改造搬：扩展只暂存，主 app 决定进聊天、文件库、书架、对话导入或贴纸导入；不自动发送 | 周级 |
| L1-4. MP 已有推送深链底子，但跨楼层通知会静态丢目标 | 实现更优（OM 的统一路由）；MP 有确认缺陷 | 改造搬：先收跨楼层 bug，再让 Push / Intent / Share / URL 全走一个 `AppRoute` | 天级 |
| L1-5. 应写正式 URL spec，但不能照抄 OM：它的资源 spec 与实际导航路由、解析器已经漂移 | 能力缺失；不适合直接搬 | 只借格式：外部导航 scheme 与内部文件引用分离；v1 只寻址楼层、对话、消息、书和设置 | 天级 |
| L1-6. Live Activity 有产品价值，但它只能展示任务，不能替代后台执行 | 能力缺失 | 只借状态模型与隐私设计；等远端 run 真相和更新通道就绪后再做 | 架构级 |
| L1-7. 现在不该上 File Provider；先统一并验证 MP 现有 Documents / iCloud 声明 | 不适用；MP 的文件边界更贴产品 | 不建议；若未来确需，仅暴露用户明确选择的交换区，不挂私有记忆/数据库 | 小时级（配置收口）；File Provider 本体周级 |
| L1-8. “普通 Widget 对齐”是伪差距：OM 的 Widget target 只承载 Live Activity | 不适用 | 不建议为了 parity 建桌面 Widget；有独立用户任务再立项 | 不适用 |

> 证据路径约定：`OM/` 代表 COMMON 指定的只读 clone：`/private/tmp/claude-501/-Users-susu-Desktop-susu-project------MemoryPalace/21f01c6d-ed23-4569-b935-7bb3469bb3ec/scratchpad/OpenMinis/`。MP 路径均相对本仓根目录。

## 盘点口径

- 我完整读了 MP 的 `project.yml`、两份 iOS plist、iOS entitlements，并对 `MemoryPalace/**/*.swift` 搜索了 `AppIntents` / `AppIntent` / `AppEntity` / `AppShortcutsProvider` / `ActivityKit` / `WidgetKit` / `FileProvider` / `.onOpenURL`；这些源码级入口均为 0 命中。MP 当前 iOS target 只嵌入 Push NSE；全项目 target 是 macOS/iOS 两个主 app、Push NSE 与测试，没有 Share / Widget / File Provider extension：`project.yml:36-43`、`project.yml:116-132`、`project.yml:188-239`。
- 我对 plist 的判断只到“源码配置意图”。`project.yml` 同时声明 `info.path = MemoryPalace/Info-iOS.plist` 和显式 `INFOPLIST_FILE = MemoryPalaceIOS-Info.plist`：`project.yml:133-147`、`project.yml:157-175`。后者自己也说明前者的 `info.properties` 没进入实际 plist：`MemoryPalaceIOS-Info.plist:5-12`。任务禁止 xcodegen/build，因此最终包内 Info.plist 未查证。
- 设备能力工具族（Calendar / Reminders / Clipboard / Vision / Notification / `open_url` 等）归并行线；本报告只在判断 `QuickTaskIntent` 是否通用时确认它与这些工具绑定，不拆它们的实现。

### L1-1. 先把“楼层 / 对话”做成系统实体，再上 4 个基础 App Intents

- **OM 怎么做**：`SessionEntity` 把会话 ID、显示名、模型 ID 包成 `AppEntity`，系统可按 ID 反查，也可给出最多 100 个建议会话：`OM/src/ios/Agent/Intents/SessionEntity.swift:4-27`、`OM/src/ios/Agent/Intents/SessionEntity.swift:30-44`。`MinisShortcutsProvider` 把 Ask、Quick Task、Send Prompt、Status、List、Follow Up、Open Session 注册成零配置 App Shortcuts：`OM/src/ios/Agent/Intents/MinisShortcutsProvider.swift:13-31`、`OM/src/ios/Agent/Intents/MinisShortcutsProvider.swift:32-89`。其中 Ask 打开 app 并复用正常发送/导航管线，Send Prompt 则可不打开 app：`OM/src/ios/Agent/Intents/AskMinisIntent.swift:6-20`、`OM/src/ios/Agent/Intents/AskMinisIntent.swift:48-88`、`OM/src/ios/Agent/Intents/SendPromptIntent.swift:6-12`。
- **MP 现状**：无 App Intents 源码。实际 plist 里的 `NSUserActivityTypes = INSendMessageIntent` 是通信通知声明，不是 App Intents action：`MemoryPalaceIOS-Info.plist:40-43`；构建配置注释也明确它服务于 Communication Notification：`project.yml:148-152`。MP 的可寻址基础对象更复杂：`Conversation.id` 全局 unique，但每条数据又必须带 `profileId` 做楼层隔离：`MemoryPalace/Models/Conversation.swift:14-21`；消息也有 unique ID、`profileId` 与 `conversationId`：`MemoryPalace/Models/Conversation.swift:94-114`。
- **差距性质**：能力缺失。
- **采纳建议**：**改造搬**，按 MP 架构原生实现，而不是复制 OM 文件。通用形态按优先级分两层：
  1. 1.0.x 可先做 `楼层实体(ProfileEntity)`、`对话实体(ConversationEntity)`、`打开对话`、`问记忆花园`（打开 app 后发送）、`发送到对话/继续对话`（第一版允许打开 app）。
  2. 有了 L1-2 的持久化 run 后，再开放真正无头的 `发送提示`、`查询任务状态` 和结构化结果串联。
  `ConversationEntity` 必须同时携带 `profileId`，建议项按当前楼层和最近打开排序，并提供字符串查询；不要照搬 OM 的固定 `prefix(100)`，否则 MP 的大量历史对话在系统选择器里不可达。模型选择不是首发必需项；楼层与对话才是 MP 的核心对象。
- **代价档位**：天级（打开 app 的第一阶段）；无头执行另见 L1-2。
- **风险与前置**：iOS-only 文件必须 `#if os(iOS)` 或放进独立 target/source 列表；MP 的 macOS/iOS 主 target 都直接吃整个 `MemoryPalace` 目录：`project.yml:37-45`、`project.yml:116-123`。还要处理 app 锁、回收站对象、楼层切换和 1,700+ 对话的实体查询性能。OM 为 iOS 16 留了 AppIntent 元数据崩溃规避：`OM/src/ios/Agent/Intents/MinisShortcutsProvider.swift:78-81`；MP 最低 iOS 26：`project.yml:116-120`，不需要原样背这层兼容债。

### L1-2. 无头 Shortcuts 不能直连现有 WebSocket；先建持久化 run 与 bridge ack

- **OM 怎么做**：`SendPromptIntent` 支持附件、已有会话、模型、等待完整结果、是否通知，并返回结构化 `SendPromptResult`：`OM/src/ios/Agent/Intents/SendPromptIntent.swift:21-41`、`OM/src/ios/Agent/Intents/SendPromptIntent.swift:187-253`；结果实体公开 session、模型、状态、prompt 与 response 字段，供后续 Shortcut action 使用：`OM/src/ios/Agent/Intents/SendPromptResult.swift:4-44`。为了追踪“系统叫醒 app 后任务到底有没有跑完”，`ShortcutRunTracker` 在 `perform()` 顶部记录保活/权限快照，落持久 pending marker，结束时清掉：`OM/src/ios/Agent/Intents/ShortcutRunTracker.swift:7-29`、`OM/src/ios/Agent/Intents/ShortcutRunTracker.swift:96-133`；前台回来时，它不会把丢失 completion signal 直接当失败，而是去数据库找 startedAt 之后的真实 assistant reply：`OM/src/ios/Agent/Intents/ShortcutRunTracker.swift:138-157`、`OM/src/ios/Agent/Intents/ShortcutRunTracker.swift:188-219`、`OM/src/ios/Agent/Intents/ShortcutRunTracker.swift:254-296`。
- **MP 现状**：cc-bridge 当前 `send` 要求进程里已有 WebSocket task；没有就立即返回“未连接”：`MemoryPalace/Services/CCBridgeWebSocketClient.swift:367-385`。聊天发送的冷启动兜底会先异步 `connect`，随即调用 `sendUserMessage`；发送错误只打 DEBUG 日志，不产生持久提交状态：`MemoryPalace/ViewModels/ConversationViewModel.swift:2899-2926`、`MemoryPalace/Services/CCBridgeWebSocketClient.swift:407-441`。等待状态只是内存里的 10 分钟 UI 标记：`MemoryPalace/ViewModels/ConversationViewModel.swift:2927-2936`。因此，**推断**：如果无头 AppIntent 在 app/WS 未就绪时复用现路径，它无法证明 prompt 已被 hub 接受；“hub 可能 replay reply”不等于“提交已持久化”。
- **差距性质**：能力缺失；OM 在失败可观测性上实现更优，但其执行保活机制不适合 MP 原样采用。
- **采纳建议**：**只借思路**。按 MP 架构原生增加 durable `AutomationRun`/`BridgeRun`：至少持久化 `runId`、intent、profileId、conversationId、idempotencyKey、submittedAt、acceptedAt、completedAt、status、error、responseRef。AppIntent 只有在本地 outbox 已落盘、或 hub 明确 ack 后才返回 `accepted`；bridge 离线时应返回可判定的 queued/failed，而不是静默 fire-and-forget。系统结果先返回 `runId + conversation entity + status`，`查询任务状态` 再读同一真相；完成后可复用现有 APNs 入口。
- **代价档位**：架构级。
- **风险与前置**：要先定重复调用的幂等键、hub ack/replay 合同、取消语义、桥离线/换地址、API provider 与 cc-bridge 是否共用 run 模型，以及锁屏状态下可返回多少内容。OM 的 pending marker 仍可能因新会话使用 placeholder session ID 而无法做 DB completion 验证：`OM/src/ios/Agent/Intents/SendPromptIntent.swift:81-97`、`OM/src/ios/Agent/Intents/ShortcutRunTracker.swift:247-251`；MP 不应复制这个身份交换缺口。

### L1-3. Share Extension 值得做，但 MP 的对等物应是“分享收件箱 + 目的地选择”

- **OM 怎么做**：Share Extension 接文本、单个 URL、最多 10 张图、5 个视频和 5 个文件：`OM/src/ios/ShareExtension/Info.plist:5-26`。扩展把文本或附件复制到 App Group，写一份 `PendingShare`；主 app 和扩展共享的 store 只保存 JSON marker 与临时文件目录：`OM/src/ios/ShareExtension/ShareExtension.entitlements:5-8`、`OM/src/ios/Shared/SharedContainerStore.swift:3-19`、`OM/src/ios/Shared/SharedContainerStore.swift:23-56`。连续分享会在 300 秒内合并而不是覆盖：`OM/src/ios/ShareExtension/ShareViewModel.swift:39-59`。主 app 最后把文字放入 composer、把文件变成聊天附件，再清理临时目录：`OM/src/ios/Views/Chat/AIChatView.swift:1588-1639`。
- **MP 现状**：无 Share Extension target；`project.yml` 的 iOS app 只嵌 Push NSE：`project.yml:116-132`。但 MP 已有可复用的目的地：聊天附件入口接受任意 data 且可多选：`MemoryPalace/Views/CardFlowView.swift:1295-1300`；对话导入接 JSON：`MemoryPalace/Views/ImportView.swift:249-271`；书架接 txt/pdf 并先让用户补书名/作者：`MemoryPalace/Views/Reading/BookshelfView.swift:67-88`；贴纸接 `.stickerpack`：`MemoryPalace/Views/StickerSettingsTab.swift:267-276`。主 app 与 Push NSE 已共享 App Group：`MemoryPalaceIOS.entitlements:25-28`、`MemoryPalacePushNSE/MemoryPalacePushNSE.entitlements:5-8`。
- **差距性质**：能力缺失。
- **采纳建议**：**改造搬**。扩展只做类型识别、security-scoped copy、写入 `incoming-share/` 的轻量 DTO；不要在 extension 里开 SwiftData 或直接写楼层文件库。主 app 醒来后显示中文目的地 sheet：
  - 文本/URL：填入新对话或指定对话草稿；
  - 图片/普通文件：作为聊天附件，或“存到本楼层文件库”；
  - txt/pdf：给“加入书架”入口；
  - `conversations.json`：进入 ChatGPT/Claude 导入确认；
  - `.stickerpack`：进入贴纸导入确认。
  默认不自动发送给模型，也不默认交给 cc-bridge；这保留了 MP“自己的文件是自己的文件”的边界。
- **代价档位**：周级（若只做“文字/URL/文件 → 新对话草稿”，可压到天级）。
- **风险与前置**：需明确当前楼层/目标对话选择、并发分享合并、TTL、磁盘配额、失败反馈和清理。OM 扩展会记录分享内容前 100 字：`OM/src/ios/ShareExtension/ShareViewController.swift:22-27`，MP 不应记录用户分享正文。OM 还用 responder chain 找 `UIApplication` 强开 `minis://share`：`OM/src/ios/ShareExtension/ShareViewController.swift:69-95`；这条做法的 App Review/跨版本可靠性本轮未查证，不建议原样采用。

### L1-4. MP 已有推送深链底子，但跨楼层通知会静态丢目标

- **OM 怎么做**：外部 URL、AppIntent 和通知最终复用同一个 `.openSessionFromIntent` 导航事件；session deep link 的 canonical/legacy 两种写法都归一到它：`OM/src/ios/Shared/DeepLinkRouter.swift:76-91`，Open Session Intent 与通知 tap 也发同一事件：`OM/src/ios/Agent/Intents/OpenSessionIntent.swift:4-20`、`OM/src/ios/Agent/Intents/SendPromptIntent.swift:420-455`。OM 同时补齐了 SwiftUI `.onOpenURL`、cold-launch `connectionOptions.urlContexts`、warm `openURLContexts` 三条入口，并统一进同一 importer/router：`OM/src/ios/MinisApp.swift:202-214`、`OM/src/ios/AppDelegate.swift:109-120`、`OM/src/ios/AppDelegate.swift:135-160`。
- **MP 现状**：MP 并非“只能打开 app”。APNs tap 会把 `chat_id` 写进 UserDefaults，同时发 NotificationCenter 事件，分别兜 cold/warm：`MemoryPalace/PushNotifications.swift:42-50`；ContentView 启动时延迟消费一次，前台也监听事件：`MemoryPalace/Views/ContentView.swift:449-455`、`MemoryPalace/Views/ContentView.swift:670-672`。但消费器先删除 pending key，再用**当前楼层** `profileId` 过滤目标：`MemoryPalace/Views/ContentView.swift:703-712`。`Conversation.id` 本身是全局 unique，真实归属楼层在 `profileId`：`MemoryPalace/Models/Conversation.swift:14-21`。所以当前代码路径里，通知属于其他楼层时 fetch 为空且目标已经被删除——这是确认的静态缺陷，不是运行时猜测。
- **差距性质**：OM 的统一路由实现更优；MP 有可复用底子，但存在确认缺陷。
- **采纳建议**：**改造搬**。先引入唯一 `AppRoute`（如 `.conversation(profileId?, conversationId, nodeId?)`）与持久 `PendingRouteStore`，让 Push、AppIntent、Share、URL 全部只产生 route，不各自导航。解析 conversation 时按全局 unique ID 找真实 `profileId`；若楼层不同，先调用现有 `switchTo`，等新 subtree 就绪后再导航，成功或明确 terminal failure 后才消费 pending。`switchTo` 会同步广播清旧 SwiftData 引用、再切 currentProfile：`MemoryPalace/MemoryPalaceApp.swift:206-221`，路由器必须尊重这个时序。
- **代价档位**：天级。
- **风险与前置**：需要定义 app locked、conversation 已回收/永久删除、profile 已删除、重复投递、冷启动 SwiftData 未就绪的行为。先写纯值 route 和 resolve 规则，再接 UI；不要让 extension/intent 持有 SwiftData model 实例。

### L1-5. 应写正式 URL spec，但不能照抄 OM：它的资源 spec 与实现已经漂移

- **OM 怎么做**：`minis-url-scheme.md` 把 `minis://` 定义为 session-scoped 资源定位器，并规定 namespace、持久性、渲染和安全边界：`OM/docs/specs/minis-url-scheme.md:6-18`、`OM/docs/specs/minis-url-scheme.md:43-71`、`OM/docs/specs/minis-url-scheme.md:335-342`。主 app 也确实注册 `minis` scheme：`OM/src/ios/Info.plist:299-325`。但 COMMON/L1 把它转述成“外部深链规范”并不准确：真正的导航 route table 在另一个 `DeepLinkRouter`，包含 share、session、settings 等：`OM/src/ios/Shared/DeepLinkRouter.swift:14-44`。而资源 spec 明写“无跨 session 读”，实际 resolver 在 active session 找不到时会扫描所有 session 目录并返回第一个命中的文件：`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:291-309`、`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:324-336`。spec 仍标为 Draft，且多项实现 checklist 未完成：`OM/docs/specs/minis-url-scheme.md:1-4`、`OM/docs/specs/minis-url-scheme.md:313-333`。
- **MP 现状**：两份候选 iOS plist、`project.yml` 和 `MemoryPalace/**/*.swift` 中均无 `CFBundleURLTypes` / `CFBundleURLSchemes`、`.onOpenURL` 或外部 URL router。MP 只有 L1-4 的内部通知导航底子。值得寻址的稳定对象已有：楼层 `Profile.id`、对话/消息 unique ID：`MemoryPalace/MemoryPalaceApp.swift:6-15`、`MemoryPalace/Models/Conversation.swift:14-21`、`MemoryPalace/Models/Conversation.swift:104-114`；书的 ID 是楼层内的 `safeName`：`MemoryPalace/Models/BookEntry.swift:4-16`。
- **差距性质**：能力缺失；OM 的“写 spec”值得学，但它的具体 contract 与实现不能直接搬。
- **采纳建议**：**只借格式**，按 MP 原生架构写两份互不混用的 contract：
  1. 外部导航：`memorypalace://profiles/<profileId>/conversations/<conversationId>`、可选 message/node、`.../books/<bookId>`、`.../settings/<section>`、`memorypalace://new-chat?...`；
  2. 内部附件/文件引用：继续用结构化 ref 或系统 file URL，不与外部导航共用 scheme。
  v1 只开放导航，不在 URL query 里放 prompt、API key、文件正文或“执行动作”。spec 必须写清版本、percent encoding、楼层切换、对象缺失/回收站、app lock、cold/warm、幂等、未知 route fallback 与安全测试矩阵。
- **代价档位**：天级。
- **风险与前置**：先完成 L1-4 的单一路由器，否则 spec 只会重复 OM 的文档/实现漂移。OM 甚至允许 settings URL 携带环境变量预填 value：`OM/src/ios/Shared/DeepLinkRouter.swift:180-192`；MP 不应把敏感值放进可被其他 app 调用和系统记录的 URL。

### L1-6. Live Activity 有产品价值，但它只能展示任务，不能替代后台执行

- **OM 怎么做**：主 plist 声明 Live Activities 与 frequent updates：`OM/src/ios/Info.plist:33-47`；共享 `ActivityAttributes` 带多 session 数、标题、工具状态、轮次、完成摘要、音频态和隐私态：`OM/src/ios/Shared/AgentActivityAttributes.swift:4-18`、`OM/src/ios/Shared/AgentActivityAttributes.swift:20-78`。manager 会启动/更新/soft-finish，做状态去重与 3-5 秒 rate limit，并在隐私模式中抹掉会话/工具/回复内容：`OM/src/ios/Agent/Background/AgentLiveActivityManager.swift:120-169`、`OM/src/ios/Agent/Background/AgentLiveActivityManager.swift:630-739`、`OM/src/ios/Agent/Background/AgentLiveActivityManager.swift:771-797`、`OM/src/ios/Agent/Background/AgentLiveActivityManager.swift:910-988`。它创建 activity 时 `pushType: nil`，状态由本机进程更新：`OM/src/ios/Agent/Background/AgentLiveActivityManager.swift:499-522`。
- **MP 现状**：无 ActivityKit 源码、Widget target、`NSSupportsLiveActivities` 声明。实际 plist 与本条相关的声明只有 audio background mode 与 `INSendMessageIntent`：`MemoryPalaceIOS-Info.plist:36-43`。MP 已有 hub APNs 完成/主动消息入口并可点进对话：`MemoryPalace/PushNotifications.swift:7-29`、`MemoryPalace/PushNotifications.swift:42-50`，但没有一份可供 ActivityKit 持续读取的 durable run state。
- **差距性质**：能力缺失。
- **采纳建议**：**只借思路**。Live Activity 排在 L1-2 后面；展示 bridge run 的状态，而不是拿它当保活机制。MP 版只需 `runId / conversationId / assistantName / generic stage / startedAt / completed`，默认隐私模式不放用户 prompt 和回复正文。因为权威任务跑在 Mac/hub，OM 的本机 `pushType:nil + activeSessions` 不能直接复用；要么有 ActivityKit 远端更新链，要么明确接受 app 被挂起后状态会陈旧。本轮未查证 APNs Live Activity token/服务端能力，不能替粟粟拍板。
- **代价档位**：架构级。
- **风险与前置**：锁屏泄密、多楼层并发、活动残留、远端任务完成但 app 未醒、用户关闭 Live Activities、APNs token 生命周期。MP 最低 iOS 26，没必要照抄 OM 为 iPadOS 16 weak-link 崩溃写的 runtime probe：`OM/src/ios/Agent/Background/AgentLiveActivityManager.swift:47-100`。

### L1-7. 现在不该上 File Provider；先统一并验证 MP 现有 Documents / iCloud 声明

- **OM 怎么做**：File Provider 把 App Group 下的 `memory / skills / shared` 三棵树挂进 Files：`OM/src/ios/FileProvider/FileProviderExtension.swift:5-25`。memory/skills 对 Files 只读，shared 可读写/增删改：`OM/src/ios/FileProvider/FileProviderItem.swift:49-77`；设置允许用户隐藏某棵顶层树，默认三棵全可见但隐藏不删数据：`OM/src/ios/Views/Settings/SharedFolderVisibility.swift:5-16`、`OM/src/ios/Views/Settings/SharedFolderVisibility.swift:35-55`。代价并不小：外部 POSIX 写绕过 FileProvider 时，还要递归 watcher、合并事件并逐层 signal enumerator：`OM/src/ios/FileProvider/AppGroupChangeWatcher.swift:5-16`、`OM/src/ios/FileProvider/AppGroupChangeWatcher.swift:235-260`。
- **MP 现状**：无 File Provider target。MP 自己的文件库已按楼层放在 Documents 下，并把路径限制在库根内：`MemoryPalace/Services/FileLibraryStore.swift:3-6`、`MemoryPalace/Services/FileLibraryStore.swift:72-96`、`MemoryPalace/Services/FileLibraryStore.swift:160-173`；聊天附件也落这份用户文件库而不是 SwiftData blob：`MemoryPalace/Services/AttachmentStore.swift:7-10`、`MemoryPalace/Services/AttachmentStore.swift:58-83`。iCloud 开关只影响 filesystem，记忆树永远本地：`MemoryPalace/Services/FileLibraryStore.swift:27-35`。但 Files 声明存在配置漂移：`MemoryPalace/Info-iOS.plist` 有 `LSSupportsOpeningDocumentsInPlace` 与 `UIFileSharingEnabled`：`MemoryPalace/Info-iOS.plist:23-43`；显式 `INFOPLIST_FILE` 指向的 `MemoryPalaceIOS-Info.plist` 没有这两项，只把 iCloud Documents 声明成 public scope：`MemoryPalaceIOS-Info.plist:44-54`。最终本地 Documents 是否真的出现在 Files，本轮未查证。
- **差距性质**：File Provider 对当前 MP **不适用**；MP 的楼层文件库边界更贴产品，但 plist source of truth 需要收口。
- **采纳建议**：**不建议**现在做 File Provider。先统一 iOS plist 真相源，并在允许测试的批次验证三件事：本地模式 Files 可见性、iCloud 模式 Files 可见性、外部编辑后 app 刷新。只有普通 document sharing 无法满足“只暴露特定目录/读写权限”时，再考虑一个很窄的 provider：只挂 `Incoming`/`Exports` 或用户显式勾选的某楼层交换区。不要挂 SwiftData store、记忆树、人格配置或 cc-bridge 控制目录。
- **代价档位**：小时级（plist 收口）；File Provider 本体周级。
- **风险与前置**：File Provider 本身不等于“让 CC 读写”，所以不自动违反“cc 是 cc，自己的文件是自己的文件”；但它会增加系统/其他 app 这一类外部 writer。若再把同一目录给 cc-bridge，会实质击穿原则。OM 的只读 memory/skills 是可借的权限分层思路，不是 MP 必须暴露私有记忆的理由。

### L1-8. “普通 Widget 对齐”是伪差距：OM 的 Widget target 只承载 Live Activity

- **OM 怎么做**：`AgentWidgetBundle` 只返回 `AgentLiveActivityWidget()`，没有 TimelineProvider、桌面小组件或锁屏静态 widget：`OM/src/ios/AgentWidget/AgentWidgetBundle.swift:1-10`。项目里确有独立 AgentWidget extension target，但其产品用途就是 “Agent Activity”：`OM/src/ios/Minis.xcodeproj/project.pbxproj:2260-2274`、`OM/src/ios/Minis.xcodeproj/project.pbxproj:3422-3445`。
- **MP 现状**：无 WidgetKit 源码和 Widget target；现有唯一 app extension 是 Push NSE：`project.yml:188-216`。
- **差距性质**：不适用。真正差距已在 L1-6（Live Activity），不是“OM 有普通 Widget、MP 没有”。
- **采纳建议**：**不建议**为 parity 建 Widget。若未来出现独立用户任务——例如“最近对话”“今日记忆”“一键新聊”——再单独做信息架构、隐私和刷新预算评估。
- **代价档位**：不适用。
- **风险与前置**：没有清晰任务时，Widget 只会复制 app 首页，增加 extension、snapshot、App Group 和隐私成本。

## 证据边界与未查证

- 全程只读 MP/OM 源码，唯一写入是本报告；未 build、未跑测试、未生成 xcodeproj、未做任何 Git 操作。
- App Intents 的 Siri/Shortcuts 实际展示、Share Extension 能否稳定拉起主 app、Live Activity 的设备行为、Files 本地目录可见性均未做运行验证。
- OM 的 URL spec 与 resolver 冲突是源码静态事实；它是否造成用户可见的跨 session 误解析或安全影响，未做运行复现，不能升级成已验证漏洞。
- COMMON 给的 OM commit 号与规模未用 Git 复核，因为本 lane 禁止 Git 操作；报告只代表给定 snapshot。

## §反向发现

1. **MP 已经不是“打开 app 才存在”**。它有 APNs 注册、hub token 上报、cold/warm tap 跳转和 Push NSE 个性化：`MemoryPalace/PushNotifications.swift:7-29`、`MemoryPalace/PushNotifications.swift:42-50`。NSE 不读整库，只读 App Group 里的 `chat → profile → 名字/头像` 轻量索引，查不到自然 fallback：`MemoryPalace/Services/PushIdentityWriter.swift:5-17`、`MemoryPalacePushNSE/SharedIdentityStore.swift:25-49`、`MemoryPalacePushNSE/NotificationService.swift:26-39`。这种“给 extension 最小 DTO，不共享主数据库”的边界比把整棵工作区放进 App Group 更适合作为 MP 新扩展模板。跨楼层跳转 bug 仍须按 L1-4 修。
2. **MP 的文件产品模型比 OM 的全局 agent workspace 更贴“楼层/陪伴”定位**。文件库按楼层隔离、可本地或 iCloud、解析相对路径时有根目录 containment：`MemoryPalace/Services/FileLibraryStore.swift:3-6`、`MemoryPalace/Services/FileLibraryStore.swift:27-35`、`MemoryPalace/Services/FileLibraryStore.swift:160-173`。OM 则把 global memory/skills/shared 直接做成 Files provider 顶层：`OM/src/ios/FileProvider/FileProviderExtension.swift:5-25`。MP 不需要因 OM 有 File Provider 而放弃自己的边界。
3. **MP 的“分享后能去哪”比 OM 丰富**。OM 最终只有填 composer/加附件：`OM/src/ios/Views/Chat/AIChatView.swift:1595-1637`；MP 已有聊天附件、书架、历史对话、贴纸包四套经过产品设计的导入入口：`MemoryPalace/Views/CardFlowView.swift:1295-1300`、`MemoryPalace/Views/Reading/BookshelfView.swift:67-88`、`MemoryPalace/Views/ImportView.swift:258-271`、`MemoryPalace/Views/StickerSettingsTab.swift:267-276`。因此 MP 的 Share Extension 应做“路由器”，而不是 OM 的单一聊天漏斗。
4. **cc-bridge 让 MP 有机会避开 OM 最重的本机保活债**。MP 的聊天任务可发到 hub/真实终端，回复再经持久去重路径落回 app：`MemoryPalace/ViewModels/ConversationViewModel.swift:2899-2926`、`MemoryPalace/Services/CCBridgeWebSocketClient.swift:830-860`；OM 为本机 agent 长任务维护 audio/location/background/Live Activity 联动，单是有效保活就依赖两个用户开关：`OM/src/ios/Agent/Background/BackgroundKeepAliveManager.swift:92-101`、`OM/src/ios/Agent/Background/BackgroundKeepAliveManager.swift:1132-1168`。MP 当前缺的是“提交已被接受”的持久合同，不是把 iPhone 进程变成常驻 agent。

## §不建议学

1. **不学 OM 的具体 Quick Tasks**。它们直接绑定睡眠、健康、天气、日历、相机、闹钟、HomeKit：`OM/src/ios/Agent/Intents/QuickTaskIntent.swift:7-27`、`OM/src/ios/Agent/Intents/QuickTaskIntent.swift:30-48`。这属于本批次另一条“设备能力工具族”并行线，本报告到此跳过；系统入口层只保留“可配置的 prompt/action”形态。
2. **不学静音音频/定位保活**。OM 的 headless intent 在 await 前 eager arm：`OM/src/ios/Agent/Intents/FollowUpSessionIntent.swift:30-59`，实际有效保活依赖后台静音音频：`OM/src/ios/Agent/Background/BackgroundKeepAliveManager.swift:1132-1168`，plist 还声明 audio/fetch/location/remote-notification：`OM/src/ios/Info.plist:33-47`。MP 的重活在 bridge/hub，正确方向是 durable job，不是制造常驻 iOS 进程。
3. **不学 `ListSessionsIntent` 的“把全部会话标题 + ID 拼成大字符串”**：`OM/src/ios/Agent/Intents/ListSessionsIntent.swift:4-27`。MP 有更多历史且有楼层边界，应让 `ConversationEntity` 查询承担选择；需要机器消费时返回结构化实体集合并分页/限量，不裸吐全部历史 ID。
4. **不学 Retry Run 作为首批系统 action**。OM 会从某条 user message 截断后续并重新跑 agent：`OM/src/ios/Agent/Intents/RetryRunIntent.swift:4-17`、`OM/src/ios/Agent/Intents/RetryRunIntent.swift:97-150`。它是 OM agent run 语义，不是 AI app 的通用入口；MP 首批应先保证打开、发送、继续、状态查询。
5. **不学“一个 custom scheme 同时装外部导航、内部资源和敏感设置参数”**。OM 的 `minis://` 同时服务资源 spec、share/session/settings router，并允许 env value 进入 query：`OM/docs/specs/minis-url-scheme.md:20-41`、`OM/src/ios/Shared/DeepLinkRouter.swift:18-40`、`OM/src/ios/Shared/DeepLinkRouter.swift:180-192`。MP 应把外部导航与内部附件引用分开，URL 只导航不携带秘密或执行 payload。
6. **不学默认把 memory/skills 暴露到 Files**。OM 虽设只读，但三棵树默认可见：`OM/src/ios/FileProvider/FileProviderItem.swift:49-77`、`OM/src/ios/Views/Settings/SharedFolderVisibility.swift:12-16`。MP 若未来做 provider，只开放用户显式选择的交换区。
7. **不学 Share Extension 的内容日志与强制拉起实现**。OM 会把分享值前 100 字写日志，并从 responder chain 找 UIApplication 开 URL：`OM/src/ios/ShareExtension/ShareViewController.swift:22-27`、`OM/src/ios/ShareExtension/ShareViewController.swift:69-95`。MP 应默认不记录正文，并把“暂存成功”和“是否打开主 app”解耦。
