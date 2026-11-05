# iOS 18 适配路线图: 记忆宫殿

生成日期: 2026-06-12
基于: IOS_COMPAT_AUDIT.md (2026-06-12) + docs/体检/CODE_REVIEW.md (2026-06-10)
适配目标: iOS 18.0+ (iPhone only)
工作分支: `worktree-ios-compat-audit`（本 worktree）

> ⚠️ **DON'T IMPLEMENT YET** — 本计划等粟粟批注（⧫ 标记），决策项填完才开工。
> 说明：CODE_REVIEW.md 实际位置在 `docs/体检/CODE_REVIEW.md`，未复制到根目录（避免双份漂移），本文引用一律指向真实路径。

## 适配策略概述

这次适配的形状很反常：**代码只有 28 处编译错误 + 5 处功能修补（约 1.5-2 天），而测试验证要 2-3 天 + 真机物流等待**——所以路线图的重心是测试编排，不是代码批次。代码侧用"一个 shim 收口全部 glass 调用 + 机械替换"的策略，把项目第一批 `if #available` 锁在单一文件里不扩散。交叉 issue 只带走"iOS 用户直接撞脸"的 5 项（3 空心导出 + 2 固定宽度溢出），内存流式化等根治项留给主线（理由见交叉 issue 表）。合并采取**早合策略**：代码波次 + 模拟器级测试完成即合回 master（主线正在动 ContentView 同区域，fork 后已有实证冲突源 73dc61c，拖越久越贵），真机专项回归在合并后的 master 上继续，TestFlight 发布以真机回归完成为门禁。

## 前置决策清单

### 决策 D-1: Glass fallback 视觉规格
- **需要决定**: iOS 18 上替代 `.glassEffect()` 的 material 配方——material 种类（ultraThin/thin/regular）、描边有无与参数、tint 的换算规则（尤其 `Color.black.opacity(0.01)` 这类 26 专用 hack tint 在 fallback 上怎么处理，见审计 B-3）
- **选项**:
  - 选项 A: **统一配方** `.ultraThinMaterial` + 0.5pt 白描边（opacity ~0.18），tint hack 位点 fallback 传 nil — 优势：一次定稿、28 处零分歧、维护简单；代价：个别深色背景组件（贴纸键盘、终端）可能偏透
  - 选项 B: 统一配方但用 `.thinMaterial`（更实底）— 优势：深色背景下更可见；代价：浅色主界面里比 26 的玻璃重
  - 选项 C: 按组件分别调 — 优势：每处最优；代价：28 处各自维护，违背收口初衷
- **推荐**: A 起步 + shim 预留 material 参数给个别组件覆写（实际上是 A/C 折中，覆写默认为零）。调参载体用 `GlassBackButton`（最小）+ `ChatInputBar`（最核心）两个组件先出原型截图给粟粟过目，定稿后再铺其余 26 处
- **阻塞**: Wave 1 全部
- **决定**: ____

### 决策 D-2: 交叉 issue 带走范围
- **需要决定**: CODE_REVIEW 的 iOS 交叉项哪些在本 worktree 修
- **选项**:
  - 选项 A: 最小范围——只修 28 处编译错误 — 优势：worktree 生命周期最短；代价：iOS 18 新用户第一次导出就撞空心功能，"能装"但"被骗"
  - 选项 B: + 功能修补 5 项（exportPreset iOS / DataSettingsTab 批量导出 ×2 / ExportOptionsSheet ShareSheet / RegexScriptEditor + ImportView 固定宽）— 优势：这 5 项全是"iOS 用户可感知的坑"，且其中 3 项已列入主线 R-B3 批次（PROJECT_ROADMAP:38），挪到这里修可以给 R-B3 减负；代价：worktree 多活一天，**需要在 roadmap 把这 3 项从 R-B3 划走避免双修**
  - 选项 C: B + 导入大小守卫（iOS 上 >50MB 导出文件先弹确认框，提示内存风险/建议 Mac 端导入）— 优势：~1-2 小时把 P1-5 的 iOS 致命面（XR 级 3GB 设备 jetsam）降为可控；代价：治标不治本（根治=流式解析，留主线）
  - 不提供"连内存流式化也做"选项：流式化 1 天+，且 ConversationImporter/ClaudeImporter 是主线 P1-22 复制体重构的对象，在这里动会和主线重构对撞
