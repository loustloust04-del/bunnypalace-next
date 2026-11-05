import XCTest
@testable import 记忆花园

/// A4-1：版本快照存储 + 行级 diff。根目录一律临时目录，不碰真 Application Support。
final class FileVersionStoreTests: XCTestCase {
    var root: URL!
    var store: FileVersionStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileVersionStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = FileVersionStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func allFiles() throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: root.path)
    }

    // MARK: - 存储

    func testDedupAgainstLatestOnly() async throws {
        let key = FileVersionStore.Key.file(profileId: "floor-1", relativePath: "notes/a.md")
        let first = try await store.record(key: key, content: "一", source: .manualSave)
        XCTAssertNotNil(first)
        let same = try await store.record(key: key, content: "一", source: .autoSave)
        XCTAssertNil(same)
        try await store.record(key: key, content: "二", source: .autoSave)
        // 只和最新一版比：回到旧内容照样记
        let back = try await store.record(key: key, content: "一", source: .restore)
        XCTAssertNotNil(back)

        let versions = try await store.versions(key: key)
        XCTAssertEqual(versions.map(\.source), [.restore, .autoSave, .manualSave])
        XCTAssertEqual(versions.first?.id, back?.id)
        XCTAssertEqual(versions.last?.bytes, 3)
        let firstId = try XCTUnwrap(first?.id)
        let text = try await store.content(key: key, id: firstId)
        XCTAssertEqual(text, "一")
    }

    func testKeepsAtMost100Versions() async throws {
        let key = FileVersionStore.Key.virtual("card/c1/description")
        for i in 0..<105 { try await store.record(key: key, content: "v\(i)", source: .autoSave) }

        let versions = try await store.versions(key: key)
        XCTAssertEqual(versions.count, FileVersionStore.maxVersions)
        let newest = try await store.content(key: key, id: versions[0].id)
        let oldest = try await store.content(key: key, id: versions[99].id)
        XCTAssertEqual(newest, "v104")
        XCTAssertEqual(oldest, "v5")
        let dir = store.directory(for: key)
        let txt = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(txt.count, 100)
    }

    func testKeyEncodingCannotEscapeRoot() async throws {
        let keys: [FileVersionStore.Key] = [
            .file(profileId: "../../evil", relativePath: "../../../etc/passwd"),
            .file(profileId: "..", relativePath: ".."),
            .virtual("../../x", profileId: "/tmp"),
            .virtual(String(repeating: "很长的路径/", count: 80)),
            .virtual(""),
        ]
        for key in keys {
            try await store.record(key: key, content: "x", source: .manualSave)
            let dir = store.directory(for: key)
            XCTAssertEqual(dir.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
                           root.standardizedFileURL.path)
            for component in [dir.lastPathComponent, dir.deletingLastPathComponent().lastPathComponent] {
                XCTAssertFalse(component.contains("/"))
                XCTAssertFalse(component.contains("."))
                XCTAssertFalse(component.isEmpty)
                XCTAssertLessThanOrEqual(component.utf8.count, 255)
            }
            let count = try await store.versions(key: key).count
            XCTAssertEqual(count, 1)
        }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            XCTAssertTrue(url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(rootPath + "/"))
        }
        // 大小写不同的 key 不能落进同一个目录（APFS 默认大小写不敏感）
        XCTAssertNotEqual(FileVersionStore.encodeComponent("Notes").lowercased(),
                          FileVersionStore.encodeComponent("notes").lowercased())
        // 文件 key 和虚拟 key 同名也不撞
        XCTAssertNotEqual(store.directory(for: .file(profileId: "global", relativePath: "a")),
                          store.directory(for: .virtual("a")))
    }

    func testContentRejectsUnknownId() async throws {
        let key = FileVersionStore.Key.virtual("preset/p1/main")
        try await store.record(key: key, content: "secret", source: .manualSave)
        let traversal = try await store.content(key: key, id: "../index")
        let unknown = try await store.content(key: key, id: "index")
        XCTAssertNil(traversal)
        XCTAssertNil(unknown)
    }

    func testAtomicWriteLeavesNoTempAndCorruptIndexIsNotOverwritten() async throws {
        let key = FileVersionStore.Key.file(profileId: "floor-1", relativePath: "a.md")
        for i in 0..<3 { try await store.record(key: key, content: "\(i)", source: .autoSave) }
        XCTAssertTrue(try allFiles().allSatisfy { !($0 as NSString).lastPathComponent.hasPrefix(".tmp-") })

        // 崩溃残留的临时文件不影响读写
        let dir = store.directory(for: key)
        try Data("half".utf8).write(to: dir.appendingPathComponent(".tmp-leftover"))
        try await store.record(key: key, content: "3", source: .autoSave)
        let count = try await store.versions(key: key).count
        XCTAssertEqual(count, 4)

        // index 读不通：抛错，不拿空 index 覆盖
        let indexURL = dir.appendingPathComponent("index.json")
        let garbage = Data("{not json".utf8)
        try garbage.write(to: indexURL)
        do {
            try await store.record(key: key, content: "4", source: .autoSave)
            XCTFail("坏 index 应该抛错")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: indexURL), garbage)
    }

    func testDeleteRemovesOnlyThatKey() async throws {
        let a = FileVersionStore.Key.virtual("worldbook/w1/entry/e1")
        let b = FileVersionStore.Key.virtual("worldbook/w1/entry/e2")
        try await store.record(key: a, content: "a", source: .manualSave)
        try await store.record(key: b, content: "b", source: .manualSave)
        try await store.delete(key: a)
        let left = try await store.versions(key: a)
        let kept = try await store.versions(key: b)
        XCTAssertTrue(left.isEmpty)
        XCTAssertEqual(kept.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: a).path))
        try await store.delete(key: a)
    }

    func testDefaultRootIsApplicationSupportVersions() {
        let path = FileVersionStore().root.path
        XCTAssertTrue(path.hasSuffix("Application Support/MemoryPalace/versions"), path)
    }

    // MARK: - LineDiff

    private func marks(_ result: LineDiff.Result) -> [String] {
        result.lines.map { line in
            let sign = line.change == .added ? "+" : line.change == .removed ? "-" : " "
            return sign + line.text + (line.missingNewline ? "$" : "")
        }
    }

    func testDiffModifyInsertDelete() {
        let modified = LineDiff.compute(old: "a\nb\nc\n", new: "a\nB\nc\n")
        XCTAssertEqual(marks(modified), [" a", "-b", "+B", " c"])
        XCTAssertEqual(modified.added, 1)
        XCTAssertEqual(modified.removed, 1)

        let inserted = LineDiff.compute(old: "a\nc\n", new: "a\nb\nc\nd\n")
        XCTAssertEqual(marks(inserted), [" a", "+b", " c", "+d"])
        XCTAssertEqual(inserted.lines.map(\.newNumber), [1, 2, 3, 4])
        XCTAssertEqual(inserted.lines.map(\.oldNumber), [1, nil, 2, nil])

        let deleted = LineDiff.compute(old: "a\nb\nc\n", new: "c\n")
        XCTAssertEqual(marks(deleted), ["-a", "-b", " c"])
        XCTAssertEqual(deleted.added, 0)
        XCTAssertEqual(deleted.removed, 2)
    }

    func testDiffEmptyFiles() {
        XCTAssertEqual(LineDiff.compute(old: "", new: "").lines, [])
        let created = LineDiff.compute(old: "", new: "x\ny\n")
        XCTAssertEqual(marks(created), ["+x", "+y"])
        let cleared = LineDiff.compute(old: "x\ny", new: "")
        XCTAssertEqual(marks(cleared), ["-x", "-y$"])
        XCTAssertEqual(cleared.removed, 2)
    }

    func testDiffTrailingNewlineAndCRLF() {
        let added = LineDiff.compute(old: "a\nb", new: "a\nb\n")
        XCTAssertEqual(marks(added), [" a", "-b$", "+b"])
        XCTAssertEqual(LineDiff.compute(old: "a\n", new: "a\n").added, 0)
        // 以换行结尾不多一行空行；中间空行照常算行
        XCTAssertEqual(marks(LineDiff.compute(old: "a\n\nb\n", new: "a\n\nb\n")), [" a", " ", " b"])
        // CRLF 是一个 grapheme，也要当换行切
        XCTAssertEqual(marks(LineDiff.compute(old: "x\r\ny\r\n", new: "x\r\nz\r\n")), [" x", "-y", "+z"])
    }

    func testDiffLargeFilesFinishQuickly() {
        let old = (0..<5000).map { "第 \($0) 行 lorem ipsum" }
        var sparse = old
        for i in stride(from: 0, to: 5000, by: 50) { sparse[i] = "改过 \(i)" }
        var start = Date()
        let edited = LineDiff.compute(old: old.joined(separator: "\n"), new: sparse.joined(separator: "\n"))
        XCTAssertEqual(edited.added, 100)
        XCTAssertEqual(edited.removed, 100)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)

        start = Date()
        let rewritten = LineDiff.compute(old: old.joined(separator: "\n"),
                                         new: old.map { "新" + $0 }.joined(separator: "\n"))
        XCTAssertEqual(rewritten.added, 5000)
        XCTAssertEqual(rewritten.removed, 5000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
