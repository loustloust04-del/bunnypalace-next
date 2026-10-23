import SwiftUI

extension EnvironmentValues {
    /// 宽屏面板形态下为 true。共用视图据此收掉在宽屏下多余或会和把手打架的控件
    /// （SidebarView 底栏的齿轮 —— 它正好压在对话窗右下角那枚缩放弧底下，粟粟「点都点不动」）
    @Entry var widePanelMode = false
}

/// 停靠壳的三条列（plan-panel-ps）：左 / 右满高，底只在正文卡下方
enum PanelEdge: String, Codable, CaseIterable {
    case left, right, bottom
}

/// 宽屏形态（iPad 横屏等）的面板布局状态：模式 / 展开 / 宽度 / 开着哪些工具 / 浮窗的位置尺寸与层级 / 桌面格子排版 / 缩成组件的窗。
///
/// **字段必须平铺**，不能收进一个 struct：`@Observable` 按属性追踪，拖宽度时只有读了
/// `leftWidth` 的那几个子视图重算；读 `leftShown` 的 `ContentView.body` 不受牵连——
/// 它一重算就会 `updatePages` 三棵 HC 树（plan-ipad-panel-v2 §2.2，真机探针已验：整段交互 43 次 body，
/// 拖动没有逐帧重算）。
///
/// 全部持久化——没有 pin 之后「展开/收起」就是唯一的常驻语义，不记住的话每次转屏都要重开侧栏。
/// 不引 UIKit，将来 macOS 重构直接拿。
@MainActor
@Observable
final class IPadPanelLayout {
    static let shared = IPadPanelLayout()
    /// 存档落哪个 defaults（测试注 suite，生产 .standard）
    private let defaults: UserDefaults

    /// 两档（plan-ipad-panel-v2 §6）：自由浮窗 / 停靠平铺。吸边对齐是浮窗的一个开关（`snapToEdges`），不是一档
    enum Mode: String, Codable, CaseIterable {
        /// 真窗口：每个面板是一扇独立窗口——可叠、点哪个哪个到前面、拖标题栏移位、角上圆弧把手缩放
        case floating
        /// 真全屏：面板贴边满高、正文被推开不被盖（默认；otty 那种平铺三栏）。右栏是一组 tab
        case docked

        var label: String {
            switch self {
            case .floating: return "窗口"
            case .docked:   return "全屏"
            }
        }

        var icon: String {
            switch self {
            case .floating: return "macwindow.on.rectangle"
            case .docked:   return "rectangle.split.3x1"
            }
        }
    }

    /// 浮窗的位置尺寸（overlay 坐标，左上原点）
    struct WindowFrame: Codable, Equatable {
        var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    }

    /// 窗口靠哪边长：决定圆弧把手放哪个下角、缩放时哪条边在动
    enum WindowAnchor { case leading, trailing }

    /// 吸边时画的辅助线（竖线给 x，横线给 y）
    struct SnapGuide: Hashable {
        let vertical: Bool
        let at: CGFloat
    }

    /// 拖动期间的吸附辅助线。瞬态：不进存档、松手清空
    var snapGuides: [SnapGuide] = []
    /// 窗 ⇄ 桌面小组件 飞行中的临时位置（盖过 `frames`，不受最小尺寸钳制）：缩进去时窗先飞到目标格再消失，
    /// 恢复时窗先出现在那一格再飞回原位。瞬态：不进存档
    var flights: [String: WindowFrame] = [:]
    #if os(macOS)
    var macTabFrames: [String: CGRect] = [:]
    var macReturnFrame: CGRect = .zero
    /// 每个停靠组 tab 栏在工作区的框（停回飞行的终点）。瞬态
    var macGroupBarFrames: [String: CGRect] = [:]
    /// 列收着时点 dock 弹出来的那个工具（它所在的组临时浮在 dock 旁）。瞬态不入档（plan-panel-ps 阶段 4）
    var macFlyout: String?
    var macFlightTargets: [String: MacPanelFlight] = [:]
    var macDragGeneration = 0
    var macDropTarget: String?
    var macFirstClickExpandedTab: String?
    /// 停靠壳里正文卡槽在工作区的框（`IPadPanelOverlay` 量了上报），标题行居卡用。瞬态不入档
    var macCardFrame: CGRect = .zero
    #endif

    /// 能不能把这个工具缩成桌面小组件（开着、没缩、格子还有空位）。
    /// `widgetCells` = 桌面小组件已占的格数（`DesktopGridPlacer.widgetCells`），调用方算好传进来
    func canMinimize(_ toolId: String, in size: CGSize, widgetCells: Int) -> Bool {
        isOpen(toolId) && !minimized.contains(toolId) && hasRoomForOneMore(in: size, widgetCells: widgetCells)
    }

    var mode: Mode = .docked { didSet { save() } }
    var leftShown = false {
        didSet {
            // 对话窗也参与浮窗层级：开就到最前，关就出列
            if leftShown { bringToFront(Self.convWindowId) } else { zOrder.removeAll { $0 == Self.convWindowId } }
            // 打开对话列表 = 左列也展开（左列折成图标时 conv 跟着藏，⌘⌥S 得能把它找回来，A I3）
            if leftShown, !applying, collapsedColumns.contains(.left) { collapsedColumns.remove(.left) }
            save()
        }
    }
    /// 浮窗模式 / iPad：dock 条 + 工具面板一起开关。**mac 停靠壳里 dock 条是壳的一部分永远在**，
    /// 这个开关只管右侧工具面板（09-17 她：「打开左栏或右栏 dock 居然会收起来」——那颗钮原来连 dock 一起收）
    var dockShown = true { didSet { save() } }
    /// 全屏模式的两侧宽度（浮窗模式各窗口自己有 frame）
    var leftWidth: CGFloat = 320 { didSet { save() } }
    var rightWidth: CGFloat = 300 { didSet { save() } }
    /// mac 停靠壳里工具面板的存档宽（她拖把手改；渲染时按窗宽钳）。两端都有字段，iOS 不读
    var toolWidth: CGFloat = 360 { didSet { save() } }
    /// 开着的工具（打开顺序 = tab 顺序）；封顶 `maxOpenTools`
    var openTools: [String] = [] { didSet { save() } }
    /// 全屏模式右栏 tab 组里选中的那个；读的时候用 `currentTab`（它兜底到最后一个 tab）
    var selectedTool: String? { didSet { save() } }
    /// 全屏模式下从 tab 组浮出来的工具——它们是盖在正文上的窗，不占右栏。浮窗模式忽略（全是窗）
    var detached: [String] = [] { didSet { save() } }
    /// 缩成桌面小组件的工具：仍算开着（dock 亮），不画成窗 / tab，在 `DesktopGridView` 里占一格
    var minimized: [String] = [] { didSet { save() } }
    /// 缩之前它是窗还是 tab（"window" / "tab"），恢复时回原形态
    var minimizedFrom: [String: String] = [:] { didSet { save() } }
    /// 浮窗拖近屏边 / 邻窗时吸上去对齐并画辅助线
    var snapToEdges = true { didSet { save() } }
    /// 每扇窗记住的位置尺寸（关了也留着，下次开回原处）
    var frames: [String: WindowFrame] = [:] { didSet { save() } }
    /// 浮窗层级，最后一个在最上；成员 = 开着且没缩起来的工具 + （展开时的）对话窗
    var zOrder: [String] = [] { didSet { save() } }
    /// 桌面格子排版（plan-ipad-desktop-grid）：两侧各一列 / 一侧两列；dock 贴哪边
    var arrangement: DesktopArrangement = .a { didSet { save() } }
    var dockSide: DockSide = .right { didSet { save() } }
    /// 屏幕尺寸，决定格子档（iOS 由 ContentView 喂 UIScreen；不持久化；mac 不用它——mac 令牌是常量）
    var screenSize = CGSize(width: 834, height: 1194)
    /// 测试钩子：钉住令牌（A0 那批几何测试跑在 mac 目标，要显式用 iPad 令牌）；生产不设
    var gridSpecOverride: WidgetGridSpec?
    /// mac 按窗宽算出的列数（`MacGridBudget`，带滞回），只在 `ContentView.macLayout` 的 onGeometryChange 一处写；
    /// 瞬态不入档。nil = 还没量过 → `grid(in:)` 按当前尺寸无滞回直接算
    var macColumns: MacGridBudget.Columns?
    /// mac 本地拖放会话的工具 ID；目标验证和提交读取，原生会话结束/取消时清空。瞬态不入档。
    var draggingTab: String?
    /// 全屏模式 tab 组折成一条标题线（mac 双击 tab，A2a-3）。开 / 停回 / 选中一个 tab 时展开；关掉最后一个 tab 清掉；
    /// 浮窗模式保留值不显示
    var tabGroupCollapsed = false { didSet { save() } }

