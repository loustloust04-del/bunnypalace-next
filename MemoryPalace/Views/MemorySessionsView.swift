import SwiftUI
import SwiftData

// MARK: - 窗口总结格（plan-memory-app-three-views §2）：顶上「正在记」（收尾队列，Q1），下面一行一个窗口，
// 最近动过的在上；点行看这个窗口的窗口总结（底部「去这个窗口」），窗口删了的行变灰、还能看、去不了

/// 窗口总结格的一行
struct WindowSummaryRow: Identifiable, Equatable {
    let conversationId: String
    let title: String
    let first: Date?
    let last: Date?
    let segmentCount: Int
    let updatedAt: Date
    var isGone: Bool
    var id: String { conversationId }
}

/// 窗口总结格的纯函数（可测）
enum WindowSummaryListLayout {
    /// 每个窗口那份文件 → 一行；一段都没有的不出；aliveTitles = 还在的对话（id → 现在的标题），不在里面 = 删了。
    /// 最近动过的在上（文件最后写入），同时写的按最后一段结束时间
    static func rows(_ summaries: [SessionSummary], aliveTitles: [String: String]) -> [WindowSummaryRow] {
        summaries.compactMap { s -> WindowSummaryRow? in
            guard !s.segments.isEmpty else { return nil }
            let dated = s.segments.filter { $0.start > .distantPast }
            let alive = aliveTitles[s.conversationId]
            let title = (alive?.isEmpty == false ? alive : nil) ?? s.title
            return WindowSummaryRow(conversationId: s.conversationId, title: title,
                                    first: dated.map(\.start).min(), last: dated.map(\.end).max(),
                                    segmentCount: s.segments.count, updatedAt: s.updatedAt, isGone: alive == nil)
        }
        .sorted { ($0.updatedAt, $0.last ?? .distantPast) > ($1.updatedAt, $1.last ?? .distantPast) }
    }

    /// 「10月1日 – 10月9日」；同一天只写一天；没有日期 nil
    static func dateRange(first: Date?, last: Date?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let a = first ?? last else { return nil }
        let b = last ?? a
        let s = MemoryDateText.short(a, now: now, calendar: calendar)
        return calendar.isDate(a, inSameDayAs: b) ? s : "\(s) – \(MemoryDateText.short(b, now: now, calendar: calendar))"
    }

    /// 「正在记」现在不记的原因；nil = 照常列队列。两个开关只关一个时收尾照跑，开着的那个照写
    static func queueNote(masterOn: Bool, summaryOn: Bool, timelineOn: Bool, queueEmpty: Bool) -> String? {
        if !masterOn { return "记忆总开关关着，现在不记" }
        // v4-1 Q3：两个开关任一个开着就收尾（各写各的）
        if !summaryOn && !timelineOn { return "「上下文摘要和窗口总结」「时间轴」都关着，窗口收尾不跑" }
        return queueEmpty ? "现在没有等着记的窗口" : nil
    }
}

/// 窗口总结格数据：挂在 MemoryPanelView 上，切格不重读；读盘全在后台
@Observable
@MainActor
final class MemorySessionsModel {
    private(set) var rows: [WindowSummaryRow] = []
    private(set) var hasLoaded = false
    /// 「正在记」：收尾巡检接下来要写的对话（和巡检同一个查询 `SessionCloseout.queue`）
    private(set) var queue: [QueueRow] = []
    private(set) var queueLoaded = false
    private var profileId: String?
    private var stale = false
    private var generation = 0
    private var queueGeneration = 0

    struct QueueRow: Identifiable, Equatable {
        let conversationId: String
        let title: String
        let state: SessionCloseout.QueueState
        var id: String { conversationId }
    }

    func loadIfNeeded(profileId: String, container: ModelContainer) {
        guard profileId != self.profileId || stale else { return }
        reload(profileId: profileId, container: container)
    }

    func markStale() { stale = true }

    func markGone(_ conversationId: String) {
        rows = rows.map { r in
            var r = r
            if r.conversationId == conversationId { r.isGone = true }
            return r
        }
    }

    func clear() {
        generation += 1
        queueGeneration += 1
        rows = []
        hasLoaded = false
        queue = []
        queueLoaded = false
        profileId = nil
        stale = false
    }

    func reload(profileId: String, container: ModelContainer) {
        if profileId != self.profileId { clear() }
        self.profileId = profileId
        stale = false
        generation += 1
        let gen = generation
        Task {
            let list = await Task.detached(priority: .userInitiated) {
                Self.read(profileId: profileId, container: container)
            }.value
            guard gen == generation else { return }
            rows = list
            hasLoaded = true
        }
    }

    /// 后台读：会读最近 7 天有新消息的对话的节点（同巡检），所以只在这格上台 / 收尾开始结束 / 记忆变了时读
    func reloadQueue(profileId: String, container: ModelContainer) {
        queueGeneration += 1
        let gen = queueGeneration
        Task {
            let rows = await Task.detached(priority: .utility) {
                SessionCloseout.queue(profileId: profileId, container: container, now: Date(), force: nil, includeWaiting: true)
                    .map { QueueRow(conversationId: $0.conversationId, title: $0.title, state: $0.state) }
            }.value
            guard gen == queueGeneration else { return }
            queue = rows
            queueLoaded = true
        }
    }

    /// 后台：读 windows/（没有的补 sessions/）每个窗口那份文件 → 查哪些对话还在（后台 context，只取 id、标题）
    nonisolated static func read(profileId: String, container: ModelContainer) -> [WindowSummaryRow] {
        let all = WindowSummaryReader.listAll(profileId: profileId)
        let ids = Array(Set(all.map(\.conversationId)))
        var alive: [String: String] = [:]
        if !ids.isEmpty {
            var d = FetchDescriptor<Conversation>(predicate: #Predicate {
                ids.contains($0.id) && $0.profileId == profileId && $0.isTrashed == false
            })
            d.propertiesToFetch = [\.id, \.title]
            for c in (try? ModelContext(container).fetch(d)) ?? [] { alive[c.id] = c.title }
        }
        return WindowSummaryListLayout.rows(all, aliveTitles: alive)
    }
}

