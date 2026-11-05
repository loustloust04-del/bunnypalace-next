import XCTest
@testable import 记忆花园

/// 编辑器「回到上次位置」的存储：读写、落盘重读、LRU 300 条、删 / 改名清理。一律临时目录，不碰真 Application Support。
@MainActor
final class FileEditorPositionStoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileEditorPositionStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var url: URL { dir.appendingPathComponent("editor-positions.json") }

    func testRoundTripsThroughFile() {
        let store = FileEditorPositionStore(url: url)
        let key = FileVersionStore.Key.file(profileId: "floor-1", relativePath: "notes/a.md")
        XCTAssertNil(store.position(for: key))
        store.set(.init(anchor: 10, head: 14, top: 3), for: key)
        XCTAssertEqual(store.position(for: key), .init(anchor: 10, head: 14, top: 3))

        let reopened = FileEditorPositionStore(url: url)
        XCTAssertEqual(reopened.position(for: key), .init(anchor: 10, head: 14, top: 3), "重开 app 读得回来")
        XCTAssertNil(reopened.position(for: .file(profileId: "floor-2", relativePath: "notes/a.md")), "按楼层分开")
    }

    func testVirtualKeysDoNotCollideWithFiles() {
        let store = FileEditorPositionStore(url: url)
        store.set(.init(anchor: 1, head: 1, top: 0), for: .cardField(cardId: "c1", field: "description"))
        XCTAssertNil(store.position(for: .file(profileId: "global", relativePath: "card/c1/description")))
        XCTAssertEqual(store.position(for: .cardField(cardId: "c1", field: "description"))?.anchor, 1)
    }

    func testKeepsMostRecent300() {
        let store = FileEditorPositionStore(url: url)
        let keys = (0..<(FileEditorPositionStore.maxEntries + 5)).map { FileVersionStore.Key.file(profileId: "p", relativePath: "f\($0).md") }
        for (i, key) in keys.enumerated() {
            store.set(.init(anchor: i, head: i, top: i), for: key)
            // 第 0 个一直在用：每次重新写入都挪到最新，不该被挤掉
            if i % 50 == 0 { store.set(.init(anchor: 0, head: 0, top: i), for: keys[0]) }
        }
        let reopened = FileEditorPositionStore(url: url)
        XCTAssertNotNil(reopened.position(for: keys[0]), "最近用过的留着")
        XCTAssertNil(reopened.position(for: keys[1]), "最久没用的挤掉")
        XCTAssertNotNil(reopened.position(for: keys.last!))
        let table = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual((table?["entries"] as? [Any])?.count, FileEditorPositionStore.maxEntries)
    }

    func testRemoveClearsEntry() {
        let store = FileEditorPositionStore(url: url)
        let a = FileVersionStore.Key.file(profileId: "p", relativePath: "a.md")
        let b = FileVersionStore.Key.file(profileId: "p", relativePath: "b.md")
        store.set(.init(anchor: 1, head: 1, top: 1), for: a)
        store.set(.init(anchor: 2, head: 2, top: 2), for: b)
        store.remove(a)
        XCTAssertNil(FileEditorPositionStore(url: url).position(for: a), "删 / 改名后旧 key 清掉")
        XCTAssertEqual(FileEditorPositionStore(url: url).position(for: b)?.anchor, 2)
    }

    func testCorruptFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = FileEditorPositionStore(url: url)
        let key = FileVersionStore.Key.file(profileId: "p", relativePath: "a.md")
        XCTAssertNil(store.position(for: key))
        store.set(.init(anchor: 3, head: 3, top: 0), for: key)
        XCTAssertEqual(FileEditorPositionStore(url: url).position(for: key)?.anchor, 3)
    }

    func testDefaultLocationIsApplicationSupportNotDefaults() {
        let path = FileEditorPositionStore().url.path
        XCTAssertTrue(path.hasSuffix("MemoryPalace/editor-positions.json"))
        XCTAssertTrue(path.contains("Application Support"))
    }

    func testCaretColorMatchesWebEditor() {
        XCTAssertEqual(FileEditorCaret.cssHex.count, 7)
        XCTAssertTrue(FileEditorCaret.cssHex.hasPrefix("#"))
        XCTAssertNotEqual(FileEditorCaret.lightHex, FileEditorCaret.darkHex, "深色下稍亮")
    }
}
