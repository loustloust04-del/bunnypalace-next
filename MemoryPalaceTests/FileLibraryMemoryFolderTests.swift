import XCTest
@testable import 记忆花园

/// 第二刀验收返工④②：记忆树在文件库里当普通文件夹显示；自己的记忆永远在、排第一；只读判定。
final class FileLibraryMemoryFolderTests: XCTestCase {

    private func meta(_ path: String, _ t: TimeInterval = 0) -> FileLibraryStore.FileMeta {
        .init(path: path, bytes: 10, modifiedAt: Date(timeIntervalSince1970: 1_800_000_000 + t))
    }

    private func merged(library: [FileLibraryStore.FileMeta], memory: [FileLibraryStore.FileMeta]) -> [String: FileLibraryDisplay.FolderContents] {
        var index = FileLibraryDisplay.folderIndex(library)
        FileLibraryMemoryFolder.merge(FileLibraryDisplay.folderIndex(FileLibraryMemoryFolder.visible(memory)), into: &index)
        for key in index.keys { index[key]?.folders.sort { $0.latest > $1.latest } }
        FileLibraryMemoryFolder.pinSelfFirst(&index)
        return index
    }

    func testMemoryIsAnOrdinaryRootFolderWithSubfolders() {
        let index = merged(library: [meta("notes/a.md", 5), meta("readme.md")],
                           memory: [meta("memory/summaries/s1.md", 9), meta("memory/cc/x.md", 3), meta("memory/profile.md", 1)])
        let root = index[""]!
        XCTAssertEqual(Set(root.folders.map(\.path)), ["notes", "memory"])
        XCTAssertEqual(root.folders.first { $0.path == "memory" }?.fileCount, 3)
        XCTAssertEqual(root.files.map(\.path), ["readme.md"], "记忆文件不混进根目录的文件")
        XCTAssertEqual(index["memory"]?.folders.map(\.path), ["memory/self", "memory/summaries", "memory/cc"], "self 永远在且排第一，其余照排序")
        XCTAssertEqual(index["memory"]?.files.map(\.path), ["memory/profile.md"])
        XCTAssertEqual(index["memory/self"]?.files.count, 0)
    }

    func testSelfFirstEvenWhenOlderAndIndexHidden() {
        let index = merged(library: [],
                           memory: [meta("memory/self/复诊.md", 1), meta("memory/self/INDEX.md", 99), meta("memory/daily/d.md", 50)])
        XCTAssertEqual(index["memory"]?.folders.map(\.path), ["memory/self", "memory/daily"])
        XCTAssertEqual(index["memory/self"]?.files.map(\.path), ["memory/self/复诊.md"], "INDEX.md 不显示")
        XCTAssertEqual(index["memory"]?.folders.first?.fileCount, 1)
    }

    func testNoMemoryFilesNoMemoryFolder() {
        let index = merged(library: [meta("a.md")], memory: [])
        XCTAssertFalse(index[""]!.folders.contains { $0.path == "memory" })
        XCTAssertNil(index["memory"])
    }

    func testNamesAndReadOnlyHelpers() {
        XCTAssertEqual(FileLibraryMemoryFolder.displayName("memory", assistantName: "小克"), "记忆")
        XCTAssertEqual(FileLibraryMemoryFolder.displayName("memory/self", assistantName: "小克"), "小克的记忆")
        XCTAssertEqual(FileLibraryMemoryFolder.displayName("memory/summaries", assistantName: "小克"), "旧对话摘要")
        XCTAssertNil(FileLibraryMemoryFolder.displayName("notes", assistantName: "小克"))
        XCTAssertNil(FileLibraryMemoryFolder.displayName("memory/cc/sub", assistantName: "小克"))
        XCTAssertTrue(FileLibraryMemoryFolder.isMemoryPath("memory"))
        XCTAssertTrue(FileLibraryMemoryFolder.isMemoryPath("memory/cc/x.md"))
        XCTAssertFalse(FileLibraryMemoryFolder.isMemoryPath("memory.md"))
        XCTAssertFalse(FileLibraryMemoryFolder.isMemoryPath("memorybook/x.md"))
        XCTAssertEqual(FileLibraryMemoryFolder.selfSlug("memory/self/复诊.md"), "复诊")
        XCTAssertNil(FileLibraryMemoryFolder.selfSlug("memory/cc/复诊.md"))
        XCTAssertNil(FileLibraryMemoryFolder.selfSlug("memory/self/a/b.md"))
    }
}
