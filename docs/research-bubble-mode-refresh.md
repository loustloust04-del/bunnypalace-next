# research：气泡模式按参考稿「稍微改」（bubble-mode.html 对照）

> 2026-10-16 · zone/page1 @ `04feebbe0` · 只读调研，未改代码 / 未编译
> 参考稿：`~/Downloads/bubble-mode.html`（12 条「原来 / 现在」+「搬进 SwiftUI 的参数」表）
> 范围补充（粟粟经车头转达）：① 去掉「显示头像 / 显示昵称」开关，气泡模式固定不显示，群聊照旧显示昵称；② 本次只做「好看」（视觉参数 + 排版），陪伴感 / 左滑时间 / 手绘云归 C；③ 弹泡暂时关掉（保留代码）。
> 「未查证」= 读码推断、没有实测，执行前要验。

## 0. 结论先行

- 最大的视觉差距是**气泡太胖 + 行距太松**：内边距 18/15（参考 13/7），单行气泡高约 49pt（参考约 37pt）；消息之间统一 31pt（参考组间 14）。这几个都是常量，改动小。
- 「头像只在顶栏一次」「思考行收成一句摘要、点开看全文」「顶栏下渐隐 + 模糊」「尾巴只在最后一个泡」**iOS 已经有了**，差的是细节对齐。
- 坑：气泡模式的几个常量和设置键**群聊在共用**（`fixedPaddingH/V`、`bubbleModeCornerRadius`），`bubbleSpacing` / `hideRoleName` / `hideTimestamp` / `ChatTimeDivider.gap` **文章模式在共用**。要只改气泡模式，必须先拆开。
- 弹泡**没有总开关**，四个入口（`markPop`、CC 入场 A/B、`popTransition`）。最小关法：在 `BubblePopTuning` 加一个 `enabled` 开关，四处读它。

## 1. 渲染路径

| 层 | 位置 | 说明 |
|---|---|---|
| 列表 | `CardFlowView.swift:845` `LazyVStack(spacing: bubbleSpacing)`，反转列表 + `.flippedUpsideDown()` | 两种模式共用；`:888` 时间分割线插在行顶；`:931` `.padding(.horizontal, metrics.listInsetH)` |
| 行分流 | `CardFlowView.swift:4146-4187` `innerBody`：`chatBubbleMode` → `BubbleModeRow`，否则 `articleModeBody` | 气泡模式的外观值在 `:4161-4166` 传入（固定常量，不吃「气泡外观」滑条） |
| 单条 | `ChatBubbleStyle.swift:212` `BubbleModeRow`：头像 + header + 附件 + `bubbleStack` + 召回卡 + 分页器 + 用量 | `:381` 块级 VStack（spacing 4）；`:662` `singleBubble` 画底；`:18` `BubbleTailShape` |
| 正文 | 用户：`ChatBubbleStyle.swift:605` SwiftUI `Text`；AI：`:620` `ChatMarkdownView` → fork 渲染器（`MarkdownConfig.swift:41`） | 两套行距来源不同（见 §2 第 3 行） |
| 思考 | `ChatBubbleStyle.swift:729` `ThinkingBubble` → `ThinkingSheet.swift:6` `ThinkingDisclosure`（一行摘要，点开原地展开或弹 sheet） | |
| 回应 | `ChatReactions.swift:176` `.chatReactionBadge` 挂在整个 `bubbleStack` 上（`ChatBubbleStyle.swift:279/286`） | |
| 边缘 | iOS：`CardFlowView.swift:999` `ChatEdgeFadeMask`（顶 130pt smoothstep 渐隐）+ `:958` `ChatContentEdgeBlur`（顶部渐进模糊，`ChatContentEdgeBlur.swift:145/154`） | mac 没有这两层（都是 `#if os(iOS)`） |

