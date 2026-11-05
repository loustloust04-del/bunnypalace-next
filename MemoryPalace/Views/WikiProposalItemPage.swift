import SwiftUI

// MARK: - 整理提案的一个目录项：点进去看详情和原料（粟粟 10-23「提案我也不能点进去，然后看每个原料是啥」）
// 整页复用整理记录那套原生只读查看（iOS UICollectionView / mac NSTableView，`RunRecordListView`）：
// 标题、路径 / 类 / 钩子 / 理由原地写，每份原料折成一张卡（名称 · 层），点卡弹 sheet 用 TextKit 2 看全文（「折叠全用弹 sheet」）。
// 只读：批 / 驳回 / 改照旧在提案页那一行上做。

/// 推进去的是哪一项；碎片（线索 / 出处）在提案页主线程从库里取好带进来
struct WikiProposalItemTarget: Identifiable, Hashable {
    let proposalId: String
    let item: WikiProposal.Item
    /// 种子任务 id（种子目录 / 正文提案带）
    let seedTask: String?
    let fragments: [WikiProposalSources.Source]

    var id: String { proposalId + "/" + item.id }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// 提案页上那一行要不要出「看详情」：方向（种子 / 日常）都出；正文条目有碎片出处才出
    static func hasDetail(_ item: WikiProposal.Item) -> Bool {
        item.change.direction != nil || !item.fragmentIds.isEmpty || !(item.covered ?? []).isEmpty
    }

    /// 碎片原料一份：正文 + 原话 + 发生在哪天
    static func fragment(id: UUID, title: String?, content: String?, quote: String?, day: String?) -> WikiProposalSources.Source {
        guard let content else {
            return .init(path: id.uuidString, name: "碎片（已经删了）", layer: "碎片", text: nil, note: "这条碎片已经删了")
        }
        var text = content
        if let quote, !quote.isEmpty { text += "\n\n原话：" + quote }
        if let day, !day.isEmpty { text += "\n发生在：" + day }
        return .init(path: id.uuidString, name: title ?? String(content.prefix(20)), layer: "碎片", text: text, note: nil)
    }
}

/// 拼整页（后台，不碰主线程）。只取这一项列着的原料的现状；任务解码 + 回执索引走 `SeedTaskCache`；
/// `check` 每份原料之前调一次（离开页面 → 取消 → 在下一个检查点停，结果不交）
enum WikiProposalItemDocument {
    static func build(_ target: WikiProposalItemTarget, wiki: WikiStore, floorBase: CatalogFloorBase?) -> RunRecordDocument {
        build(target, wiki: wiki, floorBase: floorBase, check: {})
    }

    static func build(_ target: WikiProposalItemTarget, wiki: WikiStore, floorBase: CatalogFloorBase?,
                      check: () throws -> Void) rethrows -> RunRecordDocument {
        var sources: [WikiProposalSources.Source] = []
        if let d = target.item.change.direction, d.mode == .seed {
            let memoryRoot = wiki.root.deletingLastPathComponent()
            let cached = target.seedTask.flatMap { SeedTaskCache.shared.load($0, store: CatalogSeedTaskStore(wiki: wiki)) }
            try check()
            let paths = (d.sources ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !WikiProposalSources.isPrivate($0) }
            let current = try WikiProposalSources.current(paths: paths, layers: WikiProposalSources.layers(paths, task: cached?.task),
                                                          task: cached?.task, floorBase: floorBase, memoryRoot: memoryRoot, wiki: wiki, check: check)
            sources = WikiProposalSources.seed(paths: paths, task: cached?.task, receipts: cached?.receipts ?? [:], current: current)
        }
        sources += target.fragments
        try check()
        return document(title: title(target.item), fields: fields(target.item), sources: sources)
    }

    static func title(_ item: WikiProposal.Item) -> String {
        item.change.direction?.title ?? item.change.kindLabel
    }

    static func fields(_ item: WikiProposal.Item) -> [(String, String)] {
        guard let d = item.change.direction else {
            return [("类", item.change.kindLabel), ("路径", item.change.targetPath ?? "")]
        }
        var out: [(String, String)] = [
            ("路径", d.path + (d.group == true ? "（整理这个分组）" : "")),
            ("类", d.kind?.rawValue ?? ""),
            ("标题", d.title),
            ("钩子", d.hook),
            (d.mode == .seed ? "理由" : "为什么", d.reason),
        ]
        if !d.aliases.isEmpty { out.append(("别名", d.aliases.joined(separator: "、"))) }
        if let basis = d.basis, !basis.isEmpty { out.append(("依据", basis.joined(separator: "、"))) }
        out.append(("批了以后", d.modeLabel + "，写好的正文再交你批"))
        return out
    }

    /// 标题一行 → 字段原地（空的不写）→「原料 N 份 · 各层几份」→ 每份一张卡
    static func document(title: String, fields: [(String, String)], sources: [WikiProposalSources.Source]) -> RunRecordDocument {
        var rows: [RunRecordDocument.Row] = [.heading(title, level: 1)]
        for (name, value) in fields where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(.prose("\(name)：\(value)"))
        }
        rows.append(.heading(sources.isEmpty ? "没有列原料" : WikiProposalSources.tally(sources), level: 2))
        for s in sources {
            let text = s.text ?? ""
            let first = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let summary = s.note ?? first.map { String($0.prefix(80)) } ?? ""
            rows.append(.block(.init(id: rows.count, name: "\(s.name) · \(s.layer)", language: "", text: text,
                                     count: text.count, summary: summary, note: s.note, alwaysCard: true)))
        }
        return RunRecordDocument(rows: rows, sectionStarts: [0], targetRow: nil)
    }
}

/// mac 设置窗里 `SettingsRoute.memoryProposalItem` 的落点（进 path，页顶 ‹ › 回得去、前进得回来）
struct MacWikiProposalItemRoute: View {
    var body: some View {
        if let target = WikiProposalSelection.shared.item {
            WikiProposalItemPage(target: target)
        }
    }
}

struct WikiProposalItemPage: View {
    let target: WikiProposalItemTarget

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("fontScale") private var fontScale: Double = 1.2
    @State private var document: RunRecordDocument?
    @State private var openBlock: RunRecordDocument.Block?

    var body: some View {
        _ = dynamicTypeSize
        let typography = RunRecordTypography.current(fontScale: fontScale)
        return Group {
            if let document {
                RunRecordListView(document: document, typography: typography) { openBlock = $0 }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolPageBackground()
        .memorySubpage("目录项")
        .task(id: target.id) { await load() }
        .sheet(item: $openBlock) { block in
            RunRecordBlockSheet(block: block, typography: typography)
        }
    }

    private func load() async {
        guard let profile = profileManager?.currentProfile else { return }
        let pid = profile.id
        // Prompt 底图要在主线程取（PresetManager 在主线程），只拿来比 Prompt 原料的版本
        let floorBase = CatalogRunner.shared.floorBase(profile: profile)
        let target = target
        // 离开页面 = .task 取消 → 传给后台那份，在下一份原料之前停（同整理记录 `RunRecordDocument.load`）
        let job = Task.detached(priority: .userInitiated) {
            try WikiProposalItemDocument.build(target, wiki: WikiStore(profileId: pid), floorBase: floorBase,
                                               check: { try Task.checkCancellation() })
        }
        let built = try? await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
        guard let built, !Task.isCancelled, pid == profileManager?.currentProfile.id else { return }
        document = built
    }
}