- **推荐**: C（= B + 守卫）
- **阻塞**: Wave 2、Wave 3
- **决定**: ____

### 决策 D-3: iOS 18 真机渠道
- **需要决定**: 键盘/手势专项回归（审计 B-4）和内存边界测试（C5）的真机怎么来
- **选项**:
  - 选项 A: **闲鱼收一台二手 iPhone XR**（约 ¥600-1000）— 优势：XR 装不了 iOS 26（26 要求 iPhone 11+），买到手**永久锁死在 ≤18**，不存在"被卖家升级"风险；3GB RAM 恰好是 iOS 18 用户群的内存下限，一台机器同时覆盖 C4 手势回归和 C5 内存边界两个测试需求；可挂调试器
  - 选项 B: 二手 iPhone XS（约 ¥700-1100, 4GB）— 同 A 但内存压力测试代表性略弱
  - 选项 C: TestFlight 招募 iOS 18 外部测试者 — 优势：零硬件成本；代价：无调试器、反馈链以天计、手势类 bug 靠用户描述基本定不了位。只适合做 A 的补充面（真实机型多样性），不能当主渠道
  - 选项 D: 二手 SE2/SE3 — ⚠️ 不推荐：SE2 能升 iOS 26 且 Apple 停签后不可降级，闲鱼货大概率已被升上去，买前要逐台确认系统版本，踩坑率高
- **推荐**: A（下单动作放 Wave 0，物流 2-5 天和代码波次并行）+ C 作为发布前补充
- **阻塞**: C4 手势专项（完全阻塞——`_UIRelationshipGestureRecognizer` 等私有手势行为只在真机存在）、C5 内存边界（完全阻塞——模拟器不模拟 jetsam）、sensoryFeedback 触觉（完全阻塞）。键盘时序模拟器可测约 80%，最终确认需真机
- **决定**: ____

### 决策 D-4: 部署下限 18.0 还是 18.x
- **需要决定**: `IPHONEOS_DEPLOYMENT_TARGET` 精确值
- **选项**:
  - 选项 A: 18.0 — 优势：覆盖最大；代价：SwiftData 在 18.0 运行时的 bug（18.1/18.2 修过一批）要自己防
  - 选项 B: 18.4+ — 优势：跳过最早的 SwiftData 坑；代价：理论上丢极少量钉在 18.0-18.3 的用户（实际占比很小，2026 年中 18.x 存量用户绝大多数已在 18.5+）
- **推荐**: 先定 18.0 写进 project.yml；C2 测试矩阵里专门安排 18.0 模拟器轮，**若实测暴露 18.0 独有的 SwiftData 问题且 18.4+ 模拟器没有 → 数据驱动改成 B**（改一行的事，不用现在赌）
- **阻塞**: 无（Wave 1 按 18.0 做，改值是零成本后置项）
- **决定**: ____

## 实施路线

### Wave 0: 测试基建 — 把等待时间全部前置

**前置**: 无（D-3 拍板后真机下单项即可执行；其余现在就能做）
**性质**: 环境准备，不碰源码
**预估**: 操作 ~1h，等待（下载/物流）后台进行

#### 任务

| 条目 | 动作 | 说明 |
|------|------|------|
| iOS 18 模拟器 runtime | Xcode → Settings → Components 下载 iOS 18.x Simulator Runtime（优先最新 18.x，如 18.6；若列表里有 18.0 一并下）| 本机现在**只有 26.4**（已核实），~8GB，必须最先排队 |
| 18.0 runtime（若 Components 没有） | 从 Apple Developer 下载 dmg 后 `xcrun simctl runtime add <path>` | D-4 的 18.0 专项轮需要 |
| 真机下单 | 按 D-3 决定下单（XR 注意确认卖家系统版本 ≤18.x 且未抹机绑定）| 物流 2-5 天，与 Wave 1-3 并行 |
| 双 target 验证脚本 | 把三条构建命令存成 `docs/handoffs` 备忘或 shell alias（见 Wave 1 验证清单）| 每个 commit 后跑，防"修 iOS 18 弄坏 26/macOS" |

