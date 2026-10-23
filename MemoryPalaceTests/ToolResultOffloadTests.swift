import XCTest
@testable import 记忆花园

/// B4 工具结果外置（plan-B4）：pi 档位 2000 行 / 50KB 头截、全文落 tool-results/、fs_read 范围读续读。
/// 唯一 profileId + tearDown 删整个楼层目录——不往真实 ~/Documents 泄目录（H-Q 教训）。
final class ToolResultOffloadTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // #033：本类直接测 store，测试自己站在主线程调——不算生产违规
        MainThreadIO.allowMainThreadInThisTest()
    }
    private let profileId = "test-b4-\(UUID().uuidString.prefix(8))"
    private let conversationId = "conv-\(UUID().uuidString.prefix(8))"

    private var floorDir: URL { FileLibraryStore.libraryRoot(profileId: profileId).deletingLastPathComponent() }

    override func tearDown() {
        try? FileManager.default.removeItem(at: floorDir)
        FileLibraryStore.forgetSlug(profileId: profileId)   // 假楼层映射别留在真实数据里（review-mac-hang-probe）
        super.tearDown()
    }

    private func lines(_ n: Int, _ make: (Int) -> String = { "line \($0)" }) -> String {
        (1...n).map(make).joined(separator: "\n")
    }

    private func apply(_ text: String, tool: String = "mcp_search", id: String = "call-1") -> (text: String, offloaded: Bool) {
        ToolResultOffload.apply(text: text, conversationId: conversationId, toolUseId: id, toolName: tool, profileId: profileId)
    }

    private func archivedFiles() -> [URL] {
        let root = FileLibraryStore.toolResultsRoot(profileId: profileId)
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return en.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// 尾注之前的头部
    private func head(of preview: String) -> String {
        String(preview[..<(preview.range(of: "\n\n[")?.lowerBound ?? preview.endIndex)])
    }

    private func fsRead(_ json: String) -> FileLibraryTools.Result {
        FileLibraryTools.execute(name: "fs_read", inputJSON: json, profileId: profileId)
    }

    // MARK: 1 上限以内

    func testWithinLimitsIsUntouched() {
        let text = lines(2000)
        let r = apply(text)
        XCTAssertFalse(r.offloaded)
        XCTAssertEqual(r.text, text)
        XCTAssertTrue(archivedFiles().isEmpty, "没超限不该落盘")
    }

    // MARK: 2 三种截法

    func testTruncatesByLinesAt2001() {
        let r = apply(lines(2001))
        XCTAssertTrue(r.offloaded)
        XCTAssertTrue(r.text.contains("[已截断：显示第 1–2000 行 / 共 2001 行（2000 行上限）"), r.text.suffix(300).description)
        XCTAssertTrue(r.text.contains("offset: 2001)"))
        XCTAssertEqual(ToolResultOffload.splitLines(head(of: r.text)).count, 2000)
    }

    func testTruncatesByBytesBeforeLineLimit() {
        // 1000 行 × 61 字节 ≈ 61KB：先撞字节上限
        let r = apply(lines(1000) { _ in String(repeating: "x", count: 61) })
        XCTAssertTrue(r.offloaded)
        XCTAssertTrue(r.text.contains("（50KB 上限）"), r.text.suffix(300).description)
        let shown = ToolResultOffload.splitLines(head(of: r.text)).count
        XCTAssertLessThan(shown, 1000)
        XCTAssertLessThanOrEqual(head(of: r.text).utf8.count, ToolResultOffload.maxBytes)
        XCTAssertTrue(r.text.contains("offset: \(shown + 1))"))
    }

    func testSingleGiantLineIsCutAtByteLimit() {
        let r = apply(String(repeating: "j", count: 80 * 1024))
        XCTAssertTrue(r.offloaded)
        XCTAssertTrue(r.text.hasSuffix("]"))
        XCTAssertTrue(r.text.contains("[首行超过 50KB，已切断"), r.text.suffix(300).description)
        XCTAssertEqual(head(of: r.text).utf8.count, ToolResultOffload.maxBytes)
    }

    // MARK: 3/4 全文落盘 + 路径能读回

    func testArchiveHoldsFullTextAndPathReadsBack() throws {
        let text = lines(2500)
        let r = apply(text, tool: "search_docs", id: "toolu_01AB")
        let path = try XCTUnwrap(ToolResultOffload.embeddedPath(in: r.text))
        XCTAssertTrue(path.hasPrefix("tool-results/conv-"))
        XCTAssertTrue(path.hasSuffix("/toolu_01AB-search_docs.txt"))
        XCTAssertEqual(try FileLibraryStore.toolResultRead(path, profileId: profileId), text, "全文一个字不丢")
        XCTAssertEqual(head(of: r.text), lines(2000), "预览 = 前 2000 行原样")

        let cont = fsRead(#"{"path":"\#(path)","offset":2001,"limit":1}"#)
        XCTAssertFalse(cont.isError, cont.text)
        XCTAssertTrue(cont.text.hasPrefix("（第 2001–2001 行 / 共 2500 行）\nline 2001"), cont.text)
    }

    // MARK: 5 fs_read 特例：不复制，指回原文件

    func testFsReadTruncatesItselfAndPointsAtOriginalFile() throws {
        try FileLibraryStore.write("big.txt", content: lines(3000), profileId: profileId)
        let r = fsRead(#"{"path":"big.txt"}"#)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("[已截断：显示第 1–2000 行 / 共 3000 行（2000 行上限）。用 fs_read(path: \"big.txt\", offset: 2001) 续读]"), r.text.suffix(200).description)
        XCTAssertNil(ToolResultOffload.embeddedPath(in: r.text))
        XCTAssertTrue(archivedFiles().isEmpty, "fs_read 不该往 tool-results/ 复制")
        // 收口点也不会再碰它（fs_read 由调用方跳过）：这里只验 apply 对已截断文本的幂等性不在契约内
    }

    // MARK: 6 只读

    func testToolResultsPrefixRejectsWrites() {
        for (name, json) in [
            ("fs_write", #"{"path":"tool-results/c/x.txt","content":"a"}"#),
            ("fs_edit", #"{"path":"tool-results/c/x.txt","old_string":"a","new_string":"b"}"#),
            ("fs_delete", #"{"path":"tool-results/c/x.txt"}"#),
            ("fs_rename", #"{"old_path":"tool-results/c/x.txt","new_path":"y.txt"}"#),
        ] {
            let r = FileLibraryTools.execute(name: name, inputJSON: json, profileId: profileId)
            XCTAssertTrue(r.isError, name)
            XCTAssertTrue(r.text.contains("只读"), name)
        }
    }

    // MARK: 7 每对话 50 上限

    func testPerConversationCapKeepsNewest50() throws {
        for i in 0..<52 {
            _ = try FileLibraryStore.toolResultWrite(conversationId: conversationId, toolUseId: String(format: "t%02d", i),
                                                     toolName: "x", content: "c\(i)", profileId: profileId)
        }
        let names = archivedFiles().map(\.lastPathComponent).sorted()
        XCTAssertEqual(names.count, FileLibraryStore.toolResultsPerConversationCap)
        XCTAssertFalse(names.contains("t00-x.txt"))
        XCTAssertFalse(names.contains("t01-x.txt"))
        XCTAssertTrue(names.contains("t51-x.txt"))
    }

    // MARK: 8 不切半行 / 不切坏多字节

    func testByteTruncationKeepsWholeCJKLines() {
        let src = lines(400) { i in String(repeating: "中", count: 99) + "\(i % 10)" }   // 每行 ≈300 字节
        let r = apply(src)
        XCTAssertTrue(r.offloaded)
        let shown = ToolResultOffload.splitLines(head(of: r.text))
        XCTAssertEqual(Array(ToolResultOffload.splitLines(src).prefix(shown.count)), shown, "每一行都得是原样整行")
        XCTAssertEqual(shown.last?.count, 100, "最后一行没被字节切断")
    }

    // MARK: 9 范围读

    func testRangeReadSemantics() throws {
        try FileLibraryStore.write("r.txt", content: lines(10), profileId: profileId)
        XCTAssertEqual(fsRead(#"{"path":"r.txt"}"#).text, lines(10), "不带范围 = 老行为，无表头")
        XCTAssertTrue(fsRead(#"{"path":"r.txt","offset":9,"limit":5}"#).text.hasPrefix("（第 9–10 行 / 共 10 行）\nline 9\nline 10"))
        let over = fsRead(#"{"path":"r.txt","offset":11}"#)
        XCTAssertTrue(over.isError)
        XCTAssertTrue(over.text.contains("超出文件末尾（共 10 行）"))

        let memURL = FileLibraryStore.memoryRoot(profileId: profileId).appendingPathComponent("notes.md")
        try lines(5).write(to: memURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(fsRead(#"{"path":"memory/notes.md","offset":2,"limit":2}"#).text.hasPrefix("（第 2–3 行 / 共 5 行）\nline 2\nline 3"))
    }

    func testEmbeddedPathExtraction() {
        XCTAssertNil(ToolResultOffload.embeddedPath(in: nil))
        XCTAssertNil(ToolResultOffload.embeddedPath(in: "没有路径"))
        XCTAssertEqual(ToolResultOffload.embeddedPath(in: "…已保存到 tool-results/conv-1/call_9-mcp.txt，用 fs_read…"), "tool-results/conv-1/call_9-mcp.txt")
    }
}
