#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity 的生命周期 + push token 注册链（app 侧）。
///
/// 「常驻」不存在（友邻【坑 29/30/31】）：系统随时会 end/dismiss 一个 activity，
/// 所以这里不缓存「我有一个岛」的信念——挂岛方法幂等（进来先查 `Activity.activities`），
/// 在场时听 `activityStateUpdates`，回前台再拿 `Activity.activities` 核对一遍。
@MainActor
final class CCLiveActivityManager {
    static let shared = CCLiveActivityManager()

    private var registrations: [CCLiveActivityRegistration] = CCLiveActivityRegistrationStore.load()
    private var observing = false
    /// activity.id → [pushTokenUpdates task, activityStateUpdates task]
    private var tracked: [String: [Task<Void, Never>]] = [:]
    private lazy var installId = CCLiveActivityRegistrationStore.installId()
    private lazy var lastPreview = currentPreview

    private init() {}

    // MARK: - 环境

    /// 按签名读 profile 的 `aps-environment`（跟 alert 推送同一个来源）。
    private var env: String { APNsEnvironment.current }

    /// LA 路径缺省 `hidden`（往安全倒），跟 alert 路径缺省 `full` **故意不对称**（合同 S3）。
    private var currentPreview: String {
        UserDefaults.standard.string(forKey: CCBridgeWebSocketClient.pushPreviewKey) == "full" ? "full" : "hidden"
    }

    // MARK: - 挂岛

    /// 幂等：已经有活着的 activity 就 `update`，没有才 `request`（防两个岛）。
    func start(state: CCActivityState, sessionName: String = "mp-cc") async {
        observe()
        let content = ActivityContent(state: state, staleDate: nil)
        if let existing = Activity<CCActivityAttributes>.activities.first {
            await existing.update(content)
            return
        }
        do {
            let activity = try Activity<CCActivityAttributes>.request(
                attributes: CCActivityAttributes(sessionName: sessionName),
                content: content,
                pushType: .token
            )
            track(activity)
        } catch {
            print("[CCLiveActivityManager] request failed: \(error)")
        }
    }

    /// 以 `Activity.activities` 为事实核对本地注册表：启动时 + 回前台时调。
    ///
    /// M4b2 ③：本地还挂着的岛**不**无条件 end —— 数据源在 Mac 的 hub，iPhone 上
    /// app 被杀是正常工作模式，冷启动看到的岛很可能那一轮还在跑。所以问 hub 一句
    /// （`la_query`），三分支见 `reconcileLiveActivities`。没连上 / 3s 没回 → 什么都不做。
    func recheck() {
        observe()
        let live = Activity<CCActivityAttributes>.activities
        for activity in live { track(activity) }
        let liveIds = Set(live.map(\.id))
        for reg in registrations where reg.kind == .update {
            guard let id = reg.activityId, !liveIds.contains(id) else { continue }
            dropUpdate(activityId: id)
        }
        // T13：陌生岛（远程 push-to-start 拉起的，token 还没报上去）这一轮不问 hub ——
        // 问了必得 null → 被判死 → endStale 会 cancel 掉正在等 token 的监听，token 永远上不了岸。
        let registeredIds = Set(registrations.compactMap { $0.kind == .update ? $0.activityId : nil })
        let strangers = liveIds.subtracting(registeredIds)
        if !strangers.isEmpty {
            print("[CCLiveActivityManager] recheck: 陌生岛 \(strangers.count) 个只挂监听不对账（等 token 注册）: \(strangers.sorted().joined(separator: ","))")
        }
        queryHub(activityIds: liveActivityIdsToQuery(liveIds: live.map(\.id), registeredIds: registeredIds))
    }

    // MARK: - 冷启动对账（M4b2 ③）

    /// 这一轮问出去、还在等回话的 activity id。空 = 没有在飞的 query（回帧直接丢）。
    private var pendingQuery: Set<String> = []
    private var queryTimeout: Task<Void, Never>?

