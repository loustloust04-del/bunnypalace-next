import Foundation

public struct MemoryBenchRecallInput: Codable, Equatable, Sendable {
    public struct Names: Codable, Equatable, Sendable {
        public var userName: String
        public var assistantName: String
        public var timeZone: String
        public init(userName: String, assistantName: String, timeZone: String) {
            self.userName = userName
            self.assistantName = assistantName
            self.timeZone = timeZone
        }
    }
    public struct Turn: Codable, Equatable, Sendable {
        public struct Operation: Codable, Equatable, Sendable {
            public var op: String
            public var args: [String: MemoryBenchJSON]
            public init(op: String, args: [String: MemoryBenchJSON]) {
                self.op = op
                self.args = args
            }
        }
        public var text: String
        public var ops: [Operation]? = nil
        public init(text: String, ops: [Operation]? = nil) {
            self.text = text
            self.ops = ops
        }
    }
    public var snapshot: String
    public var profile: Names
    public var turns: [Turn]
    public init(snapshot: String, profile: Names, turns: [Turn]) {
        self.snapshot = snapshot
        self.profile = profile
        self.turns = turns
    }
}

public struct MemoryBenchRecallOutput: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public var source: String
        public var layer: String
        public var status: String = "success"
        public init(source: String, layer: String, status: String = "success") {
            self.source = source
            self.layer = layer
            self.status = status
        }
    }
    public struct X: Codable, Equatable, Sendable {
        public var searched: Bool
        public var kept: Bool
        public var reason: String
        public var sources: [Source]
        public var reasons: [String: String] = [:]
        public var path: String = "x"
        public var fullText: String? = nil
        public init(searched: Bool, kept: Bool, reason: String, sources: [Source], reasons: [String: String] = [:],
                    path: String = "x", fullText: String? = nil) {
            self.searched = searched
            self.kept = kept
            self.reason = reason
            self.sources = sources
            self.reasons = reasons
            self.path = path
            self.fullText = fullText
        }
    }
    public struct Y: Codable, Equatable, Sendable {
        public var op: String
        public var layer: String
        public var status: String
        public var target: String
        public var sourceVersion: String?
        public var returnedRange: [RecallTool.Target]?
        public var next: RecallReadReceipt.Next?
        public var deepest: String?
        public var continuation: Bool = false
        public var start: [Int] = []
        public var end: [Int]? = nil
        public var rangeStart: [Int]? = nil
        public var rangeEnd: [Int]? = nil
        public var targets: [RecallTool.Target]? = nil
        public init(op: String, layer: String, status: String, target: String, sourceVersion: String? = nil,
                    returnedRange: [RecallTool.Target]? = nil, next: RecallReadReceipt.Next? = nil, deepest: String? = nil,
                    continuation: Bool = false, start: [Int] = [], end: [Int]? = nil,
                    rangeStart: [Int]? = nil, rangeEnd: [Int]? = nil, targets: [RecallTool.Target]? = nil) {
            self.op = op
            self.layer = layer
            self.status = status
            self.target = target
            self.sourceVersion = sourceVersion
            self.returnedRange = returnedRange
            self.next = next
            self.deepest = deepest
            self.continuation = continuation
            self.start = start
            self.end = end
            self.rangeStart = rangeStart
            self.rangeEnd = rangeEnd
            self.targets = targets
        }
    }
    public struct Turn: Codable, Equatable, Sendable {
        public var x: X
        public var y: [Y]
        public init(x: X, y: [Y]) {
            self.x = x
            self.y = y
        }
    }
    public struct Guard: Codable, Equatable, Sendable {
        public var privacyLeak = false
        public var l2Impersonation = false
        public var originalOverrun = false
        public init(privacyLeak: Bool = false, l2Impersonation: Bool = false, originalOverrun: Bool = false) {
            self.privacyLeak = privacyLeak
            self.l2Impersonation = l2Impersonation
            self.originalOverrun = originalOverrun
        }
    }
    public var turns: [Turn]
    public var deepestLayer: String?
    public var calls: Int
    public var guardrail: Guard
    public init(turns: [Turn], deepestLayer: String? = nil, calls: Int, guardrail: Guard) {
        self.turns = turns
        self.deepestLayer = deepestLayer
        self.calls = calls
        self.guardrail = guardrail
    }

    enum CodingKeys: String, CodingKey { case turns, deepestLayer, calls; case guardrail = "guard" }
    static let layers = ["A4", "A3", "A2", "原文", "wiki索引", "wiki页", "L1", "L2"]
    static func depth(_ layer: String?) -> Int { layer.flatMap { layers.firstIndex(of: $0) }.map { $0 + 1 } ?? 0 }
    public static func deepest(_ reads: [Y]) -> String? {
        reads.compactMap(\.deepest).max { depth($0) < depth($1) }
    }
}

