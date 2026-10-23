import XCTest
@testable import 记忆花园

/// L2 单词在场信号：快照组装纯函数（streak / 今日复习统计 / activity 窗口 / 截断）。
@MainActor
final class VocabSignalsTests: XCTestCase {

    private func entry(_ word: String, _ ts: Date, rating: String = "good") -> VocabReviewLogEntry {
        VocabReviewLogEntry(word: word, ts: ts, exercise: "read", rating: rating, intervalBefore: 0)
    }

    private func day(_ offset: Int, from now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: now)!
    }

    // MARK: - streak

    func testStreakConsecutiveIncludingToday() {
        let now = Date()
        let keys = Set([0, -1, -2].map { ReadingSignals.dayKey(day($0, from: now)) })
        XCTAssertEqual(VocabSignals.streakDays(dayKeys: keys, now: now), 3)
    }

    func testStreakTodayNotStudiedCountsFromYesterday() {
        let now = Date()
        let keys = Set([-1, -2].map { ReadingSignals.dayKey(day($0, from: now)) })
        XCTAssertEqual(VocabSignals.streakDays(dayKeys: keys, now: now), 2)
    }

    func testStreakBrokenByGap() {
        let now = Date()
        let keys = Set([0, -2, -3].map { ReadingSignals.dayKey(day($0, from: now)) })
        XCTAssertEqual(VocabSignals.streakDays(dayKeys: keys, now: now), 1)
    }

    func testStreakEmpty() {
        XCTAssertEqual(VocabSignals.streakDays(dayKeys: [], now: Date()), 0)
    }

    // MARK: - 今日复习统计

    func testTodayReviewStatsCountsAndWrongTop() {
        let now = Date()
        let yesterday = day(-1, from: now)
        let log = [
            entry("collateral", now, rating: "again"),
            entry("collateral", now, rating: "again"),
            entry("clutch", now, rating: "again"),
            entry("coherent", now, rating: "good"),
            entry("old", yesterday, rating: "again"),   // 昨天的不算
        ]
        let (reviewed, wrongTop) = VocabSignals.todayReviewStats(log: log, now: now)
        XCTAssertEqual(reviewed, 4)
        XCTAssertEqual(wrongTop, ["collateral", "clutch"])   // 次数降序
    }

    func testWrongTopCapsAtFive() {
        let now = Date()
        let log = (0..<8).map { entry("w\($0)", now, rating: "again") }
        let (_, wrongTop) = VocabSignals.todayReviewStats(log: log, now: now)
        XCTAssertEqual(wrongTop.count, 5)
    }

    // MARK: - 快照

    func testSnapshotActivityWithinWindow() {
        let now = Date()
        var s = VocabSignals.TodayState()
        s.day = ReadingSignals.dayKey(now)
        s.activityRaw = "reviewing"
        s.lastActionAt = now.addingTimeInterval(-60)
        let snap = VocabSignals.buildSnapshot(state: s, log: [], now: now)
        XCTAssertEqual(snap["activity"] as? String, "reviewing")
    }

    func testSnapshotActivityNullWhenStale() {
        let now = Date()
        var s = VocabSignals.TodayState()
        s.day = ReadingSignals.dayKey(now)
        s.activityRaw = "studying"
        s.lastActionAt = now.addingTimeInterval(-VocabSignals.activityWindow - 1)
        let snap = VocabSignals.buildSnapshot(state: s, log: [], now: now)
        XCTAssertTrue(snap["activity"] is NSNull || snap["activity"] == nil)
    }

    func testSnapshotTodayBlockAndStreakIncludesStudyOnlyToday() {
        let now = Date()
        var s = VocabSignals.TodayState()
        s.day = ReadingSignals.dayKey(now)
        s.studied = 12
        s.recentWords = ["clutch"]
        s.collected = [.init(word: "wobble", from: "聊天")]
        let log = [entry("x", day(-1, from: now))]   // 昨天复习过
        let snap = VocabSignals.buildSnapshot(state: s, log: log, now: now)
        let today = snap["today"] as? [String: Any]
        XCTAssertEqual(today?["studied"] as? Int, 12)
        XCTAssertEqual((today?["collected"] as? [[String: String]])?.first?["word"], "wobble")
        // 昨天有 log + 今天只刷了词（无复习）→ streak 2（今天由 studied>0 补入）
        XCTAssertEqual(snap["streak"] as? Int, 2)
    }
}
