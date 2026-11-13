#if PERSONAL_APPS
#if os(iOS)
import SwiftUI

/// Pinned v6 .ui/.hint/.papers CSS; photo/arranging/motion controls are outside P2a.
struct TutuWuControls: View {
    let selected: String
    let choices: [(id: String, title: String)]
    var bottomInset: CGFloat = 0
    let onSelect: (String) -> Void
    private let bone = Color(red: 239/255, green: 232/255, blue: 221/255)
    private let dim = Color(red: 165/255, green: 155/255, blue: 143/255)
    private let velvet = Color(red: 12/255, green: 10/255, blue: 12/255)
    var body: some View {
        VStack(spacing: 10) {
            Text("横向轻扫 · 轻点钥匙打开应用")
                .font(.custom("Songti SC", size: 11)).tracking(2.2)
                .foregroundStyle(dim).opacity(0.85).frame(minHeight: 17.6)
            HStack(spacing: 0) {
                ForEach(choices, id: \.id) { paper in
                    Button { onSelect(paper.id) } label: {
                        Text(paper.title).font(.custom("Songti SC", size: 12)).tracking(2.4)
                            .frame(height: 18).padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 6)
                            .foregroundStyle(selected == paper.id ? velvet : dim)
                            .background(selected == paper.id ? bone : .clear, in: Capsule())
                            .contentShape(Rectangle().inset(by: -8))
                    }.buttonStyle(.plain).accessibilityAddTraits(selected == paper.id ? .isSelected : [])
                }
            }.padding(3).background(velvet.opacity(0.66), in: Capsule())
                .overlay(Capsule().strokeBorder(bone.opacity(0.16), lineWidth: 1))
                .accessibilityLabel("壁纸")
        }.padding(.horizontal, 16).padding(.bottom, 16 + bottomInset)
    }
}

struct TutuWuKeyCard: View {
    let tools: [RightPanelTool]
    let onOpen: (String) -> Void
    let onClose: () -> Void
    private let ink = Color(red: 59/255, green: 54/255, blue: 49/255)
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("应用").font(.system(size: 16.5)).tracking(0.165)
                Spacer()
                Button("收起", action: onClose).font(.system(size: 12.5))
            }.padding(20)
            if tools.isEmpty {
                Text("主屏上还没有可打开的应用")
                    .font(.system(size: 12.5)).padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(tools) { tool in
                            Button { onOpen(tool.id) } label: {
                                HStack(spacing: 15) {
                                    Image(systemName: tool.icon).frame(width: 22)
                                    Text(tool.name).font(.system(size: 16.5)).tracking(0.165)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 12.5))
                                }.padding(.horizontal, 18).frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                    .overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.07)).frame(height: 1) }
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 6)
                }.frame(maxHeight: 340)
            }
        }
        .foregroundStyle(ink)
        .background(Color(red: 251/255, green: 248/255, blue: 242/255))
        .clipShape(TutuWuPaperShape())
        .accessibilityAddTraits(.isModal)
    }
}

private struct TutuWuPaperShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(18 * rect.width / 362, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX-r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX-r, y: rect.minY+r), radius: r, startAngle: .degrees(-90), endAngle: .zero, clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY-r))
        p.addArc(center: CGPoint(x: rect.maxX-r, y: rect.maxY-r), radius: r, startAngle: .zero, endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX+r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX+r, y: rect.maxY-r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}
#endif
#endif
