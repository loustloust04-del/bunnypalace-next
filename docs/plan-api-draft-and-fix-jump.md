# plan · API 卡草稿保活 + 报错「去改」直达

> ✅ 粟粟 10-15 批：Q1–Q8「都按推荐」。重点（她原话）：「我重新打开app要留在这一页」——冷启动有新鲜草稿时必须直接落回那张卡的编辑页（Q2-A），这是本单验收第一条。

> 来源：粟粟 10-15「复制 url 出去复制 api 回来又要重新复制一遍」；UX 审查 `docs/research-ux-audit-api-onboarding.html` 两条：
> 「[P1] 设置里新建 API 的表单没有草稿，切出去复制 key 有丢失风险」「[P2] 切到别的 app 复制 key：正常回来不丢，被系统回收就全丢」；
> 「[P1] 报错对新用户不可读，也不告诉他怎么修」「[P1] 报错原样甩给用户……没有「去哪改」」（建议「加一个『去改』按钮直接跳到对应位置」）。
> 基线：backend-2 工位 HEAD `4075461f6`（行号都是这个版本；文件都在 `MemoryPalace/` 下）。
> 不在本单：报错文案整体重写、Page2 网页皮肤聊天（`Views/Page2/Chat/`）的报错、测试连接 / 拉模型本身的逻辑（#092 已改完）。

---

## 0. 一句话

1. **草稿保活**：API 卡编辑页和引导的「接 API」页，切到后台那一刻把没存的内容存成草稿（地址、昵称这些进 UserDefaults，key 进钥匙串里一个**单独的、不同步的**位置）；App 被系统杀掉再打开，直接回到编辑页、内容原样带回。点「保存」或「取消」就清掉草稿。
2. **报错「去改」**：聊天里的报错胶囊在「重试」旁边多一个「去改」，按报错类型直达：key 不对 → 那张卡的编辑页；不收预填 → Prompt 页预填那一行；推理档不收 → 聊天里的模型 / 思考强度选择器；学到了不发的参数 → 全部模型页里那张卡；预算拦下 → 模型和API 页的预算节。

---

## 1. 现状

### 1.1 API 卡编辑页（`Views/APICredentialEditor.swift`）

| 事实 | 位置 |
|---|---|
| 表单全是 `@State`：emoji / 昵称 / 预设 / 协议 / 地址 / key（`apiKey`）/ 模型草稿（`draftModels`） | `:23-28`、`:105` |
| 有「打开时的样子」快照，用来判断改没改 | `DraftSnapshot` `:107-117`，`isDirty` `:119` |
| 改过就不许下滑关页（审查里「下滑一下就丢」那条 #092 已修） | `.interactiveDismissDisabled(isDirty)` `:238` |
| 「取消」= 直接 `dismiss()`，不确认 | `:245` |
| 进页面一次性装载：已存卡从卡表 + 钥匙串读；新建只分配一个空 emoji；最后 `original = snapshot` | `loadIfNeeded()` `:1234-1264` |
| 换预设 / 协议会重置模型草稿；**装载时给 `presetSelection` 赋值也会触发它**（已存卡碰巧还原成原清单，所以现在没出事） | `.onChange(of: presetSelection)` `:283` → `resetDraftModelsForProvider()` `:1267-1286` |
| 唯一落盘入口：卡 + key 一起写，然后 0.4s 后关页 | `persist(_:adopt:)` `:1364-1418` |
| ChatGPT 登录卡已有「切后台被回收后恢复」：UserDefaults 存 5 分钟 pending，进页面自动接上 | `:1253-1260`；`Services/ChatGPTOAuth/LoginCoordinator.swift:108-127` |
| 没有任何 `scenePhase` / `SceneStorage` / 草稿持久化 | 全文件 grep 无 |

编辑页的宿主：`APISettingsTab` 用 `.sheet(item: $editing)` 弹（`Views/APISettingsTab.swift:53-60`），`editing` 是 `@State`（`:24`）。设置本身在 iOS 是 `ContentView` 的 sheet（`Views/ContentView.swift:593-598`，开关 `showSettings` `:51`），mac 是独立 Settings 窗口（`openSettingsEntry()` `:1050-1056`）。
所以进程被杀之后，回来是聊天页，三层（设置 sheet → 模型和API 页 → 编辑 sheet）全没了。另外推送落在别的楼层会 `switchTo`，`.id(currentProfile.id)` 把整棵 ContentView 连设置 sheet 一起重建（审查原文引 `ContentView.swift:885-896`），这条路径也会丢。

### 1.2 引导（`Views/Onboarding/OnboardingFlowView.swift`，iOS only）

| 事实 | 位置 |
|---|---|
| 「接 API」页：选服务商 `pickedProvider`、自定义地址 `customBaseURL`、key `keyText`，全 `@State` | `:83-85`；表单 `:621`、`:632` |
| 步骤进度放在 `OnboardingResume.shared`，**只在进程内**（注释写明「不落盘」），为的是导卡切楼层重建时不丢 | `:4-20`、`:62`、`:166` |
| 没走完 = `onboardingCompletedV1` 为 false → 冷启动从欢迎页重来 | `ContentView.swift:64`、`:779` |
| 建卡只在「确认模型 / 带 key 跳过」时 | `persistCard()` `:709-734` |
| 走完清进度 | `:1098-1099` |