#### 完成后立即验证
- [ ] `xcrun simctl list runtimes` 出现 iOS 18.x
- [ ] 18.x 模拟器能创建 iPhone 16 设备并启动到桌面

#### Rollback
无（不碰源码）

#### Git 策略
无 commit（环境项）

---

### Wave 1: GlassCompat shim + 28 处替换 + 部署目标翻转

**前置**: 决策 D-1 已完成；Wave 0 的 runtime 已可用
**性质**: 编译阻断修复（B1，对应审计 C-1/C-2/C-3 全部 28 处）
**预估**: 代码 ~4-6h（含原型调参 1-2 轮），验证 ~1-2h

#### 代码任务

| 条目 | 来源 | 涉及文件 | 改动描述 | 预估 |
|------|------|---------|---------|------|
| shim 本体 | C-1/C-2 | **新建** `MemoryPalace/Utils/GlassCompat.swift` | `compatGlass(tint:in:interactive:)` + `CompatGlassButtonStyle`，整文件 `#if os(iOS)` 包裹（共源 macOS 必须能编译） | 1.5h |
| 原型调参 | D-1 | `Views/GlassBackButton.swift:18` + `Views/CardFlowView.swift:1592` | 两处先换 compatGlass，18/26 模拟器双截图给粟粟定稿 | 1h |
| 核心路径铺设 | C-1 | CardFlowView(:1060) / ContentView(:624,644,736) / SidebarView(:150,166) / PinnedMessageBar(:45) / ToolBarView(:96) | 机械替换（行号见审计 C-1 表） | 1h |
| 面板簇铺设 | C-1 | AttachmentPreviewSheet ×4 / MemoryPanelView / PhotoStripPanel / StickerKeyboardPanel ×2 / PersonaSettingsTab(:2489) | 同上；tint hack 位点按 D-1 规则换算 | 1h |
| Web 簇 + 按钮样式 | C-1/C-2 | MiniBrowserView ×3 / HTMLArtifactCardView ×4 / ScrollToBottomButton(:22→compatGlassButtonStyle) | 同上 | 0.5h |
| UIKit 玻璃 | C-3 | `Views/CCTerminalPanelView.swift:180` | 3 行 `if #available(iOS 26.0,*)` UIGlassEffect / else UIBlurEffect(.systemUltraThinMaterialDark)（深色终端防发灰，规格随 D-1） | 0.5h |
| 部署目标翻转 | - | `project.yml:62,94`（26.0→18.0）；`:118` UITests target 一并翻（手势探针要在 18 真机跑） | **本 wave 最后一步**，翻转前全程用 `IPHONEOS_DEPLOYMENT_TARGET=18.0` 命令行覆盖验证（审计同款技巧），保持树常绿 | 0.5h |

shim 起点配方（D-1 的调参对象，非定稿）：

```swift
// MemoryPalace/Utils/GlassCompat.swift
#if os(iOS)
import SwiftUI

extension View {
    /// iOS 26 走真 Liquid Glass，iOS 18-25 走 material 等价物。
    /// tint 传 nil = 不着色（26 上的 black.opacity(0.01) 触发 hack 不要平移进来）。
    @ViewBuilder
    func compatGlass<S: Shape>(tint: Color? = nil, in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(glassVariant(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}

@available(iOS 26.0, *)
private func glassVariant(tint: Color?, interactive: Bool) -> Glass {
    var g: Glass = .regular
    if let tint { g = g.tint(tint) }
    if interactive { g = g.interactive() }
    return g
}

/// ScrollToBottomButton 用：26 官方 .glass，18 走 material 圆底 + pressed 减淡
struct CompatGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif
```

无 `in:` 参数的调用点（CardFlowView:1060）补 `in: Capsule()`（glassEffect 默认形状即胶囊，行为等价）。

**硬约束（来自审计 B-1）**: ScrollToBottomButton:5-8、PinnedMessageBar:43、CardFlowView:1593 三处的 iOS 26 hit-test workaround 注释和结构**原样保留**，26 分支行为一个字不动——只包壳，不"顺手清理"。

