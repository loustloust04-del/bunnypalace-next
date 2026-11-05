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
    /// 这个结果属于 app 的哪一次发送（A1 R4：hub 原样带回 send 帧里的 attempt；旧 hub 不带 = nil）
    let attempt: String?
    /// 重发因「上一次还在核对 / 重发中」被拒时，正在跑的那一次的 attempt（A1 R5）：app 改跟它的终态
    let activeAttempt: String?

    init(chatId: String, messageId: String, sessionName: String, state: State, reason: String?, retryable: Bool? = nil, attempt: String? = nil, activeAttempt: String? = nil) {
        self.chatId = chatId
        self.messageId = messageId
        self.sessionName = sessionName
        self.state = state
        self.reason = reason
        self.retryable = retryable ?? (state == .failed)
        self.attempt = attempt
        self.activeAttempt = activeAttempt
    }

    /// 帧里的 attempt：非空字符串或数字（hub 原样带回 app 给的编号）
    static func attempt(in frame: [String: Any], key: String = "attempt") -> String? {
        if let s = frame[key] as? String { return s.isEmpty ? nil : s }
        if let n = frame[key] as? NSNumber { return n.stringValue }
        return nil
    }

    /// 缺 message_id / status、或 status 不认识 → nil（整帧忽略）
    init?(frame: [String: Any]) {
        guard let messageId = frame["message_id"] as? String, !messageId.isEmpty,
              let raw = frame["status"] as? String, let state = State(rawValue: raw) else { return nil }
        self.init(chatId: frame["chat_id"] as? String ?? "", messageId: messageId,
                  sessionName: frame["session_name"] as? String ?? "", state: state,
                  reason: (frame["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  retryable: frame["retryable"] as? Bool, attempt: Self.attempt(in: frame),
                  activeAttempt: Self.attempt(in: frame, key: "active_attempt"))
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

    /// 一次发送尝试（A1 R2 N3 / R4）：同一个 message_id 每次 didSend / 点重发换一个新号。
    /// wire = 写进 send / 重发帧的 `attempt`（A1 R4）：新 hub 在 ack、直接 error、send_status（含快照条目）里原样带回，
    /// 同一个 message_id 多次发送时按它精确认领；进程内唯一，前缀是每进程一个完整 UUID（A1 R5）
    struct Attempt: Equatable {
        let messageId: String
        let serial: Int
        let wire: String
    }

    /// 一次尝试的重型账（A1 R3 / R4，可裁剪）。linkId = 交给的那条连接的编号（不持有 task，A1 R5）；epoch = 交出时那条连接的目标代次
    private struct Record {
        let messageId: String
        let wire: String
        let isRetry: Bool
        var linkId: Int?
        var handedOff = false
        /// 交出去了、本地也没判定「一定没到 hub」：hub 可能有这一次的账（旧 hub 兜底判歧义用，A1 R5）
        var reached = false
        var epoch: Int?
        /// hub 对这一次回过话了（ack / error / 状态）：本地迟到的结果不再覆盖
        var answered = false
        /// 回话带着编号（新 hub）：之后不带编号的状态不覆盖它（A1 R5）
        var answeredByNumber = false
        /// 本地已经给过回执（没发出去 / 不确定）
        var settledLocally = false
    }
    private var records: [Int: Record] = [:]
    private var bySerialWire: [String: Int] = [:]
    /// message_id → 当前那一次的号（有重型账时）
    private var latest: [String: Int] = [:]
    /// 交出去、还没等到 hub 直接回话的尝试，按交出先后。新 hub 的回话带 attempt，按它精确认领，这个队列只给旧 hub
    /// （回话不带 attempt）做兼容兜底：一条连接上某个 id 的回话认领这条连接上这个 id 最早交出的那一次
    private var inFlight: [Int] = []
    /// 原帧进缓存时绑定的目标代次（A1 R4 #2）：只能重发给这个目标；没有 = 目标未知 = 不可重发
    private var msgEpoch: [String: Int] = [:]
    /// 连接现在的目标代次（transport 换目标时报过来）；nil = 还没连过（单测 / 独立使用，不做目标隔离）
    private var currentEpoch: Int?

    /// 每条消息当前那一次的轻量身份（A1 R5 P1-a），跟可裁剪的重型账分开：重型账裁掉 / 了结之后，带编号的结果照样分得清
    /// 「就是当前那一次」（落）和「已知被本地更新的一次取代」（不落）；本地根本没有这条（重启 / 别的设备发的）= 没有历史，结果照落。
    /// 只记本机创建（didSend / 点重发）或明确跟随（重发被拒后跟 active_attempt）的尝试（A1 R6）：只有它们能证明「本地有更新的一次」；
    /// 仅从 hub 观察 / 恢复到的编号不记——别的设备之后又发了新的一次，它的结果照常推进（delivered 撤回执、failed / uncertain 建回执）。
    /// reached = 这个进程里可能到过 hub 的尝试数（旧 hub 不带编号时判有没有歧义）
    private struct Ident {
        var wire: String
        var reached: Int
        var seq: Int
    }
    private var idents: [String: Ident] = [:]
    private var identSeq = 0
    /// 清理阈值，不是硬上限：超过后只清最老的、没有重型账、气泡上也没状态的；在途还没回话的身份豁免（还要用来挡旧结果）。
    /// 不做硬预算：要么给发送加准入限流（拒发也得出回执），要么淘汰还在用的身份（重新放进静默漏报 / 旧结果覆盖），两样都比多占内存糟
    private static let identBudget = 20 * CCSendStatusStore.maxEntries

    /// 连接编号（A1 R5 P2 #6）：只比身份、不持有 task；task 释放了编号照样当清理的键
    private struct LinkSlot {
        weak var object: AnyObject?
        let id: Int
    }
    private var linkSlots: [LinkSlot] = []
    private var lastLinkId = 0
    /// 最近一条没了的连接：它上面没回话的尝试还在 inFlight 里等迟到的回话；再没一条就清掉前一条留下的
    private var lastLostLinkId: Int?
    /// 回过带编号回话的连接 = 新 hub（A1 R5）：这条连接上不再按先后猜、不走宽松兜底
    private var numberedLinks: Set<Int> = []
    private var lastSerial = 0
    private let wirePrefix = UUID().uuidString
    private static let recordBudget = 2 * CCSendStatusStore.maxEntries

    static let retargetReason = "换了电脑，这条请重新发一遍"
    static let retryNotSentReason = "没连上电脑，连上后再点一次"
    static let unknownTargetReason = "不确定这条原来发给了哪台电脑，请重新发一遍"

    /// hub 明确没收下（带 message_id 的直接 error，A1 R3 #2）：不可重发（hub 没有这次的账），原因括在末尾、截 80 字
    static func hubRejectedReason(_ hubReason: String?) -> String {
        let base = "电脑没收下这条，请重新发一遍"
        guard let r = hubReason?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return base }
        return base + "（" + String(r.prefix(80)) + "）"
    }

    /// hub 对一条 send 的直接回话
    enum HubAnswer {
        /// ack：收下了
        case accepted
        /// 带 message_id 的直接 error：没收下（原因）
        case rejected(String?)
        /// 结果不明的 error（hub 写 tmux 卡住，不确定进没进去）：给这一次出「不确定」回执
        case uncertain(String)
    }

    /// 发出一条 send 帧。同一个 id 再发（重新生成）= 新的一次尝试：旧状态清掉，原帧换成新的，原帧绑定现在的目标代次；
    /// 上一次尝试迟到的本地结果从此不认
    @discardableResult
    func didSend(_ messageId: String, frame: [String: Any], now: Date = Date()) -> Attempt {
        store.remove(messageId)
        let evicted = cache.remember(messageId, frame, now: now)
        for id in evicted {
            store.entry(id)?.setHasFrame(false)
            msgEpoch.removeValue(forKey: id)
        }
        if let e = currentEpoch { msgEpoch[messageId] = e } else { msgEpoch.removeValue(forKey: messageId) }
        return startAttempt(messageId, isRetry: false)
    }

    private func startAttempt(_ messageId: String, isRetry: Bool) -> Attempt {
        lastSerial += 1
        // 上一次的账：已交出等回话的、还排着没交出去的都留着（它的回话只销它自己）；已经了结的清掉
        if let old = latest[messageId], let r = records[old], !inFlight.contains(old), r.handedOff || r.settledLocally || r.answered {
            dropRecord(old)
        }
        let wire = "\(wirePrefix).\(lastSerial)"
        records[lastSerial] = Record(messageId: messageId, wire: wire, isRetry: isRetry)
        bySerialWire[wire] = lastSerial
        latest[messageId] = lastSerial
        setIdent(messageId, wire: wire)
        trimRecords()
        return Attempt(messageId: messageId, serial: lastSerial, wire: wire)
    }

    /// 记下这条消息本机当前那一次的身份（本机创建 / 明确跟随）。超过清理阈值先清最老的、已经没有重型账、气泡上也没状态的
    private func setIdent(_ messageId: String, wire: String) {
        identSeq += 1
        idents[messageId] = Ident(wire: wire, reached: idents[messageId]?.reached ?? 0, seq: identSeq)
        guard idents.count > Self.identBudget else { return }
        let stale = idents.filter { latest[$0.key] == nil && store.entry($0.key) == nil }.sorted { $0.value.seq < $1.value.seq }
        for (id, _) in stale.prefix(idents.count - Self.identBudget * 3 / 4) { idents.removeValue(forKey: id) }
    }

    /// 这个编号是这条消息「已知被本地更新的一次取代」的旧尝试（本机没发过 / 没跟随过这条 = 没有证据，不是）
    private func isSuperseded(_ messageId: String, _ wire: String) -> Bool {
        guard let ident = idents[messageId] else { return false }
        return ident.wire != wire
    }

    /// 旧 hub（不带编号）兜底：这一次可能到过 hub，而且这个进程里这条消息只有它一次可能到过 = 归属没有歧义
    private func soleReached(_ r: Record) -> Bool {
        r.reached && idents[r.messageId]?.reached == 1
    }

    private func isCurrent(_ serial: Int, _ messageId: String) -> Bool { latest[messageId] == serial }

    private func dropRecord(_ serial: Int) {
        guard let r = records.removeValue(forKey: serial) else { return }
        bySerialWire.removeValue(forKey: r.wire)
        inFlight.removeAll { $0 == serial }
        if latest[r.messageId] == serial { latest.removeValue(forKey: r.messageId) }
    }

    /// 这条消息到了 hub 的终态（送到 / 不可重发的失败 / 没收下 / 结果不明）：它所有尝试的重型账一并清干净（A1 R4）；轻量身份留着
    private func finishMessage(_ messageId: String) {
        for (s, r) in records where r.messageId == messageId { dropRecord(s) }
        latest.removeValue(forKey: messageId)
    }

    /// 重型账的条数上限：超了先清已经回过话、不在等回话、气泡上也没状态的老账（轻量身份不动，之后的终态照样认得出）
    private func trimRecords() {
        guard records.count > Self.recordBudget else { return }
        for s in records.keys.sorted() where records.count > Self.recordBudget {
            guard let r = records[s], !inFlight.contains(s), r.answered || r.settledLocally, store.entry(r.messageId) == nil else { continue }
            dropRecord(s)
        }
    }

    /// 连接的编号；create = 没见过就发一个新的（顺手清掉已释放连接的槽）
    private func linkId(_ link: AnyObject?, create: Bool) -> Int? {
        guard let link else { return nil }
        if let slot = linkSlots.first(where: { $0.object === link }) { return slot.id }
        guard create else { return nil }
        let dead = Set(linkSlots.filter { $0.object == nil }.map(\.id))
        if !dead.isEmpty {
            linkSlots.removeAll { dead.contains($0.id) }
            numberedLinks.subtract(dead)
        }
        lastLinkId += 1
        linkSlots.append(LinkSlot(object: link, id: lastLinkId))
        return lastLinkId
    }

    private func markNumbered(_ link: AnyObject?) {
        if let id = linkId(link, create: true) { numberedLinks.insert(id) }
    }

    private func isNumbered(_ link: AnyObject?) -> Bool {
        guard let id = linkId(link, create: false) else { return false }
        return numberedLinks.contains(id)
    }

    /// 这次尝试交给了某条连接（还不算 hub 收到）。epoch = 那条连接的目标代次；跟原帧绑定的代次对不上 = 目标未知，不许重发
    func didHandOff(_ attempt: Attempt, to link: AnyObject, epoch: Int? = nil) {
        guard var r = records[attempt.serial], !r.handedOff, !r.answered, !r.settledLocally else { return }
        r.linkId = linkId(link, create: true)
        r.handedOff = true
        r.reached = true
        r.epoch = epoch
        records[attempt.serial] = r
        inFlight.append(attempt.serial)
        idents[attempt.messageId]?.reached += 1
        if isCurrent(attempt.serial, attempt.messageId), let e = epoch, msgEpoch[attempt.messageId] != e {
            msgEpoch.removeValue(forKey: attempt.messageId)
        }
    }

    /// 本地判定这一次一定没到 hub（没交出去 / 没打开过的连接）
    private func unreach(_ serial: Int) {
        guard var r = records[serial], r.reached else { return }
        r.reached = false
        records[serial] = r
        if let n = idents[r.messageId]?.reached, n > 0 { idents[r.messageId]?.reached = n - 1 }
    }

    /// 本地回执（没交出去 / WS 写入报错 / 重发没交出去）：只结算当前这一次，hub 已经回过话的不覆盖。
    /// retryable = 原帧还能再点（只有重发没交出去这一种）。mayHaveReached = false 时这一次不会再有 hub 回话，从等回话的队列里摘掉
    func didFailLocally(_ attempt: Attempt, reason: String, retryable: Bool = false, mayHaveReached: Bool = true, now: Date = Date()) {
        if !mayHaveReached { unreach(attempt.serial) }
        guard isCurrent(attempt.serial, attempt.messageId) else {
            // 旧的一次：不出回执，只把账清掉（不会再有 hub 回话的就不留在队列里）
            if !mayHaveReached { inFlight.removeAll { $0 == attempt.serial } }
            if !inFlight.contains(attempt.serial) { dropRecord(attempt.serial) }
            return
        }
        guard var r = records[attempt.serial], !r.answered, !r.settledLocally else { return }
        r.settledLocally = true
        records[attempt.serial] = r
        if !mayHaveReached { inFlight.removeAll { $0 == attempt.serial } }
        store.set(attempt.messageId, state: .failed, reason: reason, retryable: retryable,
                  hasFrame: retryable && cache.frame(attempt.messageId) != nil, now: now)
        prune(now: now)
    }

    /// 重发帧没交给 WS（没连上 / 写入报错）：落回 failed，原帧还在、还能再点（只结算这一次重发）
    func retryNotSent(_ attempt: Attempt, mayHaveReached: Bool = false) {
        didFailLocally(attempt, reason: Self.retryNotSentReason, retryable: true, mayHaveReached: mayHaveReached)
    }

    /// 旧入口（单测）：结算这个 id 当前那一次重发
    func retryNotSent(_ messageId: String) {
        guard let s = latest[messageId], let r = records[s], r.isRetry else { return }
        retryNotSent(Attempt(messageId: messageId, serial: s, wire: r.wire))
    }

    /// 这条连接没了（断线 / 被换掉）：交给它、还没等到 hub 回话的当前尝试一律给 reason 回执，不自动重发。
    /// 它们留在 inFlight 等迟到的回话（同一条连接的 ack 照样撤回执）；更早没了的连接留下的这时清掉——按连接编号认，
    /// 那条连接的 task 已经释放了也清得掉（A1 R5 P2 #6）
    func linkLost(_ link: AnyObject, reason: String, now: Date = Date()) {
        guard let lost = linkId(link, create: true) else { return }
        if let previous = lastLostLinkId, previous != lost {
            for s in inFlight where records[s]?.linkId == previous {
                guard let r = records[s] else { continue }
                if isCurrent(s, r.messageId) { inFlight.removeAll { $0 == s } } else { dropRecord(s) }
            }
        }
        lastLostLinkId = lost
        for s in inFlight {
            guard var r = records[s], r.linkId == lost, isCurrent(s, r.messageId), !r.answered, !r.settledLocally else { continue }
            r.settledLocally = true
            records[s] = r
            store.set(r.messageId, state: .failed, reason: reason, retryable: false, hasFrame: false, now: now)
        }
        prune(now: now)
    }

    /// 等回话的队列里，这条连接上这个 id 最早交出的那一次（旧 hub 兜底；link nil = 单测直接喂，不限连接）
    private func headInFlight(_ messageId: String, on link: AnyObject?) -> Int? {
        guard link != nil else { return headInFlight(messageId, linkId: nil) }
        guard let id = linkId(link, create: false) else { return nil }
        return headInFlight(messageId, linkId: id)
    }

    private func headInFlight(_ messageId: String, linkId: Int?) -> Int? {
        inFlight.first { s in
            guard let r = records[s], r.messageId == messageId else { return false }
            return linkId == nil || r.linkId == linkId
        }
    }

    /// 认领：从队列摘掉、记「hub 回过话了」
    private func markAnswered(_ serial: Int, numbered: Bool) {
        inFlight.removeAll { $0 == serial }
        records[serial]?.answered = true
        if numbered { records[serial]?.answeredByNumber = true }
    }

    /// 回话属于哪一次：带 attempt（新 hub）按编号找，找不到 / 不是这个 id 的 = 不认；不带（旧 hub）按这条连接上的交出先后——
    /// 这条连接回过带编号的话（新 hub）就不按先后猜（A1 R5）
    private func claim(_ messageId: String, wire: String?, on link: AnyObject?) -> Int? {
        if let wire {
            guard let s = bySerialWire[wire], records[s]?.messageId == messageId else { return nil }
            return s
        }
        if isNumbered(link) { return nil }
        return headInFlight(messageId, on: link)
    }

    /// hub 对一条 send 的直接回话。认领到的是旧尝试 = 只销它自己的账，永远不动当前这一次（A1 R3 #1 / R4）。
    /// 当前这一次收下：之前按断线给的回执撤掉（重发回到「确认中」等 hub 的状态）；没收下 / 结果不明：消息级回执，不可重发。
    /// 带编号、本地却没有这一次的重型账（A1 R5 P1-a）：是当前那一次（账被裁了）或本地没有这条的历史 → 没收下 / 结果不明照样出回执；
    /// 已知被更新的一次取代的不认
    func didHubAnswer(_ messageId: String, _ answer: HubAnswer, attempt wire: String? = nil, on link: AnyObject?, now: Date = Date()) {
        if wire != nil { markNumbered(link) }
        guard let s = claim(messageId, wire: wire, on: link), let r = records[s] else {
            guard let wire, !isSuperseded(messageId, wire) else { return }
            switch answer {
            case .accepted: return
            case .rejected(let reason): settleHubFailure(messageId, reason: Self.hubRejectedReason(reason), now: now)
            case .uncertain(let reason): settleHubFailure(messageId, reason: reason, now: now)
            }
            return
        }
        markAnswered(s, numbered: wire != nil)
        guard isCurrent(s, messageId) else {
            dropRecord(s)
            return
        }
        switch answer {
        case .accepted:
            guard r.settledLocally else { return }
            if r.isRetry {
                store.set(messageId, state: .uncertain, reason: nil, retryable: false, hasFrame: cache.frame(messageId) != nil, now: now)
            } else {
                store.remove(messageId)
            }
        case .rejected(let reason):
            settleHubFailure(messageId, reason: Self.hubRejectedReason(reason), now: now)
        case .uncertain(let reason):
            settleHubFailure(messageId, reason: reason, now: now)
        }
    }

    /// hub 说这一次没收下 / 结果不明：消息级回执，不可重发，这条消息的重型账了结
    private func settleHubFailure(_ messageId: String, reason: String, now: Date) {
        cache.release(messageId)
        msgEpoch.removeValue(forKey: messageId)
        store.set(messageId, state: .failed, reason: reason, retryable: false, hasFrame: false, now: now)
        finishMessage(messageId)
        prune(now: now)
    }

    /// 旧入口（单测 / R3 签名）
    func didHubAnswer(_ messageId: String, accepted: Bool, reason: String? = nil, on link: AnyObject?, now: Date = Date()) {
        didHubAnswer(messageId, accepted ? .accepted : .rejected(reason), attempt: nil, on: link, now: now)
    }

    /// transport 换了目标（候选集合 / 口令变了，A1 R3 #3）：不是绑在新目标上的可重发条目一律改成不可重发——原帧不许发给别的电脑；
    /// 目标未知的（绑定时还没连过 / 交出时目标对不上）同样不可重发
    func targetChanged(_ epoch: Int, now: Date = Date()) {
        currentEpoch = epoch
        for id in store.messageIds {
            guard let e = store.entry(id), e.state == .failed, e.retryable, msgEpoch[id] != epoch else { continue }
            let reason = msgEpoch[id] == nil ? Self.unknownTargetReason : Self.retargetReason
            cache.release(id)
            msgEpoch.removeValue(forKey: id)
            store.set(id, state: .failed, reason: reason, retryable: false, hasFrame: false, now: now)
        }
    }

    /// 这条的原帧能不能重发：没做目标隔离（还没连过）时照旧；否则原帧绑定的目标必须就是现在的目标（未知 = 不能）
    private func retryAllowed(_ messageId: String) -> Bool {
        guard let current = currentEpoch else { return true }
        return msgEpoch[messageId] == current
    }

    #if DEBUG
    /// 单测：当前那一次还在等 hub 回话（排着 / 已交出 / 本地给过回执，hub 都还没回）
    func isAwaitingHub(_ messageId: String) -> Bool {
        guard let s = latest[messageId], let r = records[s] else { return false }
        return !r.answered
    }

    /// 单测：这个 id 还挂着的账（尝试记录 / 等回话的 / 当前号）
    func bookkeepingCount(_ messageId: String) -> Int {
        records.values.filter { $0.messageId == messageId }.count
            + inFlight.filter { records[$0]?.messageId == messageId }.count
            + (latest[messageId] == nil ? 0 : 1)
    }

    /// 单测：等回话队列的总长 / 重型账总条数（查旧账有没有清掉）
    var inFlightCount: Int { inFlight.count }
    var recordCount: Int { records.count }
    #endif

    private func prune(now: Date) {
        for id in store.prune(now: now) {
            cache.release(id)
            msgEpoch.removeValue(forKey: id)
            if let s = latest[id], !inFlight.contains(s) { dropRecord(s) }
        }
    }

    /// 重发被拒、hub 说正在跑的是 active 那一次（A1 R5 P1-b）：之后跟它的终态。被拒的这次 hub 已经回过话、不会再有结果，账清掉
    private func follow(_ messageId: String, active wire: String) {
        if let s = latest[messageId] { dropRecord(s) }
        setIdent(messageId, wire: wire)
        if let s = bySerialWire[wire], records[s]?.messageId == messageId { latest[messageId] = s }
    }

    /// 收到 hub 的 send_status（link = 来源连接；nil = 单测直接喂）。
    /// 带 attempt（新 hub）：已知被本地更新的一次取代的 = 旧尝试的补账，永远不动当前这一次的回执、缓存、等回话的账（A1 R4）；
    /// 其余（就是当前那一次——重型账在不在都算——或本机没发过这条：重启后 / 别的设备发的，同一条的后续编号照常推进）以 hub 为准（A1 R5 P1-a / R6）。
    /// 重发被拒、带 active_attempt：改跟正在跑的那一次（A1 R5 P1-b）。
    /// 不带（旧 hub）兜底：这条连接回过带编号的话（新 hub）就不认（A1 R5）；当前这一次已交出还在等直接回话 / 还排着没交出去时，
    /// 归属不明的状态不动它（例外：当前是重发、就在这条连接上排在最前，它被拒时旧 hub 只回 send_status，这就是它的回话）；
    /// 本地已经给过回执的：这个进程里只有它一次可能到过 hub（没有歧义）就以 hub 为准，真送到能撤回执（A1 R5 P1-c），否则不动
    func didReceive(_ status: CCSendStatus, on link: AnyObject? = nil, now: Date = Date()) {
        let id = status.messageId
        if let wire = status.attempt {
            markNumbered(link)
            guard !isSuperseded(id, wire) else { return }
            if let s = latest[id], records[s]?.wire == wire { markAnswered(s, numbered: true) }
            if let active = status.activeAttempt, active != wire { follow(id, active: active) }
            apply(status, now: now)
            return
        }
        if isNumbered(link), idents[id] != nil { return }
        if let s = latest[id], let r = records[s] {
            if r.answeredByNumber { return }
            if !r.answered {
                if r.handedOff, !r.settledLocally, inFlight.contains(s) {
                    let head = link == nil ? headInFlight(id, linkId: r.linkId) : headInFlight(id, on: link)
                    guard r.isRetry, head == s else { return }
                    markAnswered(s, numbered: false)
                } else if r.settledLocally {
                    guard soleReached(r) else { return }
                    markAnswered(s, numbered: false)
                } else if currentEpoch != nil {
                    return   // 还没交出去：hub 不可能有它的结果，这是更早那次的
                }
            }
        }
        apply(status, now: now)
    }

    private func apply(_ status: CCSendStatus, now: Date) {
        let id = status.messageId
        switch status.state {
        case .delivered:
            store.remove(id)
            cache.release(id)
            msgEpoch.removeValue(forKey: id)
            finishMessage(id)
        case .failed where !status.retryable:
            cache.release(id)   // 再也重发不了，原帧不占预算
            msgEpoch.removeValue(forKey: id)
            store.set(id, state: .failed, reason: status.displayReason, retryable: false, hasFrame: false, now: now)
            finishMessage(id)
        case .failed where !retryAllowed(id) && cache.frame(id) != nil:
            // 原帧没绑在现在的目标上（换过电脑 / 目标未知）：hub 说能重发也不许把原帧发给现在这台
            // （原帧本来就不在的——重启后恢复的——走下面：照 hub 落状态，没有原帧本来就点不了重发）
            let reason = msgEpoch[id] == nil ? Self.unknownTargetReason : Self.retargetReason
            cache.release(id)
            msgEpoch.removeValue(forKey: id)
            store.set(id, state: .failed, reason: reason, retryable: false, hasFrame: false, now: now)
        case .uncertain, .failed:
            cache.pin(id)
            store.set(id, state: status.state, reason: status.displayReason,
                      retryable: status.retryable, hasFrame: cache.frame(id) != nil, now: now)
        }
        prune(now: now)
    }

    static let missingOnHubUncertain = "电脑那边没有这条的记录，可能已送达，看一眼再决定要不要重发"
    static let missingOnHubFailed = "电脑那边没有这条的记录了，要发请重新发一遍"

    /// 连上后 hub 补发的快照（没落定的 + failed 的全部记录）。快照不是对哪一次发送的直接回话，不消费等回话的账（A1 R4 #4）：
    /// 带 attempt 的条目：已知被本地更新的一次取代的不落；就是当前那一次的、本机没发过这条的（重启后 / 别的设备发的）照落（A1 R5 P1-a / R6）。
    /// 不带的（旧 hub）：这条连接是新 hub 的不认；只对已经回过话 / 没有在途尝试的落，本地已给过回执的按有没有歧义（A1 R5 P1-c）。
    /// 本地还挂着、快照里却没有的 = hub 那边账没了（重启 / 过期），hub 也不会再接受这条的重发：
    /// 确认中 → 没送达 + 不可重发（可能其实送到了，让她看一眼）；可重发的没送达 → 不可重发。还没了结的当前尝试不拿快照结算
    func didReceiveSnapshot(_ statuses: [CCSendStatus], on link: AnyObject? = nil, now: Date = Date()) {
        if statuses.contains(where: { $0.attempt != nil }) { markNumbered(link) }
        let numbered = isNumbered(link)
        let listed = Set(statuses.map(\.messageId))
        for status in statuses {
            let id = status.messageId
            if let wire = status.attempt {
                if isSuperseded(id, wire) { continue }
            } else {
                if numbered, idents[id] != nil { continue }
                if let s = latest[id], let r = records[s] {
                    if r.answeredByNumber { continue }
                    if !r.answered {
                        if r.settledLocally {
                            guard soleReached(r) else { continue }
                        } else if r.handedOff || currentEpoch != nil {
                            continue
                        }
                    }
                }
            }
            apply(status, now: now)
        }
        for id in store.messageIds where !listed.contains(id) {
            if let s = latest[id], let r = records[s], r.handedOff, !r.answered, !r.settledLocally, inFlight.contains(s) { continue }
            guard let e = store.entry(id) else { continue }
            let reason: String
            switch e.state {
            case .uncertain: reason = Self.missingOnHubUncertain
            case .failed where e.retryable: reason = Self.missingOnHubFailed
            case .failed, .delivered: continue
            }
            cache.release(id)
            msgEpoch.removeValue(forKey: id)
            store.set(id, state: .failed, reason: reason, retryable: false, hasFrame: false, now: now)
        }
    }

    /// 这条现在能不能点重发
    func canRetry(_ messageId: String) -> Bool { store.entry(messageId)?.canRetry ?? false }

    /// 点重发（A1 R3 #3 / R4）：登记为一次新尝试（带原帧绑定的目标代次），标记先回到「确认中」；返回重发帧（原帧 + retry + 这一次的 attempt）。
    /// 不能重发 / 做了目标隔离但原帧目标未知 → nil
    func beginRetryAttempt(_ messageId: String, now: Date = Date()) -> (frame: [String: Any], attempt: Attempt, epoch: Int?)? {
        guard canRetry(messageId), let frame = cache.frame(messageId), retryAllowed(messageId) else { return nil }
        let epoch = msgEpoch[messageId]
        let attempt = startAttempt(messageId, isRetry: true)
        store.set(messageId, state: .uncertain, reason: nil, retryable: false, hasFrame: true, now: now)
        var retry = CCBridgeWebSocketClient.retryFrame(from: frame)
        retry["attempt"] = attempt.wire
        return (retry, attempt, epoch)
    }

    /// 旧入口（单测）：只要重发帧
    func beginRetry(_ messageId: String, now: Date = Date()) -> [String: Any]? {
        beginRetryAttempt(messageId, now: now)?.frame
    }

    /// 重发在发出前就被挡下（目标换了 / 目标未知）：这一次结算成不可重发
    func retryBlocked(_ attempt: Attempt, reason: String) {
        guard isCurrent(attempt.serial, attempt.messageId) else { return }
        cache.release(attempt.messageId)
        msgEpoch.removeValue(forKey: attempt.messageId)
        didFailLocally(attempt, reason: reason, retryable: false, mayHaveReached: false)
    }
}
