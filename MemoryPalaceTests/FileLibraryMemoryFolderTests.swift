import XCTest
@testable import 记忆花园

/// 第二刀验收返工④②：记忆树在文件库里当普通文件夹显示；自己的记忆永远在、排第一；只读判定。
final class FileLibraryMemoryFolderTests: XCTestCase {

    private func meta(_ path: String, _ t: TimeInterval = 0) -> FileLibraryStore.FileMeta {
        .init(path: path, bytes: 10, modifiedAt: Date(timeIntervalSince1970: 1_800_000_000 + t))
    }

    private func merged(library: [FileLibraryStore.FileMeta], memory: [FileLibraryStore.FileMeta]) -> [String: FileLibraryDisplay.FolderContents] {
        var index = FileLibraryDisplay.folderIndex(library)
        FileLibraryMemoryFolder.merge(FileLibraryMemoryFolder.folderIndex(memory), into: &index)
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
        XCTAssertEqual(index["memory"]?.folders.map(\.path), ["memory/self", "memory/summaries", "memory/cc", "memory/wiki"], "self 永远在且排第一，空 C 档案也在")
        XCTAssertEqual(index["memory"]?.files.map(\.path), ["memory/profile.md"])
        XCTAssertEqual(index["memory/self"]?.files.count, 0)
    }

    func testSelfFirstEvenWhenOlderAndIndexHidden() {
        let index = merged(library: [],
                           memory: [meta("memory/self/复诊.md", 1), meta("memory/self/INDEX.md", 99), meta("memory/daily/d.md", 50)])
        XCTAssertEqual(index["memory"]?.folders.map(\.path), ["memory/self", "memory/daily", "memory/wiki"])
        XCTAssertEqual(index["memory/self"]?.files.map(\.path), ["memory/self/复诊.md"], "INDEX.md 不显示")
        XCTAssertEqual(index["memory"]?.folders.first?.fileCount, 1)
    }

