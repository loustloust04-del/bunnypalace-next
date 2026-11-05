import XCTest
@testable import 记忆花园

/// 卡上的 regionId + 区域反查 + 编辑页装载老卡（plan-provider-presets §2.2 / §2.3 / §4 / §5.2）
final class APICredentialRegionTests: XCTestCase {

    private func card(preset: String?, type: ProviderType = .openaiCompatible, baseURL: String,
                      regionId: String? = nil, id: String = "cred-1") -> APICredential {
        APICredential(id: id, name: "卡", emoji: "🍐", presetId: preset, type: type, baseURL: baseURL, regionId: regionId)
    }

    private func decode(_ json: String) throws -> APICredential {
        try JSONDecoder().decode(APICredential.self, from: Data(json.utf8))
    }

    /// 两个区域的测试预设：默认「按量」，第二个「套餐」
    private let twoRegions = APIProvider(
        id: "t", name: "T", group: .domestic,
        regions: [
            PresetRegion(id: "payg", name: "按量", endpoints: [.openaiCompatible: "https://api.t.example/v1", .anthropic: "https://api.t.example/anthropic/v1"]),
            PresetRegion(id: "plan", name: "套餐", endpoints: [.openaiCompatible: "https://api.t.example/coding/v1"]),
        ],
        defaultProtocol: .openaiCompatible
    )

    // MARK: 编解码

    func testOldJSONWithoutRegionIdDecodesNil() throws {
        let c = try decode(#"{"id":"cred-1","name":"老卡","emoji":"🍋","presetId":"deepseek","type":"openaiCompatible","baseURL":"https://api.deepseek.com/v1"}"#)
        XCTAssertNil(c.regionId)
        XCTAssertEqual(c.presetId, "deepseek")
    }

    func testRegionIdRoundTrips() throws {
        let original = card(preset: "zhipu", baseURL: "https://open.bigmodel.cn/api/paas/v4", regionId: "payg")
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(APICredential.self, from: data).regionId, "payg")
        let noRegion = try JSONEncoder().encode(card(preset: nil, baseURL: "https://x.example/v1"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: noRegion) as? [String: Any])
        XCTAssertNil(obj["regionId"], "没有区域就不写这个 key")
    }