结论：引导是同一个坑，而且更糟——被杀后连步骤都回到欢迎页。

### 1.3 钥匙串（决定草稿 key 放哪）

- 卡的 key：`KeychainStore.set(…, account: 卡id, sync: cloudSyncEnabled)`，service 固定 `com.susu.MemoryPalace.apikey`（`Utils/KeychainStore.swift:9`，`Models/APIProvider.swift:689-699`）。
- **启动预热会把这个 service 下所有 account 当成卡 key 读进缓存**（`warmUpApiKeyCache()` = `KeychainStore.getAll()`，`APIProvider.swift:648-651`）；切 iCloud 同步时**把这个 service 下所有条目按新开关重写**（`reencryptAllKeys` `:710-…`）。
- `KeychainStore` 的 set/get/remove 都接受自定义 `service` 参数（`KeychainStore.swift:21`、`:50`、`:75`），测试走 `TestHostIsolation.keychainQuery`。

→ 草稿 key 如果放进卡 key 的 service，会被预热当成一张「叫 draft 的卡」、还会跟着 iCloud 同步出去。**必须换一个 service**。

### 1.4 报错怎么到气泡上

1. `ProviderRouter.sendStreaming`（`Services/ChatService.swift`）里报错只是一段 `String`：
   - 本地报错直接 `onError("…")`：「找不到提供商: id」`:1944`、「未设置 X 的 API Key」`:2085`、「卡类型不支持」`:2104`；请求中途保险闸「保险闸：本次预计花费超过剩余额度」`:309`。
   - HTTP 报错：`adaptiveFailed`（`:2117-2182`）先试 #094 自愈，修不了再 `requestFailed(safe(Self.failureMessage(…)))`。
   - `failureMessage`（`:2340-2361`）**只处理 400 / 422**：说人话（`.explain`）、思考块被拒、认不出时尾巴加「（host · 模型 · HTTP 400）」、重试又学到了就加「（已记住：…，下次自动照办）」。**401 / 403 / 404 / 429 / 5xx 原文照给，状态码丢了**（`errorMessage(from:statusCode:)` `:333-358` 只取 message）。
   - 说人话的两句在 `ParamErrorClassifier.classify` 里：「这个模型不收预填（…），去预设里关掉」`Services/ParamErrorClassifier.swift:167-169`、「X 上的这个模型不收推理强度「档」，换一档」`:171-174`、「X 不收参数 f 现在的值」`:175-178`。
2. `ConversationViewModel` 的 `onError`（`ViewModels/ConversationViewModel.swift:4053-4077`）把它**写进节点正文**：`"⚠️ " + error`（或接在已有段 / 半截正文后面，`\n\n⚠️ `）。这一刻手里有 `providerRouter.lastUsageRecord`（带 `providerId`）。
3. 渲染：`ChatSystemMessage.split` 按 `⚠️ ` 标记拆出报错（`Models/ChatSystemMessage.swift:11-24`）→ `BubbleView.messageError`（`Views/CardFlowView.swift:3818-3823`）→ `ChatSystemCapsule(text:…, isError: true, actionTitle: "重试", action: onRegenerate)`（`CardFlowView.swift:4075-4078`）。胶囊只有**一个**按钮位（`Views/Chat/ChatSystemCapsule.swift:3-9`、`:23-29`），11pt 单行，点文字弹「报错详情」。
4. 账本：每次失败也记一行 `UsageRecord`（`ChatService.swift:1958-1994`，`status: .error`），行里有 `providerId`、`model`、`messageNodeId`（`Models/UsageLedger.swift:51-54`、`:78`；VM 发送前设 `usageContext.messageNodeId = assistantNodeId`，`ConversationViewModel.swift:3960`）。
5. 发送前预算门控**不进气泡**：写 `budgetBlockedMessage`（`ConversationViewModel.swift:3845`、`:5509`），`ChatInputBar` 弹 alert「预算保险闸」，只有「好」（`CardFlowView.swift:2072-2079`）。

### 1.5 现有的「跳到设置某处」

| 机制 | 用在哪 | 位置 |
|---|---|---|
| iOS：设置根列表 `selectedSettingsTab` 赋值 push | 设置内部 | `Views/SettingsView.swift:92`、`:216` |
| iOS：搜索跳转 = 展开折叠组 + `SettingsSearchRouter.request(anchor:)` 投信 + 延一拍 push；页面 `.settingsAnchorScroll(proxy)` 取信滚到 `.searchAnchor(id)` 的行并薄荷一闪 | 设置搜索 | `SettingsView.swift:586-600`；`Views/Settings/SettingsSearchRouter.swift:13-119` |
| mac：`NotificationCenter .settingsOpenTab`（object = tab rawValue） | Claude Code 页跳「让手机连这台 Mac」 | `SettingsView.swift:439-443`、`:887`；`Views/CCSettingsView.swift:113` |
| mac：`workspacePreferences.settingsRequested` 布尔信箱 + 设置窗 `onAppear` / `onChange` 消费 | Dock「管理」开设置到 Mac 工作区 | `SettingsView.swift:433-462`；`Views/iPad/MacWorkspaceDock.swift:128` |
| 右栏：`RightPanelNavigator.pendingTarget(tool, id)` | 卡库 / 世界书 / 记忆等面板 | `Services/RightPanelNavigator.swift:6-34` |
| `SettingsRoute` | **只是设置二级页的标识**（mac 设置窗的 path），不是从外面进设置的路由 | `Views/Settings/SettingsRoute.swift:1-23` |

