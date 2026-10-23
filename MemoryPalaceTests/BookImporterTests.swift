import XCTest
import SwiftData
@testable import 记忆花园

final class BookImporterTests: XCTestCase {

    // MARK: - safeName

    func testSafeNameStripsIllegalCharsAndTraversal() {
        XCTAssertEqual(BookStore.safeName("../../etc/passwd"), "_/_/etc/passwd".replacingOccurrences(of: "/", with: "_"))
        XCTAssertEqual(BookStore.safeName("三体 / The Three-Body Problem"), "三体 _ The Three-Body Problem")
        XCTAssertEqual(BookStore.safeName(""), "未命名书籍")
        XCTAssertEqual(BookStore.safeName("   "), "未命名书籍")
        XCTAssertEqual(BookStore.safeName(String(repeating: "长", count: 200)).count, 80)
    }

    // MARK: - 章节切分：中文

    func testChineseChapterSplit() {
        let text = """
        第一章 疯狂年代

        红色联合对“四·二八兵团”总部大楼的攻击已持续了两天。

        第二章 寂静的春天

        叶哲泰被押上了批斗台。

        第三章 红岸之一

        雷志成走进了哨所。
        """
        let chapters = BookImporter.splitChapters(text)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertTrue(chapters[0].title.contains("第一章"))
        XCTAssertTrue(chapters[0].title.contains("疯狂年代"))
        XCTAssertTrue(chapters[0].content.contains("红色联合"))
        XCTAssertTrue(chapters[1].title.contains("第二章"))
        XCTAssertTrue(chapters[2].title.contains("第三章"))
    }

    func testChineseChapterNumberFormats() {
        let text = """
        第123章 大数字章节

        内容一。

        第十二节 中文数字

        内容二。

        第三卷 卷一

        内容三。

        第一回 回目体

        内容四。
        """
        let chapters = BookImporter.splitChapters(text)
        XCTAssertEqual(chapters.count, 4, "阿拉伯/中文数字 + 章节卷回都识别")
    }

    // MARK: - 章节切分：英文

    func testEnglishChapterSplit() {
        let text = """
        CHAPTER 1
        It was the best of times.

        CHAPTER 2 A Tale Begins
        Two men sat at the corner.

        CHAPTER III
        Roman numerals also work.
        """
        let chapters = BookImporter.splitChapters(text)
        XCTAssertEqual(chapters.count, 3)
    }

    // MARK: - Fallback 4000 字

    func testFallbackByLengthWhenNoChapterMarkers() {
        let text = String(repeating: "这是一段没有章节标记的散文。", count: 1000) // ~14000 字
        let chapters = BookImporter.splitChapters(text)
        XCTAssertGreaterThanOrEqual(chapters.count, 3, "约 14k 字应该切 3-4 章")
        for ch in chapters {
            XCTAssertLessThanOrEqual(ch.content.count, BookImporter.fallbackChunkSize, "每章不超过 fallback 大小")
        }
    }

    // MARK: - Preamble 处理

    func testPreambleBeforeFirstChapterBecomesIntroChapter() {
        let preamble = String(repeating: "这是序言。", count: 100) // > 200 字阈值
        let text = preamble + """


        第一章 正文

        正文开始。
        """
        let chapters = BookImporter.splitChapters(text)
        XCTAssertEqual(chapters.count, 2, "前言成为独立『序』章")
        XCTAssertEqual(chapters[0].title, "序")
        XCTAssertTrue(chapters[1].title.contains("第一章"))
    }

    // MARK: - P4-A 分章：更多标题 / 前言 / 自动分段 / 不丢字

    /// 切完不丢字、不重复：认出来的标题行 + 各章正文，去掉空白后按顺序拼起来 = 原文去掉空白；
    /// 每章的起止在全文里切出来也对得上
    private func assertLossless(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let r = BookImporter.split(text)
        let strip = { (s: String) in String(s.filter { !$0.isWhitespace }) }
        let joined = r.chapters.map { ch -> String in
            let body = ch.content == ch.title && !ch.auto ? "" : ch.content
            return (ch.auto ? "" : ch.title) + body
        }.joined()
        XCTAssertEqual(strip(joined), strip(r.source), "切完丢字或重复了", file: file, line: line)
        let src = Array(r.source)
        for ch in r.chapters {
            let slice = String(src[ch.start..<ch.end])
            let expect = (ch.auto ? "" : ch.title) + (ch.content == ch.title && !ch.auto ? "" : ch.content)
            XCTAssertEqual(strip(slice), strip(expect), "第「\(ch.title)」章的起止不对", file: file, line: line)
        }
    }

