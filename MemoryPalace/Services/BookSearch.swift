import Foundation
import PDFKit

/// F2 阅读器内全文搜索。txt 书逐章匹配；PDF 书优先原生 findString
/// （文本层就绪），未就绪降级搜 OCR 页缓存（诚实报告覆盖页数）。
enum BookSearch {

    struct Hit: Identifiable {
        let id = UUID()
        let chapter: Int        // txt=章号 / PDF=页码
        let title: String       // 章名 / "第 N 页"
        let snippet: String     // 命中句 ±30 字上下文
    }

    struct Result {
        var hits: [Hit]
        /// PDF 降级搜索时的覆盖说明（"已索引 12/645 页"），全量搜索为 nil
        var coverage: String? = nil
    }

    static let maxHitsPerChapter = 3
    static let maxHits = 60

    // MARK: - txt

    static func searchTxt(query: String, safeName: String, profileId: String,
                          chapters: [BookStore.ChapterMeta]) -> Result {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Result(hits: []) }
        var hits: [Hit] = []
        for meta in chapters {
            guard hits.count < maxHits,
                  let text = BookStore.loadChapterText(safeName: safeName, chapterNo: meta.no, profileId: profileId)
            else { continue }
            for snippet in snippets(of: q, in: text, limit: maxHitsPerChapter) {
                hits.append(Hit(chapter: meta.no, title: meta.title, snippet: snippet))
                if hits.count >= maxHits { break }
            }
        }
        return Result(hits: hits)
    }

    // MARK: - PDF

    static func searchPDF(query: String, document: PDFDocument, hasTextLayer: Bool,
                          safeName: String, profileId: String,
                          chapters: [BookStore.ChapterMeta]) -> Result {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Result(hits: []) }

        if hasTextLayer {
            let sels = document.findString(q, withOptions: [.caseInsensitive])
            var hits: [Hit] = []
            for sel in sels.prefix(maxHits) {
                guard let page = sel.pages.first else { continue }
                let pageNo = document.index(for: page) + 1
                // 命中处上下文：取整页文本切 snippet（findString 的 selection 只有命中词本身）
                let pageText = page.string ?? ""
                let snippet = snippets(of: q, in: pageText, limit: 1).first ?? q
                hits.append(Hit(chapter: pageNo, title: chapterTitle(for: pageNo, chapters: chapters), snippet: snippet))
            }
            return Result(hits: hits)
        }

        // 降级：搜已有的 OCR 页缓存
        var hits: [Hit] = []
        var cachedPages = 0
        for pageNo in 1...max(1, document.pageCount) {
            guard let lines = OCRStore.cachedLines(safeName: safeName, profileId: profileId, page: pageNo) else { continue }
            cachedPages += 1
            guard hits.count < maxHits else { continue }
            let pageText = lines.map(\.text).joined(separator: "\n")
            for snippet in snippets(of: q, in: pageText, limit: maxHitsPerChapter) {
                hits.append(Hit(chapter: pageNo, title: chapterTitle(for: pageNo, chapters: chapters), snippet: snippet))
                if hits.count >= maxHits { break }
            }
        }
        return Result(hits: hits, coverage: "已索引 \(cachedPages)/\(document.pageCount) 页")
    }

    private static func chapterTitle(for page: Int, chapters: [BookStore.ChapterMeta]) -> String {
        chapters.last(where: { $0.no <= page })?.title ?? "第 \(page) 页"
    }

    // MARK: - snippet 切取（±30 字，大小写不敏感，每文本最多 limit 条）

    static func snippets(of query: String, in text: String, limit: Int) -> [String] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var out: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        while out.count < limit,
              let r = text.range(of: query, options: [.caseInsensitive], range: searchRange) {
            let lo = text.index(r.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
            let hi = text.index(r.upperBound, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex
            var s = String(text[lo..<hi]).replacingOccurrences(of: "\n", with: " ")
            if lo > text.startIndex { s = "…" + s }
            if hi < text.endIndex { s += "…" }
            out.append(s)
            searchRange = r.upperBound..<text.endIndex
        }
        return out
    }
}