**没有**「从聊天里开设置并直达某页 / 某行 / 某张卡」的通路。锚点注册表里有 `leaf-persona-prefill` / `leaf-persona-sampling` / `leaf-persona-reasoning` / `leaf-api-keys` / `leaf-api-models`（`Views/Settings/SettingsSearch.swift:578-627`），但页面上真挂了 `.searchAnchor` 的只有少数几行（Prompt 页只有 usage / tool-drawer / related，`Views/PersonaSettingsTab.swift:1758`、`:1766`、`:1833`；模型和API 页一个都没挂、也没有 `ScrollViewReader`）。

目的地现状：
- 模型 / 思考强度选择器：`ChatInputBar` 的 `showModelPicker`（`CardFlowView.swift:1529`，iOS sheet `:2030`，mac popover `:2036`）→ `ModelPickerPopover`（`:3239`）里的 `ReasoningPickerRow`（`:3444`）。和报错胶囊在同一个文件，但不是同一个 View。
- 学到的参数：用户能看到的在「全部模型」页那张卡的模型行下「自动适配：…」+ ×（`APICredentialEditor.swift:1863-1882`，`ModelPoolPage` `:1576`，有 `filterCredentialId` 筛选 `:1582`）；完整表在 开发调试 → 参数自适配（`Views/DebugSettingsTab.swift:136`、`:242`）。
- 预算：模型和API 页「预算（全局总闸）」节（`APISettingsTab.swift:368-378`）。

### 1.6 和「模型和API」改名撞车（已经合进 master）

page2-apps 的改名**已经合进 master**（`da9040883 Merge zone/page2-apps … 统一叫「模型和API」`），但**还没进 backend-2**（`git merge-base --is-ancestor` 为否）。master 上已经变了的、本单要碰的：
- `SettingsView.SettingsTab.api` 的 rawValue：`"API"` → `"模型和API"`（mac `settingsOpenTab` 通知就是靠 rawValue 找 tab）
- `ConversationViewModel.budgetSettingsPath`：→ `"设置 → 模型和API → 预算（全局总闸）"`
- `APISettingsTab` 标题、`OnboardingFlowView` 三处、`CardFlowView` 一处空态文案
- `SettingsSearch.swift` 大改（102 行），锚点注册表行号会变

**实现的人第一步 `git merge master`**（本工位现在在合并队列里，等它合完 / 退回再说），所有代码只认枚举 case（`.api`），不写 `"API"` / `"模型和API"` 字面量；「去改」的识别规则也不看设置页叫什么。

---

## 2. 改法 · 草稿保活

### 2.1 新增 `APIDraftStore`（`Models/APIDraftStore.swift`，双端）

```
struct APIDraft: Codable {
    var slot: String            // 卡 id；新建 = "__new__"；引导 = "__onboarding__"
    var emoji, nickname, presetSelection, customBaseURL: String
    var customType: String      // ProviderType rawValue
    var toolsSupported: Bool
    var models: [DraftModel]    // modelId + name，只 HTTP 卡
    var keyStored: Bool         // key 是否存进了草稿钥匙串
    var onboardingStep: Int?    // 只引导用
    var savedAt: Date
}
```

- 非敏感部分：UserDefaults 一个键 `apiDraftV1`（JSON，单槽，见 2.4）。
- key：`KeychainStore.set(key, account: "draft", sync: false, service: "com.susu.MemoryPalace.apikey.draft")`——单独 service，不进 `getAll()` 预热、不被 iCloud 开关重写、永不同步。
- API：`save(_:key:)`、`load(slot:) -> (APIDraft, key: String?)?`（过期 / slot 不符返回 nil，过期顺手清）、`clear()`（UserDefaults + 钥匙串一起清）、`pendingResume() -> APIDraft?`（给 2.5 自动回到编辑页用）。
- 过期时间 `ttl` 见拍板 Q3。

### 2.2 编辑页接线（`APICredentialEditor.swift`）

1. 加 `@Environment(\.scenePhase)`；`onChange(of: scenePhase)` 变 `.inactive` / `.background` 且 `isDirty` 且是 HTTP 卡 → `APIDraftStore.save`。**只在这一刻写**，不逐键写钥匙串。
2. `loadIfNeeded()` 末尾、`original = snapshot` **之后**：有本 slot 的新鲜草稿 → 把字段盖上去（`original` 仍是已存卡 / 空白的样子 → `isDirty` 为真 → 下滑照样被拦）；页顶一行提示「接着上次没存完的填」+「丢掉」（丢掉 = 清草稿 + 重新装载原样）。
3. 盖 `presetSelection` 会触发 `resetDraftModelsForProvider()` 把恢复的模型清单冲掉（1.1 那条）→ 加一个一次性的 `restoringDraft` 标记，`resetDraftModelsForProvider` 见到它就只消费标记、不重置。
4. 清草稿：`persist` 落盘成功后、「取消」、「删除这张卡」、「丢掉」四处。
5. 已存卡：key 和已存的一样就不往草稿钥匙串里再写一份（`keyStored = false`，恢复时 key 从卡上读）。
6. 只 HTTP 卡（OpenAI 兼容 / Anthropic，含新建默认的「自定义」）存草稿；桥卡 / ChatGPT 登录（已有自己的 pending）/ 本机模型不存。

