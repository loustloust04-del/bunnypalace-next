import XCTest
@testable import 记忆花园

final class ContextLensTests: XCTestCase {
    private func seg(_ source: SegmentSource, _ text: String) -> TaggedSegment {
        TaggedSegment(source: source, role: "system", template: text, content: text)
    }

    func testGroupsSegmentsBySourceInFixedOrder() {
        let rows = ContextLens.rows(segments: [
            seg(.memory, "记得一件事"),
            seg(.slot(id: "a", name: "人设"), "你是谁"),
            seg(.chatHistory, "hello"),
            seg(.slot(id: "b", name: "规则"), "别这样"),
            seg(.userProfile, "画像"),
            seg(.style, "<style>x</style>"),
            seg(.worldBook(entryName: "城"), "一座城"),
        ], tools: nil, tuckedTools: [])

        XCTAssertEqual(rows.map(\.id), ["history", "slots", "worldBook", "memory", "other"])
        XCTAssertEqual(rows[1].items.map(\.title), ["人设", "规则"])
        XCTAssertEqual(rows[1].countText, "2 段")
        XCTAssertEqual(rows[2].items.map(\.title), ["城"])
        XCTAssertEqual(rows[3].items.count, 2)
        XCTAssertTrue(rows[0].items.isEmpty, "对话历史不逐条列")
        XCTAssertEqual(rows[0].tokens, TokenEstimator.estimate("hello"))
        XCTAssertEqual(rows[1].tokens, rows[1].items.reduce(0) { $0 + $1.tokens })
    }

    func testToolsRowListsNamesForBothSchemas() {
        let rows = ContextLens.rows(segments: [], tools: [
            ["name": "recall", "description": "d", "input_schema": [:] as [String: Any]],
            ["type": "function", "function": ["name": "roll_dice"] as [String: Any]],
        ], tuckedTools: ["echo"])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "tools")
        XCTAssertEqual(rows[0].items.map(\.title), ["recall", "roll_dice"])
        XCTAssertEqual(rows[0].countText, "2 个，另有 1 个收在「更多工具」")
        XCTAssertGreaterThan(rows[0].tokens, 0)
    }

    func testNoToolsNoRow() {
        XCTAssertTrue(ContextLens.rows(segments: [], tools: [], tuckedTools: []).isEmpty)
        XCTAssertTrue(ContextLens.rows(segments: [], tools: nil, tuckedTools: ["echo"]).isEmpty)
    }
}
