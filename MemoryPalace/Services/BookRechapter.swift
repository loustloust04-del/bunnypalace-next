import Foundation
import SwiftData

/// 已导入的 txt 书「重新分章」（plan-reading-marks P4-C 限定版）。
///
/// - 这本书没有批注 / 书签 / 生词出处 → 原地重切：先把现在的章节 + index 打包成 zip 放进文件库「书房备份」，
///   新章节写进临时目录，整个目录一次换过去（中途失败旧书原样不动）。
/// - 有任意一样 → 不动原书，只能「另存一本重新分章的新书」（旧书和它的批注原样保留）。
/// - PDF 不参与。
enum BookRechapter {
    struct Preview {
        let result: BookImporter.SplitResult
        let oldTitles: [String]
        let notes: Int
        let bookmarks: Int
        let vocab: Int
        /// 现在读到的位置在全文里的字符 offset（原地重切后换算到新章）
        let readingOffset: Int

        var blocked: Bool { notes + bookmarks + vocab > 0 }
        var longest: Int { result.chapters.map(\.content.count).max() ?? 0 }
        var unchanged: Bool { result.chapters.map(\.title) == oldTitles }
    }

    enum RechapterError: LocalizedError {
        case notText, unreadable, empty, blocked, duplicate(String)
        var errorDescription: String? {
            switch self {
            case .notText: return "只有 txt 书能重新分章"
            case .unreadable: return "读不出这本书的章节"
            case .empty: return "这本书没有正文"
            case .blocked: return "这本书有批注 / 书签 / 生词出处，不能原地重新分章"
            case .duplicate(let name): return "书架里已经有《\(name)》了"
            }
        }
    }


