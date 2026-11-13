import XCTest
import MemoryCore
@testable import memoryd

/// recall-24 的 Y 半边（13 题）：A 线 8 + wiki 5。X 侧 11 题不跑，主分必须 nil。
/// 题集按 America/Los_Angeles 记忆日，宿主不是 LA 就跳过（和包 / app 测试同一条规矩）。
final class MemorydRecallBenchTests: XCTestCase {
    private var floor: URL!
    private var service: MemorydService!

    override func setUpWithError() throws {
        guard Calendar.current.timeZone.identifier == "America/Los_Angeles" else {
            throw XCTSkip("内置快照要求 America/Los_Angeles；RecallTool 尚无 calendar 注入入口")
        }
        floor = try MemorydFixture.copiedFloor()
        service = try MemorydFixture.service(floor)
    }

    override func tearDownWithError() throws {
        if let floor { MemorydFixture.remove(floor) }
    }

    private func runRecall() async throws -> MemoryBenchRun {
        let started = await service.post("/api/bench/run", json: #"{"setId":"recall-24"}"#)
        XCTAssertEqual(started.status, 200)
        let runId = try XCTUnwrap(started.jsonDictionary?["runId"] as? String)
        let detail = await service.get("/api/bench/runs/\(runId)")
        XCTAssertEqual(detail.status, 200)
        return try MemoryBench.decoder.decode(MemoryBenchRun.self, from: detail.body)
    }

    private var set: MemoryBenchSet {
        get throws {
            let url = try XCTUnwrap(MemorydResources.benchDirectory).appendingPathComponent("memory-bench-recall-24.json")
            return try MemoryBench.decoder.decode(MemoryBenchSet.self, from: Data(contentsOf: url))
        }
    }

    private func decode(_ cell: MemoryBenchCell) throws -> MemoryBenchRecallOutput {
        try MemoryBench.decoder.decode(MemoryBenchRecallOutput.self, from: Data(try XCTUnwrap(cell.output).utf8))
    }

    func testThirteenCellsRunWithoutErrors() async throws {
        let run = try await runRecall()
        XCTAssertEqual(run.cells.count, 13)
        XCTAssertEqual(run.cells.map(\.error), Array(repeating: nil, count: 13))
        XCTAssertEqual(run.caseIds.count, 13)
        XCTAssertTrue(run.note?.contains("主分不可测（X 侧 11 题等刀 3）") == true, run.note ?? "")
    }

    func testMainScoreIsNilAndALineConstantsMatch() async throws {
        let run = try await runRecall()
        let score = try XCTUnwrap(run.scores.first)
        XCTAssertNil(score.main, "X 侧不测 → 分母 0")
        XCTAssertEqual(score.parts["出错格"], 0)
        XCTAssertEqual(score.parts["护栏"], 0)
        XCTAssertEqual(score.parts["Y 越界"], 0)

        let aLine = run.cells.filter { $0.caseId.hasPrefix("a-") || $0.caseId.hasPrefix("switch-") }
        XCTAssertEqual(aLine.count, 8)
        let aScore = MemoryBenchRecallScorer().score(cells: aLine, judgments: run.effectiveJudgments())
        XCTAssertEqual(aScore.parts["Y 定位对"], 7)
        XCTAssertEqual(aScore.parts["Y 定位错"], 0)
        XCTAssertEqual(aScore.parts["Y 定位不可测"], 0)

        let wiki = run.cells.filter { $0.caseId == "fts-04" || $0.caseId.hasPrefix("y7-") }
        XCTAssertEqual(wiki.count, 5)
        let wikiScore = MemoryBenchRecallScorer().score(cells: wiki, judgments: run.effectiveJudgments())
        XCTAssertEqual(wikiScore.parts["Y 定位对"], 9)
        XCTAssertEqual(wikiScore.parts["Y 定位错"], 0)
        XCTAssertEqual(wikiScore.parts["Y 定位不可测"], 0)
    }

    func testQuestionShapeConstants() async throws {
        let run = try await runRecall()
        let byId = Dictionary(uniqueKeysWithValues: run.cells.map { ($0.caseId, $0) })

        let a01 = try decode(try XCTUnwrap(byId["a-01"]))
        XCTAssertEqual(a01.turns.last?.y.last?.layer, "原文")
        XCTAssertFalse(a01.guardrail.privacyLeak)
        XCTAssertFalse(a01.guardrail.l2Impersonation)
        XCTAssertFalse(a01.guardrail.originalOverrun)

        let a05 = try decode(try XCTUnwrap(byId["a-05"]))
        XCTAssertTrue(a05.turns[0].y.allSatisfy { $0.status != "success" && ($0.returnedRange ?? []).isEmpty })

        let switch03 = try decode(try XCTUnwrap(byId["switch-03"]))
        XCTAssertTrue(switch03.turns[0].y.allSatisfy { ($0.returnedRange ?? []).isEmpty })

        // 每一轮的 X 都是同一个「不可测」桩
        for cell in run.cells {
            let output = try decode(cell)
            for turn in output.turns {
                XCTAssertEqual(turn.x.reason, "不可测")
                XCTAssertEqual(turn.x.fullText, "untestable")
                XCTAssertTrue(turn.x.sources.isEmpty)
            }
        }
    }

    /// 同一题集跑两次：格子输出 JSON 字节一致（临时目录 / pid 盐不许漏进结果）
    func testByteDeterminism() async throws {
        let first = try await runRecall()
        let second = try await runRecall()
        XCTAssertEqual(first.cells.map(\.caseId), second.cells.map(\.caseId))
        for (a, b) in zip(first.cells, second.cells) {
            XCTAssertEqual(a.output, b.output, a.caseId)
            XCTAssertEqual(try MemoryBench.lineEncoder.encode(a.items), try MemoryBench.lineEncoder.encode(b.items), a.caseId)
        }
    }
}

/// 宿主时区不符：整份 run 不可测（不改进程时区，给一句怎么启动）。
/// 题集时区取一个与宿主确定不同的值（Tokyo 宿主改用 Shanghai），构造给 `runBench`；两种宿主下都跑，不依赖 LA。
final class MemorydRecallTimeZoneTests: XCTestCase {
    private var floor: URL!
    private var service: MemorydService!

    override func setUpWithError() throws {
        floor = try MemorydFixture.copiedFloor()
        service = try MemorydFixture.service(floor)
    }

    override func tearDownWithError() throws {
        if let floor { MemorydFixture.remove(floor) }
    }

    private func mismatchedSet(zone: String) throws -> MemoryBenchSet {
        let url = try XCTUnwrap(MemorydResources.benchDirectory).appendingPathComponent("memory-bench-recall-24.json")
        var set = try MemoryBench.decoder.decode(MemoryBenchSet.self, from: Data(contentsOf: url))
        set.cases = try set.cases.map { testCase in
            var input = try testCase.input.decode(MemoryBenchRecallInput.self)
            input.profile.timeZone = zone
            var copy = testCase
            copy.input = try .from(input)
            return copy
        }
        return set
    }

    func testMismatchedHostIsUnmeasurable() async throws {
        let other = TimeZone.current.identifier == "Asia/Tokyo" ? "Asia/Shanghai" : "Asia/Tokyo"
        let run = try await service.runBench(mismatchedSet(zone: other))
        XCTAssertTrue(run.cells.isEmpty)
        let note = try XCTUnwrap(run.note)
        XCTAssertTrue(note.contains("宿主时区"), note)
        XCTAssertTrue(note.contains(other), note)
        XCTAssertTrue(note.contains("TZ=\(other)"), note)
    }
}
