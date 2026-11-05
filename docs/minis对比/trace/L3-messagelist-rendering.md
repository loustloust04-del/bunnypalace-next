# L3 —— 消息列表、Markdown 渲染、流式性能

先读 `COMMON.md`（同目录）。本文件只写这条 lane 独有的东西。

## 这条轴问什么

**聊天界面这个东西，到底该用 SwiftUI 还是该沉到 UIKit。**

这是 MP 流血最多的一条轴。MP 用 SwiftUI + LazyVStack 反转列表，为此付出了极大代价（下面列了 8 条实测教训，全是真事故）。
OM 的对应实现叫 `CollectionViewMessageListV3`——名字里的 CollectionView 和 V3 已经说明了两件事：**他们沉到了 UIKit，并且重写过至少两次**。

这条轴的价值不在「抄一个列表」，而在**判断 MP 是不是走在一条注定要重写的路上**。

## OM 侧读什么

- `src/ios/Agent/MessageList/` 三个文件：`CollectionViewMessageListV3.swift`、`MessageListInfrastructure.swift`、`MessageListLayout.swift`。
  重点搞清：
  - 列表是正序还是倒序？用什么保持「贴底」？流式生长时怎么不让视口漂？
  - 自定义 layout 在解决什么（自测高度？增量更新？）
  - SwiftUI 和 UIKit 的边界划在哪——气泡内容是 SwiftUI 还是全 UIKit 绘制？
  - 键盘避让谁负责？
- `src/ios/Agent/Markdown/`：`MinisMarkdownParser.swift`（**自研 parser，不是拿库**——为什么？）、`KaTeXRenderer.swift`、`SwiftMathRenderer.swift`、`MathRenderScheduler.swift`（**渲染调度器**——说明数学渲染贵到需要调度，这个机制值得看）。
- `Agent/Chat/AIChatViewModel+SSEStream.swift` —— 流式数据怎么进 UI，节流/批处理在哪一层。

## MP 侧对照坐标

- MP 的聊天列表：自己去 `MemoryPalace/Views/` 下定位（提示：反转列表 + LazyVStack + safeAreaInset 输入条 + UIKit 层做键盘绑定）。
- Markdown：MP 用 **MarkdownUI v2.4.1** + 自定义主题 `MarkdownTheme.swift`。assistant 气泡走 Markdown 渲染，用户气泡纯文本。
- 输入条：MP 已把输入条栈搬到 UIKit host + `keyboardLayoutGuide` 直绑（`InputBarStack`）。

## 车头给的额外情报（MP 的血泪清单，你查不到，全是实测）

带着这些去看 OM 的实现——**每一条都去问「OM 的架构下这个坑还存在吗」**：

1. **SwiftUI geometry API 在 LazyVStack 里 stuck 0**：GeometryReader / onGeometryChange / onScrollGeometryChange 三种都不可靠。
2. **反转列表离底漂移**：生长中的流式 cell 在 offset 原点侧，离底视口被推（「一节节拉」）。`defaultScrollAnchor(.sizeChanges)` 对 LazyVStack 增量生长实证无效（943:0）。修法是 UIKit KVO contentSize 同帧补偿 + 幅度阈值挡万级估算重排 + 只在生成中武装 + 回底动作 0.6s 静默窗。
3. **动态 contentMargins 在键盘期是毒**：键盘起时改 contentMargins 会把 safeAreaInset 输入条重钉到键盘后面。垫块法必须把 `Color.clear` 放在 **LazyVStack 外**（lazy 窗口外高度不重测）。
4. **键盘位移动画三路判死**（修饰符不跑 / 事务泼溅 / 逐帧重排真机跟不满帧）。正解是焊帧 + 绝对值钉位 + 键盘曲线滑动。修前渲染层钉死 380-750ms 一帧瞬跳 1100px。
5. **按测量高度切 if/else 换 identity = 振荡**：异步 parse 的 view 重建回空壳→测量打转。
6. **`_ConditionalContent` 是构造时 frozen branch**，AnyView 不参与精细订阅。
7. **VStack/HStack 空白区 hit 穿透**（无 hit shape），safeAreaInset 输入条必须 `.contentShape(Rectangle())`。
8. **探针本身会扭曲测量**：探针 read view 原本不订阅的 source 会让 view 订阅，制造假 hot path。

MP 还有一个正面成果做参照系：输入条改 UIKit + keyboardLayoutGuide 后，**轨迹从「一帧瞬跳」变成「连续 13 帧逐帧滑动」**。说明沉 UIKit 这个方向在 MP 上已被验证有效——问题是沉多少。

另外 MP 本地有 **Telegram-iOS 源码**（`~/Downloads/Telegram-iOS-master`），MP 的键盘动画三不变量就是从它提炼的。如果 OM 的做法和 Telegram 的做法有分歧，这是有价值的观察，但**别跑去深读 Telegram**——本 lane 的对象是 OM，Telegram 只是你手边的第二参照。

## 特别要回答的

1. **最重要的一问**：OM 的 CollectionView 方案，是不是 MP 那 8 条坑的**根治**（即换架构后这些坑不存在），还是只是换一批坑？逐条对照给判断。
2. 如果答案是「根治」——迁移代价是什么档位？MP 的气泡里有 Markdown、贴纸、工具卡、思考块、引用条、$TICKER 链接化，这些在 CollectionView 宿主里怎么活？
3. OM 为什么自己写 Markdown parser 而不用现成库？MP 的 MarkdownUI 在**流式**场景（每帧重 parse）下是什么代价？OM 的 `MathRenderScheduler` 揭示了什么普遍问题？
4. 给一个明确结论：**MP 该不该重写消息列表**。你可以说「不该」——但要给理由和证据。这条不许骑墙。
