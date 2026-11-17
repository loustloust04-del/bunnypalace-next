import XCTest
@testable import MemoryCore

/// `MemoryBenchRecallReader` 的纯解析 / 自动判 / 打分，和重放用的小工具（不依赖任何楼层数据）。
final class MemoryBenchRecallReaderTests: XCTestCase {
    private var writer: MemoryBenchRecallReader {
        MemoryBenchRecallReader(profileId: "fictional-floor", contract: { "test-contract" })
    }

    private func recipe(triggerEnabled: Bool = true) throws -> MemoryBenchRecipe {
        let suite = MemoryBenchLocalExecutor.preferencesSuite(named: "memory-bench-test-\(UUID().uuidString)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { MemoryBenchLocalExecutor.removePreferences(defaults, suite: suite) }
        var tuning = RecallTuning.defaults
        tuning.archiveTriggerEnabled = triggerEnabled
        RecallTuningStore.save(tuning, profileId: "fictional-floor", defaults: defaults)
        return try XCTUnwrap(writer.builtInRecipes(defaults: defaults).first)
    }

    func testPreviousReferenceResolvesTargetFieldsAndRejectsMissingOnes() throws {
        let previous = RecallTool.ExecResult(text: "", isError: false, hitMemoryIds: [], read: nil,
            targets: [.init(tree: "a", layer: "window", conversationId: "fictional-window")])
        XCTAssertEqual(try MemoryBenchLocalExecutor.resolve(.string("$prev.targets[0].conversation_id"), previous: previous), .string("fictional-window"))
        XCTAssertThrowsError(try MemoryBenchLocalExecutor.resolve(.string("$prev.targets[1]"), previous: previous))
        XCTAssertThrowsError(try MemoryBenchLocalExecutor.resolve(.string("$prev.targets[0].missing"), previous: previous))
    }

    func testFiveLabelKindsHavePositiveAndNegativeVerdictsIncludingGeneratedMiss() throws {
        let source = "page:人/林栖|v1"
        func label(_ kind: String, keys: [String] = ["page:人/林栖|v1"]) -> MemoryBenchLabel {
            .init(id: kind, kind: kind, text: kind, keys: keys, from: "turn:1")
        }
        func item(_ kind: String, source: String = "page:人/林栖|v1", layer: String = "A2", status: String = "success", extra: [String: String] = [:]) -> MemoryBenchItem {
            var fields = ["kind": kind, "source": source, "layer": layer, "status": status, "turn": "1"]
            fields.merge(extra) { _, new in new }
            return .init(index: 0, text: "虚构条目", fields: fields)
        }
        for kind in ["必须带", "允许带"] {
            XCTAssertEqual(writer.autoJudge(items: [item("x")], labels: [label(kind)]).first?.verdict, .right)
            XCTAssertEqual(writer.autoJudge(items: [item("x", source: "page:地点/别处|v1")], labels: [label(kind)]).first?.verdict, .wrong)
        }
        XCTAssertEqual(writer.autoJudge(items: [item("x")], labels: [label("禁止带")]).first?.verdict, .wrong)
        XCTAssertEqual(writer.autoJudge(items: [item("x", source: "page:地点/别处|v1")], labels: [label("禁止带"), label("允许带", keys: ["page:地点/别处|v1"])]).first?.verdict, .right)
        XCTAssertEqual(writer.autoJudge(items: [item("turn", extra: ["searched": "true"])], labels: [label("应跳过")]).first?.verdict, .wrong)
        XCTAssertEqual(writer.autoJudge(items: [item("turn", extra: ["searched": "false"])], labels: [label("应跳过")]).first?.verdict, .right)
        let destination = label("应到达层", keys: ["layer:A2"])
        for (layer, expected) in [("A2", MemoryBenchVerdict.right), ("A3", .wrong)] {
            XCTAssertEqual(writer.autoJudge(items: [item("location", layer: layer, extra: ["labelId": destination.id])], labels: [destination]).first?.verdict, expected)
        }
        XCTAssertEqual(writer.autoJudge(items: [item("location", status: "untestable", extra: ["labelId": destination.id])], labels: [destination]).first?.verdict, .weak)
        let output = MemoryBenchRecallOutput(turns: [.init(x: .init(searched: true, kept: false, reason: "预算", sources: []), y: [])], calls: 0, guardrail: .init())
        let testCase = MemoryBenchCase(id: "missing", title: "漏注", input: .null, labels: [label("必须带")])
        let parsed = writer.parse(output: String(decoding: try MemoryBench.lineEncoder.encode(output), as: UTF8.self), testCase: testCase, recipe: try recipe())
        let miss = try XCTUnwrap(parsed.items.first { $0.fields["kind"] == "miss" })
        XCTAssertEqual(miss.fields["source"], source)
        XCTAssertEqual(miss.fields["reason"], "预算")
        XCTAssertEqual(writer.autoJudge(items: [miss], labels: testCase.labels).first?.verdict, .wrong)
    }

    func testAnyGuardInvalidatesWholeRecipeGroupAndPersistsAfterOutputPruning() throws {
        let scorer = MemoryBenchRecallScorer()
        for name in ["privacyLeak", "l2Impersonation", "originalOverrun"] {
            let cell = MemoryBenchCell(id: "c", caseId: "fictional", recipeId: "r", modelId: "m", output: nil,
                items: [.init(index: 0, text: "应判项", fields: ["kind":"turn", "required":"1"]),
                        .init(index: 1, text: "实际项", fields: ["kind":"x"])],
                checks: [.init(name: name, passed: false, hard: true)], ms: 0)
            let result = scorer.score(cells: [cell], judgments: [.init(cellId: "c", item: 1, verdict: .right, by: .auto, at: Date(timeIntervalSince1970: 0))])
            XCTAssertNil(result.main)
            XCTAssertEqual(result.parts["护栏"], 1)
        }
    }

    func testPaginationScoresOverlapGapAndAllowsSameNodeCharacterContinuation() throws {
        for (start, repeatCount, gapCount) in [([0, 20], 0.0, 0.0), ([0, 10], 1.0, 0.0), ([0, 30], 0.0, 1.0)] {
            let range = RecallTool.Target(tree: "a", layer: "messages", conversationId: "fictional", lastNodeId: "n0", fromNodeId: "n0")
            let first = MemoryBenchRecallOutput.Y(op: "messages", layer: "原文", status: "partial", target: "", returnedRange: [range],
                next: .init(hasMore: true, cursorIssued: true), deepest: "原文", end: [0, 20], rangeStart: [0, 0], rangeEnd: [0, 20])
            let second = MemoryBenchRecallOutput.Y(op: "messages", layer: "原文", status: "success", target: "", returnedRange: [range],
                next: .init(hasMore: false, cursorIssued: false), deepest: "原文", continuation: true, start: [0, 20], rangeStart: start, rangeEnd: [1, 0])
            let output = MemoryBenchRecallOutput(turns: [.init(x: .init(searched: false, kept: false, reason: "门槛", sources: []), y: [first, second])], calls: 2, guardrail: .init())
            let testCase = MemoryBenchCase(id: "pages", title: "分页", input: .null, labels: [])
            let parsed = writer.parse(output: String(decoding: try MemoryBench.lineEncoder.encode(output), as: UTF8.self), testCase: testCase, recipe: try recipe())
            let cell = MemoryBenchCell(id: "c", caseId: testCase.id, recipeId: "r", modelId: "m", items: parsed.items, checks: parsed.checks, ms: 0)
            let score = MemoryBenchRecallScorer().score(cells: [cell], judgments: [])
            XCTAssertEqual(score.parts["分页重复"], repeatCount)
            XCTAssertEqual(score.parts["分页丢失"], gapCount)
        }
    }

    func testExecutionAndJSONErrorsCountOncePerCellWithoutGuard() throws {
        let parsed = writer.parse(output: "invalid", testCase: .init(id: "c", title: "", input: .null, labels: []), recipe: try recipe())
        let badJSON = MemoryBenchCell(id: "json", caseId: "c", recipeId: "r", modelId: "m", items: parsed.items, checks: parsed.checks, ms: 0)
        var execution = badJSON
        execution.id = "execution"
        execution.error = "宿主时区不匹配"
        execution.checks = []
        var both = badJSON
        both.id = "both"
        both.error = "执行失败"
        let result = MemoryBenchRecallScorer().score(cells: [badJSON, execution, both], judgments: [])
        XCTAssertNil(result.main)
        XCTAssertEqual(result.parts["出错格"], 3)
        XCTAssertEqual(result.parts["护栏"], 0)
    }

    func testReplayPreferenceSuitesRemainIsolatedAndRemoveTheirOwnFiles() throws {
        let aName = MemoryBenchLocalExecutor.preferencesSuite(named: "memory-bench-test-\(UUID().uuidString)")
        let bName = MemoryBenchLocalExecutor.preferencesSuite(named: "memory-bench-test-\(UUID().uuidString)")
        let a = try XCTUnwrap(UserDefaults(suiteName: aName))
        let b = try XCTUnwrap(UserDefaults(suiteName: bName))
        defer {
            MemoryBenchLocalExecutor.removePreferences(a, suite: aName)
            MemoryBenchLocalExecutor.removePreferences(b, suite: bName)
        }
        a.set(true, forKey: "mem_master")
        b.set(false, forKey: "mem_master")
        var tuning = RecallTuning.defaults
        tuning.archiveTriggerEnabled = true
        RecallTuningStore.save(tuning, profileId: "fictional", defaults: a)
        tuning.archiveTriggerEnabled = false
        RecallTuningStore.save(tuning, profileId: "fictional", defaults: b)
        XCTAssertTrue(a.bool(forKey: "mem_master"))
        XCTAssertFalse(b.bool(forKey: "mem_master"))
        XCTAssertTrue(RecallTuningStore.load(profileId: "fictional", defaults: a).archiveTriggerEnabled)
        XCTAssertFalse(RecallTuningStore.load(profileId: "fictional", defaults: b).archiveTriggerEnabled)
        MemoryBenchLocalExecutor.removePreferences(a, suite: aName)
        XCTAssertNil(a.persistentDomain(forName: aName))
        XCTAssertFalse(b.bool(forKey: "mem_master"))
        #if os(macOS)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aName + ".plist"))
        #endif
    }
}
