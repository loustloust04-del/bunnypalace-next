import Foundation
import Network
import Observation
import os
#if canImport(UIKit)
import UIKit
#endif

/// hub 端返回的远程错误（spawn_cc_err / list 失败 / WS send err）。
/// 包成 Error 让 Result<T, CCBridgeRemoteError> 走 Swift Result idiom。
struct CCBridgeRemoteError: LocalizedError {
    let reason: String
    /// reason 是 hub 回帧里给的中文原因（能直接给她看），不是本地拼的「没发出去」之类（#046）
    var fromHub = false
    var errorDescription: String? { reason }
}

/// `end_window` 没成的三种：hub 回了 ok=false / 5 秒没回音（老 hub 不认这帧）/ 没连上或等回音时断了
enum TerminalWindowEndError: Error {
    case refused
    case timedOut
    case offline
}

/// get_hub_config / set_agent_workdir / list_dirs 的在途回调（#046，astra 实现审 #3）：hub 回帧原样带回 request_id，按它认领。
/// 超时 / 断线已经收走的 id 再来回帧就找不到 = 直接丢；没带 request_id 的回帧不认领任何回调。
struct HubPendingRequests<Handler> {
    private var handlers: [String: Handler] = [:]

    mutating func add(_ id: String, _ handler: Handler) {
        handlers[id] = handler
    }

    mutating func take(_ id: String?) -> Handler? {
        guard let id else { return nil }
        return handlers.removeValue(forKey: id)
    }

    /// 断线 / 换连接：全部收走按失败回，旧连接迟到的回帧从此认不出来
    mutating func takeAll() -> [Handler] {
        defer { handlers.removeAll() }
        return Array(handlers.values)
    }
}

@Observable
final class CCBridgeWebSocketClient: NSObject {
    static let shared = CCBridgeWebSocketClient()

    // MARK: - Public observable state

    private(set) var isConnected: Bool = false
    private(set) var lastError: String?
    /// 最近一份 hub `hello`（#046 T3）。断线时**保留**上一份——「我的电脑」页还能写「连不上 粟粟的 MacBook Pro」；
    /// 但 `hubInfoIsCurrent` 落 false：重连的可能是另一个 hub（重新配过对 / 老 hub 不发 hello），
    /// 拦 [+] 菜单、显示干活目录这类「按电脑现状做决定」的地方只认 current 的那份。
    private(set) var hubInfo: HubHello?
    /// 这份 hubInfo 是不是当前这条连接上收到的。didOpen 时落 false，收到 hello 才翻 true。
    private(set) var hubInfoIsCurrent = false
    /// 当前连接对应电脑的 hello（不是当前连接的、或者现在没连着，就当不知道）
    var currentHubInfo: HubHello? { hubInfoIsCurrent && isConnected ? hubInfo : nil }
    /// 送达异常（K1 第 4b 步）：每条消息一个状态对象，气泡标记只订阅自己那条（见 CCSendTracker）。
    /// 只放内存，app 重启就没了——hub 那边照样核对补救，丢的只是这个标记。只在 main 上用。
    @ObservationIgnored let sendTracker = CCSendTracker()

    // MARK: - Private state

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var url: URL?
    /// 候选 URL 列表（含 token）。主 URL 为 urls[0]，断开时 reconnect 轮换到下一个。
    /// 这样在家 LAN 主 + 出门 Tailscale 备用，能自动 fallback。
    @ObservationIgnored private var urls: [URL] = []
    /// 竞速探测的世代号：新一轮 startTask/disconnect 都 +1，在途旧 probe 回调按号丢弃。
    @ObservationIgnored private var probeGeneration = 0
    @ObservationIgnored private var probeSession: URLSession?
    @ObservationIgnored private var reconnectDelay: TimeInterval = CCBridgeWebSocketClient.minReconnectDelay
    /// 前台断线重试间隔封顶（plan-hub-instant-connect）：hub 一恢复 / 网络一通 ≤1s 就再试；后台照旧退避到 30s
    private static let minReconnectDelay: TimeInterval = 0.25
    private static let foregroundMaxReconnectDelay: TimeInterval = 1
    /// /health 竞速单个候选的超时：LAN 毫秒级、Tailscale 中继首包一两秒，给 4s；不通就快点重来
    private static let probeTimeout: TimeInterval = 4
    /// 网络路径（Wi-Fi / 蜂窝 / VPN 切换）一变立刻重新竞速，不等退避
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSignature: String?
    @ObservationIgnored private var reconnectTimer: Timer?
    @ObservationIgnored private var pingTimer: Timer?
    /// 连接阶段看门狗：timeoutIntervalForRequest=600 是给已连上的 idle 保活的，但它同时管
    /// handshake——连黑洞 IP（换 WiFi 后的旧 LAN 地址无 RST）要挂满 10 分钟才失败，主备轮换
    /// 形同虚设。didOpen 前单独限 10s，超时掐掉这次尝试走正常 reconnect 轮换下一个候选。
    @ObservationIgnored private var connectWatchdog: Timer?
    private static let connectTimeout: TimeInterval = 10
    @ObservationIgnored private var manualClose = false
    /// 常驻回调：所有 reply / CC 主动消息统一走它落地成会话消息（收口即发后无 pending 占位概念，
    /// insertProactive 自己存 ccMessageId，thinking/edit 锚定不受影响）。app 启动连接处注册一次（ContentView）。
    @ObservationIgnored var onProactiveMessage: ((_ chatId: String, _ content: String, _ fileData: Data?, _ fileName: String?, _ mime: String?, _ isImage: Bool, _ ccMessageId: String?, _ replyToId: String?, _ callReply: CCCallReply?) -> Void)?
    /// A4：CC 编辑某条消息 → app 按 ccMessageId 找节点改 content。
    @ObservationIgnored var onEditMessage: ((_ chatId: String, _ ccMessageId: String, _ content: String, _ streaming: Bool) -> Void)?
    /// 思考链回传：CC 当轮 thinking（hub 锚定到 ccMessageId 那条消息）→ app 挂到对应节点。
    @ObservationIgnored var onThinking: ((_ chatId: String, _ ccMessageId: String, _ content: String) -> Void)?
    /// 问问题 CC 桥（plan-问问题-cc桥）：CC 调 AskUserQuestion → hub 推题面 → app 弹选择卡。
    @ObservationIgnored var onAskUserQuestion: ((_ chatId: String, _ toolUseId: String, _ questions: [[String: Any]]) -> Void)?
    /// 问题收账（答案/declined）→ 收卡 + 落 Q/A 泡（唯一落泡来源）。answers nil = declined。
    @ObservationIgnored var onAskUserResolved: ((_ chatId: String, _ toolUseId: String, _ questions: [[String: Any]], _ answers: [String: String]?) -> Void)?
    /// 答案没赶上（已在别处答/TUI 死了）→ 收卡。
    @ObservationIgnored var onAskUserStale: ((_ toolUseId: String) -> Void)?
    /// APNs device token（AppDelegate 注册成功后塞进来），(重)连时报给 hub。
    @ObservationIgnored private var pushToken: String?

    /// CR-4：agent 读书产物（批注+消息）到货回调。返回 true = 处理成功 → 回 ack 让 hub 删 pending。
    /// app 根接线到 AgentBookNoteWriter；未接线时不 ack（hub 重连补投，不丢）。
    @ObservationIgnored var onAgentBookNote: ((_ payload: [String: Any]) -> Bool)?
    /// 小克用本地推特（TwitterCCBridge）：收 `twitter_cmd` 帧 → 返回 `twitter_result` 帧原样回给 hub。
    /// app 根接线（ContentView）；未接线时回错，hub 那边不用干等超时。
    @ObservationIgnored var onTwitterCmd: (@MainActor (_ frame: [String: Any]) -> [String: Any])?
    /// R5：agent 状态快照到货（iOS 设置-Agent 页拉取/写配置后 hub 都回它）。页面 onAppear 注册。
    @ObservationIgnored var onAgentStatusResult: ((_ payload: [String: Any]) -> Void)?
    /// agent_book_note 已处理 uuid（去重：hub 补投/重复广播无害）。保 200。
    private static let seenBookNoteKey = "agentBookNoteSeenUUIDs"

    /// 推送文案偏好（per-device）：full=完整预览 / hidden=只「小克找你了」。随 register_push_token 同步给 hub。
    static let pushPreviewKey = "ccPushPreview"
    private var pushPreview: String { UserDefaults.standard.string(forKey: Self.pushPreviewKey) ?? "full" }

    /// register_push_token 帧。topic = 本包 bundle id、env 按签名判：hub 按 token 逐个选 apns-topic 和 host
    /// （同一个 hub 下可能同时挂着 .ios 开发包和 .susu Ad Hoc 包）。
    private func pushTokenFrame(_ token: String, preview: String) -> [String: Any] {
        var frame: [String: Any] = ["type": "register_push_token", "token": token, "env": APNsEnvironment.current, "preview": preview]
        if let topic = Bundle.main.bundleIdentifier { frame["topic"] = topic }
        return frame
    }

    /// AppDelegate 拿到 device token 后调：记下 + 立即报给 hub（未连则连上后由 didOpen 补报）。
    func sendPushToken(_ token: String) {
        pushToken = token
        send(pushTokenFrame(token, preview: pushPreview)) { _ in }
    }

