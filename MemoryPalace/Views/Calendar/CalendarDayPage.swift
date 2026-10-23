import SwiftUI
import SwiftData

// MARK: - 每日页（plan-calendar §七 P4）
// 顶上一朵点阵花（p7，按日期固定抽）→ 我的日记 → 那年今天 → AI 的日记 → 这天聊了 → 记住了 → 这一天还有（健康 / 心情）。
// 没数据的块整块不出；亲密记录永远不进这里。

struct CalendarDayItem: Identifiable, Equatable {
    let date: Date
    var id: String { DailyActivity.dayKey(date, calendar: .current) }
}

/// 当日健康一句话（日历当天卡与每日页共用；亲密记录不进）
enum CalendarDayHealth {
    @MainActor
    static func summary(context: ModelContext, profileId: String, date: Date) -> String? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        var parts: [String] = []
        if let cycleDay = HealthCycleStore.fetchDay(context: context, profileId: profileId, date: dayStart),
           let flow = CycleFlow(rawValue: cycleDay.flow) {
            let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: profileId))
            if let period = periods.last(where: { $0.start <= dayStart && dayStart <= $0.end }),
               let n = cal.dateComponents([.day], from: period.start, to: dayStart).day {
                parts.append("经期第 \(n + 1) 天 · 经量\(flow.label)")
            } else {
                parts.append("经期打点 · 经量\(flow.label)")
            }
        }
        var weightDescriptor = FetchDescriptor<WeightEntry>(predicate: #Predicate { $0.profileId == profileId && $0.date == dayStart })
        weightDescriptor.fetchLimit = 1
        if let w = try? context.fetch(weightDescriptor).first {
            let unit = WeightUnit.current
            parts.append("体重 \(String(format: "%.1f", unit.fromKg(w.weightKg))) \(unit.label)")
        }
        let logs = (try? context.fetch(FetchDescriptor<MedicationLog>(
            predicate: #Predicate { $0.profileId == profileId && $0.takenAt >= dayStart && $0.takenAt < dayEnd }
        ))) ?? []
        if !logs.isEmpty {
            // 药名查含归档全集——历史日可能是已停的药
            let meds = (try? context.fetch(FetchDescriptor<Medication>(predicate: #Predicate { $0.profileId == profileId }))) ?? []
            let nameById = Dictionary(uniqueKeysWithValues: meds.map { ($0.id, $0.name) })
            parts.append(Array(Set(logs.map { nameById[$0.medicationId] ?? "药" })).sorted().map { "\($0) ✓" }.joined(separator: " "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 心情对应的刺绣小花（p8）：每种一朵不同的
enum JournalMoodLook {
    static func pattern(_ m: JournalMood) -> String {
        switch m {
        case .happy: "tulip"
        case .calm: "sprig"
        case .meh: "quatre"
        case .tired: "bell"
        case .sad: "star8"
        }
    }

    static func color(_ m: JournalMood) -> Color {
        switch m {
        case .happy: CalendarInk.Stitch.orange
        case .calm: CalendarInk.Stitch.olive
        case .meh: CalendarInk.Stitch.lilac
        case .tired: CalendarInk.Stitch.pink
        case .sad: CalendarInk.Stitch.navy
        }
    }
}

/// 一朵点阵小花（p5 / p7 / p8 三种画法）
struct DotFlower: View {
    let pattern: String
    var mode: CalendarInk.DotMode = .dot
    var cell: CGFloat = 3
    var head: Color = CalendarInk.graphite
    var stem: Color?
    var core: Color?
    var seed: UInt64 = 1

    var body: some View {
        let p = CalendarInk.patterns[pattern] ?? CalendarInk.patterns["daisy"]!
        Canvas { ctx, _ in
            var rng = CalendarInk.Rand(seed: seed)
            CalendarInk.draw(p, mode: mode, in: &ctx, origin: CGPoint(x: cell, y: cell), cell: cell,
                             head: head, stem: stem, core: core, rng: &rng)
        }
        .frame(width: CGFloat(p.width + 1) * cell, height: CGFloat(p.height + 1) * cell)
        .accessibilityHidden(true)
    }
}

struct CalendarDayPage: View {
    let date: Date
    let profileId: String
    var viewModel: ConversationViewModel
    var onOpenConversation: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("assistantName") private var assistantName = "助手"
    @AppStorage(CalendarLook.storageKey) private var lookRaw = CalendarLook.paper.rawValue
    @State private var activity = CalendarActivityModel.shared
    @State private var journal: JournalDocument?
    @State private var aiDiary: DailyNote?
    @State private var aiDiaryExpanded = false
    @State private var memories: [Memory] = []
    @State private var moreMemories = false
    @State private var editing = false
    @State private var showDiaryList = false
    @Query private var conversations: [Conversation]

    private let calendar = Calendar.current

    init(date: Date, profileId: String, viewModel: ConversationViewModel, onOpenConversation: @escaping () -> Void = {}) {
        self.date = date
        self.profileId = profileId
        self.viewModel = viewModel
        self.onOpenConversation = onOpenConversation
        _conversations = Query(filter: #Predicate<Conversation> { $0.profileId == profileId && !$0.isTrashed })
    }

    private var key: String { DailyActivity.dayKey(date, calendar: calendar) }
    private var journalStore: JournalStore { JournalStore.forProfile(profileId) }
    private var journalVisible: Bool { CalendarPrivacy().journalVisible(profileId) }

    var body: some View {
        Group {
            if lookRaw == CalendarLook.ios.rawValue { iosBody } else { paperBody }
        }
        .task(id: key) { load() }
        .sheet(isPresented: $editing, onDismiss: load) {
            JournalEditorView(date: date, profileId: profileId)
        }
        .sheet(isPresented: $showDiaryList) {
            // 现有缺口：列表里点某天只关列表，不跳那天（plan-calendar-page 裁定 #3）
            DiaryListSheet(profileId: profileId) { _ in showDiaryList = false }
        }
    }

    private var paperBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                PencilRule(seed: "day-todo")
                CalendarTodoList(dayKey: key)
                PencilRule(seed: "day-journal")
                journalSection
                PencilRule(seed: "day-mood")
                moodSection
                chattedSection
                aiDiarySection
                memoriesSection
                onThisDaySection
                healthSection
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(CalInk.paper.ignoresSafeArea())
    }

    private func load() {
        journal = journalStore.load(date: key)
        aiDiary = DailyFileStore.load(date: key, profileId: profileId)
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        var d = FetchDescriptor<Memory>(
            predicate: #Predicate { $0.profileId == profileId && $0.createdAt >= start && $0.createdAt < end && $0.supersededAt == nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        d.fetchLimit = 6
        let fetched = (try? modelContext.fetch(d)) ?? []
        memories = Array(fetched.prefix(5))
        moreMemories = fetched.count > 5
    }

    // MARK: 顶

    private var header: some View {
        let name = CalendarInk.dailyPatternNames[Int(CalendarInk.seed(key) % UInt64(CalendarInk.dailyPatternNames.count))]
        return HStack(alignment: .bottom, spacing: 14) {
            DotFlower(pattern: name, cell: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .font(CalType.hand(CalType.d))
                    .foregroundColor(CalInk.ink)
                Text(Self.englishLine(date))
                    .font(CalType.type(CalType.m))
                    .tracking(1)
                    .foregroundColor(CalInk.ink3)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    static func englishLine(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM · EEEE"
        return f.string(from: date).lowercased()
    }

    // MARK: 我的日记（整块是一个按钮：点了编辑）

    private var journalSection: some View {
        let body = journal?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Button { editing = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // 看得到 / 看不到跟隐私开关走，不能写死（astra #1）
                    Text("我的日记 · \(assistantName)\(journalVisible ? "看得到" : "看不到")")
                        .font(.system(size: CalType.s)).tracking(0.5).foregroundColor(CalInk.ink3)
                    Spacer()
                    Text("编辑 ›").font(.system(size: CalType.s)).foregroundColor(CalInk.ink)
                }
                .padding(.horizontal, 22)
                .frame(minHeight: 44)
                if body.isEmpty {
                    Text("还没写，点编辑开始")
                        .font(.system(size: CalType.s)).foregroundColor(CalInk.ink3)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 8)
                } else {
                    JournalDotPaper(markdown: body)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PencilPressStyle())
        .accessibilityHint("编辑这天的日记")
    }

    // MARK: 心情（选中的画铅笔圈；再点一次取消）

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            CalendarSectionLabel(text: "心情").padding(.top, 8)
            HStack(spacing: 0) {
                ForEach(JournalMood.allCases, id: \.self) { m in
                    let on = journal?.mood == m
                    Button { setMood(m) } label: {
                        VStack(spacing: 8) {
                            DotFlower(pattern: JournalMoodLook.pattern(m), mode: .stitch, cell: 2.5,
                                      head: JournalMoodLook.color(m), stem: CalendarInk.Stitch.leaf, core: CalendarInk.Stitch.rust,
                                      seed: CalendarInk.seed(m.rawValue))
                                .padding(7)
                                .background { if on { PencilRingView(seed: "mood-\(m.rawValue)") } }
                            Text(m.label).font(.system(size: CalType.s)).foregroundColor(on ? CalInk.ink : CalInk.ink2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("心情：\(m.label)")
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    // MARK: 这天聊了（按贡献反查，astra #4）

    @ViewBuilder
    private var chattedSection: some View {
        let byConv = activity.summary.conversationsByDay[key] ?? [:]
        if !byConv.isEmpty {
            let byId = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let rows = byConv.sorted { $0.value > $1.value }.compactMap { e in byId[e.key].map { ($0, e.value) } }
            PencilRule(seed: "day-chat")
            CalendarSectionLabel(text: "这天聊了").padding(.top, 8)
            ForEach(rows, id: \.0.id) { conv, n in
                CalendarRow(icon: CalendarRow.icon(for: conv), title: conv.title, tag: CalendarRow.tag(for: conv), meta: "\(n) 条") { open(conv) }
            }
        }
    }

    // MARK: AI 的日记（四行预览 ↔ 全文；「全部日记 ›」进列表）

    @ViewBuilder
    private var aiDiarySection: some View {
        if let aiDiary {
            PencilRule(seed: "day-ai")
            CalendarSectionLabel(text: "\(assistantName)的日记").padding(.top, 8)
            Text(aiDiary.text)
                .font(.system(size: CalType.b))
                .foregroundColor(CalInk.ink)
                .lineSpacing(5)
                .lineLimit(aiDiaryExpanded ? nil : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { aiDiaryExpanded.toggle() } }
            CalendarRow(icon: "book.closed", title: "全部日记") { showDiaryList = true }
        }
    }

    // MARK: 记住了（只读，没有 ›）

    @ViewBuilder
    private var memoriesSection: some View {
        if !memories.isEmpty {
            PencilRule(seed: "day-mem")
            CalendarSectionLabel(text: "\(assistantName)记住了").padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(memories, id: \.id) { m in
                    Text("· \(m.content)").font(.system(size: CalType.b)).foregroundColor(CalInk.ink).lineLimit(2)
                }
                if moreMemories {
                    Text("还有更多，去记忆页看").font(.system(size: CalType.s)).foregroundColor(CalInk.ink3)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
        }
    }

    // MARK: 那年今天（按真实年份标，astra #7）

    @ViewBuilder
    private var onThisDaySection: some View {
        let items = Self.onThisDay(date, summary: activity.summary, conversations: conversations, calendar: calendar)
        if !items.isEmpty {
            PencilRule(seed: "day-past")
            CalendarSectionLabel(text: "那年今天").padding(.top, 8)
            ForEach(items, id: \.conv.id) { item in
                CalendarRow(icon: "sparkle", title: "\(CalendarText.yearsAgo(item.years))：\(item.conv.title)") { open(item.conv) }
            }
        }
    }

    /// 1...3 年前的今天，每年聊得最多的那段（2-29 在平年不凑）
    static func onThisDay(_ date: Date, summary: DailyActivity.Summary, conversations: [Conversation], calendar: Calendar) -> [(years: Int, conv: Conversation)] {
        let byId = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [(years: Int, conv: Conversation)] = []
        for y in 1...3 {
            guard let past = calendar.date(byAdding: .year, value: -y, to: date),
                  calendar.component(.day, from: past) == calendar.component(.day, from: date) else { continue }
            let convs = summary.conversationsByDay[DailyActivity.dayKey(past, calendar: calendar)] ?? [:]
            if let top = convs.max(by: { $0.value < $1.value }), let c = byId[top.key] { out.append((y, c)) }
        }
        return out
    }

    // MARK: 健康（只读完整摘要）

    @ViewBuilder
    private var healthSection: some View {
        if let health = CalendarDayHealth.summary(context: modelContext, profileId: profileId, date: date) {
            PencilRule(seed: "day-health")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "heart").font(.system(size: 13)).foregroundColor(CalInk.ink2)
                Text(health).font(.system(size: CalType.s)).foregroundColor(CalInk.ink2)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
    }

    private func setMood(_ m: JournalMood) {
        let next: JournalMood? = journal?.mood == m ? nil : m
        try? journalStore.setMood(next, date: key)
        load()
    }

    private func open(_ conv: Conversation) {
        viewModel.loadConversation(conv, context: modelContext)
        onOpenConversation()
        dismiss()
    }
}

// MARK: - 每日页 · iOS 风（plan-calendar-v5）：同一张票根纸，段间缺口；空段不出、不留连续缺口

extension CalendarDayPage {
    private var chattedRows: [(Conversation, Int)] {
        let byConv = activity.summary.conversationsByDay[key] ?? [:]
        let byId = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return byConv.sorted { $0.value > $1.value }.compactMap { e in byId[e.key].map { ($0, e.value) } }
    }

    var iosBody: some View {
        let chat = chattedRows
        let past = Self.onThisDay(date, summary: activity.summary, conversations: conversations, calendar: calendar)
        let health = CalendarDayHealth.summary(context: modelContext, profileId: profileId, date: date)
        return ScrollView {
            CalendarTicket {
                CalendarTodoList(dayKey: key, look: .ios)
                TicketNotch()
                iosJournal
                iosMood
                if let aiDiary {
                    TicketNotch()
                    iosAIDiary(aiDiary)
                }
                if !chat.isEmpty || !past.isEmpty {
                    TicketNotch()
                    if !chat.isEmpty {
                        IOSSubLabel(text: "这天聊了")
                        ForEach(chat, id: \.0.id) { conv, n in
                            IOSCalendarRow(icon: CalendarRow.icon(for: conv), title: conv.title, tag: CalendarRow.tag(for: conv), meta: "\(n) 条") { open(conv) }
                        }
                    }
                    if !past.isEmpty {
                        IOSSubLabel(text: "那年今天")
                        ForEach(past, id: \.conv.id) { item in
                            IOSCalendarRow(icon: "sparkle", title: "\(CalendarText.yearsAgo(item.years))：\(item.conv.title)") { open(item.conv) }
                        }
                    }
                }
                if !memories.isEmpty {
                    TicketNotch()
                    IOSSubLabel(text: "\(assistantName)记住了")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(memories, id: \.id) { m in
                            Text("· \(m.content)").font(.system(size: 15)).foregroundColor(Theme.textPrimary).lineLimit(2)
                        }
                        if moreMemories {
                            Text("还有更多，去记忆页看").font(.system(size: 13)).foregroundColor(Theme.textMuted)
                        }
                    }
                    .padding(.horizontal, IOSCal.pad)
                    .padding(.vertical, 8)
                }
                if let health {
                    TicketNotch()
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "heart").font(.system(size: 13)).foregroundColor(Theme.textMuted)
                        Text(health).font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                    }
                    .padding(.horizontal, IOSCal.pad)
                    .padding(.vertical, 12)
                }
                Color.clear.frame(height: 12)
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Theme.sidebarBg.ignoresSafeArea().allowsHitTesting(false))
    }

    /// 我的日记：整段点了编辑（和纸一样）
    private var iosJournal: some View {
        let text = journal?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Button { editing = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("我的日记 · \(assistantName)\(journalVisible ? "看得到" : "看不到")")
                        .font(.system(size: 12)).tracking(0.5).foregroundColor(Theme.textMuted)
                    Spacer()
                    Text("编辑").font(.system(size: 13)).foregroundColor(Theme.branchIndicator)
                }
                .padding(.top, 14)
                .padding(.bottom, 6)
                if text.isEmpty {
                    Text("还没写，点编辑开始").font(.system(size: 13)).foregroundColor(Theme.textMuted)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(JournalDotPaper.lines(text).enumerated()), id: \.offset) { _, line in
                            switch line {
                            case .heading(let t): Text(t).fontWeight(.semibold)
                            case .todo(let t, let done): Text("\(done ? "☑" : "☐")  \(t)")
                            case .text(let t): Text(t)
                            case .blank: Color.clear.frame(height: 4)
                            }
                        }
                    }
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textPrimary)
                    .lineSpacing(4)
                }
            }
            .padding(.horizontal, IOSCal.pad)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("编辑这天的日记")
    }

    /// 心情：五个彩色圆点，选中的外面一圈；再点一次取消
    private var iosMood: some View {
        VStack(alignment: .leading, spacing: 0) {
            IOSSubLabel(text: "心情")
            HStack(spacing: 0) {
                ForEach(JournalMood.allCases, id: \.self) { m in
                    let on = journal?.mood == m
                    Button { setMood(m) } label: {
                        VStack(spacing: 6) {
                            Circle().fill(JournalMoodLook.color(m))
                                .frame(width: 30, height: 30)
                                .padding(3.5)
                                .overlay { if on { Circle().strokeBorder(Theme.textPrimary, lineWidth: 1.5) } }
                            Text(m.label).font(.system(size: 12, weight: on ? .semibold : .regular))
                                .foregroundColor(on ? Theme.textPrimary : Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("心情：\(m.label)")
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
    }

    private func iosAIDiary(_ note: DailyNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            IOSSubLabel(text: "\(assistantName)的日记")
            Text(note.text)
                .font(.system(size: 16))
                .foregroundColor(Theme.textSecondary)
                .lineSpacing(4)
                .lineLimit(aiDiaryExpanded ? nil : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, IOSCal.pad)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { aiDiaryExpanded.toggle() } }
            IOSCalendarRow(icon: "book.closed", title: "全部日记") { showDiaryList = true }
        }
    }
}

extension CalendarRow {
    /// 行首图标：和对话列表同一套判断（CC / codex / 导入 / 聊天），日历里统一铅笔灰
    static func icon(for c: Conversation) -> String {
        if let name = c.ccBridgeSessionName, !name.isEmpty { return "chevron.left.forwardslash.chevron.right" }
        if Conversation.importedProviders.contains(c.provider) { return "archivebox" }
        return "bubble.left"
    }

    static func tag(for c: Conversation) -> String? {
        guard let name = c.ccBridgeSessionName, !name.isEmpty else { return nil }
        return ConversationRow.sessionShortName(name)
    }
}

/// 小叮当式米字闪星（p6）
struct SparkleMark: View {
    var color: Color = CalendarInk.graphite
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            ctx.stroke(CalendarInk.sparkle(center: CGPoint(x: size.width / 2, y: size.height / 2), radius: r * 0.9),
                       with: .color(color), style: StrokeStyle(lineWidth: max(0.8, r * 0.16), lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 日记编辑

struct JournalEditorView: View {
    let date: Date
    let profileId: String

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var baseHash: String?
    @State private var newFileFrontmatter: [String] = []
    @State private var loaded = false
    @State private var conflict = false
    @State private var dirty = false

    private var key: String { DailyActivity.dayKey(date, calendar: .current) }
    private var store: JournalStore { JournalStore.forProfile(profileId) }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .background(Theme.mainBg)
                .onChange(of: text) { _, _ in if loaded { dirty = true } }
                .navigationTitle(CalendarDayPage.englishLine(date))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { if save() { dismiss() } }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .onAppear(perform: load)
        .alert("这篇日记在别处被改过", isPresented: $conflict) {
            Button("用磁盘上的版本") { load() }
            Button("用我这份覆盖", role: .destructive) {
                _ = try? store.overwriteBody(text, date: key, newFileFrontmatter: newFileFrontmatter)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("可能是另一台设备、文件 app 或 Obsidian 改的。")
        }
    }

    private func load() {
        let doc = store.load(date: key)
        if let doc, !doc.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = doc.body
            baseHash = doc.diskHash
        } else {
            // 第一次点开写才展开模板（plan §3.1）；只点过心情的文件正文是空的，也套模板。
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "EEEE"
            let t = JournalStore.expandTemplate(JournalStore.defaultTemplate, date: key, weekday: f.string(from: date))
            text = t.body
            newFileFrontmatter = t.frontmatter
            baseHash = doc?.diskHash
        }
        dirty = false
        DispatchQueue.main.async { loaded = true }
    }

    /// 返回 true = 可以关了
    private func save() -> Bool {
        guard dirty else { return true }
        do {
            baseHash = try store.saveBody(text, date: key, baseHash: baseHash, newFileFrontmatter: newFileFrontmatter)
            dirty = false
            NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
            return true
        } catch JournalStoreError.conflict {
            conflict = true
            return false
        } catch {
            return false
        }
    }
}
