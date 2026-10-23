#if os(iOS)
import SwiftUI
import UIKit

/// page2 打开过的应用（plan-page2-app-shell §2.1–2.3）。page2 挂在分页的子 HC 里拿不到 SceneStorage，
/// 所以状态放在这里，由 ContentView 恢复和写盘。
@MainActor
@Observable
final class Page2AppShell {
    static let shared = Page2AppShell()
    var stack = Page2AppStack()
    var showsSwitcher = false
    /// 后台卡片用的截图，只放内存；按 1x 抓，四张加起来几 MB
    var snapshots: [String: UIImage] = [:]
    /// 读书开着的书，存成「楼层 id/书名」（plan §2.9）；书架在子 HC 里拿不到 SceneStorage，由这里转写
    var readingBook = ""
    var motion: Page2AppMotion?
    var cardFrames: [String: CGRect] = [:]
    var switcherOrder: [String] = []
    var desktopSnapshot: UIImage?
    /// 手指按在左上角手势区里。弧线平时不画，只在这时露出来（⧫ 粟粟 09-25：拖的时候才显示）
    var cornerTouching = false
    /// 右边竖条拉开程度 0…1（#085，拖动时可略超 1）
    @ObservationIgnored let stripMotion = Page2StripMotion()
    var stripProgress: CGFloat {
        get { stripMotion.progress }
        set { stripMotion.drag(to: newValue) }
    }
    /// 竖条里应用的顺序（用户拖过的；不在里面的新开应用按最近用的接在后面）。存本机，重启不丢
    private(set) var stripOrder: [String] = (UserDefaults.standard.string(forKey: Page2AppShell.stripOrderKey) ?? "")
        .split(separator: ",").map(String.init)
    @ObservationIgnored private static let stripOrderKey = "page2StripOrder_v1"
    func setStripOrder(_ order: [String]) {
        stripOrder = order
        UserDefaults.standard.set(order.joined(separator: ","), forKey: Self.stripOrderKey)
    }
    var stripApps: [String] {
        let open = stack.openApps
        return stripOrder.filter(open.contains) + open.filter { !stripOrder.contains($0) }
    }
    @ObservationIgnored var contentViews: [String: WeakContentView] = [:]
    @ObservationIgnored var launchFrames: [String: CGRect] = [:]
    /// perf-flash C3b：外壳在窗口里的位置用时现量（UIKit 探针），尺寸变化仍由 SwiftUI 盯
    @ObservationIgnored let sceneProbe = WindowFrameProbe()
    @ObservationIgnored var sceneSize: CGSize = .zero
    var sceneFrame: CGRect { sceneProbe.windowFrame ?? CGRect(origin: .zero, size: sceneSize) }
    @ObservationIgnored private var lockOwner = UUID()
    @ObservationIgnored private var desktopCaptureToken = UUID()
    @ObservationIgnored private weak var lockedScroll: UIScrollView?

    var switcherApps: [String] {
        let order = switcherOrder.isEmpty ? stack.openApps : switcherOrder
        return order.filter { stack.openApps.contains($0) }
    }

