#if DEBUG
import MemoryCore
import SwiftData
import XCTest
@testable import 记忆花园

/// E2-6：Debug 导出「本楼层快照」→ 快照读回来和 `SwiftDataConversationSource` 逐项一致；
/// 备份包（`GlobalExporter` 记忆树）不带 `exports/`。夹具全虚构（星砚楼 / 岚舟 / 林栖 / 云桥城）。
final class FloorSnapshotExportTests: XCTestCase {
    private let pid = "xctest-floor-snapshot-星砚楼"
    private var root: URL!

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floor-snapshot-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Conversation.self, MessageNode.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @discardableResult
    private func node(_ id: String, _ role: String, _ text: String, at offset: TimeInterval?, parent: String?,
                      children: [String] = [], conversationId: String, contentType: String = "text",
                      in context: ModelContext) -> MessageNode {
        let node = MessageNode(id: id, role: role, content: text, contentType: contentType,
                               createTime: offset.map { t0.addingTimeInterval($0) }, parentId: parent,
                               childrenIds: children, conversationId: conversationId, profileId: pid)
        context.insert(node)
        return node
    }

    /// 四窗：主窗（合成根 / 隐藏 / 软删 / 旁支 / 分段 / CC 绑定 / createTime nil）+ 回收站窗
    /// + createTime 早于首节点 1 小时的窗 + 空窗（0 节点）
    private func seededContainer() throws -> ModelContainer {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let main = Conversation(id: "window-main", title: "潮汐与航图", createTime: t0.addingTimeInterval(-1),
                                updateTime: t0.addingTimeInterval(6), currentNodeId: "m-n5",
                                provider: "cc-bridge", profileId: pid)
        main.branchSelectionData = BranchSelection.encode(["m-n2": "m-n4", "m-n4": "m-n5"])
        main.ccBridgeSessionName = "mp-cc"
        main.lastRealChatAt = t0.addingTimeInterval(5)
        main.importBatchId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        main.archiveKind = "groupReadOnly"
        context.insert(main)

        node("m-root", "system", "", at: -1, parent: nil, children: ["m-n1"], conversationId: main.id, in: context).isSyntheticRoot = true
        node("m-n1", "user", "星砚楼今夜退潮。", at: 0, parent: "m-root", children: ["m-n2"], conversationId: main.id, in: context)
        let segmented = node("m-n2", "assistant", "航图", at: 1, parent: "m-n1", children: ["m-n3", "m-n4"],
                             conversationId: main.id, contentType: "segmented", in: context)
        segmented.segmentsData = try JSONEncoder().encode([MessageSegment.text("航图"), .thinking(text: "想想", signature: nil)])
        segmented.cardEditedAt = t0.addingTimeInterval(1.5)
        segmented.ccEdited = true
        node("m-n3", "user", "我先去码头。", at: 2, parent: "m-n2", conversationId: main.id, in: context)
        node("m-n4", "user", "林栖说等子夜。", at: 3, parent: "m-n2", children: ["m-hidden", "m-deleted", "m-notime", "m-n5"],
             conversationId: main.id, in: context)
        node("m-hidden", "system", "", at: 4, parent: "m-n4", conversationId: main.id, in: context).sourceVisibility = "uiSystem"
        node("m-deleted", "assistant", "我先下水试试。", at: 4, parent: "m-n4", conversationId: main.id, in: context).isTrashed = true
        node("m-notime", "user", "没有时间的旧注。", at: nil, parent: "m-n4", conversationId: main.id, in: context)
        node("m-n5", "assistant", "那就等子夜。", at: 5, parent: "m-n4", conversationId: main.id, in: context).ccMessageId = "cc-msg-0001"

        let trashed = Conversation(id: "window-trashed", title: "放弃的冬夜", createTime: t0.addingTimeInterval(10),
                                   updateTime: t0.addingTimeInterval(11), currentNodeId: "t-n2",
                                   provider: "api", profileId: pid)
        trashed.isTrashed = true
        trashed.memoryEnabled = false
        context.insert(trashed)
        node("t-n1", "user", "冬夜先记一笔。", at: 10, parent: nil, children: ["t-n2"], conversationId: trashed.id, in: context)
        node("t-n2", "assistant", "记下了。", at: 11, parent: "t-n1", conversationId: trashed.id, in: context)

        // 原生新开窗：先建 Conversation，1 小时后才有第一条消息
        let early = Conversation(id: "window-early", title: "早开的窗", createTime: t0.addingTimeInterval(-3600),
                                 updateTime: t0.addingTimeInterval(20), currentNodeId: "e-n1",
                                 provider: "chatgpt", profileId: pid)
        context.insert(early)
        node("e-n1", "user", "窗先开，话后说。", at: 20, parent: nil, conversationId: early.id, in: context)

        // 空窗（0 节点）：createTime 只能靠窗口自带，回落会变 1970
        let empty = Conversation(id: "window-empty", title: "空窗", createTime: t0.addingTimeInterval(-7200),
                                 updateTime: t0.addingTimeInterval(-7200), currentNodeId: "",
                                 provider: "chatgpt", profileId: pid)
        context.insert(empty)

        try context.save()
        return container
    }

