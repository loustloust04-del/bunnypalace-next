import Foundation

/// 内建工具注册表（plan-pi-style-toolbase P0.2）：
/// 注入侧单一入口——16 个内建工具的定义 + 可用性门控（Hermes check_fn 模式）。
/// 不含：MCP 动态工具（MCPProvider 自渲染）/ Anthropic server 搜索工具（形状特殊，toolInjection 特例）。
/// 新 reflection 风行为走 inner_voice 的 mode 复用，不加新 tool（B-D4）。
enum ToolRegistry {

    struct Entry {
        let definition: ToolDefinition
        let enabledIf: (ToolGateContext) -> Bool
    }

    /// 全部内建工具。顺序无所谓——toolInjection 末端按 name 字典序统一排序（prompt cache 前缀稳定）。
    @MainActor
    static var all: [Entry] {
        var entries: [Entry] = []

        // 文件库 9 件（fs_* 8 + 资料卡搭车），总开关 fileLibraryEnabled
        let fileLibraryOn: (ToolGateContext) -> Bool = { _ in
            PermissionCenter.capabilityEnabled(.fileLibrary)   // askOnce = 下发工具，真调用时问（tool loop 闸）
        }
        entries += FileLibraryTools.definitions.map { Entry(definition: $0, enabledIf: fileLibraryOn) }
        entries.append(Entry(definition: ProfileCardTool.definition, enabledIf: fileLibraryOn))

        // 本地推特（page2 推特子应用）：一个工具 + action，AI 在本楼层推特上发推/刷推；纯本地，默认允许
        entries.append(Entry(definition: TwitterAITool.definition, enabledIf: { _ in
            PermissionCenter.capabilityEnabled(.twitter)
        }))


        // 心声（reflection mode 入口）
        entries.append(Entry(definition: InnerVoice.definition, enabledIf: { _ in InnerVoice.enabled }))

        // recall（SC-B1）
        entries.append(Entry(definition: RecallTool.definition, enabledIf: { _ in RecallTool.enabled }))

        // 自己的记忆（记忆修复第二刀 B2）：remember / edit_memory / forget_memory，受记忆总开关管
        entries += SelfMemoryTool.definitions.map { d in Entry(definition: d, enabledIf: { _ in SelfMemoryTool.enabled }) }

        // 问问题（官端 AskUserQuestion 同款）：常开，受 sendToolsEnabled 总开关连坐
        entries.append(Entry(definition: AskUserTool.definition, enabledIf: { _ in true }))

        // 掷骰子（聊天卡片，粟粟 09-26）：真随机；常开，受 sendToolsEnabled 总开关连坐
        entries.append(Entry(definition: DiceTool.definition, enabledIf: { _ in true }))

        // 卡片写法按需查（粟粟 10-03）：发了它系统提示里只放目录；同受 sendToolsEnabled 连坐，关了就回到全文
        entries.append(Entry(definition: CardGuideTool.definition, enabledIf: { _ in true }))

        // 联网搜索 client function：openAI 系 + 配了 backend 才发（anthropic 走 server tool，注入处特例）
        entries.append(Entry(definition: WebSearchToolService.clientDefinition, enabledIf: { ctx in
            ctx.family == .openAI
                && PermissionCenter.capabilityEnabled(.webSearch)
                && WebSearchSettings.shared.selected != nil
        }))

        // browse_url：开关开就发，不依赖 backend；anthropic 不发（server tool 一站式）
        entries.append(Entry(definition: BrowseURLTool.definition, enabledIf: { ctx in
            ctx.family == .openAI && PermissionCenter.capabilityEnabled(.webSearch)
        }))

        // 设备工具 11 件（plan-设备工具 P1）+ macOS run_command（plan-离线沙箱-phase1）：按域档位下发（askOnce 也下发，真调用时 tool loop 弹卡）
        entries += DeviceToolDispatcher.definitions.map { d in
            Entry(definition: d, enabledIf: { _ in PermissionCenter.capabilityEnabled(PermissionDomain.forTool(named: d.name)) })
        }

        #if os(macOS)
        // 编程会话 4 件（W-N N5）：只读；默认不允许 = 不下发，askOnce 也下发、真调用时问
        entries += CodingTools.definitions.map { d in
            Entry(definition: d, enabledIf: { _ in PermissionCenter.capabilityEnabled(.codingSessions) })
        }
        #endif

        // 元工具 3 件（放最后：门控要看前面收起来的那些）：MCP 工具海 defer，或有内建工具收在「更多工具」里时上
        let tucked = entries.filter { tuckedNames.contains($0.definition.name) }
        entries += MetaTools.definitions.map { d in
            Entry(definition: d, enabledIf: { ctx in ctx.deferMCP || tucked.contains { $0.enabledIf(ctx) } })
        }

        return entries
    }

