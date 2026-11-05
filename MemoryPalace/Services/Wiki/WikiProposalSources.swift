import Foundation

/// 整理提案一个目录项的原料：一份一行（名称 + 层）+ 全文，只读（粟粟 10-23：「提案我也不能点进去，然后看每个原料是啥」）。
/// 正文先取种子任务这次实际读到的那一份（task.json 里 read 的回执，不重读盘）；「现在的样子」只拿来比版本，
/// 标「这份原料在提案之后改过」。现在的样子只取这一项列着的那几份，规则同种子原料那套白名单
/// （CC：cc 文件夹里的普通 .md、不跟链接、`readNoFollow`、`CatalogSeed.read`；Prompt 取楼层底图；wiki 页逐级不跟链接、索引走 `SafeWiki`；问卷取任务里的答案）。
/// private_ 开头的文件在最前面就滤掉：不列、不取回执、不读盘；wiki 文字里指向私人页的 `[[…]]` 行也剥掉。文件 IO，调用方放后台
enum WikiProposalSources {
    struct Source: Equatable, Sendable {
        var path: String
        var name: String
        /// CC / Prompt / wiki / 问卷 / 碎片
        var layer: String
        /// nil = 哪儿都没读到
        var text: String?
        /// 读到的和提案生成时不一样 / 清空了 / 现在不在了 / 现在读不了 / 没读到
        var note: String?
    }

    /// 一份原料现在的样子（astra 10-23 P2：不在 / 读失败 / 空要分开）
    enum Current: Equatable, Sendable {
        case present(text: String, version: String)
        case empty
        case missing
        case unreadable(String)
    }

    static let changedNote = "这份原料在提案之后改过"
    static let emptiedNote = "这份原料在提案之后改过（现在是空的）"
    static let goneNote = "这份原料现在已经不在了"
    static let missingNote = "没读到这份原料"
    static func unreadableNote(_ why: String) -> String { "这份原料现在读不了（\(why)）" }

    static let ccPrefix = "memory/\(CCMemorySync.subdir)/"

    /// 路径里任何一段以 private_ 开头（大小写不论）的一律不碰
    static func isPrivate(_ path: String) -> Bool {
        path.split(separator: "/").contains { CCMemorySync.isExcluded(name: String($0)) }
    }

    /// 文字里带 `[[私人页]]` 的那几行剥掉（历史 INDEX 回执 / 页里的连线）
    static func strippingPrivateLinks(_ text: String) -> String {
        guard text.range(of: "private_", options: .caseInsensitive) != nil else { return text }
        let lines = text.components(separatedBy: "\n")
        return lines.filter { !linksPrivate($0) }.joined(separator: "\n")
    }

    private static func linksPrivate(_ line: String) -> Bool {
        var rest = line[...]
        while let open = rest.range(of: "[[") {
            guard let close = rest[open.upperBound...].range(of: "]]") else { return false }
            if isPrivate(String(rest[open.upperBound..<close.lowerBound])) { return true }
            rest = rest[close.upperBound...]
        }
        return false
    }

    // MARK: - 回执

    /// 一次扫完任务的 read 回执：路径 → 实际读到的全文（同 `CatalogSeedTask.readText`：同一路径取第一次成功的那一份）
    static func receipts(_ task: CatalogSeedTask) -> [String: String] {
        var out: [String: String] = [:]
        for turn in task.turns {
            for call in turn.calls where call.name == CatalogSeedTools.read {
                guard let path = CatalogJSON.decode(CatalogSeedTools.Args.self, call.argumentsJSON)?.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                      out[path] == nil,
                      let result = turn.results.first(where: { $0.toolUseId == call.id && !$0.isError }),
                      let cut = result.text.firstIndex(of: "\n") else { continue }
                out[path] = String(result.text[result.text.index(after: cut)...])
            }
        }
        return out
    }

    // MARK: - 现在的样子（只取列着的这几份）

    /// `layers`：路径 → 层（取自任务清单，没有就按路径猜）。Prompt 没给底图 = 现状未知，不出现在结果里
    static func current(paths: [String], layers: [String: String], task: CatalogSeedTask?, floorBase: CatalogFloorBase?,
                        memoryRoot: URL, wiki: WikiStore) -> [String: Current] {
        current(paths: paths, layers: layers, task: task, floorBase: floorBase, memoryRoot: memoryRoot, wiki: wiki, check: {})
    }

