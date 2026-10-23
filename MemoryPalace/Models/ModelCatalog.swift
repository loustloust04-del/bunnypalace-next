import Foundation

/// models.dev 目录里的一个模型（research-magpie 2.5）。只留我们用得上的字段。
struct CatalogModel: Codable, Equatable, Sendable {
    let id: String
    let providerId: String
    let name: String
    let contextTokens: Int?
    let outputTokens: Int?
    let reasoning: Bool
    /// `reasoning_options` 里 type=effort 的档位（low / medium / high…）；只支持 budget_tokens 的为空
    let reasoningEfforts: [String]
    /// nil = models.dev 没标价（不知道），不是免费
    let pricing: ModelPricing?
    /// models.dev `temperature`：false = 只收默认值（OpenAI 推理模型）；nil = 没标 / 旧缓存
    let temperature: Bool?
}

/// models.dev 模型目录：本地缓存 `api.json` 的精简版，TTL 1 天、后台刷新、失败保旧缓存。
/// 首次无网时目录为空，`PricingCatalog` 退回手写表。请求是公开 GET，不带任何用户数据。
final class ModelCatalog: @unchecked Sendable {
    static let sourceURL = URL(string: "https://models.dev/api.json")!
    static let ttl: TimeInterval = 24 * 60 * 60

    /// 测试宿主里不读粟粟的缓存、不联网（结果要可复现）
    static let shared: ModelCatalog = {
        // #035：已装好隔离的测试宿主直接认，不依赖 XCTest 类此刻是否已加载
        if TestHostIsolation.active || NSClassFromString("XCTestCase") != nil {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MemoryPalaceTests-catalog-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            return ModelCatalog(cacheURL: dir.appendingPathComponent("model-catalog.json"),
                                fetch: { throw URLError(.notConnectedToInternet) })
        }
        let dir = URL.applicationSupportDirectory.appendingPathComponent("MemoryPalace", isDirectory: true)
        return ModelCatalog(cacheURL: dir.appendingPathComponent("model-catalog.json"))
    }()

    private struct CacheFile: Codable {
        var fetchedAt: Date
        var models: [CatalogModel]
    }

    let cacheURL: URL
    private let fetch: @Sendable () async throws -> Data
    private let lock = NSLock()
    private var index: [String: CatalogModel] = [:]
    private var memo: [String: CatalogModel?] = [:]
    private var fetchedAt: Date?
    private var refreshing = false
    private var pricingNeedsRefresh = false

    init(cacheURL: URL, fetch: @escaping @Sendable () async throws -> Data = ModelCatalog.defaultFetch) {
        self.cacheURL = cacheURL
        self.fetch = fetch
    }

