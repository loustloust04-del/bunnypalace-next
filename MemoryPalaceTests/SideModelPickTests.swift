import XCTest
@testable import 记忆花园

/// 后台副调用挑模型（体检 L-B3 / L-B4）：只测纯函数，不 new ProviderManager（init 会写 UserDefaults.standard）。
final class SideModelPickTests: XCTestCase {
    private func card(_ id: String, _ type: ProviderType) -> APICredential {
        APICredential(id: id, name: id, emoji: "🧪", type: type, baseURL: "https://example.invalid",
                      models: [ProviderModel(credentialId: id, modelId: "m", name: "m")])
    }

    private func pick(_ ids: [String], cards: [APICredential], usable: Set<String>) -> String? {
        let models = Dictionary(uniqueKeysWithValues: cards.map { ($0.models[0].id, $0.models[0]) })
        return ProviderManager.pickSideModel(ids: ids, model: { models[$0] },
                                             credential: { id in cards.first { $0.id == id } },
                                             usable: { usable.contains($0.id) })?.credentialId
    }

    func testSkipsNonStreamingIncapableCardsInOrder() {
        let cards = [card("bridge", .ccBridge), card("local", .localMLX), card("odd", .unsupported), card("cloud", .anthropic)]
        let all = Set(cards.map(\.id))
        XCTAssertEqual(pick(cards.map { $0.models[0].id }, cards: cards, usable: all), "cloud", "桥卡 / 本机卡 / 不认识的卡都跳过")
    }

    func testUnusableCardFallsThroughToNextCandidate() {
        let cards = [card("nokey", .openaiCompatible), card("oauth", .chatgptOAuth)]
        XCTAssertEqual(pick(cards.map { $0.models[0].id }, cards: cards, usable: ["oauth"]), "oauth", "没 key 的卡退下一个候选")
        XCTAssertNil(pick(cards.map { $0.models[0].id }, cards: cards, usable: []), "都发不出去 → nil，不兜底")
    }

    func testEmptyAndUnknownIdsIgnored() {
        let cards = [card("cloud", .openaiCompatible)]
        XCTAssertEqual(pick(["", "gone/m", cards[0].models[0].id], cards: cards, usable: ["cloud"]), "cloud")
        XCTAssertNil(pick([], cards: cards, usable: ["cloud"]))
    }
}
