import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

// MARK: - Settings Container

struct SettingsView: View {
    var viewModel: ConversationViewModel? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(RightPanelNavigator.self) private var rightPanelNavigator: RightPanelNavigator?

    @State private var selectedTab: SettingsTab = .general
    #if os(macOS)
    @State private var readingModelSession = MacReadingModelSession()
    #endif

    enum SettingsTab: String, CaseIterable {
        case general = "通用"
        #if os(macOS)
        case macWorkspace = "Mac 工作区"
        #endif
        case tts = "朗读"
        case attachment = "附件"
        case data = "数据与备份"
        case api = "API"
        /// 统一用量页（research-magpie 2.1）：逐次调用账本 + 汇总
        case usage = "用量"
        case mcp = "MCP"
        case persona = "Prompt"
        /// 小芽助手（创作助手，plan-小芽助手 Q4：人设设置里可改）
        case xiaoya = "小芽"
        case regex = "正则"
        /// 世界书原本是游离页（只有 Prompt「相关」区的 NavigationLink 能进），设置搜索要能直达 → 转正进枚举
        case worldBook = "世界书"
        case rightPanel = "右栏"
        case fileLibrary = "文件库"
        case sandbox = "手机里的小电脑"
        case memory = "记忆"
        case health = "健康"
        case calendar = "日历"
        #if PERSONAL_APPS
        case trading = "交易"
        #endif
        case sticker = "贴纸"
        case terminal = "终端"
        case claudeCode = "Claude Code"
        case codex = "Codex"
        /// #046 T3：配对 / 连接状态 / Agent 干活的目录收拢到一页。iOS 叫「我的电脑」，Mac 上是「让手机连这台 Mac」
        #if os(iOS)
        case myComputer = "我的电脑"
        #else
        case myComputer = "让手机连这台 Mac"
        #endif
        case groupChat = "群聊"
        case appearance = "外观"
        #if os(iOS)
        /// Page2 子应用各自的设置（先只有「聊天（css自定义）」；ChatSkin 整套 iOS-only）
        case subApps = "子应用"
        #endif
        case theme = "主题"
        case config = "config"
        case agent = "Agent"
        case reading = "书房"
        case vocab = "单词"
        case permissions = "权限"
        case manual = "文档"
        case about = "关于"
        case debug = "开发调试"
    }

    private var manager: ThemeManager {
        themeManager ?? ThemeManager.shared
    }

    var body: some View {
        let _ = manager.themeChangeID
        // 设置树统一薄荷 tint：toggle 默认系统绿 / 按钮默认系统蓝，都不许（粟粟 08-26「所有绿按钮都改」）；
        // 各页局部 .tint(Theme.textSecondary) 的下拉仍各自生效
        #if os(iOS)
        iOSSettingsBody.tint(Theme.branchIndicator)
        #else
        macOSSettingsBody.tint(Theme.branchIndicator)
        #endif
    }

    @State private var selectedSettingsTab: SettingsTab? = nil
    #if os(iOS)
    /// 底部玻璃胶囊点开的全屏搜索面板（收起态就是那颗胶囊本身）
    @State private var showSearchPanel = false
    /// 设置页右上角花园开关：lite/pro 模式
    @AppStorage("settings.proMode") private var settingsProMode = false
    /// 搜索框「?」弹的玻璃选项单：新手引导 / App 文档（未写，占位）
    @State private var showHelpMenu = false
    /// 重走一遍 onboarding 引导（设计 docs/未来愿景/design-onboarding.md）
    @State private var showOnboarding = false
    /// 底部搜索胶囊实测高度，喂给 safeAreaInset 当列表底部留白。
    /// 原来写死 46 —— 那个数隐含「底下还有 home indicator 安全区补一截」，
    /// iPad 上设置是居中 form sheet（底边就是 sheet 边、没有额外安全区），
    /// 46 不够，胶囊压住最后一行（「关于记忆花园」被切半行）。初值仍是 46，测到有效值就换。
    @State private var searchBarHeight: CGFloat = 46
    #endif

