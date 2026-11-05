import CryptoKit
import Foundation

// MARK: - 种子（C2/C3 v2 第 6 段）：一个 CatalogAgent 任务，全读一次 → 目录待批暂停 → 同一任务逐页写 → 正文再批

/// 入口共用同一个任务机制（目录 / 正文两批），只记是从哪进来的；survey = 新用户三问（原料只有这次的答案）
enum CatalogSeedEntry: String, Codable, Sendable {
    case cc, persona, survey

    var label: String {
        switch self {
        case .cc: return "CC 记忆"
        case .persona: return "人设"
        case .survey: return "新用户三问"
        }
    }
}

/// 这一次能读的原料（白名单）：Prompt 里人填的全部文字、CC 记忆文件、现有 wiki 各层索引和每页全文。每份都是完整的。
/// wiki 只认楼层 wiki 根里真实的文件夹 / 文件：符号链接（文件或文件夹）一律不收，真实路径必须还在这层楼的 wiki 里
struct CatalogSeedMaterials: Sendable {
    struct Item: Equatable, Sendable {
        var path: String
        var name: String
        /// Prompt / CC / wiki
        var layer: String
        var text: String
        var version: String
    }

    static let wikiPrefix = "memory/wiki/"
    static let wikiIndexPath = wikiPrefix + WikiStore.indexFileName

    var items: [Item] = []
    /// 没读的（CC 跳过的、private_ 只有数量；wiki 根是链接时的说明）
    var skipped: [String] = []

    static func wikiPath(_ page: String) -> String { wikiPrefix + page + ".md" }

    static func indexPath(_ folder: String) -> String {
        folder.isEmpty ? wikiIndexPath : wikiPrefix + folder + "/" + WikiStore.indexFileName
    }

    /// `memory/wiki/楼层/人/阿青.md` → `楼层/人/阿青`
    static func pagePath(_ path: String) -> String? {
        guard path.hasPrefix(wikiPrefix), path.hasSuffix(".md") else { return nil }
        let page = String(path.dropFirst(wikiPrefix.count).dropLast(3))
        return WikiStore.isValidPagePath(page) ? page : nil
    }

    /// `memory/wiki/楼层/人/INDEX.md` → `楼层/人`（根索引 = ""）
    static func indexFolder(_ path: String) -> String? {
        if path == wikiIndexPath { return "" }
        let tail = "/" + WikiStore.indexFileName
        guard path.hasPrefix(wikiPrefix), path.hasSuffix(tail) else { return nil }
        let folder = String(path.dropFirst(wikiPrefix.count).dropLast(tail.count))
        return WikiStore.isValidFolderPath(folder) ? folder : nil
    }

    /// 后台读；Prompt 底图要在主线程先取好传进来（PresetManager 在主线程）
    static func gather(floorBase: CatalogFloorBase?, memoryRoot: URL, wiki: WikiStore) throws -> CatalogSeedMaterials {
        var out = CatalogSeedMaterials()
        for s in floorBase?.sections ?? [] where !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.items.append(Item(path: s.path, name: s.name + (s.isEnabled == false ? "（已关闭）" : ""), layer: "Prompt",
                                  text: s.text, version: WikiStore.version(of: Data(s.text.utf8))))
        }
        let scan = try CatalogSeed.load(memoryRoot: memoryRoot)
        out.skipped = scan.skipped
        for s in scan.sources {
            let text = ccText(s)
            out.items.append(Item(path: s.path, name: s.title, layer: "CC", text: text, version: WikiStore.version(of: Data(text.utf8))))
        }
        out.addWiki(wiki, memoryRoot: memoryRoot)
        return out
    }

    /// 一份 CC 原料给模型看的正文（详情页比现状版本也用这一份拼法）
    static func ccText(_ s: CatalogSeed.Source) -> String {
        "类型：\(s.type)\n标题：\(s.title)\n\n" + s.body
    }

    /// wiki 各层索引 + 每页全文（只认 SafeWiki 扫出来的真实文件）
    mutating func addWiki(_ wiki: WikiStore, memoryRoot: URL) {
        let safe = SafeWiki.scan(wiki, memoryRoot: memoryRoot)
        if let note = safe.refused { skipped.append(note) }
        if !safe.pages.isEmpty {
            for folder in [""] + safe.folders where safe.count(under: folder) > 0 {
                let text = safe.index(folder)
                items.append(Item(path: Self.indexPath(folder), name: folder.isEmpty ? "wiki 根索引" : "wiki 索引 · \(folder)", layer: "wiki",
                                  text: text, version: WikiStore.version(of: Data(text.utf8))))
            }
        }
        for page in safe.pages {
            items.append(Item(path: Self.wikiPath(page.path), name: page.page.title, layer: "wiki", text: page.text, version: page.version))
        }
    }
}

/// 只认楼层 wiki 根里真实存在的普通文件 / 文件夹（不跟符号链接、不出根），索引也按这份算，不借 WikiStore 的读页（它会跟链接）。
/// 名字以 private_ 开头（不分大小写，`CCMemorySync.isExcluded`）的页和文件夹在打开之前就跳过：不读正文、不进索引（astra 10-23 P1）
struct SafeWiki: Sendable {
    struct Page: Sendable {
        var path: String
        var text: String
        var version: String
        var page: WikiPage
    }

    var pages: [Page] = []
    /// 真实的分组文件夹（含两支），按路径排
    var folders: [String] = []
    var hooks: [String: String] = [:]
    /// wiki 根本身不可信时的说明
    var refused: String?

