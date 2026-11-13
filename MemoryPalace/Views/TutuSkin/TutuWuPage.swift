#if PERSONAL_APPS
#if os(iOS)
import SwiftUI

@MainActor
@Observable
final class TutuWuPosition {
    static let shared = TutuWuPosition()
    var offset: CGFloat = 0
}

struct TutuWuPage: View {
    @Binding var selectedToolId: String
    @Environment(RightPanelToolManager.self) private var manager: RightPanelToolManager?
    @Environment(\.isPage2Active) private var environmentActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var skin = SkinState.shared
    @State private var home = Page2HomeStore.shared
    @State private var scene = Page2SceneState.shared
    @State private var desktop = Page2DesktopManager.shared
    @AppStorage("page2HomePresentation_v1") private var homePresentation = "free"
    @State private var foreground = UIApplication.shared.applicationState == .active
    @State private var showsKeyCard = false
    @State private var error: String?
    @State private var viewport = CGSize.zero
    private var entries: [RightPanelTool] {
        guard let manager else { return [] }
        if homePresentation != "free" {
            return TutuWuEntrySelection.legacyTools(presentation: homePresentation, desktopIDs: desktop.desktopTools(manager).map(\.id),
                                                   tools: manager.tools)
        }
        let outerMetrics = Page2SystemMetrics(width: viewport.width, height: viewport.height)
        let gridHeight = max(1, viewport.height - outerMetrics.iconSide - (Page2AppearanceStore.shared.displayed.largeIcons ? 12 : 0) - 118)
        let metrics = Page2SystemMetrics(width: viewport.width, height: gridHeight)
        let rows = max(4, min(6, Int((gridHeight + metrics.verticalGap - 20) / metrics.rowPitch)))
        return TutuWuEntrySelection.tools(layout: home.layout, board: home.board(columns: metrics.columns, rows: rows), tools: manager.tools, visible: manager.isVisibleInCurrentMode)
    }
    private var running: Bool {
        skin.active && environmentActive && scene.isActive && foreground && selectedToolId == "home" && !scene.hidesStatusBarForApp
    }
    private func card(_ shown: Bool) {
        withAnimation(reduceMotion ? .linear(duration: 0.15) : (shown ? .easeOut(duration: 0.32) : .easeIn(duration: 0.22))) { showsKeyCard = shown }
    }
    private func open(_ id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        card(false)
        if homePresentation == "free" {
            _ = Page2HomeOpenAction.prepare(id)
            Page2HomeOpenAction.select(id) { selectedToolId = $0 }
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { selectedToolId = id }
        }
    }
    private func updateViewport(_ size: CGSize) {
        viewport = size
        guard homePresentation == "free", let manager, size.width > 0, size.height > 0 else { return }
        home.bootstrap(toolIDs: manager.pinnedTools.map(\.id), dockIDs: Page2HomeStore.bootstrapDock(desktop.dockToolIds ?? Array(manager.pinnedTools.prefix(4).map(\.id))))
        let outer = Page2SystemMetrics(width: size.width, height: size.height)
        let height = max(1, size.height - outer.iconSide - (Page2AppearanceStore.shared.displayed.largeIcons ? 12 : 0) - 118)
        let metrics = Page2SystemMetrics(width: size.width, height: height)
        home.ensureBoard(columns: metrics.columns, rows: max(4, min(6, Int((height + metrics.verticalGap - 20) / metrics.rowPitch))))
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                TutuWuScrollView(running: running, wallpaper: skin.wuWallpaper.rawValue, onKey: { card(true) }, onError: { error = $0 })
                TutuWuControls(selected: skin.wuWallpaper.rawValue,
                               choices: SkinState.WuWallpaper.allCases.map { ($0.rawValue, $0.title) },
                               bottomInset: geometry.safeAreaInsets.bottom) { id in
                    if let paper = SkinState.WuWallpaper(rawValue: id) { skin.wuWallpaper = paper }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.white).padding(.bottom, 100) }
                if showsKeyCard {
                    Color.black.opacity(0.24).ignoresSafeArea().onTapGesture { card(false) }.transition(.opacity)
                    TutuWuKeyCard(tools: entries, onOpen: open, onClose: { card(false) })
                        .padding(.horizontal, 20).padding(.bottom, max(12, geometry.safeAreaInsets.bottom))
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }.background(Color(red: 12/255, green: 10/255, blue: 12/255)).clipped()
            .onAppear { updateViewport(geometry.size) }
            .onChange(of: geometry.size) { _, size in updateViewport(size) }
        }
        .onAppear { foreground = UIApplication.shared.applicationState == .active }
        .onDisappear { foreground = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in foreground = true }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in foreground = false }
        .onChange(of: running) { _, active in if !active { showsKeyCard = false } }
    }
}
#endif
#endif
