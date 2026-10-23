#if os(macOS)
import XCTest
@testable import 记忆花园

/// N5-a1：照抄 Wake `services/context.rs` 7 条单测（project 三级匹配 / since 各形态）
final class CodingContextTests: XCTestCase {
    private func project(_ path: String, _ name: String) -> CodingProjectInfo {
        CodingProjectInfo(path: path, name: name, sessionCount: 1, lastActive: 0)
    }

    private var fixtures: [CodingProjectInfo] {
        [project("/Users/t/Github/wake", "wake"), project("/Users/t/Github/wake/crates/wake-core", "wake-core"),
         project("/Users/t/Github/wake-old", "wake-old"), project("/Users/t/Work/api", "api"), project("", "")]
    }

    func testExactMatchWinsAndIgnoresTrailingSeparator() {
        XCTAssertEqual(CodingContext.resolveProjectPaths("/Users/t/Github/wake/", projects: fixtures), ["/Users/t/Github/wake"])
    }

    func testCwdInsideProjectPicksLongestAncestor() {
        XCTAssertEqual(CodingContext.resolveProjectPaths("/Users/t/Github/wake/src/db", projects: fixtures), ["/Users/t/Github/wake"])
        XCTAssertEqual(CodingContext.resolveProjectPaths("/Users/t/Github/wake/crates/wake-core/src", projects: fixtures),
                       ["/Users/t/Github/wake/crates/wake-core"])
    }

    func testAncestorDirUnionsProjectsBelowIt() {
        XCTAssertEqual(CodingContext.resolveProjectPaths("/Users/t/Github", projects: fixtures),
                       ["/Users/t/Github/wake", "/Users/t/Github/wake-old", "/Users/t/Github/wake/crates/wake-core"])
    }

    func testSiblingWithSharedPrefixIsNotADescendant() {
        let projects = [project("/Users/t/Github/wake", "wake")]
        XCTAssertTrue(CodingContext.resolveProjectPaths("/Users/t/Github/wake-old", projects: projects).isEmpty)
        XCTAssertTrue(CodingContext.resolveProjectPaths("/nope", projects: projects).isEmpty)
        XCTAssertTrue(CodingContext.resolveProjectPaths("   ", projects: projects).isEmpty)
    }

    func testDriveLetterPathsArePathsOnEveryPlatform() {
        let projects = [project(#"C:\Users\t\Github\wake"#, "wake")]
        XCTAssertEqual(CodingContext.resolveProjectPaths(#"C:\Users\t\Github\wake"#, projects: projects), [#"C:\Users\t\Github\wake"#])
        // 盘符串在任何平台都不该被当成项目名去比
        XCTAssertTrue(CodingContext.resolveProjectPaths(#"D:\elsewhere"#, projects: projects).isEmpty)
    }

    func testBareNameMatchesProjectNameCaseInsensitively() {
        XCTAssertEqual(CodingContext.resolveProjectPaths("Wake", projects: fixtures), ["/Users/t/Github/wake"])
        XCTAssertTrue(CodingContext.resolveProjectPaths("billing", projects: fixtures).isEmpty)
    }

    func testSinceRelativeAndAbsoluteForms() throws {
        let now: Int64 = 1_800_000_000_000
        XCTAssertEqual(CodingContext.parseSince("7d", nowMs: now), now - 7 * 86_400_000)
        XCTAssertEqual(CodingContext.parseSince("90m", nowMs: now), now - 90 * 60_000)
        XCTAssertEqual(CodingContext.parseSince("2w", nowMs: now), now - 14 * 86_400_000)
        XCTAssertEqual(CodingContext.parseSince("2026-09-01T00:00:00Z", nowMs: now), 1_788_220_800_000)
        let midnight = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let midnightMs = Int64((midnight.timeIntervalSince1970 * 1000).rounded())
        XCTAssertEqual(CodingContext.parseSince("2026-09-01", nowMs: now), midnightMs)
        XCTAssertEqual(CodingContext.parseSince("2026-09-01 00:00", nowMs: now), midnightMs)
        XCTAssertNil(CodingContext.parseSince("yesterday", nowMs: now))
        XCTAssertNil(CodingContext.parseSince("-3d", nowMs: now))
        XCTAssertNil(CodingContext.parseSince("", nowMs: now))
        // 非 ASCII 收尾只能是 nil，绝不能崩
        XCTAssertNil(CodingContext.parseSince("7天", nowMs: now))
        XCTAssertNil(CodingContext.parseSince("昨天", nowMs: now))
        XCTAssertNil(CodingContext.parseSince("天", nowMs: now))
    }
}
#endif
