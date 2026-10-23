import XCTest
import SwiftData
@testable import 记忆花园

/// performSearch 主线/分支过滤特征测试（B9）。
/// 先在改造前代码上跑绿锁定基线行为，N+1 分批重写后必须仍绿——结果集逐字节一致是安全网。
final class SearchMainPathFilterTests: XCTestCase {

    let pid = "xctest-mainpath"
    var container: ModelContainer!
    var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Conversation.self, MessageNode.self, configurations: config)
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// 对话 C1：n1 → n2 →┬ n3（currentNode，主线）
    ///                    └ n4（分支）
    /// n5 = n3 的 trashed 孩子（SQL 层就该被排除）。全部节点 content 含关键词「苹果」。
    private func makeC1() {
        let conv = Conversation(id: "c1", title: "工作笔记", createTime: Date(timeIntervalSince1970: 1000),
                                updateTime: Date(timeIntervalSince1970: 2000), currentNodeId: "n3", profileId: pid)
        context.insert(conv)
        insertNode(id: "n1", role: "user", content: "苹果 主线问题", parentId: nil, childrenIds: ["n2"], convId: "c1")
        insertNode(id: "n2", role: "assistant", content: "主线回答有苹果", parentId: "n1", childrenIds: ["n3", "n4"], convId: "c1")
        insertNode(id: "n3", role: "user", content: "苹果 主线跟进", parentId: "n2", childrenIds: ["n5"], convId: "c1")
        insertNode(id: "n4", role: "assistant", content: "苹果 分支内容", parentId: "n2", childrenIds: [], convId: "c1")
        insertNode(id: "n5", role: "assistant", content: "苹果 已删节点", parentId: "n3", childrenIds: [], convId: "c1", isTrashed: true)
    }

    /// 对话 C2：m1 → m2（全主线，验证跨对话分组）
    private func makeC2() {
        let conv = Conversation(id: "c2", title: "第二对话", createTime: Date(timeIntervalSince1970: 1500),
                                updateTime: Date(timeIntervalSince1970: 2500), currentNodeId: "m2", profileId: pid)
        context.insert(conv)
        insertNode(id: "m1", role: "user", content: "也提到苹果", parentId: nil, childrenIds: ["m2"], convId: "c2")
        insertNode(id: "m2", role: "assistant", content: "苹果回复", parentId: "m1", childrenIds: [], convId: "c2")
    }

    private func insertNode(id: String, role: String, content: String, parentId: String?,
                            childrenIds: [String], convId: String, isTrashed: Bool = false) {
        let node = MessageNode(id: id, role: role, content: content, contentType: "text",
                               createTime: Date(timeIntervalSince1970: 1000), parentId: parentId,
                               childrenIds: childrenIds, conversationId: convId, profileId: pid)
        node.isTrashed = isTrashed
        context.insert(node)
    }

    private func contentFilter(kind: SearchResourceKind) -> SearchFilter {
        var f = SearchFilter()
        f.keyword = "苹果"
        f.scope = .contentOnly
        f.resourceKind = kind
        return f
    }

    /// 内容块命中的节点 id 集合（标题块 matchedNodes 恒空，不掺）
    private func matchedIds(_ results: [SearchResult]) -> Set<String> {
        Set(results.filter { !$0.isTitleMatch }.flatMap { $0.matchedNodes.map(\.id) })
    }

    // MARK: - 用例 1：.conversation 只留主线命中

    func testConversationKindKeepsOnlyMainPathNodes() async throws {
        makeC1()
        makeC2()
        try context.save()

        let results = await SearchService.performSearch(
            filter: contentFilter(kind: .conversation), profileId: pid, container: container)

        XCTAssertEqual(matchedIds(results), ["n1", "n2", "n3", "m1", "m2"],
                       "主线命中应含 C1 主线三节点 + C2 全部；分支 n4 与 trashed n5 排除")
    }

    // MARK: - 用例 2：.branchContent 只留分支命中

    func testBranchKindKeepsOnlyBranchNodes() async throws {
        makeC1()
        makeC2()
        try context.save()

        let results = await SearchService.performSearch(
            filter: contentFilter(kind: .branchContent), profileId: pid, container: container)

        XCTAssertEqual(matchedIds(results), ["n4"],
                       "分支命中应只有 n4；C2 无分支不出现，trashed n5 排除")
    }

    // MARK: - 用例 3：孤儿节点（对话行不存在）整对话排除

    func testOrphanNodesWithoutConversationRowExcluded() async throws {
        makeC1()
        insertNode(id: "g1", role: "user", content: "幽灵苹果", parentId: nil, childrenIds: [], convId: "ghost")
        try context.save()

        let results = await SearchService.performSearch(
            filter: contentFilter(kind: .conversation), profileId: pid, container: container)

        XCTAssertEqual(matchedIds(results), ["n1", "n2", "n3"],
                       "ghost 对话无 Conversation 行，g1 不得出现（与改造前 guard-continue 同语义）")
    }

    // MARK: - 用例 4：>1 批命中（25 对话跨 batchSize=20 边界）

    func testCrossBatchGroupingConsistent() async throws {
        var expected = Set<String>()
        for i in 0..<25 {
            let cid = "bulk\(i)"
            let mainId = "\(cid)-a"
            let branchId = "\(cid)-b"
            let rootId = "\(cid)-root"
            let conv = Conversation(id: cid, title: "批量\(i)", createTime: Date(timeIntervalSince1970: 1000),
                                    updateTime: Date(timeIntervalSince1970: 2000), currentNodeId: mainId, profileId: pid)
            context.insert(conv)
            insertNode(id: rootId, role: "user", content: "苹果 根\(i)", parentId: nil, childrenIds: [mainId, branchId], convId: cid)
            insertNode(id: mainId, role: "assistant", content: "苹果 主线\(i)", parentId: rootId, childrenIds: [], convId: cid)
            insertNode(id: branchId, role: "assistant", content: "苹果 分支\(i)", parentId: rootId, childrenIds: [], convId: cid)
            expected.insert(rootId)
            expected.insert(mainId)
        }
        try context.save()

        let mainResults = await SearchService.performSearch(
            filter: contentFilter(kind: .conversation), profileId: pid, container: container)
        XCTAssertEqual(matchedIds(mainResults), expected, "25 对话跨批：主线 = 每对话 root+main")

        let branchResults = await SearchService.performSearch(
            filter: contentFilter(kind: .branchContent), profileId: pid, container: container)
        XCTAssertEqual(matchedIds(branchResults), Set((0..<25).map { "bulk\($0)-b" }),
                       "25 对话跨批：分支 = 每对话 -b 节点")
    }

    // MARK: - 用例 5：多词 AND（S2-8）：一个词在标题、一个词在正文

    func testMultiWordTitlePlusBody() async throws {
        func conv(_ id: String, _ title: String, _ nodes: [(String, String)]) {
            context.insert(Conversation(id: id, title: title, createTime: Date(timeIntervalSince1970: 1000),
                                        updateTime: Date(timeIntervalSince1970: 2000), currentNodeId: nodes.last!.0, profileId: pid))
            for (i, n) in nodes.enumerated() {
                insertNode(id: n.0, role: "user", content: n.1, parentId: i == 0 ? nil : nodes[i - 1].0,
                           childrenIds: i + 1 < nodes.count ? [nodes[i + 1].0] : [], convId: id)
            }
        }
        conv("t1", "薄荷计划", [("t1a", "布局调整一下")])
        conv("t2", "别的对话", [("t2a", "布局调整")])
        conv("t3", "第三个", [("t3a", "布局调整"), ("t3b", "说到薄荷")])
        conv("t4", "第四个", [("t4a", "薄荷和布局调整都在")])
        try context.save()

        var filter = SearchFilter()
        filter.keyword = "布局调整"
        filter.words = ["薄荷", "布局调整"]
        filter.scope = .both
        let buckets = await SearchService.searchConversationBuckets(filter: filter, profileId: pid, container: container)
        let rows = buckets?.conversation ?? []
        XCTAssertEqual(Set(rows.map(\.convId)), ["t1", "t3", "t4"], "t2 缺「薄荷」要排除")
        XCTAssertEqual(rows.first { $0.convId == "t1" }?.matchedNodes.map(\.id), ["t1a"], "标题里的词也算进消息级命中")
        XCTAssertEqual(rows.first { $0.convId == "t3" }?.matchedNodes.map(\.id), [], "两个词分在两条消息：对话保留，消息不带")
        XCTAssertEqual(rows.first { $0.convId == "t4" }?.matchedNodes.map(\.id), ["t4a"])

        filter.scope = .contentOnly
        let content = await SearchService.searchConversationBuckets(filter: filter, profileId: pid, container: container)
        XCTAssertEqual(Set((content?.conversation ?? []).map(\.convId)), ["t3", "t4"], "仅正文：标题里的「薄荷」不算")
    }
}