- **iOS / mac 共用** `BubbleModeRow`；mac 只多一层排版覆盖（`ChatBubbleStyle.swift:295-301` 注入 `chatSpacingOverride`）。差异只在 `ChatMetrics`：列表左右内距 iOS 16 / mac 28（`Chat/ChatMetrics.swift:40/52`）。
- **UIKit 新聊天页**：`Views/Spike/UIKitChatSpike.swift` 只在 `DEBUG || PERF_BENCH` 并且设了 `MP_SPIKE_UIKIT` / Debug 开关时挂载（`ContentView.swift:1803`）；cell 模式 a/m 用 `UIHostingConfiguration` 包现有 `BubbleView`，会自动跟着变；b/c 原生 cell 不跟。**不在关键路径**，这次不用管。
- **群聊**（`GroupRoom/GroupRoomCells.swift`）是另一套 UIKit 手算布局，但**借用了气泡模式的常量**：`:17-18` `paddingH/V = BubbleModeRow.fixedPaddingH/V`，`:38-40` 圆角读 `bubbleModeCornerRadius`，`:128` 行距读 `fixedLineSpacing`。粟粟要群聊保持不动，所以先把这几个值在群聊里写死（18 / 15 / 23 / 1.45）。

## 2. 参数表对照

| 参考参数 | 我们现在（证据） | 差距 | 成本 | 风险 |
|---|---|---|---|---|
| 屏边到气泡 14 | iOS 16 / mac 28（`ChatMetrics.swift:40/52`），两种模式共用 | 2pt | S | 改 `listInsetH` 会带动文章模式、多选勾选圆 `ChatSelectionRow.swift:9`、Spike；建议只对气泡模式做 `chatBubbleMode ? 14 : listInsetH` |
| 内边距 上下 7 / 左右 13 | `fixedPaddingV = 15`、`fixedPaddingH = 18`（`ChatBubbleStyle.swift:270-271`） | 上下差 8，左右差 5 | S | **群聊共用**（先拆）；`CCWaitingBubbleRow` `:201-202` 跟着变（是好事）；召回卡 `:287` 写死 18，要改成跟 paddingH；思考球 34pt 高（`:164`）在 7pt 内边距下等待泡会比文字泡高（未查证观感） |
| 正文 16 / 行高 1.42 | 字号 13.5 × `fontScale`(默认 1.2) = **16.2**（`MarkdownConfig.swift:48`、`FontManager.swift:204`）。行距：用户 `Text` 加 `4×fontScale×1.45 ≈ 6.96pt`（`ChatBubbleStyle.swift:609`）；AI 在 iOS 是 fork 写死 **5pt**（`MarkdownConfig.swift:15`），mac 由 `fixedLineSpacing` 换算还是 5 | 字号基本一致。行高按 SF 16.2pt 自然行高约 19.3 估：AI ≈ 24.3（1.5×），用户 ≈ 26.3（1.62×），**两边还不一样**。参考 22.7（1.42×）。中文 PingFang 自然行高另算（未查证，要实测） | 用户 S；AI M | AI 侧在 iOS 要改 fork 的写死值或加参数，会带动文章模式和缓存键（`ChatMarkdownView.swift:180-195`）；群聊 `:128` 读 `fixedLineSpacing` |
| 圆角 19 / 带尾巴的角 6 | `bubbleModeCornerRadius` 默认 **23**（`CardFlowView.swift:3814`，设置滑条 14–34，`AppearanceSettingsTab.swift:718`）；尾巴是粟粟 pao.svg 的脚丫，尺寸 = 圆角 × 1.38（`ChatBubbleStyle.swift:30-78`），带尾巴的角**不收小** | 圆角 4；尾巴的角形状不一样 | 圆角 S；尾巴的角 M | 只改默认值时，**她已经拖过滑条就不会变**（她存的值未查证，`defaults read` 一下）；**群聊读同一个键**；`CCWaitingBubbleRow` `:204` 写死 23；尾巴的角 6 等于重画尾巴（推翻粟粟已认可的 pao.svg，要她点头），`GroupRoomUIKitTests.swift:15` 比对 SwiftUI 和 UIKit 路径（共用同一个 Shape，改了两边一起变） |
| 同组 2 / 组间 14 | 同一条消息里的分泡 **4**（`ChatBubbleStyle.swift:381`）；消息之间 `bubbleSpacing` **31**（`CardFlowView.swift:459/845`），这个键在设置里标的是「文章模式」（`AppearanceSettingsTab.swift:712`），实际两种模式共用；AI 行内 VStack 还有 8（`ChatBubbleStyle.swift:283`） | 4→2；31→14 | S | 改成按模式取值即可；时间分割线 `:888` 和多选行 `selectionRow` `:612` 也读 `bubbleSpacing`，要一起传；perf 账本 `perfNoteApplied` 记 spacing（`:513`），基线会变 |
| 尾巴只在每组最后一个 | 已做：同一条消息里只有末块带尾巴（`ChatBubbleStyle.swift:441`）；**跨消息**（同一个人连发两条）每条都有尾巴 | 跨消息分组没有 | M | 要知道下一条是谁发的，见 §5 性能 |
| 最大宽度 76% | 没有百分比；对侧 `Spacer(minLength: 40)`（`:278/291`）+ 头像 32+8（`:253-254`）。393 宽 iPhone：有头像约 281（71%），没头像约 321（82%） | 关掉头像后会变宽到 82% | S | 最小改法：把 40 调到约 62（393 宽时 ≈ 76%）；真按百分比要拿宽度，别每行挂 GeometryReader（§5）；群聊已经是 `min(listWidth*0.76, 540)`（`GroupRoomCells.swift:47`） |
| 时间分割 > 15 分钟 | `ChatTimeDivider.gap = 3 * 3600`（`ChatTimeDivider.swift:7`），文章模式 / UIKit 页共用；`hideTimestamp` 关掉整个分割线（`CardFlowView.swift:884`） | 3 小时 → 15 分钟 | S | 文章模式也会跟着变密（要按模式分就加参数）；`ChatTimeDividerCacheTests` 是和直算结果比对，不依赖 gap |
| 已读 0.45s / 泡间 0.38s / 打字时长 / 云沸腾 | 没有已读；CC 入场节奏 `entranceDelay`（`ChatBubbleStyle.swift:692`，0.15+0.004×字，夹 0.18–0.7） | 整套节奏 | L | C 档；而且和「弹泡关掉」方向相反 |

