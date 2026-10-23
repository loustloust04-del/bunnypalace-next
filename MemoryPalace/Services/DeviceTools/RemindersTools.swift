import Foundation
import EventKit

/// 提醒事项三工具：reminders_query / reminders_create / reminders_complete。域 = reminders（三档，**与 calendar 隔离**——研究 §四洞 2）。
enum RemindersTools {
    static let queryName = "reminders_query"
    static let createName = "reminders_create"
    static let completeName = "reminders_complete"
    static let names: Set<String> = [queryName, createName, completeName]

    static var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: queryName,
                description: "查询用户的系统提醒事项。默认只返回未完成的，按到期时间排序；due_before 可限定到期窗口（ISO 8601 或相对写法）。",
                properties: ([
                    "list": ["type": "string", "description": "只查某个列表（按名称），默认全部"],
                    "include_completed": ["type": "boolean", "description": "是否包含已完成，默认 false"],
                    "due_before": ["type": "string", "description": "只要在此之前到期的（含无到期日的不返回）"],
                    "limit": ["type": "integer", "description": "默认 30，上限 100"],
                ] as [String: Any]),
                required: []
            ),
            ToolDefinition(
                name: createName,
                description: "创建一条系统提醒事项。due 可选（给了会带一次到点提醒）。用户会在提醒事项 app 里立刻看到。",
                properties: ([
                    "title": ["type": "string"],
                    "due": ["type": "string", "description": "到期时间，ISO 8601 或相对写法（+2h/tomorrow）"],
                    "list": ["type": "string", "description": "写进哪个列表（按名称），默认系统默认列表"],
                    "notes": ["type": "string"],
                    "priority": ["type": "integer", "description": "0=无 1=高 5=中 9=低（系统语义）"],
                ] as [String: Any]),
                required: ["title"]
            ),
            ToolDefinition(
                name: completeName,
                description: "把一条提醒标记为已完成。id 来自 reminders_query。",
                properties: (["id": ["type": "string"]] as [String: Any]),
                required: ["id"]
            ),
        ]
    }

    static func execute(name: String, args: [String: Any]) async -> DeviceToolExec {
        let svc = EventKitService.shared
        switch await svc.ensureRemindersAccess() {
        case .denied: return DeviceToolIO.fail("authorization_denied", "用户未授权提醒事项访问。可请用户到 系统设置→隐私→提醒事项 开启。")
        case .timeout: return DeviceToolIO.fail("timeout", "等待提醒事项授权超时（30s）")
        case .granted: break
        }
        let now = Date()
        switch name {
        case queryName:
            let limit = min(max(DeviceToolIO.int(args, "limit") ?? 30, 1), 100)
            let dueBefore = DeviceToolIO.parseDate(DeviceToolIO.str(args, "due_before"), now: now)
            guard let (items, total) = await svc.queryReminders(listTitle: DeviceToolIO.str(args, "list"),
                                                                 includeCompleted: DeviceToolIO.bool(args, "include_completed") ?? false,
                                                                 dueBefore: dueBefore, limit: limit) else {
                return DeviceToolIO.fail("timeout", "读取提醒事项超时（10s）")
            }
            var data: [String: Any] = ["reminders": items.map(EventKitService.describe), "count": items.count]
            if total > items.count { data["total_available"] = total; data["_warning"] = "已按 limit 截断" }
            return DeviceToolIO.ok(data)

        case createName:
            guard let title = DeviceToolIO.str(args, "title") else { return DeviceToolIO.fail("missing_param", "缺 title") }
            let due = DeviceToolIO.parseDate(DeviceToolIO.str(args, "due"), now: now)
            if DeviceToolIO.str(args, "due") != nil, due == nil { return DeviceToolIO.fail("invalid_param", "due 解析失败") }
            do {
                let r = try svc.createReminder(title: title, due: due, listTitle: DeviceToolIO.str(args, "list"),
                                               notes: DeviceToolIO.str(args, "notes"), priority: DeviceToolIO.int(args, "priority"))
                let due = r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                let card = DeviceToolIO.card(
                    type: "reminder",
                    title: r.title ?? "（无标题）",
                    subtitle: due.map { String(DeviceToolIO.iso($0).prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "无到期日",
                    detail: r.calendar?.title,
                    icon: "checklist",
                    deeplink: DeviceToolIO.remindersDeeplink
                )
                return DeviceToolIO.ok(["reminder": EventKitService.describe(r), "created": true], card: card)
            } catch {
                return DeviceToolIO.fail("failed", "创建失败：\(error.localizedDescription)")
            }

        case completeName:
            guard let id = DeviceToolIO.str(args, "id") else { return DeviceToolIO.fail("missing_param", "缺 id") }
            do {
                let ok = try svc.completeReminder(id: id)
                return ok ? DeviceToolIO.ok(["completed": true, "id": id])
                          : DeviceToolIO.fail("not_found", "没找到该提醒（重新 reminders_query）")
            } catch {
                return DeviceToolIO.fail("failed", "标记失败：\(error.localizedDescription)")
            }
        default:
            return DeviceToolIO.fail("not_available", "未知提醒工具 \(name)")
        }
    }
}
