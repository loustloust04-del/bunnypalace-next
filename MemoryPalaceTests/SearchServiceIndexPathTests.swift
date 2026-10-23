import XCTest
import SwiftData
@testable import 记忆花园

/// S5 B 段：SearchService 走索引找正文候选（plan-search-s5 设计 3）。内存 ModelContainer + 临时索引文件，
/// 每条用例同一 filter 跑索引路径和旧扫描（index: nil）对比；fixture 避开 D2 / D3（拉丁词中间片段、思考链）
final class SearchServiceIndexPathTests: XCTestCase {

    let pid = "xctest-s5-index"
    var container: ModelContainer!
    var context: ModelContext!
    var dir: URL!
    var store: SearchIndexStore!

    @MainActor
    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: config)
        context = ModelContext(container)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("search-s5-b-\(UUID().uuidString)")
        store = try SearchIndexStore.open(at: dir.appendingPathComponent("idx.sqlite"))
    }

    override func tearDown() {
        store = nil
        container = nil
        context = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - Fixtures

    private let day1 = Date(timeIntervalSince1970: 1_700_000_000)
    private var day2: Date { day1.addingTimeInterval(86_400 * 3) }

    /// c1：a1 → a2 →┬ a3（当前，主线）
    ///                └ a4（分支）
    /// a5 = a3 的孩子，节点进了回收站
    /// c2：b1 → b2，「苹果」和「香蕉」分在两条消息里（对话级 AND 成立、消息级不成立）；b3 createTime = nil
    /// c3：d1，只有「苹果」；c4：进了回收站的对话；c5：标题含「香蕉」，正文只有「苹果」
    private func seed() throws {
        conv("c1", title: "工作笔记", current: "a3", updated: 5000)
        node("a1", "user", "苹果 主线问题", parent: nil, children: ["a2"], conv: "c1", at: day1)
        node("a2", "assistant", "主线回答有苹果和香蕉", parent: "a1", children: ["a3", "a4"], conv: "c1", at: day1)
        node("a3", "user", "苹果 主线跟进", parent: "a2", children: ["a5"], conv: "c1", at: day2)
        node("a4", "assistant", "苹果 分支内容 香蕉", parent: "a2", children: [], conv: "c1", at: day2)
        node("a5", "assistant", "苹果 已删节点", parent: "a3", children: [], conv: "c1", at: day2, trashed: true)

        conv("c2", title: "水果清单", current: "b3", updated: 4000)
        node("b1", "user", "我想买苹果", parent: nil, children: ["b2"], conv: "c2", at: day1)
        node("b2", "assistant", "香蕉也不错", parent: "b1", children: ["b3"], conv: "c2", at: day1)
        node("b3", "user", "那就苹果吧", parent: "b2", children: [], conv: "c2", at: nil)

        conv("c3", title: "随便聊聊", current: "d1", updated: 3000)
        node("d1", "assistant", "只有苹果", parent: nil, children: [], conv: "c3", at: day2)

        conv("c4", title: "旧对话", current: "e1", updated: 2000, trashed: true)
        node("e1", "user", "回收站里的苹果和香蕉", parent: nil, children: [], conv: "c4", at: day1)

        conv("c5", title: "香蕉日记", current: "f1", updated: 1000)
        node("f1", "user", "今天吃了苹果", parent: nil, children: [], conv: "c5", at: day1)

        try context.save()
        let nodes = try context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.profileId == "xctest-s5-index" }))
        try store.apply(upserts: nodes.map { n in
            SearchIndexDoc(nodeId: n.id, conversationId: n.conversationId, profileId: n.profileId, role: n.role,
                           created: n.createTime, trashed: n.isTrashed,
                           body: ContentCleaner.visibleText(n.content, isUser: n.role == "user", cacheKey: n.id, cached: false),
                           identifierKey: nil)
        }, epoch: store.epoch)
    }

    private func conv(_ id: String, title: String, current: String, updated: TimeInterval, trashed: Bool = false) {
        let c = Conversation(id: id, title: title, createTime: day1, updateTime: Date(timeIntervalSince1970: updated),
                             currentNodeId: current, profileId: pid)
        c.isTrashed = trashed
        context.insert(c)
    }

    private func node(_ id: String, _ role: String, _ content: String, parent: String?, children: [String],
                      conv: String, at: Date?, trashed: Bool = false) {
        let n = MessageNode(id: id, role: role, content: content, contentType: "text", createTime: at,
                            parentId: parent, childrenIds: children, conversationId: conv, profileId: pid)
        n.isTrashed = trashed
        context.insert(n)
    }

    private func filter(_ words: [String], scope: SearchScope = .contentOnly, sort: SearchSort = .recent) -> SearchFilter {
        var f = SearchFilter()
        f.words = words
        f.keyword = words.max { $0.count < $1.count } ?? ""
        f.scope = scope
        f.sortOrder = sort
        return f
    }

    private func run(_ f: SearchFilter, index: Bool) async throws -> SearchBuckets {
        let buckets = await SearchService.searchConversationBuckets(filter: f, profileId: pid, container: container,
                                                                    index: index ? store : nil)
        return try XCTUnwrap(buckets)
    }

    /// 行 id（有序）+ 每行命中消息 id
    private func shape(_ rows: [SearchResult]) -> [String] {
        rows.map { "\($0.id)=\($0.matchedNodes.map(\.id).sorted().joined(separator: ","))" }
    }

    private func nodeIds(_ rows: [SearchResult]) -> Set<String> {
        Set(rows.flatMap { $0.matchedNodes.map(\.id) })
    }

    /// 两条路径逐标签一致（顺序也比），返回索引路径的结果
    @discardableResult
    private func assertSame(_ f: SearchFilter, file: StaticString = #filePath, line: UInt = #line) async throws -> SearchBuckets {
        let viaIndex = try await run(f, index: true)
        let viaScan = try await run(f, index: false)
        XCTAssertTrue(viaIndex.usedIndex, file: file, line: line)
        XCTAssertFalse(viaScan.usedIndex, file: file, line: line)
        XCTAssertEqual(shape(viaIndex.conversation), shape(viaScan.conversation), "对话", file: file, line: line)
        XCTAssertEqual(shape(viaIndex.branch), shape(viaScan.branch), "分支", file: file, line: line)
        return viaIndex
    }

    // MARK: - 用例

    func testSingleWordMainAndBranchBuckets() async throws {
        try seed()
        let b = try await assertSame(filter(["苹果"]))
        // a5 节点在回收站、c4 对话在回收站 → 都不出现；a4 在分支
        XCTAssertEqual(nodeIds(b.conversation), ["a1", "a2", "a3", "b1", "b3", "d1", "f1"])
        XCTAssertEqual(nodeIds(b.branch), ["a4"])
    }

    func testMultiWordIsConversationLevelAnd() async throws {
        try seed()
        let b = try await assertSame(filter(["苹果", "香蕉"]))
        let rows = Dictionary(uniqueKeysWithValues: b.conversation.map { ($0.convId, $0) })
        // c2 两个词分在两条消息 → 对话够格，但没有一条消息同时含两个词 → 行保留、不带消息
        XCTAssertEqual(rows["c2"]?.matchedNodes.map(\.id), [])
        // c1 主线只有 a2 两个词都有
        XCTAssertEqual(rows["c1"]?.matchedNodes.map(\.id), ["a2"])
        XCTAssertNil(rows["c3"], "只有一个词")
        XCTAssertNil(rows["c5"], "只看正文时标题里的词不算")
        XCTAssertEqual(nodeIds(b.branch), ["a4"])
    }

    func testMultiWordBothScopeCountsTitle() async throws {
        try seed()
        // c5：「香蕉」只在标题、「苹果」只在正文 → 标题 ∪ 正文够格，消息级也算标题里的词
        let b = try await assertSame(filter(["苹果", "香蕉"], scope: .both))
        XCTAssertEqual(b.conversation.first { $0.convId == "c5" }?.matchedNodes.map(\.id), ["f1"])
    }

    func testRoleSubset() async throws {
        try seed()
        var f = filter(["苹果"])
        f.roles = ["user"]
        let b = try await assertSame(f)
        XCTAssertEqual(nodeIds(b.conversation), ["a1", "a3", "b1", "b3", "f1"])
        f.roles = []
        let none = try await assertSame(f)
        XCTAssertTrue(none.conversation.isEmpty && none.branch.isEmpty)
    }

    func testIntervalExcludesNilCreateTime() async throws {
        try seed()
        var f = filter(["苹果"])
        f.dateRange = .custom(start: day1, end: day1)
        let b = try await assertSame(f)
        XCTAssertEqual(nodeIds(b.conversation), ["a1", "a2", "b1", "f1"], "b3 没有时间，有区间时排除")
        var multi = filter(["苹果", "香蕉"])
        multi.dateRange = .custom(start: day2, end: day2)
        try await assertSame(multi)
    }

    func testEmptyScopeAndScopedConversations() async throws {
        try seed()
        var f = filter(["苹果"])
        f.conversationIdScope = []
        let empty = try await run(f, index: true)
        XCTAssertTrue(empty.conversation.isEmpty && empty.branch.isEmpty)
        f.conversationIdScope = ["c2", "c3"]
        let b = try await assertSame(f)
        XCTAssertEqual(Set(b.conversation.map(\.convId)), ["c2", "c3"])
    }

    func testTrashedConversationsOnlyWhenWantDeleted() async throws {
        try seed()
        var f = filter(["苹果", "香蕉"])
        f.includeDeletedConversations = true
        let b = try await assertSame(f)
        XCTAssertEqual(b.conversation.map(\.convId), ["c4"])
        XCTAssertEqual(nodeIds(b.conversation), ["e1"])
    }

    func testRelevanceAndTitleSortsMatch() async throws {
        try seed()
        for sort in [SearchSort.relevance, .oldest, .titleAZ] {
            try await assertSame(filter(["苹果"], scope: .both, sort: sort))
            try await assertSame(filter(["苹果", "香蕉"], scope: .both, sort: sort))
        }
    }

    func testFallsBackWithoutIndexOrUnindexableWord() async throws {
        try seed()
        let scan = try await run(filter(["苹果"]), index: false)
        XCTAssertFalse(scan.usedIndex)
        // 纯 emoji 词索引搜不了 → 整次退回旧扫描（多词里只要有一个就退）
        let emoji = try await run(filter(["苹果", "🍎"]), index: true)
        XCTAssertFalse(emoji.usedIndex)
    }

    func testIndexSeesVisibleTextOnly() async throws {
        // D3：只在思考链里的词，索引路径不命中，旧扫描命中
        conv("t1", title: "思考", current: "t1n", updated: 100)
        node("t1n", "assistant", "[thinking]榴莲藏在这里[/thinking]正文没有", parent: nil, children: [], conv: "t1", at: day1)
        try seed()
        let viaIndex = try await run(filter(["榴莲"]), index: true)
        let viaScan = try await run(filter(["榴莲"]), index: false)
        XCTAssertTrue(viaIndex.conversation.isEmpty)
        XCTAssertEqual(nodeIds(viaScan.conversation), ["t1n"])
    }
}

