#if os(iOS)
import SwiftUI
import UIKit

/// 第二页切 app 的方式（#085）：右边竖条（默认）/ 左上弧线（#082，备选）
enum Page2Switcher {
    static let key = "page2Switcher"
    static var usesStrip: Bool { UserDefaults.standard.string(forKey: key) != "arc" }
}

/// 右边竖条（⧫ 粟粟 10-11「放在 page3，但是只拉出来一长条 app 图案供切换」，小样 fixtures/page2-strip-prototype）。
/// 不加第三页：第二页往左划由 `Page2StripPan` 接管，退开的内屏裁固定设备圆角并整体左移、缩一点、轻微模糊；收回满屏时撤掉内层裁切，外层黑底始终铺满窗口。
enum Page2StripMetrics {
    static let width: CGFloat = 92
    static let appScale: CGFloat = 0.97
    /// 保留轻微失焦，不让系统材质吞掉内容；透明度单独限幅，收起时连续淡出。
    static let blur: CGFloat = 0.02
    static let blurOpacity: CGFloat = 0.25
    static let icon: CGFloat = 54
    static let background = Color(red: 0.16, green: 0.15, blue: 0.14)
}

/// 竖条本体：最上 ⌂ 桌面，下面后台应用（用户排的顺序，新开的接在后面），当前那个描白边。
/// 跟桌面图标一样：长按进抖动编辑，角上 − 关掉这个应用，拖动排顺序（⧫ 粟粟 10-11）
struct Page2StripView: View {
    @Binding var selectedToolId: String
    @State private var shell = Page2AppShell.shared
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    @State private var editing = false
    @State private var dragID: String?
    @State private var dragStart = 0
    @State private var dragY: CGFloat = 0
    @GestureState private var reorderTouching = false
    /// 一格的高：图标 + 名字 + 间距
    private let slot: CGFloat = Page2StripMetrics.icon + 17 + 16

