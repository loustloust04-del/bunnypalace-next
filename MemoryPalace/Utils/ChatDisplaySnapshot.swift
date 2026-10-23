import Foundation

/// L4 A3（plan-chat-list-perf §3）：聊天列表的共享显示数据快照——纯数据层，不依赖 SwiftUI。
/// 旧页 CardFlowView 每次列表内容求值建一份（原来每泡 body 各算一遍），P1a 原生 cell 直接复用。
/// 版本 = 构造时的 path / 楼层 / 预设 / 卡 / 全局规则；这些变了调用方随列表求值重建。
final class ChatDisplaySnapshot {
    /// 显示阶段有效正则（全局 → 预设实例 → 绑定卡 / 楼层旧规则，⑤a 同发送一套解析），一份快照只解码一次
    let regexScripts: [RegexScript]
    private let path: [MessageNode]
    private var quoteIndex: [String: MessageNode]?

    init(path: [MessageNode], profile: Profile?, preset: Preset?, cards: [CharacterCard]) {
        self.path = path
        regexScripts = profile.map { RegexPipeline.scripts(profile: $0, preset: preset, cards: cards) } ?? []
    }

    /// reply_to 引用预览：优先落库的选段；老数据按 replyToId 在 path 里找（user 的 id 或 cc 的 ccMessageId）整条截断。
    /// 预览文字在查的这一刻读 target.content（观察依赖落在调用处，同原写法）
    func quotedPreview(for node: MessageNode) -> String? {
        if let rq = node.replyQuote, !rq.isEmpty { return String(rq.prefix(50)) }
        guard let rid = node.replyToId, let target = quoteTarget(rid) else { return nil }
        let t = target.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(50))
    }

    /// 首次需要时建索引；按 path 顺序先到先得 = 原 `first(where: { $0.id == rid || $0.ccMessageId == rid })`
    private func quoteTarget(_ rid: String) -> MessageNode? {
        if quoteIndex == nil {
            var index: [String: MessageNode] = [:]
            index.reserveCapacity(path.count * 2)
            for n in path {
                if index[n.id] == nil { index[n.id] = n }
                if let cc = n.ccMessageId, index[cc] == nil { index[cc] = n }
            }
            quoteIndex = index
        }
        return quoteIndex?[rid]
    }

    // MARK: segments 解码缓存

    private static let segmentLock = NSLock()
    nonisolated(unsafe) private static var segmentCache: [String: (data: Data, segments: [MessageSegment]?)] = [:]
    private static let segmentCacheLimit = 512

    /// `node.segments` 的缓存版：开关关时原样解码；开时按 node.id + segmentsData 全等命中（不用指纹，同长度改写也失效）
    static func segments(of node: MessageNode, enabled: Bool = ChatPerfSwitch.a3) -> [MessageSegment]? {
        guard enabled else { return node.segments }
        guard let data = node.segmentsData else { return nil }
        let id = node.id
        segmentLock.lock()
        let hit = segmentCache[id]
        segmentLock.unlock()
        if let hit, hit.data == data { return hit.segments }
        let decoded = try? JSONDecoder().decode([MessageSegment].self, from: data)
        segmentLock.lock()
        if segmentCache.count >= segmentCacheLimit { segmentCache.removeAll(keepingCapacity: true) }
        segmentCache[id] = (data, decoded)
        segmentLock.unlock()
        return decoded
    }
}
