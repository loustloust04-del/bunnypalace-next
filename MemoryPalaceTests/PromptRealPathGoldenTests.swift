import MemoryCore
import XCTest
@testable import 记忆花园

/// 实发 body 金样（plan-inspector-real-path §5.2/5.3）：重构组装路径前录、重构后不许重录且必须全过 = 实发逐字节不变。
/// 录：`TEST_RUNNER_RECORD_PROMPT_GOLDEN=1 xcodebuild test …`。金样不含 tools（MCP 读本机配置）；tools 由 InspectorRealPathTests 同次运行比。
/// #035 测试宿主隔离后本测试启动时 MCP 列表为空（不读录制人本机配置）：10-10 重录，唯一变化是 system 里「## MCP 外部工具」一段消失（原来是录的人本机启用了 MCP）。
@MainActor
final class PromptRealPathGoldenTests: XCTestCase {

    private var harness: PromptRealPathHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
    }

    private static var goldenDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/prompt-golden")
    }

    @discardableResult
    private func check(_ scenario: PromptScenario, prepare: ((PromptRealPathHarness) async throws -> Void)? = nil) async throws -> String {
        let h = try await PromptRealPathHarness.make(scenario, beforeSecondUserMessage: prepare)
        harness = h
        let body = try await h.regenerateCapturingBody()
        let text = try h.canonical(body, droppingTools: true)
        let url = Self.goldenDir.appendingPathComponent("\(scenario.name).json")
        if ProcessInfo.processInfo.environment["RECORD_PROMPT_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: Self.goldenDir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return text
        }
        let golden = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, golden, "\(scenario.name)：实发 body 与金样不一致")
        return text
    }

    func testG1OpenAICompatibleFull() async throws {
        let text = try await check(PromptScenario(name: "G1-openai-full"))
        let h = try XCTUnwrap(harness)
        XCTAssertNil(h.viewModel.selectedConversation?.memoryWindowChoicesData, "老窗 choices=nil 完整请求与既有基线逐字比较")
        XCTAssertTrue(MemoryOpenWindow.isChecked(.c, profileId: h.profile.id))
        XCTAssertTrue(RecallTuningStore.load(profileId: h.profile.id).archiveTriggerEnabled)
        XCTAssertTrue(text.contains("周末问团子吃不吃"), "基线必须确实包含待续")
    }

    func testG2MemoryOff() async throws {
        try await check(PromptScenario(name: "G2-memory-off", memoryEnabled: false))
    }

    /// P2：关参与窗 = 真的不带记忆。G2 不再与 G1 逐字节相同：Z 段（时间轴 / 待续 / 上下文摘要）
    /// 和五个写工具都不出现，recall 照发。
    func testG2DiffersFromG1() throws {
        let g1 = try String(contentsOf: Self.goldenDir.appendingPathComponent("G1-openai-full.json"), encoding: .utf8)
        let g2 = try String(contentsOf: Self.goldenDir.appendingPathComponent("G2-memory-off.json"), encoding: .utf8)
        XCTAssertNotEqual(g1, g2, "关参与窗不能和开参与窗逐字节相同")
        for header in ["[时间轴]", "[待续]", "[上下文摘要]"] {
            XCTAssertTrue(g1.contains(header), "G1 开参与窗带 \(header)")
            XCTAssertFalse(g2.contains(header), "G2 关参与窗不带 \(header)")
        }
        for tool in ["remember", "edit_memory", "forget_memory", "pending_notes", "suggest_wiki_direction"] {
            XCTAssertTrue(g1.contains("- \(tool) — "), "G1 工具清单有 \(tool)")
            XCTAssertFalse(g2.contains("- \(tool) — "), "G2 工具清单没有 \(tool)")
        }
        XCTAssertTrue(g2.contains("- recall — "), "recall 照发")
    }

    func testG3CacheFriendly() async throws {
        try await check(PromptScenario(name: "G3-cache-friendly", cacheFriendly: true))
    }

    func testG4AnthropicBlacklisted() async throws {
        try await check(PromptScenario(name: "G4-anthropic-blacklisted", providerType: .anthropic,
                                       cacheFriendly: true, anthropicBlacklisted: true))
    }

    func testG5NonStreaming() async throws {
        try await check(PromptScenario(name: "G5-non-streaming", streamingMode: .off))
    }

    func testG6HealthAskOnceAllowed() async throws {
        try await check(PromptScenario(name: "G6-health-askonce-allowed", healthWeightAskOnceAllowed: true))
    }

    /// G9：当前用户句点名命中两页；新话题不借上一条 assistant 身份回看。
    /// wiki / 碎片只进 system，不带 records、未审碎片或未命中页正文；钉住的旧档案照带。
    func testG9WikiInjection() async throws {
        try await check(PromptScenario(name: "G9-wiki", cacheFriendly: true, memoryFixtures: false,
                                       secondUserMessage: "慧慧说审计台又卡住了")) { h in
            let a1 = try XCTUnwrap(h.viewModel.currentPath.first { $0.role == "assistant" })
            a1.content = "回复一：User 提到慧慧说审计台又卡住了"
            func frag(_ text: String, _ second: TimeInterval, kept: Bool = true, page: String? = nil) -> Memory {
                let m = Memory(content: text, category: "fact", profileId: h.profile.id)
                m.createdAt = Date(timeIntervalSince1970: 1_790_000_000 + second)
                m.occurredDay = "2026-10-09"
                m.reviewedAt = kept ? m.createdAt : nil
                m.organizedPage = page
                m.organizedAt = page == nil ? nil : m.createdAt
                return m
            }
            let pinned = Memory(content: "钉住的旧档案", category: "fact", profileId: h.profile.id, isUserExplicit: true)
            pinned.createdAt = Date(timeIntervalSince1970: 1_700_000_200)
            let expired = frag("周三复诊", 3)
            expired.validUntil = FragmentPool.validUntilDate("2026-10-09")
            [pinned, frag("小慧搬进来了", 1, page: "人/小慧"), frag("团子体检正常", 2), expired,
             frag("没看过的碎片（不该出现）", 4, kept: false)].forEach { h.context.insert($0) }
            try h.context.save()
            try await h.seedWiki([
                WikiPage(path: "人/小慧", kind: .person, triggers: ["慧慧"], hook: "她提到小慧、室友的时候", title: "小慧",
                         now: "室友（自 2026-09 起）。约了一起看房（到 2026-10-08）。", records: ["2026-09-01 搬进五楼（记录不该出现）"]),
                WikiPage(path: "工程/记忆宫殿", kind: .project, triggers: ["审计台"], hook: "聊这个 app 的时候", title: "记忆宫殿",
                         now: "在做 C3 整理编目（自 2026-10 起）。"),
                WikiPage(path: "人/User", kind: .person, hook: "名字不触发", title: "User", now: "不该出现（用户名）。"),
                WikiPage(path: "物/团子", kind: .thing, triggers: ["第一条"], hook: "聊到猫的时候", title: "团子",
                         now: "不该出现（不触发的词）。"),
                WikiPage(path: "地点/五楼出租屋", kind: .place, hook: "聊到住处的时候", title: "五楼出租屋", now: "没命中，不该出现。"),
            ], stopWords: ["第一条"])
        }
    }

    /// G10（10-29）：气泡对话 = G1 + 能力提示槽末尾一段 <气泡对话>（贴表情会叫你 / ```react 给她贴表情）；文章对话 G1–G9 逐字节不变
    func testG10BubbleConversation() async throws {
        try await check(PromptScenario(name: "G10-bubble", bubbleMode: true))
    }

    /// thinking 回传（plan-thinking §6）：opus-5-5「默认」档 + 思考过程「原地」→ thinking {adaptive, summarized}、无 output_config、
    /// max_tokens = 可见上限 + medium 余量（测试宿主没有模型目录，可见上限是 16384 兜底 → 20480）、无采样参数
    func testG8OpusDefaultThinking() async throws {
        try await check(PromptScenario(name: "G8-opus-default-thinking", providerType: .anthropic, modelId: "claude-opus-5-5",
                                       thinkingDisplay: .inline))
    }
}
