import XCTest
@testable import 记忆花园

/// 测试用：`PermissionCenter` 换到独立 suite（真 prefs 不碰），`leave()` 换回原来的并删掉 suite
final class PermissionSandbox {
    let defaults: UserDefaults
    private let name = "xctest-perm-\(UUID().uuidString)"
    private let previous: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
        previous = PermissionCenter.defaults
        PermissionCenter.defaults = defaults
    }

    func leave() {
        PermissionCenter.defaults = previous
        defaults.removePersistentDomain(forName: name)
    }
}

/// atrium P3⑤0：`PermissionFloors` 解析三类规则 / 存取 / 写入口 / 读缓存（plan-atrium-p3-permissions §2.4）
final class PermissionFloorsTests: XCTestCase {

    private var sandbox: PermissionSandbox!
    private let a = "xctest-floor-a"
    private let b = "xctest-floor-b"

    override func setUp() {
        super.setUp()
        sandbox = PermissionSandbox()
    }

    override func tearDown() {
        sandbox.leave()
        sandbox = nil
        super.tearDown()
    }

    private var storedData: Data? { sandbox.defaults.data(forKey: PermissionCenter.floorsKey) }

    private func writeRaw(_ floors: [String: [String: Int]]) {
        sandbox.defaults.set(PermissionFloors(floors: floors).encoded(), forKey: PermissionCenter.floorsKey)
    }

    // MARK: 解析表

    func testEmptyFloorsFollowDefault() {
        for d in PermissionDomain.allCases {
            XCTAssertEqual(PermissionCenter.level(d, profileId: a), d.defaultLevel, "\(d)")
            XCTAssertEqual(PermissionCenter.level(d, profileId: nil), d.defaultLevel, "\(d)")
        }
        PermissionCenter.setDefaultLevel(.askOnce, for: .images)
        XCTAssertEqual(PermissionCenter.level(.images, profileId: a), .askOnce, "层空 = 跟着默认变")
        XCTAssertNil(storedData, "改默认不碰层设置")
    }

    func testFreeDomainOverridesBothWays() {
        PermissionCenter.setDefaultLevel(.notAllowed, for: .healthWeight)
        PermissionCenter.setDefaultLevel(.bypass, for: .fileLibrary)
        PermissionCenter.setFloorLevel(.bypass, for: .healthWeight, profileId: a)      // 比默认宽
        PermissionCenter.setFloorLevel(.notAllowed, for: .fileLibrary, profileId: a)   // 比默认严
        XCTAssertEqual(PermissionCenter.level(.healthWeight, profileId: a), .bypass)
        XCTAssertEqual(PermissionCenter.level(.fileLibrary, profileId: a), .notAllowed)
        XCTAssertEqual(PermissionCenter.level(.healthWeight, profileId: b), .notAllowed, "B 跟默认")
        XCTAssertEqual(PermissionCenter.level(.fileLibrary, profileId: b), .bypass)
        XCTAssertEqual(PermissionCenter.defaultLevel(.healthWeight), .notAllowed, "层不影响默认")
        XCTAssertFalse(PermissionCenter.capabilityEnabled(.fileLibrary, profileId: a))
        XCTAssertTrue(PermissionCenter.capabilityEnabled(.fileLibrary, profileId: b))
    }

    func testGlobalOnlyIgnoresFloorValues() {
        // 写入口拒写，直接塞数据模拟（老版本 / 手改）
        writeRaw([a: ["toolsMaster": PermissionLevel.notAllowed.rawValue,
                      "pocket": PermissionLevel.bypass.rawValue,
                      "memory": PermissionLevel.notAllowed.rawValue]])
        XCTAssertEqual(PermissionCenter.level(.toolsMaster, profileId: a), .bypass)
        XCTAssertEqual(PermissionCenter.level(.pocket, profileId: a), .notAllowed)
        XCTAssertEqual(PermissionCenter.level(.memory, profileId: a), .bypass)
        let floors = PermissionCenter.floors()
        for d in [PermissionDomain.toolsMaster, .pocket, .memory] {
            XCTAssertEqual(d.floorRule, .globalOnly)
            XCTAssertEqual(PermissionFloors.resolve(d, profileId: a, defaultLevel: d.defaultLevel, floors: floors), d.defaultLevel, "\(d)")
        }
    }