/// 打字即搜（S5 D7）列表 predicate 的写法：标题含词 || id 在正文命中里；正文命中为空时退化成只看标题
final class SearchTypingPredicateTests: XCTestCase {
    @MainActor
    func testTitleOrBodyIdsPredicate() throws {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let pid = "xctest-typing"
        for (id, title) in [("c1", "苹果笔记"), ("c2", "别的"), ("c3", "也是别的")] {
            context.insert(Conversation(id: id, title: title, createTime: Date(), updateTime: Date(),
                                        currentNodeId: "", profileId: pid))
        }
        try context.save()
        func fetch(_ ids: [String]) throws -> Set<String> {
            let kw = "苹果"
            let bodyIds = ids
            let desc = FetchDescriptor<Conversation>(predicate: #Predicate { conv in
                conv.profileId == pid && conv.isTrashed == false &&
                (conv.title.localizedStandardContains(kw) || bodyIds.contains(conv.id))
            })
            return Set(try context.fetch(desc).map(\.id))
        }
        XCTAssertEqual(try fetch([]), ["c1"])
        XCTAssertEqual(try fetch(["c3"]), ["c1", "c3"])

        // 条件多的分支拆成子 predicate + evaluate（SidebarView 收藏 × 关键词 × 时间、标签 × 关键词 × 时间）
        func fetchComposed(_ ids: [String]) throws -> Set<String> {
            let kw = "苹果"
            let bodyIds = ids
            let s = Date.distantPast, e = Date.distantFuture
            let keywordMatch = #Predicate<Conversation> { conv in
                conv.title.localizedStandardContains(kw) || bodyIds.contains(conv.id)
            }
            let desc = FetchDescriptor<Conversation>(predicate: #Predicate { conv in
                conv.profileId == pid && conv.isTrashed == false &&
                keywordMatch.evaluate(conv) &&
                conv.createTime >= s && conv.createTime <= e
            })
            return Set(try context.fetch(desc).map(\.id))
        }
        XCTAssertEqual(try fetchComposed([]), ["c1"])
        XCTAssertEqual(try fetchComposed(["c2"]), ["c1", "c2"])
    }
}
