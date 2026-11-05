import SwiftUI
import SwiftData

// MARK: - 记忆 v5 的二级页（设置 → 记忆；记忆 app「设置」格同一份）
// 编号页同一个模板（plan §二）：开关 → 状态 → 模型 → 各自的行 → 本期花费。
// 二级页只在 iOS 设标题（mac 设置窗由宿主按 SettingsRoute.title 给；右栏宿主里不带 navigationTitle）

private struct MemorySubpageChrome: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        #else
        content
            .scrollContentBackground(.hidden)
        #endif
    }
}

extension View {
    func memorySubpage(_ title: String) -> some View { modifier(MemorySubpageChrome(title: title)) }
}

/// 楼层的{助手}名（UI 不写死）
private func floorAssistantName(_ pm: ProfileManager?) -> String {
    let n = pm?.currentProfile.assistantName ?? ""
    return n.isEmpty ? "助手" : n
}

/// 一行：标题 + 一句话（副标题短、只描述功能）
private struct SubRowLabel: View {
    @Environment(\.settingsMetrics) private var m
    let title: String
    var sub: String? = nil
    var titleColor: Color = Theme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(m.body)
                .foregroundColor(titleColor)
            if let sub, !sub.isEmpty {
                Text(sub)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 数字步进器一行（值写在副标题里，390 宽右边只放 − +）
private struct LimitStepper: View {
    @Environment(\.settingsMetrics) private var m
    let title: String
    let value: String
    @Binding var number: Int
    let range: ClosedRange<Int>
    var step: Int = 1

    var body: some View {
        Stepper(value: $number, in: range, step: step) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                Text(value)
                    .font(m.caption.monospaced())
                    .foregroundColor(Theme.textMuted)
            }
        }
    }
}

// MARK: - 本期花了多少（账本里这一类用途；后台读）

enum MemoryWriterSpend {
    /// 本期从哪起：写入预算开着按它的周期；关着按本月
    static func since(now: Date = Date(), calendar: Calendar = .current) -> (Date, String) {
        let store = WriteBudgetStore.shared
        if let s = WriteBudgetStore.since(period: store.period, resetAt: store.resetAt, now: now, calendar: calendar) {
            return (s, store.period == .week ? "这周" : "今天")
        }
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? now
        return (month, "这个月")
    }

    static func kind(_ id: MemoryWriterID) -> UsageKind? {
        switch id {
        case .a2: return .summary
        case .a3: return .windowSummary
        case .a4: return .timeline
        case .c2: return .memory
        case .c3: return .catalog
        default: return nil
        }
    }

    /// 后台：每类花了多少（wiki 种子不算写入预算，单列给 C3 页看）
    static func load(since: Date) async -> [UsageKind: Double] {
        await Task.detached(priority: .utility) {
            let records = UsageLedger.shared.load(since: since)
            var out: [UsageKind: Double] = [:]
            for k in WriteBudgetStore.kinds.union([.catalogSeed]) {
                out[k] = GlobalBudgetStore.ledgerSpentUSD(records: records.filter { $0.kind == k }, since: since)
            }
            return out
        }.value
    }
}

// MARK: - 状态行（点了跳日志里这一项最近那条）

struct MemoryWriterStatusRow: View {
    let id: MemoryWriterID
    let profileId: String
    @Environment(\.settingsMetrics) private var m
    @State private var status: MemoryHealthStore.Status?
    @State private var paused = false
    @State private var showLog = false

    var body: some View {
        Button { showLog = true } label: {
            HStack(spacing: 8) {
                if let s = status, let kind = id.health {
                    if !MemoryHealthStore.isOn(kind) {
                        SubRowLabel(title: "状态", sub: "关着，没在写")
                    } else if paused {
                        SubRowLabel(title: "状态", sub: WriteBudgetStore.pausedText(period: WriteBudgetStore.shared.period))
                    } else if s.needsAttention {
                        SubRowLabel(title: "连续 \(s.failStreak) 次没写成", sub: MemoryHealthStatusView.failureDetail(s), titleColor: Theme.danger)
                    } else {
                        SubRowLabel(title: "状态", sub: s.lastOK.map { "上次写成 · \(MemoryHealthStatusView.relative($0))" } ?? "还没写过")
                    }
                } else {
                    SubRowLabel(title: "状态", sub: " ")
                }
                Image(systemName: "chevron.right")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showLog) {
            MemoryWriteLogSheet(profileId: profileId, focus: id)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in reload() }
    }

    private func reload() {
        guard let kind = id.health else { return }
        status = MemoryHealthStore.status(kind, profileId: profileId)
        Task {
            let over = await Task.detached(priority: .utility) { WriteBudgetStore.exceeded() }.value
            paused = over
        }
    }
}

/// C3 的状态行：在整理就写到哪了，没在整理写最近一条日志
private struct CatalogStatusRow: View {
    let profileId: String
    @Environment(\.settingsMetrics) private var m
    @AppStorage("mem_write_c3") private var writeC3 = true
    @State private var runner = CatalogRunner.shared
    @State private var latest: MemoryWriteLog.Entry?
    @State private var paused = false
    @State private var showLog = false

    private var sub: String {
        if runner.isRunning {
            let topic = runner.currentTopic.map { "正在整理：\($0)" + (runner.round > 0 ? "（第 \(runner.round) 轮）" : "") } ?? "正在整理"
            return topic + (runner.queued > 0 ? " · 后面排着 \(runner.queued) 次" : "")
        }
        if !writeC3 { return "关着，没在整理" }
        if paused { return WriteBudgetStore.pausedText(period: WriteBudgetStore.shared.period) }
        guard let e = latest else { return "还没整理过" }
        return "\(MemoryHealthStatusView.relative(e.time)) · \(e.note)"
    }

    var body: some View {
        Button { showLog = true } label: {
            HStack(spacing: 8) {
                SubRowLabel(title: "状态", sub: sub, titleColor: latest?.ok == false && !runner.isRunning ? Theme.danger : Theme.textPrimary)
                Image(systemName: "chevron.right")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showLog) {
            MemoryWriteLogSheet(profileId: profileId, focus: .c3)
        }
        .task(id: runner.isRunning) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in Task { await reload() } }
    }

    private func reload() async {
        let pid = profileId
        let (entry, over) = await Task.detached(priority: .utility) {
            (MemoryWriteLog.latest(.c3, in: MemoryWriteLog.entries(profileId: pid)), WriteBudgetStore.exceeded())
        }.value
        latest = entry
        paused = over
    }
}

/// wiki 体检：每天自动整理后代码查一次，这里显示条数，点开看明细
private struct CatalogHealthRow: View {
    let profileId: String
    @Environment(\.settingsMetrics) private var m
    @State private var runner = CatalogRunner.shared
    @State private var health: WikiHealth?
    @State private var showDetails = false

