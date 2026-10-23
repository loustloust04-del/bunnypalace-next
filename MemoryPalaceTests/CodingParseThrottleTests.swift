#if os(macOS)
import XCTest
@testable import 记忆花园

/// 监听增量解析限流（plan-mac-hang-probe 阶段 3）：同一文件隔不够就推迟、只留最新 ref、到点一定补一次
final class CodingParseThrottleTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)
    private func ref(_ path: String, mtime: Int64 = 1) -> CodingSessionFileRef {
        CodingSessionFileRef(agent: .claudeCode, nativeId: path, filePath: path, mtimeMs: mtime, size: 1)
    }
    private func makeThrottle() -> CodingParseThrottle {
        CodingParseThrottle(minInterval: 3, costFactor: 10, now: { [unowned self] in self.clock })
    }

    func testFirstParseIsImmediate() {
        let t = makeThrottle()
        let (due, retry) = t.admit([ref("/a")])
        XCTAssertEqual(due.map(\.filePath), ["/a"])
        XCTAssertNil(retry)
    }

    func testRepeatedWritesAreDeferredByCost() {
        let t = makeThrottle()
        _ = t.admit([ref("/a")])
        t.record([ref("/a")], cost: 1.5)             // 大文件解析 1.5s → 间隔 15s
        clock += 2
        let (due, retry) = t.admit([ref("/a", mtime: 2)])
        XCTAssertTrue(due.isEmpty, "隔不够就推迟")
        XCTAssertEqual(retry ?? 0, 13, accuracy: 0.001)
        clock += 5
        _ = t.admit([ref("/a", mtime: 3)])           // 又写了一次
        XCTAssertEqual(t.pendingCount, 1, "只留最新那份")
        clock += 9
        let (later, next) = t.takeDue()
        XCTAssertEqual(later.map(\.mtimeMs), [3], "到点补解析的是最新的 ref")
        XCTAssertNil(next)
        XCTAssertEqual(t.pendingCount, 0)
    }

    func testSmallFilesUseMinInterval() {
        let t = makeThrottle()
        _ = t.admit([ref("/small")])
        t.record([ref("/small")], cost: 0.01)
        clock += 1
        XCTAssertEqual(t.admit([ref("/small")]).retryAfter ?? 0, 2, accuracy: 0.001, "小文件按最短 3s")
    }

    func testOtherFilesAreIndependent() {
        let t = makeThrottle()
        _ = t.admit([ref("/a")])
        t.record([ref("/a")], cost: 1)
        clock += 1
        let (due, _) = t.admit([ref("/a"), ref("/b")])
        XCTAssertEqual(due.map(\.filePath), ["/b"], "别的文件不受 /a 的间隔影响")
    }
}
#endif
