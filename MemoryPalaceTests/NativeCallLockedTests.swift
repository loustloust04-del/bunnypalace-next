import XCTest
import Security
@testable import 记忆花园

/// #042 锁屏来电（plan-native-call-locked §五）：钥匙串名单 / 口令沿用 / 回落原因 / 来电上报错误码。
/// 钥匙串属性（T2–T4）是 iOS 数据保护钥匙串的行为，mac 测试宿主的老式钥匙串不认 kSecAttrAccessible，这里不测。
final class NativeCallLockedTests: XCTestCase {

    // T1
    func testAccessibleOverrideList() {
        for account in ["cc-bridge", "elevenlabs", "voice.abc"] {
            XCTAssertEqual(KeychainStore.accessibleOverride(account: account), kSecAttrAccessibleAfterFirstUnlock, account)
        }
        for account in ["cred-x", "codex-bridge", "websearch:x", "voicex"] {
            XCTAssertNil(KeychainStore.accessibleOverride(account: account), account)
        }
    }

    // T5
    func testKeepExistingToken() throws {
        let lan = try XCTUnwrap(URL(string: "ws://192.168.1.2:7890/cc"))
        let current = CCBridgeWebSocketClient.candidateURLs([lan], token: "abc", keepingTokenFrom: [])
        XCTAssertTrue(current[0].absoluteString.contains("token=abc"))

        let kept = CCBridgeWebSocketClient.candidateURLs([lan], token: nil, keepingTokenFrom: current)
        XCTAssertTrue(kept[0].absoluteString.contains("token=abc"))
        XCTAssertFalse(CCBridgeWebSocketClient.candidateURLs([lan], token: nil, keepingTokenFrom: []).first?.absoluteString.contains("token=") ?? true)

        // 只沿用同目标的口令
        let other = try XCTUnwrap(URL(string: "ws://100.64.0.9:7890/cc"))
        XCTAssertFalse(CCBridgeWebSocketClient.candidateURLs([other], token: nil, keepingTokenFrom: current)[0].absoluteString.contains("token="))
        // 传了新口令就用新的
        XCTAssertTrue(CCBridgeWebSocketClient.candidateURLs([lan], token: "new", keepingTokenFrom: current)[0].absoluteString.contains("token=new"))
    }

    // T9
    @MainActor
    func testRouteFallbackReason() throws {
        let suite = "NativeCallLockedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VoiceServiceStore(defaults: defaults, keychainService: "com.susu.MemoryPalace.tests.callroute")
        var profile = Profile(name: "楼", emoji: "", description: "", userName: "你", assistantName: "AI")

        let none = CallSpeechPipeline.Route.resolve(profile: profile, store: store, legacyKey: { nil }, legacyKeyStatus: { errSecItemNotFound })
        XCTAssertNil(none.synthesizer)
        XCTAssertEqual(none.fallbackReason, "楼层没挂语音服务")

        let system = VoiceService.blank(kind: .system)
        store.add(system)
        profile.voiceServiceId = system.id
        XCTAssertNil(CallSpeechPipeline.Route.resolve(profile: profile, store: store, legacyKey: { nil }).fallbackReason)

        profile.voiceServiceId = "gone"
        XCTAssertEqual(CallSpeechPipeline.Route.resolve(profile: profile, store: store, legacyKey: { nil }).fallbackReason, "语音服务已删或不认识")

        profile.voiceServiceId = nil
        profile.elevenVoiceId = "legacy-voice"
        let locked = CallSpeechPipeline.Route.resolve(profile: profile, store: store, legacyKey: { nil },
                                                      legacyKeyStatus: { errSecInteractionNotAllowed })
        XCTAssertNil(locked.synthesizer)
        XCTAssertTrue(locked.fallbackReason?.contains("读不到") == true, locked.fallbackReason ?? "nil")
        XCTAssertTrue(locked.fallbackReason?.contains("-25308") == true)

        let legacy = CallSpeechPipeline.Route.resolve(profile: profile, store: store, legacyKey: { "el-key" })
        XCTAssertNotNil(legacy.synthesizer)
        XCTAssertNil(legacy.fallbackReason)
    }

    // T10
    func testReportFailureMapping() {
        let domain = "com.apple.CallKit.error.incomingcall"
        let at = Date(timeIntervalSince1970: 0)
        let focus = NativeVoiceCall.reportFailureText(NSError(domain: domain, code: 3), caller: "小克", domain: domain, at: at)
        XCTAssertTrue(focus.shouldFailHub)
        XCTAssertTrue(focus.text?.hasPrefix("被专注模式拦下了：小克 \(NativeVoiceCall.clock(at))") == true, focus.text ?? "nil")
        XCTAssertTrue(NativeVoiceCall.reportFailureText(NSError(domain: domain, code: 4), caller: "小克", domain: domain).text?.hasPrefix("被来电拦截设置拦下了") == true)
        XCTAssertEqual(NativeVoiceCall.reportFailureText(NSError(domain: domain, code: 1), caller: "小克", domain: domain).text, "系统不允许这个包显示来电（权限问题）")
        let duplicate = NativeVoiceCall.reportFailureText(NSError(domain: domain, code: 2), caller: "小克", domain: domain)
        XCTAssertNil(duplicate.text)
        XCTAssertFalse(duplicate.shouldFailHub)
        for error in [NSError(domain: domain, code: 0), NSError(domain: domain, code: 7), NSError(domain: "other", code: 3)] {
            let mapped = NativeVoiceCall.reportFailureText(error, caller: "小克", domain: domain)
            XCTAssertTrue(mapped.shouldFailHub)
            XCTAssertTrue(mapped.text?.hasPrefix("系统无法显示来电：") == true)
        }
    }
}
