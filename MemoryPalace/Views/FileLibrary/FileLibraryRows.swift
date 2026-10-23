import SwiftUI

/// 文件库 v2 的尺寸 / 颜色。iOS 照小样，mac 右栏按比例缩。
enum FileLibraryUI {
    #if os(macOS)
    static let scale: CGFloat = 0.86
    static let titleSize: CGFloat = 22
    #else
    static let scale: CGFloat = 1
    static let titleSize: CGFloat = 30
    #endif

    static func size(_ pt: CGFloat) -> CGFloat { (pt * scale * 2).rounded() / 2 }
    static func font(_ pt: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size(pt), weight: weight) }
    static func mono(_ pt: CGFloat) -> Font { .system(size: size(pt), design: .monospaced) }

    static var line: Color { Theme.textPrimary.opacity(0.08) }
    static var hairline: Color { Theme.textPrimary.opacity(0.07) }
    static var chevron: Color { Theme.textMuted.opacity(0.6) }
    static var fieldFill: Color { Theme.textPrimary.opacity(0.06) }
}

/// 右上角 36pt 圆钮的外观（按钮 / Menu 共用）
struct FileLibraryCircleLabel: View {
    let symbol: String
    var tint: Color = Theme.textPrimary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: FileLibraryUI.size(16), weight: .medium))
            .foregroundColor(tint)
            .frame(width: FileLibraryUI.size(36), height: FileLibraryUI.size(36))
            .background(Circle().fill(Theme.mainBg.opacity(0.75)))
            .overlay(Circle().stroke(FileLibraryUI.hairline, lineWidth: 0.5))
            .shadow(color: Theme.textPrimary.opacity(0.06), radius: 4, y: 2)
            .contentShape(Circle())
    }
}

// MARK: - 列表

/// 圆角小方块：文件夹 = 外观颜色底 + 暖灰标记；文件 = 暖灰底 + 扩展名字样；图片 = 缩略图（同色系不深浅嵌套）
struct FileLibraryTile: View {
    enum Content: Equatable {
        case symbol(String)
        case badge(String)
        case image(URL, modifiedAt: Date?)
        case folder(FileLibraryFolderLook, name: String)
    }

    let content: Content
    let style: FileLibraryFolderStyle
    var side: CGFloat = 36

    var body: some View {
        let s = FileLibraryUI.size(side)
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.28, style: .continuous)
                .fill(fill)
            switch content {
            case .folder(let look, let name):
                let mark = look.mark.kind == .none ? FileLibraryFolderLook.Mark.mono : look.mark
                FileLibraryFolderMarkView(
                    mark: mark,
                    name: name,
                    size: mark.kind == .mono ? s * 0.44 : s * 0.5,
                    color: look.paint.tileInkIsWhite ? Color.white : Theme.textSecondary
                )
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: s * 0.46, weight: .regular))
                    .foregroundColor(Theme.textSecondary)
            case .badge(let text):
                Text(text)
                    .font(.system(size: s < 30 ? s * 0.29 : s * 0.25, weight: .bold))
                    .tracking(0.3)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 2)
            case .image(let url, let modifiedAt):
                Color.clear.overlay { FileThumbnailView(url: url, modifiedAt: modifiedAt) }
            }
        }
        .frame(width: s, height: s)
        .clipShape(RoundedRectangle(cornerRadius: s * 0.28, style: .continuous))
    }

    private var fill: Color {
        switch content {
        case .badge: Theme.textPrimary.opacity(0.06)
        case .folder(let look, _): look.paint.backColor
        case .symbol, .image: style.fillColor
        }
    }

    /// 文件的小方块：图片 = 缩略图，其它 = 扩展名字样。文件库列表和 page0 文件搜索共用（page0 不传 `modifiedAt`，缩略图自己读）。
    static func file(_ path: String, profileId: String, side: CGFloat = 36, modifiedAt: Date? = nil) -> FileLibraryTile {
        let style = FileLibraryFolderStyle.forFile(path)
        if FileLibraryDisplay.kind(of: path) == .image,
           let url = FileLibraryStore.absoluteURL(path, profileId: profileId) {
            return FileLibraryTile(content: .image(url, modifiedAt: modifiedAt), style: style, side: side)
        }
        return FileLibraryTile(content: .badge(FileLibraryDisplay.badge(path)), style: style, side: side)
    }
}

