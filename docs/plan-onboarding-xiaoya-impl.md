# plan · 小芽对话式新引导 · 实施

> ✅ 2026-10-15 粟粟：§7 八条「都按推荐」，go。做完**先别合**，在模拟器上给她试。
> ✅ 同日补：P1（含草稿服务）+ P3（只在 DEBUG 出现）用户看不到，**先交合并**、通知 API 线；P2 起攒在分支上，等她 sim 试过再合。
>
> 2026-10-15 · 子 agent 只读代码写成 · 前置：[plan-onboarding-xiaoya](plan-onboarding-xiaoya.md)（§六、§七 已拍板，本文不再讨论）· [research](research-onboarding-xiaoya.md)（H1–H11）· [小样](design-onboarding-xiaoya.html)（16 屏，界面和文案以它为准）
> 行号以 `MemoryPalace/` 为根，基于 `zone/page2-apps` HEAD `3c36cad15`；与当前 master `d4a4e955` 比，下文涉及的文件一行没变，行号两边都对得上。

---

## 0. 总览

| 阶段 | 一句话 | 老用户能看到吗 | 规模（文件 / 量级） | 依赖 |
|---|---|---|---|---|
| **P1 地基** | API 卡「草稿 → 测试 → 唯一保存」抽成服务（设置页改用，行为不变）；`AssistantEngine` 单例；小芽对话 + 账本进全局备份 | 看不到（只有备份包多一段） | 改 ~8、新 ~3 · +450 / −150 | 无 |
| **P2 小芽楼层** | 保留 id 楼层 `xiaoya`（不能删、不能改名），升级用户静默种入排最前；page1 挂小芽房间（照 agoraRoom）；工具改「目标楼层」+ 舞台「正在帮：某某」；收掉改名框和 Rosemary | 看得到：楼层列表多一层「小芽」、她不再叫 Rosemary | 改 ~15、新 ~3 · +700 / −80 | P1 的单例 |
| **P3 引导卡组件** | 小芽房间专用卡：选择 / 填 key 表单（含测试结果）/ 导卡 / 起名 / 新楼层出口 / 扫码 / 待办 / 说明；视觉对齐 AskCard，不依赖 `ConversationViewModel` | 看不到（只在 DEBUG 预览台出现） | 新 ~9 · +1000 | key 卡依赖 P1 的服务；其余独立 |
| **P4 剧本引擎** | 本地剧本 + 五条分支 + 与真 AI 交接（剧本压成一句系统备注）；Ta 楼层建好不自动切；默认称呼 | 看不到入口（新装判定在 P5 才接） | 改 ~10、新 ~4 · +950 | P2 + P3 |
| **P5 接通** | 新装判定（新键）、删旧 `OnboardingFlowView` 六页、mac 首启、推送 / proMode 时机、设置页「新手引导」改去小芽楼层 | 新装才看得到；老用户无感 | 改 ~9、删 ~7 · +300 / −1700 | P4 |

顺序理由：P1 纯重构 + 备份扩段，老用户零感知，先合；P3 不接入口，零感知，可以和 P2 并行做；P2 是第一处用户可见变化（多一层楼、名字统一），但不改任何人的当前楼层、不弹东西；P4 写完仍没有入口（只在 DEBUG 预览台能跑）；P5 才把新装用户接进来，同时删旧引导。**每一阶段合完 App 都完整可用**：P4 合了 P5 没合，新装用户仍走旧六页，不会落到半截。

和骨架的差别：把 P3 提到与 P2 并行（它不依赖楼层，只依赖 P1 的草稿服务接口）；P1 内部再拆 P1a / P1b 两个可单独合并的提交组，方便 P1a 交给 API 线（见 §6）。

---

## 1. P1 地基

### P1a · API 卡草稿服务（抽取，行为不变）

**现状**：`APICredentialEditor.makeDraft(id:)`（`Views/APICredentialEditor.swift:145-166`）、`persist(_:adopt:)`（`:1364-1415`）、`runTest`（`:1421-1437`）、`fetchThenPersist`（`:1339-1362`）都是 View 的 private 方法，直接读 @State（`:23-41`、`:116-121`）。旧引导自己抄了一份 `draftCredential` / `persistCard`（`Views/Onboarding/OnboardingFlowView.swift:690-734`），口径已经分叉（同协议同地址同 key 复用旧卡、没有单例 id、没有本机模型收藏、没有 `forgetModels`）。

**做法**：新建 `Services/Providers/CredentialDraft.swift`（目录不存在就放 `Models/`，与 `ProviderProbe.swift` 同层）：

```swift
struct CredentialDraft: Equatable, Codable {          // Codable：给 API 线「草稿保活」直接用（不含 key）
    var presetSelection: String                         // "_custom_" 或 preset.id
    var customType: ProviderType
    var customBaseURL: String
    var nickname: String
    var emoji: String
    var models: [ProviderModel]
    var toolsSupported: Bool
    var type: ProviderType { … }                        // = 编辑器 currentType（:79-82）
    var baseURL: String { … }                           // = currentBaseURL（:89-92），含 Ollama 可改地址
    var isHTTP: Bool { … }                              // = isHTTPCard（:114）
    var isSingletonPreset: Bool { … }                   // = :175-177
    func makeCredential(id: String, existing: APICredential?) -> APICredential   // = makeDraft 原样
}

@MainActor enum CredentialCommitter {
    enum Adopt { case none, autoPick, model(String) }   // 编辑器 = autoPick；引导 = 用户点的那个
    /// 唯一落盘入口：卡 + key（+ 本机模型收藏 / forgetModels / 主模型），返回卡 id
    static func commit(_ draft: CredentialDraft, key: String, existing: APICredential?,
                       adopt: Adopt, providerManager: ProviderManager) -> String
}
```

- `commit` 内容 = `persist` 的 `:1366-1406`（卡 id 选择：已有 id / 单例预设 id / `cred-UUID`；空名「未命名」、空 emoji「🔑」；非 HTTP 卡沿用已存模型；`forgetModels(dropped)`；按类型写钥匙串 / 不写 / 本机模型收藏；`adoptNewModel`）。`.model(id)` 走同一个 `adoptNewModel`（`Models/APIProvider.swift:805-811`：收藏 + 主模型空着或不能用时才接管，K3 口径不变）。
- **ccBridge 的 Hub 地址（`:1393-1395` `CCBridgeEndpoints.saveManual`）留在编辑器**：它读的是编辑器自己的 hubURL 草稿，不属于卡草稿；服务只管卡和 key。
- 编辑器改法：@State 的 7 个字段合成 `@State private var draft = CredentialDraft(...)`（或保留字段、在调用点现拼 `CredentialDraft`——**推荐后者**，改动面最小，不碰 `DraftSnapshot` / `isDirty` / `onChange` 链）；`makeDraft` → `currentDraft.makeCredential`；`persist` 里 `:1366-1406` → `CredentialCommitter.commit`，`savedFlash` / `dismiss` 留在 View。
- **不动**：`runTest` / `fetchThenPersist` / `refreshModels` 的 UI 状态机，`ProviderProbe` 本身（它已经是纯函数层，`Models/ProviderProbe.swift:3-5`）。
- 另加一个纯函数 `ProviderProbe.humanReason(_ failure: Failure) -> String`（401/403 → key 不对或失效；404 → 地址不对，可能要写到 /v1 或是 Anthropic 协议；429；5xx；超时；连不上），**只给引导卡用**，编辑器的报错文案不动（那是 API 线「报错去改」的地盘）。

**数据**：不新增任何持久数据。
**迁移 / 回滚**：纯重构，`git revert` 即可。
**对应**：H1（测试只认 2xx——沿用 `ProviderProbe.test`）、H2（测试不落盘、保存唯一落盘——服务里只有 `commit` 写）、H5（`Adopt.model` 让引导按用户挑的模型设主模型 + 收藏）。
**风险**：编辑器 `persist` 分支多（单例 / 桥卡 / OAuth / 本机模型），抽取时漏一支 = 静默行为变化。→ 先写对拍测试再抽。
**验证**：
- 单测 `CredentialDraftTests`：preset / 自定义 OpenAI / 自定义 Anthropic（`anthropic-version` 头）/ Ollama 可改地址，`makeCredential` 输出与抽取前 `makeDraft` 逐字段相同（抽取前先在测试里固化一份期望值）。
- 单测 `CredentialCommitterTests`：新 HTTP 卡得 `cred-` id；单例预设得预设 id；编辑已有卡 id 不变；改了家后旧模型进 `forgetModels`；本机模型卡只收藏已装好的；`.autoPick` 与 `.model(id)` 各自写对收藏和 `selectedChatModel`（K3：主模型可用时不抢）。钥匙串用现有 ProviderManager 测试的隔离写法。
- 粟粟 sim 看：设置 › 模型和API 新建一张卡、测一下、保存；改一张卡换家再保存——和以前一模一样。

### P1b · `AssistantEngine` 单例 + 全局备份

**现状**：`AssistantPanelView.init` 每次 `AssistantEngine()`（`Views/Assistant/AssistantPanelView.swift:21-24`），engine init 读盘（`Services/Assistant/AssistantEngine.swift:62-71`）。全局备份没有 `AssistantChat/`：导出白名单 `Services/GlobalBackup/GlobalExporter.swift:145-160` 只有 UserDefaults 键，文件区只有 stickers / audiobooks / themes / cardlibrary / filelibrary（`:446-660`），且这些都在 `Application Support/MemoryPalace/` 下（`StagingPaths.swift:23-27`），而小芽的两份文件在 `Application Support/AssistantChat/`（`AssistantChatStore.swift:15-19`、`AssistantLedger.swift:37-41`），不在同一棵树。

**做法**：
1. `AssistantEngine` 加 `static let shared = AssistantEngine()`（`@MainActor`），保留现有 `init(store:ledger:packDefaults:)` 给测试注入（`MemoryPalaceTests/AssistantLedgerTests.swift:25` 在用）。`AssistantPanelView.init(engine:)` 默认值改 `.shared`。
2. 写盘：`scheduleSave`（`:301-311`）已是 0.5 s 合并 + 后台写；单例后不再有两个实例互相覆盖，不需改。
3. 备份：
   - 导出：`GlobalExporter` 加 `exportAssistantChat(to:)` → 包内 `assistant/history.json` + `assistant/ledger.json`（跳过 `*.corrupt-*.json`），各记一个 section hash（照 `exportCardLibraryFiles` `:579-596`）。
   - 导入：`GlobalImporter` 照 cardlibrary（`:539-545`）拷到 `StagingPaths` 新增的 `stagingAssistantRoot`；`PendingImportApplier` 照 `:220-232` / `:399-402` 归档旧的、搬新的进 `AssistantChat/`。
   - **旧备份包没有 `assistant/` 段 → 保留本机现有文件**（不同于 cardlibrary「恢复后为空」），见待拍板 7。
   - 恢复在启动早期由 `PendingImportApplier` 完成，早于 `AssistantEngine.shared` 第一次被访问，不用热重载。

**数据**：备份包多 `assistant/` 目录 + manifest 两条 section。
**迁移 / 回滚**：旧版 App 读新包 → 不认识 `assistant/` 段直接忽略（manifest 校验只校验它认识的 section——**实施时先核 `SectionHasher` / 导入校验是不是「包里有未知 section 就拒」**，是的话要给 section 加版本兜底）。revert 即回到不备份。
**对应**：§七-1。
**风险**：小芽对话里可能有她的私人内容 → 备份包本来就是她的私人数据，不进 git，和对话库同级，无新增暴露面。
**验证**：
- 单测 `AssistantEngineSharedTests`：`shared` 恒等；注入 init 不碰真实 `history.json`（路径断言）。
- 单测 `GlobalBackupAssistantTests`：导出包含两份文件且 hash 对；导入后落回原路径；包里没有这段时本机文件不变。
- 粟粟 sim 看：mac 上右栏开着小芽、同时设置里点导出备份——不卡、包里有 `assistant/`。（mac 右栏 + page1 同时开要到 P2 才有。）

---

## 2. P2 小芽楼层

### 2.1 保留 id 楼层

**现状**：种子只有 `default-workspace`「对话空间」（`MemoryPalaceApp.swift:114-126`），楼层列表读空才种（`:444`、`:452-458`），读坏进只读、内存里给 seed（`:432-443`）。删楼层只挡「最后一个」（`:369`）；删 / 编辑入口在 `ProfileSwitcher`（`:1611-1615`、`:1643-1651`、确认框 `:1699-1723`）和 `CharacterHomeView`（`Views/CardLibrary/CharacterHomeView.swift:99,139`）。

**做法**：
- `Profile` 加 `static let xiaoyaId = "xiaoya"`、`static var xiaoyaFloor: Profile`（name「小芽」、emoji 🌱、assistantName「小芽」、userName = 默认称呼（§4.4）、`createdAt` 固定 1970——排序稳定）、`var isXiaoya: Bool`。
- `ProfileManager` 加 `ensureXiaoyaFloor()`：`!isReadOnly` 且列表里没有 id `xiaoya` → **插到第 0 位**、`saveProfiles()`、`publish` 的副作用（文件库目录、推送身份）；**不动 `currentProfile`、不写 `lastProfileId`**（§七-3「不抢当前楼层」）。调用点：`MemoryPalaceApp.init` 读完楼层后（`:820-838` 之间，只在 `profilesTrusted` 时）。每次启动都跑（幂等），于是整包导入 / 酒馆导入覆盖楼层列表后下次启动自动补回。
- 护栏（以 id 判，不以名字判——老用户自己建的「小芽」楼层不受影响）：
  - `deleteProfile`（`:368`）开头 `guard !profile.isXiaoya`；`ProfileSwitcher` 两端「删除当前楼层」「编辑当前楼层」在小芽楼层隐藏；`CharacterHomeView` 的编辑入口同。
  - `updateProfile`（`:328`）对小芽楼层只放行 `userName`（默认称呼同步用），`name` / `emoji` / `assistantName` 改动丢弃。
  - `SillyTavernImportRetract.swift:196` 撤回导入删楼层：天然不会命中（小芽楼层不是导入建的），加断言即可。
