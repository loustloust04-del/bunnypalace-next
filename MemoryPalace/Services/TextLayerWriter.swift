import Foundation
import PDFKit
import CoreText

/// CR-7「坨坨」路线：把 OCR 行写回 PDF 隐藏文本层（searchable PDF）。
/// 写回后 PDFKit 把它当真文本——原生长按选择把手 / 复制 / findString 全部成立，
/// 扫描书从此走文字版批注路线。
///
/// 做法（ocrmypdf 同款）：Core Graphics 逐页重写——drawPDFPage 原内容 +
/// invisible text rendering mode（Tr 3）按 bbox 画 OCR 行，水平缩放匹配行宽。
enum TextLayerWriter {

    /// lines: 页号(1-based) → OCR 行。写出到 outURL（调用方负责原子替换）。
    /// 没有 OCR 行的页原样复制。
    static func write(document: PDFDocument, lines: [Int: [OCRStore.Line]], to outURL: URL) throws {
        guard let consumer = CGDataConsumer(url: outURL as CFURL) else {
            throw NSError(domain: "TextLayerWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"])
        }
        var docBox = document.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &docBox, nil) else {
            throw NSError(domain: "TextLayerWriter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 PDF context"])
        }

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i), let pageRef = page.pageRef else { continue }
            var mediaBox = page.bounds(for: .mediaBox)
            ctx.beginPage(mediaBox: &mediaBox)
            ctx.saveGState()
            // 原页内容（含旋转/裁剪修正）
            ctx.concatenate(pageRef.getDrawingTransform(.mediaBox, rect: mediaBox, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(pageRef)
            ctx.restoreGState()

            guard let pageLines = lines[i + 1], !pageLines.isEmpty else {
                ctx.endPage()
                continue
            }
            ctx.saveGState()
            ctx.setTextDrawingMode(.invisible)
            for line in pageLines where line.bbox.count == 4 && !line.text.isEmpty {
                let h = line.bbox[3]
                guard h > 1 else { continue }
                let font = CTFontCreateWithName("PingFang SC" as CFString, h * 0.85, nil)
                let attr = NSAttributedString(string: line.text, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                ])
                let ctLine = CTLineCreateWithAttributedString(attr)
                let naturalWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                guard naturalWidth > 0 else { continue }
                // 水平缩放贴合 bbox 宽度——选择把手位置沿行均匀对齐
                let scaleX = line.bbox[2] / naturalWidth
                var descent: CGFloat = 0
                _ = CTLineGetTypographicBounds(ctLine, nil, &descent, nil)
                ctx.textMatrix = CGAffineTransform(scaleX: scaleX, y: 1)
                    .concatenating(CGAffineTransform(translationX: line.bbox[0],
                                                     y: line.bbox[1] + Double(descent)))
                CTLineDraw(ctLine, ctx)
            }
            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()
    }
}
