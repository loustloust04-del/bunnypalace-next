import Foundation

/// 花园记忆放到 CC 家的 `garden-memory/` 时起名字的规矩（楼层文件夹名、记忆条目的「说的是谁」文件夹名共用）。纯函数
public enum GardenMemoryExport {
    public static let looseName = "其他"

    /// 名字 → 能当文件夹 / 文件名的一段：路径分隔和控制字符换成 -，不许以点开头，最长 80 字；洗完是空的 / 撞了保留名就归到「其他」
    public static func fileStem(_ title: String) -> String {
        let cleaned = String(title.map { ch -> Character in
            ch == "/" || ch == "\\" || ch == ":" || ch.isNewline || ch.unicodeScalars.contains { $0.properties.generalCategory == .control } ? "-" : ch
        }).trimmingCharacters(in: .whitespaces)
        let stem = String(cleaned.drop(while: { $0 == "." }).prefix(80)).trimmingCharacters(in: .whitespaces)
        return stem.isEmpty || stem == "README" ? looseName : stem
    }
}