- **选楼层的地方要不要列小芽楼层**——加 `ProfileManager.taFloors`（= 去掉小芽楼层），逐处定：
  - 用 `taFloors`：导入落点（`Views/ImportView.swift:231,244`）、Agent 绑定（`Views/AgentSettingsTab.swift:47,65`）、世界书 / 卡库「挂到哪层」类选择器、目标楼层候选（§2.4）。
  - 照旧全列：`ProfileSwitcher` 切楼层菜单（小芽楼层排第一，就是她的家）、角色墙（`Views/CardLibrary/CharacterWallView.swift:50,303`，小芽楼层出一张固定在最前的「小芽」磁贴，点了只切楼层不进 CharacterHome）、数据 / 文件库设置（`DataSettingsTab.swift:963`、`FileLibrarySettingsTab.swift:200,248`）。
  - 实施时 `grep -n "\.profiles\b"` 全量过一遍（当前 ~20 处），在 plan 勾选里逐处记结论。
- 新装种子在 P5 改（§5.1），P2 不动 `seedProfiles`。

### 2.2 page1 挂小芽房间

**现状**：page1 只有 `CardFlowView` / `EmptyStateView` / `AgoraRoomView` 三种（iOS `Views/ContentView.swift:1718-1734`；mac `macChatContent` `:2139-2170`，mac 还有 `CodingSessionDetailView` 先例）。中庭房间有自己的输入框，靠 `KeyboardInsetBridge.shared.chatInputSuppressed` 关掉常驻输入条（`:826-830`、`Views/InputBarStack.swift:28`）。根视图 `.id(profileManager.currentProfile.id)`（`MemoryPalaceApp.swift:1301`）切楼层整树重建。

**做法**：
- 把 `AssistantPanelView` 拆两层：`XiaoyaConversationView`（舞台 + 消息列表 + 输入框，engine 从外面给）+ 外壳。page2 小芽 app（`Views/MemoryPanelView.swift:160-161`）和 page1 房间都用它、都传 `AssistantEngine.shared`。
- 新 `Views/Assistant/XiaoyaRoomView.swift`：page1 房间外壳（iOS 顶部留 page0 / page2 翻页手势区，mac 套 `MacChatCard`）。
- `ContentView`：**按楼层分支，不新增 `ContentDestination` case**（房间是楼层属性不是导航选择，`destination` 是 per-floor 的 @State，整树重建时会回 `.chat`）：
  - iOS `iOSChatPage`（`:1717`）：`if profileManager?.currentProfile.isXiaoya == true { XiaoyaRoomView() } else if destination == .agoraRoom …`；`iOSChatTopBar` / 岛 overlay（`:1736-1760`）在小芽楼层不挂。
  - `chatInputSuppressed`：现在只在 `onChange(of: destination)` 写（`:826-830`）→ 改成「`destination == .agoraRoom || isXiaoya`」，并在 `.task(id: currentProfile.id)`（`:822-824` 旁）里也写一次（整树重建后 `onChange` 不触发）。
  - mac `macChatContent`（`:2141`）同样加分支，排在 `CodingSessionLibrary` 之后。
  - `ensureDraftConversation`（`:135-152`）在小芽楼层直接 return（不给她的楼层托底主聊天草稿）。
- page0 在小芽楼层：见待拍板 2（推荐：对话列表区换成一行说明「小芽的话都在她的房间里」，隐藏新对话 / 导入按钮）。
- 在小芽楼层点 page2 的「小芽」app：见待拍板 3（推荐：iOS 翻回 page1；mac 右栏显示一行「她就在左边」）。
- 键盘：照 `AgoraRoomView` 自带 composer 的做法；page2 版小芽现有的「弹键盘舞台收起」（`AssistantPanelView.swift:44-51`）原样带过去。**这是最可能踩雷的地方**（记忆里一长串键盘 × 宿主陷阱），实施时读 `docs/playbook-perf.md` 和 `feedback_nested_hosting_controller_keyboard` 再动。

### 2.3 同一个引擎、同一份对话

- P1b 已单例。这里补：engine 的 `.profileWillSwitch` 静默取消（`AssistantEngine.swift:68-70`）保留——只取消**正在生成的真 AI 回复**；本地剧本（P4）不受它影响。
- engine 不再在没模型时回固定一句「去「设置 → 小芽」给我装个本地大脑」（`:103-106`），改成 H10 口径：「先在「设置 › 模型和API」接一把钥匙，或者跟我说「配钥匙」」（P4 接上「配钥匙」关键词前，这句先这样写）。

### 2.4 目标楼层 + 舞台「正在帮：某某」

**现状**：工具一律「当前楼层」：`AssistantEnv.profileId = currentProfile.id`（`Services/Assistant/AssistantTools.swift:16`），读预设 / 改预设 / 建预设读 `env.profileManager.currentProfile`（`:230,356,370,406`），世界书按 `env.profileId`（`:422,443,453,556`），`query_memories` 同（`:274-277`）。盖章侧 `LiveAssistantWorkspace` 也读 `currentProfile`（`Services/Assistant/AssistantStamp.swift:301-307`），`validate` 用 `change.profileId == ws.profileId` 做楼层锚（`:68`）。

**做法**：
- `AssistantEnv` 加 `let target: Profile?`，`profileId` 改读 `target?.id ?? ""`；上面 7 处 `currentProfile` 全改 `env.target`（没有目标楼层时这些工具返回「还没有 Ta 的楼层——跟我说「建一个 Ta」」，`isError = false`）。`LiveAssistantWorkspace` 同改：`currentPresetId` / `setCurrentPresetId` 读写 target（`updateProfile` 本来就支持非当前楼层，`MemoryPalaceApp.swift:334-342`）。
- 目标解析 `XiaoyaTarget.resolve(current:profiles:defaults:) -> Profile?`：当前不是小芽楼层 → 当前楼层；是 → `xiaoya.targetProfileId`（存在且不是小芽楼层）→ 否则 `taFloors.first` → 否则 nil。
- 「最近待过的 Ta 楼层」记录点：`ProfileManager.switchTo`（`:267`）切走前 `if !currentProfile.isXiaoya { defaults.set(currentProfile.id, forKey: "xiaoya.targetProfileId") }`；启动时当前楼层不是小芽楼层也记一次。舞台小票点开选别的 Ta 楼层 → 写同一个键。
- engine 的楼层锚：`originProfileId`（`:58,116,351`）改存 **target id**；切楼层后 target 变了才取消工具轮。
- 舞台：`XiaoyaStageView`（`Views/Assistant/XiaoyaStageView.swift:8-19`）加 `helping: String?` + `onPickTarget`；名字小票下一行「正在帮：澪 ›」，点开 `taFloors` 菜单。在 Ta 楼层的 page2 app 里也显示（就是当前楼层，不可切）。
- **小芽楼层自己的预设 / 世界书不对外**：小芽楼层右上角的楼层设置入口在房间里不挂（房间没有那个顶栏）；工具层永远拿不到小芽楼层（target 解析排除它）。

### 2.5 名字和人设收口

- `AssistantPrompts.assistantName`（`Services/Assistant/AssistantPrompts.swift:15-21`）→ 恒为「小芽」；`englishName`（`:24`）恒为「Lily」。`nameKey` 不再读（**键不删**，降级回旧版时她以前改的名字还在）。
- `personaLayer`（`:42-46`）：`proMode && override 非空` → `"你叫「小芽」（英文名 Lily），名字不能改。\n" + override`；否则内置人设。lite 下覆写不生效（键保留）。
- `XiaoyaSettingsTab`：删「名字」Section（`Views/Assistant/XiaoyaSettingsTab.swift:8,18-28`）；人设覆写 Section（`:77-96`）只在 pro 显示，footer 写「只改口吻，不改名字」。`SettingsSearch.swift:211` 关键词去掉 `rosemary`。
- 订阅残留：`AssistantPanelView.swift:17`、`AssistantProposalCard.swift:19` 的 `xiaoyaNameSubscription` 一并删掉（本改动造成的废代码）。

### 2.6 CharacterFloorService 不自动切

- `enter(card:)`（`Services/CharacterFloorService.swift:30-88`）加 `activate: Bool = true`，传到 `:50` 的 `switchTo` 和 `:86` 的 `publish(activate:)`。现有调用方不变；P4 的导卡卡片传 `false`。

**数据（P2 全部）**：楼层列表多一项 `xiaoya`；UserDefaults 新键 `xiaoya.targetProfileId`。
**迁移**：升级用户启动即补楼层；`history.json` 不迁（本来就全局）。第一次进小芽楼层她说一句「我搬家啦」——由 engine 在 `messages` 非空且没有搬家标记时追加一条本地消息（标记 `xiaoya.movedInV1`）。
**回滚**：旧版读到 `xiaoya` 楼层 = 一个普通楼层（能删能改，page1 是普通聊天）；`xiaoya.name` 还在，旧版名字照旧。无数据损坏。
**对应**：§六-4、§七-1/3/4/5；H6 前置（`activate:false`）。
**风险**：
- 楼层列表顺序：插第 0 位后 `profiles.first` 兜底（`MemoryPalaceApp.swift:838`、`deleteProfile` 后 `switchTo(profiles[0])` `:408`）会落到小芽楼层——对升级用户删光 Ta 楼层的情况是合理的（她的家），但要确认没有别的地方把 `profiles[0]` 当「默认聊天楼层」用（实施时 grep `profiles\[0\]` / `profiles.first`）。
- 推送 / 来电落点（`ContentView.swift:880-940`）：对话不会落在小芽楼层，不受影响。
- 小芽楼层也会被文件库、搜索索引、收尾巡检等「按楼层遍历」的后台任务看到——它没有对话，开销近零；文件库会给它建空目录（可接受）。
**验证**：
- 单测 `XiaoyaFloorTests`：`ensureXiaoyaFloor` 幂等、插第 0 位、只读时不写、不改 `currentProfile` / `lastProfileId`；`deleteProfile` 拒删；`updateProfile` 拒改名。
- 单测 `XiaoyaTargetTests`：四种解析分支 + 目标楼层被删后的兜底。
- 单测 `AssistantToolsTargetTests`：在小芽楼层、target = Ta 时 `propose_update_preset_slot` / `add_world_book_entry` 的 `profileId` 是 Ta；盖章 `validate` 通过；target 为 nil 时返回指路文字。
- 单测扩 `CharacterFloorServiceTests`：`activate:false` 不切楼层、楼层已发布。
- 单测 `AssistantPromptsTests`：lite / pro、有无覆写四格，名字恒为小芽。
- 粟粟 sim 看：①楼层列表第一层是「小芽」，删 / 编辑按钮没有；②进小芽楼层 page1 是舞台 + 对话，往上翻是以前的小芽聊天，第一次进有「我搬家啦」；③在「澪」楼层开 page2 小芽 app，和 page1 房间是同一段；④在小芽楼层说「把澪的预设温度调低一点」→ 提案卡写着改的是澪，小票「正在帮：澪」可切；⑤pro 下她也叫小芽。

---

## 3. P3 引导卡组件

**现状**：`AskCardView` 交互依赖 `ConversationViewModel` 环境（`Views/Cards/AskCardView.swift:9`，没有就只读 `:41-50`），加密字段进 `SecretVault`（`:329-345,583-611`）不是 `APICredential` + 钥匙串——研究结论是复用不成立（research §2）。

**做法**：新目录 `Views/Assistant/Onboarding/`，模型与视图分开，全部不依赖 `ConversationViewModel`：

| 文件 | 内容 | 小样对应 |
|---|---|---|
| `XiaoyaCard.swift`（模型，放 `Models/AssistantTypes.swift` 旁或同目录） | `enum XiaoyaCard: Codable { choice, keyForm, importCard, nameForm, floorExit, pair, todo, info, makeTa }` + 各自 payload；`XiaoyaCardAnswer: Codable`（已选项 / 已存卡摘要 / 已导卡名 / 起名结果 / go·stay / paired·later / skipped） | `choiceCard` `keyCard` `importCard` `nameCard` `floorCard` `pairCard` `todoCard` `infoCard` |
| `XiaoyaCardChrome.swift` | 卡外框 / 标题 k / 问句 q / 收起后的 summary 行 / 结果条（wait / ok / bad 三态）/ 按钮三档（b1 实心、b2 描边、b3 文字）；颜色取 `XiaoyaSkin`（`Views/Assistant/XiaoyaSkin.swift:20-38`），圆角 / 间距对齐 AskCard | 小样 `.card` `.res` `.acts` |
| `XiaoyaChoiceCardView.swift` | 选项行（标题 + 小字 + ›），点过变 ✓ 收起，不可再点 | ② 分流卡、技术线「有 Mac 吗」、小白「建一个 Ta？」 |
| `XiaoyaKeyCardView.swift` + `XiaoyaKeyCardModel.swift` | 服务商 chips（OpenAI / Anthropic / Gemini / 自定义中转 / 更多 14 家…→ 全量预设列表）；自定义时协议分段（OpenAI 兼容 / Anthropic 兼容）+ 地址 + 「实际请求：」规范化后的完整 URL；key 框带眼睛切明文；「测一下」→ 测试中 → 失败条（状态码 + `humanReason` + 上游原文 + 请求地址，按钮变「改好了，再测一次」）/ 成功条（拉到的模型单选，第一个标「★ 省钱好用」，可手填模型 ID）→「就用这个」/「换一家」/「先跳过」。草稿只在内存（`CredentialDraft` + key 字符串），**改服务商 / 协议 / 地址 / key 任一项 → 作废上次结果回编辑态并提示一行**；保存走 `CredentialCommitter.commit(adopt: .model(picked))` | ③–⑦ |
| `XiaoyaImportCardView.swift` | 选文件（.png / .json）→ 读卡中 → 摘要（名字、开场白数、内嵌世界书条数、卡自带系统指令）+「卡里的 {{user}} 会叫你「X」」→「好，就是 Ta」；坏文件给原因可重选 | ⑨ |
| `XiaoyaNameCardView.swift` | Ta 的名字（必填、不预填）/ Ta 怎么称呼你（选填）/ Ta 是个什么样的人（选填一句）+ 说明「我还是叫小芽」→「建好 Ta 的楼层」 | ⑪ |
| `XiaoyaFloorExitCardView.swift` | 新楼层摘要 +「没有自动切过去」+「去找 X →」/「继续问我」+ 追加按钮（导入世界书 / 导入预设 / 导入以前的聊天记录） | ⑩ ⑭ |
| `XiaoyaPairCardView.swift` | 两步说明 +「打开相机扫码」（iOS 用 `CCPairScannerSheet` `Views/CCPairingViews.swift:235`，落地 `CCPairingApply.apply` `:214`）/「以后再说」；mac 上不出这张卡 | ⑫ |
| `XiaoyaTodoCardView.swift` / `XiaoyaInfoCardView.swift` | 「你可以试试」三四条（只读，不打勾）；说明卡（剪纸小头像 + 「以后在任何楼层打开小芽 app，都是在这儿跟我说话」） | ⑭ |

