import MemoryCore
import SwiftData
import XCTest
@testable import 记忆花园

/// 4 条全链路（SwiftData → 快照换源后的回归闸）：`MemoryBenchRecallReaderTests` 里是纯解析 / 护栏。
final class MemoryBenchRecallTests: XCTestCase {
    private let writer = MemoryBenchWriters.recallReader(profileId: "fictional-floor")
    private let model = MemoryBenchModelRef(credentialId: "offline", modelId: "recall", name: "本地离线")

    override func setUpWithError() throws {
        guard Calendar.current.timeZone.identifier == "America/Los_Angeles" else {
            throw XCTSkip("内置快照要求 America/Los_Angeles；RecallTool 尚无 calendar 注入入口")
        }
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
    private func exam() throws -> MemoryBenchSet {
        try XCTUnwrap(MemoryBenchStore.builtInSets().first { $0.id == "recall-24" })
    }
    private func run(_ set: MemoryBenchSet, recipe: MemoryBenchRecipe, store: MemoryBenchStore) async throws -> MemoryBenchRun {
        try await MemoryBenchRunner.run(writer: writer, set: set, recipes: [recipe], models: [model], store: store, profileId: "fictional-floor",
            caller: { _, _ in throw MemoryBenchLocalExecutor.Failure("离线不得调用 caller") })
    }
    private func decode(_ cell: MemoryBenchCell) throws -> MemoryBenchRecallOutput {
        try MemoryBench.decoder.decode(MemoryBenchRecallOutput.self, from: Data(XCTUnwrap(cell.output).utf8))
    }

    func testAllTwentyFourOfflineReplayAndByteDeterminismAndStoredRescore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-bench-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryBenchStore(root: root)
        let set = try exam(), recipe = try recipe()
        let first = try await run(set, recipe: recipe, store: store)
        let second = try await run(set, recipe: recipe, store: store)
        XCTAssertEqual(first.cells.count, 24)
        XCTAssertEqual(first.cells.map(\.error), Array(repeating: nil, count: 24))
        for (a, b) in zip(first.cells, second.cells) {
            XCTAssertEqual(a.output, b.output, a.caseId)
            XCTAssertEqual(try MemoryBench.lineEncoder.encode(a.items), try MemoryBench.lineEncoder.encode(b.items), a.caseId)
            let output = try decode(a)
            XCTAssertFalse(output.guardrail.privacyLeak, a.caseId)
            XCTAssertFalse(output.guardrail.l2Impersonation, a.caseId)
            XCTAssertFalse(output.guardrail.originalOverrun, a.caseId)
            print("BENCH_RECALL_CASE \(a.caseId) deepest=\(output.deepestLayer ?? "无") calls=\(output.calls)")
        }
        let saved = try XCTUnwrap(store.run(id: first.id))
        XCTAssertEqual(saved.scored(with: writer.scorers), first.scores)
        var pruned = saved
        for i in pruned.cells.indices { pruned.cells[i].output = nil }
        XCTAssertEqual(pruned.scored(with: writer.scorers), first.scores, "原始输出清理后仍可重算")
        let score = try XCTUnwrap(first.scores.first)
        print("BENCH_RECALL_TOTAL main=\(score.main.map(String.init(describing:)) ?? "nil") parts=\(String(decoding: try MemoryBench.lineEncoder.encode(score.parts), as: UTF8.self))")
        // 改选择算法 / 快照时重录。
        // 11-09 ⑤-1 P2-b：来源窗过滤后重录（来源关参与 / 回收站窗的碎片不再带入）。
        // 变动格（错注 旧→新）：gate-01 t1、gate-02 t1、gate-03 t1、gate-04 t2、gate-05 t2 各 1 → 0（都是 A1000007）。
        XCTAssertEqual(score.main, 16.0 / 17.0)
        for (key, count) in ["错注数": 0.0, "漏注数": 1, "Y 定位对": 16, "Y 定位错": 0,
                             "Y 越界": 0, "应跳过却搜了": 0, "出错格": 0] {
            XCTAssertEqual(score.parts[key], count, key)
        }
        for judgment in first.judgments where judgment.verdict == .wrong {
            if let cell = first.cells.first(where: { $0.id == judgment.cellId }),
               let item = cell.items.first(where: { $0.index == judgment.item }) {
                print("BENCH_RECALL_ERROR \(cell.caseId) turn=\(item.fields["turn"] ?? "") kind=\(item.fields["kind"] ?? "") source=\(item.fields["source"] ?? "") reason=\(item.fields["reason"] ?? "")")
            }
        }
        for group in ["gate", "fts", "a", "y7", "switch"] {
            let cells = first.cells.filter { $0.caseId.hasPrefix(group + "-") }
            let result = MemoryBenchRecallScorer().score(cells: cells, judgments: first.effectiveJudgments())
            print("BENCH_RECALL_GROUP \(group) cells=\(cells.count) main=\(result.main.map(String.init(describing:)) ?? "nil") parts=\(String(decoding: try MemoryBench.lineEncoder.encode(result.parts), as: UTF8.self))")
        }
        let byId = Dictionary(uniqueKeysWithValues: first.cells.map { ($0.caseId, $0) })
        XCTAssertEqual(try decode(XCTUnwrap(byId["a-01"])).turns.last?.y.last?.layer, "原文")
        XCTAssertEqual(try decode(XCTUnwrap(byId["y7-01"])).turns.last?.y.last?.sourceVersion, "v1")
        XCTAssertEqual(try decode(XCTUnwrap(byId["y7-02"])).turns.last?.y.last?.sourceVersion, "v2")
        let oldCard = try XCTUnwrap(byId["y7-03"])
        XCTAssertEqual(oldCard.items.filter { $0.fields["kind"] == "y" && $0.fields["layer"] == "L1" }.map { $0.fields["source"] },
                       ["card:memory/cc/旧罗盘.md|old1"])
        let index = try XCTUnwrap(byId["fts-04"])
        XCTAssertEqual(index.items.filter { $0.fields["kind"] == "y" }.map { $0.fields["source"] }, ["layer:wiki索引"])
        XCTAssertTrue(try decode(XCTUnwrap(byId["a-05"])).turns[0].y.allSatisfy { $0.status != "success" && $0.returnedRange == [] })
        XCTAssertTrue(try decode(XCTUnwrap(byId["switch-03"])).turns[0].y.allSatisfy { $0.returnedRange == [] })
        XCTAssertEqual(score.parts["分页重复"], 0)
        XCTAssertEqual(score.parts["分页丢失"], 0)
    }

