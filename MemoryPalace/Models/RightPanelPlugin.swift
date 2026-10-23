import Foundation

// MARK: - Right Panel Tool

struct RightPanelTool: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var icon: String          // SF Symbol name
    var isPinned: Bool = true // 兼容旧字段，但现在和 isEnabled 同步
    var isEnabled: Bool = true // 唯一开关：false = toolbar + 抽屉 + 设置页联动关闭
    var order: Int = 0
}

// MARK: - Right Panel Tool Manager

@Observable
final class RightPanelToolManager {
    private static let storageKey = "rightPanelTools"

    /// lite 模式白名单（粟粟 2026-08-26 拍板）：日历/记忆+生活模块默认露出，
    /// 世界书/卡库/Prompt/CC终端/文件库/浏览器/军机处/交易 在 lite 下默认隐藏。
    /// 只在读取口过滤，不动 rightPanelTools 存档——切 pro 全部自动回来。
    static let liteVisibleToolIds: Set<String> = {
        var ids: Set<String> = [
            "calendar", "memory", "sticker",
            "health", "reading", "vocab",
            "xiaoya",   // 小芽助手：创作门槛恰恰压在 lite 用户身上（plan-小芽助手 Q2）
            "study",    // 学堂：点一下就能开课，lite 新用户也要看得见（plan-study-zero-engine P4）
        ]
        #if PERSONAL_APPS
        #if DEBUG
        ids.formUnion(["topicBox", "audiobook"])   // 话题盒 / 有声书只进粟粟的 Debug 包（#096）
        #endif
        #endif
        return ids
    }()

    var tools: [RightPanelTool]

    /// 当前是否 pro 模式（macOS 没有 lite 模式，恒 true）。
    /// 监听 UserDefaults 变更保持可观察，切开关时 dock/桌面即时刷新。
    private(set) var proMode: Bool = {
        #if os(iOS)
        return UserDefaults.standard.bool(forKey: "settings.proMode")
        #else
        return true
        #endif
    }()

    /// lite 模式下该工具是否可见（pro 全可见；不动 isEnabled 存档）
    func isVisibleInCurrentMode(_ tool: RightPanelTool) -> Bool {
        proMode || Self.liteVisibleToolIds.contains(tool.id)
    }

    /// 已启用的工具（toolbar 显示，按 order 排序）；lite 下再按白名单过滤
    var pinnedTools: [RightPanelTool] {
        tools.filter(\.isEnabled).sorted { $0.order < $1.order }.filter { isVisibleInCurrentMode($0) }
    }

    /// 全部工具（抽屉/设置页显示，按 order 排序）
    var allToolsSorted: [RightPanelTool] {
        tools.sorted { $0.order < $1.order }
    }

