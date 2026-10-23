#if os(macOS)
import XCTest
@testable import 记忆花园

/// N0-h 实测（opt-in：`TEST_RUNNER_MP_REAL_SCAN=1 xcodebuild … test`）：把本机真会话目录扫进一个**临时**索引，
/// 只打印计数 / 耗时 / 大小 / 内存峰值，不输出任何会话内容，不碰 Caches 里的正式索引。
final class CodingSessionRealScanTests: XCTestCase {
    func testRealHomeScanBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MP_REAL_SCAN"] == "1" else { throw XCTSkip("opt-in：MP_REAL_SCAN=1") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mp-real-scan-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let index = try CodingSessionIndex(url: url)
        let scanner = CodingSessionScanner(index: index, adapters: CodingSessionRoster.adapters())

        let start = Date()
        let report = try scanner.run()
        let elapsed = Date().timeIntervalSince(start)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let bytes = ["", "-wal"].reduce(Int64(0)) { sum, suffix in
            sum + (((try? FileManager.default.attributesOfItem(atPath: url.path + suffix))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let sessions = try index.sessionCount(includeArchived: true)
        let projects = try index.listProjects(includeArchived: true).count
        print(String(format: "[REAL-SCAN] parsed=%d failed=%d pruned=%d sessions=%d projects=%d elapsed=%.1fs index=%.0fMB peakRSS=%.0fMB",
                     report.parsed, report.failed, report.pruned, sessions, projects, elapsed,
                     Double(bytes) / 1_000_000, Double(usage.ru_maxrss) / 1_048_576))

        let again = Date()
        let rescan = try scanner.run()
        print(String(format: "[REAL-SCAN] rescan parsed=%d elapsed=%.2fs", rescan.parsed, Date().timeIntervalSince(again)))
        // 真机上正在跑的 agent（包括写这段代码的 CC 会话本身）会在两轮之间写文件：只要求增量，不要求 0
        XCTAssertLessThan(rescan.parsed, 10, "无变化的会话不该重解析")
        XCTAssertGreaterThan(sessions, 0)
    }
}
#endif
