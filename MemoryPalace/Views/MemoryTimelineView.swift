import SwiftUI
import SwiftData

// MARK: - 时间轴列表页（plan-memory-app-ui-rework §5）：按天分组、新的在上；顶上一行常驻开关（「正在记」挪到窗口总结格，plan-memory-app-three-views Q1）；
// 点行看详情（详情里「去这个窗口」）

struct TimelineDay: Identifiable {
    let day: Date
    let entries: [TimelineEntry]
    var id: Date { day }
}

/// 列表页的纯函数（可测）。`TimelineStore.rangeText` 是给模型看的「MM-dd HH:mm」，界面另写
enum TimelineListLayout {
    static let initialMonthCount = 2

    /// 按开始那天分组（05:00 日界，`MemoryDay`；跨天的归开始那天），天新→旧，组内新的在上
    static func groupByDay(_ entries: [TimelineEntry], calendar: Calendar = .current) -> [TimelineDay] {
        Dictionary(grouping: entries) { dayOf($0, calendar: calendar) }
            .map { TimelineDay(day: $0.key, entries: $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.day > $1.day }
    }

    /// 一条归哪天（那天 00:00）：v2 用存好的 day，老格式按开始时间现算
    static func dayOf(_ e: TimelineEntry, calendar: Calendar = .current) -> Date {
        e.day.flatMap { MemoryDay.date(ofKey: $0, calendar: calendar) } ?? MemoryDay.dayStart(e.start, calendar: calendar)
    }

    private static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// 「今天 · 10月10日」「昨天 · 10月9日」「10月8日 周三」；day = 归到的那天（`MemoryDay.dayStart`），「今天」也按 05:00 算
    static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = MemoryDateText.short(day, now: now, calendar: calendar)
        let today = MemoryDay.dayStart(now, calendar: calendar)
        if calendar.isDate(day, inSameDayAs: today) { return "今天 · \(date)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(day, inSameDayAs: y) { return "昨天 · \(date)" }
        return "\(date) \(weekdays[(calendar.component(.weekday, from: day) - 1) % 7])"
    }

    /// 行里只写时间段：「14:20–15:05」；跨天「23:40 – 次日 00:30」；再往后写日期
    static func rangeText(start: Date, end: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let s = hm(start, calendar), e = hm(end, calendar)
        let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
        switch gap {
        case ...0: return "\(s)–\(e)"
        case 1: return "\(s) – 次日 \(e)"
        default: return "\(s) – \(MemoryDateText.short(end, now: now, calendar: calendar)) \(e)"
        }
    }

    private static func hm(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 时间轴开关的副文案，照实际行为写：关 = 窗口收尾不再记新的一条，新窗口也不带最近的（`CalendarInjection.timelineSlot`）；
    /// 上下文摘要和窗口总结照写（另一个开关）；已经记下的不动。记忆总开关关着时时间轴也停（`TimelineConsolidator.enabled`）。
    /// v4-1：时间轴自己有写手，「上下文摘要和窗口总结」关着也照记（`SessionCloseout.closeoutEnabled`，Q3）
    static func switchNote(on: Bool, masterOn: Bool) -> String {
        if !masterOn { return "记忆总开关关着，时间轴也停着；已经记下的还在" }
        guard on else { return "暂停了：聊完的窗口不再记，新窗口也不会带上最近的；已经记下的还在" }
        return "在记：每个窗口每天一条，聊完记下聊了什么、还欠着什么，新窗口能看到最近的"
    }

    /// 「正在记」每行的状态，照 `SessionCloseout` 的真实规则：静默 30 分钟后的下一次巡检才记（巡检 = 回到前台 / 进后台 /
    /// 聊完一轮 / 切换对话 / 新建对话时喊一声）；新建对话那次，最近 2 小时聊过的不等静默马上记
    static func queueStatus(_ state: SessionCloseout.QueueState, running: Bool, now: Date = Date(), calendar: Calendar = .current) -> String? {
        if running { return "正在整理…" }
        switch state {
        case .none:
            return nil
        case .waiting(let until) where until > now:
            return "安静到 \(hm(until, calendar)) 后记；开新窗口会马上记"
        case .waiting, .due:
            return "该记了：下次回到 App、切换对话或聊完一轮时记"
        }
    }

    /// 待续：空或「无」不出
    static func pendingText(_ pending: String) -> String? {
        let t = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "无" ? nil : t
    }

    /// 「2026-09」→「9月」；不是今年写「2025年9月」
    static func monthTitle(_ month: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return month }
        return y == calendar.component(.year, from: now) ? "\(m)月" : "\(y)年\(m)月"
    }
}

/// 时间轴数据：挂在 MemoryPanelView 上，切分段不重读；读盘全在后台
@Observable
@MainActor
final class MemoryTimelineModel {
    private(set) var days: [TimelineDay] = []
    private(set) var months: [String] = []
    private(set) var loadedMonthCount = 0
    private(set) var goneIds: Set<String> = []
    private(set) var hasLoaded = false
    private var profileId: String?
    private var stale = false
    private var generation = 0