## 3. 12 条逐条对照

| # | 参考稿 | 我们现在（证据） | 差距 | 成本 | 风险 |
|---|---|---|---|---|---|
| 01 | 头像只在顶栏一次；头像 / 昵称 / 时间默认关 | `showAvatar` 默认 **true**、`hideRoleName` 默认 false（`CardFlowView.swift:3810/3813`）；气泡模式顶栏中间已经是头像（`ContentView.swift:1592` 注释「气泡模式中间是头像层」）；每条消息的时间已经不显示，改成了 3 小时分割线 + 长按菜单底部（`ChatBubbleStyle.swift:338`） | 按粟粟新口径：**删开关，气泡模式固定不显示头像 / 昵称** | S–M | 见 §4：`hideRoleName` / `hideTimestamp` 文章模式和 Code 详情页也在读 |
| 02 | 左边只剩一条线（气泡离屏边 14） | 头像关掉、昵称关掉之后还剩三条：气泡边、思考图标（底 +12，`:737`）、正文（+18）。思考摘要文字在 +12+图标+10 | 剩思考行没对齐 | S | 把 `ThinkingBubble` 左右内边距改成跟气泡一样（13），图标和正文起点对齐 |
| 03 | 气泡太胖：上下 7 / 左右 13 / 行高 1.42 | 15 / 18 / 约 1.5–1.62（见 §2） | 见 §2 | S（AI 行距 M） | 见 §2 |
| 04 | 同组 2、组间 14、尾巴只长在每组最后一个，那个角收成 6 | 4 / 31；同一条消息内已做；跨消息没做；角不收 | 见 §2 | 间距 S；跨消息分组 M；角 M | 见 §2 |
| 05 | 回应钉在被回应气泡的角上（用户左上 / AI 右上，叠住一点边），小圆颜色跟贴的人 | 已经挂在角上（`ChatReactions.swift:195-200`：上探 11、外探 13），但挂的是**整条消息的 VStack**：AI 有思考行时钉在思考行上，第一块比最宽块短时会悬在空中（= 参考稿说的「飘走」）；胶囊是白底 + 系统图标（`:143-154`），不是彩色圆 + emoji | 锚点和样式 | 锚点 M；样式 S | 只有她能贴回应（`ChatReactionStore` 是本机存储），「跟贴的人走」等于固定用户泡色；壁纸半透明泡上的观感未查证；改锚到某一块要动 `bubbleStack` 结构 |
| 06 | 思考行和气泡同一条线，想完收成摘要，点开看全文 | 已经是一行摘要 + ›，点开原地展开或弹 sheet（`ThinkingSheet.swift:36-89`）；气泡模式不传 `summary`，用的是原文第一句（`ChatBubbleStyle.swift:436`、`ThinkingSheet.swift:31-34`）；外层灰底圆角 12、内边距 12/8，加上内部上下 10（`:60`），单行约 50pt 高 | 对齐和高度 | S | 手绘云 6 版是 C |
| 07 | 顶栏下渐隐遮罩 + 模糊，不要硬切 | **iOS 已有**：顶部 130pt 渐隐（`ChatEdgeFadeMask.swift:32-38`）+ 渐进模糊（`ChatContentEdgeBlur.swift:145`，半径 = `blurRadius` 1.3 × 3）；mac 没有 | iOS 可能没有差距（参考稿截图哪个端、哪个版本，未查证）；mac 有没有硬切未查证 | — / mac M | 动这块会碰键盘几何（遮罩读输入条位置） |
| 08 | > 15 分钟才出居中时间；左滑看每条时间 | 3 小时居中分割线（`ChatTimeDivider.swift:7/109`）；左滑没有 | gap；左滑 | gap S；左滑 L | 左滑会和翻页 / 返回手势、长按浮层抢手势：C |
| 09 | 颜文字 ʕ…ʔ 不换行；`text-wrap: pretty` | 没有处理 | 有 | M | 往显示副本插 U+2060 会影响划线定位 / 收生词 / 复制 / 查找高亮（这些都按原文匹配）；`pretty` 在 SwiftUI `Text` 没有对应 API，UIKit `lineBreakStrategy` 是否等效未查证 |
| 10 | 已读、思考云冒出、三点、名牌状态 | 没有 | — | L | C 档（范围补充 ②） |
| 11 | 思考云 6 版（手绘抖动 SVG） | 思考球（`ThinkingOrbsKit`，`ChatBubbleStyle.swift:155-171`） | — | L | C 档 |
| 12 | 主题 = 背景 + 九宫格气泡框，装饰长在角上 | 主题只有颜色 token + 用户泡渐变（`Theme/UserBubbleFill.swift:12`） | — | L | C 档；会碰主题系统 / 主题库 |

