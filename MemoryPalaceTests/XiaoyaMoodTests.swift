import XCTest
@testable import 记忆花园

/// 小芽 v2 舞台表情（plan-小芽-v2 §3.2 v1.1）：主状态派生 + 短暂反馈压在上面
final class XiaoyaMoodTests: XCTestCase {

    func testBaseStatesMapToFaces() {
        XCTAssertEqual(XiaoyaStageState(base: .idle).mood, .smirk)
        XCTAssertEqual(XiaoyaStageState(base: .thinking).mood, .huh)
        XCTAssertEqual(XiaoyaStageState(base: .reading("世界书")).mood, .huh)
        XCTAssertEqual(XiaoyaStageState(base: .awaitingStamp).mood, .cheer)
        XCTAssertEqual(XiaoyaStageState(base: .error).mood, .sob)
        XCTAssertEqual(XiaoyaStageState(base: .reading("世界书")).status, "在翻你的世界书…")
    }

    func testFeedbackOverridesBase() {
        let cases: [(XiaoyaStageState.Feedback, XiaoyaMood)] = [
            (.approved, .love), (.discarded, .sigh), (.stopped, .shock), (.overwhelmed, .chaos), (.refused, .nope),
        ]
        for (feedback, mood) in cases {
            XCTAssertEqual(XiaoyaStageState(base: .awaitingStamp, feedback: feedback).mood, mood)
        }
    }

    func testBusyOnlyWhileThinkingOrReading() {
        XCTAssertTrue(XiaoyaStageState(base: .thinking).isBusy)
        XCTAssertTrue(XiaoyaStageState(base: .reading("预设")).isBusy)
        XCTAssertFalse(XiaoyaStageState(base: .awaitingStamp).isBusy)
        XCTAssertFalse(XiaoyaStageState(base: .idle, feedback: .stopped).isBusy)
    }

    func testReadingLabelOnlyForReadTools() {
        XCTAssertEqual(XiaoyaStageState.readingLabel(forTool: "read_world_book"), "世界书")
        XCTAssertEqual(XiaoyaStageState.readingLabel(forTool: "query_memories"), "记忆")
        XCTAssertNil(XiaoyaStageState.readingLabel(forTool: "propose_create_character"))
        XCTAssertNil(XiaoyaStageState.readingLabel(forTool: "rm_rf"))
    }

    @MainActor
    func testFeedbackExpires() async throws {
        let clock = XiaoyaFeedbackClock()
        clock.flash(.approved, seconds: 0.05)
        XCTAssertEqual(clock.feedback, .approved)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(clock.feedback)
    }

    /// 旧计时器到点不许清掉后来的反馈
    @MainActor
    func testStaleTimerDoesNotClearNewerFeedback() async throws {
        let clock = XiaoyaFeedbackClock()
        clock.flash(.approved, seconds: 0.05)
        clock.flash(.discarded, seconds: 5)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(clock.feedback, .discarded)
    }
}

/// 点小芽翻背面的句子池
final class XiaoyaLinesTests: XCTestCase {
    func testLinesFitOnPaperBack() {
        XCTAssertGreaterThanOrEqual(XiaoyaLines.all.count, 10)
        XCTAssertEqual(Set(XiaoyaLines.all).count, XiaoyaLines.all.count, "有重复的句子")
        for line in XiaoyaLines.all {
            let rows = line.split(separator: "\n")
            XCTAssertLessThanOrEqual(rows.count, 2, line)
            for row in rows { XCTAssertLessThanOrEqual(row.count, 7, "「\(row)」太长，剪纸背面放不下") }
        }
    }

    func testRandomNeverRepeatsLast() {
        var last: String?
        for _ in 0..<200 {
            let next = XiaoyaLines.random(excluding: last)
            XCTAssertNotEqual(next, last)
            last = next
        }
    }
}