    private var sub: String {
        guard let health else { return "每天自动整理后查一次断链、孤页、目录漂移，只报告不改页" }
        return health.summary + " · " + MemoryHealthStatusView.relative(health.at)
    }

    var body: some View {
        Button { showDetails = true } label: {
            HStack(spacing: 8) {
                SubRowLabel(title: "wiki 体检", sub: sub)
                if health != nil {
                    Image(systemName: "chevron.right")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(health == nil)
        .sheet(isPresented: $showDetails) {
            if let health { CatalogHealthSheet(health: health) }
        }
        .task(id: profileId) {
            health = nil
            await reload()
        }
        .onChange(of: runner.lastFinishedAt) { _, _ in Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in Task { await reload() } }
    }

    private func reload() async {
        let pid = profileId
        let loaded = await Task.detached(priority: .utility) { WikiHealth.load(WikiStore(profileId: pid)) }.value
        guard !Task.isCancelled, profileId == pid else { return }
        health = loaded
    }
}

private struct CatalogHealthSheet: View {
    let health: WikiHealth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        NavigationStack {
            List {
                section("断链", note: "「连到」指向的页不存在", health.brokenLinks.map { "\($0.from) → \($0.to)" })
                section("孤页", note: "没有页连向它，也不在任何分组里", health.orphans)
                section("目录漂移", note: health.drift.isEmpty ? "" : health.rebuildError.map { "索引没重建成：\($0)" } ?? "已按代码重建索引，这里是重建前的差异",
                        health.drift)
            }
            .panelListStyle()
            .scrollContentBackground(.hidden)
            .toolPageBackground()
            .panelSheetTitle("wiki 体检")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
            #if os(macOS)
            .frame(minWidth: 440, idealWidth: 520, minHeight: 420, idealHeight: 560)
            #endif
        }
    }

    private func section(_ title: String, note: String, _ rows: [String]) -> some View {
        Section {
            if rows.isEmpty {
                Text("没有").font(m.body).foregroundColor(Theme.textMuted)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Text(row).font(m.body).foregroundColor(Theme.textPrimary).textSelection(.enabled)
            }
        } header: {
            Text("\(title) · \(rows.count)")
        } footer: {
            if !note.isEmpty { Text(note).font(m.caption) }
        }
        .panelRowBackground()
    }
}

/// 人设变化只手动发起（不监听自动重播）：点这一下就是方向授权，一个 agent 对照现在的人设改 wiki，正文照样等她批
private struct CatalogPersonaChangeRow: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @AppStorage("mem_master") private var memMaster = true
    @AppStorage("mem_write_c3") private var writeC3 = true
    @State private var runner = CatalogRunner.shared

    private var c3On: Bool {
        _ = (memMaster, writeC3)
        return MemoryWriterSettings.writes(.c3)
    }

    var body: some View {
        Button {
            if let p = profileManager?.currentProfile { runner.personaChanged(profile: p) }
        } label: {
            SubRowLabel(title: CatalogSession.personaRequest, sub: "对照现在的人设查 wiki 里过时、矛盾的页；改出来的正文进审计台 › wiki › 整理提案等你批")
        }
        .buttonStyle(.plain)
        .disabled(!c3On || runner.isRunning)
    }
}

/// 种子：两个入口（CC 记忆 / 人设）同一个任务机制。一个 agent 全读原料 → 目录交审计台 → 批了逐页写 → 正文再批
private struct CatalogSeedSection: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage("mem_master") private var memMaster = true
    @AppStorage("mem_write_c3") private var writeC3 = true
    @State private var runner = CatalogRunner.shared
    @State private var latest: (task: CatalogSeedTask, status: CatalogSeedTask.Status)?
    @State private var completedAt: Date?
    @State private var loadedProfileId: String?
    @State private var askAbandon = false

    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private var c3On: Bool {
        _ = (memMaster, writeC3)
        return MemoryWriterSettings.writes(.c3)
    }
    private var loaded: Bool { loadedProfileId == profileId && profileManager != nil }
    private var open: (task: CatalogSeedTask, status: CatalogSeedTask.Status)? {
        guard loaded, let latest, latest.status.isOpen else { return nil }
        return latest
    }
    private var canStart: Bool { c3On && !runner.isRunning && loaded && open == nil }
    private var runningText: String {
        let topic = runner.currentTopic.map {
            "正在整理：\($0)" + (runner.round > 0 ? "（第 \(runner.round) 轮）" : "")
        } ?? "正在整理"
        return topic + (runner.queued > 0 ? " · 后面排着 \(runner.queued) 次" : "")
    }

