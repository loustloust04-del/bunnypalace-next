import Foundation
import SwiftData
import Observation
import os
#if os(iOS)
import UIKit
#endif

/// 听（STT）的注入面：真机是 `CallTranscriber`，测试注 mock
@MainActor
protocol CallListener: AnyObject {
    var onPartial: (String) -> Void { get set }
    var onFinal: (String) -> Void { get set }
    var onUnavailable: (String) -> Void { get set }
    func start()
    func stop()
}

/// 说的播放端 + 挂断时关引擎：真机是 `CallSpeaker`
@MainActor
protocol CallVoiceOutput: CallAudioOutput {
    func shutdown()
}

/// 通话接线中枢（#042 plan-native-call-locked §2）：原 `CallScreen.startCall / endCall / detachSpeech` 搬过来，语义不变。
/// 建管线、挂 VM 钩子、接 STT、`session.begin` 都在这里，不依赖界面——锁屏 / 后台接原生来电时 CallScreen 可能根本没出来。
/// 原生来电：协调器在 hub accepted + 系统音频激活后调 `startNativeIfReady`；+ 号拨打：CallScreen 出现时调 `startInApp`。
/// CallScreen 只观察 `partial` / `unavailableMessage` / `fallbackNotice`。
@MainActor @Observable
final class CallController {
    /// 原生来电卡在哪一步（超时文案 + 日志）
    enum Blocker: String {
        case noHost = "app 界面没起来"
        case conversationNotLoaded = "对话没载上"
        case profileMissing = "楼层已删"
    }

    /// 接线要用的：VM + context 由 ContentView 登记，三个 manager 由 App 登记；+ 号拨打由 CallScreen 直接带进来
    struct Host {
        let viewModel: ConversationViewModel
        let modelContext: ModelContext
        let profileManager: ProfileManager?
        let providerManager: ProviderManager
        let presetManager: PresetManager?
    }

    #if os(iOS)
    static let shared = CallController(session: .shared, makeListener: { CallTranscriber() }, makeSpeaker: { CallSpeaker() })
    #endif

    private(set) var running = false
    private(set) var nativeCallID: String?
    /// 她说话的实时字幕
    private(set) var partial = ""
    private(set) var unavailableMessage: String?
    /// 转系统音的原因（通话页小字）
    private(set) var fallbackNotice: String?
    private(set) var blocker: Blocker?

    let session: CallSession
    private let makeListener: @MainActor () -> any CallListener
    private let makeSpeaker: @MainActor () -> any CallVoiceOutput
    @ObservationIgnored private weak var viewModel: ConversationViewModel?
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private weak var profileManager: ProfileManager?
    @ObservationIgnored private weak var providerManager: ProviderManager?
    @ObservationIgnored private weak var presetManager: PresetManager?
    @ObservationIgnored private weak var activeViewModel: ConversationViewModel?
    @ObservationIgnored private var listener: (any CallListener)?
    @ObservationIgnored private var speaker: (any CallVoiceOutput)?
    /// 条件没齐的原生来电：登记 / 对话载完时再试
    @ObservationIgnored private var pendingNativeCall: NativeVoiceCall?
    @ObservationIgnored private var routeRequests = 0

    init(session: CallSession, makeListener: @escaping @MainActor () -> any CallListener,
         makeSpeaker: @escaping @MainActor () -> any CallVoiceOutput) {
        self.session = session
        self.makeListener = makeListener
        self.makeSpeaker = makeSpeaker
    }

    // MARK: - 登记

    func attach(viewModel: ConversationViewModel, modelContext: ModelContext) {
        self.viewModel = viewModel
        self.modelContext = modelContext
        retryNative()
    }

    func attach(profileManager: ProfileManager, providerManager: ProviderManager, presetManager: PresetManager) {
        self.profileManager = profileManager
        self.providerManager = providerManager
        self.presetManager = presetManager
        retryNative()
    }

    private var registeredHost: Host? {
        guard let viewModel, let modelContext, let providerManager, profileManager != nil else { return nil }
        return Host(viewModel: viewModel, modelContext: modelContext, profileManager: profileManager,
                    providerManager: providerManager, presetManager: presetManager)
    }

    // MARK: - 启动

