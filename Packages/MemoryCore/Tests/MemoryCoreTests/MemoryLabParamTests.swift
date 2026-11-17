import XCTest
@testable import MemoryCore

/// 记忆实验台的参数组和「测试集 × 参数组」（plan-memory-lab-3 §1 / §5）：参数组增删改、旧记录推算哪一组、
/// 按测试集 × 参数组取、删组后记录还读得出
final class MemoryLabParamTests: XCTestCase {
    private var memoryRoot: URL!
    private var store: MemoryLabStore!

    override func setUp() {
        super.setUp()
        memoryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("xctest-lab-params-\(UUID().uuidString)", isDirectory: true)
        store = MemoryLabStore(memoryRoot: memoryRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: memoryRoot)
        super.tearDown()
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

    private func params(pages: Int = 3, differences: [MemoryLabRecord.Difference]? = []) -> MemoryLabRecord.Params {
        var tuning = RecallTuning.defaults
        tuning.maximumPages = pages
        return .init(items: [MemoryLabRecord.Item.pinned: true], everyRound: false, systemPush: true, recallTool: true, tuning: tuning,
                     model: .init(id: "card/haiku", name: "Haiku", provider: "星砚的卡"), differences: differences)
    }

    private let changed = [MemoryLabRecord.Difference(key: MemoryLabRecord.Item.systemPush, settings: "false", lab: "true")]

    /// `group`：写进记录的 `paramsId`；nil = 不写（旧记录 / 改过没存的），算哪一组看 `differences`
    @discardableResult
    private func say(_ id: String, _ text: String = "雾岚还学门铃吗", at seconds: TimeInterval, group: String? = nil,
                     differences: [MemoryLabRecord.Difference]? = nil, sentence: String? = nil,
                     verdict: MemoryLabRecord.Verdict? = nil, failed: Bool = false) throws -> MemoryLabRecord {
        let record = MemoryLabRecord(
            id: id, input: .init(text: text, at: at(seconds)), params: params(differences: differences ?? (group == nil ? changed : [])),
            happened: failed ? .init(error: "401 没有钥匙", missing: ["状态行"]) : .init(reply: "回复 \(id)"),
            judgment: verdict.map { .init(verdict: $0) }, sets: [], sentenceId: sentence, paramsId: group)
        try store.save(record)
        return record
    }

    private func file(_ folder: String, _ id: String) -> URL { memoryRoot.appendingPathComponent("lab/\(folder)/\(id).json") }

    // MARK: - 参数组增删改

    func testCreateListRenameDelete() throws {
        XCTAssertEqual(store.paramSets(), [])
        let wide = try store.createParamSet(name: "多推几页", params: params(pages: 6, differences: changed), id: "wide", at: at(10))
        XCTAssertEqual(wide, MemoryLabParamSet(id: "wide", name: "多推几页", createdAt: at(10), params: params(pages: 6, differences: nil)),
                       "存的是值：跑那一刻「跟设置比差在哪」不存")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file("params", "wide").path), "落在 <记忆根>/lab/params/")
        try store.createParamSet(name: "只靠主动翻", params: params(pages: 1), id: "pull", at: at(5))
        XCTAssertEqual(store.paramSets().map(\.id), ["pull", "wide"], "按存的先后")
        XCTAssertEqual(store.paramSet(id: "wide"), wide)
        XCTAssertEqual(store.paramSet(id: "wide")?.params?.tuning?.maximumPages, 6, "整份参数都在")