    func testExportRoundTripsLikeSwiftDataSource() throws {
        let container = try seededContainer()
        let exportedAt = t0.addingTimeInterval(3600)
        let written = try FloorSnapshotExport.export(profileId: pid, container: container,
                                                     memoryRoot: root, now: exportedAt)

        XCTAssertEqual(written.windows, 4, "回收站 / 早开 / 空窗都要导出")
        XCTAssertEqual(written.nodes, 12)
        XCTAssertEqual(written.url.deletingLastPathComponent().lastPathComponent, "exports")
        XCTAssertTrue(written.url.lastPathComponent.hasPrefix("floor-snapshot-"))
        XCTAssertTrue(written.url.lastPathComponent.hasSuffix("Z.json"))
        XCTAssertTrue(written.url.lastPathComponent.contains(FloorSnapshotExport.stamp(exportedAt)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("exports").path),
                       [written.url.lastPathComponent], "不许留临时文件")

        let snapshot = try JSONDecoder().decode(FloorSnapshot.self, from: Data(contentsOf: written.url))
        XCTAssertEqual(snapshot.schema, 2)
        XCTAssertEqual(snapshot.exportedAt, exportedAt)
        XCTAssertEqual(snapshot.profileId, pid)

        let live = SwiftDataConversationSource(container: container)
        let replay = SnapshotConversationSource(floor: snapshot, profileId: pid)
        let liveWindows = try live.windows(profileId: pid, updatedSince: nil, includeTrashed: true)
        let replayWindows = try replay.windows(profileId: pid, updatedSince: nil, includeTrashed: true)
        XCTAssertEqual(replayWindows.map(\.id).sorted(), liveWindows.map(\.id).sorted())
        XCTAssertEqual(try replay.windows(profileId: pid, updatedSince: nil, includeTrashed: false).map(\.id).sorted(),
                       try live.windows(profileId: pid, updatedSince: nil, includeTrashed: false).map(\.id).sorted(),
                       "includeTrashed: false 也要一致")

        for expected in liveWindows {
            let actual = try XCTUnwrap(replayWindows.first { $0.id == expected.id }, "丢了窗口 \(expected.id)")
            XCTAssertEqual(actual, expected, "窗口 \(expected.id) 逐字段漂了（含 createTime）")

            let liveNodes = try live.nodes(profileId: pid, conversationId: expected.id)
            let replayNodes = try replay.nodes(profileId: pid, conversationId: expected.id)
            XCTAssertEqual(replayNodes.sorted { $0.id < $1.id }, liveNodes.sorted { $0.id < $1.id },
                           "窗口 \(expected.id) 的节点整值漂了")
            XCTAssertEqual(visiblePath(window: actual, nodes: replayNodes).map(\.id),
                           visiblePath(window: expected, nodes: liveNodes).map(\.id),
                           "窗口 \(expected.id) 的主线序列漂了")
        }

        // 窗口 createTime 原样读写：早于首节点 1 小时 / 空窗（0 节点）都不回落
        let early = try XCTUnwrap(replayWindows.first { $0.id == "window-early" })
        XCTAssertEqual(early.createTime, t0.addingTimeInterval(-3600))
        let empty = try XCTUnwrap(replayWindows.first { $0.id == "window-empty" })
        XCTAssertEqual(empty.createTime, t0.addingTimeInterval(-7200))
        XCTAssertEqual(try replay.nodes(profileId: pid, conversationId: "window-empty"), [])

        // 其余五个查询两源对照
        for text in ["码头", "子夜"] {
            XCTAssertEqual(try replay.search(profileId: pid, text: text, conversationId: nil).map(\.id),
                           try live.search(profileId: pid, text: text, conversationId: nil).map(\.id),
                           "search(\(text)) 两源不一致")
        }
        XCTAssertEqual(try replay.search(profileId: pid, text: "子夜", conversationId: "window-main").map(\.id),
                       try live.search(profileId: pid, text: "子夜", conversationId: "window-main").map(\.id),
                       "限窗口的 search 两源不一致")
        XCTAssertEqual(try replay.search(profileId: pid, text: "子夜", conversationId: "window-empty").map(\.id), [])

        let allIds = try liveWindows.flatMap { try live.nodes(profileId: pid, conversationId: $0.id).map(\.id) }
        XCTAssertEqual(try replay.messages(profileId: pid, ids: allIds).sorted { $0.id < $1.id },
                       try live.messages(profileId: pid, ids: allIds).sorted { $0.id < $1.id })
        XCTAssertEqual(try replay.titles(profileId: pid, ids: liveWindows.map(\.id)),
                       try live.titles(profileId: pid, ids: liveWindows.map(\.id)))
        for id in ["window-main", "window-early", "window-empty"] {
            XCTAssertEqual(try replay.window(profileId: pid, idOrPrefix: id),
                           try live.window(profileId: pid, idOrPrefix: id), "window(idOrPrefix: \(id))")
        }

        let mainNodes = try replay.nodes(profileId: pid, conversationId: "window-main")
        XCTAssertEqual(mainNodes.first { $0.id == "m-hidden" }?.sourceVisibility, "uiSystem")
        XCTAssertEqual(mainNodes.first { $0.id == "m-hidden" }?.isSourceHidden, true)
        XCTAssertEqual(mainNodes.first { $0.id == "m-deleted" }?.isTrashed, true)
        XCTAssertEqual(mainNodes.first { $0.id == "m-root" }?.isSyntheticRoot, true)
        XCTAssertEqual(mainNodes.first { $0.id == "m-n2" }?.segments, [.text("航图"), .thinking("想想")])
        XCTAssertEqual(mainNodes.first { $0.id == "m-n4" }?.childrenIds,
                       ["m-hidden", "m-deleted", "m-notime", "m-n5"],
                       "childrenIds 原样带（不从 parent 反推）")
        XCTAssertEqual(mainNodes.first { $0.id == "m-n5" }?.ccMessageId, "cc-msg-0001")
        XCTAssertEqual(mainNodes.first { $0.id == "m-n1" }?.contentType, "text")
        XCTAssertNil(mainNodes.first { $0.id == "m-notime" }?.createTime,
                     "createTime 缺失的消息往返后仍是 nil（不再被填成窗口时间）")
        let snapshotNode = try XCTUnwrap(snapshot.windows.first { $0.id == "window-main" }?
            .nodes.first { $0.id == "m-notime" })
        XCTAssertNil(snapshotNode.at, "导出文件里也不写 at")
    }

