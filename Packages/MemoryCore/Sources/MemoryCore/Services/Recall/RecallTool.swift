import Foundation

/// 显式分层窄读；access 与本轮读回执由主聊天调用方落库。
/// 对话只经 `ConversationSource`；工具 schema / 文案 / 本地注入面留 app（`RecallTool+App.swift`）。
public enum RecallTool {
    public static let bodyLimit = RecallTuning.defaults.maximumBodyCharacters
    public static let totalTextLimit = RecallTuning.defaults.maximumResponseCharacters
    public static let snippetLimit = 300

    public enum Op: String, Codable { case date, window, segment, messages, search, wiki }
    public struct Target: Codable, Equatable, Sendable {
        public var tree: String
        public var layer: String
        public var conversationId: String? = nil
        public var segment: Int? = nil
        public var directoryRevision: String? = nil
        public var lastNodeId: String? = nil
        public var fromNodeId: String? = nil
        public var toNodeIdExclusive: String? = nil
        public var branchAnchor: String? = nil
        public var date: String? = nil
        public var page: RecallWikiPageTarget? = nil
        public var row: RecallWikiRowTarget? = nil
        public var card: RecallWikiCardTarget? = nil
        public var source: RecallWikiSourceLocator? = nil
        public var memoryId: String? = nil
        public var sourceVersion: String? = nil
        public var query: String? = nil
        public var scope: String? = nil

        public init(tree: String, layer: String, conversationId: String? = nil, segment: Int? = nil,
                    directoryRevision: String? = nil, lastNodeId: String? = nil, fromNodeId: String? = nil,
                    toNodeIdExclusive: String? = nil, branchAnchor: String? = nil, date: String? = nil,
                    page: RecallWikiPageTarget? = nil, row: RecallWikiRowTarget? = nil,
                    card: RecallWikiCardTarget? = nil, source: RecallWikiSourceLocator? = nil,
                    memoryId: String? = nil, sourceVersion: String? = nil, query: String? = nil, scope: String? = nil) {
            self.tree = tree
            self.layer = layer
            self.conversationId = conversationId
            self.segment = segment
            self.directoryRevision = directoryRevision
            self.lastNodeId = lastNodeId
            self.fromNodeId = fromNodeId
            self.toNodeIdExclusive = toNodeIdExclusive
            self.branchAnchor = branchAnchor
            self.date = date
            self.page = page
            self.row = row
            self.card = card
            self.source = source
            self.memoryId = memoryId
            self.sourceVersion = sourceVersion
            self.query = query
            self.scope = scope
        }
    }
    public struct Input: Codable, Equatable {
        public var op: Op
        public var date: String? = nil
        public var after: String? = nil
        public var before: String? = nil
        public var conversationId: String? = nil
        public var segment: Int? = nil
        public var fromNodeId: String? = nil
        public var toNodeIdExclusive: String? = nil
        public var query: String? = nil
        public var scope: String? = nil
        public var exact: Bool? = nil
        public var includeInvalid: Bool? = nil
        public var layer: String? = nil
        public var folder: String? = nil
        public var target: Target? = nil
        public var cursor: String? = nil

        public init(op: Op, date: String? = nil, after: String? = nil, before: String? = nil,
                    conversationId: String? = nil, segment: Int? = nil, fromNodeId: String? = nil,
                    toNodeIdExclusive: String? = nil, query: String? = nil, scope: String? = nil,
                    exact: Bool? = nil, includeInvalid: Bool? = nil, layer: String? = nil,
                    folder: String? = nil, target: Target? = nil, cursor: String? = nil) {
            self.op = op
            self.date = date
            self.after = after
            self.before = before
            self.conversationId = conversationId
            self.segment = segment
            self.fromNodeId = fromNodeId
            self.toNodeIdExclusive = toNodeIdExclusive
            self.query = query
            self.scope = scope
            self.exact = exact
            self.includeInvalid = includeInvalid
            self.layer = layer
            self.folder = folder
            self.target = target
            self.cursor = cursor
        }
    }
    public struct ReadInfo {
        public let layer: String
        public let target: String
        public let sourceVersion: String?
        public let status: String
        public var returnedRange: [Target]? = nil
        public var next: RecallReadReceipt.Next? = nil
        /// 本页实际返回条数（成功 / 分页 = 本页条数，失败 = 0，nil = 旧账）
        public var returnedCount: Int? = nil
        /// 仅关闭拒绝：`mem_master` 关 → `"master"`，否则 `"window"`；其余 nil
        public var gate: String? = nil

