import Foundation

/// C2 整理的「并」单独一步（plan-c2-write-shape §1.2：和「留 / 删」一起判时便宜模型并不动）。两小步：
/// ① 分组：只看卡的正文，把说同一件事的卡圈成一组；② 合并：一组一组对着出处原文并成尽量少的几张。
/// 只有提示词、解析和「跑一遍」；落库在调用方
public enum FragmentMerger {
    public struct Card: Equatable, Sendable {
        public let id: String
        public let content: String
        public let source: String

        public init(id: String, content: String, source: String) {
            self.id = id
            self.content = content
            self.source = source
        }
    }

    /// 并出来的一张：content = 并好的整句，from = 它吸收了哪几张
    public struct Merged: Codable, Equatable, Sendable {
        public let content: String
        public let from: [String]

        public init(content: String, from: [String]) {
            self.content = content
            self.from = from
        }
    }

    public static let maxContentChars = 200
    /// 一组太大时并出来容易丢东西，超过就不并（留给她）
    public static let maxGroupSize = 12

    // MARK: - ① 分组

    public static func groupSystemPrompt(names: MemoryExtractor.Names) -> String {
        """
        下面是一份关于\(names.user)的长期档案里的卡，一行一张，前面是编号。这份档案的毛病是同一件事被切成了好几张：同一只宠物的来历拆成五六张，同一个约定换了说法记了两遍，同一种偏好分三次各记一句。

        请把**说的是同一件事**的卡圈成一组。判断标准：如果把这几张并成一张，读起来是一个完整的事实，而不是硬凑在一起的清单，它们就是一组。
        - 同一个人、同一样东西、同一段经历、同一个约定、同一种习惯的不同侧面 → 一组。
        - 只是都和\(names.user)有关、都是偏好、都发生在同一天，不算同一件事。
        - 一组 2 到 \(maxGroupSize) 张。一张卡最多进一组。找不到同伴的卡不用写。

        只输出一个 JSON 对象，不要别的字：{"groups":[["3","17","42"],["8","9"]]}。没有可并的就 {"groups":[]}。
        """
    }

    public static func groupUserContent(_ cards: [Card]) -> String {
        cards.map { "[\($0.id)] \($0.content)" }.joined(separator: "\n")
    }

