import Foundation
import SwiftData
import UserNotifications

// MARK: - 吃药本地通知（plan-health-module §2）
// 计划纯函数（可测）+ 薄壳调度（协议 spy 可测）。
// 重注册幂等：med- 前缀全清 → 批量加。改药/归档/开关/启动/切楼层都走 resync 同一入口。

struct ReminderSpec: Equatable {
    let identifier: String   // "med-<uuid>-<minute>"
    let title: String        // 药名（粟粟拍板：通知显示药名）
    let body: String
    let hour: Int
    let minute: Int
}

enum MedReminderPlanner {
    static let identifierPrefix = "med-"
    /// iOS 待处理通知上限 64 条/app 的兜底守卫（个位数药 × ≤4 时刻远够不着）。
    static let maxReminders = 40

    /// active && reminderEnabled 的药 × timesOfDay 展开。超守卫截断（truncated 供 UI 提示）。
    static func plan(meds: [Medication]) -> (specs: [ReminderSpec], truncated: Bool) {
        var specs: [ReminderSpec] = []
        for med in meds where !med.isArchived && med.reminderEnabled {
            for minute in med.timesOfDay.sorted() {
                specs.append(ReminderSpec(
                    identifier: "\(identifierPrefix)\(med.id.uuidString)-\(minute)",
                    title: med.name,
                    body: med.dosage.isEmpty ? "该吃药啦" : "\(med.dosage) · 该吃药啦",
                    hour: minute / 60,
                    minute: minute % 60
                ))
            }
        }
        if specs.count > maxReminders {
            return (Array(specs.prefix(maxReminders)), true)
        }
        return (specs, false)
    }
}

// MARK: - 调度薄壳（协议隔离 UNUserNotificationCenter，spy 可测）

protocol MedNotificationScheduling {
    func pendingMedIdentifiers() async -> [String]
    func remove(identifiers: [String])
    func add(_ spec: ReminderSpec) async
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
}

final class SystemMedNotificationCenter: MedNotificationScheduling {
    // #035：测试宿主下全部空操作（首启 / 切楼层 / 直接 resync 都挡），注 spy 的业务测试不经过这里
    func pendingMedIdentifiers() async -> [String] {
        if TestHostIsolation.blocks(.notifications) { return [] }
        return await UNUserNotificationCenter.current().pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(MedReminderPlanner.identifierPrefix) }
    }

    func remove(identifiers: [String]) {
        if TestHostIsolation.blocks(.notifications) { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(_ spec: ReminderSpec) async {
        if TestHostIsolation.blocks(.notifications) { return }
        let content = UNMutableNotificationContent()
        content.title = spec.title
        content.body = spec.body
        content.sound = .default
        var components = DateComponents()
        components.hour = spec.hour
        components.minute = spec.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: spec.identifier, content: content, trigger: trigger)
        )
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        if TestHostIsolation.blocks(.notifications) { return .denied }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        if TestHostIsolation.blocks(.notifications) { return false }
        return (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}

@MainActor
final class MedReminderScheduler {
    static let shared = MedReminderScheduler(center: SystemMedNotificationCenter())

    private let center: MedNotificationScheduling
    /// 上限守卫触发标记（UI toast 用，resync 后读）。
    private(set) var lastResyncTruncated = false
    /// 权限被拒标记（面板小灰字降级用）。
    private(set) var authorizationDenied = false

    init(center: MedNotificationScheduling) {
        self.center = center
    }

    /// 全量重注册（幂等）：med- 前缀全清 → 当前楼层计划批量加。
    /// 有计划且权限未定时先请求（macOS 首次开提醒走这里；iOS 启动已请求过）。
    func resync(meds: [Medication]) async {
        let (specs, truncated) = MedReminderPlanner.plan(meds: meds)
        lastResyncTruncated = truncated

        let stale = await center.pendingMedIdentifiers()
        if !stale.isEmpty { center.remove(identifiers: stale) }
        guard !specs.isEmpty else { return }

        var status = await center.authorizationStatus()
        if status == .notDetermined {
            _ = await center.requestAuthorization()
            status = await center.authorizationStatus()
        }
        authorizationDenied = (status == .denied)
        guard status != .denied else { return }

        for spec in specs {
            await center.add(spec)
        }
        #if DEBUG
        // 文件探针：模拟器/真机从容器 defaults plist 拉取取证（stdout 探针会被重启丢重定向）
        UserDefaults.standard.set(
            "cleared \(stale.count), registered \(specs.count), status \(status.rawValue), truncated \(truncated)",
            forKey: "health.probe.lastResync"
        )
        print("[PROBE health] resync: cleared \(stale.count), registered \(specs.count), status \(status.rawValue), truncated \(truncated)")
        #endif
    }

    /// 从库里取当前楼层的药再 resync（启动/切楼层入口）。
    func resyncFromStore(container: ModelContainer, profileId: String) async {
        let context = ModelContext(container)
        await resync(meds: HealthLogStore.fetchActiveMeds(context: context, profileId: profileId))
    }
}