        public init(layer: String, target: String, sourceVersion: String?, status: String,
                    returnedRange: [Target]? = nil, next: RecallReadReceipt.Next? = nil,
                    returnedCount: Int? = nil, gate: String? = nil) {
            self.layer = layer
            self.target = target
            self.sourceVersion = sourceVersion
            self.status = status
            self.returnedRange = returnedRange
            self.next = next
            self.returnedCount = returnedCount
            self.gate = gate
        }
    }
    public struct ExecResult {
        public let text: String
        public let isError: Bool
        public let hitMemoryIds: [UUID]
        public let read: ReadInfo?
        public var cursor: String? = nil
        public var targets: [Target] = []

        public init(text: String, isError: Bool, hitMemoryIds: [UUID], read: ReadInfo?,
                    cursor: String? = nil, targets: [Target] = []) {
            self.text = text
            self.isError = isError
            self.hitMemoryIds = hitMemoryIds
            self.read = read
            self.cursor = cursor
            self.targets = targets
        }
    }
    public struct Cursor: Codable {
        public var profileId: String
        public var root: String
        public var input: Input
        public var layer: String
        public var revision = ""
        public var position = 0
        public var offset = 0
        public var day: String? = nil
        public var timeZone: String
        public var excludedConversationId: String? = nil
        public var wiki: RecallWikiCursor? = nil
        public var lastNodeId: String? = nil
        public var searchRevisionCount: Int? = nil
        public var tuning: RecallTuning = .defaults

        public init(profileId: String, root: String, input: Input, layer: String, timeZone: String,
                    excludedConversationId: String? = nil) {
            self.profileId = profileId
            self.root = root
            self.input = input
            self.layer = layer
            self.timeZone = timeZone
            self.excludedConversationId = excludedConversationId
        }

        enum CodingKeys: String, CodingKey {
            case profileId, root, input, layer, revision, position, offset, day, timeZone
            case excludedConversationId, wiki, lastNodeId, searchRevisionCount
        }
    }
    public struct Block: Codable {
        public var label: String
        public var text: String
        public var targets: [Target] = []
        public var memoryId: UUID? = nil
        public var counts = true
        public var returnedRange: Target? = nil

        public init(label: String, text: String, targets: [Target] = [], memoryId: UUID? = nil,
                    counts: Bool = true, returnedRange: Target? = nil) {
            self.label = label
            self.text = text
            self.targets = targets
            self.memoryId = memoryId
            self.counts = counts
            self.returnedRange = returnedRange
        }

        enum CodingKeys: String, CodingKey { case label, text, targets, memoryId, counts }
    }
    public struct RangeError: Error { public let message: String
        public init(message: String) { self.message = message }
    }
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
    public static func json<T: Encodable>(_ value: T) -> String {
        String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }
    public static func revision(_ text: String) -> String { WikiStore.version(of: Data(text.utf8)) }
    public static func encodeCursor(_ cursor: Cursor) -> String {
        guard let data = try? encoder.encode(cursor),
              let compressed = try? (data as NSData).compressed(using: .lzfse) else { return "" }
        return (compressed as Data).base64EncodedString()
    }
    public static func normalizeCursor(_ token: String) -> String {
        var normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = normalized.unicodeScalars.last {
            switch last.value {
            case 65...90, 97...122, 48...57, 43, 47, 61: return normalized
            default: normalized.unicodeScalars.removeLast()
            }
        }
        return normalized
    }
    public static func decodeCursor(_ token: String) -> Cursor? {
        guard let data = Data(base64Encoded: normalizeCursor(token)),
              let plain = try? (data as NSData).decompressed(using: .lzfse) else { return nil }
        return try? decoder.decode(Cursor.self, from: plain as Data)
    }
    static func validCursor(_ state: Cursor) -> Bool {
        guard state.position >= 0, state.offset >= 0,
              state.searchRevisionCount.map({ $0 >= 0 }) != false,
              !state.revision.isEmpty || (state.position == 0 && state.offset == 0),
              TimeZone(identifier: state.timeZone) != nil, state.input.cursor == nil else { return false }
        let op = state.input.op
        if op == .search {
            let layers = state.input.scope == "a" ? ["A4", "A3", "A2", "原文"] : ["wiki页", "L1", "原文"]
            guard layers.contains(state.layer) else { return false }
        } else if state.layer != initialLayer(op, wiki: state.input.layer) { return false }
        guard (try? validate(state.input, profileId: state.profileId, calendar: calendar(state))) != nil else { return false }
        if op == .date {
            guard let day = parseDay(state.day, calendar: calendar(state)),
                  let bounds = try? resolveRange(date: state.input.date ?? state.input.target?.date,
                                                after: state.input.after, before: state.input.before, calendar: calendar(state)).get(),
                  let after = bounds.after, let before = bounds.beforeExclusive,
                  day >= after, day < before else { return false }
        }
        return true
    }

