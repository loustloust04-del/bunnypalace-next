import XCTest
@testable import MemoryCore

/// 通用外壳：工作台的五个工具（越界、只读、翻页、上限）、循环、写入这张工作书的交卷校验。全虚构
final class AgentWorkspaceTests: XCTestCase {
    private var root: URL!
    private let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("out"), withIntermediateDirectories: true)
        try Data("第一行\n双帆的船\n第三行\n".utf8).write(to: root.appendingPathComponent("material.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var workspace: AgentWorkspace { AgentWorkspace(root: root, writable: ["out"]) }

    // MARK: - 工作台

    func testStaysInsideRoot() throws {
        XCTAssertThrowsError(try workspace.resolve("../etc/passwd"))
        XCTAssertThrowsError(try workspace.resolve("out/../../x"))
        XCTAssertEqual(try workspace.resolve("/material.txt").lastPathComponent, "material.txt", "开头的斜杠当成相对根")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("agent-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("秘密".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out/link"), withDestinationURL: outside)
        XCTAssertThrowsError(try workspace.resolve("out/link/secret.txt"), "symlink 指到根外面也拒")
        XCTAssertTrue(workspace.read("out/link/secret.txt", from: nil, count: nil).isError)
        XCTAssertTrue(workspace.write("out/link/new.txt", content: "x").isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
    }

    func testMaterialsAreReadOnly() {
        XCTAssertTrue(workspace.write("material.txt", content: "改掉").isError)
        XCTAssertTrue(workspace.write("other/x.txt", content: "x").isError)
        XCTAssertTrue(workspace.write("out", content: "x").isError, "可写目录本身不能当文件写")
        XCTAssertTrue(workspace.edit("material.txt", old: "双帆", new: "单帆").isError)
        XCTAssertTrue(workspace.read("material.txt", from: nil, count: nil).content.contains("双帆的船"))
    }

    func testWriteEditAndList() {
        XCTAssertFalse(workspace.write("out/a/b.txt", content: "甲\n乙\n甲\n").isError)
        XCTAssertTrue(workspace.edit("out/a/b.txt", old: "甲", new: "丙").content.contains("出现了 2 次"))
        XCTAssertTrue(workspace.edit("out/a/b.txt", old: "丁", new: "丙").content.contains("没找到"))
        XCTAssertFalse(workspace.edit("out/a/b.txt", old: "乙", new: "丙").isError)
        XCTAssertTrue(workspace.read("out/a/b.txt", from: nil, count: nil).content.hasPrefix("甲\n丙\n甲"))
        let listing = workspace.list("").content
        XCTAssertTrue(listing.contains("material.txt  （3 行") && listing.contains("out/  （目录，1 项，可写）"))
        XCTAssertTrue(workspace.list("nope").isError)
    }

    func testReadPagesAndCaps() throws {
        try Data((1...10).map { "行\($0)" }.joined(separator: "\n").utf8).write(to: root.appendingPathComponent("long.txt"))
        var small = workspace
        small.readLines = 4
        let first = small.read("long.txt", from: nil, count: nil).content
        XCTAssertTrue(first.hasPrefix("行1\n行2\n行3\n行4\n") && first.contains("第 1–4 行，共 10 行，下一页 from_line=5"))
        XCTAssertTrue(small.read("long.txt", from: 9, count: 50).content.contains("第 9–10 行，共 10 行，已经到底"))
        XCTAssertTrue(small.read("long.txt", from: 11, count: nil).isError)
        small.readChars = 5
        XCTAssertTrue(small.read("long.txt", from: nil, count: nil).content.contains("第 1–1 行，共 10 行，下一页 from_line=2"), "字数到顶提前翻页，但至少给一行")
    }

    func testSearch() throws {
        try Data("这里也有双帆\n".utf8).write(to: root.appendingPathComponent("out/x.txt"))
        let all = workspace.search("双帆", in: nil).content
        XCTAssertTrue(all.contains("material.txt:2: 双帆的船") && all.contains("out/x.txt:1:"))
        XCTAssertFalse(workspace.search("双帆", in: "out").content.contains("material.txt"))
        XCTAssertTrue(workspace.search("没有这个词", in: nil).content.contains("没搜到"))
        var small = workspace
        small.searchHits = 1
        XCTAssertTrue(small.search("双帆", in: nil).content.contains("一共 2 处，只列了前 1 处"))
    }

    func testToolsDecodeArguments() async {
        let tools = Dictionary(workspace.tools.map { ($0.spec.name, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(Set(tools.keys), ["list", "read", "write", "edit", "search"])
        let read = await tools["read"]?.run(#"{"path":"material.txt","from_line":2,"lines":1}"#)
        XCTAssertTrue(read?.content.hasPrefix("双帆的船") == true)
        let bad = await tools["write"]?.run("{")
        XCTAssertTrue(bad?.isError == true)
    }

    // MARK: - 写入这张工作书

    private var job: WriteJob {
        WriteJob(windowTitle: "模型船",
                 span: (1...3).map { WriteLine(number: $0, who: "岚舟", when: "2026-10-1\($0) 09:00", text: "第 \($0) 句\n换行") },
                 before: [WriteLine(number: 0, who: "星砚", text: "更早的一句")],
                 known: [WriteKnownCard(id: "k1", content: "模型船做成双帆。", subject: "岚舟")], names: names)
    }

    func testWriteJobPreparesMaterialsAndBrief() throws {
        try job.prepare(workspace)
        let transcript = try String(contentsOf: root.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertEqual(transcript, "#1 2026-10-11 09:00 · 岚舟：第 1 句 ⏎ 换行\n#2 2026-10-12 09:00 · 岚舟：第 2 句 ⏎ 换行\n#3 2026-10-13 09:00 · 岚舟：第 3 句 ⏎ 换行\n")
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("before.txt"), encoding: .utf8).hasPrefix("#0  · 星砚：更早的一句"))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("known.jsonl"), encoding: .utf8).contains(#""id":"k1""#))
        XCTAssertTrue(job.brief.contains("这个窗口的名字是「模型船」") && job.brief.contains("2026-10-11 到 2026-10-13") && job.brief.contains("`before.txt`"))
        XCTAssertFalse(WriteJob(windowTitle: "模型船", span: job.span, names: names).brief.contains("`before.txt`"))
    }

    func testWriteJobReviewsOutputFile() throws {
        XCTAssertEqual(job.review(workspace).blocking.count, 1, "没写产出文件")
        try Data("{".utf8).write(to: root.appendingPathComponent("out/archive.json"))
        XCTAssertTrue(job.review(workspace).blocking[0].contains("不是合法的 JSON 数组"))
        let rows = """
        [{"id":"w1","subject":"岚舟","type":"fact","origin":"said","content":"只用水性颜料上色。","msgs":[1],"since":"2026-10-11","confidence":0.9},
         {"id":"w2","subject":"岚舟","type":"fact","origin":"said","content":"模型船改成三帆。","msgs":[2,9],"target":"k1","volatile":true},
         {"id":"w2","subject":"岚舟","type":"fact","origin":"said","content":"编号重复。","msgs":[1]},
         {"subject":"","type":"note","origin":"heard","content":"","msgs":[9],"target":"k9"},
         {"id":"w5","subject":"星砚","type":"instruction","origin":"assistant","content":"这个窗口的星砚今天答应陪她上色。","msgs":[3]}]
        """
        try Data(rows.utf8).write(to: root.appendingPathComponent("out/archive.json"))
        let found = job.review(workspace)
        XCTAssertEqual(found.blocking.count, 2)
        XCTAssertTrue(found.blocking[0].hasPrefix("w2：id 重复"))
        XCTAssertTrue(found.blocking[1].hasPrefix("w4：") && found.blocking[1].contains("target「k9」"))
        XCTAssertEqual(found.hints.count, 1)
        XCTAssertTrue(found.hints[0].hasPrefix("w5 里有「这个窗口」「今天」"))
        let entries = job.collect(workspace)
        XCTAssertEqual(entries.map(\.id), ["w1", "w2", "w5"])
        XCTAssertEqual(entries[1].msgs, [2])
        XCTAssertEqual(entries[1].target, "k1")
        XCTAssertTrue(entries[1].volatile)
    }

    // MARK: - 循环

    func testRunnerDrivesWorkspaceUntilFinishPasses() async {
        let script: [[AgentToolCall]] = [
            [AgentToolCall(id: "1", name: "read", arguments: #"{"path":"transcript.txt"}"#)],
            [AgentToolCall(id: "2", name: "finish", arguments: "{}")],
            [AgentToolCall(id: "3", name: "write", arguments: #"{"path":"out/archive.json","content":"[{\"subject\":\"岚舟\",\"type\":\"fact\",\"origin\":\"said\",\"content\":\"只用水性颜料上色。\",\"msgs\":[1]}]"}"#),
             AgentToolCall(id: "4", name: "check", arguments: "{}")],
            [AgentToolCall(id: "5", name: "finish", arguments: #"{"summary":"记了颜料"}"#)],
        ]
        let seen = Seen()
        let caller = ClosureToolModelCaller { _, turns, _ in
            let round = await seen.next(turns)
            return AgentStep(calls: script[round], usage: AgentUsage(input: 5, output: 1))
        }
        let outcome = await AgentJobRunner.run(job, root: root, caller: caller)
        XCTAssertEqual(outcome.stop, .finished)
        XCTAssertEqual(outcome.summary, "记了颜料")
        XCTAssertEqual(outcome.rounds.map(\.tools), [["read"], ["finish"], ["write", "check"], ["finish"]])
        XCTAssertEqual(job.collect(workspace).count, 1)
        let results = await seen.results
        XCTAssertTrue(results[0].contains("#1 2026-10-11 09:00 · 岚舟：第 1 句"))
        XCTAssertTrue(results[1].contains("还不能结束") && results[1].contains("还没有 `out/archive.json`"))
        XCTAssertTrue(results[3].contains("没看出问题"))
    }

    func testLoopStopsOnBudgetAndUnknownTool() async {
        let caller = ClosureToolModelCaller { _, _, _ in AgentStep(calls: [AgentToolCall(id: "x", name: "bash", arguments: "{}")]) }
        let capped = await AgentJobRunner.run(job, root: root, caller: caller, limits: .init(rounds: 4))
        XCTAssertEqual(capped.stop, .rounds)
        XCTAssertEqual(capped.rounds.count, 4)
        let denied = await AgentJobRunner.run(job, root: root, caller: caller, allow: { false })
        XCTAssertEqual(denied.stop, .budget)
        XCTAssertTrue(denied.rounds.isEmpty)
    }

    private actor Seen {
        var round = 0
        var results: [String] = []
        func next(_ turns: [AgentTurn]) -> Int {
            if case .toolResults(let latest)? = turns.last { results += latest.map(\.content) }
            round += 1
            return round - 1
        }
    }
}
