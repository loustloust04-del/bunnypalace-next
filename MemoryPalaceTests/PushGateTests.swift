import XCTest
@testable import 记忆花园

/// 推送授权时机（plan-onboarding-xiaoya-impl §5.2 / H11）：新装正在走引导的等剧本收尾，其余老样子启动就请求
final class PushGateTests: XCTestCase {
    func testMatrix() {
        XCTAssertTrue(PushGate.requestsAtLaunch(legacyCompleted: true, xiaoyaState: nil), "旧键真的老用户")
        XCTAssertTrue(PushGate.requestsAtLaunch(legacyCompleted: false, xiaoyaState: "upgraded"), "没走完旧引导的老用户也照常请求")
        XCTAssertTrue(PushGate.requestsAtLaunch(legacyCompleted: false, xiaoyaState: "done"))
        XCTAssertFalse(PushGate.requestsAtLaunch(legacyCompleted: false, xiaoyaState: "started"), "新装在走引导：等收尾")
        XCTAssertFalse(PushGate.requestsAtLaunch(legacyCompleted: false, xiaoyaState: nil), "还没判出来（列表读坏）先不弹")
        XCTAssertTrue(PushGate.requestsAtLaunch(legacyCompleted: true, xiaoyaState: "started"), "旧键真优先")
    }

    func testReadsDefaults() throws {
        let suite = "PushGateTests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertFalse(PushGate.requestsAtLaunch(d))
        d.set("started", forKey: XiaoyaScriptRunner.onboardingKey)
        XCTAssertFalse(PushGate.requestsAtLaunch(d))
        d.set("done", forKey: XiaoyaScriptRunner.onboardingKey)
        XCTAssertTrue(PushGate.requestsAtLaunch(d))
    }
}
