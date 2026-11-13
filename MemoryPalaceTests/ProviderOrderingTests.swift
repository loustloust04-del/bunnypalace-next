import MemoryCore
import XCTest
@testable import 记忆花园

/// ④b 有序消息序列 → 各 provider 最终请求体。验最终 JSON，不只验分段。
final class ProviderOrderingTests: XCTestCase {

    private var cardGuideWasEnabled = true

    override func setUp() {
        super.setUp()
        cardGuideWasEnabled = ChatCardPromptGuide.isEnabledForTesting
        ChatCardPromptGuide.isEnabledForTesting = false   // 夹具不含卡片格式说明（它改文案不该让夹具失效）
    }

    override func tearDown() {
        ChatCardPromptGuide.isEnabledForTesting = cardGuideWasEnabled
        super.tearDown()
    }

    // MARK: - 新管线（与 ConversationViewModel.assemblePrompt / provider.sendStreaming 同一组函数）

    private func ordered(_ s: ProviderOrderingScenario) -> [PromptMessage] {
        let result = PromptAssembler.assembleOrdered(
            preset: s.preset, profile: s.profile, memories: [],
            chatHistory: s.history.map { (role: $0.role, content: $0.content) },
            historyNodeIds: s.history.map(\.id),
            fileLibrary: s.fileLibrary, styleContent: s.styleContent,
            folderInstructions: s.folderInstructions, volatileNote: s.volatileNote)
        var byId: [String: [PendingChatAttachment]] = [:]
        for turn in s.history where !turn.images.isEmpty { byId[turn.id] = turn.images }
        return PromptMessage.attaching(byId, to: result.messages)
    }

    private func body(_ s: ProviderOrderingScenario, _ ordered: [PromptMessage]) -> [String: Any] {
        if s.anthropic {
            return AnthropicProvider.buildRequestBody(
                ordered: ordered, model: s.model, samplingParams: s.preset.sampling,
                tools: s.tools, toolTurns: s.toolTurns, allowCacheControl: true)
        }
        return OpenAICompatibleProvider.buildRequestBody(
            ordered: ordered, model: s.model, samplingParams: s.preset.sampling,
            tools: s.tools, toolTurns: s.toolTurns,
            compat: ProviderOrderingScenarios.wireCompat(baseURL: s.baseURL, model: s.model, sampling: s.preset.sampling))
    }

    private func scenario(_ name: String, anthropic: Bool = false, baseURL: String = "https://api.deepseek.com/v1",
                          model: String = "deepseek-chat", extraSlots: [PromptSlot], preHistoryUser: Bool = false,
                          history: [ProviderOrderingScenario.Turn] = ProviderOrderingScenarios.plainHistory,
                          styleContent: String? = nil, cacheFriendly: Bool = false) -> ProviderOrderingScenario {
        var preset = ProviderOrderingScenarios.preset(preHistoryUser: preHistoryUser, cacheFriendly: cacheFriendly)
        preset.prompts = SlotOrder.normalized(preset.prompts + extraSlots)
        return ProviderOrderingScenario(name: name, anthropic: anthropic, baseURL: baseURL, model: model, preset: preset,
                                        profile: ProviderOrderingScenarios.profile(), history: history, styleContent: styleContent,
                                        fileLibrary: nil, folderInstructions: nil, volatileNote: nil, tools: nil, toolTurns: [])
    }

    private func absolute(_ id: String, _ content: String, role: String, depth: Int, order: Int = 100) -> PromptSlot {
        PromptSlot(id: id, name: id, role: role, content: content, isSystemPrompt: false, isMarker: false,
                   injectionDepth: depth, injectionOrder: order, injectionPosition: .absolute)
    }

    private func messages(_ body: [String: Any]) -> [[String: Any]] { body["messages"] as? [[String: Any]] ?? [] }

    /// 一条消息里所有文本（string 或 text 块按序拼）
    private func text(_ message: [String: Any]) -> String {
        if let s = message["content"] as? String { return s }
        return (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "|")
    }