    /// 每次导出都是整楼层原文：连导 3 次只留最新 2 份
    func testKeepsOnlyLatestTwoSnapshots() throws {
        let container = try seededContainer()
        var names: [String] = []
        for offset in [3600.0, 7200, 10800] {
            let written = try FloorSnapshotExport.export(profileId: pid, container: container, memoryRoot: root,
                                                         now: t0.addingTimeInterval(offset))
            names.append(written.url.lastPathComponent)
        }
        let dir = root.appendingPathComponent(FloorSnapshotExportFolder.name, isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       Array(names.suffix(2)), "只留最新两份")
    }

    /// 同一秒连导两次：同名目标已存在也要覆盖成功，且内容是第二次的
    func testSecondExportInSameSecondOverwrites() throws {
        let container = try seededContainer()
        let now = t0.addingTimeInterval(3600)
        let first = try FloorSnapshotExport.export(profileId: pid, container: container, memoryRoot: root, now: now)

        let context = ModelContext(container)
        let windows = try context.fetch(FetchDescriptor<Conversation>())
        try XCTUnwrap(windows.first { $0.id == "window-main" }).title = "潮汐与航图（改）"
        try context.save()

        let second = try FloorSnapshotExport.export(profileId: pid, container: container, memoryRoot: root, now: now)
        XCTAssertEqual(second.url, first.url, "同一秒 → 同名文件")
        let dir = root.appendingPathComponent(FloorSnapshotExportFolder.name, isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [second.url.lastPathComponent],
                       "覆盖后仍只有一份，也不留临时文件")
        let snapshot = try JSONDecoder().decode(FloorSnapshot.self, from: Data(contentsOf: second.url))
        XCTAssertEqual(snapshot.windows.first { $0.id == "window-main" }?.title, "潮汐与航图（改）",
                       "内容是第二次的")
    }

