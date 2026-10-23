import XCTest
@testable import 记忆花园

/// #092 D：选择器 / 兜底 / 新卡接管主模型共用的「能不能用」判定和自动挑模型。只测静态纯函数，不 new ProviderManager
/// （它的 init 会写 UserDefaults.standard，测试宿主跑在真偏好上）。
final class ModelUsabilityTests: XCTestCase {
    private func usable(_ type: ProviderType, example: Bool = false, key: Bool = false,
                        local: Bool = false, bridge: Bool = false) -> Bool {
        ProviderManager.isUsable(type: type, isExample: example, hasKey: key,
                                 hasInstalledLocalModel: local, bridgeReachable: bridge)
    }

    func testExampleCardNeverUsable() {
        XCTAssertFalse(usable(.openaiCompatible, example: true, key: true))
    }

    func testNetworkCardsNeedKey() {
        XCTAssertTrue(usable(.openaiCompatible, key: true))
        XCTAssertTrue(usable(.anthropic, key: true))
        XCTAssertFalse(usable(.openaiCompatible))
        XCTAssertFalse(usable(.chatgptOAuth))
    }

    func testBridgeNeedsReachableHub() {
        XCTAssertFalse(usable(.ccBridge))
        XCTAssertTrue(usable(.ccBridge, bridge: true))
    }

    func testLocalNeedsInstalledModel() {
        XCTAssertFalse(usable(.localMLX))
        XCTAssertTrue(usable(.localMLX, local: true))
        XCTAssertFalse(usable(.unsupported, key: true))
    }

    func testAutoPickPrefersPresetFirstThenChatModel() {
        let ms = ["text-embedding-3-small", "gpt-4o", "gpt-4o-mini"].map { ProviderModel(credentialId: "c", modelId: $0, name: $0) }
        XCTAssertEqual(ProviderManager.autoPickModel(ms, presetFirst: "gpt-4o-mini")?.modelId, "gpt-4o-mini")
        XCTAssertEqual(ProviderManager.autoPickModel(ms, presetFirst: "gone")?.modelId, "gpt-4o")
        XCTAssertEqual(ProviderManager.autoPickModel(ms, presetFirst: nil)?.modelId, "gpt-4o")
        XCTAssertNil(ProviderManager.autoPickModel([], presetFirst: nil))
    }
}
