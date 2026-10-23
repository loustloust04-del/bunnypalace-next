import Foundation

/// 修复第一刀·刀5：设置页的「实际注入量」。
/// 只在真实发送的组装路径记账（ConversationViewModel.assemblePrompt）；token 用注入器同一条计费公式
/// （MemoryInjector.injectedCost）按本轮命中逐条累加——不另写近似。
struct MemoryInjectionRecord: Codable, Equatable {
    var tokens: Int
    var stableCount: Int
    var hitCount: Int
    var at: Date
    /// 上一轮走 cc-bridge：CC 只收最后一条用户原文，花园组装的记忆注入整个不发（nil = 旧记录 = false）
    var viaCCBridge: Bool? = nil
    /// 第二刀 B3：「我的记忆」那一段（nil = 旧记录 = 0）
    var selfTokens: Int? = nil
    var selfCount: Int? = nil
    /// v4-1 §六：这一轮注进去的时间轴条目（「日期|窗口编号」）和上下文摘要段（「窗口前 8 位|最后一条消息 id」）；nil = 旧记录
    var timelineKeys: [String]? = nil
    var contextKeys: [String]? = nil
}

enum MemoryInjectionMeter {
    private static func key(_ profileId: String) -> String { "mem_last_injection_\(profileId)" }

    static func measure(hits: [InjectionHit], memories: [Memory]) -> (tokens: Int, stable: Int, hit: Int) {
        let byId = Dictionary(memories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tokens = hits.reduce(0) { sum, h in
            sum + (byId[h.memoryId].map { MemoryInjector.injectedCost($0, catalog: h.catalog) } ?? 0)
        }
        let stable = hits.filter { $0.retrieverId == "persistent" }.count
        return (tokens, stable, hits.count - stable)
    }

    /// 没变就不写（每轮发送都会调，UserDefaults 不该被刷）
    static func record(profileId: String, hits: [InjectionHit], memories: [Memory], selfTokens: Int = 0, selfCount: Int = 0,
                       timelineKeys: [String] = [], contextKeys: [String] = []) {
        guard !profileId.isEmpty else { return }
        let m = measure(hits: hits, memories: memories)
        if let old = load(profileId: profileId), old.viaCCBridge != true,
           old.tokens == m.tokens, old.stableCount == m.stable, old.hitCount == m.hit,
           (old.selfTokens ?? 0) == selfTokens, (old.selfCount ?? 0) == selfCount,
           (old.timelineKeys ?? []) == timelineKeys, (old.contextKeys ?? []) == contextKeys { return }
        let rec = MemoryInjectionRecord(tokens: m.tokens, stableCount: m.stable, hitCount: m.hit, at: Date(),
                                        selfTokens: selfTokens, selfCount: selfCount,
                                        timelineKeys: timelineKeys, contextKeys: contextKeys)
        if let data = try? JSONEncoder().encode(rec) {
            UserDefaults.standard.set(data, forKey: key(profileId))
        }
    }

    /// cc-bridge 路由在组装之后丢掉 system prompt：覆盖成「CC 没收到注入」，不记成已注入
    static func recordCCBridge(profileId: String) {
        guard !profileId.isEmpty else { return }
        if load(profileId: profileId)?.viaCCBridge == true { return }
        let rec = MemoryInjectionRecord(tokens: 0, stableCount: 0, hitCount: 0, at: Date(), viaCCBridge: true)
        if let data = try? JSONEncoder().encode(rec) {
            UserDefaults.standard.set(data, forKey: key(profileId))
        }
    }

    /// 纯函数（astra #11）：组装后真留下来的时间轴条目——插槽关了 / 预设里没有插槽时组装不出时间轴段，一条都不算；
    /// 有时间轴段时只算段里真出现的那几行
    static func keptTimelineEntries(_ entries: [TimelineEntry], in segments: [TaggedSegment]) -> [TimelineEntry] {
        let text = segments.filter { $0.source == .timeline }.map(\.content).joined(separator: "\n")
        guard !text.isEmpty else { return [] }
        return entries.filter { text.contains(TimelineStore.line($0, withPending: false)) }
    }

    /// 记账的键：时间轴条目 =「日期|窗口编号」
    static func key(_ e: TimelineEntry) -> String { "\(e.dayKey)|\(e.conversationId)" }

    /// 记账的键：上下文摘要段 =「窗口前 8 位|最后一条消息 id」（改造前的累计摘要没有 id，记 legacy）
    static func key(conversationId: String, segment: SessionSegment) -> String {
        "\(conversationId.prefix(8))|\(segment.lastNodeId ?? "legacy")"
    }

    static func load(profileId: String) -> MemoryInjectionRecord? {
        guard let data = UserDefaults.standard.data(forKey: key(profileId)) else { return nil }
        return try? JSONDecoder().decode(MemoryInjectionRecord.self, from: data)
    }

    static func clear(profileId: String) {
        UserDefaults.standard.removeObject(forKey: key(profileId))
    }
}
