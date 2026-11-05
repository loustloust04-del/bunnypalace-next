# Audit：mac 代码路径的输入模型——触摸假设 vs 指针/键盘

> 2026-09-18 · 🎩(opus5) · **只读审计，未改任何代码**
> 分支：`worktree-mac` `f75132f9`（= 已合进 master 的 `d5955944`，代码同）
> 口径：「mac 路径」= `#if os(macOS)` 分支 + 未被 `#if os(iOS)` 排除的共享代码。平台归属用「往回找最近一个未闭合 `#if`」判定，嵌套处逐个人工核过；文末 §10 列了盲区。
> **只给地形，不给方案。**

---

## ⚠️ 实施推翻的四处（2026-09-18 Sprint 1 落地时逐条查证）

这份是静态读码产物，实施时被代码本身推翻了四条。**引用本报告前先看这一节。**

| # | 报告原话 | 实际 | 为什么漏 |
|---|---|---|---|
| C1 | §3.5「桌面空白：mac 分支是死代码，真正的 `MacDesktopGrid` 空格只有拖源」 | **右键早就有**——`MacDesktopGrid:118,138` 的 `MacShellDragSource(menuItems: editingMenu(...))` → `MacShellDragSource:104-114` 在 `rightMouseDown` 里弹 `NSMenu`（「整理桌面 / 完成」） | 只 grep 了 SwiftUI 的 `.contextMenu`，没算 AppKit 那条路。**浮窗标题行（`FloatingWindow:150` `headerMenu`）同样漏报** |
| C2 | §3.2「7 处 `.swipeActions` 未门控且无右键替代」 | **只有 4 处**。`RegexSettingsTab:203` 在 `#if os(macOS)`(75) 的 `#else`(145) 里、`PersonaSettingsTab:1721` 同理(1662/1664/1742)，两处仅 iOS；`APISettingsTab:403` 紧跟着就有 `#if os(macOS) .contextMenu` | 判据是「命中行**前 12 行**有没有 `#if os(iOS)`」——既看不到更上面开的门，也看不到后面跟的 contextMenu，两头都漏 |
| C3 | §4.5「`ThinkingSheet` 连关闭按钮都没有」 | **有**。它套 `DisclosureSheet` 壳，`DisclosureSheet:22-29` 就是 mac 的关闭钮 | 只看了 `ThinkingSheet.swift` 本身，没跟进它套的壳 |
| C4 | §3.4 / P11「`DesktopGridView` 里 4 处死 mac 分支」 | **6 处**（另有 `:105` 点泳道空白退编辑态、`:233` 组件菜单「整理桌面」） | 手工数漏了两处；清障时用「往回找最近未闭合 `#if`」扫才扫全 |

C1/C3 是**多报问题**（功能其实有），C2 是**多报范围**（7→4），C4 是**少报**（4→6）。
共同的教训：**`grep '.contextMenu'` ≠「有没有右键」**（AppKit `NSMenu` 是另一条路），
**「命中行前 N 行」≠ 平台门控**（要往回找最近一个未闭合 `#if`，还要看后面跟了什么）。

---

## 总览

壳（`ShellStyle` / `MacShellButton` / `VerticalDock` / `TabbedToolPanel` / `PanelChrome` / `MacDesktopGrid` / 缩放把手）**已经相当 Mac 化**——hover 高亮、hover 才露的关闭钮、AppKit 拖源、右键菜单、Esc、光标变形都在。

问题几乎全在**壳里面装的东西**：17 个右栏工具面板、`SidebarView` 的行、`CardFlowView` 的正文与输入条、27 页设置。这些是从 iOS 直接搬过来的共享代码，在 mac 上表现为：**鼠标扫过去什么都不亮、很多次级操作只有滑动或长按能触发、大部分弹层 Esc 关不掉、全局只有 6 个快捷键**。

一个量化对照：

| | 壳（mac 专属文件） | 17 个工具面板（共享） |
|---|---|---|
| `.onHover` | 8 处，覆盖所有交互元素 | **15/17 面板为 0** |
| `.help()` tooltip | 基本齐 | **12/17 面板为 0** |
| 右键菜单 | 齐（组件 / 空格 / tab / dock） | 7/17 有 |

---

## 1. hover

### 1.1 有 hover 的（全部 19 处 `.onHover`）

