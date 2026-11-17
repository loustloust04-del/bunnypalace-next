import MemoryCore
import SwiftUI
import SwiftData

// MARK: - 记忆 v5 的二级页（设置 → 记忆；记忆 app「设置」格同一份）
// 编号页同一个模板（plan §二）：开关 → 模型 → 各自的行（状态看设置顶上的状态卡 / 记忆日志，花费看写入预算 / 用量）。
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
struct SubRowLabel: View {
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
struct LimitStepper: View {
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

    /// 后台：写入预算里每类花了多少（写入预算页「花在哪」）
    static func load(since: Date) async -> [UsageKind: Double] {
        await Task.detached(priority: .utility) {
            let records = UsageLedger.shared.load(since: since)
            var out: [UsageKind: Double] = [:]
            for k in WriteBudgetStore.kinds {
                out[k] = GlobalBudgetStore.ledgerSpentUSD(records: records.filter { $0.kind == k }, since: since)
            }
            return out
        }.value
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
        guard let health else { return "每天自动整理后查一次断链、目录漂移，只报告不改页" }
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
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        NavigationStack {
            List {
                section("断链", note: "「连到」指向的页不存在", health.brokenLinks.map { "\($0.from) → \($0.to)" })
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
                Text(WikiStore.shown(row, user: profileManager?.currentProfile.userName ?? "")).font(m.body).foregroundColor(Theme.textPrimary).textSelection(.enabled)
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
            Button { start(.persona) } label: { SubRowLabel(title: "从人设生成基础 wiki", sub: "先播人设再播 CC 记忆：人设里的人物 / 别名会成为后面对齐的锚") }
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
                Text("上次：" + WikiStore.shown(report.summary, user: profileManager?.currentProfile.userName ?? ""))
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
    @AppStorage(FragmentWatch.wholeEveryKey) private var c2WholeEvery = FragmentWatch.defaultWholeEvery
    @AppStorage(FragmentPool.customPromptKey) private var customFragmentPrompt = ""
    @AppStorage(FragmentPool.customWholePromptKey) private var customWholePrompt = ""
    @AppStorage("memoryExtractModelId") private var memoryExtractModelId = ""
    @AppStorage(FragmentModelRoute.key) private var c2Choice = ""
    @AppStorage("mem_write_c3") private var writeC3 = true
    @AppStorage(CatalogModelRoute.key) private var c3Choice = ""
    @AppStorage(TimelineModelRoute.key) private var a4Choice = ""
    @AppStorage(CatalogSettings.dailyKey) private var c3Daily = true
    @AppStorage(CatalogSettings.maxTopicsKey) private var c3MaxTopics = CatalogSettings.defaultMaxTopics
    @AppStorage(CatalogSettings.maxRoundsKey) private var c3MaxRounds = CatalogSettings.defaultMaxRounds
    @AppStorage(CatalogSettings.sorterKey) private var c3Sorter = CatalogSettings.Sorter.code.rawValue

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
                        SubRowLabel(title: "\(id.code) \(id.displayTitle(assistant: assistantName))", sub: id.subtitle(assistant: assistantName))
                    }
                    .tint(Theme.branchIndicator)
                } else {
                    SubRowLabel(title: "\(id.code) \(id.displayTitle(assistant: assistantName))", sub: id.subtitle(assistant: assistantName))
                }
                if id == .c3 {
                    CatalogHealthRow(profileId: profileId)
                }
            }
            .panelRowBackground()

            if id != .c {
                Section("模型") { modelRows }
                    .panelRowBackground()
            }

            specificSections