    private func blockTypes(_ message: [String: Any]) -> [String] {
        (message["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
    }

    private func roles(_ body: [String: Any]) -> [String] { messages(body).compactMap { $0["role"] as? String } }

    // MARK: - Recall Z/X 权限边界（真实 adapter JSON，不录制金样）

    func testRecallMemoryRemainsSystemAcrossCacheRolesPositionsAndProviders() throws {
        let profile = Profile(id: "recall-wire", name: "岚舟", emoji: "", description: "",
                              userName: "星砚", assistantName: "岚舟")
        let hit = InjectionHit(memoryId: UUID(), snippet: "林栖碎片", category: "fact",
                               score: nil, retrieverId: "fullFallback", catalog: false)
        let layers = RecallMemoryLayers(stable: "Z：星砚住在云桥城", volatile: "X：林栖约了周末见面",
                                        hits: [hit], pages: [])
        let history: [(role: String, content: String)] = [("user", "云桥城"), ("assistant", "岚舟答复"), ("user", "聊聊林栖")]
        for cache in [false, true] {
            for role in ["user", "assistant", "system"] {
                // relative 前/后历史，以及 absolute depth 0/1。
                for placement in 0..<4 {
                    var preset = Preset(name: "Recall wire")
                    preset.sampling.cacheFriendly = cache
                    func marker(_ id: String, _ index: Int) -> PromptSlot {
                        PromptSlot(id: id, name: id, role: role, content: "", isSystemPrompt: false,
                                   isMarker: true, injectionDepth: placement >= 2 ? placement - 2 : 0,
                                   injectionPosition: placement >= 2 ? .absolute : .relative, sequenceIndex: index)
                    }
                    let memoryIndex = placement == 0 ? 0 : 2
                    preset.prompts = [
                        marker(PromptSlot.memoryInjectionId, memoryIndex),
                        marker(PromptSlot.contextSummaryId, memoryIndex + 1),
                        marker(PromptSlot.timelineId, memoryIndex + 2),
                        marker(PromptSlot.userProfileId, memoryIndex + 3),
                        PromptSlot(id: PromptSlot.chatHistoryId, name: "历史", role: "user", content: "",
                                   isSystemPrompt: false, isMarker: true, sequenceIndex: placement == 0 ? 4 : 0)
                    ]
                    let assembled = PromptAssembler.assembleTagged(
                        preset: preset, profile: profile, memories: [], chatHistory: history,
                        contextSummary: "A2：星砚的真实窗口摘要", userProfile: "画像：星砚的偏好",
                        timelineSummary: "A4：云桥城的旧日事件", selfMemory: "不应重新组装的 B4",
                        recallLayers: layers)
                    XCTAssertEqual(assembled.memoryHits, [hit])
                    XCTAssertTrue(assembled.segments.filter { $0.source.requiresSystemRole }.allSatisfy { $0.role == "system" })
                    let ordered = PromptAssembler.orderedMessages(from: assembled.segments)
                    for provider in 0..<3 {
                        let body: [String: Any]
                        if provider == 2 {
                            body = AnthropicProvider.buildRequestBody(ordered: ordered, model: "claude-sonnet-4-5",
                                                                      samplingParams: preset.sampling, allowCacheControl: true)
                        } else {
                            var compat = ResolvedCompat.permissive
                            compat.interleavedSystem = provider == 0
                            body = OpenAICompatibleProvider.buildRequestBody(ordered: ordered, model: "recall-wire",
                                                                            samplingParams: preset.sampling, compat: compat)
                        }
                        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: body)) as? [String: Any])
                        let system = (wire["system"] as? String)
                            ?? (wire["system"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                        let msgs = messages(wire)
                        let systemText = ([system] + msgs.filter { $0["role"] as? String == "system" }.map(text)).joined(separator: "\n")
                        let nonSystem = msgs.filter { $0["role"] as? String != "system" }.map(text).joined(separator: "\n")
                        for payload in [layers.stable, layers.volatile, "A2：星砚的真实窗口摘要", "画像：星砚的偏好", "A4：云桥城的旧日事件"] {
                            XCTAssertEqual(systemText.components(separatedBy: payload).count - 1, 1,
                                           "cache=\(cache), role=\(role), placement=\(placement), provider=\(provider)")
                            XCTAssertFalse(nonSystem.contains(payload))
                        }
                        XCTAssertFalse((systemText + nonSystem).contains("不应重新组装的 B4"))
                    }
                }
            }
        }
    }

    func testRecallSystemPromotionPreservesSourcesAndNonMemoryStrategies() throws {
        let ordered = [
            PromptMessage(role: "system", content: "岚舟身份", source: .slot(id: "main", name: "main"), nodeId: nil, pinnedToSystemPrefix: false),
            PromptMessage(role: "user", content: "星砚原话", source: .chatHistory, nodeId: "u1", pinnedToSystemPrefix: false),
            PromptMessage(role: "system", content: "林栖记忆", source: .memory, nodeId: nil, pinnedToSystemPrefix: false),
            PromptMessage(role: "system", content: "云桥城世界书", source: .worldBook(entryName: "云桥城"), nodeId: nil, pinnedToSystemPrefix: false)
        ]
        let plan = PromptWire.plan(ordered, strategy: .degradeToUserNote)
        XCTAssertEqual(plan.systemSegments.map(\.source), [.slot(id: "main", name: "main"), .memory])
        XCTAssertEqual(plan.degradedSystemCount, 1, "非记忆世界书仍按旧策略降级")
        XCTAssertEqual(plan.messages.last?.chunks.last?.text, "<system_note>\n云桥城世界书\n</system_note>")
        XCTAssertFalse(plan.messages.flatMap(\.chunks).contains { $0.text.contains("林栖记忆") })

        var preset = Preset.balanced
        preset.sampling.cacheFriendly = true
        let profile = Profile(id: "recall-nonmemory", name: "岚舟", emoji: "", description: "",
                              userName: "星砚", assistantName: "岚舟")
        var entry = WorldBookEntry()
        entry.keys = ["云桥城"]
        entry.content = "世界书：云桥城天气"
        let assembled = PromptAssembler.assembleTagged(
            preset: preset, profile: profile, memories: [],
            chatHistory: [("user", "云桥城")], globalEntries: [entry], styleContent: "岚舟简短作答",
            statusNote: "星砚当前状态",
            recallLayers: RecallMemoryLayers(stable: "", volatile: "林栖本轮记忆", hits: [], pages: []))
        let dynamic = try XCTUnwrap(assembled.segments.first { $0.source == .volatileContext })
        XCTAssertEqual(dynamic.role, "user")
        XCTAssertTrue(dynamic.content.contains(entry.content))
        XCTAssertTrue(dynamic.content.contains("星砚当前状态"))
        XCTAssertFalse(dynamic.content.contains("林栖本轮记忆"))
        let realUser = try XCTUnwrap(PromptAssembler.orderedMessages(from: assembled.segments).last { !$0.isInjected && $0.role == "user" })
        XCTAssertTrue(realUser.content.hasSuffix("<style>岚舟简短作答</style>"))
    }

    func testEmptyPreparedRecallLayersDoNotFallBackToMemorySelection() {
        let profile = Profile(id: "recall-empty", name: "岚舟", emoji: "", description: "",
                              userName: "星砚", assistantName: "岚舟")
        for cache in [false, true] {
            var preset = Preset.balanced
            preset.sampling.cacheFriendly = cache
            let segments = PromptAssembler.assembleTagged(
                preset: preset, profile: profile, memories: [], chatHistory: [("user", "星砚原话")],
                selfMemory: "岚舟不应自动补回的记忆",
                recallLayers: RecallMemoryLayers(stable: "", volatile: "", hits: [], pages: [])).segments
            XCTAssertFalse(segments.contains { $0.source == .memory })
        }
    }

    func testDefaultRecallLayersKeepWikiAndSelfMemorySystemWithoutPreparedInput() throws {
        let profile = Profile(id: "recall-default-wire", name: "岚舟", emoji: "", description: "",
                              userName: "星砚", assistantName: "岚舟")
        let wiki = WikiInjectionSnapshot(indexLines: ["- [[人/林栖]] 林栖"],
                                         pages: [.init(path: "人/林栖", title: "林栖", triggers: [], hook: "云桥城的朋友", now: "周末见面")])
        for cache in [false, true] {
            var preset = Preset.balanced
            preset.sampling.cacheFriendly = cache
            for idx in preset.prompts.indices where preset.prompts[idx].id == PromptSlot.memoryInjectionId {
                preset.prompts[idx].role = "assistant"
                preset.prompts[idx].injectionPosition = .absolute
                preset.prompts[idx].injectionDepth = 0
            }
            let result = PromptAssembler.assembleTagged(preset: preset, profile: profile, memories: [],
                                                         chatHistory: [("user", "林栖")], selfMemory: "岚舟自己的记忆", wiki: wiki)
            let memory = result.segments.filter { $0.source == .memory }
            XCTAssertFalse(memory.isEmpty)
            XCTAssertTrue(memory.allSatisfy { $0.role == "system" })
            let ordered = PromptAssembler.orderedMessages(from: result.segments)
            let body = AnthropicProvider.buildRequestBody(ordered: ordered, model: "claude-sonnet-4-5",
                                                          samplingParams: preset.sampling, allowCacheControl: true)
            let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: body)) as? [String: Any])
            let system = (wire["system"] as? String)
                ?? (wire["system"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            for expected in ["岚舟自己的记忆", "[[人/林栖]]", "云桥城的朋友", "周末见面"] {
                XCTAssertTrue(system.contains(expected))
                XCTAssertFalse(messages(wire).map(text).joined().contains(expected))
            }
        }
    }

    // MARK: - 主闸：唯一允许的请求体差异是 Anthropic 末工具缓存断点，其余逐字节一致

    func testNoInjectionBodiesMatchPreChangeFixturesExceptLastToolCacheMark() {
        let all = ProviderOrderingScenarios.all()
        XCTAssertEqual(Set(all.map(\.name)), Set(Self.preChangeFixtures.keys), "每个夹具都要比")
        for s in all {
            let request = ProviderOrderingScenarios.strippingOrderedToolCacheMark(body(s, ordered(s)), scenario: s)
            let json = ProviderOrderingScenarios.canonicalJSON(request)
            XCTAssertEqual(json, Self.preChangeFixtures[s.name], "\(s.name) 请求体除明确新增的工具断点外与改前不一致")
        }
    }

    // MARK: - system → user → system(历史前注入) → history → depth0 system

    /// main(system) → 用户侧设定(user) → 历史前 system（absolute depth=3，落在 3 条历史之前）→ 历史 u/a/u → depth0 system
    private func interleavedScenario(anthropic: Bool = false, baseURL: String = "https://api.deepseek.com/v1", model: String = "deepseek-chat") -> ProviderOrderingScenario {
        scenario("interleaved", anthropic: anthropic, baseURL: baseURL, model: model,
                 extraSlots: [absolute("preSys", "历史前系统注入", role: "system", depth: 3),
                              absolute("tailSys", "尾部系统注入", role: "system", depth: 0)],
                 preHistoryUser: true)
    }

    private func systemTexts(_ ordered: [PromptMessage]) -> [String] {
        ordered.filter { $0.role == "system" }.map(\.content)
    }

    func testOrderedSequenceKeepsLogicalOrder() {
        let seq = ordered(interleavedScenario())
        XCTAssertEqual(seq.map(\.role), ["system", "system", "system", "user", "system", "user", "assistant", "user", "system"])
        XCTAssertEqual(seq[4].content, "历史前系统注入")
        XCTAssertEqual(seq.last?.content, "尾部系统注入")
        XCTAssertEqual(seq.filter { !$0.isInjected }.map(\.nodeId), ["n1", "n2", "n3"])
    }