    static func current(paths: [String], layers: [String: String], task: CatalogSeedTask?, floorBase: CatalogFloorBase?,
                        memoryRoot: URL, wiki: WikiStore, check: () throws -> Void) rethrows -> [String: Current] {
        var out: [String: Current] = [:]
        var safe: SafeWiki?
        for path in paths where !isPrivate(path) {
            try check()
            switch layers[path] ?? guessLayer(path) {
            case "CC":
                out[path] = cc(path, memoryRoot: memoryRoot)
            case "wiki":
                if CatalogSeedMaterials.pagePath(path) != nil {
                    out[path] = wikiPage(path, wiki: wiki, memoryRoot: memoryRoot)
                } else if let folder = CatalogSeedMaterials.indexFolder(path) {
                    if safe == nil { safe = try SafeWiki.scan(wiki, memoryRoot: memoryRoot, check: check) }
                    out[path] = index(folder, safe: safe ?? SafeWiki())
                } else {
                    out[path] = .missing
                }
            case CatalogSurvey.layer:
                let day = CatalogSurvey.day(task?.createdAt ?? Date())
                out[path] = (task?.answers ?? []).first { $0.path == path }.map { a in
                    let text = CatalogSurvey.answerText(a, day: day)
                    return .present(text: text, version: WikiStore.version(of: Data(text.utf8)))
                } ?? .missing
            default:
                guard let floorBase else { continue }
                guard let s = floorBase.sections.first(where: { $0.path == path }) else { out[path] = .missing; continue }
                out[path] = s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .empty : .present(text: s.text, version: WikiStore.version(of: Data(s.text.utf8)))
            }
        }
        return out
    }

    /// lstat 看到的类型（不跟链接）；不存在 = nil，别的错 = 抛
    private static func itemType(_ url: URL) throws -> FileAttributeType? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    private static func inside(_ url: URL, _ root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// 同 `CatalogSeed.load` 的规矩：cc 是这层楼里真实的文件夹，文件是它下面一层的普通 .md、不是链接
    static func cc(_ path: String, memoryRoot: URL) -> Current {
        guard path.hasPrefix(ccPrefix) else { return .missing }
        let name = String(path.dropFirst(ccPrefix.count))
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), name.lowercased().hasSuffix(".md"),
              !CCMemorySync.isExcluded(name: name) else { return .missing }
        let dir = memoryRoot.appendingPathComponent(CCMemorySync.subdir, isDirectory: true)
        let file = dir.appendingPathComponent(name)
        do {
            guard let dirType = try itemType(dir) else { return .missing }
            guard dirType == .typeDirectory, inside(dir, memoryRoot) else { return .unreadable("CC 文件夹是链接或不在这层楼里") }
            guard let type = try itemType(file) else { return .missing }
            guard type == .typeRegular else { return .unreadable("不是普通文件") }
            let source = try CatalogSeed.read(name: name, text: CCMemorySync.readNoFollow(file))
            let text = CatalogSeedMaterials.ccText(source)
            return .present(text: text, version: WikiStore.version(of: Data(text.utf8)))
        } catch CatalogSeed.Skip.empty {
            return .empty
        } catch {
            return .unreadable((error as? CatalogSeed.Skip)?.rawValue ?? error.localizedDescription)
        }
    }

