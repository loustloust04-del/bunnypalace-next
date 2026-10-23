import XCTest
import SwiftData
@testable import 记忆花园

/// 跨设备同步特征测试：双 in-memory 容器模拟两台设备，共享临时目录当 iCloud。
/// 钉死合并语义：roundtrip 一致 / 分支并集 / 幂等 / 已有节点绝不被改写。
final class SyncStoreTests: XCTestCase {

    let pid = "xctest-sync"
    /// 洞 6：跨楼层冲突用的两个楼层（同一个库里，模拟单容器多租户）
    let floorA = "xctest-sync-xp-A"
    let floorB = "xctest-sync-xp-B"
    var containerA: ModelContainer!
    var containerB: ModelContainer!
    var contextA: ModelContext!
    var contextB: ModelContext!
    var tempRoot: URL!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        containerA = try! ModelContainer(for: Conversation.self, MessageNode.self, configurations: config)
        containerB = try! ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        contextA = ModelContext(containerA)
        contextB = ModelContext(containerB)
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sync-test-\(UUID().uuidString)")
        SyncStore.overrideRoot = tempRoot
        Self.wipeLocalSyncState(pid: pid)
        Self.wipeLocalSyncState(pid: floorA)
        Self.wipeLocalSyncState(pid: floorB)
    }

    /// 导出/导入指纹落在宿主沙盒真实目录（localStateDir 不随 overrideRoot 隔离）且 pid 固定，
    /// 上一次运行的残留戳 ≥ 本次 updateTime(now-50s) 时 exportChanged 静默跳过 → 两次运行间隔
    /// < 50s 必挂（2026-07-16 agora 合并验证时钉死的 flaky 根因）。setUp 清干净。
    static func wipeLocalSyncState(pid: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MemoryPalace/sync-state", isDirectory: true)
        for kind in ["export", "import"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(pid).\(kind).json"))
        }
    }

    override func tearDown() {
        SyncStore.overrideRoot = nil
        try? FileManager.default.removeItem(at: tempRoot)
        containerA = nil
        containerB = nil
        super.tearDown()
    }

    @MainActor
    private func makeConversation(in context: ModelContext, id: String, title: String) -> Conversation {
        let conv = Conversation(id: id, title: title, createTime: Date(timeIntervalSinceNow: -100),
                                updateTime: Date(timeIntervalSinceNow: -50), currentNodeId: "a1",
                                provider: "api", profileId: pid)
        context.insert(conv)
        for (nodeId, role, parent, children) in [
            ("root", "system", nil, ["u1"]),
            ("u1", "user", "root" as String?, ["a1"]),
            ("a1", "assistant", "u1", [String]())
        ] {
            let node = MessageNode(id: "\(id)-\(nodeId)", role: role, content: "c-\(nodeId)",
                                   contentType: "text", createTime: Date(), parentId: parent.map { "\(id)-\($0)" },
                                   childrenIds: children.map { "\(id)-\($0)" }, conversationId: id, profileId: pid)
            context.insert(node)
        }
        try? context.save()
        return conv
    }

    @MainActor
    private func nodes(_ context: ModelContext, _ convId: String) -> [MessageNode] {
        let p = pid
        return (try? context.fetch(FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.conversationId == convId && $0.profileId == p }
        ))) ?? []
    }

    @MainActor
    func testRoundtripBranchUnionAndIdempotency() throws {
        // A 建对话 → 导出 → B 导入：树一致
        let conv = makeConversation(in: contextA, id: "conv-1", title: "同步测试")
        var exported = SyncStore.exportChanged(profileId: pid, context: contextA)
        XCTAssertEqual(exported.exported, 1)

        var imported = SyncStore.importAll(profileId: pid, context: contextB)
        XCTAssertEqual(imported.conversationsCreated, 1)
        XCTAssertEqual(imported.nodesInserted, 3)
        XCTAssertEqual(Set(nodes(contextB, "conv-1").map(\.id)), Set(nodes(contextA, "conv-1").map(\.id)))

        // B 长出新分支（a1 下加 u2）→ 导出 → A 导入：A 两分支共存，原节点未被改写
        let newNode = MessageNode(id: "conv-1-u2", role: "user", content: "B 端新分支",
                                  contentType: "text", createTime: Date(), parentId: "conv-1-a1",
                                  childrenIds: [], conversationId: "conv-1", profileId: pid)
        contextB.insert(newNode)
        let a1B = nodes(contextB, "conv-1").first { $0.id == "conv-1-a1" }!
        a1B.childrenIds.append("conv-1-u2")
        let convB = (try? contextB.fetch(FetchDescriptor<Conversation>()))!.first!
        convB.updateTime = Date()
        try contextB.save()

        // A 本地把 a1 内容改掉（模拟本地状态），导入绝不能覆盖它
        let a1A = nodes(contextA, "conv-1").first { $0.id == "conv-1-a1" }!
        a1A.content = "A 端本地修改"
        try contextA.save()

        exported = SyncStore.exportChanged(profileId: pid, context: contextB)
        XCTAssertEqual(exported.exported, 1)
        imported = SyncStore.importAll(profileId: pid, context: contextA)
        XCTAssertEqual(imported.nodesInserted, 1, "只插缺失的 u2")

        let a1AfterImport = nodes(contextA, "conv-1").first { $0.id == "conv-1-a1" }!
        XCTAssertEqual(a1AfterImport.content, "A 端本地修改", "已有节点绝不被导入改写")
        XCTAssertEqual(Set(a1AfterImport.childrenIds), ["conv-1-u2"], "childrenIds 并集")
        XCTAssertEqual(nodes(contextA, "conv-1").count, 4)

        // 幂等：重复导入零新增
        let again = SyncStore.importAll(profileId: pid, context: contextA)
        XCTAssertEqual(again.nodesInserted, 0)
        XCTAssertEqual(again.conversationsCreated, 0)

        // 元数据 LWW：B 改标题（updateTime 更新）→ A 跟随
        convB.title = "B 改的标题"
        convB.updateTime = Date()
        try contextB.save()
        _ = SyncStore.exportChanged(profileId: pid, context: contextB)
        _ = SyncStore.importAll(profileId: pid, context: contextA)
        let convA = (try? contextA.fetch(FetchDescriptor<Conversation>()))!.first!
        XCTAssertEqual(convA.title, "B 改的标题")
        _ = conv
    }

    @MainActor
    func testExportFingerprintSkipsUnchanged() throws {
        _ = makeConversation(in: contextA, id: "conv-2", title: "指纹测试")
        XCTAssertEqual(SyncStore.exportChanged(profileId: pid, context: contextA).exported, 1)
        XCTAssertEqual(SyncStore.exportChanged(profileId: pid, context: contextA).exported, 0, "无变化不重复导出")
    }

    // MARK: - S4 删除传播

    @MainActor
    func testSoftDeletePropagatesAsLWW() throws {
        // A 建 → 同步到 B
        let convA = makeConversation(in: contextA, id: "conv-sd", title: "软删测试")
        _ = SyncStore.exportChanged(profileId: pid, context: contextA)
        _ = SyncStore.importAll(profileId: pid, context: contextB)
        let convsB = (try? contextB.fetch(FetchDescriptor<Conversation>()))!
        XCTAssertEqual(convsB.count, 1)
        XCTAssertFalse(convsB.first!.isTrashed, "B 端默认非删除态")

        // A 软删（业务字段 isTrashed/trashedAt——避开 NSManagedObject 框架保留名冲突）
        convA.isTrashed = true
        convA.trashedAt = Date()
        convA.updateTime = Date(timeIntervalSinceNow: 10)
        try contextA.save()

        let convACheck = (try contextA.fetch(FetchDescriptor<Conversation>())).first!
        XCTAssertTrue(convACheck.isTrashed, "A 端 isTrashed 持久化")

        // 同步：A 导出软删态 → B 导入跟随
        _ = SyncStore.exportChanged(profileId: pid, context: contextA)
        _ = SyncStore.importAll(profileId: pid, context: contextB)

        let convB = (try? contextB.fetch(FetchDescriptor<Conversation>()))!.first!
        XCTAssertTrue(convB.isTrashed, "对端跟着进回收站")
        XCTAssertNotNil(convB.trashedAt)
    }

    @MainActor
    func testRestorePropagatesAsLWW() throws {
        // A 建并软删 → B 收到删除态
        let convA = makeConversation(in: contextA, id: "conv-rs", title: "恢复测试")
        convA.isTrashed = true
        convA.trashedAt = Date(timeIntervalSinceNow: -10)
        convA.updateTime = Date(timeIntervalSinceNow: -10)
        try contextA.save()
        _ = SyncStore.exportChanged(profileId: pid, context: contextA)
        _ = SyncStore.importAll(profileId: pid, context: contextB)
        XCTAssertTrue((try contextB.fetch(FetchDescriptor<Conversation>())).first!.isTrashed)

        // B 端恢复
        let convB = (try contextB.fetch(FetchDescriptor<Conversation>())).first!
        convB.isTrashed = false
        convB.trashedAt = nil
        convB.updateTime = Date()
        try contextB.save()

        // B 导出 → A 导入跟随恢复
        _ = SyncStore.exportChanged(profileId: pid, context: contextB)
        _ = SyncStore.importAll(profileId: pid, context: contextA)
        let convAAfter = (try contextA.fetch(FetchDescriptor<Conversation>())).first!
        XCTAssertFalse(convAAfter.isTrashed, "B 恢复后 A 也恢复（updateTime 新者赢）")
        XCTAssertNil(convAAfter.trashedAt)
    }

    @MainActor
    func testPermanentDeleteWritesTombstoneAndPropagates() throws {
        // A 建 → 同步到 B（B 有完整副本）
        _ = makeConversation(in: contextA, id: "conv-pd", title: "永久删测试")
        _ = SyncStore.exportChanged(profileId: pid, context: contextA)
        _ = SyncStore.importAll(profileId: pid, context: contextB)
        XCTAssertEqual(nodes(contextB, "conv-pd").count, 3)

        // A 永久删：写墓碑 + 删云文档 + 清指纹（模拟 ConversationViewModel 的调用顺序）
        SyncStore.recordPermanentDeletion(conversationId: "conv-pd", profileId: pid)
        let conv = (try contextA.fetch(FetchDescriptor<Conversation>())).first!
        for n in nodes(contextA, "conv-pd") { contextA.delete(n) }
        contextA.delete(conv)
        try contextA.save()

        // 墓碑落盘 & 云文档已清
        let tombDir = SyncStore.tombstoneRoot(profileId: pid)!
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombDir.appendingPathComponent("conv-pd.json").path),
                      "墓碑文件已写")
        let convRoot = SyncStore.syncRoot(profileId: pid)!
        XCTAssertFalse(FileManager.default.fileExists(atPath: convRoot.appendingPathComponent("conv-pd.json").path),
                       "云对话文档已删")

        // B 导入 → 本地永久删
        _ = SyncStore.importAll(profileId: pid, context: contextB)
        XCTAssertEqual((try contextB.fetch(FetchDescriptor<Conversation>())).count, 0, "B 端 conversation 彻底删")
        XCTAssertEqual(nodes(contextB, "conv-pd").count, 0, "B 端 nodes 彻底删")
    }

    @MainActor
    func testTombstoneExpiredCleanup() throws {
        // 手工写一个 91 天前的过期墓碑（没有对应 conversation）
        let tombDir = SyncStore.tombstoneRoot(profileId: pid)!
        let expired = SyncStore.TombstoneDocument(
            schemaVersion: 1,
            conversationId: "conv-expired",
            profileId: pid,
            deletedAt: Date(timeIntervalSinceNow: -91 * 24 * 60 * 60)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(expired)
        let url = tombDir.appendingPathComponent("conv-expired.json")
        try data.write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // importAll 内部 processTombstones 触发清理
        _ = SyncStore.importAll(profileId: pid, context: contextB)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "过 90 天的墓碑应被自动清理")
    }

    // MARK: - 洞 6：跨楼层偷数据（同一个库里两个楼层撞同一个全库 unique id）

    /// 在指定楼层种一条真对话（3 节点）。
    @MainActor
    private func seedConversation(id: String, profileId: String, title: String, nodeIds: [String]) {
        let conv = Conversation(id: id, title: title, createTime: Date(timeIntervalSinceNow: -100),
                                updateTime: Date(timeIntervalSinceNow: -50), currentNodeId: nodeIds.last ?? "",
                                provider: "api", profileId: profileId)
        contextA.insert(conv)
        for nodeId in nodeIds {
            let node = MessageNode(id: nodeId, role: "user", content: "本地原文-\(nodeId)",
                                   contentType: "text", createTime: Date(), parentId: nil,
                                   childrenIds: [], conversationId: id, profileId: profileId)
            contextA.insert(node)
        }
        try? contextA.save()
    }

    /// 往 sync/<owner>/conversations/ 写一份属于 owner 楼层的对话文档。
    private func writeIncomingDocument(convId: String, owner: String, title: String, nodeIds: [String]) throws {
        let doc = SyncStore.ConversationDocument(
            schemaVersion: SyncStore.schemaVersion,
            conversationId: convId, profileId: owner, title: title,
            createTime: Date(timeIntervalSinceNow: -200), updateTime: Date(),
            currentNodeId: nodeIds.last ?? "", provider: "api",
            isFavorite: false, folderId: nil, pinnedAt: nil,
            memoryEnabled: true, selectedModelId: "",
            nodes: nodeIds.map { nodeId in
                SyncStore.NodeDocument(
                    id: nodeId, role: "user", content: "云端原文-\(nodeId)", contentType: "text",
                    createTime: Date(), parentId: nil, childrenIds: [],
                    isFavorite: false, isPinned: false, pinnedAt: nil, segmentsData: nil,
                    ccMessageId: nil, replyToId: nil, replyQuote: nil, ccEdited: false,
                    ccThinking: nil, imageDescsData: nil
                )
            },
            isDeleted: false, deletedAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let root = SyncStore.syncRoot(profileId: owner)!
        try encoder.encode(doc).write(to: root.appendingPathComponent("\(convId).json"))
    }

    @MainActor
    private func allConversations() -> [Conversation] {
        (try? contextA.fetch(FetchDescriptor<Conversation>())) ?? []
    }

    @MainActor
    private func allNodes() -> [MessageNode] {
        (try? contextA.fetch(FetchDescriptor<MessageNode>())) ?? []
    }

    /// 对话 id 撞楼层 A：以楼层 B 身份 importAll 必须整份跳过，不能把 A 的对话偷过来。
    @MainActor
    func testImportSkipsConversationOwnedByAnotherProfile() throws {
        seedConversation(id: "conv-xp", profileId: floorA, title: "A 楼层原标题",
                         nodeIds: ["xp-n1", "xp-n2", "xp-n3"])
        try writeIncomingDocument(convId: "conv-xp", owner: floorB, title: "B 楼层云端标题",
                                  nodeIds: ["xp-n1", "xp-n2", "xp-n3"])

        let result = SyncStore.importAll(profileId: floorB, context: contextA)

        XCTAssertEqual(result.conversationsSkippedCrossProfile, 1, "跨楼层冲突必须报数")
        XCTAssertEqual(result.conversationsCreated, 0, "冲突时不做部分 insert")
        XCTAssertEqual(result.nodesInserted, 0)

        let convs = allConversations()
        XCTAssertEqual(convs.count, 1)
        XCTAssertEqual(convs.first?.profileId, floorA, "对话仍属楼层 A")
        XCTAssertEqual(convs.first?.title, "A 楼层原标题", "属性未被云端改写")
        XCTAssertEqual(allNodes().count, 3)
        XCTAssertTrue(allNodes().allSatisfy { $0.profileId == floorA }, "节点也没被偷")
        XCTAssertTrue(allNodes().allSatisfy { $0.content.hasPrefix("本地原文") })
    }

    /// 对话 id 不撞、但某个**节点 id** 属于楼层 A：也要整份跳过（节点 insert 同样会 upsert 偷行）。
    @MainActor
    func testImportSkipsWhenNodeIdOwnedByAnotherProfile() throws {
        seedConversation(id: "conv-a-side", profileId: floorA, title: "A 楼层的对话",
                         nodeIds: ["shared-node"])
        try writeIncomingDocument(convId: "conv-b-side", owner: floorB, title: "B 楼层云端对话",
                                  nodeIds: ["shared-node"])

        let result = SyncStore.importAll(profileId: floorB, context: contextA)

        XCTAssertEqual(result.conversationsSkippedCrossProfile, 1)
        XCTAssertEqual(result.conversationsCreated, 0)
        XCTAssertEqual(result.nodesInserted, 0)
        XCTAssertEqual(allNodes().count, 1)
        XCTAssertEqual(allNodes().first?.profileId, floorA, "节点仍属楼层 A")
        XCTAssertEqual(allNodes().first?.conversationId, "conv-a-side", "节点没被改挂到 B 的对话下")
    }

    /// 同一个楼层内的正常导入不受跨楼层守卫影响（回归锚）。
    @MainActor
    func testImportSameProfileStillWorksWithGuard() throws {
        try writeIncomingDocument(convId: "conv-normal", owner: floorB, title: "云端新对话",
                                  nodeIds: ["nm-n1", "nm-n2"])

        let result = SyncStore.importAll(profileId: floorB, context: contextA)

        XCTAssertEqual(result.conversationsSkippedCrossProfile, 0)
        XCTAssertEqual(result.conversationsCreated, 1)
        XCTAssertEqual(result.nodesInserted, 2)
        XCTAssertEqual(allConversations().first?.profileId, floorB)
    }

    /// 墓碑路径的 scoped fetch（SyncStore.processTombstones）：
    /// 楼层 B 的墓碑不得删掉楼层 A 里同 id 的对话——「永久删赢」只在自己楼层内成立。
    @MainActor
    func testTombstoneDoesNotDeleteSameIdInAnotherProfile() throws {
        seedConversation(id: "conv-tomb-xp", profileId: floorA, title: "A 楼层的对话",
                         nodeIds: ["tomb-n1"])

        let tombDir = SyncStore.tombstoneRoot(profileId: floorB)!
        let tomb = SyncStore.TombstoneDocument(schemaVersion: 1, conversationId: "conv-tomb-xp",
                                               profileId: floorB, deletedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(tomb).write(to: tombDir.appendingPathComponent("conv-tomb-xp.json"))

        _ = SyncStore.importAll(profileId: floorB, context: contextA)

        XCTAssertEqual(allConversations().count, 1, "楼层 A 的对话没被别层墓碑杀掉")
        XCTAssertEqual(allConversations().first?.profileId, floorA)
        XCTAssertEqual(allNodes().count, 1)
    }
}
