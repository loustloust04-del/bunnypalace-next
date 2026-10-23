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

/// 格标：小方块里的 1 / 2 / 3（圈号在小字号下会糊，rootshell 小样第 6 条）
struct TerminalCellChip: View {
    let cell: TerminalCell

    var body: some View {
        Text("\(cell.rawValue)")
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundColor(TerminalChrome.chip)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.1)))
    }
}
#endif
