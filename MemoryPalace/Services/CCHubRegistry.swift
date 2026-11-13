import Combine
import CryptoKit
import Foundation
import Observation
import Security
import SwiftData

/// 一台 hub 的配对地址（plan-multi-hub B2.1）：主 / 备 / 中继 + 中继 pin。口令不在这里（钥匙串），这里只记它的指纹。
/// 主 hub 存在 .standard 的旧四键，附加 hub 存在它自己的 suite（键名一样）
struct CCHubPairing: Equatable {
    var primaryURL: String?
    var backupURL: String?
    var relayURL: String?
    var relayPin: String?

    init(primaryURL: String? = nil, backupURL: String? = nil, relayURL: String? = nil, relayPin: String? = nil) {
        self.primaryURL = primaryURL.flatMap { $0.isEmpty ? nil : $0 }
        self.backupURL = backupURL.flatMap { $0.isEmpty ? nil : $0 }
        self.relayURL = relayURL.flatMap { $0.isEmpty ? nil : $0 }
        self.relayPin = self.relayURL == nil ? nil : relayPin.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 扫码：整体替换，码里没带的字段清掉（同 CCBridgeEndpoints.save）
    init(payload p: CCPairPayload) {
        self.init(primaryURL: p.u, backupURL: p.u2, relayURL: p.relayURL?.absoluteString, relayPin: p.p3)
    }

    static func read(_ d: UserDefaults) -> CCHubPairing {
        CCHubPairing(primaryURL: d.string(forKey: CCBridgeEndpoints.overrideKey),
                     backupURL: d.string(forKey: CCBridgeEndpoints.backupKey),
                     relayURL: d.string(forKey: CCBridgeEndpoints.relayKey),
                     relayPin: d.string(forKey: CCBridgeEndpoints.relayPinKey))
    }

    /// 手填主 / 备：换了目标就把扫码存的中继和 pin 一起清掉（同 CCBridgeEndpoints.saveManual）
    func manual(primary: String, backup: String) -> CCHubPairing {
        let next = CCHubPairing(primaryURL: primary, backupURL: backup)
        guard next.primaryURL == primaryURL, next.backupURL == backupURL else { return next }
        return CCHubPairing(primaryURL: primary, backupURL: backup, relayURL: relayURL, relayPin: relayPin)
    }
}

/// 配对快照的读写（gen + 口令指纹）。写入顺序：指纹占位 → 钥匙串（检查返回值，失败还原指纹、地址不动）→ 地址 / gen → 真指纹。
/// 中途断在哪都只会是「旧完整配对」或「待配对」，拼不出「新地址 + 旧口令」
enum CCHubPairingStore {
    static let genKey = "ccBridgePairGen"
    static let fingerprintKey = "ccBridgeTokenFingerprint"
    /// 这台 hub 第一次连上报的 hub_id（hello）
    static let hubIdentityKey = "ccBridgeHubIdentity"
    /// 被这台 hub 拒过（鉴权失败）的口令指纹（impl1 #14）：同一个口令不再自动试连，换了口令才重试
    static let rejectedFingerprintKey = "ccBridgeRejectedFingerprint"
    /// 写配对途中的指纹占位：跟任何口令都对不上
    static let writingMarker = "writing"

    enum WriteStep { case markerWritten, secretWritten, snapshotWritten }

    enum Verdict: Equatable {
        /// 可以连；口令（nil = 没有 / 读不到，读不到时由 keepExistingToken 决定能不能沿用）
        case ok(String?)
        /// 快照没写完（写配对途中的占位 / 附加 hub 没有指纹）：待配对，不连不发
        case mismatch
        /// 快照是完整的，但钥匙串里现在的口令跟它记的指纹不一样（别的入口改了口令 / 钥匙串写失败）：待配对，不试连（impl1 #1）
        case changed(String?)
    }

