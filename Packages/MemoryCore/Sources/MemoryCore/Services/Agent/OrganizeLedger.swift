import Foundation

// 整理 agent 的数据面（plan-organize-agent §3.2 / §3.5）：卡和原文从 `OrganizeSource` 来，结论记进 `OrganizeLedger`。
// 结论存在循环外面：上下文裁掉也不丢，随时能存盘续跑。

public struct OrganizeCard: Sendable, Equatable, Codable {
    public enum Zone: String, Sendable, Codable {
        /// 她还没看过的：agent 随便整理
        case draft
        /// 她 Approve 过的：agent 只能提 Suggestion
        case archive
        /// 连 Suggestion 都不许提
        case locked
    }

    public let id: String
    public let content: String
    public let day: String?
    public let zone: Zone

    public init(id: String, content: String, day: String? = nil, zone: Zone = .draft) {
        self.id = id
        self.content = content
        self.day = day
        self.zone = zone
    }
}

public struct OrganizeSourceLine: Sendable, Equatable {
    /// 给模型看的定位（「窗口 2 · #37」这种），原样回显
    public let marker: String
    public let who: String
    public let when: String?
    public let text: String
    /// 是不是这张卡出处的那一条
    public let isOrigin: Bool

    public init(marker: String, who: String, when: String? = nil, text: String, isOrigin: Bool = false) {
        self.marker = marker
        self.who = who
        self.when = when
        self.text = text
        self.isOrigin = isOrigin
    }
}

/// agent 读卡和原文的口子。memoryd 读副本，app 读库
public protocol OrganizeSource: Sendable {
    /// 这次整理看得到的全部卡（Draft 在前，按写入先后）
    func cards() throws -> [OrganizeCard]
    /// 一张卡出处那条和前后几条原文；找不到出处 = 空
    func source(of card: String, before: Int, after: Int) throws -> [OrganizeSourceLine]
    /// 按词搜原文（跨窗口）
    func search(_ terms: String, limit: Int) throws -> [OrganizeSourceLine]
}

/// 整理的结论本。一条结论 = 一组原卡的去处
public struct OrganizeLedger: Sendable, Equatable, Codable {
    public enum Action: String, Sendable, Codable, CaseIterable {
        /// 原样留下（一张卡）
        case keep
        /// 几张说的是同一件事，并成一条
        case merge
        /// 事是真的，但要重写（对着原文改对、改全、改清楚）
        case rewrite
        /// 不进档案
        case drop
        /// 拿不准，交给她
        case unsure
    }

    public struct Entry: Sendable, Equatable, Codable {
        public var action: Action
        /// 这条结论吸收了哪几张原卡
        public var cards: [String]
        /// 整理后的整句（drop / unsure 没有；keep 没写 = 用原卡的字）
        public var content: String?
        public var confidence: Double?
        public var why: String?
        /// 动到了她 Approve 过的卡：只能当 Suggestion 给她看
        public var suggestion: Bool

        public init(action: Action, cards: [String], content: String? = nil, confidence: Double? = nil, why: String? = nil, suggestion: Bool = false) {
            self.action = action
            self.cards = cards
            self.content = content
            self.confidence = confidence
            self.why = why
            self.suggestion = suggestion
        }
    }

    public static let maxContentChars = 400

    public private(set) var entries: [Entry] = []

    public init() {}

    /// 一次 `record` 里的一条，模型给的原样（松解码）
    public struct Item: Sendable, Equatable {
        public var action: String
        public var cards: [String]
        public var content: String?
        public var confidence: Double?
        public var why: String?

        public init(action: String, cards: [String], content: String? = nil, confidence: Double? = nil, why: String? = nil) {
            self.action = action
            self.cards = cards
            self.content = content
            self.confidence = confidence
            self.why = why
        }
    }

    public struct Receipt: Sendable, Equatable {
        public var accepted = 0
        /// 退回的每条说清为什么，模型好改
        public var rejected: [String] = []
    }

    /// 哪些卡已经有去处
    public var decided: Set<String> { Set(entries.flatMap(\.cards)) }

