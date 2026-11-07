# review · API 卡草稿保活 + 报错「去改」直达

> plan：[plan-api-draft-and-fix-jump.md](plan-api-draft-and-fix-jump.md)（粟粟 10-15 批 Q1–Q8「都按推荐」；验收第一条：「我重新打开app要留在这一页」）。
> 验收说明：`~/Desktop/cc-rp/API链路/草稿保活-去改-验收.md`。
> 工位 backend-2，基于 `4075461f6`（10-15 车头提交 dfc523a70 / e7301dbaf / 9dba67cc4 后 merge 了 master bcd7ca4c4，含「模型和API」改名）。执行者只改工作区、不提交；逐项文件清单交车头（scratchpad `draft-items.md`）。

## 做了什么（对应 plan §9 执行清单）

| 步 | 内容 |
|---|---|
| 0 | 跳过：工位在合并队列里，车头合完 #00460 再 merge master |
| 1 | `APIDraftStore`：非敏感字段 → UserDefaults `apiDraftV1`（JSON 单槽）；key → 钥匙串 service `com.susu.MemoryPalace.apikey.draft`、account 每版一个 `draft-UUID`（astra #1 后）、`sync: false`；24 小时过期（读时清）；`clear(slot:)` 只清属于这一页的；`takePendingResume()` 一次性（记 `resumeOffered`，再切一次后台存出来的新草稿又能弹一次） |
| 2 | 编辑页：`scenePhase` 离开 `.active` + 应用失活通知（兜底未查证 1）+ `onDisappear`（mac 关设置窗 / 换楼层整树重建，Q4）→ 只 HTTP 卡、只在 `isDirty` 时存。已存卡 key 没改 → 不往草稿钥匙串写（`keyStored=false`）；她把 key 清空了 → 存空（恢复成空，不回退成卡上的） |
| 3 | `loadIfNeeded` 末尾、`original = snapshot` 之后盖草稿 → 下滑照样被拦；页顶「接着上次没存完的填 · 丢掉」；模型清单防冲掉见「和 plan 不一样」第 1 条 |
| 4 | 保存成功 / 取消 / 删卡 / 丢掉 → `clear(slot:)`，并置 `draftFinished` 防 `onDisappear` 再存 |
| 5 | 引导：`OnbProvider: String`；「接 API」页填了东西 → 存 slot `__onboarding__`（服务商放 `presetSelection`） |
| 6 | 引导 `init`：进程内进度为空 + 有新鲜引导草稿 → 从「接 API」页开始、服务商 / 地址带回，key 在 `onAppear` 从钥匙串取（init 可能被反复调用，不在里面读钥匙串）；`persistCard` 成功 / 走完 / 没 key 跳过时清 |
| 7 | `SettingsJump`（`@MainActor @Observable` 信箱 + `serial`）+ 目标枚举 + 三层消费器：`SettingsJumpHost`（ContentView 开设置）、`SettingsJumpTabConsumer`（SettingsView 切页）、`settingsJumpTarget`（页面取走自己那段） |
| 8 | iOS：`showSettings = true` → 设置根 `onAppear` 延 0.45s push（已在别的页先 pop 再 push）；目标是 Prompt 行 → 这一次简洁版也走完整 `PersonaSettingsTab`（`jumpFullPersona`，未查证 6 的答案：简洁版 `LitePersonaPage` 没有这两行） |
| 9 | mac：`openSettings()`；设置窗 `onAppear` / `onChange(serial)` 切 `selectedTab` |
| 10 | 模型和API 页包 `ScrollViewReader` + `.settingsAnchorScroll`，预算节挂 `leaf-api-budget`；取 `.editCredential` / `.newCredential` 延 0.6s 开编辑 sheet；草稿那张卡已删 → 丢草稿 |
| 11 | `ModelPoolPage(initialFilterCredentialId:)`；iOS 加一个 `navigationDestination(isPresented:)`（原 NavigationLink 不动），mac 原 sheet 带筛卡（未查证 5 的答案：mac 本来就是 sheet） |
| 12 | Prompt 页两处「采样参数」折叠组挂 `leaf-persona-sampling`、内容行挂 `leaf-persona-prefill`；Prefill 下加「预设里深度 0 的 assistant 段也算预填，在插槽列表里开关」（Q6-A）；取信：简单 / 预览模式切到插槽模式、展开、再投锚点 |
| 13 | 冷启动：`SettingsJumpHost.onAppear` 一次进程只查一次（`resumeChecked`，换楼层重建不再弹），闸 = 测试宿主 / XCTest / 引导盖着 / 冒烟 / 基准 / perf 角色，延 0.8s 投信 |
| 14 | `failureMessage`：有 HTTP 状态码一律带「（host · 模型 · HTTP n）」（已带不重复）；401/403 前加「key 不对或没有权限。原文：」、404 前加「地址不对，检查 Base URL。原文：」；`.explain` 认出来的也带尾巴 |
| 15 | `FixJump`：识别常量 + `kind(for:)` + 点按钮时找卡（账本这条节点最后一行 → 「未设置 X」按卡名 → 尾巴 host）+ `perform`；`ParamErrorClassifier` 三句、`ChatService` 本地报错 / 保险闸（含两处非流式 throw）改用常量，字面不变 |
| 16 | 胶囊第二按钮位（「重试 · 去改」，细点分隔，样式同「重试」）；报错详情底部同一个按钮（浅薄荷底），点了先收详情、0.45s 后再跳 |
| 17 | BubbleView 报错胶囊传 `secondaryTitle/secondaryAction`（流式中不出） |
| 18 | VM `modelPickerRequest`（自增）；ChatInputBar `onChange` → `showModelPicker = true` |
| 19 | 预算 alert「好」旁加「去改预算」→ 收 alert、0.35s 后 `SettingsJump.request(.budget)` |
| 20 | 见「验证」 |
| 21 | **没做**：模拟器被占（见「验证」） |
| 22 | 本复盘、now、`manual/facts/model/model-api.md` 6 条、`manual/facts/modules/main-chat.md` 1 条；`npm run check / rewrite / build` 没跑 |

