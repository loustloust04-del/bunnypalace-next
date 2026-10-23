import SwiftUI

/// 推特子应用的强调色。
///
/// **默认是推特蓝，这是粟粟 2026-09-21 明确拍板的**——她看过 HTML 仿版后说
/// 「推特蓝（设置自己换色）」。这一条**有意偏离** `.claude/rules/swiftui-ui.md`
/// 里「不要蓝色」的全局规则：那条管的是记忆花园整体的设计语言，
/// 而这个子应用要像推特。**别照着规则把它改回绿的**，要改先问粟粟。
enum TwitterAccent {

    struct Preset: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let defaultHex = "#1D9BF0"

    static let presets: [Preset] = [
        Preset(name: "推特蓝", hex: "#1D9BF0"),
        Preset(name: "薄荷绿", hex: "#8EBD9F"),
        Preset(name: "紫", hex: "#6364FF"),
        Preset(name: "陶土", hex: "#D97757"),
        Preset(name: "墨", hex: "#141413"),
    ]

    /// 解析 `#RRGGBB` / `RRGGBB`，大小写不限、两端空白不限。解不动返回 nil。
    static func rgb(fromHex hex: String) -> (r: Double, g: Double, b: Double)? {
        var body = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("#") { body.removeFirst() }
        guard body.count == 6 else { return nil }
        // Int(_:radix:) 会放行 "+1D9BF" 这类，所以先自己验一遍字符集
        guard body.allSatisfy({ $0.isHexDigit }), let value = Int(body, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }

    /// 规范形态：大写 + 带 `#`。解不动返回 nil。
    static func normalized(_ hex: String) -> String? {
        var body = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("#") { body.removeFirst() }
        guard body.count == 6, body.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + body.uppercased()
    }

    /// 存进 AppStorage 前过一道：用户手填的垃圾不能把界面画成黑块。
    static func hexOrFallback(_ hex: String) -> String { normalized(hex) ?? defaultHex }

    static func color(fromHex hex: String) -> Color {
        guard let c = rgb(fromHex: hex) ?? rgb(fromHex: defaultHex) else { return .accentColor }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }
}