    /// prune 只删严格时间戳名、普通文件、非链接的快照：目录 / 其它名字一律不动
    func testPruneLeavesDirectoriesAndOtherNamesAlone() throws {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(FloorSnapshotExportFolder.name, isDirectory: true)
        let fakeDir = dir.appendingPathComponent("floor-snapshot-0000.json", isDirectory: true)
        try fm.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        try "用户文件".write(to: fakeDir.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        let old = dir.appendingPathComponent("floor-snapshot-20200101-000000Z.json")
        try "{}".write(to: old, atomically: true, encoding: .utf8)

        let container = try seededContainer()
        let first = try FloorSnapshotExport.export(profileId: pid, container: container, memoryRoot: root,
                                                   now: t0.addingTimeInterval(3600))
        let second = try FloorSnapshotExport.export(profileId: pid, container: container, memoryRoot: root,
                                                    now: t0.addingTimeInterval(7200))

        XCTAssertFalse(fm.fileExists(atPath: old.path), "旧的快照文件照删")
        XCTAssertTrue(fm.fileExists(atPath: fakeDir.appendingPathComponent("inside.txt").path), "目录及内容不能动")
        let snapshots = try fm.contentsOfDirectory(atPath: dir.path)
            .filter(FloorSnapshotExportFolder.isSnapshotFileName).sorted()
        XCTAssertEqual(snapshots, [first.url.lastPathComponent, second.url.lastPathComponent].sorted(),
                       "保留最新 2 份，目录不计入")
    }

    /// 助手 fs_* / 文件库 UI 都看不到 `exports/`（整楼层原文）；大小写不敏感卷上 `Exports/` 同目录也要跳
    func testAssistantAndUIListsSkipExportsFolder() async throws {
        let fm = FileManager.default
        let memory = root.appendingPathComponent("memory", isDirectory: true)
        try fm.createDirectory(at: memory.appendingPathComponent("wiki/人", isDirectory: true), withIntermediateDirectories: true)
        let exports = memory.appendingPathComponent("Exports", isDirectory: true)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)
        try "星砚".write(to: memory.appendingPathComponent("wiki/人/星砚.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: exports.appendingPathComponent("floor-snapshot-x.json"),
                       atomically: true, encoding: .utf8)

        let profileId = pid
        let assistant = await Task.detached { FileLibraryStore.memoryList(profileId: profileId, memoryRoot: memory) }.value
        XCTAssertEqual(assistant.map(\.path), ["memory/wiki/人/星砚.md"])
        let ui = await Task.detached { FileLibraryStore.memoryUIList(profileId: profileId, memoryRoot: memory) }.value
        XCTAssertEqual(ui.map(\.path), ["memory/wiki/人/星砚.md"])

        XCTAssertTrue(FileLibraryTools.hiddenFromAssistant("memory/Exports/floor-snapshot-x.json"))
        XCTAssertTrue(FileLibraryTools.hiddenFromAssistant("memory/Exports"))
        XCTAssertTrue(FileLibraryTools.hiddenFromAssistant("memory/exports/floor-snapshot-x.json"))
        XCTAssertFalse(FileLibraryTools.hiddenFromAssistant("memory/wiki/x.md"))
    }

    /// 备份包会整目录拷记忆树：`exports/` 不进包，其它顶层目录照拷
    func testGlobalBackupSkipsExportsFolder() throws {
        let fm = FileManager.default
        let src = root.appendingPathComponent("memory", isDirectory: true)
        try fm.createDirectory(at: src.appendingPathComponent("wiki/人", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: src.appendingPathComponent(FloorSnapshotExportFolder.name, isDirectory: true),
                               withIntermediateDirectories: true)
        try "页".write(to: src.appendingPathComponent("wiki/人/星砚.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: src.appendingPathComponent("exports/floor-snapshot-x.json"), atomically: true, encoding: .utf8)

        let dst = root.appendingPathComponent("backup/memory", isDirectory: true)
        try GlobalExporter.copyMemoryTree(from: src, to: dst)

        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("wiki/人/星砚.md").path))
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("exports").path), "整楼层原文不进备份")

        // 大写 `Exports/`：同一套排除逻辑按小写比对（大小写不敏感卷上就是同一个目录，单独建源树）
        let upperSrc = root.appendingPathComponent("memory-upper", isDirectory: true)
        try fm.createDirectory(at: upperSrc.appendingPathComponent("Exports", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: upperSrc.appendingPathComponent("wiki/人", isDirectory: true),
                               withIntermediateDirectories: true)
        try "页".write(to: upperSrc.appendingPathComponent("wiki/人/星砚.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: upperSrc.appendingPathComponent("Exports/floor-snapshot-x.json"), atomically: true, encoding: .utf8)

        let upperDst = root.appendingPathComponent("backup/memory-upper", isDirectory: true)
        try GlobalExporter.copyMemoryTree(from: upperSrc, to: upperDst)

        XCTAssertTrue(fm.fileExists(atPath: upperDst.appendingPathComponent("wiki/人/星砚.md").path))
        XCTAssertFalse(fm.fileExists(atPath: upperDst.appendingPathComponent("Exports").path),
                       "Exports/ 大写也不进备份")
    }

    /// `memory/alias` 链到 `exports/` 也不能绕过读闸（解析真实路径后再判一次）
    func testResolveMemoryRejectsSymlinkAliasToExports() throws {
        let fm = FileManager.default
        let symlinkPid = pid + "-symlink"
        let memory = FileLibraryStore.memoryRoot(profileId: symlinkPid)
        defer {
            try? fm.removeItem(at: memory.deletingLastPathComponent())
            FileLibraryStore.forgetSlug(profileId: symlinkPid)
        }
        let exports = memory.appendingPathComponent(FloorSnapshotExportFolder.name, isDirectory: true)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)
        try "{}".write(to: exports.appendingPathComponent("floor-snapshot-x.json"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: memory.appendingPathComponent("wiki", isDirectory: true), withIntermediateDirectories: true)
        try "页".write(to: memory.appendingPathComponent("wiki/x.md"), atomically: true, encoding: .utf8)
        let alias = memory.appendingPathComponent("alias", isDirectory: true)
        try? fm.removeItem(at: alias)
        try fm.createSymbolicLink(at: alias, withDestinationURL: exports)

        XCTAssertNil(FileLibraryStore.resolveMemory("memory/alias/floor-snapshot-x.json", profileId: symlinkPid),
                     "别名解析后落在 exports/ 必须拒")
        XCTAssertNotNil(FileLibraryStore.resolveMemory("memory/wiki/x.md", profileId: symlinkPid))
    }
}
#endif
