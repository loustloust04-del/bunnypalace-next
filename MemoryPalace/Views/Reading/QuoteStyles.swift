#if os(iOS)
import SwiftUI
import UIKit

private let quoteInk = Color(hex: 0x2E2A26)
private let quoteMuted = Color(hex: 0xA69A8A)

private func quoteSource(_ q: StudyQuote) -> String {
    q.author.isEmpty ? "《\(q.bookName)》" : "《\(q.bookName)》· \(q.author)"
}

// MARK: - A 展签：底图铺满，上下翻；书摘是贴在画边的一张展签

struct QuotesExhibitView: View {
    let ctx: QuoteStyleContext
    @State private var current: Int? = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(ctx.quotes.enumerated()), id: \.element.id) { i, q in
                        ExhibitPage(quote: q, backdrop: ctx.backdrop(i)) { ctx.onJump(q) }
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()

            VStack {
                HStack(spacing: 10) {
                    QuoteGlassButton(icon: "chevron.left", label: "返回", action: ctx.onBack)
                    ctx.filterMenu
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        QuoteGlassButton(icon: "square.and.arrow.up", label: "分享") { export(ctx.onShare) }
                        QuoteGlassButton(icon: "arrow.down.to.line", label: "存到相册") { export(ctx.onSave) }
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 58)
            }
            // 右侧进度点（最多显示 7 个）
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    ForEach(dotRange, id: \.self) { i in
                        Capsule()
                            .fill(.white.opacity(i == (current ?? 0) ? 1 : 0.5))
                            .frame(width: 5, height: i == (current ?? 0) ? 14 : 5)
                    }
                }
                .padding(.trailing, 26)
                .animation(.easeOut(duration: 0.2), value: current)
            }
            .allowsHitTesting(false)
        }
    }

    private var dotRange: Range<Int> {
        let n = ctx.quotes.count, c = current ?? 0
        let lo = max(0, min(c - 3, n - 7))
        return lo..<min(n, lo + 7)
    }

    private func export(_ done: (UIImage) -> Void) {
        let i = current ?? 0
        guard ctx.quotes.indices.contains(i) else { return }
        let page = ExhibitPage(quote: ctx.quotes[i], backdrop: ctx.backdrop(i), exporting: true)
            .frame(width: 360, height: 640)
        if let img = QuoteStyleContext.render(page) { done(img) }
    }
}

private struct ExhibitPage: View {
    let quote: StudyQuote
    let backdrop: QuoteBackdrop
    var exporting = false
    var onJump: () -> Void = {}

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            QuoteBackdropView(backdrop: backdrop)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .center, endPoint: .bottom)
            label
                .padding(.leading, 18)
                .padding(.trailing, exporting ? 18 : 70)
                .padding(.bottom, exporting ? 48 : 64)
            if let credit = backdrop.credit {
                Text(credit)
                    .font(.system(size: 10, design: .serif))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .padding(.leading, 20)
                    .padding(.bottom, exporting ? 18 : 26)
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(quoteSource(quote))
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color(hex: 0x6B6258))
                .lineLimit(1)
            Text(quote.text)
                .font(.custom("Songti SC", size: 15))
                .lineSpacing(8)
                .foregroundStyle(quoteInk)
                .lineLimit(9)
                .padding(.vertical, 10)
            if let note = quote.note {
                Text("批注" + (quote.noteCount > 1 ? "（共 \(quote.noteCount) 条，最新）" : "") + " · \(note)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x7D7266))
                    .lineLimit(2)
                    .padding(.bottom, 8)
            }
            Rectangle().fill(Color(hex: 0xE7E1D6)).frame(height: 1)
            HStack {
                Text("\(quote.positionLabel) · \(QuoteStyleContext.dateFormat.string(from: quote.createdAt))")
                Spacer()
                if !exporting {
                    Button("翻到这一页 →", action: onJump)
                        .foregroundStyle(Color(hex: 0x6FA385))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color(hex: 0x8A8074))
            .padding(.top, 8)
        }
        .padding(16)
        .background(Color(hex: 0xFBF9F4))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
    }
}

// MARK: - B 书页：一页页叠着的米白书页，左右翻；底图做插页