| 元素 | 位置 | 做什么 |
|---|---|---|
| 所有壳按钮 | `MacShellButton.swift:58` | `MacShellControlSurface` 三态填色（selected / hovered / pressed），带动画 |
| dock 图标 | `VerticalDock.swift:140,167` | 高亮 + 拖排序目标 |
| 工具 tab | `TabbedToolPanel.swift:153,225` | 高亮 **+ 露出关闭钮** |
| 面板标题行 | `PanelChrome.swift:34` | `titleHovered` |
| 面板缩放把手 | `PanelResizeHandle.swift:26,78` | 高亮 + **换光标** |
| 桌面小组件 | `MacDesktopGrid.swift:197` | 高亮 |
| 桌面格子（iPad 侧） | `DesktopGridView.swift:63` | 高亮 |
| 设置窗侧栏 tab / 反馈钮 | `SettingsView.swift:311,361` | 高亮 |
| 楼层切换等 | `MemoryPalaceApp.swift:1125,1206` | 高亮 |
| 记忆面板某一处 | `MemoryPanelView.swift:916` | 单点 |
| 日历面板某一处 | `CalendarPanelView.swift:597` | 单点 |
| 正文某一处 | `CardFlowView.swift:3480` | 单点 |
| 贴纸把手 | `StickerCanvasLayer.swift:509,552` | **换光标**（`resizeLeftRight` / `crosshair`） |

### 1.2 没有 hover 的（高频）

| 元素 | 现状 | 判定 | 影响面 |
|---|---|---|---|
| **对话列表行** `ConversationRow`（`SidebarView:2439`） | 零 hover。选中才有底色 | 触摸假设 | **极高**（每天几十次） |
| 搜索结果各行（`FavoritedBubbleRow` / `ChatHighlightRow` / `DeletedBubbleRow` / `StickerMatchRow` / `MemoryMatchRow` / `ContentMatchRow` 等 9 个 Row） | 零 hover | 触摸假设 | 高 |
| 文件库卡片 / 列表（`FileLibraryPanelView`） | 零 hover，3 个右键菜单 | 触摸假设 | 高 |
| 世界书条目、卡库、贴纸库、读书、单词、话题盒、健康、交易、军机处、有声书、浏览器、终端面板 | **零 hover** | 触摸假设 | 中 |
| 消息气泡 / 正文段落 | 零 hover（只有 `:3480` 一处） | 触摸假设 | 极高 |
| 27 页设置里的行 | 零 hover（靠 `List` 系统样式） | 系统兜底 | 中 |

### 1.3 hover 才显示的次级控件

**全项目只有一处**：工具 tab 的关闭钮（`TabbedToolPanel.swift:208-209`，`opacity(selected || hoveredTab == id ? 1 : 0)` + `allowsHitTesting` 同步）。

其余次级操作的触发方式全是：**常驻按钮**、**右键菜单**、或 **滑动/长按**。没有第二处 hover-reveal。

### 1.4 `NSCursor`（共 7 处）

| 会变光标的 | 不会变光标的（应该变而没变） |
|---|---|
| 面板缩放把手（`PanelResizeHandle.hoverCursor`）<br>浮窗四角/四边（`FloatingWindow:354` `FrameResizePosition`）<br>贴纸缩放把手 / 画笔（`StickerCanvasLayer:510,553`） | **dock 图标**（可拖排序，光标不变）<br>**工具 tab**（可拖出去变浮窗，不变）<br>**桌面小组件**（可拖，不变）<br>**列表行 / 所有可点 icon**（不变——这个符合 mac 惯例，不算问题）<br>**列表与面板之间的分隔线**（`leftWidth` 把手区外的那条线）<br>**链接 / 文件路径**（`CodingSessionDetailView` 点路径开 Finder，光标不变） |

### 1.5 tooltip `.help()`（共 75 处）

| 覆盖好的 | 零覆盖的面板 |
|---|---|
| CodingSessions 全家（5 个文件）<br>`MacShellTuner`（参数台）<br>`PanelChrome` / `MacDesktopGrid`<br>`FileLibraryPanelView`(4) / `MemoryPanelView`(3) / `CardFlowView`<br>`BrowserView`(2) / `WebSearchServicesPage` | 世界书、日历、贴纸库、卡库、读书、话题盒、健康、交易、军机处、有声书、终端、小助手——**12/17** |

---

## 2. 点击目标与密度

### 2.1 壳的实际值 vs 系统惯例

