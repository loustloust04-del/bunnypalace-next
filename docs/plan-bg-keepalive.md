# plan：被系统回收后回来不播开屏、回到上次的页

> ✅ 粟粟 10-15 go（Q1 A｜Q2 A｜Q3 A）。实现中。
> 2026-10-15 · 🎩 · infra 工位 · 前置 [research-bg-keepalive](research-bg-keepalive.md)（根因：Air 开着 Fast App Termination，已关，验收第 1 条她确认）
> 本 plan 只管验收第 2 条：**真被系统回收**（内存回收 / 开着 Fast App Termination 等），回来时不播开屏、直接回到上次的页。

## 0. 先分清两种「被杀」

| | 系统回收（内存 / Fast App Termination / 装包以外的系统终止） | 她在多任务里上滑划掉 |
|---|---|---|
| iOS 的 scene session | **保留**（`UISceneSession.userInfo`、`@SceneStorage` 还在） | **丢弃**（新 session，两者都清空） |
| 她的预期 | 回到原处，像没走过 | 重新开始（播开屏、落聊天页） |

这是 iOS 自带的语义，page2 的「被系统杀掉后回到离开时的应用」已经在用（`ContentView.swift:84-87`）。本 plan 全部沿用这条线：**只在 session 被保留时恢复 / 跳开屏**，她主动划掉的照旧。
⚠️ 未查证：iOS 27 上 Fast App Termination 杀掉后 session 是否保留（论坛说法是为测状态恢复而设，按理保留）。
工位暂停租模拟器（粟粟 10-02），T1 实测挪到合 master 后（Warden 装 sim / Air 开 Fast App Termination）。**降级保证**：session 没保留时两样都读不到 → 行为和现在完全一样（照播开屏、落聊天页），不会更坏。
（实现前补：Air 系统日志里 FrontBoard 的 sceneID 一直是 `com.susu.MemoryPalace.ios-default`，固定不变，拿 id 比对分不出「系统回收」和「划掉」→ 标记改存 `UISceneSession.userInfo`，随 session 生灭。）

## 1. 现状（证据见 research §2.5）
- 开屏：`LaunchSplash.install` 每个新进程装一次，scene 连接时 `show(in:)`（`Views/LaunchSplash.swift:109-131`）；已有「推送启动跳过」分支（`:133-140`，`pushLaunch` → `releaseContent()`，不放声）。
- 页号：`iOSPage` 启动写死 1（`ContentView.swift:61`）。
- 当前对话：不恢复，启动 `ensureDraftConversation()` 托底一个空草稿对话（`ContentView.swift:135-151`）。
- 输入框：已存在的对话，草稿在进后台时落到 `Conversation.draftText`（`InputBarStack.swift:149-153`），恢复对话就会带回；**还没落库的新对话（草稿对话）直接 return 不存**（`InputBarStack.swift:166`）→ 新对话里打的字被杀就没了。
- API 卡：已有专用草稿 + 冷启动跳回编辑页（`SettingsJump.swift:86-99`），这次不动，和本 plan 叠加。
- 外部入口（推送 / 来电）已有让路闸 `SettingsJump.noteExternalNavigation()`（`ContentView.swift:887,948`）。

## 2. 方案

### 2.1 跳过开屏（`LaunchSplash`）
- 进后台时记一个「回来标记」：离开时间写进当前 scene 的 `session.userInfo`（`didEnterBackground` 里同步写）。
- 冷启动 scene 连接时（`willConnect` 回调和 `prepareForPageConstruction` 的 rootGate 两个入口都要拦）：**session 里有标记 且 离开 ≤ 10 分钟（Q1 A）** → 走和推送启动一样的跳过路径：不建开屏窗、不放「叮」、`finishReason = "resume"`、直接 `releaseContent()`。
- 用掉即清（一个标记只跳一次）；她划掉 app 后 session 被丢弃，标记跟着没了 → 照播。
- 系统自己的启动图（纸色底）冷启动必然闪一下，这个跳不掉，是 iOS 的。

### 2.2 回到上次的页（ContentView）
用 `@SceneStorage`（和 page2 同一套，session 丢了自动作废）存：
- `resume.page`：0 / 1 / 2（page2 里开着哪个应用已经有了）
- `resume.conversationId`：当前对话 id（草稿对话 = 空）
- `resume.newChatText`：草稿对话输入框里的字（只在草稿对话时写；发出去 / 切走即清）

写：`iOSPage` / `selectedConversation.id` 变化时写（SceneStorage 写很便宜）；`newChatText` 进后台时写一次（同 InputBarStack 现有的 flush 时机）。
读：冷启动 `onAppear` 里，在 `ensureDraftConversation()` 之前：
1. 外部入口（推送 / 来电）认领了 → 不恢复（同 API 草稿的让路规则）；
2. 有 `conversationId` 且在当前楼层查得到、没进回收站 → `viewModel.loadConversation(...)`；查不到 → 照旧托底草稿对话；
3. 是草稿对话且有 `newChatText` → 托底草稿后把字填回输入框；
4. 翻到 `resume.page`（宽屏悬浮面板形态不翻，那里 page 恒为 1）。
- 楼层：上次楼层本来就会恢复（`lastProfileId`），不另存；对话不在当前楼层就不恢复。
- 冒烟 / perf / 测试宿主 / 引导盖着时不恢复（复用 `canResumeAPIDraft` 那组闸）。