struct QuotesPageView: View {
    let ctx: QuoteStyleContext
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                QuoteGlassButton(icon: "chevron.left", label: "返回", action: ctx.onBack)
                Text("书摘").font(.custom("Songti SC", size: 22).bold()).foregroundStyle(Theme.textPrimary)
                Spacer()
                ctx.filterMenu
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
            ZStack {
                // 后面垫两张错开的纸，像一叠书页
                ForEach(0..<2, id: \.self) { k in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: 0xF7F2E8))
                        .shadow(color: Color(hex: 0x3C2814, alpha: 0.12), radius: 3, y: 2)
                        .rotationEffect(.degrees(k == 0 ? 1.4 : 0.6))
                        .offset(x: k == 0 ? 6 : 3, y: k == 0 ? 6 : 3)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                        .padding(.bottom, 30)
                }
                TabView(selection: $page) {
                    ForEach(Array(ctx.quotes.enumerated()), id: \.element.id) { i, q in
                        // 翻页容器按自身边界裁内容：书页四周留出阴影的位置（⧫ 09-25 阴影被切）
                        PageCard(quote: q, backdrop: ctx.backdrop(i), index: i, total: ctx.quotes.count)
                            .padding(.horizontal, 24)
                            .padding(.top, 4)
                            .padding(.bottom, 30)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .frame(maxHeight: 570)
            HStack(spacing: 10) {
                Button("翻到这一页") { if ctx.quotes.indices.contains(page) { ctx.onJump(ctx.quotes[page]) } }
                Button("分享") { export(ctx.onShare) }
                Button("存相册") { export(ctx.onSave) }
            }
            .buttonStyle(QuotePillStyle())
            .padding(.top, 18)
            Spacer(minLength: 12)
        }
        .background(Color(hex: 0xE9E3D8).ignoresSafeArea())
    }

    private func export(_ done: (UIImage) -> Void) {
        guard ctx.quotes.indices.contains(page) else { return }
        let card = PageCard(quote: ctx.quotes[page], backdrop: ctx.backdrop(page), index: page, total: ctx.quotes.count)
            .frame(width: 330, height: 520)
            .padding(12)
            .background(Color(hex: 0xE9E3D8))
        if let img = QuoteStyleContext.render(card) { done(img) }
    }
}

private struct PageCard: View {
    let quote: StudyQuote
    let backdrop: QuoteBackdrop
    let index: Int
    let total: Int

    /// 原文底下一道马克笔（用这道划线自己的颜色）
    private var marked: AttributedString {
        var s = AttributedString(quote.text)
        s.backgroundColor = HighlightPalette.color(quote.colorHex).opacity(0.32)
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(quote.bookName).lineLimit(1)
                Spacer()
                Text(quote.positionLabel)
            }
            .font(.system(size: 10))
            .tracking(1)
            .foregroundStyle(quoteMuted)
            .padding(.bottom, 6)
            Rectangle().fill(Color(hex: 0xEDE5D6)).frame(height: 1)
            QuoteBackdropView(backdrop: backdrop)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipped()
                .padding(6)
                .background(.white)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .padding(.horizontal, 14)
                .padding(.top, 14)
            Text(backdrop.credit ?? " ")
                .font(.system(size: 9.5, design: .serif).italic())
                .foregroundStyle(quoteMuted)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.top, 5)
            Text(marked)
                .font(.custom("Songti SC", size: 15))
                .lineSpacing(9)
                .foregroundStyle(quoteInk)
                .lineLimit(8)
                .padding(.top, 14)
            if let note = quote.note {
                Text("批注" + (quote.noteCount > 1 ? "（共 \(quote.noteCount) 条，最新）" : "") + " · \(note)")
                    .font(.system(size: 11))
                    .foregroundStyle(quoteMuted)
                    .lineLimit(2)
                    .padding(.top, 8)
            }
            Spacer(minLength: 8)
            Text("— \(index + 1) / \(total) —")
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(quoteMuted)
                .frame(maxWidth: .infinity)
        }
        .padding(EdgeInsets(top: 18, leading: 22, bottom: 16, trailing: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            ZStack(alignment: .leading) {
                Color(hex: 0xFCF8F0)
                // 装订那一侧的阴影
                LinearGradient(colors: [.black.opacity(0.06), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 20)
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2,
                                          bottomTrailingRadius: 6, topTrailingRadius: 6))
        .shadow(color: Color(hex: 0x3C2814, alpha: 0.3), radius: 10, y: 8)
    }
}