#### 完成后立即验证
- [ ] 翻转前逐簇验证: `xcodebuild -scheme MemoryPalaceIOS -destination 'generic/platform=iOS Simulator' build IPHONEOS_DEPLOYMENT_TARGET=18.0 CODE_SIGNING_ALLOWED=NO` 通过
- [ ] 翻转后: `xcodebuild -scheme MemoryPalaceIOS -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build` 通过（用实际装好的 18.x 版本号）
- [ ] **iOS 26 回归**: 26.4 模拟器 build + 启动 + 聊天页/侧栏/输入框玻璃观感与改前一致（对照截图）
- [ ] **macOS 回归**: `xcodegen generate && xcodebuild -scheme MemoryPalace build` 通过（shim 在 #if os(iOS) 里，macOS 必须零感知）
- [ ] 18.x 模拟器启动 app，过一遍 16 个被改文件对应的界面，无白块/无丢背景

#### Rollback
project.yml 翻转是独立的"门"commit——出大问题 revert 这一个 commit 即回到 26-only，shim 和替换可以留着（对 26 无害）。单文件搞砸 → `git checkout master -- <file>` 重做。

#### Git 策略
按上表分 6 个 commit（shim → 原型 → 核心簇 → 面板簇 → Web 簇+按钮 → project.yml 翻转），每个 commit 前跑双 target build，commit 后 push。message 前缀 `feat(ios18):`。

---

### Wave 2: 功能修补 — iOS 用户可感知的 5 个坑

**前置**: 决策 D-2 已完成（选 B 或 C）；Wave 1 已完成（PersonaSettingsTab 同文件先后动，避免并行 churn）
**性质**: 功能完整性修复（B2，对应审计 G-2 + 屏幕适配 2 处；CODE_REVIEW P1-15 部分 + P1-19 iOS 部分）
**预估**: 代码 ~4-6h，验证 ~2-3h

#### 代码任务

| 条目 | 来源 | 涉及文件 | 改动描述 | 预估 |
|------|------|---------|---------|------|
| 预设导出 iOS | P1-15 | `Views/PersonaSettingsTab.swift:290-299` | `#else` 分支：toSillyTavernJSON → 写 tmp `\(name).json` → UIActivityViewController（复用 StickerSettingsTab:319 的 topVC 模式，不另造抽象） | 1h |
| 单对话导出 ShareSheet | P1-19 | `Views/ExportOptionsSheet.swift:150-153` | iOS 分支写完 tmp 后接 ShareSheet（注释里自己立的 flag）；**顺手把 `try?` 写盘失败改成可见报错**（写失败还弹分享框是假成功，P1-19 主旨） | 1h |
| 批量导出 iOS ×2 | P1-15 | `Views/DataSettingsTab.swift:378-380,449-452` | 导出到 tmp 目录 → ZIPFoundation 打 zip → ShareSheet 分享单个 zip（依赖已有，不新增）；若 D-2 批注砍掉此项则按钮改 disabled + "仅 macOS" 标注，禁止保留可点的 no-op | 2h |
| 正则编辑器宽度 | P1-15 | `Views/RegexScriptEditor.swift:118` | `#if os(macOS)` 保留 460×520；iOS 去固定 frame 走 sheet 自适应 | 0.5h |
| 导入确认框宽度 | 审计·屏幕 | `Views/ImportView.swift:724` | 420 固定宽 → `frame(maxWidth: 420)`，375pt 窄屏不再溢出 | 0.5h |

#### 完成后立即验证
- [ ] iOS 18.x 模拟器：预设导出 → 分享到"存储到文件" → 重新导入该 json 验证往返
- [ ] iOS 18.x 模拟器：单对话导出 md → 分享面板出现且文件内容非空
- [ ] iOS 18.x 模拟器：批量导出 → zip 落地 → 解开抽查 2 个 md
- [ ] iPhone SE (3rd gen) 模拟器（375pt）：正则编辑器 sheet、导入确认框无溢出裁切
- [ ] **iOS 26 回归**: 同样 5 条在 26.4 模拟器重跑（ShareSheet 是双版本共用代码）
- [ ] **macOS 回归**: 三个导出入口 NSSavePanel 路径不受影响（#if 另一边没动，build 过即可 + 抽 1 条手测）

#### Rollback
每项独立 commit，单项出问题 revert 单个 commit，互不牵连。

#### Git 策略
5 个 commit（每功能点一个），前缀 `fix(ios):`，每 commit 双 target build + push。**若 D-2 选 B/C：同批在 PROJECT_ROADMAP.md 的 R-B3 行加备注"iOS 导出 no-op 三项已在 worktree-ios-compat-audit 修复"，划账防双修。**

