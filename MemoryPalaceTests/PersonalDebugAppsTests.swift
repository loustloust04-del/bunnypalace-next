import XCTest
@testable import 记忆花园

/// #096 话题盒 / 有声书只进粟粟的 Debug 包：换到没有它们的包时，旧存档不留空壳、不连累别的条目。
final class PersonalDebugAppsTests: XCTestCase {
    func testMergeDropsSavedToolsMissingFromBuiltIns() {
        let builtIns = [RightPanelTool(id: "calendar", name: "日历", icon: "calendar", order: 0),
                        RightPanelTool(id: "vocab", name: "单词", icon: "abc", order: 10)]
        let saved = [RightPanelTool(id: "vocab", name: "旧名", icon: "old", isPinned: false, isEnabled: false, order: 3),
                     RightPanelTool(id: "audiobook", name: "有声书", icon: "headphones", order: 9)]
        let merged = RightPanelToolManager.merged(saved: saved, builtIns: builtIns)
        XCTAssertEqual(merged.map(\.id), ["vocab", "calendar"])
        XCTAssertEqual(merged[0].name, "单词")
        XCTAssertFalse(merged[0].isEnabled)
        XCTAssertEqual(merged[0].order, 3)
    }

    func testBuiltInsCarryPersonalSubAppsOnlyInPersonalDebug() {
        let ids = Set(RightPanelToolManager.builtInTools.map(\.id))
        #if PERSONAL_APPS
        #if DEBUG
        XCTAssertTrue(ids.isSuperset(of: ["topicBox", "audiobook"]))
        XCTAssertTrue(RightPanelToolManager.liteVisibleToolIds.isSuperset(of: ["topicBox", "audiobook"]))
        #else
        XCTAssertTrue(ids.isDisjoint(with: ["topicBox", "audiobook"]))
        #endif
        #else
        XCTAssertTrue(ids.isDisjoint(with: ["topicBox", "audiobook"]))
        XCTAssertTrue(RightPanelToolManager.liteVisibleToolIds.isDisjoint(with: ["topicBox", "audiobook"]))
        #endif
    }

    func testDashboardDecodeSkipsUnknownKinds() throws {
        let data = Data(#"[{"kind":"pet","size":"small"},{"kind":"gone","size":"medium"},{"kind":"vocab","size":"large"}]"#.utf8)
        let widgets = try XCTUnwrap(DashboardManager.decodeWidgets(data))
        XCTAssertEqual(widgets.map(\.kind), [.pet, .vocab])
        XCTAssertEqual(widgets.map(\.size), [.small, .large])
    }

    func testDashboardDecodeRejectsNonArray() {
        XCTAssertNil(DashboardManager.decodeWidgets(Data("{}".utf8)))
    }
}