### 2.3 引导接线（`OnboardingFlowView.swift`）

1. 同样监听 `scenePhase`：在「接 API」页且填了东西 → 存 slot `__onboarding__`：服务商（`OnbProvider` 加 `String` rawValue）、自定义地址、key、`onboardingStep = Step.provider.rawValue`。
2. `init` 里 `OnboardingResume.shared.step` 为空（= 冷启动）且有新鲜的引导草稿 → 从「接 API」页开始，表单带回。前面几步的结果本来就在 `@AppStorage`（`onboardingIdentity` / `onboardingUserName` / `assistantName`，`:37-39`、`:66`），不用重放。
3. 清：`persistCard()` 成功、引导走完（`:1098`）、在接 API 页点「跳过」且没填 key。
4. 不动 `OnboardingResume` 的「进程内」语义（B7 那条注释的设计不变），只是冷启动多一个入口。

### 2.4 数据 / 持久化细则

| 问题 | 决定 |
|---|---|
| 草稿放哪 | 非敏感字段 UserDefaults `apiDraftV1`；key 钥匙串单独 service、`sync: false`、默认可访问性（解锁后） |
| 什么时候写 | 只在 `scenePhase` 离开 `.active` 时，且页面有改动 |
| 什么时候清 | 保存成功 / 取消 / 删卡 / 「丢掉」/ 过期（读时清）/ 引导走完 |
| 几张卡 | **单槽**：同一时刻只有一个编辑页开着，最后切后台的那一页赢。打开别的卡不会套用不属于它的草稿（按 slot 对号），也不会删掉它；那一页再切后台才会覆盖 |
| 新建 vs 编辑已有 | 新建 slot `__new__`，只在点「+」新建时恢复；编辑已有 slot = 卡 id，只在打开同一张卡时恢复。草稿里那张卡已经被删了 → 丢弃 |
| 已有卡在别处被改过（iCloud / 另一台） | 草稿照样盖上去（字段级覆盖，没做合并）；页顶提示会让她知道这是恢复出来的。风险见第 6 节 |
| mac | 同一份代码。mac 切到别的 app 也会 `.inactive` → 存草稿；关设置窗口不算取消 → 下次开同一页会带回。见拍板 Q4 |
| 备份 / 导出 | `GlobalExporter` 只导白名单分组和 `audiobook.checkpoint.*`（`Services/GlobalBackup/GlobalExporter.swift:186-201`），`apiDraftV1` 不会被带进备份；草稿钥匙串 service 也不在任何导出里 |
| 文件库存储格式 | 不碰 |

### 2.5 回来时怎么接上（依赖第 3 节的跳转通路）

冷启动后，`ContentView` 首次出现时：`APIDraftStore.pendingResume()` 有新鲜的 `__new__` 或卡 id 草稿，且引导没在显示、不是冒烟 / perf 启动（照抄 `consumePendingPushTarget` 的几道闸，`ContentView.swift` 同函数开头）→ 用第 3 节的 `SettingsJump` 开「设置 → 模型和API → 那张卡的编辑页」，编辑页自己装载时把草稿带回。一次性：投完信就不再自动弹（草稿还在，她自己点进来照样带回）。
见拍板 Q2（要不要自动弹回去）。

---

## 3. 改法 · 报错「去改」

### 3.1 统一的「从外面进设置」通路：`SettingsJump`

新文件 `Views/Settings/SettingsJump.swift`（双端，`@MainActor @Observable` 单例，一次性信箱，和 `SettingsSearchRouter` / `workspacePreferences.settingsRequested` 同一个套路）：

```
enum SettingsJumpTarget: Equatable {
    case credential(String?)          // 模型和API 页 + 打开这张卡的编辑页（nil = 只到模型和API 页）
    case modelPool(credentialId: String?)
    case budget                       // 模型和API 页，滚到预算节
    case persona(anchor: String)      // Prompt 页，滚到某一行（预填 / 采样参数）
}
var pending: SettingsJumpTarget?
func request(_:)    // 投信
func take(...)      // 各层取走自己那一段
```

- 发起：聊天里调 `SettingsJump.shared.request(target)`。
- iOS：`ContentView` `onChange(of: SettingsJump.shared.pending)` → `showSettings = true`；`SettingsView` iOS 身体 `onAppear` / `onChange` 取 tab（`.api` / `.persona`）→ 照搬 `jumpToSearchResult` 的「展开折叠组 + 投锚点 + 延一拍 push」；`APISettingsTab` `onAppear` 取 `credential(id)` → `editing = EditingCredential(credentialId: id)`（延一拍，等 push 动画）。
- mac：`ContentView.openSettingsEntry()` 同时投信；设置窗 `onAppear` + `onChange` 消费（同 `consumeWorkspaceRequest`），`selectedTab = .api` / `.persona`，`APISettingsTab` 同上开 sheet。
- 锚点：给 `APISettingsTab` 包 `ScrollViewReader` + `.settingsAnchorScroll`，预算节挂 `.searchAnchor("leaf-api-budget")`（注册表里如果没有就补一条，id 要过注册表唯一性单测）；Prompt 页给预填那一行挂 `leaf-persona-prefill`、采样参数挂 `leaf-persona-sampling`（注册表里已有）。
- 模型池：`.modelPool(id)` → 模型和API 页 push `ModelPoolPage`，`filterCredentialId = id`（给 `ModelPoolPage` 加一个初始筛选参数）。iOS 是 `NavigationLink`（`APISettingsTab.swift:131-140`），要改成能程序化 push 的写法；mac 对应的入口方式**未查证**。

