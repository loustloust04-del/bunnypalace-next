import XCTest
@testable import 记忆花园

/// API 卡草稿（plan-onboarding-xiaoya-impl P1a）：期望值照抽取前 APICredentialEditor.makeDraft 的逐字段结果固化，
/// 抽成 CredentialDraft.makeCredential 后必须一字不差。纯函数，不碰卡表 / 钥匙串。
final class CredentialDraftTests: XCTestCase {

    private func models(_ ids: [String], cid: String = "draft") -> [ProviderModel] {
        ids.map { ProviderModel(credentialId: cid, modelId: $0, name: $0.uppercased()) }
    }

    func testPresetOpenAI() {
        let d = CredentialDraft(presetSelection: "openai", customType: .anthropic, customBaseURL: "https://ignored.example",
                                nickname: "  我的 key ", emoji: " 🍊 ", models: models(["gpt-x", "gpt-y"]), toolsSupported: true)
        let c = d.makeCredential(id: "cred-1", existing: nil)
        XCTAssertEqual(c.id, "cred-1")
        XCTAssertEqual(c.name, "我的 key")
        XCTAssertEqual(c.emoji, "🍊")
        XCTAssertEqual(c.presetId, "openai")
        XCTAssertEqual(c.type, .openaiCompatible)
        XCTAssertEqual(c.baseURL, "https://api.openai.com/v1", "预设卡不读自定义地址")
        XCTAssertEqual(c.extraHeaders, [:])
        XCTAssertEqual(c.models.map(\.id), ["cred-1/gpt-x", "cred-1/gpt-y"], "模型改挂到卡 id 下")
        XCTAssertEqual(c.models.map(\.name), ["GPT-X", "GPT-Y"])
        XCTAssertNil(c.toolsSupported)
        XCTAssertNil(c.lastUsedAt)
        XCTAssertNil(c.lastUsedModelId)
        XCTAssertTrue(d.isHTTP)
        XCTAssertFalse(d.isSingletonPreset)
        XCTAssertFalse(d.editsBaseURL)
    }

    func testPresetHeadersComeFromPreset() {
        let d = CredentialDraft(presetSelection: "openrouter", nickname: "or", emoji: "🌀")
        let c = d.makeCredential(id: "x", existing: nil)
        XCTAssertEqual(c.extraHeaders, ["HTTP-Referer": "MemoryPalace/1.0", "X-Title": "MemoryPalace"])
        XCTAssertEqual(c.baseURL, "https://openrouter.ai/api/v1")
    }

    func testCustomOpenAICompatibleNormalizesURL() {
        let d = CredentialDraft(presetSelection: "_custom_", customType: .openaiCompatible,
                                customBaseURL: " api.relay.example/chat/completions/ ", nickname: "中转", emoji: "🛰")
        let c = d.makeCredential(id: "x", existing: nil)
        XCTAssertNil(c.presetId)
        XCTAssertEqual(c.type, .openaiCompatible)
        XCTAssertEqual(c.baseURL, "https://api.relay.example/v1")
        XCTAssertEqual(c.extraHeaders, [:])
        XCTAssertTrue(d.editsBaseURL)
    }

    func testCustomAnthropicGetsVersionHeader() {
        let d = CredentialDraft(presetSelection: "_custom_", customType: .anthropic,
                                customBaseURL: "https://relay.example/v1/messages", nickname: "a", emoji: "🅰️")
        let c = d.makeCredential(id: "x", existing: nil)
        XCTAssertEqual(c.type, .anthropic)
        XCTAssertEqual(c.baseURL, "https://relay.example/v1")
        XCTAssertEqual(c.extraHeaders, ["anthropic-version": "2023-06-01"])
        XCTAssertTrue(d.isHTTP)
    }

    // MARK: anthropic-version（Anthropic 格式聊天只从卡上拿这个头）

