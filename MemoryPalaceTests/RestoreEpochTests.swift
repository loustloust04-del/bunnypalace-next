import XCTest
import SwiftData
@testable import 记忆花园

/// 恢复纪元特征测试（plan-fix-ios-import-impl T1-T5）：
/// 全量恢复后，mtime 早于纪元的云端同步文档/墓碑一律不认；无纪元 = 行为与现状完全一致。
final class RestoreEpochTests: XCTestCase {

    let pid = "xctest-epoch"
    var containerA: ModelContainer!
    var containerB: ModelContainer!
    var contextA: ModelContext!
    var contextB: ModelContext!
    var tempRoot: URL!

    @MainActor
    override func setUp() {
        super.setUp()
        containerA = try! ModelContainer(for: Conversation.self, MessageNode.self,
                                         configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containerB = try! ModelContainer(for: Conversation.self, MessageNode.self,
                                         configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        contextA = ModelContext(containerA)
        contextB = ModelContext(containerB)
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("epoch-test-\(UUID().uuidString)")
        SyncStore.overrideRoot = tempRoot
        SyncStoreTests.wipeLocalSyncState(pid: pid)   // 同款 flaky 根因，见 SyncStoreTests 注释
        clearEpochKeys()
    }

    override func tearDown() {
        clearEpochKeys()
        SyncStore.overrideRoot = nil
        try? FileManager.default.removeItem(at: tempRoot)
        containerA = nil
        containerB = nil
        super.tearDown()
    }

    private func clearEpochKeys() {
        UserDefaults.standard.removeObject(forKey: SyncStore.restoreEpochKey)
        UserDefaults.standard.removeObject(forKey: SyncStore.firstPumpExportOnlyKey)
    }

    private func setEpoch(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: SyncStore.restoreEpochKey)
    }

    private func setMtime(_ date: Date, at url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @MainActor
    private func makeConversation(in context: ModelContext, id: String) -> Conversation {
        let conv = Conversation(id: id, title: "纪元测试", createTime: Date(timeIntervalSinceNow: -100),
                                updateTime: Date(timeIntervalSinceNow: -50), currentNodeId: "a1",
                                provider: "api", profileId: pid)
        context.insert(conv)
        let node = MessageNode(id: "\(id)-a1", role: "assistant", content: "hi", contentType: "text",
                               createTime: Date(), parentId: nil, childrenIds: [],
                               conversationId: id, profileId: pid)
        context.insert(node)
        try? context.save()
        return conv
    }

    @MainActor
    private func convCount(_ context: ModelContext) -> Int {
        let p = pid
        return (try? context.fetchCount(FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.profileId == p }
        ))) ?? -1
    }

    // T1a：纪元后的老 mtime 文件被拒
    @MainActor
    func testEpochRejectsPreEpochDocuments() throws {
        _ = makeConversation(in: contextA, id: "conv-t1")
        XCTAssertEqual(SyncStore.exportChanged(profileId: pid, context: contextA).exported, 1)

        setEpoch(Date(timeIntervalSinceNow: 600))  // 纪元在未来 → 现存文件全部早于纪元
        let imported = SyncStore.importAll(profileId: pid, context: contextB)
        XCTAssertEqual(imported.conversationsCreated, 0, "纪元前导出的云端文档不得导入")
        XCTAssertEqual(convCount(contextB), 0)
    }

    // T1b：文件 mtime 晚于纪元 → 正常导入（其他设备恢复后的新导出不受伤）
    @MainActor
    func testEpochAllowsPostEpochDocuments() throws {
        _ = makeConversation(in: contextA, id: "conv-t1b")
        _ = SyncStore.exportChanged(profileId: pid, context: contextA)

        setEpoch(Date(timeIntervalSinceNow: -600))  // 纪元在过去 → 文件 mtime（现在）晚于纪元
        let imported = SyncStore.importAll(profileId: pid, context: contextB)
        XCTAssertEqual(imported.conversationsCreated, 1, "纪元后的新导出必须正常进")
        XCTAssertEqual(convCount(contextB), 1)
    }

