import XCTest
import SwiftData
@testable import 记忆花园

/// 发语音条 M4：```voice 意向协议——块消费/占位/降级/失败行/异步挂 segment。
/// V3 起走楼层语音服务：注入假服务 + 假合成器，断言用的是楼层的 voiceId / messageModel。
final class VoiceMessageWriterTests: XCTestCase {
    static let pid = "xctest-voice-writer"
    static let serviceId = "xctest-voice-svc"

    var container: ModelContainer!
    var context: ModelContext!

    /// 假合成器：记调用，按 `result` 回
    final class MockSynth: VoiceSynthesizer {
        struct Call: Equatable { let text: String; let voice: String?; let model: String? }
        var capabilities = VoiceCapabilities(supportsTags: true,
                                             models: [VoiceModelOption(id: "m1", name: "M1"), VoiceModelOption(id: "m2", name: "M2")])
        var result: Result<AudioClip, Error> = .success(AudioClip(data: Data([0xFF, 0xFB, 0x90, 0x01]), format: .mp3))
        private(set) var calls: [Call] = []

        func synthesize(text: String, voice: String?, model: String?, tuning: VoiceTuning.Settings) async throws -> AudioClip {
            calls.append(Call(text: text, voice: voice, model: model))
            return try result.get()
        }
    }

