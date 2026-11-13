import XCTest
@testable import MemoryCore

/// 试写台的数据和存储（plan-memory-audit-home-trial 3.2）：楼层 `bench/`、JSON 带 schema、坏文件当没有、内置考卷随 app 走
final class MemoryBenchStoreTests: XCTestCase {

    private var dir: URL!
    private var store: MemoryBenchStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xctest-bench-\(UUID().uuidString)", isDirectory: true)
        store = MemoryBenchStore(root: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func set(_ id: String, writer: String = "c2", inputs: [String] = ["a"]) -> MemoryBenchSet {
        MemoryBenchSet(id: id, name: "考卷 \(id)", writer: writer, source: .floor, note: nil, createdAt: nil,
                       cases: inputs.enumerated().map { i, s in
                           MemoryBenchCase(id: "\(i)", title: "t", input: .object(["x": .string(s)]), labels: [], note: nil)
                       })
    }

    private func run(_ id: String, at: Date, writer: String = "c2", setId: String = "s", pinned: Bool = false) -> MemoryBenchRun {
        MemoryBenchRun(id: id, writer: writer, at: at, finishedAt: at, status: .done, set: .init(id: setId, name: "s", revision: "r"),
                       recipes: [], models: [], caseIds: [], cells: [], judgments: [], scores: [], pinned: pinned, note: nil)
    }

    // MARK: - 内置考卷


    // MARK: - 考卷


    func testBrokenFilesAreSkipped() throws {
        try store.saveSet(set("ok"))
        let bad = dir.appendingPathComponent("sets/bad.json")
        try Data("{不是 json".utf8).write(to: bad)
        XCTAssertEqual(store.floorSets().map(\.id), ["ok"], "坏文件当没有，不崩")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path), "也不删、不覆盖")
    }

    func testRevisionHashesInputsOnly() {
        var a = set("x", inputs: ["一", "二"])
        let base = a.revision
        a.cases[0].labels.append(MemoryBenchLabel(id: "l", kind: "应记", text: "t", keys: ["k"], from: "她判"))
        a.cases[0].title = "改了标题"
        a.name = "改了名"
        XCTAssertEqual(a.revision, base, "加标签 / 改标题不断历次线")
        a.cases[1].input = .object(["x": .string("三")])
        XCTAssertNotEqual(a.revision, base, "输入改了另起一条线")
    }

    // MARK: - 配方

    private var recipe: MemoryBenchRecipe {
        MemoryBenchRecipe(id: "v1", writer: "c2", name: "外星 v1", parent: "c2-current", system: "{{对话}}", user: "u",
                          params: ["要求subject和speaker": .bool(false)], checks: "current", builtIn: false, savedAt: Date(timeIntervalSince1970: 0))
    }

    func testRecipeBookRoundTripAndLimit() throws {
        XCTAssertEqual(try store.recipeBook(writer: "c2"), MemoryBenchRecipeBook(writer: "c2", active: nil, versions: []), "没存过 = 空配方簿")
        let r = recipe
        try store.saveRecipeBook(MemoryBenchRecipeBook(writer: "c2", active: r, versions: [r]))
        XCTAssertEqual(try store.recipeBook(writer: "c2").versions, [r])
        XCTAssertEqual(try store.recipeBook(writer: "c2").active?.params["要求subject和speaker"], .bool(false))
        let many = (0...MemoryBenchRecipeBook.maxVersions).map { i -> MemoryBenchRecipe in
            var v = r
            v.id = "v\(i)"
            return v
        }
        XCTAssertThrowsError(try store.saveRecipeBook(MemoryBenchRecipeBook(writer: "c2", active: nil, versions: many)))
    }

    /// astra zd2 #4：坏了 / 新版本写的配方簿不能当成空的，普通保存不许覆盖原件
    func testBrokenOrNewerRecipeBookIsNotOverwritten() throws {
        let url = dir.appendingPathComponent("recipes/c2.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data(#"{"schema":1,"writer":"c2","versions":"不是数组"}"#.utf8)
        try broken.write(to: url)
        XCTAssertThrowsError(try store.recipeBook(writer: "c2")) {
            XCTAssertEqual($0 as? MemoryBenchStore.LoadError, .corrupt("c2.json"))
        }
        XCTAssertThrowsError(try store.saveRecipeBook(MemoryBenchRecipeBook(writer: "c2", active: nil, versions: [recipe])))
        XCTAssertEqual(try Data(contentsOf: url), broken, "原件一个字没动")

        let newer = Data(#"{"schema":99,"writer":"c2","versions":[],"future":true}"#.utf8)
        try newer.write(to: url)
        XCTAssertThrowsError(try store.recipeBook(writer: "c2")) {
            XCTAssertEqual($0 as? MemoryBenchStore.LoadError, .unsupportedSchema(file: "c2.json", schema: 99))
        }
        XCTAssertThrowsError(try store.saveRecipeBook(MemoryBenchRecipeBook(writer: "c2", active: nil, versions: [])))
        XCTAssertEqual(try Data(contentsOf: url), newer)

        try Data("不是 json".utf8).write(to: dir.appendingPathComponent("sets/x.json").creatingParent())
        XCTAssertThrowsError(try store.saveSet(MemoryBenchSet(id: "x", name: "x", writer: "c2", source: .floor, note: nil, createdAt: nil, cases: [])),
                             "考卷同理：同 id 的原件坏了不覆盖")
    }

    func testDatesRoundTripExactly() throws {
        let messy = Date(timeIntervalSince1970: 1_800_000_000.123_456_789)
        let stamped = MemoryBench.stamp(messy)
        XCTAssertEqual(stamped.timeIntervalSince1970, 1_800_000_000.123, accuracy: 1e-6, "截到整毫秒")
        XCTAssertEqual(MemoryBench.stamp(stamped), stamped, "再截不变")
        var book = MemoryBenchRecipeBook(writer: "c2", active: nil, versions: [recipe])
        book.versions[0].savedAt = stamped
        try store.saveRecipeBook(book)
        XCTAssertEqual(try store.recipeBook(writer: "c2"), book, "存 → 读逐位相同")
        let raw = try String(contentsOf: dir.appendingPathComponent("recipes/c2.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("1800000000123"), "存的是 1970 起的整毫秒")
    }

    // MARK: - 跑

    func testRunsAndRequestLog() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveRun(run("old", at: t))
        try store.saveRun(run("new", at: t.addingTimeInterval(60)))
        try store.saveRun(run("other", at: t.addingTimeInterval(120), writer: "a2"))
        XCTAssertEqual(store.runs(writer: "c2").map(\.id), ["new", "old"], "新的在前")
        XCTAssertEqual(store.runs(setId: "s").count, 3)
        XCTAssertEqual(store.run(id: "old")?.at, t)

        let req = MemoryBenchRequest(cellId: "c", at: t, model: "m", system: "s", user: "u\n两行", response: "r", error: nil,
                                     usage: .init(input: 3, output: 4), usd: 0.01, costSource: .measured, ms: 5)
        try store.appendRequests([req], runId: "old")
        try store.appendRequests([req, req], runId: "old")
        XCTAssertEqual(store.requests(runId: "old"), [req, req, req], "一行一条，追加")
    }

    /// astra zd2 #6：30 天前没钉的，完整日志 + 每格原始输出一起清；条目 / 判断 / 分数留着；钉住的整份跳过
    func testPruneClearsLogsAndRawOutputsButKeepsResults() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-31 * 86400)
        let cell = MemoryBenchCell(id: "c", caseId: "01", recipeId: "r", modelId: "m", output: "{\"fragments\":[原文]}",
                                   items: [MemoryBenchItem(index: 0, text: "岚舟乳糖不耐", fields: [:])], checks: [],
                                   usage: MemoryBenchUsage(input: 1, output: 2), usd: 0.01, costSource: .measured, ms: 1, error: nil)
        func withCell(_ r: MemoryBenchRun) -> MemoryBenchRun {
            var r = r
            r.cells = [cell]
            r.judgments = [MemoryBenchJudgment(cellId: "c", item: 0, verdict: .right, labelId: "01-y1", by: .human, at: old)]
            r.scores = [MemoryBenchScore(scorer: "basic", version: 1, recipeId: "r", modelId: "m", main: 1, mainName: "判对比例", parts: [:])]
            return r
        }
        try store.saveRun(withCell(run("old", at: old)))
        try store.saveRun(withCell(run("pinned", at: old, pinned: true)))
        try store.saveRun(withCell(run("recent", at: now.addingTimeInterval(-86400))))
        let req = MemoryBenchRequest(cellId: "c", at: old, model: "m", system: "s", user: "u", response: nil, error: "x", usage: nil, usd: nil,
                                     costSource: nil, ms: 1)
        for id in ["old", "pinned", "recent"] { try store.appendRequests([req], runId: id) }
        XCTAssertEqual(store.pruneLogs(now: now), 1)

        XCTAssertTrue(store.requests(runId: "old").isEmpty, "30 天前没钉的清完整日志")
        let pruned = try XCTUnwrap(store.run(id: "old"))
        XCTAssertNil(pruned.cells[0].output, "原始输出也清")
        XCTAssertEqual(pruned.cells[0].items, cell.items, "条目留着")
        XCTAssertEqual(pruned.cells[0].usd, 0.01)
        XCTAssertEqual(pruned.judgments.count, 1, "判断留着")
        XCTAssertEqual(pruned.scores.count, 1, "分数留着")
        XCTAssertEqual(pruned.outputsPrunedAt, now)

        XCTAssertEqual(store.run(id: "pinned")?.cells[0].output, cell.output, "钉住的整份跳过")
        XCTAssertEqual(store.requests(runId: "pinned").count, 1)
        XCTAssertEqual(store.run(id: "recent")?.cells[0].output, cell.output)
        XCTAssertEqual(store.requests(runId: "recent").count, 1)
        XCTAssertEqual(store.pruneLogs(now: now), 0, "清过的不再动")
    }

    // MARK: - 位置 / 文件名

    func testFloorRootIsBesideMemoryNotInsideIt() {
        let memory = dir.appendingPathComponent("memory", isDirectory: true).standardizedFileURL
        let bench = MemoryBenchStore.forMemoryRoot(memory).root.standardizedFileURL
        XCTAssertEqual(bench.deletingLastPathComponent(), memory.deletingLastPathComponent(), "和 memory/ 同一层楼目录")
        XCTAssertFalse(bench.path.hasPrefix(memory.path + "/"), "不在 memory/ 里：助手 fs 工具看不到")
        XCTAssertEqual(bench.lastPathComponent, "bench")
    }

    func testFileNamesCannotEscape() {
        XCTAssertEqual(MemoryBenchStore.fileName("c2-probe_1"), "c2-probe_1")
        for id in ["../x", "a/b", "中文", "", String(repeating: "a", count: 81)] {
            let name = MemoryBenchStore.fileName(id)
            XCTAssertFalse(name.contains("/") || name.contains(".."), id)
            XCTAssertTrue(name.hasPrefix("h"), id)
        }
        XCTAssertNotEqual(MemoryBenchStore.fileName("a/b"), MemoryBenchStore.fileName("a/c"))
    }

    // MARK: - 通用 JSON

    func testJSONKeepsBoolsNumbersAndNesting() throws {
        let v: MemoryBenchJSON = .object(["b": .bool(true), "n": .number(1), "s": .string("1"), "a": .array([.null, .number(2.5)]),
                                          "o": .object(["x": .bool(false)])])
        let back = try MemoryBench.decoder.decode(MemoryBenchJSON.self, from: MemoryBench.encoder.encode(v))
        XCTAssertEqual(back, v, "true 不变成 1，1 不变成 true")
        struct T: Codable, Equatable { var a: Int; var b: [String] }
        XCTAssertEqual(try MemoryBenchJSON.from(T(a: 3, b: ["x"])).decode(T.self), T(a: 3, b: ["x"]))
    }
}

private extension URL {
    /// 先建好上一层目录，再交回自己（造坏文件用）
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
