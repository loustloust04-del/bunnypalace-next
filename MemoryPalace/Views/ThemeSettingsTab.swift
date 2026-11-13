import SwiftUI

/// 显示模式三卡选择器（浅色 / 深色 / 跟随系统），外观页一级用。
struct ThemeModeCardPicker: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?

    private var manager: ThemeManager {
        themeManager ?? ThemeManager.shared
    }

    var body: some View {
        let _ = manager.themeChangeID
        HStack(spacing: 10) {
            ForEach(AppThemeMode.allCases) { mode in
                ThemeModeCard(mode: mode, isSelected: manager.themeMode == mode) {
                    manager.themeMode = mode
                }
            }
            #if os(macOS)
            Spacer(minLength: 0)   // 卡钉宽后靠左，不居中
            #endif
        }
    }
}

/// 单张模式卡：迷你界面 mock（圆角矩形 + 两条线 + 一个点），跟随系统右下斜切深色三角。
private struct ThemeModeCard: View {
    let mode: AppThemeMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                cardMock
                    #if os(macOS)
                    .frame(width: 100, height: 72)   // 680 宽的设置窗不拉扁，钉 iPhone 上的 ~100×72（第 8 类：图形尺寸）
                    #else
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                    #endif
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isSelected ? Theme.branchIndicator : Theme.textMuted.opacity(0.25),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                Text(mode.title)
                    .font(.system(size: Theme.F.caption + 1, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Theme.textPrimary : Theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cardMock: some View {
        switch mode {
        case .light:
            mockContent(bg: Color(white: 0.98), line: Color(white: 0.72))
        case .dark:
            mockContent(bg: Color(white: 0.13), line: Color(white: 0.45))
        case .system:
            ZStack {
                mockContent(bg: Color(white: 0.98), line: Color(white: 0.72), showDot: false)
                Color(white: 0.13).clipShape(DiagonalTrailingShape())
                Circle()
                    .fill(Theme.branchIndicator.opacity(0.85))
                    .frame(width: 10, height: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(9)
            }
        }
    }

    private func mockContent(bg: Color, line: Color, showDot: Bool = true) -> some View {
        ZStack {
            Rectangle().fill(bg)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(line).frame(width: 32, height: 4)
                Capsule().fill(line).frame(width: 20, height: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 12)
            .padding(.leading, 10)
            if showDot {
                Circle()
                    .fill(Theme.branchIndicator.opacity(0.75))
                    .frame(width: 10, height: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(9)
            }
        }
    }
}

/// 从左上角斜切到右下角之外的右下三角（「跟随系统」卡的深色一半）。
private struct DiagonalTrailingShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 主题页改谁（atrium P3④a）：`.interface` = 界面主题（`selectedThemeId`，外观页入口，现状）；
/// `.person(楼层 id)` = 那一层的聊天主题（iOS 人页「聊天时的样子」、Mac 外观「聊天主题 / 聊天背景（这一层）」）。
/// 聊天背景跟着聊天主题走（粟粟 11-09 §0-1），不单独按人存。
enum ThemeTarget: Hashable {
    case interface
    case person(String)

    var profileId: String? {
        if case .person(let id) = self { return id }
        return nil
    }

    /// 人目标：这一层存的聊天主题 id（nil = 跟随界面主题）
    func storedChatThemeId(_ profiles: ProfileManager?) -> String? {
        guard let profileId else { return nil }
        return profiles?.profiles.first(where: { $0.id == profileId })?.chatAppearance?.themeId
    }

    /// 人目标：跟随界面主题（没选过，或选的那套已经不在了）
    func isFollowingInterface(_ manager: ThemeManager, _ profiles: ProfileManager?) -> Bool {
        storedChatThemeId(profiles).flatMap(manager.themeDefinition(id:)) == nil
    }

    /// 这个目标现在实际用的那套
    func themeId(_ manager: ThemeManager, _ profiles: ProfileManager?) -> String {
        switch self {
        case .interface: return manager.selectedThemeId
        case .person: return manager.chatTheme(for: storedChatThemeId(profiles)).id
        }
    }

    /// 给这个目标换上一套（人目标 nil = 回到跟随界面主题）
    func apply(_ id: String?, _ manager: ThemeManager, _ profiles: ProfileManager?) throws {
        switch self {
        case .interface:
            if let id { manager.selectTheme(id: id) }
        case .person(let profileId):
            guard let profiles else { throw ProfileManager.SaveError.profileMissing }
            try profiles.setChatTheme(id, profileId: profileId)
        }
    }

    /// 人目标改 `themeId` 那套之前：还有谁也在用它（别的层的名字；它是界面主题时加一个「界面（宫殿默认）」）。空 = 只有 TA 自己
    func sharers(of themeId: String, _ manager: ThemeManager, _ profiles: ProfileManager?) -> [String] {
        guard let profileId else { return [] }
        var names = (profiles?.profiles(usingChatTheme: themeId) ?? [])
            .filter { $0.id != profileId }
            .map(\.name)
        if themeId == manager.selectedThemeId { names.append("界面（宫殿默认）") }
        return names
    }
}

extension View {
    /// 人页进主题颜色 / 聊天背景时，这套还有别人在用 → 先问（atrium P3④a §3「共用提示」）。`sharers` nil = 不弹
    func sharedChatThemePrompt(sharers: Binding<[String]?>, themeName: String,
                               onCopy: @escaping () -> Void, onCancel: @escaping () -> Void) -> some View {
        alert("「\(themeName)」还有 \((sharers.wrappedValue ?? []).joined(separator: "、")) 在用",
              isPresented: Binding(get: { sharers.wrappedValue != nil }, set: { if !$0 { sharers.wrappedValue = nil } })) {
            Button("复制一份给 TA") { onCopy() }
            Button("一起改") {}
            Button("取消", role: .cancel) { onCancel() }
        } message: {
            Text("复制一份只改 TA 的；一起改，用这套的都会跟着变。")
        }
    }
}

/// 主题列表（外观 › 主题，两端共用一份 body）：只负责「挑」。
///
/// plan-theme-decouple M3.2（学 rootshell #2 #3）：每行 = 迷你聊天预览 + 名字 + 勾，**点行 = 立即应用**；
/// 重命名 / 复制一份 / 删除收进长按菜单（iOS 另有左滑）；内置主题只给「复制一份」。
/// 右上「+」= 新建一套（粟粟 09-16：「添加新主题就是一个编辑页面设字体颜色背景」）：从当前主题起步立刻建出来，
/// 直接开 `ThemeColorsPage(creating:)` 一页设名称 + 颜色 + 聊天背景，**不切换**当前主题；「取消」把这套删掉。
/// 没有「保存当前主题 / 编辑当前主题」两行，也没有「草稿」徽标——数据层的 custom 主题照旧，UI 上当普通自定义主题。
/// 外观页另两个入口（`ThemeColorsPage` / `ChatBackgroundPage`）编辑当前选中的这一套。
/// 删除必过确认弹窗（kimi 应改 2）：`deleteTheme` 会连带删掉背景图文件；有层单独选了它的，提示名字、删后那些层回到界面主题。
/// `target: .person`（atrium P3④a）：顶上多一行「跟随界面主题」，点行 = 给 TA 换，复制 / 新建以 TA 的那套为起点、建完给 TA。
struct ThemeLibraryPage: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    private let themeTarget: ThemeTarget
    @State private var saveError: String?
    /// 长按「复制一份」的来源主题 → 开 `ThemeSaveSheet`
    @State private var copySource: AppThemeDefinition?
    @State private var pendingThemeName = ""
    @State private var renameTarget: AppThemeDefinition?
    @State private var renameText = ""
    @State private var pendingDeleteTheme: AppThemeDefinition?
    /// 长按「编辑颜色 / 编辑聊天背景」：sheet 开对应页编辑**那一套**（粟粟 09-16：「改主题是修改主题，跟现在是啥样无关」——
    /// 不切换当前主题；它恰好是当前主题时界面才跟着变）。`.create` = 「+」新建出来的那套，同一个 sheet 开全页编辑器。
    @State private var editTarget: EditTarget?

    private struct EditTarget: Identifiable {
        enum Kind { case colors, background, create }
        let kind: Kind
        let themeId: String
        var id: String { "\(kind)-\(themeId)" }
    }

    init(target: ThemeTarget = .interface) {
        self.themeTarget = target
    }

    private var manager: ThemeManager {
        themeManager ?? ThemeManager.shared
    }

    private var isPerson: Bool { themeTarget.profileId != nil }
    private var following: Bool { isPerson && themeTarget.isFollowingInterface(manager, profileManager) }
    /// 这个目标现在用的那套（页底铺它的图；「+」从它起步）
    private var targetThemeId: String { themeTarget.themeId(manager, profileManager) }

    private func isSelected(_ theme: AppThemeDefinition) -> Bool {
        isPerson ? !following && targetThemeId == theme.id : manager.selectedThemeId == theme.id
    }

    var body: some View {
        let _ = manager.themeChangeID

        SettingsSectionList(.list) {
            Section {
                if isPerson {
                    Button {
                        apply(nil)
                    } label: {
                        ThemeListRow(
                            theme: manager.selectedTheme,
                            tokenSet: manager.currentTokenSet,
                            backgroundImageURL: manager.currentBackgroundImageURL,
                            backgroundStyle: manager.currentBackgroundStyle,
                            scheme: manager.activeScheme,
                            isSelected: following,
                            title: "跟随界面主题（宫殿默认）",
                            note: "现在是「\(manager.selectedTheme.name)」"
                        )
                    }
                    .buttonStyle(.plain)
                }

                ForEach(manager.themeDefinitions) { theme in
                    Button {
                        apply(theme.id)
                    } label: {
                        ThemeListRow(
                            theme: theme,
                            tokenSet: manager.previewTokenSet(for: theme.id, scheme: manager.activeScheme),
                            backgroundImageURL: manager.backgroundImageURL(for: theme.id),
                            backgroundStyle: manager.backgroundStyle(for: theme.id),
                            scheme: manager.activeScheme,
                            isSelected: isSelected(theme)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menuItems(for: theme) }
                    #if os(iOS)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { swipeItems(for: theme) }
                    #endif
                }

                #if os(macOS)
                // mac 设置窗藏了系统工具栏，「+」没地方画，给一行
                Button {
                    startCreate()
                } label: {
                    Label("新建主题", systemImage: "plus")
                        .font(m.body)
                        .foregroundColor(Theme.branchIndicator)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #endif
            } header: {
                Text("\(manager.themeDefinitions.count) 套")
            } footer: {
                Text(isPerson
                     ? "这里换的是和 TA 聊天时的主题和背景，界面和别人不变。「跟随界面主题」= 用 我 › 外观 里那套。「+」从 TA 现在这套起步新建一套，建好就给 TA 用上。长按可以编辑颜色、编辑聊天背景、重命名、复制一份、删除。"
                     : "点一下就切换。「+」新建一套：从当前主题起步，一页设好名字、颜色和聊天背景，建好不切换。长按可以编辑颜色、编辑聊天背景、重命名、复制一份、删除。编辑改的是那一套主题本身，不会切换过去；内置主题会先复制一份再改。")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        // 整页铺主题背景图 + 藏 navbar 底：`.navigationBar` placement 是 iOS-only，
        // mac 设置窗没有 navbar、页底由 `MacSettingsForm` / `ShellStyle` 统一定（第 5 类）
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ThemeBackgroundView(
                fill: Theme.sidebarBg,
                imageURL: manager.backgroundImageURL(for: targetThemeId),
                scheme: manager.activeScheme,
                backgroundStyle: manager.backgroundStyle(for: targetThemeId)
            )
            .ignoresSafeArea()
        }
        .navigationTitle(isPerson ? "聊天主题" : "主题库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startCreate()
                } label: {
                    Image(systemName: "plus")
                }
                .foregroundColor(Theme.branchIndicator)
                .accessibilityLabel("新建主题")
            }
        }
        #endif
        .sheet(item: $editTarget) { target in
            NavigationStack {
                Group {
                    switch target.kind {
                    case .colors: ThemeColorsPage(themeId: target.themeId)
                    case .background: ChatBackgroundPage(themeId: target.themeId)
                    case .create: ThemeColorsPage(themeId: target.themeId, creating: true)
                    }
                }
                .toolbar {
                    if target.kind == .create {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") {
                                editTarget = nil
                                manager.deleteTheme(id: target.themeId)
                            }
                            .foregroundColor(Theme.textSecondary)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") {
                                editTarget = nil
                                if isPerson { apply(target.themeId) }   // 人页新建的这套建完给 TA 用上
                            }
                            .foregroundColor(Theme.branchIndicator)
                        }
                    } else {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { editTarget = nil }
                                .foregroundColor(Theme.branchIndicator)
                        }
                    }
                }
            }
            .environment(manager)
            .interactiveDismissDisabled(target.kind == .create)   // 新建的那套要么「完成」留下要么「取消」删掉，不让下滑糊过去
            #if os(macOS)
            .frame(minWidth: 560, minHeight: 640)   // mac sheet 不给尺寸会塌成只剩标题
            #endif
        }
        .sheet(item: $copySource) { source in
            ThemeSaveSheet(
                name: $pendingThemeName,
                previewTokenSet: manager.previewTokenSet(for: source.id, scheme: manager.activeScheme),
                previewBackgroundImageURL: manager.backgroundImageURL(for: source.id),
                previewBackgroundStyle: manager.backgroundStyle(for: source.id)
            ) {
                if isPerson {
                    if let id = manager.saveThemeCopy(from: source.id, name: pendingThemeName, select: false) { apply(id) }
                } else {
                    manager.saveThemeCopy(from: source.id, name: pendingThemeName)
                }
                copySource = nil
            }
            .environment(manager)
        }
        .alert(
            "重命名",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            ),
            presenting: renameTarget
        ) { theme in
            TextField("主题名称", text: $renameText)
            Button("好") {
                manager.updateThemeName(renameText, for: theme.id)
                renameTarget = nil
            }
            Button("取消", role: .cancel) {
                renameTarget = nil
            }
        } message: { _ in
            Text("改名字不影响颜色和背景。")
        }
        .alert(
            pendingDeleteTheme.map { "删除「\($0.name)」？" } ?? "删除主题？",
            isPresented: Binding(
                get: { pendingDeleteTheme != nil },
                set: { if !$0 { pendingDeleteTheme = nil } }
            ),
            presenting: pendingDeleteTheme
        ) { theme in
            Button("删除", role: .destructive) {
                manager.deleteTheme(id: theme.id)
                profileManager?.forgetChatTheme(theme.id)
                pendingDeleteTheme = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteTheme = nil
            }
        } message: { theme in
            let users = (profileManager?.profiles ?? []).filter { $0.chatAppearance?.themeId == theme.id }.map(\.name)
            Text(users.isEmpty
                 ? "这套主题的背景图会一起删掉，不能恢复。"
                 : "\(users.joined(separator: "、")) 在用，删了回到界面主题。这套主题的背景图会一起删掉，不能恢复。")
        }
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    /// 点行 / 建完 / 复制完：界面 = 切界面主题；人 = 写那一层（当前层经镜像立刻生效）
    private func apply(_ id: String?) {
        do { try themeTarget.apply(id, manager, profileManager) }
        catch { saveError = error.localizedDescription }
    }

