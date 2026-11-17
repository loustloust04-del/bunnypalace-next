import XCTest
@testable import MemoryCore

/// 记忆实验台的测试集和轻读（plan-memory-lab-2 §1 / §4）：增删改、挑进 / 拿出两边一致、对不上时听集子的、
/// 轻读和全量读对得上、旧记录照读、记录文件丢了集子还列得出那句话、新版本写的集子不被改写
final class MemoryLabSetTests: XCTestCase {
    private var memoryRoot: URL!
    private var store: MemoryLabStore!

    override func setUp() {
        super.setUp()
        memoryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("xctest-lab-sets-\(UUID().uuidString)", isDirectory: true)
        store = MemoryLabStore(memoryRoot: memoryRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: memoryRoot)
        super.tearDown()
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

    @discardableResult
    private func say(_ id: String, _ text: String, at seconds: TimeInterval = 0, verdict: MemoryLabRecord.Verdict? = nil,
                     sentenceId: String? = nil, body: String = "还开着。") throws -> MemoryLabRecord {
        let record = MemoryLabRecord(
            id: id, input: .init(text: text, at: at(seconds)),
            happened: .init(messages: [.init(role: "system", content: "你是星砚", source: "角色描述"),
                                       .init(role: "user", content: text, source: "对话历史")], reply: body),
            judgment: verdict.map { .init(verdict: $0, note: nil, at: at(seconds + 1)) }, sets: [], sentenceId: sentenceId)
        try store.save(record)
        return record
    }

    private func recordFile(_ id: String) -> URL { memoryRoot.appendingPathComponent("lab/records/\(id).json") }
    private func setFile(_ id: String) -> URL { memoryRoot.appendingPathComponent("lab/sets/\(id).json") }

    // MARK: - 测试集增删改

    func testCreateListRenameDelete() throws {
        XCTAssertEqual(store.sets(), [])
        let life = try store.createSet(name: "生活琐事", id: "life", at: at(10))
        let close = try store.createSet(name: "亲密对话", id: "close", at: at(5))
        XCTAssertEqual(life, MemoryLabSet(id: "life", name: "生活琐事", createdAt: at(10), items: []))
        XCTAssertEqual(store.sets().map(\.id), ["close", "life"], "按建的先后")
        XCTAssertTrue(FileManager.default.fileExists(atPath: setFile("life").path), "落在 <记忆根>/lab/sets/")
        XCTAssertEqual(store.set(id: "close"), close)
        XCTAssertThrowsError(try store.createSet(name: "又一份", id: "life")) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .setExists("life"))
        }
        XCTAssertEqual(store.set(id: "life")?.name, "生活琐事", "撞编号不覆盖原来那份")

