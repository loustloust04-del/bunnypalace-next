import XCTest
@testable import 记忆花园

/// 输入框 @ 文件库文件的口径（plan-input-file-mention）
final class FileMentionTests: XCTestCase {
    private func meta(_ path: String, _ minutesAgo: Double) -> FileLibraryStore.FileMeta {
        .init(path: path, bytes: 1, modifiedAt: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
    }

    func testQueryOnlyAtTail() {
        XCTAssertEqual(FileMention.query(in: "给你看这个 @嗷"), "嗷")
        XCTAssertEqual(FileMention.query(in: "给你看这个@嗷呜"), "嗷呜")
        XCTAssertEqual(FileMention.query(in: "@notes"), "notes")
        XCTAssertNil(FileMention.query(in: "@"))
        XCTAssertNil(FileMention.query(in: "看 @"))
        XCTAssertNil(FileMention.query(in: "@嗷 后面还有"))
        XCTAssertNil(FileMention.query(in: "@嗷 "))
        XCTAssertNil(FileMention.query(in: "没有艾特"))
        XCTAssertNil(FileMention.query(in: ""))
    }

    func testQueryIgnoresEmail() {
        XCTAssertNil(FileMention.query(in: "发到 susu@example"))
        XCTAssertNil(FileMention.query(in: "a.b@c"))
        XCTAssertEqual(FileMention.query(in: "（@嗷"), "嗷")
    }

    func testQueryLengthCap() {
        let long = String(repeating: "嗷", count: FileMention.maxQueryLength + 1)
        XCTAssertNil(FileMention.query(in: "@" + long))
        let ok = String(repeating: "嗷", count: FileMention.maxQueryLength)
        XCTAssertEqual(FileMention.query(in: "@" + ok), ok)
    }

    func testRemovingQuery() {
        XCTAssertEqual(FileMention.removingQuery(from: "给你看这个 @嗷"), "给你看这个 ")
        XCTAssertEqual(FileMention.removingQuery(from: "@嗷"), "")
        XCTAssertEqual(FileMention.removingQuery(from: "没有"), "没有")
        XCTAssertEqual(FileMention.removingQuery(from: "a@b"), "a@b")
    }

    func testRankTiersThenNewest() {
        let files = [
            meta("嗷呜/随手.txt", 1),           // 文件夹含
            meta("notes/小狗叫声嗷嗷.txt", 2),    // 名字含
            meta("notes/嗷呜嗷呜.md", 30),        // 名字开头（旧）
            meta("img/嗷呜头像草稿.png", 5),      // 名字开头（新）
            meta("notes/无关.md", 0),
        ]
        XCTAssertEqual(FileMention.rank(files, query: "嗷").map(\.path), [
            "img/嗷呜头像草稿.png", "notes/嗷呜嗷呜.md", "notes/小狗叫声嗷嗷.txt", "嗷呜/随手.txt",
        ])
    }

    func testRankCaseAndWidthInsensitiveAndLimit() {
        let files = (0..<8).map { meta("Docs/Readme\($0).MD", Double($0)) }
        XCTAssertEqual(FileMention.rank(files, query: "ｒｅａｄ").count, FileMention.suggestionLimit)
        XCTAssertEqual(FileMention.rank(files, query: "readme", limit: nil).count, 8)
        XCTAssertEqual(FileMention.rank(files, query: "readme").first?.path, "Docs/Readme0.MD")
        XCTAssertTrue(FileMention.rank(files, query: "  ").isEmpty)
    }

    func testRankMatchesFolderSegmentsOnly() {
        // 文件夹任一段含都算第三档；名字 / 文件夹都不含就不出
        let files = [meta("a/b/c.md", 0)]
        XCTAssertEqual(FileMention.rank(files, query: "b").map(\.path), ["a/b/c.md"])
        XCTAssertTrue(FileMention.rank(files, query: "x").isEmpty)
    }

    func testRecentNewestFirstCapped() {
        let files = (0..<20).map { meta("f\($0).md", Double($0)) }
        let r = FileMention.recent(files)
        XCTAssertEqual(r.count, FileMention.recentLimit)
        XCTAssertEqual(r.first?.path, "f0.md")
    }
}