    /// 记一批。逐条校验，坏的退回并说明，不连累别的；同一张卡后记的顶掉先记的
    public mutating func record(_ items: [Item], cards all: [OrganizeCard]) -> Receipt {
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var receipt = Receipt()
        for (offset, item) in items.enumerated() {
            let label = "第 \(offset + 1) 条"
            guard let action = Action(rawValue: item.action) else {
                receipt.rejected.append("\(label)：action「\(item.action)」不认识，只能是 \(Action.allCases.map(\.rawValue).joined(separator: " / "))")
                continue
            }
            var ids: [String] = []
            for id in item.cards where !ids.contains(id) { ids.append(id) }
            guard !ids.isEmpty else {
                receipt.rejected.append("\(label)：cards 是空的")
                continue
            }
            if let missing = ids.first(where: { byId[$0] == nil }) {
                receipt.rejected.append("\(label)：没有编号为 \(missing) 的卡")
                continue
            }
            if let locked = ids.first(where: { byId[$0]?.zone == .locked }) {
                receipt.rejected.append("\(label)：卡 \(locked) 被她锁住了，不能动")
                continue
            }
            let content = item.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch action {
            case .keep where ids.count > 1:
                receipt.rejected.append("\(label)：keep 只能是一张卡；几张并成一条用 merge")
                continue
            case .merge where ids.count < 2:
                receipt.rejected.append("\(label)：merge 至少要两张卡；一张卡改写用 rewrite")
                continue
            case .merge, .rewrite:
                guard let content, !content.isEmpty else {
                    receipt.rejected.append("\(label)：\(action.rawValue) 要在 content 里写出整理后的整句")
                    continue
                }
                guard content.count <= Self.maxContentChars else {
                    receipt.rejected.append("\(label)：content 有 \(content.count) 字，超过 \(Self.maxContentChars)")
                    continue
                }
            default:
                if let content, content.count > Self.maxContentChars {
                    receipt.rejected.append("\(label)：content 有 \(content.count) 字，超过 \(Self.maxContentChars)")
                    continue
                }
            }
            if let confidence = item.confidence, !(0...1).contains(confidence) {
                receipt.rejected.append("\(label)：confidence 要在 0 到 1 之间")
                continue
            }
            // 后记的顶掉先记的：这些卡从旧结论里拿走，旧结论空了就删
            entries = entries.compactMap { old in
                var old = old
                old.cards.removeAll { ids.contains($0) }
                return old.cards.isEmpty ? nil : old
            }
            let touchesArchive = ids.contains { byId[$0]?.zone == .archive }
            entries.append(Entry(action: action, cards: ids,
                                 content: action == .drop || action == .unsure ? nil : (content?.isEmpty == false ? content : nil),
                                 confidence: action == .drop || action == .unsure ? nil : item.confidence,
                                 why: item.why?.trimmingCharacters(in: .whitespacesAndNewlines),
                                 suggestion: touchesArchive && action != .keep))
            receipt.accepted += 1
        }
        return receipt
    }

    /// 代码核对（`check` 工具和 `finish` 都用）：空 = 都对上了
    public func problems(cards all: [OrganizeCard]) -> [String] {
        var out: [String] = []
        let drafts = all.filter { $0.zone == .draft }.map(\.id)
        let done = decided
        let missing = drafts.filter { !done.contains($0) }
        if !missing.isEmpty {
            out.append("还有 \(missing.count) 张 Draft 卡没有结论：\(missing.prefix(30).joined(separator: "、"))\(missing.count > 30 ? "…" : "")")
        }
        // merge 的旧结论被后面的结论拿走了卡，只剩一张：整句可能已经不对了
        for entry in entries where entry.action == .merge && entry.cards.count < 2 {
            out.append("有一条 merge 现在只剩卡 \(entry.cards.joined(separator: "、"))（其余的后来改记到别处了）：请对这张重新下结论")
        }
        return out
    }

    /// 到顶没交完：没结论的 Draft 卡一律交给她
    public mutating func closeUndecided(cards all: [OrganizeCard], why: String) {
        let done = decided
        for card in all where card.zone == .draft && !done.contains(card.id) {
            entries.append(Entry(action: .unsure, cards: [card.id], why: why))
        }
    }
}
