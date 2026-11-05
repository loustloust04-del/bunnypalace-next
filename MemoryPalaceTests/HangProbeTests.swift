#if os(macOS)
import XCTest
@testable import 记忆花园

final class HangProbeTests: XCTestCase {
    func testInactiveHangKeepsDurationAndPackageIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = HangProbe(directory: root, stanchEnabled: true)
        probe.recordHang(duration: 0.249, active: false, context: "below-threshold")
        probe.recordHang(duration: 0.60, active: false, context: "code=1 toolIds=terminal")
        let text = try String(contentsOf: root.appendingPathComponent("hangs.log"), encoding: .utf8)
        XCTAssertFalse(text.contains("below-threshold"))
        XCTAssertTrue(text.contains("hang 0.60s"))
        XCTAssertTrue(text.contains("active=0 code=1 toolIds=terminal"))
        XCTAssertTrue(text.contains("pid=\(getpid()) "))
        let binary = try XCTUnwrap(text.split(separator: " ").first { $0.hasPrefix("bin=") })
        XCTAssertNotNil(UUID(uuidString: String(binary.dropFirst(4))))
        XCTAssertTrue(text.contains("origin="))
    }

    func testDisabledStanchPreservesActiveOnlyReporting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = HangProbe(directory: root, stanchEnabled: false)
        probe.recordHang(duration: 2, active: false, context: "hidden")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hangs.log").path))
        probe.recordHang(duration: 0.60, active: true, context: "code=0")
        let text = try String(contentsOf: root.appendingPathComponent("hangs.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("hang 0.60s cpu=0% code=0"))
        XCTAssertFalse(text.contains("bin="))
        XCTAssertFalse(text.contains("active="))
    }

    func testTestHostNeverStartsOrWritesNotesEvenWithRollback() throws {
        XCTAssertTrue(TestHostIsolation.active)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let probe = HangProbe(directory: root, stanchEnabled: false)
        probe.start()
        probe.note("must not write")
        XCTAssertFalse(probe.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(HangProbe.shared.isRunning)
    }

    @MainActor
    func testMeasuredSixHundredMillisecondReportingSmoke() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = HangProbe(directory: root, stanchEnabled: true)
        probe.tick()
        usleep(600_000)
        let returned = expectation(description: "main heartbeat replied")
        DispatchQueue.main.async { returned.fulfill() }
        await fulfillment(of: [returned], timeout: 5)
        XCTAssertFalse(probe.isRunning) // 队列屏障：回执已落盘，但宿主从未启动定时器
        let text = try String(contentsOf: root.appendingPathComponent("hangs.log"), encoding: .utf8)
        let value = try XCTUnwrap(text.components(separatedBy: "hang ").last?.components(separatedBy: "s ").first)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(Double(value)), 0.59)
        XCTAssertTrue(text.contains("active="))
        XCTAssertTrue(text.contains("detailLoaded="))
        print("H1_SMOKE \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    func testSummarySeparatesHeartbeatBackgroundAndTriggerWindows() {
        let identity = "pid=12 bin=11111111-1111-1111-1111-111111111111 build=7 origin=installed"
        let prefix = "2026-10-21 10:00:00 \(identity)"
        let groups = HangProbe.summarize([
            "\(prefix) hang 0.50s cpu=20% active=1 code=1 detailLoaded=1 tool=terminal",
            "\(prefix) hang 1.25s cpu=20% active=1 code=1 detailLoaded=1 tool=terminal",
            "\(prefix) hang 4.00s cpu=20% active=0 code=1 detailLoaded=1 tool=terminal",
            "\(prefix) hang 0.50s lowerBound=1 → sample-20261021-100000.txt",
            "\(prefix) busy cpu=85% 11s → sample-20261021-100000.txt"
        ])
        let foreground = groups.first { $0.kind == .heartbeat && $0.context.contains("active=1") }
        XCTAssertEqual(foreground?.count, 2)
        XCTAssertEqual(foreground?.maximumSeconds, 1.25)
        XCTAssertEqual(groups.first { $0.context.contains("active=0") }?.maximumSeconds, 4)
        XCTAssertEqual(groups.first { $0.kind == .triggerLowerBound }?.maximumSeconds, 0.5)
        XCTAssertEqual(groups.first { $0.kind == .cpuWindow }?.maximumSeconds, 11)
    }

    func testSummaryNeverAssignsOldUnidentifiedLinesToLatestStart() {
        let groups = HangProbe.summarize([
            "2026-10-21 10:00:00 pid=12 bin=11111111-1111-1111-1111-111111111111 build=7 origin=installed start pid=12",
            "2026-10-21 10:00:01 hang 1.00s cpu=50% code=0 tool=- tools=0",
            "2026-10-21 10:00:02 hang 2.00s (cooldown, no sample)",
            "2026-10-21 10:00:03 [worker] says hang 99s"
        ])
        XCTAssertEqual(groups.filter { $0.package == "身份未知" }.count, 2)
        XCTAssertEqual(groups.first { $0.kind == .heartbeat }?.maximumSeconds, 1)
        XCTAssertEqual(groups.first { $0.kind == .triggerLowerBound }?.maximumSeconds, 2)
    }

    func testRecentSummaryKeepsFiftyCompleteLinesAndIgnoresPartialAppend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = (0..<51).map { "2026-10-21 10:00:00 hang \(Double($0) + 0.5)s cpu=50% code=0 tool=- tools=0" }
        let text = rows.joined(separator: "\n") + "\n2026-10-21 10:00:01 hang 999s cpu=50% code=0"
        try text.write(to: root.appendingPathComponent("hangs.log"), atomically: false, encoding: .utf8)
        let summary = await HangProbe(directory: root).recentSummary()
        XCTAssertNil(summary.error)
        XCTAssertEqual(summary.groups.count, 1)
        XCTAssertEqual(summary.groups.first?.count, 50)
        XCTAssertEqual(summary.groups.first?.maximumSeconds, 50.5)
    }

    #if PERF_BENCH
    func testForcedSelfSampleOnlyAllowsIsolatedSeedRole() {
        XCTAssertTrue(HangProbe.canForceBenchSample(request: "1", role: "seed", active: true, testHost: false))
        for request in [nil, "0", "YES"] {
            XCTAssertFalse(HangProbe.canForceBenchSample(request: request, role: "seed", active: true, testHost: false))
        }
        for role in [nil, "run"] {
            XCTAssertFalse(HangProbe.canForceBenchSample(request: "1", role: role, active: true, testHost: false))
        }
        XCTAssertFalse(HangProbe.canForceBenchSample(request: "1", role: "seed", active: false, testHost: false))
    }

    func testForcedSelfSampleNeverAllowsTestHost() {
        XCTAssertTrue(TestHostIsolation.active)
        XCTAssertFalse(HangProbe.canForceBenchSample(request: "1", role: "seed", active: true, testHost: true))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let probe = HangProbe(directory: root)
        probe.start()
        XCTAssertFalse(probe.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    #endif
}
#endif