/// 分组白纸卡：圆角 16 + 0.5pt 描边，里面一行一行
struct FileLibraryGroupCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.mainBg))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(FileLibraryUI.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 一行：左小方块 + 标题 / 副标题（/ 路径）+ 右时间（+ chevron）。行间分隔线从文字处起。
struct FileLibraryRow<Subtitle: View>: View {
    let tile: FileLibraryTile
    let title: AttributedString
    let time: String
    var footnote: String? = nil
    var chevron = false
    var divider = false
    var minHeight: CGFloat = 66
    @ViewBuilder let subtitle: Subtitle

    var body: some View {
        HStack(spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FileLibraryUI.font(15))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                subtitle
                    .font(FileLibraryUI.font(12))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                if let footnote {
                    Text(footnote)
                        .font(FileLibraryUI.mono(11))
                        .foregroundColor(Theme.textMuted.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(time)
                    .font(FileLibraryUI.font(12))
                    .monospacedDigit()
                    .foregroundColor(Theme.textMuted)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(FileLibraryUI.font(12, .semibold))
                        .foregroundColor(FileLibraryUI.chevron)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: FileLibraryUI.size(minHeight))
        .overlay(alignment: .top) {
            if divider {
                Rectangle()
                    .fill(FileLibraryUI.line)
                    .frame(height: 0.5)
                    .padding(.leading, 14 + FileLibraryUI.size(36) + 12)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 卡片

/// 卡片模式的文件夹「档案袋」：淡底色 + 两张歪着的纸（装饰灰条）+ 左下图标
struct FileLibraryEnvelopeCard: View {
    let name: String
    let detail: String
    let style: FileLibraryFolderStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(style.coverColor)
                sheet(bars: 3)
                    .rotationEffect(.degrees(6))
                    .padding(.top, 14)
                    .padding(.trailing, 14)
                sheet(bars: 4)
                    .rotationEffect(.degrees(-4))
                    .padding(.top, 20)
                    .padding(.trailing, 40)
            }
            .overlay(alignment: .bottomLeading) {
                Image(systemName: style.symbol)
                    .font(FileLibraryUI.font(14))
                    .foregroundColor(style.tintColor)
                    .frame(width: FileLibraryUI.size(30), height: FileLibraryUI.size(30))
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.mainBg.opacity(0.9)))
                    .padding(.leading, 10)
                    .padding(.bottom, 9)
            }
            .frame(height: FileLibraryUI.size(92))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(FileLibraryUI.hairline, lineWidth: 0.5))

            Text(name)
                .font(FileLibraryUI.font(14, .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .padding(.top, 7)
            Text(detail)
                .font(FileLibraryUI.font(11.5))
                .monospacedDigit()
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func sheet(bars: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<bars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.textPrimary.opacity(i == 0 ? 0.16 : 0.08))
                    .frame(height: 3)
                    .frame(maxWidth: i == 0 ? 33 : .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, 8)
        .frame(width: FileLibraryUI.size(62), height: FileLibraryUI.size(76), alignment: .top)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.mainBg))
        .shadow(color: Theme.textPrimary.opacity(0.08), radius: 2, y: 1)
    }
}

/// 一张纸：文本 = 胶囊 + 标题 + 正文开头（底部渐隐）；HTML = 拍照缩略图；图片 = 缩略图；其它 = 图标 + 大小
struct FileLibraryPaper: View {
    enum Face {
        case text(chips: [String], title: String, lines: [String])
        case html(path: String, profileId: String, modifiedAt: Date, title: String, lines: [String])
        case image(URL, modifiedAt: Date)
        case binary(symbol: String, size: String)
    }

    let face: Face
    let badge: String
    var height: CGFloat = 178
    var compact = false
    /// HTML 那种暖色纸底（快照没拍、画文字纸时也用）
    var warm = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text(badge)
                .font(.system(size: FileLibraryUI.size(8.5), weight: .semibold))
                .tracking(0.4)
                .foregroundColor(Color.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.textPrimary))
                .padding(7)
        }
        .frame(height: FileLibraryUI.size(height))
        .frame(maxWidth: .infinity)
        .background(paperFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.textPrimary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: Theme.textPrimary.opacity(0.06), radius: 5, y: 3)
    }

    private var isHTML: Bool {
        if case .html = face { return true }
        return false
    }

    @ViewBuilder
    private var paperFill: some View {
        if warm || isHTML {
            LinearGradient(colors: [Color(hex: 0xF6EFE6), Theme.mainBg], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6))
        } else {
            Theme.mainBg
        }
    }

    @ViewBuilder
    private var content: some View {
        switch face {
        case .text(let chips, let title, let lines):
            textFace(chips: chips, title: title, lines: lines)
        case .html(let path, let profileId, let modifiedAt, let title, let lines):
            Color.clear
                .overlay(alignment: .top) {
                    HTMLCardThumbView(
                        path: path,
                        profileId: profileId,
                        modifiedAt: modifiedAt,
                        placeholder: AnyView(textFace(chips: [], title: title, lines: lines))
                    )
                }
                .clipped()
        case .image(let url, let modifiedAt):
            Color.clear
                .overlay { FileThumbnailView(url: url, modifiedAt: modifiedAt) }
                .clipped()
        case .binary(let symbol, let size):
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 26))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
                Text(size)
                    .font(FileLibraryUI.font(11))
                    .foregroundColor(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func textFace(chips: [String], title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !chips.isEmpty {
                HStack(spacing: 4) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: FileLibraryUI.size(8.5)))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.textPrimary.opacity(0.06)))
                    }
                }
                .padding(.bottom, 7)
            }
            Text(title)
                .font(.system(size: FileLibraryUI.size(compact ? 10.5 : 12.5), weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .padding(.bottom, compact ? 5 : 6)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: FileLibraryUI.size(compact ? 8.6 : 10)))
                        .lineSpacing(compact ? 2 : 3)
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .padding(.top, compact ? 11 : 13)
        .padding(.horizontal, compact ? 10 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Theme.mainBg.opacity(0), Theme.mainBg], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.8))
                .frame(height: compact ? 34 : 46)
        }
    }
}

