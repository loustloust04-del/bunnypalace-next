import MemoryCore
import SwiftUI

// MARK: - 设置 → 记忆 的骨架（粟粟 11-15 批：写按 ABC、读按 Z / X / Y 分节；app 里不做拖动）

/// 节和行的顺序只写这一份：页面按它画，`SettingsSkeletonTests` 按它锁
enum MemoryPageLayout {
    enum Row: String, CaseIterable {
        // 顶上（不带节标题）
        case master, startDay, extractModel, writeBudget
        // 写 · A / B / C（一个编号一行）
        case writerA2, writerA3, writerA4, writerB1, writerB4, writerC2, writerC3
        // 读 · Z / X / Y
        case openWindow, injectBudget, archiveTrigger, convHistory
        // 接口
        case ccMemorySync, recall
        // 最底下
        case auditSettings, explainer

        var writer: MemoryWriterID? {
            switch self {
            case .writerA2: return .a2
            case .writerA3: return .a3
            case .writerA4: return .a4
            case .writerB1: return .b1
            case .writerB4: return .b4
            case .writerC2: return .c2
            case .writerC3: return .c3
            default: return nil
            }
        }
    }

    struct Section: Equatable {
        /// `{助手}` 画的时候换成楼层的助手名
        let title: String
        let rows: [Row]
    }

    static let sections: [Section] = [
        Section(title: "", rows: [.master, .startDay, .extractModel, .writeBudget]),
        Section(title: "写 · A 纪录片", rows: [.writerA2, .writerA3, .writerA4]),
        Section(title: "写 · B 日记", rows: [.writerB1, .writerB4]),
        Section(title: "写 · C 活档案", rows: [.writerC2, .writerC3]),
        Section(title: "读 · Z 每轮都带", rows: [.openWindow, .injectBudget]),
        Section(title: "读 · X 自动推送", rows: [.archiveTrigger]),
        Section(title: "读 · Y {助手}主动翻", rows: [.convHistory]),
        Section(title: "接口", rows: [.ccMemorySync, .recall]),
        Section(title: "", rows: [.auditSettings, .explainer]),
    ]

    static func title(_ section: Section, assistant: String) -> String {
        section.title.replacingOccurrences(of: "{助手}", with: assistant)
    }
}

// MARK: - Memory Page Content（共用核：设置-记忆 / 记忆 app「设置」分段）
//
// 单一来源 — 改一处两边生效。节和行的顺序见 `MemoryPageLayout`。

