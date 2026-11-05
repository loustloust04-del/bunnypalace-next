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
        /// 这一轮注进去的时间轴单位（一天的主调行 / 一项 / 一条老条目；发送时记账用）
        var units: [TimelineStore.Unit]
    }

    /// 时间轴插槽：A4 一天一条（今天、昨天带各时段，再往前只带主调；当前窗口还在历史窗口里的项不注，见 `TimelineStore.injection`）
    /// + 待续一段 + 快到的纪念日。返回文字和注进去的单位，实发与检查器同一行代码；文字和时间轴页那几行一字不差
    static func timelineSlot(profileId: String, currentConversationId: String = "", windowIds: Set<String> = [],
                             now: Date = MemoryClock.now) -> TimelineSlot {
        // v5【开窗口】A4 那一勾（没写过跟 mem_content_timeline = 今天）。
        // 待续：迁移过的楼层带 PendingStore 里「没做完」的；没迁移照读老条目里的老字段。组 prompt 在主线程：只读缓存不碰盘
        let injection = MemoryOpenWindow.injects(.a4)
            ? TimelineStore.injection(profileId: profileId, now: now, currentConversationId: currentConversationId, windowIds: windowIds,
                                      openPending: { PendingStore.openByConversationCached(profileId: profileId) })
            : TimelineStore.Injection(text: nil, units: [])
        let parts = [injection.text, anniversaryText(profileId: profileId)].compactMap { $0 }
        return TimelineSlot(text: parts.isEmpty ? nil : parts.joined(separator: "\n\n"), timeline: injection.text, units: injection.units)
    }
}
