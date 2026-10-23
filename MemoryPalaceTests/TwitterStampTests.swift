import XCTest
@testable import 记忆花园

/// 时间戳的短形态。推特那行是「2h」「1d」而不是完整日期，这条很影响「像不像」。
final class TwitterStampTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC

    private func short(_ secondsAgo: TimeInterval) -> String {
        TwitterStamp.short(Date(timeIntervalSince1970: 1_700_000_000 - secondsAgo), now: now)
    }

    func testJustNow() {
        XCTAssertEqual(short(5), "刚刚")
    }

    func testMinutes() {
        XCTAssertEqual(short(60), "1分")
        XCTAssertEqual(short(59 * 60), "59分")
    }

    func testHours() {
        XCTAssertEqual(short(60 * 60), "1时")
        XCTAssertEqual(short(23 * 3600), "23时")
    }

    func testDays() {
        XCTAssertEqual(short(24 * 3600), "1天")
        XCTAssertEqual(short(6 * 24 * 3600), "6天")
    }

    func testFallsBackToDateBeyondAWeek() {
        // 超过一周就给日期，不然「43天」没人读得懂
        let s = short(30 * 24 * 3600)
        XCTAssertTrue(s.contains("月"), "应该退回月日形态，实际：\(s)")
        XCTAssertFalse(s.contains("天"))
    }

    func testIncludesYearWhenDifferent() {
        let s = short(400 * 24 * 3600)
        XCTAssertTrue(s.contains("年"), "跨年要带年份，实际：\(s)")
    }

    func testFutureStampDoesNotGoNegative() {
        // 设备时钟歪了也不能显示「-3天」
        XCTAssertEqual(TwitterStamp.short(now.addingTimeInterval(3600), now: now), "刚刚")
    }
}