    // MARK: 多组（plan-panel-ps §2）——**全空 = 今天的单组行为**
    //
    // 排序仍只有 `openTools` 一份：组内 tab 顺序 = openTools 过滤出该组成员；窗口 id 永远是工具 id。
    // 停靠组只是「工具 → 组 id」的映射，没映射的属于主组 `g.main`（恒在右列）

    /// 工具 → 停靠组；无键 = 主组。浮出 / 缩起时**保留**（停回、恢复回原组；原组不在列里了就回主组）
    var dockGroupOf: [String: String] = [:] { didSet { save() } }
    /// 每列里组的顺序。不变量：`conv` 恰一次在左列、`g.main` 恰一次在右列（`normalizeGroups`）
    var columnGroups: [PanelEdge: [String]] = IPadPanelLayout.defaultColumns { didSet { save() } }
    /// 非主组的组内选中（主组沿用 `selectedTool`）
    var groupSelected: [String: String] = [:] { didSet { save() } }
    /// 非主组折成标题线（主组沿用 `tabGroupCollapsed`）
    var groupCollapsed: Set<String> = [] { didSet { save() } }
    /// 左 / 底列折成图标（右列 = `!dockShown`，不另设）
    var collapsedColumns: Set<PanelEdge> = [] { didSet { save() } }
    /// 列内相对尺寸（拖组间缝逐帧写——**热字段**，冷 getter 不许读）
    var groupWeights: [String: CGFloat] = [:] { didSet { save() } }
    /// 底列存档高（热）
    var bottomHeight: CGFloat = 220 { didSet { save() } }
    /// 多 tab 浮窗（阶段 3）：成员 → 锚工具。锚就是那扇窗的 id（`frames` / `zOrder` 照旧按工具 id）；
    /// 成员仍留在 `zOrder` 和 `frames` 里——浮窗模式不看这张表，每个工具还是自己一扇窗（④ 浮窗模式不动）
    var floatGroupOf: [String: String] = [:] { didSet { save() } }
    /// 多 tab 浮窗里选中的那个（锚 → 成员）
    var floatSelected: [String: String] = [:] { didSet { save() } }

    // MARK: 常量

    static let convWindowId = "conv"
    /// 主组：没有映射的停靠工具都在这里，恒在右列，不会被回收
    static let mainGroup = "g.main"
    static let defaultColumns: [PanelEdge: [String]] = [.left: [convWindowId], .right: [mainGroup], .bottom: []]
    /// 不是 `RightPanelTool` 的面板 id 的显示名：mac dock「桌面」开的 `home`（`RightPanelToolContent` 渲染 DashboardView）
    static func fallbackTitle(_ id: String) -> String { id == "home" ? "桌面" : id }
    static let minPanelWidth: CGFloat = 240
    static let maxPanelWidth: CGFloat = 460
    /// 同开封顶：第 4 个顶掉最早那个。浏览器 / CC 终端是重家伙，几个一起活着会卡。
    /// **只管浮窗模式**（她 09-24：保留两套模式千万别动）；停靠模式放宽到 `maxDockedTools`（「PS 自己不卡」）
    static let maxOpenTools = 3
    static let maxDockedTools = 12
    private var openLimit: Int { mode == .floating ? Self.maxOpenTools : Self.maxDockedTools }
    static let dockWidth: CGFloat = WidgetGridSpec.dockWidth
    /// 浮窗模式：面板离屏边的外边距 / dock 与窗口之间的间隙
    static let floatingMargin: CGFloat = 12
    static let dockGap: CGFloat = 10
    /// 全屏模式下正文至少留这么宽，拖面板 / 缩窗口时据此钳对话面板宽。
    /// mac 320（plan-mac-shape ⧫a：最小窗 980 = 面板 240 + 工具道 412 + 正文 320），iPad 沿用 400
    #if os(macOS)
    static let minBodyWidth: CGFloat = 320
    #else
    static let minBodyWidth: CGFloat = 400
    #endif
    /// 浮窗最小尺寸；新窗口级联错位；拖出屏外时标题栏至少留多少可见
    static let minWindowSize = CGSize(width: 240, height: 180)
    static let cascadeStep: CGFloat = 26
    static let windowKeepVisible: CGFloat = 80
    /// 吸边：进到多近开始吸；相邻时留多宽的缝
    static let snapDistance: CGFloat = 12
    static let snapGap: CGFloat = 10

    // MARK: 持久化