    public static func execute(inputJSON: String, profileId: String, currentConversationId: String?, userName: String,
                        assistantName: String, source: any ConversationSource, memoryRoot: URL,
                        defaults: UserDefaults = .standard,
                        tuning: RecallTuning? = nil, memoryParticipation: Bool = true,
                        environment: RecallEnvironment) async -> ExecResult {
        let root = memoryRoot
        var layer = "原文"
        do {
            let raw = try JSONSerialization.jsonObject(with: Data(inputJSON.utf8))
            guard let args = raw as? [String: Any], let opName = args["op"] as? String, let op = Op(rawValue: opName) else {
                throw RangeError(message: "从父层重新定位：op 必填，须为 date/window/segment/messages/search/wiki。")
            }
            let targetWikiLayer = (args["target"] as? [String: Any])?["layer"] as? String
            let wikiLayer = args["cursor"] is String
                ? targetWikiLayer ?? args["layer"] as? String
                : (args["layer"] as? String) ?? targetWikiLayer
            layer = initialLayer(op, wiki: wikiLayer)
            let allowed: Set<String>
            switch op {
            case .date: allowed = ["date", "after", "before", "target"]
            case .window: allowed = ["conversation_id", "target"]
            case .segment: allowed = ["conversation_id", "segment", "target"]
            case .messages: allowed = ["conversation_id", "from_node_id", "to_node_id_exclusive", "target"]
            case .search: allowed = ["query", "scope", "date", "after", "before", "conversation_id", "exact", "include_invalid"]
            case .wiki: allowed = ["layer", "folder", "target"]
            }
            for key in args.keys.sorted() where !allowed.union(["op", "cursor"]).contains(key) {
                if op == .wiki, key == "scope" {
                    if args["scope"] as? String == "c" { continue }
                    throw RangeError(message: "wiki 用 layer:index|page|entry|original，不用 scope。")
                }
                throw RangeError(message: "从父层重新定位：op=\(op.rawValue) 不适用参数 \(key)。")
            }
            if let target = args["target"] as? [String: Any] {
                if op == .wiki, !(args["cursor"] is String), let explicit = args["layer"] as? String,
                   let requested = target["layer"] as? String, explicit != requested {
                    throw RangeError(message: "从父层重新定位：layer 与 target.layer 不一致。")
                }
                var keys: Set<String> = ["tree", "layer"]
                switch op {
                case .date: keys.insert("date")
                case .window: keys.formUnion(["conversation_id", "branch_anchor"])
                case .segment: keys.formUnion(["conversation_id", "segment", "directory_revision", "last_node_id", "branch_anchor"])
                case .messages: keys.formUnion(["conversation_id", "last_node_id", "from_node_id", "to_node_id_exclusive", "branch_anchor"])
                case .wiki:
                    switch wikiLayer {
                    case "page": keys.insert("page")
                    case "entry": keys.formUnion(["row", "source", "card"])
                    case "original": keys.formUnion(["card", "row", "source", "memory_id", "source_version", "conversation_id", "from_node_id", "to_node_id_exclusive", "branch_anchor"])
                    default: break
                    }
                default: break
                }
                if let extra = target.keys.sorted().first(where: { !keys.contains($0) }) {
                    if op == .wiki, wikiLayer == "original" {
                        throw RangeError(message: "original 只接受 entry 层返回的 target（card，或 row+memory_id+source_version）；从 page 请先 layer:entry。")
                    }
                    throw RangeError(message: "从父层重新定位：本层 target 不适用字段 \(extra)。")
                }
            }
            var input = try decoder.decode(Input.self, from: Data(inputJSON.utf8))
            if op == .wiki {
                input.layer = input.layer ?? input.target?.layer
                input.scope = nil
            }
            let token = input.cursor
            input.cursor = nil
            var state: Cursor
            if let token {
                guard let saved = decodeCursor(token), saved.profileId == profileId,
                      saved.root == String(revision(root.standardizedFileURL.path).prefix(16)),
                      saved.input.op == op, saved.timeZone == Calendar.current.timeZone.identifier, validCursor(saved) else {
                    return failure(layer, "cursor 已过期或不属于当前楼层/目标，请从父层重新定位。", status: "stale")
                }
                try validateCursorSubset(input, saved: saved.input, fields: args.keys)
                state = saved
                input = saved.input
                layer = state.layer
            } else {
                input = try validate(input, profileId: profileId, calendar: .current)
                state = Cursor(profileId: profileId, root: String(revision(root.standardizedFileURL.path).prefix(16)), input: input,
                               layer: layer, timeZone: Calendar.current.timeZone.identifier,
                               excludedConversationId: currentConversationId)
            }
            state.tuning = (tuning ?? RecallTuningStore.load(profileId: profileId, defaults: defaults)).validated
            if state.position.addingReportingOverflow(state.tuning.searchPageResults + 1).overflow {
                return failure(layer, "cursor 已过期或不属于当前楼层/目标，请从父层重新定位。", status: "stale")
            }
            let memMaster = (defaults.object(forKey: "mem_master") as? Bool) ?? true
            let master = memMaster && memoryParticipation
            return await Task.detached(priority: .userInitiated) {
                do {
                    var state = state
                    if let requested = input.conversationId ?? input.target?.conversationId {
                        _ = try resolveConversation(idOrPrefix: requested, profileId: profileId, source: source)
                        state.excludedConversationId = nil
                    }
                    if !master && input.op != .messages && input.op != .search {
                        return failure(layer, "记忆总开关已关闭，只能搜索或范围读取有权限的原文。", target: input.target,
                                       gate: memMaster ? "window" : "master")
                    }
                    switch input.op {
                    case .date: return try await readDate(state, source: source, root: root)
                    case .window: return try await readWindow(state, source: source, root: root)
                    case .segment: return try await readSegment(state, source: source, root: root)
                    case .messages: return try readMessages(state, source: source, userName: userName, assistantName: assistantName)
                    case .search: return try await search(state, source: source, root: root, master: master, environment: environment)
                    case .wiki: return try readWiki(state, source: source, root: root, userName: userName,
                                                    assistantName: assistantName, environment: environment)
                    }
                } catch let error as RangeError {
                    return failure(layer, error.message, target: input.target)
                } catch {
                    return failure(layer, "从父层重新定位：读取失败：\(error.localizedDescription)", target: input.target, status: "unavailable")
                }
            }.value
        } catch let error as RangeError {
            return failure(layer, error.message)
        } catch {
            return failure(layer, "从父层重新定位：参数类型或 JSON 无效：\(error.localizedDescription)")
        }
    }