    #if os(iOS)
    private var iOSSettingsBody: some View {
        NavigationStack {
            List {
                Section {
                    FeedbackDebugSection()
                }
                .listRowBackground(Theme.mainBg)

                if settingsProMode {
                    // ── Pro：九块全量 ──
                    Section {
                        settingsButton(icon: "gearshape", title: "通用", color: Theme.textSecondary, tab: .general)
                        languageRow()
                        settingsButton(icon: "lock.shield", title: "权限", color: Theme.textSecondary, tab: .permissions)
                        settingsButton(icon: "archivebox", title: "数据与备份", color: Theme.textSecondary, tab: .data)
                        settingsButton(icon: "square.and.arrow.up.on.square", title: "config", color: Theme.textSecondary, tab: .config)
                    }
                    Section {
                        settingsButton(icon: "paintbrush", title: "外观", color: Theme.textSecondary, tab: .appearance)
                        settingsButton(icon: "square.grid.3x3", title: "子应用", color: Theme.textSecondary, tab: .subApps)
                    }
                    Section {
                        settingsButton(icon: "text.bubble", title: "Prompt", color: Theme.branchIndicator, tab: .persona)
                        settingsButton(icon: "xiaoya-cameo", title: "小芽", color: Theme.textSecondary, tab: .xiaoya)
                        settingsButton(icon: "brain.head.profile", title: "记忆", color: Theme.textSecondary, tab: .memory)
                    }
                    Section {
                        settingsButton(icon: "network", title: "API", color: Theme.textSecondary, tab: .api)
                        settingsButton(icon: "chart.bar.xaxis", title: "用量", color: Theme.textSecondary, tab: .usage)
                        SettingsFoldRow(icon: "puzzlepiece.extension", title: "AI 连接与拓展", storageKey: "settingsFold.aiExt") {
                            settingsButton(icon: "speaker.wave.2", title: "语音", color: Theme.textSecondary, tab: .tts, guide: .middle)
                            placeholderRow(icon: "photo.on.rectangle", title: "生图", guide: .middle)
                            placeholderRow(icon: "puzzlepiece", title: "Skill", guide: .middle)
                            settingsButton(icon: "point.3.connected.trianglepath.dotted", title: "MCP", color: Theme.textSecondary, tab: .mcp, guide: .last)
                        }
                    }
                    Section {
                        SettingsFoldRow(icon: "terminal", title: "编程工具", storageKey: "settingsFold.devTools") {
                            settingsButton(icon: "laptopcomputer.and.iphone", title: "我的电脑", color: Theme.textSecondary, tab: .myComputer, guide: .middle)
                            settingsButton(icon: "ri-claude", title: "Claude Code", color: Theme.textSecondary, tab: .claudeCode, guide: .middle)
                            settingsButton(icon: "ri-openai", title: "Codex", color: Theme.textSecondary, tab: .codex, guide: .middle)
                            // R5：Agent 页 iOS 开放——数据经 cc-bridge WS 拉 Mac 快照/发配置补丁（N-D9 堵漏解除）
                            settingsButton(icon: "ri-robot-2", title: "Agent", color: Theme.textSecondary, tab: .agent, guide: .middle)
                            settingsButton(icon: "terminal", title: "终端", color: Theme.textSecondary, tab: .terminal, guide: .last)
                        }
                    }
                    Section {
                        settingsButton(icon: "sidebar.right", title: "右栏", color: Theme.textSecondary, tab: .rightPanel)
                        SettingsFoldRow(icon: "square.grid.2x2", title: "模块", storageKey: "settingsFold.modules") {
                            settingsButton(icon: "ri-emoji-sticker", title: "贴纸", color: Theme.textSecondary, tab: .sticker, guide: .middle)
                            settingsButton(icon: "heart.text.square", title: "健康", color: Theme.textSecondary, tab: .health, guide: .middle)
                            settingsButton(icon: "calendar", title: "日历", color: Theme.textSecondary, tab: .calendar, guide: .middle)
                            #if PERSONAL_APPS
                            settingsButton(icon: "chart.line.uptrend.xyaxis", title: "交易", color: Theme.textSecondary, tab: .trading, guide: .middle)
                            #endif
                            settingsButton(icon: "books.vertical", title: "书房", color: Theme.textSecondary, tab: .reading, guide: .middle)
                            settingsButton(icon: "abc", title: "单词", color: Theme.textSecondary, tab: .vocab, guide: .middle)
                            settingsButton(icon: "person.2", title: "群聊", color: Theme.textSecondary, tab: .groupChat, guide: .last)
                        }
                    }
                    Section {
                        SettingsFoldRow(icon: "externaldrive", title: "储存与文件", storageKey: "settingsFold.storage") {
                            placeholderRow(icon: "externaldrive", title: "储存", guide: .middle)
                            settingsButton(icon: "folder.fill", title: "文件库", color: Theme.textSecondary, tab: .fileLibrary, guide: .middle)
                            settingsButton(icon: "shippingbox", title: "手机里的小电脑", color: Theme.textSecondary, tab: .sandbox, guide: .middle)
                            placeholderRow(icon: "folder.badge.plus", title: "挂载和共享文件夹", guide: .last)
                        }
                    }
                    Section {
                        settingsButton(icon: "ladybug", title: "开发调试", color: Theme.textSecondary, tab: .debug)
                    }
                } else {
                    // ── Lite：只露 6 个入口（design-lite-mode.md），数据与 pro 共通，只是藏入口 ──
                    Section {
                        settingsButton(icon: "gearshape", title: "通用", color: Theme.textSecondary, tab: .general)
                        languageRow()
                        settingsButton(icon: "lock.shield", title: "权限", color: Theme.textSecondary, tab: .permissions)
                    }
                    Section {
                        settingsButton(icon: "paintbrush", title: "外观", color: Theme.textSecondary, tab: .appearance)
                        settingsButton(icon: "square.grid.3x3", title: "子应用", color: Theme.textSecondary, tab: .subApps)
                    }
                    Section {
                        settingsButton(icon: "face.smiling", title: "AI 性格", color: Theme.branchIndicator, tab: .persona)
                        settingsButton(icon: "xiaoya-cameo", title: "小芽", color: Theme.textSecondary, tab: .xiaoya)
                        settingsButton(icon: "brain.head.profile", title: "记忆", color: Theme.textSecondary, tab: .memory)
                    }
                    Section {
                        settingsButton(icon: "network", title: "模型（API）", color: Theme.textSecondary, tab: .api)
                        settingsButton(icon: "chart.bar.xaxis", title: "用量", color: Theme.textSecondary, tab: .usage)
                    }
                }

                // ── 关于坨：lite / pro 都有，垫底 ──
                Section {
                    settingsButton(icon: "leaf", title: "关于记忆花园", color: Theme.textSecondary, tab: .about)
                    placeholderRow(icon: "hand.raised", title: "隐私政策")
                    placeholderRow(icon: "doc.text", title: "服务条款")
                    versionRow()
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selectedSettingsTab) { tab in
                switch tab {
                case .general: GeneralPage()
                case .tts: TTSPage()
                case .attachment: AttachmentPage()
                case .appearance: AppearancePage()
                case .subApps: SubAppsSettingsPage()
                case .theme: ThemeLibraryPage()
                case .persona:
                    // lite 走简化「AI 性格」页，pro 走完整 Prompt 页；同一份插槽数据
                    if settingsProMode { PersonaSettingsTab() } else { LitePersonaPage() }
                case .api: APISettingsTab()
                case .usage: UsageSettingsPage()
                case .xiaoya: XiaoyaSettingsTab()
                case .mcp: MCPSettingsTab(viewModel: viewModel)
                case .memory:
                    // lite 走简化「记忆」页（总开关+画像卡+条目管理），pro 走完整开关页
                    if settingsProMode { MemoryPage() } else { LiteMemoryPage(viewModel: viewModel) }
                case .health: HealthSettingsTab()
                case .calendar: CalendarSettingsTab()
                #if PERSONAL_APPS
                case .trading: TradingSettingsTab()
                #endif
                case .regex: RegexPage()
                case .worldBook: WorldBookPage()
                case .sticker:
                    StickerPage()
                case .terminal:
                    TerminalSettingsTab()
                case .claudeCode:
                    CCSettingsView()
                case .codex:
                    CodexSettingsTab()
                case .myComputer:
                    MyComputerSettingsPage()
                case .groupChat:
                    GroupChatSettingsTab()
                case .rightPanel:
                    RightPanelPage()
                case .fileLibrary: FileLibrarySettingsTab()
                case .sandbox:
                    // #045：「打开终端」= 关掉设置，交给 ContentView 打开终端页开一个新的小电脑 shell
                    SandboxSettingsTab(onOpenTerminal: {
                        rightPanelNavigator?.pendingTarget = .init(tool: "ccTerminal", id: TerminalPanelRoot.newLocalTargetId)
                        dismiss()
                    })
                case .data: DataSettingsTab()
                case .config: ConfigPage()
                case .agent: AgentSettingsTab()
                case .reading: ReadingSettingsTab()
                case .vocab: VocabSettingsTab()
                case .permissions: PermissionsSettingsTab()
                case .manual: ManualView()
                case .about: IOSAboutPage()
                case .debug: DebugPage()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 5) {
                        Text("设置")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(settingsProMode ? "pro" : "lite")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .offset(y: 2)   // 跟大标题基线对齐
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    GardenModeToggle(isPro: $settingsProMode)
                }
            }
            // 底部玻璃搜索框（仿 iOS 26 设置）：overlay 浮在列表上才有真模糊；
            // safeAreaInset 只塞透明占位，给列表底部留出滚动空间
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: searchBarHeight)
            }
            .overlay(alignment: .bottom) {
                SettingsSearchBar(onActivate: { showSearchPanel = true }, onHelp: { showHelpMenu = true })
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        if h > 0 { searchBarHeight = h }
                    }
            }
            // 搜索面板 / 「？」选项单盖在胶囊之上（overlay 顺序 = 层序）
            .overlay {
                SettingsSearchPanel(isPresented: $showSearchPanel, onSelect: jumpToSearchResult)
            }
            .overlay {
                SettingsHelpMenu(isPresented: $showHelpMenu, onOnboarding: { showOnboarding = true }, onManual: { selectedSettingsTab = .manual })
            }
            .fullScreenCover(isPresented: $showOnboarding) { OnboardingFlowView() }
            .scrollDismissesKeyboard(.interactively)
            // 点外面收键盘：window 层挂 cancelsTouchesInView=false 的识别器，不拦点击、不打架
            .background(KeyboardDismissInstaller())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sidebarBg.ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { BreadcrumbLog.shared.add("⚙️", "打开设置") }
    }
    #endif

    #if os(macOS)
    @State private var hoveredMacTab: SettingsTab?
    @State private var macSearchText = ""
    @State private var workspacePreferences = MacWorkspacePreferences.shared
    @State private var showMacFeedbackPopover = false
    @State private var hoveredMacFeedback = false

    /// A4：侧栏底「记录反馈」一行（与侧栏项同样式，无底不选中），点开 popover 是完整控制区
    private var macFeedbackEntry: some View {
        Button {
            showMacFeedbackPopover = true
        } label: {
            HStack(spacing: 6) {
                AppIconView(name: "square.and.pencil", size: ShellStyle.iconSize,
                            tint: ShellStyle.tileGlyph, weight: .medium)
                    .frame(width: 22, height: 22)
                Text("记录反馈").font(ShellStyle.secondaryFont)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ShellStyle.text)
            .padding(.vertical, 4)
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: ShellStyle.controlRadius)
                .fill(hoveredMacFeedback ? ShellStyle.hover : Color.clear)
                .padding(.horizontal, 10)
        )
        .onHover { hoveredMacFeedback = $0 }
        // 与目录分开：一条 hairline + 上下留白，免得读起来像最后那组的第 N 项
        .padding(.top, 8)
        .padding(.bottom, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(ShellStyle.hairline).frame(height: ShellStyle.hairlineWidth)
                .padding(.horizontal, 14)
        }
        .popover(isPresented: $showMacFeedbackPopover, arrowEdge: .trailing) {
            FeedbackDebugSection()
                .padding(14)
                .frame(width: 320)
        }
    }

    private var macOSSettingsBody: some View {
        NavigationSplitView {
            // 侧栏 = 目录 List + 底部「记录反馈」行（A4）。mac 的 List 是 AppKit 表，`safeAreaInset(.bottom)` 不会让内容让位（会叠在最后一项上），所以底行放 List 外面
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { Optional(selectedTab) },
                    set: { if let tab = $0 { selectedTab = tab } }
                )) {
                    ForEach(macSidebarGroups) { group in
                        Section {
                            ForEach(group.tabs.filter { macTabs.contains($0) }, id: \.self) { tab in
                                Label {
                                    Text(tab.rawValue).font(ShellStyle.secondaryFont)
                                } icon: {
                                    if let icon = SettingsSearchEntry.iconByTab[tab] {
                                        // 小样候选 B：无底单色 glyph（粟粟：禁止深绿套浅绿，不给 glyph 垫薄荷方块）
                                        AppIconView(name: icon, size: ShellStyle.iconSize,
                                                    tint: selectedTab == tab ? ShellStyle.text : ShellStyle.tileGlyph,
                                                    weight: .medium)
                                            .frame(width: 22, height: 22)
                                    }
                                }
                                .foregroundStyle(ShellStyle.text)
                                .padding(.vertical, 2)
                                .tag(tab)
                                // 窗口为 key 时 sidebar 选中面走系统强调色（粟粟机器是黄绿），钉成薄荷
                                .listItemTint(Theme.branchIndicator)
                                .listRowSeparator(.hidden)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: ShellStyle.controlRadius)
                                        .fill(selectedTab == tab ? ShellStyle.selection :
                                            (hoveredMacTab == tab ? ShellStyle.hover : Color.clear))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 2)
                                )
                                .onHover { hoveredMacTab = $0 ? tab : nil }
                            }
                        } header: {
                            Text(group.title)
                                .font(ShellStyle.microFont)
                                .foregroundStyle(ShellStyle.mutedText)
                                .padding(.top, 10)
                        }
                        .collapsible(false)
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $macSearchText, placement: .sidebar, prompt: "搜索设置")
                .scrollContentBackground(.hidden)
            // A4（她裁 (a)）：反馈入口从开发调试页搬到侧栏底一行，点开 popover 是完整的 FeedbackDebugSection，
            // 与 iOS 根列表顶那块对称。与侧栏项同样式（glyph + 文字、无底、不做选中态）。
            macFeedbackEntry
            }
            .background {
                ShellStyle.background.opacity(0.72)
                    .ignoresSafeArea(edges: .top)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            MacSettingsPage(tab: selectedTab) { macTabContent(selectedTab) }
                .navigationTitle(selectedTab.rawValue)   // 页名在 unified toolbar 里，紧挨 ‹ ›
                .transaction { $0.animation = nil }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 780, minHeight: 560)
        .onAppear {
            BreadcrumbLog.shared.add("⚙️", "打开设置")
            consumeWorkspaceRequest()
        }
        .onChange(of: workspacePreferences.settingsRequested) { _, _ in consumeWorkspaceRequest() }
        // 页面里的跳转行（Claude Code 页「去『让手机连这台 Mac』」）：object = 目标 tab 的 rawValue
        .onReceive(NotificationCenter.default.publisher(for: .settingsOpenTab)) { note in
            guard let raw = note.object as? String, let tab = SettingsTab(rawValue: raw), macTabs.contains(tab) else { return }
            macSearchText = ""
            selectedTab = tab
        }
        #if DEBUG
        .onAppear {
            if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--mp-open-settings=") }),
               let tab = SettingsTab(rawValue: String(argument.dropFirst("--mp-open-settings=".count))),
               macTabs.contains(tab) { selectedTab = tab }
        }
        #endif
        .background(ShellStyle.windowBackground)
        .background(MacSettingsWindowStyle())
        .background(MacScrollbars())
    }

    private func consumeWorkspaceRequest() {
        guard workspacePreferences.settingsRequested else { return }
        macSearchText = ""
        selectedTab = .macWorkspace
        workspacePreferences.settingsRequested = false
    }

    private var macSidebarGroups: [MacSettingsSidebarGroup] {
        let query = macSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A1：注册表 4 条 `.theme` 条目一字不动（动了会改 iOS 路由），mac 这边把命中折算成 `.appearance`
        // ——主题库在 mac 是外观页的二级页，入口就在外观页前部
        let matches = Set(SettingsSearchEntry.all.filter { !$0.opensCardLibrarySettings && $0.matchScore(for: query) != nil }
            .compactMap(\.tab)
            .map { $0 == .theme ? SettingsTab.appearance : $0 })
        return MacSettingsSidebarGroup.all.compactMap { group in
            let tabs = group.tabs.filter { macTabs.contains($0) &&
                (query.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(query) || matches.contains($0)) }
            return tabs.isEmpty ? nil : MacSettingsSidebarGroup(title: group.title, tabs: tabs)
        }
    }

    /// .sandbox 是 iOS-only（macOS 的 run_command 跑在真机器上，没有沙箱）；
    /// .theme 在 A1 后不再是 mac 的 tab（主题库降成外观页二级页）；
    /// .terminal 只管键盘工具条，Mac 没有工具条（T43）。
    /// 枚举 case 两端共用，这里滤掉免得 Mac 上多一个点开是空的 tab
    private var macTabs: [SettingsTab] {
        SettingsTab.allCases.filter { $0 != .sandbox && $0 != .theme && $0 != .terminal }
    }

    /// 27 个可见 tab 的滚动归属（astra F9）：13 页自带滚动容器直接填 detail；14 页普通内容包 ScrollView
    @ViewBuilder
    private func macTabContent(_ tab: SettingsTab) -> some View {
        switch tab {
        case .macWorkspace:
            MacWorkspaceSettingsPage()
        // ── 自滚容器（List / Form / 自带 ScrollView）：直接填满 detail，不再硬高 430
        case .api:
            APISettingsTab().scrollContentBackground(.hidden)
        case .usage:
            UsageSettingsPage { SubscriptionQuotaCard() }.scrollContentBackground(.hidden)
        case .health:
            MacSettingsForm { HealthGatesSections(profileId: profileManager?.currentProfile.id ?? "") }
                .scrollContentBackground(.hidden)
        case .calendar:
            MacSettingsForm { CalendarSettingsSections(profileId: profileManager?.currentProfile.id ?? "") }
                .scrollContentBackground(.hidden)
        #if PERSONAL_APPS
        case .trading:
            MacSettingsForm { TradingGatesSections(profileId: profileManager?.currentProfile.id ?? "") }
                .scrollContentBackground(.hidden)
        #endif
        case .terminal:
            TerminalSettingsTab().scrollContentBackground(.hidden)
        case .claudeCode:
            CCSettingsView().scrollContentBackground(.hidden)
        case .codex:
            CodexSettingsTab().scrollContentBackground(.hidden)
        case .myComputer:
            MyComputerSettingsPage().scrollContentBackground(.hidden)
        case .groupChat:
            GroupChatSettingsTab().scrollContentBackground(.hidden)
        case .config:
            ConfigPage().scrollContentBackground(.hidden)
        case .agent:
            AgentSettingsTab().scrollContentBackground(.hidden)
        case .reading:
            ReadingSettingsTab(macModelSession: readingModelSession).scrollContentBackground(.hidden)
        case .vocab:
            VocabSettingsTab().scrollContentBackground(.hidden)
        case .permissions:
            PermissionsSettingsTab().scrollContentBackground(.hidden)
        // 刀 3 合流后的页：iOS 真身 List → SettingsSectionList → mac 自带 MacSettingsForm 滚动
        case .sticker:
            StickerPage().scrollContentBackground(.hidden)
        case .rightPanel:
            RightPanelPage().scrollContentBackground(.hidden)
        case .data:
            DataSettingsTab().scrollContentBackground(.hidden)
        case .general:
            GeneralPage().scrollContentBackground(.hidden)
        case .tts:
            TTSPage().scrollContentBackground(.hidden)
        case .attachment:
            AttachmentPage().scrollContentBackground(.hidden)
        case .worldBook:
            WorldBookPage().scrollContentBackground(.hidden)
        case .appearance:
            AppearancePage().scrollContentBackground(.hidden)
        case .manual:
            ManualView()
        // ── 普通内容：各自包 ScrollView（刀 3 逐页迁走）
        case .persona:
            PersonaSettingsTab().scrollContentBackground(.hidden)
        case .xiaoya:
            XiaoyaSettingsTab().scrollContentBackground(.hidden)
        case .mcp:
            MCPSettingsTab(viewModel: viewModel).scrollContentBackground(.hidden)
        case .memory:
            MemoryPage().scrollContentBackground(.hidden)
        case .regex:
            RegexPage().scrollContentBackground(.hidden)
        case .fileLibrary:
            macScroll { FileLibrarySettingsTab() }
        case .debug:
            DebugPage().scrollContentBackground(.hidden)
        case .about:
            MacAboutPage().scrollContentBackground(.hidden)
        case .sandbox, .theme:
            // 沙箱只有 iOS（macOS 的 run_command 跑在真机器上）；主题库在 A1 后是外观页的二级页，不再是 tab。
            // 枚举 case 两端共用，macOS 这边穷举补空分支，不露 UI（macTabs 已滤掉，走不到）
            EmptyView()
        }
    }

    private func macScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content() }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
        }
    }
    #endif

    // MARK: - Settings Row Helper (iOS)

    #if os(iOS)
    /// 搜索结果跳转：先展开目标所在折叠组（否则返回根列表按钮「消失」），再赋值 push。
    /// 面板收起与 push 同帧会打架，延一拍（rootshell :1300-1306 同款做法）。
    private func jumpToSearchResult(_ entry: SettingsSearchEntry) {
        // 卡库设置页签的行：关设置，交给 ContentView 打开卡库（⑥）
        if entry.opensCardLibrarySettings, let rightPanelNavigator {
            rightPanelNavigator.pendingTarget = .init(tool: "cardLibrary", id: RightPanelNavigator.cardLibrarySettingsTargetId)
            dismiss()
            return
        }
        guard let tab = entry.tab else { return }
        SettingsSearchEntry.expandFoldGroup(for: tab)
        // 锚点得赶在 push 之前投进信箱——页面 onAppear 一上来就取
        SettingsSearchRouter.shared.request(anchor: entry.anchor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            selectedSettingsTab = tab
        }
    }

    /// 占位行：还没做的功能入口。灰掉、点不动、右侧「敬请期待」。
    private func placeholderRow(icon: String, title: String, guide: SettingsFoldGuide? = nil) -> some View {
        HStack(spacing: 12) {
            AppIconView(name: icon, size: 16, tint: Theme.textMuted.opacity(0.5))
                .frame(width: 28)
                .foldGuide(guide)
            Text(title)
                .font(.system(size: 16))
                .foregroundColor(Theme.textMuted)
            Spacer()
            Text("敬请期待")
                .font(.system(size: 13))
                .foregroundColor(Theme.textMuted.opacity(0.5))
        }
        .listRowBackground(Theme.mainBg)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    }

    /// 版本行：不可点，只显示版本与 build（构建时间在「关于记忆花园」页里）。
    private func versionRow() -> some View {
        HStack(spacing: 12) {
            AppIconView(name: "info.circle", size: 16, tint: Theme.textMuted.opacity(0.5))
                .frame(width: 28)
            Text("版本")
                .font(.system(size: 16))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            Text("\(version) (\(build))")
                .font(.system(size: 13))
                .foregroundColor(Theme.textMuted)
                .textSelection(.enabled)
        }
        .listRowBackground(Theme.mainBg)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    }

    /// 语言：跳系统设置里本 app 那页（App 级语言只能在那改）。10-02 从外观页挪到根列表一级（粟粟）
    private func languageRow() -> some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 12) {
                AppIconView(name: "globe", size: 16, tint: Theme.textSecondary)
                    .frame(width: 28)
                Text("语言")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(currentLanguageName)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textMuted)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
            }
        }
        .listRowBackground(Theme.mainBg)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    }

    private var currentLanguageName: String {
        let code = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first ?? "zh-Hans"
        return Locale(identifier: "zh-Hans").localizedString(forIdentifier: code) ?? code
    }

    private func settingsButton(icon: String, title: String, color: Color, tab: SettingsTab, guide: SettingsFoldGuide? = nil) -> some View {
        Button {
            selectedSettingsTab = tab
        } label: {
            HStack(spacing: 12) {
                AppIconView(name: icon, size: 16, tint: color)
                    .frame(width: 28)
                    .foldGuide(guide)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
            }
        }
        .listRowBackground(Theme.mainBg)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    }
    #endif
}

