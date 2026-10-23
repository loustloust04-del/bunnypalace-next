import XCTest
@testable import 记忆花园

/// 磨砂文件夹外观（plan-file-library-folders §存储 / §默认样式 / §颜色）
final class FileLibraryFolderStyleTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("folder-styles-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var url: URL { dir.appendingPathComponent(".memorypalace/folder-styles.json") }

    func testRoundTrip() throws {
        let table: [String: FileLibraryFolderLook] = [
            "journal": FileLibraryFolderLook(color: "rose", pattern: .flower, mark: .symbol("pencil")),
            "旅行/海边": FileLibraryFolderLook(color: "#A1B2C3", mark: .emoji("🏝️")),
            "x": FileLibraryFolderLook(color: "ink", pattern: .snow, mark: .none),
        ]
        try FileLibraryFolderStyleStore.save(table, to: url)
        XCTAssertEqual(FileLibraryFolderStyleStore.load(from: url), table)
        let json = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
        XCTAssertTrue(json.contains("\"version\" : 1"))
    }

    func testMissingFileIsEmpty() {
        XCTAssertEqual(FileLibraryFolderStyleStore.load(from: url), [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBadJSONIsEmptyAndUntouched() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bad = Data("{\"version\":1,\"folders\":".utf8)
        try bad.write(to: url)
        XCTAssertEqual(FileLibraryFolderStyleStore.load(from: url), [:])
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }

    func testUnknownValuesFallBackPerEntry() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {"version":1,"folders":{
          "a":{"color":"neon","pattern":"zigzag","mark":{"kind":"sticker","value":"x"}},
          "b":{"color":"mint","pattern":null,"mark":{"kind":"symbol"}},
          "c":{"color":"#12345G","pattern":"beads","mark":{"kind":"emoji","value":"🌸"}}
        }}
        """
        try Data(json.utf8).write(to: url)
        let table = FileLibraryFolderStyleStore.load(from: url)
        XCTAssertEqual(table["a"], FileLibraryFolderLook(color: "cream", mark: .mono))
        XCTAssertEqual(table["b"], FileLibraryFolderLook(color: "mint", mark: .mono))
        XCTAssertEqual(table["c"], FileLibraryFolderLook(color: "cream", pattern: .beads, mark: .emoji("🌸")))
    }

    func testSaveSkipsIdenticalContent() throws {
        let table = ["journal": FileLibraryFolderLook(color: "rose", mark: .symbol("pencil"))]
        try FileLibraryFolderStyleStore.save(table, to: url)
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        try FileLibraryFolderStyleStore.save(table, to: url)
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(mtime, past)
    }

    /// 磁盘上 A、B 两条（B 是别的设备写的，界面内存里只有 A）：改 A 不能丢 B
    func testUpdateMergesWithDiskTable() throws {
        let a = FileLibraryFolderLook(color: "rose", mark: .symbol("pencil"))
        let b = FileLibraryFolderLook(color: "mint", pattern: .snow, mark: .mono)
        try FileLibraryFolderStyleStore.save(["A": a, "B": b], to: url)
        let newA = FileLibraryFolderLook(color: "ink", mark: .emoji("🌸"))
        let outcome = try FileLibraryFolderStyleStore.update("A", to: newA, at: url)
        XCTAssertEqual(outcome, .saved(["A": newA, "B": b]))
        XCTAssertEqual(FileLibraryFolderStyleStore.load(from: url), ["A": newA, "B": b])
        XCTAssertEqual(try FileLibraryFolderStyleStore.update("A", to: nil, at: url), .saved(["B": b]))
        XCTAssertEqual(FileLibraryFolderStyleStore.load(from: url), ["B": b])
    }

    func testUpdateCreatesFileWhenMissing() throws {
        let a = FileLibraryFolderLook(color: "sand", mark: .mono)
        XCTAssertEqual(try FileLibraryFolderStyleStore.update("A", to: a, at: url), .saved(["A": a]))
        XCTAssertEqual(FileLibraryFolderStyleStore.load(from: url), ["A": a])
    }

    func testUpdateRefusesBadJSON() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bad = Data("{\"version\":1,\"folders\":{\"B\":".utf8)
        try bad.write(to: url)
        let outcome = try FileLibraryFolderStyleStore.update("A", to: FileLibraryFolderLook(color: "rose", mark: .mono), at: url)
        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }

    func testUpdateRefusesICloudPlaceholder() throws {
        let dirURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let placeholder = dirURL.appendingPathComponent(".folder-styles.json.icloud")
        try Data("stub".utf8).write(to: placeholder)
        let outcome = try FileLibraryFolderStyleStore.update("A", to: FileLibraryFolderLook(color: "rose", mark: .mono), at: url)
        XCTAssertEqual(outcome, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(FileLibraryFolderStyleStore.diskState(at: url), .notDownloaded)
    }

    func testDefaultLooks() {
        XCTAssertEqual(FileLibraryFolderLook.defaultLook(forFolder: "attachments"), FileLibraryFolderLook(color: "sand", mark: .symbol("paperclip")))
        XCTAssertEqual(FileLibraryFolderLook.defaultLook(forFolder: "journal"), FileLibraryFolderLook(color: "rose", mark: .symbol("pencil")))
        XCTAssertEqual(FileLibraryFolderLook.defaultLook(forFolder: "trading").color, "sky")
        XCTAssertEqual(FileLibraryFolderLook.defaultLook(forFolder: StudyTemplate.noteRoot), FileLibraryFolderLook(color: "lilac", mark: .symbol("graduationcap")))
        XCTAssertEqual(FileLibraryFolderLook.defaultLook(forFolder: "memory").color, "cream")
        XCTAssertEqual(FileLibraryFolderLook.defaultLook(forFolder: "artifacts"), FileLibraryFolderLook(color: "cream", mark: .mono))
        XCTAssertEqual(FileLibraryFolderLook.defaultLook(forFolder: "trading/NVDA"), FileLibraryFolderLook(color: "cream", mark: .mono))
        XCTAssertNil(FileLibraryFolderLook.defaultLook(forFolder: "journal").pattern)
    }

    func testMonogram() {
        XCTAssertEqual(FileLibraryFolderLook.monogram("artifacts"), "A")
        XCTAssertEqual(FileLibraryFolderLook.monogram("旅行"), "旅")
        XCTAssertEqual(FileLibraryFolderLook.monogram("  "), "·")
    }

    func testHexParsing() {
        XCTAssertEqual(FileLibraryFolderPalette.hexValue("#B9D3C2"), 0xB9D3C2)
        XCTAssertEqual(FileLibraryFolderPalette.hexValue("#b9d3c2"), 0xB9D3C2)
        XCTAssertNil(FileLibraryFolderPalette.hexValue("B9D3C2"))
        XCTAssertNil(FileLibraryFolderPalette.hexValue("#B9D3C"))
        XCTAssertNil(FileLibraryFolderPalette.hexValue("#B9D3CZ"))
        XCTAssertEqual(FileLibraryFolderPalette.hexString(0x0A0B0C), "#0A0B0C")
        XCTAssertTrue(FileLibraryFolderPalette.isValid("olive"))
        XCTAssertFalse(FileLibraryFolderPalette.isValid("blue"))
    }

    func testLightness() {
        XCTAssertTrue(FileLibraryFolderPalette.isLight(FileLibraryFolderPalette.cream.back))
        for p in FileLibraryFolderPalette.allCases where p != .cream {
            XCTAssertFalse(FileLibraryFolderPalette.isLight(p.back), p.rawValue)
        }
        XCTAssertTrue(FileLibraryFolderPalette.isLight(0xFFFFFF))
        XCTAssertFalse(FileLibraryFolderPalette.isLight(0x000000))
    }

    func testPaint() {
        let rose = FileLibraryFolderPaint(color: "rose")
        XCTAssertEqual(rose.back, 0xECC6CD)
        XCTAssertEqual(rose.front, 0xD99AA5)
        XCTAssertEqual(rose.frontAlpha, 0.40)
        let custom = FileLibraryFolderPaint(color: "#336699")
        XCTAssertEqual(custom.back, 0x336699)
        XCTAssertEqual(custom.front, 0x336699)
        XCTAssertEqual(custom.frontAlpha, 0.42)
        XCTAssertTrue(FileLibraryFolderPaint(color: "ink").tileInkIsWhite)
        XCTAssertFalse(FileLibraryFolderPaint(color: "mint").tileInkIsWhite)
    }
}
