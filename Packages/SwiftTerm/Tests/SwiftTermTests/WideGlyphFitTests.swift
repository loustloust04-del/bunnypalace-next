//
//  WideGlyphFitTests.swift
//
//  MP patch 1（#087）：两格宽 fallback 字形填满两格、不出格、不撑大格子。
//  macOS 上跑（iOS 走同一份 AppleTerminalView / WideGlyphFit），字体用 iOS 终端的默认：monospacedSystemFont 12pt。
//
#if os(macOS)
import AppKit
import CoreText
import Testing

@testable import SwiftTerm

@Suite(.serialized)
final class WideGlyphFitTests {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeView(cols: Int, rows: Int = 3) -> TerminalView {
        let probe = TerminalView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        probe.font = font
        let cell = probe.cellDimension!
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height))
        view.font = font
        view.nativeForegroundColor = .black
        view.nativeBackgroundColor = .white
        return view
    }

    /// 宽字符在每一行里的 run：(字体, 字形, 列宽)
    func wideRuns(_ text: String, view: TerminalView) -> [(CTFont, CGGlyph)] {
        var out: [(CTFont, CGGlyph)] = []
        for bold in [false, true] {
            let f = bold ? view.fontSet.bold : view.fontSet.normal
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: f]))
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                if view.isPrimaryFont(runFont) { continue }
                let n = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: n)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                out += glyphs.map { (runFont, $0) }
            }
        }
        return out
    }

    @Test func referenceIdeographCappedAndCentered() throws {
        let view = makeView(cols: 20)
        let cell = view.cellDimension!
        let baseline = ceil(CTFontGetDescent(view.fontSet.normal) + CTFontGetLeading(view.fontSet.normal))
        for (runFont, glyph) in wideRuns("水", view: view) {
            var g = glyph
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(runFont, .horizontal, &g, &advance, 1)
            let fit = WideGlyphFit.placement(font: runFont, glyph: glyph, columns: 2, cellWidth: cell.width,
                                             cellHeight: cell.height, baselineFromBottom: baseline)
            // 原样：字宽 ≈ 1em，两格多出 2pt 以上（这就是「拉」的来源）
            #expect(2 * cell.width - advance.width > 2)
            // 放大封顶 maxScale（填满两格太大），字身框在两格里居中
            #expect(abs(fit.scale - WideGlyphFit.maxScale) < 0.001, "\(CTFontCopyPostScriptName(runFont)) scale=\(fit.scale)")
            #expect(abs(fit.dx - (2 * cell.width - advance.width * fit.scale) / 2) < 0.001)
        }
    }

    @Test func wideGlyphsStayInsideTheirSlot() {
        let view = makeView(cols: 20)
        let cell = view.cellDimension!
        let baseline = ceil(CTFontGetDescent(view.fontSet.normal) + CTFontGetLeading(view.fontSet.normal))
        let slot = 2 * cell.width
        // 汉字（含粗体）、全角标点、假名、谚文、长音、emoji、符号
        let runs = wideRuns("水图存好了，。、「」『』（）！？ー한글あア😀✅⚠️🀄", view: view)
        #expect(runs.count >= 20)
        for (runFont, glyph) in runs {
            var g = glyph
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(runFont, .horizontal, &g, &advance, 1)
            var ink = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(runFont, .horizontal, &g, &ink, 1)
            let fit = WideGlyphFit.placement(font: runFont, glyph: glyph, columns: 2, cellWidth: cell.width,
                                             cellHeight: cell.height, baselineFromBottom: baseline)
            let name = CTFontCopyPostScriptName(runFont) as String
            guard ink.width > 0 else { continue }
            #expect(fit.dx + ink.minX * fit.scale >= -0.01, "\(name) glyph \(glyph) 左出格")
            #expect(fit.dx + ink.maxX * fit.scale <= slot + 0.01, "\(name) glyph \(glyph) 右出格")
            #expect(ink.maxY * fit.scale <= cell.height - baseline + 0.01, "\(name) glyph \(glyph) 顶出格")
            #expect(ink.minY * fit.scale >= -baseline - 0.01, "\(name) glyph \(glyph) 底出格")
        }
    }

    @Test func cellSizeIsUnchanged() {
        let view = makeView(cols: 20)
        let f = view.fontSet.normal
        let scale = view.backingScaleFactor()
        let expectedHeight = ceil(ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)) * scale) / scale
        #expect(view.cellDimension.height == expectedHeight)
        view.feed(text: "图存好了，😀")
        #expect(view.cellDimension.height == expectedHeight)
    }

    // MARK: 真画一遍（drawTerminalContents → 位图），量墨迹

    struct Ink { var minX: Int; var maxX: Int; var minY: Int; var maxY: Int; var count: Int }

    /// 把第 0 行画进位图，返回每个两格槽里的墨迹（像素，1x）
    func render(_ view: TerminalView, slots: [Int]) -> [Ink?] {
        let w = Int(view.bounds.width.rounded(.up)), h = Int(view.bounds.height.rounded(.up))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        view.drawTerminalContents(dirtyRect: view.bounds, context: ctx, bufferOffset: view.terminal.displayBuffer.yDisp)
        NSGraphicsContext.restoreGraphicsState()
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let cell = view.cellDimension!
        return slots.map { col in
            let x0 = Int((CGFloat(col) * cell.width).rounded(.down)) - 3
            let x1 = Int((CGFloat(col + 2) * cell.width).rounded(.up)) + 3
            var ink: Ink?
            // 位图第 0 行在上（CGContext 内存自上而下），终端第 0 行在顶上那一格
            for y in 0..<Int(cell.height.rounded(.up)) {
                for x in max(0, x0)..<min(w, x1) where data[(y * w + x) * 4 + 3] > 40 && data[(y * w + x) * 4] < 128 {   // 黑字算墨迹（默认底色的 run 会被涂白）
                    if var i = ink {
                        i.minX = min(i.minX, x); i.maxX = max(i.maxX, x); i.minY = min(i.minY, y); i.maxY = max(i.maxY, y); i.count += 1
                        ink = i
                    } else { ink = Ink(minX: x, maxX: x, minY: y, maxY: y, count: 1) }
                }
            }
            return ink
        }
    }

    /// 只放一个宽字符（其余是空格）画出来量墨迹，免得量到邻居
    func isolatedInk(_ ch: String, col: Int, cols: Int) throws -> Ink {
        let view = makeView(cols: cols)
        view.feed(text: String(repeating: " ", count: col) + ch)
        return try #require(render(view, slots: [col])[0])
    }

    @Test func renderedChineseIsCenteredAndUnclipped() throws {
        let cell = makeView(cols: 12).cellDimension!
        let chars = ["图", "存", "好", "了"]
        let boxes = try chars.enumerated().map { try isolatedInk($0.element, col: 2 * $0.offset, cols: 12) }
        for (i, box) in boxes.enumerated() {
            // 不出自己的两格（像素取整留 1px）
            #expect(CGFloat(box.minX) >= CGFloat(2 * i) * cell.width - 1)
            #expect(CGFloat(box.maxX) <= CGFloat(2 * i + 2) * cell.width + 1)
        }
        // 字在两格里居中（上游贴左缘：左边几乎没空、右边空一大截，中文一字一格散开）。
        // 字号封顶 1.03 后字间空隙随字形宽窄在 0.35～0.5 之间，不再按比例卡
        for (i, box) in boxes.enumerated() {
            let left = CGFloat(box.minX) - CGFloat(2 * i) * cell.width
            let right = CGFloat(2 * i + 2) * cell.width - CGFloat(box.maxX + 1)
            let width = CGFloat(box.maxX - box.minX + 1)
            #expect(abs(left - right) <= max(2, 0.15 * width), "「\(chars[i])」左空 \(left)px 右空 \(right)px")
        }
        for i in 1..<boxes.count {
            let gap = CGFloat(boxes[i].minX - boxes[i - 1].maxX - 1)
            #expect(gap >= 1, "「\(chars[i - 1])\(chars[i])」贴在一起了")
        }
    }

    @Test func wideCharacterAtLineEndIsNotClipped() throws {
        // 11 格：「图」落在第 9、10 格（行尾），画布正好 11 格宽
        let view = makeView(cols: 11)
        view.feed(text: String(repeating: " ", count: 9) + "图")
        #expect(view.terminal.getCharacter(col: 9, row: 0) == "图")
        let atEnd = try isolatedInk("图", col: 9, cols: 11)
        let inMiddle = try isolatedInk("图", col: 3, cols: 11)
        // 行尾那个字的墨迹宽度和放在中间的一样（亚像素位置不同，允许 1px）：没被画布右边裁掉
        #expect(abs((atEnd.maxX - atEnd.minX) - (inMiddle.maxX - inMiddle.minX)) <= 1)
        #expect(CGFloat(atEnd.maxX) < view.bounds.width - 0.5)
    }

    /// 整张位图里所有黑字像素的外框（像素，1x，y 自上而下）
    func inkBounds(_ view: TerminalView) -> Ink? {
        let w = Int(view.bounds.width.rounded(.up)), h = Int(view.bounds.height.rounded(.up))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        view.drawTerminalContents(dirtyRect: view.bounds, context: ctx, bufferOffset: view.terminal.displayBuffer.yDisp)
        NSGraphicsContext.restoreGraphicsState()
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var ink: Ink?
        for y in 0..<h {
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 40 && data[(y * w + x) * 4] < 128 {
                if var i = ink {
                    i.minX = min(i.minX, x); i.maxX = max(i.maxX, x); i.minY = min(i.minY, y); i.maxY = max(i.maxY, y); i.count += 1
                    ink = i
                } else { ink = Ink(minX: x, maxX: x, minY: y, maxY: y, count: 1) }
            }
        }
        return ink
    }

    /// sol 审 #1：「水̄」—— CoreText 把组合横线拆成另一个 run、带竖向偏移；整格要统一缩放、横线不能越过格顶、不能跑到下一格
    @Test func combiningMarkScalesWithBaseAndStaysInCell() throws {
        for text in ["\u{6C34}\u{0304}", "\u{56FE}\u{20DD}", "\u{3042}\u{3099}"] {
            let view = makeView(cols: 8, rows: 3)
            view.feed(text: "\r\n  " + text)     // 第 1 行、第 2–3 格，上下左右都留空，越界的墨迹看得见
            let cell = view.cellDimension!
            let box = try #require(inkBounds(view), "\(text) 没画出来")
            #expect(CGFloat(box.minY) >= cell.height - 1, "\(text) 顶出格：minY=\(box.minY) 格顶=\(cell.height)")
            #expect(CGFloat(box.maxY) <= 2 * cell.height + 1, "\(text) 底出格")
            #expect(CGFloat(box.minX) >= 2 * cell.width - 1, "\(text) 左出槽")
            #expect(CGFloat(box.maxX) <= 4 * cell.width + 1, "\(text) 右出槽（组合符号跑到下一格）")
        }
    }

    @Test func glyphMetricsAreCached() {
        let view = makeView(cols: 4)
        let runs = wideRuns("水", view: view)
        let (font, glyph) = runs[0]
        let a = WideGlyphFit.metrics(font, glyph: glyph)
        let b = WideGlyphFit.metrics(font, glyph: glyph)
        #expect(a.advance == b.advance && a.ink == b.ink)
        // 换字号是另一条缓存（系统字体有光学尺寸，不一定正好两倍，跟直接量的比）
        let bigger = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * 2, nil, nil)
        var g = glyph
        var direct = CGSize.zero
        CTFontGetAdvancesForGlyphs(bigger, .horizontal, &g, &direct, 1)
        #expect(WideGlyphFit.metrics(bigger, glyph: glyph).advance == direct.width)
        #expect(direct.width != a.advance)
    }

    /// sol 审 #1 的算术那一半：组合横线自带竖向偏移，整格放大后（偏移也跟着放大）仍不越格顶
    @Test func clusterVerticalLimitCountsGlyphOffsets() throws {
        let view = makeView(cols: 4)
        let cell = view.cellDimension!
        let baseline = ceil(CTFontGetDescent(view.fontSet.normal) + CTFontGetLeading(view.fontSet.normal))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{6C34}\u{0304}", attributes: [.font: view.fontSet.normal]))
        var cluster: [WideGlyphFit.ClusterGlyph] = []
        var baseX: CGFloat?
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n); CTRunGetGlyphs(run, CFRange(), &glyphs)
            var pos = [CGPoint](repeating: .zero, count: n); CTRunGetPositions(run, CFRange(), &pos)
            for i in 0..<n {
                if baseX == nil { baseX = pos[i].x }
                cluster.append(.init(font: font, glyph: glyphs[i], offset: CGPoint(x: pos[i].x - baseX!, y: pos[i].y)))
            }
        }
        #expect(cluster.count == 2)
        #expect(cluster[1].offset.y > 0)   // CoreText 给横线的竖向偏移
        let fit = WideGlyphFit.placement(cluster: cluster, columns: 2, cellWidth: cell.width,
                                         cellHeight: cell.height, baselineFromBottom: baseline)
        for g in cluster {
            let ink = WideGlyphFit.metrics(g.font, glyph: g.glyph).ink
            #expect((ink.maxY + g.offset.y) * fit.scale <= cell.height - baseline + 0.01)
            #expect(fit.dx + (ink.minX + g.offset.x) * fit.scale >= -0.01)
            #expect(fit.dx + (ink.maxX + g.offset.x) * fit.scale <= 2 * cell.width + 0.01)
        }
    }
}
#endif
