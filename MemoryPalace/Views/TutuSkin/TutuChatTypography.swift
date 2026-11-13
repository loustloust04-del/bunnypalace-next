#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreText
import CoreGraphics
import NaturalLanguage

struct TutuChatGlyph: Equatable {
    var text: String
    var fontName: String
    var fontSize: CGFloat
    var origin: CGPoint
    var bounds: CGRect
    var isAction: Bool
}

struct TutuChatCardLayout {
    var size: CGSize
    var glyphs: [TutuChatGlyph]
    var right: CGFloat
    var hasAction: Bool
    var textOffset: CGFloat = 0
    var motif: CGRect? = nil
}

enum TutuChatTypography {
    static let serif = "NotoSerifSC-Medium"
    static let latin = "CormorantGaramond-Medium"
    private static let serifDescriptor = cardFontDescriptor(primary: serif, fallback: latin)
    private static let latinDescriptor = cardFontDescriptor(primary: latin, fallback: serif)
    private static let close = "，。、；：？！）》」』〉】〕…～·”’,.;:?!)]}%"
    private static let open = "（《「『〈【〔“‘([{"
    private static let cjk = try! NSRegularExpression(pattern: "[⺀-⿿　-〿぀-ヿ㐀-䶿一-鿿豈-﫿︰-﹏＀-￯]")
    private static let pictographic = try! NSRegularExpression(pattern: "\\p{Extended_Pictographic}")
    private static let emojiOnly = try! NSRegularExpression(pattern: "^[\\p{Extended_Pictographic}‍️\\s]+$")

