import XCTest
@testable import 记忆花园

/// C3 wiki 索引（plan-memory-c3-catalog 2.1）：代码生成每层 INDEX.md、根两支、分组行、>30 标记、只重建受影响层
final class WikiIndexTests: XCTestCase {

    private var root: URL!
    private var wiki: WikiStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-index-\(UUID().uuidString)", isDirectory: true)
        wiki = WikiStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func page(_ path: String, _ title: String, hook: String = "") throws {
        try wiki.save(WikiPage(path: path, kind: .topic, hook: hook, title: title))
    }

    private func index(_ folder: String) -> String? {
        try? String(contentsOf: wiki.folderURL(folder).appendingPathComponent(WikiStore.indexFileName), encoding: .utf8)
    }

    func testFullRebuild() throws {
        try page("楼层/人/小慧", "小慧", hook: "她提到小慧时")
        try page("楼层/人/阿明", "阿明")
        try page("楼层/身体", "身体", hook: "她说哪不舒服时")
        try page("工程/项目/记忆宫殿", "记忆宫殿", hook: "聊这个 app 时")
        try wiki.setGroupHook("楼层/人", hook: "她提到身边的人时")
        var edited = try XCTUnwrap(wiki.read("楼层/人/阿明"))
        edited.now = "有历史"
        try wiki.save(edited)
        try FileManager.default.createDirectory(at: wiki.folderURL("楼层/空组"), withIntermediateDirectories: true)

        try wiki.rebuildAllIndexes()

        XCTAssertEqual(index(""), """
        # C 档案

        ## 工程（1 页）
        - [[工程/项目/]] 项目（1 页）

        ## 楼层（3 页）
        - [[楼层/人/]] 人 — 她提到身边的人时（2 页）
        - [[楼层/身体]] 身体 — 她说哪不舒服时

        """)
        XCTAssertEqual(index("楼层/人"), """
        # 楼层/人

        - [[楼层/人/小慧]] 小慧 — 她提到小慧时
        - [[楼层/人/阿明]] 阿明

        """)
        XCTAssertEqual(index("楼层"), """
        # 楼层

        - [[楼层/人/]] 人 — 她提到身边的人时（2 页）
        - [[楼层/身体]] 身体 — 她说哪不舒服时

        """, "没页的分组不列；.history 不算")
        XCTAssertEqual(index("工程/项目"), "# 工程/项目\n\n- [[工程/项目/记忆宫殿]] 记忆宫殿 — 聊这个 app 时\n")
        XCTAssertEqual(wiki.groupHook("楼层/人"), "她提到身边的人时")
        XCTAssertNil(wiki.groupHook("楼层"))
        XCTAssertEqual(wiki.pagePaths().count, 4, "INDEX.md / .group.md 不算页")
    }

    func testEmptyWikiRootListsBothBranches() throws {
        try wiki.rebuildAllIndexes()
        XCTAssertEqual(index(""), "# C 档案\n\n## 工程（0 页）\n\n## 楼层（0 页）\n")
    }

    func testOverfullMarker() throws {
        for i in 1...30 { try page(String(format: "楼层/电影/片%02d", i), "片\(i)") }
        try wiki.rebuildAllIndexes()
        XCTAssertFalse(index("楼层/电影")?.contains(WikiStore.overfullMarker) ?? true, "正好 30 行不标")
        XCTAssertEqual(wiki.overfullLayers(), [])

        try page("楼层/电影/片31", "片31")
        try wiki.rebuildIndexes(affecting: ["楼层/电影/片31"])
        let text = try XCTUnwrap(index("楼层/电影"))
        XCTAssertTrue(text.hasPrefix("# 楼层/电影\n" + WikiStore.overfullMarker + "\n"))
        XCTAssertEqual(wiki.overfullLayers(), ["楼层/电影"])
        XCTAssertTrue(index("")?.contains("- [[楼层/电影/]] 电影（31 页）") ?? false)
        XCTAssertFalse(index("")?.contains(WikiStore.overfullMarker) ?? true, "根不标")
    }

    func testRebuildAffectedOnly() throws {
        try page("工程/项目/记忆宫殿", "记忆宫殿")
        try page("楼层/人/小慧", "小慧")
        try wiki.rebuildIndexes(affecting: ["楼层/人/小慧"])
        XCTAssertNotNil(index("楼层/人"))
        XCTAssertNotNil(index("楼层"))
        XCTAssertTrue(index("")?.contains("- [[工程/项目/]] 项目（1 页）") ?? false, "根总是从文件算")
        XCTAssertNil(index("工程/项目"), "别的层不动")
        XCTAssertNil(index("工程"))

        var p = try XCTUnwrap(wiki.read("楼层/人/小慧"))
        p.hook = "新钩子"
        try wiki.save(p)
        try wiki.rebuildIndexes(affecting: ["楼层/人/小慧"])
        XCTAssertTrue(index("楼层/人")?.contains("- [[楼层/人/小慧]] 小慧 — 新钩子") ?? false)
    }
}
