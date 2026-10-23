import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum AppThemeMode: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        }
    }

    var subtitle: String {
        switch self {
        case .system:
            return "自动跟着系统切换"
        case .light:
            return "始终使用浅色界面"
        case .dark:
            return "始终使用深色界面"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

struct ThemeColorValue: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    init(color: Color) {
        #if os(macOS)
        let native = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.white
        #else
        let native = UIColor(color)
        #endif

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        native.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        self.init(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var hexString: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    func withAlpha(_ alpha: Double) -> ThemeColorValue {
        ThemeColorValue(red: red, green: green, blue: blue, alpha: alpha)
    }

    func multipliedAlpha(_ multiplier: Double) -> ThemeColorValue {
        withAlpha(max(0, min(1, alpha * multiplier)))
    }

    /// 从 HSB 建色（颜色页「微调」两根条写回用，plan-theme-decouple D2 加不换）。
    init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        self = Self.colorValue(
            from: Self.makePlatformColor(
                hue: CGFloat(hue),
                saturation: CGFloat(max(0, min(1, saturation))),
                brightness: CGFloat(max(0, min(1, brightness))),
                alpha: CGFloat(alpha)
            )
        )
    }

    /// HSB 分量（0…1），读法与 `adjustedBrightness` 同一路；灰色（饱和度 0）的色相无定义，读出来是 0。
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        #if os(macOS)
        let source = platformColor.usingColorSpace(.deviceRGB) ?? platformColor
        source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        #else
        guard platformColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return (0, 0, 0)
        }
        #endif

        return (Double(hue), Double(saturation), Double(brightness))
    }

    func adjustedBrightness(_ brightness: Double, saturation: Double? = nil) -> ThemeColorValue {
        var hue: CGFloat = 0
        var currentSaturation: CGFloat = 0
        var currentBrightness: CGFloat = 0
        var alpha: CGFloat = 0

        #if os(macOS)
        let source = platformColor.usingColorSpace(.deviceRGB) ?? platformColor
        source.getHue(&hue, saturation: &currentSaturation, brightness: &currentBrightness, alpha: &alpha)
        #else
        let source = platformColor
        guard source.getHue(&hue, saturation: &currentSaturation, brightness: &currentBrightness, alpha: &alpha) else {
            return self
        }
        #endif

        return Self.colorValue(
            from: Self.makePlatformColor(
                hue: hue,
                saturation: saturation.map { CGFloat($0) } ?? currentSaturation,
                brightness: CGFloat(brightness),
                alpha: alpha
            )
        )
    }

    private static func makePlatformColor(
        hue: CGFloat,
        saturation: CGFloat,
        brightness: CGFloat,
        alpha: CGFloat
    ) -> PlatformColor {
        #if os(macOS)
        return NSColor(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: alpha
        )
        #else
        return UIColor(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: alpha
        )
        #endif
    }

    private static func colorValue(from color: PlatformColor) -> ThemeColorValue {
        #if os(macOS)
        let source = color.usingColorSpace(.deviceRGB) ?? color
        #else
        let source = color
        #endif

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        source.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return ThemeColorValue(red: red, green: green, blue: blue, alpha: alpha)
    }

    #if os(macOS)
    typealias PlatformColor = NSColor
    var platformColor: NSColor {
        NSColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
    #else
    typealias PlatformColor = UIColor
    var platformColor: UIColor {
        UIColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
    #endif
}

struct ThemeTokenSet: Codable, Hashable {
    var mainBg: ThemeColorValue
    var sidebarBg: ThemeColorValue
    var userBubble: ThemeColorValue
    /// 你的气泡渐变第二色（plan-bubble-gradient）：`nil` = 单色照旧；设了 = 「userBubble → 它」自上而下、锚在聊天区的渐变
    /// （画法见 `UserBubbleFill`）。只有你的气泡有，AI 泡不做。老 JSON 没这格，optional 合成 Codable 解成 nil，零迁移。
    var userBubbleGradient: ThemeColorValue?
    var assistantBubble: ThemeColorValue
    var accent: ThemeColorValue
    var textPrimary: ThemeColorValue
    var textSecondary: ThemeColorValue
    var textMuted: ThemeColorValue
    /// 聊天正文字色，按角色分开（plan-theme-decouple M1）。`nil` = 跟随 `textPrimary`——
    /// 改「主文字」时聊天跟着变是默认行为，单独设过才脱钩，↺ 写回 nil 即恢复跟随。
    /// 只管聊天正文，列表页 / 仪表盘 / 设置永远跟 `textPrimary`。
    var userText: ThemeColorValue?
    var assistantText: ThemeColorValue?
    var favorite: ThemeColorValue
    var danger: ThemeColorValue
    var branchIndicator: ThemeColorValue

    /// 默认浅色主题：从粟粟「我的主题 副本」迁过来（2026-06-14）—— 背景偏暖白，
    /// 侧栏/用户气泡浅绿调，AI 气泡半透明灰。文字/功能色保持原默认。
    static let palaceLightDefault = ThemeTokenSet(
        mainBg: ThemeColorValue(red: 1.0, green: 0.98822, blue: 0.97253),
        sidebarBg: ThemeColorValue(red: 0.92970, green: 0.95683, blue: 0.93724),
        userBubble: ThemeColorValue(red: 0.94116, green: 0.95685, blue: 0.93724),
        assistantBubble: ThemeColorValue(red: 0.92155, green: 0.92155, blue: 0.92155, alpha: 0),
        accent: ThemeColorValue(hex: 0xE7EEEC),
        textPrimary: ThemeColorValue(red: 0.24, green: 0.21, blue: 0.20),
        textSecondary: ThemeColorValue(red: 0.50, green: 0.47, blue: 0.44),
        textMuted: ThemeColorValue(red: 0.68, green: 0.65, blue: 0.62),
        favorite: ThemeColorValue(red: 0.94, green: 0.80, blue: 0.56),
        danger: ThemeColorValue(red: 0.88, green: 0.52, blue: 0.52),
        branchIndicator: ThemeColorValue(hex: 0x8EBD9F)
    )

    static let palaceDarkDefault = ThemeTokenSet(
        mainBg: ThemeColorValue(hex: 0x121311),
        sidebarBg: ThemeColorValue(hex: 0x171916),
        userBubble: ThemeColorValue(hex: 0x1C1F1B),
        assistantBubble: ThemeColorValue(hex: 0x20231F),
        accent: ThemeColorValue(hex: 0x27302D),
        textPrimary: ThemeColorValue(hex: 0xEEE7DF),
        textSecondary: ThemeColorValue(hex: 0xC8C0B6),
        textMuted: ThemeColorValue(hex: 0x948E86),
        favorite: ThemeColorValue(hex: 0xD6B06F),
        danger: ThemeColorValue(hex: 0xD77D7D),
        branchIndicator: ThemeColorValue(hex: 0x7FB993)
    )

    var previewColors: [Color] {
        [
            mainBg.color,
            sidebarBg.color,
            accent.color,
            branchIndicator.color
        ]
    }

    func tokens(for scheme: ColorScheme) -> ThemeTokenSet {
        self
    }

    func applyingPureBackground(for scheme: ColorScheme) -> ThemeTokenSet {
        var copy = self

        switch scheme {
        case .light:
            copy.mainBg = ThemeColorValue(hex: 0xFFFFFF)
            copy.sidebarBg = ThemeColorValue(hex: 0xF7F7F7)
            copy.userBubble = ThemeColorValue(hex: 0xF7F7F7)
            copy.userBubbleGradient = nil
            copy.assistantBubble = ThemeColorValue(hex: 0xF1F1F1)
        case .dark:
            copy.mainBg = ThemeColorValue(hex: 0x000000)
            copy.sidebarBg = ThemeColorValue(hex: 0x0B0B0B)
            copy.userBubble = ThemeColorValue(hex: 0x101010)
            copy.userBubbleGradient = nil
            copy.assistantBubble = ThemeColorValue(hex: 0x151515)
        @unknown default:
            break
        }

        return copy
    }

    func applyingBackgroundImageSurfaceStyle(for scheme: ColorScheme) -> ThemeTokenSet {
        var copy = self

        switch scheme {
        case .light:
            copy.userBubble = copy.userBubble.multipliedAlpha(0.90)
            copy.userBubbleGradient = copy.userBubbleGradient?.multipliedAlpha(0.90)
            copy.assistantBubble = copy.assistantBubble.multipliedAlpha(0.90)
            copy.accent = copy.accent.multipliedAlpha(0.76)
        case .dark:
            copy.userBubble = copy.userBubble.multipliedAlpha(0.84)
            copy.userBubbleGradient = copy.userBubbleGradient?.multipliedAlpha(0.84)
            copy.assistantBubble = copy.assistantBubble.multipliedAlpha(0.84)
            copy.accent = copy.accent.multipliedAlpha(0.72)
        @unknown default:
            break
        }

        return copy
    }

    func generatingDarkDraftFromLight() -> ThemeTokenSet {
        ThemeTokenSet(
            mainBg: mainBg.adjustedBrightness(0.09, saturation: 0.12),
            sidebarBg: sidebarBg.adjustedBrightness(0.12, saturation: 0.12),
            userBubble: userBubble.adjustedBrightness(0.15, saturation: 0.10),
            userBubbleGradient: userBubbleGradient?.adjustedBrightness(0.15, saturation: 0.10),
            assistantBubble: assistantBubble.adjustedBrightness(0.18, saturation: 0.12),
            accent: accent.adjustedBrightness(0.24, saturation: 0.20),
            textPrimary: textPrimary.adjustedBrightness(0.92, saturation: 0.10),
            textSecondary: textSecondary.adjustedBrightness(0.72, saturation: 0.12),
            textMuted: textMuted.adjustedBrightness(0.55, saturation: 0.10),
            // nil 保持 nil：没单独设过的角色字色继续跟随深色草稿的 textPrimary
            userText: userText?.adjustedBrightness(0.92, saturation: 0.10),
            assistantText: assistantText?.adjustedBrightness(0.92, saturation: 0.10),
            favorite: favorite.adjustedBrightness(0.78),
            danger: danger.adjustedBrightness(0.80),
            branchIndicator: branchIndicator.adjustedBrightness(0.70)
        )
    }
}

struct ThemeBackgroundStyle: Codable, Hashable {
    /// M2：放开到 0...1，拉满 = 原图（以前硬顶 0.92）。老数据存的 ≤0.92 原样读出。
    static let opacityRange: ClosedRange<Double> = 0...1
    static let veilRange: ClosedRange<Double> = 0...1
    static let horizontalOffsetRange: ClosedRange<Double> = -240...240
    static let verticalOffsetRange: ClosedRange<Double> = -320...320

    var opacity: Double?
    /// 盖在背景图上那层白/黑渐变遮罩的强度（plan-theme-decouple M2）。
    /// `nil` = 1.0 = 改动前的强度，老主题观感零变化；0 = 不盖，纯原图。浅深共用一个值（与 opacity 一致）。
    var veil: Double?
    var offsetX: Double?
    var offsetY: Double?

    init(
        opacity: Double? = nil,
        veil: Double? = nil,
        offsetX: Double? = nil,
        offsetY: Double? = nil
    ) {
        self.opacity = opacity
        self.veil = veil
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    func resolvedOpacity(for scheme: ColorScheme) -> Double {
        let fallback = scheme == .dark ? 0.52 : 0.36
        return Self.clamp(
            opacity ?? fallback,
            to: Self.opacityRange
        )
    }

    var resolvedVeil: Double {
        Self.clamp(veil ?? 1.0, to: Self.veilRange)
    }

    var resolvedOffsetX: CGFloat {
        CGFloat(Self.clamp(offsetX ?? 0, to: Self.horizontalOffsetRange))
    }

    var resolvedOffsetY: CGFloat {
        CGFloat(Self.clamp(offsetY ?? 0, to: Self.verticalOffsetRange))
    }

    var normalized: ThemeBackgroundStyle {
        ThemeBackgroundStyle(
            opacity: opacity.map { Self.clamp($0, to: Self.opacityRange) },
            veil: veil.map { Self.clamp($0, to: Self.veilRange) },
            offsetX: offsetX.map { Self.clamp($0, to: Self.horizontalOffsetRange) },
            offsetY: offsetY.map { Self.clamp($0, to: Self.verticalOffsetRange) }
        )
    }

    private static func clamp(
        _ value: Double,
        to range: ClosedRange<Double>
    ) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

struct AppThemeDefinition: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var isBuiltIn: Bool
    var light: ThemeTokenSet
    var dark: ThemeTokenSet
    var backgroundImageFileName: String?
    var backgroundStyle: ThemeBackgroundStyle?

    func tokens(for scheme: ColorScheme) -> ThemeTokenSet {
        scheme == .dark ? dark : light
    }

    var isCustomDraft: Bool {
        id == Self.customTheme.id
    }

    var isEditable: Bool {
        !isBuiltIn
    }

    var isDeletable: Bool {
        !isBuiltIn && !isCustomDraft
    }

    var hasBackgroundImage: Bool {
        backgroundImageFileName != nil
    }

    var resolvedBackgroundStyle: ThemeBackgroundStyle {
        (backgroundStyle ?? ThemeBackgroundStyle()).normalized
    }

    static let defaultTheme = AppThemeDefinition(
        id: "default",
        name: "宫殿默认",
        isBuiltIn: true,
        light: .palaceLightDefault,
        dark: .palaceDarkDefault,
        backgroundImageFileName: nil,
        backgroundStyle: nil
    )

    static let customTheme = AppThemeDefinition(
        id: "custom",
        name: "自定义主题",
        isBuiltIn: false,
        light: .palaceLightDefault,
        dark: .palaceDarkDefault,
        backgroundImageFileName: nil,
        backgroundStyle: nil
    )

    static let seedThemes: [AppThemeDefinition] = [
        .defaultTheme,
        .customTheme
    ]

    var previewColors: [Color] {
        light.previewColors
    }
}
