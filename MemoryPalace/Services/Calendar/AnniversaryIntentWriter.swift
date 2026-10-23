import Foundation
import SwiftData
import CryptoKit

// MARK: - 聊天里记纪念日（plan-calendar §八，astra #13）
// ```anniversary 块 → 校验 → 按来源 upsert 写盘 → 写成功后才把块换成结果行。
// 幂等：同一块（nodeId + 块内容哈希）重复处理只会更新同一条；同名同日期也合并，不会加两条。
// 首版不接 CC 编辑 / AgentBridge 自主消息（plan §〇）。

struct AnniversaryIntent: Equatable {
    var title: String
    var kind: Anniversary.Kind
    var date: String
    var lunar: LunarMonthDay?
    var isBirthday: Bool
    var remindDays: Int?
}

enum AnniversaryIntentWriter {

    static let blockTag = "```anniversary"

    private static let intentRegex = try! NSRegularExpression(pattern: "```anniversary\\s*\\n([\\s\\S]*?)```", options: [])

    /// 解析 + 校验。nil = 格式不对。
    static func parse(_ json: String, today: Date, calendar: Calendar = .current) -> AnniversaryIntent? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTitle = obj["title"] as? String else { return nil }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 40 else { return nil }
        let kind = (obj["kind"] as? String).flatMap(Anniversary.Kind.init(rawValue:)) ?? .yearly
        var lunar: LunarMonthDay?
        if kind == .yearly, let l = obj["lunar"] as? [String: Any], let m = l["month"] as? Int, let d = l["day"] as? Int,
           (1...12).contains(m), (1...30).contains(d) {
            lunar = LunarMonthDay(month: m, day: d, leap: l["leap"] as? Bool ?? false)
        }
        var date = (obj["date"] as? String) ?? ""
        if DailyActivity.date(fromKey: date, calendar: calendar) == nil {
            // 农历生日可以不给公历日期：用今天当「第一次」的基准
            guard lunar != nil else { return nil }
            date = DailyActivity.dayKey(today, calendar: calendar)
        }
        let remind = obj["remindDays"] as? Int
        return AnniversaryIntent(title: title, kind: kind, date: date, lunar: lunar,
                                 isBirthday: kind == .yearly && (obj["birthday"] as? Bool ?? false),
                                 remindDays: remind.map { max(0, min(30, $0)) } ?? 3)
    }

    /// 纯函数：决定写哪一条（新建或更新已有）。
    static func upsert(_ intent: AnniversaryIntent, source: Anniversary.Source, existing: [Anniversary]) -> Anniversary {
        let norm = { (s: String) in s.trimmingCharacters(in: .whitespaces).lowercased() }
        var target = existing.first { $0.source == source }
            ?? existing.first { norm($0.title) == norm(intent.title) && $0.kind == intent.kind && $0.date == intent.date && $0.lunar == intent.lunar }
            ?? Anniversary(title: intent.title, kind: intent.kind, date: intent.date)
        target.title = intent.title
        target.kind = intent.kind
        target.date = intent.date
        target.lunar = intent.lunar
        target.isBirthday = intent.isBirthday
        target.remindDays = intent.remindDays
        target.source = source
        return target
    }

    static func blockHash(_ json: String) -> String {
        SHA256.hash(data: Data(json.trimmingCharacters(in: .whitespacesAndNewlines).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func resultLine(_ a: Anniversary) -> String {
        let when = a.lunar.map { "农历\(AnniversaryText.lunarLabel($0))" } ?? a.date
        return "✦ 记下了：\(a.title)（\(when)）"
    }

    /// 两个挂点共用（ContentView 收口订阅 + CVM 主动消息）。无块零成本。
    @MainActor
    static func processChatIntents(nodeId: String, context: ModelContext, now: Date = Date(), store: AnniversaryStore? = nil) {
        let nodeDesc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == nodeId })
        guard let node = (try? context.fetch(nodeDesc))?.first,
              node.role == "assistant",
              node.content.contains(blockTag) else { return }
        let content = node.content
        let ns = content as NSString
        let matches = intentRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return }
        let store = store ?? AnniversaryStore.forProfile(node.profileId)

        var newContent = content
        var wrote = false
        for m in matches.reversed() {
            let json = ns.substring(with: m.range(at: 1))
            let replacement: String
            if let intent = parse(json, today: now) {
                let a = upsert(intent, source: Anniversary.Source(nodeId: nodeId, blockHash: blockHash(json)), existing: store.loadAll())
                do {
                    try store.save(a)       // 写盘成功才替换块
                    replacement = resultLine(a)
                    wrote = true
                } catch {
                    continue                // 写失败：块留着，下次收口再试（按来源 upsert，不会重复）
                }
            } else {
                replacement = "✦ 日子格式不对，没记上"
            }
            newContent = (newContent as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        node.content = newContent
        try? context.save()
        if wrote {
            NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
            CalendarSnapshotWriter.refresh(profileId: node.profileId)
        }
    }

    /// 约定段（文件库提示词里）：楼层「纪念日告诉小克」开着才教。纯静态文本，缓存安全。
    static func hint(profileId: String, privacy: CalendarPrivacy = CalendarPrivacy()) -> String {
        guard privacy.anniversaryInject(profileId) else { return "" }
        return """

        纪念日：{{user}} 明确让你记一个日子（生日、纪念日、要倒数的事）时，在回复里输出：
        ```anniversary
        {"title": "妈妈生日", "kind": "yearly", "date": "1970-10-28", "lunar": {"month": 9, "day": 9, "leap": false}, "birthday": true}
        ```
        kind：yearly 每年一次 / countdown 倒数到那天 / since 从那天起算。按农历过的才写 lunar；不知道年份的生日，date 写今年那天。系统会真实记进日历并把块变成结果行。只在{{user}}明确说了才记，不要猜。

        """
    }
}