        XCTAssertThrowsError(try store.createParamSet(name: "撞了", params: params(), id: "wide")) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .paramsExists("wide"))
        }
        XCTAssertEqual(store.paramSet(id: "wide"), wide, "撞编号不覆盖")
        // 「现在的设置」不落盘
        XCTAssertThrowsError(try store.createParamSet(name: "冒充", params: params(), id: MemoryLabParamSet.currentId)) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .paramsExists(MemoryLabParamSet.currentId))
        }
        XCTAssertThrowsError(try store.save(MemoryLabParamSet(id: MemoryLabParamSet.currentId, name: "冒充")))
        XCTAssertNil(store.paramSet(id: MemoryLabParamSet.currentId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("params", MemoryLabParamSet.currentId).path))

        XCTAssertEqual(try store.renameParamSet(id: "wide", name: "一轮六页").name, "一轮六页")
        XCTAssertEqual(store.paramSet(id: "wide")?.params, wide.params, "改名不动参数")
        XCTAssertThrowsError(try store.renameParamSet(id: "nope", name: "x")) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .missingParams("nope"))
        }
        try store.deleteParamSet(id: "pull")
        XCTAssertEqual(store.paramSets().map(\.id), ["wide"])
        XCTAssertNoThrow(try store.deleteParamSet(id: "pull"))
        let a = try store.createParamSet(name: "同名", params: params()), b = try store.createParamSet(name: "同名", params: params())
        XCTAssertNotEqual(a.id, b.id)
    }

    func testOldAndNewerParamFiles() throws {
        try FileManager.default.createDirectory(at: file("params", "x").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"id":"old","futureField":1}"#.utf8).write(to: file("params", "old"))
        let old = try XCTUnwrap(store.paramSet(id: "old"))
        XCTAssertNil(old.name)
        XCTAssertNil(old.params)
        XCTAssertEqual(try store.renameParamSet(id: "old", name: "补个名字").name, "补个名字")

        var newer = MemoryLabParamSet(id: "future", name: "以后的一组", createdAt: at(0), params: params())
        newer.schema = MemoryLabStore.schema + 1
        try store.save(newer)
        let bytes = try Data(contentsOf: file("params", "future"))
        XCTAssertThrowsError(try store.renameParamSet(id: "future", name: "改名")) {
            XCTAssertEqual($0 as? MemoryLabStore.StoreError, .newerParamsSchema("future"))
        }
        XCTAssertEqual(try Data(contentsOf: file("params", "future")), bytes, "新版本写的不改写")
        XCTAssertEqual(store.paramSets().map(\.id).sorted(), ["future", "old"], "照样列得出")
    }

    /// 删一组不删记录：记录上的 `paramsId` 还指着它，那次的参数值在记录自己身上
    func testDeletingAGroupKeepsItsRecords() throws {
        try store.createParamSet(name: "多推几页", params: params(pages: 6), id: "wide")
        let record = try say("r1", at: 0, group: "wide", verdict: .up)
        let bytes = try Data(contentsOf: file("records", "r1"))
        try store.deleteParamSet(id: "wide")
        XCTAssertNil(store.paramSet(id: "wide"))
        XCTAssertEqual(store.record(id: "r1"), record)
        XCTAssertEqual(store.record(id: "r1")?.paramsGroup, "wide", "界面拿这个 id 找不到组 = 「删掉的一组」")
        XCTAssertNotNil(store.record(id: "r1")?.params?.tuning)
        XCTAssertEqual(try Data(contentsOf: file("records", "r1")), bytes, "记录文件没动")
        XCTAssertEqual(store.heads().map(\.paramsGroup), ["wide"])
    }

    // MARK: - 旧记录算哪一组（读的时候推，不回写）

    func testOldRecordsInferTheirGroupWithoutBeingRewritten() throws {
        // 前两片的记录：没有 paramsId。当时和设置一样 → 现在的设置；改过 → 不算任何一组
        try say("same", at: 0, differences: [])
        try say("edited", at: 10, differences: changed)
        // 更老的 / 残缺的：没存参数、没存差在哪
        try Data(#"{"id":"bare","input":{"text":"林栖今天来过吗","at":1790000020000}}"#.utf8).write(to: file("records", "bare"))
        try Data(#"{"id":"nodiff","input":{"text":"栎川镇降温了吗","at":1790000030000},"params":{"systemPush":true}}"#.utf8)
            .write(to: file("records", "nodiff"))
        // 第三片写的：写了哪组就是哪组，不看差在哪
        try say("grouped", at: 40, group: "wide", differences: changed)
        try say("current", at: 50, group: MemoryLabParamSet.currentId)
        let before = try ["same", "edited", "bare", "nodiff"].map { try Data(contentsOf: file("records", $0)) }

        let records = store.records(), heads = store.heads()
        XCTAssertEqual(records.map(\.id), ["same", "edited", "bare", "nodiff", "grouped", "current"])
        XCTAssertEqual(records.map(\.paramsGroup), [MemoryLabParamSet.currentId, nil, nil, nil, "wide", MemoryLabParamSet.currentId])
        XCTAssertEqual(records.prefix(4).map(\.paramsId), [nil, nil, nil, nil], "推出来的不写进字段")
        XCTAssertEqual(heads.map(\.paramsGroup), records.map(\.paramsGroup), "轻读推出来的和整条一样")
        XCTAssertEqual(heads, records.map(MemoryLabRecord.Head.init), "轻读的每一样都和整条里的一样")
        // 读、点拇指都不会把推出来的组写回去
        try store.judge(id: "same") { $0.verdict = .up }
        XCTAssertNil(store.record(id: "same")?.paramsId)
        XCTAssertEqual(try ["edited", "bare", "nodiff"].map { try Data(contentsOf: file("records", $0)) }, Array(before.dropFirst()))
    }

    // MARK: - 测试集 × 参数组

    func testEntriesAndSummaryPerSetAndGroup() throws {
        let current = MemoryLabParamSet.currentId
        // 自由聊里说的三句（当时和设置一样），都挑进「生活琐事」
        try say("s1", "雾岚还学门铃吗", at: 0, differences: [], verdict: .down)
        try say("s2", "栎川镇降温了吗", at: 10, differences: [], verdict: .up)
        try say("s3", "林栖今天来过吗", at: 20, differences: changed)   // 改过没存就说的：不算任何一组
        try store.createSet(name: "生活琐事", id: "life", at: at(0))
        for id in ["s1", "s2", "s3"] { try store.add(recordId: id, toSet: "life") }
        try store.createParamSet(name: "多推几页", params: params(pages: 6), id: "wide")
        // 「多推几页」下重放：s1 跑了两次（取新的），s2 跑了一次，s3 还没跑
        try say("w1-old", "雾岚还学门铃吗", at: 100, group: "wide", sentence: "s1", verdict: .down)
        let w1 = try say("w1", "雾岚还学门铃吗", at: 110, group: "wide", sentence: "s1", verdict: .up)
        let w2 = try say("w2", "栎川镇降温了吗", at: 120, group: "wide", sentence: "s2")

        let wide = store.entries(inSet: "life", paramsId: "wide")
        XCTAssertEqual(wide.map(\.id), ["s1", "s2", "s3"], "按集子的顺序，没跑过的也占一格")
        XCTAssertEqual(wide.map(\.record), [w1, w2, nil])
        XCTAssertEqual(wide.map(\.text), ["雾岚还学门铃吗", "栎川镇降温了吗", "林栖今天来过吗"])
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: "wide"), .init(count: 3, ran: 2, notRun: 1, up: 1, down: 0, unseen: 1))

        let mine = store.entries(inSet: "life", paramsId: current)
        XCTAssertEqual(mine.map(\.record?.id), ["s1", "s2", nil], "旧记录推成「现在的设置」；改过没存的那句在哪一组下都算没跑过")
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: current), .init(count: 3, ran: 2, notRun: 1, up: 1, down: 1, unseen: 0))

        XCTAssertEqual(store.entries(inSet: "life", paramsId: "nope").map(\.record), [nil, nil, nil])
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: "nope"), .init(count: 3, ran: 0, notRun: 3))
        XCTAssertEqual(store.entries(inSet: "gone", paramsId: "wide"), [])
        XCTAssertEqual(store.runSummary(inSet: "gone", paramsId: "wide"), .init())

        // 不带参数组的取法还在：每句最新一条，不管哪组；顺带给出最近是哪一组
        XCTAssertEqual(store.entries(inSet: "life").map(\.record?.id), ["w1", "w2", "s3"])
        let shelf = try XCTUnwrap(store.setSummaries().first)
        XCTAssertEqual([shelf.count, shelf.up, shelf.down, shelf.unseen], [3, 1, 0, 2])
        XCTAssertEqual(shelf.latestAt, at(120))
        XCTAssertEqual(shelf.latestParamsId, "wide")

        // 调用方已经轻读过：传进来，结果一样
        let heads = store.heads()
        XCTAssertEqual(store.entries(inSet: "life", paramsId: "wide", heads: heads), wide)
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: current, heads: heads), store.runSummary(inSet: "life", paramsId: current))
        // 删掉那一组：它名下的记录照取
        try store.deleteParamSet(id: "wide")
        XCTAssertEqual(store.entries(inSet: "life", paramsId: "wide"), wide)
    }

    /// 没问成的那句（这组下最新一条没有回复）不算跑过：算进要跑的，另数一个 failed；牌堆里照样列出那条
    func testSentencesThatGotNoReplyCountAsNotRun() throws {
        try store.save(MemoryLabSet(id: "life", name: "生活琐事", createdAt: at(0), items: [
            .init(sentenceId: "s1", text: "雾岚还学门铃吗", addedAt: at(1)),
            .init(sentenceId: "s2", text: "栎川镇降温了吗", addedAt: at(2)),
            .init(sentenceId: "s3", addedAt: at(3)),   // 老集子没存那句话
        ]))
        try say("free3", "林栖今天来过吗", at: 5, differences: changed, sentence: "s3")
        let w1 = try say("w1", "雾岚还学门铃吗", at: 100, group: "wide", sentence: "s1", verdict: .up)
        let w2 = try say("w2", "栎川镇降温了吗", at: 110, group: "wide", sentence: "s2", failed: true)

        XCTAssertEqual(store.record(id: "w1")?.replied, true)
        XCTAssertEqual(store.record(id: "w2")?.replied, false)
        let heads = store.heads()
        XCTAssertEqual(heads.map(\.replied), [true, true, false], "轻读看得出有没有回复")
        XCTAssertEqual(heads, store.records().map(MemoryLabRecord.Head.init))
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: "wide"), .init(count: 3, ran: 1, notRun: 2, failed: 1, up: 1))
        XCTAssertEqual(store.notRun(inSet: "life", paramsId: "wide"), [
            .init(sentenceId: "s2", text: "栎川镇降温了吗", addedAt: at(2)),
            .init(sentenceId: "s3", text: "林栖今天来过吗", addedAt: at(3)),
        ], "没问成的 + 没跑过的，按集子的顺序；集子里没存的那句话从记录里补")
        XCTAssertEqual(store.entries(inSet: "life", paramsId: "wide").map(\.record), [w1, w2, nil], "没问成的那条照样列出来")
        XCTAssertEqual(store.entries(inSet: "life", paramsId: "wide")[1].record?.happened?.error, "401 没有钥匙")

        // 再问一次问成了：最新那条有回复，就算跑过了
        try say("w2-again", "栎川镇降温了吗", at: 120, group: "wide", sentence: "s2")
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: "wide"), .init(count: 3, ran: 2, notRun: 1, failed: 0, up: 1, unseen: 1))
        XCTAssertEqual(store.notRun(inSet: "life", paramsId: "wide").map(\.sentenceId), ["s3"])
        // 整份重跑时第一句这回没问成：听最新那条的
        try say("w1-again", "雾岚还学门铃吗", at: 130, group: "wide", sentence: "s1", failed: true)
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: "wide"), .init(count: 3, ran: 1, notRun: 2, failed: 1, unseen: 1))
        XCTAssertEqual(store.notRun(inSet: "life", paramsId: "wide").map(\.sentenceId), ["s1", "s3"])
        XCTAssertEqual(store.notRun(inSet: "life", paramsId: "wide", heads: store.heads()), store.notRun(inSet: "life", paramsId: "wide"))
        XCTAssertEqual(store.notRun(inSet: "gone", paramsId: "wide"), [])
        // 别的组不受影响；首页那排的数照旧（每句最新一条，不分有没有问成）
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: MemoryLabParamSet.currentId), .init(count: 3, notRun: 3))
        XCTAssertEqual(store.setSummaries().first.map { [$0.count, $0.up, $0.down, $0.unseen] }, [3, 0, 0, 3])
    }

    func testShelfLatestGroupCases() throws {
        try store.createSet(name: "空的", id: "empty", at: at(0))
        try store.createSet(name: "改过的", id: "edited", at: at(1))
        try say("e1", at: 5, differences: changed)
        try store.add(recordId: "e1", toSet: "edited")
        // 老集子：没存那句话；那句只在「现在的设置」下跑过
        try say("o1", "槐序巷的课改到周五了吗", at: 6, differences: [])
        try store.save(MemoryLabSet(id: "old", name: "老集子", createdAt: at(2), items: [.init(sentenceId: "o1")]))

        let shelf = store.setSummaries()
        XCTAssertEqual(shelf.map(\.id), ["empty", "edited", "old"])
        XCTAssertNil(shelf[0].latestAt, "一句记录都没有")
        XCTAssertNil(shelf[0].latestParamsId)
        XCTAssertEqual(shelf[1].latestAt, at(5))
        XCTAssertNil(shelf[1].latestParamsId, "最近那句是改过没存就跑的：有时间、没有组")
        XCTAssertEqual(shelf[2].latestParamsId, MemoryLabParamSet.currentId)
        XCTAssertEqual(store.entries(inSet: "old", paramsId: "wide").map(\.text), ["槐序巷的课改到周五了吗"], "这组下没跑过，那句话从别的记录里拿")
        XCTAssertEqual(store.entries(inSet: "old", paramsId: "wide").map(\.record), [nil])
    }
}
