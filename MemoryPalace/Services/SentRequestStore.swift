import Foundation
import Observation

/// #089 P0-c：发出去那一刻的请求体原样存一份（粟粟：「检查器的 body 应该跟真 body 一模一样」）。
/// 按对话只留最近一个回合（同一条 assistant 回复）：工具循环里每次请求、上限越界重试都各记一份，第 1 份 = 和「下一轮预览」对应的那份。
/// 只存 body 字节（key 在请求头里，不存头）；地址去掉 query；body 里出现这张卡的 key（原文和 JSON 转义后的样子）换成 `<API key>`。
/// 读写盘都在后台队列；磁盘和内存都只留最近 30 个对话。
struct SentRequest: Codable, Equatable {
    /// 工具循环第几轮（0 = 回合第一次请求；重试和原请求同一轮）
    var round: Int
    var sentAt: Date
    var model: String
    var url: String
    var body: String
}

struct SentTurn: Codable, Equatable {
    var conversationId: String
    /// 这一回合的 assistant 节点 id：换了就是新回合
    var turnId: String?
    var requests: [SentRequest]
}

@MainActor
@Observable
final class SentRequestStore {
    static let shared = SentRequestStore(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MemoryPalace/last-request", isDirectory: true))

    nonisolated static let keepConversations = 30
    nonisolated static let redactedKey = "<API key>"

    @ObservationIgnored let directory: URL
    @ObservationIgnored private var cache: [String: SentTurn] = [:]
    @ObservationIgnored private var recency: [String] = []   // 最近用过的在后
    /// 每个对话存了几次：检查器读它，同一对话里新请求进来就刷新
    private(set) var versions: [String: Int] = [:]
    @ObservationIgnored private let io = DispatchQueue(label: "SentRequestStore.io", qos: .utility)

    init(directory: URL) {
        self.directory = directory
    }

    func version(_ conversationId: String) -> Int { versions[conversationId] ?? 0 }

    /// 网络层回调（主线程）：turnId 变了开新回合，否则追加（工具循环下一轮、上限越界重试都追加）
    func record(conversationId: String, turnId: String?, round: Int, model: String, request: URLRequest, secrets: [String]) {
        guard let data = request.httpBody else { return }
        let sent = SentRequest(round: round, sentAt: Date(), model: model,
                               url: Self.strippedURL(request.url), body: Self.redact(String(decoding: data, as: UTF8.self), secrets: secrets))
        var turn = cache[conversationId] ?? SentTurn(conversationId: conversationId, turnId: turnId, requests: [])
        if turn.turnId != turnId || turnId == nil { turn = SentTurn(conversationId: conversationId, turnId: turnId, requests: []) }
        turn.requests.append(sent)
        remember(turn)
        versions[conversationId, default: 0] += 1
        let file = fileURL(conversationId)
        let dir = directory
        let snapshot = turn
        io.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            try? encoded.write(to: file, options: .atomic)
            Self.prune(dir, keep: Self.keepConversations)
        }
    }

    /// 检查器读：内存里有就用，没有（重启过）去盘上读，都在后台
    func latest(conversationId: String) async -> SentTurn? {
        if let hit = cache[conversationId] { return hit }
        let file = fileURL(conversationId)
        let loaded: SentTurn? = await withCheckedContinuation { cont in
            io.async {
                let turn = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SentTurn.self, from: $0) }
                cont.resume(returning: turn)
            }
        }
        if let hit = cache[conversationId] { return hit }
        if let loaded { remember(loaded) }
        return loaded
    }

    /// 内存也只留最近 30 个对话（含图片 base64 的 body 不能一直攒着）
    private func remember(_ turn: SentTurn) {
        cache[turn.conversationId] = turn
        recency.removeAll { $0 == turn.conversationId }
        recency.append(turn.conversationId)
        while recency.count > Self.keepConversations {
            cache[recency.removeFirst()] = nil
        }
    }

    private func fileURL(_ conversationId: String) -> URL {
        let safe = String(conversationId.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.prefix(80))
        return directory.appendingPathComponent("\(safe).json")
    }

    nonisolated static func strippedURL(_ url: URL?) -> String {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? ""
    }

    /// key 在 body 里可能是原文、JSON 转义过一次（`/` → `\/`）、或在工具参数字符串里再转义一次——几种样子都换掉。空 key 不处理
    nonisolated static func redact(_ body: String, secrets: [String]) -> String {
        var forms: Set<String> = []
        for secret in secrets where !secret.isEmpty {
            let once = jsonEscaped(secret)
            forms.formUnion([secret, once, jsonEscaped(once)])
        }
        return forms.sorted { $0.count > $1.count }.reduce(body) { $0.replacingOccurrences(of: $1, with: redactedKey) }
    }

    nonisolated private static func jsonEscaped(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let text = String(data: data, encoding: .utf8), text.count >= 4 else { return s }
        return String(text.dropFirst(2).dropLast(2))
    }

    nonisolated private static func prune(_ dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > keep else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) {
            try? fm.removeItem(at: file)
        }
    }
}