- 卡片对外只暴露 `onAnswer: (XiaoyaCardAnswer) -> Void`，由 P4 的剧本引擎接；**P3 本身不写任何数据**（key 卡的保存回调里才调 P1 服务，回调由 P4 注入）。
- DEBUG 预览台：`#if DEBUG` 一个「小芽卡片样张」页（照现有 DEBUG 测试台入口挂），把 16 屏里每张卡的各状态摆出来，方便不接剧本就验视觉。

**数据**：无。
**迁移 / 回滚**：新文件，revert 即删。
**对应**：H1（失败条四样 + 不自动往下走）、H2（改任一项作废、只有「就用这个」落盘）、H3（协议分段 + 规范化地址给看，规范化用 `BaseURLNormalizer.normalize`，与保存同一函数）、H4（眼睛）、H5（模型单选 + 手填 + `Adopt.model`）、H10 文案。
**风险**：
- 「更多 14 家…」要接全量 `APIProvider.presets`（`Models/APIProvider.swift:199` 一带），单例类（Claude Code / Codex / ChatGPT 账号 / 本机模型）**不进引导卡**——它们不是「一把 key」，引导里出现会和测试流程冲突；技术用户自己去设置页加。
- key 输入框要关掉自动大写 / 自动纠错 / 智能标点（iOS 粘贴 key 被改成弯引号是老坑）。
**验证**：
- 单测 `XiaoyaCardCodableTests`：每种卡 + 答案往返编解码；缺字段的旧数据能解。
- 单测 `XiaoyaKeyCardModelTests`：作废规则（四种改动 × ok/fail 两态）、`canTest` / `canSave`、`humanReason` 映射（401 / 404 / 超时 / 5xx / 连不上）。
- 粟粟 sim 看（DEBUG 样张页）：深浅两色各一遍，对照小样逐张看；key 框点眼睛；自定义中转输地址看「实际请求」实时变。

---

## 4. P4 本地剧本引擎 + 五条分支 + 交接

### 4.1 消息与进度存哪

- `AssistantChatMessage`（`Models/AssistantTypes.swift` 消息结构，现字段 `id,isUser,text,actions,createdAt`，自定义 decode 全 `decodeIfPresent`）加两个可选字段：
  - `source: Source?`（`.script` / `.handoff`；nil = 旧数据 = 普通对话）
  - `card: XiaoyaCardState?`（卡定义 + 答案；答案为 nil = 还没答）
  - `text` 里**总写一句可读兜底**（卡的问句 / 收起后的摘要），保证旧版 App 读到时显示成普通一句话。
- 剧本进度单独一份 `Application Support/AssistantChat/script.json`：`{ scriptId: "onboarding.v1", step: "key", identity, taProfileId, taName, userName, keySaved, keySkipped, startedAt }`。与 `history.json` 同目录 → P1b 的备份自动带上（导出时把整个目录的 `*.json` 除 corrupt 都带）。
- **进度 = 对话本身 + script.json**，不靠进程内单例（替掉 `OnboardingResume`，H6）。App 被杀 / 切楼层 / 整树重建后，engine 读 `script.json` + 最后一张未答的卡，原地接着等。
- key 永远不进 JSON（草稿只在内存）：中途被杀，key 卡回到空表单（服务商选择也不保——与 H2「测试不落盘」一致）。

### 4.2 剧本引擎

- 新 `Services/Assistant/XiaoyaScript.swift`：`@MainActor final class XiaoyaScriptRunner`，挂在 `AssistantEngine.shared` 上（`engine.script`），状态机节点 = 小样 `NOTES` 的 id：`open → identity → key(testing/fail/ok) → saved | skipkey → {newbie | tavern → tavernDone | companion | tech | ghost} → end`。
- 台词表 `XiaoyaScriptLines.swift`：逐字取小样 `run()` / 各分支函数里的台词（`intro` 四种、ghost 两句、`TODO` 三组、`end` 的「搞定啦」等），集中一处方便以后改。打字节奏：每句前 0.4–0.9 s「在想」+ 逐段出现；**节奏时钟可注入**，测试用零延迟。
- 舞台表情：剧本节点 → `XiaoyaMood`（小样 `mood()` 的映射：smirk 在呢 / huh 在想·在试钥匙·在读卡 / cheer 钥匙好使·读好了 / sob 没连上 / love 搞定啦），通过 `XiaoyaStageState` 加一个 `scriptMood` 覆盖层（`AssistantEngine.swift:77-89` 现有 base + feedback 两层之上）。
- 输入框：剧本在等卡片答案且**还没有可用模型**时锁住（placeholder「先回答上面的卡片～」）；钥匙存好后放开——**卡片还在，打字走真 AI**，卡片照样能点（§七-6）。
- 本地关键词（待拍板 4）：本地模式、或真 AI 模式下整句恰好等于「配钥匙 / 建一个 Ta / 连电脑 / 导卡」（含输入框上方的快捷 chips），由剧本接，不发给模型。

### 4.3 五条分支落地（写什么、存哪）

| 节点 | 写入 | 实现位置 |
|---|---|---|
| identity | `onboardingIdentity`；`settings.proMode` 默认值（小白 / 陪伴 lite，其余 pro，**只在这里写一次**）；`script.json.identity` | 照 `OnboardingFlowView.swift:271-293` |
| key → saved | `CredentialCommitter.commit(adopt: .model(picked))`：卡 + 钥匙串 + 收藏 + 主模型（K3）；`script.json.keySaved` | P1a |
| skipkey | 不写卡；`keySkipped` | — |
| tavern | `cardManager.importFromFile` → `floors(...).enter(card:, activate: false)`（P2.6）→ 楼层已发布但不切；出口卡「去找澪」才 `switchTo`；追加「导入世界书 / 预设」**显式以 `taProfileId` 为落点**（不读 `currentProfile`——旧代码 `:463-505` 读当前楼层就是 H7 的病根）；预设导入前提示「会替换卡自带的系统指令吗」 | 新 `Services/OnboardingFloorFactory.swift` 包一层 |
| companion | 新楼层（照 `ProfileEditorSheet.save` create 分支 `MemoryPalaceApp.swift:2177-2194` + `instantiatePreset` `:2224-2238`，但 **`persistNew` + `publish(activate:false)`，不用会切楼层的 `addProfile`**）：`assistantName` = Ta 名、`userName` = 称呼（空 → 默认称呼 → 「你」）；「Ta 是谁」填了才写 Ta 楼层预设实例的 `charDescription` 槽（照 `OnboardingFlowView.swift:976-984`，但写 Ta 楼层的实例不是当前楼层的）；称呼写默认身份（§4.4） | `OnboardingFloorFactory.createTa(name:userName:who:)` |
| tech | 有 Mac → 扫码卡，`CCPairingApply.apply`（和设置页同一份） | P3 |
| ghost | `onboardingIdentity = ghost`、`proMode = true`、`onboarding.xiaoyaV1 = done` + 推送权限；两句指路 + 说明卡 | — |
| end | 待办卡（按分支三条，没钥匙时第一条插「配一把钥匙」）+ 出口卡（有 Ta：去找 X；没 Ta：建一个 Ta → 走 companion 起名）+ 说明卡；`onboarding.xiaoyaV1 = done`；**同时写 `onboardingCompletedV1 = true`**（降级回旧版不再弹六页）；iOS `PushAppDelegate.requestAuthorization()`（`PushNotifications.swift:28-33`） | — |
| 小白 · 跟我说句话 | 只在有钥匙时出（没钥匙直接 end）；三个建议 chip；回复走真 AI | engine.send |

- 「去找 Ta」= `profileManager.switchTo(ta)`；整树重建后 engine 是单例、`script.json` 已是 done，不会重置（H6）。
- 引导期间（`onboarding.xiaoyaV1 == started` 且没存钥匙）engine **强制本地模式**：新装时 `selectedChatModel` 可能是示例卡模型或桥卡（`Models/APIProvider.swift:576-606` 新装种了 Claude Code / Codex / 示例 API 并收藏），`XiaoyaModelChoice.modelId`（`AssistantEngine.swift:9-12`）会解析到它们；加一道 `providerManager.isModelUsable`（`APIProvider.swift:793`）+ 引导中判断，避免新用户第一句话撞到示例卡报错。

### 4.4 默认称呼（H9）

- 新键 `garden.defaultUserName`；写入点：companion 起名卡的「怎么称呼你」、以后设置 › 通用改称呼时（`Views/GeneralSettingsPages.swift:17-81` 那块，只加一行同步）。
- 读取点：`CharacterFloorService.floorUserName`（`Services/CharacterFloorService.swift:126-129`）链首插 `garden.defaultUserName`（现在链首是 `currentProfile.userName`——人在小芽楼层导卡时读到的是小芽楼层的 userName，所以小芽楼层的 `userName` 也同步写成默认称呼）；`ProfileEditorSheet` 新建时 userName 预填它（`MemoryPalaceApp.swift:2183` 现为空则「你」）。
- `onboardingUserName`（无人写了）保留在读取链末尾不删（兼容老数据）。

### 4.5 与真 AI 交接（§七-6 / research §4）

- `wireHistory`（`AssistantEngine.swift:244-261`）：跳过 `source == .script` 的消息（包括用户点卡生成的「我是小白」气泡）和带 `card` 的消息；遇到 `source == .handoff` 的那条，转成一条「（系统备注，不是用户说的，也别在回复里写：用户刚走完开场引导——称呼 X、园丁类型 Y、已配好 Z 的钥匙（模型 M）、Ta 的楼层：W）」挂到下一句用户话前面——**复用现有 notes 机制**（`:249-253` 已经这么挂提案状态），不发明新通道。
- `.handoff` 消息在 saved 节点追加（也就是小样里那条分隔线「钥匙接好了 · 从这里起小芽用 M 说话」），UI 上渲染成分隔线。
- `localHistory`（本机模型，`:266-277`）只取最后一句用户话，天然不受影响。
- system prompt 加一层「关于你在帮的人」（待拍板 1）：称呼、园丁类型、有没有 Mac、Ta 楼层清单，从 `script.json` + 楼层列表现拼，2–4 行。

### 4.6 H8：Ta 名 / 称呼在 Prompt 页看得见

- 现在名字只在 设置 › 通用 改（`Views/GeneralSettingsPages.swift:17-81`），Prompt 页（`Views/PersonaSettingsTab.swift:1579` `iOSPromptPage`）顶上没有。加一行只读摘要「Ta 叫 X · 叫你 Y ›」，点了去通用页那两个框。小改动，但碰的是 page1/设置地盘，单独一个提交。

**数据（P4 全部）**：`history.json` 两个可选字段；新文件 `script.json`；UserDefaults `garden.defaultUserName`；新楼层 / 卡 / 世界书 / 预设实例照现有服务写。
**迁移**：无老数据要迁。
**回滚**：旧版解 `history.json` 忽略未知键，卡片变成一句普通话（兜底 text）；旧版再写盘会丢掉卡片字段——可接受（引导早已走完）。`script.json` 旧版不读。
**对应**：H6、H7、H8、H9、H10、H11（proMode / 推送）。
**风险**：
- 剧本与真 AI 并行：用户在卡片未答时打字 → 真 AI 回复插在卡片下面，卡片仍有效；答完卡片后剧本的下一句要接在**最末尾**而不是卡片后面（不插队，按时间追加）。
- 导卡建楼层失败（只读、存储失败）：`CharacterFloorService` 已有回滚（`:69-85`），卡片显示失败原因、可重试，不前进。
- 人在 Ta 楼层用 page2 小芽 app 时剧本还没走完（例如点了「去找 Ta」之后的「继续问我」场景）：卡片在两个入口都是活的，答案写同一个 engine，天然一致。
**验证**：
- 单测 `XiaoyaScriptTests`（零延迟时钟）：五条分支 × 有钥匙 / 跳过钥匙的完整节点序列和写入（用内存 `UserDefaults` + 临时 `ProfileManager` root + 注入 store）；中途重建 engine（读 `script.json`）后从未答卡片继续；ghost 不出钥匙卡；没钥匙的小白直接 end；end 后 `onboardingCompletedV1` 也为真。
- 单测 `XiaoyaWireHistoryTests`：剧本消息不进 wire；交接备注只出现一次、挂在下一句用户话前。
- 单测 `OnboardingFloorFactoryTests`：建 Ta 楼层不切楼层；预设实例归属 Ta；charDescription 只在填了时写；世界书 / 预设导入落 Ta 楼层（当前楼层是小芽楼层时也对）。
- 单测扩 `CharacterFloorServiceTests`：`floorUserName` 读 `garden.defaultUserName`。
- 粟粟 sim（DEBUG 里「从头放一遍引导」按钮，不碰新装判定）：五条线各走一遍；测试连接用一把错 key 看 401 条、改对再测；酒馆线导一张卡点「继续问我」→ 再点「去找澪」→ 开 page2 小芽 app 往上翻是引导；陪伴线起名后去 Ta 楼层 Prompt 页顶上看名字。

---

## 5. P5 接通：新装判定、删旧引导、mac、推送

### 5.1 新装判定 + 种子

**现状**：iOS 按 `onboardingCompletedV1` 盖 fullScreenCover（`Views/ContentView.swift:64,779`），mac 没有引导；推送授权启动时按 `onboardingCompletedV1` 决定（`PushNotifications.swift:20`）；楼层列表读空才种 seed（`MemoryPalaceApp.swift:444,452-458`）。

