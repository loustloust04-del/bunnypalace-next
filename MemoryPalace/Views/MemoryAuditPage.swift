import SwiftUI
import SwiftData

// MARK: - 审计台（plan-memory-audit-desk 第五节）
// 档案一条一张卡：留 / 删 / 改字 / 改类别 / 跳回原消息 / 批量。设置 → 记忆里推入，记忆 app 底栏最右一格（规格 7¼）。
// 不自动合并 / 删 / 标失效，不提示「可能重复」，不审 B4。规则全在 `MemoryAudit`，这里只管摆和存。
// 10-23 起页名「整理台」（plan-memory-audit-home-trial 第二节）：审计台首页的一个台；原第四段「整理提案」挪进 wiki 台（`MemoryWikiPage`）。

/// 审计台的看法（10-16 astra #8）：状态段、筛选条件、展开集合。同时间轴 / 窗口总结的 model，记忆 app 父级持有，
/// mac `switch tab` 切格重建页面时不丢；多选不在这里（切格照旧清）
@Observable
final class MemoryAuditViewState {
    var state: MemoryAudit.State = .unreviewed
    /// 审计台首页推进去的那个台（plan-memory-audit-home-trial 第二节）；切楼层退回首页
    var station: AuditStationID?
    var filter = MemoryAudit.Filter()
    var expanded: Set<UUID> = []
    /// 牌堆最上面压住的那张（审计台卡片 plan 2.3）
    var topId: UUID?
    /// 这一轮牌堆里已经过掉的（「留下」里按「留」只过不改库，plan 2.1）
    var passed: Set<UUID> = []
    /// 哪几段用牌堆（plan 2.1）：默认只有「没看过」；只记在这里，不落盘
    var stackStates: Set<MemoryAudit.State> = [.unreviewed]
    /// 牌堆「撤回上一张」（plan 2.3，⧫7）：只记最近一次
    var lastAction: MemoryAudit.Undo?
    /// 牌堆代次（10-17 astra #1）：重置一次 +1，飞着的那一下飞完发现代次变了就作废
    var deckGeneration = 0

