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

    // K3（粟粟 10-15 改）：保存前一张能用的卡都没有才接管主模型
    func testAdoptOnlyWhenNoUsableCardBefore() {
        XCTAssertTrue(ProviderManager.shouldAdopt(currentEmpty: true, currentUsable: false, hadUsableCard: false))
        XCTAssertTrue(ProviderManager.shouldAdopt(currentEmpty: false, currentUsable: false, hadUsableCard: false))
        XCTAssertFalse(ProviderManager.shouldAdopt(currentEmpty: true, currentUsable: false, hadUsableCard: true))
        XCTAssertFalse(ProviderManager.shouldAdopt(currentEmpty: false, currentUsable: false, hadUsableCard: true))
        XCTAssertFalse(ProviderManager.shouldAdopt(currentEmpty: false, currentUsable: true, hadUsableCard: true))
    }

    // F6：删掉接管的卡 → 退回接管前的主模型（还解析得到的话），否则清空
    private typealias Layer = ProviderManager.AdoptionLayer

    private func stale(_ current: String, _ stack: [Layer], alive: Set<String>) -> (next: String?, stack: [Layer]) {
        ProviderManager.staleReplacement(current: current, stack: stack, resolvable: { alive.contains($0) })
    }

    func testStaleSelectedRestoresPrevious() {
        let layer = Layer(cardId: "cred-gone", adopted: "cred-gone/test-model", previous: "cc-bridge/cc-local")
        let alive: Set<String> = ["cc-bridge/cc-local", "cred-a/gpt-4o"]
        XCTAssertEqual(stale("cred-gone/test-model", [layer], alive: alive).next, "cc-bridge/cc-local")
        XCTAssertEqual(stale("cred-gone/test-model", [layer], alive: alive).stack, [])
        XCTAssertEqual(stale("cred-gone/test-model", [layer], alive: ["cred-a/gpt-4o"]).next, "")
        XCTAssertEqual(stale("cred-gone/test-model", [], alive: alive).next, "")
        XCTAssertNil(stale("cred-a/gpt-4o", [layer], alive: alive).next)
        XCTAssertNil(stale("", [layer], alive: alive).next)
        // 主模型被手动换过（不是接管的那个）→ 不退回，那一层也不动
        let manual = stale("cred-x/other", [layer], alive: alive)
        XCTAssertEqual(manual.next, "")
        XCTAssertEqual(manual.stack, [layer])
    }

    // astra P2-1：被接管的卡换了家 → forgetModels 先清空主模型 → 同卡再接管 B/m2：退回目标仍是 A
    func testSameCardReadoptKeepsOriginalFallback() {
        var stack = ProviderManager.pushAdoption([], cardId: "cred-b", adopted: "cred-b/m1", current: "cc-bridge/cc-local")
        XCTAssertEqual(stack, [Layer(cardId: "cred-b", adopted: "cred-b/m1", previous: "cc-bridge/cc-local")])
        stack = ProviderManager.pushAdoption(stack, cardId: "cred-b", adopted: "cred-b/m2", current: "")
        XCTAssertEqual(stack, [Layer(cardId: "cred-b", adopted: "cred-b/m2", previous: "cc-bridge/cc-local")])
        // 主模型还指着这张卡的旧模型（没被清）时同理
        let again = ProviderManager.pushAdoption(stack, cardId: "cred-b", adopted: "cred-b/m3", current: "cred-b/m2")
        XCTAssertEqual(again, [Layer(cardId: "cred-b", adopted: "cred-b/m3", previous: "cc-bridge/cc-local")])
        // 删掉 B → 回 A
        XCTAssertEqual(stale("cred-b/m2", stack, alive: ["cc-bridge/cc-local"]).next, "cc-bridge/cc-local")
        // 主模型空着、别的卡没记录过 → 没东西可退，栈不动
        XCTAssertEqual(ProviderManager.pushAdoption([], cardId: "cred-c", adopted: "cred-c/x", current: ""), [])
    }

    // astra P2-2：A→B 再 B→C，删 C 回 B，再删 B 回 A；下层记录不被上层覆盖
    func testChainedAdoptionRestoresLayerByLayer() {
        var stack = ProviderManager.pushAdoption([], cardId: "cred-b", adopted: "cred-b/m", current: "cc-bridge/cc-local")
        stack = ProviderManager.pushAdoption(stack, cardId: "cred-c", adopted: "cred-c/m", current: "cred-b/m")
        XCTAssertEqual(stack.count, 2)
        let deleteC = stale("cred-c/m", stack, alive: ["cc-bridge/cc-local", "cred-b/m"])
        XCTAssertEqual(deleteC.next, "cred-b/m")
        XCTAssertEqual(deleteC.stack, [Layer(cardId: "cred-b", adopted: "cred-b/m", previous: "cc-bridge/cc-local")])
        let deleteB = stale("cred-b/m", deleteC.stack, alive: ["cc-bridge/cc-local"])
        XCTAssertEqual(deleteB.next, "cc-bridge/cc-local")
        XCTAssertEqual(deleteB.stack, [])
        // 先删了 B（主模型是 C，不动），再删 C → 顺着 B 那层退到 A
        XCTAssertNil(stale("cred-c/m", stack, alive: ["cc-bridge/cc-local", "cred-c/m"]).next)
        XCTAssertEqual(stale("cred-c/m", stack, alive: ["cc-bridge/cc-local"]).next, "cc-bridge/cc-local")
    }

    func testAdoptionStackCapped() {
        var stack: [Layer] = []
        for i in 0..<8 {
            stack = ProviderManager.pushAdoption(stack, cardId: "cred-\(i)", adopted: "cred-\(i)/m", current: "prev-\(i)")
        }
        XCTAssertEqual(stack.count, ProviderManager.adoptionStackLimit)
        XCTAssertEqual(stack.last?.cardId, "cred-7")
        XCTAssertEqual(stack.first?.cardId, "cred-3")
    }

    // 编辑器 persist 的口径：hadUsableCard = 别的卡里有任一张 isUsable。连得上 hub 的桥卡算能用 → 不接管
    func testReachableBridgeCardBlocksAdoption() {
        let reachableBridgeOnly = [usable(.ccBridge, bridge: true), usable(.openaiCompatible, example: true, key: true)]
        XCTAssertFalse(ProviderManager.shouldAdopt(currentEmpty: false, currentUsable: true,
                                                   hadUsableCard: reachableBridgeOnly.contains(true)))
        let unpairedBridgeOnly = [usable(.ccBridge, bridge: false), usable(.openaiCompatible, example: true, key: true)]
        XCTAssertTrue(ProviderManager.shouldAdopt(currentEmpty: false, currentUsable: false,
                                                  hadUsableCard: unpairedBridgeOnly.contains(true)))
    }
}
