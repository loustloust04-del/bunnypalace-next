import XCTest
@testable import 记忆花园

/// atrium P3①：主对话模型三层回退 对话 → 这个人（Profile.preferredModel）→ 全局
final class ResolveModelTiersTests: XCTestCase {
    private var pm: ProviderManager!
    private var credentialId = ""
    private var conv: ProviderModel!
    private var person: ProviderModel!
    private var global: ProviderModel!

    override func setUp() {
        super.setUp()
        credentialId = "xctest-resolve-tiers-\(UUID().uuidString)"
        conv = ProviderModel(credentialId: credentialId, modelId: "conv-model", name: "对话的")
        person = ProviderModel(credentialId: credentialId, modelId: "person-model", name: "人的")
        global = ProviderModel(credentialId: credentialId, modelId: "global-model", name: "全局的")
        pm = ProviderManager()
        pm.addCredential(APICredential(id: credentialId, name: "三层", emoji: "🧪", type: .openaiCompatible,
                                       baseURL: "http://127.0.0.1:9", models: [conv, person, global]))
    }

    override func tearDown() {
        pm.removeCredential(id: credentialId)
        pm = nil
        super.tearDown()
    }

    func testConversationWins() {
        XCTAssertEqual(pm.resolveModel(conversationModelId: conv.id, profileModelId: person.id, globalFallbackId: global.id).id, conv.id)
    }

    func testEmptyConversationFallsToPerson() {
        XCTAssertEqual(pm.resolveModel(conversationModelId: "", profileModelId: person.id, globalFallbackId: global.id).id, person.id)
        XCTAssertEqual(pm.resolveModel(conversationModelId: nil, profileModelId: person.id, globalFallbackId: global.id).id, person.id)
    }

    func testBothEmptyFallsToGlobal() {
        XCTAssertEqual(pm.resolveModel(conversationModelId: "", profileModelId: "", globalFallbackId: global.id).id, global.id)
        XCTAssertEqual(pm.resolveModel(conversationModelId: nil, profileModelId: nil, globalFallbackId: global.id).id, global.id)
    }

    /// 老用户每层存的是 M1 前的老格式默认值（`anthropic/claude-sonnet-4`），解析不出 = 当空，行为和升级前一样走全局
    func testUnresolvablePersonModelFallsToGlobal() {
        XCTAssertEqual(pm.resolveModel(conversationModelId: "", profileModelId: "anthropic/claude-sonnet-4", globalFallbackId: global.id).id, global.id)
        XCTAssertEqual(pm.resolveModel(conversationModelId: "", profileModelId: "\(credentialId)/deleted", globalFallbackId: global.id).id, global.id)
    }

    func testNewProfileDefaultsToFollowingGlobal() {
        XCTAssertEqual(Profile(name: "新人", emoji: "", description: "", userName: "你", assistantName: "").preferredModel, "")
    }
}
