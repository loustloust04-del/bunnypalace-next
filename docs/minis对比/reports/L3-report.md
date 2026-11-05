# L3 报告 —— 消息列表、Markdown 渲染、流式性能（SwiftUI vs UIKit）

> Lane 任务：逐条对照 MP 的 8 条实测血泪教训，判断 OM 的 `CollectionViewMessageListV3` 架构下坑是否还存在；回答「MP 该不该重写消息列表」。
> 证据口径：OM = `/private/tmp/.../scratchpad/OpenMinis`（commit 09fc199），下文路径省作 `OM:src/ios/...`；MP 路径相对仓库根；fork 库 = `/Users/susu/Projects/Sandbox/SwiftStreamingMarkdown-fork`。所有行号我都读过上下文（OM 侧 MessageList 三文件 7260 行全文通读；MP 侧关键点逐一目读；fork 关键段落目读）。
> 一句话先说结论：**8 条坑里只有 2 条半是被 OM 架构真正「根治」的，2 条是「OM 没接这个需求所以坑不存在」，3 条半与列表架构无关；且 OM 换来了一族 MP 今天没有的新坑（hosting-graph 崩溃 + 高度缓存陈旧）。不该重写。**

## TL;DR

| # | 发现 | 差距性质 | 采纳建议 | 代价档位 |
|---|------|----------|----------|----------|
| L1 | 8 坑逐条对照：根治 2.5 / 需求取消 2 / 架构无关 3.5 | —（本 lane 主产出，见 §逐条对照） | 见各条 | — |
| L2 | OM 流式分层节流（VM 层 0.2s→2s 阶梯 + 换行快车道）；MP 流式零节流、每快照全量重 parse，OM 明示这就是 O(N²) watchdog 雷 | 实现更优 | 直接搬（按 MP 架构原生实现：StreamingMarkdownSource 层加阶梯节流） | 小时级 |
| L3 | OM 用户滚动时挂起流式 UI 更新 + 浏览态 3s 降频 flush；MP 无滚动门控 | 能力缺失 | 改造搬（降频即可，挂起可缓） | 天级 |
| L4 | OM ScrollMetricsRecorder：DEBUG-only、默认关、内存 ring、无阈值全量记录 | 实现更优（探针基建） | 只借思路 | 天级 |
| L5 | OM「自研 markdown parser」真相 = cmark_gfm 打底 + 内联 AST + 数学预抽取；动因是渲染终点是 UITextView 且要数学 | 不适用（MP 渲染终点是 SwiftUI，无数学） | 不建议换 parser | — |
| L6 | MathRenderScheduler：贵渲染（3–10ms/公式）主线程分批让出 + weak 丢弃陈旧任务 | 不适用（MP 今天无 cell 内贵渲染） | 不建议（无需求），记住模式 | — |
| L7 | 反向：键盘期逐帧贴底滑动 MP 有 OM 没有（OM 是系统避让 + 延迟 0.3s 重钉） | 我们更好 | 保持，别在重写中丢掉 | — |
| L8 | 反向：输入条 keyboardLayoutGuide 直绑 vs OM 的 SwiftUI 自动避让 + phantom inset 补丁链 | 我们更好 | 保持 | — |
| **结论** | **MP 不该重写消息列表** | — | 把 L2/L3 搬掉；重写只在满足 §结论 的触发条件时再谈 | — |

---

## §OM 架构速写（对照的事实基础）

- 列表 = UIKit `UICollectionView` + 自研 `UICollectionViewLayout`（`MessageListLayout`），**正序不反转**；贴底靠 `contentInset.bottom`（= 输入条高 + 浮动工具条高 + 8，OM:src/ios/Agent/MessageList/CollectionViewMessageListV3.swift:104）+ contentSize KVO 钉底（同文件 :901-993）。
- cell 内容仍是 SwiftUI：`UIHostingConfiguration` 包 `Bridged*V3` 视图（同文件 :1042-1067），assistant 消息拆成 header/block/footer 四种 cell 注册（:852-867），item 标识是纯 UUID 对（OM:src/ios/Agent/MessageList/MessageListInfrastructure.swift:21-29）。
- 高度体系三层：实测缓存 → TextKit 预计算 → 启发式估算（V3 头注释 :35-37；layout 侧 MessageListLayout.swift:194-202）。
- 键盘：列表层**什么都不做**。输入条是 SwiftUI `.overlay(alignment: .bottom)`（OM:src/ios/Views/Chat/AIChatView.swift:513-597），键盘避让全靠 SwiftUI 自动机制（该文件 :1338-1341 注释自述 "SwiftUI's automatic keyboard avoidance applies that window-wide"）；`inputFocused` 变化后延迟 0.3s 补一次回底滚动（CollectionViewMessageListV3.swift:183-191）。
- 流式：VM 层节流后整段快照 + 后台 parse 推主线程（OM:src/ios/Agent/Chat/AIChatViewModel+SSEStream.swift:595-612），列表层 `flushStreamingLayout` 再按滚动模式 0.1s/3s 自适应节流（CollectionViewMessageListV3.swift:2176-2195）。

