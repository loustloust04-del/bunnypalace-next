import XCTest
@testable import 记忆花园

/// research-magpie 2.1：逐次调用账本（usage.jsonl）+ 汇总（今天按时 / 7·30 天按天 / 更久按周）。
final class UsageLedgerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageLedgerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func credential(_ type: ProviderType, id: String = "cred-a", name: String = "卡A") -> APICredential {
        APICredential(id: id, name: name, emoji: "🧪", type: type, baseURL: "https://x")
    }

    private func record(
        _ model: String = "claude-sonnet-4-5", at time: Date, provider: String = "cred-a", providerName: String = "卡A",
        input: Int = 1000, output: Int = 100, kind: UsageKind = .chat, status: UsageRecord.Status = .ok,
        subscription: Bool = false, tokensOnly: Bool = false
    ) -> UsageRecord {
        UsageRecord(time: time, providerId: provider, providerName: providerName, providerType: "anthropic", model: model,
                    input: input, output: output, cacheRead: 0, cacheWrite: 0, reasoning: 0, durationMs: 10,
                    status: status, kind: kind, conversationId: nil, profileId: nil,
                    subscription: subscription, tokensOnly: tokensOnly)
    }

    // MARK: 记录构造

    func testRecordNormalizesPromptTokensPerProviderType() {
        let started = Date(timeIntervalSince1970: 1000)
        let ended = started.addingTimeInterval(1.5)
        let usage = TokenUsage(inputTokens: 100, outputTokens: 20, cacheReadTokens: 300, cacheWriteTokens: 50, reasoningTokens: 7)
        let ctx = UsageContext(kind: .summary, conversationId: "conv-1", profileId: "p-1")

        let anth = UsageRecord(provider: credential(.anthropic), modelId: "claude-sonnet-4-5", usage: usage,
                               started: started, ended: ended, status: .ok, context: ctx)
        XCTAssertEqual(anth.input, 450, "Anthropic input_tokens 不含缓存 → 补成总 prompt")
        XCTAssertEqual(anth.cacheRead, 300)
        XCTAssertEqual(anth.cacheWrite, 50)
        XCTAssertEqual(anth.reasoning, 7)
        XCTAssertEqual(anth.durationMs, 1500)
        XCTAssertEqual(anth.kind, .summary)
        XCTAssertEqual(anth.conversationId, "conv-1")
        XCTAssertEqual(anth.profileId, "p-1")
        XCTAssertEqual(anth.providerName, "卡A")
        XCTAssertFalse(anth.subscription)

        let oai = UsageRecord(provider: credential(.openaiCompatible), modelId: "gpt-4o", usage: usage,
                              started: started, ended: ended, status: .ok, context: ctx)
        XCTAssertEqual(oai.input, 100, "OAI prompt_tokens 本来就含缓存")

        let oauth = UsageRecord(provider: credential(.chatgptOAuth), modelId: "gpt-5", usage: nil,
                                started: started, ended: ended, status: .error, context: ctx)
        XCTAssertTrue(oauth.subscription, "ChatGPT 登录走订阅额度，不按 API 价计费")
        XCTAssertEqual(oauth.input + oauth.output, 0)
        XCTAssertEqual(oauth.status, .error)
    }

    // MARK: 落盘

    func testAppendAndLoadRoundTrip() {
        let ledger = UsageLedger(fileURL: tempDir.appendingPathComponent("usage.jsonl"))
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        ledger.append(record(at: t))
        ledger.append(record("gpt-4o", at: t.addingTimeInterval(60), kind: .memory))
        let all = ledger.load()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[1].model, "gpt-4o")
        XCTAssertEqual(all[1].kind, .memory)
        XCTAssertEqual(ledger.load(since: t.addingTimeInterval(30)).count, 1)
    }

    func testLoadSkipsCorruptLinesAndUnknownKinds() throws {
        let url = tempDir.appendingPathComponent("usage.jsonl")
        let ledger = UsageLedger(fileURL: url)
        ledger.append(record(at: Date(timeIntervalSince1970: 1)))
        _ = ledger.load()   // 追加是异步串行的；load 走同一队列，当屏障用
        var raw = try Data(contentsOf: url)
        raw.append(Data("{half a line\n\n".utf8))
        raw.append(Data(#"{"t":2,"provider":"x","model":"m","in":1,"out":1,"kind":"from-the-future"}"#.utf8))
        raw.append(Data("\n".utf8))
        try raw.write(to: url)
        let loaded = ledger.load()
        XCTAssertEqual(loaded.count, 2, "坏行跳过；新版本写的未知 kind 不拖垮整份账本")
        XCTAssertEqual(loaded[1].kind, .other)
    }

    func testAppendFailureIsSilent() throws {
        // 父路径是个文件 → 建目录、写文件都会失败；必须静默
        let blocker = tempDir.appendingPathComponent("blocker")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker)
        let ledger = UsageLedger(fileURL: blocker.appendingPathComponent("usage.jsonl"))
        ledger.append(record(at: Date()))
        XCTAssertEqual(ledger.load(), [])
    }

    // MARK: 计价

    func testRecordCost() {
        let price: (String) -> ModelPricing? = { $0 == "known" ? ModelPricing(2, 10) : nil }
        let t = Date()
        XCTAssertEqual(record("known", at: t, input: 1_000_000, output: 100_000).cost(price: price)!, 3, accuracy: 1e-9)
        XCTAssertNil(record("unknown", at: t).cost(price: price), "查不到价 = 不知道")
        XCTAssertEqual(record("unknown", at: t, subscription: true).cost(price: price), 0, "订阅通道不花 API 钱")
        XCTAssertEqual(record("unknown", at: t, input: 0, output: 0, status: .error).cost(price: price), 0, "没有 token 的失败调用不算未计价")
        XCTAssertNil(record("known", at: t, tokensOnly: true).cost(price: price), "Code 侧只有总 token，拆不出输入输出")
    }

    // MARK: 汇总

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private let price: (String) -> ModelPricing? = { id in
        switch id {
        case "cheap": return ModelPricing(1, 2)
        case "pricey": return ModelPricing(10, 20)
        default: return nil
        }
    }

    func testTodayBucketsByHour() {
        let now = date(2026, 9, 24, 15, 30)
        let recs = [
            record("cheap", at: date(2026, 9, 23, 23, 59), input: 1_000_000, output: 0),   // 昨天，不计
            record("cheap", at: date(2026, 9, 24, 0, 5), input: 1_000_000, output: 0),
            record("pricey", at: date(2026, 9, 24, 15, 1), input: 1_000_000, output: 0),
            record("mystery", at: date(2026, 9, 24, 15, 2)),
            record("cheap", at: date(2026, 9, 24, 15, 3), input: 0, output: 0, status: .error),
        ]
        let s = UsageSummarizer.summarize(.today, now: now, records: recs, calendar: calendar, price: price)
        XCTAssertEqual(s.bucket, .hour)
        XCTAssertEqual(s.series.count, 24, "空时段也占位")
        XCTAssertEqual(s.series[0].totals.calls, 1)
        XCTAssertEqual(s.series[15].totals.calls, 3)
        XCTAssertEqual(s.series[0].label, "00")
        XCTAssertEqual(s.totals.calls, 4)
        XCTAssertEqual(s.totals.errors, 1)
        XCTAssertEqual(s.totals.unpriced, 1)
        XCTAssertEqual(s.totals.costUSD, 11, accuracy: 1e-9)
        XCTAssertEqual(s.models.first?.id, "pricey", "榜单按花费降序")
        XCTAssertEqual(s.models.map(\.id), ["pricey", "cheap", "mystery"])
    }

    func testWeekAndMonthBucketByDay() {
        let now = date(2026, 9, 24, 10)
        let recs = [
            record("cheap", at: date(2026, 9, 17, 23), input: 1_000_000, output: 0), // 7 天窗外
            record("cheap", at: date(2026, 9, 18, 1), input: 1_000_000, output: 0),
            record("cheap", at: date(2026, 9, 24, 9), input: 1_000_000, output: 0),
            record("cheap", at: date(2026, 8, 26, 9), input: 1_000_000, output: 0),  // 30 天窗首日
        ]
        let week = UsageSummarizer.summarize(.week, now: now, records: recs, calendar: calendar, price: price)
        XCTAssertEqual(week.bucket, .day)
        XCTAssertEqual(week.series.count, 7)
        XCTAssertEqual(week.series.first?.totals.calls, 1)
        XCTAssertEqual(week.series.last?.totals.calls, 1)
        XCTAssertEqual(week.series.first?.label, "9/18")
        XCTAssertEqual(week.totals.calls, 2)

        let month = UsageSummarizer.summarize(.month, now: now, records: recs, calendar: calendar, price: price)
        XCTAssertEqual(month.series.count, 30)
        XCTAssertEqual(month.totals.calls, 4)
        XCTAssertEqual(month.series.first?.totals.calls, 1)
    }

    func testAllUsesDaysUntilSixtyThenWeeks() {
        let now = date(2026, 9, 24, 10)
        let short = UsageSummarizer.summarize(.all, now: now,
                                              records: [record("cheap", at: date(2026, 9, 1, 10))],
                                              calendar: calendar, price: price)
        XCTAssertEqual(short.bucket, .day)
        XCTAssertEqual(short.series.count, 24)

        let recs = [record("cheap", at: date(2026, 1, 7, 10)), record("cheap", at: date(2026, 9, 24, 9))]
        let long = UsageSummarizer.summarize(.all, now: now, records: recs, calendar: calendar, price: price)
        XCTAssertEqual(long.bucket, .week)
        // 2026-01-07 是周三 → 从 1/5（周一）起；到 9/21 那周共 38 周
        XCTAssertEqual(long.series.first?.label, "1/5")
        XCTAssertEqual(long.series.count, 38)
        XCTAssertEqual(long.series.first?.totals.calls, 1)
        XCTAssertEqual(long.series.last?.totals.calls, 1)

        let empty = UsageSummarizer.summarize(.all, now: now, records: [], calendar: calendar, price: price)
        XCTAssertEqual(empty.series.count, 1)
        XCTAssertEqual(empty.totals.calls, 0)
    }

    func testProviderBoardAndScopeFilter() {
        let now = date(2026, 9, 24, 10)
        let recs = [
            record("cheap", at: date(2026, 9, 24, 1), provider: "cred-a", providerName: "卡A", input: 1_000_000, output: 0),
            record("cheap", at: date(2026, 9, 24, 2), provider: "cred-b", providerName: "卡B", input: 3_000_000, output: 0),
            record("cheap", at: date(2026, 9, 24, 3), provider: "cred-a", providerName: "卡A改名", input: 1_000_000, output: 0),
            record("opus", at: date(2026, 9, 24, 4), provider: "claude", providerName: "claude",
                   input: 50_000, output: 0, kind: .code, tokensOnly: true),
        ]
        let all = UsageSummarizer.summarize(.today, now: now, records: recs, calendar: calendar, price: price)
        XCTAssertEqual(all.providers.map(\.id), ["cred-b", "cred-a", "claude"])
        XCTAssertEqual(all.providers[1].label, "卡A改名", "显示最近一次的名字")
        XCTAssertEqual(all.providers[1].totals.costUSD, 2, accuracy: 1e-9)
        XCTAssertEqual(all.totals.unpriced, 0, "Code 的会话级 token 不算未计价")
        XCTAssertEqual(all.totals.tokens, 5_050_000)

        let chat = UsageSummarizer.summarize(.today, now: now, records: recs, calendar: calendar, scope: .chat, price: price)
        XCTAssertEqual(chat.totals.calls, 3)
        let code = UsageSummarizer.summarize(.today, now: now, records: recs, calendar: calendar, scope: .code, price: price)
        XCTAssertEqual(code.totals.calls, 1)
        XCTAssertEqual(code.models.first?.id, "opus")
    }

    // MARK: 保险闸兼容

    func testBudgetSpentCanBeRebuiltFromLedger() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let recs = [
            record("cheap", at: t, input: 1_000_000, output: 0),
            record("mystery", at: t.addingTimeInterval(10), input: 1_000_000, output: 0),
            record("cheap", at: t.addingTimeInterval(20), input: 1_000_000, output: 0, subscription: true),
            record("opus", at: t.addingTimeInterval(30), input: 1_000_000, output: 0, kind: .code, tokensOnly: true),
            record("cheap", at: t.addingTimeInterval(-10), input: 1_000_000, output: 0),
        ]
        let spent = GlobalBudgetStore.ledgerSpentUSD(records: recs, since: t, price: price)
        XCTAssertEqual(spent, 1 + PricingCatalog.budgetFallback.inputUSDPerMTok, accuracy: 1e-9,
                       "未计价按保险闸保守价；订阅 / Code 不进 API 预算；重置点之前的不算")
    }
}

