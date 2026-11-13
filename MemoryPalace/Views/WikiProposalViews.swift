import MemoryCore
import SwiftUI
import SwiftData

// MARK: - 审计台第四格「整理提案」（plan-memory-c3-catalog 第五节 / todo 10）
// 自己一套数据（读 wiki/.proposals），不进 `MemoryAudit` 的 Memory 动作。iOS / mac 同一套视图；
// 详情推入走 `SettingsNavRow`：mac 设置窗里是值驱动 path（点哪份先记进 `WikiProposalSelection`），别处是 destination 推入。
// 批 / 驳回 / 改都在后台落盘，成功后发 memoryDidChange，失败顶上一行红字。

/// mac 设置窗：`SettingsRoute.memoryProposal` 打开的是哪份提案
@MainActor
@Observable
final class WikiProposalSelection {
    static let shared = WikiProposalSelection()
    var proposalId: String?
    /// `SettingsRoute.memoryProposalItem` 打开的是哪一项（目录项详情）
    var item: WikiProposalItemTarget?
}

/// mac 设置窗里 `SettingsRoute.memoryProposal` 的落点
struct MacWikiProposalRoute: View {
    var body: some View {
        if let id = WikiProposalSelection.shared.proposalId {
            WikiProposalDetailPage(proposalId: id, viewModel: nil)
        }
    }
}

private func proposalStore(_ profileId: String) async -> WikiProposalStore {
    await Task.detached(priority: .userInitiated) { WikiProposalStore(wiki: WikiStore(profileId: profileId)) }.value
}

private func floorAssistantName(_ pm: ProfileManager?) -> String {
    let n = pm?.currentProfile.assistantName ?? ""
    return n.isEmpty ? "助手" : n
}