---

## §逐条对照：8 条血泪教训在 OM 架构下还存在吗

### 1. SwiftUI geometry API 在 LazyVStack 里 stuck 0

- **OM 怎么做**：列表内**彻底不用** GeometryReader——V3 的设计头注释第一条就是 "Single height source: UIKit self-sizing only (no GeometryReader)"（CollectionViewMessageListV3.swift:35）。cell 高度由 `preferredLayoutAttributesFitting` 的 UIKit 链路产出（MessageListInfrastructure.swift:151 起），不存在「SwiftUI 测量 SwiftUI」的环节。
- **但**：坑没有被消灭，只是被赶出了列表。OM 在列表**外**仍被同类问题咬过：`[T-ios-geometry-observer-crash]`——GeometryReader+onChange 写 state 在 iOS 18 async renderer 上 SIGTRAP，被迫改 onGeometryChange（AIChatView.swift:2633-2638）；输入条高度的 onGeometryChange 要带四重防护：瞬态 0 守卫（:3503-3504）、离屏帧丢弃（:3506-3541）、同步 seed + 380ms 后自校正（:3558-3584）、后续变化 debounce（:3585-3589）。这是 OM 版的「geometry 不可靠」，只是他们把它圈养在了输入条高度这一个点上。
- **MP 现状**：列表内测量点密度高——每个气泡 `.background(GeometryReader)` 报 midY 给贴纸锚定（CardFlowView.swift:391-396）；回底判定走 `onScrollGeometryChange`（:486-495），并有注释记录的 margin 假翻教训（:487-489）。
- **差距性质**：实现更优（就「列表内测量」这一点）。
- **判断**：**列表层根治，_app 层存活_**。换架构能消掉 MP 列表内的 geometry 依赖，但只要任何 UI 留在 SwiftUI（OM 的输入条就是），geometry 防护就还得写。
- **采纳建议**：只借思路——MP 列表新需求尽量避免新增列表内测量点；不值得为此重写。
- **代价档位**：重写才消 = 架构级。
- **风险与前置**：见 §结论。

### 2. 反转列表离底漂移（流式生长推视口）

- **OM 怎么做**：不反转，生长发生在内容尾部。三道机制叠加：(a) 自定义 layout 的 `invalidationContext` 在**同一个 layout pass** 里对「视口上方/视口内非流式 cell」的高度变化写 `contentOffsetAdjustment`（MessageListLayout.swift:517-531），对「流式 cell 且钉底中」同样同帧补 delta（:531-542，注释明说就是为了消 "grow-then-catch-up" jitter）；(b) contentSize KVO 在 autoScrolling 模式直接钉 `contentOffset.y = maxOff`（CollectionViewMessageListV3.swift:924-938）；(c) `NoAnimationCollectionView.layoutSubviews` 在流式生长时只给 contentOffset 加 0.2s easeOut 动画、cell frame 瞬到终态——「只有一个移动量，header 不漂」（MessageListInfrastructure.swift:758-803）。估算→实测的修正不会推视口，因为修正走 (a) 的同帧补偿，且 heightCache 跨 invalidation 不丢（MessageListLayout.swift:7-10）。
- **MP 现状**：同思路的体外循环版——`StreamScrollAnchor` 用 UIViewRepresentable 爬到 UIScrollView 上 KVO contentSize 同帧补 offset（CardFlowView.swift:56-132），外加幅度阈值 ≤2000（:115）、生成中才武装（:117）、0.6s 静默窗（:64/:119）、滚动中不补（:125）。`defaultScrollAnchor(.sizeChanges)` 实证无效已撤（:498-499 注释）。
- **差距性质**：实现更优——**同帧补偿长进了 layout 内部，而 MP 是在 SwiftUI 体外爬 superview 打补丁**。OM 不需要「万级估算重排」这个阈值启发式，因为它的 layout 高度源是确定性的缓存表，不存在 LazyVStack 那种位置未知的批量重估。
- **判断**：**根治**。这是 8 条里最硬的一条根治。
- **采纳建议**：只借思路。MP 现有补偿器已闭环（任务书列为已修复）；除非重写，否则没有可搬的增量。
- **代价档位**：—（不搬）。
- **风险与前置**：注意 OM 为此付的代价：`deferSelfSizing`/`deferredHeights`（滚动中冻结高度、settle 时才 applyDeferredHeights，MessageListLayout.swift:43-48、:306-375；CollectionViewMessageListV3.swift:4963-5061）——滚动期间离屏 cell 的真实高度被故意压住，settle 重排时上面视口的 cell 变化仍会位移内容（他们自己用 SettleJitter 探针追这个，MessageListLayout.swift:320-328）。根治漂移 ≠ 零代价。

