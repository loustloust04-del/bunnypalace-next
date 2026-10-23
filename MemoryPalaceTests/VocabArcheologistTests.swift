import XCTest
@testable import 记忆花园

/// #054 考古 App 路：提示词进包、请求格式、成功门槛、模型选择、路由默认值。不发网络。
@MainActor
final class VocabArcheologistTests: XCTestCase {

    func testSystemPromptShipsInBundle() throws {
        let prompt = try XCTUnwrap(VocabArcheologist.systemPrompt(), "App 包里没有考古提示词")
        XCTAssertTrue(prompt.hasPrefix("# 语言考古学家"))
        XCTAssertTrue(prompt.contains("一句话本质"))
    }

    func testUserMessageMatchesNightlyScript() {
        XCTAssertEqual(VocabArcheologist.userMessage(word: "ephemeral"), "本轮要考古的单词：ephemeral")
    }

    func testAcceptNeedsMoreThan500Bytes() {
        XCTAssertNil(VocabArcheologist.accept(String(repeating: "a", count: 500)))
        XCTAssertNil(VocabArcheologist.accept("  \n" + String(repeating: "a", count: 500) + "\n  "))
        XCTAssertEqual(VocabArcheologist.accept(String(repeating: "a", count: 501)), String(repeating: "a", count: 501))
        // 中文按字节算：167 字 × 3B = 501B
        XCTAssertNotNil(VocabArcheologist.accept(String(repeating: "词", count: 167)))
    }

    func testRouteDefault() {
        let key = VocabArcheologyRoute.storageKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #if PERSONAL_APPS
        XCTAssertEqual(VocabArcheologyRoute.current, .mac, "私用版默认要和以前一样走 Mac")
        UserDefaults.standard.set("app", forKey: key)
        XCTAssertEqual(VocabArcheologyRoute.current, .app)
        #else
        UserDefaults.standard.set("mac", forKey: key)
        XCTAssertEqual(VocabArcheologyRoute.current, .app, "开源版只有 App 路")
        #endif
    }

    func testResolveModelSkipsBridgeAndLocalThenFallsBack() throws {
        let suite = "xctest-vocab-archeology-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let pm = ProviderManager()
        let bridge = credential(id: "xctest-arch-bridge", type: .ccBridge)
        let cloud = credential(id: "xctest-arch-cloud", type: .anthropic)
        pm.addCredential(bridge)
        pm.addCredential(cloud)
        defer {
            pm.removeCredential(id: bridge.id)
            pm.removeCredential(id: cloud.id)
        }

        XCTAssertNil(VocabArcheologist.resolveModel(providerManager: pm, defaults: defaults), "都没配 → nil")

        defaults.set(bridge.models[0].id, forKey: "selectedChatModel")
        XCTAssertNil(VocabArcheologist.resolveModel(providerManager: pm, defaults: defaults), "聊天模型是 CC、没副模型 → nil")

        defaults.set(cloud.models[0].id, forKey: "memoryExtractModelId")
        XCTAssertEqual(VocabArcheologist.resolveModel(providerManager: pm, defaults: defaults)?.id, cloud.models[0].id, "CC 跳过，退副模型")

        defaults.set(cloud.models[0].id, forKey: "selectedChatModel")
        defaults.set(bridge.models[0].id, forKey: "memoryExtractModelId")
        XCTAssertEqual(VocabArcheologist.resolveModel(providerManager: pm, defaults: defaults)?.id, cloud.models[0].id, "聊天模型能用就用它")
    }

    private func credential(id: String, type: ProviderType) -> APICredential {
        APICredential(id: id, name: id, emoji: "🧪", type: type, baseURL: "https://example.invalid",
                      models: [ProviderModel(credentialId: id, modelId: "m", name: "m")])
    }
}