/// 纸 + 纸下的字：文本文件只写时间；图片 / 二进制写文件名 + 时间
struct FileLibraryPaperCard: View {
    let paper: FileLibraryPaper
    let caption: String?
    let time: String
    /// 开盒转场的锚点：只挂在纸那块，标题 / 时间不算
    var anchor: String? = nil
    var frames: FileLibraryFlightFrames? = nil
    /// 开盒转场：纸由飞行层画着时藏起来；纸落上来的那张，标题 / 时间等纸快落定再淡入
    var flight: FileLibraryFlightState? = nil
    var page = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            paper
                .fileLibraryFlightAnchor(anchor ?? "", in: anchor == nil ? nil : frames)
                .modifier(FileLibraryFlightHide(mark: anchor.flatMap { flight?.mark($0) }))
            Group {
                if let caption {
                    Text(caption)
                        .font(FileLibraryUI.font(13, .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 8)
                }
                Text(time)
                    .font(FileLibraryUI.font(11))
                    .monospacedDigit()
                    .foregroundColor(Theme.textMuted)
                    .padding(.top, caption == nil ? 7 : 0)
            }
            .modifier(FileLibraryIntroStyle(state: anchor == nil ? nil : flight, page: page, role: .caption(anchor ?? "")))
        }
        .contentShape(Rectangle())
    }
}

