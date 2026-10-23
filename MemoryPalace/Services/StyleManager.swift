import Foundation

/// 全局写作风格库。仿 PresetManager：@Observable + UserDefaults JSON，
/// load 时确保内置始终存在。注入逻辑在 ConversationViewModel.assemblePrompt 出口取，故用单例。
@Observable
final class StyleManager {
    static let shared = StyleManager()
    private static let stylesKey = "savedWritingStyles"

    var styles: [WritingStyle]

    init() {
        self.styles = Self.load()
    }

    func find(_ id: String) -> WritingStyle? {
        styles.first { $0.id == id }
    }

    func save(_ style: WritingStyle) {
        if let idx = styles.firstIndex(where: { $0.id == style.id }) {
            styles[idx] = style
        } else {
            styles.append(style)
        }
        persist()
    }

    /// 内置不可删（可复制成自建后改）。
    func delete(_ style: WritingStyle) {
        guard !style.isBuiltin else { return }
        styles.removeAll { $0.id == style.id }
        persist()
    }

    func duplicate(_ style: WritingStyle) -> WritingStyle {
        var copy = style
        copy.id = UUID().uuidString
        copy.name = "\(style.name) 副本"
        copy.isBuiltin = false
        styles.append(copy)
        persist()
        return copy
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(styles) {
            UserDefaults.standard.set(data, forKey: Self.stylesKey)
        }
    }

    private static func load() -> [WritingStyle] {
        if let data = UserDefaults.standard.data(forKey: stylesKey),
           let saved = try? JSONDecoder().decode([WritingStyle].self, from: data),
           !saved.isEmpty {
            var result = saved
            for b in WritingStyle.allBuiltin where !result.contains(where: { $0.id == b.id }) {
                result.insert(b, at: 0)
            }
            return result
        }
        return WritingStyle.allBuiltin
    }
}