### 3.2 识别：报错 → 目的地（`Services/FixJump.swift`，纯函数）

`FixJump.target(for errorText: String) -> FixJump.Kind?`，只看文字（正文里存的就是文字，见拍板 Q5）：

| 报错文字里有 | Kind | 去哪 | 按钮字 |
|---|---|---|---|
| `HTTP 401` / `HTTP 403`（3.3 补上的尾巴） | `.badKey` | 那张卡的编辑页 | 去改 |
| `未设置 ` + `的 API Key` | `.badKey` | 那张卡的编辑页（按卡名找） | 去改 |
| `HTTP 404` | `.badURL` | 那张卡的编辑页 | 去改 |
| `找不到提供商` / `卡的类型当前版本不支持` | `.cardMissing` | 模型和API 页（不开编辑页） | 去改 |
| `不收预填` | `.prefill` | Prompt 页 · 续写 Prefill 那一行（深度 0 的 assistant 段在插槽列表里，见拍板 Q6） | 去改 |
| `不收推理强度` | `.reasoning` | 聊天里的模型选择器（思考强度在里面） | 去改 |
| `不收参数 ` + `现在的值` | `.samplingValue` | Prompt 页 · 采样参数 | 去改 |
| `已记住：` | `.learned` | 全部模型页，筛到那张卡 | 去看 |
| `保险闸` | `.budget` | 模型和API 页 · 预算节 | 去改 |
| `思考块没被接受` / 429 / 5xx / 网络错误 / 其余 | nil | 不出按钮 | — |

- 顺序：上表从上往下第一个命中的算；`已记住：` 和别的同时出现时（重试又失败了）以前面那条为准，因为那条才是这次失败的原因。
- 「那张卡」在**点按钮时**才找：① 账本里 `messageNodeId == 这条节点` 的最后一行 `providerId`（`UsageLedger`，只在点的时候读一次）；② 「未设置 X 的 API Key」按卡名 X；③ 尾巴里的 host 对卡的 baseURL host；都找不到 → 只开到模型和API 页。
- 识别字符串都是**我们自己写的中文**（`ParamErrorClassifier` / `failureMessage` / 本地报错），集中成 `FixJump` 里的常量，生成方和识别方引用同一组常量，改文案时编译期就对得上。

### 3.3 `failureMessage` 补状态码（`ChatService.swift:2340-2361`）

- 现在只有 400 / 422 认不出时才加「（host · 模型 · HTTP 状态码）」。改成：**有 HTTP 状态码（> 0）的失败一律带这条尾巴**（已经带了就不重复）。401 / 403 前面再加一句「key 不对或没有权限」，404 加「地址不对，检查 Base URL」——审查里点名要的那几类，别的状态码只加尾巴不加话。
- 这是「去改」识别 401 / 404 的依据，也是审查要的「报错带状态码」。
- 只改文字，存储格式不变（节点正文还是 `⚠️ …` 一段字符串）。

### 3.4 胶囊加按钮（`Views/Chat/ChatSystemCapsule.swift`）

- 加第二个按钮位：`secondaryTitle` / `secondaryAction`（可选，默认 nil，现有调用方不受影响），样式和「重试」一样（`Theme.textPrimary` semibold、plain），两个按钮之间一个细点分隔。不加蓝 / 黄。
- 「报错详情」sheet 底部也放同一个按钮（单行胶囊被挤时她点开详情也能找到）。

### 3.5 气泡接线（**要动 `CardFlowView.swift`**）

- `BubbleView`（`CardFlowView.swift:4075-4078`）：`messageError` 算出 `FixJump.Kind` → 传给胶囊第二按钮；动作 = `.reasoning` 时发「开模型选择器」请求，其余 = `SettingsJump.shared.request(…)`。`Kind` 由 `messageError` 文字算，纯字符串匹配，不读库、不读账本（账本只在点按钮时读）。
- `.reasoning`：`ChatInputBar` 的 `showModelPicker`（`:1529`）是它自己的 `@State`，气泡碰不到 → 在 `ConversationViewModel` 加一个一次性的 `modelPickerRequest`（自增计数），`ChatInputBar` `onChange` 到就 `showModelPicker = true`。改动是 VM 一个属性 + `ChatInputBar` 一个 `onChange`。
- 发送前预算 alert（`CardFlowView.swift:2072-2079`，在 `ChatInputBar` 里）：「好」旁边加「去改预算」→ `SettingsJump.shared.request(.budget)`。
- `node.role == "system"` 的 `⚠` 胶囊（`:4071-4072`）：先不加（哪些报错会写成 system 节点没查清，见未查证）。

