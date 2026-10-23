import XCTest
import SwiftData
@testable import 记忆花园

final class SearchIndexerTests: XCTestCase {

    var dir: URL!
    var url: URL!
    var container: ModelContainer!
    var indexer: SearchIndexer!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("search-indexer-\(UUID().uuidString)")
        url = dir.appendingPathComponent("idx.sqlite")
        container = try ModelContainer(for: Conversation.self, MessageNode.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() {
        indexer = nil
        container = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func seed(_ count: Int, conv: String = "c1", pid: String = "p1", prefix: String = "n",
                      created: (Int) -> Date? = { _ in Date(timeIntervalSince1970: 1000) }, content: (Int) -> String) throws {
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        if try ctx.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conv })) == 0 {
            ctx.insert(Conversation(id: conv, title: conv, createTime: Date(), updateTime: Date(), currentNodeId: "", profileId: pid))
        }
        for i in 0..<count {
            ctx.insert(MessageNode(id: String(format: "\(prefix)%04d", i), role: i % 2 == 0 ? "user" : "assistant",
                                   content: content(i), contentType: "text", createTime: created(i), parentId: nil,
                                   childrenIds: [], conversationId: conv, profileId: pid))
        }
        try ctx.save()
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("超时：\(what)"); return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func startAndWaitReady(profileIds: [String] = ["p1"]) -> SearchIndexStore {
        indexer = SearchIndexer(url: url)
        indexer.start(container: container, profileIds: profileIds)
        waitUntil("ready") { indexer.readyStore != nil && indexer.state.status == .ready }
        return indexer.readyStore!
    }

    private func hitIds(_ store: SearchIndexStore, _ word: String, pid: String = "p1") -> Set<String> {
        Set(((try? store.hits(word: word, profileId: pid, roles: ["user", "assistant"])) ?? nil)?.map(\.nodeId) ?? [])
    }

    func testBackfillIndexesAllWithNilAndSameCreateTime() throws {
        try seed(1234, created: { $0 % 3 == 0 ? nil : Date(timeIntervalSince1970: 1000) }, content: { "第\($0)条 苹果" })
        let store = startAndWaitReady()
        XCTAssertEqual(store.docCount(), 1234)
        XCTAssertEqual(hitIds(store, "苹果").count, 1234)
        XCTAssertEqual(store.meta("backfill_done"), "1")
        XCTAssertNil(store.meta("cursor"))
    }

    func testBackfillResumesFromCursor() throws {
        try seed(600, conv: "c1", prefix: "a", content: { _ in "香蕉" })
        try seed(600, conv: "c2", prefix: "b", content: { _ in "香蕉" })
        do {
            let pre = try SearchIndexStore.open(at: url)
            try pre.apply(upserts: [], meta: ["cursor": "c1", "processed": "600"], epoch: pre.epoch)
        }
        let store = startAndWaitReady()
        // 游标之前的对话 c1 这次回填不碰；对账发现楼层计数不一致后逐对话补齐
        waitUntil("reconcile fills") { store.docCount() == 1200 }
        XCTAssertEqual(hitIds(store, "香蕉").count, 1200)
    }

    func testBackfillMixedCaseIdsCoversAll() throws {
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        for c in 0..<40 {
            let convId = c % 2 == 0 ? UUID().uuidString : UUID().uuidString.lowercased()
            ctx.insert(Conversation(id: convId, title: "t", createTime: Date(), updateTime: Date(), currentNodeId: "", profileId: "p1"))
            for i in 0..<30 {
                let id = i % 2 == 0 ? UUID().uuidString : UUID().uuidString.lowercased()
                ctx.insert(MessageNode(id: id, role: "user", content: "葡萄", contentType: "text", createTime: nil, parentId: nil,
                                       childrenIds: [], conversationId: convId, profileId: "p1"))
            }
        }
        try ctx.save()
        let store = startAndWaitReady()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(store.docCount(), 1200)
        // 回填按顺序写行号 1…1200；对账补过的对话会重插出更大的行号 → 最大行号 = 1200 说明回填本身没漏
        let db = try SQLiteDB(url: url, readOnly: true)
        XCTAssertEqual(try db.scalarInt("SELECT MAX(id) FROM doc"), 1200)
    }