extension UsageLedgerTests {
    func testFormatting() {
        XCTAssertEqual(UsageFormat.tokens(0), "0")
        XCTAssertEqual(UsageFormat.tokens(999), "999")
        XCTAssertEqual(UsageFormat.tokens(12_345), "12.3K")
        XCTAssertEqual(UsageFormat.tokens(4_500_000), "4.5M")
        XCTAssertEqual(UsageFormat.cost(0), "$0")
        XCTAssertEqual(UsageFormat.cost(0.004), "<$0.01")
        XCTAssertEqual(UsageFormat.cost(1.234), "$1.23")
        XCTAssertEqual(UsageFormat.cost(1234.5), "$1234.50")
        XCTAssertEqual(UsageFormat.unpricedNote(0), nil)
        XCTAssertEqual(UsageFormat.unpricedNote(3), "3 次未计价（查不到模型价格，未计入花费）")
    }
}

extension UsageLedgerTests {
    func testCostFieldsRoundTripAndLegacyDefaults() throws {
        let old = Data(#"{"t":1,"provider":"p","model":"m","in":10,"out":2}"#.utf8)
        var row = try XCTUnwrap(UsageLedger.decode(lines: old).first)
        XCTAssertNil(row.costUSD)
        XCTAssertNil(row.costSource)
        XCTAssertEqual(row.effectiveCostSource, .estimated)
        XCTAssertEqual(row.cacheWrite1h, 0)
        XCTAssertEqual(row.webSearches, 0)
        row.costUSD = 0
        row.costSource = .reported
        row.priceVersion = "fixture"
        row.cacheWrite1h = 4
        row.webSearches = 2
        row.responseId = "gen-fixture"
        let ledger = UsageLedger(fileURL: tempDir.appendingPathComponent("fields.jsonl"))
        ledger.append(row)
        XCTAssertEqual(ledger.load(), [row])
        struct LegacyRow: Decodable { let model: String }
        let encoded = try JSONEncoder().encode(row)
        XCTAssertEqual(try JSONDecoder().decode(LegacyRow.self, from: encoded).model, "m")
    }
}

extension UsageLedgerTests {
    func testStoredCostSurvivesPriceChangeAndReportedZero() {
        let t = Date()
        var row = UsageRecord(provider: credential(.openaiCompatible), modelId: "gpt-4o",
                              usage: TokenUsage(inputTokens: 1000, outputTokens: 20, reportedCostUSD: 0),
                              started: t, ended: t, status: .ok, context: UsageContext())
        XCTAssertEqual(row.costUSD, 0)
        XCTAssertEqual(row.costSource, .reported)
        XCTAssertEqual(row.cost(price: { _ in ModelPricing(999, 999) }), 0)
        row.costUSD = 1.25
        XCTAssertEqual(row.cost(price: { _ in nil }), 1.25)
    }
}

extension UsageLedgerTests {
    func testCorrectionReplacesCallWithoutDoubleCounting() {
        let t = date(2026, 10, 11, 12)
        var original = record("cheap", at: t)
        original.responseId = "gen-1"
        original.costUSD = 0.1
        var correction = original
        correction.costUSD = 0.25
        correction.costSource = .reported
        correction.correction = true
        let ledger = UsageLedger(fileURL: tempDir.appendingPathComponent("correction.jsonl"))
        ledger.append(original)
        ledger.append(record("cheap", at: t))
        ledger.append(correction)
        XCTAssertEqual(ledger.load().count, 2)
        let sum = UsageSummarizer.summarize(.today, now: t, records: [original, correction], calendar: calendar)
        XCTAssertEqual(sum.totals.calls, 1)
        XCTAssertEqual(sum.totals.costUSD, 0.25)
        XCTAssertEqual(sum.totals.input, original.input)
        XCTAssertEqual(ledger.load().first(where: { $0.responseId != nil })?.kind, original.kind)
    }
}

extension UsageLedgerTests {
    func testSummaryCountsPartialAndLegacyAmounts() {
        let t = date(2026, 10, 11, 12)
        var partial = record("cheap", at: t)
        partial.costUSD = 0.5
        partial.costSource = .partial
        let sum = UsageSummarizer.summarize(.today, now: t, records: [partial, record("cheap", at: t)], calendar: calendar, price: price)
        XCTAssertEqual(sum.totals.partial, 1)
        XCTAssertEqual(sum.totals.estimated, 1)
    }
}

extension UsageLedgerTests {
    func testBudgetReadsStoredAmountsAndDeduplicatesCorrections() {
        var row = record(at: Date())
        row.costUSD = 0.2
        row.costSource = .calculated
        row.responseId = "gen-budget"
        var corrected = row
        corrected.costUSD = 0.3
        corrected.correction = true
        XCTAssertEqual(GlobalBudgetStore.ledgerSpentUSD(records: [row, corrected], since: nil, price: { _ in ModelPricing(999, 999) }), 0.3)
        let usage = TokenUsage(inputTokens: 100, outputTokens: 20, ledgerCostUSD: 0.3, ledgerCostRecorded: true)
        XCTAssertEqual(BudgetCalculator.actualCost(provider: credential(.openaiCompatible), modelId: row.model, usage: usage), 0.3)
    }
}