    var isEmpty: Bool { days.isEmpty }
    var nextMonth: String? { loadedMonthCount < months.count ? months[loadedMonthCount] : nil }

    func loadIfNeeded(profileId: String, container: ModelContainer) {
        guard profileId != self.profileId || stale else { return }
        reload(profileId: profileId, container: container)
    }

    func markStale() { stale = true }

    func markGone(_ conversationId: String) { goneIds.insert(conversationId) }

    func clear() {
        generation += 1
        days = []
        months = []
        loadedMonthCount = 0
        goneIds = []
        hasLoaded = false
        profileId = nil
        stale = false
    }

    func loadMore(container: ModelContainer) {
        guard let pid = profileId, nextMonth != nil else { return }
        reload(profileId: pid, container: container, monthCount: loadedMonthCount + 1)
    }

    func reload(profileId: String, container: ModelContainer, monthCount: Int? = nil) {
        if profileId != self.profileId { clear() }
        let count = monthCount ?? max(loadedMonthCount, TimelineListLayout.initialMonthCount)
        self.profileId = profileId
        stale = false
        generation += 1
        let gen = generation
        Task {
            let snap = await Task.detached(priority: .userInitiated) {
                Self.read(profileId: profileId, monthCount: count, container: container)
            }.value
            guard gen == generation else { return }
            months = snap.months
            loadedMonthCount = snap.loadedMonthCount
            days = TimelineListLayout.groupByDay(snap.entries)
            goneIds = snap.gone
            hasLoaded = true
        }
    }

    struct Snapshot {
        var months: [String]
        var loadedMonthCount: Int
        var entries: [TimelineEntry]
        var gone: Set<String>
    }

    /// 后台：枚举月份 → 读前 monthCount 个月 → 查哪些对话还在（后台 context，只取 id）
    nonisolated static func read(profileId: String, monthCount: Int, container: ModelContainer) -> Snapshot {
        let months = TimelineStore.months(profileId: profileId)
        let loaded = Array(months.prefix(monthCount))
        let entries = loaded.flatMap { TimelineStore.entries(month: $0, profileId: profileId) }
        let ids = Array(Set(entries.map(\.conversationId)))
        var alive: Set<String> = []
        if !ids.isEmpty {
            var d = FetchDescriptor<Conversation>(predicate: #Predicate {
                ids.contains($0.id) && $0.profileId == profileId && $0.isTrashed == false
            })
            d.propertiesToFetch = [\.id]
            alive = Set(((try? ModelContext(container).fetch(d)) ?? []).map(\.id))
        }
        return Snapshot(months: months, loadedMonthCount: loaded.count, entries: entries,
                        gone: Set(ids).subtracting(alive))
    }
}

struct MemoryTimelineView: View {
    let model: MemoryTimelineModel
    var viewModel: ConversationViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    /// 和设置格「跨窗口时间轴」、⋯ 菜单「暂停 / 继续记时间轴」同一个 key
    @AppStorage("mem_content_timeline") private var timelineOn = true
    @AppStorage("mem_master") private var memMaster = true
    @State private var detail: DetailTarget? = nil
    /// 「这个对话不记」等确认的那个（id + 标题）
    @State private var pendingStop: MemoryStopTarget? = nil