    /// sha256(口令) hex 前 16 位；没有口令 = ""
    static func fingerprint(_ token: String?) -> String {
        guard let token, !token.isEmpty else { return "" }
        return String(SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    static func gen(_ d: UserDefaults) -> Int { d.integer(forKey: genKey) }

    static func storedFingerprint(_ d: UserDefaults) -> String? { d.string(forKey: fingerprintKey) }

    /// 写配对。记下的 hub_id 不动（impl1 #6：更新 = 同一台，下次握手 hello 核对；对不上由身份闸停住）；被拒记录清掉（换了口令重新试）。
    /// interrupt：单测注入「崩在这一步之后」，返回 true 就到此为止（返回 false，后面的步骤不做）
    @discardableResult
    static func write(_ p: CCHubPairing, token: String, to d: UserDefaults, writeSecret: (String) -> Bool,
                      interrupt: ((WriteStep) -> Bool)? = nil) -> Bool {
        // 占位先于钥匙串：本机写到一半（含钥匙串已换、快照没换）一律是占位 = 待配对
        let previous = storedFingerprint(d)
        d.set(writingMarker, forKey: fingerprintKey)
        if interrupt?(.markerWritten) == true { return false }
        guard writeSecret(token) else {
            // 钥匙串写失败：地址不动，指纹还原（旧口令可能已被删，下次核的时候按对不上处理）
            if let previous { d.set(previous, forKey: fingerprintKey) } else { d.removeObject(forKey: fingerprintKey) }
            return false
        }
        if interrupt?(.secretWritten) == true { return false }
        func put(_ value: String?, _ key: String) {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
        put(p.primaryURL, CCBridgeEndpoints.overrideKey)
        put(p.backupURL, CCBridgeEndpoints.backupKey)
        put(p.relayURL, CCBridgeEndpoints.relayKey)
        put(p.relayPin, CCBridgeEndpoints.relayPinKey)
        d.removeObject(forKey: rejectedFingerprintKey)
        d.set(gen(d) + 1, forKey: genKey)
        if interrupt?(.snapshotWritten) == true { return false }
        d.set(fingerprint(token), forKey: fingerprintKey)
        return true
    }

    /// allowLegacy：主 hub 没有指纹（老用户、钥匙串一直读不到没补上）照旧连；附加 hub 没指纹 = 没写完，待配对
    static func verify(_ d: UserDefaults, secret: HubSecretRead, allowLegacy: Bool) -> Verdict {
        let value: String?
        switch secret {
        case .value(let t): value = t
        case .absent: value = nil
        case .unreadable:
            // 锁屏读不到（#042）：没法核，交给 keepExistingToken 只在同一代、同一组候选上沿用内存里核过的口令
            return storedFingerprint(d) == writingMarker ? .mismatch : .ok(nil)
        }
        guard let stored = storedFingerprint(d) else { return allowLegacy ? .ok(value) : .mismatch }
        if stored == writingMarker { return .mismatch }
        return stored == fingerprint(value) ? .ok(value) : .changed(value)
    }
}

enum HubSecretRead: Equatable {
    case value(String)
    case absent
    /// 有条目但这会儿读不了（锁屏 errSecInteractionNotAllowed 等）
    case unreadable
}

/// hub 口令存哪（单测注入替身，不碰真钥匙串）
protocol HubSecretStore {
    func read(account: String) -> HubSecretRead
    /// 空串 = 删掉。返回写没写成
    func write(_ token: String, account: String) -> Bool
    /// 返回删没删成（本来就没有也算成）
    func remove(account: String) -> Bool
}

struct KeychainHubSecrets: HubSecretStore {
    func read(account: String) -> HubSecretRead {
        // 只读钥匙串，不带任何副作用（旧条目也不再经 HubTokenStore 顺带 plist bootstrap：那一步改由 Registry 核过配对目标再做，recheck1 #1）
        if TestHostIsolation.blocks(.hub), account == HubTokenStore.keychainAccount { return .absent }   // #035：测试宿主不取主 hub 旧条目
        let value = KeychainStore.get(account: account)
        if let value, !value.isEmpty { return .value(value) }
        if TestHostIsolation.blocks(.hub) { return .absent }
        let status = KeychainStore.readStatus(account: account)
        return status == errSecItemNotFound || status == errSecSuccess ? .absent : .unreadable
    }

    func write(_ token: String, account: String) -> Bool {
        KeychainStore.set(token, account: account, sync: false)
    }

    func remove(account: String) -> Bool {
        KeychainStore.remove(account: account)
    }
}

/// 花园连着的所有 hub（plan-multi-hub B2.3）。主 hub = 旧槽位（`CCBridgeWebSocketClient.shared` / .standard），永远排第一；
/// 口令连接只认本机专用副本 `cc-bridge.hub.primary`（不同步 iCloud，impl1 #1），旧条目 `cc-bridge` 配对时照写一份给老版本回滚、首次启动拷进本机副本。
/// 附加 hub 每台一个 suite `cc.hub.<id>`（键名同旧键）+ 钥匙串 `cc-bridge.hub.<id>`，名单 `ccHubs` 在 .standard。
/// 扫码 / 手填 / 增删改都走这里，口令和地址只从同一台的快照来
@Observable @MainActor
final class CCHubRegistry {
    static let shared = CCHubRegistry()

    struct HubProfile: Identifiable, Equatable {
        let id: String
        var name: String
        var status: Status
    }

    enum Status: Equatable {
        case ready
        /// 钥匙串口令和配对快照对不上：不连不发，等重新配对
        case needsPairing
        /// 连上的 hub_id 跟记下的不一样：停住不收发，等确认
        case identityChanged
    }

    enum AddResult: Equatable {
        case added(String)
        /// 这个口令已经挂在那台上了（同一台电脑别加两次）
        case duplicateToken(String)
        /// 这个 hub_id 已经是那台了（同一台换过口令也别加两次）
        case duplicateIdentity(String)
        case secretWriteFailed
    }

    /// 改一台配对的结果（impl1 #6）
    enum UpdateResult: Equatable {
        case updated
        case secretWriteFailed
        /// 这个口令挂在别的那台上
        case duplicateToken(String)
        /// 预期的 hub_id 是别的那台
        case duplicateIdentity(String)
        /// 预期的 hub_id 跟这台记下的不一样 = 另一台电脑：不更新，只能新增
        case differentMachine
    }

    /// 对话 / 终端要的那台用不了（B4 的提示读 message）
    enum Unavailable: Error, Equatable {
        /// 对话从别的设备同步来，本机认不出它连的那台：选一台改绑
        case unbound
        /// 那台已经删了
        case removed
        /// 那台口令和配对对不上：重新扫码配对
        case needsPairing
        /// 那台连上的 hub_id 变了：确认前不收发
        case identityChanged

        var message: String {
            switch self {
            case .unbound: return "这条对话连的电脑不在这台设备上，选一台电脑再发"
            case .removed: return "这条对话连的电脑已经删掉了，选一台电脑再发"
            case .needsPairing: return "这条对话连的电脑要重新配对，配好再发"
            case .identityChanged: return "这条对话连的电脑换成了另一台，确认后再发"
            }
        }
    }

    private struct Entry: Equatable {
        let id: String
        var name: String
    }

    nonisolated static let primaryId = CCBridgeWebSocketClient.primaryHubId
    nonisolated static let listKey = "ccHubs"
    nonisolated static let primaryNameKey = "ccPrimaryHubName"
    /// 那台最后一次核准的 hello 报的机型（存在那台自己的 defaults）
    nonisolated static let lastHostModelKey = "ccHubLastHostModel"
    nonisolated static let pendingUnregisterKey = "ccHubPendingUnregister"
    nonisolated static let pendingCleanupKey = "ccHubsPendingCleanup"
    /// 删掉的那台叫什么（槽位 → 名字）：对话标题下「纽约 · 已删除」要用（B4.4）。只记名字
    nonisolated static let removedNamesKey = "ccHubRemovedNames"
    nonisolated static let defaultPrimaryName = "我的电脑"
    nonisolated static let suitePrefix = "cc.hub."

    /// 连接用的口令账户：附加 hub `cc-bridge.hub.<id>`，主 hub 本机副本 `cc-bridge.hub.primary`（都不同步、首次解锁后可读）
    nonisolated static func keychainAccount(for id: String) -> String { "cc-bridge.hub.\(id)" }
    /// 主 hub 的旧条目（跟着 API 同步开关走，可能经 iCloud 被别的设备改掉）：只写不读来连，首次启动拷一份进本机副本
    nonisolated static let legacyPrimaryAccount = HubTokenStore.keychainAccount

    /// 跨设备同步来、本机认不出那台的对话（plan-multi-hub B1）：不是任何一台的 id → route 不给 client → 拒发，等改绑
    nonisolated static let unboundHubId = "unbound"
    /// 新建 CC 对话默认连哪台（B4 选台写它）
    nonisolated static let lastHubKey = "ccLastHubId"

    /// 对话绑的是哪台 hub（nil = 老对话 = 主 hub）。读侧按 hub 过滤的地方都从这里取
    nonisolated static func hubId(of conversation: Conversation) -> String {
        conversation.ccHubId ?? primaryId
    }

    /// 那台 hub 第一次连上报的 hub_id（不经 Registry 实例，后台线程可调；同步导出 / 恢复用）
    nonisolated static func storedIdentity(ofHub id: String, standard: UserDefaults = .standard, suitePrefix: String = suitePrefix) -> String? {
        if id == primaryId { return standard.string(forKey: CCHubPairingStore.hubIdentityKey) }
        guard knownAdditionalIds(standard).contains(id) else { return nil }
        return UserDefaults(suiteName: suitePrefix + id)?.string(forKey: CCHubPairingStore.hubIdentityKey)
    }

    /// 同步导出带的 hub_id：对话自己记的；没记（建对话时那台还没连上过）就补本机那台现在记下的
    nonisolated static func exportedIdentity(of conversation: Conversation, standard: UserDefaults = .standard, suitePrefix: String = suitePrefix) -> String? {
        if let identity = conversation.ccHubIdentity { return identity }
        guard let id = conversation.ccHubId, id != unboundHubId else { return nil }
        return storedIdentity(ofHub: id, standard: standard, suitePrefix: suitePrefix)
    }

    /// 对端同步来 / 备份恢复的 (ccHubId, hub_id) → 本机的 ccHubId（B1 恢复规则；impl1 #3 同步和恢复共用）：
    /// 两个都没有（真正的旧数据）保持 nil；带 hub_id 的按 hub_id 在本机的电脑里找，找到 → 那台，找不到 → 待绑定；
    /// 不带 hub_id 的：本机名单里正是这个附加槽位（这台设备自己的备份）→ 那台；其余（含明确的 "primary"：新对话主 hub 身份不知道时
    /// 写 nil，明确的 "primary" 应当带 hub_id）→ 待绑定，绝不落到本机主 hub
    nonisolated static func resolveSynced(hubId: String?, identity: String?, standard: UserDefaults = .standard, suitePrefix: String = suitePrefix) -> String? {
        guard let identity, !identity.isEmpty else {
            guard let hubId else { return nil }
            return knownAdditionalIds(standard).contains(hubId) ? hubId : unboundHubId
        }
        if storedIdentity(ofHub: primaryId, standard: standard, suitePrefix: suitePrefix) == identity { return primaryId }
        for id in knownAdditionalIds(standard) where storedIdentity(ofHub: id, standard: standard, suitePrefix: suitePrefix) == identity {
            return id
        }
        return unboundHubId
    }

    nonisolated private static func knownAdditionalIds(_ standard: UserDefaults) -> [String] {
        (standard.array(forKey: listKey) as? [[String: String]] ?? []).compactMap { $0["id"] }
    }

    @ObservationIgnored let primary: CCBridgeWebSocketClient
    @ObservationIgnored private let standard: UserDefaults
    @ObservationIgnored private let suitePrefix: String
    @ObservationIgnored private let secrets: HubSecretStore
    /// 改绑记录写在哪（CCChatOriginLedger 的独立 suite；单测注入）
    @ObservationIgnored let originDefaults: UserDefaults
    @ObservationIgnored private let makeClient: (String, UserDefaults) -> CCBridgeWebSocketClient
    /// 这台 Mac 的 launchd 外部 hub 口令（plist 里的 MP_CC_HUB_TOKEN；iOS / 测试宿主 = nil）。单测注入
    @ObservationIgnored private let launchdToken: () -> String?
    private var entries: [Entry]
    private var statuses: [String: Status] = [:]
    private var primaryNameOverride: String?
    @ObservationIgnored private var clients: [String: CCBridgeWebSocketClient] = [:]
    @ObservationIgnored private var suites: [String: UserDefaults] = [:]
    /// 每台附加 hub 的终端窗口表（B2.8），跟 client 同生同灭；主 hub 的见 windowStore(for:)
    @ObservationIgnored private var windowStores: [String: TerminalWindowStore] = [:]
    @ObservationIgnored private var primaryWindowStore: TerminalWindowStore?
    @ObservationIgnored private var bind: ((CCBridgeWebSocketClient) -> Void)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var primaryWired = false
    /// 主 hub 这一代交互（client.interactionEpoch）是本机切换（Mac 外部 / 内嵌 hub，impl1 #2 / #4）：这一代上 hello 报的新 hub_id 直接核准
    @ObservationIgnored private var localSwitchEpoch: Int?
    /// 最新的 APNs device token：新 client 建好就补种，变了广播给所有有效 client（B2.7）
    @ObservationIgnored private(set) var deviceToken: String?
    /// 现在看着的对话（B3.3）：(chatId, 它绑的 hub)。目标那台发 chatId，其他台发 focus:null
    @ObservationIgnored private(set) var focus: (chatId: String, hubId: String)?
    /// 各台送达异常索引「某条 entry 建 / 删」的合流（值 = message_id），气泡按 sendStatus(for:) 认领（B3.1 / research R1）
    @ObservationIgnored let sendMembership = PassthroughSubject<String, Never>()
    @ObservationIgnored private var membershipLinks: [String: AnyCancellable] = [:]
    /// removedNamesKey 的内存副本（标题每次读，不反复读盘）
    @ObservationIgnored private(set) var removedNames: [String: String]

    init(primary: CCBridgeWebSocketClient = .shared, standard: UserDefaults = .standard, suitePrefix: String = CCHubRegistry.suitePrefix,
         secrets: HubSecretStore = KeychainHubSecrets(), originDefaults: UserDefaults = CCChatOriginLedger.store,
         launchdToken: @escaping () -> String? = { HubTokenStore.launchdPlistToken() },
         makeClient: @escaping (String, UserDefaults) -> CCBridgeWebSocketClient = { CCBridgeWebSocketClient(hubId: $0, defaults: $1) }) {
        self.primary = primary
        self.originDefaults = originDefaults
        self.launchdToken = launchdToken
        self.standard = standard
        self.suitePrefix = suitePrefix
        self.secrets = secrets
        self.makeClient = makeClient
        let list = standard.array(forKey: Self.listKey) as? [[String: String]] ?? []
        entries = list.compactMap { d in d["id"].map { Entry(id: $0, name: d["name"] ?? "") } }
        primaryNameOverride = standard.string(forKey: Self.primaryNameKey).flatMap { $0.isEmpty ? nil : $0 }
        removedNames = standard.dictionary(forKey: Self.removedNamesKey) as? [String: String] ?? [:]
        linkMembership(primary, id: Self.primaryId)
    }

    // MARK: - 查询

    var hubs: [HubProfile] {
        [HubProfile(id: Self.primaryId, name: primaryName, status: statuses[Self.primaryId] ?? .ready)]
            + entries.map { HubProfile(id: $0.id, name: $0.name, status: statuses[$0.id] ?? .ready) }
    }

    /// 主 hub 的名字：改过名用改的；否则 hello 报的机型 / 主机名；都没有叫「我的电脑」（D1）
    var primaryName: String {
        primaryNameOverride ?? primary.hubInfo?.hostModelName ?? primary.hubInfo?.hostName ?? Self.defaultPrimaryName
    }

    /// 那台最后一次知道的机型：断线 / 待配对 / 换了机器 / 冷启动还没握手时首页 3D 照它画，不跳外形；从没握过手 = nil
    func lastKnownDevice(for id: String) -> TerminalDeviceClass? {
        guard let saved = defaults(for: id)?.dictionary(forKey: Self.lastHostModelKey) as? [String: String] else { return nil }
        return .remote(modelId: saved["id"], modelName: saved["name"])
    }

    func status(for id: String) -> Status? {
        guard id == Self.primaryId || entries.contains(where: { $0.id == id }) else { return nil }
        return statuses[id] ?? .ready
    }

    /// 能收发的那台的连接；已删 / 待配对 / 换了机器 → nil
    func client(for id: String) -> CCBridgeWebSocketClient? {
        guard status(for: id) == .ready else { return nil }
        return id == Self.primaryId ? primary : clients[id]
    }

    /// 那台的终端窗口表（绑它自己的 client + 存储）。主 hub = TerminalWindowStore.shared（注入的主 client 另建一份）；已删 → nil
    func windowStore(for id: String) -> TerminalWindowStore? {
        guard id == Self.primaryId else {
            guard entries.contains(where: { $0.id == id }) else { return nil }
            return windowStores[id]
        }
        if let primaryWindowStore { return primaryWindowStore }
        let store = primary === CCBridgeWebSocketClient.shared ? TerminalWindowStore.shared : TerminalWindowStore(client: primary, defaults: primary.defaults)
        primary.windowStore = store
        primaryWindowStore = store
        return store
    }

    /// 发送 / 终端要用的那台（B3.1 / B3.4）。删了 / 待配对 / 换了机器、对话待绑定 → 不给，调用方拒发，不回落主 hub。
    /// 主 hub 待配对 / 换了机器也报出来（b4 #4：标题 / 输入框 / 发送拦截共用）；正常时照旧总给
    func route(_ id: String) -> Result<CCBridgeWebSocketClient, Unavailable> {
        if id == Self.primaryId {
            switch statuses[id] {
            case .needsPairing?: return .failure(.needsPairing)
            case .identityChanged?: return .failure(.identityChanged)
            case .ready?, nil: return .success(primary)
            }
        }
        guard let status = status(for: id) else { return .failure(id == Self.unboundHubId ? .unbound : .removed) }
        switch status {
        case .ready: return clients[id].map { .success($0) } ?? .failure(.removed)
        case .needsPairing: return .failure(.needsPairing)
        case .identityChanged: return .failure(.identityChanged)
        }
    }

    /// 那台现在记下的 hub_id（hello）
    func identity(of id: String) -> String? {
        defaults(for: id)?.string(forKey: CCHubPairingStore.hubIdentityKey)
    }

    /// 删掉的那台当时叫什么（没删过 / 不知道 = nil）
    func removedName(of id: String) -> String? { removedNames[id] }

    /// 启动时只留还有对话连着的删除记录（b4 #11）；referenced = 对话里出现过的 ccHubId
    func pruneRemovedNames(referenced: Set<String>) {
        let kept = removedNames.filter { referenced.contains($0.key) }
        guard kept.count != removedNames.count else { return }
        setRemovedNames(kept)
    }

    private func setRemovedNames(_ names: [String: String]) {
        removedNames = names
        if names.isEmpty { standard.removeObject(forKey: Self.removedNamesKey) } else { standard.set(names, forKey: Self.removedNamesKey) }
    }

    /// 新建 CC 对话默认连哪台：上次选的；没有 / 那台不在了 → 主 hub
    var lastHubId: String {
        get {
            guard let id = standard.string(forKey: Self.lastHubKey), status(for: id) != nil else { return Self.primaryId }
            return id
        }
        set { standard.set(newValue, forKey: Self.lastHubKey) }
    }

    /// 新建的 CC 对话写明确的归属 + 当时那台的 hub_id；主 hub 的 hub_id 还不知道就留 nil（= 老语义，impl1 #3：明确的 "primary" 一定带 hub_id）。
    /// 只认「还没归属、也还没会话名」= 新对话；已有会话名的老对话保持 nil（= 主 hub）
    func bindNewCCConversation(_ conversation: Conversation) {
        guard conversation.ccHubId == nil, conversation.ccBridgeSessionName == nil else { return }
        let id = lastHubId
        let known = identity(of: id)
        guard id != Self.primaryId || known != nil else { return }
        conversation.ccHubId = id
        conversation.ccHubIdentity = known
        if focus?.chatId == conversation.id, focus?.hubId != id {
            focus = (conversation.id, id)
            distributeFocus()
        }
    }

    /// 改绑（B3.5）：改 ccHubId / ccHubIdentity，会话名不动（新那台没有这个会话会按现有逻辑新起），正看着它就重发 focus。
    /// 改连到 hub_id 还不知道的主 hub：两个字段都写 nil（= 老语义，同 bindNewCCConversation；b4 #3）。
    /// 在途问题卡 / 发送记着原来那台，照旧回原来那台。那台不存在 → false，不改
    @discardableResult
    func rebind(_ conversation: Conversation, to id: String) -> Bool {
        guard status(for: id) != nil else { return false }
        // 记下改绑过（R5.2）：以后查不到来源的 edit 不再放行
        if Self.hubId(of: conversation) != id { CCChatOriginLedger.recordRebind(chatId: conversation.id, defaults: originDefaults) }
        let known = identity(of: id)
        conversation.ccHubId = id == Self.primaryId && known == nil ? nil : id
        conversation.ccHubIdentity = known
        if focus?.chatId == conversation.id {
            focus = (conversation.id, id)
            distributeFocus()
        }
        return true
    }

    /// 某台的 hub_id 第一次确认 / 换成新的（hello 首次记下、本机切换、加 hub / 更新配对带的 hub_id）→ 把按这个 hub_id 自动待绑定的对话绑回这台
    /// （impl1 #12）。参数 (槽位, hub_id)，返回绑回的对话 id。app 根接（ModelContext 在那）；接上之前确认的先攒着，接上时补做
    @ObservationIgnored var onIdentityConfirmed: ((_ hubId: String, _ identity: String) -> [String])? {
        didSet {
            let pending = unhandledConfirmations
            unhandledConfirmations = []
            for (id, identity) in pending { identityConfirmed(id, identity) }
        }
    }
    @ObservationIgnored private var unhandledConfirmations: [(String, String)] = []

    private func identityConfirmed(_ id: String, _ identity: String) {
        guard let hook = onIdentityConfirmed else {
            unhandledConfirmations.append((id, identity))
            return
        }
        let rebound = hook(id, identity)
        guard !rebound.isEmpty else { return }
        hubLog(id, "rebound \(rebound.count) auto-unbound chats by hub_id \(identity.prefix(8))")
        if let focus, rebound.contains(focus.chatId), focus.hubId != id {
            self.focus = (focus.chatId, id)
            distributeFocus()
        }
    }

    /// 自动待绑定（同步 / 恢复认不出那台：ccHubId == unbound 且带 hub_id）里 hub_id 是这个的 → 绑回 hubId（impl1 #12）。
    /// 用户手动选的绑定不会是 unbound，不动。ccHubId 是可选字段、#Predicate 比较不可靠：取全部对话再内存筛（只在 hub_id 确认时跑）
    static func rebindAutoUnbound(identity: String, to hubId: String, context: ModelContext) -> [String] {
        let hits = ((try? context.fetch(FetchDescriptor<Conversation>())) ?? [])
            .filter { $0.ccHubId == unboundHubId && $0.ccHubIdentity == identity }
        guard !hits.isEmpty else { return [] }
        for c in hits { c.ccHubId = hubId }
        try? context.save()
        return hits.map(\.id)
    }

    /// 对话里出现过的 ccHubId（含回收站里的）。ccHubId 是可选字段，只取这一列在内存里收
    static func referencedHubIds(context: ModelContext) -> Set<String> {
        var descriptor = FetchDescriptor<Conversation>()
        descriptor.propertiesToFetch = [\.ccHubId]
        return Set(((try? context.fetch(descriptor)) ?? []).compactMap(\.ccHubId))
    }

    // MARK: - focus（B3.3）

    /// 现在看着的对话（nil = 没在看任何对话）。对话切换 / 翻页 / 楼层切换都走这里
    func updateFocus(_ conversation: Conversation?) {
        updateFocus(chatId: conversation?.id, hubId: conversation.map(Self.hubId(of:)))
    }

    func updateFocus(chatId: String?, hubId: String?) {
        if let chatId, let hubId { focus = (chatId, hubId) } else { focus = nil }
        distributeFocus()
    }

    private func focusChat(for id: String) -> String? {
        guard let focus, focus.hubId == id else { return nil }
        return focus.chatId
    }

    private func distributeFocus() {
        primary.updateFocus(focusChat(for: Self.primaryId))
        for e in entries { clients[e.id]?.updateFocus(focusChat(for: e.id)) }
    }

    // MARK: - 送达状态（B3.1）

    /// 这条消息的送达异常记在哪台的账上（重发回那台，不按对话现在绑哪台）；主 hub 先查
    func sendStatus(for messageId: String) -> (client: CCBridgeWebSocketClient, entry: CCSendStatusEntry)? {
        for c in [primary] + entries.compactMap({ clients[$0.id] }) {
            if let entry = c.sendTracker.store.entry(messageId) { return (c, entry) }
        }
        return nil
    }

    private func linkMembership(_ c: CCBridgeWebSocketClient, id: String) {
        membershipLinks[id] = c.sendTracker.store.membership.sink { [weak self] in self?.sendMembership.send($0) }
    }

    func defaults(for id: String) -> UserDefaults? {
        if id == Self.primaryId { return primary.defaults }
        guard entries.contains(where: { $0.id == id }) else { return nil }
        return suite(id)
    }

    // MARK: - 启动

    /// app 根调（可重复调）：先接回调、补推送 token、接 hello 核对，再开连接（不然一连上的回放先到、没人接）。
    /// 主 hub 照原 ContentView 冷启动逻辑连；附加 hub 只用自己 suite 的地址 + 自己的口令，永不补本机默认地址
    func start(bind: @escaping (CCBridgeWebSocketClient) -> Void) {
        self.bind = bind
        if !started {
            started = true
            purgePendingCleanup()
            wirePrimaryOnce()
            for e in entries { clients[e.id] = makeWiredClient(e) }
        }
        bind(primary)
        for e in entries { if let c = clients[e.id] { bind(c) } }
        distributeFocus()
        connect(Self.primaryId)
        for e in entries { connect(e.id) }
    }

    /// 来电（VoIP 拉起）补连主 hub：照配对快照核指纹，没配过 hub 就不连（原 NativeCallCoordinator 语义）
    func reconnectPrimary(fallbackToLocal: Bool) {
        wirePrimaryOnce()
        connect(Self.primaryId, fallbackToLocal: fallbackToLocal)
    }

    /// 主 hub 的 hello 核对 / 身份闸：任何一条连主 hub 的路径之前接好（VoIP 冷启动可能早于 app 根 start）
    private func wirePrimaryOnce() {
        guard !primaryWired else { return }
        primaryWired = true
        wire(primary, id: Self.primaryId)
    }

    /// 主 hub 现在配对着的口令（本机副本，指纹核过；对不上 / 被拒过 / 读不到 → nil）。API 卡编辑器、发送兜底用，绝不读 `cc-bridge`
    var pairedPrimaryToken: String? {
        let d = primary.defaults
        guard case .ok(let token) = CCHubPairingStore.verify(d, secret: secrets.read(account: Self.keychainAccount(for: Self.primaryId)),
                                                             allowLegacy: true),
              let token, d.string(forKey: CCHubPairingStore.rejectedFingerprintKey) != CCHubPairingStore.fingerprint(token) else { return nil }
        return token
    }

    /// Mac 外部 / 内嵌 hub 之间切换（CCHubProcess 跟内嵌 hub 端口）：显式授权——这一代上 hello 报的新 hub_id 直接核准，
    /// 交互代次推进（旧问题卡的答案不发给新那台）。口令是调用方给的那台本机 hub 的，不碰配对快照 / 本机副本
    func switchPrimaryLocally(urls: [URL], token: String?) {
        wirePrimaryOnce()
        primary.advanceInteractionEpoch()
        primary.connect(urls: urls, token: token)
        localSwitchEpoch = primary.interactionEpoch
        hubLog(Self.primaryId, "local switch authorized")
    }

    /// 按快照连一台（核指纹）。对不上 / 口令被拒过 → 待配对，不连
    private func connect(_ id: String, fallbackToLocal: Bool = true) {
        guard let d = defaults(for: id), let client = id == Self.primaryId ? primary : clients[id] else { return }
        guard statuses[id] != .identityChanged else { return }
        let isPrimary = id == Self.primaryId
        // 补本机副本（可能经 HubTokenStore 顺带 plist bootstrap）先做完，再一次性读地址 + 口令 + 指纹来核：连接用的三样出自同一次核验
        if isPrimary { backfillPrimaryLocalCopy(d) }
        let urls = CCBridgeEndpoints.configuredURLs(fallbackToLocal: isPrimary && fallbackToLocal, defaults: d)
        guard !urls.isEmpty else { return }
        let secret = secrets.read(account: Self.keychainAccount(for: id))
        switch CCHubPairingStore.verify(d, secret: secret, allowLegacy: isPrimary) {
        case .mismatch, .changed:
            // 主 hub 也不试连（impl1 #1）：本机副本被改过 = 不知道这个口令属于哪台
            needsPairing(id, client, reason: "这台电脑的口令和配对对不上，重新扫码配对一次")
        case .ok(let token):
            if secret != .unreadable, d.string(forKey: CCHubPairingStore.rejectedFingerprintKey) == CCHubPairingStore.fingerprint(token) {
                needsPairing(id, client, reason: "这台电脑不认现在的口令，重新扫码配对一次")
                return
            }
            if statuses[id] == .needsPairing {
                statuses[id] = .ready
                client.releasePairingHold()
            }
            client.connect(urls: urls, token: token, keepExistingToken: true)
            #if os(macOS)
            // Mac 主 hub 只连本机回环（外部 launchd hub / 没配过）= 这台 Mac 自己：按本机切换授权，跟内嵌 hub 来回换不停住
            if isPrimary, urls.allSatisfy(Self.isLoopback) { localSwitchEpoch = client.interactionEpoch }
            #endif
        }
    }

    nonisolated static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// 主 hub 本机副本还没有：从旧条目 `cc-bridge` 拷一份（只补不改）。老用户（还没指纹）照当前 `cc-bridge` 补并写指纹；
    /// 已有指纹的只在对得上时补（对不上 = 经 iCloud 同步来的别台口令，不拷，后面按待配对走）；`cc-bridge` 读不到这次不补。
    /// 旧条目也没有（Mac 首次 / hub 重装）：launchd plist 的口令只给「配对目标全是本机回环 = 就是这台 Mac 的 hub」补（两份都写），
    /// 配的是别的电脑就不补、不改指纹，原配对核不上 → 待配对（recheck1 #1）
    private func backfillPrimaryLocalCopy(_ d: UserDefaults) {
        let local = Self.keychainAccount(for: Self.primaryId)
        guard secrets.read(account: local) == .absent else { return }
        let stored = CCHubPairingStore.storedFingerprint(d)
        guard stored != CCHubPairingStore.writingMarker else { return }
        switch secrets.read(account: Self.legacyPrimaryAccount) {
        case .value(let token):
            guard stored == nil || stored == CCHubPairingStore.fingerprint(token) else {
                hubLog(Self.primaryId, "cc-bridge differs from paired fingerprint, not copied")
                return
            }
            guard secrets.write(token, account: local) else { return }
            if stored == nil { d.set(CCHubPairingStore.fingerprint(token), forKey: CCHubPairingStore.fingerprintKey) }
        case .absent:
            if let token = launchdToken(), !token.isEmpty,
               CCBridgeEndpoints.configuredURLs(defaults: d).allSatisfy(Self.isLoopback) {
                guard secrets.write(token, account: local) else { return }
                if !secrets.write(token, account: Self.legacyPrimaryAccount) { hubLog(Self.primaryId, "launchd token: legacy cc-bridge write failed") }
                d.set(CCHubPairingStore.fingerprint(token), forKey: CCHubPairingStore.fingerprintKey)
                hubLog(Self.primaryId, "local copy bootstrapped from launchd plist")
            } else if stored == nil {
                d.set(CCHubPairingStore.fingerprint(nil), forKey: CCHubPairingStore.fingerprintKey)
            }
        case .unreadable:
            return
        }
        if d.object(forKey: CCHubPairingStore.genKey) == nil { d.set(0, forKey: CCHubPairingStore.genKey) }
    }

    private func needsPairing(_ id: String, _ client: CCBridgeWebSocketClient?, reason: String) {
        statuses[id] = .needsPairing
        client?.holdForPairing(reason: reason)
    }

    // MARK: - 配对（扫码 / 手填 / 新增，统一入口）

    /// 主电脑从没配过对：没有扫码 / 手填写过的地址，也没记下过 hub_id。这时扫码 / 手填照原样直接写（不多一步）
    var primaryNeverPaired: Bool {
        CCHubPairing.read(primary.defaults) == CCHubPairing() && identity(of: Self.primaryId) == nil
    }

    /// 主电脑的入口改配对内容，握手认过之后还要人定落点的（b4 #1）：交给落点页（iOS HubPairingSheet）
    struct PrimaryPairingCheck: Identifiable, Equatable {
        let id = UUID()
        let pairing: CCHubPairing
        let token: String
        let match: PairingMatch
        /// hello 报的 hub_id / 主机名
        let reported: String?
        let hostName: String?
    }

    enum PrimaryPairingResult: Equatable {
        case applied
        case failed(UpdateResult)
        /// 不是「就是主电脑」：别覆盖，按落点让人定
        case confirm(PrimaryPairingCheck)
    }

    private final class ProbeBox {
        var reported: String?
        var hostName: String?
    }

    /// 主电脑入口（我的电脑 / CC 卡扫码、手填保存）改配对内容：从没配过对 → 照原样直接写；否则先握一次手 → classifyPairing（target = 主电脑）→
    /// 认出就是主电脑才更新（带预期 hub_id），其余一律不写、交给落点（b4 #1）。钥匙串写失败 / 撞了别的那台 → failed，配对没动
    func pairPrimary(_ pairing: CCHubPairing, token: String, providerManager: ProviderManager?, probe: PairingProbe? = nil) async -> PrimaryPairingResult {
        if primaryNeverPaired {
            let result = updatePairing(Self.primaryId, pairing, token: token, providerManager: providerManager)
            return result == .updated ? .applied : .failed(result)
        }
        let box = ProbeBox()
        let base: PairingProbe = probe ?? { pairing, token in await Self.handshakeProbe(pairing, token: token) { box.hostName = $0.hostName } }
        let match = await classifyPairing(pairing, token: token, target: Self.primaryId) { pairing, token in
            let outcome = await base(pairing, token)
            if case .hello(let id) = outcome { box.reported = id }
            return outcome
        }
        guard match == .update(Self.primaryId) else {
            return .confirm(PrimaryPairingCheck(pairing: pairing, token: token, match: match, reported: box.reported, hostName: box.hostName))
        }
        let result = updatePairing(Self.primaryId, pairing, token: token, expectedIdentity: box.reported, providerManager: providerManager)
        return result == .updated ? .applied : .failed(result)
    }

    /// 主 hub 手填（API 卡编辑器）：地址 / 口令都没变（本机副本里真的是这个口令）就不重写配对；reconnect = 「重连」按钮，变没变都重新握手。
    /// 变了走 pairPrimary（认过是主电脑才写）
    func applyPrimaryManual(primary primaryURL: String, backup: String, token: String, providerManager: ProviderManager?, reconnect: Bool,
                            probe: PairingProbe? = nil) async -> PrimaryPairingResult {
        let d = primary.defaults
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = CCHubPairing.read(d)
        let next = current.manual(primary: primaryURL, backup: backup)
        let stored = secrets.read(account: Self.keychainAccount(for: Self.primaryId))
        let unchanged = next == current && CCHubPairingStore.storedFingerprint(d) == CCHubPairingStore.fingerprint(token)
            && stored == (token.isEmpty ? .absent : .value(token)) && statuses[Self.primaryId] != .needsPairing
        guard unchanged else { return await pairPrimary(next, token: token, providerManager: providerManager, probe: probe) }
        if reconnect { handshake(Self.primaryId, token: token) }
        return .applied
    }

    /// 改一台的配对（同一台：换地址 / 换口令 / 换 pin，impl1 #6）。expectedIdentity = classifyPairing 握手看到的 hub_id：
    /// 跟这台记下的不一样 → differentMachine（只能新增）；口令 / hub_id 撞了别的那台 → duplicate*。
    /// 先写钥匙串（失败整个放弃）→ 再写快照（记下的 hub_id 保留）→ 断开重新握手；hello 核对过才放行业务（身份闸）
    @discardableResult
    func updatePairing(_ id: String, _ pairing: CCHubPairing, token: String, expectedIdentity: String? = nil,
                       providerManager: ProviderManager? = nil) -> UpdateResult {
        guard let d = defaults(for: id) else { return .secretWriteFailed }
        if let other = hubHolding(fingerprintOf: token, except: id) { return .duplicateToken(other) }
        if let expectedIdentity {
            if let other = hubs.map(\.id).first(where: { $0 != id && identity(of: $0) == expectedIdentity }) { return .duplicateIdentity(other) }
            if let stored = identity(of: id), stored != expectedIdentity { return .differentMachine }
        }
        let account = Self.keychainAccount(for: id)
        let writeSecret: (String) -> Bool = { [secrets] value in
            guard secrets.write(value, account: account) else { return false }
            if id == Self.primaryId {
                // 旧条目照旧写（老版本回滚读它）；连接不读它，写失败不影响这次配对
                let legacy = providerManager.map { $0.setApiKey(value, for: Self.legacyPrimaryAccount) }
                    ?? secrets.write(value, account: Self.legacyPrimaryAccount)
                if !legacy { BridgeProbe.log("pairing: legacy cc-bridge write failed (local copy ok)") }
            }
            return true
        }
        guard CCHubPairingStore.write(pairing, token: token, to: d, writeSecret: writeSecret) else {
            hubLog(id, "pairing write failed: keychain")
            // 旧口令可能已经被删（钥匙串 set 先删后写）：重新核一遍，对不上就进待配对
            if case .ok = CCHubPairingStore.verify(d, secret: secrets.read(account: account), allowLegacy: id == Self.primaryId) {} else {
                needsPairing(id, id == Self.primaryId ? primary : clients[id], reason: "口令没存进钥匙串，重新配对一次")
            }
            return .secretWriteFailed
        }
        let learned = expectedIdentity.flatMap { identity(of: id) == nil ? $0 : nil }
        if let learned { d.set(learned, forKey: CCHubPairingStore.hubIdentityKey) }
        statuses[id] = .ready
        handshake(id, token: token)
        if let learned { identityConfirmed(id, learned) }
        return .updated
    }

    /// 配对更新一律先断开再握手：同地址换口令 / 换 pin 时旧 TLS / WS 不能接着用（connect 按地址判「已连着」会提前返回）
    private func handshake(_ id: String, token: String) {
        guard let d = defaults(for: id), let client = id == Self.primaryId ? primary : clients[id] else { return }
        client.releasePairingHold()
        client.disconnect()
        let urls = CCBridgeEndpoints.configuredURLs(fallbackToLocal: id == Self.primaryId, defaults: d)
        guard !urls.isEmpty else { return }
        client.connect(urls: urls, token: token.isEmpty ? nil : token)
    }

    /// 这个口令挂在哪台上（空口令不算）
    private func hubHolding(fingerprintOf token: String, except id: String? = nil) -> String? {
        guard !token.isEmpty else { return nil }
        let fp = CCHubPairingStore.fingerprint(token)
        return hubs.map(\.id).first { $0 != id && defaults(for: $0).flatMap(CCHubPairingStore.storedFingerprint) == fp }
    }

    /// 加一台附加 hub：名单 → 配对快照（钥匙串失败就整台撤掉）→ 建 client、接回调、补推送 token → 连。
    /// identity = classifyPairing 握手看到的 hub_id（有就先记下，之后的 hello 必须对得上）；口令 / hub_id 撞了已有的那台就不加
    func addHub(name: String, pairing: CCHubPairing, token: String, identity reported: String? = nil) -> AddResult {
        if let dup = hubHolding(fingerprintOf: token) { return .duplicateToken(dup) }
        if let reported, let dup = hubs.map(\.id).first(where: { identity(of: $0) == reported }) { return .duplicateIdentity(dup) }
        let entry = Entry(id: UUID().uuidString, name: name)
        entries.append(entry)
        saveList()
        let account = Self.keychainAccount(for: entry.id)
        guard CCHubPairingStore.write(pairing, token: token, to: suite(entry.id), writeSecret: { [secrets] in secrets.write($0, account: account) }) else {
            entries.removeAll { $0.id == entry.id }
            saveList()
            suite(entry.id).removePersistentDomain(forName: suitePrefix + entry.id)
            suites.removeValue(forKey: entry.id)
            _ = secrets.remove(account: account)
            return .secretWriteFailed
        }
        if let reported { suite(entry.id).set(reported, forKey: CCHubPairingStore.hubIdentityKey) }
        statuses[entry.id] = .ready
        let client = makeWiredClient(entry)
        clients[entry.id] = client
        if started {
            bind?(client)
            connect(entry.id)
        }
        if let reported { identityConfirmed(entry.id, reported) }
        return .added(entry.id)
    }

    // MARK: - 扫码 / 手填落到哪台（B3.5，给 B4 UI；没有「替换」）

    enum PairingMatch: Equatable {
        /// 同一台（hub_id 对上；老 hub 不报 hub_id 时口令对上）→ updatePairing(那台, …, expectedIdentity:)，游标 / 去重 / 终端订阅都保留
        case update(String)
        /// 跟名单里哪台都不一样 → addHub（填名字）
        case addNew(reportedIdentity: String?)
        /// 从某台（target）的入口扫的，握手看到的却是另一台：不覆盖 target，建议添加为新电脑；
        /// matching = 它其实是名单里的那一台（那就更新那台）
        case differentMachine(target: String, matching: String?)
        /// 老 hub 不报 hub_id（或那台从没报过）、口令也对不上：让人选「X 换了口令」/「新电脑」
        case needsChoice
        /// 握手没成（连不上 / 口令被拒）
        case unreachable(String)
    }

    enum ProbeOutcome: Equatable {
        /// 握手成了；hubId = hello 报的 hub_id（老 hub 没有 / 不发 hello = nil）
        case hello(hubId: String?)
        case failed(String)
    }

    typealias PairingProbe = @MainActor (CCHubPairing, String) async -> ProbeOutcome

    /// 先用新配对握一次手看 hub_id，再决定是更新哪台还是新增。target = 从哪台的入口扫的（nil = 「再接一台」）。
    /// 主 hub 的入口扫进另一台机器的码 → differentMachine，绝不覆盖主 hub。只判断，不写任何东西
    func classifyPairing(_ pairing: CCHubPairing, token: String, target: String? = nil,
                         probe: PairingProbe? = nil) async -> PairingMatch {
        let outcome = await (probe ?? { await Self.handshakeProbe($0, token: $1) })(pairing, token)
        guard case .hello(let reported) = outcome else {
            if case .failed(let reason) = outcome { return .unreachable(reason) }
            return .unreachable("")
        }
        let ids = hubs.map(\.id)
        let byIdentity = reported.flatMap { r in ids.first { identity(of: $0) == r } }
        let fp = CCHubPairingStore.fingerprint(token)
        // 只在「认不出 hub_id」的台里按口令认（报过 hub_id 的台已经由上面认过，口令一样也不能算同一台）
        let byToken = token.isEmpty ? nil : ids.first {
            (reported == nil || identity(of: $0) == nil) && defaults(for: $0).flatMap(CCHubPairingStore.storedFingerprint) == fp
        }
        if let match = byIdentity ?? byToken {
            if let target, target != match { return .differentMachine(target: target, matching: match) }
            return .update(match)
        }
        if let target, status(for: target) != nil {
            // target 报过 hub_id 而且对不上 = 另一台；target 从没报过 = 分不清
            return reported != nil && identity(of: target) != nil ? .differentMachine(target: target, matching: nil) : .needsChoice
        }
        return reported == nil ? .needsChoice : .addNew(reportedIdentity: reported)
    }

    #if DEBUG
    /// 单测：临时握手的 client connect 之后调（装发送 / 收帧替身、喂帧）
    nonisolated(unsafe) static var probeClientHookForTesting: (@MainActor (CCBridgeWebSocketClient) -> Void)?
    #endif

    nonisolated static let probeSuiteName = "cc.hub.probe"
    private static var probeSuiteBusy = false

    /// 缺省的握手（impl1 #5）：临时 client 走只握手模式——一帧不发（不发配置 / focus / 终端 / 推送，连 client_info 都不发），hello 以外的帧不落；
    /// 独立临时 suite 只放这次的地址和 pin。等 hello / 鉴权被拒 / 10 秒，之后立刻失效拆掉。onHello：扫码落点要 hello 报的主机名起默认名字
    static func handshakeProbe(_ pairing: CCHubPairing, token: String, onHello: ((HubHello) -> Void)? = nil) async -> ProbeOutcome {
        // 固定一个 suite 反复用（B7.2 B6：清了键也会留一个空的偏好文件，按 UUID 起名就每认一次留一个）；同时有两个在认才另起一个
        let name = probeSuiteBusy ? probeSuiteName + "." + UUID().uuidString : probeSuiteName
        guard let d = UserDefaults(suiteName: name) else { return .failed("没法临时连这台电脑") }
        let ownsShared = name == probeSuiteName
        if ownsShared { probeSuiteBusy = true }
        d.removePersistentDomain(forName: name)
        defer {
            d.removePersistentDomain(forName: name)
            if ownsShared { probeSuiteBusy = false }
        }
        if let v = pairing.primaryURL { d.set(v, forKey: CCBridgeEndpoints.overrideKey) }
        if let v = pairing.backupURL { d.set(v, forKey: CCBridgeEndpoints.backupKey) }
        if let v = pairing.relayURL { d.set(v, forKey: CCBridgeEndpoints.relayKey) }
        if let v = pairing.relayPin { d.set(v, forKey: CCBridgeEndpoints.relayPinKey) }
        let urls = CCBridgeEndpoints.configuredURLs(fallbackToLocal: false, defaults: d)
        guard !urls.isEmpty else { return .failed("码里没有地址") }
        let client = CCBridgeWebSocketClient(hubId: "probe-" + UUID().uuidString, defaults: d)
        client.setLogName("probe")
        client.beginHandshakeOnly()
        let outcome = await withCheckedContinuation { (cont: CheckedContinuation<ProbeOutcome, Never>) in
            var done = false
            let finish: (ProbeOutcome) -> Void = { result in
                guard !done else { return }
                done = true
                cont.resume(returning: result)
            }
            client.onHello = { hello in
                onHello?(hello)
                finish(.hello(hubId: hello.hubId))
                return .reject
            }
            client.onAuthRejected = { _ in finish(.failed("这台电脑不认这个口令")) }
            client.connect(urls: urls, token: token.isEmpty ? nil : token)
            #if DEBUG
            probeClientHookForTesting?(client)
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak client] in
                // 连上了但一直没 hello = 老 hub（不发 hello）
                finish(client?.isConnected == true ? .hello(hubId: nil) : .failed("连不上这台电脑"))
            }
        }
        client.invalidate()
        return outcome
    }

    func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if id == Self.primaryId {
            primaryNameOverride = name.isEmpty ? nil : name
            if name.isEmpty { standard.removeObject(forKey: Self.primaryNameKey) } else { standard.set(name, forKey: Self.primaryNameKey) }
            return
        }
        guard let i = entries.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        entries[i].name = name
        saveList()
        clients[id]?.setLogName(name)
    }

