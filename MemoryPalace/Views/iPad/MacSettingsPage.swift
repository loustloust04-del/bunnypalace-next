#if os(macOS)
import SwiftUI
import AppKit

struct MacSettingsWindowStyle: NSViewRepresentable {
    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.toolbarStyle = .unified
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible   // 页名走 unified toolbar 的标题（Tahoe 系统设置同款，紧挨 ‹ ›）；标题栏仍透明，不出白带
            window.titlebarSeparatorStyle = .none
        }
    }

    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ nsView: WindowView, context: Context) {
        nsView.configureWindow()
    }
}

/// mac 设置 detail 里的二级页：`SettingsRoute`（两端可见，`Views/Settings/SettingsRoute.swift`）在 mac 走值驱动 path，
/// 好让页顶 ‹ › 能回退 / 前进（destination 式 NavigationLink 不进 path，回不去）。
/// 系统工具栏已藏（标题栏透明 + 无标题），系统返回键没地方画，所以二级导航自己管。
extension SettingsRoute {
    var title: String {
        switch self {
        case .healthPermissions: "健康"
        case .memoryExtractPrompt: "提取提示词"
        case .dreamPrompt: "画像生成提示词"
        case .themeLibrary: "主题库"
        case .themeColors: "主题颜色"
        case .chatBackground: "聊天背景"
        case .appearanceFont: "字体"
        case .appearanceWaiting: "等待动画"
        case .appearanceAdvanced: "高级外观"
        case .highlightColors: "划线颜色"
        case .wideLayout: "宽屏布局"
        case .acknowledgements: "开源致谢"
        case .voiceServices: "语音服务"
        case .importRecordDetail: "导入详情"
        }
    }

    @ViewBuilder var macDestination: some View {
        switch self {
        case .healthPermissions: MacHealthPermissionPage()
        case .memoryExtractPrompt:
            PromptEditorPage.memoryExtract
        case .dreamPrompt:
            PromptEditorPage.dream
        case .themeLibrary: ThemeLibraryPage()
        case .themeColors: ThemeColorsPage()
        case .chatBackground: ChatBackgroundPage()
        case .appearanceFont: FontPickerPage()
        case .appearanceWaiting: WaitingAnimationPage()
        case .appearanceAdvanced: AdvancedAppearancePage()
        case .highlightColors: HighlightColorsPage()
        case .wideLayout: WideLayoutPage()
        case .acknowledgements: MacAcknowledgementsPage()
        case .voiceServices: VoiceServicesPage()
        case .importRecordDetail: MacImportRecordDetailRoute()
        }
    }
}

struct MacSettingsPage<Content: View>: View {
    let tab: SettingsView.SettingsTab
    @ViewBuilder var content: Content
    @State private var path: [SettingsRoute] = []
    @State private var forward: [SettingsRoute] = []

