import XCTest
@testable import MemoryCore

/// 从 app `MemoryBenchRecallTests` 迁来的纯解析 / 护栏 13 条（断言未改）。
/// 全链路 4 条仍留 app：执行壳只写 `Memory` 表，但重放要 app 的注入 / 选择 / wiki。
final class MemoryBenchRecallReaderTests: XCTestCase {
    /// 包测试用同一份 xingyan 夹具（与 app 资源逐字节相同，不再复制第二份）
    private var fixtureURL: URL {
        Bundle.module.url(forResource: "conversation-floor-schema1", withExtension: "json", subdirectory: "Fixtures")!
    }
    private func loadFloor(_ name: String) throws -> (MemoryBenchRecallFloor, MemoryBenchRecallFloor.Variant) {
        try MemoryBenchRecallFloor.load(contentsOf: fixtureURL, variant: name)
    }
    private var writer: MemoryBenchRecallReader {
        MemoryBenchRecallReader(profileId: "fictional-floor", contract: { "test-contract" }, floorURL: fixtureURL)
    }

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

    /// 24 题 JSON 只随 memoryd / app 走；包测试直接读仓库里的那份（不改内容）
    private func exam() throws -> MemoryBenchSet {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/memoryd/MemoryBench/memory-bench-recall-24.json")
        return try MemoryBench.decoder.decode(MemoryBenchSet.self, from: Data(contentsOf: url))
    }

