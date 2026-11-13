import XCTest
@testable import 记忆花园

/// 设置搜索（plan-settings-search §六）：打分五档 / token AND / 注册表 sanity。
final class SettingsSearchTests: XCTestCase {

    private func entry(
        id: String = "t",
        title: String,
        subtitle: String = "",
        keywords: [String] = []
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            id: id,
            title: title,
            subtitle: subtitle,
            systemImage: "gearshape",
            tab: .general,
            keywords: keywords
        )
    }

    #if os(macOS)
    func testMacSidebarCoversVisiblePagesExactlyOnce() {
        let tabs = MacSettingsSidebarGroup.all.flatMap(\.tabs)
        // .theme 在 A1 后不是 mac 的 tab（主题库降成外观页二级页），与 .sandbox 同处理；同 macTabs 口径（小芽 09-24 上 mac）
        // .terminal 只管键盘工具条，Mac 没有工具条（T43）
        let visible = SettingsView.SettingsTab.allCases.filter { $0 != .sandbox && $0 != .theme && $0 != .terminal }
        XCTAssertEqual(Set(tabs), Set(visible))
        XCTAssertEqual(tabs.count, Set(tabs).count)
        for tab in visible {
            XCTAssertFalse(tab.macSubtitle.isEmpty, "\(tab.rawValue) 缺页面说明")
        }
    }

    /// C1/C2/C3：世界书 / 正则不进常驻目录（只在搜索时出现）；原「模块」组改叫「子应用」，右栏不算子应用
    func testMacSidebarDirectoryLayout() {
        let listed = MacSettingsSidebarGroup.all.filter { !$0.searchOnly }
        let listedTabs = Set(listed.flatMap(\.tabs))
        XCTAssertFalse(listedTabs.contains(.worldBook))
        XCTAssertFalse(listedTabs.contains(.regex))
        XCTAssertEqual(Set(MacSettingsSidebarGroup.all.filter(\.searchOnly).flatMap(\.tabs)), [.worldBook, .regex])
        let subApps = listed.first { $0.title == "子应用" }?.tabs ?? []
        XCTAssertTrue(subApps.contains(.sticker))
        XCTAssertFalse(subApps.contains(.rightPanel))
        XCTAssertNil(listed.first { $0.title == "模块" })
    }
    #endif

    // MARK: 五档

    func testScoreTitleExact() {
        XCTAssertEqual(entry(title: "终端").matchScore(for: "终端"), 500)
    }

    func testScoreTitlePrefix() {
        XCTAssertEqual(entry(title: "终端工具条").matchScore(for: "终端"), 420)
    }

    func testScoreTitleContains() {
        XCTAssertEqual(entry(title: "重置终端").matchScore(for: "终端"), 320)
    }

    func testScoreSubtitleContains() {
        XCTAssertEqual(entry(title: "工具条按键", subtitle: "终端 › 工具条按键").matchScore(for: "终端"), 220)
    }

    func testScoreKeywordsOnly() {
        XCTAssertEqual(entry(title: "工具条按键", subtitle: "按键管理", keywords: ["keyboard", "terminal"]).matchScore(for: "keyboard"), 140)
    }

    // MARK: token AND

    func testTokenAndAllMustMatch() {
        let e = entry(title: "工具条按键", subtitle: "终端 › 工具条按键", keywords: ["keyboard"])
        XCTAssertNotNil(e.matchScore(for: "终端 按键"))
        XCTAssertNil(e.matchScore(for: "终端 贴纸"))
    }

    /// 中文输入法默认全角空格，也要算分隔
    func testTokenAndIdeographicSpace() {
        let e = entry(title: "工具条按键", subtitle: "终端 › 工具条按键")
        XCTAssertNotNil(e.matchScore(for: "终端\u{3000}按键"))
    }

    func testEmptyQueryReturnsNil() {
        XCTAssertNil(entry(title: "终端").matchScore(for: ""))
        XCTAssertNil(entry(title: "终端").matchScore(for: "   "))
    }

    func testCaseInsensitive() {
        XCTAssertEqual(entry(title: "Claude Code").matchScore(for: "claude code"), 500)
    }

    // MARK: filtered

    func testRetiredAvatarAndNicknameTogglesCannotBeSearchDestinations() {
        let retired = Set(["leaf-appear-avatar", "leaf-appear-nickname"])
        for query in ["显示头像", "显示昵称", "avatar", "nickname"] {
            XCTAssertFalse(SettingsSearchEntry.filtered(for: query).contains { retired.contains($0.id) }, query)
        }
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "时间戳").first?.id, "leaf-appear-timestamp")
    }

    func testFilteredEmptyQueryReturnsSuggested() {
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "  "), SettingsSearchEntry.suggested)
    }

    func testFilteredSortsByScoreDescending() {
        let scores = SettingsSearchEntry.filtered(for: "记忆").compactMap { $0.matchScore(for: "记忆") }
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    // MARK: 注册表 sanity

    func testEveryTabHasPageEntry() {
        let covered = Set(SettingsSearchEntry.pageEntries.compactMap(\.tab))
        for tab in SettingsView.SettingsTab.allCases {
            XCTAssertTrue(covered.contains(tab), "\(tab.rawValue) 缺页面级条目")
        }
        XCTAssertEqual(SettingsSearchEntry.pageEntries.count, SettingsView.SettingsTab.allCases.count)
    }

    func testPlaceholderCount() {
        // 关于坨原本四行全占位；「关于记忆花园」已落地、「检查更新」降级成版本行后剩 6 个
        XCTAssertEqual(SettingsSearchEntry.all.filter(\.isPlaceholder).count, 6)
    }

    func testNoEmptyTitleOrKeywords() {
        for e in SettingsSearchEntry.all {
            XCTAssertFalse(e.title.isEmpty, "\(e.id) title 为空")
            XCTAssertFalse(e.subtitle.isEmpty, "\(e.id) subtitle 为空")
            XCTAssertFalse(e.keywords.isEmpty, "\(e.id) keywords 为空")
        }
    }

    func testLeafEntriesAllJumpSomewhere() {
        for e in SettingsSearchEntry.leafEntries {
            XCTAssertNotNil(e.tab, "\(e.id) 叶子条目没有跳转目标")
        }
    }

    /// plan §六 GUI 走查的两条，先在注册表层锁住
    #if os(macOS)
    func testMacWorkspaceSearchRoutesToItsOwnPage() {
        for query in ["Dock 排列", "分隔线", "Code 入口", "Mac 工作区", "会话来源"] {
            XCTAssertEqual(SettingsSearchEntry.filtered(for: query).first?.tab, .macWorkspace, query)
        }
        XCTAssertNotNil(SettingsSearchEntry.iconByTab[.macWorkspace])
    }
    #endif

    func testKnownQueriesLandOnRightPage() {
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "思考").first?.tab, .claudeCode)
        #if PERSONAL_APPS
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "夜跑").first?.tab, .trading)
        #endif
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "正则").first?.tab, .regex)
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "每日复习上限").first?.tab, .vocab)
    }

    /// C4：pro / lite 两套根目录、mac 侧栏、页面标题都叫「模型和API」
    func testAPIPageNamedModelAndAPI() {
        XCTAssertEqual(SettingsView.SettingsTab.api.rawValue, "模型和API")
        let page = SettingsSearchEntry.pageEntries.first { $0.tab == .api }
        XCTAssertEqual(page?.title, "模型和API")
        for query in ["模型和API", "模型（API）", "API"] {
            XCTAssertEqual(SettingsSearchEntry.filtered(for: query).first?.tab, .api, query)
        }
        for e in SettingsSearchEntry.leafEntries where e.tab == .api {
            XCTAssertTrue(e.subtitle.hasPrefix("模型和API › "), "\(e.id) subtitle 还是旧叫法")
        }
    }

    /// C2：世界书 / 正则的条目跳卡库对应页签（tab 留着当兜底）
    func testWorldBookAndRegexRouteToCardLibrary() {
        let worldBook = SettingsSearchEntry.filtered(for: "世界书").first
        XCTAssertEqual(worldBook?.tab, .worldBook)
        XCTAssertEqual(worldBook?.cardLibraryTarget, RightPanelNavigator.cardLibraryWorldBookTabTargetId)
        let regex = SettingsSearchEntry.filtered(for: "正则").first
        XCTAssertEqual(regex?.cardLibraryTarget, RightPanelNavigator.cardLibraryRegexTabTargetId)
        for e in SettingsSearchEntry.all where e.tab == .worldBook || e.tab == .regex {
            XCTAssertNotNil(e.cardLibraryTarget, "\(e.id) 还指向设置里的旧页")
        }
        XCTAssertTrue(RightPanelNavigator.cardLibraryTabTargetIds.isSuperset(of: [
            RightPanelNavigator.cardLibrarySettingsTargetId,
            RightPanelNavigator.cardLibraryWorldBookTabTargetId,
            RightPanelNavigator.cardLibraryRegexTabTargetId,
        ]))
    }

    /// C5：审查里搜不到地方的几个词
    func testAuditQueriesLandOnRightPlace() {
        let favorite = SettingsSearchEntry.filtered(for: "收藏").first
        XCTAssertEqual(favorite?.id, "leaf-api-favorites")
        XCTAssertEqual(favorite?.tab, .api)

        for query in ["温度", "temperature"] {
            let hit = SettingsSearchEntry.filtered(for: query).first
            XCTAssertEqual(hit?.tab, .persona, query)
            XCTAssertEqual(hit?.id, "leaf-persona-temperature", query)
        }

        let card = SettingsSearchEntry.filtered(for: "角色卡").first
        XCTAssertEqual(card?.id, "leaf-cardlib-characters")
        XCTAssertEqual(card?.cardLibraryTarget, "tab:characters")

        let versions = SettingsSearchEntry.filtered(for: "版本历史").first
        XCTAssertEqual(versions?.tab, .fileLibrary)
        XCTAssertEqual(versions?.subtitle, "文件库")
        XCTAssertEqual(versions?.anchor, "leaf-file-versions", "落到文件库页的「记录版本」开关")
    }

    /// #093：工具抽屉在 Prompt 页，带锚点
    func testToolDrawerQueryLandsOnPromptPage() {
        for query in ["工具抽屉", "抽屉", "tools"] {
            let hit = SettingsSearchEntry.filtered(for: query).first
            XCTAssertEqual(hit?.tab, .persona, query)
            XCTAssertEqual(hit?.anchor, "leaf-persona-tool-drawer", query)
        }
    }

    /// #046 T3：配对 / 干活目录 / 局域网都落到「我的电脑」（Mac 上叫「让手机连这台 Mac」）
    func testMyComputerQueriesLandOnItsPage() {
        for query in ["配对", "我的电脑", "工作目录", "局域网直连", "依赖检查"] {
            XCTAssertEqual(SettingsSearchEntry.filtered(for: query).first?.tab, .myComputer, query)
        }
        XCTAssertNotNil(SettingsSearchEntry.iconByTab[.myComputer])
    }

    /// atrium P4-0：App 里有自己 ⚙ 的 9 个工具页，iOS 副标题写「X App …」、落点不变；mac 副标题原样
    func testToolSettingsSubtitlesNameTheApp() {
        let expected: [String: SettingsView.SettingsTab] = [
            "page-calendar": .calendar, "page-terminal": .terminal, "page-reading": .reading,
            "page-vocab": .vocab, "page-claudecode": .claudeCode, "page-codex": .codex,
            "page-mycomputer": .myComputer, "page-sandbox": .sandbox, "page-xiaoya": .xiaoya,
        ]
        let pages = Dictionary(uniqueKeysWithValues: SettingsSearchEntry.pageEntries.map { ($0.id, $0) })
        for (id, tab) in expected {
            let page = pages[id]
            XCTAssertEqual(page?.tab, tab, id)
            #if os(iOS)
            XCTAssertEqual(page?.subtitle.contains("App"), true, "\(id): \(page?.subtitle ?? "nil")")
            #else
            XCTAssertEqual(page?.subtitle.contains("App"), false, "\(id): \(page?.subtitle ?? "nil")")
            #endif
        }
        XCTAssertEqual(pages["page-mcp"]?.subtitle, "设置 › AI 连接与拓展", "MCP 不动")
        #if os(iOS)
        for (id, sub) in [("leaf-calendar-style", "日历 App › 月历"), ("leaf-terminal-layout", "终端 App › 按键布局"),
                          ("leaf-vocab-order", "单词 App › 出词顺序"), ("leaf-xiaoya-stage", "小芽 App › 舞台"),
                          ("leaf-mycomputer-workdir", "终端 App › 我的电脑 › Agent 干活的目录"),
                          ("leaf-sandbox-reset", "手机里的小电脑")] {
            XCTAssertEqual(SettingsSearchEntry.all.first { $0.id == id }?.subtitle, sub, id)
        }
        #else
        XCTAssertEqual(SettingsSearchEntry.all.first { $0.id == "leaf-calendar-style" }?.subtitle, "日历 › 月历")
        #endif
    }

    /// atrium P4-a：iOS「右栏」那页叫 gardenOS 设置，搜「gardenOS」「主屏」先到它；mac 仍是「右栏」，字节不变
    func testRightPanelEntryNamesGardenOSOnIOSOnly() {
        let page = SettingsSearchEntry.pageEntries.first { $0.id == "page-rightpanel" }
        XCTAssertEqual(page?.tab, .rightPanel)
        #if os(iOS)
        XCTAssertEqual(page?.title, "gardenOS 设置")
        XCTAssertEqual(page?.subtitle, "主屏 › 设置 App")
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "gardenOS").first?.tab, .rightPanel)
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "主屏").first?.tab, .rightPanel)
        XCTAssertEqual(SettingsSearchEntry.all.first { $0.id == "leaf-rightpanel-tools" }?.subtitle, "gardenOS 设置 › 默认")
        #else
        XCTAssertEqual(page?.title, "右栏")
        XCTAssertEqual(page?.subtitle, "设置")
        XCTAssertEqual(page?.keywords, ["桌面", "小组件", "工具管理", "默认", "按人", "装", "卸", "主屏上的 App", "panel", "desktop", "widget"])
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "右栏").first?.tab, .rightPanel)
        XCTAssertEqual(SettingsSearchEntry.all.first { $0.id == "leaf-rightpanel-tools" }?.subtitle, "右栏 › 工具管理")
        #endif
    }

    /// atrium P4-b：iOS 搜「壁纸 / 图标」能到 gardenOS 设置那条，「子应用」改名「App 设置」仍能搜到；mac 没有这些
    func testWallpaperAndAppSettingsEntriesOnIOSOnly() {
        let wallpaper = SettingsSearchEntry.all.first { $0.id == "leaf-gardenos-wallpaper" }
        #if os(iOS)
        XCTAssertEqual(wallpaper?.tab, .rightPanel)
        XCTAssertEqual(wallpaper?.subtitle, "gardenOS 设置")
        for query in ["壁纸", "图标", "大图标", "wallpaper"] {
            XCTAssertTrue(SettingsSearchEntry.filtered(for: query).contains { $0.id == "leaf-gardenos-wallpaper" }, query)
        }
        let page = SettingsSearchEntry.pageEntries.first { $0.id == "page-subapps" }
        XCTAssertEqual(page?.title, "App 设置")
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "子应用").first?.tab, .subApps)
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "App 设置").first?.tab, .subApps)
        XCTAssertFalse(SettingsSearchEntry.all.contains { $0.subtitle.hasPrefix("子应用 ›") }, "叶子页名跟着改")
        #else
        XCTAssertNil(wallpaper)
        XCTAssertFalse(SettingsSearchEntry.filtered(for: "壁纸").contains { $0.tab == .rightPanel })
        #endif
    }

    /// b4 #10：多台电脑三条只在 iOS 出（Mac 本期不出添加入口），iOS 上落到「我的电脑」
    func testHubEntriesPlatformFilterAndLanding() {
        let ids: Set<String> = ["leaf-mycomputer-hubs", "leaf-mycomputer-addhub", "leaf-mycomputer-managehub"]
        #if os(macOS)
        for query in ["添加电脑", "管理电脑", "多台电脑"] {
            XCTAssertFalse(SettingsSearchEntry.filtered(for: query).contains { ids.contains($0.id) }, query)
        }
        #else
        for (query, id) in [("添加电脑", "leaf-mycomputer-addhub"), ("管理电脑", "leaf-mycomputer-managehub"), ("多台电脑", "leaf-mycomputer-hubs")] {
            let hit = SettingsSearchEntry.filtered(for: query).first
            XCTAssertEqual(hit?.id, id, query)
            XCTAssertEqual(hit?.tab, .myComputer, query)
        }
        #endif
    }

    func testRegistryIDsUnique() {
        let ids = SettingsSearchEntry.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "重复 id: \(Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")
    }

    // MARK: 锚点（增量二 §八）

    /// 带 anchor 的条目只许落在铺了锚点的 8 个长页上
    func testAnchoredEntriesLiveOnAnchoredTabs() {
        for e in SettingsSearchEntry.all where e.anchor != nil {
            guard let tab = e.tab else { return XCTFail("\(e.id) 占位条目不该有 anchor") }
            XCTAssertTrue(SettingsSearchEntry.anchoredTabs.contains(tab), "\(e.id) 的页面 \(tab.rawValue) 没铺锚点")
        }
    }

    func testAnchorsNonEmptyAndUnique() {
        let anchors = SettingsSearchEntry.all.compactMap(\.anchor)
        for a in anchors {
            XCTAssertFalse(a.trimmingCharacters(in: .whitespaces).isEmpty, "空 anchor")
        }
        XCTAssertEqual(Set(anchors).count, anchors.count,
                       "重复 anchor: \(Dictionary(grouping: anchors, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")
    }

    /// 约定：anchor 直接用条目自己的 id（两边好 grep）
    func testAnchorMatchesEntryID() {
        for e in SettingsSearchEntry.all where e.anchor != nil {
            XCTAssertEqual(e.anchor, e.id, "\(e.id) 的 anchor 跟 id 不一致")
        }
    }

    func testPageEntriesHaveNoAnchor() {
        for e in SettingsSearchEntry.pageEntries {
            XCTAssertNil(e.anchor, "\(e.id) 页面级条目不该有 anchor")
        }
    }

    /// 走查①②：这两条要真带锚点，否则只跳页不滚
    func testCCThinkingCarriesAnchor() {
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "显示思考过程").first?.anchor, "leaf-cc-thinking")
    }

    func testVocabCapCarriesAnchor() {
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "每日复习上限").first?.anchor, "leaf-vocab-cap")
    }

    /// atrium P3④b：字体字号 / 行距段距 / 气泡几何按人存——Mac 留在外观「这一层」节（带锚点）；iOS 只在人页，注册表里没有
    func testPerLayerAppearanceEntries() {
        let ids = ["leaf-appear-font", "leaf-appear-text", "leaf-appear-typeset", "leaf-appear-bubblechat", "leaf-appear-geometry"]
        #if os(macOS)
        for id in ids {
            let e = SettingsSearchEntry.all.first { $0.id == id }
            XCTAssertEqual(e?.subtitle.hasPrefix("外观 › 这一层"), true, id)
            XCTAssertEqual(e?.anchor, id)
        }
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "聊天字号").first?.id, "leaf-appear-text")
        #else
        XCTAssertTrue(SettingsSearchEntry.all.allSatisfy { !ids.contains($0.id) })
        #endif
    }

    func testRecallQueriesReachTheirPageAndRetiredFeedbackIsNotASetting() {
        for (query, route) in [("太短的不找", SettingsRoute.memoryArchiveTrigger),
                               ("最多翻几次", .memoryRecallBrowse),
                               ("命中的只带一行目录", .memoryOpenWindow),
                               ("翻记忆", .memoryRecallBrowse)] {
            let hit = SettingsSearchEntry.filtered(for: query).first
            XCTAssertEqual(hit?.tab, .memory, query)
            XCTAssertEqual(hit?.anchor.flatMap(SettingsSearchEntry.memorySubpage), route, query)
        }
        XCTAssertFalse(SettingsSearchEntry.filtered(for: "召回反馈").contains { $0.id == "leaf-mem-feedback" })
        XCTAssertEqual(SettingsSearchEntry.memorySubpage(for: "leaf-mem-tuning-previousWindowMessages"), .memoryOpenWindow)
        XCTAssertNil(SettingsSearchEntry.memorySubpage(for: "leaf-mem-tuning-maximumPages"))
        XCTAssertNil(SettingsSearchEntry.memorySubpage(for: "leaf-mem-maximumpages"))
    }

    func testCCMemorySyncQueriesReachMemoryWritingSettings() throws {
        for query in ["同步 CC 的记忆", "CC 记忆 同步", "Claude Code 同步"] {
            let hit = try XCTUnwrap(SettingsSearchEntry.filtered(for: query).first, query)
            XCTAssertEqual(hit.tab, .memory, query)
            XCTAssertEqual(hit.anchor, "leaf-mem-ccmemory", query)
            XCTAssertNil(SettingsSearchEntry.memorySubpage(for: try XCTUnwrap(hit.anchor)), query)
        }
    }

    // MARK: Router 状态机

    @MainActor
    func testRouterPendingConsumedOnce() {
        let router = SettingsSearchRouter.shared
        defer { _ = router.takePending(); router.clearFlash() }

        router.request(anchor: "leaf-cc-thinking")
        XCTAssertEqual(router.pendingAnchor, "leaf-cc-thinking")
        XCTAssertEqual(router.takePending(), "leaf-cc-thinking")
        XCTAssertNil(router.pendingAnchor, "取走后没清空")
        XCTAssertNil(router.takePending(), "第二次还能取到，会重复滚")
    }

    @MainActor
    func testRouterRequestNilClearsPending() {
        let router = SettingsSearchRouter.shared
        defer { _ = router.takePending(); router.clearFlash() }

        router.request(anchor: "leaf-vocab-cap")
        router.request(anchor: nil)   // 页面级条目：上一条的锚点不许留下来
        XCTAssertNil(router.pendingAnchor)
    }

    @MainActor
    func testRouterFlashSetsAndClears() {
        let router = SettingsSearchRouter.shared
        defer { router.clearFlash() }

        router.flash("leaf-vocab-cap")
        XCTAssertEqual(router.flashingAnchor, "leaf-vocab-cap")
        router.clearFlash()
        XCTAssertNil(router.flashingAnchor)
    }

    // MARK: 说明书章节（manual-index.json → manualEntries）

    func testManualIndexLoads() {
        let entries = SettingsSearchEntry.manualEntries
        XCTAssertFalse(entries.isEmpty, "manual-index.json 没读到或为空——先跑 scripts/manual build")
        for e in entries {
            XCTAssertEqual(e.tab, .manual, "\(e.id) 应跳 .manual")
            XCTAssertNotNil(e.anchor, "\(e.id) 缺 anchor")
            XCTAssertEqual(e.id, e.anchor, "\(e.id) id 应等于 anchor")
        }
        XCTAssertTrue(entries.contains { $0.anchor?.contains("--") == true }, "至少一条小节锚（name--slug）")
        XCTAssertTrue(SettingsSearchEntry.anchoredTabs.contains(.manual))
    }
}
