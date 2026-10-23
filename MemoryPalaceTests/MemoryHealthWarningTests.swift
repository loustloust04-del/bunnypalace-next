import XCTest
@testable import 记忆花园

/// #067 第 4 步：首屏画像卡底的提醒——正常时没有，连续失败 3 次才出一行，提取优先
final class MemoryHealthWarningTests: XCTestCase {

    let pid = "xctest-health-warning"

    override func tearDown() {
        let d = UserDefaults.standard
        for kind in ["extract", "dream", "summary", "context", "timeline"] {
            for field in ["ok", "err", "errmsg", "streak", "model"] {
                d.removeObject(forKey: "mem_health_\(kind)_\(field)_\(pid)")
            }
        }
        super.tearDown()
    }

    private func fail(_ kind: MemoryHealthStore.Kind, times: Int) {
        for _ in 0..<times {
            MemoryHealthStore.recordError(kind, profileId: pid, message: "boom", modelName: "m")
        }
    }

    func testNoWarningWhenHealthy() {
        XCTAssertNil(MemoryHealthWarning.text(profileId: pid))
        MemoryHealthStore.recordOK(.extract, profileId: pid, modelName: "m")
        XCTAssertNil(MemoryHealthWarning.text(profileId: pid))
    }

    func testTwoFailuresStayQuiet() {
        fail(.dream, times: 2)
        XCTAssertNil(MemoryHealthWarning.text(profileId: pid))
    }

    func testDreamFailingShowsProfileLine() {
        fail(.dream, times: 3)
        XCTAssertEqual(MemoryHealthWarning.text(profileId: pid), "最近写不成画像")
    }

    func testExtractWinsOverDream() {
        fail(.dream, times: 3)
        fail(.extract, times: 3)
        XCTAssertEqual(MemoryHealthWarning.text(profileId: pid), "最近记不住新东西了")
    }

    func testRecoveryClearsWarning() {
        fail(.summary, times: 3)
        XCTAssertEqual(MemoryHealthWarning.text(profileId: pid), "最近写不成窗口总结")
        MemoryHealthStore.recordOK(.summary, profileId: pid, modelName: "m")
        XCTAssertNil(MemoryHealthWarning.text(profileId: pid))
    }
}
