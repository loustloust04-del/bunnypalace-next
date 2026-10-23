import XCTest
@testable import 记忆花园

/// 修全局卡顿（10-03 Warden 派修）：文件库清单缓存——主线程只读缓存；本仓写入就地更新；路径与旧算法一致；
/// 大库（≥粟粟主楼层 1394 个文件）主线程耗时前后对比。固定测试楼层，tearDown 删整个楼层目录。
final class FileLibraryListCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // #033：本类直接测 store，测试自己站在主线程调——不算生产违规
        MainThreadIO.allowMainThreadInThisTest()
    }

    let pid = "xctest-filelib-list-cache"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.libraryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    /// 绕开本仓直接写盘（模拟书房 / 附件 / shell 写的文件）
    private func seed(folders: Int, filesPerFolder: Int, books: Int) throws {
        let root = FileLibraryStore.libraryRoot(profileId: pid)
        let fm = FileManager.default
        for f in 0..<folders {
            let dir = root.appendingPathComponent("folder\(f)/sub", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<filesPerFolder {
                try Data("第\(i)份 \(String(repeating: "字", count: 50))".utf8).write(to: dir.appendingPathComponent("note\(i).md"))
            }
        }
        let bookDir = root.appendingPathComponent("books/某本书", isDirectory: true)
        try fm.createDirectory(at: bookDir, withIntermediateDirectories: true)
        for i in 0..<books {
            try Data("章\(i)".utf8).write(to: bookDir.appendingPathComponent("ch\(i).md"))
        }
        try Data("根目录文件".utf8).write(to: root.appendingPathComponent("readme.md"))
    }

    /// 改动前的算法（逐文件 standardizedFileURL），只用来对照路径和计时
    private func legacyList(skipping: Set<String> = []) -> [FileLibraryStore.FileMeta] {
        let root = FileLibraryStore.libraryRoot(profileId: pid)
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        ) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var out: [FileLibraryStore.FileMeta] = []
        for case let url as URL in en {
            if !skipping.isEmpty, url.hasDirectoryPath {
                let rel = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
                if skipping.contains(rel) { en.skipDescendants(); continue }
            }
            guard FileLibraryStore.isSupportedFile(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            out.append(.init(path: rel, bytes: values?.fileSize ?? 0, modifiedAt: values?.contentModificationDate ?? .distantPast))
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func testPathsMatchLegacyAlgorithm() throws {
        try seed(folders: 3, filesPerFolder: 4, books: 5)
        XCTAssertEqual(FileLibraryStore.list(profileId: pid).map(\.path), legacyList().map(\.path))
        XCTAssertEqual(FileLibraryStore.list(profileId: pid, skippingTopLevelDirs: ["books"]).map(\.path),
                       legacyList(skipping: ["books"]).map(\.path))
    }

    func testCachedSkipFilterMatchesEnumerationSkip() throws {
        try seed(folders: 2, filesPerFolder: 3, books: 4)
        _ = FileLibraryStore.list(profileId: pid)
        XCTAssertEqual(FileLibraryStore.cachedList(profileId: pid, skippingTopLevelDirs: ["books"]).map(\.path),
                       FileLibraryStore.list(profileId: pid, skippingTopLevelDirs: ["books"]).map(\.path))
    }

    func testInAppWritesUpdateCacheImmediately() throws {
        try seed(folders: 1, filesPerFolder: 2, books: 0)
        _ = FileLibraryStore.list(profileId: pid)

        try FileLibraryStore.write("新建/刚写的.md", content: "hi", profileId: pid)
        XCTAssertTrue(FileLibraryStore.cachedList(profileId: pid).contains { $0.path == "新建/刚写的.md" }, "刚写完就列得到")

        try FileLibraryStore.append("新建/刚写的.md", content: "更多", profileId: pid)
        try FileLibraryStore.rename("新建/刚写的.md", to: "新建/改名了.md", profileId: pid)
        var paths = FileLibraryStore.cachedList(profileId: pid).map(\.path)
        XCTAssertFalse(paths.contains("新建/刚写的.md"))
        XCTAssertTrue(paths.contains("新建/改名了.md"))

        try FileLibraryStore.delete("新建/改名了.md", profileId: pid)
        paths = FileLibraryStore.cachedList(profileId: pid).map(\.path)
        XCTAssertFalse(paths.contains("新建/改名了.md"))
        XCTAssertEqual(paths, FileLibraryStore.list(profileId: pid).map(\.path), "就地更新后的缓存 = 重新枚举")
    }

    func testRemovedFolderLeavesCache() throws {
        try seed(folders: 2, filesPerFolder: 2, books: 3)
        _ = FileLibraryStore.list(profileId: pid)
        let dir = FileLibraryStore.libraryRoot(profileId: pid).appendingPathComponent("books/某本书", isDirectory: true)
        try FileManager.default.removeItem(at: dir)
        FileLibraryStore.noteFolderRemoved(dir, profileId: pid)
        XCTAssertFalse(FileLibraryStore.cachedList(profileId: pid).contains { $0.path.hasPrefix("books/某本书/") })
        XCTAssertEqual(FileLibraryStore.cachedList(profileId: pid).map(\.path), FileLibraryStore.list(profileId: pid).map(\.path))
    }

    func testInvalidateMarksStale() throws {
        try seed(folders: 1, filesPerFolder: 1, books: 0)
        _ = FileLibraryStore.list(profileId: pid)
        XCTAssertEqual(FileLibraryStore.ListCache.snapshot(profileId: pid)?.stale, false)
        FileLibraryStore.ListCache.invalidate(profileId: pid)
        XCTAssertEqual(FileLibraryStore.ListCache.snapshot(profileId: pid)?.stale, true)
    }

    func testFreshListSeesExternalWrites() async throws {
        try seed(folders: 1, filesPerFolder: 1, books: 0)
        _ = FileLibraryStore.list(profileId: pid)
        let root = FileLibraryStore.libraryRoot(profileId: pid)
        try Data("外部".utf8).write(to: root.appendingPathComponent("外部写的.md"))
        let fresh = await FileLibraryStore.freshList(profileId: pid)
        XCTAssertTrue(fresh.contains { $0.path == "外部写的.md" })
        XCTAssertTrue(FileLibraryStore.cachedList(profileId: pid).contains { $0.path == "外部写的.md" }, "后台扫完回填缓存")
    }

    /// 大库：100 个文件夹 × 20 + books 200 + 1 = 2201 个文件（粟粟主楼层 1394）
    func testMainThreadCostBeforeAfter() throws {
        try seed(folders: 100, filesPerFolder: 20, books: 200)
        func ms(_ n: Int, _ block: () -> Void) -> Double {
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<n { block() }
            return (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(n)
        }
        _ = legacyList(); _ = FileLibraryStore.list(profileId: pid)   // 预热文件系统缓存，两边公平
        let legacy = ms(5) { _ = legacyList(skipping: ["books"]) }
        let newEnum = ms(5) { _ = FileLibraryStore.list(profileId: pid, skippingTopLevelDirs: ["books"]) }
        _ = FileLibraryStore.list(profileId: pid)
        let cached = ms(20) { _ = FileLibraryStore.cachedList(profileId: pid, skippingTopLevelDirs: ["books"]) }
        print(String(format: "[LISTBENCH] files=%d legacy=%.1fms newEnum=%.1fms cachedMain=%.2fms",
                     FileLibraryStore.list(profileId: pid).count, legacy, newEnum, cached))
        XCTAssertLessThan(cached, legacy / 5, "主线程读缓存至少比旧的同步枚举快 5 倍")
    }
}
