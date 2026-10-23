import XCTest
@testable import 记忆花园

/// T6c ②：发送键 = 停止键的防连点闸。
/// 背景见 `ComposerStopGuard` 注释与 t6b-report §2（「（已停止）」的唯一来源就是这次点击）。
final class ComposerStopGuardTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 发送后 500ms 内的第二下：忽略
    func testSecondTapWithinWindowIsIgnored() {
        XCTAssertTrue(ComposerStopGuard.shouldIgnoreStopTap(sentAt: t0, now: t0))
        XCTAssertTrue(ComposerStopGuard.shouldIgnoreStopTap(sentAt: t0, now: t0.addingTimeInterval(0.05)))
        XCTAssertTrue(ComposerStopGuard.shouldIgnoreStopTap(sentAt: t0, now: t0.addingTimeInterval(0.499)))
    }

    /// 窗口过后行为一点不变：stop 就是 stop
    func testTapAfterWindowStops() {
        XCTAssertFalse(ComposerStopGuard.shouldIgnoreStopTap(sentAt: t0, now: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(ComposerStopGuard.shouldIgnoreStopTap(sentAt: t0, now: t0.addingTimeInterval(3)))
        XCTAssertFalse(ComposerStopGuard.shouldIgnoreStopTap(sentAt: t0, now: t0.addingTimeInterval(600)))
    }

    /// 不是自己发起的这轮（重新生成 / 进来时就在跑）：一下都不拦
    func testNoSendMeansNoGuard() {
        XCTAssertFalse(ComposerStopGuard.shouldIgnoreStopTap(sentAt: nil, now: t0))
    }

    /// 时钟往回跳（用户改系统时间）：当作窗口内——宁可漏一次 stop，也别误取消整轮
    func testClockGoingBackwardsIsTreatedAsInsideWindow() {
        XCTAssertTrue(ComposerStopGuard.shouldIgnoreStopTap(sentAt: t0, now: t0.addingTimeInterval(-30)))
    }
}