// MARK: - C 书签条：一排竖长书签，点一枚拿出来

struct QuotesBookmarkView: View {
    let ctx: QuoteStyleContext
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                QuoteGlassButton(icon: "chevron.left", label: "返回", action: ctx.onBack)
                Text("书摘").font(.custom("Songti SC", size: 24).bold()).foregroundStyle(Theme.textPrimary)
                Spacer()
                ctx.filterMenu
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Text("\(ctx.quotes.count) 枚 · 点一枚拿出来看")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 22)
                .padding(.top, 4)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .center, spacing: 0) {
                        ForEach(Array(ctx.quotes.enumerated()), id: \.element.id) { i, q in
                            // 每枚都按大尺寸排好版，没选中的整体缩到 80%：切换只动缩放，里面的竖排不重排（⧫ 09-26 嫌不平滑）
                            // 布局框固定不变（切换时整排不重新排位置），只缩放；内容先拍平成一张图再缩（09-26 还卡）
                            BookmarkStrip(quote: q, backdrop: ctx.backdrop(i))
                                .scaleEffect(i == selected ? 1 : 0.8)
                                .frame(width: BookmarkStrip.size.width, height: BookmarkStrip.size.height)
                                .id(i)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                                        selected = i
                                        proxy.scrollTo(i, anchor: .center)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 520)     // 书签四周给阴影留位置，ScrollView 会裁掉越界的部分
                }
            }
            .padding(.top, 10)
            HStack(spacing: 10) {
                Button("翻到这一页") { if ctx.quotes.indices.contains(selected) { ctx.onJump(ctx.quotes[selected]) } }
                Button("分享") { export(ctx.onShare) }
                Button("存相册") { export(ctx.onSave) }
            }
            .buttonStyle(QuotePillStyle())
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            Spacer(minLength: 12)
        }
        .background(StudyPaper.wall.ignoresSafeArea())
    }

    private func export(_ done: (UIImage) -> Void) {
        guard ctx.quotes.indices.contains(selected) else { return }
        let strip = BookmarkStrip(quote: ctx.quotes[selected], backdrop: ctx.backdrop(selected))
            .padding(24)
            .background(StudyPaper.wall)
        if let img = QuoteStyleContext.render(strip) { done(img) }
    }
}

private struct BookmarkStrip: View {
    let quote: StudyQuote
    let backdrop: QuoteBackdrop

    static let size = CGSize(width: 150, height: 450)
    private var size: CGSize { Self.size }

    var body: some View {
        let artHeight = size.height * 0.38
        VStack(spacing: 0) {
            QuoteBackdropView(backdrop: backdrop)
                .frame(width: size.width, height: artHeight)
                .clipped()
            VerticalQuote(text: quote.text,
                          source: "\(quote.bookName) · \(quote.positionLabel.replacingOccurrences(of: " ", with: ""))",
                          fontSize: 14.5,
                          width: size.width - 14,
                          height: size.height - artHeight - 56)
                .padding(.top, 14)
            Spacer(minLength: 0)
            Text("摘")
                .font(.custom("Songti SC", size: 10).bold())
                .foregroundStyle(Color(hex: 0xB85C5C))
                .frame(width: 20, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(hex: 0xB85C5C), lineWidth: 1.4))
                .padding(.bottom, 10)
        }
        .frame(width: size.width, height: size.height)
        .background(Color(hex: 0xFBF7EE))
        .overlay(alignment: .top) {
            // 穿绳的小孔 + 红绳
            ZStack(alignment: .top) {
                Circle().fill(StudyPaper.wall).frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.35), radius: 1, x: 1, y: 1)
                    .padding(.top, 10)
                Rectangle().fill(Color(hex: 0xB85C5C)).frame(width: 2, height: 20)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .drawingGroup()
        .shadow(color: Color(hex: 0x3C2814, alpha: 0.3), radius: 10, y: 8)
    }
}