    var body: some View {
        Section {
            Button { start(.persona) } label: { SubRowLabel(title: "从人设生成基础 wiki") }
                .buttonStyle(.plain)
                .disabled(!canStart)
            Button { start(.cc) } label: { SubRowLabel(title: "从 CC 记忆播种") }
                .buttonStyle(.plain)
                .disabled(!canStart)
            if let open {
                SubRowLabel(title: "种子任务（\(open.task.entry.label)）· \(open.status.text)", sub: open.task.note)
                if case .waitingOutline = open.status {
                    SubRowLabel(title: "去审计台 › wiki › 整理提案批目录", titleColor: Theme.textMuted)
                } else {
                    Button { resume(open.task.id) } label: { SubRowLabel(title: "继续这个种子任务") }
                        .buttonStyle(.plain)
                        .disabled(!c3On || runner.isRunning)
                }
                Button { askAbandon = true } label: { SubRowLabel(title: "放弃这次种子", titleColor: Theme.danger) }
                    .buttonStyle(.plain)
                    .disabled(runner.isRunning)
            } else if loaded, let completedAt {
                SubRowLabel(title: "种子完成 · \(completedAt.formatted(date: .numeric, time: .shortened))")
            }
            if runner.isRunning {
                HStack(spacing: 8) {
                    SubRowLabel(title: runningText)
                    Button("停止") { runner.cancel() }
                        .font(m.caption)
                        .foregroundColor(Theme.danger)
                        .buttonStyle(.borderless)
                }
            } else if let report = runner.lastReport {
                Text("上次：" + report.summary)
                    .font(m.caption)
                    .foregroundColor(report.failures.isEmpty ? Theme.textMuted : Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !c3On {
                SubRowLabel(title: "记忆总开关或 C3 关着，开启后才能播种", titleColor: Theme.textMuted)
            }
        } header: {
            Text("种子")
        } footer: {
            Text("读本楼层 Prompt 里填的全部文字、CC 记忆和现有 wiki，先交一份目录给你批，批了再一页一页写，写好的正文再批一次才进 wiki。不算写入预算，随时能停。")
                .font(m.caption)
        }
        .panelRowBackground()
        .alert("放弃这次种子？", isPresented: $askAbandon) {
            Button("放弃", role: .destructive) { abandon() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("还没批的目录项会驳回；已经交了的正文提案还在审计台 › wiki › 整理提案，照常可以批。")
        }
        .task(id: profileId) {
            latest = nil
            completedAt = nil
            loadedProfileId = nil
            askAbandon = false
            await reload()
        }
        .onChange(of: runner.lastFinishedAt) { _, _ in Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in Task { await reload() } }
    }

    private func start(_ entry: CatalogSeedEntry) {
        guard canStart, let profile = profileManager?.currentProfile else { return }
        runner.seed(profile: profile, entry: entry)
    }

    private func resume(_ taskId: String) {
        guard let profile = profileManager?.currentProfile else { return }
        runner.resumeSeed(taskId, profile: profile)
    }

    private func abandon() {
        guard let open, let profile = profileManager?.currentProfile else { return }
        runner.abandonSeed(open.task.id, profile: profile)
    }

    private func reload() async {
        let pid = profileId
        let (task, date) = await Task.detached(priority: .utility) { () -> ((CatalogSeedTask, CatalogSeedTask.Status)?, Date?) in
            let wiki = WikiStore(profileId: pid)
            let proposals = WikiProposalStore(wiki: wiki)
            // 三问和种子可能同时各开着一个：先显示还开着的（新的在前），都结束了再显示最近一个
            let store = CatalogSeedTaskStore(wiki: wiki)
            let latest = store.open(proposals: proposals) ?? store.latest(proposals: proposals).map { (task: $0.task, status: $0.task.status(outline: $0.outline)) }
            return (latest, CatalogSeed.completion(wiki: wiki)?.at)
        }.value
        guard !Task.isCancelled, profileId == pid else { return }
        latest = task
        completedAt = date
        loadedProfileId = pid
    }
}

// MARK: - C3 › 不触发的词（wiki 里的 `不触发的词.txt`，一行一个）

struct CatalogStopWordsPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var words: [String] = []
    @State private var draft = ""
    @State private var loaded = false

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                HStack {
                    TextField("加一个词", text: $draft)
                        .font(m.body)
                        .onSubmit(add)
                    Button("加", action: add)
                        .foregroundColor(Theme.branchIndicator)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if loaded && words.isEmpty {
                    SubRowLabel(title: "没有")
                        .opacity(0.5)
                }
                ForEach(words, id: \.self) { word in
                    SubRowLabel(title: word)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("删掉", role: .destructive) { remove(word) }
                        }
                        .contextMenu {
                            Button("删掉", role: .destructive) { remove(word) }
                        }
                }
            } footer: {
                Text("聊天里出现这些词，不会带出 wiki 页")
                    .font(m.caption)
            }
            .panelRowBackground()
        }
        .memorySubpage("不触发的词")
        .task { await reload() }
    }

    private func reload() async {
        let pid = profileId
        words = await Task.detached(priority: .utility) { WikiStore(profileId: pid).stopWords() }.value
        loaded = true
    }

    private func add() {
        let w = draft.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        draft = ""
        save(words.contains(w) ? words : words + [w])
    }

    private func remove(_ word: String) {
        save(words.filter { $0 != word })
    }

    private func save(_ list: [String]) {
        words = list
        let pid = profileId
        Task {
            await Task.detached(priority: .utility) { try? WikiStore(profileId: pid).setStopWords(list) }.value
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        }
    }
}

// MARK: - 编号二级页

