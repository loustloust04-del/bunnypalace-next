import MemoryCore
import SwiftUI
import SwiftData

// MARK: - 审计台（plan-memory-audit-desk 第五节）
// 档案一条一张卡：留 / 删 / 改字 / 改类别 / 跳回原消息 / 批量。设置 → 记忆里推入，记忆 app 底栏最右一格（规格 7¼）。
// 不自动合并 / 删 / 标失效，不提示「可能重复」，不审 B4。规则全在 `MemoryAudit`，这里只管摆和存。
// 10-23 起页名「整理台」（plan-memory-audit-home-trial 第二节）：审计台首页的一个台；原第四段「整理提案」挪进 wiki 台（`MemoryWikiPage`）。
// 11-12 v2 原型（docs/prototypes/audit-desk-20261112）：顶上只留导航栏 + 三段，别的收进 ⋯；
// 动作在底部玻璃条；Edit 全屏；列表行尾两个图标钮，点行进 Edit；每屏只有一个实心主钮。
// 11-15（粟粟「为什么记忆看一个条目在记忆-审计台和记忆-记忆是两回事」）：这里就是记忆页那份列表只看 Draft 的一面——
// 行（`MemoryRow`）、详情页（`memoryEntryPage`）、改删钉的存法（`MemoryEntryActions`）、三段上的数和记忆页同一套；
// 第三段 Deleted 就是记忆页底部那个 Deleted（按批分组 + {助手}划掉的，Restore / Delete forever）。

/// 审计台的看法（10-16 astra #8）：状态段、筛选条件。同时间轴 / 窗口总结的 model，记忆 app 父级持有，
/// mac `switch tab` 切格重建页面时不丢；多选不在这里（切格照旧清）
@Observable
final class MemoryAuditViewState {
    var state: MemoryAudit.State = .unreviewed
    /// 审计台首页推进去的那个台（plan-memory-audit-home-trial 第二节）；切楼层退回首页
    var station: AuditStationID?
    var filter = MemoryAudit.Filter()
    /// ⋯ 里的 Old drafts：只看这一版装上之前 C2 写的那批（原 v5 横条）
    var oldOnly = false
    /// 牌堆最上面压住的那张（审计台卡片 plan 2.3）
    var topId: UUID?
    /// 这一轮牌堆里已经 Skip 过掉的（Draft / Archive 里按 Skip 只过不改库，plan 2.1）；换段 / 改筛选 / 切列表就清空，再从头出
    var passed: Set<UUID> = []
    /// 哪几段用牌堆（plan 2.1）：默认只有「没看过」；只记在这里，不落盘
    var stackStates: Set<MemoryAudit.State> = [.unreviewed]
    /// 整理台在牌堆 / 多选里：记忆 app 的底栏据此收起（推进去的页面自己藏不掉根页的底栏；牌堆有自己的动作条，多选有批量条）。
    /// 只在推着整理台（`station == .desk`）时算数：退回首页不用回写，免得藏 / 露底栏来回触发页面出现消失
    var hidesTabBar = false
    /// 牌堆「撤回上一张」（plan 2.3，⧫7）：只记最近一次
    var lastAction: MemoryAudit.Undo?
    /// 牌堆代次（10-17 astra #1）：重置一次 +1，飞着的那一下飞完发现代次变了就作废
    var deckGeneration = 0

    func clear() {
        state = .unreviewed
        station = nil
        filter = MemoryAudit.Filter()
        oldOnly = false
        topId = nil
        passed = []
        stackStates = [.unreviewed]
        lastAction = nil
        deckGeneration += 1
    }

    /// 换段 / 改筛选 / 进出选择 / 切列表 ↔ 牌堆 / 切楼层：清掉这一轮，按新条件直接压住首张——
    /// 首张 id 没变时页面上「首张一变就压住」那条不触发，不在这里压就漏锁（10-17 astra #4）
    func resetDeck(rows: [Memory]) {
        deckGeneration += 1
        passed = []
        lastAction = nil
        topId = rows.first?.id
    }
}

