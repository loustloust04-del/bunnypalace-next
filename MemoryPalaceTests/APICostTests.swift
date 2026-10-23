import XCTest
@testable import 记忆花园

final class APICostTests: XCTestCase {
    func testReportedCostPresenceAndTrustedHost() throws {
        for value: Double? in [0.125, 0, nil] {
            var u: [String: Any] = ["prompt_tokens": 10, "completion_tokens": 2,
                                    "prompt_tokens_details": ["cache_write_tokens": 4]]
            if let value { u["cost"] = value }
            let obj: [String: Any] = ["id": "gen-test", "usage": u]
            let parsed = try XCTUnwrap(APIUsageParser.openAI(obj, baseURL: "https://openrouter.ai/api/v1", cacheWriteIs1h: true))
            XCTAssertEqual(parsed.reportedCostUSD, value)
            XCTAssertEqual(parsed.cacheWriteTokens, 4)
            XCTAssertEqual(parsed.cacheWrite1hTokens, 4)
            XCTAssertEqual(parsed.responseId, "gen-test")
            XCTAssertNil(APIUsageParser.openAI(obj, baseURL: "https://openrouter.ai.example/v1")?.reportedCostUSD)
            let stream = OpenAICompatibleProvider()
            stream.usageBaseURL = "https://openrouter.ai/api/v1"
            stream.usageCacheWriteIs1h = true
            let data = try JSONSerialization.data(withJSONObject: obj)
            stream.processData(Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8))
            XCTAssertEqual(stream.finalUsage?.reportedCostUSD, value)
            XCTAssertEqual(stream.finalUsage?.cacheWriteTokens, 4)
        }
        XCTAssertEqual(APIUsageParser.openAI(["id": "gen-only"], baseURL: "https://openrouter.ai/api/v1")?.responseId, "gen-only")
    }

    private func recoveryRecord() -> UsageRecord {
        var row = UsageRecord(time: Date(timeIntervalSince1970: 10), providerId: "fixture", providerName: "fixture",
                              providerType: "openaiCompatible", model: "fixture", input: 10, output: 2,
                              cacheRead: 0, cacheWrite: 0, reasoning: 0, durationMs: 1, status: .error,
                              kind: .chat, conversationId: nil, profileId: nil, subscription: false, tokensOnly: false)
        row.responseId = "gen-fixture"
        row.costUSD = 0.1
        row.costSource = .calculated
        return row
    }

    func testRecoverySuccessAppendsCorrectionIncludingZero() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = UsageLedger(fileURL: url)
        let row = recoveryRecord()
        ledger.append(row)
        let client = OpenRouterCostRecovery(fetch: { request in
            XCTAssertEqual(request.url?.host, "openrouter.ai")
            return Data(#"{"data":{"total_cost":0}}"#.utf8)
        }, sleep: { _ in })
        let correction = await client.recover(row, apiKey: "fixture-not-a-key", ledger: ledger)
        XCTAssertEqual(correction?.costUSD, 0)
        XCTAssertEqual(correction?.costSource, .reported)
        XCTAssertEqual(correction?.time, row.time)
        XCTAssertEqual(ledger.load().count, 1)
        XCTAssertEqual(ledger.load().first?.correction, true)
    }

    func testRecoveryFailureKeepsOriginalAndRetriesThreeTimes() async {
        actor Attempts {
            var delays: [UInt64] = []
            func add(_ delay: UInt64) { delays.append(delay) }
        }
        let attempts = Attempts()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = UsageLedger(fileURL: url)
        let row = recoveryRecord()
        ledger.append(row)
        let client = OpenRouterCostRecovery(fetch: { _ in throw URLError(.notConnectedToInternet) },
                                            sleep: { await attempts.add($0) })
        let correction = await client.recover(row, apiKey: "fixture-not-a-key", ledger: ledger)
        let delays = await attempts.delays
        XCTAssertNil(correction)
        XCTAssertEqual(delays, [10, 20, 90].map { UInt64($0) * 1_000_000_000 })
        XCTAssertEqual(ledger.load(), [row])
    }
}

