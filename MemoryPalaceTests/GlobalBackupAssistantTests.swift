import XCTest
@testable import 记忆花园

/// 全局备份带上小芽对话 + 账本（plan-onboarding-xiaoya-impl P1b）。全部用临时目录，不碰真实 AssistantChat/ 和 staging。
final class GlobalBackupAssistantTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("gb-assistant-\(UUID().uuidString)", isDirectory: true)
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

    private func put(_ text: String, _ name: String, in d: URL) throws {
        try Data(text.utf8).write(to: d.appendingPathComponent(name))
    }

    private func read(_ name: String, in d: URL) -> String? {
        (try? Data(contentsOf: d.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func names(_ d: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).sorted()
    }

    // MARK: 导出

    func testExportCarriesJSONFilesSkipsCorruptAndHashes() throws {
        let src = try dir("AssistantChat")
        try put("[1]", "history.json", in: src)
        try put("[2]", "ledger.json", in: src)
        try put("[3]", "script.json", in: src)
        try put("broken", "history.corrupt-1700000000.json", in: src)
        try put("x", "notes.txt", in: src)
        let workspace = try dir("workspace")

        let sec = try XCTUnwrap(GlobalExporter.exportAssistantChat(from: src, to: workspace))
        let out = workspace.appendingPathComponent("assistant", isDirectory: true)
        XCTAssertEqual(sec.path, "assistant")
        XCTAssertEqual(names(out), ["history.json", "ledger.json", "script.json"], "按目录带 *.json，留底的 corrupt 不带")
        let (sha, bytes) = try SectionHasher.hash(directory: out)
        XCTAssertEqual(sec.sha256, sha)
        XCTAssertEqual(sec.bytes, bytes)
        XCTAssertEqual(bytes, 9)
        XCTAssertEqual(names(src).count, 5, "导出不动源目录")
    }

    func testExportWithoutFilesHasNoSection() throws {
        let workspace = try dir("workspace")
        XCTAssertNil(try GlobalExporter.exportAssistantChat(from: root.appendingPathComponent("missing"), to: workspace))
        let empty = try dir("AssistantChat")
        try put("broken", "ledger.corrupt-1.json", in: empty)
        XCTAssertNil(try GlobalExporter.exportAssistantChat(from: empty, to: workspace))
        XCTAssertFalse(fm.fileExists(atPath: workspace.appendingPathComponent("assistant").path))
    }

    // MARK: 导入 → staging → 启动期 apply

    func testRestoreReplacesLocalAndArchivesOld() throws {
        // 包
        let workspace = try dir("workspace")
        let pkg = try dir("workspace/assistant")
        try put("[\"新\"]", "history.json", in: pkg)
        try put("[\"新账\"]", "ledger.json", in: pkg)
        // 本机
        let primary = try dir("AssistantChat")
        try put("[\"旧\"]", "history.json", in: primary)
        try put("broken", "history.corrupt-9.json", in: primary)
        let staging = root.appendingPathComponent("assistant-staging", isDirectory: true)
        let archive = root.appendingPathComponent("archive/assistant", isDirectory: true)
        try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)

        try GlobalImporter.stageAssistantChat(workspace: workspace, to: staging)
        XCTAssertEqual(names(staging), ["history.json", "ledger.json"])
        XCTAssertEqual(read("history.json", in: primary), "[\"旧\"]", "staging 阶段主位不动")

        try PendingImportApplier.archiveAssistantIfIncoming(staging: staging, primary: primary, archive: archive)
        try PendingImportApplier.installAssistant(staging: staging, primary: primary)

        XCTAssertEqual(read("history.json", in: primary), "[\"新\"]")
        XCTAssertEqual(read("ledger.json", in: primary), "[\"新账\"]")
        XCTAssertEqual(read("history.json", in: archive), "[\"旧\"]", "旧的进 pre-import-archive，放弃恢复时搬回")
        XCTAssertEqual(names(archive), ["history.corrupt-9.json", "history.json"])
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
    }

    /// 粟粟拍板 7：旧备份包没有小芽这段 → 本机现有对话不动
    func testPackageWithoutSectionLeavesLocalUntouched() throws {
        let workspace = try dir("workspace")
        let primary = try dir("AssistantChat")
        try put("[\"本机\"]", "history.json", in: primary)
        try put("[\"本机账\"]", "ledger.json", in: primary)
        let staging = root.appendingPathComponent("assistant-staging", isDirectory: true)
        let archive = root.appendingPathComponent("archive/assistant", isDirectory: true)

        try GlobalImporter.stageAssistantChat(workspace: workspace, to: staging)
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
        try PendingImportApplier.archiveAssistantIfIncoming(staging: staging, primary: primary, archive: archive)
        try PendingImportApplier.installAssistant(staging: staging, primary: primary)

        XCTAssertEqual(names(primary), ["history.json", "ledger.json"])
        XCTAssertEqual(read("history.json", in: primary), "[\"本机\"]")
        XCTAssertFalse(fm.fileExists(atPath: archive.path))
    }

    /// 本机从没开过小芽（主位不存在）：照样装进来
    func testRestoreOntoEmptyDevice() throws {
        let workspace = try dir("workspace")
        try put("[\"新\"]", "history.json", in: try dir("workspace/assistant"))
        let primary = root.appendingPathComponent("AssistantChat", isDirectory: true)
        let staging = root.appendingPathComponent("assistant-staging", isDirectory: true)
        let archive = root.appendingPathComponent("archive/assistant", isDirectory: true)

        try GlobalImporter.stageAssistantChat(workspace: workspace, to: staging)
        try PendingImportApplier.archiveAssistantIfIncoming(staging: staging, primary: primary, archive: archive)
        try PendingImportApplier.installAssistant(staging: staging, primary: primary)
        XCTAssertEqual(read("history.json", in: primary), "[\"新\"]")
        XCTAssertFalse(fm.fileExists(atPath: archive.path))
    }

    func testStagingPathsSitNextToRealStores() {
        XCTAssertEqual(StagingPaths.primaryAssistantRoot.standardizedFileURL.path,
                       AssistantChatStore.defaultURL.deletingLastPathComponent().standardizedFileURL.path)
        XCTAssertEqual(StagingPaths.primaryAssistantRoot.standardizedFileURL.path,
                       AssistantLedger.defaultURL.deletingLastPathComponent().standardizedFileURL.path)
        XCTAssertEqual(StagingPaths.stagingAssistantRoot.deletingLastPathComponent().standardizedFileURL.path,
                       StagingPaths.applicationSupportRoot.standardizedFileURL.path)
    }
}
