# research：新建 API 卡后聊天被切模型 / 删卡落到 otc-mock / iOS 弹「存储密码」

> 2026-10-15，只读调查（代码 + git 历史），基于 master `38928c319`。没编译、没跑、没碰模拟器 / 真机数据。
> 起因：Warden 在 iOS 模拟器验 API 草稿单时看到两件事（见下）。

---

## 问题 1：新卡「抢」当前对话的模型；删卡后落到 otc-mock

### 复现（Warden 描述）
1. 当前聊天显示「Claude Code」。
2. 新建并保存一张 API 卡（模型 `test-model`）→ 当前聊天变成 `test-model`。
3. 删掉这张测试卡 → 聊天落到「otc-mock」，不是回到 Claude Code。

### (a) 哪条代码改了模型

**链路只有一条：`APICredentialEditor.save → persist(adopt:) → ProviderManager.adoptNewModel` 改了全局 `selectedChatModel`，没改对话本身；对话因为没钉模型、跟着全局走，所以“看起来被切了”。**

1. `Views/APICredentialEditor.swift:1437` `let fresh = isHTTPCard && (isNew || providerChanged)`；新 HTTP 卡一律 `adopt = true`（拉模型成功走 `fetchThenPersist` → `persist(pm, adopt: true)` :1462；拉不到点「仍然保存」走 :1442 `persist(pm, adopt: fresh)`，`test-model` + `draft-test.invalid` 就是这条）。
2. `APICredentialEditor.swift:1521-1523`：`if adopt, let pick = ProviderManager.autoPickModel(...) { pm.adoptNewModel(pick) }`。
3. `Models/APIProvider.swift:805-811` `adoptNewModel`：
   ```swift
   let current = UserDefaults.standard.string(forKey: "selectedChatModel") ?? ""
   if current.isEmpty || !isModelUsable(id: current) {
       UserDefaults.standard.set(model.id, forKey: "selectedChatModel")
   }
   ```
   即「K3：主模型空着或**不能用**时才接管」。
4. 「不能用」的判定 `APIProvider.swift:766-791`：桥卡（Claude Code / Codex）在 iOS 上 `bridgeReachable = !CCBridgeEndpoints.configuredURLs(fallbackToLocal: false).isEmpty`（:785-791；`configuredURLs` 在 `Views/CCPairingViews.swift:62-70`，只认手动 override / 备用 / 扫码中继，不认回环）。**没扫码配对过的 iOS 设备上，Claude Code 一律算不能用。**
5. 对话怎么跟着变：`Models/Conversation.swift:62-64` `selectedModelId = ""` 表示「没单独选过，回退全局」；聊天胶囊 / 发送都取 `CardFlowView.swift:1805-1809` `resolveModel(conversationModelId: conv.selectedModelId, globalFallbackId: selectedModelId /* @AppStorage selectedChatModel */)`（Page2 聊天 `Page2ChatWebView.swift:499-502 / 627-630 / 648-652` 同口径）。对话只有在**发过消息或手动点过选择器**时才钉住自己的 id（`CardFlowView.swift:1682 / 1770 / 2114 / 2137 / 2185`）。
6. `resolveModel`（`APIProvider.swift:847-851`）**不看能不能用**，所以胶囊上一直显示「Claude Code」，哪怕 K2 判它不能用、选择器里根本不列它（`favoritesByCredential` :1029-1040 过滤 `isUsable`）。

**推断 Warden 现场的状态（未查证，见文末）**：那个对话没钉模型（新对话 / 没发过）+ 全局 `selectedChatModel = cc-bridge/cc-local` + 模拟器没设 `ccBridgeBaseURLOverride` / 中继 → `isModelUsable("cc-bridge/cc-local") == false` → K3 认为「主模型不能用」→ 新卡接管全局 → 跟随全局的对话变成 `test-model`。

> 注意一个**模拟器专属误判**：iOS 模拟器和宿主 Mac 共享网络栈，`ws://127.0.0.1:7890/cc`（`APIProvider.swift:399-404`）在模拟器上**真的连得到 Mac 上的 hub**；但 `bridgeReachable` 只按「配没配对」判，模拟器上 Claude Code 实际能聊却被判不能用。真机 iOS 上「回环＝手机自己」的前提才成立。

