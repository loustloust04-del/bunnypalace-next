import SwiftUI

/// 便利贴本体：12 种纸（docs/design-page1-笔刷与便利贴.html 同款）。贴在画布 / 面板缩略 / 贴纸库 / 导出 PNG / 原地编辑共用。
/// `text` 给 Binding 就是编辑态（纸上直接打字）。
struct NoteView: View {
    let spec: NoteSpec
    @Binding var text: String
    var editable = false
    var width: CGFloat = 168
    var focus: FocusState<Bool>.Binding? = nil
    /// 导出 PNG（ImageRenderer 画不出毛玻璃材质，描图纸改用半透白）
    var exporting = false

    init(spec: NoteSpec, text: String, width: CGFloat = 168, exporting: Bool = false) {
        self.spec = spec
        _text = .constant(text)
        self.width = width
        self.exporting = exporting
    }

    init(spec: NoteSpec, editing: Binding<String>, width: CGFloat = 168, focus: FocusState<Bool>.Binding? = nil) {
        self.spec = spec
        _text = editing
        editable = true
        self.width = width
        self.focus = focus
    }

    private var scale: CGFloat { width / 168 }
    private var fontSize: CGFloat { 15 * scale }
    private var line: CGFloat { 24 * scale }
    private var paper: Color { Color(cgColor: BrushEngine.cgColor(spec.color ?? "#fffdf6")) }
    private var ink: Color { spec.kind == .kraft ? Color(red: 0.24, green: 0.17, blue: 0.1) : Color(red: 0.23, green: 0.21, blue: 0.18) }

