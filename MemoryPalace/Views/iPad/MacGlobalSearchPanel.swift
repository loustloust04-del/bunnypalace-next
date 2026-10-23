import SwiftUI
import SwiftData

#if os(macOS)
import AppKit

/// ⌘K 全局搜索（⇧⌘F 为别名）：照 `~/Downloads/mint-workspace-global-search.html` 的 `#search-dialog` 一比一搭——
/// 半透明遮罩 + 顶部「搜索 / Query」切换 + 764 宽圆角卡（输入行 / 类型条 / 高级筛选 / Query 语法 / 条件 chip /
/// 结果标题行 / 结果列表 / 键位底栏）。尺寸取原型桌面档的 CSS 数值，颜色全部走 Theme / ShellStyle token。
/// 数据由 `MacGlobalSearchEngine` 接现有搜索；落点复用 `navigateToSearchResult` / `RightPanelNavigator`。
struct MacGlobalSearchOverlay: View {
    let profileId: String
    let profileName: String
    let viewModel: ConversationViewModel
    let focusToken: Int
    /// 打开时预选的类型（code 组里按 ⌘K = 编程会话）
    var presetKinds: [MacSearchKind] = []
    let onOpenChat: () -> Void
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            // 原型：padding-top = clamp(34px, 13vh, 124px)；卡最高 = 视口 - 顶距 - 80
            let top = min(max(34, geo.size.height * 0.13), 124)
            ZStack(alignment: .top) {
                Color.black.opacity(Theme.activeScheme == .dark ? 0.42 : 0.24)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityHidden(true)
                MacGlobalSearchPanel(profileId: profileId, profileName: profileName, viewModel: viewModel,
                                     focusToken: focusToken, maxCardHeight: max(260, geo.size.height - top - 80),
                                     onOpenChat: onOpenChat, onClose: onClose, presetKinds: presetKinds)
                    .frame(width: min(764, max(320, geo.size.width - 48)))
                    .padding(.top, top)
            }
        }
        .transition(.opacity)
    }
}

private enum Palette {
    static var ink: Color { Theme.textPrimary }
    static var secondary: Color { Theme.textSecondary }
    static var muted: Color { Theme.textMuted }
    static var card: Color { Theme.mainBg }
    /// 选中行 / 按下的 chip（原型 #edf2e8）
    static var pressed: Color { Theme.accent }
    static var hover: Color { ShellStyle.hover }
    static var tint: Color { Theme.branchIndicator }
    /// 高级筛选 / 语法 / 底栏的浅底（原型 #f8faf4 / #fbfcf7）
    static var wash: Color { Theme.sidebarBg.opacity(0.55) }
    static var line: Color { Theme.textSecondary.opacity(0.14) }
    static var mark: Color { Theme.branchIndicator.opacity(0.28) }
    static var rim: Color { Color.white.opacity(Theme.activeScheme == .dark ? 0.06 : 0.9) }
}

struct MacGlobalSearchPanel: View {
    enum Mode { case search, query }

    let profileId: String
    let profileName: String
    let viewModel: ConversationViewModel
    let focusToken: Int
    let maxCardHeight: CGFloat
    let onOpenChat: () -> Void
    let onClose: () -> Void
    /// 预填（侧栏带关键词打开、自检渲染用）；含 key:value 时用 `.query`
    var initialQuery = ""
    var initialMode: Mode = .search
    /// 预选类型（code 组里按 ⌘K 打开 = `type:coding`）；每次 focusToken 变化时重新套用
    var presetKinds: [MacSearchKind] = []

    @Environment(\.modelContext) private var context
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(GlobalWorldBookManager.self) private var globalWBManager: GlobalWorldBookManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    @FocusState private var inputFocused: Bool

    @State private var mode: Mode = .search
    @State private var text = ""
    @State private var free = ""
    @State private var words: [String] = []
    @State private var filters = MacSearchFilters()
    @State private var errors: [String] = []
    @State private var advanced = false
    @State private var help = false
    @State private var selected = 0
    @State private var results: [MacSearchRecord] = []
    @State private var searching = false
    @State private var openError: String?
    @State private var scrollTarget: String?
    @State private var listContentHeight: CGFloat = 0