其他写 `selectedChatModel` 的地方都排除了：
- `OnboardingFlowView.swift:276 / 966`：只在旧引导里，无条件写（首次配置，合理；旧引导将被小芽引导替换）。
- `ProxyCardInstaller.swift:166-170`：只在主模型为空或解析不到时写，不看「能不能用」。
- `APICredentialEditor.swift:2007`：模型行「设为主模型」按钮，用户显式点的。
- `ProviderManager.useCredential`（:1045-1061）：全仓无调用方（旧的死代码，不动）。
- `MemoryPalaceApp.swift:1324` / `APIProvider.swift:1437 / 1551`：卡 id 迁移时重写前缀，不改选择。
- 没有任何地方监听卡表变化去改对话的 `selectedModelId`。

### (b) 老行为还是新引入

**新的，#092（API 第一波，10-14）引入，不是草稿单引入的。**

| 行为 | 引入提交 | 之前 |
|---|---|---|
| 新卡保存后可能接管全局主模型（`adoptNewModel`，K3） | `d82694f03`（模型层）+ `ebc10d3bd`（编辑器 `persist(adopt:)`），均 2026-10-14 | 保存新卡只收藏（`ebc10d3bd^` 的 APICredentialEditor 里 `selectedChatModel` 只在模型行「设为主模型」按钮处写），**从不动全局** |
| iOS 未配对桥卡算「不能用」（`isUsable` / `bridgeReachable`，K2） | `d82694f03` | 无此概念 |
| 兜底顺序：能用的网络卡 → 本机 → 能用的桥卡（`fallbackModel`） | `d82694f03` | `availableModels.first`（启用卡表顺序第一个，不看能不能用）——`d82694f03^:APIProvider.swift:755` |

- K3 是粟粟 10-14 拍的（`docs/plan-api-wave1.md:18-20`「只有当前主模型（🌞）是空的或不能用时才把新卡第一个模型设成主模型；已经有能用的主模型就只收藏、不抢」）。plan 当时的假设是「你的对话都有显式模型，基本走不到兜底」（:80）——对**没钉模型的对话**（新对话）这个假设不成立。
- 草稿单 `dfc523a70..57af15f4a`：diff 里没有任何 `adopt` / `selectedChatModel` / `resolveStale` / `forgetModels` 改动（`git diff dfc523a70^ 57af15f4a` grep 为空），只是让 `persist` 多了清草稿（`APICredentialEditor.swift:1525-1526`）和 `removeCredential` 清草稿（`APIProvider.swift:1093`）。
- #093（工具抽屉）、#094、thinking 回传：blame 这些行都不是它们的提交。
- `resolveStaleSelectedModel`（`APIProvider.swift:870-876`）是 2026-04 的老代码（`614afe4d8`），清空逻辑本身没变。

### (c) 删卡时兜底怎么选的、为什么是 otc-mock

1. 详情页删卡 `APICredentialEditor.swift:1585-1591`：`removeCredential(id:)`（`APIProvider.swift:1089-1095`，删卡 + 钥匙串 + 草稿）→ `resolveStaleSelectedModel()`（:870-876）：全局 `selectedChatModel` 指向的模型已不存在 → **清成 ""**。列表左滑 `APISettingsTab.swift:72-73` 同一对调用。
2. 对话 `selectedModelId` 若是 ""（或钉的是 `cred-xxx/test-model`，已解析不到）→ `resolveModel` 第三级 `fallbackModel`（:855-866）：只在 `isUsable` 的卡里挑，类型排序 网络卡(0) < 本机(1) < 桥卡(2)，同级按卡表顺序。
3. **之前的 Claude Code 没人记得**：`adoptNewModel` 直接覆盖全局，旧值没存；删卡只会清空，不会“退回上一个”。于是落到第一张能用的网络卡。
4. **otc-mock 是什么**：不是种子卡。代码里没有 `otc-mock` 字样（`StreamSmokeSeed` 是 `stream-smoke-mock/mock-model`，`ChatSampleSeed` 是 `chat-sample-mock/sample`）。它是 10-01 输出上限单（OTC = output token cap）在这台模拟器上**手工建的 OpenAI 兼容测试卡「OTC Mock」**，指向本机 mock `127.0.0.1:18765`（`docs/plan-output-token-cap.md:317`、`docs/review-output-token-cap.md:67`、`docs/review-study-zero-engine.md:62`）。它有 key → 能用 → rank 0，在没配对的模拟器上 Claude Code 又是不能用 → 兜底就是它。即使 Claude Code 算能用，它也排在网络卡后面（rank 2），照样是 otc-mock。