struct MemoryAuditPage: View {
    /// 弹层里给：关弹层的「Done」（多选时藏起来），跳到原消息前也先关
    var onClose: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    /// 拿不到（mac 设置窗是另一个窗口）就不出「跳到这条」
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(\.settingsMetrics) private var m
    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MemoryAudit.bannerDoneKey) private var bannerDone = false

    @State private var all: [Memory] = []
    @State private var titles: [String: String] = [:]
    @State private var loaded = false
    /// 状态段 / 筛选（10-16 astra #8）：记忆 app 底栏里由父级持有（mac 切格会重建这页），别处推进来的自己持有
    var viewState: MemoryAuditViewState? = nil
    @State private var ownViewState = MemoryAuditViewState()
    @State private var showFilter = false
    @State private var selection: Set<UUID> = []
    /// Edit 全屏页开着的那一张
    @State private var editing: MemoryEntryTarget?
    @State private var pendingPurge: Set<UUID>? = nil
    /// {助手}自己记下的、划掉的（Deleted 里和删掉的原子事实一起列，同记忆页底部那个 Deleted）
    @State private var deletedSelf: [SelfMemory] = []
    @State private var pendingSelfPurge: SelfMemory?
    /// 批量删确认框：打开时冻结的楼层 + 目标 id（10-16 astra #6）
    @State private var trashAllSnapshot: MemoryAudit.TrashSnapshot?
    /// 存盘失败的那行红字（10-16 astra #7）
    @State private var saveError: String?
    /// 刚做完、还能撤的那一笔（牌堆的 Undo 钮 / 列表浮条的 Undo 都撤它）
    @State private var lastEntry: MemoryAuditLog.Entry?
    /// 做完浮一行小字（「Deleted 1」）：只是字的几秒就收，列表里带 Undo 的留着
    @State private var toast: MemoryAuditToast?
    @State private var showHistory = false
    /// 牌堆里正在飞走的那张（plan 2.3）
    @State private var flight: MemoryAuditFlight?
    /// 「C2 整理」给还留着的新卡写的那句理由（`FragmentDreamNotes`）：Draft 里拿不准的排最前，卡上显示
    @State private var dreamNotes: [UUID: FragmentDreamNotes.Note] = [:]

    private var ui: MemoryAuditViewState { viewState ?? ownViewState }
    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private var now: Date { Date() }
    /// 「Old drafts」开着时只看那一批，三段的数字也只数那一批
    private var scoped: [Memory] {
        guard ui.oldOnly, let cutoff = MemoryAudit.cutoff() else { return all }
        return all.filter { $0.isFragment && $0.createdAt < cutoff }
    }
    private var rows: [Memory] {
        MemoryAudit.apply(scoped, filter: ui.filter, state: ui.state, now: now,
                          first: ui.state == .unreviewed ? Set(dreamNotes.filter(\.value.isUnsure).keys) : [])
    }
    /// 卡上的 Why：C2 整理给这条下过结论就有（删了的不出）
    private func dreamNote(_ mem: Memory) -> FragmentDreamNotes.Note? {
        mem.supersededAt == nil ? dreamNotes[mem.id] : nil
    }
    /// 这一段用牌堆（plan 2.1）；iOS「Select」里一律列表
    private var showsStack: Bool { ui.stackStates.contains(ui.state) && !isSelecting }
    private var deck: [Memory] { MemoryAudit.deck(rows: rows, all: scoped, state: ui.state, top: ui.topId, passed: ui.passed) }
    private var oldDraftCount: Int {
        guard !bannerDone, let cutoff = MemoryAudit.cutoff() else { return 0 }
        return MemoryAudit.v5BannerCount(all, cutoff: cutoff)
    }
    private var filtered: Bool { ui.oldOnly || ui.filter != MemoryAudit.Filter() }
    /// Deleted 里一起列的{助手}划掉的（筛选只管原子事实：开着筛选时不列，数字也不算）
    private var shownSelfDeleted: [SelfMemory] { filtered ? [] : deletedSelf }
    private var assistantName: String {
        let n = profileManager?.currentProfile.assistantName ?? ""
        return n.isEmpty ? "助手" : n
    }

    var body: some View {
        Group {
            if showsStack {
                stack
            } else {
                list
            }
        }
        .animation(nil, value: showsStack)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        #if os(iOS)
        .toolbar { toolbarItems }
        .navigationBarBackButtonHidden(isSelecting)
        .toolbarColorScheme(MemoryAuditStyle.pageIsDark ? .dark : nil, for: .navigationBar)
        .toolbarVisibility(isSelecting ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { batchBar }
        #else
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty { macSelectionBar }
        }
        #endif
        .memoryEntryPage($editing, onJump: { jumpAction($0) }, onEvent: entryChanged)
        .sheet(isPresented: $showFilter) {
            MemoryAuditFilterSheet(filter: Bindable(ui).filter, windows: windowChoices)
        }
        // 记忆日志（和记忆页 ⋯、设置状态卡 ⓘ 同一本）：AI 写入和她在这里的操作按时间混排，能撤
        .sheet(isPresented: $showHistory) {
            MemoryWriteLogSheet(profileId: profileId) { lastEntry = nil; reload(); resetDeck() }
        }
        .task(id: "\(toast?.id.uuidString ?? "")|\(showsStack)") {
            // 列表里带 Undo 的那条不自己收（和牌堆动作条上的 Undo 一样留到做下一笔 / 撤了）；只是一行字的几秒就收
            guard let shown = toast, !(!showsStack && shown.undoable && lastEntry != nil) else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { toast = nil } }
        }
        // 居中 alert（iOS 26 的 confirmationDialog 会锚到 List 弹成 popover）
        .alert(MemoryDeletePlan.purgeTitle(pendingPurge?.count ?? 0),
               isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
               presenting: pendingPurge) { ids in
            Button("Delete forever", role: .destructive) { purgeConfirmed(ids) }
            Button("Cancel", role: .cancel) { pendingPurge = nil }
        } message: { _ in
            Text("30 天内能在记忆日志里放回来，过了就真没了。")
        }
        .alert("Delete \(trashAllSnapshot?.ids.count ?? 0)?",
               isPresented: Binding(get: { trashAllSnapshot != nil }, set: { if !$0 { trashAllSnapshot = nil } }),
               presenting: trashAllSnapshot) { s in
            Button("Delete", role: .destructive) { trash(snapshot: s) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("可以在 Deleted 里 Restore")
        }
        .onAppear(perform: reload)
        // 离开页面：飞着的那一下作废（10-17 astra #1）
        .onDisappear {
            ui.deckGeneration += 1
            flight = nil
        }
        .onChange(of: ui.state) { _, _ in
            endSelection()
            resetDeck()
        }
        .onChange(of: ui.filter) { _, _ in
            endSelection()
            resetDeck()
        }
        .onChange(of: ui.oldOnly) { _, _ in
            endSelection()
            resetDeck()
        }
        .onChange(of: showsStack || isSelecting, initial: true) { _, hide in ui.hidesTabBar = hide }
        #if os(iOS)
        .onChange(of: isSelecting) { _, _ in resetDeck() }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            all = []
            deletedSelf = []
            titles = [:]
            loaded = false
            lastEntry = nil
            toast = nil
            endSelection()
            resetDeck()
        }
        .onChange(of: profileId) { _, _ in reload() }
    }

    // MARK: - 顶上：三段（+ 筛选开着时一颗「条件 ✕」）

    private var header: some View {
        let counts = MemoryAudit.counts(scoped, filter: ui.filter, now: now)
        return VStack(spacing: 8) {
            if !isSelecting {
                HStack(spacing: 8) {
                    Picker("State", selection: Bindable(ui).state) {
                        Text("Draft \(counts[.unreviewed] ?? 0)").tag(MemoryAudit.State.unreviewed)
                        Text("Archive \(counts[.kept] ?? 0)").tag(MemoryAudit.State.kept)
                        Text("Deleted \((counts[.trashed] ?? 0) + shownSelfDeleted.count)").tag(MemoryAudit.State.trashed)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.large)
                    #if os(macOS)
                    // mac 设置窗 / 右栏没有导航栏：⋯ 放在三段右边
                    moreMenu
                    #endif
                }
                if filtered {
                    Button(action: clearFilter) {
                        HStack(spacing: 6) {
                            Text(filterSummary).lineLimit(1)
                            Image(systemName: "xmark").font(m.secondary.weight(.semibold))
                        }
                        .font(m.secondary.weight(.medium))
                        .foregroundStyle(MemoryAuditStyle.onPage)
                    }
                    .auditGlassButton()
                    .accessibilityHint("清掉筛选")
                }
            }
            if let saveError {
                Text(saveError)
                    .font(m.secondary)
                    .foregroundColor(Theme.danger)
                    .lineLimit(2)
            }
        }
        .environment(\.colorScheme, MemoryAuditStyle.pageScheme)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, isSelecting && saveError == nil ? 0 : 8)
    }

    /// 一行字写当前条件（如「Old drafts · 关系 · 7 天内」）
    private var filterSummary: String {
        var parts: [String] = []
        if ui.oldOnly { parts.append("Old drafts") }
        if let o = MemoryAuditFilterSheet.originLabel(ui.filter.origin) { parts.append(o) }
        if let c = ui.filter.category { parts.append(MemoryCardView.categoryLabels[c] ?? c) }
        if let d = MemoryAuditFilterSheet.dateLabel(ui.filter.dateRange) { parts.append(d) }
        if let cid = ui.filter.conversationId { parts.append("《\(titles[cid] ?? "窗口")》") }
        return parts.joined(separator: " · ")
    }

    private func clearFilter() {
        ui.oldOnly = false
        ui.filter = MemoryAudit.Filter()
    }

    /// 筛选 sheet 里的窗口：当前结果（除窗口以外的条件）里出现过的，按条数多→少
    private var windowChoices: [(id: String, title: String, count: Int)] {
        var f = ui.filter
        f.conversationId = nil
        let base = MemoryAudit.apply(scoped, filter: f, state: ui.state, now: now)
        return MemoryAudit.windowCounts(base).map { ($0.id, titles[$0.id] ?? "已删的窗口", $0.count) }
    }

    private func windowTitle(_ mem: Memory) -> String? { mem.sourceConversationId.flatMap { titles[$0] } }

    private func jumpAction(_ mem: Memory) -> (() -> Void)? {
        viewModel != nil && mem.sourceConversationId != nil ? { jump(mem) } : nil
    }

    // MARK: - 列表

    private var list: some View {
        let rows = rows
        return List(selection: $selection) {
            if ui.state == .trashed {
                deletedSections(rows)
            } else {
                ForEach(rows, id: \.id) { mem in
                    row(mem)
                        .tag(mem.id)
                        .panelRowBackground(rowBackground(mem.id))
                }
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 4, for: .scrollContent)
        // 点行进 Edit（Deleted 里不进）；右键 / 长按同行尾那组动作。不挂左右划（和翻页打架）
        .contextMenu(forSelectionType: UUID.self) { ids in
            actions(self.rows.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            guard ids.count == 1, let mem = self.rows.first(where: { ids.contains($0.id) }), mem.supersededAt == nil else { return }
            editing = .existing(mem)
        }
        .overlay {
            if loaded && rows.isEmpty && (ui.state != .trashed || shownSelfDeleted.isEmpty) { emptyState }
        }
        .overlay(alignment: .bottom) { toastView.padding(.bottom, 10) }
        // {助手}划掉的只在列表的 Deleted 里出：彻底删的确认挂在列表上
        .alert(MemoryDeletePlan.purgeTitle(1),
               isPresented: Binding(get: { pendingSelfPurge != nil }, set: { if !$0 { pendingSelfPurge = nil } }),
               presenting: pendingSelfPurge) { s in
            Button("Delete forever", role: .destructive) { purgeSelf(s) }
            Button("Cancel", role: .cancel) { pendingSelfPurge = nil }
        } message: { _ in
            Text("删掉之后找不回来，\(assistantName)也不会再想起它。")
        }
    }

    /// 一行 = 记忆页同一个行（`MemoryRow`：「说的是谁 · 正文」+ Draft 牌子 + 日期），行尾两个 44pt 图标钮
    private func row(_ mem: Memory) -> some View {
        HStack(spacing: 4) {
            MemoryRow(item: MemoryRowItem(mem)) { actions([mem]) }
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isSelecting { rowButtons(mem) }
        }
    }

    /// Deleted（= 记忆页底部那个 Deleted）：一起删掉的按批一组（带 Restore 整批），零散的和{助手}划掉的并一组，新→旧
    @ViewBuilder
    private func deletedSections(_ rows: [Memory]) -> some View {
        let grouped = MemoryRevival.trash(archive: rows, assistant: shownSelfDeleted)
        ForEach(grouped.batches) { batch in
            Section("\(MemoryDateText.short(batch.start))一起删掉的 · \(batch.memories.count)") {
                ForEach(batch.memories, id: \.id) { mem in
                    row(mem)
                        .tag(mem.id)
                        .panelRowBackground(rowBackground(mem.id))
                }
                if !isSelecting {
                    Button("Restore \(batch.memories.count)") { restore(batch.memories) }
                        .font(m.body.weight(.medium))
                        .foregroundColor(MemoryAuditStyle.onPage)
                        .buttonStyle(.plain)
                        .panelRowBackground()
                }
            }
        }
        if !grouped.scattered.isEmpty {
            Section("你删的、\(assistantName)划掉的 · \(grouped.scattered.count)") {
                ForEach(grouped.scattered) { item in
                    switch item.id {
                    case .archive(let id):
                        if let mem = rows.first(where: { $0.id == id }) {
                            row(mem)
                                .tag(mem.id)
                                .panelRowBackground(rowBackground(mem.id))
                        }
                    case .assistant(let slug):
                        if let s = deletedSelf.first(where: { $0.slug == slug }) { selfRow(s, item: item) }
                    }
                }
            }
        }
    }

    /// {助手}划掉的一条：同一个行，行尾 Restore；多选不选它（批量只管原子事实）
    private func selfRow(_ s: SelfMemory, item: MemoryRowItem) -> some View {
        HStack(spacing: 4) {
            MemoryRow(item: item) { selfActions(s) }
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isSelecting {
                rowIcon("arrow.uturn.backward", label: "Restore", positive: true) { restoreSelf(s) }
            }
        }
        .contextMenu { selfActions(s) }
        .selectionDisabled()
        .panelRowBackground()
    }

    @ViewBuilder
    private func selfActions(_ s: SelfMemory) -> some View {
        Button { restoreSelf(s) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
        Button(role: .destructive) { pendingSelfPurge = s } label: { Label("Delete forever", systemImage: "trash") }
    }

    @ViewBuilder
    private func rowButtons(_ mem: Memory) -> some View {
        switch MemoryAudit.state(of: mem) {
        case .unreviewed:
            rowIcon("trash", label: "Delete", positive: false) { trash([mem]) }
            rowIcon("checkmark", label: "Approve", positive: true) { keep([mem]) }
        case .kept:
            rowIcon("trash", label: "Delete", positive: false) { trash([mem]) }
        case .trashed:
            rowIcon("arrow.uturn.backward", label: "Restore", positive: true) { restore([mem]) }
        }
    }

    private func rowIcon(_ symbol: String, label: String, positive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(m.body.weight(positive ? .bold : .regular))
                .foregroundColor(positive ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 44, height: 44)
                .background(positive ? MemoryAuditStyle.positiveTint : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    // MARK: - 牌堆（plan 2.1 / 2.3）

    private var stack: some View {
        let deck = deck
        // ZStack 不用 Group：还没读完时里面是空的，Group 空了外面挂的 frame / onAppear 全都跟着没了（页面永远读不出来）
        return ZStack {
            if deck.isEmpty {
                if loaded { stackEmpty }
            } else {
                MemoryAuditStack(deck: deck, flight: flight) { mem in
                    MemoryAuditDeckCard(memory: mem, windowTitle: windowTitle(mem), onJump: jumpAction(mem), dreamNote: dreamNote(mem))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(top: deck.first) }
        // 最上面那张一露面就压住（新写进来的排它后面）；它离开这一段 / 按了留删后换下一张
        .onChange(of: deck.first?.id, initial: true) { _, id in
            if ui.topId != id { ui.topId = id }
        }
    }

    /// 底部玻璃动作条：Undo · Delete（红图标）· Edit ·（Draft 里多一颗「Skip →」）· 主钮（Approve / Skip / Restore，唯一实心）；做完上方浮一行小字。
    /// 最左下角是 Undo 不是 Delete（11-15 小样：那个位置是别的页底栏「记忆」tab，按错的代价要是 Undo）。
    /// Draft 里三颗图标钮收窄一点给主钮让地方；主钮放不下「图标 + 字」就只留字，再放不下只留图标
    private func actionBar(top: Memory?) -> some View {
        let trashed = ui.state == .trashed
        let draft = ui.state == .unreviewed
        let busy = top == nil || flight != nil
        return HStack(spacing: 8) {
            barIcon("arrow.uturn.backward", label: "Undo", color: MemoryAuditStyle.onPage, slim: draft, action: undoTapped)
                .disabled(!canUndo || flight != nil)
            barIcon("trash", label: trashed ? "Delete forever" : "Delete", color: Theme.danger, slim: draft) {
                if let top { deckLeft(top) }
            }
            .disabled(busy)
            barIcon("pencil", label: "Edit", color: MemoryAuditStyle.onPage, slim: draft) { editing = top.map(MemoryEntryTarget.existing) }
                .disabled(busy || trashed)
            if draft {
                // 原样留在 Draft、不算 Approve，只是这一轮先过（同 Archive 的 Skip）
                Button {
                    if let top { flyAway(top.id, .pass, toRight: true) }
                } label: {
                    Text("Skip →")
                        .font(m.body.weight(.medium))
                        .foregroundStyle(MemoryAuditStyle.onPage)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minHeight: 26)
                }
                .auditGlassButton()
                .disabled(busy)
                .accessibilityLabel("Skip")
            }
            Button {
                if let top { deckRight(top) }
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label(deckRightTitle, systemImage: deckRightIcon)
                        .labelStyle(.titleAndIcon)
                    Text(deckRightTitle)
                    Image(systemName: deckRightIcon)
                }
                .font(m.body.weight(.semibold))
                .foregroundStyle(MemoryAuditStyle.onAccent)
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .auditGlassButton(prominent: true)
            .tint(Theme.branchIndicator)
            .disabled(busy)
            .accessibilityLabel(deckRightTitle)
        }
        .controlSize(.large)
        .environment(\.colorScheme, MemoryAuditStyle.pageScheme)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .overlay(alignment: .top) {
            toastView.alignmentGuide(.top) { $0[.bottom] + 2 }
        }
    }

    private func barIcon(_ symbol: String, label: String, color: Color, slim: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(m.sectionHeader.weight(.medium))
                .foregroundStyle(color)
                .frame(width: slim ? 12 : 24, height: 26)
        }
        .auditGlassButton()
        .accessibilityLabel(label)
    }

    private var deckRightTitle: String {
        switch ui.state {
        case .unreviewed: return "Approve"
        case .kept: return "Skip"
        case .trashed: return "Restore"
        }
    }

    private var deckRightIcon: String {
        switch ui.state {
        case .unreviewed: return "checkmark"
        case .kept: return "arrow.right"
        case .trashed: return "arrow.uturn.backward"
        }
    }

    private func deckLeft(_ mem: Memory) {
        switch ui.state {
        case .unreviewed, .kept: flyAway(mem.id, .trash, toRight: false)
        case .trashed: pendingPurge = [mem.id]
        }
    }

    private func deckRight(_ mem: Memory) {
        switch ui.state {
        case .unreviewed: flyAway(mem.id, .keep, toRight: true)
        // Archive 里主钮是 Skip：不改库，只是这张过了（plan 2.1）
        case .kept: flyAway(mem.id, .pass, toRight: true)
        case .trashed: flyAway(mem.id, .restore, toRight: true)
        }
    }

    /// 先飞走（本地状态驱动），飞完再复核 + 动数据 + 存盘。按下时记楼层 / 牌堆代次 / 目标（10-17 astra #1）：
    /// 飞的时候换了段 / 改了筛选 / 切了列表 / 切了楼层 / 离开了页面，代次就变了，这一下作废（flight 已由重置那边清掉）
    private func flyAway(_ id: UUID, _ kind: MemoryAudit.DeckAction.Kind, toRight: Bool) {
        guard flight == nil else { return }
        let action = MemoryAudit.DeckAction(profileId: profileId, generation: ui.deckGeneration, id: id, kind: kind)
        let out: Animation = reduceMotion ? .easeOut(duration: 0.15) : .easeIn(duration: 0.28)
        withAnimation(out) {
            flight = MemoryAuditFlight(id: id, toRight: toRight)
        } completion: {
            guard action.generation == ui.deckGeneration else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35)) {
                commit(action)
                flight = nil
            }
        }
    }

    /// 飞完提交：按 id 重新查目标，楼层 / 代次 / 还在不在那一边对不上就整个作废（不动库、不记过掉 / 撤回、不动压住的）。
    /// 存不成：字段已放回原值，这张回到最上面，撤回记录不动（重试时撤回基线还是原来的，10-17 astra #3）
    private func commit(_ a: MemoryAudit.DeckAction) {
        let target = fetchMemory(a.id, profileId: a.profileId)
        guard MemoryAudit.canCommit(a, profileId: profileId, generation: ui.deckGeneration, target: target),
              let mem = target else { return }
        switch a.kind {
        case .pass:
            ui.passed.insert(mem.id)
            ui.topId = nil
            ui.lastAction = MemoryAudit.Undo(id: mem.id, kind: .passed)
            showToast("Skipped 1")
        case .purge:
            // 彻底删撤不回：清掉「撤回上一张」
            ui.lastAction = nil
            ui.topId = purge([mem.id]) ? nil : mem.id
        case .keep, .trash, .restore:
            let before = MemoryAudit.Fields(mem)
            let ok: Bool
            let kind: MemoryAudit.Undo.Kind
            switch a.kind {
            case .keep:
                ok = keep([mem])
                kind = .kept
            case .trash:
                ok = trash([mem])
                kind = .trashed
            default:
                ok = restore([mem])
                kind = .restored
            }
            guard ok else {
                ui.topId = mem.id
                return
            }
            ui.topId = nil
            ui.lastAction = MemoryAudit.Undo(id: mem.id, kind: kind, before: before, after: MemoryAudit.Fields(mem))
        }
    }

    /// 按 id 重新查一条（同楼层）
    private func fetchMemory(_ id: UUID, profileId pid: String) -> Memory? {
        var desc = FetchDescriptor<Memory>(predicate: #Predicate<Memory> { $0.id == id && $0.profileId == pid })
        desc.fetchLimit = 1
        return try? modelContext.fetch(desc).first
    }

    /// 彻底删确认后：牌堆最上面那张先往左飞再删；列表里照旧直接删
    private func purgeConfirmed(_ ids: Set<UUID>) {
        if showsStack, ids.count == 1, let id = ids.first, id == ui.topId {
            pendingPurge = nil
            flyAway(id, .purge, toRight: false)
        } else {
            purge(ids)
        }
    }

    private func resetDeck() {
        flight = nil
        ui.resetDeck(rows: rows)
    }

    /// 牌堆空了：筛出来为零给「清掉筛选」；剩下的都 Skip 过了 = 一叠过完一遍；其余同列表的空状态
    @ViewBuilder
    private var stackEmpty: some View {
        if filtered {
            MemoryEmptyState(title: "这些条件下没有\(segmentNoun)", message: "换个条件，或者把筛选清掉") {
                Button("Clear filter", action: clearFilter)
                    .font(m.body.weight(.medium))
                    .foregroundColor(MemoryAuditStyle.onPage)
                    .buttonStyle(.plain)
            }
        } else if !ui.passed.isEmpty {
            MemoryEmptyState(title: "这一叠看完了", message: "换个段，或者在 ⋯ 里换成 List")
        } else {
            emptyState
        }
    }

    private var segmentNoun: String {
        switch ui.state {
        case .unreviewed: return "Draft 里的"
        case .kept: return "Archive 里的"
        case .trashed: return "删掉的"
        }
    }

    /// 列表在「Select」里（iOS editMode）；mac 原生多选没有这个模式
    private var isSelecting: Bool {
        #if os(iOS)
        editMode?.wrappedValue.isEditing == true
        #else
        false
        #endif
    }

    /// 右键 / 长按：同行尾那组动作
    @ViewBuilder
    private func actions(_ ms: [Memory]) -> some View {
        let live = ms.filter { $0.supersededAt == nil }
        let dead = ms.filter { $0.supersededAt != nil }
        if live.contains(where: { $0.reviewedAt == nil }) {
            Button { keep(live) } label: { Label("Approve", systemImage: "checkmark") }
        }
        if ms.count == 1, let mem = ms.first, mem.supersededAt == nil {
            Button { editing = .existing(mem) } label: { Label("Edit", systemImage: "pencil") }
            if viewModel != nil, mem.sourceConversationId != nil {
                Button { jump(mem) } label: { Label("跳到这条", systemImage: "arrow.right.circle") }
            }
        }
        if !live.isEmpty {
            Button(role: .destructive) { trash(live) } label: { Label("Delete", systemImage: "trash") }
        }
        if !dead.isEmpty {
            Button { restore(dead) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { pendingPurge = Set(dead.map(\.id)) } label: { Label("Delete forever", systemImage: "trash") }
        }
    }

    private func rowBackground(_ id: UUID) -> Color {
        #if os(macOS)
        selection.contains(id) ? Theme.accent : Theme.mainBg
        #else
        Theme.mainBg
        #endif
    }

    private var emptyState: some View {
        switch ui.state {
        case .unreviewed: return MemoryEmptyState(title: "Draft 都过完了", message: "新记下的会先到这里")
        case .kept: return MemoryEmptyState(title: "Archive 还是空的", message: "在 Draft 里点 Approve，就会到这里")
        case .trashed: return MemoryEmptyState(title: "没有删掉的", message: "Delete 的会先放在这里，可以 Restore")
        }
    }

    // MARK: - 浮条

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            // 列表里带 Undo（整条就是钮）；牌堆里动作条上有 Undo，这里只是一行字
            MemoryToastView(text: toast.text, onUndo: !showsStack && toast.undoable && lastEntry != nil ? undoTapped : nil)
        }
    }

    private func showToast(_ text: String, undoable: Bool = false) {
        withAnimation(.easeOut(duration: 0.2)) { toast = MemoryAuditToast(text: text, undoable: undoable) }
    }

    // MARK: - Edit

    /// 详情页存了 / 删了 / 钉了（存盘和记一笔在页里走 `MemoryEntryActions`）：浮「Saved · Approved 1 · Undo」，这一笔就是 Undo 撤的那一笔
    private func entryChanged(_ e: MemoryEntryEvent) {
        // 牌堆里这张原来被压在最上面：Draft 里改完算 Approve、删了也走，放它走
        if ui.topId == e.card, e.kind == .deleted || (e.kind == .saved && ui.state == .unreviewed) { ui.topId = nil }
        ui.lastAction = nil
        lastEntry = e.outcome.undoable
        saveError = nil
        showToast(e.text, undoable: lastEntry != nil)
    }

    // MARK: - 多选 / 工具栏

    private var selected: [Memory] { rows.filter { selection.contains($0.id) } }

    #if os(iOS)
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                selectAllButton.foregroundStyle(MemoryAuditStyle.onPage)
            }
            ToolbarItem(placement: .principal) {
                Text(selection.isEmpty ? "Select cards" : "\(selection.count) selected")
                    .font(m.sectionHeader)
                    .foregroundStyle(MemoryAuditStyle.onPage)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { endSelection() }
                    .foregroundStyle(MemoryAuditStyle.onPage)
            }
        } else {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                        .foregroundStyle(MemoryAuditStyle.onPage)
                }
            }
            ToolbarItem(placement: .principal) {
                Text("整理台")
                    .font(m.sectionHeader)
                    .foregroundStyle(MemoryAuditStyle.onPage)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Select") {
                    withAnimation { editMode?.wrappedValue = .active }
                }
                .foregroundStyle(MemoryAuditStyle.onPage)
                moreMenu
            }
        }
    }

    /// 多选时的批量条：自己画（系统 bottomBar 在页签里只画图标、看不出是什么）。只有一颗实心钮
    @ViewBuilder
    private var batchBar: some View {
        if isSelecting {
            let ms = selected
            HStack(spacing: 8) {
                switch ui.state {
                case .unreviewed:
                    batchButton("Approve \(ms.count)", icon: "checkmark", color: MemoryAuditStyle.onPage, prominent: false) { keep(ms) }
                    batchButton("Delete \(ms.count)", icon: "trash", color: MemoryAuditStyle.onAccent, prominent: true) { trash(ms) }
                case .kept:
                    batchButton("Delete \(ms.count)", icon: "trash", color: MemoryAuditStyle.onAccent, prominent: true) { trash(ms) }
                case .trashed:
                    batchButton("Delete forever \(ms.count)", icon: nil, color: Theme.danger, prominent: false) { pendingPurge = Set(ms.map(\.id)) }
                    batchButton("Restore \(ms.count)", icon: "arrow.uturn.backward", color: MemoryAuditStyle.onAccent, prominent: true) { restore(ms) }
                }
            }
            .disabled(ms.isEmpty)
            .controlSize(.large)
            .environment(\.colorScheme, MemoryAuditStyle.pageScheme)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func batchButton(_ title: String, icon: String?, color: Color, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(m.body.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .auditGlassButton(prominent: prominent)
        .tint(prominent ? (ui.state == .trashed ? Theme.branchIndicator : Theme.danger) : nil)
    }
    #else
    private var macSelectionBar: some View {
        HStack(spacing: 14) {
            batchButtons
            selectAllButton
            Button { selection = [] } label: { Image(systemName: "xmark.circle") }
                .help("Cancel")
        }
        .font(.system(size: 13))
        .foregroundColor(Theme.textSecondary)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .toolPageBackground()
    }

    /// mac 底栏：「Approve N」「Delete N」；Deleted 里是「Restore N」「Delete forever N」
    @ViewBuilder
    private var batchButtons: some View {
        let ms = selected
        if ui.state == .trashed {
            Button { restore(ms) } label: { Label("Restore \(ms.count)", systemImage: "arrow.uturn.backward") }
                .disabled(ms.isEmpty)
            Spacer()
            Button(role: .destructive) { pendingPurge = Set(ms.map(\.id)) } label: { Label("Delete forever \(ms.count)", systemImage: "trash") }
                .disabled(ms.isEmpty)
        } else {
            if ui.state == .unreviewed {
                Button { keep(ms) } label: { Label("Approve \(ms.count)", systemImage: "checkmark") }
                    .disabled(ms.isEmpty)
            }
            Spacer()
            Button(role: .destructive) { trash(ms) } label: { Label("Delete \(ms.count)", systemImage: "trash") }
                .disabled(ms.isEmpty)
        }
    }
    #endif

    /// 选中现在筛出来的全部；已经全选了就变成取消
    private var selectAllButton: some View {
        let all = Set(rows.map(\.id))
        let isAll = !all.isEmpty && selection.isSuperset(of: all)
        return Button(isAll ? "Deselect all" : "Select all") { selection = isAll ? [] : all }
            .disabled(all.isEmpty)
    }

    /// ⋯：Stack / List、Filter、Old drafts、记忆日志、Delete all（原来顶上的说明句 / 切换钮 / 筛选行 / v5 横条都收在这里）
    private var moreMenu: some View {
        Menu {
            Picker("Layout", selection: Binding(get: { showsStack }, set: setStack)) {
                Label("Stack", systemImage: "rectangle.stack").tag(true)
                Label("List", systemImage: "list.bullet").tag(false)
            }
            .pickerStyle(.inline)
            Section {
                Button { showFilter = true } label: { Label("Filter", systemImage: "line.3.horizontal.decrease") }
                let old = oldDraftCount
                if old > 0 {
                    Button { ui.state = .unreviewed; ui.oldOnly = true } label: {
                        Label("Old drafts · \(old)", systemImage: "shippingbox")
                    }
                }
                Button { showHistory = true } label: { Label("记忆日志", systemImage: "clock") }
            }
            Section {
                let n = rows.count
                if ui.state == .trashed {
                    Button(role: .destructive) { pendingPurge = Set(rows.map(\.id)) } label: {
                        Label("Delete forever all · \(n)", systemImage: "trash")
                    }
                    .disabled(n == 0)
                } else {
                    Button(role: .destructive) { trashAllSnapshot = MemoryAudit.snapshot(rows, profileId: profileId) } label: {
                        Label("Delete all · \(n)", systemImage: "trash")
                    }
                    .disabled(n == 0)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(MemoryAuditStyle.onPage)
                .accessibilityLabel("More")
        }
        .menuIndicator(.hidden)
    }

    private func setStack(_ on: Bool) {
        if on { ui.stackStates.insert(ui.state) } else { ui.stackStates.remove(ui.state) }
        endSelection()
        resetDeck()
    }

    // MARK: - 动作（规则在 MemoryAudit，这里存盘 + 通知）

    @discardableResult
    private func keep(_ ms: [Memory]) -> Bool {
        persist(ms) { MemoryAudit.keep(ms) }
    }

    /// 单张、多选都走这里：把眼前列着的全选了再删才算整批（记进那一笔，「C2 整理」认「她逐条删过的」时看）
    @discardableResult
    private func trash(_ ms: [Memory]) -> Bool {
        persist(ms, bulk: MemoryEntryActions.isBulk(picked: ms.count, shown: rows.count)) { MemoryAudit.trash(ms) }
    }

    @discardableResult
    private func restore(_ ms: [Memory]) -> Bool {
        persist(ms) { MemoryAudit.restore(ms) }
    }

    /// 改库 + 存盘 + 记一笔，全在 `MemoryEntryActions.commit`（和记忆页同一处）；存不成那几条放回原样、顶上红字
    @discardableResult
    private func persist(_ ms: [Memory], bulk: Bool = false, _ change: () -> Void) -> Bool {
        let out = MemoryEntryActions.commit(ms, profileId: profileId, context: modelContext, bulk: bulk, change)
        if let e = out.error {
            saveError = e
            return false
        }
        saveError = nil
        endSelection()
        record(out)
        return true
    }

    /// 记了一笔就是最新的一笔：牌堆的「撤回上一张」让给它（牌堆动作自己会在后面重新记上）；记不进文件的只是撤不回
    private func record(_ out: MemoryEntryActions.Outcome) {
        guard let entry = out.entry else { return }
        ui.lastAction = nil
        lastEntry = out.undoable
        showToast(MemoryEntryActions.toastText(entry), undoable: lastEntry != nil)
    }

    /// 牌堆 Undo 钮能不能点：刚过掉一张 / 有能撤的一笔 / 记不进文件时牌堆自己的那一下
    private var canUndo: Bool {
        if lastEntry != nil { return true }
        guard let u = ui.lastAction else { return false }
        return u.kind == .passed || MemoryAudit.canUndo(u, in: all)
    }

    /// Undo：过掉的放回来；其余撤最近那一笔（走记录，记忆日志里留一笔 Undo）；记录写不进时退回牌堆自己的撤回
    private func undoTapped() {
        if let u = ui.lastAction, u.kind == .passed {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35)) {
                ui.passed.remove(u.id)
                ui.lastAction = nil
                ui.topId = u.id
            }
            showToast("Undone")
            return
        }
        if let entry = lastEntry {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35)) { undo(entry) }
            return
        }
        undoLast()
    }

    /// 撤回（记录写不进文件时的退路）：那张回到最上面并压住；存不成顶上红字、字段放回撤回前、撤回记录留着能再试
    private func undoLast() {
        guard let u = ui.lastAction, MemoryAudit.canUndo(u, in: all),
              let mem = all.first(where: { $0.id == u.id }) else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35)) {
            guard persist([mem], { MemoryAudit.undo(u, in: [mem]) }) else { return }
            lastEntry = nil
            ui.topId = u.id
        }
        showToast("Undone 1")
    }

    private func undo(_ entry: MemoryAuditLog.Entry) {
        let result = MemoryEntryActions.undo(entry, profileId: profileId, context: modelContext)
        if let e = result.error {
            saveError = e
            return
        }
        saveError = nil
        endSelection()
        lastEntry = nil
        ui.lastAction = nil
        reload()
        // 撤的是一张：它回到牌堆最上面（还在这一段的话）；多张就按新条件重排
        if entry.items.count == 1, let id = entry.items.first?.card {
            flight = nil
            ui.topId = id
        } else {
            resetDeck()
        }
        showToast(result.text)
    }

    @discardableResult
    private func purge(_ ids: Set<UUID>) -> Bool {
        pendingPurge = nil
        // 彻底删之前把整张卡留进记录，30 天内能在记忆日志里放回来
        let doomed = all.filter { ids.contains($0.id) && $0.supersededAt != nil }
            .map { (card: $0.id, before: MemoryAuditLog.CardState($0), after: MemoryAuditLog.CardState?.none, full: Optional(MemoryAuditLog.FullCard($0))) }
        MemoryAudit.purge(ids: ids, profileId: profileId, context: modelContext)
        guard didChange() else { return false }
        let (entry, logged) = MemoryEntryActions.log(doomed, profileId: profileId)
        record(MemoryEntryActions.Outcome(entry: entry, logged: logged))
        return true
    }

    // MARK: - {助手}划掉的（Deleted 里一起列；不进记忆日志，同原来的「已删除」）

    private func restoreSelf(_ s: SelfMemory) {
        var revived = s
        revived.superseded = nil
        try? SelfMemoryStore.save(revived, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId), checkPath: AppPaths.checked)
        reloadSelf()
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }

    private func purgeSelf(_ s: SelfMemory) {
        pendingSelfPurge = nil
        try? SelfMemoryStore.delete(slug: s.slug, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId), checkPath: AppPaths.checked)
        reloadSelf()
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }

    private func reloadSelf() {
        let pid = profileId
        Task {
            let list = await Task.detached {
                SelfMemoryStore.list(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), checkPath: AppPaths.checked)
            }.value
            guard pid == profileId else { return }
            deletedSelf = list.filter { !$0.isActive }
        }
    }

    /// 批量删按确认框打开时的快照执行（10-16 astra #6）：楼层换了不动；只删快照里还活着的。返回存成没有
    @discardableResult
    private func trash(snapshot: MemoryAudit.TrashSnapshot) -> Bool {
        guard snapshot.profileId == profileId else { return false }
        let fresh = SwiftDataMemoryStore().listAll(profileId: snapshot.profileId, context: modelContext)
        let targets = MemoryAudit.trashTargets(snapshot, in: fresh)
        return persist(targets, bulk: true) { MemoryAudit.trash(targets) }
    }

    /// 存盘成功才清选择、发通知（10-16 astra #7）；存不成顶上一行红字，选择留着。返回存成没有
    @discardableResult
    private func didChange() -> Bool {
        do {
            try modelContext.save()
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
            return false
        }
        saveError = nil
        endSelection()
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        return true
    }

    private func endSelection() {
        selection = []
        #if os(iOS)
        editMode?.wrappedValue = .inactive
        #endif
    }

    /// 同记忆 app 的 `jumpToSource`：有节点跳到那条，没有就打开那个窗口
    private func jump(_ mem: Memory) {
        guard let viewModel else { return }
        if MemoryConversationLink.openSource(of: mem, profileId: profileId, context: modelContext, viewModel: viewModel) != .windowGone {
            onClose?()
        }
    }

    private func reload() {
        let pid = profileId
        all = SwiftDataMemoryStore().listAll(profileId: pid, context: modelContext)
        titles = MemoryAudit.windowTitles(ids: Set(all.compactMap(\.sourceConversationId)), profileId: pid, source: SwiftDataConversationSource(container: modelContext.container))
        selection.formIntersection(Set(all.map(\.id)))
        dreamNotes = FragmentDreamNotes.load(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        loaded = true
        reloadSelf()
    }
}

