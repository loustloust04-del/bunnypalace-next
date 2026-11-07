# 复盘 · 小芽新引导 P5 接通

> 2026-10-15 · 实现 agent ζ · 对应 [plan-onboarding-xiaoya-impl](plan-onboarding-xiaoya-impl.md) §5 / §9「P5 接通」

## 做了什么（一句一项）

- `Services/Onboarding/FreshInstallProbe.swift`：`decide` 纯函数 + `runOnce`（键有值就不判）+ `PushGate`。
- 启动：`MemoryPalaceApp.init` 在卡库建好后调 `startOnboardingIfFresh`（iOS DEBUG/PERF 包里套 `LaunchTrace.measure("onboarding.probe")`）；`started` → 切小芽楼层 + `script.start()`。
- 首启种子：`ProfileManager.firstLaunchSeed(legacyCompleted:)`：旧键假只种 [小芽]，旧键真种 [小芽, 对话空间] 并写 `lastProfileId = default-workspace`。只读兜底仍是 `Profile.seedProfiles`。
- 推送：`PushAppDelegate` 启动请求条件改 `PushGate.requestsAtLaunch`。
- 删旧引导六个文件 + `ContentView` / `SettingsView` 两处 cover；`canResumeAPIDraft` 的「引导盖着不弹」改成 `xiaoyaV1 == started`。
- 设置「?」→ 新手引导：`script.replay()`（「再走一遍」分隔线 + 分流卡）→ 关设置 → 切小芽楼层；已在小芽楼层就发 `.xiaoyaRoomRequested` 翻回房间（这个通知现在 page0 也翻）。
- mac 技术线：`.tech` 在不能扫码的平台问「要把手机也连上这台 Mac 吗？」→ 要 = 一句指路到「设置 › 让手机连这台 Mac」（新节点 `techPhone`），不出扫码卡。
- 新消息来源 `.divider`：只画线，不进 wire、不算交接。
- 「我搬家啦」：剧本在走时第一次进房间不插。

## 1. 边界情况

- **判定只在 `onboarding.xiaoyaV1 == nil` 时跑**：升级用户第一次启动新版就写成 `upgraded`；之后无论数据怎么变都不再判。列表读坏那次不写，下次启动再判。
- **对话数读失败（`fetchCount` 抛）**：当作「不知道」，不判不写，下次再判。容器持续坏的机器永远不进引导——保守，可接受。
- **卡库读坏**：`CharacterCardManager` 读失败时 `cards` 为空，不会单独拦住判定；但还要同时满足楼层只有种子、零对话、没自建 key 才会判成新装，真实老用户不会三条全中。没给卡库加只读探测（需要动卡库管理器，收益太小）。
- **自动种的 API 卡**：plan 列了 4 个 id，实际还有只播一次的 `chatgpt-oauth`（`ProviderManager.ensureChatGPTOAuthCard`），不排除的话新装永远判成 upgraded，已加进白名单。
- **`started` 中途杀掉 App**：键保持 `started`，下次启动不再判，script.json 原地续（P4 的 resume）；当前楼层按 `lastProfileId` 回到小芽楼层。推送一直不请求直到收尾。
- **重走不写 `started`**：重走的人（走完过 / 老用户）推送照常、API 草稿恢复照常；重走途中放弃，`isActive` 一直为真（召回 chips 不出、输入框在存钥匙前锁着），直到她走完或再点一次重走。这和新装中途放弃同一个行为。
- **重走重置了 progress**：上一轮的园丁类型 / Ta / 钥匙状态都清掉；重走时 key 卡照出（可跳过），跳过后「关于你在帮的人」会写「还没配钥匙（引导里跳过了）」，即使设置里已经有卡——这是 P4 `aboutUser` 原有的口径问题，新装跳过后再去设置配卡也一样。
- **mac 没有「?」重走入口**：mac 设置页没有搜索胶囊 / 「?」，plan 只写了 iOS 那处；mac 只有 DEBUG「从头放一遍引导」。
- **跨平台续跑**：iPhone 上停在「有 Mac 吗」那张卡、备份恢复到 mac 再答，会按 mac 的「要连手机」分支走（选项 id 同为 yes/no），可接受。

## 2. 与下一模块交互的风险

- **启动时序**：判定依赖 `App.init` 早于 `PushAppDelegate.didFinishLaunching`（SwiftUI `App.main()` 先建 App 实例再跑 UIApplicationMain）；万一反过来，`upgraded` 但旧键假的老用户首启少请求一次推送，下次启动补上，不会多弹。
- **测试 / 种子启动参数**：`-onboardingCompletedV1 YES` 的新模拟器 → 种 [小芽, 对话空间]、落对话空间，`--kb-probe-seed` 等种子写进当前楼层（对话空间）不受影响。不带这个参数、在**全新**模拟器上跑的 UI 测试（`KeyboardB2RegressionUITests` / `KeyboardLatestVisibleUITests` 只带 `--kb-probe-seed`）会落在小芽楼层、种子写进小芽楼层——但以前全新机会被旧六页 cover 挡住，本来就跑不通，等于没变。
- **`AssistantEngine.shared` 初始化提前**：只在判成新装那一次的 `App.init` 里碰（读空 history.json），老用户冷启动路径上不多碰引擎；`canResumeAPIDraft` 只读一个 UserDefaults 键。
- **`App.init` 读 `@State providerManager`**：拿的是初始值（同一个实例），和 DEBUG 下 `StreamSmokeSeed` 一样的读法。
- **`.xiaoyaRoomRequested` 语义放宽**：以前只从 page2 翻回，现在 page0 也翻；目前只有 page2「小芽」app 和设置重走两个发送方。

## 3. 技术债务

- `APIDraft.onboardingSlot` / `onboardingStep`（`Models/APIDraftStore.swift`）现在没有写入方了；保留是因为老用户偏好里可能还躺着旧引导的草稿，`pendingResume` 靠它把那份草稿排除在「回到没存完的 API 卡」之外。下个版本可以连同一次性清理一起删。
- `onboardingUserName` 只剩 `CharacterFloorService` 读（旧引导写过的老数据），同上。
- iPad 宽屏、`StickerProbeUITests` 都没上模拟器跑（agent 不碰模拟器），只读代码确认路径没变，见最终回复。
- 说明书 `manual/facts/modules/xiaoya.md` 还没有（P2–P4 也没建），整个小芽模块的事实层留给车头一次收口。
- 冷启动只加了 `LaunchTrace` 打点，没跑 perf 测量台对比（判定在老用户路径上只是一次 UserDefaults 读；新装那次多一次 `fetchCount` + 引擎初始化）。
