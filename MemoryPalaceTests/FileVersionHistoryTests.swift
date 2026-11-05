import XCTest
@testable import 记忆花园

/// A4-2：版本历史列表的增删统计、「记录版本」总开关、虚拟文本 key、老表兼容、编辑器 versionKey 通道。
/// FileVersionStore 一律临时根目录，不碰真 Application Support。
final class FileVersionHistoryTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileVersionHistoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - 列表统计

    func testEntriesCountLinesAgainstOlderVersion() async throws {
        let store = FileVersionStore(root: root.appendingPathComponent("versions"))
        let key = FileVersionStore.Key.file(profileId: "floor-1", relativePath: "notes/a.md")
        try await store.record(key: key, content: "一\n二\n三\n", source: .external)
        try await store.record(key: key, content: "一\n二改\n三\n四\n", source: .manualSave)
        try await store.record(key: key, content: "一\n二改\n", source: .autoSave)

        let versions = try await store.versions(key: key)
        var contents: [String: String] = [:]
        for v in versions { contents[v.id] = try await store.content(key: key, id: v.id) }
        let entries = FileVersionHistory.entries(versions, contents: contents, current: "一\n二改\n三\n四\n")

        XCTAssertEqual(entries.map(\.version.source), [.autoSave, .manualSave, .external])
        XCTAssertEqual(entries[0].added, 0)
        XCTAssertEqual(entries[0].removed, 2)
        XCTAssertEqual(entries[1].added, 2)
        XCTAssertEqual(entries[1].removed, 1)
        XCTAssertNil(entries[2].added, "最老一版没有可比的上一版")
        XCTAssertEqual(entries.map(\.isOldest), [false, false, true])
        XCTAssertEqual(entries.map(\.matchesCurrent), [false, true, false])
    }

    func testEntriesSkipStatsWhenContentMissing() {
        let old = FileVersionStore.Version(id: "a", date: Date(), source: .manualSave, bytes: 1, sha256: "x")
        let new = FileVersionStore.Version(id: "b", date: Date(), source: .manualSave, bytes: 1, sha256: "y")
        let entries = FileVersionHistory.entries([new, old], contents: ["b": "新"], current: "")
        XCTAssertNil(entries[0].added)
        XCTAssertFalse(entries[0].isOldest)
    }

    // MARK: - 总开关（设置 → 文件库，10-15 起替代按文件夹开关）

    func testMasterSwitchDefaultsOnAndGatesRecording() throws {
        let suite = "FileVersionHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(FileVersionHistory.isEnabled(defaults), "没设过 = 默认开")
        defaults.set(false, forKey: FileVersionHistory.enabledKey)
        XCTAssertFalse(FileVersionHistory.isEnabled(defaults))
        defaults.set(true, forKey: FileVersionHistory.enabledKey)
        XCTAssertTrue(FileVersionHistory.isEnabled(defaults))

        let key = FileVersionStore.Key.file(profileId: "floor-1", relativePath: "a.md")
        XCTAssertEqual(FileVersionHistory.recordingKey(key, enabled: true), key, "库根下的文件也记")
        XCTAssertNil(FileVersionHistory.recordingKey(key, enabled: false))
        XCTAssertNil(FileVersionHistory.recordingKey(nil, enabled: true), "没有稳定 id 的新条目不记")
    }

    // MARK: - 虚拟文本 key

    func testVirtualKeysAreStableAndScoped() {
        XCTAssertEqual(FileVersionStore.Key.cardField(cardId: "c1", field: "description"),
                       .virtual("card/c1/description"))
        XCTAssertEqual(FileVersionStore.Key.cardField(cardId: "c1", field: "description").scope, "global", "卡不属于楼层")
        XCTAssertNotEqual(FileVersionStore.Key.cardField(cardId: "c1", field: "description"),
                          FileVersionStore.Key.cardField(cardId: "c1", field: "personality"))

        let entry = UUID()
        XCTAssertEqual(FileVersionStore.Key.worldBookEntry(bookId: "b1", entryId: entry),
                       .virtual("worldbook/b1/\(entry.uuidString)"))

        let floor = FileVersionStore.Key.floorSystemPrompt(profileId: "p1")
        XCTAssertEqual(floor, .virtual("floor/p1/systemPrompt", profileId: "p1"))
        XCTAssertEqual(floor.scope, "p1")
        XCTAssertNotEqual(floor, FileVersionStore.Key.file(profileId: "p1", relativePath: "floor/p1/systemPrompt"), "虚拟和真文件不撞")
    }

    // MARK: - 老表兼容（folder-styles.json 里按文件夹的 recordsVersions 不再读，但照旧能解、原样写回）

    func testSwitchRoundTripsAndOldTablesStayByteIdentical() throws {
        let url = root.appendingPathComponent("folder-styles.json")
        let plain = FileLibraryFolderLook(color: "mint", pattern: .flower, mark: .symbol("leaf"))
        try FileLibraryFolderStyleStore.save(["notes": plain], to: url)
        let before = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("recordsVersions"), "关着不写字段")

        var on = plain
        on.recordsVersions = true
        guard case .saved = try FileLibraryFolderStyleStore.update("notes", to: on, at: url) else {
            return XCTFail("应写成功")
        }
        XCTAssertEqual(FileLibraryFolderStyleStore.load(from: url)["notes"]?.recordsVersions, true)

        var off = on
        off.recordsVersions = nil
        _ = try FileLibraryFolderStyleStore.update("notes", to: off, at: url)
        XCTAssertEqual(try Data(contentsOf: url), before, "关掉后和老表逐字节一样")
    }

    func testOldJSONWithoutFieldDecodesOff() throws {
        let json = #"{"version":1,"folders":{"notes":{"color":"mint","mark":{"kind":"mono"}}}}"#
        let table = try JSONDecoder().decode(FileLibraryFolderStyleStore.Table.self, from: Data(json.utf8))
        XCTAssertNil(table.folders["notes"]?.recordsVersions)
        let bad = #"{"version":1,"folders":{"notes":{"color":"mint","mark":{"kind":"mono"},"recordsVersions":"yes"}}}"#
        let tolerant = try JSONDecoder().decode(FileLibraryFolderStyleStore.Table.self, from: Data(bad.utf8))
        XCTAssertNil(tolerant.folders["notes"]?.recordsVersions, "坏值当关，不拖垮整张表")
    }

    // MARK: - 编辑器通道

    @MainActor
    func testEditorCarriesVersionKey() {
        let key = FileVersionStore.Key.virtual("card/c1/description")
        let text = FileEditorSheet.text(title: "描述", text: "", format: .markdown, onSave: { _ in }, onCancel: {}, versionKey: key)
        XCTAssertEqual(text.versionKey, key)
        XCTAssertNil(FileEditorSheet.text(title: "描述", text: "", format: .plain, onSave: { _ in }, onCancel: {}).versionKey)

        let readOnly = FileEditorSheet(
            path: "memory/a.md", initialContent: "", initialModifiedAt: nil, readOnly: true,
            currentModifiedAt: { nil }, reloadExternalContent: { ReloadedFileContent(content: "", modifiedAt: nil) },
            onSave: { _, _ in }, onCancel: {},
            versionKey: .file(profileId: "p", relativePath: "memory/a.md")
        )
        XCTAssertNil(readOnly.versionKey, "只读不记版本")
    }

    func testSourceLabels() {
        XCTAssertEqual(FileVersionHistory.sourceLabel(.manualSave), "保存")
        XCTAssertEqual(FileVersionHistory.sourceLabel(.autoSave), "自动保存")
        XCTAssertEqual(FileVersionHistory.sourceLabel(.external), "载入")
        XCTAssertEqual(FileVersionHistory.sourceLabel(.restore), "恢复")
    }
}
