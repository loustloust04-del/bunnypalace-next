import MemoryCore
import SwiftUI
import SwiftData

// MARK: - 时间轴列表页（plan-memory-c2c3-v2 第 7 段）：一天一组、新的在上；一组 = 主调 + 各时段的项（A2 段 / 没压缩的那截），
// 每一行的字和注入给模型的那一行一字不差（`TimelineStore.itemText` / `headlineText`）。老条目一条不删：有新记录的日子折在「旧格式」下面（点开看），
// 只有老条目的日子照旧列出来、标「旧格式」。
// 顶上一行常驻开关（「正在记」在窗口总结格）；点项看这一项（里面看那段 A2 / 去原文）

struct TimelineDayGroup: Identifiable {
    let key: String
    let day: Date
    /// 新的一天一条；nil = 这天只有老条目
    let record: TimelineDayRecord?
    /// 老条目（旧格式），组内新的在上
    let entries: [TimelineEntry]
    var id: String { key }
}

/// 列表页的纯函数（可测）。`TimelineStore.rangeText` 是老条目文件头的「MM-dd HH:mm」，界面另写
enum TimelineListLayout {
    static let initialMonthCount = 2

    /// 按记忆日（05:00 日界）合成一组：新的一天一条 + 同一天的老条目；天新→旧
    static func group(records: [TimelineDayRecord], entries: [TimelineEntry], calendar: Calendar = .current) -> [TimelineDayGroup] {
        let byDay = Dictionary(grouping: entries) { $0.dayKey }
        let recordByDay = Dictionary(records.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        return Set(recordByDay.keys).union(byDay.keys).compactMap { key -> TimelineDayGroup? in
            guard let day = MemoryDay.date(ofKey: key, calendar: calendar) else { return nil }
            return TimelineDayGroup(key: key, day: day, record: recordByDay[key],
                                    entries: (byDay[key] ?? []).sorted { $0.start > $1.start })
        }.sorted { $0.key > $1.key }
    }

    /// 日期选择器选的那天 → 记忆日（取那天中午，免得 05:00 以前算到前一天）
    static func dayKey(picked: Date, calendar: Calendar = .current) -> String {
        MemoryDay.key(calendar.startOfDay(for: picked).addingTimeInterval(12 * 3600), calendar: calendar)
    }

    /// 这天有新记录又有老条目：老条目折起来（默认收着，点开看）
    static func foldsLegacy(_ group: TimelineDayGroup) -> Bool {
        group.record != nil && !group.entries.isEmpty
    }

    /// 一组里的项按时间先后，时段换了的那一项带时段名
    static func rows(_ record: TimelineDayRecord, calendar: Calendar = .current) -> [(period: String?, item: TimelineDayRecord.Item)] {
        var last: TimelinePeriod?
        return record.items.sorted { $0.start < $1.start }.map { item in
            let p = item.period(calendar: calendar)
            defer { last = p }
            return (p == last ? nil : p.label, item)
        }
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

    /// 时间轴开关的副文案，照实际行为写：关 = 不再拼新的日子，新窗口也不带最近的（`CalendarInjection.timelineSlot`）；
    /// 已经记下的不动。记忆总开关关着时时间轴也停（`TimelineConsolidator.enabled`）
    static func switchNote(on: Bool, masterOn: Bool) -> String {
        if !masterOn { return "记忆总开关关着，时间轴也停着；已经记下的还在" }
        guard on else { return "暂停了：不再拼新的日子，新窗口也不会带上最近的；已经记下的还在" }
        return "在记：一天一条、跨所有窗口，过了 05:00 把前一天拼好、写一句主调；新窗口能看到最近几天"
    }

    /// 「正在记」每行的状态，照 `SessionCloseout` 的真实规则：静默够了（A3 默认 24 小时）后的下一次巡检才记（巡检 = 回到前台 / 进后台 /
    /// 聊完一轮 / 切换对话 / 新建对话时喊一声）；新建对话那次，最近 12 小时聊过的不等静默马上记
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
    private(set) var days: [TimelineDayGroup] = []
    private(set) var months: [String] = []
    private(set) var loadedMonthCount = 0
    private(set) var goneIds: Set<String> = []
    private(set) var hasLoaded = false
    private var profileId: String?
    private(set) var stale = false
    private var generation = 0
    /// 正在重写主调的那天：父级持有，mac 切格拆掉时间轴视图也不丢，在跑就不再提交（10-24 astra P2）
    private(set) var regenerating: String?
    /// 重写结果 / 跳转失败的提示：存着，只在时间轴段看得见时弹，隐藏时攒到切回来再弹
    var notice: String?
    private var regenToken = 0

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
        regenToken += 1
        regenerating = nil
        notice = nil
    }

    func presentsNotice(active: Bool) -> Bool { active && notice != nil }

    /// 提交重写某天；已有一个在跑（含切格前提交的）就不提交、返回 false。跑完重读、把结果放进 notice；换楼层后到的旧结果丢掉
    @discardableResult
    func regenerate(_ day: String, profileId: String, container: ModelContainer,
                    run: @escaping () async -> TimelineDaily.Report?) -> Bool {
        guard regenerating == nil else { return false }
        regenerating = day
        regenToken += 1
        let token = regenToken
        Task {
            let report = await run()
            guard token == regenToken else { return }
            regenerating = nil
            reload(profileId: profileId, container: container)
            notice = Self.regenerateNotice(day: day, report: report, timelineEnabled: SessionCloseout.timelineEnabled)
        }
        return true
    }

    nonisolated static func regenerateNotice(day: String, report: TimelineDaily.Report?, timelineEnabled: Bool) -> String? {
        guard let report else { return timelineEnabled ? "正在搬迁 / 恢复记忆，这会儿不写，等会儿再试" : nil }
        if let why = report.failed[day] ?? report.blocked { return why }
        if report.invalidated { return "中途在搬迁 / 恢复记忆，这天没写，等会儿再试" }
        if report.written.isEmpty { return "这天没写：没有能拼的上下文摘要 / 消息，或者和原来一样" }
        return nil
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
            days = TimelineListLayout.group(records: snap.records, entries: snap.entries)
            goneIds = snap.gone
            hasLoaded = true
        }
    }