    private struct SearchKey: Equatable {
        var words: [String]
        var filters: MacSearchFilters
        var valid: Bool
    }

    private var codingEnabled: Bool { MacWorkspacePreferences.shared.showCodingSessions }
    private var typeChips: [MacSearchKind?] { [nil] + MacGlobalSearchEngine.availableKinds(codingEnabled: codingEnabled) }
    private var allErrors: [String] { errors + filters.validationErrors }
    private var inputLocked: Bool { mode == .query && !errors.isEmpty }
    private var onlyUnsupported: Bool { !filters.types.isEmpty && filters.types.allSatisfy { !$0.isSupported } }

    var body: some View {
        VStack(spacing: 14) {
            modeSwitch
            card
        }
        .onAppear {
            if !initialQuery.isEmpty {
                mode = initialMode
                help = initialMode == .query
                text = initialQuery
                readInput()
            }
            applyPreset()
            focusInput()
        }
        .onChange(of: focusToken) { _, _ in
            applyPreset()
            focusInput()
        }
        .onChange(of: text) { _, _ in readInput() }
        .task(id: SearchKey(words: words, filters: filters, valid: allErrors.isEmpty)) { await runSearch() }
        .onExitCommand(perform: onClose)
    }

    // MARK: - 顶部「搜索 / Query」

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            modeButton("搜索", .search)
            modeButton("Query", .query)
        }
        .padding(3)
        .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.rim, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("搜索输入方式")
    }

    private func modeButton(_ title: String, _ value: Mode) -> some View {
        let on = mode == value
        return Button { setMode(value) } label: {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(on ? Palette.ink : Palette.secondary)
                .frame(minWidth: 42)
                .padding(.horizontal, 17)
                .frame(height: 29)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Palette.card)
                            .shadow(color: Color.black.opacity(0.07), radius: 2.5, y: 1)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - 卡片

    private var card: some View {
        VStack(spacing: 0) {
            inputRow
            typeBar
            if advanced { advancedPanel }
            if help { queryHelp }
            if !filters.activeConditions.isEmpty && errors.isEmpty { conditionChips }
            resultHeading
            resultList
            footer
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.rim, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.16), radius: 34, y: 22)
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 6)
        .foregroundStyle(Palette.ink)
    }

    private var inputRow: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Palette.secondary)
                .frame(width: 20)
            TextField("", text: $text,
                      prompt: Text(mode == .query ? "关键词 type:memory within:30d" : "搜索整个工作区…")
                        .font(mode == .query ? .system(size: 13) : .system(size: 17))
                        .foregroundColor(Palette.muted))
                .textFieldStyle(.plain)
                .font(mode == .query ? .system(size: 14, design: .monospaced) : .system(size: 18))
                .focused($inputFocused)
                .onSubmit { open(selected) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.escape) { onClose(); return .handled }
                .onKeyPress(keys: [.tab]) { press in cycleType(press.modifiers.contains(.shift) ? -1 : 1) }
                .accessibilityIdentifier("mac-workspace-search")
                .accessibilityLabel("搜索所有内容")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MacSearchHoverStyle(radius: 7, active: false))
            .help("关闭 · Esc")
            .accessibilityLabel("关闭全局搜索")
        }
        .padding(.leading, 23)
        .padding(.trailing, 19)
        .padding(.top, 8)
        .frame(height: 69)
    }

    private var typeBar: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(typeChips, id: \.self) { kind in
                        typeChip(kind)
                    }
                }
            }
            Button {
                advanced.toggle()
                if advanced { help = false }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .foregroundStyle(advanced ? Palette.ink : Palette.secondary)
                    .frame(width: 33, height: 31)
                    .background(advanced ? Palette.pressed : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if !filters.activeConditions.isEmpty {
                            Circle().fill(Palette.tint).frame(width: 5, height: 5)
                                .overlay(Circle().strokeBorder(Palette.card, lineWidth: 1.5).frame(width: 8, height: 8))
                                .padding(3)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("高级筛选")
            .accessibilityLabel((advanced ? "收起" : "展开") + "高级筛选"
                                + (filters.activeConditions.isEmpty ? "" : "，已有 \(filters.activeConditions.count) 个条件"))
        }
        .padding(.leading, 21)
        .padding(.trailing, 19)
        .padding(.top, 8)
        .padding(.bottom, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func typeChip(_ kind: MacSearchKind?) -> some View {
        let on = kind.map { filters.types.contains($0) } ?? filters.types.isEmpty
        return Button {
            updateFilters { $0.types = kind.map { [$0] } ?? [] }
            inputFocused = true
        } label: {
            Text(kind?.label ?? "全部")
                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Palette.ink : Palette.secondary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(on ? Palette.pressed : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(MacSearchHoverStyle(radius: 7, active: on))
        .disabled(inputLocked)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - 高级筛选（原型 7 行）

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterRow("范围") {
                ForEach(MacSearchFilters.Location.allCases, id: \.self) { loc in
                    option(MacSearchFilters.label(loc), on: filters.location == loc,
                           disabled: loc == .current && viewModel.selectedConversation == nil) {
                        updateFilters { $0.location = loc }
                    }
                }
            }
            filterRow("匹配") {
                ForEach(MacSearchFilters.Match.allCases, id: \.self) { m in
                    option(MacSearchFilters.label(m), on: filters.match == m) { updateFilters { $0.match = m } }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                filterRow("时间") {
                    ForEach(MacSearchFilters.periodOptions, id: \.0) { value, label in
                        option(label, on: filters.period == value) {
                            updateFilters {
                                $0.period = value
                                if value != "custom" { $0.after = ""; $0.before = "" }
                            }
                        }
                    }
                }
                if filters.period == "custom" { dateRange }
            }
            filterRow("角色") {
                ForEach(MacSearchFilters.Author.allCases, id: \.self) { a in
                    option(MacSearchFilters.label(a), on: filters.author == a) { updateFilters { $0.author = a } }
                }
            }
            filterRow("排序") {
                ForEach(MacSearchFilters.Sort.allCases, id: \.self) { s in
                    option(MacSearchFilters.label(s), on: filters.sort == s) { updateFilters { $0.sort = s } }
                }
            }
            filterRow("格式") {
                Picker("", selection: Binding(get: { filters.extensions.joined(separator: ",") },
                                              set: { v in updateFilters { $0.extensions = v.isEmpty ? [] : v.components(separatedBy: ",") } })) {
                    Text("所有格式").tag("")
                    ForEach(MacSearchFilters.extensionOptions, id: \.self) { Text("." + $0).tag($0) }
                    if filters.extensions.count > 1 || filters.extensions.contains(where: { !MacSearchFilters.extensionOptions.contains($0) }) {
                        Text(filters.extensions.map { "." + $0 }.joined(separator: " / ")).tag(filters.extensions.joined(separator: ","))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(inputLocked)
                HStack(spacing: 6) {
                    Text("状态").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Picker("", selection: Binding(get: { filters.starred }, set: { v in updateFilters { $0.starred = v } })) {
                        Text("全部").tag(false)
                        Text("仅收藏").tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(inputLocked)
                }
                .padding(.leading, 8)
            }
            Text("日期按更新时间；对话中的角色筛选只匹配该角色的消息。文件只比对文件名与开头 4 KB，便笺暂不支持。")
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
                .lineSpacing(3)
                .padding(.top, 8)
                .padding(.leading, 54)
        }
        .padding(.horizontal, 22)
        .padding(.top, 15)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var dateRange: some View {
        HStack(spacing: 7) {
            Text("从")
            DatePicker("", selection: Binding(get: { MacSearchQuery.calendarDate(filters.after) ?? Date() },
                                              set: { d in updateFilters { $0.after = MacSearchQuery.dayString(d); $0.period = "custom" } }),
                       displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field).fixedSize()
            Text("到")
            DatePicker("", selection: Binding(get: { MacSearchQuery.calendarDate(filters.before) ?? Date() },
                                              set: { d in updateFilters { $0.before = MacSearchQuery.dayString(d); $0.period = "custom" } }),
                       displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field).fixedSize()
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.muted)
        .disabled(inputLocked)
        .padding(.leading, 52)
        .padding(.top, 5)
        .padding(.bottom, 9)
    }

    private func filterRow<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .frame(width: 42, alignment: .leading)
            HStack(spacing: 7) { content() }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 35)
    }

    private func option(_ label: String, on: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: on ? .medium : .regular))
                .foregroundStyle(on ? Palette.ink : Palette.secondary)
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(on ? Palette.pressed : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(MacSearchHoverStyle(radius: 6, active: on))
        .disabled(disabled || inputLocked)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - Query 语法

    private var queryHelp: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("筛选与 Query 使用同一套条件")
                Spacer()
                Button("收起语法") { help = false; inputFocused = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.ink)
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondary)
            .padding(.bottom, 8)
            Group {
                Text(syntax([("type:", "类型"), ("in:", "位置"), ("match:", "字段"), ("by:", "角色"), ("within:", "近几天")]))
                Text(syntax([("after:", "起始日"), ("before:", "结束日"), ("ext:", "格式"), ("sort:", "排序"), ("is:starred", "收藏")]))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Palette.secondary)
            .lineSpacing(6)
            HStack(spacing: 7) {
                ForEach(MacSearchQuery.examples, id: \.self) { example in
                    Button {
                        mode = .query
                        help = false
                        text = example
                        readInput()
                        inputFocused = true
                    } label: {
                        Text(example)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 9)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func syntax(_ pairs: [(String, String)]) -> AttributedString {
        var out = AttributedString()
        for (i, pair) in pairs.enumerated() {
            var code = AttributedString(pair.0)
            code.foregroundColor = Palette.ink
            out += code
            out += AttributedString(" " + pair.1 + (i < pairs.count - 1 ? "   " : ""))
        }
        return out
    }

    // MARK: - 条件 chip

    private var conditionChips: some View {
        MacSearchFlow(spacing: 6) {
            ForEach(Array(filters.activeConditions.enumerated()), id: \.offset) { _, item in
                Button {
                    updateFilters { $0.clear(item.key) }
                    inputFocused = true
                } label: {
                    HStack(spacing: 7) {
                        Text(item.label).lineLimit(1)
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink)
                    .padding(.leading, 9)
                    .padding(.trailing, 7)
                    .frame(height: 26)
                    .background(Palette.pressed, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除筛选：\(item.label)")
            }
            Button("清除筛选") { resetSearch(all: false) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .padding(4)
        }
        .padding(.horizontal, 21)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 结果

    private var resultHeading: some View {
        HStack(spacing: 12) {
            Text(headingLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
            Spacer(minLength: 0)
            Text(filters.scopeCaption)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 23)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var headingLabel: String {
        if !allErrors.isEmpty { return "查询未完成" }
        if searching && results.isEmpty { return "正在搜索…" }
        return !words.isEmpty || !filters.activeConditions.isEmpty ? "\(results.count) 个结果" : "最近更新"
    }

    /// 原型 `.search-results{min-height:100px;max-height:397px}`，卡整体不超过 `maxCardHeight`
    /// （视口 - 顶距 - 80）：列表高度 = 量出来的内容高，夹在 [100, 397] 里，再让出其余几段的高度
    private var listHeight: CGFloat {
        var chrome: CGFloat = 69 + 53 + 40 + 43
        if advanced { chrome += filters.period == "custom" ? 330 : 290 }
        if help { chrome += 130 }
        if !filters.activeConditions.isEmpty && errors.isEmpty { chrome += 40 }
        let content = results.isEmpty ? 190 : max(100, listContentHeight)
        return max(100, min(397, content, maxCardHeight - chrome))
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if !allErrors.isEmpty {
                    emptyState(symbol: "info.circle", title: "这条查询还差一点",
                               message: Array(NSOrderedSet(array: allErrors)).compactMap { $0 as? String }.joined(separator: " "),
                               button: ("重新开始", { resetSearch(all: true) }), warning: true)
                } else if onlyUnsupported {
                    emptyState(symbol: "note.text", title: "便笺暂不支持搜索",
                               message: "这边还没有便笺的数据源。贴在对话里的便签可以在「贴纸」里搜到。", button: nil)
                } else if results.isEmpty && !searching {
                    emptyState(symbol: "magnifyingglass", title: "没有找到匹配内容",
                               message: "试试少一个关键词，或放宽筛选范围。",
                               button: filters.activeConditions.isEmpty ? nil : ("清除筛选，保留关键词", { resetSearch(all: false) }))
                } else if results.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, record in
                            resultRow(record, index: index)
                                .id(record.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { listContentHeight = $0 }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: listHeight)
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
                scrollTarget = nil
            }
        }
        .overlay(alignment: .bottom) {
            if let openError {
                Text(openError)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Palette.card, in: Capsule())
                    .padding(.bottom, 6)
            }
        }
    }

    private func resultRow(_ r: MacSearchRecord, index: Int) -> some View {
        let isSelected = index == selected
        let contentHit = !words.isEmpty && words.contains { MacSearchQuery.contains(r.body, $0) }
        return HStack(spacing: 13) {
            Image(systemName: r.kind.symbol)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(isSelected ? Palette.ink : Palette.secondary)
                .frame(width: 21)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 15) {
                    (Text(highlight(r.title)) + Text("  " + r.kind.label).font(.system(size: 10)).foregroundColor(Palette.muted))
                        .font(.system(size: 15))
                        .foregroundColor(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let updated = r.updated {
                        Text(MacSearchQuery.dateLabel(updated))
                            .font(.system(size: 10.5))
                            .foregroundStyle(isSelected ? Palette.secondary : Palette.muted)
                            .fixedSize()
                    }
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 13)
                }
                if !words.isEmpty {
                    (Text(contentHit ? "正文" : "标题").font(.system(size: 10, weight: .medium)).foregroundColor(Palette.tint)
                     + Text("  ")
                     + Text(contentHit ? highlight(MacSearchQuery.excerpt(r.body, words: words)) : AttributedString("\(r.sub) · \(r.kind.label)")))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(minHeight: 45)
        .background(isSelected ? Palette.pressed : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open(index) }
        .onContinuousHover { phase in
            if case .active = phase, selected != index { selected = index }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(r.title)，\(r.kind.label)，\(r.sub)\(r.updated.map { "，" + MacSearchQuery.dateLabel($0) } ?? "")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func highlight(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        for r in MacSearchQuery.hitRanges(in: text, words: words) {
            guard let lower = AttributedString.Index(r.lowerBound, within: out),
                  let upper = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lower..<upper].backgroundColor = Palette.mark
            out[lower..<upper].foregroundColor = Palette.ink
        }
        return out
    }

    private func emptyState(symbol: String, title: String, message: String,
                            button: (String, () -> Void)?, warning: Bool = false) -> some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(warning ? Theme.danger.opacity(0.7) : Palette.muted)
                .padding(.bottom, 13)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(warning ? Theme.danger : Palette.ink)
                .padding(.bottom, 9)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .frame(maxWidth: 520)
            if let button {
                Button(button.0, action: button.1)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Palette.pressed, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line, lineWidth: 1))
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, 25)
        .padding(.top, 29)
        .padding(.bottom, 35)
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer").font(.system(size: 10)).foregroundStyle(Palette.tint)
                Text("本机搜索 · \(profileName.isEmpty ? "当前楼层" : profileName)").lineLimit(1)
                Button { help.toggle(); if help { advanced = false } } label: {
                    Text("语法")
                        .overlay(alignment: .bottom) {
                            Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [1, 1.5]))
                                .frame(height: 1).offset(y: 1).foregroundStyle(Palette.muted)
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                keyHint(["↑", "↓"], "选择")
                keyHint(["↵"], "打开")
                keyHint(["Tab"], "切类")
                keyHint(["Esc"], "关闭")
            }
            .accessibilityHidden(true)
        }
        .font(.system(size: 10))
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 21)
        .frame(height: 43)
        .background(Palette.wash)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func keyHint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line, lineWidth: 1))
            }
            Text(label)
        }
    }

    // MARK: - 行为（原型 readSearchInput / syncSearchInput / setSearchMode / updateSearchFilter / resetSearch）

    private func focusInput() {
        DispatchQueue.main.async {
            inputFocused = true
            // 已经开着再按 ⌘K：原型是聚焦 + 全选
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    private func readInput() {
        guard !isComposing else { return }
        openError = nil
        if mode == .query {
            let parsed = MacSearchQuery.parse(text)
            words = parsed.words
            free = parsed.words.map(MacSearchQuery.quote).joined(separator: " ")
            filters = parsed.filters
            errors = parsed.errors
        } else {
            free = text
            let lexed = MacSearchQuery.lex(free)
            words = lexed.tokens.map(\.value).filter { !$0.isEmpty }
            errors = lexed.errors
        }
    }

    private func syncInput() {
        let next = mode == .query ? MacSearchQuery.serialize(words: words, filters: filters) : free
        if text != next { text = next }
    }

    private func setMode(_ next: Mode) {
        guard next != mode else { return }
        if !errors.isEmpty { inputFocused = true; return }
        mode = next
        help = next == .query
        if next == .query { advanced = false }
        syncInput()
        inputFocused = true
    }

    private func updateFilters(_ change: (inout MacSearchFilters) -> Void) {
        guard !inputLocked else { return }
        change(&filters)
        syncInput()
    }

    private func resetSearch(all: Bool) {
        filters = MacSearchFilters()
        errors = []
        if all { free = ""; words = [] }
        syncInput()
        if all { text = "" }
        inputFocused = true
    }

    /// 预选类型：只在给了预设时改筛选，普通 ⌘K 重开不动用户已选的类型
    private func applyPreset() {
        let kinds = presetKinds.filter { typeChips.contains($0) }
        guard !kinds.isEmpty, !inputLocked, filters.types != kinds else { return }
        updateFilters { $0.types = kinds }
    }

    /// Tab / ⇧Tab 在类型 chip 间轮转（全部 → 对话 → 文件 → …）
    private func cycleType(_ delta: Int) -> KeyPress.Result {
        guard !isComposing, !inputLocked else { return .ignored }
        let chips = typeChips
        let current = filters.types.count == 1 ? (chips.firstIndex(of: filters.types[0]) ?? 0) : 0
        let next = chips[(current + delta + chips.count) % chips.count]
        updateFilters { $0.types = next.map { [$0] } ?? [] }
        return .handled
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        // 输入法选词时 ↑↓ 归输入法
        guard !isComposing else { return .ignored }
        guard !results.isEmpty else { return .handled }
        selected = (selected + delta + results.count) % results.count
        scrollTarget = results[selected].id
        return .handled
    }

    @MainActor private func runSearch() async {
        guard allErrors.isEmpty else { results = []; searching = false; return }
        searching = true
        do { try await Task.sleep(for: .milliseconds(words.isEmpty ? 0 : 200)) } catch { return }
        let snapshot = MacGlobalSearchEngine.Snapshot(
            profileId: profileId, profileName: profileName,
            currentConversationId: viewModel.selectedConversation?.id,
            cards: MacGlobalSearchEngine.cardSnapshots(cardManager?.cards ?? []),
            globalBooks: globalWBManager?.books ?? [],
            codingEnabled: codingEnabled)
        let found = await MacGlobalSearchEngine.search(words: words, filters: filters, snapshot: snapshot,
                                                        container: context.container)
        guard !Task.isCancelled else { return }
        results = found
        selected = 0
        if let first = found.first { scrollTarget = first.id }
        searching = false
    }

    private func open(_ index: Int) {
        guard allErrors.isEmpty, results.indices.contains(index) else { return }
        let record = results[index]
        switch record.route {
        case .conversation(let id, let nodeId):
            let pid = profileId
            let request = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id && $0.profileId == pid && !$0.isTrashed })
            guard let conversation = try? context.fetch(request).first else {
                openError = "这段对话已移走或删除，请重新搜索。"
                return
            }
            onClose()
            CodingSessionLibrary.shared.deactivate()
            onOpenChat()
            if let nodeId {
                viewModel.navigateToSearchResult(nodeId: nodeId, conversation: conversation, context: context)
            } else {
                viewModel.loadConversation(conversation, context: context)
            }
        case .rightPanel(let tool, let id):
            onClose()
            navigator?.pendingTarget = .init(tool: tool, id: id)
        case .coding(let hit):
            onClose()
            CodingSessionLibrary.shared.activate()
            CodingSessionLibrary.shared.open(hit)
        }
    }
}

/// hover 浅底（原型 `.search-type:hover` / `.search-filter-option:hover`）；已按下的不叠 hover
private struct MacSearchHoverStyle: ButtonStyle {
    let radius: CGFloat
    let active: Bool
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(!active && hovered ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovered = $0 }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// 条件 chip 会换行（原型 `flex-wrap:wrap`）
private struct MacSearchFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y + (line > 0 ? 0 : 0)), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
#endif