    var body: some View {
        content
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var words: some View {
        let font = spec.kind == .receipt && spec.font == .system ? NoteFont.type.font(fontSize * 0.88) : spec.font.font(fontSize)
        Group {
            if editable {
                TextField("写点什么…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .modifier(OptionalFocus(focus: focus))
            } else {
                Text(text.isEmpty ? " " : text)
            }
        }
        .font(font)
        .foregroundStyle(ink)
        .lineSpacing(max(0, line - fontSize * 1.25))
        .frame(maxWidth: .infinity, minHeight: line * 3, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        switch spec.kind {
        case .sticky:
            words.padding(.horizontal, 16 * scale).padding(.vertical, 18 * scale)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 3, bottomTrailingRadius: 16 * scale, topTrailingRadius: 2)
                        .fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4)))
                        .background(UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 3, bottomTrailingRadius: 16 * scale, topTrailingRadius: 2).fill(paper))
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 3, bottomTrailingRadius: 16 * scale, topTrailingRadius: 2)
                            .fill(LinearGradient(colors: [.clear, Color(red: 0.47, green: 0.35, blue: 0.16).opacity(0.13)], startPoint: UnitPoint(x: 0.75, y: 0.75), endPoint: .bottomTrailing)))
                        .shadow(color: Color(red: 0.27, green: 0.2, blue: 0.08).opacity(0.3), radius: 7 * scale, x: 6 * scale, y: 8 * scale)
                )
        case .lined, .spiral:
            words.padding(.leading, spec.kind == .lined ? 38 * scale : 14 * scale).padding(.trailing, 12 * scale)
                .padding(.top, (spec.kind == .spiral ? 28 : 22) * scale).padding(.bottom, 12 * scale)
                .background(LinedPaper(line: line, top: (spec.kind == .spiral ? 26 : 20) * scale, margin: spec.kind == .lined ? 30 * scale : nil,
                                       holes: spec.kind == .spiral, scale: scale))
                .compositingGroup()   // 不压成一层的话阴影会落到每个字上（字周围一圈灰雾）
                .shadow(color: .black.opacity(0.14), radius: 5 * scale, y: 4 * scale)
        case .grid:
            words.padding(16 * scale)
                .background(GridPaper(step: 12 * scale))
                .compositingGroup()
                .shadow(color: .black.opacity(0.14), radius: 5 * scale, y: 4 * scale)
        case .kraft:
            words.padding(.horizontal, 16 * scale).padding(.vertical, 18 * scale)
                .background(Fibers(base: Color(red: 0.78, green: 0.65, blue: 0.48)))
                .compositingGroup()
                .shadow(color: .black.opacity(0.18), radius: 5 * scale, y: 4 * scale)
        case .index:
            words.padding(.horizontal, 14 * scale).padding(.top, 9 * scale).padding(.bottom, 10 * scale)
                .background(IndexCard(line: line, header: 38 * scale))
                .compositingGroup()
                .shadow(color: .black.opacity(0.15), radius: 5 * scale, y: 4 * scale)
        case .polaroid:
            VStack(spacing: 6 * scale) {
                LinearGradient(colors: [paper, Color(red: 0.96, green: 0.91, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(height: 118 * scale)
                    .overlay(Rectangle().stroke(.black.opacity(0.05), lineWidth: 1))
                words.multilineTextAlignment(.center).frame(minHeight: 30 * scale)
            }
            .padding([.horizontal, .top], 10 * scale).padding(.bottom, 8 * scale)
            .background(Color(red: 1, green: 0.995, blue: 0.985))
            .compositingGroup()
            .shadow(color: .black.opacity(0.18), radius: 6 * scale, y: 5 * scale)
        case .receipt:
            words.padding(.horizontal, 14 * scale).padding(.top, 16 * scale).padding(.bottom, 24 * scale)
                .background(Color(red: 1, green: 0.995, blue: 0.98))
                .clipShape(ZigzagBottom(tooth: 12 * scale, depth: 8 * scale))
                .compositingGroup()
                .shadow(color: .black.opacity(0.14), radius: 5 * scale, y: 4 * scale)
        case .torn:
            words.padding(.horizontal, 22 * scale).padding(.vertical, 16 * scale)
                .background(TornEdges(seed: 7).fill(paper))
                .compositingGroup()
                .shadow(color: .black.opacity(0.16), radius: 5 * scale, y: 4 * scale)
        case .fold:
            words.padding(16 * scale).padding(.trailing, 10 * scale)
                .background(FoldedCorner(fold: 26 * scale, paper: paper))
                .compositingGroup()
                .shadow(color: .black.opacity(0.16), radius: 5 * scale, y: 4 * scale)
        case .tape:
            words.padding(.horizontal, 16 * scale).padding(.top, 24 * scale).padding(.bottom, 16 * scale)
                .background(Color(red: 1, green: 0.99, blue: 0.97))
                .compositingGroup()
                .shadow(color: .black.opacity(0.14), radius: 5 * scale, y: 4 * scale)
                .overlay(alignment: .topLeading) { Tape(color: paper).frame(width: 70 * scale, height: 20 * scale).rotationEffect(.degrees(-28)).offset(x: -14 * scale, y: -6 * scale) }
                .overlay(alignment: .topTrailing) { Tape(color: paper).frame(width: 70 * scale, height: 20 * scale).rotationEffect(.degrees(28)).offset(x: 14 * scale, y: -6 * scale) }
        case .vellum:
            words.padding(.horizontal, 16 * scale).padding(.vertical, 18 * scale)
                .background { if exporting { Color.white.opacity(0.85) } else { Rectangle().fill(.ultraThinMaterial) } }
                .background(Color.white.opacity(0.45))
                .overlay(Rectangle().stroke(.white.opacity(0.8), lineWidth: 1))
                .compositingGroup()
                .shadow(color: .black.opacity(0.12), radius: 8 * scale, y: 5 * scale)
        }
    }
}

private struct OptionalFocus: ViewModifier {
    let focus: FocusState<Bool>.Binding?
    func body(content: Content) -> some View {
        if let focus { content.focused(focus) } else { content }
    }
}

// MARK: - 纸

private struct LinedPaper: View {
    let line: CGFloat, top: CGFloat
    let margin: CGFloat?
    let holes: Bool
    let scale: CGFloat
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 1, green: 0.99, blue: 0.965)))
            var y = top + line - 1
            while y < size.height - 4 {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Color(red: 0.79, green: 0.86, blue: 0.88)))
                y += line
            }
            if let margin { ctx.fill(Path(CGRect(x: margin, y: 0, width: 1, height: size.height)), with: .color(Color(red: 0.84, green: 0.47, blue: 0.43).opacity(0.55))) }
            if holes {
                // 线圈孔真打穿（看得到下面）
                ctx.blendMode = .destinationOut
                var x: CGFloat = 15 * scale
                while x < size.width - 6 { ctx.fill(Path(ellipseIn: CGRect(x: x - 4.5 * scale, y: 4.5 * scale, width: 9 * scale, height: 9 * scale)), with: .color(.black)); x += 18 * scale }
            }
        }
    }
}

