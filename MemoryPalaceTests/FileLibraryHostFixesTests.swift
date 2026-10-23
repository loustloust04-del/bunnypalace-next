#if os(macOS)
import XCTest
@testable import 记忆花园

/// plan-离线沙箱-phase2 §1.5 宿主三修族（T3c）的回归锚。
/// 这个 target 是 macOS-only，正好能直接测宿主侧语义。
final class FileLibraryHostFixesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // #033：本类直接测 store，测试自己站在主线程调——不算生产违规
        MainThreadIO.allowMainThreadInThisTest()
    }
    private let profileId = "test-hostfix-\(UUID().uuidString.prefix(8))"

    private var root: URL { FileLibraryStore.libraryRoot(profileId: profileId) }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        FileLibraryStore.forgetSlug(profileId: profileId)   // 假楼层映射别留在真实数据里（review-mac-hang-probe）
        super.tearDown()
    }

    // MARK: - R5：resolve() 解 symlink 后再判 containment

    func testResolveRejectsSymlinkPointingOutsideRoot() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostfix-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "库外的秘密".write(to: outside.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("escape")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertNil(FileLibraryStore.resolve("escape/secret.md", profileId: profileId),
                     "库根下指向根外的 symlink 不能把路径带出去")
    }

    func testResolveStillAllowsSymlinkPointingInsideRoot() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try "库内".write(to: root.appendingPathComponent("real/a.md"), atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("inside")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real"))

        XCTAssertNotNil(FileLibraryStore.resolve("inside/a.md", profileId: profileId),
                        "库内互链是正常用法，不该被误伤")
    }

    // MARK: - E5/R5：写入口拒绝把 symlink 当普通文件覆盖

    func testWriteRefusesToOverwriteSymlink() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostfix-target-\(UUID().uuidString).md")
        try "原始内容".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("note.md")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try FileLibraryStore.write("note.md", content: "写穿", profileId: profileId))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "原始内容", "库外文件不能被写穿")
    }

    // MARK: - R10：文件名 clamp 255 UTF-8 字节

    func testClampKeepsExtensionAndByteLimit() {
        let long = String(repeating: "中", count: 300) + ".md"
        let clamped = FileLibraryStore.clampComponent(long)
        XCTAssertLessThanOrEqual(clamped.utf8.count, 255)
        XCTAssertTrue(clamped.hasSuffix(".md"), "扩展名要保住")
        XCTAssertFalse(clamped.isEmpty)
    }

    func testClampCutsOnGraphemeBoundary() {
        let long = String(repeating: "👩‍👩‍👧‍👦", count: 60) + ".md"
        let clamped = FileLibraryStore.clampComponent(long)
        XCTAssertLessThanOrEqual(clamped.utf8.count, 255)
        XCTAssertFalse(clamped.unicodeScalars.contains { $0 == "\u{FFFD}" }, "不能切出替换字符")
    }

    func testClampLeavesShortNamesAlone() {
        XCTAssertEqual(FileLibraryStore.clampComponent("笔记.md"), "笔记.md")
    }

    func testWriteWithVeryLongChineseNameSucceeds() throws {
        let name = String(repeating: "长", count: 300) + ".md"
        try FileLibraryStore.write(name, content: "ok", profileId: profileId)
        XCTAssertEqual(FileLibraryStore.list(profileId: profileId).count, 1)
    }

    // MARK: - R11：冲突检测按内容哈希，不看 mtime

    func testConflictDetectedWhenContentDiffersEvenIfMtimeUnchanged() throws {
        try FileLibraryStore.write("c.md", content: "A", profileId: profileId)
        let url = try XCTUnwrap(FileLibraryStore.resolve("c.md", profileId: profileId))
        let mtime = try XCTUnwrap(FileLibraryStore.modifiedAt("c.md", profileId: profileId))
        try "B".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)

        XCTAssertEqual(FileLibraryStore.modifiedAt("c.md", profileId: profileId)?.timeIntervalSince1970 ?? -1,
                       mtime.timeIntervalSince1970, accuracy: 1.0, "前提：mtime 确实没变")
        XCTAssertTrue(FileLibraryStore.hasExternalConflict("c.md", profileId: profileId, baselineContent: "A"),
                      "同 mtime 不同内容必须判冲突")
    }

    func testNoConflictWhenContentSameEvenIfMtimeChanged() throws {
        try FileLibraryStore.write("d.md", content: "same", profileId: profileId)
        let url = try XCTUnwrap(FileLibraryStore.resolve("d.md", profileId: profileId))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(600)],
                                              ofItemAtPath: url.path)
        XCTAssertFalse(FileLibraryStore.hasExternalConflict("d.md", profileId: profileId, baselineContent: "same"),
                       "碰过但内容没变，不该误报冲突")
    }

    func testNoConflictWhenFileMissing() {
        XCTAssertFalse(FileLibraryStore.hasExternalConflict("never.md", profileId: profileId, baselineContent: "x"))
    }

    // MARK: - R7：写操作走进程级串行队列

    func testConcurrentWritesDoNotCorrupt() throws {
        let payloads = (0..<50).map { String(repeating: "\($0 % 10)", count: 2000) }
        let group = DispatchGroup()
        for p in payloads {
            group.enter()
            DispatchQueue.global().async {
                try? FileLibraryStore.write("hot.md", content: p, profileId: self.profileId)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

        let final = try FileLibraryStore.read("hot.md", profileId: profileId)
        XCTAssertTrue(payloads.contains(final), "并发写后内容必须是某一次写的完整值，长度=\(final.count)")
    }

    // MARK: - floorSlug 兜底去重

    func testFallbackSlugsDoNotCollideOnSharedPrefix() {
        let a = "collideXaaa\(UUID().uuidString.prefix(4))"
        let b = "collideXbbb\(UUID().uuidString.prefix(4))"
        let slugA = FileLibraryStore.floorSlug(profileId: a)
        _ = FileLibraryStore.libraryRoot(profileId: a)   // 先落盘，B 才有机会撞上
        let slugB = FileLibraryStore.floorSlug(profileId: b)
        defer {
            let base = FileLibraryStore.documentsBaseRoot()
            try? FileManager.default.removeItem(at: base.appendingPathComponent(slugA))
            try? FileManager.default.removeItem(at: base.appendingPathComponent(slugB))
            FileLibraryStore.forgetSlug(profileId: a)
            FileLibraryStore.forgetSlug(profileId: b)
        }
        XCTAssertNotEqual(slugA, slugB, "两个前 8 字母数字相同的 profileId 不能共用一个楼层目录")
    }
}
#endif
