import Foundation
import os

/// 通话链路日志（#042）：设备 syslog 过滤 `subsystem:com.susu.MemoryPalace category:call`。只记状态 / 原因，不记 key 和对话内容。
let callLog = Logger(subsystem: "com.susu.MemoryPalace", category: "call")

/// 与 hub 对齐的来电记录。profile 由本机 chat_id 查库，不信任推送提供的楼层。
struct NativeVoiceCall: Codable, Equatable, Sendable {
    let call_id: String
    let chat_id: String
    var install_id: String?
    let caller: String
    let created_at: Double
    let expires_at: Double
    var status: String?
    var uuid: UUID? { UUID(uuidString: call_id) }
    var valid: Bool {
        uuid != nil && UUID(uuidString: chat_id) != nil && created_at.isFinite && expires_at.isFinite
            && expires_at > created_at && expires_at - created_at <= 60_000 && caller.count <= 80
    }
    func expired(at date: Date = .now) -> Bool { expires_at <= date.timeIntervalSince1970 * 1000 }
    var terminal: Bool { ["declined", "canceled", "missed", "ended"].contains(status ?? "") }
}

extension NativeVoiceCall {
    /// 系统拒绝上报来电（`reportNewIncomingConversation` 抛错）：给她看的文案（nil = 不显示）+ 要不要告诉 hub 结束。
    /// 码值按 CallKit `CXErrorCodeIncomingCallError`（iPhoneOS 26.4 SDK CXError.h 核过）；domain 由 iOS 侧传 `CXErrorDomainIncomingCall`。
    static func reportFailureText(_ error: Error, caller: String, domain: String, at date: Date = .now) -> (text: String?, shouldFailHub: Bool) {
        let ns = error as NSError
        let generic = "系统无法显示来电：" + error.localizedDescription
        guard ns.domain == domain else { return (generic, true) }
        switch ns.code {
        case 1: return ("系统不允许这个包显示来电（权限问题）", true)
        case 2: return (nil, false)  // 同一通重复上报：系统里已经有这通
        case 3: return ("被专注模式拦下了：\(caller) \(clock(date)) 的来电没响。关掉专注模式，或在专注模式里放行来电后再让\(caller)打", true)
        case 4: return ("被来电拦截设置拦下了：\(caller) \(clock(date)) 的来电没响", true)
        default: return (generic, true)
        }
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

#if os(iOS)
import PushKit
import LiveCommunicationKit
import CallKit
import AVFoundation
import Observation

@MainActor @Observable
final class NativeCallCoordinator: NSObject {
    static let shared = NativeCallCoordinator()
    static let enabledKey = "nativeVoiceCalls.enabled.v1"
    static let installKey = "nativeVoiceCalls.install.v1"
    static let lastErrorKey = "nativeVoiceCalls.lastError.v1"
    private(set) var current: NativeVoiceCall?
    private(set) var audioActive = false
    private(set) var readyToPresent = false
    private(set) var muted = false
    /// 最近一次来电失败的原因（持久化：冷启动被拉起报错后进程被杀，她进设置页也能看到）；下一通接通后清掉
    private(set) var errorMessage: String?
    private(set) var errorAt: Date?
    @ObservationIgnored private var registry: PKPushRegistry?
    @ObservationIgnored private var manager: ConversationManager!
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var joinAction: JoinConversationAction?
    @ObservationIgnored private var reported: Set<UUID> = []
    @ObservationIgnored private var pendingAction: String?
    private var terminalActions: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "nativeVoiceCalls.pendingEnds.v1") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "nativeVoiceCalls.pendingEnds.v1") }
    }

    var installID: String {
        if let id = UserDefaults.standard.string(forKey: Self.installKey), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: Self.installKey); return id
    }
    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    override init() {
        super.init()
        manager = ConversationManager(configuration: .init(ringtoneName: nil, iconTemplateImageData: nil,
            maximumConversationGroups: 1, maximumConversationsPerConversationGroup: 1,
            includesConversationInRecents: false, supportsVideo: false, supportedHandleTypes: [.generic]))
        manager.delegate = self
        if let saved = UserDefaults.standard.dictionary(forKey: Self.lastErrorKey),
           let text = saved["text"] as? String, let at = saved["at"] as? Double {
            errorMessage = text; errorAt = Date(timeIntervalSince1970: at)
        }
    }
    private func setError(_ text: String?) {
        errorMessage = text; errorAt = text == nil ? nil : .now
        if let text { UserDefaults.standard.set(["text": text, "at": Date().timeIntervalSince1970], forKey: Self.lastErrorKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.lastErrorKey) }
    }
    func configure() {
        if enabled && registry == nil {
            let r = PKPushRegistry(queue: .main); r.delegate = self; registry = r; r.desiredPushTypes = [.voIP]
        } else if !enabled {
            if current != nil { finish(reason: .remoteEnded, action: "hangup") }
            registry?.desiredPushTypes = []; registry = nil
        }
        reportRegistration()
    }
    func reportRegistration() {
        let token = UserDefaults.standard.string(forKey: "nativeVoiceCalls.token.v1") ?? ""
        CCBridgeWebSocketClient.shared.send(["type": "register_call_client", "install_id": installID,
            "enabled": enabled && !token.isEmpty, "token": token, "env": APNsEnvironment.current,
            "topic": Bundle.main.bundleIdentifier ?? ""]) { _ in }
        for (id, action) in terminalActions { sendAction(action, id: id) }
        if let call = current, let pendingAction { sendAction(pendingAction, id: call.call_id) }
    }
    private func reconnectBridge() {
        let urls = CCBridgeEndpoints.configuredURLs(fallbackToLocal: false)   // 没配过 hub 就不连（原语义）
        guard !urls.isEmpty else { return }
        let token = KeychainStore.get(account: "cc-bridge")
        if token == nil { callLog.error("reconnect 读不到 hub 口令 status=\(KeychainStore.readStatus(account: "cc-bridge"), privacy: .public)") }
        CCBridgeWebSocketClient.shared.connect(urls: urls, token: token, keepExistingToken: true)
    }
    func receiveState(_ call: NativeVoiceCall) {
        guard call.valid, call.install_id == installID else { return }
        if call.terminal { var actions = terminalActions; actions.removeValue(forKey: call.call_id); terminalActions = actions }
        guard let old = current, old.call_id == call.call_id,
              call.install_id == installID, old.chat_id == call.chat_id else { return }
        current = call
        if call.terminal { finish(reason: call.status == "missed" ? .unanswered : .remoteEnded, action: nil); return }
        if call.status == "accepted", let action = joinAction {
            callLog.notice("hub accepted call=\(String(call.call_id.prefix(8)), privacy: .public)")
            pendingAction = nil; joinAction = nil
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            timeoutTask?.cancel()
            action.fulfill(dateConnected: .now)
            // 音频激活之后再导航、开麦。
            routeWhenReady()
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, current?.call_id == call.call_id,
                      CallController.shared.nativeCallID != call.call_id else { return }
                let reason = audioActive ? (CallController.shared.blocker?.rawValue ?? "原因不明") : "系统通话音频没激活"
                callLog.error("接听超时 call=\(String(call.call_id.prefix(8)), privacy: .public) 卡在：\(reason, privacy: .public)")
                fail("接听后没接上对话（\(reason)）")
            }
        }
    }
    func receiveSnapshot(_ calls: [NativeVoiceCall]) {
        for call in calls where call.valid && call.install_id == installID {
            if call.terminal { receiveState(call) }
            else if call.status == "accepted", call.call_id != current?.call_id {
                var actions = terminalActions; actions[call.call_id] = "hangup"; terminalActions = actions
                sendAction("hangup", id: call.call_id)
            }
        }
        guard let id = current?.call_id else { return }
        if let call = calls.first(where: { $0.call_id == id }) { receiveState(call) }
        else { fail("来电已失效") }
    }
    func receiveError(id: String?, message: String) {
        if let id, message.contains("not owned") {
            var actions = terminalActions; actions.removeValue(forKey: id); terminalActions = actions
        }
        if id == current?.call_id { fail(message) }
    }
    private func sendAction(_ action: String, id: String) {
        CCBridgeWebSocketClient.shared.send(["type": "voice_call_action", "call_id": id, "action": action]) { _ in }
    }
    private func receivePush(_ payload: [AnyHashable: Any], mustReport: Bool, completion: @escaping () -> Void) {
        // 必须先履行系统报告；不能等待网络/数据库再决定报告。
        let decoded = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { try? JSONDecoder().decode(NativeVoiceCall.self, from: $0) }
        let id = decoded?.uuid ?? UUID()
        let alreadyReported = reported.contains(id)
        callLog.notice("收到来电推送 call=\(String(id.uuidString.prefix(8)), privacy: .public) mustReport=\(mustReport, privacy: .public) again=\(alreadyReported, privacy: .public)")
        if reported.count >= 128 { reported.removeAll() }; reported.insert(id)
        let handle = Handle(type: .generic, value: decoded?.chat_id ?? "unknown", displayName: decoded?.caller ?? "语音来电")
        Task { @MainActor in
            defer { completion() }
            do { try await manager.reportNewIncomingConversation(uuid: id, update: .init(members: [handle], activeRemoteMembers: [handle], capabilities: [])) }
            catch {
                let ns = error as NSError
                callLog.error("来电上报失败 domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
                if alreadyReported { return }
                reported.remove(id)
                let failure = NativeVoiceCall.reportFailureText(error, caller: decoded?.caller ?? "来电", domain: CXErrorDomainIncomingCall)
                if let text = failure.text { setError(text) }
                // 告诉 hub 这通没响（ringing → missed），别让 CC 干等 60 秒；断线 / 冷启动下次连上由 reportRegistration 补发
                if failure.shouldFailHub, let call = decoded, call.valid, call.install_id == installID {
                    var actions = terminalActions
                    if actions.count >= 20 { actions.removeAll() }
                    actions[call.call_id] = "fail"; terminalActions = actions
                    reconnectBridge(); reportRegistration()
                }
                return
            }
            if alreadyReported { return }
            guard let call = decoded, call.valid, enabled, !call.expired(), current == nil, !CallSession.activeSnapshot else {
                if let conversation = manager.conversations.first(where: { $0.uuid == id }) {
                    manager.reportConversationEvent(.conversationEnded(.now, .unanswered), for: conversation)
                }
                return
            }
            current = call; readyToPresent = false; muted = false
            reconnectBridge(); reportRegistration()
            timeoutTask?.cancel()
            timeoutTask = Task { @MainActor in
                let seconds = max(0, (call.expires_at / 1000) - Date().timeIntervalSince1970)
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, current?.call_id == call.call_id else { return }
                finish(reason: .unanswered, action: "fail")
            }
        }
    }
    /// accepted + 系统音频激活：控制器直接开麦（不等界面），同时照旧请 ContentView 载对话、盖通话页
    private func routeWhenReady() {
        guard audioActive, let call = current, call.status == "accepted" else { return }
        readyToPresent = true
        NotificationCenter.default.post(name: .pushConversationRequested, object: nil)
        CallController.shared.startNativeIfReady(call)
    }
    /// 控制器已开麦：撤掉接听超时，清掉上一通的失败原因
    func controllerDidStart() { timeoutTask?.cancel(); setError(nil) }
    func fail(_ message: String) {
        setError(message)
        finish(reason: .failed, action: "fail")
    }
    func setMuted(_ value: Bool) {
        guard let id = current?.uuid, current?.status == "accepted", muted != value else { return }
        Task { @MainActor in
            do { try await manager.perform([MuteConversationAction(conversationUUID: id, isMuted: value)]) }
            catch { setError("系统静音操作失败：" + error.localizedDescription) }
        }
    }
    func appHangup() { if current != nil { finish(reason: .remoteEnded, action: "hangup") } }
    private func finish(reason: LiveCommunicationKit.Conversation.EndedReason, action: String?) {
        guard let call = current else { return }
        callLog.notice("来电结束 call=\(String(call.call_id.prefix(8)), privacy: .public) reason=\(String(describing: reason), privacy: .public) action=\(action ?? "nil", privacy: .public)")
        current = nil; readyToPresent = false; audioActive = false
        CallController.shared.stop()
        pendingAction = nil; timeoutTask?.cancel(); timeoutTask = nil
        joinAction?.fail(); joinAction = nil
        if let action {
            var actions = terminalActions
            if actions.count >= 20 { actions.removeAll() }
            actions[call.call_id] = action; terminalActions = actions
            sendAction(action, id: call.call_id)
        }
        if let conversation = manager.conversations.first(where: { $0.uuid == call.uuid }) {
            manager.reportConversationEvent(.conversationEnded(.now, reason), for: conversation)
        }
        NotificationCenter.default.post(name: .nativeCallEnded, object: nil)
    }
}

