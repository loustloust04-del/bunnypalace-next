# 任务书：气泡模式改成 iOS 26/27 iMessage 的样子（astra 实现）

工位 `/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace/.claude/worktrees/page1`（分支 `zone/page1`）。中文写所有文档和提交说明。

## 必读
1. `docs/plan-bubble-mode-refresh.md` 顶部「粟粟 10-16 批注」：这是真相源，下面旧的 §1–§5 只做参考
2. `docs/research-bubble-mode-refresh.md`：渲染路径和代码证据（`文件:行号`），群聊 / 文章模式共用了哪些值，弹泡的四个入口
3. `docs/playbook-perf.md`：聊天列表相关的部分。别在 `ForEach` 里现算邻居，别给每行挂 GeometryReader
4. 参考截图（iOS 26/27 iMessage，**3x、1180 宽，像素 ÷3 = pt**，底部的 Mobbin 黑条不算）：`~/MemoryPalace-docs-media/docs/imessage-ref/imessage-{51,42,25,4}.png`

## 目标
气泡模式的**几何和 iOS 26/27 iMessage 像素级一致**。包括：屏边到气泡、气泡内边距、单行气泡高度、圆角、最大宽度、同一个人连发的间距、换人的间距、尾巴只在连发的最后一条、尾巴的大小和位置。
- 颜色继续用主题色，不换成蓝 / 灰
- 字号继续跟用户的字体设置走；对拍的时候用 17pt（iMessage 默认字号）


## 范围扩大（粟粟 10-16 第二次改口）：整页布局像素级一致
不只是气泡和尾巴，**气泡模式下整个聊天页的布局**都要和 iMessage 截图像素级一致：
- 顶栏：返回圆钮、中间头像 + 名字胶囊（头像大小、胶囊压在头像下沿的位置、字号）、右侧圆钮的大小和位置，以及顶栏下方的渐隐
- 消息区：上面说的所有气泡几何，再加上居中的时间分隔（"Today 9.23 AM" 的字号、颜色层级、上下间距）
- 输入栏：左侧「+」圆钮、胶囊输入框（高度、圆角、离屏边和离底的距离、占位字号、右侧语音图标位置）
- 颜色照旧用主题色；我们没有的东西（Delivered、投票、贴纸）不做
- 切片调整：S0 把这些也量进 §1b；S2 之后加 **S2b 顶栏 + 输入栏 + 时间分隔**（这几个组件文章模式也在用，只在气泡模式生效，文章模式一像素不变；输入栏和键盘几何、`KeyboardInsetBridge` 有耦合，改尺寸后键盘跟随要保持正常，读 `docs/playbook-perf.md` 和键盘相关的 feedback）；S7 的对拍要整屏比，不只比气泡

## 切片（按顺序做，每片做完自己 commit，提交说明写清这片改了什么）

**S0 量**：用 python3 + PIL 读截图像素（`python3 -I`），量出上面每一项，填进 plan 的 §1b 表（px@3x → pt，每个数注明在哪张图哪个气泡量的）。尾巴要量：伸出气泡外多少、高多少、贴在哪个角。最大宽度在截图里找最长的那个文字气泡，量不到就写「未量到」，并给出依据推算的值。commit 这张表。往 log 写 `MILESTONE S0`，然后**停下等车头核数**（车头核完会在终端里叫你继续）。

**S1 拆共用**：群聊（`GroupRoom/GroupRoomCells.swift` 等）借用了气泡模式的 paddingH/V、圆角、行距，先让群聊写死自己现在的值（18 / 15 / 23 / 1.45），群聊外观一像素不变。气泡模式的消息间距不再读 `bubbleSpacing`，文章模式继续读。跑 `GroupRoomUIKitTests`。

**S2 几何**：按 §1b 改气泡模式的内边距、单行高度、圆角默认值（只改默认值，不做迁移，设置里「恢复默认」也一起改）、屏边、最大宽度、用户和 AI 两边的行距。召回卡、CC 等待泡、思考行跟着气泡对齐（思考图标和正文起点在一条线上）。

**S3 连发分组**：同一个人连发好几条时，间距用 iMessage 的小间距，只有最后一条带尾巴；换人用大间距。邻居关系要做缓存（照 `viewModel.timeDividerCache` 的做法，路径变了才重算），不能在列表 body 里现算。

**S4 尾巴**（粟粟 10-16 改口）：现在的 pao.svg 是粟粟照着 iMessage 手画的。允许重画 `BubbleTailShape`，目标是和 iMessage 尾巴像素级一致（伸出多少、高度、和气泡边的接缝弧线、贴哪个角）。群聊也用同一个 Shape，`GroupRoomUIKitTests` 要继续过；群聊尾巴跟着变是可以的，其它外观照旧不变。S7 的差值表里要有尾巴这一项。

