#if PERSONAL_APPS
import Foundation

/// 楼层 AI 读死亡天平（plan-death-scale §4.5）：只读；工具启用且本楼层被授权才下发，执行时再判一次
enum DeathScaleAITool {
    struct Result { let text: String; let isError: Bool }

    static let toolName = "death_scale"
    static let sections = ["reasons", "ledger", "hours", "carnet", "all"]
    static let defaultLimit = 50
    static let maxLimit = 500
    /// 留在 ToolResultOffload 的 50KB 上限以内，结果永远不外置成文件
    static let maxBytes = 40 * 1024

    private static let desc = """
    Read-only access to "Mort sans sépulture", Susu's own private scale. It holds her personal record of \
    reasons to die (left pan) and reasons to live (right pan), each written by her with a weight from 1 to 9; \
    an append-only ledger of every change with the running totals of both pans; the time periods she marked, \
    to the second; and her notebook (carnet). This is Susu's intimate private record. You can only read it, \
    never change it. All times are Asia/Shanghai (UTC+8).
    section: reasons = both pans and their totals; ledger = most recent ledger entries; hours = marked periods; \
    carnet = the notebook text; all = everything. limit caps how many ledger entries / periods are returned \
    (default 50, max 500).
    """

    static var definition: ToolDefinition {
        ToolDefinition(name: toolName, description: desc, properties: [
            "section": ["type": "string", "enum": sections, "description": "Which part to read"],
            "limit": ["type": "integer", "description": "Max ledger entries / periods to return, newest kept (default 50, max 500)"],
        ], required: ["section"])
    }

    static func isAvailable(profileId: String?, toolEnabled: Bool, readableProfileIds: [String]) -> Bool {
        guard toolEnabled, let profileId, !profileId.isEmpty else { return false }
        return readableProfileIds.contains(profileId)
    }

    @MainActor
    static func isAvailable(profileId: String?, store: DeathScaleStore? = nil) -> Bool {
        isAvailable(profileId: profileId,
                    toolEnabled: RightPanelToolManager.storedTool(DeathScaleGate.toolId)?.isEnabled ?? false,
                    readableProfileIds: (store ?? .shared).readableProfileIds)
    }

    @MainActor
    static func execute(inputJSON: String, profileId: String, store: DeathScaleStore? = nil,
                        toolEnabled: Bool? = nil) -> Result {
        let store = store ?? .shared
        let enabled = toolEnabled ?? (RightPanelToolManager.storedTool(DeathScaleGate.toolId)?.isEnabled ?? false)
        guard isAvailable(profileId: profileId, toolEnabled: enabled, readableProfileIds: store.readableProfileIds) else {
            return Result(text: "permission_denied: this floor is not allowed to read Mort sans sépulture.", isError: true)
        }
        guard let data = inputJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Result(text: "Arguments must be a JSON object.", isError: true)
        }
        guard let section = args["section"] as? String, sections.contains(section) else {
            return Result(text: "section must be one of: " + sections.joined(separator: " / "), isError: true)
        }
        let limit = min(max((args["limit"] as? Int) ?? defaultLimit, 1), maxLimit)
        var parts = ["Times are Asia/Shanghai (UTC+8)."]
        if section == "reasons" || section == "all" { parts.append(reasons(store)) }
        if section == "hours" || section == "all" { parts.append(hours(store, limit: limit)) }
        if section == "ledger" || section == "all" { parts.append(ledger(store, limit: limit)) }
        if section == "carnet" || section == "all" { parts.append("LE CARNET (notebook):\n" + (store.carnet.isEmpty ? "(empty)" : store.carnet)) }
        return Result(text: capped(parts.joined(separator: "\n\n")), isError: false)
    }

    // MARK: - 输出

    @MainActor
    private static func reasons(_ store: DeathScaleStore) -> String {
        func pan(_ side: DeathScale.Side, _ title: String) -> String {
            let rows = store.reasons.filter { $0.side == side }
            let head = "\(title) — total weight \(store.sum(side)), \(rows.count) reason(s)"
            return ([head] + rows.map { r in
                var line = "- [\(r.weight)] \(r.text) · placed \(DeathScaleTime.format(r.createdAt))"
                if r.modifiedAt != r.createdAt { line += " · last changed \(DeathScaleTime.format(r.modifiedAt))" }
                return line
            }).joined(separator: "\n")
        }
        return pan(.die, "POUR MOURIR (reasons to die, left pan)") + "\n\n" + pan(.live, "POUR VIVRE (reasons to live, right pan)")
    }

    @MainActor
    private static func hours(_ store: DeathScaleStore, limit: Int) -> String {
        let all = store.hours
        guard !all.isEmpty else { return "LES HEURES (marked periods): none" }
        let rows = all.suffix(limit).map { h -> String in
            guard let end = h.end else { return "- \(DeathScaleTime.format(h.start)) – ongoing" }
            return "- \(DeathScaleTime.format(h.start)) – \(DeathScaleTime.format(end)) (\(duration(end.timeIntervalSince(h.start))))"
        }
        return (["LES HEURES (marked periods), \(rows.count) of \(all.count):"] + rows).joined(separator: "\n")
    }

    @MainActor
    private static func ledger(_ store: DeathScaleStore, limit: Int) -> String {
        let all = store.ledger
        guard !all.isEmpty else { return "LE REGISTRE (ledger): empty" }
        let rows = all.suffix(limit).map { e -> String in
            var line = "- \(DeathScaleTime.format(e.at)) · \(e.kind.rawValue)"
            if let side = e.side { line += " · \(side.rawValue)" }
            if let text = e.text { line += " · \(text)" }
            if e.from != nil || e.to != nil { line += " · \(e.from ?? "∅") → \(e.to ?? "∅")" }
            return line + " · totals die \(e.sumDie) / live \(e.sumLive)"
        }
        return (["LE REGISTRE (ledger), last \(rows.count) of \(all.count), oldest first:"] + rows).joined(separator: "\n")
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    private static func capped(_ text: String) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var out = ""
        var bytes = 0
        for ch in text {
            bytes += String(ch).utf8.count
            if bytes > maxBytes { break }
            out.append(ch)
        }
        return out + "\n…(truncated; ask for a single section or a smaller limit)"
    }
}
#endif