    func testOpenAIInterleavedKeepsSystemInPlace() {
        let s = interleavedScenario(baseURL: "https://api.openai.com/v1", model: "gpt-4o")
        let b = body(s, ordered(s))
        XCTAssertEqual(roles(b), ["system", "user", "system", "user", "assistant", "user", "system"])
        let msgs = messages(b)
        XCTAssertEqual(text(msgs[2]), "历史前系统注入")
        XCTAssertEqual(text(msgs[6]), "尾部系统注入")
        XCTAssertFalse(text(msgs[0]).contains("系统注入"), "非前缀 system 不上移")
        XCTAssertEqual(msgs.map(text).filter { $0.contains(PromptWire.systemNoteOpen) }, [], "支持交错就不降级")
    }

    func testOpenAICompatibleWithoutCapabilityDegradesInPlaceAndMerges() {
        let s = interleavedScenario()
        let b = body(s, ordered(s))
        XCTAssertEqual(roles(b), ["system", "user", "assistant", "user"], "开头 system 进首条；其余降级成 user 并合并相邻同 role")
        let msgs = messages(b)
        XCTAssertEqual(text(msgs[1]), "（禾禾的补充设定）\n\n<system_note>\n历史前系统注入\n</system_note>\n\n你好 小岚",
                       "降级块在原位（用户侧设定之后、第一条历史之前）")
        XCTAssertEqual(text(msgs[3]), "今天好累\n\n<system_note>\n尾部系统注入\n</system_note>", "depth0 system 在最新一条之后")
        XCTAssertFalse(text(msgs[0]).contains("系统注入"))
    }