## 4. 设置开关现状和「去掉」要动的地方

| 开关 | 键 / 默认 | 谁在读 | 去掉要动哪里 |
|---|---|---|---|
| 显示头像 | `@AppStorage("showAvatar")` = **true** | 只有气泡模式（`CardFlowView.swift:3813` → `ChatBubbleStyle.swift:280/282`） | ① `AppearanceSettingsTab.swift:288-293` 删 Toggle 和 `:41` 声明；② `Settings/SettingsSearch.swift:500-502` 删条目；③ `CardFlowView.swift:3813/4169` 不再传，`BubbleModeRow` 的头像分支和 `AvatarBox` 调用删掉或写死 false；④ `ConfigSchema.swift:50` 的键：**建议保留**（`ConfigEncryptedExportTests.swift:217-222` 拿它测导入，删了要改测试；旧导出文件里有这个键也不报错）；⑤ perf 配置 `PerfChatCore.swift:20`、`PerfChatV1Load.swift:1040` 留着无害 |
| 显示昵称 | `hideRoleName` = false（取反显示） | 气泡模式 header（`ChatBubbleStyle.swift:339-349`）、**文章模式** header（`CardFlowView.swift:4199`）、**Code 详情页**（`CodingSessionDetailView.swift:507/547`） | 气泡模式里写死不显示（header 只留用户侧的 StyleChip / CardEventsChip，`:346`）；删 Toggle（`AppearanceSettingsTab.swift:295-299`）和搜索条目（`SettingsSearch.swift:503-505`）。**要粟粟定**：开关删掉以后文章模式 / Code 详情页一直显示昵称（mac 上这个开关原本对文章模式常驻，`AppearanceSettingsTab.swift:18-24`） |
| 显示时间戳 | `hideTimestamp` = false | 现在管的是**时间分割线**（两种模式，`CardFlowView.swift:464/884`）+ Code 详情页 | 粟粟只点名头像 / 昵称。建议**保留**（它是分割线的唯一开关）；如果也要删，分割线就一直显示 |
| 群聊昵称 | 不读上面任何键：`showsName: !sameSpeaker`（`GroupRoom/AgoraRoomViewController.swift:258-267`） | — | **不共用开关，不用拆**；只需要拆 §1 说的 padding / 圆角 / 行距常量 |
| 气泡圆角 | `bubbleModeCornerRadius` = 23（滑条 14–34） | 气泡模式 + 群聊 + 长按浮层（`BubbleMenuOverlayView.swift:302` 用 session 的圆角） | 改默认值 + `resetPageToDefaults` `:816` 一起改；群聊改成读自己的值 |
| 气泡间距 | `bubbleSpacing` = 31（标「文章模式」） | 两种模式的列表、分割线、多选行、Spike | 气泡模式改用自己的常量 |
| 消息用量 | `showMessageUsage` = **true** | 气泡模式每条 AI 消息下面一行 10pt token 数（`ChatBubbleStyle.swift:311-330`） | 参考稿没有这行；要不要在气泡模式默认藏，交粟粟定（B） |

