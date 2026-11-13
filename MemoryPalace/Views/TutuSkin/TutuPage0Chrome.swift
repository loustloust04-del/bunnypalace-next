#if PERSONAL_APPS
#if os(iOS)
import SwiftUI
import ImageIO

struct TutuPage0Appearance: Equatable {
    var active = false
    var glass = false
    var scale: CGFloat = 1
    var ink: Color { glass ? Self.glassInk : Color(red: 59 / 255, green: 54 / 255, blue: 49 / 255) }
    var dim: Color { glass ? Self.glassInk.opacity(0.55) : Color(red: 169 / 255, green: 160 / 255, blue: 151 / 255) }
    var tag: Color { glass ? Self.glassInk.opacity(0.5) : Color(red: 179 / 255, green: 170 / 255, blue: 161 / 255) }
    static let glassInk = Color(red: 244 / 255, green: 239 / 255, blue: 232 / 255)
    static let paper = Color(red: 251 / 255, green: 248 / 255, blue: 242 / 255)
}

private struct TutuPage0AppearanceKey: EnvironmentKey {
    static let defaultValue = TutuPage0Appearance()
}
extension EnvironmentValues {
    var tutuPage0Appearance: TutuPage0Appearance {
        get { self[TutuPage0AppearanceKey.self] }
        set { self[TutuPage0AppearanceKey.self] = newValue }
    }
}

struct TutuPage0Wordmark: View {
    @Environment(\.tutuPage0Appearance) private var appearance
    var image: CGImage? = Self.bundledImage
    private static let bundledImage: CGImage? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("TutuSkin/page0/wordmark.png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()
    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
                #if TUTU_PAPER_METRICS
                .paperMeasure("wordmark")
                #endif
                .offset(y: -0.5 * appearance.scale)
        } else {
            Text("字标资源缺失")
        }
    }
}

struct TutuPage0Card<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    @Environment(\.tutuPage0Appearance) private var appearance
    var body: some View {
        content
            .background(appearance.glass ? Color.clear : TutuPage0Appearance.paper)
            .clipShape(TutuPage0CardShape())
            #if TUTU_PAPER_METRICS
            .paperMeasure("card")
            #endif
            .padding(.horizontal, 20 * appearance.scale)
    }
}

struct TutuPage0Count: View {
    let visible: Int
    let total: Int
    @Environment(\.tutuPage0Appearance) private var appearance
    var body: some View {
        Text("显示 \(visible) / \(total) 条对话")
            .font(.custom("PingFangSC-Regular", fixedSize: 12 * appearance.scale)).tracking(0.48 * appearance.scale)
            .foregroundStyle(appearance.glass ? TutuPage0Appearance.glassInk.opacity(0.42) : (visible == 0 ? Color(red: 239 / 255, green: 232 / 255, blue: 221 / 255).opacity(0.55) : Color(red: 180 / 255, green: 171 / 255, blue: 162 / 255)))
            #if TUTU_PAPER_METRICS
            .paperMeasure("text:count", text: true)
            #endif
            .offset(y: appearance.glass ? 0 : 4 * appearance.scale)
    }
}

struct TutuPage0List<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView { content }.scrollIndicators(.hidden)
    }
}

struct TutuPage0SidebarLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 402, height: 874))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let sx = bounds.width / 402, sy = sx
        for index in subviews.indices {
            let placement: (y: CGFloat, height: CGFloat)
            switch index {
            case 0: placement = (70, 44)
            case 1: placement = (135, 640)
            default: placement = (788, 44)
            }
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY + placement.y * sy),
                                 anchor: .topLeading,
                                 proposal: ProposedViewSize(width: 402 * sx, height: placement.height * sy))
        }
    }
}

struct TutuPage0CardShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(18 * rect.width / 362, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .zero, clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .zero, endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}

struct TutuPage0TabShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = 12 * rect.height / 32
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(270), endAngle: .zero, clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct TutuPage0FolderPlus: View {
    @Environment(\.tutuPage0Appearance) private var appearance
    var body: some View {
        Text("+")
            .font(.custom("PingFangSC-Thin", fixedSize: 20 * appearance.scale))
            .tracking(0.4 * appearance.scale)
            .foregroundStyle(Color(red: 239 / 255, green: 232 / 255, blue: 221 / 255).opacity(0.62))
            #if TUTU_PAPER_METRICS
            .paperMeasure("text:folder-plus", text: true)
            #endif
            .frame(width: 24 * appearance.scale, height: 32 * appearance.scale)
            #if TUTU_PAPER_METRICS
            .paperMeasure("tab:plus")
            #endif
    }
}