    /// 收进「更多工具」的内建工具（#069 第 2 步）：平时聊天用不到，不放进工具清单（省 schema、少干扰选择），
    /// 系统提示〔更多工具〕列名字 + 一句话，经 tool_invoke 调（直接叫名字也照常执行）。只随平台变
    static let tuckedNames: Set<String> = {
        var names: Set<String> = [
            FileLibraryTools.Name.rename.rawValue, FileLibraryTools.Name.delete.rawValue,
            ProfileCardTool.toolName, TwitterAITool.toolName,
            CalendarTools.deleteName, RemindersTools.completeName,
            ClipboardTool.toolName, OCRImageTool.toolName, OpenURLTool.toolName, DeviceInfoTool.toolName,
        ]
        #if os(iOS)
        names.insert(RunCommandTool.toolName)   // iOS 是 app 内沙箱，看不到对方的任何文件，平时用不到；mac 上照常直接给
        #endif
        #if os(macOS)
        names.formUnion(CodingTools.names)
        #endif
        return names
    }()

    /// 〔更多工具〕里每个工具的一句话（固定文本，前缀稳定）
    static let tuckedBlurbs: [String: String] = {
        var b: [String: String] = [
            FileLibraryTools.Name.rename.rawValue: "文件库里改文件名、挪位置",
            FileLibraryTools.Name.delete.rawValue: "删文件库里的文件",
            ProfileCardTool.toolName: "改你自己资料卡上的状态、自我介绍",
            TwitterAITool.toolName: "本楼层的推特：发推、刷推、回复、点赞",
            CalendarTools.deleteName: "删一个日历日程（id 先用 calendar_query 查）",
            RemindersTools.completeName: "把一条提醒标成完成（id 先用 reminders_query 查）",
            ClipboardTool.toolName: "读对方设备的剪贴板",
            OCRImageTool.toolName: "识别图片里的文字",
            OpenURLTool.toolName: "在对方设备上打开一个链接（你看不到内容）",
            DeviceInfoTool.toolName: "看设备型号、电量、存储空间",
            RunCommandTool.toolName: "在 app 内置的 Linux 沙箱里跑命令",
        ]
        #if os(macOS)
        b[CodingTools.search] = "搜这台 Mac 上编程 agent 的会话记录"
        b[CodingTools.listSessions] = "列最近的编程会话"
        b[CodingTools.getSession] = "读一条编程会话的转录"
        b[CodingTools.listProjects] = "列有编程会话的项目"
        #endif
        return b
    }()

    /// 这一轮能用的全部内建工具（直接给的 + 收在「更多工具」里的）
    @MainActor
    static func enabledDefinitions(_ ctx: ToolGateContext) -> [ToolDefinition] {
        all.filter { $0.enabledIf(ctx) }.map(\.definition)
    }

    /// 放进工具清单直接给模型的
    @MainActor
    static func inlineDefinitions(_ ctx: ToolGateContext) -> [ToolDefinition] {
        enabledDefinitions(ctx).filter { !tuckedNames.contains($0.name) }
    }

    /// 能用、但收在「更多工具」里的
    @MainActor
    static func tuckedDefinitions(_ ctx: ToolGateContext) -> [ToolDefinition] {
        enabledDefinitions(ctx).filter { tuckedNames.contains($0.name) }
    }

    /// 执行前复查（#069）：模型照着历史直接叫一个这一轮没下发的内建工具时拒掉——
    /// 只靠开关门控、不归权限域的工具（remember / recall…）权限闸拦不住。不是内建工具（MCP）返回 nil
    @MainActor
    static func availability(of name: String, _ ctx: ToolGateContext) -> Bool? {
        let entries = all.filter { $0.definition.name == name }
        guard !entries.isEmpty else { return nil }
        guard PermissionCenter.capabilityEnabled(.toolsMaster) else { return false }
        return entries.contains { $0.enabledIf(ctx) }
    }
}
