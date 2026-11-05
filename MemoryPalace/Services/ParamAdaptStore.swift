import Foundation

/// 按「地址 + 模型」记住这个模型不收哪些参数（#094 plan-param-autoadapt §3.3，学 magpie gateway.go `unfit` 表，差别是落盘 + 设置里能看能清）。
/// 存 UserDefaults 一个小字典（主线程不碰文件；测试宿主的 standard 已换成本工位 suite），最多 200 条，超了删最老的。
/// 只会「去掉」，不会「加回来」；清掉后下次照常发，再被拒会再学一次。
@Observable
final class ParamAdaptStore: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        var learned: ParamCompat.Learned
        var learnedAt: Date
        /// 原始报错前 300 字（设置页看）
        var rawError: String
        var baseURL: String
        var modelId: String
        /// ProviderType.rawValue（astra #6：同一地址的 OpenAI 兼容口和 Anthropic 口各记各的）；老条目没有
        var providerType: String?
    }

    static let shared = ParamAdaptStore(defaults: .standard)
    static let defaultsKey = "paramAdaptByEndpoint.v1"
    static let limit = 200

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let lock = NSLock()
    private var table: [String: Entry]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        table = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// 键 = 协议类型 | 地址 | 模型 id（小写）。同协议同地址不同 key 共享。
    /// 地址只规范 scheme / host 大小写、去尾 `/`，路径大小写保留（astra #7：`/TenantA` 和 `/tenanta` 是两个路由）
    static func key(providerType: ProviderType, baseURL: String, modelId: String) -> String {
        providerType.rawValue + "|" + normalizedBase(baseURL) + "|" + modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedBase(_ baseURL: String) -> String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard var parts = URLComponents(string: base) else { return base }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        return parts.string ?? base
    }

    func entry(providerType: ProviderType, baseURL: String, modelId: String) -> Entry? {
        let k = Self.key(providerType: providerType, baseURL: baseURL, modelId: modelId)
        return lock.withLock { table[k] }
    }

    struct Row: Identifiable {
        let key: String
        let entry: Entry
        var id: String { key }
    }

    /// 新的在前
    var all: [Row] {
        lock.withLock { table.map { Row(key: $0.key, entry: $0.value) } }
            .sorted { ($0.entry.learnedAt, $0.key) > ($1.entry.learnedAt, $1.key) }
    }

    /// 合并进已有的一条（组取并集；键名 / 思考格式有新的就换）
    func learn(providerType: ProviderType, baseURL: String, modelId: String, adding delta: ParamCompat.Learned,
               rawError: String, now: Date = Date()) {
        let k = Self.key(providerType: providerType, baseURL: baseURL, modelId: modelId)
        lock.withLock {
            var learned = table[k]?.learned ?? ParamCompat.Learned()
            learned.groups.formUnion(delta.groups)
            if delta.groups.contains(ParamCompat.Group.reasoningReplayRequired) { learned.groups.remove(ParamCompat.Group.reasoningReplay) }
            if delta.groups.contains(ParamCompat.Group.reasoningReplay) { learned.groups.remove(ParamCompat.Group.reasoningReplayRequired) }
            if let key = delta.maxTokensKey { learned.maxTokensKey = key }
            if let format = delta.thinkingFormat { learned.thinkingFormat = format }
            guard learned != ParamCompat.Learned() else { return }
            table[k] = Entry(learned: learned, learnedAt: now, rawError: String(rawError.prefix(300)),
                             baseURL: baseURL, modelId: modelId, providerType: providerType.rawValue)
            if table.count > Self.limit {
                let oldest = table.sorted { ($0.value.learnedAt, $0.key) < ($1.value.learnedAt, $1.key) }
                for (key, _) in oldest.prefix(table.count - Self.limit) { table[key] = nil }
            }
            persistLocked()
        }
    }

    func remove(key: String) {
        lock.withLock {
            table[key] = nil
            persistLocked()
        }
    }

    func removeAll() {
        lock.withLock {
            table = [:]
            persistLocked()
        }
    }

    private func persistLocked() {
        if table.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(table) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension ParamAdaptStore.Entry {
    var host: String { URL(string: baseURL)?.host ?? baseURL }

    var typeLabel: String {
        switch providerType {
        case ProviderType.anthropic.rawValue: return "Anthropic"
        case ProviderType.openaiCompatible.rawValue: return "OpenAI 兼容"
        default: return ""
        }
    }

    var summary: String { learned.summary }
}