    // MARK: - 删除（impl1 #8：先落删除记录再撤名单；每步可重做、做完一步销一项）

    enum RemovalStep { case recordWritten, listRemoved, invalidated }

    #if DEBUG
    /// 单测：删到这一步之后「进程没了」（返回 true 就到此为止，后面的步骤都不做）
    @ObservationIgnored var removalInterruptForTesting: ((RemovalStep) -> Bool)?
    #endif

    private func interrupted(_ step: RemovalStep) -> Bool {
        #if DEBUG
        return removalInterruptForTesting?(step) == true
        #else
        return false
        #endif
    }

    /// 删附加 hub：删除记录（槽位、hub_id、待注销的推送 token）先落盘 → 撤名单（client(for:) 立刻 nil）→ invalidate（业务入口当场关；
    /// 连着且身份核准过就在摘下的旧连接上发 unregister_push_token）→ 注销结果销账（没发出去转「待注销」，以后同一台连上先注销）→
    /// 删 suite + 钥匙串（钥匙串删成了才销掉整条记录，没成下次启动再删）。主 hub 不能删
    func remove(_ id: String) {
        guard id != Self.primaryId, let entry = entries.first(where: { $0.id == id }) else { return }
        var names = removedNames
        names[id] = entry.name
        setRemovedNames(names)
        var record = ["id": id]
        record["hub"] = suite(id).string(forKey: CCHubPairingStore.hubIdentityKey)
        record["token"] = deviceToken
        upsertCleanup(record)
        if interrupted(.recordWritten) { return }
        entries.removeAll { $0.id == id }
        saveList()
        statuses.removeValue(forKey: id)
        windowStores.removeValue(forKey: id)?.stopSyncing()
        membershipLinks.removeValue(forKey: id)
        CCSessionPhaseStore.shared.removeHub(id)
        CCSessionModelStore.shared.removeHub(id)
        if interrupted(.listRemoved) { return }
        let token = deviceToken
        let finish: (Bool) -> Void = { [weak self] sent in
            guard let self, !self.interrupted(.invalidated) else { return }
            self.settleUnregister(id, sent: sent)
            self.dropStorage(id)
        }
        guard let client = clients.removeValue(forKey: id) else { finish(false); return }
        client.invalidate(finalFrame: token.map { ["type": "unregister_push_token", "token": $0] }, completion: finish)
    }

