import XCTest
@testable import MemoryCore

/// 合同用例跑在 `SnapshotConversationSource` 上；E2-2 的 `SwiftDataConversationSource` 跑同一个函数。
final class ConversationSourceContractTests: XCTestCase {
    func testSnapshotSourceSatisfiesContract() throws {
        let source = SnapshotConversationSource(floor: ConversationSourceContract.floor())
        try ConversationSourceContract.check(source)
    }

    func testSnapshotDefaultsApplyToContractFloor() throws {
        let source = SnapshotConversationSource(floor: ConversationSourceContract.floor())
        let windows = try source.windows(profileId: ConversationSourceContract.profileId, updatedSince: nil, includeTrashed: true)
        let alpha = try XCTUnwrap(windows.first { $0.id == ConversationSourceContract.alpha })
        XCTAssertEqual(alpha.currentNodeId, "a4")
        XCTAssertEqual(alpha.profileId, ConversationSourceContract.profileId)
        XCTAssertFalse(alpha.isCC)
        XCTAssertEqual(alpha.provider, "chatgpt")

        let nodes = try source.nodes(profileId: ConversationSourceContract.profileId, conversationId: ConversationSourceContract.alpha)
        let hidden = try XCTUnwrap(nodes.first { $0.id == "a2" })
        XCTAssertEqual(hidden.sourceVisibility, "hidden")
        XCTAssertTrue(hidden.isSourceHidden)
        let deleted = try XCTUnwrap(nodes.first { $0.id == "a3" })
        XCTAssertTrue(deleted.isTrashed)
        XCTAssertEqual(try XCTUnwrap(nodes.first { $0.id == "a1" }).childrenIds, ["a2"], "childrenIds 按 parent 反推")
        XCTAssertEqual(try XCTUnwrap(nodes.first { $0.id == "a0" }).contentType, "text")
    }
}
