import XCTest
@testable import 记忆花园

/// E1（《minis对比》洞 4）：未知 provider type 不得吃掉整张凭据表。
/// 原症状：任何一条 credential 带未知 type → 整表解码失败回空数组 → 用户看到「所有 API key 都不见了」。
final class ProviderTypeUnsupportedTests: XCTestCase {

    private func encode(_ objs: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: objs)
    }

    private func cardJSON(id: String, type: String) -> [String: Any] {
        ["id": id, "name": "卡\(id)", "emoji": "🔑", "type": type,
         "baseURL": "https://example.com/v1", "extraHeaders": [:], "models": [],
         "createdAt": 780000000.0]
    }

    // MARK: 单条

    func testUnknownTypeDecodesToUnsupportedInsteadOfThrowing() throws {
        let data = encode([cardJSON(id: "c1", type: "quantumProvider")])
        let cards = try JSONDecoder().decode([APICredential].self, from: data)
        XCTAssertEqual(cards.count, 1, "未知 type 不该让解码失败")
        XCTAssertEqual(cards[0].type, .unsupported)
        XCTAssertEqual(cards[0].unknownTypeRaw, "quantumProvider", "原始字符串要留着")
        XCTAssertFalse(cards[0].type.isUsable)
    }

    func testKnownTypesStillDecodeNormally() throws {
        let data = encode([cardJSON(id: "a", type: "openaiCompatible"),
                           cardJSON(id: "b", type: "anthropic"),
                           cardJSON(id: "c", type: "ccBridge"),
                           cardJSON(id: "d", type: "chatgptOAuth")])
        let cards = try JSONDecoder().decode([APICredential].self, from: data)
        XCTAssertEqual(cards.map(\.type), [.openaiCompatible, .anthropic, .ccBridge, .chatgptOAuth])
        XCTAssertTrue(cards.allSatisfy { $0.unknownTypeRaw == nil })
        XCTAssertTrue(cards.allSatisfy { $0.type.isUsable })
    }

    // MARK: 混表（本 bug 的核心场景）

    func testUnknownTypeDoesNotWipeOtherCards() throws {
        let data = encode([cardJSON(id: "keep1", type: "openaiCompatible"),
                           cardJSON(id: "weird", type: "somethingNew"),
                           cardJSON(id: "keep2", type: "anthropic")])
        let cards = try JSONDecoder().decode([APICredential].self, from: data)
        XCTAssertEqual(cards.count, 3, "一条未知不能吃掉整表")
        XCTAssertEqual(cards.map(\.id), ["keep1", "weird", "keep2"])
        XCTAssertEqual(cards[1].type, .unsupported)
    }

    // MARK: 往返（降级→升级不丢数据）

    func testUnknownTypeRoundTripsOriginalString() throws {
        let data = encode([cardJSON(id: "c1", type: "quantumProvider")])
        let decoded = try JSONDecoder().decode([APICredential].self, from: data)
        let reencoded = try JSONEncoder().encode(decoded)
        let obj = try JSONSerialization.jsonObject(with: reencoded) as! [[String: Any]]
        XCTAssertEqual(obj[0]["type"] as? String, "quantumProvider",
                       "encode 必须写回原始 type，不能改写成 unsupported（不可逆数据损坏）")
        // 再解一轮仍然稳定
        let again = try JSONDecoder().decode([APICredential].self, from: reencoded)
        XCTAssertEqual(again[0].type, .unsupported)
        XCTAssertEqual(again[0].unknownTypeRaw, "quantumProvider")
    }

    func testKnownTypeRoundTripUnchanged() throws {
        let data = encode([cardJSON(id: "c1", type: "anthropic")])
        let decoded = try JSONDecoder().decode([APICredential].self, from: data)
        let obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(decoded)) as! [[String: Any]]
        XCTAssertEqual(obj[0]["type"] as? String, "anthropic")
        XCTAssertNil(obj[0]["unknownTypeRaw"], "已知类型不该多写这个字段")
    }

    // MARK: 绝不降级

    func testUnsupportedIsNeverSilentlyTreatedAsOpenAI() throws {
        let data = encode([cardJSON(id: "c1", type: "wat")])
        let card = try JSONDecoder().decode([APICredential].self, from: data)[0]
        XCTAssertNotEqual(card.type, .openaiCompatible, "降级成 openaiCompatible 会把 key 发到错误端点")
        XCTAssertNotEqual(card.type, .anthropic)
    }
}