### (d) 应有行为 + 最小修法

**目标**
- 新卡**不改变已有对话正在用的模型**；只有「这是第一张能用的卡」（之前根本发不出请求）或用户显式点了「设为主模型」/选择器时才设主模型。
- 删掉当前主模型所在的卡 → 回到**接管前的那个选择**（若还在），而不是卡表里第一张能用的 mock。

**修法 1（核心，改 K3 条件）**：`adoptNewModel` 的接管条件从「主模型空 / 不能用」收窄为「**这次保存之前没有任何能用的卡**」。
- `persist` 在 `pm.addCredential(cred)` **之前**算 `let hadUsable = pm.credentials.contains { pm.isUsable($0) }`，传给 `adoptNewModel(pick, hadUsableCard: hadUsable)`。
- 规则：`current.isEmpty && !hadUsable` → 接管；`!isModelUsable(current) && !hadUsable` → 接管；其余只收藏。
- 抽成纯函数 `static func shouldAdopt(currentEmpty: Bool, currentUsable: Bool, hadUsableCard: Bool) -> Bool`，方便测（项目惯例：`ModelUsabilityTests` 不 new `ProviderManager`，因为它的 init 写真 `UserDefaults.standard`）。
- 这改的是粟粟拍过的 K3 措辞（「不能用时也接管」），**要她点头**。她自己的 iOS 配过对，这条对她日常无感；影响的是新用户「主模型是没配对的 Claude Code + 已经有别的能用卡」这种组合——新逻辑下不接管，靠兜底 `fallbackModel` 已经能挑到能用的网络卡发出去（#092 D 本来就为这个）。

**修法 2（删卡退回上一个）**：`adoptNewModel` 真接管时，把旧值存进 `selectedChatModelBeforeAdopt`（UserDefaults）；`resolveStaleSelectedModel` 清空前，若这个旧值还能解析到模型 → 恢复它并删掉记录，否则才清空。
- 抽纯函数 `static func staleReplacement(current: String, previous: String?, resolvable: (String) -> Bool) -> String?`（返回 nil = 不动；"" = 清空；其它 = 恢复成它）。
- 修法 1 落地后接管变少，但 onboarding 外「第一张能用的卡」仍会接管（比如之前只有没配对的 Claude Code），删掉它时就该回 Claude Code。

**修法 3（模拟器误判，可选，独立）**：`bridgeReachable`（`APIProvider.swift:785-791`）在 `#if targetEnvironment(simulator)` 下返回 `true`（模拟器回环 = 宿主 Mac hub，和 mac 同理）。不改真机行为；能让 Warden / 各工位在模拟器上看到的「能不能用」和 mac 一致，也是本次现场被 K3 误伤的直接诱因。
- 风险：模拟器上没起 hub 时 Claude Code 也算能用（mac 上同样如此，`docs/review-api-wave1.md:12` 已接受）。

**不建议**：保存新卡时把「当前选中对话」顺手钉住旧模型——只能救当前那一个对话，其它没钉的对话照样漂，而且是跨模块偷写对话。

**测试**
- `ModelUsabilityTests` 加：
  - `testAdoptOnlyWhenNoUsableCardBefore`：`(currentEmpty: true, currentUsable: false, hadUsable: false) → true`；`(false, false, false) → true`；`(true, false, true) → false`；`(false, false, true) → false`；`(false, true, true) → false`。
  - `testStaleSelectedRestoresPrevious`：current 不可解析 + previous 可解析 → previous；previous 也不可解析 → ""；current 可解析 → nil（不动）；current 为空 → nil。
  - （修法 3）`isUsable(.ccBridge, bridge: …)` 的静态签名不变，`bridgeReachable` 是 `#if` 分支，单测测不到，靠模拟器手验。
