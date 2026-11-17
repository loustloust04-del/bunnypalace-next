import MemoryCore
import SwiftUI

// MARK: - 记忆实验台（plan-memory-lab §4；她认了的小样 MemoryPalace-docs-media/docs/记忆系统/实验台小样/）
// 记忆系统的实验台，只是长得像对话：她说一句 → 在这层楼的真记忆上真问一次模型 → 看回复、看「想起来了」三条路、给 👍 👎 写批注。
// 每句自动存成一条记录（`MemoryLabRunner`）。顶上参数胶囊只改这一页上的参数，从不写她的设置。
// 第二片（plan-memory-lab-2）：胶囊下面一排测试集（固定，不跟对话滚）、每句「挑进测试集」，点一份进 `MemoryLabSetPage`。
// 第三片（plan-memory-lab-3）：胶囊写组名，参数卡能换一组 / 存成一组 / 拨系统推送那一页的数（`MemoryLabGroups`）。
// 还没有：对比表、不带记忆再问一遍——一律不出现。

struct MemoryLabPage: View {
    static let title = "模拟对话"

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(\.settingsMetrics) private var m

    /// 这层楼的全部记录（一排的数要算上重放出来的）；对话里只列 `chat`
    @State private var records: [MemoryLabRecord] = []
    @State private var loaded = false
    /// 现在用哪一组、页面上拨过的值（跟那组存的不一样的项带薄荷点）
    @State private var groups = MemoryLabGroups()
    @State private var cardOpen = false
    @State private var draft = ""
    /// 正在问的那句
    @State private var pending: String?
    @State private var failure: String?
    @State private var recallOpen: Set<String> = []
    @State private var noting: String?
    @State private var noteDraft = ""
    @State private var sheet: LabSheet?
    /// 要滚到哪（`ScrollViewReader` 里接）
    @State private var scrollRequest: ScrollRequest?
    /// 测试集一排 + 每句在哪几份里（都以集子文件为准）
    @State private var shelf: [MemoryLabStore.SetSummary] = []
    @State private var membership: [String: [String]] = [:]
    /// 点进去的那份测试集
    @State private var openSet: String?
    /// ＋ 那张纸卡起名新建一份（alert 开着）
    @State private var naming = false
    @State private var newName = ""
    @FocusState private var inputFocused: Bool

    private struct ScrollRequest: Equatable {
        let id: String
        let anchor: UnitPoint
        var animated = true
        let token = UUID()
    }

    private enum LabSheet: Identifiable {
        case conditions(MemoryLabRecord)
        case prompt(MemoryLabRecord)
        case pick(MemoryLabRecord)

        var id: String {
            switch self {
            case .conditions(let r): return "c-" + r.id
            case .prompt(let r): return "p-" + r.id
            case .pick(let r): return "k-" + r.id
            }
        }
    }

    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private var assistant: String {
        let n = profileManager?.currentProfile.assistantName ?? ""
        return n.isEmpty ? "助手" : n
    }
    private var lab: MemoryLabRunner? { .page(profileManager, providerManager, presetManager) }

    /// 对话里列的：在自由聊里说的句子（重放出来的不是她在这儿说的）
    private var chat: [MemoryLabRecord] { MemoryLabPicks.freeChat(records) }

