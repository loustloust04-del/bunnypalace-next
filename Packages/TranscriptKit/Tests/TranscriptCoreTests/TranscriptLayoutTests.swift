import CoreGraphics
import XCTest
@testable import TranscriptCore

final class PrefixSumsTests: XCTestCase {
    func testSumsAndLookupMatchNaive() {
        var generator = SeededGenerator(seed: 7)
        for count in [0, 1, 2, 3, 7, 8, 9, 64, 257] {
            var values = (0..<count).map { _ in CGFloat(Int.random(in: 0...40, using: &generator)) }
            var sums = PrefixSums(values)
            for _ in 0..<(count * 3) {
                let index = Int.random(in: 0..<count, using: &generator)
                values[index] = CGFloat(Int.random(in: 0...40, using: &generator))
                sums.set(index, values[index])
            }
            XCTAssertEqual(sums.total, values.reduce(0, +))
            for index in 0...count {
                XCTAssertEqual(sums.sum(upTo: index), values.prefix(index).reduce(0, +), "count \(count) index \(index)")
            }
            let total = values.reduce(0, +)
            for offset in stride(from: CGFloat(-1), through: total + 1, by: 0.5) {
                var expected = 0
                var running: CGFloat = 0
                while expected < count, running + values[expected] <= max(offset, 0) {
                    running += values[expected]
                    expected += 1
                }
                XCTAssertEqual(sums.index(containing: offset), expected, "count \(count) offset \(offset)")
            }
        }
    }
}

final class HeightTableTests: XCTestCase {
    func testUnknownRowUsesEstimate() {
        let table = HeightTable()
        XCTAssertEqual(table.resolve(id: "a", version: 0, width: 300, estimate: 44),
                       .init(height: 44, tier: .estimated, stale: false))
    }

    func testLowerTierDoesNotOverwriteHigherForSameKey() {
        var table = HeightTable()
        XCTAssertTrue(table.store(100, tier: .measured, id: "a", version: 1, width: 300))
        XCTAssertFalse(table.store(90, tier: .prepared, id: "a", version: 1, width: 300))
        XCTAssertEqual(table.resolve(id: "a", version: 1, width: 300, estimate: 44).height, 100)
        XCTAssertTrue(table.store(104, tier: .measured, id: "a", version: 1, width: 300))
    }

    func testStaleHeightSurvivesVersionAndWidthChange() {
        var table = HeightTable()
        table.store(100, tier: .measured, id: "a", version: 1, width: 300)
        XCTAssertEqual(table.resolve(id: "a", version: 2, width: 300, estimate: 44),
                       .init(height: 100, tier: .estimated, stale: true), "内容变了：旧高度当估算用，不塌回 44")
        XCTAssertEqual(table.resolve(id: "a", version: 1, width: 320, estimate: 44).stale, true)
        XCTAssertTrue(table.store(120, tier: .prepared, id: "a", version: 2, width: 300), "新键的低档可以顶掉旧键的高档")
        XCTAssertEqual(table.resolve(id: "a", version: 2, width: 300, estimate: 44),
                       .init(height: 120, tier: .prepared, stale: false))
    }

    func testStoreReportsWhetherResolvedHeightChanged() {
        var table = HeightTable()
        table.store(100, tier: .prepared, id: "a", version: 1, width: 300)
        XCTAssertFalse(table.store(100, tier: .measured, id: "a", version: 1, width: 300), "升档但高度没变")
        XCTAssertFalse(table.store(100, tier: .measured, id: "a", version: 2, width: 300), "换键但高度没变")
        XCTAssertFalse(table.store(0, tier: .measured, id: "a", version: 2, width: 300), "0 高度不收")
    }

    func testPrune() {
        var table = HeightTable()
        table.store(10, tier: .measured, id: "a", version: 0, width: 1)
        table.store(20, tier: .measured, id: "b", version: 0, width: 1)
        table.prune(retaining: ["b"])
        XCTAssertEqual(table.resolve(id: "a", version: 0, width: 1, estimate: 5).height, 5)
        XCTAssertEqual(table.resolve(id: "b", version: 0, width: 1, estimate: 5).height, 20)
    }
}

final class TranscriptLayoutTests: XCTestCase {
    private func row(_ id: String, gap: CGFloat = 0, estimate: CGFloat = 40, version: Int = 0) -> TranscriptLayout.Row {
        .init(id: id, version: version, gapBefore: gap, estimatedHeight: estimate)
    }

    func testFramesStackFromStartWithPadAndGaps() {
        var layout = TranscriptLayout(width: 300)
        layout.setRows([row("new", gap: 99), row("mid", gap: 8), row("old", gap: 12)])
        layout.setLeadingPad(30)

        XCTAssertEqual(layout.frame(of: "new"), .init(minY: 30, height: 40), "第一行的行前间距不算")
        XCTAssertEqual(layout.frame(of: "mid"), .init(minY: 78, height: 40))
        XCTAssertEqual(layout.frame(of: "old"), .init(minY: 130, height: 40))
        XCTAssertEqual(layout.contentLength, 170)
        XCTAssertNil(layout.frame(of: "missing"))
    }