**CardFlowView 只动这三处**（气泡胶囊参数、`ChatInputBar` 一个 onChange、预算 alert 一个按钮），不动布局。改名那边也改过这个文件的空态文案，`git merge master` 后再动。

---

## 4. 报错类型 → 目的地对照（汇总）

| 报错 | 现在气泡上的样子（来源） | 按钮 | 目的地 | iOS 路径 | mac 路径 |
|---|---|---|---|---|---|
| key 不对（401 / 403） | 上游原文（3.3 后加「key 不对或没有权限」+ 尾巴） | 去改 | 那张卡的编辑页 | 设置 sheet → 模型和API → 编辑 sheet | 设置窗 → 模型和API → 编辑 sheet |
| 没填 key | 「未设置 X 的 API Key」`ChatService.swift:2085` | 去改 | 卡 X 的编辑页 | 同上 | 同上 |
| 地址不对（404） | 原文（3.3 后加一句 + 尾巴） | 去改 | 那张卡的编辑页 | 同上 | 同上 |
| 卡没了 / 类型不认识 | `:1944`、`:2104` | 去改 | 模型和API 页 | 设置 sheet → 模型和API | 设置窗 → 模型和API |
| 不收预填 | `ParamErrorClassifier.swift:168` | 去改 | Prompt 页 · 续写 Prefill 行 | 设置 sheet → Prompt（lite 走 `LitePersonaPage`，见未查证） | 设置窗 → Prompt |
| 推理档不收 | `:173` | 去改 | 聊天模型选择器（思考强度） | 输入栏模型 sheet | 输入栏模型 popover |
| 采样参数值不对 | `:177` | 去改 | Prompt 页 · 采样参数 | 设置 sheet → Prompt | 设置窗 → Prompt |
| 重试也失败但学到了参数 | 「（已记住：…）」`ChatService.swift:2358` | 去看 | 全部模型页，筛到那张卡 | 设置 sheet → 模型和API → 全部模型 | 设置窗 → 模型和API → 全部模型 |
| 请求中途保险闸 | 「保险闸：本次预计花费超过剩余额度」`:309` | 去改 | 模型和API · 预算节 | 设置 sheet → 模型和API（滚到预算） | 设置窗 → 模型和API |
| 发送前预算拦下 | alert「预算保险闸」`CardFlowView.swift:2072` | 去改预算 | 同上 | 同上 | 同上 |
| 思考块被拒 / 429 / 5xx / 网络 | — | 无 | — | — | — |

---

## 5. 测试

单测（`MemoryPalaceTests`，scheme `MemoryPalaceTests`，module「记忆花园」；验收要 grep 到目标类的 `Test Suite … passed`）：

1. `APIDraftStoreTests`：存 / 取往返；slot 不符返回 nil；过期返回 nil 且已清；`clear()` 后 UserDefaults 和草稿钥匙串都空；**UserDefaults 里存的 JSON 不含 key 原文**；草稿 service 的条目不出现在 `KeychainStore.getAll()`（默认 service）里；钥匙串走 `TestHostIsolation`，不碰真钥匙串。
2. `FixJumpTests`：第 4 节每一行一条输入 → 期望 Kind；`已记住：` 和 `HTTP 401` 同时出现取 401；普通正文里提到「保险闸」三个字但没有 `⚠️` 标记 → 不出按钮（只对 `messageError` 跑）；所有识别常量能在生成方源码里找到（防文案漂移）。
3. `ParamErrorClassifierTests` 里 `failureMessage` 那组（`MemoryPalaceTests/ParamErrorClassifierTests.swift:151`）：更新期望——401 / 403 / 404 / 429 带尾巴，400 认出来的 `.explain` 也带尾巴，不重复加。
4. `SettingsSearch` 注册表唯一性单测：补 `leaf-api-budget` 后仍过。

模拟器手验（`sim`，`device-lease`；测试用的卡用假 key + 本机 mock 服务器，不用她的数据、不打生产 hub）：

5. 新建卡：填昵称、自定义地址、假 key → 回桌面 → `xcrun simctl terminate` → 重开 → 自动回到「设置 → 模型和API → 新建 API」，字段和 key 都在、页顶有「接着上次没存完的填」；点「保存」后再杀再开 → 不再弹，草稿已清。
6. 编辑已有卡同上；中途点「取消」→ 杀掉重开 → 不弹。
7. 引导：在「接 API」页填好 → 杀掉重开 → 直接在「接 API」页、内容在。
8. 本机 mock（`python3 -m http.server` 那种小脚本，按路径回 401 / 404 / 400 预填 / 400 推理档 / 400 学参数）→ 每种报错胶囊出「去改」→ 点了落到第 4 节的目的地；mac 上同样走一遍（`mac`）。
9. 预算：把总预算调成很小 → 发送被 alert 拦 → 「去改预算」落到预算节。

构建：mac + iOS `build-for-testing` 都要 `** TEST BUILD SUCCEEDED **`（工位现在暂停本地编译时，按当时规矩交给 Warden 集成区编）。

---

## 6. 风险

