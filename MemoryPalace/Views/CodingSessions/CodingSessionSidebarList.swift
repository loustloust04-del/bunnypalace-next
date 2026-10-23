#if os(macOS)
import SwiftUI

/// 左栏面板组的 Code tab（plan-wake-native N0 / N1，⧫2 按项目划分）：项目分组的编程会话列表 + 顶部筛选框 / 搜索 ⌘K / 刷新 ⌘R / 扫描进度。
/// 搜索钮 = 全局搜索预选「编程会话」（它在视图树上时先于菜单吃 ⌘K）。
/// 展开哪些项目放在 Library（搜索命中后要能替它展开、翻页、滚到那条）。
struct CodingSessionSidebarList: View {
    /// 选中会话后（与选对话同语义：切回聊天页 + 收左栏）
    var onOpen: () -> Void = {}

    private var library: CodingSessionLibrary { .shared }
    @Environment(MacWorkspaceActions.self) private var workspaceActions: MacWorkspaceActions?
    @FocusState private var titleFocused: Bool
    /// 行内改名（plan-mac-code-mode-gaps §2，照对话行 `SidebarView` 那套：出现即聚焦、回车 / 失焦确认、Esc 取消）
    @State private var renamingKey: String?
    @State private var renameText = ""
    @State private var renameOriginal = ""
    @FocusState private var renameFocused: Bool
    @State private var actionError: String?

