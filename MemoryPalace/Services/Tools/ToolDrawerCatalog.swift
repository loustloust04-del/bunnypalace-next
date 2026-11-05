import Foundation

/// 工具抽屉（#093 §2.1）给人看的目录：每个工具归哪组、一句话说明、上游是哪道门。
/// 和 ToolRegistry.tuckedBlurbs（给模型看的第二人称）分开放，受众不同。
/// 说明里 {char} / {user} 渲染时换成这一楼层的名字（不写死）。隐藏子应用不进目录。
enum ToolDrawerCatalog {

    enum Group: String, CaseIterable, Identifiable {
        case fileLibrary, memory, device, twitter, search, other
        var id: String { rawValue }

        var title: String {
            switch self {
            case .fileLibrary: return "文件库"
            case .memory: return "记忆"
            case .device: return "设备"
            case .twitter: return "推特"
            case .search: return "搜索"
            case .other: return "其他"
            }
        }

        /// 整组对应一个权限域的，组头直接放权限页同一个档位控件
        var permissionDomain: PermissionDomain? {
            switch self {
            case .fileLibrary: return .fileLibrary
            case .twitter: return .twitter
            case .search: return .webSearch
            case .memory, .device, .other: return nil
            }
        }
    }

    /// 上游门（抽屉只能在它之内收窄）
    enum Gate: Equatable {
        case permission(PermissionDomain)
        /// 设置 · 记忆 · 写入里这一项（总开关 && 这一项）
        case memoryWriter(MemoryWriterID)
        case convHistory
        case heartVoice
        /// 只随工具总开关
        case always
        /// 元工具：有收起的工具（或 MCP 太多）时自动给，不能手动开关
        case auto
    }

    struct Item: Identifiable, Equatable {
        let name: String
        let group: Group
        /// 给人看的一句话，{char} / {user} 渲染时替换
        let summary: String
        let gate: Gate
        var id: String { name }

        /// 元工具只读
        var canToggle: Bool { gate != .auto }
        /// 服务端搜索 tool_invoke 调不到、元工具本身就是门：不能收起
        var canTuck: Bool { canToggle && name != ToolRegistry.serverWebSearchName }
    }

