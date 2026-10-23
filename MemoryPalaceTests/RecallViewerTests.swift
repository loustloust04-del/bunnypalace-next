import XCTest
import SwiftData
@testable import 记忆花园

/// 记忆查看升级（粟粟 10-03：按推荐——卡上只停用 / 恢复，不放删除）
@MainActor
final class RecallViewerTests: XCTestCase {

    // MARK: - 显示

    func testStateOfHit() {
        XCTAssertEqual(RecallHitDisplay.state(exists: true, supersededAt: nil), .active)
        XCTAssertEqual(RecallHitDisplay.state(exists: true, supersededAt: Date()), .disabled)
        XCTAssertEqual(RecallHitDisplay.state(exists: false, supersededAt: nil), .deleted)
    }

    func testShowsLiveContentOverSnapshot() {
        XCTAssertEqual(RecallHitDisplay.text(live: "改过的", snapshot: "当时的"), "改过的")
        XCTAssertEqual(RecallHitDisplay.text(live: nil, snapshot: "当时的"), "当时的", "删掉了就显示当时的")
    }

    func testSourceLine() {
        XCTAssertEqual(RecallHitDisplay.sourceLine(conversationTitle: "周末计划", quote: "我喜欢山里"), "来自「周末计划」：“我喜欢山里”")
        XCTAssertEqual(RecallHitDisplay.sourceLine(conversationTitle: "周末计划", quote: nil), "来自「周末计划」")
        XCTAssertEqual(RecallHitDisplay.sourceLine(conversationTitle: nil, quote: "原话"), "原话：“原话”")
        XCTAssertEqual(RecallHitDisplay.sourceLine(conversationTitle: nil, quote: nil), "手动添加 / 来源不明")
    }

    // MARK: - 改 / 停用 / 恢复（走记忆库同一套接口）

    private func context() throws -> ModelContext {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    func testEditSavesTrimmedContentAndKeepsSource() throws {
        let ctx = try context()
        let m = try SwiftDataMemoryStore().add(content: "喜欢海边", category: "preference", keywords: ["海边"],
                                               profileId: "p", isUserExplicit: false, extractedBy: "x",
                                               sourceConversationId: "c", sourceQuote: "我喜欢海边", sourceNodeId: "n", context: ctx)
        XCTAssertTrue(RecallActions.saveEdit(m, text: "  喜欢山里  ", context: ctx))
        XCTAssertEqual(m.content, "喜欢山里")
        XCTAssertEqual(m.sourceNodeId, "n", "出处不丢")
        XCTAssertEqual(m.sourceQuote, "我喜欢海边")
        XCTAssertFalse(RecallActions.saveEdit(m, text: "   ", context: ctx), "空的不存")
        XCTAssertEqual(m.content, "喜欢山里")
    }

    func testDisableThenRevive() throws {
        let ctx = try context()
        let m = try SwiftDataMemoryStore().add(content: "a", category: "fact", keywords: [], profileId: "p",
                                               isUserExplicit: false, extractedBy: "x", sourceConversationId: nil,
                                               sourceQuote: nil, sourceNodeId: nil, context: ctx)
        RecallActions.toggleDisabled(m, context: ctx)
        XCTAssertNotNil(m.supersededAt, "停用 = 软失效，可恢复")
        RecallActions.toggleDisabled(m, context: ctx)
        XCTAssertNil(m.supersededAt)
    }
}