1. **`scenePhase` 在 sheet 里收不收得到**：SwiftUI 说环境会传进 sheet，但嵌两层 sheet（设置 sheet → 编辑 sheet）的实际行为没实测。兜底：收不到就在 `ContentView` 层监听，投一个「现在存草稿」的信给编辑页。（未查证 1）
2. **被杀前来不及写**：切后台时 `.inactive` → `.background` 都会触发，钥匙串和 UserDefaults 写都是同步的；但系统在极端内存压力下直接杀挂起中的进程，写在切后台那一刻已经完成，问题不大。UserDefaults 交给 cfprefsd 是异步落盘的，`simctl terminate` 测不出差别。（未查证 2）
3. **嵌套 sheet 时序**：设置 sheet 刚弹出就 push + 再弹编辑 sheet，iOS 会吞掉动画中途的第二次 present。要按 `jumpToSearchResult` 的延一拍做法，必要时再延；这是最可能要调的地方。
4. **草稿盖掉别处的新改动**：编辑已有卡时，草稿是字段级整块覆盖，iCloud 同步来的新地址会被旧草稿盖回去（只要她点保存）。概率低（要恰好在切后台期间别处改了同一张卡），页顶提示能看到。
5. **按文字识别报错会漂移**：文案改了按钮就没了。用共用常量 + 单测（第 5 节第 2 条）兜。
6. **自动弹回去打扰人**：她其实已经不想加这张卡了，每次冷启动都被拉回编辑页。所以设计成一次性：弹过一次就不再自动弹，草稿留着等她自己进来。
7. **改名合并冲突**：`SettingsView` / `SettingsSearch` / `OnboardingFlowView` / `CardFlowView` / `ConversationViewModel` 在 master 上都动过，先 `git merge master` 再动手，否则锚点注册表那块一定冲突。
8. **账本按节点找卡**：账本行是追加写，点按钮时读一次全表，大账本可能慢一点（只发生在点按钮那一下）。

---

## 7. 不做什么

- 不给 `MessageNode` 加字段（不动 SwiftData 模型）。
- 不改文件库存储格式；不改 `KeychainStore` 本身。
- 不做报错文案整体中文化（只补 401 / 403 / 404 三句 + 状态码尾巴）。
- 不动 Page2 网页皮肤聊天的报错显示。
- 不改「取消」的语义（还是直接关、不确认）。

---

## 8. 要粟粟拍板

**Q1 · 草稿里的 key 怎么存**
- **A（推荐）**：存进钥匙串，单独一个位置，不跟 iCloud 同步，保存 / 取消 / 过期就删。回来时 key 也在，她不用再复制一遍。
- B：key 不存，回来时其它都在，key 那一栏提示「上次贴的 key 没保存，再贴一次」。最保守，但正是她嫌麻烦的那一步。

**Q2 · App 被杀后回来，怎么回到编辑页**
- **A（推荐）**：重新打开时自动回到「设置 → 模型和API → 那张卡」，内容带回；只自动弹一次。
- B：不自动弹；她自己点进 设置 → 模型和API → 「+」（或那张卡）时才带回。

**Q3 · 草稿留多久**
- **A（推荐）**：24 小时。
- B：30 分钟（和 ChatGPT 登录的 5 分钟同一个思路，更保守，但她出去查资料久一点就没了）。

**Q4 · mac 要不要也存草稿**
- **A（推荐）**：要，同一份代码；mac 关掉设置窗口也算「没存完」，下次打开同一页会带回。
- B：只 iOS（mac 上 App 很少被系统杀）。

**Q5 · 报错类型怎么认**
- **A（推荐）**：按报错文字认（文字是我们自己写的，补上「HTTP 401」这类尾巴），卡在点按钮时从用量账本找。不加存储字段，老消息、重启后的消息也有按钮。
- B：报错那一刻把「去哪改」记在内存里。准，但 App 重启后老报错就没有按钮了。
- C：给消息加一个字段存。最准，但要改数据库结构，不推荐。

**Q6 · 「不收预填」跳到哪**
- **A（推荐）**：Prompt 页「续写 Prefill」那一行（续写预填在这里），这一行下面再加一句「深度 0 的 assistant 段在插槽列表里」。
- B：直接跳插槽列表（深度 0 的 assistant 段多数时候是从酒馆预设带进来的）。

**Q7 · 「学到了不发的参数」跳到哪**
- **A（推荐）**：全部模型页，筛到那张卡，模型行下面有「自动适配：…」和 × 可以清。
- B：开发调试 → 参数自适配那张表（全，但在开发调试里，新用户找不到）。

**Q8 · 按钮放哪**
- **A（推荐）**：胶囊里「重试」旁边，同时报错详情页底部也放一个。
- B：只放报错详情页（胶囊保持一个按钮，但要多点一下）。

---

## 9. 执行清单（一项一个可单独 revert 的提交）

前置
- [x] 0. `git merge master`（拿到「模型和API」改名），xcodegen generate，确认工位不在合并队列里了 ⏭ 跳过：工位在合并队列 #00460，车头合完再 merge