    /// 不认识的编号丢掉；一张卡出现在两组里只算先出现的那组；丢完不足 2 张或超过上限的组不要
    public static func parseGroups(_ raw: String, ids: Set<String>) -> [[String]]? {
        struct Envelope: Decodable { let groups: [[Flexible]] }
        struct Flexible: Decodable {
            let value: String
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let text = try? c.decode(String.self) { value = text } else { value = String(try c.decode(Int.self)) }
            }
        }
        guard let text = FragmentPool.strictObjectText(raw), let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        var used: Set<String> = []
        var out: [[String]] = []
        for group in envelope.groups {
            var members: [String] = []
            for id in group.map(\.value) where ids.contains(id) && !used.contains(id) && !members.contains(id) {
                members.append(id)
            }
            guard (2...maxGroupSize).contains(members.count) else { continue }
            used.formUnion(members)
            out.append(members)
        }
        return out
    }

    // MARK: - ② 合并

    public static func mergeSystemPrompt(names: MemoryExtractor.Names) -> String {
        """
        下面几张卡出自一份关于\(names.user)的长期档案，它们说的是同一件事，被切碎了。每张卡带着它的出处原文——原文是事实。

        请把它们并成尽量少的几张（通常一张）。要求：
        - 并好的每一张是一个完整的事实：过一个月\(names.char)翻到它，不看原来的对话就读得懂、用得上。
        - 不丢信息：原来几张里的具体内容（名字、日子、数字、原因）都要在。也不添信息：原文和原卡里没有的不写。
        - 几张卡互相矛盾时以原文为准；原文也分不清的，就不要并，原样各留一张。
        - 确实是两件不同的事，就并成两张，不要硬凑成一句。
        - 每张不超过 \(maxContentChars) 字，主语写名字，不用「我」「你」。

        只输出一个 JSON 对象，不要别的字：{"cards":[{"content":"……","from":["3","17","42"]}]}。from 写这张吸收了哪几张的编号；每个编号正好出现一次。
        """
    }

    public static func mergeUserContent(_ group: [Card]) -> String {
        group.map { "[\($0.id)] \($0.content)\n出处原文：\n" + ($0.source.isEmpty ? "（找不到出处）" : $0.source) }
            .joined(separator: "\n\n———\n\n")
    }

    /// 这一组的每个编号正好被吸收一次、每张都有不超长的正文才算数
    public static func parseMerged(_ raw: String, group ids: [String]) -> [Merged]? {
        struct Envelope: Decodable { let cards: [Row] }
        struct Row: Decodable {
            let content: String
            let from: [Flexible]
        }
        struct Flexible: Decodable {
            let value: String
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let text = try? c.decode(String.self) { value = text } else { value = String(try c.decode(Int.self)) }
            }
        }
        guard let text = FragmentPool.strictObjectText(raw), let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), !envelope.cards.isEmpty else { return nil }
        let rows = envelope.cards.map { Merged(content: $0.content.trimmingCharacters(in: .whitespacesAndNewlines), from: $0.from.map(\.value)) }
        let all = rows.flatMap(\.from)
        guard all.count == ids.count, Set(all) == Set(ids),
              rows.allSatisfy({ !$0.content.isEmpty && $0.content.count <= maxContentChars && !$0.from.isEmpty }) else { return nil }
        return rows
    }

    // MARK: - 跑

    public struct Outcome: Codable, Equatable, Sendable {
        /// 模型圈出来的组
        public var groups: [[String]]
        /// 并成功的结果（每条的 from 是一组里的若干张）
        public var merged: [Merged]
        /// 圈了组但没并成（两次都不合格）：原样留着，记下来
        public var failedGroups: [[String]]

        public init(groups: [[String]] = [], merged: [Merged] = [], failedGroups: [[String]] = []) {
            self.groups = groups
            self.merged = merged
            self.failedGroups = failedGroups
        }

        /// 真的少了几张（并之前这些组的张数 − 并之后的张数）
        public var removed: Int {
            merged.reduce(0) { $0 + $1.from.count } - merged.count
        }
    }

    /// 分组一次调用（不合格重来一次，还不行 = 这次不并）；每组一次调用（不合格重来一次，还不行这组原样留）
    public static func run(_ cards: [Card], names: MemoryExtractor.Names, caller: @escaping SessionSegmentWriter.Caller,
                           concurrent: Int = 3) async throws -> Outcome {
        guard cards.count >= 2 else { return Outcome() }
        let ids = Set(cards.map(\.id))
        let system = groupSystemPrompt(names: names)
        let user = groupUserContent(cards)
        var groups = try await caller(system, user).flatMap { parseGroups($0, ids: ids) }
        if groups == nil {
            groups = try await caller(system, user + "\n\n（上一次交的不合格：只输出 {\"groups\":[[…],[…]]} 这一个 JSON 对象。重交。）")
                .flatMap { parseGroups($0, ids: ids) }
        }
        guard let groups, !groups.isEmpty else { return Outcome() }
        let byId = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var outcome = Outcome(groups: groups)
        let mergeSystem = mergeSystemPrompt(names: names)
        try await withThrowingTaskGroup(of: (Int, [Merged]?).self) { tasks in
            var next = 0
            func addNext() {
                guard next < groups.count else { return }
                let index = next
                next += 1
                let members = groups[index].compactMap { byId[$0] }
                let groupIds = groups[index]
                tasks.addTask {
                    let content = mergeUserContent(members)
                    if let done = try await caller(mergeSystem, content).flatMap({ parseMerged($0, group: groupIds) }) { return (index, done) }
                    let retry = try await caller(mergeSystem, content + "\n\n（上一次交的不合格：每个编号正好出现一次，每张不超过 \(maxContentChars) 字。重交。）")
                    return (index, retry.flatMap { parseMerged($0, group: groupIds) })
                }
            }
            for _ in 0..<min(max(concurrent, 1), groups.count) { addNext() }
            var results: [Int: [Merged]?] = [:]
            while let (index, rows) = try await tasks.next() {
                results[index] = rows
                addNext()
            }
            for index in groups.indices {
                if let rows = results[index] ?? nil { outcome.merged += rows } else { outcome.failedGroups.append(groups[index]) }
            }
        }
        return outcome
    }
}
