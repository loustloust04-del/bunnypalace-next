import Foundation

/// 画笔 / 便利贴偏好（设置 · 贴纸「画笔」「便利贴」段改，画板 / 便利贴读）。存 UserDefaults JSON，两端共用。
struct BrushSettings: Codable, Equatable {
    /// 工具栏里出哪些笔、什么顺序（橡皮 / 套索恒在，不进这张表）
    var tools: [BoardTool] = BoardTool.defaultTools
    var waterColors: [String] = BrushSettings.defaultWaterColors
    var inkColors: [String] = BrushSettings.defaultInkColors
    var paper: PaperKind = .cold
    /// 新便利贴默认样子（NoteSpec.raw）；可选：老存档里没有这个键
    var note: String?

    var noteDefault: NoteSpec { note.map { NoteSpec(raw: $0) } ?? NoteSpec(kind: .sticky, color: "#d4efe4", font: .hand) }

    static let key = "brushSettings.v1"

    static let defaultWaterColors = ["#c8505a", "#e58a5c", "#e9b949", "#6f9a4c", "#2f7f7a", "#3a6fb0", "#6a5aa8", "#8a5a44", "#4a5560"]
    static let defaultInkColors = ["#22314a", "#1c1c1c", "#5a2b2b", "#2c4a3a", "#4a3a6a", "#8a3b2e"]

    static func load(_ defaults: UserDefaults = .standard) -> BrushSettings {
        guard let data = defaults.data(forKey: key), var s = try? JSONDecoder().decode(BrushSettings.self, from: data) else { return BrushSettings() }
        // 这一端没有的笔（mac 上的 PencilKit 笔）滤掉；滤空了回默认
        s.tools = s.tools.filter { BoardTool.available.contains($0) && !$0.isFixed }
        if s.tools.isEmpty { s.tools = BoardTool.defaultTools }
        if s.waterColors.isEmpty { s.waterColors = defaultWaterColors }
        if s.inkColors.isEmpty { s.inkColors = defaultInkColors }
        return s
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

extension BoardTool {
    static var defaultTools: [BoardTool] { available.filter { !$0.isFixed } }
}
