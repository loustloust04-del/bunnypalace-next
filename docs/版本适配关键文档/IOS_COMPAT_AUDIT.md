# iOS 兼容性体检: 记忆宫殿

日期: 2026-06-12
目标: iOS 18 最低部署目标（暂定）
扫描范围: 全项目 iOS 相关代码（170 个 Swift 文件，其中 160 个编入 iOS target）
扫描方法:
- **路径 A（编译器，ground truth）**: 把 `IPHONEOS_DEPLOYMENT_TARGET` 压到 18.0 真编译了两轮（xcodebuild + 手工复刻 swift-frontend 全模块 `-typecheck`），拿到**编译器盖章的完整 availability 错误清单**——不是 grep 猜的
- **路径 B（SwiftUI API 审计）**: 对 iOS 17/18/26 三代 API 逐个 grep + 误报剔除（`Tab(` 33 处命中实为 `PersonaSettingsTab(` 子串；早期 `onScrollGeometryChange` 35 处计数有误，实际 3 处）
- **路径 C（SwiftData）**: `#Index` 12 个 @Model 全清点，`#Expression`/`VersionedSchema` 零使用确认
- **路径 D（平台/框架）**: 239 处 `#if os(iOS)` / 153 处 `#if os(macOS)` / 10 处 `#if canImport` 对称性审查 + 5 个 SPM 依赖的 Package.swift 最低版本逐个核实

> ⚠️ 任务书勘误：**iOS 19 不存在**。Apple 在 WWDC25 把版本号从 18 直接跳到 26（与 macOS 26 / Xcode 26 对齐）。所以部署目标的真实选项只有 17 / 18 / 26 三档，不存在 19-25 的中间档。

## 概要

结论比预期干净得多：**iOS 18 上编译失败的只有 28 处，且 100% 是 Liquid Glass 一个家族**（26 处 `.glassEffect()` + 1 处 `.buttonStyle(.glass)` + 1 处 `UIGlassEffect`，分布在 16 个文件）。除此之外**没有任何**其他 API 挡路——`#Index`、`onScrollGeometryChange`、`sensoryFeedback`、全部 5 个 SPM 依赖，在 iOS 18 下全部编译通过（编译器验证，非推测）。

原因是结构性的：两个 target 共用同一份源码，`#if os(iOS)` 之外的代码必须在 macOS 14（≈iOS 17 API 时代）编译通过，所以新 API 风险天然被压缩进 iOS 分支里；而 iOS 分支里除了 glass，其余全是 iOS 17/18 时代的 API。

工程量级评估：**一个兼容 shim 文件 + 28 处机械替换 + 真机/模拟器视觉走查，1-2 天**。真正的隐性成本不在代码，在**测试债**：整个 iOS 键盘/手势/分页体系（PagingViewController、Route C child HC、键盘避让数学）只在 iOS 26 真机上调通过，iOS 18 是另一套系统行为，需要一轮专门的回归（家里所有设备都是 iOS 26.x，只能靠模拟器 + 找外部测试者）。

## 版本边界速查

| API / 功能 | 最低 iOS 版本 | 项目中使用处数 | 有无 fallback | 验证方式 |
|------------|-------------|--------------|-------------|---------|
| `.glassEffect(_:in:)` | **26.0** | 26 处 / 15 文件 | ❌ 无，裸用 | 编译器报错原文 |
| `.buttonStyle(.glass)` | **26.0** | 1 处（ScrollToBottomButton:22） | ❌ 无 | 编译器报错原文 |
| `UIGlassEffect` | **26.0** | 1 处（CCTerminalPanelView:180） | ❌ 无 | 编译器报错原文 |
| `onScrollGeometryChange` | 18.0 | 3 处（全在 CardFlowView） | 不需要 | 18.0 typecheck 通过 |
| SwiftData `#Index` | 18.0 | 12 个 @Model | 不需要（iOS 侧） | 18.0 typecheck 通过 |
| `onGeometryChange` | 18.0（官方回部署到 16.0）[待验证: 回部署下限] | 2 处 | 不需要 | 18.0 typecheck 通过 |
| `sensoryFeedback` | 17.0 | 16 处 | 不需要 | 18.0 typecheck 通过 |
| `contentMargins` | 17.0 | 22 处 | 不需要 | 同上 |
| `containerRelativeFrame` | 17.0 | 8 处 | 不需要 | 同上 |
| `scrollTargetBehavior` | 17.0 | 9 处 | 不需要 | 同上 |
| `@Observable` / `@Bindable` | 17.0 | 116 / 7 处 | 不需要 | 同上 |
| SwiftData 本体 | 17.0 | 全局 | - | - |
| VariableBlur（SPM） | 13.0 | 2 文件（CardFlowView/ContentView 渐变模糊） | 不需要 | Package.swift 实读 |
| Grape（SPM） | 17.0 | - | 不需要 | Package.swift 实读 |
| MarkdownUI（SPM） | 15.0 | assistant 气泡全局 | 不需要 | Package.swift 实读 |
| SwiftTerm（SPM） | 14.0 | CC 终端 | 不需要 | Package.swift 实读 |
| ZIPFoundation（SPM） | 9.0 | 导入导出 | 不需要 | Package.swift 实读 |