    func trace(_ message: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["PAGE2_ARC_TRACE"] == "1" else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("page2-arc.trace")
        let line = "\(Date().timeIntervalSince1970) pid=\(ProcessInfo.processInfo.processIdentifier) \(message) motion=\(motion != nil) switcher=\(showsSwitcher) scroll=\(PagingViewController.sharedScrollView?.isScrollEnabled ?? false)\n"
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
        }
        #endif
    }

    func lockPaging() {
        guard lockedScroll == nil, let scroll = PagingViewController.sharedScrollView else { return }
        if PagingViewController.setPage2DragLocked(true, owner: lockOwner, scrollView: scroll) { lockedScroll = scroll }
    }
    func unlockPaging() {
        if let scroll = lockedScroll { _ = PagingViewController.setPage2DragLocked(false, owner: lockOwner, scrollView: scroll) }
        lockedScroll = nil
        trace("unlock")
    }
    /// `id == "home"`：桌面上拉弧线进后台（⧫ 粟粟 10-11），没有回桌面那段
    func beginMotion(_ id: String, fromSwitcher: Bool) {
        guard motion == nil, id != "home" || !stack.openApps.isEmpty else { return }
        lockPaging()
        trace("begin \(id)")
        if !fromSwitcher {
            captureSnapshot(of: id)
            switcherOrder = stack.openApps
            // 后台重新挂载：旧的单卡尺寸、顺序或滚动位置不能作为这次落点。
            cardFrames = [:]
        }
        motion = Page2AppMotion(appID: id, fromSwitcher: fromSwitcher, cardProgress: fromSwitcher ? 1 : 0)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    func settle(card: CGFloat, home: CGFloat = 0, completion: @escaping () -> Void) {
        guard let token = motion?.token else { unlockPaging(); return }
        motion?.settling = true
        trace("settle \(card) home=\(home)")
        withAnimation(UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.88), completionCriteria: .removed) {
            motion?.cardProgress = card
            motion?.homeProgress = home
        } completion: {
            self.trace("completion")
            guard self.motion?.token == token else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                completion()
                self.motion = nil
                self.unlockPaging()
            }
        }
    }
    func beginStripDrag() -> CGFloat { stripMotion.beginDrag() }

    /// 竖条开 / 收；收尾期间保留真实进度，重抓可直接接续。
    func setStrip(open: Bool, animated: Bool = true, velocity: CGFloat = 0) {
        let active = Page2SceneState.shared.stripSceneActive
        stripMotion.setOpen(open && active, animated: animated && active, velocity: velocity)
    }
    func cancelMotion() {
        trace("cancel")
        motion = nil
        unlockPaging()
    }

    private(set) var restored = false

    func open(_ id: String) {
        let previous = stack.openApps
        if let evicted = stack.open(id) { snapshots[evicted] = nil }
        if previous != stack.openApps, motion == nil, !showsSwitcher { cardFrames = [:] }
    }

    func close(_ id: String) {
        stack.close(id)
        snapshots[id] = nil
        cardFrames = [:]
        switcherOrder.removeAll { $0 == id }
    }

    /// 回返回路径上的上一个应用；它要是已经被挤出后台，重开时可能再挤掉一个，顺手清掉没人用的截图
    func back() -> String? {
        let previous = stack.back()
        snapshots = snapshots.filter { stack.openApps.contains($0.key) }
        return previous
    }

    func captureSnapshot(of id: String, deferPublication: Bool = false) {
        guard let view = contentViews[id]?.view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        #if DEBUG || PERF_BENCH
        Page2StripProbe.hit("snapshot:\(id)")
        #endif
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        if id == "home" {
            let token = UUID(); desktopCaptureToken = token
            if deferPublication {
                DispatchQueue.main.async {
                    guard self.desktopCaptureToken == token else { return }
                    self.desktopSnapshot = image
                }
            } else { desktopSnapshot = image }
        } else { snapshots[id] = image }
    }

    /// 只认第一次：外壳和 ContentView 谁先起都行，当前应用总会补回栈顶
    func restore(_ encoded: String, readingBook: String, current: String) {
        guard !restored else { return }
        restored = true
        self.readingBook = readingBook
        stack = Page2AppStack(encoded: encoded)
        if current != "home" { stack.open(current) }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.event("page2Restored", fields: ["tool": current, "openApps": stack.openApps])
        #endif
    }
}

/// 挂在 ContentView 上：把 SceneStorage 里的后台恢复进 Page2AppShell，后台变了再写回去。
/// 订阅放在这个 modifier 里，后台变动不会让 ContentView.body 整棵重算。
struct Page2AppShellPersistence: ViewModifier {
    @Binding var encoded: String
    @Binding var readingBook: String
    let current: String
    @State private var shell = Page2AppShell.shared