| 元素 | MP 的值 | 定义处 | macOS 对应物 | 判定 |
|---|---|---|---|---|
| 工具 tab 高 | **34** | `ShellStyle.tabHeight` | Safari tab ~28–32、Xcode tab 24 | 略胖，可接受 |
| dock 图标格 | **42**（可调 24…48） | `ShellStyle.dockHit` / `MacShellMetrics.dockItem` | Finder 侧栏行 24–28、Dock 图标另算 | **偏触摸**（42 接近 44） |
| dock 图标间距 | **2**（可调 0…16） | `MacShellMetrics.dockGap` | — | 合理 |
| 标题行高 | **32**（探针量的红绿灯带高） | `MacShellMetrics.titleBarHeight` | = 系统标题栏 | ✅ 已 Mac 化 |
| 标题行图标钮 | **26** 宽，间距 2 | `MacShellMetrics.iconButtonWidth` | toolbar 钮 ~28 | ✅ |
| chip / 紧凑控件高 | 26 | `ShellStyle.chipHeight` | — | ✅ |
| 面板头按钮 | 30 | `ShellStyle.headerButtonWidth` | — | ✅ |
| tab 关闭钮 | 20 | `ShellStyle.closeButtonWidth` | Safari ~16 | ✅ |
| 窗角缩放命中 | 8 | `ShellStyle.cornerHit` | 系统 ~4–6 | ✅ |
| 窗边缩放命中 | 6 | `ShellStyle.edgeHit` | 系统 ~4 | ✅ |
| **`barHeight`** | **44** | `ShellStyle.barHeight` | — | **触摸标准直接写进壳的常量表** |

### 2.2 共享内容里的尺寸

| 元素 | 值 | 位置 | 判定 |
|---|---|---|---|
| **对话列表行** | padding 16/12 → 实高 ≈ **56** | `SidebarView:2528-2529` | Mail 邮件行 ≈ 60 可比，但 Finder / Xcode 是 24 档。**行高本身不算错，错在没有 hover 和密度档** |
| 输入条发送钮占位 | `48 × 44` | `CardFlowView:2013`（**共享，mac 也吃**） | 触摸假设 |
| 贴纸键盘格 | `44 × 44` | `StickerKeyboardPanel:321`（共享） | 触摸假设 |
| 全项目 `44` 硬编码 | **58 处** | — | 抽样 5 处：3 处 iOS-only、2 处共享 |

> 没有任何「紧凑 / 舒适」密度开关。`MacShellMetrics` 的 18 根旋钮只管卡 / 标题栏 / dock，**不管列表行高与面板内间距**。

---

## 3. 触发方式

### 3.1 长按（`onLongPressGesture` / `LongPressGesture`，共 9 处）

| 位置 | 触发什么 | mac 活？ | 影响 |
|---|---|---|---|
| **`DashboardView.swift:58`** | **长按桌面空白 → 进编辑态** | ✅ **活**（整份文件零 `#if os`） | **高**——mac「桌面」页只能长按空白进整理模式，没有右键入口、没有按钮 |
| `CardFlowView:2150`（0.5s） | 语音占位长按 → 起通话 | ❌ iOS-only | — |
| `StickerCanvasLayer`（0.3s） | 贴纸 | 共享（贴纸在 mac 可用） | 中 |
| `Page2DesktopView:58,360` / `Page2FolderView:196` | Page2 编辑态 / 改名 | ❌ iOS-only | — |
| `DesktopGridView:150` | 格子进编辑态 | ❌ 在 `#if os(iOS)` 段内 | — |

### 3.2 滑动操作（`.swipeActions`，共 10 处）—— **最集中的一类触摸残留**

| 文件 | 行 | 被 `#if os(iOS)` 包？ | 附近有 contextMenu 替代？ |
|---|---|---|---|
| `RegexSettingsTab.swift` | 203 | ❌ **没有** | ❌ 没有 |
| `MCPSettingsView.swift` | 177 | ❌ **没有** | ❌ 没有 |
| `APISettingsTab.swift` | 403 | ❌ **没有** | ❌ 没有 |
| `PersonaSettingsTab.swift` | 1721 | ❌ **没有** | ❌ 没有 |
| `StyleManagerView.swift` | 30 | ❌ **没有** | ❌ 没有 |
| `TradingPanelView.swift` | 133 | ❌ **没有** | ❌ 没有 |
| `HealthPanelView.swift` | 473 | ❌ **没有** | ❌ 没有 |
| `ThemeSettingsTab.swift` | 166 | ✅ 有 | ✅ 有 |
| `BookAnnotationDrawer.swift` | 351 | ✅ 有 | — |
| `TerminalToolbarLayoutEditor.swift` | 38 | UIKit，iOS | — |