注：项目**没有用** iOS 26 的其他新 API——`ToolbarSpacer`、`tabViewBottomAccessory`、`scrollEdgeEffectStyle`、`backgroundExtensionEffect`、`GlassEffectContainer`、`matchedTransitionSource`、新 `Tab` 语法、`MeshGradient`、`ScrollPosition` 类型，全部 0 命中（grep 确认）。glass 是唯一的 26 依赖。

## 🔴 编译失败（iOS 18 编译不过）— 共 28 处，一个家族

以下清单为编译器输出原文（`swift-frontend -typecheck -target arm64-apple-ios18.0-simulator`，全模块 160 文件一次性 typecheck），非 grep 推测。

### [C-1] `.glassEffect()` × 26 处 — 全 app 玻璃视觉语言
- **位置**（26 处，全部在 `#if os(iOS)` 内，零 `@available` 保护）:

  | 文件 | 行号 | 所属功能 | 影响范围 |
  |------|------|---------|---------|
  | `Views/CardFlowView.swift` | 1060, 1592 | 聊天输入框玻璃 + 模型切换胶囊 | **核心路径** |
  | `Views/ContentView.swift` | 624, 644, 736 | 气泡模式顶栏头像胶囊（最近刚做的 X-chat 式头像框） | **核心路径** |
  | `Views/SidebarView.swift` | 150, 166 | 侧栏顶部胶囊 + 圆钮 | **核心路径** |
  | `Views/PinnedMessageBar.swift` | 45 | 置顶消息条 | 核心路径 |
  | `Views/ToolBarView.swift` | 96 | 工具栏胶囊 | 核心路径 |
  | `Views/GlassBackButton.swift` | 18 | **全 iOS 复用的统一返回/关闭键** | 核心路径 |
  | `Views/AttachmentPreviewSheet.swift` | 59, 69, 101, 154 | 附件预览操作钮 | 次要功能 |
  | `Views/MemoryPanelView.swift` | 36 | 记忆面板按钮 | 次要功能 |
  | `Views/PhotoStripPanel.swift` | 47 | 照片条 | 次要功能 |
  | `Views/StickerKeyboardPanel.swift` | 117, 170 | 贴纸键盘面板 | 次要功能 |
  | `Views/PersonaSettingsTab.swift` | 2489 | 设置页自定义 overlay 返回键 | 次要功能 |
  | `Views/Web/MiniBrowserView.swift` | 223, 235, 324 | 内置浏览器工具钮 | 边缘功能 |
  | `Views/Web/HTMLArtifactCardView.swift` | 144, 164, 176, 205 | HTML artifact 卡片钮 | 边缘功能 |

- **使用的 API**: `glassEffect(_:in:)` (iOS 26.0+)，参数变体：`.regular.tint(色).interactive()`，shape 用了 `.circle` / `.capsule` / `.rect(cornerRadius: 20)` / 默认 四种
- **上下文**: 这是 iOS 端整套视觉语言——按钮、胶囊、输入框、返回键全是玻璃。不是点缀，是皮肤。
- **降级选项**:
  - **方案 A（推荐评估）: 兼容 shim** — 写一个 `View.compatGlass(tint:in:interactive:)` 扩展：`if #available(iOS 26.0, *)` 走真 glassEffect，else 走 `.background(.ultraThinMaterial, in: shape)` + tint overlay + 细描边。28 处机械替换。— 难度 🟢（shim 本体 ~60 行 + 替换半天），效果保真度 **中**（毛玻璃有模糊和半透明，但没有液态玻璃的折射/高光/形变；在 iOS 18 的系统语境里反而是"原生正确"的样子）
  - **方案 B: 每处手写 `if #available` 分支** — 难度 🟡（28 处 × 两分支，View body 里要 `@ViewBuilder` 化），无收益，纯粹比方案 A 多写代码。不建议。
  - **方案 C: 整体放弃玻璃改 material（26 也不用 glass）** — 难度 🟢，但 iOS 26 用户的视觉倒退，违背"保留 .interactive() 玻璃视觉"的既有决策（roadmap 2026-04-19）。不建议。
