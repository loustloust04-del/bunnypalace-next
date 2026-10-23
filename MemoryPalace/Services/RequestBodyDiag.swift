import Foundation

/// #089 请求体修复的日志：模型自己写出伪造的工具前缀 / 没查格式就发复杂卡 / 每个对话的缓存命中率。
/// 只记诊断日志（设置 → 调试），不改回复。
enum RequestBodyDiag {
    /// 客户端以前 / 现在会生成的标记；出现在模型自己的输出里 = 模仿了历史格式
    static let fakeToolMarkers = ["〔我在本对话做过的文件操作〕", "〔系统记录"]

    /// 直接写在静态 system 里的卡（P2-c），其余发前该先调 card_guide
    static let staticCardKinds: Set<String> = ["ask", "dice", "todo", "timer"]

    static func fakeMarkers(in text: String) -> [String] {
        fakeToolMarkers.filter { text.contains($0) }
    }

    /// 回复里出现、但本轮没调 card_guide 的复杂卡种
    static func uncheckedCardKinds(in text: String, segments: [MessageSegment]?) -> [String] {
        let calledGuide = segments?.contains {
            if case .toolUse(_, let name, _, _, _) = $0 { return name == CardGuideTool.toolName }
            return false
        } ?? false
        guard !calledGuide else { return [] }
        var kinds: [String] = []
        for match in text.matches(of: /```card-([a-z]+)/) {
            let kind = String(match.1)
            if !staticCardKinds.contains(kind), !kinds.contains(kind) { kinds.append(kind) }
        }
        return kinds
    }

    /// 一轮回复完成时调：有问题就记一条
    static func checkReply(_ text: String, segments: [MessageSegment]?) {
        let fake = fakeMarkers(in: text)
        if !fake.isEmpty { CacheDiagLog.shared.log("⚠️ 模型自己写了工具标记：\(fake.joined(separator: "、"))") }
        let cards = uncheckedCardKinds(in: text, segments: segments)
        if !cards.isEmpty { CacheDiagLog.shared.log("⚠️ 没调 card_guide 就发了卡：\(cards.joined(separator: "、"))") }
        let bad = ChatCardExtractor.malformed(in: text)
        if !bad.isEmpty { CacheDiagLog.shared.log("⚠️ 卡片格式不对、显示成了代码块：\(bad.joined(separator: "、"))") }
    }
}

/// 每个对话最近 20 次请求的缓存读 / 写，算命中率 = 读 ÷（读 + 写）。只在内存里
@MainActor
final class CacheHitMeter {
    static let shared = CacheHitMeter()
    private var samples: [String: [(read: Int, write: Int)]] = [:]

    /// 返回日志行；响应没带缓存字段（不是 Anthropic / 不支持）就不记
    @discardableResult
    func record(conversationId: String?, usage: TokenUsage?) -> String? {
        guard let conversationId, let usage, usage.cacheReadTokens != nil || usage.cacheWriteTokens != nil else { return nil }
        var list = samples[conversationId, default: []]
        list.append((usage.cacheReadTokens ?? 0, usage.cacheWriteTokens ?? 0))
        if list.count > 20 { list.removeFirst(list.count - 20) }
        samples[conversationId] = list
        let read = list.reduce(0) { $0 + $1.read }
        let write = list.reduce(0) { $0 + $1.write }
        guard read + write > 0 else { return nil }
        let line = "📦 缓存命中 最近 \(list.count) 次：读 \(read) / 写 \(write)（\(Int((Double(read) / Double(read + write) * 100).rounded()))%）"
        CacheDiagLog.shared.log(line)
        return line
    }
}