**做法**：
- 新键 `onboarding.xiaoyaV1`：nil（未判定）/ `started` / `done` / `upgraded`。
- 判定 `FreshInstallProbe.decide(...)`（纯函数，放 `Services/Onboarding/`），**启动时只判一次**，结果写进键后不再判：
  - 楼层列表读坏（只读）→ **不判、不写、不种、不开引导**（下次启动再判）。
  - `onboardingCompletedV1 == true` → `upgraded`。
  - 楼层 id ⊆ {`default-workspace`, `xiaoya`} **且** 对话数 0（`fetchCount(Conversation)`）**且** 没有自建 API 卡（排除 `cc-bridge` / `codex-bridge` / `example-api` / `local-mlx` 这些自动种的）**且** 卡库为空 → `started`；否则 `upgraded`。
- 种子：`seedAndSave`（`:452`，只在楼层列表真为空——即真正第一次启动——才走）改成：`onboardingCompletedV1 == true`（UI 测试 / 测量台用 `-onboardingCompletedV1 YES` 起新模拟器，见 `StickerProbeUITests/Page2FolderTouchUITests.m:42,91,432`）→ 种 [小芽, 对话空间] 且 `lastProfileId = default-workspace`，保住这些测试落在聊天页；否则只种 [小芽]（§七-2）。`Profile.seedProfiles` 的只读兜底语义不变（`ProtectedDataGateTests` 断言用的是它本身，跟着走）。
- `started` → 当前楼层 = 小芽楼层，`XiaoyaScriptRunner.start(.onboarding)`；`upgraded` → 什么都不弹，只靠 P2 的 `ensureXiaoyaFloor`。

### 5.2 删旧引导

- 删：`Views/Onboarding/OnboardingFlowView.swift`（1119 行，含 `OnboardingResume`）、`AstralWelcomeView` / `AstralIdentityView` / `AstralIdentityChoice` / `AstralPalette` / `PixelArtView`（只被旧引导用，已 grep 确认）；`ContentView.swift:63-64,779` 的 cover；`SettingsView.swift:101,300` 的 cover。
- **保留** `LitePersonaCoachView`（`LitePersonaPage.swift` 还在用）。
- 设置页搜索框「?」→「新手引导」（`Views/SettingsView.swift:298`）：改成关设置、切到小芽楼层、`script.start(.replay)`（待拍板 5）。
- `PushAppDelegate`（`PushNotifications.swift:18-20`）：启动请求授权的条件改为 `onboardingCompletedV1 || xiaoyaV1 ∈ {done, upgraded}`；`started` 的人等剧本 end / ghost 时请求（H11）。
- `xcodegen generate`（删文件后必须）。

### 5.3 mac 首启

- mac 走同一套：`started` 时当前楼层 = 小芽楼层，`macChatContent` 显示房间（P2 已接）；扫码卡在 mac 不出（技术线的「有 Mac 吗」在 mac 上改问「要连手机吗」→ 指到 设置 › 连接手机，**只指路不扫码**）。推送相关 mac 无操作。
- iPad：与 iOS 同路径，宽屏面板模式下房间在中间卡里（`isWidePanelMode` 只影响 page0/2 浮层），需 sim 看一眼。

**数据**：UserDefaults `onboarding.xiaoyaV1`。
**迁移**：升级用户第一次启动新版 → `upgraded`，无感（楼层已在 P2 补）。从没走完旧引导但用过 App 的老用户（`onboardingCompletedV1 == false` 但有对话 / 卡）→ `upgraded`，**不会被拉进新引导**（research §4 的最大坑）。
**回滚**：revert P5 → 旧六页回来；新装且走完新引导的人 `onboardingCompletedV1` 已为真，不会再弹；新装中途回滚的人会看到旧六页（可接受）。
**对应**：H11；§七-2/7；research §4 首启判定、mac。
**风险**：
- 判定读 SwiftData 计数要在容器就绪之后、且不能卡主线程太久（`fetchCount` 一次，开销可忽略，但放在 `LaunchTrace` 里量一下，别让冷启动回归——读 `docs/playbook-perf.md`）。
- iCloud / 备份恢复：新机先装、先走引导、再恢复备份 → 楼层列表被替换，下次启动 `ensureXiaoyaFloor` 补回小芽楼层，`history.json` 按 P1b 规则：包里有就用包里的（会覆盖刚走的引导对话）——可接受，属预期。
**验证**：
- 单测 `FreshInstallProbeTests`：判定矩阵（只读 / 旧键真 / 只有种子无对话 / 有对话 / 有自建卡 / 只有示例卡和桥卡 / 有卡库）。
- 单测 `LaunchSeedTests`：真空列表 × 旧键真 / 假 两种种子；`PushGateTests`：授权条件纯函数。
- 粟粟 sim：**全新模拟器**装一遍（iPhone + mac 各一次）→ 直接落在小芽房间，前三句打字出现，完整走一条；再用**升级场景**（先装 master 版、建点数据、再覆盖装新版）→ 不弹、多一层小芽、当前楼层没变。设置「?」→ 新手引导 → 跳到小芽楼层重走。

---

## 6. 撞车面

### 6.1 API 线（backend-001；thinking 回传已在 `zone/backend-2` 合进 master `d4a4e955`）

- API 线接下来要做的「表单草稿保活」「报错『去改』」「引导里的 Anthropic 中转协议切换」（`docs/plan-uiux-editor-tavern-ia.md:159`、`docs/plan-api-wave1.md:100-101`）都落在 `APICredentialEditor`；P1a 抽服务正好改它的 `makeDraft` / `persist`。目前 `zone/backend-*` 没有任何一条分支动过 `APICredentialEditor.swift` / `ProviderProbe.swift`（已核 `git diff master...zone/backend-N`）。
- **建议（推荐 A）**：
  - **A. P1a 由本线先做、先合**，范围严格限定「抽取 + 行为不变 + 不改任何文案」，1 个文件改 + 2 个新文件，一天内可合。合之前经 Warden 通知 API 线：草稿已是 `Codable` 的 `CredentialDraft`（不含 key），「草稿保活」直接拿它存；「报错去改」可复用 `ProviderProbe.humanReason`。同时请 API 线**从清单里划掉「引导 Anthropic 中转」**——旧引导 P5 删除，新引导 key 卡已按 H3 带协议切换，修旧的是白干。
  - B. 把 P1a 整个交给 API 线做（它本来就要动这块），本线 P3 的 key 卡先对着约定接口写、等它合了再接。代价：P3/P4 的关键路径挂在别人的排期上。
  - 无论 A / B：**不要两边同时改 `APICredentialEditor.swift`**；谁先动谁先合，另一边 `git merge master` 后再动。
- `ProviderManager.adoptNewModel` 的 K3 口径（`APIProvider.swift:805-811`）是 API 线 10-14 定的，本线只调用不改。

### 6.2 其他工位

| 地盘 | 本 plan 会碰 | 现状 | 建议 |
|---|---|---|---|
| page1（`ContentView.swift`、`InputBarStack`、Prompt 页） | P2 房间分支、输入条抑制；P4 Prompt 页一行名字 | `zone/page1` / `page1-2` 领先 0 | P2 动 `ContentView` 前问 Warden 有没有人在改；Prompt 页那行单独提交 |
| page0（侧栏、`ProfileSwitcher` 在 `MemoryPalaceApp.swift`） | P2 小芽楼层的 page0 显示、删除 / 编辑入口 | `zone/page0` 领先 0 | 同上 |
| mac（`macChatContent`） | P2 房间分支 | `zone/mac` 领先 11，**没碰**上述热点文件（已核） | 合 P2 前 `git merge master` 一次 |
| 备份（`GlobalBackup/`） | P1b 导出 / 导入 / 恢复各加一段 | 无人在改 | — |
| 卡库（`CharacterFloorService`、`CharacterWallView`） | P2 `activate:` 参数、小芽磁贴 | 本工位自己的线（卡库在 page2-apps） | — |

### 6.3 本工位（page2-apps）现状

- `git log master..HEAD`：只有本引导的两笔 docs（`a6a3f247a` research + 小样、`3c36cad15` plan 拍板），没有代码。
- `git status`：**另一个 agent 的未提交改动** `Services/LineDiff.swift`、`Views/FileLibrary/FileVersionHistoryView.swift`、新测试 `MemoryPalaceTests/LineDiffInlineTests.swift`（文件库版本历史的行内 diff），与本 plan 零重叠。
- 按「每工位 WIP=1」：那件事合掉之前，本工位不开 P1；或 P1 / P3 在别的空工位做（见 §8 并行建议）。

---

## 7. 拍板（2026-10-15 粟粟：全部按推荐）

1. **小芽自己的「记忆」**（research §1-5，§七 没覆盖）：推荐**不接记忆系统**，只给她一页「备忘」——称呼、园丁类型、有没有 Mac、Ta 楼层清单，从 `script.json` + 楼层列表现拼进 system prompt；`query_memories` 继续查目标 Ta 楼层的记忆。以后要她「记住你喜欢什么」再单独立项。
2. **小芽楼层的 page0（对话列表）**：推荐对话列表区换一行「小芽的话都在她的房间里」，隐藏新对话 / 导入按钮；楼层切换照常。（不这样的话，用户可能在小芽楼层建出一堆普通对话，和「小芽楼层 = 小芽」矛盾。）
3. **在小芽楼层点 page2 的「小芽」app / mac 右栏开小芽**：推荐 iOS 直接翻回 page1 房间；mac 右栏显示一行「她就在左边」，不重复开第二个输入框。
4. **召回卡片的说法**：推荐本地精确匹配「配钥匙 / 建一个 Ta / 连电脑 / 导卡」+ 输入框上方常驻这几个小 chip（引导走完后只在小芽房间显示），不让模型决定出卡（延续 §七-6）。
5. **设置「?」→ 新手引导**：推荐跳到小芽楼层、加一条分隔线「再走一遍」、从分流卡重来；历史不清，`proMode` 只有重新选了园丁类型才重写。
6. **老用户以前给小芽改过的名字**：推荐静默不再用（键保留，降级回旧版还在）；第一次进小芽楼层的「我搬家啦」里顺带一句「以后就叫我小芽啦」。
7. **恢复旧备份（没有小芽那段）**：推荐保留本机现有小芽对话，不清空。
8. **P1a 归属**：推荐 A（本线先做、先合，通知 API 线复用）——理由见 §6.1。

---

## 8. 并行与派活建议

- **可并行**（不同 agent / 不同工位）：
  - Agent α：P1a（草稿服务 + 对拍测试）——或按 §6.1-B 交 API 线。
  - Agent β：P1b（单例 + 备份三处）。
  - Agent γ：P3 除 key 卡以外的全部卡片 + DEBUG 样张页（零依赖，P1 期间就能开工）；key 卡等 P1a 接口定了再写（接口签名本 plan §1 已给，可以先对着写）。
- **串行**：P2（依赖 P1b）→ P4（依赖 P2 + P3）→ P5（依赖 P4）。P2 内部 2.1–2.6 可拆两人：楼层 / 护栏 / 名字（2.1、2.5、2.6）与房间 / 目标楼层（2.2–2.4），但都碰 `MemoryPalaceApp.swift`，建议一人做完。
- 每阶段收口：astra + kimi 各审一轮（UI 多的 P2/P3 加 sol）；复盘 `review-onboarding-xiaoya-P<n>.md`；说明书事实层新建 `manual/facts/modules/xiaoya.md`（P2 起每阶段同步）。
- 实施任务书必写禁区：不改 `ProviderProbe.test` 行为、不改 K3 接管规则、不动 `.id(currentProfile.id)`、不迁小芽对话进 SwiftData、不加 `-derivedDataPath`；性能相关改动前读 `docs/playbook-perf.md`。

---

## 9. Todo

### P1a 草稿服务
- [x] 先写 `CredentialDraftTests` / `CredentialCommitterTests`，把抽取前的 `makeDraft` / `persist` 行为固化成期望值
- [x] 新建 `CredentialDraft`（Codable，不含 key）+ `makeCredential(id:existing:)`（`Models/CredentialDraft.swift`，Services/Providers 不存在）
- [x] 新建 `CredentialCommitter.commit(_:key:existing:adopt:providerManager:)`，含单例 id / 本机模型收藏 / forgetModels / Adopt 三种（`.model(modelId)` 不在清单上会补进清单再接管）
- [x] `ProviderProbe.humanReason(_:)` 纯函数 + 测试（编辑器不接；API 线 `FixJump` 只认聊天报错文字，没有可复用的 Failure → 人话映射）
- [x] `APICredentialEditor`：`makeDraft` → `CredentialDraft.makeCredential`；`persist` 主体 → `CredentialCommitter.commit`；ccBridge Hub 地址留在 View（偏离一处：卡 id 改按 `resolvedCredential` 取，编辑中卡被别处删掉的极端情况会存成新卡，原来是按旧 id 复建）
- [ ] 测试全绿 + 双端编译（Warden 集成区）+ sim 新建 / 改卡回归 —— 单测 + 本工位双端 build-for-testing 已过；sim 回归留给车头
- [ ] 经 Warden 通知 API 线：草稿结构可复用、划掉「引导 Anthropic 中转」

### P1b 单例 + 备份
- [x] `AssistantEngine.shared`；`AssistantPanelView` 默认用它；`AssistantEngineSharedTests`
- [x] 核 manifest 导入校验对未知 section 的处理（决定要不要加版本兜底）—— `validateWorkspace` 只逐个校验包里列出的 section、不认识的目录 staging 时不拷，不拒；不加版本兜底
- [x] `GlobalExporter.exportAssistantChat`（目录内 `*.json` 去 corrupt）+ section hash（没有可带的文件就不出这段）
- [x] `StagingPaths.stagingAssistantRoot` / `primaryAssistantRoot`；`GlobalImporter` 拷 staging；`PendingImportApplier` 归档（p1.8）+ 搬入（p2.12）+ 失败回滚列表 + `cleanupAllStagingArtifacts`
- [x] 包里没有这段 → 本机文件不动（归档步只在 staging 在时才动主位）
- [ ] `GlobalBackupAssistantTests`；mac 导出一次看包内容 —— 测试已过；mac 实导一次留给车头

