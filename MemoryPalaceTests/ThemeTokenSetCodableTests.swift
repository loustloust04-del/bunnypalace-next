import XCTest
@testable import 记忆花园

/// M1 三格字色的迁移锁（plan-theme-decouple M1.5）。
///
/// 主题定义持久化在 UserDefaults 的 `themeDefinitions` JSON 里（`ThemeManager.Keys`），
/// 用户机器上存着的都是**没有** `userText` / `assistantText` 两格的老 JSON。这两格是
/// optional，合成 Codable 走 `decodeIfPresent`，所以老数据零迁移——但这是语言行为，
/// 不是我们写的代码，改结构时很容易在不知不觉中破坏（比如哪天给它们加了非 optional 的
/// 兄弟字段，或手写了 `init(from:)`）。锁在这里。
final class ThemeTokenSetCodableTests: XCTestCase {

    /// 老 JSON：11 格齐全，没有两个新字段
    private let legacyJSON = """
    {
      "mainBg":          {"red": 1.0,  "green": 0.98, "blue": 0.97, "alpha": 1.0},
      "sidebarBg":       {"red": 0.93, "green": 0.96, "blue": 0.94, "alpha": 1.0},
      "userBubble":      {"red": 0.94, "green": 0.96, "blue": 0.94, "alpha": 1.0},
      "assistantBubble": {"red": 0.92, "green": 0.92, "blue": 0.92, "alpha": 0.0},
      "accent":          {"red": 0.90, "green": 0.93, "blue": 0.92, "alpha": 1.0},
      "textPrimary":     {"red": 0.24, "green": 0.21, "blue": 0.20, "alpha": 1.0},
      "textSecondary":   {"red": 0.50, "green": 0.47, "blue": 0.44, "alpha": 1.0},
      "textMuted":       {"red": 0.68, "green": 0.65, "blue": 0.62, "alpha": 1.0},
      "favorite":        {"red": 0.94, "green": 0.80, "blue": 0.56, "alpha": 1.0},
      "danger":          {"red": 0.88, "green": 0.52, "blue": 0.52, "alpha": 1.0},
      "branchIndicator": {"red": 0.56, "green": 0.74, "blue": 0.62, "alpha": 1.0}
    }
    """

