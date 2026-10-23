import SwiftUI

/// 文件库里文件夹 / 文件小方块的配色和图标。只认顶层的系统文件夹，子文件夹一律原名 + 灰。
struct FileLibraryFolderStyle: Equatable {
    let displayName: String?
    let symbol: String
    let tint: UInt
    let fill: UInt
    let cover: UInt

    var tintColor: Color { Color(hex: tint) }
    var fillColor: Color { Color(hex: fill) }
    var coverColor: Color { Color(hex: cover) }

    static let plain = FileLibraryFolderStyle(displayName: nil, symbol: "folder", tint: 0x8B847D, fill: 0xF3F1EE, cover: 0xEBE8E3)

    private static let green = (tint: UInt(0x5F8F74), fill: UInt(0xEEF3EE), cover: UInt(0xE4EDE5))
    private static let purple = (tint: UInt(0x9585B3), fill: UInt(0xF2EEF6), cover: UInt(0xECE6F2))
    private static let slate = (tint: UInt(0x7D93B3), fill: UInt(0xEEF1F6), cover: UInt(0xE5EAF2))
    private static let brown = (tint: UInt(0xB1835C), fill: UInt(0xF6EFE6), cover: UInt(0xF2E8DC))
    private static let olive = (tint: UInt(0x9A9174), fill: UInt(0xF1F0EA), cover: UInt(0xECE9E0))
    private static let rose = (tint: UInt(0xC27F8F), fill: UInt(0xF7EEF0), cover: UInt(0xF2E4E8))

    private static func make(_ name: String, _ symbol: String, _ c: (tint: UInt, fill: UInt, cover: UInt)) -> FileLibraryFolderStyle {
        FileLibraryFolderStyle(displayName: name, symbol: symbol, tint: c.tint, fill: c.fill, cover: c.cover)
    }

    /// 顶层系统文件夹表。学堂的真实目录名取 `StudyTemplate.noteRoot`。
    static func system(_ topLevel: String) -> FileLibraryFolderStyle? {
        switch topLevel {
        case "vocab": make("词条笔记", "character.book.closed", green)
        case StudyTemplate.noteRoot: make("学堂笔记", "graduationcap", purple)
        case "trading": make("投研", "chart.line.uptrend.xyaxis", slate)
        case "books": make("读书", "book", brown)
        case "attachments": make("聊天附件", "paperclip", olive)
        case "calendar": make("日历", "calendar", rose)
        case "journal": make("日记", "pencil.line", rose)
        case "memory": make("记忆", "sparkles", purple)
        case "notes": make("笔记", "note.text", green)
        default: nil
        }
    }

    /// 文件夹路径（相对库根）对应的样式：顶层认得就用系统样式，子文件夹用顶层的颜色但图标是普通文件夹、名字用原名。
    static func forFolder(_ path: String) -> FileLibraryFolderStyle {
        let parts = path.split(separator: "/").map(String.init)
        guard let top = parts.first, let sys = system(top) else { return .plain }
        if parts.count == 1 { return sys }
        return FileLibraryFolderStyle(displayName: nil, symbol: "folder", tint: sys.tint, fill: sys.fill, cover: sys.cover)
    }

    /// 文件小方块的颜色：跟它所在的顶层系统文件夹走。
    static func forFile(_ path: String) -> FileLibraryFolderStyle {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1, let sys = system(parts[0]) else { return .plain }
        return sys
    }

    /// 文件夹显示名：顶层系统文件夹给中文名，其它原名。
    static func displayName(forFolder path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 1, let name = system(parts[0])?.displayName { return name }
        return parts.last ?? path
    }
}

// MARK: - 磨砂文件夹外观（存楼层 .memorypalace/folder-styles.json）

/// 一只文件夹的外观：颜色（预设名或 #RRGGBB）+ 纹样 + 标记。没记录的文件夹走 `defaultLook`。
struct FileLibraryFolderLook: Codable, Equatable {
    enum Pattern: String, Codable, CaseIterable {
        case flower, star, snow, beads

        var title: String {
            switch self {
            case .flower: "点点花"
            case .star: "点点星"
            case .snow: "雪花"
            case .beads: "珠串"
            }
        }
    }

    struct Mark: Codable, Equatable {
        enum Kind: String, Codable {
            case symbol, emoji, mono, none
        }

        var kind: Kind
        var value: String?

        static let mono = Mark(kind: .mono, value: nil)
        static let none = Mark(kind: .none, value: nil)
        static func symbol(_ name: String) -> Mark { Mark(kind: .symbol, value: name) }
        static func emoji(_ glyph: String) -> Mark { Mark(kind: .emoji, value: glyph) }

        init(kind: Kind, value: String?) {
            self.kind = kind
            self.value = value
        }

        /// 认不得的 kind、symbol / emoji 缺值 → 首字
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = (try? c.decode(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? .mono
            let value = (try? c.decodeIfPresent(String.self, forKey: .value)) ?? nil
            let needsValue = kind == .symbol || kind == .emoji
            self.kind = needsValue && (value ?? "").isEmpty ? .mono : kind
            self.value = needsValue ? value : nil
        }
    }

    var color: String
    var pattern: Pattern?
    var mark: Mark

