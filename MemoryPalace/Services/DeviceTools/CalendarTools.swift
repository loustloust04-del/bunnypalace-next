import Foundation
import EventKit

/// 日历三工具（plan-设备工具 §2）：calendar_query / calendar_create / calendar_delete。域 = calendar（三档）。
enum CalendarTools {
    static let queryName = "calendar_query"
    static let createName = "calendar_create"
    static let deleteName = "calendar_delete"
    static let names: Set<String> = [queryName, createName, deleteName]

    static var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: queryName,
                description: "查询用户的系统日历事件。默认窗口=从现在起未来 7 天；时间接受 ISO 8601（无时区按设备本地）或相对写法（-7d/+2h/today/tomorrow）。重复事件返回 recurring:true + occurrence_date（删除单次实例时要带上）。结果按开始时间排序，超过 limit 截断并附 total_available。",
                properties: ([
                    "from": ["type": "string", "description": "起始时间，默认 now"],
                    "to": ["type": "string", "description": "结束时间，默认 from+7d"],
                    "limit": ["type": "integer", "description": "最多返回条数，默认 20，上限 100"],
                    "calendar": ["type": "string", "description": "只查某个日历（按名称），默认全部"],
                ] as [String: Any]),
                required: []
            ),
            ToolDefinition(
                name: createName,
                description: "在用户的系统日历创建一个事件。start 必填；end 缺省=start+1h（全天事件忽略）。创建成功返回事件 id，用户会在系统日历 app 里立刻看到。",
                properties: ([
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": "ISO 8601 或相对写法"],
                    "end": ["type": "string", "description": "默认 start+1h"],
                    "all_day": ["type": "boolean", "description": "全天事件，默认 false"],
                    "location": ["type": "string"],
                    "notes": ["type": "string"],
                    "calendar": ["type": "string", "description": "写进哪个日历（按名称），默认系统默认日历"],
                ] as [String: Any]),
                required: ["title", "start"]
            ),
            ToolDefinition(
                name: deleteName,
                description: "删除一个日历事件。id 来自 calendar_query。重复事件：带 occurrence_date 删单次实例，span=future 删该实例及之后全部。删除不可撤销，用户没明确说要删时先确认。",
                properties: ([
                    "id": ["type": "string"],
                    "occurrence_date": ["type": "string", "description": "重复事件的实例日期（来自 query 的 occurrence_date）"],
                    "span": ["type": "string", "enum": ["this", "future"], "description": "默认 this"],
                ] as [String: Any]),
                required: ["id"]
            ),
        ]
    }

    /// 事件卡：系统日历图标 + 标题 + 时间；点击跳系统日历到那天。
    private static func eventCard(_ ev: EKEvent) -> [String: Any] {
        let when: String
        if ev.isAllDay {
            when = DeviceToolIO.iso(ev.startDate).prefix(10) + " 全天"
        } else {
            let s = DeviceToolIO.iso(ev.startDate)
            when = String(s.prefix(16)).replacingOccurrences(of: "T", with: " ")
        }
        return DeviceToolIO.card(
            type: "calendar_event",
            title: ev.title ?? "（无标题）",
            subtitle: when,
            detail: [ev.location, ev.calendar?.title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "),
            icon: "calendar",
            deeplink: DeviceToolIO.calendarDeeplink(for: ev.startDate),
            eventId: ev.eventIdentifier,
            occurrence: ev.hasRecurrenceRules ? ev.occurrenceDate : nil
        )
    }

    static func execute(name: String, args: [String: Any]) async -> DeviceToolExec {
        let svc = EventKitService.shared
        switch await svc.ensureEventsAccess() {
        case .denied: return DeviceToolIO.fail("authorization_denied", "用户未授权日历访问。可请用户到 系统设置→隐私→日历 开启。")
        case .timeout: return DeviceToolIO.fail("timeout", "等待日历授权超时（30s）")
        case .granted: break
        }
        let now = Date()
        switch name {
        case queryName:
            let from = DeviceToolIO.parseDate(DeviceToolIO.str(args, "from"), now: now) ?? now
            let to = DeviceToolIO.parseDate(DeviceToolIO.str(args, "to"), now: from) ?? from.addingTimeInterval(7 * 86400)
            guard to > from else { return DeviceToolIO.fail("invalid_param", "to 必须晚于 from") }
            let limit = min(max(DeviceToolIO.int(args, "limit") ?? 20, 1), 100)
            let (events, total) = svc.queryEvents(from: from, to: to, limit: limit, calendarTitle: DeviceToolIO.str(args, "calendar"))
            var data: [String: Any] = [
                "events": events.map(EventKitService.describe),
                "count": events.count,
                "range": ["from": DeviceToolIO.iso(from), "to": DeviceToolIO.iso(to)],
            ]
            if total > events.count { data["total_available"] = total; data["_warning"] = "已按 limit 截断" }
            // 单条命中才出卡：多条列表用文字更好读（卡片堆叠会挤爆气泡）
            if events.count == 1, let ev = events.first {
                return DeviceToolIO.ok(data, card: eventCard(ev))
            }
            return DeviceToolIO.ok(data)

        case createName:
            guard let title = DeviceToolIO.str(args, "title") else { return DeviceToolIO.fail("missing_param", "缺 title") }
            guard let start = DeviceToolIO.parseDate(DeviceToolIO.str(args, "start"), now: now) else { return DeviceToolIO.fail("invalid_param", "start 解析失败") }
            let allDay = DeviceToolIO.bool(args, "all_day") ?? false
            let end = DeviceToolIO.parseDate(DeviceToolIO.str(args, "end"), now: start) ?? start.addingTimeInterval(allDay ? 86400 : 3600)
            guard end > start else { return DeviceToolIO.fail("invalid_param", "end 必须晚于 start") }
            do {
                let ev = try svc.createEvent(title: title, start: start, end: end, allDay: allDay,
                                             location: DeviceToolIO.str(args, "location"), notes: DeviceToolIO.str(args, "notes"),
                                             calendarTitle: DeviceToolIO.str(args, "calendar"))
                return DeviceToolIO.ok(["event": EventKitService.describe(ev), "created": true], card: eventCard(ev))
            } catch {
                return DeviceToolIO.fail("failed", "创建失败：\(error.localizedDescription)")
            }

        case deleteName:
            guard let id = DeviceToolIO.str(args, "id") else { return DeviceToolIO.fail("missing_param", "缺 id") }
            let occ = DeviceToolIO.parseDate(DeviceToolIO.str(args, "occurrence_date"), now: now)
            let span = EventKitService.DeleteSpan(rawValue: DeviceToolIO.str(args, "span") ?? "this") ?? .this
            do {
                let removed = try svc.deleteEvent(id: id, occurrenceDate: occ, span: span)
                return removed ? DeviceToolIO.ok(["deleted": true, "id": id, "span": span.rawValue])
                               : DeviceToolIO.fail("not_found", "没找到该事件（id 可能已失效，重新 calendar_query）")
            } catch {
                return DeviceToolIO.fail("failed", "删除失败：\(error.localizedDescription)")
            }
        default:
            return DeviceToolIO.fail("not_available", "未知日历工具 \(name)")
        }
    }
}