/// CSS `.ti` clips the complete inline run, not the session child independently.
/// Reserve the parent's ellipsis at the right edge while keeping both runs at
/// their intrinsic widths and their shared baseline.
private struct TutuPage0InlineOverflow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let intrinsic = subviews[0].sizeThatFits(.unspecified)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? intrinsic.width
        return CGSize(width: width, height: intrinsic.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let content = subviews[0].dimensions(in: .unspecified)
        let ellipsis = subviews[1].dimensions(in: .unspecified)
        let overflows = content.width > bounds.width
        let clipWidth = overflows ? max(0, bounds.width - ellipsis.width) : bounds.width
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: clipWidth, height: content.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + (overflows ? clipWidth : bounds.width),
                                     y: bounds.minY + content[.firstTextBaseline] - ellipsis[.firstTextBaseline]),
                          anchor: .topLeading, proposal: .unspecified)
    }
}

enum TutuPage0RowIcon { case code, chat, cap }
/// The original Chrome DOM resolves to PingFang SC / Menlo, not SF Pro.
/// Fixed sizes preserve CSS fractional points without Dynamic Type rounding.

struct TutuPage0Row: View {
    let title: String
    var session: String = ""
    let metadata: String
    var icon: TutuPage0RowIcon = .chat
    @Environment(\.tutuPage0Appearance) private var appearance

