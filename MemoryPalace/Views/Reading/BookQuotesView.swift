#if os(iOS)
import SwiftUI
import UIKit

// MARK: - 数据

/// 一条书摘 = 一条带原文的划线 / 笔记（plan-reading-study-2 §3）。
/// AI 回复（aiBubble）、回复串不收。PDF 的划线也收（框选 / 选字时存了原文），位置是页码。
struct StudyQuote: Identifiable, Sendable {
    var positionLabel: String { isPDF ? "第 \(chapter) 页" : "第 \(chapter) 章" }

    let id: String
    let bookId: String
    let bookName: String
    let author: String
    /// txt = 第几章；PDF = 第几页
    let chapter: Int
    let isPDF: Bool
    let text: String
    let anchorStart: Int
    /// 这处时间线里最新的一条批注（卡片底显示）
    let note: String?
    /// 这处一共几条批注（>1 时卡片底写「共 N 条」）
    var noteCount: Int = 0
    let createdAt: Date
    /// 这道划线自己的颜色（书页样式的马克笔用）
    var colorHex: String = HighlightPalette.userDefault

    static func load(bookId: String, bookName: String, author: String, profileId: String) -> [StudyQuote] {
        // 一处一张卡（同一段叠了几道只算一张），批注把整条时间线聚合进来（P3-3）
        let all = BookStore.loadNotes(safeName: bookId, profileId: profileId)
        return NoteThreads.places(for: all.filter { $0.replyTo == nil }.map(\.id), in: all)
            .filter { $0.primary.kind != "aiBubble" }
            .compactMap { place in
                let n = place.primary
                let text = n.anchorText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let summary = NoteThreads.summary(of: place, in: all)
                let note = summary.latest ?? ""
                return StudyQuote(id: n.id, bookId: bookId, bookName: bookName, author: author,
                                  chapter: n.chapter, isPDF: n.rects != nil, text: text, anchorStart: n.anchorStart,
                                  note: note.isEmpty ? nil : note, noteCount: summary.count, createdAt: n.createdAt,
                                  colorHex: (place.strokes.last ?? n).strokeColorHex)
            }
    }
}

// MARK: - 书摘页（plan-reading-study-3 §1：A 展签 / B 书页 / C 书签条，设置里切）

enum QuoteStyle: String, CaseIterable {
    case exhibit, page, bookmark
    var title: String {
        switch self {
        case .exhibit: "展签"
        case .page: "书页"
        case .bookmark: "书签条"
        }
    }
}

/// 三种样式共用的外壳：数据、按书筛选、底图池、翻到这一页、分享 / 存相册
struct BookQuotesView: View {
    let quotes: [StudyQuote]
    let profileId: String
    var initialBookId: String? = nil
    var onJump: (StudyQuote) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("quotes.style") private var styleRaw = QuoteStyle.exhibit.rawValue
    @AppStorage("quotes.artSource") private var sourceRaw = QuoteArtSource.garden.rawValue
    @State private var filter: String?
    /// 每次进来换一套底图顺序（「底图每次都会换一换」）
    @State private var salt = Int.random(in: 0..<100_000)
    @State private var pool: [QuoteBackdrop] = []
    @State private var shareItem: QuoteShareImage?
    @State private var toast: String?

    private var style: QuoteStyle { QuoteStyle(rawValue: styleRaw) ?? .exhibit }
    private var shown: [StudyQuote] { filter.map { f in quotes.filter { $0.bookId == f } } ?? quotes }

    private var books: [(id: String, name: String)] {
        var seen = Set<String>()
        return quotes.compactMap { seen.insert($0.bookId).inserted ? ($0.bookId, $0.bookName) : nil }
    }

    func backdrop(_ index: Int) -> QuoteBackdrop {
        pool.isEmpty ? .garden(index) : pool[index % pool.count]
    }

    var body: some View {
        let ctx = QuoteStyleContext(
            quotes: shown, backdrop: backdrop, filterMenu: AnyView(filterMenu),
            onBack: { dismiss() }, onJump: onJump,
            onShare: { img in shareItem = QuoteShareImage(image: img) },
            onSave: saveToPhotos)
        Group {
            if shown.isEmpty {
                VStack(spacing: 14) {
                    HStack { QuoteGlassButton(icon: "chevron.left", label: "返回") { dismiss() }; Spacer() }
                        .padding(.horizontal, 16).padding(.top, 8)
                    Spacer()
                    Text("还没有书摘。读书时划一句，就会出现在这里。")
                        .font(.system(size: 13)).foregroundStyle(Theme.textMuted)
                    Spacer()
                }
                .background(Color(hex: 0xF1ECE3).ignoresSafeArea())
            } else {
                switch style {
                case .exhibit: QuotesExhibitView(ctx: ctx)
                case .page: QuotesPageView(ctx: ctx)
                case .bookmark: QuotesBookmarkView(ctx: ctx)
                }
            }
        }
        .id(filter ?? "")      // 换筛选从第一条重新开始
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Color(hex: 0x2C2A28, alpha: 0.85), in: Capsule())
                    .padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
        .onAppear {
            filter = initialBookId
            pool = (QuoteArtSource(rawValue: sourceRaw) ?? .garden).pool(profileId: profileId, salt: salt)
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.image]).presentationDetents([.medium, .large]) }
    }

    private var filterMenu: some View {
        Menu {
            Picker("书", selection: $filter) {
                Text("全部书 · \(quotes.count)").tag(String?.none)
                ForEach(books, id: \.id) { b in Text(b.name).tag(String?.some(b.id)) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(filter.flatMap { f in books.first { $0.id == f }?.name } ?? "全部书")
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 6)
            .frame(height: 28)
        }
        .buttonStyle(.glass)
    }

    private func saveToPhotos(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        toast = "已存到相册"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { toast = nil }
    }
}

