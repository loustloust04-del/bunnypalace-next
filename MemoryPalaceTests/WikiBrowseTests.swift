import MemoryCore
import XCTest
@testable import 记忆花园

/// C 档案给人翻（plan-memory-c3-catalog todo 11 / 11b）：一层的分组 / 页、9 组页数、文件库里的 wiki 路径和隐藏规则
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
        XCTAssertEqual(wiki.browse(""), [], "空 wiki")
        try page("人/小慧", "小慧", hook: "她提到小慧时")
        try page("人/阿明", "阿明")
        try page("人/同学/小李", "小李")
        try page("主题/身体", "身体", hook: "聊到身体时")
        try page("工程/记忆宫殿", "记忆宫殿")
        try FileManager.default.createDirectory(at: wiki.folderURL("主题/空组"), withIntermediateDirectories: true)
        try wiki.setGroupHook("人", hook: "她提到身边的人时")
        try wiki.rebuildAllIndexes()
        var old = try XCTUnwrap(wiki.read("主题/身体"))
        old.now = "改过"
        try wiki.save(old)

        XCTAssertEqual(wiki.browse(""), [
            WikiBrowseEntry(path: "主题", kind: .folder(pageCount: 1), title: "主题", hook: ""),
            WikiBrowseEntry(path: "人", kind: .folder(pageCount: 3), title: "人", hook: "她提到身边的人时"),
            WikiBrowseEntry(path: "工程", kind: .folder(pageCount: 1), title: "工程", hook: ""),
        ], "根下直接列各组（页数含更深层）")
        XCTAssertEqual(wiki.browse("主题"), [WikiBrowseEntry(path: "主题/身体", kind: .page, title: "身体", hook: "聊到身体时", version: WikiStore.version(of: Data(old.markdown.utf8)))],
                       "空分组不列；INDEX.md / .group.md / .history 不算")
        XCTAssertEqual(wiki.browse("人").map(\.path), ["人/同学", "人/小慧", "人/阿明"])
        XCTAssertEqual(wiki.browse("人")[0].kind, .folder(pageCount: 1))
        XCTAssertEqual(wiki.branchPageCounts().map(\.branch), WikiStore.branches)
        XCTAssertEqual(wiki.branchPageCounts().map(\.count), [0, 3, 0, 0, 0, 0, 0, 1, 1])
        XCTAssertNotNil(wiki.modifiedAt("主题/身体"))
        XCTAssertNil(wiki.modifiedAt("主题/没有"))
    }

    func testBranchCountsWithoutFolders() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(wiki.branchPageCounts().map(\.count), Array(repeating: 0, count: 9))
        XCTAssertEqual(wiki.browse("工程"), [])
        XCTAssertEqual(wiki.browse(""), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "空 wiki 的计数和浏览不建目录")
    }

    func testFileLibraryWikiPaths() {
        XCTAssertEqual(FileLibraryMemoryFolder.wikiPagePath("memory/wiki/人/小慧.md"), "人/小慧")
        XCTAssertEqual(FileLibraryMemoryFolder.wikiPagePath("memory/wiki/工程/记忆宫殿.md"), "工程/记忆宫殿")
        for notPage in ["memory/wiki/INDEX.md", "memory/wiki/主题/INDEX.md", "memory/wiki/主题/.group.md",
                        "memory/wiki/.history/主题/x/20261016-000000.md", "memory/wiki/.runs/run.md",
                        "memory/wiki/.proposals/drafts/run.md", "memory/wiki/不触发的词.txt",
                        "memory/wiki/别的/x.md", "memory/self/x.md"] {
            XCTAssertNil(FileLibraryMemoryFolder.wikiPagePath(notPage), notPage)
        }

        let metas = ["memory/wiki/INDEX.md", "memory/wiki/人/小慧.md", "memory/wiki/主题/.group.md",
                     "memory/wiki/.history/人/小慧/20261016-000000.md", "memory/wiki/.proposals/a.json",
                     "memory/wiki/不触发的词.txt", "memory/self/INDEX.md", "memory/self/a.md", "memory/.x/y.md"]
            .map { FileLibraryStore.FileMeta(path: $0, bytes: 1, modifiedAt: .distantPast) }
        XCTAssertEqual(FileLibraryMemoryFolder.visible(metas).map(\.path),
                       ["memory/wiki/INDEX.md", "memory/wiki/人/小慧.md", "memory/wiki/不触发的词.txt", "memory/self/a.md", "memory/.x/y.md"],
                       "只藏 wiki 里点开头的，别处不动")
        XCTAssertEqual(FileLibraryMemoryFolder.displayName("memory/wiki", assistantName: "助手"), "C 档案")
    }
}
