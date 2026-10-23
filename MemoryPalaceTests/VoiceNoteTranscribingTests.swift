import XCTest
@testable import 记忆花园

/// 语音转写忙状态（sol P1-2）：一次只转一条，任务 id 管开始 / 完成，迟到的完成不清掉别人的
@MainActor
final class VoiceNoteTranscribingTests: XCTestCase {
    func testOneJobAtATimeAndStaleFinishIgnored() {
        let jobs = VoiceNoteTranscribing()
        XCTAssertFalse(jobs.isBusy)
        let a = jobs.begin(conversationId: "c1")
        XCTAssertNotNil(a)
        XCTAssertEqual(jobs.conversationId, "c1")
        XCTAssertNil(jobs.begin(conversationId: "c2"))          // 忙时不并发
        XCTAssertEqual(jobs.conversationId, "c1")

        jobs.finish(UUID())                                       // 别人的完成：不动
        XCTAssertTrue(jobs.isBusy)
        jobs.finish(a!)
        XCTAssertFalse(jobs.isBusy)
        XCTAssertNil(jobs.conversationId)

        let b = jobs.begin(conversationId: "c2")
        jobs.finish(a!)                                           // 上一条迟到的完成：不清掉新这条
        XCTAssertEqual(jobs.conversationId, "c2")
        jobs.finish(b!)
        XCTAssertFalse(jobs.isBusy)
    }
}
