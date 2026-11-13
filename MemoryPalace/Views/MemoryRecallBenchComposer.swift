import MemoryCore
import SwiftUI
import SwiftData

struct MemoryRecallBenchSource: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case page = "wiki 页", card = "卡", node = "日期窗口" }
    let id: String
    let title: String
    let detail: String
    let kind: Kind

    struct Loaded: Sendable {
        var sources: [MemoryRecallBenchSource] = []
        var errors: [Kind: String] = [:]
    }

    static func load(profileId: String, memoryRoot: URL, container: ModelContainer) -> Loaded {
        var result = Loaded()
        for kind in Kind.allCases {
            do {
                result.sources += try load(kind: kind, profileId: profileId, memoryRoot: memoryRoot, container: container)
            } catch {
                result.errors[kind] = kind == .node ? "时间轴文件读不了" : "\(kind.rawValue)文件读不了"
            }
        }
        return result
    }

    private static func load(kind: Kind, profileId: String, memoryRoot: URL, container: ModelContainer) throws -> [Self] {
        let wiki = WikiStore(root: memoryRoot.appendingPathComponent("wiki"))
        if kind == .page {
            return SafeWiki.scan(wiki, memoryRoot: memoryRoot).pages.map {
                Self(id: MemoryBenchRecallReader.key(page: $0.path, version: $0.version),
                     title: $0.page.title, detail: $0.path, kind: .page)
            }
        }
        var sources: [Self] = []
        if kind == .card {
            struct CardIdentity: Decodable { let path: String; let version: String }
            let cards = SeedNoteStore(wiki: wiki)
            for name in (SafeWiki.names(in: [SeedNoteStore.folderName], under: wiki.root)?.names ?? []).sorted() where name.hasSuffix(".json") {
                guard let data = SafeWiki.read(name, in: [SeedNoteStore.folderName], under: wiki.root),
                      let ref = try? JSONDecoder().decode(CardIdentity.self, from: data),
                      CatalogRecallIndexStore.publicPath(ref.path),
                      name == SeedNoteStore.key(path: ref.path, version: ref.version) + ".json",
                      let card = cards.load(path: ref.path, version: ref.version) else { continue }
                sources.append(Self(id: MemoryBenchRecallReader.key(card: card.path, version: card.version), title: card.title,
                                    detail: "\(card.path) · \(card.version)", kind: .card))
            }
            return sources
        }
        let dir = TimelineStore.dir(root: memoryRoot)
        var days: [TimelineDayRecord] = []
        var entries: [TimelineEntry] = []
        for month in try TimelineStore.monthsStrict(in: dir) {
            let content = try TimelineStore.monthStrict(month, in: dir)
            days += content.days
            entries += content.entries
            if Set(days.map(\.date) + entries.map(\.dayKey)).count >= 30 { break }
        }
        let recent = Set((Set(days.map(\.date) + entries.map(\.dayKey))).sorted(by: >).prefix(30))
        let context = ModelContext(container)
        var paths: [String: Set<String>] = [:]
        func visible(_ cid: String) throws -> Set<String> {
            if let cached = paths[cid] { return cached }
            guard let conv = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate {
                $0.profileId == profileId && $0.id == cid && $0.isTrashed == false && $0.memoryEnabled == true
            })).first else { paths[cid] = []; return [] }
            let nodes = try context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate {
                $0.profileId == profileId && $0.conversationId == cid
            }))
            let resolution = BranchSelection.resolve(
                links: nodes.map { .init(id: $0.id, parentId: $0.parentId, childrenIds: $0.childrenIds) },
                selection: BranchSelection.decode(conv.branchSelectionData), legacyCurrentNodeId: conv.currentNodeId)
            let allowed = Set(nodes.filter {
                !$0.isTrashed && !$0.isSourceHidden && !$0.isSyntheticRoot && $0.hasDisplayableContent
                    && ($0.role == "user" || $0.role == "assistant")
            }.map(\.id))
            let result = Set(resolution.pathIds).intersection(allowed)
            paths[cid] = result
            return result
        }
        for day in days.filter({ recent.contains($0.date) }).sorted(by: { $0.date > $1.date }) {
            for item in day.items {
                guard let from = item.from, try visible(item.conversationId).contains(from) else { continue }
                sources.append(Self(id: MemoryBenchRecallReader.key(node: from, conversationId: item.conversationId), title: "\(day.date) · \(item.window)",
                                    detail: item.title, kind: .node))
            }
        }
        for entry in entries.filter({ recent.contains($0.dayKey) }).sorted(by: { $0.start > $1.start }) {
            // Old entries without a first-node anchor cannot represent a node identity.
            guard let from = entry.lastNodeId, try visible(entry.conversationId).contains(from) else { continue }
            sources.append(Self(id: MemoryBenchRecallReader.key(node: from, conversationId: entry.conversationId), title: "\(entry.dayKey) · \(entry.title)",
                                detail: "旧格式 · 末条消息", kind: .node))
        }
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id).inserted }
    }
}

