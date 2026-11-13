import Foundation
import Observation
import UserNotifications

/// 状态面板的数据（plan-status-panel §7.5）：hub 那边的外部检修源 + 静音时段，30 秒节流拉取；
/// 最近一份存 Application Support 下的小 json（内容没变不写），连不上 Mac / 冷启动时显示旧结果。
/// 花园自检那五项也缓存在这里：面板 / 组件可见时的 tick 和相关状态变化才重算，body 只读缓存
@MainActor
@Observable
final class StatusSnapshot {
    static let shared = StatusSnapshot()

    private(set) var sources: [StatusSource] = []
    private(set) var quiet = StatusQuiet.fallback
    private(set) var notify: GardenSelfCheck.Notify = .unknown
    private(set) var garden = GardenSelfCheck(connected: false, lastError: nil, memoryOn: false, memoryFailure: nil, memoryLastOK: nil,
                                              budgetEnabled: false, spentUSD: 0, limitUSD: 0, backupEnabled: false, lastBackup: nil,
                                              notify: .unknown)
    /// 点了「立即检修」、hub 还没回 running 的那一小段也算在跑，免得连点
    private var requestedRuns: Set<String> = []

    @ObservationIgnored private var requestedAt: Date?
    @ObservationIgnored private var gardenProfileId = ""
    @ObservationIgnored private var saved: Data?

    var runnable: [StatusSource] { sources.filter(\.canRun) }
    /// 断了就不算在跑（hub 那边跑完的结果要重连后才到，别把胶囊卡在「检修中」）
    var running: Bool {
        CCBridgeWebSocketClient.shared.isConnected && sources.contains { $0.running || requestedRuns.contains($0.id) }
    }

    private static var fileURL: URL {
        AppPaths.applicationSupport.appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("status-snapshot.json")
    }

    private init() {
        UserDefaults.standard.removeObject(forKey: "statusSnapshotFrame_v1")
        if let data = try? Data(contentsOf: Self.fileURL),
           let frame = try? JSONDecoder().decode(StatusResultFrame.self, from: data) {
            saved = data
            apply(frame)
        }
    }

    func refreshIfNeeded() {
        guard CCBridgeWebSocketClient.shared.isConnected,
              requestedAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true else { return }
        requestedAt = Date()
        CCBridgeWebSocketClient.shared.send(["type": "status_get"]) { _ in }
    }

    func run(_ id: String) {
        guard !running else { return }
        requestedRuns.insert(id)
        CCBridgeWebSocketClient.shared.send(["type": "status_run", "id": id]) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async { self?.requestedRuns.remove(id) }
        }
    }

    func setQuiet(start: String, end: String) {
        CCBridgeWebSocketClient.shared.send(["type": "status_quiet_set", "start": start, "end": end,
                                             "tz": TimeZone.current.identifier]) { _ in }
    }

    func update(_ frame: StatusResultFrame) {
        apply(frame)
        requestedRuns = []
        save(frame)
    }

    private func apply(_ frame: StatusResultFrame) {
        sources = frame.sources.sorted { $0.id < $1.id }
        if let q = frame.quiet { quiet = q }
    }

    private func save(_ frame: StatusResultFrame) {
        guard let data = try? JSONEncoder().encode(frame), data != saved else { return }
        saved = data
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func refreshNotificationPermission() async {
        #if os(iOS)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notify = .on
        default: notify = .off
        }
        #else
        notify = .bannerOnly
        #endif
        refreshGarden(profileId: gardenProfileId)
    }

    /// 重读花园自检那五项（读现成的 store）；没变不写，免得白白打脏订阅它的视图
    func refreshGarden(profileId: String) {
        gardenProfileId = profileId
        let bridge = CCBridgeWebSocketClient.shared
        let kinds = MemoryHealthStatusView.lines.filter { MemoryHealthStore.isOn($0.0) }
        let statuses = kinds.map { ($0, MemoryHealthStore.status($0.0, profileId: profileId)) }
        let failure = statuses.first { $0.1.needsAttention }.map { GardenSelfCheck.MemoryFailure(text: $0.0.2, streak: $0.1.failStreak) }
        let budget = GlobalBudgetStore.shared
        let check = GardenSelfCheck(
            connected: bridge.isConnected,
            lastError: bridge.lastError,
            memoryOn: !kinds.isEmpty,
            memoryFailure: failure,
            memoryLastOK: statuses.compactMap { $0.1.lastOK }.max(),
            budgetEnabled: budget.enabled,
            spentUSD: budget.spentUSD,
            limitUSD: budget.isBudgetSet ? budget.budgetUSD : budget.defaultBudgetUSD,
            backupEnabled: BackupStore.isEnabled,
            lastBackup: UserDefaults.standard.object(forKey: BackupStore.lastSnapshotKey) as? Date,
            notify: notify
        )
        if check != garden { garden = check }
    }
}