struct MemoryWriterPage: View {
    let id: MemoryWriterID
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.settingsMetrics) private var m

    @AppStorage("mem_content_summary") private var writeA2 = true
    @AppStorage("mem_write_a3") private var writeA3 = true
    @AppStorage("mem_content_timeline") private var writeA4 = true
    @AppStorage("mem_content_heartvoice") private var writeB1 = false
    @AppStorage("mem_write_b4") private var writeB4 = true
    @AppStorage("mem_content_facts") private var writeC2 = true
    @AppStorage("heartvoice_show_in_chat") private var heartvoiceShowInChat = false
    @AppStorage("mem_self_daily_limit") private var selfDailyLimit = 12
    @AppStorage("mem_self_body_limit") private var selfBodyLimit = 800
    @AppStorage(FragmentWatch.everyKey) private var c2Every = FragmentWatch.defaultEvery
    @AppStorage("mem_a3_chars") private var a3Chars = 300
    @AppStorage(FragmentPool.customPromptKey) private var customFragmentPrompt = ""
    @AppStorage("memoryExtractModelId") private var memoryExtractModelId = ""
    @AppStorage(FragmentModelRoute.key) private var c2Choice = ""
    @AppStorage("mem_write_c3") private var writeC3 = true
    @AppStorage(CatalogModelRoute.key) private var c3Choice = ""
    @AppStorage(TimelineModelRoute.key) private var a4Choice = ""
    @AppStorage(CatalogSettings.dailyKey) private var c3Daily = true
    @AppStorage(CatalogSettings.maxTopicsKey) private var c3MaxTopics = CatalogSettings.defaultMaxTopics
    @AppStorage(CatalogSettings.maxRoundsKey) private var c3MaxRounds = CatalogSettings.defaultMaxRounds
    @AppStorage(CatalogSettings.sorterKey) private var c3Sorter = CatalogSettings.Sorter.code.rawValue

    @State private var spent: [UsageKind: Double]? = nil
    @State private var periodLabel = ""
    @State private var archiveCount = 0
    @State private var stopWordCount = 0
    @State private var selfCount = 0
    @State private var rejectedThisWeek = 0
    @State private var showLog = false

    private var assistantName: String { floorAssistantName(profileManager) }
    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                if id.hasSwitch {
                    Toggle(isOn: Binding(get: { isOn }, set: { MemoryWriterSettings.set(id, $0) })) {
                        SubRowLabel(title: "\(id.code) \(id.title(assistant: assistantName))", sub: id.subtitle(assistant: assistantName))
                    }
                    .tint(Theme.branchIndicator)
                } else {
                    SubRowLabel(title: "\(id.code) \(id.title(assistant: assistantName))", sub: id.subtitle(assistant: assistantName))
                }
                if id.health != nil {
                    MemoryWriterStatusRow(id: id, profileId: profileId)
                } else if id == .c3 {
                    CatalogStatusRow(profileId: profileId)
                    CatalogHealthRow(profileId: profileId)
                }
            }
            .panelRowBackground()

            if id != .c {
                Section("模型") { modelRows }
                    .panelRowBackground()
            }

            specificSections

            if id.isBackground || id == .b1 {
                Section("花费") {
                    if id == .b1 {
                        SubRowLabel(title: "本期", sub: "\(assistantName)本人调工具，不算写入预算")
                    } else {
                        HStack {
                            SubRowLabel(title: periodLabel.isEmpty ? "本期" : periodLabel)
                            Text(spentText)
                                .font(m.caption.monospaced())
                                .foregroundColor(Theme.textMuted)
                        }
                        if id == .c3 {
                            HStack {
                                SubRowLabel(title: UsageKind.catalogSeed.label, sub: "\(periodLabel.isEmpty ? "本期" : periodLabel)，另算，不占写入预算")
                                Text(seedSpentText)
                                    .font(m.caption.monospaced())
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                    }
                }
                .panelRowBackground()
            }
        }
        .memorySubpage("\(id.code) \(id.title(assistant: assistantName))")
        .sheet(isPresented: $showLog) {
            MemoryWriteLogSheet(profileId: profileId, focus: id)
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in Task { await reload() } }
    }

    private var isOn: Bool {
        _ = (writeA2, writeA3, writeA4, writeB1, writeB4, writeC2, writeC3)
        return MemoryWriterSettings.isOn(id)
    }

    private var spentText: String {
        guard let kind = MemoryWriterSpend.kind(id) else { return "" }
        guard let spent else { return "…" }
        let v = spent[kind] ?? 0
        return v == 0 && localChoice != nil ? "$0.00 · 本机不花钱" : String(format: "$%.2f", v)
    }

    private var seedSpentText: String {
        guard let spent else { return "…" }
        let v = spent[.catalogSeed] ?? 0
        return v == 0 && localChoice != nil ? "$0.00 · 本机不花钱" : String(format: "$%.2f", v)
    }

    /// A4 / C2 / C3 选了本机哪一款（A4 没选过 = 本机轻巧款）
    private var localChoice: String? {
        switch id {
        case .a4: return FragmentModelRoute.localModelId(choice: TimelineModelRoute.choice(a4Choice))
        case .c2: return FragmentModelRoute.localModelId(choice: c2Choice)
        case .c3: return FragmentModelRoute.localModelId(choice: c3Choice)
        default: return nil
        }
    }

    // MARK: 模型

    @ViewBuilder
    private var modelRows: some View {
        switch id {
        case .a2, .a3:
            WriterModelPicker(key: MemoryWriterModels.key(id), fallbackLabel: "跟「提取模型」", extractLabel: extractModelLabel,
                              allowLocal: false)
        case .a4:
            WriterModelPicker(key: TimelineModelRoute.key, fallbackLabel: "本机轻巧款 1.7B（默认）", extractLabel: extractModelLabel,
                              allowLocal: true, defaultLocal: true)
            Text("只写一句主调和几个话题词；本机没装、跑不了或 app 在后台，这一次用提取模型")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
            if let local = localChoice {
                if !LocalLLMService.isSupported {
                    SubRowLabel(title: "本机模型", sub: "这台设备跑不了本机模型，先用提取模型")
                } else if let model = AssistantLocalModel.catalog.first(where: { $0.id == local }) {
                    LocalModelDownloadRow(model: model, title: "下载本机模型")
                }
            }
        case .c2, .c3:
            WriterModelPicker(key: id == .c2 ? FragmentModelRoute.key : CatalogModelRoute.key, fallbackLabel: "跟「提取模型」",
                              extractLabel: extractModelLabel, allowLocal: true)
            if id == .c3, localChoice != nil {
                Text("本机模型放不下写作规则，日常整理会报错")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            // 选了哪个本机款就给哪个的下载行；没选本机就不出
            if let local = localChoice {
                if !LocalLLMService.isSupported {
                    SubRowLabel(title: "本机模型", sub: "这台设备跑不了本机模型，先用提取模型")
                } else if let model = AssistantLocalModel.catalog.first(where: { $0.id == local }) {
                    LocalModelDownloadRow(model: model, title: "下载本机模型")
                }
            }
        default:
            SubRowLabel(title: "用哪个模型", sub: "跟对话用同一个（这一项不能单换）")
        }
    }

    // MARK: 各自的行

    @ViewBuilder
    private var specificSections: some View {
        switch id {
        case .a4:
            Section {
                SubRowLabel(title: "每天过了 05:00", sub: "第一次巡检把前一天各窗口拼成一条；读已经写好的上下文摘要，不另外去压")
                SubRowLabel(title: "没压缩的那截", sub: "先列「N 条，没压缩」，等上下文摘要压完、下次拼那天时补上")
            } header: {
                Text("什么时候写")
            } footer: {
                Text("对话 ⋯ 里的「现在写」顺手拼今天；时间轴里长按一天能重写那天的主调")
                    .font(m.caption)
            }
            .panelRowBackground()
        case .a2, .a3:
            Section {
                TriggerRows(id: id)
                if id == .a2 {
                    SubRowLabel(title: "CC 窗口", sub: "满 60 条或跨过 05:00 就写（只手动时不写）")
                    SubRowLabel(title: "尾段", sub: "每次收尾整段重写，被正式压缩后换成正式段")
                }
                if id == .a3 {
                    LimitStepper(title: "约多少字", value: "\(a3Chars) 字", number: $a3Chars, range: 100...1000, step: 50)
                }
            } header: {
                Text("什么时候写")
            } footer: {
                Text("对话 ⋯ 里的「现在写」立刻写这个窗口")
                    .font(m.caption)
            }
            .panelRowBackground()
        case .b1:
            Section("显示") {
                Toggle(isOn: $heartvoiceShowInChat) {
                    SubRowLabel(title: "心声进聊天流", sub: "开 = 实时显示；关 = 只落盘，翻日历看")
                }
                .tint(Theme.branchIndicator)
            }
            .panelRowBackground()
        case .b4:
            Section("记了什么") {
                SettingsNavRow(.memorySelfList) {
                    SelfMemoryListPage()
                } label: {
                    SubRowLabel(title: "\(selfCount) 条", sub: "看、改\(assistantName)记下的")
                }
                LimitStepper(title: "自己主动记的每日上限", value: "\(selfDailyLimit) 条（你让记的、你改的都不算）",
                             number: $selfDailyLimit, range: 1...50)
                LimitStepper(title: "每条正文上限", value: "\(selfBodyLimit) 字", number: $selfBodyLimit, range: 200...3000, step: 100)
                SubRowLabel(title: "图数据库 · 联想召回", sub: "还没做")
                    .opacity(0.5)
            }
            .panelRowBackground()
        case .c:
            Section {
                SettingsNavRow(.memoryArchiveList) {
                    MemoryArchiveListPage()
                } label: {
                    SubRowLabel(title: "\(archiveCount) 条", sub: "看、搜从聊天里记住的")
                }
            }
            .panelRowBackground()
        case .c2:
            Section("怎么记") {
                LimitStepper(title: "每满几条写一次", value: "\(c2Every) 条（两边加起来）", number: $c2Every,
                             range: FragmentWatch.everyRange, step: 2)
                SettingsNavRow(.memoryExtractPrompt) {
                    PromptEditorPage.memoryExtract
                } label: {
                    SubRowLabel(title: "提取提示词", sub: customFragmentPrompt.isEmpty ? "新版默认 · 每条最多 200 字" : "自定义保留 · 用默认模板并保存才换新版")
                }
                Button { showLog = true } label: {
                    HStack {
                        SubRowLabel(title: "本周拒收", sub: "\(rejectedThisWeek) 次（格式不对没收）")
                        Image(systemName: "chevron.right")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .panelRowBackground()
        case .c3:
            Section("怎么整理") {
                Toggle(isOn: $c3Daily) {
                    SubRowLabel(title: "每天自动整理", sub: "每天过了 05:00 第一次打开时整理一次")
                }
                .tint(Theme.branchIndicator)
                Picker(selection: $c3Sorter) {
                    Text("代码").tag(CatalogSettings.Sorter.code.rawValue)
                    Text("模型").tag(CatalogSettings.Sorter.model.rawValue)
                } label: {
                    SubRowLabel(title: "分拣", sub: c3Sorter == CatalogSettings.Sorter.model.rawValue
                        ? "用上面选的模型判碎片归哪页、开不开新页，算写入预算"
                        : "碎片里出现某页的标题 / 触发词就归那页，没对上的同一个主体攒够 3 条提开新页，不调模型")
                }
                LimitStepper(title: "自动一次最多几个主题", value: "\(c3MaxTopics) 个（剩下的下次）", number: $c3MaxTopics,
                             range: CatalogSettings.maxTopicsRange)
                LimitStepper(title: "手动整理最多几轮", value: "每个主题 \(c3MaxRounds) 轮", number: $c3MaxRounds,
                             range: CatalogSettings.maxRoundsRange)
                SettingsNavRow(.memoryCatalogStopWords) {
                    CatalogStopWordsPage()
                } label: {
                    SubRowLabel(title: "不触发的词", sub: "\(stopWordCount) 个")
                }
                CatalogPersonaChangeRow()
            }
            .panelRowBackground()
            CatalogSeedSection()
        default:
            EmptyView()
        }
    }

    private var extractModelLabel: String {
        guard !memoryExtractModelId.isEmpty,
              let model = (providerManager?.enabledProviders ?? []).flatMap(\.models).first(where: { $0.id == memoryExtractModelId })
        else { return "自动" }
        return model.name
    }

    private func reload() async {
        let pid = profileId
        let (since, label) = MemoryWriterSpend.since()
        periodLabel = label
        if id.isBackground { spent = await MemoryWriterSpend.load(since: since) }
        switch id {
        case .c:
            archiveCount = SwiftDataMemoryStore().listActive(profileId: pid, context: modelContext).count
        case .b4:
            selfCount = await Task.detached { SelfMemoryStore.list(profileId: pid).filter(\.isActive).count }.value
        case .c2:
            rejectedThisWeek = await Task.detached { MemoryWriteLog.rejectedThisWeek(MemoryWriteLog.entries(profileId: pid)) }.value
        case .c3:
            stopWordCount = await Task.detached { WikiStore(profileId: pid).stopWords().count }.value
        default:
            break
        }
    }
}

/// 一项写手的模型单选（空 = 跟提取模型；C2 另能选本机两款）
private struct WriterModelPicker: View {
    let key: String
    let fallbackLabel: String
    let extractLabel: String
    let allowLocal: Bool
    /// 没选过 = 本机轻巧款（A4）：「跟提取模型」单列一项
    var defaultLocal = false
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage private var choice: String

    init(key: String, fallbackLabel: String, extractLabel: String, allowLocal: Bool, defaultLocal: Bool = false) {
        self.key = key
        self.fallbackLabel = fallbackLabel
        self.extractLabel = extractLabel
        self.allowLocal = allowLocal
        self.defaultLocal = defaultLocal
        _choice = AppStorage(wrappedValue: "", key)
    }

    private var cards: [APICredential] { FragmentModelRoute.remoteCredentials(providerManager?.enabledProviders ?? []) }

    private var label: String {
        if choice.isEmpty { return defaultLocal ? fallbackLabel : "\(fallbackLabel) · \(extractLabel)" }
        if choice == FragmentModelRoute.extractChoice { return "跟「提取模型」 · \(extractLabel)" }
        if choice.hasPrefix(FragmentModelRoute.localPrefix) { return FragmentModelRoute.localName(String(choice.dropFirst(FragmentModelRoute.localPrefix.count))) }
        return cards.flatMap(\.models).first { $0.id == choice }?.name ?? "已停用的模型（现在按默认）"
    }

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { defaultLocal ? choice : FragmentModelRoute.pickerChoice(choice) }, set: { choice = $0 })) {
                Text(fallbackLabel).tag("")
                if defaultLocal {
                    Text("本机聪明款 4B").tag(FragmentModelRoute.localPrefix + AssistantLocalModel.smart.id)
                    Text("跟「提取模型」").tag(FragmentModelRoute.extractChoice)
                } else if allowLocal {
                    Text("本机聪明款 4B").tag(FragmentModelRoute.localPrefix + AssistantLocalModel.smart.id)
                    Text("本机轻巧款 1.7B").tag(FragmentModelRoute.localPrefix + AssistantLocalModel.light.id)
                }
                ForEach(cards, id: \.id) { c in
                    Section(c.name) {
                        ForEach(c.models) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
            } label: {
                Text("用哪个模型")
            }
            .pickerStyle(.inline)
        } label: {
            HStack {
                SubRowLabel(title: "用哪个模型", sub: label)
                Image(systemName: "chevron.up.chevron.down")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 触发三选一：停 N 分钟 / 每 N 回合 / 只手动（A2 / A3 / A4 各一套）
private struct TriggerRows: View {
    let id: MemoryWriterID
    @Environment(\.settingsMetrics) private var m
    @AppStorage private var modeRaw: String
    @AppStorage private var idle: Int
    @AppStorage private var rounds: Int
    @AppStorage private var onNew: Bool

    init(id: MemoryWriterID) {
        self.id = id
        _modeRaw = AppStorage(wrappedValue: MemoryTriggers.mode(id).rawValue, MemoryTriggers.modeKey(id))
        _idle = AppStorage(wrappedValue: MemoryTriggers.defaultIdleMinutes(id), MemoryTriggers.idleKey(id))
        _rounds = AppStorage(wrappedValue: MemoryTriggers.defaultRounds(id), MemoryTriggers.roundsKey(id))
        _onNew = AppStorage(wrappedValue: true, MemoryTriggers.onNewKey(id))
    }

    private var mode: MemoryTriggerMode { MemoryTriggerMode(rawValue: modeRaw) ?? MemoryTriggers.mode(id) }

    var body: some View {
        Picker("什么时候写", selection: $modeRaw) {
            ForEach(MemoryTriggerMode.allCases, id: \.rawValue) { m in
                Text(m.label).tag(m.rawValue)
            }
        }
        .pickerStyle(.segmented)
        switch mode {
        case .idle:
            Stepper(value: $idle, in: 30...1440, step: 30) {
                SubRowLabel(title: "窗口停下来多久就写", sub: MemoryTriggers.idleText(idle))
            }
        case .rounds:
            Stepper(value: $rounds, in: 1...50) {
                SubRowLabel(title: "每几回合写一次", sub: "每 \(rounds) 回合")
            }
        case .manual:
            SubRowLabel(title: "只手动", sub: "只在对话 ⋯「现在写」时写")
        }
        if id != .a2, mode != .manual {
            Toggle(isOn: $onNew) {
                SubRowLabel(title: "新开对话时，先写掉刚聊的", sub: "12 小时内聊过的不等静默")
            }
            .tint(Theme.branchIndicator)
        }
    }
}

// MARK: - 开窗口带什么（plan §三）

struct MemoryOpenWindowPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage(MemoryOpenWindow.a2Key) private var openA2 = true
    @AppStorage(MemoryOpenWindow.a4Key) private var openA4 = true
    @AppStorage(MemoryOpenWindow.b4Key) private var openB4 = true
    @AppStorage(MemoryOpenWindow.cKey) private var openC = false
    @AppStorage("mem_session_full_segments") private var sessionFullSegments = 2
    @AppStorage("mem_timeline_inject_days") private var timelineInjectDays = 7
    @AppStorage("mem_self_recent_count") private var selfRecentCount = 5
    @AppStorage("mem_self_budget_percent") private var selfBudgetPercent = 100

    private var assistantName: String { floorAssistantName(profileManager) }

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                check("A2 上下文摘要", $openA2)
                if openA2 {
                    LimitStepper(title: "带全文的最近几段", value: "\(sessionFullSegments) 段（更早的只带标题）",
                                 number: $sessionFullSegments, range: 1...4)
                }
                check("A4 时间轴", $openA4)
                if openA4 {
                    LimitStepper(title: "最多往回看几天", value: "\(timelineInjectDays) 天（今天、昨天带各时段，更早的只带主调）",
                                 number: $timelineInjectDays, range: 2...30)
                    SubRowLabel(title: "↳ 待续", sub: "只带「没做完」的，单独一段跟在时间轴后面")
                }
                check("B4 \(assistantName)的记忆", $openB4)
                if openB4 {
                    LimitStepper(title: "带全文的最近几条", value: "\(selfRecentCount) 条（重要度 5 的另算，全部带）",
                                 number: $selfRecentCount, range: 1...30)
                    LimitStepper(title: "最多占注入预算", value: "\(selfBudgetPercent)%（剩下的给档案）",
                                 number: $selfBudgetPercent, range: 10...100, step: 10)
                }
                check("C 档案", $openC)
                if openC {
                    SubRowLabel(title: "带哪些", sub: "按下面「检索」挑")
                } else {
                    Text("档案先不带，等 C3 整理好再开；聊天中靠「检索」按需想起")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                SubRowLabel(title: "目录", sub: "还没做")
                    .opacity(0.5)
            } footer: {
                Text("勾上的这些每一轮都带进去（所有窗口）。聊天中按需想起来的，在「检索」里设。")
                    .font(m.caption)
            }
            .panelRowBackground()
        }
        .memorySubpage("开窗口带什么")
    }

    private func check(_ title: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack {
                SubRowLabel(title: title)
                Image(systemName: on.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(m.body)
                    .foregroundColor(on.wrappedValue ? Theme.branchIndicator : Theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
    }
}

// MARK: - 写入预算（plan §四：控件和全局预算一样，另加周期）

struct WriteBudgetPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var store = WriteBudgetStore.shared
    @State private var spent: [UsageKind: Double]? = nil
    @AppStorage(FragmentModelRoute.key) private var c2Choice = ""
    @AppStorage(CatalogModelRoute.key) private var c3Choice = ""
    @AppStorage(TimelineModelRoute.key) private var a4Choice = ""

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                if store.period == .off {
                    VStack(alignment: .leading, spacing: 10) {
                        periodPicker
                        Text("不限：后台写手照常写。选周或日就按你填的数停")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                } else {
                    BudgetSection(account: store,
                                  spentLabel: store.period == .week ? "这周已用" : "今天已用",
                                  footnote: "只算后台写手 A2 A3 A4 C2 C3；B1 / B4 是\(floorAssistantName(profileManager))本人调工具，不算；本机模型不花钱。超了后台先停，对话 ⋯「现在写」照样能写。",
                                  warnAt80: false) {
                        periodPicker
                    }
                }
            }
            .panelRowBackground()

            if store.period != .off {
                Section("花在哪") {
                    ForEach([MemoryWriterID.a2, .a3, .a4, .c2, .c3], id: \.self) { id in
                        HStack {
                            SubRowLabel(title: "\(id.code) \(id.title(assistant: floorAssistantName(profileManager)))")
                            Text(spentText(id))
                                .font(m.caption.monospaced())
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                }
                .panelRowBackground()
            }
        }
        .memorySubpage("写入预算")
        .task(id: store.period) { await reload() }
    }

    private var periodPicker: some View {
        Picker("周期", selection: Binding(get: { store.period }, set: { store.setPeriod($0) })) {
            ForEach(WriteBudgetPeriod.allCases) { p in
                Text(p.label).tag(p)
            }
        }
        .pickerStyle(.segmented)
    }

    private func spentText(_ id: MemoryWriterID) -> String {
        guard let kind = MemoryWriterSpend.kind(id), let spent else { return "…" }
        let v = spent[kind] ?? 0
        let choice = id == .c2 ? c2Choice : id == .c3 ? c3Choice : id == .a4 ? TimelineModelRoute.choice(a4Choice) : ""
        return v == 0 && FragmentModelRoute.localModelId(choice: choice) != nil ? "$0.00 · 本机" : String(format: "$%.2f", v)
    }

    private func reload() async {
        await store.refreshSpent()
        guard let since = WriteBudgetStore.since(period: store.period, resetAt: store.resetAt, now: Date()) else { return }
        spent = await MemoryWriterSpend.load(since: since)
    }
}

// MARK: - 待续（plan §八：三态、左滑改状态、能改字）

struct PendingListPage: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var items: [PendingItem] = []
    @State private var titles: [String: String] = [:]
    @State private var filter: PendingState = .open
    @State private var editing: PendingItem?
    @State private var editText = ""
    @State private var loaded = false
    /// 待续本子迁不好 / 读不全：照实说，这一页不许改
    @State private var problem: String?

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        SettingsSectionList(.list) {
            if let problem {
                Section {
                    Text(problem)
                        .font(m.caption)
                        .foregroundColor(Theme.textSecondary)
                }
                .panelRowBackground()
            }
            Section {
                Picker("状态", selection: $filter) {
                    ForEach(PendingState.allCases) { s in
                        Text("\(s.label) \(items.filter { $0.state == s }.count)").tag(s)
                    }
                }
                .pickerStyle(.segmented)
                let shown = items.filter { $0.state == filter }
                if loaded && shown.isEmpty {
                    SubRowLabel(title: "没有", sub: nil)
                        .opacity(0.5)
                }
                ForEach(shown.reversed()) { item in
                    Button {
                        editText = item.text
                        editing = item
                    } label: {
                        SubRowLabel(title: item.text, sub: "《\(titles[item.conversationId] ?? String(item.conversationId.prefix(8)))》\(item.day)")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(problem != nil)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        ForEach(PendingState.allCases.filter { $0 != item.state }) { s in
                            Button(s.label) { set(item, s) }
                                .tint(s == .done ? Theme.branchIndicator : Theme.textMuted)
                                .disabled(problem != nil)
                        }
                    }
                    .contextMenu {
                        ForEach(PendingState.allCases.filter { $0 != item.state }) { s in
                            Button("改成「\(s.label)」") { set(item, s) }
                                .disabled(problem != nil)
                        }
                    }
                }
            } footer: {
                Text("左滑一条改成「做完了」或「淡了」，点一条改字。\(floorAssistantName(profileManager))也能自己标。时间轴只带「没做完」的。")
                    .font(m.caption)
            }
            .panelRowBackground()
        }
        .memorySubpage("待续")
        .alert("改待续", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("待续", text: $editText)
            Button("保存") { saveText() }
            Button("取消", role: .cancel) { editing = nil }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in Task { await reload() } }
    }

    private func reload() async {
        let pid = profileId
        let (list, why) = await Task.detached { () -> ([PendingItem], String?) in
            var why: String?
            do { try TimelineDaily.preparePendingForEdit(profileId: pid) } catch { why = TimelineDaily.pendingProblem(error) }
            return (PendingStore.load(profileId: pid) ?? [], why)
        }.value
        guard pid == profileId else { return }
        problem = why
        items = list
        let ids = Set(list.map(\.conversationId))
        var t: [String: String] = [:]
        for cid in ids {
            let fetch = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.id == cid })
            if let c = try? modelContext.fetch(fetch).first { t[cid] = c.title }
        }
        titles = t
        loaded = true
    }

    private func set(_ item: PendingItem, _ state: PendingState) {
        let pid = profileId
        Task {
            let why = await Task.detached { () -> String? in
                do { try PendingStore.setState(item.id, state, profileId: pid); return nil } catch { return TimelineDaily.pendingProblem(error) }
            }.value
            if let why { problem = why }
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        }
    }

    private func saveText() {
        guard let item = editing else { return }
        editing = nil
        let pid = profileId, text = editText
        Task {
            let why = await Task.detached { () -> String? in
                do { try PendingStore.setText(item.id, text, profileId: pid); return nil } catch { return TimelineDaily.pendingProblem(error) }
            }.value
            if let why { problem = why }
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        }
    }
}