    /// 页顶 ‹ ›：Tahoe 系统设置同款，做成真 toolbar item（两颗一组，Tahoe 自动给玻璃胶囊；回退 / 前进各自禁用态）。
    /// 之前自画在内容区顶 52pt——那一段在透明标题栏 / toolbar 条底下，AppKit 的标题栏视图叠在内容上把点击当拖窗吃掉，怎么点都不响应。
    /// 根页和每个二级页各挂一份：推入的页接管整个 detail 列的 toolbar。
    @ToolbarContentBuilder
    private var navToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { navCapsule }
                .sharedBackgroundVisibility(.hidden)   // Tahoe 给 toolbar item 的那层淡玻璃藏掉，只留我们自己的
        } else {
            ToolbarItem(placement: .navigation) { navCapsule }
        }
    }

    /// 我们的玻璃胶囊：配方同 iOS `GlassBackButton`（15 semibold 次级色 chevron）+ 壳的 `shellGlass` 0.15 可交互（macOS 15 退材质 + 描边）
    private var navCapsule: some View {
        HStack(spacing: 0) {
            navButton("chevron.left", enabled: !path.isEmpty) {
                forward.append(path.removeLast())
            }
            navButton("chevron.right", enabled: !forward.isEmpty) {
                path.append(forward.removeLast())
            }
        }
        .shellGlass(in: Capsule(), tint: 0.15, interactive: true)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                MacSettingsCard {
                    HStack(alignment: .top, spacing: 12) {
                        if let icon = SettingsSearchEntry.iconByTab[tab] {
                            AppIconView(name: icon, size: ShellStyle.iconSize, tint: ShellStyle.windowBackground)
                                .frame(width: 30, height: 30)
                                .background(Theme.branchIndicator, in: RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tab.rawValue).font(ShellStyle.bodyFont.weight(.regular))
                            Text(tab.macSubtitle)
                                .font(ShellStyle.secondaryFont)
                                .foregroundStyle(ShellStyle.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .center)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .toolbar { navToolbar }
            .navigationDestination(for: SettingsRoute.self) { route in
                route.macDestination
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .navigationTitle(route.title)   // toolbar 标题跟着二级页走，不然退回系统默认「记忆花园 Settings」
                    // 系统自己那颗单向返回钮藏掉，换上面的 ‹ › 组；工具栏底不铺（侧栏通顶）；顶部安全区留着，内容从 toolbar 下面开始
                    .navigationBarBackButtonHidden(true)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                    .toolbar { navToolbar }
            }
        }
        // 整个设置 NavigationStack 作用域（含推入的二级页）都是 route 宿主：`SettingsNavRow` 走值驱动 link
        .environment(\.settingsRouteHost, true)
        .font(ShellStyle.bodyFont.weight(.regular))
        .foregroundStyle(ShellStyle.text)
        .tint(Theme.branchIndicator)
        .toggleStyle(MacSettingsToggleStyle())
        .controlSize(.regular)
        .background(ShellStyle.windowBackground)
        .background(MacScrollbars().id(tab.rawValue + "/" + path.map(\.rawValue).joined(separator: "/")))
        .onChange(of: tab) {
            path.removeAll()
            forward.removeAll()
        }
        #if DEBUG
        // 自测钩子：`--mp-settings-route=<SettingsRoute.rawValue>` 启动即推二级页（配合 `--mp-open-settings=<tab>`）
        .onAppear {
            guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--mp-settings-route=") }),
                  let route = SettingsRoute(rawValue: String(argument.dropFirst("--mp-settings-route=".count))) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { path = [route] }
        }
        #endif
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 34, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// 权限 › 健康 的 mac 二级页：同一批 `PermissionDomainRow`，套 MacSettingsForm 组卡（iOS 那份 `HealthPermissionSubpage` 不动）
struct MacHealthPermissionPage: View {
    var body: some View {
        MacSettingsForm {
            Section {
                PermissionDomainRow(domain: .healthApple)
                PermissionDomainRow(domain: .healthWeight)
                PermissionDomainRow(domain: .healthMeds)
                PermissionDomainRow(domain: .healthCycle)
                PermissionDomainRow(domain: .healthIntimacy)
            } footer: {
                Text("与 设置→健康 里的开关是同一个值，两边改都一样。")
            }
        }
    }
}

struct MacSettingsSlider: View {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let step: Double

    init(value: Binding<Double>, in bounds: ClosedRange<Double>, step: Double) {
        self._value = value
        self.bounds = bounds
        self.step = step
    }

    var body: some View {
        Slider(value: Binding(
            get: { value },
            set: { raw in
                let snapped = bounds.lowerBound + ((raw - bounds.lowerBound) / step).rounded() * step
                value = min(max(snapped, bounds.lowerBound), bounds.upperBound)
            }
        ), in: bounds)
    }
}

struct MacSettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            Toggle(configuration)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.branchIndicator)
                .fixedSize()
        }
    }
}

struct MacSettingsButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MacShellButton(compact: true).makeBody(configuration: configuration)
            .background(ShellStyle.hover, in: RoundedRectangle(cornerRadius: ShellStyle.chipRadius))
    }
}

// 卡 / 组头 / 脚注的字号与间距统一读 `settingsMetrics`（唯一数值源；mac 五档可用 defaults 覆写）
struct MacSettingsCard<Content: View>: View {
    @Environment(\.settingsMetrics) private var m
    /// 设置页被搬进右栏（正则 / Prompt 等工具）时：跟右栏分组卡一个画法（奶白大圆角），设置窗里照旧淡灰卡
    @Environment(\.inGlassChrome) private var inGlassChrome
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { rows in
            VStack(alignment: .leading, spacing: m.rowSpacing) {
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle().fill(ShellStyle.hairline).frame(height: ShellStyle.hairlineWidth)
                    }
                    row.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(m.cardPadding)
            .background(inGlassChrome ? Theme.mainBg : ShellStyle.hover,
                        in: RoundedRectangle(cornerRadius: inGlassChrome ? 18 : m.cardCorner, style: .continuous))

    }
}

struct MacSettingsSection<Content: View>: View {
    @Environment(\.settingsMetrics) private var m
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(m.sectionHeader).foregroundStyle(m.sectionHeaderColor)
            MacSettingsCard { content }
        }
    }
}