    private static let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]

    static func isPlainFile(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
        return v.isRegularFile == true && v.isSymbolicLink != true
    }

    static func scan(_ wiki: WikiStore, memoryRoot: URL) -> SafeWiki {
        scan(wiki, memoryRoot: memoryRoot, check: {})
    }

    /// `check`：每个文件之前调一次（详情页离开时取消用）；种子走上面那个不传的
    static func scan(_ wiki: WikiStore, memoryRoot: URL, check: () throws -> Void) rethrows -> SafeWiki {
        var out = SafeWiki()
        let root = wiki.root
        guard let rootValues = try? root.resourceValues(forKeys: Set(keys)) else { return out }
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let realMemory = memoryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true, realRoot.hasPrefix(realMemory + "/") else {
            out.refused = "wiki 文件夹是链接或不在这层楼里，没读"
            return out
        }
        let base = root.standardizedFileURL.path + "/"
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in en {
            try check()
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if CCMemorySync.isExcluded(name: url.lastPathComponent) {
                if v.isDirectory == true { en.skipDescendants() }
                continue
            }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            let rel = String(full.dropFirst(base.count))
            if v.isSymbolicLink == true {
                if v.isDirectory == true { en.skipDescendants() }
                continue
            }
            guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(realRoot + "/") else {
                if v.isDirectory == true { en.skipDescendants() }
                continue
            }
            if v.isDirectory == true {
                if WikiStore.isValidFolderPath(rel) {
                    out.folders.append(rel)
                    let group = url.appendingPathComponent(WikiStore.groupFileName)
                    if isPlainFile(group), let data = try? Data(contentsOf: group) {
                        var lines = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                        if let hook = WikiPage.frontmatter(&lines)["钩子"], !hook.isEmpty { out.hooks[rel] = hook }
                    }
                } else {
                    en.skipDescendants()
                }
                continue
            }
            guard v.isRegularFile == true, rel.hasSuffix(".md"), url.lastPathComponent != WikiStore.indexFileName else { continue }
            let page = String(rel.dropLast(3))
            guard WikiStore.isValidPagePath(page), let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            out.pages.append(Page(path: page, text: text, version: WikiStore.version(of: data), page: WikiPage.parse(text, path: page)))
        }
        out.pages.sort { $0.path < $1.path }
        out.folders.sort()
        return out
    }

    private static func parent(_ path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    func count(under folder: String) -> Int {
        folder.isEmpty ? pages.count : pages.filter { $0.path.hasPrefix(folder + "/") }.count
    }

    private func lines(_ folder: String) -> [String] {
        var out: [String] = []
        for sub in folders where Self.parent(sub) == folder {
            let n = count(under: sub)
            guard n > 0 else { continue }
            out.append("- [[\(sub)/]] \(sub.split(separator: "/").last ?? "")" + (hooks[sub].map { " — \($0)" } ?? "") + "（\(n) 页）")
        }
        for p in pages where Self.parent(p.path) == folder {
            out.append("- [[\(p.path)]] \(p.page.title)" + (p.page.hook.isEmpty ? "" : " — \(p.page.hook)"))
        }
        return out
    }

    /// 按真实文件算的这一层索引（形状同生成的 INDEX.md）
    func index(_ folder: String) -> String {
        guard !folder.isEmpty else {
            var out = "# C 档案\n"
            for branch in WikiStore.branches {
                out += "\n## \(branch)（\(count(under: branch)) 页）\n" + lines(branch).map { $0 + "\n" }.joined()
            }
            return out
        }
        return "# \(folder)\n\n" + lines(folder).map { $0 + "\n" }.joined()
    }
}