## 5. 测试和性能约束

**受影响的测试**（没有气泡模式的像素快照 / 金样：`PromptRealPathGoldenTests` 测的是提示词，`ChartSnapshotTests` 测的是图表）

| 测试 | 关系 |
|---|---|
| `GroupRoomUIKitTests.swift:15` | 比对 `BubbleTailShape(radius: 23)` 和 UIKit 路径；改尾巴形状两边一起变，应该照样过；拆群聊常量后再跑一遍 |
| `ChatTimeDividerCacheTests` | 和直算结果比对，改 gap 不影响 |
| `CCEntranceTests` / `BubbleStreamingBlocksTests` | 纯函数（`entranceDelay` / `entranceNodeIds` / `streamingBlocks`），弹泡开关挡在调用点就不影响 |
| `SettingsSearchTests` | 只查 id / anchor 唯一和格式，删条目不会挂 |
| `ConfigEncryptedExportTests.swift:217-222` | 用 `showAvatar` 测导入；`ConfigSchema` 留着这个键就不用动 |
| `ThemeBubbleGradientTests` | 渐变锚点；改 padding 不影响 |
| UI 回归 `scripts/ui/ui-regress.sh`（playbook §6.7） | 要补形态：气泡模式 × iPad 宽屏 / 深色 / 减弱动态 / 壁纸半透明 / 渐变泡 / mac |

**性能（`docs/playbook-perf.md` 相关）**