> **7 处在 mac 上会渲染出来，且没有右键替代**。macOS 的 `List.swipeActions` 只认触控板两指横扫——**接鼠标就彻底够不着**（她主力是 MacBook 触控板，所以不是「不能用」，是「用不上也发现不了」）。

### 3.3 下拉刷新（`.refreshable`，共 8 处）

`SidebarView` 的三处列表刷新（`:737,756,785`）**已被 `#if os(iOS)` 正确门控** ✅。
`SidebarView:1206`（空态小卡）在 `#if os(iOS)` 段里 ✅。
未门控的：`AgoraMentionInboxSheet:34`、`HealthSettingsTab:27`、`WarroomPanelView:136` —— mac 上是死代码（macOS List 不给下拉手势），不产生错觉，但也意味着**这三处在 mac 上没有刷新入口**。

### 3.4 双击

| 位置 | 用途 | 状态 |
|---|---|---|
| `StickerCanvasLayer:276` | 贴纸 | 活 |
| `DesktopGridView:307` `.onTapGesture(count: 2) { restore() }` | 注释写「mac 单击选中、双击恢复（A2a-7）」 | ⚠️ **死代码**——它在 `ToolFaceTap` 里，而 `ToolFaceTap` 整个包在 `#if os(iOS)`（297–382）内，里面的 `#if os(macOS)` 分支在 mac 上根本不编译。mac 的真实路径是 `MacDesktopGrid`，**没有任何 `onTapGesture`** |

**结论：mac 上双击几乎零利用。** 列表行双击不打开、不重命名；小组件双击不恢复；tab 双击不做任何事。

### 3.5 右键（`.contextMenu`，共 51 处）

| 有右键的 | 没有右键的（高频） |
|---|---|
| 对话行（`SidebarView:207`）✅<br>搜索结果三类（`:357,397,432`）<br>标签（`:1462`）<br>消息气泡（`CardFlowView` 5 处 + `ChatBubbleStyle` 3 + `BubbleContextMenuBridge` 3）<br>桌面小组件（`MacDesktopGrid:191`）<br>工具 tab（`TabbedToolPanel:168`）<br>文件库(3)、世界书(2)、读书批注(2)、终端 tab(2)、贴纸库、有声书、军机处、单词(2)、HTML 卡 | **dock 图标**（不能右键关掉 / 改顺序）<br>**桌面空白**（mac 分支是死代码，见 3.4；真正的 `MacDesktopGrid` 空格只有拖源）<br>**记忆面板条目**（0 contextMenu）<br>**日历条目**（0）<br>**卡库条目**（0）<br>**话题盒**（0）<br>**交易 / 健康行**（0，操作只在 swipeActions 里 → 见 3.2）<br>**小助手**（0）<br>**列表槽 / 工具槽的空白区**（没有「新建对话」这类右键） |

---

## 4. 键盘

### 4.1 全局快捷键全清单（`.commands` 里注册的，共 6 条）

| 键 | 功能 | 位置 |
|---|---|---|
| `⌥⌘S` | 开关侧栏 | `MemoryPalaceApp:992` |
| `⌥⌘T` | 开关工具面板 | `:996` |
| `⌘+` / `⌘-` / `⌘0` | 正文字号 | `:1013,1020,1025` |
| `⇧⌘D` | 反馈手势 | `:1032` |
| `⌘?` | 帮助窗 | `ManualView:78` |
| `⌘,` | 设置窗 | 系统自动挂 `Settings` scene |

### 4.2 局部快捷键（挂在特定视图上，视图不在就没有）

`⌘F` 会话内搜索（`CardFlowView:808`）· `⌘K` 编程会话全文搜 / `⌘R` 刷新（`CodingSessionSidebarList:71,76`）· `⌘S` 文件库保存 / `⌘G` `⇧⌘G` 查找下/上一个（`FileLibraryPanelView`）· 贴纸选中时 `⌘C` `⌘V` `Delete` `[` `]`（`StickerCanvasLayer`）· 单词卡评分键（`VocabStudyView`）