public struct MemoryBenchRecallReader: MemoryBenchWriter {
    public let id = "recall"
    public let title = "翻记忆"
    public let callStyle = MemoryBenchCallStyle.local
    public let labelKinds = ["必须带", "允许带", "禁止带", "应跳过", "应到达层"]
    public let variableCatalog: [MemoryBenchVariable] = []
    public var scorers: [any MemoryBenchScorer] { [MemoryBenchRecallScorer()] }
    public var profileId: String? = nil

    /// 工具合同摘要（app 注入 `ToolSchemaRenderer` / `RecallTool` 的产物；包内不认识提示词）
    private let contract: @Sendable () -> String?
    /// 内置快照文件（app = `Bundle.main.url(MemoryBench/…)`，包测试 = `Bundle.module.url(测试夹具目录/…)`）
    private let floorURL: URL

    public init(profileId: String? = nil, contract: @escaping @Sendable () -> String?, floorURL: URL) {
        self.profileId = profileId
        self.contract = contract
        self.floorURL = floorURL
    }

    public func builtInRecipes(defaults: UserDefaults) -> [MemoryBenchRecipe] {
        let tuning = RecallTuningStore.load(profileId: profileId ?? defaults.string(forKey: "lastProfileId") ?? "", defaults: defaults)
        guard case .object(var params) = try? MemoryBenchJSON.from(tuning), let contract = contract() else { return [] }
        params["contract"] = .string(contract)
        params["tuningSource"] = .string("floor")
        return [MemoryBenchRecipe(id: "recall-current", writer: id, name: "现行", parent: nil, system: "", user: "",
                                  params: params, checks: "recall", builtIn: true, savedAt: nil)]
    }

    public func variables(for testCase: MemoryBenchCase, recipe: MemoryBenchRecipe) throws -> [String: MemoryBenchValue] { [:] }

