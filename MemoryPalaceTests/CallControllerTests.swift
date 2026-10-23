import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
private final class FakeListener: CallListener {
    var onPartial: (String) -> Void = { _ in }
    var onFinal: (String) -> Void = { _ in }
    var onUnavailable: (String) -> Void = { _ in }
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor
private final class FakeSpeaker: CallVoiceOutput {
    var shutdowns = 0
    func schedulePCM(_ clip: AudioClip) throws {}
    func waitPCMDrained() async {}
    func play(_ clip: AudioClip) async throws {}
    func speakSystem(_ text: String, voice: String?) async {}
    func stop() {}
    func shutdown() { shutdowns += 1 }
}

/// #042 T6–T8：通话控制器（plan-native-call-locked §2）——条件不齐不启动 / 齐了只启动一次 / 停止拆干净。
@MainActor
final class CallControllerTests: XCTestCase {
    private var session: CallSession!
    private var listeners: [FakeListener] = []
    private var speakers: [FakeSpeaker] = []
    private var controller: CallController!
    private var root: URL!
    private var suite: String!
    private var profileManager: ProfileManager!
    private var container: ModelContainer!
    /// 控制器对 VM / manager 是弱引用（生产里由 ContentView / App 持有），测试自己拿住
    private var retained: [AnyObject] = []
    private let profile = Profile(id: "call-floor", name: "通话楼层", emoji: "", description: "", userName: "你", assistantName: "AI")

    override func setUp() async throws {
        session = CallSession()
        session.resumeDelay = .zero
        listeners = []; speakers = []
        controller = CallController(session: session,
                                    makeListener: { [unowned self] in let l = FakeListener(); listeners.append(l); return l },
                                    makeSpeaker: { [unowned self] in let s = FakeSpeaker(); speakers.append(s); return s })
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "CallControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let schema = Schema([Conversation.self, MessageNode.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        profileManager = ProfileManager(container: container, profiles: [profile], currentProfile: profile, loadError: nil,
                                        root: root.appendingPathComponent("blobs"), defaults: defaults, sideEffectsEnabled: false)
    }

    override func tearDown() async throws {
        controller.stop()
        session.end()
        retained = []
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func call(chatID: String) -> NativeVoiceCall {
        NativeVoiceCall(call_id: UUID().uuidString, chat_id: chatID, caller: "AI", created_at: 1000, expires_at: 61_000, status: "accepted")
    }

    private func conversation(profileId: String) -> Conversation {
        Conversation(id: UUID().uuidString, title: "通话", createTime: Date(), updateTime: Date(), currentNodeId: "", profileId: profileId)
    }

    private func attachHost(_ vm: ConversationViewModel, providerManager: ProviderManager) {
        let presets = PresetManager(root: root.appendingPathComponent("blobs"), defaults: UserDefaults(suiteName: suite)!)
        retained += [vm, providerManager, presets]
        controller.attach(viewModel: vm, modelContext: ModelContext(container))
        controller.attach(profileManager: profileManager, providerManager: providerManager, presetManager: presets)
    }

    // T6
    func testNotReadyDoesNotStart() {
        let conv = conversation(profileId: profile.id)
        XCTAssertFalse(controller.startNativeIfReady(call(chatID: conv.id)))
        XCTAssertFalse(controller.running)
        XCTAssertEqual(controller.blocker, .noHost)

        let vm = ConversationViewModel()
        vm.selectedConversation = conversation(profileId: profile.id)
        attachHost(vm, providerManager: ProviderManager())
        XCTAssertFalse(controller.startNativeIfReady(call(chatID: conv.id)))
        XCTAssertFalse(controller.running)
        XCTAssertEqual(controller.blocker, .conversationNotLoaded)

        let orphan = conversation(profileId: "deleted-floor")
        vm.selectedConversation = orphan
        XCTAssertFalse(controller.startNativeIfReady(call(chatID: orphan.id)))
        XCTAssertEqual(controller.blocker, .profileMissing)
        XCTAssertTrue(listeners.isEmpty)
        XCTAssertFalse(session.active)
    }

    // T7
    func testReadyStartsOnce() {
        let vm = ConversationViewModel()
        let conv = conversation(profileId: profile.id)
        vm.selectedConversation = conv
        attachHost(vm, providerManager: ProviderManager())
        let incoming = call(chatID: conv.id)
        XCTAssertTrue(controller.startNativeIfReady(incoming))
        XCTAssertTrue(controller.running)
        XCTAssertEqual(controller.nativeCallID, incoming.call_id)
        XCTAssertNil(controller.blocker)
        XCTAssertTrue(session.active)
        XCTAssertEqual(session.conversationId, conv.id)
        XCTAssertEqual(listeners.count, 1)
        XCTAssertEqual(listeners.first?.starts, 1)

        XCTAssertTrue(controller.startNativeIfReady(incoming))
        controller.retryNative()
        XCTAssertEqual(listeners.count, 1)
        XCTAssertEqual(listeners.first?.starts, 1)
        XCTAssertFalse(controller.startNativeIfReady(call(chatID: conv.id)), "别的来电不能顶掉正在跑的")
    }

    // T8
    func testStopTearsDown() {
        let vm = ConversationViewModel()
        let conv = conversation(profileId: profile.id)
        vm.selectedConversation = conv
        attachHost(vm, providerManager: ProviderManager())
        XCTAssertTrue(controller.startNativeIfReady(call(chatID: conv.id)))
        XCTAssertNotNil(vm.callStreamHook)
        XCTAssertNotNil(vm.callReplyCanTrack)

        controller.stop()
        XCTAssertNil(vm.callStreamHook)
        XCTAssertNil(vm.callReplyCanTrack)
        XCTAssertFalse(session.active)
        XCTAssertNil(session.speech)
        XCTAssertFalse(controller.running)
        XCTAssertNil(controller.nativeCallID)
        XCTAssertEqual(speakers.first?.shutdowns, 1)
        XCTAssertEqual(listeners.first?.stops, 1)
        XCTAssertFalse(session.sendUserText("hi"))
    }
}
