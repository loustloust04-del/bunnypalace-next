import MemoryCore
import SwiftUI
import SwiftData

struct MemoryRecallBenchResultPage: View {
    let run: MemoryBenchRun
    let set: MemoryBenchSet
    let profileId: String
    let names: EffectiveCharacterContext
    @Environment(\.modelContext) private var modelContext
    @State private var previous: [MemoryBenchRun] = []
    @State private var receipt: MemoryBenchCell?
    @State private var sourceTitles: [String: String] = [:]

    private var score: MemoryBenchScore? { run.scores.first }
    private var wrong: [MemoryBenchJudgment] {
        run.effectiveJudgments().filter { $0.verdict == .wrong }.sorted {
            if $0.cellId != $1.cellId { return $0.cellId < $1.cellId }
            return ($0.item ?? -1) < ($1.item ?? -1)
        }
    }
    private var noScoreReason: String {
        let parts = score?.parts ?? [:]
        if (parts["护栏"] ?? 0) > 0 { return "护栏触发，主分作废" }
        if (parts["出错格"] ?? 0) > 0 || run.cells.contains(where: { $0.error != nil }) { return "有出错格，无法计算主分" }
        return "没有应判项"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(MemoryRecallBenchDisplay.main(run))
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(Theme.textPrimary)
                    if score?.main == nil { Text(noScoreReason).foregroundStyle(Theme.textMuted) }
                    Text(MemoryRecallBenchDisplay.comparison(run, previous: previous)).foregroundStyle(Theme.textSecondary)
                    Text(summary).font(.caption).foregroundStyle(Theme.textMuted)
                    Text(run.at, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(Theme.textMuted)
                    if run.status != .done {
                        Text(MemoryRecallBenchDisplay.status(run.status)).font(.caption).foregroundStyle(Theme.textMuted)
                    }
                    if let note = run.note { Text(note).font(.caption).foregroundStyle(Theme.textMuted) }
                    if run.set.revision != set.revision {
                        Text("测试集已改，下面的题目文案来自当前版本；回执保留当时结果")
                            .font(.caption).foregroundStyle(Theme.textMuted)
                    }
                }.padding(.vertical, 8).panelRowBackground()
            }
            Section {
                ForEach(Array(wrong.enumerated()), id: \.offset) { _, judgment in
                    if let cell = run.cells.first(where: { $0.id == judgment.cellId }) {
                        wrongRow(judgment, cell: cell)
                    }
                }
                ForEach(run.cells.filter { $0.error != nil }) { cell in
                    Text("\(title(cell.caseId)) · \(cell.error ?? "")")
                        .foregroundStyle(Theme.textSecondary).panelRowBackground()
                }
                if wrong.isEmpty && !run.cells.contains(where: { $0.error != nil }) {
                    Text("没有错例").foregroundStyle(Theme.textMuted).panelRowBackground()
                }
            } header: { Text("错例").foregroundStyle(Theme.textSecondary) }
            Section {
                ForEach(previous) { old in
                    NavigationLink {
                        MemoryRecallBenchResultPage(run: old, set: set, profileId: profileId, names: names)
                    } label: { MemoryRecallBenchRunRow(run: old) }
                    .panelRowBackground()
                }
                if previous.isEmpty {
                    Text("还没有更早的成绩").foregroundStyle(Theme.textMuted).panelRowBackground()
                }
            } header: { Text("之前的").foregroundStyle(Theme.textSecondary) }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        #if os(macOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            MemoryRecallBenchHeading(title: "成绩 · " + names.expand(run.set.name)) { EmptyView() }
        }
        #else
        .navigationTitle("成绩 · " + names.expand(run.set.name))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        .sheet(item: $receipt) { cell in MemoryRecallBenchReceipt(cell: cell) }
        .task(id: run.id) {
            let pid = profileId, run = run, set = set, container = modelContext.container
            let data = await Task.detached(priority: .utility) {
                let store = MemoryBenchStore.forMemoryRoot(FileLibraryStore.memoryRoot(profileId: pid))
                return (store.runs(writer: "recall", setId: run.set.id).filter { $0.id != run.id && $0.at < run.at },
                        MemoryRecallBenchDisplay.sourceTitles(set: set, run: run, profileId: pid, container: container))
            }.value
            guard !Task.isCancelled else { return }
            (previous, sourceTitles) = data
        }
    }

    private var summary: String {
        let p = score?.parts ?? [:]
        return "错注 \(Int(p["错注数"] ?? 0)) · 漏注 \(Int(p["漏注数"] ?? 0)) · Y 越界 \(Int(p["Y 越界"] ?? 0)) · 应跳过却搜了 \(Int(p["应跳过却搜了"] ?? 0))"
    }
    private func title(_ id: String) -> String {
        names.expand(set.cases.first(where: { $0.id == id })?.title ?? id)
    }
    private func wrongRow(_ judgment: MemoryBenchJudgment, cell: MemoryBenchCell) -> some View {
        let item = cell.items.first { $0.index == judgment.item }
        let turn = Int(item?.fields["turn"] ?? "") ?? 1
        let input = set.cases.first(where: { $0.id == cell.caseId }).flatMap { try? $0.input.decode(MemoryBenchRecallInput.self) }
        return Button { receipt = cell } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title(cell.caseId)).foregroundStyle(Theme.textPrimary)
                if let input, input.turns.indices.contains(turn - 1) {
                    Text("第 \(turn) 轮 · " + names.expand(input.turns[turn - 1].text))
                        .font(.callout).foregroundStyle(Theme.textSecondary)
                }
                Text(names.expand(item.map {
                    MemoryRecallBenchDisplay.itemText($0, labels: set.cases.first { $0.id == cell.caseId }?.labels ?? [],
                                                     cell: cell, titles: sourceTitles)
                } ?? judgment.note ?? "整格判断为错"))
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                Text("看回执").font(.caption).foregroundStyle(Theme.textMuted)
            }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).panelRowBackground()
    }
}

