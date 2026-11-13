import CryptoKit
import Foundation

/// 生产者吐出的一份保留单位（不落库，plan-memory-receipt §2.1）。
/// `text` = 生产者拼进层的那一块，一字不差——核存活时要拿它去最终段里找。
public struct RecallDeliveryUnit: Sendable, Equatable {
    public enum Segment: String, Sendable {
        case memoryStable, memoryVolatile, contextSummary, timeline, volatileContext
    }

    /// `RecallDeliveryItem.Kind` 里的常量
    public let kind: String
    /// `MemoryDelivery.key(...)`
    public let ref: String
    public let version: String?
    public let text: String
    /// X 项 = `RecallItem.tokenCost`，其余 `Memory.estimateTokens(text)`
    public let tokens: Int
    /// 生产者给的人话短文，`build` 截 60 字
    public let shown: String
    /// 聚合项成员（B4 全文 slug / Z7 节点 id / 过期提醒 memory id），`build` 截 50 个
    public let members: [String]?
    public let segment: Segment

    public init(kind: String, ref: String, version: String? = nil, text: String, tokens: Int,
                shown: String, members: [String]? = nil, segment: Segment) {
        self.kind = kind
        self.ref = ref
        self.version = version
        self.text = text
        self.tokens = tokens
        self.shown = shown
        self.members = members
        self.segment = segment
    }
}

/// 落库的一项（回执 `delivery.items`）。
public struct RecallDeliveryItem: Codable, Equatable, Sendable {
    /// String 常量，不用 Codable 枚举：加种类不炸旧 build 的解码。
    public enum Kind {
        public static let selfMemory = "self"
        public static let rootIndex = "rootIndex"
        public static let pinned = "pinned"
        public static let expiredReminder = "expiredReminder"
        public static let previousWindow = "previousWindow"
        public static let page = "page"
        public static let card = "card"
        public static let fragment = "fragment"
        public static let legacyFragment = "legacyFragment"
        public static let a2 = "a2"
        public static let timeline = "timeline"
        public static let pending = "pending"
        public static let anniversary = "anniversary"
        public static let journal = "journal"
    }

    public let kind: String
    public let ref: String
    public let version: String?
    public let shown: String
    public let tokens: Int
    public var members: [String]? = nil
    /// 仅本机截断截了一半；nil = 整块上 wire
    public var trimmed: Bool? = nil

    public init(kind: String, ref: String, version: String? = nil, shown: String, tokens: Int,
                members: [String]? = nil, trimmed: Bool? = nil) {
        self.kind = kind
        self.ref = ref
        self.version = version
        self.shown = shown
        self.tokens = tokens
        self.members = members
        self.trimmed = trimmed
    }
}

/// 一轮的门控快照（`off` / 六项 / legacy / 触发关 / 来源窗挡掉数）。
public struct RecallGateSnapshot: Codable, Equatable, Sendable {
    /// `EffectiveMemoryParticipation.off?.rawValue`；nil = 开
    public let off: String?
    public let participates: Bool
    /// `!switches.archiveTrigger`
    public let triggerOff: Bool
    public let legacy: Bool
    /// 解析后六项：timeline / pending / selfMemory / archive / previousWindow / pinned
    public let choices: [String: Bool]
    public let a2Checked: Bool
    /// 候选数：`roundInputs` 被来源窗挡掉的条数（不保证本来会上 wire）；`off != nil` 时恒 0
    public let hiddenFragments: Int
    /// 候选数：`TimelineStore.injection` 按 `hiddenConversations` 挡掉的项 + 老条目（勾着时间轴才数）
    /// + 待续窗（不保证本来会上 wire）；`!participates` 时恒 0
    public let hiddenTimeline: Int

    public init(off: String?, participates: Bool, triggerOff: Bool, legacy: Bool, choices: [String: Bool],
                a2Checked: Bool, hiddenFragments: Int, hiddenTimeline: Int) {
        self.off = off
        self.participates = participates
        self.triggerOff = triggerOff
        self.legacy = legacy
        self.choices = choices
        self.a2Checked = a2Checked
        self.hiddenFragments = hiddenFragments
        self.hiddenTimeline = hiddenTimeline
    }
}

/// 一次真实请求的「自动带了什么」：卡 = 检查器 = 消息账 = Meter 的唯一来源。
public struct RecallDelivery: Codable, Equatable, Sendable {
    /// items 编码后的内容 hash（续轮 / 重试判「同一份」）
    public let id: String
    /// `"api"` | `"local"` | `"ccBridge"`
    public let route: String
    /// CC 恒空
    public let items: [RecallDeliveryItem]
    public let gate: RecallGateSnapshot

    public init(id: String, route: String, items: [RecallDeliveryItem], gate: RecallGateSnapshot) {
        self.id = id
        self.route = route
        self.items = items
        self.gate = gate
    }
}

public enum MemoryDelivery {
    public enum Located: Equatable, Sendable {
        case full, partial, none
    }

    /// 与 `MemoryBenchRecallReader.key(page:version:)` / `key(card:version:)` / `"memory:\(uuid)"` 同式。
    public static func key(_ ref: RecallSourceRef) -> String {
        switch ref.kind {
        case .page: return "page:\(ref.path)|\(ref.version)"
        case .card: return "card:\(ref.path)|\(ref.version)"
        case .fragment: return "memory:\(ref.path)"
        }
    }

    /// `locate` 判 none 的丢掉；partial 标 trimmed 且不写 nil；shown 截 60 字、members 截 50 个；
    /// `id` = items 按顺序编码后的内容 hash（同 items 同 id，内容变 id 变）。
    public static func build(units: [RecallDeliveryUnit], route: String, gate: RecallGateSnapshot,
                             locate: (RecallDeliveryUnit) -> Located) -> RecallDelivery {
        var items: [RecallDeliveryItem] = []
        for unit in units {
            let trimmed: Bool?
            switch locate(unit) {
            case .none: continue
            case .partial: trimmed = true
            case .full: trimmed = nil
            }
            items.append(RecallDeliveryItem(
                kind: unit.kind, ref: unit.ref, version: unit.version,
                shown: String(unit.shown.prefix(60)), tokens: unit.tokens,
                members: unit.members.map { Array($0.prefix(50)) }, trimmed: trimmed))
        }
        return RecallDelivery(id: digest(items), route: route, items: items, gate: gate)
    }

    /// 按段游标顺序 `contains`：同段里每单位只认游标之后下一次出现，找不到 = none（不产生 partial）。
    public static func containmentLocator(_ segments: [RecallDeliveryUnit.Segment: String],
                                          transform: @escaping (String) -> String) -> (RecallDeliveryUnit) -> Located {
        var cursors: [RecallDeliveryUnit.Segment: String.Index] = [:]
        return { unit in
            guard let text = segments[unit.segment] else { return .none }
            let needle = transform(unit.text)
            guard !needle.isEmpty else { return .none }
            let start = cursors[unit.segment] ?? text.startIndex
            guard let range = text.range(of: needle, range: start..<text.endIndex) else { return .none }
            cursors[unit.segment] = range.upperBound
            return .full
        }
    }

    private static let itemsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// SHA-256 前 16 位十六进制（与 `MemoryBench.digest` 同式）
    private static func digest(_ items: [RecallDeliveryItem]) -> String {
        let data = (try? itemsEncoder.encode(items)) ?? Data()
        return String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