### 4.3 缺口（高频操作对照）

| 高频操作 | 现在怎么做 | 有快捷键吗 |
|---|---|---|
| **新建对话** | 点侧栏按钮 | ❌ 无（`⌘N` 空着——`CommandGroup(replacing: .newItem) { }` 把系统的新建**整组删掉了**，`MemoryPalaceApp:987`） |
| **删除对话** | 右键菜单 | ❌ 无 |
| **重命名对话** | 右键菜单 | ❌ 无（也没有双击改名） |
| **切换楼层** | 侧栏菜单 | ❌ 无 |
| **全局搜索** | 点搜索框 | ❌ 无（`⌘F` 只管会话内；`⌘K` 只管编程会话） |
| **发送消息** | 点按钮 / `↩` | `↩` 有（`CardFlowView:2086`，`⌘↩` 分支见 4.5） |
| **打开某个工具** | 点 dock | ❌ 无（`⌘1…⌘9` 全空） |
| **关闭当前 tab** | 点 × / 右键 | ❌ 无（`⌘W` 空着，且会被系统解释成关窗） |
| **在对话间上下走** | 点 | ❌ 无 |

### 4.4 焦点管理

- `@FocusState` **22 处，全部是「某个输入框要不要聚焦」**，没有一处用于面板间导航。
- `.focusable()` **只有 2 处**（`DesktopGridView:349` / `MacDesktopGrid:74`，都是为了让桌面格子能收 Esc）。
- **没有 `focusSection` / `defaultFocus` / `FocusedValue`**。
- ⇒ **Tab 键不能在四个槽之间走**。系统默认的 key-view loop 只会在原生控件（`TextField` / `List` / `Button`）之间跳，自绘的 `MacShellButton` 全是 SwiftUI `Button`（可进 loop，但顺序不可控、没有分区）。

### 4.5 Esc

| 能关的 | 关不掉的 |
|---|---|
| 侧栏某处（`SidebarView:201` `onExitCommand`）<br>编程会话搜索面板（`CodingSessionSearchPanel:76`）<br>桌面整理编辑态（`MacDesktopGrid:84` / `DesktopGridView:354`）<br>10 个带 `.cancelAction` 的 sheet（CC 指南、Markdown 弹层、贴纸编辑、参数台、编程会话的 4 个 pane…） | **179 处 `.sheet(` 里只有 10 处带 `cancelAction`**。抽样 mac 上会开的：<br>`BranchMapSheet` ❌（只有「关闭」按钮）<br>`ThinkingSheet` ❌（连关闭按钮都没有）<br>`GlobalExportSheet` ❌<br>`AttachmentPreviewSheet` ❌<br>`TagPickerPopover`（改项目）❌ |

> macOS 的 SwiftUI `.sheet` **不会**自动响应 Esc——必须有一个 `.keyboardShortcut(.cancelAction)` 的按钮。所以上面这些在 mac 上只能用鼠标点关闭。

### 4.6 列表里的方向键

**只有一处**：`CodingSessionSearchPanel:27,31` 的 `onKeyPress(.upArrow/.downArrow)` 在搜索结果里移动。

对话列表、搜索结果、文件库、记忆、世界书、卡库……**方向键一律无效**（它们是 `ScrollView` + `ForEach`，不是 `List(selection:)`，系统也接管不了）。

### 4.7 修饰键 + 点击

**全项目只有 1 处涉及修饰键**：`CardFlowView:2087` `press.modifiers.contains(.command)`——而且是键盘的 `⌘↩`，不是点击。

**没有任何 ⇧-click / ⌘-click / ⌥-click 处理。** 唯一的多选是记忆面板，走的是 `List(selection:)` 让系统原生实现 ⌘/⇧ 连选（`MemoryPanelView:430` 注释明确写了「mac 用 List 原生 ⌘ / ⇧ 连选，不走 EditMode」）✅——**这是全项目唯一做对的多选**。对话列表、文件库、贴纸库都不能多选。

---

## 5. 拖拽

### 5.1 两套拖源并存