## 和 plan 不一样的地方

1. **`restoringDraft` 一次性标记 → 改成「记住草稿属于哪一家」**：装载时 `presetSelection` 和 `customType` 可能各触发一次 `onChange`，也可能都不触发（草稿和默认值一样），一次性标记会被吞错一次或留到她下一次真换家时才吞。改成 `restoredDraft = (preset, type, models)`：`resetDraftModelsForProvider` 见到「现在就是草稿那一家」就还原草稿清单（和原有「换回原来那家还原原清单」同一个思路），而且放在 Ollama 清地址那句**之前**，免得恢复出来的 Ollama 地址被清。
2. **存草稿多了两个时机**：应用失活通知（`scenePhase` 在两层 sheet 里收不收得到没实测，兜底；重复写无害）、`onDisappear`（plan 只说 mac 关窗算「没存完」，iOS 上被 `.id(currentProfile.id)` 整树重建也会走这里，正好盖住 plan §1.1 末尾那条丢失路径）。
3. **目标枚举**：plan 的 `.credential(String?)`（nil = 只到页）拆成 `.apiPage` / `.editCredential(id)` / `.newCredential`——新建卡要能单独表达。
4. **注册表在 merge master 之后才动**：`leaf-api-budget` 条目补 `anchor: "leaf-api-budget"`、`.api` 加进 `anchoredTabs`（设置搜索「预算」也会滚到预算节并薄荷一闪）。
5. **`.prefill` / `.samplingValue` 会改她的 Prompt 页模式**：采样参数折叠组只在插槽 / 原始模式里有，简单 / 组装预览 / 请求预览模式下跳过来**这一次临时**按插槽模式显示（astra #9 后不再写她存的模式，离开页面 / 重启就回原样）。
6. **`.reasoning` 从详情页点**也延一拍（sheet 收起后才开模型选择器）。

## astra 一轮裁决（2 P1、9 P2；车头裁定：10 条全收，第 11 条部分收）