    func body(content: Content) -> some View {
        content
            .onAppear { shell.restore(encoded, readingBook: readingBook, current: current) }
            .onChange(of: shell.stack) { _, stack in encoded = stack.encoded }
            .onChange(of: shell.readingBook) { _, book in readingBook = book }
    }
}

/// 活应用身份稳定；过渡只改变外层几何，不在卡片与全屏之间搬动内容树。
struct Page2AppShellView: View {
    @Binding var selectedToolId: String
    var viewModel: ConversationViewModel
    var stickerVM: StickerViewModel
    @State private var shell = Page2AppShell.shared
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.launchPageSignal) private var launchSignal
    @AppStorage(Page2Switcher.key) private var switcher = "strip"
    private var stripMode: Bool { switcher != "arc" }

    private var liveIDs: [String] {
        var ids = shell.stack.openApps
        if selectedToolId != "home", !ids.contains(selectedToolId) { ids.append(selectedToolId) }
        return ids.sorted()
    }
    private var availableIDs: Set<String> { Set(tools?.pinnedTools.map(\.id) ?? []) }

    var body: some View {
        #if DEBUG || PERF_BENCH
        let _ = Page2StripProbe.hit("shellBody")
        let _ = AirPerfProbe.enabled ? AirPerfProbe.shared.notePage2(selectedToolId) : ()
        #endif
        GeometryReader { geo in
            ZStack {
                Page2StripBackdrop(motion: shell.stripMotion)
                // 竖条垫在页面底下：拉的过程中页面在上、退开多少露多少，图标不压到页面上（⧫ 粟粟 10-11「不要穿模」）
                if stripMode {
                    Page2StripView(selectedToolId: $selectedToolId)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                ZStack {
                    Page2AppContentHost(id: "home", interactive: selectedToolId == "home" && !shell.showsSwitcher && shell.motion == nil,
                                        visible: selectedToolId == "home" && !shell.showsSwitcher || shell.motion != nil) {
                        RightPanelToolContent(toolId: "home", selectedToolId: $selectedToolId, viewModel: viewModel, stickerVM: stickerVM)
                    }
                    .overlay {
                        // 桌面也常驻弧线（有后台应用才画，桌面拉弧线进后台）
                        Page2CornerBar(radius: Page2DisplayCorner.radius)
                            .opacity(!stripMode && selectedToolId == "home" && !shell.stack.openApps.isEmpty
                                     ? (shell.cornerTouching ? 1 : 0.5) * (1 - min((shell.motion?.cardProgress ?? 0) / 0.85, 1)) : 0)
                            .animation(.easeOut(duration: 0.18), value: shell.cornerTouching)
                    }
                    .opacity(selectedToolId == "home" && !shell.showsSwitcher || shell.motion != nil ? 1 : 0)
                    .allowsHitTesting(selectedToolId == "home" && !shell.showsSwitcher && shell.motion == nil)
                    .accessibilityHidden(selectedToolId != "home" || shell.showsSwitcher || shell.motion != nil)

                    if shell.showsSwitcher || shell.motion != nil {
                        Page2AppSwitcherView(selectedToolId: $selectedToolId, viewport: geo.size)
                            .opacity(switcherOpacity)
                            .allowsHitTesting(shell.showsSwitcher && shell.motion == nil)
                            .accessibilityHidden(!shell.showsSwitcher || shell.motion != nil)
                    }

                    ForEach(liveIDs, id: \.self) { id in
                        Page2AppContentHost(id: id, interactive: id == selectedToolId && !shell.showsSwitcher && shell.motion == nil,
                                            visible: shell.motion?.appID == id || id == selectedToolId && !shell.showsSwitcher) {
                            // 日历的「楼层日记」入口挪进了每日页（plan-calendar §七），外壳不再单独挂按钮
                            RightPanelToolContent(toolId: id, selectedToolId: $selectedToolId, viewModel: viewModel, stickerVM: stickerVM)
                            .environment(\.page2AppShellTool, id)
                            .environment(\.page2AppActive, id == selectedToolId && !shell.showsSwitcher && Page2SceneState.shared.isActive)
                        }
                        .modifier(Page2AppSurface(id: id, selected: selectedToolId, size: geo.size))
                    }
                }
                .modifier(Page2StripPresentation())
                Page2CornerGesture(selectedToolId: $selectedToolId)
            }
            .coordinateSpace(name: "page2-app-scene")
            .background(WindowFrameProbeView(probe: shell.sceneProbe))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if shell.sceneSize != size {
                    shell.cancelMotion(); shell.setStrip(open: false, animated: false)
                    shell.cardFrames = [:]; shell.launchFrames = [:]
                }
                shell.sceneSize = size
            }
        }
        // 子应用 hosting controller 自己处理键盘安全区；外壳几何不随键盘压缩。
        .ignoresSafeArea()
        .environment(\.launchPage2Target, selectedToolId)
        #if DEBUG || PERF_BENCH
        .task { await Page2StripProbe.run { selectedToolId = $0 } }
        #endif
        .onChange(of: selectedToolId, initial: true) { old, id in
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if LaunchTrace.enabled { LaunchTrace.page2Target = id }
            #endif
            if old == "home", id != "home", shell.desktopSnapshot == nil { shell.captureSnapshot(of: "home") }
            if id != "home" { shell.open(id) }
            if let motion = shell.motion, motion.appID != id { shell.cancelMotion() }
            if let signal = launchSignal {
                let epoch = signal.epoch
                if old != id { signal.state.expectContent(2) }
                signal.state.page2Condition = { [weak shell, weak state = signal.state] in
                    guard let shell, shell.restored, let state, state.valid, state.epoch == epoch,
                          let content = shell.contentViews[id]?.view, let owner = state.owner?.viewIfLoaded,
                          content.isDescendant(of: owner), content.window != nil,
                          content.bounds.width > 0, content.bounds.height > 0 else { return false }
                    return !content.isHidden && content.isUserInteractionEnabled
                }
                signal.state.check()
            }
        }
        .onChange(of: selectedToolId != "home" || shell.showsSwitcher, initial: true) { _, active in
            Page2SceneState.shared.hidesStatusBarForApp = active
            PagingViewController.refreshStatusBar()
        }
        .onChange(of: availableIDs) { _, ids in
            guard !ids.isEmpty else { return }
            shell.stack.retain { ids.contains($0) }
            if selectedToolId != "home", !ids.contains(selectedToolId) { shell.cancelMotion(); selectedToolId = "home" }
        }
        .onChange(of: Page2SceneState.shared.isActive) { _, active in if !active { shell.cancelMotion() } }
        // 竖条手势只在第二页、竖条模式下开（翻页1mac 审）；离开第二页（tab / 音乐胶囊 / 楼层重建翻走）就地收掉、解锁翻页
        .onChange(of: stripMode && Page2SceneState.shared.isActive && scenePhase == .active, initial: true) { _, enabled in
            Page2StripPan.shared.install(enabled: enabled)
            if !enabled { shell.setStrip(open: false, animated: false) }
        }
        .onChange(of: selectedToolId == "ccTerminal" && !shell.showsSwitcher && stripMode, initial: true) { _, shows in
            // 竖条模式下终端照 #055 D2 显示系统状态栏；弧线模式要藏（状态栏吃掉弧线那块的触摸，#082）
            Page2SceneState.shared.appShowsStatusBar = shows
            PagingViewController.refreshStatusBar()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            Page2SceneState.shared.stripSceneActive = phase == .active
            if phase != .active { shell.cancelMotion(); shell.setStrip(open: false, animated: false) }
        }
        .onDisappear { shell.cancelMotion(); shell.setStrip(open: false, animated: false) }
    }

    private var switcherOpacity: CGFloat {
        guard let motion = shell.motion else { return shell.showsSwitcher ? 1 : 0 }
        return min(motion.cardProgress / 0.6, 1) * (1 - motion.homeProgress)
    }
}

