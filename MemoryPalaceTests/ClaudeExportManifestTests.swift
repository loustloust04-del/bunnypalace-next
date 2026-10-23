import XCTest
@testable import 记忆花园

/// #059：Claude 导出下载清单。全是合成清单，链接是编的（不碰真账号）
final class ClaudeExportManifestTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    private let created = "2026-10-08T23:11:22.168482+00:00"
    private var createdDate: Date { GeminiImportSupport.parseISO(created)! }

    private func manifest(_ files: [[String: Any]], created: String? = "2026-10-08T23:11:22.168482+00:00") throws -> Data {
        var root: [String: Any] = ["instructions": "编的", "total_files": files.count, "version": "1.0", "data_files": files]
        if let created { root["created_at"] = created }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func file(_ category: String, url: String? = nil, name: String? = nil) -> [String: Any] {
        ["batch_index": 0, "category": category, "part": 0, "filename": name ?? "\(category)-000.zip",
         "export_url": url ?? "https://claude.ai/export/00000000-0000-4000-8000-000000000000/download/TESTTOKEN-\(category)"]
    }

    private let sevenCategories = ["light_metadata", "projects", "memories", "feedback", "design_chats", "frames", "conversations"]

    func testParsesSevenPackages() throws {
        let m = try XCTUnwrap(ClaudeExportManifest.parse(data: manifest(sevenCategories.map { file($0) })))
        XCTAssertEqual(m.packages.map(\.filename), sevenCategories.map { "\($0)-000.zip" })
        XCTAssertEqual(m.createdAt, createdDate)
        XCTAssertEqual(m.packages.filter(\.isNeeded).map(\.category), ["projects", "memories", "design_chats", "frames", "conversations"])
        XCTAssertEqual(m.packages.map(\.categoryName), ["账号信息", "项目", "记忆", "反馈", "设计对话", "Artifacts", "对话"])
    }

    func testOldAccountLinkShape() throws {
        let m = try XCTUnwrap(ClaudeExportManifest.parse(data: manifest([
            file("conversations", url: "https://claude.ai/export/account/download/TESTTOKEN-old"),
        ])))
        XCTAssertEqual(m.packages.count, 1)
    }

    func testRejectsForeignLinksAndNames() throws {
        let m = try XCTUnwrap(ClaudeExportManifest.parse(data: manifest([
            file("conversations"),
            file("projects", url: "https://example.invalid/export/x"),
            file("memories", url: "http://claude.ai/export/x/download/y"),
            file("frames", url: "https://claude.ai/export/../api/x"),
            file("design_chats", url: "https://claude.ai.evil.example/export/x"),
            file("feedback", name: "../feedback-000.zip"),
            file("light_metadata", name: "users.json"),
            file("conversations"),
        ])))
        XCTAssertEqual(m.packages.map(\.filename), ["conversations-000.zip"], "别处的链接、怪文件名、重复的都不收")
        XCTAssertNil(ClaudeExportManifest.parse(data: try manifest([file("x", url: "https://example.invalid/a")])))
        XCTAssertNil(ClaudeExportManifest.parse(data: Data(#"{"logical_files":{"conversations.json":{"files":[]}}}"#.utf8)),
                     "ChatGPT 的 export_manifest 不是")
        XCTAssertNil(ClaudeExportManifest.parse(data: Data(#"{"format":"kelivo-backup","formatVersion":3}"#.utf8)))
        XCTAssertNil(ClaudeExportManifest.parse(data: Data("不是 json".utf8)))
    }

    func testExpiryBoundaries() throws {
        let m = try XCTUnwrap(ClaudeExportManifest.parse(data: manifest([file("conversations")])))
        let start = createdDate
        XCTAssertFalse(m.isExpired(now: start.addingTimeInterval(23 * 3600 + 59 * 60)))
        XCTAssertEqual(m.hoursLeft(now: start.addingTimeInterval(23 * 3600 + 59 * 60)), 0)
        XCTAssertEqual(m.hoursLeft(now: start.addingTimeInterval(3600)), 23)
        XCTAssertTrue(m.isExpired(now: start.addingTimeInterval(24 * 3600)))
        XCTAssertEqual(m.hoursLeft(now: start.addingTimeInterval(30 * 3600)), 0)

        let undated = try XCTUnwrap(ClaudeExportManifest.parse(data: manifest([file("conversations")], created: nil)))
        XCTAssertFalse(undated.isExpired(now: .distantFuture), "没写导出时间：不知道，不拦")
        XCTAssertNil(undated.hoursLeft())
    }

    /// 链接是短期凭证：打印、插值、调试描述里都不能带令牌
    func testDescriptionsHideLinks() throws {
        let m = try XCTUnwrap(ClaudeExportManifest.parse(data: manifest(sevenCategories.map { file($0) })))
        for text in [String(describing: m), String(reflecting: m), "\(m.packages)", String(reflecting: m.packages[0])] {
            XCTAssertFalse(text.contains("TESTTOKEN"), text)
            XCTAssertFalse(text.contains("claude.ai/export"), text)
        }
    }

    /// 只选了清单：扫描仍是空（没有可导的内容），但带出清单，导入页据此进下载页
    func testScanOfManifestAloneCarriesIt() throws {
        let url = work.appendingPathComponent("manifest-00000000-0000-4000-8000-000000000000-1791500973-8e11ac32-2026-10-08-23-11-22.json")
        try manifest(sevenCategories.map { file($0) }).write(to: url)
        let s = try ExportPackageScanner.scan([url], tempRoot: work)
        defer { s.cleanup() }
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.claudeManifest?.packages.count, 7)
        XCTAssertEqual(Set(s.missingFromManifest),
                       ["projects-000.zip", "memories-000.zip", "design_chats-000.zip", "frames-000.zip", "conversations-000.zip"])
        XCTAssertTrue(s.unrecognized.isEmpty, "\(s.unrecognized)")
    }

    // MARK: - 导入页会话

    @MainActor
    private func opened(_ urls: [URL]) async throws -> ImportSession {
        let session = ImportSession()
        session.open(urls)
        let deadline = Date().addingTimeInterval(10)
        while session.phase == .scanning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return session
    }

    /// 只选清单：进下载页，不报「没找到」；返回 = 回到选包、清单丢掉
    @MainActor
    func testSessionManifestAloneGoesToDownload() async throws {
        let url = work.appendingPathComponent("manifest-test.json")
        try manifest(sevenCategories.map { file($0) }).write(to: url)
        let session = try await opened([url])
        XCTAssertEqual(session.phase, .download)
        XCTAssertEqual(session.claudeManifest?.packages.count, 7)
        XCTAssertNil(session.scan)
        session.leaveDownload()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.claudeManifest, "离开下载页，链接不留")
    }

    /// 清单 + 部分包：照常预览，能进下载页再回来
    @MainActor
    func testSessionPreviewCanVisitDownload() async throws {
        let dir = work.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest(sevenCategories.map { file($0) }).write(to: dir.appendingPathComponent("manifest-test.json"))
        try Data(#"[{"uuid":"c1","name":"t","updated_at":"2026-10-08T00:00:00Z","chat_messages":[]}]"#.utf8)
            .write(to: dir.appendingPathComponent("conversations.json"))
        let session = try await opened([dir])
        XCTAssertEqual(session.phase, .preview)
        XCTAssertNotNil(session.claudeManifest)
        session.showDownload()
        XCTAssertEqual(session.phase, .download)
        session.leaveDownload()
        XCTAssertEqual(session.phase, .preview)
        session.reset()
        XCTAssertNil(session.claudeManifest)
    }

    // MARK: - ② 花园里下载（纯逻辑；真下载要真账号，不自动测）

    private func response(_ status: Int, mime: String = "application/zip", length: Int64? = nil) -> URLResponse {
        var headers = ["Content-Type": mime]
        if let length { headers["Content-Length"] = "\(length)" }
        return HTTPURLResponse(url: URL(string: "https://claude.ai/export/x/download/TESTTOKEN")!, statusCode: status,
                               httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func testDownloadResponseClassification() {
        XCTAssertNil(ClaudeExportDownload.classify(response(200)))
        XCTAssertNil(ClaudeExportDownload.classify(response(200, length: 1 << 20)))
        XCTAssertEqual(ClaudeExportDownload.classify(response(401)), .notLoggedIn)
        XCTAssertEqual(ClaudeExportDownload.classify(response(403)), .notLoggedIn)
        XCTAssertEqual(ClaudeExportDownload.classify(response(200, mime: "text/html; charset=utf-8")), .notLoggedIn,
                       "拿回来是网页 = 被带去登录页了")
        XCTAssertEqual(ClaudeExportDownload.classify(response(404)), .linkUsed)
        XCTAssertEqual(ClaudeExportDownload.classify(response(410)), .linkUsed)
        XCTAssertEqual(ClaudeExportDownload.classify(response(500)), .server(500))
        XCTAssertEqual(ClaudeExportDownload.classify(response(200, length: ClaudeExportDownload.maxBytes + 1)), .tooLarge)
    }

    func testDownloadRedirectPolicy() {
        XCTAssertNil(ClaudeExportDownload.redirectFailure(to: URL(string: "https://storage.example.invalid/signed/x.zip")),
                     "导出包可能跳去存储服务")
        XCTAssertEqual(ClaudeExportDownload.redirectFailure(to: URL(string: "https://claude.ai/login?returnTo=/export")), .notLoggedIn)
        XCTAssertEqual(ClaudeExportDownload.redirectFailure(to: URL(string: "http://claude.ai/export/x")), .refused)
        XCTAssertEqual(ClaudeExportDownload.redirectFailure(to: nil), .refused)
    }

    func testDownloadDestinationUsesManifestName() throws {
        let m = try XCTUnwrap(ClaudeExportManifest.parse(data: manifest([file("conversations")])))
        let dest = try XCTUnwrap(ClaudeExportDownload.destination(for: m.packages[0], in: work))
        XCTAssertEqual(dest, work.appendingPathComponent("conversations-000.zip"))
        for failure: ClaudeExportDownload.Failure in [.notLoggedIn, .linkUsed, .server(502), .tooLarge, .empty, .refused, .expired,
                                                      .network(NSURLErrorTimedOut), .network(-9999)] {
            XCTAssertFalse(failure.message.contains("claude.ai/export"), failure.message)
        }
        // 系统错误原文带着链接也不进状态：只留错误码
        let leaky = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [
            NSLocalizedDescriptionKey: "lost https://claude.ai/export/x/download/TESTTOKEN",
            NSURLErrorFailingURLStringErrorKey: "https://claude.ai/export/x/download/TESTTOKEN"])
        let failure = ClaudeExportDownload.failure(for: leaky)
        XCTAssertEqual(failure, .network(NSURLErrorNetworkConnectionLost))
        for text in [failure.message, String(describing: failure), String(reflecting: failure)] {
            XCTAssertFalse(text.contains("TESTTOKEN"), text)
        }
    }

    /// ②下完：扫下好的目录进预览，没下下来的记着；换包时目录删掉
    @MainActor
    func testSessionOpensDownloadedDirectory() async throws {
        let dir = work.appendingPathComponent("\(ExportPackageScanner.stagingPrefix)claude-test", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"[{"uuid":"c1","name":"t","updated_at":"2026-10-08T00:00:00Z","chat_messages":[]}]"#.utf8)
            .write(to: dir.appendingPathComponent("conversations.json"))
        let session = ImportSession()
        session.openDownloaded(dir, files: [dir.appendingPathComponent("conversations.json")], missing: ["projects-000.zip"])
        try await settle(session)
        XCTAssertEqual(session.phase, .preview)
        XCTAssertEqual(session.downloadMissing, ["projects-000.zip"])
        session.reset()
        XCTAssertTrue(session.downloadMissing.isEmpty)
        try await waitGone(dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "下载目录跟着会话删")
    }

    /// 从预览「去下载」：下好的包和原来选的一起重新扫，原来的对话不丢；下载器只下没选到的
    @MainActor
    func testDownloadFromPreviewMergesWithEarlierPick() async throws {
        let picked = work.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        try manifest(["conversations", "projects"].map { file($0) }).write(to: picked.appendingPathComponent("manifest-test.json"))
        try Data(#"[{"uuid":"c1","name":"t","updated_at":"2026-10-08T00:00:00Z","chat_messages":[]}]"#.utf8)
            .write(to: picked.appendingPathComponent("conversations.json"))
        let session = try await opened([picked])
        XCTAssertEqual(session.phase, .preview)
        XCTAssertEqual(session.scan?.claudeConversationCount, 1)
        session.showDownload()

        let dir = work.appendingPathComponent("\(ExportPackageScanner.stagingPrefix)claude-merge", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("projects-000.zip")
        try GPT.zip(["conversations.json": Data(#"[{"uuid":"c2","name":"u","updated_at":"2026-10-08T00:00:00Z","chat_messages":[]}]"#.utf8)],
                    to: zip)
        session.openDownloaded(dir, files: [zip], missing: [])
        try await settle(session)
        XCTAssertEqual(session.phase, .preview)
        XCTAssertEqual(session.scan?.claudeConversationCount, 2, "原来选的 c1 + 下好的 c2")
        XCTAssertFalse(session.scan?.missingFromManifest.contains("projects-000.zip") ?? true, "下好的包不再算缺")

        // 第二轮：上一轮下好的目录不能在重新扫之前被删
        let dir2 = work.appendingPathComponent("\(ExportPackageScanner.stagingPrefix)claude-merge2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        session.openDownloaded(dir2, files: [], missing: ["x-000.zip"])
        try await settle(session)
        XCTAssertEqual(session.scan?.claudeConversationCount, 2)
        session.reset()
        try await waitGone(dir)
        try await waitGone(dir2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir2.path))
    }

    @MainActor
    private func settle(_ session: ImportSession) async throws {
        let deadline = Date().addingTimeInterval(10)
        while session.phase == .scanning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func waitGone(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: url.path), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
}
