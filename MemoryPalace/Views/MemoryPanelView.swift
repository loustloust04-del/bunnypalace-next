import SwiftUI
import SwiftData

// MARK: - Right Panel (Tool-based Container)

#if os(iOS)
/// iPhone 页 2 / iPad 窄屏的右栏（全屏应用外壳 + 工具正文，plan-page2-app-shell）。mac 自 plan-mac-shape A1b 起走 iPad 宽屏壳
/// （`IPadPanelOverlay` + `TabbedToolPanel`），不再用它。
struct RightPanelView: View {
    @Binding var selectedToolId: String
    var viewModel: ConversationViewModel
    var stickerVM: StickerViewModel

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    #if os(iOS)
    /// Page 2 桌面样式：classic = 经典 widget 桌面 / stitch = 针脚点阵新桌面（两套并存，设置切换）
    @AppStorage("page2DesktopStyle") private var page2DesktopStyle = "classic"
    @AppStorage("page2HomePresentation_v1") private var homePresentation = "free"
    #endif

    private var stitchHomeActive: Bool {
        #if os(iOS)
        return selectedToolId == "home" && homePresentation == "stitch"
        #else
        return false
        #endif
    }

    var body: some View {
        platformBody
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(stitchHomeActive ? Page2PaletteCanvasColor : Theme.sidebarBg)
    }

    /// 针脚点阵桌面底色（macOS 分支不引用 Page2Palette，给个跨端安全取值）
    private var Page2PaletteCanvasColor: Color {
        #if os(iOS)
        return Page2Palette.canvas
        #else
        return Theme.sidebarBg
        #endif
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(iOS)
        Page2AppShellView(selectedToolId: $selectedToolId, viewModel: viewModel, stickerVM: stickerVM)
        #endif
    }
}
#endif

/// 一个工具 id → 它的面板内容。从 `RightPanelView.panelContent` 抽出来：iPad 宽屏一张卡渲染一个工具，
/// 得能脱离「dock + 单选」那个壳复用。mac / iPhone 的 `RightPanelView` 行为不变。
struct RightPanelToolContent: View {
    let toolId: String
    /// 只有 `home`（针脚桌面）用它导航；卡片里传 `.constant`
    @Binding var selectedToolId: String
    var viewModel: ConversationViewModel
    var stickerVM: StickerViewModel

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    #if os(iOS)
    @AppStorage("page2DesktopStyle") private var page2DesktopStyle = "classic"
    @AppStorage("page2HomePresentation_v1") private var homePresentation = "free"
    /// `selectedToolId` 的源头是 ContentView 的 `@SceneStorage`——那个 binding 在翻页期间每帧把 `Page2HomeView`
    /// 整棵打脏（真机 `_printChanges`：两次翻页 158 次「_selectedToolId changed」，上游各层只有 6 次；
    /// docs/research-page2-ios-hangs.md §3）。这里用 @State 镜像双向同步，往下传 @State 支持的 binding。
    @State private var homeTool: String = "home"
    #endif

    var body: some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let _ = AirPerfProbe.enabled ? AirPerfProbe.shared.noteToolBody(toolId) : ()
        #endif
        switch toolId {
        case "home":
            #if os(iOS)
            if homePresentation == "free" {
                Page2HomeView(selectedToolId: $homeTool)
                    .onAppear { homeTool = selectedToolId }
                    .onChange(of: selectedToolId) { _, v in if homeTool != v { homeTool = v } }
                    .onChange(of: homeTool) { _, v in if selectedToolId != v { selectedToolId = v } }
            } else if homePresentation == "stitch" {
                Page2DesktopView(selectedToolId: $selectedToolId)
            } else {
                DashboardView()
            }
            #else
            DashboardView()
            #endif
        case "calendar":
            CalendarPanelView(viewModel: viewModel, profileId: profileManager?.currentProfile.id ?? "")
        case "memory":
            MemoryPanelView(viewModel: viewModel)
        case "worldBook":
            WorldBookPanelView()
        case "cardLibrary":
            CardLibraryWorkspaceView(initial: .characters)
        case "sticker":
            StickerLibraryView(viewModel: viewModel, stickerVM: stickerVM)
        case "prompt":
            PersonaSettingsTab(useSheetNavigation: true, viewModel: viewModel)
        case "ccTerminal":
            CCTerminalPanelView(viewModel: viewModel)
        case "fileLibrary":
            FileLibraryPanelView()
        case "browser":
            BrowserView()
        case "vocab":
            VocabPanelView(viewModel: viewModel)
        case "reading":
            ReadingPanelView()
        case "health":
            HealthPanelView(profileId: profileManager?.currentProfile.id ?? "")
        case "regex":
            RegexPage()
        case "twitter":
            TwitterPanelView(profileId: profileManager?.currentProfile.id ?? "")
        case "study":
            StudyPanelView(viewModel: viewModel)
        #if os(macOS)
        case "run":
            RunPanelView()
        case "terminal":
            LocalTerminalPanelView()
        #endif
        #if os(iOS)
        case "cssChat":
            Page2ChatWebView(viewModel: viewModel)
        #endif
        case "xiaoya":
            AssistantPanelView()
        default:
            Text("未知工具")
                .foregroundColor(Theme.textMuted)
        }
    }
}


// MARK: - Memory Panel（page2 主体）
//
// 首屏：画像卡 + 两组记忆；整理 / 关系图 / 下一轮会想起什么进「⋯」，设置在「设置」页签。
// 多选删除 / 钉住：EditMode + List(selection:) + bottom toolbar；两组记忆一个行样式（MemoryRow），删掉的进「已删除」。
// 四格「记忆 / 窗口总结 / 时间轴 / 设置」在底部（同日历 iOS 版）：iOS 系统 TabView，mac 浮动胶囊 `PanelFloatingTabBar`。

