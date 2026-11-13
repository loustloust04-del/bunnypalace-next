#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import CoreText

/// Display-only inputs: storage and the conversation's displayMode remain untouched.
struct TutuChatMessageSnapshot: Hashable {
    var id: String
    var text: String
    var isUser: Bool
    var isRich: Bool
    var hasRecall: Bool = false
    var hasDate: Bool = false
    var nativeHeight: CGFloat = 0
    var dateLabel: String = ""
    var recallLabel: String = ""
}

enum TutuChatContent {
    struct Part { var action: String; var say: String }
    private static let markdown = try! NSRegularExpression(
        pattern: #"(?m)(?:^\s{0,3}(?:#{1,6}\s|>\s|[-+*]\s|\d+[.)]\s|```|~~~)|!?\[[^\]\n]*\]\(|`|\*\*|__|~~|<[/!A-Za-z]|\|.*\||\*[^*\n]+\*|_[^_\n]+_)"#)
    private static let urls = try! NSRegularExpression(pattern: #"(?:[A-Za-z][A-Za-z0-9+.-]*://|www\.)[^\s<>]+"#)
    static func isCJK(_ value: String) -> Bool {
        value.range(of: #"[⺀-⿿　-〿぀-ヿ㐀-䶿一-鿿豈-﫿︰-﹏＀-￯]"#, options: .regularExpression) != nil
    }
    static func isMarkdown(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return markdown.firstMatch(in: text, range: range) != nil || urls.firstMatch(in: text, range: range) != nil
    }
    static func feltParts(_ text: String) -> [String] {
        let parts = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return parts.isEmpty ? [""] : parts
    }
    /// Only paired parentheses are fallback actions; native Markdown/code/URLs remain opaque.
    static func cards(_ text: String) -> [Part] {
        if isMarkdown(text) { return [Part(action: "", say: text)] }
        var parts: [Part] = [], pending = "", speech = ""
        func flushSpeech() {
            for paragraph in speech.components(separatedBy: "\n\n") {
                let value = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { parts.append(Part(action: pending, say: value)); pending = "" }
            }
            speech = ""
        }
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let char = text[cursor]
            guard char == "（" || char == "(" else { speech.append(char); cursor = text.index(after: cursor); continue }
            var stack: [Character] = [char == "（" ? "）" : ")"]
            var end = text.index(after: cursor)
            while end < text.endIndex, !stack.isEmpty {
                let next = text[end]
                if next == "（" { stack.append("）") }
                else if next == "(" { stack.append(")") }
                else if next == stack.last { stack.removeLast() }
                else if next == "）" || next == ")" { break }
                end = text.index(after: end)
            }
            guard stack.isEmpty else { speech.append(char); cursor = text.index(after: cursor); continue }
            let inner = text[text.index(after: cursor)..<text.index(before: end)].trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.isEmpty { speech += text[cursor..<end] }
            else {
                flushSpeech()
                if !pending.isEmpty { pending += "　" }
                pending += inner
            }
            cursor = end
        }
        flushSpeech()
        if !pending.isEmpty { parts.append(Part(action: pending, say: "")) }
        return parts.isEmpty ? [Part(action: "", say: "")] : parts
    }
}
enum TutuChatLayoutItem {
    case date(String)
    case recall(String)
    case me([String])
    case him([TutuChatContent.Part])
    case native(isUser: Bool, height: CGFloat)
}

struct TutuChatPositionedCard {
    var layout: TutuChatCardLayout
    var origin: CGPoint
    var index: Int
}

struct TutuChatPositionedFelt {
    var text: String
    var size: CGSize
    var origin: CGPoint
    var index: Int
    var ears: Bool
    var tail: Bool
    var emoji: Bool
    var lines: [String] = []
}

struct TutuChatItemLayout {
    enum Kind { case date, recall, me, turn }
    var kind: Kind
    var origin: CGPoint
    var size: CGSize
    var cards: [TutuChatPositionedCard] = []
    var felts: [TutuChatPositionedFelt] = []
    var turnIndex: Int = 0
}

/// Reuses finalized history layout while the live turn changes; streaming prefixes are never retained.
final class TutuChatLayoutCache {
    private final class CardValue: NSObject { let layout: TutuChatCardLayout; init(_ layout: TutuChatCardLayout) { self.layout = layout } }
    private final class FeltValue: NSObject {
        let size: CGSize; let emoji: Bool; let lines: [String]
        init(_ value: (size: CGSize, emoji: Bool, lines: [String])) { size = value.size; emoji = value.emoji; lines = value.lines }
    }
    private let cards = NSCache<NSString, CardValue>()
    private let felts = NSCache<NSString, FeltValue>()
    init() { cards.countLimit = 256; felts.countLimit = 256 }
    func card(action: String, say: String) -> TutuChatCardLayout {
        let key = "\(action.utf8.count):\(action)\(say)" as NSString
        if let value = cards.object(forKey: key) { return value.layout }
        let value = TutuChatTypography.card(action: action, say: say)
        cards.setObject(CardValue(value), forKey: key); return value
    }
    func felt(text: String) -> (size: CGSize, emoji: Bool, lines: [String]) {
        let key = text as NSString
        if let value = felts.object(forKey: key) { return (value.size, value.emoji, value.lines) }
        let value = TutuChatTypography.feltTextLayout(text: text)
        felts.setObject(FeltValue(value), forKey: key); return value
    }
    func removeAll() { cards.removeAllObjects(); felts.removeAllObjects() }
}

/// The same source-order layout is used by production and the offline frame compositor.
enum TutuChatConversationLayout {
    static func canvasPaintRect(_ rect: CGRect) -> CGRect {
        // HTMLCanvasElement::PaintInternal uses ToPixelSnappedRect in CSS
        // pixels, before the device-scale transform. Snap both edges, not the
        // texture's pixel grid: a card's -1.5pt inset paints at -1pt at 3x too.
        // https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/core/html/canvas/html_canvas_element.cc
        let x = floor(rect.minX + 0.5), y = floor(rect.minY + 0.5)
        return CGRect(x: x, y: y, width: floor(rect.maxX + 0.5) - x,
                      height: floor(rect.maxY + 0.5) - y)
    }
    static func labelHeight(_ text: String, recall: Bool = false) -> CGFloat {
        let size: CGFloat = recall ? 12 : (TutuChatContent.isCJK(text) ? 10.5 : 9.5)
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        return ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }
    static func gap(after previous: TutuChatItemLayout.Kind?, before next: TutuChatItemLayout.Kind) -> CGFloat {
        switch (previous, next) {
        case (.me?, .recall): return 16
        case (.recall?, .turn): return 8
        case (.me?, .turn), (.date?, .turn), (.turn?, .turn): return 24
        case (.turn?, .me): return 42
        case (.date?, .me): return 36
        default: return 0
        }
    }
    static func layout(items: [TutuChatLayoutItem], listWidth: CGFloat = 325,
                       streamingTurn: Int? = nil, cache: TutuChatLayoutCache? = nil) -> [TutuChatItemLayout] {
        var output: [TutuChatItemLayout] = []
        var top: CGFloat = 0, lastHero: CGFloat = -1e9, lastHeight: CGFloat = 0
        var cardIndex = 0, feltIndex = 0, turnIndex = 0
        for item in items {
            let kind: TutuChatItemLayout.Kind
            switch item {
            case .date: kind = .date
            case .recall: kind = .recall
            case .me: kind = .me
            case .him: kind = .turn
            case .native(let user, _): kind = user ? .me : .turn
            }
            top += gap(after: output.last?.kind, before: kind)
            var result = TutuChatItemLayout(kind: kind, origin: CGPoint(x: 0, y: top), size: CGSize(width: listWidth, height: 0), turnIndex: turnIndex)
            switch item {
            case .date(let text): result.size.height = labelHeight(text)
            case .recall(let text): result.size.height = max(13, labelHeight(text, recall: true))
            case .me(let lines):
                var y: CGFloat = 0
                for (offset, text) in lines.enumerated() {
                    let metric = cache?.felt(text: text) ?? TutuChatTypography.feltTextLayout(text: text)
                    result.felts.append(TutuChatPositionedFelt(text: text, size: metric.size,
                        origin: CGPoint(x: listWidth - metric.size.width - 8, y: y), index: feltIndex,
                        ears: offset == 0 || metric.emoji, tail: offset == lines.count - 1 && !metric.emoji, emoji: metric.emoji, lines: metric.lines))
                    feltIndex += 1; y += metric.size.height + 14
                }
                result.size.height = max(0, y - 14)
            case .him(let parts):
                var y: CGFloat = 0
                for part in parts {
                    var card = streamingTurn == turnIndex ? TutuChatTypography.card(action: part.action, say: part.say)
                        : (cache?.card(action: part.action, say: part.say) ?? TutuChatTypography.card(action: part.action, say: part.say))
                    let cardTop = top + y
                    if streamingTurn != turnIndex, !card.hasAction, 268 - card.right > 120, cardTop - lastHero >= 612 + lastHeight {
                        if card.size.height < 88 { card.textOffset = (88 - card.size.height) / 2; card.size.height = 88 }
                        card.motif = CGRect(x: card.right + 12, y: 18, width: 249 - card.right - 12, height: card.size.height - 36)
                        lastHero = cardTop; lastHeight = card.size.height
                    }
                    result.cards.append(TutuChatPositionedCard(layout: card, origin: CGPoint(x: 0, y: y), index: cardIndex))
                    cardIndex += 1; y += card.size.height + 12
                }
                result.size.height = max(0, y - 12); turnIndex += 1
            case .native(let user, let height):
                if user {
                    let size = CGSize(width: 246, height: max(42, height + 20))
                    result.felts = [TutuChatPositionedFelt(text: "", size: size, origin: CGPoint(x: listWidth - size.width - 8, y: 0),
                                                        index: feltIndex, ears: true, tail: true, emoji: false)]
                    result.size.height = size.height; feltIndex += 1
                } else {
                    let card = TutuChatCardLayout(size: CGSize(width: 268, height: max(48, height + 32)), glyphs: [], right: 268, hasAction: true)
                    result.cards = [TutuChatPositionedCard(layout: card, origin: .zero, index: cardIndex)]
                    result.size.height = card.size.height; cardIndex += 1; turnIndex += 1
                }
            }
            output.append(result); top += result.size.height
        }
        return output
    }
}

enum TutuChatTableLighting {
    static func multiplier(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> SIMD3<Double> {
        let qx = (Double(x / width) - 0.08) / 1.30
        let qy = (Double(y / height) - 0.06) / 0.95
        let q = sqrt(qx * qx + qy * qy)
        let white = SIMD3<Double>(repeating: 1)
        let middle = SIMD3<Double>(241, 240, 238) / 255
        let end = SIMD3<Double>(226, 224, 221) / 255
        if q <= 0.28 { return white }
        if q < 0.62 { let t = (q - 0.28) / 0.34; return white + (middle - white) * t }
        let t = min(1, (q - 0.62) / 0.38)
        return middle + (end - middle) * t
    }
}
#endif
#endif
