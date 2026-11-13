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
/// `target: .person`（atrium P3④a）：编辑 TA 的聊天主题；这套还有别人在用先问「复制一份给 TA / 一起改」，内置主题复制完给 TA。
struct ThemeColorsPage: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @Environment(\.dismiss) private var dismiss
    /// nil = 编辑当前主题（外观页入口）；给定 = 编辑那一套（主题列表长按），不切换当前主题
    let fixedThemeId: String?
    let creating: Bool
    private let themeTarget: ThemeTarget
    /// 人页入口：这套还有谁在用（非 nil = 弹共用提示）
    @State private var sharers: [String]?
    @State private var saveError: String?
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

    init(themeId: String? = nil, creating: Bool = false, target: ThemeTarget = .interface) {
        self.fixedThemeId = themeId
        self.creating = creating
        self.themeTarget = target
    }

    private struct ColorSnapshot {
        let themeId: String
        let light: ThemeTokenSet
        let dark: ThemeTokenSet
    }

    private var manager: ThemeManager { themeManager ?? ThemeManager.shared }
    private var themeId: String { copiedThemeId ?? fixedThemeId ?? themeTarget.themeId(manager, profileManager) }
    /// 页底铺图：按目标走的入口铺正在改的那套，列表长按入口照旧铺界面主题
    private var pageBackgroundThemeId: String { fixedThemeId == nil ? themeId : manager.selectedThemeId }
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

            Section {
                overrideRow("bubbleModeUserBubble", "你的气泡底", \.bubbleModeUserBubble,
                            fallback: { $0.userBubble }, offText: "跟随上面", covered: pure)
                // 没设时跟 applyingBubbleModeColors 对齐：泡底换了 = 单色「不渐变」，否则跟随上面的渐变
                overrideRow("bubbleModeUserBubbleGradient", "你的气泡渐变", \.bubbleModeUserBubbleGradient,
                            fallback: { $0.bubbleModeUserBubble ?? $0.userBubbleGradient ?? $0.userBubble },
                            offText: tokens.bubbleModeUserBubble == nil ? "跟随上面" : "不渐变", covered: pure)
                overrideRow("bubbleModeUserText", "你的文字", \.bubbleModeUserText,
                            fallback: { $0.userText ?? $0.textPrimary }, offText: "跟随上面")
                overrideRow("bubbleModeAssistantBubble", "AI 气泡底", \.bubbleModeAssistantBubble,
                            fallback: { $0.assistantBubble }, offText: "跟随上面", covered: pure)
                overrideRow("bubbleModeAssistantText", "AI 文字", \.bubbleModeAssistantText,
                            fallback: { $0.assistantText ?? $0.textPrimary }, offText: "跟随上面")
            } header: {
                Text("气泡模式")
            } footer: {
                Text("气泡模式下用这几种颜色，不设就跟随上面。")
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
                imageURL: manager.backgroundImageURL(for: pageBackgroundThemeId),
                scheme: manager.activeScheme,
                backgroundStyle: manager.backgroundStyle(for: pageBackgroundThemeId)
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
            Text(themeTarget.profileId != nil && fixedThemeId == nil
                 ? "复制一份「\(theme.name)」给 TA 再改？"
                 : fixedThemeId == nil
                 ? "复制一份「\(theme.name)」再改？复制完自动切过去。"
                 : "复制一份「\(theme.name)」再改？当前主题不变。")
        }
        .sharedChatThemePrompt(sharers: $sharers, themeName: theme.name, onCopy: copyAndContinue, onCancel: { dismiss() })
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            editingScheme = manager.activeScheme
            if creating { draftName = theme.name }
            takeSnapshot()
            if theme.isBuiltIn {
                showBuiltInPrompt = true
            } else if fixedThemeId == nil {
                let others = themeTarget.sharers(of: themeId, manager, profileManager)
                if !others.isEmpty { sharers = others }
            }
        }
        .onChange(of: themeId) { _, _ in
            // 按目标走的入口（界面 = 选中的、人 = TA 的聊天主题）跟着它变重拍快照；列表入口的靶子是固定的
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
    /// 和「气泡渐变」（nil = 关、色块画气泡底）、「气泡模式」一节（nil = 跟随上面）共用；`fallback` 就是 nil 时色块画什么。
    private func overrideRow(
        _ key: String,
        _ title: String,
        _ keyPath: WritableKeyPath<ThemeTokenSet, ThemeColorValue?>,
        subtitle: String? = nil,
        fallback: @escaping (ThemeTokenSet) -> ThemeColorValue = { $0.textPrimary },
        offText: String = "跟随主文字",
        covered: Bool = false
    ) -> some View {
        let override = tokens[keyPath: keyPath]
        let shown = override ?? fallback(tokens)
        return ThemeColorRow(
            title: title,
            subtitle: subtitle,
            value: shown,
            valueText: override == nil ? offText : nil,
            covered: covered,
            onReset: override == nil ? nil : { writeOverride(keyPath, nil) },
            apply: { writeOverride(keyPath, $0) },
            onOpenPicker: {
                openPicker(key: key, title: title, initial: shown, read: { tokens[keyPath: keyPath] ?? fallback(tokens) }) { writeOverride(keyPath, $0) }
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

    /// 内置主题不能改 / 人页共用提示选「复制一份给 TA」→ 复制一份接着改。外观页入口（编辑的就是当前）复制完切过去；
    /// 人页入口复制完给 TA；列表入口不切，靶子换成新的那份。
    private func copyAndContinue() {
        let isPerson = themeTarget.profileId != nil && fixedThemeId == nil
        let selectAfter = fixedThemeId == nil && !isPerson
        if let newId = manager.saveThemeCopy(from: themeId, name: "", select: selectAfter), !selectAfter {
            copiedThemeId = newId
            if isPerson {
                do { try themeTarget.apply(newId, manager, profileManager) } catch { saveError = error.localizedDescription }
            }
        }
        takeSnapshot()
    }
}
