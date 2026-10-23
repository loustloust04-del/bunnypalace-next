import XCTest
@testable import 记忆花园

/// 卡库 ③-4：身份进发送链后的最终请求体。无身份（含指定了但找不到）时 ④b 那 8 份逐字节不变；
/// 有身份时只有 `{{user}}` 展开出的名字变、身份描述落在楼层原有身份描述的同一位置，不新增插槽、不改顺序。
final class PersonaRequestBodyTests: XCTestCase {

    private var cardGuideWasEnabled = true

    override func setUp() {
        super.setUp()
        cardGuideWasEnabled = ChatCardPromptGuide.isEnabledForTesting
        ChatCardPromptGuide.isEnabledForTesting = false
    }

    override func tearDown() {
        ChatCardPromptGuide.isEnabledForTesting = cardGuideWasEnabled
        super.tearDown()
    }

    /// 与实发同一组函数：身份套上后的楼层副本 → assembleOrdered → provider 请求体
    private func body(_ s: ProviderOrderingScenario, profile: Profile, preset: Preset? = nil) -> String {
        let preset = preset ?? s.preset
        let result = PromptAssembler.assembleOrdered(
            preset: preset, profile: profile, memories: [],
            chatHistory: s.history.map { (role: $0.role, content: $0.content) },
            historyNodeIds: s.history.map(\.id),
            fileLibrary: s.fileLibrary, styleContent: s.styleContent,
            folderInstructions: s.folderInstructions, volatileNote: s.volatileNote)
        var byId: [String: [PendingChatAttachment]] = [:]
        for turn in s.history where !turn.images.isEmpty { byId[turn.id] = turn.images }
        let ordered = PromptMessage.attaching(byId, to: result.messages)
        let raw: [String: Any]
        if s.anthropic {
            raw = AnthropicProvider.buildRequestBody(ordered: ordered, model: s.model, samplingParams: preset.sampling,
                                                     tools: s.tools, toolTurns: s.toolTurns, allowCacheControl: true)
        } else {
            raw = OpenAICompatibleProvider.buildRequestBody(
                ordered: ordered, model: s.model, samplingParams: preset.sampling, tools: s.tools, toolTurns: s.toolTurns,
                orCacheControl: OpenAICompatibleProvider.wantsORCacheControl(baseURL: s.baseURL, model: s.model, samplingParams: preset.sampling),
                orProviderOrder: OpenAICompatibleProvider.orPreferredProviderOrder(baseURL: s.baseURL, model: s.model, samplingParams: preset.sampling),
                interleavedSystem: OpenAICompatibleProvider.supportsInterleavedSystem(baseURL: s.baseURL, model: s.model))
        }
        return ProviderOrderingScenarios.canonicalJSON(raw)
    }

    private let personas = [UserPersona(id: "p", name: "阿禾", description: "身份描述：{{user}}爱喝茶")]

    /// 夹具预设在系统指令后插一个身份描述插槽（序列第 2 位，历史前）
    private func withPersonaSlot(_ base: Preset) -> Preset {
        var preset = base
        var prompts = preset.prompts
        prompts.insert(PromptSlot(id: PromptSlot.personaDescriptionId, name: "用户设定", role: "system", isSystemPrompt: true,
                                  isMarker: true, injectionOrder: 10), at: 1)
        preset.prompts = SlotOrder.normalized(prompts)
        return preset
    }

    func testNoPersonaBodiesStayByteIdenticalToFixtures() {
        for s in ProviderOrderingScenarios.all() {
            for (conversationId, floorId) in [(nil, nil), ("gone", "gone-too"), ("", "")] as [(String?, String?)] {
                let resolution = PersonaResolution.resolve(conversationPersonaId: conversationId, floorPersonaId: floorId, personas: personas)
                XCTAssertNil(resolution.persona)
                XCTAssertEqual(body(s, profile: resolution.applied(to: s.profile)), ProviderOrderingTests.preChangeFixtures[s.name],
                               "\(s.name) 无身份（\(conversationId ?? "nil")）请求体变了")
            }
        }
    }

    /// 夹具预设里没有身份描述插槽：套上身份只换名字，描述不会凭空多一段
    func testPersonaChangesOnlyExpandedNamesWithoutNewSlot() {
        for s in ProviderOrderingScenarios.all() {
            let effective = PersonaResolution.resolve(conversationPersonaId: "p", floorPersonaId: nil, personas: personas).applied(to: s.profile)
            let fixture = ProviderOrderingTests.preChangeFixtures[s.name]!
            XCTAssertTrue(fixture.contains("禾禾"), s.name)
            XCTAssertEqual(body(s, profile: effective), fixture.replacingOccurrences(of: "禾禾", with: "阿禾"), s.name)
        }
    }

    /// 预设有身份描述插槽：身份描述原位替换楼层原有身份描述，顺序、角色、其余正文都不动
    func testPersonaDescriptionLandsInFloorPersonaSlotPosition() {
        let preset = withPersonaSlot(ProviderOrderingScenarios.preset(preHistoryUser: true))
        for s in ProviderOrderingScenarios.all() where ["oai-plain", "oai-official", "anthropic-plain"].contains(s.name) {
            var floor = s.profile
            floor.userPersona = "楼层原身份：{{user}}是写作者"
            let before = body(s, profile: floor, preset: preset)
            XCTAssertTrue(before.contains("楼层原身份：禾禾是写作者"), s.name)

            let after = body(s, profile: PersonaResolution.resolve(conversationPersonaId: nil, floorPersonaId: "p", personas: personas)
                .applied(to: floor), preset: preset)
            let expected = before.replacingOccurrences(of: "楼层原身份：禾禾是写作者", with: "身份描述：阿禾爱喝茶")
                .replacingOccurrences(of: "禾禾", with: "阿禾")
            XCTAssertEqual(after, expected, s.name)
            let persona = after.range(of: "身份描述：阿禾爱喝茶")!.lowerBound
            XCTAssertLessThan(after.range(of: "陪阿禾聊天")!.lowerBound, persona, "在系统指令之后")
            XCTAssertLessThan(persona, after.range(of: "[角色设定]")!.lowerBound, "在角色设定之前（原插槽位）")
        }
    }

    /// 楼层原本没写身份描述、身份有描述：同一个插槽位补上，不挪别处
    func testPersonaDescriptionFillsEmptyFloorSlotInPlace() {
        let preset = withPersonaSlot(ProviderOrderingScenarios.preset())
        let s = ProviderOrderingScenarios.all().first { $0.name == "oai-plain" }!
        XCTAssertEqual(body(s, profile: s.profile, preset: preset), ProviderOrderingTests.preChangeFixtures["oai-plain"], "空身份描述槽不出段")
        let after = body(s, profile: PersonaResolution.resolve(conversationPersonaId: "p", floorPersonaId: nil, personas: personas)
            .applied(to: s.profile), preset: preset)
        XCTAssertTrue(after.contains(#""content":"你是小岚，陪阿禾聊天。\n\n[用户信息]\n身份描述：阿禾爱喝茶\n\n[角色设定]"#), after)
        XCTAssertEqual(after.replacingOccurrences(of: #"\n\n[用户信息]\n身份描述：阿禾爱喝茶"#, with: ""),
                       ProviderOrderingTests.preChangeFixtures["oai-plain"]!.replacingOccurrences(of: "禾禾", with: "阿禾"), "其余逐字不变")
    }
}
