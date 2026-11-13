import XCTest
@testable import MemoryCore

final class RecallTuningTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "xctest-recall-tuning-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testFactoryDefaultsAndMissingFloor() {
        let expected = RecallTestTuning.make(archiveTriggerEnabled: false)
        XCTAssertEqual(RecallTuning.defaults, expected)
        XCTAssertEqual(RecallTuningStore.load(profileId: "岚舟", defaults: defaults), expected)
        XCTAssertNil(defaults.object(forKey: RecallTuningStore.storageKey), "读取缺省值不写入存储")
    }

    func testExplicitProfilesRemainIsolatedAndLatestLoadIsImmediate() {
        var first = RecallTestTuning.make()
        first.minimumEffectiveLength = 9
        first.cooldownTurns = 7
        var second = RecallTestTuning.make()
        second.minimumEffectiveLength = 11
        second.cooldownTurns = 0
        RecallTuningStore.save(first, profileId: "岚舟", defaults: defaults)
        RecallTuningStore.save(second, profileId: "星砚", defaults: defaults)
        // 显式 ID 不受当前全局选择影响，新轮每次 load 即拿到该层最新配置。
        defaults.set("星砚", forKey: "lastProfileId")
        XCTAssertEqual(RecallTuningStore.load(profileId: "岚舟", defaults: defaults), first)
        XCTAssertEqual(RecallTuningStore.load(profileId: "星砚", defaults: defaults), second)
        first.maximumPages = 8
        RecallTuningStore.save(first, profileId: "岚舟", defaults: defaults)
        XCTAssertEqual(RecallTuningStore.load(profileId: "岚舟", defaults: defaults), first)
        XCTAssertEqual(RecallTuningStore.load(profileId: "星砚", defaults: defaults), second)
        XCTAssertEqual(RecallTuningStore.load(profileId: "云桥城", defaults: defaults), RecallTestTuning.make(archiveTriggerEnabled: false))
    }

    func testResetOnlyRemovesSpecifiedFloor() {
        var first = RecallTestTuning.make()
        first.maximumRecallCalls = 12
        var second = RecallTestTuning.make()
        second.wikiPageRecords = 25
        RecallTuningStore.save(first, profileId: "岚舟", defaults: defaults)
        RecallTuningStore.save(second, profileId: "星砚", defaults: defaults)
        RecallTuningStore.reset(profileId: "岚舟", defaults: defaults)
        XCTAssertEqual(RecallTuningStore.load(profileId: "岚舟", defaults: defaults), RecallTuning.defaults)
        XCTAssertEqual(RecallTuningStore.load(profileId: "星砚", defaults: defaults), second)
        RecallTuningStore.reset(profileId: "星砚", defaults: defaults)
        XCTAssertNil(defaults.object(forKey: RecallTuningStore.storageKey))
        XCTAssertEqual(RecallTuningStore.load(profileId: "星砚", defaults: defaults), RecallTuning.defaults)
    }

    func testAllFieldsPersistThroughIndependentDefaultsInstance() throws {
        var expected = RecallTestTuning.make()
        RecallTuning.Field.maximumResponseCharacters.set(RecallTuning.Field.maximumResponseCharacters.range.upperBound, in: &expected)
        for field in RecallTuning.Field.allCases {
            field.set(field.range.upperBound, in: &expected)
        }
        RecallTuningStore.save(expected, profileId: "林栖", defaults: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let result = RecallTuningStore.load(profileId: "林栖", defaults: reopened)
        XCTAssertEqual(result, expected)
        let data = try XCTUnwrap(reopened.data(forKey: RecallTuningStore.storageKey))
        let archive = try JSONDecoder().decode([String: RecallTuning].self, from: data)
        XCTAssertEqual(archive["林栖"], expected)
    }

    func testLegacyMissingFieldsUseFactoryValuesWithoutReadingOldGlobalSettings() throws {
        defaults.set(99, forKey: "mem_self_recent_count")
        defaults.set(999, forKey: "mem_inject_budget")
        defaults.set(Data("{\"岚舟\":{\"minimumEffectiveLength\":12}}".utf8), forKey: RecallTuningStore.storageKey)
        var expected = RecallTestTuning.make(archiveTriggerEnabled: false)
        expected.minimumEffectiveLength = 12
        XCTAssertEqual(RecallTuningStore.load(profileId: "岚舟", defaults: defaults), expected)
        XCTAssertEqual(try JSONDecoder().decode(RecallTuning.self, from: Data("{}".utf8)), RecallTestTuning.make(archiveTriggerEnabled: false))
    }

    func testEveryFieldClampsAtBothLegalBoundariesOnSave() {
        for field in RecallTuning.Field.allCases {
            var low = RecallTestTuning.make()
            var high = RecallTestTuning.make()
            if let path = field.integerKeyPath {
                low[keyPath: path] = Int(field.range.lowerBound) - 1
                high[keyPath: path] = Int(field.range.upperBound) + 1
            } else if field == .activeOverlapThreshold {
                low.activeOverlapThreshold = -0.25
                high.activeOverlapThreshold = 1.25
            } else {
                low.fullTextCoverageThreshold = -0.25
                high.fullTextCoverageThreshold = 1.25
            }
            RecallTuningStore.save(low, profileId: "岚舟", defaults: defaults)
            RecallTuningStore.save(high, profileId: "星砚", defaults: defaults)
            XCTAssertEqual(field.value(in: RecallTuningStore.load(profileId: "岚舟", defaults: defaults)), field.range.lowerBound, field.rawValue)
            let expectedHigh = field == .maximumBodyCharacters
                ? Double(high.maximumResponseCharacters) : field.range.upperBound
            XCTAssertEqual(field.value(in: RecallTuningStore.load(profileId: "星砚", defaults: defaults)), expectedHigh, field.rawValue)
        }
    }

    func testImportedSettingsRespectAllRangesAtTheStoreBoundary() throws {
        var raw: [String: Any] = ["schemaVersion": 1]
        for field in RecallTuning.Field.allCases {
            if field.isFraction {
                raw[field.rawValue] = field.range.upperBound + 1
            } else {
                raw[field.rawValue] = Int(field.range.upperBound) + 1
            }
        }
        defaults.set(try JSONSerialization.data(withJSONObject: ["林栖": raw]), forKey: RecallTuningStore.storageKey)
        let result = RecallTuningStore.load(profileId: "林栖", defaults: defaults)
        for field in RecallTuning.Field.allCases {
            XCTAssertEqual(field.value(in: result), field.range.upperBound, field.rawValue)
        }
    }

    func testHistoricalSnapshotDecodingDoesNotRewriteVersionOrPreviouslyUsedParameters() throws {
        var historical = RecallTestTuning.make()
        historical.schemaVersion = 17
        historical.minimumEffectiveLength = 101
        historical.activeOverlapThreshold = 1.25
        historical.maximumBodyCharacters = 30000
        historical.maximumResponseCharacters = 100
        let data = try JSONEncoder().encode(historical)
        XCTAssertEqual(try JSONDecoder().decode(RecallTuning.self, from: data), historical,
                       "范围校正只在设置入口发生，历史决策必须保留当时实际使用的参数")
    }

    func testSettingsEditsKeepBodyWithinResponseWithoutIncreasingTotalBudget() {
        var tuning = RecallTestTuning.make()
        RecallTuning.Field.maximumBodyCharacters.set(30000, in: &tuning)
        XCTAssertEqual(tuning.maximumBodyCharacters, 4000)
        XCTAssertEqual(tuning.maximumResponseCharacters, 4000)

        RecallTuning.Field.maximumResponseCharacters.set(500, in: &tuning)
        XCTAssertEqual(tuning.maximumBodyCharacters, 500)
        XCTAssertEqual(tuning.maximumResponseCharacters, 500)

        RecallTuning.Field.maximumResponseCharacters.set(8000, in: &tuning)
        XCTAssertEqual(tuning.maximumBodyCharacters, 500, "增大总预算不能擅自增大正文")
        RecallTuning.Field.maximumBodyCharacters.set(6000, in: &tuning)
        XCTAssertEqual(tuning.maximumBodyCharacters, 6000)
        XCTAssertEqual(tuning.maximumResponseCharacters, 8000)
    }

    func testSavingCrossFieldLimitsClampsBodyAndPreservesOtherSettings() {
        var tuning = RecallTestTuning.make()
        tuning.maximumBodyCharacters = 30000
        tuning.maximumResponseCharacters = 200
        tuning.cooldownTurns = 0
        tuning.maximumRecallCalls = 7
        RecallTuningStore.save(tuning, profileId: "岚舟", defaults: defaults)
        let stored = RecallTuningStore.load(profileId: "岚舟", defaults: defaults)
        tuning.maximumBodyCharacters = 200
        XCTAssertEqual(stored, tuning)
    }

    func testImportedCrossFieldLimitsNormalizeAgainstImportedResponseRatherThanFactoryBudget() throws {
        let cases = [(30000, 100, 100), (30000, 40000, 30000), (50000, 50000, 30000), (-1, -1, 100)]
        for (body, response, expectedBody) in cases {
            let archive = ["林栖": ["maximumBodyCharacters": body, "maximumResponseCharacters": response]]
            defaults.set(try JSONSerialization.data(withJSONObject: archive), forKey: RecallTuningStore.storageKey)
            let result = RecallTuningStore.load(profileId: "林栖", defaults: defaults)
            XCTAssertEqual(result.maximumBodyCharacters, expectedBody)
            XCTAssertLessThanOrEqual(result.maximumBodyCharacters, result.maximumResponseCharacters)
        }
    }

    func testNonFiniteRatiosFallBackWithoutLosingOtherFields() {
        var expected = RecallTestTuning.make()
        expected.maximumQueryTerms = 13
        var invalid = expected
        invalid.activeOverlapThreshold = .nan
        invalid.fullTextCoverageThreshold = .infinity
        RecallTuningStore.save(invalid, profileId: "云桥城", defaults: defaults)
        XCTAssertEqual(RecallTuningStore.load(profileId: "云桥城", defaults: defaults), expected)
    }

    func testMalformedArchiveUsesFactoryValues() {
        defaults.set(Data("not-a-settings-archive".utf8), forKey: RecallTuningStore.storageKey)
        XCTAssertEqual(RecallTuningStore.load(profileId: "林栖", defaults: defaults), RecallTestTuning.make(archiveTriggerEnabled: false))
    }

    func testOldJSONKeepsNumbersAndSuppliesNewSwitchDefaults() throws {
        let decoded = try JSONDecoder().decode(RecallTuning.self, from: Data("""
        {"schemaVersion":1,"cooldownTurns":9,"maximumPages":7,"maximumRecallCalls":4}
        """.utf8))
        XCTAssertFalse(decoded.archiveTriggerEnabled)
        XCTAssertTrue(decoded.cooldownEnabled)
        XCTAssertEqual(decoded.cooldownTurns, 9)
        XCTAssertEqual(decoded.maximumPages, 7)
        XCTAssertEqual(decoded.maximumRecallCalls, 4)
        var changed = decoded
        changed.archiveTriggerEnabled = true
        changed.cooldownEnabled = false
        RecallTuningStore.save(changed, profileId: "synthetic", defaults: defaults)
        XCTAssertEqual(RecallTuningStore.load(profileId: "synthetic", defaults: defaults), changed)
    }

    func testPageResetPreservesOtherPagePrimaryControlsAndOtherFloor() {
        var custom = RecallTestTuning.make()
        custom.cooldownEnabled = false
        custom.minimumEffectiveLength = 17
        custom.maximumPages = 8
        custom.maximumRecallCalls = 11
        custom.maximumResponseCharacters = 9000
        custom.previousWindowMessages = 19
        RecallTuningStore.save(custom, profileId: "first", defaults: defaults)
        RecallTuningStore.save(custom, profileId: "second", defaults: defaults)
        RecallTuningStore.reset(profileId: "first", fields: RecallTuning.Field.archiveTriggerFields, defaults: defaults)
        var expected = custom
        expected.minimumEffectiveLength = RecallTuning.defaults.minimumEffectiveLength
        XCTAssertEqual(RecallTuningStore.load(profileId: "first", defaults: defaults), expected)
        XCTAssertEqual(RecallTuningStore.load(profileId: "second", defaults: defaults), custom)
        RecallTuningStore.reset(profileId: "first", fields: RecallTuning.Field.recallBrowseFields, defaults: defaults)
        expected.maximumRecallCalls = RecallTuning.defaults.maximumRecallCalls
        expected.maximumResponseCharacters = RecallTuning.defaults.maximumResponseCharacters
        XCTAssertEqual(RecallTuningStore.load(profileId: "first", defaults: defaults), expected)
        XCTAssertEqual(RecallTuningStore.load(profileId: "second", defaults: defaults), custom)
    }

    func testBrowseResetRestoresBodyAfterPreviouslyTightResponseBudget() {
        var custom = RecallTuning.defaults
        custom.maximumBodyCharacters = 100
        custom.maximumResponseCharacters = 100
        RecallTuningStore.save(custom, profileId: "tight", defaults: defaults)
        RecallTuningStore.reset(profileId: "tight", fields: RecallTuning.Field.recallBrowseFields, defaults: defaults)
        XCTAssertEqual(RecallTuningStore.load(profileId: "tight", defaults: defaults), RecallTuning.defaults)
    }

}