    /// 老数据能解码，且两格是 nil —— nil 就是「跟随主文字」，等于升级前的观感
    func testLegacyJSONDecodesWithNilTextOverrides() throws {
        let tokens = try JSONDecoder().decode(ThemeTokenSet.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(tokens.userText, "老主题解出来必须是 nil（跟随主文字），否则升级后聊天字色会跳变")
        XCTAssertNil(tokens.assistantText)
        XCTAssertEqual(tokens.textPrimary.hexString, "#3D3633")
    }

    /// 共存第一步：老 JSON 和老的导出主题文件没有 5 格气泡模式色，解出来全是 nil（跟随普通色）；设过的往返不丢
    func testLegacyJSONDecodesWithNilBubbleModeColors() throws {
        let tokens = try JSONDecoder().decode(ThemeTokenSet.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(tokens.bubbleModeUserBubble)
        XCTAssertNil(tokens.bubbleModeUserBubbleGradient)
        XCTAssertNil(tokens.bubbleModeAssistantBubble)
        XCTAssertNil(tokens.bubbleModeUserText)
        XCTAssertNil(tokens.bubbleModeAssistantText)
        XCTAssertEqual(tokens.applyingBubbleModeColors(), tokens, "全 nil 时气泡模式和普通色一模一样")

        let definitionJSON = """
        {"id": "theme-old", "name": "老主题", "isBuiltIn": false, "light": \(legacyJSON), "dark": \(legacyJSON)}
        """
        let definition = try JSONDecoder().decode(AppThemeDefinition.self, from: Data(definitionJSON.utf8))
        XCTAssertNil(definition.light.bubbleModeUserBubble, "导出的老主题文件照常能读")
        XCTAssertNil(definition.dark.bubbleModeAssistantText)

        var edited = tokens
        edited.bubbleModeUserBubble = ThemeColorValue(hex: 0x007AFF)
        edited.bubbleModeAssistantText = ThemeColorValue(hex: 0x112233)
        let restored = try JSONDecoder().decode(ThemeTokenSet.self, from: try JSONEncoder().encode(edited))
        XCTAssertEqual(restored.bubbleModeUserBubble?.hexString, "#007AFF")
        XCTAssertEqual(restored.bubbleModeAssistantText?.hexString, "#112233")
        XCTAssertNil(restored.bubbleModeUserText)
    }

    /// 共存返工：深色草稿里 5 格气泡模式色 nil 保持 nil（跟随），设了值的跟着派生（提亮 / 压暗，不原样抄）
    func testDarkDraftDerivesBubbleModeColors() throws {
        let legacy = try JSONDecoder().decode(ThemeTokenSet.self, from: Data(legacyJSON.utf8))
        let followDark = legacy.generatingDarkDraftFromLight()
        XCTAssertNil(followDark.bubbleModeUserBubble)
        XCTAssertNil(followDark.bubbleModeUserBubbleGradient)
        XCTAssertNil(followDark.bubbleModeAssistantBubble)
        XCTAssertNil(followDark.bubbleModeUserText)
        XCTAssertNil(followDark.bubbleModeAssistantText)

        var light = legacy
        light.bubbleModeUserBubble = ThemeColorValue(hex: 0x4A90D9)
        light.bubbleModeUserBubbleGradient = ThemeColorValue(hex: 0x7FB3E6)
        light.bubbleModeAssistantBubble = ThemeColorValue(hex: 0xE9E9EB)
        light.bubbleModeUserText = ThemeColorValue(hex: 0x332211)
        light.bubbleModeAssistantText = ThemeColorValue(hex: 0x223344)
        let dark = light.generatingDarkDraftFromLight()
        let pairs: [(ThemeColorValue?, ThemeColorValue?)] = [
            (light.bubbleModeUserBubble, dark.bubbleModeUserBubble),
            (light.bubbleModeUserBubbleGradient, dark.bubbleModeUserBubbleGradient),
            (light.bubbleModeAssistantBubble, dark.bubbleModeAssistantBubble),
            (light.bubbleModeUserText, dark.bubbleModeUserText),
            (light.bubbleModeAssistantText, dark.bubbleModeAssistantText)
        ]
        for (i, (l, d)) in pairs.enumerated() {
            XCTAssertNotNil(d, "第 \(i) 格：设过就不能丢回跟随")
            XCTAssertNotEqual(d?.hexString, l?.hexString, "第 \(i) 格：深色草稿要派生，不原样抄")
        }
    }

    /// 设过覆盖之后编解码保住值
    func testOverridesSurviveRoundTrip() throws {
        var tokens = try JSONDecoder().decode(ThemeTokenSet.self, from: Data(legacyJSON.utf8))
        tokens.userText = ThemeColorValue(hex: 0x8EBD9F)
        tokens.assistantText = ThemeColorValue(hex: 0xD77D7D)

        let restored = try JSONDecoder().decode(
            ThemeTokenSet.self,
            from: try JSONEncoder().encode(tokens)
        )

        XCTAssertEqual(restored.userText?.hexString, "#8EBD9F")
        XCTAssertEqual(restored.assistantText?.hexString, "#D77D7D")
    }

    /// 只设一格时另一格保持跟随（三格是独立的，不会互相带出来）
    func testPartialOverrideKeepsTheOtherFollowing() throws {
        var tokens = try JSONDecoder().decode(ThemeTokenSet.self, from: Data(legacyJSON.utf8))
        tokens.assistantText = ThemeColorValue(hex: 0x123456)

        let restored = try JSONDecoder().decode(
            ThemeTokenSet.self,
            from: try JSONEncoder().encode(tokens)
        )

        XCTAssertNil(restored.userText)
        XCTAssertEqual(restored.assistantText?.hexString, "#123456")
    }

    /// 浅色生成深色草稿时，跟随态不能被「推导」成一个写死的值
    func testDarkDraftKeepsFollowingWhenNotOverridden() throws {
        let light = try JSONDecoder().decode(ThemeTokenSet.self, from: Data(legacyJSON.utf8))
        let dark = light.generatingDarkDraftFromLight()

        XCTAssertNil(dark.userText, "浅色是跟随态，生成的深色草稿也必须是跟随态")
        XCTAssertNil(dark.assistantText)
    }

    /// 浅色设过覆盖时，深色草稿要带着它一起变亮（而不是丢掉覆盖回到跟随）
    func testDarkDraftCarriesOverrideOver() throws {
        var light = try JSONDecoder().decode(ThemeTokenSet.self, from: Data(legacyJSON.utf8))
        light.userText = ThemeColorValue(hex: 0x332211)

        let dark = light.generatingDarkDraftFromLight()

        XCTAssertNotNil(dark.userText, "浅色设过就不是跟随态了，深色草稿不能把它丢回 nil")
        XCTAssertNotEqual(dark.userText?.hexString, light.userText?.hexString, "深色草稿应该被提亮")
    }
}
