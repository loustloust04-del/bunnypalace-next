import XCTest
@testable import 记忆花园

final class SearchIndexStoreTests: XCTestCase {

    var dir: URL!
    var url: URL!
    var store: SearchIndexStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("search-index-\(UUID().uuidString)")
        url = dir.appendingPathComponent("idx.sqlite")
        store = try SearchIndexStore.open(at: url)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func doc(_ id: String, conv: String = "c1", pid: String = "p1", role: String = "user",
                     created: Date? = Date(timeIntervalSince1970: 1000), trashed: Bool = false,
                     _ body: String, key: String? = nil) -> SearchIndexDoc {
        SearchIndexDoc(nodeId: id, conversationId: conv, profileId: pid, role: role, created: created,
                       trashed: trashed, body: body, identifierKey: key)
    }

    private func ids(_ word: String, pid: String = "p1", roles: Set<String> = ["user", "assistant"],
                     interval: (start: Date, end: Date)? = nil, scope: Set<String>? = nil) throws -> Set<String> {
        Set(try XCTUnwrap(store.hits(word: word, profileId: pid, roles: roles, interval: interval, scope: scope)).map(\.nodeId))
    }

    func testPhrasePrefixAndCJKSubstring() throws {
        try store.apply(upserts: [
            doc("n1", "我今天换了新键盘"),
            doc("n2", "SwiftUI 很好用"),
            doc("n3", "键 和 盘 分开"),
            doc("n4", "OpenAPI 文档"),
            doc("n5", "Café crème"),
        ], epoch: store.epoch)
        XCTAssertEqual(try ids("键盘"), ["n1"])
        XCTAssertEqual(try ids("swift"), ["n2"])
        XCTAssertEqual(try ids("SWIFTUI"), ["n2"])
        XCTAssertEqual(try ids("API"), [], "D2：拉丁中间片段不命中")
        XCTAssertEqual(try ids("openapi"), ["n4"])
        XCTAssertEqual(try ids("cafe"), ["n5"], "remove_diacritics 2 与 localizedStandardContains 同样不分重音")
        XCTAssertNil(try store.hits(word: "😀", profileId: "p1", roles: ["user"]))
    }

    func testCrossPunctuationHits() throws {
        try store.apply(upserts: [doc("n1", "我爱，你"), doc("n2", "我爱\n你"), doc("n3", "我不爱你")], epoch: store.epoch)
        XCTAssertEqual(try ids("我爱你"), ["n1", "n2"])
    }