    func testDateEventPaginationWithinOneDayIsNotCountedAsDuplicate() async throws {
        var testCase = try XCTUnwrap(exam().cases.first { $0.id == "a-03" })
        var input = try testCase.input.decode(MemoryBenchRecallInput.self)
        input.turns[0].ops!.append(.init(op: "date", args: ["cursor": .string("$prev.cursor")]))
        testCase.input = try .from(input)
        var recipe = try recipe()
        recipe.params["datePageEvents"] = .number(1)
        let raw = try await MemoryBenchLocalExecutor.execute(testCase: testCase, recipe: recipe)
        let output = try MemoryBench.decoder.decode(MemoryBenchRecallOutput.self, from: Data(raw.utf8))
        XCTAssertEqual(output.turns[0].y.count, 3)
        XCTAssertEqual(output.turns[0].y[0].returnedRange?.first?.date, "2026-10-31")
        XCTAssertEqual(output.turns[0].y[1].returnedRange?.first?.date, "2026-10-31")
        XCTAssertEqual(output.turns[0].y[2].returnedRange?.first?.date, "2026-11-01")
        let parsed = writer.parse(output: raw, testCase: testCase, recipe: recipe)
        let cell = MemoryBenchCell(id: "c", caseId: testCase.id, recipeId: recipe.id, modelId: "m", items: parsed.items, checks: parsed.checks, ms: 0)
        let score = MemoryBenchRecallScorer().score(cells: [cell], judgments: [])
        XCTAssertEqual(score.parts["分页重复"], 0)
        XCTAssertEqual(score.parts["分页丢失"], 0)
    }