    static func validateCursorSubset(_ input: Input, saved: Input, fields: some Collection<String>) throws {
        func unchanged<T: Equatable>(_ value: T?, _ original: T?, _ field: String) throws {
            if fields.contains(field), value != original {
                throw RangeError(message: "cursor 续读不能改变目标/区间：\(field) 与签发时不一致。")
            }
        }
        if fields.contains("conversation_id"), input.conversationId != saved.conversationId,
           input.conversationId.map({ cid in cid.count >= 8 && saved.conversationId?.hasPrefix(cid) == true }) != true {
            throw RangeError(message: "cursor 续读不能改变目标/区间：conversation_id 与签发时不一致。")
        }
        try unchanged(input.target, saved.target, "target")
        try unchanged(input.segment, saved.segment, "segment")
        try unchanged(input.fromNodeId, saved.fromNodeId, "from_node_id")
        try unchanged(input.toNodeIdExclusive, saved.toNodeIdExclusive, "to_node_id_exclusive")
        try unchanged(input.date, saved.date, "date")
        try unchanged(input.after, saved.after, "after")
        try unchanged(input.before, saved.before, "before")
        try unchanged(input.query, saved.query, "query")
        try unchanged(input.scope, saved.scope, "scope")
        try unchanged(input.exact, saved.exact, "exact")
        try unchanged(input.includeInvalid, saved.includeInvalid, "include_invalid")
        try unchanged(input.layer, saved.layer, "layer")
        try unchanged(input.folder, saved.folder, "folder")
    }