/// 描边小胶囊（同审计台卡上的留 / 删）
private struct ProposalPill: View {
    let title: String
    let color: Color
    let action: () -> Void
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(m.caption.weight(.medium))
                .foregroundColor(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(color, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - 列表（第四格的正文）

struct WikiProposalsView: View {
    /// 详情里「跳到这条」要拿聊天 VM（推入页不一定继承得到环境，显式传）
    let viewModel: ConversationViewModel?

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage("mem_master") private var memMaster = true
    @AppStorage("mem_write_c3") private var writeC3 = true
    @State private var runner = CatalogRunner.shared
    @State private var proposals: [WikiProposal]?
    @State private var askTopic = false
    @State private var topic = ""

    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private var c3On: Bool {
        _ = (memMaster, writeC3)
        return MemoryWriterSettings.writes(.c3)
    }

    var body: some View {
        List {
            ForEach(proposals ?? []) { p in
                SettingsNavRow(.memoryProposal) {
                    WikiProposalDetailPage(proposalId: p.id, viewModel: viewModel)
                } label: {
                    card(p)
                }
                #if os(macOS)
                // mac 设置窗的 path 只存 SettingsRoute（不带 id），点哪份先记下来
                .simultaneousGesture(TapGesture().onEnded { WikiProposalSelection.shared.proposalId = p.id })
                #endif
                .panelRowBackground()
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .overlay {
            if proposals?.isEmpty == true {
                MemoryEmptyState(title: "还没有整理提案", message: "整理出来的新页、追加、改动先放在这里，批了才写进 wiki")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { actionBar }
        .alert("整理一个主题", isPresented: $askTopic) {
            TextField("比如：电影", text: $topic)
            Button("开始") { startTopic() }
            Button("取消", role: .cancel) { topic = "" }
        } message: {
            Text("搜这个词相关的聊天和碎片，整理成一份提案")
        }
        .task(id: profileId) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in Task { await reload() } }
        .onChange(of: runner.lastFinishedAt) { _, _ in Task { await reload() } }
    }

    // MARK: 顶上操作区

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if runner.isRunning {
                HStack(spacing: 8) {
                    Text(runningText)
                        .font(m.caption)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    ProposalPill(title: "停", color: Theme.danger) { runner.cancel() }
                }
            } else {
                HStack(spacing: 10) {
                    ProposalPill(title: "现在整理", color: c3On ? Theme.textPrimary : Theme.textMuted) {
                        if let p = profileManager?.currentProfile { runner.organizeNow(profile: p) }
                    }
                    .disabled(!c3On)
                    ProposalPill(title: "整理一个主题…", color: c3On ? Theme.textPrimary : Theme.textMuted) {
                        topic = ""
                        askTopic = true
                    }
                    .disabled(!c3On)
                    Spacer(minLength: 0)
                }
                if !c3On {
                    HStack(spacing: 8) {
                        Text("C3 整理在设置里关着")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                        SettingsNavRow(.memoryWriterC3) {
                            MemoryWriterPage(id: .c3)
                        } label: {
                            Text("去设置")
                                .font(m.caption)
                                .foregroundColor(Theme.textPrimary)
                        }
                        .fixedSize()
                        Spacer(minLength: 0)
                    }
                } else if let report = runner.lastReport {
                    Text("上次：" + WikiStore.shown(report.summary, user: profileManager?.currentProfile.userName ?? ""))
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolPageBackground()
    }

    private var runningText: String {
        let head = runner.currentTopic.map { "正在整理：\($0)" + (runner.round > 0 ? "（第 \(runner.round) 轮）" : "") } ?? "正在整理"
        return head + (runner.queued > 0 ? " · 后面排着 \(runner.queued) 次" : "")
    }

    private func startTopic() {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        topic = ""
        guard !t.isEmpty, let p = profileManager?.currentProfile else { return }
        runner.organizeTopic(t, profile: p)
    }

    // MARK: 卡

    private func card(_ p: WikiProposal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(WikiProposalDisplay.summary(p, assistantName: floorAssistantName(profileManager)))
                .font(m.body)
                .foregroundColor(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Text(WikiProposalDisplay.statusText(p))
                    .foregroundColor(p.pendingCount > 0 ? Theme.textSecondary : Theme.textMuted)
                if p.incomplete {
                    Text("· 没整理完")
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .font(m.caption)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func reload() async {
        let pid = profileId
        guard !pid.isEmpty else { return }
        let store = await proposalStore(pid)
        let list = await Task.detached(priority: .userInitiated) { store.list() }.value
        guard pid == profileId else { return }
        proposals = list
    }
}

// MARK: - 详情

struct WikiProposalDetailPage: View {
    let proposalId: String
    let viewModel: ConversationViewModel?

    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var proposal: WikiProposal?
    @State private var loaded = false
    @State private var fragments: [UUID: Memory] = [:]
    /// 「确认已覆盖」对照用：目标页现在的样子
    @State private var coveredPages: [String: WikiPage] = [:]
    /// 方向交出的正文提案 id → 目录那条要显示的状态（只留一句话，不持有正文全文）；没有 = 还有待批，照旧显示 result
    @State private var contentStatus: [String: String] = [:]
    @State private var directionBlocks: [String: String] = [:]
    @State private var legacyHistoryPaths: [String: [String]] = [:]
    @State private var titles: [String: String] = [:]
    @State private var liveMessageTargets: Set<WikiProposalDisplay.MessageTarget> = []
    @State private var log: [MemoryWriteLog.Entry] = []
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var editing: WikiProposal.Item?
    @State private var rejecting: RejectionTarget?
    @State private var withdrawal: WikiProposalReview.WithdrawPlan?
    @State private var confirmWithdrawal = false
    @State private var withdrawalProfileId = ""
    @State private var history: HistoryTarget?
    @State private var window: WindowTarget?
    @State private var preview: PreviewTarget?
    @State private var runner = CatalogRunner.shared
    @State private var runDocument: MemoryWriteLogRunReader.Document?
    /// 推进去看详情和原料的那一项（`WikiProposalItemPage`）；mac 设置窗不用它，走 `SettingsRoute.memoryProposalItem`
    @State private var itemTarget: WikiProposalItemTarget?
    #if os(macOS)
    @Environment(\.settingsRoutePush) private var routePush
    #endif

    private struct WindowTarget: Identifiable {
        let id: String
        let title: String
        let isGone: Bool
    }

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        List {
            if let notice {
                Section {
                    Text(notice)
                        .font(m.caption)
                        .foregroundColor(Theme.textPrimary)
                }
                .panelRowBackground()
            }
            if let error {
                Section {
                    Text(error)
                        .font(m.caption)
                        .foregroundColor(Theme.danger)
                }
                .panelRowBackground()
            }
            if let p = proposal {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(WikiProposalDisplay.summary(p, assistantName: floorAssistantName(profileManager)))
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Text(WikiProposalDisplay.statusText(p) + (p.incomplete ? " · 没整理完" : ""))
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                        if let skipped = p.seedSkipped, !skipped.isEmpty {
                            field("本次跳过的 CC 文件", skipped.joined(separator: "\n"))
                        }
                        if let request = p.request {
                            field("你说的", request.text)
                        }
                        if p.directionRef != nil {
                            Text("这是批过的方向写出来的正文，批了才写进 wiki")
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                        if Self.isSeedOutline(p) {
                            Text("种子目录：批了的项由同一个种子任务接着一页一页写，写好的正文再交你批")
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                        if let revision = p.revision {
                            field("修订", revision)
                        }
                        if let link = p.run {
                            Button("这次的整理记录 ›") { Task { await openRun(link) } }
                                .font(m.caption)
                                .foregroundColor(Theme.textPrimary)
                                .buttonStyle(.borderless)
                        }
                        if p.items.contains(where: { WikiProposalDisplay.status($0, directionBlock: directionBlocks[$0.id]) == .withdrawable }) {
                            Button("撤回本提案已批项…") {
                                prepareWithdrawal(Set(p.items.filter { WikiProposalDisplay.status($0, directionBlock: directionBlocks[$0.id]) == .withdrawable }.map(\.id)))
                            }
                            .disabled(busy)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .panelRowBackground()
                let groups = WikiProposalDisplay.groups(p)
                ForEach(groups) { g in
                    Section {
                        ForEach(g.items) { item in itemRow(item) }
                        ForEach(Array((p.unapplied ?? []).filter { $0.page == g.path }.enumerated()), id: \.offset) { _, u in
                            unappliedRow(u)
                        }
                    } header: {
                        Text(WikiStore.shown(g.path.map { "\(g.title) · \($0.replacingOccurrences(of: "/", with: " › "))" } ?? g.title,
                                             user: profileManager?.currentProfile.userName ?? ""))
                            .textCase(nil)
                    }
                    .panelRowBackground()
                }
                let paths = Set(groups.compactMap(\.path))
                let loose = (p.unapplied ?? []).filter { $0.page.map { !paths.contains($0) } ?? true }
                if !loose.isEmpty {
                    Section {
                        ForEach(Array(loose.enumerated()), id: \.offset) { _, u in unappliedRow(u) }
                    } header: {
                        Text("没收进页的内容").textCase(nil)
                    }
                    .panelRowBackground()
                }
                if p.unreadCount > 0 {
                    Section {
                        HStack(spacing: 8) {
                            Text("没收进页的 \(p.unreadCount) 处只给你看，不会写进 wiki")
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted)
                            Spacer(minLength: 0)
                            ProposalPill(title: "知道了", color: Theme.textSecondary) { acknowledge() }
                        }
                        .disabled(busy)
                    }
                    .panelRowBackground()
                }
                if !log.isEmpty {
                    Section {
                        DisclosureGroup {
                            ForEach(log) { e in
                                Text(e.time.formatted(date: .omitted, time: .shortened) + " " + WikiStore.shown(e.note, user: profileManager?.currentProfile.userName ?? ""))
                                    .font(m.caption)
                                    .foregroundColor(e.ok ? Theme.textSecondary : Theme.danger)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } label: {
                            Text("它搜了什么")
                                .font(m.body)
                                .foregroundColor(Theme.textPrimary)
                        }
                    }
                    .panelRowBackground()
                }
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .overlay {
            if loaded && proposal == nil {
                MemoryEmptyState(title: "这份提案不在了", message: "处理完满 30 天的提案会清掉")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let p = proposal, p.pendingCount > 0 { bottomBar }
        }
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        .memorySubpage("整理提案")
        .sheet(item: $editing) { item in
            WikiProposalEditSheet(proposalId: proposalId, item: item) { updated, savedNotice in
                proposal = updated
                error = nil
                notice = savedNotice
            }
        }
        .sheet(item: $window) { w in
            WindowSummarySheet(conversationId: w.id, profileId: profileId, fallbackTitle: w.title, isGone: w.isGone,
                               onOpen: viewModel == nil ? nil : { open(w.id) })
        }
        .sheet(item: $preview) { WikiPagePreviewSheet(page: $0.page) }
        .sheet(item: $history) { target in
            WikiHistoryView(target: target.value, hasUnsavedEdits: false)
        }
        .navigationDestination(item: $itemTarget) { WikiProposalItemPage(target: $0) }
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
        .sheet(item: $rejecting) { target in
            WikiProposalRejectionSheet(items: target.items, batch: target.batch) { reasons in
                reject(target.batch ? nil : Set(target.items.map(\.id)), reasons: reasons)
            }
        }
        .alert(withdrawal?.blocked.isEmpty == true
            ? (withdrawal?.ordered.allSatisfy(\.authorization) == true ? "撤方向授权？" : "撤回批准？")
            : "撤回被阻挡", isPresented: $confirmWithdrawal) {
            if withdrawal?.blocked.isEmpty == true {
                Button(withdrawal?.ordered.allSatisfy(\.authorization) == true ? "撤授权" : "按此顺序撤回", role: .destructive) { performWithdrawal() }
                Button("取消", role: .cancel) { withdrawal = nil }
            } else {
                Button("查看", role: .cancel) {
                    withdrawal = nil
                }
            }
        } message: {
            Text(withdrawal?.confirmation ?? "")
        }
        .task(id: "\(profileId)/\(proposalId)") { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in
            if !busy { Task { await load() } }
        }
        .onChange(of: runner.lastFinishedAt) { _, _ in
            if !busy { Task { await load() } }
        }
    }

    private struct PreviewTarget: Identifiable {
        let page: WikiPage
        var id: String { page.path }
    }

    private struct HistoryTarget: Identifiable {
        let value: WikiHistoryTarget
        var id: String { value.path }
    }

    private struct RejectionTarget: Identifiable {
        let id = UUID()
        let items: [WikiProposal.Item]
        let batch: Bool
    }

    // MARK: 一条

    /// 能看详情的整块点进去（粟粟 10-24「为什么不是点那个块直接点进去」）：块里的批 / 改 / 驳回 / 看整页 / 跳转都是子 Button，手势优先于整块，点它们不推入；
    /// 落盘中（busy）整块不响应，免得点到禁用的胶囊漏给整块
    @ViewBuilder
    private func itemRow(_ item: WikiProposal.Item) -> some View {
        if WikiProposalItemTarget.hasDetail(item) {
            itemCard(item, detail: true)
                .contentShape(Rectangle())
                .onTapGesture { if !busy { openDetail(item) } }
        } else {
            itemCard(item, detail: false)
        }
    }

    private func itemCard(_ item: WikiProposal.Item, detail: Bool) -> some View {
        let status = WikiProposalDisplay.status(item, directionBlock: directionBlocks[item.id])
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(item.change.kindLabel)
                    .font(m.caption.weight(.medium))
                    .foregroundColor(Theme.textSecondary)
                if let j = item.judgment {
                    Text("新旧判断：\(j.label)")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                Spacer(minLength: 0)
                if detail {
                    Image(systemName: "chevron.right")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            changeBody(item.change)
            if let checks = item.checks, !checks.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("写手交稿时没过的检查" + (item.checksEdited == true ? " · 编辑后未重新检查" : ""))
                        .font(m.caption)
                        .foregroundColor(Theme.danger)
                    Text(checks.map { "· " + $0 }.joined(separator: "\n"))
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            coveredFragments(item)
            cites(item)
            HStack(spacing: 8) {
                if let label = statusLabel(item, status) {
                    Text(label)
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                Spacer(minLength: 0)
                if status.canAct {
                    ProposalPill(title: "批", color: Theme.branchIndicator) { approve([item.id]) }
                    if item.change.isEditable {
                        ProposalPill(title: "改", color: Theme.textSecondary) { editing = item }
                    }
                    ProposalPill(title: "驳回", color: Theme.danger) { prepareRejection([item.id]) }
                } else if status == .withdrawable {
                    ProposalPill(title: "撤回", color: Theme.danger) { prepareWithdrawal([item.id]) }
                } else if status == .legacyApproved {
                    if let path = item.change.targetPath {
                        ProposalPill(title: "查看历史", color: Theme.textSecondary) { openHistory(path) }
                    }
                } else if item.approval?.phase != nil && item.approval?.phase != .committed {
                    ProposalPill(title: "重新核账", color: Theme.textSecondary) { reconcile(item.id) }
                }
            }
            .disabled(busy)
            if item.state == .rejected {
                let reason = item.rejection?.reason ?? ""
                let unrecorded = item.reviewHistory?.last?.origin == .abandonedSeed ? "种子放弃时系统作废" : "未记录"
                Text("驳回原因：" + (reason.isEmpty ? unrecorded : reason)
                    + (item.rejection.map { "（\($0.at.formatted(date: .abbreviated, time: .shortened))）" } ?? ""))
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.change.isEditable {
                    ProposalPill(title: "重新编辑", color: Theme.textSecondary) { editing = item }
                        .disabled(busy)
                }
            }
            if item.state == .pending, item.reviewHistory?.last?.kind == .reopened,
               (item.reviewHistory?.last?.rejection == nil || item.reviewHistory?.contains(where: { $0.kind == .rejected }) != true) {
                Text("当时未记录归属，来源拒绝标记保留")
                    .font(m.caption).foregroundColor(Theme.textMuted)
            }
            if item.state == .approved, item.change.direction != nil, item.approval == nil {
                Text("当时未记录精确撤回凭据；此处只撤方向授权，不撤下游正文")
                    .font(m.caption).foregroundColor(Theme.textMuted)
            }
            if let receipt = item.approval, receipt.phase != .committed {
                ForEach(Array(WikiProposalDisplay.progressLines(receipt).enumerated()), id: \.offset) { _, line in
                    Text(line).font(m.caption).foregroundColor(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if status == .legacyApproved {
                ForEach(Array((legacyHistoryPaths[item.id] ?? []).prefix(5)), id: \.self) { path in
                    Button("查看历史 · \(path)") { openHistory(path) }
                        .font(m.caption).buttonStyle(.borderless).disabled(busy)
                }
                if let count = legacyHistoryPaths[item.id]?.count, count > 5 {
                    Text("还有 \(count - 5) 页").font(m.caption).foregroundColor(Theme.textMuted)
                }
            }
            if let id = item.change.direction?.contentProposalId {
                #if os(macOS)
                Button("正文提案 \(id) ›") { WikiProposalSelection.shared.proposalId = id }
                    .font(m.caption).buttonStyle(.borderless)
                #else
                SettingsNavRow(.memoryProposal) {
                    WikiProposalDetailPage(proposalId: id, viewModel: viewModel)
                } label: {
                    Text("正文提案 \(id) ›").font(m.caption)
                }
                #endif
            }
        }
        .padding(.vertical, 4)
        .opacity(status == .stale ? 0.5 : 1)
    }

    /// 没收进页的内容：原样给她看，不执行
    private func unappliedRow(_ u: WikiProposal.Unapplied) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("没收进页（只展示，不执行）")
                .font(m.caption)
                .foregroundColor(Theme.danger)
            field("原样", u.raw)
            field("原因", u.reason)
        }
        .padding(.vertical, 4)
    }

    private func acknowledge() {
        guard let p = proposal, !busy else { return }
        busy = true
        let pid = profileId
        Task {
            let store = await proposalStore(pid)
            do {
                proposal = try await WikiProposalReview.acknowledgeUnapplied(p.id, store: store)
                error = nil
                NotificationCenter.default.post(name: .memoryDidChange, object: nil)
            } catch {
                self.error = "没记上：\(error.localizedDescription)"
            }
            busy = false
        }
    }

    /// 批了的方向：执行到哪了 / 结果
    func statusLabel(_ item: WikiProposal.Item, _ status: WikiProposalDisplay.ItemStatus) -> String? {
        if case .interruptedApproval = status { return status.label }
        if status == .stale || item.state == .pending, let reason = item.staleReason { return reason }
        guard status == .approved, let d = item.change.direction else { return status.label }
        if let reason = directionBlocks[item.id] { return "已批 · " + reason }
        if let id = d.contentProposalId, let status = contentStatus[id] { return "已批 · " + status }
        if let result = d.result { return "已批 · " + result }
        if d.mode == .seed { return "已批 · 等种子任务写这一页" }
        return d.ranAt == nil ? "已批 · 还没开始写" : "已批 · 正在查原料、写"
    }

    @ViewBuilder
    private func changeBody(_ change: WikiProposal.Change) -> some View {
        switch change {
        case .direction(let d):
            VStack(alignment: .leading, spacing: 4) {
                Text(d.title + (d.kind.map { " · \($0.rawValue)" } ?? ""))
                    .font(m.body.weight(.medium))
                    .foregroundColor(Theme.textPrimary)
                if !d.hook.isEmpty { field("钩子", d.hook) }
                if d.mode == .seed {
                    field("原料", "\((d.sources ?? []).count) 份" + ((d.candidates ?? []).isEmpty ? "" : " + 回扫候选 \(d.candidates?.count ?? 0) 份") + "，点这一块逐份看全文")
                } else {
                    field("为什么", d.reason)
                }
                if !d.clues.isEmpty {
                    field("线索碎片（只看标题）", d.clues.map { id in
                        "· " + (fragments[id].map { CatalogSorter.title(CatalogFragment($0)) } ?? "碎片（已经删了）")
                    }.joined(separator: "\n"))
                }
                field("批了以后", d.modeLabel + "，写好的正文再交你批")
            }
        case .confirmCovered(let path):
            VStack(alignment: .leading, spacing: 4) {
                Text("页上已经写过这些碎片，不改页；批了只把它们标成已整理进这页")
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                if let page = coveredPages[path] {
                    Button("对照这一页现在的样子 ›") { preview = PreviewTarget(page: page) }
                        .font(m.caption)
                        .foregroundColor(Theme.textPrimary)
                        .buttonStyle(.borderless)
                } else {
                    Text("这一页已经不在了")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
        case .newPage(let page):
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title + (page.kind.map { " · \($0.rawValue)" } ?? ""))
                    .font(m.body.weight(.medium))
                    .foregroundColor(Theme.textPrimary)
                field("钩子", page.hook)
                field("触发词", page.triggers.joined(separator: "、"))
                field("现在", page.now)
                if let until = page.validUntil { field(WikiPage.validUntilKey, until) }
                if !page.records.isEmpty { field("记录", page.records.map { "· " + $0 }.joined(separator: "\n")) }
                if !page.links.isEmpty { field("连到", page.links.map(linkText).joined(separator: "\n")) }
                Button("看整页 ›") { preview = PreviewTarget(page: page) }
                    .font(m.caption)
                    .foregroundColor(Theme.textPrimary)
                    .buttonStyle(.borderless)
            }
        case .appendRecords(_, let lines):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text("+ " + line)
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        case .rewriteNow(_, let old, let new, let until):
            VStack(alignment: .leading, spacing: 4) {
                Text(old.isEmpty ? "（原来是空的）" : old)
                    .font(m.body)
                    .strikethrough(!old.isEmpty, color: Theme.textMuted)
                    .foregroundColor(Theme.textMuted)
                Text(new)
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                if let until { field(WikiPage.validUntilKey, until) }
            }
        case .link(_, let link):
            Text(linkText(link))
                .font(m.body)
                .foregroundColor(Theme.textPrimary)
        case .retag(_, let oldHook, let newHook, let oldTriggers, let newTriggers):
            VStack(alignment: .leading, spacing: 4) {
                if oldHook != newHook { field("钩子", "\(oldHook) → \(newHook)") }
                if oldTriggers != newTriggers {
                    field("触发词", "\(oldTriggers.joined(separator: "、")) → \(newTriggers.joined(separator: "、"))")
                }
            }
        case .regroup(let layer, let groups, let moves):
            VStack(alignment: .leading, spacing: 4) {
                field("层", layer)
                if !groups.isEmpty {
                    field("新分组", groups.map { "\(lastSegment($0.path)) — \($0.hook)" }.joined(separator: "\n"))
                }
                if !moves.isEmpty {
                    field("挪动", moves.map { "\($0.from) → \($0.to)" }.joined(separator: "\n"))
                }
            }
        }
    }

    private func field(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
            Text(value.isEmpty ? "（空）" : WikiStore.shown(value, user: profileManager?.currentProfile.userName ?? ""))
                .font(m.body)
                .foregroundColor(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lastSegment(_ path: String) -> String { String(path.split(separator: "/").last ?? "") }

    private func linkText(_ link: WikiPage.Link) -> String {
        "→ 《\(lastSegment(link.target))》 · \(link.relation.rawValue)" + (link.why.isEmpty ? "" : " · \(link.why)")
    }

    // MARK: 详情和原料

    /// mac 设置窗（值驱动 path，页顶 ‹ › 只认 `[SettingsRoute]`）：目录项也进 path（astra 10-23 P2），点哪项先记进 `WikiProposalSelection`；
    /// 别处照旧 destination 推入
    private func openDetail(_ item: WikiProposal.Item) {
        let target = detailTarget(item)
        #if os(macOS)
        if let routePush {
            WikiProposalSelection.shared.item = target
            routePush(.memoryProposalItem)
            return
        }
        #endif
        itemTarget = target
    }

    /// 碎片（方向的线索 / 正文的出处 / 页上已经写过的）在这里从已经取好的库行转成原料带过去
    private func detailTarget(_ item: WikiProposal.Item) -> WikiProposalItemTarget {
        let ids = (item.change.direction?.clues ?? []) + item.fragmentIds + (item.covered ?? [])
        var seen = Set<UUID>()
        let fragmentSources = ids.filter { seen.insert($0).inserted }.map { id in
            let mem = fragments[id]
            return WikiProposalItemTarget.fragment(id: id, title: mem.map { CatalogSorter.title(CatalogFragment($0)) },
                                                   content: mem?.content, quote: mem?.sourceQuote, day: mem?.occurredDay)
        }
        return WikiProposalItemTarget(proposalId: proposalId, item: item, seedTask: proposal?.seedTask, fragments: fragmentSources)
    }

    // MARK: 出处

    /// covered 的碎片（批了一起标已整理进这页，驳回不连带）：只是展示，不算进 fragmentIds
    @ViewBuilder
    private func coveredFragments(_ item: WikiProposal.Item) -> some View {
        if let covered = item.covered, !covered.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("页上已经写过的碎片")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                ForEach(covered, id: \.self) { fid in
                    if let mem = fragments[fid] {
                        let text = "碎片：" + (mem.content.count > 40 ? String(mem.content.prefix(40)) + "…" : mem.content)
                        if viewModel != nil, mem.sourceConversationId != nil {
                            Button { jump(mem) } label: { citeLabel(text + " ›") }
                                .buttonStyle(.borderless)
                        } else {
                            citeLabel(text)
                        }
                    } else {
                        citeLabel("碎片（已经删了）")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cites(_ item: WikiProposal.Item) -> some View {
        if !item.fragmentIds.isEmpty || !item.cites.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(item.fragmentIds, id: \.self) { fid in
                    if let mem = fragments[fid] {
                        let text = "碎片：" + (mem.content.count > 40 ? String(mem.content.prefix(40)) + "…" : mem.content)
                        if viewModel != nil, mem.sourceConversationId != nil {
                            Button { jump(mem) } label: { citeLabel(text + " ›") }
                                .buttonStyle(.borderless)
                        } else {
                            citeLabel(text)
                        }
                    } else {
                        citeLabel("碎片（已经删了）")
                    }
                }
                ForEach(Array(item.cites.enumerated()), id: \.offset) { _, cite in
                    if let target = WikiProposalDisplay.messageTarget(for: cite, currentProfileId: profileId),
                       liveMessageTargets.contains(target), viewModel != nil {
                        Button { jump(target) } label: { citeLabel(citeText(cite) + " ›") }
                            .buttonStyle(.borderless)
                    } else if cite.layer != "原文", let wid = cite.windowId {
                        Button {
                            window = WindowTarget(id: wid, title: titles[wid] ?? "", isGone: titles[wid] == nil)
                        } label: { citeLabel(citeText(cite) + " ›") }
                        .buttonStyle(.borderless)
                    } else {
                        citeLabel(citeText(cite))
                    }
                }
            }
        }
    }

    private func citeLabel(_ text: String) -> some View {
        Text(text)
            .font(m.caption)
            .foregroundColor(Theme.textSecondary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func citeText(_ c: WikiProposal.Cite) -> String {
        let available = WikiProposalDisplay.messageTarget(for: c, currentProfileId: profileId)
            .map { liveMessageTargets.contains($0) } ?? false
        return WikiProposalDisplay.citeText(c, titles: titles, originalAvailable: available)
    }

    /// 同审计台卡上「跳到这条」：有节点跳到那条，没有就打开那个窗口
    private func jump(_ mem: Memory) {
        guard let viewModel, let cid = mem.sourceConversationId else { return }
        let pid = profileId
        let desc = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.id == cid && $0.profileId == pid })
        guard let conv = try? modelContext.fetch(desc).first else { return }
        if let nodeId = mem.sourceNodeId {
            viewModel.navigateToSearchResult(nodeId: nodeId, conversation: conv, context: modelContext)
        } else {
            viewModel.loadConversation(conv, context: modelContext)
            NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
        }
    }

    private func jump(_ target: WikiProposalDisplay.MessageTarget) {
        guard let viewModel else { return }
        if !WikiProposalDisplay.navigateToMessage(target, currentProfileId: profileId,
                                                 container: modelContext.container, viewModel: viewModel) {
            liveMessageTargets.remove(target)
        }
    }

    private func open(_ conversationId: String) {
        guard let viewModel else { return }
        MemoryConversationLink.open(conversationId, profileId: profileId, context: modelContext, viewModel: viewModel)
    }

    // MARK: 底部 / 动作

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { prepareRejection(nil) } label: {
                Text("整批驳回")
                    .font(m.body.weight(.medium))
                    .foregroundColor(Theme.danger)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(Capsule().stroke(Theme.danger, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Button("整批批") { approve(nil) }
                .buttonStyle(MemoryPrimaryButtonStyle(fullWidth: true))
        }
        .disabled(busy)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.mainBg)
    }

    private func prepareWithdrawal(_ ids: Set<String>) {
        guard !busy else { return }
        busy = true
        error = nil
        notice = nil
        let pid = profileId
        Task {
            let store = await proposalStore(pid)
            do {
                let plan = try await WikiProposalReview.withdrawPlan(proposalId, itemIds: ids, store: store,
                    profileId: pid, context: modelContext)
                guard profileId == pid else { busy = false; return }
                withdrawal = plan
                withdrawalProfileId = pid
                confirmWithdrawal = true
            } catch {
                if profileId == pid { self.error = error.localizedDescription }
            }
            busy = false
        }
    }

    private func performWithdrawal() {
        guard let plan = withdrawal, plan.blocked.isEmpty, profileId == withdrawalProfileId, !busy else { return }
        let pid = withdrawalProfileId
        let ids = Set(plan.ordered.map(\.itemId))
        withdrawal = nil
        busy = true
        error = nil
        notice = nil
        Task {
            let store = await proposalStore(pid)
            do {
                let result = try await WikiProposalReview.withdraw(proposalId, itemIds: ids, store: store,
                    profileId: pid, context: modelContext)
                if profileId == pid {
                    await load()
                    if result.succeeded > 0 { notice = result.message }
                    else { error = result.message }
                }
            } catch {
                if profileId == pid { self.error = error.localizedDescription }
            }
            busy = false
        }
    }

    private func reconcile(_ itemId: String) {
        guard !busy else { return }
        busy = true
        let pid = profileId
        Task {
            let store = await proposalStore(pid)
            do {
                try await WikiProposalReview.reconcile(proposalId, itemId: itemId, store: store, profileId: pid, context: modelContext)
                if profileId == pid { error = nil; await load() }
            } catch {
                if profileId == pid { self.error = error.localizedDescription }
            }
            busy = false
        }
    }

    private func openHistory(_ path: String) {
        let pid = profileId
        let user = profileManager?.currentProfile.userName ?? ""
        Task {
            let store = await proposalStore(pid)
            let version = await Task.detached(priority: .userInitiated) { store.wiki.version(of: path) }.value
            guard profileId == pid else { return }
            history = HistoryTarget(value: WikiHistoryTarget(store: store.wiki, path: path, expectedVersion: version,
                shown: { WikiStore.shown($0, user: user) }, onRestored: { _, _ in Task { if profileId == pid { await load() } } }))
        }
    }

    /// `ids` = nil 是整批。批了方向就去执行（这才搜、写；同一条只执行一次）
    private func approve(_ ids: Set<String>?) {
        guard let p = proposal, !busy else { return }
        busy = true
        notice = nil
        let pid = profileId
        Task {
            let store = await proposalStore(pid)
            do {
                let seen = Dictionary(p.items.map { ($0.id, $0.change) }, uniquingKeysWith: { a, _ in a })
                let before = await Task.detached(priority: .userInitiated) { store.load(p.id) }.value ?? p
                let updated = try await WikiProposalReview.approve(p.id, itemIds: ids, seen: seen, store: store, profileId: pid, context: modelContext)
                proposal = updated
                error = nil
                busy = false
                if let profile = profileManager?.currentProfile, profile.id == pid {
                    if Self.isSeedOutline(updated) {
                        if Self.decided(before, updated) { runner.resumeSeed(updated.id, profile: profile) }
                    } else {
                        let waiting = WikiProposalDisplay.unranDirections(updated)
                        if !waiting.isEmpty { runner.runDirections(proposalId: updated.id, itemIds: waiting, profile: profile) }
                    }
                }
            } catch {
                self.error = "没批成：\(error.localizedDescription)"
                busy = false
                await load()
            }
        }
    }

    private func prepareRejection(_ ids: Set<String>?) {
        guard let proposal, !busy else { return }
        let items = proposal.items.filter { $0.state == .pending && ids?.contains($0.id) != false }
        guard !items.isEmpty else { return }
        rejecting = RejectionTarget(items: items, batch: ids == nil)
    }

    private func reject(_ ids: Set<String>?, reasons: [String: String]) {
        guard let p = proposal, !busy else { return }
        busy = true
        notice = nil
        let pid = profileId
        Task {
            let store = await proposalStore(pid)
            do {
                let before = await Task.detached(priority: .userInitiated) { store.load(p.id) }.value ?? p
                let updated = try await WikiProposalReview.reject(p.id, itemIds: ids, reasons: reasons,
                    store: store, profileId: pid, context: modelContext)
                proposal = updated
                error = nil
                busy = false
                if Self.isSeedOutline(updated), Self.decided(before, updated), let profile = profileManager?.currentProfile, profile.id == pid {
                    runner.resumeSeed(updated.id, profile: profile)
                }
                NotificationCenter.default.post(name: .memoryDidChange, object: nil)
            } catch {
                self.error = "没驳回成：\(error.localizedDescription)"
                busy = false
                await load()
            }
        }
    }

    static func isSeedOutline(_ p: WikiProposal) -> Bool {
        p.origin == .seed && p.items.contains { $0.change.direction?.mode == .seed }
    }

    /// 这一下真的新批 / 新驳回了目录项（重复点、别处已经批过的不算），才去续跑种子
    static func decided(_ before: WikiProposal, _ after: WikiProposal) -> Bool {
        let old = Dictionary(before.items.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        return after.items.contains { $0.state != .pending && old[$0.id] == .pending }
    }

    private func openRun(_ link: CatalogRunLink) async {
        let pid = profileId
        switch await MemoryWriteLogRunReader.load(link: link, wiki: WikiStore(profileId: pid)) {
        case .loaded(let document): runDocument = document
        case let other: error = other.message
        }
    }

    private func load() async {
        let pid = profileId, id = proposalId
        guard !pid.isEmpty else { return }
        let store = await proposalStore(pid)
        let (p, all, entries, pages, contents, blocks, histories) = await Task.detached(priority: .userInitiated) {
            () -> (WikiProposal?, [WikiProposal], [MemoryWriteLog.Entry], [String: WikiPage], [String: String], [String: String], [String: [String]]) in
            let p = store.load(id)
            var pages: [String: WikiPage] = [:]
            var contents: [String: String] = [:]
            var blocks: [String: String] = [:]
            var histories: [String: [String]] = [:]
            for item in p?.items ?? [] {
                if case .confirmCovered(let path) = item.change, let page = store.wiki.read(path) { pages[path] = page }
                if let cid = item.change.direction?.contentProposalId, let status = WikiProposalDisplay.contentStatus(store.load(cid)) { contents[cid] = status }
                if let p { blocks[item.id] = await WikiProposalReview.directionBlock(item, proposal: p, store: store) }
                if item.state == .approved, item.approval == nil, case .regroup(_, _, let moves) = item.change {
                    histories[item.id] = moves.flatMap { move in
                        store.wiki.pageExists(move.to) ? [move.to] : store.wiki.pagePaths(under: move.to)
                    }
                }
            }
            guard let p, p.origin == .manual || p.origin == .topic || p.origin == .assistant else { return (p, [], [], pages, contents, blocks, histories) }
            return (p, store.list(), MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)), pages, contents, blocks, histories)
        }.value
        let container = modelContext.container
        let cites = p?.items.flatMap(\.cites) ?? []
        let targets = await Task.detached(priority: .userInitiated) {
            WikiProposalDisplay.liveMessageTargets(for: cites, currentProfileId: pid, source: SwiftDataConversationSource(container: container))
        }.value
        guard pid == profileId else { return }
        proposal = p
        log = p.map { WikiProposalDisplay.searchLog(entries, for: $0, all: all) } ?? []
        coveredPages = pages
        contentStatus = contents
        directionBlocks = blocks
        legacyHistoryPaths = histories
        let ids = Array(Set(p?.items.flatMap { $0.fragmentIds + ($0.covered ?? []) + ($0.change.direction?.clues ?? []) } ?? []))
        if ids.isEmpty {
            fragments = [:]
        } else {
            let rows = (try? modelContext.fetch(FetchDescriptor<Memory>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
            fragments = Dictionary(rows.filter { $0.profileId == pid }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        titles = MemoryAudit.windowTitles(ids: Set(p?.items.flatMap { $0.cites.compactMap(\.windowId) } ?? []), profileId: pid,
                                          source: SwiftDataConversationSource(container: modelContext.container))
        liveMessageTargets = targets
        loaded = true
    }
}

struct WikiRejectionDraft {
    var commonReason = ""
    var overrides: [String: String] = [:]

    var isOverLimit: Bool {
        commonReason.count > WikiProposal.Rejection.reasonLimit
            || overrides.values.contains { $0.count > WikiProposal.Rejection.reasonLimit }
    }

    func reasons(for ids: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.map { id in
            let override = overrides[id] ?? ""
            return (id, override.isEmpty ? commonReason : override)
        })
    }
}

struct WikiProposalRejectionSheet: View {
    let items: [WikiProposal.Item]
    let batch: Bool
    let onConfirm: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var draft = WikiRejectionDraft()

    var body: some View {
        NavigationStack {
            Form {
                Section(batch ? "共用原因" : "驳回原因") {
                    reasonInput($draft.commonReason)
                }
                if batch {
                    Section {
                        DisclosureGroup("逐条覆盖") {
                            Text("留空时使用共用原因")
                                .font(.caption)
                                .foregroundColor(Theme.textMuted)
                            ForEach(items) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(WikiStore.shown(item.change.kindLabel
                                        + (item.change.targetPath.map { " · " + $0 } ?? ""),
                                        user: profileManager?.currentProfile.userName ?? ""))
                                        .foregroundColor(Theme.textPrimary)
                                    reasonInput(Binding(get: { draft.overrides[item.id] ?? "" },
                                                        set: { draft.overrides[item.id] = $0 }))
                                }
                            }
                        }
                    }
                    Section {
                        Text("剩下待批的条目全部驳回；正文条目用到的碎片以后不再自动整理，方向的线索碎片不受影响")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .panelSheetTitle(batch ? "整批驳回？" : "驳回这条？")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("驳回", role: .destructive) {
                        onConfirm(draft.reasons(for: items.map(\.id)))
                        dismiss()
                    }
                    .foregroundColor(Theme.danger)
                    .disabled(draft.isOverLimit)
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 520)
        #endif
    }

    private func reasonInput(_ text: Binding<String>) -> some View {
        let count = text.wrappedValue.count
        return VStack(alignment: .leading, spacing: 6) {
            TextField("驳回原因", text: text, prompt: Text("一句话原因，可不填"), axis: .vertical)
                .labelsHidden()
                .lineLimit(3...8)
            HStack {
                if count > WikiProposal.Rejection.reasonLimit {
                    Text("最多 200 字")
                        .foregroundColor(Theme.danger)
                }
                Spacer(minLength: 0)
                Text("\(count) / 200")
                    .foregroundColor(count > WikiProposal.Rejection.reasonLimit ? Theme.danger : Theme.textMuted)
            }
            .font(.caption)
        }
    }
}

// MARK: - 新开页整页预览

private struct WikiPagePreviewSheet: View {
    let page: WikiPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(WikiProposalDisplay.pageMarkdown(page))
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Theme.mainBg)
            .panelSheetTitle(page.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 560)
        #endif
    }
}

// MARK: - 「改」：就地改文字，存回提案（驳回项保存后回待批）

struct WikiProposalEditSheet: View {
    let proposalId: String
    let item: WikiProposal.Item
    let onSaved: (WikiProposal, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var draft: WikiProposalDraft
    @State private var error: String?
    @State private var saving = false
    @State private var conversionRow: Int?

    init(proposalId: String, item: WikiProposal.Item, onSaved: @escaping (WikiProposal, String?) -> Void) {
        self.proposalId = proposalId
        self.item = item
        self.onSaved = onSaved
        _draft = State(initialValue: WikiProposalDraft(item.change))
    }

    /// 草稿里存落盘写法（{{user}}/…），框里显示、输入的是名字
    private var shownPath: Binding<String> {
        let user = profileManager?.currentProfile.userName ?? ""
        return Binding(get: { WikiStore.shown(draft.path, user: user) }, set: { draft.path = WikiStore.stored($0, user: user) })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        Text(error)
                            .foregroundColor(Theme.danger)
                    }
                }
                if item.state == .rejected {
                    Section("驳回原因") {
                        Text(item.rejection.map { $0.reason.isEmpty ? "未记录" : $0.reason } ?? "未记录")
                        if let rejection = item.rejection {
                            Text(rejection.at.formatted(date: .abbreviated, time: .shortened))
                        }
                        if item.rejection == nil || item.reviewHistory?.last(where: { $0.kind == .rejected })?.rejection != item.rejection {
                            Text("当时未记录归属，来源拒绝标记保留")
                        }
                    }
                    if let withdrawals = item.withdrawals, !withdrawals.isEmpty {
                        Section("撤回记录") {
                            ForEach(Array(withdrawals.enumerated()), id: \.offset) { _, record in
                                Text(record.at.formatted(date: .abbreviated, time: .shortened) + " · " + record.note)
                            }
                        }
                    }
                    if let reason = item.staleReason {
                        Section("页已变") { Text(reason) }
                    }
                }
                fields
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .panelSheetTitle("\(item.state == .rejected ? "重新编辑" : "改")「\(item.change.kindLabel)」")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存") { save() }
                        .foregroundColor(Theme.branchIndicator)
                        .disabled(saving)
                }
            }
        }
        .alert("此行将不再声称原料支持", isPresented: Binding(
            get: { conversionRow != nil }, set: { if !$0 { conversionRow = nil } }
        )) {
            Button("取消", role: .cancel) { conversionRow = nil }
            Button("改为手写事实", role: .destructive) {
                if let index = conversionRow { draft.records[index].converted = true }
                conversionRow = nil
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 520)
        #endif
    }

    @ViewBuilder
    private var fields: some View {
        switch item.change {
        case .direction(let d):
            Section("目标页路径") { TextField("人/… 地点/… 工程/…", text: shownPath, axis: .vertical) }
            if d.mode == .seed {
                Section("类") {
                    Picker("类", selection: $draft.kind) {
                        ForEach(WikiPage.Kind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                    }
                }
            }
            Section("标题") { TextField("标题", text: $draft.title) }
            Section("钩子") { TextField("什么时候会用到", text: $draft.hook, axis: .vertical) }
            if d.mode == .seed {
                Section("原料（一行一份，读过的原料路径）") { TextField("原料", text: $draft.sources, axis: .vertical).lineLimit(2...10) }
            }
        case .confirmCovered:
            EmptyView()
        case .newPage:
            Section("标题") { TextField("显示名", text: $draft.title) }
            Section("钩子") { TextField("什么时候会用到", text: $draft.hook, axis: .vertical) }
            Section("触发词") { TextField("用顿号或逗号隔开", text: $draft.triggers, axis: .vertical) }
            Section("现在") { TextField("现在", text: $draft.now, axis: .vertical).lineLimit(3...12) }
            recordFields("记录")
        case .appendRecords:
            recordFields("追加的记录")
        case .rewriteNow:
            Section("新的「现在」") { TextField("现在", text: $draft.now, axis: .vertical).lineLimit(3...12) }
        case .link:
            Section("为什么连") { TextField("为什么", text: $draft.why, axis: .vertical) }
        case .retag:
            Section("钩子") { TextField("什么时候会用到", text: $draft.hook, axis: .vertical) }
            Section("触发词") { TextField("用顿号或逗号隔开", text: $draft.triggers, axis: .vertical) }
        case .regroup:
            ForEach(draft.groups.indices, id: \.self) { i in
                Section("分组 \(i + 1)") {
                    TextField("分组名", text: $draft.groups[i].name)
                    TextField("钩子", text: $draft.groups[i].hook, axis: .vertical)
                }
            }
        }
    }

    private func recordFields(_ title: String) -> some View {
        Section(title) {
            ForEach(draft.records.indices, id: \.self) { index in
                if !draft.records[index].deleted {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("正文", text: $draft.records[index].body, axis: .vertical)
                            .lineLimit(2...8)
                        Text(draft.records[index].converted || draft.records[index].labels.isEmpty ? "用户编辑" : draft.records[index].labels.joined(separator: "；"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("删除行", role: .destructive) { draft.records[index].deleted = true }
                                .buttonStyle(.borderless)
                            if !draft.records[index].converted, CatalogSources.hasCodeSources(draft.records[index].labels) {
                                Button("改为手写事实") { conversionRow = index }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            Button { draft.records.append(.init()) } label: {
                Text("加一行")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.borderless)
        }
    }

    private func save() {
        let pid = profileManager?.currentProfile.id ?? ""
        guard !pid.isEmpty, !saving else { return }
        saving = true
        let change = draft.apply(to: item.change)
        let conversions = draft.conversions
        let id = proposalId, itemId = item.id, judgment = item.judgment
        Task {
            let store = await proposalStore(pid)
            let result: Result<(WikiProposal, String?), Error>
            do {
                if item.state == .rejected {
                    let reopened = try await WikiProposalReview.reopen(id, itemId: itemId, change: change,
                        baseline: item.change, judgment: judgment, store: store, profileId: pid, context: modelContext, conversions: conversions)
                    result = .success((reopened.proposal, reopened.notice))
                } else if let current = await Task.detached(priority: .userInitiated, operation: { store.load(id) }).value,
                   CatalogSeedDrafts.isSeedProposal(current) {
                    result = .success((try await CatalogSeedDrafts.saveChange(id, itemId: itemId, change: change, baseline: item.change, wiki: store.wiki, conversions: conversions), nil))
                } else {
                    result = .success((try await WikiProposalReview.edit(id, itemId: itemId, change: change, judgment: judgment, store: store, conversions: conversions), nil))
                }
            } catch {
                result = .failure(error)
            }
            saving = false
            switch result {
            case .success(let (p, notice)):
                onSaved(p, notice)
                if item.state == .rejected { NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
                dismiss()
            case .failure(let e):
                error = "没存成：" + e.localizedDescription
            }
        }
    }
}