    func testShortPreambleIsKept() {
        let text = "三体\n刘慈欣\n\n第一章 疯狂年代\n\n攻击持续了两天。\n\n第二章 寂静的春天\n\n他被押上台。"
        let r = BookImporter.split(text)
        XCTAssertEqual(r.method, .headings)
        XCTAssertEqual(r.chapters.count, 3, "书名作者那两行也留着")
        XCTAssertTrue(r.chapters[0].content.contains("刘慈欣"))
        XCTAssertTrue(r.chapters[0].auto)
        assertLossless(text)
    }

    func testSpecialChineseHeadings() {
        let text = "楔子\n\n风起。\n\n第一回 开篇\n\n正文一。\n\n尾声\n\n完了。\n\n后记：写在最后\n\n谢谢。"
        let titles = BookImporter.splitChapters(text).map(\.title)
        XCTAssertEqual(titles, ["楔子", "第一回 开篇", "尾声", "后记：写在最后"])
        assertLossless(text)
    }

    func testEnglishHeadingVariants() {
        let text = "Prologue\n\nIt began.\n\nChapter One: The Road\n\nWe walked.\n\nCHAPTER II\n\nMore walking.\n\nPart Three\n\nEnd.\n\nEpilogue\n\nAfter."
        let titles = BookImporter.splitChapters(text).map(\.title)
        XCTAssertEqual(titles, ["Prologue", "Chapter One: The Road", "CHAPTER II", "Part Three", "Epilogue"])
        assertLossless(text)
    }

    func testMarkdownHeadings() {
        let text = "# 第一部分\n\n内容。\n\n## 小节\n\n更多内容。"
        XCTAssertEqual(BookImporter.splitChapters(text).map(\.title), ["# 第一部分", "## 小节"])
    }

    func testProseLineStartingWithChapterWordIsNotHeading() {
        let body = String(repeating: "正文正文正文。", count: 60)
        let text = "第一章 开始\n\n\(body)\n第三节课下课后，他说。\n\(body)\n\n第二章 继续\n\n\(body)"
        let titles = BookImporter.splitChapters(text).map(\.title)
        XCTAssertEqual(titles, ["第一章 开始", "第二章 继续"], "以句号结尾的「第三节课…」是正文")
        assertLossless(text)
    }

    func testTableOfContentsIsNotChapters() {
        let body = String(repeating: "正文正文正文。", count: 30)
        let text = "目录\n第一章 甲\n第二章 乙\n第三章 丙\n\n第一章 甲\n\n\(body)\n\n第二章 乙\n\n\(body)\n\n第三章 丙\n\n\(body)"
        let r = BookImporter.split(text)
        XCTAssertEqual(r.chapters.filter { !$0.auto && $0.title != "序" }.count, 3, "开头的目录不算三章")
        XCTAssertTrue(r.chapters.dropFirst().allSatisfy { $0.content.count > 50 })
        assertLossless(text)
    }

    func testStandaloneNumberHeadings() {
        let body = String(repeating: "Some prose goes here and keeps going. ", count: 30)
        let text = (1...4).map { "\($0)\n\n\(body)" }.joined(separator: "\n\n")
        let r = BookImporter.split(text)
        XCTAssertEqual(r.method, .numbered)
        XCTAssertEqual(r.chapters.map(\.title), ["1", "2", "3", "4"])
        assertLossless(text)
    }

    func testChineseNumberedHeadings() {
        let body = String(repeating: "这里是正文，写得很长很长。", count: 80)
        let text = ["一、出发", "二、路上", "三、到达"].map { "\($0)\n\n\(body)" }.joined(separator: "\n\n")
        let r = BookImporter.split(text)
        XCTAssertEqual(r.method, .numbered)
        XCTAssertEqual(r.chapters.map(\.title), ["一、出发", "二、路上", "三、到达"])
    }

    func testNumberedListInsideProseIsNotHeadings() {
        let body = String(repeating: "正文正文正文正文。", count: 400)
        let text = "\(body)\n\n1\n2\n3\n4\n\n\(body)"
        XCTAssertEqual(BookImporter.split(text).method, .length, "挤在一起的编号是列表，不当标题")
    }

    func testShortLineHeadings() {
        let body = String(repeating: "那天下午她推开门，看见窗台上的薄荷长得很好。", count: 80)
        let text = ["春", "夏", "秋天的事"].map { "\($0)\n\n\(body)" }.joined(separator: "\n\n")
        let r = BookImporter.split(text)
        XCTAssertEqual(r.method, .shortLines)
        XCTAssertEqual(r.chapters.map(\.title), ["春", "夏", "秋天的事"])
        assertLossless(text)
    }