- **建议**: 方案 A 几乎无悬念。唯一要粟粟拍板的是 **fallback 的视觉规格**（material 种类、描边、tint 透明度），建议先在一两个组件上试出满意的配方再批量铺。

### [C-2] `.buttonStyle(.glass)` × 1 处
- **位置**: `Views/ScrollToBottomButton.swift:22`
- **使用的 API**: `GlassButtonStyle` (iOS 26.0+)
- **上下文**: 回到底部按钮。文件头注释明确记录了为什么必须用官方 `.glass` 而不是 `.glassEffect + .plain`（后者在 iOS 26 会吞 hit test，是踩过的坑）。
- **降级选项**:
  - 方案 A: shim 里加一个 `compatGlassButtonStyle`——26 走 `.glass`，18 走自定义 ButtonStyle（material 圆底 + pressed 态 opacity）— 难度 🟢，保真度中
  - 方案 B: 18 直接 `.bordered` — 难度 🟢，保真度低（样式突兀）
- **建议**: 方案 A，跟 C-1 同一个 shim 文件。**注意**：iOS 26 的"glass 层吞 tap"问题在 iOS 18 的 material fallback 上不存在，fallback 分支不需要也不能照搬那些 workaround。

### [C-3] `UIGlassEffect` × 1 处（UIKit 层）
- **位置**: `Views/CCTerminalPanelView.swift:180`
- **使用的 API**: `UIGlassEffect` (iOS 26.0+)，挂在 `UIVisualEffectView` 上
- **上下文**: CC 终端面板的悬浮药丸。注释记录了换它的原因（systemThinMaterial 在深色终端上发灰"看不见玻璃"）。
- **降级选项**:
  - 方案 A: `if #available(iOS 26.0, *) { UIGlassEffect() } else { UIBlurEffect(style: .systemThinMaterial) }` — 难度 🟢（3 行），保真度中（会回到"发灰"的旧观感，但功能完整）
  - 方案 B: 18 分支用 `.systemUltraThinMaterialDark` 缓解发灰 — 难度 🟢，保真度中高
- **建议**: 简单，方案明确（B 略优于 A）。

## 🟡 运行时崩溃风险

**未发现版本相关的运行时崩溃点。** 依据：Swift 的 availability checking 是编译期强制的，上面 28 处编译错误修掉之后，不存在"编译过了但调用 iOS 18 不存在的方法"的残留面（项目没有用 `performSelector` / 字符串反射调 API 的代码）。

两个非崩溃但要点名的运行时注意项：

### [R-1] SwiftData 在 iOS 18.0 上的行为差异 [待验证]
- **上下文**: 项目的 SwiftData 用法（单 container、`@Attribute(.unique)`、`externalStorage`、12 个 `#Index`）全部是 iOS 18 的 API 面，**编译没问题**。但 SwiftData 的运行时实现在 18.0 → 18.x → 26 之间修过大量 bug（尤其 unique 约束和关系处理），项目从未在 18.x 运行时上跑过。
- **不确定原因**: 没有 iOS 18 真机/没跑过，无法引用实测；Apple 不公开 SwiftData 运行时的版本差异清单。
- **建议**: 适配时在 iOS 18.x 模拟器上用真实规模数据（20 万 MessageNode 级）跑一轮导入 + 搜索 + 楼层切换。已知的 P0-1 upsert 偷数据问题（CODE_REVIEW）在 18 上同样存在且行为可能更不可预测。

### [R-2] 内存红线在 iOS 18 老设备上更紧
- 见下方「iOS 专项风险 → 内存压力」。不是版本 API 问题，是"能跑 iOS 18 而跑不了 26 的设备恰好是内存最小的那批"（iPhone XS/XR 4GB）。

## 🔵 行为差异（能跑但表现不同）

