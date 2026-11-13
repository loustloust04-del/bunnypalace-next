import XCTest
@testable import 记忆花园

/// atrium P3⑥a：「主屏有 = 授权」前置门——域连着的 App 这一层没装 → 不允许；装了照档位；只收紧（plan-atrium-p3-page2 §3.1 / §3.8）
@MainActor
final class Page2AppGateTests: XCTestCase {

    private var perm: PermissionSandbox!
    private var apps: Page2AppsSandbox!
    private let a = "xctest-gate-a"
    private let b = "xctest-gate-b"

    override func setUp() {
        super.setUp()
        perm = PermissionSandbox()
        apps = Page2AppsSandbox()
    }

    override func tearDown() {
        apps.leave()
        perm.leave()
        super.tearDown()
    }

    // MARK: 映射

    func testMappingTable() {
        XCTAssertEqual(PermissionDomain.fileLibrary.page2App, "fileLibrary")
        XCTAssertEqual(PermissionDomain.twitter.page2App, "twitter")
        for d in [PermissionDomain.healthApple, .healthWeight, .healthMeds, .healthCycle, .healthIntimacy] {
            XCTAssertEqual(d.page2App, "health", "\(d)")
        }
        #if PERSONAL_APPS
        XCTAssertEqual(PermissionDomain.trading.page2App, "trading")
        #if DEBUG
        XCTAssertEqual(PermissionDomain.topicBox.page2App, "topicBox")
        #endif
        #endif
        let mapped = PermissionDomain.allCases.filter { $0.page2App != nil }
        #if PERSONAL_APPS && DEBUG
        XCTAssertEqual(mapped.count, 9)
        #elseif PERSONAL_APPS
        XCTAssertEqual(mapped.count, 8)
        #else
        XCTAssertEqual(mapped.count, 7)
        #endif
        // 每个映射的 App 都在内置表里（同编译条件），否则门永远挡着
        let builtins = Set(RightPanelToolManager.builtInTools.map(\.id))
        for d in mapped { XCTAssertTrue(builtins.contains(d.page2App!), "\(d) → \(d.page2App!)") }
        // 只全局 / 只能更严的域不挂门
        for d in PermissionDomain.allCases where d.floorRule != .free { XCTAssertNil(d.page2App, "\(d)") }
    }

    // MARK: 门

    func testNotInstalledIsNotAllowedInstalledFollowsLevel() {
        PermissionCenter.setDefaultLevel(.askOnce, for: .fileLibrary)
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
        XCTAssertEqual(PermissionCenter.level(.fileLibrary, profileId: a), .notAllowed, "A 没装 → 不允许")
        XCTAssertEqual(PermissionCenter.level(.fileLibrary, profileId: b), .askOnce, "B 装着（跟默认）→ 照档位")
        XCTAssertFalse(PermissionCenter.capabilityEnabled(.fileLibrary, profileId: a))
        XCTAssertTrue(PermissionCenter.capabilityEnabled(.fileLibrary, profileId: b))
        PermissionCenter.setDefaultLevel(.bypass, for: .fileLibrary)
        XCTAssertFalse(PermissionCenter.injectionAllowed(.fileLibrary, profileId: a, grants: .empty))
        XCTAssertTrue(PermissionCenter.injectionAllowed(.fileLibrary, profileId: b, grants: .empty))
        XCTAssertEqual(PermissionCenter.defaultLevel(.fileLibrary), .bypass, "默认档不受门影响（「我 › 权限」照旧）")
        Page2Apps.setFloor(true, for: "fileLibrary", profileId: a)
        XCTAssertEqual(PermissionCenter.level(.fileLibrary, profileId: a), .bypass, "装回来 → 回到档位")
    }

    func testFloorLooserLevelStillBlockedWhenNotInstalled() {
        XCTAssertEqual(PermissionCenter.defaultLevel(.healthWeight), .notAllowed)
        PermissionCenter.setFloorLevel(.bypass, for: .healthWeight, profileId: a)
        PermissionCenter.setFloorLevel(.bypass, for: .healthWeight, profileId: b)
        Page2Apps.setFloor(false, for: "health", profileId: a)
        XCTAssertEqual(PermissionCenter.level(.healthWeight, profileId: a), .notAllowed, "层档位放宽也压不过没装")
        XCTAssertEqual(PermissionCenter.level(.healthWeight, profileId: b), .bypass)
        for d in [PermissionDomain.healthApple, .healthMeds, .healthCycle, .healthIntimacy] {
            XCTAssertEqual(PermissionCenter.level(d, profileId: a), .notAllowed, "健康五项一起挡：\(d)")
        }
        XCTAssertEqual(PermissionCenter.floors().stored(.healthWeight, profileId: a), .bypass, "门不写档位层")
        XCTAssertNil(perm.defaults.object(forKey: PermissionDomain.healthWeight.storageKey), "门不写默认档")
    }

