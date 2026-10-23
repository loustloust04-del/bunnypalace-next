import XCTest
@testable import 记忆花园

/// 小芽 v2 P3 外观放权（plan-小芽-v2 §5 v1.1，astra A8/B2/C4）：共享层 + 盖章 / 撤销，mac 上跑
@MainActor
final class AssistantAppearanceTests: XCTestCase {

    /// v3 §5：本机按关键词 / 页面挑工具，挑不出就全挂
    func testLocalToolSubset() {
        func names(_ text: String, page: String = "") -> Set<String> {
            Set(AssistantTools.localDefinitions(for: text, page: page).compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        }
        let all = Set(AssistantTools.definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        XCTAssertEqual(names("要写新角色卡，我得先知道一些信息\n随便"),
                       ["read_character", "propose_create_character", "propose_update_character_field"])
        XCTAssertTrue(names("换个秋天一点的主屏").contains("read_appearance"))
        XCTAssertEqual(names("随便写一条", page: "worldBook").count, 5)
        XCTAssertEqual(names("你好呀"), all)
        let create = AssistantTools.localDefinitions(for: "角色卡", page: "")
            .first { ($0["function"] as? [String: Any])?["name"] as? String == "propose_create_character" }
        XCTAssertTrue(((create?["function"] as? [String: Any])?["description"] as? String ?? "").hasSuffix("不要反问用户。"))
    }

    func testPatchValidationRejectsOutOfRange() {
        XCTAssertThrowsError(try Page2AppearancePatch(wallpaper: "photo").validate(), "我的照片不放权")
        XCTAssertThrowsError(try Page2AppearancePatch(rendering: "neon").validate())
        XCTAssertThrowsError(try Page2AppearancePatch(dimming: 0.9).validate())
        XCTAssertThrowsError(try Page2AppearancePatch(tintHue: 1.2).validate())
        XCTAssertNoThrow(try Page2AppearancePatch(wallpaper: "flora", rendering: "tinted", tintHue: 0.1).validate())
    }

    func testDroppingUnchangedAndCurrentValues() {
        var base = Page2Appearance()
        base.wallpaper = "mist"
        let patch = Page2AppearancePatch(wallpaper: "mist", luminosity: "dark").dropping(unchangedFrom: base)
        XCTAssertNil(patch.wallpaper)
        XCTAssertEqual(patch.luminosity, "dark")
        XCTAssertEqual(patch.currentValues(in: base), Page2AppearancePatch(luminosity: base.luminosity))
    }

    /// 盖章套在「盖章这一刻」的外观上：提案之后她手动改的别的项不会被盖回去（astra B2）
    func testStampAppliesPatchOntoCurrentCommittedValue() throws {
        let ws = FakeAssistantWorkspace.seeded()
        let after = Page2AppearancePatch(wallpaper: "flora")
        let change = AssistantChange.page2Appearance(before: after.currentValues(in: ws.page2Appearance), after: after)
        ws.page2Appearance.largeIcons = true      // 提案之后她自己开了大图标
        _ = try AssistantStamp.apply(change, in: ws)
        XCTAssertEqual(ws.page2Appearance.wallpaper, "flora")
        XCTAssertTrue(ws.page2Appearance.largeIcons, "别的项被盖回去了")
        if case .done = AssistantStamp.undo(change, in: ws, force: false) {} else { XCTFail() }
        XCTAssertEqual(ws.page2Appearance.wallpaper, "ios26")
        XCTAssertTrue(ws.page2Appearance.largeIcons)
    }

    func testStampRefusedWhenTouchedValueChangedSince() {
        let ws = FakeAssistantWorkspace.seeded()
        let after = Page2AppearancePatch(wallpaper: "flora")
        let change = AssistantChange.page2Appearance(before: after.currentValues(in: ws.page2Appearance), after: after)
        ws.page2Appearance.wallpaper = "dusk"
        XCTAssertThrowsError(try AssistantStamp.apply(change, in: ws))
        XCTAssertEqual(ws.page2Appearance.wallpaper, "dusk")
    }

    func testStitchedHomeRefused() {
        let ws = FakeAssistantWorkspace.seeded()
        ws.page2HomeIsFree = false
        let after = Page2AppearancePatch(luminosity: "dark")
        let change = AssistantChange.page2Appearance(before: after.currentValues(in: ws.page2Appearance), after: after)
        XCTAssertThrowsError(try AssistantStamp.apply(change, in: ws)) {
            XCTAssertEqual($0 as? AssistantStampError, .invalid(AssistantStamp.stitchedHome))
        }
    }

    /// 原来没自定义的图标，撤销后删掉这一项、回到默认
    func testAppIconUndoRemovesKeyWhenOriginallyAbsent() throws {
        let ws = FakeAssistantWorkspace.seeded()
        let change = AssistantChange.appIcon(toolId: "calendar", toolName: "日历", before: nil,
                                             after: Page2IconOverride(symbol: "moon", imageFile: nil, tint: "plum"))
        _ = try AssistantStamp.apply(change, in: ws)
        XCTAssertEqual(ws.page2Appearance.icons["calendar"]?.symbol, "moon")
        if case .done = AssistantStamp.undo(change, in: ws, force: false) {} else { XCTFail() }
        XCTAssertNil(ws.page2Appearance.icons["calendar"])
    }

    func testAppIconRejectsUnknownSymbol() {
        let ws = FakeAssistantWorkspace.seeded()
        let change = AssistantChange.appIcon(toolId: "calendar", toolName: "日历", before: nil,
                                             after: Page2IconOverride(symbol: "flame.fill", imageFile: nil, tint: "sage"))
        XCTAssertThrowsError(try AssistantStamp.apply(change, in: ws))
    }

    func testStageThemeStampAndUndo() throws {
        let ws = FakeAssistantWorkspace.seeded()
        let change = AssistantChange.stageTheme(before: "mint", after: "collage")
        _ = try AssistantStamp.apply(change, in: ws)
        XCTAssertEqual(ws.stageTheme, "collage")
        ws.stageTheme = "rouge"   // 之后她自己又换了
        XCTAssertEqual(AssistantStamp.undo(change, in: ws, force: false), .conflict("这之后又被改过，撤销会把那些改动一起覆盖掉"))
        if case .done = AssistantStamp.undo(change, in: ws, force: true) {} else { XCTFail() }
        XCTAssertEqual(ws.stageTheme, "mint")
    }

    func testSaveFailureMeansNotStamped() {
        let ws = FakeAssistantWorkspace.seeded()
        ws.failNextAppearanceSave = true
        let after = Page2AppearancePatch(largeIcons: true)
        let change = AssistantChange.page2Appearance(before: after.currentValues(in: ws.page2Appearance), after: after)
        XCTAssertThrowsError(try AssistantStamp.apply(change, in: ws))
        XCTAssertFalse(ws.page2Appearance.largeIcons)
    }

    func testAppearanceKindsBelongToAppearancePack() {
        XCTAssertEqual(XiaoyaPack.of(kind: .page2Appearance), .appearance)
        XCTAssertEqual(XiaoyaPack.of(kind: .stageTheme), .appearance)
        XCTAssertEqual(XiaoyaPack.of(kind: .createCharacter), .creation)
        XCTAssertEqual(XiaoyaPack.of(tool: "read_appearance"), .appearance)
        XCTAssertEqual(XiaoyaPack.of(tool: "propose_stage_theme"), .appearance)
        XCTAssertEqual(XiaoyaPack.of(tool: "read_world_book"), .read)
    }

    func testAppearanceChangeRoundTrips() throws {
        let action = AssistantAction(change: .appIcon(toolId: "t", toolName: "日历", before: nil,
                                                       after: Page2IconOverride(symbol: "moon", imageFile: nil, tint: "rose")))
        let back = try JSONDecoder().decode(AssistantAction.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(back, action)
        XCTAssertEqual(back.status, .pending)
    }
}