    private var cleanupRecords: [[String: String]] {
        (standard.array(forKey: Self.pendingCleanupKey) ?? []).compactMap { item in
            if let id = item as? String { return ["id": id] }   // 返工前的格式：只有槽位 id
            return item as? [String: String]
        }
    }

    private func saveCleanup(_ records: [[String: String]]) {
        if records.isEmpty { standard.removeObject(forKey: Self.pendingCleanupKey) } else { standard.set(records, forKey: Self.pendingCleanupKey) }
    }

    private func upsertCleanup(_ record: [String: String]) {
        saveCleanup(cleanupRecords.filter { $0["id"] != record["id"] } + [record])
    }

    /// 删除记录里的推送 token 销账：发出去了直接销；没发出去、知道 hub_id 的转「待注销」再销；不知道 hub_id 的没法认那台，记日志销掉
    private func settleUnregister(_ id: String, sent: Bool) {
        var records = cleanupRecords
        guard let i = records.firstIndex(where: { $0["id"] == id }), let token = records[i]["token"] else { return }
        if !sent {
            if let identity = records[i]["hub"] {
                addPendingUnregister(identity: identity, token: token)
            } else {
                hubLog(id, "removed offline without hub_id: push token not unregistered")
            }
        }
        records[i].removeValue(forKey: "token")
        saveCleanup(records)
    }