struct MemoryPageContent: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsRoutePush) private var pushRoute
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    /// B15：共用核搬进 mac 设置窗后，raw `Theme.F`（mac 表 11/9）比 J2 小一档 → 全部走 `m.*`（iOS 不变，mac 13/10）
    @Environment(\.settingsMetrics) private var m

    @AppStorage("memoryExtractModelId") private var memoryExtractModelId = ""
    @AppStorage("mem_master") private var memMaster = true
    /// 「记忆从哪天开始」：yyyy-MM-dd，空 = 不限（MemoryStartDay）
    @AppStorage(MemoryStartDay.key) private var memStartDay = ""
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

    @State private var writeBudget = WriteBudgetStore.shared
    @State private var recallTuning = RecallTuning.defaults
    @State private var openWindowChecked = 0

    var body: some View {
        Group {
            ForEach(Array(MemoryPageLayout.sections.enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }
        }
        .onAppear { refreshRecallSettings() }
        .onChange(of: profileManager?.currentProfile.id) { _, _ in refreshRecallSettings() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            refreshRecallSettings()
        }
        .onReceive(SettingsSearchRouter.shared.$flashingAnchor) { anchor in
            guard let anchor, let route = SettingsSearchEntry.memorySubpage(for: anchor) else { return }
            if let pushRoute { pushRoute(route) }
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
                Text(MemoryPageLayout.title(section, assistant: assistantName))
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
        case .ccMemorySync:
            SettingsNavRow(.memoryCCSync) {
                MemoryCCSyncPage()
            } label: {
                titleLabel("和 CC 同步")
            }
            .searchAnchor("leaf-mem-ccsync")
        case .auditSettings:
            SettingsNavRow(.memoryAuditSettings) {
                MemoryAuditSettingsPage()
            } label: {
                titleLabel("审计台设置")
            }
            .searchAnchor("leaf-mem-auditsettings")
        case .explainer:
            SettingsNavRow(.memoryExplainer) {
                MemoryExplainerPage()
            } label: {
                titleLabel("记忆系统说明")
            }
            .searchAnchor("leaf-mem-explainer")
        case .openWindow: openWindowRow
        case .archiveTrigger:
            SettingsNavRow(.memoryArchiveTrigger) {
                ArchiveTriggerPage()
            } label: {
                HStack(spacing: 10) {
                    rowLabel("系统推送给\(assistantName)", "聊到哪页、哪条记忆条目，就推送哪个")
                    Toggle("", isOn: tuningSwitch(\.archiveTriggerEnabled))
                        .labelsHidden()
                        .tint(Theme.branchIndicator)
                }
            }
            .searchAnchor("leaf-mem-archivetrigger")
        case .recall:
            DisclosureModeRow(kind: .recall, fontSize: Theme.F.body, valueSize: Theme.F.secondary)
                .searchAnchor("leaf-mem-recall")
        case .injectBudget: injectBudgetRow
        case .convHistory:
            SettingsNavRow(.memoryRecallBrowse) {
                RecallBrowsePage()
            } label: {
                HStack(spacing: 10) {
                    rowLabel("翻记忆", "\(assistantName)可以搜旧对话原话和记忆（带出处）")
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
                Text("默认模型")
            }
            .pickerStyle(.inline)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("默认模型")
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
        .accessibilityLabel("默认模型：\(extractModelLabel)")
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

    // MARK: - 写 · A / B / C

    @ViewBuilder
    private func writerRow(_ id: MemoryWriterID) -> some View {
        if let route = SettingsRoute.memoryWriter(id) {
            SettingsNavRow(route) {
                MemoryWriterPage(id: id)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    rowLabel("\(id.code) \(id.displayTitle(assistant: assistantName))", id.subtitle(assistant: assistantName))
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

    // MARK: - 读 · Z 每轮都带

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

    // MARK: - Helpers

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    private func refreshRecallSettings() {
        recallTuning = RecallTuningStore.load(profileId: profileId)
        openWindowChecked = MemoryOpenWindow.checkedCount(profileId: profileId)
    }

    private func tuningSwitch(_ path: WritableKeyPath<RecallTuning, Bool>) -> Binding<Bool> {
        Binding(get: { recallTuning[keyPath: path] }, set: { value in
            var latest = RecallTuningStore.load(profileId: profileId)
            latest[keyPath: path] = value
            RecallTuningStore.save(latest, profileId: profileId)
            refreshRecallSettings()
        })
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

    /// 只有标题、点进去是一页的行（和 rowLabel 同一套字号颜色）
    private func titleLabel(_ title: String) -> some View {
        Text(title)
            .font(m.body)
            .foregroundColor(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memSwitchRow(_ title: String, _ sub: String, _ isOn: Binding<Bool>, tech: String? = nil) -> some View {
        MemorySwitchRow(title: title, sub: sub, isOn: isOn, tech: tech)
    }

    /// 只列启用了的卡：运行时 `ConversationViewModel.memoryModel` 也只认启用卡里的模型
    private var extractModelChoices: [APICredential] {
        (providerManager?.enabledProviders ?? []).filter { !$0.models.isEmpty }
    }

    /// 存着的模型不在启用卡里（卡停用了 / 模型删了）：运行时按自动
    private var extractModelIsStale: Bool {
        !memoryExtractModelId.isEmpty && !extractModelChoices.contains { $0.models.contains { $0.id == memoryExtractModelId } }
    }

    /// 当前值：选了的写名字；自动 / 停用了的把现在实际用的那个模型也写出来（「自动」背后是谁以前看不见）
    private var extractModelLabel: String {
        if memoryExtractModelId.isEmpty { return "自动 · 现在用 \(extractActualName)" }
        if extractModelIsStale { return "已停用的模型（现在按自动 · 用 \(extractActualName)）" }
        return extractModelChoices.lazy.flatMap(\.models).first { $0.id == memoryExtractModelId }?.name ?? "自动 · 现在用 \(extractActualName)"
    }

    /// 提取模型现在实际解析成谁（和写手运行时同一处：`MemoryWriterModels.extract`）
    private var extractActualName: String {
        _ = memoryExtractModelId
        return providerManager.map { MemoryWriterModels.extract(providers: $0).name } ?? "自动"
    }
}

/// 记忆设置里「标题（+ 小灰技术名）+ 一句话 + 开关」那一行；一级页和开发调试 › 记忆 · 没做完的 共用
struct MemorySwitchRow: View {
    @Environment(\.settingsMetrics) private var m
    let title: String
    let sub: String
    @Binding var isOn: Bool
    var tech: String? = nil

    var body: some View {
        Toggle(isOn: $isOn) {
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
}
