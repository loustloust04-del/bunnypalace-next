import Foundation
import MemoryCore
import SwiftData
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// 自唤醒引擎（plan-wake-heartbeat §3）：看哪些任务到点、过护栏、一次跑一件、交付、排下次。
/// 后台保活不归这里：保活叫醒 app 后调 `runDue(now:deadline:)`；拿 `nextWakeDate`（变了发 `.wakeScheduleDidChange`）排下次。
/// 保活接上前：app 进前台自己补跑一次
@MainActor
@Observable
final class WakeEngine {
    static let shared = WakeEngine()

    @ObservationIgnored private(set) weak var profileManager: ProfileManager?
    @ObservationIgnored private weak var providerManager: ProviderManager?
    @ObservationIgnored private weak var presetManager: PresetManager?
    @ObservationIgnored var defaults: UserDefaults = .standard

    static let settingsKey = "wake.settings"
    static let scheduleDidChange = Notification.Name("wakeScheduleDidChange")

    var settings: WakeSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
            refreshNextWake()
        }
    }

    /// 正在跑的那件（「AI 在跑」胶囊、heartbeat 里的「跑着」）
    private(set) var running: (profileId: String, taskId: String, title: String)?
    /// 任务 / 执行有变化 +1（heartbeat 页据此重读）
    private(set) var revision = 0
    /// 全部人里最早的下一次（保活拿它排）
    private(set) var nextWakeDate: Date?
    /// 聊天页挂上：往正开着的对话里插了消息就重载一下
    @ObservationIgnored var onDelivered: ((String) -> Void)?

    @ObservationIgnored private var current: Task<Void, Never>?
    @ObservationIgnored private var currentCaller: WakeModelCaller?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        settings = (UserDefaults.standard.data(forKey: Self.settingsKey)).flatMap { try? JSONDecoder().decode(WakeSettings.self, from: $0) }
            ?? WakeSettings()
    }

    func attach(profileManager: ProfileManager, providerManager: ProviderManager, presetManager: PresetManager) {
        self.profileManager = profileManager
        self.providerManager = providerManager
        self.presetManager = presetManager
        refreshNextWake()
        guard observers.isEmpty else { return }
        #if os(iOS)
        // 保活接上前的兜底：一回到前台就把错过的补跑（plan §3.4）
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in _ = await WakeEngine.shared.runDue(now: Date(), deadline: Date().addingTimeInterval(600)) }
        })
        #endif
    }

    // MARK: 每个人

    /// 别的窗口〔状态〕里要的这一层最近几次执行（plan-floor-main-thread §2.3）。每轮聊天都读，存一份；跑完一次作废重读
    @ObservationIgnored private var recentRunsCache: [String: [WakeRun]] = [:]

    func recentRuns(profileId: String) -> [WakeRun] {
        if let cached = recentRunsCache[profileId] { return cached }
        let runs = store(profileId: profileId).runs(limit: 6)
        recentRunsCache[profileId] = runs
        return runs
    }

    func store(profileId: String) -> WakeStore {
        WakeStore(memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
    }

    /// 人设「时区」，没设就用这台设备的
    func timeZone(profileId: String) -> TimeZone {
        profile(profileId)?.characterTimeZone.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    func personEnabled(_ profileId: String) -> Bool {
        guard !FolderFloor.isFolder(profileId) else { return false }   // 连着电脑文件夹的楼层不自己醒来（plan-folder-floor）
        return defaults.object(forKey: "wake.person.\(profileId)") as? Bool ?? true
    }

    func setPersonEnabled(_ profileId: String, _ on: Bool) {
        defaults.set(on, forKey: "wake.person.\(profileId)")
        revision += 1
        refreshNextWake()
    }

    private func profile(_ id: String) -> Profile? {
        profileManager?.profiles.first { $0.id == id } ?? ProfileManager.loadProfiles().first { $0.id == id }
    }

    private var profiles: [Profile] { profileManager?.profiles ?? ProfileManager.loadProfiles() }

    // MARK: 任务增删改

    /// 按时间表算下次（停了 / 做完了 = nil）
    func scheduled(_ task: WakeTask, profileId: String, after: Date = Date()) -> WakeTask {
        var task = task
        task.nextRunAt = task.enabled && !task.done
            ? WakeClock.next(task.schedule, after: after, timeZone: timeZone(profileId: profileId), settings: settings) : nil
        return task
    }

    func save(_ task: WakeTask, profileId: String) {
        try? store(profileId: profileId).upsert(task)
        revision += 1
        refreshNextWake()
    }

    func delete(_ taskId: String, profileId: String) {
        try? store(profileId: profileId).deleteTask(taskId)
        revision += 1
        refreshNextWake()
    }

    func refreshNextWake() {
        guard settings.enabled else {
            nextWakeDate = nil
            NotificationCenter.default.post(name: Self.scheduleDidChange, object: nil)
            return
        }
        let next = profiles.filter { personEnabled($0.id) }
            .flatMap { store(profileId: $0.id).tasks() }
            .compactMap { $0.isActive ? $0.nextRunAt : nil }
            .min()
        if next != nextWakeDate {
            nextWakeDate = next
            NotificationCenter.default.post(name: Self.scheduleDidChange, object: nil)
        }
    }

    // MARK: 跑

    struct Report {
        var ran = 0
        var remaining = 0
        var next: Date?
    }

    /// 给保活的入口：跑到 deadline 为止（一件一件来），回跑了几件、还剩几件、下次最早什么时候
    func runDue(now: Date = Date(), deadline: Date) async -> Report {
        var report = Report()
        guard running == nil, settings.enabled else {
            report.next = nextWakeDate
            return report
        }
        for profile in profiles {
            let store = store(profileId: profile.id)
            for task in store.tasks() {
                switch WakeClock.due(task, now: now) {
                case .notYet:
                    continue
                case .missed:
                    // 错过太久：记一条跳过，排下次（不补）
                    record(skipped: task, note: "错过太久，没补", profileId: profile.id, trigger: .catchUp, now: now)
                case .run(let trigger):
                    guard Date() < deadline else { report.remaining += 1; continue }
                    let decision = WakeGuard.decide(now: Date(), .init(
                        settings: settings, personEnabled: personEnabled(profile.id), runsToday: runsToday(),
                        lastUserMessageAt: lastUserMessage(profileId: profile.id), typing: false))
                    switch decision {
                    case .go:
                        await run(task, profile: profile, trigger: trigger, withBrowser: false)
                        report.ran += 1
                    case .wait(let until):
                        var t = task
                        t.nextRunAt = until
                        try? store.upsert(t)
                    case .hold(let why):
                        // 人的开关关着：留在原地（打开后还能补）；次数用完：记一条跳过，排下次
                        if why.hasPrefix("今天") { record(skipped: task, note: why, profileId: profile.id, trigger: trigger, now: now) }
                    }
                }
            }
            store.prune(now: now)
        }
        revision += 1
        refreshNextWake()
        report.next = nextWakeDate
        return report
    }

    /// 她点「现在跑一次」：不管开关 / 次数 / 让路，给浏览器（她在看着）
    func runNow(taskId: String, profileId: String) {
        guard running == nil, let task = store(profileId: profileId).task(taskId), let profile = profile(profileId) else { return }
        current = Task { await run(task, profile: profile, trigger: .manual, withBrowser: true) }
    }

    /// 「停」：打断正在跑的
    func stop() {
        currentCaller?.cancel()
        current?.cancel()
    }

    private func run(_ task: WakeTask, profile: Profile, trigger: WakeTrigger, withBrowser: Bool) async {
        guard let providerManager, let container = profileManager?.container else { return }
        running = (profile.id, task.id, task.title)
        defer {
            running = nil
            currentCaller = nil
            revision += 1
            recentRunsCache[profile.id] = nil
            // 浏览器动过：流光 / 「AI 正在操作」收掉（同聊天一轮结束）
            BrowserOperateTools.endTurn()
        }
        let store = store(profileId: profile.id)
        // 发到哪个对话就拿哪个对话当醒来的语境（权限、人设）；mainsession 常驻，万一还没建（没打开过列表）交付时再建
        let conversationId: String? = {
            switch task.notify {
            case .conversation(let id, _): return id
            case .mainSession: return profile.mainSessionId
            case .heartbeatOnly: return nil
            }
        }()
        let context = ModelContext(container)
        let conversation = conversationId.flatMap { id in
            try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first
        }
        // 任务自己选了模型就用它（停用了 / 删了照旧往下找）；没选跟对话 → 人页 → 全局
        let model = providerManager.resolveModel(conversationModelId: task.modelId ?? conversation?.selectedModelId, profileModelId: profile.preferredModel,
                                                 globalFallbackId: defaults.string(forKey: "selectedChatModel"))
        let caller = WakeModelCaller(model: model, providerManager: providerManager,
                                     usage: UsageContext(kind: .wake, conversationId: conversationId, profileId: profile.id))
        currentCaller = caller
        let built = WakeTools.build(profileId: profile.id, grants: PermissionGrants(raw: conversation?.permGrantsRaw), withBrowser: withBrowser)
        let preset = presetManager?.preset(byId: profile.presetId) ?? Preset.balanced
        let system = WakePrompt.system(profile: profile, preset: preset, conversation: conversation, context: context,
                                       tools: Set(built.tools.map(\.spec.name)))
        let opening = WakePrompt.opening(task, profile: profile, tz: timeZone(profileId: profile.id), withheld: built.withheld)
        let maxUSD = settings.maxUSD
        let (run, note) = await WakeRunner.run(.init(
            task: task, trigger: trigger, system: system, opening: opening, tools: built.tools, withheld: built.withheld,
            caller: caller, maxRounds: settings.maxRounds,
            allow: { await MainActor.run { caller.costUSD } < maxUSD },
            store: store))
        var finished = run
        finished.usd = caller.costUSD
        if finished.status == .ok { deliver(&finished, task: task, profile: profile, context: context) }
        try? store.save(finished)

        // 任务：上次结果、连败、留给下次的话、下次时间
        var t = store.task(task.id) ?? task
        t.lastRunAt = finished.startedAt
        t.lastStatus = finished.status
        t.failureStreak = finished.status == .failed ? t.failureStreak + 1 : finished.status == .ok ? 0 : t.failureStreak
        if t.failureStreak >= WakeSettings.failureStop { t.enabled = false }
        if let note { t.note = note }
        if t.schedule.isOnce, finished.status == .ok { t.done = true }
        t = scheduled(t, profileId: profile.id)
        try? store.upsert(t)
    }

    /// 结果发到对话（插一条 AI 消息，agentOrigin = wake:<runId>）+ 推一条通知（点了进那个对话）
    private func deliver(_ run: inout WakeRun, task: WakeTask, profile: Profile, context: ModelContext) {
        // 没写 message = 这次不发（「先安静」，plan-floor-main-thread §2.4）
        guard let text = run.message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let target: (id: String, push: Bool)?
        switch task.notify {
        case .conversation(let id, let push): target = (id, push)
        case .mainSession(let push):
            target = MainSession.ensure(profileId: profile.id, profileManager: profileManager, context: context).map { ($0.id, push) }
        case .heartbeatOnly: target = nil
        }
        guard let (id, push) = target,
              let nodeId = insertAssistantMessage(text, conversationId: id, origin: "wake:\(run.id)", context: context)
        else { return }
        run.deliveredConversationId = id
        run.deliveredMessageId = nodeId
        if push, !TestHostIsolation.blocks(.notifications) {
            let content = UNMutableNotificationContent()
            content.title = "\(profile.assistantName.isEmpty ? "助手" : profile.assistantName) · \(task.title)"
            content.body = String(text.prefix(180))
            content.sound = .default
            content.userInfo = ["chat_id": id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wake-\(run.id)", content: content, trigger: nil))
            run.notified = true
        }
    }

    /// 往对话末尾插一条 AI 消息（自唤醒交付、一起看陪看插话共用）；正开着这个对话就重载。回新节点 id
    @discardableResult
    func insertAssistantMessage(_ text: String, conversationId id: String, origin: String, context: ModelContext) -> String? {
        guard let conversation = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first else { return nil }
        let pid = conversation.profileId
        let parentId = conversation.currentNodeId
        let node = MessageNode(id: UUID().uuidString, role: "assistant", content: text, contentType: "text",
                               createTime: Date(), parentId: parentId.isEmpty ? nil : parentId,
                               childrenIds: [], conversationId: id, profileId: pid)
        node.agentOrigin = origin
        context.insert(node)
        if !parentId.isEmpty,
           let parent = try? context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == parentId && $0.profileId == pid })).first {
            if !parent.childrenIds.contains(node.id) { parent.childrenIds.append(node.id) }
            conversation.recordBranchChoice(parentId: parentId, childId: node.id, parentChildCount: parent.childrenIds.count)
        }
        conversation.currentNodeId = node.id
        conversation.updateTime = Date()
        conversation.unreadCount += 1
        conversation.nodeCount += 1
        try? context.save()
        onDelivered?(id)
        // 对话列表跟着刷（未读数、更新时间；mainsession 第一次建出来也要出现）
        NotificationCenter.default.post(name: .wakeDidDeliver, object: id)
        return node.id
    }

    /// 一起看陪看要的：这个对话的人、预设、模型管家、库（plan-watch-together-v2 V7）
    func environment(conversationId: String) -> (profile: Profile, preset: Preset, providers: ProviderManager, container: ModelContainer, conversation: Conversation)? {
        guard let providerManager, let container = profileManager?.container else { return nil }
        let context = ModelContext(container)
        guard let conversation = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationId })).first,
              let profile = profile(conversation.profileId) else { return nil }
        let preset = presetManager?.preset(byId: profile.presetId) ?? Preset.balanced
        return (profile, preset, providerManager, container, conversation)
    }

    private func record(skipped task: WakeTask, note: String, profileId: String, trigger: WakeTrigger, now: Date) {
        let store = store(profileId: profileId)
        try? store.save(WakeRun(taskId: task.id, taskTitle: task.title, startedAt: now, endedAt: now, trigger: trigger,
                                status: .skipped, statusNote: note))
        var t = task
        t.lastStatus = .skipped
        t = scheduled(t, profileId: profileId, after: now)
        if t.schedule.isOnce, t.nextRunAt == nil { t.done = true }
        try? store.upsert(t)
    }

    private func runsToday() -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return profiles.reduce(0) { $0 + store(profileId: $1.id).runsCount(on: Date(), calendar: cal) }
    }

    /// 她最后一次在这个人的对话里发消息（让路用）
    private func lastUserMessage(profileId: String) -> Date? {
        guard let container = profileManager?.container else { return nil }
        let pid = profileId
        var desc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.profileId == pid && $0.role == "user" },
                                                sortBy: [SortDescriptor(\.createTime, order: .reverse)])
        desc.fetchLimit = 1
        return (try? ModelContext(container).fetch(desc).first)?.createTime
    }
}
