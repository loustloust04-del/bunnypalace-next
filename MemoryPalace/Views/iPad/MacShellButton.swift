#if os(macOS)
import SwiftUI

struct MacShellLabel: View {
    let symbol: String
    var title: String? = nil
    var chevron = false

    var body: some View {
        HStack(spacing: 6) {
            if AppIconView.isAssetName(symbol) {
                AppIconView(name: symbol, size: ShellStyle.iconSize, tint: nil)
            } else {
                Image(systemName: symbol)
                    .font(ShellStyle.iconFont)
                    .symbolRenderingMode(.monochrome)
                    .frame(width: ShellStyle.iconSize)
            }
            if let title {
                Text(title)
                    .font(ShellStyle.bodyFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if chevron {
                Image(systemName: "chevron.down")
                    .font(ShellStyle.iconFont)
            }
        }
    }
}

struct MacShellButton: ButtonStyle {
    var selected = false
    var compact = false
    var width: CGFloat? = nil
    var height: CGFloat = ShellStyle.tabHeight
    var horizontalPadding: CGFloat = 10
    var pointerHovered = false
    var pointerPressed = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, style: self)
    }

    private struct Face: View {
        let configuration: Configuration
        let style: MacShellButton
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(ShellStyle.bodyFont)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(style.selected ? ShellStyle.text : ShellStyle.secondaryText)
                .padding(.horizontal, style.width == nil ? style.horizontalPadding : 0)
                .frame(width: style.width, height: style.compact ? ShellStyle.chipHeight : style.height)
                .modifier(MacShellControlSurface(selected: style.selected, hovered: hovered || style.pointerHovered,
                    pressed: configuration.isPressed || style.pointerPressed, compact: style.compact))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
        }
    }
}

struct MacShellControlSurface: ViewModifier {
    var selected = false
    var hovered = false
    var pressed = false
    var compact = false

    func body(content: Content) -> some View {
        content
            .background(ShellStyle.controlFill(selected: selected, hovered: hovered, pressed: pressed),
                in: RoundedRectangle(cornerRadius: compact ? ShellStyle.chipRadius : ShellStyle.controlRadius))
            .contentShape(Rectangle())
            .animation(ShellStyle.feedback, value: hovered)
            .animation(ShellStyle.feedback, value: pressed)
            .animation(ShellStyle.feedback, value: selected)
    }
}

struct MacShellWidgetSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(ShellStyle.background)
            .clipShape(RoundedRectangle(cornerRadius: ShellStyle.cellRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ShellStyle.cellRadius, style: .continuous)
                    .strokeBorder(ShellStyle.hairline, lineWidth: ShellStyle.hairlineWidth)
                    .allowsHitTesting(false)
            }
    }
}
#endif