enum MemoryPanelTab: PanelFloatingTab {
    case memory, sessions, timeline, settings

    var title: String {
        switch self {
        case .memory: "记忆"
        case .sessions: "窗口总结"
        case .timeline: "时间轴"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .memory: "leaf"
        case .sessions: "rectangle.stack"
        case .timeline: "calendar.day.timeline.left"
        case .settings: "gearshape"
        }
    }
}

struct MemoryPanelView: View {
    var viewModel: ConversationViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    @Environment(\.settingsMetrics) private var m

    @State private var memories: [Memory] = []
    @State private var selfMemories: [SelfMemory] = []
    @State private var editingSelfMemory: SelfMemory? = nil
    @State private var tab: MemoryPanelTab = .memory
    @State private var showGraph = false
    @State private var timelineModel = MemoryTimelineModel()
    @State private var sessionsModel = MemorySessionsModel()
    @State private var highlightedId: String? = nil
    @State private var selection: Set<MemoryRowID> = []
    @State private var showAddSheet = false
    @State private var showTrash = false
    @State private var editingMemory: Memory? = nil   // 刀2：单条编辑
    @State private var aboutDream: UserProfileDream? = nil
    @State private var loaded = false
    @State private var healthWarning: String? = nil
    @State private var showProfile = false
    @State private var showOrganize = false
    @State private var showInjectionPreview = false
    @State private var searchText = ""
    @State private var pendingScrollId: String? = nil
    /// 时间轴格「⋯」里的暂停 / 继续；和时间轴顶上的开关、设置格「跨窗口时间轴」同一个 key
    @AppStorage("mem_content_timeline") private var timelineOn = true
    #if os(macOS)
    @State private var macSelecting = false
    #endif
    #if os(iOS)
    @FocusState private var searchFocused: Bool
    @State private var pageWidth: CGFloat = 0
    /// 键盘起来时藏系统底栏（同日历：不藏的话底栏骑在键盘上）
    @State private var keyboardUp = false
    // SwiftUI 推荐：EditButton（这里换成同法的 MemorySelectButton）自动管理 environment.editMode，view 只读不写——
    // 自己 @State + .environment(\.editMode, $editMode) 反而会抢 binding，
    // 导致 List(selection:) 收不到 active 状态，选择圈不出来。
    @Environment(\.editMode) private var editMode
    #endif

    private let store = SwiftDataMemoryStore()

    var body: some View {
        ScrollViewReader { proxy in
            tabContainer(proxy)
                .tint(Theme.branchIndicator)
                .sheet(isPresented: $showAddSheet) {
                    AddMemorySheet(profileId: profileManager?.currentProfile.id ?? "") {
                        refreshMemories()
                    }
                }
                .sheet(item: $editingMemory) { mem in
                    AddMemorySheet(profileId: profileManager?.currentProfile.id ?? "", editing: mem,
                                   onJumpToSource: mem.sourceConversationId != nil ? { jumpToSource(mem) } : nil) {
                        refreshMemories()
                    }
                }
                .sheet(isPresented: $showTrash, onDismiss: refreshMemories) {
                    MemoryTrashSheet(profileId: profileManager?.currentProfile.id ?? "")
                }
                .sheet(isPresented: $showInjectionPreview) {
                    InjectionPreviewSheet(profileId: profileManager?.currentProfile.id ?? "",
                                          conversationMemoryEnabled: viewModel.selectedConversation?.memoryEnabled ?? true)
                }
                .sheet(item: $editingSelfMemory) { m in
                    SelfMemoryEditSheet(profileId: profileManager?.currentProfile.id ?? "", slug: m.slug)
                }
                .sheet(isPresented: $showProfile) {
                    MemoryProfileSheet(profileId: profileManager?.currentProfile.id ?? "")
                }
                .sheet(isPresented: $showOrganize) {
                    MemoryOrganizeSheet(profileId: profileManager?.currentProfile.id ?? "")
                }
                #if os(iOS)
                .fullScreenCover(isPresented: $showGraph) {
                    MemoryGraphSheet(memories: memories.filter { $0.supersededAt == nil })
                }
                #else
                .sheet(isPresented: $showGraph) {
                    MemoryGraphSheet(memories: memories.filter { $0.supersededAt == nil })
                }
                #endif
                .onAppear { refreshMemories(); consumeDesktopMemory(proxy) }
                .onAppear { AssistantContext.shared.report(page: "memory") }
                .onDisappear { AssistantContext.shared.clear(page: "memory") }
                .onChange(of: navigator?.pendingTarget) { _, _ in consumeDesktopMemory(proxy) }
                .onChange(of: loaded) { _, isLoaded in if isLoaded { consumeDesktopMemory(proxy) } }
                .onChange(of: searchText) { _, _ in
                    if !selection.isEmpty { selection.formIntersection(visibleRowIds) }
                    consumePendingScroll(proxy)
                }
                .onChange(of: tab) { _, _ in
                    resetSelection()
                    #if os(iOS)
                    searchFocused = false
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
                    memories = []
                    selfMemories = []
                    aboutDream = nil
                    loaded = false
                    healthWarning = nil
                    selection = []
                    showProfile = false
                    showOrganize = false
                    showTrash = false
                    searchText = ""
                    timelineModel.clear()
                    sessionsModel.clear()
                    #if os(iOS)
                    editMode?.wrappedValue = .inactive
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in
                    refreshMemories()
                    if tab == .timeline, let pid = profileManager?.currentProfile.id {
                        timelineModel.reload(profileId: pid, container: modelContext.container)
                    } else {
                        timelineModel.markStale()
                    }
                    if tab == .sessions, let pid = profileManager?.currentProfile.id {
                        sessionsModel.reload(profileId: pid, container: modelContext.container)
                    } else {
                        sessionsModel.markStale()
                    }
                }
        }
    }

