#if os(iOS)
import SwiftUI

/// 终端页暗底那一套颜色（照 design-terminal-rootshell-style.html）。tab 条跟终端走，不跟系统浅色切换。
enum TerminalChrome {
    /// = 终端底色（`TerminalRepresentable` 的 termBg）
    static let background = Color(red: 0.12, green: 0.11, blue: 0.10)
    static let selected = Color(red: 0.227, green: 0.208, blue: 0.196)
    static let sheet = Color(red: 0.17, green: 0.157, blue: 0.149)
    static let ink = Color(white: 0.95)
    static let dim = Color(white: 0.6)
    static let faint = Color(red: 0.353, green: 0.337, blue: 0.322)
    static let chip = Color(red: 0.812, green: 0.788, blue: 0.769)
}

extension TerminalDot {
    /// 等你 apricot / 在干活 灰绿 / 跑完 mint / 死了 灰
    var color: Color {
        switch self {
        case .waiting: return Palette.apricot
        case .working: return Palette.model
        case .done: return Palette.mint
        case .dead: return Palette.placeholder
        }
    }
}

struct TerminalStatusDot: View {
    let dot: TerminalDot?
    var size: CGFloat = 6

    var body: some View {
        if let dot {
            Circle().fill(dot.color).frame(width: size, height: size)
        }
    }
}

/// 窗口种类的小标记（plan-multi-hub B4.2a，替掉原来的 1 / 2 / 3 格号）：手机轮廓 / `>_` 灰线条，
/// 螃蟹头 / Codex 小人用 3D 里那两只的原色。图形照 design-multi-hub.html 第 7 屏的 SVG
struct TerminalCellChip: View {
    let engine: TerminalEngine
    var size: CGFloat = 13

    var body: some View {
        Canvas { context, canvas in
            switch engine {
            case .phone:
                context.scaleBy(x: canvas.width / 14, y: canvas.height / 14)
                context.stroke(Path(roundedRect: CGRect(x: 3.8, y: 1.2, width: 6.4, height: 11.6), cornerRadius: 1.6),
                               with: .color(TerminalChrome.chip), lineWidth: 1.3)
                context.fill(Path(ellipseIn: CGRect(x: 6.25, y: 9.95, width: 1.5, height: 1.5)), with: .color(TerminalChrome.chip))
            case .shell:
                context.scaleBy(x: canvas.width / 14, y: canvas.height / 14)
                var path = Path()
                path.addLines([CGPoint(x: 2.2, y: 3.6), CGPoint(x: 5.6, y: 7), CGPoint(x: 2.2, y: 10.4)])
                path.move(to: CGPoint(x: 7.2, y: 11))
                path.addLine(to: CGPoint(x: 12, y: 11))
                context.stroke(path, with: .color(TerminalChrome.chip),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            case .claude:
                context.scaleBy(x: canvas.width / 17, y: canvas.height / 17)
                context.translateBy(x: 0, y: 3.5)
                for (x, y, w, h) in Self.crabBody {
                    context.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(Self.crab))
                }
                for x in [4.0, 12.0] {
                    context.fill(Path(CGRect(x: x, y: 2, width: 1, height: 2)), with: .color(Self.crabEye))
                }
            case .codex:
                context.scaleBy(x: canvas.width / 14, y: canvas.height / 14)
                context.fill(Path(ellipseIn: CGRect(x: 7.5, y: 0.8, width: 4.2, height: 4.2)), with: .color(Color(hex: 0x6c99fa)))
                context.fill(Path(ellipseIn: CGRect(x: 0.8, y: 1.7, width: 12.4, height: 9.8)), with: .color(Color(hex: 0x5a85f7)))
                context.fill(Path(roundedRect: CGRect(x: 2.9, y: 4.4, width: 8.2, height: 4.6), cornerRadius: 1.5),
                             with: .color(Color(hex: 0x232d66)))
                var prompt = Path()
                prompt.addLines([CGPoint(x: 4.3, y: 5.5), CGPoint(x: 5.7, y: 6.7), CGPoint(x: 4.3, y: 7.9)])
                prompt.move(to: CGPoint(x: 6.6, y: 7.9))
                prompt.addLine(to: CGPoint(x: 9.3, y: 7.9))
                context.stroke(prompt, with: .color(Color(hex: 0x9dfcff)),
                               style: StrokeStyle(lineWidth: 0.95, lineCap: .round, lineJoin: .round))
                for x in [4.4, 7.6] {
                    context.fill(Path(roundedRect: CGRect(x: x, y: 11, width: 2, height: 2.4), cornerRadius: 0.6),
                                 with: .color(Color(hex: 0x486ce4)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(engine.displayName)
    }

    private static let crab = Color(hex: 0xD77757)
    private static let crabEye = Color(hex: 0x1F1C1A)
    private static let crabBody: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (2, 0, 13, 4), (0, 4, 17, 2), (2, 6, 13, 2), (2, 8, 1, 2), (4, 8, 1, 2), (12, 8, 1, 2), (14, 8, 1, 2),
    ]
}

/// 电脑名灰标签（≥2 台时紧贴标题）
struct TerminalHubTag: View {
    let name: String
    var size: CGFloat = 10

    var body: some View {
        Text(name)
            .font(.system(size: size))
            .foregroundColor(Color(hex: 0xa9a29b))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
            .frame(maxWidth: 84, alignment: .leading)
            .layoutPriority(1)
    }
}
#endif