    static func registerFonts(resourceURL: URL) throws {
        for name in [serif, latin] {
            let url = resourceURL.appendingPathComponent("fonts/\(name).ttf")
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
                if code != CTFontManagerError.alreadyRegistered.rawValue { throw TutuChatError.font(url) }
            }
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    private static func isCJK(_ text: String) -> Bool { matches(cjk, text) }
    private static func cardFontDescriptor(primary: String, fallback: String) -> CTFontDescriptor {
        let fallbackDescriptor = CTFontDescriptorCreateWithNameAndSize(fallback as CFString, 0)
        return CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: primary,
            kCTFontCascadeListAttribute: [fallbackDescriptor]
        ] as CFDictionary)
    }
    private static func font(name: String, size: CGFloat) -> CTFont {
        if name == serif { return CTFontCreateWithFontDescriptor(serifDescriptor, size, nil) }
        if name == latin { return CTFontCreateWithFontDescriptor(latinDescriptor, size, nil) }
        return CTFontCreateWithName(name as CFString, size, nil)
    }
    fileprivate static func line(_ text: String, name: String, size: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(name: name, size: size),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]))
    }
    private static func width(_ text: String, _ type: TypeStyle) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, name: type.name, size: type.size), nil, nil, nil))
    }
    static func canvasFontMetrics(_ font: CTFont) -> (ascent: CGFloat, descent: CGFloat) {
        // Blink FontMetrics::AscentDescentWithHacks rounds the platform font's
        // ascent/descent in CSS-pixel space before Canvas measureText exposes
        // fontBoundingBoxAscent/Descent. Keep ink bounds and advances fractional.
        // https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/platform/fonts/font_metrics.cc
        (floor(CTFontGetAscent(font) + 0.5), floor(CTFontGetDescent(font) + 0.5))
    }
    private struct TypeStyle {
        let name: String
        let size: CGFloat
        let lh: CGFloat
        let track: CGFloat
        let upper: Bool
        let mb: CGFloat
        var space: CGFloat { TutuChatTypography.width(" ", self) + track }
    }
    private static let say = TypeStyle(name: latin, size: 18, lh: 23.4, track: 0, upper: false, mb: 0)
    private static let sayZh = TypeStyle(name: serif, size: 15.5, lh: 25, track: 0.62, upper: false, mb: 0)
    private static let act = TypeStyle(name: latin, size: 10.5, lh: 14, track: 1.5, upper: true, mb: 7)
    private static let actZh = TypeStyle(name: serif, size: 12, lh: 18, track: 0.72, upper: false, mb: 6)
    private struct Token {
        var s: String
        var space: Bool
        var cjk: Bool
        var i: Int
        var w: CGFloat = 0
    }
    private struct Group {
        var toks: [Token]
        var w: CGFloat
        var space: Bool
    }
    private struct TextLine {
        var pieces: [(text: String, x: CGFloat)]
        var w: CGFloat
    }
    private static func wordStarts(_ text: String) -> Set<Int> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.simplifiedChinese)
        var starts: Set<Int> = [0]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            starts.insert(text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.lowerBound))
            // Intl.Segmenter also emits punctuation and intervening whitespace.
            starts.insert(text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.upperBound))
            return true
        }
        for (i, scalar) in text.unicodeScalars.enumerated() {
            let s = String(scalar)
            if close.contains(s) || open.contains(s) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                starts.insert(i); starts.insert(i + 1)
            }
        }
        return starts
    }
    private static func breakLines(_ text: String, _ ty: TypeStyle, _ maxW: CGFloat, _ balance: Bool) -> [TextLine] {
        var tokens: [Token] = [], current: Int?, space = false
        for (i, scalar) in text.unicodeScalars.enumerated() {
            let ch = String(scalar)
            if scalar.value == 0xA0 {
                if let j = current, !tokens[j].cjk { tokens[j].s += ch }
                else { tokens.append(Token(s: ch, space: space, cjk: false, i: i)); current = tokens.count - 1 }
                space = false; continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { current = nil; space = true; continue }
            let zh = isCJK(ch) || matches(pictographic, ch)
            if zh { tokens.append(Token(s: ch, space: space, cjk: true, i: i)); current = nil }
            else if let j = current, !tokens[j].cjk { tokens[j].s += ch }
            else { tokens.append(Token(s: ch, space: space, cjk: false, i: i)); current = tokens.count - 1 }
            space = false
        }
        var groups: [Group] = []
        for var t in tokens {
            t.w = width(t.s, ty) + ty.track * CGFloat(t.s.unicodeScalars.count)
            if let g = groups.last, !t.space,
               close.contains(String(t.s.unicodeScalars.first!)) || open.contains(String(g.toks.last!.s.unicodeScalars.last!)) {
                groups[groups.count - 1].toks.append(t); groups[groups.count - 1].w += t.w
            } else { groups.append(Group(toks: [t], w: t.w, space: t.space)) }
        }
        guard !groups.isEmpty else { return [] }
        let gap = ty.space
        func widthOf(_ indices: Range<Int>) -> CGFloat {
            indices.reduce(CGFloat(0)) { $0 + ($1 > indices.lowerBound && groups[$1].space ? gap : 0) + groups[$1].w }
        }
        func fill(_ limit: CGFloat) -> [Range<Int>] {
            var result: [Range<Int>] = [], start = 0, x: CGFloat = 0
            for k in groups.indices {
                var add = (k > start && groups[k].space ? gap : 0) + groups[k].w
                if k > start && x + add > limit + 0.01 { result.append(start..<k); start = k; x = 0; add = groups[k].w }
                x += add
            }
            result.append(start..<groups.count); return result
        }
        var ranges: [Range<Int>]
        if isCJK(text) {
            ranges = setZh(groups, ty, maxW, wordStarts(text))
        } else {
            ranges = fill(maxW)
            if balance && ranges.count > 1 {
                var lo = maxW / CGFloat(ranges.count) * 0.8, hi = maxW
                let n = ranges.count
                for _ in 0..<14 { let mid = (lo + hi) / 2; if fill(mid).count > n { lo = mid } else { hi = mid } }
                ranges = fill(hi)
            } else if ranges.count == 2 {
                var bestK = -1, bestC: CGFloat = 1e9
                for k in 1..<groups.count {
                    let a = widthOf(0..<k), b = widthOf(k..<groups.count)
                    if a > maxW + 0.01 || b > maxW + 0.01 { continue }
                    let end = String(groups[k - 1].toks.last!.s.unicodeScalars.last!)
                    let cost = abs(a - b) - (",.;:!?—".contains(end) ? maxW * 0.3 : 0) + (b > a ? maxW * 0.05 : 0)
                    if cost < bestC { bestC = cost; bestK = k }
                }
                if bestK > 0 { ranges = [0..<bestK, bestK..<groups.count] }
            } else if ranges.count > 1 {
                for _ in 0..<4 {
                    let last = ranges[ranges.count - 1], prev = ranges[ranges.count - 2]
                    let weight = last.reduce(0) { $0 + (groups[$1].toks[0].cjk ? groups[$1].toks.count : 2) }
                    if weight >= 3 || prev.count < 3 { break }
                    if widthOf((prev.upperBound - 1)..<last.upperBound) > maxW { break }
                    ranges[ranges.count - 2] = prev.lowerBound..<(prev.upperBound - 1)
                    ranges[ranges.count - 1] = (last.lowerBound - 1)..<last.upperBound
                }
            }
        }
        return ranges.map { range in
            var x: CGFloat = 0, pieces: [(String, CGFloat)] = []
            for k in range {
                if k > range.lowerBound && groups[k].space { x += gap }
                for t in groups[k].toks { pieces.append((t.s, x)); x += t.w }
            }
            let t = groups[range.upperBound - 1].toks.last!
            let hang: CGFloat = isCJK(text) && t.cjk && close.contains(t.s) ? ty.size * 0.5 : 0
            return TextLine(pieces: pieces, w: x - hang)
        }
    }
    private static func setZh(_ groups: [Group], _ ty: TypeStyle, _ maxW: CGFloat, _ starts: Set<Int>) -> [Range<Int>] {
        let n = groups.count, gap = ty.space
        func brk(_ k: Int) -> CGFloat {
            let a = groups[k - 1].toks.last!, b = groups[k].toks[0]
            if a.cjk && close.contains(a.s) { return -20 }
            if a.cjk && b.cjk && !starts.contains(b.i) { return 250 }
            if k >= 2 && groups[k - 1].toks.count == 1 && a.cjk && close.contains(groups[k - 2].toks.last!.s) { return 150 }
            return 0
        }
        func cost(_ a: Int, _ b: Int, _ last: Bool) -> CGFloat {
            var w: CGFloat = 0
            for k in a..<b { w += (k > a && groups[k].space ? gap : 0) + groups[k].w }
            let t = groups[b - 1].toks.last!
            let hang = t.cjk && close.contains(t.s) ? ty.size * 0.5 : 0
            if w - hang > maxW + 0.01 { return b - a > 1 ? .infinity : 1e6 }
            if last {
                var chars = 0
                for k in a..<b { for t in groups[k].toks { chars += !t.cjk ? 2 : (!close.contains(t.s) && !open.contains(t.s) ? 1 : 0) } }
                return chars <= 1 ? 2000 : chars == 2 ? 40 : 0
            }
            let r = (maxW - (w - hang)) / ty.size
            return 10 * r * r
        }
        var best = [CGFloat](repeating: .infinity, count: n + 1), from = [Int](repeating: 0, count: n + 1)
        best[0] = 0
        for j in 1...n {
            for i in stride(from: j - 1, through: 0, by: -1) {
                var c = cost(i, j, j == n)
                if c == .infinity { break }
                c += best[i] + 30 + (i > 0 ? brk(i) : 0)
                if c < best[j] { best[j] = c; from[j] = i }
            }
        }
        var result: [Range<Int>] = [], j = n
        while j > 0 { result.append(from[j]..<j); j = from[j] }
        return result.reversed()
    }

    static func card(action: String, say text: String) -> TutuChatCardLayout {
        TutuChatRenderTrace.emit("coretext.layout.begin")
        defer { TutuChatRenderTrace.emit("coretext.layout.end") }
        var glyphs: [TutuChatGlyph] = [], y: CGFloat = 16, right: CGFloat = 0
        func put(_ text: String, _ ty: TypeStyle, _ action: Bool) {
            let font = font(name: ty.name, size: ty.size)
            let metrics = canvasFontMetrics(font)
            let lines = breakLines(ty.upper ? text.uppercased() : text, ty, 220, action)
            for ln in lines {
                let baseline = y + ty.lh / 2 + (metrics.ascent - metrics.descent) / 2
                for piece in ln.pieces {
                    var x = 24 + piece.x
                    let parts = ty.track > 0.2 ? piece.text.unicodeScalars.map(String.init) : [piece.text]
                    for part in parts {
                        let ct = line(part, name: ty.name, size: ty.size)
                        let ink = CTLineGetBoundsWithOptions(ct, .useGlyphPathBounds)
                        let bounds = CGRect(x: x + ink.minX, y: baseline - ink.maxY, width: ink.width, height: ink.height)
                        glyphs.append(TutuChatGlyph(text: part, fontName: ty.name, fontSize: ty.size,
                                                   origin: CGPoint(x: x, y: baseline), bounds: bounds, isAction: action))
                        x += width(part, ty) + ty.track
                    }
                }
                if !action { right = max(right, 24 + ln.w) }
                y += ty.lh
            }
            y += ty.mb
        }
        if !action.isEmpty { put(action, isCJK(action) ? actZh : act, true) }
        if !text.isEmpty { put(text, isCJK(text) ? sayZh : say, false) }
        else { y -= (isCJK(action) ? actZh : act).mb }
        return TutuChatCardLayout(size: CGSize(width: 268, height: y + 16), glyphs: glyphs, right: right, hasAction: !action.isEmpty)
    }

    static func felt(text: String) -> (size: CGSize, emoji: Bool) {
        let layout = feltTextLayout(text: text)
        return (layout.size, layout.emoji)
    }

    static func feltTextLayout(text: String) -> (size: CGSize, emoji: Bool, lines: [String]) {
        TutuChatRenderTrace.emit("coretext.felt.begin")
        defer { TutuChatRenderTrace.emit("coretext.felt.end") }
        if matches(emojiOnly, text) { return (CGSize(width: 48, height: 42), true, [text]) }
        let zh = isCJK(text)
        let ty = TypeStyle(name: "PingFangSC-Regular", size: 15.5, lh: zh ? 25 : 15.5 * 1.45, track: zh ? 0.62 : 0, upper: false, mb: 0)
        // CSS keeps segmented Chinese words in nowrap spans. Other text uses
        // ordinary whitespace opportunities and overflow-wrap:anywhere.
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text; tokenizer.setLanguage(.simplifiedChinese)
        var spans: [String] = []
        if zh {
            var cursor = text.startIndex
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
                if cursor < r.lowerBound { spans += text[cursor..<r.lowerBound].unicodeScalars.map(String.init) }
                spans.append(String(text[r])); cursor = r.upperBound; return true
            }
            if cursor < text.endIndex { spans += text[cursor...].unicodeScalars.map(String.init) }
        } else {
            var word = ""
            for scalar in text.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { if !word.isEmpty { spans.append(word); word = "" }; spans.append(" ") }
                else { word += String(scalar) }
            }
            if !word.isEmpty { spans.append(word) }
        }
        func measure(_ outer: CGFloat, collectLines: Bool = false) -> (width: CGFloat, lines: Int, text: [String]) {
            let inner = max(0, outer - 32)
            var x: CGFloat = 0, widest: CGFloat = 0, rows = 1, pendingSpace = false
            var line = "", rendered: [String] = []
            func append(_ w: CGFloat, _ piece: String) {
                let gap = x > 0 && pendingSpace ? ty.space : 0
                if x > 0 && x + gap + w > inner + 0.01 {
                    widest = max(widest, x); rows += 1; x = w
                    if collectLines { rendered.append(line); line = piece }
                } else {
                    if collectLines { if gap > 0 { line += " " }; line += piece }
                    x += gap + w
                }
                pendingSpace = false
            }
            for span in spans {
                if span.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { pendingSpace = true; continue }
                let w = width(span, ty) + ty.track * CGFloat(span.unicodeScalars.count)
                if !zh && w > inner {
                    for scalar in span.unicodeScalars { append(width(String(scalar), ty), String(scalar)) }
                } else { append(w, span) }
            }
            if collectLines { rendered.append(line) }
            return (max(widest, x) + 32, rows, rendered)
        }
        let natural = measure(246)
        var outer = min(246, natural.width)
        let height = CGFloat(natural.lines) * ty.lh + 20
        if height.rounded() >= 44 {
            var lo: CGFloat = 48, hi = outer
            for _ in 0..<9 { let mid = (lo + hi) / 2; if measure(mid).lines > natural.lines { lo = mid } else { hi = mid } }
            outer = ceil(hi + 0.5)
        }
        let size = CGSize(width: outer.rounded(), height: height.rounded())
        return (size, false, measure(size.width, collectLines: true).text)
    }
}

