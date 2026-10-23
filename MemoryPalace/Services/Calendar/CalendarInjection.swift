import Foundation

// MARK: - 日历进 prompt（plan-calendar §八；实施偏差见 plan「P5 注入」注）
// 快到的纪念日：拼进时间轴插槽那段文字（按天稳定，进缓存前缀）——不新开插槽，免去逐预设补槽的风险（astra #10）。
// 今天的日记：走 PromptAssembler 的 volatileNote（cacheFriendly 时进动态段，不碰前缀，astra #11）。

enum CalendarInjection {

    /// 快到的纪念日。每条按自己的 remindDays（nil = 不告诉）；楼层总开关关 = 全不告诉。
    static func anniversaryText(anniversaries: [Anniversary], today: Date, calendar: Calendar = .current,
                                enabled: Bool) -> String? {
        guard enabled else { return nil }
        var lines: [(Int, String)] = []
        for a in anniversaries {
            guard let remind = a.remindDays, a.kind != .since,
                  let c = AnniversaryMath.countdown(for: a, today: today, gregorian: calendar),
                  !c.isPast, c.days <= remind else { continue }
            let md = calendar.dateComponents([.month, .day], from: c.target)
            let when: String
            switch c.days {
            case 0: when = "今天"
            case 1: when = "明天"
            case 2: when = "后天"
            default: when = "\(c.days) 天后"
            }
            var extra: [String] = []
            if let l = a.lunar { extra.append("农历\(AnniversaryText.lunarLabel(l))") }
            if a.isBirthday { extra.append("生日") }
            if a.kind == .yearly, let n = c.occurrence, !a.isBirthday { extra.append("第 \(n) 年") }
            let tail = extra.isEmpty ? "" : "（\(extra.joined(separator: "，"))）"
            lines.append((c.days, "· \(when)（\(md.month ?? 0)/\(md.day ?? 0)）是「\(a.title)」\(tail)"))
        }
        guard !lines.isEmpty else { return nil }
        return "[日历·快到的日子]\n" + lines.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
    }

    static let journalLimit = 800

    /// 今天的日记：日记闸和「告诉」子开关都开才注；空正文不注。
    static func todayJournalText(document: JournalDocument?, visible: Bool, inject: Bool) -> String? {
        guard visible, inject, let body = document?.body.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
        let clipped = body.count > journalLimit ? String(body.prefix(journalLimit)) + "……" : body
        return "[今天的日记｜用户自己写的，别逐字复述]\n" + clipped
    }

    // MARK: 楼层入口（读文件 + 开关）

    static func anniversaryText(profileId: String, today: Date = Date(), privacy: CalendarPrivacy = CalendarPrivacy()) -> String? {
        anniversaryText(anniversaries: AnniversaryStore.forProfile(profileId).loadAll(), today: today,
                        enabled: privacy.anniversaryInject(profileId))
    }

    static func todayJournalText(profileId: String, today: Date = Date(), privacy: CalendarPrivacy = CalendarPrivacy()) -> String? {
        let visible = privacy.journalVisible(profileId), inject = privacy.injectTodayJournal(profileId)
        guard visible, inject else { return nil }
        let doc = JournalStore.forProfile(profileId).load(date: DailyActivity.dayKey(today, calendar: .current))
        return todayJournalText(document: doc, visible: visible, inject: inject)
    }

    struct TimelineSlot {
        /// 插槽里的整段（时间轴 + 纪念日）
        var text: String?
        /// 只有时间轴那段
        var timeline: String?
        /// 这一轮注进去的时间轴条目（发送时记账用）
        var entries: [TimelineEntry]
    }

    /// 时间轴插槽：时间轴（v4-1：当前窗口还在历史窗口里的条目不注，见 `TimelineStore.injectable`）+ 快到的纪念日。
    /// 返回文字和选中的条目，实发与检查器同一行代码
    static func timelineSlot(profileId: String, currentConversationId: String = "", windowIds: Set<String> = [],
                             now: Date = MemoryClock.now) -> TimelineSlot {
        let entries = TimelineConsolidator.enabled
            ? TimelineStore.recent(profileId: profileId, now: now) {
                !TimelineStore.injectable($0, currentConversationId: currentConversationId, windowIds: windowIds)
            }
            : []
        let timeline = TimelineStore.injectionText(entries)
        let parts = [timeline, anniversaryText(profileId: profileId)].compactMap { $0 }
        return TimelineSlot(text: parts.isEmpty ? nil : parts.joined(separator: "\n\n"), timeline: timeline, entries: entries)
    }
}
