import Combine
import Foundation
import Observation

/// 发给 CC 的消息送达状态（plan-hub-perf K1 第 4b 步）：hub 写 tmux 结果不明时才推 `send_status`，正常发送没有这帧。
/// uncertain = hub 还在核对；delivered = 核对过了，已送到；failed = 补救不了。
/// `retryable`：hub 判定这条还能不能重发（hub 只接受自己记为 failed 的重发；账丢了 / 过期就是 false）。
/// 缺省按 status == failed 当 true（兼容没带这字段的 hub）。
/// 连上时 hub 补发一份快照 `send_status_snapshot{statuses:[同 send_status 字段]}`：没落定的 + failed 的全部记录。
struct CCSendStatus: Equatable {
    enum State: String { case uncertain, delivered, failed }
    let chatId: String
    let messageId: String
    let sessionName: String
    let state: State
    let reason: String?
    let retryable: Bool

    init(chatId: String, messageId: String, sessionName: String, state: State, reason: String?, retryable: Bool? = nil) {
        self.chatId = chatId
        self.messageId = messageId
        self.sessionName = sessionName
        self.state = state
        self.reason = reason
        self.retryable = retryable ?? (state == .failed)
    }

    /// 缺 message_id / status、或 status 不认识 → nil（整帧忽略）
    init?(frame: [String: Any]) {
        guard let messageId = frame["message_id"] as? String, !messageId.isEmpty,
              let raw = frame["status"] as? String, let state = State(rawValue: raw) else { return nil }
        self.init(chatId: frame["chat_id"] as? String ?? "", messageId: messageId,
                  sessionName: frame["session_name"] as? String ?? "", state: state,
                  reason: (frame["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  retryable: frame["retryable"] as? Bool)
    }

    /// `send_status_snapshot` 帧：statuses 不是数组 → nil（整帧忽略）；里面坏的条目单条跳过
    static func snapshot(frame: [String: Any]) -> [CCSendStatus]? {
        guard let items = frame["statuses"] as? [[String: Any]] else { return nil }
        return items.compactMap { CCSendStatus(frame: $0) }
    }

    /// 气泡上给她看的原因：hub 的中文原因照搬；英文技术报错（tmux 原文）不上气泡，只在 DEBUG 日志里
    var displayReason: String? {
        guard let reason, reason.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
        return reason
    }
}

/// 重发要原 send 帧（message_id 不变，plan-hub-perf K1 第 4b 步）。只在内存里，不落盘。只在 main 上读写。
/// - 字节：没钉住的（recent）+ 钉住的（收到 uncertain / failed 的）一起算预算；单帧超预算干脆不缓存（那条就不能重发）
/// - 条数：只数没钉住的；发出后 120 秒内的不按条数挤（hub 要等写入结果不明才推 uncertain，别在那之前把原帧挤掉），只受字节预算约束
/// - 挤的顺序：先挤没钉住的老帧，再挤钉住的老帧；刚发的这条不挤。被挤掉的 id 交回调用方，好把那条标成不能重发
struct CCSendFrameCache {
    static let keepCount = 20
    static let keepBytes = 32 * 1024 * 1024
    static let graceAge: TimeInterval = 120
    private struct Slot {
        let id: String
        let frame: [String: Any]
        let bytes: Int
        let sentAt: Date
        var pinned: Bool
    }
    /// 按发送先后
    private var slots: [Slot] = []
    private(set) var totalBytes = 0

    /// 记下刚发的一帧，返回因此被挤掉的其它 id。同一个 id 再发（重新生成复用用户节点 id）：新帧顶掉旧帧，钉住的旧帧也换掉
    @discardableResult
    mutating func remember(_ id: String, _ frame: [String: Any], now: Date = Date()) -> [String] {
        release(id)
        let bytes = Self.estimatedBytes(frame)
        guard bytes <= Self.keepBytes else { return [] }
        slots.append(Slot(id: id, frame: frame, bytes: bytes, sentAt: now, pinned: false))
        totalBytes += bytes
        var evicted: [String] = []
        while slots.lazy.filter({ !$0.pinned }).count > Self.keepCount,
              let i = slots.firstIndex(where: { !$0.pinned && $0.id != id && now.timeIntervalSince($0.sentAt) > Self.graceAge }) {
            evicted.append(remove(at: i))
        }
        while totalBytes > Self.keepBytes,
              let i = slots.firstIndex(where: { !$0.pinned && $0.id != id }) ?? slots.firstIndex(where: { $0.id != id }) {
            evicted.append(remove(at: i))
        }
        return evicted
    }

    mutating func pin(_ id: String) {
        guard let i = slots.lastIndex(where: { $0.id == id }) else { return }
        slots[i].pinned = true
    }

    mutating func release(_ id: String) {
        while let i = slots.firstIndex(where: { $0.id == id }) { remove(at: i) }
    }

    func frame(_ id: String) -> [String: Any]? {
        (slots.last(where: { $0.id == id && $0.pinned }) ?? slots.last(where: { $0.id == id }))?.frame
    }

    @discardableResult
    private mutating func remove(at i: Int) -> String {
        let slot = slots.remove(at: i)
        totalBytes -= slot.bytes
        return slot.id
    }

    private static func estimatedBytes(_ frame: [String: Any]) -> Int {
        let attachments = ((frame["images"] as? [[String: Any]]) ?? []) + ((frame["files"] as? [[String: Any]]) ?? [])
        let text = (frame["content"] as? String)?.utf8.count ?? 0
        return text + attachments.reduce(0) { $0 + (($1["b64"] as? String)?.utf8.count ?? 0) }
    }
}

/// 一条消息的送达异常：每条一个稳定对象，标记视图只读自己这条的属性——别的消息状态变了不连带它重算。
/// 写之前比值：Observation 的 setter 不比较，写同值也会让读它的视图重算。只在 main 上写。
@Observable
final class CCSendStatusEntry {
    let messageId: String
    private(set) var state: CCSendStatus.State
    /// 给她看的原因（已经是人话；hub 的英文原文不进来）
    private(set) var reason: String?
    /// hub 判定还能不能重发
    private(set) var retryable: Bool
    /// 重发要的原帧还在缓存里
    private(set) var hasFrame: Bool

    init(messageId: String, state: CCSendStatus.State, reason: String?, retryable: Bool, hasFrame: Bool) {
        self.messageId = messageId
        self.state = state
        self.reason = reason
        self.retryable = retryable
        self.hasFrame = hasFrame
    }

    /// 显示「点一下重发」按钮：只看 hub 给的 retryable + 原帧在不在
    var canRetry: Bool { state == .failed && retryable && hasFrame }

    /// 没送达时气泡下那行小字（不能重发时就只有这行，没有按钮）
    var visibleReason: String? {
        guard state == .failed else { return nil }
        if !retryable { return reason ?? "请重新发一遍" }
        if !hasFrame { return (reason.map { $0 + "。" } ?? "") + "原消息没留住，请重新发一遍" }
        return reason
    }

    /// VoiceOver：完整原因（屏幕上最多两行可能被截）；提示按能不能重发定
    var accessibilityValue: String { visibleReason ?? "" }
    var accessibilityHint: String? { canRetry ? "点两下重发这条，消息编号不变" : nil }

    /// 真有变化才写，返回写没写
    @discardableResult
    func update(state: CCSendStatus.State, reason: String?, retryable: Bool) -> Bool {
        var changed = false
        if self.state != state { self.state = state; changed = true }
        if self.reason != reason { self.reason = reason; changed = true }
        if self.retryable != retryable { self.retryable = retryable; changed = true }
        return changed
    }

    func setHasFrame(_ value: Bool) {
        if hasFrame != value { hasFrame = value }
    }
}

/// message_id → 单条状态对象。索引本身**不是** Observable：视图读它不产生订阅；
/// 只有「这条从无到有 / 从有到无」时经 `membership` 发一次 message_id，只有那条气泡自己认领、重算。
/// 没有异常的消息不建对象。只在 main 上读写。
final class CCSendStatusStore {
    /// 有界：最多这么多条，超过一小时没再更新的清掉（只在内存，不落盘）
    static let maxEntries = 200
    static let ttl: TimeInterval = 3600
    private var entries: [String: CCSendStatusEntry] = [:]
    private var touchedAt: [String: Date] = [:]
    /// 某条 entry 被建 / 被删（值 = message_id）。状态变化走 entry 自己的 Observation，不发这个
    let membership = PassthroughSubject<String, Never>()

    var count: Int { entries.count }
    var messageIds: [String] { Array(entries.keys) }

    func entry(_ messageId: String) -> CCSendStatusEntry? { entries[messageId] }

    /// 建或改；delivered 不落这里（调用方走 remove）
    func set(_ messageId: String, state: CCSendStatus.State, reason: String?, retryable: Bool, hasFrame: Bool, now: Date = Date()) {
        touchedAt[messageId] = now
        if let e = entries[messageId] {
            e.update(state: state, reason: reason, retryable: retryable)
            e.setHasFrame(hasFrame)
            return
        }
        entries[messageId] = CCSendStatusEntry(messageId: messageId, state: state, reason: reason, retryable: retryable, hasFrame: hasFrame)
        membership.send(messageId)
    }

    func remove(_ messageId: String) {
        touchedAt.removeValue(forKey: messageId)
        guard entries.removeValue(forKey: messageId) != nil else { return }
        membership.send(messageId)
    }

    /// 清过期 + 超量（先清最久没更新的），返回清掉的 id（调用方顺手放掉原帧）
    func prune(now: Date = Date()) -> [String] {
        var dropped = touchedAt.filter { now.timeIntervalSince($0.value) > Self.ttl }.map(\.key)
        let rest = touchedAt.filter { now.timeIntervalSince($0.value) <= Self.ttl }.sorted { $0.value < $1.value }
        if rest.count > Self.maxEntries { dropped += rest.prefix(rest.count - Self.maxEntries).map(\.key) }
        for id in dropped { remove(id) }
        return dropped
    }
}

/// 送达异常的全部账（状态 + 重发用原帧），CCBridgeWebSocketClient 持有一份。纯逻辑、不碰网络，单测直接驱动。只在 main 上用。
final class CCSendTracker {
    let store = CCSendStatusStore()
    private var cache = CCSendFrameCache()
    /// 原帧缓存当前估算字节（单测核预算用）
    var cachedBytes: Int { cache.totalBytes }

    /// 发出一条 send 帧。同一个 id 再发（重新生成）= 新的一次尝试：旧状态清掉，原帧换成新的
    func didSend(_ messageId: String, frame: [String: Any], now: Date = Date()) {
        store.remove(messageId)
        let evicted = cache.remember(messageId, frame, now: now)
        for id in evicted { store.entry(id)?.setHasFrame(false) }
    }

    /// 收到 hub 的 send_status
    func didReceive(_ status: CCSendStatus, now: Date = Date()) {
        switch status.state {
        case .delivered:
            store.remove(status.messageId)
            cache.release(status.messageId)
        case .failed where !status.retryable:
            cache.release(status.messageId)   // 再也重发不了，原帧不占预算
            store.set(status.messageId, state: .failed, reason: status.displayReason, retryable: false, hasFrame: false, now: now)
        case .uncertain, .failed:
            cache.pin(status.messageId)
            store.set(status.messageId, state: status.state, reason: status.displayReason,
                      retryable: status.retryable, hasFrame: cache.frame(status.messageId) != nil, now: now)
        }
        for id in store.prune(now: now) { cache.release(id) }
    }

    static let missingOnHubUncertain = "电脑那边没有这条的记录，可能已送达，看一眼再决定要不要重发"
    static let missingOnHubFailed = "电脑那边没有这条的记录了，要发请重新发一遍"

    /// 连上后 hub 补发的快照（没落定的 + failed 的全部记录）：快照里的覆盖本地；
    /// 本地还挂着、快照里却没有的 = hub 那边账没了（重启 / 过期），hub 也不会再接受这条的重发：
    /// 确认中 → 没送达 + 不可重发（可能其实送到了，让她看一眼）；可重发的没送达 → 不可重发
    func didReceiveSnapshot(_ statuses: [CCSendStatus], now: Date = Date()) {
        let listed = Set(statuses.map(\.messageId))
        for status in statuses { didReceive(status, now: now) }
        for id in store.messageIds where !listed.contains(id) {
            guard let e = store.entry(id) else { continue }
            let reason: String
            switch e.state {
            case .uncertain: reason = Self.missingOnHubUncertain
            case .failed where e.retryable: reason = Self.missingOnHubFailed
            case .failed, .delivered: continue
            }
            cache.release(id)
            store.set(id, state: .failed, reason: reason, retryable: false, hasFrame: false, now: now)
        }
    }

    /// 这条现在能不能点重发
    func canRetry(_ messageId: String) -> Bool { store.entry(messageId)?.canRetry ?? false }

    /// 点重发：返回要发的重发帧（原帧 + retry），标记先回到「确认中」；不能重发返回 nil
    func beginRetry(_ messageId: String, now: Date = Date()) -> [String: Any]? {
        guard canRetry(messageId), let frame = cache.frame(messageId) else { return nil }
        store.set(messageId, state: .uncertain, reason: nil, retryable: false, hasFrame: true, now: now)
        return CCBridgeWebSocketClient.retryFrame(from: frame)
    }

    /// 重发帧没交给 WS（没连上）：落回 failed，原帧还在、还能再点
    func retryNotSent(_ messageId: String) {
        guard store.entry(messageId)?.state == .uncertain else { return }
        store.set(messageId, state: .failed, reason: "没连上电脑，连上后再点一次", retryable: true,
                  hasFrame: cache.frame(messageId) != nil)
    }
}