private struct Page2AppSurface: ViewModifier {
    let id: String
    let selected: String
    let size: CGSize
    @State private var shell = Page2AppShell.shared
    @AppStorage(Page2Switcher.key) private var switcher = "strip"

    func body(content: Content) -> some View {
        let moving = shell.motion?.appID == id
        let progress = moving ? shell.motion?.cardProgress ?? 0 : (shell.showsSwitcher ? 1 : 0)
        let home = moving ? shell.motion?.homeProgress ?? 0 : 0
        let card = shell.cardFrames[id] ?? Page2AppSwitcherView.slot(for: id, apps: shell.switcherApps, size: size)
        let icon = shell.launchFrames[id].map { $0.offsetBy(dx: -shell.sceneFrame.minX, dy: -shell.sceneFrame.minY) }
        let geometry = Page2AppGeometry(size: size, card: card, icon: icon, cardProgress: progress, homeProgress: home)
        let visible = moving || (id == selected && !shell.showsSwitcher)
        content
            .frame(width: size.width, height: size.height)
            .frame(height: geometry.cropHeight, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: geometry.clipRadius / geometry.scale, style: .continuous))
            // 拉成卡片时补上后台卡片同款阴影（形状阴影，不离屏渲染内容），落定换截图时阴影不再突然出现
            .background {
                if moving {
                    RoundedRectangle(cornerRadius: geometry.clipRadius / geometry.scale, style: .continuous)
                        .fill(Theme.mainBg)
                        .shadow(color: .black.opacity(0.14 * min(max((progress - 0.6) / 0.4, 0), 1) * (1 - home)),
                                radius: 14 / geometry.scale, y: 8 / geometry.scale)
                }
            }
            .overlay {
                // 全屏应用里常驻（⧫ 粟粟 10-11「把弧线持久化放在那里」），平时半透明，按住全亮
                Page2CornerBar(radius: geometry.radius / geometry.scale, light: id == "ccTerminal")
                    .opacity(switcher == "arc" && id == selected ? geometry.arcOpacity * (shell.cornerTouching ? 1 : 0.5) : 0)
                    .animation(.easeOut(duration: 0.18), value: shell.cornerTouching)
            }
            .scaleEffect(geometry.scale)
            .position(geometry.position)
            .opacity(visible ? 1 - home : 0)
            .allowsHitTesting(visible && shell.motion == nil)
            .accessibilityHidden(!visible || shell.motion != nil)
    }
}