    func testEmptyMemoryStillHasWikiAndDiagnosticFolders() {
        let index = merged(library: [meta("a.md")], memory: [])
        XCTAssertEqual(index[""]?.folders.map(\.path), ["memory"])
        XCTAssertEqual(index[""]?.folders.first?.fileCount, 0)
        XCTAssertEqual(index["memory"]?.folders.map(\.path), ["memory/self", "memory/wiki"])
        XCTAssertEqual(Set(index["memory/wiki"]?.folders.map(\.path) ?? []),
                       [FileLibraryMemoryFolder.runsFolder, FileLibraryMemoryFolder.draftsFolder])
        for path in ["memory/self", "memory/wiki", FileLibraryMemoryFolder.runsFolder, FileLibraryMemoryFolder.draftsFolder] {
            XCTAssertTrue(index[path]?.files.isEmpty == true, path)
        }
        XCTAssertNil(index["memory/wiki/.proposals"])
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

    func testDiagnosticWhitelistAndReadOnlyPaths() {
        let allowed = ["memory/wiki/.runs/run.md", "memory/wiki/.proposals/drafts/run.txt",
                       "memory/wiki/.proposals/drafts/run.md"]
        let hidden = ["memory/wiki/.history/旧版.md", "memory/wiki/.proposals/p.json",
                      "memory/wiki/.proposals/drafts/p.json", "memory/wiki/.proposals/other.txt",
                      "memory/wiki/.runs/raw.txt", "memory/wiki/.runs/nested/run.md",
                      "memory/wiki/.runs/.hidden.md", "memory/wiki/工程/.group.md"]
        XCTAssertEqual(FileLibraryMemoryFolder.visible((allowed + hidden).map { meta($0) }).map(\.path), allowed)
        for path in allowed {
            XCTAssertTrue(FileLibraryMemoryFolder.isMemoryPath(path))
            XCTAssertTrue(FileLibraryMemoryFolder.isHiddenWikiPath(path), "助手隐藏规则不能因 UI 白名单放开")
            XCTAssertNil(FileLibraryMemoryFolder.selfSlug(path), "诊断记录不能走自己的记忆编辑器")
            XCTAssertNil(FileLibraryMemoryFolder.wikiPagePath(path), "诊断记录不能走 wiki 页编辑器")
        }
        XCTAssertEqual(FileLibraryMemoryFolder.parentFolder(allowed[1]), FileLibraryMemoryFolder.draftsFolder)
        XCTAssertEqual(FileLibraryMemoryFolder.parentFolder("memory/wiki/楼层/主题/电影.md"), "memory/wiki/楼层/主题")
        XCTAssertEqual(FileLibraryMemoryFolder.displayName(FileLibraryMemoryFolder.runsFolder, assistantName: "阿雾"), "整理记录")
        XCTAssertEqual(FileLibraryMemoryFolder.displayName(FileLibraryMemoryFolder.draftsFolder, assistantName: "阿雾"), "模型原始输出")
        XCTAssertTrue(FileLibraryMemoryFolder.isDiagnosticFolder(FileLibraryMemoryFolder.runsFolder))
        XCTAssertTrue(FileLibraryMemoryFolder.isDiagnosticFolder(FileLibraryMemoryFolder.draftsFolder))
        XCTAssertFalse(FileLibraryMemoryFolder.isDiagnosticFolder("memory/wiki"))
    }

    func testDiagnosticsStayNewestFirstAfterUserNameSorting() {
        let files = [meta("memory/wiki/.runs/z-new.md", 50), meta("memory/wiki/.runs/a-old.md", 1),
                     meta("memory/wiki/.proposals/drafts/z-new.txt", 40), meta("memory/wiki/.proposals/drafts/a-old.md", 2)]
        let userSorted = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var index = FileLibraryMemoryFolder.folderIndex(userSorted)
        for key in Array(index.keys) {
            index[key]?.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        FileLibraryMemoryFolder.pinSelfFirst(&index)
        XCTAssertEqual(index[FileLibraryMemoryFolder.runsFolder]?.files.map(\.path),
                       ["memory/wiki/.runs/z-new.md", "memory/wiki/.runs/a-old.md"])
        XCTAssertEqual(index[FileLibraryMemoryFolder.draftsFolder]?.files.map(\.path),
                       ["memory/wiki/.proposals/drafts/z-new.txt", "memory/wiki/.proposals/drafts/a-old.md"])
        XCTAssertEqual(Set(index["memory/wiki"]?.folders.map(\.path) ?? []),
                       [FileLibraryMemoryFolder.runsFolder, FileLibraryMemoryFolder.draftsFolder])
        XCTAssertNil(index["memory/wiki/.proposals"])
        XCTAssertNil(index[FileLibraryMemoryFolder.draftsStorageFolder], "不能泄漏中间提案目录")
        XCTAssertEqual(index[""]?.folders.first?.fileCount, 4)
        XCTAssertEqual(index["memory"]?.folders.first { $0.path == "memory/wiki" }?.fileCount, 4)
    }

    func testMemoryUIListMissingWikiDoesNotCreateDirectories() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("memory", isDirectory: true)
        let missingList = await Task.detached {
            FileLibraryStore.memoryUIList(profileId: "unused", memoryRoot: root)
        }.value
        XCTAssertTrue(missingList.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "虚拟入口不能创建记忆根")
        XCTAssertNotNil(FileLibraryMemoryFolder.folderIndex(missingList)["memory/wiki"])

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let emptyList = await Task.detached {
            FileLibraryStore.memoryUIList(profileId: "unused", memoryRoot: root)
        }.value
        XCTAssertTrue(emptyList.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("wiki").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertNotNil(FileLibraryMemoryFolder.folderIndex(emptyList)["memory/wiki"])

        let wiki = root.appendingPathComponent("wiki", isDirectory: true)
        try FileManager.default.createDirectory(at: wiki, withIntermediateDirectories: true)
        let emptyWikiList = await Task.detached {
            FileLibraryStore.memoryUIList(profileId: "unused", memoryRoot: root)
        }.value
        XCTAssertTrue(emptyWikiList.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: wiki.path).isEmpty,
                      "诊断入口不能创建 .runs / .proposals")
        let index = FileLibraryMemoryFolder.folderIndex(emptyWikiList)
        XCTAssertNotNil(index[FileLibraryMemoryFolder.runsFolder])
        XCTAssertNotNil(index[FileLibraryMemoryFolder.draftsFolder])
    }

    func testMemoryUIListEnumeratesOnlyReadableDiagnosticFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, time: TimeInterval = 0) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# 合成内容\n工具原文".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 + time)],
                                                  ofItemAtPath: url.path)
        }
        let paths = ["self/事实.md", "wiki/楼层/主题/电影.md", "wiki/.runs/z-new.md", "wiki/.runs/a-old.md",
                     "wiki/.proposals/drafts/z-new.txt", "wiki/.proposals/drafts/a-old.md", ".x/y.md"]
        for (offset, path) in paths.enumerated() { try write(path, time: TimeInterval(20 - offset)) }
        for path in ["self/INDEX.md", "wiki/.history/旧.md", "wiki/.proposals/p.json",
                     "wiki/.proposals/drafts/p.json", "wiki/.proposals/other.txt", "wiki/楼层/.group.md",
                     "wiki/.runs/nested/run.md", "wiki/.runs/.hidden.md", "wiki/.runs/not-a-run.txt"] {
            try write(path)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("wiki/.runs/directory.md"),
                                                withIntermediateDirectories: true)
        let list = await Task.detached {
            FileLibraryStore.memoryUIList(profileId: "unused", memoryRoot: root)
        }.value
        XCTAssertEqual(Set(list.map(\.path)), Set(paths.map { "memory/" + $0 }))
        XCTAssertTrue(list.allSatisfy { $0.bytes > 0 })
        let index = FileLibraryMemoryFolder.folderIndex(list)
        XCTAssertEqual(index[FileLibraryMemoryFolder.runsFolder]?.files.map(\.path),
                       ["memory/wiki/.runs/z-new.md", "memory/wiki/.runs/a-old.md"])
        XCTAssertEqual(index[FileLibraryMemoryFolder.draftsFolder]?.files.map(\.path),
                       ["memory/wiki/.proposals/drafts/z-new.txt", "memory/wiki/.proposals/drafts/a-old.md"])
        XCTAssertNil(index["memory/wiki/.proposals"])
    }

    func testDiagnosticDirectorySymlinksCannotEnumerateOutsideMemoryRoot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("memory", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let wiki = root.appendingPathComponent("wiki", isDirectory: true)
        try FileManager.default.createDirectory(at: wiki.appendingPathComponent(".proposals"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("不可见的外部内容".utf8).write(to: outside.appendingPathComponent("run.md"))
        try FileManager.default.createSymbolicLink(at: wiki.appendingPathComponent(".runs"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: wiki.appendingPathComponent(".proposals/drafts"), withDestinationURL: outside)
        let list = await Task.detached {
            FileLibraryStore.memoryUIList(profileId: "unused", memoryRoot: root)
        }.value
        XCTAssertTrue(list.isEmpty, "白名单目录的符号链接不能把记忆根之外的内容带进 UI")
    }
}