    /// 新预设 / 老预设新加的 Anthropic 区域：预设没写这个头，卡上要补
    func testPresetAnthropicRegionGetsVersionHeader() {
        var zp = CredentialDraft(presetSelection: "zhipu")
        zp.switchRegion(to: "coding", original: nil)
        XCTAssertEqual(zp.type, .anthropic)
        XCTAssertEqual(zp.makeCredential(id: "x", existing: nil).extraHeaders, ["anthropic-version": "2023-06-01"])

        let kimi = CredentialDraft(presetSelection: "kimi-code")
        XCTAssertEqual(kimi.type, .anthropic)
        XCTAssertEqual(kimi.makeCredential(id: "x", existing: nil).extraHeaders, ["anthropic-version": "2023-06-01"])

        var payg = CredentialDraft(presetSelection: "zhipu")
        payg.presetProtocol = .anthropic
        XCTAssertEqual(payg.type, .anthropic)
        XCTAssertEqual(payg.makeCredential(id: "x", existing: nil).extraHeaders, ["anthropic-version": "2023-06-01"])
    }

    /// 每家预设：Anthropic 格式的卡都带这个头，OpenAI 兼容格式的卡不带（除非预设自己写了）
    func testEveryPresetRegionFormatHeaders() {
        for p in APIProvider.presets {
            for r in p.regions {
                for t in r.protocols where t == .anthropic || t == .openaiCompatible {
                    let d = CredentialDraft(presetSelection: p.id, regionSelection: r.id, presetProtocol: t)
                    guard d.type == t else { continue }
                    let headers = d.makeCredential(id: "x", existing: nil).extraHeaders
                    if t == .anthropic {
                        XCTAssertEqual(headers["anthropic-version"], "2023-06-01", "\(p.id)/\(r.id)")
                    } else {
                        XCTAssertEqual(headers, p.extraHeaders, "\(p.id)/\(r.id)")
                    }
                }
            }
        }
    }

    /// 已有卡切格式保存：头按当前格式重算，切回 OpenAI 不残留自动补的那个
    func testSwitchingFormatRecomputesHeaders() {
        let openAICard = APICredential(id: "cred-zp", name: "智谱", emoji: "🍐", presetId: "zhipu", type: .openaiCompatible,
                                       baseURL: "https://open.bigmodel.cn/api/paas/v4")
        var d = CredentialDraft.loaded(from: openAICard)
        d.presetProtocol = .anthropic
        let toAnthropic = d.makeCredential(id: openAICard.id, existing: openAICard)
        XCTAssertEqual(toAnthropic.type, .anthropic)
        XCTAssertEqual(toAnthropic.extraHeaders, ["anthropic-version": "2023-06-01"])

        var back = CredentialDraft.loaded(from: toAnthropic)
        back.presetProtocol = .openaiCompatible
        let toOpenAI = back.makeCredential(id: openAICard.id, existing: toAnthropic)
        XCTAssertEqual(toOpenAI.type, .openaiCompatible)
        XCTAssertEqual(toOpenAI.extraHeaders, [:])
    }

    /// 老 Anthropic 类预设自带这个头：值不变、不重复
    func testOldAnthropicPresetHeadersUnchanged() {
        for id in ["anthropic", "claude-p"] {
            let c = CredentialDraft(presetSelection: id).makeCredential(id: "x", existing: nil)
            XCTAssertEqual(c.extraHeaders, ["anthropic-version": "2023-06-01"], id)
        }
    }

    /// Ollama 是预设但地址可改（#092 零散雷）
    func testOllamaUsesEditableBaseURL() {
        let d = CredentialDraft(presetSelection: "ollama", customBaseURL: "http://192.168.1.5:11434", nickname: "o", emoji: "🦙")
        let c = d.makeCredential(id: "x", existing: nil)
        XCTAssertTrue(d.editsBaseURL)
        XCTAssertEqual(c.presetId, "ollama")
        XCTAssertEqual(c.type, .openaiCompatible)
        XCTAssertEqual(c.baseURL, "http://192.168.1.5:11434/v1")
    }

