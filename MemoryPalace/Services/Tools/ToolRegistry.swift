import MemoryCore
import Foundation

/// 内建工具注册表（plan-pi-style-toolbase P0.2）：
/// 注入侧单一入口——16 个内建工具的定义 + 可用性门控（Hermes check_fn 模式）。
/// 不含：MCP 动态工具（MCPProvider 自渲染）/ Anthropic server 搜索工具（形状特殊，toolInjection 特例）。
/// 新 reflection 风行为走 inner_voice 的 mode 复用，不加新 tool（B-D4）。
enum ToolRegistry {

    /// 五个记忆写工具（关参与窗不下发）：执行前复查拒绝时文案要说清是「本窗关了记忆参与」，不是抽屉里关着
    static let memoryWriteNames: Set<String> = SelfMemoryTool.names.union([PendingNotesTool.toolName, WikiSuggestTool.toolName])

    struct Entry {
        let definition: ToolDefinition
        let enabledIf: (ToolGateContext) -> Bool
    }

    /// 全部内建工具。顺序无所谓——toolInjection 末端按 name 字典序统一排序（prompt cache 前缀稳定）。
    @MainActor
    static var all: [Entry] {
        var entries: [Entry] = []
        entries.append(Entry(definition: TurnStatusTool.definition, enabledIf: { _ in true }))

        // 文件库 9 件（fs_* 8 + 资料卡搭车），总开关 fileLibraryEnabled
        let fileLibraryOn: (ToolGateContext) -> Bool = { ctx in
            PermissionCenter.capabilityEnabled(.fileLibrary, profileId: ctx.profileId)   // askOnce = 下发工具，真调用时问（tool loop 闸）
        }
        entries += FileLibraryTools.definitions.map { Entry(definition: $0, enabledIf: fileLibraryOn) }
        entries.append(Entry(definition: ProfileCardTool.definition, enabledIf: fileLibraryOn))

        // 本地推特（page2 推特子应用）：一个工具 + action，AI 在本楼层推特上发推/刷推；纯本地，默认允许
        entries.append(Entry(definition: TwitterAITool.definition, enabledIf: { ctx in
            PermissionCenter.capabilityEnabled(.twitter, profileId: ctx.profileId)
        }))

        #if PERSONAL_APPS
        // 死亡天平（plan-death-scale §4.5）：只读；工具启用 + 本楼层被授权才下发，别的楼层连工具都看不到
        entries.append(Entry(definition: DeathScaleAITool.definition, enabledIf: { ctx in
            DeathScaleAITool.isAvailable(profileId: ctx.profileId)
        }))
        #endif

        // 心声（reflection mode 入口）
        entries.append(Entry(definition: InnerVoice.definition, enabledIf: { _ in InnerVoice.enabled }))

        // recall（SC-B1）
        entries.append(Entry(definition: RecallTool.definition, enabledIf: { _ in RecallTool.enabled }))

        // 自己的记忆（记忆修复第二刀 B2）：remember / edit_memory / forget_memory，受记忆总开关管；关参与窗不下发
        entries += SelfMemoryTool.definitions.map { d in Entry(definition: d, enabledIf: { ctx in SelfMemoryTool.enabled && ctx.memoryWriteTools }) }

        // 待续（v5 §3-2）：标做完了 / 淡了；总开关 && A4 时间轴开着才给；关参与窗不下发
        entries.append(Entry(definition: PendingNotesTool.definition, enabledIf: { ctx in PendingNotesTool.enabled && ctx.memoryWriteTools }))

        // 给 wiki 提整理方向（C2/C3 v2 第 4 段）：只交待批方向；总开关 && C3 开着才给；关参与窗不下发
        entries.append(Entry(definition: WikiSuggestTool.definition, enabledIf: { ctx in WikiSuggestTool.enabled && ctx.memoryWriteTools }))

        // 问问题（官端 AskUserQuestion 同款）：常开，受 sendToolsEnabled 总开关连坐
        entries.append(Entry(definition: AskUserTool.definition, enabledIf: { _ in true }))

        // 掷骰子（聊天卡片，粟粟 09-26）：真随机；常开，受 sendToolsEnabled 总开关连坐
        entries.append(Entry(definition: DiceTool.definition, enabledIf: { _ in true }))

        // 卡片写法按需查（粟粟 10-03）：发了它系统提示里只放目录；同受 sendToolsEnabled 连坐，关了就回到全文
        entries.append(Entry(definition: CardGuideTool.definition, enabledIf: { _ in true }))

        // 联网搜索 client function：openAI 系 + 配了 backend 才发（anthropic 走 server tool，注入处特例）
        entries.append(Entry(definition: WebSearchToolService.clientDefinition, enabledIf: { ctx in
            ctx.family == .openAI
                && PermissionCenter.capabilityEnabled(.webSearch, profileId: ctx.profileId)
                && WebSearchSettings.shared.selected != nil
        }))

        // browse_url：开关开就发，不依赖 backend；anthropic 不发（server tool 一站式）
        entries.append(Entry(definition: BrowseURLTool.definition, enabledIf: { ctx in
            ctx.family == .openAI && PermissionCenter.capabilityEnabled(.webSearch, profileId: ctx.profileId)
        }))

        // 借 Mac 上 Chrome 登录态（plan-opencli-in-app）：两家都发；主 hub 连着且 Mac 上开了总开关才有
        entries += ChromeBridgeTools.definitions.map { d in
            Entry(definition: d, enabledIf: { ctx in ChromeBridgeTools.hubReady && PermissionCenter.capabilityEnabled(.webSearch, profileId: ctx.profileId) })
        }

        #if os(iOS)
        // AI 在花园浏览器里动手（plan-ai-browser-operate）：两家都发；门 = 「AI 操作浏览器」不是不允许（每次询问也发，真调用时弹卡）
        entries += BrowserOperateTools.definitions.map { d in
            Entry(definition: d, enabledIf: { ctx in PermissionCenter.capabilityEnabled(.browserOperate, profileId: ctx.profileId) })
        }
        #endif

        // 设备工具 11 件（plan-设备工具 P1）+ macOS run_command（plan-离线沙箱-phase1）：按域档位下发（askOnce 也下发，真调用时 tool loop 弹卡）
        entries += DeviceToolDispatcher.definitions.map { d in
            Entry(definition: d, enabledIf: { ctx in PermissionCenter.capabilityEnabled(PermissionDomain.forTool(named: d.name), profileId: ctx.profileId) })
        }

        #if os(macOS)
        // 编程会话 4 件（W-N N5）：只读；默认不允许 = 不下发，askOnce 也下发、真调用时问
        entries += CodingTools.definitions.map { d in
            Entry(definition: d, enabledIf: { ctx in PermissionCenter.capabilityEnabled(.codingSessions, profileId: ctx.profileId) })
        }
        #endif

        // 元工具 3 件（放最后：门控要看前面收起来的那些）：MCP 工具海 defer，或有内建工具收在「更多工具」里时上。
        // #093：「收起」按这一轮抽屉算（用户自己收起的也算）；元工具本身不吃抽屉（Q4）
        let builtins = entries
        entries += MetaTools.definitions.map { d in
            Entry(definition: d, enabledIf: { ctx in
                ctx.deferMCP || builtins.contains { $0.enabledIf(ctx) && mode(of: $0.definition.name, ctx) == .tucked }
            })
        }

        return entries
    }

