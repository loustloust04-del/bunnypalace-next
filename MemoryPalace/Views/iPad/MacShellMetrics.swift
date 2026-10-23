import SwiftUI

#if os(macOS)

/// mac **全屏模式**（`IPadPanelLayout.mode == .docked`）外观的活参数。
///
/// 她 09-16：「间距 padding 多少每个组件的精确位置你直接给我一个参数控制面板我自己调整」
/// ＋「真机也弄个参数台」。所以这些数**不是编译期常量**：`@Observable` + `UserDefaults` 落盘，
/// 参数台（`MacShellTuner`）拖一下，正文卡当场变。
///
/// 两条纪律：
/// - **消费点必须在 `body` 里读** `MacShellMetrics.shared.xxx`。在 `init` / `let` 里取快照 = 拖滑杆不重绘。
/// - **测试不许读 `shared`**——那会让断言跟她真机上调过的值耦合（09-16 `migrateForLaneDecouple`
///   把迁移标记烧进 `.standard` 就是这个形状的坑）。要参与计算的量一律**显式传参**，默认值写死。
///
/// 默认使用薄荷工作台密度；已有用户覆盖值保持不变。正文内距由 ChatMetrics 负责，
/// 卡只提供外边距。composerGap / composerInset 仍是用户额外增加的距离。
@Observable
final class MacShellMetrics {
    static let shared = MacShellMetrics()

    /// 一根旋钮。参数台按 `group` 分组、按 `allCases` 顺序排；`exportText()` 也走这张表。
    enum Knob: String, CaseIterable {
        case cardGapX, cardGapTop, cardGapBottom, cardRadius, cardPadX, cardPadY, cardShadow, cardBorder
        case composerInset, composerGap
        case titleBarHeight, titleBarPadY, titleSize, titleIconSize, iconButtonWidth, iconButtonGap
        case dockItem, dockGap
        case contentWidth, contentPadX, contentPadY, messageGap, headerPadX, headerPadY, paneInset
        case panelHairline

        var group: String {
            switch self {
            case .cardGapX, .cardGapTop, .cardGapBottom, .cardRadius,
                 .cardPadX, .cardPadY, .cardShadow, .cardBorder:       return "正文卡"
            case .composerInset, .composerGap:                          return "输入框（在卡里）"
            case .titleBarHeight, .titleBarPadY, .titleSize, .titleIconSize,
                 .iconButtonWidth, .iconButtonGap:                      return "标题栏"
            case .dockItem, .dockGap:                                   return "dock"
            case .contentWidth, .contentPadX, .contentPadY, .messageGap: return "正文阅读区"
            case .headerPadX, .headerPadY, .paneInset: return "面板"
            case .panelHairline:                                        return "其他"
            }
        }

        var label: String {
            switch self {
            case .cardGapX:        return "卡左右外边距"
            case .cardGapTop:      return "卡与标题栏的缝"
            case .cardGapBottom:   return "卡下外边距"
            case .cardRadius:      return "卡圆角"
            case .cardPadX:        return "卡内左右"
            case .cardPadY:        return "卡内上下"
            case .cardShadow:      return "卡阴影"
            case .cardBorder:      return "卡描边"
            case .composerInset:   return "左右再内缩"
            case .composerGap:     return "与正文再加间距"
            case .titleBarHeight:  return "栏高"
            case .titleBarPadY:    return "按钮四周留白"
            case .titleIconSize:   return "图标字号"
            case .titleSize:       return "标题字号"
            case .iconButtonWidth: return "图标钮宽"
            case .iconButtonGap:   return "图标钮间距"
            case .dockItem:        return "图标格"
            case .dockGap:         return "图标间距"
            case .contentWidth: return "正文最大宽度"
            case .contentPadX: return "正文左右内距"
            case .contentPadY: return "正文上下内距"
            case .messageGap: return "Code 消息间距"
            case .headerPadX: return "Code 栏左右内距"
            case .headerPadY: return "Code 栏上下内距"
            case .paneInset: return "侧面板外边距"
            case .panelHairline:   return "面板描边"
            }
        }

