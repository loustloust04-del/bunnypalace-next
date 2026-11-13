import Foundation
import Observation

/// 进度卡 B（粟粟 10-03「都按推荐」）：hub 推下来的 CC 会话状态（`session_phase` 帧）。
/// 真相源是 hub 的 phase 状态机（发消息 / 提问 / 回复 / Stop hook），这里不猜
struct CCSessionPhase: Equatable {
    enum Phase: String { case idle, working, waiting, done }

    let sessionName: String
    let chatId: String
    let phase: Phase
    let detail: String?
    let since: Date?
    let updated: Date
    /// tmux 会话能按 Esc 停；无终端（stream）会话 hub 给 false
    let canStop: Bool
    /// 这一轮用了几次「干活」的工具（hub 从 transcript 数，回话用的 cc-bridge 工具不算）；0 = 纯聊天
    let tools: Int
    /// 最近用的那个工具（原名，显示时翻成中文）
    let tool: String?

    /// 做完了亮多久再收（秒）
    static let doneLinger: TimeInterval = 8

    init?(frame obj: [String: Any]) {
        guard let session = obj["session_name"] as? String, !session.isEmpty,
              let chat = obj["chat_id"] as? String, !chat.isEmpty,
              let raw = obj["phase"] as? String, let phase = Phase(rawValue: raw) else { return nil }
        sessionName = session
        chatId = chat
        self.phase = phase
        detail = (obj["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        since = (obj["since_unix"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        updated = Date(timeIntervalSince1970: (obj["updated_unix"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
        canStop = obj["can_stop"] as? Bool ?? false
        tools = (obj["tools"] as? NSNumber)?.intValue ?? 0
        tool = (obj["tool"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    func isVisible(now: Date) -> Bool {
        // 粟粟 10-04：普通聊天（这一轮没动工具）不出卡，照旧三个点；等你回答不管动没动工具都出
        switch phase {
        case .waiting: return true
        case .working: return tools > 0
        case .done: return tools > 0 && now.timeIntervalSince(updated) < Self.doneLinger
        case .idle: return false
        }
    }

    func headline(now: Date) -> String {
        switch phase {
        case .working:
            let head = since.map { "干活中 · \(Self.elapsed(now.timeIntervalSince($0)))" } ?? "干活中"
            return tool.map { "\(head) · \(Self.toolName($0))" } ?? head
        case .waiting: return detail.map { "在等你回答：\($0)" } ?? "在等你"
        case .done:
            let head = since.map { "做完了 · 用时 \(Self.elapsed(updated.timeIntervalSince($0)))" } ?? "做完了"
            return tools > 0 ? "\(head) · 用了 \(tools) 次工具" : head
        case .idle: return ""
        }
    }

    /// Claude Code 工具名 → 卡上的中文；MCP 工具取最后一段；不认识的原样
    static func toolName(_ raw: String) -> String {
        let names = ["Bash": "跑命令", "Read": "读文件", "Edit": "改文件", "MultiEdit": "改文件", "Write": "写文件",
                     "NotebookEdit": "改笔记本", "Grep": "搜文件", "Glob": "找文件", "WebSearch": "搜网页", "WebFetch": "看网页",
                     "Task": "派子任务", "Agent": "派子任务", "TodoWrite": "记待办"]
        if let n = names[raw] { return n }
        if raw.hasPrefix("mcp__"), let last = raw.split(separator: "__").last { return String(last) }
        return raw
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分钟" }
        return "\(s / 3600) 小时 \(s % 3600 / 60) 分钟"
    }
}

/// 按对话存（帧里的 chat_id = 这个会话最近一次从哪个对话发来）；聊天页底部的状态卡读它。
/// 按 hub 分开存（plan-multi-hub B2.8）：每台各是各的，同名会话只在同一台里互相顶；读的时候给对话所属那台（默认主 hub）
@MainActor @Observable
final class CCSessionPhaseStore {
    static let shared = CCSessionPhaseStore()

    /// hubId → chatId → 阶段
    private(set) var byHub: [String: [String: CCSessionPhase]] = [:]

    /// 写入前核来源（plan-multi-hub B3.2 / research R7）：这条对话当前绑这台、或最近在这台上发过才收（app 根接上
    /// ConversationViewModel.acceptsCCFrame）。改绑后旧那台还按 chat_id 推的阶段不写进来。nil = 照收
    @ObservationIgnored var accepts: ((_ chatId: String, _ hubId: String) -> Bool)?
    /// 这个对话的一轮收口了（working / waiting / 没有记录 → done / idle）：app 根接 ConversationViewModel.ccTurnSettled，
    /// 清等待泡、让等着的贴表情马上投（plan-cc-reactions-1105 §1）。`at` = 帧里的 updated
    @ObservationIgnored var onTurnSettled: ((_ chatId: String, _ hubId: String, _ at: Date) -> Void)?

    func apply(_ p: CCSessionPhase, hubId: String = CCBridgeWebSocketClient.primaryHubId) {
        guard accepts?(p.chatId, hubId) ?? true else { return }
        var byChat = byHub[hubId] ?? [:]
        let previous = byChat[p.chatId]?.phase
        // 同一个会话改从别的对话发了：旧对话不再挂它
        for (chat, old) in byChat where old.sessionName == p.sessionName && chat != p.chatId { byChat[chat] = nil }
        byChat[p.chatId] = p
        byHub[hubId] = byChat
        let settled: Set<CCSessionPhase.Phase> = [.done, .idle]
        if settled.contains(p.phase), !(previous.map(settled.contains) ?? false) {
            onTurnSettled?(p.chatId, hubId, p.updated)
        }
    }

    func phase(for conversationId: String, hubId: String = CCBridgeWebSocketClient.primaryHubId) -> CCSessionPhase? {
        byHub[hubId]?[conversationId]
    }

    /// 删 hub：那台推来的阶段一起清
    func removeHub(_ hubId: String) {
        byHub[hubId] = nil
    }
}