    // MARK: - 推送 token / 设备设置广播（B2.7）

    func setPushToken(_ token: String) {
        deviceToken = token
        for c in liveClients { c.sendPushToken(token) }
    }

    func updatePushPreview(_ mode: String) {
        for c in liveClients { c.updatePushPreview(mode) }
    }

    /// 名字 / nudge / 传输默认值改了：每台都发（保暖表各发各的）
    func broadcastCCConfig() {
        for c in liveClients { c.sendCCConfig() }
    }

    private var liveClients: [CCBridgeWebSocketClient] {
        [primary] + entries.compactMap { clients[$0.id] }.filter { !$0.isInvalidated }
    }

    // MARK: - 内部

    private func suite(_ id: String) -> UserDefaults {
        if let d = suites[id] { return d }
        let d = UserDefaults(suiteName: suitePrefix + id) ?? .standard
        suites[id] = d
        return d
    }

    private func makeWiredClient(_ e: Entry) -> CCBridgeWebSocketClient {
        let c = makeClient(e.id, suite(e.id))
        c.setLogName(e.name.isEmpty ? String(e.id.prefix(8)) : e.name)
        let store = TerminalWindowStore(client: c, defaults: suite(e.id))
        c.windowStore = store
        windowStores[e.id] = store
        wire(c, id: e.id)
        linkMembership(c, id: e.id)
        // 连上前先把缓存的 focus 设对（didOpen 会重报缓存值）
        c.updateFocus(focusChat(for: e.id))
        return c
    }