| 机制 | 用在哪 | 启动方式 |
|---|---|---|
| **`MacShellDragSource`**（AppKit `NSView` + `beginDraggingSession`） | dock 图标排序（`VerticalDock:108`）<br>工具 tab 拖出/换位（`TabbedToolPanel:195`）<br>浮窗标题拖回停靠（`FloatingWindow:150`）<br>桌面小组件 / 空格（`MacDesktopGrid:118,138,166`） | **按下即拖**（AppKit 标准阈值），有拖影、有结束回调 ✅ |
| **SwiftUI `DragGesture`** | 面板宽度把手（`PanelResizeHandle:29`，`minimumDistance: 2`）<br>浮窗移动（`FloatingWindow:261`，`minimumDistance: 3`）<br>浮窗缩放（`:134,273`，`minimumDistance: 0`）<br>面板标题拖动（`PanelChrome:109`，`minimumDistance: 3`）<br>窗口拖动（`ContentView:1120` `WindowDragGesture()`）✅ 系统的 | 按下即拖，阈值 0–3pt ✅ |
| **SwiftUI `.onDrag`**（16 处） | 侧栏对话拖进标签（`SidebarView:1449`）<br>贴纸库（`StickerLibraryView:333,418`）<br>Dashboard 组件（`DashboardView:189`）<br>贴纸键盘（`StickerKeyboardPanel:353`）<br>Page2（iOS） | **iOS 语义：按住一会儿才拎起来**。在 mac 上 `.onDrag` 映射到 AppKit 拖放，实际是按下即拖，但**没有拖影定制、没有结束回调**（这正是 `ToolTabDrag.swift:20` 注释说的「mac 拖源由 `MacShellDragSource` 提供结束回调；iPad 保留原 provider」） |

**结论**：壳的拖拽已经全部 Mac 化；**内容区的拖拽（对话→标签、贴纸库、Dashboard 组件）还是 `.onDrag`**，没有拖影和结束回调。

### 5.2 drop 反馈

- 只有**高亮**：`panelLayout.macDropTarget` + `ShellDropHighlight`（`ContentView:1563` 等）。
- **光标不变**（没有 `NSCursor.dragCopy` / `.dragLink`）。
- 拖放取消**无回调**（memory `feedback_contextmenu_kills_draggesture` 记过：「拖放取消无回调不能存状态」）。

---

## 6. 滚动与手势

### 6.1 多指手势

| 手势 | 位置 | mac 活？ | 鼠标用户怎么办 |
|---|---|---|---|
| **pinch 缩放记忆图谱** | `MemoryGraphView:104` `withGraphMagnifyGesture` | ✅ **活**（`MemoryPanelView:205` 在 mac 面板里） | ❌ **没有任何替代**——没有 `+/-` 钮、没有 `⌘+`、没有滚轮缩放 |
| pinch 裁头像 | `AvatarCropSheet:147` `MagnifyGesture` | ✅ 活（同文件有 mac 分支） | ❌ 无替代 |
| pinch / rotate 贴纸 | `StickerGestureOverlay`（`UIPinchGestureRecognizer` / `UIRotationGestureRecognizer`） | ❌ UIKit，iOS-only | mac 走 `StickerCanvasLayer` 的把手拖拽 ✅ |

### 6.2 横向滚动（23 处 `ScrollView(.horizontal)`）

mac 路径上会遇到的：附件条（`CardFlowView:1531,2567`）、标签条（`SidebarView:1337`）、代码块（`MessageSegmentsView:429`）、搜索来源 chip、文件库、编程会话统计图、终端 tab 条（`PixelTerminalHeader:231`）、单词笔记。

- 这些在 macOS 上**能用**：触控板两指横扫、或 `⇧` + 滚轮。
- 但**全部 `showsIndicators: false`** —— 23/23 都关了滚动条。在 mac 上没有滚动条＝**看不出还有内容**（iOS 上靠惯性和弹跳暗示，mac 没有）。
- 已知相关坑：memory `feedback_horizontal_scrollview_button_swallowed`（横向 ScrollView 里 Button 被吞）。

---

## 7. 文本选择

`.textSelection(.enabled)` 共 **41 处**。

| 能选的 | 不能选的 |
|---|---|
| **聊天正文**：mac 走 fork 渲染器，`MessageSegmentsView` 6 处 + `ChatBubbleStyle:502` + 「选择文本」弹层（`CardFlowView:3308`），且 ms0911 给 mac 做了**段内拖选 + 右键收生词/引用/划线** ✅ | **跨段选择**（fork 每 block 一个 text view，选区出不了 view——`roadmap §5` 债表已登记，她 09-13「先不管」） |
| 世界书(2)、记忆(2)、日历、军机处(5)、小助手(2)、编程会话(2)、读书、导入导出、设置若干 | **对话列表的标题 / 摘要**（不能选） |
| 思考层（`ThinkingSheet:49`）、frontmatter 卡 | **文件库的文件名**、**卡库**、**贴纸库**、**话题盒**、**交易 / 健康的数字** |