    public func parse(output: String, testCase: MemoryBenchCase, recipe: MemoryBenchRecipe) -> MemoryBenchParsed {
        guard let result = try? MemoryBench.decoder.decode(MemoryBenchRecallOutput.self, from: Data(output.utf8)) else {
            return .init(items: [], checks: [.init(name: "召回输出 JSON", passed: false, hard: true, detail: "无法读取本地回执")])
        }
        var items: [MemoryBenchItem] = []
        func add(_ text: String, turn: Int, kind: String, source: String = "", layer: String = "", status: String = "success", extra: [String: String] = [:]) {
            var fields = ["turn": String(turn), "kind": kind, "source": source, "layer": layer, "status": status]
            fields.merge(extra) { _, new in new }
            items.append(.init(index: items.count, text: text, fields: fields))
        }
        var previous: MemoryBenchRecallOutput.Y?
        let floor = floor(for: testCase)
        for (offset, turn) in result.turns.enumerated() {
            let n = offset + 1
            let labels = testCase.labels.filter { $0.from == "turn:\(n)" }
            let required = labels.filter { $0.kind == "必须带" }
            // Scripted Y turns use must-carry labels for the read result, not X injection.
            let xRequired = turn.y.isEmpty ? required : []
            let judgeable = turn.x.fullText == nil || turn.x.fullText == "ready"
            let sources = Set(turn.x.sources.map(\.source))
            let skip = labels.contains { $0.kind == "应跳过" }
            add("第 \(n) 轮：\(turn.x.reason)", turn: n, kind: "turn", extra: [
                "searched": String(turn.x.searched), "kept": String(turn.x.kept), "skip": String(skip),
                "required": String(judgeable ? xRequired.count : 0), "judgeable": String(judgeable && !labels.isEmpty),
                "path": turn.x.path, "fullText": turn.x.fullText ?? "notRequested"])
            for source in turn.x.sources {
                add("X 带入 \(source.source)", turn: n, kind: "x", source: source.source, layer: source.layer, status: source.status,
                    extra: ["judgeable": String(judgeable)])
            }
            for label in xRequired where judgeable && !label.keys.contains(where: sources.contains) {
                let source = label.keys.first ?? ""
                add("漏注：\(label.text)", turn: n, kind: "miss", source: source, status: "missing",
                    extra: ["labelId": label.id, "reason": turn.x.reasons[source] ?? turn.x.reason])
            }
            var ySources = Set<String>()
            for read in turn.y {
                var extra = ["op": read.op, "paginationRepeat": "0", "paginationGap": "0"]
                if read.continuation, let old = previous, old.op == read.op, let end = old.end, !read.start.isEmpty, end != read.start {
                    extra[read.start.lexicographicallyPrecedes(end) ? "paginationRepeat" : "paginationGap"] = "1"
                }
                if read.continuation, let old = previous, old.op == read.op,
                   let start = read.rangeStart, let end = old.rangeEnd, start != end {
                    extra[start.lexicographicallyPrecedes(end) ? "paginationRepeat" : "paginationGap"] = "1"
                }
                let ranges = read.returnedRange ?? []
                var sources = ranges.flatMap { Self.sources($0, version: read.sourceVersion, layer: read.layer, floor: floor) }
                if !ranges.isEmpty, read.layer == "wiki索引" { sources = ["layer:wiki索引"] }
                if !ranges.isEmpty, read.layer == "L1" {
                    let originals = (read.targets ?? []).filter { $0.layer == "original" }
                    sources = originals.isEmpty ? ["layer:L1"] : originals.map { Self.source($0, version: read.sourceVersion, layer: read.layer) }
                }
                var seen = Set<String>()
                sources = sources.filter { seen.insert($0).inserted }
                if ["success", "partial"].contains(read.status) {
                    ySources.formUnion(sources)
                    ySources.insert("layer:\(read.layer)")
                }
                if sources.isEmpty {
                    add("Y \(read.op)：\(read.layer) · \(read.status)", turn: n, kind: "y", layer: read.layer, status: read.status, extra: extra)
                } else {
                    for (i, source) in sources.enumerated() {
                        add("Y 读到 \(read.layer)：\(source)", turn: n, kind: "y",
                            source: source, layer: read.layer, status: read.status,
                            extra: i == 0 ? extra : ["op": read.op])
                    }
                }
                previous = read
            }
            for label in required where !turn.y.isEmpty && !label.keys.contains(where: ySources.contains) {
                add("Y 未带：\(label.text)", turn: n, kind: "y", status: "missing", extra: ["labelId": label.id])
            }
            let deepest = MemoryBenchRecallOutput.deepest(turn.y)
            for label in labels where label.kind == "应到达层" {
                add("Y 定位：\(deepest ?? "没有成功读取")，期望 \(label.text)", turn: n, kind: "location", layer: deepest ?? "",
                    status: turn.y.isEmpty ? "untestable" : "measured", extra: ["labelId": label.id])
            }
        }
        let checks = [("privacyLeak", result.guardrail.privacyLeak), ("l2Impersonation", result.guardrail.l2Impersonation), ("originalOverrun", result.guardrail.originalOverrun)]
            .map { MemoryBenchCheck(name: $0.0, passed: !$0.1, hard: true, detail: nil) }
        return .init(items: items, checks: checks)
    }

    private func floor(for testCase: MemoryBenchCase) -> MemoryBenchRecallFloor? {
        guard let input = try? testCase.input.decode(MemoryBenchRecallInput.self) else { return nil }
        return try? MemoryBenchRecallFloor.load(contentsOf: floorURL, variant: input.snapshot).0
    }