// MARK: - Settings Fold Row (iOS)

#if os(iOS)
/// 折叠组引导竖线位置：middle=顶+底段，last=只顶段（收尾），header=只底段（折叠标题行）
private enum SettingsFoldGuide {
    case middle, last, header
}

/// 图标列的引导竖线：每个行间间隙一根独立短胶囊，两端完整露出才是正圆头。
/// 不再用整条长线+色块遮罩（切断面看着像方头）。middle/header 画图标下方的段，last 不画。
private struct SettingsFoldGuideModifier: ViewModifier {
    let guide: SettingsFoldGuide?
    func body(content: Content) -> some View {
        content.background {
            if let guide, guide != .last {
                Capsule()
                    .fill(Theme.branchIndicator.opacity(0.5))
                    .frame(width: 2, height: 14)
                    .offset(y: 23)
            }
        }
    }
}

private extension View {
    func foldGuide(_ guide: SettingsFoldGuide?) -> some View {
        modifier(SettingsFoldGuideModifier(guide: guide))
    }
}

/// 设置根列表的折叠分组行：一级就地展开收起，展开状态逐组持久化。
/// 不用 DisclosureGroup——它的 chevron 在 List 里不吃 .tint()，颜色跟普通行对不上。
/// Button + 自绘 chevron，样式跟 settingsButton 完全一致；内容摊平成多行，不包 VStack。
/// 展开时标题变薄荷绿，图标下方接引导竖线。
private struct SettingsFoldRow<Content: View>: View {
    let icon: String
    let title: String
    @AppStorage private var expanded: Bool
    @ViewBuilder let content: () -> Content