    struct Snapshot {
        var months: [String]
        var loadedMonthCount: Int
        var records: [TimelineDayRecord]
        var entries: [TimelineEntry]
        var gone: Set<String>
    }

    /// 后台：枚举月份 → 读前 monthCount 个月 → 查哪些对话还在（后台 context，只取 id）
    nonisolated static func read(profileId: String, monthCount: Int, container: ModelContainer) -> Snapshot {
        let dir = TimelineStore.dir(memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        let months = TimelineStore.months(in: dir)
        let loaded = Array(months.prefix(monthCount)).map { TimelineStore.month($0, in: dir) }
        let records = loaded.flatMap(\.days), entries = loaded.flatMap(\.entries)
        let ids = Array(Set(entries.map(\.conversationId) + records.flatMap { $0.items.map(\.conversationId) }))
        var alive: Set<String> = []
        if !ids.isEmpty {
            var d = FetchDescriptor<Conversation>(predicate: #Predicate {
                ids.contains($0.id) && $0.profileId == profileId && $0.isTrashed == false
            })
            d.propertiesToFetch = [\.id]
            alive = Set(((try? ModelContext(container).fetch(d)) ?? []).map(\.id))
        }
        return Snapshot(months: months, loadedMonthCount: loaded.count, records: records, entries: entries,
                        gone: Set(ids).subtracting(alive))
    }
}

struct MemoryTimelineView: View {
    let model: MemoryTimelineModel
    var viewModel: ConversationViewModel
    /// 时间轴段此刻看得见（格选中 + 段在台上）：不是就不弹提示，攒在 model 里
    var isActive = true
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    /// 和设置格「跨窗口时间轴」、⋯ 菜单「暂停 / 继续记时间轴」同一个 key
    @AppStorage("mem_content_timeline") private var timelineOn = true
    @AppStorage("mem_master") private var memMaster = true
    @State private var detail: DetailTarget? = nil
    /// 「这个对话不记」等确认的那个（id + 标题）
    @State private var pendingStop: MemoryStopTarget? = nil
    @State private var pendingCounts: (open: Int, faded: Int) = (0, 0)
    /// 待续本子迁不好 / 读不全：照实说
    @State private var pendingProblem: String?
    /// 「重写某一天…」选日期
    @State private var pickingDay = false
    @State private var pickedDate = Date()
    /// 点开了「旧格式」的那几天
    @State private var openLegacy: Set<String> = []

