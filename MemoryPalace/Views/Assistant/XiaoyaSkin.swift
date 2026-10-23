import SwiftUI

// MARK: - 小芽 v2 · 聊天区皮肤（plan-小芽-v2 §3.3 / §3.6）
// 舞台自带颜色（XiaoyaStageTheme），这里只管下面的聊天区：跟 app 亮暗主题走。
// 亮色纸从奶黄改成偏灰（粟粟 09-26「太黄了」）；浅灰薄荷只点一层（你的气泡）。

struct XiaoyaSkin {
    var paper: Color
    var card: Color
    var line: Color
    var ink: Color
    var inkSoft: Color
    var inkMuted: Color
    var mint: Color

    static func current(_ scheme: ColorScheme) -> XiaoyaSkin {
        scheme == .dark ? .night : .cream
    }

    static let cream = XiaoyaSkin(
        paper: Color(red: 0.953, green: 0.953, blue: 0.937),
        card: Color(red: 0.980, green: 0.980, blue: 0.969),
        line: Color(red: 0.886, green: 0.886, blue: 0.855),
        ink: Color(red: 0.118, green: 0.239, blue: 0.149),
        inkSoft: Color(red: 0.306, green: 0.388, blue: 0.322),
        inkMuted: Color(red: 0.541, green: 0.588, blue: 0.545),
        mint: Color(red: 0.863, green: 0.906, blue: 0.875)
    )

    static let night = XiaoyaSkin(
        paper: Color(red: 0.106, green: 0.118, blue: 0.110),
        card: Color(red: 0.137, green: 0.165, blue: 0.145),
        line: Color(red: 0.204, green: 0.251, blue: 0.227),
        ink: Color(red: 0.910, green: 0.886, blue: 0.816),
        inkSoft: Color(red: 0.725, green: 0.761, blue: 0.710),
        inkMuted: Color(red: 0.494, green: 0.545, blue: 0.502),
        mint: Color(red: 0.180, green: 0.239, blue: 0.200)
    )
}
