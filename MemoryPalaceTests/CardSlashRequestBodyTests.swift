import XCTest
@testable import 记忆花园

/// 卡库第二批 B5：卡里网页 `/send 那句话 | /trigger` 生成出来的请求体，和你手动发同一句话的请求体逐字节一致
/// （④b 那 8 份夹具里末楼是纯文字用户消息的几份；/send 的文字原样落成用户楼，/trigger 走同一组组装 / provider 函数）
final class CardSlashRequestBodyTests: XCTestCase {

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

    /// 与实发同一组函数：assembleOrdered → provider 请求体
    private func body(_ s: ProviderOrderingScenario, history: [ProviderOrderingScenario.Turn]) -> String {
        let result = PromptAssembler.assembleOrdered(
            preset: s.preset, profile: s.profile, memories: [],
            chatHistory: history.map { (role: $0.role, content: $0.content) },
            historyNodeIds: history.map(\.id),
            fileLibrary: s.fileLibrary, styleContent: s.styleContent,
            folderInstructions: s.folderInstructions, volatileNote: s.volatileNote)
        var byId: [String: [PendingChatAttachment]] = [:]
        for turn in history where !turn.images.isEmpty { byId[turn.id] = turn.images }
        let ordered = PromptMessage.attaching(byId, to: result.messages)
        let raw: [String: Any]
        if s.anthropic {
            raw = AnthropicProvider.buildRequestBody(ordered: ordered, model: s.model, samplingParams: s.preset.sampling,
                                                     tools: s.tools, toolTurns: s.toolTurns, allowCacheControl: true)
        } else {
            raw = OpenAICompatibleProvider.buildRequestBody(
                ordered: ordered, model: s.model, samplingParams: s.preset.sampling, tools: s.tools, toolTurns: s.toolTurns,
                orCacheControl: OpenAICompatibleProvider.wantsORCacheControl(baseURL: s.baseURL, model: s.model, samplingParams: s.preset.sampling),
                orProviderOrder: OpenAICompatibleProvider.orPreferredProviderOrder(baseURL: s.baseURL, model: s.model, samplingParams: s.preset.sampling),
                interleavedSystem: OpenAICompatibleProvider.supportsInterleavedSystem(baseURL: s.baseURL, model: s.model))
        }
        return ProviderOrderingScenarios.canonicalJSON(raw)
    }

    /// 末楼是纯文字用户消息的夹具（/send 只发文字）
    private var scenarios: [ProviderOrderingScenario] {
        ProviderOrderingScenarios.all().filter { $0.history.last.map { $0.role == "user" && $0.images.isEmpty } == true }
    }

    /// 卡里的按钮执行 slash → 宿主的执行步骤 → 落成的历史（/send 文字原样成用户楼；/trigger 不加楼，只生成）
    private func historyAfterSlash(_ commands: [String], base: [ProviderOrderingScenario.Turn], userId: String,
                                   names: (char: String, user: String)) throws -> (history: [ProviderOrderingScenario.Turn], replies: Int, steps: [CardSlashStep]) {
        var history = base
        var replies = 0
        var all: [CardSlashStep] = []
        for command in commands {
            guard case .success(let plan) = CardSlash.plan(command, charName: names.char, userName: names.user) else {
                XCTFail("解析失败：\(command)")
                return (history, replies, all)
            }
            for step in plan.steps {
                all.append(step)
                switch step {
                case .append(let t): history.append(.init(id: userId, role: "user", content: t, images: []))
                case .sendAndReply(let t): history.append(.init(id: userId, role: "user", content: t, images: [])); replies += 1
                case .reply: replies += 1
                case .toast, .fillInput: break
                }
            }
        }
        return (history, replies, all)
    }

    func testSendTriggerBodyIsByteIdenticalToManualSend() throws {
        XCTAssertEqual(scenarios.map(\.name), ["oai-plain", "or-deepseek-cache", "anthropic-cache-tools"])
        for s in scenarios {
            let last = try XCTUnwrap(s.history.last)
            let base = Array(s.history.dropLast())
            let manual = body(s, history: s.history)
            XCTAssertEqual(manual, ProviderOrderingTests.preChangeFixtures[s.name], "\(s.name) 手动发送 = ④b 夹具")
            let names = (s.profile.assistantName, s.profile.userName)

            // 一条管道：/send 那句话 | /trigger → 合成一步（= 手动发送同一个入口）
            let piped = try historyAfterSlash(["/send \(last.content) | /trigger"], base: base, userId: last.id, names: names)
            XCTAssertEqual(piped.steps, [.sendAndReply(last.content)], s.name)
            XCTAssertEqual(piped.replies, 1)
            XCTAssertEqual(body(s, history: piped.history), manual, "\(s.name)：/send|/trigger 的请求体与手动发送逐字节一致")

            // 分两次点：先 /send（只追加），再 /trigger（末尾生成一次）
            let split = try historyAfterSlash(["/send \(last.content)", "/trigger"], base: base, userId: last.id, names: names)
            XCTAssertEqual(split.steps, [.append(last.content), .reply], s.name)
            XCTAssertEqual(body(s, history: split.history), manual, "\(s.name)：先 /send 后 /trigger 也一致")

            // 引号写法（raw=false 去引号）、管道注入写法
            let quoted = try historyAfterSlash(["/send raw=false \"\(last.content)\" | /trigger"], base: base, userId: last.id, names: names)
            XCTAssertEqual(body(s, history: quoted.history), manual, "\(s.name)：带引号写法")
            let injected = try historyAfterSlash(["/setinput \(last.content) | /send | /trigger"], base: base, userId: last.id, names: names)
            XCTAssertEqual(body(s, history: injected.history), manual, "\(s.name)：/send 吃管道")
        }
    }

    /// 宏：卡里写 {{user}}/{{char}}，slash 先按有效名字展开；你手打同一句（带宏）由发送时展开（sendMessage 的
    /// expandUserMacros → MacroExpander.expand，/send 落楼也再过一遍，幂等）——落成的用户楼一样，请求体一样
    func testMacroTextMatchesManualSendOfSameSentence() throws {
        let s = try XCTUnwrap(scenarios.first)
        let base = Array(s.history.dropLast())
        let literal = "{{user}}推开门，看见{{char}}"
        let bake = { (t: String) in MacroExpander.expand(t, userName: s.profile.userName, charName: s.profile.assistantName) }
        let manual = body(s, history: base + [.init(id: "n3", role: "user", content: bake(literal), images: [])])
        let viaCard = try historyAfterSlash(["/send \(literal)|/trigger"], base: base, userId: "n3",
                                            names: (s.profile.assistantName, s.profile.userName))
        XCTAssertEqual(viaCard.steps, [.sendAndReply("禾禾推开门，看见小岚")])
        let baked = viaCard.history.map { ProviderOrderingScenario.Turn(id: $0.id, role: $0.role, content: $0.id == "n3" ? bake($0.content) : $0.content, images: $0.images) }
        XCTAssertEqual(body(s, history: baked), manual)
        XCTAssertTrue(manual.contains("禾禾推开门，看见小岚"))
    }
}
