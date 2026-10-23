import XCTest
import SwiftData
@testable import 记忆花园

/// #043 D10 回归护栏：ChatGPT / Claude 导入的写库语义（普通 / 叠加 / 跨楼层 / 副本 / 撤回）。
/// 先在旧的两套导入器上跑绿（0c），换成公用写库引擎后只改了 `runImport`，断言没动。
@MainActor
final class ImportRegressionTests: XCTestCase {

    enum Provider { case chatgpt, claude }

    struct Counts: Equatable {
        var added = 0, copied = 0, updated = 0, skipped = 0, ignored = 0, conflicts = 0
    }

    private var container: ModelContainer!
    private var workDir: URL!
    private let pA = "profile-aaaaaaaa"
    private let pB = "profile-bbbbbbbb"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: Conversation.self, MessageNode.self, FavoriteItem.self, UserCard.self,
            ImportRecord.self, ImportConversationChange.self, Memory.self, ConversationTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        workDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("import-reg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - 入口（重构时只改这里）

    private func runImport(_ provider: Provider, _ conversations: [[String: Any]], profileId: String,
                           merge: Bool = false, copyConflicts: Bool = false) async throws -> (Counts, UUID?) {
        let url = workDir.appendingPathComponent("\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: conversations).write(to: url)
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let record = ImportRecord(fileName: url.lastPathComponent, provider: provider == .claude ? "claude" : "chatgpt",
                                  mode: merge ? .merge : .normal, profileId: profileId)
        ctx.insert(record)
        let engine = try PayloadImportEngine(context: ctx, profileId: profileId, record: record,
                                             merge: merge, copyConflicts: copyConflicts)
        switch provider {
        case .chatgpt: try ImportRunner.importChatGPTFile(url, engine: engine)
        case .claude: try ImportRunner.importClaudeFile(url, folderIds: [:], engine: engine)
        }
        try ctx.save()
        let c = engine.counts
        return (Counts(added: c.added, copied: c.copied, updated: c.updated, skipped: c.skipped,
                       ignored: c.ignored, conflicts: c.conflicts), record.id)
    }

    // MARK: - 样本

    private func chatgpt(_ id: String, title: String = "标题", replies: [String] = ["你好"], update: Double = 1_700_000_100) -> [String: Any] {
        var mapping: [String: Any] = ["\(id)-root": ["id": "\(id)-root", "parent": NSNull(), "children": ["\(id)-u"]]]
        var prev = "\(id)-u"
        mapping[prev] = ["id": prev, "parent": "\(id)-root", "children": [],
                         "message": ["id": prev, "author": ["role": "user"], "create_time": 1_700_000_000,
                                     "content": ["content_type": "text", "parts": ["问题"]]]]
        for (i, reply) in replies.enumerated() {
            let nid = "\(id)-a\(i)"
            var p = mapping[prev] as! [String: Any]
            p["children"] = [nid]
            mapping[prev] = p
            mapping[nid] = ["id": nid, "parent": prev, "children": [],
                            "message": ["id": nid, "author": ["role": "assistant"], "create_time": 1_700_000_010 + Double(i),
                                        "content": ["content_type": "text", "parts": [reply]]]]
            prev = nid
        }
        return ["id": id, "title": title, "create_time": 1_700_000_000, "update_time": update,
                "current_node": prev, "mapping": mapping]
    }

    private func claude(_ id: String, title: String = "标题", replies: [String] = ["你好"], update: String = "2026-01-01T00:10:00.000000Z") -> [String: Any] {
        var msgs: [[String: Any]] = [[
            "uuid": "\(id)-u", "text": "", "sender": "human", "created_at": "2026-01-01T00:00:00.000000Z",
            "content": [["type": "text", "text": "问题"]], "attachments": [], "files": [],
            "parent_message_uuid": "00000000-0000-4000-8000-000000000000",
        ]]
        var prev = "\(id)-u"
        for (i, reply) in replies.enumerated() {
            let mid = "\(id)-a\(i)"
            msgs.append(["uuid": mid, "text": "", "sender": "assistant", "created_at": "2026-01-01T00:0\(i + 1):00.000000Z",
                         "content": [["type": "text", "text": reply]], "attachments": [], "files": [],
                         "parent_message_uuid": prev])
            prev = mid
        }
        return ["uuid": id, "name": title, "summary": "", "created_at": "2026-01-01T00:00:00.000000Z",
                "updated_at": update, "account": ["uuid": "acct"], "chat_messages": msgs]
    }

    private func sample(_ p: Provider, _ id: String, title: String = "标题", replies: [String] = ["你好"], newer: Bool = false) -> [String: Any] {
        switch p {
        case .chatgpt: return chatgpt(id, title: title, replies: replies, update: newer ? 1_700_000_900 : 1_700_000_100)
        case .claude: return claude(id, title: title, replies: replies, update: newer ? "2026-01-02T00:00:00.000000Z" : "2026-01-01T00:10:00.000000Z")
        }
    }

    // MARK: - 查询

    private func ctx() -> ModelContext { ModelContext(container) }

    private func conversations(_ profileId: String) throws -> [Conversation] {
        try ctx().fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == profileId }))
            .sorted { $0.id < $1.id }
    }

    private func nodes(_ conversationId: String, _ profileId: String) throws -> [MessageNode] {
        try ctx().fetch(FetchDescriptor<MessageNode>(predicate: #Predicate {
            $0.conversationId == conversationId && $0.profileId == profileId
        }))
    }

    private func record(_ id: UUID) throws -> ImportRecord? {
        try ctx().fetch(FetchDescriptor<ImportRecord>(predicate: #Predicate { $0.id == id })).first
    }

    /// 照 ImportHistoryView.undoImport 的做法撤回一次导入
    private func undo(_ recordId: UUID, _ profileId: String) throws {
        let c = ctx()
        let changes = try c.fetch(FetchDescriptor<ImportConversationChange>(predicate: #Predicate {
            $0.recordId == recordId && $0.profileId == profileId
        }))
        for change in changes { try restoreConversationChange(change, in: c) }
        for change in changes { c.delete(change) }
        if let r = try c.fetch(FetchDescriptor<ImportRecord>(predicate: #Predicate { $0.id == recordId })).first {
            c.delete(r)
        }
        try c.save()
    }

    // MARK: - 用例（两家各跑一遍）

    func testNormalImportThenReimportSkips() async throws {
        for p in [Provider.chatgpt, .claude] {
            try await resetStore()
            let (first, rid) = try await runImport(p, [sample(p, "x1"), sample(p, "x2")], profileId: pA)
            XCTAssertEqual(first, Counts(added: 2), "\(p)")
            XCTAssertEqual(try conversations(pA).map(\.id), ["x1", "x2"], "\(p)")
            let r = try XCTUnwrap(record(try XCTUnwrap(rid)))
            XCTAssertTrue(r.supportsUndo, "\(p)")
            XCTAssertEqual(r.addedConversationCount, 2, "\(p)")

            let (second, _) = try await runImport(p, [sample(p, "x1"), sample(p, "x2")], profileId: pA)
            XCTAssertEqual(second, Counts(skipped: 2), "\(p)")
        }
    }

    func testNormalImportUndoRemovesConversations() async throws {
        for p in [Provider.chatgpt, .claude] {
            try await resetStore()
            let (_, rid) = try await runImport(p, [sample(p, "x1")], profileId: pA)
            XCTAssertFalse(try nodes("x1", pA).isEmpty, "\(p)")
            try undo(try XCTUnwrap(rid), pA)
            XCTAssertTrue(try conversations(pA).isEmpty, "\(p)")
            XCTAssertTrue(try nodes("x1", pA).isEmpty, "\(p)")
        }
    }

    func testMergeUpdatesChangedAndUndoRestores() async throws {
        for p in [Provider.chatgpt, .claude] {
            try await resetStore()
            _ = try await runImport(p, [sample(p, "x1"), sample(p, "x2")], profileId: pA)
            let before = try nodes("x1", pA).count

            let (merged, rid) = try await runImport(
                p, [sample(p, "x1", title: "新标题", replies: ["你好", "再见"], newer: true), sample(p, "x2")],
                profileId: pA, merge: true)
            XCTAssertEqual(merged, Counts(updated: 1, skipped: 1), "\(p)")
            XCTAssertEqual(try nodes("x1", pA).count, before + 1, "\(p)")
            XCTAssertEqual(try conversations(pA).first { $0.id == "x1" }?.title, "新标题", "\(p)")

            try undo(try XCTUnwrap(rid), pA)
            XCTAssertEqual(try nodes("x1", pA).count, before, "\(p) 撤回后节点数回到合并前")
            XCTAssertEqual(try conversations(pA).first { $0.id == "x1" }?.title, "标题", "\(p) 撤回后标题回到合并前")
        }
    }

    func testMergeAddsNewConversations() async throws {
        for p in [Provider.chatgpt, .claude] {
            try await resetStore()
            _ = try await runImport(p, [sample(p, "x1")], profileId: pA)
            let (merged, _) = try await runImport(p, [sample(p, "x1"), sample(p, "x9")], profileId: pA, merge: true)
            XCTAssertEqual(merged, Counts(added: 1, skipped: 1), "\(p)")
        }
    }

    func testCrossProfileConflictSkipsOrCopies() async throws {
        for p in [Provider.chatgpt, .claude] {
            try await resetStore()
            _ = try await runImport(p, [sample(p, "x1")], profileId: pB)

            let (skipped, _) = try await runImport(p, [sample(p, "x1")], profileId: pA)
            XCTAssertEqual(skipped, Counts(conflicts: 1), "\(p) 冲突不再算在未导入里（#061）")
            XCTAssertTrue(try conversations(pA).isEmpty, "\(p)")
            XCTAssertEqual(try conversations(pB).map(\.id), ["x1"], "\(p) 别的楼层不被抢")

            let (copied, _) = try await runImport(p, [sample(p, "x1")], profileId: pA, copyConflicts: true)
            XCTAssertEqual(copied, Counts(copied: 1), "\(p)")
            XCTAssertEqual(try conversations(pA).map(\.id), [copyId("x1", profileId: pA)], "\(p)")

            let (again, _) = try await runImport(p, [sample(p, "x1")], profileId: pA, copyConflicts: true)
            XCTAssertEqual(again, Counts(skipped: 1), "\(p) 副本不翻倍")
            XCTAssertEqual(try conversations(pB).map(\.id), ["x1"], "\(p)")
        }
    }

    func testClaudeEmptyConversationIgnored() async throws {
        try await resetStore()
        var empty = claude("e1")
        empty["chat_messages"] = []
        let (counts, _) = try await runImport(.claude, [empty, claude("x1")], profileId: pA)
        XCTAssertEqual(counts, Counts(added: 1, ignored: 1))
    }

    private func resetStore() async throws {
        container = try ModelContainer(
            for: Conversation.self, MessageNode.self, FavoriteItem.self, UserCard.self,
            ImportRecord.self, ImportConversationChange.self, Memory.self, ConversationTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