---

## 8. 共享代码污染清单

「触摸假设写在共享代码里、iPad 宽屏也在吃」的逐条。最后一列是**隔离手段的判据**：

- `#if os` —— 行为在两个平台上**本质不同**（手势 vs 指针）
- `widePanelMode` —— iPad 横屏和 mac **应该一样**，只跟窄屏 iPhone 分
- 加能力 —— 不用删 iOS 的，只是 mac 多一条路

| # | 污染点 | 位置 | iPad 宽屏也吃？ | 建议隔离手段 |
|---|---|---|---|---|
| P1 | **7 处 `.swipeActions` 未门控** | Regex / MCP / API / Persona / StyleManager 设置页 + Trading / Health 面板 | ✅ 吃（iPad 上滑动是对的） | **加能力**：保留 swipe，补右键 + 常驻按钮 |
| P2 | **长按进桌面编辑态** | `DashboardView:58`（整份文件零 `#if os`） | ✅ 吃（iPad 上长按是对的） | **加能力**：mac 补右键 / 按钮 |
| P3 | **`ShellStyle.barHeight = 44`** | `ShellStyle.swift:39` | ✅ 吃 | `#if os`（或让 `MacShellMetrics` 接管） |
| P4 | **输入条 `48×44` 占位** | `CardFlowView:2013` | ✅ 吃 | `#if os` |
| P5 | **9 个列表 Row 零 hover** | `SidebarView:2439–2900` | ✅ 吃（iPad 接妙控板也想要 hover） | **`widePanelMode`**——两边都该有 |
| P6 | **15/17 工具面板零 hover + 12/17 零 tooltip** | 各 `*PanelView.swift` | ✅ 吃 | **`widePanelMode`** |
| P7 | **23 处横向滚动全关滚动条** | 见 §6.2 | ✅ 吃 | `#if os`（mac 显示，iOS 保持隐藏） |
| P8 | **pinch 是记忆图谱唯一的缩放入口** | `MemoryGraphView:104` | ✅ 吃 | **加能力**：补按钮 / 滚轮，两端都受益 |
| P9 | **169 个 sheet 无 `cancelAction`** | 全局 | iPad 有下滑关闭，不算缺 | `#if os` 或统一包一层 mac sheet 容器 |
| P10 | **`.onDrag` 内容区拖拽无拖影/无结束回调** | `SidebarView:1449` / `StickerLibraryView` / `DashboardView:189` | ✅ 吃 | `#if os`（mac 换 `MacShellDragSource`，路已铺好） |
| P11 | **死的 mac 分支**（`#if os(macOS)` 套在 `#if os(iOS)` 里） | `DesktopGridView:297–382`（4 处：305 / 321 / 347 / 363） | — | **清掉**——注释在描述不存在的行为（「mac 双击恢复」「mac 空格右键整理桌面」），照它写方案会翻车 |
| P12 | **3 处 `.refreshable` 未门控** | `AgoraMentionInboxSheet:34` / `HealthSettingsTab:27` / `WarroomPanelView:136` | ✅ 吃 | `#if os` + mac 补刷新钮（现在 mac 上无刷新入口） |

---

## 9. 前 15 项（每天碰到多少次 × 修起来多难）

难度口径：**S** = 单点加个 modifier；**M** = 一个文件里成体系改；**L** = 跨文件 / 要定设计。

