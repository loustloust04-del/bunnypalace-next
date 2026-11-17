import Foundation
import MemoryCore

/// 别的窗口也知道自己醒来做了什么（plan-floor-main-thread §2.3，粟粟选 B）：每轮〔状态〕里带最近 24 小时、最多 3 次执行的一句话。
/// 当前就是 mainsession 时不带（原文就在对话里）；失败 / 跳过的不带；没发的写「这次没发」
enum WakeRecent {
    static let window: TimeInterval = 24 * 3600
    static let maxItems = 3

    @MainActor
    static func statusLines(profileId: String, current: Conversation?, now: Date = Date()) -> [String] {
        if let current, MainSession.isMain(current) { return [] }
        let mainId = WakeEngine.shared.profileManager?.profiles.first { $0.id == profileId }?.mainSessionId
        return lines(WakeEngine.shared.recentRuns(profileId: profileId), mainSessionId: mainId, now: now)
    }

    /// 纯函数（单测）：runs 新→旧
    static func lines(_ runs: [WakeRun], mainSessionId: String?, now: Date, calendar: Calendar = .current) -> [String] {
        let picked = runs.filter { $0.status == .ok && now.timeIntervalSince($0.startedAt) < window && $0.startedAt <= now }.prefix(maxItems)
        guard !picked.isEmpty else { return [] }
        let items = picked.map { run -> String in
            let summary = (run.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let what: String
            if run.deliveredMessageId == nil {
                what = "这次没发" + (summary.isEmpty ? "" : "：\(summary)")
            } else if let delivered = run.deliveredConversationId, delivered != mainSessionId {
                what = (summary.isEmpty ? "" : "\(summary)") + "（发在别的对话里）"
            } else {
                what = summary.isEmpty ? "发了" : summary
            }
            return "- \(when(run.startedAt, now: now, calendar: calendar))「\(run.taskTitle)」：\(what)"
        }
        return ["你最近自己醒来做的事（结果发在 main session）："] + items
    }

    private static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        let day = calendar.isDate(date, inSameDayAs: now) ? "今天" : "昨天"
        return "\(day) \(f.string(from: date))"
    }
}
