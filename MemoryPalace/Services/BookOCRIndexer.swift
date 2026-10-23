import Foundation
import PDFKit

/// CR-7「坨坨」路线：扫描书后台全书索引——逐页 OCR（读过的页缓存命中免费）→
/// 全部完成后把文本层写回 book.pdf（原子替换）→ hasTextLayer 翻 true。
/// 之后这本书走文字版路线：原生长按选字把手 / findString 锚定。
///
/// 节奏：utility 优先级逐页跑，页与页之间让出 actor——她翻页触发的按需
/// OCR（userInitiated）能插队，阅读上下文不断供。app 杀掉 = 页缓存即断点，
/// 下次开书续跑。
actor BookOCRIndexer {
    static let shared = BookOCRIndexer()

    private var running: Set<String> = []

    func indexIfNeeded(safeName: String, profileId: String) async {
        guard let idx = BookStore.loadIndex(safeName: safeName, profileId: profileId),
              idx.format == "pdf", idx.hasTextLayer == false else { return }
        let key = "\(profileId)/\(safeName)"
        guard !running.contains(key) else { return }
        running.insert(key)
        defer { running.remove(key) }

        let bookDir = BookStore.bookDir(safeName: safeName, profileId: profileId)
        let bookURL = bookDir.appendingPathComponent("book.pdf")
        guard let doc = PDFDocument(url: bookURL), doc.pageCount > 0 else { return }

        var all: [Int: [OCRStore.Line]] = [:]
        for page in 1...doc.pageCount {
            all[page] = await OCRStore.shared.pageLines(
                safeName: safeName, profileId: profileId, page: page, document: doc)
            if Task.isCancelled { return }
        }

        // 写回 tmp → 校验可开且页数一致 → 原子替换（防砸原书）
        let tmp = bookDir.appendingPathComponent("book-textlayer.tmp.pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try TextLayerWriter.write(document: doc, lines: all, to: tmp)
        } catch {
            return
        }
        guard let check = PDFDocument(url: tmp), check.pageCount == doc.pageCount,
              !(check.page(at: min(9, check.pageCount - 1))?.string ?? "").isEmpty
                || all.values.allSatisfy({ $0.isEmpty })
        else { return }
        guard (try? FileManager.default.replaceItemAt(bookURL, withItemAt: tmp)) != nil else { return }

        if var index = BookStore.loadIndex(safeName: safeName, profileId: profileId) {
            index.chapters = Self.writeChapterTexts(
                lines: all, chapters: index.chapters, pageCount: doc.pageCount,
                safeName: safeName, profileId: profileId)
            index.hasTextLayer = true
            index.updatedAt = Date()
            try? BookStore.saveIndex(index, safeName: safeName, profileId: profileId)
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .bookTextLayerReady, object: nil,
                                            userInfo: ["safeName": safeName])
        }
    }

    /// CR-7 P3：OCR 全书文本按章聚合成 chapters/chapter_NNNN.txt（NNNN=章起始页，
    /// 与 ChapterMeta.no 一致）——这本 PDF 在 AI 眼里从此是一本完整的书
    /// （聊天 fs 原语可翻任意章）。每页开头带 `[第 N 页]` 标记，AI 批注才知道
    /// 引用落在哪页（book-note 协议 chapter=页码）。
    /// 无 outline 的书按 25 页一段生成章节表（目录 sheet 顺手可用）。
    /// 返回更新后的章节表（chars 填真值）。
    static func writeChapterTexts(
        lines: [Int: [OCRStore.Line]], chapters: [BookStore.ChapterMeta], pageCount: Int,
        safeName: String, profileId: String
    ) -> [BookStore.ChapterMeta] {
        var metas = chapters.sorted { $0.no < $1.no }
        if metas.isEmpty {
            metas = stride(from: 1, through: pageCount, by: 25).map {
                BookStore.ChapterMeta(no: $0, title: "第 \($0)–\(min($0 + 24, pageCount)) 页", chars: 0)
            }
        }
        try? FileManager.default.createDirectory(
            at: BookStore.bookDir(safeName: safeName, profileId: profileId),
            withIntermediateDirectories: true)
        for (i, meta) in metas.enumerated() {
            let endPage = i + 1 < metas.count ? metas[i + 1].no - 1 : pageCount
            guard meta.no <= endPage else { continue }
            var text = ""
            for p in meta.no...endPage {
                let pageText = (lines[p] ?? []).map(\.text).joined(separator: "\n")
                text += "[第 \(p) 页]\n\(pageText)\n\n"
            }
            let url = BookStore.chapterURL(safeName: safeName, chapterNo: meta.no, profileId: profileId)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            metas[i].chars = text.count
        }
        return metas
    }
}

extension Notification.Name {
    /// 全书文本层就绪（重新打开该书后原生选字生效）。userInfo: safeName。
    static let bookTextLayerReady = Notification.Name("MemoryPalaceBookTextLayerReady")
}