### 3. 动态 contentMargins 在键盘期是毒

- **OM 怎么做**：**键盘从不碰列表 inset**。列表 `contentInset.bottom` 恒 = 输入条 + 浮动条 + 8（CollectionViewMessageListV3.swift:104）；键盘起来时 SwiftUI 自动避让把整个 chat view 压矮（AIChatView.swift:1338-1341），collection view 只是 bounds 变小，inset 不动。「键盘期改 inset 会把 safeAreaInset 输入条重钉到键盘后面」这个因果链在 OM 里不存在——因为没有 safeAreaInset 输入条，也没有动态 margin。
- **MP 现状**：动态 margin 路线已弃，垫块法 + `Color.clear` 必须放 LazyVStack 外（CardFlowView.swift:348-366，注释即消融实验结论）；margin 只剩静态 100/150（:445-448）。
- **差距性质**：不适用→更准确说「**需求被取消**」：OM 没有「键盘期列表内容逐帧贴底」这个需求（见第 4 条），自然没有这个坑。
- **判断**：**坑不存在，但不是因为架构高明，是因为目标更低**。代价：OM 被 SwiftUI 自动避让咬出另一串伤——chat→home 残留的 phantom keyboard inset（onDisappear 强制 endEditing，AIChatView.swift:1331-1358）、后台快照期的 zombie inset（被迫对语音面板态 `.ignoresSafeArea(.keyboard)`，:1362-1378）。
- **采纳建议**：不建议搬任何东西。MP 的 UIKit 方案（keyboardLayoutGuide 直绑）在此维度上更优，见 §反向发现。
- **代价档位**：—。
- **风险与前置**：—。

### 4. 键盘位移动画三路判死（焊帧 + 绝对值钉位 + 键盘曲线滑动）

- **OM 怎么做**：没有对应物。OM 不接受「键盘期正文跟随手指/曲线逐帧滑动」这个需求：键盘动画是系统的，列表被压矮后由 `inputFocused` 边触发一次延迟 0.3s 的 `scrollToBottomNow(animated: true)` 了事（CollectionViewMessageListV3.swift:183-191）。全仓 grep `keyboardLayoutGuide|keyboardWillShow` 在聊天链路零命中（命中仅在语音面板和终端视图）。
- **MP 现状**：已实现 Telegram 级方案——`handleChatKeyboardRise`：`performWithoutAnimation` 内垫块瞬变 + 绝对值钉「旧画面等价位」，再 `UIView.animate` 用键盘 userInfo 真曲线滑回底（Paging/PagingViewController.swift:290-357，焊帧在 :331-335，滑动在 :306-315，候选栏级小变化过滤 :317-325）。
- **差距性质**：**我们更好**（这条同时进 §反向发现）。
- **判断**：坑在 OM 下「不存在」= OM 放弃了这个体验档位。MP 今天的逐帧贴底滑动是 OM 架构里**没有**的能力，不是 OM 架构里「不会坏」的能力。
- **采纳建议**：不建议。任何重写都必须保留这条已验证的能力，这是重写的隐藏成本。
- **代价档位**：—。
- **风险与前置**：—。

### 5. 按测量高度切 if/else 换 identity = 振荡

