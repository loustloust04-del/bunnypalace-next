import MemoryCore
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
        /// 这一轮注进去的待续（每窗一行；发送时记账用）
        var pendingUnits: [TimelineStore.PendingUnit] = []
        /// 快到的纪念日整段（发送时记账用）；nil = 不带
        var anniversaryUnit: String? = nil
        /// 仅因来源窗已删 / 关参与被挡掉的项 + 老条目 + 待续窗条数
        var hiddenCount: Int = 0
    }

    /// 时间轴插槽：A4 一天一条（今天、昨天带各时段，再往前只带主调；当前窗口还在历史窗口里的项不注，见 `TimelineStore.injection`）
    /// + 待续一段 + 快到的纪念日（纪念日也随参与开关：`timeline || pending`）。返回文字和注进去的单位，实发与检查器同一行代码；文字和时间轴页那几行一字不差
    static func timelineSlot(profileId: String, currentConversationId: String = "", windowIds: Set<String> = [],
                             now: Date = MemoryClock.now, participation: EffectiveMemoryParticipation,
                             hiddenSources: Set<String> = []) -> TimelineSlot {
        // 待续：迁移过的楼层带 PendingStore 里「没做完」的；没迁移照读老条目里的老字段。组 prompt 在主线程：只读缓存不碰盘
        // 段④：本窗纸条把时间轴 / 待续拆成两项；nil = 老窗，待续跟时间轴一起（= 今天）
        // 关参与（master / 本窗 memoryEnabled）由值闸住：时间轴 / 待续 / 纪念日都不带（plan-memory-participation §2.2）
        // 来源窗已删 / 关参与（hiddenSources）：那窗的时间轴项 / 老条目 / 待续都在包里 `TimelineStore.injection` 挡
        //（待续只从注进去的窗里出，这里不再过滤一遍）
        let injection = participation.timeline || participation.pending
            ? TimelineStore.injection(memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId), now: now, currentConversationId: currentConversationId, windowIds: windowIds,
                                      openPending: { participation.pending ? PendingStore.openByConversationCached(profileId: profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: profileId)) : [:] },
                                      timelineLines: participation.timeline, hiddenConversations: hiddenSources)
            : TimelineStore.Injection(text: nil, units: [])
        let anniversary = participation.anniversary ? anniversaryText(profileId: profileId) : nil
        let parts = [injection.text, anniversary].compactMap { $0 }
        return TimelineSlot(text: parts.isEmpty ? nil : parts.joined(separator: "\n\n"), timeline: injection.text,
                            units: injection.units, pendingUnits: injection.pendingUnits,
                            anniversaryUnit: anniversary, hiddenCount: injection.hiddenCount)
    }
}