    func testNilProfileUsesDefaultInstalled() {
        XCTAssertEqual(PermissionCenter.level(.twitter, profileId: nil), .bypass)
        Page2Apps.setFloor(false, for: "twitter", profileId: a)
        XCTAssertEqual(PermissionCenter.level(.twitter, profileId: nil), .bypass, "没层 = 默认装没装，层覆盖不算")
        apps.storeDefaults(["twitter": false])
        XCTAssertEqual(PermissionCenter.level(.twitter, profileId: nil), .notAllowed, "默认卸了 → 没层也挡")
        XCTAssertEqual(PermissionCenter.level(.twitter, profileId: b), .notAllowed, "跟默认的人一起挡")
        Page2Apps.setFloor(true, for: "twitter", profileId: b)
        XCTAssertEqual(PermissionCenter.level(.twitter, profileId: b), .bypass, "默认卸了、这个人单独装 → 照档位")
    }

    func testLiteHiddenButInstalledIsNotBlocked() {
        XCTAssertFalse(RightPanelToolManager.liteVisibleToolIds.contains("fileLibrary"), "前提：lite 下文件库隐藏")
        apps.defaults.set(false, forKey: "settings.proMode")
        XCTAssertNil(PermissionCenter.blockingApp(.fileLibrary, profileId: a), "门只看装没装，不看 lite 白名单")
        XCTAssertEqual(PermissionCenter.level(.fileLibrary, profileId: a), .bypass)
    }

    func testUnmappedAndGlobalDomainsUnaffected() {
        apps.storeDefaults(Dictionary(uniqueKeysWithValues: RightPanelToolManager.builtInTools.map { ($0.id, false) }))
        for d in PermissionDomain.allCases where d.page2App == nil {
            XCTAssertEqual(PermissionCenter.level(d, profileId: a), PermissionCenter.defaultLevel(d), "\(d) 不连 App，全卸了也不变")
            XCTAssertNil(PermissionCenter.blockingApp(d, profileId: a))
        }
        for d in PermissionDomain.allCases where d.page2App != nil {
            XCTAssertEqual(PermissionCenter.level(d, profileId: a), .notAllowed, "\(d)")
        }
    }

    func testBlockingAppAndLabels() {
        XCTAssertNil(PermissionCenter.blockingApp(.healthCycle, profileId: a))
        Page2Apps.setFloor(false, for: "health", profileId: a)
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
        XCTAssertEqual(PermissionCenter.blockingApp(.healthCycle, profileId: a), "health")
        XCTAssertEqual(PermissionCenter.blockingApp(.fileLibrary, profileId: a), "fileLibrary")
        XCTAssertNil(PermissionCenter.blockingApp(.healthCycle, profileId: b))
        XCTAssertEqual(Page2Apps.displayName("fileLibrary"), "文件库")
        XCTAssertEqual(Page2Apps.displayName("no-such-app"), "no-such-app")
        #if os(macOS)
        XCTAssertEqual(PermissionCenter.notInstalledLabel("fileLibrary"), "右栏里没开文件库")
        XCTAssertTrue(PermissionCenter.notInstalledDenial("fileLibrary").contains("设置 → 右栏"))
        #else
        XCTAssertEqual(PermissionCenter.notInstalledLabel("fileLibrary"), "主屏上没装文件库")
        XCTAssertTrue(PermissionCenter.notInstalledDenial("fileLibrary").contains("人页 › 权限"))
        #endif
        XCTAssertTrue(PermissionCenter.notInstalledDenial("fileLibrary").hasPrefix("permission_denied："))
        XCTAssertTrue(PermissionCenter.notInstalledDenial("fileLibrary").contains("「文件库」"))
        // 界面：这个人的表显示「不允许 · 原因」，默认目标不受门影响；只读档位带原因
        XCTAssertEqual(PermissionLevelPicker.blockedTitle(domain: .fileLibrary, target: .floor(a)),
                       "不允许 · \(PermissionCenter.notInstalledLabel("fileLibrary"))")
        XCTAssertNil(PermissionLevelPicker.blockedTitle(domain: .fileLibrary, target: .floor(b)))
        XCTAssertNil(PermissionLevelPicker.blockedTitle(domain: .fileLibrary, target: .defaults))
        XCTAssertEqual(PermissionLevelReadout.text(name: "云桥", level: .notAllowed, blockingApp: "health"),
                       "云桥：不允许 · \(PermissionCenter.notInstalledLabel("health"))")
    }

    // MARK: 「右栏」页「N 个人单独改了」

    func testOverridesCountOnlyExistingFloors() {
        let pa = Profile(id: a, name: "A", emoji: "", description: "", userName: "你", assistantName: "A")
        let pb = Profile(id: b, name: "B", emoji: "", description: "", userName: "你", assistantName: "B")
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: "xctest-gate-deleted")
        Page2Apps.setFloor(true, for: "fileLibrary", profileId: b)   // 等于默认 → 存成 nil，不算
        let rows = Page2AppOverridesPage.entries("fileLibrary", profiles: [pa, pb])
        XCTAssertEqual(rows.map(\.profile.id), [a], "删掉的层残留不算；和默认一样的不存")
        XCTAssertEqual(rows.first?.installed, false)
        XCTAssertTrue(Page2AppOverridesPage.entries("twitter", profiles: [pa, pb]).isEmpty)
        Page2Apps.clearFloor("fileLibrary")
        XCTAssertTrue(Page2Apps.overrides("fileLibrary").isEmpty, "都回到跟默认：残留层也清")
        XCTAssertNil(apps.defaults.object(forKey: Page2Apps.floorsKey), "全空删键")
    }
}
