import Foundation

/// 联网搜索诊断探针——写文件到 Documents/web-search-probe.log。
/// devicectl device copy from-device 拉回 mac 看。
/// 故障排查用，不在 release 走（自检查只触发一次，不会刷屏）。
enum WebSearchProbe {
    static let filename = "web-search-probe.log"

    private static var url: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return docs.appendingPathComponent(filename)
    }

    static func log(_ msg: String) {
        guard let url else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// 摘 tools 数组里关键字段，避免 JSON 太长
    static func summarizeTools(_ tools: [[String: Any]]?) -> String {
        guard let tools, !tools.isEmpty else { return "<nil-or-empty>" }
        let names = tools.compactMap { t -> String? in
            if let name = t["name"] as? String { return name }                                      // anthropic style
            if let fn = t["function"] as? [String: Any], let name = fn["name"] as? String { return name }  // openai style
            if let type = t["type"] as? String { return "[type=\(type)]" }                          // server tool
            return nil
        }
        return "[\(tools.count) tools: \(names.joined(separator: ", "))]"
    }
}