### 2.3 不在本单
- 对话里的滚动位置（回来落在最新消息；要不要记位置单独提）。
- 设置页 / 其他 sheet 停在哪一页（API 卡编辑页已有专用恢复）。
- research §2.5 里的进后台备份全量编码、iSH 调速器没接、iSH init 死 `_exit(0)`：记债，另开单。

## 3. 拍板（粟粟 10-15：Q1 A｜Q2 A｜Q3 A）
- **Q1 跳开屏的时间窗 N**：A 10 分钟（推荐，符合派单「几分钟内」）/ B 不限时（只要是系统回收都跳）/ C 2 分钟。
- **Q2 回到上次的页有没有时间上限**：A 不限时，系统回收就恢复（推荐，iOS 自家 app 的做法；她划掉就重新开始）/ B 跟 Q1 同一个窗。
- **Q3 新对话里没发出去的字要不要恢复**：A 要（推荐）/ B 不要。

## 4. 验证
- 单测：回来标记的判定（session 一样 / 不一样、窗内 / 窗外、用过一次后失效）。
- 模拟器（`sim`）实测，iOS build-for-testing SUCCEEDED 才算编过：
  1. 进对话 A → 打几个字 → 回桌面 → `simctl terminate` → 重开：不播开屏、在对话 A、字在；
  2. 新对话里打字 → 同上：字在；
  3. 停在 page0 / page2 → 同上：回到那一页；
  4. 回桌面后在多任务里上滑划掉 → 重开：播开屏、落聊天页空草稿（session 丢弃路径；模拟器划不掉就用 mobai 划）；
  5. 推送点进来的冷启动：落推送的对话，不被恢复抢。
  6. （审查补）推送冷启动 → 不翻页 → 回桌面 → terminate → 重开：回到聊天页（存值已对齐，不回上一世的列表页）。
  7. （审查补）Codex 草稿里打字 → 被回收：字不出现在普通草稿里。
  8. （审查补）打字后立刻回桌面 + terminate；回来把字删光 → 回桌面 + terminate：两次恢复出来的字都是最新的（验 didEnterBackground 写入赶不赶得上系统存盘，没文档保证）。
  9. （审查补）停在 page0 时该对话来新消息 → 被回收 → 重开：未读数还在；顺手翻几页看 `PerfCount contentViewBody` 不涨、跳开屏后有没有先闪一帧聊天页。
- Air（合 master 后由 Warden 装）：她临时打开 Fast App Termination 当测试开关跑一遍 1 和 4，验完关掉。

## 5. 风险
- `@SceneStorage` 在 iOS 26/27 上被系统杀后是否可靠恢复——page2 已经靠它，T1 先实测确认。
- 冷启动多一次按 id 的单条 `Conversation` fetch（`fetchLimit = 1`，走索引），不碰 MessageNode 全量。
- `loadConversation` 在冷启动早期调用的时机：推送落点用 0.6s 延迟消费，恢复要排在它之后判断，避免抢推送；T3 对着推送那条线写。

## 6. todo
- [x] ✅ T1 实测 session 保留（research §2.7：`simctl terminate` 后 userInfo / SceneStorage 都保留）
- [x] ✅ T2 `LaunchResumeMarker`（进后台写离开时间到 `session.userInfo`、冷启动判定、用后即清）+ 单测
- [x] ✅ T3 `LaunchSplash` 两个入口接跳过路径（`finishReason = "resume"`，不放声）
- [x] ✅ T4 ContentView：`@SceneStorage` 写 `resume.page` / `resume.conversationId`
- [x] ✅ T5 ContentView：冷启动恢复（外部入口让路、查不到回落草稿、翻页、宽屏不翻）
- [x] ✅ T6 草稿对话输入框文字：进后台写 `resume.newChatText`、恢复时填回、发出 / 切走清
- [x] ✅ T7 iOS build-for-testing SUCCEEDED + 单测 Test Suite passed
- [ ] T8 sim 实测 §4 的 1–5（合 master 后 Warden 装 sim 再测；提交 --why 写「要验 UI」）
- [x] ✅ T9 审查一轮（sol + Claude；kimi 额度墙），逐条裁决见 review §0，修复 5d4ebfe78
- [x] ✅ T10 `docs/now/infra.md` + review 文档 + 问合
- [ ] T11（码 ✅ 7f2deba23，build / 单测过；待重跑）第一轮实测第 2 条 FAIL（系统存 session 早于 didEnterBackground 写入）→ 标记和新对话的字提前到 willResignActive 写；didEnterBackground 那次定稿后再写一遍保留 → 再交 Warden 重跑 §4 的 1–9
