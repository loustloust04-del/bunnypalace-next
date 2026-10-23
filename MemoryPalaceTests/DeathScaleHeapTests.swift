#if PERSONAL_APPS
import XCTest
import SwiftUI
@testable import 记忆花园

final class DeathScaleHeapTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func items(_ n: Int, weight: (Int) -> Int) -> [DeathScaleHeap.Item] {
        (0..<n).map { i in
            DeathScaleHeap.Item(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!,
                                weight: weight(i), createdAt: t0.addingTimeInterval(Double(i)))
        }
    }

    private func assertInsidePan(_ layout: DeathScaleHeap.Layout, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(layout.placements.count, count, "每枚都要摆上", file: file, line: line)
        XCTAssertEqual(Set(layout.placements.map(\.id)).count, count, "不重不漏", file: file, line: line)
        for p in layout.placements {
            XCTAssertLessThanOrEqual(abs(p.x) + p.size / 2, DeathScaleScene.panRadius, "横向出盘：\(p)", file: file, line: line)
            XCTAssertLessThanOrEqual(p.y, DeathScaleScene.rim + 3.2, "沉到盘底以下：\(p)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(p.y - p.size * 1.15, DeathScaleScene.rim - DeathScaleHeap.maxHeight - 40, "堆到链子上去了：\(p)", file: file, line: line)
            XCTAssertGreaterThan(p.size, 0, file: file, line: line)
        }
    }

    func testEmpty() {
        let layout = DeathScaleHeap.layout([])
        XCTAssertTrue(layout.placements.isEmpty)
        XCTAssertEqual(layout.scale, 1)
    }

    func testOneWeightFullSizeCentered() {
        let layout = DeathScaleHeap.layout(items(1) { _ in 5 })
        assertInsidePan(layout, count: 1)
        XCTAssertEqual(layout.scale, 1)
        XCTAssertEqual(layout.placements[0].size, DeathScaleHeap.size(5))
        XCTAssertLessThanOrEqual(abs(layout.placements[0].x), 1.01)
    }

    func testCountsStayInsidePan() {
        for n in [0, 1, 9, 40, 200] {
            for pattern in [{ (_: Int) in 1 }, { (_: Int) in 9 }, { (i: Int) in 1 + (i * 7) % 9 }] {
                assertInsidePan(DeathScaleHeap.layout(items(n, weight: pattern)), count: n)
            }
        }
    }

    func testScaleIsMonotonicAsWeightsAccumulate() {
        for w in [1, 5, 9] {
            var last = 1.0
            for n in 0...200 {
                let s = DeathScaleHeap.layout(items(n) { _ in w }).scale
                XCTAssertLessThanOrEqual(s, last + 1e-12, "第 \(n) 枚（分量 \(w)）缩放反弹：\(last) → \(s)")
                last = s
            }
        }
        let mixed = [1, 9, 40, 200].map { DeathScaleHeap.layout(items($0) { 1 + ($0 * 7) % 9 }).scale }
        XCTAssertEqual(mixed, mixed.sorted(by: >))
    }

    func testHeavierFirstThenOlder() {
        var list = items(3) { [2, 7, 2][$0] }
        list.swapAt(0, 2)
        let order = DeathScaleHeap.layout(list).placements.map(\.weight)
        XCTAssertEqual(order, [7, 2, 2], "重的压在底排")
    }

    func testDeterministic() {
        let list = items(40) { 1 + ($0 * 7) % 9 }
        XCTAssertEqual(DeathScaleHeap.layout(list), DeathScaleHeap.layout(list.reversed()))
    }
}

final class DeathScaleSpringTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testTargetLeansTowardHeavierSide() {
        XCTAssertEqual(DeathScaleSpring.target(die: 0, live: 0), 0)
        XCTAssertLessThan(DeathScaleSpring.target(die: 9, live: 2), 0, "想死那边重，梁左端下沉（负角）")
        XCTAssertGreaterThan(DeathScaleSpring.target(die: 2, live: 9), 0)
        XCTAssertGreaterThan(DeathScaleSpring.target(die: 500, live: 0), -21)
    }

    func testRetargetIsContinuousAndSettles() {
        let rest = DeathScaleSpring.resting(at: 0, date: t0)
        let moving = rest.retargeted(-15, at: t0)
        XCTAssertEqual(moving.angle(at: t0), 0, accuracy: 1e-9, "换目标那一刻角度不跳")
        XCTAssertEqual(moving.angularVelocity(at: t0), 0, accuracy: 1e-9)
        let later = t0.addingTimeInterval(0.4)
        let again = moving.retargeted(5, at: later)
        XCTAssertEqual(again.angle(at: later), moving.angle(at: later), accuracy: 1e-9)
        XCTAssertEqual(again.angularVelocity(at: later), moving.angularVelocity(at: later), accuracy: 1e-9)
        XCTAssertGreaterThan(moving.settleDate, t0)
        XCTAssertLessThan(moving.settleDate.timeIntervalSince(t0), 10)
        let settled = moving.settleDate.addingTimeInterval(0.01)
        XCTAssertEqual(moving.angle(at: settled), -15, accuracy: DeathScaleSpring.restThreshold)
    }

    func testRestingNeedsNoAnimation() {
        let rest = DeathScaleSpring.resting(at: -8, date: t0)
        XCTAssertEqual(rest.settleDate, t0)
        XCTAssertEqual(rest.angle(at: t0.addingTimeInterval(3)), -8)
    }

    func testDropLandsAndEnds() {
        let drop = DeathScaleDrop(id: UUID(), start: t0)
        XCTAssertEqual(drop.pose(at: t0)?.dy, -90)
        XCTAssertEqual(drop.pose(at: t0)?.opacity, 0)
        XCTAssertNil(drop.pose(at: drop.end))
        let mid = drop.pose(at: t0.addingTimeInterval(DeathScaleDrop.duration * 0.55))
        XCTAssertEqual(mid?.dy ?? 1, 0, accuracy: 1e-6)
    }
}

