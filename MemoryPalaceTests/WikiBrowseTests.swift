import XCTest
@testable import 记忆花园

/// C 档案给人翻（plan-memory-c3-catalog todo 11 / 11b）：一层的分组 / 页、两支页数、文件库里的 wiki 路径和隐藏规则
final class WikiBrowseTests: XCTestCase {

    private var root: URL!
    private var wiki: WikiStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-browse-\(UUID().uuidString)", isDirectory: true)
        wiki = WikiStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func page(_ path: String, _ title: String, hook: String = "") throws {
        try wiki.save(WikiPage(path: path, hook: hook, title: title))
    }

    func testBrowseLayer() throws {
        XCTAssertEqual(wiki.browse("楼层"), [], "空 wiki")
        try page("楼层/人/小慧", "小慧", hook: "她提到小慧时")
        try page("楼层/人/阿明", "阿明")
        try page("楼层/人/同学/小李", "小李")
        try page("楼层/身体", "身体", hook: "聊到身体时")
        try page("工程/记忆宫殿", "记忆宫殿")
        try FileManager.default.createDirectory(at: wiki.folderURL("楼层/空组"), withIntermediateDirectories: true)
        try wiki.setGroupHook("楼层/人", hook: "她提到身边的人时")
        try wiki.rebuildAllIndexes()
        var old = try XCTUnwrap(wiki.read("楼层/身体"))
        old.now = "改过"
        try wiki.save(old)

        XCTAssertEqual(wiki.browse("楼层"), [
            WikiBrowseEntry(path: "楼层/人", kind: .folder(pageCount: 3), title: "人", hook: "她提到身边的人时"),
            WikiBrowseEntry(path: "楼层/身体", kind: .page, title: "身体", hook: "聊到身体时"),
        ], "子分组在前（空分组不列，页数含更深层），再页；INDEX.md / .group.md / .history 不算")
        XCTAssertEqual(wiki.browse("楼层/人").map(\.path), ["楼层/人/同学", "楼层/人/小慧", "楼层/人/阿明"])
        XCTAssertEqual(wiki.browse("楼层/人")[0].kind, .folder(pageCount: 1))
        XCTAssertEqual(wiki.branchPageCounts(), [WikiBranchCount(branch: "工程", count: 1), WikiBranchCount(branch: "楼层", count: 4)])
        XCTAssertNotNil(wiki.modifiedAt("楼层/身体"))
        XCTAssertNil(wiki.modifiedAt("楼层/没有"))
    }

    func testBranchCountsWithoutFolders() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(wiki.branchPageCounts().map(\.count), [0, 0])
        XCTAssertEqual(wiki.browse("工程"), [])
        XCTAssertEqual(wiki.browse("楼层"), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "空 wiki 的计数和浏览不建目录")
    }

    func testFileLibraryWikiPaths() {
        XCTAssertEqual(FileLibraryMemoryFolder.wikiPagePath("memory/wiki/楼层/人/小慧.md"), "楼层/人/小慧")
        XCTAssertEqual(FileLibraryMemoryFolder.wikiPagePath("memory/wiki/工程/记忆宫殿.md"), "工程/记忆宫殿")
        for notPage in ["memory/wiki/INDEX.md", "memory/wiki/楼层/INDEX.md", "memory/wiki/楼层/.group.md",
                        "memory/wiki/.history/楼层/x/20261016-000000.md", "memory/wiki/.runs/run.md",
                        "memory/wiki/.proposals/drafts/run.md", "memory/wiki/不触发的词.txt",
                        "memory/wiki/别的/x.md", "memory/self/x.md"] {
            XCTAssertNil(FileLibraryMemoryFolder.wikiPagePath(notPage), notPage)
        }

        let metas = ["memory/wiki/INDEX.md", "memory/wiki/楼层/人/小慧.md", "memory/wiki/楼层/.group.md",
                     "memory/wiki/.history/楼层/人/小慧/20261016-000000.md", "memory/wiki/.proposals/a.json",
                     "memory/wiki/不触发的词.txt", "memory/self/INDEX.md", "memory/self/a.md", "memory/.x/y.md"]
            .map { FileLibraryStore.FileMeta(path: $0, bytes: 1, modifiedAt: .distantPast) }
        XCTAssertEqual(FileLibraryMemoryFolder.visible(metas).map(\.path),
                       ["memory/wiki/INDEX.md", "memory/wiki/楼层/人/小慧.md", "memory/wiki/不触发的词.txt", "memory/self/a.md", "memory/.x/y.md"],
                       "只藏 wiki 里点开头的，别处不动")
        XCTAssertEqual(FileLibraryMemoryFolder.displayName("memory/wiki", assistantName: "助手"), "C 档案")
    }
}
