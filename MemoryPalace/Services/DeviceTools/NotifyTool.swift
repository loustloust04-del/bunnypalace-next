import Foundation
import UserNotifications

/// notify_schedule：AI 发一条本地通知（一次性）。域 = notifications（二值，「AI 自主行为」区，默认关）。
/// P1 只发不收（category/action 点击回对话是 P2）。授权走 SystemAuthQueue。
enum NotifyTool {
    static let toolName = "notify_schedule"
    static let idPrefix = "ai-"

    static var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "给用户设备发一条本地通知（一次性）。after_seconds 与 at 二选一（at 为 ISO 8601 或相对写法）。同一 id 再次调用会覆盖旧通知。只在用户要求提醒/叫醒时用，不要用来复读聊天内容。",
            properties: [
                "title": ["type": "string"],
                "body": ["type": "string"],
                "after_seconds": ["type": "integer", "description": "多少秒后（≥1）"],
                "at": ["type": "string", "description": "具体时间"],
                "id": ["type": "string", "description": "可选，自定义通知 id（用于覆盖/取消）"],
            ],
            required: ["title"]
        )
    }

    static func execute(args: [String: Any]) async -> DeviceToolExec {
        guard let title = DeviceToolIO.str(args, "title") else { return DeviceToolIO.fail("missing_param", "缺 title") }
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            let granted = await SystemAuthQueue.shared.run { () -> Bool in
                (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            }
            if granted == nil { return DeviceToolIO.fail("timeout", "等待通知授权超时（30s）") }
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else {
            return DeviceToolIO.fail("authorization_denied", "用户未允许通知。可请用户到 系统设置→通知 开启。")
        }

        let now = Date()
        let fire: Date
        if let secs = DeviceToolIO.int(args, "after_seconds") {
            guard secs >= 1 else { return DeviceToolIO.fail("invalid_param", "after_seconds 必须 ≥ 1") }
            fire = now.addingTimeInterval(TimeInterval(secs))
        } else if let at = DeviceToolIO.parseDate(DeviceToolIO.str(args, "at"), now: now) {
            guard at > now else { return DeviceToolIO.fail("invalid_param", "at 必须是未来时间") }
            fire = at
        } else {
            return DeviceToolIO.fail("missing_param", "after_seconds 或 at 二选一")
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = DeviceToolIO.str(args, "body") ?? ""
        content.sound = .default
        let id = idPrefix + (DeviceToolIO.str(args, "id") ?? UUID().uuidString)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSince(now)), repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            return DeviceToolIO.ok(["id": id, "fires_at": DeviceToolIO.iso(fire), "scheduled": true])
        } catch {
            return DeviceToolIO.fail("failed", "排定失败：\(error.localizedDescription)")
        }
    }
}
