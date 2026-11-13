import Foundation

/// 设置页消费发送时的逐轮快照；不重新检索或按现库重建旧账。
public struct MemoryInjectionRecord: Codable, Equatable, Sendable {
    public var tokens: Int
    public var stableCount: Int
    public var hitCount: Int
    public var at: Date
    /// 上一轮走 cc-bridge：CC 只收最后一条用户原文，花园组装的记忆注入整个不发（nil = 旧记录 = false）
    public var viaCCBridge: Bool? = nil
    /// 第二刀 B3：「我的记忆」那一段（nil = 旧记录 = 0）
    public var selfTokens: Int? = nil
    public var selfCount: Int? = nil
    /// v4-1 §六：这一轮注进去的时间轴（一天「日期」、一项「日期|窗口编号|末条消息 id」、老条目「日期|窗口编号」）
    /// 和上下文摘要段（「窗口前 8 位|最后一条消息 id」）；nil = 旧记录
    public var timelineKeys: [String]? = nil
    public var contextKeys: [String]? = nil
    /// 记这一轮的是哪个窗口；nil = 旧记录
    public var conversationId: String? = nil

    public init(tokens: Int, stableCount: Int, hitCount: Int, at: Date, viaCCBridge: Bool? = nil,
                selfTokens: Int? = nil, selfCount: Int? = nil, timelineKeys: [String]? = nil, contextKeys: [String]? = nil,
                conversationId: String? = nil) {
        self.tokens = tokens
        self.stableCount = stableCount
        self.hitCount = hitCount
        self.at = at
        self.viaCCBridge = viaCCBridge
        self.selfTokens = selfTokens
        self.selfCount = selfCount
        self.timelineKeys = timelineKeys
        self.contextKeys = contextKeys
        self.conversationId = conversationId
    }
}

public enum MemoryInjectionMeter {}

public extension MemoryInjectionMeter {
    private static func key(_ profileId: String) -> String { "mem_last_injection_\(profileId)" }


    static func record(profileId: String, record: MemoryInjectionRecord) {
        guard !profileId.isEmpty else { return }
        if let data = try? JSONEncoder().encode(record) {
            MemoryReadEnvironment.defaults.set(data, forKey: key(profileId))
        }
    }

    /// cc-bridge 路由在组装之后丢掉 system prompt：覆盖成「CC 没收到注入」，不记成已注入
    static func recordCCBridge(profileId: String) {
        guard !profileId.isEmpty else { return }
        if load(profileId: profileId)?.viaCCBridge == true { return }
        let rec = MemoryInjectionRecord(tokens: 0, stableCount: 0, hitCount: 0, at: Date(), viaCCBridge: true)
        if let data = try? JSONEncoder().encode(rec) {
            MemoryReadEnvironment.defaults.set(data, forKey: key(profileId))
        }
    }


    /// 记账的键：上下文摘要段 =「窗口前 8 位|最后一条消息 id」（改造前的累计摘要没有 id，记 legacy）
    static func key(conversationId: String, segment: SessionSegment) -> String {
        "\(conversationId.prefix(8))|\(segment.lastNodeId ?? "legacy")"
    }

    static func load(profileId: String) -> MemoryInjectionRecord? {
        guard let data = MemoryReadEnvironment.defaults.data(forKey: key(profileId)) else { return nil }
        return try? JSONDecoder().decode(MemoryInjectionRecord.self, from: data)
    }

    static func clear(profileId: String) {
        MemoryReadEnvironment.defaults.removeObject(forKey: key(profileId))
    }
}
