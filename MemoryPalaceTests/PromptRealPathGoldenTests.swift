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

    private func check(_ scenario: PromptScenario) async throws {
        let h = try await PromptRealPathHarness.make(scenario)
        harness = h
        let body = try await h.regenerateCapturingBody()
        let text = try h.canonical(body, droppingTools: true)
        let url = Self.goldenDir.appendingPathComponent("\(scenario.name).json")
        if ProcessInfo.processInfo.environment["RECORD_PROMPT_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: Self.goldenDir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return
        }
        let golden = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, golden, "\(scenario.name)：实发 body 与金样不一致")
    }

    func testG1OpenAICompatibleFull() async throws {
        try await check(PromptScenario(name: "G1-openai-full"))
    }

    func testG2MemoryOff() async throws {
        try await check(PromptScenario(name: "G2-memory-off", memoryEnabled: false))
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
}
