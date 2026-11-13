import XCTest
import SwiftUI
@testable import 记忆花园

/// 共存第一步：主题只有一套，每套主题里带 5 个气泡模式色（nil = 跟随普通色）。
/// 气泡模式下聊天页（且只有聊天页）用它们盖住泡底 / 泡字；文章模式不受影响；兔兔皮肤开着时排第一，覆盖不生效。
final class BubbleThemeTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        suites.removeAll()
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "BubbleThemeTests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    /// 一套自定义主题：普通色是暖色，气泡模式色只设了「你的气泡底」和「你的文字」
    private func makeManagerWithBubbleColors(_ defaults: UserDefaults) throws -> ThemeManager {
        var mine = AppThemeDefinition.customTheme
        mine.id = "theme-mine"
        mine.name = "我的主题"
        mine.light.userBubble = ThemeColorValue(hex: 0x8A2345)
        mine.light.assistantBubble = ThemeColorValue(hex: 0xEAD9C8)
        mine.light.bubbleModeUserBubble = ThemeColorValue(hex: 0x007AFF)
        mine.light.bubbleModeUserText = ThemeColorValue(hex: 0xFFFFFF)
        defaults.set(try JSONEncoder().encode([mine]), forKey: "themeDefinitions")
        defaults.set(mine.id, forKey: "selectedThemeId")
        let manager = ThemeManager(defaults: defaults)
        manager.themeMode = .light
        return manager
    }

    // MARK: - iMessage 内置主题

    func testIMessageThemeExistsAndIsLocked() {
        let theme = ThemeManager(defaults: makeDefaults()).themeDefinition(id: "imessage")
        XCTAssertNotNil(theme)
        XCTAssertEqual(theme?.isBuiltIn, true)
        XCTAssertEqual(theme?.isDeletable, false)
    }

    func testIMessageColors() {
        XCTAssertEqual(ThemeTokenSet.iMessageLight.userBubble.hexString.lowercased(), "#007aff")
        XCTAssertEqual(ThemeTokenSet.iMessageLight.assistantBubble.hexString.lowercased(), "#e9e9eb")
        XCTAssertEqual(ThemeTokenSet.iMessageDark.userBubble.hexString.lowercased(), "#0a84ff")
        XCTAssertEqual(ThemeTokenSet.iMessageDark.assistantText?.hexString.lowercased(), "#ffffff")
        XCTAssertEqual(ThemeTokenSet.iMessageLight.bubbleModeUserBubble?.hexString.lowercased(), "#007aff")
        XCTAssertEqual(ThemeTokenSet.iMessageLight.bubbleModeAssistantBubble?.hexString.lowercased(), "#e9e9eb")
        XCTAssertEqual(ThemeTokenSet.iMessageLight.bubbleModeUserText?.hexString.lowercased(), "#ffffff")
        XCTAssertEqual(ThemeTokenSet.iMessageLight.bubbleModeAssistantText?.hexString.lowercased(), "#000000")
        XCTAssertEqual(ThemeTokenSet.iMessageDark.bubbleModeUserBubble?.hexString.lowercased(), "#0a84ff")
        XCTAssertEqual(ThemeTokenSet.iMessageDark.bubbleModeAssistantBubble?.hexString.lowercased(), "#2c2c2e")
        XCTAssertEqual(ThemeTokenSet.iMessageDark.bubbleModeUserText?.hexString.lowercased(), "#ffffff")
        XCTAssertEqual(ThemeTokenSet.iMessageDark.bubbleModeAssistantText?.hexString.lowercased(), "#ffffff")
    }

    // MARK: - 残留键

    func testLegacyBubbleThemeKeyIsRemovedAtLaunch() {
        let defaults = makeDefaults()
        defaults.set("imessage", forKey: "bubbleThemeId")
        defaults.set("custom", forKey: "selectedThemeId")
        let manager = ThemeManager(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "bubbleThemeId"), "T7 留下的气泡主题键启动时清掉")
        XCTAssertEqual(manager.selectedThemeId, "custom", "选中的主题不受影响")
        manager.isBubbleModeActive = true
        manager.themeMode = .light
        XCTAssertEqual(manager.currentChatTokenSet, manager.currentTokenSet,
                       "旧的气泡主题不再生效：自定义主题没设气泡色，聊天页就是这套主题本身")
    }

    // MARK: - 覆盖语义

    /// 1. 气泡模式下覆盖生效（只盖设了的那几格，且只盖聊天页）
    func testBubbleModeOverridesApplyInChat() throws {
        let manager = try makeManagerWithBubbleColors(makeDefaults())
        manager.isBubbleModeActive = true
        let chat = manager.currentChatTokenSet
        XCTAssertEqual(chat.userBubble.hexString.lowercased(), "#007aff")
        XCTAssertEqual(chat.userText?.hexString.lowercased(), "#ffffff")
        XCTAssertEqual(manager.currentTokenSet.userBubble.hexString.lowercased(), "#8a2345",
                       "列表、设置、page0 不被气泡模式色染")
    }

    /// 2. 字段为 nil 时跟随普通颜色
    func testNilBubbleModeFieldsFollowNormalColors() throws {
        let manager = try makeManagerWithBubbleColors(makeDefaults())
        manager.isBubbleModeActive = true
        let chat = manager.currentChatTokenSet
        let normal = manager.currentTokenSet
        XCTAssertEqual(chat.assistantBubble, normal.assistantBubble)
        XCTAssertEqual(chat.assistantText, normal.assistantText)
        XCTAssertEqual(chat.userBubbleGradient, normal.userBubbleGradient)

        // 默认主题五格全 nil：气泡模式聊天页和普通色一模一样
        let plain = ThemeManager(defaults: makeDefaults())
        plain.themeMode = .light
        plain.isBubbleModeActive = true
        XCTAssertEqual(plain.currentChatTokenSet, plain.currentTokenSet)
        XCTAssertEqual(ThemeTokenSet.palaceLightDefault.applyingBubbleModeColors(), .palaceLightDefault)
    }

    /// 3. 文章模式不受影响
    func testArticleModeIgnoresBubbleModeColors() throws {
        let manager = try makeManagerWithBubbleColors(makeDefaults())
        manager.isBubbleModeActive = false
        XCTAssertEqual(manager.currentChatTokenSet, manager.currentTokenSet)
        XCTAssertEqual(manager.currentChatTokenSet.userBubble.hexString.lowercased(), "#8a2345")
    }

    /// 5. 换主题后聊天页立刻跟着变（气泡模式里点主题库就换，不再有单独的气泡主题）
    func testSwitchingThemeChangesChatImmediately() throws {
        let manager = try makeManagerWithBubbleColors(makeDefaults())
        manager.isBubbleModeActive = true
        let before = manager.themeChangeID
        manager.selectTheme(id: AppThemeDefinition.iMessageTheme.id)
        XCTAssertNotEqual(manager.themeChangeID, before, "换主题要通知界面重算")
        XCTAssertEqual(manager.currentChatTokenSet, ThemeTokenSet.iMessageLight.applyingBubbleModeColors())
        XCTAssertEqual(Theme.chatTokens(skin: nil, manager: manager).userBubble.hexString.lowercased(), "#007aff")
        manager.selectTheme(id: AppThemeDefinition.defaultTheme.id)
        XCTAssertEqual(manager.currentChatTokenSet, .palaceLightDefault)
    }

    // MARK: - 界面主题 / 聊天主题拆 id（P3④0）

    /// 聊天主题设了：聊天配色换成那套、界面配色不动；值没变不重复通知
    func testChatThemeIdChangesChatTokensOnly() throws {
        let manager = try makeManagerWithBubbleColors(makeDefaults())
        let globalBefore = manager.currentTokenSet
        let changeBefore = manager.themeChangeID
        manager.applyChatTheme(AppThemeDefinition.iMessageTheme.id)
        XCTAssertNotEqual(manager.themeChangeID, changeBefore, "换聊天主题要通知界面重算（清 markdown 缓存）")
        XCTAssertEqual(manager.chatTheme.id, AppThemeDefinition.iMessageTheme.id)
        XCTAssertEqual(manager.currentChatTokenSet, .iMessageLight)
        XCTAssertEqual(manager.currentTokenSet, globalBefore, "界面配色还是 selectedThemeId 那套")
        XCTAssertEqual(manager.selectedThemeId, "theme-mine")
        let changeAfter = manager.themeChangeID
        manager.applyChatTheme(AppThemeDefinition.iMessageTheme.id)
        XCTAssertEqual(manager.themeChangeID, changeAfter, "同一个 id 不 touch")
    }

    /// 聊天主题指向不存在的 id：回落界面主题（不是 default）
    func testMissingChatThemeFallsBackToInterfaceTheme() throws {
        let manager = try makeManagerWithBubbleColors(makeDefaults())
        manager.applyChatTheme("theme-gone")
        XCTAssertEqual(manager.chatTheme.id, "theme-mine")
        XCTAssertEqual(manager.currentChatTokenSet, manager.currentTokenSet)
        XCTAssertEqual(manager.chatBackgroundImageURL, manager.currentBackgroundImageURL)
    }

    /// 删掉正在当聊天主题的那套：chatThemeId 清成 nil，界面主题不受影响
    func testDeletingChatThemeClearsChatThemeId() throws {
        let manager = try makeManagerWithBubbleColors(makeDefaults())
        let copyId = try XCTUnwrap(manager.saveThemeCopy(from: AppThemeDefinition.iMessageTheme.id, name: "聊天用", select: false))
        manager.applyChatTheme(copyId)
        XCTAssertEqual(manager.chatTheme.id, copyId)
        manager.deleteTheme(id: copyId)
        XCTAssertNil(manager.chatThemeId)
        XCTAssertEqual(manager.chatTheme.id, "theme-mine")
        XCTAssertEqual(manager.selectedThemeId, "theme-mine")
    }

    // MARK: - 渐变三种组合（共存返工③）

    private var gradientBase: ThemeTokenSet {
        var tokens = ThemeTokenSet.palaceLightDefault
        tokens.userBubble = ThemeColorValue(hex: 0x8A2345)
        tokens.userBubbleGradient = ThemeColorValue(hex: 0xE8B4A8)
        return tokens
    }

    func testBubbleModeGradientSetIsUsed() {
        var tokens = gradientBase
        tokens.bubbleModeUserBubble = ThemeColorValue(hex: 0x007AFF)
        tokens.bubbleModeUserBubbleGradient = ThemeColorValue(hex: 0x5AC8FA)
        let chat = tokens.applyingBubbleModeColors()
        XCTAssertEqual(chat.userBubble.hexString, "#007AFF")
        XCTAssertEqual(chat.userBubbleGradient?.hexString, "#5AC8FA", "设了气泡模式渐变就用它")
    }

    func testBubbleOverriddenWithoutGradientIsSolid() {
        var tokens = gradientBase
        tokens.bubbleModeUserBubble = ThemeColorValue(hex: 0x007AFF)
        let chat = tokens.applyingBubbleModeColors()
        XCTAssertEqual(chat.userBubble.hexString, "#007AFF")
        XCTAssertNil(chat.userBubbleGradient, "泡底换了、渐变没设：单色，不拿普通渐变第二色配新泡底")
    }

    func testNeitherSetFollowsNormalGradient() {
        let chat = gradientBase.applyingBubbleModeColors()
        XCTAssertEqual(chat.userBubble.hexString, "#8A2345")
        XCTAssertEqual(chat.userBubbleGradient?.hexString, "#E8B4A8", "两个都没设：跟随普通渐变")
    }

    // MARK: - 复制 / 清回跟随

    func testThemeCopyKeepsBubbleModeColors() throws {
        let defaults = makeDefaults()
        let manager = try makeManagerWithBubbleColors(defaults)
        let copyId = try XCTUnwrap(manager.saveThemeCopy(from: "theme-mine", name: "副本", select: false))
        let copy = try XCTUnwrap(manager.themeDefinition(id: copyId))
        XCTAssertEqual(copy.light.bubbleModeUserBubble?.hexString, "#007AFF")
        XCTAssertEqual(copy.light.bubbleModeUserText?.hexString, "#FFFFFF")
        XCTAssertNil(copy.light.bubbleModeAssistantBubble, "没设的复制过去仍是跟随")
        let reloaded = try XCTUnwrap(ThemeManager(defaults: defaults).themeDefinition(id: copyId))
        XCTAssertEqual(reloaded.light.bubbleModeUserBubble?.hexString, "#007AFF", "副本落盘后读回不丢")
    }

    func testClearingBubbleModeColorWritesNilAndPersists() throws {
        let defaults = makeDefaults()
        let manager = try makeManagerWithBubbleColors(defaults)
        var tokens = try XCTUnwrap(manager.themeDefinition(id: "theme-mine")).light
        tokens.bubbleModeUserBubble = nil   // 颜色页 ↺：writeOverride(keyPath, nil)
        manager.replaceTokenSet(tokens, for: .light, themeId: "theme-mine")
        XCTAssertNil(manager.themeDefinition(id: "theme-mine")?.light.bubbleModeUserBubble)
        XCTAssertNil(ThemeManager(defaults: defaults).themeDefinition(id: "theme-mine")?.light.bubbleModeUserBubble,
                     "清回跟随落盘是 nil，不是写死成普通色")
        manager.isBubbleModeActive = true
        XCTAssertEqual(manager.currentChatTokenSet.userBubble.hexString, "#8A2345", "清回后气泡模式跟随普通泡底")
    }

    /// 返工 1：编程会话 / 助手面板复用聊天组件时整套读全局——气泡模式 + 主题设了气泡色时，
    /// 用户字不能变成气泡模式的白字（泡底是全局普通色），字色和泡底同源。
    func testGlobalScopeIgnoresBubbleModeColorsForReusedChatComponents() throws {
        let manager = ThemeManager.shared
        let saved = (manager.isBubbleModeActive, manager.selectedThemeId, manager.themeMode)
        defer {
            manager.isBubbleModeActive = saved.0
            manager.selectTheme(id: saved.1)
            manager.themeMode = saved.2
        }
        let copyId = try XCTUnwrap(manager.saveThemeCopy(from: AppThemeDefinition.defaultTheme.id, name: "带气泡色", select: true))
        defer { manager.deleteTheme(id: copyId) }
        var light = ThemeTokenSet.palaceLightDefault
        light.bubbleModeUserBubble = ThemeColorValue(hex: 0x007AFF)
        light.bubbleModeUserText = ThemeColorValue(hex: 0xFFFFFF)
        manager.replaceTokenSet(light, for: .light, themeId: copyId)
        manager.themeMode = .light
        manager.isBubbleModeActive = true

        let global = manager.currentTokenSet
        XCTAssertEqual(ThemeScope.global.palette.tokens, global)
        XCTAssertEqual(ThemeScope.chat.palette.tokens, light.applyingBubbleModeColors())
        XCTAssertEqual(ChatTextRole.user.color(in: .global), (global.userText ?? global.textPrimary).color,
                       "编程会话用户字色跟全局泡底同源")
        XCTAssertEqual(ChatTextRole.assistant.color(in: .global), (global.assistantText ?? global.textPrimary).color)
        XCTAssertNotEqual(ChatTextRole.user.color(in: .global), ChatTextRole.user.color(in: .chat),
                          "聊天页才用气泡模式白字")
        XCTAssertEqual(ChatTextRole.chatPlain.color(in: .global), global.textPrimary.color)
        XCTAssertNotNil(Theme.chatCardStyle(themed: true, scope: .chat), "名单卡在聊天页气泡模式跟聊天主题")
        XCTAssertNil(Theme.chatCardStyle(themed: true, scope: .global), "文件库预览 / 编程会话里卡壳取全局（米白）")
        XCTAssertNil(Theme.chatCardStyle(themed: false, scope: .chat), "固定纸墨的卡（图表等）不跟聊天主题")
        manager.isBubbleModeActive = false
        XCTAssertNil(Theme.chatCardStyle(themed: true, scope: .chat), "文章模式卡片照旧米白")
        XCTAssertEqual(ChatTextRole.chatPlain.color(in: .chat), global.textPrimary.color, "文章模式 chatPlain 等同全局")
    }

    /// 返工二：名单卡标签字读 token，iMessage 浅 / 深卡底上 ≥ 4.5；图表卡（不在名单）米白纸 + ChartInk 墨 ≥ 4.5
    func testCardLabelAndChartInkContrast() {
        for tokens in [ThemeTokenSet.iMessageLight, .iMessageDark] {
            XCTAssertGreaterThanOrEqual(Self.contrast(tokens.textSecondary, on: tokens.sidebarBg), 4.5, tokens.sidebarBg.hexString)
        }
        let paper = ThemeColorValue(hex: 0xFFFDF9)
        XCTAssertGreaterThanOrEqual(Self.contrast(ThemeColorValue(hex: 0x1C1C1A), on: paper), 4.5, "图表标题墨压米白纸")
        XCTAssertLessThan(Self.contrast(ThemeColorValue(hex: 0x1C1C1A), on: ThemeTokenSet.iMessageDark.sidebarBg), 1.5,
                          "这正是图表卡不能换深色壳的原因")
    }

    /// 4. 兔兔开着时覆盖不生效：聊天页整套兔兔色，气泡模式色一格都不盖上去。
    /// 测试 target 不带 PERSONAL_APPS，拿一套深色 token 顶替兔兔 token 验优先级（`Theme.skinTokens` 的开关判断原样不动）。
    func testTutuSkinWinsOverBubbleModeColorsInChat() throws {
        let manager = try makeManagerWithBubbleColors(makeDefaults())
        manager.isBubbleModeActive = true
        #if PERSONAL_APPS
        let skin = TutuSkinPalette.tokens
        #else
        let skin = ThemeTokenSet.palaceDarkDefault
        #endif
        XCTAssertEqual(Theme.chatTokens(skin: skin, manager: manager), skin,
                       "皮肤开着时聊天页显示兔兔配色，不被气泡模式色盖掉")
        XCTAssertNil(Theme.chatTokens(skin: skin, manager: manager).bubbleModeUserBubble)
        XCTAssertEqual(Theme.chatTokens(skin: nil, manager: manager).userBubble.hexString.lowercased(), "#007aff")
    }

    // MARK: - 引用对比度

    func testBubbleBlockQuoteUsesBubbleTextColorOnlyInBubbleMode() {
        let manager = ThemeManager.shared
        let saved = manager.isBubbleModeActive
        defer { manager.isBubbleModeActive = saved }
        manager.isBubbleModeActive = false
        XCTAssertNil(Theme.chatBlockQuoteColor(for: .assistant), "文章模式引用块不动")
        XCTAssertNil(Theme.chatBlockQuoteColor(for: .global))
        manager.isBubbleModeActive = true
        XCTAssertNotNil(Theme.chatBlockQuoteColor(for: .assistant))
        XCTAssertNotNil(Theme.chatBlockQuoteColor(for: .user))
        XCTAssertNil(Theme.chatBlockQuoteColor(for: .global), "非聊天调用方永远不动")
    }

    /// 气泡模式引用块用泡里的正文色，对比度与该泡正文一致：灰泡黑 / 白字 ≥ 4.5，蓝泡白字是 iMessage 原生配色（≥ 3）。
    func testIMessageBubbleTextContrast() throws {
        for tokens in [ThemeTokenSet.iMessageLight, .iMessageDark] {
            XCTAssertGreaterThanOrEqual(Self.contrast(try XCTUnwrap(tokens.assistantText), on: tokens.assistantBubble), 4.5)
            XCTAssertGreaterThanOrEqual(Self.contrast(try XCTUnwrap(tokens.userText), on: tokens.userBubble), 3)
        }
    }

    /// 回复引用条（泡上方）：正文色 × 0.8 压在聊天底色上，iMessage 和宫殿默认主题浅深都 ≥ 4.5:1。
    func testReplyQuoteTextContrast() {
        let sets: [ThemeTokenSet] = [.iMessageLight, .iMessageDark, .palaceLightDefault, .palaceDarkDefault]
        for tokens in sets {
            let ink = Self.blend(tokens.textPrimary, opacity: BubbleModeRow.replyQuoteTextOpacity, over: tokens.mainBg)
            XCTAssertGreaterThanOrEqual(Self.contrast(ink, on: tokens.mainBg), 4.5, tokens.mainBg.hexString)
        }
    }

    static func blend(_ c: ThemeColorValue, opacity: Double, over bg: ThemeColorValue) -> ThemeColorValue {
        ThemeColorValue(red: c.red * opacity + bg.red * (1 - opacity),
                        green: c.green * opacity + bg.green * (1 - opacity),
                        blue: c.blue * opacity + bg.blue * (1 - opacity))
    }

    static func contrast(_ a: ThemeColorValue, on b: ThemeColorValue) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func lum(_ c: ThemeColorValue) -> Double { 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue) }
        let (l1, l2) = (lum(a), lum(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
