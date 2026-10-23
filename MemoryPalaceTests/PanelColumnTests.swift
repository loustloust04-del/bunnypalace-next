import XCTest
@testable import 记忆花园

/// 列内分配 / 拖缝 / 两种落点分区（plan-panel-ps 阶段 2b 的纯函数）
final class PanelColumnTests: XCTestCase {
    typealias Item = PanelColumnLayout.Item
    let bar: CGFloat = 40, seam: CGFloat = 6, minBody: CGFloat = 80

    private func check(_ r: PanelColumnLayout.Result, total: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let sum = r.sizes.reduce(0, +) + r.seam * CGFloat(max(0, r.sizes.count - 1)) + r.remainder
        XCTAssertEqual(sum, max(0, total), accuracy: 0.001, "恒等式", file: file, line: line)
        XCTAssertTrue(r.sizes.allSatisfy { $0 >= 0 } && r.remainder >= 0 && r.seam >= 0, "非负", file: file, line: line)
    }

    func testSingleGroupFillsColumn() {
        let r = PanelColumnLayout.extents(total: 568, items: [Item(weight: 1, collapsed: false)], bar: bar, seam: seam, minBody: minBody)
        XCTAssertEqual(r.sizes, [568])
        check(r, total: 568)
    }

    func testWeightsSplitProportionally() {
        let r = PanelColumnLayout.extents(total: 606, items: [Item(weight: 1, collapsed: false), Item(weight: 2, collapsed: false)],
                                          bar: bar, seam: seam, minBody: minBody)
        XCTAssertEqual(r.sizes[0], 200, accuracy: 0.001)
        XCTAssertEqual(r.sizes[1], 400, accuracy: 0.001)
        check(r, total: 606)
    }

    func testCollapsedIsBarAndRestGoesToExpanded() {
        let r = PanelColumnLayout.extents(total: 568, items: [Item(weight: 1, collapsed: true), Item(weight: 1, collapsed: false)],
                                          bar: bar, seam: seam, minBody: minBody)
        XCTAssertEqual(r.sizes, [40, 522])
        check(r, total: 568)
    }

    /// A B5 反例：三个全折叠——多出的给 remainder，不硬塞
    func testAllCollapsedLeavesRemainder() {
        let items = Array(repeating: Item(weight: 1, collapsed: true), count: 3)
        let r = PanelColumnLayout.extents(total: 568, items: items, bar: bar, seam: seam, minBody: minBody)
        XCTAssertEqual(r.sizes, [40, 40, 40])
        XCTAssertEqual(r.remainder, 568 - 132)
        check(r, total: 568)
    }

    /// 小权重的组钉在下限，其余按比例分剩下的
    func testFloorPinsTinyWeight() {
        let r = PanelColumnLayout.extents(total: 606, items: [Item(weight: 0.01, collapsed: false), Item(weight: 1, collapsed: false)],
                                          bar: bar, seam: seam, minBody: minBody)
        XCTAssertEqual(r.sizes[0], 120)
        XCTAssertEqual(r.sizes[1], 480)
        check(r, total: 606)
    }

    /// A B5 反例：放宽上限后 5 个展开组放不进 568 → 压正文，不低于 tab 栏
    func testOverflowCompressesBodies() {
        let items = Array(repeating: Item(weight: 1, collapsed: false), count: 5)
        let r = PanelColumnLayout.extents(total: 568, items: items, bar: bar, seam: seam, minBody: minBody)
        XCTAssertTrue(r.sizes.allSatisfy { $0 >= 40 && $0 < 120 })
        XCTAssertEqual(r.remainder, 0)
        check(r, total: 568)
    }

    /// 连 tab 栏都放不下：平均分
    func testExtremelySmallTotal() {
        let items = Array(repeating: Item(weight: 1, collapsed: false), count: 4)
        let r = PanelColumnLayout.extents(total: 100, items: items, bar: bar, seam: seam, minBody: minBody)
        check(r, total: 100)
        XCTAssertEqual(r.sizes[0], r.sizes[3], accuracy: 0.001)
    }

    func testZeroAndNegativeTotal() {
        for t in [0, -50, CGFloat.nan] as [CGFloat] {
            let r = PanelColumnLayout.extents(total: t, items: [Item(weight: 1, collapsed: false), Item(weight: 1, collapsed: true)],
                                              bar: bar, seam: seam, minBody: minBody)
            XCTAssertEqual(r.sizes, [0, 0])
            XCTAssertEqual(r.remainder, 0)
        }
    }

    func testBadWeightsTreatedAsOne() {
        let r = PanelColumnLayout.extents(total: 406, items: [Item(weight: -3, collapsed: false), Item(weight: .infinity, collapsed: false)],
                                          bar: bar, seam: seam, minBody: minBody)
        XCTAssertEqual(r.sizes[0], 200, accuracy: 0.001)
        XCTAssertEqual(r.sizes[1], 200, accuracy: 0.001)
    }