    func testCallLimitCountsRejectedCallsAndResetsNextTurn() async throws {
        var testCase = try XCTUnwrap(exam().cases.first { $0.id == "a-05" })
        var input = try testCase.input.decode(MemoryBenchRecallInput.self)
        let operation = input.turns[0].ops![0]
        input.turns[0].ops = Array(repeating: operation, count: 4)
        input.turns.append(.init(text: "🙂", ops: [operation]))
        testCase.input = try .from(input)
        let raw = try await MemoryBenchLocalExecutor.execute(testCase: testCase, recipe: recipe())
        let result = try MemoryBench.decoder.decode(MemoryBenchRecallOutput.self, from: Data(raw.utf8))
        XCTAssertEqual(result.calls, 5)
        XCTAssertEqual(result.turns[0].y.map(\.status).last, "limited")
        XCTAssertNotEqual(result.turns[1].y.first?.status, "limited")
        XCTAssertEqual(result.turns[0].y.last?.returnedRange, [])
    }

    func testDefaultLegacyReplayRecordsActualFragmentsAcrossAllTwentyFourCases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-bench-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await run(exam(), recipe: recipe(triggerEnabled: false), store: MemoryBenchStore(root: root))
        XCTAssertEqual(result.cells.map(\.error), Array(repeating: nil, count: 24))
        let first = try decode(XCTUnwrap(result.cells.first { $0.caseId == "gate-01" })).turns[0].x
        XCTAssertEqual(first.path, "legacy")
        XCTAssertTrue(first.sources.contains { $0.source == "memory:A1000001-0000-4000-8000-000000000001" })
        // 来源窗 linqi-window-0002 关参与 → 不带（⑤-1 P2-b 来源窗过滤）
        XCTAssertFalse(first.sources.contains { $0.source == "memory:A1000007-0000-4000-8000-000000000007" })
        XCTAssertFalse(first.sources.contains { $0.source == "memory:A1000004-0000-4000-8000-000000000004" }, "钉住属于 stable，不进 X 来源")
        let score = try XCTUnwrap(result.scores.first)
        // 改选择算法 / 快照时重录。
        // 11-09 ⑤-1 P2-b：来源窗过滤后重录（触发关组错注 10 → 1）。
        // 变动格（错注 旧→新）：gate-01 t1、gate-02 t1/t2、gate-03 t1/t2、gate-04 t2/t3、gate-05 t2/t3 的 A1000007 各 1 → 0（共 9）；
        // 剩 gate-03 t2 的 A1000001（来源窗开参与；该轮没有允许 / 必须标签，按 Reader 规则计错）。实带项数 17 → 8，分母 26 → 17。
        XCTAssertEqual(score.main, 7.0 / 17.0)
        for (key, count) in ["错注数": 1.0, "漏注数": 9, "Y 定位对": 16, "Y 定位错": 0,
                             "Y 越界": 0, "应跳过却搜了": 0, "出错格": 0] {
            XCTAssertEqual(score.parts[key], count, key)
        }
        print("BENCH_RECALL_LEGACY_TOTAL main=\(score.main.map(String.init(describing:)) ?? "nil") parts=\(String(decoding: try MemoryBench.lineEncoder.encode(score.parts), as: UTF8.self))")
        for group in ["gate", "fts", "a", "y7", "switch"] {
            let cells = result.cells.filter { $0.caseId.hasPrefix(group + "-") }
            let score = MemoryBenchRecallScorer().score(cells: cells, judgments: result.effectiveJudgments())
            print("BENCH_RECALL_LEGACY_GROUP \(group) main=\(score.main.map(String.init(describing:)) ?? "nil") parts=\(String(decoding: try MemoryBench.lineEncoder.encode(score.parts), as: UTF8.self))")
        }
    }

    /// E3-0 口径：`install` 的段下标按 `branch`（`visiblePath`）编，与生产 A2 同口径。
    /// 可见主线 `[xz-n0, xz-n1, xz-n2, xz-n3, xz-n4]` 的段 `{2,4}` 仍落在 `xz-n2…xz-n3`，段尾 `xz-n3` 不变。
    func testInstallSegmentIndicesMatchHeadConstants() throws {
        let (floor, _) = try MemoryBenchRecallFloor.load("xingyan", in: .main)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-bench-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: Memory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        try MemoryBenchLocalExecutor.install(floor, profileId: "bench-head", container: container, root: root,
                                             wiki: WikiStore(root: root.appendingPathComponent("wiki")))
        let session = try XCTUnwrap(SessionSummaryStore.load(conversationId: "xingyan-window-0001", memoryRoot: root))
        XCTAssertEqual(session.segments.map(\.lastNodeId), ["xz-n1", "xz-n3"])
        let window = try XCTUnwrap(WindowSummaryStore.load(conversationId: "xingyan-window-0001", memoryRoot: root))
        // A3 水位 = A2 水位线（`segments.last.to`），与生产 `SessionCloseout:1011` 同口径；
        // 原值 6（旧全路径长度，口径本身就错）。路径长度只进段级 `to`。
        XCTAssertEqual(window.compressedCount, 4)
        XCTAssertEqual(window.segments.first?.to, 5)
        XCTAssertEqual(window.closedThrough, "xz-n4")
    }

    /// 同一条链的另一端：`date 2026-10-31` 必须命中 A2 段 2（`xz-n3`），不是回落到 `messages`。
    func testDateReadHitsSegmentTwoAfterInstall() async throws {
        var testCase = try XCTUnwrap(exam().cases.first { $0.id == "a-03" })
        var input = try testCase.input.decode(MemoryBenchRecallInput.self)
        input.turns = [.init(text: "🙂", ops: [.init(op: "date", args: ["date": .string("2026-10-31")])])]
        testCase.input = try .from(input)
        let raw = try await MemoryBenchLocalExecutor.execute(testCase: testCase, recipe: recipe())
        let output = try MemoryBench.decoder.decode(MemoryBenchRecallOutput.self, from: Data(raw.utf8))
        let targets = try XCTUnwrap(output.turns.first?.y.first?.targets)
        let target = try XCTUnwrap(targets.count > 3 ? targets[3] : nil)
        print("BENCH_RECALL_DATE_TARGET \(String(decoding: try MemoryBench.lineEncoder.encode(target), as: UTF8.self))")
        XCTAssertEqual(target.layer, "segment")
        XCTAssertEqual(target.segment, 2)
        XCTAssertEqual(target.lastNodeId, "xz-n3")
    }

    /// M1 钉子：`installFiles` 的 `let daily = render(…)` 曾遮蔽 `self.daily`，daily 落到
    /// `daily/<整段 frontmatter>.md`，`daily/2026-10-30.md` 不存在 → a-02 第 1 读 sourceVersion 漂移。
    /// 常量来源：修正遮蔽后用 HEAD app 执行器实跑 a-02（与 memoryd 一致）：
    /// `dd5d80c08462e18d3fd501bad9d95ec586357a08eb895026698208c4291546b5`
    func testASeriesSourceVersionsMatchHeadConstants() async throws {
        let testCase = try XCTUnwrap(exam().cases.first { $0.id == "a-02" })
        let raw = try await MemoryBenchLocalExecutor.execute(testCase: testCase, recipe: recipe())
        let output = try MemoryBench.decoder.decode(MemoryBenchRecallOutput.self, from: Data(raw.utf8))
        XCTAssertEqual(output.turns[0].y[0].sourceVersion,
                       "dd5d80c08462e18d3fd501bad9d95ec586357a08eb895026698208c4291546b5")
    }
}