    func clear() {
        state = .unreviewed
        station = nil
        filter = MemoryAudit.Filter()
        expanded = []
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
    /// 弹层里给：关弹层的「完成」（多选时藏起来，免得和「选择」变成的「完成」撞成两个），跳到原消息前也先关
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
    /// 状态段 / 筛选 / 展开了哪几张（10-16 astra #8）：记忆 app 底栏里由父级持有（mac 切格会重建这页），别处推进来的自己持有
    var viewState: MemoryAuditViewState? = nil
    @State private var ownViewState = MemoryAuditViewState()
    @State private var showFilter = false
    @State private var selection: Set<UUID> = []
    @State private var editing: Memory?
    @State private var pendingPurge: Set<UUID>? = nil
    /// 两个批量删确认框：打开时冻结的楼层 + 目标 id（10-16 astra #6）
    @State private var bannerSnapshot: MemoryAudit.TrashSnapshot?
    @State private var trashAllSnapshot: MemoryAudit.TrashSnapshot?
    /// 存盘失败的那行红字（10-16 astra #7）
    @State private var saveError: String?
    /// 牌堆里正在飞走的那张（plan 2.3）
    @State private var flight: MemoryAuditFlight?

    private var ui: MemoryAuditViewState { viewState ?? ownViewState }
    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private var now: Date { Date() }
    private var rows: [Memory] { MemoryAudit.apply(all, filter: ui.filter, state: ui.state, now: now) }
    /// 这一段用牌堆（plan 2.1）；iOS「选择」里一律列表
    private var showsStack: Bool { ui.stackStates.contains(ui.state) && !isSelecting }
    private var deck: [Memory] { MemoryAudit.deck(rows: rows, all: all, state: ui.state, top: ui.topId, passed: ui.passed) }
    private var bannerTargets: [Memory] {
        guard !bannerDone, let cutoff = MemoryAudit.cutoff() else { return [] }
        return MemoryAudit.v5BannerTargets(all, cutoff: cutoff)
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
        // 放在记忆 app 底栏里时：多选的批量底栏要让出系统页签栏
        .toolbarVisibility(editMode?.wrappedValue.isEditing == true ? .hidden : .automatic, for: .tabBar)
        #else
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { onClose() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty { macSelectionBar }
        }
        #endif
        .sheet(isPresented: $showFilter) {
            MemoryAuditFilterSheet(filter: Bindable(ui).filter, windows: windowChoices)
        }
        .sheet(item: $editing) { mem in
            AddMemorySheet(profileId: profileId, editing: mem, pinsOnSave: false) { didChange() }
        }
        // 居中 alert（iOS 26 的 confirmationDialog 会锚到 List 弹成 popover）
        .alert(MemoryDeletePlan.purgeTitle(pendingPurge?.count ?? 0),
               isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
               presenting: pendingPurge) { ids in
            Button("彻底删除", role: .destructive) { purgeConfirmed(ids) }
            Button("取消", role: .cancel) { pendingPurge = nil }
        } message: { _ in
            Text("删掉之后找不回来。")
        }
        .alert("把 \(bannerSnapshot?.ids.count ?? 0) 条碎片移到已删除？",
               isPresented: Binding(get: { bannerSnapshot != nil }, set: { if !$0 { bannerSnapshot = nil } }),
               presenting: bannerSnapshot) { s in
            Button("移到已删除", role: .destructive) {
                if trash(snapshot: s) { bannerDone = true }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("可以在已删除里恢复")
        }
        .alert("把筛出来的 \(trashAllSnapshot?.ids.count ?? 0) 条都删掉？",
               isPresented: Binding(get: { trashAllSnapshot != nil }, set: { if !$0 { trashAllSnapshot = nil } }),
               presenting: trashAllSnapshot) { s in
            Button("移到已删除", role: .destructive) { trash(snapshot: s) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("可以在已删除里恢复")
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
        #if os(iOS)
        .onChange(of: editMode?.wrappedValue.isEditing == true) { _, _ in resetDeck() }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            all = []
            titles = [:]
            loaded = false
            endSelection()
            resetDeck()
        }
        .onChange(of: profileId) { _, _ in reload() }
    }

    private var list: some View {
        let rows = rows
        return List(selection: $selection) {
            ForEach(rows, id: \.id) { mem in
                card(mem)
                    .tag(mem.id)
                    .swipeActions(edge: .leading) { leadingSwipe(mem) }
                    .swipeActions(edge: .trailing) { trailingSwipe(mem) }
                    .panelRowBackground(rowBackground(mem.id))
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UUID.self) { ids in
            actions(self.rows.filter { ids.contains($0.id) })
        }
        .overlay {
            if loaded && rows.isEmpty { emptyState }
        }
    }

    // MARK: - 顶上：横条 / 三段 / 筛选行

    private var header: some View {
        let counts = MemoryAudit.counts(all, filter: ui.filter, now: now)
        let banner = bannerTargets.count
        return VStack(alignment: .leading, spacing: 10) {
            if banner > 0 {
                HStack(spacing: 8) {
                    Button { bannerSnapshot = MemoryAudit.snapshot(bannerTargets, profileId: profileId) } label: {
                        Text("v5 碎片池有 \(banner) 条还没看过 · 全部删掉 ›")
                            .font(m.caption)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { bannerDone = true } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textMuted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("不再提示")
                }
                .padding(.leading, 12)
                .padding(.vertical, 4)
                .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let saveError {
                Text(saveError)
                    .font(m.caption)
                    .foregroundColor(Theme.danger)
                    .lineLimit(2)
            }
            Picker("状态", selection: Bindable(ui).state) {
                Text("没看过 \(counts[.unreviewed] ?? 0)").tag(MemoryAudit.State.unreviewed)
                Text("留下 \(counts[.kept] ?? 0)").tag(MemoryAudit.State.kept)
                Text("删了 \(counts[.trashed] ?? 0)").tag(MemoryAudit.State.trashed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            filterRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .toolPageBackground()
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            Text(filterSummary)
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button { showFilter = true } label: {
                Text("筛选 ›")
                    .font(m.caption)
                    .foregroundColor(Theme.branchIndicator)
            }
            .buttonStyle(.plain)
            if !isSelecting { layoutToggle }
            #if os(macOS)
            // mac 设置窗没有工具栏：⋯ 放在筛选行尾
            moreMenu
            #endif
        }
    }

    /// 列表 ↔ 牌堆（plan 2.1，⧫1 加的）：画的是点了会变成的样子；棕灰 glyph（直接压在浅薄荷页面底上，不用薄荷色）。
    /// iOS「选择」里藏（那时一定是列表）；mac 切到列表就是原生多选
    private var layoutToggle: some View {
        let stacked = showsStack
        return Button {
            if stacked { ui.stackStates.remove(ui.state) } else { ui.stackStates.insert(ui.state) }
            endSelection()
            resetDeck()
        } label: {
            Image(systemName: stacked ? "list.bullet" : "rectangle.stack")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stacked ? "切成列表" : "切成牌堆")
        .help(stacked ? "切成列表" : "切成牌堆")
    }

    /// 一行字写当前条件（如「v5 碎片池 · 关系 · 7 天内 · 2 个窗口」）
    private var filterSummary: String {
        var parts: [String] = []
        if let o = MemoryAuditFilterSheet.originLabel(ui.filter.origin) { parts.append(o) }
        if let c = ui.filter.category { parts.append(MemoryCardView.categoryLabels[c] ?? c) }
        if let d = MemoryAuditFilterSheet.dateLabel(ui.filter.dateRange) { parts.append(d) }
        if let cid = ui.filter.conversationId {
            parts.append("《\(titles[cid] ?? "窗口")》")
        } else {
            let n = Set(rows.compactMap(\.sourceConversationId)).count
            if n > 0 { parts.append("\(n) 个窗口") }
        }
        return parts.isEmpty ? "全部" : parts.joined(separator: " · ")
    }

    /// 筛选 sheet 里的窗口：当前结果（除窗口以外的条件）里出现过的，按条数多→少
    private var windowChoices: [(id: String, title: String, count: Int)] {
        var f = ui.filter
        f.conversationId = nil
        let base = MemoryAudit.apply(all, filter: f, state: ui.state, now: now)
        return MemoryAudit.windowCounts(base).map { ($0.id, titles[$0.id] ?? "已删的窗口", $0.count) }
    }

    // MARK: - 卡片

    private func card(_ mem: Memory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content(mem)
            HStack(spacing: 8) {
                Spacer()
                buttons(mem)
            }
        }
        .padding(.vertical, 4)
    }

    /// 卡片内容（列表行 / 牌堆卡共用）；牌堆卡正文不折叠、滑条挪到卡底
    private func content(_ mem: Memory, inDeck: Bool = false) -> MemoryAuditCardContent {
        MemoryAuditCardContent(
            memory: mem,
            windowTitle: mem.sourceConversationId.flatMap { titles[$0] },
            expanded: ui.expanded.contains(mem.id),
            locked: isSelecting,
            fullText: inDeck,
            showsImportance: !inDeck,
            onToggle: { toggle(mem.id) },
            onJump: viewModel != nil && mem.sourceConversationId != nil ? { jump(mem) } : nil,
            onEdit: { editing = mem },
            onCategory: { c in
                persist([mem]) { MemoryAudit.setCategory(mem, c) }
            },
            onImportance: { v in setImportance(mem, v) }
        )
    }

    /// 值没变不存；存不成放回原值（10-17 astra #3），滑条跟着弹回
    private func setImportance(_ mem: Memory, _ v: Int) {
        let before = MemoryAudit.Fields(mem)
        guard MemoryAudit.setImportance(mem, v) else { return }
        if !didChange() { before.apply(to: mem) }
    }

    // MARK: - 牌堆（plan 2.1 / 2.3）

    private var stack: some View {
        let deck = deck
        return VStack(spacing: 0) {
            Group {
                if deck.isEmpty {
                    if loaded { stackEmpty }
                } else {
                    MemoryAuditStack(deck: deck, flight: flight) { mem in deckCard(mem) }
                }
            }
            .frame(maxHeight: .infinity)
            undoButton
        }
        // 最上面那张一露面就压住（新写进来的排它后面）；它离开这一段 / 按了留删后换下一张
        .onChange(of: deck.first?.id, initial: true) { _, id in
            if ui.topId != id { ui.topId = id }
        }
    }

    /// 「↶ 撤回上一张」：一直占着这一行（没得撤时透明 + 不能点），卡片高度不跟着跳；棕灰字压在浅薄荷页面底上。
    /// 那张在别处又改过（对不上）就置灰不能点（10-17 astra #2）
    private var undoButton: some View {
        let shown = ui.lastAction != nil && flight == nil
        let available = shown && ui.lastAction.map { MemoryAudit.canUndo($0, in: all) } == true
        return Button(action: undoLast) {
            Label("撤回上一张", systemImage: "arrow.uturn.backward")
                .font(m.caption)
                .foregroundColor(available ? Theme.textSecondary : Theme.textMuted)
                .frame(minHeight: 32)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(shown ? 1 : 0)
        .disabled(!available)
        .accessibilityHidden(!shown)
        .padding(.bottom, 4)
    }

    /// 撤回：那张回到最上面并压住（还在这一段的话）；动了库就存盘，存不成顶上红字、字段放回撤回前、撤回记录留着能再试
    private func undoLast() {
        guard let u = ui.lastAction, MemoryAudit.canUndo(u, in: all) else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35)) {
            if u.kind == .passed {
                ui.passed.remove(u.id)
            } else {
                guard let mem = all.first(where: { $0.id == u.id }),
                      persist([mem], { MemoryAudit.undo(u, in: [mem]) }) else { return }
            }
            ui.lastAction = nil
            ui.topId = u.id
        }
    }

    private func deckCard(_ mem: Memory) -> some View {
        let titles = deckButtonTitles
        return MemoryAuditDeckCard(
            leftTitle: titles.left,
            rightTitle: titles.right,
            importance: mem.importance,
            importanceDisabled: mem.supersededAt != nil,
            onImportance: { v in setImportance(mem, v) },
            onLeft: { deckLeft(mem) },
            onRight: { deckRight(mem) }
        ) {
            content(mem, inDeck: true)
        }
    }

    /// 卡底两颗按钮（plan 2.1 表）：没看过 删 / 留；留下 删 / 留（只过到下一张）；删了 彻底删 / 恢复
    private var deckButtonTitles: (left: String, right: String) {
        ui.state == .trashed ? ("彻底删", "恢复") : ("删", "留")
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
        // 留下里按「留」不改库，只是这张过了（plan 2.1）
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

    /// 牌堆空了：筛出来为零给「清掉筛选」；「留下 / 删了」一叠过完一遍；其余同列表的空状态
    @ViewBuilder
    private var stackEmpty: some View {
        if ui.filter != MemoryAudit.Filter() {
            MemoryEmptyState(title: "这些条件下没有\(segmentNoun)", message: "换个条件，或者把筛选清掉") {
                // 棕黑字：压在浅薄荷页面底上，不放薄荷实心按钮
                Button("清掉筛选") { ui.filter = MemoryAudit.Filter() }
                    .font(m.body.weight(.medium))
                    .foregroundColor(Theme.textPrimary)
                    .buttonStyle(.plain)
            }
        } else if !ui.passed.isEmpty {
            MemoryEmptyState(title: "这一叠看完了", message: "切到别的段，或者换成列表再看")
        } else {
            emptyState
        }
    }

    private var segmentNoun: String {
        switch ui.state {
        case .unreviewed: return "没看过的"
        case .kept: return "留下的"
        case .trashed: return "删掉的"
        }
    }

    /// 列表在「选择」里（iOS editMode）：卡里的滑条不让动；mac 原生多选没有这个模式
    private var isSelecting: Bool {
        #if os(iOS)
        editMode?.wrappedValue.isEditing == true
        #else
        false
        #endif
    }

    @ViewBuilder
    private func buttons(_ mem: Memory) -> some View {
        switch MemoryAudit.state(of: mem) {
        case .unreviewed:
            pill("留", color: Theme.branchIndicator) { keep([mem]) }
            pill("删", color: Theme.danger) { trash([mem]) }
        case .kept:
            pill("删", color: Theme.danger) { trash([mem]) }
        case .trashed:
            pill("恢复", color: Theme.branchIndicator) { restore([mem]) }
            pill("彻底删", color: Theme.danger) { pendingPurge = [mem.id] }
        }
    }

    private func pill(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
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

    @ViewBuilder
    private func leadingSwipe(_ mem: Memory) -> some View {
        switch MemoryAudit.state(of: mem) {
        case .unreviewed:
            Button { keep([mem]) } label: { Label("留", systemImage: "checkmark") }
                .tint(Theme.branchIndicator)
        case .trashed:
            Button { restore([mem]) } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
                .tint(Theme.branchIndicator)
        case .kept:
            EmptyView()
        }
    }

    @ViewBuilder
    private func trailingSwipe(_ mem: Memory) -> some View {
        if mem.supersededAt == nil {
            Button(role: .destructive) { trash([mem]) } label: { Label("删", systemImage: "trash") }
        } else {
            Button { pendingPurge = [mem.id] } label: { Label("彻底删", systemImage: "trash") }
                .tint(Theme.danger)
        }
    }

    /// 右键 / 长按：同卡上那组动作
    @ViewBuilder
    private func actions(_ ms: [Memory]) -> some View {
        let live = ms.filter { $0.supersededAt == nil }
        let dead = ms.filter { $0.supersededAt != nil }
        if live.contains(where: { $0.reviewedAt == nil }) {
            Button { keep(live) } label: { Label("留", systemImage: "checkmark") }
        }
        if ms.count == 1, let mem = ms.first, mem.supersededAt == nil {
            Button { editing = mem } label: { Label("改字", systemImage: "pencil") }
            if viewModel != nil, mem.sourceConversationId != nil {
                Button { jump(mem) } label: { Label("跳到这条", systemImage: "arrow.right.circle") }
            }
        }
        if !live.isEmpty {
            Button(role: .destructive) { trash(live) } label: { Label("删", systemImage: "trash") }
        }
        if !dead.isEmpty {
            Button { restore(dead) } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { pendingPurge = Set(dead.map(\.id)) } label: { Label("彻底删", systemImage: "trash") }
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
        case .unreviewed: return MemoryEmptyState(title: "没看过的都过完了", message: "新记下的会先到这里")
        case .kept: return MemoryEmptyState(title: "还没有留下的", message: "在「没看过」里点「留」，就会到这里")
        case .trashed: return MemoryEmptyState(title: "没有删掉的", message: "删掉的会先放在这里，可以恢复")
        }
    }

    // MARK: - 批量 / 工具栏

    private var selected: [Memory] { rows.filter { selection.contains($0.id) } }

    #if os(iOS)
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        let editing = editMode?.wrappedValue.isEditing == true
        if let onClose, !editing {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { onClose() }
                    .foregroundColor(Theme.branchIndicator)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            MemorySelectButton()
            if !editing { moreMenu }
        }
        if editing {
            ToolbarItemGroup(placement: .bottomBar) {
                batchButtons
            }
        }
    }
    #else
    private var macSelectionBar: some View {
        HStack(spacing: 14) {
            batchButtons
            Button { selection = [] } label: { Image(systemName: "xmark.circle") }
                .help("取消选择")
        }
        .font(.system(size: 13))
        .foregroundColor(Theme.textSecondary)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .toolPageBackground()
    }
    #endif

    /// 底栏：「留 N」「删 N」；「删了」里是「恢复 N」「彻底删 N」
    @ViewBuilder
    private var batchButtons: some View {
        let ms = selected
        if ui.state == .trashed {
            Button { restore(ms) } label: { Label("恢复 \(ms.count)", systemImage: "arrow.uturn.backward") }
                .disabled(ms.isEmpty)
            Spacer()
            Button(role: .destructive) { pendingPurge = Set(ms.map(\.id)) } label: { Label("彻底删 \(ms.count)", systemImage: "trash") }
                .disabled(ms.isEmpty)
        } else {
            if ui.state == .unreviewed {
                Button { keep(ms) } label: { Label("留 \(ms.count)", systemImage: "checkmark") }
                    .disabled(ms.isEmpty)
            }
            Spacer()
            Button(role: .destructive) { trash(ms) } label: { Label("删 \(ms.count)", systemImage: "trash") }
                .disabled(ms.isEmpty)
        }
    }

    private var moreMenu: some View {
        Menu {
            if ui.state != .trashed {
                Button(role: .destructive) { trashAllSnapshot = MemoryAudit.snapshot(rows, profileId: profileId) } label: {
                    Label("把筛出来的 \(rows.count) 条都删掉", systemImage: "trash")
                }
                .disabled(rows.isEmpty)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundColor(Theme.branchIndicator)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(ui.state == .trashed)
    }

    // MARK: - 动作（规则在 MemoryAudit，这里存盘 + 通知）

    private func toggle(_ id: UUID) {
        if ui.expanded.contains(id) { ui.expanded.remove(id) } else { ui.expanded.insert(id) }
    }

    @discardableResult
    private func keep(_ ms: [Memory]) -> Bool {
        persist(ms) { MemoryAudit.keep(ms) }
    }

    @discardableResult
    private func trash(_ ms: [Memory]) -> Bool {
        persist(ms) { MemoryAudit.trash(ms) }
    }

    @discardableResult
    private func restore(_ ms: [Memory]) -> Bool {
        persist(ms) { MemoryAudit.restore(ms) }
    }

    /// 改库 + 存盘；存不成把这几条动过的字段放回原值（10-17 astra #3：只放回自己改的，不 rollback 全 app 共用的主 context）
    @discardableResult
    private func persist(_ ms: [Memory], _ change: () -> Void) -> Bool {
        let before = ms.map { ($0, MemoryAudit.Fields($0)) }
        change()
        guard didChange() else {
            for (m, f) in before { f.apply(to: m) }
            return false
        }
        return true
    }

    @discardableResult
    private func purge(_ ids: Set<UUID>) -> Bool {
        pendingPurge = nil
        MemoryAudit.purge(ids: ids, profileId: profileId, context: modelContext)
        return didChange()
    }

    /// 批量删按确认框打开时的快照执行（10-16 astra #6）：楼层换了不动；只删快照里还活着的。返回存成没有
    @discardableResult
    private func trash(snapshot: MemoryAudit.TrashSnapshot) -> Bool {
        guard snapshot.profileId == profileId else { return false }
        let fresh = SwiftDataMemoryStore().listAll(profileId: snapshot.profileId, context: modelContext)
        let targets = MemoryAudit.trashTargets(snapshot, in: fresh)
        return persist(targets) { MemoryAudit.trash(targets) }
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
        let ids = Set(all.map(\.id))
        selection.formIntersection(ids)
        ui.expanded.formIntersection(ids)
        loaded = true
    }
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
        case .fragmentPool: return "v5 碎片池"
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
                    Text("v5 碎片池").tag(MemoryAudit.Origin.fragmentPool)
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
            .panelSheetTitle("筛选")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("全部清掉") { filter = MemoryAudit.Filter() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
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
