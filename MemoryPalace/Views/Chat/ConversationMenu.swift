import Foundation

/// 对话菜单（11-16 合一，plan-chat-menus）：对话列表长按和聊天页 ⋯ 用同一份清单。
/// 清单长什么样在这里定（测试按 `State` 验），每一项做什么由调用方的 `Handlers` 给——两处的弹窗 / sheet 各挂各的。
/// 顶上图标排（带 quickLabel）粟粟定了不动：Rename · Copy · Pin · Star · Delete
enum ConversationMenu {
    enum Place: Equatable {
        case list
        /// 聊天页：多「在对话中查找」（Mac 没有对话内查找，canSearch = false），文章模式有分支时多「分支地图（N）」
        case chat(branchCount: Int, canSearch: Bool = true)
    }

    struct Choice: Equatable {
        let id: String
        let name: String
    }

    struct State {
        var isPinned = false
        var isFavorite = false
        var isBubble = false
        var memoryEnabled = true
        var folderId: String?
        var personaId: String?
        var folders: [Choice] = []
        /// 身份库空 = 不出「这个对话用的身份」
        var personas: [Choice] = []
        /// 记忆总开关关着：「现在写记忆」灰掉
        var memoryWriteEnabled = true
        /// 「重新记这个窗口」：nil = 不出（开关没开 / 写法不支持）；running = 正在跑，灰掉、行名是进度
        var rerecord: (title: String, running: Bool)?
        /// mainsession（plan-floor-main-thread）：没有重命名 / 置顶 / 删除 / 重新生成标题（清空用 /clear）
        var isMainSession = false
        /// 电脑上同步来的 session：没有「复制对话」（副本会变成普通对话，正文就能被备份、同步带走了）
        var isFolderSession = false
    }

    struct Handlers {
        var rename: () -> Void = {}
        var duplicate: () -> Void = {}
        var togglePin: () -> Void = {}
        var toggleFavorite: () -> Void = {}
        var delete: () -> Void = {}
        var search: () -> Void = {}
        var branchMap: () -> Void = {}
        var toggleDisplayMode: () -> Void = {}
        /// nil = 移出文件夹
        var moveToFolder: (String?) -> Void = { _ in }
        var toggleMemory: () -> Void = {}
        var openWindowNote: () -> Void = {}
        var windowSummary: () -> Void = {}
        var contextSummary: () -> Void = {}
        var writeMemoryNow: () -> Void = {}
        var rerecord: () -> Void = {}
        var regenerateTitle: () -> Void = {}
        var favoriteTag: () -> Void = {}
        /// nil = 跟随楼层
        var setPersona: (String?) -> Void = { _ in }
        var export: () -> Void = {}
    }

    /// `cc`：CC 对话才有的几项（缓存保暖 / 终端 / 连哪台电脑），排在「更多」最后
    static func specs(place: Place, state s: State, cc: [MenuActionSpec] = [], handlers h: Handlers) -> [MenuActionSpec] {
        var specs: [MenuActionSpec] = [
            MenuActionSpec(title: "重命名", systemImage: "pencil", quickLabel: "Rename", handler: h.rename),
            MenuActionSpec(title: "复制对话", systemImage: "doc.on.doc", quickLabel: "Copy", handler: h.duplicate),
            MenuActionSpec(title: s.isPinned ? "取消置顶" : "置顶对话", systemImage: s.isPinned ? "pin.slash" : "pin",
                           quickLabel: "Pin", handler: h.togglePin),
            MenuActionSpec(title: s.isFavorite ? "取消收藏" : "收藏整个对话", systemImage: s.isFavorite ? "star.slash" : "star",
                           quickLabel: "Star", handler: h.toggleFavorite),
            MenuActionSpec(title: "删除", systemImage: "trash", isDestructive: true, quickLabel: "Delete", handler: h.delete),
        ]
        if s.isMainSession { specs.removeAll { ["Rename", "Pin", "Delete"].contains($0.quickLabel ?? "") } }
        if s.isFolderSession { specs.removeAll { $0.quickLabel == "Copy" } }

        if case let .chat(branchCount, canSearch) = place {
            if canSearch {
                specs.append(MenuActionSpec(title: "在对话中查找", systemImage: "magnifyingglass", handler: h.search))
            }
            if !s.isBubble, branchCount > 0 {
                specs.append(MenuActionSpec(title: "分支地图（\(branchCount)）", systemImage: "arrow.triangle.branch", handler: h.branchMap))
            }
        }

        specs.append(MenuActionSpec(title: s.isBubble ? "换成文章" : "换成气泡",
                                    systemImage: s.isBubble ? "doc.text" : "bubble.left.and.bubble.right",
                                    handler: h.toggleDisplayMode))

        if !s.folders.isEmpty || s.folderId != nil {
            var folders = s.folders.map { f in
                MenuActionSpec(title: f.name, systemImage: s.folderId == f.id ? "checkmark" : "folder") { h.moveToFolder(f.id) }
            }
            if s.folderId != nil {
                folders.append(MenuActionSpec(title: "移出文件夹", systemImage: "folder.badge.minus") { h.moveToFolder(nil) })
            }
            specs.append(MenuActionSpec(title: "移到文件夹", systemImage: "folder", children: folders) {})
        }

        var memory = [
            MenuActionSpec(title: s.memoryEnabled ? "关闭记忆参与" : "开启记忆参与",
                           systemImage: s.memoryEnabled ? "brain" : "brain.head.profile", handler: h.toggleMemory),
            MenuActionSpec(title: "这个窗口带什么", systemImage: "checklist", handler: h.openWindowNote),
            MenuActionSpec(title: "窗口总结", systemImage: "rectangle.stack", handler: h.windowSummary),
            MenuActionSpec(title: "上下文摘要", systemImage: "text.append", handler: h.contextSummary),
        ]
        // 「现在写」「重新记」只在聊天页：都是对打开着的那条做的（写的是已加载的消息、确认框挂在聊天页上），
        // 列表里长按的不一定是打开的那条（astra 审 11-16：没加载完就写会漏 A2 压缩；确认框可能没宿主）
        if case .chat = place {
            memory.append(MenuActionSpec(title: "现在写记忆", systemImage: "square.and.pencil", isDisabled: !s.memoryWriteEnabled,
                                         handler: h.writeMemoryNow))
            if let rerecord = s.rerecord {
                memory.append(MenuActionSpec(title: rerecord.title, systemImage: "arrow.counterclockwise",
                                             isDisabled: rerecord.running, handler: h.rerecord))
            }
        }
        specs.append(MenuActionSpec(title: "记忆", systemImage: "brain", children: memory) {})

        var more = [
            MenuActionSpec(title: "重新生成标题", systemImage: "sparkles", handler: h.regenerateTitle),
            MenuActionSpec(title: "收藏到标签…", systemImage: "tag", handler: h.favoriteTag),
        ]
        if s.isMainSession { more.removeFirst() }
        if !s.personas.isEmpty {
            let following = (s.personaId ?? "").isEmpty
            let personas = [MenuActionSpec(title: "跟随楼层", systemImage: following ? "checkmark" : "person.crop.circle") { h.setPersona(nil) }]
                + s.personas.map { p in
                    MenuActionSpec(title: p.name.isEmpty ? "（没名字）" : p.name,
                                   systemImage: s.personaId == p.id ? "checkmark" : "person") { h.setPersona(p.id) }
                }
            more.append(MenuActionSpec(title: "身份", systemImage: "person.crop.circle", children: personas) {})
        }
        more.append(MenuActionSpec(title: "导出为 Markdown", systemImage: "square.and.arrow.up", handler: h.export))
        more += cc
        specs.append(MenuActionSpec(title: "更多", systemImage: "ellipsis.circle", children: more) {})
        return specs
    }
}