extension NativeCallCoordinator: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            #if !targetEnvironment(simulator)
            UserDefaults.standard.set(token, forKey: "nativeVoiceCalls.token.v1")
            reportRegistration()
            #endif
        }
    }
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        Task { @MainActor in UserDefaults.standard.removeObject(forKey: "nativeVoiceCalls.token.v1"); reportRegistration() }
    }
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        LaunchMarks.note("voipPush")   // 秒连尺子：启动来源
        Task { @MainActor in receivePush(payload.dictionaryPayload, mustReport: true, completion: completion) }
    }
    @available(iOS 26.4, *)
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingVoIPPushWith payload: PKPushPayload, metadata: PKVoIPPushMetadata, withCompletionHandler completion: @escaping () -> Void) {
        LaunchMarks.note("voipPush")   // 秒连尺子：启动来源
        Task { @MainActor in
            // mustReport=false 的迟到来电不重振铃；前台 fresh 来电仍可展示系统 UI。
            if !metadata.mustReport {
                let data = try? JSONSerialization.data(withJSONObject: payload.dictionaryPayload)
                guard let data, let call = try? JSONDecoder().decode(NativeVoiceCall.self, from: data), call.valid,
                      enabled, !call.expired(), current == nil, !CallSession.activeSnapshot else { completion(); return }
            }
            receivePush(payload.dictionaryPayload, mustReport: metadata.mustReport, completion: completion)
        }
    }
}
extension NativeCallCoordinator: ConversationManagerDelegate {
    nonisolated func conversationManagerDidBegin(_ manager: ConversationManager) {}
    nonisolated func conversationManager(_ manager: ConversationManager, conversationChanged conversation: LiveCommunicationKit.Conversation) {}
    nonisolated func conversationManagerDidReset(_ manager: ConversationManager) {
        Task { @MainActor in finish(reason: .failed, action: "fail"); reported.removeAll() }
    }
    nonisolated func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
        Task { @MainActor in
            guard action.conversationUUID == current?.uuid else { action.fail(); return }
            if let join = action as? JoinConversationAction {
                guard enabled, current?.status != "accepted", let call = current, !call.expired() else { action.fail(); return }
                joinAction = join; pendingAction = "accept"
                callLog.notice("接听 Join call=\(String(call.call_id.prefix(8)), privacy: .public)")
                reconnectBridge(); reportRegistration()
            } else if let mute = action as? MuteConversationAction {
                muted = mute.isMuted
                CallSession.shared.muted = mute.isMuted
                mute.fulfill()
            } else if let end = action as? EndConversationAction {
                let event = current?.status == "accepted" ? "hangup" : "decline"
                end.fulfill(dateEnded: .now); finish(reason: .remoteEnded, action: event)
            } else { action.fail() }
        }
    }
    nonisolated func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {
        Task { @MainActor in if action.conversationUUID == current?.uuid { fail("来电操作超时") }; action.fail() }
    }
    nonisolated func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in callLog.notice("didActivate 音频"); audioActive = true; routeWhenReady() }
    }
    nonisolated func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in callLog.notice("didDeactivate 音频"); audioActive = false; if current != nil { fail("系统结束了通话音频") } }
    }
}
extension Notification.Name {
    static let nativeCallRequested = Notification.Name("MemoryPalaceNativeCallRequested")
    static let nativeCallEnded = Notification.Name("MemoryPalaceNativeCallEnded")
}
#endif