### P2 小芽楼层
- [x] `Profile.xiaoyaId` / `xiaoyaFloor` / `isXiaoya`（name 小芽、🌱、description「小芽住在这里」、userName 先写「你」——§4.4 默认称呼 P4 才有）
- [x] `ProfileManager.ensureXiaoyaFloor()`（第 0 位、只读不写、不动当前楼层）+ 启动调用（仅 `profilesTrusted`）
  - 偏离一处：启动兜底 `profiles.first` 改成「先找第一个 Ta 楼层」——从没切过楼层的老用户 `lastProfileId` 是空的，不改的话第二次启动就落进小芽楼层（违背「不抢当前楼层」）
- [x] `deleteProfile` 拒删；`updateProfile` 拒改名 / emoji / assistantName（三项改回固定值，其余字段照收）
- [x] `ProfileSwitcher` 两端、`CharacterHomeView` 隐藏删除 / 编辑（CharacterHome 只藏「编辑楼层」，带卡的「编辑卡」不受影响）
- [x] `ProfileManager.taFloors`；逐处过 `.profiles` 调用点（~20 处）并在此记结论
  - 改用 `taFloors`：`AgentSettingsTab`（两处，自主任务按楼层开关）、`DeathScaleSheets:401`（哪些楼层能读天平）
  - 照旧全列：`ProfileSwitcher` 两端菜单（小芽排第一）、`FileLibrarySettingsTab:200/248`、`DataSettingsTab:151/963`、`GlobalExporter`（备份带上小芽楼层）、`SearchIndexer` reconcile、`migratePresetInstances`（小芽楼层也会拿到一份预设实例，不对外）、`VoiceServiceMigration`、`WorldBookLibraryView:43`（排序）
  - 按 id 查名字 / 查楼层，不涉及挑选，不改：`ImportView:231/244/284`（plan 原写「导入落点」，实际这三处是冲突报告的楼层名表；真正的落点是 `currentProfile`，见下条）、`ToolDrawerPage`、`MemoryPanelView:1180/1211`、`Memory*Sheet` / `WindowSummarySheet`、`RegexSettingsTab` / `PersonaSettingsTab` / `RegexLibrary`、`ContentView:409/497/891/910/954`、`CallController`、`SessionCloseout`、`VoiceServicesPage`、`CharacterFloorService`、`SillyTavernImport*`、各 Seed / PerfHarness 按 id 找测试楼层
  - `ImportView` 落点 = 当前楼层：小芽楼层没有对话列表，导进去看不见 → `.idle` 态换成一行「先切到一个 Ta 的楼层，再来导入」（设置 › 数据里的导入入口还在）
  - 角色墙：见下面磁贴那项
- [x] grep `profiles[0]` / `profiles.first` 确认没有「默认聊天楼层」语义
  - `MemoryPalaceApp` 启动兜底：已改（见上）
  - `deleteProfile` 删当前楼层后 `switchTo(profiles[0])` → 落小芽楼层：按 §2 风险条，接受（她的家）
  - `SillyTavernImportCommitter:156` 启动恢复用的临时管理器 `currentProfile: profiles[0]`（无副作用，只给撤回判「是不是当前楼层」）：可能是小芽楼层，无害，不改
  - `PerfBenchSeed:111`、`PerfChatCore:926`（bench 收尾回「第一个非 bench 楼层」）可能落小芽楼层：DEBUG / PERF 工具，不进上架包，不改
  - 其余全是 `first(where: id ==)` 按 id 查
- [x] 角色墙小芽磁贴（固定最前，点了只切楼层）——`CharacterWallItem.make` 把小芽楼层提到最前、不在尾部重复；点了不开 CharacterHome
- [x] `AssistantPanelView` 拆出 `XiaoyaConversationView`；page2 app 改用它（同文件；`AssistantPanelView` 成了外壳：小芽楼层里显示「她就在左边」）
- [x] `XiaoyaRoomView`；iOS `iOSChatPage` / mac `macChatContent` 按楼层分支；小芽楼层不挂 `iOSChatTopBar` / 岛（新文件 `Views/Assistant/XiaoyaRoomView.swift`；mac 排在 `CodingSessionLibrary` 之后）
  - 舞台左上加「≡ 小芽的楼层」签（照小样 floorchip，只 iOS 房间有，翻回 page0）；房间里角钮跟它一起提到顶（page2 app 里角钮位置不变）
  - 顺带：`PageSync` 的 `isChatDestination`、开屏 `launchRequired` 在小芽楼层按「不是聊天页」算（没有聊天输入条可等，开屏直接收）
- [x] `chatInputSuppressed` 按 `agoraRoom || isXiaoya`，`.task(id: 楼层)` 里也写——实现成独立 `XiaoyaFloorSync` modifier 里的 `onChange(initial: true)`（换掉原 `onChange(of: destination)`，iOSLayout 链长度不变）
- [x] `ensureDraftConversation` 小芽楼层 return（⌘N `handleNewConversationRequest` 同样拦）
- [x] page0 小芽楼层显示（按待拍板 2）；小芽楼层里的小芽 app / mac 右栏（按待拍板 3）
  - page0：列表区换成一张小卡「小芽的话都在她的房间里」；iOS 顶上「＋」藏起来但占位（字标那行高度不变）、mac 工具条新建 / 导入两钮不出；`createNewConversation` 兜底拦
  - page2：小芽 app 在前台（`page2AppActive`）就发 `.xiaoyaRoomRequested`，ContentView 只在 page==2 时翻回 page1 并把 page2 退回桌面；进小芽楼层时 page2 若停在小芽 app 先回桌面（不然一翻到 page2 就被弹回）。app 里留一行「‹ 她就在左边」，点了再翻
  - mac 右栏 / iPad 宽屏卡片：同一行「她就在左边」，不开第二个输入框
- [ ] 键盘：读 playbook + 键盘相关教训后接房间输入框，iOS / iPad sim 各验一遍 —— 接法已做（照中庭：根视图 `KeyboardSelfManaging`，内层宿主底边贴 `keyboardLayoutGuide`、`safeAreaRegions = .container`，整份环境原样带进嵌套宿主）；本 agent 不许碰模拟器，sim 留给粟粟
- [x] 无模型兜底文案改 H10 口径
- [x] `AssistantEnv.target` + 7 处 `currentProfile` → target；`LiveAssistantWorkspace` 同改；target 为 nil 时指路（target 是现算的计算属性 + 可注入 defaults，不是 `let`：同一轮里小票换了目标，引擎楼层锚就对不上、工具轮作废）
- [x] `XiaoyaTarget.resolve`；`switchTo` 记 `xiaoya.targetProfileId`；启动补记（新文件 `Services/Assistant/XiaoyaTarget.swift`）
- [x] engine 楼层锚改 target id（`originProfileId = env.profileId`，而 `profileId` 已是 target id，引擎本身不用改）
- [x] 舞台小票「正在帮：X ›」+ 切换菜单（只在小芽楼层可切；Ta 楼层的 page2 app 里是不带箭头的一行；弹键盘收起时不显示）
- [x] 名字恒为小芽 / Lily；人设覆写只在 pro 且带名字前缀；删设置名字 Section、搜索词、两处 `xiaoyaNameSubscription`（连同两处 `proModeSubscription`——名字不再随 pro 变，也成了废代码）
- [x] `CharacterFloorService.enter(card:activate:)`
- [x] 「我搬家啦」一次性消息（`xiaoya.movedInV1`）——房间 `onAppear` 调 `engine.noteMovedIn()`；没聊过的不说但标记照落；旧版叫过别的名字（改过名 / pro 的 Rosemary）才补「以后就叫我小芽啦」
- [x] 测试：`XiaoyaFloorTests` / `XiaoyaTargetTests` / `AssistantToolsTargetTests` / `AssistantPromptsTests` / `CharacterFloorServiceTests` 扩
- [ ] 粟粟 sim 五项（§2 验证）

### P3 引导卡组件
- [x] `XiaoyaCard` / `XiaoyaCardAnswer` / `XiaoyaCardState` 模型 + `XiaoyaCardCodableTests`（放 `Views/Assistant/Onboarding/`；kind 分派手写编解码，未知卡 / 答案解成 `.unsupported`；多一个 `.goTa` 卡＝小样 end() 的「出口 · 去找 X」）
- [x] `XiaoyaCardChrome`（外框、summary、结果条三态、按钮三档；颜色走 `XiaoyaSkin`——给 `XiaoyaSkin` 加了 `ok` / `bad` / `field` 三色，深浅各一套）
- [x] 选择卡
- [x] key 卡模型 `XiaoyaKeyCardModel`（作废规则、canTest / canSave）+ `XiaoyaKeyCardModelTests`
- [x] key 卡视图（服务商 chips + 全量预设、协议分段、实际请求地址、眼睛、测试中 / 失败 / 成功、模型单选 + 手填、就用这个 / 换一家 / 先跳过；关自动纠错）——iOS key / 地址 / 模型框用 UITextField 关智能引号；「★ 省钱好用」= 清单里有价最便宜的聊天模型（没价就用测通的那个）；成功条角标是 ✓ 不写 200（拿不到真状态码）
- [x] 导卡卡（含坏文件原因）——选中的文件拷进临时目录再解析，答案带这份拷贝的 URL 给 P4 导入
- [x] 起名卡
- [x] 新楼层出口卡（去找 / 继续问我 / 追加导入）
- [x] 扫码卡（iOS；mac 不出）——落地函数注入（`XiaoyaPairOutcome.applying(providerManager:)` 包 `CCPairingApply.apply`），卡片本身不写
- [x] 待办卡、说明卡（待办按 plan 只读，不学小样点着划掉）
- [x] DEBUG 样张页（每张卡各状态，深浅色）——设置 › 开发调试 › 小芽卡片样张（iOS push / mac sheet），DEBUG 专用不进设置搜索
- [ ] 粟粟 sim 对照小样看样张

### P4 剧本引擎
- [x] `AssistantChatMessage` 加 `source` / `card`（decodeIfPresent，text 写兜底）——不认识的来源当普通话、解不开的卡当没卡；选择卡答完 text 写选项标题（P3 的 `summary` 对 picked 只给 id）
- [x] `script.json` 读写（同目录，自动进备份）——`XiaoyaScriptStore`，解不开挪成 corrupt 留底；新版节点这版不认识当走完
- [x] `XiaoyaScriptRunner` 状态机 + 可注入节奏时钟 + 重建后续跑（`Services/Assistant/XiaoyaScript.swift`；节点 → 拍子是纯函数，script.json 记「第几节点第几拍 + 在等哪张卡」；history.json 没来得及落盘丢了卡就重出一张）
- [x] `XiaoyaScriptLines` 台词表（照小样逐字）——偏离一处：酒馆读完卡那句去掉「是个很有画面感的姑娘」（对着示例卡澪写的，真卡不知道是谁）
- [x] 剧本表情覆盖层 `scriptMood`（`XiaoyaStageState.scripted`；busy / 短暂反馈照样压过它；key 卡 phase → 在试钥匙 / 没连上 / 连上啦）
- [x] 输入框锁 / 放开规则；卡片未答时打字走真 AI、剧本后续追加在末尾——偏离一处：小样没钥匙走完仍锁着，这里走完一律放开（召回 chips / 「配钥匙」要能用；没模型打字回 H10 兜底句）
- [x] 本地关键词 + chips（按待拍板 4）——chips 只在房间、引导没在走时出，弹键盘时收起；mac 上「连电脑」只指路
- [x] identity：`onboardingIdentity` + proMode 一次性写
- [x] key：接 `CredentialCommitter`（`Adopt.model`）；skipkey——commit 前默认 🔑 被占就 `allocateUnusedEmoji`；交接分隔线写小芽实际用的模型（K3 没接管主模型时是原来那个）
- [x] `OnboardingFloorFactory`：导卡（`activate:false`）、追加世界书 / 预设落 Ta 楼层、预设冲指令提示、陪伴建楼层（persistNew + publish 不切 + 实例 + charDescription）——预设导入后给 Ta 楼层实例化一份换上（设置页旧路径是直接指模板）；导卡建楼层失败把刚进卡库的卡撤掉
- [x] tech 扫码；ghost；小白试聊 + 建一个 Ta——mac 上「有 Mac」不出扫码卡直接收尾（mac 的问法 P5 改）
- [x] end：待办 / 出口 / 说明卡；`xiaoyaV1 = done` + `onboardingCompletedV1 = true`；推送授权——「去找 X」先收尾（script.json 已 done）再切楼层
- [x] 引导中强制本地模式（`isModelUsable` 兜底示例卡 / 桥卡）——引导没走完且（没存钥匙或模型不可用）就不发模型
- [x] 默认称呼 `garden.defaultUserName`：写入两处、`floorUserName` 链首、新建楼层预填、小芽楼层 userName 同步（`DefaultUserName`，在 `OnboardingFloorFactory.swift`）
- [x] `wireHistory` 跳过剧本 + 交接备注；`.handoff` 分隔线渲染——备注按 script.json 现拼（交接之后建的 Ta 楼层也在），窗口里只认最后一条分隔线；剧本气泡 / 卡片之前的话不能「编辑」（删了剧本接不上）
- [x] system prompt「关于你在帮的人」（按待拍板 1）
- [x] Prompt 页顶一行「Ta 叫 X · 叫你 Y ›」（单独提交）——两端都弹通用页 sheet；标题是动态名字，没进设置搜索注册表（通用页本身已在）
- [x] DEBUG「从头放一遍引导」入口（设置 › 开发调试，小芽卡片样张下面；切到小芽楼层，不碰新装判定）
- [x] 测试：`XiaoyaScriptTests` / `XiaoyaWireHistoryTests` / `OnboardingFloorFactoryTests` / `CharacterFloorServiceTests` 扩（20 + 5 + 6 + 1）
- [ ] 粟粟 sim 五条线（§4 验证）——agent 不许碰模拟器，留给车头
- 追加导入「以前的聊天记录」：聊天记录导入落当前楼层（ImportView），小芽楼层导不了 → 这里只回一句指路（去找 Ta → 对话列表上方「导入」），没做成直接导