    #if os(iOS)
    /// 系统页签（iOS 26 液态玻璃底栏，滚动不收起），同日历 iOS 版；每格自己一个 NavigationStack，导航栏只放这一格的按钮。
    /// 时间轴 / 设置两张 insetGrouped List 的顶边距压成 4（`contentMargins`），第一张卡和记忆格的搜索框同一个起点
    private func tabContainer(_ proxy: ScrollViewProxy) -> some View {
        TabView(selection: $tab) {
            Tab(MemoryPanelTab.memory.title, systemImage: MemoryPanelTab.memory.icon, value: MemoryPanelTab.memory) {
                tabPage {
                    memoryList(proxy)
                        .toolbar { memoryToolbar }
                }
            }
            Tab(MemoryPanelTab.sessions.title, systemImage: MemoryPanelTab.sessions.icon, value: MemoryPanelTab.sessions) {
                tabPage {
                    MemorySessionsView(model: sessionsModel, viewModel: viewModel)
                        .contentMargins(.top, 4, for: .scrollContent)
                        .toolbar {
                            ToolbarItemGroup(placement: .primaryAction) { moreMenu }
                        }
                }
            }
            Tab(MemoryPanelTab.timeline.title, systemImage: MemoryPanelTab.timeline.icon, value: MemoryPanelTab.timeline) {
                tabPage {
                    MemoryTimelineView(model: timelineModel, viewModel: viewModel)
                        .contentMargins(.top, 4, for: .scrollContent)
                        .toolbar {
                            ToolbarItemGroup(placement: .primaryAction) { moreMenu }
                        }
                }
            }
            // 设置格也挂「⋯」：没有按钮时导航栏是空的，正文会顶到灵动岛底下，三格起点对不齐
            Tab(MemoryPanelTab.settings.title, systemImage: MemoryPanelTab.settings.icon, value: MemoryPanelTab.settings) {
                tabPage {
                    settingsList
                        .contentMargins(.top, 4, for: .scrollContent)
                        .toolbar {
                            ToolbarItemGroup(placement: .primaryAction) { moreMenu }
                        }
                }
            }
        }
        // 不设 tabBarMinimizeBehavior：粟粟要底栏滚动时不缩，只在键盘起来 / 多选时藏
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
    }

