import MemoryCore
import SwiftUI
import SwiftData

// MARK: - 设置 → 记忆 的骨架（v5，粟粟 10-15 拖好的顺序；app 里不做拖动）

/// 节和行的顺序只写这一份：页面按它画，`SettingsSkeletonTests` 按它锁
enum MemoryPageLayout {
    enum Row: String, CaseIterable {
        // 顶上（不带节标题）
        case master, startDay, extractModel, writeBudget, complexity
        // 写入 · 记什么（一个编号一行）
        case writerA2, writerA3, writerA4, writerB1, writerB2, writerB3, writerB4, writerC, writerC2, writerC3
        case ccMemorySync
        // 整理 · 怎么管
        case audit, pending, trash
        // 回想 · 怎么想起来
        case everyRound, openWindow, injectBudget, automatic, archiveTrigger, maximumPages, cooldown, oldFragments, recall
        case injectFull, injectKeyword, injectVector, injectGraph, convHistory
        case browse, seen

        var writer: MemoryWriterID? {
            switch self {
            case .writerA2: return .a2
            case .writerA3: return .a3
            case .writerA4: return .a4
            case .writerB1: return .b1
            case .writerB2: return .b2
            case .writerB3: return .b3
            case .writerB4: return .b4
            case .writerC: return .c
            case .writerC2: return .c2
            case .writerC3: return .c3
            default: return nil
            }
        }
    }

    struct Section: Equatable {
        let title: String
        let rows: [Row]
    }

    static let sections: [Section] = [
        Section(title: "", rows: [.master, .startDay, .extractModel, .writeBudget, .complexity]),
        Section(title: "写入 · 记什么", rows: [.writerA2, .writerA3, .writerA4, .writerB1, .writerB2, .writerB3, .writerB4,
                                          .writerC, .writerC2, .writerC3, .ccMemorySync]),
        Section(title: "整理 · 怎么管", rows: [.audit, .pending, .trash]),
        Section(title: "回想 · 怎么想起来", rows: [.everyRound, .openWindow, .injectBudget,
            .automatic, .archiveTrigger, .maximumPages, .cooldown, .oldFragments,
            .injectFull, .injectKeyword, .injectVector, .injectGraph,
            .browse, .convHistory, .seen, .recall]),
    ]
}

// MARK: - Memory Page Content（共用核：设置-记忆 / 记忆 app「设置」分段）
//
// 单一来源 — 改一处两边生效。节和行的顺序见 `MemoryPageLayout`。