### P5 接通
- [x] `FreshInstallProbe.decide` + `FreshInstallProbeTests`（`Services/Onboarding/FreshInstallProbe.swift`）——自动种的 API 卡白名单比 plan 多一个 `chatgpt-oauth`（`ensureChatGPTOAuthCard` 新装也播，不排除新装永远判成 upgraded）；示例角色卡 `sample-baishi` 不算卡库；对话数读不出来当「不知道」不判
- [x] 启动接判定（只读不判）；`started` → 当前楼层小芽 + 开剧本；`LaunchTrace` 量一次（`onboarding.probe`，iOS DEBUG/PERF 包；老用户路径只读一次键，`fetchCount` 只在前几条都像新装时数）
- [x] `seedAndSave` 种子按旧键分流 + `LaunchSeedTests`；跑 `ProtectedDataGateTests`（首启那两条断言改成对 `firstLaunchSeed(legacyCompleted: false)`，只读兜底仍断言 `Profile.seedProfiles`）
- [x] `PushAppDelegate` 授权条件 + `PushGateTests`（`PushGate` 纯函数放在 FreshInstallProbe.swift，测试宿主是 mac）
- [x] 删 `OnboardingFlowView` + `Astral*` + `PixelArtView`；删 `ContentView` / `SettingsView` 两处 cover；`xcodegen generate`——`canResumeAPIDraft` 的「引导盖着不弹」改成 `xiaoyaV1 == started`；`APIDraft.onboardingSlot` 留着（老偏好里可能还有旧引导草稿，靠它排除，见复盘 §3）
- [x] 设置「?」新手引导 → 小芽楼层重走（按待拍板 5）——`script.replay()`：「再走一遍」分隔线（新来源 `.divider`，不进 wire）+ 直接出分流卡；不把键改回 started；已在小芽楼层就发 `.xiaoyaRoomRequested`（现在 page0 也翻回房间）。mac 设置没有「?」，没加入口
- [x] mac：首启落小芽房间、技术线改问「要连手机吗」只指路——问句「要把手机也连上这台 Mac 吗？」，要 → 指到「设置 › 让手机连这台 Mac」（mac 设置页真名；plan / 小样写的「连接手机」不存在，顺手把召回句和 iOS 扫码卡上的同一处说法也改成真名）；剧本在走时进房间不插「我搬家啦」
- [ ] iPad 宽屏看一眼——agent 不碰模拟器；读代码：宽屏只是 `isWidePanelMode` 把 page1 固定成中间卡，房间分支和 iPhone 同一个 `isXiaoyaFloor` 判断，P5 没改这条路径
- [ ] 跑 `StickerProbeUITests` 那组（`-onboardingCompletedV1 YES`）确认仍落聊天页——agent 不碰模拟器；读代码确认：参数进 NSArgumentDomain → 旧键真 → 种 [小芽, 对话空间] + `lastProfileId = default-workspace` → 判 upgraded 不开剧本，`--kb-probe-seed` 等种子写进对话空间（`LaunchSeedTests.testLegacyFlagSeedsWorkspaceToo`）
- [ ] 粟粟 sim：全新装（iPhone + mac）、升级装、设置重走
- [ ] 说明书 `manual/facts/modules/xiaoya.md` 收口（P2–P4 也没建，整个模块留车头一次收口）；复盘 [review-onboarding-xiaoya-P5.md](review-onboarding-xiaoya-P5.md) ✅

### sol 审查 9 条（2026-10-15，基于 9195f8d81；车头裁：全收）
- [x] #1 楼层列表读空但库里有数据 → 不再只种小芽：`loadProfilesChecked(freshInstall:)` 读空时才问 `FreshInstallProbe.libraryLooksEmpty`（没自建 API 卡、卡库空且读得出、对话数为 0，同新装判定的证据）；真新装才种 `[小芽]`，有数据 / 不知道 / 不传（只读调用点）一律 `[小芽, 对话空间]`。App.init 把卡库挪到楼层列表前读、凭据 id 从 `_providerManager` 取，判定在落盘前做完，不用事后删楼层。`LaunchSeedTests` +3（`ProtectedDataGateTests` 两处断言跟签名改）
- [x] #2 出口卡丢了重开接不上 → 恢复按「最后一拍要不要等答案」统一判（`XiaoyaBeat.awaitsAnswer`，`.floorExit` 也算），抽成纯函数 `XiaoyaScriptRunner.resumable`；出口卡按 script.json 里记的 Ta 重拼，不重建楼层。`XiaoyaScriptTests.testRebuiltEngineRepostsLostFloorExitCard`（陪伴 / 酒馆两条线）+ `testResumableKeepsAnswerableWaits`
- [x] #3 iPhone 停在扫码卡的备份恢复到 mac → `resumable` 里平台适配：mac 上 `.techPair` 改走 `.techPhone`（只指路）再收尾。`testIPhoneProgressOnPairCardMovesToPhoneGuideOnMac`
- [x] #4 起名建楼不幂等 → `XiaoyaScriptProgress.pendingTaId`：落地前先定 id 写进 script.json，`createTa(id:)` 同 id 楼层已在就直接还它，上次只落了预设的孤儿实例先清；`world.createTa` 多带 id 参数。`testBuildTaResumesWithStableFloorId` / `testBuildTaRecordsFloorIdBeforeBuilding` / `OnboardingFloorFactoryTests.testCreateTaIsIdempotentById`
- [x] #5 预设存不下仍宣布建好 → `createTa` 不再走吞错的 `instantiate` / `save`，自己拼实例后 `presets.persistNew`（可抛）先落、再落楼层，楼层落不下 `discardNew` 回滚；失败照旧说「没建成」+ 重出起名卡。`testBuildTaFailsWhenPresetCannotPersist` / `testCreateTaThrowsWhenPresetCannotPersist`
- [x] #6 恢复走完引导的备份后本机永远 started → `XiaoyaScriptRunner.reconcileFinished`：启动接判定前，`xiaoyaV1 == started` 且 script.json 已 `finishedAt` → 写 `done` + `onboardingCompletedV1 = true`；只认 started，重走（done / upgraded 下没收尾）不碰。`testReconcileFinishedBackup`
- [x] #7 卡库读坏当空库 → `CharacterCardManager.loadFailed`；`FreshInstallProbe.decide / runOnce` 多一个 `cardsTrusted`，读坏不判不写（同楼层列表读坏，连旧键都不看）；首启种子也按「不知道」处理。`FreshInstallProbeTests.testUnreadableCardLibraryDoesNotDecide`
- [x] #8 自定义中转测之前填不了模型 → key 卡自定义中转在编辑 / 失败态多一栏「模型 ID（可不填）」，`Probe` 多带一个参数传给 `ProviderProbe.test(preferredModelId:)`；拿手填模型测通的就存它（手填优先），仍以 2xx 为保存前提；改地址 / key 作废时手填的留着，换服务商才清。`XiaoyaKeyCardModelTests` +3
- [x] #9 历史写盘乱序覆盖 → `AssistantChatWriter`（actor，`AssistantChatStore.swift`）：编码写盘排在同一个写入器里，带版本号（= saveToken），旧快照晚到直接丢。新文件 `AssistantChatWriterTests`（顺序 / 40 路乱序并发 / 引擎接线）

---

## 10. 改向（10-16 粟粟）：不要小芽楼层，小芽 = page2 子 app

> 粟粟：「小芽还是不要自己一个楼层了（免得把人搞混了……），小芽就是那个子app，一打开就是先在子app里。」#00475 已合 master（3039aa05），Air 安装已请 Warden 压住。

做法（车头推荐，粟粟没反对即按此）：
1. **去掉保留楼层**：删 `ensureXiaoyaFloor` 及护栏、`taFloors`（调用点回 `profiles`）、page1 小芽房间 / page0 说明行 / ImportView 拦截 / ⌘N 拦截 / 「≡ 小芽的楼层」签 / 「她就在左边」/ `.xiaoyaRoomRequested`、「我搬家啦」消息。`Profile.xiaoyaId` 只留作迁移识别。
2. **迁移**：启动时楼层列表里有 id `xiaoya` 的自动种入楼层 → 静默移除（若它是当前楼层，切到第一个别的楼层；它本来没有对话）。只读时不动。
3. **种子**：回到 master 原样（新装种 [对话空间]），`firstLaunchSeed` 的小芽分支删掉；sol #1 的「库有数据」判断随之不再需要。
4. **新装首启**：判定 `started` → iOS 直接翻到 page2 并打开小芽 app；mac 打开右栏小芽。剧本、卡片、交接都在小芽 app 里走。
5. **工具目标楼层**：回到「当前所在楼层」；舞台一行「正在帮：X」只读不可切（去掉切换菜单和 `xiaoya.targetProfileId`）。引导里建好的 Ta 楼层不自动切，「去找 X →」= 切楼层 + 回 page1（mac 关不关右栏随原样）。
6. **设置「新手引导」**：关设置 → 打开小芽 app → 「再走一遍」从分流卡重来。
7. 保留：名字恒为小芽 / Lily、AssistantEngine 单例、备份、剧本 / 卡片 / 新装判定 / 删旧六页 / 推送时机 / sol 其余修复。

### Todo（§10）
- [x] 去掉小芽楼层及其所有 UI / 护栏 / 目标楼层切换——删 `XiaoyaRoomView.swift`（房间 / 「她就在左边」/ `.xiaoyaRoomRequested`）、`XiaoyaTarget.swift`；`Profile.xiaoyaFloor` / `isXiaoya`、`ensureXiaoyaFloor`、`taFloors`（Agent / 天平回 `profiles`）、删 / 改名护栏、ProfileSwitcher / CharacterHome / 角色墙磁贴、page0 说明行与藏钮、ImportView / ⌘N / 草稿托底拦截、PageSync / 开屏的小芽楼层判据、舞台「≡ 小芽的楼层」签与切换菜单、「我搬家啦」（连同只给它用的 `AssistantPrompts.legacyName`）、`DefaultUserName.set` 同步小芽楼层称呼那段。P2 里 view 层那 7 个文件是按原 hunk 反向打回去的
  - 保留：名字恒为小芽 / Lily、`XiaoyaConversationView` 拆分（`AssistantPanelView` 只剩一层壳）、`enter(card:activate:)`、`AssistantEngine.shared`、`AssistantEnv.defaults`（剧本在用）、默认称呼链首（`floorUserName`）
  - 工具目标楼层回当前楼层（`AssistantTools` / `LiveAssistantWorkspace` 的 P2 hunk 原样反向，`noTarget` 指路一并撤）；舞台「正在帮：X」= 当前楼层，只读一行
  - 召回 chips：房间没了，改在小芽 app 里显示（引导没在走就有，老用户也看得到）
  - 文案偏离小样两处：开场「以后有不会的，回到这一层问我」、ghost「或者回这一层跟我说配钥匙」→「点开「小芽」」（没有「这一层」了）
- [x] 迁移：静默移除自动种入的 xiaoya 楼层 + 测试——`ProfileManager.removeLegacyXiaoyaFloor()`，启动时 `profilesTrusted` 才调：按 id 移除（同名 Ta 楼层不动），当前楼层是它就落到剩下第一层并写 `lastProfileId` / `userName` / `assistantName`，移完为空种回 [对话空间]；清 `xiaoya.targetProfileId` / `xiaoya.movedInV1`；只读时什么都不碰。数据不删（这层万一有 page2 生活类记录也留着，变孤儿但不丢）；它的文件库空目录、预设实例不清。`XiaoyaFloorMigrationTests` 7 条
- [x] 种子回原样；新装首启打开 page2 小芽 app（iOS）/ 右栏小芽（mac）——`seedAndSave` 回 P5 之前（只种 `Profile.seedProfiles`，不再按旧键写 `lastProfileId`）；sol #1 的 `freshInstall` 闭包 / `firstLaunchSeed` / App 里的 `libraryLooksEmpty` / 卡库提前读一并撤（`FreshInstallProbe.libraryLooksEmpty` 留着，`decide` 在用）；`FreshInstallProbe.seedFloorIds` 去掉 xiaoya。新文件不加：`XiaoyaApp`（在 `AssistantPanelView.swift`）——App.init 判完后 `noteLaunch(onboardingStarted: xiaoyaV1 == started)`（新装刚判 / 上次没走完都算）：iOS 记一笔，ContentView 出现时走现成的 `openToolFromOutside("xiaoya")`（窄屏翻 page2、宽屏开 tab）；mac 直接 `IPadPanelLayout.shared.open`。iOS 钩子是原 `XiaoyaFloorSync` 那个 modifier 换成 `XiaoyaAppHooks`（链长度不变）；这次启动在 app 里就不按「聊天输入框可用」收开屏（同 page2 UI 测试）
- [x] 「去找 X」切楼层回 page1；设置「新手引导」打开小芽 app 重走——`goTo` 先 `XiaoyaApp.leave()`（iOS：page2 退回桌面 + 翻回 page1；mac 右栏不动）再 `switchTo`；设置「?」= `replay()` + 关设置 + `XiaoyaApp.open()`；DEBUG「从头放一遍」同样改成打开 app
- [x] 测试改写 + 双端 build-for-testing——删 `XiaoyaFloorTests` / `XiaoyaTargetTests` / `AssistantToolsTargetTests`、角色墙磁贴测试、「我搬家啦」测试；`LaunchSeedTests` 重写（种子 = 对话空间）、`ProtectedDataGateTests` 回 P5 前原样、`FreshInstallProbeTests` 种子改对话空间；剧本 / 建楼层测试台的起始楼层改成对话空间（`atHome`）
- [ ] Warden 预览 → 粟粟 sim 试 → 合

---

## 11. v2：怎么划 Tip + 开机 hello 占位 + 挑头像 / 名字（10-16 粟粟）

> 小样：[design-onboarding-xiaoya-v2.html](design-onboarding-xiaoya-v2.html)。粟粟：「竖条（弧线你这个资产也可以放设置里）｜page012 是我们的用语，不要跟用户这么说。我们叫 atriumOS｜都先按你的。tip1 就是现在的 1234。tip 收到小芽边上放一个灯泡剪纸可以随时看历史 tip。挑头像和名字不只是给用户还有给 ai 自己挑」

