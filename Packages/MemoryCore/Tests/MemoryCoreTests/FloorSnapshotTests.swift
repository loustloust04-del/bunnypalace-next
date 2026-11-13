import XCTest
@testable import MemoryCore

final class FloorSnapshotTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/conversation-floor-schema1.json")
    }

    private func loadSchemaOne() throws -> FloorSnapshot {
        try JSONDecoder().decode(FloorSnapshot.self, from: Data(contentsOf: fixtureURL))
    }

    func testSchemaOneFixtureDecodesWithDefaults() throws {
        let floor = try loadSchemaOne()
        XCTAssertEqual(floor.windows.map(\.id), ["xingyan-window-0001", "linqi-window-0002", "lantern-window-0003", "recycle-window-0004"])
        let first = floor.windows[0]
        XCTAssertEqual(first.current, "xz-n4")
        XCTAssertEqual(first.nodes.count, 8)
        XCTAssertEqual(first.nodes[0].at, Date(timeIntervalSince1970: 1_793_494_800))
        XCTAssertTrue(floor.windows[3].trashed)

        let source = SnapshotConversationSource(floor: floor, profileId: "xingyan")
        let windows = try source.windows(profileId: "xingyan", updatedSince: nil, includeTrashed: true)
        XCTAssertEqual(windows.count, 4)
        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.updateTime, Date(timeIntervalSince1970: 1_793_541_600), "updateTime 缺省取节点最晚 at")
        XCTAssertEqual(window.createTime, Date(timeIntervalSince1970: 1_793_494_800), "createTime 缺省取节点最早 at")

        let nodes = try source.nodes(profileId: "xingyan", conversationId: "xingyan-window-0001")
        XCTAssertEqual(nodes.first { $0.id == "xz-hidden" }?.sourceVisibility, "hidden")
        XCTAssertEqual(nodes.first { $0.id == "xz-deleted" }?.isTrashed, true)
        XCTAssertEqual(nodes.first { $0.id == "xz-n2" }?.childrenIds, ["xz-branch", "xz-deleted", "xz-n3"],
                       "childrenIds 缺省按 parent 反推并按 at 排序")
    }

    /// 口径对齐：`visiblePath` 与 `MemoryBenchLocalExecutor.branch` 在 schema 1 夹具上逐 id 相同
    func testVisiblePathMatchesLocalExecutorBranchOnFixture() throws {
        let floor = try loadSchemaOne()
        let source = SnapshotConversationSource(floor: floor, profileId: "p")
        for id in ["xingyan-window-0001", "linqi-window-0002", "lantern-window-0003"] {
            let snapshotWindow = try XCTUnwrap(floor.windows.first { $0.id == id })
            let window = try XCTUnwrap(try source.window(profileId: "p", idOrPrefix: id))
            let nodes = try source.nodes(profileId: "p", conversationId: id)
            let expected = localExecutorBranch(snapshotWindow).filter { !$0.hidden && !$0.deleted }.map(\.id)
            XCTAssertEqual(visiblePath(window: window, nodes: nodes).map(\.id), expected, "窗口 \(id) 口径不一致")
        }
    }

    /// 逐字照抄 `MemoryBenchLocalExecutor.branch`（:407-416）
    private func localExecutorBranch(_ window: FloorSnapshot.Window) -> [FloorSnapshot.Node] {
        let byId = Dictionary(uniqueKeysWithValues: window.nodes.map { ($0.id, $0) })
        var path: [FloorSnapshot.Node] = []
        var next: String? = window.current
        var seen = Set<String>()
        while let id = next, seen.insert(id).inserted, let node = byId[id] {
            path.append(node)
            next = node.parent
        }
        return path.reversed()
    }

    func testSchemaTwoFieldsRoundTrip() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let floor = FloorSnapshot(windows: [
            .init(id: "w", title: "窗", current: "n2", memoryEnabled: false, trashed: false,
                  nodes: [
                    .init(id: "n1", role: "user", text: "", at: at, hidden: false, deleted: false,
                          contentType: "multimodal_text", segments: [.text("甲"), .other], isSyntheticRoot: true,
                          sourceVisibility: "uiSystem", ccMessageId: "s_1", childrenIds: ["n2"]),
                    .init(id: "n2", role: "assistant", text: "答", at: at.addingTimeInterval(60), parent: "n1"),
                  ],
                  profileId: "p", createTime: at.addingTimeInterval(-30), updateTime: at.addingTimeInterval(120),
                  branchSelection: ["n1": "n2"], isCC: true, lastRealChatAt: at.addingTimeInterval(30),
                  provider: "cc-bridge", importBatchId: "batch-1", archiveKind: "groupReadOnly"),
        ], schema: FloorSnapshot.currentSchema, exportedAt: at, profileId: "p")
        let decoded = try JSONDecoder().decode(FloorSnapshot.self, from: JSONEncoder().encode(floor))
        XCTAssertEqual(decoded, floor)
        XCTAssertEqual(decoded.schema, 2)
        XCTAssertEqual(decoded.exportedAt, at)
        XCTAssertEqual(decoded.profileId, "p")

        let source = SnapshotConversationSource(floor: decoded, profileId: "p")
        let window = try XCTUnwrap(try source.window(profileId: "p", idOrPrefix: "w"))
        XCTAssertTrue(window.isCC)
        XCTAssertEqual(window.provider, "cc-bridge")
        XCTAssertEqual(window.archiveKind, "groupReadOnly")
        XCTAssertEqual(window.importBatchId, "batch-1")
        XCTAssertEqual(window.lastRealChatAt, at.addingTimeInterval(30))
        XCTAssertEqual(window.createTime, at.addingTimeInterval(-30), "窗口 createTime 原样读写，不靠最早节点回落")
        XCTAssertEqual(window.branchSelection, BranchSelection.encode(["n1": "n2"]))
        let node = try XCTUnwrap(try source.messages(profileId: "p", ids: ["n1"]).first)
        XCTAssertEqual(node.sourceVisibility, "uiSystem")
        XCTAssertTrue(node.isSyntheticRoot)
        XCTAssertEqual(node.segments, [.text("甲"), .other])
        XCTAssertEqual(node.ccMessageId, "s_1")
        XCTAssertEqual(node.childrenIds, ["n2"])
    }
}
