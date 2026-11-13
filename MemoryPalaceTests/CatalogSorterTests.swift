import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// C3 原料与共用件：原料过滤、单条就够打标、严格 JSON 调用记录、原始输出落盘、停（模型分拣已由 C2/C3 v2 第 4 段的代码归组替掉，见 CatalogDirectionTests）
@MainActor
final class CatalogSorterTests: XCTestCase {

    private let pid = "xctest-catalog-sorter"
    private var root: URL!
    private var wiki: WikiStore!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-sorter-\(UUID().uuidString)", isDirectory: true)
        wiki = WikiStore(root: root.appendingPathComponent("wiki", isDirectory: true))
        let schema = ProfileManager.makeFullSchema()
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func fragment(_ content: String, day: String? = "2026-10-12", pid: String? = nil) -> Memory {
        let m = Memory(content: content, category: "fact", profileId: pid ?? self.pid)
        m.occurredDay = day
        m.importance = 3
        m.reviewedAt = Date()
        context.insert(m)
        return m
    }

    // MARK: - 原料

    func testRawMaterialFilter() async throws {
        let unseen = fragment("未审计的模型船草稿")
        unseen.reviewedAt = nil
        let keep2 = fragment("留下的那条")
        keep2.reviewedAt = Date()
        fragment("九月的", day: "2026-09-30")
        fragment("手加的（不是碎片）", day: nil)
        fragment("删了的").supersededAt = Date()
        let organized = fragment("整理进页的")
        organized.organizedAt = Date()
        organized.organizedPage = "人/小慧"
        let single = fragment("单条就够的")
        single.organizedAt = Date()
        fragment("驳回的").organizeRejectedAt = Date()
        fragment("别的楼层", pid: "xctest-other")
        let waiting = fragment("在待批提案里")
        try context.save()
        try WikiProposalStore(wiki: wiki).save(WikiProposal(origin: .scheduled, createdAt: Date(), items: [
            .init(change: .appendRecords(path: "人/小慧", lines: ["x"]), fragmentIds: [waiting.id], baseVersion: "v"),
        ]))

        let got = await CatalogMaterial.pending(profileId: pid, container: container, wiki: wiki)

        XCTAssertEqual(Set(got.map(\.id)), [keep2.id, single.id], "10 月起已留、没删、没进页、没驳回、不在待批里；单条就够的留着等新证据")
        XCTAssertEqual(got.first { $0.id == single.id }?.organizedAt != nil, true, "单条就够的带着标记，只当同伴")
    }

    func testMarkSingleSavesOnBackgroundContext() async throws {
        let a = fragment("怕香菜")
        try context.save()
        let t = Date(timeIntervalSince1970: 1_800_000_000)

        try await CatalogMaterial.markSingle([a.id], container: container, now: t)

        let fresh = try ModelContext(container).fetch(FetchDescriptor<Memory>()).first { $0.id == a.id }
        XCTAssertEqual(fresh?.organizedAt, t)
        XCTAssertNil(fresh?.organizedPage)
        XCTAssertEqual(fresh?.isSingleEnough, true)
    }

    func testRunRecordCapturesBudgetErrorCancellationAndPreservesCost() async throws {
        let run = CatalogRunRecord(wiki: wiki, topic: "无输出与中止", kind: "自动")
        let meter = MemoryWriteLog.CostMeter()
        var parsed = false
        let cancel = CatalogCancel()
        try await MemoryWriteLog.$meter.withValue(meter) {
            let blocked: Int? = try await CatalogJSON.call(system: "预算系统", user: "预算输入", retries: 1, caller: { _, _ in
                MemoryWriteLog.addCost(0.125)
                return nil
            }, drafts: nil, name: "预算", userName: "", run: run) { _ in parsed = true; return 1 }
            XCTAssertNil(blocked)
            do {
                let _: Int? = try await CatalogJSON.call(system: "错误系统", user: "错误输入", retries: 1, caller: { _, _ in
                    MemoryWriteLog.addCost(0.25)
                    throw MemoryWriterError.format("测试调用错误")
                }, drafts: nil, name: "异常", userName: "", run: run) { _ in parsed = true; return 1 }
                XCTFail("原始请求错误必须仍然抛出")
            } catch MemoryWriterError.format(let message) {
                XCTAssertEqual(message, "测试调用错误")
            }
            do {
                let _: Int? = try await CatalogJSON.call(system: "取消系统", user: "取消输入", retries: 1, caller: { _, _ in
                    MemoryWriteLog.addCost(0.5)
                    cancel.cancel()
                    return "取消时已经收到的完整模型原文```"
                }, drafts: nil, name: "取消", userName: "", cancel: cancel, run: run) { _ in parsed = true; return 1 }
                XCTFail("取消必须仍然抛出")
            } catch is CancellationError {}
        }
        XCTAssertFalse(parsed, "预算、错误、请求返回时取消都不能进入解析")
        XCTAssertEqual(try XCTUnwrap(meter.usd), 0.875, accuracy: 0.000_001, "抛错及取消前的计费也原额加回")
        await run.flush()
        let report = try String(contentsOf: run.url, encoding: .utf8)
        for text in ["预算闸 / 空输出", "测试调用错误", "已取消", "取消时已经收到的完整模型原文```", "0.125", "0.25", "0.5"] {
            XCTAssertTrue(report.contains(text))
        }
    }