| # | 级别 | 问题 | 裁定 | 怎么改的 |
|---|---|---|---|---|
| 1 | P1 | 草稿元数据和 key 可能串卡（公共 account 先被 B 覆盖、B 元数据没落盘就被杀 → A 页带出 B 的 key；写入返回值没看） | 收 | 每版草稿一个钥匙串 account（`draft-UUID`），JSON 里存引用；先写钥匙串、成功才发布元数据、最后删旧版；元数据说有 key 但读不到 → 整份作废。测试：写失败保留旧版、半截写入不串卡、孤儿下次收掉 |
| 2 | P1 | 带凭据的地址（query / userinfo）明文进 UserDefaults | 收 | `isSafeBaseURL`：只认干净的 http(s)://host/path，有 userinfo / query / fragment / 像 key 的段 → 整条地址和 key 一起进这一版的钥匙串，偏好里留空；引导同一个 store 也覆盖。测试含引导 slot |
| 3 | P2 | 同进程切楼层重建引导，「接 API」页表单变空 | 收 | 停在「接 API」页（进程内进度 = provider）且草稿在 → 新实例 onAppear 表单还空时从草稿带回；加 onDisappear 存 |
| 4 | P2 | 改回原样后旧草稿还会复活 | 收 | 存草稿时不再脏了 → 清这一页的草稿（含 key） |
| 5 | P2 | 「只自动弹一次」被没改东西的切后台重新武装、还续期 | 收 | 记上一次存下 / 恢复出来的快照，没新改动不重存（编辑页、引导都是） |
| 6 | P2 | 列表左滑 / 右键删卡不清草稿 | 收 | 清草稿挪进 `ProviderManager.removeCredential`（所有删卡都走它），编辑页那处去掉。测试 |
| 7 | P2 | 冷启动回草稿抢走推送点进来的会话 | 收 | 有待消费的推送 / 来电、或这次启动已经被推送 / 来电认领（`noteExternalNavigation`）→ 这次不弹、草稿不标「弹过」；0.8 秒后真要投信前再查一遍 |
| 8 | P2 | 找卡会开错卡（账本里的卡已删退回 host 猜；同名取第一张） | 收 | 账本记的卡已删 → 只开卡列表；卡名 / host 只有唯一一张才认；改了把错行为写成通过条件的测试 |
| 9 | P2 | 「去改」永久改了 Prompt 页模式 | 收 | `@AppStorage` 改名 `storedPersonaEditMode`，页面读 `jumpModeOverride ?? 存的`；跳过来只设临时覆盖（`@State`，离开页面 / 重启就没），她自己切模式时清覆盖再写偏好 |
| 10 | P2 | 输入条不在树上（贴纸面板 / 查找 / 多选）时推理档「去改」丢了 | 收 | VM `modelPickerRequested` 改成待消费的布尔；输入条 `onChange(initial: true)` 接手清掉；iOS `InputBarStack` / mac `MacChatComposerHost`（常驻）见到请求先收贴纸面板 |
| 11 | P2 | 钥匙串 / 读账本在主线程 | 部分收 | 找卡读账本挪后台（`ledgerProviderId(nodeId:) async`，读完回主线程投信）；草稿钥匙串写**保持同步**（就一小条，切后台前写完才保得住），iOS 包一层 `beginBackgroundTask`；编辑页装载时读钥匙串照旧 |

## 1. 边界情况