---

### Wave 3: 防护项 — 导入内存守卫

**前置**: 决策 D-2 选 C；Wave 2 已完成（同动 ImportView）
**性质**: 性能/安全防护（B3，对应审计 R-2 / CODE_REVIEW P1-5 的 iOS 缓解面）
**预估**: 代码 ~1-2h，验证 ~0.5h

#### 代码任务

| 条目 | 来源 | 涉及文件 | 改动描述 | 预估 |
|------|------|---------|---------|------|
| 导入大小守卫 | P1-5/R-2 | `Views/ImportView.swift`（security scope 拿到 url 后、decode 前） | `#if os(iOS)`：文件 >50MB 弹确认框（"导入大文件可能因内存不足中断，建议在 Mac 端导入后同步"两键：继续/取消）。阈值常量化，便于真机 C5 实测后调 | 1.5h |

不做的事（明确划界）：流式 JSON 解析（主线 P1-5 根治）、导入断点续传（主线 P1-6）——在这里动会撞主线 importer 重构。

#### 完成后立即验证
- [ ] 18.x 模拟器：>50MB 文件触发弹窗，"继续"后正常走导入，"取消"干净退出
- [ ] <50MB 文件零打扰
- [ ] **iOS 26 回归**: 同两条
- [ ] macOS：无此弹窗（#if 守卫）

#### Rollback
单 commit revert。

#### Git 策略
1 个 commit，`feat(ios):` 前缀，build + push。

---

## 测试矩阵

> 代码波次内的"完成后立即验证"是冒烟级；本节是适配定稿前的系统性验证，**对应工时与代码工时同量级，不能省**。

### 测试环境需求

| 环境 | 用途 | 获取方式 | 状态 |
|------|------|---------|------|
| iOS 18.x 模拟器（最新，如 18.6） | C1 编译 / C2 冒烟 / C3 视觉 / C4 键盘 80% | Xcode Components 下载 ~8GB | ❌ 待下载（本机仅 26.4，已核实） |
| iOS 18.0 模拟器 | D-4 数据驱动验证（SwiftData 18.0 独有 bug 探测） | 同上或 dmg + `simctl runtime add` | ❌ 待下载 |
| iPhone SE (3rd gen) 模拟器 | 375pt 窄屏布局 | 任一 18.x runtime 自带设备型号 | 随 runtime |
| iOS 26.4 模拟器 | 回归保护 | 已有 | ✅ |
| iOS 18 真机（XR 推荐） | C4 手势/触觉/键盘终验 + C5 内存 | D-3 决策，闲鱼 2-5 天 | ❌ 待决策 |
| iOS 26 真机 | 回归保护 + 视觉对照 | 现有 iPhone 17 Air（装包只推 Air） | ✅ |

### 测试用例