// MARK: - C 档案：看 / 搜

struct MemoryArchiveListPage: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var memories: [Memory] = []
    @State private var query = ""

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                TextField("搜索", text: $query)
                    .font(m.body)
                let q = query.trimmingCharacters(in: .whitespaces)
                ForEach(memories.filter { q.isEmpty || $0.content.localizedCaseInsensitiveContains(q) }, id: \.id) { mem in
                    SubRowLabel(title: mem.content, sub: MemoryDateText.short(mem.createdAt))
                }
            }
            .panelRowBackground()
        }
        .memorySubpage("从聊天里记住的")
        .onAppear {
            memories = SwiftDataMemoryStore().listActive(profileId: profileManager?.currentProfile.id ?? "", context: modelContext)
                .sorted { $0.createdAt > $1.createdAt }
        }
    }
}

// MARK: - B4 {助手}的记忆：看 / 改

struct SelfMemoryListPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var list: [SelfMemory] = []
    @State private var editing: SelfMemory?

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                ForEach(list) { item in
                    Button { editing = item } label: {
                        SubRowLabel(title: item.name, sub: item.description)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .panelRowBackground()
        }
        .memorySubpage("\(floorAssistantName(profileManager))的记忆")
        .sheet(item: $editing) { item in
            SelfMemoryEditSheet(profileId: profileId, slug: item.slug) { Task { await reload() } }
        }
        .task { await reload() }
    }

    private func reload() async {
        let pid = profileId
        list = await Task.detached { SelfMemoryStore.list(profileId: pid).filter(\.isActive) }.value
    }
}