/// 传给三种样式的东西
struct QuoteStyleContext {
    let quotes: [StudyQuote]
    let backdrop: (Int) -> QuoteBackdrop
    let filterMenu: AnyView
    let onBack: () -> Void
    let onJump: (StudyQuote) -> Void
    let onShare: (UIImage) -> Void
    let onSave: (UIImage) -> Void

    /// 导出用：按显示尺寸 3 倍渲染。版面里不用系统材质（ImageRenderer 渲不出模糊）。
    @MainActor
    static func render<V: View>(_ view: V) -> UIImage? {
        let r = ImageRenderer(content: view)
        r.scale = 3
        return r.uiImage
    }

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd"
        return f
    }()
}

private struct QuoteShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct QuoteGlassButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

struct QuotePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color(hex: 0xFBF8F2), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(hex: 0xE6DED0), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// 「花园」底图：渐变 + 叶影 + 纸纹，全是生成的（零包体）。名画 / 自己的图见 QuoteBackdrops.swift。
struct QuoteArt: View {
    let variant: Int

    static let names = ["薄荷与晚霞", "纸纹", "夜园", "蔷薇", "牛皮纸"]
    static var count: Int { names.count }

    /// 整体垫一层不参与撑大的空底：里面的叶影图是 scaledToFill，直接放会把外框撑大（设置缩略图 / 展签都被它裁过，09-26）
    var body: some View {
        Color.clear.overlay { layers }.clipped()
    }

    private var layers: some View {
        ZStack {
            switch variant % Self.count {
            case 0:
                Color(hex: 0xC9B79C)
                RadialGradient(colors: [Color(hex: 0xE9C9B8), .clear], center: UnitPoint(x: 0.2, y: 0.2), startRadius: 0, endRadius: 180)
                RadialGradient(colors: [Color(hex: 0x9FB7A6), .clear], center: UnitPoint(x: 0.8, y: 0.7), startRadius: 0, endRadius: 220)
                RadialGradient(colors: [Color(hex: 0x6E8872), .clear], center: UnitPoint(x: 0.5, y: 1.05), startRadius: 0, endRadius: 200)
                leaves(opacity: 0.35, angle: 0)
            case 1:
                Color(hex: 0xEFE6D2)
                Stripes().fill(Color(hex: 0xE3D5BB))
                leaves(opacity: 0.18, angle: 20)
            case 2:
                LinearGradient(colors: [Color(hex: 0x2F3B36), Color(hex: 0x44574C)], startPoint: .top, endPoint: .bottom)
                leaves(opacity: 0.5, angle: -15).colorInvert().blendMode(.screen)
            case 3:
                Color(hex: 0xEAD3D0)
                RadialGradient(colors: [Color(hex: 0xF6E6DF), .clear], center: UnitPoint(x: 0.3, y: 0.25), startRadius: 0, endRadius: 200)
                RadialGradient(colors: [Color(hex: 0xC9DCD1), .clear], center: UnitPoint(x: 0.85, y: 0.85), startRadius: 0, endRadius: 200)
                leaves(opacity: 0.25, angle: 160)
            default:
                Color(hex: 0xD9C19A)
                LinearGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                leaves(opacity: 0.28, angle: 90)
            }
        }
    }

    private func leaves(opacity: Double, angle: Double) -> some View {
        Image("StudyLeafShadow")
            .resizable()
            .scaledToFill()
            .rotationEffect(.degrees(angle))
            .blendMode(.multiply)
            .opacity(opacity)
    }

    private struct Stripes: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            var x = -rect.height
            while x < rect.width {
                p.move(to: CGPoint(x: x, y: rect.height))
                p.addLine(to: CGPoint(x: x + 14, y: rect.height))
                p.addLine(to: CGPoint(x: x + 14 + rect.height, y: 0))
                p.addLine(to: CGPoint(x: x + rect.height, y: 0))
                p.closeSubpath()
                x += 28
            }
            return p
        }
    }
}

// MARK: - 墙上的书摘便签（只在书房 3D 布局）

