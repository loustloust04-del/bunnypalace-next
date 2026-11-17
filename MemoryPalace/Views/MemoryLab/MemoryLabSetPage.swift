import MemoryCore
import SwiftUI

// MARK: - 一份测试集（plan-memory-lab-2 §2；小样 17 / 19 / 20 / 21 / 33）
// 分段「没看过 / 👍 / 👎」+ 整理台那样的一叠卡，一句一张：卡里是首页那两种气泡，卡底「想起来了」「这一次的条件」；
// 底栏 撤回 · 批注 · 跳过 → · 👎 · 👍（拇指一样重）。拿出这份 / 改名 / 删这份在右上 ⋯。
// 这页不说话。拇指和批注就是那条记录上的（和自由聊里是同一个）。
// 第三片（plan-memory-lab-3，小样 22–27）：胶囊能点（换一组 / 临时改）；牌堆按「这份 × 这组」取；这组没跑过 / 只跑了一部分 →
// 重放（一句一句真问模型，能停）；临时改了没存 → 先存成一组；卡底多一颗「跟「现在的设置」比」。

struct MemoryLabSetPage: View {
    let setId: String
    /// 从首页进来：用首页此刻的组和页面上的参数；nil = 用这份最近跑的那一组
    var start: MemoryLabGroups.Start? = nil

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(\.settingsMetrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [MemoryLabStore.SetEntry] = []
    @State private var name = ""
    @State private var loaded = false
    /// 现在看的是哪一组（「这份 × 这组」的那一组）、页面上临时拨过的值
    @State private var groups = MemoryLabGroups()
    @State private var cardOpen = false
    /// 这份在这一组下跑了几句、还差几句
    @State private var summary = MemoryLabStore.RunSummary()
    /// 「现在的设置」下每句话最新的一条（比较用；这组就是「现在的设置」时不读）
    @State private var currentRecords: [String: MemoryLabRecord] = [:]
    @State private var replayTask: Task<Void, Never>?
    @State private var progress: (done: Int, total: Int)?
    @State private var stopping = false
    @State private var confirmRerun = false
    @State private var segment: MemoryLabPicks.Segment = .unseen
    /// 这一轮跳过的（放到这一段最后，不算判），按跳的先后
    @State private var skipped: [String] = []
    /// 撤回后放回最上面的那张
    @State private var front: String?
    @State private var lastAction: Undo?
    @State private var flight: Flight?
    @State private var sheet: CardSheet?
    @State private var noting = false
    @State private var noteDraft = ""
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var confirmDelete = false
    @State private var failure: String?

    /// 正在飞走的那张：👍 / 跳过往右，👎 / 拿出往左
    struct Flight: Equatable {
        let id: String
        let toRight: Bool
    }

    /// 撤回只记最近一下：拇指（改回原来的判断）或跳过
    private struct Undo {
        let entryId: String
        /// 拇指那一下：记录编号 + 原来的判断；nil = 跳过
        let verdict: (recordId: String, previous: MemoryLabRecord.Verdict?)?
        let segment: MemoryLabPicks.Segment
        let skipped: [String]
    }

    private enum CardSheet: Identifiable {
        case recall(MemoryLabRecord)
        case conditions(MemoryLabRecord)
        case compare(MemoryLabRecord)

        var id: String {
            switch self {
            case .recall(let r): return "r-" + r.id
            case .conditions(let r): return "c-" + r.id
            case .compare(let r): return "v-" + r.id
            }
        }
    }

    private var lab: MemoryLabRunner? { .page(profileManager, providerManager, presetManager) }
    private var assistant: String {
        let n = profileManager?.currentProfile.assistantName ?? ""
        return n.isEmpty ? "助手" : n
    }
    private var deck: [MemoryLabStore.SetEntry] {
        MemoryLabPicks.ordered(MemoryLabPicks.deck(entries, segment), skipped: skipped, front: front)
    }

    private func modelName(_ id: String) -> String { providerManager?.model(byId: id)?.name ?? id }

    var body: some View {
        VStack(spacing: 8) {
            #if os(macOS)
            // mac 右栏没有导航栏：名字和 ⋯ 放在页里
            HStack {
                Text(name).font(m.sectionHeader).foregroundColor(MemoryAuditStyle.onPage).lineLimit(1)
                Spacer(minLength: 8)
                moreMenu
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            #endif
            MemoryLabCapsule(title: groups.name, params: groups.params, assistant: assistant, modelName: modelName,
                             changed: groups.changed) { cardOpen.toggle() }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .disabled(replayTask != nil)
            if showsDeck { segments }
            stack
        }
        .memoryLabParams(groups, open: $cardOpen, lab: lab, profileId: profileManager?.currentProfile.id ?? "",
                         assistant: assistant, modelName: modelName, models: lab?.modelChoices() ?? [])
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        #if os(iOS)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { moreMenu } }
        #endif
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .recall(let record):
                MemoryLabSheetFrame(title: "想起来了") {
                    MemoryLabRecallCard(recall: MemoryLabRecall.make(record, assistant: assistant), assistant: assistant)
                }
            case .conditions(let record):
                MemoryLabConditionsSheet(record: record, assistant: assistant,
                                         floorName: { id in profileManager?.profiles.first { $0.id == id }?.name },
                                         modelName: modelName)
            case .compare(let record):
                let there = currentRecords[record.sentence]
                MemoryLabCompareSheet(here: record, there: there, groupName: groups.name, assistant: assistant,
                                      note: compareNote(there), modelName: modelName)
            }
        }
        .alert("改名", isPresented: $renaming) {
            TextField("名字", text: $nameDraft)
            Button("好") { rename() }
                .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        }
        .alert("删掉「\(name)」？", isPresented: $confirmDelete) {
            Button("删", role: .destructive) { deleteSet() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删这份测试集，里面那些句子的记录还在，自由聊里照样看得到。")
        }
        .alert("用「\(groups.name)」把这份重跑一遍？", isPresented: $confirmRerun) {
            Button("重跑") { startReplay(rerunAll: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会真问模型 \(summary.count) 句。出的是新记录，原来的留着。")
        }
        .task(id: setId) { await load() }
        // 换了一组（或刚存成一组）：牌堆换成「这份 × 这组」
        .onChange(of: groups.groupId) { _, _ in
            resetDeck()
            Task { await reload() }
        }
        // 离开页面：正在重放的停（当前这句跑完）
        .onDisappear { replayTask?.cancel() }
    }

    /// 牌堆这一轮的状态（跳过 / 撤回 / 段）全清
    private func resetDeck() {
        segment = .unseen
        skipped = []
        front = nil
        lastAction = nil
        noting = false
        flight = nil
    }

    /// 这组在这份上有记录（哪怕全是没问成的）
    private var hasRecords: Bool { entries.contains { $0.record != nil } }

    /// 出牌堆的时候（这组在这份上有记录、没有临时改、不在重放）。没问成的那条也上牌堆：看得到原因、照样能判
    private var showsDeck: Bool {
        loaded && !entries.isEmpty && replayTask == nil && !groups.changed && hasRecords
    }

    /// 「现在的设置」是活的：比到的那条跑的时候，她的设置跟此刻不一样了，说一声
    private func compareNote(_ there: MemoryLabRecord?) -> String? {
        guard let there, let then = MemoryLabParams(recorded: there.params), let now = groups.settings else { return nil }
        // 模型是台子自己的选择，不算她的设置
        let diff = then.differences(from: now).filter { $0.key != MemoryLabRecord.Item.model }
        guard !diff.isEmpty else { return nil }
        return "「现在的设置」那条是 \(MemoryLabWords.time(there.input.at)) 跑的，那时的设置跟现在差在："
            + MemoryLabWords.differences(diff, assistant: assistant, model: modelName)
    }

    // MARK: - 读

    /// 从首页进来带着首页那组；不然先看这份最近是用哪一组跑的（删掉的组 / 改过没存的 →「现在的设置」）
    private func load() async {
        guard let lab else { return }
        if let start {
            await groups.load(lab, select: start.groupId)
            groups.adopt(start)
        } else {
            let store = lab.store, id = setId
            let latest = await Task.detached(priority: .userInitiated) {
                store.setSummaries().first { $0.id == id }?.latestParamsId
            }.value
            await groups.load(lab, select: latest)
        }
        await reload()
    }

    private func reload() async {
        guard let lab else { return }
        let store = lab.store, id = setId, group = groups.groupId
        let (list, run, current, set) = await Task.detached(priority: .userInitiated) {
            let heads = store.heads()
            let current = group == MemoryLabParamSet.currentId ? []
                : store.entries(inSet: id, paramsId: MemoryLabParamSet.currentId, heads: heads)
            return (store.entries(inSet: id, paramsId: group, heads: heads), store.runSummary(inSet: id, paramsId: group, heads: heads),
                    current, store.set(id: id))
        }.value
        guard group == groups.groupId else { return }
        entries = list
        summary = run
        currentRecords = Dictionary(current.compactMap { e in e.record.map { (e.id, $0) } }, uniquingKeysWith: { a, _ in a })
        name = set?.name ?? name
        loaded = true
    }

    // MARK: - 顶上：⋯ / 三段

    private var moreMenu: some View {
        Menu {
            Button("把这句拿出这份测试集", systemImage: "rectangle.stack.badge.minus") {
                if let top = deck.first { takeOut(top) }
            }
            .disabled(deck.first == nil || flight != nil)
            Button("这组重跑一遍", systemImage: "arrow.counterclockwise") { confirmRerun = true }
                .disabled(replayTask != nil || groups.changed || entries.isEmpty || noModel)
            Button("改名", systemImage: "pencil") {
                nameDraft = name
                renaming = true
            }
            Button("删这份", systemImage: "trash", role: .destructive) { confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundColor(MemoryAuditStyle.onPage)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("更多")
    }

    /// 小样那种胶囊分段：选中的一段是白底小胶囊；拇指是线条图标
    private var segments: some View {
        let counts = MemoryLabPicks.counts(entries)
        return HStack(spacing: 0) {
            segmentButton(.unseen, icon: nil, label: "没看过", count: counts[.unseen] ?? 0)
            segmentButton(.up, icon: "hand.thumbsup", label: "👍", count: counts[.up] ?? 0)
            segmentButton(.down, icon: "hand.thumbsdown", label: "👎", count: counts[.down] ?? 0)
        }
        .padding(4)
        .frame(height: 44)
        .shellGlass(in: Capsule(), tint: 0.15)
        .padding(.horizontal, 16)
    }

    private func segmentButton(_ value: MemoryLabPicks.Segment, icon: String?, label: String, count: Int) -> some View {
        let on = segment == value
        return Button {
            guard segment != value else { return }
            segment = value
            front = nil
            flight = nil
            noting = false
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(m.body)
                } else {
                    Text(label)
                }
                Text("\(count)").monospacedDigit()
            }
            .font(on ? m.body.weight(.bold) : m.body.weight(.medium))
            .foregroundColor(Theme.textPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if on {
                    Capsule().fill(Theme.mainBg).shadow(color: .black.opacity(0.14), radius: 2, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == nil ? "\(label) \(count)" : "\(label == "👍" ? "好" : "不好") \(count)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - 一叠

    private var stack: some View {
        let deck = deck
        return ZStack {
            if !loaded {
                EmptyView()
            } else if entries.isEmpty {
                MemoryEmptyState(title: "还没有句子", message: "去模拟对话里挑几句进来")
            } else if let progress {
                replaying(progress)
            } else if groups.changed {
                // 小样 27：没名字的参数没法当一列比，先存成一组
                LabNotice(title: "参数改过了",
                          lines: [changedText, "存成一组，就按它重放这 \(summary.count) 句。"],
                          button: "存成一组") { groups.sheet = .groups }
            } else if !hasRecords {
                // 小样 23：这组在这份上一条记录都没有
                LabNotice(title: "「\(groups.name)」还没跑过这份",
                          lines: [MemoryLabGroupWords.versusSettings(groups.params, settings: groups.settings, assistant: assistant,
                                                                     model: modelName),
                                  noModel ? "先在上面选一个模型" : nil]
                              .compactMap { $0 },
                          button: "重放 \(summary.notRun) 句", disabled: noModel) { startReplay(rerunAll: false) }
            } else if deck.isEmpty {
                switch segment {
                case .unseen: MemoryEmptyState(title: "都看过了", message: "换个段看看")
                case .up: MemoryEmptyState(title: "这一段还是空的", message: "在「没看过」里点 👍，就会到这里")
                case .down: MemoryEmptyState(title: "这一段还是空的", message: "在「没看过」里点 👎，就会到这里")
                }
            } else {
                LabDeckStack(deck: deck, flight: flight) { entry in
                    MemoryLabSetCard(entry: entry, assistant: assistant,
                                     onRecall: { sheet = .recall($0) }, onConditions: { sheet = .conditions($0) },
                                     onCompare: groups.groupId == MemoryLabParamSet.currentId ? nil : { sheet = .compare($0) })
                }
                .overlay(alignment: .bottom) {
                    if noting { noteTray }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsDeck, let line = MemoryLabGroupWords.pendingLine(summary) { pendingBar(line) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsDeck { actionBar(top: deck.first, count: deck.count) }
        }
    }

    private var noModel: Bool { groups.params?.modelId.isEmpty != false }

    private var changedText: String {
        MemoryLabWords.differences(groups.changes, assistant: assistant, model: modelName)
    }

    /// 还有没跑的 / 没问成的：牌堆上面一行「还有 N 句没跑 · 重放」/「N 句没问成 · 重放」；没选模型时下面再一行
    private func pendingBar(_ line: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(line).foregroundColor(Theme.textSecondary).lineLimit(1)
                Text("·").foregroundColor(Theme.textMuted)
                Button("重放") { startReplay(rerunAll: false) }
                    .buttonStyle(.plain)
                    .foregroundColor(noModel ? Theme.textMuted : Theme.branchIndicator)
                    .disabled(noModel)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(MemoryEntryChip.fill, in: Capsule())
            if noModel {
                Text("先在上面选一个模型").font(m.caption).foregroundColor(Theme.textMuted)
            }
        }
        .font(m.secondary)
        .padding(.top, 2)
    }

    /// 重放中（小样 24）：用「组名」重放 · 进度条 · 几 / 几句 · 停
    private func replaying(_ progress: (done: Int, total: Int)) -> some View {
        VStack(spacing: 10) {
            Text("用「\(groups.name)」重放").font(m.sectionHeader).foregroundColor(MemoryAuditStyle.onPage)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .tint(Theme.branchIndicator)
                .frame(width: 180)
            Text("\(progress.done) / \(progress.total) 句").font(m.secondary).monospacedDigit().foregroundColor(Theme.textMuted)
                .contentTransition(.numericText())
            // 一句要问好几秒：转着的小圈 + 正在问第几句，看得出在动
            if progress.done < progress.total && !stopping {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在问第 \(progress.done + 1) 句").font(m.caption).foregroundColor(Theme.textMuted)
                }
            }
            Button(stopping ? "这一句跑完就停" : "停") {
                stopping = true
                replayTask?.cancel()
            }
            .buttonStyle(.plain)
            .font(m.body.weight(.medium))
            .foregroundColor(stopping ? Theme.textMuted : Theme.branchIndicator)
            .disabled(stopping)
            .padding(.top, 4)
        }
        .padding(24)
    }

    /// 重放：这组下还要跑的（或 `rerunAll` 整份）一句一句真问；跑完 / 停了回到牌堆
    private func startReplay(rerunAll: Bool) {
        guard let lab, let params = groups.params, !groups.changed, replayTask == nil, !noModel else { return }
        let id = setId, paramsId = groups.groupId
        failure = nil
        stopping = false
        progress = (0, rerunAll ? summary.count : summary.notRun)
        replayTask = Task {
            do {
                try await lab.replay(setId: id, paramsId: paramsId, params: params, rerunAll: rerunAll) { p in
                    withAnimation(.easeOut(duration: 0.25)) { progress = (p.done, p.total) }
                }
            } catch {
                failure = error.localizedDescription
            }
            replayTask = nil
            progress = nil
            stopping = false
            resetDeck()
            await reload()
        }
    }

    /// 批注托盘（小样 21）：卡底升起，「批注」+「完成」，下面一块输入
    private var noteTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("批注").font(m.secondary.weight(.semibold)).foregroundColor(Theme.textSecondary)
                Spacer(minLength: 8)
                Button(action: saveNote) {
                    Text("完成")
                        .font(m.secondary.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(MemoryEntryChip.fill, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 44)
            TextEditor(text: $noteDraft)
                .font(m.body)
                .foregroundColor(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 110)
                .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MemoryEntryChip.line, lineWidth: 1))
        }
        .memoryTray()
        .padding(.horizontal, 16)
        .padding(.bottom, 26)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - 底栏（照整理台 actionBar：圆玻璃钮 撤回 · 批注 · 跳过 →，右边一样重的 👎 👍）

    private func actionBar(top: MemoryLabStore.SetEntry?, count: Int) -> some View {
        let busy = top == nil || flight != nil || noting
        let verdict = top?.record?.judgment?.verdict
        return VStack(spacing: 4) {
            if let failure {
                Text(failure).font(m.caption).foregroundColor(Theme.danger).lineLimit(2)
            }
            HStack(spacing: 8) {
                circle("arrow.uturn.backward", label: "撤回", action: undo)
                    .disabled(lastAction == nil || flight != nil)
                circle("pencil", label: "批注") {
                    noteDraft = top?.record?.judgment?.note ?? ""
                    withAnimation(.easeOut(duration: 0.2)) { noting = true }
                }
                .disabled(busy || top?.record == nil)
                circle("arrow.right", label: "跳过") {
                    if let top { skip(top) }
                }
                .disabled(busy || count < 2)
                thumb(.down, on: verdict == .down, top: top)
                    .disabled(busy || top?.record == nil)
                thumb(.up, on: verdict == .up, top: top)
                    .disabled(busy || top?.record == nil)
            }
        }
        .controlSize(.large)
        .environment(\.colorScheme, MemoryAuditStyle.pageScheme)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func circle(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(m.sectionHeader.weight(.medium))
                .foregroundStyle(MemoryAuditStyle.onPage)
                .frame(width: 24, height: 26)
        }
        .auditGlassButton()
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    /// 👎 👍 一样宽、一样的玻璃底，只有图标带颜色；这一段就是它的那颗填实
    private func thumb(_ verdict: MemoryLabRecord.Verdict, on: Bool, top: MemoryLabStore.SetEntry?) -> some View {
        let up = verdict == .up
        let symbol = up ? "hand.thumbsup" : "hand.thumbsdown"
        return Button {
            if let top { judge(top, verdict) }
        } label: {
            Image(systemName: on ? symbol + ".fill" : symbol)
                .font(m.sectionHeader.weight(.medium))
                .foregroundStyle(up ? Theme.branchIndicator : Theme.danger)
                .frame(maxWidth: .infinity, minHeight: 26)
        }
        .auditGlassButton()
        .buttonBorderShape(.capsule)
        .accessibilityLabel(up ? "好" : "不好")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - 动作

    /// 先飞走，飞完再落盘、换下一张（同整理台 flyAway → commit）
    private func fly(_ entry: MemoryLabStore.SetEntry, toRight: Bool, then commit: @escaping () async -> Void) {
        guard flight == nil else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeIn(duration: 0.28)) {
            flight = Flight(id: entry.id, toRight: toRight)
        } completion: {
            Task {
                await commit()
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35)) { flight = nil }
            }
        }
    }

    private func judge(_ entry: MemoryLabStore.SetEntry, _ tapped: MemoryLabRecord.Verdict) {
        guard let lab, let record = entry.record else { return }
        let previous = record.judgment?.verdict
        let next = MemoryLabPicks.verdict(after: tapped, current: previous)
        let undo = Undo(entryId: entry.id, verdict: (record.id, previous), segment: segment, skipped: skipped)
        failure = nil
        front = nil
        fly(entry, toRight: tapped == .up) {
            do {
                let updated = try await lab.judge(record.id) { $0.verdict = next }
                replace(updated)
                skipped.removeAll { $0 == entry.id }
                lastAction = undo
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// 跳过：这张放到这一段的最后，不算判
    private func skip(_ entry: MemoryLabStore.SetEntry) {
        let undo = Undo(entryId: entry.id, verdict: nil, segment: segment, skipped: skipped)
        front = nil
        fly(entry, toRight: true) {
            skipped = MemoryLabPicks.skipping(entry.id, in: skipped)
            lastAction = undo
        }
    }

    /// 撤回最近一下：拇指改回原来的判断 / 跳过的放回来；那张回到最上面
    private func undo() {
        guard let undo = lastAction else { return }
        lastAction = nil
        failure = nil
        guard let verdict = undo.verdict, let lab else {
            withAnimation(.spring(duration: 0.35)) {
                skipped = undo.skipped
                front = undo.entryId
            }
            return
        }
        Task {
            do {
                let updated = try await lab.judge(verdict.recordId) { $0.verdict = verdict.previous }
                withAnimation(.spring(duration: 0.35)) {
                    replace(updated)
                    segment = undo.segment
                    skipped = undo.skipped
                    front = undo.entryId
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func replace(_ record: MemoryLabRecord) {
        if let i = entries.firstIndex(where: { $0.record?.id == record.id }) { entries[i].record = record }
    }

    private func takeOut(_ entry: MemoryLabStore.SetEntry) {
        guard let lab else { return }
        let store = lab.store, id = setId, sentence = entry.id
        failure = nil
        front = nil
        fly(entry, toRight: false) {
            do {
                try await Task.detached(priority: .userInitiated) { _ = try store.remove(sentenceId: sentence, fromSet: id) }.value
                skipped.removeAll { $0 == sentence }
                await reload()
                // 拿出撤不回（集子已经改了）
                if lastAction?.entryId == sentence { lastAction = nil }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func saveNote() {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.easeOut(duration: 0.2)) { noting = false }
        guard let lab, let record = deck.first?.record, text != (record.judgment?.note ?? "") else { return }
        Task {
            do {
                replace(try await lab.judge(record.id) { $0.note = text.isEmpty ? nil : text })
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func rename() {
        guard let lab else { return }
        let store = lab.store, id = setId
        let newName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        Task {
            do {
                let set = try await Task.detached(priority: .userInitiated) { try store.renameSet(id: id, name: newName) }.value
                name = set.name ?? newName
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func deleteSet() {
        guard let lab else { return }
        let store = lab.store, id = setId
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try store.deleteSet(id: id) }.value
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// 一叠卡：照抄整理台 `MemoryAuditStack` 那一段（它钉死 `Memory`，不改它）——只画最上面三张，后面两张各往下 7pt、缩一点；
/// 只有最上面那张能点，飞着的时候都不能点；不挂拖动手势，飞走由页面的 `flight` 驱动
private struct LabDeckStack<Card: View>: View {
    let deck: [MemoryLabStore.SetEntry]
    let flight: MemoryLabSetPage.Flight?
    @ViewBuilder let card: (MemoryLabStore.SetEntry) -> Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let visible = Array(deck.prefix(3))
        ZStack(alignment: .top) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { i, entry in
                let flying = flight?.id == entry.id
                card(entry)
                    .transaction { t in if reduceMotion { t.animation = nil } } body: {
                        $0.scaleEffect(1 - 0.04 * CGFloat(i), anchor: .bottom)
                            .offset(y: 7 * CGFloat(i))
                            .opacity(i == 0 ? 1 : (i == 1 ? 0.8 : 0.55))
                    }
                    .rotationEffect(.degrees(flying && !reduceMotion ? (flight?.toRight == true ? 12 : -12) : 0))
                    .offset(x: flying && !reduceMotion ? (flight?.toRight == true ? 700 : -700) : 0)
                    .opacity(flying ? 0 : 1)
                    .zIndex(Double(-i))
                    .allowsHitTesting(i == 0 && flight == nil)
                    .accessibilityHidden(i != 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 26)
    }
}

/// 牌堆里的一张（小样 17）：首页那两种气泡搬进卡里——她那句靠右，{助手}名小字 + 回复靠左（没回复时是那行带感叹号的原因）；
/// 回复长时卡里能滚。卡底两颗 chip（不在「现在的设置」上时三颗）。这组下没跑过的句子不进牌堆
struct MemoryLabSetCard: View {
    let entry: MemoryLabStore.SetEntry
    let assistant: String
    let onRecall: (MemoryLabRecord) -> Void
    let onConditions: (MemoryLabRecord) -> Void
    /// 「跟「现在的设置」比」（这组就是「现在的设置」时 nil，不出这颗）
    var onCompare: ((MemoryLabRecord) -> Void)? = nil

    @Environment(\.settingsMetrics) private var m

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Spacer(minLength: 40)
                        Text(entry.text)
                            .font(.system(size: Theme.F.label))
                            .foregroundColor(Theme.textPrimary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(BubbleTailShape(isUser: true, radius: 18).fill(MemoryAuditStyle.positiveTint))
                    }
                    if let record = entry.record {
                        if let reply = record.happened?.reply {
                            Text(assistant).font(m.caption).foregroundColor(Theme.textMuted).padding(.horizontal, 6).padding(.top, 4)
                            HStack {
                                Text(reply)
                                    .font(.system(size: Theme.F.label))
                                    .foregroundColor(Theme.textPrimary)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    // 卡是卡的颜色：回复气泡用页面底那一层（小样 `.dbody .ai`）
                                    .background(BubbleTailShape(isUser: false, radius: 18).fill(Theme.sidebarBg))
                                Spacer(minLength: 40)
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "exclamationmark.circle").foregroundColor(Theme.danger)
                                Text(record.happened?.error ?? "模型没有回话").foregroundColor(Theme.textSecondary)
                            }
                            .font(m.secondary)
                            .padding(.horizontal, 6)
                            .padding(.top, 4)
                        }
                        if let note = record.judgment?.note, !note.isEmpty {
                            Text(note)
                                .font(m.secondary)
                                .foregroundColor(Theme.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .padding(.top, 6)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            if let record = entry.record {
                let count = MemoryLabRecall.make(record, assistant: assistant).count
                Rectangle()
                    .fill(MemoryEntryChip.line)
                    .frame(height: 1)
                FlowLayout(spacing: 4, lineSpacing: 0) {
                    MemoryEntryChip(text: count > 0 ? "想起来了 \(count)" : "想起来了", name: "想起来了") { onRecall(record) }
                    MemoryEntryChip(text: "这一次的条件", name: "这一次的条件") { onConditions(record) }
                    if let onCompare {
                        MemoryEntryChip(text: "跟「现在的设置」比", name: "跟「现在的设置」比") { onCompare(record) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: MemoryAuditStyle.corner, style: .continuous)
                .fill(Theme.mainBg)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        }
    }
}

/// 牌堆位置上的一段说明（小样 23 / 27）：粗字标题 + 几行小字 + 一颗实心钮
private struct LabNotice: View {
    let title: String
    let lines: [String]
    let button: String
    var disabled = false
    let action: () -> Void

    @Environment(\.settingsMetrics) private var m

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(m.sectionHeader).foregroundColor(MemoryAuditStyle.onPage).multilineTextAlignment(.center)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(m.secondary).foregroundColor(Theme.textMuted).multilineTextAlignment(.center)
            }
            Button(action: action) {
                Label(button, systemImage: "arrow.counterclockwise")
                    .font(m.body.weight(.semibold))
                    .foregroundColor(MemoryAuditStyle.onAccent)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .background(Theme.branchIndicator.opacity(disabled ? 0.45 : 1), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .padding(.top, 6)
        }
        .padding(.horizontal, 32)
    }
}
