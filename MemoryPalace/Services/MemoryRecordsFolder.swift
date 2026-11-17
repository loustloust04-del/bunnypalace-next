import Foundation
import MemoryCore

/// wiki 这条线上三样原来只在审计台 / 页编辑器里看得到的东西，在记忆文件夹里各有一处（粟粟 11-14「外在表现是文件夹」）：
/// 整理提案（`memory/wiki/Proposals/<提案编号>.md`）、要点卡（`memory/wiki/Notes/<编号>.md`）、
/// 页历史（`memory/wiki/History/<页路径>/<那一版的时间>.md`）。
/// 都是只读的投影：盘上原来怎么存（`.proposals/*.json`、`.cards/*.json`、`.history/`）不动，批 / 驳回 / 回到某一版照旧在原处做。
/// 列的时候只看文件名和改动时间，读哪一份才解哪一份。名字以 `private_` 开头的页的历史、动到这种页的提案、出自这种原料的要点卡不给。
/// 模型原始输出（`.proposals/drafts`）不在这里。页历史不进同步给 CC 的那棵树（`GardenTree.exclusion`），提案和要点卡进
enum MemoryRecordsFolder {
    static let proposalsFolder = FileLibraryMemoryFolder.wikiFolder + "/Proposals"
    static let notesFolder = FileLibraryMemoryFolder.wikiFolder + "/Notes"
    static let historyFolder = FileLibraryMemoryFolder.wikiFolder + "/History"
    private static let folders = [proposalsFolder, notesFolder, historyFolder]