final class DeathScaleEngraverTests: XCTestCase {
    private func points(_ path: Path) -> [CGPoint] {
        var out: [CGPoint] = []
        path.forEach { el in
            switch el {
            case .move(let p), .line(let p): out.append(p)
            case .quadCurve(let p, _), .curve(let p, _, _): out.append(p)
            case .closeSubpath: break
            }
        }
        return out
    }

    func testWobbleIsDeterministicAndBounded() {
        let rect = Path(CGRect(x: 10, y: 10, width: 120, height: 80))
        let a = DeathScaleEngraver.wobble(rect, amplitude: 0.9, seed: 3)
        let b = DeathScaleEngraver.wobble(rect, amplitude: 0.9, seed: 3)
        XCTAssertEqual(points(a), points(b), "固定种子，每次一样")
        XCTAssertNotEqual(points(a), points(DeathScaleEngraver.wobble(rect, amplitude: 0.9, seed: 4)))
        let pts = points(a)
        XCTAssertGreaterThan(pts.count, 100, "细分过")
        var moved = 0.0
        for p in pts {
            let d = min(abs(p.x - 10), abs(p.x - 130), abs(p.y - 10), abs(p.y - 90))
            XCTAssertLessThanOrEqual(d, 0.9 + 1e-6, "抖动不超过幅度：\(p)")
            moved = max(moved, d)
        }
        XCTAssertGreaterThan(moved, 0.2, "真的抖了")
    }

    func testWobbleKeepsSubpathsClosed() {
        var closes = 0
        DeathScaleEngraver.wobble(Path(ellipseIn: CGRect(x: 0, y: 0, width: 40, height: 20))).forEach { if case .closeSubpath = $0 { closes += 1 } }
        XCTAssertEqual(closes, 1)
    }

    func testHatchFollowsTone() {
        let empty = DeathScaleEngraver.hatch(.init(box: (0, 0, 50, 50), angle: 0, gap: 2, tone: { _, _ in 0 }))
        XCTAssertTrue(empty.isEmpty, "全亮就不刻")
        let dark = DeathScaleEngraver.hatch(.init(box: (0, 0, 50, 50), angle: 30, gap: 2, tone: { _, _ in 0.8 }))
        XCTAssertFalse(dark.isEmpty)
        XCTAssertTrue(CGRect(x: -2, y: -2, width: 54, height: 54).contains(dark.boundingRect), "不出框")
    }

    func testStaticPlateBuilds() {
        let art = DeathScaleScene.staticArt
        XCTAssertGreaterThan(art.scene.ops.count, 50)
        XCTAssertGreaterThan(art.frame.ops.count, 5)
    }
}

final class DeathScaleTextTests: XCTestCase {
    func testParseRoundTripsFormat() {
        let d = Date(timeIntervalSince1970: 1_790_000_123)
        XCTAssertEqual(DeathScaleText.parse(DeathScaleTime.format(d)), d)
        XCTAssertEqual(DeathScaleText.parse("01.10.2026·21:05:09"), DeathScaleText.parse("01.10.2026 · 21:05:09"))
        XCTAssertNil(DeathScaleText.parse("hier soir"))
        XCTAssertNil(DeathScaleText.parse("32.10.2026 · 21:05:09"))
    }

    func testParseIsShanghaiTime() {
        XCTAssertEqual(DeathScaleText.parse("01.10.2026 · 08:00:00"), Date(timeIntervalSince1970: 1_790_812_800))
    }

    func testDuration() {
        XCTAssertEqual(DeathScaleText.duration(7), "7 s")
        XCTAssertEqual(DeathScaleText.duration(65), "1 min 05 s")
        XCTAssertEqual(DeathScaleText.duration(3_725), "1 h 02 min 05 s")
    }

    func testSpanSameDayWritesDateOnce() {
        XCTAssertEqual(DeathScaleText.span("01.10.2026 · 21:00:00 – 01.10.2026 · 22:30:05"), "01.10.2026 · 21:00:00 → 22:30:05")
        XCTAssertEqual(DeathScaleText.span("01.10.2026 · 23:00:00 – …"), "01.10.2026 · 23:00:00 → …")
    }

    func testLedgerIsFrench() {
        let e = DeathScale.LedgerEntry(at: Date(), kind: .weight, side: .die, from: "2", to: "5", text: "la fatigue", sumDie: 5, sumLive: 0)
        XCTAssertEqual(DeathScaleText.ledger(e).map(\.text).joined(), "« la fatigue » II → V")
        XCTAssertEqual(DeathScaleText.symbol(e), "†")
    }
}
#endif