### [B-1] iOS 26 专属 hit-test workaround 在 18 上是无效但无害的死逻辑
- **位置**: `Views/ScrollToBottomButton.swift:5-8`（注释记录的 glass 吞 tap 坑）、`Views/PinnedMessageBar.swift:43`（"不加 .interactive()：iOS 26 的 interactive glass 层会吞 tap"）、`Views/CardFlowView.swift:1593`（"S1 fix: glassEffect .interactive() 在真机上 tap-through 有时序延迟"）
- **差异**: 这三处的设计决策（用 onTapGesture 不用 Button、不加 .interactive()）都是为 iOS 26 glass 层的怪癖让路。fallback material 没有这些怪癖，18 上这些权衡变成"没必要但不伤人"。
- **用户可感知**: 否。列出来是为了防止适配时"顺手把 workaround 拆了"——**26 分支必须原样保留**。

### [B-2] 系统观感整体回到 18 时代
- **差异**: 键盘、sheet、context menu、系统控件在 iOS 18 是扁平风，26 是液态玻璃。app 自己的 fallback material 风格在 18 语境里是协调的，但和 26 上的同一 app 视觉不一致。
- **用户可感知**: 是（跨设备对比时）。属于接受成本，不是 bug。

### [B-3] 玻璃 tint hack 在 material 上的视觉漂移
- **位置**: `Views/PhotoStripPanel.swift:47`、`Views/StickerKeyboardPanel.swift:117,170` 用了 `tint(Color.black.opacity(0.01))` 这种"几乎透明的 tint"来触发 glass 的特定渲染路径
- **差异**: 这个 hack 在 material fallback 上没有意义（material 不需要 tint 触发），直接照搬参数会得到和 26 不同的灰度。fallback 配方要单独调，不能参数平移。
- **用户可感知**: 是（细微）。shim 设计时把 tint 语义分开处理即可。

### [B-4] 键盘/手势/分页体系从未在 iOS 18 上验证过 ⚠️ 这是真正的大头
- **上下文**: iOS 端最复杂的三块——PagingViewController 分页架构、嵌套 UIHostingController 键盘避让（手动 observer + additionalSafeAreaInsets）、贴纸手势系统（SingleFingerPan 子类化、_UIRelationshipGestureRecognizer simultaneously workaround）——全部是在 iOS 26 真机上逐坑调通的（项目积累了 20+ 条相关教训）。
- **差异**: 这些代码用的 API 在 18 上全部存在（编译已证明），但键盘通知时序、safe area 注入行为、私有手势识别器（`_UIRelationshipGestureRecognizer` 是 iOS 私有实现，版本间行为无契约）在 18 上**不保证同样的行为**。
- **用户可感知**: 如果有差异，感知会很强（键盘遮输入框 / 手势死锁级别）。
- **建议**: 这不是改代码项，是**测试预算项**。适配计划里要留一轮 iOS 18 模拟器（键盘时序在模拟器可测）+ 至少一台 iOS 18 真机（手势必须真机）的专项回归。家里设备全是 26.x（roadmap 实测记录），真机渠道要提前想（TestFlight 外部测试者里找 iOS 18 用户 / 二手 XR）。

## ⚪ 已有保护但需审查

### [G-1] 全项目唯一一个 `@available`：FlowLayout
- **位置**: `Views/FlowLayout.swift:6` — `@available(iOS 16.0, macOS 13.0, *)`
- **保护方式**: 声明级 @available
- **fallback 质量**: 无 fallback 也不需要——两个平台的部署目标（14.0 / 26.0→18.0）都远高于标注值，这是个遗迹注解，无风险。

### [G-2] `#if os(iOS)` 平台守卫的"空心 fallback"（继承 CODE_REVIEW P1-15 / P1-19）
- **位置与现状**（这些在 iOS 26 上就坏着，iOS 18 适配不新增也不解决，但"iOS 適配"语境下必须列入）:
  - `Views/PersonaSettingsTab.swift:287-299` — `exportPreset` 函数体整体 `#if os(macOS)`，iOS 按钮照常可点 = no-op
  - `Views/DataSettingsTab.swift:378-380,449-452` — iOS 批量导出按钮可点、实现是裸 `return`
  - `Views/ExportOptionsSheet.swift:148-152` — iOS 分支把文件写进 tmp 后没接 ShareSheet，导出黑洞
