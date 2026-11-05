# H-A —— 洞 6 + 洞 7：跨楼层 scoped fetch 漏楼层

先读 `IMPL-COMMON.md`（同目录，纪律 + 跑道 + escape hatch），再读 `docs/minis对比/plan-补洞.md` §二 的「洞 6」和「洞 7」两节——那是你的契约，本文只补契约没写的。

## 为什么这两个洞是一条 lane

同一种病：`Conversation.id` 是**全库** `@Attribute(.unique)`，`profileId` 是普通列。两处代码都用 `id == X && profileId == currentPid` 查，查不到就当不存在——但它可能存在于另一个楼层。洞 6 的后果是 SwiftData 静默 upsert 把那行偷过来；洞 7 的后果是通知跳转静默失败。修法的核心动作也一样：**先按 id 全库查，再看它属于谁**。

## 洞 6 补充

- 正确解法已经在仓里：`ImportSupport.swift:26-33` 的注释就是这条事故的原文，`crossProfileConflictedConversationIds`（`:80`）是函数，`ConversationImporter.swift:79, 235` 和 `ClaudeImporter.swift:124, 287` 四处调用是**范例**——照它们的调法。
- 三处要修：`BackupStore.swift:424`（`restoreConversation`）、`SyncStore.swift:448`、`SyncStore.swift:514`（`importAll` 附近）。行号是 09-02 的，你自己重新定位。
- ⧫ 冲突时**整份对话跳过**（不做部分 insert、不改 id），跳过数计入返回结果并露到 UI（还原结果 / 同步日志——现有结果结构里有计数字段就复用，没有就加最小的一个）。
- 「全库还原」如果现有语义允许覆盖 profile 归属，保持不变，单测锚一下。
- 测试：`SyncStoreTests` 已存在，扩它；`BackupStore` 没有测试文件，建一个。三条路径各至少一测：种楼层 A 有对话 X → 以楼层 B 身份走该路径导入含 X 的数据 → 断言 X 仍属 A、属性未变、B 侧无 X、结果报 1 跳过。**先让它红**（现在的代码会把 X 偷到 B）。
- ⚠️ 测试用 SwiftData 内存 store，注意「双 context 写后必须显式 save」——用同 context 写的测试会假阳性。

## 洞 7 补充

- `ContentView.swift:709-717` `consumePendingPushTarget`。三步叠加：先删 key → 当前楼层过滤 → 静默 return。
- ⧫ 只修 bug，**不做 AppRoute**。但把解析逻辑抽成一个独立的纯函数（例如 `resolvePushTarget(chatId:in:) -> PushTarget?`，返回对话 + 它真实的 profile + 是否需要切楼层），ContentView 只负责调它然后按结果动作——将来 AppRoute 直接复用这个函数。放哪个文件你定，ContentView 已经很大了别再塞。
- 时序：`ProfileManager.switchTo`（`MemoryPalaceApp.swift:206`）会**同步广播清旧 SwiftData 引用再切 currentProfile**——切完不能立刻拿旧 context 导航，要等新 subtree 就绪。看 `switchTo` 的实现和现有调用点怎么等的，照做。
- **pending key 只在成功导航或明确 terminal failure（对话已永久删除 / 楼层已删除）之后才删。** 可恢复的失败（比如 SwiftData 还没就绪）保留 key 让下次消费。
- 失败要有可见反馈——现有 toast 机制有就用，没有至少 `BreadcrumbLog`。**不许静默 return。**
- 测试：resolve 纯函数三 case（同楼层 / 异楼层 / 不存在）。ContentView 那层的 SwiftUI 集成不要求单测，模拟器实证归收口 QA。

## 影响面（你不该碰的）

- `PushNotifications.swift`——存 key 那边没错，不动。
- `ImportSupport.swift`——正确解法在这，只调用不改。
- `ConversationImporter.swift` / `ClaudeImporter.swift`——范例，只读。
- 任何 `ConversationViewModel.swift` / `ChatService.swift` 改动——那是 H-B 的地盘。

## 验收

- 三条洞 6 路径的测试：修前红（贴输出）→ 修后绿（贴输出）。
- 洞 7 resolve 函数三 case 绿。
- `xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS'` 全套绿（贴 `Executed N tests` 行）。
- `xcodebuild -scheme MemoryPalace -destination 'platform=macOS' build` 绿。
- 每个洞一个或多个 commit 已 push 到你的分支。
- 报告 `docs/minis对比/reports/H-A-report.md` 按 IMPL-COMMON 格式。
