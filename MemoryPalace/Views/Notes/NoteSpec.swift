import SwiftUI

/// 便利贴的样子（docs/plan-page1-note-drawing.md §E）。不改表：编进现有 `noteStyle` 字符串 `kind|#hex|font`，
/// 旧四种值（yellow_square / pink_rounded / glass / torn_paper）照认、映射到新样式。
struct NoteSpec: Equatable, Hashable {
    var kind: NoteKind
    var color: String?
    var font: NoteFont

    init(kind: NoteKind, color: String? = nil, font: NoteFont = .hand) {
        self.kind = kind
        self.color = color ?? kind.colors.first
        self.font = font
    }

    init(raw: String?) {
        switch raw ?? "" {
        case "", "yellow_square": self.init(kind: .sticky, color: "#fff1a8", font: .system)
        case "pink_rounded": self.init(kind: .sticky, color: "#ffd6dc", font: .system)
        case "glass": self.init(kind: .vellum, font: .system)
        case "torn_paper": self.init(kind: .torn, color: "#fffaf0", font: .system)
        case let s:
            let parts = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let kind = NoteKind(rawValue: parts[0]) ?? .sticky
            let color = parts.count > 1 && parts[1].hasPrefix("#") ? parts[1] : nil
            let font = parts.count > 2 ? NoteFont(rawValue: parts[2]) ?? .system : .system
            self.init(kind: kind, color: kind.colors.isEmpty ? nil : (color ?? kind.colors.first), font: font)
        }
    }

    var raw: String { "\(kind.rawValue)|\(color ?? "")|\(font.rawValue)" }
}

enum NoteKind: String, CaseIterable, Identifiable {
    case sticky, lined, grid, kraft, index, polaroid, receipt, torn, fold, tape, spiral, vellum
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sticky: "便利贴"
        case .lined: "横线纸"
        case .grid: "方格纸"
        case .kraft: "牛皮纸"
        case .index: "索引卡"
        case .polaroid: "拍立得"
        case .receipt: "小票"
        case .torn: "撕边纸条"
        case .fold: "折角"
        case .tape: "和纸胶带"
        case .spiral: "线圈本"
        case .vellum: "描图纸"
        }
    }

    /// 这种纸可选的颜色；空 = 纸本身定色
    var colors: [String] {
        switch self {
        case .sticky: ["#fff1a8", "#ffd6dc", "#d4efe4", "#ffe2c4", "#dde6f6", "#efe3fb"]
        case .polaroid: ["#f6d3c8", "#cfe5df", "#e6dcf3", "#f3e3b9"]
        case .torn: ["#fffaf0", "#fff1a8", "#d4efe4", "#ffd6dc"]
        case .fold: ["#fff1a8", "#d4efe4", "#ffd6dc", "#ffe2c4"]
        case .tape: ["#e6a7a1", "#9fcfc4", "#e9c77c", "#b6a6d8"]
        default: []
        }
    }
}

enum NoteFont: String, CaseIterable, Identifiable {
    case hand, cute, kai, marker, type, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hand: "手写"
        case .cute: "可爱"
        case .kai: "楷体"
        case .marker: "马克笔"
        case .type: "打字机"
        case .system: "系统"
        }
    }

    func font(_ size: CGFloat) -> Font {
        switch self {
        case .hand: .custom("LongCang-Regular", size: size * 1.15)
        case .cute: .custom("ZCOOLKuaiLe-Regular", size: size)
        case .kai: .custom("LXGWWenKai-Regular", size: size)
        case .marker: .custom("Marker Felt", size: size)
        case .type: .custom("American Typewriter", size: size * 0.92)
        case .system: .system(size: size)
        }
    }
}