    /// 一页：wiki 根和路径上每一级都不能是链接、不出根（同 `SafeWiki`），版本按原始字节算（同 `SafeWiki`）
    static func wikiPage(_ path: String, wiki: WikiStore, memoryRoot: URL) -> Current {
        guard let page = CatalogSeedMaterials.pagePath(path) else { return .missing }
        do {
            guard let rootType = try itemType(wiki.root) else { return .missing }
            guard rootType == .typeDirectory, inside(wiki.root, memoryRoot) else { return .unreadable("wiki 文件夹是链接或不在这层楼里") }
            var url = wiki.root
            let parts = (page + ".md").split(separator: "/").map(String.init)
            for (i, part) in parts.enumerated() {
                url = url.appendingPathComponent(part)
                guard let type = try itemType(url) else { return .missing }
                if type == .typeSymbolicLink { return .unreadable("是链接") }
                guard type == (i == parts.count - 1 ? .typeRegular : .typeDirectory) else { return .unreadable("不是普通文件") }
            }
            let data = try Data(contentsOf: url)
            if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
            return .present(text: strippingPrivateLinks(String(decoding: data, as: UTF8.self)), version: WikiStore.version(of: data))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// 一层索引：同种子收集（这一层下面有页才有索引）
    static func index(_ folder: String, safe: SafeWiki) -> Current {
        if let refused = safe.refused { return .unreadable(refused) }
        guard folder.isEmpty || safe.folders.contains(folder), safe.count(under: folder) > 0 else { return .missing }
        let text = safe.index(folder)
        return .present(text: text, version: WikiStore.version(of: Data(text.utf8)))
    }

    // MARK: - 拼一项的原料

    /// 种子目录项的原料（顺序照目录项列的，重复的只列一次）。`receipts` 由 `receipts(_:)` 取，`current` 由 `current(...)` 取
    static func seed(paths: [String], task: CatalogSeedTask?, receipts: [String: String], current: [String: Current]) -> [Source] {
        var seen = Set<String>()
        var out: [Source] = []
        for raw in paths {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !isPrivate(path), seen.insert(path).inserted else { continue }
            let material = task?.materials.first { $0.path == path }
            let layer = material?.layer ?? guessLayer(path)
            let name = material?.name ?? (path as NSString).lastPathComponent
            let readVersion = task?.read[path].flatMap { $0.isEmpty ? nil : $0 } ?? material?.version
            var text = receipts[path]
            var note: String?
            switch current[path] {
            case .present(let now, let version)?:
                if text == nil { text = now } else if let readVersion, readVersion != version { note = changedNote }
            case .empty?:
                note = emptiedNote
            case .missing?:
                note = text == nil ? missingNote : goneNote
            case .unreadable(let why)?:
                note = unreadableNote(why)
            case nil:
                break
            }
            if text == nil, note == nil { note = missingNote }
            if layer == "wiki" { text = text.map(strippingPrivateLinks) }
            out.append(Source(path: path, name: name, layer: layer, text: text, note: note))
        }
        return out
    }

    /// 任务清单里这几份的层（没有就按路径猜）
    static func layers(_ paths: [String], task: CatalogSeedTask?) -> [String: String] {
        var out: [String: String] = [:]
        for p in paths { out[p] = task?.materials.first { $0.path == p }?.layer ?? guessLayer(p) }
        return out
    }

    static func guessLayer(_ path: String) -> String {
        if path.hasPrefix(ccPrefix) { return "CC" }
        if path.hasPrefix(CatalogSeedMaterials.wikiPrefix) { return "wiki" }
        if path.hasPrefix(CatalogSurvey.prefix) { return CatalogSurvey.layer }
        return "Prompt"
    }

    /// 卡片列表头上的一行：「原料 12 份 · CC 7 · wiki 4 · Prompt 1」
    static func tally(_ sources: [Source]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for s in sources {
            if counts[s.layer] == nil { order.append(s.layer) }
            counts[s.layer, default: 0] += 1
        }
        return (["原料 \(sources.count) 份"] + order.map { "\($0) \(counts[$0] ?? 0)" }).joined(separator: " · ")
    }
}

/// 种子任务的解析结果 + 回执索引：同一份 task.json 没改过就复用（目录 65 项挨个点进去，不每次重新解码整份任务）
final class SeedTaskCache: @unchecked Sendable {
    static let shared = SeedTaskCache()

    private struct Entry {
        let file: String
        let stamp: Date
        let task: CatalogSeedTask
        let receipts: [String: String]
    }

    private let lock = NSLock()
    private var entry: Entry?

    func load(_ id: String, store: CatalogSeedTaskStore) -> (task: CatalogSeedTask, receipts: [String: String])? {
        guard UUID(uuidString: id) != nil else { return nil }
        let file = store.folder(id).appendingPathComponent(CatalogSeedTaskStore.fileName).path
        let stamp = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
        if let stamp, let hit = lock.withLock({ entry.flatMap { $0.file == file && $0.stamp == stamp ? $0 : nil } }) {
            return (hit.task, hit.receipts)
        }
        guard let task = store.load(id) else { return nil }
        let receipts = WikiProposalSources.receipts(task)
        if let stamp { lock.withLock { entry = Entry(file: file, stamp: stamp, task: task, receipts: receipts) } }
        return (task, receipts)
    }
}
