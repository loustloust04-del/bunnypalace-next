import XCTest
@testable import 记忆花园

/// research-magpie 2.5：models.dev 目录（解析 / 查找 / 缓存 TTL / 失败保旧）+ `price(for:)` 查不到返回 nil。
final class ModelCatalogTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCatalogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// 缩微版 models.dev：一方厂商 + 一个聚合商（同名模型要让一方赢）
    private static let sample = Data(#"""
    {
      "openrouter": {"id": "openrouter", "name": "OpenRouter", "models": {
        "anthropic/claude-sonnet-4.5": {"id": "anthropic/claude-sonnet-4.5", "name": "Anthropic: Claude Sonnet 4.5",
          "limit": {"context": 1000000, "output": 64000}, "cost": {"input": 3.3, "output": 16.5}},
        "vendorx/solo-model": {"id": "vendorx/solo-model", "name": "Solo", "cost": {"input": 1, "output": 2}}
      }},
      "anthropic": {"id": "anthropic", "name": "Anthropic", "models": {
        "claude-sonnet-4-5": {"id": "claude-sonnet-4-5", "name": "Claude Sonnet 4.5", "reasoning": true,
          "reasoning_options": [{"type": "budget_tokens", "min": 1024}],
          "limit": {"context": 1000000, "output": 64000},
          "cost": {"input": 3, "output": 15, "cache_read": 0.3, "cache_write": 3.75}},
        "claude-opus-4-5": {"id": "claude-opus-4-5", "name": "Claude Opus 4.5", "reasoning": true,
          "reasoning_options": [{"type": "effort", "values": ["low", "medium", "high"]}],
          "limit": {"context": 200000, "output": 64000}, "cost": {"input": 5, "output": 25}}
      }},
      "openai": {"id": "openai", "name": "OpenAI", "models": {
        "gpt-4.1": {"id": "gpt-4.1", "name": "GPT-4.1", "limit": {"context": 1047576, "output": 32768},
          "cost": {"input": 2, "output": 8, "cache_read": 0.5}},
        "gpt-4.1-mini": {"id": "gpt-4.1-mini", "name": "GPT-4.1 mini", "cost": {"input": 0.4, "output": 1.6}},
        "no-price": {"id": "no-price", "name": "No Price"}
      }},
      "broken": {"id": "broken", "models": {"weird": {"name": 42, "limit": {"context": "big"}}}}
    }
    """#.utf8)

    private func catalog(_ fetch: @escaping @Sendable () async throws -> Data = { throw URLError(.notConnectedToInternet) }) -> ModelCatalog {
        ModelCatalog(cacheURL: tempDir.appendingPathComponent("model-catalog.json"), fetch: fetch)
    }

    // MARK: 解析

    func testParseKeepsNameContextEffortsAndPricing() throws {
        let models = try ModelCatalog.parse(modelsDevJSON: Self.sample)
        let sonnet = try XCTUnwrap(models.first { $0.providerId == "anthropic" && $0.id == "claude-sonnet-4-5" })
        XCTAssertEqual(sonnet.name, "Claude Sonnet 4.5")
        XCTAssertEqual(sonnet.contextTokens, 1_000_000)
        XCTAssertEqual(sonnet.outputTokens, 64_000)
        XCTAssertTrue(sonnet.reasoning)
        XCTAssertEqual(sonnet.reasoningEfforts, [])
        XCTAssertEqual(sonnet.pricing, ModelPricing(3, 15, cacheRead: 0.3, cacheWrite: 3.75, webSearch: 0.01, priceVersion: nil))

        let opus = try XCTUnwrap(models.first { $0.id == "claude-opus-4-5" })
        XCTAssertEqual(opus.reasoningEfforts, ["low", "medium", "high"])

        XCTAssertNil(models.first { $0.id == "no-price" }?.pricing, "没标价就是不知道")
        XCTAssertNotNil(models.first { $0.id == "no-price" }, "没价的模型仍进目录（显示名/上下文有用）")
    }

    func testParseRejectsGarbage() {
        XCTAssertThrowsError(try ModelCatalog.parse(modelsDevJSON: Data("[1,2]".utf8)))
    }

    // MARK: 查找

    func testLookupPrefersFirstPartyAndNormalizes() throws {
        let index = ModelCatalog.buildIndex(try ModelCatalog.parse(modelsDevJSON: Self.sample))
        func look(_ id: String) -> CatalogModel? { ModelCatalog.lookup(id, in: index) }

        XCTAssertEqual(look("claude-sonnet-4-5")?.providerId, "anthropic")
        XCTAssertEqual(look("Claude-Sonnet-4-5")?.providerId, "anthropic", "大小写不敏感")
        XCTAssertEqual(look("claude-sonnet-4.5")?.providerId, "anthropic", "点/横线等价")
        XCTAssertEqual(look("custom/claude-sonnet-4-5")?.providerId, "anthropic", "中转站 vendor 前缀")
        XCTAssertEqual(look("anthropic/claude-sonnet-4.5")?.providerId, "openrouter", "完整 id 精确命中聚合商条目")
        XCTAssertEqual(look("claude-sonnet-4-5-20250929")?.id, "claude-sonnet-4-5", "去日期后缀")
        XCTAssertEqual(look("claude-sonnet-4-5-thinking")?.id, "claude-sonnet-4-5", "变体后缀按最长前缀")
        XCTAssertEqual(look("gpt-4.1-mini")?.id, "gpt-4.1-mini", "最长前缀赢，不落到 gpt-4.1")
        XCTAssertEqual(look("solo-model")?.id, "vendorx/solo-model", "只有聚合商有的模型按末段也能找到")
    }

    func testLookupRefusesVersionGuesses() throws {
        let index = ModelCatalog.buildIndex(try ModelCatalog.parse(modelsDevJSON: Self.sample))
        XCTAssertNil(ModelCatalog.lookup("claude-opus-4-5-1", in: index), "余下是数字 = 另一个版本，不猜")
        XCTAssertNil(ModelCatalog.lookup("gpt-4.10", in: index), "边界不是分隔符不算前缀")
        XCTAssertNil(ModelCatalog.lookup("totally-unknown", in: index))
        XCTAssertNil(ModelCatalog.lookup("", in: index))
    }

    // MARK: 缓存与刷新

    func testRefreshWritesCacheAndReloads() async throws {
        let c = catalog { Self.sample }
        XCTAssertNil(c.model(for: "claude-opus-4-5"))
        await c.refreshIfStale(now: Date())
        XCTAssertEqual(c.model(for: "claude-opus-4-5")?.name, "Claude Opus 4.5")

        let reopened = catalog()
        XCTAssertTrue(reopened.loadCache())
        XCTAssertEqual(reopened.model(for: "claude-opus-4-5")?.contextTokens, 200_000, "离线也能从缓存读")
    }

    func testFreshCacheIsNotRefetched() async throws {
        let counter = Counter()
        let c = catalog { counter.bump(); return Self.sample }
        let t0 = Date()
        await c.refreshIfStale(now: t0)
        await c.refreshIfStale(now: t0.addingTimeInterval(3600))
        XCTAssertEqual(counter.value, 1, "TTL 1 天内不重复拉")
        await c.refreshIfStale(now: t0.addingTimeInterval(ModelCatalog.ttl + 1))
        XCTAssertEqual(counter.value, 2, "过期后再拉")
    }

    func testFailedRefreshKeepsOldCache() async throws {
        let first = catalog { Self.sample }
        await first.refreshIfStale(now: Date(timeIntervalSince1970: 0))

        let failing = catalog { throw URLError(.timedOut) }
        XCTAssertTrue(failing.loadCache())
        await failing.refreshIfStale(now: Date())
        XCTAssertEqual(failing.model(for: "gpt-4.1")?.pricing?.inputUSDPerMTok, 2, "失败用旧缓存")

        let garbage = catalog { Data("{}".utf8) }
        XCTAssertTrue(garbage.loadCache())
        await garbage.refreshIfStale(now: Date())
        XCTAssertNotNil(garbage.model(for: "gpt-4.1"), "空载荷不覆盖旧缓存")
    }

    // MARK: PricingCatalog

    func testPriceUsesCatalogThenBuiltinThenNil() async throws {
        let c = catalog { Self.sample }
        XCTAssertEqual(PricingCatalog.price(for: "claude-opus-4-5", catalog: c)?.inputUSDPerMTok, 5,
                       "目录空（首次无网）→ 手写表兜底")
        XCTAssertNil(PricingCatalog.price(for: "totally-unknown-model", catalog: c), "查不到就是不知道，不再给 fallback 价")

        await c.refreshIfStale(now: Date())
        XCTAssertEqual(PricingCatalog.price(for: "claude-opus-4-5", catalog: c)?.inputUSDPerMTok, 5, "目录优先")
        XCTAssertEqual(PricingCatalog.price(for: "claude-sonnet-4", catalog: c)?.inputUSDPerMTok, 3, "目录没有 → 手写表")
        XCTAssertNil(PricingCatalog.price(for: "totally-unknown-model", catalog: c))
    }

    func testCostUsesCachePricesOrDefaults() {
        let explicit = ModelPricing(3, 15, cacheRead: 0.3, cacheWrite: 3.75)
        // 1M 总 prompt，其中 20 万读缓存、10 万写缓存 → 70 万新鲜
        XCTAssertEqual(explicit.cost(promptTokens: 1_000_000, completionTokens: 100_000,
                                     cacheReadTokens: 200_000, cacheWriteTokens: 100_000),
                       0.7 * 3 + 0.2 * 0.3 + 0.1 * 3.75 + 0.1 * 15, accuracy: 1e-9)
        let implicit = ModelPricing(2, 8)
        XCTAssertEqual(implicit.cost(promptTokens: 1_000_000, completionTokens: 0,
                                     cacheReadTokens: 1_000_000, cacheWriteTokens: 0),
                       0.2, accuracy: 1e-9, "没标缓存价按 0.1× 输入价")
    }

    func testBudgetEstimateStaysConservativeForUnknownModels() {
        let provider = APICredential(id: "cred-t", name: "t", emoji: "🧪", type: .openaiCompatible, baseURL: "https://x")
        let cost = BudgetCalculator.actualCost(provider: provider, modelId: "totally-unknown-model",
                                               usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0))
        XCTAssertEqual(cost, PricingCatalog.budgetFallback.inputUSDPerMTok, accuracy: 1e-9,
                       "保险闸对未知模型仍按保守价估，别因为「不知道」就放行")
        XCTAssertNil(BudgetCalculator.displayCost(provider: provider, modelId: "totally-unknown-model",
                                                  promptTokens: 10, completionTokens: 10,
                                                  cacheReadTokens: 0, cacheWriteTokens: 0),
                     "显示费用不知道就是 nil")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

extension ModelCatalogTests {
    func testCaption() throws {
        let models = try ModelCatalog.parse(modelsDevJSON: Self.sampleForCaption)
        XCTAssertEqual(models.first { $0.id == "a" }?.caption, "200K 上下文 · 推理 low/high · $5 / $25")
        XCTAssertEqual(models.first { $0.id == "b" }?.caption, "1M 上下文 · 推理 · $0.4 / $1.6")
        XCTAssertNil(models.first { $0.id == "c" }?.caption)
    }

    private static let sampleForCaption = Data(#"""
    {"p": {"id": "p", "models": {
      "a": {"id": "a", "reasoning": true, "reasoning_options": [{"type": "effort", "values": ["low", "high"]}],
            "limit": {"context": 200000}, "cost": {"input": 5, "output": 25}},
      "b": {"id": "b", "reasoning": true, "limit": {"context": 1000000}, "cost": {"input": 0.4, "output": 1.6}},
      "c": {"id": "c"}
    }}}
    """#.utf8)
}

extension ModelCatalogTests {
    /// 实测 models.dev：聚合商的 "anthropic/claude-opus-4.6" 条目没标价，一方 anthropic 有价 → 取有价的；
    /// 中转的 0 价免费档不能盖过别家的真实价
    func testPricedEntriesWinOverUnpricedOrFree() throws {
        let json = Data(#"""
        {"anyapi": {"id": "anyapi", "models": {"anthropic/claude-opus-4.6": {"id": "anthropic/claude-opus-4.6", "name": "x"}}},
         "anthropic": {"id": "anthropic", "models": {"claude-opus-4-6": {"id": "claude-opus-4-6", "name": "Opus", "cost": {"input": 5, "output": 25}}}},
         "aaa-free": {"id": "aaa-free", "models": {"kimi-k2": {"id": "kimi-k2", "cost": {"input": 0, "output": 0}}}},
         "zzz-paid": {"id": "zzz-paid", "models": {"kimi-k2": {"id": "kimi-k2", "cost": {"input": 0.57, "output": 2.3}}}}}
        """#.utf8)
        let index = ModelCatalog.buildIndex(try ModelCatalog.parse(modelsDevJSON: json))
        XCTAssertEqual(ModelCatalog.lookup("anthropic/claude-opus-4.6", in: index)?.providerId, "anthropic")
        XCTAssertEqual(ModelCatalog.lookup("kimi-k2", in: index)?.providerId, "zzz-paid")
    }
}

extension ModelCatalogTests {
    /// deepseek-chat 已从一方目录下架，只剩中转条目（价不同）→ 手写表的官方价优先；手写表也没有才用中转价
    func testBuiltinOfficialPriceBeatsRelayOnlyEntries() async {
        let json = Data(#"""
        {"nano-gpt": {"id": "nano-gpt", "models": {
          "deepseek-chat": {"id": "deepseek-chat", "cost": {"input": 0.1, "output": 0.425}},
          "relay-only": {"id": "relay-only", "cost": {"input": 7, "output": 9}}}}}
        """#.utf8)
        let c = catalog { json }
        await c.refreshIfStale(now: Date())
        XCTAssertEqual(PricingCatalog.price(for: "deepseek-chat", catalog: c)?.inputUSDPerMTok, 0.27)
        XCTAssertEqual(PricingCatalog.price(for: "relay-only", catalog: c)?.inputUSDPerMTok, 7)
    }
}

extension ModelCatalogTests {
    func testLiveCostFixtureParsesExactContextThresholds() throws {
        let models = try ModelCatalog.parse(modelsDevJSON: ModelsDevCostFixture.data)
        let google = try XCTUnwrap(models.first { $0.id == "gemini-2.5-pro" }?.pricing)
        XCTAssertEqual(google.outputUSDPerMTok, 10)
        XCTAssertEqual(google.tiers?.map(\.aboveInputTokens), [200_000])
        XCTAssertEqual(google.tiers?.first?.pricing.inputUSDPerMTok, 2.5)
        let qwen = try XCTUnwrap(models.first { $0.id == "Qwen/Qwen3-Max" }?.pricing)
        XCTAssertEqual(qwen.tiers?.map(\.aboveInputTokens), [32_000, 128_000])
        let sol = try XCTUnwrap(models.first { $0.id == "gpt-6.1-sol" }?.pricing)
        XCTAssertEqual(sol.tiers?.map(\.aboveInputTokens), [272_000], "不把兼容 context_over_200k 错当实际门槛")
        let old = Data(#"{"p":{"models":{"m":{"cost":{"input":1,"output":2,"context_over_200k":{"input":3,"output":4}}}}}}"#.utf8)
        XCTAssertEqual(try ModelCatalog.parse(modelsDevJSON: old).first?.pricing?.tiers?.first?.aboveInputTokens, 200_000)
    }
}
