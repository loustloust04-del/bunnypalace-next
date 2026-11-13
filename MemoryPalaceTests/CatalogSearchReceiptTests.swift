import MemoryCore
import XCTest
@testable import 记忆花园

final class CatalogSearchReceiptTests: XCTestCase {
    private func hit(_ layer: CatalogALineReader.Layer, parts: [CatalogSearchPart], title: String = "云桥城") -> CatalogALineReader.Hit {
        CatalogALineReader.Hit(layer: layer, conversationId: "receipt-window", title: title,
                               start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 600),
                               day: "2026-10-01", segment: layer == .a2 ? 1 : nil,
                               messages: layer == .a2 ? 0..<10 : nil, parts: parts, old: nil)
    }

    func testQueryAndA4BodyCollisionDoesNotCountHeaderAfterClipping() throws {
        let body = "云桥城"
        let result = CatalogALineReader.Result(terms: [body], hits: [hit(.a4, parts: [.init(text: body, isBody: true)])], found: [.a4: 1])
        let receipt = result.receipt()
        let bodyStart = try XCTUnwrap(receipt.bodies.first?.range.lowerBound)
        let clipped = receipt.prefix(bodyStart)

        XCTAssertTrue(clipped.text.contains("「云桥城」"))
        XCTAssertTrue(clipped.text.contains("《云桥城》"))
        XCTAssertEqual(clipped.evidence().searchedChars, 0)
        XCTAssertEqual(receipt.evidence(visibleChars: bodyStart).searchedChars, 0)
        XCTAssertEqual(receipt.evidence().aline, [body])
        XCTAssertEqual(receipt.evidence().searchedChars, body.count)
    }

    func testTitleAndSectionLabelsAreNotBodyEvenWhenTheirTextMatches() throws {
        let title = "云桥城"
        let segment = SessionSegment(kind: .rolling, title: title, start: .distantPast, end: .distantPast,
                                     from: 0, to: 1, lastNodeId: nil, story: title, quotes: "【原话】", pending: "【待续】")
        var receipt = CatalogSearchReceipt(vectorStatus: "不可用")
        receipt.appendParts(CatalogALineReader.segmentParts(segment), kind: .aline)
        let firstStart = try XCTUnwrap(receipt.bodies.first?.range.lowerBound)
        XCTAssertEqual(receipt.prefix(firstStart).evidence().searchedChars, 0)
        let quoteStart = try XCTUnwrap(receipt.bodies.dropFirst().first?.range.lowerBound)
        XCTAssertEqual(receipt.prefix(quoteStart).evidence().aline, [title])
        XCTAssertEqual(receipt.evidence().aline, [title, "【原话】"], "段里的【待续】不给（c2c3-v2 第 7 段：待续只有待续本子一份）")
    }

    func testAppendReceiptShiftsRangesAndPrefixClipsByCharacter() {
        let family = "👨‍👩‍👧‍👦"
        var source = CatalogSearchReceipt(vectorStatus: "未检索")
        source.append("说明：")
        source.appendBody("\(family)甲乙", kind: .aline)
        source.append("\n碎片：")
        source.appendBody("🧑🏽‍🚀丙", kind: .fragment)
        var combined = CatalogSearchReceipt(vectorStatus: "向量命中 1 条")
        combined.append("查询\n")
        combined.appendReceipt(source)

        XCTAssertEqual(combined.bodies.first?.range, 6..<9)
        XCTAssertEqual(combined.bodies.last?.range, 13..<15)
        XCTAssertEqual(combined.prefix(8).text, "查询\n说明：\(family)甲")
        XCTAssertEqual(combined.prefix(8).evidence().aline, ["\(family)甲"])
        XCTAssertEqual(combined.prefix(14).evidence().fragments, ["🧑🏽‍🚀"])
        XCTAssertEqual(combined.evidence(visibleChars: 8), combined.prefix(8).evidence())
        XCTAssertEqual(combined.prefix(100).text, combined.text)
        XCTAssertEqual(combined.prefix(100).evidence(), combined.evidence())
        XCTAssertEqual(combined.prefix(0).text, "")
        XCTAssertEqual(combined.prefix(-1).evidence().searchedChars, 0)
        XCTAssertEqual(combined.evidence(visibleChars: -1).searchedChars, 0)
    }

    func testResultReceiptPreservesMixedLayerOrder() {
        let hits = [hit(.a2, parts: [.init(text: "先给A2", isBody: true)]),
                    hit(.a4, parts: [.init(text: "再给A4", isBody: true)]),
                    hit(.a3, parts: [.init(text: "最后A3", isBody: true)])]
        let result = CatalogALineReader.Result(terms: ["主题"], hits: hits, found: [.a2: 1, .a4: 1, .a3: 1])
        let receipt = result.receipt()
        XCTAssertEqual(receipt.evidence().aline, ["先给A2", "再给A4", "最后A3"])
    }

    func testMetadataOnlyAndEmptyBodyHaveZeroEvidence() {
        var receipt = CatalogSearchReceipt(vectorStatus: "不可用")
        receipt.appendParts([.init(text: "云桥城【经过】【原话】【待续】", isBody: false),
                             .init(text: "", isBody: true)], kind: .aline)
        receipt.appendBody("", kind: .fragment)
        XCTAssertEqual(receipt.bodies.count, 0)
        XCTAssertEqual(receipt.evidence().searchedChars, 0)
        XCTAssertEqual(CatalogALineReader.Result(terms: ["云桥城"], hits: [], found: [:]).receipt().evidence().searchedChars, 0)
    }
}