final class TutuChatTypeMask {
    private let width: Int
    private let height: Int
    private let scale: CGFloat
    private let pixels: UnsafeMutablePointer<UInt8>
    private let context: CGContext
    private var previous: [TutuChatGlyph] = []
    private var previousOffset: CGFloat = 0
    private var lines: [CTLine] = []
    private(set) var alpha: [Float]
    // The source's detached TYPE_CV uses Canvas's default font smoothing, not
    // the .c11 DOM subtree's antialiased override. Match Skia's CoreText A8
    // path: smoothed black on opaque white, undo CG's coverage gamma, then
    // apply the white-foreground mask preblend. These are renderer conversions,
    // not an outline stroke, a font-weight change, or a fitted alpha curve.
    // SkScalerContext_mac_ct.cpp, SkTypeface_mac_ct.cpp::onFilterRec,
    // SkMaskGamma.cpp and SkGlyph.h in https://github.com/google/skia.
    private static let linearCoverage = (0..<256).map { ($0 * $0 + 127) / 255 }
    private static let canvasCoverage: [Float] = {
        // Modern CoreGraphics smoothing has no RGB fringe. Skia halves the
        // white paint luminance, then canonicalizes it to three luminance bits.
        let bits = (255 / 2) >> 5
        let canonical = (bits << 5) | (bits << 2) | (bits >> 1)
        let source = Double(canonical) / 255, destination = 1 - source
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func encoded(_ value: Double) -> Double {
            value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
        }
        let foreground = linear(source), background = linear(destination)
        return (0..<256).map { index in
            let a = Double(index) / 255
            let out = encoded(foreground * a + background * (1 - a))
            let coverage = floor((out - destination) / (source - destination) * 255 + 0.5)
            return Float(max(0, min(255, coverage))) / 255
        }
    }()