- **列表 body 里每行算邻居 = 雷**：playbook §5 的实例就是「时间分割线在列表 body 里每次 O(n) 读 createTime」。跨消息分组（2 / 14 间距、尾巴归最后一条）要知道上下一条是谁发的，必须照 `viewModel.timeDividerCache` 那样做一份缓存（路径变才重算），不能在 `ForEach` 里现算。
- **别每行挂 GeometryReader 量宽度**做 76%：行上已经有一个 GeometryReader 记位置（`CardFlowView.swift:905-914`）。用常量 minLength，或者沿用 `chatViewportHeight` 的做法在列表层量一次、用 environment 往下传。
- **行高变化**：padding / 间距 / 行距都会改所有行高。反转 LazyVStack 加上 `CellGrowthAnchor` / `StreamScrollAnchor` 补偿器都按真实高度工作，常量变化本身没风险；但 perf 基线（`scripts/perf/air-config.py` 照粟粟真实设置跑气泡模式）要重新量一次，不能和旧数字直接比。
- **AI 行距改 fork**：缓存键 `cacheDims` 在 iOS 不含行距（`ChatMarkdownView.swift:188-194`），改写死值会换掉所有渲染结果，LRU 里的旧块要靠 `fontName|scale` 之类的维度失效——改法要进缓存键，否则会新旧行距混在一起（未查证）。
- **回应锚到单块**：只有带回应的消息才挂 overlay，开销可以忽略；但别为了它给每块都包一层 `GeometryReader` / `anchorPreference`。
- **弹泡关掉**会让行插入和 CC 到达少一次动画事务（`CardFlowView.swift:896-903/927-930`），对性能只有好处。

## 6. 弹泡：现状和最小关法（范围补充 ③）

| 入口 | 位置 | 触发 |
|---|---|---|
| 发消息 / 重生成行内弹泡 | `ConversationViewModel.swift:69` `markPop` → `popNodeIds`；7 处调用（`:2056/3013/3045/4633/5013/5111/5151`）；列表 `CardFlowView.swift:896-903`（事务升级）、`:927-930`（旧行推移）；行内 `ChatBubbleStyle.swift:427/447` | 发送、重试、编辑 |
| CC 入场 场景 A | `ConversationViewModel.swift:357` `pendingEntranceNodeIds.insert` | 正看着对话时 CC 消息到达 |
| CC 入场 场景 B | `ConversationViewModel.swift:1078` | 打开有未读的对话，尾部最多 3 条 |
| 流式逐块弹入 | `ChatBubbleStyle.swift:447/455` 在 `showPartialDots` 时用 `popTransition`；`:476-478` 三个 `.animation(popAnimation)` | 气泡模式流式回复 |
| 调音台 | `BubblePopTunerView.swift:21`，挂在 Debug（`DebugSettingsTab.swift:126-128`） | 只调参数，没有开关 |

- **没有总开关**。最小关法（不删代码）：在 `BubblePopTuning` 加 `static let enabledKey = "popEnabled"`（默认 false）和 `static var enabled`；然后 ① `markPop` 开头 `guard BubblePopTuning.enabled`；② 场景 A / B 两处插入前同样 guard；③ `popTransition` 在关的时候返回 `.identity`（一处挡住流式弹入、入场、发消息三条路）；④ `bubbleStack` 的三个 `.animation(popAnimation)` 在关的时候给 nil，免得新块撑开 VStack 时其它泡还在弹簧位移；⑤ 调音台顶上加一个「启用弹泡」Toggle 写这个键，以后打开就在这里。约 6 处小改，S。
- **关掉以后对键盘 / 滚动跟随的影响**（读码推断，未实测）：
  - `KeyboardInsetBridge.swift:45` `sendDismissUntil`（发送时收键盘不走滑出动画）注释说是为了让弹泡独占舞台，但它真正修的是「发送大跳案」（新泡插入 + 键盘滑出动画把视口拉走 312pt）。这个问题和弹泡无关，**建议保留不动**。
  - CC 入场关掉后，消息一次性以完整高度出现，`scrollToNodeId` 跟随逻辑（`ConversationViewModel.swift:351-353`）不变；原来分块放出时行高一点点长、要补偿器跟着追，现在只长一次，应该更稳。
  - 流式回复仍然只显示已完成的段落（这是内容策略，不是动画），新段落直接出现、不弹；`StreamScrollAnchor` 的离底补偿照常工作。
  - 旧行推移动画本来就只在 `popNodeIds` 非空时开，集合一直空就天然关掉，没有副作用。