    // MARK: - 动作

    @ViewBuilder
    private func menuItems(for theme: AppThemeDefinition) -> some View {
        // 内置主题也给编辑入口：页里会弹「复制一份？」，复制完接着编辑那份新的（不切换当前主题）
        Button {
            editTarget = EditTarget(kind: .colors, themeId: theme.id)
        } label: {
            Label("编辑颜色", systemImage: "paintpalette")
        }
        Button {
            editTarget = EditTarget(kind: .background, themeId: theme.id)
        } label: {
            Label("编辑聊天背景", systemImage: "photo")
        }
        if theme.isEditable {
            Button {
                renameText = theme.name
                renameTarget = theme
            } label: {
                Label("重命名", systemImage: "pencil")
            }
        }
        Button {
            startCopy(from: theme)
        } label: {
            Label("复制一份", systemImage: "doc.on.doc")
        }
        if theme.isDeletable {
            Button(role: .destructive) {
                pendingDeleteTheme = theme
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    #if os(iOS)
    @ViewBuilder
    private func swipeItems(for theme: AppThemeDefinition) -> some View {
        if theme.isDeletable {
            Button(role: .destructive) {
                pendingDeleteTheme = theme
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        Button {
            startCopy(from: theme)
        } label: {
            Label("复制一份", systemImage: "doc.on.doc")
        }
        .tint(Theme.branchIndicator)
    }
    #endif

    private func startCopy(from theme: AppThemeDefinition) {
        pendingThemeName = theme.isCustomDraft ? "我的主题" : "\(theme.name) 副本"
        copySource = theme
    }

    /// 「+」：先从当前主题建出一套（不切换），再开全页编辑器；名字「新主题」撞了就「新主题 2 / 3…」
    private func startCreate() {
        let taken = Set(manager.themeDefinitions.map(\.name))
        var name = "新主题"
        var n = 2
        while taken.contains(name) {
            name = "新主题 \(n)"
            n += 1
        }
        guard let id = manager.saveThemeCopy(from: targetThemeId, name: name, select: false) else { return }
        editTarget = EditTarget(kind: .create, themeId: id)
    }
}

/// 主题列表的一行：迷你聊天预览 + 名字 + 一句身份 + 选中勾。勾用正文色，不做薄荷底薄荷勾（09-09 禁深绿套浅绿）。
private struct ThemeListRow: View {
    @Environment(\.settingsMetrics) private var m
    let theme: AppThemeDefinition
    let tokenSet: ThemeTokenSet
    let backgroundImageURL: URL?
    let backgroundStyle: ThemeBackgroundStyle
    let scheme: ColorScheme
    let isSelected: Bool
    /// 「跟随界面主题」那一行借界面主题的预览，名字和小字自己给
    var title: String? = nil
    var note: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ThemeChatPreview(
                tokenSet: tokenSet,
                scheme: scheme,
                backgroundImageURL: backgroundImageURL,
                backgroundStyle: backgroundStyle,
                size: .list
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? theme.name)
                    .font(m.action)
                    .foregroundColor(Theme.textPrimary)
                Text(note ?? subtitle)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(m.secondary.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .accessibilityLabel("当前使用")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())   // mac：plain 按钮整行可点，不只文字
    }

    private var subtitle: String {
        if theme.isBuiltIn {
            return "内置"
        }
        return theme.hasBackgroundImage ? "带背景图" : "自定义"
    }
}

/// 复制一份新主题：起名 + 预览 + 保存并切换（长按 / 左滑「复制一份」用；「+」不走这里）。
private struct ThemeSaveSheet: View {
    @Environment(\.settingsMetrics) private var m
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Binding var name: String
    let previewTokenSet: ThemeTokenSet
    let previewBackgroundImageURL: URL?
    let previewBackgroundStyle: ThemeBackgroundStyle
    let onSave: () -> Void

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var scheme: ColorScheme {
        (themeManager ?? ThemeManager.shared).activeScheme
    }

    var body: some View {
        NavigationStack {
            List {
                Section("名称") {
                    TextField("新主题", text: $name)
                        .textFieldStyle(.plain)
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("预览") {
                    ThemeChatPreview(
                        tokenSet: previewTokenSet,
                        scheme: scheme,
                        backgroundImageURL: previewBackgroundImageURL,
                        backgroundStyle: previewBackgroundStyle,
                        size: .pinned
                    )
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section {
                    Button("保存并切换过去") {
                        onSave()
                        dismiss()
                    }
                    .foregroundColor(Theme.branchIndicator)
                    .disabled(trimmedName.isEmpty)
                } footer: {
                    Text("保存后自动切到新主题，颜色和聊天背景都从它开始改。")
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.sidebar)
            #endif
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("复制一份")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ThemeBackgroundView(
                fill: Theme.sidebarBg,
                imageURL: previewBackgroundImageURL,
                scheme: scheme,
                backgroundStyle: previewBackgroundStyle
            )
            .ignoresSafeArea()
        }
        #if os(macOS)
        .frame(width: 430, height: 380)   // mac sheet 不给尺寸会塌成只剩标题 + 完成
        #endif
    }
}

/// 四个色点（主背景 · 侧栏 · 辅助底 · 分支强调），外观页「颜色」行右侧用。
struct ThemePalettePreview: View {
    let colors: [Color]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { entry in
                Circle()
                    .fill(entry.element)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
            }
        }
        .padding(.trailing, 4)
    }
}