    @Sendable static func defaultFetch() async throws -> Data {
        var request = URLRequest(url: sourceURL, timeoutInterval: 30)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: - 查询

    func model(for modelId: String) -> CatalogModel? {
        let key = modelId.lowercased()
        return lock.withLock {
            if let hit = memo[key] { return hit }
            let found = Self.lookup(modelId, in: index)
            memo[key] = found
            return found
        }
    }

    // MARK: - 缓存 / 刷新

    /// app 启动调一次：后台读盘，过期再后台刷新。
    func bootstrap() {
        Task.detached(priority: .utility) { [self] in
            loadCache()
            await refreshIfStale(now: Date())
        }
    }

    @discardableResult
    func loadCache() -> Bool {
        guard let data = try? Data(contentsOf: cacheURL),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              !file.models.isEmpty else { return false }
        install(file.models, fetchedAt: file.fetchedAt)
        return true
    }

    func refreshIfStale(now: Date) async {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.quietNetwork { PerfGuardrails.suppress("modelCatalog"); return }   // 测量角色不拉 models.dev（perf P0 §3.1）
        #endif
        let proceed = lock.withLock { () -> Bool in
            if refreshing { return false }
            if !pricingNeedsRefresh, let fetchedAt, now.timeIntervalSince(fetchedAt) < Self.ttl, now >= fetchedAt { return false }
            refreshing = true
            return true
        }
        guard proceed else { return }
        defer { lock.withLock { refreshing = false } }
        guard let data = try? await fetch(),
              let models = try? Self.parse(modelsDevJSON: data),
              !models.isEmpty else { return }
        install(models, fetchedAt: now)
        guard let encoded = try? JSONEncoder().encode(CacheFile(fetchedAt: now, models: models)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoded.write(to: cacheURL, options: .atomic)
    }

    private func install(_ models: [CatalogModel], fetchedAt: Date) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let version = "models.dev-" + formatter.string(from: fetchedAt)
        let versioned = models.map { model in
            var pricing = model.pricing
            pricing?.priceVersion = version
            return CatalogModel(id: model.id, providerId: model.providerId, name: model.name,
                                contextTokens: model.contextTokens, outputTokens: model.outputTokens,
                                reasoning: model.reasoning, reasoningEfforts: model.reasoningEfforts,
                                pricing: pricing, temperature: model.temperature)
        }
        let built = Self.buildIndex(versioned)
        lock.withLock {
            index = built
            memo = [:]
            self.fetchedAt = fetchedAt
            self.pricingNeedsRefresh = models.contains { $0.pricing?.cachedDimensionsUnknown == true }
        }
    }

    // MARK: - 纯逻辑

    /// 容错解析：单个坏条目跳过，不拖垮整份目录。顶层不是 provider 字典才抛。
    static func parse(modelsDevJSON data: Data) throws -> [CatalogModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        func int(_ v: Any?) -> Int? { (v as? NSNumber).map { $0.intValue } }
        func double(_ v: Any?) -> Double? { (v as? NSNumber).map { $0.doubleValue } }
        var out: [CatalogModel] = []
        for (providerKey, rawProvider) in root {
            guard let provider = rawProvider as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            let providerId = (provider["id"] as? String) ?? providerKey
            for (modelKey, rawModel) in models {
                guard let m = rawModel as? [String: Any] else { continue }
                let id = (m["id"] as? String) ?? modelKey
                let limit = m["limit"] as? [String: Any]
                let efforts = ((m["reasoning_options"] as? [[String: Any]]) ?? [])
                    .filter { ($0["type"] as? String) == "effort" }
                    .flatMap { ($0["values"] as? [String]) ?? [] }
                var pricing: ModelPricing?
                if let cost = m["cost"] as? [String: Any], let input = double(cost["input"]), let output = double(cost["output"]) {
                    func tierPrice(_ c: [String: Any]) -> ModelPricing {
                        var p = ModelPricing(double(c["input"]) ?? 0, double(c["output"]) ?? 0,
                                             cacheRead: double(c["cache_read"]), cacheWrite: double(c["cache_write"]),
                                             cacheWrite1h: double(c["cache_write_1h"]),
                                             webSearch: providerId == "anthropic" ? 0.01 : nil, priceVersion: nil)
                        p.missingInputPrice = double(c["input"]) == nil
                        p.missingOutputPrice = double(c["output"]) == nil
                        return p
                    }
                    var tiers: [ModelPricing.Tier] = []
                    for c in cost["tiers"] as? [[String: Any]] ?? [] {
                        guard let tier = c["tier"] as? [String: Any], tier["type"] as? String == "context",
                              let size = int(tier["size"]), size > 0 else { continue }
                        tiers.append(.init(aboveInputTokens: size, pricing: tierPrice(c)))
                    }
                    if tiers.isEmpty, let legacy = cost["context_over_200k"] as? [String: Any] {
                        tiers.append(.init(aboveInputTokens: 200_000, pricing: tierPrice(legacy)))
                    }
                    pricing = ModelPricing(input, output, cacheRead: double(cost["cache_read"]),
                                           cacheWrite: double(cost["cache_write"]), cacheWrite1h: double(cost["cache_write_1h"]),
                                           webSearch: providerId == "anthropic" ? 0.01 : nil,
                                           tiers: tiers.isEmpty ? nil : tiers, priceVersion: nil,
                                           additionalPriceUnknown: providerId == "deepseek")
                }
                out.append(CatalogModel(
                    id: id, providerId: providerId, name: (m["name"] as? String) ?? id,
                    contextTokens: int(limit?["context"]), outputTokens: int(limit?["output"]),
                    reasoning: (m["reasoning"] as? Bool) ?? false, reasoningEfforts: efforts, pricing: pricing,
                    temperature: m["temperature"] as? Bool
                ))
            }
        }
        return out
    }

    /// 同一个 id 多家都有时，一方厂商优先（中转/聚合商常加价或改名）
    static let preferredProviders = ["anthropic", "openai", "google", "deepseek", "xai", "mistral",
                                     "moonshotai", "zai", "alibaba", "minimax", "groq", "cohere", "llama"]

    static func canonical(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ".", with: "-")
    }