struct MemoryPageContent: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsRoutePush) private var pushRoute
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    /// B15：共用核搬进 mac 设置窗后，raw `Theme.F`（mac 表 11/9）比 J2 小一档 → 全部走 `m.*`（iOS 不变，mac 13/10）
    @Environment(\.settingsMetrics) private var m

    @AppStorage("memoryExtractModelId") private var memoryExtractModelId = ""
    @AppStorage("mem_master") private var memMaster = true
    /// 「记忆从哪天开始」：yyyy-MM-dd，空 = 不限（MemoryStartDay）
    @AppStorage(MemoryStartDay.key) private var memStartDay = ""
    @AppStorage("mem_inject_full") private var memInjectFull = true
    @AppStorage("mem_inject_keyword") private var memInjectKeyword = false
    @AppStorage("mem_inject_vector") private var memInjectVector = false
    @AppStorage("mem_inject_graph") private var memInjectGraph = false
    @AppStorage("mem_content_convhistory") private var memContentConvHistory = true
    @AppStorage("mem_inject_budget") private var memInjectBudget = 10000
    // 写入开关（行上的开关和二级页顶上的同一个键）；只为跟着刷新，读写都过 MemoryWriterSettings（A3 没写过跟老键）
    @AppStorage("mem_content_summary") private var writeA2 = true
    @AppStorage("mem_write_a3") private var writeA3 = true
    @AppStorage("mem_content_timeline") private var writeA4 = true
    @AppStorage("mem_content_heartvoice") private var writeB1 = false
    @AppStorage("mem_write_b4") private var writeB4 = true
    @AppStorage("mem_content_facts") private var writeC2 = true
    @AppStorage("mem_write_c3") private var writeC3 = true
    @AppStorage("mem_model_a2") private var modelA2 = ""
    @AppStorage("mem_model_a3") private var modelA3 = ""
    @AppStorage("mem_model_a4") private var modelA4 = ""
    @AppStorage(FragmentModelRoute.key) private var modelC2 = ""
    @AppStorage(CatalogModelRoute.key) private var modelC3 = ""

    @State private var writeBudget = WriteBudgetStore.shared
    @State private var localModels = AssistantModelStore.shared
    @State private var showTrash = false
    @State private var deletedSelfCount = 0
    @State private var memoryStats = MemoryStats()
    @State private var pending = PendingCounts()
    @State private var recallTuning = RecallTuning.defaults
    @State private var openWindowChecked = 0

    private struct MemoryStats {
        var total: Int = 0
        var superseded: Int = 0
        var unreviewed: Int = 0
    }

    private struct PendingCounts: Equatable {
        var open = 0
        var faded = 0
        /// 待续本子迁不好 / 读不全：照实说
        var problem: String?
    }

    var body: some View {
        Group {
            ForEach(MemoryPageLayout.sections, id: \.title) { section in
                sectionView(section)
            }
            // v4-1 §九：按新规则重写 / 从备份恢复，只在 DEBUG 构建里（Q10）
            #if DEBUG
            MemoryRegenerationSection()
            #endif
            sectionInfra
        }
        .sheet(isPresented: $showTrash, onDismiss: refresh) {
            MemoryTrashSheet(profileId: profileManager?.currentProfile.id ?? "")
        }
        .onAppear { refresh() }
        .onChange(of: profileManager?.currentProfile.id) { _, _ in refreshRecallSettings() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            refreshRecallSettings()
        }
        .onReceive(SettingsSearchRouter.shared.$flashingAnchor) { anchor in
            guard let anchor, let route = SettingsSearchEntry.memorySubpage(for: anchor) else { return }
            if let pushRoute { pushRoute(route) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            memoryStats = MemoryStats()
            deletedSelfCount = 0
            pending = PendingCounts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in
            refresh()
        }
    }

    // MARK: - 节

    @ViewBuilder
    private func sectionView(_ section: MemoryPageLayout.Section) -> some View {
        let dim = !masterOn && !section.title.isEmpty
        Section {
            ForEach(section.rows, id: \.self) { row in
                rowView(row)
            }
        } header: {
            if !section.title.isEmpty {
                // section 级搜索锚点：回想节沿用老锚 leaf-mem-content
                switch section.rows.first {
                case .some(.everyRound): Text(section.title).searchAnchor("leaf-mem-content")
                default: Text(section.title)
                }
            }
        }
        .panelRowBackground()
        .listRowSeparator(.hidden)
        .disabled(dim)
        .opacity(dim ? 0.5 : 1)
    }

    @ViewBuilder
    private func rowView(_ row: MemoryPageLayout.Row) -> some View {
        switch row {
        case .master: masterRow
        case .startDay: startDayRows
        case .extractModel: extractModelRow
        case .writeBudget: writeBudgetRow
        case .complexity: complexityRow
        case .ccMemorySync: CCMemorySyncCard()
        case .pending: pendingRow
        case .audit: auditRow
        case .trash: trashRow
        case .openWindow: openWindowRow
        case .everyRound: recallGroup("每轮都带的")
        case .automatic: recallGroup("自动想起 · 聊到了才带").searchAnchor("leaf-mem-inject")
        case .browse: recallGroup("翻记忆 · \(assistantName)自己翻")
        case .seen: recallGroup("看到了什么")
        case .oldFragments: recallGroup("── 旧碎片记忆（整理完一起退）──")
        case .archiveTrigger:
            SettingsNavRow(.memoryArchiveTrigger) {
                ArchiveTriggerPage()
            } label: {
                HStack(spacing: 10) {
                    rowLabel("档案触发", "聊到哪页带哪页")
                    Toggle("", isOn: tuningSwitch(\.archiveTriggerEnabled))
                        .labelsHidden()
                        .tint(Theme.branchIndicator)
                }
            }
            .searchAnchor("leaf-mem-archivetrigger")
        case .maximumPages:
            LimitStepper(title: "一轮最多几页", value: "\(recallTuning.maximumPages) 页",
                         number: Binding(get: { recallTuning.maximumPages }, set: { value in
                             var latest = RecallTuningStore.load(profileId: profileId)
                             latest.maximumPages = value
                             RecallTuningStore.save(latest, profileId: profileId)
                             refreshRecallSettings()
                         }), range: 1...20)
                .searchAnchor("leaf-mem-maximumpages")
        case .cooldown:
            memSwitchRow("冷却", "带了你没接茬就先停几句", tuningSwitch(\.cooldownEnabled))
                .searchAnchor("leaf-mem-cooldown")
        case .recall:
            DisclosureModeRow(kind: .recall, fontSize: Theme.F.body, valueSize: Theme.F.secondary)
                .searchAnchor("leaf-mem-recall")
        case .injectBudget: injectBudgetRow
        case .injectFull:
            memSwitchRow("全量注入", "不筛选，全部注入", $memInjectFull)
                .searchAnchor("leaf-mem-injectfull")
        case .injectKeyword:
            memSwitchRow("关键词命中", "对话命中关键词时才注入", $memInjectKeyword)
                .searchAnchor("leaf-mem-injectkeyword")
        case .injectVector: vectorRows
        case .injectGraph:
            memSwitchRow("关联扩展", "命中一条顺带它的关联记忆", $memInjectGraph)
                .searchAnchor("leaf-mem-injectgraph")
        case .convHistory:
            SettingsNavRow(.memoryRecallBrowse) {
                RecallBrowsePage()
            } label: {
                HStack(spacing: 10) {
                    rowLabel("对话历史搜索", "\(assistantName)可以搜旧对话原话和记忆（带出处）")
                    Toggle("", isOn: $memContentConvHistory)
                        .labelsHidden()
                        .tint(Theme.branchIndicator)
                }
            }
            .searchAnchor("leaf-mem-convhistory")
        default:
            if let id = row.writer { writerRow(id) }
        }
    }

    // MARK: - 顶上

    private var masterOn: Bool { memMaster && PermissionCenter.defaultLevel(.memory) == .bypass }

    private var masterRow: some View {
        Toggle(isOn: Binding(
            get: { PermissionCenter.defaultLevel(.memory) == .bypass },
            set: { PermissionCenter.setDefaultLevel($0 ? .bypass : .notAllowed, for: .memory); memMaster = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("记忆系统总开关")
                    .font(m.rowTitle)
                    .foregroundColor(Theme.textPrimary)
                Text("关 = 不注入、不提取、不强化；数据不动")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
        }
        .tint(Theme.branchIndicator)
        .searchAnchor("leaf-mem-master")
    }

    @ViewBuilder
    private var startDayRows: some View {
        // 关 = 不限；开了下面出一行选日期（默认今天，不能选以后的）
        memSwitchRow("记忆从哪天开始", "这天以前的聊天不写上下文摘要、窗口总结、时间轴；已经记下的不动",
                     Binding(get: { !memStartDay.isEmpty },
                             set: { memStartDay = $0 ? MemoryStartDay.format(Date()) : "" }),
                     tech: memStartDay.isEmpty ? "不限" : nil)
            .searchAnchor("leaf-mem-startday")
        if !memStartDay.isEmpty {
            DatePicker(selection: Binding(get: { MemoryStartDay.parse(memStartDay) ?? Date() },
                                          set: { memStartDay = MemoryStartDay.format($0) }),
                       in: ...Date(), displayedComponents: .date) {
                Text("从这天开始")
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
            }
            .datePickerStyle(.compact)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .tint(Theme.branchIndicator)
        }
    }

    /// 和 API 设置模型池里的 🌛 写同一个 key（值 = ProviderModel.id「卡 ID/模型 ID」，空 = 自动），两边联动。
    /// 390 宽：模型名放副标题，右边只留一个小箭头（v5）
    private var extractModelRow: some View {
        Menu {
            Picker(selection: $memoryExtractModelId) {
                Text("自动（默认）").tag("")
                if extractModelIsStale {
                    Text("已停用的模型（现在按自动）").tag(memoryExtractModelId)
                }
                ForEach(extractModelChoices, id: \.id) { c in
                    Section(c.name) {
                        ForEach(c.models) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
            } label: {
                Text("提取模型")
            }
            .pickerStyle(.inline)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("提取模型")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Text("没单独选的都用它 · \(extractModelLabel)")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("提取模型：\(extractModelLabel)")
        .searchAnchor("leaf-mem-extractmodel")
    }

    private var writeBudgetRow: some View {
        SettingsNavRow(.memoryWriteBudget) {
            WriteBudgetPage()
        } label: {
            rowLabel("写入预算", writeBudget.summary())
        }
        .searchAnchor("leaf-mem-writebudget")
        .task { await writeBudget.refreshSpent() }
    }

    /// 复杂度滑条（plan §五）：不存值；拖一档 = 改一组写入开关；对不上显示「自定义」
    private var complexityRow: some View {
        let _ = (writeA2, writeA3, writeA4, writeB1, writeB4, writeC2)
        let level = MemoryComplexity.current()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("复杂度")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Text(MemoryComplexity.summary())
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                Spacer(minLength: 0)
            }
            Slider(value: Binding(
                get: { Double(level ?? 2) },
                set: { v in
                    let target = Int(v.rounded())
                    if target != level { MemoryComplexity.apply(target) }
                }
            ), in: 0...3, step: 1)
            .tint(Theme.branchIndicator)
            HStack {
                ForEach(MemoryComplexity.names.indices, id: \.self) { i in
                    Text(MemoryComplexity.names[i])
                        .font(m.caption.weight(i == level ? .semibold : .regular))
                        .foregroundColor(i == level ? Theme.textPrimary : Theme.textMuted)
                    if i < MemoryComplexity.names.count - 1 { Spacer(minLength: 0) }
                }
            }
        }
        .searchAnchor("leaf-mem-complexity")
    }

    // MARK: - 写入 · 记什么

    @ViewBuilder
    private func writerRow(_ id: MemoryWriterID) -> some View {
        let title = "\(id.code) \(id.title(assistant: assistantName))"
        if id.isTodo {
            rowLabel(title, "还没做")
                .opacity(0.5)
                .searchAnchor("leaf-mem-w-\(id.rawValue)")
        } else if let route = SettingsRoute.memoryWriter(id) {
            SettingsNavRow(route) {
                MemoryWriterPage(id: id)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    rowLabel(title, writerSubtitle(id))
                    if id.hasSwitch {
                        Toggle("", isOn: Binding(get: { writerOn(id) }, set: { MemoryWriterSettings.set(id, $0) }))
                            .labelsHidden()
                            .tint(Theme.branchIndicator)
                    }
                }
            }
            .searchAnchor("leaf-mem-w-\(id.rawValue)")
        }
    }

    /// 读键时顺手碰一下 AppStorage，开关一变整行跟着刷
    private func writerOn(_ id: MemoryWriterID) -> Bool {
        _ = (writeA2, writeA3, writeA4, writeB1, writeB4, writeC2, writeC3)
        return MemoryWriterSettings.isOn(id)
    }

    /// 一句话 + 用哪个模型（模型写在副标题后面，390 宽右边只放开关）
    private func writerSubtitle(_ id: MemoryWriterID) -> String {
        let base = id.subtitle(assistant: assistantName)
        switch id {
        case .a2, .a3: return "\(base) · \(writerModelLabel(id))"
        case .a4: return "\(base) · \(localRouteLabel(TimelineModelRoute.choice(modelA4)))"
        case .b1, .b4: return "\(base) · 对话模型"
        case .c: return "\(base) · \(memoryStats.total) 条"
        case .c2: return "\(base) · \(localRouteLabel(modelC2))"
        case .c3: return "\(base) · \(localRouteLabel(modelC3))"
        default: return base
        }
    }

    private func writerModelLabel(_ id: MemoryWriterID) -> String {
        let choice = [MemoryWriterID.a2: modelA2, .a3: modelA3][id] ?? ""
        guard !choice.isEmpty, let model = remoteModels.first(where: { $0.id == choice }) else { return extractModelLabel }
        return model.name
    }

    /// A4 / C2 / C3 的模型：C2 / C3 默认跟提取模型、A4 默认本机轻巧款；选了本机没下写清楚这一轮先用谁
    private func localRouteLabel(_ choice: String) -> String {
        if let local = FragmentModelRoute.localModelId(choice: choice) {
            let installed = localModels.state(AssistantLocalModel.catalog.first { $0.id == local } ?? .smart) == .installed
            return installed ? FragmentModelRoute.localName(local) : "本机没下 · 先用\(extractModelLabel)"
        }
        if choice == FragmentModelRoute.extractChoice { return extractModelLabel }
        return remoteModels.first { $0.id == choice }?.name ?? extractModelLabel
    }

    // MARK: - 整理 · 怎么管

    private var pendingRow: some View {
        SettingsNavRow(.memoryPending) {
            PendingListPage()
        } label: {
            rowLabel("待续", pending.problem ?? "没做完 \(pending.open) · 淡了 \(pending.faded)")
        }
        .searchAnchor("leaf-mem-pending")
    }

    /// 审计台：顶掉老「整理记忆」（plan-memory-audit-desk 第五节）
    private var auditRow: some View {
        SettingsNavRow(.memoryAudit) {
            MemoryAuditPage().memorySubpage("整理台")
        } label: {
            rowLabel("整理台", "没看过 \(memoryStats.unreviewed) 条")
        }
        .searchAnchor("leaf-mem-audit")
    }

    // 「已删除 · N ›」：两类记忆删掉的都算（有才出现），和记忆页列表底那行开同一个弹层
    @ViewBuilder
    private var trashRow: some View {
        let n = memoryStats.superseded + deletedSelfCount
        if n > 0 {
            Button {
                showTrash = true
            } label: {
                HStack {
                    Text("已删除 · \(n)")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 回想 · 每轮都带的

    private var openWindowRow: some View {
        let checked = openWindowChecked
        return SettingsNavRow(.memoryOpenWindow) {
            MemoryOpenWindowPage()
        } label: {
            rowLabel("开窗口带什么", "勾了 \(checked) 项 · 按楼层")
        }
        .searchAnchor("leaf-mem-openwindow")
    }

    private var injectBudgetRow: some View {
        Stepper(value: $memInjectBudget, in: 500...20000, step: 500) {
            HStack {
                Text("注入预算")
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(memInjectBudget) token")
                    .font(m.caption.monospaced())
                    .foregroundColor(Theme.textMuted)
            }
        }
        .searchAnchor("leaf-mem-budget")
    }

    // MARK: - 检索 · 怎么挑记忆（可叠加）

    @ViewBuilder
    private var vectorRows: some View {
        memSwitchRow("按意思找记忆", "聊到意思相近的事也能想起来（第一次打开会下载本地模型）", $memInjectVector, tech: "向量检索")
            .onChange(of: memInjectVector) { _, on in
                if on { AppleMemoryEmbedder.shared.requestAssetsIfNeeded() }
            }
            .searchAnchor("leaf-mem-injectvector")
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
    }

    @ViewBuilder
    private var sectionInfra: some View {
        #if DEBUG
        Section("还没做") {
            Text("文件 / 发图历史、Moment（事件感知）、提取门槛、语境 tag、随机联想、记忆网关")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .panelRowBackground()
        .listRowSeparator(.hidden)
        #endif
    }

    // MARK: - Helpers

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    private func refreshRecallSettings() {
        recallTuning = RecallTuningStore.load(profileId: profileId)
        openWindowChecked = MemoryOpenWindow.rows.filter { MemoryOpenWindow.isChecked($0, profileId: profileId) }.count
    }

    private func tuningSwitch(_ path: WritableKeyPath<RecallTuning, Bool>) -> Binding<Bool> {
        Binding(get: { recallTuning[keyPath: path] }, set: { value in
            var latest = RecallTuningStore.load(profileId: profileId)
            latest[keyPath: path] = value
            RecallTuningStore.save(latest, profileId: profileId)
            refreshRecallSettings()
        })
    }

    private func recallGroup(_ title: String) -> some View {
        Text(title).font(m.caption).foregroundColor(Theme.textMuted)
            .listRowSeparator(.hidden)
    }

    /// UI 名字用楼层变量，不写死
    private var assistantName: String {
        let n = profileManager?.currentProfile.assistantName ?? ""
        return n.isEmpty ? "助手" : n
    }

    private func rowLabel(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(m.body)
                .foregroundColor(Theme.textPrimary)
            Text(sub)
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func memSwitchRow(_ title: String, _ sub: String, _ isOn: Binding<Bool>, tech: String? = nil) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    if let tech {
                        Text(tech)
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                Text(sub)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
        }
        .tint(Theme.branchIndicator)
    }

    /// 只列启用了的卡：运行时 `ConversationViewModel.memoryModel` 也只认启用卡里的模型
    private var extractModelChoices: [APICredential] {
        (providerManager?.enabledProviders ?? []).filter { !$0.models.isEmpty }
    }

    private var remoteModels: [ProviderModel] {
        FragmentModelRoute.remoteCredentials(providerManager?.enabledProviders ?? []).flatMap(\.models)
    }

    /// 存着的模型不在启用卡里（卡停用了 / 模型删了）：运行时按自动
    private var extractModelIsStale: Bool {
        !memoryExtractModelId.isEmpty && !extractModelChoices.contains { $0.models.contains { $0.id == memoryExtractModelId } }
    }

    /// 当前值，和菜单里的选项文字一致
    private var extractModelLabel: String {
        if memoryExtractModelId.isEmpty { return "自动" }
        if extractModelIsStale { return "已停用的模型（现在按自动）" }
        return extractModelChoices.lazy.flatMap(\.models).first { $0.id == memoryExtractModelId }?.name ?? "自动"
    }

    // MARK: - Actions

    private func refresh() {
        refreshRecallSettings()
        let profileId = profileManager?.currentProfile.id ?? ""
        let all = SwiftDataMemoryStore().listAll(profileId: profileId, context: modelContext)
        let active = all.filter { $0.supersededAt == nil }
        memoryStats = MemoryStats(
            total: active.count,
            superseded: all.count - active.count,
            unreviewed: active.filter { $0.reviewedAt == nil }.count
        )
        Task {
            let (n, items, problem) = await Task.detached { () -> (Int, [PendingItem]?, String?) in
                // 待续单独存：第一次进来顺手迁移（先备份、严格读、补齐，时间轴条目不动）；迁不好照实说
                var problem: String?
                do { try TimelineDaily.preparePendingForEdit(profileId: profileId) } catch { problem = TimelineDaily.pendingProblem(error) }
                return (SelfMemoryStore.list(memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId), checkPath: AppPaths.checked).filter { !$0.isActive }.count, PendingStore.load(profileId: profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: profileId)), problem)
            }.value
            guard profileId == profileManager?.currentProfile.id else { return }
            deletedSelfCount = n
            let list = items ?? []
            pending = PendingCounts(open: list.filter { $0.state == .open }.count, faded: list.filter { $0.state == .faded }.count,
                                    problem: problem)
        }
    }
}

