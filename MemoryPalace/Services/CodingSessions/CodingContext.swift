#if os(macOS)
import Foundation

/// AI 工具取上下文的纯函数（Wake `services/context.rs`）：project 参数的三级匹配与 since 解析，单测卡语义——工具层只管拼装
enum CodingContext {
    /// agent 给的 project 参数 → 索引里的项目路径集合。绝对路径三级：①完全相等；②该路径在某项目之内（agent 的 cwd 在子目录里）→ 取最长的
    /// 那个祖先；③项目在该路径之下（monorepo 根、`~/Github` 这类上层目录）→ 并集。边界判定用 pathOwns，`wake-old` 不算 `wake` 的后代。
    /// 非路径按项目名匹配（大小写不敏感）。返回空 = 没匹配上，调用方据此报「未知项目」，**不要退化成不过滤**
    static func resolveProjectPaths(_ arg: String, projects: [CodingProjectInfo]) -> [String] {
        let expanded = CodingLocations.expandTilde(arg.trimmingCharacters(in: .whitespacesAndNewlines))
        let wanted = stripTrailingSeparator(expanded)
        guard !wanted.isEmpty else { return [] }
        if looksLikePath(wanted) {
            if let exact = projects.first(where: { stripTrailingSeparator($0.path) == wanted }) { return [exact.path] }
            var best: CodingProjectInfo?
            for project in projects where !project.path.isEmpty && CodingLocations.pathOwns(project.path, wanted) {
                if project.path.count > (best?.path.count ?? -1) { best = project }
            }
            if let best { return [best.path] }
            return Array(Set(projects.filter { !$0.path.isEmpty && CodingLocations.pathOwns(wanted, $0.path) }.map(\.path))).sorted()
        }
        let lower = wanted.lowercased()
        return Array(Set(projects.filter { !$0.path.isEmpty && $0.name.lowercased() == lower }.map(\.path))).sorted()
    }

    /// 是「路径」而非「项目名」：绝对路径，或盘符串（远程镜像 / 夹具里可能有 Windows 形态，一个盘符串不可能是项目名）
    private static func looksLikePath(_ s: String) -> Bool {
        let b = Array(s.utf8)
        let drive = b.count >= 3 && ((b[0] >= 65 && b[0] <= 90) || (b[0] >= 97 && b[0] <= 122)) && b[1] == UInt8(ascii: ":")
            && (b[2] == UInt8(ascii: "\\") || b[2] == UInt8(ascii: "/"))
        return s.hasPrefix("/") || drive
    }

    /// 去掉尾部分隔符；文件系统根「/」剥光了会变空串，保留原样
    private static func stripTrailingSeparator(_ s: String) -> String {
        var trimmed = s
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty && !s.isEmpty ? s : trimmed
    }

    /// since 参数 → epoch ms。接受相对量 `30m / 24h / 7d / 2w`（以 nowMs 为基准）、RFC 3339、无时区的日期时间（本地时区）、裸日期
    /// （本地当天 00:00）。解析不了回 nil，调用方报参数错误；负数与非 ASCII 单位（`7天`）都回 nil
    static func parseSince(_ arg: String, nowMs: Int64) -> Int64? {
        let s = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let ms = relative(s) { return nowMs - ms }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: s) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: s) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        }
        return nil
    }

    private static func relative(_ s: String) -> Int64? {
        guard let unit = s.last else { return nil }
        let unitMs: Int64
        switch unit {
        case "m": unitMs = 60_000
        case "h": unitMs = 3_600_000
        case "d": unitMs = 86_400_000
        case "w": unitMs = 7 * 86_400_000
        default: return nil
        }
        guard let n = Int64(s.dropLast()), n >= 0 else { return nil }
        let (product, overflow) = n.multipliedReportingOverflow(by: unitMs)
        return overflow ? nil : product
    }
}
#endif