    // T1c：被拒的文件之后真更新（mtime 越过纪元）→ 照常进（不被账本卡死）
    @MainActor
    func testRejectedFileImportsAfterTouch() throws {
        _ = makeConversation(in: contextA, id: "conv-t1c")
        _ = SyncStore.exportChanged(profileId: pid, context: contextA)
        let epoch = Date(timeIntervalSinceNow: 600)
        setEpoch(epoch)
        XCTAssertEqual(SyncStore.importAll(profileId: pid, context: contextB).conversationsCreated, 0)

        let fileURL = SyncStore.syncRoot(profileId: pid)!.appendingPathComponent("conv-t1c.json")
        setMtime(epoch.addingTimeInterval(60), at: fileURL)
        XCTAssertEqual(SyncStore.importAll(profileId: pid, context: contextB).conversationsCreated, 1)
    }

    // T2：纪元前的墓碑失效——恢复复活的对话不被老墓碑再杀；纪元后的新墓碑照常生效
    @MainActor
    func testEpochGatesTombstones() throws {
        _ = makeConversation(in: contextB, id: "conv-t2")
        SyncStore.recordPermanentDeletion(conversationId: "conv-t2", profileId: pid)
        let tombURL = SyncStore.tombstoneRoot(profileId: pid)!.appendingPathComponent("conv-t2.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombURL.path))

        setEpoch(Date(timeIntervalSinceNow: 600))  // 墓碑 mtime（现在）早于纪元
        _ = SyncStore.importAll(profileId: pid, context: contextB)
        XCTAssertEqual(convCount(contextB), 1, "纪元前的墓碑不得杀恢复回来的对话")

        setMtime(Date(timeIntervalSinceNow: 1200), at: tombURL)  // 墓碑"更新"到纪元后
        _ = SyncStore.importAll(profileId: pid, context: contextB)
        XCTAssertEqual(convCount(contextB), 0, "纪元后的墓碑照常生效")
    }

    // T3：首泵 export-only flag 读到即清、只生效一次
    @MainActor
    func testFirstPumpFlagConsumedOnce() {
        XCTAssertFalse(SyncEngine.consumeFirstPumpExportOnly(), "无 flag 时不触发")
        UserDefaults.standard.set(true, forKey: SyncStore.firstPumpExportOnlyKey)
        XCTAssertTrue(SyncEngine.consumeFirstPumpExportOnly(), "首次消费返回 true")
        XCTAssertFalse(SyncEngine.consumeFirstPumpExportOnly(), "flag 已清，二次不触发")
    }

    // T4：legacy store 改名 backup 时 sidecar 用真实连字符命名跟走
    func testSidecarRenameFollowsBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = dir.appendingPathComponent("x.store")
        try Data("db".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: store.path + "-shm"))

        UnifiedContainerMigration.renameLegacyToBackup(url: store)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertFalse(remaining.contains("x.store"), "主库应已改名")
        XCTAssertFalse(remaining.contains("x.store-wal"), "wal sidecar 应跟走（旧 bug：残留原名）")
        XCTAssertFalse(remaining.contains("x.store-shm"), "shm sidecar 应跟走")
        let backup = remaining.first { $0.hasPrefix("x.store.backup") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        XCTAssertNotNil(backup, "backup 主库应存在: \(remaining)")
        if let backup {
            XCTAssertTrue(remaining.contains("\(backup)-wal"), "backup-wal 应存在: \(remaining)")
            XCTAssertTrue(remaining.contains("\(backup)-shm"), "backup-shm 应存在: \(remaining)")
        }
    }

    // T5：无纪元（key 缺失）= 行为与现状完全一致（老用户零影响）
    @MainActor
    func testNoEpochBehavesAsBefore() throws {
        _ = makeConversation(in: contextA, id: "conv-t5")
        _ = SyncStore.exportChanged(profileId: pid, context: contextA)
        XCTAssertNil(SyncStore.restoreEpoch)
        let imported = SyncStore.importAll(profileId: pid, context: contextB)
        XCTAssertEqual(imported.conversationsCreated, 1)
        XCTAssertEqual(imported.nodesInserted, 1)
    }
}
