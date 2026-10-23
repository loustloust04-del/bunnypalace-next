import Foundation

struct Page2IconOverride: Codable, Equatable {
    var symbol: String?
    var imageFile: String?
    var tint: String = "sage"
}

struct Page2Appearance: Codable, Equatable {
    #if PERSONAL_APPS
    var wallpaper: String = "ios26"
    #else
    var wallpaper: String = "garden"
    #endif
    var rendering: String = "clear"
    var luminosity: String = "auto"
    var largeIcons: Bool = false
    var imageFile: String?
    var dimming: Double = 0.15
    var offsetX: Double = 0
    var offsetY: Double = 0
    var icons: [String: Page2IconOverride] = [:]
    var widgetTone: String = "ivory"
    var tintHue: Double = 0.36
    var tintSaturation: Double = 0.6

    init() {}
    private enum CodingKeys: String, CodingKey {
        case wallpaper, rendering, luminosity, largeIcons, imageFile, dimming, offsetX, offsetY, icons, widgetTone, tintHue, tintSaturation
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wallpaper = try c.decodeIfPresent(String.self, forKey: .wallpaper) ?? wallpaper
        rendering = try c.decodeIfPresent(String.self, forKey: .rendering) ?? rendering
        luminosity = try c.decodeIfPresent(String.self, forKey: .luminosity) ?? luminosity
        largeIcons = try c.decodeIfPresent(Bool.self, forKey: .largeIcons) ?? largeIcons
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        dimming = try c.decodeIfPresent(Double.self, forKey: .dimming) ?? dimming
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? offsetX
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? offsetY
        icons = try c.decodeIfPresent([String: Page2IconOverride].self, forKey: .icons) ?? icons
        widgetTone = try c.decodeIfPresent(String.self, forKey: .widgetTone) ?? widgetTone
        tintHue = try c.decodeIfPresent(Double.self, forKey: .tintHue) ?? tintHue
        tintSaturation = try c.decodeIfPresent(Double.self, forKey: .tintSaturation) ?? tintSaturation
    }
}

extension Page2Appearance {
    /// 实际画出来的壁纸：公开版不带 iOS 26 那张系统图（#013），存着 ios26 的按花园四季画
    var resolvedWallpaper: String {
        #if PERSONAL_APPS
        wallpaper
        #else
        wallpaper == "ios26" ? "garden" : wallpaper
        #endif
    }
    static func isLightBackdrop(_ resolved: String, daylight: Bool) -> Bool {
        ["mist", "flora"].contains(resolved) || (resolved == "garden" && daylight)
    }
    static func isPaleGlass(_ resolved: String, daylight: Bool) -> Bool {
        resolved == "mist" || (resolved == "garden" && daylight)
    }
}