// MARK: - 对话 ⋯「现在写」（plan §九）

/// 自己拿 manager（对话页本身不订阅这些 manager，见 ContentView 顶上的说明）
struct WriteMemoryNowButton: View {
    let viewModel: ConversationViewModel
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @AppStorage("mem_master") private var memMaster = true

    var body: some View {
        Button {
            guard let pm = providerManager, let profile = profileManager?.currentProfile else { return }
            let preset = presetManager?.preset(byId: profile.presetId) ?? Preset.balanced
            let model = pm.resolveModel(conversationModelId: viewModel.selectedConversation?.selectedModelId,
                                        globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
            viewModel.writeMemoryNow(contextDepth: preset.sampling.contextDepth, profile: profile, model: model, providerManager: pm)
        } label: { Label("现在写", systemImage: "square.and.pencil") }
        .disabled(!memMaster)
    }
}

// MARK: - 记忆日志（plan §十一）

enum MemoryWriteLogRunReader {
    struct Document: Identifiable, Sendable {
        let url: URL
        let link: CatalogRunLink
        let content: String
        var id: String { url.path + "#" + (link.anchor ?? "") }
    }

    enum Result: Sendable {
        case unlinked
        case loaded(Document)
        case expired
        case unavailable

        var message: String? {
            switch self {
            case .expired: return CatalogRunRecord.expiredMessage
            case .unavailable: return "暂时打不开这次整理记录，请稍后再试"
            case .unlinked, .loaded: return nil
            }
        }
    }