/// 种子任务的 checkpoint（`wiki/.proposals/<任务 id>/task.json`；任务 id = 目录提案 id，本任务的提案也都在这个文件夹里）：
/// 完整 history / 工具回合（含实际回执和 provider 内容块）、收到还没处理完的那一轮、原料清单和读到的版本、跑到哪。
/// 目录交审后暂停，批准再从这里继续同一任务
struct CatalogSeedTask: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// 读原料、交目录
        case reading
        /// 目录交了 / 获批的页写完了，等批
        case waiting
        case writing
        /// 被停 / 出错 / 被拦 / 上下文超长：没完成，可以继续
        case stopped
        /// 空目录 / 目录全驳回：没完成，也没什么可写了
        case ended
        case complete
        case abandoned
    }

    struct Message: Codable, Equatable, Sendable {
        var role: String
        var content: String
    }

    struct Call: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var argumentsJSON: String
        var truncated: Bool
    }

    struct Result: Codable, Equatable, Sendable {
        var toolUseId: String
        var text: String
        var isError: Bool
    }

    /// 工具回合的小型持久 DTO：provider 内容块 / 思考原样存成 JSON，跟着调用一起说的正文也存
    struct Turn: Codable, Equatable, Sendable {
        var calls: [Call]
        var results: [Result]
        var assistantContent: Data? = nil
        var thinkingTokens: Int? = nil
        var reasoningField: String? = nil
        var reasoningText: String? = nil
        var reasoningDetails: Data? = nil
        var text: String? = nil
    }

    struct Material: Codable, Equatable, Sendable {
        var path: String
        var name: String
        var layer: String
        var version: String
    }

    var id: String
    var profileId: String
    var entry: CatalogSeedEntry
    /// 给人看的模型名
    var modelName: String
    /// 稳定的模型身份（`local:<id>` / `remote:<凭据>/<模型>`），续跑按它认，不按显示名
    var modelKey: String?
    var createdAt: Date
    var run: CatalogRunLink
    var state: State = .reading
    /// 上一次停下的原因（人话；上下文超长带服务商原文）
    var note: String? = nil
    /// 结束（完成 / 结束没完成 / 放弃）的时间：30 天留存从这里算
    var endedAt: Date? = nil
    var rounds = 0
    var history: [Message] = []
    var turns: [Turn] = []
    /// 模型回了工具调用、还没处理完就停了的那一轮：续跑先把它处理完（按调用 id 对账已经存下的产物），不重新问模型
    var pending: Turn? = nil
    /// 开工时的原料清单：交目录前每份都要读完
    var materials: [Material] = []
    /// 实际读过的：路径 → 读到的版本（读的时候已经不在了 = 空）
    var read: [String: String] = [:]
    var outlineSaved = false
    var skipped: [String] = []
    /// 交页时没过检查、已经打回过一次修订的目录项 id → 那一稿的原参数（修订用不了就交它）
    var revisionDrafts: [String: String]? = nil
    /// 同一批目录项 id → 当时给的修改要求（这一页的对话要重开时，跟第一稿一起迁到新开场里）
    var revisionAsks: [String: String]? = nil
    /// 新用户三问的答案（这一个任务唯一能当出处的原料，跟着任务绑在目标楼层）
    var answers: [CatalogSurvey.Answer]? = nil
    /// 写正文阶段正在写的那一页：每个已批目录项单开一段对话（不带出目录时的历史和别的原料），写完清掉。
    /// 旧 checkpoint 没有这个字段 = nil；history / turns 只留着出目录那段，写正文时只从里面取 read 回执
    var page: PageSession? = nil

    struct PageSession: Codable, Equatable, Sendable {
        /// 目录项 id
        var item: String
        var history: [Message]
        var turns: [Turn] = []
        /// 这一页收到、还没处理完的工具调用
        var pending: Turn? = nil
        /// 开这段对话时本项的目标、原料和读到的版本：变了才重开（别的目录项变了不算）。旧 checkpoint 没有 = 不重开
        var key: String? = nil
        /// 连续几轮没交出合格的这一页（交了别的、只回字、没过检查…），到上限就停，不再自动请求
        var stalls = 0
    }

    /// 交目录前必须读完的：种子 = 全部原料；三问 = 答案（wiki 只是给它看有什么，用到哪页读哪页）
    var unread: [Material] { materials.filter { read[$0.path] == nil && (entry != .survey || $0.layer == CatalogSurvey.layer) } }

    /// 能当出处的读过的原料
    var readable: Set<String> { Set(read.filter { !$0.value.isEmpty }.keys) }

    /// 一次正文提交的稳定 id：同一任务、同一次工具调用、同一目录项永远是同一个，崩溃后按它找回已经存下的提案
    static func commitId(task: String, call: String, item: String) -> String {
        let bytes = Array(SHA256.hash(data: Data("\(task)|\(call)|\(item)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }

    /// 某份原料这次实际读到的全文（从回合里的 read 回执取，不重新读盘；参数解析和执行 read 时同一个）
    func readText(_ path: String) -> String? {
        for turn in turns {
            for call in turn.calls where call.name == CatalogSeedTools.read {
                guard CatalogSeedTools.parse(call.argumentsJSON, truncated: call.truncated)?.path?.trimmingCharacters(in: .whitespacesAndNewlines) == path,
                      let result = turn.results.first(where: { $0.toolUseId == call.id && !$0.isError }),
                      let cut = result.text.firstIndex(of: "\n") else { continue }
                return String(result.text[result.text.index(after: cut)...])
            }
        }
        return nil
    }

    /// 已批、还没交正文的目录项
    static func unwritten(_ outline: WikiProposal?) -> [WikiProposal.Item] {
        (outline?.items ?? []).filter { $0.state == .approved && $0.change.direction?.mode == .seed && $0.change.direction?.contentProposalId == nil }
    }

    /// 完成 = 整份目录没有待批、至少一项获批、所有获批项都成功交了正文提案（正文还没批不拦）
    static func isComplete(_ outline: WikiProposal?) -> Bool {
        guard let outline else { return false }
        let approved = outline.items.filter { $0.state == .approved && $0.change.direction?.mode == .seed }
        return outline.pendingCount == 0 && !approved.isEmpty && approved.allSatisfy { $0.change.direction?.contentProposalId != nil }
    }

    enum Status: Equatable, Sendable {
        case reading
        case waitingOutline(pending: Int)
        case writable(Int)
        case ended
        case complete
        case abandoned

        var text: String {
            switch self {
            case .reading: return "还在读原料、没交目录"
            case .waitingOutline(let n): return "目录还有 \(n) 项等你批"
            case .writable(let n): return "\(n) 页批了还没写"
            case .ended: return "结束了，没完成"
            case .complete: return "完成了"
            case .abandoned: return "放弃了"
            }
        }

        /// 没完成、还挡着开新种子的
        var isOpen: Bool {
            switch self {
            case .reading, .waitingOutline, .writable: return true
            case .ended, .complete, .abandoned: return false
            }
        }
    }

    func status(outline: WikiProposal?) -> Status {
        if state == .complete { return .complete }
        if state == .abandoned { return .abandoned }
        if state == .ended { return .ended }
        guard outlineSaved || outline != nil else { return .reading }
        let left = Self.unwritten(outline).count
        if left > 0 { return .writable(left) }
        let pending = outline?.pendingCount ?? 0
        return pending > 0 ? .waitingOutline(pending: pending) : .ended
    }
}

extension CatalogSeedTask.Turn {
    init(_ turn: ToolTurn) {
        calls = turn.calls.map { .init(id: $0.id, name: $0.name, argumentsJSON: $0.argumentsJSON, truncated: $0.truncated) }
        results = turn.results.map { .init(toolUseId: $0.toolUseId, text: $0.text, isError: $0.isError) }
        assistantContent = turn.assistantContent.flatMap(Self.json)
        thinkingTokens = turn.thinkingTokens
        reasoningField = turn.reasoning?.field
        reasoningText = turn.reasoning?.text
        reasoningDetails = turn.reasoning.flatMap { $0.details.isEmpty ? nil : Self.json($0.details) }
        text = turn.text
    }

    var toolTurn: ToolTurn {
        var turn = ToolTurn(calls: calls.map { ToolCallBlock(id: $0.id, name: $0.name, argumentsJSON: $0.argumentsJSON, truncated: $0.truncated) },
                            results: results.map { ToolResultBlock(toolUseId: $0.toolUseId, text: $0.text, isError: $0.isError) })
        turn.assistantContent = assistantContent.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] }
        turn.thinkingTokens = thinkingTokens
        if reasoningField != nil || reasoningText != nil || reasoningDetails != nil {
            var r = ReasoningCapture()
            r.field = reasoningField
            r.text = reasoningText ?? ""
            r.details = reasoningDetails.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] } ?? []
            turn.reasoning = r
        }
        turn.text = text
        return turn
    }

    private static func json(_ value: [[String: Any]]) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}