        let renamed = try store.renameSet(id: "life", name: "云桥城的日常")
        XCTAssertEqual(renamed.name, "云桥城的日常")
        XCTAssertEqual(store.set(id: "life"), renamed)
        XCTAssertThrowsError(try store.renameSet(id: "nope", name: "x")) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .missingSet("nope"))
        }

        try store.deleteSet(id: "close")
        XCTAssertEqual(store.sets().map(\.id), ["life"])
        XCTAssertNoThrow(try store.deleteSet(id: "close"), "本来就没有也不算错")
        // 不给编号 = 自己起一个，两份不撞
        let a = try store.createSet(name: "同名"), b = try store.createSet(name: "同名")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(store.sets().count, 3)
    }

    /// 以后加字段时旧集子的样子：只有编号
    func testOldSetWithMissingFieldsStillLoads() throws {
        try FileManager.default.createDirectory(at: setFile("x").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"id":"old","items":[{"sentenceId":"r1"}],"futureField":true}"#.utf8).write(to: setFile("old"))
        let set = try XCTUnwrap(store.set(id: "old"))
        XCTAssertNil(set.schema)
        XCTAssertNil(set.name)
        XCTAssertNil(set.createdAt)
        XCTAssertEqual(set.items, [.init(sentenceId: "r1")])
        try say("r1", "林栖今天来过吗")
        XCTAssertEqual(store.entries(inSet: "old").map(\.text), ["林栖今天来过吗"], "集子里没存那句话就用记录里的")
        XCTAssertEqual(try store.renameSet(id: "old", name: "补个名字").name, "补个名字")
    }

    // MARK: - 挑进 / 拿出

    func testAddWritesBothSidesAndGivesTheRecordItsSentenceId() throws {
        let record = try say("r1", "雾岚还学门铃吗", verdict: .up)
        try say("r2", "云桥城那家皮影作坊还开着吗", at: 10)
        try store.createSet(name: "生活琐事", id: "life", at: at(0))
        try store.createSet(name: "亲密对话", id: "close", at: at(1))
        XCTAssertNil(store.record(id: "r1")?.sentenceId, "自由聊说出来的先没有")

        let set = try store.add(recordId: "r1", toSet: "life", at: at(20))
        XCTAssertEqual(set.items, [.init(sentenceId: "r1", text: "雾岚还学门铃吗", addedAt: at(20))])
        XCTAssertEqual(store.set(id: "life"), set)
        var expected = record
        expected.sentenceId = "r1"
        expected.sets = ["life"]
        XCTAssertEqual(store.record(id: "r1"), expected, "记录只多了 sentenceId 和回指，别的一个字不变")

        // 再挑一遍不重复；挑进第二份；另一句排在后面
        XCTAssertEqual(try store.add(recordId: "r1", toSet: "life", at: at(30)), set)
        try store.add(recordId: "r1", toSet: "close", at: at(31))
        try store.add(recordId: "r2", toSet: "life", at: at(32))
        XCTAssertEqual(store.record(id: "r1")?.sets, ["life", "close"])
        XCTAssertEqual(store.set(id: "life")?.items?.map(\.sentenceId), ["r1", "r2"])
        XCTAssertEqual(store.membership(), ["r1": ["life", "close"], "r2": ["life"]])
        XCTAssertEqual(store.records().count, 2, "挑进不多出记录")

        XCTAssertThrowsError(try store.add(recordId: "nope", toSet: "life")) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .missing("nope"))
        }
        XCTAssertThrowsError(try store.add(recordId: "r2", toSet: "nope")) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .missingSet("nope"))
        }
        XCTAssertEqual(store.record(id: "r2")?.sets, ["life"], "挑不成的那一次什么都没改")
    }

    func testRemoveUndoesBothSides() throws {
        try say("r1", "雾岚还学门铃吗")
        try say("r2", "栎川镇降温了吗", at: 10)
        try store.createSet(name: "生活琐事", id: "life", at: at(0))
        try store.createSet(name: "亲密对话", id: "close", at: at(1))
        for id in ["r1", "r2"] { try store.add(recordId: id, toSet: "life") }
        try store.add(recordId: "r1", toSet: "close")

        let set = try store.remove(sentenceId: "r1", fromSet: "life")
        XCTAssertEqual(set.items?.map(\.sentenceId), ["r2"])
        XCTAssertEqual(store.record(id: "r1")?.sets, ["close"], "只撤这一份的回指")
        XCTAssertEqual(store.record(id: "r1")?.sentenceId, "r1", "这句话的键留着")
        XCTAssertEqual(store.record(id: "r2")?.sets, ["life"])
        XCTAssertEqual(store.membership(), ["r1": ["close"], "r2": ["life"]])
        XCTAssertEqual(try store.remove(sentenceId: "r1", fromSet: "life"), set, "本来就不在里面：不算错")
        XCTAssertThrowsError(try store.remove(sentenceId: "r1", fromSet: "nope")) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .missingSet("nope"))
        }
        XCTAssertEqual(store.records().count, 2)
    }

    func testDeleteSetClearsBackReferencesAndKeepsRecords() throws {
        try say("r1", "雾岚还学门铃吗", verdict: .up)
        try say("r2", "栎川镇降温了吗", at: 10)
        try store.createSet(name: "生活琐事", id: "life", at: at(0))
        try store.createSet(name: "亲密对话", id: "close", at: at(1))
        for id in ["r1", "r2"] { try store.add(recordId: id, toSet: "life") }
        try store.add(recordId: "r1", toSet: "close")

        try store.deleteSet(id: "life")
        XCTAssertFalse(FileManager.default.fileExists(atPath: setFile("life").path))
        XCTAssertEqual(store.sets().map(\.id), ["close"])
        XCTAssertEqual(store.records().map(\.id), ["r1", "r2"], "不删记录")
        XCTAssertEqual(store.record(id: "r1")?.sets, ["close"])
        XCTAssertEqual(store.record(id: "r2")?.sets, [])
        XCTAssertEqual(store.record(id: "r1")?.judgment?.verdict, .up, "拇指还在")
        XCTAssertEqual(store.membership(), ["r1": ["close"]])
    }

    // MARK: - 对不上时听集子的

    /// 两个文件只写成了一个的几种样子：读的入口都只看集子；同样的操作再做一遍把回指补齐
    func testSetFileIsTheTruthWhenBackReferencesDisagree() throws {
        // 集子里有、记录上没有回指也没有 sentenceId（挑进时记录没写成）
        try say("r1", "雾岚还学门铃吗", verdict: .down)
        // 记录上有回指、集子里没有（拿出时回指没清成）；还有一条指向早就删掉的集子
        var stale = try say("r2", "栎川镇降温了吗", at: 10)
        stale.sets = ["life", "ghost"]
        try store.save(stale)
        try store.save(MemoryLabSet(id: "life", name: "生活琐事", createdAt: at(0), items: [.init(sentenceId: "r1", text: "雾岚还学门铃吗", addedAt: at(1))]))

        XCTAssertEqual(store.membership(), ["r1": ["life"]])
        XCTAssertEqual(store.entries(inSet: "life").map(\.record?.id), ["r1"], "没写 sentenceId 的记录，键就是它自己的编号")
        XCTAssertEqual(store.setSummaries(), [.init(set: try XCTUnwrap(store.set(id: "life")), count: 1, up: 0, down: 1, unseen: 0, latestAt: at(0))])

        // 再做一遍：补齐 / 清掉
        try store.add(recordId: "r1", toSet: "life")
        XCTAssertEqual(store.record(id: "r1")?.sets, ["life"])
        XCTAssertEqual(store.record(id: "r1")?.sentenceId, "r1")
        XCTAssertEqual(store.set(id: "life")?.items?.count, 1)
        try store.remove(sentenceId: "r2", fromSet: "life")
        XCTAssertEqual(store.record(id: "r2")?.sets, ["ghost"])
        try store.deleteSet(id: "ghost")
        XCTAssertEqual(store.record(id: "r2")?.sets, [])
    }

    // MARK: - 一份集子里的记录、每份的数

    func testEntriesFollowItemOrderTakeTheLatestRecordAndSurviveMissingFiles() throws {
        try say("r1", "雾岚还学门铃吗", at: 0, verdict: .down)
        try say("r2", "栎川镇降温了吗", at: 10, verdict: .up)
        try say("r3", "林栖今天来过吗", at: 20)
        try say("free", "今天晚饭吃的汤面", at: 30, verdict: .up)
        try store.createSet(name: "生活琐事", id: "life", at: at(0))
        for (index, id) in ["r3", "r1", "r2"].enumerated() { try store.add(recordId: id, toSet: "life", at: at(100 + TimeInterval(index))) }
        // 同一句话后来重放出来的一条（第三片会这样写）：带同一个 sentenceId，更新，拇指不一样
        let replay = try say("r1-again", "雾岚还学门铃吗", at: 200, verdict: .up, sentenceId: "r1", body: "还学，学得更像了。")
        // r3 的记录文件没了
        try FileManager.default.removeItem(at: recordFile("r3"))

        let entries = store.entries(inSet: "life")
        XCTAssertEqual(entries.map(\.id), ["r3", "r1", "r2"], "按挑进的先后")
        XCTAssertEqual(entries.map(\.text), ["林栖今天来过吗", "雾岚还学门铃吗", "栎川镇降温了吗"], "记录没了的那句照样列得出")
        XCTAssertNil(entries[0].record)
        XCTAssertEqual(entries[1].record, replay, "同一句有好几条记录：取最新一条")
        XCTAssertEqual(entries[2].record?.id, "r2")
        XCTAssertEqual(entries[2].record?.happened?.reply, "还开着。", "整条都在")
        XCTAssertEqual(store.entries(inSet: "nope"), [])

        let empty = try store.createSet(name: "亲密对话", id: "close", at: at(1))
        XCTAssertEqual(store.setSummaries(), [
            .init(set: try XCTUnwrap(store.set(id: "life")), count: 3, up: 2, down: 0, unseen: 1, latestAt: at(200)),
            .init(set: empty, count: 0, up: 0, down: 0, unseen: 0),
        ], "r1 看最新那条的 👍；记录没了的算没看过")
        // 拇指是同一个：在自由聊里改，集子的数跟着变
        try store.judge(id: "r2") { $0.verdict = .down }
        XCTAssertEqual(store.setSummaries().first.map { [$0.up, $0.down, $0.unseen] }, [1, 1, 1])
        // 调用方已经轻读过：传进来，结果一样
        let heads = store.heads()
        XCTAssertEqual(store.setSummaries(heads: heads), store.setSummaries())
        XCTAssertEqual(store.entries(inSet: "life", heads: heads), store.entries(inSet: "life"))
    }

    // MARK: - 轻读

    func testHeadsMatchFullRecords() throws {
        try say("b", "栎川镇降温了吗", at: 10, verdict: .down)
        try say("a", "雾岚还学门铃吗", at: 10, verdict: .up)
        try say("c", "林栖今天来过吗", at: 0)
        try store.createSet(name: "生活琐事", id: "life")
        try store.add(recordId: "a", toSet: "life")
        // 旧记录：没有 sentenceId、没有 sets、没有 schema
        try Data(#"{"id":"old","input":{"text":"槐序巷的课改到周五了吗","at":1790000005000},"judgment":{"verdict":"up"}}"#.utf8)
            .write(to: recordFile("old"))
        try Data("不是 JSON".utf8).write(to: recordFile("broken"))

        let records = store.records(), heads = store.heads()
        XCTAssertEqual(heads.map(\.id), ["c", "old", "a", "b"], "顺序同全量：按说的先后，同一刻按编号")
        XCTAssertEqual(heads, records.map(MemoryLabRecord.Head.init), "轻读的每一样都和整条里的一样")
        XCTAssertEqual(heads.first { $0.id == "a" }?.sentenceId, "a")
        XCTAssertEqual(heads.first { $0.id == "a" }?.sets, ["life"])
        let old = try XCTUnwrap(heads.first { $0.id == "old" })
        XCTAssertNil(old.sentenceId)
        XCTAssertEqual(old.sentence, "old")
        XCTAssertNil(old.sets)
        XCTAssertEqual(store.record(id: "old")?.sentence, "old")
        XCTAssertEqual(store.summary(), .init(count: 4, up: 2, down: 1))
        XCTAssertEqual(store.summary(), MemoryLabStore.summary(records), "汇总走轻读，数和全量一样")
        // 旧记录也能挑进：这时才写 sentenceId
        try store.add(recordId: "old", toSet: "life")
        XCTAssertEqual(store.record(id: "old")?.sentenceId, "old")
        XCTAssertEqual(store.record(id: "old")?.input.text, "槐序巷的课改到周五了吗")
    }

    // MARK: - 新版本写的不改写

    func testNewerSchemaSetsAndRecordsAreNotRewritten() throws {
        try say("r1", "雾岚还学门铃吗")
        var newer = MemoryLabSet(id: "future", name: "以后的集子", createdAt: at(0), items: [.init(sentenceId: "r9", text: "云桥城下雪了吗", addedAt: at(1))])
        newer.schema = MemoryLabStore.schema + 1
        try store.save(newer)
        let bytes = try Data(contentsOf: setFile("future"))

        XCTAssertThrowsError(try store.renameSet(id: "future", name: "改名")) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .newerSetSchema("future"))
        }
        XCTAssertThrowsError(try store.add(recordId: "r1", toSet: "future")) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .newerSetSchema("future"))
        }
        XCTAssertThrowsError(try store.remove(sentenceId: "r9", fromSet: "future")) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .newerSetSchema("future"))
        }
        XCTAssertEqual(try Data(contentsOf: setFile("future")), bytes, "文件一个字节没动")
        XCTAssertNil(store.record(id: "r1")?.sentenceId, "挑不成的那一次记录也没动")
        XCTAssertEqual(store.sets().map(\.id), ["future"], "照样列得出")
        XCTAssertEqual(store.entries(inSet: "future").map(\.text), ["云桥城下雪了吗"])

        // 新版本写的记录：挑进直接拒；清回指时跳过它（集子已经是准的）
        var record = try say("r2", "栎川镇降温了吗", at: 10)
        record.schema = MemoryLabStore.schema + 1
        record.sets = ["life"]
        try store.save(record)
        let recordBytes = try Data(contentsOf: recordFile("r2"))
        try store.createSet(name: "生活琐事", id: "life")
        XCTAssertThrowsError(try store.add(recordId: "r2", toSet: "life")) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .newerSchema("r2"))
        }
        XCTAssertEqual(store.set(id: "life")?.items, [], "记录改不了就整个不挑，集子没动")
        try store.deleteSet(id: "life")
        XCTAssertEqual(try Data(contentsOf: recordFile("r2")), recordBytes)
        XCTAssertEqual(store.membership(), ["r9": ["future"]], "留下的旧回指读的时候不算数")
    }

    // MARK: - 量一下轻读

    /// 200 条、每条带几十 KB 的 `happened`：轻读和全量各要多久（只打数，不卡阈值）
    func testLightReadTimingOn200Records() throws {
        // 照真记录的形状：二十来段提示词（约 37KB）+ 一张带 40 个候选的回执，一个文件约 60KB
        let segment = String(repeating: "星砚记得岚舟每周五晚上去槐序巷皮影作坊上课。", count: 24)
        let items = (0..<40).map { n in
            RecallItem(source: .init(profileId: "floor-xingyan", conversationId: "lab", kind: .page, path: "地点/云桥城\(n)", version: "v\(n)"),
                       text: "## 云桥城\(n)\n岚舟常去的地方，槐序巷皮影作坊在这里。", identities: ["云桥城\(n)"], tokenCost: 20)
        }
        let receipt = RecallTurnReceipt(decision: RecallTurnDecision(
            turnId: "t", branchAnchor: "lab", origin: .user, gateReason: .search, tuning: .defaults, topicAnchor: "云桥城",
            selected: Array(items.prefix(3)), candidates: items, suppressions: [], ignored: [], thawed: [],
            stateAfterResponse: RecallConversationState(active: Array(items.prefix(3)))))
        for index in 0..<200 {
            var record = try say("r\(index)", "第 \(index) 句：雾岚还学门铃吗", at: TimeInterval(index), verdict: index % 3 == 0 ? .up : nil)
            record.happened?.messages = (0..<22).map { .init(role: "system", content: segment, source: "插槽 \($0)") }
                + [.init(role: "user", content: record.input.text, source: "对话历史")]
            record.happened?.receipt = receipt
            try store.save(record)
        }
        let size = try FileManager.default.attributesOfItem(atPath: recordFile("r0").path)[.size] as? Int ?? 0
        func fastest(_ work: () -> Int) -> (ms: Double, count: Int) {
            var best = Double.infinity, count = 0
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                count = work()
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            return (best, count)
        }
        let light = fastest { store.heads().count }
        let full = fastest { store.records().count }
        let raw = fastest {
            ((try? FileManager.default.contentsOfDirectory(at: recordFile("x").deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
                .reduce(0) { $0 + ((try? Data(contentsOf: $1))?.count ?? 0) }
        }
        print(String(format: "[LAB-LIGHT] 200 条 × %d 字节：只读文件 %.1f ms · 轻读 heads() %.1f ms · 全量 records() %.1f ms",
                     size, raw.ms, light.ms, full.ms))
        XCTAssertEqual(light.count, 200)
        XCTAssertEqual(full.count, 200)
        XCTAssertEqual(store.summary(), .init(count: 200, up: 67, down: 0))
    }
}
