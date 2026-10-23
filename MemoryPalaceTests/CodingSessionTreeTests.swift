#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-d 父子列表（Wake roots_only / child_counts / list_children / all_descendants + SessionsDelegate）：子树聚合排序与 keyset、
/// 根计数、父归档子提升、懒展开、选子会话自动展开根、整棵删除（邻居跳过整棵）。全在 tmp
@MainActor
final class CodingSessionTreeTests: XCTestCase {
    private var dir: URL!
    private var indexURL: URL { dir.appendingPathComponent("index.sqlite") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-coding-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func meta(_ id: String, project: String, created: Int64, updated: Int64, messages: Int, archived: Bool = false) -> CodingSessionMeta {
        CodingSessionMeta(key: "grok:\(id)", nativeId: id, agent: .grok, title: "会话 \(id)", projectPath: project,
                          projectName: (project as NSString).lastPathComponent, filePath: dir.appendingPathComponent("\(id)/updates.jsonl").path,
                          createdAt: created, updatedAt: updated, messageCount: messages, sizeBytes: 1,
                          gitBranch: nil, model: nil, tokensUsed: nil, archived: archived, source: nil)
    }

    /// P（旧）下挂 C1（最新）/ C2，C1 下再挂 G（验递归子树）；O 是独立根
    private func seed(_ index: CodingSessionIndex, archiveParent: Bool = false) throws {
        try index.writeSession(meta("P", project: "/p", created: 10, updated: 100, messages: 2, archived: archiveParent), fileMtime: 1, units: [])
        try index.writeSession(meta("C1", project: "/c1", created: 20, updated: 300, messages: 5), fileMtime: 1, units: [])
        try index.writeSession(meta("C2", project: "/c2", created: 30, updated: 150, messages: 1), fileMtime: 1, units: [])
        try index.writeSession(meta("G", project: "/g", created: 40, updated: 120, messages: 1), fileMtime: 1, units: [])
        try index.writeSession(meta("O", project: "/o", created: 50, updated: 200, messages: 4), fileMtime: 1, units: [])
        try index.replaceParentLinks(agent: .grok, links: [(child: "grok:C1", parent: "grok:P"), (child: "grok:C2", parent: "grok:P"),
                                                          (child: "grok:G", parent: "grok:C1")])
    }

    private func roots(_ sort: CodingSortKey = .updated, ascending: Bool = false) -> CodingListFilter {
        var filter = CodingListFilter()
        filter.rootsOnly = true
        filter.sort = sort
        filter.ascending = ascending
        return filter
    }

    func testRootsAggregateSortKeysetAndCounts() throws {
        let index = try CodingSessionIndex(url: indexURL)
        try seed(index)
        let list = try index.listSessions(projectPath: nil, filter: roots(), limit: 100)
        XCTAssertEqual(list.map(\.key), ["grok:P", "grok:O"], "父旧子新：按子树聚合的活动时间排在前面")
        XCTAssertEqual(list.first?.updatedAt, 300, "行上显示的就是聚合值（游标同口径）")
        XCTAssertEqual(list.first?.messageCount, 8, "消息数 = 自己 + 直接子会话")
        XCTAssertEqual(list.first?.projectPath, "/p", "子会话项目随父（关系替换时覆写）")
        XCTAssertEqual(try index.listSessions(projectPath: nil, filter: roots(.messages), limit: 100).map(\.key), ["grok:P", "grok:O"])
        for sort in CodingSortKey.allCases {
            for ascending in [false, true] {
                let filter = roots(sort, ascending: ascending)
                let all = try index.listSessions(projectPath: nil, filter: filter, limit: 100)
                var paged: [CodingSessionMeta] = []
                for _ in 0..<10 {
                    let page = try index.listSessions(projectPath: nil, filter: filter, limit: 1, after: paged.last)
                    paged += page
                    if page.isEmpty { break }
                }
                XCTAssertEqual(paged.map(\.key), all.map(\.key), "keyset 用聚合值翻页不漏不重：\(sort) ascending=\(ascending)")
            }
        }
        XCTAssertEqual(try index.countSessions(filter: roots()), 2, "角标数根")
        XCTAssertEqual(try index.countSessions(filter: CodingListFilter()), 5, "平铺（收藏范围）数全部")
        let projects = try index.listProjects(filter: roots())
        XCTAssertEqual(projects.first { $0.path == "/p" }?.sessionCount, 1, "项目会话数数根")
        XCTAssertEqual(projects.first { $0.path == "/p" }?.lastActive, 300, "项目活动取子树聚合")
        XCTAssertEqual(try index.childCounts(filter: roots()), ["grok:P": 2, "grok:C1": 1])
        XCTAssertEqual(try index.listChildren(of: "grok:P", filter: roots()).map(\.key), ["grok:C1", "grok:C2"])
        XCTAssertEqual(Set(try index.allDescendants(of: "grok:P").map(\.key)), ["grok:C1", "grok:C2", "grok:G"], "递归取完整子树")
        XCTAssertEqual(try index.visibleParentKey(of: "grok:C1"), "grok:P")
        XCTAssertNil(try index.visibleParentKey(of: "grok:O"))
    }

    func testArchivedParentPromotesChildren() throws {
        let index = try CodingSessionIndex(url: indexURL)
        try seed(index, archiveParent: true)
        XCTAssertEqual(Set(try index.listSessions(projectPath: nil, filter: roots(), limit: 100).map(\.key)), ["grok:C1", "grok:C2", "grok:O"],
                       "父被归档：子会话提升为根（G 的父 C1 还在，仍挂着）")
        XCTAssertNil(try index.visibleParentKey(of: "grok:C1"), "归档的父看不见")
    }

    private func makeLibrary() -> CodingSessionLibrary {
        let library = CodingSessionLibrary(indexURL: indexURL, adapters: [],
                                           state: CodingSessionState(url: dir.appendingPathComponent("state.json")))
        library.recycle = { urls, done in
            for url in urls { try? FileManager.default.removeItem(at: url) }
            done(nil)
        }
        return library
    }

    func testLibraryExpandRevealAndSubtreeDelete() async throws {
        try seed(try CodingSessionIndex(url: indexURL))
        let library = makeLibrary()
        XCTAssertTrue(library.listFilter().rootsOnly, "全部范围只列根")
        library.setListMode(.timeline)
        library.reload()
        XCTAssertEqual(library.timeline.all.map(\.key), ["grok:P", "grok:O"])
        XCTAssertEqual(library.childCounts["grok:P"], 2)

        library.toggleRoot("grok:P")
        XCTAssertEqual(library.children["grok:P"]?.map(\.key), ["grok:C1", "grok:C2"], "懒加载子会话")
        XCTAssertEqual(library.visibleRows(inProject: nil).map(\.key), ["grok:P", "grok:C1", "grok:C2", "grok:O"])
        library.toggleRoot("grok:P")
        XCTAssertFalse(library.expandedRoots.contains("grok:P"), "再点收起")
        library.toggleRoot("grok:O")
        XCTAssertFalse(library.expandedRoots.contains("grok:O"), "没有子会话的行什么也不做")

        library.select("grok:C2")
        XCTAssertTrue(library.expandedRoots.contains("grok:P"), "选中子会话自动展开它的根")

        let parent = try XCTUnwrap(library.timeline.all.first)
        library.select(parent.key)
        XCTAssertEqual(library.deletionPlan(for: parent).sessions.count, 4, "删除范围 = 自己 + 整棵子树")
        var result: String??
        library.delete(parent) { result = .some($0) }
        for _ in 0..<60 where result == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(result, .some(nil))
        XCTAssertEqual(library.timeline.all.map(\.key), ["grok:O"], "整棵子树一起删")
        XCTAssertEqual(library.selectedKey, "grok:O", "邻居跳过整棵子树")
        for key in ["grok:P", "grok:C1", "grok:C2", "grok:G"] {
            XCTAssertNil(try CodingSessionIndex(url: indexURL).session(key: key))
            XCTAssertTrue(library.state.tombstoneCheck("", key), "\(key) 写了墓碑，下次扫描不复活")
        }
    }

    func testFavoritesScopeStaysFlat() throws {
        try seed(try CodingSessionIndex(url: indexURL))
        let library = makeLibrary()
        library.state.toggleFavorite("grok:C1")
        library.setScope(.favorites)
        XCTAssertFalse(library.listFilter().rootsOnly, "收藏范围平铺：收藏了的子会话直接看见")
    }
}
#endif
