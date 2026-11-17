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

    private let pid = "xctest-recall-viewer"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    /// 停用 / 恢复 = 进 Deleted / Restore，两笔都记进记忆日志（和记忆页、整理台同一处）
    func testDisableThenReviveIsLogged() throws {
        let ctx = try context()
        let m = try SwiftDataMemoryStore().add(content: "a", category: "fact", keywords: [], profileId: pid,
                                               isUserExplicit: false, extractedBy: "x", sourceConversationId: nil,
                                               sourceQuote: nil, sourceNodeId: nil, context: ctx)
        RecallActions.toggleDisabled(m, context: ctx)
        XCTAssertNotNil(m.supersededAt, "停用 = 软失效，可恢复")
        RecallActions.toggleDisabled(m, context: ctx)
        XCTAssertNil(m.supersededAt)
        let log = MemoryAuditLog.load(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        XCTAssertEqual(log.map(\.action), [.restore, .delete])
    }
}
