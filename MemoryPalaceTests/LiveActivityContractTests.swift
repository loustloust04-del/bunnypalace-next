import Foundation
import XCTest
@testable import 记忆花园

// Fixture 真相在 fixtures/live-activity/，经 project.yml resources 拷进 bundle；测试进程 TCC 拒绝 #filePath 直读。
final class LiveActivityContractTests: XCTestCase {
    private let fullState = CCActivityState(
        phase: .waiting,
        model: "Opus 5",
        ctx: 47,
        fiveHour: 20,
        sevenDay: 88,
        detail: "要不要把 M4 拆成两步？",
        sinceUnix: 1_756_472_400,
        updatedUnix: 1_756_472_460,
        runId: "r-1756472400-3"
    )

    private let minimalState = CCActivityState(
        phase: .idle,
        model: nil,
        ctx: nil,
        fiveHour: nil,
        sevenDay: nil,
        detail: nil,
        sinceUnix: nil,
        updatedUnix: nil,
        runId: nil
    )

    func testFullStateEncodingMatchesGoldenBytes() throws {
        XCTAssertEqual(try encoded(fullState), try goldenData(named: "content-state.golden"))
    }

    func testMinimalStateEncodingOmitsNilKeys() throws {
        XCTAssertEqual(try encoded(minimalState), try goldenData(named: "content-state-minimal.golden"))
    }

    func testGoldenStatesDecodeToExpectedValues() throws {
        let decoder = JSONDecoder()

        XCTAssertEqual(
            try decoder.decode(CCActivityState.self, from: goldenData(named: "content-state.golden")),
            fullState
        )
        XCTAssertEqual(
            try decoder.decode(CCActivityState.self, from: goldenData(named: "content-state-minimal.golden")),
            minimalState
        )
    }

    private func encoded(_ state: CCActivityState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    private func goldenData(named name: String) throws -> Data {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: LiveActivityContractTests.self).url(forResource: name, withExtension: "json")
        )
        let fixture = try Data(contentsOf: fixtureURL)
        let text = try XCTUnwrap(String(data: fixture, encoding: .utf8))
        return try XCTUnwrap(
            text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)
        )
    }
}