    static func link(for entry: MemoryWriteLog.Entry) -> CatalogRunLink? {
        entry.writer.uppercased() == "C3" ? entry.run : nil
    }

    static func load(
        _ entry: MemoryWriteLog.Entry,
        wiki: WikiStore,
        readContent: @escaping @Sendable (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
    ) async -> Result {
        guard let link = link(for: entry) else { return .unlinked }
        return await load(link: link, wiki: wiki, readContent: readContent)
    }

    /// 提案上带的同一次记录（种子目录 / 正文）
    static func load(
        link: CatalogRunLink,
        wiki: WikiStore,
        readContent: @escaping @Sendable (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
    ) async -> Result {
        await Task.detached(priority: .userInitiated) {
            guard let url = CatalogRunRecord.resolve(link, wiki: wiki) else {
                return failure(for: link, wiki: wiki)
            }
            do {
                let content = try readContent(url)
                return Result.loaded(Document(url: url, link: link, content: content))
            } catch {
                return failure(for: link, wiki: wiki)
            }
        }.value
    }

    private static func failure(for link: CatalogRunLink, wiki: WikiStore) -> Result {
        let parts = link.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == Substring(CatalogRunRecord.folderName), !parts[1].isEmpty,
              parts[1] != ".", parts[1] != "..", parts[1].hasSuffix(".md") else { return .unavailable }
        let candidate = wiki.root.appendingPathComponent(link.path)
        let resolvedRoot = wiki.root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard candidate.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot) else {
            return .unavailable
        }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: candidate.path)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
                return .expired
            }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return .expired }
        }
        return .unavailable
    }
}