## 7. 「稍微改」建议分档（只给建议，粟粟拍板）

**A 档：纯参数 / 删开关，低风险，建议这次做**

1. **先拆共用**（前置，不改观感）：群聊在 `GroupRoomMetrics` 写死 paddingH 18 / paddingV 15 / 圆角 23 / 行距 1.45；气泡模式列表间距不再读 `bubbleSpacing`。
2. 气泡内边距 `fixedPaddingH/V` 18/15 → **13/7**；召回卡 `:287` 的 18 改成跟 `fixedPaddingH`。
3. 气泡模式消息间距 31 → **14**；同一条消息内分泡 4 → **2**。
4. 圆角默认 23 → **19**（`CardFlowView.swift:3814`、`AppearanceSettingsTab.swift:690/816`、`CCWaitingBubbleRow` `:204`）。先看她现在存的值，存过的话要问她要不要重置。
5. 屏边：气泡模式 iOS 16 → **14**（只在气泡模式生效，mac 28 先不动）。
6. 最大宽度：对侧 `Spacer(minLength: 40)` → 约 **62**（393 宽 ≈ 76%）。
7. 用户正文行距 `4×fontScale×1.45` 收到和 AI 一样的 5pt（先统一两边，再看要不要往 1.42 收）。
8. **删「显示头像 / 显示昵称」开关**（§4 列的四个位置），气泡模式固定不显示头像和昵称；`ConfigSchema` 留键；群聊不用动。
9. `ThinkingBubble` 左右内边距 12 → 跟气泡一样（13），上下收紧，让思考行和正文对齐（第 02 / 06 条）。
10. **弹泡加总开关，默认关**（§6 的 ① 到 ⑤）。

**B 档：小行为改动，A 落地看过效果再定**

- 时间分割 3 小时 → 15 分钟（要不要只对气泡模式生效）。
- 回应徽标：锚点从整条消息移到具体某一块（第一块或最后一块要定），样式换成用户泡色的圆 + emoji。
- 跨消息分组：同一个人连发时间距 2、只有最后一条带尾巴（要做邻居缓存）。
- 带尾巴的角收成 6 / 尾巴缩小——等于重画 pao.svg，需要粟粟点头。
- AI 正文行距往 1.42 收（改 fork 写死的 5，带上缓存键，文章模式要不要跟着变）。
- 颜文字不换行（U+2060 方案要先确认不破坏划线 / 收生词 / 查找）。
- 气泡模式默认藏用量行；思考行用小模型摘要代替原文第一句。
- mac 顶部渐隐（先确认有没有硬切）。

**C 档：大活，建议另立项**

- 手绘思考云 6 版 + 沸腾滤镜（第 11 条）；左滑看每条时间（第 08 条后半）；陪伴感节奏：已读、云冒出、三点变消息、名牌状态（第 10 条）；九宫格主题框（第 12 条）。

## 8. 未查证清单（执行前要验）

1. 粟粟本机 `bubbleModeCornerRadius` / `bubbleSpacing` / `showAvatar` 存的值（决定改默认值对她有没有效果）。
2. 16.2pt 系统字 + PingFang 的自然行高，算真实行高倍数（现在是按 SF 约 1.19× 估的）。
3. 参考稿第 07 条的硬切截图是哪个端、哪个版本；mac 顶部现状。
4. 7pt 内边距下思考球等待泡（34pt 高）和文字泡高度不一致的观感。
5. 回应徽标在壁纸半透明 / 渐变用户泡上的观感。
6. 关弹泡后流式 / CC 到达 / 发送三种场景的真机跟随（尤其键盘在场时发送）。
7. `RecallCardView` 没召回时是否完全不占 VStack 的 8pt 间距。
