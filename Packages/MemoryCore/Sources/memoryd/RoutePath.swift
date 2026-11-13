import Foundation

/// 请求目标 → 规范路径。只解析、不碰文件系统：去掉 query、percent 解码、拒绝 `..` / `.` / 反斜杠 / NUL。
enum RoutePath {
    /// 规范路径（以 `/` 开头）；不合法 = nil
    static func normalized(_ target: String) -> String? {
        let raw = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        guard raw.hasPrefix("/") else { return nil }
        guard let decoded = raw.removingPercentEncoding else { return nil }
        guard !decoded.contains("\\"), !decoded.utf8.contains(0) else { return nil }
        var parts: [String] = []
        for part in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = String(part)
            if segment == "." || segment == ".." { return nil }
            parts.append(segment)
        }
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    /// 规范路径 → 段（`/` 本身 = 空数组）
    static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
