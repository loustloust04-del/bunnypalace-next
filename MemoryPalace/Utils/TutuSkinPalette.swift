#if PERSONAL_APPS
import SwiftUI

/// 兔兔皮肤的固定配色，不写回用户主题；关闭皮肤后由 Theme 恢复原主题。
enum TutuSkinPalette {
    static let tokens = ThemeTokenSet(
        mainBg: ThemeColorValue(hex: 0x120E11),
        sidebarBg: ThemeColorValue(hex: 0x1B1419),
        userBubble: ThemeColorValue(hex: 0x321C27),
        assistantBubble: ThemeColorValue(hex: 0x21191E),
        accent: ThemeColorValue(hex: 0x8C3652),
        textPrimary: ThemeColorValue(hex: 0xF3EBDD),
        textSecondary: ThemeColorValue(hex: 0xC9BBAF),
        textMuted: ThemeColorValue(hex: 0x9C8B86),
        userText: ThemeColorValue(hex: 0x2A221F),
        assistantText: ThemeColorValue(hex: 0x48212A),
        favorite: ThemeColorValue(hex: 0xC5A368),
        danger: ThemeColorValue(hex: 0xCC7184),
        branchIndicator: ThemeColorValue(hex: 0xA86178)
    )
}
#endif