    private func wire(_ c: CCBridgeWebSocketClient, id: String) {
        c.enableIdentityGate()
        c.onHello = { [weak self, weak c] hello in
            guard let self, let c else { return .reject }
            let verdict = self.noteHello(hello, id: id, client: c)
            if verdict == .approve {
                self.defaults(for: id)?.set(["id": hello.hostModelId, "name": hello.hostModelName].compactMapValues { $0 },
                                            forKey: Self.lastHostModelKey)
            }
            return verdict
        }
        c.onAuthRejected = { [weak self, weak c] fingerprint in
            guard let self, let d = self.defaults(for: id) else { return }
            // 只认配对口令被拒（Mac 内嵌 hub 那种显式给的口令不归这里）：记下，同一个口令不再自动试连，换了口令（重新配对）才重试。
            // 主 hub 老用户没存指纹：按本机副本里的口令认（B7.2 B4：不认就每 0.25 秒重连停不下）
            guard fingerprint == CCHubPairingStore.storedFingerprint(d) ?? self.unfingerprintedPrimaryToken(id) else { return }
            self.hubLog(id, "auth rejected, holding until the token changes")
            d.set(fingerprint, forKey: CCHubPairingStore.rejectedFingerprintKey)
            self.needsPairing(id, c, reason: "这台电脑不认现在的口令，重新扫码配对一次")
        }
        if let deviceToken { c.sendPushToken(deviceToken) }
    }