/// checkpoint 存取：`wiki/.proposals/<任务 id>/task.json`，原子写。同步文件 IO，调用方放后台
struct CatalogSeedTaskStore: Sendable {
    let wiki: WikiStore

    static let fileName = "task.json"

    func folder(_ id: String) -> URL {
        wiki.root.appendingPathComponent(WikiStore.proposalsFolder, isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    func save(_ task: CatalogSeedTask) throws {
        guard UUID(uuidString: task.id) != nil else { throw WikiProposalStore.ProposalError.notFound(task.id) }
        try WikiStore.writeAtomic(Self.encoder.encode(task), to: folder(task.id).appendingPathComponent(Self.fileName))
    }

    func load(_ id: String) -> CatalogSeedTask? {
        guard UUID(uuidString: id) != nil, let data = try? Data(contentsOf: folder(id).appendingPathComponent(Self.fileName)) else { return nil }
        return try? Self.decoder.decode(CatalogSeedTask.self, from: data)
    }

    /// 新→旧
    func all() -> [CatalogSeedTask] {
        let base = wiki.root.appendingPathComponent(WikiStore.proposalsFolder, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.compactMap(load).sorted { $0.createdAt > $1.createdAt }
    }

    func remove(_ id: String) {
        guard UUID(uuidString: id) != nil else { return }
        try? FileManager.default.removeItem(at: folder(id))
    }

    /// 最近一次任务和它的目录（目录还没交 = nil）
    func latest(proposals: WikiProposalStore) -> (task: CatalogSeedTask, outline: WikiProposal?)? {
        guard let task = all().first else { return nil }
        return (task, proposals.load(task.id))
    }

    /// 还没完、挡着开新种子的那个
    func open(proposals: WikiProposalStore) -> (task: CatalogSeedTask, status: CatalogSeedTask.Status)? {
        for task in all() {
            let status = task.status(outline: proposals.load(task.id))
            if status.isOpen { return (task, status) }
        }
        return nil
    }

    /// 30 天清理不能删的：任务还没结束（等批 / 等写 / 停了能继续）
    func keeps(_ taskId: String, proposals: WikiProposalStore) -> Bool {
        guard let task = load(taskId) else { return false }
        return task.status(outline: proposals.load(taskId)).isOpen
    }
}

// MARK: - 工具：复用的文件 read（白名单）+ submit_proposal（outline / page 两阶段）

enum CatalogSeedTools {
    static let read = "read"

    /// 工具参数解析：执行调用和从回合里取 read 回执都走这一个（容得下围栏、尾随第二段 JSON、诊断写在后面）
    static func parse(_ json: String, truncated: Bool = false) -> Args? {
        let raw = json.isEmpty ? "{}" : json
        return CatalogDiagnostics.split(raw, truncated: truncated).bodies.lazy.compactMap { CatalogJSON.decode(Args.self, $0) }.first
    }

    /// 写正文阶段：原料全文都在开场消息里，只给交这一页的工具（phase 只能是 page、item 只能是这一项、items 必填）
    static func pageDefinitions(item: String) -> [[String: Any]] {
        [["type": "function", "function": [
            "name": CatalogAgentTools.submit,
            "description": "交这一页的正文条目（phase = page，item = 这一项的 id）。",
            "parameters": ["type": "object", "properties": [
                "phase": ["type": "string", "enum": ["page"]],
                "item": ["type": "string", "enum": [item], "description": "这一项的 id"],
                "items": ["type": "array", "items": CatalogAgentTools.itemSchema(record: seedRecord), "description": "这一页的条目"],
                "coverage": CatalogAgentTools.coverageSchema, "preservation": CatalogAgentTools.preservationSchema,
            ], "required": ["phase", "item", "items"]],
        ]]]
    }

    static var definitions: [[String: Any]] {
        let outlineEntry: [String: Any] = [
            "type": "object", "properties": [
                "path": ["type": "string"], "kind": ["type": "string", "enum": WikiPage.Kind.allCases.map(\.rawValue)],
                "title": ["type": "string"], "hook": ["type": "string"],
                "sources": ["type": "array", "items": ["type": "string"], "description": "这一页用到的原料路径（read 读过的）"],
            ], "required": ["path", "kind", "title", "sources"],
        ]
        return [
            ["type": "function", "function": [
                "name": read,
                "description": "完整读原料清单里的一份（只能读清单里的路径，每份只读一次）。",
                "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]],
            ]],
            ["type": "function", "function": [
                "name": CatalogAgentTools.submit,
                "description": "交种子：phase = outline 交整份目录（交完停下等批）；phase = page 交一个获批目录项的正文条目（item = 目录项 id）。",
                "parameters": ["type": "object", "properties": [
                    "phase": ["type": "string", "enum": ["outline", "page"]],
                    "outline": ["type": "array", "items": outlineEntry, "description": "phase = outline：整份目录"],
                    "item": ["type": "string", "description": "phase = page：目录项 id"],
                    "items": ["type": "array", "items": CatalogAgentTools.itemSchema(record: seedRecord), "description": "phase = page：这一页的条目"],
                    "reason": ["type": "string", "description": "确实没有事实可写成页时，说明为什么交空目录"],
                    "coverage": CatalogAgentTools.coverageSchema, "preservation": CatalogAgentTools.preservationSchema,
                ], "required": ["phase"]],
            ]],
        ]
    }

    private static let seedRecord: [String: Any] = [
        "type": "object", "properties": [
            "text": ["type": "string"],
            "sources": ["type": "array", "items": ["type": "string"]],
        ], "required": ["text", "sources"],
    ]

    struct Args: Decodable {
        let path: String?
        let phase: String?
        let item: String?
        let reason: String?
        let outline: [CatalogJSON.Lossy<OutlineEntry>]?
    }

    struct OutlineEntry: Decodable {
        let path: String
        let kind: String
        let title: String?
        let hook: String?
        let sources: [String]?
    }

    /// 出处里能认的原料：读过的、且在 allowed 里的（写正文时 = 这一项目录最终获批的原料）；页版本按读到的
    static func sources(_ task: CatalogSeedTask, allowed: Set<String>? = nil) -> CatalogSources {
        var s = CatalogSources()
        let byPath = Dictionary(task.materials.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for (path, version) in task.read where !version.isEmpty {
            guard let m = byPath[path] else { continue }
            if m.layer == "wiki", let page = CatalogSeedMaterials.pagePath(path) { s.versions[page] = version }
            guard allowed?.contains(path) ?? true else { continue }
            var cite = WikiProposal.Cite(layer: m.layer, filePath: path)
            if m.layer == "Prompt" { cite.name = m.name }
            if m.layer == CatalogSurvey.layer {
                cite = CatalogSurvey.cite(key: String(path.dropFirst(CatalogSurvey.prefix.count)), taskId: task.id, day: CatalogSurvey.day(task.createdAt))
            }
            s.addFile(path, cite: cite)
        }
        return s
    }

    /// 一个目录项（交上来的、文件库 / 审计台改过的都过这一道）：路径在工程 / 楼层下、八类、原料都是读过的
    static func checkDirection(_ d: WikiProposal.Direction, task: CatalogSeedTask?, wiki: WikiStore) -> Result<WikiProposal.Direction, CatalogSeedDrafts.EditError> {
        var d = d
        d.path = CatalogPrompts.normalizedPath(d.path)
        guard WikiStore.isValidPagePath(d.path) else { return .failure(.invalid("路径不合法：\(d.path)（第一段只能是工程或楼层）")) }
        guard d.kind != nil else { return .failure(.invalid("「\(d.title)」的类只能是 用户 / 人 / 物 / 地点 / 时间 / 事 / 项目 / 主题")) }
        let sources = WikiStore.normalizedWords(d.sources ?? [])
        let readable = task?.readable ?? []
        if let bad = sources.first(where: { !readable.contains($0) }) {
            return .failure(.invalid("「\(d.title)」的原料不是这次读过的：\(bad)"))
        }
        guard !sources.isEmpty else { return .failure(.invalid("「\(d.title)」没有原料")) }
        if task?.entry == .survey {
            if let bad = sources.first(where: { !$0.hasPrefix(CatalogSurvey.prefix) }) {
                return .failure(.invalid("「\(d.title)」的原料只能是这次的答案（问卷/…）：\(bad)"))
            }
            if wiki.pageExists(d.path), task?.read[CatalogSeedMaterials.wikiPath(d.path)]?.isEmpty != false {
                return .failure(.invalid("「\(d.title)」是已有页（\(d.path)），先 read 它再列进目录，只能交更新"))
            }
        }
        d.sources = sources
        if d.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { d.title = String(d.path.split(separator: "/").last ?? "") }
        d.action = wiki.pageExists(d.path) ? .update : .newPage
        return .success(d)
    }

    /// 目录：路径合法、八类、原料都读过；同路径只留第一项。返回目录项和扔掉的原因
    static func outline(_ entries: [CatalogJSON.Lossy<OutlineEntry>], task: CatalogSeedTask, wiki: WikiStore) -> (items: [WikiProposal.Item], dropped: [String]) {
        var items: [WikiProposal.Item] = []
        var dropped: [String] = []
        var seen = Set<String>()
        for (index, entry) in entries.enumerated() {
            guard let e = entry.value else { dropped.append("outline[\(index)]：格式不合格"); continue }
            let path = CatalogPrompts.normalizedPath(e.path)
            guard seen.insert(path).inserted else { dropped.append("outline[\(index)] \(path)：同一页重复"); continue }
            let raw = WikiProposal.Direction(path: path, title: e.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                             hook: e.hook?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                             kind: WikiPage.Kind(rawValue: e.kind.trimmingCharacters(in: .whitespaces)), action: .newPage,
                                             reason: "种子目录", mode: .seed,
                                             sources: WikiStore.normalizedWords(e.sources ?? []).filter(task.readable.contains))
            switch checkDirection(raw, task: task, wiki: wiki) {
            case .success(let d): items.append(WikiProposal.Item(change: .direction(d)))
            case .failure(let error): dropped.append("outline[\(index)] \(path)：\(error.localizedDescription)")
            }
        }
        return (items, dropped)
    }

    /// 算「这页正文已经产出」的：带可追溯出处的新开页或追加记录（空页、只改现在 / 钩子 / 连线都不算）
    static func isSubstantive(_ items: [WikiProposal.Item]) -> Bool {
        items.contains { item in
            switch item.change {
            case .newPage(let page): return !page.records.isEmpty && !item.cites.isEmpty
            case .appendRecords(_, let lines): return !lines.isEmpty && !item.cites.isEmpty
            default: return false
            }
        }
    }

    /// 一页的条目：只认写这个目录项那一页的；新开页的类 / 标题 / 钩子按（她可能改过的）目录；
    /// 已有页所有条目一律以本任务实际读到的版本为基线（补出的改钩子也一样，旧钩子按读到的那一版）
    static func page(_ parsed: CatalogItems.Parsed, direction d: WikiProposal.Direction, task: CatalogSeedTask) -> (items: [WikiProposal.Item], dropped: [String]) {
        var dropped = parsed.dropReasons
        var items: [WikiProposal.Item] = []
        for var item in parsed.items {
            guard item.change.targetPath == d.path else {
                dropped.append("\(item.change.targetPath ?? "分组")：不是这个目录项的页（\(d.path)）")
                continue
            }
            if case .newPage(var page) = item.change {
                guard !page.records.isEmpty else {
                    dropped.append("\(d.path)：新开页没有带出处的记录，不算正文")
                    continue
                }
                page.kind = d.kind ?? page.kind
                if !d.title.isEmpty { page.title = d.title }
                item.change = .newPage(page: page)
            }
            items.append(item)
        }
        guard isSubstantive(items) else {
            return ([], dropped + ["\(d.path)：没有带出处的事实正文（空页、只改现在 / 钩子 / 连线都不算这页写好了）"])
        }
        let readVersion = task.read[CatalogSeedMaterials.wikiPath(d.path)].flatMap { $0.isEmpty ? nil : $0 }
        for i in items.indices where !items[i].change.isNewPage { items[i].baseVersion = readVersion }
        let readPage = readVersion.flatMap { _ in task.readText(CatalogSeedMaterials.wikiPath(d.path)) }.map { WikiPage.parse($0, path: d.path) }
        CatalogItems.applyHook(&items, hook: d.hook, path: d.path, page: readPage, version: readVersion)
        return (items, dropped)
    }
}

// MARK: - 提示词（不带{助手}的聊天 prompt；规矩与事实分开；种子可以重述人设事实）

enum CatalogSeedPrompts {
    /// day = 三问的答题日期（种子不用）
    static func system(names: MemoryExtractor.Names, entry: CatalogSeedEntry = .cc, day: String = "") -> String {
        guard entry == .survey else { return seed(names: names) }
        return """
        这不是在跟你聊天。\(names.user)刚在新用户引导里答了几个问题，你要照这几句答案，给\(names.user)和\(names.char)的记忆 wiki 打一个基础底子。能当出处的原料只有这次的答案（问卷/…）；wiki 已有的索引和页只用来看已经有什么，不能当出处。
        怎么做：
        1. 用 read 把每一份答案都读一遍；想知道 wiki 里已经有什么，可以读索引；要往已有页里补，先 read 那一页；
        2. 读完调用 submit_proposal，phase = outline，交目录：\(names.user)本人的基础页放在「楼层/\(names.user)/」下面，类写「用户」，页名按内容自己起，不预设固定子页；答案里明说了、能单独写出几句的项目或人可以另开一页。页要少，只列答案里真有内容的；每项的 sources 只能写答案的路径。答案里没有能写成页的事实，就交空目录（outline 为空，写 reason）。交完目录就停下，等\(names.user)批；
        同一件事只开一页：在做的事、它叫什么、在哪儿做，讲的是一件事就写进同一页，不拆成几页；只够一句话的东西（一个地名、一个名字、一个偏好）写进相关的那页，不单开一页。
        3. 目录批了以后，只写批过的项：一页一页调用 submit_proposal，phase = page，item = 目录项 id，交这一页的条目。没批的、驳回的不写；写某一页时，记录的 sources 只能用这一项目录里列的答案。
        \(surveyFaithful(names))
        \(surveyDates(day))
        一页至少要有一行带 sources 的记录；可以连到这次目录里批过的别的页。
        已经有的页只能交追加记录 / 改现在 / 连线 / 改钩子，不能整页重写。
        目录项：{"path":"楼层/\(names.user)/在做的事","kind":"用户","title":"在做的事","hook":"当\(names.user)提到工作、课程或创业的打算时先看这页","sources":["问卷/在做什么"]}
        \(surveyItems(names: names, day: day))
        """
    }

    private static func surveyFaithful(_ names: MemoryExtractor.Names) -> String {
        "只写答案里明确说了的，不推测、不补充、不评价；\(names.user)怎么说就怎么记。"
    }

    private static func surveyDates(_ day: String) -> String {
        "这些答案都是 \(day) 答的（每份答案里写着答题日期）：记录开头写 \(day)；「现在」的时间锚写「（自 \(day) 起）」；答案原话里另说了时间（「去年开始」「下个月」），按 \(day) 换成具体日子。这次的原料都有日期，不写「日期未注明」「时间未注明」。"
    }

    private static func surveyItems(names: MemoryExtractor.Names, day: String) -> String {
        items(names: names, source: CatalogSurvey.prefix + "在做什么", now: "在准备 12 月的日语考试（自 \(day) 起）。", record: "\(day) 报了 12 月的日语考试")
    }

    private static func factsRule(_ names: MemoryExtractor.Names) -> String {
        "规矩和事实分开：回复规矩、语气要求、写给助手的指令（「你要…」「不要…」）不是事实，不进 wiki；只把关于\(names.user)、\(names.char)、你们之间、生活里的人事物和项目的事实写成页。CC 记忆里有很多是写给助手的工作规矩，规矩本身不进 wiki，但里面提到的关于\(names.user)的事实（偏好、经历、日期、原因）照样能写成页。"
    }

    private static func seedItems(names: MemoryExtractor.Names) -> String {
        items(names: names, source: "memory/cc/user_ship.md", now: "灯塔航线模型船展的举办地（时间未注明）。", record: "日期未注明 收藏《灯塔航线》纸质海图")
    }

    private static func seed(names: MemoryExtractor.Names) -> String {
        """
        这不是在跟你聊天。你在给\(names.user)和\(names.char)的记忆 wiki 打一个基础底子（种子）。原料只有清单里这些：楼层 Prompt 里人手填的全部文字、CC 记忆文件、wiki 已有的页和各层索引。
        怎么做：
        1. 用 read 把清单里每一份都完整读一遍（每份只读一次）；
        2. 读完调用 submit_proposal，phase = outline，交整份目录：每页的路径、类、标题、钩子、用到哪几份原料（sources）。按八类分页：用户 / 人 / 物 / 地点 / 时间 / 事 / 项目 / 主题；一页可以合多份原料，一份原料也可以拆到几页，不要一份文件建一页。交完目录就停下，等\(names.user)批；
        3. 目录批了以后，只写批过的项：一页一页调用 submit_proposal，phase = page，item = 目录项 id，交这一页的条目。没批的、驳回的不写；写某一页时，记录的 sources 只能用这一项目录里列的原料。
        \(factsRule(names))
        一页至少要有一行带 sources 的记录；可以连到这次目录里批过的别的页。
        已经有的页（清单里的 wiki 页）只能交追加记录 / 改现在 / 连线 / 改钩子，不能整页重写。
        目录项：{"path":"楼层/地点/云桥城","kind":"地点","title":"云桥城","hook":"当\(names.user)提到云桥城、模型船展时先看这页","sources":["memory/cc/user_ship.md"]}
        \(seedItems(names: names))
        """
    }

    /// 写正文阶段的 system：一页一段对话，写页规则沿用出目录时的那一套
    static func pageSystem(names: MemoryExtractor.Names, entry: CatalogSeedEntry = .cc, day: String = "") -> String {
        let survey = entry == .survey
        var lines = [
            survey ? "这不是在跟你聊天。你在照\(names.user)在新用户引导里答的几句话，给\(names.user)和\(names.char)的记忆 wiki 打一个基础底子。目录\(names.user)已经批了，这一次只写其中一页。"
                : "这不是在跟你聊天。你在给\(names.user)和\(names.char)的记忆 wiki 打一个基础底子（种子）。目录\(names.user)已经批了，这一次只写其中一页。",
            "下面的消息里给了：整份目录（用来连线）、这一页的目录项、这一项列着的原料全文；要更新已有页的，还有那一页现在的全文。只用这些写，不用 read。",
            "写好调用 submit_proposal，phase = page，item = 这一项的 id，交这一页的条目；记录的 sources 只能写这一项列着的原料路径。",
        ]
        lines += survey ? [surveyFaithful(names), surveyDates(day)] : [factsRule(names)]
        lines += [
            "一页至少要有一行带 sources 的记录；可以连到这次目录里批过的别的页。",
            "已经有的页只能交追加记录 / 改现在 / 连线 / 改钩子，不能整页重写。",
            survey ? surveyItems(names: names, day: day) : seedItems(names: names),
        ]
        return lines.joined(separator: "\n")
    }

    struct PageSource: Equatable, Sendable {
        var path: String
        var layer: String
        var name: String
        /// 任务 read 回执里的那一版全文（读的时候已经不在了 = nil）
        var text: String?
    }

    /// 写一页的开场：整份目录、这一项、这一项列着的原料全文（read 回执那一版）、要更新的已有页全文
    static func pageOpening(_ item: WikiProposal.Item, outline: WikiProposal, sources: [PageSource], existing: String?,
                            revision: (asks: String, draft: String)? = nil) -> String {
        guard let d = item.change.direction else { return "" }
        func line(_ i: WikiProposal.Item) -> String? {
            guard let d = i.change.direction, d.mode == .seed else { return nil }
            let state = i.state == .approved ? "已批" : i.state == .rejected ? "驳回" : "待批"
            return "- \(d.path) · \(d.kind?.rawValue ?? "") · \(d.title)" + (d.hook.isEmpty ? "" : " · 钩子：\(d.hook)") + " · \(state)"
        }
        var out = ["【整份目录】（用来连线：只能连到「已批」的页）\n" + outline.items.compactMap(line).joined(separator: "\n")]
        let action = d.action == .update ? "更新已有页（只能交追加记录 / 改现在 / 连线 / 改钩子）" : "新开页"
        out.append("【这一页】item=\(item.id) · \(d.path) · \(d.kind?.rawValue ?? "") · \(d.title)" + (d.hook.isEmpty ? "" : " · 钩子：\(d.hook)") + " · \(action)")
        out.append("【这一项的原料】共 \(sources.count) 份，全文在下面；记录的 sources 只能写这几份的路径")
        for s in sources {
            out.append("【\(s.path) · \(s.layer) · \(s.name)】\n" + (s.text ?? "（这份读的时候已经不在了，不能当出处）"))
        }
        if let existing { out.append("【要更新的已有页 · 现在的全文】\n" + existing) }
        if let revision {
            out.append("【这一页之前交过一稿，没过检查】只改下面这几处，别的照旧，整页重交：\n\(revision.asks)\n\n上一稿（原样）：\n\(revision.draft)")
        }
        out.append("写好调用 submit_proposal（phase = page，item = \(item.id)），只交这一页。")
        return out.joined(separator: "\n\n")
    }

    static func pageNudge(_ itemId: String) -> String {
        "（系统提醒：你还没调用工具。这一页的原料都在上面，写好用 submit_proposal（phase = page，item = \(itemId)）交。）"
    }

    /// page 阶段的条目格式、记录、诊断和写作规则（种子 / 三问共用）
    private static func items(names: MemoryExtractor.Names, source: String, now: String, record: String) -> String {
        """
        page 的 items 只有这几种：
        - 新开一页：{"type":"new_page","path":"楼层/地点/云桥城","kind":"地点","title":"云桥城","triggers":["云桥城","云桥"],"hook":"…","now":"\(now)","records":[记录…],"links":[{"to":"楼层/事/灯塔航线试航","relation":"补充","why":"试航地点"}]}
        - 往已有页追加记录：{"type":"append","path":"…","records":[记录…]}
        - 改已有页的「现在」：{"type":"rewrite_now","path":"…","now":"改完的整段「现在」"}
        - 已有页连线：{"type":"link","path":"从哪页","to":"连到哪页","relation":"补充","why":"一句为什么"}
        - 改已有页的钩子 / 触发词：{"type":"retag","path":"…","hook":"…","triggers":["…"]}
        记录 = {"text":"\(record)","sources":["\(source)"]}：sources 只能写 read 实际读过、并列在这一项目录里的路径。
        phase = page 时：\(CatalogPrompts.diagnostics(names: names, standalone: false, seed: true))

        \(CatalogPrompts.pageRules(names: names, seed: true))
        """
    }

    static func opening(_ m: CatalogSeedMaterials, names: MemoryExtractor.Names, entry: CatalogSeedEntry = .cc, day: String = "") -> String {
        guard entry == .survey else { return opening(m, names: names) }
        let answers = m.items.filter { $0.layer == CatalogSurvey.layer }
        let indexes = m.items.filter { $0.layer == "wiki" && CatalogSeedMaterials.indexFolder($0.path) != nil }
        var out = ["【这次的答案】（\(day) 答的，记录日期就用这一天；共 \(answers.count) 份，每份都用 read 读一次，只有它们能当出处）"]
        out += answers.map { "- \($0.path) · \($0.name) · \($0.text.count) 字" }
        if indexes.isEmpty {
            out.append("【wiki 已有的】还没有页")
        } else {
            out.append("【wiki 已有的】（只用来看有什么，不能当出处；要往已有页里补，先 read 那一页）")
            out += indexes.map { "- \($0.path) · \($0.name) · \($0.text.count) 字" }
            out.append("索引里列的页都能 read，路径 = memory/wiki/<页路径>.md")
        }
        out.append("先 read 答案，读完调用 submit_proposal（phase = outline）交目录。")
        return out.joined(separator: "\n")
    }

    private static func opening(_ m: CatalogSeedMaterials, names: MemoryExtractor.Names) -> String {
        var out = ["【这次的原料清单】（共 \(m.items.count) 份；每份都用 read 完整读一次，读过的不用再读）"]
        out += m.items.map { item in
            let note = item.layer == "wiki" && CatalogSeedMaterials.pagePath(item.path) != nil ? "（已有页，只能交更新）" : ""
            return "- \(item.path) · \(item.layer) · \(item.name)\(note) · \(item.text.count) 字"
        }
        if !m.skipped.isEmpty {
            out.append("【没读的】\n" + m.skipped.map { "- " + $0 }.joined(separator: "\n"))
        }
        out.append("先逐份 read，读完调用 submit_proposal（phase = outline）交整份目录。")
        return out.joined(separator: "\n")
    }

    /// 审批后继续：只是控制消息，不是事实来源
    static func control(_ outline: WikiProposal, names: MemoryExtractor.Names) -> String {
        func line(_ item: WikiProposal.Item) -> String {
            guard let d = item.change.direction else { return "" }
            return "- item=\(item.id) · \(d.path) · \(d.kind?.rawValue ?? "") · \(d.title)"
                + (d.hook.isEmpty ? "" : " · 钩子：\(d.hook)") + " · 原料：\((d.sources ?? []).joined(separator: "、"))"
        }
        let seeds = outline.items.filter { $0.change.direction?.mode == .seed }
        let todo = seeds.filter { $0.state == .approved && $0.change.direction?.contentProposalId == nil }
        let done = seeds.filter { $0.state == .approved && $0.change.direction?.contentProposalId != nil }
        let rejected = seeds.filter { $0.state == .rejected }
        let pending = seeds.filter { $0.state == .pending }.count
        var out = ["（系统：\(names.user)批了目录。这只是审批结果，不是事实。只写「已批、待写」的项，按目录现在的路径 / 类 / 标题 / 钩子 / 原料写；没批的、驳回的不写。"]
        out.append("已批、待写：\n" + (todo.isEmpty ? "（无）" : todo.map(line).joined(separator: "\n")))
        if !done.isEmpty { out.append("已批、已交过正文（不用再交）：\n" + done.map(line).joined(separator: "\n")) }
        if !rejected.isEmpty { out.append("驳回了（不写）：\n" + rejected.map(line).joined(separator: "\n")) }
        if pending > 0 { out.append("还有 \(pending) 项等批，先不写。") }
        out.append("现在逐页调用 submit_proposal（phase = page，item = 目录项 id）。）")
        return out.joined(separator: "\n")
    }

    static let nudge = "（系统提醒：你还没调用工具。没读完就继续 read；读完交目录用 submit_proposal（phase = outline）；目录批了就逐页交 submit_proposal（phase = page）。）"

    /// 服务商说上下文太长：人话 + 原文，不记完成
    static func contextTooLong(_ message: String) -> Bool {
        ChatErrorClassifier.classify(.init(status: 0, body: "", streamError: message)) == .contextTooLong
    }

    /// 出目录这一轮超长（一次读全部原料）：种子自己的说法，不带聊天那套「调上下文深度」的建议
    static func contextNote(round: Int, model: String, raw: String) -> String {
        let said = providerText(raw)
        return "出目录这一轮要一次读完全部原料，加起来超过 \(model) 一次能读的长度\(limitText(said))，种子还没完成（第 \(round) 轮）。可以放弃这个种子任务，先在 C3 设置里换上下文更大的模型，再重新播种。服务商原话：\(said)"
    }

    /// 写某一页超长：这一页列的原料本身就装不下，照实报，不悄悄裁剪原料
    static func pageContextNote(title: String, round: Int, model: String, raw: String) -> String {
        let said = providerText(raw)
        return "「\(title)」这一页列的原料太长，超过 \(model) 一次能读的长度\(limitText(said))，这一页还没写（第 \(round) 轮）。可以放弃这个种子任务，重新播种时在目录批之前给这一项少列几份原料，或先在 C3 设置里换上下文更大的模型再重新播种。服务商原话：\(said)"
    }

    /// 同一页连续几轮没交出合格的这一页：停下，不再自动请求
    static func stallNote(title: String, rounds: Int, last: String) -> String {
        "「\(title)」这一页连续 \(rounds) 轮没交出能用的正文（最后一轮：\(last)），先停下了，没有再自动请求。可以点「继续这个种子任务」再试，或放弃这个种子任务。"
    }

    /// 报错里服务商自己的那段：聊天层加在前面的建议（「把预设里的上下文深度调小」那类）不要
    static func providerText(_ message: String) -> String {
        guard let r = message.range(of: "原文：") else { return message }
        return String(message[r.upperBound...])
    }

    /// 服务商原话里写的上限 token 数（认得出才给）
    static func contextLimit(_ raw: String) -> Int? {
        for pattern in [#">\s*\d{4,}\s*maximum"#, #"maximum context length is \d{4,}"#, #"maximum prompt length is \d{4,}"#, #"context window of \d{4,}"#] {
            guard let r = raw.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            return Int(raw[r].filter(\.isNumber))
        }
        return nil
    }

    private static func limitText(_ raw: String) -> String {
        contextLimit(raw).map { "（约 \($0) token）" } ?? ""
    }
}