    public static func initialLayer(_ op: Op, wiki: String? = nil) -> String {
        switch op {
        case .date: return "A4"
        case .window: return "A3"
        case .segment: return "A2"
        case .messages, .search: return "原文"
        case .wiki: return ["index": "wiki索引", "page": "wiki页", "entry": "L1", "original": "L2"][wiki ?? ""] ?? "wiki索引"
        }
    }
    public static func failure(_ layer: String, _ message: String, target: Target? = nil, status: String = "invalidTarget",
                               gate: String? = nil) -> ExecResult {
        let text = "在 \(layer) 层 · 本次 0 条 · 下一步 " + String(message.prefix(bodyLimit))
        return ExecResult(text: text, isError: true, hitMemoryIds: [],
                          read: ReadInfo(layer: layer, target: target.map(json) ?? "", sourceVersion: nil, status: status,
                                         returnedRange: [], next: .init(hasMore: false, cursorIssued: false),
                                         returnedCount: 0, gate: gate))
    }
    @discardableResult
    public static func validate(_ requested: Input, profileId: String, calendar: Calendar) throws -> Input {
        var input = requested
        if input.op == .wiki {
            if let layer = input.layer, let target = input.target, layer != target.layer {
                throw RangeError(message: "从父层重新定位：layer 与 target.layer 不一致。")
            }
            input.layer = input.layer ?? input.target?.layer
        }
        if let target = input.target {
            guard target.tree == (input.op == .wiki ? "c" : "a"), target.layer == (input.op == .wiki ? input.layer : input.op.rawValue) else {
                throw RangeError(message: "从父层重新定位：target 的树/层与本次 op 不匹配。")
            }
            if let cid = input.conversationId,
               target.conversationId.map({ $0 == cid || (cid.count >= 8 && $0.hasPrefix(cid)) }) != true {
                throw RangeError(message: "从父层重新定位：显式 conversation_id 与 target 内 conversation_id 不一致。")
            }
            if let segment = input.segment, segment != target.segment {
                throw RangeError(message: "从父层重新定位：显式 segment 与 target 内 segment 不一致。")
            }
            if let from = input.fromNodeId, from != target.fromNodeId {
                throw RangeError(message: "从父层重新定位：显式 from_node_id 与 target 内 from_node_id 不一致。")
            }
            if let to = input.toNodeIdExclusive, to != target.toNodeIdExclusive {
                throw RangeError(message: "从父层重新定位：显式 to_node_id_exclusive 与 target 内 to_node_id_exclusive 不一致。")
            }
            if input.op == .date && (input.date != nil || input.after != nil || input.before != nil) {
                throw RangeError(message: "从父层重新定位：日期 target 与 date/after/before 互斥。")
            }
            input.conversationId = target.conversationId
            input.segment = target.segment
            input.fromNodeId = target.fromNodeId
            input.toNodeIdExclusive = target.toNodeIdExclusive
        }
        _ = try resolveRange(date: input.date ?? input.target?.date, after: input.after, before: input.before, calendar: calendar).get()
        switch input.op {
        case .date:
            guard input.date != nil || input.after != nil || input.target?.date != nil else { throw RangeError(message: "从父层重新定位：op=date 必须给 date 或 after（或返回的日期 target）；不能只给 before。") }
        case .window, .segment, .messages:
            guard let cid = input.conversationId ?? input.target?.conversationId, !cid.isEmpty else { throw RangeError(message: "从父层重新定位：op=\(input.op.rawValue) 缺 conversation_id 或对应 target。") }
            if input.op == .segment {
                guard let number = input.segment ?? input.target?.segment, number >= 0 else { throw RangeError(message: "从父层重新定位：op=segment 缺非负 segment。") }
                if let target = input.target, target.directoryRevision == nil { throw RangeError(message: "从父层重新定位：段 target 缺 directory_revision。") }
            }
            if input.op == .messages, (input.fromNodeId ?? input.target?.fromNodeId)?.isEmpty != false {
                throw RangeError(message: "从父层重新定位：op=messages 缺 from_node_id。")
            }
        case .search:
            guard input.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { throw RangeError(message: "从父层重新定位：op=search 缺非空 query。") }
            guard input.scope == "a" || input.scope == "c" else { throw RangeError(message: "从父层重新定位：op=search 缺 scope:a|c。") }
            if input.includeInvalid != nil && (input.scope != "c" || input.exact == true) {
                throw RangeError(message: "include_invalid 只适用于 scope=c 且 exact 不为 true 的档案搜索。")
            }
        case .wiki:
            guard ["index", "page", "entry", "original"].contains(input.layer ?? "") else { throw RangeError(message: "从父层重新定位：op=wiki 缺 layer:index|page|entry|original。") }
            if input.layer != "index", input.target == nil { throw RangeError(message: "从父层重新定位：wiki/\(input.layer ?? "") 缺结构化 target。") }
            if input.layer != "index", input.folder != nil { throw RangeError(message: "folder 仅适用于 wiki/index。") }
            if input.layer == "page", input.target?.page == nil { throw RangeError(message: "从父层重新定位：wiki/page target 缺 page。") }
            if input.layer == "entry", input.target?.row == nil { throw RangeError(message: "从父层重新定位：wiki/entry target 缺 row。") }
            if input.layer == "original", let target = input.target, target.card != nil,
               target.memoryId != nil || target.row != nil || target.source != nil || target.sourceVersion != nil
                || target.conversationId != nil || target.fromNodeId != nil || target.toNodeIdExclusive != nil || target.branchAnchor != nil {
                throw RangeError(message: "从父层重新定位：wiki/original 的 card target 与碎片/消息 target 互斥。")
            }
            if input.layer == "original", input.target?.card == nil,
               input.target?.memoryId == nil || input.target?.row == nil || input.target?.sourceVersion == nil {
                throw RangeError(message: "original 只接受 entry 层返回的 target（card，或 row+memory_id+source_version）；从 page 请先 layer:entry。")
            }
        }
        return input
    }