struct MemoryRecallBenchDraft {
    private static let saveLock = NSLock()
    struct Selection: Identifiable {
        let source: MemoryRecallBenchSource
        var kind = "允许带"
        var turn = 1
        var id: String { source.id }
    }
    var text = ""
    var second = ""
    var selections: [Selection] = []
    var skip = false
    var skipTurn = 1

    func save(names: MemoryBenchRecallInput.Names, availableKeys: Set<String>, store: MemoryBenchStore) throws {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = second.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { throw MemoryBenchLocalExecutor.Failure("先写一句要测的话") }
        guard !selections.isEmpty || skip else {
            throw MemoryBenchLocalExecutor.Failure("至少选一个来源或打开『这句不该翻』")
        }
        if skip && selections.contains(where: { $0.kind == "必须带" && (next.isEmpty || $0.turn == skipTurn) }) {
            throw MemoryBenchLocalExecutor.Failure("不该翻的那句不能再要求必须带")
        }
        for selection in selections {
            guard availableKeys.contains(selection.id) else {
                throw MemoryBenchLocalExecutor.Failure("来源已不存在或版本已变：\(selection.source.detail)，请重新选择")
            }
        }
        let turns: [MemoryBenchRecallInput.Turn] = [.init(text: first)] + (next.isEmpty ? [] : [.init(text: next)])
        let input = MemoryBenchRecallInput(snapshot: "floor", profile: names, turns: turns)
        let caseId = "floor-" + UUID().uuidString.prefix(8)
        var labels = selections.enumerated().map { index, selection in
            MemoryBenchLabel(id: "\(caseId)-\(index)", kind: selection.kind, text: selection.source.title,
                             keys: [selection.id], from: "turn:\(next.isEmpty ? 1 : selection.turn)")
        }
        if skip {
            labels.append(.init(id: "\(caseId)-skip", kind: "应跳过", text: "这句不该翻", keys: [],
                                from: "turn:\(next.isEmpty ? 1 : skipTurn)"))
        }
        Self.saveLock.lock()
        defer { Self.saveLock.unlock() }
        var set = store.floorSets().first { $0.id == "recall-floor" }
            ?? MemoryBenchSet(id: "recall-floor", name: "我出的题", writer: "recall", source: .floor,
                              createdAt: MemoryBench.now(), cases: [])
        guard set.writer == "recall", set.source == .floor else {
            throw MemoryBenchLocalExecutor.Failure("本楼层测试集身份不符，未保存")
        }
        set.cases.append(.init(id: caseId, title: String(first.prefix(40)), input: try .from(input), labels: labels))
        try store.saveSet(set)
    }
}

struct MemoryRecallBenchComposer: View {
    let profileId: String
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MemoryRecallBenchDraft()
    @State private var sources: [MemoryRecallBenchSource] = []
    @State private var searches: [MemoryRecallBenchSource.Kind: String] = [:]
    @State private var sourceErrors: [MemoryRecallBenchSource.Kind: String] = [:]
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?

