import XCTest
import Network
@testable import 记忆花园

/// 跑一次（plan-memory-audit-home-trial 第五节）：用例 × 配方 × 模型、上限不截、三样不许重复、本机模型不收、模板先全渲染、
/// 最多 3 个并发、能停；每格完成就落盘、全部写完才标完成、启动时遗留的标中断；错误在调用边界脱敏；用量 / 钱分实测 / 估算 / 未知；
/// 存 run.json + requests.jsonl、自动配标签、可插拔打分、记一条试写日志；不碰记忆数据、不进健康
final class MemoryBenchRunnerTests: XCTestCase {

    private let pid = "xctest-bench-runner"
    private var dir: URL!
    private var store: MemoryBenchStore!
    private let writer = MemoryBenchC2Writer()
    private let haiku = MemoryBenchModelRef(credentialId: "card", modelId: "haiku", name: "Haiku")
    private let sonnet = MemoryBenchModelRef(credentialId: "card", modelId: "sonnet", name: "Sonnet")

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xctest-bench-run-\(UUID().uuidString)", isDirectory: true)
        store = MemoryBenchStore(root: dir)
    }

    override func tearDown() {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private var probe: MemoryBenchSet {
        get throws { try XCTUnwrap(MemoryBenchStore.builtInSets().first { $0.id == "c2-probe" }) }
    }

    private var current: MemoryBenchRecipe { writer.builtInRecipes(defaults: UserDefaults(suiteName: "xctest-bench-empty")!)[0] }

    private func variant(_ id: String, system: String? = nil) -> MemoryBenchRecipe {
        var r = current
        r.id = id
        r.name = "外星 \(id)"
        r.parent = current.id
        r.builtIn = false
        if let system { r.system = system }
        return r
    }

    private static func card(_ content: String) -> String {
        #"{"msg":1,"content":"\#(content)","tags":[],"importance":3,"emotion":0,"resolved":null,"category":"fact","subject":"岚舟","speaker":"用户自述"}"#
    }

    /// 假模型：按用例给固定输出（08 那段 Haiku 多记一条「害怕水」），Sonnet 在 01 上报错
    private static let fake: MemoryBenchCaller = { model, prompt in
        if prompt.user.contains("请把包裹放在门口") {
            if model.modelId == "sonnet" { throw URLError(.timedOut) }
            return MemoryBenchCallResult(text: #"{"fragments":["# + card("岚舟乳糖不耐，改喝燕麦拿铁") + "]}",
                                         usage: MemoryBenchUsage(input: 100, output: 20), usd: 0.001, costSource: .measured)
        }
        var cards = [card("岚舟每周六下午去旧书店半盏看书")]
        if model.modelId == "haiku" { cards.append(card("岚舟害怕水")) }
        return MemoryBenchCallResult(text: #"{"fragments":["# + cards.joined(separator: ",") + "]}",
                                     usage: MemoryBenchUsage(input: 200, output: 30), usd: 0.002, costSource: .measured)
    }

    // MARK: - 组合 / 校验

    func testJobsAreGroupedByCaseAndLimitIsNotTruncated() throws {
        let p = try probe
        let jobs = try MemoryBenchRunner.jobs(cases: Array(p.cases.prefix(2)), recipes: [current, variant("v2")], models: [haiku, sonnet])
        XCTAssertEqual(jobs.count, 8)
        XCTAssertEqual(jobs.prefix(4).map(\.testCase.id), ["01", "01", "01", "01"], "按用例分组排")
        XCTAssertEqual(jobs.prefix(2).map(\.model.id), [haiku.id, sonnet.id])
        XCTAssertThrowsError(try MemoryBenchRunner.jobs(cases: p.cases, recipes: [current, variant("a"), variant("b")], models: [haiku, sonnet])) {
            XCTAssertEqual($0 as? MemoryBenchRunError, .tooMany(count: 72, limit: 60), "超了报数，不默默截")
        }
        XCTAssertThrowsError(try MemoryBenchRunner.jobs(cases: [], recipes: [current], models: [haiku])) {
            XCTAssertEqual($0 as? MemoryBenchRunError, .empty)
        }
    }

    /// astra zd2 #5：重复的身份以前会在发完请求后让 `Dictionary(uniqueKeysWithValues:)` 崩掉；现在发请求前就拒
    func testDuplicatesAreRejectedBeforeAnyCall() async throws {
        let p = try probe
        var twin = p.cases[1]
        twin.id = p.cases[0].id
        XCTAssertThrowsError(try MemoryBenchRunner.jobs(cases: [p.cases[0], twin], recipes: [current], models: [haiku])) {
            XCTAssertEqual($0 as? MemoryBenchRunError, .duplicate(kind: "用例", id: "01"))
        }
        XCTAssertThrowsError(try MemoryBenchRunner.jobs(cases: [p.cases[0]], recipes: [current, current], models: [haiku])) {
            XCTAssertEqual($0 as? MemoryBenchRunError, .duplicate(kind: "配方", id: current.id))
        }
        XCTAssertThrowsError(try MemoryBenchRunner.jobs(cases: [p.cases[0]], recipes: [current], models: [haiku, haiku])) {
            XCTAssertEqual($0 as? MemoryBenchRunError, .duplicate(kind: "模型", id: haiku.id))
        }
        var set = p
        set.cases = [p.cases[0], twin]
        let calls = Counter()
        do {
            _ = try await MemoryBenchRunner.run(writer: writer, set: set, recipes: [current], models: [haiku], store: store, profileId: pid,
                                                caller: { _, _ in await calls.bump(); return MemoryBenchCallResult() })
            XCTFail("应该抛")
        } catch {
            XCTAssertEqual(error as? MemoryBenchRunError, .duplicate(kind: "用例", id: "01"))
        }
        let n = await calls.value
        XCTAssertEqual(n, 0)
    }

    /// astra zd2 #7 #8：本机模型这一刀不收（送出去的会被裁、停也停不住，和记录对不上）
    func testLocalModelsAreRejected() throws {
        let local = MemoryBenchModelRef(credentialId: "", modelId: "qwen", name: "本机 1.7B", local: true)
        XCTAssertThrowsError(try MemoryBenchRunner.jobs(cases: [try probe.cases[0]], recipes: [current], models: [haiku, local])) {
            XCTAssertEqual($0 as? MemoryBenchRunError, .localModel("本机 1.7B"))
        }
    }

    func testEstimateSumsKnownPrices() throws {
        let p = try probe
        let jobs = try MemoryBenchRunner.jobs(cases: Array(p.cases.prefix(2)), recipes: [current], models: [haiku, sonnet])
        let prompts = try MemoryBenchRunner.prompts(jobs, writer: writer)
        XCTAssertEqual(MemoryBenchRunner.estimate(jobs, prompts: prompts) { m, _ in m.modelId == "haiku" ? 0.01 : nil }, 0.02)
        XCTAssertNil(MemoryBenchRunner.estimate(jobs, prompts: prompts) { _, _ in nil })
    }

    func testBrokenTemplateStopsBeforeAnyCall() async throws {
        let calls = Counter()
        do {
            _ = try await MemoryBenchRunner.run(writer: writer, set: try probe, caseIds: ["01"], recipes: [variant("bad", system: "{{不存在}}")],
                                                models: [haiku], store: store, profileId: pid,
                                                caller: { _, _ in await calls.bump(); return MemoryBenchCallResult() })
            XCTFail("应该抛")
        } catch let e as MemoryBenchRunError {
            guard case .template(let recipe, let caseId, let message) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(recipe, "外星 bad")
            XCTAssertEqual(caseId, "01")
            XCTAssertTrue(message.contains("第 1 行"), message)
        }
        let n = await calls.value
        XCTAssertEqual(n, 0, "写错就一格都不发")
        XCTAssertTrue(store.runs().isEmpty)
    }

    // MARK: - 跑

    func testRunRecordsEverythingAndScores() async throws {
        let p = try probe
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let run = try await MemoryBenchRunner.run(writer: writer, set: p, caseIds: ["01", "08"], recipes: [current, variant("v2")],
                                                  models: [haiku, sonnet], store: store, profileId: pid, caller: Self.fake,
                                                  runId: "r1", now: { t })
        XCTAssertEqual(run.status, .done)
        XCTAssertEqual(run.cells.count, 8)
        XCTAssertEqual(run.cells.map(\.caseId), ["01", "01", "01", "01", "08", "08", "08", "08"], "收尾按展开顺序排好")
        XCTAssertEqual(run.set.revision, p.revision)
        XCTAssertEqual(run.caseIds, ["01", "08"])

        let failed = run.cells.filter { $0.error != nil }
        XCTAssertEqual(failed.count, 2, "Sonnet 在 01 上两个配方都报错")
        XCTAssertTrue(failed.allSatisfy { $0.caseId == "01" && $0.modelId == sonnet.id && $0.output == nil && $0.usd == nil })

        let haiku08 = try XCTUnwrap(run.cells.first { $0.caseId == "08" && $0.modelId == haiku.id && $0.recipeId == current.id })
        XCTAssertEqual(haiku08.items.map(\.text), ["岚舟每周六下午去旧书店半盏看书", "岚舟害怕水"])
        XCTAssertEqual(haiku08.usage, MemoryBenchUsage(input: 200, output: 30))
        XCTAssertEqual(haiku08.usd, 0.002)
        XCTAssertEqual(haiku08.costSource, .measured)
        let judged = run.judgments.filter { $0.cellId == haiku08.id }
        XCTAssertEqual(judged.map(\.verdict), [.right, .wrong], "自动配：半盏对、怕水错")
        XCTAssertTrue(judged.allSatisfy { $0.by == .auto })

        XCTAssertEqual(run.scores.count, 4, "每个「配方 × 模型」一个占位分")
        let s = try XCTUnwrap(run.scores.first { $0.recipeId == current.id && $0.modelId == haiku.id })
        XCTAssertEqual(s.scorer, "basic")
        XCTAssertEqual(s.mainName, "判对比例")
        XCTAssertEqual(try XCTUnwrap(s.main), 2.0 / 3.0, accuracy: 1e-9, "01 一条对 + 08 一对一错")
        XCTAssertEqual(s.parts["判错"], 1)
        XCTAssertEqual(s.parts["美元"] ?? 0, 0.003, accuracy: 1e-9)

        XCTAssertEqual(store.run(id: "r1"), run, "run.json 存下来，和返回的一样")
        let requests = store.requests(runId: "r1")
        XCTAssertEqual(requests.count, 8, "每格一行完整日志")
        XCTAssertTrue(requests.allSatisfy { !$0.system.isEmpty && !$0.user.isEmpty })
        XCTAssertEqual(requests.filter { $0.error != nil }.count, 2)
    }

    /// zd2 live 实锤：用真时钟跑（带毫秒以下的零头），run.json 读回来也要和内存里那份一模一样
    func testRunWithRealClockReadsBackIdentical() async throws {
        let run = try await MemoryBenchRunner.run(writer: writer, set: try probe, caseIds: ["08"], recipes: [current], models: [haiku],
                                                  store: store, profileId: pid, caller: Self.fake)
        XCTAssertEqual(store.run(id: run.id), run)
        let at = Date(timeIntervalSince1970: 1_800_000_000.123_456_7)
        var copy = run
        copy.judgments.append(MemoryBenchJudgment(cellId: run.cells[0].id, item: 0, verdict: .weak, labelId: nil, by: .human, at: MemoryBench.stamp(at)))
        try store.saveRun(copy)
        XCTAssertEqual(store.run(id: run.id), copy, "截到整毫秒的时间存 → 读逐位相同")
    }

    func testHumanJudgmentOverridesAutoAndRescores() async throws {
        var run = try await MemoryBenchRunner.run(writer: writer, set: try probe, caseIds: ["08"], recipes: [current], models: [haiku],
                                                  store: store, profileId: pid, caller: Self.fake)
        let cell = try XCTUnwrap(run.cells.first)
        XCTAssertEqual(run.scored(with: writer.scorers).first?.main, 0.5)
        run.judgments.append(MemoryBenchJudgment(cellId: cell.id, item: 1, verdict: .weak, labelId: nil, by: .human, at: Date()))
        let effective = run.effectiveJudgments()
        XCTAssertEqual(effective.count, 2)
        XCTAssertEqual(effective.first { $0.item == 1 }?.verdict, .weak, "她判的压过自动配的")
        XCTAssertEqual(run.scored(with: writer.scorers).first?.main, 0.5, "1 对 / (1 对 + 1 偏弱)")
        run.judgments.append(MemoryBenchJudgment(cellId: cell.id, item: 1, verdict: .right, labelId: nil, by: .auto, at: Date().addingTimeInterval(9)))
        XCTAssertEqual(run.effectiveJudgments().first { $0.item == 1 }?.verdict, .weak, "后来的自动配也压不过她判的")
    }

    func testAtMostThreeCallsInFlight() async throws {
        let gauge = Gauge()
        let run = try await MemoryBenchRunner.run(writer: writer, set: try probe, caseIds: ["01", "02", "03", "04", "05"],
                                                  recipes: [current], models: [haiku, sonnet], store: store, profileId: pid,
                                                  caller: { _, _ in
                                                      await gauge.enter()
                                                      try await Task.sleep(nanoseconds: 20_000_000)
                                                      await gauge.leave()
                                                      return MemoryBenchCallResult(text: #"{"fragments":[]}"#)
                                                  })
        XCTAssertEqual(run.cells.count, 10)
        let peak = await gauge.peak
        XCTAssertLessThanOrEqual(peak, MemoryBenchRunner.maxConcurrent)
        XCTAssertGreaterThan(peak, 1, "真的并发了")
        XCTAssertTrue(run.cells.allSatisfy { $0.error == nil && $0.items.isEmpty }, "交空正常")
        XCTAssertTrue(run.scores.allSatisfy { $0.main == nil }, "没有可判的条目 = 没有主分")
        XCTAssertTrue(run.cells.allSatisfy { $0.usage == nil && $0.usd == nil }, "没报用量就是未知，不记 0")
        XCTAssertEqual(run.unpricedCells, 10)
    }

    func testCancelKeepsWhatFinished() async throws {
        let p = try probe
        let started = Counter()
        let task = Task {
            try await MemoryBenchRunner.run(writer: writer, set: p, recipes: [current], models: [haiku], store: store, profileId: pid,
                                            caller: { _, _ in
                                                await started.bump()
                                                try await Task.sleep(nanoseconds: 200_000_000)
                                                return MemoryBenchCallResult(text: #"{"fragments":[]}"#)
                                            })
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let run = try await task.value
        XCTAssertEqual(run.status, .cancelled)
        let n = await started.value
        XCTAssertLessThan(n, p.cases.count, "停了就不再发新的")
        XCTAssertEqual(store.run(id: run.id)?.status, .cancelled, "停下的也存")
    }

    // MARK: - 中途被杀（astra zd2 #1）

    /// 每格一完成就落盘：跑到第 3 格时看盘上，前面做完的格子和请求记录都已经在了，状态还是 running
    func testEachFinishedCellIsPersistedBeforeTheRunEnds() async throws {
        let p = try probe
        let seen = Snapshot()
        let store = self.store!
        let run = try await MemoryBenchRunner.run(writer: writer, set: p, caseIds: ["01", "02", "03", "04"], recipes: [current], models: [haiku],
                                                  store: store, profileId: pid,
                                                  caller: { _, prompt in
                                                      if prompt.user.contains("周报") || prompt.user.contains("手账") {
                                                          await seen.take(store.run(id: "persist"), store.requests(runId: "persist").count)
                                                      }
                                                      return MemoryBenchCallResult(text: #"{"fragments":[]}"#)
                                                  }, runId: "persist")
        XCTAssertEqual(run.status, .done)
        let snaps = await seen.all
        XCTAssertFalse(snaps.isEmpty)
        XCTAssertTrue(snaps.allSatisfy { $0.run?.status == .running }, "跑完之前一直是 running")
        XCTAssertTrue(snaps.allSatisfy { ($0.run?.cells.count ?? -1) == $0.requests }, "格子和请求记录一起落盘")
        XCTAssertGreaterThan(snaps.map(\.requests).max() ?? 0, 0, "后面的格子开跑时，前面做完的已经在盘上")
    }

    /// 启动时：遗留的 running 标成中断、做完的格子留着并打分；这个进程正在跑的不动
    func testLeftoverRunningIsMarkedInterrupted() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let cell = MemoryBenchCell(id: "c", caseId: "08", recipeId: current.id, modelId: haiku.id, output: "{}",
                                   items: [MemoryBenchItem(index: 0, text: "x", fields: [:])], checks: [], usage: nil, usd: nil,
                                   costSource: nil, ms: 1, error: nil)
        func leftover(_ id: String) -> MemoryBenchRun {
            MemoryBenchRun(id: id, writer: "c2", at: t, finishedAt: nil, status: .running, set: .init(id: "s", name: "s", revision: "r"),
                           recipes: [current], models: [haiku], caseIds: ["08"], cells: [cell],
                           judgments: [MemoryBenchJudgment(cellId: "c", item: 0, verdict: .right, labelId: nil, by: .auto, at: t)],
                           scores: [], pinned: false, note: nil)
        }
        try store.saveRun(leftover("killed"))
        try store.saveRun(leftover("live"))
        XCTAssertEqual(store.markInterrupted(active: ["live"], scorers: { _ in [MemoryBenchBasicScorer()] }, now: t), 1)
        let killed = try XCTUnwrap(store.run(id: "killed"))
        XCTAssertEqual(killed.status, .interrupted)
        XCTAssertEqual(killed.cells, [cell], "做完的格子留着")
        XCTAssertEqual(killed.scores.first?.main, 1.0, "按做完的格子重新打分")
        XCTAssertEqual(store.run(id: "live")?.status, .running, "这个进程正在跑的不动")
    }

    // MARK: - 用量 / 钱（astra zd2 #9）

    func testAccountingKeepsUnknownsUnknown() {
        XCTAssertTrue(MemoryBenchRunner.accounting(nil, spent: nil) == (nil, nil, nil))
        let missing = TokenUsage(inputTokens: 0, outputTokens: 0, completeness: .missing)
        XCTAssertTrue(MemoryBenchRunner.accounting(missing, spent: 0) == (nil, nil, nil), "回包没报用量：token / 钱都未知，不记 0")

        var measured = TokenUsage(inputTokens: 100, outputTokens: 20)
        measured.ledgerCostRecorded = true
        measured.ledgerCostUSD = 0.004
        XCTAssertTrue(MemoryBenchRunner.accounting(measured, spent: 0.004) == (MemoryBenchUsage(input: 100, output: 20), 0.004, .measured))

        var unpriced = TokenUsage(inputTokens: 100, outputTokens: 20)
        unpriced.ledgerCostRecorded = true
        unpriced.ledgerCostUSD = nil
        XCTAssertTrue(MemoryBenchRunner.accounting(unpriced, spent: 0) == (MemoryBenchUsage(input: 100, output: 20), nil, .unpriced),
                      "价目表里没有：金额未知，不是 $0")

        var snapshot = TokenUsage(inputTokens: 100, outputTokens: 20, completeness: .snapshot)
        snapshot.ledgerCostRecorded = true
        snapshot.ledgerCostUSD = 0.004
        XCTAssertTrue(MemoryBenchRunner.accounting(snapshot, spent: 0.004)
                      == (MemoryBenchUsage(input: 100, output: 20, source: MemoryBenchUsage.estimated), 0.004, .estimated))
    }

    // MARK: - 脱敏（astra zd2 #2）

    /// 假 key + 假鉴权头，本地假端点回 HTTP 200 但回包结构不对、正文回显两样：bench 的 run.json / requests.jsonl 里都不能有
    @MainActor
    func testErrorsAreRedactedAtTheCallerBoundary() async throws {
        let key = "sk-FAKE-bench-key-1234567890"
        let header = "hdr-FAKE-secret-0987654321"
        let server = try EchoServer(body: #"{"error":"invalid key: \#(key) / header \#(header)","note":"see https://x.test/v1?key=\#(key)"}"#)
        try server.start()
        defer { server.stop() }
        let credentialId = "xctest-bench-redact-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "fake-model", name: "Fake")
        let manager = ProviderManager()
        manager.addCredential(APICredential(id: credentialId, name: "Fake", emoji: "🧪", type: .openaiCompatible, baseURL: server.baseURL,
                                            extraHeaders: ["X-Api-Key": header, "X-Trace": "plain"], models: [model], toolsSupported: false))
        manager.setApiKey(key, for: credentialId)
        defer {
            manager.setApiKey("", for: credentialId)
            manager.removeCredential(id: credentialId)
        }
        XCTAssertEqual(Set(MemoryBenchRunner.secrets(for: credentialId, providerManager: manager)), [key, header], "名字带 key 的头算秘密，别的不算")

        let run = try await MemoryBenchRunner.run(writer: writer, set: try probe, caseIds: ["08"], recipes: [current],
                                                  models: [MemoryBenchModelRef(model)], store: store, profileId: pid,
                                                  caller: MemoryBenchRunner.liveCaller(providerManager: manager, profileId: pid))
        let cell = try XCTUnwrap(run.cells.first)
        let error = try XCTUnwrap(cell.error, "坏回包要报错")
        XCTAssertFalse(error.contains(key) || error.contains(header), error)
        XCTAssertGreaterThanOrEqual(error.components(separatedBy: SentRequestStore.redactedKey).count - 1, 2,
                                    "回包原文确实进了错误（key 和鉴权头各一处），在调用边界被换掉了：\(error)")
        let onDisk = try String(contentsOf: dir.appendingPathComponent("runs/\(MemoryBenchStore.fileName(run.id))/run.json"), encoding: .utf8)
            + String(contentsOf: dir.appendingPathComponent("runs/\(MemoryBenchStore.fileName(run.id))/requests.jsonl"), encoding: .utf8)
        XCTAssertFalse(onDisk.contains(key), "key 不进 bench")
        XCTAssertFalse(onDisk.contains(header), "鉴权头不进 bench")
        XCTAssertFalse(onDisk.contains("?key="), "URL 里的 query 也去掉")
    }

    // MARK: - 日志 / 不碰记忆

    func testLogsOneTrialEntryAndTouchesNoMemory() async throws {
        _ = try await MemoryBenchRunner.run(writer: writer, set: try probe, caseIds: ["08"], recipes: [current], models: [haiku],
                                            store: store, profileId: pid, caller: Self.fake)
        MemoryWriteLog.flush()
        let log = MemoryWriteLog.entries(profileId: pid)
        XCTAssertEqual(log.count, 1, "一次跑一条汇总")
        XCTAssertEqual(log[0].writer, "C2")
        XCTAssertEqual(log[0].trial, true)
        XCTAssertTrue(log[0].ok, "试写不算失败")
        XCTAssertTrue(log[0].note.contains("C2 质量探针"), log[0].note)
        XCTAssertEqual(log[0].costUSD ?? 0, 0.002, accuracy: 1e-9)
        XCTAssertNil(MemoryWriteLog.latest(.c2, in: log), "状态行「最近那条」不认试写")
        XCTAssertNil(MemoryHealthStore.status(.extract, profileId: pid).lastOK, "不进健康状态")
        let memory = FileLibraryStore.memoryRoot(profileId: pid)
        let made = (try? FileManager.default.contentsOfDirectory(atPath: memory.path)) ?? []
        XCTAssertEqual(made, ["log"], "记忆树里只多了日志，别的（sessions / windows / timeline / wiki）都没碰")
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}

private actor Gauge {
    private var now = 0
    private(set) var peak = 0
    func enter() {
        now += 1
        peak = max(peak, now)
    }
    func leave() { now -= 1 }
}

private actor Snapshot {
    struct Seen: Sendable {
        let run: MemoryBenchRun?
        let requests: Int
    }
    private(set) var all: [Seen] = []
    func take(_ run: MemoryBenchRun?, _ requests: Int) { all.append(Seen(run: run, requests: requests)) }
}

/// 本地假端点：每个请求都回 HTTP 200 + 同一份 JSON（结构不对，正文回显秘密）
private final class EchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MemoryBenchRunnerTests.EchoServer")
    private let body: Data

    init(body: String) throws {
        self.body = Data(body.utf8)
        listener = try NWListener(using: .tcp, on: .any)
    }

    var baseURL: String { "http://127.0.0.1:\(listener.port!.rawValue)/v1" }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success else { throw URLError(.timedOut) }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, _ accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if Self.complete(buffer) {
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(self.body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(self.body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if error != nil || done {
                connection.cancel()
            } else {
                self.receive(connection, buffer)
            }
        }
    }

    private static func complete(_ request: Data) -> Bool {
        guard let range = request.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let header = String(decoding: request[..<range.lowerBound], as: UTF8.self)
        let length = header.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        return request.distance(from: range.upperBound, to: request.endIndex) >= length
    }
}
