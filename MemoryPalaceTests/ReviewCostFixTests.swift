import XCTest
@testable import 记忆花园

final class ReviewCostFixTests: XCTestCase {
    func testF1AnthropicFinalCumulativeUsageFreezes0283() throws {
        let provider = AnthropicProvider()
        provider.processData(Data("event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":1000,\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}\n\n".utf8))
        provider.processData(Data("event: message_delta\ndata: {\"usage\":{\"input_tokens\":3000,\"cache_read_input_tokens\":1000,\"cache_creation_input_tokens\":2000,\"output_tokens\":100,\"server_tool_use\":{\"web_search_requests\":1}}}\n\n".utf8))
        let usage = try XCTUnwrap(provider.finalUsage)
        let card = APICredential(id: "fixture", name: "fixture", emoji: "", type: .anthropic, baseURL: "https://api.anthropic.com")
        let row = UsageRecord(provider: card, modelId: "claude-sonnet-4-6", usage: usage,
                              started: Date(), ended: Date(), status: .ok, context: UsageContext())
        XCTAssertEqual(row.input, 6000)
        XCTAssertEqual(row.cacheWrite, 2000)
        XCTAssertEqual(try XCTUnwrap(row.costUSD), 0.0283, accuracy: 1e-12)
        provider.processData(Data("event: message_delta\ndata: {\"usage\":{\"output_tokens\":101}}\n\n".utf8))
        XCTAssertEqual(provider.finalUsage?.inputTokens, 3000, "缺字段保留累计快照")
        XCTAssertEqual(provider.finalUsage?.cacheReadTokens, 1000)
        XCTAssertEqual(provider.finalUsage?.cacheWriteTokens, 2000)
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testF2RepeatedTerminationReturnsFirstChargedReceipt() {
        let settlement = RequestUsageSettlement()
        var builds = 0
        let raw = TokenUsage(inputTokens: 100, outputTokens: 20)
        let first = settlement.settle(raw) { usage in
            builds += 1
            var receipt = usage!
            receipt.ledgerCostUSD = 0.1
            receipt.ledgerCostRecorded = true
            receipt.ledgerSpendRecorded = true
            return receipt
        }
        let repeated = settlement.settle(raw) { _ in builds += 1; return raw }
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(repeated, first)
        XCTAssertTrue(repeated.ledgerSpendRecorded)
    }

    @MainActor
    func testF2CancelDropsQueuedDoneAndLateToken() async {
        let provider = OpenAICompatibleProvider()
        var completions = 0
        var tokens = 0
        provider.resetState(onToken: { _ in tokens += 1 }, onComplete: { _, _ in completions += 1 }, onError: { _ in })
        provider.processData(Data("data: {\"choices\":[{\"delta\":{\"content\":\"late\"}}]}\n\ndata: [DONE]\n\n".utf8))
        provider.cancel()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(tokens, 0)
        XCTAssertEqual(provider.streamingContent, "")
    }
}

extension ReviewCostFixTests {
    func testF3UnknownLedgerCostStillChargesConservativeBudget() {
        let card = APICredential(id: "fixture", name: "fixture", emoji: "", type: .openaiCompatible, baseURL: "https://fixture.invalid")
        var missing = UsageRecord(provider: card, modelId: "unknown", usage: nil,
                                  started: Date(), ended: Date(), status: .ok, context: UsageContext())
        missing.budgetChargeUSD = missing.budgetCost(estimatedCost: 0.5, price: { _ in nil })
        XCTAssertNil(missing.costUSD)
        XCTAssertEqual(missing.costSource, .partial)
        XCTAssertEqual(missing.budgetChargeUSD, 0.5)
        XCTAssertEqual(GlobalBudgetStore.ledgerSpentUSD(records: [missing], since: nil), 0.5)
        let counted = UsageRecord(provider: card, modelId: "unknown", usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0),
                                  started: Date(), ended: Date(), status: .ok, context: UsageContext())
        XCTAssertEqual(counted.budgetCost(estimatedCost: 0.5, price: { _ in nil }), PricingCatalog.budgetFallback.inputUSDPerMTok)
        var correction = missing
        correction.costUSD = 0.3
        correction.costSource = .reported
        XCTAssertEqual(GlobalBudgetStore.costCorrectionDelta(original: missing, corrected: correction), -0.2, accuracy: 1e-12)
    }
}

extension ReviewCostFixTests {
    func testF4ToolRoundsAndFinalShareDeduplicatedNodeTotal() {
        var amounts = NodeUsageAmounts()
        func row(_ provider: String, _ rid: String?, _ local: String, _ cost: Double) -> UsageRecord {
            var row = UsageRecord(time: Date(), providerId: provider, providerName: provider, providerType: "openaiCompatible", model: "fixture",
                                  input: 10, output: 2, cacheRead: 0, cacheWrite: 0, reasoning: 0, durationMs: 1,
                                  status: .ok, kind: .chat, conversationId: nil, profileId: nil, subscription: false, tokensOnly: false)
            row.responseId = rid
            row.requestId = local
            row.costUSD = cost
            return row
        }
        let first = row("p", "gen-1", "req-1", 0.1)
        let second = row("p", "gen-2", "req-2", 0.2)
        let final = row("p", nil, "req-3", 0.03)
        amounts.add(first); amounts.add(second); amounts.add(final); amounts.add(final)
        XCTAssertEqual(amounts.costUSD!, 0.33, accuracy: 1e-12)
        var correction = first
        correction.costUSD = 0.15
        correction.correction = true
        amounts.add(correction); amounts.add(correction)
        XCTAssertEqual(amounts.costUSD!, 0.38, accuracy: 1e-12)
        XCTAssertEqual(amounts.input, 30)
        amounts.add(row("other-provider", "gen-1", "req-4", 0.1))
        XCTAssertEqual(amounts.costUSD!, 0.48, accuracy: 1e-12)
    }
}

extension ReviewCostFixTests {
    func testF5ZeroTokenCorrectionDoesNotDoubleLegacyCost() throws {
        let card = APICredential(id: "fixture", name: "fixture", emoji: "", type: .openaiCompatible, baseURL: "https://openrouter.ai/api/v1")
        var original = UsageRecord(provider: card, modelId: "gpt-4o", usage: TokenUsage(inputTokens: 1000, outputTokens: 100, cacheReadTokens: 100),
                                   started: Date(timeIntervalSince1970: 10), ended: Date(timeIntervalSince1970: 11), status: .ok, context: UsageContext(kind: .chat))
        original.responseId = "gen-old-reader"
        original.cacheWrite = 20; original.cacheWrite1h = 10; original.reasoning = 2; original.webSearches = 1
        let correction = original.costCorrection(usd: 0.05)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        var raw = try encoder.encode(original); raw.append(10); raw.append(try encoder.encode(correction)); raw.append(10)
        let logical = try XCTUnwrap(UsageLedger.decode(lines: raw).first)
        XCTAssertEqual(UsageLedger.decode(lines: raw).count, 1)
        XCTAssertEqual(logical.input, original.input)
        XCTAssertEqual(logical.output, original.output)
        XCTAssertEqual(logical.cacheWrite1h, 10)
        XCTAssertEqual(logical.costUSD, 0.05)
        struct LegacyRow: Decodable {
            let input: Int; let output: Int; let cacheRead: Int?; let cacheWrite: Int?
            enum CodingKeys: String, CodingKey { case input = "in", output = "out", cacheRead = "cr", cacheWrite = "cw" }
        }
        let legacy = try raw.split(separator: 10).map { try JSONDecoder().decode(LegacyRow.self, from: Data($0)) }
        let before = ModelPricing(2.5, 10).cost(promptTokens: legacy[0].input, completionTokens: legacy[0].output, cacheReadTokens: legacy[0].cacheRead ?? 0, cacheWriteTokens: legacy[0].cacheWrite ?? 0)
        let after = legacy.reduce(0) { $0 + ModelPricing(2.5, 10).cost(promptTokens: $1.input, completionTokens: $1.output, cacheReadTokens: $1.cacheRead ?? 0, cacheWriteTokens: $1.cacheWrite ?? 0) }
        XCTAssertEqual(before, after)
        XCTAssertEqual(correction.cacheRead + correction.cacheWrite + correction.reasoning + correction.webSearches, 0)
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testF6FinalGateRunsOutsideRefinementWindowUsingWireOutput() async {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpBody = try! JSONSerialization.data(withJSONObject: ["model": "claude-haiku-4-5", "max_tokens": 1024,
            "messages": [["role": "user", "content": String(repeating: "字", count: 1000)]]])
        let result = await BudgetPreflight.decision(request, counter: OfficialTokenCounter(fetch: { _ in
            XCTFail("超过临界窗口不应调计数接口"); return Data()
        }), state: { .init(enabled: true, isBudgetSet: true, budgetUSD: 0.0035, spentUSD: 0) })
        XCTAssertEqual(result.estimatedCost, 0.00612, accuracy: 1e-12)
        XCTAssertFalse(result.allowed)
    }

    @MainActor
    func testF6BalanceConsumedDuringCountMustBlockSend() async {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpBody = try! JSONSerialization.data(withJSONObject: ["model": "claude-haiku-4-5", "max_tokens": 1024,
            "messages": [["role": "user", "content": String(repeating: "字", count: 1000)]]])
        var reads = 0
        let result = await BudgetPreflight.decision(request, counter: OfficialTokenCounter(fetch: { _ in Data(#"{"input_tokens":1000}"#.utf8) }), state: {
            reads += 1
            return .init(enabled: true, isBudgetSet: true, budgetUSD: 0.0062, spentUSD: reads == 1 ? 0 : 0.0062)
        })
        XCTAssertFalse(result.allowed)
        XCTAssertGreaterThanOrEqual(reads, 2)
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testF7OldSessionCannotFinishPendingCountRequest() async throws {
        @MainActor final class StartProbe {
            var starts = 0
            var onStart: (() -> Void)?
        }
        final class NoNetworkProvider: BaseChatProvider {
            let probe: StartProbe
            init(probe: StartProbe) { self.probe = probe; super.init() }
            override func startBudgetCheckedRequest(_ request: URLRequest) {
                MainActor.assumeIsolated { probe.starts += 1; probe.onStart?() }
            }
        }
        actor CountGate {
            let entered: XCTestExpectation
            var continuation: CheckedContinuation<Data, Never>?
            init(_ entered: XCTestExpectation) { self.entered = entered }
            func fetch() async -> Data {
                await withCheckedContinuation { continuation = $0; entered.fulfill() }
            }
            func release() { continuation?.resume(returning: Data(#"{"input_tokens":1000}"#.utf8)); continuation = nil }
        }
        let probe = StartProbe()
        let provider = NoNetworkProvider(probe: probe)
        let started = expectation(description: "新请求完成计数后启动")
        probe.onStart = { started.fulfill() }
        let oldSession = URLSession(configuration: .ephemeral)
        defer { oldSession.invalidateAndCancel(); provider.cancel() }
        provider.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { _ in })
        provider.urlSession = oldSession
        provider.sessionGeneration = provider.pacedGeneration
        let oldDelegate = ChatRequestDelegate(owner: provider, generation: provider.pacedGeneration)
        provider.cancel()
        var errors = 0
        provider.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { _ in errors += 1 })
        let entered = expectation(description: "计数进入等待")
        let gate = CountGate(entered)
        provider.tokenCounter = OfficialTokenCounter(fetch: { _ in await gate.fetch() })
        provider.budgetState = { .init(enabled: true, isBudgetSet: true, budgetUSD: 0.0062, spentUSD: 0) }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "claude-haiku-4-5", "max_tokens": 1024,
            "messages": [["role": "user", "content": String(repeating: "字", count: 1000)]]])
        provider.startRequest(request)
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertTrue(provider.requestPending)
        oldDelegate.urlSession(oldSession, task: oldSession.dataTask(with: request), didCompleteWithError: URLError(.cancelled))
        XCTAssertTrue(provider.requestPending)
        XCTAssertTrue(provider.isStreaming)
        XCTAssertEqual(errors, 0)
        await gate.release()
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(probe.starts, 1)
    }
}

extension ReviewCostFixTests {
    func testF8SameKeyCardsMergeAndRotatedHistoryIsExcluded() {
        let identity = BillingKeyIdentity.hash("fixture-key", host: "openrouter.ai")
        XCTAssertEqual(identity, BillingKeyIdentity.hash("fixture-key", host: "OPENROUTER.AI"))
        XCTAssertFalse(identity.contains("fixture-key"))
        let other = BillingKeyIdentity.hash("rotated-key", host: "openrouter.ai")
        func row(_ id: String, _ hash: String?, _ cost: Double) -> UsageRecord {
            var r = UsageRecord(time: Date(), providerId: id, providerName: id, providerType: "openaiCompatible", model: "fixture",
                                input: 1, output: 1, cacheRead: 0, cacheWrite: 0, reasoning: 0, durationMs: 1,
                                status: .ok, kind: .chat, conversationId: nil, profileId: nil, subscription: false, tokensOnly: false)
            r.keyIdentity = hash; r.costUSD = cost
            return r
        }
        let scope = BillingScope.openRouter(records: [row("A", identity, 1), row("B", identity, 2), row("A", other, 4)],
                                             identity: identity, since: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(scope.verified)
        XCTAssertEqual(scope.records.compactMap(\.costUSD).reduce(0, +), 3)
        let unknown = BillingScope.openRouter(records: [row("A", nil, 1)], identity: identity, since: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(unknown.verified)
    }

    func testF8UnknownOrganizationNeverJudgesDifferenceOrMarksRed() {
        let day = BillingDay(date: Date(), ledgerUSD: 3, supplierUSD: 1, scopeVerified: false)
        XCTAssertNil(day.differencePercent)
        XCTAssertFalse(day.mismatched)
    }
}

extension ReviewCostFixTests {
    func testF9CrossUTCMidnightRequeriesAndUsesSecondDate() async throws {
        final class Dates: @unchecked Sendable {
            let lock = NSLock(); var dates: [Date]
            init(_ dates: [Date]) { self.dates = dates }
            func next() -> Date { lock.withLock { dates.removeFirst() } }
        }
        actor Requests {
            var count = 0
            func data() -> Data { count += 1; return Data((count == 1 ? #"{"data":{"usage_daily":0}}"# : #"{"data":{"usage_daily":2}}"#).utf8) }
        }
        let day = BillingReconciliation.calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_140_800))
        let before = day.addingTimeInterval(86_399)
        let second = day.addingTimeInterval(86_402)
        let dates = Dates([day.addingTimeInterval(86_401), second])
        let requests = Requests()
        let client = BillingReconciliation(fetch: { _ in await requests.data() }, clock: { dates.next() })
        let report = try await client.load(provider: .openRouter, key: "fixture-not-a-key", now: before)
        let calls = await requests.count
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(report.reportDate, second)
        XCTAssertEqual(report.dailyUSD[day.addingTimeInterval(86_400)], 2)
        XCTAssertNil(report.dailyUSD[day])
    }

    func testF9StillCrossingAfterRetryShowsUncertainDate() async throws {
        final class Dates: @unchecked Sendable {
            let lock = NSLock(); var index = 0
            let base: Date
            init(_ base: Date) { self.base = base }
            func next() -> Date { lock.withLock { index += 1; return base.addingTimeInterval(Double(index) * 86_400) } }
        }
        let day = BillingReconciliation.calendar.startOfDay(for: Date())
        let dates = Dates(day)
        let client = BillingReconciliation(fetch: { _ in Data(#"{"data":{"usage_daily":2}}"#.utf8) }, clock: { dates.next() })
        let report = try await client.load(provider: .openRouter, key: "fixture-not-a-key", now: day)
        XCTAssertTrue(report.dateUncertain)
        XCTAssertTrue(report.dailyUSD.isEmpty)
        XCTAssertEqual(report.note, "跨日，稍后再看")
    }
}

extension ReviewCostFixTests {
    func testF10SnapshotAndMissingUsageArePartialButUnsentFailureIsNot() {
        let provider = AnthropicProvider()
        provider.processData(Data("event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":1000,\"output_tokens\":0}}}\n\n".utf8))
        let card = APICredential(id: "fixture", name: "fixture", emoji: "", type: .anthropic, baseURL: "https://api.anthropic.com")
        let now = Date()
        let snapshot = UsageRecord(provider: card, modelId: "claude-sonnet-4-6", usage: provider.finalUsage,
                                   started: now, ended: now, status: .error, context: UsageContext(), requestSent: true)
        XCTAssertEqual(snapshot.usageState, .snapshot)
        XCTAssertEqual(snapshot.costSource, .partial)
        let missing = UsageRecord(provider: card, modelId: "claude-sonnet-4-6", usage: nil,
                                  started: now, ended: now, status: .ok, context: UsageContext(), requestSent: true)
        XCTAssertEqual(missing.usageState, .missing)
        let unsent = UsageRecord(provider: card, modelId: "claude-sonnet-4-6", usage: nil,
                                 started: now, ended: now, status: .error, context: UsageContext(), requestSent: false)
        XCTAssertEqual(unsent.costUSD, 0)
        XCTAssertEqual(unsent.budgetCost(estimatedCost: 1), 0)
        let summary = UsageSummarizer.summarize(.today, now: now, records: [snapshot, missing, unsent])
        XCTAssertEqual(summary.totals.partial, 2)
        let complete = UsageRecord(provider: card, modelId: "claude-sonnet-4-6", usage: TokenUsage(inputTokens: 1000, outputTokens: 100),
                                   started: now, ended: now, status: .ok, context: UsageContext(), requestSent: true)
        XCTAssertEqual(complete.usageState, .complete)
        XCTAssertEqual(complete.costSource, .calculated)
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testF7DelegateSnapshotAndSettlementUseSameSerialDomain() async throws {
        let provider = OpenAICompatibleProvider()
        let settlement = RequestUsageSettlement()
        let completed = expectation(description: "结算快照生成")
        provider.resetState(onToken: { _ in }, onComplete: { _, usage in
            MainActor.assumeIsolated {
                _ = settlement.settle(usage) { usage in
                    XCTAssertTrue(Thread.isMainThread)
                    var receipt = usage!
                    receipt.ledgerSpendRecorded = true
                    return receipt
                }
                completed.fulfill()
            }
        }, onError: { _ in XCTFail("不应出错") })
        provider.usageBaseURL = "https://openrouter.ai/api/v1"
        provider.isEventStream = true
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel(); provider.cancel() }
        provider.urlSession = session; provider.sessionGeneration = provider.pacedGeneration
        let delegate = ChatRequestDelegate(owner: provider, generation: provider.pacedGeneration)
        let task = session.dataTask(with: URL(string: "https://fixture.invalid")!)
        delegate.urlSession(session, dataTask: task, didReceive: Data("data: {\"id\":\"gen-serial\",\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":20,\"cost\":0.1,\"prompt_tokens_details\":{\"cached_tokens\":30}}}\n\ndata: [DONE]\n\n".utf8))
        await fulfillment(of: [completed], timeout: 1)
        let receipt = try XCTUnwrap(settlement.receipt)
        XCTAssertEqual(receipt.inputTokens, 100)
        XCTAssertEqual(receipt.outputTokens, 20)
        XCTAssertEqual(receipt.cacheReadTokens, 30)
        XCTAssertEqual(receipt.reportedCostUSD, 0.1)
        XCTAssertTrue(receipt.ledgerSpendRecorded)
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testF8RecoveryUsesOriginalKeyWhenCardRotates() {
        let settlement = RequestUsageSettlement()
        settlement.freezeKey("fixture-original-key", host: "openrouter.ai")
        settlement.freezeKey("fixture-replacement-key", host: "openrouter.ai")
        XCTAssertEqual(settlement.recoveryKey, "fixture-original-key")
        XCTAssertEqual(settlement.keyIdentity, BillingKeyIdentity.hash("fixture-original-key", host: "openrouter.ai"))
    }
}

extension ReviewCostFixTests {
    func testF5CorrectionOnlyAddsThreeSettlementFields() throws {
        var row = UsageRecord(time: Date(), providerId: "fixture", providerName: "fixture", providerType: "openaiCompatible", model: "fixture",
                              input: 100, output: 20, cacheRead: 10, cacheWrite: 5, reasoning: 2, durationMs: 1,
                              status: .ok, kind: .chat, conversationId: nil, profileId: nil, subscription: false, tokensOnly: false)
        row.responseId = "gen-fields"; row.budgetChargeUSD = 0.2; row.requestId = "req"; row.keyIdentity = "hash"
        let data = try JSONEncoder().encode(row.costCorrection(usd: 0.1))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settlementKeys: Set<String> = ["cost", "rid", "correction", "cs", "pv", "bc", "req", "node", "kh", "us", "sent", "cw1h", "ws"]
        XCTAssertEqual(Set(json.keys).intersection(settlementKeys), ["cost", "rid", "correction"])
        XCTAssertEqual(try JSONDecoder().decode(UsageRecord.self, from: data).costSource, .reported)
    }
}

extension ReviewCostFixTests {
    func testF3DuplicateCorrectionUsesPreviouslyChargedActual() {
        let card = APICredential(id: "fixture", name: "fixture", emoji: "", type: .openaiCompatible, baseURL: "https://fixture.invalid")
        var original = UsageRecord(provider: card, modelId: "unknown", usage: nil,
                                   started: Date(), ended: Date(), status: .ok, context: UsageContext())
        original.budgetChargeUSD = 0.5
        let first = original.costCorrection(usd: 0.3)
        XCTAssertEqual(GlobalBudgetStore.costCorrectionDelta(original: original, corrected: first), -0.2, accuracy: 1e-12)
        XCTAssertEqual(GlobalBudgetStore.costCorrectionDelta(original: original, corrected: first, previousCharge: 0.3), 0)
        XCTAssertEqual(GlobalBudgetStore.costCorrectionDelta(original: original, corrected: original.costCorrection(usd: 0.4), previousCharge: 0.3), 0.1, accuracy: 1e-12)
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testF6WireEstimateIncludesToolCallsWithNullText() async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "gpt-4o-mini", "max_completion_tokens": 1,
            "messages": [["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call", "type": "function",
                "function": ["name": "noop", "arguments": String(repeating: "字", count: 1000)]]]]]])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(BudgetPreflight.estimate(request)).input, 1000)
        let decision = await BudgetPreflight.decision(request, counter: OfficialTokenCounter(fetch: { _ in
            XCTFail("远超余额不调计数接口"); return Data()
        }), state: { .init(enabled: true, isBudgetSet: true, budgetUSD: 0.00001, spentUSD: 0) })
        XCTAssertFalse(decision.allowed)
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testF4FooterIncludesAllRoundsAndReplaysZeroTokenCorrection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = UsageLedger(fileURL: url)
        let service = UsageCostSettlement(ledger: ledger)
        let node = MessageNode(id: "node-fixture", role: "assistant", content: "", contentType: "text",
                               createTime: Date(), parentId: nil, childrenIds: [], conversationId: "conv-fixture", profileId: "profile-fixture")
        func row(_ rid: String, _ amount: Double) -> UsageRecord {
            var r = UsageRecord(time: Date(), providerId: "fixture", providerName: "fixture", providerType: "openaiCompatible", model: "fixture",
                                input: 10, output: 2, cacheRead: 0, cacheWrite: 0, reasoning: 0, durationMs: 1,
                                status: .ok, kind: .chat, conversationId: "conv-fixture", profileId: "profile-fixture", subscription: false, tokensOnly: false)
            r.responseId = rid; r.costUSD = amount; r.messageNodeId = node.id
            return r
        }
        let rounds = [row("tool-1", 0.1), row("tool-2", 0.2), row("final", 0.03)]
        for r in rounds { ledger.append(r); service.attach(record: r, node: node) }
        XCTAssertEqual(try XCTUnwrap(node.usageCostUSD), 0.33, accuracy: 1e-12)
        let correction = rounds[0].costCorrection(usd: 0.15)
        ledger.append(correction)
        service.applyNodeCorrection(correction)
        service.applyNodeCorrection(correction)
        XCTAssertEqual(try XCTUnwrap(node.usageCostUSD), 0.38, accuracy: 1e-12)
        XCTAssertEqual(node.usagePromptTokens, 30)
        let reloaded = UsageCostSettlement(ledger: ledger)
        reloaded.attach(record: rounds[0], node: node)
        XCTAssertEqual(try XCTUnwrap(node.usageCostUSD), 0.38, accuracy: 1e-12)
        let foreign = MessageNode(id: node.id, role: "assistant", content: "", contentType: "text", createTime: Date(),
                                  parentId: nil, childrenIds: [], conversationId: "other", profileId: "other-profile")
        reloaded.attach(record: rounds[0], node: foreign)
        XCTAssertNil(foreign.usageCostUSD)
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testF7OAuthQueuedDoneCannotCompleteNextGeneration() async {
        let provider = ChatGPTOAuthProvider()
        var completions = 0
        provider.resetState(onToken: { _ in }, onComplete: { _, _ in completions += 1 }, onError: { _ in })
        provider.processData(Data("data: [DONE]\n\n".utf8))
        provider.resetState(onToken: { _ in }, onComplete: { _, _ in completions += 1 }, onError: { _ in })
        await Task.yield(); await Task.yield()
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(provider.isStreaming)
        provider.cancel()
    }
}

extension ReviewCostFixTests {
    func testF5CorrectionKeepsLegacyFailureCountAndLogicalStatus() {
        let card = APICredential(id: "fixture", name: "fixture", emoji: "", type: .openaiCompatible, baseURL: "https://fixture.invalid")
        var row = UsageRecord(provider: card, modelId: "unknown", usage: nil, started: Date(), ended: Date(),
                              status: .error, context: UsageContext())
        row.responseId = "gen-error"
        let correction = row.costCorrection(usd: 0.1)
        XCTAssertEqual([row, correction].filter { $0.status == .error }.count, 1)
        XCTAssertEqual(correction.status, .ok)
        XCTAssertEqual(UsageLedger.latestRecords([row, correction]).first?.status, .error)
    }
}

extension ReviewCostFixTests {
    func testF10ReportedCorrectionDoesNotInventCompleteTokenUsage() {
        let card = APICredential(id: "fixture", name: "fixture", emoji: "", type: .openaiCompatible, baseURL: "https://fixture.invalid")
        var row = UsageRecord(provider: card, modelId: "unknown", usage: nil, started: Date(), ended: Date(), status: .error, context: UsageContext())
        row.responseId = "gen-missing"
        let merged = UsageLedger.latestRecords([row, row.costCorrection(usd: 0.1)]).first!
        XCTAssertEqual(merged.costSource, .reported)
        XCTAssertEqual(merged.usageState, .missing)
        XCTAssertEqual(merged.input + merged.output, 0)
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testF7NonStreamSourcesStayInRequestGeneration() async throws {
        let provider = AnthropicProvider()
        let done = expectation(description: "整包播放完成")
        provider.resetState(onToken: { _ in }, onComplete: { _, _ in done.fulfill() }, onError: { _ in XCTFail("不应出错") })
        let generation = provider.pacedGeneration
        provider.rawBody = Data(#"{"content":[{"type":"text","text":"ok"},{"type":"web_search_tool_result","content":[{"type":"web_search_result","url":"https://fixture.invalid/source","title":"fixture"}]}],"usage":{"input_tokens":1000,"output_tokens":10}}"#.utf8)
        provider.handleNonStreamBody()
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(provider.pacedGeneration, generation)
        XCTAssertEqual(provider.streamingWebSources.count, 1)
        provider.cancel()
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testF10CompleteNonStreamToolUsageIsNotSnapshot() async {
        final class ToolBody: BaseChatProvider {
            override func parseNonStreamBody(_ data: Data) throws -> NonStreamResult {
                NonStreamResult(text: "", toolCalls: [ToolCallBlock(id: "call", name: "noop", argumentsJSON: "{}")],
                                usage: TokenUsage(inputTokens: 100, outputTokens: 20))
            }
        }
        let provider = ToolBody()
        let done = expectation(description: "整包工具回调")
        provider.resetState(onToken: { _ in }, onComplete: { _, _ in XCTFail("应回工具") }, onError: { _ in XCTFail("不应出错") })
        provider.onToolCalls = { _ in done.fulfill() }
        provider.handleNonStreamBody()
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(provider.finalUsage?.completeness, .complete)
    }

    func testF10IdOrCostWithoutTokenFieldsRemainsMissingUsage() {
        let base = "https://openrouter.ai/api/v1"
        XCTAssertEqual(APIUsageParser.openAI(["id": "gen-only"], baseURL: base)?.completeness, .missing)
        XCTAssertEqual(APIUsageParser.openAI(["usage": ["cost": 0]], baseURL: base)?.completeness, .missing)
        XCTAssertEqual(APIUsageParser.openAI(["id": "gen-snapshot", "usage": ["prompt_tokens": 100]], baseURL: base)?.completeness, .snapshot)
    }
}

extension ReviewCostFixTests {
    func testF4UnknownRoundKeepsFooterUnknownUntilCorrection() {
        let card = APICredential(id: "fixture", name: "fixture", emoji: "", type: .openaiCompatible, baseURL: "https://fixture.invalid")
        var unknown = UsageRecord(provider: card, modelId: "unknown", usage: nil, started: Date(), ended: Date(), status: .error, context: UsageContext())
        unknown.responseId = "gen-unknown"
        var final = unknown
        final.responseId = "gen-final"; final.costUSD = 0.03; final.costSource = .reported
        var amounts = NodeUsageAmounts()
        amounts.add(unknown); amounts.add(final)
        XCTAssertNil(amounts.costUSD)
        amounts.add(unknown.costCorrection(usd: 0.1))
        XCTAssertEqual(amounts.costUSD!, 0.13, accuracy: 1e-12)
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testF7SettledSnapshotIsIndependentOfLaterSourceMutation() {
        let settlement = RequestUsageSettlement()
        var source = TokenUsage(inputTokens: 100, outputTokens: 20, cacheReadTokens: 30)
        let frozen = settlement.settle(source) { usage in
            var receipt = usage!
            receipt.ledgerSpendRecorded = true
            return receipt
        }
        source.cacheReadTokens = 999
        let repeated = settlement.settle(source) { $0! }
        XCTAssertEqual(frozen.cacheReadTokens, 30)
        XCTAssertEqual(repeated, frozen)
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testRegression4NonCountingRequestGatesAndStartsBeforeReturning() throws {
        @MainActor final class Probe {
            var starts = 0
            var errors = 0
        }
        final class NoNetworkProvider: BaseChatProvider {
            let probe: Probe
            init(_ probe: Probe) { self.probe = probe; super.init() }
            override func startBudgetCheckedRequest(_ request: URLRequest) {
                MainActor.assumeIsolated { probe.starts += 1 }
            }
        }
        let probe = Probe()
        let provider = NoNetworkProvider(probe)
        defer { provider.cancel() }
        provider.tokenCounter = OfficialTokenCounter(fetch: { _ in
            XCTFail("无官方计数的端点不得调计数接口"); return Data()
        })
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/v1/chat/completions")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "gpt-4o", "max_tokens": 4096,
            "messages": [["role": "user", "content": "run one tool then summarize"]]])
        provider.budgetState = { .init(enabled: true, isBudgetSet: true, budgetUSD: 100, spentUSD: 0) }
        provider.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { _ in probe.errors += 1 })
        provider.startRequest(request)
        XCTAssertEqual(probe.starts, 1, "无需计数时不能把首轮发送再排到主线程队尾")
        XCTAssertFalse(provider.requestPending)

        provider.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { _ in probe.errors += 1 })
        provider.budgetState = { .init(enabled: true, isBudgetSet: true, budgetUSD: 100, spentUSD: 100) }
        provider.startRequest(request)
        XCTAssertEqual(probe.starts, 1, "同步路径仍须按当前余额执行最终 gate")
        XCTAssertEqual(probe.errors, 1)
        XCTAssertFalse(provider.requestPending)
        XCTAssertFalse(provider.isStreaming)
    }

    @MainActor
    func testRegression4PendingPreflightRetainsProviderUntilStartThenReleases() async throws {
        final class NoNetworkProvider: BaseChatProvider {
            let onStart: () -> Void
            init(onStart: @escaping () -> Void) { self.onStart = onStart; super.init() }
            override func startBudgetCheckedRequest(_ request: URLRequest) { onStart() }
        }
        let started = expectation(description: "临时 provider 完成预检后启动")
        weak var pendingProvider: NoNetworkProvider?
        do {
            let provider = NoNetworkProvider(onStart: { started.fulfill() })
            pendingProvider = provider
            provider.budgetState = { .init(enabled: true, isBudgetSet: true, budgetUSD: 0.0062, spentUSD: 0) }
            provider.tokenCounter = OfficialTokenCounter(fetch: { _ in
                await Task.yield()
                return Data(#"{"input_tokens":1000}"#.utf8)
            })
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "claude-haiku-4-5", "max_tokens": 1024,
                "messages": [["role": "user", "content": String(repeating: "字", count: 1000)]]])
            provider.startRequest(request)
        }
        XCTAssertNotNil(pendingProvider, "预检进入前必须持有临时 provider")
        await fulfillment(of: [started], timeout: 1)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertNil(pendingProvider, "预检结束后不能留下 Task 持有环")
    }

    @MainActor
    func testRegression1OAuthCompletedUsageIsCompleteBeforeDone() async {
        let provider = ChatGPTOAuthProvider()
        let callback = expectation(description: "完成事件的工具 usage")
        provider.onToolCalls = { _ in callback.fulfill() }
        provider.processData(Data("data: {\"type\":\"response.function_call.added\",\"item\":{\"id\":\"fixture-item\",\"call_id\":\"fixture-call\",\"name\":\"noop\"}}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":67,\"output_tokens\":13}}}\n\n".utf8))
        await fulfillment(of: [callback], timeout: 1)
        XCTAssertEqual(provider.finalUsage, TokenUsage(inputTokens: 67, outputTokens: 13))
        XCTAssertFalse(provider.receivedDone)
    }
}

extension ReviewCostFixTests {
    @MainActor
    func testRegression2ActiveSessionRetainsOAuthProviderThroughQueuedToolCallback() async {
        let callback = expectation(description: "临时 owner 的 OAuth 工具回调")
        weak var activeProvider: ChatGPTOAuthProvider?
        let session: URLSession
        do {
            let provider = ChatGPTOAuthProvider()
            activeProvider = provider
            provider.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { _ in XCTFail("不应出错") })
            provider.onToolCalls = { _ in callback.fulfill() }
            let delegate = ChatRequestDelegate(owner: provider, generation: provider.pacedGeneration)
            session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: .main)
            provider.urlSession = session
            provider.sessionGeneration = provider.pacedGeneration
            provider.isEventStream = true
        }
        defer { session.invalidateAndCancel() }
        XCTAssertNotNil(activeProvider, "session 必须持有执行中的 provider")
        let task = session.dataTask(with: URL(string: "https://fixture.invalid")!)
        let data = Data("data: {\"type\":\"response.function_call.added\",\"item\":{\"id\":\"fixture-item\",\"call_id\":\"fixture-call\",\"name\":\"noop\"}}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":71,\"output_tokens\":17}}}\n\ndata: [DONE]\n\n".utf8)
        (session.delegate as? ChatRequestDelegate)?.urlSession(session, dataTask: task, didReceive: data)
        (session.delegate as? ChatRequestDelegate)?.urlSession(session, task: task, didCompleteWithError: nil)
        await fulfillment(of: [callback], timeout: 1)
    }
}

extension ReviewCostFixTests {
    func testRegression4IntegerZeroCostHasMissingTokensAndReportedZero() throws {
        let base = "https://openrouter.ai/api/v1"
        let swift = try XCTUnwrap(APIUsageParser.openAI(["usage": ["cost": 0]], baseURL: base))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"usage":{"cost":0}}"#.utf8)) as? [String: Any])
        let decoded = try XCTUnwrap(APIUsageParser.openAI(json, baseURL: base))
        XCTAssertEqual(swift, decoded)
        XCTAssertEqual(swift.reportedCostUSD, 0)
        XCTAssertEqual(swift.completeness, .missing)
        XCTAssertNil(APIUsageParser.openAI(["usage": ["cost": 0]], baseURL: "https://fixture.invalid"))
    }
}