    /// 标题栏一律 inline：不设标题时根页默认大标题模式，导航栏底下空着一整条大标题位（返工 2 搜索框上那段空白）。
    /// 三格同一个标题「记忆」（学日历），切格时顶栏不变。多选时藏底栏，给批量操作的 bottomBar 让位
    private func tabPage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationTitle("记忆")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarVisibility(keyboardUp || editMode?.wrappedValue.isEditing == true ? .hidden : .automatic, for: .tabBar)
        }
    }
    #else
    /// macOS：NavigationStack toolbar 会被提升进窗口统一标题栏
    ///（principal 相对中栏+右栏居中骑缝、primaryAction 甩到窗口角），改面板内头部行；三格是底部浮动胶囊（同日历 mac）
    private func tabContainer(_ proxy: ScrollViewProxy) -> some View {
        NavigationStack {
            ZStack {
                switch tab {
                case .memory:
                    memoryList(proxy)
                case .sessions:
                    MemorySessionsView(model: sessionsModel, viewModel: viewModel)
                case .timeline:
                    MemoryTimelineView(model: timelineModel, viewModel: viewModel)
                case .settings:
                    settingsList
                }
            }
            // 切格只换正文，不带布局动画
            .animation(nil, value: tab)
            .safeAreaInset(edge: .top, spacing: 0) { macPanelHeader }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PanelFloatingTabBar(selection: $tab)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
    }
    #endif

    private func memoryList(_ proxy: ScrollViewProxy) -> some View {
        Group {
            if !loaded {
                // 首帧：自记 / 画像还在后台读，整页先空着（只有搜索框），读齐了一次出来，不逐块插进来
                Color.clear
            } else if pageIsEmpty {
                emptyPage
            } else {
                List(selection: $selection) {
                    if searchText.panelSearchKeyword == nil {
                        profileCard
                    }

                    listSections
                }
                .panelListStyle()
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: MemoryRowID.self) { ids in
                    rowActions(ids)
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first { edit(id) }
                }
            }
        }
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        #if os(iOS)
        // 搜索框常驻钉在列表顶（同 mac 的 PanelSearchField）。不用 .searchable：它只挂在「记忆」格，切格时导航栏高度跟着变
        .safeAreaInset(edge: .top, spacing: 0) {
            PanelSearchField(prompt: "搜索记忆", text: $searchText, focus: $searchFocused)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .toolPageBackground()
        }
        .scrollDismissesKeyboard(.immediately)
        #endif
        .onAppear { consumePendingScroll(proxy) }
    }

    /// 画像、两组记忆都空：整页一个原生空状态（搜索时不算）
    private var pageIsEmpty: Bool {
        loaded && searchText.panelSearchKeyword == nil && (aboutDream?.text.isEmpty ?? true)
            && !memories.contains { $0.supersededAt == nil } && !selfMemories.contains(where: \.isActive)
    }

    private var emptyPage: some View {
        MemoryEmptyState(title: "还没有记忆",
                         message: "和{{char}}聊天时会自动记下重要的事".expandingMacros(profile: profileManager?.currentProfile)) {
            Button("加一条") { showAddSheet = true }
                .buttonStyle(MemoryPrimaryButtonStyle())
            if deletedCount > 0 {
                Button("已删除 · \(deletedCount)") { showTrash = true }
                    .buttonStyle(MemoryPrimaryButtonStyle())
            }
        }
    }

    /// 「设置」分段：就是原来「更多设置」推进去的那页；运行状态放这里（首屏只在出问题时提醒一行）
    private var settingsList: some View {
        List {
            Section {
                MemoryHealthStatusView(profileId: profileManager?.currentProfile.id ?? "")
            }
            .panelRowBackground()
            MemoryPageContent()
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .toolPageBackground()
    }

    private func consumeDesktopMemory(_ proxy: ScrollViewProxy) {
        guard let target = navigator?.pendingTarget, target.tool == "memory" else { return }
        // 首次读齐前列表还没上台：目标先留着，`loaded` 变 true 时再来
        guard loaded else { return }
        navigator?.pendingTarget = nil
        guard memories.contains(where: { $0.id.uuidString == target.id && $0.supersededAt == nil }) else { return }
        flash(target.id)
        if searchText.isEmpty && tab == .memory {
            DispatchQueue.main.async { withAnimation { proxy.scrollTo(target.id, anchor: .center) } }
        } else {
            // 目标可能被搜索词滤掉 / 列表不在台上：先清词、切回「记忆」，等列表重建完（onChange(searchText) 或列表 onAppear）再滚
            pendingScrollId = target.id
            searchText = ""
            #if os(iOS)
            searchFocused = false
            #endif
            tab = .memory
        }
    }

    /// 跳过来的那条：薄荷底亮一下，1.5 秒后淡出
    private func flash(_ id: String) {
        withAnimation(.easeInOut(duration: 0.35)) { highlightedId = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard highlightedId == id else { return }
            withAnimation(.easeOut(duration: 0.6)) { highlightedId = nil }
        }
    }

    private func consumePendingScroll(_ proxy: ScrollViewProxy) {
        guard tab == .memory, searchText.isEmpty, let id = pendingScrollId else { return }
        pendingScrollId = nil
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .center) } }
    }

    // MARK: - 画像卡：3 行 + 看全文，点卡打开画像弹层；出问题时卡底一行提醒

    @ViewBuilder
    private var profileCard: some View {
        Section {
            Button {
                showProfile = true
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("{{char}}眼里的你".expandingMacros(profile: profileManager?.currentProfile))
                        .font(m.body.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    if let d = aboutDream, !d.text.isEmpty {
                        Text(d.text)
                            .font(m.body)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(3)
                        HStack {
                            Text("\(MemoryDateText.short(d.updatedAt))更新")
                                .foregroundColor(Theme.textMuted)
                            Spacer()
                            Text("看全文 ›")
                                .foregroundColor(Theme.textSecondary)
                        }
                        .font(m.caption)
                    } else if loaded {
                        Text("还没有画像。聊几天后{{char}}会自己写一份".expandingMacros(profile: profileManager?.currentProfile))
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let warning = healthWarning {
                Button {
                    tab = .settings
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.danger).frame(width: 6, height: 6)
                        Text("\(warning)，去看看模型设置 ›")
                        Spacer(minLength: 0)
                    }
                    .font(m.caption)
                    .foregroundColor(Theme.danger)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .panelRowBackground()
    }

    // MARK: - 两组记忆（只列活着的；删掉的在最底「已删除 · N ›」）

    @ViewBuilder
    private var listSections: some View {
        let active = activeMemories
        let selfRows = selfPanelRows
        if !selfRows.isEmpty {
            Section {
                ForEach(selfRows) { m in
                    selfMemoryRow(m)
                }
            } header: {
                groupHeader("\(selfMemoryName) · \(selfRows.count)",
                            "\(assistantName)觉得重要、自己决定记下的；跟\(assistantName)说「记住…」也会记在这")
            }
        }
        if !active.isEmpty {
            Section {
                ForEach(active, id: \.id) { mem in
                    memoryRow(mem)
                }
            } header: {
                groupHeader("从聊天里记住的 · \(active.count)", "聊天时自动记下的关于你的事")
            }
        }
        if searchText.panelSearchKeyword != nil && active.isEmpty && selfRows.isEmpty {
            Section {
                PanelNoMatchView()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        trashRow
    }

    /// 组头 + 一行说明；计数 = 这组正在显示的条数（搜索时是命中数）
    private func groupHeader(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(note)
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .textCase(nil)
        #if os(macOS)
        .font(.system(size: 11))
        .foregroundStyle(ShellStyle.secondaryText)
        #endif
    }

    private var deletedCount: Int {
        memories.filter { $0.supersededAt != nil }.count + selfMemories.filter { !$0.isActive }.count
    }

    @ViewBuilder
    private var trashRow: some View {
        let n = deletedCount
        if searchText.panelSearchKeyword == nil && n > 0 {
            Section {
                Button {
                    showTrash = true
                } label: {
                    HStack {
                        Text("已删除 · \(n)")
                            .font(m.body)
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .panelRowBackground()
        }
    }

    // MARK: - 小克的记忆（memory/self/，和文件库同一份数据、同一个编辑页）

    private var assistantName: String {
        let n = profileManager?.currentProfile.assistantName ?? ""
        return n.isEmpty ? "助手" : n
    }

    private var selfMemoryName: String { "\(assistantName)自己记下的" }

    private var selfPanelRows: [SelfMemory] {
        SelfMemoryStore.panelRows(selfMemories, keyword: searchText.panelSearchKeyword).filter(\.isActive)
    }

    private func selfMemoryRow(_ m: SelfMemory) -> some View {
        let item = MemoryRowItem(m)
        return MemoryRow(item: item) { rowActions([item.id]) }
            .tag(item.id)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { moveToTrash([item.id]) } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .panelRowBackground(rowBackground(item.id))
    }

    /// 行底：mac 选中行用浅薄荷（`Theme.accent` 是浅背景色，不是强调色）标出；iOS 选中由 EditMode 的选择圈标，行底不变
    private func rowBackground(_ id: MemoryRowID) -> Color {
        #if os(macOS)
        selection.contains(id) ? Theme.accent : Theme.mainBg
        #else
        Theme.mainBg
        #endif
    }

    /// 跳过来的高亮和选中底合成一个 listRowBackground（两个叠着时外层那个会盖掉里层）
    private func memoryRow(_ mem: Memory) -> some View {
        let item = MemoryRowItem(mem)
        let idStr = mem.id.uuidString
        return MemoryRow(item: item) { rowActions([item.id]) }
            .id(idStr)
            .tag(item.id)
            .swipeActions(edge: .leading) {
                Button { pin([mem]) } label: {
                    Label(mem.isUserExplicit ? "取消钉住" : "钉住", systemImage: mem.isUserExplicit ? "pin.slash" : "pin")
                }
                .tint(Theme.branchIndicator)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { moveToTrash([item.id]) } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .panelRowBackground(highlightedId == idStr ? Theme.branchIndicator.opacity(0.35) : rowBackground(item.id))
    }

    /// 长按 / 右键 / mac 行尾「⋯」同一份：编辑 / 钉住 / 去原对话（有出处才有）/ 删除
    @ViewBuilder
    private func rowActions(_ ids: Set<MemoryRowID>) -> some View {
        let archive = liveArchive(ids)
        if ids.count == 1, let id = ids.first {
            Button { edit(id) } label: { Label("编辑", systemImage: "pencil") }
        }
        if !archive.isEmpty {
            let unpin = MemoryPinPlan.unpins(archive)
            Button { pin(archive) } label: {
                Label(unpin ? "取消钉住" : "钉住", systemImage: unpin ? "pin.slash" : "pin")
            }
        }
        if ids.count == 1, let m = archive.first, m.sourceConversationId != nil {
            Button { jumpToSource(m) } label: { Label("去原对话", systemImage: "arrow.right.circle") }
        }
        if !ids.isEmpty {
            Button(role: .destructive) { moveToTrash(ids) } label: {
                Label(ids.count > 1 ? "删除 \(ids.count) 条" : "删除", systemImage: "trash")
            }
        }
    }

    // MARK: - Toolbar

    /// iPad 卡窄时「＋」放不下，收进「⋯」第一项
    private var foldAdd: Bool {
        #if os(iOS)
        pageWidth > 0 && pageWidth < 360
        #else
        false
        #endif
    }

    private var moreMenu: some View {
        Menu {
            if tab == .memory {
                if foldAdd {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("加一条记忆", systemImage: "plus")
                    }
                }
                Button {
                    startSelecting()
                } label: {
                    Label("选择", systemImage: "checkmark.circle")
                }
            }
            if tab == .timeline {
                Button {
                    timelineOn.toggle()
                } label: {
                    Label(timelineOn ? "暂停时间轴" : "继续记时间轴", systemImage: timelineOn ? "pause.circle" : "play.circle")
                }
            }
            Button {
                showGraph = true
            } label: {
                Label("关系图", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Divider()
            Button {
                showOrganize = true
            } label: {
                Label("整理记忆…", systemImage: "sparkles")
            }
            Button {
                showInjectionPreview = true
            } label: {
                Label("下一轮会想起什么", systemImage: "eye")
            }
        } label: {
            toolbarIcon("ellipsis")
        }
        .accessibilityLabel("更多")
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
    }

    private func startSelecting() {
        tab = .memory
        #if os(iOS)
        withAnimation { editMode?.wrappedValue = .active }
        #else
        macSelecting = true
        #endif
    }

    private var addMemoryButton: some View {
        Button {
            showAddSheet = true
        } label: {
            toolbarIcon("plus")
        }
        .accessibilityLabel("加一条记忆")
    }

    /// 顶栏图标同页 1 聊天页右上 ⋯：灰色细图标、不套圈、不用绿（粟粟 10-11）。
    /// iOS 在系统 toolbar 里：不加 frame / padding，点按区和圆玻璃交给系统（加了会把圆撑成扁椭圆）；mac 没有系统玻璃，自己给 44pt
    @ViewBuilder
    private func toolbarIcon(_ name: String) -> some View {
        let icon = Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(Theme.textSecondary)
        #if os(macOS)
        icon
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        #else
        icon
        #endif
    }

    #if os(macOS)
    /// 头部只剩这一格的按钮：记忆「＋ ⋯」+ 搜索框，其余三格「⋯」（四格都有，粟粟 10-11）
    private var macPanelHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                if tab == .memory {
                    addMemoryButton
                        .buttonStyle(.plain)
                }
                moreMenu
            }
            .padding(.horizontal, 2)
            if tab == .memory {
                PanelSearchField(prompt: "搜索记忆", text: $searchText)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                if macSelecting || !selection.isEmpty {
                    macSelectionBar
                }
            }
        }
        .toolPageBackground()
    }

    /// 多选批量条（面 3.2，B1）：mac 用 List 原生 ⌘ / ⇧ 连选，选中即出，不走 EditMode；动作与 iOS 底 bar 同一组函数。
    /// 无底单色，不给薄荷 glyph 垫薄荷底。
    private var macSelectionBar: some View {
        let unpin = MemoryPinPlan.unpins(selectedLiveArchive)
        return HStack(spacing: 14) {
            Text(selection.isEmpty ? "⌘ 点选多条" : "\(selection.count) 已选")
                .foregroundColor(Theme.textMuted)
            Spacer()
            Button { pinSelected() } label: {
                Label(unpin ? "取消钉住" : "钉住", systemImage: unpin ? "pin.slash" : "pin")
            }
            .disabled(selectedLiveArchive.isEmpty)
            Button(role: .destructive) { deleteSelected() } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
            Button { resetSelection() } label: {
                Image(systemName: "xmark.circle")
            }
            .help("取消选择")
        }
        .font(m.body)
        .foregroundColor(Theme.textSecondary)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    #endif

    #if os(iOS)
    @ToolbarContentBuilder
    private var memoryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if editMode?.wrappedValue.isEditing == true {
                MemorySelectButton()
            } else {
                if !foldAdd {
                    addMemoryButton
                }
                moreMenu
            }
        }
        if editMode?.wrappedValue == .active {
            ToolbarItemGroup(placement: .bottomBar) {
                let unpin = MemoryPinPlan.unpins(selectedLiveArchive)
                Button { pinSelected() } label: {
                    Label(unpin ? "取消钉住" : "钉住", systemImage: unpin ? "pin.slash" : "pin")
                }
                .disabled(selectedLiveArchive.isEmpty)
                Spacer()
                Text("\(selection.count) 已选")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(role: .destructive) { deleteSelected() } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
    }
    #endif

    // MARK: - Actions（单条和多选同一组函数）

    private func liveArchive(_ ids: Set<MemoryRowID>) -> [Memory] {
        memories.filter { $0.supersededAt == nil && ids.contains(.archive($0.id)) }
    }

    private var selectedLiveArchive: [Memory] { liveArchive(selection) }

    private func resetSelection() {
        selection = []
        #if os(iOS)
        editMode?.wrappedValue = .inactive
        #else
        macSelecting = false
        #endif
    }

    private func edit(_ id: MemoryRowID) {
        switch id {
        case .archive(let uuid):
            editingMemory = memories.first { $0.id == uuid }
        case .assistant(let slug):
            editingSelfMemory = selfMemories.first { $0.slug == slug }
        }
    }

    private func pin(_ targets: [Memory]) {
        guard !targets.isEmpty else { return }
        MemoryPinPlan.apply(targets)
        try? modelContext.save()
        refreshMemories()
    }

    private func pinSelected() {
        pin(selectedLiveArchive)
        resetSelection()
    }

    private func deleteSelected() {
        moveToTrash(selection)
        resetSelection()
    }

    /// 删除 = 移到「已删除」，可恢复，不确认；只碰活着的（按楼层 ID 读最新列表再按 id 找）
    private func moveToTrash(_ ids: Set<MemoryRowID>) {
        let pid = profileManager?.currentProfile.id ?? ""
        let targets = store.listAll(profileId: pid, context: modelContext).filter { ids.contains(.archive($0.id)) }
        if !MemoryDeletePlan.moveToTrash(targets).isEmpty {
            try? modelContext.save()
        }
        let now = Date()
        for (i, m) in selfMemories.enumerated() where m.isActive && ids.contains(.assistant(m.slug)) {
            var deleted = m
            deleted.superseded = now
            if (try? SelfMemoryStore.save(deleted, profileId: pid)) != nil {
                selfMemories[i] = deleted
            }
        }
        selection.subtract(ids)
        refreshMemories()
    }

    /// 同时间轴：load 完再发通知，页 2 才会翻回聊天页（有 nodeId 那支 navigateToSearchResult 自己发）
    private func jumpToSource(_ memory: Memory) {
        guard let cid = memory.sourceConversationId else { return }
        let pid = profileManager?.currentProfile.id ?? ""
        let convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { conv in conv.id == cid && conv.profileId == pid }
        )
        guard let conv = try? modelContext.fetch(convDesc).first else { return }
        if let nodeId = memory.sourceNodeId {
            viewModel.navigateToSearchResult(nodeId: nodeId, conversation: conv, context: modelContext)
        } else {
            viewModel.loadConversation(conv, context: modelContext)
            NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
        }
    }

    // MARK: - Data

    /// 口径同 `SearchService.searchMemories`：content 或 keywords 任一 localizedStandardContains
    private var visibleMemories: [Memory] {
        guard let kw = searchText.panelSearchKeyword else { return memories }
        return memories.filter { mem in
            mem.content.localizedStandardContains(kw) || mem.keywords.contains { $0.localizedStandardContains(kw) }
        }
    }

    /// 第二刀 A1：档案不分冷热——活着的按创建时间新→旧（钉住在前）；已删除的不在主列表
    private var activeMemories: [Memory] {
        MemoryArchiveOrder.split(visibleMemories).active
    }

    private var visibleRowIds: Set<MemoryRowID> {
        Set(activeMemories.map { MemoryRowID.archive($0.id) } + selfPanelRows.map { MemoryRowID.assistant($0.slug) })
    }

    /// 读盘位置不变（档案主线程 fetch、自记 + 画像后台读）。首次读：档案先攥着，等后台那份到了一起上台，
    /// 不然画像卡、自记组会在档案已经画出来之后再插进来（打开时「重排一下闪一下」）；之后的刷新档案照旧立刻换
    private func refreshMemories() {
        let profileId = profileManager?.currentProfile.id ?? ""
        let archive = (try? store.listAll(profileId: profileId, context: modelContext)) ?? []
        let warning = MemoryHealthWarning.text(profileId: profileId)
        let firstLoad = !loaded
        if !firstLoad {
            memories = archive
            healthWarning = warning
        }
        Task {
            let (list, dream) = await Task.detached {
                (SelfMemoryStore.list(profileId: profileId), ProfileFileStore.load(profileId: profileId))
            }.value
            guard profileId == profileManager?.currentProfile.id else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                if firstLoad {
                    memories = archive
                    healthWarning = warning
                }
                selfMemories = list
                aboutDream = dream
                loaded = true
            }
        }
    }
}

/// 关系图（原分段里的「图谱」）：从「⋯」打开，iOS 全屏、mac 大弹层
private struct MemoryGraphSheet: View {
    let memories: [Memory]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MemoryGraphView(memories: memories)
                .toolPageBackground()
                .panelSheetTitle("关系图")
                #if os(macOS)
                .frame(minWidth: 720, idealWidth: 900, minHeight: 600, idealHeight: 720)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                            .foregroundColor(Theme.branchIndicator)
                    }
                }
        }
    }
}

#if os(iOS)
/// 中文「选择 / 完成」：同 `EditButton` 在 toolbar 里就地读写 environment.editMode（App 没中文本地化，系统 EditButton 显示英文）
struct MemorySelectButton: View {
    @Environment(\.editMode) private var editMode

    var body: some View {
        let editing = editMode?.wrappedValue.isEditing == true
        Button(editing ? "完成" : "选择") {
            withAnimation { editMode?.wrappedValue = editing ? .inactive : .active }
        }
        .foregroundColor(Theme.branchIndicator)
    }
}
#endif

/// 记忆列表的日期：今年写「10月10日」，往年写「2025年3月2日」（两组记忆共用；不走系统 locale，App 没中文本地化）
enum MemoryDateText {
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let md = "\(c.month ?? 0)月\(c.day ?? 0)日"
        return c.year == calendar.component(.year, from: now) ? md : "\(c.year ?? 0)年\(md)"
    }
}

/// 首屏画像卡底的一行提醒：连续失败才有，正常时不显示运行状态
enum MemoryHealthWarning {
    static func text(profileId: String) -> String? {
        if MemoryHealthStore.status(.extract, profileId: profileId).needsAttention { return "最近记不住新东西了" }
        if MemoryHealthStore.status(.dream, profileId: profileId).needsAttention { return "最近写不成画像" }
        if MemoryHealthStore.status(.context, profileId: profileId).needsAttention { return "最近写不成上下文摘要" }
        if MemoryHealthStore.status(.summary, profileId: profileId).needsAttention { return "最近写不成窗口总结" }
        if MemoryHealthStore.status(.timeline, profileId: profileId).needsAttention { return "最近写不成时间轴" }
        return nil
    }
}

// MARK: - 刀3 注入预览（复用真实执行路径：MemoryInjector.roundInputs → PromptAssembler.memoryLayers，与 composePrompt 同源）

struct InjectionPreviewSheet: View {
    let profileId: String
    /// 实发看当前对话的记忆开关（composePrompt 同口径）；没有对话 = 开
    var conversationMemoryEnabled: Bool = true
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m

    @State private var stable = ""
    @State private var volatilePart = ""
    @State private var memoryCount = 0
    @State private var masterOff = false
    @State private var lastInjection: MemoryInjectionRecord? = nil

    var body: some View {
        NavigationStack {
            List {
                if masterOff {
                    Section {
                        Text("记忆总开关关着，下一轮不会想起任何记忆")
                            .font(m.body)
                            .foregroundColor(Theme.textMuted)
                    }
                    .panelRowBackground()
                } else {
                    layerSection("每次都会想起的", stable)
                    layerSection("聊到相关话题才会想起的", volatilePart)
                    if stable.isEmpty && volatilePart.isEmpty {
                        Section {
                            Text("下一轮不会想起任何记忆（还没有记忆，或相关开关都关着）")
                                .font(m.body)
                                .foregroundColor(Theme.textMuted)
                        }
                        .panelRowBackground()
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        if !masterOff {
                            Text("不管聊什么，每次都会带上这些：共 \(memoryCount) 条，大约占 \(stable.count + volatilePart.count) 字的位置")
                            Text("按刚开始聊天的情形预览；聊到具体话题时，还会想起更多相关的")
                        }
                        if let r = lastInjection {
                            Text(r.viaCCBridge == true
                                 ? "上一轮走的是 CC，CC 不会带上这里的记忆"
                                 : "上一轮带上了：\(assistantName)自己记下的 \(r.selfCount ?? 0) 条、关于你的 \(r.stableCount + r.hitCount) 条")
                        }
                    }
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Color.clear)
                }
            }
            .panelListStyle()
            .scrollContentBackground(.hidden)
            .toolPageBackground()
            .panelSheetTitle("下一轮会想起什么")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
            #if os(macOS)
            .frame(width: 520, height: 480)
            #endif
            .onAppear(perform: buildPreview)
        }
    }

    private var assistantName: String {
        let n = profileManager?.profiles.first { $0.id == profileId }?.assistantName ?? ""
        return n.isEmpty ? "助手" : n
    }

    /// 每条一行正常字体；「[关于…]」这类段标签画成小灰字
    @ViewBuilder
    private func layerSection(_ title: String, _ text: String) -> some View {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !lines.isEmpty {
            Section(title) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("[") && line.hasSuffix("]") {
                        Text(line.dropFirst().dropLast())
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    } else {
                        Text(line.hasPrefix("- ") ? String(line.dropFirst(2)) : line)
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            }
            .panelRowBackground()
        }
    }

    private func buildPreview() {
        lastInjection = MemoryInjectionMeter.load(profileId: profileId)
        masterOff = !MemoryFlags.masterEnabled
        guard !masterOff,
              let profile = profileManager?.profiles.first(where: { $0.id == profileId }) ?? profileManager?.currentProfile
        else { return }
        let inputs = MemoryInjector.roundInputs(profileId: profileId, conversationMemoryEnabled: conversationMemoryEnabled,
                                                store: SwiftDataMemoryStore(), context: modelContext)
        let selfCount = (inputs.selfMemory?.fullCount ?? 0) + (inputs.selfMemory?.indexCount ?? 0)
        memoryCount = inputs.memories.count + selfCount
        let layers = PromptAssembler.memoryLayers(profile: profile,
                                                  selfMemory: (inputs.selfMemory?.text).flatMap { $0.isEmpty ? nil : $0 },
                                                  memories: inputs.memories, recentMessages: [], budget: inputs.archiveBudget)
        stable = layers.stable
        volatilePart = layers.volatile
    }
}

