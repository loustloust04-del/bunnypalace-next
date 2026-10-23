import XCTest

/// perf-flash 真手指翻页交叉验（plan-perf-flash §6 B4 / astra R2 M8）：XCUITest 坐标拖动驱动 1→0→1→2→1 × 4，
/// app 端 PerfHarness 被动模式（MP_PERF_OBSERVE=1）从 willEndDragging 回调现场起算，记完 16 次写
/// Documents/perf/run-<MP_PERF_RUNID>.json 后自行退出；host 拉 JSON 核 failures。
/// 同时是舞台模式 / 快照 / L4 下真实手势链路的功能冒烟（MP_PERF_STAGE / MP_PERF_SNAPFLIP / MP_PERF_L4 透传）。
/// UI 测试会开启无障碍树，数字只作与合成驱动的对照。
@MainActor
final class PerfFingerFlipUITests: XCTestCase {
    func testFingerFlips() {
        let app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        var launch = [
            "MP_PERF_OBSERVE": "1",
            "MP_PERF_VARIANT": env["MP_PERF_VARIANT"] ?? "finger",
            "MP_PERF_RUNID": env["MP_PERF_RUNID"] ?? "finger-\(Int(Date().timeIntervalSince1970))",
        ]
        for key in ["MP_PERF_STAGE", "MP_PERF_SNAPFLIP", "MP_PERF_L4"] { if let v = env[key] { launch[key] = v } }
        app.launchEnvironment = launch
        app.launchArguments = ["-onboardingCompletedV1", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["chat-input-field"].firstMatch.waitForExistence(timeout: 30))
        sleep(6)   // 冷启尾窗走完再开始翻
        var flips = 0
        for _ in 0..<4 {
            for left in [false, true, true, false] {
                guard app.state == .runningForeground else { break }
                app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.82 : 0.18, dy: 0.40))
                    .press(forDuration: 0.05,
                           thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.18 : 0.82, dy: 0.40)),
                           withVelocity: .default, thenHoldForDuration: 0)
                flips += 1
                Thread.sleep(forTimeInterval: 2.8)   // 就绪 0.5s 安静窗 + 1.5s 尾窗
            }
        }
        XCTAssertEqual(flips, 16, "拖动次数不足：app 提前退出或不在前台")
        // app 记满 16 次后自行 exit(0) 并写 JSON；等它退出，确认不是崩溃
        let exited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue), object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 20), .completed, "app 没按时写完结果退出")
    }
}
