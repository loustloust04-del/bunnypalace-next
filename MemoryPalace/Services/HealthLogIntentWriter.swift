import Foundation
import SwiftData

// MARK: - 聊天内健康记录意向（plan-health-chat-entry）
// ```health-log 块 → 落库 → 块变结果行。book-note/voice 之后意向协议第三例，
// 模式同 AgentBookNoteWriter：流式期间块可见=「TA 在记」，收口落地替换，替换后不含块=天然幂等。

enum HealthLogIntentWriter {

    private static let intentRegex = try! NSRegularExpression(
        pattern: "```health-log\\s*\\n([\\s\\S]*?)```",
        options: []
    )

    /// 两挂点共用入口（ContentView 收口订阅 + CVM insertProactiveAssistantMessage）。
    /// 无块零成本；now 可注入供测试。
    static func processChatIntents(nodeId: String, context: ModelContext, now: Date = Date()) {
        let nodeDesc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == nodeId })
        guard let node = (try? context.fetch(nodeDesc))?.first,
              node.role == "assistant",
              node.content.contains("```health-log") else { return }

        let content = node.content
        let ns = content as NSString
        let matches = intentRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return }

        var newContent = content
        // 倒序替换保 range 有效
        for m in matches.reversed() {
            let jsonStr = ns.substring(with: m.range(at: 1))
            let replacement = applyIntent(jsonStr, profileId: node.profileId, context: context, now: now)
            newContent = (newContent as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        node.content = newContent
        try? context.save()
    }

    // MARK: - 单条意向落地

    private static func applyIntent(_ jsonStr: String, profileId: String, context: ModelContext, now: Date) -> String {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return "♥ 记录格式无效，未落地"
        }
        switch type {
        case "weight":
            return applyWeight(obj, profileId: profileId, context: context, now: now)
        case "med":
            return applyMed(obj, profileId: profileId, context: context, now: now)
        case "cycle":
            return applyCycle(obj, profileId: profileId, context: context, now: now)
        case "intimacy":
            return applyIntimacy(obj, profileId: profileId, context: context, now: now)
        default:
            return "♥ 记录格式无效，未落地"
        }
    }

    private static func applyWeight(_ obj: [String: Any], profileId: String, context: ModelContext, now: Date) -> String {
        guard let kg = obj["kg"] as? Double, kg > 0, kg < 1000 else {
            return "♥ 记录格式无效，未落地"
        }
        var date = now
        if let dateStr = obj["date"] as? String {
            guard let parsed = Self.dayFormatter.date(from: dateStr) else {
                return "♥ 记录格式无效，未落地"
            }
            guard parsed <= now else {
                return "♥ 未来的日期记不了，没落地"
            }
            date = parsed
        }
        HealthLogStore.upsertWeight(context: context, profileId: profileId, date: date, weightKg: kg)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日"
        return "♥ 已记体重 \(String(format: "%.1f", kg)) 公斤（\(f.string(from: date))）"
    }

    private static func applyCycle(_ obj: [String: Any], profileId: String, context: ModelContext, now: Date) -> String {
        guard let flowStr = obj["flow"] as? String, let flow = CycleFlow.parse(flowStr) else {
            return "♥ 记录格式无效，未落地"
        }
        var date = now
        if let dateStr = obj["date"] as? String {
            guard let parsed = Self.dayFormatter.date(from: dateStr) else {
                return "♥ 记录格式无效，未落地"
            }
            guard parsed <= now else {
                return "♥ 未来的日期记不了，没落地"
            }
            date = parsed
        }
        HealthCycleStore.upsertDay(context: context, profileId: profileId, date: date, flow: flow)
        if obj["date"] != nil {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M 月 d 日"
            return "♥ 已记：经期打点（\(flow.label)，\(f.string(from: date))）"
        }
        return "♥ 已记：经期打点（\(flow.label)）"
    }

    /// 结果行文案克制（隐私拍板）：不复述内容不带 note。
    private static func applyIntimacy(_ obj: [String: Any], profileId: String, context: ModelContext, now: Date) -> String {
        var date = now
        if let dateStr = obj["date"] as? String {
            guard let parsed = Self.dayFormatter.date(from: dateStr) else {
                return "♥ 记录格式无效，未落地"
            }
            guard parsed <= now else {
                return "♥ 未来的日期记不了，没落地"
            }
            date = parsed
        }
        let note = (obj["note"] as? String)?.trimmingCharacters(in: .whitespaces)
        HealthLogStore.upsertIntimacy(context: context, profileId: profileId, date: date,
                                      note: (note?.isEmpty == false) ? note : nil)
        if obj["date"] != nil {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M 月 d 日"
            return "♥ 已记下了（\(f.string(from: date))）"
        }
        return "♥ 已记下了"
    }

    private static func applyMed(_ obj: [String: Any], profileId: String, context: ModelContext, now: Date) -> String {
        guard let query = (obj["name"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return "♥ 记录格式无效，未落地"
        }
        let meds = HealthLogStore.fetchActiveMeds(context: context, profileId: profileId)
        // 双向包含匹配（大小写不敏感），命中恰 1 条才落
        let hits = meds.filter {
            $0.name.localizedCaseInsensitiveContains(query) || query.localizedCaseInsensitiveContains($0.name)
        }
        guard let med = hits.first, hits.count == 1 else {
            return hits.isEmpty
                ? "♥ 没找到叫「\(query)」的药，没落地"
                : "♥ 「\(query)」对上了好几种药，没落地"
        }

        let todayLogs = HealthLogStore.fetchTodayLogs(context: context, profileId: profileId, now: now)

        // 选 slot：time 给了且是计划时刻 → 该 slot；time 给了非计划点 → 计划外；
        // time 省略 → 未打卡计划时刻里距现在最近的；全打过 → 计划外
        var slot: Int? = nil
        if let timeStr = obj["time"] as? String {
            guard let minute = Self.parseMinute(timeStr) else {
                return "♥ 记录格式无效，未落地"
            }
            slot = med.timesOfDay.contains(minute) ? minute : nil
        } else {
            let nowMinute = Calendar.current.component(.hour, from: now) * 60
                + Calendar.current.component(.minute, from: now)
            let unlogged = med.timesOfDay.filter { m in
                if case .taken = HealthLogStore.medState(medication: med, minuteOfDay: m, todayLogs: todayLogs, now: now) {
                    return false
                }
                return true
            }
            slot = unlogged.min(by: { abs($0 - nowMinute) < abs($1 - nowMinute) })
        }

        if let slot {
            if case .taken = HealthLogStore.medState(medication: med, minuteOfDay: slot, todayLogs: todayLogs, now: now) {
                return "♥ \(med.name) \(HealthLogStore.timeText(slot)) 已经打过卡了"
            }
            HealthLogStore.logIntake(context: context, profileId: profileId, medication: med, minuteOfDay: slot, now: now)
            return "♥ 已打卡：\(med.name) \(HealthLogStore.timeText(slot))"
        } else {
            context.insert(MedicationLog(profileId: profileId, medicationId: med.id, scheduledAt: nil, takenAt: now))
            try? context.save()
            return "♥ 已记：\(med.name) 计划外补服"
        }
    }

    // MARK: - 解析小件

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// "8:00" / "21:30" → 分钟数；非法返回 nil。
    static func parseMinute(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}
