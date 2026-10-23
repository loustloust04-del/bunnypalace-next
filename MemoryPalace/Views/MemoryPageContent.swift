import SwiftUI
import SwiftData

// MARK: - Memory Page Content（共用核：设置-记忆 / 记忆 app「设置」分段）
//
// 按 cc-rp 六组分组（感知 / 提取 / 整理 / 注入 / 检索 / 基建）拼装 Section。
// 单一来源 — 改一处两边生效。

struct MemoryPageContent: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    /// B15：共用核搬进 mac 设置窗后，raw `Theme.F`（mac 表 11/9）比 J2 小一档 → 全部走 `m.*`（iOS 不变，mac 13/10）
    @Environment(\.settingsMetrics) private var m

    // 记忆系统全集 AppStorage（六组）
    @AppStorage("memoryExtractModelId") private var memoryExtractModelId = ""
    @AppStorage("customMemoryExtractionPrompt") private var customMemoryPrompt = ""
    @AppStorage("mem_master") private var memMaster = true
    /// 「记忆从哪天开始」：yyyy-MM-dd，空 = 不限（MemoryStartDay）
    @AppStorage(MemoryStartDay.key) private var memStartDay = ""
    @AppStorage("mem_extract_interval") private var memExtractInterval = 3
    @AppStorage("mem_inject_full") private var memInjectFull = true
    @AppStorage("mem_inject_keyword") private var memInjectKeyword = false
    @AppStorage("mem_inject_vector") private var memInjectVector = false
    @AppStorage("mem_inject_graph") private var memInjectGraph = false
    @AppStorage("mem_content_facts") private var memContentFacts = true
    @AppStorage("mem_content_profile") private var memContentProfile = false
    @AppStorage("mem_inject_profile") private var memInjectProfile = false
    @AppStorage("mem_content_summary") private var memContentSummary = true
    @AppStorage("mem_content_convhistory") private var memContentConvHistory = true
    @AppStorage("mem_inject_catalog") private var memInjectCatalog = false
    @AppStorage(DisclosureKind.recall.key) private var recallModeRaw = DisclosureKind.recall.migratedDefault.rawValue
    @AppStorage("mem_recall_feedback") private var memRecallFeedback = true
    @AppStorage("mem_content_timeline") private var memContentTimeline = true
    @AppStorage("mem_content_heartvoice") private var memContentHeartvoice = false
    @AppStorage("heartvoice_show_in_chat") private var heartvoiceShowInChat = false
    @AppStorage("mem_inject_budget") private var memInjectBudget = 10000
    // 第二刀 C：AI 自己的记忆几个可调限制（默认值同 MemoryFlags）
    @AppStorage("mem_self_recent_count") private var selfRecentCount = 5
    @AppStorage("mem_self_daily_limit") private var selfDailyLimit = 12
    @AppStorage("mem_self_budget_percent") private var selfBudgetPercent = 100
    @AppStorage("mem_self_body_limit") private var selfBodyLimit = 800
    @AppStorage("mem_session_full_segments") private var sessionFullSegments = 2
    @AppStorage("mem_timeline_inject_count") private var timelineInjectCount = 8
    @AppStorage("mem_timeline_inject_days") private var timelineInjectDays = 7

    @State private var profileDream: UserProfileDream? = nil
    @State private var showProfile = false
    @State private var showOrganize = false
    @State private var showTrash = false
    @State private var deletedSelfCount = 0
    @State private var memoryStats = MemoryStats()

    private struct MemoryStats {
        var total: Int = 0
        var superseded: Int = 0
    }

    var body: some View {
        Group {
            sectionPerception
            sectionExtraction
            sectionOrganize
            sectionInjection
            sectionRetrieval
            sectionAdvanced
            sectionInfra
        }
        .sheet(isPresented: $showTrash, onDismiss: refresh) {
            MemoryTrashSheet(profileId: profileManager?.currentProfile.id ?? "")
        }
        .sheet(isPresented: $showProfile) {
            MemoryProfileSheet(profileId: profileManager?.currentProfile.id ?? "")
        }
        .sheet(isPresented: $showOrganize) {
            MemoryOrganizeSheet(profileId: profileManager?.currentProfile.id ?? "")
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            profileDream = nil
            memoryStats = MemoryStats()
            deletedSelfCount = 0
            showProfile = false
            showOrganize = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in
            refresh()
        }
    }

    // MARK: - Section ① 感知·记什么

    @ViewBuilder
    private var sectionPerception: some View {
        Section("感知 · 记什么") {
            Toggle(isOn: Binding(
                get: { PermissionCenter.level(.memory) == .bypass },
                set: { PermissionCenter.setLevel($0 ? .bypass : .notAllowed, for: .memory); memMaster = $0 }
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
            // 关 = 不限；开了下面出一行选日期（默认今天，不能选以后的）
            memSwitchRow("记忆从哪天开始", "这天以前的聊天不写上下文摘要、窗口总结、时间轴；已经记下的不动",
                         Binding(get: { !memStartDay.isEmpty },
                                 set: { memStartDay = $0 ? MemoryStartDay.format(Date()) : "" }),
                         true, tech: memStartDay.isEmpty ? "不限" : nil)
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
            memSwitchRow("从聊天里记住的", "聊天时在后台把关于你的事记下来；关 = 不再记新的，已经记下的照常会想起", $memContentFacts, true, tech: "原子档案")
                .searchAnchor("leaf-mem-facts")
            memSwitchRow("心声", "\(assistantName)聊到触动处会写一小篇独白", $memContentHeartvoice, true)
                .searchAnchor("leaf-mem-heartvoice")
            if memContentHeartvoice {
                memSwitchRow("心声进聊天流", "开 = 实时显示；关 = 只默默落盘，翻日历查看", $heartvoiceShowInChat, true)
            }
        }
        .panelRowBackground()
        .listRowSeparator(.hidden)
    }

    // MARK: - Section ② 提取·怎么记

    @ViewBuilder
    private var sectionExtraction: some View {
        Section("提取 · 怎么记") {
            // 和 API 设置模型池里的 🌛 写同一个 key（值 = ProviderModel.id「卡 ID/模型 ID」，空 = 自动），两边联动
            // 排法同开关行：左边标题 + 说明，右边菜单。说明放进 Picker 的 label 时 iOS 会把选中值挤到下一行
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("提取模型")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Text("记新东西、写画像、写上下文摘要和窗口总结都用这个模型。自动 = 主对话那家有内置的便宜款就用它，没有就和主对话用同一个")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                Spacer(minLength: 0)
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
                    HStack(spacing: 4) {
                        Text(extractModelLabel)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(m.caption)
                    }
                    .font(m.body)
                    .foregroundColor(Theme.branchIndicator)
                }
                .fixedSize()
                .accessibilityLabel("提取模型：\(extractModelLabel)")
            }
            .searchAnchor("leaf-mem-extractmodel")

            SettingsNavRow(.memoryExtractPrompt) {
                PromptEditorPage.memoryExtract
            } label: {
                HStack {
                    Text("提取提示词")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text(customMemoryPrompt.isEmpty ? "默认" : "自定义")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .searchAnchor("leaf-mem-extractprompt")
            if !customMemoryPrompt.isEmpty {
                Text("你用的是自定义提示词；想换回默认的，进去点恢复默认")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }

            Stepper(value: $memExtractInterval, in: 1...10) {
                HStack {
                    Text("提取间隔")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text("每 \(memExtractInterval) 轮一次")
                        .font(m.caption.monospaced())
                        .foregroundColor(Theme.textMuted)
                }
            }

        }
        .panelRowBackground()
        .listRowSeparator(.hidden)
    }

    // MARK: - Section ③ 整理·怎么管

    @ViewBuilder
    private var sectionOrganize: some View {
        Section("整理 · 怎么管") {
            memSwitchRow("用户画像 · 做梦聚合", "定期把记忆凝成画像（每天一次）", $memContentProfile, true)
                .searchAnchor("leaf-mem-userprofile")
            profileRow
            organizeRow
            trashRow
            organizeStatsRow
        }
        .panelRowBackground()
        .listRowSeparator(.hidden)
    }

    /// 画像入口：打开画像弹层（全文 / 编辑 / 重写画像 / 删除画像），和记忆 app 首屏画像卡同一个
    private var profileRow: some View {
        Button {
            showProfile = true
        } label: {
            HStack {
                Text(profileDream.map { "\(assistantName)眼里的你 · \($0.text.count) 字 · \(MemoryDateText.short($0.updatedAt))" }
                     ?? "还没有画像。聊几天后\(assistantName)会自己写一份")
                    .font(m.body)
                    .foregroundColor(profileDream == nil ? Theme.textMuted : Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .searchAnchor("leaf-mem-dream")
    }

    private var organizeRow: some View {
        Button {
            showOrganize = true
        } label: {
            HStack {
                Text("整理记忆…")
                    .font(m.body)
                    .foregroundColor(Theme.branchIndicator)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .searchAnchor("leaf-mem-hygiene")
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

    private var organizeStatsRow: some View {
        HStack(spacing: 12) {
            statBadge("从聊天里记住的", count: memoryStats.total, color: Theme.branchIndicator)
        }
    }

    // MARK: - Section ④ 注入·塞什么进 prompt

    @ViewBuilder
    private var sectionInjection: some View {
        Section {
            // 修复第一刀·刀3：画像注入独立 key（mem_inject_profile），与 ③ 做梦互不影响
            memSwitchRow("画像注入", "把画像放进 system prompt", $memInjectProfile, true)
            memSwitchRow("上下文摘要和窗口总结", "长对话挤出视野的部分一段段记下经过和原话；每个窗口聊完整理一份从头到尾的窗口总结", $memContentSummary, true)
                .searchAnchor("leaf-mem-summary")
            memSwitchRow("时间轴", "每个窗口每天一条：聊了什么、还欠着什么，新窗口能看到最近的", $memContentTimeline, true)
                .searchAnchor("leaf-mem-timeline")
            memSwitchRow("目录式注入", "命中记忆只注一行目录，细节按需取回", $memInjectCatalog, true)
                .searchAnchor("leaf-mem-catalog")
            DisclosureModeRow(kind: .recall, fontSize: Theme.F.body, valueSize: Theme.F.secondary)
            if recallModeRaw != DisclosureMode.hidden.rawValue {
                memSwitchRow("召回反馈", "卡片上显示点赞点踩，点了会调整这条记忆的权重", $memRecallFeedback, true)
                    .searchAnchor("leaf-mem-feedback")
            }

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
        } header: {
            // section 级条目「记忆内容 · 注入什么」的锚点
            Text("注入 · 塞什么进 prompt").searchAnchor("leaf-mem-content")
        }
        .panelRowBackground()
        .listRowSeparator(.hidden)
    }

    // MARK: - Section ⑤ 检索·怎么挑记忆（可叠加）

    @ViewBuilder
    private var sectionRetrieval: some View {
        Section {
            memSwitchRow("全量注入", "不筛选，全部注入", $memInjectFull, true)
                .searchAnchor("leaf-mem-injectfull")
            memSwitchRow("关键词命中", "对话命中关键词时才注入", $memInjectKeyword, true)
                .searchAnchor("leaf-mem-injectkeyword")
            memSwitchRow("按意思找记忆", "聊到意思相近的事也能想起来（第一次打开会下载本地模型）", $memInjectVector, true, tech: "向量检索")
                .onChange(of: memInjectVector) { _, on in
                    if on { AppleMemoryEmbedder.shared.requestAssetsIfNeeded() }
                }
                .searchAnchor("leaf-mem-injectvector")
            memSwitchRow("关联扩展", "命中一条顺带它的关联记忆", $memInjectGraph, true)
                .searchAnchor("leaf-mem-injectgraph")
            memSwitchRow("对话历史搜索", "\(assistantName)可以搜旧对话原话和记忆（带出处）", $memContentConvHistory, true)
                .searchAnchor("leaf-mem-convhistory")

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
        } header: {
            // section 级条目「注入策略 · 怎么挑记忆」的锚点
            Text("检索 · 怎么挑记忆（可叠加）").searchAnchor("leaf-mem-inject")
        }
        .panelRowBackground()
        .listRowSeparator(.hidden)
    }

    // MARK: - Section ⑥ 基建

    @ViewBuilder
    private var sectionAdvanced: some View {
        Section {
            limitStepper("每轮带全文的最近几条", "\(selfRecentCount) 条（重要度 5 的另算，全部带）", $selfRecentCount, 1...30, 1)
            limitStepper("自己主动记的每日上限", "\(selfDailyLimit) 条（你让记的、你改的都不算）", $selfDailyLimit, 1...50, 1)
            limitStepper("\(selfMemoryName)最多占注入预算", "\(selfBudgetPercent)%（剩下的给从聊天里记住的）", $selfBudgetPercent, 10...100, 10)
            limitStepper("每条记忆正文上限", "\(selfBodyLimit) 字", $selfBodyLimit, 200...3000, 100)
        } header: {
            Text("高级 · \(selfMemoryName)").searchAnchor("leaf-mem-advanced")
        }
        .panelRowBackground()
        .listRowSeparator(.hidden)

        // 第三刀：窗口摘要 / 跨窗口时间轴注入多少（默认值同 SessionCloseout / TimelineStore）
        Section {
            limitStepper("上下文摘要带全文的最近几段", "\(sessionFullSegments) 段（更早的只带标题）", $sessionFullSegments, 1...4, 1)
            limitStepper("时间轴最多带几条", "\(timelineInjectCount) 条", $timelineInjectCount, 1...30, 1)
            limitStepper("时间轴最多往回看几天", "\(timelineInjectDays) 天", $timelineInjectDays, 1...30, 1)
        } header: {
            Text("高级 · 上下文摘要和时间轴").searchAnchor("leaf-mem-advanced-session")
        }
        .panelRowBackground()
        .listRowSeparator(.hidden)

        // v4-1 §九：按新规则重写 / 从备份恢复，只在 DEBUG 构建里（Q10）
        #if DEBUG
        MemoryRegenerationSection()
        #endif
    }

    /// UI 名字用楼层变量，不写死
    private var assistantName: String {
        let n = profileManager?.currentProfile.assistantName ?? ""
        return n.isEmpty ? "助手" : n
    }

    private var selfMemoryName: String { "\(assistantName)自己记下的" }

    private func limitStepper(_ title: String, _ value: String, _ binding: Binding<Int>, _ range: ClosedRange<Int>, _ step: Int) -> some View {
        Stepper(value: binding, in: range, step: step) {
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

    @ViewBuilder
    private func memSwitchRow(_ title: String, _ sub: String, _ isOn: Binding<Bool>, _ enabled: Bool, tech: String? = nil) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(m.body)
                        .foregroundColor(enabled ? Theme.textPrimary : Theme.textMuted)
                    if let tech {
                        Text(tech)
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                Text(enabled ? sub : "\(sub) · 未实现")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted.opacity(enabled ? 1 : 0.55))
            }
        }
        .tint(Theme.branchIndicator)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func statBadge(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(count)")
                .font(m.secondary)
                .foregroundColor(Theme.textSecondary)
        }
    }

    /// 只列启用了的卡：运行时 `ConversationViewModel.memoryModel` 也只认启用卡里的模型
    private var extractModelChoices: [APICredential] {
        (providerManager?.enabledProviders ?? []).filter { !$0.models.isEmpty }
    }

    /// 存着的模型不在启用卡里（卡停用了 / 模型删了）：运行时按自动
    private var extractModelIsStale: Bool {
        !memoryExtractModelId.isEmpty && !extractModelChoices.contains { $0.models.contains { $0.id == memoryExtractModelId } }
    }

    /// 菜单右边显示的当前值，和菜单里的选项文字一致
    private var extractModelLabel: String {
        if memoryExtractModelId.isEmpty { return "自动（默认）" }
        if extractModelIsStale { return "已停用的模型（现在按自动）" }
        return extractModelChoices.lazy.flatMap(\.models).first { $0.id == memoryExtractModelId }?.name ?? "自动（默认）"
    }

    // MARK: - Actions

    private func refresh() {
        let profileId = profileManager?.currentProfile.id ?? ""
        let all = SwiftDataMemoryStore().listAll(profileId: profileId, context: modelContext)
        let active = all.filter { $0.supersededAt == nil }
        memoryStats = MemoryStats(
            total: active.count,
            superseded: all.count - active.count
        )
        Task {
            let (n, dream) = await Task.detached {
                (SelfMemoryStore.list(profileId: profileId).filter { !$0.isActive }.count, ProfileFileStore.load(profileId: profileId))
            }.value
            guard profileId == profileManager?.currentProfile.id else { return }
            deletedSelfCount = n
            profileDream = dream
        }
    }

}