    init(icon: String, title: String, storageKey: String, @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon
        self.title = title
        self._expanded = AppStorage(wrappedValue: false, storageKey)
        self.content = content
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 28)
                    .foldGuide(expanded ? .header : nil)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(expanded ? Theme.branchIndicator : Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .listRowBackground(Theme.mainBg)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        if expanded {
            content()
        }
    }
}
#endif

// MARK: - Settings Search Bar + Keyboard Dismiss (iOS)

#if os(iOS)
/// 「点外面收键盘」安装器：往 window 挂一个 cancelsTouchesInView=false 的 UITapGestureRecognizer。
/// 不拦截任何触摸（行点击照走，不会像 simultaneousGesture 那样打架）；
/// 命中测试点到输入框/文本框时跳过，避免刚聚焦就被收。
private struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
            tap.cancelsTouchesInView = false
            window.addGestureRecognizer(tap)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let window = recognizer.view else { return }
            let hit = window.hitTest(recognizer.location(in: window), with: nil)
            var node = hit
            while let cur = node {
                if cur is UITextField || cur is UITextView { return }
                node = cur.superview
            }
            window.endEditing(true)   // 无第一响应者时是 no-op
        }
    }
}

/// 底部玻璃搜索框（仿 iOS 26 设置页）：放大镜 + 输入框 + ？按钮。
/// 玻璃质感照 iOS 工具条那套 `.glassEffect(.regular.tint(white 0.06), in: .capsule)`。
/// 像素对齐苹果：左右边距 28pt、高约 47pt。
/// 收起态：这颗胶囊本身不收输入——点它弹 `SettingsSearchPanel`（展开态在那里输入）。
private struct SettingsSearchBar: View {
    var onActivate: () -> Void = {}
    var onHelp: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(Theme.textMuted)
            // 原来这里是 TextField("搜索")；改成同色同字号的占位文字，视觉一致但点击落到整颗胶囊上
            Text("搜索")
                .font(.system(size: 16))
                .foregroundColor(Color(uiColor: .placeholderText))
            Spacer(minLength: 0)
            Button(action: onHelp) {
                Image(systemName: "questionmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular.tint(Color.white.opacity(0.06)), in: .capsule)
        // 整颗胶囊可点（「？」是子 Button，手势优先级比父 onTapGesture 高，不会被这条吃掉）
        .contentShape(Capsule())
        .onTapGesture { onActivate() }
        .padding(.horizontal, 28)
        .padding(.bottom, 4)
    }
}
#endif

// MARK: - Settings Text Field

struct SettingsTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false   // 凭证类输入用 SecureField（P1-20）
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        HStack(spacing: 12) {
            // 标签：iOS 15 regular 不变；mac 13 regular → 13 medium（刀 0.5b ⧫3，与已合页的 label 档一致）
            Text(label)
                .font(m.label)
                .foregroundColor(Theme.textSecondary)
                #if os(iOS)
                .frame(width: 90, alignment: .leading)
                #else
                .frame(width: 72, alignment: .leading)
                #endif
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(m.body)
            .padding(.horizontal, 10)
            .padding(.vertical, Theme.optionRowVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.mainBg.opacity(0.8))
            )
        }
    }
}

extension Notification.Name {
    /// 设置页内跳到另一个 tab（mac 侧栏选中它）。object = `SettingsView.SettingsTab.rawValue`
    static let settingsOpenTab = Notification.Name("mpSettingsOpenTab")
}
