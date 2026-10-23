import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

// MARK: - Appearance Pages

/// 外观总览页：主题 / 窗口（mac）/ 文本 / 聊天样式 / 消息显示 / 动效 / 对话列表（iOS）/ 音乐（iOS）/ 宽屏布局（iPad 二级）/ 高级外观（二级）。
/// 10-02 重整（`docs/prompts/2026-10-02-appearance-ia/r1-ia-rulings.md`）：语言挪设置根一级，群聊颜色挪 设置 › 群聊，
/// 流式输出挪 设置 › API，mac 的面板四项挪 Mac 工作区，正文栏宽度挪 高级外观 › 排版（只 iPad）。
///
/// 一份 body 两端共用（plan-settings-merge-x 刀 3 · A1）：容器走 `SettingsSectionList(.list)`，字号走
/// `settingsMetrics`，二级页（字体 / 划线颜色 / 等待动画 / 宽屏布局 / 高级外观 / 主题库…）走 `SettingsNavRow` + `SettingsRoute`。
struct AppearancePage: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(\.settingsMetrics) private var m
    /// 昵称 / 时间戳两个开关在文章模式也生效（`CardFlowView.articleModeBody`）：mac 沿 J2 常驻；iOS 保持基线只在气泡模式露出（改它是 iOS 可见变化，待她批）——R6c I4
    private var showNameTimeToggles: Bool {
        #if os(macOS)
        true
        #else
        chatBubbleMode
        #endif
    }
    @AppStorage("selectedFont") private var selectedFont = ""
    @AppStorage("fontScale") private var fontScale = 1.2
    #if os(macOS)
    @Bindable private var glass = MacGlass.shared
    #endif
    @AppStorage("hideTimestamp") private var hideTimestamp: Bool = false
    @AppStorage("hideRoleName") private var hideRoleName: Bool = false
    @AppStorage("hideActionBar") private var hideActionBar: Bool = false
    @AppStorage("showFlagBlocks") private var showFlagBlocks: Bool = true
    @AppStorage("showMessageUsage") private var showMessageUsage: Bool = true
    @AppStorage("chatBubbleMode") private var chatBubbleMode = false
    /// page0 对话列表样式（和列表 ≡ 筛选面板里那组是同一个 key）
    @AppStorage("page0ListStyle") private var page0ListStyle = "compact"
    @AppStorage("page0LiquidMetal") private var page0LiquidMetal = true
    @AppStorage("page0MetalFlowers") private var page0MetalFlowers = true
    @AppStorage("showAvatar") private var showAvatar = true
    @AppStorage("gardenSceneEnabled") private var gardenSceneEnabled = true
    @AppStorage("globalMusicCapsuleEnabled") private var globalMusicCapsuleEnabled = true
    @AppStorage(OrbState.storageKey) private var orbStyleRaw = OrbState.working.rawValue

    @State private var importedFonts: [(fileName: String, fontName: String)] = []

    private var manager: ThemeManager {
        themeManager ?? ThemeManager.shared
    }

    private var currentFontDisplayName: String {
        if selectedFont.isEmpty { return "系统默认" }
        if let preset = FontManager.presetFonts.first(where: { $0.name == selectedFont }) {
            return preset.displayName
        }
        return importedFonts.first(where: { $0.fontName == selectedFont })?.fileName ?? "系统默认"
    }

    private var orbDisplayName: String {
        orbStyleRaw == OrbState.legacyDotsRaw ? "三个点" : OrbState.stored(orbStyleRaw).displayName
    }

    /// 高级外观入口的副标题：照二级页实际装的东西写（iPad 多一行正文栏宽度）
    private var advancedSubtitle: String {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad { return "气泡圆角、内边距、间距、行距、正文栏宽度、边缘模糊" }
        #endif
        return "气泡圆角、内边距、间距、行距、边缘模糊"
    }

    var body: some View {
        let _ = manager.themeChangeID

        // 搜索锚点：命中叶子条目时滚到那一行
        return ScrollViewReader { anchorProxy in
        SettingsSectionList(.list) {
            // 主题：显示模式三卡 + 三个二级入口（主题库 / 主题颜色 / 聊天背景），右侧就是当前状态摘要
            // （plan-theme-decouple M3.1，学 rootshell #1：不点进去就知道现在是什么）
            Section("主题") {
                ThemeModeCardPicker()

                SettingsNavRow(.themeLibrary) {
                    ThemeLibraryPage()
                } label: {
                    HStack(spacing: 8) {
                        Text("主题库")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        ThemeChatPreview(
                            tokenSet: manager.currentTokenSet,
                            scheme: manager.activeScheme,
                            backgroundImageURL: manager.currentBackgroundImageURL,
                            backgroundStyle: manager.currentBackgroundStyle,
                            size: .row
                        )
                        Text(manager.selectedTheme.name)
                            .font(m.secondary)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .searchAnchor("leaf-appear-theme")

                SettingsNavRow(.themeColors) {
                    ThemeColorsPage()
                } label: {
                    HStack(spacing: 8) {
                        Text("主题颜色")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        ThemePalettePreview(colors: manager.currentTokenSet.previewColors)
                    }
                }
                .searchAnchor("leaf-appear-colors")

                SettingsNavRow(.chatBackground) {
                    ChatBackgroundPage()
                } label: {
                    HStack(spacing: 8) {
                        Text("聊天背景")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        if let url = manager.currentBackgroundImageURL {
                            ThemeBackgroundView(
                                fill: Theme.mainBg,
                                imageURL: url,
                                scheme: manager.activeScheme,
                                backgroundStyle: manager.currentBackgroundStyle
                            )
                            .frame(width: 44, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text("\(Int((manager.currentBackgroundStyle.resolvedOpacity(for: manager.activeScheme) * 100).rounded()))%")
                                .font(m.secondary)
                                .foregroundColor(Theme.textMuted)
                        } else {
                            Text("无背景图")
                                .font(m.secondary)
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                }
                .searchAnchor("leaf-appear-chatbg")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            #if os(macOS)
            // 窗口玻璃（plan-mac-glass-chrome §1.6）：边栏 / 工具面板 / 标题栏透出桌面，正文卡保持实底
            Section("窗口") {
                Toggle(isOn: $glass.enabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("窗口玻璃")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Text("边栏、工具面板和标题栏透出桌面。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .tint(Theme.branchIndicator)
                .searchAnchor("leaf-appear-window")

                if glass.enabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("玻璃色偏")
                                .font(m.body)
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text("\(Int((glass.tint * 100).rounded()))%")
                                .font(m.secondary)
                                .foregroundColor(Theme.textMuted)
                                .monospacedDigit()
                        }
                        Slider(value: $glass.tint, in: 0...0.6, step: 0.05)
                            .tint(Theme.branchIndicator)
                        Text("越高越接近实底，字越好认。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
            #endif

            // 文本：字体（二级）+ 字号 + 划线颜色（二级）
            Section("文本") {
                SettingsNavRow(.appearanceFont) {
                    FontPickerPage()
                } label: {
                    HStack {
                        Text("字体")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Text(currentFontDisplayName)
                            .font(selectedFont.isEmpty
                                  ? m.secondary
                                  : .custom(selectedFont, size: m.secondarySize))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .searchAnchor("leaf-appear-font")

                VStack(spacing: 8) {
                    HStack {
                        Text("聊天字号")
                            .font(m.label)
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Text("\(Int(fontScale * 100))%")
                            .font(m.secondary.weight(.medium))
                            .foregroundColor(Theme.branchIndicator)
                    }

                    HStack(spacing: 12) {
                        Button(action: { fontScale = max(0.5, fontScale - 0.1) }) {
                            Image(systemName: "textformat.size.smaller")
                                .font(m.label)
                                .foregroundColor(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)

                        Slider(value: $fontScale, in: 0.5...2.0, step: 0.05)
                            .tint(Theme.branchIndicator)

                        Button(action: { fontScale = min(2.0, fontScale + 0.1) }) {
                            Image(systemName: "textformat.size.larger")
                                .font(m.label)
                                .foregroundColor(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }

                    if fontScale != 1.2 {
                        Button(action: { fontScale = 1.2 }) {
                            Text("重置默认")
                                .font(m.secondary)
                                .foregroundColor(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    // ⌘ 快捷键提示：iOS 无菜单快捷键，mac 保留 J2 原样一行（第 2 类）
                    #if os(macOS)
                    HStack(spacing: 4) {
                        Spacer()
                        Text("⌘+ 放大  ⌘- 缩小  ⌘0 重置")
                            .font(m.secondary)
                            .foregroundColor(Theme.textMuted.opacity(0.7))
                    }
                    #endif
                }
                .searchAnchor("leaf-appear-text")

                SettingsNavRow(.highlightColors) {
                    HighlightColorsPage()
                } label: {
                    HStack(spacing: 8) {
                        Text("划线颜色")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(HighlightPalette.defaults.prefix(4), id: \.hex) { c in
                                Circle().fill(HighlightPalette.color(c.hex)).frame(width: 12, height: 12)
                            }
                        }
                    }
                }
                .searchAnchor("leaf-appear-highlight")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // 聊天样式：版式 + 气泡周边信息 + 新对话开场
            Section("聊天样式") {
                Picker("显示方式", selection: $chatBubbleMode) {
                    Text("文章").tag(false)
                    Text("气泡").tag(true)
                }
                .pickerStyle(.segmented)
                .searchAnchor("leaf-appear-bubblemode")

                if chatBubbleMode {
                    Toggle("显示头像", isOn: $showAvatar)
                        .font(m.body)
                        .tint(Theme.branchIndicator)
                        .searchAnchor("leaf-appear-avatar")
                }
                if showNameTimeToggles {
                    Toggle("显示昵称", isOn: Binding(
                        get: { !hideRoleName }, set: { hideRoleName = !$0 }))
                        .font(m.body)
                        .tint(Theme.branchIndicator)
                        .searchAnchor("leaf-appear-nickname")
                    Toggle("显示时间戳", isOn: Binding(
                        get: { !hideTimestamp }, set: { hideTimestamp = !$0 }))
                        .font(m.body)
                        .tint(Theme.branchIndicator)
                        .searchAnchor("leaf-appear-timestamp")
                }

                Toggle(isOn: $gardenSceneEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("花园背景")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Text("新对话界面用本层记忆长成的花 + 星空开场；关掉则是空白页。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .tint(Theme.branchIndicator)
                .searchAnchor("leaf-appear-opening")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // 消息显示：正文里的折叠块怎么显示 + 还显示哪些辅助信息
            Section("消息显示") {
                DisclosureModeRow(kind: .thinking, fontSize: m.bodySize, valueSize: m.secondarySize)
                    .searchAnchor("leaf-appear-foldblocks")
                DisclosureModeRow(kind: .recall, fontSize: m.bodySize, valueSize: m.secondarySize)
                DisclosureModeRow(kind: .tool, fontSize: m.bodySize, valueSize: m.secondarySize)

                Toggle(isOn: $showFlagBlocks) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示安全提示卡")
                            .font(m.body)
                        Text("Claude 在对话里插入的 ⚠️ flag（如 self_harm_risk + 热线）")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .searchAnchor("leaf-appear-msgdisplay")

                Toggle(isOn: $showMessageUsage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示消息用量")
                            .font(m.body)
                        Text("AI 气泡右下角的 token 数 / 缓存命中 / 费用小字")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }

                Toggle(isOn: Binding(
                    get: { !hideActionBar }, set: { hideActionBar = !$0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示消息操作按钮")
                            .font(m.body)
                        Text("消息下方的复制 / 收藏等按钮行")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // 动效
            Section("动效") {
                SettingsNavRow(.appearanceWaiting) {
                    WaitingAnimationPage()
                } label: {
                    HStack(spacing: 8) {
                        Text("等待动画")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        if orbStyleRaw == OrbState.legacyDotsRaw {
                            BouncingDotsView()
                                .frame(width: 22, height: 22)
                        } else {
                            ThinkingOrb(state: OrbState.stored(orbStyleRaw), size: .px20, theme: .dark, displaySize: 22)
                                .colorMultiply(Theme.textPrimary)
                        }
                        Text(orbDisplayName)
                            .font(m.secondary)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .searchAnchor("leaf-appear-thinkingorb")

                LiquidMetalRingToggle(fontSize: m.bodySize)
                    .searchAnchor("leaf-appear-ring")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            #if os(iOS)
            // 对话列表（page0）
            Section("对话列表") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("列表样式", selection: $page0ListStyle) {
                        Text("紧凑").tag("compact")
                        Text("详细").tag("detailed")
                        Text("纯净").tag("pure")
                    }
                    .pickerStyle(.segmented)
                    Text("紧凑：标题+图标+时间。详细：多一行预览和未读条数。纯净：只有标题。")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .searchAnchor("leaf-appear-liststyle")

                Toggle(isOn: $page0LiquidMetal) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("液态金属背景")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Text("列表外面那片底换成缓慢流动的铬面，只在列表页露出来时动。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .tint(Theme.branchIndicator)
                .searchAnchor("leaf-appear-livebg")

                Toggle(isOn: $page0MetalFlowers) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("底部白色小花")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Text("长在液态金属底边，要先开液态金属。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .tint(Theme.branchIndicator)
                .disabled(!page0LiquidMetal)
                .searchAnchor("leaf-appear-metalflowers")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
            #endif

            #if os(iOS)
            Section("音乐") {
                Toggle(isOn: $globalMusicCapsuleEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("全局音乐胶囊")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Text("放歌时，聊天页以外的页面顶上挂一个音乐胶囊，点一下回到那首歌的对话。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .tint(Theme.branchIndicator)
                .searchAnchor("leaf-appear-music")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
            #endif

            // 宽屏布局（iPad 二级）+ 高级外观（二级）
            Section {
                #if os(iOS)
                // 面板模式 / 吸边 / 桌面排版 / dock 只在 iPad 横屏有那个形态，手机不露这一行；mac 的在 Mac 工作区
                if UIDevice.current.userInterfaceIdiom == .pad {
                    SettingsNavRow(.wideLayout) {
                        WideLayoutPage()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("宽屏布局")
                                .font(m.body)
                                .foregroundColor(Theme.textPrimary)
                            Text("面板模式、浮窗吸边、桌面排版、dock")
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    .searchAnchor("leaf-appear-widelayout")
                }
                #endif

                SettingsNavRow(.appearanceAdvanced) {
                    AdvancedAppearancePage()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("高级外观")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Text(advancedSubtitle)
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .settingsAnchorScroll(anchorProxy)
        .onAppear {
            importedFonts = FontManager.importedFonts()
        }
        }
    }
}

/// 字体选择（外观页二级）：preset 列表 + 已导入字体 + 导入文件。
struct FontPickerPage: View {
    @Environment(\.settingsMetrics) private var m
    @AppStorage("selectedFont") private var selectedFont = ""
    @State private var importedFonts: [(fileName: String, fontName: String)] = []
    @State private var showFontImporter = false
    /// D8：删导入字体只置 pending，确认分支才真删（按字体 ID = `fontName`），取消零写入
    @State private var pendingDeleteFont: (fileName: String, fontName: String)?

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                VStack(spacing: Theme.optionRowSpacing) {
                    ForEach(FontManager.presetFonts, id: \.name) { preset in
                        FontOptionRow(
                            displayName: preset.displayName,
                            fontName: preset.name,
                            isSelected: selectedFont == preset.name,
                            previewFont: preset.name.isEmpty ? .system(size: m.bodySize) : .custom(preset.name, size: m.bodySize)
                        ) {
                            selectedFont = preset.name
                        }
                    }

                    if !importedFonts.isEmpty {
                        Divider().opacity(0.1).padding(.vertical, 2)
                        ForEach(importedFonts, id: \.fontName) { font in
                            FontOptionRow(
                                displayName: font.fileName,
                                fontName: font.fontName,
                                isSelected: selectedFont == font.fontName,
                                previewFont: .custom(font.fontName, size: m.bodySize),
                                onDelete: { pendingDeleteFont = font }
                            ) {
                                selectedFont = font.fontName
                            }
                        }
                    }

                    Button(action: { showFontImporter = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                                .font(m.secondary)
                            Text("导入字体文件...")
                                .font(m.secondary)
                            Spacer()
                        }
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 10)
                        .padding(.vertical, Theme.optionRowVerticalPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("字体")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            importedFonts = FontManager.importedFonts()
        }
        // D8（G10）：删导入字体加二次确认；pending 存字体 ID，确认分支按 ID 在最新列表里重找再删，取消零写入
        .confirmationDialog(
            "删除字体？",
            isPresented: Binding(
                get: { pendingDeleteFont != nil },
                set: { if !$0 { pendingDeleteFont = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = pendingDeleteFont,
                   FontManager.importedFonts().contains(where: { $0.fontName == target.fontName }) {
                    FontManager.deleteFont(named: target.fontName)
                    if selectedFont == target.fontName { selectedFont = "" }
                    importedFonts = FontManager.importedFonts()
                }
                pendingDeleteFont = nil
            }
            Button("取消", role: .cancel) { pendingDeleteFont = nil }
        }
        .fileImporter(
            isPresented: $showFontImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "ttf") ?? .data,
                UTType(filenameExtension: "otf") ?? .data,
                UTType(filenameExtension: "ttc") ?? .data,
            ],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let name = FontManager.importFont(from: url) {
                        selectedFont = name
                    }
                }
                importedFonts = FontManager.importedFonts()
            }
        }
    }
}

/// 等待动画选择（外观页二级）：思考球 9+1 宫格 + 轮换文案包。
struct WaitingAnimationPage: View {
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                ThinkingOrbStylePicker()
            } header: {
                Text("等待回复的思考球")
            } footer: {
                Text("等待 AI 回复时显示的小动画，点选即生效。")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("等待回复的文案") {
                ThinkingPhrasePackPicker(fontSize: m.secondarySize)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("等待动画")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 宽屏布局（外观页二级，只 iPad 有入口）：面板模式 / 吸边 / 桌面排版 / dock。mac 的同一组在 Mac 工作区。
struct WideLayoutPage: View {
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                PanelLayoutSettingsRows(layout: IPadPanelLayout.shared,
                                        labelFont: m.label, captionFont: m.caption)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("宽屏布局")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 高级外观（外观页二级）：低频几何精调 + 排版（iPad 多正文栏宽度）+ 边缘模糊 + 重置。
struct AdvancedAppearancePage: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage("bubbleCornerRadius") private var bubbleCornerRadius: Double = 16
    @AppStorage("bubblePaddingH") private var bubblePaddingH: Double = 18
    @AppStorage("bubblePaddingV") private var bubblePaddingV: Double = 15
    @AppStorage("bubbleSpacing") private var bubbleSpacing: Double = 31
    @AppStorage("lineSpacingScale") private var lineSpacingScale: Double = 1.45
    @AppStorage("paragraphSpacingScale") private var paragraphSpacingScale: Double = 1.65
    @AppStorage("bubbleModeCornerRadius") private var bubbleModeCornerRadius: Double = 23
    @AppStorage("blurRadius") private var blurRadius = 1.3
    // 负向 key：true = 关闭自动半透明。这样 key 缺省（false）= 行为保持原样。
    @AppStorage("disableAutoTransparentBubblesOnWallpaper") private var disableAutoTransparent: Bool = false
    // E6：重置取两端并集（12 项），这三个 hide 在外观主页面（昵称 / 时间戳在聊天样式，操作按钮在消息显示），只在重置里出现
    @AppStorage("hideTimestamp") private var hideTimestamp: Bool = false
    @AppStorage("hideRoleName") private var hideRoleName: Bool = false
    @AppStorage("hideActionBar") private var hideActionBar: Bool = false
    /// 正文栏最大宽度（宽屏才生效）。消费点读 Theme.contentMaxWidth，实时性靠
    /// ContentView 里同 key 的订阅带整棵树重算。
    /// F3：mac 固定 720 不给调，这行不并 → declaration 也包起来，否则 mac 上是个白订阅
    /// （`feedback_appstorage_dead_subscription`：declaration 本身就会订阅）
    #if os(iOS)
    @AppStorage(Theme.contentWidthKey) private var ipadContentWidth: Double = Double(Theme.contentWidthDefault)
    #endif

    var body: some View {
        SettingsSectionList(.list) {
            Section("气泡几何（文章模式）") {
                sliderRow("圆角", value: $bubbleCornerRadius, range: 0...28, step: 1) { "\(Int($0))pt" }
                sliderRow("水平内边距", value: $bubblePaddingH, range: 8...24, step: 1) { "\(Int($0))pt" }
                sliderRow("垂直内边距", value: $bubblePaddingV, range: 4...20, step: 1) { "\(Int($0))pt" }
                sliderRow("气泡间距", value: $bubbleSpacing, range: 8...40, step: 1) { "\(Int($0))pt" }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("气泡几何（气泡模式）") {
                sliderRow("气泡圆角", value: $bubbleModeCornerRadius, range: 14...34, step: 1) { "\(Int($0))pt" }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("排版") {
                sliderRow("行间距", value: $lineSpacingScale, range: 0.5...2.0, step: 0.05) { "\(Int($0 * 100))%" }
                sliderRow("段落间距", value: $paragraphSpacingScale, range: 0.5...2.0, step: 0.05) { "\(Int($0 * 100))%" }
                #if os(iOS)
                // 正文栏宽度只在宽屏看得出（手机竖屏比这个数窄），所以只 iPad 露；不进下面的重置
                if UIDevice.current.userInterfaceIdiom == .pad {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow("正文栏宽度", value: $ipadContentWidth, range: 480...900, step: 20) { "\(Int($0))pt" }
                        Text("宽屏下正文和输入条居中的最大宽度。窄了每行字少、更好读，两侧留给悬浮面板的地方也更大；宽了一行装得下更长的代码。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        if ipadContentWidth != Double(Theme.contentWidthDefault) {
                            Button(action: { ipadContentWidth = Double(Theme.contentWidthDefault) }) {
                                Text("重置默认")
                                    .font(m.secondary)
                                    .foregroundColor(Theme.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                #endif
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // 「壁纸下气泡自动半透明」搬去 外观 › 聊天背景（plan-theme-decouple M3.4）；下面的重置仍会把它归位
            Section("聊天区边缘") {
                sliderRow("边缘模糊", value: $blurRadius, range: 0...6, step: 1) { "\(Int($0))" }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                Button(action: resetPageToDefaults) {
                    HStack {
                        Spacer()
                        // E6 / G7：重置的范围跨了别的页（昵称 / 时间戳在聊天样式，操作按钮在消息显示，壁纸半透明在聊天背景），文案照实说
                        Text("重置气泡几何、行距段距、边缘模糊、壁纸下半透明，以及昵称、时间戳、操作按钮的显示")
                            .font(m.secondary)
                            .foregroundColor(Theme.textMuted)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("高级外观")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formatter: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(m.label)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(formatter(value.wrappedValue))
                    .font(m.secondary.weight(.medium))
                    .foregroundColor(Theme.branchIndicator)
            }
            Slider(value: value, in: range, step: step)
                .tint(Theme.branchIndicator)
        }
    }

    /// E6：两端同一份 12 项并集（交集 6 + 旧 mac 三个 hide + 原 iOS 三项）+ `notifyThemeChange()`。
    /// 不含主题 / 字体 / 语言 / 正文栏宽度。
    private func resetPageToDefaults() {
        bubbleCornerRadius = 16
        bubblePaddingH = 18
        bubblePaddingV = 15
        bubbleSpacing = 31
        lineSpacingScale = 1.45
        paragraphSpacingScale = 1.65
        bubbleModeCornerRadius = 23
        blurRadius = 1.3
        disableAutoTransparent = false
        hideTimestamp = false
        hideRoleName = false
        hideActionBar = false
        themeManager?.notifyThemeChange()
    }
}

// MARK: - Font Option Row

struct FontOptionRow: View {
    @Environment(\.settingsMetrics) private var m
    let displayName: String
    let fontName: String
    let isSelected: Bool
    let previewFont: Font
    var onDelete: (() -> Void)? = nil
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(m.body)
                    .foregroundColor(isSelected ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))
                Text("记忆花园")
                    .font(previewFont)
                    .foregroundColor(Theme.textPrimary)
                Text(displayName)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                Spacer()
                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle")
                            .font(m.secondary)
                            .foregroundColor(Theme.textMuted.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Theme.optionRowVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Theme.accent.opacity(0.4) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
