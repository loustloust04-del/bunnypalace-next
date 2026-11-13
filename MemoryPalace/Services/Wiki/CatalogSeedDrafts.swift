import MemoryCore
import Foundation
import SwiftData

/// 文件库里的「种子待批」（第 6 段 C-13）：把同一份待批提案映射成可编辑的「目录」和各页草稿，不另存一份文件。
/// 保存走 WikiProposalReview（同一把审批锁），审计台读的是同一份；已批只读，驳回修稿保存后回待批；改完重新校验出处和页版本
enum CatalogSeedDrafts {
    static let root = FileLibraryMemoryFolder.wikiFolder + "/.seed"
    static let outlineFileName = "目录.md"

    enum Kind: Equatable, Sendable {
        case outline(String)
        case page(proposalId: String, itemId: String)
    }

    struct Entry: Equatable, Identifiable, Sendable {
        var path: String
        var name: String
        var content: String
        var editable: Bool
        var kind: Kind
        /// 这个任务的文件夹（`memory/wiki/.seed/<任务 id>`）和它的显示名
        var folder: String
        var folderName: String
        var id: String { path }
    }

    enum EditError: LocalizedError, Equatable {
        case conflict
        case gone
        case readOnly(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .conflict: return "这份草稿在别处改过了（审计台 › wiki › 整理提案或种子任务），请关闭重开后再改。"
            case .gone: return "这份草稿已经不在了。"
            case .readOnly(let why): return why
            case .invalid(let why): return why
            }
        }
    }

    static func isSeedPath(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    static func isOutline(_ p: WikiProposal) -> Bool {
        p.origin == .seed && p.items.contains { $0.change.direction?.mode == .seed }
    }

    /// 种子任务的提案（目录 / 正文）：改稿要走种子校验
    static func isSeedProposal(_ p: WikiProposal) -> Bool { p.seedTask != nil || isOutline(p) }

    static func canEditOutlineItem(_ item: WikiProposal.Item, task: CatalogSeedTask?) -> Bool {
        guard item.change.direction?.mode == .seed, let task,
              task.state != .complete, task.state != .abandoned, task.state != .ended,
              item.reviewHistory?.last(where: { $0.kind == .rejected })?.origin != .abandonedSeed else { return false }
        return true
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    /// 后台读：每个种子目录一个文件夹（目录 + 已交的各页草稿）
    static func entries(wiki: WikiStore) -> [Entry] {
        let all = WikiProposalStore(wiki: wiki).list()
        var out: [Entry] = []
        for outline in all where isOutline(outline) {
            let folder = root + "/" + outline.id
            let folderName = (outline.title ?? "种子目录") + " · " + stamp(outline.createdAt)
            let task = CatalogSeedTaskStore(wiki: wiki).load(outline.seedTask ?? outline.id)
            out.append(Entry(path: folder + "/" + outlineFileName, name: "目录", content: outlineText(outline),
                             editable: outline.items.contains {
                                 ($0.state == .pending || $0.state == .rejected) && canEditOutlineItem($0, task: task)
                             },
                             kind: .outline(outline.id), folder: folder, folderName: folderName))
            for page in all where page.directionRef?.proposalId == outline.id && page.id != outline.id {
                for item in page.items {
                    let text = pageText(item)
                    out.append(Entry(path: folder + "/\(page.id).\(item.id).md", name: (item.state == .rejected ? "重新编辑 · " : "") + "\(page.title ?? "") · \(item.change.kindLabel)",
                                     content: text ?? readOnlyText(item), editable: text != nil && (item.state == .pending || item.state == .rejected),
                                     kind: .page(proposalId: page.id, itemId: item.id), folder: folder, folderName: folderName))
                }
            }
        }
        return out
    }

    // MARK: - 目录

    private static func stateLabel(_ state: WikiProposal.Item.State) -> String {
        switch state {
        case .pending: return "待批"
        case .approved: return "已批"
        case .rejected: return "驳回"
        case .stale: return "页已变"
        }
    }

    static func outlineText(_ p: WikiProposal) -> String {
        var out = "# \(p.title ?? "种子目录")\n\n改「路径 / 类 / 标题 / 钩子 / 原料」后保存，审计台 › wiki › 整理提案看到的是同一份；已批的项只读，驳回项重新编辑并保存后回待批，不会自动批。这里不能加项、删项（不要的去审计台 › wiki › 整理提案驳回）。\n"
        var n = 0
        for item in p.items {
            guard let d = item.change.direction, d.mode == .seed else { continue }
            n += 1
            out += "\n## \(n). \(d.title)（\(stateLabel(item.state))）\n"
            out += "id: \(item.id)\n路径: \(d.path)\n类: \(d.kind?.rawValue ?? "")\n标题: \(d.title)\n钩子: \(d.hook)\n原料:\n"
            out += (d.sources ?? []).map { "- \($0)\n" }.joined()
        }
        return out
    }

    private struct Block {
        var number: Int
        var fields: [String: String] = [:]
        var sources: [String] = []
    }

    /// 解析改过的目录：只认原有的项（按 id），改动走同一道种子校验；动了已批的、删了项都报错，一项都不改
    static func parseOutline(_ text: String, outline: WikiProposal, task: CatalogSeedTask?, wiki: WikiStore) throws -> [String: WikiProposal.Change] {
        var blocks: [Block] = []
        var inSources = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                blocks.append(Block(number: blocks.count + 1))
                inSources = false
                continue
            }
            guard !blocks.isEmpty, !line.isEmpty else { continue }
            if inSources, line.hasPrefix("- ") {
                blocks[blocks.count - 1].sources.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }
            guard let sep = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let key = line[..<sep].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            inSources = key == "原料"
            if !inSources { blocks[blocks.count - 1].fields[key] = value }
        }
        var changes: [String: WikiProposal.Change] = [:]
        var seen = Set<String>()
        for b in blocks {
            guard let id = b.fields["id"], let item = outline.items.first(where: { $0.id == id }),
                  case .direction(let d) = item.change, d.mode == .seed else {
                throw EditError.invalid("第 \(b.number) 项的 id 对不上目录里的项，别改 id 那一行")
            }
            seen.insert(id)
            var new = d
            new.path = b.fields["路径"] ?? d.path
            new.kind = WikiPage.Kind(rawValue: b.fields["类"] ?? "")
            new.title = b.fields["标题"] ?? ""
            new.hook = b.fields["钩子"] ?? ""
            new.sources = b.sources
            if new.path == d.path, new.kind == d.kind, new.title == d.title, new.hook == d.hook, WikiStore.normalizedWords(b.sources) == (d.sources ?? []) { continue }
            guard item.state == .pending || item.state == .rejected else { throw EditError.readOnly("第 \(b.number) 项「\(d.title)」\(stateLabel(item.state))了，只读") }
            do {
                changes[id] = item.state == .rejected ? .direction(new) : try validate(.direction(new), original: item, task: task, wiki: wiki)
            } catch let error as EditError {
                throw EditError.invalid("第 \(b.number) 项：" + (error.errorDescription ?? ""))
            }
        }
        let missing = outline.items.filter { $0.change.direction?.mode == .seed && !seen.contains($0.id) }
        if let first = missing.first?.change.direction {
            throw EditError.invalid("目录里少了「\(first.title)」这一项：这里不能删项，不要的去审计台 › wiki › 整理提案驳回")
        }
        return changes
    }

    // MARK: - 页草稿

    /// 能改的：新开页（整页）、追加的记录（一行一条）、新的「现在」；别的种只读
    static func pageText(_ item: WikiProposal.Item) -> String? {
        switch item.change {
        case .newPage(let page): return page.markdown
        case .appendRecords(_, let lines): return lines.joined(separator: "\n")
        case .rewriteNow(_, _, let new, _): return new
        default: return nil
        }
    }

    static func readOnlyText(_ item: WikiProposal.Item) -> String {
        switch item.change {
        case .link(let from, let link): return "\(from) → \(link.target) · \(link.relation.rawValue)" + (link.why.isEmpty ? "" : " · \(link.why)")
        case .retag(let path, let oldHook, let newHook, let oldTriggers, let newTriggers):
            return "\(path)\n钩子：\(oldHook) → \(newHook)\n触发词：\(oldTriggers.joined(separator: "、")) → \(newTriggers.joined(separator: "、"))\n（这一种在审计台 › wiki › 整理提案用「改」）"
        default: return item.change.kindLabel
        }
    }

    /// 这一条原来就有的出处
    static func allowed(_ item: WikiProposal.Item) -> Set<String> {
        Set(item.cites.map(CatalogSources.label) + item.fragmentIds.map(CatalogSources.label))
    }

    static func checkVersion(_ path: String, item: WikiProposal.Item, wiki: WikiStore) throws {
        guard wiki.version(of: path) == item.baseVersion else { throw EditError.invalid("「\(path)」在提案之后改过了（页已变），不能再改这条") }
    }

    static func accepts(sourceDomain: SeedFactDomain?, pageDomain: SeedFactDomain?) -> Bool {
        switch pageDomain {
        case .realWorld: return sourceDomain == .realWorld
        case .inWorld: return sourceDomain == .inWorld
        case .mixed, .unspecified: return sourceDomain == .mixed || sourceDomain == .unspecified || sourceDomain == nil
        case nil: return true // 旧目录未声明域，不推断域，也不新增改稿限制。
        }
    }

    /// 种子提案改稿的唯一入口（文件库、审计台「改」都走它）：目录项过同一道路径 / 八类 / 原料（必须读过）校验；
    /// 正文条目路径不能改、出处只能是原有的、已有页版本要对得上、新开页不能已存在、至少留一行记录（可以是手写行）
    static func validate(_ change: WikiProposal.Change, original item: WikiProposal.Item, task: CatalogSeedTask?, wiki: WikiStore,
                         conversions: [CatalogSources.Conversion] = []) throws -> WikiProposal.Change {
        if item.change.direction == nil, let path = item.change.targetPath {
            try WikiProposalReview.requireSettled(path, store: WikiProposalStore(wiki: wiki))
        }
        switch (item.change, change) {
        case (.direction(let old), .direction(var new)) where old.mode == .seed:
            new.factDomain = old.factDomain
            let targetPath = CatalogPrompts.normalizedPath(new.path)
            let targetVersion = task?.read[CatalogSeedMaterials.wikiPath(targetPath)]
            let targetExists = wiki.pageExists(targetPath)
            if targetExists, targetVersion?.isEmpty != false {
                throw EditError.invalid("这页已存在但不在本次任务快照里，不能现场读活页")
            }
            if let domain = new.factDomain, let task {
                let oldSources = Set(WikiStore.normalizedWords(old.sources ?? []))
                let store = SeedNoteStore(wiki: wiki)
                for (index, path) in WikiStore.normalizedWords(new.sources ?? []).enumerated() where !oldSources.contains(path) {
                    let material = task.materials.first { $0.path == path }
                    var card: SeedNoteCard?
                    if let material, let version = task.read[path], !version.isEmpty, task.carded?[path] == version {
                        card = store.load(path: path, version: version)
                        let contextIssue = card?.contextIssue(for: material.sourceContext)
                        card?.sourceContextIssue = contextIssue
                    }
                    let sourceDomain = card?.effectiveFactDomain
                    guard accepts(sourceDomain: sourceDomain, pageDomain: domain) else {
                        let sourceLabel = sourceDomain == .realWorld ? "现实卡" : sourceDomain == .inWorld ? "设定卡" : "待判卡"
                        let pageLabel = domain == .realWorld ? "现实页" : domain == .inWorld ? "设定页" : "待判页"
                        throw EditError.invalid("第 \(index + 1) 份原料「\(card?.title ?? material?.name ?? path)」是\(sourceLabel)，不能进\(pageLabel)")
                    }
                }
            }
            switch CatalogSeedTools.checkDirection(new, task: task, wiki: wiki) {
            case .success(var d):
                if targetVersion?.isEmpty == false, !targetExists {
                    throw EditError.invalid("「\(d.path)」在提案之后被删了（页已变），不能再改这条")
                }
                d.action = targetVersion?.isEmpty == false ? .update : .newPage
                return .direction(d)
            case .failure(let error): throw error
            }
        case (.newPage(let old), .newPage(var page)):
            guard !wiki.pageExists(old.path) else { throw EditError.invalid("「\(old.path)」这页已经有了，不能再新开（页已变）") }
            page.path = old.path
            page.kind = old.kind
            page.factDomain = old.factDomain
            guard !page.records.isEmpty else { throw EditError.invalid("没有记录了；不要这条就去审计台 › wiki › 整理提案驳回") }
            page.records = try CatalogSources.checkEdited(page.records, original: old.records, allowed: allowed(item), conversions: conversions)
            return .newPage(page: page)
        case (.appendRecords(let path, let old), .appendRecords(_, let lines)):
            try checkVersion(path, item: item, wiki: wiki)
            guard !lines.isEmpty else { throw EditError.invalid("没有记录了；不要这条就去审计台 › wiki › 整理提案驳回") }
            return .appendRecords(path: path, lines: try CatalogSources.checkEdited(lines, original: old, allowed: allowed(item), conversions: conversions))
        case (.rewriteNow(let path, let old, _, let until), .rewriteNow(_, _, let new, _)):
            try checkVersion(path, item: item, wiki: wiki)
            let text = new.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw EditError.invalid("「现在」不能是空的") }
            return .rewriteNow(path: path, old: old, new: text, until: WikiPage.until(until, in: text))
        case (.link(let from, let oldLink), .link(_, var link)):
            try checkVersion(from, item: item, wiki: wiki)
            link.target = oldLink.target
            link.relation = oldLink.relation
            return .link(from: from, link: link)
        case (.retag(let path, let oldHook, _, let oldTriggers, _), .retag(_, _, let newHook, _, let newTriggers)):
            try checkVersion(path, item: item, wiki: wiki)
            return .retag(path: path, oldHook: oldHook, newHook: newHook, oldTriggers: oldTriggers, newTriggers: newTriggers)
        default:
            throw EditError.readOnly("这一条不能这样改")
        }
    }

    static func parsePage(_ text: String, item: WikiProposal.Item, task: CatalogSeedTask?, wiki: WikiStore) throws -> WikiProposal.Change {
        try validate(pageChange(text, item: item), original: item, task: task, wiki: wiki)
    }

    private static func pageChange(_ text: String, item: WikiProposal.Item) throws -> WikiProposal.Change {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
        switch item.change {
        case .newPage(let old): return .newPage(page: WikiPage.parse(text, path: old.path))
        case .appendRecords(let path, _): return .appendRecords(path: path, lines: lines)
        case .rewriteNow(let path, let old, _, let until): return .rewriteNow(path: path, old: old, new: text, until: until)
        default: throw EditError.readOnly("这一种在审计台 › wiki › 整理提案用「改」")
        }
    }

    /// 文件库保存：读、和打开时看到的比、校验、写回，全在同一次审批锁里（等锁期间别处改了也拒，不盖掉）
    @MainActor
    /// userName = 楼层用户名：编辑器里显示的是本人那组换成名字的（`WikiStore.shown`），比对、解析前换回落盘写法
    @discardableResult
    static func save(_ entry: Entry, text: String, baseline: String, wiki: WikiStore, userName: String = "",
                     profileId: String, context: ModelContext) async throws -> String? {
        let store = WikiProposalStore(wiki: wiki)
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        let same: @Sendable (String) -> Bool = { $0 == baseline || WikiStore.shown($0, user: userName) == baseline }
        let notice = try await WikiProposalReview.exclusive(store) {
            let prepared = try await Task.detached(priority: .userInitiated) { () throws -> (String, [WikiProposalReview.ReopenEdit], Bool) in
                switch entry.kind {
                case .outline(let id):
                    guard let current = store.load(id) else { throw EditError.gone }
                    guard same(outlineText(current)) else { throw EditError.conflict }
                    let edited = WikiStore.storedEdit(text, original: outlineText(current), user: userName) { storedDraftLine($0, user: userName) }
                    let changes = try parseOutline(edited, outline: current, task: tasks.load(current.seedTask ?? id), wiki: wiki)
                    let edits = current.items.compactMap { item -> WikiProposalReview.ReopenEdit? in
                        guard let change = changes[item.id] else { return nil }
                        return .init(itemId: item.id, change: change, baseline: item.change, judgment: item.judgment)
                    }
                    return (id, edits, current.items.contains { $0.state == .rejected && changes[$0.id] != nil })
                case .page(let proposalId, let itemId):
                    guard let proposal = store.load(proposalId), let item = proposal.items.first(where: { $0.id == itemId }) else { throw EditError.gone }
                    guard let current = pageText(item), same(current) else { throw EditError.conflict }
                    let edited = WikiStore.storedEdit(text, original: current, user: userName)
                    guard item.state == .pending || item.state == .rejected else { throw EditError.readOnly("这一条已经处理过了，只读") }
                    let change = item.state == .rejected ? try pageChange(edited, item: item)
                        : try parsePage(edited, item: item, task: proposal.seedTask.flatMap(tasks.load), wiki: wiki)
                    return (proposalId, [.init(itemId: itemId, change: change, baseline: item.change, judgment: item.judgment)], item.state == .rejected)
                }
            }.value
            if prepared.2 {
                return try await WikiProposalReview.saveReopened(prepared.0, edits: prepared.1, requiringRejected: false,
                    store: store, profileId: profileId, context: context).notice
            }
            let changes = Dictionary(uniqueKeysWithValues: prepared.1.map { ($0.itemId, $0.change) })
            if !changes.isEmpty {
                _ = try await Task.detached(priority: .userInitiated) { try store.edit(prepared.0, changes: changes) }.value
            }
            return Optional<String>.none
        }
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        return notice
    }

    /// 目录草稿里改过的一行还原成落盘写法：「路径:」行、原料清单行（`- …`）按路径还原；别的行同正文（[[双链]] / 出处）
    static func storedDraftLine(_ line: String, user: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        for key in ["路径:", "路径："] where t.hasPrefix(key) {
            return key + " " + WikiStore.stored(t.dropFirst(key.count).trimmingCharacters(in: .whitespaces), user: user)
        }
        if t.hasPrefix("- "), !t.hasPrefix("- [[") {
            return "- " + WikiStore.stored(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces), user: user)
        }
        return WikiStore.storedLine(line, user: user)
    }

    /// 审计台「改」种子提案：同一把锁里比对她打开时那一版、过同一道校验再写
    @MainActor
    @discardableResult
    static func saveChange(_ proposalId: String, itemId: String, change: WikiProposal.Change, baseline: WikiProposal.Change,
                           wiki: WikiStore, conversions: [CatalogSources.Conversion] = []) async throws -> WikiProposal {
        let store = WikiProposalStore(wiki: wiki)
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        let saved = try await WikiProposalReview.exclusive(store) {
            try await Task.detached(priority: .userInitiated) { () throws -> WikiProposal in
                guard let proposal = store.load(proposalId), let item = proposal.items.first(where: { $0.id == itemId }) else { throw EditError.gone }
                guard item.change == baseline else { throw EditError.conflict }
                guard item.state == .pending else { throw EditError.readOnly("这一条已经处理过了，只读") }
                let checked = try validate(change, original: item, task: proposal.seedTask.flatMap(tasks.load), wiki: wiki, conversions: conversions)
                return try store.edit(proposalId, itemId: itemId, change: checked, judgment: item.judgment, conversions: conversions)
            }.value
        }
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        return saved
    }
}