    func testNodeLevelFilters() throws {
        try store.apply(upserts: [
            doc("u", role: "user", "苹果"),
            doc("a", role: "assistant", "苹果"),
            doc("t", trashed: true, "苹果"),
            doc("nil", created: nil, "苹果"),
            doc("old", created: Date(timeIntervalSince1970: 10), "苹果"),
            doc("other", conv: "c2", "苹果"),
            doc("otherPid", pid: "p2", "苹果"),
        ], epoch: store.epoch)
        XCTAssertEqual(try ids("苹果"), ["u", "a", "nil", "old", "other"])
        XCTAssertEqual(try ids("苹果", roles: ["assistant"]), ["a"])
        XCTAssertEqual(try ids("苹果", roles: []), [])
        let interval = (start: Date(timeIntervalSince1970: 500), end: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(try ids("苹果", interval: interval), ["u", "a", "other"], "有区间时 created nil 排除")
        XCTAssertEqual(try ids("苹果", scope: ["c2"]), ["other"])
        XCTAssertEqual(try ids("苹果", scope: []), [])
        let grouped = try XCTUnwrap(store.conversations(word: "苹果", profileId: "p1", roles: ["user", "assistant"]))
        XCTAssertEqual(Set(grouped.keys), ["c1", "c2"])
        XCTAssertEqual(try store.bodies(nodeIds: ["u", "missing"]), ["u": "苹果"])
    }

    func testUpdateAndDeleteKeepFTSInSync() throws {
        try store.apply(upserts: [doc("n1", "香蕉")], epoch: store.epoch)
        try store.apply(upserts: [doc("n1", "橙子")], epoch: store.epoch)
        XCTAssertEqual(try ids("香蕉"), [])
        XCTAssertEqual(try ids("橙子"), ["n1"])
        try store.apply(upserts: [doc("n1", trashed: true, "橙子")], epoch: store.epoch)
        XCTAssertEqual(try ids("橙子"), [])
        try store.apply(upserts: [], deleteNodeIds: ["n1"], epoch: store.epoch)
        XCTAssertEqual(store.docCount(), 0)
        try store.apply(upserts: [doc("n2", "橙子")], epoch: store.epoch)
        XCTAssertEqual(try ids("橙子"), ["n2"])
    }

    func testStaleEpochBatchDropped() throws {
        let old = store.epoch
        try store.deleteProfile("p9")
        XCTAssertFalse(try store.apply(upserts: [doc("n1", "旧批")], epoch: old))
        XCTAssertEqual(store.docCount(), 0)
        XCTAssertTrue(try store.apply(upserts: [doc("n1", "新批")], epoch: store.epoch))
    }

    func testDeleteProfileRemovesDocsAndFTS() throws {
        try store.apply(upserts: [doc("a", pid: "p1", "葡萄"), doc("b", pid: "p2", "葡萄")], epoch: store.epoch)
        try store.deleteProfile("p1")
        XCTAssertEqual(try ids("葡萄", pid: "p1"), [])
        XCTAssertEqual(try ids("葡萄", pid: "p2"), ["b"])
    }

    func testReplaceConversationAndDirty() throws {
        try store.apply(upserts: [doc("a", "西瓜"), doc("b", "西瓜"), doc("x", conv: "c2", "西瓜")], epoch: store.epoch)
        try store.markDirty(["c1"])
        XCTAssertEqual(store.dirtyConversations(), ["c1"])
        try store.replaceConversation("c1", with: [doc("c", "西瓜")], epoch: store.epoch)
        XCTAssertEqual(try ids("西瓜"), ["c", "x"])
        XCTAssertEqual(store.dirtyConversations(), [])
        let stats = try store.conversationStats(profileId: "p1")
        XCTAssertEqual(stats["c1"], SearchIndexStats(count: 1, maxCreatedMillis: 1_000_000))
    }

    func testIdentifierLookup() throws {
        try store.apply(upserts: [doc("a", "x", key: "K1")], epoch: store.epoch)
        let found = try store.nodes(forIdentifierKeys: ["K1", "K2"])
        XCTAssertEqual(found["K1"]?.nodeId, "a")
        XCTAssertNil(found["K2"])
    }

    func testResetClearsEverything() throws {
        try store.apply(upserts: [doc("a", "草莓")], meta: ["backfill_done": "1"], epoch: store.epoch)
        let before = store.epoch
        try store.reset()
        XCTAssertEqual(store.docCount(), 0)
        XCTAssertNil(store.meta("backfill_done"))
        XCTAssertEqual(store.epoch, before + 1)
        XCTAssertEqual(try ids("草莓"), [])
    }

    func testReopenKeepsDataAndVersionMismatchRebuilds() throws {
        try store.apply(upserts: [doc("a", "柠檬")], epoch: store.epoch)
        store = nil
        store = try SearchIndexStore.open(at: url)
        XCTAssertEqual(try ids("柠檬"), ["a"])
        store = nil
        do {
            let raw = try SQLiteDB(url: url)
            try raw.exec("UPDATE meta SET value = '0' WHERE key = 'version'")
        }
        store = try SearchIndexStore.open(at: url)
        XCTAssertEqual(store.docCount(), 0, "版本不符 → 删文件重建")
    }

    func testCorruptFileRebuilds() throws {
        store = nil
        SearchIndexStore.removeFiles(at: url)
        try Data(repeating: 0x42, count: 8192).write(to: url)
        store = try SearchIndexStore.open(at: url)
        XCTAssertEqual(store.docCount(), 0)
        try store.apply(upserts: [doc("a", "恢复")], epoch: store.epoch)
        XCTAssertEqual(try ids("恢复"), ["a"])
    }
}