- **单槽**：A 卡编辑页切后台存了草稿，再去编辑 B 卡切后台 → A 的草稿被覆盖（plan §2.4 设计如此）。打开 C 卡不套用、不删别人的草稿。
- **已有卡被别处改过**（iCloud / 另一台）：草稿字段级整块盖上去，她点保存就把别处的新改动盖回（plan 风险 4）；页顶提示能看出是恢复的。
- **新建卡 emoji**：恢复时用草稿里的 emoji；期间被别的卡占了 → 原有「被占用」红字提示。
- **恢复出来的 key 在 iOS `SecureField` 里**：她再点进去打字，系统会整段清空（未查证 3，改前同样如此，和草稿无关；有「显示」开关可绕）。
- **引导草稿**：只在「接 API」页存；走到「挑模型」页被杀 → 回到「接 API」页（模型列表要重拉）。前几步的身份 / 称呼 / 名字本来就在 `@AppStorage` / 楼层里；导卡切楼层等别的副作用是不是都已落盘**仍未查证**（plan 未查证 9）。
- **从设置「?」重走引导**：`onboardingCompletedV1` 不会被置回 false，所以重走途中被杀、冷启动不会盖引导（回到平常的 app）；引导草稿留着，24 小时内她再从「?」开引导会直接从「接 API」页开始、内容带回。没另做处理。
- **冷启动只自动弹一次**：她不想要了 → 下次冷启动不再弹，草稿留 24 小时等她自己点进来；再编辑一次切后台 = 新草稿，又弹一次。
- **设置 sheet 已经开着 / 在别的二级页**：iOS 先 pop 再延 0.45s push；mac 直接切侧栏。
- **两层 sheet 时序**（plan 风险 3）：设置 sheet → push → 编辑 sheet 三段都靠固定延时（0.45 / 0.6s），慢机上可能被吞——吞了的话信已经被模型和API 页取走，表现为停在模型和API 页、没开编辑页。**没在模拟器 / 真机上跑过**。
- **「去改」找卡**：本地报错（没 key / 找不到卡）不进账本 → 按卡名，只认唯一同名（astra #8 后；同名多张 / 账本里的卡已删 → 只开卡列表）。HTTP 报错一定有账本行（未查证 4：`UsageRecord(provider:…context:)` 构造里 `messageNodeId = context.messageNodeId`，VM 发送前设了；已读代码确认）。账本是点按钮那一下在后台全量读一次（plan 风险 8；astra #11 后不在主线程）。
- **老消息**：本单之前的 401 / 404 报错没有尾巴、没有人话 → 不出按钮；「未设置 X」/「找不到提供商」/ 预填 / 推理档 / 采样值 / 已记住 / 保险闸 这些老文案字面没变，老消息也有按钮。
- **429 / 5xx 现在也带尾巴**（plan「有 HTTP 状态码一律带」），但不出按钮。
- **`role == "system"` 的报错胶囊**没接按钮（未查证 7，plan 说先不加）。
- **mac 上的模型选择器**：只有 `MacChatComposerHost` 一个 ChatInputBar 实例（未查证 10 读代码确认：iOS 走 `InputBarStack`，mac 走 `MacChatComposerHost`，各一个）。

## 2. 和下一模块交互的风险

- **merge master 冲突面**：本单碰了 master 改过的 `SettingsView.swift`（只在 body 两行 + iOS 状态区 + Prompt 目的地一行，离 master 的改动 ≥ 20 行）、`APISettingsTab.swift`（离 `.navigationTitle` 30 行外）、`OnboardingFlowView.swift`（init / 状态区 / 三处清草稿，master 只改了几句文案）、`CardFlowView.swift`（2064 / 2078 / 4082，master 改 3430）、`ConversationViewModel.swift`（2111，master 改 5490）。预计自动合并；合完要 `xcodegen generate` 再编一遍。
- **合完要复跑 `SettingsSearchTests`**：master 加了 `testAPIPageNamedModelAndAPI` 等 4 个用例，本单没碰注册表，理论上不受影响。
- **识别靠文字**：以后改 `ParamErrorClassifier` / `failureMessage` / 本地报错文案时，请从 `FixJump` 的常量拼，`FixJumpTests` 从真生成方取输入，漂了会红。
- **Page2 网页皮肤聊天的报错**（未查证 8）不在本单，那边看不到按钮。
- **`SettingsJump` 是新的公共通路**：以后「从外面直达设置某处」都可以走它（master 的 `SettingsView.requestMacTab` 只管 mac 侧栏页，两套并存，合完可以考虑统一）。

## 3. 技术债务