    init(color: String, pattern: Pattern? = nil, mark: Mark) {
        self.color = color
        self.pattern = pattern
        self.mark = mark
    }

    /// 宽松解码：认不得的颜色 / 纹样 / 标记退回默认，不让一条坏记录拖垮整张表
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let color = (try? c.decode(String.self, forKey: .color)) ?? ""
        self.color = FileLibraryFolderPalette.isValid(color) ? color : FileLibraryFolderPalette.cream.rawValue
        pattern = ((try? c.decodeIfPresent(String.self, forKey: .pattern)) ?? nil).flatMap(Pattern.init(rawValue:))
        mark = (try? c.decode(Mark.self, forKey: .mark)) ?? .mono
    }

    var paint: FileLibraryFolderPaint { FileLibraryFolderPaint(color: color) }

    /// 首字：名字第一个字，英文大写
    static func monogram(_ name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "·" }
        return String(first).uppercased()
    }

    /// 默认样式：顶层系统文件夹有颜色 + 图标；其它（含子文件夹）奶白 + 首字
    static func defaultLook(forFolder path: String) -> FileLibraryFolderLook {
        let parts = path.split(separator: "/").map(String.init)
        let plain = FileLibraryFolderLook(color: FileLibraryFolderPalette.cream.rawValue, mark: .mono)
        guard parts.count == 1 else { return plain }
        func look(_ p: FileLibraryFolderPalette, _ symbol: String) -> FileLibraryFolderLook {
            FileLibraryFolderLook(color: p.rawValue, mark: .symbol(symbol))
        }
        switch parts[0] {
        case "attachments": return look(.sand, "paperclip")
        case "journal": return look(.rose, "pencil")
        case "calendar": return look(.lilac, "calendar")
        case "books": return look(.olive, "book")
        case "trading": return look(.sky, "chart.line.uptrend.xyaxis")
        case "vocab": return look(.mint, "character.book.closed")
        case StudyTemplate.noteRoot: return look(.lilac, "graduationcap")
        case "memory": return look(.cream, "sparkles")
        case "notes": return look(.cream, "note.text")
        default: return plain
        }
    }
}

/// 8 个预设色：后片实色 + 前片半透明色（叠在 Material 上）
enum FileLibraryFolderPalette: String, CaseIterable {
    case mint, rose, lilac, sky, sand, olive, cream, ink

    var back: UInt {
        switch self {
        case .mint: 0xB9D3C2
        case .rose: 0xECC6CD
        case .lilac: 0xD3CAE3
        case .sky: 0xC8D4E6
        case .sand: 0xE8D4BD
        case .olive: 0xD9D4B4
        case .cream: 0xECE5D8
        case .ink: 0x7C726C
        }
    }

    var front: (hex: UInt, alpha: Double) {
        switch self {
        case .mint: (0x8FB79D, 0.42)
        case .rose: (0xD99AA5, 0.40)
        case .lilac: (0xB3A2CC, 0.42)
        case .sky: (0x8FA9C9, 0.42)
        case .sand: (0xD9A07F, 0.36)
        case .olive: (0xC7B27A, 0.40)
        case .cream: (0xECE5D8, 0.55)
        case .ink: (0x3D3633, 0.55)
        }
    }

    static func isValid(_ color: String) -> Bool {
        FileLibraryFolderPalette(rawValue: color) != nil || hexValue(color) != nil
    }

    /// "#RRGGBB" → 0xRRGGBB；别的写法一律 nil
    static func hexValue(_ s: String) -> UInt? {
        guard s.count == 7, s.hasPrefix("#") else { return nil }
        let digits = s.dropFirst()
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt(digits, radix: 16)
    }

    static func hexString(_ value: UInt) -> String {
        String(format: "#%06X", value & 0xFFFFFF)
    }

    /// WCAG 相对亮度（0…1）
    static func luminance(_ hex: UInt) -> Double {
        func channel(_ v: UInt) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    /// 太浅的颜色白图案看不见，改暖灰（8 色里只有奶白过线）
    static func isLight(_ hex: UInt) -> Bool { luminance(hex) > 0.75 }
}

/// 外观落到画面上的颜色
struct FileLibraryFolderPaint: Equatable {
    let back: UInt
    let front: UInt
    let frontAlpha: Double

    static let warmGray: UInt = 0x8B827B

    init(color: String) {
        if let preset = FileLibraryFolderPalette(rawValue: color) {
            back = preset.back
            (front, frontAlpha) = preset.front
        } else {
            let hex = FileLibraryFolderPalette.hexValue(color) ?? FileLibraryFolderPalette.cream.back
            back = hex
            front = hex
            frontAlpha = 0.42
        }
    }

    var backColor: Color { Color(hex: back) }
    var frontColor: Color { Color(hex: front, alpha: frontAlpha) }
    /// 前片上的纹样 / 标记：白，过浅的颜色改暖灰
    var inkColor: Color { FileLibraryFolderPalette.isLight(back) ? Color(hex: Self.warmGray) : .white }
    /// 列表 / 树小方块：深底（棕黑那种）标记用白，其它暖灰
    var tileInkIsWhite: Bool { FileLibraryFolderPalette.luminance(back) < 0.3 }
}