草稿保活
- [x] 1. 新增 `Models/APIDraftStore.swift`（UserDefaults `apiDraftV1` + 钥匙串单独 service）+ `APIDraftStoreTests` ✅
- [x] 2. 编辑页：切后台存草稿（`scenePhase`），只 HTTP 卡、只在有改动时 ✅
- [x] 3. 编辑页：装载时恢复草稿 + `restoringDraft` 标记防模型清单被冲掉 + 页顶「接着上次没存完的填 · 丢掉」 ✅（标记改成「记住草稿属于哪一家」，见复盘）
- [x] 4. 编辑页：保存成功 / 取消 / 删卡时清草稿 ✅
- [x] 5. 引导：`OnbProvider` 加 rawValue；「接 API」页切后台存草稿 ✅
- [x] 6. 引导：冷启动有引导草稿 → 从「接 API」页开始并带回；走完 / 建卡 / 跳过时清 ✅

跳转通路
- [x] 7. 新增 `Views/Settings/SettingsJump.swift`（信箱 + 目标枚举） ✅
- [x] 8. iOS：`ContentView` 收信开设置 sheet；`SettingsView` 取 tab（展开折叠组 + 锚点 + 延一拍 push） ✅
- [x] 9. mac：开设置窗时投信，设置窗 `onAppear` / `onChange` 取 tab ✅
- [x] 10. `APISettingsTab`：取 `credential(id)` 开编辑 sheet；包 `ScrollViewReader` + 预算节锚点 `leaf-api-budget`（注册表补条目） ✅（条目本来就有；补 `anchor:` 留到 merge master 后，见复盘）
- [x] 11. `ModelPoolPage` 加初始筛选参数；`APISettingsTab` 能程序化 push 全部模型页 ✅
- [x] 12. `PersonaSettingsTab` 给「续写 Prefill」「采样参数」两行挂锚点（照 Q6 结果，必要时加那一句提示） ✅
- [x] 13. 冷启动有新鲜草稿 → 一次性 `SettingsJump` 回到编辑页（照 Q2 结果；带上冒烟 / perf / 引导三道闸） ✅

报错「去改」
- [x] 14. `failureMessage` 补状态码尾巴 + 401/403/404 一句人话；更新 `ParamErrorClassifierTests` ✅
- [x] 15. 新增 `Services/FixJump.swift`（识别常量 + `target(for:)` + 点按钮时找卡）；`ParamErrorClassifier` / `ChatService` 本地报错改用共用常量；`FixJumpTests` ✅
- [x] 16. `ChatSystemCapsule` 加第二按钮位 + 详情页底部按钮 ✅
- [x] 17. `CardFlowView` · `BubbleView` 报错胶囊接「去改」（⚠️ 动 CardFlowView） ✅
- [x] 18. `ConversationViewModel` 加 `modelPickerRequest`；`CardFlowView` · `ChatInputBar` `onChange` 开模型选择器（⚠️ 动 CardFlowView） ✅
- [x] 19. `CardFlowView` · 发送前预算 alert 加「去改预算」（⚠️ 动 CardFlowView） ✅

收口
- [x] 20. mac + iOS `build-for-testing` SUCCEEDED；目标测试类 `Test Suite … passed` ✅
- [ ] 21. 模拟器 / mac 手验第 5 节 5–9 条，`device-lease` 装 `sim`，叫粟粟验 ⏭ 没做：工位租不到 sim（10-02 规矩，device-lease exit 75），步骤写进验收说明，合进 master 后 Warden 装 sim 跑
- [x] 22. `manual/facts/` 同步（API 卡编辑、聊天报错两页），`docs/now/backend-2.md`，复盘 `docs/review-api-draft-and-fix-jump.md` ✅

---

## 10. 未查证

1. 两层 sheet（设置 sheet → 编辑 sheet）里 `@Environment(\.scenePhase)` 能不能收到 `.inactive` / `.background`。
2. `simctl terminate` 能不能代表「系统在后台回收」（钥匙串 / UserDefaults 都在切后台时写，理论上一样，没实测）。
3. iOS 上 `SecureField` 失焦再聚焦会清空原内容（审查里也标了「系统行为，未实测」）——恢复出来的 key 她再点进去改会不会被整段清掉。
4. 失败请求的账本行是不是一定带 `messageNodeId`（`UsageRecord(provider:…context:)` 的构造没逐行读；VM 侧确实设了 `usageContext.messageNodeId`）。本地报错（没 key / 找不到卡）不进账本，靠卡名兜。
5. mac 设置窗里「全部模型」页的入口方式（iOS 是 `NavigationLink`），程序化 push 怎么接。
6. 简洁版（lite）Prompt 页 `LitePersonaPage` 有没有「续写 Prefill」「采样参数」这两行；没有的话 `.prefill` / `.samplingValue` 在 lite 下要先切 pro 还是只到页面级。
7. 哪些报错会写成 `role == "system"` 的节点（`CardFlowView.swift:4071` 那条分支），要不要也给它们加按钮。
8. Page2 网页皮肤聊天（`Views/Page2/Chat/ChatWebPayload.swift`）里报错怎么显示、要不要跟进。
9. 冷启动时引导直接从「接 API」页开始，前面几步（导卡切楼层、Ghost 拷贝等）的副作用是否都已落盘、跳过它们会不会漏东西。
10. mac 上 `ChatInputBar` 是不是都经 `MacChatComposerHost`（`Views/Chat/MacChatComposerHost.swift:29`）同一个实例，`modelPickerRequest` 的 `onChange` 会不会两处都响应。