拍板（小样 6 条按推荐 + 她的补充）：
1. **Tip 按竖条模式讲**（默认就是竖条）。弧线版插图不进 Tip，放进设置里选「竖条 / 弧线」那一页（`RightPanelSettingsView`）当示意图。
2. **对用户不说 page0/1/2**：整套页面叫 **atriumOS**；文案里说「atriumOS 的桌面」「聊天」「所有对话」等。顺带修 v1 待办里「右滑到 page2」的说法和方向（`XiaoyaScriptLines.swift:78`）。
3. **Tip 编号**：小样里收尾连发的那几条（回桌面 / 去聊天 / 看所有对话 + 带我去桌面）合起来就是 **Tip 1**（一组多张）。以后的每日 tip 从 Tip 2 起，本期不做每日推送。
4. **灯泡剪纸**：小芽舞台边上放一个灯泡剪纸按钮，点开是历史 Tip 列表（按编号，可重看插图）。收到新 tip 时灯泡亮一下。
5. **开机 hello**：占位动画（黑屏 → hello 描边 → 桌面出现，可跳过），只在第一次回到 atriumOS 桌面时放一次；画面以后换粟粟那版；重播只放 DEBUG。mac 不放。
6. **Tip 插图**：示意画（SwiftUI 形状拼，会动），不用真截图。mac 不发「怎么划」Tip。
7. **挑头像 + 名字 = 两张卡，给你也给 Ta**：只小白线，放在分流之后、钥匙卡之前：
   - 「你」：随机头像（程序化生成 6 个，可换一批 / 从相册选）+ 随机昵称（6 个 chip，可再换 / 自己写 / 先叫「你」）→ 写当前楼层 `userName` / `userAvatarData` + 默认称呼 + 新增「默认头像」（文件存 Application Support，不进 UserDefaults），之后新建 / 导卡楼层继承。
   - 「Ta」（AI）：同样随机头像 + 随机名字 → 写当前楼层 `assistantName` / `assistantAvatarData`。小芽自己的名字不变。
   - 陪伴线起名卡预填这里选的名字（若走过）。

### Todo（§11）
- [x] Tip 1（一组）：收尾后发，竖条版插图（会动）、文案用 atriumOS、「带我去桌面」按钮——新卡 `.tip(XiaoyaTipRef)`（`XiaoyaTips.swift` / `XiaoyaTipCardView.swift`），end / ghost 在 info 卡后、收尾前连发（endQuiet 只放卡不说话，免得「去找 X」被拖 3 秒）；回桌面那张渲染时按当前「切换应用」设置出竖条 / 弧线版；只 iPhone（iPad 也不发，宽 / 窄屏会变，偏保守）；插图只在可见 + 小芽 app 在前台 + App 活跃 + 没开减弱动态时动
- [x] Tip 历史：灯泡剪纸按钮 + 历史列表 + 新 tip 亮一下；Tip 存在小芽目录（进备份）——`AssistantChat/tips.json`（编号 + 第一次收到的时间，同号只记一次）；灯泡在舞台小票右边，没收到过 tip 不画（mac / 老用户看不到）
- [x] 开机 hello 占位（第一次回桌面、可跳过、只一次；DEBUG 重播；mac 不放）——`Views/Page2/GardenHelloOverlay.swift`：独立 UIWindow + CA 关键帧；触发挂 page2 外壳（桌面露出 + 第二页停 0.45 s，「去找 X」那条路不误放）；落位用桌面截图切 7 条落下、垫糊图（截图没赶上就整张揭开）；`garden.helloShown` 放前就记；UI 测试 / `--` 启动参数不放；DEBUG 设置 › 开发调试「重放开机 hello」
- [x] 设置「竖条 / 弧线」页放弧线示意插图——两张并排（同 Tip 插图），选中的会动、点图也能切
- [x] 小白线：「你」头像 + 名字卡、「Ta」头像 + 名字卡；默认头像存储 + 新楼层继承——一人一张卡（上头像下名字，`.face(.user / .ta)`，`XiaoyaFaceCardView` + `GardenAvatar`）；`DefaultUserAvatar` = Application Support/MemoryPalace/default-user-avatar.jpg；起名建 Ta / 卡库进卡 / 酒馆整包导入 / 新建楼层表单都继承，设置 › 通用「你的头像」同步写；陪伴线起名卡「Ta 怎么称呼你」预填默认称呼
- [x] 修 v1 台词里 page 说法 / 方向；全文 grep 用户可见文案不出现 page0/1/2——待办「往左划到 atriumOS 的桌面…」/「打开 atriumOS 桌面上的终端 app」（mac 说右栏）、说明卡、扫码卡、设置右栏两行、聊天皮肤设置一行；`XiaoyaV2Tests.testScriptLinesNeverSayPageNumbers` 扫台词表源文件。没改：给模型看的工具描述（AssistantTools 里「Page2 主屏」）
- [x] 讲楼层（粟粟 10-16 追加）：Tip 1 第四张「楼层是什么」（会动：对话列表顶上点楼层 → 换一层 → 聊天里头像跟着变）；新楼层出口卡加一行「这是 Ta 的楼层：Ta 的名字、记忆、对话都住在这层。」；小白挑完 Ta 那句带「你现在待的这一层就是 Ta 的楼层」
- [x] 测试 + 双端 build-for-testing（`XiaoyaV2Tests` 14 条；XiaoyaScript / WireHistory 的小白用例补答两张挑头像卡）
- [x] 粟粟说直接合（#00483，master 49be922f，已装 Air）

## 12. v3：更拼贴 + Tip 一条一条 + 马克笔概念 + 开场自我介绍（10-16 粟粟试完 Air）

> ⚠️ DON'T IMPLEMENT YET（C / D 两个 bug 除外，先修）。小样（待做）：[design-onboarding-xiaoya-v3.html](design-onboarding-xiaoya-v3.html)。粟粟：「我觉得都不错，几个小问题」+ 两张参考图（彩色纸剪贴纸：白边 / 纸纹 / 叠层；复古拼贴：网点照片、报纸碎片、放射条纹、喇叭、闪电、黑胶）。

### 她的 6 条 + 命名
1. **更拼贴**：既然是拼贴风就再拼贴一点，**聊天的演出也加拼贴元素**。灯泡太小、不亮眼，用户不知道能点。
2. **Tip 1 一次 4 张太多**，拆成 **Tip 1.1 / 1.2 / 1.3 / 1.4**。
3. **动画有时卡住不播**（bug）。
4. **填密码 / key 这类输入框时舞台头没收起**（bug）。
5. **马克笔划高亮概念**：如【楼层：……】【API key：……】。
6. **文案**：一上来就问「你是哪种园丁」很怪，先自我介绍（「欢迎来到记忆花园，我是你的助手小芽，我可以帮你……」）。
7. **命名**：atriumOS 还是别的？朋友提「粟粟机」（小手机圈说法 + 小米梗）、susuOS、gardenOS。**只有 page2 算 OS，page0/1 不算**；说整体时叫「记忆花园」。

### 建议（⧫ 批注处拍板）
- **A 拼贴（1）**：两层素材。
  - **纸剪贴纸**（参考图 1）程序化画：不规则多边形 + 白纸边 + 纸纹噪点 + 错位叠层 + 落影，SwiftUI `Shape` 做，不用位图——星爆 / 爱心 / 问号 / 感叹号 / 对话框 / 闪电 / 灯泡。
  - **复古拼贴**（参考图 2）：网点（halftone）+ 报纸碎片 + 放射条纹只做**底纹和点缀**（程序化网点、报纸用「随机字号的假排版」碎片），**不用真照片**——参考图里的人像 / 骷髅 / 喇叭照片来源不明、版权不清；要真照片拼贴得你给有授权的素材。
  - **演出位置**：~~小芽舞台（背景放射条纹 + 星爆贴纸随心情换）~~ **舞台头本身不变**（粟粟看小样 v3：「现在反而变杂乱变丑了」）；小芽气泡边角偶尔贴一张（问号 = 在问你，感叹号 = 重要，爱心 = 完成）、选项做成撕下来的纸条、完成一步「啪」贴一个星爆。克制：一屏最多 2 张，不挡字。
  - **灯泡**：放大成剪纸贴纸（≈44pt），**挪到舞台头小芽的左边**，浮着、有新 tip 时黄光晕呼吸 + 未看数字；**不要「点我看提示」纸条**（粟粟看小样 v3）。
- **B Tip 1.1–1.4（2）**：收尾只发 **Tip 1.1（回桌面）**，卡底「懂了，下一条」chip → 发 1.2，依次到 1.4；另给「以后再看」，剩下的进灯泡（灯泡标未看数字）。卡上显示「Tip 1.1」。
  - **灯泡历史列表**：**不拟物**（去掉纸条 / 「已看」印章 / 网点垫块），干净的列表：编号 + 标题 + 一行说明 + 未看小红点（粟粟：「故意拟物反而有点丑」）。
  - **点开一条 = 提示内页，做成报纸样式**：报头（「小芽日报 · Tip 1.2」+ 日期）、大标题、分栏正文、插图套网点框当新闻图、图注；返回回列表。
- **C 卡住不播（3）**：先查根因再修（门控 `visible && appActive && scenePhase == .active && !reduceMotion`，怀疑 onAppear / onDisappear 在懒加载回收、整树重建时把 `visible` 留成 false）。修完 Air 上复现确认。
- **D 舞台头（4）**：同样先查根因（`stageCollapsed` 只看键盘，钥匙卡 / 名字卡的 UITextField 可能没进那条路径）。
- **E 马克笔（5）**：小芽台词里的概念词画一道马克笔底色（**一种颜色、一笔**，不要多色 / 胶带 / 尖角——粟粟看小样 v3：「太花了」），**点一下弹出的解释直接复用 page1 便利贴的线圈本**（`NoteView` + `NoteSpec(kind: .spiral)`，`Views/Notes/`），不自画纸条：
  - 【楼层】一层住一位 Ta：Ta 的名字、记忆、对话都在这一层，换一层就换一位。
  - 【API key】去 AI 公司领的「钥匙」，有了它 Ta 才能说话；只存在你手机的钥匙串里。
  - 【模型】Ta 用的那颗「脑子」，同一把钥匙下可以换。
  - 【记忆】Ta 自己从聊天里记下的小事，你随时能看、能删。
  - 【桌面（gardenOS）】见 G。
  台词表里用 `[[楼层]]` 标记，渲染时换成马克笔；词表一处维护。
- **F 开场（6）**：第一句改自我介绍，再分流：
  > 欢迎来到记忆花园～我是小芽，在这里帮你打理花园的小助手。
  > 我可以帮你接上 AI、把旧聊天搬进来、给 Ta 起名字挑头像；以后找不到什么功能，也可以直接问我。
  > 先认识一下：你是哪种园丁？
- **G 命名（7）**：推荐 **gardenOS**——和「记忆花园」同一个词根，用户一看就懂；产品要上架，app 里写开发者自己的名字（susuOS / 粟粟机）对陌生用户是谜语。「粟粟机」留作彩蛋：开机 hello 角落小字，或问小芽「这是什么手机」时回一句。范围按你说的收窄：
  - 整体 = **记忆花园**；page2 = **gardenOS**（桌面 / app）；page1 = **聊天**；page0 = **所有对话**。
  - 小芽提示词 `atriumNaming`、全部用户可见文案、工具描述一起换；测试扫描防回潮。

### 拍板（10-16 粟粟：「都按推荐。懂了下一条」）
1. 命名 = **gardenOS**（只指 page2；整体 = 记忆花园；「粟粟机」留彩蛋）。
2. 拼贴只做程序化（贴纸 / 网点 / 报纸 / 条纹），不用照片。
3. 1.2–1.4 = 点「懂了，下一条」一条条出；「以后再看」收进灯泡。

### 小样定稿 = 实现以此为准（10-16 粟粟看完最后一版说 go；上面 A / B / E 与此冲突处以这里为准）
- **舞台头 = v2 原样**，不加条纹 / 图钉 / 星爆。
- **灯泡**：剪纸贴纸，缩到能放进屏幕左缘和小芽之间（看上去 ≈47pt），浮在左幕布上，小芽和小票位置不动；**一直**轻轻上下浮 + 柔和黄光晕呼吸（粟粟：「就浮动在那里亮亮的就好了」），有未看 tip 时光晕更亮 + 轻晃 + 未看红数字；没有「点我看提示」纸条。**三端一直画**（词典一直有内容，老用户也有入口）。（10-16 Air 试 v3 后改）
- **选项不做撕纸条**（粟粟：「这一坨丑」）：开场园丁选项、所有问答都用现成 `XiaoyaChoiceCardView`；Tip 卡底「懂了，下一条」「以后再看」也用普通 chip（同理，按推荐）。
- **拼贴只剩点缀**：气泡右上角外侧偶尔贴一张程序化剪纸贴纸（问号 = 在问你、感叹号 = 重要、爱心 = 完成），完成一步在卡角「啪」拍一枚星爆；一屏最多 2 张，不压字。贴纸库：星爆 / 爱心 / 问号 / 感叹号 / 对话框 / 闪电 / 灯泡，白纸边 + 淡纸纹 + 错位叠层 + 落影，SwiftUI Shape 程序化。
- **马克笔概念词**：一种颜色（黄）、一笔；**点马克笔词弹释义 sheet**，照搬 page1「思考过程」的弹法（`DisclosureSheet`：把手 + 左上关闭 + 正文滚动，40% 高），**sheet 里是一本 page1 便利贴的线圈本**（`NoteView` + `NoteSpec(kind: .spiral, font: .kai)`）写「词：释义」，sheet 标题留空不重复；聊天里不再原地翻线圈本、没有首次自动展开。（10-16 Air 第二轮，粟粟：「词典都像page1思考那样弹sheet好不」「其实我的意思是弹了是线圈本」；前一版「首次翻开线圈本 + 点开合」作废）
- **词典收进提示**：灯泡列表下面一组「词典 · 小芽的词」，**词表 5 个词一直全列**（小芽讲过的按先后排前面、标「讲过」，没讲过的照样能看）；普通行（Aa + 马克笔词 + 讲过 + 一行释义缩略 + ›），**点一行弹跟聊天里同一张释义 sheet**（叠在灯泡列表 sheet 上）。（10-16 Air 第二轮改：原来点开在列表里翻线圈本）
- **灯泡列表**：干净的 iOS 分组列表（编号 + 标题 + 一行说明 + 未看红点 + ›），不拟物；**没有小报内页**——点一条就打开原来那张 Tip 卡。
- **Tip 1.1–1.4**：收尾只发 1.1；「懂了，下一条」发下一条，「以后再看」小芽说一句「剩下 N 条收进灯泡」。卡上标「Tip 1.1」。
- **开场 F**、**命名 G**（gardenOS）照上文。

