import SwiftUI

/// 划线的三种样式（plan-reading-marks P2）
enum HighlightStyle: String, CaseIterable, Codable, Sendable {
    case fill, underline, pen
    var title: String {
        switch self {
        case .fill: "底色"
        case .underline: "下划线"
        case .pen: "彩笔"
        }
    }
}

/// 划线色板：默认 6 色（不放黄、不放蓝）+ 设置里自己加的。存的都是 `#RRGGBB`。
enum HighlightPalette {
    static let userDefault = "#8EBD9F"   // 薄荷（老数据：自己划的）
    static let aiDefault = "#C98A8A"     // 玫瑰（老数据：AI 划的）

    static let defaults: [(name: String, hex: String)] = [
        ("薄荷", "#8EBD9F"), ("玫瑰", "#C98A8A"), ("杏", "#E9B99A"),
        ("丁香", "#BDA8D8"), ("苔绿", "#AFC08A"), ("灰绿", "#9DB3A6"),
    ]

    static let customKey = "highlight.customColors"
    static let lastColorKey = "highlight.lastColor"
    static let lastStyleKey = "highlight.lastStyle"

    /// 设置里自己加的颜色（AppStorage 里存成逗号分隔的十六进制串，几十字节）
    static func customColors(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init).filter { hexValue($0) != nil }
    }

    static func all(customRaw: String) -> [String] {
        defaults.map(\.hex) + customColors(customRaw)
    }

    static func hexValue(_ hex: String) -> UInt? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt(s, radix: 16) else { return nil }
        return v
    }

    static func color(_ hex: String) -> Color {
        Color(hex: hexValue(hex) ?? 0x8EBD9F)
    }

    static func hex(of color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(iOS)
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        (NSColor(color).usingColorSpace(.sRGB) ?? .gray).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        let c = { (v: CGFloat) in Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}