    init(size: CGSize, scale: CGFloat) throws {
        let w = max(1, Int((size.width * scale).rounded()))
        let h = max(1, Int((size.height * scale).rounded()))
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        storage.initialize(repeating: 255, count: w * h * 4)
        guard let ctx = CGContext(data: storage, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            storage.deallocate(); throw TutuChatError.allocation
        }
        width = w; height = h; self.scale = scale; pixels = storage; context = ctx
        alpha = [Float](repeating: 0, count: w * h)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(true)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setTextDrawingMode(.fill)
    }
    deinit { pixels.deallocate() }

    func update(glyphs: [TutuChatGlyph], offsetY: CGFloat = 0) throws -> CGRect? {
        TutuChatRenderTrace.emit("coretext.mask.begin")
        defer { TutuChatRenderTrace.emit("coretext.mask.end") }
        if glyphs == previous && offsetY == previousOffset { return nil }
        func box(_ glyph: TutuChatGlyph, _ offset: CGFloat) -> CGRect {
            guard !glyph.bounds.isEmpty else { return .null }
            return glyph.bounds.offsetBy(dx: 0, dy: offset).applying(CGAffineTransform(scaleX: scale, y: scale)).insetBy(dx: -2, dy: -2).integral
        }
        var dirty = CGRect.null
        let count = max(previous.count, glyphs.count)
        for i in 0..<count {
            let old = i < previous.count ? previous[i] : nil
            let new = i < glyphs.count ? glyphs[i] : nil
            if old != new || previousOffset != offsetY {
                if let old { dirty = dirty.union(box(old, previousOffset)) }
                if let new { dirty = dirty.union(box(new, offsetY)) }
            }
        }
        dirty = dirty.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        for i in glyphs.indices {
            if i < previous.count && previous[i].text == glyphs[i].text && previous[i].fontName == glyphs[i].fontName && previous[i].fontSize == glyphs[i].fontSize { continue }
            let line = TutuChatTypography.line(glyphs[i].text, name: glyphs[i].fontName, size: glyphs[i].fontSize)
            if i < lines.count { lines[i] = line } else { lines.append(line) }
        }
        if lines.count > glyphs.count { lines.removeLast(lines.count - glyphs.count) }
        previous = glyphs; previousOffset = offsetY
        guard !dirty.isNull && !dirty.isEmpty else { return nil }
        context.saveGState()
        // Bitmap rows are exposed top-first; use a top-left coordinate system
        // for clipping, then flip each Core Text baseline back to glyph-up.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.clip(to: dirty)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); context.fill(dirty)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        for i in glyphs.indices where box(glyphs[i], offsetY).intersects(dirty) {
            context.saveGState()
            // Skia's horizontal glyph strike retains quarter-pixel x phases
            // and snaps the orthogonal baseline to a device pixel.
            let x = floor(glyphs[i].origin.x * scale * 4 + 0.5) / 4
            let y = floor((glyphs[i].origin.y + offsetY) * scale + 0.5)
            context.translateBy(x: x, y: y)
            context.scaleBy(x: scale, y: -scale)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(lines[i], context)
            context.restoreGState()
        }
        context.restoreGState()
        for y in Int(dirty.minY)..<Int(dirty.maxY) {
            for x in Int(dirty.minX)..<Int(dirty.maxX) {
                let i = y * width + x, p = i * 4
                let red = Self.linearCoverage[Int(pixels[p])]
                let green = Self.linearCoverage[Int(pixels[p + 1])]
                let blue = Self.linearCoverage[Int(pixels[p + 2])]
                let coverage = 255 - ((54 * red + 183 * green + 19 * blue) >> 8)
                alpha[i] = Self.canvasCoverage[coverage]
            }
        }
        return dirty
    }
}
#endif
#endif