struct StudyQuoteNote: View {
    let style: StudyNoteStyle
    let count: Int
    let latest: String
    let tilt: StudyTilt

    private var excerpt: String {
        let s = latest.count > 22 ? String(latest.prefix(22)) + "…" : latest
        return "「\(s)」"
    }

    var body: some View {
        // 09-26：两种都再小一号
        Group {
            switch style {
            case .clip: clipCard
            case .tag: hangingTag
            }
        }
        .scaleEffect(0.84, anchor: .topTrailing)
    }

    /// N2：带薄荷横线的小卡，回形针别在左上
    private var clipCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("书摘 · \(count)").font(.custom("Kaiti SC", size: 16).bold())
            Text(excerpt).font(.custom("Kaiti SC", size: 11)).lineSpacing(3).lineLimit(3)
                .foregroundStyle(Color(hex: 0x7D6858))
        }
        .foregroundStyle(Color(hex: 0x5E4B3C))
        .padding(EdgeInsets(top: 16, leading: 14, bottom: 12, trailing: 14))
        .frame(width: 134, alignment: .leading)
        .background {
            ZStack(alignment: .top) {
                Color(hex: 0xFFFDF8)
                VStack(spacing: 18) {
                    ForEach(0..<6, id: \.self) { _ in Rectangle().fill(Color(hex: 0x8EBD9F, alpha: 0.35)).frame(height: 1) }
                }
                .padding(.top, 28)
            }
            .clipped()
        }
        .shadow(color: Color(hex: 0x46321E, alpha: 0.3), radius: 7, y: 7)
        .overlay(alignment: .topLeading) { PaperClip().offset(x: 18, y: -15) }
        .rotationEffect(.degrees(3))
    }

    /// N3：牛皮纸吊牌，麻绳挂在墙钉上，跟着陀螺仪轻轻摆
    private var hangingTag: some View {
        ZStack(alignment: .top) {
            Path { p in
                p.move(to: CGPoint(x: 75, y: 4)); p.addQuadCurve(to: CGPoint(x: 58, y: 50), control: CGPoint(x: 60, y: 26))
                p.move(to: CGPoint(x: 75, y: 4)); p.addQuadCurve(to: CGPoint(x: 92, y: 50), control: CGPoint(x: 90, y: 26))
            }
            .stroke(Color(hex: 0xA58760), lineWidth: 1.5)
            .frame(width: 150, height: 60)
            ZStack(alignment: .top) {
                TagShape().fill(Color(hex: 0xD9C19A))
                    .shadow(color: Color(hex: 0x46321E, alpha: 0.35), radius: 6, y: 7)
                Circle().fill(StudyPaper.wall).frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(Color(hex: 0xEDE2CC), lineWidth: 2.4))
                    .padding(.top, 9)
                VStack(alignment: .leading, spacing: 6) {
                    Text("书摘 · \(count)").font(.custom("Kaiti SC", size: 16).bold())
                    Text(excerpt).font(.custom("Kaiti SC", size: 10.5)).lineSpacing(2).lineLimit(3)
                        .foregroundStyle(Color(hex: 0x6A5234))
                }
                .foregroundStyle(Color(hex: 0x5E4B3C))
                .padding(.top, 28)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 104, height: 124)
            .padding(.top, 44)
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xE0DCD4), Color(hex: 0x8C877E)], center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: 5))
                .frame(width: 8, height: 8)
                .shadow(color: .black.opacity(0.3), radius: 1, x: 1, y: 2)
        }
        .frame(width: 150, height: 170, alignment: .top)
        // 手机往哪边转，吊牌就往哪边偏（⧫ 09-26：之前方向反了）
        .rotationEffect(.degrees(tilt.x * 6), anchor: UnitPoint(x: 0.5, y: 0.02))
    }

    private struct TagShape: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.width * 0.22, y: 0))
            p.addLine(to: CGPoint(x: r.width * 0.78, y: 0))
            p.addLine(to: CGPoint(x: r.width, y: r.height * 0.15))
            p.addLine(to: CGPoint(x: r.width, y: r.height - 6))
            p.addQuadCurve(to: CGPoint(x: r.width - 6, y: r.height), control: CGPoint(x: r.width, y: r.height))
            p.addLine(to: CGPoint(x: 6, y: r.height))
            p.addQuadCurve(to: CGPoint(x: 0, y: r.height - 6), control: CGPoint(x: 0, y: r.height))
            p.addLine(to: CGPoint(x: 0, y: r.height * 0.15))
            p.closeSubpath()
            return p
        }
    }

    private struct PaperClip: View {
        var body: some View {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0xA9ADB0), lineWidth: 2.4)
                    .frame(width: 15, height: 42)
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xA9ADB0), lineWidth: 2.4)
                    .frame(width: 8, height: 30)
                    .padding(.top, 6)
            }
            .shadow(color: .black.opacity(0.2), radius: 0.5, x: 1, y: 1)
        }
    }
}
#endif
