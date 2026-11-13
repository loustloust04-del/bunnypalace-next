import XCTest
@testable import MemoryCore

/// C3 wiki 索引（plan-memory-c3-catalog 2.1）：代码生成每层 INDEX.md、根下 9 组、分组行、>30 标记、只重建受影响层
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

    func testDiskAndPublicIndexesPreserveFactDomainTags() throws {
        let cases: [(String, SeedFactDomain?, String)] = [
            ("现实", .realWorld, ""), ("设定", .inWorld, " [设定]"),
            ("混合", .mixed, " [待判域]"), ("未判", .unspecified, " [待判域]"), ("旧页", nil, ""),
        ]
        for (title, domain, _) in cases {
            try wiki.save(WikiPage(path: "主题/\(title)", hook: "虚构钩子", title: title, factDomain: domain))
        }
        try wiki.rebuildAllIndexes()
        let safe = SafeWiki.scan(wiki, memoryRoot: root.deletingLastPathComponent())
        for folder in ["", "主题"] {
            let disk = try XCTUnwrap(index(folder))
            let publicIndex = safe.index(folder)
            for (title, _, tag) in cases {
                let expected = "- [[主题/\(title)]] \(title)\(tag) — 虚构钩子"
                XCTAssertTrue(disk.components(separatedBy: "\n").contains(expected), disk)
                XCTAssertTrue(publicIndex.components(separatedBy: "\n").contains(expected), publicIndex)
            }
        }
    }

    func testFullRebuild() throws {
        try page("人/小慧", "小慧", hook: "她提到小慧时")
        try page("人/阿明", "阿明")
        try page("主题/身体", "身体", hook: "她说哪不舒服时")
        try page("{{user}}/品味", "品味")
        try page("工程/项目/记忆宫殿", "记忆宫殿", hook: "聊这个 app 时")
        try wiki.setGroupHook("人", hook: "她提到身边的人时")
        var edited = try XCTUnwrap(wiki.read("人/阿明"))
        edited.now = "有历史"
        try wiki.save(edited)
        try FileManager.default.createDirectory(at: wiki.folderURL("主题/空组"), withIntermediateDirectories: true)

        try wiki.rebuildAllIndexes()

        XCTAssertEqual(index(""), """
        # C 档案

        ## {{user}}（1 页）
        - [[{{user}}/品味]] 品味

        ## 人 — 她提到身边的人时（2 页）
        - [[人/小慧]] 小慧 — 她提到小慧时
        - [[人/阿明]] 阿明

        ## 主题（1 页）
        - [[主题/身体]] 身体 — 她说哪不舒服时

        ## 工程（1 页）
        - [[工程/项目/]] 项目（1 页）

        """, "根下直接是各组（带组钩子），没页的组不列")
        XCTAssertEqual(index("人"), """
        # 人

        - [[人/小慧]] 小慧 — 她提到小慧时
        - [[人/阿明]] 阿明

        """)
        XCTAssertEqual(index("主题"), "# 主题\n\n- [[主题/身体]] 身体 — 她说哪不舒服时\n", "没页的分组不列；.history 不算")
        XCTAssertEqual(index("工程/项目"), "# 工程/项目\n\n- [[工程/项目/记忆宫殿]] 记忆宫殿 — 聊这个 app 时\n")
        XCTAssertEqual(wiki.groupHook("人"), "她提到身边的人时")
        XCTAssertNil(wiki.groupHook("主题"))
        XCTAssertEqual(wiki.pagePaths().count, 5, "INDEX.md / .group.md 不算页")
        XCTAssertEqual(WikiStore.shown(index("") ?? "", user: "岚舟").components(separatedBy: "\n")[2...3], ["## 岚舟（1 页）", "- [[岚舟/品味]] 品味"],
                       "给人 / 模型看时本人那组是名字")
    }

    func testEmptyWikiRootListsNoGroupsAndCreatesNoFolders() throws {
        try wiki.rebuildAllIndexes()
        XCTAssertEqual(index(""), "# C 档案\n")
        for branch in WikiStore.branches { XCTAssertFalse(wiki.folderExists(branch), "不预先建空的组：\(branch)") }
    }

    func testOverfullMarker() throws {
        for i in 1...30 { try page(String(format: "主题/电影/片%02d", i), "片\(i)") }
        try wiki.rebuildAllIndexes()
        XCTAssertFalse(index("主题/电影")?.contains(WikiStore.overfullMarker) ?? true, "正好 30 行不标")
        XCTAssertEqual(wiki.overfullLayers(), [])

        try page("主题/电影/片31", "片31")
        try wiki.rebuildIndexes(affecting: ["主题/电影/片31"])
        let text = try XCTUnwrap(index("主题/电影"))
        XCTAssertTrue(text.hasPrefix("# 主题/电影\n" + WikiStore.overfullMarker + "\n"))
        XCTAssertEqual(wiki.overfullLayers(), ["主题/电影"])
        XCTAssertTrue(index("")?.contains("- [[主题/电影/]] 电影（31 页）") ?? false)
        XCTAssertFalse(index("")?.contains(WikiStore.overfullMarker) ?? true, "根不标")
    }

    func testRebuildAffectedOnly() throws {
        try page("工程/项目/记忆宫殿", "记忆宫殿")
        try page("人/小慧", "小慧")
        try wiki.rebuildIndexes(affecting: ["人/小慧"])
        XCTAssertNotNil(index("人"))
        XCTAssertNil(index("工程"), "别的组不动")
        XCTAssertTrue(index("")?.contains("- [[工程/项目/]] 项目（1 页）") ?? false, "根总是从文件算")
        XCTAssertNil(index("工程/项目"), "别的层不动")
        XCTAssertNil(index("工程"))

        var p = try XCTUnwrap(wiki.read("人/小慧"))
        p.hook = "新钩子"
        try wiki.save(p)
        try wiki.rebuildIndexes(affecting: ["人/小慧"])
        XCTAssertTrue(index("人")?.contains("- [[人/小慧]] 小慧 — 新钩子") ?? false)
    }
}