    struct LayoutSnapshot: Codable, Equatable {
        /// 存字串不存枚举：旧档里的 `"magnetic"`（已删的档）要能落回去，不然整份存档解不出来
        var mode: String
        var leftShown: Bool, dockShown: Bool
        var leftWidth: CGFloat, rightWidth: CGFloat
        var openTools: [String]
        var selectedTool: String?
        var detached: [String]?
        var minimized: [String]?
        var minimizedFrom: [String: String]?
        var snapToEdges: Bool?
        var frames: [String: WindowFrame]?
        var zOrder: [String]?
        var arrangement: String?
        var dockSide: String?
        /// 旧档没这个 key → 展开（astra F10）
        var tabGroupCollapsed: Bool?
        /// 旧档没这个 key → 360（plan-mac-fullscreen-shell-v2，工具面板内容宽可拖）
        var toolWidth: CGFloat?
        // plan-panel-ps §2.4：多组只**追加**可选字段，缺省 = 单组（旧档 / 旧包写回的档都这样读）
        var dockGroupOf: [String: String]?
        var columns: [String: [String]]?
        var groupSelected: [String: String]?
        var groupCollapsed: [String]?
        var collapsedColumns: [String]?
        var groupWeights: [String: CGFloat]?
        var bottomHeight: CGFloat?
        var floatGroupOf: [String: String]?
        var floatSelected: [String: String]?
    }
    private static let storageKey = "ipad.panel.layout.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey),
              let s = try? JSONDecoder().decode(LayoutSnapshot.self, from: data) else { return }
        // 从方法里赋值会触发 didSet（init 体里直接赋才不触发）：读档不该回写存档
        applying = true
        load(s)
        applying = false
        // 09-16 泳道解耦：工具侧从「dock 那边」变成恒在右，排版 a 的存档要按**旧的** dockSide 翻一次
        // （只跑一次，标记存在 defaults 里；排版 b 靠 DesktopGridRules 的单 zone 搬迁自己走，R-LD #3）。
        // **只在真身上跑**：测试会 new 一堆注入自己 defaults 的 layout，它们的 dockSide 是默认值 .right，
        // 而 `DesktopGridStore.shared` 写的是 .standard —— 不挡住就会把真存档的迁移标记白烧掉（实测踩过）
        if defaults == .standard, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            DesktopGridStore.shared.migrateForLaneDecouple(oldDockSide: dockSide)
        }
    }

    /// 把一份存档整份套上（启动读档 / 切工作区共用）。字段顺序有讲究：先落 `zOrder` 再落 `leftShown`——
    /// 它的 didSet 把开着的对话窗提到层级最前，跟一直以来读档的结果一样（`testSnapshotRoundTrip`）
    private func load(_ s: LayoutSnapshot) {
        mode = Mode(rawValue: s.mode) ?? .floating
        dockShown = s.dockShown
        leftWidth = s.leftWidth; rightWidth = s.rightWidth
        openTools = s.openTools
        selectedTool = s.selectedTool
        detached = (s.detached ?? []).filter { s.openTools.contains($0) }
        minimized = (s.minimized ?? []).filter { s.openTools.contains($0) }
        minimizedFrom = (s.minimizedFrom ?? [:]).filter { minimized.contains($0.key) }
        snapToEdges = s.snapToEdges ?? true
        frames = s.frames ?? [:]
        arrangement = s.arrangement.flatMap(DesktopArrangement.init(rawValue:)) ?? .a
        dockSide = s.dockSide.flatMap(DockSide.init(rawValue:)) ?? .right
        tabGroupCollapsed = s.tabGroupCollapsed ?? false
        toolWidth = s.toolWidth ?? 360
        dockGroupOf = s.dockGroupOf ?? [:]
        if let columns = s.columns {
            var cols: [PanelEdge: [String]] = [:]
            for (k, v) in columns { if let e = PanelEdge(rawValue: k) { cols[e] = v } }
            columnGroups = cols
        } else {
            columnGroups = Self.defaultColumns
        }
        groupSelected = s.groupSelected ?? [:]
        groupCollapsed = Set(s.groupCollapsed ?? [])
        collapsedColumns = Set((s.collapsedColumns ?? []).compactMap(PanelEdge.init(rawValue:)))
        groupWeights = s.groupWeights ?? [:]
        bottomHeight = s.bottomHeight ?? 220
        floatGroupOf = s.floatGroupOf ?? [:]
        floatSelected = s.floatSelected ?? [:]
        normalizeGroups()
        zOrder = (s.zOrder ?? s.openTools).filter { !minimized.contains($0) }
        leftShown = s.leftShown
        // 对话窗在层级里的进出再对齐一次（didSet 已把开着的对话窗提到最前）
        if leftShown, !zOrder.contains(Self.convWindowId) { zOrder.append(Self.convWindowId) }
        if !leftShown { zOrder.removeAll { $0 == Self.convWindowId } }
    }

    /// 此刻的布局存档（工作区「存为」拿它）
    func snapshot() -> LayoutSnapshot {
        LayoutSnapshot(mode: mode.rawValue, leftShown: leftShown, dockShown: dockShown,
                       leftWidth: leftWidth, rightWidth: rightWidth,
                       openTools: openTools, selectedTool: selectedTool, detached: detached,
                       minimized: minimized, minimizedFrom: minimizedFrom,
                       snapToEdges: snapToEdges, frames: frames, zOrder: zOrder,
                       arrangement: arrangement.rawValue, dockSide: dockSide.rawValue,
                       tabGroupCollapsed: tabGroupCollapsed, toolWidth: toolWidth,
                       dockGroupOf: dockGroupOf.isEmpty ? nil : dockGroupOf,
                       columns: columnGroups == Self.defaultColumns ? nil
                           : Dictionary(uniqueKeysWithValues: columnGroups.map { ($0.key.rawValue, $0.value) }),
                       groupSelected: groupSelected.isEmpty ? nil : groupSelected,
                       groupCollapsed: groupCollapsed.isEmpty ? nil : groupCollapsed.sorted(),
                       collapsedColumns: collapsedColumns.isEmpty ? nil : collapsedColumns.map(\.rawValue).sorted(),
                       groupWeights: groupWeights.isEmpty ? nil : groupWeights,
                       bottomHeight: bottomHeight == 220 ? nil : bottomHeight,
                       floatGroupOf: floatGroupOf.isEmpty ? nil : floatGroupOf,
                       floatSelected: floatSelected.isEmpty ? nil : floatSelected)
    }

    /// 读档 / 套工作区后的修复（plan-panel-ps §2.4）：纯靠现有字段、幂等。坏档只会退回更接近单组的样子，不崩。
    /// 顺序：openTools 去重 → 列去重（跨列先到先得）+ 补两个哨兵 → 映射只留开着的工具、指向列里的普通组 →
    /// 没有成员映射的普通组摘掉 → 组内选中 / 折叠 / 尺寸只留活组
    private func normalizeGroups() {
        var seen = Set<String>()
        let tools = openTools.filter { seen.insert($0).inserted }
        if tools != openTools { openTools = tools }

        let main = Self.mainGroup, conv = Self.convWindowId
        var used = Set<String>()
        var cols: [PanelEdge: [String]] = [:]
        for e in PanelEdge.allCases {
            cols[e] = (columnGroups[e] ?? []).filter { g in
                guard !g.isEmpty, used.insert(g).inserted else { return false }
                if g == conv { return e == .left }
                if g == main { return e == .right }
                return true
            }
        }
        if cols[.left]?.contains(conv) != true { cols[.left, default: []].insert(conv, at: 0) }
        if cols[.right]?.contains(main) != true { cols[.right, default: []].insert(main, at: 0) }

        let live = Set(cols.values.flatMap { $0 })
        let mapping = dockGroupOf.filter { tools.contains($0.key) && live.contains($0.value) && $0.value != main && $0.value != conv }
        let mapped = Set(mapping.values)
        for e in PanelEdge.allCases {
            cols[e] = cols[e]?.filter { $0 == main || $0 == conv || mapped.contains($0) }
        }
        if mapping != dockGroupOf { dockGroupOf = mapping }
        if cols != columnGroups { columnGroups = cols }

        let selected = groupSelected.filter { mapped.contains($0.key) && mapping[$0.value] == $0.key }
        if selected != groupSelected { groupSelected = selected }
        let collapsed = groupCollapsed.filter { mapped.contains($0) }
        if collapsed != groupCollapsed { groupCollapsed = collapsed }
        let weights = groupWeights.filter { (mapped.contains($0.key) || $0.key == main || $0.key == conv) && $0.value.isFinite && $0.value > 0 }
        if weights != groupWeights { groupWeights = weights }
        if !bottomHeight.isFinite || bottomHeight <= 0 { bottomHeight = 220 }

        // 多 tab 浮窗：成员必须浮着（或缩着），锚必须浮着、没缩、自己不是别人的成员；锚链拍平成一层
        var floats: [String: String] = [:]
        for (member, anchor) in floatGroupOf {
            var a = anchor
            if let up = floatGroupOf[a], up != member { a = up }
            guard a != member, tools.contains(member), tools.contains(a), detached.contains(member),
                  detached.contains(a), !minimized.contains(a) else { continue }
            floats[member] = a
        }
        for a in Set(floats.values) where floats[a] != nil { floats[a] = nil }
        if floats != floatGroupOf { floatGroupOf = floats }
        let anchors = Set(floats.values)
        let fsel = floatSelected.filter { anchors.contains($0.key) && ($0.value == $0.key || floats[$0.value] == $0.key) }
        if fsel != floatSelected { floatSelected = fsel }
    }

    /// 切工作区：整份换上，只落一次盘（逐字段 didSet 的存档被 `applying` 压住）。
    /// mac 先清掉飞行 / 拖放这些瞬态，别让旧布局的幽灵框飞到新布局里
    func apply(_ s: LayoutSnapshot) {
        #if os(macOS)
        cancelMacPresentation()
        #endif
        applying = true
        load(s)
        applying = false
        save()
    }

    /// 出厂布局：各项回默认，**开着的工具不关**——全部回 tab 组（浮出的、缩起的都收回来），选中不变
    func factorySnapshot() -> LayoutSnapshot {
        LayoutSnapshot(mode: Mode.docked.rawValue, leftShown: false, dockShown: true,
                       leftWidth: 320, rightWidth: 300, openTools: openTools, selectedTool: selectedTool,
                       detached: [], minimized: [], minimizedFrom: [:], snapToEdges: true, frames: [:],
                       zOrder: openTools, arrangement: DesktopArrangement.a.rawValue, dockSide: DockSide.right.rawValue,
                       tabGroupCollapsed: false, toolWidth: 360)
    }

    /// 一轮 runloop 只落一次盘：一次收放 = 两三个 didSet，拖宽 / 拖窗是逐帧 didSet，每个都同步写
    /// UserDefaults 是 09-18 trace 里收放面板 0.3–0.5s hang 的直接触发点（docs/research-prefs-domain-bloat.md §3 C）
    @ObservationIgnored private var saveScheduled = false
    /// `apply` 整份换档期间为 true：逐字段 didSet 不各自存，换完统一存一次
    @ObservationIgnored private var applying = false

    private func save() {
        guard !applying else { return }
        // 测试注的 suite 要改完立刻能读到（18 处 `IPadPanelLayout(defaults:)` 重读），只有生产 `.standard` 合并
        guard defaults === UserDefaults.standard else { persistNow(); return }
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushPendingSave() }
    }

    /// 把挂起的存档立刻写盘（测试里改完状态马上读 defaults 用；生产靠 runloop 自动 flush）
    func flushPendingSave() {
        guard saveScheduled else { return }
        saveScheduled = false
        persistNow()
    }

    private func persistNow() {
        if let data = try? JSONEncoder().encode(snapshot()) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: 工具：开 / 关 / tab 组

    func isOpen(_ toolId: String) -> Bool { openTools.contains(toolId) }

    /// 全屏模式所有停靠组的成员（开着的里头没浮出去、没缩起来的），按 右列 → 左列 → 底列、列内组序排；
    /// 组内顺序 = 打开顺序。**单组时 = 今天**；iPad 的 tab 栏只读这份投影
    var tabs: [String] {
        let docked = openTools.filter { !detached.contains($0) && !minimized.contains($0) }
        guard !dockGroupOf.isEmpty else { return docked }
        var out: [String] = []
        for edge in [PanelEdge.right, .left, .bottom] {
            for g in columnGroups[edge] ?? [] { out += docked.filter { group(of: $0) == g } }
        }
        return out
    }

    /// 当前选中的 tab；存档里的选中项失效（被关 / 浮出）时兜底到最后一个
    var currentTab: String? {
        if let s = selectedTool, tabs.contains(s) { return s }
        return tabs.last
    }

    // MARK: 组（plan-panel-ps §2.2）

    /// 工具所在的停靠组：映射指向的组已不在任何列 → 主组
    func group(of toolId: String) -> String {
        guard let g = dockGroupOf[toolId], edge(of: g) != nil else { return Self.mainGroup }
        return g
    }

    func edge(of groupId: String) -> PanelEdge? {
        PanelEdge.allCases.first { columnGroups[$0]?.contains(groupId) == true }
    }

    /// 一个组此刻的 tab（不浮、不缩），顺序 = 打开顺序
    func tabs(in groupId: String) -> [String] {
        openTools.filter { !detached.contains($0) && !minimized.contains($0) && group(of: $0) == groupId }
    }

    /// 组内选中：主组 = 旧 `currentTab` 限定在主组；其它组 = 全局焦点在组里就是它，否则组自己记的，再否则末个
    func selected(in groupId: String) -> String? {
        let t = tabs(in: groupId)
        if let s = selectedTool, t.contains(s) { return s }
        if groupId != Self.mainGroup, let s = groupSelected[groupId], t.contains(s) { return s }
        return t.last
    }

    func isCollapsed(_ groupId: String) -> Bool {
        groupId == Self.mainGroup ? tabGroupCollapsed : groupCollapsed.contains(groupId)
    }

    func setCollapsed(_ groupId: String, _ collapsed: Bool) {
        if groupId == Self.mainGroup {
            if tabGroupCollapsed != collapsed { tabGroupCollapsed = collapsed }
        } else if collapsed != groupCollapsed.contains(groupId) {
            if collapsed { groupCollapsed.insert(groupId) } else { groupCollapsed.remove(groupId) }
        }
    }

    /// 某列此刻要画的组：有 tab 的组；左列的 `conv` 哨兵在对话列表开着时算
    func visibleGroups(_ edge: PanelEdge) -> [String] {
        (columnGroups[edge] ?? []).filter { g in
            g == Self.convWindowId ? leftShown : !tabs(in: g).isEmpty
        }
    }

    /// 某列此刻收着：右列 = 工具钮关了；左 / 底列 = 折成图标
    func isColumnHidden(_ edge: PanelEdge?) -> Bool {
        switch edge {
        case .right?: return !dockShown
        case .left?, .bottom?: return collapsedColumns.contains(edge!)
        case nil: return false
        }
    }

    /// 左 / 底列 折成图标 ⇄ 展开
    func toggleColumnCollapsed(_ edge: PanelEdge) {
        guard edge != .right else { dockShown.toggle(); return }
        if collapsedColumns.contains(edge) { collapsedColumns.remove(edge) } else { collapsedColumns.insert(edge) }
    }

    /// 左列看得见：没折成图标，且对话列表开着或有工具组
    var leftColumnVisible: Bool {
        !collapsedColumns.contains(.left) && !visibleGroups(.left).isEmpty
    }

    /// 底列看得见：没折叠且有 tab
    var bottomColumnVisible: Bool {
        !collapsedColumns.contains(.bottom) && !visibleGroups(.bottom).isEmpty
    }

    /// 选中一个停靠工具：全局焦点 + 组内选中 + 展开它的组
    func select(_ toolId: String) {
        if selectedTool != toolId { selectedTool = toolId }
        let g = group(of: toolId)
        if g != Self.mainGroup, groupSelected[g] != toolId { groupSelected[g] = toolId }
        setCollapsed(g, false)
    }

    private func setGroup(_ toolId: String, _ groupId: String) {
        let value: String? = groupId == Self.mainGroup ? nil : groupId
        if dockGroupOf[toolId] != value { dockGroupOf[toolId] = value }
    }

    /// 没有任何开着的工具还映射到它的组从列里摘掉（主组 / 哨兵除外）。浮着、缩着的成员也算——它们要回来
    private func pruneGroup(_ groupId: String) {
        guard groupId != Self.mainGroup, groupId != Self.convWindowId,
              !openTools.contains(where: { dockGroupOf[$0] == groupId }),
              let edge = edge(of: groupId) else { return }
        columnGroups[edge]?.removeAll { $0 == groupId }
        groupSelected[groupId] = nil
        groupCollapsed.remove(groupId)
        groupWeights[groupId] = nil
        #if os(macOS)
        macGroupBarFrames[groupId] = nil
        #endif
    }

    /// 组里最后一个 tab 走了：折叠清掉（空组没有标题线可折）
    private func settleEmptied(_ groupId: String) {
        if tabs(in: groupId).isEmpty { setCollapsed(groupId, false) }
    }

    /// 此刻要画成窗的：浮窗模式 = 全部层级成员；全屏模式 = 只有浮出去的那几个（缩起来的不在 zOrder 里）
    var windowIds: [String] {
        mode == .docked ? zOrder.filter { detached.contains($0) && floatGroupOf[$0] == nil } : zOrder
    }

    /// 开着就关，关着就开（浮窗模式的 dock 语义）；缩起来的 → 恢复
    func toggle(_ toolId: String) {
        if minimized.contains(toolId) { restore(toolId) } else if isOpen(toolId) { close(toolId) } else { open(toolId) }
    }

    /// dock 点图标。缩起来的 → 恢复。全屏模式三段：没开 → 开成 tab 并选中；开着没选中 → 选中；已选中 → 关。
    /// 浮出去的 → 提到最前。dock 亮 = 开着，语义不变。浮窗模式 = 开 ⇄ 关
    func dockTap(_ toolId: String) {
        if minimized.contains(toolId) { restore(toolId); return }
        guard mode == .docked else { toggle(toolId); return }
        #if os(macOS)
        if macFlyoutTap(toolId) { return }
        #endif
        if !isOpen(toolId) {
            open(toolId)
        } else if detached.contains(toolId) {
            selectFloat(toolId)
        } else if selected(in: group(of: toolId)) == toolId, currentTab == toolId, !isCollapsed(group(of: toolId)) {
            close(toolId)
        } else {
            select(toolId)
        }
    }

    /// 开到上限顶掉最早那个（Safari 标签式；浮窗模式 3、停靠 12）。已开着的：缩起来的恢复，浮出去的提到最前，tab 就选中它
    func open(_ toolId: String) {
        guard !isOpen(toolId) else {
            if minimized.contains(toolId) { restore(toolId); return }
            if !detached.contains(toolId) { select(toolId) }
            bringToFront(toolId)
            if floatGroupOf[toolId] != nil { selectFloat(toolId) }
            return
        }
        var tools = openTools
        tools.append(toolId)
        while tools.count > openLimit {
            let evicted = tools.removeFirst()
            forget(evicted)
        }
        openTools = tools
        selectedTool = toolId
        tabGroupCollapsed = false
        bringToFront(toolId)
    }

    func close(_ toolId: String) {
        let g = group(of: toolId)
        let neighbor = neighborTab(of: toolId)
        openTools.removeAll { $0 == toolId }
        forget(toolId)
        if selectedTool == toolId { selectedTool = neighbor }
        settleEmptied(g)
        pruneGroup(g)
    }

    /// PS 拖 tab 换位（A2a）：`slot` = 在它**所在组当前** tab（含被拖的这个）里的插入槽位 0...count，半槽算法见 `TabInsertion`；
    /// 落回自己的左右两槽 = 不动
    func moveTab(_ toolId: String, to slot: Int) {
        var t = tabs(in: group(of: toolId))
        guard let from = t.firstIndex(of: toolId) else { return }
        t.remove(at: from)
        t.insert(toolId, at: min(max(0, slot > from ? slot - 1 : slot), t.count))
        reorderTabs(t)
    }

    /// 只重排一组 tab 之间的相对顺序：`openTools` 里别的项原位不动（它们的位置就是被顶掉的先后）
    private func reorderTabs(_ t: [String]) {
        let members = Set(t)
        let current = openTools.filter { members.contains($0) }
        guard t != current else { return }
        var next = t.makeIterator()
        openTools = openTools.map { members.contains($0) ? next.next()! : $0 }
    }

    /// 从层级 / 浮出 / 缩起 / 分组 名单里全部除名（关掉或被顶掉）
    private func forget(_ toolId: String) {
        #if os(macOS)
        macFlightTargets[toolId] = nil
        flights[toolId] = nil
        macTabFrames[toolId] = nil
        if draggingTab == toolId { endMacTabDrag() }
        if macFirstClickExpandedTab == toolId { macFirstClickExpandedTab = nil }
        #endif
        leaveFloat(toolId)
        zOrder.removeAll { $0 == toolId }
        detached.removeAll { $0 == toolId }
        minimized.removeAll { $0 == toolId }
        minimizedFrom[toolId] = nil
        if let g = dockGroupOf[toolId] {
            dockGroupOf[toolId] = nil
            if groupSelected[g] == toolId { groupSelected[g] = nil }
            pruneGroup(g)
        }
    }

    /// 关掉 / 浮出选中的 tab 后接棒的那个：**同组里**优先右邻，没有就左邻
    private func neighborTab(of toolId: String) -> String? {
        let t = tabs(in: group(of: toolId))
        guard let i = t.firstIndex(of: toolId) else { return currentTab }
        if i + 1 < t.count { return t[i + 1] }
        return i > 0 ? t[i - 1] : nil
    }

    /// 全屏模式：把一个 tab 从栏里脱出成一扇盖在正文上的窗。初始位置贴在工具栏内侧（像是从栏里滑出来），
    /// 之后的位置由 `frames` 记。所在组的映射保留（停回回原组）
    func detach(_ toolId: String, in size: CGSize) {
        guard tabs.contains(toolId) else { return }
        let g = group(of: toolId)
        let neighbor = neighborTab(of: toolId)
        if size.width > 0, size.height > 0 {
            let w = rightWidth
            let h = min(560, max(Self.minWindowSize.height, size.height - 120))
            // 浮窗从工具面板飞出来 ⇒ 落点跟**工具侧（恒右）**，不跟 dock（R-LD #6）。
            // dock 在右时它占掉最外沿那条要减掉；dock 在左时右边没有 dock，不减
            let dockGutter = dockSide == .right ? Self.dockWidth : 0
            // mac 停靠壳的工具面板是 `toolWidth`（渲染钳后）不是 rightWidth（R-FS2 S3）
            var panelWidth = rightWidth
            #if os(macOS)
            if mode == .docked { panelWidth = macShellFrame(in: size).tool ?? rightWidth }
            #endif
            let x = max(Self.floatingMargin, size.width - dockGutter - panelWidth - w - Self.floatingMargin)
            frames[toolId] = clamped(WindowFrame(x: x, y: 56, w: w, h: h), in: size)
        }
        detached.append(toolId)
        if selectedTool == toolId || selectedTool == nil { selectedTool = neighbor }
        settleEmptied(g)
        bringToFront(toolId)
    }

    /// 拖 tab 丢到工作区空处（A2a 目标 ③）：落点定位置——标题栏中点落在指针下。
    /// 已经浮出的（拖浮窗标题）= 只搬位置
    func detach(_ toolId: String, at point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if tabs.contains(toolId) { detach(toolId, in: size) }
        guard detached.contains(toolId) else { return }
        // 多 tab 浮窗里拖一个 tab 出来 = 拆成自己一扇窗（尺寸跟原窗一样），落在指针下
        let window = windowId(of: toolId)
        if floatMembers(of: window).count > 1 {
            let windowFrame = currentFrame(window, in: size)
            leaveFloat(toolId)
            frames[toolId] = windowFrame
        }
        let f = currentFrame(toolId, in: size)
        frames[toolId] = clamped(WindowFrame(x: point.x - f.w / 2, y: point.y - 20, w: f.w, h: f.h), in: size)
        bringToFront(toolId)
    }

    /// 浮窗「停回」：回原来那个组（组没了回主组）并选中（组折着就展开）
    func attach(_ toolId: String) {
        leaveFloat(toolId)
        detached.removeAll { $0 == toolId }
        if dockGroupOf[toolId] != nil, group(of: toolId) == Self.mainGroup { dockGroupOf[toolId] = nil }
        select(toolId)
    }

    /// 拖进它所在组 tab 栏的某个槽位（A2a 目标 ① / ②）：来源是 tab 就换位；是浮窗标题就先停回再插到那一槽
    /// （`slot` 按悬停时看到的 tab 栏算——那时它还没在栏里，所以不用像 `moveTab` 那样扣掉自己）
    func attach(_ toolId: String, at slot: Int) {
        attach(toolId, to: group(of: toolId), at: slot)
    }

    /// 拖进**指定组**的某个槽位：浮着的先停进那个组；停靠的同组换位、跨组搬过去
    func attach(_ toolId: String, to groupId: String, at slot: Int) {
        guard detached.contains(toolId) else { move(toolId, toGroup: groupId, at: slot); return }
        leaveFloat(toolId)
        detached.removeAll { $0 == toolId }
        setGroup(toolId, groupId)
        select(toolId)
        var t = tabs(in: groupId)
        t.removeAll { $0 == toolId }
        t.insert(toolId, at: min(max(0, slot), t.count))
        reorderTabs(t)
    }

    /// 停靠工具搬到另一个组的某一槽（同组 = `moveTab`）。原组交棒、空了就回收
    func move(_ toolId: String, toGroup groupId: String, at slot: Int) {
        guard tabs.contains(toolId), edge(of: groupId) != nil, groupId != Self.convWindowId else { return }
        let from = group(of: toolId)
        guard from != groupId else { moveTab(toolId, to: slot); return }
        let neighbor = neighborTab(of: toolId)
        if groupSelected[from] == toolId { groupSelected[from] = neighbor }
        setGroup(toolId, groupId)
        var t = tabs(in: groupId)
        t.removeAll { $0 == toolId }
        t.insert(toolId, at: min(max(0, slot), t.count))
        reorderTabs(t)
        select(toolId)
        settleEmptied(from)
        pruneGroup(from)
    }

    /// 新建一个组放在某列的第 `index` 位（按该列 `columnGroups` 的下标，含哨兵），把工具搬进去。返回新组 id
    @discardableResult
    func insertGroup(with toolId: String, edge: PanelEdge, at index: Int) -> String? {
        guard isOpen(toolId), !minimized.contains(toolId) else { return nil }
        let id = "g." + UUID().uuidString.prefix(8).lowercased()
        var col = columnGroups[edge] ?? []
        col.insert(id, at: min(max(0, index), col.count))
        columnGroups[edge] = col
        if collapsedColumns.contains(edge) { collapsedColumns.remove(edge) }
        if edge == .right, !dockShown { dockShown = true }
        if detached.contains(toolId) { attach(toolId, to: id, at: 0) } else { move(toolId, toGroup: id, at: 0) }
        return id
    }

    // MARK: 窗 ⇄ 桌面小组件

    /// 把一扇窗 / 一个 tab 缩成桌面上的 1×1。格子满了就不缩（返回 false）
    @discardableResult
    func minimize(_ toolId: String, in size: CGSize, widgetCells: Int) -> Bool {
        guard isOpen(toolId), !minimized.contains(toolId), hasRoomForOneMore(in: size, widgetCells: widgetCells) else { return false }
        let fromTab = mode == .docked && tabs.contains(toolId)
        if fromTab {
            let g = group(of: toolId)
            let neighbor = neighborTab(of: toolId)
            detached.append(toolId)
            if selectedTool == toolId { selectedTool = neighbor }
            settleEmptied(g)
        }
        minimizedFrom[toolId] = fromTab ? "tab" : "window"
        // 多 tab 浮窗的锚缩起来：窗留给下一个成员，自己记住回哪扇窗
        if !fromTab, floatGroupOf[toolId] == nil, let next = reanchor(from: toolId) { floatGroupOf[toolId] = next }
        zOrder.removeAll { $0 == toolId }
        minimized.append(toolId)
        return true
    }

    /// 点桌面上那块：回它原来的形态（tab 就回原组并选中，窗就回原位置到最前）
    func restore(_ toolId: String) {
        guard minimized.contains(toolId) else { return }
        minimized.removeAll { $0 == toolId }
        let from = minimizedFrom[toolId]
        minimizedFrom[toolId] = nil
        if from == "tab", mode == .docked {
            attach(toolId)
        } else if let a = floatGroupOf[toolId] {
            // 原来那扇多 tab 窗还在 → 回去并选中；不在了 → 自己一扇窗（框用它自己记的，没有就用锚的）
            bringToFront(toolId)
            if detached.contains(a), !minimized.contains(a), floatGroupOf[a] == nil {
                floatSelected[a] = toolId
                bringToFront(a)
            } else {
                if frames[toolId] == nil { frames[toolId] = frames[a] }
                floatGroupOf[toolId] = nil
            }
        } else {
            bringToFront(toolId)
        }
    }

    // MARK: 多 tab 浮窗（plan-panel-ps 阶段 3）

    /// 工具此刻在哪扇窗里（成员 → 锚；自己一扇窗 / 停靠的 → 自己）
    func windowId(of toolId: String) -> String {
        floatGroupOf[toolId] ?? toolId
    }

    /// 一扇浮窗的 tab：锚 + 成员里浮着没缩的，顺序 = 打开顺序
    func floatMembers(of anchor: String) -> [String] {
        openTools.filter { ($0 == anchor || floatGroupOf[$0] == anchor) && detached.contains($0) && !minimized.contains($0) }
    }

    /// 浮窗里选中的 tab（没记 / 记的失效 → 锚）
    func floatSelection(in anchor: String) -> String {
        let members = floatMembers(of: anchor)
        if let s = floatSelected[anchor], members.contains(s) { return s }
        return members.contains(anchor) ? anchor : (members.first ?? anchor)
    }

    /// 选中浮窗里的某个 tab 并把那扇窗提到最前
    func selectFloat(_ toolId: String) {
        let window = windowId(of: toolId)
        if window != toolId || floatSelected[window] != nil {
            if floatSelected[window] != toolId { floatSelected[window] = toolId }
        }
        bringToFront(window)
    }

    /// 并进某扇浮窗（PS：把 tab 拖到另一个浮动面板的 tab 栏 / 正文）。来源可以是停靠的 tab、别的浮窗、同窗换位
    func merge(_ toolId: String, into anchor: String, at slot: Int? = nil) {
        let target = windowId(of: anchor)
        guard isOpen(toolId), !minimized.contains(toolId), detached.contains(target), !minimized.contains(target),
              floatGroupOf[target] == nil, toolId != target || floatMembers(of: target).count > 1 else { return }
        if tabs.contains(toolId) {
            let g = group(of: toolId)
            let neighbor = neighborTab(of: toolId)
            detached.append(toolId)
            if selectedTool == toolId { selectedTool = neighbor }
            settleEmptied(g)
        } else if windowId(of: toolId) != target {
            leaveFloat(toolId)
        }
        if toolId != target, floatGroupOf[toolId] != target { floatGroupOf[toolId] = target }
        if let slot {
            var t = floatMembers(of: target)
            t.removeAll { $0 == toolId }
            t.insert(toolId, at: min(max(0, slot), t.count))
            reorderTabs(t)
        }
        if floatSelected[target] != toolId { floatSelected[target] = toolId }
        bringToFront(target)
    }

    /// 停回整扇多 tab 窗：成员一起成为右列末尾的一个新组（单 tab 窗 = 普通停回，回原组）
    func attachWindow(_ anchor: String) {
        let members = floatMembers(of: anchor)
        guard members.count > 1, let first = members.first else { attach(anchor); return }
        // 停回过程中会逐个离窗、选中记录跟着清掉，先记下窗里选中的那个
        let focus = floatSelection(in: anchor)
        guard let g = insertGroup(with: first, edge: .right, at: columnGroups[.right]?.count ?? 0) else { return }
        for m in members.dropFirst() { attach(m, to: g, at: tabs(in: g).count) }
        select(focus)
    }

    /// 关掉整扇多 tab 窗
    func closeWindow(_ anchor: String) {
        for m in floatMembers(of: anchor).reversed() { close(m) }
        if isOpen(anchor) { close(anchor) }
    }

    /// 从所在的多 tab 浮窗里出来：成员 → 断开；锚 → 窗交给下一个成员
    private func leaveFloat(_ toolId: String) {
        if let a = floatGroupOf[toolId] {
            floatGroupOf[toolId] = nil
            if floatSelected[a] == toolId { floatSelected[a] = nil }
        } else {
            _ = reanchor(from: toolId)
        }
    }

    /// 锚要走了：下一个成员继承窗的框、层级位置和选中，其余成员改挂它。返回新锚（没有成员 = nil）
    @discardableResult
    private func reanchor(from old: String) -> String? {
        let members = openTools.filter { floatGroupOf[$0] == old }
        let selected = floatSelected[old]
        if selected != nil { floatSelected[old] = nil }
        // 只剩缩起来的成员：窗散了，它们恢复时各自成窗（框用原窗的）；缩着的不进层级
        guard let next = members.first(where: { !minimized.contains($0) }) else {
            for m in members {
                floatGroupOf[m] = nil
                if frames[m] == nil, let f = frames[old] { frames[m] = f }
            }
            return nil
        }
        if let f = frames[old] { frames[next] = f }
        var z = zOrder
        z.removeAll { $0 == next }
        if let i = z.firstIndex(of: old) { z.insert(next, at: i + 1) } else { z.append(next) }
        if z != zOrder { zOrder = z }
        floatGroupOf[next] = nil
        for m in members where m != next { floatGroupOf[m] = next }
        if let selected, selected != old, members.contains(selected) { floatSelected[next] = selected }
        return next
    }

    /// 桌面格子还有没有空位：小组件占的格数（调用方按排版算好传入）+ 已缩起来的工具数 < 总格数
    private func hasRoomForOneMore(in size: CGSize, widgetCells: Int) -> Bool {
        // mac 停靠壳的格子在空地上（`desktopGrid`）——按旧格子算会少一行、还挂着 480 的闸（R-FS2 I1）
        #if os(macOS)
        let availableGrid = mode == .docked ? macShellFrame(in: size, reservingDesktopSpace: true).grid : desktopGrid(in: size)
        #else
        let availableGrid = desktopGrid(in: size)
        #endif
        guard let g = availableGrid else { return false }
        let cells = g.zones.reduce(0) { $0 + $1.cols } * g.rows
        return widgetCells + minimized.count < cells
    }

    // MARK: 浮窗层级与位置

    /// 触摸落到哪扇窗就把它提到最前；已在最前不动（避免拖动每帧都改数组）
    func bringToFront(_ id: String) {
        guard zOrder.last != id else { return }
        var z = zOrder
        z.removeAll { $0 == id }
        z.append(id)
        zOrder = z
    }

    /// 没记过位置的窗口：对话窗贴左满高；工具窗靠右、从 dock 左边起，按层级序号级联错位
    func defaultFrame(for id: String, in size: CGSize) -> WindowFrame {
        let m = Self.floatingMargin
        if id == Self.convWindowId {
            return WindowFrame(x: m, y: m, w: 320, h: max(Self.minWindowSize.height, size.height - m * 2))
        }
        let index = CGFloat(max(0, zOrder.firstIndex(of: id) ?? zOrder.count))
        let w: CGFloat = 320
        let h = min(520, max(Self.minWindowSize.height, size.height * 0.62))
        let step = Self.cascadeStep * index
        return WindowFrame(x: size.width - m - Self.dockWidth - Self.dockGap - w - step,
                           y: m + step, w: w, h: h)
    }

    /// 这扇窗此刻的位置尺寸（记过的 / 默认的，钳过）
    func currentFrame(_ id: String, in size: CGSize) -> WindowFrame {
        clamped(frames[id] ?? defaultFrame(for: id, in: size), in: size)
    }

    // MARK: 吸边（拖近屏边 / 邻窗就吸上去对齐或留缝，画辅助线）

    /// 其余窗口在某一轴上的边 + 屏边界。`starts` = 左/上边，`ends` = 右/下边。
    /// 横向边界 = 聊天区两侧（有桌面格子时吸到格线上；没有时 = 屏边 / dock 那条道）
    private func neighborEdges(vertical: Bool, excluding: Set<String>, in size: CGSize)
        -> (starts: [CGFloat], ends: [CGFloat], lo: CGFloat, hi: CGFloat) {
        var starts: [CGFloat] = [], ends: [CGFloat] = []
        for other in windowIds where !excluding.contains(other) {
            let f = currentFrame(other, in: size)
            starts.append(vertical ? f.x : f.y)
            ends.append(vertical ? f.x + f.w : f.y + f.h)
        }
        let m = Self.floatingMargin
        #if os(macOS)
        // 停靠壳：横向吸到**正文卡的边**（R-FS2 I2）；旧 lane 公式与新几何差一个缝级、面板开着那侧还根本没空地
        if mode == .docked {
            let f = macShellFrame(in: size)
            return vertical ? (starts, ends, f.cardX, f.cardX + f.card) : (starts, ends, m, size.height - m)
        }
        #endif
        let li = leftInset(in: size), ri = rightInset(in: size)
        let lo = li > 0 ? li : m
        let hi = size.width - (ri > 0 ? ri : (dockShown ? m + Self.dockWidth + Self.dockGap : m))
        return vertical ? (starts, ends, lo, hi) : (starts, ends, m, size.height - m)
    }

    /// 一条边找最近的吸附目标（在 snapDistance 内）。返回 (要挪多少, 目标线在哪)
    private func nearest(_ edge: CGFloat, targets: [(value: CGFloat, guide: CGFloat)]) -> (delta: CGFloat, guide: CGFloat)? {
        var best: (delta: CGFloat, guide: CGFloat)?
        for t in targets {
            let d = t.value - edge
            guard abs(d) <= Self.snapDistance else { continue }
            if best == nil || abs(d) < abs(best!.delta) { best = (d, t.guide) }
        }
        return best
    }

    /// 整体平移时一轴的吸附：我的两条边都参与——起边对齐邻窗起边 / 贴邻窗终边留缝 / 贴屏界；终边对称
    private func moveSnap(lo: CGFloat, hi: CGFloat,
                          n: (starts: [CGFloat], ends: [CGFloat], lo: CGFloat, hi: CGFloat)) -> (delta: CGFloat, guide: CGFloat)? {
        let g = Self.snapGap
        var targets: [(CGFloat, CGFloat)] = []
        // 我的起边
        targets += n.starts.map { ($0, $0) } + n.ends.map { ($0 + g, $0) } + [(n.lo, n.lo)]
        let a = nearest(lo, targets: targets.map { (value: $0.0, guide: $0.1) })
        // 我的终边：目标值换算成起边位移
        var t2: [(CGFloat, CGFloat)] = []
        t2 += n.ends.map { ($0, $0) } + n.starts.map { ($0 - g, $0) } + [(n.hi, n.hi)]
        let b = nearest(hi, targets: t2.map { (value: $0.0, guide: $0.1) })
        switch (a, b) {
        case let (a?, b?): return abs(a.delta) <= abs(b.delta) ? a : b
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// 拖动移位时的吸边
    func magnetize(move f: WindowFrame, id: String, in size: CGSize) -> WindowFrame {
        var r = f
        var guides: [SnapGuide] = []
        if let s = moveSnap(lo: f.x, hi: f.x + f.w, n: neighborEdges(vertical: true, excluding: [id], in: size)) {
            r.x += s.delta; guides.append(SnapGuide(vertical: true, at: s.guide))
        }
        if let s = moveSnap(lo: f.y, hi: f.y + f.h, n: neighborEdges(vertical: false, excluding: [id], in: size)) {
            r.y += s.delta; guides.append(SnapGuide(vertical: false, at: s.guide))
        }
        snapGuides = guides
        return r
    }

    /// 缩放时的吸边：**只有在动的边参与**（拖角 = 两条边；mac 拖一条边 = 只那一条，另一轴不吸，astra F12）
    func magnetize(resize f: WindowFrame, movingEdges: Set<Edge>, id: String, in size: CGSize) -> WindowFrame {
        var r = f
        var guides: [SnapGuide] = []
        let g = Self.snapGap
        if movingEdges.contains(.leading) || movingEdges.contains(.trailing) {
            let nx = neighborEdges(vertical: true, excluding: [id], in: size)
            if movingEdges.contains(.leading) {
                let t = nx.starts.map { (value: $0, guide: $0) } + nx.ends.map { (value: $0 + g, guide: $0) } + [(value: nx.lo, guide: nx.lo)]
                if let s = nearest(f.x, targets: t), f.w - s.delta >= Self.minWindowSize.width {
                    r.x += s.delta; r.w -= s.delta; guides.append(SnapGuide(vertical: true, at: s.guide))
                }
            } else {
                let t = nx.ends.map { (value: $0, guide: $0) } + nx.starts.map { (value: $0 - g, guide: $0) } + [(value: nx.hi, guide: nx.hi)]
                if let s = nearest(f.x + f.w, targets: t), f.w + s.delta >= Self.minWindowSize.width {
                    r.w += s.delta; guides.append(SnapGuide(vertical: true, at: s.guide))
                }
            }
        }
        if movingEdges.contains(.top) || movingEdges.contains(.bottom) {
            let ny = neighborEdges(vertical: false, excluding: [id], in: size)
            if movingEdges.contains(.top) {
                let t = ny.starts.map { (value: $0, guide: $0) } + ny.ends.map { (value: $0 + g, guide: $0) } + [(value: ny.lo, guide: ny.lo)]
                if let s = nearest(f.y, targets: t), f.h - s.delta >= Self.minWindowSize.height {
                    r.y += s.delta; r.h -= s.delta; guides.append(SnapGuide(vertical: false, at: s.guide))
                }
            } else {
                let t = ny.ends.map { (value: $0, guide: $0) } + ny.starts.map { (value: $0 - g, guide: $0) } + [(value: ny.hi, guide: ny.hi)]
                if let s = nearest(f.y + f.h, targets: t), f.h + s.delta >= Self.minWindowSize.height {
                    r.h += s.delta; guides.append(SnapGuide(vertical: false, at: s.guide))
                }
            }
        }
        snapGuides = guides
        return r
    }

    /// 钳制：尺寸不小于下限、不超过可用区；位置允许拖出屏外，但标题栏那一段得留在屏内
    func clamped(_ f: WindowFrame, in size: CGSize) -> WindowFrame {
        guard size.width > 0, size.height > 0 else { return f }
        var r = f
        r.w = max(Self.minWindowSize.width, min(size.width - Self.floatingMargin * 2, f.w))
        r.h = max(Self.minWindowSize.height, min(size.height - Self.floatingMargin * 2, f.h))
        r.x = max(Self.windowKeepVisible - r.w, min(size.width - Self.windowKeepVisible, f.x))
        r.y = max(0, min(size.height - 44, f.y))
        return r
    }

    // MARK: 桌面格子 + 正文让位

    /// 令牌：iPad 按机型查档；mac 常量 `.mac`（plan-mac-shape A3，⧫8）；测试可钉
    var gridSpec: WidgetGridSpec {
        if let gridSpecOverride { return gridSpecOverride }
        #if os(macOS)
        return .mac
        #else
        return WidgetGridSpec.forScreen(screenSize)
        #endif
    }

    /// **工具面板恒在右、对话列表恒在左**（她 09-16：「工具页面永远放右边，列表永远从左边出来」）。
    /// `dockSide` 从此只决定那条竖 dock 图标条贴哪边——三者解耦（plan-lane-decouple）
    static let toolsSide: GridFrame.Side = .right
    static let convSide: GridFrame.Side = .left

    /// dock 离边多远 / 工具侧是否预留两列：全屏模式 dock 贴边（0）且工具侧固定留两列给 tab 组盖
    /// （research-ipad-desktop-bugs §2.1 丙右）；浮窗模式 dock 悬在格线上（M）、工具侧一列
    private var dockInset: CGFloat { mode == .docked ? 0 : gridSpec.margin }
    private var reserveToolsSide: Bool { mode == .docked }

    #if os(macOS)
    /// 正文卡的活参数来源。默认是全局那份（= 她在参数台里调的），**测试注入自己的**——
    /// 不注入的话断言就跟她真机上调过的值耦合了（R4b：和 09-16 `migrateForLaneDecouple`
    /// 把标记烧进 `.standard` 是同一个形状的坑）。
    var shellMetrics: MacShellMetrics = .shared
    #endif

    #if os(macOS)
    /// 停靠壳里工具面板算不算「开着」：有 tab，或者 tab 全浮出去了但还留着「拖到这里停靠」那条（`toolPanel()` 的两支）
    var macToolShown: Bool {
        dockShown && (!visibleGroups(.right).isEmpty || detached.contains { !minimized.contains($0) })
    }

    /// mac 停靠壳的几何（plan-mac-fullscreen-shell-v2 §2）：四个槽 + 空地上的格子，一处算。
    /// 列数用提交过的 `macColumns`（滞回在 `commitMacColumns`），`compute` 自己会过可行性。
    /// dock 条恒在（`dockShown` 在停靠壳里只管工具面板，见它的注释）
    func macShellFrame(in size: CGSize, reservingDesktopSpace: Bool = false) -> MacShellFrame {
        MacShellFrame.compute(width: size.width, height: size.height, spec: gridSpec, arrangement: arrangement,
                              dockSide: dockSide, dockShown: true, leftShown: leftColumnVisible, leftWidth: leftWidth,
                              toolShown: macToolShown, toolWidth: toolWidth, cardEdges: shellMetrics.cardEdges,
                              cols: macColumns, bottomShown: bottomColumnVisible, bottomHeight: bottomHeight,
                              reserveDesktopSpace: reservingDesktopSpace || !minimized.isEmpty)
    }

    /// 停靠壳拖列表把手用的钳（跟 `MacShellFrame` 一个口径，不是 `clampedConvWidth`）
    func macClampedConvWidth(_ w: CGFloat, in size: CGSize) -> CGFloat {
        MacShellFrame.convWidth(stored: w, width: size.width, dock: Self.dockWidth,
                                toolShown: macToolShown, cardEdges: shellMetrics.cardEdges)
    }

    /// 停靠壳拖工具面板把手用的钳（280…460，再按窗宽）
    func macClampedToolWidth(_ w: CGFloat, in size: CGSize) -> CGFloat {
        let dock = Self.dockWidth
        let conv = leftColumnVisible ? MacShellFrame.convWidth(stored: leftWidth, width: size.width, dock: dock, toolShown: true,
                                                        cardEdges: shellMetrics.cardEdges) : nil
        return MacShellFrame.toolWidth(stored: w, width: size.width, dock: dock, conv: conv, cardEdges: shellMetrics.cardEdges)
    }
    #endif

    /// 桌面组件该按哪份格子画：mac 停靠壳按空地（`MacShellFrame`），其余按 `grid(in:)`。
    /// 停靠壳里所有「组件落在哪一格」的消费点（desktop 层 / 缩成小组件的落点与容量 / dock 点小组件复原）都走这个
    func desktopGrid(in size: CGSize) -> GridFrame? {
        #if os(macOS)
        if mode == .docked { return macShellFrame(in: size).grid }
        #endif
        return grid(in: size)
    }

    /// 这块可用区里的桌面格线；聊天会窄过下限（Split View）就没有格子。
    /// mac：列数来自 `macColumns`（按窗宽 + 滞回，在 ContentView 一处提交）；还没量过就按这个尺寸无滞回直接算。
    /// **mac 停靠壳不用它画格子**（走 `desktopGrid`）——它在 mac 上只剩浮窗模式 + 老口径的 inset / 钳制在用
    func grid(in size: CGSize) -> GridFrame? {
        guard size.width > 0, size.height > 0 else { return nil }
        #if os(macOS)
        let cols = macColumns ?? MacGridBudget.target(width: size.width, spec: gridSpec, arrangement: arrangement,
                                                       dockInset: dockInset, reserveToolsSide: reserveToolsSide)
        let g = GridFrame.compute(width: size.width, height: size.height, spec: gridSpec,
                                  arrangement: arrangement, dockSide: dockSide,
                                  dockInset: dockInset, reserveToolsSide: reserveToolsSide,
                                  convCols: arrangement == .a ? cols.conv : nil, toolsCols: cols.tools)
        #else
        let g = GridFrame.compute(width: size.width, height: size.height, spec: gridSpec,
                                  arrangement: arrangement, dockSide: dockSide,
                                  dockInset: dockInset, reserveToolsSide: reserveToolsSide)
        #endif
        return g.fits ? g : nil
    }

    /// 按窗宽重算 mac 列数（带滞回），只从 `ContentView.macLayout` 的 onGeometryChange 调；
    /// 排版 / 模式 / 面板开关 / 面板宽 / 卡边改了也要调一次（停靠壳的列数依赖它们，`macShapeKey`）
    func commitMacColumns(width: CGFloat) {
        let next: MacGridBudget.Columns
        #if os(macOS)
        if mode == .docked {
            next = MacShellFrame.columns(width: width, spec: gridSpec, arrangement: arrangement,
                                         dockShown: true, leftShown: leftColumnVisible, leftWidth: leftWidth,
                                         toolShown: macToolShown, toolWidth: toolWidth, cardEdges: shellMetrics.cardEdges,
                                         previous: macColumns)
        } else {
            next = MacGridBudget.columns(width: width, spec: gridSpec, arrangement: arrangement,
                                         dockInset: dockInset, reserveToolsSide: reserveToolsSide, previous: macColumns)
        }
        #else
        next = MacGridBudget.columns(width: width, spec: gridSpec, arrangement: arrangement,
                                     dockInset: dockInset, reserveToolsSide: reserveToolsSide, previous: macColumns)
        #endif
        if next != macColumns { macColumns = next }
    }

    /// 全屏模式 tab 组的宽：正好盖住工具侧的列区 + 到 dock 的缝（有格子按格子的列数；没格子按预留两列），开关 tab 聊天不动
    func dockedToolPanelWidth(in size: CGSize) -> CGFloat {
        if let g = grid(in: size) { return g.toolPanelWidth }
        return 2 * gridSpec.small + 2 * gridSpec.gutter
    }

    /// 没有格子（Split View 窄窗 / mac 最小窗）时退回 v2 的推法：面板占多宽正文让多宽
    private func toolLane(in size: CGSize) -> CGFloat {
        guard mode == .docked, dockShown else { return 0 }
        return Self.dockWidth + (tabs.isEmpty ? 0 : dockedToolPanelWidth(in: size))
    }
    /// 对话侧让位 = 停靠面板此刻**实际**画多宽（存的 leftWidth 按窗口现算钳过，不改档）
    private func convLane(in size: CGSize) -> CGFloat {
        mode == .docked && leftShown ? dockedConvWidth(in: size) : 0
    }

    /// 停靠模式对话面板此刻的宽：存档 leftWidth 按当前可用尺寸钳过（窗口缩到放不下时面板先让，正文守住 minBodyWidth）。
    /// 只钳渲染值不写档——窗口拉回去面板自己回到存的宽（plan-mac-shape §2）
    func dockedConvWidth(in size: CGSize) -> CGFloat {
        clampedConvWidth(leftWidth, availableSize: size)
    }

    /// 正文两侧要让出的宽 = **只看格子道**，面板开关不动它（她：布局跟设置走不跟窗口走）：
    /// 工具侧的 tab 组正好盖在预留的两列上；对话列表盖在另一侧的格子和一截正文上（乙左）。
    /// 没有格子时才退回「面板占多宽让多宽」
    func leftInset(in size: CGSize) -> CGFloat {
        if let g = grid(in: size) { return g.leftLane }
        return convLane(in: size)      // 对话列表恒在左
    }

    func rightInset(in size: CGSize) -> CGFloat {
        if let g = grid(in: size) { return g.rightLane }
        return toolLane(in: size)      // 工具面板恒在右
    }

    // MARK: 全屏模式对话列表宽度钳制（tab 组宽度固定，不拖）

    /// 正文至少留 minBodyWidth（工具侧的让位算进去）；浮窗模式只有面板自身上下限
    func clampedConvWidth(_ w: CGFloat, availableSize: CGSize) -> CGFloat {
        var upper = Self.maxPanelWidth
        if mode == .docked, availableSize.width > 0 {
            upper = min(upper, availableSize.width - rightInset(in: availableSize) - Self.minBodyWidth)
        }
        return max(Self.minPanelWidth, min(upper, w))
    }
}

extension WidgetSize {
    /// 在桌面格子上占几格（只有排版 b 的两列放得下长条 / 大方）
    var cells: Int {
        switch self {
        case .small:  return 1
        case .medium: return 2
        case .large:  return 4
        }
    }
}