**S5 开关**：删设置 › 外观里的「显示头像」「显示昵称」两个开关，设置搜索里的条目一起删。气泡模式固定不显示头像和昵称。`ConfigSchema` 保留 `showAvatar` 键（导入测试要用）。文章模式和 Code 详情页继续显示昵称，但昵称**稍微往中间挪一点点**（往里挪 4–6pt，挑和正文对齐最好看的值，写明理由）。群聊不动。

**S6 弹泡默认关**：在 `BubblePopTuning` 加总开关 `enabled`，默认 false。`markPop`、CC 入场场景 A 和 B、`popTransition`、气泡里的三处 `.animation(popAnimation)` 都读它。Debug › 弹泡调音台顶上加「启用弹泡」开关。代码一行不删。`KeyboardInsetBridge` 的 `sendDismissUntil` 不动。

**S7 对拍**：写一个测试（`xcodebuild test`，iOS 26 模拟器，scheme `MemoryPalaceTests`，module 名「记忆花园」），用 ImageRenderer 渲染气泡模式：用 17pt 字号排出和截图里一样的几条消息（"Thank you!"、"I love chocolate chip!!! 🍪"、"Which flavor do you want?"、"Come over at 12"，连发和换人都要有），393 宽、3x 出 PNG，存到 `~/MemoryPalace-docs-media/docs/imessage-ref/ours/`。再写个 python 脚本，把我们的图和 iMessage 截图按气泡外框逐项比（x / y / 宽 / 高 / 圆角 / 尾巴），输出差值表。目标是每项差 ≤1pt（3px）。超出的修到达标，修不到的写清原因。差值表贴进 `docs/review-bubble-mode-refresh.md`。

**S8 收尾**：写 `docs/review-bubble-mode-refresh.md`（三块：边界情况 / 和其它模块交互的风险 / 技术债，加上 S7 的差值表）。更新 `manual/facts/modules/appearance-theme.md` 和 `main-chat.md`（开关删了、参数变了，带 `文件:行号`），`cd scripts/manual && npm run check` 要过。plan §5 的 todo 逐项打 ✅。写 `docs/now/page1.md`（一段话：做了什么、怎么验、等粟粟验 UI）。往 log 写 `DONE`。

## 验证规则
- **工位不准普通 build**（shim 会拒）。只用 `xcodebuild build-for-testing` / `test` / `test-without-building`。iOS 用 scheme `MemoryPalaceIOS` + 具体的 iOS 26 模拟器 `-destination 'platform=iOS Simulator,id=…'`（`xcrun simctl list devices` 找）；mac 用 `MemoryPalace`。只认输出里的 `** TEST BUILD SUCCEEDED **` / `Test Suite '…' passed`，退出码不算。
- 每片做完至少 iOS build-for-testing 一次。S1、S5、S6、S7 跑对应的测试：`GroupRoomUIKitTests`、`SettingsSearchTests`、`ConfigEncryptedExportTests`、`CCEntranceTests`、`BubbleStreamingBlocksTests`，加上你新写的对拍测试。定向测试要 grep 到目标类的 `Test Suite '<类名>' passed`。
- 合并后先 `xcodegen generate`；不准用 `-derivedDataPath`。编译排队、超载等待都是正常的，别绕过去。

## 禁区
- 不准碰：群聊外观、文章模式外观（只有 S5 的昵称位置可以动）、UIKit 试验页（`Views/Spike/`）、主题颜色、`git push`、`merge-queue`、master、其它工位、`settings*.json`、CLAUDE.md
- 不准装设备、不准启动模拟器 app 装包（测试跑在模拟器上可以）
- 不准往 `tasks/` 加任务；不准提交截图 / PNG 进 git（都放 `~/MemoryPalace-docs-media/`）
- 不准 `git stash`、`reset --hard`、`checkout -- .`
- 不准在 `ForEach` / 行 body 里做 O(n) 的邻居计算；不准每行挂 GeometryReader
- 不改方向：做不下去写 BLOCKED，不要自己换方案

## 汇报
往 `~/MemoryPalace-docs-media/docs/imessage-ref/astra-log.md` 追加，一行一条：
- `MILESTONE S<n> <commit短哈希> <一句话>`：每片做完
- `BLOCKED <原因>`：卡住了，停下等车头
- `DONE <最后一个 commit>`：全部做完
其余时间连续做，不用等确认（S0 之后那次停下除外）。