    /// 原生来电：host 已登记且对话已载上才开麦；条件不齐记卡点，等下一次触发。已在跑同一通返回 true。
    @discardableResult
    func startNativeIfReady(_ call: NativeVoiceCall) -> Bool {
        if running { return nativeCallID == call.call_id }
        if pendingNativeCall?.call_id != call.call_id { routeRequests = 0 }
        pendingNativeCall = call
        guard let host = registeredHost else { return block(.noHost) }
        guard let conversation = host.viewModel.selectedConversation, conversation.id == call.chat_id else {
            return block(.conversationNotLoaded)
        }
        // 用对话所属楼层，不用 currentProfile（调研 R1 楼层错位）
        guard let profile = host.profileManager?.profiles.first(where: { $0.id == conversation.profileId }) else {
            return block(.profileMissing)
        }
        let model = host.providerManager.resolveModel(conversationModelId: conversation.selectedModelId,
                                                      globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        start(host: host, conversation: conversation, profile: profile, model: model, nativeCallID: call.call_id)
        return true
    }

    /// 登记 / 对话载完后再试；对话还没载上就再请 ContentView 跳一次（最多 3 次，覆盖切楼层后没载对话的情况）
    func retryNative() {
        guard !running, let call = pendingNativeCall, !startNativeIfReady(call) else { return }
        guard blocker == .conversationNotLoaded, routeRequests < 3 else { return }
        routeRequests += 1
        NotificationCenter.default.post(name: .pushConversationRequested, object: nil)
    }

    /// + 号拨打：CallScreen 出现时调，模型沿用页面算好的
    @discardableResult
    func startInApp(host: Host, model: ProviderModel) -> Bool {
        guard !running, let conversation = host.viewModel.selectedConversation else { return false }
        let profile = host.profileManager.map { manager in
            manager.profiles.first(where: { $0.id == conversation.profileId }) ?? manager.currentProfile
        }
        start(host: host, conversation: conversation, profile: profile, model: model, nativeCallID: nil)
        return true
    }

    private func block(_ reason: Blocker) -> Bool {
        if blocker != reason { callLog.notice("控制器等待：\(reason.rawValue, privacy: .public)") }
        blocker = reason
        return false
    }

    private func start(host: Host, conversation: Conversation, profile: Profile?, model: ProviderModel, nativeCallID: String?) {
        let native = nativeCallID != nil
        #if os(iOS)
        CallAudioSessionController.begin(systemManaged: native)
        #endif

        let session = self.session
        let speaker = makeSpeaker()
        self.speaker = speaker
        let route = CallSpeechPipeline.Route.resolve(profile: profile)
        let pipeline = CallSpeechPipeline(route: route, output: speaker)
        pipeline.onPlaybackStarted = { session.playbackStarted() }
        pipeline.onUtterance = { session.utteranceChanged($0) }
        pipeline.onIdle = { session.playbackIdle() }
        pipeline.reportError = { [weak self] in self?.reportFallback($0) }
        session.speech = pipeline
        session.effectInstruction = profile?.voiceEffects?.callHint
        let vm = host.viewModel
        activeViewModel = vm
        vm.clearCallReplyTracking()
        vm.callReplyCanTrack = { requestId, convId in
            MainActor.assumeIsolated { session.expectsExternalReply(requestId: requestId, conversationId: convId) }
        }
        vm.callStreamHook = { event, nodeId, convId in
            MainActor.assumeIsolated {
                switch event {
                case .delta(let text): session.assistantStreamDelta(text, nodeId: nodeId, conversationId: convId)
                case .segmentBreak: session.assistantStreamSegmentBreak(nodeId: nodeId, conversationId: convId)
                case .externalReply(let text, let reply):
                    session.externalReply(text, nodeId: nodeId, conversationId: convId,
                                          requestId: reply.requestId, streaming: reply.streaming)
                }
            }
        }

        let listener = makeListener()
        self.listener = listener
        session.startListening = { listener.start() }
        session.stopListening = { listener.stop() }

        let prof = profile ?? Profile(name: "", emoji: "", description: "", userName: "你", assistantName: "AI")
        let preset = host.presetManager?.preset(byId: prof.presetId) ?? Preset.balanced
        let pm = host.providerManager
        let ctx = host.modelContext
        // CC 桥接：回复走 proactive 落地，没有流式 / 收口事件 → 按请求 id 认领
        session.replyLandsExternally = { pm.provider(for: model)?.type == .ccBridge }
        session.sentUserNodeId = { vm.currentPath.last(where: { $0.role == "user" })?.id }
        session.activeReplyNodeId = { vm.callReplyNodeId(conversationId: conversation.id) }
        session.cancelReply = { vm.cancelCallReply(conversationId: conversation.id, context: ctx) }
        session.sendUserText = { text in
            guard vm.selectedConversation?.id == conversation.id else { return false }
            vm.selectedConversation?.selectedModelId = model.id
            return vm.sendMessage(text, model: model, profile: prof, preset: preset,
                                  providerManager: pm, context: ctx, attachments: [])
        }

        listener.onPartial = { [weak self] in self?.partial = $0 }
        listener.onFinal = { [weak self] text in
            self?.partial = ""
            session.userFinalTranscript(text)
        }
        listener.onUnavailable = { [weak self] message in
            self?.unavailableMessage = message
            callLog.error("STT 不可用：\(message, privacy: .public)")
            #if os(iOS)
            if native { NativeCallCoordinator.shared.fail(message) }
            #endif
        }

        running = true
        self.nativeCallID = nativeCallID
        blocker = nil
        pendingNativeCall = nil
        partial = ""
        unavailableMessage = nil
        fallbackNotice = route.fallbackReason.map { "系统音：" + $0 }
        logRoute(route, profile: profile, model: model, native: native)

        session.begin(conversationId: conversation.id)
        #if os(iOS)
        if native {
            session.muted = NativeCallCoordinator.shared.muted
            NativeCallCoordinator.shared.controllerDidStart()
        }
        #endif
        session.turnInFlight = vm.isCurrentConvResponding
    }

    private func logRoute(_ route: CallSpeechPipeline.Route, profile: Profile?, model: ProviderModel, native: Bool) {
        let synth = route.synthesizer.map { String(describing: type(of: $0)) } ?? "system"
        let voiceModelStreaming = route.synthesizer?.capabilities.models.first { $0.id == route.model }?.streaming == true
        #if os(iOS)
        let protectedData = UIApplication.shared.isProtectedDataAvailable
        #else
        let protectedData = true
        #endif
        callLog.notice("""
            控制器启动 native=\(native, privacy: .public) profile=\(profile?.id ?? "nil", privacy: .public) \
            synth=\(synth, privacy: .public) service=\(route.serviceId ?? "nil", privacy: .public) \
            model=\(model.id, privacy: .public) voiceModel=\(route.model ?? "nil", privacy: .public) \
            voiceModelStreaming=\(voiceModelStreaming, privacy: .public) callEffects=\(route.usesEffects, privacy: .public) \
            voiceEmpty=\((route.voice ?? "").isEmpty, privacy: .public) \
            fallback=\(route.fallbackReason ?? "nil", privacy: .public) protectedData=\(protectedData, privacy: .public)
            """)
    }

    private func reportFallback(_ message: String) {
        fallbackNotice = "转系统音：" + message
        BreadcrumbLog.shared.add("🔈", "通话转系统音：\(message)")
        callLog.error("合成失败转系统音：\(message, privacy: .public)")
    }

    // MARK: - 结束

    /// 挂断 / 系统结束 / hub 结束：拆钩子、放管线、停引擎。没在跑也会清掉等待中的原生来电。
    func stop() {
        pendingNativeCall = nil
        blocker = nil
        routeRequests = 0
        guard running else { return }
        let native = nativeCallID != nil
        session.end()
        detachSpeech()
        #if os(iOS)
        CallAudioSessionController.end(systemManaged: native)
        #endif
        running = false
        nativeCallID = nil
        partial = ""
        unavailableMessage = nil
        fallbackNotice = nil
        callLog.notice("控制器停止 native=\(native, privacy: .public)")
    }

    /// 挂断后：拆钩子、放管线、停引擎（session.end 已让管线 cancel + gate reset）
    private func detachSpeech() {
        activeViewModel?.callStreamHook = nil
        activeViewModel?.callReplyCanTrack = nil
        activeViewModel?.clearCallReplyTracking()
        activeViewModel = nil
        session.sentUserNodeId = { nil }
        session.activeReplyNodeId = { nil }
        session.cancelReply = {}
        session.effectInstruction = nil
        session.sendUserText = { _ in false }
        session.replyLandsExternally = { false }
        session.startListening = {}
        session.stopListening = {}
        session.speech = nil
        speaker?.shutdown()
        speaker = nil
        listener = nil
    }
}

#if os(iOS)
extension CallTranscriber: CallListener {}
extension CallSpeaker: CallVoiceOutput {}
#endif