    private func queryHub(activityIds: [String]) {
        guard !activityIds.isEmpty else { return }
        guard CCBridgeWebSocketClient.shared.isConnected else {
            print("[CCLiveActivityManager] recheck: WS 未连，保留 \(activityIds.count) 个岛（不猜）")
            return
        }
        pendingQuery = Set(activityIds)
        queryTimeout?.cancel()
        queryTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.queryTimedOut()
        }
        CCBridgeWebSocketClient.shared.sendLiveActivityQuery(activityIds: activityIds)
    }

    private func queryTimedOut() {
        guard !pendingQuery.isEmpty else { return }
        print("[CCLiveActivityManager] recheck: la_query 3s 无回，保留 \(pendingQuery.count) 个岛（不猜）")
        pendingQuery = []
        queryTimeout = nil
    }

    /// hub 回话了。只处理这一轮问过的 id（防串帧），未被回到的 id 一律不动。
    func handleQueryResult(alive: [String: CCLiveActivityAlive], answered: Set<String>) {
        guard !pendingQuery.isEmpty else { return }
        queryTimeout?.cancel()
        queryTimeout = nil
        let asked = pendingQuery
        pendingQuery = []
        let liveIds = Activity<CCActivityAttributes>.activities.map(\.id).filter { asked.contains($0) }
        for action in reconcileLiveActivities(liveIds: liveIds, alive: alive, answered: answered) {
            switch action {
            case .reattach(let id):
                print("[CCLiveActivityManager] recheck: reattach \(id) phase=\(alive[id]?.phase ?? "-") session=\(alive[id]?.sessionName ?? "-")")
            case .end(let id):
                print("[CCLiveActivityManager] recheck: end \(id)（hub 不认识这一轮）")
                endStale(activityId: id)
            }
        }
    }

    /// hub 说这一轮已经没了 → 立刻收走岛 + 删本地记录（`dropUpdate` 顺带通知 hub）。
    /// 「用户划掉后回 app 自动重挂」是另一条产品规则，本 lane 不做。
    private func endStale(activityId: String) {
        guard let activity = Activity<CCActivityAttributes>.activities.first(where: { $0.id == activityId }) else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        dropUpdate(activityId: activityId)
    }

    // MARK: - 监听

    /// 全局监听，只装一次。`activityUpdates` 只吐**新出现**的，所以已存在的要自己补挂。
    private func observe() {
        guard !observing else { return }
        observing = true

        for activity in Activity<CCActivityAttributes>.activities { track(activity) }

        // ActivityKit 的 async sequence 一律 detached 迭代：在主 actor 上 `for await` 会和
        // pushTokenClientQueue 锁反转，冷启动 16s 看门狗 0x8BADF00D（09-17 崩溃报告 8/9 同栈）。
        Task.detached { [weak self] in
            for await activity in Activity<CCActivityAttributes>.activityUpdates {
                await self?.track(activity)
            }
        }
        Task.detached { [weak self] in
            for await tokenData in Activity<CCActivityAttributes>.pushToStartTokenUpdates {
                await self?.registerStart(token: Self.hex(tokenData))
            }
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.syncPreview() }
        }
    }

    /// 给一个 activity 挂 token 流 + 状态流（幂等）。
    private func track(_ activity: Activity<CCActivityAttributes>) {
        guard tracked[activity.id] == nil else { return }
        let tokens = Task.detached { [weak self] in
            for await data in activity.pushTokenUpdates {
                await self?.registerUpdate(token: Self.hex(data), activity: activity)
            }
        }
        let states = Task.detached { [weak self] in
            for await state in activity.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                await self?.dropUpdate(activityId: activity.id)
            }
        }
        tracked[activity.id] = [tokens, states]
        print("[CCLiveActivityManager] attach \(activity.id) session=\(activity.attributes.sessionName)")
    }

    // MARK: - 注册

    private func registerUpdate(token: String, activity: Activity<CCActivityAttributes>) {
        let reg = CCLiveActivityRegistration(
            kind: .update,
            token: token,
            previousToken: previousToken(forIdentity: "update:\(activity.id)", newToken: token),
            activityId: activity.id,
            // 远程 start 起的岛 app 不知道别的 session —— 只能问 attributes，不能拿本地全局量（合同 S12）
            sessionName: activity.attributes.sessionName,
            installId: installId,
            env: env,
            preview: currentPreview,
            topic: Bundle.main.bundleIdentifier
        )
        store(reg)
        print("[CCLiveActivityManager] la token update → activity=\(activity.id) token=…\(token.suffix(8))")
        CCBridgeWebSocketClient.shared.sendLiveActivityRegistration(reg)
    }

    private func registerStart(token: String) {
        let reg = CCLiveActivityRegistration(
            kind: .start,
            token: token,
            previousToken: previousToken(forIdentity: "start:\(installId)", newToken: token),
            activityId: nil,
            sessionName: nil,
            installId: installId,
            env: env,
            preview: currentPreview,
            topic: Bundle.main.bundleIdentifier
        )
        store(reg)
        CCBridgeWebSocketClient.shared.sendLiveActivityRegistration(reg)
    }

    /// `previous_token` 只用于 hub 的 log 与事后对账（合同 S6）。
    private func previousToken(forIdentity identity: String, newToken: String) -> String? {
        let old = registrations.first { $0.identity == identity }?.token
        return old == newToken ? nil : old
    }

    private func store(_ reg: CCLiveActivityRegistration) {
        registrations = CCLiveActivityRegistrationStore.upsert(reg, into: registrations)
        CCLiveActivityRegistrationStore.save(registrations)
    }

    private func dropUpdate(activityId: String) {
        tracked[activityId]?.forEach { $0.cancel() }
        tracked[activityId] = nil
        guard registrations.contains(where: { $0.identity == "update:\(activityId)" }) else { return }
        registrations.removeAll { $0.identity == "update:\(activityId)" }
        CCLiveActivityRegistrationStore.save(registrations)
        CCBridgeWebSocketClient.shared.sendLiveActivityUnregister(kind: .update, activityId: activityId, installId: nil)
    }

    // MARK: - 补报 / 偏好 / nak

    /// `didOpen` 全量补报：WS 断开期间攒下的注册靠这个上岸。
    func reportAll() {
        for reg in registrations { CCBridgeWebSocketClient.shared.sendLiveActivityRegistration(reg) }
    }

    private func syncPreview() {
        let mode = currentPreview
        guard mode != lastPreview else { return }
        previewChanged(mode)
    }

    /// 推送文案偏好变了：所有 LA 记录带新 `preview` 重报。
    func previewChanged(_ mode: String) {
        let p = mode == "full" ? "full" : "hidden"
        lastPreview = p
        registrations = registrations.map { var r = $0; r.preview = p; return r }
        CCLiveActivityRegistrationStore.save(registrations)
        reportAll()
    }

    /// hub 拒了这条注册：删掉本地记录，`didOpen` 不再补报它（否则静默死循环，合同 S5）。
    func handleNak(kind: String, activityId: String?, installId: String?, reason: String) {
        let identity = kind == "start" ? "start:\(installId ?? "")" : "update:\(activityId ?? "")"
        print("[CCLiveActivityManager] la_token_nak \(identity) reason=\(reason)")
        guard registrations.contains(where: { $0.identity == identity }) else { return }
        registrations.removeAll { $0.identity == identity }
        CCLiveActivityRegistrationStore.save(registrations)
        if identity.hasPrefix("update:") { tracked[activityId ?? ""]?.forEach { $0.cancel() }; tracked[activityId ?? ""] = nil }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