    private var hasSecond: Bool { !draft.second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var names: EffectiveCharacterContext {
        if let profile = profileManager?.currentProfile { return EffectiveCharacterContext(profile: profile) }
        return EffectiveCharacterContext(charName: "", userName: "")
    }

    var body: some View {
        List {
            Section {
                TextField("一句要测的话", text: $draft.text, axis: .vertical).lineLimit(3...8)
                    .foregroundStyle(Theme.textPrimary).panelRowBackground()
                TextField("可选第二句：续题或换题", text: $draft.second, axis: .vertical).lineLimit(2...6)
                    .foregroundStyle(Theme.textPrimary).panelRowBackground()
                Toggle("这句不该翻", isOn: $draft.skip).foregroundStyle(Theme.textPrimary).panelRowBackground()
                if draft.skip && hasSecond { turnPicker("不该翻的是", turn: $draft.skipTurn).panelRowBackground() }
                Text(MemoryRecallBenchSetPage.floorUnavailable).font(.caption).foregroundStyle(Theme.textMuted).panelRowBackground()
                if let error { Text(error).foregroundStyle(Theme.danger).panelRowBackground() }
            } header: { Text("问句").foregroundStyle(Theme.textSecondary) }
            if !draft.selections.isEmpty {
                Section {
                    ForEach($draft.selections) { $selection in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(names.expand(selection.source.title)).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Button("移除") { draft.selections.removeAll { $0.id == selection.id } }
                                    .foregroundStyle(Theme.textMuted)
                            }
                            Text(names.expand(selection.source.detail)).font(.caption).foregroundStyle(Theme.textMuted)
                            Picker("标签", selection: $selection.kind) {
                                ForEach(["必须带", "允许带", "禁止带"], id: \.self) { Text($0).tag($0) }
                            }.pickerStyle(.segmented)
                            if hasSecond { turnPicker("用于", turn: $selection.turn) }
                        }.padding(.vertical, 4).panelRowBackground()
                    }
                } header: { Text("已选来源").foregroundStyle(Theme.textSecondary) }
            }
            ForEach(MemoryRecallBenchSource.Kind.allCases, id: \.self) { kind in
                sourceSection(kind)
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            MemoryRecallBenchHeading(title: "出题") {
                Button(saving ? "正在保存" : "保存", action: save)
                    .disabled(saving || !loaded || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        #if os(iOS)
        .navigationTitle("出题")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        .task(id: profileId) { await reload() }
        .onDisappear { saveTask?.cancel() }
    }

    private func turnPicker(_ title: String, turn: Binding<Int>) -> some View {
        Picker(title, selection: turn) {
            Text("第一句").tag(1)
            Text("第二句").tag(2)
        }.pickerStyle(.segmented)
    }

    private func sourceSection(_ kind: MemoryRecallBenchSource.Kind) -> some View {
        let search = searches[kind] ?? ""
        let list = sources.filter {
            $0.kind == kind && (search.isEmpty || names.expand($0.title + " " + $0.detail).localizedCaseInsensitiveContains(search))
        }
        return Section {
            TextField("搜索" + kind.rawValue, text: Binding(get: { searches[kind] ?? "" }, set: { searches[kind] = $0 }))
                .foregroundStyle(Theme.textPrimary).panelRowBackground()
            ForEach(list) { source in
                let selected = draft.selections.contains { $0.id == source.id }
                Button {
                    if selected { draft.selections.removeAll { $0.id == source.id } }
                    else { draft.selections.append(.init(source: source)) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(names.expand(source.title)).foregroundStyle(Theme.textPrimary)
                            Text(names.expand(source.detail)).font(.caption).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.branchIndicator)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).panelRowBackground()
            }
            if let failure = sourceErrors[kind] {
                Text(failure).font(.caption).foregroundStyle(Theme.textMuted).panelRowBackground()
            } else if loaded && list.isEmpty {
                Text(search.isEmpty ? "没有可选的来源" : "没有匹配的来源")
                    .font(.caption).foregroundStyle(Theme.textMuted).panelRowBackground()
            }
        } header: { Text(kind.rawValue).foregroundStyle(Theme.textSecondary) }
    }

    private func reload() async {
        let pid = profileId, container = modelContext.container
        let fresh = await Task.detached(priority: .utility) {
            MemoryRecallBenchSource.load(profileId: pid, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), container: container)
        }.value
        guard !Task.isCancelled else { return }
        sources = fresh.sources
        sourceErrors = fresh.errors
        loaded = true
    }

    private func save() {
        guard !saving else { return }
        saving = true
        error = nil
        let pid = profileId, container = modelContext.container, draft = draft
        let profile = MemoryBenchRecallInput.Names(userName: names.userName, assistantName: names.charName,
                                                  timeZone: Calendar.current.timeZone.identifier)
        saveTask = Task {
            defer { saving = false; saveTask = nil }
            do {
                let task = Task.detached(priority: .utility) {
                    let fresh = MemoryRecallBenchSource.load(profileId: pid, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), container: container)
                    try Task.checkCancellation()
                    try draft.save(names: profile, availableKeys: Set(fresh.sources.map(\.id)), store: .forMemoryRoot(FileLibraryStore.memoryRoot(profileId: pid)))
                }
                try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard !Task.isCancelled else { return }
                dismiss()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
