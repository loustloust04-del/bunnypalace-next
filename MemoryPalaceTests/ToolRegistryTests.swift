import MemoryCore
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

    /// 双家工具契约金样；有意变更通过下方录制入口更新，review记录变更原因。
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
            let goldenSchema = try XCTUnwrap(goldenOpenAI[name], "openai/\(name) 缺少 golden schema")
            XCTAssertEqual(try canonical(schema), try canonical(goldenSchema), "openai/\(name) schema 漂移")
        }
        for (name, schema) in actualAnthropic {
            let goldenSchema = try XCTUnwrap(goldenAnthropic[name], "anthropic/\(name) 缺少 golden schema")
            XCTAssertEqual(try canonical(schema), try canonical(goldenSchema), "anthropic/\(name) schema 漂移")
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

    /// 关参与窗（`memoryWriteTools = false`）不下发五个写工具；recall 照发。默认 true 时全在
    @MainActor
    func testMemoryWriteToolsGate() {
        let d = UserDefaults.standard
        let keys = ["mem_master", "mem_write_b4", "mem_content_timeline", "mem_write_c3", "mem_content_convhistory"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        for k in keys { d.set(true, forKey: k) }

        let writeTools = [SelfMemoryTool.rememberName, SelfMemoryTool.editName, SelfMemoryTool.forgetName,
                          PendingNotesTool.toolName, WikiSuggestTool.toolName]
        let on = ToolRegistry.enabledDefinitions(.init(family: .openAI, deferMCP: false)).map(\.name)
        for name in writeTools { XCTAssertTrue(on.contains(name), "默认全开：\(name)") }

        let off = ToolRegistry.enabledDefinitions(.init(family: .openAI, deferMCP: false, memoryWriteTools: false)).map(\.name)
        XCTAssertTrue(off.contains(RecallTool.toolName), "recall 照发")
        for name in writeTools { XCTAssertFalse(off.contains(name), "关参与窗不下发 \(name)") }
    }

    /// 建议 1：关参与窗里五个写工具被拒，文案要说清是本窗关了参与（不是抽屉里关着）；别的工具照旧
    func testMemoryWriteRejectionMessageNamesParticipation() {
        for name in ToolRegistry.memoryWriteNames {
            let msg = ConversationViewModel.toolUnavailableMessage(name: name, memoryParticipationOff: true)
            XCTAssertTrue(msg.hasPrefix("\(name)："), "名字按实际被拒的那个写：\(msg)")
            XCTAssertTrue(msg.contains("关了记忆参与"), msg)
        }
        XCTAssertFalse(ConversationViewModel.toolUnavailableMessage(name: "fs_read", memoryParticipationOff: true).contains("关了记忆参与"),
                       "非写工具不套记忆参与文案")
        XCTAssertFalse(ConversationViewModel.toolUnavailableMessage(name: SelfMemoryTool.rememberName).contains("关了记忆参与"),
                       "参与开着照旧通用文案")
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

        PermissionCenter.setDefaultLevel(.bypass, for: .fileLibrary)
        let on = ToolRegistry.enabledDefinitions(.init(family: .openAI, deferMCP: false)).map(\.name)
        XCTAssertTrue(on.contains("fs_read"))
        XCTAssertTrue(on.contains(ProfileCardTool.toolName))

        PermissionCenter.setDefaultLevel(.askOnce, for: .fileLibrary)
        let ask = ToolRegistry.enabledDefinitions(.init(family: .openAI, deferMCP: false)).map(\.name)
        XCTAssertTrue(ask.contains("fs_read"), "askOnce = 下发工具，真调用时问")

        PermissionCenter.setDefaultLevel(.notAllowed, for: .fileLibrary)
        let off = ToolRegistry.enabledDefinitions(.init(family: .openAI, deferMCP: false)).map(\.name)
        XCTAssertFalse(off.contains(where: { $0.hasPrefix("fs_") }))
        XCTAssertFalse(off.contains(ProfileCardTool.toolName))
        UserDefaults.standard.removeObject(forKey: PermissionDomain.fileLibrary.storageKey)
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// atrium P3⑤0：文件库按 ctx.profileId 那一层——默认允许、A 层不允许、B 层跟默认；没层（nil）= 默认
    @MainActor
    func testFileLibraryGateFollowsFloor() {
        let sandbox = PermissionSandbox()
        defer { sandbox.leave() }
        PermissionCenter.setDefaultLevel(.bypass, for: .fileLibrary)
        PermissionCenter.setFloorLevel(.notAllowed, for: .fileLibrary, profileId: "xctest-a")
        func names(_ pid: String?) -> [String] {
            ToolRegistry.enabledDefinitions(.init(family: .openAI, deferMCP: false, profileId: pid)).map(\.name)
        }
        XCTAssertFalse(names("xctest-a").contains { $0.hasPrefix("fs_") })
        XCTAssertFalse(names("xctest-a").contains(ProfileCardTool.toolName))
        XCTAssertTrue(names("xctest-b").contains("fs_read"))
        XCTAssertTrue(names(nil).contains("fs_read"))
        XCTAssertEqual(ToolRegistry.availability(of: "fs_read", .init(family: .openAI, deferMCP: false, profileId: "xctest-a")), false)
        XCTAssertEqual(ToolRegistry.availability(of: "fs_read", .init(family: .openAI, deferMCP: false, profileId: "xctest-b")), true)
        // 工具总开关只全局：层上有值也不看
        sandbox.defaults.set(PermissionFloors(floors: ["xctest-b": ["toolsMaster": PermissionLevel.notAllowed.rawValue]]).encoded(),
                             forKey: PermissionCenter.floorsKey)
        XCTAssertEqual(ToolRegistry.availability(of: "fs_read", .init(family: .openAI, deferMCP: false, profileId: "xctest-b")), true)
    }

    /// atrium P3⑥a：A 层卸了文件库 App → 档位允许也不下发 fs_* / 资料卡；推特同理；B 跟默认都有
    @MainActor
    func testUninstalledAppDropsToolsPerFloor() {
        let perm = PermissionSandbox()
        let apps = Page2AppsSandbox()
        defer { apps.leave(); perm.leave() }
        PermissionCenter.setDefaultLevel(.bypass, for: .fileLibrary)
        PermissionCenter.setDefaultLevel(.bypass, for: .twitter)
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: "xctest-a")
        Page2Apps.setFloor(false, for: "twitter", profileId: "xctest-a")
        func ctx(_ pid: String) -> ToolGateContext { .init(family: .openAI, deferMCP: false, profileId: pid) }
        let inlineA = ToolRegistry.inlineDefinitions(ctx("xctest-a")).map(\.name)
        let inlineB = ToolRegistry.inlineDefinitions(ctx("xctest-b")).map(\.name)
        XCTAssertFalse(inlineA.contains { $0.hasPrefix("fs_") })
        XCTAssertTrue(inlineB.contains("fs_read"))
        let allA = ToolRegistry.enabledDefinitions(ctx("xctest-a")).map(\.name)
        let allB = ToolRegistry.enabledDefinitions(ctx("xctest-b")).map(\.name)
        XCTAssertFalse(allA.contains(ProfileCardTool.toolName))
        XCTAssertFalse(allA.contains(TwitterAITool.toolName), "推特（收在更多工具里）也不给")
        XCTAssertTrue(allB.contains(TwitterAITool.toolName))
        XCTAssertEqual(ToolRegistry.availability(of: "fs_read", ctx("xctest-a")), false)
        XCTAssertEqual(ToolRegistry.availability(of: "fs_read", ctx("xctest-b")), true)
    }

    /// #069 执行前复查：开关关着的内建工具 = 不可用；MCP（不在注册表）= nil
    @MainActor
    func testAvailabilityRecheck() {
        let ctx = ToolGateContext(family: .openAI, deferMCP: false)
        let d = UserDefaults.standard
        let keys = ["mem_master", "mem_content_convhistory", PermissionDomain.toolsMaster.storageKey, PermissionDomain.toolsMaster.legacy.key]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }

        PermissionCenter.setDefaultLevel(.bypass, for: .toolsMaster)
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

        // #093 工具抽屉：关了 → 拒；收起 → 照样能用
        var drawer = ToolDrawerState.defaults
        drawer.set(.off, for: AskUserTool.toolName, profileId: nil)
        drawer.set(.tucked, for: DiceTool.toolName, profileId: nil)
        let drawerCtx = ToolGateContext(family: .openAI, deferMCP: false, drawer: drawer)
        XCTAssertEqual(ToolRegistry.availability(of: AskUserTool.toolName, drawerCtx), false, "抽屉里关了直接叫也要拒")
        XCTAssertEqual(ToolRegistry.availability(of: DiceTool.toolName, drawerCtx), true)

        PermissionCenter.setDefaultLevel(.notAllowed, for: .toolsMaster)
        XCTAssertEqual(ToolRegistry.availability(of: AskUserTool.toolName, ctx), false, "工具总开关关了全拒")
    }

    /// hub 导出 dump（scripts/export-tool-schemas.sh 消费）：中性格式 {name,description,parameters}
    @MainActor
    func testExportNeutralSchemaJSON() throws {
        var entries = ToolRegistry.all
        entries.removeAll { $0.definition.name == TurnStatusTool.toolName }
        entries.removeAll { ChromeBridgeTools.names.contains($0.definition.name) }   // 本身就是请 hub 跑 opencli，导回 hub 是绕圈（plan-opencli-in-app）
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
        XCTAssertEqual(ToolRegistry.all.count, 45)   // + chrome_read / site_query（plan-opencli-in-app，不导出）；+ set_turn_status（气泡状态行，本轮内存，不导出）；+ suggest_wiki_direction（C2/C3 v2 第 4 段）；+ pending_notes（记忆 v5 待续）；+ remember / edit_memory / forget_memory（记忆修复第二刀）；+ card_guide（卡片写法按需查）；+ death_scale（死亡天平，按楼层门控）；19 内建（含 roll_dice 掷骰）；18 内建（含 local_twitter，page2 推特） + 11 设备工具（plan-设备工具 P1）+ run_command（plan-离线沙箱-phase1，macOS）+ code_* 4 件（W-N N5，macOS）
        #else
        XCTAssertEqual(ToolRegistry.all.count, 44)   // + chrome_read / site_query（plan-opencli-in-app，不导出）；+ set_turn_status（气泡状态行，本轮内存，不导出）；+ suggest_wiki_direction（C2/C3 v2 第 4 段）；+ pending_notes（记忆 v5 待续）；+ remember / edit_memory / forget_memory（记忆修复第二刀）；+ card_guide（卡片写法按需查）；19 内建（含 roll_dice 掷骰）；18 内建（含 local_twitter，page2 推特） + 11 设备工具（plan-设备工具 P1）+ run_command（plan-离线沙箱-phase1，macOS）+ code_* 4 件（W-N N5，macOS）
        #endif
        XCTAssertEqual(tools.count, 41)   // 导出不含私有工具
        XCTAssertFalse(tools.contains { $0["name"] as? String == TurnStatusTool.toolName }, "本轮内存工具不能暴露给CC")
    }
}