/// 做完浮的那一行；id 每次新的，计时器跟着重来
struct MemoryAuditToast: Equatable {
    let id = UUID()
    let text: String
    let undoable: Bool
}

// MARK: - 筛选 sheet

struct MemoryAuditFilterSheet: View {
    @Binding var filter: MemoryAudit.Filter
    let windows: [(id: String, title: String, count: Int)]
    @Environment(\.dismiss) private var dismiss

    static let categories: [(key: String, label: String)] = [
        ("preference", "偏好"), ("fact", "事实"), ("relationship", "关系"), ("goal", "目标"), ("context", "近况")
    ]

    static func originLabel(_ o: MemoryAudit.Origin) -> String? {
        switch o {
        case .all: return nil
        case .legacyAtomic: return "改版前的原子档案"
        case .fragmentPool: return "C2 原子事实"
        }
    }

    static func dateLabel(_ d: MemoryAudit.DateRange) -> String? {
        switch d {
        case .all: return nil
        case .today: return "今天"
        case .last7Days: return "7 天内"
        case .last30Days: return "30 天内"
        case .custom(let from, let to): return "\(MemoryDateText.short(from))–\(MemoryDateText.short(to))"
        }
    }

    private enum DateChoice: Hashable { case all, today, last7, last30, custom }

