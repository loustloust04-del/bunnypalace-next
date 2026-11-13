import Foundation

/// 本地重放的纯函数部分（执行壳留在 app：`MemoryBenchLocalExecutor` 扩展）。
public enum MemoryBenchLocalExecutor {
    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public static func preferencesSuite(named name: String) -> String {
        #if os(macOS)
        // Explicit file domains avoid cfprefsd recreating an empty named suite after unlink.
        return FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        #else
        return name
        #endif
    }

    public static func removePreferences(_ defaults: UserDefaults, suite: String) {
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
        #if os(macOS)
        if suite.hasPrefix("/") {
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        #else
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: library.appendingPathComponent("Preferences/\(suite).plist"))
        }
        #endif
    }

    public static func resolve(_ value: MemoryBenchJSON, previous: RecallTool.ExecResult?) throws -> MemoryBenchJSON {
        switch value {
        case .string(let reference) where reference.hasPrefix("$prev"):
            guard let previous else { throw Failure("$prev 没有前一结果") }
            if reference == "$prev.cursor", let cursor = previous.cursor { return .string(cursor) }
            let pattern = #"^\$prev\.targets\[(\d+)\](?:\.(.+))?$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: reference, range: NSRange(reference.startIndex..., in: reference)),
                  let range = Range(match.range(at: 1), in: reference), let index = Int(reference[range]), previous.targets.indices.contains(index) else {
                throw Failure("无效引用：\(reference)")
            }
            var result = try MemoryBench.decoder.decode(MemoryBenchJSON.self, from: RecallTool.encoder.encode(previous.targets[index]))
            if let field = Range(match.range(at: 2), in: reference) {
                for key in reference[field].split(separator: ".").map(String.init) {
                    guard case .object(let object) = result, let next = object[key] else { throw Failure("引用字段不存在：\(reference)") }
                    result = next
                }
            }
            return result
        case .array(let values): return .array(try values.map { try resolve($0, previous: previous) })
        case .object(let values): return .object(try values.mapValues { try resolve($0, previous: previous) })
        default: return value
        }
    }

    public static func position(_ cursor: RecallTool.Cursor?) -> [Int] {
        guard let cursor else { return [0, 0, 0, 0, 0] }
        let wiki = cursor.wiki.flatMap { try? MemoryBenchJSON.from($0) }
        var p = 0, o = 0
        if case .object(let fields) = wiki {
            if case .number(let value) = fields["position"] { p = Int(value) }
            if case .number(let value) = fields["offset"] { o = Int(value) }
        }
        return [Int((cursor.day ?? "").replacingOccurrences(of: "-", with: "")) ?? 0, cursor.position, cursor.offset, p, o]
    }

    public static func rangeBounds(_ ranges: [RecallTool.Target], op: String, before: RecallTool.Cursor?,
                                   after: RecallTool.Cursor?, floor: MemoryBenchRecallFloor) -> ([Int], [Int])? {
        if op == "date" {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let days = ranges.compactMap { $0.date }.compactMap { MemoryDay.date(ofKey: $0, calendar: calendar) }
                .map { Int($0.timeIntervalSince1970 / 86400) }.sorted()
            guard let first = days.first, let last = days.last else { return nil }
            let nextDay = after?.day.flatMap { MemoryDay.date(ofKey: $0, calendar: calendar) }
                .map { Int($0.timeIntervalSince1970 / 86400) }
            let end = nextDay == last ? [last, after?.position ?? 0, after?.offset ?? 0] : [last + 1, 0, 0]
            return ([first, before?.position ?? 0, before?.offset ?? 0], end)
        }
        if op == "messages", let first = ranges.first, let last = ranges.last,
           let window = floor.windows.first(where: { $0.id == first.conversationId }) {
            let nodes = floor.branch(window).filter { !$0.hidden && !$0.deleted }.map(\.id)
            guard let low = first.fromNodeId.flatMap({ nodes.firstIndex(of: $0) }),
                  let high = last.lastNodeId.flatMap({ nodes.firstIndex(of: $0) }) else { return nil }
            let offset = after?.offset ?? 0
            return ([low, before?.offset ?? 0], offset > 0 ? [high, offset] : [high + 1, 0])
        }
        return nil
    }

    /// 每轮重放只建一次（app 建好传进 `observe` / `leaks`）：只读值类型，一次算完 `branch`。
    public struct Forbidden: Sendable {
        public let nodes: Set<String>
        public let memories: Set<UUID>
        public let lines: Set<String>

        public init(_ floor: MemoryBenchRecallFloor) {
            var nodes = Set<String>()
            var memories = Set<UUID>()
            var lines = Set<String>()
            func addBody(_ body: String) {
                for line in body.components(separatedBy: .newlines) {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty && !text.hasPrefix("#") { lines.insert(text) }
                }
            }
            for page in floor.pages where page.path.contains("private_") || !page.approved {
                for raw in page.versions { addBody(FrontmatterCodec.parse(raw)?.body ?? raw) }
            }
            for window in floor.windows {
                let selected = Set(floor.branch(window).map(\.id))
                for node in window.nodes where window.trashed || node.hidden || node.deleted || !selected.contains(node.id) {
                    nodes.insert(node.id)
                    addBody(node.text)
                }
            }
            for fragment in floor.fragments where nodes.contains(fragment.nodeId) {
                memories.insert(fragment.id)
                addBody(fragment.text)
            }
            self.nodes = nodes
            self.memories = memories
            self.lines = lines
        }

        public func leaks(_ text: String) -> Bool { lines.contains { text.contains($0) } }
        public func contains(_ target: RecallTool.Target) -> Bool {
            [target.fromNodeId, target.lastNodeId, target.toNodeIdExclusive].compactMap { $0 }.contains(where: nodes.contains)
                || target.memoryId.flatMap(UUID.init(uuidString:)).map(memories.contains) == true
        }
    }

    /// 正文 / 来源是否碰到快照里不许出现的材料
    public static func leaks(_ text: String, forbidden: Forbidden) -> Bool {
        forbidden.leaks(text)
    }

    public static func observe(_ result: RecallTool.ExecResult, requested: RecallTool.Input, floor: MemoryBenchRecallFloor,
                               forbidden: Forbidden, guardrail: inout MemoryBenchRecallOutput.Guard) {
        if forbidden.leaks(result.text)
            || result.targets.contains(where: forbidden.contains)
            || (result.read?.returnedRange ?? []).contains(where: forbidden.contains)
            || result.hitMemoryIds.contains(where: forbidden.memories.contains) {
            guardrail.privacyLeak = true
        }
        if result.read?.layer == "L2", result.read?.status == "success", let card = requested.target?.card {
            if result.read?.sourceVersion != card.version || !floor.cards.contains(where: { $0.path == card.path && $0.version == card.version }) {
                guardrail.l2Impersonation = true
            }
        }
        guard requested.op == .messages, !result.isError,
              let cid = requested.target?.conversationId ?? requested.conversationId,
              let window = floor.windows.first(where: { $0.id == cid || $0.id.hasPrefix(cid) }) else { return }
        let nodes = floor.branch(window).map(\.id)
        let from = requested.target?.fromNodeId ?? requested.fromNodeId
        let to = requested.target?.toNodeIdExclusive ?? requested.toNodeIdExclusive
        let last = requested.target?.lastNodeId
        guard let from, let low = nodes.firstIndex(of: from) else { guardrail.originalOverrun = true; return }
        let high: Int
        if let to {
            // `to` 给了却不在可见主线（如隐藏节点）→ 从严判越界，不再回落到窗尾放行。
            guard let index = nodes.firstIndex(of: to) else { guardrail.originalOverrun = true; return }
            high = index
        } else {
            high = last.flatMap { nodes.firstIndex(of: $0).map { $0 + 1 } } ?? nodes.count
        }
        let allowed = Set(nodes[low..<max(low, high)])
        for range in result.read?.returnedRange ?? [] {
            guard range.conversationId == window.id, let first = range.fromNodeId, let end = range.lastNodeId,
                  let a = nodes.firstIndex(of: first), let b = nodes.firstIndex(of: end), a <= b,
                  Set(nodes[a...b]).isSubset(of: allowed) else { guardrail.originalOverrun = true; continue }
        }
    }
}