    static func sources(_ target: RecallTool.Target, version: String?, layer: String,
                        floor: MemoryBenchRecallFloor?) -> [String] {
        guard let cid = target.conversationId, let from = target.fromNodeId,
              let window = floor?.windows.first(where: { $0.id == cid }) else {
            return [source(target, version: version, layer: layer)]
        }
        let nodes = floor?.branch(window).filter { !$0.hidden && !$0.deleted } ?? []
        guard let low = nodes.firstIndex(where: { $0.id == from }) else {
            return [source(target, version: version, layer: layer)]
        }
        let high = target.lastNodeId.flatMap { last in nodes.firstIndex { $0.id == last }.map { $0 + 1 } }
            ?? target.toNodeIdExclusive.flatMap { to in nodes.firstIndex { $0.id == to } } ?? low + 1
        guard low < high else { return [] }
        return nodes[low..<high].map { key(node: $0.id, conversationId: cid) }
    }

    public static func key(page: String, version: String) -> String { "page:\(page)|\(version)" }
    public static func key(card: String, version: String) -> String { "card:\(card)|\(version)" }
    public static func key(node: String, conversationId: String) -> String { "node:\(conversationId)|\(node)" }

    static func source(_ target: RecallTool.Target, version: String?, layer: String? = nil) -> String {
        if let card = target.card { return key(card: card.path, version: card.version) }
        if let memory = target.memoryId { return "memory:\(memory)" }
        if let cid = target.conversationId, let node = target.fromNodeId { return key(node: node, conversationId: cid) }
        if let page = target.page ?? target.row?.page { return key(page: page.path, version: page.version ?? version ?? "") }
        return "layer:\(layer ?? target.layer)"
    }

    public func autoJudge(items: [MemoryBenchItem], labels: [MemoryBenchLabel]) -> [(item: Int, verdict: MemoryBenchVerdict, labelId: String)] {
        items.map { item in
            let own = labels.filter { $0.from == "turn:\(item.fields["turn"] ?? "")" }
            let source = item.fields["source"] ?? ""
            let kind = item.fields["kind"]
            if ["x", "y", "turn"].contains(kind), item.fields["judgeable"] == "false" { return (item.index, .weak, "") }
            if kind == "y" {
                if item.fields["status"] == "missing" { return (item.index, .wrong, item.fields["labelId"] ?? "") }
                if ["success", "partial"].contains(item.fields["status"] ?? "") {
                    let keys = [source, "layer:\(item.fields["layer"] ?? "")"]
                    if let forbidden = own.first(where: { $0.kind == "禁止带" && $0.keys.contains(where: keys.contains) }) {
                        return (item.index, .wrong, forbidden.id)
                    }
                    if let required = own.first(where: { $0.kind == "必须带" && $0.keys.contains(where: {
                        $0.components(separatedBy: "|").first == source.components(separatedBy: "|").first
                    }) }) {
                        return (item.index, required.keys.contains(source) ? .right : .wrong, required.id)
                    }
                }
                return (item.index, .right, "")
            }
            if kind == "x" {
                if let forbidden = own.first(where: { $0.kind == "禁止带" && $0.keys.contains(source) }) { return (item.index, .wrong, forbidden.id) }
                let allowed = own.first { ["允许带", "必须带"].contains($0.kind) && $0.keys.contains(source) }
                return (item.index, allowed == nil ? .wrong : .right, allowed?.id ?? "")
            }
            if kind == "miss" { return (item.index, .wrong, item.fields["labelId"] ?? "") }
            if kind == "turn", let skip = own.first(where: { $0.kind == "应跳过" }) {
                return (item.index, item.fields["searched"] == "true" ? .wrong : .right, skip.id)
            }
            if kind == "location", let label = own.first(where: { $0.id == item.fields["labelId"] }) {
                return (item.index, item.fields["status"] == "untestable" ? .weak : label.keys.contains("layer:\(item.fields["layer"] ?? "")") ? .right : .wrong, label.id)
            }
            return (item.index, .right, "")
        }
    }
}
