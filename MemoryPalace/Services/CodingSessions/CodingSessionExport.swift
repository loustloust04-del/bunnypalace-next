#if os(macOS)
import Foundation

/// 导出 Markdown（plan-wake-native-n1 §2.5 / R-WN1 #9，Wake `services/exporter.rs` 逐项对齐）：
/// 标题 + 一行元信息 + `---`；每条 `### 角色 emoji 标题 · 时间`；thinking 与工具调用各进 `<details>`
/// （thinking 裸排，工具 Input / Output 代码块）；CompactSummary 渲成引用块；Meta 跳过；图片出占位行；子代理附在后面。
enum CodingSessionExport {
    static func markdown(meta: CodingSessionMeta, messages: [CodingMessage],
                         sidechains: [(info: CodingSidechain, messages: [CodingMessage])] = []) -> String {
        var out = "# \(meta.title)\n\n"
        let project = meta.projectPath.isEmpty ? "(unknown)" : meta.projectPath
        let branch = meta.gitBranch.map { "(\($0))" } ?? ""
        out += "> **Agent**: \(meta.agent.displayName) · **Project**: \(project)\(branch) · **Time**: \(formatTime(meta.createdAt)) – \(formatTime(meta.updatedAt)) · **Messages**: \(meta.messageCount) · **Tokens**: \(formatTokens(meta.tokensUsed))\n\n---\n\n"
        for message in messages where message.kind != .meta {
            render(message, into: &out)
        }
        for (info, sideMessages) in sidechains where !sideMessages.isEmpty {
            let label = [info.agentType, info.description].compactMap { $0 }.joined(separator: ":")
            out += "---\n\n## ⑂ Subagent: \(label.isEmpty ? info.id : label)\n\n"
            for message in sideMessages where message.kind != .meta {
                render(message, into: &out)
            }
        }
        return out
    }

    /// 一站式：按 meta 解析主线与全部子代理，渲染成 Markdown
    static func render(adapter: CodingSessionAdapter, meta: CodingSessionMeta) throws -> String {
        guard let ref = (adapter.fileRef(URL(fileURLWithPath: meta.filePath)) ?? CodingSessionFileRef.fromMeta(meta)) else {
            throw CodingSessionError.unreadable(meta.filePath)
        }
        let transcript = try adapter.parseTranscript(ref)
        let sidechains = transcript.sidechains.map { info in
            (info: info, messages: (try? adapter.loadSidechain(ref, id: info.id)) ?? [])
        }
        return markdown(meta: meta, messages: transcript.mainline, sidechains: sidechains)
    }

    /// 默认文件名 `agent-标题-日期.md`：标题滤掉 `/\:*?"<>|`、压空白、截 40 字
    static func defaultFileName(_ meta: CodingSessionMeta, ext: String = "md") -> String {
        let forbidden = Set(#"/\:*?"<>|"#)
        let cleaned = CodingParse.collapseWhitespace(String(meta.title.filter { !forbidden.contains($0) }))
        let title = String(cleaned.prefix(40))
        let stamp = meta.updatedAt > 0 ? meta.updatedAt : Int64(Date().timeIntervalSince1970 * 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(stamp) / 1000))
        return "\(meta.agent.rawValue)-\(title.isEmpty ? "session" : title)-\(date).\(ext)"
    }

    // MARK: -

    private static func render(_ message: CodingMessage, into out: inout String) {
        let time = message.timestamp.map { " · \(formatTime($0))" } ?? ""
        out += "### \(roleLabel(message.role))\(time)\n\n"
        if message.kind == .compactSummary {
            out += "> \(message.text)\n\n"
            return
        }
        if let thinking = message.thinking {
            out += "<details><summary>🧠 Thinking</summary>\n\n\(thinking)\n\n</details>\n\n"
        }
        if !message.text.isEmpty {
            out += message.text + "\n\n"
        }
        // 解出的图每张一行（Wake exporter 格式）；解不了的已是正文里的 `[image]`
        for image in message.images {
            out += "> 🖼 Image attachment · \(image.mediaType) · \(image.data.count) bytes\n\n"
        }
        for call in message.toolCalls {
            out += "<details><summary>🔧 \(call.name) — \(call.inputPreview.replacingOccurrences(of: "<", with: "&lt;"))</summary>\n\n"
            if let input = call.input { out += "Input:\n\n```\n\(input)\n```\n\n" }
            if let output = call.output { out += "Output:\n\n```\n\(output)\n```\n\n" }
            out += "</details>\n\n"
        }
    }

    private static func roleLabel(_ role: CodingRole) -> String {
        switch role {
        case .user: return "👤 User"
        case .assistant: return "🤖 Assistant"
        case .system: return "⚙️ System"
        }
    }

    /// 本地时区 `yyyy-MM-dd HH:mm:ss`；0 = 空串
    static func formatTime(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    static func formatTokens(_ tokens: Int64?) -> String {
        guard let n = tokens, n != 0 else { return "-" }
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }
}
#endif
