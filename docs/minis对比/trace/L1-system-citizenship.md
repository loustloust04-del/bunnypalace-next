# L1 —— 系统公民身份：入口、快捷指令、扩展、深链

先读 `COMMON.md`（同目录），它是本批次的共用条款、产出格式硬契约和红线。本文件只写你这条 lane 独有的东西。

## 这条轴问什么

**一个 AI app 怎么活在 iOS 系统里，而不只是活在自己的窗口里。**

OM 在这条轴上投入很重：App Intents 全家、Share Extension、Widget、File Provider、自定义 URL scheme 并且**给它写了正式 spec**。
MP 目前基本是「打开 app 才存在」的形态，且正在往上架走。这条轴的结论直接影响「记忆花园」发版后是不是一个像样的 iOS 公民。

## OM 侧读什么（`src/ios/` 下）

- `Agent/Intents/` 13 个文件——AskMinisIntent / SendPromptIntent / FollowUpSessionIntent / OpenSessionIntent / QuickTaskIntent / RetryRunIntent / GetSessionStatusIntent / ListSessionsIntent / MinisShortcutsProvider / SessionEntity / UserMessageEntity / ModelSelectionEntity / ShortcutRunTracker。
  重点看：**AppEntity 怎么把「会话」暴露给系统**、快捷指令怎么在 app 没开的时候把活干完、`ShortcutRunTracker` 在追什么（提示：后台执行的可观测性）。
- `ShareExtension/`、`AgentWidget/`、`FileProvider/`——各自小，但要看清**它们和主 app 共享什么状态、怎么共享**（App Group？共享容器？）。FileProvider 尤其值得看：它把 agent 的工作区挂进「文件」app 意味着什么。
- `docs/specs/minis-url-scheme.md` —— 这是 OM 自己写的 URL scheme 规范，**整篇读**。它是「深链作为一等公民接口」的样板：不只是打开某页，而是可寻址的对象体系（README 提到 workspace 可用 `minis://workspace/` 寻址）。
- `Agent/Chat/MinisURLPathDecoding.swift`、`Agent/Chat/ChatURLBrokerage.swift` —— 深链解析和分发的落地。
- `Info.plist` / `Minis.entitlements` —— 声明面（URL types、App Group、后台模式、能力）。

## MP 侧对照坐标

自己去 grep 确认，不要信我的转述：
- MP 有没有 App Intents / Shortcuts 支持？（提示：`project.yml` 是构建真相源，`.xcodeproj` 由 xcodegen 生成且 gitignore，**不要读 .xcodeproj**，读 `project.yml` 看有没有 extension target）
- MP 有没有 Share Extension / Widget / File Provider target？
- MP 的深链现状：grep URL scheme 注册和处理路径。08-23 那批的 `reference-openminis.md` 里车头写过一句「MP 有 deep link 底子」——**那是未查证的转述，请你验证真假**，这正是本 lane 该收的账。
- MP 的通知链：`PushNotifications.swift` + APNs（MP 走 cc-bridge hub 推送）。对照 OM 的 `Agent/Background/`（AgentLiveActivityManager / BackgroundKeepAliveManager / CacheKeepAliveManager）——**Live Activity 是 MP 完全没碰过的面**，值得单独判断。

## 车头给的额外情报（你查不到的）

- MP 的产品形态里，**有一条 OM 没有的重资产**：cc-bridge——手机 app 通过 WebSocket 连本机 hub，能驱动本地 Claude Code / codex 的真实终端。所以「让 agent 干活」这件事 MP 走的是完全不同的路（借外部真机的算力，而不是在手机里塞 Linux）。
  → 判断 OM 的 Intents 时请带上这个上下文：MP 的快捷指令如果要做，它触发的可能是**桥那头的活**，不是本地活。这是机会也是复杂度。
- MP 正在准备 1.0.1 TestFlight 发版（当前挂起，等另一个功能落地）。所以「上架前该补的系统集成」优先级会被抬高。
- MP 是 macOS + iOS 共用源码，**未守卫的 macOS-only view 在 iOS 也会编译**（历史踩过）。任何 iOS-only extension 的建议要说清对 macOS 端的影响。

## 特别要回答的

1. OM 的 App Intents 设计里，**哪几个是「AI app 都该有」的通用形态**（值得 MP 原样借），哪几个是 OM 自己 agent 定位特有的（MP 不需要）？
2. Share Extension「分享任意东西进 app 让它处理」——MP 的对等物应该是什么？（MP 有导入对话、有文件库、有共读、有贴纸）
3. File Provider 对 MP 有没有意义？MP 有自己的文件库（app 内），OM 把工作区挂进「文件」app。**这里注意**：MP 有一条明确原则「app 自己的记忆/文件库永不借 CC 桥让本地 CC 读写，cc 是 cc，自己的文件是自己的文件」——File Provider 会不会撞这条原则？这是产品判断，你给分析，别替粟粟拍板。
4. URL scheme 该不该正式化成 spec？MP 的哪些对象值得可寻址？