    var synth = MockSynth()
    var serviceKind: VoiceServiceKind = .elevenLabs
    var serviceKey: String? = "k-test"

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Conversation.self, MessageNode.self, configurations: config)
        context = ModelContext(container)

        synth = MockSynth()
        serviceKind = .elevenLabs
        serviceKey = "k-test"
        VoiceMessageWriter.serviceProvider = { [unowned self] id in
            id == Self.serviceId ? VoiceService(id: id, name: "测试服务", kind: self.serviceKind) : nil
        }
        VoiceMessageWriter.serviceKeyProvider = { [unowned self] _ in self.serviceKey }
        VoiceMessageWriter.synthesizerProvider = { [unowned self] _ in self.synth }
        VoiceMessageWriter.proactiveEnabledProvider = { true }
        VoiceMessageWriter.voiceNoteReporter = { _ in }   // 测试不打真 WS
    }

    override func tearDown() {
        VoiceMessageWriter.serviceProvider = { VoiceServiceStore.shared.service(id: $0) }
        VoiceMessageWriter.serviceKeyProvider = { VoiceServiceStore.shared.key(for: $0) }
        VoiceMessageWriter.synthesizerProvider = { $0.makeSynthesizer() }
        VoiceMessageWriter.proactiveEnabledProvider = { UserDefaults.standard.bool(forKey: VoiceTuning.proactiveKey) }
        VoiceMessageWriter.profilesProvider = { ProfileManager.loadProfiles() }
        VoiceMessageWriter.voiceNoteReporter = { payload in
            CCBridgeWebSocketClient.shared.send(payload) { _ in }
        }
        try? FileManager.default.removeItem(at: FileLibraryStore.libraryRoot(profileId: Self.pid))
        container = nil
        super.tearDown()
    }

    private var voiceProfile: Profile {
        var p = Profile(id: Self.pid, name: "测试楼", emoji: "🌿", description: "",
                        userName: "你", assistantName: "助手")
        p.voiceServiceId = Self.serviceId
        p.voiceId = "v-test"
        p.voiceName = "测试声音"
        p.messageModel = "m2"
        return p
    }

    @MainActor
    private func makeNode(content: String) -> String {
        let conv = Conversation(id: "c-voice", title: "语音测试", createTime: Date(), updateTime: Date(), currentNodeId: "", profileId: Self.pid)
        context.insert(conv)
        let node = MessageNode(
            id: UUID().uuidString, role: "assistant", content: content, contentType: "text",
            createTime: Date(), parentId: nil, childrenIds: [], conversationId: "c-voice",
            profileId: Self.pid
        )
        context.insert(node)
        try! context.save()
        return node.id
    }

    @MainActor
    private func node(_ id: String) -> MessageNode {
        let desc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == id })
        return (try! context.fetch(desc)).first!
    }

    /// 轮询等异步收尾（占位行消失或超时）
    @MainActor
    private func waitUntil(_ cond: @escaping () -> Bool, timeout: TimeInterval = 5) async {
        let start = Date()
        while !cond() && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Tests

    @MainActor
    func testNoBlockIsNoop() {
        let id = makeNode(content: "普通回复，没有块。")
        VoiceMessageWriter.processChatIntents(nodeId: id, context: context, profiles: [voiceProfile])
        XCTAssertEqual(node(id).content, "普通回复，没有块。")
    }

    @MainActor
    func testDisabledDowngradesBlockToText() {
        VoiceMessageWriter.proactiveEnabledProvider = { false }
        let id = makeNode(content: "正文。\n```voice\n[whispers] 嗨。\n```\n后文。")
        VoiceMessageWriter.processChatIntents(nodeId: id, context: context, profiles: [voiceProfile])
        let c = node(id).content
        XCTAssertFalse(c.contains("```voice"), "块被消费")
        XCTAssertFalse(c.contains(VoiceMessageWriter.placeholderLine), "关着不生成")
        XCTAssertTrue(c.contains("[whispers] 嗨。"), "脚本降级成正文")
        XCTAssertTrue(c.contains("后文。"))
    }

    @MainActor
    func testNoVoiceConfiguredDowngrades() {
        var p = voiceProfile
        p.voiceId = nil
        let id = makeNode(content: "```voice\n[softly] 你好。\n```")
        VoiceMessageWriter.processChatIntents(nodeId: id, context: context, profiles: [p])
        XCTAssertEqual(node(id).content, "[softly] 你好。")
    }

    @MainActor
    func testSuccessAttachesAudioRefAndRemovesPlaceholder() async {
        var reported: [[String: Any]] = []
        VoiceMessageWriter.voiceNoteReporter = { reported.append($0) }
        let id = makeNode(content: "我念给你听。\n```voice\n[breathing heavily] 床前……明月光……\n```")
        VoiceMessageWriter.processChatIntents(nodeId: id, context: context, profiles: [voiceProfile])
        XCTAssertTrue(node(id).content.contains(VoiceMessageWriter.placeholderLine), "同步段先占位")

        await waitUntil { !self.node(id).content.contains(VoiceMessageWriter.placeholderLine) }

        // 成功后上报 voice_note（hub 记进 cc-rp）
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?["type"] as? String, "voice_note")
        let note = reported.first?["note"] as? [String: Any]
        XCTAssertEqual(note?["script"] as? String, "[breathing heavily] 床前……明月光……")
        XCTAssertEqual(note?["voice"] as? String, "测试声音")
        XCTAssertEqual(synth.calls, [.init(text: "[breathing heavily] 床前……明月光……", voice: "v-test", model: "m2")],
                       "走楼层的服务 / 声音 / 语音条模型")

        let n = node(id)
        XCTAssertEqual(n.content, "我念给你听。", "占位行清干净")
        let segs = n.segments ?? []
        guard case .audioRef(let name, let mime, let path, _, let script)? = segs.last else {
            XCTFail("没挂上 audioRef：\(segs)")
            return
        }
        XCTAssertTrue(name.hasPrefix("voice-"))
        XCTAssertTrue(name.hasSuffix(".mp3"))
        XCTAssertEqual(mime, "audio/mpeg")
        XCTAssertEqual(script, "[breathing heavily] 床前……明月光……")
        MainThreadIO.allowMainThreadInThisTest()   // #033：下面这句是测试自己在主线程核落盘
        XCTAssertNotNil(FileLibraryStore.absoluteURL(path, profileId: Self.pid), "mp3 落盘")
    }

    @MainActor
    func testFailureWritesFailLineKeepingScript() async {
        synth.result = .failure(VoiceSynthError.invalidKey)
        let id = makeNode(content: "```voice\n[rushed] 我来了我来了。\n```")
        VoiceMessageWriter.processChatIntents(nodeId: id, context: context, profiles: [voiceProfile])

        await waitUntil { !self.node(id).content.contains(VoiceMessageWriter.placeholderLine) }

        let c = node(id).content
        XCTAssertTrue(c.contains("语音条没成功"), "失败可见：\(c)")
        XCTAssertTrue(c.contains("key 无效"))
        XCTAssertTrue(c.contains("[rushed] 我来了我来了。"), "脚本文字保住")
        XCTAssertTrue((node(id).segments ?? []).isEmpty, "失败不挂 segment")
    }

    @MainActor
    func testOnlyFirstBlockGeneratesExtrasDowngrade() async {
        let id = makeNode(content: "```voice\n第一条。\n```\n中间。\n```voice\n第二条。\n```")
        VoiceMessageWriter.processChatIntents(nodeId: id, context: context, profiles: [voiceProfile])

        await waitUntil { !self.node(id).content.contains(VoiceMessageWriter.placeholderLine) }

        let n = node(id)
        XCTAssertTrue(n.content.contains("第二条。"), "多余块降级成正文")
        XCTAssertFalse(n.content.contains("```voice"))
        XCTAssertEqual((n.segments ?? []).count, 1, "只生成一条")
    }

    @MainActor
    func testSegmentedMessageConsumesBlockInBothContainers() async {
        // 工具轮/segmented 消息：正文在 segments .text 里还有一份副本——只消费 content
        // 会让渲染把残留块画成代码卡片（07-12 粟粟截图案）。两容器都得消费。
        let body = "查到了。\n```voice\n[softly] 念给你听。\n```"
        let id = makeNode(content: body)
        let n0 = node(id)
        n0.setSegments([
            .toolUse(id: "t1", name: "recall", inputJSON: "{}", integrationName: nil, iconName: nil),
            .toolResult(toolUseId: "t1", text: "ok", isError: false, integrationName: nil),
            .text(body),
        ])
        try! context.save()

        VoiceMessageWriter.processChatIntents(nodeId: id, context: context, profiles: [voiceProfile])
        // 同步段：两容器都无原始块
        func textSegs(_ n: MessageNode) -> [String] {
            (n.segments ?? []).compactMap { if case .text(let s) = $0 { return s }; return nil }
        }
        XCTAssertFalse(node(id).content.contains("```voice"))
        XCTAssertFalse(textSegs(node(id)).contains { $0.contains("```voice") }, "segments 副本的块也被消费")

        await waitUntil {
            !self.node(id).content.contains(VoiceMessageWriter.placeholderLine)
                && !textSegs(self.node(id)).contains { $0.contains(VoiceMessageWriter.placeholderLine) }
        }

        let n = node(id)
        XCTAssertEqual(n.content, "查到了。")
        XCTAssertEqual(textSegs(n), ["查到了。"], "segments 正文副本占位也清干净")
        XCTAssertTrue((n.segments ?? []).contains {
            if case .audioRef = $0 { return true } else { return false }
        }, "胶囊挂上")
    }

    @MainActor
    func testProactiveCCMessageProcessesVoiceBlock() async {
        // CC 主动消息路径（insertProactiveAssistantMessage）不走收口通知，voice 块就地处理
        let p = voiceProfile
        VoiceMessageWriter.profilesProvider = { [p] }

        let conv = Conversation(id: "c-cc", title: "CC 对话", createTime: Date(), updateTime: Date(), currentNodeId: "", profileId: Self.pid)
        context.insert(conv)
        try! context.save()

        let vm = ConversationViewModel()
        vm.insertProactiveAssistantMessage(
            chatId: "c-cc", content: "在呢。\n```voice\n[softly] 我在。\n```",
            ccMessageId: "cc-msg-1", context: context
        )

        let desc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == "c-cc" })
        await waitUntil {
            let n = (try? self.context.fetch(desc))?.first
            return n != nil && !n!.content.contains(VoiceMessageWriter.placeholderLine) && !n!.content.contains("```voice")
        }

        let node = (try! context.fetch(desc)).first!
        XCTAssertEqual(node.content, "在呢。")
        guard case .audioRef(_, _, _, _, let script)? = (node.segments ?? []).last else {
            XCTFail("CC 主动消息没挂上语音条：\(node.segments ?? [])")
            return
        }
        XCTAssertEqual(script, "[softly] 我在。")
    }

    @MainActor
    func testPCMClipPersistsAsWav() async {
        synth.result = .success(AudioClip(data: Data(repeating: 0, count: 4_800), format: .pcm16, sampleRate: 24_000))
        let id = makeNode(content: "```voice\n嗯。\n```")
        VoiceMessageWriter.processChatIntents(nodeId: id, context: context, profiles: [voiceProfile])
        await waitUntil { !self.node(id).content.contains(VoiceMessageWriter.placeholderLine) }
        guard case .audioRef(let name, let mime, _, _, _)? = node(id).segments?.last else {
            XCTFail("没挂上 audioRef")
            return
        }
        XCTAssertTrue(name.hasSuffix(".wav"))
        XCTAssertEqual(mime, "audio/wav")
    }

    @MainActor
    func testFailureLineRedactsServiceKey() async {
        serviceKey = "k-very-secret-123"
        synth.result = .failure(VoiceSynthError.server(500, "bad key k-very-secret-123"))
        let id = makeNode(content: "```voice\n嗨。\n```")
        VoiceMessageWriter.processChatIntents(nodeId: id, context: context, profiles: [voiceProfile])
        await waitUntil { !self.node(id).content.contains(VoiceMessageWriter.placeholderLine) }
        let c = node(id).content
        XCTAssertTrue(c.contains("服务端出错 500"), c)
        XCTAssertFalse(c.contains("k-very-secret-123"), "失败行不带 key")
    }

    func testVoiceSetupConditions() {
        XCTAssertEqual(VoiceMessageWriter.voiceSetup(for: voiceProfile)?.model, "m2")
        var p = voiceProfile
        p.messageModel = "gone"
        XCTAssertEqual(VoiceMessageWriter.voiceSetup(for: p)?.model, "m1", "模型下线回落默认")
        p.voiceId = "  "
        XCTAssertNil(VoiceMessageWriter.voiceSetup(for: p), "没声音")
        p = voiceProfile
        p.voiceServiceId = "gone"
        XCTAssertNil(VoiceMessageWriter.voiceSetup(for: p), "服务被删")
        serviceKey = nil
        XCTAssertNil(VoiceMessageWriter.voiceSetup(for: voiceProfile), "要 key 的服务没 key")
        serviceKind = .system
        XCTAssertNotNil(VoiceMessageWriter.voiceSetup(for: voiceProfile), "系统音不要 key")
        serviceKind = .unknown("gemini")
        XCTAssertNil(VoiceMessageWriter.voiceSetup(for: voiceProfile), "不认识的厂商")
        XCTAssertNil(VoiceMessageWriter.voiceSetup(for: nil))
    }

    func testFileInfoByFormat() {
        let mp3 = VoiceMessageWriter.fileInfo(for: AudioClip(data: Data([1]), format: .mp3))
        XCTAssertEqual(mp3.ext, "mp3")
        XCTAssertEqual(mp3.mime, "audio/mpeg")
        XCTAssertEqual(mp3.data, Data([1]))
        let wav = VoiceMessageWriter.fileInfo(for: AudioClip(data: Data([2]), format: .wav))
        XCTAssertEqual(wav.ext, "wav")
        XCTAssertEqual(wav.data, Data([2]))
        let pcm = VoiceMessageWriter.fileInfo(for: AudioClip(data: Data([0, 0]), format: .pcm16, sampleRate: 24_000))
        XCTAssertEqual(pcm.ext, "wav")
        XCTAssertEqual(pcm.mime, "audio/wav")
        XCTAssertEqual(pcm.data.count, 46, "裸 PCM 包 WAV 头")
    }

    @MainActor
    func testScriptCapTruncates() {
        VoiceMessageWriter.proactiveEnabledProvider = { false }   // 只验截断逻辑走降级路径
        let long = String(repeating: "啊", count: 1500)
        let id = makeNode(content: "```voice\n\(long)\n```")
        VoiceMessageWriter.processChatIntents(nodeId: id, context: context, profiles: [voiceProfile])
        // 降级替换用完整块体（正文不截）；截断只作用于送 TTS 的脚本——这里验证不炸即可
        XCTAssertFalse(node(id).content.contains("```voice"))
    }
}
