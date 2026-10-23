//
//  WideGlyphFit.swift
//
//  MP patch 1（记忆花园 #087）：两格宽字符（CJK、全角标点、emoji…）走 CoreText fallback 字体时，
//  fallback 字体和主字体同字号，汉字字宽 ≈ 1em，而两格 ≈ 1.24em（SF Mono 12pt：格宽 7.43、汉字 11.92），
//  上游把字形贴在两格左缘，每个字右边空出一截，中文看着一字一格散开。
//  这里按 Ghostty 的 ic_width 归一化：以 fallback 字体里「水」的字宽为准，把整套字体放大往两格填，
//  但最多放大到 `maxScale`（填满两格约 1.24 倍，粟粟 10-14 看着太大，定 1.03）；
//  上限还有格高（墨迹不出格、不撑大格子）；字体里没有「水」的（emoji 等）按这个字自己的字宽、至少按 1em 算。
//  字号放大后按「水」的字宽把字身框居中，同一字体的字在格子里位置一致（标点保持在字身框里原来的位置）。
//  一格里的组合字形（基字 + 组合符号，CoreText 常把符号拆成另一个 run、带竖向偏移）当一整块统一缩放，
//  保留 shaping 给的相对位置，限高按整块的墨迹（含每个字形的偏移）算。
//  主字体自己带的宽字形不放大（用户换了自带 CJK 的等宽字体时维持上游行为）。
//

#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreText
import CoreGraphics
#if os(iOS) || os(visionOS)
import UIKit
#else
import AppKit
#endif

enum WideGlyphFit {
    struct Placement: Equatable {
        /// 字号放大倍数（< 1 = 缩小以免出格）
        var scale: CGFloat
        /// 基字原点相对格子左缘的水平偏移（pt）
        var dx: CGFloat
    }

    /// 一格里的一个字形：相对基字原点的偏移（未缩放，CoreText 排出来的位置之差）
    struct ClusterGlyph {
        var font: CTFont
        var glyph: CGGlyph
        var offset: CGPoint
    }

    /// 参照字「水」U+6C34（Ghostty 量 ic_width 用的同一个字）
    static let referenceCharacter: UniChar = 0x6C34

    /// 字号最多放大的倍数（填满两格要 ≈1.24，太大；粟粟 10-14 定 1.03）
    static let maxScale: CGFloat = 1.03

    struct Metrics { let advance: CGFloat; let ink: CGRect }
    private static let lock = NSLock()
    private static var references: [String: Metrics?] = [:]
    private static var glyphMetrics: [String: Metrics] = [:]
    private static var scaledFonts: [String: CTFont] = [:]

    private static func key(_ font: CTFont, size: CGFloat) -> String {
        "\(CTFontCopyPostScriptName(font) as String)@\(Int((size * 100).rounded()))"
    }

