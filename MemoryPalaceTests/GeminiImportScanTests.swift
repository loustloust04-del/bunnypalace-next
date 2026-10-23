import XCTest
import ZIPFoundation
@testable import 记忆花园

/// #047：扫描器认 Gemini Takeout / AI Studio + 预览计数。全部合成样本（结构依据 docs/research-import-gemini.md §1），不是真包。
final class GeminiImportScanTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gemini-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    // MARK: - 样本

    static func activity(_ prompt: String, time: String, answer: String, chat: String? = nil, header: String = "Gemini Apps") -> [String: Any] {
        var r: [String: Any] = ["header": header, "products": [header], "title": "Prompted \(prompt)", "time": time,
                                "safeHtmlItem": [["html": "<p>\(answer)</p>"]]]
        if let chat { r["details"] = [["name": "Conversation", "url": "https://gemini.google.com/app/\(chat)"]] }
        return r
    }

    static func takeoutJSON(_ records: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: records)
    }

    static let geminiRecords: [[String: Any]] = [
        activity("第一句", time: "2026-01-01T10:00:00Z", answer: "一", chat: "c1"),
        activity("第二句", time: "2026-01-01T10:05:00Z", answer: "二", chat: "c1"),
        activity("没链接", time: "2026-01-03T09:00:00Z", answer: "三"),
    ]

    static func aiStudioFile(_ opening: String = "你好", reply: String = "你好呀") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "runSettings": ["model": "models/gemini-2.5-pro"],
            "systemInstruction": ["text": "你是助手"],
            "chunkedPrompt": ["chunks": [
                ["role": "user", "text": opening, "createTime": "2025-06-15T10:30:00Z"],
                ["role": "model", "text": reply, "createTime": "2025-06-15T10:30:05Z"],
            ]],
        ])
    }

    private func write(_ data: Data, _ rel: String, in root: URL) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// 一个 Takeout 目录：Gemini 活动 + 搜索活动 + Drive 里两个 AI Studio 文件（无扩展名）+ 一个无扩展名杂项
    private func takeoutDir() throws -> URL {
        let root = work.appendingPathComponent("takeout-src")
        try write(try Self.takeoutJSON(Self.geminiRecords), "Takeout/My Activity/Gemini Apps/MyActivity.json", in: root)
        try write(try Self.takeoutJSON([Self.activity("x", time: "2026-01-01T10:00:00Z", answer: "y", header: "Search")]),
                  "Takeout/My Activity/Search/MyActivity.json", in: root)
        try write(try Self.aiStudioFile(), "Takeout/Drive/Google AI Studio/Trip plan", in: root)
        try write(try Self.aiStudioFile("另一段"), "Takeout/Drive/Google AI Studio/Notes v1.5", in: root)
        try write(try Self.aiStudioFile("第三段"), "Takeout/Drive/Google AI Studio/Draft.json", in: root)
        try write(Data("随便什么".utf8), "Takeout/Drive/README", in: root)
        return root
    }

    private func scan(_ urls: [URL]) throws -> ExportPackageScan {
        try ExportPackageScanner.scan(urls, tempRoot: work)
    }

    // MARK: - 用例

    func testClassify() {
        XCTAssertEqual(ExportPackageScanner.classify("Takeout/我的活动/Gemini Apps/MyActivity.json"), .geminiActivity, "文件夹名随语言变，只认文件名")
        XCTAssertEqual(ExportPackageScanner.classify("Takeout/My Activity/Gemini Apps/MyActivity.html"), .geminiActivity)
        XCTAssertEqual(ExportPackageScanner.classify("Takeout/Drive/Google AI Studio/Trip plan"), .candidate)
        XCTAssertNil(ExportPackageScanner.classify("Takeout/archive_browser.html"))
        XCTAssertEqual(ExportPackageScanner.classify("Takeout/Drive/Google AI Studio/Notes v1.5"), .candidate)
        XCTAssertEqual(ExportPackageScanner.classify("Takeout/Drive/Google AI Studio/Notes.json"), .candidate)
        XCTAssertEqual(ExportPackageScanner.classify("下载/Plan v2.0 draft"), .candidate)
        XCTAssertNil(ExportPackageScanner.classify("Takeout/Gemini/song.mp3"), "媒体文件不拷进来试认")
        XCTAssertEqual(ExportPackageScanner.classify("chatgpt/file-abc.mp3"), .asset, "ChatGPT 附件按 #050 建索引，不当候选试认")
    }

    func testTakeoutZip() throws {
        let zip = work.appendingPathComponent("takeout-20260101T000000Z-001.zip")
        try ExportPackageScannerTests.zip(try takeoutDir(), to: zip)
        let s = try scan([zip])
        XCTAssertEqual(s.geminiActivityFiles.map(\.lastPathComponent), ["MyActivity.json"])
        XCTAssertTrue(s.geminiActivityFiles[0].path.contains("Gemini Apps"))
        XCTAssertEqual(Set(s.aiStudioFiles.map(\.lastPathComponent)), ["Trip plan", "Notes v1.5", "Draft.json"])
        XCTAssertEqual(s.ignoredLabels, ["其他 Google 产品的活动记录"])
        XCTAssertTrue(s.unrecognized.isEmpty, "无扩展名的杂项认不出就算了，不提示")
        XCTAssertTrue(s.claudeFiles.isEmpty && s.chatGPTFiles.isEmpty, "Takeout 数组不能被当成 Claude / ChatGPT")
        XCTAssertFalse(s.isEmpty)
    }

    func testTakeoutFolder() throws {
        let s = try scan([try takeoutDir()])
        XCTAssertEqual(s.geminiActivityFiles.count, 1)
        XCTAssertEqual(s.aiStudioFiles.count, 3)
    }

    func testDirectPickedFiles() throws {
        let json = work.appendingPathComponent("活动.json")
        try Self.takeoutJSON(Self.geminiRecords).write(to: json)
        let html = work.appendingPathComponent("MyActivity.html")
        try Data(#"<html><body><div class="outer-cell"><p>Gemini Apps</p></div></body></html>"#.utf8).write(to: html)
        let aiStudio = work.appendingPathComponent("Trip plan")
        try Self.aiStudioFile().write(to: aiStudio)
        let s = try scan([json, html, aiStudio])
        XCTAssertEqual(s.geminiActivityFiles.map(\.lastPathComponent).sorted(), ["MyActivity.html", "活动.json"])
        XCTAssertEqual(s.aiStudioFiles.map(\.lastPathComponent), ["Trip plan"])
        XCTAssertTrue(s.unrecognized.isEmpty)
    }

    func testNonGeminiActivityOnlyIsEmpty() throws {
        let root = work.appendingPathComponent("search-only")
        try write(try Self.takeoutJSON([Self.activity("x", time: "2026-01-01T10:00:00Z", answer: "y", header: "Search")]),
                  "Takeout/My Activity/Search/MyActivity.json", in: root)
        try write(Data(#"<html><div class="outer-cell">YouTube</div></html>"#.utf8), "Takeout/My Activity/YouTube/MyActivity.html", in: root)
        let s = try scan([root])
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.ignoredLabels, ["其他 Google 产品的活动记录"])
    }

    func testPreviewCounts() throws {
        let s = try scan([try takeoutDir()])
        defer { s.cleanup() }
        let p = ImportPreview.make(s)
        XCTAssertEqual(p.gemini.activityCount, 3)
        XCTAssertEqual(p.gemini.conversationCount, 2)
        XCTAssertEqual(p.gemini.explicitConversationCount, 1)
        XCTAssertEqual(p.gemini.inferredConversationCount, 1)
        XCTAssertEqual(p.aiStudio.conversationCount, 3)
        XCTAssertTrue(p.notes.isEmpty)
    }
}