- **OM 怎么做**：列表层没有这个问题类——cell 的 identity 是 diffable data source 的 UUID item（MessageListInfrastructure.swift:21-29），内容变化在 cell 内就地发生，不存在「SwiftUI 条件分支换 subtree identity」。**但换来了同族的镜像坑**：@Published 驱动的就地内容变化不改变 item 标识 → diffable diff 为空 → UIKit 不重配 cell → 高度缓存陈旧。OM 为此维护了一整套手工失效机制：`blockContentFilledSignal` 双侧清缓存（CollectionViewMessageListV3.swift:1843-1909）、`FooterHeightShape` 布尔形状比较（:1424-1453）、`invalidateFooterHeightCaches`（:1959-1985）、thinking 折叠通知定向失效（:2372-2442）——至少四个独立的 T- 标签事故都长在这条链上。
- **MP 现状**：实锤振荡现场不在列表在长按预览——`previewBox` 恒等同一 ScrollView 容器只变 frame，注释记录了「换 identity → MarkdownView 重建回空壳 → 50↔727 振荡（探针实录）」（BubbleMenuOverlayView.swift:209-216）。
- **差距性质**：不适用（MP 的现场与列表架构无关；OM 的镜像坑 MP 没有）。
- **判断**：**列表层根治，但换成「就地变异 → 缓存失效」坑族**。这不是免费的。
- **采纳建议**：不建议为此动列表；MP 的修法（恒等容器只变 frame）已是对的。
- **代价档位**：—。
- **风险与前置**：—。

### 6. `_ConditionalContent` 构造时 frozen branch / AnyView 不参与精细订阅

- **OM 怎么做**：列表结构变化（增删 block、footer 插入/移除）走 diffable snapshot，不走 SwiftUI 条件渲染——这一层确实绕开了。但 cell 内部仍是 SwiftUI，OM 照样被咬：`.sheet`/`.contextMenu` 修饰符会包一层 interaction 容器把 self-sizing 充气，workaround 是把它们挂到零尺寸 `Color.clear` overlay 上（CollectionViewMessageListV3.swift:288-291、:445-449 注释明说 "causing height oscillation"）。
- **MP 现状**：见第 5 条；这是 SwiftUI 语言层事实。
- **差距性质**：不适用（架构只能把它赶出列表层，赶不出 SwiftUI）。
- **判断**：**列表层根治，cell 内存活**。
- **采纳建议**：不建议。
- **代价档位**：—。
- **风险与前置**：—。

### 7. VStack/HStack 空白区 hit 穿透

- **OM 怎么做**：同款坑同款修法——tap-outside catcher 就是 `Color.clear.contentShape(Rectangle()).onTapGesture`（AIChatView.swift:570-577）；还有注释记录 `.overlay(alignment:)` 内容画出 host frame 外吃不到 touch、被迫改 ZStack sibling（:544-549）。
- **MP 现状**：safeAreaInset 输入条 `.contentShape(Rectangle())`（任务书），以及 UIKit 侧 `PassthroughContainerView` 透传容器（Paging/PagingViewController.swift:152-154 注释：hosting view 整 bounds 拦截触摸会挡死列表按钮行）。
- **差距性质**：不适用（与列表架构零关系，纯 SwiftUI 语义）。
- **判断**：**两边一样存在，一样修法**。不构成重写理由。
- **采纳建议**：不建议。
- **代价档位**：—。
- **风险与前置**：—。

### 8. 探针本身扭曲测量

- **OM 怎么做**：`ScrollMetricsRecorder`——20000 槽内存 ring，DEBUG-only 编译剥离，默认关、经 debug server 显式开，记录无阈值全量事件（scroll/measure/inv/flush/settle/prepare），热路径上只有一个 Bool 检查（MessageListLayout.swift:901-998，开关语义 :920-930）。事件带稳定 content-hash tag，可跨消息对象重建追踪同一 cell 的高度轨迹（:932-947）。设计哲学与第 8 条教训完全同构：探针不打 log I/O、不改订阅、不干扰时序。
- **MP 现状**：教训本身（任务书第 8 条）。MP 现有探针形态未在本次范围系统盘点（未查证）。
- **差距性质**：实现更优（探针基建）。
- **判断**：与列表架构无关，**直接可借**。
- **采纳建议**：只借思路——DEBUG-only + 默认关 + 内存 ring + 无阈值 + 稳定 tag。MP 下次再追滚动/高度类问题前值得先有这层。
- **代价档位**：天级。
- **风险与前置**：无冲突；注意不要做成常开。

### 对照小结