// Section 内容仍由业务页持有；这里只负责组卡和独立滚动。
struct MacSettingsForm<Content: View>: View {
    @Environment(\.settingsMetrics) private var m
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(sections: content) { section in
                    VStack(alignment: .leading, spacing: 7) {
                        if !section.header.isEmpty {
                            HStack { section.header }
                                .font(m.sectionHeader)
                                .foregroundStyle(m.sectionHeaderColor)
                        }
                        // 只有 footer 的空 Section（单词页底部 build 戳）不画空卡
                        if !section.content.isEmpty {
                            MacSettingsCard {
                                ForEach(section.content) { row in
                                    row.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        if !section.footer.isEmpty {
                            // 脚注 = caption 档（合流后 mac 10pt，原 11）
                            VStack(alignment: .leading, spacing: 4) { section.footer }
                                .font(m.caption)
                                .foregroundStyle(ShellStyle.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }
}

struct MacSettingsSidebarGroup: Identifiable {
    let title: String
    let tabs: [SettingsView.SettingsTab]
    var id: String { title }

    static let all: [Self] = [
        // A1：mac 删「主题」tab，主题库成外观页二级（`SettingsRoute.themeLibrary`）
        .init(title: "基础", tabs: [.general, .macWorkspace, .appearance, .permissions]),
        .init(title: "AI 与对话", tabs: [.api, .usage, .persona, .xiaoya, .memory, .tts, .mcp, .regex, .worldBook]),
        .init(title: "编程工具", tabs: [.myComputer, .claudeCode, .codex, .agent]),
        .init(title: "模块", tabs: moduleTabs),
        .init(title: "文件与数据", tabs: [.attachment, .fileLibrary, .data]),
        .init(title: "其他", tabs: [.config, .manual, .debug, .about]),
    ]

    #if PERSONAL_APPS
    private static let moduleTabs: [SettingsView.SettingsTab] = [.rightPanel, .sticker, .health, .calendar, .trading, .reading, .vocab, .groupChat]
    #else
    private static let moduleTabs: [SettingsView.SettingsTab] = [.rightPanel, .sticker, .health, .calendar, .reading, .vocab, .groupChat]
    #endif
}

extension SettingsView.SettingsTab {
    var macSubtitle: String {
        switch self {
        case .general: "管理楼层与消息标签。"
        case .macWorkspace: "管理 Dock 图标、分组、面板布局与编程会话入口。"
        case .appearance: "调整主题、文字、聊天显示与气泡。"
        case .theme: "选择主题、配色与聊天背景。"
        case .permissions: "管理 AI 访问范围、自动行为与系统授权。"
        case .api: "管理 API Keys、模型、联网搜索与预算。"
        case .usage: "查看各模型、各卡片的调用次数、Token 与花费。"
        case .persona: "编辑预设、提示词插槽与请求参数。"
        case .xiaoya: "小芽助手的人设。"
        case .memory: "管理记忆提取、注入策略与记忆条目。"
        case .tts: "设置系统朗读、语速与语音消息。"
        case .mcp: "连接与管理 MCP 工具服务。"
        case .regex: "管理消息处理与显示用的正则规则。"
        case .claudeCode: "配置 Claude Code 连接与会话行为。"
        case .codex: "查看 Codex 桥连接与会话使用说明。"
        case .myComputer: "启动 hub、配对手机，设置 Agent 干活的目录。"
        case .agent: "管理 Agent、定时任务与自动行为。"
        case .rightPanel: "选择右栏工具与面板内容。"
        case .sticker: "管理贴纸来源、图库与触发选项。"
        case .health: "设置健康数据访问与记录权限。"
        case .calendar: "设置月历样子、日记与纪念日给不给 AI 看。"
        #if PERSONAL_APPS
        case .trading: "设置交易数据访问与研究权限。"
        #endif
        case .reading: "选择自主读书与共读使用的模型。"
        case .vocab: "设置出词顺序、复习与提问模板。"
        case .groupChat: "设置群聊开关、发言模式与节奏。"
        case .attachment: "设置图片发送数量与图片转述。"
        case .fileLibrary: "管理文件存储、同步与清理。"
        case .data: "导入、导出、同步与备份数据。"
        case .config: "导入与导出应用配置。"
        case .manual: "查看应用功能说明与使用文档。"
        case .debug: "查看诊断信息、反馈与调试工具。"
        case .worldBook: "查看与管理当前楼层绑定的世界书。"
        case .sandbox, .terminal: ""
        case .about: "版本信息与开源致谢。"
        }
    }
}
#endif