    /// 扫描：1…6 组、任意折叠组合、总量 0…900，恒等式和非负都成立
    func testSweepInvariants() {
        for n in 1...6 {
            for mask in 0..<(1 << n) {
                let items = (0..<n).map { Item(weight: CGFloat($0 % 3 + 1), collapsed: mask & (1 << $0) != 0) }
                for total in stride(from: 0.0, through: 900.0, by: 37.0) {
                    check(PanelColumnLayout.extents(total: total, items: items, bar: bar, seam: seam, minBody: minBody), total: total)
                }
            }
        }
    }

    /// 底列横排：折叠组用自己的宽
    func testHorizontalCollapsedSize() {
        let r = PanelColumnLayout.extents(total: 700, items: [Item(weight: 1, collapsed: true), Item(weight: 1, collapsed: false)],
                                          bar: bar, seam: seam, minBody: 200, collapsedSize: 120)
        XCTAssertEqual(r.sizes, [120, 574])
    }

    /// 没记过权重的新组按这一列已记权重的均值算（09-24 实拍：旧点数权重 305 对新组缺省 1，新组被挤成 120）
    func testMissingWeightUsesColumnMean() {
        XCTAssertEqual(PanelColumnLayout.weights([305.8, nil]), [305.8, 305.8])
        XCTAssertEqual(PanelColumnLayout.weights([nil, nil]), [1, 1])
        XCTAssertEqual(PanelColumnLayout.weights([2, 4, nil, -1]), [2, 4, 3, 3])
        let w = PanelColumnLayout.weights([305.8, nil])
        let r = PanelColumnLayout.extents(total: 855, items: w.map { .init(weight: $0, collapsed: false) },
                                          bar: bar, seam: seam, minBody: minBody)
        XCTAssertEqual(r.sizes[0], r.sizes[1], accuracy: 0.001, "新组对半分，不是被挤到下限")
    }

    // MARK: 拖缝

    func testDragSeamKeepsPairSumAndFloors() {
        let out = PanelColumnLayout.dragSeam(sizes: [200, 300, 100], at: 0, delta: 50, floor: 120)
        XCTAssertEqual(out, [250, 250, 100])
        XCTAssertEqual(PanelColumnLayout.dragSeam(sizes: [200, 300], at: 0, delta: 500, floor: 120), [380, 120])
        XCTAssertEqual(PanelColumnLayout.dragSeam(sizes: [200, 300], at: 0, delta: -500, floor: 120), [120, 380])
        XCTAssertEqual(PanelColumnLayout.dragSeam(sizes: [100, 100], at: 0, delta: 10, floor: 120), [100, 100], "放不下两个下限就不动")
        XCTAssertEqual(PanelColumnLayout.dragSeam(sizes: [200], at: 0, delta: 10, floor: 120), [200])
    }

    // MARK: 落点分区

    func testGroupBodyBands() {
        XCTAssertEqual(GroupBodyDrop.resolve(position: 10, extent: 400), .before)
        XCTAssertEqual(GroupBodyDrop.resolve(position: 100, extent: 400), .merge, "恰 25% 归并入")
        XCTAssertEqual(GroupBodyDrop.resolve(position: 200, extent: 400), .merge)
        XCTAssertEqual(GroupBodyDrop.resolve(position: 300, extent: 400), .merge, "恰 75% 归并入")
        XCTAssertEqual(GroupBodyDrop.resolve(position: 390, extent: 400), .after)
        XCTAssertEqual(GroupBodyDrop.resolve(position: 0, extent: 0), .merge, "折叠组只能并入")
    }

    func testCardZones() {
        let size = CGSize(width: 600, height: 500)
        XCTAssertEqual(CardDropZone.resolve(CGPoint(x: 10, y: 250), in: size, bottomEnabled: false), .left)
        XCTAssertEqual(CardDropZone.resolve(CGPoint(x: 590, y: 250), in: size, bottomEnabled: false), .right)
        XCTAssertEqual(CardDropZone.resolve(CGPoint(x: 300, y: 250), in: size, bottomEnabled: false), .float)
        XCTAssertEqual(CardDropZone.resolve(CGPoint(x: 300, y: 480), in: size, bottomEnabled: false), .float, "底沿没开")
        XCTAssertEqual(CardDropZone.resolve(CGPoint(x: 300, y: 480), in: size, bottomEnabled: true), .bottom)
        XCTAssertEqual(CardDropZone.resolve(CGPoint(x: 10, y: 480), in: size, bottomEnabled: true), .bottom, "角上底沿优先")
        XCTAssertEqual(CardDropZone.resolve(CGPoint(x: 48, y: 250), in: size, bottomEnabled: false), .float, "恰 48 不算沿")
        XCTAssertEqual(CardDropZone.resolve(.zero, in: .zero, bottomEnabled: true), .float)
    }
}