- 手验（sim，用 Warden 的步骤）：全局 = Claude Code、对话没钉 → 新建 `test-model` 卡保存 → 胶囊仍是 Claude Code、选择器收藏里多了 test-model；删卡 → 仍是 Claude Code。再造「只有一张没配对的桥卡」场景 → 新卡接管 → 删卡回 Claude Code。

---

## 问题 2：iOS 在 API key 输入框弹「存储密码？」

### 字段在哪
| 位置 | 字段 | 现状 |
|---|---|---|
| `Views/APICredentialEditor.swift:740-756` keySection | 显示时 `TextField("sk-...")`，隐藏时 `SecureField("sk-...", text: $apiKey)` :750 | 只有 `.autocorrectionDisabled` + `.textInputAutocapitalization(.never)`，**没有 `textContentType`** |
| `APICredentialEditor.swift:1210` Claude Code「Hub Token」 | `SecureField("LAN 模式必填，loopback 留空", text: $apiKey)` | 同上 |
| `Views/Onboarding/OnboardingFlowView.swift:684` 接 API 页 | `SecureField("sk-...", text: $keyText)` | `.autocapitalization(.none)` + `.disableAutocorrection(true)`，无 `textContentType` |

同屏还有 Base URL / 名称等 `TextField`（`APICredentialEditor.swift:521`、`OnboardingFlowView.swift:672`），系统启发式会把「普通文本框 + 安全文本框」认成登录表单（用户名 + 密码），页面消失 / 提交时弹 Passwords 的「存储密码？」。

### Apple 文档怎么说（xcdocs）
- 「Enabling Password AutoFill on a text input view」（`/documentation/Security/enabling-password-autofill-on-a-text-input-view`）：Password AutoFill 靠 `textContentType` + 启发式识别登录流程；显式设 `textContentType` 会覆盖启发式。可用值 `.username` / `.password` / `.newPassword` / `.oneTimeCode`。
- `ASSavePasswordRequest.Event.formDidDisappear`：表单提交或从屏幕移除时触发保存事件——对应「点保存、页面 dismiss 那一下」弹窗。
- 文档没有「禁用存密码」的官方开关；业界通用做法是把非登录用途的安全框标成 `.oneTimeCode`，系统不再把它当密码，不进 Passwords 保存流程。

### 仓内先例（最强证据）
`ef9de2eec`（10-09）给加密询问卡的两处 `SecureField` 加了 `.textContentType(.oneTimeCode)`（`Views/Cards/AskCardView.swift:304 / 428`），同一问题——「iOS 不再把弹单当登录表单弹存储密码」；`StickerProbeUITests/SecureAskUITests.swift` 加了 `assertNoSavePasswordPrompt`（在 app 和 springboard 里找 `Save Password / 存储密码 / 储存密码 / Not Now`），两个用例 passed；`docs/review-secure-ask-sheet.md` 记录：「`.password` / `.newPassword` 反而触发密码 App」，iOS + mac 都编过（这个修饰符在共用源码里没加平台守卫也能编）。

### 选项对比
| 方案 | 效果 | 代价 |
|---|---|---|
| **`.textContentType(.oneTimeCode)`**（推荐） | 不弹存储密码；保留 `SecureField` 的遮挡、禁复制、录屏遮罩 | QuickType 栏可能出现短信验证码建议（只在收到验证码短信时，无害）；和仓内 AskCard 同一做法 |
| `.textContentType(nil)` / 不设 | 等于现状，`SecureField`（`isSecureTextEntry`）本身就是启发式触发条件 | 无效 |
| `.password` / `.newPassword` | 明确告诉系统「这是密码」，**更会**弹 / 还会建议强密码 | 反效果（仓内已验） |
| 改 `TextField` + 自己打码 | 不弹 | 丢掉安全输入的系统保护，key 进键盘学习 / 截屏可见；不值 |
| 显示态的 `TextField`（:741） | 普通 `TextField`，不触发 | 可顺手也标 `.oneTimeCode` 保持一致，非必须 |

