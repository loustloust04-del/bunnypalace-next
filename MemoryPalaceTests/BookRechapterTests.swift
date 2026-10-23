import XCTest
import SwiftData
@testable import 记忆花园

/// P4-C 重新分章：老书拼回全文、原地重切 + 备份、有批注时拦住只能另存。
@MainActor
final class BookRechapterTests: XCTestCase {
    private var pid = ""
    private var context: ModelContext!

    override func setUp() async throws {
        pid = "xctest-rechapter-\(UUID().uuidString.prefix(8))"
        let container = try ModelContainer(for: BookEntry.self, VocabProgress.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: FileLibraryStore.libraryRoot(profileId: pid))
    }

    /// 老版本导入的书：没认出标题，按 4000 字切成「第 N 章」，正文里其实有标题
    private func makeOldBook(_ safe: String = "老书") throws -> String {
        let body = String(repeating: "他走了很远的路。", count: 40)
        let whole = "Chapter One\n\n\(body)\n\nChapter Two\n\n\(body)\n\nChapter Three\n\n\(body)"
        let half = whole.count / 2
        let parts = [String(whole.prefix(half)), String(whole.dropFirst(half))]
        for (i, p) in parts.enumerated() {
            try BookStore.saveChapterText(p.trimmingCharacters(in: .whitespacesAndNewlines), safeName: safe, chapterNo: i + 1, profileId: pid)
        }
        let now = Date()
        let index = BookStore.BookIndex(name: safe, author: "", format: "txt", createdAt: now, updatedAt: now,
                                        currentChapter: 2, scrollRatio: 0.4, totalChapters: 2,
                                        chapters: [.init(no: 1, title: "第 1 章", chars: 0), .init(no: 2, title: "第 2 章", chars: 0)])
        try BookStore.saveIndex(index, safeName: safe, profileId: pid)
        try BookStore.saveNotes([], safeName: safe, profileId: pid)
        return safe
    }

    func testReconstructSkipsSyntheticTitles() throws {
        let safe = try makeOldBook()
        let index = try XCTUnwrap(BookStore.loadIndex(safeName: safe, profileId: pid))
        let whole = try XCTUnwrap(BookRechapter.reconstruct(index: index, safeName: safe, profileId: pid))
        XCTAssertFalse(whole.text.contains("第 1 章"), "自动编的标题不拼回正文")
        XCTAssertTrue(whole.text.hasPrefix("Chapter One"))
        XCTAssertEqual(whole.starts[1], 0)
    }

    func testRealNumberedTitleIsKeptWhenNotAllSynthetic() throws {
        let safe = "真标题"
        try BookStore.saveChapterText("开头的话。", safeName: safe, chapterNo: 1, profileId: pid)
        try BookStore.saveChapterText("第三章的正文。", safeName: safe, chapterNo: 2, profileId: pid)
        let now = Date()
        let index = BookStore.BookIndex(name: safe, author: "", format: "txt", createdAt: now, updatedAt: now,
                                        currentChapter: 1, scrollRatio: 0, totalChapters: 2,
                                        chapters: [.init(no: 1, title: "楔子", chars: 0), .init(no: 2, title: "第 3 章", chars: 0)])
        try BookStore.saveIndex(index, safeName: safe, profileId: pid)
        let whole = try XCTUnwrap(BookRechapter.reconstruct(index: index, safeName: safe, profileId: pid))
        XCTAssertTrue(whole.text.contains("第 3 章"), "不是整本都叫「第 N 章」，这个标题是真的，要拼回")
    }

    func testUnreadableNotesFileBlocks() async throws {
        let safe = try makeOldBook()
        try "{ broken".data(using: .utf8)!.write(to: BookStore.notesURL(safeName: safe, profileId: pid))
        let preview = try await BookRechapter.preview(safeName: safe, profileId: pid, context: context)
        XCTAssertTrue(preview.blocked, "批注文件读不出来不能当成没有批注")
    }