/// 竖排：一列一列从右往左排；标点换成竖排字形；出处单独一列放最左边。放不下的截断加「︙」。
private struct VerticalQuote: View {
    let text: String
    let source: String
    let fontSize: CGFloat
    let width: CGFloat
    let height: CGFloat

    private static let vertical: [Character: Character] = [
        "，": "︐", "。": "︒", "、": "︑", "：": "︓", "；": "︔", "！": "︕", "？": "︖",
        "「": "﹁", "」": "﹂", "『": "﹃", "』": "﹄", "（": "︵", "）": "︶", "《": "︽", "》": "︾",
        "“": "﹁", "”": "﹂", "‘": "﹃", "’": "﹄", "—": "︱", "…": "︙", "(": "︵", ")": "︶",
    ]

    private func columns(of s: String, perColumn: Int, maxColumns: Int) -> [[Character]] {
        let chars = s.filter { !$0.isNewline && $0 != " " }.map { Self.vertical[$0] ?? $0 }
        var cols = stride(from: 0, to: chars.count, by: perColumn).map { Array(chars[$0..<min($0 + perColumn, chars.count)]) }
        if cols.count > maxColumns {
            cols = Array(cols.prefix(maxColumns))
            cols[cols.count - 1][cols[cols.count - 1].count - 1] = "︙"
        }
        return cols
    }

    /// 西文为主（中日文字符不到三成）：不逐字竖排，整段横排转 90° 侧着读（⧫ 09-26：英文逐字竖排一个字母一行没法读）
    private static func isMostlyLatin(_ s: String) -> Bool {
        let letters = s.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard !letters.isEmpty else { return false }
        let cjk = letters.filter { $0.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) } }
        return Double(cjk.count) / Double(letters.count) < 0.3
    }

    var body: some View {
        if Self.isMostlyLatin(text) {
            sideways
        } else {
            verticalColumns
        }
    }

    /// 横排文字转 90°：先按「书签高 × 书签宽」排版，再顺时针转过来
    private var sideways: some View {
        let latinSource = Self.isMostlyLatin(source)
        return HStack(alignment: .top, spacing: 6) {
            if latinSource {
                Text(source)
                    .font(.system(size: 9.5, design: .serif))
                    .foregroundStyle(quoteMuted)
                    .lineLimit(1)
                    .frame(width: height, alignment: .leading)
                    .rotationEffect(.degrees(90))
                    .frame(width: 12, height: height)
            } else {
                column(columns(of: source, perColumn: Int(height / (10 * 1.3)), maxColumns: 1).first ?? [], size: 10, color: quoteMuted)
            }
            Text(text)
                .font(.system(size: fontSize - 1.5, design: .serif))
                .lineSpacing(4)
                .foregroundStyle(quoteInk)
                .frame(width: height, height: width - 20, alignment: .topLeading)
                .rotationEffect(.degrees(90))
                .frame(width: width - 20, height: height)
        }
        .frame(width: width, height: height, alignment: .top)
    }

    private var verticalColumns: some View {
        let step = fontSize * 1.28
        let perColumn = max(1, Int(height / step))
        let columnWidth = fontSize * 1.55
        let maxColumns = max(1, Int(width / columnWidth) - 1)
        let quoteCols = columns(of: text, perColumn: perColumn, maxColumns: maxColumns)
        let sourceCol = columns(of: source, perColumn: Int(height / (10 * 1.3)), maxColumns: 1).first ?? []
        return HStack(alignment: .top, spacing: fontSize * 0.3) {
            column(sourceCol, size: 10, color: quoteMuted)
            ForEach(Array(quoteCols.enumerated().reversed()), id: \.offset) { _, col in
                column(col, size: fontSize, color: quoteInk)
            }
        }
        .frame(width: width, height: height, alignment: .top)
    }

    private func column(_ chars: [Character], size: CGFloat, color: Color) -> some View {
        VStack(spacing: size * 0.28) {
            ForEach(Array(chars.enumerated()), id: \.offset) { _, c in
                Text(String(c))
                    .font(.custom("Songti SC", size: size))
                    .foregroundStyle(color)
                    .frame(width: size * 1.2, height: size)
            }
        }
    }
}
#endif
