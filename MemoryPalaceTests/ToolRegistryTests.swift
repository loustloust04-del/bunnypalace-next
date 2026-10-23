import XCTest
@testable import 记忆花园

/// 工具底座特征测试（plan-pi-style-toolbase）：
/// golden fixture 钉死双家 schema 逐字节不变 + 门控行为 + hub 导出 dump。
final class ToolRegistryTests: XCTestCase {

    private var fixtureURL: URL {
        // 走 test bundle 资源（#filePath 直读会被测试进程 TCC 沙箱拒）
        Bundle(for: ToolRegistryTests.self).url(forResource: "tools-schema-golden", withExtension: "json")!
    }

    private func canonical(_ obj: Any) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
    }

    @MainActor
    private func renderAll(_ family: ToolGateContext.Family) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for entry in ToolRegistry.all {
            let d = entry.definition
            #if PERSONAL_APPS
            if d.name == DeathScaleAITool.toolName { continue }   // 私有工具不进共享 fixture，定义由 DeathScaleAIToolTests 覆盖
            #endif
            out[d.name] = family == .anthropic ? ToolSchemaRenderer.anthropic(d) : ToolSchemaRenderer.openAI(d)
        }
        return out
    }

    /// Golden：注册表渲染输出与迁移基线逐字节一致（唯一已审计 diff = inner_voice anthropic 补齐
    /// reason.description，手写双份时代的漂移，fixture 已随之更新——见 review-toolbase-phase0.md）
    @MainActor
    func testSchemaMatchesGoldenFixture() throws {
        // 重生成入口：TEST_RUNNER_REGEN_TOOLS_GOLDEN=1 跑本用例 → 写 /tmp/tools-schema-golden.json，人工拷回 Fixtures/（源码路径受 TCC 沙箱限制写不了）。
        // 只在有意加/改工具时用；每次重生成都是一次显式的形状变更审计（review 记账）。
        if ProcessInfo.processInfo.environment["REGEN_TOOLS_GOLDEN"] == "1" {
            let payload: [String: Any] = [
                "openai": renderAll(.openAI), "anthropic": renderAll(.anthropic),
                "anthropicServer": ["web_search": WebSearchToolService.anthropicServerTool()],
            ]
            let out = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: URL(fileURLWithPath: "/tmp/tools-schema-golden.json"))
            return
        }
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: [String: Any]]
        let goldenOpenAI = fixture["openai"] as! [String: Any]
        let goldenAnthropic = fixture["anthropic"] as! [String: Any]
        let goldenServer = (fixture["anthropicServer"] as! [String: Any])["web_search"]!

        let actualOpenAI = renderAll(.openAI)
        let actualAnthropic = renderAll(.anthropic)

        XCTAssertEqual(Set(actualOpenAI.keys), Set(goldenOpenAI.keys), "openai 工具集合漂移")
        XCTAssertEqual(Set(actualAnthropic.keys), Set(goldenAnthropic.keys), "anthropic 工具集合漂移")

        for (name, schema) in actualOpenAI {
            XCTAssertEqual(try canonical(schema), try canonical(goldenOpenAI[name]!), "openai/\(name) schema 漂移")
        }
        for (name, schema) in actualAnthropic {
            XCTAssertEqual(try canonical(schema), try canonical(goldenAnthropic[name]!), "anthropic/\(name) schema 漂移")
        }
        XCTAssertEqual(try canonical(WebSearchToolService.anthropicServerTool()),
                       try canonical(goldenServer), "anthropic server 搜索工具漂移")
    }

    /// 门控：deferMCP 或有收起来的内建工具才出元工具；anthropic 家族不出 client 搜索/浏览
    @MainActor
    func testContextGates() {
        // #069：没 defer 时，元工具跟着「有没有收起来的内建工具」走
        let noDefer = ToolGateContext(family: .openAI, deferMCP: false)
        let openNoDefer = ToolRegistry.enabledDefinitions(noDefer).map(\.name)
        XCTAssertEqual(openNoDefer.contains(MetaTools.searchName), !ToolRegistry.tuckedDefinitions(noDefer).isEmpty)

        let openDefer = ToolRegistry.enabledDefinitions(.init(family: .openAI, deferMCP: true)).map(\.name)
        XCTAssertTrue(openDefer.contains(MetaTools.searchName))
        XCTAssertTrue(openDefer.contains(MetaTools.inspectName))
        XCTAssertTrue(openDefer.contains(MetaTools.invokeName))

        let anthropic = ToolRegistry.enabledDefinitions(.init(family: .anthropic, deferMCP: false)).map(\.name)
        XCTAssertFalse(anthropic.contains(WebSearchToolService.toolName), "anthropic 不发 client 搜索")
        XCTAssertFalse(anthropic.contains(BrowseURLTool.toolName), "anthropic 不发 browse_url")
    }

    /// 门控：文件库总开关拦 fs_* 9 件（含资料卡搭车）
    @MainActor
    func testFileLibraryGate() {
        let key = "fileLibraryEnabled"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        PermissionCenter.setLevel(.bypass, for: .fileLibrary)
        let on = ToolRegistry.enabledDefinitions(.init(family: .openAI, deferMCP: false)).map(\.name)
        XCTAssertTrue(on.contains("fs_read"))
        XCTAssertTrue(on.contains(ProfileCardTool.toolName))

        PermissionCenter.setLevel(.askOnce, for: .fileLibrary)
        let ask = ToolRegistry.enabledDefinitions(.init(family: .openAI, deferMCP: false)).map(\.name)
        XCTAssertTrue(ask.contains("fs_read"), "askOnce = 下发工具，真调用时问")

        PermissionCenter.setLevel(.notAllowed, for: .fileLibrary)
        let off = ToolRegistry.enabledDefinitions(.init(family: .openAI, deferMCP: false)).map(\.name)
        XCTAssertFalse(off.contains(where: { $0.hasPrefix("fs_") }))
        XCTAssertFalse(off.contains(ProfileCardTool.toolName))
        UserDefaults.standard.removeObject(forKey: PermissionDomain.fileLibrary.storageKey)
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// #069 执行前复查：开关关着的内建工具 = 不可用；MCP（不在注册表）= nil
    @MainActor
    func testAvailabilityRecheck() {
        let ctx = ToolGateContext(family: .openAI, deferMCP: false)
        let d = UserDefaults.standard
        let keys = ["mem_master", "mem_content_convhistory", PermissionDomain.toolsMaster.storageKey, PermissionDomain.toolsMaster.legacy.key]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }

        PermissionCenter.setLevel(.bypass, for: .toolsMaster)
        d.set(true, forKey: "mem_master")
        d.set(true, forKey: "mem_content_convhistory")
        XCTAssertEqual(ToolRegistry.availability(of: SelfMemoryTool.rememberName, ctx), true)
        XCTAssertEqual(ToolRegistry.availability(of: RecallTool.toolName, ctx), true)

        d.set(false, forKey: "mem_master")
        d.set(false, forKey: "mem_content_convhistory")
        XCTAssertEqual(ToolRegistry.availability(of: SelfMemoryTool.rememberName, ctx), false, "记忆关着直接叫 remember 要拒")
        XCTAssertEqual(ToolRegistry.availability(of: RecallTool.toolName, ctx), false)

        XCTAssertNil(ToolRegistry.availability(of: "some_mcp_tool", ctx), "MCP 工具不归注册表管")
        XCTAssertEqual(ToolRegistry.availability(of: MetaTools.searchName, ctx), !ToolRegistry.tuckedDefinitions(ctx).isEmpty,
                       "没 defer 时元工具跟着收起来的内建工具走")
        XCTAssertEqual(ToolRegistry.availability(of: MetaTools.searchName, .init(family: .openAI, deferMCP: true)), true)

        PermissionCenter.setLevel(.notAllowed, for: .toolsMaster)
        XCTAssertEqual(ToolRegistry.availability(of: AskUserTool.toolName, ctx), false, "工具总开关关了全拒")
    }

    /// hub 导出 dump（scripts/export-tool-schemas.sh 消费）：中性格式 {name,description,parameters}
    @MainActor
    func testExportNeutralSchemaJSON() throws {
        var entries = ToolRegistry.all
        #if PERSONAL_APPS
        entries.removeAll { $0.definition.name == DeathScaleAITool.toolName }   // 私有工具不导进 cc-bridge
        #endif
        let tools: [[String: Any]] = entries.map { entry in
            let d = entry.definition
            return ["name": d.name, "description": d.description,
                    "parameters": ["type": "object", "properties": d.properties, "required": d.required] as [String: Any]]
        }.sorted { ($0["name"] as! String) < ($1["name"] as! String) }
        let payload: [String: Any] = ["version": 1, "tools": tools]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/tmp/tools-schema.json"))
        #if PERSONAL_APPS
        XCTAssertEqual(ToolRegistry.all.count, 40)   // + remember / edit_memory / forget_memory（记忆修复第二刀）；+ card_guide（卡片写法按需查）；+ death_scale（死亡天平，按楼层门控）；19 内建（含 roll_dice 掷骰）；18 内建（含 local_twitter，page2 推特） + 11 设备工具（plan-设备工具 P1）+ run_command（plan-离线沙箱-phase1，macOS）+ code_* 4 件（W-N N5，macOS）
        #else
        XCTAssertEqual(ToolRegistry.all.count, 39)   // + remember / edit_memory / forget_memory（记忆修复第二刀）；+ card_guide（卡片写法按需查）；19 内建（含 roll_dice 掷骰）；18 内建（含 local_twitter，page2 推特） + 11 设备工具（plan-设备工具 P1）+ run_command（plan-离线沙箱-phase1，macOS）+ code_* 4 件（W-N N5，macOS）
        #endif
        XCTAssertEqual(tools.count, 39)   // 导出不含私有工具
    }
}