    /// 字形的字宽和墨迹，按（字体名、字号、字形号）缓存：每帧重画不再重复量
    static func metrics(_ font: CTFont, glyph: CGGlyph) -> Metrics {
        let k = "\(key(font, size: CTFontGetSize(font)))#\(glyph)"
        lock.lock()
        if let cached = glyphMetrics[k] { lock.unlock(); return cached }
        lock.unlock()
        var g = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &advance, 1)
        var ink = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &ink, 1)
        let m = Metrics(advance: advance.width, ink: ink)
        lock.lock()
        if glyphMetrics.count > 8192 { glyphMetrics.removeAll(keepingCapacity: true) }
        glyphMetrics[k] = m
        lock.unlock()
        return m
    }

    /// 字体里「水」的字宽和墨迹；没有这个字返回 nil。按字体名 + 字号缓存
    private static func reference(_ font: CTFont) -> Metrics? {
        let k = key(font, size: CTFontGetSize(font))
        lock.lock()
        if let cached = references[k] { lock.unlock(); return cached }
        lock.unlock()
        var ch = referenceCharacter
        var glyph: CGGlyph = 0
        var ref: Metrics?
        if CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1), glyph != 0 {
            let m = metrics(font, glyph: glyph)
            if m.advance > 0 { ref = m }
        }
        lock.lock()
        references[k] = ref
        lock.unlock()
        return ref
    }

    /// 同一字体按倍数放大后的副本（字形号不变），按字体名 + 目标字号缓存
    static func scaledFont(_ font: CTFont, scale: CGFloat) -> CTFont {
        if scale == 1 { return font }
        let size = CTFontGetSize(font) * scale
        let k = key(font, size: size)
        lock.lock(); defer { lock.unlock() }
        if let cached = scaledFonts[k] { return cached }
        let scaled = CTFontCreateCopyWithAttributes(font, size, nil, nil)
        scaledFonts[k] = scaled
        return scaled
    }

    /// 单个字形（没有组合符号）的放法
    static func placement(font: CTFont, glyph: CGGlyph, columns: Int,
                          cellWidth: CGFloat, cellHeight: CGFloat, baselineFromBottom: CGFloat) -> Placement {
        placement(cluster: [ClusterGlyph(font: font, glyph: glyph, offset: .zero)], columns: columns,
                  cellWidth: cellWidth, cellHeight: cellHeight, baselineFromBottom: baselineFromBottom)
    }

    /// `columns` 格宽的槽里怎么放一整格字形（第一个是基字）。整块统一一个倍数，墨迹按各字形的偏移合起来限高、限宽。
    /// `baselineFromBottom` = 基线离格子底边的距离（上游 yOffset）
    static func placement(cluster: [ClusterGlyph], columns: Int,
                          cellWidth: CGFloat, cellHeight: CGFloat, baselineFromBottom: CGFloat) -> Placement {
        guard let base = cluster.first, columns >= 2, cellWidth > 0, cellHeight > 0 else { return Placement(scale: 1, dx: 0) }
        let slot = CGFloat(columns) * cellWidth
        let baseMetrics = metrics(base.font, glyph: base.glyph)
        let ref = reference(base.font)
        // 字身框宽：有「水」用它（整套字统一倍数、统一位置）；没有就用基字自己的字宽，至少 1em
        let box = ref?.advance ?? max(baseMetrics.advance, CTFontGetSize(base.font))
        guard box > 0 else { return Placement(scale: 1, dx: 0) }
        var scale = min(slot / box, maxScale)

        // 整块墨迹（未缩放，基字原点为原点）；参照字只管竖向
        var ink = CGRect.null
        for g in cluster {
            let r = metrics(g.font, glyph: g.glyph).ink
            guard r.width > 0 || r.height > 0 else { continue }
            ink = ink.union(r.offsetBy(dx: g.offset.x, dy: g.offset.y))
        }
        // 竖向：上沿 = 格高 − 基线高，下沿 = 基线下 baselineFromBottom
        let top = cellHeight - baselineFromBottom
        for r in [ref?.ink, ink.isNull ? nil : ink].compactMap({ $0 }) where r.height > 0 {
            if r.maxY > 0 { scale = min(scale, top / r.maxY) }
            if r.minY < 0, baselineFromBottom > 0 { scale = min(scale, baselineFromBottom / -r.minY) }
        }
        // 横向：字身框居中后，整块墨迹不能出槽。dx(s) = (slot - box*s)/2；左沿 dx + minX*s ≥ 0，右沿 dx + maxX*s ≤ slot
        if !ink.isNull, ink.width > 0 {
            let left = box - 2 * ink.minX
            if left > 0 { scale = min(scale, slot / left) }
            let right = 2 * ink.maxX - box
            if right > 0 { scale = min(scale, slot / right) }
        }
        scale = max(0.1, scale)
        return Placement(scale: scale, dx: (slot - box * scale) / 2)
    }

    /// 一个字形该怎么画：用哪个字体（可能是放大副本）、画在哪（相对段落起点 / 基线，pt）
    struct DrawItem {
        var font: CTFont
        var glyph: CGGlyph
        /// 相对「段首格子左缘、基线」的位置
        var point: CGPoint
        /// 给下划线等属性用：所在格子左缘（同上游，基线 + CoreText 的竖向偏移）
        var attributePoint: CGPoint
    }

    /// 把一个两格宽段落的所有 run 排好：按字符串下标认格子（组合符号跟着它前面的基字），每格统一缩放。
    /// 返回值与 runs 一一对应。`isPrimary`：主字体那一套不放大
    static func layout(runs: [CTRun], string: String, columns: Int, cellWidth: CGFloat, cellHeight: CGFloat,
                       baselineFromBottom: CGFloat, isPrimary: (CTFont) -> Bool) -> [[DrawItem]] {
        // UTF-16 下标 → 第几格（每个 Character 一格）
        var cellAt: [Int: Int] = [:]
        var offset = 0
        for (k, ch) in string.enumerated() {
            cellAt[offset] = k
            offset += ch.utf16.count
        }
        struct Raw { let run: Int; let font: CTFont; let glyph: CGGlyph; let position: CGPoint; let cell: Int; let isBase: Bool }
        var raws: [Raw] = []
        var currentCell = 0
        for (r, run) in runs.enumerated() {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            let font = ((CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            var positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetPositions(run, CFRange(), &positions)
            var indices = [CFIndex](repeating: 0, count: n)
            CTRunGetStringIndices(run, CFRange(), &indices)
            for i in 0..<n {
                let base = cellAt[indices[i]]
                if let base { currentCell = base }
                raws.append(Raw(run: r, font: font, glyph: glyphs[i], position: positions[i], cell: currentCell, isBase: base != nil))
            }
        }
        // 每格：基字原点 + 整块放法
        var placements: [Int: (origin: CGPoint, fit: Placement, primary: Bool)] = [:]
        var byCell: [Int: [Raw]] = [:]
        for raw in raws { byCell[raw.cell, default: []].append(raw) }
        for (cell, glyphs) in byCell {
            let baseIndex = glyphs.firstIndex(where: { $0.isBase }) ?? 0
            let base = glyphs[baseIndex]
            let primary = isPrimary(base.font)
            // 基字排第一；偏移 = 相对基字的横向差 + CoreText 给的竖向偏移
            let ordered = [base] + glyphs.enumerated().filter { $0.offset != baseIndex }.map(\.element)
            let cluster = ordered.map { ClusterGlyph(font: $0.font, glyph: $0.glyph,
                                                     offset: CGPoint(x: $0.position.x - base.position.x, y: $0.position.y)) }
            let fit = primary ? Placement(scale: 1, dx: 0)
                : placement(cluster: cluster, columns: columns, cellWidth: cellWidth, cellHeight: cellHeight,
                            baselineFromBottom: baselineFromBottom)
            placements[cell] = (CGPoint(x: base.position.x, y: 0), fit, primary)
        }
        var out = [[DrawItem]](repeating: [], count: runs.count)
        for raw in raws {
            guard let p = placements[raw.cell] else { continue }
            let cellLeft = CGFloat(raw.cell * columns) * cellWidth
            let rel = CGPoint(x: raw.position.x - p.origin.x, y: raw.position.y)
            let font = p.primary ? raw.font : scaledFont(raw.font, scale: p.fit.scale)
            out[raw.run].append(DrawItem(
                font: font, glyph: raw.glyph,
                point: CGPoint(x: cellLeft + p.fit.dx + rel.x * p.fit.scale, y: rel.y * p.fit.scale),
                attributePoint: CGPoint(x: cellLeft, y: raw.position.y)))
        }
        return out
    }
}

extension TerminalView {
    /// 这个 run 的字体是不是主字体那一套（主字体自带的宽字形不动）
    func isPrimaryFont(_ font: CTFont) -> Bool {
        let name = CTFontCopyPostScriptName(font) as String
        for f in [fontSet.normal, fontSet.bold, fontSet.italic, fontSet.boldItalic] {
            if (CTFontCopyPostScriptName(f as CTFont) as String) == name { return true }
        }
        return false
    }

    /// 两格宽段落的排法（见 WideGlyphFit.layout）
    func wideSegmentLayout(runs: [CTRun], string: String, columns: Int, baselineFromBottom: CGFloat) -> [[WideGlyphFit.DrawItem]] {
        WideGlyphFit.layout(runs: runs, string: string, columns: columns,
                            cellWidth: cellDimension.width, cellHeight: cellDimension.height,
                            baselineFromBottom: baselineFromBottom, isPrimary: isPrimaryFont)
    }

    /// 按排好的位置画（origin = 段首格子左缘、基线）
    func drawWideItems(_ items: [WideGlyphFit.DrawItem], origin: CGPoint, in context: CGContext) {
        for item in items {
            var g = item.glyph
            var p = CGPoint(x: origin.x + item.point.x, y: origin.y + item.point.y)
            CTFontDrawGlyphs(item.font, &g, &p, 1, context)
        }
    }
}
#endif
