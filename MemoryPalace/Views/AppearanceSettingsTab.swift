import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

// MARK: - Appearance Pages

/// 外观总览页：主题 / 窗口（mac）/ 文本 / 聊天样式 / 气泡对话 / 文章对话 / 消息显示 / 动效 / 对话列表（iOS）/ 音乐（iOS）/ 宽屏布局（iPad 二级）/ 高级外观（二级）。
/// 10-29 共存第二步：全局「显示方式」删掉（每个对话自己选），只对一种对话生效的设置归到「气泡对话」「文章对话」两块。
/// 10-02 重整（`docs/prompts/2026-10-02-appearance-ia/r1-ia-rulings.md`）：语言挪设置根一级，群聊颜色挪 设置 › 群聊，
/// 流式输出挪 设置 › API，mac 的面板四项挪 Mac 工作区，正文栏宽度挪 高级外观 › 排版（只 iPad）。
///
/// 一份 body 两端共用（plan-settings-merge-x 刀 3 · A1）：容器走 `SettingsSectionList(.list)`，字号走
/// `settingsMetrics`，二级页（字体 / 划线颜色 / 等待动画 / 宽屏布局 / 高级外观 / 主题库…）走 `SettingsNavRow` + `SettingsRoute`。
struct AppearancePage: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(\.settingsMetrics) private var m
    #if os(macOS)
    /// Mac 没人页：聊天主题 / 聊天背景两行绑当前层（atrium P3④a）
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    #endif
    #if os(macOS)
    @Bindable private var glass = MacGlass.shared
    #endif
    @AppStorage("hideTimestamp") private var hideTimestamp: Bool = false
    @AppStorage("hideActionBar") private var hideActionBar: Bool = false
    @AppStorage("showFlagBlocks") private var showFlagBlocks: Bool = true
    @AppStorage("showMessageUsage") private var showMessageUsage: Bool = true
    /// page0 对话列表样式（和列表 ≡ 筛选面板里那组是同一个 key）
    @AppStorage("page0ListStyle") private var page0ListStyle = "compact"
    @AppStorage("page0LiquidMetal") private var page0LiquidMetal = true
    @AppStorage("page0MetalFlowers") private var page0MetalFlowers = true
    @AppStorage("gardenSceneEnabled") private var gardenSceneEnabled = true
    @AppStorage("globalMusicCapsuleEnabled") private var globalMusicCapsuleEnabled = true
    @AppStorage(OrbState.storageKey) private var orbStyleRaw = OrbState.working.rawValue

    private var manager: ThemeManager {
        themeManager ?? ThemeManager.shared
    }

    #if os(macOS)
    private var currentLayerTarget: ThemeTarget {
        profileManager.map { .person($0.currentProfile.id) } ?? .interface
    }

    /// 「聊天背景」行摘要：Mac 是这一层的聊天背景，iOS 是界面主题的
    private var chatBackgroundRowURL: URL? { manager.chatBackgroundImageURL }
    private var chatBackgroundRowStyle: ThemeBackgroundStyle { manager.chatBackgroundStyle }
    #else
    private var chatBackgroundRowURL: URL? { manager.currentBackgroundImageURL }
    private var chatBackgroundRowStyle: ThemeBackgroundStyle { manager.currentBackgroundStyle }
    #endif

    private var orbDisplayName: String {
        orbStyleRaw == OrbState.legacyDotsRaw ? "三个点" : OrbState.stored(orbStyleRaw).displayName
    }

    /// 高级外观入口的副标题：照二级页实际装的东西写（iPad 多一行正文栏宽度）
    private var advancedSubtitle: String {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad { return "正文栏宽度、边缘模糊" }
        #endif
        return "边缘模糊"
    }

    var body: some View {
        let _ = manager.themeChangeID

        // 搜索锚点：命中叶子条目时滚到那一行
        return ScrollViewReader { anchorProxy in
        SettingsSectionList(.list) {
            // 主题：显示模式三卡 + 三个二级入口（主题库 / 主题颜色 / 聊天背景），右侧就是当前状态摘要
            // （plan-theme-decouple M3.1，学 rootshell #1：不点进去就知道现在是什么）
            // atrium P3④a：iOS 这三行管「界面 + 跟随宫殿默认的人」，单独给人换去人页；Mac 没人页，拆成界面两行 + 这一层两行
            Section {
                ThemeModeCardPicker()

                SettingsNavRow(.themeLibrary) {
                    ThemeLibraryPage()
                } label: {
                    HStack(spacing: 8) {
                        #if os(macOS)
                        Text("界面主题")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        #else
                        Text("主题库")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        #endif
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

                #if os(macOS)
                // 聊天主题（这一层）：ThemeManager 里镜像的就是当前层，摘要直接读它
                SettingsNavRow(.chatThemeLibrary) {
                    ThemeLibraryPage(target: currentLayerTarget)
                } label: {
                    HStack(spacing: 8) {
                        Text("聊天主题（这一层）")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        ThemeChatPreview(
                            tokenSet: manager.previewTokenSet(for: manager.chatTheme.id, scheme: manager.activeScheme),
                            scheme: manager.activeScheme,
                            backgroundImageURL: manager.chatBackgroundImageURL,
                            backgroundStyle: manager.chatBackgroundStyle,
                            size: .row
                        )
                        Text(manager.chatThemeId.flatMap(manager.themeDefinition(id:)) == nil ? "跟随界面主题" : manager.chatTheme.name)
                            .font(m.secondary)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .searchAnchor("leaf-appear-chattheme")
                #endif

                SettingsNavRow(.chatBackground) {
                    #if os(macOS)
                    ChatBackgroundPage(target: currentLayerTarget)
                    #else
                    ChatBackgroundPage()
                    #endif
                } label: {
                    HStack(spacing: 8) {
                        #if os(macOS)
                        Text("聊天背景（这一层）")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        #else
                        Text("聊天背景")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        #endif
                        Spacer()
                        if let url = chatBackgroundRowURL {
                            ThemeBackgroundView(
                                fill: Theme.mainBg,
                                imageURL: url,
                                scheme: manager.activeScheme,
                                backgroundStyle: chatBackgroundRowStyle
                            )
                            .frame(width: 44, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text("\(Int((chatBackgroundRowStyle.resolvedOpacity(for: manager.activeScheme) * 100).rounded()))%")
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
            } header: {
                Text("主题")
            } footer: {
                #if os(macOS)
                Text("界面主题管侧栏、列表和设置；聊天主题和聊天背景只管这一层，换一层各是各的。")
                #else
                Text("这里换的是界面，和没单独选过主题的人聊天时也用它。单独给某个人换，去 TA 的人页。")
                #endif
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

            #if os(macOS)
            // atrium P3④b：字体字号 / 气泡几何 / 行距段距按层存；Mac 没人页，这里改的是当前这一层
            if let current = profileManager?.currentProfile {
                ChatAppearanceSections(profileId: current.id, layerName: current.name)
            }
            #endif

            // 文本：划线颜色（二级）。字体 / 字号 atrium P3④b 起按人存，iOS 在人页「气泡 · 字号」，Mac 在上面「这一层」
            Section("文本") {
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

            // 聊天样式：新对话开场（气泡 / 文章各自的交互在下面两块）
            Section("聊天样式") {
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

            // 气泡对话：只对气泡对话生效的设置（时间戳原在聊天样式）。气泡圆角 atrium P3④b 起按人存（ChatAppearanceSections）
            Section("气泡对话") {
                Toggle("显示时间戳", isOn: Binding(
                    get: { !hideTimestamp }, set: { hideTimestamp = !$0 }))
                    .font(m.body)
                    .tint(Theme.branchIndicator)
                    .searchAnchor("leaf-appear-timestamp")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // 文章对话：只对文章对话生效的设置（操作按钮原在消息显示）。气泡几何 atrium P3④b 起按人存（ChatAppearanceSections）
            Section("文章对话") {
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
                .searchAnchor("leaf-appear-articlechat")
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
        }
    }
}

/// 字体选择（`ChatAppearanceSections` 二级）：preset 列表 + 已导入字体 + 导入文件。
/// atrium P3④b：选的是 `profileId` 那一层的字体，点选直接写楼层（当前层经 `publishUpdated` 镜像进 `selectedFont` 老键）
struct FontPickerPage: View {
    let profileId: String
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var saveError: String?
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
                            select(preset.name)
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
                                select(font.fontName)
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
                    if selectedFont == target.fontName { select(nil) }
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
                        select(name)
                    }
                }
                importedFonts = FontManager.importedFonts()
            }
        }
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var selectedFont: String {
        (profileManager?.profiles.first(where: { $0.id == profileId })?.chatAppearance ?? ChatAppearance()).effectiveFontName
    }

    /// nil = 回到系统默认（删键）
    private func select(_ name: String?) {
        guard let profileManager else { return }
        do { try profileManager.updateChatAppearance(profileId: profileId) { $0.fontName = name } }
        catch { saveError = error.localizedDescription }
    }
}

/// 「聊天时的样子」按层的那几项（atrium P3④b）：字体 › / 聊天字号 / 行距段距 / 气泡对话圆角 / 文章对话气泡几何 / 恢复默认。
/// iOS 人页「气泡 · 字号」和 Mac 外观「这一层」共用。拖动时实时写老键（只当前层，聊天区当场看得见），
/// 松手 / 加减钮 / 离开页才写楼层（同 `VoiceEffectControls`，别每帧重写整份楼层列表）；值没变不写
struct ChatAppearanceSections: View {
    let profileId: String
    /// Mac：节头标「这一层（名字）」
    var layerName: String? = nil
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var draft = ChatAppearance()
    @State private var loadedProfileId: String?
    @State private var importedFonts: [(fileName: String, fontName: String)] = []
    @State private var saveError: String?

    private var stored: ChatAppearance {
        profileManager?.profiles.first(where: { $0.id == profileId })?.chatAppearance ?? ChatAppearance()
    }

    private var isCurrentLayer: Bool { profileManager?.currentProfile.id == profileId }

    private var fontScale: Double { draft.value(ChatAppearance.fontScaleMetric) }

    private var currentFontDisplayName: String {
        let name = stored.effectiveFontName
        if name.isEmpty { return "系统默认" }
        if let preset = FontManager.presetFonts.first(where: { $0.name == name }) { return preset.displayName }
        return importedFonts.first(where: { $0.fontName == name })?.fileName ?? "系统默认"
    }

    private func header(_ title: String, first: Bool = false) -> String {
        guard let layerName else { return title }
        return first ? "这一层（\(layerName)）" : "这一层 · \(title)"
    }

    var body: some View {
        Section {
            SettingsNavRow(.appearanceFont) {
                FontPickerPage(profileId: profileId)
            } label: {
                HStack {
                    Text("字体")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text(currentFontDisplayName)
                        .font(stored.effectiveFontName.isEmpty
                              ? m.secondary
                              : .custom(stored.effectiveFontName, size: m.secondarySize))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .searchAnchor("leaf-appear-font")
            // 生命周期挂在行上不挂 Section：Mac 设置表单按 Section 拆，Section 带修饰会认不出来
            .onAppear {
                importedFonts = FontManager.importedFonts()
                load()
            }
            .onChange(of: profileId) { _, _ in load() }
            .onChange(of: stored) { _, _ in load() }
            .onDisappear { save() }
            .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }

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
                    Button(action: { setFontScale(max(0.5, fontScale - 0.1)) }) {
                        Image(systemName: "textformat.size.smaller")
                            .font(m.label)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Slider(value: binding(ChatAppearance.fontScaleMetric), in: 0.5...2.0, step: 0.05,
                           onEditingChanged: commitOnRelease)
                        .tint(Theme.branchIndicator)

                    Button(action: { setFontScale(min(2.0, fontScale + 0.1)) }) {
                        Image(systemName: "textformat.size.larger")
                            .font(m.label)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                if fontScale != ChatAppearance.fontScaleMetric.defaultValue {
                    Button(action: { setFontScale(ChatAppearance.fontScaleMetric.defaultValue) }) {
                        Text("重置默认")
                            .font(m.secondary)
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                // ⌘ 快捷键提示：iOS 无菜单快捷键，mac 保留 J2 原样一行（⌘ 也改当前层）
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

            VStack(spacing: 12) {
                slider("行间距", ChatAppearance.lineSpacingMetric, range: 0.5...2.0, step: 0.05) { "\(Int($0 * 100))%" }
                slider("段落间距", ChatAppearance.paragraphSpacingMetric, range: 0.5...2.0, step: 0.05) { "\(Int($0 * 100))%" }
            }
            .searchAnchor("leaf-appear-typeset")
        } header: {
            Text(header("文字", first: true))
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)

        Section(header("气泡对话")) {
            slider("气泡圆角", ChatAppearance.bubbleModeCornerMetric, range: 14...34, step: 1) { "\(Int($0))pt" }
                .searchAnchor("leaf-appear-bubblechat")
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)

        Section(header("文章对话")) {
            VStack(spacing: 12) {
                slider("圆角", ChatAppearance.bubbleCornerMetric, range: 0...28, step: 1) { "\(Int($0))pt" }
                slider("水平内边距", ChatAppearance.bubblePaddingHMetric, range: 8...24, step: 1) { "\(Int($0))pt" }
                slider("垂直内边距", ChatAppearance.bubblePaddingVMetric, range: 4...20, step: 1) { "\(Int($0))pt" }
                slider("气泡间距", ChatAppearance.bubbleSpacingMetric, range: 8...40, step: 1) { "\(Int($0))pt" }
            }
            .searchAnchor("leaf-appear-geometry")
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)

        Section {
            Button(action: resetToDefaults) {
                HStack {
                    Spacer()
                    Text("恢复默认")
                        .font(m.secondary)
                        .foregroundColor(Theme.branchIndicator)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } footer: {
            Text("字体、字号、行距段距和气泡几何每个人各是各的；新建的人从当前这一层带过去。")
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)
    }

    private func slider(_ title: String, _ metric: ChatAppearance.Metric, range: ClosedRange<Double>, step: Double,
                        formatter: @escaping (Double) -> String) -> some View {
        AppearanceSliderRow(title: title, value: binding(metric), range: range, step: step,
                            onEditingChanged: commitOnRelease, formatter: formatter)
    }

    /// 拖动中：草稿 + 当前层的老键（聊天区实时看得见）；写楼层等松手
    private func binding(_ metric: ChatAppearance.Metric) -> Binding<Double> {
        Binding(get: { draft.value(metric) }, set: { value in
            draft[keyPath: metric.path] = value
            if isCurrentLayer { ChatAppearance.sync(value, key: metric.key, into: .standard) }
        })
    }

    private func commitOnRelease(_ editing: Bool) {
        if !editing { save() }
    }

    private func setFontScale(_ value: Double) {
        binding(ChatAppearance.fontScaleMetric).wrappedValue = value
        save()
    }

    private func load() {
        draft = stored
        loadedProfileId = profileId
    }

    /// 只写数值项、只写和楼层里实际生效值不同的（字体由字体页直接写）
    private func save() {
        guard let profileManager, loadedProfileId == profileId else { return }
        let next = draft
        do {
            try profileManager.updateChatAppearance(profileId: profileId) { a in
                for metric in ChatAppearance.metrics where a.value(metric) != next.value(metric) {
                    a[keyPath: metric.path] = next.value(metric)
                }
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// 9 项全置 nil（读侧默认值）；当前层先把老键删掉，楼层写失败也和草稿一致到下次镜像
    private func resetToDefaults() {
        guard let profileManager else { return }
        draft.resetLayout()
        if isCurrentLayer { ChatAppearance.writeKeys(draft, into: .standard) }
        do { try profileManager.updateChatAppearance(profileId: profileId) { $0.resetLayout() } }
        catch { saveError = error.localizedDescription }
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

/// 高级外观（外观页二级）：排版（只 iPad：正文栏宽度）+ 边缘模糊 + 重置。
/// 行距段距、气泡几何 atrium P3④b 起按人存，在 `ChatAppearanceSections`（它自己的「恢复默认」管那 7 个）。
struct AdvancedAppearancePage: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage("blurRadius") private var blurRadius = 1.3
    // 负向 key：true = 关闭自动半透明。这样 key 缺省（false）= 行为保持原样。
    @AppStorage("disableAutoTransparentBubblesOnWallpaper") private var disableAutoTransparent: Bool = false
    // 重置同时恢复主页面的时间戳和操作按钮设置。
    @AppStorage("hideTimestamp") private var hideTimestamp: Bool = false
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
            #if os(iOS)
            // 正文栏宽度只在宽屏看得出（手机竖屏比这个数窄），所以只 iPad 露；不进下面的重置。
            // 行距段距 atrium P3④b 起按人存，这一节只剩它
            if UIDevice.current.userInterfaceIdiom == .pad {
                Section("排版") {
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
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            }
            #endif

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
                        // 重置跨页：时间戳、操作按钮在外观一级页的气泡对话 / 文章对话，壁纸半透明在聊天背景。
                        // 气泡几何、行距段距按人存，归「气泡 · 字号」（Mac「这一层」）的「恢复默认」
                        Text("重置边缘模糊、壁纸下半透明，以及时间戳、操作按钮的显示")
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
        AppearanceSliderRow(title: title, value: value, range: range, step: step, formatter: formatter)
    }

    /// 两端恢复同一组默认值，并通知主题刷新。
    /// 不含主题 / 语言 / 正文栏宽度，也不含按人存的字体字号、气泡几何、行距段距（atrium P3④b）。
    private func resetPageToDefaults() {
        blurRadius = 1.3
        disableAutoTransparent = false
        hideTimestamp = false
        hideActionBar = false
        themeManager?.notifyThemeChange()
    }
}

/// 外观页的滑杆行（标题 + 当前值 + 滑杆）：高级外观和按人的 `ChatAppearanceSections` 共用。
/// `onEditingChanged` 松手时 false（按人那几根靠它写楼层，拖动中不逐帧落盘）
struct AppearanceSliderRow: View {
    @Environment(\.settingsMetrics) private var m
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var onEditingChanged: (Bool) -> Void = { _ in }
    let formatter: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(m.label)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(formatter(value))
                    .font(m.secondary.weight(.medium))
                    .foregroundColor(Theme.branchIndicator)
            }
            Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
                .tint(Theme.branchIndicator)
        }
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