| 坑 | OM 架构下的状态 | 性质 |
|---|---|---|
| 1 geometry stuck 0 | 列表层根治，列表外存活（OM 自己有 SIGTRAP 史） | 半个根治 |
| 2 离底漂移 | **根治**（同帧补偿内建于 layout） | 根治 |
| 3 动态 margin 键盘期 | 坑不存在（键盘不碰 inset） | 需求取消 |
| 4 键盘逐帧动画 | 坑不存在（没接这需求；MP 在此领先） | 需求取消 |
| 5 测量高度切分支振荡 | 列表层根治，换成缓存陈旧坑族 | 根治但有对价 |
| 6 _ConditionalContent frozen | 列表层根治，cell 内存活 | 半个根治 |
| 7 hit 穿透 | 一样存在 | 无关 |
| 8 探针扭曲 | 一样要面对（OM 基建更好） | 无关 |

**2.5 根治 / 2 需求取消 / 3.5 无关。没有任何一条是「OM 架构下自然不存在且无副作用」的免费午餐——两条「需求取消」还是拿体验换的。**

---

## §OM 换来的新坑族（MP 今天没有的）

这是回答「根治还是换一批坑」的另一半证据——OM 的伤疤清单：

1. **FB13213926 hosting-graph 崩溃系列**（UIKit 自测量重进 SwiftUI view graph 撞上 async renderer 拆图，至少 5 次坠机记录）：防御 = `noff_try_objc` + `withExtendedLifetime` 钉住整棵 contentView 子树（MessageListInfrastructure.swift:319-357、:380-424）、off-collection 守卫（:227-229）、交互/流式窗口短路（:231-287）、`prepareForReuse` 里**不敢**清 contentConfiguration（:642-647）、提前 dismiss context menu（:613-641）。**MP 的列表是纯 SwiftUI，对这套崩溃面零暴露**；一旦把 SwiftUI 气泡塞进 UIKit 复用循环，这整个家族就是门票。
2. **高度缓存陈旧族**：cell 侧 `lastComputedHeight`、layout 侧 `heightCache`、content-keyed memo 三层，任何 @Published 就地变化都要手工定向失效（见第 5 条列举）。V3 里带 `T-ios-*-staleness/gap` 标签的事故注释密度极高。
3. **suspend/resume 快照延迟链**：用户滚动即挂起流式 UI（见发现 L3），于是需要 pending-snapshot + 三路 flush 兜底（suspend-resume、stream-end rescue、updateUIViewController backstop，CollectionViewMessageListV3.swift:1544-1615、:2097-2129、:167-181）——每一块注释都是一次「UI 冻住/块丢失」事故。
4. **体量**：三个文件 7260 行（V3 协调器 5131 + 基建 1130 + layout 999），且这是**第三次**重写（V3 头注释 :32-37 自述 "replaces V2's 6+ mechanisms"）。

---

## §发现 L2：流式分层节流（最值得搬的一条）

- **OM 怎么做**：SSE 消费在后台 actor，文本 delta 先进非发布缓冲；flush 用**随内容长度变宽的阶梯节流**：<500→0.2s、<2K→0.3s、<32K→0.5s、<64K→1s、<128K→1.5s、以上 2s（AIChatViewModel+SSEStream.swift:579-584）；换行快车道（<5000 字符且含 `\n` 且未 flush ≥50 立即冲，:586-593）；flush 时**后台线程** parse markdown 再 hop MainActor（:598-612）。注释明说动机：防 "O(N²) full-markdown re-parse storm" 触发 0x8BADF00D（:569-571）。工具输入 delta 单独节流（file_write/edit 1s、其余 0.2s，:631-648）。thinking delta 同理阶梯 0.3/0.6/1.0s（ChatModels.swift:261-265）。另有一个解耦思想值得抄走：**逐字顺滑的观感靠动画层的固定 stagger，不靠提高 flush 频率**（SSEStream:572-575 注释，动画层 = TextFadeAnimator）。
- **MP 现状**：`StreamingMarkdownSource` 对 `vm.streamingText` 的**每次变化** yield 一份完整快照，无节流无合批（Services/StreamingMarkdownSource.swift:59-75）；fork 库侧对每份快照整体重 parse（off-main，但无丢弃旧快照机制，`for await` 顺序消费）（fork: Sources/MarkdownText/StreamedMarkdownView.swift:82-95，协议注释 :12-14 自述 "re-parses each snapshot"）。即 MP 今天就是 OM 注释里那个 O(N²) 形态，只是还没长到触发 watchdog 的规模。macOS 侧 MarkdownUI 每 body 重算全量 parse（CardFlowView.swift:3053-3060）。
- **差距性质**：实现更优。
- **采纳建议**：**直接搬（按 MP 架构原生实现）**。落点在 `StreamingMarkdownSource.observe()` 的 yield 点：加阶梯时间节流 + 换行快车道 + `.done` 强制尾 flush。fork 的 parse 已在后台，无需动。macOS 的 MarkdownUI 路径如需同保护，在 viewModel 的 streamingText 发布侧节流更省事（一处节流两端受益——推断，未验证 macOS 路径是否共用 streamingText）。
- **代价档位**：小时级。
- **风险与前置**：节流会拉低「逐字感」——用 OM 的思路对冲：视觉顺滑交给 reveal/淡入动画层，不靠 flush 频率。MP 气泡模式已有逐块 reveal 节奏器（ChatBubbleStyle，本次未目读，标未查证），对得上。

