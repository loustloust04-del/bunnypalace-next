import SwiftUI

enum CardLibraryTab: Hashable, CaseIterable {
    case characters, worldBook, regex, settings

    var title: String {
        switch self {
        case .characters: "角色"
        case .worldBook: "世界书"
        case .regex: "正则"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .characters: "person.crop.rectangle.stack"
        case .worldBook: "book"
        case .regex: "textformat.abc"
        case .settings: "gearshape"
        }
    }
}

/// 第①步只包旧页；书和正则的独立入口仍由原面板接管。
struct CardLibraryWorkspaceView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    @State private var selection: CardLibraryTab
    @State private var keyboardUp = false
    #if os(iOS)
    @Environment(\.page2AppShellTool) private var shellTool
    #endif

    init(initial: CardLibraryTab = .characters) {
        _selection = State(initialValue: initial)
    }

    var body: some View {
        platformBody
            .background(Theme.sidebarBg.ignoresSafeArea().allowsHitTesting(false))
            .onAppear {
                revealTarget(navigator?.pendingTarget)
                revealWorldBook(navigator?.cardLibraryWorldBookTarget)
            }
            .onChange(of: navigator?.pendingTarget) { _, target in revealTarget(target) }
            .onChange(of: navigator?.cardLibraryWorldBookTarget) { _, target in revealWorldBook(target) }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(iOS)
        TabView(selection: $selection) {
            Tab(CardLibraryTab.characters.title, systemImage: CardLibraryTab.characters.icon, value: CardLibraryTab.characters) {
                page(.characters)
            }
            Tab(CardLibraryTab.worldBook.title, systemImage: CardLibraryTab.worldBook.icon, value: CardLibraryTab.worldBook) {
                page(.worldBook)
            }
            Tab(CardLibraryTab.regex.title, systemImage: CardLibraryTab.regex.icon, value: CardLibraryTab.regex) {
                page(.regex)
            }
            Tab(CardLibraryTab.settings.title, systemImage: CardLibraryTab.settings.icon, value: CardLibraryTab.settings) {
                page(.settings)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // page2 左上角手势区（76pt 见方）盖住返回钮上沿，轻点走 Page2AppBackRegistry：登记成同一个「退一层」。
        // 世界书页签由 WorldBookLibraryView 自己登记（书详情），这里不抢
        .onChange(of: selection == .worldBook ? nil : selection == .characters && navigator?.characterHome != nil, initial: true) { _, canGoBack in
            guard let shellTool, let canGoBack else { return }
            Page2AppBackRegistry.shared.update(shellTool, canGoBack: canGoBack) { navigator?.characterHome = nil }
        }
        .tint(Theme.branchIndicator)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        #else
        page(selection)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                CardLibraryTabBar(selection: $selection)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        #endif
    }

    private func page(_ tab: CardLibraryTab) -> some View {
        Group {
            switch tab {
            case .characters:
                if let home = navigator?.characterHome, home.profileId == profileManager?.currentProfile.id {
                    CharacterHomeView(profileId: home.profileId, cardId: home.cardId)
                        .id(home.profileId + (home.cardId ?? ""))
                } else {
                    CharacterWallView(isActive: selection == .characters)
                }
            case .worldBook: WorldBookLibraryView(isActive: selection == .worldBook)
            case .regex: RegexLibraryView()
            case .settings: CardLibrarySettingsView()
            }
        }
        // 整包导入 / 撤回进行中：卡墙、世界书、正则的写入口一起停（⑧c）
        .disabled(tab != .settings && SillyTavernImportGate.shared.isBusy)
        #if os(iOS)
        .toolbarVisibility(keyboardUp ? .hidden : .automatic, for: .tabBar)
        #endif
    }

    private func revealTarget(_ target: RightPanelNavigator.Target?) {
        guard target?.tool == "cardLibrary" else { return }
        // 设置搜索跳「设置」页签（⑥）
        if target?.id == RightPanelNavigator.cardLibrarySettingsTargetId {
            selection = .settings
            navigator?.pendingTarget = nil
            return
        }
        navigator?.characterHome = nil
        selection = .characters
    }

    /// 世界书页要打开某本书（跨楼层切过来 / 其它入口）：先切到世界书页签，书由 WorldBookLibraryView 自己消费
    private func revealWorldBook(_ target: String?) {
        guard target != nil else { return }
        selection = .worldBook
    }
}

/// 沿用日历的浮动胶囊，不共用日历枚举。
private struct CardLibraryTabBar: View {
    @Binding var selection: CardLibraryTab
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CardLibraryTab.allCases, id: \.self) { tab in
                let on = selection == tab
                Button {
                    if reduceMotion { selection = tab } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = tab }
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon).font(.system(size: 17))
                        Text(tab.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    }
                    .foregroundColor(on ? Theme.branchIndicator : Theme.textPrimary)
                    .frame(maxWidth: 74)
                    .frame(minHeight: 52)
                    .background {
                        if on { Capsule().fill(Theme.textPrimary.opacity(0.07)).matchedGeometryEffect(id: "pill", in: ns) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background {
            if #available(iOS 26, macOS 26, *) {
                Color.clear.glassEffect(.regular, in: .capsule).allowsHitTesting(false)
            } else {
                Capsule().fill(.ultraThinMaterial).allowsHitTesting(false)
            }
        }
        .shadow(color: Theme.textPrimary.opacity(0.1), radius: 12, y: 6)
        .padding(.horizontal, 16)
    }
}
