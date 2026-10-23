import XCTest
@testable import 记忆花园

/// ⑤a 正则执行链：三源顺序 / 卡许可 / 三阶段分流 / 发送深度与 placement / 世界书发送规则 / ④b 主闸 / 附件稳定挂节点
final class RegexPipelineTests: XCTestCase {

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

    // MARK: - 夹具

    private func rule(_ id: String, find: String = "/X/g", replace: String = "", placement: [Int] = [1, 2],
                      display: Bool = false, send: Bool = false, disabled: Bool = false, runOnEdit: Bool = true,
                      minDepth: Int? = nil, maxDepth: Int? = nil) -> RegexScript {
        var s = RegexScript()
        s.id = id
        s.scriptName = id
        s.findRegex = find
        s.replaceString = replace
        s.placement = placement
        s.markdownOnly = display
        s.promptOnly = send
        s.disabled = disabled
        s.runOnEdit = runOnEdit
        s.minDepth = minDepth
        s.maxDepth = maxDepth
        return s
    }

    private func profile(rules: [RegexScript] = []) -> Profile {
        var p = Profile(name: "测试", emoji: "🧪", description: "", userName: "禾禾", assistantName: "小岚",
                        systemPrompt: "系统指令", characterDescription: "角色设定")
        p.regexScripts = rules
        return p
    }