- **fallback 质量**: 形式上有平台分支，实质上 iOS 分支是空壳。**这三处是"iOS 用户点了没反应"清单，优先级应排在 glass 适配同批或更前**（glass 不修只是丑，这三个不修是功能欺骗）。

### [G-3] `#Index` 的条件编译方向反了（继承 CODE_REVIEW P1-4）
- **位置**: `Models/Conversation.swift:7,84,197` 等全部 12 个 @Model
- **保护方式**: `#if os(iOS)`
- **审查结论**: 对 iOS 18 目标**正好不用动**（`#Index` 是 18.0 API，编译器证实）。真正吃亏的是 macOS 14 主平台（20 万行无索引）——那是另一个 worktree 的事，但如果未来把条件改成 `#if os(iOS) || os(macOS)`+macOS 15 检查，注意 `#Index` 是宏不能用运行时 `if #available` 包，只能整个 schema 编译期二选一。

## 条件编译现状总结

- `#if os(iOS)`: **239 处**（重灾区：CardFlowView 38、PersonaSettingsTab 16、SidebarView 15、ContentView 14、ThemeEditorView 12、APISettingsTab 11）
- `#if os(macOS)`: **153 处**
- `#if canImport(...)`: **10 处**（UIKit 6、HealthKit 3、UniformTypeIdentifiers 1）——HealthService 用 canImport(HealthKit) 是对的（macOS 也有 HealthKit 但无数据源，靠内部 stub）
- `@available` / `#available`: **1 处**（FlowLayout，遗迹）——意味着**项目从未做过运行时版本分支**，全部是编译期平台分支。iOS 18 适配会引入项目第一批 `if #available(iOS 26.0, *)`，建议全部收口在一个 shim 文件里，不要散落
- **不对称**: macOS→iOS 方向有 3 处空心实现（见 G-2）；iOS→macOS 方向有 1 处已知（ScrollToBottomButton 的 glass 注释承认 macOS 侧用普通样式）
- **嵌套混乱**: 无嵌套 `#if` + `@available` 的情况（因为 @available 总共就一个）。`#if os(iOS) →ELSE` 双分支结构在 Web 三件套里使用规范（宽 frame 正确锁在 macOS 分支）

## iOS 专项风险

### 内存压力（继承 CODE_REVIEW P1-5，补兼容性视角）
- `Services/ConversationImporter.swift:4,33-37`、`Services/ClaudeImporter.swift:78-82` — 注释自称流式，实际 `decoder.decode([RawConversation].self, from: data)` 整文件一次性 decode；几百 MB 的 ChatGPT 导出内存峰值数倍于文件大小
- `Services/UnifiedContainerMigration.swift:182` — 迁移读侧 `FetchDescriptor<MessageNode>()` 全量 fetch
- **兼容性放大系数**: 能装 iOS 26 的最老设备是 iPhone 11（4GB）；把目标降到 18 会纳入 iPhone XS/XR（4GB 但 jetsam 阈值更紧、芯片更老）。主力用户（iPhone 16/17 级，8GB）大概率挺得过导入峰值，**XR 级设备首次导入大概率被 jetsam 杀**。如果降目标到 18，导入器流式化从"性能债"升级为"阻断项"。

### 后台执行
- `Info-iOS.plist` **没有声明任何 `UIBackgroundModes`**（实读确认）——MCP 连接、CC bridge WebSocket、导入、迁移全部依赖前台存活
- 已知配套：连接抖动已有"缓存工具列表 + 按需重连"的设计教训在案；CC bridge 有 foreground resync 计划（docs/plan-cc-foreground-resync.md）
- **版本无关**但属于 iOS 适配清单：长导入（20 万节点级）在 iOS 上必须设计成可中断续传，目前导入器中断状态不可恢复（CODE_REVIEW P1-6），iPhone 上锁屏即中断，触发概率远高于 Mac

### iPhone 屏幕适配
- **真问题 2 处**（无平台守卫、iOS 可达、固定宽度超过或逼近窄屏）:
  - `Views/RegexScriptEditor.swift:118` — `frame(width: 460, height: 520)`，iPhone 全系（375-440pt）溢出裁切（CODE_REVIEW P1-15 已记录）
  - `Views/ImportView.swift:724` — `frame(width: 420, height: 400)`，iPhone mini/SE（375pt）和标准 16（393pt）溢出；从 ContentView:372 / DataSettingsTab:248,372 三处入口可达