        var def: Double {
            switch self {
            case .cardGapX:        return 4
            case .cardGapTop:      return 0      // 与两侧工作面板对齐
            case .cardGapBottom:   return 10
            case .cardRadius:      return 12
            case .cardPadX:        return 0
            case .cardPadY:        return 0
            case .cardShadow:      return 0
            case .cardBorder:      return 0.5
            case .composerInset:   return 0      // 现状：输入条与正文同宽
            case .composerGap:     return 0      // 现状之上再加，0 = 不动
            case .titleBarHeight:  return 26     // = Tahoe 红绿灯那一带的高（探针 [PROBE shell.titlebar] 量到 32.0）
            case .titleBarPadY:    return 4
            case .titleIconSize:   return 11.5
            case .titleSize:       return 12
            case .iconButtonWidth: return 26
            case .iconButtonGap:   return 2
            case .dockItem:        return 36     // 指针目标；仍可在参数台调整
            case .dockGap:         return 2      // 现状 VStack spacing
            case .contentWidth: return 720
            case .contentPadX: return 28
            case .contentPadY: return 20
            case .messageGap: return 16
            case .headerPadX: return 28
            case .headerPadY: return 12
            case .paneInset: return 4
            case .panelHairline:   return 0.5    // 工具栏分界
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .cardGapX, .cardGapTop, .cardGapBottom:   return 0...48
            case .cardRadius:                              return 0...28
            case .cardPadX, .cardPadY:                     return 0...48
            case .cardShadow:                              return 0...24
            case .cardBorder:                              return 0...1.5
            case .composerInset:                           return 0...220
            case .composerGap:                             return 0...60
            case .titleBarHeight:                          return 26...64
            case .titleBarPadY:                            return 2...12
            case .titleIconSize:                           return 9...16
            case .titleSize:                               return 10...18
            case .iconButtonWidth:                         return 20...40
            case .iconButtonGap:                           return 0...12
            case .dockItem:                                return 24...48
            case .dockGap:                                 return 0...16
            case .contentWidth: return 480...1440
            case .contentPadX, .contentPadY, .headerPadX, .headerPadY: return 0...64
            case .messageGap: return 0...48
            case .paneInset: return 0...20
            case .panelHairline:                           return 0...1
            }
        }

        var step: Double {
            switch self {
            case .cardBorder, .panelHairline: return 0.5
            case .titleSize, .titleIconSize:  return 0.5
            case .composerInset:              return 2
            default:                          return 1
            }
        }
    }

    private static let prefix = "mac.shell."
    private let defaults: UserDefaults
    @ObservationIgnored private let alignedTitlebarHeight: () -> CGFloat
    var followsTrafficLights: Bool {
        didSet { defaults.set(followsTrafficLights, forKey: "mac.shell.followsTrafficLights") }
    }
    private var values: [Knob: Double]

    /// 留白可视化：泳道上色 + 桌布留白打斜纹。只在参数台开着时有意义，不落盘。
    var showGuides = false

    init(defaults: UserDefaults = .standard,
         alignedTitlebarHeight: @escaping () -> CGFloat = { MacWindowChrome.shared.alignedTitlebarHeight }) {
        self.defaults = defaults
        self.alignedTitlebarHeight = alignedTitlebarHeight
        self.followsTrafficLights = defaults.object(forKey: "mac.shell.followsTrafficLights") as? Bool ?? true
        var v: [Knob: Double] = [:]
        for k in Knob.allCases {
            let stored = defaults.object(forKey: Self.prefix + k.rawValue) as? Double ?? k.def
            v[k] = stored.isFinite ? min(k.range.upperBound, max(k.range.lowerBound, stored)) : k.def
        }
        values = v
    }