    func testExistingCarriesUsageStampsAndToolsOff() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let used = Date(timeIntervalSince1970: 1_700_000_500)
        let existing = APICredential(id: "cred-old", name: "旧", emoji: "🔑", presetId: "openai", type: .openaiCompatible,
                                     baseURL: "https://api.openai.com/v1", createdAt: created, lastUsedAt: used,
                                     lastUsedModelId: "gpt-x")
        let d = CredentialDraft(presetSelection: "openai", nickname: "新", emoji: "🔑", toolsSupported: false)
        let c = d.makeCredential(id: "cred-old", existing: existing)
        XCTAssertEqual(c.createdAt, created)
        XCTAssertEqual(c.lastUsedAt, used)
        XCTAssertEqual(c.lastUsedModelId, "gpt-x")
        XCTAssertEqual(c.toolsSupported, false)
    }

    func testSingletonKinds() {
        XCTAssertTrue(CredentialDraft(presetSelection: "cc-bridge").isSingletonPreset)
        XCTAssertTrue(CredentialDraft(presetSelection: "codex-bridge").isSingletonPreset)
        XCTAssertTrue(CredentialDraft(presetSelection: "chatgpt-oauth").isSingletonPreset)
        XCTAssertFalse(CredentialDraft(presetSelection: "cc-bridge").isHTTP)
        let bridge = CredentialDraft(presetSelection: "cc-bridge", customBaseURL: "ws://ignored").makeCredential(id: "cc-bridge", existing: nil)
        XCTAssertEqual(bridge.type, .ccBridge)
        XCTAssertEqual(bridge.baseURL, "ws://127.0.0.1:7890/cc", "非 HTTP 卡地址原样，不规整")
        XCTAssertTrue(CredentialDraft(presetSelection: "_custom_", customType: .localMLX).isSingletonPreset)
    }

    /// 预设表里找不到的 id（比如 Release 里没有的自用预设）：和编辑页一样当 OpenAI 兼容、地址空
    func testUnknownPresetFallsBack() {
        let d = CredentialDraft(presetSelection: "no-such-preset")
        XCTAssertEqual(d.type, .openaiCompatible)
        XCTAssertEqual(d.baseURL, "")
        XCTAssertEqual(d.makeCredential(id: "x", existing: nil).presetId, "no-such-preset")
    }

    func testCodableRoundTrip() throws {
        let d = CredentialDraft(presetSelection: "_custom_", customType: .anthropic, customBaseURL: "https://r.example",
                                nickname: "n", emoji: "🍵", models: models(["m1"]), toolsSupported: false)
        let back = try JSONDecoder().decode(CredentialDraft.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(d), as: UTF8.self).lowercased().contains("key\""),
                       "草稿不含 key 字段")
    }

    // MARK: humanReason（只给引导 key 卡用）

    private func fail(_ status: Int?, _ message: String = "x") -> ProviderProbe.Failure {
        .init(status: status, message: message, url: "https://a.example/v1/chat/completions")
    }

    func testHumanReason() {
        XCTAssertEqual(ProviderProbe.humanReason(fail(401)), "key 不对，或者已经失效了")
        XCTAssertEqual(ProviderProbe.humanReason(fail(403)), "key 不对，或者已经失效了")
        XCTAssertEqual(ProviderProbe.humanReason(fail(404)), "地址不对——这家中转可能要写到 /v1，或者用的是 Anthropic 协议")
        XCTAssertEqual(ProviderProbe.humanReason(fail(429)), "被限流了，或者余额不够了")
        XCTAssertEqual(ProviderProbe.humanReason(fail(502)), "这家服务暂时出问题了，过一会儿再试")
        XCTAssertEqual(ProviderProbe.humanReason(fail(400)), "这家没接受这次请求（400）")
        XCTAssertEqual(ProviderProbe.humanReason(fail(nil, "连不上：The request timed out.")),
                       "15 秒没回音：网络不通，或者地址填错了域名")
        XCTAssertEqual(ProviderProbe.humanReason(fail(nil, "连不上：请求超时。")),
                       "15 秒没回音：网络不通，或者地址填错了域名")
        XCTAssertEqual(ProviderProbe.humanReason(fail(nil, "卡上还没有模型，连不上：A server with the specified hostname could not be found.——手填一个模型 ID 再测")),
                       "连不上：网络不通，或者地址填错了")
        XCTAssertEqual(ProviderProbe.humanReason(fail(nil, "还没填 API Key")), "还没填 API Key", "不是网络问题的原话照给")
    }
}