/// 全是图的文件夹：三列方格
struct FileLibraryGalleryCell: View {
    let url: URL
    let modifiedAt: Date

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(FileThumbnailView(url: url, modifiedAt: modifiedAt))
            .clipped()
            .contentShape(Rectangle())
    }
}

// MARK: - 树

/// 树的一行：每层缩进 20pt，层级线是点点虚线（末项画 └）；文件夹 = chevron + 着色小方块 + 粗体名 + 数量胶囊
struct FileLibraryTreeRow: View {
    /// 每个祖先层的竖线要不要接着画（长度 = depth - 1）
    let guides: [Bool]
    let depth: Int
    let isLast: Bool
    /// nil = 文件
    let expanded: Bool?
    let tile: FileLibraryTile
    let name: String
    let trailing: String
    let highlighted: Bool

    private static let rowHeight: CGFloat = 42

    var body: some View {
        let h = FileLibraryUI.size(Self.rowHeight)
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<depth, id: \.self) { level in
                    guideCell(level: level, height: h)
                }
            }
            .padding(.leading, 8)
            Group {
                if let expanded {
                    Image(systemName: "chevron.right")
                        .font(.system(size: FileLibraryUI.size(10), weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .frame(width: 18)
            tile
                .padding(.leading, 2)
                .padding(.trailing, 9)
            Text(name)
                .font(FileLibraryUI.font(14.5, expanded == nil ? .regular : .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if expanded == nil {
                Text(trailing)
                    .font(FileLibraryUI.font(11.5))
                    .monospacedDigit()
                    .foregroundColor(Theme.textMuted)
                    .fixedSize()
            } else {
                Text(trailing)
                    .font(FileLibraryUI.font(11))
                    .monospacedDigit()
                    .foregroundColor(Theme.textMuted)
                    .padding(.horizontal, 7)
                    .background(Capsule().fill(Theme.sidebarBg))
                    .fixedSize()
            }
        }
        .padding(.trailing, 14)
        .frame(height: h)
        .background(
            LinearGradient(
                stops: [.init(color: Theme.branchIndicator.opacity(0), location: 0), .init(color: Theme.branchIndicator.opacity(0.13), location: 0.3)],
                startPoint: .leading, endPoint: .trailing
            )
            .opacity(highlighted ? 1 : 0)
        )
        .contentShape(Rectangle())
    }

    private func guideCell(level: Int, height: CGFloat) -> some View {
        let own = level == depth - 1
        let continues = own || (level < guides.count && guides[level])
        return Path { p in
            guard continues else { return }
            p.move(to: CGPoint(x: 11, y: 0))
            p.addLine(to: CGPoint(x: 11, y: own && isLast ? height / 2 : height))
            if own && isLast {
                p.move(to: CGPoint(x: 11, y: height / 2))
                p.addLine(to: CGPoint(x: 18, y: height / 2))
            }
        }
        .stroke(Theme.branchIndicator.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 3]))
        .frame(width: 20, height: height)
    }
}

/// 三段视图开关：选中段白底 + 绿图标
struct FileLibrarySegment: View {
    struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: String
    }

    @Binding var selection: String
    let items: [Item]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items) { item in
                let on = item.id == selection
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = item.id }
                } label: {
                    Image(systemName: item.symbol)
                        .font(FileLibraryUI.font(12, .medium))
                        .foregroundColor(on ? Theme.branchIndicator : Theme.textSecondary)
                        .frame(width: FileLibraryUI.size(30), height: FileLibraryUI.size(24))
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(on ? Theme.mainBg : Color.clear)
                                .shadow(color: Color.black.opacity(on ? 0.08 : 0), radius: 1.5, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(on ? .isSelected : [])
                .help(item.title)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FileLibraryUI.fieldFill))
    }
}

/// 区标题（「最近」「文件夹」…），右边挂视图开关 / 排序
struct FileLibrarySectionHeader<Trailing: View>: View {
    @Environment(\.chatMetrics) private var metrics
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(FileLibraryUI.font(13, .semibold))
                .tracking(0.5)
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, metrics.fileLibHeaderInsetH + 6)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}