    subscript(knob: Knob) -> CGFloat {
        get { CGFloat(values[knob] ?? knob.def) }
        set {
            guard newValue.isFinite else { return }
            if knob == .titleBarHeight { followsTrafficLights = false }
            let bounded = min(knob.range.upperBound, max(knob.range.lowerBound, Double(newValue)))
            values[knob] = bounded
            defaults.set(bounded, forKey: Self.prefix + knob.rawValue)
        }
    }

    func binding(_ knob: Knob) -> Binding<Double> {
        Binding(get: { Double(self[knob]) }, set: { self[knob] = CGFloat($0) })
    }

    func reset() {
        followsTrafficLights = true
        for k in Knob.allCases {
            defaults.removeObject(forKey: Self.prefix + k.rawValue)
            values[k] = k.def
        }
    }

    /// 和 HTML 小样（`docs/design-mac-fullscreen-otty.html`）同一个格式，她一键复制发我
    func exportText() -> String {
        var out = "// 记忆花园 · mac 外观控制台\n"
        out += "// 标题栏对齐系统红绿灯：\(followsTrafficLights ? "开" : "关")；实际栏高 \(titleBarHeight) pt\n"
        var lastGroup = ""
        for k in Knob.allCases {
            if k.group != lastGroup {
                out += "\n// \(k.group)\n"
                lastGroup = k.group
            }
            let v = self[k]
            let num = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", Double(v))
            out += k.label.padding(toLength: max(14, k.label.count), withPad: " ", startingAt: 0) + " = " + num + "\n"
        }
        return out
    }

    var chatMetrics: ChatMetrics {
        var value = ChatMetrics.mac
        value.listInsetH = self[.contentPadX]
        value.listInsetV = self[.contentPadY]
        value.composerInsetH = self[.contentPadX]
        return value
    }

    // MARK: 具名读口（消费点用这些，读起来像常量）

    var cardGapX: CGFloat { self[.cardGapX] }
    var cardGapTop: CGFloat { self[.cardGapTop] }
    var cardGapBottom: CGFloat { self[.cardGapBottom] }
    var cardRadius: CGFloat { self[.cardRadius] }
    var cardPadX: CGFloat { self[.cardPadX] }
    var cardPadY: CGFloat { self[.cardPadY] }
    var cardShadow: CGFloat { self[.cardShadow] }
    var cardBorder: CGFloat { self[.cardBorder] }
    var composerInset: CGFloat { self[.composerInset] }
    var composerGap: CGFloat { self[.composerGap] }
    /// The button must fit as a square without bleeding into the window edge.
    var titleBarHeight: CGFloat { followsTrafficLights ? alignedTitlebarHeight() : self[.titleBarHeight] }
    var titleButtonSide: CGFloat { max(10, min(iconButtonWidth, titleBarHeight - 2 * self[.titleBarPadY])) }
    var titleControlInset: CGFloat { (titleBarHeight - titleButtonSide) / 2 }
    var titleIconSize: CGFloat { min(self[.titleIconSize], titleButtonSide - 6) }
    var titleBarPadX: CGFloat { titleControlInset }
    var titleSize: CGFloat { self[.titleSize] }
    var iconButtonWidth: CGFloat { self[.iconButtonWidth] }
    var iconButtonGap: CGFloat { self[.iconButtonGap] }
    var dockItem: CGFloat { self[.dockItem] }
    var dockGap: CGFloat { self[.dockGap] }
    var panelHairline: CGFloat { self[.panelHairline] }

    /// 正文卡两侧的边（外边距 + 内边距，两侧合计）。`MacShellFrame` 用它算卡的下限（320 + 边）
    /// 和舒适宽（720 + 边）——720 的夹宽发生在**卡内 padding 之内**（`CardFlowView:557` / `:1285`）。
    ///
    /// ⚠️ 测试不许读 `shared` 的这个属性，显式传 `defaultCardEdges`。
    var cardEdges: CGFloat { 2 * (cardGapX + cardPadX) }

    /// 测试与纯函数用的默认值（= 默认参数下的 `cardEdges`）
    static let defaultCardEdges: CGFloat = 2 * (CGFloat(Knob.cardGapX.def) + CGFloat(Knob.cardPadX.def))
}