    private enum DetailTarget: Identifiable {
        case entry(TimelineEntry)
        case item(TimelineDayRecord.Item, day: String)

        var id: String {
            switch self {
            case .entry(let e): return e.rowId
            case .item(let i, let day): return i.rowId(day)
            }
        }
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
            await reloadPending()
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in Task { await reloadPending() } }
        .modifier(MemoryStopRecordingAlert(target: $pendingStop))
        .alert(model.notice ?? "", isPresented: Binding(get: { model.presentsNotice(active: isActive) },
                                                        set: { if !$0 { model.notice = nil } })) {
            Button("好", role: .cancel) { model.notice = nil }
        }
        .sheet(isPresented: $pickingDay) {
            VStack(spacing: 12) {
                Text("重写哪一天")
                    .font(.system(size: m.bodySize, weight: .semibold))
                DatePicker("", selection: $pickedDate, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    Button("取消") { pickingDay = false }
                    Spacer()
                    Button("重写") {
                        pickingDay = false
                        regenerate(TimelineListLayout.dayKey(picked: pickedDate))
                    }
                    .tint(Theme.branchIndicator)
                }
            }
            .padding(20)
            .frame(minWidth: 320)
        }
        .sheet(item: $detail) { t in
            switch t {
            case .entry(let e):
                TimelineEntrySheet(entry: e, profileId: profileId, isGone: model.goneIds.contains(e.conversationId)) {
                    open(e.conversationId)
                }
            case .item(let item, let day):
                TimelineItemSheet(item: item, day: day, profileId: profileId, isGone: model.goneIds.contains(item.conversationId)) {
                    openMessage(item)
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                switchRow
                // v5 §八：待续和设置「整理 › 待续」同一份（三态、改字）
                SettingsNavRow(.memoryPending) {
                    PendingListPage()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("待续")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Text(pendingProblem ?? "没做完 \(pendingCounts.open) · 淡了 \(pendingCounts.faded)")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                // 恢复过备份的日子自动不碰、空日子没有主调行：任选一天手动重写（不受冻结限制）
                Button {
                    pickedDate = Date()
                    pickingDay = true
                } label: {
                    Text("重写某一天…")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.regenerating != nil || !timelineOn || !memMaster)
            }
            .panelRowBackground()
            ForEach(model.days) { day in
                Section {
                    if let r = day.record {
                        headlineRow(r)
                            .panelRowBackground()
                        let rows = TimelineListLayout.rows(r)
                        ForEach(Array(rows.enumerated()), id: \.element.item.rowKey) { i, row in
                            itemRow(row.item, period: row.period, day: r.date, isLast: i == rows.count - 1 && day.entries.isEmpty)
                                .panelRowBackground()
                        }
                    }
                    if TimelineListLayout.foldsLegacy(day) {
                        legacyFoldRow(day)
                            .panelRowBackground()
                    }
                    if !TimelineListLayout.foldsLegacy(day) || openLegacy.contains(day.key) {
                        ForEach(Array(day.entries.enumerated()), id: \.element.rowId) { i, e in
                            legacyRow(e, isLast: i == day.entries.count - 1)
                                .panelRowBackground()
                        }
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
                MemoryEmptyState(title: "还没有记下的日子",
                                 message: timelineOn && memMaster
                                    ? "过了 05:00，会把前一天各窗口聊的拼成一条"
                                    : "现在不记新的，原因看上面开关那行")
                    .allowsHitTesting(false)
            }
        }
    }

    /// 待续数（后台读；第一次进来顺手迁移，只跑一次）
    private func reloadPending() async {
        let pid = profileId
        let (items, why) = await Task.detached { () -> ([PendingItem], String?) in
            var why: String?
            do { try TimelineDaily.preparePendingForEdit(profileId: pid) } catch { why = TimelineDaily.pendingProblem(error) }
            return (PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) ?? [], why)
        }.value
        guard pid == profileId else { return }
        pendingProblem = why
        pendingCounts = (items.filter { $0.state == .open }.count, items.filter { $0.state == .faded }.count)
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

    /// 主调（和注入那一行同一份字）+ 话题词；长按重写这天的主调
    private func headlineRow(_ r: TimelineDayRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.regenerating == r.date ? "正在重写主调…" : TimelineStore.headlineText(r))
                .font(.system(size: m.bodySize, weight: .semibold))
                .foregroundColor(r.headline == nil ? Theme.textMuted : Theme.textPrimary)
                .textSelection(.enabled)
            if !r.topics.isEmpty {
                Text(r.topics.joined(separator: " · "))
                    .font(.system(size: m.secondarySize))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button { regenerate(r.date) } label: { Label("重写这天的主调", systemImage: "arrow.clockwise") }
                .disabled(model.regenerating != nil || !timelineOn || !memMaster)
            Button { copy(r) } label: { Label("复制这一天", systemImage: "doc.on.doc") }
        }
    }

    /// 一项：时段名（换时段的那项才有）+ 和注入那一行同一份字；点了看这一项
    private func itemRow(_ item: TimelineDayRecord.Item, period: String?, day: String, isLast: Bool) -> some View {
        let gone = model.goneIds.contains(item.conversationId)
        return Button {
            detail = .item(item, day: day)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Color.clear.frame(width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    if let period {
                        Text(period)
                            .font(.system(size: m.secondarySize, design: .serif))
                            .foregroundColor(Theme.textSecondary)
                    }
                    TimelineLine.text(TimelineStore.itemBody(item), conv: item.conversationId, size: m.secondarySize,
                                      color: gone || item.kind != .segment ? Theme.textMuted : Theme.textPrimary)
                        .lineLimit(2)
                    if gone {
                        Text("这个窗口已经删了")
                            .font(.system(size: m.secondarySize))
                            .foregroundColor(Theme.textMuted)
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
            Button { open(item.conversationId) } label: { Label("去这个窗口", systemImage: "arrow.right.circle") }
                .disabled(gone)
            if !gone {
                Button(role: .destructive) {
                    pendingStop = MemoryStopTarget(conversationId: item.conversationId, title: item.window)
                } label: { Label("这个对话以后不记", systemImage: "nosign") }
            }
        }
    }

    /// 有新记录的日子：老条目收在这一行下面，点开 / 收起
    private func legacyFoldRow(_ day: TimelineDayGroup) -> some View {
        let open = openLegacy.contains(day.key)
        return Button {
            if open { openLegacy.remove(day.key) } else { openLegacy.insert(day.key) }
        } label: {
            HStack(spacing: 6) {
                Color.clear.frame(width: 12)
                Text("旧格式 \(day.entries.count) 条")
                    .font(.system(size: m.secondarySize, design: .serif))
                    .foregroundColor(Theme.textMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: m.secondarySize - 2, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 老条目（旧格式）：标「旧格式」+ 和注入那一行同一份字；点行 = 先看这一条本身（`TimelineEntrySheet`）
    private func legacyRow(_ e: TimelineEntry, isLast: Bool) -> some View {
        let gone = model.goneIds.contains(e.conversationId)
        return Button {
            detail = .entry(e)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Color.clear.frame(width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text("旧格式")
                        .font(.system(size: m.secondarySize, design: .serif))
                        .foregroundColor(Theme.textMuted)
                    Group {
                        if gone {
                            Text("这个窗口已经删了")
                                .font(.system(size: m.secondarySize))
                                .foregroundColor(Theme.textMuted)
                        } else {
                            TimelineLine.text(TimelineStore.legacyBody(e), conv: e.conversationId, size: m.secondarySize, color: Theme.textSecondary)
                        }
                    }
                    .lineLimit(2)
                    if !gone, let p = TimelineListLayout.pendingText(e.pending) {
                        TimelinePendingLine(text: "待续：\(p)", size: m.secondarySize)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .topLeading) {
                TimelineBeadString(tail: !isLast, dimmed: true)
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
            // 只有老条目的日子没有主调行：从这里重写这天（不受恢复冻结限制）
            Button { regenerate(e.dayKey) } label: { Label("重写这天", systemImage: "arrow.clockwise") }
                .disabled(model.regenerating != nil || !timelineOn || !memMaster)
            if !gone {
                Button(role: .destructive) {
                    pendingStop = MemoryStopTarget(conversationId: e.conversationId, title: e.title)
                } label: { Label("这个对话以后不记", systemImage: "nosign") }
            }
        }
    }

    private func regenerate(_ day: String) {
        guard let profile = profileManager?.currentProfile else { return }
        model.regenerate(day, profileId: profile.id, container: modelContext.container) {
            await SessionCloseoutTrigger.shared.timelineRegenerate(day: day, profile: profile)
        }
    }

    private func open(_ conversationId: String) {
        if !MemoryConversationLink.open(conversationId, profileId: profileId, context: modelContext, viewModel: viewModel) {
            model.markGone(conversationId)
        }
    }

    /// 没压缩的 / 段在当前分支上的：跳到这一项当天的第一条消息；消息不在了明确说
    private func openMessage(_ item: TimelineDayRecord.Item) {
        guard let from = item.from else { return open(item.conversationId) }
        switch MemoryConversationLink.openMessage(from, conversationId: item.conversationId, profileId: profileId,
                                                  context: modelContext, viewModel: viewModel) {
        case .opened: break
        case .windowGone: model.markGone(item.conversationId)
        case .messageGone: model.notice = "这一项的消息找不到了（可能切了分支或删了），已经打开这个窗口"
        }
    }

    private func copy(_ r: TimelineDayRecord) {
        let lines = [TimelineStore.headlineText(r)] + TimelineListLayout.rows(r).map { ($0.period.map { "\($0) · " } ?? "") + TimelineStore.itemText($0.item) }
        setPasteboard("\(TimelineStore.dayLabel(r.date))\n" + lines.joined(separator: "\n"))
    }

    private func copy(_ e: TimelineEntry) {
        var s = "\(TimelineStore.dayLabel(e.dayKey)) \(TimelineStore.legacyText(e))"
        if let p = TimelineListLayout.pendingText(e.pending) { s += "\n待续：\(p)" }
        setPasteboard(s)
    }

    private func setPasteboard(_ s: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}

/// 时间轴一行：正文 + 小号灰字的窗口短编号（拼起来就是 `TimelineStore.itemText` / `legacyText`，和注入那一行一字不差）
enum TimelineLine {
    static func text(_ body: String, conv: String, size: CGFloat, color: Color, weight: Font.Weight = .regular) -> Text {
        Text(body).font(.system(size: size, weight: weight)).foregroundColor(color)
            + Text(" " + TimelineStore.convTag(conv)).font(.system(size: max(size - 3, 9))).foregroundColor(Theme.textMuted)
    }
}

private extension TimelineDayRecord.Item {
    var rowKey: String { "\(conversationId)@\(start.timeIntervalSince1970)@\(from ?? title)" }
    func rowId(_ day: String) -> String { "\(day)#\(rowKey)" }
}

/// 时间轴一项（只读）：日期、这一项那一行（和注入同一份字）、哪种；
/// A2 段 →「看上下文摘要」推进窗口总结页、定位到那一段（段号现算）；能定位的都有「去原文」（跳到这一项当天的第一条消息）
struct TimelineItemSheet: View {
    let item: TimelineDayRecord.Item
    let day: String
    let profileId: String
    var isGone = false
    var onOpenMessage: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m

    private var kindText: String {
        switch item.kind {
        case .segment: return item.from == nil ? "上下文摘要的一段 · 在当前分支上找不到了（可能切了分支或删了）" : "上下文摘要的一段" + (item.continued ? " · 接前一天" : "")
        case .uncompressed: return "这一截还没压成上下文摘要，等它压完、下次拼这天时补上"
        case .short: return "短窗口，没压成上下文摘要"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(TimelineStore.dayLabel(day)) · \(item.period().label)")
                            .font(.system(size: m.secondarySize, design: .serif))
                            .foregroundColor(Theme.textSecondary)
                        TimelineLine.text(TimelineStore.itemBody(item), conv: item.conversationId, size: m.bodySize,
                                          color: isGone ? Theme.textMuted : Theme.textPrimary, weight: .semibold)
                            .textSelection(.enabled)
                        Text(isGone ? "这个窗口已经删了" : kindText)
                            .font(.system(size: m.secondarySize))
                            .foregroundColor(Theme.textMuted)
                    }
                    .padding(.vertical, 4)
                }
                .panelRowBackground()
            }
            .panelListStyle()
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) { buttons }
            .toolPageBackground()
            .panelSheetTitle("时间轴")
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 420)
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
            if item.kind == .segment {
                NavigationLink {
                    WindowSummaryPage(conversationId: item.conversationId, profileId: profileId, fallbackTitle: item.window,
                                      isGone: isGone, anchor: WindowSummaryAnchor(start: item.start, title: item.title),
                                      onOpen: { dismiss(); onOpenMessage() })
                } label: {
                    Text("看上下文摘要这一段")
                }
                .buttonStyle(MemoryPrimaryButtonStyle(fullWidth: true))
            }
            Button {
                dismiss()
                onOpenMessage()
            } label: {
                Text(isGone ? "这个窗口已经删了" : (item.from == nil ? "去这个窗口" : "去原文"))
            }
            .buttonStyle(MemoryPrimaryButtonStyle(fullWidth: true))
            .disabled(isGone)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private extension TimelineEntry {
    var rowId: String { "\(conversationId)@\(start.timeIntervalSince1970)" }
}

/// 从记忆 app 跳回某个窗口（时间轴、窗口总结格共用）
enum MemoryConversationLink {
    enum MessageResult { case opened, windowGone, messageGone }

    /// 跳到窗口里的某条消息（时间轴项的稳定指针）：窗口在、消息不在（删了）也打开窗口，但如实回 messageGone
    static func openMessage(_ nodeId: String, conversationId: String, profileId: String, context: ModelContext,
                            viewModel: ConversationViewModel) -> MessageResult {
        let desc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { conv in conv.id == conversationId && conv.profileId == profileId }
        )
        guard let conv = try? context.fetch(desc).first, !conv.isTrashed else { return .windowGone }
        let nodeDesc = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.id == nodeId && $0.conversationId == conversationId && $0.isTrashed == false }
        )
        guard (try? context.fetchCount(nodeDesc)) ?? 0 > 0 else {
            viewModel.loadConversation(conv, context: context)
            NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
            return .messageGone
        }
        viewModel.navigateToNode(nodeId: nodeId, conversation: conv, context: context)
        return .opened
    }

    /// 记忆条目的「去原对话 / 跳到这条」（记忆列表、整理台、设置里的条目页共用）：窗口没了不动、说一声；
    /// 出处那条消息没了（删了 / 藏了）只打开窗口并说一声，不进会误报「已切换到分支」的搜索跳转
    @MainActor
    @discardableResult
    static func openSource(of memory: Memory, profileId: String, context: ModelContext,
                           viewModel: ConversationViewModel) -> MessageResult {
        guard let cid = memory.sourceConversationId else { return .windowGone }
        let desc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { conv in conv.id == cid && conv.profileId == profileId }
        )
        guard let conv = try? context.fetch(desc).first, !conv.isTrashed else {
            ToastCenter.shared.show("原对话已经不在了")
            return .windowGone
        }
        guard let nodeId = memory.sourceNodeId else {
            viewModel.loadConversation(conv, context: context)
            NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
            return .opened
        }
        let nodeDesc = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.id == nodeId && $0.conversationId == cid && $0.profileId == profileId }
        )
        guard let node = try? context.fetch(nodeDesc).first, !node.isTrashed, node.hasDisplayableContent,
              node.role == "user" || node.role == "assistant" else {
            viewModel.loadConversation(conv, context: context)
            NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
            ToastCenter.shared.show("原消息找不到了，已打开这个窗口")
            return .messageGone
        }
        viewModel.navigateToSearchResult(nodeId: nodeId, conversation: conv, context: context)
        return .opened
    }

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

/// 时间轴老条目（旧格式，只读，plan-memory-app-three-views §3）：日期 + 时间段、窗口名、正文按行、待续；
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
                        Text("\(MemoryDay.date(ofKey: entry.dayKey).map { TimelineListLayout.dayTitle($0) } ?? entry.dayKey) \(TimelineListLayout.rangeText(start: entry.start, end: entry.end)) · 旧格式")
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