    public static func calendar(_ state: Cursor) -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: state.timeZone) ?? .current
        return calendar
    }
    public static func parseDay(_ string: String?, endOfDay: Bool = false, calendar: Calendar = .current) -> Date? {
        guard let string, string.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let day = MemoryDay.date(ofKey: string, calendar: calendar) else { return nil }
        let boundary = MemoryDay.boundary(of: day, calendar: calendar)
        guard MemoryDay.key(boundary, calendar: calendar) == string else { return nil }
        return endOfDay ? calendar.date(byAdding: .day, value: 1, to: boundary) : boundary
    }
    public static func resolveRange(date: String?, after: String?, before: String?, calendar: Calendar = .current) -> Result<(after: Date?, beforeExclusive: Date?), RangeError> {
        if date != nil && (after != nil || before != nil) { return .failure(.init(message: "从父层重新定位：date 与 after/before 互斥。")) }
        if before != nil && after == nil { return .failure(.init(message: "从父层重新定位：不能只给 before，必须同时给 after。")) }
        for (name, value) in [("date", date), ("after", after), ("before", before)] {
            if let value, parseDay(value, calendar: calendar) == nil { return .failure(.init(message: "从父层重新定位：\(name) 格式要有效 YYYY-MM-DD（收到「\(value)」）。")) }
        }
        if let date { return .success((parseDay(date, calendar: calendar), parseDay(date, endOfDay: true, calendar: calendar))) }
        let a = parseDay(after, calendar: calendar)
        let b = parseDay(before, calendar: calendar) ?? parseDay(after, endOfDay: true, calendar: calendar)
        if let a, let b, b <= a { return .failure(.init(message: "从父层重新定位：before 要晚于 after（before 不含当天）。")) }
        return .success((a, b))
    }
    public static func inRange(_ date: Date?, after: Date?, beforeExclusive: Date?) -> Bool {
        guard let date else { return false }
        return (after == nil || date >= after!) && (beforeExclusive == nil || date < beforeExclusive!)
    }

    /// 正文只计 block.text；label、target、层头与 cursor 计入总回包，JSON 定位不截断。
    public static func deliver(_ blocks: [Block], state requested: Cursor, revision: String, target: Target,
                        maximumCount: Int, nextPage: Cursor? = nil, empty: String = "没有找到可读记录。",
                        nextStep: String, positionBase: Int = 0, sourceVersion: String? = nil,
                        notice: String? = nil,
                        dateBoundaries: [(day: String, position: Int, revision: String)] = []) -> ExecResult {
        if !requested.revision.isEmpty && requested.revision != revision {
            return failure(requested.layer, "内容或选中分支已改版，cursor 已过期，请从父层重新定位。", target: target, status: "stale")
        }
        let localPosition = requested.position - positionBase
        guard localPosition >= 0, localPosition <= blocks.count,
              requested.offset == 0 || (localPosition < blocks.count && requested.offset <= blocks[localPosition].text.count) else {
            return failure(requested.layer, "cursor 已过期或不属于当前楼层/目标，请从父层重新定位。", target: target, status: "stale")
        }
        let bodyLimit = requested.tuning.maximumBodyCharacters
        let totalLimit = requested.tuning.maximumResponseCharacters
        let joinsOriginalRanges = requested.input.op == .messages ||
            (requested.input.op == .wiki && requested.input.layer == "original")
        let tailReserve = "（该消息未完）\n".count + 1
        var pageLimit = totalLimit
        while pageLimit > 0 {
            var state = requested
            state.revision = revision
            var body = notice.map { $0 + "\n" } ?? ""
            var bodyCount = 0, metaCount = body.count, count = 0, limitedCount = 0
            var ids: [UUID] = [], targets: [Target] = []
            var returnedRange: [Target] = []
            var emittedTargets = Set<String>()
            while state.position - positionBase < blocks.count && limitedCount < maximumCount {
                let block = blocks[state.position - positionBase]
                var metadata = "[\(block.label)]\n"
                for target in block.targets {
                    let encoded = json(target)
                    if emittedTargets.insert(encoded).inserted { metadata += "target: " + encoded + "\n" }
                }
                let remaining = block.text.dropFirst(state.offset)
                let available = min(bodyLimit - bodyCount, pageLimit - bodyCount - metaCount - metadata.count - tailReserve)
                if available <= 0 { break }
                if count > 0 && remaining.count > available { break }
                let slice = String(remaining.prefix(available))
                body += metadata + slice + "\n"
                bodyCount += slice.count
                metaCount += metadata.count + 1
                targets += block.targets
                let range = block.returnedRange ?? block.targets.first ?? target
                if joinsOriginalRanges, let last = returnedRange.last, let cid = range.conversationId, last.conversationId == cid,
                   last.fromNodeId != nil, range.lastNodeId != nil {
                    returnedRange[returnedRange.count - 1].lastNodeId = range.lastNodeId
                    returnedRange[returnedRange.count - 1].toNodeIdExclusive = range.toNodeIdExclusive
                } else if returnedRange.last != range {
                    returnedRange.append(range)
                }
                count += 1
                if block.counts { limitedCount += 1 }
                if let id = block.memoryId { ids.append(id) }
                state.offset += slice.count
                if state.offset < block.text.count {
                    body += requested.layer == "原文" ? "（该消息未完）\n" : "（本块未完）\n"
                    break
                }
                state.position += 1; state.offset = 0
            }
            if count == 0 && blocks.isEmpty { body += empty + "\n" }
            if count == 0 && !blocks.isEmpty {
                return failure(requested.layer, "从父层重新定位：目标元数据过长，无法在本次限额内返回。", target: target)
            }
            var next = state.position - positionBase < blocks.count ? state : nextPage
            if state.position - positionBase < blocks.count,
               let boundary = dateBoundaries.last(where: { $0.position <= state.position }) {
                next?.day = boundary.day
                next?.position = state.position - boundary.position
                next?.revision = boundary.revision
            }
            if let first = dateBoundaries.first {
                let last = state.position - positionBase == blocks.count ? dateBoundaries.last! :
                    dateBoundaries.last(where: { $0.position < state.position || ($0.position == state.position && state.offset > 0) }) ?? first
                returnedRange = [Target(tree: "a", layer: "date", date: first.day)]
                if last.day != first.day { returnedRange.append(Target(tree: "a", layer: "date", date: last.day)) }
            }
            let token = next.map(encodeCursor)
            let header = "在 \(requested.layer) 层 · 本次 \(count) 条 · 下一步 \(token == nil ? nextStep : "同 op + cursor 续读本层")\n"
            let text = header + body + (token.map { "cursor: \($0)\n" } ?? "")
            if text.count <= totalLimit {
                return ExecResult(text: text, isError: false, hitMemoryIds: ids,
                                  read: ReadInfo(layer: requested.layer, target: json(target), sourceVersion: sourceVersion ?? revision,
                                                 status: token == nil ? "success" : "partial",
                                                 returnedRange: returnedRange,
                                                 next: .init(hasMore: next != nil, cursorIssued: token?.isEmpty == false),
                                                 returnedCount: count),
                                  cursor: token, targets: targets)
            }
            pageLimit -= text.count - totalLimit
        }
        return failure(requested.layer, "cursor/目标元数据超过回包限额，请缩小定位范围。", target: target)
    }

    public static func resolveConversation(idOrPrefix: String, profileId: String, source: any ConversationSource) throws -> String {
        let match: ConversationWindow?
        do {
            match = try source.window(profileId: profileId, idOrPrefix: idOrPrefix)
        } catch ConversationSourceError.ambiguousIdPrefix {
            throw RangeError(message: "conversation_id 前缀有歧义，请给完整 ID；不会猜另一个窗口。")
        } catch {
            match = nil
        }
        guard let match else {
            throw RangeError(message: "从父层重新定位：没有找到这场对话（id 不存在、已删除或不属于当前楼层；前缀至少8位）。")
        }
        return match.id
    }

    /// 碎片出处用的记忆命中（`Memory` 表由 app 注入，见 `RecallEnvironment.searchL1`）。
    public struct MemoryHit: Sendable {
        public let id: UUID
        public let content: String
        public let category: String
        public let createdAt: Date
        public let invalid: Bool
        public let priority: Int
        public let sourceConversationId: String?
        public let sourceNodeId: String?
        public let isFragment: Bool

        public init(id: UUID, content: String, category: String, createdAt: Date, invalid: Bool, priority: Int,
                    sourceConversationId: String?, sourceNodeId: String?, isFragment: Bool) {
            self.id = id
            self.content = content
            self.category = category
            self.createdAt = createdAt
            self.invalid = invalid
            self.priority = priority
            self.sourceConversationId = sourceConversationId
            self.sourceNodeId = sourceNodeId
            self.isFragment = isFragment
        }
    }
    public struct L1Result: Sendable {
        public let hits: [MemoryHit]
        public let vectorStatus: String?
        public init(hits: [MemoryHit], vectorStatus: String?) {
            self.hits = hits
            self.vectorStatus = vectorStatus
        }
    }

    public static func searchALine(terms: [String], in range: DateInterval? = nil, memoryRoot: URL,
                           conversationIds: Set<String>? = nil, cancel: CatalogCancel? = nil) -> CatalogALineReader.Result {
        let terms = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !terms.isEmpty, cancel?.isCancelled != true else { return .init(terms: [], hits: [], found: [:], truncated: false) }
        let candidates = CatalogALineReader.candidates(in: range, memoryRoot: memoryRoot, conversationIds: conversationIds, cancel: cancel).filter {
            conversationIds == nil || $0.conversationId.map { conversationIds!.contains($0) } ?? true
        }
        var documents: [[String]] = []
        for candidate in candidates {
            guard cancel?.isCancelled != true else { return .init(terms: terms, hits: [], found: [:]) }
            documents.append(MemoryBM25.document(content: candidate.title + "\n" + candidate.text, keywords: candidate.keywords))
        }
        let scores = MemoryBM25.scores(documents: documents, query: terms.joined(separator: "\n"), cancel: cancel)
        guard cancel?.isCancelled != true else { return .init(terms: terms, hits: [], found: [:]) }
        let indices = candidates.indices.filter { scores[$0] > 0 }.sorted {
            scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1
        }
        let hits = indices.map { candidates[$0] }
        var found: [CatalogALineReader.Layer: Int] = [:]
        for hit in hits {
            guard cancel?.isCancelled != true else { return .init(terms: terms, hits: [], found: [:]) }
            found[hit.layer, default: 0] += 1
        }
        return .init(terms: terms, hits: hits, found: found, truncated: false)
    }

    public static func centeredSnippet(_ text: String, keyword: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        guard let range = text.range(of: keyword, options: .caseInsensitive) else { return String(text.prefix(limit)) + "…" }
        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let offset = max(0, min(matchStart - limit / 3, text.count - limit))
        let slice = String(text.dropFirst(offset).prefix(limit))
        return (offset > 0 ? "…" : "") + slice + (offset + slice.count < text.count ? "…" : "")
    }
}
