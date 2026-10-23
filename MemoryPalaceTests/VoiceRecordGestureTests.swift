import XCTest
@testable import 记忆花园

/// 按住录语音的手势判定矩阵（plan-voice-note M5a，数值照 docs/design-voice-record.html）
final class VoiceRecordGestureTests: XCTestCase {
    private func up(_ dx: CGFloat = 0, _ dy: CGFloat = 0, vx: CGFloat = 0, vy: CGFloat = 0,
                    dur: TimeInterval? = 2) -> VoiceRecordGesture.Outcome {
        VoiceRecordGesture.decide(.up(dx: dx, dy: dy, vx: vx, vy: vy, recordedDuration: dur))
    }

    func testDebounce() {
        XCTAssertEqual(VoiceRecordGesture.decide(.down(sinceLastTouchEnd: 0.39)), .ignore)
        XCTAssertEqual(VoiceRecordGesture.decide(.down(sinceLastTouchEnd: 0.4)), .arm)
        XCTAssertEqual(VoiceRecordGesture.decide(.down(sinceLastTouchEnd: .infinity)), .arm)
    }

    func testReleaseBeforeRecordingIsTap() {
        XCTAssertEqual(up(dur: nil), .tap)
        XCTAssertEqual(up(-200, -200, dur: nil), .tap)
    }

    func testDragBeforeRecordingDoesNothing() {
        XCTAssertEqual(VoiceRecordGesture.decide(.move(dx: -300, dy: -300, recording: false)), .track)
    }

    func testDragThresholds() {
        XCTAssertEqual(VoiceRecordGesture.decide(.move(dx: -150, dy: 0, recording: true)), .track)
        XCTAssertEqual(VoiceRecordGesture.decide(.move(dx: -151, dy: 0, recording: true)), .cancel)
        XCTAssertEqual(VoiceRecordGesture.decide(.move(dx: 0, dy: -110, recording: true)), .track)
        XCTAssertEqual(VoiceRecordGesture.decide(.move(dx: 0, dy: -111, recording: true)), .lock)
        // 只认左、上：往右 / 往下拖多远都不触发
        XCTAssertEqual(VoiceRecordGesture.decide(.move(dx: 400, dy: 400, recording: true)), .track)
        // 两个都过线：取消优先（小样先判取消）
        XCTAssertEqual(VoiceRecordGesture.decide(.move(dx: -160, dy: -120, recording: true)), .cancel)
    }

    func testReleaseDistanceThresholds() {
        XCTAssertEqual(up(-100, 0), .send)
        XCTAssertEqual(up(-101, 0), .cancel)
        XCTAssertEqual(up(0, -60), .send)
        XCTAssertEqual(up(0, -61), .lock)
        XCTAssertEqual(up(30, 40), .send)
    }

    func testReleaseDominantAxisWins() {
        // 左拖更多：上拖记 0，左拖没过 -100 → 发送（不因 dy=-70 锁定）
        XCTAssertEqual(up(-90, -70), .send)
        // 上拖更多：左拖记 0，上拖过 -60 → 锁定
        XCTAssertEqual(up(-80, -90), .lock)
        XCTAssertEqual(up(-120, -110), .cancel)
    }

    func testReleaseFling() {
        XCTAssertEqual(up(-10, 0, vx: -401), .cancel)
        XCTAssertEqual(up(0, -10, vy: -401), .lock)
        XCTAssertEqual(up(0, 0, vx: -400, vy: -400), .send)
        // 速度取消优先于锁定
        XCTAssertEqual(up(0, 0, vx: -500, vy: -500), .cancel)
    }

    func testTooShort() {
        XCTAssertEqual(up(dur: 0.49), .tooShort)
        XCTAssertEqual(up(dur: 0.5), .send)
        // 太短但拖去取消 / 锁定：照取消 / 锁定
        XCTAssertEqual(up(-120, 0, dur: 0.2), .cancel)
        XCTAssertEqual(up(0, -80, dur: 0.2), .lock)
    }

    func testHintFollowsHalfSpeedAfterDeadZone() {
        XCTAssertEqual(VoiceRecordGesture.hintOffset(dx: -8), 0)
        XCTAssertEqual(VoiceRecordGesture.hintOffset(dx: -28), -10)
        XCTAssertEqual(VoiceRecordGesture.hintOffset(dx: 30), 0)
        XCTAssertEqual(VoiceRecordGesture.hintOpacity(dx: -50), 1)
        XCTAssertEqual(VoiceRecordGesture.hintOpacity(dx: -120), 0)
        XCTAssertEqual(VoiceRecordGesture.hintOpacity(dx: -85), 0.5, accuracy: 1e-9)
    }

    func testLocknessAndScale() {
        XCTAssertEqual(VoiceRecordGesture.lockness(dy: 0), 0)
        XCTAssertEqual(VoiceRecordGesture.lockness(dy: -52.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(VoiceRecordGesture.lockness(dy: -200), 1)
        XCTAssertEqual(VoiceRecordGesture.bigButtonScale(dx: 0), 1)
        XCTAssertEqual(VoiceRecordGesture.bigButtonScale(dx: -150), 0.5, accuracy: 1e-9)
        XCTAssertEqual(VoiceRecordGesture.bigButtonScale(dx: -600), 0.4)
    }
}