---

## 建议修法（每条可单独 revert）

- [x] **F1**（问题 2）`APICredentialEditor.swift:750` 的 `SecureField("sk-...")` 加 `.textContentType(.oneTimeCode)`；`:741` 显示态 `TextField` 同步加（可选）。
- [x] **F2**（问题 2）`APICredentialEditor.swift:1210` Hub Token `SecureField` 加 `.textContentType(.oneTimeCode)`。
- [x] **F3**（问题 2）`OnboardingFlowView.swift:684` `SecureField` 加 `.textContentType(.oneTimeCode)`（旧引导要被小芽引导替换；新引导里的 key 框同样要带上，写进小芽引导 plan 的禁区 / 验收）。
- [ ] **F4**（问题 2，验证）`StickerProbeUITests` 加一个用例：设置 → 模型和API → 新建卡 → 填 Base URL + key → 「仍然保存」→ 复用 `assertNoSavePasswordPrompt` 断言不弹。
- [x] **F5**（问题 1 核心，粟粟 10-15 选 A）`adoptNewModel` 改成「保存前没有任何能用的卡才接管」：`persist` 在 `addCredential` 前算 `hadUsable` 传入；抽 `static shouldAdopt(...)` + `ModelUsabilityTests.testAdoptOnlyWhenNoUsableCardBefore`。
- [x] **F6**（问题 1）接管时记 `selectedChatModelBeforeAdopt`；`resolveStaleSelectedModel` 清空前先尝试恢复它；抽 `static staleReplacement(...)` + `testStaleSelectedRestoresPrevious`。
- [ ] **F7**（问题 1，可选；**本单不做**，#00463 另一 session 已交，同一行 `|| targetEnvironment(simulator)`）`bridgeReachable` 在 `targetEnvironment(simulator)` 下返回 `true`。只影响模拟器。
- [ ] **F8**（文案，可选）`APICredential.deleteWarning`（`APIProvider.swift`，「用它的模型的对话会改用别的模型」）在 F6 后可补「会回到之前的主模型」——只有 F6 合了才改。

## 已修（10-15，backend-2）

| 项 | 改了什么 | 证据 |
|---|---|---|
| F5 | `adoptNewModel(_:hadUsableCard:)`：只有「这次保存前别的卡里一张能用的都没有」且主模型空 / 不能用才接管；`persist` 在 `addCredential` 前算 `hadUsableCard`，**排除正在保存的这张卡自己**（换了家的卡如果是唯一能用的卡，换完仍可接管）。纯函数 `ProviderManager.shouldAdopt(currentEmpty:currentUsable:hadUsableCard:)` | `ModelUsabilityTests.testAdoptOnlyWhenNoUsableCardBefore` / `testReachableBridgeCardBlocksAdoption` |
| F6 | 接管栈 `selectedChatModelAdoptionStack`（UserDefaults 数组，每层 `cardId / adopted / previous`，最多 5 层，`forgetModels` 不碰它）。接管时 `pushAdoption`：同一张卡再接管（主模型被清空或还指着它那层的模型）→ 只换 `adopted`、保留原退回目标；否则主模型非空就压新层。`resolveStaleSelectedModel` → `staleReplacement(current:stack:resolvable:)`：只弹「接管成当前主模型」的那层，退回目标还在就恢复，也失效且它自己是接管来的就顺着下一层继续退，都不行清空；下层原样留着 | `testStaleSelectedRestoresPrevious` / `testSameCardReadoptKeepsOriginalFallback` / `testChainedAdoptionRestoresLayerByLayer` / `testAdoptionStackCapped` |
| F1–F3 | 三个 `SecureField` 加 `.textContentType(.oneTimeCode)`（API Key、Hub Token、旧引导 key 框），照 `ef9de2eec` AskCard 先例，不加平台守卫；显示态 `TextField` 没动 | mac + iOS build-for-testing |