    private func preset(rules: [RegexScript] = []) -> Preset {
        var p = Preset(name: "t")
        p.prompts = SlotOrder.normalized([
            PromptSlot(id: PromptSlot.mainId, name: "系统指令", role: "system", isSystemPrompt: true, isMarker: false, injectionOrder: 0),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "对话历史", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 60),
        ])
        p.regexScripts = rules
        return p
    }

    private func card(boundTo profileId: String?, consent: CharacterCard.ExtensionConsent, rules: [RegexScript]) -> CharacterCard {
        var c = CharacterCard(name: "卡", description: "", personality: "", scenario: "", firstMes: "")
        c.linkedProfileId = profileId
        c.bindingState = profileId == nil ? .unbound : .active
        c.extensionConsent = consent
        c.regexScripts = rules
        return c
    }

    private func entry(_ content: String, _ position: WorldBookEntry.InsertionPosition, keys: [String] = [], depth: Int? = nil) -> WorldBookEntry {
        var e = WorldBookEntry()
        e.content = content
        e.position = position
        e.isConstant = keys.isEmpty
        e.keys = keys
        e.depth = depth
        return e
    }

    // MARK: - 三源顺序与许可

    func testSourceOrderIsGlobalPresetThenBoundCard() {
        let prof = profile(rules: [rule("old")])
        let pre = preset(rules: [rule("p1"), rule("p2")])
        let c = card(boundTo: prof.id, consent: .allowed, rules: [rule("c1")])
        let rules = RegexPipeline.resolve(global: [rule("g1")], profile: prof, preset: pre, cards: [c])
        XCTAssertEqual(rules.map(\.compositeId),
                       ["global:global:g1", "preset:\(pre.id):p1", "preset:\(pre.id):p2", "card:\(c.id):c1"],
                       "绑定卡时不再叠加楼层旧规则")
    }

    func testUnboundFloorFallsBackToProfileRules() {
        let prof = profile(rules: [rule("old")])
        let other = card(boundTo: "别的楼层", consent: .allowed, rules: [rule("c1")])
        let rules = RegexPipeline.resolve(profile: prof, preset: preset(rules: [rule("p1")]), cards: [other, card(boundTo: nil, consent: .allowed, rules: [rule("c2")])])
        XCTAssertEqual(rules.map(\.script.id), ["p1", "old"])
        XCTAssertEqual(rules.last?.source, .profile)
    }

    func testCardConsentUnknownAndDeferredAreOffAllowedIsOn() {
        let prof = profile(rules: [rule("old")])
        for consent in [CharacterCard.ExtensionConsent.unknown, .deferred] {
            let c = card(boundTo: prof.id, consent: consent, rules: [rule("c1")])
            XCTAssertEqual(RegexPipeline.resolve(profile: prof, preset: nil, cards: [c]).map(\.script.id), [],
                           "\(consent)：卡规则不生效，也不回退楼层旧规则")
            XCTAssertFalse(c.regexScripts[0].disabled, "许可不改规则自身 disabled")
        }
        let allowed = card(boundTo: prof.id, consent: .allowed, rules: [rule("c1")])
        XCTAssertEqual(RegexPipeline.resolve(profile: prof, preset: nil, cards: [allowed]).map(\.script.id), ["c1"])
    }

    func testSourceDisabledIsIndependentOfConsent() {
        let prof = profile()
        let c = card(boundTo: prof.id, consent: .allowed, rules: [rule("off", replace: "关", disabled: true), rule("on", replace: "开")])
        let scripts = RegexPipeline.scripts(profile: prof, preset: nil, cards: [c])
        XCTAssertEqual(scripts.map(\.id), ["off", "on"], "disabled 规则仍解析出来（给 ⑤b 页面显示），只是不执行")
        XCTAssertEqual(RegexPipeline.run(scripts, text: "X", phase: .input, placement: 1), "开")
    }

    func testSameCompositeIdIsNotStacked() {
        let pre = preset(rules: [rule("dup", replace: "a"), rule("dup", replace: "b")])
        let prof = profile(rules: [rule("dup")])
        let rules = RegexPipeline.resolve(profile: prof, preset: pre, cards: [])
        XCTAssertEqual(rules.map(\.compositeId), ["preset:\(pre.id):dup", "profile:\(prof.id):dup"],
                       "同来源同 owner 同 id 只留第一条；不同来源各自保留")
    }

    // MARK: - 三阶段分流

    func testPhasesDerivedFromLegacyFlags() {
        XCTAssertEqual(rule("a").phases, [.input])
        XCTAssertEqual(rule("b", display: true).phases, [.display])
        XCTAssertEqual(rule("c", send: true).phases, [.send])
        XCTAssertEqual(rule("d", display: true, send: true).phases, [.display, .send])
    }

    func testEachPhaseRunsOnlyItsRules() {
        let scripts = [rule("d", replace: "显", display: true), rule("s", replace: "发", send: true), rule("i", replace: "入")]
        XCTAssertEqual(RegexPipeline.run(scripts, text: "X", phase: .display, placement: 2), "显")
        XCTAssertEqual(RegexPipeline.run(scripts, text: "X", phase: .send, placement: 2, depth: 0), "发")
        XCTAssertEqual(RegexPipeline.run(scripts, text: "X", phase: .input, placement: 2), "入")
        let both = [rule("ds", replace: "双", display: true, send: true)]
        XCTAssertEqual(RegexPipeline.run(both, text: "X", phase: .display, placement: 1), "双")
        XCTAssertEqual(RegexPipeline.run(both, text: "X", phase: .send, placement: 1), "双")
        XCTAssertEqual(RegexPipeline.run(both, text: "X", phase: .input, placement: 1), "X")
    }

    func testInputEditRunsOnlyRunOnEditAndIgnoresDepth() {
        let scripts = [rule("e", find: "/A/", replace: "a", runOnEdit: true, minDepth: 3),
                       rule("n", find: "/B/", replace: "b", runOnEdit: false)]
        XCTAssertEqual(RegexPipeline.run(scripts, text: "AB", phase: .input, placement: 1), "ab", "输入阶段深度恒 0，旧 minDepth 不挡")
        XCTAssertEqual(RegexPipeline.run(scripts, text: "AB", phase: .input, placement: 1, isEdit: true), "aB")
    }

    func testRoleToPlacementDoesNotDisguiseSystemAsAssistant() {
        XCTAssertEqual(RegexPipeline.placement(forRole: "user"), 1)
        XCTAssertEqual(RegexPipeline.placement(forRole: "assistant"), 2)
        XCTAssertNil(RegexPipeline.placement(forRole: "system"))
        XCTAssertNil(RegexPipeline.placement(forRole: "tool"))
        XCTAssertEqual(RegexPipeline.run([rule("s", replace: "改", placement: [1, 2], send: true)], text: "X", phase: .send, placement: nil), "X")
    }

    func testNoEligibleRuleLeavesTextUntouchedIncludingMacros() {
        let scripts = [rule("d", replace: "显", display: true)]
        XCTAssertEqual(RegexPipeline.run(scripts, text: "X {{date}}", phase: .send, placement: 2, userName: "禾禾", charName: "小岚"),
                       "X {{date}}", "没有该跑的规则就不碰正文（也不做宏展开）")
    }

    // MARK: - 发送：深度与 placement

    private let history: [(role: String, content: String)] = [
        ("user", "X0"), ("assistant", "X1"), ("user", "X2"), ("assistant", "X3"), ("user", "X4"),
    ]

    private func sentHistory(_ scripts: [RegexScript]) -> [String] {
        let segs = PromptAssembler.assembleTagged(preset: preset(), profile: profile(), memories: [],
                                                  chatHistory: history, regexScripts: scripts).segments
        return segs.filter { $0.source == .chatHistory }.map(\.content)
    }

    func testSendDepthWindowLatestIsZero() {
        XCTAssertEqual(sentHistory([rule("near", replace: "Y", send: true, maxDepth: 1)]), ["X0", "X1", "X2", "Y3", "Y4"])
        XCTAssertEqual(sentHistory([rule("far", replace: "Y", send: true, minDepth: 3)]), ["Y0", "Y1", "X2", "X3", "X4"])
        XCTAssertEqual(sentHistory([rule("mid", replace: "Y", send: true, minDepth: 1, maxDepth: 2)]), ["X0", "X1", "Y2", "Y3", "X4"])
    }

    func testSendPlacementUserAndAssistantSeparately() {
        XCTAssertEqual(sentHistory([rule("u", replace: "U", placement: [1], send: true)]), ["U0", "X1", "U2", "X3", "U4"])
        XCTAssertEqual(sentHistory([rule("a", replace: "A", placement: [2], send: true)]), ["X0", "A1", "X2", "A3", "X4"])
    }

    func testSendRulesLeaveTemplateAndSystemHistoryAlone() {
        let segs = PromptAssembler.assembleTagged(preset: preset(), profile: profile(), memories: [],
                                                  chatHistory: [("system", "X系统"), ("user", "X{{char}}")],
                                                  regexScripts: [rule("s", replace: "Y", send: true)]).segments
        let hist = segs.filter { $0.source == .chatHistory }
        XCTAssertEqual(hist.map(\.content), ["X系统", "Y小岚"], "system 不冒充 assistant；宏先展开再跑规则")
        XCTAssertEqual(hist.map(\.template), ["X系统", "X{{char}}"], "模板留原文")
    }

    func testDisplayAndInputRulesDoNotTouchSendHistory() {
        XCTAssertEqual(sentHistory([rule("d", replace: "Y", display: true), rule("i", replace: "Y")]), ["X0", "X1", "X2", "X3", "X4"])
    }

    // MARK: - 世界书

    private func worldBookSegments(_ scripts: [RegexScript], entries: [WorldBookEntry],
                                   history: [(role: String, content: String)] = [("user", "你好")]) -> [String] {
        let segs = PromptAssembler.assembleTagged(preset: preset(), profile: profile(), memories: [],
                                                  chatHistory: history, globalEntries: entries, regexScripts: scripts).segments
        return segs.compactMap { seg in
            if case .worldBook = seg.source { return seg.content }
            return nil
        }
    }

    func testWorldInfoContentRunsPlacementFiveSendRules() {
        let entries = [entry("设定X", .beforeCharDef), entry("深处X", .atDepth, depth: 2)]
        XCTAssertEqual(worldBookSegments([rule("wi", replace: "Y", placement: [5], send: true)], entries: entries), ["设定Y", "深处Y"])
        XCTAssertEqual(worldBookSegments([rule("ai", replace: "Y", placement: [2], send: true)], entries: entries), ["设定X", "深处X"],
                       "placement 2 不作用世界书")
        XCTAssertEqual(worldBookSegments([rule("disp", replace: "Y", placement: [5], display: true)], entries: entries), ["设定X", "深处X"],
                       "显示规则不进请求")
        XCTAssertEqual(worldBookSegments([rule("near", replace: "Y", placement: [5], send: true, maxDepth: 1)], entries: entries), ["设定Y", "深处X"],
                       "atDepth 条目按自身深度（2）过滤；非 atDepth 不看深度（酒馆 regexDepth=null）")
        XCTAssertEqual(worldBookSegments([rule("wipe", find: "/^设定X$/", replace: "", placement: [5], send: true)], entries: entries), ["深处X"],
                       "跑空的条目不注入")
    }

    func testWorldBookScanReadsSendRegexedHistory() {
        let keyed = [entry("香蕉条目", .beforeCharDef, keys: ["香蕉"])]
        XCTAssertEqual(worldBookSegments([], entries: keyed, history: [("user", "我想吃苹果")]), [])
        XCTAssertEqual(worldBookSegments([rule("swap", find: "/苹果/", replace: "香蕉", placement: [1], send: true)],
                                         entries: keyed, history: [("user", "我想吃苹果")]), ["香蕉条目"],
                       "先跑发送规则再扫世界书（酒馆同序）")
    }

    // MARK: - 附件仍挂原节点

    func testAttachmentsStayOnOriginalNodeWhenSendRegexChangesText() {
        let image = ProviderOrderingScenarios.image("a.jpg", 0x0A)
        let result = PromptAssembler.assembleOrdered(
            preset: preset(), profile: profile(), memories: [],
            chatHistory: [("user", "看X"), ("assistant", "好"), ("user", "再看X")], historyNodeIds: ["n1", "n2", "n3"],
            regexScripts: [rule("s", replace: "这张图", placement: [1], send: true)])
        let ordered = PromptMessage.attaching(["n1": [image]], to: result.messages)
        let first = ordered.first { $0.nodeId == "n1" }
        XCTAssertEqual(first?.content, "看这张图")
        XCTAssertEqual(first?.attachments.map(\.id), [image.id], "正文变了附件仍挂 n1")
        XCTAssertEqual(ordered.first { $0.nodeId == "n3" }?.attachments.count, 0)
    }

    // MARK: - ④b 主闸：没有发送规则时 8 份请求体逐字节不变

    private func body(_ s: ProviderOrderingScenario, scripts: [RegexScript]) -> String {
        let result = PromptAssembler.assembleOrdered(
            preset: s.preset, profile: s.profile, memories: [],
            chatHistory: s.history.map { (role: $0.role, content: $0.content) }, historyNodeIds: s.history.map(\.id),
            fileLibrary: s.fileLibrary, styleContent: s.styleContent,
            folderInstructions: s.folderInstructions, volatileNote: s.volatileNote, regexScripts: scripts)
        var byId: [String: [PendingChatAttachment]] = [:]
        for turn in s.history where !turn.images.isEmpty { byId[turn.id] = turn.images }
        let ordered = PromptMessage.attaching(byId, to: result.messages)
        let json: [String: Any]
        if s.anthropic {
            json = AnthropicProvider.buildRequestBody(
                ordered: ordered, model: s.model, samplingParams: s.preset.sampling,
                tools: s.tools, toolTurns: s.toolTurns, allowCacheControl: true)
        } else {
            json = OpenAICompatibleProvider.buildRequestBody(
                ordered: ordered, model: s.model, samplingParams: s.preset.sampling,
                tools: s.tools, toolTurns: s.toolTurns,
                orCacheControl: OpenAICompatibleProvider.wantsORCacheControl(baseURL: s.baseURL, model: s.model, samplingParams: s.preset.sampling),
                orProviderOrder: OpenAICompatibleProvider.orPreferredProviderOrder(baseURL: s.baseURL, model: s.model, samplingParams: s.preset.sampling),
                interleavedSystem: OpenAICompatibleProvider.supportsInterleavedSystem(baseURL: s.baseURL, model: s.model))
        }
        return ProviderOrderingScenarios.canonicalJSON(json)
    }

    func testFixturesByteIdenticalWithoutSendRules() {
        let all = ProviderOrderingScenarios.all()
        XCTAssertEqual(all.count, 8)
        // 楼层没有任何规则 / 只有显示、输入规则 / 卡未许可 / 发送规则 disabled：请求体都与 ④b 改前 fixture 一致
        let prof = ProviderOrderingScenarios.profile()
        let unconsented = card(boundTo: prof.id, consent: .unknown, rules: [rule("c", find: "/./g", replace: "!", send: true)])
        let inactiveSets: [[RegexScript]] = [
            [],
            RegexPipeline.scripts(profile: prof, preset: nil, cards: []),
            RegexPipeline.scripts(profile: prof, preset: nil, cards: [unconsented]),
            [rule("d", find: "/./g", replace: "!", display: true), rule("i", find: "/./g", replace: "!")],
            [rule("off", find: "/./g", replace: "!", send: true, disabled: true)],
        ]
        for scripts in inactiveSets {
            for s in all {
                XCTAssertEqual(body(s, scripts: scripts), ProviderOrderingTests.preChangeFixtures[s.name],
                               "\(s.name) 规则 \(scripts.map(\.id)) 改了请求体")
            }
        }
    }
}