    func testMeasuredHeightMovesLaterRowsOnly() {
        var layout = TranscriptLayout(width: 300)
        layout.setRows([row("a"), row("b", gap: 10), row("c", gap: 10)])

        XCTAssertTrue(layout.setHeight(100, tier: .measured, id: "b", version: 0))
        XCTAssertEqual(layout.frame(of: "a"), .init(minY: 0, height: 40))
        XCTAssertEqual(layout.frame(of: "b"), .init(minY: 50, height: 100))
        XCTAssertEqual(layout.frame(of: "c"), .init(minY: 160, height: 40))
        XCTAssertFalse(layout.setHeight(100, tier: .measured, id: "b", version: 0), "同一个高度再报一次不算变")
    }

    func testHeightForRowNotInListIsKeptForLater() {
        var layout = TranscriptLayout(width: 300)
        layout.setRows([row("a")])
        XCTAssertFalse(layout.setHeight(77, tier: .measured, id: "b", version: 0))
        layout.setRows([row("a"), row("b")])
        XCTAssertEqual(layout.frame(of: "b")?.height, 77)
    }

    func testVersionBumpKeepsOldHeightUntilRemeasured() {
        var layout = TranscriptLayout(width: 300)
        layout.setRows([row("a", estimate: 40)])
        layout.setHeight(200, tier: .measured, id: "a", version: 0)

        layout.setRows([row("a", estimate: 40, version: 1)])
        XCTAssertEqual(layout.height(at: 0), .init(height: 200, tier: .estimated, stale: true))
        XCTAssertTrue(layout.setHeight(230, tier: .measured, id: "a", version: 1))
        XCTAssertEqual(layout.height(at: 0), .init(height: 230, tier: .measured, stale: false))
    }

    func testWidthChangeKeepsStaleHeights() {
        var layout = TranscriptLayout(width: 300)
        layout.setRows([row("a"), row("b")])
        layout.setHeight(90, tier: .measured, id: "a", version: 0)
        layout.setWidth(400)
        XCTAssertEqual(layout.frame(of: "b"), .init(minY: 90, height: 40))
        XCTAssertTrue(layout.height(at: 0).stale)
    }

    func testIndicesIntersecting() {
        var layout = TranscriptLayout(width: 300)
        layout.setRows([row("a"), row("b", gap: 10), row("c", gap: 10)])   // a 0–40，b 50–90，c 100–140
        layout.setLeadingPad(0)

        XCTAssertEqual(layout.indices(intersecting: 0, 140), 0..<3)
        XCTAssertEqual(layout.indices(intersecting: 45, 95), 1..<2, "两头都落在行间距里")
        XCTAssertEqual(layout.indices(intersecting: 41, 49), 1..<1, "整段在行间距里：没有行")
        XCTAssertEqual(layout.indices(intersecting: 39, 51), 0..<2)
        XCTAssertEqual(layout.indices(intersecting: -50, -1), 0..<0)
        XCTAssertEqual(layout.indices(intersecting: 200, 300), 3..<3)
        XCTAssertEqual(layout.indices(intersecting: 120, 999), 2..<3)
    }

    func testMatchesNaiveLayoutUnderRandomEdits() {
        var generator = SeededGenerator(seed: 42)
        var layout = TranscriptLayout(width: 300)
        var rows = (0..<200).map { row("r\($0)", gap: CGFloat(Int.random(in: 0...16, using: &generator)), estimate: 44) }
        var known: [String: CGFloat] = [:]
        layout.setRows(rows)
        layout.setLeadingPad(25)

        for step in 0..<400 {
            switch Int.random(in: 0..<10, using: &generator) {
            case 0:
                rows.insert(row("n\(step)", gap: 6, estimate: 44), at: 0)
                layout.setRows(rows)
            case 1 where rows.count > 1:
                rows.remove(at: Int.random(in: 0..<rows.count, using: &generator))
                layout.setRows(rows)
            default:
                let target = rows[Int.random(in: 0..<rows.count, using: &generator)]
                let height = CGFloat(Int.random(in: 20...400, using: &generator))
                known[target.id] = height
                layout.setHeight(height, tier: .measured, id: target.id, version: 0)
            }
        }

        var y: CGFloat = 25
        for (index, row) in rows.enumerated() {
            if index > 0 { y += row.gapBefore }
            let height = known[row.id] ?? 44
            XCTAssertEqual(layout.frame(at: index), .init(minY: y, height: height), "行 \(index)")
            y += height
        }
        XCTAssertEqual(layout.contentLength, y)
    }
}

/// 固定种子的随机数（SplitMix64）：随机测试每次跑同一串
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