    private var canSend: Bool {
        pending == nil && groups.params.map { !$0.modelId.isEmpty } == true
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            MemoryLabCapsule(title: groups.name, params: groups.params, assistant: assistant, modelName: modelName,
                             changed: groups.changed) { cardOpen.toggle() }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)
            // 测试集一排固定在胶囊下面，不跟对话滚；对话顶上那头淡出，淡出的边就在这一排底下（小样）
            if loaded {
                MemoryLabSetShelf(sets: shelf, line: { MemoryLabGroupWords.shelfLine($0, groups: groups.groups) },
                                  onOpen: { openSet = $0 }, onNew: { naming = true })
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
            }
            conversation
        }
        .memoryLabParams(groups, open: $cardOpen, lab: lab, profileId: profileId, assistant: assistant,
                         modelName: modelName, models: lab?.modelChoices() ?? [])
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .conditions(let record):
                MemoryLabConditionsSheet(record: record, assistant: assistant,
                                         floorName: { id in profileManager?.profiles.first { $0.id == id }?.name },
                                         modelName: modelName)
            case .prompt(let record):
                MemoryLabPromptSheet(record: record, assistant: assistant)
            case .pick(let record):
                MemoryLabPickSheet(sets: shelf, picked: MemoryLabPicks.sets(for: record, in: membership),
                                   onToggle: { togglePick(record, set: $0) },
                                   onCreate: { createSet($0, adding: record.id) })
                    .presentationDetents([.medium, .large])
            }
        }
        .onChange(of: inputFocused) { _, focused in if focused { cardOpen = false } }
        .task(id: profileId) { await load() }
        .navigationDestination(item: $openSet) { id in
            // 带着首页此刻的组和页面上的参数进去（改过没存的也带）
            MemoryLabSetPage(setId: id, start: .init(groupId: groups.groupId, params: groups.params))
        }
        // 从测试集页回来：那边判过 / 拿出 / 改名 / 删过，重读
        .onChange(of: openSet) { old, new in
            if old != nil, new == nil { Task { await reload() } }
        }
        .alert("新建一份测试集", isPresented: $naming) {
            TextField("比如：深夜聊天", text: $newName)
            Button("建") { createSet() }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        }
    }

    /// 这个模型台子问得了（在、而且不走 Claude Code 桥）
    private func askable(_ id: String) -> Bool {
        guard let providerManager, let model = providerManager.model(byId: id) else { return false }
        return providerManager.provider(for: model)?.type != .ccBridge
    }

    private func modelName(_ id: String) -> String {
        providerManager?.model(byId: id)?.name ?? id
    }

    // MARK: - 进页面

    private func load() async {
        guard let lab else { return }
        let pid = profileId
        await groups.load(lab)
        cardOpen = false
        recallOpen = []
        noting = nil
        failure = nil
        let history = await lab.records()
        guard pid == profileId else { return }
        records = history
        loaded = true
        // 进页面停在最后一句
        scrollRequest = ScrollRequest(id: "bottom", anchor: .bottom, animated: false)
        await refreshSets()
    }

    /// 从测试集页回来：只重读记录和测试集，参数不动
    private func reload() async {
        guard let lab else { return }
        let pid = profileId
        let history = await lab.records()
        guard pid == profileId else { return }
        records = history
        await groups.refresh(lab)
        await refreshSets()
    }

    /// 测试集一排的数、每句在哪几份里。几个 👍 用手上这份记录轻算，不再读一遍记录
    private func refreshSets() async {
        guard let lab else { return }
        let pid = profileId, store = lab.store, heads = records.map(MemoryLabRecord.Head.init)
        let (summaries, members) = await Task.detached(priority: .userInitiated) {
            (store.setSummaries(heads: heads), store.membership())
        }.value
        guard pid == profileId else { return }
        shelf = summaries
        membership = members
    }

    /// 挑进 / 拿出 / 新建都是同步文件 IO：放后台，做完重读一排
    private func changeSets(_ change: @escaping @Sendable (MemoryLabStore) throws -> Void) {
        guard let lab else { return }
        let store = lab.store
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try change(store) }.value
            } catch {
                failure = error.localizedDescription
            }
            await refreshSets()
        }
    }

    private func togglePick(_ record: MemoryLabRecord, set id: String) {
        let sentence = record.sentence, recordId = record.id
        if MemoryLabPicks.sets(for: record, in: membership).contains(id) {
            changeSets { try $0.remove(sentenceId: sentence, fromSet: id) }
        } else {
            changeSets { try $0.add(recordId: recordId, toSet: id) }
        }
    }

    /// ＋ 那张纸卡的 alert
    private func createSet() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        createSet(name, adding: nil)
    }

    /// 新建一份；`recordId` 有 = 建完把这句挑进去（挑进 sheet 里的「建」）
    private func createSet(_ name: String, adding recordId: String?) {
        guard !name.isEmpty else { return }
        changeSets { store in
            let set = try store.createSet(name: name)
            if let recordId { try store.add(recordId: recordId, toSet: set.id) }
        }
    }

    // MARK: - 参数胶囊 / 参数卡

    // MARK: - 对话

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if loaded && chat.isEmpty && pending == nil {
                        Text("随便说一句。\n每句单独问\(assistant)，连同当时的参数记下来。")
                            .font(m.body)
                            .foregroundColor(Theme.textMuted)
                            .multilineTextAlignment(.center)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    let said = chat
                    ForEach(Array(said.enumerated()), id: \.element.id) { i, record in
                        turn(record, previous: i > 0 ? said[i - 1] : nil)
                            .id(record.id)
                    }
                    if let pending {
                        VStack(alignment: .leading, spacing: 8) {
                            userBubble(pending)
                            HStack {
                                BubbleTypingDots()
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(assistantBubbleShape)
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(.top, 10)
                        .id("pending")
                    }
                    if let failure {
                        errorLine(failure).padding(.top, 8)
                    }
                    Color.clear.frame(height: 12).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                }
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                // 等这一帧排完（键盘收起、卡展开）再滚，不然 LazyVStack 还没量到新内容
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard scrollRequest == request else { return }
                    if request.animated {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(request.id, anchor: request.anchor) }
                    } else {
                        proxy.scrollTo(request.id, anchor: request.anchor)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func turn(_ record: MemoryLabRecord, previous: MemoryLabRecord?) -> some View {
        let recall = MemoryLabRecall.make(record, assistant: assistant)
        let open = recallOpen.contains(record.id)
        VStack(alignment: .leading, spacing: 6) {
            if let divider = divider(record, previous: previous) {
                Button { sheet = .conditions(record) } label: {
                    Text(divider.text)
                        .font(m.caption)
                        .foregroundColor(divider.changed ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(divider.changed ? Theme.branchIndicator.opacity(0.25) : MemoryEntryChip.fill, in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            userBubble(record.input.text).padding(.top, 4)
            if let reply = record.happened?.reply {
                HStack {
                    Text(reply)
                        .font(.system(size: Theme.F.label))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(assistantBubbleShape)
                    Spacer(minLength: 40)
                }
            } else {
                errorLine(record.happened?.error ?? "模型没有回话")
            }
            underRow(record, recall: recall, open: open)
                .id(record.id + "-under")
            if noting == record.id {
                noteEditor(record)
            } else if let note = record.judgment?.note, !note.isEmpty {
                Text(note)
                    .font(m.secondary)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .onTapGesture { startNote(record) }
            }
            if open {
                MemoryLabRecallCard(recall: recall, assistant: assistant)
            }
        }
        .padding(.bottom, 10)
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.system(size: Theme.F.label))
                .foregroundColor(MemoryAuditStyle.onPage)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(BubbleTailShape(isUser: true, radius: 18).fill(MemoryAuditStyle.positiveTint))
        }
    }

    /// 和整理台一个系列：{助手}回的 = 卡的颜色实心一块（带浅影）；她说的 = 强调色淡淡一层（`userBubble`）。
    /// 主对话的 userBubble / assistantBubble 是给壁纸调的，放在这页底上跟底一个颜色
    private var assistantBubbleShape: some View {
        BubbleTailShape(isUser: false, radius: 18)
            .fill(Theme.mainBg)
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    private func errorLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle").foregroundColor(Theme.danger)
            Text(text).foregroundColor(Theme.textSecondary).textSelection(.enabled)
        }
        .font(m.secondary)
        .padding(.horizontal, 6)
    }

    /// 这一句算哪一组：没写 `paramsId` 的旧记录现推；她设置里的模型台子问不了（Claude Code）时，只差在模型上的也算「现在的设置」
    private func group(of record: MemoryLabRecord) -> String? {
        if let group = record.paramsGroup { return group }
        guard record.paramsId == nil, let diff = record.params?.differences,
              diff.allSatisfy({ $0.key == MemoryLabRecord.Item.model && !askable($0.settings) }) else { return nil }
        return MemoryLabParamSet.currentId
    }

    /// 相邻两句之间的小签（小样 16）：新的一天「11-16 · 组名」；换了一组「换成「组名」」；同一组里参数变了「改了：…」（点开那一次的条件）
    private func divider(_ record: MemoryLabRecord, previous: MemoryLabRecord?) -> (text: String, changed: Bool)? {
        let day = MemoryLabWords.day(record.input.at), mine = group(of: record)
        guard let previous, MemoryLabWords.day(previous.input.at) == day else {
            return ("\(day) · " + groups.name(of: mine), false)
        }
        let theirs = group(of: previous)
        if let mine, mine != theirs { return ("换成「\(groups.name(of: mine))」", true) }
        guard let now = MemoryLabParams(recorded: record.params), let before = MemoryLabParams(recorded: previous.params) else { return nil }
        let diff = now.differences(from: before)
        guard !diff.isEmpty else { return nil }
        return ("改了：" + MemoryLabWords.differences(diff, assistant: assistant, model: modelName), true)
    }

    // MARK: - 每句下面一行

    private func underRow(_ record: MemoryLabRecord, recall: MemoryLabRecall, open: Bool) -> some View {
        let recallChip = Button {
            if open {
                recallOpen.remove(record.id)
            } else {
                recallOpen.insert(record.id)
                // 展开的卡在这一行下面：把这一行顶到上面，卡跟着露出来
                scrollRequest = ScrollRequest(id: record.id + "-under", anchor: .top)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "house")
                Text(recall.count > 0 ? "想起来了 \(recall.count)" : "想起来了")
                Image(systemName: open ? "chevron.down" : "chevron.right").font(m.caption)
            }
            .font(m.secondary)
            .foregroundColor(Theme.textSecondary)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        let links = HStack(spacing: 12) {
            link("这一次的条件") { sheet = .conditions(record) }
            link("提示词多了什么") { sheet = .prompt(record) }
        }
        let icons = HStack(spacing: 0) {
            thumb(record, .up)
            thumb(record, .down)
            iconButton("pencil", on: !(record.judgment?.note ?? "").isEmpty, filled: false, color: Theme.branchIndicator, label: "批注") {
                if noting == record.id { noting = nil } else { startNote(record) }
            }
            let picked = !MemoryLabPicks.sets(for: record, in: membership).isEmpty
            iconButton(picked ? "plus.square.fill.on.square.fill" : "plus.square.on.square", on: picked, filled: false,
                       color: Theme.branchIndicator, label: "挑进测试集") { sheet = .pick(record) }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                recallChip
                links
                Spacer(minLength: 0)
                icons
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    recallChip
                    Spacer(minLength: 0)
                    icons
                }
                links.padding(.leading, 2)
            }
        }
        .padding(.horizontal, 4)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(m.secondary).foregroundColor(Theme.branchIndicator).lineLimit(1)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func thumb(_ record: MemoryLabRecord, _ verdict: MemoryLabRecord.Verdict) -> some View {
        let on = record.judgment?.verdict == verdict
        let up = verdict == .up
        return iconButton(up ? "hand.thumbsup" : "hand.thumbsdown", on: on,
                          color: up ? Theme.branchIndicator : Theme.danger, label: up ? "好" : "不好") {
            let next: MemoryLabRecord.Verdict? = on ? nil : verdict
            judge(record) { $0.verdict = next }
        }
    }

    /// 选中的填实（拇指）；`filled: false` 的只变色（铅笔没有实心款）
    private func iconButton(_ symbol: String, on: Bool, filled: Bool = true, color: Color, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on && filled ? symbol + ".fill" : symbol)
                .font(.system(size: 17))
                .foregroundColor(on ? color : Theme.textMuted)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func noteEditor(_ record: MemoryLabRecord) -> some View {
        HStack(spacing: 8) {
            TextField("", text: $noteDraft, prompt: Text("批注").foregroundColor(Theme.textMuted), axis: .vertical)
                .textFieldStyle(.plain)
                .font(m.body)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onSubmit { saveNote(record) }
            Button("好") { saveNote(record) }
                .font(m.body)
                .foregroundColor(Theme.branchIndicator)
                .buttonStyle(.plain)
        }
    }

    private func startNote(_ record: MemoryLabRecord) {
        noteDraft = record.judgment?.note ?? ""
        noting = record.id
    }

    private func saveNote(_ record: MemoryLabRecord) {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        noting = nil
        judge(record) { $0.note = text.isEmpty ? nil : text }
    }

    private func judge(_ record: MemoryLabRecord, _ change: @escaping @Sendable (inout MemoryLabRecord.Judgment) -> Void) {
        guard let lab else { return }
        let pid = profileId
        Task {
            do {
                let updated = try await lab.judge(record.id, change)
                guard pid == profileId, let i = records.firstIndex(where: { $0.id == updated.id }) else { return }
                records[i] = updated
                await refreshSets()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    // MARK: - 输入栏

    private var placeholder: String {
        guard let params = groups.params, !params.modelId.isEmpty else { return "先在上面选一个模型" }
        return groups.changed ? "按改过的「\(groups.name)」说一句" : "按「\(groups.name)」说一句"
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $draft, prompt: Text(placeholder).foregroundColor(Theme.textMuted))
                .textFieldStyle(.plain)
                .font(m.body)
                .foregroundColor(Theme.textPrimary)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(groups.params?.modelId.isEmpty != false)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(MemoryAuditStyle.onAccent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.branchIndicator))
                    .opacity(canSend ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("发送")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Theme.mainBg, in: Capsule())
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .frame(maxWidth: 720)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let lab, let params = groups.params else { return }
        let paramsId = groups.runId
        let pid = profileId
        draft = ""
        failure = nil
        cardOpen = false
        recallOpen = []
        inputFocused = false
        pending = text
        scrollRequest = ScrollRequest(id: "pending", anchor: .bottom)
        Task {
            defer { pending = nil }
            do {
                let record = try await lab.run(text, params: params, paramsId: paramsId)
                guard pid == profileId else { return }
                records.append(record)
                // 回复 / 出错到了：这一句下面那行贴着底，回复整段在上面看得见
                scrollRequest = ScrollRequest(id: record.id + "-under", anchor: .bottom)
            } catch {
                guard pid == profileId else { return }
                failure = "这句没存下：\(error.localizedDescription)"
                scrollRequest = ScrollRequest(id: "bottom", anchor: .bottom)
            }
        }
    }
}

// MARK: - 参数卡（胶囊点开往下落的那张）

struct MemoryLabParamCard: View {
    @Binding var params: MemoryLabParams
    let baseline: MemoryLabParams
    /// 这一组叫什么（「现在的设置」/ 组名）
    let title: String
    let assistant: String
    let changed: Bool
    /// nil = 还没选
    let modelName: String?
    let models: [(APICredential, [ProviderModel])]
    let onPickModel: (String) -> Void
    /// 点组名 / 「改过 · 存成一组」→ 换一组；点「自动推送 ›」「{助手}主动翻 ›」→ 那一页的数
    let onSheet: (MemoryLabGroups.Sheet) -> Void
    let onClose: () -> Void

    @Environment(\.settingsMetrics) private var m

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 组名优先完整：放不下时「改过 · 存成一组」换到下一行，模型名先缩
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    groupTitle
                    if changed { saveChip }
                    Spacer(minLength: 8)
                    modelMenu.fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        groupTitle
                        Spacer(minLength: 8)
                        modelMenu
                    }
                    if changed { saveChip }
                }
            }
            Text("每轮都带").font(m.caption).foregroundColor(Theme.textMuted).padding(.top, 2)
            FlowLayout(spacing: 6, lineSpacing: 0) {
                ForEach(MemoryLabWords.items(assistant: assistant), id: \.key) { item in
                    chip(item.key, item.name, item.path)
                }
            }
            // 两格名字都要完整：并排放不下就上下排
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { switches }
                VStack(spacing: 8) { switches }
            }
            Button(action: onClose) {
                Image(systemName: "chevron.up")
                    .font(m.caption.weight(.semibold))
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: MemoryAuditStyle.corner, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .frame(maxWidth: 560)
    }

    @ViewBuilder
    private func chip(_ key: String, _ name: String, _ path: WritableKeyPath<MemoryLabParams, Bool>) -> some View {
        let carried = key == MemoryLabRecord.Item.rootIndex && params.rootIndexCarried
        let on = params[keyPath: path] || carried
        if carried {
            // 推送或每轮全带开着时 wiki 目录一定带：显示开着、点不掉
            MemoryEntryChip(text: name, look: .mine, changed: params[keyPath: path] != baseline[keyPath: path], name: name)
                .opacity(0.6)
                .accessibilityHint("自动推送或原子事实每轮全带开着时一定带")
        } else {
            MemoryEntryChip(text: name, look: on ? .mine : .empty, changed: params[keyPath: path] != baseline[keyPath: path],
                            name: name) { params[keyPath: path].toggle() }
        }
    }

    private var groupTitle: some View {
        Button { onSheet(.groups) } label: {
            HStack(spacing: 4) {
                Text(title).font(m.sectionHeader).foregroundColor(Theme.textPrimary).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(m.caption).foregroundColor(Theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .accessibilityLabel("换一组参数")
    }

    private var saveChip: some View {
        Button { onSheet(.groups) } label: {
            Text("改过 · 存成一组")
                .font(m.caption.weight(.medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Theme.branchIndicator.opacity(0.3), in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder
    private var switches: some View {
        toggle("自动推送", \.systemPush, sheet: .push, changed: pushChanged)
        toggle("\(assistant)主动翻", \.recallTool, sheet: .pull, changed: pullChanged)
    }

    /// 那一页里有一项跟这组存的不一样（开关本身或那一页的数）
    private func differs(_ fields: [RecallTuning.Field]) -> Bool {
        fields.contains { $0.value(in: params.tuning) != $0.value(in: baseline.tuning) }
    }

    private var pushChanged: Bool {
        params.systemPush != baseline.systemPush || params.tuning.cooldownEnabled != baseline.tuning.cooldownEnabled
            || differs(RecallTuning.Field.allCases.filter { $0.page == .archiveTrigger })
    }

    private var pullChanged: Bool {
        params.recallTool != baseline.recallTool || differs([.maximumRecallCalls])
    }

    /// 一格：名字 ›（点了进那一页）+ 开关
    private func toggle(_ title: String, _ path: WritableKeyPath<MemoryLabParams, Bool>, sheet: MemoryLabGroups.Sheet,
                        changed: Bool) -> some View {
        HStack(spacing: 5) {
            Button { onSheet(sheet) } label: {
                HStack(spacing: 4) {
                    Text(title).font(m.body).foregroundColor(Theme.textPrimary).lineLimit(1).fixedSize()
                    if changed { Circle().fill(Theme.branchIndicator).frame(width: 7, height: 7) }
                    Image(systemName: "chevron.right").font(m.caption).foregroundColor(Theme.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            Toggle(title, isOn: $params[dynamicMember: path])
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.branchIndicator)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(MemoryEntryChip.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var modelMenu: some View {
        Menu {
            Picker("模型", selection: Binding(get: { params.modelId }, set: onPickModel)) {
                ForEach(models, id: \.0.id) { credential, list in
                    Section(credential.name) {
                        ForEach(list) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(modelName ?? "选模型").lineLimit(1)
                Image(systemName: "chevron.down").font(m.caption)
            }
            .font(m.secondary)
            .foregroundColor(modelName == nil ? Theme.branchIndicator : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(MemoryEntryChip.fill, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("模型")
    }
}
