import Foundation
import Observation
import UserNotifications
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct TimerRun: Codable, Equatable {
    let key: String
    let conversationId: String
    let nodeId: String
    let card: TimerCard
    var endsAt: Date?
    var pausedRemaining: TimeInterval?
    var round: Int
}

enum TimerPhase: Equatable {
    case idle
    case running(endsAt: Date)
    case paused(remaining: TimeInterval)
    case finished
}

/// 到点待告诉模型的事件（持久；发送受理后 ack 才删）
struct TimerFinishedEvent: Codable, Equatable, Identifiable {
    let id: String
    let conversationId: String
    let nodeId: String
    let text: String
    /// 发送被拒（预算等）的次数与下次可试时刻（可选：旧版本存下来的事件没有这两项，§8.6-3）
    var failures: Int?
    var retryAfter: Date?
}

@MainActor
protocol TimerNotificationScheduling {
    func schedule(id: String, title: String, body: String, at: Date, conversationId: String)
    func cancel(id: String)
}

/// 计时器卡的本机状态（research-chat-cards §8.2 / §8.5）
@Observable @MainActor
final class TimerCardStore {
    static let shared = TimerCardStore(defaults: .standard, clock: Date.init,
                                       notifier: SystemTimerNotifications(), live: true)

    private struct Snapshot: Codable {
        var runs: [String: TimerRun]
        var settled: Set<String>
        var outbox: [TimerFinishedEvent]
    }

    private static let defaultsKey = "chatCardTimers.v1"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let notifier: TimerNotificationScheduling
    @ObservationIgnored private let live: Bool
    @ObservationIgnored private var workItems: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var claimed: Set<String> = []
    private(set) var runs: [String: TimerRun] = [:]
    private(set) var settled: Set<String> = []
    private(set) var outbox: [TimerFinishedEvent] = []

