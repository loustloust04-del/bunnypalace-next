import MemoryCore
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
        SummaryFileStore.save(s, conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "测试对话")
        let loaded = SummaryFileStore.load(conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        XCTAssertEqual(loaded?.summary, s.summary)
        XCTAssertEqual(loaded?.coveredCount, s.coveredCount)
        XCTAssertEqual(loaded.map { Int($0.updatedAt.timeIntervalSince1970) },
                       Int(s.updatedAt.timeIntervalSince1970), "时间秒级精度往返")
    }

    func testFilenameUsesPrefix8AndTitleSlug() {
        SummaryFileStore.save(makeSummary(), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "测试对话")
        let names = summaryFileURLs().map(\.lastPathComponent)
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasPrefix("AABBCCDD-"), "convId 前 8 是稳定锚，实际: \(names[0])")
        XCTAssertTrue(names[0].contains("测试对话"))
    }

    func testRenameFollowsTitleChange() {
        SummaryFileStore.save(makeSummary(), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "旧标题")
        SummaryFileStore.save(makeSummary("更新后的摘要"), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "新标题")
        let names = summaryFileURLs().map(\.lastPathComponent)
        XCTAssertEqual(names.count, 1, "改标题后不应出现两个文件")
        XCTAssertTrue(names[0].contains("新标题"))
        XCTAssertEqual(SummaryFileStore.load(conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.summary, "更新后的摘要")
    }

    func testSlugSanitizesDangerousCharsAndTruncates() {
        SummaryFileStore.save(makeSummary(), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid),
                              conversationTitle: "a/b:c*?\"<>|#\n一二三四五六七八九十一二三四五六七八九十一二三四五")
        let name = summaryFileURLs().map(\.lastPathComponent).first ?? ""
        XCTAssertFalse(name.dropFirst(9).contains("/"), "危险字符应被清洗: \(name)")
        for ch in ":*?\"<>|#" { XCTAssertFalse(name.contains(ch), "残留危险字符 \(ch): \(name)") }
        XCTAssertLessThan(name.count, 9 + 24 + 4, "标题应截到 24 字内: \(name)")
    }

    func testEmptyTitleFallsBackToUntitled() {
        SummaryFileStore.save(makeSummary(), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "  ")
        let name = summaryFileURLs().map(\.lastPathComponent).first ?? ""
        XCTAssertTrue(name.contains("untitled"), "空标题应回退 untitled: \(name)")
    }

    func testBodyContainingDashLinesSurvives() {
        let body = "前段\n---\n后段（正文里的分隔线不该破坏 frontmatter 解析）"
        SummaryFileStore.save(makeSummary(body), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "t")
        XCTAssertEqual(SummaryFileStore.load(conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.summary, body)
    }

    func testCorruptFrontmatterLoadsNilAndSelfHeals() throws {
        SummaryFileStore.save(makeSummary(), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "t")
        let url = try XCTUnwrap(summaryFileURLs().first)
        try Data("不是 frontmatter 的垃圾内容".utf8).write(to: url)
        XCTAssertNil(SummaryFileStore.load(conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)), "坏文件应视为无摘要（自愈：下次重压）")
    }

    func testClearRemovesFile() {
        SummaryFileStore.save(makeSummary(), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "t")
        SummaryFileStore.clear(conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        XCTAssertNil(SummaryFileStore.load(conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        XCTAssertTrue(summaryFileURLs().isEmpty)
    }

    // MARK: - FileLibraryStore memory* 只读挂载

    func testMemoryListAndReadViaVirtualPrefix() throws {
        SummaryFileStore.save(makeSummary("可被 grep 的内容"), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "t")
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
        SummaryFileStore.save(makeSummary("独特关键词薄荷绿斑马"), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "t")
        let hits = FileLibraryStore.memorySearch("薄荷绿斑马", profileId: pid)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].path.hasPrefix("memory/"))
    }

    // MARK: - fs 工具对 memory/ 的只读契约

    func testWriteToolsRejectMemoryPaths() {
        SummaryFileStore.save(makeSummary(), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "t")
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
        XCTAssertNotNil(SummaryFileStore.load(conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)), "拒绝后文件应原样还在")
    }

    func testReadToolAllowsMemoryPath() {
        SummaryFileStore.save(makeSummary("工具能读到我"), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "t")
        let memPath = FileLibraryStore.memoryList(profileId: pid).first!.path
        let r = FileLibraryTools.execute(name: "fs_read", inputJSON: #"{"path": "\#(memPath)"}"#, profileId: pid)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("工具能读到我"))
    }

    func testListAndSearchToolsIncludeMemoryTree() {
        SummaryFileStore.save(makeSummary("列表搜索双覆盖"), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "t")
        let list = FileLibraryTools.execute(name: "fs_list", inputJSON: "{}", profileId: pid)
        XCTAssertTrue(list.text.contains("memory/summaries/"), "fs_list 应含记忆树: \(list.text)")
        let search = FileLibraryTools.execute(name: "fs_search", inputJSON: #"{"keyword": "列表搜索双覆盖"}"#, profileId: pid)
        XCTAssertTrue(search.text.contains("memory/"), "fs_search 应命中记忆树: \(search.text)")
    }

    /// C 档案里点开头的（历史 / 提案和原始输出 / 分组钩子）对助手隐藏：列表不出、搜不到、直接读也拒；页和 memory/ 别处照旧
    func testFsToolsHideWikiInternals() throws {
        SummaryFileStore.save(makeSummary("摘要也有暗号薄荷"), conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "t")
        let wiki = FileLibraryStore.memoryRoot(profileId: pid).appendingPathComponent("wiki", isDirectory: true)
        for (rel, text) in [("人/小慧.md", "# 小慧\n暗号薄荷"), (".history/人/小慧/20261018-050200.md", "暗号薄荷 旧版"),
                            (".proposals/p.json", "{\"暗号薄荷\":1}"), (".proposals/drafts/run-原始.txt", "暗号薄荷 原始输出"),
                            (".runs/20261018-050200-电影.md", "# 整理记录\n暗号薄荷 工具结果全文"),
                            ("工程/.group.md", "暗号薄荷 钩子")] {
            try WikiStore.writeAtomic(Data(text.utf8), to: wiki.appendingPathComponent(rel))
        }

        let list = FileLibraryTools.execute(name: "fs_list", inputJSON: "{}", profileId: pid).text
        XCTAssertTrue(list.contains("memory/wiki/人/小慧.md"), list)
        XCTAssertTrue(list.contains("memory/summaries/"), "memory/ 别处照旧: \(list)")
        for hidden in [".history", ".proposals", ".runs", ".group.md"] { XCTAssertFalse(list.contains(hidden), "\(hidden) 不该列出: \(list)") }

        let search = FileLibraryTools.execute(name: "fs_search", inputJSON: #"{"keyword": "暗号薄荷"}"#, profileId: pid).text
        XCTAssertTrue(search.contains("memory/wiki/人/小慧.md"), search)
        XCTAssertTrue(search.contains("memory/summaries/"), search)
        for hidden in [".history", ".proposals", ".runs", ".group.md"] { XCTAssertFalse(search.contains(hidden), "\(hidden) 不该搜到: \(search)") }

        for path in ["memory/wiki/.proposals/p.json", "memory/wiki/.proposals/drafts/run-原始.txt", "memory/wiki/工程/.group.md",
                     "memory/wiki/.history/人/小慧/20261018-050200.md", "memory/wiki/主题/../.proposals/p.json",
                     "memory//wiki/./.proposals/p.json", "memory/wiki/.runs/20261018-050200-电影.md",
                     "memory/wiki/主题/../.runs/20261018-050200-电影.md",
                     "memory//wiki/./.runs/20261018-050200-电影.md"] {
            let r = FileLibraryTools.execute(name: "fs_read", inputJSON: #"{"path": "\#(path)"}"#, profileId: pid)
            XCTAssertTrue(r.isError, "\(path) 直接读也要拒")
            XCTAssertFalse(r.text.contains("暗号薄荷"), path)
        }
        let page = FileLibraryTools.execute(name: "fs_read", inputJSON: #"{"path": "memory/wiki/人/小慧.md"}"#, profileId: pid)
        XCTAssertFalse(page.isError)
        XCTAssertTrue(page.text.contains("暗号薄荷"))
    }

    /// 本人那组落盘 {{user}}：聊天 fs 工具用名字读得到；列表 / 搜索 / 正文 / 续读提示显示名字；隐藏规则在还原后的真实路径上照旧；别的文件里的 {{user}} 宏原样
    func testFsToolsMapUserBranchToCurrentName() throws {
        let wiki = FileLibraryStore.memoryRoot(profileId: pid).appendingPathComponent("wiki", isDirectory: true)
        for (rel, text) in [("{{user}}/身体.md", "# 身体\n星砚口令 见 [[{{user}}/作息]]"), ("{{user}}/.group.md", "星砚口令 钩子"),
                            ("INDEX.md", "# C 档案\n\n## {{user}}（1 页）\n- [[{{user}}/身体]] 身体\n")] {
            try WikiStore.writeAtomic(Data(text.utf8), to: wiki.appendingPathComponent(rel))
        }
        try WikiStore.writeAtomic(Data("{{user}} 的模板 星砚口令".utf8),
                                  to: FileLibraryStore.memoryRoot(profileId: pid).appendingPathComponent("cc/note.md"))
        func run(_ name: String, _ json: String) -> FileLibraryTools.Result {
            FileLibraryTools.execute(name: name, inputJSON: json, profileId: pid, userName: "星砚")
        }

        let page = run("fs_read", #"{"path": "memory/wiki/星砚/身体.md"}"#)
        XCTAssertFalse(page.isError, page.text)
        XCTAssertTrue(page.text.contains("[[星砚/作息]]") && !page.text.contains("{{user}}"), page.text)
        let index = run("fs_read", #"{"path": "memory/wiki/INDEX.md"}"#)
        XCTAssertTrue(index.text.contains("## 星砚（1 页）") && index.text.contains("[[星砚/身体]]"), index.text)
        XCTAssertTrue(run("fs_read", #"{"path": "memory/wiki/{{user}}/身体.md"}"#).text.contains("星砚口令"), "字面量也认")
        XCTAssertTrue(run("fs_read", #"{"path": "memory/wiki/星砚/.group.md"}"#).isError, "隐藏规则在还原后的路径上照旧")

        let list = run("fs_list", "{}").text
        XCTAssertTrue(list.contains("memory/wiki/星砚/身体.md") && !list.contains("{{user}}/"), list)
        let search = run("fs_search", #"{"keyword": "星砚口令"}"#).text
        XCTAssertTrue(search.contains("memory/wiki/星砚/身体.md: "), search)
        XCTAssertTrue(search.contains("[[星砚/作息]]"), search)
        XCTAssertFalse(search.contains(".group.md"), search)
        XCTAssertTrue(search.contains("{{user}} 的模板"), "wiki 以外文件里的宏原样")
        XCTAssertTrue(run("fs_read", #"{"path": "memory/cc/note.md"}"#).text.contains("{{user}} 的模板"))
        XCTAssertTrue(run("fs_write", #"{"path": "memory/wiki/星砚/身体.md", "content": "x"}"#).isError, "memory/ 照旧只读")
    }
}
