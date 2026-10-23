import XCTest
@testable import 记忆花园

/// 记忆树（SummaryFileStore + FileLibraryStore.memory* + fs 工具只读）特征测试。
/// 对应 review-memory-tree-v1 手测清单中可自动化的部分。
/// 用固定测试楼层 id，tearDown 删整个楼层目录（slugMap 残留一条无害）。
final class MemoryTreeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // #033：本类直接测 store，测试自己站在主线程调——不算生产违规
        MainThreadIO.allowMainThreadInThisTest()
    }

    let pid = "xctest-memory-tree"
    let convId = "AABBCCDD-1111-2222-3333-444455556666"

    override func tearDown() {
        let floorDir = FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: floorDir)
        super.tearDown()
    }

    private func makeSummary(_ text: String = "她喜欢薄荷绿。", covered: Int = 12) -> ContextSummary {
        ContextSummary(summary: text, coveredCount: covered, updatedAt: Date())
    }

    private func summaryFileURLs() -> [URL] {
        let dir = FileLibraryStore.memoryRoot(profileId: pid).appendingPathComponent("summaries", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.map { dir.appendingPathComponent($0) }
    }

    // MARK: - SummaryFileStore

    func testSaveLoadRoundtrip() {
        let s = makeSummary()
        SummaryFileStore.save(s, conversationId: convId, profileId: pid, conversationTitle: "测试对话")
        let loaded = SummaryFileStore.load(conversationId: convId, profileId: pid)
        XCTAssertEqual(loaded?.summary, s.summary)
        XCTAssertEqual(loaded?.coveredCount, s.coveredCount)
        XCTAssertEqual(loaded.map { Int($0.updatedAt.timeIntervalSince1970) },
                       Int(s.updatedAt.timeIntervalSince1970), "时间秒级精度往返")
    }

    func testFilenameUsesPrefix8AndTitleSlug() {
        SummaryFileStore.save(makeSummary(), conversationId: convId, profileId: pid, conversationTitle: "测试对话")
        let names = summaryFileURLs().map(\.lastPathComponent)
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasPrefix("AABBCCDD-"), "convId 前 8 是稳定锚，实际: \(names[0])")
        XCTAssertTrue(names[0].contains("测试对话"))
    }

    func testRenameFollowsTitleChange() {
        SummaryFileStore.save(makeSummary(), conversationId: convId, profileId: pid, conversationTitle: "旧标题")
        SummaryFileStore.save(makeSummary("更新后的摘要"), conversationId: convId, profileId: pid, conversationTitle: "新标题")
        let names = summaryFileURLs().map(\.lastPathComponent)
        XCTAssertEqual(names.count, 1, "改标题后不应出现两个文件")
        XCTAssertTrue(names[0].contains("新标题"))
        XCTAssertEqual(SummaryFileStore.load(conversationId: convId, profileId: pid)?.summary, "更新后的摘要")
    }

    func testSlugSanitizesDangerousCharsAndTruncates() {
        SummaryFileStore.save(makeSummary(), conversationId: convId, profileId: pid,
                              conversationTitle: "a/b:c*?\"<>|#\n一二三四五六七八九十一二三四五六七八九十一二三四五")
        let name = summaryFileURLs().map(\.lastPathComponent).first ?? ""
        XCTAssertFalse(name.dropFirst(9).contains("/"), "危险字符应被清洗: \(name)")
        for ch in ":*?\"<>|#" { XCTAssertFalse(name.contains(ch), "残留危险字符 \(ch): \(name)") }
        XCTAssertLessThan(name.count, 9 + 24 + 4, "标题应截到 24 字内: \(name)")
    }

    func testEmptyTitleFallsBackToUntitled() {
        SummaryFileStore.save(makeSummary(), conversationId: convId, profileId: pid, conversationTitle: "  ")
        let name = summaryFileURLs().map(\.lastPathComponent).first ?? ""
        XCTAssertTrue(name.contains("untitled"), "空标题应回退 untitled: \(name)")
    }

    func testBodyContainingDashLinesSurvives() {
        let body = "前段\n---\n后段（正文里的分隔线不该破坏 frontmatter 解析）"
        SummaryFileStore.save(makeSummary(body), conversationId: convId, profileId: pid, conversationTitle: "t")
        XCTAssertEqual(SummaryFileStore.load(conversationId: convId, profileId: pid)?.summary, body)
    }

    func testCorruptFrontmatterLoadsNilAndSelfHeals() throws {
        SummaryFileStore.save(makeSummary(), conversationId: convId, profileId: pid, conversationTitle: "t")
        let url = try XCTUnwrap(summaryFileURLs().first)
        try Data("不是 frontmatter 的垃圾内容".utf8).write(to: url)
        XCTAssertNil(SummaryFileStore.load(conversationId: convId, profileId: pid), "坏文件应视为无摘要（自愈：下次重压）")
    }

    func testClearRemovesFile() {
        SummaryFileStore.save(makeSummary(), conversationId: convId, profileId: pid, conversationTitle: "t")
        SummaryFileStore.clear(conversationId: convId, profileId: pid)
        XCTAssertNil(SummaryFileStore.load(conversationId: convId, profileId: pid))
        XCTAssertTrue(summaryFileURLs().isEmpty)
    }

    // MARK: - FileLibraryStore memory* 只读挂载

    func testMemoryListAndReadViaVirtualPrefix() throws {
        SummaryFileStore.save(makeSummary("可被 grep 的内容"), conversationId: convId, profileId: pid, conversationTitle: "t")
        let list = FileLibraryStore.memoryList(profileId: pid)
        XCTAssertEqual(list.count, 1)
        let vpath = try XCTUnwrap(list.first?.path)
        XCTAssertTrue(vpath.hasPrefix("memory/summaries/"), "虚拟路径带 memory/ 前缀: \(vpath)")
        let content = try FileLibraryStore.memoryRead(vpath, profileId: pid)
        XCTAssertTrue(content.contains("可被 grep 的内容"))
    }

    func testResolveMemoryRejectsEscapes() {
        XCTAssertNil(FileLibraryStore.resolveMemory("memory/../../escape.md", profileId: pid), "../ 越狱必须拒")
        XCTAssertNil(FileLibraryStore.resolveMemory("memory/", profileId: pid), "空相对路径必须拒")
        XCTAssertNil(FileLibraryStore.resolveMemory("notmemory/x.md", profileId: pid), "非 memory/ 前缀不归它管")
        XCTAssertNotNil(FileLibraryStore.resolveMemory("memory/summaries/a.md", profileId: pid))
    }

    func testMemorySearchHitsSummaryContent() {
        SummaryFileStore.save(makeSummary("独特关键词薄荷绿斑马"), conversationId: convId, profileId: pid, conversationTitle: "t")
        let hits = FileLibraryStore.memorySearch("薄荷绿斑马", profileId: pid)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].path.hasPrefix("memory/"))
    }

    // MARK: - fs 工具对 memory/ 的只读契约

    func testWriteToolsRejectMemoryPaths() {
        SummaryFileStore.save(makeSummary(), conversationId: convId, profileId: pid, conversationTitle: "t")
        let memPath = FileLibraryStore.memoryList(profileId: pid).first!.path
        for (tool, json) in [
            ("fs_write",  #"{"path": "memory/x.md", "content": "hack"}"#),
            ("fs_append", #"{"path": "\#(memPath)", "content": "hack"}"#),
            ("fs_edit",   #"{"path": "\#(memPath)", "old_string": "a", "new_string": "b"}"#),
            ("fs_delete", #"{"path": "\#(memPath)"}"#),
            ("fs_rename", #"{"old_path": "\#(memPath)", "new_path": "stolen.md"}"#),
            ("fs_rename", #"{"old_path": "a.md", "new_path": "memory/sneak.md"}"#),
        ] {
            let r = FileLibraryTools.execute(name: tool, inputJSON: json, profileId: pid)
            XCTAssertTrue(r.isError, "\(tool) 对 memory/ 必须拒绝")
            XCTAssertTrue(r.text.contains("只读"), "\(tool) 拒绝文案应说明只读")
        }
        XCTAssertNotNil(SummaryFileStore.load(conversationId: convId, profileId: pid), "拒绝后文件应原样还在")
    }

    func testReadToolAllowsMemoryPath() {
        SummaryFileStore.save(makeSummary("工具能读到我"), conversationId: convId, profileId: pid, conversationTitle: "t")
        let memPath = FileLibraryStore.memoryList(profileId: pid).first!.path
        let r = FileLibraryTools.execute(name: "fs_read", inputJSON: #"{"path": "\#(memPath)"}"#, profileId: pid)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("工具能读到我"))
    }

    func testListAndSearchToolsIncludeMemoryTree() {
        SummaryFileStore.save(makeSummary("列表搜索双覆盖"), conversationId: convId, profileId: pid, conversationTitle: "t")
        let list = FileLibraryTools.execute(name: "fs_list", inputJSON: "{}", profileId: pid)
        XCTAssertTrue(list.text.contains("memory/summaries/"), "fs_list 应含记忆树: \(list.text)")
        let search = FileLibraryTools.execute(name: "fs_search", inputJSON: #"{"keyword": "列表搜索双覆盖"}"#, profileId: pid)
        XCTAssertTrue(search.text.contains("memory/"), "fs_search 应命中记忆树: \(search.text)")
    }
}
