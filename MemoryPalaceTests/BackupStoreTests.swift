import XCTest
import SwiftData
@testable import 记忆花园

/// 洞 6（备份还原分支）：`Conversation.id` 是全库 unique、`profileId` 只是普通列。
/// `BackupStore.restoreConversation` 按 `id == convId && profileId == 目标楼层` 查重，
/// 同 id 在**另一个楼层**时查不到 → insert → SwiftData unique 冲突静默 upsert →
/// 整行属性（含 profileId）被改写 = 对话被从原楼层偷走。
///
/// 这里种「楼层 A 有对话 X」+「备份说 X 属于楼层 B」，走三档粒度还原钉死行为：
/// 单对话 / 单楼层 → 整份跳过并报数；整库还原 → 保持既有覆盖语义（备份是全局真相）。
final class BackupStoreTests: XCTestCase {

    let floorA = "xctest-backup-A"
    let floorB = "xctest-backup-B"
    let date = "2026-09-02"
    let convId = "conv-backup-xp"

    var container: ModelContainer!
    var context: ModelContext!
    var tempRoot: URL!

    @MainActor
    override func setUp() {
        super.setUp()
        container = try! ModelContainer(
            for: Conversation.self, MessageNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-test-\(UUID().uuidString)")
        BackupStore.overrideRoot = tempRoot
    }

    override func tearDown() {
        BackupStore.overrideRoot = nil
        try? FileManager.default.removeItem(at: tempRoot)
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// 楼层 A 里种一条真对话（3 个节点），返回它。
    @MainActor
    @discardableResult
    private func seedLiveConversation(profileId: String, title: String) -> Conversation {
        let conv = Conversation(id: convId, title: title,
                                createTime: Date(timeIntervalSinceNow: -100),
                                updateTime: Date(timeIntervalSinceNow: -50),
                                currentNodeId: "\(convId)-a1", provider: "api", profileId: profileId)
        context.insert(conv)
        for (nodeId, role, parent, children) in [
            ("root", "system", nil, ["a1"]),
            ("u1", "user", "root" as String?, ["a1"]),
            ("a1", "assistant", "u1", [String]())
        ] {
            let node = MessageNode(id: "\(convId)-\(nodeId)", role: role, content: "A 楼层原文-\(nodeId)",
                                   contentType: "text", createTime: Date(),
                                   parentId: parent.map { "\(convId)-\($0)" },
                                   childrenIds: children.map { "\(convId)-\($0)" },
                                   conversationId: convId, profileId: profileId)
            context.insert(node)
        }
        try? context.save()
        return conv
    }

    /// 往备份目录里写「楼层 <owner> 拥有 convId」的一天备份。
    /// extraEmptyProfiles 里的楼层也进 day-manifest（对话列表为空），用来构造整库还原的范围。
    private func seedBackup(owner: String, extraEmptyProfiles: [String] = []) throws {
        let doc = SyncStore.ConversationDocument(
            schemaVersion: SyncStore.schemaVersion,
            conversationId: convId,
            profileId: owner,
            title: "备份里的标题",
            createTime: Date(timeIntervalSinceNow: -200),
            updateTime: Date(timeIntervalSinceNow: -10),
            currentNodeId: "\(convId)-a1",
            provider: "api",
            isFavorite: false,
            folderId: nil,
            pinnedAt: nil,
            memoryEnabled: true,
            selectedModelId: "",
            nodes: [
                SyncStore.NodeDocument(
                    id: "\(convId)-root", role: "system", content: "备份原文-root", contentType: "text",
                    createTime: Date(), parentId: nil, childrenIds: ["\(convId)-a1"],
                    isFavorite: false, isPinned: false, pinnedAt: nil, segmentsData: nil,
                    ccMessageId: nil, replyToId: nil, replyQuote: nil, ccEdited: false,
                    ccThinking: nil, imageDescsData: nil
                ),
                SyncStore.NodeDocument(
                    id: "\(convId)-a1", role: "assistant", content: "备份原文-a1", contentType: "text",
                    createTime: Date(), parentId: "\(convId)-root", childrenIds: [],
                    isFavorite: false, isPinned: false, pinnedAt: nil, segmentsData: nil,
                    ccMessageId: nil, replyToId: nil, replyQuote: nil, ccEdited: false,
                    ccThinking: nil, imageDescsData: nil
                )
            ],
            isDeleted: false,
            deletedAt: nil
        )
        let data = try encoder.encode(doc)
        let convDir = tempRoot.appendingPathComponent(date, isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
        try data.write(to: convDir.appendingPathComponent("\(convId).json"))

        var day = DayManifest(date: date)
        day.profiles.append(ProfileBackup(
            profileId: owner, floorName: "备份楼层", floorEmoji: "🏠",
            conversations: [ConversationRef(conversationId: convId, title: "备份里的标题",
                                            nodeCount: doc.nodes.count,
                                            updateTime: doc.updateTime,
                                            sizeBytes: data.count, sha256: "test")]
        ))
        for pid in extraEmptyProfiles {
            day.profiles.append(ProfileBackup(profileId: pid, floorName: "空楼层", floorEmoji: "🏠",
                                             conversations: []))
        }
        let dayDir = tempRoot.appendingPathComponent(date, isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try encoder.encode(day).write(to: dayDir.appendingPathComponent(".day-manifest.json"))
    }

    @MainActor
    private func conversations() -> [Conversation] {
        (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
    }

    @MainActor
    private func nodes() -> [MessageNode] {
        (try? context.fetch(FetchDescriptor<MessageNode>())) ?? []
    }

    // MARK: - 洞 6

    /// 单对话粒度：以楼层 B 身份还原 X，X 实际在楼层 A → 整份跳过，A 的数据一动不动。
    @MainActor
    func testRestoreSingleConversationSkipsCrossProfileConflict() throws {
        seedLiveConversation(profileId: floorA, title: "A 楼层原标题")
        try seedBackup(owner: floorB)

        let result = try BackupStore.restore(
            date: date, scope: .conversation(profileId: floorB, convId: convId), context: context
        )

        XCTAssertEqual(result.conversationsSkippedCrossProfile, 1, "跨楼层冲突必须报数")
        XCTAssertEqual(result.conversationsRestored, 0, "冲突时不做部分 insert")

        let convs = conversations()
        XCTAssertEqual(convs.count, 1)
        XCTAssertEqual(convs.first?.profileId, floorA, "对话必须仍属楼层 A（没被偷到 B）")
        XCTAssertEqual(convs.first?.title, "A 楼层原标题", "属性未被备份改写")
        XCTAssertTrue(nodes().allSatisfy { $0.profileId == floorA }, "节点也没被偷")
        XCTAssertEqual(nodes().count, 3, "节点数不变")
        XCTAssertTrue(nodes().allSatisfy { $0.content.hasPrefix("A 楼层原文") }, "节点内容未被备份改写")
    }

    /// 单楼层粒度：同上，走 .profile scope。
    @MainActor
    func testRestoreProfileScopeSkipsCrossProfileConflict() throws {
        seedLiveConversation(profileId: floorA, title: "A 楼层原标题")
        try seedBackup(owner: floorB)

        let result = try BackupStore.restore(
            date: date, scope: .profile(profileId: floorB), context: context
        )

        XCTAssertEqual(result.conversationsSkippedCrossProfile, 1)
        XCTAssertEqual(result.conversationsRestored, 0)
        XCTAssertEqual(conversations().first?.profileId, floorA)
        XCTAssertEqual(conversations().first?.title, "A 楼层原标题")
        XCTAssertTrue(nodes().allSatisfy { $0.profileId == floorA })
    }

    /// 整库还原：备份是全局真相，两个楼层都在还原范围内 → 保持既有覆盖语义（对话归到备份说的楼层）。
    /// ⧫ plan：「全库还原若语义上允许覆盖 profile 归属，保持不变，单独一测。」
    @MainActor
    func testRestoreEverythingKeepsOverwriteSemantics() throws {
        seedLiveConversation(profileId: floorA, title: "A 楼层原标题")
        try seedBackup(owner: floorB, extraEmptyProfiles: [floorA])

        let result = try BackupStore.restore(date: date, scope: .everything, context: context)

        XCTAssertEqual(result.conversationsSkippedCrossProfile, 0, "冲突方也在还原范围内，不算偷")
        XCTAssertEqual(result.conversationsRestored, 1)
        let convs = conversations()
        XCTAssertEqual(convs.count, 1)
        XCTAssertEqual(convs.first?.profileId, floorB, "整库还原按备份归属")
        XCTAssertEqual(convs.first?.title, "备份里的标题")
    }

    /// 整库还原但冲突方**不在**备份里（备份之后新建的楼层）→ 仍然整份跳过，不偷。
    @MainActor
    func testRestoreEverythingStillSkipsProfileOutsideBackup() throws {
        seedLiveConversation(profileId: floorA, title: "A 楼层原标题")
        try seedBackup(owner: floorB)   // day-manifest 里只有 floorB

        let result = try BackupStore.restore(date: date, scope: .everything, context: context)

        XCTAssertEqual(result.conversationsSkippedCrossProfile, 1)
        XCTAssertEqual(conversations().first?.profileId, floorA)
        XCTAssertEqual(conversations().first?.title, "A 楼层原标题")
    }

    /// 无冲突的正常还原不受影响（回归锚）。
    @MainActor
    func testRestoreWithoutConflictStillRestores() throws {
        try seedBackup(owner: floorB)

        let result = try BackupStore.restore(
            date: date, scope: .profile(profileId: floorB), context: context
        )

        XCTAssertEqual(result.conversationsSkippedCrossProfile, 0)
        XCTAssertEqual(result.conversationsRestored, 1)
        XCTAssertEqual(result.nodesInserted, 2)
        XCTAssertEqual(conversations().first?.profileId, floorB)
        XCTAssertEqual(conversations().first?.title, "备份里的标题")
    }
}