- **UI / 跳转时序全没在设备上看过**（第 21 项没做）：草稿横幅长相、三段延时够不够、Prompt 页滚到 prefill 那一行（锚点挂在折叠组的内容行上，整行 `.center`，行很高时 Prefill 可能刚好在屏幕下沿）。
- 固定延时（0.45 / 0.6 / 0.35 / 0.45 / 0.8s）都是经验值，照 `jumpToSearchResult` / `settingsAnchorScroll` 的做法，没有「等动画结束」的回调。
- `budgetSettingsPath` master 已改成「设置 → 模型和API → 预算（全局总闸）」，没再动。
- `SettingsJumpHost` 的 `onChange(serial)` 在 iOS 只置 `showSettings = true`，设置 sheet 若被别的 sheet 挡着（比如工具审批卡开着）会 present 失败，信留着，下次她自己开设置时会被消费跳过去。
- 说明书：facts 已加，`npm run check` / `rewrite` / `build` 没跑。

## 验证

- mac `build-for-testing`（MemoryPalaceTests）：`** TEST BUILD SUCCEEDED **`（第一次就过）。
- iOS `build-for-testing`（MemoryPalaceIOS，iOS 26 模拟器 9451D1D2）：`** TEST BUILD SUCCEEDED **`（第一次就过）。
- mac 定向（都 grep 到 `Test Suite '…' passed`）：APIDraftStoreTests 9、FixJumpTests 8、SettingsSearchTests 34、ParamErrorClassifierTests 18、ParamAutoAdaptRouterTests 17、InspectorRealPathTests 20、PromptRealPathGoldenTests 7、MainThreadIOBudgetTests 3（共 116，0 失败）；BudgetGateTests 单跑 38，全过。
- 金样：没重录、原样过（错误文案不进请求体）。
- 测试期望改动：`ParamErrorClassifierTests.testFailureMessage`（500 现在带尾巴、prefill 带尾巴、学到参数带尾巴，新增 401/403/404/429/0/不重复 6 条）、`ParamAutoAdaptRouterTests.testPrefillExplainedInPlainWords`（尾巴）。
- **模拟器手验没做**：`sim`（9451D1D2，粟粟日常前台）关着，另一台「记忆花园 回归 17Pro」（F3BAB89B，regress）开着、App 在跑、idb 连着、没有租约——「同一时间只跑一个模拟器」，不能再开一台，也不能关别人的。按任务书「被挡就跳过」。

### 合 master 之后（bcd7ca4c4）

- `xcodegen generate` 后 mac / iOS `build-for-testing` 都 `** TEST BUILD SUCCEEDED **`，合并没弄坏东西，没改代码。
- 注册表补 `leaf-api-budget` 锚点 + `anchoredTabs` 加 `.api`。
- 新加 / 改过的界面文字逐条查过：没有指向设置页名的（「接着上次没存完的填」「丢掉」「去改 / 去看 / 去改预算」「key 不对或没有权限」「地址不对，检查 Base URL」、Prefill 下那句）；代码里只认 `.api` 枚举。
- mac 定向复跑：APIDraftStoreTests 9、FixJumpTests 8、SettingsSearchTests 38、ParamErrorClassifierTests 18、ParamAutoAdaptRouterTests 17、InspectorRealPathTests 20、PromptRealPathGoldenTests 7、MainThreadIOBudgetTests 3（共 120，0 失败，都 grep 到 passed）；BudgetGateTests 单跑 38 全过。
- 模拟器自检：`device-lease acquire sim` 被闸拒（exit 75，「工位暂停模拟器 / 设备装包（粟粟 10-02）……验 UI 等合进 master 后由 Warden 统一装 sim」），没绕。自检步骤（新建 / 已有卡 / 丢掉）写进验收说明末尾，交 Warden 合完装 sim 时跑。

### astra 修复后验证

- mac / iOS `build-for-testing` 都 `** TEST BUILD SUCCEEDED **`；BudgetGateTests 单跑 38 全过。
- mac 定向：APIDraftStoreTests 16、FixJumpTests 9、SettingsSearchTests 38、ParamErrorClassifierTests 18、ParamAutoAdaptRouterTests 17、InspectorRealPathTests 20、PromptRealPathGoldenTests 7、MainThreadIOBudgetTests 3（共 128，0 失败）。
- 第 3、4、5、7、9、10 条是视图 / 生命周期逻辑，没写单测（要起界面），交模拟器自检。
- 已知：第 10 条的请求在输入条一直不回来时会挂着，下次输入条出现（哪怕换了对话）才弹选择器。