    func testStricterOnlyTakesMax() {
        XCTAssertEqual(PermissionDomain.shell.floorRule, .stricterOnly)
        XCTAssertEqual(PermissionCenter.defaultLevel(.shell), .askOnce)
        writeRaw([a: ["shell": PermissionLevel.bypass.rawValue], b: ["shell": PermissionLevel.notAllowed.rawValue]])
        XCTAssertEqual(PermissionCenter.level(.shell, profileId: a), .askOnce, "层上更宽不生效")
        XCTAssertEqual(PermissionCenter.level(.shell, profileId: b), .notAllowed)
        // 默认追上来再放宽：层上那条留着，重新生效（plan §6-7）
        PermissionCenter.setDefaultLevel(.notAllowed, for: .shell)
        XCTAssertEqual(PermissionCenter.level(.shell, profileId: b), .notAllowed)
        PermissionCenter.setDefaultLevel(.bypass, for: .shell)
        XCTAssertEqual(PermissionCenter.level(.shell, profileId: b), .notAllowed)
        XCTAssertEqual(PermissionCenter.level(.shell, profileId: a), .bypass, "默认放宽到 bypass，A 层的 bypass 不比它严")
        #if os(macOS)
        XCTAssertEqual(PermissionDomain.codingSessions.floorRule, .stricterOnly)
        #endif
    }

    func testNilOrUnknownProfileFollowsDefault() {
        PermissionCenter.setFloorLevel(.bypass, for: .webSearch, profileId: a)
        XCTAssertEqual(PermissionCenter.level(.webSearch, profileId: nil), .notAllowed)
        XCTAssertEqual(PermissionCenter.level(.webSearch, profileId: "xctest-no-such-floor"), .notAllowed)
        XCTAssertEqual(PermissionCenter.level(.webSearch, profileId: a), .bypass)
    }

    // MARK: 存取

    func testCodableRoundTripKeepsUnknownKeys() throws {
        // 认不出的域（别的编译条件 / 以后的版本）和认不出的档位原样留着
        writeRaw([a: ["futureDomain": 1, "images": 7], b: ["images": PermissionLevel.notAllowed.rawValue]])
        XCTAssertEqual(PermissionCenter.level(.images, profileId: a), .bypass, "认不出的档位 = 跟默认")
        PermissionCenter.setFloorLevel(.notAllowed, for: .webSearch, profileId: a)
        let floors = try XCTUnwrap(PermissionFloors.decoded(storedData))
        XCTAssertEqual(floors.floors[a]?["futureDomain"], 1)
        XCTAssertEqual(floors.floors[a]?["images"], 7)
        XCTAssertEqual(floors.floors[a]?["webSearch"], PermissionLevel.notAllowed.rawValue)
        XCTAssertEqual(floors.floors[b]?["images"], PermissionLevel.notAllowed.rawValue)
        XCTAssertEqual(PermissionFloors.decoded(floors.encoded()), floors)
        XCTAssertEqual(PermissionFloors.decoded(nil), PermissionFloors())
    }

    func testBadJSONReadsEmptyAndRefusesWrites() {
        let junk = Data("{not json".utf8)
        sandbox.defaults.set(junk, forKey: PermissionCenter.floorsKey)
        XCTAssertNil(PermissionFloors.decoded(junk))
        XCTAssertEqual(PermissionCenter.level(.webSearch, profileId: a), .notAllowed, "解不开 = 当空 = 默认")
        PermissionCenter.setFloorLevel(.bypass, for: .webSearch, profileId: a)
        PermissionCenter.clearAll(profileId: a)
        PermissionCenter.clearFloor(.webSearch)
        PermissionCenter.copyFloor(from: a, to: b)
        XCTAssertEqual(storedData, junk, "写入口拒写，不覆盖")
    }

    // MARK: 写入口