extension APICostTests {
    func testAnthropicBucketsAndSearches() throws {
        let usage: [String: Any] = ["input_tokens": 100, "output_tokens": 20,
                                    "cache_creation": ["ephemeral_5m_input_tokens": 30, "ephemeral_1h_input_tokens": 40],
                                    "server_tool_use": ["web_search_requests": 2]]
        let parsed = try XCTUnwrap(APIUsageParser.anthropic(usage))
        XCTAssertEqual(parsed.cacheWriteTokens, 70)
        XCTAssertEqual(parsed.cacheWrite1hTokens, 40)
        XCTAssertEqual(parsed.webSearches, 2)
        let provider = AnthropicProvider()
        let message = try JSONSerialization.data(withJSONObject: ["message": ["usage": usage]])
        provider.processData(Data("event: message_start\ndata: \(String(decoding: message, as: UTF8.self))\n\n".utf8))
        provider.processData(Data(#"""
        event: message_delta
        data: {"usage":{"output_tokens":25,"server_tool_use":{"web_search_requests":3}}}

        """#.utf8))
        XCTAssertEqual(provider.finalUsage?.cacheWrite1hTokens, 40)
        XCTAssertEqual(provider.finalUsage?.webSearches, 3)
    }
}

extension APICostTests {
    func testDeepSeekHitFieldWinsAndMissingFallsBack() {
        var u: [String: Any] = ["prompt_tokens": 100, "completion_tokens": 10,
                                "prompt_tokens_details": ["cached_tokens": 20], "prompt_cache_hit_tokens": 80]
        XCTAssertEqual(APIUsageParser.openAI(["usage": u], baseURL: "https://api.deepseek.com")?.cacheReadTokens, 80)
        u["prompt_cache_hit_tokens"] = 0
        XCTAssertEqual(APIUsageParser.openAI(["usage": u], baseURL: "https://api.deepseek.com")?.cacheReadTokens, 0)
        u.removeValue(forKey: "prompt_cache_hit_tokens")
        XCTAssertEqual(APIUsageParser.openAI(["usage": u], baseURL: "https://api.deepseek.com")?.cacheReadTokens, 20)
    }
}

extension APICostTests {
    func testGeminiExplicitNativeBucketsAndCompatibilityFallback() {
        let usage: [String: Any] = ["prompt_tokens": 100, "completion_tokens": 20,
                                    "completion_tokens_details": ["reasoning_tokens": 10]]
        let base = "https://generativelanguage.googleapis.com/v1beta/openai"
        XCTAssertEqual(APIUsageParser.openAI(["usage": usage], baseURL: base)?.outputTokens, 20)
        let obj: [String: Any] = ["usage": usage, "usageMetadata": ["candidatesTokenCount": 20, "thoughtsTokenCount": 10]]
        XCTAssertEqual(APIUsageParser.openAI(obj, baseURL: base)?.outputTokens, 30)
        XCTAssertEqual(APIUsageParser.openAI(obj, baseURL: "https://api.openai.com/v1")?.outputTokens, 20)
    }
}

extension APICostTests {
    func testContextThresholdAppliesToWholeRequestAndAllBuckets() {
        let tier = ModelPricing(4, 20, cacheRead: 0.4, cacheWrite: 5, cacheWrite1h: 8)
        let pricing = ModelPricing(2, 10, tiers: [.init(aboveInputTokens: 200_000, pricing: tier)])
        for prompt in [199_999, 200_000, 200_001] {
            let over = prompt > 200_000
            let result = pricing.evaluatedCost(promptTokens: prompt, completionTokens: 100,
                                               cacheReadTokens: 50, cacheWriteTokens: 30, cacheWrite1hTokens: 10)
            let expected = (Double(prompt - 80) * (over ? 4 : 2) + 50 * (over ? 0.4 : 0.2)
                            + 20 * (over ? 5 : 2.5) + 10 * (over ? 8 : 4) + 100 * (over ? 20 : 10)) / 1_000_000
            XCTAssertEqual(result.usd, expected, accuracy: 1e-12)
            XCTAssertFalse(result.partial)
        }
    }

    func testCacheBucketsFullHitNoHitAndSearchMissingPrice() {
        let price = ModelPricing(2, 10, webSearch: 0.01)
        XCTAssertEqual(price.cost(promptTokens: 1000, completionTokens: 0, cacheReadTokens: 1000, cacheWriteTokens: 0), 0.0002, accuracy: 1e-12)
        XCTAssertEqual(price.cost(promptTokens: 1000, completionTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0), 0.002, accuracy: 1e-12)
        XCTAssertEqual(price.cost(promptTokens: 1000, completionTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 1000), 0.0025, accuracy: 1e-12)
        let hour = price.evaluatedCost(promptTokens: 1000, completionTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 1000, cacheWrite1hTokens: 1000, webSearches: 2)
        XCTAssertEqual(hour.usd, 0.024, accuracy: 1e-12)
        XCTAssertFalse(hour.partial, "1h 缺价按 2×；读 / 5m 按已拍板倍率")
        let unknown = ModelPricing(2, 10).evaluatedCost(promptTokens: 1000, completionTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, webSearches: 1)
        XCTAssertEqual(unknown.usd, 0.002)
        XCTAssertTrue(unknown.partial)
        var missing = ModelPricing(4, 0)
        missing.missingOutputPrice = true
        let incomplete = ModelPricing(2, 10, tiers: [.init(aboveInputTokens: 100, pricing: missing)])
        XCTAssertTrue(incomplete.evaluatedCost(promptTokens: 101, completionTokens: 20, cacheReadTokens: 0, cacheWriteTokens: 0).partial)
    }

    func testOlderCachedPricingDecodesWithoutNewDimensions() throws {
        let data = Data(#"{"inputUSDPerMTok":2,"outputUSDPerMTok":10}"#.utf8)
        let p = try JSONDecoder().decode(ModelPricing.self, from: data)
        XCTAssertNil(p.tiers)
        XCTAssertNil(p.cacheWrite1hUSDPerMTok)
    }
}

extension APICostTests {
    func testOctoberBuiltinPricesAndVersion() {
        XCTAssertEqual(PricingCatalog.builtinPrice(for: "claude-opus-4-6")?.inputUSDPerMTok, 5)
        XCTAssertEqual(PricingCatalog.builtinPrice(for: "claude-haiku-4-5")?.inputUSDPerMTok, 1)
        XCTAssertEqual(PricingCatalog.builtinPrice(for: "claude-opus-5")?.outputUSDPerMTok, 25)
        XCTAssertEqual(PricingCatalog.builtinPrice(for: "gpt-6.1-sol")?.tiers?.first?.aboveInputTokens, 272_000)
        XCTAssertEqual(PricingCatalog.builtinPrice(for: "gpt-6.1-sol")?.priceVersion, "builtin-2026-10")
        XCTAssertEqual(PricingCatalog.builtinPrice(for: "gpt-4o-mini-2024-07-18")?.inputUSDPerMTok, 0.15)
    }
}

extension APICostTests {
    func testPricingCacheFormatStaysUnchangedAndMissingDimensionsArePartial() throws {
        let p = ModelPricing(2, 10, cacheRead: 0.2, cacheWrite: 2.5, cacheWrite1h: 4,
                             webSearch: 0.01, tiers: [.init(aboveInputTokens: 200_000, pricing: ModelPricing(4, 15))])
        let encoded = try JSONEncoder().encode(p)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["inputUSDPerMTok", "outputUSDPerMTok", "cacheReadUSDPerMTok", "cacheWriteUSDPerMTok"]))
        let cached = try JSONDecoder().decode(ModelPricing.self, from: encoded)
        XCTAssertTrue(cached.evaluatedCost(promptTokens: 300_000, completionTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0).partial)
    }
}

extension APICostTests {
    func testDeepSeekTimeSensitivePriceIsPartialUntilCovered() throws {
        let p = try XCTUnwrap(PricingCatalog.builtinPrice(for: "deepseek-v4-pro"))
        XCTAssertEqual(p.cacheReadUSDPerMTok, 0.022)
        XCTAssertTrue(p.evaluatedCost(promptTokens: 1000, completionTokens: 20, cacheReadTokens: 0, cacheWriteTokens: 0).partial)
    }
}

extension APICostTests {
    func testReportedZeroDoesNotRequireTokenFieldsOrResponseId() {
        let stream = OpenAICompatibleProvider()
        stream.usageBaseURL = "https://openrouter.ai/api/v1"
        stream.processData(Data("data: {\"usage\":{\"cost\":0}}\n\n".utf8))
        XCTAssertEqual(stream.finalUsage?.reportedCostUSD, 0)
    }
}
