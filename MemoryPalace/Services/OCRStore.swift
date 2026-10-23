import Foundation
import PDFKit
import Vision

/// CR-7 P1.5：扫描版 PDF 的 OCR 页缓存。
/// 一页一文件 `books/{safe}/ocr/page-N.jsonl`，每行一个 {text, bbox}——
/// bbox 是 PDF 页坐标（cropBox 系、原点左下、单位 point），P2 批注锚定/渲染直接用。
/// actor 串行：accurate OCR ~5s/页是 CPU 重活，一次一页；同页并发请求去重等缓存。
/// 文字版 PDF（hasTextLayer=true）直接 PDFPage.string，不进这里。
actor OCRStore {
    static let shared = OCRStore()

    struct Line: Codable {
        let text: String
        let bbox: [Double]   // [x, y, w, h]
    }

    private var inFlight: Set<String> = []

    // MARK: - 读取（缓存优先，未命中现场 OCR）

    func pageLines(safeName: String, profileId: String, page: Int, document: PDFDocument) async -> [Line] {
        if let cached = Self.loadCache(safeName: safeName, profileId: profileId, page: page) {
            return cached
        }
        let key = "\(profileId)/\(safeName)/\(page)"
        while inFlight.contains(key) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let cached = Self.loadCache(safeName: safeName, profileId: profileId, page: page) {
                return cached
            }
        }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        guard let pdfPage = document.page(at: page - 1) else { return [] }
        let lines = await Self.recognize(page: pdfPage)
        Self.saveCache(lines, safeName: safeName, profileId: profileId, page: page)
        return lines
    }

    func pageText(safeName: String, profileId: String, page: Int, document: PDFDocument) async -> String {
        await pageLines(safeName: safeName, profileId: profileId, page: page, document: document)
            .map(\.text).joined(separator: "\n")
    }

    /// 当前页 ±radius 预热（调用方 fire-and-forget）。
    func prefetch(safeName: String, profileId: String, around page: Int, radius: Int = 2, document: PDFDocument) async {
        for p in (page - radius)...(page + radius) where p >= 1 && p <= document.pageCount && p != page {
            _ = await pageLines(safeName: safeName, profileId: profileId, page: p, document: document)
        }
    }

    // MARK: - 框选相交（P2 批注：用户框 → 命中行 → quote + 贴行 rects）

    /// 与框相交的 OCR 行（中心点或 ≥40% 面积落框内），按阅读序（y 降序，PDF 原点左下）。
    /// 返回 nil = 框内没字。
    static func selection(from lines: [Line], in box: CGRect) -> (quote: String, rects: [[Double]])? {
        let hit = lines.filter { line in
            guard line.bbox.count == 4 else { return false }
            let r = CGRect(x: line.bbox[0], y: line.bbox[1], width: line.bbox[2], height: line.bbox[3])
            guard r.width > 0, r.height > 0 else { return false }
            let inter = r.intersection(box)
            guard !inter.isNull else { return false }
            let coverage = (inter.width * inter.height) / (r.width * r.height)
            return coverage >= 0.4 || box.contains(CGPoint(x: r.midX, y: r.midY))
        }
        guard !hit.isEmpty else { return nil }
        let ordered = hit.sorted { $0.bbox[1] > $1.bbox[1] }
        return (ordered.map(\.text).joined(separator: "\n"), ordered.map(\.bbox))
    }

    // MARK: - Vision

    private static func recognize(page: PDFPage) async -> [Line] {
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0 else { return [] }
        return await Task.detached(priority: .utility) {
            let scale: CGFloat = 2.5
            let thumb = page.thumbnail(of: CGSize(width: crop.width * scale, height: crop.height * scale), for: .cropBox)
            #if os(iOS)
            guard let cg = thumb.cgImage else { return [] }
            #else
            var rect = CGRect(origin: .zero, size: thumb.size)
            guard let cg = thumb.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [] }
            #endif

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            guard (try? VNImageRequestHandler(cgImage: cg).perform([request])) != nil,
                  let observations = request.results else { return [] }

            return observations.compactMap { obs -> Line? in
                guard let top = obs.topCandidates(1).first else { return nil }
                let b = obs.boundingBox   // normalized，原点左下——换算 cropBox point 坐标
                return Line(text: top.string, bbox: [
                    Double(crop.origin.x + b.origin.x * crop.width),
                    Double(crop.origin.y + b.origin.y * crop.height),
                    Double(b.width * crop.width),
                    Double(b.height * crop.height),
                ])
            }
        }.value
    }

    // MARK: - 缓存

    static func cacheURL(safeName: String, profileId: String, page: Int) -> URL {
        BookStore.bookDir(safeName: safeName, profileId: profileId)
            .appendingPathComponent("ocr", isDirectory: true)
            .appendingPathComponent("page-\(page).jsonl")
    }

    /// 只读缓存（不触发 OCR）——AgentBookNoteWriter 锚定 / 章文本聚合用。
    static func cachedLines(safeName: String, profileId: String, page: Int) -> [Line]? {
        loadCache(safeName: safeName, profileId: profileId, page: page)
    }

    private static func loadCache(safeName: String, profileId: String, page: Int) -> [Line]? {
        guard let content = try? String(
            contentsOf: cacheURL(safeName: safeName, profileId: profileId, page: page), encoding: .utf8
        ) else { return nil }
        let decoder = JSONDecoder()
        return content.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(Line.self, from: Data($0.utf8)) }
    }

    private static func saveCache(_ lines: [Line], safeName: String, profileId: String, page: Int) {
        let url = cacheURL(safeName: safeName, profileId: profileId, page: page)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let body = lines.compactMap { line -> String? in
            guard let d = try? encoder.encode(line) else { return nil }
            return String(data: d, encoding: .utf8)
        }.joined(separator: "\n")
        try? (body + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