struct MemoryWriteLogSheet: View {
    let profileId: String
    /// 点状态卡某一行进来：跳到这一项最近那条
    var focus: MemoryWriterID? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m
    @State private var entries: [MemoryWriteLog.Entry] = []
    @State private var filter: MemoryWriterID? = nil
    @State private var highlighted: UUID?
    @State private var loaded = false
    @State private var runDocument: MemoryWriteLogRunReader.Document?
    @State private var runError: String?
    @State private var openingRun = false

    private static let filters: [MemoryWriterID?] = [nil, .a2, .a3, .a4, .c2, .c3]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        Picker("筛", selection: $filter) {
                            ForEach(Self.filters, id: \.self) { f in
                                Text(f?.code ?? "全部").tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .panelRowBackground()
                    let shown = entries.filter { filter == nil || $0.writer == filter?.code }
                    if loaded && shown.isEmpty {
                        Section { Text("还没有记录").font(m.body).foregroundColor(Theme.textMuted) }
                            .panelRowBackground()
                    }
                    ForEach(Self.days(shown), id: \.0) { day, rows in
                        Section(day) {
                            ForEach(rows) { e in
                                row(e)
                                    .id(e.id)
                                    .listRowBackground(e.id == highlighted ? Theme.accent : Theme.mainBg)
                            }
                        }
                    }
                }
                .panelListStyle()
                .scrollContentBackground(.hidden)
                .toolPageBackground()
                .onChange(of: loaded) { _, ok in
                    guard ok, let id = highlighted else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .panelSheetTitle("记忆日志")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
            #if os(macOS)
            .frame(minWidth: 440, idealWidth: 520, minHeight: 480, idealHeight: 620)
            #endif
        }
        .task { await load() }
        .sheet(item: $runDocument) { document in
            FileEditorSheet(
                path: "wiki/" + document.link.path,
                initialContent: document.content,
                initialModifiedAt: nil,
                readOnly: true,
                initialAnchor: document.link.anchor,
                currentModifiedAt: { nil },
                reloadExternalContent: { ReloadedFileContent(content: document.content, modifiedAt: nil) },
                onCancel: { runDocument = nil },
                title: "整理记录"
            )
        }
        .alert("整理记录", isPresented: Binding(get: { runError != nil }, set: { if !$0 { runError = nil } })) {
            Button("好", role: .cancel) { runError = nil }
        } message: {
            Text(runError ?? "")
        }
    }

    @ViewBuilder
    private func row(_ entry: MemoryWriteLog.Entry) -> some View {
        if MemoryWriteLogRunReader.link(for: entry) != nil {
            Button {
                Task { await openRun(entry) }
            } label: {
                HStack {
                    rowContent(entry)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(openingRun)
            .accessibilityHint("打开这次整理记录并定位")
        } else {
            rowContent(entry)
        }
    }

    private func rowContent(_ e: MemoryWriteLog.Entry) -> some View {
        let name = MemoryWriterID(rawValue: e.writer.lowercased()).map { $0.title(assistant: "") } ?? ""
        var tail = [e.note, e.model].filter { !$0.isEmpty }
        if let c = e.costUSD { tail.append(String(format: "$%.3f", c)) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if !e.ok { Circle().fill(Theme.danger).frame(width: 6, height: 6) }
                Text("\(Self.time(e.time))　\(e.writer) \(name) · \(e.ok ? "写好了" : "没写成")")
                    .font(m.body)
                    .foregroundColor(e.ok ? Theme.textPrimary : Theme.danger)
            }
            Text(tail.joined(separator: " · "))
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .lineLimit(3)
        }
    }

    private func openRun(_ entry: MemoryWriteLog.Entry) async {
        guard !openingRun else { return }
        openingRun = true
        defer { openingRun = false }
        let pid = profileId
        let wiki = await Task.detached(priority: .userInitiated) { WikiStore(profileId: pid) }.value
        let result = await MemoryWriteLogRunReader.load(entry, wiki: wiki)
        switch result {
        case .unlinked: break
        case .loaded(let document): runDocument = document
        case .expired, .unavailable: runError = result.message
        }
    }

    private func load() async {
        let pid = profileId
        let list = await Task.detached { MemoryWriteLog.entries(profileId: pid) }.value
        entries = list
        if let focus { highlighted = MemoryWriteLog.latest(focus, in: list)?.id }
        loaded = true
    }

    /// 按天分组（新的在前）：今天 / 昨天 / 10-11
    static func days(_ list: [MemoryWriteLog.Entry], now: Date = Date(), calendar: Calendar = .current) -> [(String, [MemoryWriteLog.Entry])] {
        var order: [String] = []
        var groups: [String: [MemoryWriteLog.Entry]] = [:]
        for e in list.sorted(by: { $0.time > $1.time }) {
            let key: String
            if calendar.isDate(e.time, inSameDayAs: now) { key = "今天" }
            else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(e.time, inSameDayAs: y) { key = "昨天" }
            else {
                let c = calendar.dateComponents([.month, .day], from: e.time)
                key = String(format: "%02d-%02d", c.month ?? 0, c.day ?? 0)
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(e)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