// MARK: - Memory Card

struct MemoryCardView: View {
    @Environment(\.chatMetrics) private var metrics
    let memory: Memory
    var isFlashing: Bool = false
    var onPin: () -> Void
    var onDelete: () -> Void
    var onEdit: (() -> Void)? = nil            // 刀2：单条编辑（还权）
    var onRevive: (() -> Void)? = nil          // 已失效记忆的复活（SC-B2）
    var onJumpToSource: (() -> Void)? = nil    // 出处跳转源对话（SC-B2）

    /// 行尾动作菜单（Lite「管理记忆条目」页用；主记忆页已换成 MemoryRow）
    private var actionMenu: some View {
        Menu {
            if let onEdit {
                Button("编辑", action: onEdit)
            }
            Button(memory.isUserExplicit ? "取消钉住" : "钉住", action: onPin)
            if memory.supersededAt != nil, let onRevive {
                Button("恢复", action: onRevive)
            }
            Button(memory.supersededAt == nil ? "删除" : "彻底删除",
                   role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textMuted)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }
    @State private var flashOpacity: Double = 0

    static let categoryLabels: [String: String] = [
        "preference": "偏好", "fact": "事实", "relationship": "关系",
        "goal": "目标", "context": "近况"
    ]

    // 第二刀 A1：档案不显示冷热——不再随热度变淡 / 呼吸 / 换边框色；只区分钉住与已失效
    private var baseOpacity: Double { memory.supersededAt != nil ? 0.45 : 1.0 }

    private var borderColor: Color {
        Theme.branchIndicator
    }

    private var borderWidth: CGFloat { 2 }

    var body: some View {
        HStack(spacing: 0) {
            // Left border
            RoundedRectangle(cornerRadius: 1.5)
                .fill(borderColor)
                .frame(width: borderWidth)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                // Content
                Text(memory.content)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(metrics.memoryCardLines)

                // 出处行（SC-B2）：有 quote 显示，可点跳源对话（v1 跳对话不定位消息）
                if let quote = memory.sourceQuote {
                    Button { onJumpToSource?() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "quote.opening")
                                .font(.system(size: 7))
                            Text(quote)
                                .font(.system(size: Theme.F.caption))
                                .lineLimit(1)
                        }
                        .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .disabled(onJumpToSource == nil)
                }

                // Meta row
                HStack(spacing: 6) {
                    // Category tag
                    Text(Self.categoryLabels[memory.category] ?? memory.category)
                        .font(.system(size: Theme.F.badge, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Theme.branchIndicator.opacity(0.12))
                        )

                    Text(MemoryDateText.short(memory.createdAt))
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)

                    Spacer()

                    // 已失效标记（SC-B2）
                    if memory.supersededAt != nil {
                        Text("已删除")
                            .font(.system(size: Theme.F.badge))
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().stroke(Theme.textMuted.opacity(0.5), lineWidth: 0.5))
                    }

                    // Pin icon
                    if memory.isUserExplicit {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor(Theme.branchIndicator)
                    }

                    actionMenu
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 6)
            .padding(.trailing, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.mainBg.opacity(0.6))
        )
        // Phosphor flash overlay
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.branchIndicator.opacity(flashOpacity))
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(baseOpacity)
        .onChange(of: isFlashing) { _, flashing in
            if flashing {
                withAnimation(.easeIn(duration: 0.2)) { flashOpacity = 0.4 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeOut(duration: 0.6)) { flashOpacity = 0 }
                }
            }
        }
    }

}

// MARK: - Profile Editing（FileEditorSheet 复用 + 独立提示词 sheet）

/// 画像编辑 sheet 上下文（Identifiable 让 .sheet(item:) 触发）
struct ProfileEditingContext: Identifiable {
    let id = UUID()
    let text: String
    let modifiedAt: Date?
}

