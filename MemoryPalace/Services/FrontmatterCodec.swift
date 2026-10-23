import Foundation

/// 记忆树 frontmatter 文件的统一编解码（summaries / profile.md / daily 三店共用）。
/// 格式：`---` / `key: value` 行 / `---` / 空行 / 正文。正文里的 `---` 行不影响解析（闭合取 header 后第一个）。
enum FrontmatterCodec {
    /// meta 用有序对——渲染顺序稳定（文件 diff 友好）
    static func render(meta: [(key: String, value: String)], body: String) -> String {
        let metaLines = meta.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        return "---\n\(metaLines)\n---\n\n\(body)"
    }

    /// 解析失败或正文为空返回 nil（调用方视为"无此记忆"，自愈：下次重新生成）
    static func parse(_ raw: String) -> (meta: [String: String], body: String)? {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closeIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        var meta: [String: String] = [:]
        for line in lines[1..<closeIdx] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            meta[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let body = lines[(closeIdx + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return (meta, body)
    }

    /// 三店共用的日期格式（秒级 ISO8601）
    static let dateFormatter = ISO8601DateFormatter()
}
