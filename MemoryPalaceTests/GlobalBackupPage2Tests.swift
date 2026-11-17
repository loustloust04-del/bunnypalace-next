import XCTest
@testable import 记忆花园

/// 全局备份带上 page2 主屏（布局 + 外观）和网页应用（plan-garden-webapps T11）。全部用临时目录，不碰真实 Page2/ WebApps/ 和 staging。
final class GlobalBackupPage2Tests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("gb-page2-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func dir(_ name: String) throws -> URL {
        let u = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func put(_ text: String, _ path: String, in d: URL) throws {
        let url = d.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in d: URL) -> String? {
        (try? Data(contentsOf: d.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testExportCopiesWholeDirectoryWithSubfoldersAndHashes() throws {
        let src = try dir("Page2")
        try put("{\"a\":1}", "home-layout-v1.json", in: src)
        try put("{\"b\":2}", "floors/p1/home-layout-v1.json", in: src)
        try put("png", "Appearance/icon-1.png", in: src)
        let workspace = try dir("workspace")

        let sec = try XCTUnwrap(GlobalExporter.exportDirectory(src, as: "page2", to: workspace))
        let out = workspace.appendingPathComponent("page2", isDirectory: true)
        XCTAssertEqual(sec.path, "page2")
        XCTAssertEqual(read("floors/p1/home-layout-v1.json", in: out), "{\"b\":2}")
        XCTAssertEqual(read("Appearance/icon-1.png", in: out), "png")
        let (sha, bytes) = try SectionHasher.hash(directory: out)
        XCTAssertEqual(sec.sha256, sha)
        XCTAssertEqual(sec.bytes, bytes)
        XCTAssertNotNil(read("home-layout-v1.json", in: src), "导出不动源目录")
    }

    func testExportMissingOrEmptyHasNoSection() throws {
        let workspace = try dir("workspace")
        XCTAssertNil(try GlobalExporter.exportDirectory(root.appendingPathComponent("missing"), as: "webapps", to: workspace))
        XCTAssertNil(try GlobalExporter.exportDirectory(try dir("WebApps"), as: "webapps", to: workspace))
        XCTAssertFalse(fm.fileExists(atPath: workspace.appendingPathComponent("webapps").path))
    }

    func testRestoreReplacesLocalAndArchivesOld() throws {
        let workspace = try dir("workspace")
        try put("[\"新\"]", "webapps/webapps.json", in: workspace)
        let primary = try dir("WebApps")
        try put("[\"旧\"]", "webapps.json", in: primary)
        let staging = root.appendingPathComponent("webapps-staging", isDirectory: true)
        let archive = root.appendingPathComponent("archive/webapps", isDirectory: true)
        try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)

        try GlobalImporter.stageDirectory(workspace: workspace, name: "webapps", to: staging)
        try PendingImportApplier.archiveIfIncoming(staging: staging, primary: primary, archive: archive)
        XCTAssertEqual(read("webapps.json", in: archive), "[\"旧\"]")
        XCTAssertFalse(fm.fileExists(atPath: primary.path))
        try fm.moveItem(at: staging, to: primary)
        XCTAssertEqual(read("webapps.json", in: primary), "[\"新\"]")
    }

    func testOldPackageWithoutSectionKeepsLocal() throws {
        let workspace = try dir("workspace")
        let primary = try dir("Page2")
        try put("{\"本机\":1}", "home-layout-v1.json", in: primary)
        let staging = root.appendingPathComponent("page2-staging", isDirectory: true)
        let archive = root.appendingPathComponent("archive/page2", isDirectory: true)

        try GlobalImporter.stageDirectory(workspace: workspace, name: "page2", to: staging)
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
        try PendingImportApplier.archiveIfIncoming(staging: staging, primary: primary, archive: archive)
        XCTAssertEqual(read("home-layout-v1.json", in: primary), "{\"本机\":1}", "旧包没有这段：本机主屏不动")
        XCTAssertFalse(fm.fileExists(atPath: archive.path))
    }
}