    static func contains(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return folders.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// 文件库里这三格的名字
    static func displayName(_ path: String) -> String? {
        switch path {
        case proposalsFolder: return "整理提案"
        case notesFolder: return "要点卡"
        case historyFolder: return "页历史"
        default: return nil
        }
    }

    /// 为什么只读（文件工具 / CC 那边改了时回的那一句）
    static func readOnlyReason(_ path: String) -> String? {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == proposalsFolder || p.hasPrefix(proposalsFolder + "/") {
            return "整理提案在这里只能看；批、驳回、改了再批在审计台 › wiki › 整理提案里做。要提一个新的整理方向用 suggest_wiki_direction。"
        }
        if p == notesFolder || p.hasPrefix(notesFolder + "/") { return "要点卡是种子整理时照原料出的，只能看。" }
        if p == historyFolder || p.hasPrefix(historyFolder + "/") { return "页历史是每次改页之前存下的那一版，只能看；要回到某一版，在那一页的历史里恢复。" }
        return nil
    }

    // MARK: - 列

    /// 后台调（读目录）。路径是落盘写法（本人那组是 `{{user}}`），给人 / 模型看时照 wiki 路径同一条规矩显示成名字
    static func list(profileId: String) -> [FileLibraryStore.FileMeta] {
        let wiki = WikiStore(profileId: profileId)
        var out: [FileLibraryStore.FileMeta] = []
        let proposals = wiki.root.appendingPathComponent(WikiStore.proposalsFolder, isDirectory: true)
        for file in regularFiles(in: proposals) where file.name.hasSuffix(".json") {
            out.append(.init(path: "\(proposalsFolder)/\(file.name.dropLast(5)).md", bytes: file.bytes, modifiedAt: file.modifiedAt))
        }
        // 种子任务各有一个以任务编号命名的文件夹，里面的提案文件名也是编号（任务快照 task.json 不算）
        for task in subfolders(of: proposals) where UUID(uuidString: task.lastPathComponent) != nil {
            for file in regularFiles(in: task) where file.name.hasSuffix(".json") && UUID(uuidString: String(file.name.dropLast(5))) != nil {
                out.append(.init(path: "\(proposalsFolder)/\(file.name.dropLast(5)).md", bytes: file.bytes, modifiedAt: file.modifiedAt))
            }
        }
        for file in regularFiles(in: wiki.root.appendingPathComponent(SeedNoteStore.folderName, isDirectory: true)) where file.name.hasSuffix(".json") {
            out.append(.init(path: "\(notesFolder)/\(file.name.dropLast(5)).md", bytes: file.bytes, modifiedAt: file.modifiedAt))
        }
        history(in: wiki.root.appendingPathComponent(WikiStore.historyFolder, isDirectory: true), page: [], into: &out)
        return out
    }

    private static let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

    private static func entries(_ dir: URL) -> [(url: URL, values: URLResourceValues)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.compactMap { url in
            guard !url.lastPathComponent.hasPrefix("."), let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return nil }
            return (url, values)
        }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    private static func regularFiles(in dir: URL) -> [(name: String, bytes: Int, modifiedAt: Date)] {
        entries(dir).filter { $0.values.isRegularFile == true }
            .map { ($0.url.lastPathComponent, $0.values.fileSize ?? 0, $0.values.contentModificationDate ?? .distantPast) }
    }

    private static func subfolders(of dir: URL) -> [URL] {
        entries(dir).filter { $0.values.isDirectory == true }.map(\.url)
    }

    private static func history(in dir: URL, page: [String], into out: inout [FileLibraryStore.FileMeta]) {
        for entry in entries(dir) {
            let name = entry.url.lastPathComponent
            guard !CCMemorySync.isExcluded(name: name) else { continue }
            if entry.values.isDirectory == true {
                history(in: entry.url, page: page + [name], into: &out)
            } else if entry.values.isRegularFile == true, name.hasSuffix(".md"), !page.isEmpty {
                out.append(.init(path: ([historyFolder] + page + [name]).joined(separator: "/"), bytes: entry.values.fileSize ?? 0,
                                 modifiedAt: entry.values.contentModificationDate ?? .distantPast))
            }
        }
    }

    // MARK: - 读

    /// nil = 没有这份 / 不给看。`path` 里本人那组写名字或 `{{user}}` 都认；回的文字里 `{{user}}` 显示成名字
    static func read(_ path: String, profileId: String, user: String) -> String? {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.hasSuffix(".md") else { return nil }
        let wiki = WikiStore(profileId: profileId)
        func name(in folder: String) -> String? {
            guard p.hasPrefix(folder + "/") else { return nil }
            let rest = String(p.dropFirst(folder.count + 1).dropLast(3))
            return rest.isEmpty || rest.contains("/") || rest.hasPrefix(".") ? nil : rest
        }
        let text: String?
        if let id = name(in: proposalsFolder) {
            text = WikiProposalStore(wiki: wiki).load(id).flatMap { proposalText($0, assistantName: "") }
        } else if let key = name(in: notesFolder) {
            text = SafeWiki.read(key + ".json", in: [SeedNoteStore.folderName], under: wiki.root)
                .flatMap { try? noteDecoder.decode(SeedNoteCard.self, from: $0) }.flatMap(noteText)
        } else if p.hasPrefix(historyFolder + "/") {
            let parts = p.dropFirst(historyFolder.count + 1).split(separator: "/").map(String.init)
            guard parts.count >= 2, let entry = parts.last else { return nil }
            let page = WikiStore.stored(parts.dropLast().joined(separator: "/"), user: user)
            guard !WikiProposalSources.isPrivate(page) else { return nil }
            text = wiki.historyText(page, entry: entry)
        } else {
            text = nil
        }
        return text.map { WikiStore.shown(WikiProposalSources.strippingPrivateLinks($0), user: user) }
    }

    private static let noteDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    // MARK: - 一份提案

    private static func stateLabel(_ state: WikiProposal.Item.State) -> String {
        switch state {
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        case .stale: return "Stale"
        }
    }

    /// 动到私人页的提案整份不给（nil）
    static func proposalText(_ p: WikiProposal, assistantName: String) -> String? {
        var touched: [String] = []
        for item in p.items {
            if let path = item.change.targetPath { touched.append(path) }
            if case .regroup(let layer, let groups, let moves) = item.change {
                touched += [layer] + groups.map(\.path) + moves.flatMap { [$0.from, $0.to] }
            }
            if case .link(_, let link) = item.change { touched.append(link.target) }
        }
        guard !touched.contains(where: WikiProposalSources.isPrivate) else { return nil }
        var out = FrontmatterCodec.render(meta: [
            ("id", p.id),
            ("from", WikiProposalDisplay.originLabel(p.origin, assistantName: assistantName)),
            ("created", timeFormatter.string(from: p.createdAt)),
            ("status", WikiProposalDisplay.statusText(p)),
        ], body: "# " + oneLine(WikiProposalDisplay.summary(p, assistantName: assistantName)))
        if !out.hasSuffix("\n") { out += "\n" }
        if let request = p.request { out += "\n当时的请求：\(oneLine(request.text))\n" }
        for (index, item) in p.items.enumerated() {
            out += "\n## \(index + 1). \(stateLabel(item.state)) · \(changeTitle(item.change))\n\n" + changeBody(item.change) + "\n"
            if let reason = item.rejection?.reason, !reason.isEmpty { out += "\n驳回原因：\(oneLine(reason))\n" }
            if let reason = item.staleReason, !reason.isEmpty { out += "\n失效原因：\(oneLine(reason))\n" }
            if let checks = item.checks, !checks.isEmpty { out += "\n没过的检查：\n" + checks.map { "- " + oneLine($0) }.joined(separator: "\n") + "\n" }
        }
        for extra in p.unapplied ?? [] {
            out += "\n## 没收进页的内容" + (extra.page.map { "（\($0)）" } ?? "") + "\n\n\(extra.reason)\n\n```\n\(extra.raw)\n```\n"
        }
        return out
    }

    private static func changeTitle(_ change: WikiProposal.Change) -> String {
        switch change {
        case .direction(let d): return "方向：\(d.action == .newPage ? "新开" : "更新") \(d.path)"
        case .newPage(let page): return "新开页 \(page.path)"
        case .appendRecords(let path, _): return "追加记录 \(path)"
        case .rewriteNow(let path, _, _, _): return "改「现在」 \(path)"
        case .link(let from, let link): return "连线 \(from) → \(link.target)"
        case .retag(let path, _, _, _, _): return "改钩子 \(path)"
        case .regroup(let layer, _, _): return "分组调整 \(layer)"
        case .confirmCovered(let path): return "确认已经写过 \(path)"
        }
    }

    private static func changeBody(_ change: WikiProposal.Change) -> String {
        switch change {
        case .direction(let d):
            var lines = ["标题：\(d.title)", "理由：\(oneLine(d.reason))"]
            if let result = d.result, !result.isEmpty { lines.append("执行结果：\(oneLine(result))") }
            if let content = d.contentProposalId { lines.append("交出的正文：\(proposalsFolder)/\(content).md") }
            return lines.joined(separator: "\n")
        case .newPage(let page):
            return "```\n" + page.markdown + "\n```"
        case .appendRecords(_, let lines):
            return lines.joined(separator: "\n")
        case .rewriteNow(_, let old, let new, let until):
            return "原来：\(old)\n\n改成：\(new)" + (until.map { "\n\n到 \($0) 该复核" } ?? "")
        case .link(_, let link):
            return "\(link.relation.rawValue)：\(oneLine(link.why))"
        case .retag(_, let oldHook, let newHook, let oldTriggers, let newTriggers):
            return "钩子：\(oldHook) → \(newHook)\n触发词：\(oldTriggers.joined(separator: "、")) → \(newTriggers.joined(separator: "、"))"
        case .regroup(_, let groups, let moves):
            return (groups.map { "新分组 \($0.path)：\(oneLine($0.hook))" } + moves.map { "\($0.from) → \($0.to)" }).joined(separator: "\n")
        case .confirmCovered:
            return "这页已经写过这些，不改页，只把用到的记忆条目标成整理过。"
        }
    }

    // MARK: - 一张要点卡

    /// 出自私人原料的不给（nil）
    static func noteText(_ card: SeedNoteCard) -> String? {
        guard !WikiProposalSources.isPrivate(card.path) else { return nil }
        var body = "# " + oneLine(card.title) + "\n\n" + card.gist
        if !card.mentions.isEmpty {
            body += "\n\n## 提到的\n\n" + card.mentions.map { m in
                "- \(m.name)（\(m.group)）" + ((m.aliases ?? []).isEmpty ? "" : "，也叫 " + (m.aliases ?? []).joined(separator: "、"))
            }.joined(separator: "\n")
        }
        if !card.when.isEmpty { body += "\n\n## 时间\n\n" + card.when.map { "- " + oneLine($0) }.joined(separator: "\n") }
        return FrontmatterCodec.render(meta: [
            ("source", card.path),
            ("name", oneLine(card.name)),
            ("layer", card.layer),
            ("group", card.group),
            ("about_user", card.aboutUser ? "yes" : "no"),
            ("made", timeFormatter.string(from: card.madeAt)),
            ("model", card.model),
        ], body: body)
    }
}