// MARK: - CC 对话才有的几项（列表长按原有「缓存保暖」、聊天页原有「终端」「连哪台电脑」，合一后两处都有）

extension ConversationMenu {
    /// 这条对话不是 CC / 那台用不了 → 对应项不出；`save` 由调用方给（列表和聊天页的 modelContext 各用各的）
    @MainActor
    static func ccSpecs(_ conversation: Conversation, viewModel: ConversationViewModel,
                        isHubConversation: Bool, save: @escaping () -> Void) -> [MenuActionSpec] {
        var specs: [MenuActionSpec] = []
        // 缓存保暖 / 带不带终端：按 tmux session 设（不是按对话），共享同一 session 的对话共用一份，标题带上 session 名
        if let session = conversation.ccBridgeSessionName, !session.isEmpty,
           let hub = try? CCHubRegistry.shared.route(CCHubRegistry.hubId(of: conversation)).get() {
            let keepalive = CCBridgeWebSocketClient.keepalivePolicy(for: session, hub: hub)
            let keepaliveChoices: [(String, String, String)] = [("always", "🔥 常驻保暖", "flame"), ("auto", "⚙️ 自动", "gearshape"), ("never", "❄️ 不保暖", "snowflake")]
            specs.append(MenuActionSpec(
                title: "缓存保暖 · \(session)", systemImage: "flame",
                children: keepaliveChoices.map { policy, title, icon in
                    MenuActionSpec(title: title, systemImage: keepalive == policy ? "checkmark" : icon) {
                        CCBridgeWebSocketClient.setKeepalivePolicy(policy, for: session, hub: hub)
                    }
                }) {})
            // 切换后 hub 收掉旧进程按新传输重生（同一 claude 会话 resume，正在跑的一轮等跑完）
            let transport = CCBridgeWebSocketClient.transportPolicy(for: session, hub: hub)
            let transportChoices: [(String, String, String)] = [("", "跟随全局设置", "gearshape"), ("tmux", "带终端", "terminal"), ("stream", "不带终端（逐字流式）", "text.bubble")]
            specs.append(MenuActionSpec(
                title: "终端 · \(session)", systemImage: "terminal",
                children: transportChoices.map { policy, title, icon in
                    MenuActionSpec(title: title, systemImage: transport == policy ? "checkmark" : icon) {
                        CCBridgeWebSocketClient.setTransportPolicy(policy, for: session, hub: hub)
                    }
                }) {})
        }
        // 连哪台电脑（plan-multi-hub B4.4）：≥2 台 / 那台用不了才出，跟输入框上方「换一台」同一份选择
        if isHubConversation, CCHubRegistry.shared.hubs.count >= 2 || CCHubTitle.blocker(for: conversation) != nil {
            let current = CCHubRegistry.hubId(of: conversation)
            specs.append(MenuActionSpec(
                title: "连哪台电脑 · \(CCHubTitle.name(of: current) ?? "那台电脑")", systemImage: "desktopcomputer",
                children: CCHubRegistry.shared.hubs.map { hub in
                    MenuActionSpec(title: hub.id == current ? "\(hub.name)（现在连的）" : hub.name,
                                   systemImage: hub.id == current ? "checkmark" : "desktopcomputer",
                                   isDisabled: hub.id == current) {
                        let notice = CCHubTitle.rebind(conversation, to: hub.id, unfinished: viewModel.ccHasUnfinished(for: conversation))
                        save()
                        if let notice { ToastCenter.shared.show(notice) }
                    }
                }) {})
        }
        return specs
    }
}
