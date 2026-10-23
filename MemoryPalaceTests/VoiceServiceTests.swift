import XCTest
import AVFoundation
@testable import 记忆花园

/// plan-voice-providers V1a/V1b：语音服务配置 Codable、Store 增删改 + key、去 key、协议小件。
/// 全部用独立 UserDefaults suite + 独立钥匙串 service，不碰真条目。
final class VoiceServiceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var keychainService = ""

    override func setUp() {
        super.setUp()
        suiteName = "VoiceServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        keychainService = "com.susu.MemoryPalace.test.voice-\(UUID().uuidString)"
    }

    override func tearDown() {
        for account in KeychainStore.allAccounts(service: keychainService) {
            KeychainStore.remove(account: account, service: keychainService)
        }
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> VoiceServiceStore {
        VoiceServiceStore(defaults: defaults, keychainService: keychainService)
    }

    // MARK: - Codable

    func testServiceRoundtripKeepsVendorOptions() throws {
        var s = VoiceService.blank(kind: .miniMax)
        s.name = "MiniMax 中文"
        s.baseURL = "https://api.minimax.io/v1"
        s.miniMaxOptions.groupId = "g-123"
        let back = try JSONDecoder().decode(VoiceService.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.kind, .miniMax)
        XCTAssertEqual(back.miniMaxOptions.groupId, "g-123")
        XCTAssertNil(back.openAICompatible)
    }

    func testUnknownKindDecodesAndKeepsRawValue() throws {
        let json = """
        [{"id":"a","name":"未来厂商","kind":"gemini","baseURL":null,"someNewField":{"x":1}},
         {"id":"b","name":"系统","kind":"system"}]
        """
        let list = try JSONDecoder().decode([VoiceService].self, from: Data(json.utf8))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].kind, .unknown("gemini"))
        XCTAssertEqual(list[1].kind, .system)
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(list[0])) as? [String: Any]
        XCTAssertEqual(reencoded?["kind"] as? String, "gemini")
        XCTAssertThrowsError(try awaitResult { try await list[0].makeSynthesizer(store: self.makeStore())
            .synthesize(text: "x", voice: nil, model: nil, tuning: VoiceTuning.current()) }) { err in
            XCTAssertEqual(err as? VoiceSynthError, .notSupported)
        }
    }

    func testBlankCarriesDefaultOptions() {
        XCTAssertEqual(VoiceService.blank(kind: .openAICompatible).openAICompatible?.models, OpenAICompatibleOptions.defaultModels)
        XCTAssertNotNil(VoiceService.blank(kind: .miniMax).miniMax)
        XCTAssertNil(VoiceService.blank(kind: .elevenLabs).miniMax)
    }

    // MARK: - Store

    func testStoreAddUpdateDeletePersists() {
        let store = makeStore()
        let s = VoiceService(id: "s1", name: "甲", kind: .system)
        store.add(s)
        XCTAssertEqual(makeStore().services.map(\.id), ["s1"], "列表落 UserDefaults，新实例读得回")

        var edited = s
        edited.name = "乙"
        store.update(edited)
        XCTAssertEqual(makeStore().service(id: "s1")?.name, "乙")

        store.update(VoiceService(id: "nope", name: "x", kind: .system))
        XCTAssertEqual(store.services.count, 1, "更新不存在的 id 不新增")

        store.delete(id: "s1")
        XCTAssertTrue(makeStore().services.isEmpty)
    }

    func testKeyStoredPerServiceAndRemovedOnDelete() {
        let store = makeStore()
        let s = VoiceService(id: "k1", name: "OA", kind: .openAICompatible)
        store.add(s, key: "  sk-test-000111  ")
        XCTAssertEqual(store.key(for: "k1"), "sk-test-000111", "去首尾空白")
        XCTAssertEqual(KeychainStore.get(account: "voice.k1", service: keychainService), "sk-test-000111")
        XCTAssertNil(KeychainStore.get(account: VoiceTuning.keychainAccount, service: keychainService),
                     "非 ElevenLabs 不写老 account")

        store.setKey("", for: s)
        XCTAssertNil(store.key(for: "k1"), "空串 = 删 key")

        store.setKey("again", for: s)
        store.delete(id: "k1")
        XCTAssertNil(store.key(for: "k1"), "删服务连 key 一起删")
    }

    func testElevenLabsKeyMirrorsLegacyAccountUnlessDisabled() {
        let store = makeStore()
        let s = VoiceService(id: "el", name: "EL", kind: .elevenLabs)
        store.add(s, key: "el-key-1")
        XCTAssertEqual(KeychainStore.get(account: VoiceTuning.keychainAccount, service: keychainService), "el-key-1")

        store.setKey("el-key-2", for: s, mirrorLegacy: false)
        XCTAssertEqual(store.key(for: "el"), "el-key-2")
        XCTAssertEqual(KeychainStore.get(account: VoiceTuning.keychainAccount, service: keychainService), "el-key-1")
    }

    // MARK: - 去 key

    func testRedactStripsKnownSecretsAndTokenShapes() {
        let secret = "abcd1234SECRET"
        let raw = "401 invalid key abcd1234SECRET; Authorization: Bearer eyJhbGciOi.x-y; xi-api-key: zzzz9999; key=sk-proj-AbC123xyz"
        let out = VoiceServiceStore.redact(raw, secrets: [secret])
        XCTAssertFalse(out.contains(secret))
        XCTAssertFalse(out.contains("eyJhbGciOi"))
        XCTAssertFalse(out.contains("zzzz9999"))
        XCTAssertFalse(out.contains("AbC123xyz"))
        XCTAssertTrue(out.contains("401 invalid key"), "正文留着：\(out)")
    }

    func testRedactIgnoresTooShortSecrets() {
        XCTAssertEqual(VoiceServiceStore.redact("a b c", secrets: ["a", ""]), "a b c")
    }

    func testErrorMessageRedactsThisServicesKey() {
        let store = makeStore()
        let s = VoiceService(id: "e1", name: "OA", kind: .openAICompatible)
        store.add(s, key: "plainkey-778899")
        let msg = store.errorMessage(VoiceSynthError.server(400, "bad credential plainkey-778899"), serviceId: "e1")
        XCTAssertFalse(msg.contains("plainkey-778899"))
        XCTAssertTrue(msg.hasPrefix("服务端出错 400"))
    }

    // MARK: - 楼层写入（过渡期双写老字段）

    func testSetVoiceMirrorsLegacyFieldsOnlyForElevenLabs() {
        var p = Profile(id: "p", name: "楼", emoji: "🌿", description: "", userName: "你", assistantName: "助手")
        let el = VoiceService(id: "el", name: "EL", kind: .elevenLabs)
        let mm = VoiceService(id: "mm", name: "MM", kind: .miniMax)

        p.setVoice(service: el, voiceId: " v1 ", voiceName: "暖暖")
        p.messageModel = "eleven_v3"
        XCTAssertEqual(p.voiceServiceId, "el")
        XCTAssertEqual(p.voiceId, "v1")
        XCTAssertEqual(p.elevenVoiceId, "v1")
        XCTAssertEqual(p.elevenVoiceName, "暖暖")

        p.setVoice(service: el, voiceId: "v2", voiceName: nil)
        XCTAssertEqual(p.messageModel, "eleven_v3", "同服务换声音不动模型")
        XCTAssertEqual(p.voiceName, "v2", "没名字用 id 顶")

        p.setVoice(service: mm, voiceId: nil, voiceName: nil)
        XCTAssertEqual(p.voiceServiceId, "mm")
        XCTAssertNil(p.voiceId)
        XCTAssertNil(p.messageModel, "换服务模型回落默认")
        XCTAssertNil(p.elevenVoiceId, "非 ElevenLabs 清老字段")

        p.setVoice(service: nil, voiceId: "x", voiceName: "x")
        XCTAssertNil(p.voiceServiceId)
    }

    // MARK: - 协议小件

    func testCapabilitiesResolveModelAndTunables() {
        let caps = VoiceCapabilities(tunables: [.stability, .style],
                                     models: [VoiceModelOption(id: "a", name: "A"),
                                              VoiceModelOption(id: "b", name: "B", tunables: [.stability])])
        XCTAssertEqual(caps.resolvedModel("b"), "b")
        XCTAssertEqual(caps.resolvedModel("gone"), "a")
        XCTAssertEqual(caps.resolvedModel(nil), "a")
        XCTAssertEqual(caps.tunables(for: "b"), [.stability])
        XCTAssertEqual(caps.tunables(for: "a"), [.stability, .style])
        XCTAssertNil(VoiceCapabilities().resolvedModel("x"))
    }

    func testPCMClipWrapsIntoWav() {
        let pcm = Data(repeating: 0, count: 480)
        let clip = AudioClip(data: pcm, format: .pcm16, sampleRate: 24_000)
        let wav = clip.playableData
        XCTAssertEqual(wav.count, 44 + 480)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        let mp3 = AudioClip(data: Data([1, 2, 3]), format: .mp3)
        XCTAssertEqual(mp3.playableData, Data([1, 2, 3]))
    }

    func testFactoryRoutesByKind() {
        let store = makeStore()
        XCTAssertTrue(VoiceService(name: "s", kind: .system).makeSynthesizer(store: store) is SystemSynthesizer)
        XCTAssertTrue(VoiceService(name: "e", kind: .elevenLabs).makeSynthesizer(store: store) is ElevenLabsSynthesizer)
        XCTAssertTrue(VoiceService.blank(kind: .miniMax).makeSynthesizer(store: store) is MiniMaxSynthesizer)
        XCTAssertTrue(VoiceService(name: "u", kind: .unknown("x")).makeSynthesizer(store: store) is UnsupportedVoiceSynthesizer)
        let oa = VoiceService.blank(kind: .openAICompatible).makeSynthesizer(store: store)
        XCTAssertTrue(oa is OpenAICompatibleSynthesizer)
        XCTAssertEqual(oa.capabilities.models.map(\.id), OpenAICompatibleOptions.defaultModels)
        XCTAssertNil(oa.openStream(voice: nil, model: nil))
    }

    func testElevenLabsWithoutKeyThrowsMissingKey() {
        let synth = VoiceService(name: "e", kind: .elevenLabs).makeSynthesizer(store: makeStore())
        XCTAssertThrowsError(try awaitResult { try await synth.fetchVoices() }) { err in
            XCTAssertEqual(err as? VoiceSynthError, .missingKey)
        }
    }

    /// 系统音真渲染：mac 测试宿主上 AVSpeechSynthesizer.write 能出 WAV
    func testSystemSynthesizerRendersWav() async throws {
        try XCTSkipIf(AVSpeechSynthesisVoice.speechVoices().isEmpty, "没有系统声音")
        let exp = expectation(description: "system render")
        let box = ResultBox()
        Task {
            do {
                box.clip = try await SystemSynthesizer().synthesize(text: "你好，这是试听。", voice: nil, model: nil,
                                                                    tuning: VoiceTuning.current())
            } catch {
                box.error = error
            }
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 30)
        XCTAssertNil(box.error)
        let clip = try XCTUnwrap(box.clip)
        XCTAssertEqual(clip.format, .wav)
        XCTAssertGreaterThan(clip.data.count, 1_000)
        XCTAssertNotNil(try? AVAudioPlayer(data: clip.playableData), "AVAudioPlayer 能吃")
    }

    func testSystemVoicesListed() async throws {
        let voices = try await SystemSynthesizer().fetchVoices()
        XCTAssertEqual(voices.count, AVSpeechSynthesisVoice.speechVoices().count)
    }

    // MARK: - helpers

    private final class ResultBox {
        var clip: AudioClip?
        var error: Error?
    }

    /// 同步测试里跑一个 async throws（只用于立刻返回 / 立刻抛的调用）
    private func awaitResult<T>(_ body: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task.detached {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }
}
