import SwiftUI

/// 颜色页（两端共用一份 body）：编辑一套主题的浅 / 深两套 token。
///
/// **改主题 ≠ 应用主题**（粟粟 09-16）：`themeId == nil` = 外观页入口，编辑当前主题，改了立刻生效；
/// 给定 `themeId` = 主题列表长按进来，编辑那一套本身，**不切换**当前主题——只有它恰好是当前主题时界面才跟着变。
///
/// plan-theme-decouple M3.3：顶部钉实时预览；按「用在哪」分四组，副标题写清用途；浅 / 深分段默认停在当前配色方案（修 P3）；
/// 「纯净背景」开关住这里（kimi 应改 3 修正版）——它覆盖的是四个颜色 token、不碰背景图，开着时那四行标灰打「被覆盖」；
/// 内置主题点进来弹「复制一份？」；「撤销」回到进页时的浅 + 深两套（快照只包 tokenSet，kimi 应改 4）。
/// 取色 = 取色 sheet：色相 / 饱和度 / 明度三根条 + 原样嵌入的系统取色器（D2 加不换，见 `ColorPickSheet`）。
/// `creating` = 主题列表「+」新建：同一页顶上多一段「名称」、颜色下面接 `ChatBackgroundSections`（一页设完名字、字色、背景），
/// 没有撤销——外面的「取消」把这套新主题整个丢掉。
struct ThemeColorsPage: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(\.settingsMetrics) private var m
    @Environment(\.dismiss) private var dismiss
    /// nil = 编辑当前主题（外观页入口）；给定 = 编辑那一套（主题列表长按），不切换当前主题
    let fixedThemeId: String?
    let creating: Bool
    @State private var draftName = ""
    @State private var editingScheme: ColorScheme = .light
    @State private var didAppear = false
    @State private var snapshot: ColorSnapshot?
    @State private var showBuiltInPrompt = false
    /// 内置主题「复制一份」后接着编辑的那份（列表入口不切换当前主题，靶子换成新 id）
    @State private var copiedThemeId: String?
    #if os(iOS)
    /// B22 v6：取色 sheet 收口到页级单一 `.sheet(item:)`，13 行共用（每行各挂一个会打架，见 research-B22）
    @State private var pickingSlot: ColorPickingSlot?
    #endif

    init(themeId: String? = nil, creating: Bool = false) {
        self.fixedThemeId = themeId
        self.creating = creating
    }

    private struct ColorSnapshot {
        let themeId: String
        let light: ThemeTokenSet
        let dark: ThemeTokenSet
    }

    private var manager: ThemeManager { themeManager ?? ThemeManager.shared }
    private var themeId: String { copiedThemeId ?? fixedThemeId ?? manager.selectedThemeId }
    private var theme: AppThemeDefinition { manager.themeDefinition(id: themeId) ?? manager.selectedTheme }
    private var tokens: ThemeTokenSet { theme.tokens(for: editingScheme) }
    private var pure: Bool { manager.usePureBackground }

    private var canUndo: Bool {
        guard let snapshot, snapshot.themeId == themeId else { return false }
        return snapshot.light != theme.light || snapshot.dark != theme.dark
    }

    var body: some View {
        let _ = manager.themeChangeID

        SettingsSectionList(.list) {
            if creating {
                Section("名称") {
                    TextField("新主题", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                        .onChange(of: draftName) { _, name in manager.updateThemeName(name, for: themeId) }
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            }

            Section {
                tokenRow("mainBg", "主背景", nil, \.mainBg, covered: pure)
                tokenRow("sidebarBg", "侧栏背景", nil, \.sidebarBg, covered: pure)
                tokenRow("textPrimary", "主文字", nil, \.textPrimary)
                tokenRow("textSecondary", "次文字", "昵称 · 摘要", \.textSecondary)
                tokenRow("textMuted", "弱文字", "时间 · 微标签", \.textMuted)
                tokenRow("accent", "辅助底色", "行内码 · 卡片底", \.accent)
            } header: {
                groupHeader("全局", "列表页 · 仪表盘 · 设置 · 聊天默认")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("聊天 · 你的消息") {
                tokenRow("userBubble", "气泡底", nil, \.userBubble, covered: pure)
                overrideRow("userBubbleGradient", "气泡渐变", \.userBubbleGradient,
                            subtitle: "第二色在下面，和气泡底连成一条。", fallback: \.userBubble, offText: "关", covered: pure)
                overrideRow("userText", "文字", \.userText)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("聊天 · AI 消息") {
                tokenRow("assistantBubble", "气泡底", tokens.assistantBubble.alpha == 0 ? "透明" : nil, \.assistantBubble, covered: pure)
                overrideRow("assistantText", "文字", \.assistantText)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("功能色") {
                tokenRow("branchIndicator", "分支强调", "链接 · 选中 · 按钮", \.branchIndicator)
                tokenRow("favorite", "收藏", nil, \.favorite)
                tokenRow("danger", "危险色", nil, \.danger)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("配色策略") {
                Toggle(isOn: Binding(
                    get: { manager.usePureBackground },
                    set: { manager.usePureBackground = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("纯净背景")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Text("开了会覆盖上面的主背景、侧栏和两种气泡底色，不碰背景图。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .tint(Theme.branchIndicator)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            if creating {
                ChatBackgroundSections(themeId: themeId, embedded: true)
            }

            Section {
                Button(editingScheme == .dark ? "恢复默认深色" : "恢复默认浅色") {
                    manager.restoreDefaultTokenSet(for: editingScheme, themeId: themeId)
                }
                .foregroundColor(Theme.branchIndicator)

                if editingScheme == .dark {
                    Button("用浅色生成深色草稿") {
                        manager.copyLightIntoDarkDraft(themeId: themeId)
                    }
                    .foregroundColor(Theme.branchIndicator)
                }

                if creating && theme.hasBackgroundImage {
                    Button("聊天背景重置为默认") {
                        manager.resetBackgroundAdjustments(for: themeId)
                    }
                    .foregroundColor(Theme.branchIndicator)
                }

                #if os(macOS)
                if !creating {
                    Button("撤销本次修改") { undo() }
                        .foregroundColor(Theme.branchIndicator)
                        .disabled(!canUndo)
                }
                #endif
            } footer: {
                Text(creating
                     ? "改动实时生效。「取消」会把这套新主题整个丢掉。"
                     : "「撤销」= 回到进这页时的浅、深两套颜色。改动实时生效，不用保存。")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        .disabled(theme.isBuiltIn)
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
        .safeAreaInset(edge: .top, spacing: 0) { pinnedHeader }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ThemeBackgroundView(
                fill: Theme.sidebarBg,
                imageURL: manager.currentBackgroundImageURL,
                scheme: manager.activeScheme,
                backgroundStyle: manager.currentBackgroundStyle
            )
            .ignoresSafeArea()
        }
        #if os(iOS)
        .navigationTitle(creating ? "新主题" : "主题颜色")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if !creating {
                ToolbarItem(placement: .primaryAction) {
                    Button("撤销") { undo() }
                        .foregroundColor(Theme.branchIndicator)
                        .disabled(!canUndo)
                }
            }
        }
        .sheet(item: $pickingSlot) { slot in
            ColorPickSheet(slot: slot)
                .environment(manager)
        }
        #endif
        .alert("内置主题不能改", isPresented: $showBuiltInPrompt) {
            Button("复制一份") { copyAndContinue() }
            Button("算了", role: .cancel) { dismiss() }
        } message: {
            Text(fixedThemeId == nil
                 ? "复制一份「\(theme.name)」再改？复制完自动切过去。"
                 : "复制一份「\(theme.name)」再改？当前主题不变。")
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            editingScheme = manager.activeScheme
            if creating { draftName = theme.name }
            takeSnapshot()
            if theme.isBuiltIn { showBuiltInPrompt = true }
        }
        .onChange(of: manager.selectedThemeId) { _, _ in
            // 只有「编辑当前主题」入口跟着选中走；列表入口的靶子是固定的
            if fixedThemeId == nil { takeSnapshot() }
        }
    }

    // MARK: - 钉顶预览

    private var pinnedHeader: some View {
        let previewTokens = manager.previewTokenSet(for: themeId, scheme: editingScheme)
        return VStack(spacing: 10) {
            Picker("编辑", selection: $editingScheme) {
                Text("浅色").tag(ColorScheme.light)
                Text("深色").tag(ColorScheme.dark)
            }
            .pickerStyle(.segmented)

            ThemeChatPreview(
                tokenSet: previewTokens,
                scheme: editingScheme,
                backgroundImageURL: manager.backgroundImageURL(for: themeId),
                backgroundStyle: manager.backgroundStyle(for: themeId),
                size: .pinned
            )
            .overlay(alignment: .topTrailing) {
                Text("\(theme.name) · \(editingScheme == .dark ? "深色" : "浅色")")
                    .font(m.caption)
                    .foregroundColor(previewTokens.textMuted.color)
                    .padding(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.sidebarBg)   // 实底：半透明会让滚到下面的行透出来一层字

    }

    private func groupHeader(_ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Text(subtitle)
                .foregroundColor(Theme.textMuted)
        }
    }

    // MARK: - 行

    private func tokenRow(
        _ key: String,
        _ title: String,
        _ subtitle: String?,
        _ keyPath: WritableKeyPath<ThemeTokenSet, ThemeColorValue>,
        covered: Bool = false
    ) -> some View {
        let value = tokens[keyPath: keyPath]
        return ThemeColorRow(
            title: title,
            subtitle: subtitle,
            value: value,
            covered: covered,
            apply: { write(keyPath, $0) },
            onOpenPicker: {
                openPicker(key: key, title: title, initial: value, read: { tokens[keyPath: keyPath] }) { write(keyPath, $0) }
            }
        )
    }

    /// 「nil = 跟随 / 关，设过才出 ↺」的覆盖行：聊天正文字色两行（M1 三格，nil = 跟随主文字、色块画主文字色）
    /// 和「气泡渐变」（nil = 关、色块画气泡底）共用；`fallback` 就是 nil 时色块画哪格。
    private func overrideRow(
        _ key: String,
        _ title: String,
        _ keyPath: WritableKeyPath<ThemeTokenSet, ThemeColorValue?>,
        subtitle: String? = nil,
        fallback: KeyPath<ThemeTokenSet, ThemeColorValue> = \.textPrimary,
        offText: String = "跟随主文字",
        covered: Bool = false
    ) -> some View {
        let override = tokens[keyPath: keyPath]
        let shown = override ?? tokens[keyPath: fallback]
        return ThemeColorRow(
            title: title,
            subtitle: subtitle,
            value: shown,
            valueText: override == nil ? offText : nil,
            covered: covered,
            onReset: override == nil ? nil : { writeOverride(keyPath, nil) },
            apply: { writeOverride(keyPath, $0) },
            onOpenPicker: {
                openPicker(key: key, title: title, initial: shown, read: { tokens[keyPath: keyPath] ?? tokens[keyPath: fallback] }) { writeOverride(keyPath, $0) }
            }
        )
    }

    private func write(_ keyPath: WritableKeyPath<ThemeTokenSet, ThemeColorValue>, _ value: ThemeColorValue) {
        var next = tokens
        next[keyPath: keyPath] = value
        manager.replaceTokenSet(next, for: editingScheme, themeId: themeId)
    }

    private func writeOverride(_ keyPath: WritableKeyPath<ThemeTokenSet, ThemeColorValue?>, _ value: ThemeColorValue?) {
        var next = tokens
        next[keyPath: keyPath] = value
        manager.replaceTokenSet(next, for: editingScheme, themeId: themeId)
    }

    /// iOS：开取色 sheet（系统取色器 + 两根条，页级单一 sheet）；mac 走行内 ColorPicker，这里是空操作。
    private func openPicker(
        key: String,
        title: String,
        initial: ThemeColorValue,
        read: @escaping () -> ThemeColorValue,
        apply: @escaping (ThemeColorValue) -> Void
    ) {
        #if os(iOS)
        pickingSlot = ColorPickingSlot(id: key, label: title, initial: initial, read: read) { apply(ThemeColorValue(color: $0)) }
        #endif
    }

    // MARK: - 快照 / 撤销 / 复制

    private func takeSnapshot() {
        snapshot = ColorSnapshot(themeId: themeId, light: theme.light, dark: theme.dark)
    }

    private func undo() {
        guard let snapshot, snapshot.themeId == themeId else { return }
        manager.replaceTokenSet(snapshot.light, for: .light, themeId: themeId)
        manager.replaceTokenSet(snapshot.dark, for: .dark, themeId: themeId)
    }

    /// 内置主题不能改 → 复制一份接着改。外观页入口（编辑的就是当前）复制完切过去；列表入口不切，靶子换成新的那份。
    private func copyAndContinue() {
        let selectAfter = fixedThemeId == nil
        if let newId = manager.saveThemeCopy(from: themeId, name: "", select: selectAfter), !selectAfter {
            copiedThemeId = newId
        }
        takeSnapshot()
    }
}
