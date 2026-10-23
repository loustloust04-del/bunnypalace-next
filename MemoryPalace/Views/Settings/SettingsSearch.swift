import SwiftUI

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
// MARK: - Settings Search Entry

/// 设置搜索的一条目的地。
///
/// 匹配与打分照抄 rootshell（MIT）`UI/Settings/SettingsView.swift:109-150`：
/// 手写注册表 + token AND + 五档分。没有索引、没有反射、没有 fuzzy——表就百来条，全量算也便宜。
/// 中文天然可用（`localizedLowercase` 后 `contains`），拼音不做。
struct SettingsSearchEntry: Identifiable, Hashable {
    let id: String
    /// 叶子条目直接摘抄源码里的中文 label
    let title: String
    /// 「页面名 › Section 名」；页面级条目写「设置」
    let subtitle: String
    let systemImage: String
    /// 跳转目标；`nil` = 占位条目（结果行右侧「敬请期待」，点了不跳）
    let tab: SettingsView.SettingsTab?
    /// 手写同义词，中英双语
    let keywords: [String]
    /// 空查询时进「推荐」区
    let isSuggested: Bool
    /// 目标页里那一行的锚点 id（`.searchAnchor(_:)`）；`nil` = 只跳页不滚
    /// （页面级 / 占位条目恒 nil；短页面和 macOS-only 的行也留 nil）
    let anchor: String?
    /// 这一行在卡库「设置」页签里（不在设置树）：iOS 点了关设置、打开卡库设置页签；
    /// `tab` 只是兜底（mac 设置搜索只筛侧栏页，这类条目不参与）
    let opensCardLibrarySettings: Bool

    init(
        id: String,
        title: String,
        subtitle: String,
        systemImage: String,
        tab: SettingsView.SettingsTab?,
        keywords: [String],
        isSuggested: Bool = false,
        anchor: String? = nil,
        opensCardLibrarySettings: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tab = tab
        self.keywords = keywords
        self.isSuggested = isSuggested
        self.anchor = anchor
        self.opensCardLibrarySettings = opensCardLibrarySettings
    }

    var isPlaceholder: Bool { tab == nil }

    private var searchBlob: String {
        ([title, subtitle] + keywords)
            .joined(separator: " ")
            .localizedLowercase
    }

    /// 五档分：title 全等 500 / title 前缀 420 / title 包含 320 / subtitle 包含 220 / 只有 keywords 命中 140。
    /// 多 token 是 AND：每个 token 都要落在 blob 里才算命中。
    func matchScore(for rawQuery: String) -> Int? {
        let query = rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        guard !query.isEmpty else { return nil }

        // 全角空格也算分隔（中文输入法默认全角）
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let blob = searchBlob
        guard tokens.allSatisfy(blob.contains) else { return nil }

        let normalizedTitle = title.localizedLowercase
        let normalizedSubtitle = subtitle.localizedLowercase

        if normalizedTitle == query { return 500 }
        if normalizedTitle.hasPrefix(query) { return 420 }
        if normalizedTitle.contains(query) { return 320 }
        if normalizedSubtitle.contains(query) { return 220 }
        return 140
    }
}

// MARK: - Query

extension SettingsSearchEntry {
    /// 空查询时的「推荐」区
    static var suggested: [SettingsSearchEntry] {
        all.filter(\.isSuggested)
    }

    /// 打分排序；同分按标题字典序稳定
    static func filtered(for query: String) -> [SettingsSearchEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return suggested }

        return all
            .compactMap { entry -> (entry: SettingsSearchEntry, score: Int)? in
                guard let score = entry.matchScore(for: trimmed) else { return nil }
                return (entry, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.entry.title.localizedCaseInsensitiveCompare(rhs.entry.title) == .orderedAscending
            }
            .map(\.entry)
    }
}

// MARK: - 折叠组

extension SettingsSearchEntry {
    /// 目标页在 pro 根列表的哪个折叠组里（`SettingsFoldRow` 的 AppStorage key，`SettingsView.swift:104-137`）。
    /// 搜索直接跳进折叠组内的页面时要顺手把组展开——否则用户返回根列表会发现刚去过的按钮「消失」了。
    /// 根级页面 / 无根入口的页面（主题·附件·正则·世界书）返回 nil。
    static func foldStorageKey(for tab: SettingsView.SettingsTab) -> String? {
        switch tab {
        #if os(macOS)
        case .macWorkspace: return nil
        #endif
        #if os(iOS)
        case .subApps: return nil
        #endif
        case .tts, .mcp:
            return "settingsFold.aiExt"
        case .claudeCode, .codex, .agent, .terminal, .myComputer:
            return "settingsFold.devTools"
        case .sticker, .health, .calendar, .reading, .vocab, .groupChat:
            return "settingsFold.modules"
        case .fileLibrary, .sandbox:
            return "settingsFold.storage"
        case .general, .permissions, .data, .config, .appearance, .persona,
             .memory, .api, .usage, .rightPanel, .debug, .manual, .about,
             .theme, .attachment, .regex, .worldBook, .xiaoya:
            return nil
        }
    }

    /// 铺了锚点的长页面（plan §八：内容 >1.5 屏才值得滚，短页跳页即可）。
    /// 带 anchor 的条目必属这几页——单测锁住，别往短页偷偷加。
    static let anchoredTabs: Set<SettingsView.SettingsTab> = [
        .appearance, .memory, .persona, .claudeCode,
        .data, .permissions, .vocab, .fileLibrary, .manual, .reading, .tts, .usage
    ]

    /// 跳转前的准备：把目标页所在折叠组展开。赋值 `selectedSettingsTab` 由调用方做。
    static func expandFoldGroup(for tab: SettingsView.SettingsTab) {
        guard let key = foldStorageKey(for: tab) else { return }
        UserDefaults.standard.set(true, forKey: key)
    }
}

// MARK: - Registry

extension SettingsSearchEntry {
    /// 全表 = 页面级 + 叶子级 + 占位。手写，不做反射。
    static var all: [SettingsSearchEntry] {
        pageEntries + leafEntries + placeholderEntries + manualEntries
    }

