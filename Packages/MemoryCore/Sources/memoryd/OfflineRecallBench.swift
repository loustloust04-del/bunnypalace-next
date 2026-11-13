import Foundation
import MemoryCore

/// memoryd 的 Y 半边（第 2 刀）：只重放题集里「每轮都有 ops」的用例（recall-24 的 13 题），
/// 读的是 `RecallTool.execute` 的 Y 侧（date/window/segment/messages/search/wiki），
/// 不建 SwiftData、不跑 X 注入、不调模型。X 侧填固定「不可测」桩，主分留给刀 3。
enum OfflineRecallBench {
    static let writerId = "recall"

    static func isRunnable(_ testCase: MemoryBenchCase) -> Bool {
        guard let input = try? testCase.input.decode(MemoryBenchRecallInput.self), !input.turns.isEmpty else { return false }
        return input.turns.allSatisfy { !($0.ops ?? []).isEmpty }
    }

    /// 题集声明的宿主时区（recall-24 全是 America/Los_Angeles）；解不开 = nil
    static func timeZone(of set: MemoryBenchSet) -> String? {
        set.cases.first.flatMap { try? $0.input.decode(MemoryBenchRecallInput.self).profile.timeZone }
    }

    /// Reader 只用来解析 / 自动配标签 / 打分；执行在 `execute`，不读配方里的提示词
    static func writer(floorURL: URL) -> MemoryBenchRecallReader {
        MemoryBenchRecallReader(profileId: "bench-xingyan", contract: { "memoryd-y-only" }, floorURL: floorURL)
    }

    static func recipe(tuning: RecallTuning) throws -> MemoryBenchRecipe {
        guard case .object(var params) = try MemoryBenchJSON.from(tuning) else {
            throw MemoryBenchLocalExecutor.Failure("召回参数不是对象")
        }
        params["contract"] = .string("memoryd-y-only")
        params["tuningSource"] = .string("floor")
        return MemoryBenchRecipe(id: "recall-current", writer: writerId, name: "现行", parent: nil, system: "", user: "",
                                 params: params, checks: "recall", builtIn: true, savedAt: nil)
    }