| # | 事 | 频次 | 难度 | 为什么排这儿 |
|---|---|---|---|---|
| 1 | **对话列表行零 hover** | 每天几十次 | **S** | 一个 `.onHover` + 一层底色。mac 上"鼠标扫过去没反应"是最刺眼的单点，而且正是她说的「对话列表在 mac 全屏下照抄 iOS 很诡异」的一部分 |
| 2 | **7 处 swipeActions 没有右键替代** | 每次改 API / Prompt / 正则都撞 | **S** | 每处补一个 `.contextMenu` 复用同一组 Button。接鼠标时是**功能不可达**，不是难看 |
| 3 | **`⌘N` 被 `CommandGroup(replacing: .newItem) { }` 整组删掉，新建对话无快捷键** | 每天十几次 | **S** | 一行的事；现在连系统默认都被拿掉了 |
| 4 | **工具面板零 hover / 零 tooltip（15 & 12 / 17）** | 每天几十次 | **M** | 面多，但每面是同一套改法；可先挑记忆 / 文件库 / 世界书三个高频 |
| 5 | **大部分 sheet Esc 关不掉** | 每天十几次 | **S–M** | 单个是一行 `.keyboardShortcut(.cancelAction)`；要全覆盖得扫 179 处 |
| 6 | **列表方向键不能动选中** | 每天十几次 | **L** | 现在是 `ScrollView + ForEach`，要么换 `List(selection:)`（动数据流），要么自己接 `onKeyPress` + 焦点。记忆面板已经证明 `List(selection:)` 这条路在 mac 上是通的 |
| 7 | **双击全局无用**（列表不开、不改名；组件不恢复） | 每天几次 | **S–M** | 单点 `.onTapGesture(count: 2)`，但要先决定双击语义（打开？改名？），且要清掉 P11 的死代码免得照着抄 |
| 8 | **dock 图标 / 工具 tab / 小组件拖动时光标不变** | 每天几次 | **S** | `PanelResizeHandle.hoverCursor` 已经有现成的封装，直接套 |
| 9 | **长按才能进桌面编辑态**（`DashboardView:58`） | 每周几次 | **S** | 补一个右键「整理桌面」；注意 P11 那段死代码里已经写过这个菜单，可以搬活的那份 |
| 10 | **没有 ⇧/⌘ + click 多选**（对话、文件库、贴纸库） | 每周几次 | **L** | 要动选择模型；记忆面板的 `List(selection:)` 是样板 |
| 11 | **横向滚动区不显示滚动条** | 每天几次 | **S** | 23 处统一改 `showsIndicators`，但要 `#if os` 免得动 iOS |
| 12 | **记忆图谱只能 pinch 缩放** | 每周几次 | **M** | 补缩放钮 / 滚轮；鼠标用户现在**完全用不了这个功能** |
| 13 | **Tab 键不能在四槽间走 / 无焦点分区** | 每天（如果习惯键盘） | **L** | 要引 `focusSection` + `FocusedValue`，和 A4 多窗口那条线撞（`IPadPanelLayout.shared` 单例） |
| 14 | **常用操作无快捷键**（删除 / 重命名 / 切楼层 / 开工具 / 关 tab） | 每天十几次 | **M** | 要先定一张键位表（X28 在 roadmap §5 排着），逐个挂 |
| 15 | **内容区 `.onDrag` 无拖影无结束回调** | 每周几次 | **M** | `MacShellDragSource` 现成，换过去即可；难在每个拖源的 payload 不同 |

**没进前 15 但记一笔**：`ShellStyle.barHeight = 44` 和输入条 `48×44` 占位（改动小但视觉影响小）；跨段选择（她已裁「先不管」）；`dockItem` 42 偏触摸（但有旋钮可调，她自己就能改）。

---

## 10. 审计方法与盲区

**怎么判的**：全仓 `grep` + 对每个命中往回找最近一个未闭合 `#if`。嵌套 `#if` 处（`DesktopGridView` / `CardFlowView` 的输入条段）逐行人工核过，并因此发现了 P11 那段死代码。

**盲区，别当成"没有"**：
1. **没有跑过 app**。这份全部来自静态读码——「hover 不亮」是"代码里没写 `.onHover`"，不是"我看着它不亮"。系统控件（`List` / `Button` / `TextField` 的原生样式）自带的 hover 与焦点行为不在 grep 范围内，**实际观感会比这份报告好一些**。
2. **`.swipeActions` 在 macOS 26 上的真实行为没实测**。我按"触控板两指横扫可触发、鼠标不可"写的，这是 SwiftUI 的既有行为，但没在这台机器上验过。
3. **系统 key-view loop 的实际顺序没测**。Tab 键能走到哪些控件、顺序如何，只能实跑看。
4. **27 页设置只抽样看了带 `swipeActions` 的那几页**，没有逐页过 hover / 快捷键。
5. `.help()` 的 75 处只统计了文件分布，没核每一处挂在哪个控件上——可能有挂在容器上、实际不显示的。
6. 尺寸对照里的「Finder / Xcode 对应值」是我按记忆写的常见值，没有实测取样。
