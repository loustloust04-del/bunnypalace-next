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
        XCTAssertNil(SettingsSearchEntry.foldStorageKey(for: .macWorkspace))
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

    /// #046 T3：配对 / 干活目录 / 局域网都落到「我的电脑」（Mac 上叫「让手机连这台 Mac」）
    func testMyComputerQueriesLandOnItsPage() {
        for query in ["配对", "我的电脑", "工作目录", "局域网直连", "依赖检查"] {
            XCTAssertEqual(SettingsSearchEntry.filtered(for: query).first?.tab, .myComputer, query)
        }
        XCTAssertEqual(SettingsSearchEntry.foldStorageKey(for: .myComputer), "settingsFold.devTools")
        XCTAssertNotNil(SettingsSearchEntry.iconByTab[.myComputer])
    }

    // MARK: 折叠组

    func testFoldGroupMapping() {
        XCTAssertEqual(SettingsSearchEntry.foldStorageKey(for: .terminal), "settingsFold.devTools")
        XCTAssertEqual(SettingsSearchEntry.foldStorageKey(for: .mcp), "settingsFold.aiExt")
        #if PERSONAL_APPS
        XCTAssertEqual(SettingsSearchEntry.foldStorageKey(for: .trading), "settingsFold.modules")
        #endif
        XCTAssertEqual(SettingsSearchEntry.foldStorageKey(for: .sandbox), "settingsFold.storage")
        XCTAssertNil(SettingsSearchEntry.foldStorageKey(for: .general))
        XCTAssertNil(SettingsSearchEntry.foldStorageKey(for: .worldBook))
    }

    /// 折叠组 key 必须跟根列表 SettingsFoldRow 的四个 storageKey 一致
    func testFoldGroupKeysAreKnown() {
        let known: Set<String> = ["settingsFold.aiExt", "settingsFold.devTools", "settingsFold.modules", "settingsFold.storage"]
        for tab in SettingsView.SettingsTab.allCases {
            if let key = SettingsSearchEntry.foldStorageKey(for: tab) {
                XCTAssertTrue(known.contains(key), "\(tab.rawValue) 映射到未知折叠组 \(key)")
            }
        }
    }

    func testExpandFoldGroupWritesDefaults() {
        let key = "settingsFold.devTools"
        let old = UserDefaults.standard.object(forKey: key)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        SettingsSearchEntry.expandFoldGroup(for: .claudeCode)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
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