| 功能区域 | 测试步骤 | 环境要求 | 风险来源 | 优先级 |
|---------|---------|---------|---------|--------|
| 启动/建楼层 | 全新装 → 建楼层 → 设置 API key → 建对话 | 18.0 + 18.x 模拟器各一遍 | R-1 SwiftData 全新建库 | P0 |
| 核心聊天 | 发消息 → 流式回复 → 流式中上滑再回底（回底按钮=compatGlassButtonStyle + onScrollGeometryChange 的 isAtBottom）→ 新建对话 | 模拟器 OK | C-2 / onScrollGeometryChange 18 首跑 | P0 |
| 键盘避让 | 输入框聚焦/收起 ×5、贴纸键盘面板切换、设置页 TextEditor 聚焦、Route C 卡片流输入 | 模拟器 80%，**终验真机** | B-4（嵌套 HC 手动 observer 数学只在 26 调过） | P0 |
| 导入（小） | 10 对话 ChatGPT 导出 → 导入 → 树/分支抽查 | 模拟器 OK | R-1 | P0 |
| 导入（大） | >100MB ChatGPT 导出 → 守卫弹窗 → 继续 → 完成或观察内存 | **真机必须**（jetsam 模拟器不模拟）+ Xcode memory gauge | P1-5/R-2 | P0 |
| 楼层切换 | 建 2+ 楼层来回切 → 壁纸/主题/对话列表正确跟随 | 模拟器 OK | `.id()` 整树重建雷区（项目已知"切楼层后坏"模式） | P0 |
| 手势系统 | 贴纸 pan/长按/双指旋转缩放、画布编辑、tab 翻页、横向滚动区按钮点击 | **真机必须**（私有手势识别器行为无契约） | B-4 / `_UIRelationshipGestureRecognizer` | P0 |
| 导出 ×4 | 预设/单对话/批量×2 全走 ShareSheet 路径（Wave 2 新代码） | 模拟器 OK | Wave 2 新实现 | P1 |
| 玻璃视觉走查 | 16 个被改文件对应界面逐屏过：亮/暗主题 ×（SE 375pt / 16 393pt / Pro Max 440pt） | 模拟器 OK | D-1 配方在边界场景的观感 | P1 |
| 搜索/收藏/标签 | 关键词搜索 → 跳转定位 → 收藏/取消 | 模拟器 OK | R-1（#Index 在 18 运行时首跑） | P1 |
| MCP/CC bridge | 连接 → 工具调用一轮 → 切后台回前台重连 | 模拟器 OK（hub 在 Mac 上） | 版本无关但路径必走 | P1 |
| 触觉反馈 | sensoryFeedback 各触发点有震感 | **真机必须** | 模拟器无触觉 | P2 |
| HealthKit | 授权页拉起 → 快照读取 | 真机佳，模拟器可注假数据 | canImport 分支 18 首跑 | P2 |

**没有真机时完全不能做的**: 手势系统全套、内存 jetsam 边界、触觉反馈。**模拟器可替代 80% 的**: 键盘时序（最终确认仍要真机一轮）。其余模拟器可全覆盖。

## 交叉 issue 处理

| CODE_REVIEW 编号 | 标题 | 处置 | 理由 |
|-----------------|------|------|------|
| P1-15（3/4 项） | exportPreset iOS / DataSettingsTab 导出 ×2 / RegexScriptEditor 宽度 | **本 worktree 修**（Wave 2，待 D-2） | iOS 用户直接撞脸；已列主线 R-B3 的部分划账过来 |
| P1-19（1 处） | ExportOptionsSheet iOS 导出黑洞 | **本 worktree 修**（Wave 2） | 同上，注释里自己立的 flag |
| P1-5 | 导入器内存峰值 | **本 worktree 只做守卫**（Wave 3），流式化留主线 | 根治要动 importer 主体，与主线 P1-22 复制体重构对撞 |
| P1-6 | 导入中断不可恢复 | 留主线，**建议提级** | iOS 锁屏即中断，触发率远高于 Mac；修复要动状态机，超出适配范围 |
| P1-15（renameSticker） | 贴纸重命名空实现 | 留主线 R-B3 | 跨平台问题，与 iOS 适配无关 |
| P0-1 | 跨楼层 upsert 偷数据 | 留主线（R 批次已排） | 非版本相关；**C2 导入测试用全新楼层规避误伤** |
| P0-3 | MCP 超时挂死 | 留主线（R 批次已排） | 非版本相关，iOS 26 同样存在 |
| P1-4 / G-3 | #Index 条件编译方向 | 不动 | iOS 18 正好可用；macOS 15 索引是另一个 worktree 的事 |
| P1-8/9/10 | 并发安全三件套 | 留主线 | 非版本相关；备注：XR 级慢芯片改变时序，**真机 C4 若复现崩溃优先对照这三条**，但修复不进本分支 |
| P1-11 | profileManager! 强解包 | 留主线 R-B3 | 非版本相关 |

## 合并策略

