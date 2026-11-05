import XCTest
@testable import 记忆花园

/// 被系统回收后回来跳开屏的判定（plan-bg-keepalive §2.1 / §4）：标记存在 scene session.userInfo，
/// 换 session（她划掉 app）就读不到；窗口内才跳；读一次就清。
final class LaunchResumeMarkerTests: XCTestCase {
    private let left = Date(timeIntervalSince1970: 1_800_000_000)

    func testNoMarkerDoesNotSkip() {
        XCTAssertFalse(LaunchResumeMarker.shouldSkipSplash(leftAt: nil, now: left))
        var info: [String: Any]? = nil
        XCTAssertFalse(LaunchResumeMarker.take(&info, now: left))
    }

    func testWithinWindowSkips() {
        XCTAssertTrue(LaunchResumeMarker.shouldSkipSplash(leftAt: left, now: left))
        XCTAssertTrue(LaunchResumeMarker.shouldSkipSplash(leftAt: left, now: left.addingTimeInterval(599)))
        XCTAssertTrue(LaunchResumeMarker.shouldSkipSplash(leftAt: left, now: left.addingTimeInterval(600)))
    }

    func testOutsideWindowPlays() {
        XCTAssertFalse(LaunchResumeMarker.shouldSkipSplash(leftAt: left, now: left.addingTimeInterval(601)))
        // 时钟往回拨：不认
        XCTAssertFalse(LaunchResumeMarker.shouldSkipSplash(leftAt: left, now: left.addingTimeInterval(-1)))
    }

    func testMarkerIsConsumedOnce() {
        var info: [String: Any]? = ["other": "keep"]
        LaunchResumeMarker.record(&info, at: left)
        XCTAssertTrue(LaunchResumeMarker.take(&info, now: left.addingTimeInterval(30)))
        XCTAssertFalse(LaunchResumeMarker.take(&info, now: left.addingTimeInterval(31)))
        XCTAssertNil(info?[LaunchResumeMarker.key])
        XCTAssertEqual(info?["other"] as? String, "keep")
    }

    func testStaleMarkerIsClearedToo() {
        var info: [String: Any]? = nil
        LaunchResumeMarker.record(&info, at: left)
        XCTAssertFalse(LaunchResumeMarker.take(&info, now: left.addingTimeInterval(3600)))
        XCTAssertNil(info?[LaunchResumeMarker.key])
    }

    func testDifferentSessionHasNoMarker() {
        var kept: [String: Any]? = nil
        LaunchResumeMarker.record(&kept, at: left)
        var fresh: [String: Any]? = nil
        XCTAssertFalse(LaunchResumeMarker.take(&fresh, now: left.addingTimeInterval(10)))
        XCTAssertTrue(LaunchResumeMarker.take(&kept, now: left.addingTimeInterval(10)))
    }
}

/// 冷启动恢复的进程级一次性状态（plan-bg-keepalive §2.2）：草稿字按对话 id 认领、挡板按 id 只吃一次
@MainActor
final class LastLocationResumeTests: XCTestCase {
    override func setUp() async throws {
        // 静态状态跨测试共享：先清干净
        _ = LastLocationResume.takeListPageHold(for: nil)
        LastLocationResume.putNewChatText("", for: "reset")
        _ = LastLocationResume.takeNewChatText(for: "reset")
    }

    func testNewChatTextOnlyForItsDraft() {
        LastLocationResume.putNewChatText("没发的字", for: "draft-a")
        XCTAssertNil(LastLocationResume.takeNewChatText(for: "draft-b"))
        XCTAssertNil(LastLocationResume.takeNewChatText(for: nil))
        XCTAssertEqual(LastLocationResume.takeNewChatText(for: "draft-a"), "没发的字")
        XCTAssertNil(LastLocationResume.takeNewChatText(for: "draft-a"))
    }

    func testListPageHoldMatchesOnce() {
        LastLocationResume.holdListPageOnce(for: "conv-a")
        XCTAssertTrue(LastLocationResume.takeListPageHold(for: "conv-a"))
        XCTAssertFalse(LastLocationResume.takeListPageHold(for: "conv-a"))
    }

    func testListPageHoldMismatchClears() {
        LastLocationResume.holdListPageOnce(for: "conv-a")
        XCTAssertFalse(LastLocationResume.takeListPageHold(for: "conv-b"))
        XCTAssertFalse(LastLocationResume.takeListPageHold(for: "conv-a"))
    }

    func testNoHoldNeverMatches() {
        XCTAssertFalse(LastLocationResume.takeListPageHold(for: nil))
        XCTAssertFalse(LastLocationResume.takeListPageHold(for: "conv-a"))
    }
}
