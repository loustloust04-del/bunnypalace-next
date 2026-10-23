import XCTest
@testable import 记忆花园

/// 「复习」模块调度内核：SM-2 三档评分推进 + 题型阶梯 + 到期计算。
final class SM2Tests: XCTestCase {
    let fresh = SM2State(ease: 2.5, intervalDays: 0, reps: 0, lapses: 0)

    func testGoodProgression() {
        let r1 = SM2.review(fresh, rating: .good)
        XCTAssertEqual(r1.intervalDays, 1)
        XCTAssertEqual(r1.reps, 1)
        let r2 = SM2.review(r1, rating: .good)
        XCTAssertEqual(r2.intervalDays, 3)
        XCTAssertEqual(r2.reps, 2)
        let r3 = SM2.review(r2, rating: .good)
        XCTAssertEqual(r3.intervalDays, 3 * 2.5, accuracy: 0.01, "第三次起 ×ease")
    }

    func testHardSlowsAndDropsEase() {
        let s = SM2State(ease: 2.5, intervalDays: 10, reps: 3, lapses: 0)
        let r = SM2.review(s, rating: .hard)
        XCTAssertEqual(r.intervalDays, 12, accuracy: 0.01)
        XCTAssertEqual(r.ease, 2.35, accuracy: 0.01)
        XCTAssertEqual(r.reps, 4)
    }

    func testAgainResetsToRelearn() {
        let s = SM2State(ease: 2.0, intervalDays: 30, reps: 5, lapses: 1)
        let r = SM2.review(s, rating: .again)
        XCTAssertEqual(r.intervalDays, 1)
        XCTAssertEqual(r.reps, 0, "遗忘 → 回认读重学")
        XCTAssertEqual(r.lapses, 2)
        XCTAssertEqual(r.ease, 1.8, accuracy: 0.01)
    }

    func testEaseFloor() {
        let s = SM2State(ease: 1.35, intervalDays: 5, reps: 2, lapses: 3)
        XCTAssertEqual(SM2.review(s, rating: .again).ease, 1.3, "ease 下限 1.3")
    }

    func testExerciseLadder() {
        XCTAssertEqual(SM2.exercise(reps: 0, intervalDays: 0), .read)
        XCTAssertEqual(SM2.exercise(reps: 1, intervalDays: 1), .read)
        XCTAssertEqual(SM2.exercise(reps: 2, intervalDays: 3), .spell)
        XCTAssertEqual(SM2.exercise(reps: 4, intervalDays: 7), .sentence)
    }

    func testNextDue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = SM2State(ease: 2.5, intervalDays: 3, reps: 2, lapses: 0)
        XCTAssertEqual(SM2.nextDue(after: s, from: now),
                       now.addingTimeInterval(3 * 86_400))
    }
}