    func testUnsupportedCardKeepsRawTypeAndRegionId() throws {
        let c = try decode(#"{"id":"cred-9","name":"新版卡","presetId":"openai","type":"futureType","baseURL":"https://x.example","regionId":"r9"}"#)
        XCTAssertEqual(c.type, .unsupported)
        XCTAssertEqual(c.regionId, "r9")
        XCTAssertNil(APIProvider.openai.resolveRegion(for: c))
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
        XCTAssertEqual(back["type"] as? String, "futureType")
        XCTAssertEqual(back["regionId"] as? String, "r9")
    }

    // MARK: resolveRegion

    func testRegionIdHitWins() {
        let c = card(preset: "t", baseURL: "https://api.t.example/v1", regionId: "plan")
        XCTAssertEqual(twoRegions.resolveRegion(for: c)?.id, "plan")
    }

    func testUnknownRegionIdFallsBackToURL() {
        let c = card(preset: "t", baseURL: "https://api.t.example/coding/v1", regionId: "gone")
        XCTAssertEqual(twoRegions.resolveRegion(for: c)?.id, "plan")
    }

    func testURLHitsNonDefaultRegionAfterNormalizing() {
        let c = card(preset: "t", baseURL: "api.t.example/coding/v1/chat/completions/")
        XCTAssertEqual(twoRegions.resolveRegion(for: c)?.id, "plan")
    }

    func testURLMatchesOnlyTheCardsFormat() {
        let anthropicCard = card(preset: "t", type: .anthropic, baseURL: "https://api.t.example/anthropic/v1")
        XCTAssertEqual(twoRegions.resolveRegion(for: anthropicCard)?.id, "payg")
        let wrongFormat = card(preset: "t", type: .anthropic, baseURL: "https://api.t.example/coding/v1")
        XCTAssertNil(twoRegions.resolveRegion(for: wrongFormat))
    }

    func testEditedAddressResolvesNil() {
        XCTAssertNil(twoRegions.resolveRegion(for: card(preset: "t", baseURL: "https://relay.example.com/v1")))
    }

    func testEveryOldPresetCardResolvesToDefaultRegion() {
        for p in APIProvider.presets where !p.baseURL.isEmpty {
            let c = card(preset: p.id, type: p.type, baseURL: BaseURLNormalizer.normalize(p.baseURL, type: p.type))
            XCTAssertEqual(p.resolveRegion(for: c)?.id, p.defaultRegion.id, p.id)
        }
    }

    // MARK: 编辑页装载老卡（CredentialDraft.loaded）

    func testOldPresetCardLoadsDefaultRegionUnchanged() {
        let c = card(preset: "deepseek", baseURL: "https://api.deepseek.com/v1")
        let d = CredentialDraft.loaded(from: c)
        XCTAssertEqual(d.regionSelection, "default")
        XCTAssertFalse(d.usesOwnBaseURL)
        XCTAssertEqual(d.type, .openaiCompatible)
        XCTAssertEqual(d.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(d.makeCredential(id: c.id, existing: c).regionId, "default", "保存时把区域写进卡")
    }

    func testPresetCardWithOwnAddressKeepsIt() {
        let c = card(preset: "deepseek", type: .anthropic, baseURL: "https://relay.example.com/anthropic/v1")
        let d = CredentialDraft.loaded(from: c)
        XCTAssertEqual(d.regionSelection, CredentialDraft.ownRegion)
        XCTAssertTrue(d.usesOwnBaseURL)
        XCTAssertEqual(d.type, .anthropic)
        XCTAssertEqual(d.baseURL, "https://relay.example.com/anthropic/v1")
        let saved = d.makeCredential(id: c.id, existing: c)
        XCTAssertEqual(saved.baseURL, "https://relay.example.com/anthropic/v1")
        XCTAssertEqual(saved.type, .anthropic)
        XCTAssertNil(saved.regionId)
        XCTAssertEqual(saved.presetId, "deepseek")
    }

    func testOwnAddressKeepsUnknownRegionIdFromNewerVersion() {
        let c = card(preset: "deepseek", baseURL: "https://relay.example.com/v1", regionId: "future-region")
        let d = CredentialDraft.loaded(from: c)
        XCTAssertTrue(d.usesOwnBaseURL)
        XCTAssertEqual(d.makeCredential(id: c.id, existing: c).regionId, "future-region")
    }

    /// claude-p 的地址靠发现填：已存的卡在编辑页仍按预设的空地址算，能不能存和改前一样
    func testClaudePCardNotTreatedAsOwnAddress() {
        let c = card(preset: "claude-p", type: .anthropic, baseURL: "http://192.168.1.8:8790/v1")
        let d = CredentialDraft.loaded(from: c)
        XCTAssertFalse(d.usesOwnBaseURL)
        XCTAssertEqual(d.baseURL, "")
        XCTAssertEqual(d.type, .anthropic)
    }

    func testOllamaCardStillEditsItsOwnAddress() {
        let c = card(preset: "ollama", baseURL: "http://192.168.1.5:11434/v1")
        let d = CredentialDraft.loaded(from: c)
        XCTAssertFalse(d.usesOwnBaseURL)
        XCTAssertEqual(d.baseURL, "http://192.168.1.5:11434/v1")
    }

    func testBridgeAndAccountCardsUnaffected() {
        let bridge = card(preset: "cc-bridge", type: .ccBridge, baseURL: "ws://10.0.0.2:7890/cc", id: "cc-bridge")
        let b = CredentialDraft.loaded(from: bridge)
        XCTAssertFalse(b.usesOwnBaseURL)
        XCTAssertEqual(b.baseURL, "ws://127.0.0.1:7890/cc")
        let gpt = card(preset: "chatgpt-oauth", type: .chatgptOAuth, baseURL: "https://chatgpt.com/backend-api/codex", id: "chatgpt-oauth")
        XCTAssertEqual(CredentialDraft.loaded(from: gpt).type, .chatgptOAuth)
    }

    func testUnsupportedPresetCardNotOwnAddress() throws {
        let c = try decode(#"{"id":"cred-9","name":"新版卡","presetId":"openai","type":"futureType","baseURL":"https://x.example"}"#)
        let d = CredentialDraft.loaded(from: c)
        XCTAssertFalse(d.usesOwnBaseURL)
        XCTAssertEqual(d.type, .openaiCompatible, "和改前一样按预设算")
    }

    func testCustomCardHasNoRegion() {
        let c = card(preset: nil, type: .anthropic, baseURL: "https://relay.example.com/v1")
        let d = CredentialDraft.loaded(from: c)
        XCTAssertNil(d.regionSelection)
        XCTAssertNil(d.region)
        XCTAssertNil(d.makeCredential(id: c.id, existing: c).regionId)
        XCTAssertNil(d.keysURL)
    }

    // MARK: 换家判断

    func testProviderKeyTracksPresetRegionAndFormat() {
        let base = CredentialDraft.loaded(from: card(preset: "deepseek", baseURL: "https://api.deepseek.com/v1"))
        var other = base
        other.presetSelection = "openai"
        XCTAssertNotEqual(base.providerKey, other.providerKey)
        var own = base
        own.regionSelection = CredentialDraft.ownRegion
        XCTAssertNotEqual(base.providerKey, own.providerKey)
        var defaultRegion = base
        defaultRegion.regionSelection = nil
        XCTAssertEqual(base.providerKey, defaultRegion.providerKey, "nil = 默认区域，不算换")
        var custom = CredentialDraft(presetSelection: CredentialDraft.customSelection, customType: .openaiCompatible, customBaseURL: "https://a.example")
        let before = custom.providerKey
        custom.customBaseURL = "https://b.example"
        XCTAssertEqual(custom.providerKey, before, "只改地址不算换家")
        custom.customType = .anthropic
        XCTAssertNotEqual(custom.providerKey, before)
    }

    // MARK: 换提供商再换回（审查 #1）

    /// 自有地址 A 的 DeepSeek 卡 → 换 Ollama 改成地址 B → 换回 DeepSeek → 保存：地址仍是 A，格式仍是卡原来的
    func testSwitchAwayAndBackRestoresOwnAddress() {
        let c = card(preset: "deepseek", type: .anthropic, baseURL: "https://relay.example.com/anthropic/v1")
        let original = CredentialDraft.loaded(from: c)
        var d = original
        d.switchPreset(to: "ollama", original: original)
        d.customBaseURL = "http://192.168.1.5:11434/v1"
        d.switchPreset(to: CredentialDraft.customSelection, original: original)
        d.customType = .openaiCompatible
        d.switchPreset(to: "deepseek", original: original)
        XCTAssertTrue(d.usesOwnBaseURL)
        XCTAssertEqual(d.providerKey, original.providerKey)
        let saved = d.makeCredential(id: c.id, existing: c)
        XCTAssertEqual(saved.baseURL, "https://relay.example.com/anthropic/v1")
        XCTAssertEqual(saved.type, .anthropic)
    }

    func testSwitchToOtherPresetResetsRegionAndFormat() {
        let original = CredentialDraft.loaded(from: card(preset: "deepseek", baseURL: "https://relay.example.com/v1"))
        var d = original
        d.switchPreset(to: "openai", original: original)
        XCTAssertNil(d.regionSelection)
        XCTAssertNil(d.presetProtocol)
        XCTAssertEqual(d.baseURL, "https://api.openai.com/v1")
    }

    // MARK: 判脏的语义归一（审查 #2）

    /// 旧草稿没有区域 / 格式字段：恢复出的 nil 和装卡写明的默认区域、默认格式算同一个
    func testOldDraftNilsEqualLoadedDefaults() {
        let loaded = CredentialDraft.loaded(from: card(preset: "deepseek", baseURL: "https://api.deepseek.com/v1"))
        XCTAssertEqual(loaded.regionSelection, "default")
        let restored = CredentialDraft(presetSelection: "deepseek", customType: .openaiCompatible, customBaseURL: "https://api.deepseek.com/v1")
        XCTAssertEqual(restored.effectiveRegionSelection, loaded.effectiveRegionSelection)
        XCTAssertEqual(restored.effectivePresetProtocol, loaded.effectivePresetProtocol)
        let custom = CredentialDraft(presetSelection: CredentialDraft.customSelection, customType: .anthropic)
        XCTAssertNil(custom.effectiveRegionSelection)
        XCTAssertNil(custom.effectivePresetProtocol)
    }

    func testOwnAddressNotNormalizedToDefaultRegion() {
        let own = CredentialDraft.loaded(from: card(preset: "deepseek", baseURL: "https://relay.example.com/v1"))
        var official = own
        official.regionSelection = nil
        XCTAssertEqual(own.effectiveRegionSelection, CredentialDraft.ownRegion)
        XCTAssertEqual(official.effectiveRegionSelection, "default")
        XCTAssertNotEqual(own.effectiveRegionSelection, official.effectiveRegionSelection)
    }

    // MARK: 自有地址卡选回官方地址（审查 #3）

    func testOwnAddressCardPickingTableRegionCountsAsSwitch() {
        let c = card(preset: "deepseek", baseURL: "https://relay.example.com/v1")
        let own = CredentialDraft.loaded(from: c)
        var d = own
        d.regionSelection = APIProvider.deepseek.defaultRegion.id
        XCTAssertFalse(d.usesOwnBaseURL)
        XCTAssertEqual(d.baseURL, "https://api.deepseek.com/v1")
        XCTAssertNotEqual(d.providerKey, own.providerKey, "选表内区域 = 换家，保存要确认")
        XCTAssertEqual(d.makeCredential(id: c.id, existing: c).regionId, "default")
        d.regionSelection = CredentialDraft.ownRegion
        XCTAssertEqual(d.providerKey, own.providerKey)
        XCTAssertEqual(d.baseURL, "https://relay.example.com/v1")
    }

    // MARK: 已有卡换区域（阶段 2–4 审查 #2）

    private let zhipuOpenAICard = APICredential(id: "cred-zp", name: "智谱", emoji: "🍐", presetId: "zhipu", type: .openaiCompatible,
                                                baseURL: "https://open.bigmodel.cn/api/paas/v4")

    /// 旧智谱 OpenAI 卡 → 选 Coding Plan：格式按套餐默认走 Anthropic（和新建卡选套餐一样）
    func testExistingCardPickingPlanRegionUsesPlanDefaultProtocol() {
        let original = CredentialDraft.loaded(from: zhipuOpenAICard)
        XCTAssertEqual(original.regionSelection, "payg")
        var d = original
        d.switchRegion(to: "coding", original: original)
        XCTAssertNil(d.presetProtocol)
        XCTAssertEqual(d.type, .anthropic)
        XCTAssertEqual(d.baseURL, "https://open.bigmodel.cn/api/anthropic/v1")
        var fresh = CredentialDraft(presetSelection: "zhipu")
        fresh.switchRegion(to: "coding", original: nil)
        XCTAssertEqual(fresh.type, d.type, "同一目标区域不因进入路径不同而不同")
    }

    /// 换回卡原来的区域：还原卡原来的格式，不算换家
    func testSwitchingBackToOriginalRegionRestoresProtocol() {
        let original = CredentialDraft.loaded(from: zhipuOpenAICard)
        var d = original
        d.switchRegion(to: "coding", original: original)
        d.switchRegion(to: "payg", original: original)
        XCTAssertEqual(d.type, .openaiCompatible)
        XCTAssertEqual(d.providerKey, original.providerKey)
    }

    /// 选的还是当前区域：格式不动（含手选过的）
    func testPickingSameRegionKeepsProtocol() {
        var d = CredentialDraft.loaded(from: zhipuOpenAICard)
        d.presetProtocol = .anthropic
        d.switchRegion(to: "payg", original: CredentialDraft.loaded(from: zhipuOpenAICard))
        XCTAssertEqual(d.type, .anthropic)
    }

    /// 装载旧卡不走 switchRegion：Coding Plan 上的 OpenAI 旧卡格式不变
    func testLoadingOldPlanCardKeepsItsProtocol() {
        let c = APICredential(id: "cred-zpc", name: "智谱套餐", emoji: "🍐", presetId: "zhipu", type: .openaiCompatible,
                              baseURL: "https://open.bigmodel.cn/api/coding/paas/v4")
        let d = CredentialDraft.loaded(from: c)
        XCTAssertEqual(d.regionSelection, "coding")
        XCTAssertEqual(d.type, .openaiCompatible)
        XCTAssertEqual(d.makeCredential(id: c.id, existing: c).baseURL, "https://open.bigmodel.cn/api/coding/paas/v4")
        XCTAssertEqual(CredentialDraft.loaded(from: zhipuOpenAICard).type, .openaiCompatible)
    }

    func testNewDraftDefaultsMatchOldBehavior() {
        for p in APIProvider.presets {
            let d = CredentialDraft(presetSelection: p.id)
            XCTAssertEqual(d.type, p.type, p.id)
            if !d.editsBaseURL { XCTAssertEqual(d.baseURL, p.baseURL, p.id) }
            XCTAssertEqual(d.region?.id, p.defaultRegion.id, p.id)
        }
    }
}
