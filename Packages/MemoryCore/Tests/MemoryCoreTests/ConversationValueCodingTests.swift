import XCTest
@testable import MemoryCore

/// 值类型自身的解码兼容：旧 JSON 缺新键、新导出端写出未知分段 kind 都不能整条炸。
final class ConversationValueCodingTests: XCTestCase {
    /// E3-W2 之前的 `ConversationMessage` JSON 没有 `cardEditedAt` / `ccEdited`：
    /// 自定义解码按 nil / false 兜底，其余字段照常。
    func testMessageDecodesLegacyJSONWithoutEditKeys() throws {
        let json = """
        {"id":"m1","conversationId":"c1","role":"assistant","content":"正文","contentType":"text",
         "childrenIds":[],"isTrashed":false,"isSyntheticRoot":false}
        """
        let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.content, "正文")
        XCTAssertNil(message.segments)
        XCTAssertNil(message.cardEditedAt)
        XCTAssertFalse(message.ccEdited)
    }

    /// 旧解码器不认识的 kind（新导出端的 `thinking` 或以后的种类）退回 `.other`，
    /// 不让一条分段炸掉整份快照。
    func testUnknownSegmentKindFallsBackToOther() throws {
        let json = """
        {"id":"m1","conversationId":"c1","role":"assistant","content":"正文","contentType":"text",
         "segments":[{"kind":"whatever"},{"kind":"text","text":"正文"}],
         "childrenIds":[],"isTrashed":false,"isSyntheticRoot":false}
        """
        let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.segments, [.other, .text("正文")])
    }
}