    var body: some View {
        // 在 body 里直接读：只在 Binding 的 get 闭包里读，观察追踪跟不上，钩子 / 头部按钮改了值侧栏不重绘、sheet 时弹时不弹
        let locationsPresented = library.isLocationsPresented
        VStack(spacing: 0) {
            header
            if library.totalSessions == 0 {
                emptyState
            } else {
                controls
                if library.filteredTotal == 0 {
                    filteredEmpty
                } else {
                    list
                }
            }
        }
        .sheet(isPresented: Binding(get: { locationsPresented }, set: { library.isLocationsPresented = $0 })) {
            CodingLocationsSheet()
        }
        .alert("没能继续这条会话", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .onAppear(perform: autoExpandFirst)
        .onChange(of: library.projects.first?.path) { _, _ in autoExpandFirst() }
        .onChange(of: library.listMode) { _, _ in autoExpandFirst() }
    }

    /// 顶行和「对话」tab 的搜索行同一个位置同一副样子（`SidebarView.macSearchToolbar`：32 高的框 + 两颗 26 宽的钮）：
    /// 框 = 筛选标题 / 项目名（全文搜索走 ⌘K，这里不重复），钮 = ⌘K 全局搜索（预选「编程会话」）+ 刷新。
    /// 「编程会话」四个字不再写：面板头的 tab 已经是「Code」
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                titleField
                Button { workspaceActions?.search(kinds: [.coding]) } label: {
                    Image(systemName: "text.magnifyingglass")
                }
                .buttonStyle(MacShellButton(width: 26))
                .keyboardShortcut("k", modifiers: .command)
                .help("搜索编程会话（⌘K）")
                Button {
                    library.refresh()
                    library.syncRemoteHosts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(MacShellButton(width: 26))
                .keyboardShortcut("r", modifiers: .command)
                .disabled(library.isScanning)
                .help("刷新（⌘R）")
            }
            .padding(12)
            statusRow
        }
    }

    /// 形态 / 条数 / 扫描进度 / 排序 / 位置 / 统计
    private var statusRow: some View {
        HStack(spacing: 6) {
            if library.totalSessions > 0 {
                HStack(spacing: 2) {
                    modeButton("项目", .projects)
                    modeButton("时间", .timeline)
                }
                .padding(2)
                .background(Capsule().fill(Theme.mainBg.opacity(0.8)))
                .overlay(Capsule().stroke(Theme.accent.opacity(0.5), lineWidth: 0.5))
                Text("\(library.filteredTotal)")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .monospacedDigit()
                    .help("当前筛选下的会话数")
            }
            Spacer(minLength: 4)
            if let progress = library.progress, progress.scanning {
                ProgressView().controlSize(.mini)
                if progress.total > 0 {
                    Text("\(progress.done)/\(progress.total)")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .monospacedDigit()
                }
            } else if !library.syncingHosts.isEmpty {
                // 远程同步中（N4，Wake 侧栏状态行）：扫描进度优先，同步只在没在扫时露出来
                ProgressView().controlSize(.mini)
                Text(library.syncingHosts.count == 1 ? "正在同步 \(library.syncingHosts.first ?? "")…" : "正在同步 \(library.syncingHosts.count) 台远程主机…")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if library.totalSessions > 0 && library.listMode == .timeline { sortMenu }
            headerButton("folder.badge.gearshape", help: "会话位置") { library.isLocationsPresented = true }
            headerButton("chart.bar.xaxis", help: "统计", on: library.isInsightsPresented) {
                library.toggleInsights()
                if library.isInsightsPresented { onOpen() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func headerButton(_ icon: String, help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: Theme.F.caption, weight: .medium))
                .foregroundColor(on ? Theme.textPrimary : Theme.textMuted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if library.listMode == .timeline {
                        timelineRows
                    } else {
                        projectRows
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: library.revealKey) { _, key in
                guard let key else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(key, anchor: .center) }
            }
        }
    }

    private func projectRow(_ project: CodingProjectInfo) -> some View {
        let isOpen = library.expandedProjects.contains(project.path)
        return Button {
            if isOpen {
                library.expandedProjects.remove(project.path)
            } else {
                library.expandedProjects.insert(project.path)
                if library.sessions(in: project.path).isEmpty { library.loadMore(project: project.path) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: "folder")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                Text(project.path.isEmpty ? "未知项目" : project.name)
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(project.sessionCount)")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.path)
    }

    @ViewBuilder
    private var projectRows: some View {
        ForEach(library.projects) { project in
            projectRow(project)
            if library.expandedProjects.contains(project.path) {
                ForEach(library.sessions(in: project.path)) { meta in
                    sessionRow(meta).id(meta.key)
                    childRows(of: meta, inTimeline: false)
                }
                if library.hasMore(in: project.path) && !library.sessions(in: project.path).isEmpty {
                    Button("更多…") { library.loadMore(project: project.path) }
                        .buttonStyle(.plain)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.leading, 34)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    /// 时间视图：Pinned + 日历分组（按时间倒序时），否则平铺；距末尾 20 行预取下一页
    @ViewBuilder
    private var timelineRows: some View {
        let sessions = library.timeline.all
        let groups = CodingSessionGroup.build(sessions, pinnedCount: library.timeline.pinned.count, filter: library.listFilter())
        ForEach(groups, id: \.label) { group in
            if !group.label.isEmpty { groupHeader(group.label) }
            ForEach(group.range, id: \.self) { index in
                sessionRow(sessions[index], inTimeline: true)
                    .id(sessions[index].key)
                    .onAppear {
                        if index >= sessions.count - 20 && library.hasMoreTimeline { library.loadMoreTimeline() }
                    }
                childRows(of: sessions[index], inTimeline: true)
            }
        }
    }

    /// 分组标题：标签 + 右侧低对比度细线（Wake 会话流）
    private func groupHeader(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: Theme.F.caption, weight: .medium))
                .foregroundColor(Theme.textMuted)
            Rectangle()
                .fill(Theme.textMuted.opacity(0.2))
                .frame(height: 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// 展开了的根会话下面的子会话行（跟着根留在同一个分组里）
    @ViewBuilder
    private func childRows(of root: CodingSessionMeta, inTimeline: Bool) -> some View {
        if library.expandedRoots.contains(root.key) {
            ForEach(library.children[root.key] ?? []) { child in
                sessionRow(child, inTimeline: inTimeline, depth: 1).id(child.key)
            }
        }
    }

    private func sessionRow(_ meta: CodingSessionMeta, inTimeline: Bool = false, depth: Int = 0) -> some View {
        let selected = library.selectedKey == meta.key
        let childCount = depth == 0 ? library.childCounts[meta.key] ?? 0 : 0
        let expanded = library.expandedRoots.contains(meta.key)
        let leading: CGFloat = (inTimeline ? 12 : 34) + (depth > 0 ? 16 : 0)
        // 按创建时间排序时行尾显示创建时间，其余显示更新时间（Wake）
        let time = inTimeline && library.sort == .created ? meta.createdAt : meta.updatedAt
        return Button {
            // 已选中的根会话再点一下 = 展开 / 收起子会话（Wake）
            if selected && childCount > 0 {
                library.toggleRoot(meta.key)
            } else {
                library.select(meta.key)
                onOpen()
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if childCount > 0 {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(Theme.textMuted)
                            .frame(width: 10)
                            .help("\(childCount) 个子会话 · 选中后再点一下\(expanded ? "收起" : "展开")")
                    }
                    // 标题 / 副信息 / 时间的层级对齐「对话」tab 的行（`MacConversationRow`：13 中粗标题、10 号时间、薄荷选中底）
                    if renamingKey == meta.key {
                        TextField("会话名", text: $renameText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                            .focused($renameFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { renamingKey = nil }
                            .onChange(of: renameFocused) { _, focused in if !focused { commitRename() } }
                            .onAppear { renameFocused = true }
                    } else {
                        Text(CodingSessionFormat.title(meta))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    if library.state.isFavorite(meta.key) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.branchIndicator)
                    }
                    if library.state.isPinned(meta.key) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(CodingSessionFormat.color(meta.agent))
                        .frame(width: 6, height: 6)
                        .help(meta.agent.displayName)
                    Text(inTimeline ? (meta.projectName.isEmpty ? "未知项目" : meta.projectName) : meta.agent.displayName)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                    // 远程会话的主机（N4）：薄荷字无底——不垫浅薄荷底（配色铁律），与灰色的项目 / 家名拉开
                    if !meta.host.isEmpty {
                        Text("@\(meta.host)")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.branchIndicator)
                            .lineLimit(1)
                            .help("远程会话 · \(meta.host)")
                    }
                    Spacer(minLength: 4)
                    Text(CodingSessionFormat.relative(time))
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                        .help(CodingSessionFormat.absolute(time))
                }
            }
            .padding(.leading, leading)
            .overlay(alignment: .leading) {
                // 子会话行左侧一道细竖线，看得出挂在上面那条根会话下
                if depth > 0 {
                    Capsule()
                        .fill(Theme.textMuted.opacity(0.38))
                        .frame(width: 2)
                        .padding(.vertical, 6)
                        .padding(.leading, leading - 10)
                }
            }
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? ShellStyle.selection : Color.clear).padding(.horizontal, 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(CodingSessionFormat.title(meta))
        .contextMenu {
            CodingSessionActionItems(meta: meta, onRename: { startRename(meta) }, onError: { actionError = $0 })
        }
    }

    private func startRename(_ meta: CodingSessionMeta) {
        renameText = CodingSessionFormat.title(meta)
        renameOriginal = CodingSessionFormat.title(meta, override: nil)
        renamingKey = meta.key
    }

    /// 回车和失焦都会进来：只落一次
    private func commitRename() {
        guard let key = renamingKey else { return }
        renamingKey = nil
        // 改回原名 = 清掉改名（不存一份和原名相同的，agent 那边标题变了才跟得上）
        let text = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        library.rename(key, to: text == renameOriginal ? "" : text)
    }

    // MARK: - 形态 / 范围 / 标题筛选 / 排序

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
            HStack(spacing: 4) {
                chip("全部", scope: .all)
                chip("收藏", scope: .favorites, icon: "star")
                ForEach(library.presentAgents, id: \.self) { agent in
                    chip(agent.shortName, scope: .agent(agent), dot: CodingSessionFormat.color(agent))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func modeButton(_ title: String, _ mode: CodingListMode) -> some View {
        let on = library.listMode == mode
        return Button { library.setListMode(mode) } label: {
            Text(title)
                .font(.system(size: Theme.F.caption, weight: on ? .medium : .regular))
                .foregroundColor(on ? Theme.textPrimary : Theme.textMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(on ? Theme.accent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 范围胶囊：选中 = 浅薄荷底 + 正文色字（不叠薄荷字）
    private func chip(_ title: String, scope: CodingListScope, icon: String? = nil, dot: Color? = nil) -> some View {
        let on = library.scope == scope
        return Button { library.setScope(scope) } label: {
            HStack(spacing: 4) {
                if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
                if let icon {
                    Image(systemName: on ? icon + ".fill" : icon)
                        .font(.system(size: 9))
                }
                Text(title)
            }
            .font(.system(size: Theme.F.caption, weight: on ? .medium : .regular))
            .foregroundColor(on ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? Theme.accent : Color.clear))
            .overlay(Capsule().stroke(Theme.accent.opacity(on ? 0 : 0.8), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 只筛当前范围的标题 / 项目名（全文搜索走 ⌘K，这里不重复）。
    /// 样子同「对话」tab 的搜索框（`SidebarView.macSearchToolbar`）：32 高、正文底、7 圆角、聚焦描薄荷边
    private var titleField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
            TextField("筛选编程会话…", text: Binding(get: { library.titleQuery }, set: { library.setTitleQuery($0) }))
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .onExitCommand {
                    library.setTitleQuery("")
                    titleFocused = false
                }
            if !library.titleQuery.isEmpty {
                Button { library.setTitleQuery("") } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .help("清除筛选")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(titleFocused ? Theme.branchIndicator : ShellStyle.hairline, lineWidth: 0.5)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: Binding(get: { library.sort }, set: { library.setSort($0, ascending: library.ascending) })) {
                ForEach(CodingSortKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .pickerStyle(.inline)
            Picker("方向", selection: Binding(get: { library.ascending }, set: { library.setSort(library.sort, ascending: $0) })) {
                Text("降序").tag(false)
                Text("升序").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: Theme.F.caption, weight: .medium))
                .foregroundColor(Theme.textMuted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("排序：\(library.sort.displayName) · \(library.ascending ? "升序" : "降序")")
    }

    private var filteredEmpty: some View {
        VStack(spacing: 8) {
            Text("没有符合筛选的会话")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textSecondary)
            Button("清除筛选") { library.clearFilters() }
                .buttonStyle(.plain)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.branchIndicator)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if library.isScanning {
                ProgressView().controlSize(.small)
                Text("正在建立索引…")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textSecondary)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 22))
                    .foregroundColor(Theme.textMuted)
                Text("没有找到编程会话")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textSecondary)
                Text("会读本机 Claude Code、Codex、Kimi Code 等 16 家编程 agent 的会话目录。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
            }
            if let error = library.lastError {
                Text(error)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 什么都没展开时展开第一个项目（N0-8：首扫期间第一名换人后也跟上）
    private func autoExpandFirst() {
        guard library.listMode == .projects, library.expandedProjects.isEmpty, let first = library.projects.first else { return }
        library.expandedProjects.insert(first.path)
        if library.sessions(in: first.path).isEmpty { library.loadMore(project: first.path) }
    }
}

/// code 组的显示格式（标题占位、agent 色、中文相对时间）
enum CodingSessionFormat {
    /// 显示名：改过名先用改的（`CodingSessionState.titleOverrides`），否则会话原名
    @MainActor
    static func title(_ meta: CodingSessionMeta) -> String {
        title(meta, override: CodingSessionState.shared.titleOverride(meta.key))
    }

    static func title(_ meta: CodingSessionMeta, override: String?) -> String {
        if let override, !override.isEmpty { return override }
        return meta.title == CodingLimits.untitled || meta.title.isEmpty ? "未命名会话" : meta.title
    }

    /// agent 功能识别色（Wake 品牌色；色点旁始终有名字）
    static func color(_ agent: CodingAgent) -> Color {
        switch agent {
        case .kimi: return Theme.textMuted
        default: return colorHex(agent).map { Color(hex: $0) } ?? Theme.textMuted
        }
    }

    /// 16 家色点（MP 自拟无蓝无黄低饱和色板，plan-wake-native-n3 §2.6；小样 docs/shots/wake-native/n3-agent-palette.html）。
    /// 前三家沿用 N0；Kimi 用弱色灰（nil）
    static func colorHex(_ agent: CodingAgent) -> UInt? {
        switch agent {
        case .claudeCode: return 0xD97757
        case .codex: return 0x12A06B
        case .grok: return 0x4A4744
        case .dsh: return 0xB56576
        case .cursor: return 0xA67B5B
        case .opencode: return 0x6F8F5A
        case .pi: return 0x5E9E93
        case .omp: return 0x3F6F68
        case .kiro: return 0xA0708E
        case .kimi: return nil
        case .gemini: return 0xA2574A
        case .copilot: return 0x8FA88A
        case .antigravity: return 0xB0A79D
        case .qoder: return 0x4E7A55
        case .hermes: return 0x8E5570
        case .openclaw: return 0xC08A6A
        }
    }

    static func relative(_ ms: Int64, now: Date = Date()) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.defaultDigits).day())
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day())
    }

    static func absolute(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            .formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    /// 「模型 · via 来源 · N 条消息 · tokens」。原来摊在详情页顶上，她 09-16 让它挪进顶部条那颗的菜单里
    static func summaryLine(_ meta: CodingSessionMeta) -> String {
        var parts: [String] = []
        if let model = meta.model, !model.isEmpty { parts.append(model) }
        if let source = meta.source, !source.isEmpty { parts.append("via \(source)") }
        parts.append("\(meta.messageCount) 条消息")
        if let tokens = meta.tokensUsed, tokens > 0 { parts.append("\(tokens.formatted()) tokens") }
        return parts.joined(separator: " · ")
    }
}
#endif