    static func buildIndex(_ models: [CatalogModel]) -> [String: CatalogModel] {
        func rank(_ p: String) -> Int { preferredProviders.firstIndex(of: p) ?? preferredProviders.count }
        // 非一方的同名条目：有价 > 标 0 价（中转的免费档）> 没标价
        func priced(_ m: CatalogModel) -> Int {
            guard let p = m.pricing else { return 2 }
            return p.inputUSDPerMTok > 0 || p.outputUSDPerMTok > 0 ? 0 : 1
        }
        let sorted = models.sorted {
            (rank($0.providerId), priced($0), $0.providerId, $0.id) < (rank($1.providerId), priced($1), $1.providerId, $1.id)
        }
        var index: [String: CatalogModel] = [:]
        for m in sorted { index[canonical(m.id)] = index[canonical(m.id)] ?? m }
        // 只有聚合商收录的模型（"vendor/model"）按末段也能找到；一方条目已占位的不覆盖
        for m in sorted where m.id.contains("/") {
            let bare = canonical(String(m.id.split(separator: "/").last ?? ""))
            if !bare.isEmpty, index[bare] == nil { index[bare] = m }
        }
        return index
    }

    /// 查找顺序：完整 id → 去 vendor 前缀 → 去日期后缀 → 最长前缀（边界必须是分隔符，且余下不以数字开头——
    /// 那是另一个版本，宁可说不知道也不拿旧版本价冒充）。
    static func lookup(_ modelId: String, in index: [String: CatalogModel]) -> CatalogModel? {
        let full = canonical(modelId)
        guard !full.isEmpty else { return nil }
        let bare = full.split(separator: "/").last.map(String.init) ?? full
        let undated = bare.replacingOccurrences(of: #"-(\d{8}|\d{4}-\d{2}-\d{2})$"#, with: "", options: .regularExpression)
        // 精确命中但没标价（聚合商条目常这样）→ 让后面有价的同名一方条目顶上
        let exact = [full, bare, undated].compactMap { index[$0] }
        if let m = exact.first(where: { $0.pricing != nil }) ?? exact.first { return m }
        var best: (key: String, model: CatalogModel)?
        for (key, m) in index where !key.contains("/") && key.count < undated.count && undated.hasPrefix(key) {
            let rest = undated.dropFirst(key.count)
            guard let sep = rest.first, sep == "-" || sep == ":" || sep == "@" else { continue }
            if let next = rest.dropFirst().first, next.isNumber { continue }
            if best == nil || key.count > best!.key.count { best = (key, m) }
        }
        return best?.model
    }
}

extension CatalogModel {
    /// 模型池一行的小字：「200K 上下文 · 推理 low/medium/high · $3 / $15」，缺的段落省掉
    var caption: String? {
        var parts: [String] = []
        if let contextTokens, contextTokens > 0 {
            parts.append(contextTokens >= 1_000_000 && contextTokens % 1_000_000 == 0
                ? "\(contextTokens / 1_000_000)M 上下文" : "\(contextTokens / 1000)K 上下文")
        }
        if !reasoningEfforts.isEmpty {
            parts.append("推理 " + reasoningEfforts.joined(separator: "/"))
        } else if reasoning {
            parts.append("推理")
        }
        if let pricing {
            parts.append("$\(Self.price(pricing.inputUSDPerMTok)) / $\(Self.price(pricing.outputUSDPerMTok))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func price(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}