    func testThinkingStrippedForAssistantOnly() throws {
        try seed(2, content: { _ in "[thinking]内心戏[/thinking]正文" })
        let store = startAndWaitReady()
        XCTAssertEqual(hitIds(store, "内心戏"), ["n0000"], "user 不剥，assistant 剥")
        XCTAssertEqual(hitIds(store, "正文"), ["n0000", "n0001"])
    }

    func testIncrementalInsertUpdateDeleteViaDidSave() throws {
        try seed(3, content: { _ in "旧内容" })
        let store = startAndWaitReady()
        try seed(1, prefix: "new", content: { _ in "刚发的消息" })
        waitUntil("insert") { hitIds(store, "刚发的") == ["new0000"] }

        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let n = try XCTUnwrap(ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == "n0001" })).first)
        n.content = "编辑过的内容"
        try ctx.save()
        waitUntil("update") { hitIds(store, "编辑过") == ["n0001"] && !hitIds(store, "旧内容").contains("n0001") }

        n.isTrashed = true
        try ctx.save()
        waitUntil("trash") { hitIds(store, "编辑过").isEmpty }

        let gone = try XCTUnwrap(ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == "n0002" })).first)
        ctx.delete(gone)
        try ctx.save()
        waitUntil("delete") { store.bodies(nodeIdsOrEmpty: ["n0002"]).isEmpty }
    }

    func testProfileDeletedDropsDocs() throws {
        try seed(5, pid: "p1", content: { _ in "葡萄" })
        try seed(5, conv: "c2", pid: "p2", prefix: "q", content: { _ in "葡萄" })
        let store = startAndWaitReady(profileIds: ["p1", "p2"])
        let ctx = ModelContext(container)
        try ctx.delete(model: MessageNode.self, where: #Predicate { $0.profileId == "p1" })
        try ctx.save()
        indexer.profileDeleted("p1")
        waitUntil("profile gone") { hitIds(store, "葡萄", pid: "p1").isEmpty }
        XCTAssertEqual(hitIds(store, "葡萄", pid: "p2").count, 5)
    }

    func testReconcileRepairsMissingAndExtraRows() throws {
        try seed(10, content: { _ in "西瓜" })
        let store = startAndWaitReady()
        try store.apply(upserts: [SearchIndexDoc(nodeId: "ghost", conversationId: "c9", profileId: "p1", role: "user",
                                                 created: nil, trashed: false, body: "西瓜", identifierKey: nil)],
                        deleteNodeIds: ["n0003", "n0004"], epoch: store.epoch)
        XCTAssertEqual(hitIds(store, "西瓜").count, 9)
        indexer.requestReconcile()
        waitUntil("reconciled") { hitIds(store, "西瓜") == Set((0..<10).map { String(format: "n%04d", $0) }) }
    }

    func testMarkDirtyRebuildsConversationInPlaceEdit() throws {
        try seed(4, content: { _ in "柠檬" })
        let store = startAndWaitReady()
        try store.apply(upserts: [SearchIndexDoc(nodeId: "n0000", conversationId: "c1", profileId: "p1", role: "user",
                                                 created: Date(timeIntervalSince1970: 1000), trashed: false,
                                                 body: "过期正文", identifierKey: nil)], epoch: store.epoch)
        XCTAssertEqual(hitIds(store, "柠檬").count, 3)
        indexer.markDirty(conversationIds: ["c1"])
        waitUntil("dirty rebuilt") { hitIds(store, "柠檬").count == 4 && hitIds(store, "过期").isEmpty }
    }

    func testRebuildStartsOver() throws {
        try seed(20, content: { _ in "草莓" })
        let store = startAndWaitReady()
        indexer.rebuild()
        waitUntil("rebuilt") { indexer.readyStore != nil && store.docCount() == 20 && store.meta("backfill_done") == "1" }
        XCTAssertEqual(hitIds(store, "草莓").count, 20)
    }
}

private extension SearchIndexStore {
    func bodies(nodeIdsOrEmpty ids: [String]) -> [String: String] {
        (try? bodies(nodeIds: ids)) ?? [:]
    }

}