    /// 拼回全文：有 source.txt 直接用；老书把「标题行 + 正文」按章拼回。返回全文 + 每章起点。
    static func reconstruct(index: BookStore.BookIndex, safeName: String, profileId: String) -> (text: String, starts: [Int: Int])? {
        if let src = try? String(contentsOf: BookStore.sourceURL(safeName: safeName, profileId: profileId), encoding: .utf8),
           !src.isEmpty, index.chapters.allSatisfy({ $0.start != nil }) {
            return (src, Dictionary(uniqueKeysWithValues: index.chapters.map { ($0.no, $0.start ?? 0) }))
        }
        var parts: [String] = []
        var starts: [Int: Int] = [:]
        var offset = 0
        // 旧版没记 auto：按长度切的书每章都叫「第 N 章」（带空格、从 1 连着编）；「序」只会是旧版补的第一章。
        // 只有整本都是这种编号才当成自动标题——真有一章叫「第 3 章」的书不会被误删标题
        let chapters = index.chapters.sorted(by: { $0.no < $1.no })
        let allNumbered = chapters.allSatisfy { $0.title == "第 \($0.no) 章" }
        for ch in chapters {
            guard let body = BookStore.loadChapterText(safeName: safeName, chapterNo: ch.no, profileId: profileId) else { return nil }
            let synthetic = ch.auto == true || (ch.auto == nil && (allNumbered || (ch.no == 1 && ch.title == "序")))
            var piece = synthetic ? "" : ch.title
            if body != ch.title || synthetic {
                piece += piece.isEmpty ? body : "\n\n" + body
            }
            starts[ch.no] = offset
            parts.append(piece)
            offset += piece.count + 2
        }
        let text = parts.joined(separator: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (text, starts)
    }

    @MainActor
    static func preview(safeName: String, profileId: String, context: ModelContext) async throws -> Preview {
        guard let index = BookStore.loadIndex(safeName: safeName, profileId: profileId) else { throw RechapterError.unreadable }
        guard index.format == "txt" else { throw RechapterError.notText }
        // 文件在却读不出（iCloud 没下完 / 坏了）不能当成「没有」：算 1，拦住原地重切
        func count(_ url: URL, _ loaded: Int) -> Int {
            let fm = FileManager.default
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            if fm.fileExists(atPath: placeholder.path) { return max(loaded, 1) }
            return fm.fileExists(atPath: url.path) && loaded == 0 && !isEmptyJSONArray(url) ? 1 : loaded
        }
        let notes = count(BookStore.notesURL(safeName: safeName, profileId: profileId),
                          BookStore.loadNotes(safeName: safeName, profileId: profileId).count)
        let bookmarks = count(BookStore.bookmarksURL(safeName: safeName, profileId: profileId),
                              BookStore.loadBookmarks(safeName: safeName, profileId: profileId).count)
        // 生词出处 `<safeName>#chapter<N>#<offset>`：可选字段谓词不可靠，取出来在内存里筛
        let prefix = "\(safeName)#"
        let vocab = ((try? context.fetch(FetchDescriptor<VocabProgress>())) ?? [])
            .filter { $0.sourceBookRef?.hasPrefix(prefix) ?? false }.count
        let (result, offset) = try await Task.detached(priority: .userInitiated) { () -> (BookImporter.SplitResult, Int) in
            guard let whole = reconstruct(index: index, safeName: safeName, profileId: profileId) else { throw RechapterError.unreadable }
            let r = BookImporter.split(whole.text)
            guard !r.chapters.isEmpty else { throw RechapterError.empty }
            return (r, whole.starts[index.currentChapter] ?? 0)
        }.value
        return Preview(result: result, oldTitles: index.chapters.sorted { $0.no < $1.no }.map(\.title),
                       notes: notes, bookmarks: bookmarks, vocab: vocab, readingOffset: offset)
    }

    /// 原地重切（没有批注 / 书签 / 生词出处时）
    @MainActor
    static func applyInPlace(_ preview: Preview, safeName: String, profileId: String, context: ModelContext) async throws {
        guard !preview.blocked else { throw RechapterError.blocked }
        guard var index = BookStore.loadIndex(safeName: safeName, profileId: profileId) else { throw RechapterError.unreadable }
        let dir = BookStore.bookDir(safeName: safeName, profileId: profileId)
        let backupDir = FileLibraryStore.libraryRoot(profileId: profileId).appendingPathComponent("书房备份", isDirectory: true)
        let bookName = index.name
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try backup(bookDir: dir, bookName: bookName, to: backupDir)

            // 新书目录先写在旁边：章节 / source / index 是新的，其余文件（封面、空的 notes / bookmarks）照搬
            let staging = dir.deletingLastPathComponent().appendingPathComponent(".\(safeName).rechapter")
            try? fm.removeItem(at: staging)
            let metas = try BookStore.writeChapters(preview.result, into: staging)
            for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let name = item.lastPathComponent
                if name.hasPrefix("chapter_") || name == "index.json" || name == "source.txt" { continue }
                try fm.copyItem(at: item, to: staging.appendingPathComponent(name))
            }
            let newNo = (preview.result.chapters.lastIndex { $0.start <= preview.readingOffset } ?? 0) + 1
            index.chapters = metas
            index.totalChapters = metas.count
            index.currentChapter = min(newNo, metas.count)
            index.scrollRatio = 0
            index.updatedAt = Date()
            try BookStore.writeIndex(index, into: staging)
            // 整个目录一次换过去：换失败旧目录还在
            _ = try fm.replaceItemAt(dir, withItemAt: staging)
        }.value
        BookStore.refreshEntries(profileId: profileId, context: context)
    }

    /// 另存一本重新分章的新书（原书有批注 / 书签 / 生词出处时）。返回新书 safeName。
    @MainActor
    static func saveAsNewBook(_ preview: Preview, safeName: String, profileId: String, context: ModelContext) async throws -> String {
        guard let index = BookStore.loadIndex(safeName: safeName, profileId: profileId) else { throw RechapterError.unreadable }
        let newName = index.name + "（重新分章）"
        let newSafe = BookStore.safeName(newName)
        let newDir = BookStore.bookDir(safeName: newSafe, profileId: profileId)
        guard !FileManager.default.fileExists(atPath: newDir.path) else { throw RechapterError.duplicate(newName) }
        let oldCover = BookStore.coverURL(safeName: safeName, profileId: profileId)
        try await Task.detached(priority: .userInitiated) {
            let metas = try BookStore.writeChapters(preview.result, into: newDir)
            let now = Date()
            let newIndex = BookStore.BookIndex(name: newName, author: index.author, format: "txt",
                                               createdAt: now, updatedAt: now, currentChapter: 1, scrollRatio: 0,
                                               totalChapters: metas.count, chapters: metas)
            try BookStore.writeIndex(newIndex, into: newDir)
            try BookStore.saveNotes([], safeName: newSafe, profileId: profileId)
            if FileManager.default.fileExists(atPath: oldCover.path) {
                try? FileManager.default.copyItem(at: oldCover, to: BookStore.coverURL(safeName: newSafe, profileId: profileId))
            }
        }.value
        BookStore.refreshEntries(profileId: profileId, context: context)
        return newSafe
    }

    nonisolated private static func isEmptyJSONArray(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return (try? JSONSerialization.jsonObject(with: data) as? [Any])?.isEmpty == true
    }

    /// 旧章节 + index（+ source）打成 zip 放进「书房备份」（文件库里，不在 books/ 下，不会被当成书）
    nonisolated private static func backup(bookDir: URL, bookName: String, to backupDir: URL) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("rechapter-\(UUID().uuidString)", isDirectory: true)
        let folder = stage.appendingPathComponent("book", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        for item in try fm.contentsOfDirectory(at: bookDir, includingPropertiesForKeys: nil) {
            let name = item.lastPathComponent
            guard name.hasPrefix("chapter_") || name == "index.json" || name == "source.txt" else { continue }
            try fm.copyItem(at: item, to: folder.appendingPathComponent(name))
        }
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let target = backupDir.appendingPathComponent("\(BookStore.safeName(bookName))-重新分章前-\(stamp.string(from: Date())).zip")
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordError) { zipURL in
            do { try fm.copyItem(at: zipURL, to: target) } catch { copyError = error }
        }
        if let e = coordError ?? copyError { throw e }
    }
}