    func testLengthFallbackCutsAtParagraphsWithFirstSentenceTitles() {
        let para = String(repeating: "这是一段没有标题的散文，句子很普通。", count: 12) // ~216 字一段
        let text = (0..<60).map { _ in para }.joined(separator: "\n\n")
        let r = BookImporter.split(text)
        XCTAssertEqual(r.method, .length)
        XCTAssertGreaterThanOrEqual(r.chapters.count, 3)
        for ch in r.chapters {
            XCTAssertTrue(ch.auto)
            XCTAssertLessThanOrEqual(ch.content.count, BookImporter.fallbackChunkSize)
            XCTAssertTrue(ch.content.hasSuffix("普通。"), "切在段落边界，不从句子中间切开")
            XCTAssertEqual(ch.title, "这是一段没有标题的散文，句子很普…", "第一句截 16 字")
        }
        assertLossless(text)
    }

    func testOneParagraphPerLineCutsAtLineBreaks() {
        let line = "他走过长长的街，想起很多事情，没有说话"   // 没有句号，一行一段
        let text = (0..<400).map { "\(line)\($0)" }.joined(separator: "\n")
        let r = BookImporter.split(text)
        for ch in r.chapters { XCTAssertTrue(ch.content.last?.isNumber ?? false, "切在换行上") }
        assertLossless(text)
    }

    func testHugeParagraphCutsAtSentenceEnd() {
        let text = String(repeating: "一句话说完了。", count: 2000)
        let r = BookImporter.split(text)
        XCTAssertGreaterThan(r.chapters.count, 2)
        for ch in r.chapters { XCTAssertTrue(ch.content.hasSuffix("。")) }
        assertLossless(text)
    }

    func testNoBreaksAtAllHardCuts() {
        let text = String(repeating: "字", count: 9000)
        let r = BookImporter.split(text)
        XCTAssertEqual(r.chapters.map(\.content.count), [4000, 4000, 1000])
        assertLossless(text)
    }

    func testTitleFromFirstSentenceIsCapped() {
        XCTAssertEqual(BookImporter.firstSentence("那天下午她推开门看见窗台上的薄荷长得很好。后面"), "那天下午她推开门看见窗台上的薄荷…")
        XCTAssertEqual(BookImporter.firstSentence("短句。后面"), "短句")
    }

    // MARK: - astra 审查回归（09-26）

    func testStrongAndNumberedHeadingsMix() {
        let body = String(repeating: "Some prose goes here and keeps going. ", count: 30)
        let text = "Prologue\n\n\(body)\n\n1\n\n\(body)\n\n2\n\n\(body)\n\n3\n\n\(body)"
        let r = BookImporter.split(text)
        XCTAssertEqual(r.chapters.map(\.title), ["Prologue", "1", "2", "3"], "Prologue 之后的编号章不能被吞")
        assertLossless(text)
    }

    func testShortChaptersMidBookAreNotTableOfContents() {
        let long = String(repeating: "正文正文正文。", count: 40)
        let text = "第一章 甲\n\n\(long)\n\n第二章 乙\n\n短。\n\n第三章 丙\n\n短。\n\n第四章 丁\n\n短。\n\n第五章 戊\n\n\(long)"
        XCTAssertEqual(BookImporter.splitChapters(text).count, 5, "书中间连着几章很短，不是目录")
        assertLossless(text)
    }

    func testQuestionTitleTraditionalAndVolumeFirst() {
        let text = "第十章 你是谁？\n\n正文一。\n\n第一節 下課\n\n正文二。\n\n卷一 开篇\n\n正文三。\n\n後記\n\n完。"
        XCTAssertEqual(BookImporter.splitChapters(text).map(\.title), ["第十章 你是谁？", "第一節 下課", "卷一 开篇", "後記"])
        assertLossless(text)
    }

    func testMarkdownHeadingInsideCodeFenceIsNotChapter() {
        let text = "# 第一部分\n\n内容。\n\n```\n# 这是代码注释\n```\n\n# 第二部分\n\n更多。"
        XCTAssertEqual(BookImporter.splitChapters(text).map(\.title), ["# 第一部分", "# 第二部分"])
        assertLossless(text)
    }

    func testOversizedChapterIsSplitAgain() {
        let para = String(repeating: "这一章特别特别长。", count: 100)
        let huge = (0..<80).map { _ in para }.joined(separator: "\n\n")   // ~72000 字
        let text = "第一章 长\n\n\(huge)\n\n第二章 短\n\n完。"
        let chs = BookImporter.splitChapters(text)
        XCTAssertGreaterThan(chs.count, 2)
        XCTAssertEqual(chs.first?.title, "第一章 长")
        XCTAssertTrue(chs.allSatisfy { $0.content.count <= BookImporter.maxSectionChars })
        XCTAssertEqual(chs.last?.title, "第二章 短")
        assertLossless(text)
    }