    private struct DetailTarget: Identifiable {
        let entry: TimelineEntry
        var id: String { entry.rowId }
    }

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        // 读齐了一次上台，不逐块插进来
        ZStack {
            if model.hasLoaded {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolPageBackground()
        .task(id: profileId) {
            model.loadIfNeeded(profileId: profileId, container: modelContext.container)
        }
        .modifier(MemoryStopRecordingAlert(target: $pendingStop))
        .sheet(item: $detail) { t in
            TimelineEntrySheet(entry: t.entry, profileId: profileId, isGone: model.goneIds.contains(t.entry.conversationId)) {
                open(t.entry.conversationId)
            }
        }
    }

    private var list: some View {
        List {
            Section {
                switchRow
            }
            .panelRowBackground()
            ForEach(model.days) { day in
                Section {
                    ForEach(Array(day.entries.enumerated()), id: \.element.rowId) { i, e in
                        row(e, isLast: i == day.entries.count - 1)
                            .panelRowBackground()
                    }
                } header: {
                    Text(TimelineListLayout.dayTitle(day.day))
                }
            }
            if let next = model.nextMonth {
                Section {
                    Button {
                        model.loadMore(container: modelContext.container)
                    } label: {
                        Text("更早的（\(TimelineListLayout.monthTitle(next))）›")
                            .font(.system(size: m.bodySize))
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .panelRowBackground(.clear)
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .overlay {
            if model.hasLoaded && model.isEmpty {
                MemoryEmptyState(title: "还没有记下的窗口",
                                 message: timelineOn && memMaster
                                    ? "每个窗口聊完、安静 30 分钟后，会在这里记一条"
                                    : "现在不记新的，原因看上面开关那行")
                    .allowsHitTesting(false)
            }
        }
    }

    /// 常驻开关：开着在记、关着暂停（已经记下的照样列出来）
    private var switchRow: some View {
        Toggle(isOn: $timelineOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("时间轴")
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                Text(TimelineListLayout.switchNote(on: timelineOn, masterOn: memMaster))
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
        }
        .tint(Theme.branchIndicator)
    }

    /// 点行 = 先看这一条本身（`TimelineEntrySheet`），里面再进窗口总结；窗口删了也能看，只是去不了
    private func row(_ e: TimelineEntry, isLast: Bool) -> some View {
        let gone = model.goneIds.contains(e.conversationId)
        return Button {
            detail = DetailTarget(entry: e)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Color.clear.frame(width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(TimelineListLayout.rangeText(start: e.start, end: e.end))
                        .font(.system(size: m.secondarySize, design: .serif))
                        .foregroundColor(gone ? Theme.textMuted : Theme.textSecondary)
                    Text(e.title.isEmpty ? "没有标题的窗口" : e.title)
                        .font(.system(size: m.bodySize, weight: .semibold))
                        .foregroundColor(gone ? Theme.textMuted : Theme.textPrimary)
                        .lineLimit(1)
                    Text(gone ? "这个窗口已经删了" : e.text)
                        .font(.system(size: m.secondarySize))
                        .foregroundColor(gone ? Theme.textMuted : Theme.textSecondary)
                        .lineLimit(2)
                    if !gone, let p = TimelineListLayout.pendingText(e.pending) {
                        TimelinePendingLine(text: "待续：\(p)", size: m.secondarySize)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .topLeading) {
                TimelineBeadString(tail: !isLast, dimmed: gone)
                    .frame(width: 12)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { open(e.conversationId) } label: { Label("去这个窗口", systemImage: "arrow.right.circle") }
                .disabled(gone)
            Button { copy(e) } label: { Label("复制这一条", systemImage: "doc.on.doc") }
            if !gone {
                Button(role: .destructive) {
                    pendingStop = MemoryStopTarget(conversationId: e.conversationId, title: e.title)
                } label: { Label("这个对话以后不记", systemImage: "nosign") }
            }
        }
    }

    private func open(_ conversationId: String) {
        if !MemoryConversationLink.open(conversationId, profileId: profileId, context: modelContext, viewModel: viewModel) {
            model.markGone(conversationId)
        }
    }

    private func copy(_ e: TimelineEntry) {
        var s = "\(TimelineListLayout.dayTitle(TimelineListLayout.dayOf(e))) \(TimelineListLayout.rangeText(start: e.start, end: e.end))　\(e.title)\n\(e.text)"
        if let p = TimelineListLayout.pendingText(e.pending) { s += "\n待续：\(p)" }
        #if canImport(UIKit)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}

private extension TimelineEntry {
    var rowId: String { "\(conversationId)@\(start.timeIntervalSince1970)" }
}

/// 从记忆 app 跳回某个窗口（时间轴、窗口总结格共用）
enum MemoryConversationLink {
    /// 同 SidebarView.openFromList：load 完再发通知，页 2 才会翻回聊天页（ContentView 只在页 0 时跟 selectedConversation 自动翻）。
    /// 返回 false = 窗口已经删了
    @discardableResult
    static func open(_ conversationId: String, profileId: String, context: ModelContext, viewModel: ConversationViewModel) -> Bool {
        let desc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { conv in conv.id == conversationId && conv.profileId == profileId }
        )
        guard let conv = try? context.fetch(desc).first, !conv.isTrashed else { return false }
        viewModel.loadConversation(conv, context: context)
        NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
        return true
    }
}

/// 「这个对话不记」等确认的那个（id + 标题）
struct MemoryStopTarget: Equatable {
    let conversationId: String
    let title: String
}

/// 「这个对话不记」确认（时间轴行、窗口总结格「正在记」共用）：关掉这个对话的「记忆参与」
///（`Conversation.memoryEnabled`，对话列表长按那个开关），收尾巡检就不再挑它
struct MemoryStopRecordingAlert: ViewModifier {
    @Binding var target: MemoryStopTarget?
    var onStopped: () -> Void = {}
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    func body(content: Content) -> some View {
        content
            .alert(target.map { "「\($0.title.isEmpty ? "没有标题的窗口" : $0.title)」以后不记了？" } ?? "",
                   isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                   presenting: target) { t in
                Button("不记了", role: .destructive) { stop(t.conversationId) }
                Button("取消", role: .cancel) { target = nil }
            } message: { _ in
                Text("这个对话会关掉「记忆参与」：以后不进时间轴、不写上下文摘要和窗口总结，也不再从里面记新东西，聊天时也不带记忆。已经记下的不动。想恢复：在对话列表里长按（mac 右键）这个对话，点「开启记忆参与」。")
            }
    }

    private func stop(_ conversationId: String) {
        target = nil
        let pid = profileManager?.currentProfile.id ?? ""
        let desc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { conv in conv.id == conversationId && conv.profileId == pid }
        )
        if let conv = try? modelContext.fetch(desc).first {
            conv.memoryEnabled = false
            try? modelContext.save()
        }
        onStopped()
    }
}

/// 时间轴一条（只读，plan-memory-app-three-views §3）：日期 + 时间段、窗口名、正文按行、待续；
/// 底部「看窗口总结」（弹层里推进下一页）和「去这个窗口」（窗口删了禁用）
struct TimelineEntrySheet: View {
    let entry: TimelineEntry
    let profileId: String
    var isGone = false
    var onOpen: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m

    /// 正文按行（v4-1 以后一行一个话题，这里不用跟着改）
    private var lines: [String] {
        entry.text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(TimelineListLayout.dayTitle(TimelineListLayout.dayOf(entry))) \(TimelineListLayout.rangeText(start: entry.start, end: entry.end))")
                            .font(.system(size: m.secondarySize, design: .serif))
                            .foregroundColor(Theme.textSecondary)
                        Text(entry.title.isEmpty ? "没有标题的窗口" : entry.title)
                            .font(.system(size: m.bodySize, weight: .semibold))
                            .foregroundColor(isGone ? Theme.textMuted : Theme.textPrimary)
                        if isGone {
                            Text("这个窗口已经删了")
                                .font(.system(size: m.secondarySize))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .panelRowBackground()
                if !lines.isEmpty {
                    Section {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: m.secondarySize))
                                .foregroundColor(Theme.textPrimary)
                                .textSelection(.enabled)
                        }
                    } header: {
                        Text("聊了什么")
                    }
                    .panelRowBackground()
                }
                if let p = TimelineListLayout.pendingText(entry.pending) {
                    Section {
                        TimelinePendingLine(text: p, size: m.secondarySize)
                    } header: {
                        Text("待续")
                    }
                    .panelRowBackground()
                }
            }
            .panelListStyle()
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) { buttons }
            .toolPageBackground()
            .panelSheetTitle("时间轴")
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 520)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            NavigationLink {
                WindowSummaryPage(conversationId: entry.conversationId, profileId: profileId, fallbackTitle: entry.title,
                                  isGone: isGone, onOpen: { dismiss(); onOpen() })
            } label: {
                Text("看窗口总结")
            }
            .buttonStyle(MemoryPrimaryButtonStyle(fullWidth: true))
            Button {
                dismiss()
                onOpen()
            } label: {
                Text(isGone ? "这个窗口已经删了" : "去这个窗口")
            }
            .buttonStyle(MemoryPrimaryButtonStyle(fullWidth: true))
            .disabled(isGone)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// 「待续」行：前面一颗薄荷小点（时间轴行和时间轴条目弹层共用）
struct TimelinePendingLine: View {
    let text: String
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(Theme.branchIndicator)
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 2 }
            Text(text)
                .font(.system(size: size))
                .foregroundColor(Theme.textPrimary)
        }
    }
}

/// 花园的「珠串」：一颗大珠打头，下面大小交替的小珠把同一天的窗口串起来；当天最后一条只留大珠
private struct TimelineBeadString: View {
    let tail: Bool
    let dimmed: Bool

    var body: some View {
        Canvas { ctx, size in
            let x = size.width / 2
            let head = dimmed ? Theme.textMuted.opacity(0.35) : Theme.branchIndicator
            ctx.fill(Path(ellipseIn: CGRect(x: x - 4.5, y: 5, width: 9, height: 9)), with: .color(head))
            guard tail else { return }
            let soft = Theme.branchIndicator.opacity(0.4)
            var y: CGFloat = 19
            var big = true
            while true {
                let d: CGFloat = big ? 5.5 : 4
                guard y + d <= size.height else { break }
                ctx.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y, width: d, height: d)), with: .color(soft))
                y += d + 5
                big.toggle()
            }
        }
        .allowsHitTesting(false)
    }
}
