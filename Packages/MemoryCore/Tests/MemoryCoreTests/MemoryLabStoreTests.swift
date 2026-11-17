import XCTest
@testable import MemoryCore

/// 记忆实验台的记录和落盘（plan-memory-lab §3）：一句一个文件、缺字段的旧记录读得出、改判断原地重写、汇总
final class MemoryLabStoreTests: XCTestCase {
    private var memoryRoot: URL!
    private var store: MemoryLabStore!

    override func setUp() {
        super.setUp()
        memoryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("xctest-lab-\(UUID().uuidString)", isDirectory: true)
        store = MemoryLabStore(memoryRoot: memoryRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: memoryRoot)
        super.tearDown()
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

    private func full(_ id: String = "r1") -> MemoryLabRecord {
        let source = RecallSourceRef(profileId: "floor-xingyan", conversationId: "lab", kind: .page, path: "地点/云桥城", version: "v1")
        let item = RecallItem(source: source, text: "## 云桥城\n岚舟常去的地方", identities: ["云桥城"], tokenCost: 12)
        let decision = RecallTurnDecision(
            turnId: id, branchAnchor: "lab", origin: .user, gateReason: .search, tuning: .defaults, topicAnchor: "云桥城",
            selected: [item], candidates: [item],
            suppressions: [.init(source: .init(profileId: "floor-xingyan", conversationId: "lab", kind: .page, path: "地点/栎川镇", version: "v2"),
                                 reason: .pageLimit)],
            ignored: [], thawed: [], stateAfterResponse: RecallConversationState())
        var receipt = RecallTurnReceipt(decision: decision)
        receipt.delivery = RecallDelivery(
            id: "d1", route: "api",
            items: [.init(kind: RecallDeliveryItem.Kind.page, ref: "page:地点/云桥城|v1", version: "v1", shown: "云桥城", tokens: 12)],
            gate: .init(off: nil, participates: true, triggerOff: false, legacy: false, choices: ["pinned": true],
                        a2Checked: false, everyRound: false, hiddenFragments: 0, hiddenTimeline: 0))
        receipt.reads = [.init(toolCallId: "call-1", turnId: id, layer: "wiki页", target: "地点/云桥城", returnedCount: 1)]
        var tuning = RecallTuning.defaults
        tuning.maximumPages = 5
        return MemoryLabRecord(
            id: id,
            input: .init(text: "云桥城那家皮影作坊还开着吗", at: at(0)),
            environment: .init(profileId: "floor-xingyan", counts: .init(approvedFacts: 15, allFacts: 40, wikiPages: 6, pinned: 2),
                               fingerprint: "abc123", presetName: "星砚", promptHash: "def456", appVersion: "1.0", build: "808",
                               commit: nil, window: MemoryLabRecord.Environment.firstTurn),
            params: .init(items: [MemoryLabRecord.Item.timeline: true, MemoryLabRecord.Item.rootIndex: false], everyRound: false,
                          systemPush: true, recallTool: true, tuning: tuning,
                          model: .init(id: "card/haiku", name: "Haiku", provider: "anthropic"),
                          differences: [.init(key: MemoryLabRecord.Item.systemPush, settings: "false", lab: "true")]),
            happened: .init(messages: [.init(role: "system", content: "你是星砚", source: "角色描述"),
                                       .init(role: "user", content: "云桥城那家皮影作坊还开着吗", source: "对话历史")],
                            receipt: receipt,
                            prompt: .init(segments: [.init(source: "记忆", role: "system", with: "## 云桥城", without: nil)],
                                          everyRound: "", pushed: "## 云桥城"),
                            reply: "还开着，槐序巷那家。", error: nil,
                            rounds: [.init(calls: [.init(id: "call-1", name: "recall", arguments: "{\"op\":\"wiki\"}", result: "云桥城", isError: false)])],
                            usage: .init(requests: 2, input: 9000, output: 60, cacheRead: 0, cacheWrite: 0, costUSD: 0.01),
                            missing: ["其他工具的清单和说明"]),
            judgment: nil, sets: [])
    }

    func testRecordRoundTripsThroughDisk() throws {
        let record = full()
        try store.save(record)
        XCTAssertEqual(store.record(id: "r1"), record)
        let file = memoryRoot.appendingPathComponent("lab/records/r1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "一句一个文件，落在 <记忆根>/lab/records/")
    }

    /// 以后加字段时旧记录的样子：只有编号、那句话、时间
    func testOldRecordWithMissingFieldsStillLoads() throws {
        let dir = memoryRoot.appendingPathComponent("lab/records", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = #"{"id":"old","input":{"text":"林栖今天来过吗","at":1790000000000},"happened":{"reply":"来过"},"futureField":{"x":1}}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("old.json"))
        let record = try XCTUnwrap(store.record(id: "old"))
        XCTAssertEqual(record.input.text, "林栖今天来过吗")
        XCTAssertEqual(record.input.at, at(0))
        XCTAssertEqual(record.happened?.reply, "来过")
        XCTAssertNil(record.schema)
        XCTAssertNil(record.environment)
        XCTAssertNil(record.params)
        XCTAssertNil(record.happened?.receipt)
        XCTAssertNil(record.judgment)
        XCTAssertNil(record.sets)
        // 旧记录也能点拇指
        XCTAssertEqual(try store.judge(id: "old") { $0.verdict = .down }.judgment?.verdict, .down)
    }

    func testJudgeRewritesOnlyJudgmentInPlace() throws {
        let record = full()
        try store.save(record)
        let thumbed = try store.judge(id: "r1", at: at(60)) { $0.verdict = .up }
        XCTAssertEqual(thumbed.judgment, .init(verdict: .up, note: nil, at: at(60)))
        let noted = try store.judge(id: "r1", at: at(120)) { $0.note = "想起的是对的，回得太短" }
        XCTAssertEqual(noted.judgment, .init(verdict: .up, note: "想起的是对的，回得太短", at: at(120)), "加批注不动拇指")
        let cleared = try store.judge(id: "r1", at: at(180)) { $0.verdict = nil }
        XCTAssertEqual(cleared.judgment?.verdict, nil)
        XCTAssertEqual(cleared.judgment?.note, "想起的是对的，回得太短")

        var expected = record
        expected.judgment = cleared.judgment
        XCTAssertEqual(store.record(id: "r1"), expected, "别的字段一个字不变")
        let files = try FileManager.default.contentsOfDirectory(atPath: memoryRoot.appendingPathComponent("lab/records").path)
        XCTAssertEqual(files, ["r1.json"], "原地重写，不多出文件")
    }

    func testJudgeRefusesMissingAndNewerRecords() throws {
        XCTAssertThrowsError(try store.judge(id: "nope") { $0.verdict = .up }) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .missing("nope"))
        }
        var newer = full("new")
        newer.schema = MemoryLabStore.schema + 1
        try store.save(newer)
        XCTAssertThrowsError(try store.judge(id: "new") { $0.verdict = .up }) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .newerSchema("new"))
        }
        XCTAssertEqual(store.record(id: "new"), newer)
    }

    func testRecordsAreOrderedByTimeAndSummaryCountsThumbs() throws {
        XCTAssertEqual(store.records(), [])
        XCTAssertEqual(store.summary(), .init())
        for (index, id) in ["c", "a", "b"].enumerated() {
            var record = full(id)
            record.input.at = at(TimeInterval(index * 10))
            try store.save(record)
        }
        try Data("不是 JSON".utf8).write(to: memoryRoot.appendingPathComponent("lab/records/broken.json"))
        XCTAssertEqual(store.records().map(\.id), ["c", "a", "b"], "按说的先后；读不成的跳过")
        try store.judge(id: "a") { $0.verdict = .up }
        try store.judge(id: "b") { $0.verdict = .down }
        try store.judge(id: "c") { $0.note = "只写了批注" }
        XCTAssertEqual(store.summary(), .init(count: 3, up: 1, down: 1))
    }

    /// 编号里有不能当文件名的字（斜杠、中文）也不越出 records/
    func testOddIdsStayInsideRecordsFolder() throws {
        var record = full("../岚舟/一句")
        record.input.at = at(5)
        try store.save(record)
        XCTAssertEqual(store.record(id: "../岚舟/一句"), record)
        let files = try FileManager.default.contentsOfDirectory(atPath: memoryRoot.appendingPathComponent("lab/records").path)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: memoryRoot.path), ["lab"])
    }
}