extension MemoryRecallBenchDisplay {
    static func sourceTitles(set: MemoryBenchSet, run: MemoryBenchRun, profileId: String, container: ModelContainer) -> [String: String] {
        var titles: [String: String] = [:]
        let snapshot = set.cases.first.flatMap { try? $0.input.decode(MemoryBenchRecallInput.self).snapshot }
        if let snapshot, snapshot != "floor", let floor = try? MemoryBenchRecallFloor.load(snapshot, in: .main).0 {
            for card in floor.cards {
                titles[MemoryBenchRecallReader.key(card: card.path, version: card.version)] = card.title
            }
            for window in floor.windows { titles["node:\(window.id)"] = window.title }
        }
        if snapshot == "floor" {
            let wiki = WikiStore(root: FileLibraryStore.memoryRoot(profileId: profileId).appendingPathComponent("wiki"))
            let cards = SeedNoteStore(wiki: wiki)
            let context = ModelContext(container)
            let keys = Set(run.cells.flatMap { $0.items.compactMap { $0.fields["source"] } })
            for key in keys {
                let identity = key.split(separator: "|", maxSplits: 1).map(String.init)
                if key.hasPrefix("card:"), identity.count == 2 {
                    titles[key] = cards.load(path: String(identity[0].dropFirst(5)), version: identity[1])?.title
                } else if key.hasPrefix("node:") {
                    let cid = String(identity[0].dropFirst(5))
                    titles[identity[0]] = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate {
                        $0.profileId == profileId && $0.id == cid
                    })))?.first?.title
                }
            }
        }
        return titles
    }

    static func itemText(_ item: MemoryBenchItem, labels: [MemoryBenchLabel], cell: MemoryBenchCell,
                         titles: [String: String]) -> String {
        guard let source = item.fields["source"], !source.isEmpty else { return item.text }
        let turn = item.fields["turn"] ?? "1"
        let label = labels.first { $0.from == "turn:\(turn)" && $0.keys.contains(source) }
        let identity = source.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
        let title: String
        if let label {
            title = label.text
        } else if source.hasPrefix("page:") {
            title = URL(fileURLWithPath: String(identity.dropFirst(5))).lastPathComponent
        } else if source.hasPrefix("card:") {
            title = titles[source] ?? URL(fileURLWithPath: String(identity.dropFirst(5))).lastPathComponent
        } else if source.hasPrefix("memory:") {
            let output = cell.output.flatMap { try? MemoryBench.decoder.decode(MemoryBenchRecallOutput.self, from: Data($0.utf8)) }
            let index = (Int(turn) ?? 1) - 1
            let layer = output.flatMap { $0.turns.indices.contains(index) ? $0.turns[index].x.sources.first { $0.source == source }?.layer : nil }
                ?? item.fields["layer"] ?? ""
            title = layer.isEmpty ? "碎片" : "碎片 · \(layer)"
        } else if source.hasPrefix("node:") {
            title = "原文 · " + (titles[identity] ?? "窗口")
        } else if source.hasPrefix("layer:") {
            title = String(source.dropFirst(6))
        } else {
            title = "来源"
        }
        return item.text.replacingOccurrences(of: source, with: title)
    }
}

private struct MemoryRecallBenchReceipt: View {
    let cell: MemoryBenchCell
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let output = cell.output {
                    ScrollView([.horizontal, .vertical]) {
                        Text(output).font(.system(.callout, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                            .padding().frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    MemoryEmptyState(title: "原始回执已清理", message: "成绩、条目和判断仍保留；原始输出只留三十天")
                }
            }
            .toolPageBackground()
            .panelSheetTitle("原始回执")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("复制") {
                        guard let output = cell.output else { return }
                        #if os(iOS)
                        UIPasteboard.general.string = output
                        #else
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                        #endif
                    }
                        .disabled(cell.output == nil)
                }
            }
        }
        .tint(Theme.branchIndicator)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }
}