    static var items: [Item] {
        var list: [Item] = [
            Item(name: FileLibraryTools.Name.list.rawValue, group: .fileLibrary, summary: "{char} 看文件库里有哪些文件", gate: .permission(.fileLibrary)),
            Item(name: FileLibraryTools.Name.read.rawValue, group: .fileLibrary, summary: "{char} 读文件库里的文件", gate: .permission(.fileLibrary)),
            Item(name: FileLibraryTools.Name.search.rawValue, group: .fileLibrary, summary: "{char} 在文件库里搜内容", gate: .permission(.fileLibrary)),
            Item(name: FileLibraryTools.Name.write.rawValue, group: .fileLibrary, summary: "{char} 新建或整篇覆盖写文件", gate: .permission(.fileLibrary)),
            Item(name: FileLibraryTools.Name.append.rawValue, group: .fileLibrary, summary: "{char} 往文件末尾接着写", gate: .permission(.fileLibrary)),
            Item(name: FileLibraryTools.Name.edit.rawValue, group: .fileLibrary, summary: "{char} 改文件里的一段", gate: .permission(.fileLibrary)),
            Item(name: FileLibraryTools.Name.rename.rawValue, group: .fileLibrary, summary: "{char} 给文件改名、挪位置", gate: .permission(.fileLibrary)),
            Item(name: FileLibraryTools.Name.delete.rawValue, group: .fileLibrary, summary: "{char} 删文件库里的文件", gate: .permission(.fileLibrary)),
            Item(name: ProfileCardTool.toolName, group: .fileLibrary, summary: "{char} 改自己资料卡上的状态、自我介绍", gate: .permission(.fileLibrary)),

            Item(name: SelfMemoryTool.rememberName, group: .memory, summary: "{char} 记下一条自己的记忆", gate: .memoryWriter(.b4)),
            Item(name: SelfMemoryTool.editName, group: .memory, summary: "{char} 改一条记过的记忆", gate: .memoryWriter(.b4)),
            Item(name: SelfMemoryTool.forgetName, group: .memory, summary: "{char} 把一条记忆标成失效", gate: .memoryWriter(.b4)),
            Item(name: PendingNotesTool.toolName, group: .memory, summary: "{char} 看待续、标做完了 / 淡了", gate: .memoryWriter(.a4)),
            Item(name: WikiSuggestTool.toolName, group: .memory, summary: "{char} 给记忆 wiki 提整理方向（{user}批了才去查、写）", gate: .memoryWriter(.c3)),
            Item(name: RecallTool.toolName, group: .memory, summary: "{char} 搜和{user}的对话历史、记忆库", gate: .convHistory),
            Item(name: InnerVoice.toolName, group: .memory, summary: "{char} 写下心声", gate: .heartVoice),

            Item(name: CalendarTools.queryName, group: .device, summary: "{char} 查{user}的日历", gate: .permission(.calendar)),
            Item(name: CalendarTools.createName, group: .device, summary: "{char} 在{user}的日历里建日程", gate: .permission(.calendar)),
            Item(name: CalendarTools.deleteName, group: .device, summary: "{char} 删{user}日历里的日程", gate: .permission(.calendar)),
            Item(name: RemindersTools.queryName, group: .device, summary: "{char} 查{user}的提醒事项", gate: .permission(.reminders)),
            Item(name: RemindersTools.createName, group: .device, summary: "{char} 给{user}建一条提醒", gate: .permission(.reminders)),
            Item(name: RemindersTools.completeName, group: .device, summary: "{char} 把一条提醒标成完成", gate: .permission(.reminders)),
            Item(name: ClipboardTool.toolName, group: .device, summary: "{char} 读{user}设备的剪贴板", gate: .permission(.clipboard)),
            Item(name: NotifyTool.toolName, group: .device, summary: "{char} 到点给{user}发通知", gate: .permission(.notifications)),
            Item(name: OCRImageTool.toolName, group: .device, summary: "{char} 识别图片里的文字", gate: .always),
            Item(name: OpenURLTool.toolName, group: .device, summary: "{char} 在{user}的设备上打开链接", gate: .always),
            Item(name: DeviceInfoTool.toolName, group: .device, summary: "{char} 看设备型号、电量、存储空间", gate: .always),
            Item(name: RunCommandTool.toolName, group: .device, summary: runCommandSummary, gate: .permission(.shell)),

            Item(name: TwitterAITool.toolName, group: .twitter, summary: "{char} 在本楼层的推特上发推、刷推、回复", gate: .permission(.twitter)),

            Item(name: ToolRegistry.serverWebSearchName, group: .search, summary: "{char} 联网搜索（Anthropic 卡，服务端执行）", gate: .permission(.webSearch)),
            Item(name: WebSearchToolService.toolName, group: .search, summary: "{char} 联网搜索（OpenAI 系卡，要配搜索服务）", gate: .permission(.webSearch)),
            Item(name: BrowseURLTool.toolName, group: .search, summary: "{char} 打开网页读内容（OpenAI 系卡）", gate: .permission(.webSearch)),

            Item(name: AskUserTool.toolName, group: .other, summary: "{char} 出选择题问{user}", gate: .always),
            Item(name: DiceTool.toolName, group: .other, summary: "{char} 掷骰子、随机抽选", gate: .always),
            Item(name: CardGuideTool.toolName, group: .other, summary: "{char} 发卡片前查写法（关了：系统提示里不再放卡片写法，{char} 不会主动发卡片）", gate: .always),
        ]
        #if os(macOS)
        list += [
            Item(name: CodingTools.search, group: .other, summary: "{char} 搜这台 Mac 上编程 agent 的会话记录", gate: .permission(.codingSessions)),
            Item(name: CodingTools.listSessions, group: .other, summary: "{char} 列最近的编程会话", gate: .permission(.codingSessions)),
            Item(name: CodingTools.getSession, group: .other, summary: "{char} 读一条编程会话的转录", gate: .permission(.codingSessions)),
            Item(name: CodingTools.listProjects, group: .other, summary: "{char} 列有编程会话的项目", gate: .permission(.codingSessions)),
        ]
        #endif
        list += [MetaTools.searchName, MetaTools.inspectName, MetaTools.invokeName].map {
            Item(name: $0, group: .other, summary: "{char} 搜、看、调〔更多工具〕里的工具", gate: .auto)
        }
        return list
    }

    private static var runCommandSummary: String {
        #if os(macOS)
        return "{char} 在这台 Mac 上跑 shell 命令"
        #else
        return "{char} 在 app 内置的 Linux 沙箱里跑命令"
        #endif
    }

    static func item(named name: String) -> Item? {
        items.first { $0.name == name }
    }

    static func summary(_ item: Item, assistantName: String, userName: String) -> String {
        item.summary
            .replacingOccurrences(of: "{char}", with: assistantName)
            .replacingOccurrences(of: "{user}", with: userName)
    }

    /// 上游门的名字（被它关着时行下写「X 关着」）
    static func gateLabel(_ gate: Gate) -> String {
        switch gate {
        case .permission(let domain): return "权限 · \(domain.displayName)"
        case .memoryWriter(let id): return "设置 · 记忆 · \(id.code)"
        case .convHistory: return "设置 · 记忆 · 对话历史搜索"
        case .heartVoice: return "设置 · 记忆 · 心声"
        case .always: return "工具调用总开关"
        case .auto: return "自动"
        }
    }
}
