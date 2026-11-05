import XCTest
@testable import 记忆花园

/// 小芽引导新装判定（plan-onboarding-xiaoya-impl §5.1）：只认「什么都没有」的机器，老用户一律 upgraded
final class FreshInstallProbeTests: XCTestCase {
    private let seedIds = ["default-workspace"]
    private let autoCards = ["cc-bridge", "codex-bridge", APICredential.exampleId, APICredential.localId, "chatgpt-oauth"]

    /// counted：对话数闭包被调了几次（能定的不该碰库）
    private final class Counter { var calls = 0 }

    private func decide(trusted: Bool = true, legacy: Bool = false, profiles: [String]? = nil, credentials: [String]? = nil,
                        cards: [String] = [CardSample.id], cardsTrusted: Bool = true, conversations: Int? = 0,
                        counter: Counter = Counter()) -> FreshInstallProbe.Decision? {
        FreshInstallProbe.decide(profilesTrusted: trusted, legacyCompleted: legacy, profileIds: profiles ?? seedIds,
                                 credentialIds: credentials ?? autoCards, cardIds: cards, cardsTrusted: cardsTrusted,
                                 conversationCount: { counter.calls += 1; return conversations })
    }

    func testOnlySeedsNoDataIsFresh() {
        XCTAssertEqual(decide(), .started)
        XCTAssertEqual(decide(credentials: [], cards: []), .started)
    }

    func testReadOnlyListDoesNotDecide() {
        XCTAssertNil(decide(trusted: false))
        XCTAssertNil(decide(trusted: false, legacy: true), "只读时连旧键都不看：不判、不写")
    }

    func testLegacyCompletedIsUpgradedWithoutCounting() {
        let counter = Counter()
        XCTAssertEqual(decide(legacy: true, counter: counter), .upgraded)
        XCTAssertEqual(counter.calls, 0, "能定的不碰库")
    }

    /// research §4 最大的坑：没走完旧六页（旧键假）但用过 App 的老用户
    func testUsedAppWithoutFinishingOldOnboardingIsUpgraded() {
        XCTAssertEqual(decide(conversations: 3), .upgraded, "有对话")
        XCTAssertEqual(decide(profiles: ["default-workspace", "her-floor"]), .upgraded, "有自己的楼层")
        XCTAssertEqual(decide(credentials: autoCards + ["cred-1234"]), .upgraded, "有自建 API 卡")
        XCTAssertEqual(decide(cards: [CardSample.id, "card-1"]), .upgraded, "卡库有她导的卡")
    }

    func testAutoSeededCardsAndSampleCardDoNotCount() {
        XCTAssertEqual(decide(credentials: autoCards, cards: [CardSample.id]), .started)
    }

    func testCountOnlyWhenEverythingElseLooksFresh() {
        let counter = Counter()
        XCTAssertEqual(decide(profiles: ["her"], counter: counter), .upgraded)
        XCTAssertEqual(counter.calls, 0)
        XCTAssertEqual(decide(counter: counter), .started)
        XCTAssertEqual(counter.calls, 1)
    }

    func testUnreadableCountDoesNotDecide() {
        XCTAssertNil(decide(conversations: nil))
    }

    /// sol #7：卡库读坏时 cards 是空数组，不等于卡库空——不判（不写键），下次启动再判
    func testUnreadableCardLibraryDoesNotDecide() throws {
        let counter = Counter()
        XCTAssertNil(decide(cards: [], cardsTrusted: false, counter: counter))
        XCTAssertNil(decide(legacy: true, cardsTrusted: false), "同楼层列表读坏：连旧键都不看")
        XCTAssertEqual(counter.calls, 0, "不知道就不碰库")
        let (d, suite) = try makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertNil(FreshInstallProbe.runOnce(defaults: d, profilesTrusted: true, profileIds: seedIds, credentialIds: autoCards,
                                               cardIds: [], cardsTrusted: false, conversationCount: { 0 }))
        XCTAssertNil(d.string(forKey: XiaoyaScriptRunner.onboardingKey))
    }

    // MARK: runOnce：写键、只判一次

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "FreshInstallProbeTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func runOnce(_ d: UserDefaults, trusted: Bool = true, conversations: Int = 0) -> FreshInstallProbe.Decision? {
        FreshInstallProbe.runOnce(defaults: d, profilesTrusted: trusted, profileIds: seedIds, credentialIds: autoCards,
                                  cardIds: [], cardsTrusted: true, conversationCount: { conversations })
    }

    func testRunOnceWritesKeyAndNeverDecidesAgain() throws {
        let (d, suite) = try makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(runOnce(d), .started)
        XCTAssertEqual(d.string(forKey: XiaoyaScriptRunner.onboardingKey), "started")
        XCTAssertNil(runOnce(d), "判过就不再判（重启后不会再从开场放）")
        d.set("done", forKey: XiaoyaScriptRunner.onboardingKey)
        XCTAssertNil(runOnce(d))
        XCTAssertEqual(d.string(forKey: XiaoyaScriptRunner.onboardingKey), "done")
    }

    func testRunOnceUpgradedWritesKey() throws {
        let (d, suite) = try makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        d.set(true, forKey: XiaoyaScriptRunner.legacyCompletedKey)
        XCTAssertEqual(runOnce(d), .upgraded)
        XCTAssertEqual(d.string(forKey: XiaoyaScriptRunner.onboardingKey), "upgraded")
    }

    func testRunOnceReadOnlyWritesNothing() throws {
        let (d, suite) = try makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertNil(runOnce(d, trusted: false))
        XCTAssertNil(d.string(forKey: XiaoyaScriptRunner.onboardingKey), "下次启动再判")
        XCTAssertEqual(runOnce(d, conversations: 5), .upgraded)
    }
}