/// 窗口自己的 chrome 量出来的数（不是设计参数，她调不了，也不该调）。
@Observable
final class MacWindowChrome {
    static let shared = MacWindowChrome()

    /// 红绿灯右缘到窗口左边的距离 + 一点缝。标题栏那一行左边要让开这么多。
    /// **量出来不写死**（R-FS I5）：交通灯的尺寸/间距是系统的，写死的数在系统改版时会静默错位。
    /// 量不到（还没上屏）就先用 78，上屏后 `WindowConfigurator` 会覆盖。
    var trafficLightInset: CGFloat = 78
    /// Twice the actual distance from the window top to the traffic-light center.
    /// Keep the last normal-window measurement when full screen hides the buttons.
    var alignedTitlebarHeight: CGFloat = 32
    /// 系统标题栏那一带有多高（`fullSizeContentView` 下 = 顶部安全区）。plan-v2 R1：标题行高得 ≥ 它才盖得住红绿灯那一带。
    /// 只量不用（DEBUG 打一行），她的 Tahoe 上 09-17 实拍推算 ≈32.5
    var titlebarHeight: CGFloat = 0
    #if DEBUG
    private var didProbeLights = false
    #endif

    func measure(_ window: NSWindow) {
        if let content = window.contentView {
            let h = content.frame.height - window.contentLayoutRect.height
            if h > 0, abs(h - titlebarHeight) > 0.5 {
                DispatchQueue.main.async { self.titlebarHeight = h }
                #if DEBUG
                ShellProbe.p("[PROBE shell.titlebar] height=\(h) titleBarKnob=\(MacShellMetrics.shared.titleBarHeight)")
                #endif
            }
        }
        guard let zoom = window.standardWindowButton(.zoomButton) else { return }
        let maxX = zoom.convert(zoom.bounds, to: nil).maxX
        guard maxX > 0 else { return }
        let next = maxX + 10
        let centerFromTop = window.frame.height - zoom.convert(zoom.bounds, to: nil).midY
        let alignedHeight = (2 * centerFromTop * 2).rounded() / 2
        if !window.styleMask.contains(.fullScreen), !zoom.isHidden,
           (24...64).contains(alignedHeight), abs(alignedHeight - alignedTitlebarHeight) > 0.25 {
            DispatchQueue.main.async { self.alignedTitlebarHeight = alignedHeight }
        }
        #if DEBUG
        if !didProbeLights {
            ShellProbe.keep("[PROBE shell.title-alignment] centerFromTop=\(centerFromTop) rowHeight=\(alignedHeight)")
        }
        #endif

        #if DEBUG
        // 09-17 列表钮挪到红绿灯右边后点不到（合成点击 x=91/100 都没反应）：看那一带到底是谁在接。
        // 只在上屏一秒后打一次（updateNSView 每次布局都进来；太早 SwiftUI 还没铺好）
        if !didProbeLights {
            didProbeLights = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak window, weak zoom] in
                guard let window, let zoom, let frame = window.contentView?.superview else { return }
                let probeY = frame.bounds.height - 16
                let hits = [80, 91, 100, 120, 160].map { x -> String in
                    let v = frame.hitTest(NSPoint(x: CGFloat(x), y: probeY))
                    return "\(x):\(v.map { String(describing: type(of: $0)) } ?? "nil")"
                }
                let sup = zoom.superview.map { "\(type(of: $0)) \($0.frame)" } ?? "nil"
                ShellProbe.keep("[PROBE shell.lights] zoomMaxX=\(maxX) super=\(sup) hit=\(hits.joined(separator: " "))")
            }
        }
        #endif
        // 只在真变了的时候写：`updateNSView` 每次布局都会调进来，无条件写会在 view update 里改状态
        if abs(next - trafficLightInset) > 0.5 {
            DispatchQueue.main.async { self.trafficLightInset = next }
        }
    }
}

#endif