/// 本地目标子树确有尺寸，并且 SceneStorage 恢复完成后才报内容到达；不承诺网络/全部 lazy 行。
struct LaunchPage2ContentReady: ViewModifier {
    let id: String
    @Environment(\.launchPageSignal) private var signal
    @Environment(\.launchPage2Target) private var target
    @State private var size: CGSize = .zero
    @State private var shell = Page2AppShell.shared
    @ViewBuilder func body(content: Content) -> some View {
        if signal?.state.enabled == true {
            content
                .onGeometryChange(for: CGSize.self) { $0.size } action: { value in
                    size = value
                    report()
                }
                .onChange(of: shell.restored) { _, _ in report() }
                .onChange(of: target) { _, _ in report() }
                .onAppear { report() }
        } else { content }
    }
    private func report() {
        guard id == target, shell.restored, size.width > 0, size.height > 0 else { return }
        signal?.note("contentReady")
        // classic/stitch home 使用 SwiftUI 自带 Button/ScrollView；free 桌面的 UIKit driver 另报接线。
        let presentation = UserDefaults.standard.string(forKey: "page2HomePresentation_v1") ?? "free"
        if id == "home", presentation != "free" { signal?.note("gestureReady") }
    }
}

extension EnvironmentValues {
    @Entry var launchPage2Target: String = "home"
    @Entry var page2AppShellTool: String? = nil
    /// 这个应用正在前台显示（不在后台卡片里、page2 是当前页）。后台应用的 hosting 只被藏起来、不会 onDisappear，
    /// 要按可见性开关传感器 / 动画的（书房的陀螺仪）读这个。外壳外默认 true。
    @Entry var page2AppActive: Bool = true
}
#endif