struct MemorySessionsView: View {
    let model: MemorySessionsModel
    var viewModel: ConversationViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage("mem_master") private var memMaster = true
    @AppStorage("mem_content_summary") private var summaryOn = true
    @AppStorage("mem_content_timeline") private var timelineOn = true
    @State private var detail: WindowSummaryRow? = nil
    @State private var pendingStop: MemoryStopTarget? = nil

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        // 窗口列表和「正在记」是两次后台读：两份都到了才上台，一次出来
        ZStack {
            if model.hasLoaded && model.queueLoaded {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolPageBackground()
        .task(id: profileId) {
            model.loadIfNeeded(profileId: profileId, container: modelContext.container)
            model.reloadQueue(profileId: profileId, container: modelContext.container)
        }
        .onChange(of: SessionCloseoutStatus.shared.runningConversationId) { _, running in
            model.reloadQueue(profileId: profileId, container: modelContext.container)
            // 收尾写完一个（时间轴暂停时收尾不发 memoryDidChange，这里自己刷）
            if running == nil { model.reload(profileId: profileId, container: modelContext.container) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in
            model.reloadQueue(profileId: profileId, container: modelContext.container)
        }
        .modifier(MemoryStopRecordingAlert(target: $pendingStop) {
            model.reloadQueue(profileId: profileId, container: modelContext.container)
        })
        .sheet(item: $detail) { r in
            WindowSummarySheet(conversationId: r.conversationId, profileId: profileId, fallbackTitle: r.title,
                               isGone: r.isGone) {
                open(r.conversationId)
            }
        }
    }

    private var list: some View {
        List {
            Section {
                queueRows
            } header: {
                Text("正在记")
            }
            .panelRowBackground()
            if !model.rows.isEmpty {
                Section {
                    ForEach(model.rows) { r in
                        row(r)
                            .panelRowBackground()
                    }
                } header: {
                    Text("窗口 · \(model.rows.count)")
                }
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .overlay {
            if model.rows.isEmpty {
                MemoryEmptyState(title: "还没有窗口总结",
                                 message: memMaster && (summaryOn || timelineOn)
                                    ? "每个窗口聊完、安静 30 分钟后，会在这里记下"
                                    : "现在不记新的，原因看上面「正在记」那行")
                    .allowsHitTesting(false)
            }
        }
    }

    /// 「正在记」：收尾巡检接下来要写的对话 + 每个现在什么状态；空时一行灰字
    @ViewBuilder
    private var queueRows: some View {
        if let note = WindowSummaryListLayout.queueNote(masterOn: memMaster, summaryOn: summaryOn, timelineOn: timelineOn, queueEmpty: model.queue.isEmpty) {
            Text(note)
                .font(.system(size: m.secondarySize))
                .foregroundColor(Theme.textMuted)
        } else {
            ForEach(model.queue) { q in
                // 每 30 秒重算一次：「安静到 HH:mm」过点后变「该记了」
                SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { tl in
                    queueRow(q, now: tl.date)
                }
            }
        }
    }

    private func queueRow(_ q: MemorySessionsModel.QueueRow, now: Date) -> some View {
        let running = SessionCloseoutStatus.shared.runningConversationId == q.conversationId
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(running ? Theme.branchIndicator : Theme.textMuted.opacity(0.45))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(q.title.isEmpty ? "没有标题的窗口" : q.title)
                    .font(.system(size: m.bodySize))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if let s = TimelineListLayout.queueStatus(q.state, running: running, now: now) {
                    Text(s)
                        .font(.system(size: m.secondarySize))
                        .foregroundColor(Theme.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button { open(q.conversationId) } label: { Label("去这个窗口", systemImage: "arrow.right.circle") }
            Button(role: .destructive) {
                pendingStop = MemoryStopTarget(conversationId: q.conversationId, title: q.title)
            } label: { Label("这个对话不记", systemImage: "nosign") }
        }
    }

    /// 窗口名 / 从哪天到哪天 · 记了几段；删了的变灰
    private func row(_ r: WindowSummaryRow) -> some View {
        Button {
            detail = r
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title.isEmpty ? "没有标题的窗口" : r.title)
                    .font(.system(size: m.bodySize, weight: .semibold))
                    .foregroundColor(r.isGone ? Theme.textMuted : Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle(r))
                    .font(.system(size: m.secondarySize))
                    .foregroundColor(r.isGone ? Theme.textMuted : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { open(r.conversationId) } label: { Label("去这个窗口", systemImage: "arrow.right.circle") }
                .disabled(r.isGone)
            if !r.isGone {
                Button(role: .destructive) {
                    pendingStop = MemoryStopTarget(conversationId: r.conversationId, title: r.title)
                } label: { Label("这个对话以后不记", systemImage: "nosign") }
            }
        }
    }

    private func subtitle(_ r: WindowSummaryRow) -> String {
        let parts = [WindowSummaryListLayout.dateRange(first: r.first, last: r.last), "记了 \(r.segmentCount) 段"].compactMap { $0 }
        let text = parts.joined(separator: " · ")
        return r.isGone ? "\(text) · 这个窗口已经删了" : text
    }

    private func open(_ conversationId: String) {
        if !MemoryConversationLink.open(conversationId, profileId: profileId, context: modelContext, viewModel: viewModel) {
            model.markGone(conversationId)
        }
    }
}