    /// 主 hub 没存指纹时本机副本口令的指纹（没有口令 = ""）；附加 hub / 读不到 = nil
    private func unfingerprintedPrimaryToken(_ id: String) -> String? {
        guard id == Self.primaryId else { return nil }
        switch secrets.read(account: Self.keychainAccount(for: id)) {
        case .value(let token): return CCHubPairingStore.fingerprint(token)
        case .absent: return CCHubPairingStore.fingerprint(nil)
        case .unreadable: return nil
        }
    }

    /// hello 的 hub_id → 这条连接的身份核准（impl1 #2）。第一次记下（撞了别的那台 = 矛盾）；跟记下的不一样 → 换了机器，停住、业务帧全丢。
    /// 主 hub 本机切换（Mac 外部 / 内嵌 hub）那一代显式授权：新 hub_id 直接记下、核准
    private func noteHello(_ hello: HubHello, id: String, client: CCBridgeWebSocketClient) -> CCBridgeWebSocketClient.IdentityVerdict {
        guard let d = defaults(for: id) else { return .reject }
        let stored = d.string(forKey: CCHubPairingStore.hubIdentityKey)
        if id == Self.primaryId, let epoch = localSwitchEpoch, epoch == client.interactionEpoch {
            if let reported = hello.hubId, reported != stored {
                hubLog(id, "local switch: hub_id \(stored?.prefix(8) ?? "-") → \(reported.prefix(8))")
                d.set(reported, forKey: CCHubPairingStore.hubIdentityKey)
                identityConfirmed(id, reported)
            }
            // 本机切换显式授权、这一代核准了：待配对 / 换了机器都解开（R5.3：只解 identityChanged 的话 route 还拦着这条好连接）
            if statuses[id] == .identityChanged || statuses[id] == .needsPairing {
                statuses[id] = .ready
                client.releasePairingHold()
            }
            if let reported = hello.hubId { flushPendingUnregister(identity: reported, on: client) }
            return .approve
        }
        guard let reported = hello.hubId else { return .approve }   // 老 hub 不报 hub_id：拿到 hello 即核准
        if let stored, stored != reported {
            return identityChanged(id, client, "hub_id changed \(stored.prefix(8)) → \(reported.prefix(8)), holding")
        }
        if stored == nil {
            if let other = hubs.map(\.id).first(where: { $0 != id && identity(of: $0) == reported }) {
                return identityChanged(id, client, "hub_id \(reported.prefix(8)) already belongs to \(other.prefix(8)), holding")
            }
            d.set(reported, forKey: CCHubPairingStore.hubIdentityKey)
            identityConfirmed(id, reported)
        }
        flushPendingUnregister(identity: reported, on: client)
        return .approve
    }

    private func identityChanged(_ id: String, _ client: CCBridgeWebSocketClient, _ log: String) -> CCBridgeWebSocketClient.IdentityVerdict {
        hubLog(id, log)
        statuses[id] = .identityChanged
        client.holdForPairing(reason: "连上的是另一台电脑，先停住，确认后再连")
        return .reject
    }

    private func addPendingUnregister(identity: String, token: String) {
        var list = standard.array(forKey: Self.pendingUnregisterKey) as? [[String: String]] ?? []
        guard !list.contains(where: { $0["hub"] == identity && $0["token"] == token }) else { return }
        list.append(["hub": identity, "token": token])
        standard.set(list, forKey: Self.pendingUnregisterKey)
    }

    private func removePendingUnregister(identity: String, token: String) {
        let list = standard.array(forKey: Self.pendingUnregisterKey) as? [[String: String]] ?? []
        standard.set(list.filter { !($0["hub"] == identity && $0["token"] == token) }, forKey: Self.pendingUnregisterKey)
    }

    /// 删掉时没注销成的那台又连上了：注销旧的 token，发成一条销一条（没发出去留着下次）。
    /// 跟现在这台设备的 token 一样 = 又加回来了、要推送，不注销（连上时刚报过），直接销
    private func flushPendingUnregister(identity: String, on client: CCBridgeWebSocketClient) {
        let list = standard.array(forKey: Self.pendingUnregisterKey) as? [[String: String]] ?? []
        for item in list where item["hub"] == identity {
            guard let token = item["token"] else { continue }
            if token == deviceToken {
                removePendingUnregister(identity: identity, token: token)
                continue
            }
            client.send(["type": "unregister_push_token", "token": token]) { [weak self] err in
                guard err == nil else { return }
                DispatchQueue.main.async { self?.removePendingUnregister(identity: identity, token: token) }
            }
        }
    }