    func testAnthropicTopLevelSystemOnlyLeadingAndNotesInPlace() throws {
        let s = interleavedScenario(anthropic: true, baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5")
        let b = body(s, ordered(s))
        let system = try XCTUnwrap(b["system"] as? String)
        XCTAssertEqual(system, "你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园")
        XCTAssertEqual(roles(b), ["user", "assistant", "user"], "Anthropic 要交替：相邻同 role 合并")
        let msgs = messages(b)
        XCTAssertEqual(blockTypes(msgs[0]), ["text", "text", "text"])
        XCTAssertEqual(text(msgs[0]), "（禾禾的补充设定）|<system_note>\n历史前系统注入\n</system_note>|你好 小岚")
        XCTAssertEqual(text(msgs[2]), "今天好累|<system_note>\n尾部系统注入\n</system_note>")
    }

    func testNoSystemContentLostInAnyAdapter() {
        for (anthropic, baseURL, model) in [(false, "https://api.openai.com/v1", "gpt-4o"),
                                            (false, "https://api.deepseek.com/v1", "deepseek-chat"),
                                            (true, "https://api.anthropic.com/v1", "claude-sonnet-4-5")] {
            let s = interleavedScenario(anthropic: anthropic, baseURL: baseURL, model: model)
            let seq = ordered(s)
            let b = body(s, seq)
            // 按线上顺序收回所有 system 文本：顶层 system / role:system 消息 / <system_note> 块
            var recovered: [String] = []
            if let sys = b["system"] as? String { recovered.append(sys) }
            for message in messages(b) {
                let parts: [String] = (message["content"] as? String).map { [$0] }
                    ?? (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                for part in parts {
                    if (message["role"] as? String) == "system" { recovered.append(part); continue }
                    for chunk in part.components(separatedBy: "\n\n") where chunk.hasPrefix(PromptWire.systemNoteOpen) {
                        recovered.append(String(chunk.dropFirst(PromptWire.systemNoteOpen.count + 1)
                            .dropLast(PromptWire.systemNoteClose.count + 1)))
                    }
                }
            }
            // 开头连续 system 在线上被并成一条（"\n\n" 连接），按同样规则拆回比对
            let prefixCount = seq.prefix { $0.role == "system" }.count
            let expectedWire = [systemTexts(seq).prefix(prefixCount).joined(separator: "\n\n")] + systemTexts(seq).dropFirst(prefixCount)
            XCTAssertEqual(recovered, expectedWire, "\(baseURL) 有 system 丢失或乱序")
        }
    }

    // MARK: - depth0 user 注入：写作风格和图片挂在真实最后一条用户消息

    func testStyleAndImagesStayOnRealLastUserWithDepthZeroUserInjection() throws {
        // 注入段正文故意与第一条历史（带图）相同：按正文匹配会把图挂到注入上
        let slots = [absolute("tailUser", "看这张图", role: "user", depth: 0)]
        for (anthropic, baseURL, model) in [(false, "https://api.deepseek.com/v1", "deepseek-chat"),
                                            (true, "https://api.anthropic.com/v1", "claude-sonnet-4-5")] {
            let s = scenario("tailUser", anthropic: anthropic, baseURL: baseURL, model: model, extraSlots: slots,
                             history: ProviderOrderingScenarios.richHistory, styleContent: "简洁一点")
            let seq = ordered(s)
            let real = try XCTUnwrap(seq.last { $0.role == "user" && !$0.isInjected })
            XCTAssertEqual(real.nodeId, "n3")
            XCTAssertEqual(real.content, "再看这张和文件\n<style>简洁一点</style>")
            XCTAssertEqual(real.attachments.map(\.name), ["b.jpg", "c.txt"])
            XCTAssertEqual(seq.last?.content, "看这张图", "注入仍在最后")
            XCTAssertTrue(seq.last?.attachments.isEmpty == true, "注入段不挂图（不按正文匹配）")

            let msgs = messages(body(s, seq))
            XCTAssertEqual(msgs.last?["content"] as? String, "看这张图", "\(baseURL)：注入段纯文本，无 style、无图")
            let styled = msgs[msgs.count - 2]
            XCTAssertEqual(text(styled), "再看这张和文件\n<style>简洁一点</style>")
            XCTAssertEqual(blockTypes(styled), ["text", anthropic ? "image" : "image_url"], "\(baseURL)：真实消息带图")
            let first = try XCTUnwrap(msgs.first { text($0) == "看这张图" && !blockTypes($0).isEmpty })
            XCTAssertEqual(blockTypes(first), ["text", anthropic ? "image" : "image_url"], "第一条历史的图还在")
        }
        // 旧形态派生（CC / 非有序 provider）：imageMap 的键是带 style 的真实消息
        let legacy = PromptMessage.legacyShape(ordered(scenario("tailUser", extraSlots: slots,
                                                                history: ProviderOrderingScenarios.richHistory, styleContent: "简洁一点")))
        XCTAssertEqual(legacy.imageMap["再看这张和文件\n<style>简洁一点</style>"]?.map(\.name), ["b.jpg", "c.txt"])
        XCTAssertEqual(legacy.messages.last?.content, "看这张图")
    }

    func testAttachmentBlockOrderSurvivesMerge() {
        // Anthropic：真实最后一条（带图）+ depth0 system 降级块 + depth0 user 注入 → 合并成一条，块顺序不变
        let s = scenario("merge", anthropic: true, baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5",
                         extraSlots: [absolute("tailSys", "尾部系统注入", role: "system", depth: 0, order: 1),
                                      absolute("tailUser", "用户尾注", role: "user", depth: 0, order: 2)],
                         history: ProviderOrderingScenarios.richHistory, styleContent: "简洁一点")
        let msgs = messages(body(s, ordered(s)))
        XCTAssertEqual(msgs.compactMap { $0["role"] as? String }, ["user", "assistant", "user"])
        let last = msgs[2]
        XCTAssertEqual(blockTypes(last), ["text", "image", "text", "text"])
        XCTAssertEqual(text(last), "再看这张和文件\n<style>简洁一点</style>|<system_note>\n尾部系统注入\n</system_note>|用户尾注")
        XCTAssertEqual(((last["content"] as? [[String: Any]])?[1]["source"] as? [String: Any])?["data"] as? String,
                       Data([0xFF, 0xD8, 0x0B, 0x01, 0x02]).base64EncodedString())
        XCTAssertEqual(blockTypes(msgs[0]), ["text", "image"])

        // OpenAI 兼容降级合并：带图时用 parts 数组，按块顺序
        let o = scenario("merge-oai", extraSlots: [absolute("tailSys", "尾部系统注入", role: "system", depth: 0)],
                         history: ProviderOrderingScenarios.richHistory)
        let om = messages(body(o, ordered(o)))
        XCTAssertEqual(blockTypes(om.last ?? [:]), ["text", "image_url", "text"])
        XCTAssertEqual(text(om.last ?? [:]), "再看这张和文件|<system_note>\n尾部系统注入\n</system_note>")
    }

    // MARK: - 以 assistant 结尾（depth0 assistant 注入）：维持现状

    func testTrailingAssistantInjectionIsKeptAsPrefill() {
        let s = scenario("prefill", anthropic: true, baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5",
                         extraSlots: [absolute("prefill", "（小岚想了想）", role: "assistant", depth: 0)])
        let msgs = messages(body(s, ordered(s)))
        XCTAssertEqual(msgs.last?["role"] as? String, "assistant")
        XCTAssertEqual(msgs.last?["content"] as? String, "（小岚想了想）")
    }

    // MARK: - 能力标记与 cacheFriendly

    func testInterleavedSystemCapabilityIsExplicitAllowList() {
        func interleaved(_ url: String, _ model: String) -> Bool {
            ResolvedCompat.resolve(providerType: .openaiCompatible, baseURL: url, modelId: model, sampling: nil, store: nil).interleavedSystem
        }
        XCTAssertTrue(interleaved("https://api.openai.com/v1", "gpt-4o"))
        XCTAssertTrue(interleaved("https://openrouter.ai/api/v1", "openai/gpt-4o"))
        for (url, model) in [("https://openrouter.ai/api/v1", "anthropic/claude-sonnet-4.5"),
                             ("https://openrouter.ai/api/v1", "deepseek/deepseek-chat"),
                             ("https://api.deepseek.com/v1", "deepseek-chat"),
                             ("https://api.siliconflow.cn/v1", "Qwen/Qwen3"),
                             ("https://api.moonshot.cn/v1", "kimi-k2"),
                             ("https://generativelanguage.googleapis.com/v1beta/openai", "gemini-2.5-pro"),
                             ("https://relay.example.com/v1", "gpt-4o")] {
            XCTAssertFalse(interleaved(url, model), "\(url) \(model) 未核实，默认降级")
        }
    }

    func testAnthropicCacheMarksStillApplyWithDegradedSystem() throws {
        let s = scenario("cache", anthropic: true, baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5",
                         extraSlots: [absolute("tailSys", "尾部系统注入", role: "system", depth: 0)], cacheFriendly: true)
        let b = body(s, ordered(s))
        let system = try XCTUnwrap(b["system"] as? [[String: Any]])
        XCTAssertNotNil(system.first?["cache_control"], "BP1 顶层 system 挂标")
        let msgs = messages(b)
        let assistant = try XCTUnwrap(msgs.last { ($0["role"] as? String) == "assistant" })
        XCTAssertNotNil((assistant["content"] as? [[String: Any]])?.last?["cache_control"], "BP4 最后一条 assistant 挂标")
        XCTAssertTrue(text(msgs.last ?? [:]).contains("<system_note>\n尾部系统注入\n</system_note>"))
    }

    private func cacheWireOrdered(
        stablePrefixes: [String] = ["身份：岚舟", "Z：星砚住在云桥城"],
        memorySuffixes: [String]
    ) -> [PromptMessage] {
        let prefix = stablePrefixes.enumerated().map { index, content in
            PromptMessage(role: "system", content: content,
                          source: index == 0 ? .slot(id: "main", name: "main") : .memory,
                          nodeId: nil, pinnedToSystemPrefix: false)
        }
        let history = [
            PromptMessage(role: "user", content: "星砚原话", source: .chatHistory, nodeId: "u1", pinnedToSystemPrefix: false),
            PromptMessage(role: "assistant", content: "岚舟答复", source: .chatHistory, nodeId: "a1", pinnedToSystemPrefix: false),
            PromptMessage(role: "user", content: "再聊林栖", source: .chatHistory, nodeId: "u2", pinnedToSystemPrefix: false)
        ]
        return prefix + history + memorySuffixes.map {
            PromptMessage(role: "system", content: $0, source: .memory, nodeId: nil, pinnedToSystemPrefix: false)
        }
    }

    private func cacheWireTool(_ name: String, deferred: Bool? = nil) -> [String: Any] {
        var tool: [String: Any] = [
            "name": name, "description": "虚构工具 \(name)",
            "input_schema": ["type": "object", "properties": [:]] as [String: Any]
        ]
        if let deferred { tool["defer_loading"] = deferred }
        return tool
    }

    func testAnthropicOrderedCacheSeparatesVolatileMemoryAndKeepsStableBytes() throws {
        let suffixes = ["X：林栖约了周末见面\n原文尾行  ", "X：林栖改约下周\n新原文尾行  "]
        let params = ProviderOrderingScenarios.preset(cacheFriendly: true).sampling
        var systems: [[[String: Any]]] = []
        for suffix in suffixes {
            let request = AnthropicProvider.buildRequestBody(
                ordered: cacheWireOrdered(memorySuffixes: [suffix]), model: "claude-sonnet-4-5",
                samplingParams: params)
            let system = try XCTUnwrap(request["system"] as? [[String: Any]])
            XCTAssertEqual(system.count, 2)
            guard system.count == 2 else { return }
            XCTAssertEqual(system.compactMap { $0["type"] as? String }, ["text", "text"])
            XCTAssertEqual(system[0]["text"] as? String, "身份：岚舟\n\nZ：星砚住在云桥城")
            XCTAssertEqual(system[1]["text"] as? String, "\n\n" + suffix, "分隔符只加在 X 开头，原文不裁剪")
            XCTAssertEqual(system.filter { $0["cache_control"] != nil }.count, 1)
            let mark = try XCTUnwrap(system[0]["cache_control"] as? [String: Any])
            XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(mark), #"{"ttl":"1h","type":"ephemeral"}"#)
            XCTAssertNil(system[1]["cache_control"])
            let expected = suffix == suffixes[0]
                ? "身份：岚舟\n\nZ：星砚住在云桥城\n\nX：林栖约了周末见面\n原文尾行  "
                : "身份：岚舟\n\nZ：星砚住在云桥城\n\nX：林栖改约下周\n新原文尾行  "
            XCTAssertEqual(Array(system.compactMap { $0["text"] as? String }.joined().utf8), Array(expected.utf8),
                           "两块直接拼接必须等于改前 systemPrompt 的独立字面期望")
            XCTAssertFalse(messages(request).map(text).joined().contains(suffix))
            let assistant = try XCTUnwrap(messages(request).first { $0["role"] as? String == "assistant" })
            let assistantBlocks = try XCTUnwrap(assistant["content"] as? [[String: Any]])
            XCTAssertEqual(assistantBlocks.count, 1)
            XCTAssertEqual(assistantBlocks.first?["text"] as? String, "岚舟答复")
            XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(try XCTUnwrap(assistantBlocks.last?["cache_control"] as? [String: Any])),
                           ProviderOrderingScenarios.canonicalJSON(mark), "BP4 保持原来的最后 assistant 断点")
            systems.append(system)
        }
        XCTAssertEqual(Array(ProviderOrderingScenarios.canonicalJSON(systems[0][0]).utf8),
                       Array(ProviderOrderingScenarios.canonicalJSON(systems[1][0]).utf8),
                       "换 X 不能改变稳定块 canonical bytes")
        XCTAssertNotEqual(ProviderOrderingScenarios.canonicalJSON(systems[0][1]),
                          ProviderOrderingScenarios.canonicalJSON(systems[1][1]))
    }

    func testAnthropicOrderedCacheStableBytesSurviveMemoryAppearanceAndClearing() throws {
        let params = ProviderOrderingScenarios.preset(cacheFriendly: true).sampling
        let stableText = "身份：岚舟\n\nZ：星砚住在云桥城"
        let rounds: [[String]] = [[], ["X：林栖周末见面  "], []]
        var stableBytes: [[UInt8]] = []
        for suffixes in rounds {
            let request = AnthropicProvider.buildRequestBody(
                ordered: cacheWireOrdered(memorySuffixes: suffixes), model: "claude-sonnet-4-5",
                samplingParams: params)
            let system = try XCTUnwrap(request["system"] as? [[String: Any]])
            XCTAssertEqual(system.count, suffixes.isEmpty ? 1 : 2)
            let stable = try XCTUnwrap(system.first)
            XCTAssertEqual(stable["text"] as? String, stableText)
            let mark = try XCTUnwrap(stable["cache_control"] as? [String: Any])
            XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(mark), #"{"ttl":"1h","type":"ephemeral"}"#)
            XCTAssertTrue(system.dropFirst().allSatisfy { $0["cache_control"] == nil })
            let expectedText = suffixes.isEmpty ? stableText : stableText + "\n\nX：林栖周末见面  "
            XCTAssertEqual(Array(system.compactMap { $0["text"] as? String }.joined().utf8),
                           Array(expectedText.utf8))
            stableBytes.append(Array(ProviderOrderingScenarios.canonicalJSON(stable).utf8))
        }
        XCTAssertEqual(stableBytes[0], stableBytes[1], "X 出现不能改变稳定块 canonical bytes")
        XCTAssertEqual(stableBytes[1], stableBytes[2], "X 清空不能改变稳定块 canonical bytes")
    }

    func testAnthropicOrderedCacheJoinsMultiplePrefixesAndMemorySuffixesWithoutLosingBytes() throws {
        let request = AnthropicProvider.buildRequestBody(
            ordered: cacheWireOrdered(stablePrefixes: ["身份：岚舟\n", "Z：星砚住在云桥城", "规则：不复述"],
                                      memorySuffixes: ["X：林栖周末见面\n", "X：展览在云桥城  "]),
            model: "claude-sonnet-4-5", samplingParams: ProviderOrderingScenarios.preset(cacheFriendly: true).sampling)
        let system = try XCTUnwrap(request["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 2)
        XCTAssertEqual(system.first?["text"] as? String, "身份：岚舟\n\n\nZ：星砚住在云桥城\n\n规则：不复述")
        XCTAssertEqual(system.last?["text"] as? String, "\n\nX：林栖周末见面\n\n\nX：展览在云桥城  ")
        XCTAssertNotNil(system.first?["cache_control"])
        XCTAssertNil(system.last?["cache_control"])
        XCTAssertEqual(Array(system.compactMap { $0["text"] as? String }.joined().utf8),
                       Array("身份：岚舟\n\n\nZ：星砚住在云桥城\n\n规则：不复述\n\nX：林栖周末见面\n\n\nX：展览在云桥城  ".utf8))
    }

    func testAnthropicOrderedCacheWithoutStablePrefixFallsBackToSingleMarkedBlock() throws {
        let request = AnthropicProvider.buildRequestBody(
            ordered: cacheWireOrdered(stablePrefixes: [], memorySuffixes: ["X：林栖周末见面", "X：云桥城展览  "]),
            model: "claude-sonnet-4-5", samplingParams: ProviderOrderingScenarios.preset(cacheFriendly: true).sampling,
            tools: [cacheWireTool("lookup")])
        let system = try XCTUnwrap(request["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1, "全易变时沿用单块，不伪造空的稳定缓存块")
        XCTAssertEqual(system.first?["text"] as? String, "X：林栖周末见面\n\nX：云桥城展览  ")
        let mark = try XCTUnwrap(system.first?["cache_control"] as? [String: Any])
        XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(mark), #"{"ttl":"1h","type":"ephemeral"}"#)
        let tools = try XCTUnwrap(request["tools"] as? [[String: Any]])
        XCTAssertNotNil(tools.last?["cache_control"], "没有稳定 system 不影响 tools 断点")
    }

    func testAnthropicOrderedCacheWithEmptyStableTextFallsBackToSingleMarkedBlock() throws {
        let request = AnthropicProvider.buildRequestBody(
            ordered: cacheWireOrdered(stablePrefixes: [""], memorySuffixes: ["X：林栖周末见面  "]),
            model: "claude-sonnet-4-5", samplingParams: ProviderOrderingScenarios.preset(cacheFriendly: true).sampling)
        let system = try XCTUnwrap(request["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system.first?["text"] as? String, "\n\nX：林栖周末见面  ", "回退不能丢失原 systemPrompt 的分隔符")
        let mark = try XCTUnwrap(system.first?["cache_control"] as? [String: Any])
        XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(mark), #"{"ttl":"1h","type":"ephemeral"}"#)
    }

    func testAnthropicOrderedCacheWithEmptyVolatileTextPreservesSeparator() throws {
        let request = AnthropicProvider.buildRequestBody(
            ordered: cacheWireOrdered(memorySuffixes: [""]), model: "claude-sonnet-4-5",
            samplingParams: ProviderOrderingScenarios.preset(cacheFriendly: true).sampling)
        let system = try XCTUnwrap(request["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 2)
        XCTAssertEqual(system.last?["text"] as? String, "\n\n", "空 X 仍保留合法非空的分隔符块")
        XCTAssertNotNil(system.first?["cache_control"])
        XCTAssertNil(system.last?["cache_control"])
        XCTAssertEqual(Array(system.compactMap { $0["text"] as? String }.joined().utf8),
                       Array("身份：岚舟\n\nZ：星砚住在云桥城\n\n".utf8))
    }

    func testAnthropicOrderedCacheWithoutMemoryOrToolsIsByteIdenticalToLegacyBuilder() throws {
        let ordered = cacheWireOrdered(memorySuffixes: [])
        let legacy = PromptMessage.legacyShape(ordered)
        XCTAssertEqual(legacy.systemPrompt, "身份：岚舟\n\nZ：星砚住在云桥城")
        for cacheFriendly in [false, true] {
            let params = ProviderOrderingScenarios.preset(cacheFriendly: cacheFriendly).sampling
            let request = AnthropicProvider.buildRequestBody(ordered: ordered, model: "claude-sonnet-4-5", samplingParams: params)
            let oldRequest = AnthropicProvider.buildRequestBody(
                messages: legacy.messages, model: "claude-sonnet-4-5", systemPrompt: legacy.systemPrompt,
                samplingParams: params, imageMap: legacy.imageMap)
            XCTAssertEqual(Array(ProviderOrderingScenarios.canonicalJSON(request).utf8),
                           Array(ProviderOrderingScenarios.canonicalJSON(oldRequest).utf8))
            XCTAssertNil(request["tools"])
            if cacheFriendly {
                let system = try XCTUnwrap(request["system"] as? [[String: Any]])
                XCTAssertEqual(system.count, 1)
                XCTAssertEqual(system.first?["text"] as? String, "身份：岚舟\n\nZ：星砚住在云桥城",
                               "无 X 时不得添加末尾分隔符")
            }
        }
    }

    func testAnthropicOrderedToolsMarkOnlyLastNonDeferredToolWithSharedTTL() throws {
        let cases: [(tools: [[String: Any]], markedIndex: Int?)] = [
            ([cacheWireTool("first"), cacheWireTool("last")], 1),
            (ProviderOrderingScenarios.tool + [
                cacheWireTool("deferred_middle", deferred: true),
                cacheWireTool("last_active", deferred: false),
                cacheWireTool("deferred_tail", deferred: true)
            ], 2),
            ([cacheWireTool("deferred_first", deferred: true), cacheWireTool("deferred_last", deferred: true)], nil)
        ]
        for longTTL in [false, true] {
            var params = ProviderOrderingScenarios.preset(cacheFriendly: true).sampling
            params.cacheLongTTL = longTTL
            let expectedMark = longTTL ? #"{"ttl":"1h","type":"ephemeral"}"# : #"{"type":"ephemeral"}"#
            for testCase in cases {
                let request = AnthropicProvider.buildRequestBody(
                    ordered: cacheWireOrdered(memorySuffixes: ["X：林栖周末见面"]),
                    model: "claude-sonnet-4-5", samplingParams: params, tools: testCase.tools)
                var tools = try XCTUnwrap(request["tools"] as? [[String: Any]])
                XCTAssertEqual(tools.count, testCase.tools.count)
                XCTAssertEqual(tools.indices.filter { tools[$0]["cache_control"] != nil },
                               testCase.markedIndex.map { [$0] } ?? [])
                if let index = testCase.markedIndex {
                    let mark = try XCTUnwrap(tools[index].removeValue(forKey: "cache_control") as? [String: Any])
                    XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(mark), expectedMark)
                }
                XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(["tools": tools]),
                               ProviderOrderingScenarios.canonicalJSON(["tools": ToolSchemaRenderer.anthropic(testCase.tools)]),
                               "除新断点外，工具 schema、defer_loading 和顺序保持原样")
                let system = try XCTUnwrap(request["system"] as? [[String: Any]])
                let systemMark = try XCTUnwrap(system.first?["cache_control"] as? [String: Any])
                XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(systemMark), expectedMark)
                let assistant = try XCTUnwrap(messages(request).first { $0["role"] as? String == "assistant" })
                let assistantMark = try XCTUnwrap((assistant["content"] as? [[String: Any]])?.last?["cache_control"] as? [String: Any])
                XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(assistantMark), expectedMark)
            }
        }
    }

    func testAnthropicOrderedCacheDisabledKeepsSystemStringAndNoMarksAnywhere() {
        let tools = [cacheWireTool("first"), cacheWireTool("last"), cacheWireTool("deferred", deferred: true)]
        for (cacheFriendly, allowCacheControl) in [(false, true), (true, false), (false, false)] {
            let request = AnthropicProvider.buildRequestBody(
                ordered: cacheWireOrdered(memorySuffixes: ["X：林栖周末见面", "X：云桥城展览  "]),
                model: "claude-sonnet-4-5", samplingParams: ProviderOrderingScenarios.preset(cacheFriendly: cacheFriendly).sampling,
                tools: tools, toolTurns: [ProviderOrderingScenarios.toolTurn], allowCacheControl: allowCacheControl)
            XCTAssertEqual(request["system"] as? String, "身份：岚舟\n\nZ：星砚住在云桥城\n\nX：林栖周末见面\n\nX：云桥城展览  ")
            XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(["tools": request["tools"] ?? []]),
                           ProviderOrderingScenarios.canonicalJSON(["tools": tools]))
            XCTAssertFalse(ProviderOrderingScenarios.canonicalJSON(request).contains(#""cache_control""#),
                           "cacheFriendly=\(cacheFriendly), allowCacheControl=\(allowCacheControl)：system/tools/messages 都不得挂标")
        }
    }

    func testAnthropicLegacyBuilderNeverAddsOrderedToolCacheMarksOrSplitsSystem() throws {
        let tools = ProviderOrderingScenarios.tool + [cacheWireTool("last"), cacheWireTool("deferred", deferred: true)]
        for cacheFriendly in [false, true] {
            let request = AnthropicProvider.buildRequestBody(
                messages: [("user", "星砚原话"), ("assistant", "岚舟答复"), ("user", "再聊林栖")],
                model: "claude-sonnet-4-5", systemPrompt: "身份：岚舟\n\nX：林栖周末见面",
                samplingParams: ProviderOrderingScenarios.preset(cacheFriendly: cacheFriendly).sampling, tools: tools)
            let wireTools = try XCTUnwrap(request["tools"] as? [[String: Any]])
            XCTAssertTrue(wireTools.allSatisfy { $0["cache_control"] == nil })
            XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(["tools": wireTools]),
                           ProviderOrderingScenarios.canonicalJSON(["tools": ToolSchemaRenderer.anthropic(tools)]))
            if cacheFriendly {
                let system = try XCTUnwrap(request["system"] as? [[String: Any]])
                XCTAssertEqual(system.count, 1, "非 ordered 入口仍缓存完整 system，不套用新边界")
                XCTAssertEqual(system.first?["text"] as? String, "身份：岚舟\n\nX：林栖周末见面")
                XCTAssertNotNil(system.first?["cache_control"])
            } else {
                XCTAssertEqual(request["system"] as? String, "身份：岚舟\n\nX：林栖周末见面")
            }
        }
    }

    /// thinking 回传 §6：当轮回传夹具（思考 + 正文 + 进度更新思考 + tool_use，审批卡改过 input）——
    /// 只有这一条 assistant 变成原样块（只换 input、BP4 挂在 tool_use），其余和老夹具逐字节相同
    func testAnthropicToolTurnEchoesThisTurnsBlocksVerbatim() throws {
        let base = try XCTUnwrap(ProviderOrderingScenarios.all().first { $0.name == "anthropic-cache-tools" })
        let legacyTurn = ProviderOrderingScenarios.toolTurn
        let content: [[String: Any]] = [
            ["type": "thinking", "thinking": "先想", "signature": "sig-0"],
            ["type": "text", "text": "我读一下"],
            ["type": "thinking", "thinking": "", "signature": "sig-progress"],
            ["type": "tool_use", "id": "call_1", "name": "fs_read", "input": ["path": "model-wrote.md"]],
        ]
        let s = ProviderOrderingScenario(name: "anthropic-thinking-echo", anthropic: true, baseURL: base.baseURL, model: base.model,
                                         preset: base.preset, profile: base.profile, history: base.history, styleContent: base.styleContent,
                                         fileLibrary: base.fileLibrary, folderInstructions: base.folderInstructions, volatileNote: base.volatileNote,
                                         tools: base.tools,
                                         toolTurns: [ToolTurn(calls: legacyTurn.calls, results: legacyTurn.results, assistantContent: content)])
        var echoed = messages(body(s, ordered(s)))
        let legacy = messages(body(base, ordered(base)))
        let idx = try XCTUnwrap(echoed.lastIndex { ($0["role"] as? String) == "assistant" })
        let blocks = try XCTUnwrap(echoed[idx]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["thinking", "text", "thinking", "tool_use"])
        for i in 0..<3 {
            XCTAssertTrue(NSDictionary(dictionary: blocks[i]).isEqual(to: content[i]), "第 \(i) 块原样")
        }
        XCTAssertEqual((blocks[3]["input"] as? [String: Any])?["path"] as? String, "a.md", "只换成发出去的 input")
        XCTAssertNotNil(blocks[3]["cache_control"], "BP4 挂在最后一个非思考块")
        XCTAssertEqual(blocks.filter { $0["cache_control"] != nil }.count, 1)
        echoed[idx] = legacy[idx]
        XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(["m": echoed]), ProviderOrderingScenarios.canonicalJSON(["m": legacy]),
                       "其余消息一个字节不变")
    }

    /// 模型兼容 P0 §5.4：DeepSeek host + 当轮有思考 + 开关开 → 工具那条 assistant 多一个 reasoning_content，其余和老夹具逐字节相同
    func testOpenAIToolTurnReplaysReasoningOnlyOnThatMessage() throws {
        let base = try XCTUnwrap(ProviderOrderingScenarios.all().first { $0.name == "oai-rich" })
        var reasoning = ReasoningCapture()
        reasoning.field = "reasoning_content"
        reasoning.text = "先读文件再回答"
        var turn = ProviderOrderingScenarios.toolTurn
        turn.reasoning = reasoning
        let s = ProviderOrderingScenario(name: "oai-reasoning-replay", anthropic: false, baseURL: base.baseURL, model: base.model,
                                         preset: base.preset, profile: base.profile, history: base.history, styleContent: base.styleContent,
                                         fileLibrary: base.fileLibrary, folderInstructions: base.folderInstructions, volatileNote: base.volatileNote,
                                         tools: base.tools, toolTurns: [turn])
        var compat = ProviderOrderingScenarios.wireCompat(baseURL: s.baseURL, model: s.model, sampling: s.preset.sampling)
        compat.requiresReasoningContentForToolCalls = ResolvedCompat.resolve(providerType: .openaiCompatible, baseURL: s.baseURL, modelId: s.model,
                                                                             sampling: s.preset.sampling, store: nil).requiresReasoningContentForToolCalls
        XCTAssertTrue(compat.requiresReasoningContentForToolCalls)
        var replayed = OpenAICompatibleProvider.buildRequestBody(ordered: ordered(s), model: s.model, samplingParams: s.preset.sampling,
                                                                 tools: s.tools, toolTurns: s.toolTurns, compat: compat)
        var msgs = messages(replayed)
        let idx = try XCTUnwrap(msgs.firstIndex { $0["tool_calls"] != nil })
        XCTAssertEqual(msgs[idx].removeValue(forKey: "reasoning_content") as? String, "先读文件再回答")
        replayed["messages"] = msgs
        XCTAssertEqual(ProviderOrderingScenarios.canonicalJSON(replayed), Self.preChangeFixtures["oai-rich"], "去掉回传字段后和老夹具逐字节相同")
    }

    // MARK: - 改码前旧管线落盘的请求体（sortedKeys 序列化；metadata.user_id 换占位）
    // 10-01 输出上限（plan-output-token-cap）：OpenAI 兼容一律显式发 max_tokens；Anthropic thinking 预算加在上限之上（8000 + 中档 4096）。除这两处外逐字节未动
    // 10-14 claude-sonnet-4-5 temperature 和 top_p 只收一个：anthropic-plain / anthropic-first-turn 去掉 top_p（只这一处）
    static let preChangeFixtures: [String: String] = [
        "oai-plain": ##"{"max_tokens":4096,"messages":[{"content":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园","role":"system"},{"content":"你好 小岚","role":"user"},{"content":"在呢，禾禾。","role":"assistant"},{"content":"今天好累","role":"user"}],"model":"deepseek-chat","stream":true,"stream_options":{"include_usage":true},"temperature":0.69999999999999996,"top_p":0.94999999999999996}"##,
        "oai-rich": ##"{"max_tokens":2000,"messages":[{"content":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[文件夹说明]\n文件夹：日常\n\n[当前场景]\n傍晚的花园\n\n[文件库] 禾禾 的文件在这里","role":"system"},{"content":"（禾禾的补充设定）","role":"user"},{"content":[{"text":"看这张图","type":"text"},{"image_url":{"url":"data:image\/jpeg;base64,\/9gKAQI="},"type":"image_url"}],"role":"user"},{"content":"好看！","role":"assistant"},{"content":[{"text":"再看这张和文件\n<style>简洁一点<\/style>","type":"text"},{"image_url":{"url":"data:image\/jpeg;base64,\/9gLAQI="},"type":"image_url"}],"role":"user"},{"content":"","role":"assistant","tool_calls":[{"function":{"arguments":"{\"path\":\"a.md\"}","name":"fs_read"},"id":"call_1","type":"function"}]},{"content":"文件内容","role":"tool","tool_call_id":"call_1"}],"model":"deepseek-chat","stream":true,"stream_options":{"include_usage":true},"temperature":0.90000000000000002,"tools":[{"function":{"description":"读文件","name":"fs_read","parameters":{"properties":{},"type":"object"}},"type":"function"}],"top_p":0.94999999999999996}"##,
        "oai-official": ##"{"max_tokens":4096,"messages":[{"content":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园\n\n[文件库] 说明","role":"system"},{"content":"（禾禾的补充设定）","role":"user"},{"content":[{"text":"看这张图","type":"text"},{"image_url":{"url":"data:image\/jpeg;base64,\/9gKAQI="},"type":"image_url"}],"role":"user"},{"content":"好看！","role":"assistant"},{"content":[{"text":"再看这张和文件\n<style>简洁一点<\/style>","type":"text"},{"image_url":{"url":"data:image\/jpeg;base64,\/9gLAQI="},"type":"image_url"}],"role":"user"}],"model":"gpt-4o","stream":true,"stream_options":{"include_usage":true},"temperature":0.69999999999999996,"top_p":0.94999999999999996}"##,
        "or-claude-cache": ##"{"max_tokens":4096,"messages":[{"content":[{"cache_control":{"ttl":"1h","type":"ephemeral"},"text":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园","type":"text"}],"role":"system"},{"content":[{"text":"看这张图","type":"text"},{"image_url":{"url":"data:image\/jpeg;base64,\/9gKAQI="},"type":"image_url"}],"role":"user"},{"content":[{"cache_control":{"ttl":"1h","type":"ephemeral"},"text":"好看！","type":"text"}],"role":"assistant"},{"content":"[动态上下文｜仅供参考，不要复述]\n今天的日记","role":"user"},{"content":[{"text":"再看这张和文件\n<style>简洁一点<\/style>","type":"text"},{"image_url":{"url":"data:image\/jpeg;base64,\/9gLAQI="},"type":"image_url"}],"role":"user"}],"model":"anthropic\/claude-sonnet-4.5","stream":true,"stream_options":{"include_usage":true},"temperature":0.69999999999999996,"top_p":0.94999999999999996}"##,
        "or-deepseek-cache": ##"{"max_tokens":4096,"messages":[{"content":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园","role":"system"},{"content":"你好 小岚","role":"user"},{"content":"在呢，禾禾。","role":"assistant"},{"content":"[动态上下文｜仅供参考，不要复述]\n今天的日记","role":"user"},{"content":"今天好累","role":"user"}],"model":"deepseek\/deepseek-chat","provider":{"allow_fallbacks":true,"order":["deepseek"]},"stream":true,"stream_options":{"include_usage":true},"temperature":0.69999999999999996,"top_p":0.94999999999999996}"##,
        "anthropic-plain": ##"{"max_tokens":4096,"messages":[{"content":"（禾禾的补充设定）","role":"user"},{"content":[{"text":"看这张图","type":"text"},{"source":{"data":"\/9gKAQI=","media_type":"image\/jpeg","type":"base64"},"type":"image"}],"role":"user"},{"content":"好看！","role":"assistant"},{"content":[{"text":"再看这张和文件\n<style>简洁一点<\/style>","type":"text"},{"source":{"data":"\/9gLAQI=","media_type":"image\/jpeg","type":"base64"},"type":"image"}],"role":"user"}],"model":"claude-sonnet-4-5","stream":true,"system":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[文件夹说明]\n文件夹：日常\n\n[当前场景]\n傍晚的花园\n\n[文件库] 说明","temperature":0.69999999999999996}"##,
        "anthropic-cache-tools": ##"{"max_tokens":12096,"messages":[{"content":"你好 小岚","role":"user"},{"content":"在呢，禾禾。","role":"assistant"},{"content":"[动态上下文｜仅供参考，不要复述]\n今天的日记","role":"user"},{"content":"今天好累\n<style>简洁一点<\/style>","role":"user"},{"content":[{"cache_control":{"ttl":"1h","type":"ephemeral"},"id":"call_1","input":{"path":"a.md"},"name":"fs_read","type":"tool_use"}],"role":"assistant"},{"content":[{"content":"文件内容","tool_use_id":"call_1","type":"tool_result"}],"role":"user"}],"metadata":{"user_id":"{{CACHE_USER_ID}}"},"model":"claude-sonnet-4-5","stream":true,"system":[{"cache_control":{"ttl":"1h","type":"ephemeral"},"text":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园","type":"text"}],"thinking":{"budget_tokens":4096,"type":"enabled"},"tools":[{"description":"读文件","input_schema":{"properties":{},"type":"object"},"name":"fs_read"}],"top_p":0.94999999999999996}"##,
        "anthropic-first-turn": ##"{"max_tokens":4096,"messages":[{"content":[{"text":"第一句\n<style>简洁一点<\/style>","type":"text"},{"source":{"data":"\/9gNAQI=","media_type":"image\/jpeg","type":"base64"},"type":"image"}],"role":"user"}],"model":"claude-sonnet-4-5","stream":true,"system":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园","temperature":0.69999999999999996}"##,
    ]
}

// ===== 典型请求夹具（改代码前后逐字相同的输入；fixture 在 ④b 改码前用旧管线落盘）=====
struct ProviderOrderingScenario {
    struct Turn {
        let id: String
        let role: String
        let content: String
        let images: [PendingChatAttachment]
    }
    let name: String
    let anthropic: Bool
    let baseURL: String
    let model: String
    let preset: Preset
    let profile: Profile
    let history: [Turn]
    let styleContent: String?
    let fileLibrary: String?
    let folderInstructions: String?
    let volatileNote: String?
    let tools: [[String: Any]]?
    let toolTurns: [ToolTurn]
}

enum ProviderOrderingScenarios {
    /// 旧夹具唯一豁免：先验证原生 Anthropic 末工具断点的形状，再移除它以比较其余字节。
    static func strippingOrderedToolCacheMark(
        _ body: [String: Any], scenario: ProviderOrderingScenario,
        file: StaticString = #filePath, line: UInt = #line
    ) -> [String: Any] {
        guard scenario.name == "anthropic-cache-tools" else { return body }
        guard var tools = body["tools"] as? [[String: Any]], tools.count == 1,
              let mark = tools[0].removeValue(forKey: "cache_control") as? [String: Any] else {
            XCTFail("anthropic-cache-tools 必须有唯一的末工具缓存断点", file: file, line: line)
            return body
        }
        XCTAssertEqual(canonicalJSON(mark), #"{"ttl":"1h","type":"ephemeral"}"#, file: file, line: line)
        var stripped = body
        stripped["tools"] = tools
        return stripped
    }

    /// 夹具口径：采样层全发（.permissive），只取 host 判断那几项（OR 挂标 / 路由、序列内 system）
    static func wireCompat(baseURL: String, model: String, sampling: SamplingParams?) -> ResolvedCompat {
        let resolved = ResolvedCompat.resolve(providerType: .openaiCompatible, baseURL: baseURL, modelId: model,
                                              sampling: sampling, store: nil)
        return ResolvedCompat(interleavedSystem: resolved.interleavedSystem, orCacheControl: resolved.orCacheControl,
                              orProviderOrder: resolved.orProviderOrder)
    }

    static func image(_ name: String, _ byte: UInt8) -> PendingChatAttachment {
        var att = try! PendingChatAttachment.image(name: name, typeDescription: "图片", mimeType: "image/jpeg",
                                                   data: Data([0xFF, 0xD8, byte, 0x01, 0x02]))
        att.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02X", byte))")!
        return att
    }

    static func file(_ name: String) -> PendingChatAttachment {
        .text(name: name, typeDescription: name, extractedText: "", byteCount: 3, fileData: Data([1, 2, 3]), fileMime: "text/plain")
    }

    static func profile() -> Profile {
        Profile(name: "测试", emoji: "🧪", description: "", userName: "禾禾", assistantName: "小岚",
                systemPrompt: "你是{{char}}，陪{{user}}聊天。", characterDescription: "温柔的角色", scenario: "傍晚的花园")
    }

    static func slots(preHistoryUser: Bool = false) -> [PromptSlot] {
        var s: [PromptSlot] = [
            PromptSlot(id: PromptSlot.mainId, name: "系统指令", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 0),
            PromptSlot(id: PromptSlot.charDescriptionId, name: "助手设定", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 20),
            PromptSlot(id: PromptSlot.scenarioId, name: "场景", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 30),
        ]
        if preHistoryUser {
            s.append(PromptSlot(id: "preUser", name: "用户侧设定", role: "user", content: "（{{user}}的补充设定）", injectionOrder: 40))
        }
        s.append(PromptSlot(id: PromptSlot.chatHistoryId, name: "对话历史", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 60))
        return SlotOrder.normalized(s)
    }

    static func preset(preHistoryUser: Bool = false, cacheFriendly: Bool = false, tweak: (inout SamplingParams) -> Void = { _ in }) -> Preset {
        var p = Preset(name: "夹具")
        p.prompts = slots(preHistoryUser: preHistoryUser)
        p.sampling.cacheFriendly = cacheFriendly
        tweak(&p.sampling)
        return p
    }

    static let plainHistory: [ProviderOrderingScenario.Turn] = [
        .init(id: "n1", role: "user", content: "你好 {{char}}", images: []),
        .init(id: "n2", role: "assistant", content: "在呢，{{user}}。", images: []),
        .init(id: "n3", role: "user", content: "今天好累", images: []),
    ]

    static let richHistory: [ProviderOrderingScenario.Turn] = [
        .init(id: "n1", role: "user", content: "看这张图", images: [image("a.jpg", 0x0A)]),
        .init(id: "n2", role: "assistant", content: "好看！", images: []),
        .init(id: "n3", role: "user", content: "再看这张和文件", images: [image("b.jpg", 0x0B), file("c.txt")]),
    ]

    static let tool: [[String: Any]] = [["type": "function", "function": ["name": "fs_read", "description": "读文件",
                                                                         "parameters": ["type": "object", "properties": [:]]]]]
    static let toolTurn = ToolTurn(calls: [ToolCallBlock(id: "call_1", name: "fs_read", argumentsJSON: "{\"path\":\"a.md\"}")],
                                   results: [ToolResultBlock(toolUseId: "call_1", text: "文件内容", isError: false)])

    static func all() -> [ProviderOrderingScenario] {
        [
            .init(name: "oai-plain", anthropic: false, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
                  preset: preset(), profile: profile(), history: plainHistory, styleContent: nil,
                  fileLibrary: nil, folderInstructions: nil, volatileNote: nil, tools: nil, toolTurns: []),
            .init(name: "oai-rich", anthropic: false, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
                  preset: preset(preHistoryUser: true) { $0.temperature = 0.9; $0.maxTokens = 2000 }, profile: profile(),
                  history: richHistory, styleContent: "简洁一点", fileLibrary: "[文件库] {{user}} 的文件在这里", folderInstructions: "文件夹：日常",
                  volatileNote: nil, tools: tool, toolTurns: [toolTurn]),
            .init(name: "oai-official", anthropic: false, baseURL: "https://api.openai.com/v1", model: "gpt-4o",
                  preset: preset(preHistoryUser: true), profile: profile(), history: richHistory, styleContent: "简洁一点",
                  fileLibrary: "[文件库] 说明", folderInstructions: nil, volatileNote: nil, tools: nil, toolTurns: []),
            .init(name: "or-claude-cache", anthropic: false, baseURL: "https://openrouter.ai/api/v1", model: "anthropic/claude-sonnet-4.5",
                  preset: preset(cacheFriendly: true), profile: profile(), history: richHistory, styleContent: "简洁一点",
                  fileLibrary: nil, folderInstructions: nil, volatileNote: "今天的日记", tools: nil, toolTurns: []),
            .init(name: "or-deepseek-cache", anthropic: false, baseURL: "https://openrouter.ai/api/v1", model: "deepseek/deepseek-chat",
                  preset: preset(cacheFriendly: true), profile: profile(), history: plainHistory, styleContent: nil,
                  fileLibrary: nil, folderInstructions: nil, volatileNote: "今天的日记", tools: nil, toolTurns: []),
            .init(name: "anthropic-plain", anthropic: true, baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5",
                  preset: preset(preHistoryUser: true), profile: profile(), history: richHistory, styleContent: "简洁一点",
                  fileLibrary: "[文件库] 说明", folderInstructions: "文件夹：日常", volatileNote: nil, tools: nil, toolTurns: []),
            .init(name: "anthropic-cache-tools", anthropic: true, baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5",
                  preset: preset(cacheFriendly: true) { $0.reasoningEffort = "medium"; $0.maxTokens = 8000 }, profile: profile(),
                  history: plainHistory, styleContent: "简洁一点", fileLibrary: nil, folderInstructions: nil,
                  volatileNote: "今天的日记", tools: tool, toolTurns: [toolTurn]),
            .init(name: "anthropic-first-turn", anthropic: true, baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5",
                  preset: preset(), profile: profile(), history: [.init(id: "n1", role: "user", content: "第一句", images: [image("d.jpg", 0x0D)])],
                  styleContent: "简洁一点", fileLibrary: nil, folderInstructions: nil, volatileNote: nil, tools: nil, toolTurns: []),
        ]
    }

    static func canonicalJSON(_ body: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        // Anthropic cacheFriendly 的 metadata.user_id 是每台机器随机生成的 sticky id，夹具里换成占位
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: AnthropicProvider.cacheUserId, with: "{{CACHE_USER_ID}}")
    }
}
// ===== 夹具定义结束 =====