    // MARK: - 归一化

    func testNormalizeFoldsCRLFAndExcessNewlines() {
        let raw = "第一章\r\n\r\n\r\n\r\n内容\r\n第二章\r\n内容"
        let normalized = BookImporter.normalize(raw)
        XCTAssertFalse(normalized.contains("\r"))
        XCTAssertFalse(normalized.contains("\n\n\n"))
    }

    // MARK: - 空输入

    func testEmptyTextReturnsEmptyChapters() {
        XCTAssertTrue(BookImporter.splitChapters("").isEmpty)
        XCTAssertTrue(BookImporter.splitChapters("    \n\n   ").isEmpty)
    }

    // MARK: - B1：同名书查重（爸爸 batch B1）

    @MainActor
    func testDuplicateBookNameThrows() async throws {
        let pid = "xctest-bookimporter-dup"
        let tempBooksRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("books-test-\(UUID().uuidString)")

        // 模拟已有同名书目录（书名经 safeName 后撞）
        let safeName = BookStore.safeName("测试书")
        let bookDir = BookStore.bookDir(safeName: safeName, profileId: pid)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBooksRoot) }

        // 写一个 txt 源文件
        let srcFile = tempBooksRoot.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: tempBooksRoot, withIntermediateDirectories: true)
        try "第一章\n内容".write(to: srcFile, atomically: true, encoding: .utf8)

        // 没有 SwiftData ctx 也能跑 importTxt 的查重路径（duplicate 在 ctx 之前抛错）
        // 但需要 ctx 参数——用 dummy in-memory
        let container = try ModelContainer(for: BookEntry.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)

        do {
            _ = try await BookImporter.importTxt(
                url: srcFile, bookName: "测试书", profileId: pid, context: ctx
            )
            XCTFail("同名应该抛 duplicateName")
        } catch let e as BookImporter.ImportError {
            if case .duplicateName(let n) = e {
                XCTAssertEqual(n, "测试书")
            } else {
                XCTFail("wrong error: \(e)")
            }
        }

        // 清理
        try? FileManager.default.removeItem(at: bookDir)
    }

    // MARK: - B2：refreshEntries 分两阶段（爸爸 batch B2）

    @MainActor
    func testRefreshEntriesKeepsEntryWhenIndexUnreadable() async throws {
        let pid = "xctest-refresh-keep"
        let container = try ModelContainer(for: BookEntry.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)

        let bookDir = BookStore.bookDir(safeName: "未下载完", profileId: pid)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: BookStore.booksRoot(profileId: pid)) }

        // 预置一个 SwiftData entry，模拟之前能读 index 时已经创建过
        let entry = BookEntry(id: "未下载完", profileId: pid, name: "未下载完", totalChapters: 10)
        entry.currentChapter = 5
        ctx.insert(entry)
        try ctx.save()

        // **故意不写 index.json**——模拟 iCloud 还在下载
        XCTAssertFalse(FileManager.default.fileExists(atPath: BookStore.indexURL(safeName: "未下载完", profileId: pid).path))

        // 跑 refresh
        await BookStore.refreshEntriesAsync(profileId: pid, context: ctx)

        // entry 仍然在——文件夹存在就保留，不能因为 index 读不出就误删（爸爸 B2 痛点）
        let pid2 = pid
        let after = (try? ctx.fetch(FetchDescriptor<BookEntry>(
            predicate: #Predicate<BookEntry> { $0.profileId == pid2 }
        ))) ?? []
        XCTAssertEqual(after.count, 1, "index 读不出不能删 entry")
        XCTAssertEqual(after.first?.currentChapter, 5, "字段保持原状")
    }

    @MainActor
    func testRefreshEntriesDeletesWhenDirectoryGone() async throws {
        let pid = "xctest-refresh-delete"
        let container = try ModelContainer(for: BookEntry.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)

        // 预置 entry 但磁盘上没目录
        let entry = BookEntry(id: "已经被外部删了", profileId: pid, name: "x", totalChapters: 0)
        ctx.insert(entry)
        try ctx.save()
        defer { try? FileManager.default.removeItem(at: BookStore.booksRoot(profileId: pid)) }

        await BookStore.refreshEntriesAsync(profileId: pid, context: ctx)

        let pid2 = pid
        let after = (try? ctx.fetch(FetchDescriptor<BookEntry>(
            predicate: #Predicate<BookEntry> { $0.profileId == pid2 }
        ))) ?? []
        XCTAssertEqual(after.count, 0, "目录真的没了就该删")
    }
}
