#if os(macOS)
import XCTest
@testable import 记忆花园

final class KBProbeTests: XCTestCase {
    func testDefaultOffDoesNotEvaluateMessageOrCreateFile() throws {
        let suite = "mp.kbprobe.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("kb-probe.log")
        let probe = KBProbe(url: file, defaults: defaults)
        var evaluated = false
        probe.record({ evaluated = true; return "disabled" }())
        XCTAssertFalse(evaluated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testExplicitlyEnabledWritesCompleteLinesInOrder() throws {
        let suite = "mp.kbprobe.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "mp.kbProbe.enabled")
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("kb-probe.log")
        let probe = KBProbe(url: file, defaults: defaults)
        let caller = Thread.current
        func message(_ value: String) -> String {
            XCTAssertTrue(Thread.current === caller, "日志表达式不能跨线程读取模型")
            return value
        }
        probe.record(message("one"))
        probe.record(message("two"))
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: file, encoding: .utf8))?.hasSuffix(" two\n") == true
        }, object: nil)
        wait(for: [written], timeout: 5)
        let text = try String(contentsOf: file, encoding: .utf8)
        let messages = text.split(separator: "\n").map { String($0.split(separator: " ", maxSplits: 1).last ?? "") }
        XCTAssertEqual(messages, ["one", "two"])
        print("P1_SMOKE explicitEnabled=1 orderedLines=one,two")
    }

    func testRollbackRestoresEnabledSynchronousWrites() throws {
        let suite = "mp.kbprobe.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "mp.stanch.P1")
        defaults.set(false, forKey: "mp.kbProbe.enabled")
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("kb-probe.log")
        let probe = KBProbe(url: file, defaults: defaults)
        probe.record("legacy")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix(" legacy\n"), "NO回退必须在调用返回前落盘")
        print("P1_ROLLBACK_SMOKE switch=NO synchronousLine=legacy")
    }
}
#endif
