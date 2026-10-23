import SwiftUI

/// 调色条（plan-reading-marks P2-2）：读书划完浮在底部；时间线小窗里点色块也用它。左边三种样式，中间色板，右边撤掉这道。
/// 点什么立刻改这道线，同时记成下次划线的默认。
struct HighlightPaletteBar: View {
    let colorHex: String
    let style: HighlightStyle
    var onChange: (String, HighlightStyle) -> Void
    var onDelete: () -> Void

    @AppStorage(HighlightPalette.customKey) private var customColorsRaw = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(HighlightStyle.allCases, id: \.self) { s in
                Button { onChange(colorHex, s) } label: {
                    StyleGlyph(style: s, color: HighlightPalette.color(colorHex))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(s == style ? Theme.textPrimary.opacity(0.08) : .clear))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.title)
                .accessibilityAddTraits(s == style ? .isSelected : [])
            }
            Rectangle().fill(Theme.textMuted.opacity(0.25)).frame(width: 1, height: 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HighlightPalette.all(customRaw: customColorsRaw), id: \.self) { hex in
                        Circle()
                            .fill(HighlightPalette.color(hex))
                            .frame(width: 24, height: 24)
                            .padding(3)
                            .overlay(Circle().strokeBorder(Theme.textPrimary.opacity(hex == colorHex ? 0.7 : 0), lineWidth: 1.5))
                            .contentShape(Circle())
                            .onTapGesture { onChange(hex, style) }
                            .accessibilityLabel(HighlightPalette.defaults.first { $0.hex == hex }?.name ?? "自定义颜色")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.horizontal, 4)
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("撤掉这道划线")
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        #if os(iOS)
        .glassEffect(.regular, in: .capsule)
        #else
        .background(Theme.sidebarBg, in: Capsule())
        #endif
    }
}

/// 样式按钮上的小字：底色 = 字垫色块，下划线 = 字下一道线，彩笔 = 字下半截一笔马克笔
private struct StyleGlyph: View {
    let style: HighlightStyle
    let color: Color

    var body: some View {
        Text("字")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 2)
            .background(alignment: .bottom) {
                switch style {
                case .fill:
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.45))
                case .underline:
                    Capsule().fill(color).frame(height: 2).offset(y: 2)
                case .pen:
                    Capsule().fill(color.opacity(0.6)).frame(height: 8).rotationEffect(.degrees(-3)).offset(y: -1)
                }
            }
    }
}