    /// 默认收进「更多工具」的内建工具（#069 第 2 步）：平时聊天用不到，不放进工具清单（省 schema、少干扰选择），
    /// 系统提示〔更多工具〕列名字 + 一句话，经 tool_invoke 调（直接叫名字也照常执行）。只随平台变；#093 起工具抽屉能逐个改
    static let defaultTuckedNames: Set<String> = {
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

    /// 抽屉管不着的：元工具、只随工具总开关的临时状态、隐藏子应用。
    static var drawerExempt: Set<String> {
        var names = MetaTools.names
        names.insert(TurnStatusTool.toolName)
        #if PERSONAL_APPS
        names.insert(DeathScaleAITool.toolName)
        #endif
        return names
    }

    /// Anthropic 服务端搜索（不在注册表，注入处特例）：抽屉里只有开 / 关（tool_invoke 调不到服务端工具，不能收起）
    static let serverWebSearchName = "web_search"

    static func serverWebSearchOn(_ ctx: ToolGateContext) -> Bool {
        ctx.drawer.override(serverWebSearchName, profileId: ctx.profileId) != .off
    }

    /// 抽屉没改过时的档位
    static func defaultMode(_ name: String) -> ToolDrawerMode {
        defaultTuckedNames.contains(name) ? .tucked : .inline
    }

    /// 这一轮抽屉里的档位（本楼层覆盖 → 全局 → 默认）；上游门另算
    static func mode(of name: String, _ ctx: ToolGateContext) -> ToolDrawerMode {
        if drawerExempt.contains(name) { return .inline }
        return ctx.drawer.override(name, profileId: ctx.profileId) ?? defaultMode(name)
    }

    /// 〔更多工具〕/ tool_search 里的一句话：手写的 blurb，没有（用户自己收起的，比如 fs_write）就取描述第一句
    static func blurb(for d: ToolDefinition) -> String {
        tuckedBlurbs[d.name] ?? firstSentence(d.description)
    }

    /// 描述的第一句（到「。」或换行），超过 60 字截断加「…」。〔当前能用的工具〕和 blurb 共用这一种切法
    static func firstSentence(_ description: String) -> String {
        let first = description.split(whereSeparator: { "。\n".contains($0) }).first.map(String.init) ?? description
        return first.count > 60 ? String(first.prefix(60)) + "…" : first
    }

    /// 这一轮能用的全部内建工具（直接给的 + 收在「更多工具」里的）：上游门开 且 抽屉不是关
    @MainActor
    static func enabledDefinitions(_ ctx: ToolGateContext) -> [ToolDefinition] {
        all.filter { $0.enabledIf(ctx) && mode(of: $0.definition.name, ctx) != .off }
            .map { $0.definition.name == WikiSuggestTool.toolName ? WikiSuggestTool.definition(userName: ctx.userName) : $0.definition }
    }

    /// 放进工具清单直接给模型的
    @MainActor
    static func inlineDefinitions(_ ctx: ToolGateContext) -> [ToolDefinition] {
        enabledDefinitions(ctx).filter { mode(of: $0.name, ctx) == .inline }
    }

    /// 能用、但收在「更多工具」里的
    @MainActor
    static func tuckedDefinitions(_ ctx: ToolGateContext) -> [ToolDefinition] {
        enabledDefinitions(ctx).filter { mode(of: $0.name, ctx) == .tucked }
    }

    /// 执行前复查（#069）：模型照着历史直接叫一个这一轮没下发的内建工具时拒掉（#093：抽屉里关了的也拒）——
    /// 只靠开关门控、不归权限域的工具（remember / recall…）权限闸拦不住。不是内建工具（MCP）返回 nil
    @MainActor
    static func availability(of name: String, _ ctx: ToolGateContext) -> Bool? {
        let entries = all.filter { $0.definition.name == name }
        guard !entries.isEmpty else { return nil }
        guard PermissionCenter.capabilityEnabled(.toolsMaster, profileId: ctx.profileId) else { return false }
        return entries.contains { $0.enabledIf(ctx) && mode(of: name, ctx) != .off }
    }
}
