import XCTest
import SwiftData
@testable import 记忆花园

/// 权限 P1（plan-权限管理 T10）：档位存取默认 / 迁移矩阵 / grants 编解码 / 工具域映射 / 注入判定。
@MainActor
final class PermissionCenterTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    /// 测试涉及的全部 UserDefaults key，setUp/tearDown 双向清场（防污染真库教训）。
    private var allKeys: [String] {
        var keys = PermissionDomain.allCases.flatMap { [$0.storageKey, $0.legacy.key] }
            + ["perm_migrated_v1", "ccNudgeEnabled"]
        #if PERSONAL_APPS
        keys.append("trading.nightly.enabled")
        #endif
        return keys
    }

    /// 测试宿主是真 app、`UserDefaults.standard` 是真 prefs 域：setUp 快照真值再清场，tearDown **恢复**而不是删——
    /// 原来的双向 removeObject 会把真 app 的档位和 `perm_migrated_v1` sentinel 一起抹掉，下次真 app 启动重跑迁移把用户自选档位重置（codex 评审）。
    private var snapshot: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(
            for: Conversation.self, MessageNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        snapshot = [:]
        for k in allKeys {
            if let v = UserDefaults.standard.object(forKey: k) { snapshot[k] = v }
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        for k in allKeys {
            if let v = snapshot[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    // MARK: 档位存取

    func testDefaultLevels_tightened() {
        // §4 收紧：健康组全关；基础能力保持开
        XCTAssertEqual(PermissionCenter.level(.healthWeight), .notAllowed)
        XCTAssertEqual(PermissionCenter.level(.healthApple), .notAllowed)
        XCTAssertEqual(PermissionCenter.level(.toolsMaster), .bypass)
        XCTAssertEqual(PermissionCenter.level(.fileLibrary), .bypass)
        XCTAssertEqual(PermissionCenter.level(.memory), .bypass)
    }

    func testSetLevel_projectsLegacyKeyAndSyncsSingleton() {
        #if PERSONAL_APPS
        PermissionCenter.setLevel(.bypass, for: .trading)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "trading.inject.watchlist") as? Bool, true)
        PermissionCenter.setLevel(.askOnce, for: .trading)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "trading.inject.watchlist") as? Bool, false)
        XCTAssertEqual(PermissionCenter.level(.trading), .askOnce)

        #endif
        // 单例缓存域：setLevel 必须踢 HealthService 运行态（verify 挑刺 #2）
        PermissionCenter.setLevel(.bypass, for: .healthApple)
        XCTAssertTrue(HealthService.shared.injectionEnabled)
        PermissionCenter.setLevel(.notAllowed, for: .healthApple)
        XCTAssertFalse(HealthService.shared.injectionEnabled)
    }

    // MARK: 迁移矩阵（显式开/显式关/无值 × 老装机/新装）

    func testMigration_explicitValuesMapToLevels() {
        UserDefaults.standard.set(true, forKey: "health.inject.weight")    // 显式开
        UserDefaults.standard.set(false, forKey: "sendToolsEnabled")       // 显式关
        PermissionCenter.migrateIfNeeded(container: container)
        XCTAssertEqual(PermissionCenter.level(.healthWeight), .bypass)
        XCTAssertEqual(PermissionCenter.level(.toolsMaster), .notAllowed)
    }

    func testMigration_existingInstallUnsetKeysGetOldDefaults() {
        // 老装机标记：库里有对话
        let conv = Conversation(id: "perm-mig-conv", title: "t", createTime: Date(), updateTime: Date(), currentNodeId: "", profileId: "p")
        context.insert(conv); try! context.save()
        PermissionCenter.migrateIfNeeded(container: container)
        // 体重旧默认开 → bypass（行为不变）；月经旧默认关 → notAllowed
        XCTAssertEqual(PermissionCenter.level(.healthWeight), .bypass)
        XCTAssertEqual(PermissionCenter.level(.healthCycle), .notAllowed)
        // §4 二值域保护：nudge/夜跑无显式值 → 写入旧默认 true
        XCTAssertEqual(UserDefaults.standard.object(forKey: "ccNudgeEnabled") as? Bool, true)
        #if PERSONAL_APPS
        XCTAssertEqual(UserDefaults.standard.object(forKey: "trading.nightly.enabled") as? Bool, true)
        #endif
        // shell 无历史 key：老装机迁移不写档位，新默认 askOnce 生效（plan-离线沙箱-phase1，粟粟拍）
        XCTAssertNil(UserDefaults.standard.object(forKey: PermissionDomain.shell.storageKey))
        XCTAssertEqual(PermissionCenter.level(.shell), .askOnce)
    }

    func testMigration_freshInstallGetsTightenedDefaults() {
        PermissionCenter.migrateIfNeeded(container: container)   // 库空 = 新装
        XCTAssertEqual(PermissionCenter.level(.healthWeight), .notAllowed)   // 新默认生效
        XCTAssertNil(UserDefaults.standard.object(forKey: "ccNudgeEnabled")) // 二值域不写 → 声明默认 false
    }

    func testMigration_sentinelPreventsRerun() {
        PermissionCenter.migrateIfNeeded(container: container)
        UserDefaults.standard.set(true, forKey: "health.inject.weight")
        PermissionCenter.migrateIfNeeded(container: container)   // 第二次不该重跑
        XCTAssertEqual(PermissionCenter.level(.healthWeight), .notAllowed)   // 仍是首轮结果
    }

    // MARK: grants 编解码 + 判定

    func testGrantsCodecAndIdempotence() {
        var g = PermissionGrants(raw: nil)
        XCTAssertFalse(g.isResolved(.healthMeds))
        g.record(.healthMeds, allow: true)
        #if PERSONAL_APPS
        XCTAssertFalse(g.isResolved(.trading))
        g.record(.trading, allow: true)
        #endif
        g.record(.healthWeight, allow: false)
        let round = PermissionGrants(raw: g.raw)
        XCTAssertTrue(round.isAllowed(.healthMeds))
        #if PERSONAL_APPS
        XCTAssertTrue(round.isAllowed(.trading))
        #endif
        XCTAssertTrue(round.isResolved(.healthWeight))
        XCTAssertFalse(round.isAllowed(.healthWeight))
        // 改判幂等：deny → allow 覆盖不叠加
        g.record(.healthWeight, allow: true)
        XCTAssertTrue(PermissionGrants(raw: g.raw).isAllowed(.healthWeight))
    }

    func testInjectionAllowed_threeLevels() {
        // 共享域样本：三档都显式设，不依赖默认档位
        var shared = PermissionGrants(raw: nil)
        PermissionCenter.setLevel(.bypass, for: .healthWeight)
        XCTAssertTrue(PermissionCenter.injectionAllowed(.healthWeight, grants: shared))
        PermissionCenter.setLevel(.notAllowed, for: .healthWeight)
        XCTAssertFalse(PermissionCenter.injectionAllowed(.healthWeight, grants: shared))
        PermissionCenter.setLevel(.askOnce, for: .healthWeight)
        XCTAssertFalse(PermissionCenter.injectionAllowed(.healthWeight, grants: shared))   // 未答 = 安全缺省不注入
        shared.record(.healthWeight, allow: true)
        XCTAssertTrue(PermissionCenter.injectionAllowed(.healthWeight, grants: shared))

        #if PERSONAL_APPS
        var g = PermissionGrants(raw: nil)
        PermissionCenter.setLevel(.bypass, for: .trading)
        XCTAssertTrue(PermissionCenter.injectionAllowed(.trading, grants: g))
        PermissionCenter.setLevel(.notAllowed, for: .trading)
        XCTAssertFalse(PermissionCenter.injectionAllowed(.trading, grants: g))
        PermissionCenter.setLevel(.askOnce, for: .trading)
        XCTAssertFalse(PermissionCenter.injectionAllowed(.trading, grants: g))   // 未答 = 安全缺省不注入
        g.record(.trading, allow: true)
        XCTAssertTrue(PermissionCenter.injectionAllowed(.trading, grants: g))
        #endif
    }

    // MARK: 工具域映射

    func testForToolMapping() {
        XCTAssertEqual(PermissionDomain.forTool(named: "fs_read"), .fileLibrary)
        XCTAssertEqual(PermissionDomain.forTool(named: "update_profile_card"), .fileLibrary)
        XCTAssertEqual(PermissionDomain.forTool(named: "search_web"), .webSearch)
        XCTAssertEqual(PermissionDomain.forTool(named: "browse_url"), .webSearch)
        XCTAssertEqual(PermissionDomain.forTool(named: "some_mcp_tool"), .toolsMaster)
    }

    #if PERSONAL_APPS
    // MARK: 组合器走 grants（实发路径同源）

    func testComposedSummariesRespectGrants() {
        PermissionCenter.setLevel(.askOnce, for: .trading)
        var g = PermissionGrants(raw: nil)
        XCTAssertEqual(TradingStore.composedTradingSummary(context: context, profileId: "p", grants: g), "")
        g.record(.trading, allow: true)
        // 允许后闸开（无数据仍为空串，但不再被闸拦——语义由上面的 injectionAllowed 用例锚定）
        XCTAssertTrue(PermissionCenter.injectionAllowed(.trading, grants: g))
    }
    #endif
}