    /// 设置页改推送偏好后调：存 UserDefaults + 若已连上则立即重发 register_push_token 让 hub 即时生效。
    func updatePushPreview(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: Self.pushPreviewKey)
        if let t = pushToken {
            send(pushTokenFrame(t, preview: mode)) { _ in }
        }
    }

    // MARK: - Live Activity token 注册（D6）
    //
    // 跟上面 register_push_token 那套**完全隔离**：新消息类型、新落盘文件、hub 侧新 Map。
    // 作用域 / topic / payload / 路由身份四不同，不是「同一个 token 的两种用法」。

    /// 报一条 LA push token（update = 某个 activity 的；start = 这台设备的 push-to-start）。
    /// WS 没连上时 `send` 直接失败——没关系，记录已落 `UserDefaults`，`didOpen` 会全量补报。
    func sendLiveActivityRegistration(_ r: CCLiveActivityRegistration) {
        var frame = r.wireFields()
        frame["type"] = "register_la_token"
        send(frame) { _ in }
    }

    /// M4b2 ③：冷启动对账 —— 问 hub「这些岛那一轮还活着吗」。回帧 `la_query_result`。
    func sendLiveActivityQuery(activityIds: [String]) {
        send(["type": "la_query", "activity_ids": activityIds]) { _ in }
    }

    /// 岛没了 / hub 拒了 → 让 hub 也删掉，别继续往死 token 推。
    func sendLiveActivityUnregister(kind: CCLiveActivityRegistration.Kind,
                                    activityId: String?,
                                    installId: String?) {
        var frame: [String: Any] = ["type": "unregister_la_token", "kind": kind.rawValue]
        if let activityId { frame["activity_id"] = activityId }
        if let installId { frame["install_id"] = installId }
        send(frame) { _ in }
    }

    // MARK: - 缓存保暖策略（per tmux session，不是 per conversation）
    //
    // 保暖保的是一个 tmux 进程里那**一份** prompt cache，所以策略天然属于 session：
    // 共享同一 session 的对话（默认 mp-cc 就是显式共享的）本来就该共享策略，
    // 存在 Conversation 上会让它们各持一份互相打架。
    // 也因此不进 SwiftData/iCloud —— tmux session 是这台 Mac 的东西，同步到手机没有意义。
    static let keepalivePolicyKey = "ccKeepalivePolicies"

    /// "always" 🔥常驻 / "auto" ⚙️默认 / "never" ❄️不保
    static func keepalivePolicy(for session: String) -> String {
        let d = UserDefaults.standard.dictionary(forKey: keepalivePolicyKey) as? [String: String]
        return d?[session] ?? "auto"
    }

    /// 改完立刻推给 hub（hub 侧落盘，重启不丢）。auto = 删除条目，回到默认。
    static func setKeepalivePolicy(_ policy: String, for session: String) {
        var d = (UserDefaults.standard.dictionary(forKey: keepalivePolicyKey) as? [String: String]) ?? [:]
        if policy == "auto" { d.removeValue(forKey: session) } else { d[session] = policy }
        UserDefaults.standard.set(d, forKey: keepalivePolicyKey)
        shared.sendCCConfig()
    }

    static let transportPolicyKey = "ccTransportPolicies"

    /// "tmux" 带终端 / "stream" 不带终端（逐字流式）/ "" 跟随全局设置。按 session 设（同保暖）。
    static func transportPolicy(for session: String) -> String {
        let d = UserDefaults.standard.dictionary(forKey: transportPolicyKey) as? [String: String]
        return d?[session] ?? ""
    }

    /// 只发这一条的改动；hub 是唯一真相，改完回推 transport_policies 给所有设备（本机也靠它落 UserDefaults）。
    /// 先本地写一份让菜单勾立刻跟上。
    static func setTransportPolicy(_ policy: String, for session: String) {
        var d = (UserDefaults.standard.dictionary(forKey: transportPolicyKey) as? [String: String]) ?? [:]
        if policy.isEmpty { d.removeValue(forKey: session) } else { d[session] = policy }
        UserDefaults.standard.set(d, forKey: transportPolicyKey)
        shared.send(["type": "set_transport_policy", "session": session, "policy": policy]) { _ in }
    }

    /// 同步 CC 设置（推送名=assistantName / nudge 参数 / 系统提示模板 / 保暖策略 / 传输策略）给 hub。连上 + 改设置时调。
    func sendCCConfig() {
        let d = UserDefaults.standard
        var payload: [String: Any] = [
            "type": "set_cc_config",
            "pushName": (d.string(forKey: "assistantName") ?? "助手"),
            "userName": (d.string(forKey: "userName") ?? "你"),
            "nudgeEnabled": (d.object(forKey: "ccNudgeEnabled") as? Bool) ?? true,
            "newSessionTransport": d.bool(forKey: "ccNewSessionStream") ? "stream" : "tmux",
            // 整表下发（app 是唯一真相源）。空表也发——她把最后一个常驻取消了，hub 得知道
            "keepalivePolicies": (d.dictionary(forKey: Self.keepalivePolicyKey) as? [String: String]) ?? [:],
        ]
        if let v = d.object(forKey: "ccNudgeIdleMin") as? Int, v > 0 { payload["idleMinMin"] = v }
        if let v = d.object(forKey: "ccNudgeIdleMax") as? Int, v > 0 { payload["idleMaxMin"] = v }
        if let v = d.object(forKey: "ccNudgeQuietStartMin") as? Int { payload["quietStartMin"] = v }
        if let v = d.object(forKey: "ccNudgeQuietEndMin") as? Int { payload["quietEndMin"] = v }
        if let v = d.object(forKey: "ccNudgeCooldown") as? Int, v >= 0 { payload["cooldownMin"] = v }
        if let t = d.string(forKey: "ccNudgeTemplate"), !t.isEmpty { payload["nudgeTemplate"] = t }
        send(payload) { _ in }
    }

    /// 楼层语音设置 → hub 改写 cc-rp CLAUDE.md 的 mp-voice 标记块（plan-cc-terminal-mirror 二-b）。
    /// 按内容去重：跟本进程上次发过的一样就不发；发送失败清掉，下次照发。发 CC 消息前 / 改语音设置时调（主线程）。
    @ObservationIgnored private var lastVoiceInstructions: String?
    func syncVoiceInstructions(_ content: String) {
        guard content != lastVoiceInstructions else { return }
        lastVoiceInstructions = content
        send(["type": "set_voice_instructions", "content": content]) { [weak self] err in
            guard err != nil else { return }
            DispatchQueue.main.async {
                if self?.lastVoiceInstructions == content { self?.lastVoiceInstructions = nil }
            }
        }
    }

    /// 绑定开关：通知 hub 实绑哪些接口（关 LAN=hub 真不监听 LAN）。只本机 loopback 有效，故仅 Mac 调。
    func sendBindConfig() {
        let d = UserDefaults.standard
        send([
            "type": "set_bind",
            "lan": (d.object(forKey: "ccBindLan") as? Bool) ?? true,
            "tailscale": (d.object(forKey: "ccBindTailscale") as? Bool) ?? true,
        ]) { _ in }
    }
    /// L2: spawn 结果回调，key = 请求时的 session_name
    @ObservationIgnored private var spawnHandlers: [String: (Result<Void, CCBridgeRemoteError>) -> Void] = [:]
    /// L2: list_sessions 回调队列（不带 key，每个 list 请求都会用最早注册的 handler 接收第一个结果）
    @ObservationIgnored private var listHandlers: [(Result<[String], CCBridgeRemoteError>) -> Void] = []
    /// L4: terminal stream handlers per session_name
    /// 第二个参数是 `terminal_init` 帧的 `mouse_any`（tmux `#{mouse_any_flag}`）：
    /// 窗口里跑的东西开没开鼠标上报。老 hub 不发这个字段 → nil。
    @ObservationIgnored private var terminalInitHandlers: [String: (Data, Bool?) -> Void] = [:]
    @ObservationIgnored private var terminalChunkHandlers: [String: (Data) -> Void] = [:]
    @ObservationIgnored private var terminalErrorHandlers: [String: (String) -> Void] = [:]
    @ObservationIgnored private var terminalUsageHandlers: [String: (TerminalUsage) -> Void] = [:]
    /// terminal_paste 等回包：request_id → 回调（nil = 送达，否则失败原因）
    @ObservationIgnored private var terminalPasteHandlers: [String: (String?) -> Void] = [:]
    /// 这个 hub 认不认 `terminal_paste`（`terminal_init.paste`，#053）：true 认 / false 老 hub（init 没带这字段）/
    /// nil 还不知道（没收到 init，或刚断线 —— 重连的可能是另一个 hub）。只在 main 上读写。
    @ObservationIgnored private(set) var hubSupportsTerminalPaste: Bool?
    // 全局终端窗口（跟对话无关）。跟 listHandlers 同款：请求时排队，结果到了一次性 flush。
    @ObservationIgnored private var windowListHandlers: [(Result<[TerminalWindowInfo], CCBridgeRemoteError>) -> Void] = []
    @ObservationIgnored private var windowOpenHandlers: [(Result<String, CCBridgeRemoteError>) -> Void] = []
    @ObservationIgnored private var windowRestoreHandlers: [(Result<String, CCBridgeRemoteError>) -> Void] = []
    /// `window_ended` 带 code，按 code 认领回调（同时结束两个也不会串）；内层按请求 id 存，超时 / 断连单独摘走。
    @ObservationIgnored private var windowEndHandlers: [String: [UUID: (Result<Void, TerminalWindowEndError>) -> Void]] = [:]
    /// L4: 每个已订阅 session 的最新 cols/rows，断线重连时 didOpen 用它重发 terminal_attach
    /// （hub 在 client 断开时会拆掉 pipe-pane 流，重连后必须重订阅否则黑屏）。
    @ObservationIgnored private var terminalAttachParams: [String: (cols: Int, rows: Int)] = [:]
    /// 每个 session 的 terminal_attach 交给了哪个 task（T06）。didOpen 时没交给当前 task 的一律补发：
    /// 多候选探测期 task 是 nil，首发 attach 静默失败；首连没连成的 task 上排着的 attach 也跟着死了。
    /// 存 task 本身（强引用）而不是 ObjectIdentifier：旧 task 释放后地址可能被新 task 复用，=== 才可靠。只在 handlersQueue 上读写。
    @ObservationIgnored private var attachSentOnTask: [String: URLSessionWebSocketTask] = [:]
    /// 补订阅撞 session_not_found 时自动 spawn 过的连接（T06，astra P1-6）：每个 session 每条连接最多一次。只在 handlersQueue 上读写。
    @ObservationIgnored private var autoSpawnedOn: [String: URLSessionWebSocketTask] = [:]
    /// set_agent_workdir 等回音：hub_config = 成功（nil）/ hub_config_error = 中文原因。按 request_id 认领。只在 handlersQueue 上读写。
    @ObservationIgnored private var hubConfigHandlers = HubPendingRequests<(String?) -> Void>()
    /// list_dirs 等回音，按 request_id 认领。只在 handlersQueue 上读写。
    @ObservationIgnored private var dirListHandlers = HubPendingRequests<(Result<HubDirListing, CCBridgeRemoteError>) -> Void>()
    /// 终端出字账本（plan-hub-instant-connect §六）：点开终端的时刻 + 发 attach 的时刻，等第一帧 terminal_init（handlersQueue 上读写）
    @ObservationIgnored private var terminalOpenTiming: [String: (openedAt: Date, attachAt: Date)] = [:]
    /// 最近一次 WS 打开（主线程）：attach 发出时桥没通，等桥的时长 = 它 - attachAt
    @ObservationIgnored private var lastOpenAt: Date?
    @ObservationIgnored private let handlersQueue = DispatchQueue(label: "cc.bridge.handlers")
    /// 已 deliver 的 reply_id 缓存（hub 在 reconnect 时会 replay 持久缓冲里全部 reply，
    /// client 端去重避免同一条投递两次）。
    /// ⚠️ 保留条数必须 ≥ hub MAX_REPLY_LOG(500)，否则 replay 到尾部时去重已被剔 → 漏过去重 →
    /// 旧回复冒充当前答复（回复错位）。取 600 留余量。按条数（不按时间）才能扛长断连/hub 重启。
    @ObservationIgnored private var seenReplyIds: [String: Date] = [:]
    private let replyDedupKeepCount = 600
    private static let seenStoreKey = "ccSeenReplyIds"
    /// thinking 帧去重（独立于 reply 表：混用会挤掉 reply 去重条目 → 旧 reply 漏过去重）。
    /// 保留条数 ≥ hub MAX_THINKING_LOG(200)，取 300。
    @ObservationIgnored private var seenThinkingIds: [String: Date] = [:]
    private let thinkingDedupKeepCount = 300
    private static let seenThinkingStoreKey = "ccSeenThinkingIds"
    @ObservationIgnored private let dedupDefaults: UserDefaults
    /// 收到过的最大 reply / thinking ts（hub 钟）。连接带 since= 让 hub 只补这之后的，
    /// 不再每次连上都重放 500 条（plan-hub-instant-connect）。只在主线程读写。
    @ObservationIgnored private var replyCursor: Double = 0
    private static let replyCursorKey = "ccReplyCursorTs"
    /// since 往回让一点：投递排队中被杀的那几条下次还能补上（去重兜重复）
    private static let replyCursorMarginMs: Double = 120_000

    override convenience init() {
        self.init(dedupDefaults: .standard)
    }

    /// 只注入 reply / thinking 去重存储，测试不碰真实账户的重放记录。
    init(dedupDefaults: UserDefaults) {
        self.dedupDefaults = dedupDefaults
        super.init()
        replyCursor = dedupDefaults.double(forKey: Self.replyCursorKey)
        startPathMonitor()
        // 载回持久化的去重表：app 被 iOS 杀掉重启后，hub 重连仍会 replay 缓冲里全部旧 reply，
        // 内存去重表已清空会漏过 → 旧回复被当主动消息重复插入。持久化后重启仍能拦住。
        handlersQueue.async { [weak self] in
            guard let self else { return }
            guard let dict = self.dedupDefaults.dictionary(forKey: Self.seenStoreKey) as? [String: Double] else { return }
            var loaded = dict.mapValues { Date(timeIntervalSince1970: $0) }
            // 留最新 N 个（按条数，不按时间）
            if loaded.count > self.replyDedupKeepCount {
                let keep = loaded.sorted { $0.value > $1.value }.prefix(self.replyDedupKeepCount)
                loaded = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            self.seenReplyIds = loaded
        }
        handlersQueue.async { [weak self] in
            guard let self else { return }
            guard let dict = self.dedupDefaults.dictionary(forKey: Self.seenThinkingStoreKey) as? [String: Double] else { return }
            var loaded = dict.mapValues { Date(timeIntervalSince1970: $0) }
            if loaded.count > self.thinkingDedupKeepCount {
                let keep = loaded.sorted { $0.value > $1.value }.prefix(self.thinkingDedupKeepCount)
                loaded = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            self.seenThinkingIds = loaded
        }
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppForeground),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }

    // MARK: - 秒连账本（plan-hub-instant-connect §五）
    // 一段 = 从「需要连接」到 WS 打开。起点按粟粟口径：冷启动 = 点开图标（进程起点），回前台 = 即将进前台，
    // 掉线 / 换网 = 发生那一刻。连上后整段明细发 connect_report 给 hub，hub 对上自己的卡顿记录贴理由记账。

    private struct ConnectEpisode {
        let trigger: String
        let t0: Date
        var launchMs: Double?
        var prewarm = false
        var bgMs: Double = 0
        var bgSince: Date?
        var waitMs: Double = 0
        var mainDelayMs: Double = 0
        var attempts: [[String: Any]] = []
        /// 尺子（plan-app-instant-connect §2）：建这一段 = 连接入口，单调时钟起点 + 连接窗口主线程忙段从这里开；关尺子为 nil
        var ruler: ConnectRulerEpisode? = ConnectRuler.enabled ? .start() : nil
    }
    @ObservationIgnored private var episode: ConnectEpisode?
    /// 尺子 R1-4：进程内 WS 尝试序号 + 最近一次尝试的 task（只做测量归属，不参与连接决策）。只在主线程读写
    @ObservationIgnored private var rulerWSAttemptSeq = 0
    @ObservationIgnored private var rulerLastWS: (task: ObjectIdentifier, attempt: Int)?
    /// 尺子 R1-6：探测赢家（代次 + 候选 id），openSocket 那次 resume 取走；代次对不上 = 直连
    @ObservationIgnored private var rulerProbeWinner: (gen: Int, id: String)?
    @ObservationIgnored private var launchEpisodeStarted = false
    @ObservationIgnored private var willEnterForegroundAt: Date?

    /// 只在主线程调。已有一段在跑就不动（replace=true 时换成新的一段）。
    private func beginEpisode(_ trigger: String, at t0: Date = Date(), replace: Bool = false) {
        if !launchEpisodeStarted {
            launchEpisodeStarted = true
            #if os(iOS)
            let prewarm = ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
            #else
            let prewarm = false
            #endif
            // 预热过的进程起点早于点开，没法知道点开时刻 → 退到这一刻并标出来
            if !prewarm, let start = Self.processStartDate() {
                episode = ConnectEpisode(trigger: "launch", t0: start, launchMs: t0.timeIntervalSince(start) * 1000)
            } else {
                episode = ConnectEpisode(trigger: "launch", t0: t0, prewarm: prewarm)
                episode?.ruler?.launchFail = !prewarm   // 尺子：p_starttime 读失败，旧口径 t0 照旧退到这一刻，新口径显式标出
            }
            return
        }
        guard episode == nil || replace else { return }
        if episode?.ruler != nil { ConnectRunCounters.bump(\.replaced) }   // 尺子：没连上就被换掉的一段
        episode = ConnectEpisode(trigger: trigger, t0: t0)
    }

    private func recordAttempt(host: String?, result: String, since start: Date) {
        episode?.attempts.append(["h": host ?? "?", "r": result, "ms": Int(Date().timeIntervalSince(start) * 1000)])
    }

    private func noteMainDelay(since enqueuedAt: Date) {
        let ms = Date().timeIntervalSince(enqueuedAt) * 1000
        if let ep = episode, ms > ep.mainDelayMs { episode?.mainDelayMs = ms }
    }

    private func finishEpisode(host: String?) {
        guard var ep = episode else { return }
        let finishNs = ConnectRuler.stamp()
        if ep.ruler != nil { ConnectRunCounters.bump(\.ok) }
        episode = nil
        let now = Date()
        if let since = ep.bgSince { ep.bgMs += now.timeIntervalSince(since) * 1000 }
        let total = max(0, now.timeIntervalSince(ep.t0) * 1000 - ep.bgMs)
        var frame: [String: Any] = [
            "type": "connect_report", "trigger": ep.trigger,
            "t0": Int(ep.t0.timeIntervalSince1970 * 1000), "open_at": Int(now.timeIntervalSince1970 * 1000),
            "total_ms": Int(total), "bg_ms": Int(ep.bgMs), "wait_ms": Int(ep.waitMs), "main_delay_ms": Int(ep.mainDelayMs),
            "attempts": ep.attempts, "host": host ?? "", "path": lastPathSignature ?? "",
        ]
        if let launchMs = ep.launchMs { frame["launch_ms"] = Int(launchMs) }
        if ep.prewarm { frame["prewarm"] = true }
        if let ruler = ep.ruler { frame.merge(Self.rulerFields(ep, ruler, finishNs: finishNs, deviceId: ConnectRuler.deviceId(dedupDefaults))) { old, _ in old } }
        let tried = ep.attempts.map { "\($0["h"] ?? "?")=\($0["r"] ?? "?")" }.joined(separator: ",")
        let launch = ep.launchMs.map { "\(Int($0))ms" } ?? "-"
        BridgeProbe.log("connect \(Int(total))ms trigger=\(ep.trigger)\(total > 1000 ? " SLOW" : "") launch=\(launch) wait=\(Int(ep.waitMs))ms tried=\(tried)")
        send(frame) { [ruled = ep.ruler != nil] err in if err != nil, ruled { ConnectRunCounters.bump(\.reportFailed) } }   // 尺子：下一份报告带上来
    }

    /// 尺子新字段：冷启动那段带启动分段 + 进程起点→入口（墙钟，预热 / 读失败不给）
    private static func rulerFields(_ ep: ConnectEpisode, _ ruler: ConnectRulerEpisode, finishNs: UInt64, deviceId: String) -> [String: Any] {
        var ruler = ruler
        ruler.resolveMetrics()
        guard ep.trigger == "launch" else { return ruler.fields(finishNs: finishNs, deviceId: deviceId, launch: nil) }
        let marks = LaunchMarks.snapshot()
        let preMain = ep.launchMs == nil ? nil : marks.entryWall.map { $0.timeIntervalSince(ep.t0) * 1000 }
        let launch = ConnectRulerEpisode.LaunchInfo(segs: LaunchMarks.offsets(marks.marks, connectNs: ruler.entryNs), preMainMs: preMain,
                                                   source: ConnectRuler.launchSource(notes: marks.notes, prewarm: ep.prewarm),
                                                   recovery: marks.notes.filter { $0.hasPrefix("rec:") }.map { String($0.dropFirst(4)) })
        return ruler.fields(finishNs: finishNs, deviceId: deviceId, launch: launch)
    }

    /// 尺子：WS resume 之后（主线程）登记这次尝试归属
    private func rulerNoteWSResume(_ task: URLSessionWebSocketTask, at ns: UInt64) {
        guard ConnectRuler.enabled else { return }
        rulerWSAttemptSeq += 1
        rulerLastWS = (ObjectIdentifier(task), rulerWSAttemptSeq)
        let via = rulerProbeWinner.flatMap { $0.gen == probeGeneration ? $0.id : nil } ?? "direct"
        rulerProbeWinner = nil
        episode?.ruler?.noteWSResume(attempt: rulerWSAttemptSeq, gen: probeGeneration, via: via, at: ns, wall: Date())
    }

    /// 尺子：didOpen 过了 task === 守卫（主线程）
    private func rulerNoteOpen(_ task: URLSessionWebSocketTask, openNs: UInt64, openWall: Date, uiNs: UInt64, uiWall: Date) {
        episode?.ruler?.noteOpen(task: ObjectIdentifier(task), lastTask: rulerLastWS?.task, attempt: rulerLastWS?.attempt,
                                 currentGen: probeGeneration, wsOpenNs: openNs, wsOpenWall: openWall, uiNs: uiNs, uiWall: uiWall)
    }

    /// 终端第一屏画完（主线程，onInit 刚 feed 完）：拆段报给 hub 记账
    private func reportTerminalOpen(_ session: String, timing: (openedAt: Date, attachAt: Date), hubMs: Int?, hubSteps: String?) {
        let now = Date()
        let total = now.timeIntervalSince(timing.openedAt) * 1000
        let layout = timing.attachAt.timeIntervalSince(timing.openedAt) * 1000
        let bridge = lastOpenAt.map { max(0, $0.timeIntervalSince(timing.attachAt) * 1000) } ?? 0
        var frame: [String: Any] = [
            "type": "terminal_report", "session": session,
            "t0": Int(timing.openedAt.timeIntervalSince1970 * 1000), "open_at": Int(now.timeIntervalSince1970 * 1000),
            "total_ms": Int(total), "layout_ms": Int(layout), "bridge_ms": Int(bridge),
        ]
        if let hubMs { frame["hub_ms"] = hubMs }
        if let hubSteps { frame["hub_steps"] = hubSteps }
        BridgeProbe.log("terminal \(session) \(Int(total))ms\(total > 1000 ? " SLOW" : "") layout=\(Int(layout)) bridge=\(Int(bridge)) hub=\(hubMs.map(String.init) ?? "-") [\(hubSteps ?? "")]")
        send(frame) { _ in }
    }

    static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    /// 探测 / 握手失败归类（账本 attempts.r）
    static func attemptResult(_ err: Error?) -> String {
        guard let err = err as? URLError else { return err.map { "err:\(($0 as NSError).code)" } ?? "err:none" }
        switch err.code {
        case .timedOut: return "timeout"
        case .cannotConnectToHost: return "refused"
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed: return "unreachable"
        default: return "err:\(err.code.rawValue)"
        }
    }

    @ObservationIgnored private var wasBackgrounded = false
    @ObservationIgnored private var probeConnectedAt: Date?   // BridgeProbe：本次连上的时刻
    @ObservationIgnored private var probeReplyCount = 0       // BridgeProbe：本次连接收到的 reply 帧数（含补发）

    // MARK: - 焦点上报（TG 式推送：hub 据此判断你在不在看某会话 → 决定推不推）
    @ObservationIgnored private var reportedFocusChatId: String?   // ContentView 上报：当前在看哪个会话（对话页+选中）
    @ObservationIgnored private var isForeground = true            // 前后台（macOS 无概念，恒前台）
    @ObservationIgnored private var lastSentFocus: String? = nil   // 已发的 effective focus（""=null）；nil=没发过/需重发

    /// ContentView 在 iOSPage / selectedConversation 变化时调：上报当前在看哪个会话（nil=没在看）。
    func updateFocus(_ chatId: String?) {
        reportedFocusChatId = chatId
        sendEffectiveFocus()
    }

    /// 把 effective focus（前台才算在看）发给 hub，去重避免狂发。
    private func sendEffectiveFocus() {
        let effStr = (isForeground ? reportedFocusChatId : nil) ?? ""
        guard effStr != lastSentFocus else { return }
        lastSentFocus = effStr
        send(["type": "focus", "chat_id": effStr]) { _ in }
    }

    #if canImport(UIKit)
    @objc private func handleAppBackground() {
        BridgeProbe.log("background")
        if episode != nil, episode?.bgSince == nil { episode?.bgSince = Date() }
        wasBackgrounded = true
        isForeground = false
        sendEffectiveFocus()   // 尽力发 null（即便 socket 即将挂，hub 的 close 清理也会兜底）
        sendTerminalActive()
    }

    @objc private func handleAppWillEnterForeground() {
        willEnterForegroundAt = Date()
    }

    /// 从后台回前台：强制重连，让 hub 在新连接上 replay 后台期间漏掉的 reply（持久化去重防重复）。
    /// 只在真从后台回来时重连，避免每次 active 抖动都重连导致终端无谓闪。
    @objc private func handleAppForeground() {
        BridgeProbe.log("foreground wasBackgrounded=\(wasBackgrounded) connected=\(isConnected)")
        isForeground = true
        sendTerminalActive()
        if let since = episode?.bgSince { episode?.bgMs += Date().timeIntervalSince(since) * 1000; episode?.bgSince = nil }
        guard wasBackgrounded, !manualClose, url != nil else { return }
        wasBackgrounded = false
        // 账本：她感受到的等待从「即将进前台」算起，之前没连上的那段（含后台）不算这一段
        beginEpisode("foreground", at: willEnterForegroundAt ?? Date(), replace: true)
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectDelay = Self.minReconnectDelay
        startTask()   // 重连后 didOpen 会重报 focus
    }
    #endif

    /// T51（astra P1-5）：iOS 退后台 socket 还挂着、终端也不 detach，不告诉 hub 就会一直按手机的尺寸压窄 Mac。
    /// 老 hub 不认这帧 = 一直算 active，等于今天的行为。macOS 恒前台。
    private func sendTerminalActive() {
        send(["type": "terminal_active", "active": isForeground]) { _ in }
    }

    /// 断桥卡 / Mac 终端头部的「重新连接」（审计 T05）：不等退避（最长 30 秒），现在就重连。
    /// 已连上什么都不做（别把活连接掐了）；没有候选地址（从没配过对）也什么都不做。
    func reconnectNow() {
        guard !isConnected, !urls.isEmpty else { return }
        BridgeProbe.log("reconnect now")
        manualClose = false
        beginEpisode("manual")
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectDelay = Self.minReconnectDelay
        // 丢掉半死的 task：先摘引用，它晚到的 receive 失败 / didClose 被各自的 === 守卫挡掉，不会再排一轮退避
        let stale = task
        task = nil
        connectWatchdog?.invalidate()
        connectWatchdog = nil
        stale?.cancel(with: .goingAway, reason: nil)
        startTask()
    }

    /// 候选地址的主机名（「我的电脑」页判 LAN / Tailscale、断桥卡的 Tailscale 提示用）
    var candidateHosts: [String] { urls.compactMap(\.host) }
    /// 连过 / 配过地址（内嵌 hub 跟过的端口、扫码的候选）。有的话断线兜底只该 reconnectNow，别拿别的地址覆盖
    var hasCandidates: Bool { !urls.isEmpty }
    /// 有一次握手正在进行（task 在、还没 didOpen）
    var isConnecting: Bool { task != nil && !isConnected }
    /// 现在连着（或正在连）的那个地址的主机名
    var currentHost: String? { url?.host }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.handlePathUpdate(path) }
        }
        monitor.start(queue: DispatchQueue(label: "cc.bridge.path"))
        pathMonitor = monitor
    }

    /// 网络路径变了（连上 Wi-Fi / 切蜂窝 / 开关 VPN）→ 立刻重新竞速。没连上时省掉退避等待；
    /// 连着时老 socket 多半已经走不通（换网后 LAN 地址成黑洞），等 ping / 600s 超时太慢。
    private func handlePathUpdate(_ path: NWPath) {
        let signature = "\(path.status)|" + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
        let previous = lastPathSignature
        lastPathSignature = signature
        guard let previous, previous != signature else { return }
        BridgeProbe.log("path \(signature) connected=\(isConnected)")
        guard path.status == .satisfied, !manualClose, url != nil, !urls.isEmpty else { return }
        beginEpisode("path")
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectDelay = Self.minReconnectDelay
        startTask()
    }

    /// 持久化去重表（reply_id→时间戳，TTL 内）。在 handlersQueue 上调。
    private func persistSeenReplyIds() {
        dedupDefaults.set(seenReplyIds.mapValues { $0.timeIntervalSince1970 }, forKey: Self.seenStoreKey)
    }

    /// 持久化 thinking 去重表。在 handlersQueue 上调。
    private func persistSeenThinkingIds() {
        dedupDefaults.set(seenThinkingIds.mapValues { $0.timeIntervalSince1970 }, forKey: Self.seenThinkingStoreKey)
    }

    // MARK: - Public API

    /// 开始连接。重复 connect 同一个 URL（含 token）且已连接时是 no-op。
    func connect(url: URL, token: String? = nil, keepExistingToken: Bool = false) {
        connect(urls: [url], token: token, keepExistingToken: keepExistingToken)
    }

    /// 开始连接，支持多 URL fallback。优先连 urls[0]，失败 reconnect 时轮换到下一个。
    /// 典型用法：urls = [LAN URL, Tailscale URL]，在家走 LAN，出门走 Tailscale。
    /// keepExistingToken：后台 / 兜底调用点传 true——锁屏读不到口令（nil）时沿用当前同目标 URL 里的 token=，
    /// 别把带口令的候选换成不带口令的（#042：16:02 断线后重连全 auth failed）。设置页 / 扫码不传，清口令仍按不带口令连。
    func connect(urls inputURLs: [URL], token: String? = nil, keepExistingToken: Bool = false) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        // 严格测量角色：声明抑制（§3.1）。connect(url:) 也转到这里；url 保持 nil，回前台 / 重连都进不去
        if PerfHarness.quietNetwork { PerfGuardrails.suppress("ccws"); return }
        #endif
        let finalURLs = Self.candidateURLs(inputURLs, token: token, keepingTokenFrom: keepExistingToken ? urls : [])

        // L4 根因2：去重不能用数组全等——ChatService 传 [LAN]、ContentView 传 [LAN,Tailscale]，
        // 全等不成立就会绕过去重 → startTask → invalidateAndCancel 把刚连上的活 socket 掐死 → 1006 churn。
        // 改判语义：已连/连接中，且当前已连目标仍在新候选里 → 不重启，只更新 fallback 列表（保留 LAN+Tailscale）。
        if (isConnected || task != nil),
           let current = self.url,
           finalURLs.contains(where: { Self.normalizedKey($0) == Self.normalizedKey(current) }) {
            self.urls = finalURLs       // 保留/刷新 fallback 候选，但不掐活连接
            return
        }
        manualClose = false
        self.urls = finalURLs
        self.url = finalURLs.first
        // 换目标：手上那份 hello 只能算「上次连的电脑」，旧连接的在途请求也不再认（astra 实现审 #3 / #11）
        hubInfoIsCurrent = false
        failHubRequests()
        beginEpisode("connect")
        startTask()
    }

    /// URL 归一化比较键：scheme+host+port+path，忽略 token query 和顺序。
    /// 同一服务器即使 token query 不同也算同一目标，避免无谓重连。
    private static func normalizedKey(_ url: URL) -> String {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let scheme = c.scheme ?? ""
        let host = c.host ?? ""
        let port = c.port.map(String.init) ?? ""
        let path = c.path
        return "\(scheme)://\(host):\(port)\(path)"
    }

    /// 组候选 URL（带 token= / bundle=）。token 为空且 existing 非空时，沿用 existing 里同目标 URL 已带的 token。
    static func candidateURLs(_ inputURLs: [URL], token: String?, keepingTokenFrom existing: [URL]) -> [URL] {
        var token = token
        if token?.isEmpty ?? true, !existing.isEmpty {
            let targets = Set(inputURLs.map(normalizedKey))
            token = existing.lazy.filter { targets.contains(normalizedKey($0)) }
                .compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value }
                .first { !$0.isEmpty }
            if token != nil { callLog.notice("hub 口令读不到，沿用已有口令") }
        }
        return inputURLs.map { url -> URL in
            guard let token, !token.isEmpty,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url
            }
            var items = components.queryItems ?? []
            items.removeAll(where: { $0.name == "token" || $0.name == "bundle" })  // 避免重复 token= / bundle=
            items.append(URLQueryItem(name: "token", value: token))
            // hub 设了 MP_CC_ALLOWED_BUNDLES 时只放行名单里的 app（别人的包拿到口令也连不上）
            if let bundle = Bundle.main.bundleIdentifier { items.append(URLQueryItem(name: "bundle", value: bundle)) }
            components.queryItems = items
            return components.url ?? url
        }
    }

    /// 手动断开，禁用自动重连。
    func disconnect() {
        manualClose = true
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        pingTimer?.invalidate()
        pingTimer = nil
        connectWatchdog?.invalidate()
        connectWatchdog = nil
        probeGeneration += 1                  // 作废在途竞速探测
        probeSession?.invalidateAndCancel()
        probeSession = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        failHubRequests()
        // disconnect() 默认来自主线程 UI；直接同步更新，避免 stale window
        // task 已摘掉，之后的 handleDisconnect 会提前 return，current 标志得在这里落（astra 实现审 #11）
        if Thread.isMainThread {
            isConnected = false
            hubInfoIsCurrent = false
        } else {
            DispatchQueue.main.sync { self.isConnected = false; self.hubInfoIsCurrent = false }
        }
    }

    /// JSON 序列化后以文本帧发出。

    /// 问问题 CC 桥：答案帧（answers 按题序 [{indices:[Int]}|{text:String}]）；skip=true 整卡跳过（hub 发 Esc）。
    func sendAskUserAnswer(toolUseId: String, answers: [[String: Any]]?, skip: Bool = false) {
        var frame: [String: Any] = ["type": "ask_user_answer", "tool_use_id": toolUseId]
        if skip { frame["skip"] = true } else if let answers { frame["answers"] = answers }
        send(frame) { _ in }
    }

    func send(_ payload: [String: Any], completion: @escaping (Error?) -> Void) {
        guard let task else {
            completion(NSError(domain: "CCBridge", code: -10,
                               userInfo: [NSLocalizedDescriptionKey: "WebSocket 未连接"]))
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let str = String(data: data, encoding: .utf8) else {
                completion(NSError(domain: "CCBridge", code: -11,
                                   userInfo: [NSLocalizedDescriptionKey: "payload 编码失败"]))
                return
            }
            task.send(.string(str)) { err in
                completion(err)
            }
        } catch {
            completion(error)
        }
    }

    // MARK: - L2: spawn / list sessions

    /// 让 hub 在远端 tmux 起一个新 CC session（不 --continue）。
    /// 完成回调走 main queue。注意：CC 启动需要 ~3-5s，hub 是否成功 spawn 只看
    /// tmux new-session 是否成功；CC 本身起没起 / mcp-server 连没连这里不验证。
    func spawnSession(_ name: String, completion: @escaping (Result<Void, CCBridgeRemoteError>) -> Void) {
        handlersQueue.async {
            // 同名覆盖：旧回调先按失败收掉，别让它永远挂着（astra P1-6）
            if let superseded = self.spawnHandlers[name] {
                DispatchQueue.main.async { superseded(.failure(CCBridgeRemoteError(reason: "superseded"))) }
            }
            self.spawnHandlers[name] = completion
        }
        let payload: [String: Any] = ["type": "spawn_cc", "session_name": name]
        send(payload) { [weak self] err in
            guard let self, let err else { return }
            // send 即失败 → 立即 fail，不等 hub 回包
            self.handlersQueue.async {
                if let h = self.spawnHandlers.removeValue(forKey: name) {
                    DispatchQueue.main.async { h(.failure(CCBridgeRemoteError(reason: err.localizedDescription))) }
                }
            }
        }
    }

    /// 用户消息直发（收口即发，plan-跨对话排队）：发一帧 send 就结束，不注册 reply handler。
    /// 回复由 hub 推回，无 handler 时走 proactive 路径落地（查重/未读/上树全复用）。
    /// send err 不上抛——iPhone 连接抖动时 err 但 hub 大概率已收到，hub replay 兜底（沿旧 CCBridgeProvider 语义）。
    func sendUserMessage(
        chatId: String, messageId: String, content: String, user: String,
        session: String?, replyTo: String?, attachments: [PendingChatAttachment], effort: String? = nil
    ) {
        let payload = Self.sendFrame(chatId: chatId, messageId: messageId, content: content, user: user,
                                     session: session, replyTo: replyTo, attachments: attachments, effort: effort)
        sendTracker.didSend(messageId, frame: payload)   // 调用方在 main（sendCCFireAndForget）
        send(payload) { err in
            if let err {
                #if DEBUG
                print("[CCBridge] send err（hub replay 兜底）: \(err.localizedDescription)")
                #endif
            }
        }
    }

    /// 「没送达」点重发（K1 第 4b 步）：原 send 帧 + retry，message_id 不变；标记先回到「确认中」，等 hub 再推 send_status。
    /// 交不给 WS（没连上）就立刻落回 failed。main 上调。
    func retrySend(messageId: String) {
        guard let frame = sendTracker.beginRetry(messageId) else { return }
        send(frame) { [weak self] err in
            guard err != nil else { return }
            DispatchQueue.main.async { self?.sendTracker.retryNotSent(messageId) }
        }
    }

    /// 重发帧（纯函数，单测可直接验）：原 send 帧原样 + `"retry": true`
    static func retryFrame(from sendFrame: [String: Any]) -> [String: Any] {
        var frame = sendFrame
        frame["retry"] = true
        return frame
    }

    /// send 帧（纯函数，单测可直接验）
    static func sendFrame(
        chatId: String, messageId: String, content: String, user: String,
        session: String?, replyTo: String?, attachments: [PendingChatAttachment], effort: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "type":       "send",
            "chat_id":    chatId,
            "message_id": messageId,
            "content":    content,
            "user":       user,
        ]
        if let session, !session.isEmpty { payload["session_name"] = session }
        if let replyTo, !replyTo.isEmpty { payload["reply_to"] = replyTo }
        // 思考强度（research-reasoning-effort §2.3）：「默认」不带，hub 不动会话
        if let effort, effort != ReasoningEffort.auto { payload["effort"] = effort }
        // C2：当前消息的图 + 文件 base64 进 send 帧（hub 落盘 mp-inbox 让 CC Read/处理真文件）
        let imgPayload: [[String: Any]] = attachments.compactMap { att in
            guard att.isImage, let data = att.imageData, let mime = att.mimeType,
                  data.count <= 10 * 1024 * 1024 else { return nil }
            return ["name": att.name, "mime": mime, "b64": data.base64EncodedString()]
        }
        if !imgPayload.isEmpty { payload["images"] = imgPayload }
        let filePayload: [[String: Any]] = attachments.compactMap { att in
            guard att.isFile, let data = att.fileData, data.count <= 25 * 1024 * 1024 else { return nil }
            return ["name": att.name, "mime": att.mimeType ?? "application/octet-stream", "b64": data.base64EncodedString()]
        }
        if !filePayload.isEmpty { payload["files"] = filePayload }
        return payload
    }

    /// L3: 给 CC 发斜杠命令（fire-and-forget — completion 只反映"hub 收没收到"）。
    /// CC 自身的响应（如 /clear 后清 UI / /cost 显示 token）在 tmux 渲染，
    /// MP 端不接 reply（CC 命令不调 MCP reply tool）。
    func sendCommand(_ content: String, session: String? = nil,
                     completion: @escaping (Result<Void, CCBridgeRemoteError>) -> Void) {
        var payload: [String: Any] = ["type": "command", "content": content]
        if let session, !session.isEmpty { payload["session_name"] = session }
        send(payload) { err in
            DispatchQueue.main.async {
                if let err {
                    completion(.failure(CCBridgeRemoteError(reason: err.localizedDescription)))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    // MARK: - L4: terminal stream

    /// 订阅某 session 的 tmux pane 流。
    /// onInit 在 attach 时收到初始 ANSI snapshot（视作 reset 信号 → 用于完整 feed）+ `mouse_any`
    /// （窗口里的程序开没开鼠标上报；老 hub 不发这字段时是 nil，调用方按老前缀规则兜底）。
    /// onChunk 后续增量字节。onError 任何错误（session 不存在 / attach failed / send-keys 失败）。
    /// 所有回调在 main queue。
    ///
    /// cols/rows：**必传**。MP 端 SwiftTerm viewport 大小；hub 收到后先 tmux resize-window
    /// 让 pane 跟 MP 同步，再 capture-pane snapshot。否则 snapshot 里 cursor 坐标按
    /// tmux 默认 80x24，iPhone 上小 viewport 一渲染就溢出叠字符。
    func attachTerminal(
        session: String,
        cols: Int,
        rows: Int,
        onInit: @escaping (Data, Bool?) -> Void,
        onChunk: @escaping (Data) -> Void,
        onError: @escaping (String) -> Void,
        onUsage: ((TerminalUsage) -> Void)? = nil,
        onSent: ((Bool) -> Void)? = nil,
        openedAt: Date? = nil
    ) {
        let attachAt = Date()
        handlersQueue.async {
            self.terminalInitHandlers[session] = onInit
            self.terminalChunkHandlers[session] = onChunk
            self.terminalErrorHandlers[session] = onError
            self.terminalUsageHandlers[session] = onUsage
            self.terminalAttachParams[session] = (cols, rows)
            if let openedAt { self.terminalOpenTiming[session] = (openedAt, attachAt) }
            self.sendAttachOnQueue(session: session, cols: cols, rows: rows, onSent: onSent)
        }
    }

    /// 发 terminal_attach 并记下交给了哪个 task（见 `attachSentOnTask`）。只在 handlersQueue 上调。
    /// onSent（main）：true = 交给 WS 了（不代表 hub 收到），false = 没连上发不出去——后者 didOpen 会自动补发。
    private func sendAttachOnQueue(session: String, cols: Int, rows: Int, onSent: ((Bool) -> Void)? = nil) {
        let sentTask = task
        if let sentTask { attachSentOnTask[session] = sentTask } else { attachSentOnTask.removeValue(forKey: session) }
        send([
            "type": "terminal_attach",
            "session_name": session,
            "cols": cols,
            "rows": rows,
        ]) { [weak self] err in
            if err != nil {
                self?.handlersQueue.async {
                    guard let self, let sentTask, self.attachSentOnTask[session] === sentTask else { return }
                    self.attachSentOnTask.removeValue(forKey: session)
                }
            }
            if let onSent { DispatchQueue.main.async { onSent(err == nil) } }
        }
    }

    /// 取消订阅；hub 端最后一个 client 离开会自动关 pipe-pane + 清理 fifo。
    func detachTerminal(session: String) {
        handlersQueue.async {
            self.terminalInitHandlers.removeValue(forKey: session)
            self.terminalChunkHandlers.removeValue(forKey: session)
            self.terminalErrorHandlers.removeValue(forKey: session)
            self.terminalUsageHandlers.removeValue(forKey: session)
            self.terminalAttachParams.removeValue(forKey: session)
            self.attachSentOnTask.removeValue(forKey: session)
            self.terminalOpenTiming.removeValue(forKey: session)
            // 跟 attach / resize 同在 handlersQueue 上发：排在它前面的 resize 不会晚于 detach 到 hub
            self.send(["type": "terminal_detach", "session_name": session]) { _ in }
        }
    }

    /// 刷新重绘：用存的 cols/rows 重发 terminal_attach → hub 重新 capture-pane 发 terminal_init
    /// → onInit `ESC c` + feed 干净重绘（治客户端渲染脏/乱码，不打扰 CC 进程）。
    func refreshTerminal(session: String) {
        handlersQueue.async {
            guard let p = self.terminalAttachParams[session] else { return }
            self.sendAttachOnQueue(session: session, cols: p.cols, rows: p.rows)
        }
    }

    /// 这个终端真显示在前台了：hub 把它的「跑完了」标成已读（done → idle）。attach / 重订阅不算看过。
    func sendTerminalSeen(session: String) {
        send(["type": "terminal_seen", "session_name": session]) { _ in }
    }

    /// hub 单帧 terminal_input 上限：超了整帧扔掉（hub.ts terminal_input 分支，#053 T26）
    static let terminalInputChunkLimit = 4096

    /// 按 ≤limit 字节切片，切点退到 UTF-8 字符开头（不落在 10xxxxxx 续字节上）。
    /// hub 是逐字节 send-keys -H，切在哪都不坏；退到字符边界只是不赌 tmux 跨调用拼半个汉字。
    static func terminalInputChunks(_ bytes: Data, limit: Int = terminalInputChunkLimit) -> [Data] {
        let b = [UInt8](bytes)
        var chunks: [Data] = []
        var start = 0
        while start < b.count {
            var end = min(start + limit, b.count)
            if end < b.count {
                var cut = end
                while cut > start, b[cut] & 0xC0 == 0x80 { cut -= 1 }
                if cut > start { end = cut }
            }
            chunks.append(Data(b[start..<end]))
            start = end
        }
        return chunks
    }

    /// 发 keystroke 字节给 CC（hub 端 tmux send-keys -H hex）。支持任意 ANSI 序列。
    /// 超过 4096 字节按片顺序发（同一条 WS，hub 按到达顺序处理）。
    /// completion（main）：所有片都交给 WS 了才回 nil，任一片失败回第一个错误。不代表 hub 收到。
    func sendTerminalInput(session: String, bytes: Data, completion: ((Error?) -> Void)? = nil) {
        let chunks = Self.terminalInputChunks(bytes)
        guard !chunks.isEmpty else {
            if let completion { DispatchQueue.main.async { completion(nil) } }
            return
        }
        let lock = NSLock()
        var remaining = chunks.count
        var firstError: Error?
        for chunk in chunks {
            send([
                "type": "terminal_input",
                "session_name": session,
                "bytes": chunk.base64EncodedString(),
            ]) { err in
                lock.lock()
                if let err, firstError == nil { firstError = err }
                remaining -= 1
                let done = remaining == 0
                let result = firstError
                lock.unlock()
                if done, let completion { DispatchQueue.main.async { completion(result) } }
            }
        }
    }

    /// 粘贴（#053 T27）：hub 用 tmux paste-buffer -p 送进 pane —— pane 开了 bracketed paste 才包
    /// ESC[200~…ESC[201~，没有 4096 的线。调用前看 `hubSupportsTerminalPaste`。
    /// completion（main）：nil = hub 确认贴进去了；否则一句给她看的原因（含 10 秒没回包）。
    func sendTerminalPaste(session: String, text: String, completion: @escaping (String?) -> Void) {
        let requestId = UUID().uuidString
        handlersQueue.async { self.terminalPasteHandlers[requestId] = completion }
        send([
            "type": "terminal_paste",
            "session_name": session,
            "text": text,
            "request_id": requestId,
        ]) { [weak self] err in
            guard let err else { return }
            self?.finishTerminalPaste(requestId, failure: "没发出去：\(err.localizedDescription)")
        }
        // 超时 ≠ 没贴进去：hub 可能贴完了只是回包没到，所以话要说成「不确定」
        handlersQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.finishTerminalPaste(requestId, failure: "电脑 10 秒没回话，可能已经贴进去了，看一眼终端")
        }
    }

    private func finishTerminalPaste(_ requestId: String, failure: String?) {
        handlersQueue.async {
            guard let h = self.terminalPasteHandlers.removeValue(forKey: requestId) else { return }
            DispatchQueue.main.async { h(failure) }
        }
    }

    /// 通知 hub 把 tmux pane resize 到 MP 视口对应大小。
    /// 只给订阅着的 session 发：已 detach / 还没 attach 的不发也不记尺寸——迟到的 resize 会让 hub 把离开的设备
    /// 重新算进尺寸表、压窄别的设备，也不能凭它重建订阅参数（astra 实现审 #2）。
    func sendTerminalResize(session: String, cols: Int, rows: Int) {
        handlersQueue.async {
            guard self.terminalAttachParams[session] != nil else { return }
            self.terminalAttachParams[session] = (cols, rows)
            self.send([
                "type": "terminal_resize",
                "session_name": session,
                "cols": cols,
                "rows": rows,
            ]) { _ in }
        }
    }

    /// 拉 hub 端当前 tmux mp-cc* sessions 列表。完成回调走 main queue。
    func listSessions(completion: @escaping (Result<[String], CCBridgeRemoteError>) -> Void) {
        handlersQueue.async { self.listHandlers.append(completion) }
        let payload: [String: Any] = ["type": "list_sessions"]
        send(payload) { [weak self] err in
            guard let self, let err else { return }
            self.handlersQueue.async {
                let hs = self.listHandlers
                self.listHandlers.removeAll()
                for h in hs {
                    DispatchQueue.main.async { h(.failure(CCBridgeRemoteError(reason: err.localizedDescription))) }
                }
            }
        }
    }

    // MARK: - 全局终端窗口
    //
    // 跟 list_sessions 是两条独立的链：那条给 CC 会话选择器用（只列对话绑定的 CC session），
    // 这条给终端页导航用（只列全局窗口）。故意不合并 —— 合了 shell 窗口就会混进选择器。

    func listWindows(
        includeClosed: Bool = false,
        completion: @escaping (Result<[TerminalWindowInfo], CCBridgeRemoteError>) -> Void
    ) {
        handlersQueue.async { self.windowListHandlers.append(completion) }
        send(["type": "list_windows", "include_closed": includeClosed]) { [weak self] err in
            guard let self, let err else { return }
            self.flushWindowList(.failure(CCBridgeRemoteError(reason: err.localizedDescription)))
        }
    }

    /// 开一个新窗口，回调给出它的 code。
    /// `engine`：`claude` / `codex` / 不传 = 裸 shell（老 hub 不认识这个字段，不传就还是老行为）。
    func openWindow(engine: String? = nil,
                    completion: @escaping (Result<String, CCBridgeRemoteError>) -> Void) {
        handlersQueue.async { self.windowOpenHandlers.append(completion) }
        var payload: [String: Any] = ["type": "open_window"]
        if let engine { payload["engine"] = engine }
        send(payload) { [weak self] err in
            guard let self, let err else { return }
            self.flushWindowOpen(.failure(CCBridgeRemoteError(reason: err.localizedDescription)))
        }
    }

    /// 手动改名：hub 把它存进窗口注册表的 customTitle，之后 `terminal_state` 帧里的 title 就是它
    /// （标题链最高优先级，plan §A3）。无回调 —— 下一帧就是回执。
    func renameWindow(code: String, title: String) {
        send(["type": "rename_window", "code": code, "title": title]) { _ in }
    }

    /// 关闭 = 从导航收起来。hub 侧只打 closedAt 标记，**tmux session 不动**。
    /// 无回调：store 乐观更新，下一轮 60s 对账会以 hub 为准修正。
    func closeWindow(code: String) {
        send(["type": "close_window", "code": code]) { _ in }
    }

    func restoreWindow(code: String, completion: @escaping (Result<String, CCBridgeRemoteError>) -> Void) {
        handlersQueue.async { self.windowRestoreHandlers.append(completion) }
        send(["type": "restore_window", "code": code]) { [weak self] err in
            guard let self, let err else { return }
            self.flushWindowRestore(.failure(CCBridgeRemoteError(reason: err.localizedDescription)))
        }
    }

    /// 结束 = hub 真 kill tmux + 注册表标 ended，之后列表 / 恢复菜单都不再有它。
    /// completion 恰好调一次（main queue）：hub 回音 / 5 秒超时（老 hub 不认这帧）/ 发不出去或断连，谁先到算谁，迟到的丢掉。
    func endWindow(code: String, completion: @escaping (Result<Void, TerminalWindowEndError>) -> Void) {
        let id = UUID()
        handlersQueue.async {
            self.windowEndHandlers[code, default: [:]][id] = completion
            self.handlersQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.finishWindowEnd(code: code, id: id, .failure(.timedOut))
            }
        }
        send(["type": "end_window", "code": code]) { [weak self] err in
            guard let self, err != nil else { return }
            self.handlersQueue.async { self.finishWindowEnd(code: code, id: id, .failure(.offline)) }
        }
    }

    // MARK: - 电脑的目录（#046 T3）

    /// 拉一次 hub 的目录配置，回帧 `hub_config` 合进 `hubInfo`。老 hub 不认 = 没回音，无害。
    /// 带 request_id 只为跟 set / list 一个契约：不登记回调，回帧只刷新显示。
    func requestHubConfig() {
        send(["type": "get_hub_config", "request_id": UUID().uuidString]) { _ in }
    }

    /// 改 [+] 新窗口用的干活目录；空串 = 恢复成家。completion（main）：nil 成功，否则一句中文原因。
    /// 成功后 hub 会广播新 hello，`hubInfo` 跟着变。
    func setAgentWorkdir(_ path: String, completion: @escaping (String?) -> Void) {
        let id = UUID().uuidString
        handlersQueue.async {
            self.hubConfigHandlers.add(id, completion)
            self.handlersQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.finishHubConfig(id: id, "电脑 10 秒没回话（hub 可能需要更新）")
            }
        }
        send(["type": "set_agent_workdir", "path": path, "request_id": id]) { [weak self] err in
            guard let self, let err else { return }
            self.handlersQueue.async { self.finishHubConfig(id: id, "没发出去：\(err.localizedDescription)") }
        }
    }

    /// 列电脑上一层子文件夹；path 为 nil = 家目录（~）。completion 在 main。
    func listDirs(path: String?, completion: @escaping (Result<HubDirListing, CCBridgeRemoteError>) -> Void) {
        let id = UUID().uuidString
        handlersQueue.async {
            self.dirListHandlers.add(id, completion)
            self.handlersQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.finishDirList(id: id, .failure(CCBridgeRemoteError(reason: "电脑 10 秒没回话（hub 可能需要更新）")))
            }
        }
        var payload: [String: Any] = ["type": "list_dirs", "request_id": id]
        if let path { payload["path"] = path }
        send(payload) { [weak self] err in
            guard let self, let err else { return }
            self.handlersQueue.async {
                self.finishDirList(id: id, .failure(CCBridgeRemoteError(reason: "没发出去：\(err.localizedDescription)")))
            }
        }
    }

    /// 只在 handlersQueue 上调。已被别的一路收走（超时 / 断线 / 回帧）就什么都不做。
    private func finishHubConfig(id: String?, _ failure: String?) {
        guard let h = hubConfigHandlers.take(id) else { return }
        DispatchQueue.main.async { h(failure) }
    }

    private func finishDirList(id: String?, _ result: Result<HubDirListing, CCBridgeRemoteError>) {
        guard let h = dirListHandlers.take(id) else { return }
        DispatchQueue.main.async { h(result) }
    }

    /// 连接断了 / 换了 / 手动断开：在途的配置、目录请求一律按失败收掉，旧连接的回帧之后来了也认不出来。
    /// 在发起换连接的线程上、新 task 生效之前调（同在 handlersQueue 排队，排在之后新请求的登记前面）。
    private func failHubRequests() {
        handlersQueue.async { [weak self] in
            guard let self else { return }
            let reason = "连接断了，没等到电脑回话"
            let configs = self.hubConfigHandlers.takeAll()
            let listings = self.dirListHandlers.takeAll()
            DispatchQueue.main.async {
                for h in configs { h(reason) }
                for h in listings { h(.failure(CCBridgeRemoteError(reason: reason))) }
            }
        }
    }

    private func flushWindowList(_ result: Result<[TerminalWindowInfo], CCBridgeRemoteError>) {
        handlersQueue.async { [weak self] in
            guard let self else { return }
            let hs = self.windowListHandlers
            self.windowListHandlers.removeAll()
            for h in hs { DispatchQueue.main.async { h(result) } }
        }
    }

    private func flushWindowOpen(_ result: Result<String, CCBridgeRemoteError>) {
        handlersQueue.async { [weak self] in
            guard let self else { return }
            let hs = self.windowOpenHandlers
            self.windowOpenHandlers.removeAll()
            for h in hs { DispatchQueue.main.async { h(result) } }
        }
    }

    private func flushWindowRestore(_ result: Result<String, CCBridgeRemoteError>) {
        handlersQueue.async { [weak self] in
            guard let self else { return }
            let hs = self.windowRestoreHandlers
            self.windowRestoreHandlers.removeAll()
            for h in hs { DispatchQueue.main.async { h(result) } }
        }
    }

    private func flushWindowEnd(code: String, _ result: Result<Void, TerminalWindowEndError>) {
        handlersQueue.async { [weak self] in
            guard let self else { return }
            let hs = self.windowEndHandlers.removeValue(forKey: code) ?? [:]
            for h in hs.values { DispatchQueue.main.async { h(result) } }
        }
    }

    /// 只在 handlersQueue 上调。已经被别的一路收走了就什么都不做。
    private func finishWindowEnd(code: String, id: UUID, _ result: Result<Void, TerminalWindowEndError>) {
        guard let h = windowEndHandlers[code]?.removeValue(forKey: id) else { return }
        if windowEndHandlers[code]?.isEmpty == true { windowEndHandlers.removeValue(forKey: code) }
        DispatchQueue.main.async { h(result) }
    }

    private func failWindowEnds() {
        handlersQueue.async { [weak self] in
            guard let self else { return }
            let hs = self.windowEndHandlers.values.flatMap(\.values)
            self.windowEndHandlers.removeAll()
            for h in hs { DispatchQueue.main.async { h(.failure(.offline)) } }
        }
    }

    // MARK: - Internal

    /// 连接入口：多候选时并发竞速探测 /health，谁先 200 连谁——在家 LAN 毫秒胜出、
    /// 在外 Tailscale 胜出，换网零手动切换。旧轮换制是串行的：死候选要等满超时才轮下一个，
    /// 换 WiFi 后体感就是"卡住/连不上"。全败走 scheduleReconnect 退避重试（下轮再全体竞速）。
    private func startTask() {
        if TestHostIsolation.blocks(.hub) { return }   // #035：测试宿主不连 hub（生产 hub 严禁测试流量）
        BridgeProbe.log("connect try")
        guard !urls.isEmpty else { return }
        probeSession?.invalidateAndCancel()
        probeGeneration += 1
        // 单候选：省一跳 probe RTT 直连，黑洞由 connect 看门狗兜底
        guard urls.count > 1 else {
            url = urls[0]
            openSocket()
            return
        }
        let gen = probeGeneration
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.probeTimeout
        config.connectionProxyDictionary = [:]   // 不走系统 HTTP 代理（LAN / Tailscale 地址本来就该直连）
        let timings = ConnectRuler.enabled ? ProbeRoundTimings() : nil   // 尺子：每候选 resume 时刻 + URLSessionTaskMetrics
        let probe = URLSession(configuration: config, delegate: CCBridgeProbeDelegate(onMetrics: timings?.noteMetrics), delegateQueue: nil)   // 不跟重定向 + 中继 pin
        probeSession = probe
        var settled = false      // 都在 main queue 串行访问
        var failures = 0
        var failReasons: [String] = []
        let total = urls.count
        let probeStart = Date()
        let relayKey = CCBridgeEndpoints.relayURL().map(Self.normalizedKey)   // 只有扫码存的中继走严格判活
        for (slot, candidate) in urls.enumerated() {
            let fail: (String) -> Void = { [weak self] reason in
                guard let self, gen == self.probeGeneration else { return }
                failures += 1
                failReasons.append(reason)
                if failures == total, !settled {
                    settled = true
                    probe.finishTasksAndInvalidate()   // 带 delegate 的 session 不失效会一直持有 delegate
                    self.probeSession = nil
                    self.lastError = "探测全败：" + failReasons.joined(separator: "；")
                    BridgeProbe.log("probe all failed: " + failReasons.joined(separator: " | "))
                    if !self.manualClose { self.scheduleReconnect() }
                }
            }
            guard let healthURL = Self.healthURL(for: candidate) else {
                DispatchQueue.main.async { fail("候选 URL 非法") }
                continue
            }
            let label = "\(healthURL.host ?? "?"):\(healthURL.port ?? 7890)"
            let dataTask = probe.dataTask(with: healthURL) { _, resp, err in
                let callbackAt = Date()
                let callbackNs = ConnectRuler.stamp()
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.probeGeneration else { return }
                    let enterNs = ConnectRuler.stamp()
                    let late = settled
                    var won = false
                    defer {
                        if let timings { self.episode?.ruler?.noteCandidate(ConnectCandidateRecord(host: healthURL.host ?? "?", resumeNs: timings.resumeNs(slot: slot),
                            callbackNs: callbackNs, enterNs: enterNs, endNs: ConnectClock.nowNs(), won: won, late: late, timings: timings, gen: gen, slot: slot)) }
                    }
                    self.noteMainDelay(since: callbackAt)
                    if settled { return }   // 已有候选胜出，其余（多半是被撤掉的 cancelled）不记账
                    // 判活标准见 isHubProbeResponse：认 hub 的 x-mp-hub 头，手机代理替不通地址回的 502 不算活。
                    if err == nil, let http = resp as? HTTPURLResponse, Self.isHubProbeResponse(http, strict: Self.normalizedKey(candidate) == relayKey) {
                        guard !settled else { return }
                        settled = true
                        won = true
                        if timings != nil { self.rulerProbeWinner = (gen, "\(gen).\(slot)") }
                        self.recordAttempt(host: healthURL.host, result: "ok", since: probeStart)
                        probe.invalidateAndCancel()   // 撤掉其余在途探测
                        self.probeSession = nil
                        self.url = candidate
                        self.openSocket()
                    } else if let http = resp as? HTTPURLResponse {
                        self.recordAttempt(host: healthURL.host, result: "nothub:\(http.statusCode)", since: probeStart)
                        fail("\(label) 不是 hub（HTTP \(http.statusCode)，疑似代理替答）")
                    } else {
                        self.recordAttempt(host: healthURL.host, result: Self.attemptResult(err), since: probeStart)
                        fail("\(label) \(err?.localizedDescription ?? "无 HTTP 响应")")
                    }
                }
            }
            timings?.register(slot: slot, taskId: dataTask.taskIdentifier)   // metrics 可能早于下面记 resume 到，映射先登记
            let resumeNs = ConnectRuler.stamp()
            dataTask.resume()
            if let timings { timings.noteResume(slot: slot, at: resumeNs); episode?.ruler?.noteRequest(at: resumeNs, wall: Date()) }
        }
    }

    /// 探测回应是不是 hub 本尊。hub 的 /health 对非 loopback 有意回 403（信息收紧），403 恰恰证明 hub 活着；
    /// 新 hub 所有回应带 x-mp-hub 头。手机开着代理 VPN 时，代理会替连不通的地址（Tailscale 100.x）几毫秒
    /// 回 502——旧规则「任何状态码都算活」被它骗去连死地址（bridge-probe.log 105 次 bad response）。
    /// 兼容老 hub：没头但 200/401/403 也算；其余一律不算。⚠️ 只认 200 会把 LAN 候选全误杀。
    /// strict（候选是扫码存的自建中继）：必须带 x-mp-hub——中继自己的 503/504 不带，Mac 不在线时不会被当成活（#068）。
    /// 手填的普通 wss hub 地址照旧走兼容规则。
    static func isHubProbeResponse(_ http: HTTPURLResponse, strict: Bool = false) -> Bool {
        if http.value(forHTTPHeaderField: "x-mp-hub") != nil { return true }
        return !strict && [200, 401, 403].contains(http.statusCode)
    }

    /// 连接 URL 带上 since=（收到过的最大 ts 减余量）；没收过就不带 = hub 全量补发
    static func urlWithReplySince(_ url: URL, cursor: Double, marginMs: Double) -> URL {
        guard cursor > marginMs, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (c.queryItems ?? []).filter { $0.name != "since" }
        items.append(URLQueryItem(name: "since", value: String(Int64(cursor - marginMs))))
        c.queryItems = items
        return c.url ?? url
    }

    /// 主线程：reply / thinking 落地后推进游标
    private func advanceReplyCursor(_ ts: Double?) {
        guard let ts, ts > replyCursor else { return }
        replyCursor = ts
        dedupDefaults.set(ts, forKey: Self.replyCursorKey)
    }

    /// ws://host:port/cc?token=xx → http://host:port/health（probe 用；/health 无鉴权无副作用）
    static func healthURL(for wsURL: URL) -> URL? {
        guard var c = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = (c.scheme == "wss") ? "https" : "http"
        c.path = "/health"
        c.queryItems = nil
        return c.url
    }

    private func openSocket() {
        guard let url else { return }
        session?.invalidateAndCancel()  // 释放旧 session（避免 reconnect 累积资源）
        // L4 P0a：iOS URLSessionConfiguration 默认 timeoutIntervalForRequest=60s
        // 连接 idle 超 60s（5s ping 在 .tracking RunLoop mode 下可能跳票）→
        // iOS 主动断 1006 → 反复 attach race 显示乱码。给 10 分钟缓冲。
        // L4 根因3：timeoutIntervalForResource 是「整个 task 生命周期上限」，对长连 WS 是 footgun
        //   —— 设 600 会让 socket 每 ~10 分钟被系统硬杀。WS 保活靠 ping，这里用默认（7 天），不设。
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.connectionProxyDictionary = [:]   // 跟竞速探测同一条路：直连，不经系统 HTTP 代理
        failHubRequests()   // 旧 task 要被换掉了：它上面的在途请求等不到回帧（见 receiveLoop 的 === 守卫）
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: Self.urlWithReplySince(url, cursor: replyCursor, marginMs: Self.replyCursorMarginMs))
        // 研报帧可带财报 PDF base64（实测 4.8MB），默认 1MB 单帧上限会 1009 断连
        // → 永不 ack → hub 补投 → 重连死循环（2026-08-03 事故）
        task.maximumMessageSize = 64 << 20
        self.task = task
        let wsResumeNs = ConnectRuler.stamp()
        task.resume()
        rulerNoteWSResume(task, at: wsResumeNs)
        receiveLoop()
        startConnectWatchdog(for: task)
    }

    private func startConnectWatchdog(for armedTask: URLSessionWebSocketTask) {
        connectWatchdog?.invalidate()
        // 学 pingTimer：.common mode 防 SwiftUI scroll 时 .tracking RunLoop 跳票
        let timer = Timer(timeInterval: Self.connectTimeout, repeats: false) { [weak self] _ in
            guard let self, self.task === armedTask, !self.isConnected else { return }
            armedTask.cancel(with: .goingAway, reason: nil)
            self.handleDisconnect(error: "connect timeout")
        }
        RunLoop.main.add(timer, forMode: .common)
        connectWatchdog = timer
    }

    private func receiveLoop() {
        guard let currentTask = task else { return }
        currentTask.receive { [weak self] result in
            // 旧 task 完成后 self.task 已被替换，直接忽略以免触发 ghost reconnect
            guard let self, self.task === currentTask else { return }
            switch result {
            case .failure(let err):
                self.handleDisconnect(error: err.localizedDescription)
            case .success(.string(let text)):
                self.handleIncoming(text)
                self.receiveLoop()
            case .success(.data(let data)):
                if let text = String(data: data, encoding: .utf8) {
                    self.handleIncoming(text)
                }
                self.receiveLoop()
            @unknown default:
                self.receiveLoop()
            }
        }
    }

    func handleIncoming(_ text: String) {   // internal：CCBridgeReplyDedupOrderTests 直接喂帧
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "cc_memory_manifest":
            DispatchQueue.main.async { CCMemorySync.handleManifest(obj) }
        case "cc_memory_files":
            DispatchQueue.main.async { CCMemorySync.handleFiles(obj) }
        case "cc_memory_changed":
            DispatchQueue.main.async { CCMemorySync.requestManifest() }
        case "vocab_corpus_result":
            // R3-3 考古按钮回投：全文落 live 覆盖层，通知词详情刷新
            if let word = obj["word"] as? String {
                let ok = (obj["ok"] as? Bool) ?? false
                let content = obj["content"] as? String ?? ""
                DispatchQueue.main.async {
                    if ok, !content.isEmpty {
                        VocabCorpusStore.saveLive(word: word, markdown: content)
                    }
                    // sheet 关着时也要清「考古中」（#054 sol 1）
                    VocabArcheologyTracker.inFlight.remove(word)
                    NotificationCenter.default.post(
                        name: .vocabCorpusArrived, object: nil,
                        userInfo: ["word": word, "ok": ok]
                    )
                }
            }
        case "pocket_cmd":
            guard UserDefaults.standard.bool(forKey: "pocketEnabled") else {
                let id = obj["id"] as? String ?? ""
                send(["type": "pocket_result", "id": id, "ok": false, "error": "pocket disabled"]) { _ in }
                return
            }
            DispatchQueue.main.async {
                PocketExecutor.shared.execute(obj)
            }
        case TwitterCCBridge.commandType:
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = self.onTwitterCmd?(obj)
                    ?? ["type": TwitterCCBridge.resultType, "id": obj["id"] as? String ?? "", "ok": false, "result": "app 还没准备好"]
                self.send(result) { _ in }
            }
        case "agent_status_result":
            DispatchQueue.main.async { [weak self] in
                self?.onAgentStatusResult?(obj)
            }
        case "agent_book_note":
            // CR-4：AI 读书产物。去重 → 处理 → ack（成功才 ack，失败留 pending 等补投）
            guard let uuid = obj["uuid"] as? String, !uuid.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var seen = UserDefaults.standard.stringArray(forKey: Self.seenBookNoteKey) ?? []
                if seen.contains(uuid) {
                    // 已处理过（重复投递）——直接 ack 让 hub 清 pending
                    self.send(["type": "agent_book_note_ack", "uuid": uuid]) { _ in }
                    return
                }
                guard let handler = self.onAgentBookNote, handler(obj) else { return }
                seen.append(uuid)
                if seen.count > 200 { seen = Array(seen.suffix(200)) }
                UserDefaults.standard.set(seen, forKey: Self.seenBookNoteKey)
                self.send(["type": "agent_book_note_ack", "uuid": uuid]) { _ in }
            }
        case "reply":
            if let chatId = obj["chat_id"] as? String,
               let content = obj["content"] as? String {
                // reply_id dedup（hub 在 reconnect 时会 replay 缓冲全部 reply）
                let replyId = obj["reply_id"] as? String
                // C2：CC 发来的文件/图（可选 {name,mime,b64,isImage}）
                let fileObj = obj["file"] as? [String: Any]
                let fileData: Data? = (fileObj?["b64"] as? String).flatMap { Data(base64Encoded: $0) }
                let fileName = fileObj?["name"] as? String
                let fileMime = fileObj?["mime"] as? String
                let fileIsImage = (fileObj?["isImage"] as? Bool) ?? false
                let ccMsgId = obj["mp_msg_id"] as? String     // A4：CC 消息 id
                let replyTo = obj["reply_to"] as? String        // A4：引用的消息 id
                let callReply = CCCallReply.fromFrame(obj)
                let ts = (obj["ts"] as? NSNumber)?.doubleValue
                handlersQueue.async { [weak self] in
                    guard let self else { return }
                    self.probeReplyCount += 1
                    if let replyId, self.seenReplyIds[replyId] != nil {
                        DispatchQueue.main.async { self.advanceReplyCursor(ts) }
                        return  // 已收过，silently drop（不再比时间，按条数保留的全集里有就算见过）
                    }
                    BridgeProbe.log("reply new rid=\(replyId?.prefix(8) ?? "-") chat=\(chatId.prefix(8)) len=\(content.count) mp=\(ccMsgId?.prefix(14) ?? "-")")
                    // 收口即发（plan-跨对话排队）：无 pending 占位概念，所有 reply（回复我们的 /
                    // CC 主动发的）统一走 proactive 落地——查重/未读/上树/ccMessageId 存储全在那边。
                    // 「已收」标记落在投递**之后**：进程死在投递前（09-17 冷启动看门狗）下次 replay 还能补上；
                    // 没接线（handler 为 nil）不算收过。投递排队窗口内同一 reply_id 再来会二次投递，
                    // 由落库层 ccMessageId 查重兜底。
                    DispatchQueue.main.async {
                        guard let deliver = self.onProactiveMessage else { BridgeProbe.log("reply dropped: no handler rid=\(replyId?.prefix(8) ?? "-")"); return }
                        deliver(chatId, content, fileData, fileName, fileMime, fileIsImage, ccMsgId, replyTo, callReply)
                        self.advanceReplyCursor(ts)
                        guard let replyId else { return }
                        self.handlersQueue.async {
                            self.seenReplyIds[replyId] = Date()
                            // 按条数 prune：超过保留量就留最新 N 个
                            if self.seenReplyIds.count > self.replyDedupKeepCount {
                                let keep = self.seenReplyIds.sorted { $0.value > $1.value }.prefix(self.replyDedupKeepCount)
                                self.seenReplyIds = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
                            }
                            self.persistSeenReplyIds()   // 持久化：重启后仍能拦 hub replay 的旧 reply
                        }
                    }
                }
            }
        case "edit":
            // A4：CC 编辑发过的消息。按 mp_msg_id 找节点改 content（去重靠 ccMessageId+content，无害幂等）。
            if let chatId = obj["chat_id"] as? String,
               let mpMsgId = obj["mp_msg_id"] as? String,
               let content = obj["content"] as? String {
                let streaming = (obj["streaming"] as? Bool) ?? false   // 逐字流式中间态：不标 edited、不滚动
                DispatchQueue.main.async { [weak self] in self?.onEditMessage?(chatId, mpMsgId, content, streaming) }
            }
        case "thinking":
            // 思考链：挂到 mp_msg_id 锚定的消息节点。thinking_id 去重拦 replay。
            if let chatId = obj["chat_id"] as? String,
               let mpMsgId = obj["mp_msg_id"] as? String,
               let content = obj["content"] as? String,
               let thinkingId = obj["thinking_id"] as? String {
                let ts = (obj["ts"] as? NSNumber)?.doubleValue
                if (obj["streaming"] as? Bool) == true {   // 逐字流式：中间态不进去重表（一轮几十帧）
                    DispatchQueue.main.async { [weak self] in self?.onThinking?(chatId, mpMsgId, content) }
                    break
                }
                handlersQueue.async { [weak self] in
                    guard let self else { return }
                    if self.seenThinkingIds[thinkingId] != nil { DispatchQueue.main.async { self.advanceReplyCursor(ts) }; return }
                    self.seenThinkingIds[thinkingId] = Date()
                    if self.seenThinkingIds.count > self.thinkingDedupKeepCount {
                        let keep = self.seenThinkingIds.sorted { $0.value > $1.value }.prefix(self.thinkingDedupKeepCount)
                        self.seenThinkingIds = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
                    }
                    self.persistSeenThinkingIds()
                    DispatchQueue.main.async { self.onThinking?(chatId, mpMsgId, content); self.advanceReplyCursor(ts) }
                }
            }
        case "ask_user_question":
            if let chatId = obj["chat_id"] as? String,
               let toolUseId = obj["tool_use_id"] as? String,
               let questions = obj["questions"] as? [[String: Any]], !questions.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.onAskUserQuestion?(chatId, toolUseId, questions) }
            }
        case "ask_user_resolved":
            if let chatId = obj["chat_id"] as? String,
               let toolUseId = obj["tool_use_id"] as? String,
               let questions = obj["questions"] as? [[String: Any]] {
                let answers = obj["answers"] as? [String: String]
                DispatchQueue.main.async { [weak self] in self?.onAskUserResolved?(chatId, toolUseId, questions, answers) }
            }
        case "ask_user_stale":
            if let toolUseId = obj["tool_use_id"] as? String {
                DispatchQueue.main.async { [weak self] in self?.onAskUserStale?(toolUseId) }
            }
        case "ack":
            // v1 no-op；后续版本可用于确认送达
            break
        case "send_status":
            // K1 第 4b 步：hub 写 tmux 结果不明才推（正常发送没有这帧）。缺字段 / 不认识的 status 整帧忽略
            guard let status = CCSendStatus(frame: obj) else { break }
            #if DEBUG
            print("[CCBridge] send_status \(status.state.rawValue) msg=\(status.messageId) session=\(status.sessionName) reason=\(status.reason ?? "-")")
            #endif
            DispatchQueue.main.async { [weak self] in self?.sendTracker.didReceive(status) }
        case "send_status_snapshot":
            // 连上后 hub 补发：没落定的 + failed 的全部记录。断线 / 后台期间错过的最终状态靠它补上
            guard let statuses = CCSendStatus.snapshot(frame: obj) else { break }
            #if DEBUG
            print("[CCBridge] send_status_snapshot \(statuses.count) 条")
            #endif
            DispatchQueue.main.async { [weak self] in self?.sendTracker.didReceiveSnapshot(statuses) }
        case "hello":
            if let hello = HubHello(frame: obj) {
                DispatchQueue.main.async { [weak self] in
                    self?.hubInfo = hello
                    self?.hubInfoIsCurrent = true
                }
            }
        case "hub_config":
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // 老一点的 hub 可能先回 hub_config 没 hello：有一份才合（没有就等 hello）
                if var info = self.hubInfo, self.hubInfoIsCurrent {
                    info.merge(hubConfig: obj)
                    self.hubInfo = info
                }
            }
            // 只认带回来的 request_id：GET 的回帧 / 别处触发的广播 / 已超时的 SET 都不在表里，只刷新显示
            let id = Self.requestId(obj)
            handlersQueue.async { [weak self] in self?.finishHubConfig(id: id, nil) }
        case "hub_config_error":
            let reason = (obj["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "电脑没接受这个目录"
            let id = Self.requestId(obj)
            handlersQueue.async { [weak self] in self?.finishHubConfig(id: id, reason) }
        case "dir_list":
            if let result = HubDirListing.parse(obj) {
                let id = Self.requestId(obj)
                handlersQueue.async { [weak self] in self?.finishDirList(id: id, result) }
            }
        case "error":
            let reason = (obj["reason"] as? String) ?? "unknown"
            DispatchQueue.main.async { [weak self] in
                self?.lastError = reason
            }
        case "spawn_cc_ok":
            if let name = obj["session_name"] as? String {
                handlersQueue.async { [weak self] in
                    guard let self else { return }
                    if let h = self.spawnHandlers.removeValue(forKey: name) {
                        DispatchQueue.main.async { h(.success(())) }
                    }
                }
            }
        case "spawn_cc_err":
            let name = obj["session_name"] as? String ?? ""
            let reason = obj["reason"] as? String ?? "unknown"
            handlersQueue.async { [weak self] in
                guard let self else { return }
                if let h = self.spawnHandlers.removeValue(forKey: name) {
                    DispatchQueue.main.async { h(.failure(CCBridgeRemoteError(reason: reason, fromHub: true))) }
                }
            }
        case "transport_policies":
            // hub 推的权威表（连上 / 任何设备改了）：整表覆盖本机，菜单勾以此为准
            if let pol = obj["policies"] as? [String: String] {
                DispatchQueue.main.async { UserDefaults.standard.set(pol, forKey: Self.transportPolicyKey) }
            }
        case "list_sessions_result":
            let sessions = obj["sessions"] as? [String] ?? []
            handlersQueue.async { [weak self] in
                guard let self else { return }
                let hs = self.listHandlers
                self.listHandlers.removeAll()
                for h in hs {
                    DispatchQueue.main.async { h(.success(sessions)) }
                }
            }
        case "terminal_init":
            if let session = obj["session_name"] as? String,
               let b64 = obj["bytes"] as? String,
               let data = Data(base64Encoded: b64) {
                // mouse_any：tmux #{mouse_any_flag}。缺字段 = 老 hub，传 nil 让 app 侧走前缀兜底。
                let mouseAny = obj["mouse_any"] as? Bool
                let paste = obj["paste"] as? Bool == true
                let hubMs = (obj["hub_ms"] as? NSNumber)?.intValue
                let hubSteps = obj["hub_steps"] as? String
                DispatchQueue.main.async { [weak self] in self?.hubSupportsTerminalPaste = paste }
                handlersQueue.async { [weak self] in
                    guard let self, let h = self.terminalInitHandlers[session] else { return }
                    let timing = self.terminalOpenTiming.removeValue(forKey: session)
                    DispatchQueue.main.async {
                        h(data, mouseAny)
                        if let timing { self.reportTerminalOpen(session, timing: timing, hubMs: hubMs, hubSteps: hubSteps) }
                    }
                }
            }
        case "terminal_chunk":
            if let session = obj["session_name"] as? String,
               let b64 = obj["bytes"] as? String,
               let data = Data(base64Encoded: b64) {
                handlersQueue.async { [weak self] in
                    if let h = self?.terminalChunkHandlers[session] {
                        DispatchQueue.main.async { h(data) }
                    }
                }
            }
        case "list_windows_result":
            let raw = obj["windows"] as? [[String: Any]] ?? []
            let windows: [TerminalWindowInfo] = raw.compactMap { item in
                guard let code = item["code"] as? String, !code.isEmpty else { return nil }
                return TerminalWindowInfo(
                    code: code,
                    createdAt: item["created_at"] as? String ?? "",
                    closedAt: item["closed_at"] as? String,
                    alive: item["alive"] as? Bool ?? false,
                    title: item["title"] as? String,
                    engine: item["engine"] as? String,
                    phase: item["phase"] as? String
                )
            }
            flushWindowList(.success(windows))
        case "terminal_state":
            // 排 3 的真相源（全量窗口 + phase + engine + title；对话 session 同轴发下来）。
            // `list_windows` 60s 对账保留 —— 它是唯一带 closed 的那条，恢复 sheet 要靠它。
            let entries = (obj["windows"] as? [[String: Any]] ?? []).compactMap(TerminalStateEntry.init(frame:))
            Task { @MainActor in TerminalWindowStore.shared.applyState(entries) }
        case "session_model":
            // 底部模型胶囊「cc-opus-4.6-1m」：会话实际在用的模型（hub 读转录 / 拉起 / /model 确认）
            if let m = CCSessionModel(frame: obj) {
                Task { @MainActor in CCSessionModelStore.shared.apply(m) }
            }
        case "session_phase":
            // 进度卡 B（粟粟 10-03）：CC 会话干活中 / 等你 / 做完了，聊天页底部的状态卡读
            if let p = CCSessionPhase(frame: obj) {
                Task { @MainActor in CCSessionPhaseStore.shared.apply(p) }
            }
        case "window_opened":
            if let code = obj["code"] as? String, !code.isEmpty {
                flushWindowOpen(.success(code))
            } else {
                // 新 hub 开不出来时回 {ok:false, reason}（缺 tmux / 没装 claude…），老 hub 不带 reason
                flushWindowOpen(.failure(Self.hubReason(obj).map { CCBridgeRemoteError(reason: $0, fromHub: true) }
                    ?? CCBridgeRemoteError(reason: Self.noCodeReason)))
            }
        case "window_restored":
            // ok=false：hub 拒绝了（已结束 / 不认识 / tmux 起不来）。老 hub 不带 ok，按成功算
            if obj["ok"] as? Bool == false {
                flushWindowRestore(.failure(Self.hubReason(obj).map { CCBridgeRemoteError(reason: $0, fromHub: true) }
                    ?? CCBridgeRemoteError(reason: "hub 拒绝恢复这个窗口")))
            } else if let code = obj["code"] as? String, !code.isEmpty {
                flushWindowRestore(.success(code))
            } else {
                flushWindowRestore(.failure(CCBridgeRemoteError(reason: Self.noCodeReason)))
            }
        case "window_closed":
            break   // 无回调：store 乐观更新，下一轮对账以 hub 为准
        case "window_ended":
            if let code = obj["code"] as? String {
                flushWindowEnd(code: code, obj["ok"] as? Bool == true ? .success(()) : .failure(.refused))
            }
        case "terminal_usage":
            // 字段全可选：hub 读不到 transcript / rl.json 时会缺字段，顶卡对应格显示 `--`
            if let session = obj["session_name"] as? String {
                let usage = TerminalUsage(
                    model: obj["model"] as? String,
                    ctx: obj["ctx"] as? Int,
                    fiveHour: obj["five_hour"] as? Int,
                    sevenDay: obj["seven_day"] as? Int
                )
                handlersQueue.async { [weak self] in
                    if let h = self?.terminalUsageHandlers[session] {
                        DispatchQueue.main.async { h(usage) }
                    }
                }
                #if os(iOS)
                UsageSnapshotWriter.write(sessionName: session, model: usage.model, ctx: usage.ctx,
                                          fiveHour: usage.fiveHour, sevenDay: usage.sevenDay)
                #endif
            }
        case "voice_call_state":
            #if os(iOS)
            if let object = obj["call"], let data = try? JSONSerialization.data(withJSONObject: object),
               let call = try? JSONDecoder().decode(NativeVoiceCall.self, from: data) {
                Task { @MainActor in NativeCallCoordinator.shared.receiveState(call) }
            }
            #endif
        case "voice_call_snapshot":
            #if os(iOS)
            if let object = obj["calls"], let data = try? JSONSerialization.data(withJSONObject: object),
               let calls = try? JSONDecoder().decode([NativeVoiceCall].self, from: data) {
                Task { @MainActor in NativeCallCoordinator.shared.receiveSnapshot(calls) }
            }
            #endif
        case "voice_call_error":
            #if os(iOS)
            let id = obj["call_id"] as? String, reason = obj["reason"] as? String ?? "来电请求失败"
            Task { @MainActor in NativeCallCoordinator.shared.receiveError(id: id, message: reason) }
            #endif
        case "la_query_result":
            #if os(iOS)
            // 「回了 null」= hub 明确说这一轮死了（该 end）；「键根本没出现」= 没答案（不动）。
            // 两者在 app 侧是相反的决定，所以 answered 单独收一份键集合。
            let rawAlive = obj["alive"] as? [String: Any] ?? [:]
            var alive: [String: CCLiveActivityAlive] = [:]
            var answered: Set<String> = []
            for (activityId, value) in rawAlive {
                answered.insert(activityId)
                guard let d = value as? [String: Any],
                      let phase = d["phase"] as? String,
                      let session = d["session_name"] as? String else { continue }
                alive[activityId] = CCLiveActivityAlive(phase: phase, runId: d["run_id"] as? String, sessionName: session)
            }
            Task { @MainActor in
                CCLiveActivityManager.shared.handleQueryResult(alive: alive, answered: answered)
            }
            #endif
        case "voice_instructions_result":
            // CLAUDE.md 语音块同步回执：只记日志（no_markers = cc-rp CLAUDE.md 里标记被删了）
            #if DEBUG
            print("[CCBridge] voice_instructions_result ok=\(obj["ok"] as? Bool ?? false) changed=\(obj["changed"] as? Bool ?? false) reason=\(obj["reason"] as? String ?? "-")")
            #endif
        case "la_token_nak":
            #if os(iOS)
            let kind = obj["kind"] as? String ?? "update"
            let activityId = obj["activity_id"] as? String
            let installId = obj["install_id"] as? String
            let reason = obj["reason"] as? String ?? "unknown"
            Task { @MainActor in
                CCLiveActivityManager.shared.handleNak(kind: kind, activityId: activityId,
                                                       installId: installId, reason: reason)
            }
            #endif
        case "terminal_paste_result":
            if let requestId = obj["request_id"] as? String {
                let ok = obj["ok"] as? Bool == true
                finishTerminalPaste(requestId, failure: ok ? nil : "没发出去：\(obj["reason"] as? String ?? "粘贴失败")")
            }
        case "terminal_error":
            if let session = obj["session_name"] as? String,
               let reason = obj["reason"] as? String {
                if reason == "session_not_found", !session.hasPrefix("mp-win-") {
                    handlersQueue.async { [weak self] in self?.respawnOrReportOnQueue(session: session) }
                } else {
                    deliverTerminalError(session: session, reason: reason)
                }
            }
        default:
            break
        }
    }

    /// 新 hub 失败帧里的中文原因（open / restore 失败时带）
    private static func hubReason(_ obj: [String: Any]) -> String? {
        (obj["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// hub_config / hub_config_error / dir_list 带回来的 request_id（非空字符串才算）
    static func requestId(_ obj: [String: Any]) -> String? {
        (obj["request_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 窗口操作回帧没给 code（老 hub 的失败）
    static let noCodeReason = "hub 没给 code"

    private func deliverTerminalError(session: String, reason: String) {
        handlersQueue.async { [weak self] in
            if let h = self?.terminalErrorHandlers[session] {
                DispatchQueue.main.async { h(reason) }
            }
        }
    }

    /// 对话 Agent 的终端撞 session_not_found（Mac 重启过 / tmux 被关了）：这条连接上第一次撞就自动 spawn 一次再 attach（T06），
    /// 第二次才报给界面（断桥卡「这个窗口已经不在了」）。spawn 期间 detach 了（终端页关了）就不再 attach。
    /// 只在 handlersQueue 上调：跟 detach 摘订阅同一条队，「已经离开终端」和「这次要不要 spawn」不会错开（astra 实现审 #10）。
    private func respawnOrReportOnQueue(session: String) {
        // 已经 detach（离开终端）：这次恢复作废，不 spawn 也不报
        guard terminalAttachParams[session] != nil else { return }
        // 回音来自的那次 attach 不是交给当前连接的（连接换过了）：新连接 didOpen 会自己补订阅，这条作废
        guard let current = task, attachSentOnTask[session] === current else { return }
        guard autoSpawnedOn[session] !== current else {
            deliverTerminalError(session: session, reason: "session_not_found")
            return
        }
        autoSpawnedOn[session] = current
        BridgeProbe.log("auto spawn \(session) after session_not_found")
        spawnSession(session) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.reattachIfSubscribed(session)
            // superseded = 别处（终端页 onAppear）也发了 spawn_cc，它排在这次 attach 前面，hub 按序处理，照样 attach
            case .failure(let err) where err.reason == "session_exists" || err.reason == "superseded":
                self.reattachIfSubscribed(session)
            case .failure(let err):
                // hub 说了为什么起不来（电脑上没装 tmux / Claude Code…）就把原因带到界面，别一律说「窗口已经不在了」（astra 实现审 #14）
                self.deliverTerminalError(session: session, reason: err.fromHub ? err.reason : "session_not_found")
            }
        }
    }

    private func reattachIfSubscribed(_ session: String) {
        handlersQueue.async {
            guard let p = self.terminalAttachParams[session] else { return }
            self.sendAttachOnQueue(session: session, cols: p.cols, rows: p.rows)
        }
    }

    private func handleDisconnect(error: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 幂等守卫：同一次断连 receive failure 和 didClose 都会到这（两边 guard 判的都是
            // task 引用没变）→ scheduleReconnect 双调 → 轮换转两格，两候选正好转回原地，
            // 备用 URL 永远轮不到。这里清 task 引用，晚到的重复回调被各自的 === guard 挡掉。
            guard self.task != nil else { return }
            if self.probeConnectedAt == nil {
                // 握手没成（看门狗超时 / 被拒 / bad response）：记进这一段的尝试
                self.episode?.attempts.append(["h": self.url?.host ?? "?", "r": "ws:" + String((error ?? "nil").prefix(80)), "ms": 0])
            } else if !self.manualClose {
                self.beginEpisode("drop")
            }
            let up = self.probeConnectedAt.map { String(format: "%.0fs", Date().timeIntervalSince($0)) } ?? "never-open"
            BridgeProbe.log("disconnect err=\(error ?? "nil") up=\(up) replies=\(self.probeReplyCount) fg=\(self.isForeground)")
            self.probeConnectedAt = nil
            self.task = nil
            self.hubSupportsTerminalPaste = nil
            self.hubInfoIsCurrent = false
            self.connectWatchdog?.invalidate()
            self.connectWatchdog = nil
            self.isConnected = false
            self.lastError = error
            self.failWindowEnds()
            self.failHubRequests()
            if !self.manualClose {
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        let delay = isForeground ? min(reconnectDelay, Self.foregroundMaxReconnectDelay) : reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        episode?.waitMs += delay * 1000
        BridgeProbe.log("reconnect in \(String(format: "%.2f", delay))s")
        // 候选选择交给 startTask 的竞速探测，这里只管退避节奏
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.startTask()
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension CCBridgeWebSocketClient: URLSessionWebSocketDelegate {
    /// 中继配了自签证书 pin 时只认 pin（和竞速探测同一套，CCRelayPin）；其余地址照常走系统校验
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = CCRelayPin.evaluate(challenge)
        completionHandler(disposition, credential)
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        let callbackAt = Date()
        let openNs = ConnectRuler.stamp()   // 尺子 wsOpenAt：delegate 回调线程
        DispatchQueue.main.async { [weak self] in
            let uiNs = ConnectRuler.stamp(), uiWall = Date()   // 尺子 uiConnectedAt（主线程进入）：排到主线程的 block 首行
            guard let self else { return }
            // 老 session 在 invalidateAndCancel 后回调可能跟新 task didOpen race，
            // 只认当前 self.task 的回调，避免被替换掉的老 task 污染状态
            guard webSocketTask === self.task else { return }
            self.rulerNoteOpen(webSocketTask, openNs: openNs, openWall: callbackAt, uiNs: uiNs, uiWall: uiWall)
            self.connectWatchdog?.invalidate()
            self.connectWatchdog = nil
            self.isConnected = true
            self.lastError = nil
            self.probeConnectedAt = Date()
            self.probeReplyCount = 0
            BridgeProbe.log("open host=\(webSocketTask.originalRequest?.url?.host ?? "?")")
            self.lastOpenAt = Date()
            self.reconnectDelay = Self.minReconnectDelay  // 连接成功后重置退避计数
            self.startPingTimer()
            // 新连接上的 hello 到之前，上一份 hubInfo 只能当「上次的」（见 hubInfoIsCurrent）
            self.hubInfoIsCurrent = false
            // L4 根因1：断线时 hub 会拆掉 pipe-pane 流，重连后必须重订阅，否则终端永久黑屏。
            // 首连也要补（T06 / 10-10）：冷启动停在终端页时 attach 常早于桥连上，那一发没有 task 直接丢了。
            // 只补没交给这个 task 的，已经排在它上面的 attach 不重发（见 attachSentOnTask）。
            self.resubscribeTerminals(on: webSocketTask)
            self.sendTerminalActive()
            // 自报平台：hub 据此把本地推特命令固定发手机（数据在手机上）
            #if os(iOS)
            self.send(["type": "client_info", "platform": "ios"]) { _ in }
            #else
            self.send(["type": "client_info", "platform": "macos"]) { _ in }
            #endif
            self.episode?.ruler?.noteClientInfo(at: ConnectRuler.stamp())   // 尺子终点：send 同步调完 task.send 即交给了当前 task
            self.noteMainDelay(since: callbackAt)
            self.finishEpisode(host: webSocketTask.originalRequest?.url?.host)
            // 每次（重）连都把 APNs token 重报给 hub，确保 hub 始终有有效 token 可推。
            if let t = self.pushToken {
                self.send(self.pushTokenFrame(t, preview: self.pushPreview)) { _ in }
            }
            #if os(iOS)
            // LA token 同理：断线期间的注册攒在 UserDefaults，连上一次性全报。
            Task { @MainActor in CCLiveActivityManager.shared.reportAll(); NativeCallCoordinator.shared.reportRegistration() }
            #endif
            // 重连后重报当前 focus（hub 重启/断线会丢 focus 表）。重置去重缓存强制发一次。
            self.lastSentFocus = nil
            self.sendEffectiveFocus()
            // 重连后重发 CC 设置（hub 不持久化 config，靠 app 重发）
            self.sendCCConfig()
            // CC 小克 memory 同步：每次连上拉一次清单（开关关着时空操作）
            CCMemorySync.connected()
            #if os(macOS)
            self.sendBindConfig()   // 绑定开关只本机 Mac 同步给 hub（hub bind-config 持久，这里对齐）
            #endif
        }
    }

    /// (重)连上后对仍注册、但 attach 没交给这个 task 的 terminal session 重发 attach（用最新存的 cols/rows）。
    private func resubscribeTerminals(on openedTask: URLSessionWebSocketTask) {
        handlersQueue.async {
            for (session, size) in self.terminalAttachParams where self.attachSentOnTask[session] !== openedTask {
                self.sendAttachOnQueue(session: session, cols: size.cols, rows: size.rows)
            }
        }
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        // iOS 上 URLSessionWebSocketTask 不自动 keepalive，长 idle 会被 OS 杀。
        // 每 5s 主动发 ping 保活。
        // L4 P0a：用 Timer init + RunLoop.add(_:forMode:.common) 而不是 scheduledTimer，
        // 后者只跑在 .default mode，SwiftUI scroll/paging 时 RunLoop 切 .tracking →
        // ping 跳票几秒 → URLSession idle timeout → 1006。
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let task = self?.task, task.state == .running else { return }
            task.sendPing { err in if let err { BridgeProbe.log("ping fail \(err.localizedDescription)") } }   // 断开仍由 receive 路径处理
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        // startTask() 里 invalidateAndCancel 老 session 会异步触发老 task 的 didClose，
        // 那次 close 是我们主动 cancel 的预期结果，不该再起一轮 ghost reconnect。
        // 只对当前 self.task 的真实关闭做 disconnect 处理。
        guard webSocketTask === self.task else { return }
        let r = reason.flatMap { String(data: $0, encoding: .utf8) }
        handleDisconnect(error: r ?? "closed (\(closeCode.rawValue))")
    }
}
