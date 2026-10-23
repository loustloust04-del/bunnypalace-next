import XCTest
@testable import 记忆花园

/// 刀1（plan-memory-usable）：MemoryHealthStore 特征测试——记录/读取/连败清零/红点阈值。
final class MemoryHealthStoreTests: XCTestCase {

    let pid = "xctest-mem-health"

    override func tearDown() {
        let d = UserDefaults.standard
        for kind in ["extract", "dream"] {
            for field in ["ok", "err", "errmsg", "streak", "model"] {
                d.removeObject(forKey: "mem_health_\(kind)_\(field)_\(pid)")
            }
        }
        super.tearDown()
    }

    func testRecordOKSetsTimestampAndModel() {
        MemoryHealthStore.recordOK(.extract, profileId: pid, modelName: "haiku-test")
        let s = MemoryHealthStore.status(.extract, profileId: pid)
        XCTAssertNotNil(s.lastOK)
        XCTAssertEqual(s.modelName, "haiku-test")
        XCTAssertEqual(s.failStreak, 0)
        XCTAssertFalse(s.needsAttention)
    }

    func testErrorAccumulatesStreakAndAttentionAtThree() {
        for i in 1...3 {
            MemoryHealthStore.recordError(.extract, profileId: pid, message: "连接超时", modelName: "mi-local")
            let s = MemoryHealthStore.status(.extract, profileId: pid)
            XCTAssertEqual(s.failStreak, i)
            XCTAssertEqual(s.needsAttention, i >= 3, "红点应在连续第 3 次失败时亮")
        }
        let s = MemoryHealthStore.status(.extract, profileId: pid)
        XCTAssertEqual(s.lastErrorMessage, "连接超时")
        XCTAssertEqual(s.modelName, "mi-local")
    }

    func testOKResetsStreak() {
        MemoryHealthStore.recordError(.extract, profileId: pid, message: "x", modelName: "m")
        MemoryHealthStore.recordError(.extract, profileId: pid, message: "x", modelName: "m")
        MemoryHealthStore.recordOK(.extract, profileId: pid, modelName: "m2")
        let s = MemoryHealthStore.status(.extract, profileId: pid)
        XCTAssertEqual(s.failStreak, 0)
        XCTAssertFalse(s.needsAttention)
        XCTAssertNotNil(s.lastError, "历史错误时间戳保留，只清连败计数")
    }

    func testKindsAreIsolated() {
        MemoryHealthStore.recordError(.dream, profileId: pid, message: "做梦失败", modelName: "m")
        let extract = MemoryHealthStore.status(.extract, profileId: pid)
        XCTAssertEqual(extract.failStreak, 0, "dream 的失败不该串到 extract")
        XCTAssertNil(extract.lastError)
    }

    func testLongErrorMessageTruncated() {
        MemoryHealthStore.recordError(.extract, profileId: pid, message: String(repeating: "错", count: 500), modelName: "m")
        let s = MemoryHealthStore.status(.extract, profileId: pid)
        XCTAssertLessThanOrEqual(s.lastErrorMessage?.count ?? 0, 200)
    }
}