    var body: some View {
        let s = appearance.scale
        HStack(spacing: 15 * s) {
            TutuPage0Icon(kind: icon, glass: appearance.glass)
                .frame(width: 22 * s, height: 22 * s)
                #if TUTU_PAPER_METRICS
                .paperMeasure("icon:\(title)")
                #endif
            TutuPage0InlineOverflow {
                HStack(alignment: .firstTextBaseline, spacing: 8 * s) {
                    Text(title).font(.custom("PingFangSC-Regular", fixedSize: 16.5 * s))
                        .foregroundStyle(appearance.ink)
                        #if TUTU_PAPER_METRICS
                        .paperMeasure("text:title:\(title)", text: true)
                        #endif
                    if !session.isEmpty {
                        Text(session).font(.custom("Menlo-Regular", fixedSize: 12.5 * s))
                            .foregroundStyle(appearance.tag)
                            #if TUTU_PAPER_METRICS
                            .paperMeasure("text:session:\(title)", text: true)
                            #endif
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                Text("…").font(.custom("PingFangSC-Regular", fixedSize: 16.5 * s))
                    .foregroundStyle(appearance.ink)
                    .accessibilityHidden(true)
                    #if TUTU_PAPER_METRICS
                    .paperMeasure("ellipsis:\(title)")
                    #endif
            }
            .tracking(0.165 * s)
            .lineLimit(1)
            .clipped()
            #if TUTU_PAPER_METRICS
            .paperMeasure("inline-clip:\(title)")
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(metadata)
                .font(.custom("PingFangSC-Regular", fixedSize: 12.5 * s)).monospacedDigit()
                .foregroundStyle(appearance.dim)
                .fixedSize()
                #if TUTU_PAPER_METRICS
                .paperMeasure("text:metadata:\(title)", text: true)
                #endif
                .padding(.leading, -5 * s)
        }
        .padding(.leading, 18 * s).padding(.trailing, 20 * s)
        .frame(height: 42.3 * s)
        .overlay(alignment: .bottom) {
            Rectangle().fill(appearance.glass ? Color.white.opacity(0.075) : Color(red: 60 / 255, green: 50 / 255, blue: 40 / 255).opacity(0.07))
                .frame(height: s)
                #if TUTU_PAPER_METRICS
                .paperMeasure("separator:\(title)")
                #endif
        }
        #if TUTU_PAPER_METRICS
        .paperMeasure("row:\(title)")
        #endif
        .padding(.horizontal, 6 * s)
        .contentShape(Rectangle())
    }
}

struct TutuPage0Icon: View {
    let kind: TutuPage0RowIcon
    var glass = false
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 22, sy = size.height / 22
            var p = Path()
            func move(_ x: CGFloat, _ y: CGFloat) { p.move(to: CGPoint(x: x, y: y)) }
            func line(_ x: CGFloat, _ y: CGFloat) { p.addLine(to: CGPoint(x: x, y: y)) }
            let tint: Color
            let width: CGFloat
            let roundedCaps: Bool
            switch kind {
            case .code:
                move(6.5, 5.5); line(1.8, 11); line(6.5, 16.5)
                move(15.5, 5.5); line(20.2, 11); line(15.5, 16.5)
                move(12.6, 3.8); line(9.4, 18.2)
                tint = glass ? Color(red: 227 / 255, green: 147 / 255, blue: 122 / 255) : Color(red: 192 / 255, green: 115 / 255, blue: 91 / 255)
                width = 1.6
                roundedCaps = true
            case .chat:
                move(3.5, 3.5); line(18.5, 3.5)
                p.addQuadCurve(to: CGPoint(x: 20.5, y: 5.5), control: CGPoint(x: 20.5, y: 3.5))
                line(20.5, 14)
                p.addQuadCurve(to: CGPoint(x: 18.5, y: 16), control: CGPoint(x: 20.5, y: 16))
                line(9.2, 16); line(4.8, 19.3); line(4.8, 16); line(3.5, 16)
                p.addQuadCurve(to: CGPoint(x: 1.5, y: 14), control: CGPoint(x: 1.5, y: 16))
                line(1.5, 5.5)
                p.addQuadCurve(to: CGPoint(x: 3.5, y: 3.5), control: CGPoint(x: 1.5, y: 3.5))
                p.closeSubpath()
                tint = glass ? TutuPage0Appearance.glassInk.opacity(0.62) : Color(red: 185 / 255, green: 176 / 255, blue: 166 / 255)
                width = 1.4
                roundedCaps = false
            case .cap:
                move(11, 3); line(0.5, 8); line(11, 13); line(21.5, 8); p.closeSubpath()
                move(4.5, 10.2); line(4.5, 14.8)
                p.addCurve(to: CGPoint(x: 11, y: 17.5), control1: CGPoint(x: 6.2, y: 16.6), control2: CGPoint(x: 8.5, y: 17.5))
                p.addCurve(to: CGPoint(x: 17.5, y: 14.8), control1: CGPoint(x: 13.5, y: 17.5), control2: CGPoint(x: 15.8, y: 16.6))
                line(17.5, 10.2); move(20, 8.6); line(20, 14)
                tint = glass ? TutuPage0Appearance.glassInk.opacity(0.55) : Color(red: 169 / 255, green: 160 / 255, blue: 151 / 255)
                width = 1.4
                roundedCaps = false
            }
            context.scaleBy(x: sx, y: sy)
            context.stroke(p, with: .color(tint), style: StrokeStyle(lineWidth: width, lineCap: roundedCaps ? .round : .butt, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

struct TutuPage0EmptyContent: View {
    let title: String
    let subtitle: String
    var showImport: Bool
    var onImport: () -> Void
    @Environment(\.tutuPage0Appearance) private var appearance
    var body: some View {
        let s = appearance.scale
        ZStack(alignment: .top) {
            TutuPage0EmptyIcon().stroke(appearance.glass ? TutuPage0Appearance.glassInk.opacity(0.6) : Color(red: 201 / 255, green: 193 / 255, blue: 184 / 255),
                                       style: StrokeStyle(lineWidth: 1.5 * s, lineJoin: .round))
                .frame(width: 36 * s, height: 30 * s).offset(y: 22 * s)
            Text(title).font(.custom("PingFangSC-Semibold", fixedSize: 17 * s)).tracking(1.36 * s)
                .foregroundStyle(appearance.glass ? appearance.ink : Color(red: 58 / 255, green: 53 / 255, blue: 48 / 255)).offset(y: 55 * s)
                #if TUTU_PAPER_METRICS
                .paperMeasure("text:empty-title", text: true)
                #endif
            Text(subtitle).font(.custom("PingFangSC-Regular", fixedSize: 12.5 * s)).tracking(0.75 * s)
                .foregroundStyle(appearance.glass ? appearance.dim : Color(red: 170 / 255, green: 161 / 255, blue: 152 / 255)).offset(y: 82 * s)
                #if TUTU_PAPER_METRICS
                .paperMeasure("text:empty-subtitle", text: true)
                #endif
            if showImport {
                Button(action: onImport) {
                    HStack(spacing: 6 * s) {
                        TutuPage0ControlIcon(kind: .importRecord).frame(width: 15 * s, height: 15 * s)
                        Text("导入聊天记录").font(.custom("PingFangSC-Regular", fixedSize: 13.5 * s)).tracking(0.81 * s)
                            #if TUTU_PAPER_METRICS
                            .paperMeasure("text:import", text: true)
                            #endif
                    }
                        .foregroundStyle(appearance.glass ? appearance.ink : Color(red: 74 / 255, green: 68 / 255, blue: 62 / 255))
                        .frame(width: 126 * s, height: 31 * s)
                        .background(Capsule().fill(appearance.glass ? Color.white.opacity(0.13) : Color(red: 238 / 255, green: 235 / 255, blue: 229 / 255)))
                }
                .buttonStyle(.plain).offset(y: 110 * s)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 168 * s, alignment: .top)
    }
}

private struct TutuPage0EmptyIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 4, y: 3)); p.addLine(to: CGPoint(x: 21, y: 3))
        p.addArc(center: CGPoint(x: 21, y: 5.5), radius: 2.5, startAngle: .degrees(-90), endAngle: .zero, clockwise: false)
        p.addLine(to: CGPoint(x: 23.5, y: 14.5))
        p.addArc(center: CGPoint(x: 21, y: 14.5), radius: 2.5, startAngle: .zero, endAngle: .degrees(90), clockwise: false)
        for point in [CGPoint(x: 12, y: 17), CGPoint(x: 7, y: 20.6), CGPoint(x: 7, y: 17), CGPoint(x: 4, y: 17)] { p.addLine(to: point) }
        p.addArc(center: CGPoint(x: 4, y: 14.5), radius: 2.5, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: 1.5, y: 5.5))
        p.addArc(center: CGPoint(x: 4, y: 5.5), radius: 2.5, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        p.move(to: CGPoint(x: 27, y: 9.5)); p.addLine(to: CGPoint(x: 31.5, y: 9.5))
        p.addArc(center: CGPoint(x: 31.5, y: 12), radius: 2.5, startAngle: .degrees(-90), endAngle: .zero, clockwise: false)
        p.addLine(to: CGPoint(x: 34, y: 20.5))
        p.addArc(center: CGPoint(x: 31.5, y: 20.5), radius: 2.5, startAngle: .zero, endAngle: .degrees(90), clockwise: false)
        for point in [CGPoint(x: 30, y: 23), CGPoint(x: 30, y: 26.4), CGPoint(x: 25.4, y: 23), CGPoint(x: 17, y: 23)] { p.addLine(to: point) }
        p.addArc(center: CGPoint(x: 17, y: 20.5), radius: 2.5, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: 14.5, y: 20))
        return p.applying(CGAffineTransform(scaleX: rect.width / 36, y: rect.height / 30))
    }
}

enum TutuPage0ControlGlyph { case plus, search, filter, gear, cap, importRecord }

/// Paths and view boxes from the page0 source SVGs; no platform symbol substitution.
struct TutuPage0ControlIcon: View {
    let kind: TutuPage0ControlGlyph
    @Environment(\.tutuPage0Appearance) private var appearance
    var body: some View {
        Canvas { context, size in
            var p = Path()
            func m(_ x: CGFloat, _ y: CGFloat) { p.move(to: CGPoint(x: x, y: y)) }
            func l(_ x: CGFloat, _ y: CGFloat) { p.addLine(to: CGPoint(x: x, y: y)) }
            func arc(_ x: CGFloat, _ y: CGFloat) {
                guard let start = p.currentPoint else { return }
                let end = CGPoint(x: x, y: y)
                let dx = end.x - start.x, dy = end.y - start.y
                let distance = hypot(dx, dy)
                let offset = sqrt(max(0, 64 - distance * distance / 4))
                let center = CGPoint(x: (start.x + x) / 2 - dy / distance * offset,
                                     y: (start.y + y) / 2 + dx / distance * offset)
                p.addArc(center: center, radius: 8,
                         startAngle: .radians(atan2(start.y - center.y, start.x - center.x)),
                         endAngle: .radians(atan2(y - center.y, x - center.x)), clockwise: false)
            }
            let box: CGSize
            let tint: Color
            let width: CGFloat
            let round: Bool
            switch kind {
            case .plus:
                box = CGSize(width: 18, height: 18); width = 2; round = true
                tint = Color(red: 244 / 255, green: 239 / 255, blue: 231 / 255)
                m(9, 2); l(9, 16); m(2, 9); l(16, 9)
            case .search:
                box = CGSize(width: 20, height: 20); width = 1.8; round = true
                tint = Color(red: 239 / 255, green: 232 / 255, blue: 221 / 255).opacity(0.6)
                p.addEllipse(in: CGRect(x: 2.5, y: 2.5, width: 12, height: 12))
                m(13, 13); l(17.5, 17.5)
            case .filter:
                box = CGSize(width: 20, height: 14); width = 1.5; round = true
                tint = Color(red: 239 / 255, green: 232 / 255, blue: 221 / 255).opacity(0.55)
                m(1, 1.5); l(19, 1.5); m(4, 7); l(16, 7); m(7.5, 12.5); l(12.5, 12.5)
            case .gear:
                box = CGSize(width: 24, height: 24); width = 1.5; round = false
                tint = Color(red: 239 / 255, green: 232 / 255, blue: 221 / 255)
                p.addEllipse(in: CGRect(x: 8.8, y: 8.8, width: 6.4, height: 6.4))
                m(20.4, 13.4); l(20.5, 12); l(20.4, 10.6); l(22.4, 9); l(20.4, 5.6); l(18, 6.5)
                arc(15.6, 5.1); l(15.2, 2); l(11.2, 2); l(10.8, 4.6)
                arc(8.4, 6); l(6, 5.1); l(4, 8.5); l(6, 10.1); l(5.9, 11.5); l(6, 12.9)
                l(4, 14.5); l(6, 17.9); l(8.4, 17); arc(10.8, 18.4)
                l(11.2, 21); l(15.2, 21); l(15.6, 18.4); arc(18, 17)
                l(20.4, 17.9); l(22.4, 14.5); p.closeSubpath()
            case .cap:
                box = CGSize(width: 17, height: 14); width = 1.3; round = false
                tint = Color(red: 143 / 255, green: 174 / 255, blue: 138 / 255)
                m(8.5, 1); l(1, 4.6); l(8.5, 8.2); l(16, 4.6); p.closeSubpath()
                m(4, 6.2); l(4, 9.4)
                p.addCurve(to: CGPoint(x: 8.5, y: 11.4), control1: CGPoint(x: 5.2, y: 10.7), control2: CGPoint(x: 6.8, y: 11.4))
                p.addCurve(to: CGPoint(x: 13, y: 9.4), control1: CGPoint(x: 10.2, y: 11.4), control2: CGPoint(x: 11.8, y: 10.7))
                l(13, 6.2); m(15.2, 5); l(15.2, 9)
            case .importRecord:
                box = CGSize(width: 16, height: 16); width = 1.4; round = true
                tint = appearance.glass ? TutuPage0Appearance.glassInk.opacity(0.85) : Color(red: 90 / 255, green: 83 / 255, blue: 76 / 255)
                m(8, 1.5); l(8, 9.5); m(4.8, 6.5); l(8, 9.7); l(11.2, 6.5)
                m(2.5, 10); l(2.5, 12.6)
                p.addCurve(to: CGPoint(x: 3.9, y: 14), control1: CGPoint(x: 2.5, y: 13.4), control2: CGPoint(x: 3.2, y: 14))
                l(12.1, 14)
                p.addCurve(to: CGPoint(x: 13.5, y: 12.6), control1: CGPoint(x: 12.9, y: 14), control2: CGPoint(x: 13.5, y: 13.4))
                l(13.5, 10)
            }
            context.scaleBy(x: size.width / box.width, y: size.height / box.height)
            context.stroke(p, with: .color(tint), style: StrokeStyle(lineWidth: width, lineCap: round ? .round : .butt, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
#endif
#endif