private struct GridPaper: View {
    let step: CGFloat
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.985, green: 0.98, blue: 0.955)))
            var p = Path()
            for x in stride(from: CGFloat(0), through: size.width, by: step) { p.addRect(CGRect(x: x, y: 0, width: 0.6, height: size.height)) }
            for y in stride(from: CGFloat(0), through: size.height, by: step) { p.addRect(CGRect(x: 0, y: y, width: size.width, height: 0.6)) }
            ctx.fill(p, with: .color(Color(red: 0.59, green: 0.7, blue: 0.67).opacity(0.4)))
        }
    }
}

private struct Fibers: View {
    let base: Color
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            var rng = BrushRandom(seed: 11)
            for _ in 0..<Int(size.width * size.height / 30) {
                let x = rng.unit() * size.width, y = rng.unit() * size.height, l = 1 + rng.unit() * 4
                ctx.fill(Path(CGRect(x: x, y: y, width: l, height: 0.6)), with: .color(Color(red: 0.35, green: 0.25, blue: 0.12).opacity(0.08 + rng.unit() * 0.12)))
            }
        }
    }
}

private struct IndexCard: View {
    let line: CGFloat, header: CGFloat
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            ctx.fill(Path(CGRect(x: 0, y: header, width: size.width, height: 1)), with: .color(Color(red: 0.84, green: 0.39, blue: 0.39).opacity(0.6)))
            var y = header + line
            while y < size.height - 4 { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Color(red: 0.84, green: 0.89, blue: 0.92))); y += line }
        }
    }
}

private struct ZigzagBottom: Shape {
    let tooth: CGFloat, depth: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: r.maxX, y: 0))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - depth))
        var x = r.maxX
        var down = true
        while x > 0 {
            x -= tooth / 2
            p.addLine(to: CGPoint(x: max(0, x), y: down ? r.maxY : r.maxY - depth))
            down.toggle()
        }
        p.closeSubpath()
        return p
    }
}

private struct TornEdges: Shape {
    let seed: UInt64
    func path(in r: CGRect) -> Path {
        var rng = BrushRandom(seed: seed)
        var p = Path()
        let step: CGFloat = 6, j = min(9, r.width * 0.06)
        p.move(to: CGPoint(x: rng.unit() * j, y: 0))
        p.addLine(to: CGPoint(x: r.maxX - rng.unit() * j, y: 0))
        var y: CGFloat = step
        while y < r.maxY { p.addLine(to: CGPoint(x: r.maxX - rng.unit() * j, y: y)); y += step }
        p.addLine(to: CGPoint(x: r.maxX - rng.unit() * j, y: r.maxY))
        p.addLine(to: CGPoint(x: rng.unit() * j, y: r.maxY))
        y = r.maxY - step
        while y > 0 { p.addLine(to: CGPoint(x: rng.unit() * j, y: y)); y -= step }
        p.closeSubpath()
        return p
    }
}

private struct FoldedCorner: View {
    let fold: CGFloat
    let paper: Color
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topTrailing) {
                Path { p in
                    p.move(to: .zero); p.addLine(to: CGPoint(x: w - fold, y: 0)); p.addLine(to: CGPoint(x: w, y: fold))
                    p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
                }
                .fill(paper)
                Path { p in
                    p.move(to: CGPoint(x: w - fold, y: 0)); p.addLine(to: CGPoint(x: w - fold, y: fold)); p.addLine(to: CGPoint(x: w, y: fold)); p.closeSubpath()
                }
                .fill(LinearGradient(colors: [paper.opacity(0.9), Color.black.opacity(0.12)], startPoint: .bottomLeading, endPoint: .topTrailing))
                .background(Path { p in
                    p.move(to: CGPoint(x: w - fold, y: 0)); p.addLine(to: CGPoint(x: w - fold, y: fold)); p.addLine(to: CGPoint(x: w, y: fold)); p.closeSubpath()
                }.fill(paper))
            }
        }
    }
}

private struct Tape: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = -size.height
            var on = true
            while x < size.width + size.height {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                p.addLine(to: CGPoint(x: x + size.height + 6, y: 0)); p.addLine(to: CGPoint(x: x + 6, y: size.height)); p.closeSubpath()
                ctx.fill(p, with: .color(color.opacity(on ? 0.85 : 0.55)))
                x += 6; on.toggle()
            }
        }
        .opacity(0.92)
    }
}