- **虚惊已排除**（精确 #if 状态机核实）: MiniBrowserView:280（860×680）、HTMLArtifactCardView:262（760×640）在 `#if os(iOS)` 的 `#else` 分支；SettingsView:248（480×560）在 `#if os(macOS)` 内——iOS 都不可达

### 文件系统差异
- 已就位：`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`（Files app 可见）、导入用 security-scoped resource（`Views/ImportView.swift:662`，但失败静默 return，P1-6）
- 缺口：`Views/ExportOptionsSheet.swift:148-152` iOS 导出写 tmp 不接 ShareSheet（G-2）；无 App Group（暂无 widget/extension 需求，X22 做 Widget 时要补）

## 决策矩阵

| 编号 | 功能/API | 破坏类型 | 推荐策略 | 降级替代难度 | 功能隐藏的损失 |
|------|---------|---------|---------|------------|--------------|
| C-1 | `.glassEffect()` × 26 | 🔴 | shim（方案 A），fallback 视觉规格需粟粟定 | 🟢 半天-1天 | 不可隐藏（是皮肤不是功能） |
| C-2 | `.buttonStyle(.glass)` × 1 | 🔴 | shim 同批 | 🟢 | 同上 |
| C-3 | `UIGlassEffect` × 1 | 🔴 | 3 行 if #available | 🟢 | 同上 |
| R-1 | SwiftData 18.x 运行时 | 🟡 | 18.x 模拟器真数据回归 | -（测试项） | - |
| B-4 | 键盘/手势体系 18 未验证 | 🔵 | 专项回归 + 找 18 真机渠道 | -（测试项） | - |
| G-2 | iOS 空心导出 ×3 | ⚪ | 补实现或 disabled（与版本无关，建议同批修） | 🟡 半天-1天 | 已经在损失中 |
| 屏幕 | RegexScriptEditor / ImportView 固定宽 | 🔵 | 改 maxWidth + 自适应 | 🟢 各 30 分钟 | 低（可先 disabled 正则编辑入口） |
| P1-5 | 导入器内存峰值 | 🟡 | 若降到 18 则流式化升级为阻断项 | 🔴 流式 JSON 解析 1 天+ | 大文件导入引导到 Mac 端做（短期方案） |

## 部署目标建议

三档真实选项（iOS 19-25 不存在）：

- **维持 iOS 26**: 0 工作量。代价：排除两类人——硬件停在 XS/XR/SE2 早期的（这些机器装不了 26），和买得起新机但没升级系统的慢更新者。社区测试（产品方向里的 Phase "找 50 个酒馆用户"）会直接把后者挡在 TestFlight 外。
- **iOS 18（建议的甜点位）**: 需要处理 28 处编译错误（一个 shim 收口，🟢 1-2 天含视觉调校）+ R-1/B-4 两轮测试（模拟器为主，找至少一台 18 真机）+ 建议同批顺手修 G-2 三处空心导出和 2 处固定宽度。覆盖 iPhone XS（2018）以来所有机型。**注意测试债是大头，代码是小头。**
- **再降到 iOS 17**: 额外增加约 17 处工作——12 个 @Model 的 `#Index` 在 17 无法编译（宏没有运行时分支可走，只能整个砍掉 = 全表扫，20 万节点不可接受）+ `onScrollGeometryChange` 3 处要换 offset 侦测方案（项目教训明确记录过 GeometryReader 系在 LazyVStack 里 stuck 0，替代方案本身就是已知雷区）+ `onGeometryChange` 2 处 [待验证回部署下限] + iOS 17.0-17.4 的 SwiftData 运行时缺 18 修的一批 bug。**性价比为负，不建议**：iOS 17 能装的机器（XS/XR+）iOS 18 全部能装，降到 17 只为收编"能升 18 而不升"的用户，拿索引性能换他们不值。

一句话版本：**降到 18 的工程门槛出乎意料地低（glass 一个家族 28 处，一个 shim 的事），真正要花的钱在 iOS 18 运行时的测试验证上；降到 17 是赔本买卖；留在 26 唯一的代价是用户面。**

---
*扫描产物: `/tmp/ios18-build-full.log`（xcodebuild 全量日志）、`/tmp/ios18-typecheck.log`（全模块 typecheck 诊断）。本报告所有 🔴 条目都有编译器报错原文背书；所有"iOS 可达性"结论都经 #if 状态机逐行核实。*