## §发现 L3：滚动时挂起/降频流式 UI 更新

- **OM 怎么做**：`scrollViewWillBeginDragging` 一刀切：`scrollMode = .userBrowsing` + `layout.deferSelfSizing = true` + `vm.setStreamingUIUpdatesSuspended(true)`（CollectionViewMessageListV3.swift:4683-4691）；settle 后统一恢复并 flush（:5046-5052）。期间新 block 只记 `hasPendingSnapshot`（:2143-2148）。另外浏览态下 streaming layout flush 从 0.1s 降到 3s（:2176-2178）。哲学：**用户的手 > 模型的字**。
- **MP 现状**：无滚动门控。流式期间滚动靠 StreamScrollAnchor 补偿器硬扛（CardFlowView.swift:111-127），渲染侧照常每变化重 parse（见 L2）。
- **差距性质**：能力缺失。
- **采纳建议**：改造搬——先搬轻的一半：检测到用户拖拽/减速中时，把 L2 的节流间隔临时拉宽（等效 OM 的 3s 档）；「完全挂起」带 pending-flush 复杂度（OM 自己的事故链见 §OM 换来的新坑族 3），不建议第一步就上。
- **代价档位**：天级。
- **风险与前置**：依赖 L2 先落地（否则没有可调的节流旋钮）；挂起方向若做，必须配 flush 兜底路径。

## §发现 L4：ScrollMetricsRecorder（探针基建）

- 见第 8 条对照。**采纳建议：只借思路，天级**。对 MP 的边际价值高：MP 的 8 条教训全是真机探针换来的，而第 8 条说明探针会污染测量——ring buffer + 默认关 + DEBUG 剥离正是对症形态（MessageListLayout.swift:901-930）。

## §发现 L5：OM 的「自研 parser」真相 & MP 的 MarkdownUI 流式代价

- **OM 怎么做**：底层 tokenizer 是 **cmark_gfm**（MinisMarkdownParser.swift:1-3、:899 一次性 feed 全文），不是手写 parser。自研的三层是：(a) 把 swift-markdown-ui 的 AST 类型内联进来、刻意去掉对 MarkdownUI 渲染层的依赖（:5、:107）；(b) cmark 没有的**数学预抽取**——先抽出 LaTeX 再 parse 再回填 AST（:129-135，容错：未闭合定界符原样输出，:449-470 一带，我读过 449-511 区域的函数签名与注释框架，具体逐行未全读，标注）；(c) 规则可控，如单 `~` 不触发删除线防误伤「6月14日~6月16日」（:875-881）。**动机（推断，代码结构支撑）**：OM 的渲染终点是 NSAttributedString → UITextView（`SelectableMarkdownTextView`，完成块缓存 `cachedAttributedString`，ChatModels.swift:305-309），MarkdownUI 的产出是 SwiftUI view 树，根本接不上；数学支持 cmark 没有。所以「为什么自研」的答案是：**渲染栈换了，parser 必须跟着换**；不是「库不好」。
- **MP 现状**：渲染终点是 SwiftUI（iOS fork SwiftStreamingMarkdown / macOS MarkdownUI，CardFlowView.swift:3040-3060），MarkdownUI 正是为这个终点设计的。流式代价 = L2 所述每快照全量重 parse，无增量 AST（fork StreamedMarkdownView.swift:86-93）。
- **差距性质**：不适用（两边渲染终点不同，parser 选择各自合理）。
- **采纳建议**：不建议换 parser。MP 要解的是节流（L2），不是 parse 本身。
- **代价档位**：—。
- **风险与前置**：—。

## §发现 L6：MathRenderScheduler 揭示的普遍问题

