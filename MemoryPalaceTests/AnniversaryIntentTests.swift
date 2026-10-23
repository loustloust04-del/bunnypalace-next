import XCTest
@testable import 记忆花园

/// 聊天里记纪念日（plan-calendar §八，astra #13）：解析、按来源 upsert 幂等。
final class AnniversaryIntentTests: XCTestCase {

    private var g: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { g.date(from: DateComponents(year: y, month: m, day: d))! }

    // MARK: 聊天意向

    func testParseIntent() {
        let today = day(2026, 9, 27)
        let a = AnniversaryIntentWriter.parse(#"{"title": "妈妈生日", "kind": "yearly", "lunar": {"month": 9, "day": 9}, "birthday": true}"#, today: today, calendar: g)
        XCTAssertEqual(a?.lunar, LunarMonthDay(month: 9, day: 9, leap: false))
        XCTAssertEqual(a?.date, "2026-09-27")
        XCTAssertEqual(a?.isBirthday, true)
        XCTAssertNil(AnniversaryIntentWriter.parse(#"{"title": "", "date": "2026-10-01"}"#, today: today, calendar: g))
        XCTAssertNil(AnniversaryIntentWriter.parse(#"{"title": "x", "date": "明天"}"#, today: today, calendar: g))
        XCTAssertNil(AnniversaryIntentWriter.parse("not json", today: today, calendar: g))
        let trip = AnniversaryIntentWriter.parse(#"{"title": "旅行", "kind": "countdown", "date": "2026-11-14", "birthday": true}"#, today: today, calendar: g)
        XCTAssertEqual(trip?.isBirthday, false)   // 只有每年型能是生日
    }

    func testUpsertIsIdempotentBySourceAndByContent() {
        let intent = AnniversaryIntent(title: "妈妈生日", kind: .yearly, date: "1970-10-28", lunar: nil, isBirthday: true, remindDays: 3)
        let src = Anniversary.Source(nodeId: "n1", blockHash: "h1")
        let first = AnniversaryIntentWriter.upsert(intent, source: src, existing: [])
        // 同一块再处理一次 → 同一条
        let again = AnniversaryIntentWriter.upsert(intent, source: src, existing: [first])
        XCTAssertEqual(again.id, first.id)
        // 重生成出的新块（新 nodeId）、同名同日期 → 合并
        let regen = AnniversaryIntentWriter.upsert(intent, source: Anniversary.Source(nodeId: "n2", blockHash: "h1"), existing: [first])
        XCTAssertEqual(regen.id, first.id)
        // 不同日期 → 新的一条
        var other = intent; other.date = "1971-10-28"
        XCTAssertNotEqual(AnniversaryIntentWriter.upsert(other, source: Anniversary.Source(nodeId: "n3", blockHash: "h2"), existing: [first]).id, first.id)
    }

    func testBlockHashIgnoresSurroundingWhitespace() {
        XCTAssertEqual(AnniversaryIntentWriter.blockHash("  {\"a\":1}\n"), AnniversaryIntentWriter.blockHash("{\"a\":1}"))
    }
}