    func testDraftsPrunedAfter30Days() throws {
        let drafts = CatalogDrafts(wiki: wiki, now: Date())
        let old = drafts.save("旧", name: "旧")
        let new = drafts.save("新", name: "新")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86_400)], ofItemAtPath: old.path)

        CatalogDrafts.prune(wiki, now: Date())

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
    }

    // MARK: - 停（astra 10-16 #5）

    func testCancelStopsJSONRetryAndNextRequest() async throws {
        let cancel = CatalogCancel()
        var calls = 0
        do {
            _ = try await CatalogJSON.call(system: "s", user: "u", retries: 2, caller: { _, _ in
                calls += 1
                cancel.cancel()
                return "不合格"
            }, drafts: nil, name: "x", userName: "", cancel: cancel) { _ -> Int? in nil }
            XCTFail("停了应该抛 CancellationError")
        } catch is CancellationError {}
        XCTAssertEqual(calls, 1, "回来就查：不再重试")

        calls = 0
        _ = try? await CatalogJSON.call(system: "s", user: "u", retries: 2, caller: { _, _ in calls += 1; return "{}" },
                                        drafts: nil, name: "x", userName: "", cancel: cancel) { _ -> Int? in 1 }
        XCTAssertEqual(calls, 0, "发请求前就查")
    }

    func testModelRouteReadsItsOwnKey() {
        let d = UserDefaults(suiteName: "xctest-catalog-route-\(UUID().uuidString)")!
        d.set(FragmentModelRoute.localPrefix + AssistantLocalModel.light.id, forKey: CatalogModelRoute.key)
        XCTAssertEqual(CatalogModelRoute.key, "mem_model_c3")
        XCTAssertNil(d.string(forKey: FragmentModelRoute.key), "C3 不改 C2 的选择")
        XCTAssertNotNil(FragmentModelRoute.localModelId(choice: d.string(forKey: CatalogModelRoute.key) ?? ""))
    }

    /// 单发请求：发出去 {{user}} 换成当前名字；回复原样，解析副本里「名字/…」路径换回 {{user}}；改名后同一份显示新名字
    func testSingleShotRequestShowsAndStoresUserBranch() async throws {
        for name in ["岚舟", "星砚"] {
            var sent: [String] = []
            let reply = try await CatalogJSON.request(system: "本人的页挂在 {{user}}/ 下", user: "- [[{{user}}/品味]] 品味",
                                                      caller: { s, u in sent = [s, u]; return "{\"page\":\"\(name)/品味\",\"subject\":\"\(name)\"}" },
                                                      run: nil, name: "t", userName: name)
            XCTAssertEqual(sent, ["本人的页挂在 \(name)/ 下", "- [[\(name)/品味]] 品味"])
            XCTAssertEqual(reply, "{\"page\":\"\(name)/品味\",\"subject\":\"\(name)\"}", "回复原样返回（草稿、运行记录是模型原文）")
            XCTAssertEqual(WikiStore.storedJSON(try XCTUnwrap(reply), fields: .sorter, user: name), "{\"page\":\"\(name)/品味\",\"subject\":\"\(name)\"}",
                           "顶层 page 不是分拣的路径位置（fragments[].page 才是），不换")
            XCTAssertEqual(WikiStore.storedJSON("{\"fragments\":[{\"page\":\"\(name)/品味\",\"subject\":\"\(name)\"}]}", fields: .sorter, user: name),
                           "{\"fragments\":[{\"page\":\"{{user}}/品味\",\"subject\":\"\(name)\"}]}", "解析时只换路径位置，别的字段里的名字不换")
        }
    }
}