    private var dateChoice: Binding<DateChoice> {
        Binding(get: {
            switch filter.dateRange {
            case .all: return .all
            case .today: return .today
            case .last7Days: return .last7
            case .last30Days: return .last30
            case .custom: return .custom
            }
        }, set: { c in
            switch c {
            case .all: filter.dateRange = .all
            case .today: filter.dateRange = .today
            case .last7: filter.dateRange = .last7Days
            case .last30: filter.dateRange = .last30Days
            case .custom:
                let to = Date()
                filter.dateRange = .custom(from: Calendar.current.date(byAdding: .day, value: -7, to: to) ?? to, to: to)
            }
        })
    }

    private func customBound(_ isFrom: Bool) -> Binding<Date> {
        Binding(get: {
            if case .custom(let from, let to) = filter.dateRange { return isFrom ? from : to }
            return Date()
        }, set: { d in
            if case .custom(let from, let to) = filter.dateRange {
                filter.dateRange = isFrom ? .custom(from: d, to: to) : .custom(from: from, to: d)
            }
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("来源", selection: $filter.origin) {
                    Text("全部").tag(MemoryAudit.Origin.all)
                    Text("改版前的原子档案").tag(MemoryAudit.Origin.legacyAtomic)
                    Text("C2 原子事实").tag(MemoryAudit.Origin.fragmentPool)
                }
                Picker("类别", selection: $filter.category) {
                    Text("全部").tag(String?.none)
                    ForEach(Self.categories, id: \.key) { c in Text(c.label).tag(Optional(c.key)) }
                }
                Picker("日期", selection: dateChoice) {
                    Text("全部").tag(DateChoice.all)
                    Text("今天").tag(DateChoice.today)
                    Text("7 天内").tag(DateChoice.last7)
                    Text("30 天内").tag(DateChoice.last30)
                    Text("自己选").tag(DateChoice.custom)
                }
                if dateChoice.wrappedValue == .custom {
                    DatePicker("从", selection: customBound(true), displayedComponents: .date)
                        .datePickerStyle(.compact)
                    DatePicker("到", selection: customBound(false), displayedComponents: .date)
                        .datePickerStyle(.compact)
                }
                Picker("来自哪个窗口", selection: $filter.conversationId) {
                    Text("全部").tag(String?.none)
                    ForEach(windows, id: \.id) { w in Text("\(w.title) · \(w.count)").tag(Optional(w.id)) }
                    // 选中的窗口这会儿不在列表里（换了别的条件）也要有个 tag，不然 Picker 认不出当前值
                    if let cid = filter.conversationId, !windows.contains(where: { $0.id == cid }) {
                        Text("当前窗口").tag(Optional(cid))
                    }
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.branchIndicator)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .panelSheetTitle("Filter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { filter = MemoryAudit.Filter() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 380)
        #endif
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }
}