- **OM 怎么做**：SwiftMath 原生排版每个公式 3–10ms，600–700 个公式朴素渲染阻塞主线程 3–7s 被 watchdog 杀（MathRenderScheduler.swift:5-14 文件头自述）。解法 = 主线程串行队列、每 runloop tick 最多 4 个就让出（:28-31、:79-101）、weak 引用让宿主已销毁的陈旧任务自然作废（:33-35、:81）。数学渲染本身：SwiftMath 纯原生同步出 bitmap（SwiftMathRenderer.swift:6，此行我目读过文件头区域）；KaTeX/WKWebView 路径已是**死代码**——全仓仅 `MinisApp.swift:134` 一处 `warmUp()` 调用（我 grep `KaTeXRenderer\.shared\.(render|renderCached|warmUp)` 验证，只命中 warmUp）。
- **MP 现状**：无数学/贵 cell 渲染——全仓 grep `latex|swiftmath|katex|mathBlock` 只命中词库语料文本（推断：MP 今天没有此需求）。
- **差距性质**：不适用。
- **采纳建议**：不建议搬。记住模式即可：**cell 内有单价 ≥3ms 的渲染时，排队分批 + runloop 让出 + weak 丢弃**是通用解。MP 若未来加公式/图表渲染，先上调度器再上渲染。
- **代价档位**：—。
- **风险与前置**：—。

---

## §特别问题 2：如果重写，代价是什么？气泡内容怎么活？

**代价档位：架构级（数周起步，且 macOS 无解）。** 拆解：

- **macOS 没有 UICollectionView**。NSCollectionView 的 self-sizing 生态与 UICollectionView 不对等（推断——本次未在 macOS 上验证 NSCollectionView 自测量链路，标未查证）。MP 两端共用源码（AGENTS.md），重写 = 要么 iOS 单列实现 + macOS 保留 SwiftUI（两套列表长期双维护），要么 macOS 也硬迁 NSCollectionView（未知风险区）。
- **气泡内容在 CollectionView 宿主里的活法**：OM 证明了 SwiftUI 内容可以塞 `UIHostingConfiguration` cell（CollectionViewMessageListV3.swift:1042-1067）——但门票是 FB13213926 崩溃防御全家桶（§OM 换来的新坑族 1）。MP 的 Markdown（fork SwiftStreamingMarkdown 是 SwiftUI 原生，StreamedMarkdownView 是 View）、贴纸（列表 ZStack 兄弟层，画布不随列表技术变，但**落点锚定靠 per-bubble GeometryReader**，CardFlowView.swift:391-396——进 UIKit 后这套要重铺成 cell frame 回调）、工具卡/思考块/引用条/$TICKER（全 SwiftUI：ChatMarkdownView.swift:101-125 等）都能以「SwiftUI-in-cell」存活，但每一个都是 hosting-graph 重进的新表面。OM 的 markdown 路线（NSAttributedString→UITextView）对 MP 意味着连渲染器一起重写——那是另一个数量级。
- **会被重写丢掉的已有资产**：键盘逐帧贴底（PagingViewController.swift:290-357）、StreamScrollAnchor（CardFlowView.swift:56-132）、垫块法键盘避让（:348-366）——全部要在新架构里重新等价实现并重新排雷。

## §结论：MP 该不该重写消息列表？

**不该。**

理由（按权重）：

1. **要治的病都已治**。8 条教训全部有已落地、经探针验证的修复（任务书自述 + 我在代码里核对了 StreamScrollAnchor、垫块法、焊帧滑动三处现场）。重写解决的是已解决的问题。
2. **OM 的证据指向「换坑」而非「根治」**。逐条对照：2.5 条根治 / 2 条是 OM 放弃需求 / 3.5 条与架构无关。OM 的 V3 是第三次重写，7260 行列表基建，带着 MP 今天零暴露的崩溃家族（FB13213926）和一整套手工缓存失效机制。「V3」这个命名本身就是答案：沉到 UIKit 不是上岸，是换一片海继续游。
3. **MP 是 macOS 主战场**。UIKit 列表不覆盖 macOS，重写在主战场上买不到任何东西，还要长期双实现。
4. **MP 在键盘轴上已经领先 OM**（§反向发现 L7/L8）。重写最可能弄丢的恰恰是 MP 已经赢的部分。

**真正该做的（也是本 lane 的可执行产出）**：L2 流式节流（小时级）→ L3 滚动降频（天级）→ L4 探针 ring（天级）。三个都不动列表架构。