    var body: some View {
        let apps = shell.stripApps
        // 应用多了上下滚；少的时候竖着居中（拖动排序时不滚，免得和拖动抢）
        GeometryReader { geo in
        ScrollView(.vertical) {
        VStack(spacing: 16) {
            item(id: "home", label: "桌面", index: -1) {
                // 和桌面图标同款玻璃方块
                Image(systemName: "house.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.94))
                    .frame(width: Page2StripMetrics.icon, height: Page2StripMetrics.icon)
                    .glassEffect(.regular, in: .rect(cornerRadius: Page2StripMetrics.icon * 0.26))
            }
            Capsule().fill(Color.white.opacity(0.18)).frame(width: 28, height: 2)
            ForEach(Array(apps.enumerated()), id: \.element) { index, id in
                if let tool = tools?.tool(byId: id) {
                    // 直接用桌面图标（Page2AppIcon），跟着桌面外观 / 自定义图标走
                    item(id: id, label: tool.name, index: index) {
                        Page2AppIcon(tool: tool, side: Page2StripMetrics.icon, label: false, followsIconSize: false,
                                     interactive: false, decorative: true)
                    }
                }
            }
        }
        .frame(width: Page2StripMetrics.width)
        .padding(.vertical, 24)
        .frame(minHeight: geo.size.height)
        .contentShape(Rectangle())
        // 编辑中点竖条空白处 = 退出编辑
        .onTapGesture { if editing { editing = false } }
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(dragID != nil)
        }
        .frame(width: Page2StripMetrics.width)
        .environment(\.isPage2Active, Page2SceneState.shared.isActive)
        .modifier(Page2StripIconReveal())
        .onChange(of: Page2SceneState.shared.stripOpen) { _, open in
            if !open { editing = false; dragID = nil; dragY = 0 }
        }
        .onChange(of: Page2SceneState.shared.stripTransitioning) { _, moving in
            if moving { editing = false; dragID = nil; dragY = 0 }
        }
        .onChange(of: reorderTouching) { _, touching in
            if !touching { dragID = nil; dragY = 0 }
        }
        .onChange(of: editing) { _, editing in
            if !editing { dragID = nil; dragY = 0 }
        }
    }

    private func item<Icon: View>(id: String, label: String, index: Int, @ViewBuilder icon: () -> Icon) -> some View {
        let selected = selectedToolId == id
        let app = index >= 0
        let dragging = dragID == id
        return VStack(spacing: 5) {
            icon()
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.white.opacity(selected && !editing ? 0.9 : 0), lineWidth: 2).padding(-3))
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
        }
        .modifier(Page2EditingMotion(enabled: editing && app && !dragging, seed: index + 1, pivotHeight: Page2StripMetrics.icon))
        // − 标单独一层放在最上面（放进图标的玻璃容器里会和图标玻璃融在一起、像被压住），同一个种子一起抖
        .overlay(alignment: .topLeading) {
            if app {
                Page2RemoveBadge(label: "关闭\(label)", editing: editing && !dragging) { close(id) }
                    .offset(x: Page2RemoveBadge.originOffset + 6, y: Page2RemoveBadge.originOffset + 6)
                    .modifier(Page2EditingMotion(enabled: editing && !dragging, seed: index + 1, pivotHeight: Page2StripMetrics.icon))
            }
        }
        .scaleEffect(dragging ? 1.12 : 1)
        // 拖着的那个只跟手指；别的只靠位移让位，松手才真换顺序（换顺序 + 清位移同一帧、不补动画，不跳）
        .offset(y: dragging ? dragY : shift(index))
        .animation(dragging ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: shift(index))
        .zIndex(dragging ? 2 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !editing else { return }
            #if DEBUG || PERF_BENCH
            Page2StripProbe.begin("select:\(id)")
            Page2StripProbe.finishAfterSettle()
            #endif
            if !selected { selectedToolId = id }
            shell.setStrip(open: false)
        }
        .gesture(app ? reorder(id) : nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(editing && app ? "\(label)，编辑中" : (id == "home" ? "回桌面" : "切到\(label)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            if editing {
                Button("退出编辑") { editing = false }
            } else if app {
                Button("编辑应用") { editing = true }
            }
            if app {
                Button("关闭\(label)") { close(id) }
                if editing {
                    Button("上移") { move(id, by: -1) }
                    Button("下移") { move(id, by: 1) }
                }
            }
            Button("收起应用切换栏") { shell.setStrip(open: false) }
        }
    }

    /// 拖着的那个当前落在第几格
    private var dragTarget: Int {
        min(max(dragStart + Int((dragY / slot).rounded()), 0), max(shell.stripApps.count - 1, 0))
    }

    /// 其它图标给拖着的那个让位：它从 dragStart 挪到 dragTarget，中间那几个各挪一格
    private func shift(_ index: Int) -> CGFloat {
        guard dragID != nil, index >= 0 else { return 0 }
        let target = dragTarget
        if dragStart < target, index > dragStart, index <= target { return -slot }
        if dragStart > target, index >= target, index < dragStart { return slot }
        return 0
    }

    /// 长按进编辑（编辑中直接拖），拖着上下换位置，松手落定
    private func reorder(_ id: String) -> some Gesture {
        LongPressGesture(minimumDuration: editing ? 0.05 : 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($reorderTouching) { value, touching, _ in
                if case .second(true, _) = value { touching = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !editing {
                    editing = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                guard let drag else { return }
                if dragID == nil, let start = shell.stripApps.firstIndex(of: id) { dragID = id; dragStart = start }
                let before = dragTarget
                dragY = drag.translation.height
                if dragTarget != before { UISelectionFeedbackGenerator().selectionChanged() }
            }
            .onEnded { _ in
                guard let id = dragID else { return }
                var order = shell.stripApps
                let target = dragTarget
                order.removeAll { $0 == id }
                order.insert(id, at: target)
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    shell.setStripOrder(order)
                    dragID = nil; dragY = 0
                }
            }
    }

    private func move(_ id: String, by offset: Int) {
        var order = shell.stripApps
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { shell.setStripOrder(order) }
    }

    private func close(_ id: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            shell.close(id)
            if selectedToolId == id { selectedToolId = shell.stripApps.first ?? "home" }
            if shell.stack.openApps.isEmpty { editing = false; shell.setStrip(open: false) }
        }
    }
}

/// 竖条拖动识别器：挂在翻页 pan 所在的视图上（舞台模式是 stageView，启动定死），翻页 pan `require(toFail:)` 它
///（`iOSTabBarGestureBlocker` 同款）。只在第二页、竖条模式下 enabled（翻页1mac 审：0↔1 不多等一次判定）。
@MainActor
final class Page2StripPan: NSObject, UIGestureRecognizerDelegate {
    static let shared = Page2StripPan()
    private let pan = UIPanGestureRecognizer()
    private let owner = UUID()
    private var startProgress: CGFloat = 0
    private var startDrag: CGFloat = 0
    private var dragging = false
    private weak var lockedScroll: UIScrollView?
    private let tick = UIImpactFeedbackGenerator(style: .light)

    override private init() {
        super.init()
        pan.delegate = self
        pan.addTarget(self, action: #selector(handle(_:)))
        pan.isEnabled = false
    }

    /// 外壳每次更新调一次：挂上（幂等）+ 按页面 / 模式开关
    func install(enabled: Bool) {
        if let scroll = PagingViewController.sharedScrollView, let host = scroll.panGestureRecognizer.view, pan.view !== host {
            host.addGestureRecognizer(pan)
            scroll.panGestureRecognizer.require(toFail: pan)
        }
        // 关掉会取消进行中的拖动（离开第二页 / 换成弧线模式）
        if pan.isEnabled != enabled { pan.isEnabled = enabled }
    }

    var isEnabled: Bool { pan.isEnabled }

    /// 竖条开着期间锁住翻页（往右划 = 收竖条，不翻页）
    func setPagingLocked(_ lock: Bool) {
        if !lock {
            if let scroll = lockedScroll { _ = PagingViewController.setPage2DragLocked(false, owner: owner, scrollView: scroll) }
            lockedScroll = nil
            return
        }
        guard let scroll = PagingViewController.sharedScrollView, lockedScroll !== scroll else { return }
        if let previous = lockedScroll { _ = PagingViewController.setPage2DragLocked(false, owner: owner, scrollView: previous) }
        lockedScroll = nil
        if PagingViewController.setPage2DragLocked(true, owner: owner, scrollView: scroll) { lockedScroll = scroll }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let shell = Page2AppShell.shared
        guard shell.motion == nil, !shell.showsSwitcher, !shell.stack.openApps.isEmpty else { return false }
        let v = pan.velocity(in: pan.view)
        guard abs(v.x) > abs(v.y) * 1.2 else { return false }
        return shell.stripProgress > 0.01 || v.x < 0
    }

    /// 应用里自己认横划的先来，它们不要了才轮到竖条（⧫ 粟粟 10-11 选「里面先来」）：
    /// - 滚动视图：还能往左滚的才让（终端 tab 条、桌面翻页）；竖着滚的、滚到头的不让，不然竖滚的应用里永远拉不出竖条
    /// - 其它拖动类手势（列表左划删除、终端窗口面板左划、SwiftUI 拖动）：一律先让
    /// - 点按 / 长按不等（手指一动它们自己就失败了）
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        guard Page2AppShell.shared.stripProgress < 0.01, other !== pan,
              let paging = PagingViewController.sharedScrollView, other !== paging.panGestureRecognizer,
              let view = other.view, view.window != nil else { return false }
        if let scroll = view as? UIScrollView, other === scroll.panGestureRecognizer {
            guard scroll.contentSize.width > scroll.bounds.width + 1 else { return false }
            let maxX = scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right
            return scroll.contentOffset.x < maxX - 1
        }
        if other is UITapGestureRecognizer || other is UILongPressGestureRecognizer { return false }
        return true
    }

    @objc private func handle(_ pan: UIPanGestureRecognizer) {
        let shell = Page2AppShell.shared
        guard pan.isEnabled, Page2SceneState.shared.isActive, Page2SceneState.shared.stripSceneActive, Page2Switcher.usesStrip else {
            dragging = false
            shell.setStrip(open: false, animated: false)
            return
        }
        let width = Page2StripMetrics.width
        switch pan.state {
        case .began:
            #if DEBUG || PERF_BENCH
            Page2StripProbe.begin("drag")
            #endif
            startProgress = shell.beginStripDrag()
            startDrag = startProgress > 1 ? 1 + (startProgress - 1) / 0.25 : startProgress
            dragging = true
            setPagingLocked(true)
            tick.prepare()
            // 拉竖条先收键盘（不然终端的键盘会一路跟到切过去的应用上）
            if startProgress < 0.01 { pan.view?.window?.endEditing(true) }
        case .changed:
            guard dragging else { return }
            let raw = startDrag - pan.translation(in: pan.view).x / width
            // 拉过头有阻尼，收不过 0
            let p = raw > 1 ? 1 + (raw - 1) * 0.25 : max(raw, 0)
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { shell.stripProgress = p }
        case .ended:
            guard dragging else { return }
            dragging = false
            let raw = startDrag - pan.translation(in: pan.view).x / width
            let projected = raw - pan.velocity(in: pan.view).x * 0.12 / width
            let open = projected > 0.5
            if open, startProgress < 0.5 { tick.impactOccurred(intensity: 0.6) }
            let speed = -pan.velocity(in: pan.view).x / width * (raw > 1 ? 0.25 : 1)
            shell.setStrip(open: open, velocity: speed)
            #if DEBUG || PERF_BENCH
            Page2StripProbe.finishAfterSettle()
            #endif
        case .cancelled, .failed:
            guard dragging else { return }
            dragging = false
            shell.setStrip(open: false, animated: false)
            #if DEBUG || PERF_BENCH
            Page2StripProbe.finish()
            #endif
        default: break
        }
    }
}
#endif
