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
            orCacheControl: OpenAICompatibleProvider.wantsORCacheControl(baseURL: s.baseURL, model: s.model, samplingParams: s.preset.sampling),
            orProviderOrder: OpenAICompatibleProvider.orPreferredProviderOrder(baseURL: s.baseURL, model: s.model, samplingParams: s.preset.sampling),
            interleavedSystem: OpenAICompatibleProvider.supportsInterleavedSystem(baseURL: s.baseURL, model: s.model))
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

    // MARK: - 主闸：没有非前缀 system 时，请求体与改前逐字节一致

    func testNoInjectionBodiesAreByteIdenticalToPreChangeFixtures() {
        let all = ProviderOrderingScenarios.all()
        XCTAssertEqual(Set(all.map(\.name)), Set(Self.preChangeFixtures.keys), "每个夹具都要比")
        for s in all {
            let json = ProviderOrderingScenarios.canonicalJSON(body(s, ordered(s)))
            XCTAssertEqual(json, Self.preChangeFixtures[s.name], "\(s.name) 请求体与改前不一致")
        }
    }

    func testLegacyShapeMatchesOldAssembleWithoutInjection() {
        for s in ProviderOrderingScenarios.all() {
            let old = PromptAssembler.assemble(
                preset: s.preset, profile: s.profile, memories: [],
                chatHistory: s.history.map { (role: $0.role, content: $0.content) },
                fileLibrary: s.fileLibrary, styleContent: s.styleContent,
                folderInstructions: s.folderInstructions, volatileNote: s.volatileNote)
            let legacy = PromptMessage.legacyShape(ordered(s))
            XCTAssertEqual(legacy.systemPrompt, old.systemPrompt, s.name)
            XCTAssertEqual(legacy.messages.map(\.role), old.messages.map(\.role), s.name)
            XCTAssertEqual(legacy.messages.map(\.content), old.messages.map(\.content), s.name)
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
        XCTAssertTrue(OpenAICompatibleProvider.supportsInterleavedSystem(baseURL: "https://api.openai.com/v1", model: "gpt-4o"))
        XCTAssertTrue(OpenAICompatibleProvider.supportsInterleavedSystem(baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o"))
        for (url, model) in [("https://openrouter.ai/api/v1", "anthropic/claude-sonnet-4.5"),
                             ("https://openrouter.ai/api/v1", "deepseek/deepseek-chat"),
                             ("https://api.deepseek.com/v1", "deepseek-chat"),
                             ("https://api.siliconflow.cn/v1", "Qwen/Qwen3"),
                             ("https://api.moonshot.cn/v1", "kimi-k2"),
                             ("https://generativelanguage.googleapis.com/v1beta/openai", "gemini-2.5-pro"),
                             ("https://relay.example.com/v1", "gpt-4o")] {
            XCTAssertFalse(OpenAICompatibleProvider.supportsInterleavedSystem(baseURL: url, model: model), "\(url) \(model) 未核实，默认降级")
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

    // MARK: - 改码前旧管线落盘的请求体（sortedKeys 序列化；metadata.user_id 换占位）
    // 10-01 输出上限（plan-output-token-cap）：OpenAI 兼容一律显式发 max_tokens；Anthropic thinking 预算加在上限之上（8000 + 中档 4096）。除这两处外逐字节未动
    static let preChangeFixtures: [String: String] = [
        "oai-plain": ##"{"max_tokens":4096,"messages":[{"content":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园","role":"system"},{"content":"你好 小岚","role":"user"},{"content":"在呢，禾禾。","role":"assistant"},{"content":"今天好累","role":"user"}],"model":"deepseek-chat","stream":true,"stream_options":{"include_usage":true},"temperature":0.69999999999999996,"top_p":0.94999999999999996}"##,
        "oai-rich": ##"{"max_tokens":2000,"messages":[{"content":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[文件夹说明]\n文件夹：日常\n\n[当前场景]\n傍晚的花园\n\n[文件库] 禾禾 的文件在这里","role":"system"},{"content":"（禾禾的补充设定）","role":"user"},{"content":[{"text":"看这张图","type":"text"},{"image_url":{"url":"data:image\/jpeg;base64,\/9gKAQI="},"type":"image_url"}],"role":"user"},{"content":"好看！","role":"assistant"},{"content":[{"text":"再看这张和文件\n<style>简洁一点<\/style>","type":"text"},{"image_url":{"url":"data:image\/jpeg;base64,\/9gLAQI="},"type":"image_url"}],"role":"user"},{"content":"","role":"assistant","tool_calls":[{"function":{"arguments":"{\"path\":\"a.md\"}","name":"fs_read"},"id":"call_1","type":"function"}]},{"content":"文件内容","role":"tool","tool_call_id":"call_1"}],"model":"deepseek-chat","stream":true,"stream_options":{"include_usage":true},"temperature":0.90000000000000002,"tools":[{"function":{"description":"读文件","name":"fs_read","parameters":{"properties":{},"type":"object"}},"type":"function"}],"top_p":0.94999999999999996}"##,
        "oai-official": ##"{"max_tokens":4096,"messages":[{"content":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园\n\n[文件库] 说明","role":"system"},{"content":"（禾禾的补充设定）","role":"user"},{"content":[{"text":"看这张图","type":"text"},{"image_url":{"url":"data:image\/jpeg;base64,\/9gKAQI="},"type":"image_url"}],"role":"user"},{"content":"好看！","role":"assistant"},{"content":[{"text":"再看这张和文件\n<style>简洁一点<\/style>","type":"text"},{"image_url":{"url":"data:image\/jpeg;base64,\/9gLAQI="},"type":"image_url"}],"role":"user"}],"model":"gpt-4o","stream":true,"stream_options":{"include_usage":true},"temperature":0.69999999999999996,"top_p":0.94999999999999996}"##,
        "or-claude-cache": ##"{"max_tokens":4096,"messages":[{"content":[{"cache_control":{"ttl":"1h","type":"ephemeral"},"text":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园","type":"text"}],"role":"system"},{"content":[{"text":"看这张图","type":"text"},{"image_url":{"url":"data:image\/jpeg;base64,\/9gKAQI="},"type":"image_url"}],"role":"user"},{"content":[{"cache_control":{"ttl":"1h","type":"ephemeral"},"text":"好看！","type":"text"}],"role":"assistant"},{"content":"[动态上下文｜仅供参考，不要复述]\n今天的日记","role":"user"},{"content":[{"text":"再看这张和文件\n<style>简洁一点<\/style>","type":"text"},{"image_url":{"url":"data:image\/jpeg;base64,\/9gLAQI="},"type":"image_url"}],"role":"user"}],"model":"anthropic\/claude-sonnet-4.5","stream":true,"stream_options":{"include_usage":true},"temperature":0.69999999999999996,"top_p":0.94999999999999996}"##,
        "or-deepseek-cache": ##"{"max_tokens":4096,"messages":[{"content":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园","role":"system"},{"content":"你好 小岚","role":"user"},{"content":"在呢，禾禾。","role":"assistant"},{"content":"[动态上下文｜仅供参考，不要复述]\n今天的日记","role":"user"},{"content":"今天好累","role":"user"}],"model":"deepseek\/deepseek-chat","provider":{"allow_fallbacks":true,"order":["deepseek"]},"stream":true,"stream_options":{"include_usage":true},"temperature":0.69999999999999996,"top_p":0.94999999999999996}"##,
        "anthropic-plain": ##"{"max_tokens":4096,"messages":[{"content":"（禾禾的补充设定）","role":"user"},{"content":[{"text":"看这张图","type":"text"},{"source":{"data":"\/9gKAQI=","media_type":"image\/jpeg","type":"base64"},"type":"image"}],"role":"user"},{"content":"好看！","role":"assistant"},{"content":[{"text":"再看这张和文件\n<style>简洁一点<\/style>","type":"text"},{"source":{"data":"\/9gLAQI=","media_type":"image\/jpeg","type":"base64"},"type":"image"}],"role":"user"}],"model":"claude-sonnet-4-5","stream":true,"system":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[文件夹说明]\n文件夹：日常\n\n[当前场景]\n傍晚的花园\n\n[文件库] 说明","temperature":0.69999999999999996,"top_p":0.94999999999999996}"##,
        "anthropic-cache-tools": ##"{"max_tokens":12096,"messages":[{"content":"你好 小岚","role":"user"},{"content":"在呢，禾禾。","role":"assistant"},{"content":"[动态上下文｜仅供参考，不要复述]\n今天的日记","role":"user"},{"content":"今天好累\n<style>简洁一点<\/style>","role":"user"},{"content":[{"cache_control":{"type":"ephemeral"},"id":"call_1","input":{"path":"a.md"},"name":"fs_read","type":"tool_use"}],"role":"assistant"},{"content":[{"content":"文件内容","tool_use_id":"call_1","type":"tool_result"}],"role":"user"}],"metadata":{"user_id":"{{CACHE_USER_ID}}"},"model":"claude-sonnet-4-5","stream":true,"system":[{"cache_control":{"type":"ephemeral"},"text":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园","type":"text"}],"thinking":{"budget_tokens":4096,"type":"enabled"},"tools":[{"function":{"description":"读文件","name":"fs_read","parameters":{"properties":{},"type":"object"}},"type":"function"}],"top_p":0.94999999999999996}"##,
        "anthropic-first-turn": ##"{"max_tokens":4096,"messages":[{"content":[{"text":"第一句\n<style>简洁一点<\/style>","type":"text"},{"source":{"data":"\/9gNAQI=","media_type":"image\/jpeg","type":"base64"},"type":"image"}],"role":"user"}],"model":"claude-sonnet-4-5","stream":true,"system":"你是小岚，陪禾禾聊天。\n\n[角色设定]\n温柔的角色\n\n\n[当前场景]\n傍晚的花园","temperature":0.69999999999999996,"top_p":0.94999999999999996}"##,
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