**重写的触发条件**（哪天这些成立了再回来翻这份报告）：(a) 单会话消息量级长到 LazyVStack 首屏/回翻成本成为用户可感投诉；(b) 现有补丁层再出**无法局部修复**的事故（补丁的补丁的补丁信号）；(c) 决定 iOS 独立成产品、愿意养两套列表。届时 OM V3 的最大价值不是代码，是它注释里的伤疤清单——那是重写的验收单。

---

## §反向发现（MP 比 OM 好的地方）

1. **键盘期逐帧贴底滑动**。MP：焊帧 + 绝对值钉位 + 键盘真曲线 `UIView.animate`（Paging/PagingViewController.swift:290-357），任务书记录的效果是「一帧瞬跳 → 连续 13 帧逐帧滑动」。OM：SwiftUI 系统自动避让 + `inputFocused` 边延迟 0.3s 补一次回底（CollectionViewMessageListV3.swift:183-191），键盘期正文不逐帧跟随。**OM 架构里没有这个能力的等价物。**
2. **输入条键盘绑定的结构干净度**。MP：UIKit 层 `keyboardLayoutGuide.topAnchor` 直绑（Paging/PagingViewController.swift:162），键盘几何是约束真值。OM：依赖 SwiftUI 自动避让 window 级生效，反被咬出 phantom inset（离开 chat 残留键盘 inset 顶起 home FAB，被迫 onDisappear 强制 endEditing，AIChatView.swift:1331-1358）和 zombie inset（后台快照期 inset 滞留，被迫按状态切 `.ignoresSafeArea(.keyboard)`，:1362-1378）。
3. **没有死代码渲染路径**。OM 的 KaTeXRenderer（WKWebView 方案）全仓只剩 `warmUp()` 一个调用点（MinisApp.swift:134，render/renderCached 零调用——我 grep 验证），每次启动白预热一个离屏 WebView。MP 无此税。
4. **macOS 覆盖**。本 lane 范围内 OM 是 iOS-only；MP 同一套 SwiftUI 列表两端可用，macOS 侧根本没有键盘避让这个战场。这既是我们更好的点，也是「不该重写」的论据。

## §不建议学（OM 有但 MP 不该学的）

1. **SwiftUI 自动键盘避让 + 按状态切 `.ignoresSafeArea(.keyboard)`**——OM 自己为此打了一串补丁（AIChatView.swift:1331-1378 两个事故的防御链）。MP 的 UIKit 直绑已 structurally 更稳，别回头。
2. **三层高度缓存 + seed + content-keyed memo 体系**（MessageListLayout.swift:123-149、:844-876；MessageListInfrastructure.swift:59-141）——这是 UIKit self-sizing 的创可贴，不是可移植资产；不重写列表就永远用不上，重写时才以「伤疤清单」身份参考。
3. **KaTeX/WKWebView 数学渲染**——OM 自己已弃（死代码，仅 warmUp 残留）。数学真要上，照 OM 的现役答案（SwiftMath 原生 + 调度器）想，但 MP 今天无需求。
4. **cell-per-block 拆分 + 4 种 CellRegistration**（MessageListInfrastructure.swift:21-29；CollectionViewMessageListV3.swift:852-867）——它绑定 diffable 架构存在，脱离那个架构对 MP 的 SwiftUI 列表无意义（MP 的 segmented 渲染已在 view 层做了块拆分，不需列表层配合）。

## §轴外发现

无超出本 lane 的独立发现。两个 lane 内但值得车头留意的点已并入正文：L3（滚动挂起流式——严格说是流式策略不是列表技术）和 OM 的 suspend/resume pending-snapshot 事故链（§OM 换来的新坑族 3，对任何想做「后台继续流式 + 前台挂起 UI」的 lane 都是前置警告）。

## §未查证/推断登记（诚实清单）

- OM `MinisMarkdownParser` 的数学容错函数（:449-511）我只读了签名与注释框架，未逐行读实现；相关结论已降级为「推断（代码结构支撑）」。
- MP macOS 流式路径是否与 iOS 共用 `streamingText` 发布侧——未查证（影响 L2 的落点建议，已在该条内标注）。
- MP 气泡模式逐块 reveal 节奏器（ChatBubbleStyle）本次未目读，引用自车头情报外的子代理初查，标未查证。
- NSCollectionView 在 macOS 的 self-sizing 可行性——未查证（推断），但它只影响「重写代价」论证的强度，不影响「不该重写」的结论方向。
- OM `AssistantBlockView`/`SelectableMarkdownView` 内部（数千行）未深读；本报告对它们的引用仅限于我在 MessageList 三文件与 ChatModels 里目读到的接口面。
