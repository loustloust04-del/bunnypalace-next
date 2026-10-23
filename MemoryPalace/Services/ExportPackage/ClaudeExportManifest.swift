import Foundation

/// Claude 新版导出的下载清单 `manifest-*.json`（#059）：只列包的下载链接，包本身要另外下。
/// 链接是短期凭证（24 小时、可能只能用一次）：只放内存，`description` 打码，不进日志 / 导入记录。
struct ClaudeExportManifest: Equatable {
    struct Package: Identifiable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        /// 清单里的文件名（下载落盘也用它，不信服务器给的名字）
        let filename: String
        let category: String
        let url: URL

        var id: String { filename }
        /// 花园不导的类别（反馈、账号信息）：列出来但不用下
        var isNeeded: Bool { !ClaudeExportManifest.skippedCategories.contains(category) }
        var categoryName: String { ClaudeExportManifest.categoryNames[category] ?? category }

        var description: String { "\(filename)（\(category)）" }
        var debugDescription: String { description }
    }

    /// 链接有效期（清单 instructions 原文：created 后 24 小时）
    static let lifetime: TimeInterval = 24 * 3600
    static let skippedCategories: Set<String> = ["feedback", "light_metadata"]
    static let categoryNames = [
        "conversations": "对话", "projects": "项目", "memories": "记忆", "design_chats": "设计对话",
        "frames": "Artifacts", "feedback": "反馈", "light_metadata": "账号信息",
    ]

    /// 清单没写导出时间 = nil（不知道过没过期）
    let createdAt: Date?
    let packages: [Package]

    var expiresAt: Date? { createdAt?.addingTimeInterval(Self.lifetime) }

    func isExpired(now: Date = Date()) -> Bool {
        expiresAt.map { now >= $0 } ?? false
    }

    /// 还剩几个小时（向下取整，最少 0）；不知道导出时间 = nil
    func hoursLeft(now: Date = Date()) -> Int? {
        expiresAt.map { max(0, Int($0.timeIntervalSince(now) / 3600)) }
    }

    /// 只认 `https://claude.ai/export/…`：清单被改过也不会让花园去下别处的东西
    static func isDownloadURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "claude.ai" && url.path.hasPrefix("/export/")
            && !url.path.split(separator: "/").contains("..")
    }

    /// 不是 Claude 的下载清单（ChatGPT 的 `export_manifest.json`、Kelivo 的清单…）= nil。
    /// 链接不对 / 文件名不像包名的条目跳过
    static func parse(data: Data) -> ClaudeExportManifest? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["data_files"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        let packages = files.compactMap { file -> Package? in
            guard let raw = file["export_url"] as? String, let url = URL(string: raw), isDownloadURL(url),
                  let name = file["filename"] as? String, isPackageName(name), seen.insert(name).inserted else { return nil }
            return Package(filename: name, category: file["category"] as? String ?? "", url: url)
        }
        guard !packages.isEmpty else { return nil }
        return ClaudeExportManifest(createdAt: GeminiImportSupport.parseISO(root["created_at"] as? String), packages: packages)
    }

    /// `conversations-000.zip` 这类：单层文件名、`.zip` 结尾
    private static func isPackageName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && name.lowercased().hasSuffix(".zip")
    }

    var description: String { "ClaudeExportManifest(\(packages.map(\.filename)))" }
}

extension ClaudeExportManifest: CustomStringConvertible, CustomDebugStringConvertible {
    var debugDescription: String { description }
}
