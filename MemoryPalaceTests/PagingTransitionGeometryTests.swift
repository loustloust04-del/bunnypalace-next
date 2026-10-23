import XCTest
@testable import 记忆花园

/// A-deck 转场姿态表逐 q 断言（plan-paging-decouple §1.2）
final class PagingTransitionGeometryTests: XCTestCase {
    private let w: CGFloat = 400
    private func pose(_ page: Int, _ q: CGFloat) -> PagingTransitionGeometry.DeckPose {
        PagingTransitionGeometry.deck(page: page, position: q, width: w, pageCount: 3)
    }
    private func top(_ q: CGFloat) -> Int { (0..<3).max { pose($0, q).rank < pose($1, q).rank }! }

    func testDockedPagesAllAtOriginCurrentOnTop() {
        for page in 0..<3 {
            let q = CGFloat(page)
            for i in 0..<3 {
                XCTAssertEqual(pose(i, q).tx, 0, "停靠 q=\(page) 页 \(i) 平移归 0")
                XCTAssertEqual(pose(i, q).dimOpacity, 0)
            }
            XCTAssertEqual(top(q), page, "停靠 q=\(page) 当前页最上")
        }
        // 停聊天页：聊天 > 列表 > page2
        XCTAssertGreaterThan(pose(1, 1).rank, pose(0, 1).rank)
        XCTAssertGreaterThan(pose(0, 1).rank, pose(2, 1).rank)
        // 停 page2：page2 > 聊天 > 列表
        XCTAssertGreaterThan(pose(2, 2).rank, pose(1, 2).rank)
        XCTAssertGreaterThan(pose(1, 2).rank, pose(0, 2).rank)
    }

    func testZeroToOneChatSlidesOverStaticList() {
        for q in stride(from: CGFloat(0.05), to: 1, by: 0.1) {
            XCTAssertEqual(top(q), 1, "0↔1 途中主角是聊天页")
            XCTAssertEqual(pose(1, q).tx, w * (1 - q), accuracy: 0.001)
            XCTAssertEqual(pose(0, q).tx, 0, "列表静止在 x=0")
            XCTAssertEqual(pose(0, q).dimOpacity, 0.46 * q, accuracy: 0.001)
            XCTAssertGreaterThan(pose(0, q).rank, pose(2, q).rank, "聊天 > 列表 > page2")
        }
    }

    func testOneToTwoPage2SlidesOverStaticChat() {
        for q in stride(from: CGFloat(1.05), to: 2, by: 0.1) {
            let p = q - 1
            XCTAssertEqual(top(q), 2, "1↔2 途中主角是 page2")
            XCTAssertEqual(pose(2, q).tx, w * (1 - p), accuracy: 0.001)
            XCTAssertEqual(pose(1, q).tx, 0, "聊天静止在 x=0")
            XCTAssertEqual(pose(1, q).dimOpacity, 0.46 * p, accuracy: 0.001)
            XCTAssertGreaterThan(pose(1, q).rank, pose(0, q).rank, "page2 > 聊天 > 列表")
        }
    }

    func testCrossingIntegerSwapsActorContinuously() {
        // 反向越过 q=1（0↔2 连续 q 同理）：两侧的主角在 q=1 附近都退到「平移归 0 / 屏外」，画面不跳
        let below = 1 - CGFloat(0.0005), above = 1 + CGFloat(0.0005)
        XCTAssertEqual(pose(1, below).tx, 0, accuracy: 0.5, "q→1⁻：聊天页已到位")
        XCTAssertEqual(top(below), 1)
        XCTAssertEqual(pose(2, above).tx, w, accuracy: 0.5, "q→1⁺：page2 还在屏外")
        XCTAssertEqual(top(above), 2)
        XCTAssertEqual(pose(1, above).tx, 0, "越过后聊天页成静止页，仍在 x=0")
    }

    func testClampsOutOfRange() {
        XCTAssertEqual(top(-0.3), 0)
        XCTAssertEqual(top(2.4), 2)
        for i in 0..<3 { XCTAssertEqual(pose(i, 2.4).tx, 0) }
    }

    func testActorOnlyMidTransition() {
        XCTAssertNil(PagingTransitionGeometry.deckActor(position: 1, pageCount: 3))
        XCTAssertEqual(PagingTransitionGeometry.deckActor(position: 0.3, pageCount: 3), 1)
        XCTAssertEqual(PagingTransitionGeometry.deckActor(position: 1.7, pageCount: 3), 2)
        XCTAssertNil(PagingTransitionGeometry.deckActor(position: 2, pageCount: 3))
    }
}
