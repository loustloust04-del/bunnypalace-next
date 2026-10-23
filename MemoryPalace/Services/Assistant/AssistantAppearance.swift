import Foundation

// MARK: - 小芽 v2 · P3 外观放权的共享层（plan-小芽-v2 §5 v1.1，astra B2/C4）
// 提案只存「要改的那几项」；盖章时从当下的外观复制一份、套上补丁再存——不存整份草稿，
// 不会把你在这期间改过的其他项盖回去。两端共享（mac 测试能测），画面预览在 iOS 那边。

struct Page2AppearancePatch: Codable, Equatable {
    var wallpaper: String?
    var rendering: String?
    var luminosity: String?
    var largeIcons: Bool?
    var dimming: Double?
    var tintHue: Double?
    var tintSaturation: Double?

    /// 首批放权的可选值（照 Page2WallpaperEditor / Page2AppearanceEditor 现有 UI 提取；「我的照片」要选文件，模型做不了，不放）
    static let wallpapers = ["ios26": "iOS 26 原生", "garden": "花园四季", "mist": "雾白花园", "dusk": "暮色玻璃", "flora": "手绘花园"]
    static let renderings = ["default": "默认", "dark": "深色", "clear": "透明", "tinted": "着色"]
    static let luminosities = ["light": "浅色", "dark": "深色", "auto": "自动"]

    var isEmpty: Bool { self == Page2AppearancePatch() }

    /// 越界 = 抛错，工具层据此不产提案
    func validate() throws {
        if let wallpaper, Self.wallpapers[wallpaper] == nil { throw AssistantStampError.invalid("没有叫 \(wallpaper) 的壁纸") }
        if let rendering, Self.renderings[rendering] == nil { throw AssistantStampError.invalid("图标外观只能是 default / dark / clear / tinted") }
        if let luminosity, Self.luminosities[luminosity] == nil { throw AssistantStampError.invalid("明暗只能是 light / dark / auto") }
        if let dimming, !(0...0.85).contains(dimming) { throw AssistantStampError.invalid("明亮遮罩要在 0~0.85") }
        if let tintHue, !(0...1).contains(tintHue) { throw AssistantStampError.invalid("着色色相要在 0~1") }
        if let tintSaturation, !(0...1).contains(tintSaturation) { throw AssistantStampError.invalid("着色饱和度要在 0~1") }
    }

    func applied(to base: Page2Appearance) -> Page2Appearance {
        var out = base
        if let wallpaper { out.wallpaper = wallpaper }
        if let rendering { out.rendering = rendering }
        if let luminosity { out.luminosity = luminosity }
        if let largeIcons { out.largeIcons = largeIcons }
        if let dimming { out.dimming = dimming }
        if let tintHue { out.tintHue = tintHue }
        if let tintSaturation { out.tintSaturation = tintSaturation }
        return out
    }

    /// 同样这几项，在 base 里现在是什么值（改前快照 / 核「之后又改过」都用它）
    func currentValues(in base: Page2Appearance) -> Page2AppearancePatch {
        Page2AppearancePatch(
            wallpaper: wallpaper.map { _ in base.wallpaper },
            rendering: rendering.map { _ in base.rendering },
            luminosity: luminosity.map { _ in base.luminosity },
            largeIcons: largeIcons.map { _ in base.largeIcons },
            dimming: dimming.map { _ in base.dimming },
            tintHue: tintHue.map { _ in base.tintHue },
            tintSaturation: tintSaturation.map { _ in base.tintSaturation })
    }

    /// 把没变化的项去掉（新值和现在一样就别提）
    func dropping(unchangedFrom base: Page2Appearance) -> Page2AppearancePatch {
        Page2AppearancePatch(
            wallpaper: wallpaper == base.wallpaper ? nil : wallpaper,
            rendering: rendering == base.rendering ? nil : rendering,
            luminosity: luminosity == base.luminosity ? nil : luminosity,
            largeIcons: largeIcons == base.largeIcons ? nil : largeIcons,
            dimming: dimming == base.dimming ? nil : dimming,
            tintHue: tintHue == base.tintHue ? nil : tintHue,
            tintSaturation: tintSaturation == base.tintSaturation ? nil : tintSaturation)
    }

    /// 卡片上的对照行
    func describe(against before: Page2AppearancePatch) -> [AssistantDiffField] {
        var out: [AssistantDiffField] = []
        func add(_ label: String, _ old: String?, _ new: String?) {
            if let new { out.append(AssistantDiffField(label: label, old: old, new: new)) }
        }
        add("壁纸", before.wallpaper.map { Self.wallpapers[$0] ?? $0 }, wallpaper.map { Self.wallpapers[$0] ?? $0 })
        add("图标外观", before.rendering.map { Self.renderings[$0] ?? $0 }, rendering.map { Self.renderings[$0] ?? $0 })
        add("明暗", before.luminosity.map { Self.luminosities[$0] ?? $0 }, luminosity.map { Self.luminosities[$0] ?? $0 })
        add("大图标", before.largeIcons.map { $0 ? "开" : "关" }, largeIcons.map { $0 ? "开" : "关" })
        add("明亮遮罩", before.dimming.map(Self.percent), dimming.map(Self.percent))
        add("着色色相", before.tintHue.map(Self.percent), tintHue.map(Self.percent))
        add("着色饱和度", before.tintSaturation.map(Self.percent), tintSaturation.map(Self.percent))
        return out
    }

    private static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

enum Page2IconChoices {
    /// 照 Page2IconEditor 现有的 16 个符号 + 4 种颜色
    static let symbols = ["leaf", "sparkles", "heart", "book.closed", "calendar", "brain", "bubble.left", "lightbulb",
                          "folder", "star", "moon", "leaf.circle", "pawprint", "headphones", "terminal", "globe"]
    static let tints = ["sage": "灰绿", "rose": "灰玫瑰", "plum": "灰紫", "graphite": "墨色"]
}
