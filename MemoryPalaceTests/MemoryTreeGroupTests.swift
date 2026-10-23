import XCTest
@testable import 记忆花园

/// 文件库首页「记忆（只读）」浏览的分组：按 memory/ 下第一层子文件夹，已知分组排前。
final class MemoryTreeGroupTests: XCTestCase {

    private func meta(_ path: String) -> FileLibraryStore.FileMeta {
        FileLibraryStore.FileMeta(path: path, bytes: 1, modifiedAt: Date())
    }

    func testGroupsByFirstFolderInKnownOrder() {
        let list = ["memory/cc/b.md", "memory/profile.md", "memory/summaries/x.md",
                    "memory/heartvoice/h.md", "memory/cc/a.md", "memory/zzz/other.md", "notes/not-memory.md"].map(meta)
        let groups = MemoryTreeGroup.group(list, onlyFolder: nil)
        XCTAssertEqual(groups.map(\.folder), ["", "summaries", "heartvoice", "cc", "zzz"])
        XCTAssertEqual(groups.first { $0.folder == "cc" }?.files.map(\.path), ["memory/cc/a.md", "memory/cc/b.md"])
        XCTAssertEqual(groups.first { $0.folder == "" }?.title, "画像等")
        XCTAssertEqual(groups.first { $0.folder == "cc" }?.title, "CC 同步来的笔记")
    }

    func testSelfFolderSortsFirst() {
        let list = ["memory/profile.md", "memory/self/a.md", "memory/cc/b.md"].map(meta)
        XCTAssertEqual(MemoryTreeGroup.group(list, onlyFolder: nil).map(\.folder), ["self", "", "cc"])
    }

    func testOnlyFolderFilters() {
        let list = ["memory/cc/a.md", "memory/profile.md", "memory/summaries/x.md"].map(meta)
        let groups = MemoryTreeGroup.group(list, onlyFolder: "cc")
        XCTAssertEqual(groups.map(\.folder), ["cc"])
        XCTAssertEqual(groups[0].prefix, "memory/cc/")
    }

    func testEmptyGivesNoGroups() {
        XCTAssertTrue(MemoryTreeGroup.group([], onlyFolder: nil).isEmpty)
    }
}