- **合并时机**: Wave 1-3 全完成 + C1/C2/C3（模拟器级）通过 → **一次合回 master**。C4/C5 真机回归在合并后的 master 上继续做——理由：① 主线正在动 ContentView/CardFlowView 同区域（fork 后 73dc61c 已实证），晚合一天冲突面涨一天；② 28 处替换是机械改动，越早合主线新代码就越早直接写 compatGlass，不再产生新的裸 glassEffect；③ 真机回归发现的问题大概率是调参/修 bug 级，在 master 上小步修符合项目惯例
- **预期冲突热点**: `ContentView.swift`（气泡顶栏，主线活跃区）、`CardFlowView.swift`、`SidebarView.swift`、`PersonaSettingsTab.swift`（主线 SC 批次 + R-B 批次都会动）
- **冲突处理原则**: glass/视觉行 → 适配分支优先（compatGlass 是机械等价包装）；逻辑行 → 主线优先；同行双改 → case by case。兜底方案：机械替换可对主线新版本用相同 pattern 重放（成本极低），不死磕三方合并
- **合并后回归**: ① macOS build + 启动冒烟（共源红线）② iOS 26.4 模拟器冒烟 ③ 26 真机（Air）装包走查玻璃界面 ④ TestFlight 发布门禁 = C4/C5 真机项全过
- **合并方式**: `git merge --no-ff worktree-ios-compat-audit`（保留波次 commit 历史），合并 commit 注明"iOS 18 适配代码完成，真机回归进行中，TestFlight 勿发"

## 时间线估算

| 阶段 | 代码工时 | 测试工时 | 阻塞项 |
|------|---------|---------|--------|
| 前置决策 D-1~D-4 | 0 | 0 | 粟粟批注（~30min） |
| Wave 0 测试基建 | 0 | ~1h 操作（下载/物流后台） | D-3（真机下单项） |
| Wave 1 glass shim | 4-6h | 1-2h | D-1、runtime 下载完成 |
| Wave 2 功能修补 | 4-6h | 2-3h | D-2、Wave 1 |
| Wave 3 导入守卫 | 1-2h | 0.5h | D-2(C)、Wave 2 |
| C3 视觉走查+调参 | （调参算这里 1-2h） | 2-4h | Wave 1 |
| C2 系统冒烟（18.0+18.x 双轮） | 0 | 3-4h | 全部 wave |
| 合并 + 合并后回归 | 1h | 2h | C1-C3 |
| C4 专项回归（模拟器部分） | 0 | 3-4h | 合并后可做 |
| C4+C5 真机部分 | （修 bug 余量 2-4h） | 4-6h | **真机到手** |
| **合计** | **~12-19h（代码 1.5-2.5 天）** | **~18-26h（测试 2.5-3.5 天）** | |

注：测试工时假设**有** iOS 18 真机（D-3 选 A/B）。若只走 TestFlight 外测（D-3 选 C），真机部分换成"等待外测反馈"，加 **3-7 天**等待期且手势类问题可能定位不了。真机物流 2-5 天与代码波次并行，不进关键路径——**前提是 Wave 0 第一天就下单**。

---

## 执行追踪器（总 checklist）

- [ ] D-1 视觉规格批注
- [ ] D-2 交叉范围批注
- [ ] D-3 真机渠道批注（选 A/B 当天下单）
- [ ] D-4 部署下限批注
- [ ] W0: iOS 18.x runtime 下载完成
- [ ] W0: 18.0 runtime 下载完成
- [ ] W0: 真机下单
- [ ] W1: GlassCompat.swift shim（commit 1）
- [ ] W1: 原型两件套调参定稿（commit 2，含截图过目）
- [ ] W1: 核心簇替换（commit 3）
- [ ] W1: 面板簇替换（commit 4）
- [ ] W1: Web 簇 + ScrollToBottomButton + CCTerminal（commit 5）
- [ ] W1: project.yml 翻转 18.0（commit 6，"门"commit）
- [ ] W1: 双 target + macOS 三平台 build 全绿
- [ ] W2: exportPreset iOS ShareSheet
- [ ] W2: ExportOptionsSheet ShareSheet + 写盘报错
- [ ] W2: DataSettingsTab 批量导出 ×2（或 disabled 化）
- [ ] W2: RegexScriptEditor / ImportView 宽度
- [ ] W2: roadmap R-B3 划账备注
- [ ] W3: 导入大小守卫
- [ ] C3: 视觉走查（亮暗 × 3 尺寸）+ 调参定稿
- [ ] C2: 18.x 系统冒烟全表
- [ ] C2: 18.0 SwiftData 专项轮 → D-4 终值确认
- [ ] 合并 master + 合并后回归 4 项
- [ ] C4: 键盘/手势模拟器部分
- [ ] C4+C5: 真机专项（键盘终验/手势全套/触觉/大导入内存）
- [ ] TestFlight 发布门禁评审