            if id == .a3 { WindowSummaryRewriteSection() }
        }
        .memorySubpage("\(id.code) \(id.displayTitle(assistant: assistantName))")
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
            WriterModelPicker(key: MemoryWriterModels.key(id), fallbackLabel: "跟默认模型", extractLabel: extractModelLabel,
                              allowLocal: false)
        case .a4:
            WriterModelPicker(key: TimelineModelRoute.key, fallbackLabel: "本机轻巧款 1.7B（默认）", extractLabel: extractModelLabel,
                              allowLocal: true, defaultLocal: true)
            if let local = localChoice {
                if !LocalLLMService.isSupported {
                    SubRowLabel(title: "本机模型", sub: "这台设备跑不了本机模型，先用默认模型")
                } else if let model = AssistantLocalModel.catalog.first(where: { $0.id == local }) {
                    LocalModelDownloadRow(model: model, title: "下载本机模型")
                }
            }
        case .c2, .c3:
            WriterModelPicker(key: id == .c2 ? FragmentModelRoute.key : CatalogModelRoute.key, fallbackLabel: "跟默认模型",
                              extractLabel: extractModelLabel, allowLocal: true)
            if id == .c3, localChoice != nil {
                Text("本机模型放不下写作规则，日常整理会报错")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            // 选了哪个本机款就给哪个的下载行；没选本机就不出
            if let local = localChoice {
                if !LocalLLMService.isSupported {
                    SubRowLabel(title: "本机模型", sub: "这台设备跑不了本机模型，先用默认模型")
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
        case .a2, .a3:
            Section("什么时候写") {
                TriggerRows(id: id)
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
                // 整段写手（云上模型）攒一大截再写；本机模型走老写法，用老的那个数
                if FragmentWatch.usesWhole(local: FragmentModelRoute.localModelId(choice: c2Choice) != nil) {
                    LimitStepper(title: "每满几条写一次", value: "\(c2WholeEvery) 条（两边加起来）", number: $c2WholeEvery,
                                 range: FragmentWatch.wholeEveryRange, step: 20)
                } else {
                    LimitStepper(title: "每满几条写一次", value: "\(c2Every) 条（两边加起来）", number: $c2Every,
                                 range: FragmentWatch.everyRange, step: 2)
                }
                SettingsNavRow(.memoryExtractPrompt) {
                    ExtractPromptPage()
                } label: {
                    SubRowLabel(title: "提取提示词", sub: extractPromptSub)
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

    /// 「提取提示词」那行：写法只看选没选本机模型（本机 = 旧写法）；她改过提示词只换前面那两个字
    private var extractPromptSub: String {
        _ = (customFragmentPrompt, customWholePrompt)
        if FragmentWatch.usesWhole(local: localChoice != nil) {
            return (FragmentPool.activeWholeTemplate() != nil ? "你改过的" : "默认") + " · 整段读完再写，写完再核对"
        }
        return (FragmentPool.activeCustomTemplate() != nil ? "你改过的" : "默认") + " · 旧写法"
    }

    /// 提取模型现在实际解析成谁（和写手运行时同一处；以前没选时只写「自动」，看不出背后是哪个模型）
    private var extractModelLabel: String {
        _ = memoryExtractModelId
        return providerManager.map { MemoryWriterModels.extract(providers: $0).name } ?? "自动"
    }

    private func reload() async {
        let pid = profileId
        switch id {
        case .c:
            archiveCount = SwiftDataMemoryStore().listActive(profileId: pid, context: modelContext).count
        case .b4:
            selfCount = await Task.detached { SelfMemoryStore.list(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), checkPath: AppPaths.checked).filter(\.isActive).count }.value
        case .c2:
            rejectedThisWeek = await Task.detached { MemoryWriteLog.rejectedThisWeek(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))) }.value
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
        if choice == FragmentModelRoute.extractChoice { return "跟默认模型 · \(extractLabel)" }
        if choice.hasPrefix(FragmentModelRoute.localPrefix) { return FragmentModelRoute.localName(String(choice.dropFirst(FragmentModelRoute.localPrefix.count))) }
        // 选过的模型停用了：运行时跟默认模型（`FragmentModelRoute.resolve`），A4 也一样
        return cards.flatMap(\.models).first { $0.id == choice }?.name ?? "跟默认模型 · \(extractLabel)"
    }

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { defaultLocal ? choice : FragmentModelRoute.pickerChoice(choice) }, set: { choice = $0 })) {
                Text(fallbackLabel).tag("")
                if defaultLocal {
                    Text("本机聪明款 4B").tag(FragmentModelRoute.localPrefix + AssistantLocalModel.smart.id)
                    Text("跟默认模型").tag(FragmentModelRoute.extractChoice)
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
    var searchTarget: String? = nil
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var checks: [MemoryWriterID: Bool] = [:]
    @State private var extras: [MemoryNoteItem: Bool] = [:]
    @State private var everyRound = false
    @State private var noteOn = true
    @AppStorage("mem_inject_catalog") private var memInjectCatalog = false
    @AppStorage("mem_session_full_segments") private var sessionFullSegments = 2
    @AppStorage("mem_timeline_inject_days") private var timelineInjectDays = 7
    @AppStorage("mem_self_recent_count") private var selfRecentCount = 5
    @AppStorage("mem_self_budget_percent") private var selfBudgetPercent = 100

    private var assistantName: String { floorAssistantName(profileManager) }
    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        ScrollViewReader { proxy in
        SettingsSectionList(.list) {
            Section {
                check("A2 上下文摘要", checked(.a2))
                if checked(.a2).wrappedValue {
                    LimitStepper(title: "带全文的最近几段", value: "\(sessionFullSegments) 段（更早的只带标题）",
                                 number: $sessionFullSegments, range: 1...4)
                }
                check("A4 时间轴", checked(.a4))
                if checked(.a4).wrappedValue {
                    LimitStepper(title: "最多往回看几天", value: "\(timelineInjectDays) 天（今天、昨天带各时段，更早的只带主调）",
                                 number: $timelineInjectDays, range: 2...30)
                }
                check("待续", extra(.pending), sub: "只带「没做完」的，单独一段跟在时间轴后面；新开的窗口按这个起步")
                check("B4 \(assistantName)的记忆", checked(.b4))
                if checked(.b4).wrappedValue {
                    LimitStepper(title: "带全文的最近几条", value: "\(selfRecentCount) 条（重要度 5 的另算，全部带）",
                                 number: $selfRecentCount, range: 1...30)
                    LimitStepper(title: "最多占注入预算", value: "\(selfBudgetPercent)%（剩下的给原子事实和 wiki）",
                                 number: $selfBudgetPercent, range: 10...100, step: 10)
                }
                check("原子事实每轮全带", everyRoundBinding, sub: "批过的原子事实每一轮都带（预算内）")
                    .searchAnchor("leaf-mem-everyround")
                check("wiki 目录", checked(.c))
                    .searchAnchor("leaf-mem-rootindex")
                if checked(.c).wrappedValue {
                    Toggle(isOn: $memInjectCatalog) {
                        SubRowLabel(title: "命中的只带一行目录")
                    }
                    .tint(Theme.branchIndicator)
                    .searchAnchor("leaf-mem-catalog")
                }
                check("上一个窗口最后几条", extra(.previousWindow),
                      sub: "开新窗口时记下最后聊的那个窗口最后 \(RecallTuningStore.load(profileId: profileId).previousWindowMessages) 条；新开的窗口按这个起步")
                    .searchAnchor("leaf-mem-previouswindow")
                check("钉住的", extra(.pinned), sub: "在记忆里钉住的条目；新开的窗口按这个起步")
                    .searchAnchor("leaf-mem-pinned")
                Toggle(isOn: noteBinding) {
                    SubRowLabel(title: "新开窗口先弹纸条", sub: "新建对话时先选这个窗口带哪几样，每样多少 token")
                }
                .tint(Theme.branchIndicator)
                .searchAnchor("leaf-mem-opennote")
            } footer: {
                Text("勾上的这些每一轮都带进去。只管这一个楼层；新开的窗口按这里的勾起步，开出来以后各管各的。")
                    .font(m.caption)
            }
            .panelRowBackground()
        }
            .onAppear {
                if let target = searchTarget ?? SettingsSearchRouter.shared.flashingAnchor {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .memorySubpage("开窗口带什么")
        .task(id: profileId) { refreshChecks() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            refreshChecks()
        }
    }

    private func refreshChecks() {
        checks = Dictionary(uniqueKeysWithValues: MemoryOpenWindow.rows.map {
            ($0, MemoryOpenWindow.isChecked($0, profileId: profileId))
        })
        let defaults = MemoryWindowChoices.defaults(profileId: profileId)
        extras = Dictionary(uniqueKeysWithValues: MemoryOpenWindow.noteExtras.map { ($0, defaults[$0]) })
        everyRound = MemoryOpenWindow.everyRound(profileId: profileId)
        noteOn = MemoryOpenWindowNote.enabled(profileId: profileId)
    }

    private var everyRoundBinding: Binding<Bool> {
        Binding(get: { everyRound }, set: { value in
            MemoryOpenWindow.setEveryRound(value, profileId: profileId)
            refreshChecks()
        })
    }

    /// 段④ 纸条新增的三勾（楼层默认，新窗口起步用）
    private func extra(_ item: MemoryNoteItem) -> Binding<Bool> {
        Binding(get: { extras[item] ?? MemoryWindowChoices.defaults(profileId: profileId)[item] }, set: { value in
            MemoryWindowChoices.setDefault(item, value, profileId: profileId)
            refreshChecks()
        })
    }

    private var noteBinding: Binding<Bool> {
        Binding(get: { noteOn }, set: { value in
            MemoryOpenWindowNote.set(value, profileId: profileId)
            refreshChecks()
        })
    }

    private func checked(_ id: MemoryWriterID) -> Binding<Bool> {
        Binding(get: { checks[id] ?? MemoryOpenWindow.isChecked(id, profileId: profileId) }, set: { value in
            MemoryOpenWindowStore.save(id, value, profileId: profileId)
            refreshChecks()
        })
    }

    private func check(_ title: String, _ on: Binding<Bool>, sub: String? = nil) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack {
                SubRowLabel(title: title, sub: sub)
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

struct ArchiveTriggerPage: View {
    var searchTarget: String? = nil
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    var body: some View {
        RecallParametersPage(page: .archiveTrigger, searchTarget: searchTarget)
            .memorySubpage("系统推送给\(floorAssistantName(profileManager))")
            .searchAnchor("page-mem-archivetrigger")
    }
}

struct RecallBrowsePage: View {
    var searchTarget: String? = nil
    var body: some View {
        RecallParametersPage(page: .recallBrowse, searchTarget: searchTarget).memorySubpage("翻记忆")
            .searchAnchor("page-mem-recallbrowse")
    }
}

// MARK: - 接口 › 和 CC 同步（原来一级页上那两张卡，原样搬进来）

struct MemoryCCSyncPage: View {
    var body: some View {
        SettingsSectionList(.list) {
            Section {
                CCMemorySyncCard()
            }
            .panelRowBackground()
            .listRowSeparator(.hidden)
        }
        .memorySubpage("和 CC 同步")
    }
}

// MARK: - 审计台设置（粟粟 11-15：整理放这里；「C2 整理」那一节从 C2 页原样挪来）

struct MemoryAuditSettingsPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage(FragmentDream.enabledKey) private var c2Dream = true
    @AppStorage(FragmentDream.reviewKey) private var c2DreamReview = true

    var body: some View {
        SettingsSectionList(.list) {
            // 「C2 整理」（`FragmentDream`；不是 B3「小克做梦」）
            Section {
                Toggle(isOn: $c2Dream) {
                    SubRowLabel(title: "写完自动整理一遍", sub: "每写成一批，给这批新条目下结论：留下、删掉、并进已有的、改对、拿不准")
                }
                .tint(Theme.branchIndicator)
                Toggle(isOn: $c2DreamReview) {
                    SubRowLabel(title: "整理留下的条目要我批", sub: "关 = 留下的直接算批过，只有拿不准的留在 Draft")
                }
                .tint(Theme.branchIndicator)
                // 手动「重新整理」（`FragmentReorganize`）：不看上面「写完自动整理一遍」开没开；「要我批」对它照常生效
                ReorganizeDraftsSettingsRows(profileId: profileManager?.currentProfile.id ?? "")
            } header: {
                Text(FragmentDream.actor).searchAnchor("leaf-mem-c2-organize")
            } footer: {
                Text("删掉、并进已有的、改对直接生效。本机模型不做。")
                    .font(m.caption)
            }
            .panelRowBackground()
        }
        .memorySubpage("审计台设置")
    }
}

// MARK: - 记忆系统说明（正文以后另写，粟粟 11-15）

struct MemoryExplainerPage: View {
    var body: some View {
        SettingsSectionList(.list) {
            Section {
                SubRowLabel(title: "还没写")
            }
            .panelRowBackground()
        }
        .memorySubpage("记忆系统说明")
    }
}

// MARK: - 设置 › 开发调试 › 记忆 · 没做完的（粟粟 11-15：还没做的 / 没弄完的都收这里）

struct MemoryUnfinishedPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage("mem_inject_vector") private var memInjectVector = false
    @AppStorage("mem_inject_graph") private var memInjectGraph = false

    private var assistantName: String { floorAssistantName(profileManager) }

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                ForEach([MemoryWriterID.b2, .b3], id: \.self) { id in
                    SubRowLabel(title: "\(id.code) \(id.title(assistant: assistantName))", sub: id.subtitle(assistant: assistantName))
                        .opacity(0.5)
                }
                SubRowLabel(title: "图数据库 · 联想召回", sub: "还没做")
                    .opacity(0.5)
            }
            .panelRowBackground()
            Section {
                MemorySwitchRow(title: "按意思找记忆", sub: "聊到意思相近的事也能想起来（第一次打开会下载本地模型）", isOn: $memInjectVector, tech: "向量检索")
                    .onChange(of: memInjectVector) { _, on in
                        if on { AppleMemoryEmbedder.shared.requestAssetsIfNeeded() }
                    }
                if memInjectVector {
                    HStack(spacing: 8) {
                        Text("向量模型")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                        if AppleMemoryEmbedder.shared.assetState == .downloading {
                            ProgressView().controlSize(.small)
                        }
                        Text(AppleMemoryEmbedder.shared.assetState.rawValue)
                            .font(m.caption.weight(.medium))
                            .foregroundColor(AppleMemoryEmbedder.shared.assetState == .ready ? Theme.branchIndicator : Theme.textSecondary)
                        Spacer()
                    }
                }
                MemorySwitchRow(title: "关联扩展", sub: "命中一条顺带它的关联记忆", isOn: $memInjectGraph)
            }
            .panelRowBackground()
            .listRowSeparator(.hidden)
            // v4-1 §九：按新规则重写 / 从备份恢复，只在 DEBUG 构建里（Q10）
            #if DEBUG
            MemoryRegenerationSection()
            Section("还没做") {
                Text("文件 / 发图历史、Moment（事件感知）、提取门槛、语境 tag、随机联想、记忆网关")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .panelRowBackground()
            .listRowSeparator(.hidden)
            #endif
        }
        .memorySubpage("记忆 · 没做完的")
    }
}

private struct RecallParametersPage: View {
    let page: RecallTuning.Field.Page
    var searchTarget: String? = nil
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var tuning = RecallTuning.defaults

    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private var assistantName: String { floorAssistantName(profileManager) }
    private let defaults = RecallTuning.defaults

    var body: some View {
        ScrollViewReader { proxy in
            SettingsSectionList(.list) {
                if page == .archiveTrigger {
                    // 一级页挪进来的两行（粟粟 11-15：一级只留总闸）
                    Section {
                        LimitStepper(title: "一轮最多几页", value: "\(tuning.maximumPages) 页",
                                     number: Binding(get: { tuning.maximumPages }, set: { value in
                                         var latest = RecallTuningStore.load(profileId: profileId)
                                         latest.maximumPages = value
                                         RecallTuningStore.save(latest, profileId: profileId)
                                         tuning = RecallTuningStore.load(profileId: profileId)
                                     }), range: 1...20)
                            .searchAnchor("leaf-mem-maximumpages")
                        MemorySwitchRow(title: "冷却", sub: "推送了你没接茬就先停几句",
                                        isOn: Binding(get: { tuning.cooldownEnabled }, set: { value in
                                            var latest = RecallTuningStore.load(profileId: profileId)
                                            latest.cooldownEnabled = value
                                            RecallTuningStore.save(latest, profileId: profileId)
                                            tuning = RecallTuningStore.load(profileId: profileId)
                                        }))
                            .searchAnchor("leaf-mem-cooldown")
                    }
                    .panelRowBackground()
                    fieldGroup([.minimumEffectiveLength])
                    fieldGroup([.minimumSharedTerms, .activeOverlapThreshold])
                    fieldGroup([.cooldownTurns])
                    fieldGroup([.minimumHanTermLength, .minimumLatinTermLength])
                    fieldGroup([.maximumQueryTerms, .minimumFullTextTerms, .fullTextCoverageThreshold])
                    fieldGroup([.maximumFragments])
                } else {
                    fieldGroup([.maximumRecallCalls])
                }
                Section {
                    Button("恢复本楼层默认") {
                        RecallTuningStore.reset(profileId: profileId, fields: page == .archiveTrigger
                            ? RecallTuning.Field.archiveTriggerFields : RecallTuning.Field.recallBrowseFields)
                        tuning = RecallTuningStore.load(profileId: profileId)
                    }
                    .foregroundColor(Theme.branchIndicator)
                    .searchAnchor(page == .archiveTrigger ? "leaf-mem-archivereset" : "leaf-mem-browsereset")
                }
                .panelRowBackground()
            }
            .onAppear {
                if let target = searchTarget ?? SettingsSearchRouter.shared.flashingAnchor {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .task(id: profileId) { tuning = RecallTuningStore.load(profileId: profileId) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            tuning = RecallTuningStore.load(profileId: profileId)
        }
    }

    private func fieldGroup(_ fields: [RecallTuning.Field]) -> some View {
        Section {
            ForEach(fields, id: \.self) { field in
                fieldRow(field).searchAnchor("leaf-mem-tuning-\(field.rawValue)")
            }
        } header: {
            Text(fields[0].group)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(fields[0].explanation.replacingOccurrences(of: "助手", with: assistantName))
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
        }
        .panelRowBackground()
    }

    @ViewBuilder
    private func fieldRow(_ field: RecallTuning.Field) -> some View {
        let value = field.value(in: tuning)
        let bounds = field.range
        let factory = field.value(in: defaults)
        let changed = value == factory ? "" : " · 默认 " + formatted(factory, field: field)
        if let path = field.integerKeyPath {
            LimitStepper(title: field.title, value: "\(Int(value)) \(unit(field))\(changed)",
                         number: Binding(get: { tuning[keyPath: path] }, set: { save(Double($0), field: field) }),
                         range: Int(bounds.lowerBound)...Int(bounds.upperBound), step: Int(field.step))
        } else {
            Stepper(value: Binding(get: { field.value(in: tuning) }, set: { save($0, field: field) }),
                    in: bounds, step: field.step) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.title).font(m.body).foregroundColor(Theme.textPrimary)
                    Text("\(value, specifier: "%.2f")\(changed)")
                        .font(m.caption.monospaced())
                        .foregroundColor(Theme.textMuted)
                }
            }
        }
    }

    private func formatted(_ value: Double, field: RecallTuning.Field) -> String {
        field.isFraction ? String(format: "%.2f", value) : String(Int(value))
    }

    private func unit(_ field: RecallTuning.Field) -> String {
        switch field {
        case .minimumEffectiveLength, .minimumHanTermLength: "字"
        case .cooldownTurns: "句"
        case .maximumFragments: "条"
        case .maximumRecallCalls: "次"
        default: "个"
        }
    }

    private func save(_ value: Double, field: RecallTuning.Field) {
        // 写前重读只更新这一项，让其它设置入口的最新修改不被旧页面覆盖。
        var latest = RecallTuningStore.load(profileId: profileId)
        field.set(value, in: &latest)
        RecallTuningStore.save(latest, profileId: profileId)
        tuning = RecallTuningStore.load(profileId: profileId)
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
                            SubRowLabel(title: "\(id.code) \(id.displayTitle(assistant: floorAssistantName(profileManager)))")
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
                        SubRowLabel(title: item.text, sub: "《\(titles[item.conversationId] ?? (item.conversationId == PendingStore.ccWindow ? "CC" : String(item.conversationId.prefix(8))))》\(item.day)")
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
            return (PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) ?? [], why)
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
                do { try PendingStore.setState(item.id, state, profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)); return nil } catch { return TimelineDaily.pendingProblem(error) }
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
                do { try PendingStore.setText(item.id, text, profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)); return nil } catch { return TimelineDaily.pendingProblem(error) }
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
                    SubRowLabel(title: mem.lineText, sub: MemoryDateText.short(mem.createdAt))
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
        list = await Task.detached { SelfMemoryStore.list(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), checkPath: AppPaths.checked).filter(\.isActive) }.value
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
            Self.run(viewModel: viewModel, profileManager: profileManager, providerManager: providerManager, presetManager: presetManager)
        } label: { Label("现在写", systemImage: "square.and.pencil") }
        .disabled(!memMaster)
    }

    /// 按钮和对话菜单（`ConversationMenu`「记忆 ▸ 现在写记忆」）共用：写的是 viewModel 当前选中的对话
    static func run(viewModel: ConversationViewModel, profileManager: ProfileManager?,
                    providerManager: ProviderManager?, presetManager: PresetManager?) {
        guard let pm = providerManager, let profile = profileManager?.currentProfile else { return }
        let preset = presetManager?.preset(byId: profile.presetId) ?? Preset.balanced
        let model = pm.resolveModel(conversationModelId: viewModel.selectedConversation?.selectedModelId,
                                    profileModelId: profile.preferredModel,
                                    globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        viewModel.writeMemoryNow(contextDepth: preset.sampling.contextDepth, profile: profile, model: model, providerManager: pm)
    }

    /// 总开关（`mem_master`，默认开）：关着时「现在写」灰掉
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "mem_master") as? Bool ?? true }
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
    /// 在这里撤了整理台的一笔（整理台从 ⋯ › 记忆日志 打开时用来刷新自己）
    let onAuditChanged: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m
    @Environment(\.modelContext) private var modelContext
    @State private var entries: [MemoryWriteLog.Entry] = []
    /// 她在整理台做的（`MemoryAuditLog`）：和 AI 写入按时间混排；撤回那一笔本身不单列，原来那行标 Undone
    @State private var audit: [MemoryAuditLog.Entry] = []
    @State private var auditOpen: Set<UUID> = []
    @State private var auditNote: String?
    @State private var filter: LogFilter
    @State private var loaded = false
    @State private var runDocument: MemoryWriteLogRunReader.Document?
    @State private var runError: String?
    @State private var openingRun = false
    /// 点开的那次「C2 整理」的记录
    @State private var dreamRecord: FragmentDreamRecord?
    /// 点开的那次「详细度」重写的记录
    @State private var detailRecord: CardDetailRecord?
    @State private var dreamError: String?
    @AppStorage("assistantName") private var assistantName = "助手"

    /// 详情页 ⋯「这条的记录」：只列动过这一条的那几笔
    let card: UUID?

    /// `focus`：从某一项写手进来，筛选直接选到那一项（打开永远在顶上，不滚到中间）
    init(profileId: String, focus: MemoryWriterID? = nil, card: UUID? = nil, onAuditChanged: (() -> Void)? = nil) {
        self.profileId = profileId
        self.card = card
        self.onAuditChanged = onAuditChanged
        _filter = State(initialValue: Self.filter(focus: focus))
    }

    /// 上面那排：全部 / 她自己的操作 / 某一项写手
    enum LogFilter: Hashable {
        case all, you
        case writer(MemoryWriterID)

        var label: String {
            switch self {
            case .all: return "全部"
            case .you: return "You"
            case .writer(let w): return w.code
            }
        }
    }

    static let filters: [LogFilter] = [.all, .you] + [MemoryWriterID.a2, .a3, .a4, .c2, .c3].map(LogFilter.writer)

    /// 带进来的那一项在那排里就选它，不在就「全部」
    static func filter(focus: MemoryWriterID?) -> LogFilter {
        guard let focus, filters.contains(.writer(focus)) else { return .all }
        return .writer(focus)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("筛", selection: $filter) {
                        ForEach(Self.filters, id: \.self) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .panelRowBackground()
                if let auditNote {
                    Section { Text(auditNote).font(m.caption).foregroundColor(Theme.textSecondary) }
                        .panelRowBackground()
                }
                let shown = Self.rows(entries, audit: audit, filter: filter, card: card)
                if loaded && shown.isEmpty {
                    Section { Text("还没有记录").font(m.body).foregroundColor(Theme.textMuted) }
                        .panelRowBackground()
                }
                let undone = MemoryAuditLog.undone(audit)
                ForEach(Self.days(shown, time: \.time), id: \.0) { day, rows in
                    Section(day) {
                        ForEach(rows) { r in
                            switch r {
                            case .ai(let e):
                                row(e)
                                    .listRowBackground(Theme.mainBg)
                            case .you(let e):
                                auditRow(e, undone: undone.contains(e.id))
                                    .listRowBackground(Theme.mainBg)
                            }
                        }
                    }
                }
            }
            .panelListStyle()
            .scrollContentBackground(.hidden)
            .toolPageBackground()
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
        .sheet(item: $dreamRecord) { record in
            FragmentDreamRecordSheet(record: record)
                .environment(\.settingsMetrics, m)
        }
        .sheet(item: $detailRecord) { record in
            CardDetailRecordSheet(record: record)
                .environment(\.settingsMetrics, m)
        }
        .alert(dreamError == CardDetailRecord.expiredMessage ? CardDetailRewrite.name : FragmentDream.actor,
               isPresented: Binding(get: { dreamError != nil }, set: { if !$0 { dreamError = nil } })) {
            Button("好", role: .cancel) { dreamError = nil }
        } message: {
            Text(dreamError ?? "")
        }
    }

    private func openDream(_ id: String) {
        Task {
            if CardDetailRecord.isId(id) {
                let pid = profileId
                let record = await Task.detached(priority: .userInitiated) {
                    CardDetailRecord.load(id: id, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
                }.value
                if let record { detailRecord = record } else { dreamError = CardDetailRecord.expiredMessage }
            } else if let record = await FragmentDreamRecordReader.load(id: id, profileId: profileId) {
                dreamRecord = record
            } else {
                dreamError = FragmentDreamRecordReader.expiredMessage
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: MemoryWriteLog.Entry) -> some View {
        if let dream = entry.dream {
            Button { openDream(dream) } label: {
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
            .accessibilityHint("看这次发给模型的全文和每条的结论")
        } else if MemoryWriteLogRunReader.link(for: entry) != nil {
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
        let name = MemoryWriterID(rawValue: e.writer.lowercased()).map { $0.displayTitle(assistant: "") } ?? ""
        var tail = [e.note, e.model].filter { !$0.isEmpty }
        if let c = e.costUSD { tail.append(String(format: "$%.3f", c)) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if !e.ok { Circle().fill(Theme.danger).frame(width: 6, height: 6) }
                Text(e.dream != nil ? "\(Self.time(e.time))　\(e.dream.map(CardDetailRecord.isId) == true ? CardDetailRewrite.name : FragmentDream.actor)\(e.ok ? "" : " · 没跑成")"
                                    : "\(Self.time(e.time))　\(e.writer) \(name) · \(e.ok ? "写好了" : "没写成")")
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
        let root = FileLibraryStore.memoryRoot(profileId: pid)
        let (list, mine) = await Task.detached { () -> ([MemoryWriteLog.Entry], [MemoryAuditLog.Entry]) in
            MemoryAuditLog.prune(memoryRoot: root)
            return (MemoryWriteLog.entries(memoryRoot: root), MemoryAuditLog.load(memoryRoot: root))
        }.value
        entries = list
        audit = mine
        loaded = true
    }

    /// 一行：AI 写入，或她在整理台的一笔
    enum LogRow: Identifiable {
        case ai(MemoryWriteLog.Entry)
        case you(MemoryAuditLog.Entry)

        var id: UUID {
            switch self {
            case .ai(let e): return e.id
            case .you(let e): return e.id
            }
        }

        var time: Date {
            switch self {
            case .ai(let e): return e.time
            case .you(let e): return e.at
            }
        }
    }

    /// 「全部」= AI 写入 + 整理台记录里的每一笔（她的操作、「C2 整理」的结论、助手用 memory_card 动的）混排；You 只看她的操作；
    /// 筛某一项写手时只看那一项（不带她的操作），C2 带上做梦的那几笔
    /// `card` 给了 = 只看动过这一条的那几笔（AI 写入不按条记，不列）
    static func rows(_ entries: [MemoryWriteLog.Entry], audit: [MemoryAuditLog.Entry], filter: LogFilter, card: UUID? = nil) -> [LogRow] {
        if let card {
            let mine = audit.filter { $0.action != .undo && $0.items.contains { $0.card == card } }
            switch filter {
            case .all: return mine.map(LogRow.you)
            case .you: return mine.filter { $0.actor == MemoryAuditLog.you }.map(LogRow.you)
            case .writer(let w): return w == .c2 ? mine.filter { $0.actor == FragmentDream.actor }.map(LogRow.you) : []
            }
        }
        let shown = audit.filter { $0.action != .undo }
        let dream = shown.filter { $0.actor == FragmentDream.actor }.map(LogRow.you)
        switch filter {
        case .all: return entries.map(LogRow.ai) + shown.map(LogRow.you)
        case .you: return shown.filter { $0.actor == MemoryAuditLog.you }.map(LogRow.you)
        case .writer(let w): return entries.filter { $0.writer == w.code }.map(LogRow.ai) + (w == .c2 ? dream : [])
        }
    }

    /// 按天分组（新的在前）：今天 / 昨天 / 10-11
    static func days(_ list: [MemoryWriteLog.Entry], now: Date = Date(), calendar: Calendar = .current) -> [(String, [MemoryWriteLog.Entry])] {
        days(list, time: \.time, now: now, calendar: calendar)
    }

    static func days<T>(_ list: [T], time: (T) -> Date, now: Date = Date(), calendar: Calendar = .current) -> [(String, [T])] {
        var order: [String] = []
        var groups: [String: [T]] = [:]
        for e in list.sorted(by: { time($0) > time($1) }) {
            let t = time(e)
            let key: String
            if calendar.isDate(t, inSameDayAs: now) { key = "今天" }
            else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(t, inSameDayAs: y) { key = "昨天" }
            else {
                let c = calendar.dateComponents([.month, .day], from: t)
                key = String(format: "%02d-%02d", c.month ?? 0, c.day ?? 0)
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(e)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    // MARK: 她在整理台的一笔（原整理台 History，11-12 v2 原型挪来这里）

    /// 「You · Delete 12」+ 时间 · 整理台；点开看改前改后；能撤的行尾 Undo，撤过的标 Undone。
    /// 「C2 整理」的一笔 =「C2 整理 · Merge」+ 模型给的理由，点开多一个「看发给模型的全文」
    private func auditRow(_ entry: MemoryAuditLog.Entry, undone: Bool) -> some View {
        let open = auditOpen.contains(entry.id)
        let dream = entry.actor == FragmentDream.actor
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if open { auditOpen.remove(entry.id) } else { auditOpen.insert(entry.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dream || entry.label != nil ? "\(entry.actor) · \(entry.label ?? entry.action.rawValue)"
                                   : "\(entry.actor) · \(entry.action.rawValue) \(entry.items.count)")
                            .font(m.body.weight(.medium))
                            .foregroundColor(undone ? Theme.textMuted : Theme.textPrimary)
                            .strikethrough(undone, color: Theme.textMuted)
                        Text("\(Self.time(entry.at))" + (dream ? "" : " · \(entry.via ?? "整理台")") + (undone ? " · Undone" : "") + (open ? " · Hide" : " · Show"))
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                        if let note = entry.note {
                            Text(note)
                                .font(m.caption)
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(open ? nil : 2)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if MemoryAuditLog.canUndo(entry, in: audit) {
                    Button { undoAudit(entry) } label: {
                        Text("Undo")
                            .font(m.body.weight(.medium))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(Theme.textPrimary.opacity(0.08), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                }
            }
            if open {
                ForEach(entry.items, id: \.card) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.before.content)
                            .foregroundColor(Theme.textSecondary)
                        if let after = item.after, after.content != item.before.content {
                            Text("→ " + after.content)
                                .foregroundColor(Theme.textPrimary)
                        }
                        ForEach(Self.traitChanges(item.before.traits, item.after?.traits, assistant: assistantName), id: \.self) { line in
                            Text(line)
                                .foregroundColor(Theme.textPrimary)
                        }
                    }
                    .font(m.caption)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.textMuted.opacity(0.4)).frame(width: 2) }
                }
                if let id = entry.dream {
                    Button("看发给模型的全文") { openDream(id) }
                        .font(m.caption)
                        .foregroundColor(Theme.branchIndicator)
                        .buttonStyle(.borderless)
                        .frame(minHeight: 32)
                }
            }
        }
    }

    /// 一张卡写手四项改前改后：变了的各一行（`Tags: #a #b → #a #c`、`Confidence: 60 → 85`），没有的写 —；
    /// 两头有一头没记四项（加这一项之前的老记录 / 彻底删）就不出
    static func traitChanges(_ before: MemoryAuditLog.Traits?, _ after: MemoryAuditLog.Traits?, assistant: String) -> [String] {
        guard let before, let after else { return [] }
        func show(_ t: MemoryAuditLog.Traits) -> [String] {
            let tags = MemoryAudit.cleanedTags(t.keywords).map { "#" + $0 }.joined(separator: " ")
            return [MemoryAudit.cleaned(t.subject) ?? "—",
                    MemoryAuditTraits.origin(t.speaker, assistant: assistant) ?? "—",
                    t.confidence.map(String.init) ?? "—",
                    tags.isEmpty ? "—" : tags]
        }
        let labels = ["About", "Said by", "Confidence", "Tags"]
        let (old, new) = (show(before), show(after))
        return labels.indices.filter { old[$0] != new[$0] }.map { "\(labels[$0]): \(old[$0]) → \(new[$0])" }
    }

    private func undoAudit(_ entry: MemoryAuditLog.Entry) {
        let root = FileLibraryStore.memoryRoot(profileId: profileId)
        let result = MemoryAuditLog.undo(entry, profileId: profileId, context: modelContext)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            auditNote = "撤回失败：\(error.localizedDescription)"
            return
        }
        if let undone = result.entry { try? MemoryAuditLog.append(undone, memoryRoot: root) }
        auditNote = result.restored == 0 ? "一张都没撤：这些卡后来都动过了"
            : (result.skipped == 0 ? nil : "撤回了 \(result.restored) 张，\(result.skipped) 张后来动过没撤")
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        onAuditChanged?()
        audit = MemoryAuditLog.load(memoryRoot: root)
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