    /// 说明书章节：从 bundle 里的 `manual-index.json`（`scripts/manual` 构建产物）生成。
    /// 每页一条（anchor = 页 name），每个 h2 一条（anchor = `name--小节`），都跳 `.manual` 再让 HTML 定位。
    /// id 与 anchor 同值（`testAnchorMatchesEntryID` 的既有约定）。
    static let manualEntries: [SettingsSearchEntry] = {
        struct Anchor: Decodable { let id: String; let title: String }
        struct Page: Decodable {
            let name: String; let title: String; let description: String; let area: String
            let keywords: [String]?; let anchors: [Anchor]?
        }
        guard let url = Bundle.main.url(forResource: "manual-index", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let pages = try? JSONDecoder().decode([Page].self, from: data) else { return [] }
        var out: [SettingsSearchEntry] = []
        for p in pages {
            out.append(.init(id: p.name, title: p.title, subtitle: "文档 › \(p.area)", systemImage: "book",
                             tab: .manual, keywords: (p.keywords ?? []) + [p.description], anchor: p.name))
            for a in p.anchors ?? [] {
                out.append(.init(id: a.id, title: a.title, subtitle: "文档 › \(p.title)", systemImage: "book",
                                 tab: .manual, keywords: [p.title], anchor: a.id))
            }
        }
        return out
    }()

    /// 页面级：每个 `SettingsTab` case 一条。title = 页面 `navigationTitle`，icon = 根列表现有 SF Symbol。
    static var pageEntries: [SettingsSearchEntry] {
        var entries: [SettingsSearchEntry] = [
            .init(id: "page-general", title: "通用", subtitle: "设置", systemImage: "gearshape",
                  tab: .general, keywords: ["楼层", "名字", "昵称", "general", "profile", "floor"]),
            .init(id: "page-permissions", title: "权限", subtitle: "设置", systemImage: "lock.shield",
                  tab: .permissions, keywords: ["隐私", "授权", "档位", "本地模式", "permission", "privacy", "access"],
                  isSuggested: true),
            .init(id: "page-data", title: "数据与备份", subtitle: "设置", systemImage: "archivebox",
                  tab: .data, keywords: ["导入", "导出", "备份", "恢复", "同步", "时间机器", "backup", "export", "import", "sync"],
                  isSuggested: true),
            .init(id: "page-config", title: "config", subtitle: "设置", systemImage: "square.and.arrow.up.on.square",
                  tab: .config, keywords: ["设置导入", "设置导出", "配置", "config", "settings"]),
            .init(id: "page-appearance", title: "外观", subtitle: "设置", systemImage: "paintbrush",
                  tab: .appearance, keywords: ["字体", "气泡", "壁纸", "排版", "样式", "appearance", "font", "bubble", "wallpaper"],
                  isSuggested: true),
            .init(id: "page-theme", title: "主题库", subtitle: "外观 › 主题", systemImage: "paintpalette",
                  tab: .theme, keywords: ["配色", "深色", "浅色", "背景", "theme", "color", "dark", "light"]),
            .init(id: "page-persona", title: "Prompt", subtitle: "设置", systemImage: "text.bubble",
                  tab: .persona, keywords: ["预设", "人格", "插槽", "AI 性格", "提示词", "persona", "preset", "prompt", "slot"],
                  isSuggested: true),
            .init(id: "page-xiaoya", title: "小芽", subtitle: "设置", systemImage: "xiaoya-cameo",
                  tab: .xiaoya, keywords: ["助手", "人设", "创作", "写卡", "assistant", "xiaoya", "rosemary", "芽"]),
            .init(id: "page-worldbook", title: "世界书", subtitle: "Prompt › 相关", systemImage: "book.closed",
                  tab: .worldBook, keywords: ["世界观", "设定", "绑定", "lore", "worldbook", "world info"]),
            .init(id: "page-attachment", title: "附件", subtitle: "Prompt › 相关", systemImage: "paperclip",
                  tab: .attachment, keywords: ["图片", "转述", "上传", "attachment", "image", "upload"]),
            .init(id: "page-regex", title: "正则脚本", subtitle: "Prompt › 相关", systemImage: "textformat.abc",
                  tab: .regex, keywords: ["替换", "过滤", "脚本", "regex", "regexp", "replace", "script"]),
            .init(id: "page-memory", title: "记忆", subtitle: "设置", systemImage: "brain.head.profile",
                  tab: .memory, keywords: ["记住", "画像", "做梦", "注入", "遗忘", "memory", "profile", "dream", "recall"],
                  isSuggested: true),
            .init(id: "page-api", title: "API", subtitle: "设置", systemImage: "network",
                  tab: .api, keywords: ["模型", "key", "密钥", "供应商", "预算", "联网搜索", "model", "provider", "budget", "search"],
                  isSuggested: true),
            .init(id: "page-usage", title: "用量", subtitle: "设置", systemImage: "chart.bar.xaxis",
                  tab: .usage, keywords: ["花费", "账单", "token", "统计", "未计价", "费用", "usage", "cost", "spend", "billing"]),
            .init(id: "page-tts", title: "语音", subtitle: "设置 › AI 连接与拓展", systemImage: "speaker.wave.2",
                  tab: .tts, keywords: ["朗读", "念", "声音", "语速", "tts", "speech", "voice", "read aloud"]),
            .init(id: "page-mcp", title: "MCP", subtitle: "设置 › AI 连接与拓展", systemImage: "point.3.connected.trianglepath.dotted",
                  tab: .mcp, keywords: ["工具", "连接器", "server", "tool", "connector", "mcp"]),
            .init(id: "page-claudecode", title: "Claude Code", subtitle: "设置 › 编程工具", systemImage: "ri-claude",
                  tab: .claudeCode, keywords: ["cc", "桥接", "hub", "推送", "思考", "bridge", "claude", "push"]),
            .init(id: "page-codex", title: "Codex", subtitle: "设置 › 编程工具", systemImage: "ri-openai",
                  tab: .codex, keywords: ["配对", "扫码", "codex", "openai", "pairing"]),
            .init(id: "page-mycomputer", title: SettingsView.SettingsTab.myComputer.rawValue, subtitle: "设置 › 编程工具",
                  systemImage: "laptopcomputer.and.iphone", tab: .myComputer,
                  keywords: ["配对", "我的电脑", "让手机连这台 Mac", "工作目录", "干活目录", "hub", "扫码", "二维码", "电脑", "Mac",
                             "tmux", "连接", "重新连接", "pairing", "computer", "workdir", "connect"]),
            .init(id: "page-agent", title: "Agent", subtitle: "设置 › 编程工具", systemImage: "ri-robot-2",
                  tab: .agent, keywords: ["自主任务", "共读", "预算", "自动", "agent", "autonomy", "budget"]),
            .init(id: "page-terminal", title: "终端", subtitle: "设置 › 编程工具", systemImage: "terminal",
                  tab: .terminal, keywords: ["快捷键", "按键", "工具条", "命令行", "keyboard", "terminal", "shortcut"]),
            .init(id: "page-rightpanel", title: "右栏", subtitle: "设置", systemImage: "sidebar.right",
                  tab: .rightPanel, keywords: ["桌面", "小组件", "工具管理", "panel", "desktop", "widget"]),
            .init(id: "page-sticker", title: "贴纸", subtitle: "设置 › 模块", systemImage: "ri-emoji-sticker",
                  tab: .sticker, keywords: ["便签", "贴纸包", "画布", "sticker", "note", "canvas"]),
            .init(id: "page-health", title: "健康", subtitle: "设置 › 模块", systemImage: "heart.text.square",
                  tab: .health, keywords: ["苹果健康", "步数", "睡眠", "心率", "健身", "health", "steps", "sleep", "heart"]),
            .init(id: "page-calendar", title: "日历", subtitle: "设置 › 模块", systemImage: "calendar",
                  tab: .calendar, keywords: ["月历", "日记", "纪念日", "倒数日", "铅笔", "星孔", "calendar", "journal", "anniversary"]),
        ]
        entries += [
            .init(id: "page-reading", title: "书房", subtitle: "设置 › 模块", systemImage: "books.vertical",
                  tab: .reading, keywords: ["读书", "读书模型", "共读", "书", "阅读", "书摘", "reading", "book", "study"]),
            .init(id: "page-vocab", title: "单词", subtitle: "设置 › 模块", systemImage: "abc",
                  tab: .vocab, keywords: ["背单词", "复习", "生词", "词卡", "vocab", "word", "review", "flashcard"]),
            .init(id: "page-groupchat", title: "群聊", subtitle: "设置 › 模块", systemImage: "person.2",
                  tab: .groupChat, keywords: ["中庭", "多人", "发言", "agora", "group", "chat"]),
            .init(id: "page-filelibrary", title: "文件库", subtitle: "设置 › 储存与文件", systemImage: "folder.fill",
                  tab: .fileLibrary, keywords: ["文件", "icloud", "存储位置", "file", "library", "storage"]),
            .init(id: "page-sandbox", title: "手机里的小电脑", subtitle: "设置 › 储存与文件", systemImage: "shippingbox",
                  tab: .sandbox, keywords: ["小电脑", "沙箱", "alpine", "linux", "命令", "重置沙箱", "sandbox", "ish", "rootfs", "shell"]),
            .init(id: "page-debug", title: "开发调试", subtitle: "设置", systemImage: "ladybug",
                  tab: .debug, keywords: ["调试", "日志", "诊断", "调音台", "debug", "log", "diagnostic"]),
            .init(id: "page-manual", title: "文档", subtitle: "设置 · App 说明书", systemImage: "book",
                  tab: .manual, keywords: ["文档", "说明书", "帮助", "教程", "手册", "manual", "help", "docs", "guide"]),
            .init(id: "page-about", title: "关于记忆花园", subtitle: "设置", systemImage: "leaf",
                  tab: .about, keywords: ["关于", "版本", "构建", "更新", "报告问题", "反馈",
                                          "about", "version", "build", "update", "feedback"])
        ]

        #if os(iOS)
        entries.append(.init(id: "page-subapps", title: "子应用", subtitle: "设置", systemImage: "square.grid.3x3",
            tab: .subApps, keywords: ["聊天（css自定义）", "css", "皮肤", "装修", "KakaoTalk", "ktheme", "Page2", "skin"]))
        #endif
        #if os(macOS)
        entries.append(.init(id: "page-mac-workspace", title: "Mac 工作区", subtitle: "设置", systemImage: "sidebar.left",
            tab: .macWorkspace, keywords: ["Dock", "图标", "分隔线", "分组", "排序", "工具栏", "Code", "编程会话", "来源", "远程主机"]))
        #endif
        return entries
    }

    /// 页面级 icon 按 tab 索引。macOS 设置 tab bar 复用它——不再手写第三份 icon 真相源，
    /// 一级 icon 换新值只改这张 registry，iOS 搜索结果和 macOS tab 一起跟着变。
    static let iconByTab: [SettingsView.SettingsTab: String] = {
        var map: [SettingsView.SettingsTab: String] = [:]
        for entry in pageEntries {
            if let tab = entry.tab, map[tab] == nil { map[tab] = entry.systemImage }
        }
        return map
    }()

    /// 叶子级：各页 Section / 重要 Toggle / Picker / 按钮，title 逐条摘抄源码原文，
    /// subtitle = 「页面名 › Section 名」，跳转只到所在页面（不做滚动到控件，见 plan §七）。
    /// 排除纯动态数据行（API 卡 / MCP server / 正则脚本行 / 读书模型列表 / 终端自定义键）。
    static var leafEntries: [SettingsSearchEntry] {
        let entries = leafGeneral + leafAppearance + leafPanelLayout + leafPersona + leafAPI + leafMemory
            + leafData + leafDevTools + leafModules + leafStorage + leafPermissions
        #if os(macOS)
        // 这两行只在 iOS 页上有（终端按键布局 / 右栏桌面样式），mac 搜出来会跳到一个没有它的页
        return entries.filter { !Self.iOSOnlyLeafIds.contains($0.id) } + [
            .init(id: "leaf-mac-workspace-dock", title: "Dock 排列", subtitle: "Mac 工作区 › Dock 排列", systemImage: "line.3.horizontal",
                  tab: .macWorkspace, keywords: ["工具栏", "图标", "分隔线", "分组", "拖动", "排序", "移除", "恢复"]),
            .init(id: "leaf-mac-workspace-code", title: "在对话列表显示 Code 入口", subtitle: "Mac 工作区 › 编程会话", systemImage: "chevron.left.forwardslash.chevron.right",
                  tab: .macWorkspace, keywords: ["code", "编程会话", "显示", "隐藏", "入口", "来源", "远程主机"]),
            .init(id: "leaf-mac-workspace-code-sources", title: "会话来源与远程主机…", subtitle: "Mac 工作区 › 编程会话", systemImage: "folder.badge.gearshape",
                  tab: .macWorkspace, keywords: ["code", "编程", "会话来源", "扫描位置", "路径", "远程主机", "locations"]),
            .init(id: "leaf-mac-software-update", title: "软件更新", subtitle: "Mac 工作区 › 软件更新", systemImage: "arrow.down.circle",
                  tab: .macWorkspace, keywords: ["更新", "检查更新", "自动更新", "自动下载", "版本", "sparkle", "update"])
        ] + leafPersonal
        #else
        return entries + leafSubApps + leafPersonal
        #endif
    }

    private static var leafPersonal: [SettingsSearchEntry] { [] }

    #if os(iOS)
    /// 子应用 › 聊天（css自定义）：二级页，只跳到「子应用」页不滚
    private static var leafSubApps: [SettingsSearchEntry] {
        [
            .init(id: "leaf-study-layout", title: "书房布局", subtitle: "书房 › 书房", systemImage: "books.vertical",
                  tab: .reading, keywords: ["书格", "书单", "3D", "书架", "布局", "layout", "shelf"], anchor: "leaf-study-layout"),
            .init(id: "leaf-study-quote-style", title: "书摘样式", subtitle: "书房 › 书摘", systemImage: "text.quote",
                  tab: .reading, keywords: ["展签", "书页", "书签条", "书摘卡", "quote", "style"], anchor: "leaf-study-quote-style"),
            .init(id: "leaf-study-quote-art", title: "书摘底图", subtitle: "书房 › 书摘", systemImage: "photo.artframe",
                  tab: .reading, keywords: ["名画", "花园", "背景", "底图", "background", "art"], anchor: "leaf-study-quote-art"),
            .init(id: "leaf-study-my-images", title: "我的图片", subtitle: "书房 › 我的图片", systemImage: "photo.badge.plus",
                  tab: .reading, keywords: ["导入", "书摘底图", "自己的图", "import", "photo"], anchor: "leaf-study-my-images"),
            .init(id: "leaf-csschat-font", title: "聊天字号", subtitle: "子应用 › 聊天（css自定义）", systemImage: "textformat.size",
                  tab: .subApps, keywords: ["css", "字号", "字体大小", "font size"]),
            .init(id: "leaf-csschat-bg", title: "背景图", subtitle: "子应用 › 聊天（css自定义）", systemImage: "photo",
                  tab: .subApps, keywords: ["css", "背景", "壁纸", "透明度", "background", "wallpaper"]),
            .init(id: "leaf-csschat-css", title: "CSS", subtitle: "子应用 › 聊天（css自定义）", systemImage: "chevron.left.forwardslash.chevron.right",
                  tab: .subApps, keywords: ["css", "皮肤", "样式", "装修", "skin", "style"]),
            .init(id: "leaf-csschat-import", title: "导入皮肤…", subtitle: "子应用 › 聊天（css自定义）", systemImage: "square.and.arrow.down",
                  tab: .subApps, keywords: ["KakaoTalk", "ktheme", "mpskin", "皮肤", "import", "theme"]),
        ]
    }
    #endif

    #if os(macOS)
    // A4 后 mac 的反馈入口在侧栏底（不在 .debug 页里），搜索跳过去也看不到那一行 → 与 iOS-only 叶子同处理
    // leaf-debug-inputfont：输入框字号调音台是 iOS-only 块（F2 不并），mac 跳到调试页也找不到它。
    // leaf-debug-feedback 不过滤：mac 的反馈入口在侧栏底（A4），跳到任意页都看得见那一行（R6b S7）
    // leaf-appear-ipadwidth：正文栏宽度是 iOS-only 行（F3 不并）；leaf-persona-related：mac Prompt 页不加「相关」组（A2）——跳过去都没有那一行（R6c S3）
    // leaf-terminal-*：终端页只管键盘工具条，mac 没有工具条、侧栏也不露这一页（T43）
    private static let iOSOnlyLeafIds: Set<String> = ["leaf-terminal-layout", "leaf-terminal-drawer", "leaf-terminal-custom", "leaf-terminal-reset", "leaf-rightpanel-style", "leaf-rightpanel-switcher", "leaf-debug-inputfont", "leaf-appear-ipadwidth", "leaf-persona-related", "leaf-appear-groupchat"]
    #endif

    // MARK: 叶子 · 通用 / 语音 / 附件 / 世界书

    private static var leafGeneral: [SettingsSearchEntry] {
        [
            .init(id: "leaf-general-floor", title: "楼层", subtitle: "通用 › 楼层", systemImage: "building.2",
                  tab: .general, keywords: ["切换楼层", "新建楼层", "profile", "floor"]),
            .init(id: "leaf-general-username", title: "我的名字", subtitle: "通用 › 气泡标签", systemImage: "person",
                  tab: .general, keywords: ["昵称", "用户名", "称呼", "name", "user"]),
            .init(id: "leaf-general-ainame", title: "AI 的名字", subtitle: "通用 › 气泡标签", systemImage: "person.crop.circle",
                  tab: .general, keywords: ["助手名", "昵称", "称呼", "assistant", "name"]),
            .init(id: "leaf-general-bubblelabel", title: "气泡标签", subtitle: "通用 › 气泡标签", systemImage: "text.bubble",
                  tab: .general, keywords: ["名称标签", "显示名字", "label", "bubble"]),
            .init(id: "leaf-tts-enable", title: "启用系统朗读", subtitle: "语音 › 朗读", systemImage: "speaker.wave.2",
                  tab: .tts, keywords: ["念出来", "朗读", "tts", "speak", "read aloud"]),
            .init(id: "leaf-tts-rate", title: "语速", subtitle: "语音 › 朗读", systemImage: "gauge.with.needle",
                  tab: .tts, keywords: ["快慢", "速度", "rate", "speed"]),
            .init(id: "leaf-tts-voicemsg", title: "语音条", subtitle: "语音 › 语音条", systemImage: "waveform",
                  tab: .tts, keywords: ["语音消息", "录音", "voice message", "audio"]),
            .init(id: "leaf-tts-voiceservices", title: "语音服务", subtitle: "语音 › 语音服务", systemImage: "waveform.badge.plus",
                  tab: .tts, keywords: ["语音厂商", "试听", "ElevenLabs", "MiniMax", "OpenAI", "系统音", "key", "voice provider", "tts service"]),
            .init(id: "leaf-tts-floorvoice", title: "声音", subtitle: "语音 › 声音", systemImage: "person.wave.2",
                  tab: .tts, keywords: ["楼层声音", "音色", "选声音", "语音条模型", "通话模型", "voice", "model"]),
            .init(id: "leaf-tts-voicenote", title: "嗓子补充说明", subtitle: "语音 › 声音", systemImage: "text.quote",
                  tab: .tts, keywords: ["音色描述", "口头禅", "标签", "拟声词", "语音条提示词", "voice note", "prompt"]),
            .init(id: "leaf-tts-prosody", title: "听语气", subtitle: "语音 › 听语气", systemImage: "waveform",
                  tab: .tts, keywords: ["语气线索", "声音变化", "停顿", "静音", "韵律", "prosody"],
                  anchor: "leaf-tts-prosody"),
            .init(id: "leaf-tts-prosody-reset", title: "清空声音基线", subtitle: "语音 › 听语气", systemImage: "arrow.counterclockwise",
                  tab: .tts, keywords: ["重新学习声音", "重置语气", "baseline", "清空"],
                  anchor: "leaf-tts-prosody-reset"),
            .init(id: "leaf-tts-effects", title: "启用本机音效", subtitle: "语音 › 本机音效", systemImage: "waveform",
                  tab: .tts, keywords: ["亲吻", "亲盒", "水声", "素材", "sfx", "音效"], anchor: "leaf-tts-effects"),
            .init(id: "leaf-tts-effects-import", title: "新建组", subtitle: "语音 › 本机音效", systemImage: "square.and.arrow.down",
                  tab: .tts, keywords: ["导入", "音效素材", "亲盒", "试听", "删除素材", "音效分组", "种类", "插入", "垫底"], anchor: "leaf-tts-effects-import"),
            .init(id: "leaf-tts-effects-call", title: "通话也使用音效", subtitle: "语音 › 本机音效", systemImage: "phone",
                  tab: .tts, keywords: ["通话音效", "电话亲吻", "电话水声", "分块合成"], anchor: "leaf-tts-effects-call"),
            .init(id: "leaf-tts-speaker", title: "声纹关系线索", subtitle: "语音 › 本机声纹", systemImage: "person.wave.2",
                  tab: .tts, keywords: ["认人", "本人声音", "说话人", "speaker"], anchor: "leaf-tts-speaker"),
            .init(id: "leaf-tts-speaker-enroll", title: "声纹档案", subtitle: "语音 › 本机声纹", systemImage: "person.crop.circle.badge.plus",
                  tab: .tts, keywords: ["录入声音", "声纹模型", "ONNX", "熟人", "删除声纹"], anchor: "leaf-tts-speaker-enroll"),
            .init(id: "leaf-attach-sendimage", title: "发送图片给模型", subtitle: "附件 › 图片", systemImage: "photo",
                  tab: .attachment, keywords: ["图片", "视觉", "多模态", "image", "vision"]),
            .init(id: "leaf-attach-ctximages", title: "上下文图片", subtitle: "附件 › 图片", systemImage: "photo.stack",
                  tab: .attachment, keywords: ["携带图片", "张数", "context", "image"]),
            .init(id: "leaf-attach-transcribe", title: "图片转述省 token", subtitle: "附件 › 图片", systemImage: "text.viewfinder",
                  tab: .attachment, keywords: ["转述", "省钱", "描述", "transcription", "token"]),
            .init(id: "leaf-worldbook-binding", title: "世界书绑定", subtitle: "世界书", systemImage: "book.closed",
                  tab: .worldBook, keywords: ["绑定", "设定集", "lore", "worldbook", "binding"]),
            // 卡库设置页签（⑥）：tab 只是兜底，iOS 跳卡库
            .init(id: "leaf-cardlib-autoresume", title: "点卡直接进最近的聊天", subtitle: "卡库 › 设置 › 用卡",
                  systemImage: "person.crop.rectangle.stack", tab: .worldBook,
                  keywords: ["卡库", "角色卡", "续聊", "最近的聊天", "自动进入", "card library", "resume"],
                  opensCardLibrarySettings: true),
            .init(id: "leaf-cardlib-webscripts", title: "允许卡里的网页运行脚本", subtitle: "卡库 › 设置 › 前端卡",
                  systemImage: "chevron.left.forwardslash.chevron.right", tab: .worldBook,
                  keywords: ["卡库", "前端卡", "脚本", "网页", "授权", "html", "script"],
                  opensCardLibrarySettings: true),
            .init(id: "leaf-cardlib-sendconsent", title: "替你发消息", subtitle: "卡库 › 设置 › 前端卡",
                  systemImage: "paperplane", tab: .worldBook,
                  keywords: ["卡库", "前端卡", "代发", "发消息", "问我", "直接发", "只填输入框", "triggerSlash", "send"],
                  opensCardLibrarySettings: true),
            .init(id: "leaf-cardlib-wbmax", title: "每次最多注入", subtitle: "卡库 › 设置 › 世界书",
                  systemImage: "book.closed", tab: .worldBook,
                  keywords: ["世界书", "条数", "注入上限", "token 预算", "卡库", "lore", "worldbook", "limit"],
                  opensCardLibrarySettings: true),
            .init(id: "leaf-cardlib-stimport", title: "整包导入", subtitle: "卡库 › 设置 › 酒馆整包",
                  systemImage: "archivebox", tab: .worldBook,
                  keywords: ["酒馆", "整包", "导入", "撤回", "导入来源", "导入报告", "备份", "压缩包", "default-user",
                             "sillytavern", "tavern", "import", "zip", "retract"],
                  opensCardLibrarySettings: true),
            .init(id: "leaf-xiaoya-stage", title: "小芽舞台", subtitle: "小芽 › 舞台", systemImage: "theatermasks",
                  tab: .xiaoya, keywords: ["剪纸", "剧场", "幕布", "主题", "太阳", "月亮", "薄荷夜场", "胭脂剧场", "粉绿马戏", "拼贴剧场", "stage", "theme"]),
            .init(id: "leaf-xiaoya-local", title: "小芽本地大脑", subtitle: "小芽 › 本地大脑", systemImage: "cpu",
                  tab: .xiaoya, keywords: ["本地", "离线", "模型", "下载", "qwen", "mlx", "local", "offline", "model"]),
            .init(id: "leaf-xiaoya-packs", title: "小芽能做什么", subtitle: "小芽 › 能做什么", systemImage: "checkmark.shield",
                  tab: .xiaoya, keywords: ["权限", "查阅", "创作", "外观", "壁纸", "图标", "盖章", "撤销", "账本", "permission", "approve", "undo", "appearance", "xiaoya"])
        ]
    }

    // MARK: 叶子 · 外观 / 主题库

    private static var leafAppearance: [SettingsSearchEntry] {
        [
            .init(id: "leaf-appear-liststyle", title: "列表样式", subtitle: "外观 › 对话列表", systemImage: "list.bullet",
                  tab: .appearance, keywords: ["对话列表", "紧凑", "详细", "纯净", "两行", "预览", "未读", "list", "compact", "detailed", "pure", "clean", "preview"],
                  anchor: "leaf-appear-liststyle"),
            .init(id: "leaf-appear-livebg", title: "液态金属背景", subtitle: "外观 › 对话列表", systemImage: "drop",
                  tab: .appearance, keywords: ["液态金属", "金属", "铬", "水银", "动态背景", "背景", "liquid metal", "chrome", "shader", "background"],
                  anchor: "leaf-appear-livebg"),
            // 10-02 挪到 设置 › 群聊 › 聊天外观（群聊开着才显示；群聊页不铺锚点，只跳页）
            .init(id: "leaf-appear-groupchat", title: "群聊颜色", subtitle: "群聊 › 聊天外观", systemImage: "person.2",
                  tab: .groupChat, keywords: ["群聊", "背景", "气泡", "颜色", "我的气泡", "对方气泡", "外观", "group", "bubble", "background"]),
            .init(id: "leaf-appear-metalflowers", title: "底部白色小花", subtitle: "外观 › 对话列表", systemImage: "camera.macro",
                  tab: .appearance, keywords: ["小花", "白花", "点点花", "花", "液态金属", "flowers"],
                  anchor: "leaf-appear-metalflowers"),
            .init(id: "leaf-appear-bubblemode", title: "显示方式", subtitle: "外观 › 聊天样式", systemImage: "bubble.left.and.bubble.right",
                  tab: .appearance, keywords: ["气泡", "气泡模式", "文章模式", "bubble", "article"],
                  anchor: "leaf-appear-bubblemode"),
            .init(id: "leaf-appear-theme", title: "主题库", subtitle: "外观 › 主题", systemImage: "paintpalette",
                  tab: .appearance, keywords: ["主题", "换肤", "切换主题", "复制一份", "新主题", "theme", "palette"],
                  anchor: "leaf-appear-theme"),
            .init(id: "leaf-appear-colors", title: "主题颜色", subtitle: "外观 › 主题", systemImage: "eyedropper",
                  tab: .appearance, keywords: ["颜色", "配色", "字色", "主文字", "AI 消息文字", "你的消息文字", "气泡底", "纯净背景", "微调", "饱和度", "明度", "color", "text color", "saturation", "brightness"],
                  anchor: "leaf-appear-colors"),
            .init(id: "leaf-appear-chatbg", title: "聊天背景", subtitle: "外观 › 主题", systemImage: "photo.on.rectangle.angled",
                  tab: .appearance, keywords: ["背景图", "壁纸", "透明度", "遮罩", "位置", "气泡半透明", "wallpaper", "background", "opacity", "veil"],
                  anchor: "leaf-appear-chatbg"),
            .init(id: "leaf-appear-opening", title: "花园背景", subtitle: "外观 › 聊天样式", systemImage: "sparkles",
                  tab: .appearance, keywords: ["开场", "开场白", "首屏", "新对话", "花", "星空", "opening", "greeting"],
                  anchor: "leaf-appear-opening"),
            .init(id: "leaf-appear-text", title: "文本", subtitle: "外观 › 文本", systemImage: "textformat",
                  tab: .appearance, keywords: ["字号", "行距", "text", "font"],
                  anchor: "leaf-appear-text"),
            .init(id: "leaf-appear-font", title: "字体", subtitle: "外观 › 文本", systemImage: "textformat.size",
                  tab: .appearance, keywords: ["字号", "字形", "font", "typeface"],
                  anchor: "leaf-appear-font"),
            // 10-02 挪进 高级外观 › 排版（只 iPad），二级页锚点滚不到 → 只跳外观页
            .init(id: "leaf-appear-ipadwidth", title: "正文栏宽度", subtitle: "外观 › 高级外观 › 排版", systemImage: "ipad.landscape",
                  tab: .appearance, keywords: ["iPad", "平板", "宽度", "正文", "栏宽", "横屏", "width", "column", "landscape"]),
            .init(id: "leaf-appear-chatstyle", title: "聊天样式", subtitle: "外观 › 聊天样式", systemImage: "bubble.left",
                  tab: .appearance, keywords: ["对话样式", "样式", "显示方式", "chat style"]),
            .init(id: "leaf-appear-avatar", title: "显示头像", subtitle: "外观 › 聊天样式", systemImage: "person.circle",
                  tab: .appearance, keywords: ["头像", "avatar"],
                  anchor: "leaf-appear-avatar"),
            .init(id: "leaf-appear-nickname", title: "显示昵称", subtitle: "外观 › 聊天样式", systemImage: "character.cursor.ibeam",
                  tab: .appearance, keywords: ["昵称", "名字", "nickname", "name"],
                  anchor: "leaf-appear-nickname"),
            .init(id: "leaf-appear-timestamp", title: "显示时间戳", subtitle: "外观 › 聊天样式", systemImage: "clock",
                  tab: .appearance, keywords: ["时间", "timestamp", "time"],
                  anchor: "leaf-appear-timestamp"),
            .init(id: "leaf-appear-msgdisplay", title: "消息显示", subtitle: "外观 › 消息显示", systemImage: "list.bullet.rectangle",
                  tab: .appearance, keywords: ["flag", "token 用量", "message display"],
                  anchor: "leaf-appear-msgdisplay"),
            // 思考过程 / 想起来了 / 工具调用三行合一条：标题不带「思考」，免得「思考」类搜索抢走 CC 的「显示思考过程」
            .init(id: "leaf-appear-foldblocks", title: "折叠块显示方式", subtitle: "外观 › 消息显示", systemImage: "rectangle.compress.vertical",
                  tab: .appearance, keywords: ["思考过程", "想起来了", "工具调用", "折叠", "展开", "弹出", "thinking", "recall", "tool"],
                  anchor: "leaf-appear-foldblocks"),
            .init(id: "leaf-appear-highlight", title: "划线颜色", subtitle: "外观 › 文本", systemImage: "paintpalette",
                  tab: .appearance, keywords: ["色板", "高亮", "划线", "聊天划线", "读书划线", "颜色", "highlight", "color"],
                  anchor: "leaf-appear-highlight"),
            .init(id: "leaf-appear-waiting", title: "等待回复的文案", subtitle: "外观 › 动效 › 等待动画", systemImage: "ellipsis.bubble",
                  tab: .appearance, keywords: ["思考中", "等待", "loading", "waiting"]),
            .init(id: "leaf-appear-thinkingorb", title: "等待动画", subtitle: "外观 › 动效", systemImage: "circle.hexagongrid",
                  tab: .appearance, keywords: ["思考球", "动画", "orb", "animation", "spinner"],
                  anchor: "leaf-appear-thinkingorb"),
            // 以下几条的控件在「高级外观」二级页（AdvancedAppearancePage）或已不在外观页上，
            // 搜索只跳到外观页 → anchor 留 nil
            .init(id: "leaf-appear-geometry", title: "气泡几何", subtitle: "外观 › 高级外观", systemImage: "square.on.square",
                  tab: .appearance, keywords: ["圆角", "间距", "宽度", "geometry", "radius"]),
            .init(id: "leaf-appear-typeset", title: "排版", subtitle: "外观 › 高级外观", systemImage: "text.alignleft",
                  tab: .appearance, keywords: ["行距", "边距", "typography", "layout"]),
            .init(id: "leaf-appear-wallpaper", title: "边缘模糊", subtitle: "外观 › 高级外观 › 聊天区边缘", systemImage: "rectangle.dashed",
                  tab: .appearance, keywords: ["模糊", "视口", "聊天区边缘", "blur", "viewport"]),
            // 住在二级页（聊天背景）里，锚点滚不到 → 只跳外观页（anchor 规则：必须等于 id 且唯一，别借别人的）
            .init(id: "leaf-appear-translucent", title: "壁纸下气泡自动半透明", subtitle: "外观 › 聊天背景", systemImage: "square.on.square.dashed",
                  tab: .appearance, keywords: ["半透明", "透明度", "translucent", "opacity"]),
            .init(id: "leaf-appear-ring", title: "输入框彩虹描边", subtitle: "外观 › 动效", systemImage: "circle.dashed",
                  tab: .appearance, keywords: ["彩虹描边", "金属环", "liquid metal", "输入框", "ring", "shader"],
                  anchor: "leaf-appear-ring"),
            // 下面两条也在二级页里（主题颜色 / 主题库），只跳外观页
            .init(id: "leaf-theme-bgstrategy", title: "纯净背景", subtitle: "外观 › 主题颜色", systemImage: "photo.artframe",
                  tab: .appearance, keywords: ["背景策略", "克制", "覆盖气泡底", "pure", "background", "strategy"]),
            .init(id: "leaf-theme-save", title: "新建主题", subtitle: "外观 › 主题库", systemImage: "plus",
                  tab: .appearance, keywords: ["添加主题", "存主题", "保存主题", "自定义主题", "复制一份", "另存", "save", "new", "theme"])
        ]
    }

    // MARK: 叶子 · 面板四项（iPad：外观 › 宽屏布局 二级；mac：Mac 工作区 › 面板）

    /// 10-02 从外观一级页挪出：iPad 收进「宽屏布局」二级页（锚点滚不到，只跳外观页、入口行有锚），mac 在 Mac 工作区
    private static var leafPanelLayout: [SettingsSearchEntry] {
        #if os(iOS)
        let tab: SettingsView.SettingsTab = .appearance
        let subtitle = "外观 › 宽屏布局"
        #else
        let tab: SettingsView.SettingsTab = .macWorkspace
        let subtitle = "Mac 工作区 › 面板"
        #endif
        var entries: [SettingsSearchEntry] = [
            .init(id: "leaf-appear-ipadmode", title: "面板模式", subtitle: subtitle, systemImage: "rectangle.split.3x1",
                  tab: tab, keywords: ["iPad", "平板", "面板", "全屏", "浮窗", "窗口", "tab", "侧栏", "dock", "横屏", "panel", "docked", "floating", "window"]),
            .init(id: "leaf-appear-ipadsnap", title: "浮窗吸边对齐", subtitle: subtitle, systemImage: "rectangle.3.group",
                  tab: tab, keywords: ["iPad", "平板", "浮窗", "窗口", "吸边", "对齐", "磁吸", "辅助线", "snap", "align", "magnetic", "window"]),
            .init(id: "leaf-appear-ipadgrid", title: "桌面排版", subtitle: subtitle, systemImage: "square.grid.2x2",
                  tab: tab, keywords: ["iPad", "平板", "桌面", "小组件", "组件", "网格", "格子", "排版", "两列", "一列", "widget", "desktop", "grid", "layout"]),
            .init(id: "leaf-appear-ipaddock", title: "dock", subtitle: subtitle, systemImage: "dock.rectangle",
                  tab: tab, keywords: ["iPad", "平板", "dock", "图标条", "工具栏", "工具条", "左", "右", "位置", "side", "toolbar"]),
        ]
        #if os(iOS)
        entries.append(.init(id: "leaf-appear-widelayout", title: "宽屏布局", subtitle: "外观", systemImage: "ipad.landscape",
                             tab: .appearance, keywords: ["iPad", "平板", "面板", "横屏", "宽屏", "layout"],
                             anchor: "leaf-appear-widelayout"))
        #endif
        return entries
    }

    // MARK: 叶子 · Prompt / 插槽

    /// Prompt 页的行大多藏在模式切换后面（简单 / 插槽 / raw / 组装 / 请求），
    /// 用户当前模式不对时那一行根本不在树上 → 只给各模式都在的行（用量仪表盘、相关入口）挂锚点，
    /// 其余留 nil 照旧跳页（plan §八 逃生舱）。
    private static var leafPersona: [SettingsSearchEntry] {
        [
            .init(id: "leaf-persona-preset", title: "预设", subtitle: "Prompt › 预设", systemImage: "square.stack.3d.up",
                  tab: .persona, keywords: ["酒馆", "preset", "预设卡", "profile"]),
            .init(id: "leaf-persona-slots", title: "Prompt 插槽", subtitle: "Prompt › 插槽", systemImage: "list.bullet.indent",
                  tab: .persona, keywords: ["插槽", "system", "拼装", "slot", "prompt"]),
            .init(id: "leaf-persona-import", title: "导入 Prompt 预设", subtitle: "Prompt › 插槽", systemImage: "square.and.arrow.down",
                  tab: .persona, keywords: ["导入", "酒馆", "json", "import", "preset"]),
            .init(id: "leaf-persona-sampling", title: "采样参数", subtitle: "Prompt › 采样参数", systemImage: "slider.horizontal.3",
                  tab: .persona, keywords: ["温度", "temperature", "top p", "sampling", "max tokens", "输出上限", "按模型自动"]),
            .init(id: "leaf-persona-reasoning", title: "推理深度", subtitle: "Prompt › 采样参数", systemImage: "brain",
                  tab: .persona, keywords: ["思考", "reasoning", "effort", "thinking"]),
            .init(id: "leaf-persona-verbosity", title: "详细度", subtitle: "Prompt › 采样参数", systemImage: "text.justify",
                  tab: .persona, keywords: ["简洁", "详细", "verbosity"]),
            .init(id: "leaf-persona-stream", title: "流式输出", subtitle: "Prompt › 采样参数", systemImage: "waveform.path",
                  tab: .persona, keywords: ["流式", "打字机", "stream", "sse"]),
            .init(id: "leaf-persona-prefill", title: "续写 Prefill", subtitle: "Prompt › 后处理", systemImage: "text.append",
                  tab: .persona, keywords: ["预填", "continue", "prefill"]),
            .init(id: "leaf-persona-suffix", title: "续写后缀", subtitle: "Prompt › 后处理", systemImage: "text.insert",
                  tab: .persona, keywords: ["后缀", "continue", "suffix"]),
            .init(id: "leaf-persona-compress", title: "上下文压缩", subtitle: "Prompt › 用量 · 缓存 · 上下文", systemImage: "arrow.down.right.and.arrow.up.left",
                  tab: .persona, keywords: ["压缩", "总结", "context", "compress"]),
            .init(id: "leaf-persona-usage", title: "用量 · 缓存 · 上下文", subtitle: "Prompt › 用量 · 缓存 · 上下文", systemImage: "chart.bar",
                  tab: .persona, keywords: ["token", "缓存", "上下文", "usage", "cache", "context"],
                  anchor: "leaf-persona-usage"),
            .init(id: "leaf-persona-assembly", title: "组装预览（模板）", subtitle: "Prompt › 组装", systemImage: "doc.text.magnifyingglass",
                  tab: .persona, keywords: ["预览", "组装", "assembly", "preview"]),
            .init(id: "leaf-persona-json", title: "JSON 编辑器", subtitle: "Prompt › JSON", systemImage: "curlybraces",
                  tab: .persona, keywords: ["json", "raw", "编辑器", "editor"]),
            .init(id: "leaf-persona-related", title: "相关", subtitle: "Prompt › 相关", systemImage: "link",
                  tab: .persona, keywords: ["附件", "正则", "世界书", "related"],
                  anchor: "leaf-persona-related")
        ]
    }

    // MARK: 叶子 · API

    private static var leafAPI: [SettingsSearchEntry] {
        [
            .init(id: "leaf-api-keys", title: "API Keys", subtitle: "API › API Keys", systemImage: "key",
                  tab: .api, keywords: ["密钥", "凭证", "供应商", "key", "credential", "provider"]),
            .init(id: "leaf-api-models", title: "全部模型", subtitle: "API › API Keys", systemImage: "ri-stack",
                  tab: .api, keywords: ["模型池", "模型列表", "model", "pool"]),
            .init(id: "leaf-api-websearch", title: "启用联网搜索", subtitle: "API › 联网搜索", systemImage: "globe",
                  tab: .api, keywords: ["搜索", "上网", "web search", "internet"]),
            .init(id: "leaf-api-searchservice", title: "搜索服务", subtitle: "API › 联网搜索", systemImage: "magnifyingglass.circle",
                  tab: .api, keywords: ["搜索引擎", "服务商", "search service"]),
            .init(id: "leaf-api-searchsize", title: "结果数", subtitle: "API › 联网搜索", systemImage: "number",
                  tab: .api, keywords: ["条数", "结果", "result size"]),
            .init(id: "leaf-api-searchtimeout", title: "超时", subtitle: "API › 联网搜索", systemImage: "timer",
                  tab: .api, keywords: ["超时", "timeout"]),
            .init(id: "leaf-api-blocked", title: "黑名单（AI 不读）", subtitle: "API › 联网搜索", systemImage: "hand.raised.slash",
                  tab: .api, keywords: ["黑名单", "屏蔽", "域名", "blocked", "domain"]),
            .init(id: "leaf-api-stream", title: "流式输出", subtitle: "API › 回复方式", systemImage: "waveform",
                  tab: .api, keywords: ["流式", "假流式", "打字", "整包", "stream", "sse"]),
            .init(id: "leaf-api-budget", title: "预算（全局总闸）", subtitle: "API › 预算", systemImage: "dollarsign.circle",
                  tab: .api, keywords: ["花费", "限额", "美元", "budget", "cost", "limit"]),
            .init(id: "leaf-api-budgetlimit", title: "启用预算限额", subtitle: "API › 预算", systemImage: "gauge.with.dots.needle.bottom.50percent",
                  tab: .api, keywords: ["限额", "上限", "budget", "limit"]),
            .init(id: "leaf-api-keychain", title: "iCloud Keychain 同步", subtitle: "API › iCloud Keychain 同步", systemImage: "key.icloud",
                  tab: .api, keywords: ["钥匙串", "同步", "icloud", "keychain", "sync"]),
            .init(id: "leaf-usage-reconciliation", title: "对账", subtitle: "用量 › 对账", systemImage: "checkmark.circle",
                  tab: .usage, keywords: ["Admin key", "管理员密钥", "日账单", "差额", "reconciliation", "billing"],
                  anchor: "leaf-usage-reconciliation")
        ]
    }

    // MARK: 叶子 · 记忆

    private static var leafMemory: [SettingsSearchEntry] {
        [
            .init(id: "leaf-mem-master", title: "记忆系统总开关", subtitle: "记忆", systemImage: "power",
                  tab: .memory, keywords: ["总开关", "启用记忆", "memory", "toggle"],
                  anchor: "leaf-mem-master"),
            .init(id: "leaf-mem-startday", title: "记忆从哪天开始", subtitle: "记忆", systemImage: "calendar.badge.clock",
                  tab: .memory, keywords: ["起点", "开始日期", "从哪天", "不限", "start date", "since"],
                  anchor: "leaf-mem-startday"),
            .init(id: "leaf-mem-inject", title: "注入策略 · 怎么挑记忆", subtitle: "记忆 › 注入策略", systemImage: "arrow.down.doc",
                  tab: .memory, keywords: ["注入", "挑选", "策略", "inject", "strategy"],
                  anchor: "leaf-mem-inject"),
            .init(id: "leaf-mem-injectfull", title: "全量注入", subtitle: "记忆 › 注入策略", systemImage: "tray.full",
                  tab: .memory, keywords: ["全部", "不筛选", "full", "inject"],
                  anchor: "leaf-mem-injectfull"),
            .init(id: "leaf-mem-injectkeyword", title: "关键词命中", subtitle: "记忆 › 注入策略", systemImage: "text.magnifyingglass",
                  tab: .memory, keywords: ["关键词", "keyword", "match"],
                  anchor: "leaf-mem-injectkeyword"),
            .init(id: "leaf-mem-injectvector", title: "按意思找记忆", subtitle: "记忆 › 注入策略", systemImage: "point.3.filled.connected.trianglepath.dotted",
                  tab: .memory, keywords: ["向量检索", "向量语义", "语义", "按意思", "embedding", "vector", "semantic"],
                  anchor: "leaf-mem-injectvector"),
            .init(id: "leaf-mem-injectgraph", title: "关联扩展", subtitle: "记忆 › 注入策略", systemImage: "circle.hexagonpath",
                  tab: .memory, keywords: ["关联", "图谱", "graph", "related"],
                  anchor: "leaf-mem-injectgraph"),
            .init(id: "leaf-mem-content", title: "记忆内容 · 注入什么", subtitle: "记忆 › 记忆内容", systemImage: "doc.text",
                  tab: .memory, keywords: ["内容", "注入什么", "content"],
                  anchor: "leaf-mem-content"),
            .init(id: "leaf-mem-facts", title: "从聊天里记住的", subtitle: "记忆 › 记忆内容", systemImage: "atom",
                  tab: .memory, keywords: ["原子档案", "事实", "提取", "fact", "atomic"],
                  anchor: "leaf-mem-facts"),
            .init(id: "leaf-mem-userprofile", title: "用户画像", subtitle: "记忆 › 用户画像", systemImage: "person.text.rectangle",
                  tab: .memory, keywords: ["画像", "做梦", "profile", "dream"],
                  anchor: "leaf-mem-userprofile"),
            .init(id: "leaf-mem-summary", title: "上下文摘要和窗口总结", subtitle: "记忆 › 记忆内容", systemImage: "text.append",
                  tab: .memory, keywords: ["上下文摘要", "窗口总结", "窗口摘要", "总结", "压缩", "收尾", "summary", "compress", "closeout"],
                  anchor: "leaf-mem-summary"),
            .init(id: "leaf-mem-convhistory", title: "对话历史搜索", subtitle: "记忆 › 记忆内容", systemImage: "clock.arrow.circlepath",
                  tab: .memory, keywords: ["搜索旧对话", "历史", "history", "search"],
                  anchor: "leaf-mem-convhistory"),
            .init(id: "leaf-mem-catalog", title: "目录式注入", subtitle: "记忆 › 记忆内容", systemImage: "list.bullet.rectangle.portrait",
                  tab: .memory, keywords: ["目录", "按需", "catalog"],
                  anchor: "leaf-mem-catalog"),
            .init(id: "leaf-mem-feedback", title: "召回反馈", subtitle: "记忆 › 记忆内容", systemImage: "hand.thumbsup",
                  tab: .memory, keywords: ["点赞", "点踩", "权重", "feedback", "recall"],
                  anchor: "leaf-mem-feedback"),
            .init(id: "leaf-mem-timeline", title: "时间轴", subtitle: "记忆 › 记忆内容", systemImage: "calendar.day.timeline.left",
                  tab: .memory, keywords: ["日记", "时间轴", "跨窗口时间轴", "窗口", "timeline", "diary"],
                  anchor: "leaf-mem-timeline"),
            .init(id: "leaf-mem-heartvoice", title: "心声", subtitle: "记忆 › 记忆内容", systemImage: "heart.text.square",
                  tab: .memory, keywords: ["独白", "心声", "heartvoice", "monologue"],
                  anchor: "leaf-mem-heartvoice"),
            .init(id: "leaf-mem-extractmodel", title: "提取模型", subtitle: "记忆 › 基建", systemImage: "cpu",
                  tab: .memory, keywords: ["提取", "模型", "extract", "model"],
                  anchor: "leaf-mem-extractmodel"),
            .init(id: "leaf-mem-extractprompt", title: "提取提示词", subtitle: "记忆 › 基建", systemImage: "text.quote",
                  tab: .memory, keywords: ["提示词", "prompt", "extract"],
                  anchor: "leaf-mem-extractprompt"),
            .init(id: "leaf-mem-advanced", title: "高级 · 自己记下的", subtitle: "记忆 › 高级", systemImage: "slider.horizontal.3",
                  tab: .memory, keywords: ["最近几条", "每日上限", "预算", "字数", "remember", "limit", "advanced"],
                  anchor: "leaf-mem-advanced"),
            .init(id: "leaf-mem-advanced-session", title: "高级 · 上下文摘要和时间轴", subtitle: "记忆 › 高级", systemImage: "slider.horizontal.3",
                  tab: .memory, keywords: ["全文几段", "时间轴条数", "天数", "窗口摘要", "summary", "timeline", "advanced"],
                  anchor: "leaf-mem-advanced-session"),
            .init(id: "leaf-mem-budget", title: "注入预算", subtitle: "记忆 › 基建", systemImage: "gauge.with.needle",
                  tab: .memory, keywords: ["token", "预算", "budget", "inject"],
                  anchor: "leaf-mem-budget"),
            // 「手动添加记忆」的输入框在 macOS 的 MacMemoryEntriesSections（MemorySettingsPage.swift），
            // iOS 记忆页上没有这一块 → 无锚点
            .init(id: "leaf-mem-add", title: "手动添加记忆", subtitle: "记忆 › 条目管理", systemImage: "plus.circle",
                  tab: .memory, keywords: ["添加", "手动", "add", "memory"]),
            .init(id: "leaf-mem-dream", title: "重写画像", subtitle: "记忆 › 用户画像", systemImage: "moon.stars",
                  tab: .memory, keywords: ["重新做梦", "做梦", "聚合", "dream", "aggregate"],
                  anchor: "leaf-mem-dream"),
            .init(id: "leaf-mem-hygiene", title: "整理记忆", subtitle: "记忆 › 用户画像", systemImage: "sparkles",
                  tab: .memory, keywords: ["整理", "清理", "去重", "hygiene", "cleanup"],
                  anchor: "leaf-mem-hygiene")
        ]
    }

    // MARK: 叶子 · 数据与备份 / config

    private static var leafData: [SettingsSearchEntry] {
        [
            .init(id: "leaf-data-import", title: "导入对话", subtitle: "数据与备份 › 导入", systemImage: "square.and.arrow.down",
                  tab: .data, keywords: ["chatgpt", "claude", "gemini", "导入", "import", "conversation"],
                  anchor: "leaf-data-import"),
            .init(id: "leaf-data-backfill", title: "补原图", subtitle: "数据与备份 › 导入", systemImage: "photo.badge.arrow.down",
                  tab: .data, keywords: ["图片", "原图", "补图", "占位", "claude", "chatgpt", "backfill", "image"],
                  anchor: "leaf-data-backfill"),
            .init(id: "leaf-data-exportfloor", title: "导出本楼层对话", subtitle: "数据与备份 › 导出对话数据", systemImage: "square.and.arrow.up",
                  tab: .data, keywords: ["导出", "楼层", "export"],
                  anchor: "leaf-data-exportfloor"),
            .init(id: "leaf-data-exportall", title: "导出全部对话", subtitle: "数据与备份 › 导出对话数据", systemImage: "square.and.arrow.up.on.square",
                  tab: .data, keywords: ["导出", "全部", "export", "all"],
                  anchor: "leaf-data-exportall"),
            .init(id: "leaf-data-backup", title: "导出全量备份", subtitle: "数据与备份 › 全量备份", systemImage: "externaldrive.badge.timemachine",
                  tab: .data, keywords: ["备份", "mpb", "backup"],
                  anchor: "leaf-data-backup"),
            .init(id: "leaf-data-restore", title: "从备份恢复", subtitle: "数据与备份 › 全量备份", systemImage: "arrow.uturn.backward.circle",
                  tab: .data, keywords: ["恢复", "还原", "restore"],
                  anchor: "leaf-data-restore"),
            .init(id: "leaf-data-autobackup", title: "自动备份", subtitle: "数据与备份 › 全量备份", systemImage: "clock.arrow.2.circlepath",
                  tab: .data, keywords: ["自动", "定时", "auto backup"],
                  anchor: "leaf-data-autobackup"),
            .init(id: "leaf-data-history", title: "导入历史", subtitle: "数据与备份 › 导入历史", systemImage: "clock.badge.checkmark",
                  tab: .data, keywords: ["历史", "记录", "import history"],
                  anchor: "leaf-data-history"),
            .init(id: "leaf-data-sync", title: "同步", subtitle: "数据与备份 › 同步", systemImage: "arrow.triangle.2.circlepath",
                  tab: .data, keywords: ["icloud", "同步", "多设备", "sync"],
                  anchor: "leaf-data-sync"),
            .init(id: "leaf-data-timemachine", title: "⏰ 时间机器", subtitle: "数据与备份 › 时间机器", systemImage: "clock.arrow.circlepath",
                  tab: .data, keywords: ["时间机器", "快照", "回溯", "time machine", "snapshot"],
                  anchor: "leaf-data-timemachine"),
            .init(id: "leaf-data-storage", title: "存储", subtitle: "数据与备份 › 存储", systemImage: "internaldrive",
                  tab: .data, keywords: ["缓存", "占用", "清理", "storage", "cache"],
                  anchor: "leaf-data-storage"),
            .init(id: "leaf-data-searchindex", title: "搜索索引", subtitle: "数据与备份 › 存储", systemImage: "text.magnifyingglass",
                  tab: .data, keywords: ["全文搜索", "索引", "重建", "search index", "rebuild", "fts"],
                  anchor: "leaf-data-searchindex"),
            .init(id: "leaf-data-cache", title: "清理系统缓存", subtitle: "数据与备份 › 存储", systemImage: "trash",
                  tab: .data, keywords: ["清缓存", "释放", "clean", "cache"],
                  anchor: "leaf-data-cache"),
            .init(id: "leaf-data-danger", title: "开发（危险操作）", subtitle: "数据与备份 › 开发", systemImage: "exclamationmark.triangle",
                  tab: .data, keywords: ["清空", "危险", "danger", "wipe"],
                  anchor: "leaf-data-danger"),
            .init(id: "leaf-config-export", title: "导出全部设置", subtitle: "config › 操作", systemImage: "square.and.arrow.up",
                  tab: .config, keywords: ["设置导出", "配置", "export", "settings"]),
            .init(id: "leaf-config-import", title: "从文件导入", subtitle: "config › 操作", systemImage: "square.and.arrow.down",
                  tab: .config, keywords: ["设置导入", "配置", "import", "settings"])
        ]
    }

    // MARK: 叶子 · Claude Code / Codex / Agent / 终端 / MCP

    private static var myComputerPage: String { SettingsView.SettingsTab.myComputer.rawValue }

    /// 配对那一行在两端的界面原文不同：Mac「配对手机」（出二维码）/ iOS「扫码配对」
    private static var pairLeafTitle: String {
        #if os(macOS)
        "配对手机"
        #else
        "扫码配对"
        #endif
    }

    private static var leafDevTools: [SettingsSearchEntry] {
        [
            // hub / 依赖检查 / LAN / Tailscale 四行 #046 搬进「让手机连这台 Mac」页（Mac 独有那几节），iOS 页上不存在 → 无锚点
            .init(id: "leaf-cc-hub", title: "启动 CC 桥接", subtitle: "\(myComputerPage) › Hub 服务", systemImage: "server.rack",
                  tab: .myComputer, keywords: ["hub", "桥接", "服务", "bridge", "start"]),
            .init(id: "leaf-cc-deps", title: "依赖检查", subtitle: "\(myComputerPage) › 依赖检查", systemImage: "checkmark.seal",
                  tab: .myComputer, keywords: ["依赖", "检查", "tmux", "python3", "dependency", "check"]),
            .init(id: "leaf-cc-lan", title: "局域网直连（LAN）", subtitle: "\(myComputerPage) › 连接", systemImage: "wifi",
                  tab: .myComputer, keywords: ["局域网", "lan", "直连", "network"]),
            .init(id: "leaf-cc-tailscale", title: "Tailscale（远程 / 加密）", subtitle: "\(myComputerPage) › 连接", systemImage: "lock.icloud",
                  tab: .myComputer, keywords: ["tailscale", "远程", "vpn", "remote"]),
            .init(id: "leaf-mycomputer-pair", title: pairLeafTitle, subtitle: "\(myComputerPage) › 配对", systemImage: "qrcode",
                  tab: .myComputer, keywords: ["配对", "扫码", "二维码", "手机", "pairing", "qr"]),
            .init(id: "leaf-mycomputer-workdir", title: "Agent 干活的目录", subtitle: "\(myComputerPage) › Agent 干活的目录",
                  systemImage: "folder", tab: .myComputer, keywords: ["工作目录", "干活目录", "项目", "文件夹", "workdir", "folder", "directory"]),
            .init(id: "leaf-cc-pushcontent", title: "推送内容", subtitle: "Claude Code › 推送通知", systemImage: "bell.badge",
                  tab: .claudeCode, keywords: ["推送", "通知", "预览", "push", "notification"],
                  anchor: "leaf-cc-pushcontent"),
            .init(id: "leaf-cc-nudge", title: "让 AI 主动找我", subtitle: "Claude Code › 主动找我", systemImage: "bell.and.waves.left.and.right",
                  tab: .claudeCode, keywords: ["主动", "打扰", "nudge", "proactive"],
                  anchor: "leaf-cc-nudge"),
            .init(id: "leaf-cc-quiet", title: "休眠时段", subtitle: "Claude Code › 主动找我", systemImage: "moon.zzz",
                  tab: .claudeCode, keywords: ["免打扰", "休眠", "quiet", "dnd"],
                  anchor: "leaf-cc-quiet"),
            .init(id: "leaf-cc-stream", title: "新会话不带终端", subtitle: "Claude Code › 会话传输", systemImage: "rectangle.dashed",
                  tab: .claudeCode, keywords: ["终端", "stream", "无终端", "传输", "headless"],
                  anchor: "leaf-cc-stream"),
            .init(id: "leaf-cc-thinking", title: "显示思考过程", subtitle: "Claude Code › 思考与存档", systemImage: "brain.head.profile",
                  tab: .claudeCode, keywords: ["思考", "thinking", "reasoning", "链"],
                  anchor: "leaf-cc-thinking"),
            // 保留时长的 Picker 只在 macOS 分支（CCSettingsView.swift:525 `#if os(macOS)`），iOS 上没这行 → 不给锚点
            .init(id: "leaf-cc-retention", title: "对话保留时长", subtitle: "Claude Code › 思考与存档", systemImage: "calendar.badge.clock",
                  tab: .claudeCode, keywords: ["保留", "存档", "retention", "archive"]),
            .init(id: "leaf-cc-pocket", title: "允许 CC 遥控内置浏览器", subtitle: "Claude Code › 遥控浏览器", systemImage: "safari",
                  tab: .claudeCode, keywords: ["浏览器", "遥控", "browser", "pocket"],
                  anchor: "leaf-cc-pocket"),
            .init(id: "leaf-codex-connect", title: "连接", subtitle: "Codex › 连接", systemImage: "link",
                  tab: .codex, keywords: ["扫码", "配对", "connect", "pairing"]),
            .init(id: "leaf-agent-enable", title: "启用自主任务", subtitle: "Agent › 自主任务", systemImage: "ri-robot-2",
                  tab: .agent, keywords: ["自主", "自动", "autonomy", "task"]),
            .init(id: "leaf-agent-coread", title: "共读批注", subtitle: "Agent › 共读批注", systemImage: "book.and.wrench",
                  tab: .agent, keywords: ["共读", "批注", "coread", "annotate"]),
            .init(id: "leaf-agent-budget", title: "预算", subtitle: "Agent › 预算", systemImage: "dollarsign.circle",
                  tab: .agent, keywords: ["每日预算", "上限", "暂停", "budget", "limit"]),
            .init(id: "leaf-agent-activity", title: "最近活动", subtitle: "Agent › 最近活动", systemImage: "list.bullet.clipboard",
                  tab: .agent, keywords: ["日志", "活动", "activity", "log"]),
            .init(id: "leaf-terminal-layout", title: "按键布局", subtitle: "终端 › 按键布局", systemImage: "keyboard",
                  tab: .terminal, keywords: ["快捷键", "按键", "工具条", "主行", "抽屉", "拖动", "key", "keyboard", "layout", "toolbar"]),
            .init(id: "leaf-terminal-drawer", title: "抽屉", subtitle: "终端 › 抽屉", systemImage: "tray",
                  tab: .terminal, keywords: ["抽屉", "行数", "展开方式", "叠加", "轮换", "drawer", "stack", "cycle"]),
            .init(id: "leaf-terminal-custom", title: "自定义键", subtitle: "终端 › 自定义键", systemImage: "plus.rectangle.on.rectangle",
                  tab: .terminal, keywords: ["加键", "自定义", "宏", "序列", "组合键", "custom", "macro", "sequence"]),
            .init(id: "leaf-terminal-reset", title: "恢复默认布局", subtitle: "终端 › 恢复默认", systemImage: "arrow.counterclockwise",
                  tab: .terminal, keywords: ["恢复", "重置", "reset", "default"]),
            .init(id: "leaf-mcp-master", title: "启用工具调用总开关", subtitle: "MCP › 工具", systemImage: "wrench.and.screwdriver",
                  tab: .mcp, keywords: ["工具", "总开关", "tool", "master"]),
            .init(id: "leaf-mcp-transport", title: "连接方式", subtitle: "MCP › 连接器", systemImage: "cable.connector",
                  tab: .mcp, keywords: ["stdio", "sse", "http", "transport"]),
            .init(id: "leaf-mcp-json", title: "MCP JSON 配置", subtitle: "MCP › 连接器", systemImage: "curlybraces",
                  tab: .mcp, keywords: ["json", "配置", "config", "mcp"])
        ]
    }

    // MARK: 叶子 · 模块（贴纸/健康/交易/读书/单词/群聊/右栏）

    private static var leafModules: [SettingsSearchEntry] {
        var entries: [SettingsSearchEntry] = [
            .init(id: "leaf-sticker-library", title: "贴纸库", subtitle: "贴纸 › 贴纸库", systemImage: "square.grid.3x3",
                  tab: .sticker, keywords: ["贴纸", "资产", "占用", "sticker", "library"]),
            .init(id: "leaf-sticker-data", title: "贴纸数据", subtitle: "贴纸 › 贴纸数据", systemImage: "shippingbox",
                  tab: .sticker, keywords: ["导入贴纸包", "导出贴纸包", "sticker pack", "export"]),
            .init(id: "leaf-sticker-brush", title: "画笔", subtitle: "贴纸 › 画笔", systemImage: "paintbrush.pointed",
                  tab: .sticker, keywords: ["画画", "笔刷", "水彩", "钢笔", "颜色", "纸", "brush", "watercolor", "pen", "color"]),
            .init(id: "leaf-sticker-note", title: "便利贴", subtitle: "贴纸 › 便利贴", systemImage: "note.text",
                  tab: .sticker, keywords: ["便签", "便利贴", "字体", "手写", "note", "sticky", "font"]),
            .init(id: "leaf-health-connect", title: "连接", subtitle: "健康 › 连接", systemImage: "heart.circle",
                  tab: .health, keywords: ["苹果健康", "授权", "healthkit", "authorize"]),
            .init(id: "leaf-health-today", title: "今日快照", subtitle: "健康 › 今日快照", systemImage: "figure.walk",
                  tab: .health, keywords: ["步数", "睡眠", "心率", "锻炼", "steps", "sleep", "heart rate"]),
            .init(id: "leaf-health-unit", title: "体重单位", subtitle: "健康 › 单位", systemImage: "scalemass",
                  tab: .health, keywords: ["公斤", "磅", "kg", "lb", "unit", "weight"]),
            .init(id: "leaf-health-visible", title: "AI 会看到", subtitle: "健康 › AI 会看到", systemImage: "eye",
                  tab: .health, keywords: ["可见", "注入", "visible", "ai"]),
            .init(id: "leaf-health-intimacy", title: "显示亲密卡", subtitle: "健康 › 亲密", systemImage: "heart",
                  tab: .health, keywords: ["亲密", "intimacy"]),
            .init(id: "leaf-health-macro", title: "怎么用", subtitle: "健康 › 怎么用", systemImage: "text.badge.plus",
                  tab: .health, keywords: ["宏", "占位符", "macro", "health"]),
            .init(id: "leaf-calendar-look", title: "页面样子", subtitle: "日历 › 月历", systemImage: "rectangle.on.rectangle",
                  tab: .calendar, keywords: ["纸", "iOS", "样子", "外观", "look", "paper", "ios"]),
            .init(id: "leaf-calendar-style", title: "月历样子", subtitle: "日历 › 月历", systemImage: "square.grid.3x3",
                  tab: .calendar, keywords: ["铅笔纸", "星孔卡片", "外卡颜色", "小点", "涂深", "pencil", "card"]),
            .init(id: "leaf-calendar-privacy", title: "能看到我的日记", subtitle: "日历 › 日记与纪念日", systemImage: "eye",
                  tab: .calendar, keywords: ["日记", "隐私", "可见", "注入", "纪念日", "journal", "privacy", "ai"]),
            .init(id: "leaf-calendar-rebuild", title: "重新统计聊天", subtitle: "日历 › 统计", systemImage: "arrow.clockwise",
                  tab: .calendar, keywords: ["统计", "重建", "热力图", "rebuild", "stats"]),
        ]
        entries += [
            .init(id: "leaf-reading-model", title: "当前读书模型", subtitle: "书房 › AI 读书", systemImage: "book",
                  tab: .reading, keywords: ["读书", "模型", "reading", "model"]),
            .init(id: "leaf-vocab-order", title: "出词顺序", subtitle: "单词 › 出词顺序", systemImage: "shuffle",
                  tab: .vocab, keywords: ["随机", "顺序", "order", "shuffle"],
                  anchor: "leaf-vocab-order"),
            .init(id: "leaf-vocab-review", title: "复习", subtitle: "单词 › 复习", systemImage: "arrow.triangle.2.circlepath",
                  tab: .vocab, keywords: ["复习", "sm2", "review"],
                  anchor: "leaf-vocab-review"),
            .init(id: "leaf-vocab-newquota", title: "每日新卡", subtitle: "单词 › 复习", systemImage: "plus.rectangle.on.folder",
                  tab: .vocab, keywords: ["新卡", "配额", "daily new"],
                  anchor: "leaf-vocab-newquota"),
            .init(id: "leaf-vocab-cap", title: "每日复习上限", subtitle: "单词 › 复习", systemImage: "gauge.with.dots.needle.bottom.50percent",
                  tab: .vocab, keywords: ["上限", "复习量", "daily cap"],
                  anchor: "leaf-vocab-cap"),
            .init(id: "leaf-vocab-collect", title: "划词收词进复习", subtitle: "单词 › 复习", systemImage: "hand.tap",
                  tab: .vocab, keywords: ["划词", "收词", "collect", "highlight"],
                  anchor: "leaf-vocab-collect"),
            .init(id: "leaf-vocab-template", title: "模板", subtitle: "单词 › 模板", systemImage: "doc.plaintext",
                  tab: .vocab, keywords: ["模板", "占位符", "template", "placeholder"],
                  anchor: "leaf-vocab-template"),
            .init(id: "leaf-groupchat-enable", title: "群聊（中庭）", subtitle: "群聊", systemImage: "person.2",
                  tab: .groupChat, keywords: ["中庭", "群聊", "agora", "group"]),
            .init(id: "leaf-groupchat-mode", title: "发言模式", subtitle: "群聊", systemImage: "bubble.left.and.text.bubble.right",
                  tab: .groupChat, keywords: ["发言", "轮流", "speech mode"]),
            .init(id: "leaf-groupchat-pace", title: "AI 发言节奏", subtitle: "群聊", systemImage: "metronome",
                  tab: .groupChat, keywords: ["节奏", "间隔", "pace", "interval"]),
            .init(id: "leaf-rightpanel-style", title: "桌面样式", subtitle: "右栏 › 桌面样式", systemImage: "square.grid.2x2",
                  tab: .rightPanel, keywords: ["手机主屏", "自由摆放", "iOS 26", "经典", "针脚点阵", "desktop", "style"]),
            .init(id: "leaf-rightpanel-switcher", title: "切换应用", subtitle: "右栏 › 切换应用", systemImage: "rectangle.righthalf.inset.filled",
                  tab: .rightPanel, keywords: ["竖条", "弧线", "后台", "回桌面", "切换", "app switcher", "strip", "arc"]),
            .init(id: "leaf-rightpanel-tools", title: "工具管理", subtitle: "右栏 › 工具管理", systemImage: "slider.horizontal.3",
                  tab: .rightPanel, keywords: ["工具", "小组件", "管理", "tool", "widget"])
        ]
        return entries
    }

    // MARK: 叶子 · 文件库 / 沙箱 / 正则 / 开发调试

    private static var leafStorage: [SettingsSearchEntry] {
        var entries: [SettingsSearchEntry] = [
            .init(id: "leaf-file-enable", title: "启用文件库", subtitle: "文件库", systemImage: "folder",
                  tab: .fileLibrary, keywords: ["文件库", "档位", "file library"],
                  anchor: "leaf-file-enable"),
            .init(id: "leaf-file-ccmemory", title: "同步 CC 的记忆", subtitle: "文件库", systemImage: "arrow.triangle.2.circlepath",
                  tab: .fileLibrary, keywords: ["CC", "Claude Code", "同步", "memory", "sync"],
                  anchor: "leaf-file-ccmemory"),
            .init(id: "leaf-file-compress", title: "聊天图片压缩入库", subtitle: "文件库", systemImage: "photo.badge.arrow.down",
                  tab: .fileLibrary, keywords: ["图片", "压缩", "入库", "compress", "image"],
                  anchor: "leaf-file-compress"),
            .init(id: "leaf-file-location", title: "本机文件位置", subtitle: "文件库", systemImage: "internaldrive",
                  tab: .fileLibrary, keywords: ["位置", "路径", "location", "path"],
                  anchor: "leaf-file-location"),
            .init(id: "leaf-file-icloud", title: "iCloud 同步（实验）", subtitle: "文件库", systemImage: "icloud",
                  tab: .fileLibrary, keywords: ["icloud", "同步", "sync"],
                  anchor: "leaf-file-icloud"),
            .init(id: "leaf-file-injecttemplate", title: "注入提示词模板", subtitle: "文件库", systemImage: "text.quote",
                  tab: .fileLibrary, keywords: ["注入", "模板", "prompt", "template"],
                  anchor: "leaf-file-injecttemplate"),
            .init(id: "leaf-sandbox-open-terminal", title: "打开终端", subtitle: "手机里的小电脑", systemImage: "apple.terminal",
                  tab: .sandbox, keywords: ["终端", "小电脑终端", "离线终端", "shell", "linux", "ish", "terminal"]),
            .init(id: "leaf-sandbox-status", title: "状态", subtitle: "手机里的小电脑 › 状态", systemImage: "info.circle",
                  tab: .sandbox, keywords: ["沙箱状态", "小电脑状态", "rootfs", "ish", "status", "sandbox"]),
            .init(id: "leaf-sandbox-reset", title: "重置小电脑", subtitle: "手机里的小电脑", systemImage: "arrow.counterclockwise",
                  tab: .sandbox, keywords: ["重置", "清空", "重置沙箱", "沙箱", "reset", "sandbox"]),
            .init(id: "leaf-regex-list", title: "脚本列表", subtitle: "正则脚本 › 脚本列表", systemImage: "list.bullet.rectangle",
                  tab: .regex, keywords: ["正则", "脚本", "替换", "regex", "script"]),
            .init(id: "leaf-debug-tuner", title: "弹泡调音台", subtitle: "开发调试", systemImage: "slider.vertical.3",
                  tab: .debug, keywords: ["弹泡", "调音", "动画", "tuner", "bubble pop"]),
            .init(id: "leaf-debug-inputfont", title: "输入框字号", subtitle: "开发调试", systemImage: "textformat.size",
                  tab: .debug, keywords: ["字号", "输入框", "input", "font size"]),
            .init(id: "leaf-debug-feedback", title: "摇一摇记录反馈", subtitle: "设置 › 反馈", systemImage: "exclamationmark.bubble",
                  tab: .debug, keywords: ["反馈", "摇一摇", "bug", "feedback", "shake"]),
            .init(id: "leaf-about-acknowledgements", title: "开源致谢", subtitle: "设置 › 关于记忆花园", systemImage: "doc.text",
                  tab: .about, keywords: ["致谢", "开源", "许可", "协议", "第三方", "版权",
                                          "acknowledgements", "license", "open source", "credits", "agpl"])
        ]
        #if os(iOS)
        // 关于 › 报告问题只在 iOS 关于页（mac 关于页不带，反馈走开发调试页）
        entries.append(.init(id: "leaf-about-report", title: "报告问题", subtitle: "设置 › 关于记忆花园", systemImage: "exclamationmark.bubble",
                             tab: .about, keywords: ["报告", "问题", "反馈", "bug", "report", "issue", "feedback"]))
        entries.append(.init(id: "leaf-tts-incoming", title: "允许 CC 原生来电", subtitle: "语音 › 来电", systemImage: "phone.arrow.down.left",
                             tab: .tts, keywords: ["电话", "VoIP", "来电", "接听"], anchor: "leaf-tts-incoming"))
        // 文件库 › 编辑器键盘浮条只在 iOS 分支（FileLibrarySettingsTab 的 #if os(iOS)）
        entries.append(.init(id: "leaf-file-editorbar", title: "编辑器键盘浮条", subtitle: "文件库", systemImage: "keyboard",
                             tab: .fileLibrary, keywords: ["编辑器", "浮条", "键盘", "格式条", "玻璃", "键帽", "editor", "keyboard", "toolbar", "glass", "keycap"],
                             anchor: "leaf-file-editorbar"))
        // 外观 › 音乐（全局音乐胶囊）只在 iOS 分支（AppearanceSettingsTab 的 #if os(iOS)）
        entries.append(.init(id: "leaf-appear-music", title: "全局音乐胶囊", subtitle: "外观 › 音乐", systemImage: "music.note",
                             tab: .appearance, keywords: ["音乐", "胶囊", "播放器", "正在播放", "黑胶", "歌", "music", "player", "now playing", "capsule"],
                             anchor: "leaf-appear-music"))
        #endif
        #if os(macOS)
        // 外观 › 窗口（窗口玻璃开关 + 色偏）只在 mac 分支（AppearanceSettingsTab 的 #if os(macOS)）
        entries.append(.init(id: "leaf-appear-window", title: "窗口玻璃", subtitle: "外观 › 窗口", systemImage: "rectangle.on.rectangle",
                             tab: .appearance, keywords: ["玻璃", "透明", "毛玻璃", "色偏", "桌面", "glass", "translucent", "vibrancy", "tint"],
                             anchor: "leaf-appear-window"))
        entries.append(.init(id: "leaf-debug-hangs", title: "卡顿记录", subtitle: "开发调试 › 卡顿记录",
                             systemImage: "gauge.with.dots.needle.33percent", tab: .debug,
                             keywords: ["卡顿", "转菊花", "卡死", "性能", "探针", "hang", "beachball", "performance", "sample"]))
        entries.append(.init(id: "leaf-debug-shelltuner", title: "外观控制台", subtitle: "开发调试 › 外观控制台",
                             systemImage: "slider.horizontal.3", tab: .debug,
                             keywords: ["控制台", "正文宽度", "参数台", "间距", "padding", "圆角", "标题栏", "dock", "微调", "tuner"]))
        #endif
        #if DEBUG
        #if os(iOS)
        entries.append(.init(id: "leaf-debug-airprobe", title: "翻页探针", subtitle: "开发调试", systemImage: "waveform.path",
                             tab: .debug, keywords: ["翻页", "滚动", "卡顿", "性能", "Air", "perf", "probe"],
                             anchor: "leaf-debug-airprobe"))
        #endif
        // release 里这个 Toggle 不存在（DebugSettingsTab.swift:13 被 #if DEBUG 包），注册表同步
        entries.append(
            // 对齐 DebugOrb 自己的瓢虫身份
            .init(id: "leaf-debug-orb", title: "悬浮调试球", subtitle: "开发调试", systemImage: "ladybug",
                  tab: .debug, keywords: ["调试球", "悬浮", "orb", "debug"])
        )
        #endif
        // 话题盒只进粟粟的 Debug 包（#096）；FileLibrarySettingsTab 那张卡同样包着
        return entries
    }

    // MARK: 叶子 · 权限（复用 PermissionDomain 这份现成的半注册表）

    private static var leafPermissions: [SettingsSearchEntry] {
        // 加密值列表（plan-secure-ask §5）：权限页底部一个 Section，不是权限域
        let secrets = SettingsSearchEntry(
            id: "leaf-perm-secrets", title: "加密值", subtitle: "权限 › 加密值", systemImage: "lock",
            tab: .permissions, keywords: ["加密值", "密码", "secret", "钥匙串", "keychain"], anchor: "leaf-perm-secrets"
        )
        let domains: [SettingsSearchEntry] = PermissionDomain.allCases.map { domain in
            .init(
                id: "leaf-perm-\(domain.rawValue)",
                title: domain.displayName,
                subtitle: "权限 › \(permissionSectionTitle(domain))",
                systemImage: "lock.shield",
                tab: .permissions,
                // summary 进 keywords：搜「步数」「剪贴板」这种词能命中对应域
                keywords: [domain.summary, domain.rawValue],
                anchor: hasPermissionRowOnPage(domain) ? "leaf-perm-\(domain.rawValue)" : nil
            )
        }
        return [secrets] + domains
    }

    /// 健康五个子域的行在 `HealthPermissionSubpage`（权限页上只有一条「健康」入口），
    /// 主页面上没有它们的行 → 不给锚点，照旧只跳页。
    private static func hasPermissionRowOnPage(_ domain: PermissionDomain) -> Bool {
        switch domain {
        case .healthApple, .healthWeight, .healthMeds, .healthCycle, .healthIntimacy:
            return false
        default:
            return true
        }
    }

    /// 域 → 权限页 Section 名（`PermissionsSettingsTab.swift:103/121/151` 三个 header）
    private static func permissionSectionTitle(_ domain: PermissionDomain) -> String {
        switch domain {
        case .healthApple, .healthWeight, .healthMeds, .healthCycle, .healthIntimacy,
             .memory, .images, .fileLibrary:
            return "AI 能看什么"
        #if os(macOS)
        case .codingSessions:
            return "AI 能看什么"
        #endif
        case .toolsMaster, .webSearch, .voiceProactive, .pocket,
             .calendar, .reminders, .clipboard, .shell, .twitter:
            return "AI 能做什么"
        case .notifications:
            return "AI 自主行为"
        }
    }

    /// 根列表底部两行占位（关于坨剩下的）+ 折叠组里四个占位：看得见打不开，收进表但标「敬请期待」（点了只 Toast）
    static var placeholderEntries: [SettingsSearchEntry] {
        [
            .init(id: "todo-privacy", title: "隐私政策", subtitle: "设置 · 敬请期待", systemImage: "hand.raised",
                  tab: nil, keywords: ["隐私", "政策", "privacy", "policy"]),
            .init(id: "todo-terms", title: "服务条款", subtitle: "设置 · 敬请期待", systemImage: "doc.text",
                  tab: nil, keywords: ["条款", "协议", "terms", "license"]),
            .init(id: "todo-imagegen", title: "生图", subtitle: "AI 连接与拓展 · 敬请期待", systemImage: "photo.on.rectangle",
                  tab: nil, keywords: ["画图", "文生图", "image", "draw", "generate"]),
            .init(id: "todo-skill", title: "Skill", subtitle: "AI 连接与拓展 · 敬请期待", systemImage: "puzzlepiece",
                  tab: nil, keywords: ["技能", "插件", "skill", "plugin"]),
            .init(id: "todo-storage", title: "储存", subtitle: "储存与文件 · 敬请期待", systemImage: "externaldrive",
                  tab: nil, keywords: ["磁盘", "容量", "storage", "disk"]),
            .init(id: "todo-mount", title: "挂载和共享文件夹", subtitle: "储存与文件 · 敬请期待", systemImage: "folder.badge.plus",
                  tab: nil, keywords: ["挂载", "共享", "文件夹", "mount", "share", "folder"])
        ]
    }
}
