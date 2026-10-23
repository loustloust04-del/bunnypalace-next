import XCTest
@testable import 记忆花园

/// 选工具评测的请求导出（plan-tool-bloat 第 0 步）：按粟粟 Air 的工具开关走实发路径组一份 body，
/// 写 /tmp/tool-eval-request.json 给 scripts/tool-eval 用。只在 EXPORT_TOOL_EVAL=1 时写，平时只检查组装得出来。
@MainActor
final class ToolEvalExportTests: XCTestCase {

    private var harness: PromptRealPathHarness?
    private var savedSearch: (providers: [WebSearchServiceOptions], selectedId: String)?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        if let s = savedSearch {
            WebSearchSettings.shared.providers = s.providers
            WebSearchSettings.shared.selectedId = s.selectedId
            WebSearchSettings.shared.save()
        }
        savedSearch = nil
    }

    /// Air 10-09 备份里的开关（research-tool-bloat §1）：只覆盖跟下发工具有关的
    private func applyAirToolSettings(_ h: PromptRealPathHarness) {
        let levels: [PermissionDomain: PermissionLevel] = [
            .toolsMaster: .bypass, .fileLibrary: .bypass, .memory: .bypass,
            .webSearch: .bypass, .calendar: .bypass, .notifications: .bypass,
            .reminders: .askOnce, .clipboard: .askOnce, .shell: .askOnce, .twitter: .bypass,
        ]
        for (domain, level) in levels { h.overrideDefault(domain.storageKey, level.rawValue) }
        h.overrideDefault("mem_master", true)
        h.overrideDefault("mem_content_heartvoice", true)
        h.overrideDefault("mem_content_convhistory", true)
        h.overrideDefault(WebSearchSettings.kEnabled, true)

        let ws = WebSearchSettings.shared
        savedSearch = (ws.providers, ws.selectedId)
        let ddg = WebSearchServiceOptions.makeDefault(kind: .duckduckgo, id: "xctest-tool-eval-ddg")
        ws.providers = [ddg]
        ws.selectedId = ddg.id
        ws.save()
    }

    func testExportAirToolEvalRequest() async throws {
        let h = try await PromptRealPathHarness.make(PromptScenario(name: "tool-eval", voiceHint: false))
        harness = h
        applyAirToolSettings(h)
        let body = try await h.regenerateCapturingBody()

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]], "Air 开关下应该有工具")
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains(SelfMemoryTool.rememberName))
        XCTAssertTrue(names.contains(WebSearchToolService.toolName))
        XCTAssertTrue(names.contains("calendar_create"))

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first { $0["role"] as? String == "system" }?["content"] as? String)
        guard ProcessInfo.processInfo.environment["EXPORT_TOOL_EVAL"] == "1" else { return }
        // 收在「更多工具」里的（评测的假执行器按它判 tool_invoke 能不能调，同 app 的门控）
        let tucked = ToolRegistry.tuckedDefinitions(ToolGateContext(family: .openAI, deferMCP: false, profileId: h.profile.id)).map(\.name)
        let payload: [String: Any] = ["system": system, "tools": tools, "toolNames": names, "tucked": tucked]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: "/tmp/tool-eval-request.json"))
    }
}