    func testExamHasUniqueCasesResolvableSnapshotsAndTurnScopedLabels() throws {
        let set = try exam()
        XCTAssertEqual(Set(set.cases.map(\.id)).count, 24)
        for testCase in set.cases {
            XCTAssertFalse(testCase.labels.isEmpty, testCase.id)
            let input = try testCase.input.decode(MemoryBenchRecallInput.self)
            let (floor, _) = try loadFloor(input.snapshot)
            var identities = Set(floor.pages.flatMap { page in
                page.versions.map { "page:\(page.path)|\(WikiStore.version(of: Data($0.utf8)))" }
            })
            identities.formUnion(floor.cards.map { "card:\($0.path)|\($0.version)" })
            identities.formUnion(floor.fragments.map { "memory:\($0.id.uuidString)" })
            for window in floor.windows { identities.formUnion(window.nodes.map { "node:\(window.id)|\($0.id)" }) }
            for label in testCase.labels {
                XCTAssertTrue(writer.labelKinds.contains(label.kind))
                let n = try XCTUnwrap(Int(label.from.replacingOccurrences(of: "turn:", with: "")))
                XCTAssertTrue((1...input.turns.count).contains(n))
                if label.kind != "应跳过" { XCTAssertFalse(label.keys.isEmpty) }
                for key in label.keys where ["page:", "card:", "memory:", "node:"].contains(where: key.hasPrefix) {
                    XCTAssertTrue(identities.contains(key), "\(testCase.id) \(label.id): \(key)")
                }
            }
            var hasPrevious = false
            for operation in input.turns.flatMap({ $0.ops ?? [] }) {
                let json = String(decoding: try MemoryBench.lineEncoder.encode(operation.args), as: UTF8.self)
                if json.contains("$prev") { XCTAssertTrue(hasPrevious, testCase.id) }
                hasPrevious = true
            }
        }
        // Dynamic target indexes and field paths are validated by all 24 real executions above.
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

    func testPrivacyGuardDetectsSnapshotBodiesAndStructuredIdentitiesIndependently() throws {
        let (floor, _) = try loadFloor("xingyan")
        let texts = floor.pages.filter { $0.path.contains("private_") || !$0.approved }.compactMap {
            $0.versions.last.flatMap { FrontmatterCodec.parse($0)?.body.components(separatedBy: "\n").first { !$0.isEmpty && !$0.hasPrefix("#") } }
        } + floor.windows.flatMap { window in
            let selected = Set(floor.branch(window).map(\.id))
            return window.nodes.filter { window.trashed || $0.hidden || $0.deleted || !selected.contains($0.id) }.map(\.text)
        }
        let forbiddenNodes = ["xz-hidden", "xz-deleted", "xz-branch", "rc-n0"]
        var results = texts.map { RecallTool.ExecResult(text: $0, isError: false, hitMemoryIds: [], read: nil) }
        for id in forbiddenNodes {
            let target = RecallTool.Target(tree: "a", layer: "messages", conversationId: id == "rc-n0" ? "recycle-window-0004" : "xingyan-window-0001", fromNodeId: id)
            results.append(.init(text: "", isError: false, hitMemoryIds: [], read: nil, targets: [target]))
            results.append(.init(text: "", isError: false, hitMemoryIds: [], read: .init(layer: "原文", target: "", sourceVersion: nil, status: "success", returnedRange: [target])))
        }
        let fragment = try XCTUnwrap(floor.fragments.first { $0.conversationId == "recycle-window-0004" })
        results.append(.init(text: fragment.text, isError: false, hitMemoryIds: [], read: nil))
        results.append(.init(text: "", isError: false, hitMemoryIds: [fragment.id], read: nil))
        results.append(.init(text: "", isError: false, hitMemoryIds: [], read: nil,
            targets: [.init(tree: "c", layer: "original", memoryId: fragment.id.uuidString)]))
        let forbidden = MemoryBenchLocalExecutor.Forbidden(floor)
        for result in results {
            var guardrail = MemoryBenchRecallOutput.Guard()
            MemoryBenchLocalExecutor.observe(result, requested: .init(op: .search), floor: floor, forbidden: forbidden, guardrail: &guardrail)
            XCTAssertEqual(guardrail, .init(privacyLeak: true, l2Impersonation: false, originalOverrun: false))
        }
    }

    func testL2GuardDetectsVersionImpersonationIndependently() throws {
        let (floor, _) = try loadFloor("xingyan")
        var guardrail = MemoryBenchRecallOutput.Guard()
        let card = RecallWikiCardTarget(page: .init(profileId: "fictional", path: "地点/云桥城"), path: "memory/cc/云桥航图.md", version: "v1")
        let result = RecallTool.ExecResult(text: "", isError: false, hitMemoryIds: [],
            read: .init(layer: "L2", target: "", sourceVersion: "v2", status: "success"))
        MemoryBenchLocalExecutor.observe(result, requested: .init(op: .wiki, target: .init(tree: "c", layer: "original", card: card)), floor: floor, forbidden: MemoryBenchLocalExecutor.Forbidden(floor), guardrail: &guardrail)
        XCTAssertEqual(guardrail, .init(privacyLeak: false, l2Impersonation: true, originalOverrun: false))
    }

    func testOriginalRangeGuardDetectsOverrunIndependently() throws {
        let (floor, _) = try loadFloor("xingyan")
        var guardrail = MemoryBenchRecallOutput.Guard()
        let result = RecallTool.ExecResult(text: "", isError: false, hitMemoryIds: [],
            read: .init(layer: "原文", target: "", sourceVersion: nil, status: "success",
                        returnedRange: [.init(tree: "a", layer: "messages", conversationId: "xingyan-window-0001", lastNodeId: "xz-n2", fromNodeId: "xz-n0")]))
        MemoryBenchLocalExecutor.observe(result, requested: .init(op: .messages, conversationId: "xingyan-window-0001", fromNodeId: "xz-n0", toNodeIdExclusive: "xz-n1"), floor: floor, forbidden: MemoryBenchLocalExecutor.Forbidden(floor), guardrail: &guardrail)
        XCTAssertEqual(guardrail, .init(privacyLeak: false, l2Impersonation: false, originalOverrun: true))
    }

    func testHiddenAnchorOverrunAgainstVisiblePath() throws {
        let (floor, _) = try loadFloor("xingyan")
        let forbidden = MemoryBenchLocalExecutor.Forbidden(floor)
        func result(returned: RecallTool.Target) -> RecallTool.ExecResult {
            .init(text: "", isError: false, hitMemoryIds: [],
                  read: .init(layer: "原文", target: "", sourceVersion: nil, status: "success", returnedRange: [returned]))
        }
        func target(from: String, to: String? = nil, last: String? = nil) -> RecallTool.Target {
            .init(tree: "a", layer: "messages", conversationId: "xingyan-window-0001", lastNodeId: last, fromNodeId: from, toNodeIdExclusive: to)
        }
        // 隐藏节点作起点且 op 返回成功 → 可见路径找不到起点，判越界。
        // 旧 `fullPath` 口径下主线含 `xz-hidden`，`allowed` 会算出 `{xz-hidden, xz-n2…}`，本条不会触发。
        var guardrail = MemoryBenchRecallOutput.Guard()
        MemoryBenchLocalExecutor.observe(result(returned: target(from: "xz-n2", last: "xz-n2")),
            requested: .init(op: .messages, conversationId: "xingyan-window-0001", fromNodeId: "xz-hidden"),
            floor: floor, forbidden: forbidden, guardrail: &guardrail)
        XCTAssertEqual(guardrail, .init(privacyLeak: false, l2Impersonation: false, originalOverrun: true), "隐藏节点作起点")
        // 隐藏节点作终点（O-S3）：以前找不到会回落到窗尾放宽，现在直接判越界；旧口径能找到 `xz-hidden` 并通过。
        guardrail = .init()
        MemoryBenchLocalExecutor.observe(result(returned: target(from: "xz-n0", last: "xz-n0")),
            requested: .init(op: .messages, conversationId: "xingyan-window-0001", fromNodeId: "xz-n0", toNodeIdExclusive: "xz-hidden"),
            floor: floor, forbidden: forbidden, guardrail: &guardrail)
        XCTAssertEqual(guardrail, .init(privacyLeak: false, l2Impersonation: false, originalOverrun: true), "隐藏节点作终点")
    }

    func testCleanReadTriggersNoneOfTheThreeGuards() throws {
        let (floor, _) = try loadFloor("xingyan")
        var guardrail = MemoryBenchRecallOutput.Guard()
        let result = RecallTool.ExecResult(text: "private_ 只是普通文本。\n" + floor.windows[0].nodes[0].text, isError: false, hitMemoryIds: [],
            read: .init(layer: "原文", target: "", sourceVersion: nil, status: "success",
                        returnedRange: [.init(tree: "a", layer: "messages", conversationId: "xingyan-window-0001", lastNodeId: "xz-n1", fromNodeId: "xz-n0")]))
        MemoryBenchLocalExecutor.observe(result, requested: .init(op: .messages, conversationId: "xingyan-window-0001", fromNodeId: "xz-n0", toNodeIdExclusive: "xz-n2"), floor: floor, forbidden: MemoryBenchLocalExecutor.Forbidden(floor), guardrail: &guardrail)
        XCTAssertEqual(guardrail, .init())
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

    func testYForbiddenLayerAndInteriorNodeAreNotHiddenByDeeperSuccessfulRead() throws {
        var testCase = try XCTUnwrap(exam().cases.first { $0.id == "a-04" })
        testCase.labels.append(.init(id: "arrival", kind: "应到达层", text: "原文", keys: ["layer:原文"], from: "turn:1"))
        let output = MemoryBenchRecallOutput(turns: [.init(x: .init(searched: false, kept: false, reason: "门槛", sources: []), y: [
            .init(op: "window", layer: "A3", status: "partial", target: "", returnedRange: [], deepest: "A3"),
            .init(op: "messages", layer: "原文", status: "success", target: "", returnedRange: [
                .init(tree: "a", layer: "messages", conversationId: "xingyan-window-0001", lastNodeId: "xz-n2", fromNodeId: "xz-n0")
            ], deepest: "原文")
        ])], calls: 2, guardrail: .init())
        var labels = testCase.labels
        labels.append(.init(id: "layer", kind: "禁止带", text: "不得读 A3", keys: ["layer:A3"], from: "turn:1"))
        let parsed = writer.parse(output: String(decoding: try MemoryBench.lineEncoder.encode(output), as: UTF8.self), testCase: testCase, recipe: try recipe())
        let judged = writer.autoJudge(items: parsed.items, labels: labels)
        let wrongSources = parsed.items.filter { item in judged.contains { $0.item == item.index && $0.verdict == .wrong } }.map { $0.fields["source"] ?? "" }
        XCTAssertEqual(wrongSources, ["", "node:xingyan-window-0001|xz-n1"])
        let cell = MemoryBenchCell(id: "c", caseId: testCase.id, recipeId: "r", modelId: "m", items: parsed.items, checks: parsed.checks, ms: 0)
        let score = MemoryBenchRecallScorer().score(cells: [cell], judgments: judged.map { .init(cellId: "c", item: $0.item, verdict: $0.verdict, by: .auto, at: .distantPast) })
        XCTAssertEqual(score.parts["Y 越界"], 2)
        XCTAssertEqual(score.parts["Y 定位对"], 1)
        XCTAssertNil(score.main)
    }

    func testYRequiredVersionMismatchAndAbsenceAreWrongWithoutXMiss() throws {
        let testCase = try XCTUnwrap(exam().cases.first { $0.id == "y7-01" })
        let page = RecallWikiPageTarget(profileId: "fictional", path: "地点/云桥城")
        for targets in [[RecallTool.Target(tree: "c", layer: "original", card: .init(page: page, path: "memory/cc/云桥航图.md", version: "v2"))], []] {
            let empty = MemoryBenchRecallOutput.X(searched: false, kept: false, reason: "门槛", sources: [])
            let output = MemoryBenchRecallOutput(turns: [.init(x: empty, y: []), .init(x: empty, y: [
                .init(op: "wiki", layer: "L2", status: "success", target: "", returnedRange: targets, deepest: "L2")
            ])], calls: 1, guardrail: .init())
            let parsed = writer.parse(output: String(decoding: try MemoryBench.lineEncoder.encode(output), as: UTF8.self), testCase: testCase, recipe: try recipe())
            XCTAssertFalse(parsed.items.contains { $0.fields["kind"] == "miss" })
            let judged = writer.autoJudge(items: parsed.items, labels: testCase.labels)
            let missing = try XCTUnwrap(parsed.items.first { $0.fields["kind"] == "y" && $0.fields["status"] == "missing" })
            XCTAssertEqual(judged.first { $0.item == missing.index }?.verdict, .wrong)
            if let actual = parsed.items.first(where: { $0.fields["source"] == "card:memory/cc/云桥航图.md|v2" }) {
                XCTAssertEqual(judged.first { $0.item == actual.index }?.verdict, .wrong)
            }
        }
    }

    func testUnreadyFullTextMarksRoundUntestableWithoutMissOrScoreCredit() throws {
        let testCase = try XCTUnwrap(exam().cases.first { $0.id == "gate-01" })
        let output = MemoryBenchRecallOutput(turns: [.init(x: .init(searched: true, kept: false, reason: "无资料",
            sources: [.init(source: "memory:A1000001-0000-4000-8000-000000000001", layer: "L1")], fullText: "building"), y: [])], calls: 0, guardrail: .init())
        let parsed = writer.parse(output: String(decoding: try MemoryBench.lineEncoder.encode(output), as: UTF8.self), testCase: testCase, recipe: try recipe())
        XCTAssertEqual(parsed.items.first?.fields["judgeable"], "false")
        XCTAssertFalse(parsed.items.contains { $0.fields["kind"] == "miss" })
        let cell = MemoryBenchCell(id: "c", caseId: testCase.id, recipeId: "r", modelId: "m", items: parsed.items, checks: parsed.checks, ms: 0)
        let score = MemoryBenchRecallScorer().score(cells: [cell], judgments: [])
        XCTAssertEqual(score.parts["不可测"], 1)
        XCTAssertEqual(score.parts["漏注数"], 0)
        XCTAssertNil(score.main)
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
        RecallTuningStore.save(.defaults, profileId: "fictional", defaults: b)
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

    /// `floor.branch` == 旧实现再过滤 `!hidden && !deleted` 逐 id 一致：段下标 / `rangeBounds` / `sources` / `Forbidden` 口径
    func testFloorBranchMatchesLegacyParentWalkFiltered() throws {
        let (floor, _) = try loadFloor("xingyan")
        for window in floor.windows {
            let expected = legacyWalk(window).filter { !$0.hidden && !$0.deleted }.map(\.id)
            XCTAssertEqual(floor.branch(window).map(\.id), expected, window.id)
        }
    }

    /// 逐字照抄 HEAD `MemoryBenchLocalExecutor.branch`（parentId 回走，不做可见过滤）
    private func legacyWalk(_ window: MemoryBenchRecallFloor.Window) -> [MemoryBenchRecallFloor.Node] {
        let byId = Dictionary(uniqueKeysWithValues: window.nodes.map { ($0.id, $0) })
        var path: [MemoryBenchRecallFloor.Node] = []
        var next: String? = window.current
        var seen = Set<String>()
        while let id = next, seen.insert(id).inserted, let node = byId[id] {
            path.append(node)
            next = node.parent
        }
        return path.reversed()
    }
}

/// `installFiles` 的 daily 落盘：文件名必须是 `self.daily`（`daily/\(daily).md` 里的 `daily`
/// 曾被渲染结果遮蔽，写成了 `daily/<整段 frontmatter>.md`）。不依赖宿主时区。
final class MemoryBenchRecallFloorInstallTests: XCTestCase {
    private var fixtureURL: URL {
        Bundle.module.url(forResource: "conversation-floor-schema1", withExtension: "json", subdirectory: "Fixtures")!
    }

    func testInstallFilesWritesDailyUnderDateKey() throws {
        let (floor, _) = try MemoryBenchRecallFloor.load(contentsOf: fixtureURL, variant: "xingyan")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-bench-daily-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try floor.installFiles(root: root, wiki: WikiStore(root: root.appendingPathComponent("wiki")))
        XCTAssertEqual(floor.daily, "2026-10-30")
        let expected = FrontmatterCodec.render(
            meta: [("date", floor.daily), ("sourceConversations", RecallTool.json([floor.windows[0].id]))],
            body: "林栖的云桥城旧日航图")
        let dailyRoot = root.appendingPathComponent("daily")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dailyRoot.path), ["2026-10-30.md"])
        XCTAssertEqual(try String(contentsOf: dailyRoot.appendingPathComponent("2026-10-30.md"), encoding: .utf8), expected)
    }
}