    /// 删 suite + 钥匙串（可重复做）。钥匙串删成了才销掉整条删除记录，没成留着下次启动再删
    private func dropStorage(_ id: String) {
        suite(id).removePersistentDomain(forName: suitePrefix + id)
        suites.removeValue(forKey: id)
        guard secrets.remove(account: Self.keychainAccount(for: id)) else {
            hubLog(id, "keychain remove failed, cleanup kept for next launch")
            return
        }
        saveCleanup(cleanupRecords.filter { $0["id"] != id })
    }

    /// 上次删到一半就退出了：按删除记录做完——还在名单里的撤掉，没注销的 token 转「待注销」，suite / 钥匙串补删
    private func purgePendingCleanup() {
        let ids = Set(cleanupRecords.compactMap { $0["id"] })
        guard !ids.isEmpty else { return }
        if entries.contains(where: { ids.contains($0.id) }) {
            entries.removeAll { ids.contains($0.id) }
            saveList()
        }
        for id in ids {
            settleUnregister(id, sent: false)
            dropStorage(id)
        }
    }

    private func saveList() {
        standard.set(entries.map { ["id": $0.id, "name": $0.name] }, forKey: Self.listKey)
    }

    private func hubLog(_ id: String, _ msg: String) {
        let name = id == Self.primaryId ? nil : entries.first(where: { $0.id == id })?.name ?? String(id.prefix(8))
        BridgeProbe.log((name.map { "[hub:\($0)] " } ?? "") + msg)
    }
}

/// 对话在哪台 hub 上发过东西（impl1 #13）：改绑后 / 重启后原来那台迟到的回包据此照收。持久在 .standard 一个键，
/// 每条 (对话, 槽位) 记发送时那台的 hub_id + 时间；7 天过期、最多 300 条（按时间留新的）。
/// 每个收帧都要查：第一次读出来后留在内存，写入同时写盘（重启 = 新实例从盘上读）
final class CCSentHubLedger {
    static let key = "ccChatSentHubs"
    static let ttl: TimeInterval = 7 * 24 * 3600
    static let limit = 300

    let defaults: UserDefaults
    private var cache: [Item]?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private struct Item {
        let chat: String
        let hub: String
        let identity: String?
        let at: Date
    }

    private var items: [Item] {
        if let cache { return cache }
        let loaded = (defaults.array(forKey: Self.key) as? [[String: Any]] ?? []).compactMap { d -> Item? in
            guard let chat = d["chat"] as? String, let hub = d["hub"] as? String, let at = d["at"] as? Double else { return nil }
            return Item(chat: chat, hub: hub, identity: d["id"] as? String, at: Date(timeIntervalSince1970: at))
        }
        cache = loaded
        return loaded
    }

    func record(chatId: String, hubId: String, identity: String?, now: Date = Date()) {
        var next = items.filter { now.timeIntervalSince($0.at) < Self.ttl && !($0.chat == chatId && $0.hub == hubId) }
        next.append(Item(chat: chatId, hub: hubId, identity: identity, at: now))
        if next.count > Self.limit { next = Array(next.sorted { $0.at > $1.at }.prefix(Self.limit)) }
        cache = next
        defaults.set(next.map { i -> [String: Any] in
            var d: [String: Any] = ["chat": i.chat, "hub": i.hub, "at": i.at.timeIntervalSince1970]
            d["id"] = i.identity
            return d
        }, forKey: Self.key)
    }

    /// 过期前在这台上给这条对话发过东西；hub_id 两边都知道时必须一样（同槽位换了机器不算）
    func sent(chatId: String, hubId: String, identity: String?, now: Date = Date()) -> Bool {
        items.contains {
            $0.chat == chatId && $0.hub == hubId && now.timeIntervalSince($0.at) < Self.ttl
                && ($0.identity == nil || identity == nil || $0.identity == identity)
        }
    }
}

/// 对话里 CC 消息 / 问题卡的来源（R5.2，B7.2 B1），持久在独立 suite `cc.chatOrigins`（不放 .standard：消息表能到几百 KB，
/// 每条新回复整表重写，.standard 域涨大拖过收放面板），三张表各有上限：
/// - 消息：(对话, ccMessageId) → 推来它的那台（槽位 + hub_id），30 天、2000 条。edit 只认这条消息自己的那台
/// - 拒过的问题卡：对话绑着别的那台时拒过的 (那台, 对话, toolUseId)，7 天、300 条。改绑到那台后 / 重启后它重放也不收
/// - 改绑过的对话：不过期、500 条（按时间留新的）。edit 查不到来源时，只在从没改绑过的对话里放行
/// 消息 / 问题卡只有 ViewModel 这一个实例写，读过一次留在内存；改绑由 Registry 写，读的时候现读
final class CCChatOriginLedger {
    static let suiteName = "cc.chatOrigins"
    static var store: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }
    static let messagesKey = "ccMessageOrigins"
    static let refusedAsksKey = "ccRefusedAsks"
    static let reboundKey = "ccReboundChats"
    static let messageTTL: TimeInterval = 30 * 24 * 3600
    static let messageLimit = 2000
    static let askTTL: TimeInterval = 7 * 24 * 3600
    static let askLimit = 300
    static let reboundLimit = 500

    struct Origin: Equatable {
        let hub: String
        let identity: String?
    }

    let defaults: UserDefaults
    private var messages: [[String: Any]]?
    private var asks: [[String: Any]]?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: 消息

    func recordMessage(chatId: String, messageId: String, hubId: String, identity: String?, now: Date = Date()) {
        var list = live(&messages, Self.messagesKey, ttl: Self.messageTTL, now: now)
            .filter { !($0["chat"] as? String == chatId && $0["msg"] as? String == messageId) }
        list.append(Self.item(["chat": chatId, "msg": messageId, "hub": hubId], identity: identity, now: now))
        save(&messages, Self.capped(list, Self.messageLimit), Self.messagesKey)
    }

    func messageOrigin(chatId: String, messageId: String, now: Date = Date()) -> Origin? {
        live(&messages, Self.messagesKey, ttl: Self.messageTTL, now: now)
            .last { $0["chat"] as? String == chatId && $0["msg"] as? String == messageId }
            .flatMap { d in (d["hub"] as? String).map { Origin(hub: $0, identity: d["id"] as? String) } }
    }

    // MARK: 拒过的问题卡

    func recordRefusedAsk(chatId: String, toolUseId: String, hubId: String, identity: String?, now: Date = Date()) {
        guard !refusedAsk(chatId: chatId, toolUseId: toolUseId, hubId: hubId, identity: identity, now: now) else { return }
        var list = live(&asks, Self.refusedAsksKey, ttl: Self.askTTL, now: now)
        list.append(Self.item(["chat": chatId, "tool": toolUseId, "hub": hubId], identity: identity, now: now))
        save(&asks, Self.capped(list, Self.askLimit), Self.refusedAsksKey)
    }

    /// 同一台（槽位一样；hub_id 两边都知道时也得一样）拒过这条对话的这道题
    func refusedAsk(chatId: String, toolUseId: String, hubId: String, identity: String?, now: Date = Date()) -> Bool {
        live(&asks, Self.refusedAsksKey, ttl: Self.askTTL, now: now).contains { d in
            d["chat"] as? String == chatId && d["tool"] as? String == toolUseId && d["hub"] as? String == hubId
                && (d["id"] == nil || identity == nil || d["id"] as? String == identity)
        }
    }

    // MARK: 改绑过的对话

    static func recordRebind(chatId: String, defaults: UserDefaults, now: Date = Date()) {
        var map = defaults.dictionary(forKey: reboundKey) as? [String: Double] ?? [:]
        map[chatId] = now.timeIntervalSince1970
        if map.count > reboundLimit {
            map = Dictionary(uniqueKeysWithValues: map.sorted { $0.value > $1.value }.prefix(reboundLimit).map { ($0.key, $0.value) })
        }
        defaults.set(map, forKey: reboundKey)
    }

    static func wasRebound(chatId: String, defaults: UserDefaults) -> Bool {
        (defaults.dictionary(forKey: reboundKey) as? [String: Double])?[chatId] != nil
    }

    // MARK: 内部

    private static func item(_ fields: [String: Any], identity: String?, now: Date) -> [String: Any] {
        var d = fields
        d["at"] = now.timeIntervalSince1970
        d["id"] = identity
        return d
    }

    private static func capped(_ list: [[String: Any]], _ limit: Int) -> [[String: Any]] {
        list.count > limit ? Array(list.suffix(limit)) : list
    }

    private func live(_ cache: inout [[String: Any]]?, _ key: String, ttl: TimeInterval, now: Date) -> [[String: Any]] {
        let all = cache ?? (defaults.array(forKey: key) as? [[String: Any]] ?? [])
        cache = all
        return all.filter { ($0["at"] as? Double).map { now.timeIntervalSince1970 - $0 < ttl } ?? false }
    }

    private func save(_ cache: inout [[String: Any]]?, _ list: [[String: Any]], _ key: String) {
        cache = list
        defaults.set(list, forKey: key)
    }
}
