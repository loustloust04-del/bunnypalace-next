import MemoryCore
import XCTest
@testable import 记忆花园

@MainActor
final class WikiEditingTests: XCTestCase {
    private var root: URL!
    private var wiki: WikiStore!
    private let path = "主题/虚构航线"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-editing-\(UUID().uuidString)", isDirectory: true)
        wiki = WikiStore(root: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSaveRejectsChangedPageWithoutTouchingHistory() async throws {
        try wiki.saveRaw("打开时", path: path)
        try wiki.saveRaw("别处改过", path: path)
        let history = wiki.history(path)
        do {
            try await WikiEditing.save("旧窗口改稿", baseline: "打开时", store: wiki, path: path)
            XCTFail("不能覆盖别处改过的页")
        } catch {
            XCTAssertEqual((error as NSError).domain, "Wiki")
        }
        XCTAssertEqual(wiki.readRaw(path), "别处改过")
        XCTAssertEqual(wiki.history(path), history)
    }

    func testSaveDoesNotRecreateDeletedPageIncludingEmptyOriginal() async throws {
        for original in ["打开时", ""] {
            try wiki.saveRaw(original, path: path)
            try FileManager.default.removeItem(at: wiki.pageURL(path))
            let history = wiki.history(path)
            do {
                try await WikiEditing.save("旧窗口改稿", baseline: original, store: wiki, path: path)
                XCTFail("旧窗口不能复活已删除页")
            } catch {
                XCTAssertEqual((error as NSError).domain, "Wiki")
            }
            XCTAssertFalse(wiki.pageExists(path))
            XCTAssertEqual(wiki.history(path), history)
        }
    }

    func testMatchingSaveSnapshotsExactPreviousContent() async throws {
        try wiki.saveRaw("打开时", path: path)
        let version = try await WikiEditing.save("人工改稿", baseline: "打开时", store: wiki, path: path)
        XCTAssertEqual(wiki.readRaw(path), "人工改稿")
        XCTAssertEqual(wiki.version(of: path), version)
        let history = wiki.history(path)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(wiki.historyText(path, entry: try XCTUnwrap(history.first).name), "打开时")
    }

    func testSaveRebuildsIndexesBeforeReturning() async throws {
        let original = WikiPage(path: path, title: "旧标题", now: "虚构航线")
        let edited = WikiPage(path: path, title: "人工新标题", now: "人工更新的虚构航线")
        try wiki.save(original)
        try wiki.rebuildAllIndexes()

        try await WikiEditing.save(edited.markdown, baseline: original.markdown, store: wiki, path: path)

        for folder in ["", "主题"] {
            let index = try String(contentsOf: wiki.folderURL(folder).appendingPathComponent(WikiStore.indexFileName), encoding: .utf8)
            let lines = index.components(separatedBy: "\n")
            XCTAssertTrue(lines.contains("- [[\(path)]] 人工新标题"), index)
            XCTAssertFalse(lines.contains("- [[\(path)]] 旧标题"), index)
        }
    }

    func testCanonicalLockKeyUnifiesAliasesButSeparatesFloors() async throws {
        let root = root!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let real = root.appendingPathComponent("profile-a/wiki", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("别名", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let keys = await Task.detached {
            [real, URL(fileURLWithPath: real.path + "/./"), URL(fileURLWithPath: real.path + "/"),
             alias, URL(fileURLWithPath: alias.path + "/./")]
                .map { WikiProposalReview.lockKey(WikiStore(root: $0)) }
        }.value
        XCTAssertEqual(Set(keys).count, 1)
        let other = WikiStore(root: root.appendingPathComponent("profile-b/wiki", isDirectory: true))
        let otherKey = await Task.detached { WikiProposalReview.lockKey(other) }.value
        XCTAssertNotEqual(keys[0], otherKey)
    }
}