    init(defaults: UserDefaults, clock: @escaping () -> Date, notifier: TimerNotificationScheduling, live: Bool) {
        self.defaults = defaults
        self.clock = clock
        self.notifier = notifier
        self.live = live
        if let data = defaults.data(forKey: Self.defaultsKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            runs = snapshot.runs
            settled = snapshot.settled
            outbox = snapshot.outbox
        }
        guard live else { return }
        for run in runs.values { if let end = run.endsAt { arm(run.key, at: end) } }
        #if canImport(UIKit)
        let name = UIApplication.didBecomeActiveNotification
        #else
        let name = NSApplication.didBecomeActiveNotification
        #endif
        observerTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkExpired() }
        })
    }

    static func key(conversationId: String, nodeId: String, cardId: String) -> String {
        "\(conversationId)|\(nodeId)|\(cardId)"
    }

    func phase(_ key: String) -> TimerPhase {
        if let run = runs[key] {
            if let end = run.endsAt { return .running(endsAt: end) }
            if let remaining = run.pausedRemaining { return .paused(remaining: remaining) }
            return .idle
        }
        return settled.contains(key) ? .finished : .idle
    }

    func remaining(_ key: String) -> TimeInterval? {
        switch phase(key) {
        case .running(let end): return max(0, end.timeIntervalSince(clock()))
        case .paused(let r): return r
        case .finished: return 0
        case .idle: return nil
        }
    }

    /// 第一次看到时已过期、但过期不久（锁屏 / 切走没来得及看）→ 照常结算并告诉模型；更久的算旧对话，静默
    static let lateGrace: TimeInterval = 12 * 3600

    /// 自动开始：仅真正第一次（runs / settled 都没有这把键）；按发出时刻起算
    func registerAutoStart(key: String, conversationId: String, nodeId: String, card: TimerCard, sentAt: Date) {
        guard runs[key] == nil, !settled.contains(key) else { return }
        let end = sentAt.addingTimeInterval(TimeInterval(card.seconds))
        if end <= clock() {
            if clock().timeIntervalSince(end) <= Self.lateGrace {
                let run = TimerRun(key: key, conversationId: conversationId, nodeId: nodeId, card: card,
                                   endsAt: end, pausedRemaining: nil, round: 1)
                runs[key] = run
                finish(run)                                              // 写 outbox，不再预约已过去的通知
            } else {
                settled.insert(key)
                persist()
            }
            return
        }
        begin(TimerRun(key: key, conversationId: conversationId, nodeId: nodeId, card: card,
                       endsAt: end, pausedRemaining: nil, round: 1))
    }

    /// 开始 / 继续 / 结束后再来一轮
    func start(key: String, conversationId: String, nodeId: String, card: TimerCard) {
        if let run = runs[key] {
            if run.endsAt != nil { return }                              // 已在走
            let remaining = run.pausedRemaining ?? TimeInterval(card.seconds)
            var next = run
            next.endsAt = clock().addingTimeInterval(remaining)
            next.pausedRemaining = nil
            begin(next)
            return
        }
        let round = settled.contains(key) ? 2 : 1
        settled.remove(key)
        begin(TimerRun(key: key, conversationId: conversationId, nodeId: nodeId, card: card,
                       endsAt: clock().addingTimeInterval(TimeInterval(card.seconds)), pausedRemaining: nil, round: round))
    }

    func pause(_ key: String) {
        guard var run = runs[key], let end = run.endsAt else { return }
        run.pausedRemaining = max(0, end.timeIntervalSince(clock()))
        run.endsAt = nil
        disarm(key, cancelNotification: true)
        runs[key] = run
        persist()
    }

    /// 重置：回到空闲并记住（不会因卡片重新出现又自动开始）
    func reset(_ key: String) {
        disarm(key, cancelNotification: true)
        if var run = runs[key] {
            run.endsAt = nil
            run.pausedRemaining = nil
            runs[key] = run
        } else if settled.contains(key) {
            settled.remove(key)
        }
        persist()
    }

    /// 卡片成了旧版本：结束，不通知不发消息
    func cancel(_ key: String) {
        guard runs[key] != nil else { return }
        disarm(key, cancelNotification: true)
        runs[key] = nil
        settled.insert(key)
        persist()
    }

    func checkExpired() {
        let now = clock()
        for run in runs.values {
            if let end = run.endsAt, end <= now { finish(run) }
        }
    }

    // MARK: - outbox（多窗口认领；受理后 ack）

    func claim(conversationId: String) -> TimerFinishedEvent? {
        let now = clock()
        guard let event = outbox.first(where: {
            $0.conversationId == conversationId && !claimed.contains($0.id) && ($0.retryAfter.map { $0 <= now } ?? true)
        }) else { return nil }
        claimed.insert(event.id)
        return event
    }

    func ack(_ id: String) {
        claimed.remove(id)
        outbox.removeAll { $0.id == id }
        persist()
    }

    func release(_ id: String) {
        claimed.remove(id)
    }

    static let retryDelay: TimeInterval = 600
    static let maxDeliveryFailures = 3

    /// 发送被拒：10 分钟后再试（不随每次状态变化重试、反复弹提示）；连败 3 次放弃并删掉。返回是否已放弃（§8.6-3）
    @discardableResult
    func deliveryFailed(_ id: String) -> Bool {
        claimed.remove(id)
        guard let i = outbox.firstIndex(where: { $0.id == id }) else { return true }
        let failures = (outbox[i].failures ?? 0) + 1
        if failures >= Self.maxDeliveryFailures {
            outbox.remove(at: i)
            persist()
            return true
        }
        outbox[i].failures = failures
        outbox[i].retryAfter = clock().addingTimeInterval(Self.retryDelay)
        persist()
        return false
    }

    // MARK: - private

    private func begin(_ run: TimerRun) {
        runs[run.key] = run
        persist()
        if let end = run.endsAt {
            notifier.schedule(id: run.key, title: "计时结束", body: run.card.finishedMessage, at: end,
                              conversationId: run.conversationId)
            arm(run.key, at: end)
        }
    }

    private func finish(_ run: TimerRun) {
        disarm(run.key, cancelNotification: false)                      // 系统通知照常送达
        runs[run.key] = nil
        settled.insert(run.key)
        // 事件 id = 键 + 这一轮的到点时刻：每一轮天然唯一（重置 / 再来一次都不会撞上旧事件）
        let eventId = "\(run.key)#\(Int((run.endsAt ?? clock()).timeIntervalSince1970))"
        if !outbox.contains(where: { $0.id == eventId }) {
            outbox.append(TimerFinishedEvent(id: eventId, conversationId: run.conversationId,
                                             nodeId: run.nodeId, text: run.card.finishedMessage))
        }
        persist()
    }

    private func arm(_ key: String, at end: Date) {
        guard live else { return }
        workItems[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkExpired() }
        }
        workItems[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, end.timeIntervalSince(clock())), execute: item)
    }

    private func disarm(_ key: String, cancelNotification: Bool) {
        workItems[key]?.cancel()
        workItems[key] = nil
        if cancelNotification { notifier.cancel(id: key) }
    }

    private func persist() {
        let snapshot = Snapshot(runs: runs, settled: settled, outbox: outbox)
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// 每次预约发一个号：授权回调是异步的，回来之前已经暂停 / 重置（号作废）就不再设提醒（§8.6-2，TASK page1-卡片-04）
@MainActor
final class TimerNotificationGate {
    static let shared = TimerNotificationGate()
    private var tokens: [String: Int] = [:]
    private var next = 0

    func begin(_ id: String) -> Int {
        next += 1
        tokens[id] = next
        return next
    }

    func invalidate(_ id: String) { tokens[id] = nil }

    func isCurrent(_ id: String, _ token: Int) -> Bool { tokens[id] == token }
}

/// 系统本地通知（带提示音）：先确认授权再预约；被拒则只靠 app 内提醒 + 自动消息
@MainActor
struct SystemTimerNotifications: TimerNotificationScheduling {
    var gate: TimerNotificationGate = .shared

    func schedule(id: String, title: String, body: String, at date: Date, conversationId: String) {
        let center = UNUserNotificationCenter.current()
        let token = gate.begin(id)
        let gate = gate
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in
                guard gate.isCurrent(id, token) else { return }   // 授权期间已暂停 / 重置：不设，免得多响一次
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                content.userInfo = ["chat_id": conversationId]   // 点通知 → 打开那个对话（PushNotifications 的跳转链路）
                let interval = max(1, date.timeIntervalSinceNow)
                try? await center.add(UNNotificationRequest(identifier: "card-timer-\(id)", content: content,
                                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
            }
        }
    }

    func cancel(id: String) {
        gate.invalidate(id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["card-timer-\(id)"])
    }
}
