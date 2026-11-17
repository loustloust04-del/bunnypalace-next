import Foundation
import CryptoKit

/// 电脑文件夹楼层「看历史」（docs/plan-folder-floor.md P2）：电脑上的 session 同步到这一层，落成普通对话（导入的归档那一类）。
/// 这里只放两样：看板服务回来的东西长什么样，和一轮怎么变成对话里的消息。写库、收发在 `FolderHistorySync`。
enum FolderHistory {
    /// `Conversation.provider`：电脑上的 Claude Code session
    static let provider = "claude-code"
    /// `Conversation.archiveKind`：同步来的 session，这一段只读（P4 插话再放开）
    static let archiveKind = "folderSession"

    struct SessionMeta: Decodable, Equatable {
        /// 「账号:Claude 对话号」
        var key: String
        var account: String
        var sid: String
        var title: String
        var createdAt: Double
        var updatedAt: Double
        var turns: Int
        /// 文件被换掉 / 变短过几次：变了 = 手机上这条从头重拉
        var epoch: Int
        var seq: Int
    }

    enum Part: Decodable, Equatable {
        case text(String)
        case thinking(String)
        case tool(id: String, name: String, brief: String)
        case unknown

        private enum Keys: String, CodingKey { case k, text, id, name, brief }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(String.self, forKey: .k) {
            case "text": self = .text(try c.decode(String.self, forKey: .text))
            case "thinking": self = .thinking((try? c.decode(String.self, forKey: .text)) ?? "")
            case "tool":
                self = .tool(id: (try? c.decode(String.self, forKey: .id)) ?? "", name: (try? c.decode(String.self, forKey: .name)) ?? "",
                             brief: (try? c.decode(String.self, forKey: .brief)) ?? "")
            default: self = .unknown
            }
        }
    }

    struct Turn: Decodable, Equatable {
        var id: String
        var at: Double
        /// human 人打的 / session 别的 session 发来的 / system 后台任务通知 / none 没有输入
        var from: String
        var who: String?
        var text: String
        var images: Int?
        var parts: [Part]
        var endAt: Double
    }

    struct SessionsReply: Decodable {
        var ok: Bool
        var error: String?
        var seq: Int?
        var sessions: [SessionMeta]?
        var gone: [String]?
        /// 电脑那头的索引还在建：这次拿到的不全，过一会儿再问
        var pending: Bool?
        /// 「账号:对话号」→ busy / wait / done；不在里面 = 没有状态
        var states: [String: String]?
        /// 「账号:对话号」→ 那台 hub 自己开的会话名（手机上开的对话，本地已经有了）
        var hub_sessions: [String: String]?
    }

    struct TurnsReply: Decodable {
        var ok: Bool
        var error: String?
        var key: String?
        var epoch: Int?
        var total: Int?
        var from: Int?
        var turns: [Turn]?
        var next: Int?
    }

    // MARK: 号

    /// 这条 session 在手机上的对话号。带上电脑的身份和楼层：换一台电脑、同一个对话号不会撞；两层连同一台电脑时各有各的一份；
    /// 同一台电脑、同一层重连还是同一条
    static func conversationId(hubIdentity: String, profileId: String, key: String) -> String {
        let scope = SHA256.hash(data: Data("\(hubIdentity)|\(profileId)".utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
        return "fh-\(scope)-\(key.replacingOccurrences(of: ":", with: "-"))"
    }

    static func userNodeId(_ conversationId: String, turn: Int) -> String { "\(conversationId)-\(turn)u" }
    static func assistantNodeId(_ conversationId: String, turn: Int) -> String { "\(conversationId)-\(turn)a" }

    // MARK: 一轮 → 消息

    /// 一轮最多两条：她（或别的 session / 后台任务）的输入一条，CC 这一轮所有的正文、思考、工具行合成一条。
    /// `parent` = 前一条消息的号（第一轮 nil）。没有输入的一轮只有回答那条；还没开始答的只有输入那条
    static func nodes(for turn: Turn, index: Int, conversationId: String, parent: String?) -> [ImportedNodePayload] {
        var out: [ImportedNodePayload] = []
        var parent = parent
        let userText = inputText(turn)
        let segments = self.segments(turn.parts)
        let userId = userNodeId(conversationId, turn: index), assistantId = assistantNodeId(conversationId, turn: index)
        if !userText.isEmpty {
            out.append(ImportedNodePayload(id: userId, role: "user", content: userText, contentType: "text",
                                           createTime: date(turn.at), parentId: parent, childrenIds: segments.isEmpty ? [] : [assistantId]))
            parent = userId
        }
        if !segments.isEmpty {
            out.append(ImportedNodePayload(id: assistantId, role: "assistant", content: searchText(turn.parts),
                                           contentType: "segmented", createTime: date(turn.endAt > 0 ? turn.endAt : turn.at),
                                           parentId: parent, childrenIds: [], segmentsData: try? encoder.encode(segments)))
        }
        return out
    }

    static func inputText(_ turn: Turn) -> String {
        var text = turn.text
        switch turn.from {
        case "session": text = "【\(turn.who ?? "别的 session") 发来】\n" + text
        case "system": text = "（后台任务通知）" + text
        case "none": return ""
        default: break
        }
        if let n = turn.images, n > 0 { text += (text.isEmpty ? "" : "\n") + "（附了 \(n) 张图）" }
        return text
    }

    /// 思考：电脑上没存正文的（现在的版本只存耗时）不放。工具：只有名字和一句摘要，配一条「在电脑上」的结果——
    /// 这样现成的工具行会显示「名字 · 摘要 已完成」，不会一直「进行中」
    static func segments(_ parts: [Part]) -> [MessageSegment] {
        var out: [MessageSegment] = []
        for (i, part) in parts.enumerated() {
            switch part {
            case .text(let s): if !s.isEmpty { out.append(.text(s)) }
            case .thinking(let s): if !s.isEmpty { out.append(.thinking(text: s, signature: nil)) }
            case .tool(let id, let name, let brief):
                let useId = id.isEmpty ? "t\(i)" : id
                out.append(.toolUse(id: useId, name: name, inputJSON: "{}", integrationName: brief.isEmpty ? name : "\(name) · \(brief)", iconName: icon(name)))
                out.append(.toolResult(toolUseId: useId, text: toolResultNote, isError: false, integrationName: nil))
            case .unknown: break
            }
        }
        return out
    }

    static let toolResultNote = "完整的输入输出在电脑上，这里只同步了一行摘要"

    /// 消息的纯文本（搜索、列表第二行用）：正文原样，思考包在 `ClaudeImporter` 那对标记里，工具一行「🔧 名字 摘要」。
    /// 不用现成的拍平函数：它会把每个工具的那句「在电脑上」也拼进去
    static func searchText(_ parts: [Part]) -> String {
        parts.compactMap { part -> String? in
            switch part {
            case .text(let s): return s.isEmpty ? nil : s
            case .thinking(let s): return s.isEmpty ? nil : "<<<THINK>>>\n\(s)\n<<</THINK>>>"
            case .tool(_, let name, let brief): return "🔧 \(name) \(brief)"
            case .unknown: return nil
            }
        }.joined(separator: "\n\n")
    }

    static func icon(_ tool: String) -> String? {
        switch tool {
        case "Bash", "BashOutput", "KillShell": return "terminal"
        case "Read", "NotebookRead": return "doc.text"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "square.and.pencil"
        case "Grep", "Glob", "ToolSearch": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Agent", "Task", "SendMessage": return "person.2"
        default: return nil
        }
    }

    static func date(_ ms: Double) -> Date? { ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil }

    /// 键排序：同样的分段每次编出同样的字节（重拉最后一轮时靠字节比较判断改没改，同 `ClaudeImporter`）
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

extension Conversation {
    /// 电脑上同步来的 session（文件夹楼层看历史）
    var isFolderSession: Bool { archiveKind == FolderHistory.archiveKind }
}