    /// 一格：装文件半边 → 逐轮重放 ops。X 侧没有可判材料（刀 3 才换 GRDB L1 检索）
    static func execute(testCase: MemoryBenchCase, recipe: MemoryBenchRecipe, floorURL: URL) async throws -> String {
        let input = try testCase.input.decode(MemoryBenchRecallInput.self)
        if input.snapshot == "floor" { throw MemoryBenchLocalExecutor.Failure("本楼层快照还没接上，先用内置 13 题") }
        guard !input.turns.isEmpty, TimeZone(identifier: input.profile.timeZone) != nil else {
            throw MemoryBenchLocalExecutor.Failure("轮序或时区无效")
        }
        // 不能改进程时区：Runner 3 格并发，改 TZ 会串
        guard input.profile.timeZone == Calendar.current.timeZone.identifier else {
            throw MemoryBenchLocalExecutor.Failure("recall 工具只接受宿主时区 \(Calendar.current.timeZone.identifier)，无法隔离重放 \(input.profile.timeZone)")
        }
        let (floor, variant) = try MemoryBenchRecallFloor.load(contentsOf: floorURL, variant: input.snapshot)
        let token = UUID().uuidString
        let pid = "memory-bench-\(token)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(pid, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = MemoryBenchLocalExecutor.preferencesSuite(named: pid)
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw MemoryBenchLocalExecutor.Failure("隔离偏好不可用")
        }
        defer { MemoryBenchLocalExecutor.removePreferences(defaults, suite: suite) }
        defaults.set(variant.master, forKey: "mem_master")
        let tuning = try MemoryBenchJSON.object(recipe.params).decode(RecallTuning.self).validated
        RecallTuningStore.save(tuning, profileId: pid, defaults: defaults)
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        try floor.installFiles(root: root, wiki: wiki)
        let result = try await replay(input, floor: floor, variant: variant, profileId: pid, root: root,
                                      defaults: defaults, tuning: tuning)
        let output = String(decoding: try MemoryBench.lineEncoder.encode(result), as: UTF8.self)
        return output.replacingOccurrences(of: pid, with: "bench-xingyan")
    }

    private static func replay(_ input: MemoryBenchRecallInput, floor: MemoryBenchRecallFloor,
                               variant: MemoryBenchRecallFloor.Variant, profileId: String, root: URL,
                               defaults: UserDefaults, tuning: RecallTuning) async throws -> MemoryBenchRecallOutput {
        let cid = variant.currentConversationId ?? "bench-current-window"
        let participation = floor.windows.first { $0.id == cid }?.memoryEnabled ?? true
        let fragments = floor.fragments
        let environment = RecallEnvironment(
            searchL1: { _, _, _, _, _ in RecallTool.L1Result(hits: [], vectorStatus: nil) },
            locateFragment: { label, _ in
                let hits = fragments.filter { CatalogRecordLine.fragmentLabel($0.id) == label }
                guard hits.count == 1, let fragment = hits.first else { return nil }
                return (fragment.id.uuidString, fragment.text, fragment.conversationId, fragment.nodeId)
            },
            resolveCurrent: nil
        )
        // X 侧本次不测：Reader.parse 见 fullText != "ready" 就把 X 标成不可判
        let x = MemoryBenchRecallOutput.X(searched: false, kept: false, reason: "不可测", sources: [], fullText: "untestable")
        var turns: [MemoryBenchRecallOutput.Turn] = []
        var previous: RecallTool.ExecResult?
        var calls = 0
        var guardrail = MemoryBenchRecallOutput.Guard()
        let forbidden = MemoryBenchLocalExecutor.Forbidden(floor)
        for turn in input.turns {
            try Task.checkCancellation()
            var reads: [MemoryBenchRecallOutput.Y] = []
            var turnCalls = 0
            for operation in turn.ops ?? [] {
                try Task.checkCancellation()
                calls += 1
                turnCalls += 1
                if turnCalls > tuning.maximumRecallCalls {
                    reads.append(.init(op: operation.op, layer: reads.last?.layer ?? "原文", status: "limited", target: "", sourceVersion: nil,
                                       returnedRange: [], next: .init(hasMore: false, cursorIssued: false), deepest: nil))
                    continue
                }
                let resolved = try MemoryBenchLocalExecutor.resolve(.object(operation.args), previous: previous)
                guard case .object(var args) = resolved else { throw MemoryBenchLocalExecutor.Failure("调用参数不是对象") }
                args["op"] = .string(operation.op)
                let json = String(decoding: try MemoryBench.lineEncoder.encode(MemoryBenchJSON.object(args)), as: UTF8.self)
                let requested = try RecallTool.decoder.decode(RecallTool.Input.self, from: Data(json.utf8))
                let before = requested.cursor.flatMap(RecallTool.decodeCursor)
                let result = await RecallTool.execute(inputJSON: json, profileId: profileId, currentConversationId: cid,
                    userName: input.profile.userName, assistantName: input.profile.assistantName,
                    source: floor.conversationSource(profileId: profileId), memoryRoot: root,
                    defaults: defaults, tuning: tuning, memoryParticipation: participation, environment: environment)
                MemoryBenchLocalExecutor.observe(result, requested: before?.input ?? requested, floor: floor, forbidden: forbidden,
                                                 guardrail: &guardrail)
                if let read = result.read {
                    let actual = !result.isError && !(read.returnedRange ?? []).isEmpty
                    // 索引版本里含运行时 profileId；记规范身份，不落随机盐
                    let version = read.layer == "wiki索引"
                        ? RecallTool.revision(RecallTool.json(result.targets).replacingOccurrences(of: profileId, with: "bench-xingyan"))
                        : read.sourceVersion
                    let after = result.cursor.flatMap(RecallTool.decodeCursor)
                    let bounds = MemoryBenchLocalExecutor.rangeBounds(read.returnedRange ?? [], op: operation.op, before: before,
                                                                      after: after, floor: floor)
                    reads.append(.init(op: operation.op, layer: read.layer, status: read.status, target: read.target, sourceVersion: version,
                        returnedRange: read.returnedRange, next: read.next, deepest: actual ? read.layer : nil,
                        continuation: requested.cursor != nil, start: MemoryBenchLocalExecutor.position(before),
                        end: after.map(MemoryBenchLocalExecutor.position),
                        rangeStart: bounds?.0, rangeEnd: bounds?.1, targets: result.targets))
                }
                previous = result
            }
            turns.append(.init(x: x, y: reads))
        }
        return .init(turns: turns, deepestLayer: MemoryBenchRecallOutput.deepest(turns.flatMap(\.y)), calls: calls, guardrail: guardrail)
    }
}