    init() {
        self.tools = Self.load()
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            let v = UserDefaults.standard.bool(forKey: "settings.proMode")
            guard let self, self.proMode != v else { return }
            self.proMode = v
        }
        #endif
    }

    // MARK: - Enable / Disable（toolbar 移除 和 设置页 Toggle 统一入口）

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let idx = tools.firstIndex(where: { $0.id == id }) else { return }
        tools[idx].isEnabled = enabled
        tools[idx].isPinned = enabled // 同步
        persist()
    }

    // MARK: - Drag Reorder（拖拽排序）

    /// 把 fromId 移到 toId 的位置（toolbar 和抽屉共用）
    func reorder(fromId: String, toId: String) {
        guard fromId != toId else { return }
        var sorted = allToolsSorted
        guard let fromIdx = sorted.firstIndex(where: { $0.id == fromId }),
              let toIdx = sorted.firstIndex(where: { $0.id == toId }) else { return }

        let moving = sorted.remove(at: fromIdx)
        sorted.insert(moving, at: toIdx)

        // 重新编号 order
        for (i, tool) in sorted.enumerated() {
            if let ti = tools.firstIndex(where: { $0.id == tool.id }) {
                tools[ti].order = i
            }
        }
        persist()
    }

    // MARK: - Query

    func tool(byId id: String) -> RightPanelTool? {
        tools.first { $0.id == id }
    }

    /// 当前选中的工具被禁用后，回落到第一个可用工具
    func fallbackToolId(from current: String) -> String? {
        let pinned = pinnedTools
        if pinned.contains(where: { $0.id == current }) { return nil }
        return pinned.first?.id
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(tools) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func load() -> [RightPanelTool] {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([RightPanelTool].self, from: data),
           !saved.isEmpty {
            return merged(saved: saved, builtIns: builtInTools)
        }
        return builtInTools
    }

    /// 存档 × 内置表合并。存档里不在内置表里的工具丢掉（#096：Debug 包存过的话题盒 / 有声书等 Debug 专属工具，
    /// 换到 Release 后不留空壳图标）；只在读取时过滤，回到 Debug 包会按内置默认补回来。
    static func merged(saved: [RightPanelTool], builtIns: [RightPanelTool]) -> [RightPanelTool] {
        let builtinIds = Set(builtIns.map(\.id))
        var result = saved.filter { builtinIds.contains($0.id) }
        for builtin in builtIns {
            if let idx = result.firstIndex(where: { $0.id == builtin.id }) {
                // icon/name 以内置定义为准（否则改图标对老用户永不生效——
                // 存档整体序列化含 icon）；isEnabled/order 保留用户设置
                result[idx].icon = builtin.icon
                result[idx].name = builtin.name
            } else {
                result.append(builtin)
            }
        }
        return result
    }

    // MARK: - Built-in Tools

    static let builtInTools: [RightPanelTool] = {
        #if os(macOS)
        let terminalName = "Agent 终端"
        #else
        let terminalName = "终端"
        #endif
        var tools: [RightPanelTool] = [
        RightPanelTool(id: "calendar",    name: "日历",    icon: "calendar",                       order: 0),
        RightPanelTool(id: "memory",      name: "记忆",    icon: "brain",                          order: 1),
        RightPanelTool(id: "worldBook",   name: "世界书",  icon: "book.closed",                    order: 2),
        RightPanelTool(id: "cardLibrary", name: "卡库",    icon: "person.crop.rectangle.stack",    order: 3),
        RightPanelTool(id: "sticker",     name: "贴纸",    icon: "ri-emoji-sticker",               order: 4),
        RightPanelTool(id: "prompt",      name: "Prompt", icon: "text.bubble",  isEnabled: false, order: 5),
        RightPanelTool(id: "ccTerminal",  name: terminalName, icon: "terminal",                    order: 6),
        RightPanelTool(id: "fileLibrary", name: "文件库",  icon: "folder.fill",                    order: 7),
        RightPanelTool(id: "browser",     name: "浏览器",  icon: "globe",                          order: 8),
        ]
        // 话题盒 / 有声书只进粟粟的 Debug 包（#096）：TF（Release）和开源快照都没有；order 和数组位置不变
        #if PERSONAL_APPS
        #if DEBUG
        tools += [
        RightPanelTool(id: "audiobook",   name: "有声书",  icon: "headphones",                     order: 9),
        ]
        #endif
        #endif
        tools += [
        RightPanelTool(id: "vocab",       name: "单词",    icon: "abc",                            order: 10),
        RightPanelTool(id: "reading",     name: "书房",    icon: "books.vertical",                 order: 11),
        ]
        #if PERSONAL_APPS
        #if DEBUG
        tools += [
        // icon 字段是 SF 兜底值；pill/抽屉对 topicBox 特例走 PixelGlyph.lightbulb（粟粟拍的像素灯泡）
        RightPanelTool(id: "topicBox",    name: "话题盒",  icon: "lightbulb",                      order: 12),
        ]
        #endif
        #endif
        tools += [
        RightPanelTool(id: "health",      name: "健康",    icon: "heart",                          order: 13),
        ]
        #if PERSONAL_APPS
        tools += [
        // [Bunny patch BP-001] 军机处 / 交易依赖粟粟 Mac 上的服务，小兔这边默认关（代码保留，设置里可再打开）
        RightPanelTool(id: "warroom",     name: "军机处",  icon: "ri-sword",                       isEnabled: false, order: 14),
        RightPanelTool(id: "trading",     name: "交易",    icon: "chart.line.uptrend.xyaxis",      isEnabled: false, order: 15),
        ]
        #endif
        tools += [
        // 面 4.3（A4）：正则从设置页也进右栏，同一份 RegexPage；两端都露（G11 她批），lite 白名单不加
        RightPanelTool(id: "regex",       name: "正则",    icon: "textformat.abc",                 order: 16),
        // page2「推特」（plan-page2-twitter）：导入官方导出包、离线看自己的时间线。
        // 放 builtInTools 而非 platformTools —— 两端都上（粟粟拍：iOS 为主，mac 也要）。
        // order 从 20 起：17-19 已被 platformTools 的 运行/终端/聊天/小芽 占着，撞号排序会乱。
        RightPanelTool(id: "twitter",     name: "推特",    icon: "bird",                           order: 20),
        // page2「学堂」（plan-study-zero-engine）：内置学习说明的文件夹 + 开课；两端都上。21 是 Debug 的「开发」
        RightPanelTool(id: "study",       name: "学堂",    icon: "graduationcap",                  order: 22),
        ]
        #if PERSONAL_APPS
        tools += [
        // 死亡天平（plan-death-scale）：默认关，只有输暗号才打开；未启用时不在任何工具列表里露面
        RightPanelTool(id: "deathScale",  name: "Mort sans sépulture", icon: "scalemass", isEnabled: false, order: 23),
        ]
        #endif
        return tools + platformTools + debugTools
    }()

    #if PERSONAL_APPS
    static let secretToolIds: Set<String> = ["deathScale"]
    #else
    static let secretToolIds: Set<String> = []
    #endif

    /// 不经实例读存档里的工具状态（AI 工具门控用，那里拿不到环境里的 manager）
    static func storedTool(_ id: String) -> RightPanelTool? {
        load().first { $0.id == id }
    }

    #if PERSONAL_APPS
    /// 只进粟粟的 Debug 包：pmBoard = 手机上看 / 跟 Mac 上各 session 说话（plan-dev-subapp-v2，数据靠她 Mac 上的看板服务 4793）
    private static var debugTools: [RightPanelTool] {
        #if DEBUG
        [RightPanelTool(id: "pmBoard", name: "pmBoard", icon: "person.3", order: 21)]
        #else
        []
        #endif
    }
    #else
    private static var debugTools: [RightPanelTool] { [] }
    #endif

    /// 平台专属工具。macOS：「运行」（正在跑的 run_command 进程 + 端口，plan-离线沙箱-phase1 §1.7）；
    /// iOS：「聊天（css自定义）」（Page2 的 WKWebView 聊天渲染器，plan-page2-chat-webview）。
    private static var platformTools: [RightPanelTool] {
        #if os(macOS)
        [RightPanelTool(id: "run", name: "运行", icon: "play.rectangle", order: 17),
         // 本机终端（plan-mp-local-terminal）：像 Otty 一样开任意文件夹；与 cc 桥的「CC 终端」无关
         RightPanelTool(id: "terminal", name: "终端", icon: "apple.terminal", order: 18),
         // 小芽（09-24 粟粟「当然要有」）：代码两端本来就能编，当初只是没有 mac 入口（Page2 桌面 iOS 独有）
         RightPanelTool(id: "xiaoya", name: "小芽", icon: "xiaoya-cameo", order: 19)]
        #else
        // 默认关：设置-外观-「聊天（css自定义）」里开了才上桌面。
        // （isEnabled=false 的工具连 Page2 编辑态的添加区都不出现，pinnedTools 已过滤）
        [RightPanelTool(id: "cssChat", name: "聊天（css自定义）", icon: "paintbrush",
                        isEnabled: false, order: 18),
         // 小芽助手：椭圆肖像（plan-小芽-v2 §3.4，template 随主题染色）
         RightPanelTool(id: "xiaoya", name: "小芽", icon: "xiaoya-cameo", order: 19)]
        #endif
    }
}
