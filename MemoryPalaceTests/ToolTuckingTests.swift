import XCTest
@testable import 记忆花园

/// #069 第 2 步：平时用不到的内建工具收进「更多工具」——分组、元工具门控、tool_invoke 拆包 / 重新包回、目录
@MainActor
final class ToolTuckingTests: XCTestCase {

    private let ctx = ToolGateContext(family: .openAI, deferMCP: false)
    /// setLevel 同时写新键和旧键，两个都要还原（原来没有就删掉）
    private let toolsMasterKeys = [PermissionDomain.toolsMaster.storageKey, PermissionDomain.toolsMaster.legacy.key]
    private var savedToolsMaster: [Any?] = []

    override func setUp() async throws {
        savedToolsMaster = toolsMasterKeys.map { UserDefaults.standard.object(forKey: $0) }
    }

    override func tearDown() async throws {
        for (k, v) in zip(toolsMasterKeys, savedToolsMaster) {
            if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    func testInlineAndTuckedPartitionTheEnabledSet() {
        let all = Set(ToolRegistry.enabledDefinitions(ctx).map(\.name))
        let inline = Set(ToolRegistry.inlineDefinitions(ctx).map(\.name))
        let tucked = Set(ToolRegistry.tuckedDefinitions(ctx).map(\.name))
        XCTAssertTrue(inline.isDisjoint(with: tucked))
        XCTAssertEqual(inline.union(tucked), all)
        XCTAssertTrue(tucked.isSubset(of: ToolRegistry.defaultTuckedNames))
        XCTAssertFalse(inline.contains(where: ToolRegistry.defaultTuckedNames.contains))
        // 常用的不收
        for name in [SelfMemoryTool.rememberName, AskUserTool.toolName, CardGuideTool.toolName] {
            XCTAssertFalse(ToolRegistry.defaultTuckedNames.contains(name), name)
        }
    }

    func testMetaToolsShowUpWhenSomethingIsTucked() {
        // open_url / device_info 只跟工具总开关走，总开关开着就一定有收起来的
        PermissionCenter.setDefaultLevel(.bypass, for: .toolsMaster)
        XCTAssertFalse(ToolRegistry.tuckedDefinitions(ctx).isEmpty)
        let inline = ToolRegistry.inlineDefinitions(ctx).map(\.name)
        XCTAssertTrue(MetaTools.names.isSubset(of: Set(inline)), "有收起来的工具就发元工具")
    }

    func testEveryTuckedToolHasABlurb() {
        for name in ToolRegistry.defaultTuckedNames {
            XCTAssertFalse((ToolRegistry.tuckedBlurbs[name] ?? "").isEmpty, name)
        }
        // #093：抽屉里任何内建工具都可能被收起，每个都要有一句话（没手写的取描述第一句）
        for entry in ToolRegistry.all {
            XCTAssertFalse(ToolRegistry.blurb(for: entry.definition).isEmpty, entry.definition.name)
        }
        #if os(iOS)
        XCTAssertTrue(ToolRegistry.defaultTuckedNames.contains(RunCommandTool.toolName))
        #else
        XCTAssertFalse(ToolRegistry.defaultTuckedNames.contains(RunCommandTool.toolName), "mac 上 run_command 照常直接给")
        XCTAssertTrue(CodingTools.names.isSubset(of: ToolRegistry.defaultTuckedNames))
        #endif
    }

    // MARK: tool_invoke 拆包

    /// 默认抽屉下这一轮收起的（静态测例用）
    private let tucked = ToolRegistry.defaultTuckedNames

    private func invoke(_ args: String, truncated: Bool = false) -> ToolCallBlock {
        ToolCallBlock(id: "call-1", name: MetaTools.invokeName, argumentsJSON: args, truncated: truncated)
    }

    func testUnwrapTuckedBuiltin() throws {
        guard case .unwrapped(let inner) = ConversationViewModel.unwrapTuckedInvoke(
            invoke(#"{"name":"ocr_image","arguments":{"path":"a.png"}}"#, truncated: true), tucked: tucked) else { return XCTFail("应拆包") }
        XCTAssertEqual(inner.id, "call-1", "同一个调用 id，结果才配得上")
        XCTAssertEqual(inner.name, OCRImageTool.toolName)
        XCTAssertTrue(inner.truncated, "截断标记带着走")
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(inner.argumentsJSON.utf8)) as? [String: Any])
        XCTAssertEqual(args["path"] as? String, "a.png")
    }

    func testUnwrapRequiresArguments() {
        guard case .invalid = ConversationViewModel.unwrapTuckedInvoke(invoke(#"{"name":"device_info"}"#), tucked: tucked) else {
            return XCTFail("缺 arguments 要拒（schema 里是必填）")
        }
        guard case .unwrapped(let inner) = ConversationViewModel.unwrapTuckedInvoke(invoke(#"{"name":"device_info","arguments":{}}"#), tucked: tucked) else {
            return XCTFail("显式 {} 照常拆")
        }
        XCTAssertEqual(inner.argumentsJSON, "{}")
    }

    func testUnwrapRejectsNonObjectArguments() {
        guard case .invalid(let msg) = ConversationViewModel.unwrapTuckedInvoke(
            invoke(#"{"name":"device_info","arguments":"kind=battery"}"#), tucked: tucked) else { return XCTFail("应拒") }
        XCTAssertTrue(msg.contains("对象"))
    }

    func testUnwrapLeavesOthersToMetaHandler() {
        let cases = [
            #"{"name":"fs_read","arguments":{"path":"a"}}"#,      // 常用工具不许包着调
            #"{"name":"current_time","arguments":{}}"#,           // MCP
            #"{"name":"OCR_IMAGE","arguments":{}}"#,              // 名字要一字不差
            #"{"name":"tool_invoke","arguments":{}}"#,            // 元工具不能包元工具
            "not json",
        ]
        for c in cases {
            guard case .notWrapped = ConversationViewModel.unwrapTuckedInvoke(invoke(c), tucked: tucked) else { return XCTFail(c) }
        }
        let notInvoke = ToolCallBlock(id: "x", name: OCRImageTool.toolName, argumentsJSON: "{}")
        guard case .notWrapped = ConversationViewModel.unwrapTuckedInvoke(notInvoke, tucked: tucked) else { return XCTFail("直接叫名字不拆") }
    }

    /// #093：拆不拆按这一轮的收起集合（工具抽屉）——用户收起的 roll_dice（默认直接给）能拆；抽屉里关掉的 ocr_image 不拆，交给元工具处理回「这一轮没开」
    func testUnwrapFollowsThisTurnsTuckedSet() {
        var drawer = ToolDrawerState.defaults
        drawer.set(.tucked, for: DiceTool.toolName, profileId: nil)
        drawer.set(.off, for: OCRImageTool.toolName, profileId: nil)
        let now = Set(ToolRegistry.tuckedDefinitions(ToolGateContext(family: .openAI, deferMCP: false, drawer: drawer)).map(\.name))
        guard case .unwrapped(let inner) = ConversationViewModel.unwrapTuckedInvoke(
            invoke(#"{"name":"roll_dice","arguments":{}}"#), tucked: now) else {
            return XCTFail("用户收起的工具要拆")
        }
        XCTAssertEqual(inner.name, DiceTool.toolName)
        guard case .notWrapped = ConversationViewModel.unwrapTuckedInvoke(
            invoke(#"{"name":"roll_dice","arguments":{}}"#), tucked: tucked) else { return XCTFail("默认抽屉下 roll_dice 直接给，不拆") }
        XCTAssertFalse(now.contains(OCRImageTool.toolName))
        guard case .notWrapped = ConversationViewModel.unwrapTuckedInvoke(
            invoke(#"{"name":"ocr_image","arguments":{"path":"a.png"}}"#), tucked: now) else { return XCTFail("关掉的不拆") }
    }

    /// #093 astra #3：循环里能拆包的 = 这一轮发出去的清单里没有的内建工具（按发出去的清单，不按现读的抽屉）
    func testInvokableBuiltinsFollowSentToolList() {
        let sent: [[String: Any]] = [["type": "function", "function": ["name": FileLibraryTools.Name.read.rawValue]],
                                     ["type": "function", "function": ["name": MetaTools.invokeName]]]
        let set = ConversationViewModel.invokableBuiltins(sentTools: sent)
        XCTAssertTrue(set.contains(FileLibraryTools.Name.delete.rawValue))
        XCTAssertTrue(set.contains(DiceTool.toolName), "清单里没有的都能拆（关着的拆了会被执行前复查拒）")
        XCTAssertFalse(set.contains(FileLibraryTools.Name.read.rawValue), "清单里有的不许包着调")
        XCTAssertTrue(set.isDisjoint(with: MetaTools.names), "元工具不能包元工具")
    }

    func testRewrapAfterApprovalCardEdit() throws {
        // iOS 上授权卡改的是 run_command 的命令；这里用两端都收起来的 ocr_image 验形状
        let wrapped = ConversationViewModel.rewrapInvoke(name: OCRImageTool.toolName, argumentsJSON: #"{"path":"改过.png"}"#)
        let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(wrapped.utf8)) as? [String: Any])
        XCTAssertEqual(outer["name"] as? String, OCRImageTool.toolName)
        XCTAssertEqual((outer["arguments"] as? [String: Any])?["path"] as? String, "改过.png")
        // 拆回来是同一个调用
        guard case .unwrapped(let inner) = ConversationViewModel.unwrapTuckedInvoke(
            ToolCallBlock(id: "c", name: MetaTools.invokeName, argumentsJSON: wrapped), tucked: tucked) else { return XCTFail() }
        XCTAssertTrue(inner.argumentsJSON.contains("改过.png"))
    }

    // MARK: 目录

    func testSearchListsBuiltinsFirstAndHidesSameNamedMCP() {
        let builtins = [OCRImageTool.definition, DeviceInfoTool.definition]
        let mcp = [
            MCPResolvedTool(serverId: "s", serverName: "测试", tool: MCPToolConfig(enabled: true, name: "ocr_image", description: "MCP 版识字", params: [], schema: [:])),
            MCPResolvedTool(serverId: "s", serverName: "测试", tool: MCPToolConfig(enabled: true, name: "current_time", description: "现在几点", params: [], schema: [:])),
        ]
        let all = MetaTools.search(query: "", catalog: mcp, builtins: builtins)
        XCTAssertTrue(all.hasPrefix("· "))
        XCTAssertTrue(all.contains("ocr_image — ") && all.contains("(来源 内建)"))
        XCTAssertFalse(all.contains("MCP 版识字"), "同名 MCP 不列，裸名按内建执行")
        XCTAssertTrue(all.contains("current_time"))
        XCTAssertTrue(MetaTools.search(query: "电量", catalog: mcp, builtins: builtins).contains("device_info"))
        XCTAssertTrue(MetaTools.search(query: "没有这种", catalog: [], builtins: builtins).contains("内建(2)"))
    }

    /// MCP 跟任何内建同名（包括常用的、这一轮关着的）都不列、不给看——执行端裸名一律按内建走
    func testReservedBuiltinNamesHideSameNamedMCP() {
        let mcp = [MCPResolvedTool(serverId: "s", serverName: "测试", tool: MCPToolConfig(enabled: true, name: "recall", description: "MCP 版回忆", params: [], schema: [:]))]
        let reserved = Set(ToolRegistry.all.map(\.definition.name))
        XCTAssertFalse(MetaTools.search(query: "", catalog: mcp, builtins: [], reserved: reserved).contains("MCP 版回忆"))
        XCTAssertTrue(MetaTools.inspect(names: ["recall"], catalog: mcp, builtins: [], reserved: reserved).contains("不在「更多工具」里"))
    }

    func testInspectBuiltinShowsSchema() {
        let text = MetaTools.inspect(names: [OCRImageTool.toolName], catalog: [], builtins: [OCRImageTool.definition])
        XCTAssertTrue(text.contains("[内建]"))
        XCTAssertTrue(text.contains("\"path\""))
        XCTAssertTrue(text.contains("\"required\""))
    }
}