**复盘**
- astra 两条 P2 已修（同卡换家再接管丢退回目标；A→B→C 连续接管覆盖下层记录）→ 两把键改成上面的接管栈，提交前的两把旧键（`selectedChatModelAdopted` / `selectedChatModelBeforeAdopt`）只在本工位当天出现过，没做迁移。
- 边界：① 记录只认「接管的那个」，用户后来手动换过主模型再删卡，不会被拉回旧值（`adopted != current` → 不恢复）；但用户手动又选回接管的那个模型再删卡，仍会退回接管前的值（可接受）。② 卡里删掉某个模型走 `forgetModels`，直接清空主模型，**不走** F6 的恢复（只覆盖删整张卡 / 启动清理两条 `resolveStaleSelectedModel` 路径）。③ 旧值为空时不记录（同卡再接管除外），删卡照旧清空走兜底。④ 栈只有 5 层，超出丢最底层；手动换走主模型后留下的过期层不主动清，靠上限挤掉。
- 与其它模块：F7 由 #00463 落地后，模拟器上未配对的 Claude Code 也算能用 → 模拟器上新卡基本不再接管；本单 `bridgeReachable` 一行没动，合并无冲突。小芽新引导的 key 框也要带 `.oneTimeCode`（F3 只改了旧引导）。
- 技术债：`adoptNewModel` / `resolveStaleSelectedModel` 本身仍没单测（`ProviderManager` init 写真 `UserDefaults.standard`），只测纯函数 + 编辑器口径；F4（UI 测试断言不弹「存储密码」）没做，要模拟器跑 `StickerProbeUITests`；F8 文案未改；胶囊显示不看能不能用的老问题未改。

## 未查证

- **`.oneTimeCode` 的副作用**（astra 10-15）：iOS 收到短信验证码时 QuickType 栏可能在 key 框上方出验证码建议；macOS 26 起 Messages / Mail 收到验证码时也可能在光标旁出自动填充菜单（Apple 文档 `NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac`）。粘贴整段 key 是否正常、三个页面是否完全不再弹「存储密码？」，都要真机 / 模拟器验。

- **Warden 那台模拟器的实际状态**：没读模拟器 app 数据（按约束）。推断依赖三点：①那个对话 `selectedModelId == ""`；②全局 `selectedChatModel == "cc-bridge/cc-local"`；③`ccBridgeBaseURLOverride` / `ccBridgeBaseURLBackup` / 中继键都为空（所以 Claude Code 被判不能用）。Warden 可以自己 `xcrun simctl spawn <udid> defaults read com.susu.MemoryPalace.ios ccBridgeBaseURLOverride` 之类核一下（bundle id 带 `.ios`）。**若③不成立（模拟器配过对）**，`adoptNewModel` 不会接管，就还有别的路径没找到——需要再查。
- otc-mock 的确切卡 id / 名字（文档里写「OTC Mock 卡」，id 是 `cred-<UUID>` 还是别的没核）；不影响结论。
- F5 之后「主模型是没配对的 Claude Code、已有别的能用卡」的新用户：新卡不接管，第一句走 `fallbackModel` 能发出去，但胶囊仍显示「Claude Code」（`resolveModel` 不看能不能用，老问题，本次不改）。是否要让胶囊显示实际会用的兜底模型，留给粟粟定。
- 「其它 app 怎么做」：只有仓内 AskCard 先例和 Apple 文档；没逐个拆第三方 app 核实，`.oneTimeCode` 是社区常见做法这一点未独立查证。
- `.oneTimeCode` 在 iOS 26 上是否仍完全抑制保存提示：仓内 10-09 的 UI 测试是在 iOS 26 模拟器上过的（推断，未回看当时的 destination）；真机未验。
- 其它带 `SecureField` 的 key 输入（`WebSearchProviderEditSheet.swift:48`、`UsageReconciliationSection.swift:54`、`Settings/VoiceServicesPage.swift:255`、`SettingsView.swift:877`、`ConfigPage.swift:58/60/132` 导出口令）大概率同样会弹；本次没在模拟器上验，也没列进修法（范围外，粟粟要的话按 F1 同法补）。
