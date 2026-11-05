import SwiftUI
import SwiftStreamingMarkdown

// MARK: - 马克笔概念词（plan-onboarding-xiaoya-impl §12-E；小样 design-onboarding-xiaoya-v3.html .mk / .gloss）
// 一种颜色（黄）、一笔，画在字的下半截。她那句话（ChatMarkdownView）借 fork 的划线层 pen 画；
// Tip 卡 / 灯泡列表里的 SwiftUI Text 用 TextRenderer 画同一个样子。点词弹释义 sheet（XiaoyaGlossSheet，里面是线圈本）。

enum XiaoyaMarker {
    static func color(dark: Bool) -> Color {
        dark ? Color(red: 0.925, green: 0.776, blue: 0.235).opacity(0.42) : Color(red: 1, green: 0.878, blue: 0.329).opacity(0.8)
    }

    /// 她那句话里的马克笔：每个标了的词一道（fork 划线层按词匹配，同一句里出现几次画几次）
    static func highlights(_ words: [String], dark: Bool) -> [TextHighlight] {
        let color = dark ? PlatformColor(red: 0.925, green: 0.776, blue: 0.235, alpha: 0.42)
                         : PlatformColor(red: 1, green: 0.878, blue: 0.329, alpha: 0.8)
        return words.map { TextHighlight(quote: $0, color: color, style: .pen, strokeId: "xiaoya.marker.\($0)") }
    }

    /// 一笔：下半截、往右上斜一点、两头毛边（同 .mk:before 的 rotate(-2deg) skewX(-12deg)）
    static func stroke(in r: CGRect) -> Path {
        let top = r.minY + r.height * 0.45
        let bottom = r.maxY + 1
        var p = Path()
        p.move(to: CGPoint(x: r.minX - 1, y: top + 1))
        p.addQuadCurve(to: CGPoint(x: r.maxX + 5, y: top - 1), control: CGPoint(x: r.midX, y: top - 1.5))
        p.addLine(to: CGPoint(x: r.maxX + 2, y: bottom - 1))
        p.addQuadCurve(to: CGPoint(x: r.minX - 4, y: bottom + 1), control: CGPoint(x: r.midX, y: bottom + 1))
        p.closeSubpath()
        return p
    }
}

private struct XiaoyaMarkerAttribute: TextAttribute {}

private struct XiaoyaMarkerRenderer: TextRenderer {
    let color: Color

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            for run in line where run[XiaoyaMarkerAttribute.self] != nil {
                ctx.fill(XiaoyaMarker.stroke(in: run.typographicBounds.rect), with: .color(color))
            }
        }
        for line in layout { ctx.draw(line) }
    }
}

/// SwiftUI 版：Markdown 行内（**粗体**）+ [[概念词]] 马克笔。字体 / 颜色由外面的修饰符定
struct XiaoyaMarkedText: View {
    let source: String
    @Environment(\.colorScheme) private var scheme

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        Self.text(source)
            .textRenderer(XiaoyaMarkerRenderer(color: XiaoyaMarker.color(dark: scheme == .dark)))
    }

    static func text(_ source: String) -> Text {
        XiaoyaGlossary.pieces(source).reduce(Text(verbatim: "")) { result, piece in
            let part: Text
            switch piece {
            case .text(let markdown):
                let attributed = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(markdown)
                part = Text(attributed)
            case .mark(let word):
                part = Text(word).bold().customAttribute(XiaoyaMarkerAttribute())
            }
            return Text("\(result)\(part)")
        }
    }
}

/// 概念词的释义：page1「思考过程」同款 sheet（DisclosureSheet，40% 高），里面是一本 page1 便利贴的线圈本（NoteView + .spiral + 楷体）写「词：释义」。
/// 线圈本上已经有词，sheet 标题留空不重复。聊天里点马克笔词、灯泡列表词典里点一行，都弹这一张
struct XiaoyaGlossSheet: View {
    let term: XiaoyaGlossary.Term

    /// NoteView 字号跟宽度走（168 宽 = 15pt）：220 宽 ≈ 19.6pt 楷体，最长的 gardenOS 释义约 6 行 ≈ 240pt，40% 高的 sheet 里整本露出
    static let noteWidth: CGFloat = 220
    private static let spec = NoteSpec(kind: .spiral, font: .kai)

    var body: some View {
        DisclosureSheet(title: "", detent: .fraction(0.4)) {
            NoteView(spec: Self.spec, text: "\(term.word)：\(term.definition)", width: Self.noteWidth)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
        }
    }
}
