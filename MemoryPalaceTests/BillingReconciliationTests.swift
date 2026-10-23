import XCTest
@testable import 记忆花园

final class BillingReconciliationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_140_800)

    func testOpenRouterOptionalDailyFieldAndZero() throws {
        let zero = try BillingReconciliation.parse(Data(#"{"data":{"usage_daily":0,"usage_weekly":12}}"#.utf8), provider: .openRouter, now: now)
        XCTAssertEqual(zero.report.dailyUSD[BillingReconciliation.calendar.startOfDay(for: now)], 0)
        let absent = try BillingReconciliation.parse(Data(#"{"data":{"usage_weekly":12}}"#.utf8), provider: .openRouter, now: now)
        XCTAssertTrue(absent.report.dailyUSD.isEmpty)
        XCTAssertEqual(BillingReconciliation.days(now: now, records: [], report: zero.report).filter { $0.supplierUSD != nil }.count, 1)
    }

    func testAnthropicCentsAndOpenAIDollarAmount() throws {
        let anth = Data(#"{"data":[{"starting_at":"2026-10-11T00:00:00Z","results":[{"amount":"123.45","currency":"USD"},{"amount":"25","currency":"USD"}]}],"has_more":false}"#.utf8)
        let parsed = try BillingReconciliation.parse(anth, provider: .anthropic, now: now)
        XCTAssertEqual(parsed.report.dailyUSD.values.first!, 1.4845, accuracy: 1e-12)
        let oai = Data(#"{"data":[{"start_time":1760140800,"results":[{"amount":{"value":1.2,"currency":"usd"}}]}],"has_more":true,"next_page":"p2"}"#.utf8)
        let openai = try BillingReconciliation.parse(oai, provider: .openAI, now: now)
        XCTAssertEqual(openai.report.dailyUSD.values.first, 1.2)
        XCTAssertEqual(openai.nextPage, "p2")
        let bad = Data(#"{"data":[{"start_time":1760140800,"results":[{"amount":{"value":1.2,"currency":"eur"}}]}]}"#.utf8)
        XCTAssertTrue(try BillingReconciliation.parse(bad, provider: .openAI, now: now).report.dailyUSD.isEmpty)
    }

    func testPaginationIsFollowedWithoutChangingLedger() async throws {
        actor Requests {
            var count = 0
            func reply(_ request: URLRequest) -> Data {
                count += 1
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                if count == 1 {
                    XCTAssertNil(components.queryItems?.first { $0.name == "page" })
                    return Data(#"{"data":[{"start_time":1760140800,"results":[{"amount":{"value":1,"currency":"usd"}}]}],"has_more":true,"next_page":"p2"}"#.utf8)
                }
                XCTAssertEqual(components.queryItems?.first { $0.name == "page" }?.value, "p2")
                return Data(#"{"data":[{"start_time":1760140800,"results":[{"amount":{"value":2,"currency":"usd"}}]}],"has_more":false}"#.utf8)
            }
        }
        let requests = Requests()
        let service = BillingReconciliation(fetch: { await requests.reply($0) }, clock: { Date(timeIntervalSince1970: 1_760_140_800) })
        let result = try await service.load(provider: .openAI, key: "fixture-not-a-key", now: now)
        XCTAssertEqual(result.dailyUSD.values.first, 3)
        let count = await requests.count
        XCTAssertEqual(count, 2)
    }

    func testSevenDaysAndDifferenceBoundary() {
        let days = BillingReconciliation.days(now: now, records: [], report: BillingReport())
        XCTAssertEqual(days.count, 7)
        XCTAssertTrue(days.allSatisfy { $0.supplierUSD == nil })
        XCTAssertFalse(BillingDay(date: now, ledgerUSD: 0, supplierUSD: 0).mismatched)
        XCTAssertTrue(BillingDay(date: now, ledgerUSD: 1, supplierUSD: 0).mismatched)
        XCTAssertFalse(BillingDay(date: now, ledgerUSD: 100, supplierUSD: 100).mismatched)
        XCTAssertTrue(BillingDay(date: now, ledgerUSD: 102, supplierUSD: 100).mismatched)
    }
}