### Todo（§12）
- [x] 小样 v3 定稿（`design-onboarding-xiaoya-v3.html`，粟粟 go）
- [x] C 动画卡住：根因 + 修（不等批注，bug 先修）——插图改 TimelineView 按时间算帧、门控只管暂停；可见性拆 onScreen / inViewport 两路；点图重播顺手对齐。iOS 上是哪条回调没来没能在运行时坐实（规矩不起模拟器），待 Air 复现确认
- [x] D 填 key / 名字时舞台头收起：根因 + 修（不等批注）——stageCollapsed 只看聊天框 inputFocused；改成聊天框焦点 或 键盘起来（keyboardWillShow / WillHide）
- [x] A 贴纸库 + 气泡角贴纸 / 完成星爆 + 小芽左边大灯泡——`Views/Assistant/XiaoyaPaperSticker.swift`：小样 sticker() 逐项搬（mulberry32 种子、0…100 坐标 / 128 格画布、每层描粗边当纸边 + 错位 1–2pt、sourceAtop 撒深浅纸纤维、每层薄边影 + 整张落影），七种 = 星爆 / 爱心 / 问号 / 感叹号 / 对话框 / 闪电 / 灯泡，配色照 LAY。规则一处：`Services/Assistant/XiaoyaStickers.swift` `XiaoyaStickerRule`（剧本台词：完成 = 「搞定啦」/「钥匙好使」→ 爱心，重要 = ghost 第二句 / 跳过钥匙 / 建楼层失败 / 导入失败 → 感叹号，以「？」收尾 → 问号；卡答成 keySaved / imported / named / face / paired → 卡角星爆；从最新往回数只贴最近 2 处 = 一屏最多 2 张）。气泡贴纸挂在她那句话右上角外侧（40pt，offset 38 / -16，不压字）；星爆挂卡右上角外（58pt，offset 14 / -24），只有刚答完那张（`freshStamp`，不落盘）「啪」一次，减弱动态直接贴着。灯泡 = 剪纸灯泡 62pt 画布（看上去 ≈47pt），舞台 overlay 左下（x -6、比小芽脚底高 16），小芽 / 小票不动；有没看的 tip 时黄光晕呼吸 2.6 s + 每 3.6 s 晃三下 + 红数字，全看过了静止；TimelineView 30 帧、小芽 app 不在前台 / 减弱动态时停。没收到过 tip 照旧不画；**偏离**：mac / iPad 不发 tip，有展开过的概念词也画灯泡（列表里只有「词典」组），否则词典在那两端进不去。Tip 卡上「Tip 1.1」做成小样 .tipno 金黄燕尾纸签；小样 Tip 插图上的胶带 / 网点角没做（定稿说拼贴只剩点缀）
- [x] B Tip 1.1–1.4 拆分（懂了，下一条 / 以后再看）+ 未看计数；灯泡列表干净化——收尾只放 1.1（info 卡后：说 tipsIntro + 1.1；endQuiet 只放卡）；新答案 `.tipNext` / `.tipLater`（进 history.json，旧版解成 unsupported），走 recall：下一条 = 直接发同组下一张，「以后再看」= 小芽说「好～剩下 N 条我收进舞台上的灯泡里了，想看随时点它。」；最后一张只给「懂了」一颗 chip（剩 0 条时「以后再看」没意义）。chip 用现成 `XiaoyaChip`，只给对话里最新那张没答过的 tip；答过显示「已看 ✓ / 收进灯泡了」。tips.json 加 `seen`（「1.1」这样的标签）：收到一组 = 整组进列表、发在对话里 / 灯泡里点开才算看过；旧文件没 `seen` → 当年一口气发完四张，整组算看过（Air 上不会冒红数字）。灯泡列表 = 分组 List（「Tip 1 · 怎么划」：编号 + 标题 + 一行说明 + 未看红点 + ›），点一条 push 原来那张 Tip 卡（插图能重播，打开即已看）；标题「小芽的提示」，副标题「4 条 · 3 条还没看」。没有小报内页
- [x] C 补：Tip 插图 TimelineView 限 30 帧（`XiaoyaTipCardView.swift:186` `minimumInterval: nil` → `1.0 / 30`；示意动画不用跟 120Hz 满帧重画）——照改
- [x] E 马克笔概念词 + 首次自动展开一行解释 + 词表 + 灯泡列表「词典」组——词表一处：`Services/Assistant/XiaoyaGlossary.swift`（楼层 / API key / 模型 / 记忆 / gardenOS，释义照小样 DEF）。台词标在：小白钥匙开场「一把 [[API key]]」（照小样去掉了「**钥匙**（API key）」）、陪伴钥匙开场、「钥匙好使！现在是 **X** 这个[[模型]]在借我的嘴…」（加了「这个模型」四字，否则「模型」整套剧本里没处出现）、挑 Ta 名 / 默认 / 小白「建一个 Ta 的[[楼层]]」/ 导卡「Ta 的[[楼层]]我帮你搭好了」、技术线「查[[记忆]]」、tipsIntro 和 Tip 1.1 / 1.4 正文；待办 / 说明卡这些卡片里的字不标。她那句话：`[[词]]` → `**词**` 交 ChatMarkdownView，马克笔借 fork 划线层的 pen 样式画（ChatMarkdownView 加了个 `extraHighlights` 默认空参数，跟划线一起进缓存键）；Tip 卡 / 灯泡列表里的 SwiftUI Text 用 TextRenderer 画同样一笔（`Views/Assistant/XiaoyaMarker.swift`）。一种黄、一笔、下半截。展开记在 `AssistantChat/glossary.json`（词 + 跟在哪条消息下面，进备份）：剧本 `say()` 一句话时第一次出现的词表词记下来，那句下面跟一行浅底圆角解释（词加粗 + 释义），之后只画马克笔；重走引导不再展开。Tip 卡里的词不展开（只 say 的台词展开）。灯泡列表下「词典 · 小芽说过的词」组（Aa + 马克笔词 + 一行释义 + ›，点进去看全文）。小芽模型实时回复里的词本期没做（模型回复里的 [[ ]] 照原样显示，不转马克笔）
- [x] F 开场自我介绍——`XiaoyaScriptLines.open` 换成 plan 的三句（第一句名字用 `AssistantPrompts.assistantName`），再出现成的 `XiaoyaChoiceCardView` 分流卡；第三句「你是哪种园丁？」按规则贴问号。句数保持 3 → open 节点仍是 5 拍，已开始过的 script.json（停在等分流卡 / 开场说到一半）续跑不重放、不错位（XiaoyaV3Tests 两条）
- [x] G 命名替换（提示词 + 用户可见文案 + 工具描述 + 测试扫描）——`AssistantPrompts.atriumNaming` 改名 `gardenNaming`：「整个 app 叫记忆花园；放小 app 的那一页叫 gardenOS（桌面），聊天的那一页叫聊天，对话列表叫所有对话」；规则层「主屏壁纸」→「gardenOS 桌面壁纸」；工具描述 / read_appearance 结果里的 atriumOS → gardenOS（工具名 `propose_page2_appearance` 不动，是 id），本地关键词加「桌面」；台词表、说明卡、扫码卡、设置右栏两行、聊天皮肤设置一行、开机 hello 注释 atriumOS → gardenOS；提案卡 / 账本 / 盖章文案里的「主屏」→「桌面」（「外观 · 桌面」「换个桌面样子」「现在用的是针脚桌面…」「桌面换回原来的样子了」）。「手机主屏」是桌面样式选项名，没动；「Mneme Atrium」是英文产品名，没动。「粟粟机」不进本期。XiaoyaV3Tests 扫 11 个文件的字符串字面量不出现 atriumOS、台词 + 全部工具描述不出现 page0/1/2、gardenNaming 四个叫法都在
- [x] 测试 + 双端 build-for-testing——新 `XiaoyaV3Tests` 15 条（Tip 一条条出 / 以后再看 / 最后一张 / 灯泡点开算看过、编号与 next、tips.json 旧格式整组算看过 + 新格式往返、词表解析、台词里每个 [[词]] 都在词表、首次展开一次 + 重开还在 + 重走不再展开、glossary.json 坏文件留底、开场三句 + 续跑两种、命名扫描两条、贴纸规则 + 一屏两处、星爆只在完成一步、灯泡出现条件）；`XiaoyaV2Tests` 改 3 处（收尾只发 1.1 + 未看 3、quiet 只放 1.1、tipsIntro 说 gardenOS；faceTaNamed 断言走 plain）。mac `MemoryPalaceTests` / iOS `MemoryPalaceIOS`（iPhone 17 模拟器作编译目标）build-for-testing 都 SUCCEEDED；XiaoyaV3 / V2 / StagePlayback / Script / WireHistory / ScrollFollow / CardCodable / Mood / FloorMigration、AssistantPrompts / Appearance / Stamp、GlobalBackupAssistant 全过。`AssistantEngineSharedTests.testInjectedEngineWritesOnlyItsOwnFile` 不过：测试宿主（xctest-home 新家目录 → 新装 → mac 打开右栏小芽 → 剧本 start）在测试窗口里写了宿主自己的 history.json，跟本次改动无关的路径（script.json 停在 open 第 1 拍），未在改动前基线上复跑确认
- [x] 粟粟 Air 试 v3 反馈：灯泡常亮浮动 / 线圈本可开合 / 词典常列——灯泡（`XiaoyaPaperSticker.swift` `XiaoyaTipBulb`）：TimelineView 不再只在有未看时跑，一直上下浮 ±3pt（3.4 s）+ 柔和光晕呼吸，有未看 tip 时光晕放大变亮 + 轻晃 + 红数字；门控照旧（小芽 app 不在前台 / 减弱动态时停在静止亮着，30 帧）；`XiaoyaScriptRunner.showsBulb` 删掉，舞台三端一直画灯泡。线圈本：`XiaoyaGlossBox` 换成 `XiaoyaGlossNote`（`NoteView(spec: .spiral + 楷体, width: 188)`，188 宽 ≈ 16.8pt 字，不撑破聊天列）；点马克笔词走 fork 划线层现成的单击上报（patch 7.1 `highlight.tap`），`ChatMarkdownView` 加 `onExtraHighlightTap` 默认 nil 参数，点到 extraHighlights 里的词就回调；开合 `XiaoyaGlossOpenState`（每条消息记翻转过的词，首次出现默认开），存在 `AssistantPanelView` 的 @State。词典：`XiaoyaGlossaryLog.dictionary` 一直 5 条（讲过的在前 + `spoken`），灯泡列表行点开就地翻开线圈本（原来 push 的 wordPage 删了）。XiaoyaV3Tests：灯泡出现条件那条换成「词典一直 5 条 + 讲过的在前」和「线圈本开合」两条
- [x] 粟粟验 #00486：词典 / 概念词点开改弹思考同款 sheet——`XiaoyaGlossNote`（线圈本）换成 `XiaoyaGlossSheet`（`XiaoyaMarker.swift`，套 `DisclosureSheet(title: 词)`，正文 `ChatMarkdownView` 照 `ThinkingSheet` 两端写法：iOS 默认字号、mac 跟 fontScale + 清 chatSpacingOverride，不挂划线锚）；`XiaoyaGlossary.Term` 加 `Identifiable`（id = 词）走 `.sheet(item:)`。聊天：`AssistantPanelView` 的 `glossOpen` / `XiaoyaGlossOpenState` 删掉，点马克笔词 `glossTerm = XiaoyaGlossary.term(word)`（不在词表 = nil 不弹）。词典：`XiaoyaTipHistoryView` 行改回普通行 + ›，点了设同一个 `glossTerm`，sheet 挂在列表自己的 NavigationStack 外面（sheet 叠 sheet，iOS / mac 原生支持）。glossary.json 记「讲过」照留（词典排序用）。XiaoyaV3Tests：「线圈本开合」那条换成「点马克笔词 / 词典行弹同一张」
- [x] 粟粟：概念词释义 sheet 高度 40%——`DisclosureSheet` 加 `detent` 参数（默认 `.fraction(0.72)`，思考 / 想起来了 / 工具调用等调用点不变），`XiaoyaGlossSheet` 传 `.fraction(0.4)`，仍可拉到 large
- [x] 粟粟：小芽这里改了称呼，之后设置里改不生效——根因：设置 › 通用（Prompt 页「Ta 叫 X · 叫你 Y ›」也是弹这页）只写 `@AppStorage("userName"/"assistantName")` 镜像键 + 默认称呼，不写楼层；`{{user}}` / `{{char}}` 读楼层，小芽挑名字卡写过楼层后楼层值一直盖着，同页改头像等任何 `updateProfile` 还把镜像键刷回旧名；小芽自己的「称呼」也优先读剧本快照。修：通用页确认走新的 `ProfileManager.renameCurrent`（写当前楼层 + 默认称呼，镜像键由 updateProfile 跟着写，跟同页头像一样写当前楼层）；小芽 `callName` 改成默认称呼优先。XiaoyaV2Tests 加「挑名字卡 → 设置改 → 楼层 / 镜像键 / {{user}} / 小芽称呼都是新值」
- [x] 粟粟：sheet 里是线圈本——`XiaoyaGlossSheet` 正文从 `ChatMarkdownView` 换回线圈本 `NoteView(spec: .spiral + 楷体, width: 220)`「词：释义」，水平居中；sheet 标题留空（线圈本上有词）；`detent: .fraction(0.4)` 照留。宽度定 220：NoteView 字号跟宽度走（168 = 15pt → 220 ≈ 19.6pt），最长的 gardenOS 释义约 6 行 ≈ 240pt，40% 高（小屏 ≈ 270pt 可视）里整本露出；内容宽（iPhone ≥ 335 / mac ≥ 440）都比 220 宽，不用跟着量
- [ ] 问合（车头）