    func testApplyInPlaceRewritesAndBacksUp() async throws {
        let safe = try makeOldBook()
        let preview = try await BookRechapter.preview(safeName: safe, profileId: pid, context: context)
        XCTAssertFalse(preview.blocked)
        XCTAssertEqual(preview.result.method, .headings)
        XCTAssertEqual(preview.result.chapters.map(\.title), ["Chapter One", "Chapter Two", "Chapter Three"])

        try await BookRechapter.applyInPlace(preview, safeName: safe, profileId: pid, context: context)
        let index = try XCTUnwrap(BookStore.loadIndex(safeName: safe, profileId: pid))
        XCTAssertEqual(index.totalChapters, 3)
        XCTAssertEqual(index.chapters.map(\.title), ["Chapter One", "Chapter Two", "Chapter Three"])
        XCTAssertNil(BookStore.loadChapterText(safeName: safe, chapterNo: 4, profileId: pid))
        XCTAssertTrue(BookStore.loadChapterText(safeName: safe, chapterNo: 3, profileId: pid)?.contains("他走了") ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: BookStore.sourceURL(safeName: safe, profileId: pid).path))
        XCTAssertEqual(index.currentChapter, 2, "原来读到第 2 段（全文后半）→ 新目录里的第二章")
        XCTAssertEqual(index.scrollRatio, 0)
        XCTAssertNotNil(BookStore.loadNotes(safeName: safe, profileId: pid), "其余文件照搬")

        let backups = try FileManager.default.contentsOfDirectory(
            atPath: FileLibraryStore.libraryRoot(profileId: pid).appendingPathComponent("书房备份").path)
        XCTAssertEqual(backups.filter { $0.hasSuffix(".zip") }.count, 1, "原来的章节打包进书房备份")
        let books = try FileManager.default.contentsOfDirectory(
            atPath: BookStore.bookDir(safeName: safe, profileId: pid).deletingLastPathComponent().path)
        XCTAssertFalse(books.contains { $0.hasSuffix(".rechapter") }, "临时目录换完就没了")

        // 再重切一次走 source.txt，结果一样
        let again = try await BookRechapter.preview(safeName: safe, profileId: pid, context: context)
        XCTAssertTrue(again.unchanged)
    }

    func testNotesBlockInPlaceButAllowSaveAsNew() async throws {
        let safe = try makeOldBook()
        try BookStore.saveNotes([BookStore.Note(id: "n", chapter: 1, anchorText: "他走了", anchorStart: 0, anchorEnd: 3,
                                                kind: "highlight", content: "", role: "user", messageId: nil, createdAt: Date())],
                                safeName: safe, profileId: pid)
        let preview = try await BookRechapter.preview(safeName: safe, profileId: pid, context: context)
        XCTAssertTrue(preview.blocked)
        XCTAssertEqual(preview.notes, 1)
        do {
            try await BookRechapter.applyInPlace(preview, safeName: safe, profileId: pid, context: context)
            XCTFail("有批注不能原地重切")
        } catch {}
        XCTAssertEqual(BookStore.loadIndex(safeName: safe, profileId: pid)?.totalChapters, 2, "原书没动")

        let newSafe = try await BookRechapter.saveAsNewBook(preview, safeName: safe, profileId: pid, context: context)
        XCTAssertEqual(newSafe, "老书（重新分章）")
        XCTAssertEqual(BookStore.loadIndex(safeName: newSafe, profileId: pid)?.totalChapters, 3)
        XCTAssertEqual(BookStore.loadNotes(safeName: newSafe, profileId: pid).count, 0)
        XCTAssertEqual(BookStore.loadNotes(safeName: safe, profileId: pid).count, 1, "旧书批注原样")
    }

    func testVocabSourceBlocks() async throws {
        let safe = try makeOldBook()
        let v = VocabProgress(word: "road", status: .unknown, seconds: 0)
        v.sourceBookRef = "\(safe)#chapter1#10"
        context.insert(v)
        let preview = try await BookRechapter.preview(safeName: safe, profileId: pid, context: context)
        XCTAssertEqual(preview.vocab, 1)
        XCTAssertTrue(preview.blocked)
    }
}
