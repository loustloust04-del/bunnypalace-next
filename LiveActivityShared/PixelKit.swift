import SwiftUI

enum PixelFont {
    static let postScriptName = "Silkscreen-Regular"

    enum Size: CGFloat {
        case small = 8
        case body = 12
        case large = 16
    }

    static func font(_ size: Size) -> Font {
        .custom(postScriptName, size: size.rawValue)
    }
}

struct PixelScanlines: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(.black.opacity(0.28))
                )
                y += 2
            }
        }
        .accessibilityHidden(true)
    }
}

enum Palette {
    static let ink = Color(white: 0.91)
    static let dim = Color(white: 0.55)
    static let placeholder = Color(white: 0.29)
    static let frame = Color(white: 0.91).opacity(0.35)
    static let edge = Color(red: 0.55, green: 0.62, blue: 0.71).opacity(0.22)
    static let model = Color(red: 0.56, green: 0.66, blue: 0.61)

    static let mint = Color(red: 0.53, green: 0.84, blue: 0.69)
    static let apricot = Color(red: 1.00, green: 0.69, blue: 0.37)
    static let berry = Color(red: 1.00, green: 0.53, blue: 0.53)

    static func usage(_ percent: Int) -> Color {
        switch percent {
        case ..<40: return mint
        case ..<70: return apricot
        default: return berry
        }
    }
}

extension View {
    func pixelGlow(_ color: Color) -> some View {
        self
            .shadow(color: color.opacity(0.85), radius: 1)
            .shadow(color: color.opacity(0.45), radius: 2)
    }
}