    func testSetFloorLevelRules() {
        PermissionCenter.setFloorLevel(.notAllowed, for: .toolsMaster, profileId: a)
        PermissionCenter.setFloorLevel(.bypass, for: .memory, profileId: a)
        PermissionCenter.setFloorLevel(.bypass, for: .pocket, profileId: a)
        XCTAssertNil(storedData, "只全局的域拒写")

        PermissionCenter.setFloorLevel(.bypass, for: .shell, profileId: a)
        PermissionCenter.setFloorLevel(.askOnce, for: .shell, profileId: a)
        XCTAssertNil(storedData, "只能更严：不比默认严的存成 nil")
        PermissionCenter.setFloorLevel(.notAllowed, for: .shell, profileId: a)
        XCTAssertEqual(PermissionCenter.floors().stored(.shell, profileId: a), .notAllowed)
        PermissionCenter.setFloorLevel(.askOnce, for: .shell, profileId: a)
        XCTAssertNil(storedData, "改回不严的 = 删这条，层空了删整层、键也删")

        PermissionCenter.setFloorLevel(.bypass, for: .twitter, profileId: a)
        XCTAssertEqual(PermissionCenter.floors().stored(.twitter, profileId: a), .bypass, "自由域和默认一样也照存（单独设过）")
        PermissionCenter.setFloorLevel(nil, for: .twitter, profileId: a)
        XCTAssertNil(storedData)
    }

    func testClearCopyAndOverrides() {
        PermissionCenter.setFloorLevel(.notAllowed, for: .images, profileId: a)
        PermissionCenter.setFloorLevel(.bypass, for: .webSearch, profileId: a)
        PermissionCenter.setFloorLevel(.askOnce, for: .images, profileId: b)
        XCTAssertEqual(PermissionCenter.overrides(.images), [a: .notAllowed, b: .askOnce])
        XCTAssertEqual(PermissionCenter.overrides(.webSearch), [a: .bypass])
        XCTAssertEqual(PermissionCenter.overrides(.calendar), [:])

        let c = "xctest-floor-c"
        PermissionCenter.copyFloor(from: a, to: c)
        XCTAssertEqual(PermissionCenter.level(.images, profileId: c), .notAllowed)
        XCTAssertEqual(PermissionCenter.level(.webSearch, profileId: c), .bypass)
        let d = "xctest-floor-d"
        PermissionCenter.copyFloor(from: "xctest-floor-empty", to: d)
        XCTAssertNil(PermissionCenter.floors().floors[d], "来源跟默认 → 新层也空")

        PermissionCenter.clearFloor(.images)
        XCTAssertEqual(PermissionCenter.overrides(.images), [:])
        XCTAssertNil(PermissionCenter.floors().floors[b], "B 只设了图片，清完整层删掉")
        XCTAssertEqual(PermissionCenter.overrides(.webSearch), [a: .bypass, c: .bypass])

        PermissionCenter.clearAll(profileId: a)
        XCTAssertEqual(PermissionCenter.overrides(.webSearch), [c: .bypass])
        PermissionCenter.clearAll(profileId: c)
        XCTAssertNil(storedData)
    }

    // MARK: 读缓存

    func testCacheSeesDefaultsChanges() {
        XCTAssertEqual(PermissionCenter.level(.calendar, profileId: a), .notAllowed)
        writeRaw([a: ["calendar": PermissionLevel.bypass.rawValue]])
        XCTAssertEqual(PermissionCenter.level(.calendar, profileId: a), .bypass, "绕过写入口改了 defaults，下一次读就是新值")
        writeRaw([a: ["calendar": PermissionLevel.askOnce.rawValue]])
        XCTAssertEqual(PermissionCenter.level(.calendar, profileId: a), .askOnce)
        sandbox.defaults.removeObject(forKey: PermissionCenter.floorsKey)
        XCTAssertEqual(PermissionCenter.level(.calendar, profileId: a), .notAllowed)
        // 换 defaults 实例：缓存跟着作废
        let other = PermissionSandbox()
        XCTAssertEqual(PermissionCenter.level(.calendar, profileId: a), .notAllowed)
        PermissionCenter.setFloorLevel(.bypass, for: .calendar, profileId: a)
        other.leave()
        XCTAssertEqual(PermissionCenter.level(.calendar, profileId: a), .notAllowed, "回到原 suite，看不到另一个 suite 写的")
    }
}
