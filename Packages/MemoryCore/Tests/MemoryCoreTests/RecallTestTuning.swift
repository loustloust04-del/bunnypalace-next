@testable import MemoryCore

/// 测试规则必须显式给全字段，不把出厂默认值当作隐式规则输入。
enum RecallTestTuning {
    static func make(archiveTriggerEnabled: Bool = true) -> RecallTuning {
        RecallTuning(
            schemaVersion: 1,
            archiveTriggerEnabled: archiveTriggerEnabled,
            cooldownEnabled: true,
            minimumEffectiveLength: 4,
            minimumSharedTerms: 2,
            activeOverlapThreshold: 0.5,
            cooldownTurns: 3,
            identityLookbackMessages: 4,
            maximumPages: 3,
            maximumQueryTerms: 6,
            minimumHanTermLength: 2,
            minimumLatinTermLength: 3,
            minimumFullTextTerms: 2,
            fullTextCoverageThreshold: 0.6,
            previousWindowMessages: 6,
            maximumRecallCalls: 3,
            maximumBodyCharacters: 3000,
            maximumResponseCharacters: 4000,
            datePageDays: 1,
            datePageEvents: 12,
            windowPageSegments: 10,
            searchPageResults: 5,
            wikiIndexPageLines: 30,
            wikiPageRecords: 10,
            originalPageMessages: 8
        )
    }
}
