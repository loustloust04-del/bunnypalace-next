import XCTest
import SwiftData
@testable import 记忆花园

/// C2/C3 v2 第 4 段 · 共用审批：自动方向由代码提（零模型），批了才搜、写；正文第二批才落页。
/// 手动请求本身是方向授权；{助手}的建议先批方向。逐条批、驳回方向不伤线索、重复批不重付、stale、
/// covered-only、单条就够、没材料、失败 / 停止各出口
@MainActor
final class CatalogDirectionTests: XCTestCase {

    private let pid = "xctest-catalog-direction"
    private var root: URL!
    private var wiki: WikiStore!
    private var store: WikiProposalStore!
    private var container: ModelContainer!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-direction-\(UUID().uuidString)", isDirectory: true)
        wiki = WikiStore(root: root.appendingPathComponent("wiki", isDirectory: true))
        store = WikiProposalStore(wiki: wiki)
        let schema = ProfileManager.makeFullSchema()
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    @discardableResult
    private func fragment(_ content: String, subject: String?, keywords: [String] = [], day: Int = 12) throws -> Memory {
        let ctx = ModelContext(container)
        let m = Memory(content: content, category: "fact", keywords: keywords, profileId: pid)
        m.subject = subject
        m.occurredDay = "2026-10-\(day)"
        m.createdAt = Date(timeIntervalSince1970: 1_800_000_000 + Double(day))
        m.reviewedAt = Date()
        ctx.insert(m)
        try ctx.save()
        return m
    }

    private func memory(_ id: UUID) throws -> Memory? {
        try ModelContext(container).fetch(FetchDescriptor<Memory>()).first { $0.id == id }
    }

    private func job(caller: @escaping SessionSegmentWriter.Caller = { _, _ in nil }, backend: FakeCatalogBackend? = nil,
                     maxRounds: Int = 10) -> CatalogJob {
        CatalogTestKit.job(pid: pid, root: root, container: container, caller: caller, backend: backend, maxRounds: maxRounds)
    }

    @discardableResult
    private func approve(_ id: String, _ items: Set<String>? = nil) async throws -> WikiProposal {
        try await WikiProposalReview.approve(id, itemIds: items, store: store, profileId: pid, context: ModelContext(container))
    }

    private func directionProposal() throws -> WikiProposal {
        try XCTUnwrap(store.list().first { $0.items.contains { $0.change.direction != nil } })
    }

    private func contentProposals() -> [WikiProposal] {
        store.list().filter { !$0.items.contains { $0.change.direction != nil } }
    }

    private func page(_ path: String, records: [String]) -> String {
        let lines = records.map { "{\"text\":\"\($0)\",\"fragments\":[\"f1\"]}" }.joined(separator: ",")
        return "{\"items\":[{\"type\":\"new_page\",\"path\":\"\(path)\",\"kind\":\"主题\",\"title\":\"x\",\"records\":[\(lines)]}]}"
    }

    // MARK: - 自动：方向待批零模型，第一次批不落页，第二次批才落页

    func testAutoDirectionMakesNoModelRequestAndPageLandsOnlyAfterSecondApproval() async throws {
        let ids = try (12...14).map { try fragment("灯塔航线第\($0)天改成三轮领航", subject: "灯塔航线", day: $0).id }
        var writerCalls = 0
        let embedder = CatalogFakeEmbedder()
        let backend = FakeCatalogBackend { _, _ in .failed("自动不该调 agent") }
        var j = job(caller: { _, _ in
            writerCalls += 1
            return """
            {"items":[{"type":"new_page","path":"楼层/主题/灯塔航线","kind":"主题","title":"灯塔航线","records":[
            {"text":"2026-10-12 改成三轮领航","fragments":["f1","f2"]}]}],"covered":["f3"]}
            """
        }, backend: backend)
        j.embedder = embedder

        let report = await CatalogSession(job: j).daily(now: Date())

        XCTAssertEqual(writerCalls, 0, "方向待批：没有分拣 / 写手请求")
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertTrue(embedder.calls.isEmpty, "方向待批：不补算向量、不搜")
        XCTAssertEqual(report.proposals, 1)
        let first = try directionProposal()
        XCTAssertEqual(first.origin, .scheduled)
        let d = try XCTUnwrap(first.items.first?.change.direction)
        XCTAssertEqual(d.path, "楼层/主题/灯塔航线")
        XCTAssertEqual(d.action, .newPage)
        XCTAssertEqual(d.mode, .daily)
        XCTAssertEqual(d.clues, ids)
        XCTAssertTrue(d.reason.contains("灯塔航线"))
        XCTAssertFalse(d.reason.contains("三轮领航"), "理由只用碎片标题，不读正文")
        XCTAssertEqual(CatalogMaterial.pendingFragmentIds(store), Set(ids), "待批方向占着这批线索")

        let approved = try await approve(first.id)
        XCTAssertEqual(approved.items.first?.state, .approved)
        XCTAssertEqual(writerCalls, 0, "批方向这一步本身不调模型")
        let run = await CatalogSession(job: j).directions(first.id)

        XCTAssertEqual(writerCalls, 1, "批了才写，日常一次写手")
        XCTAssertFalse(embedder.calls.isEmpty, "批了才搜")
        XCTAssertEqual(run.proposals, 1)
        XCTAssertFalse(wiki.pageExists("楼层/主题/灯塔航线"), "第一次批不落页")
        for id in ids { XCTAssertNil(try memory(id)?.organizedAt, "正文没批不打标") }
        let content = try XCTUnwrap(contentProposals().first)
        XCTAssertEqual(content.directionRef, .init(proposalId: first.id, itemId: first.items[0].id))
        XCTAssertEqual(content.origin, .scheduled)
        let done = try XCTUnwrap(store.load(first.id)?.items.first?.change.direction)
        XCTAssertNotNil(done.ranAt)
        XCTAssertEqual(done.contentProposalId, content.id)
        XCTAssertTrue(try XCTUnwrap(done.result).hasPrefix("交了 1 条正文等批"))

        try await approve(content.id)
        XCTAssertTrue(wiki.pageExists("楼层/主题/灯塔航线"), "第二次批才落页")
        for id in ids { XCTAssertEqual(try memory(id)?.organizedPage, "楼层/主题/灯塔航线", "引用的和 covered 的一起标") }
    }

    // MARK: - 逐条批；驳回方向不伤线索；没新证据不重提

    func testPerItemApprovalAndRejectedDirectionLeavesCluesUntouched() async throws {
        let jia = try (12...14).map { try fragment("甲事\($0)", subject: "甲", day: $0).id }
        let yi = try (15...17).map { try fragment("乙事\($0)", subject: "乙", day: $0).id }
        var writerUsers: [String] = []
        let j = job(caller: { _, user in
            writerUsers.append(user)
            return "{\"items\":[],\"reason\":\"测试不写\"}"
        })
        _ = await CatalogSession(job: j).daily(now: Date())
        let p = try directionProposal()
        let items = Dictionary(uniqueKeysWithValues: p.items.map { ($0.change.direction!.title, $0.id) })
        XCTAssertEqual(Set(items.keys), ["甲", "乙"])

        try await approve(p.id, [items["甲"]!])
        try await WikiProposalReview.reject(p.id, itemIds: [items["乙"]!], store: store, context: ModelContext(container))
        _ = await CatalogSession(job: j).directions(p.id)

        XCTAssertEqual(writerUsers.count, 1, "只执行批了的那条")
        XCTAssertTrue(writerUsers[0].contains("标题：甲"))
        for id in jia + yi {
            let m = try XCTUnwrap(try memory(id))
            XCTAssertNil(m.organizeRejectedAt, "驳回方向不连带驳回线索碎片")
            XCTAssertNil(m.organizedAt)
        }

        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertEqual(store.list().count, 1, "驳回 / 执行过的方向没有新碎片不再提")
        try fragment("乙又一件", subject: "乙", day: 18)
        _ = await CatalogSession(job: j).daily(now: Date())
        let again = try XCTUnwrap(store.list().first { $0.id != p.id })
        XCTAssertEqual(again.items.compactMap(\.change.direction?.title), ["乙"], "有新证据才重提")
        XCTAssertEqual(again.items.first?.change.direction?.clues.count, 4)
    }

    func testPendingDirectionIsNotProposedAgain() async throws {
        try (12...14).forEach { try fragment("丙事\($0)", subject: "丙", day: $0) }
        let j = job()
        _ = await CatalogSession(job: j).daily(now: Date())
        try fragment("丙又一件", subject: "丙", day: 15)
        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertEqual(store.list().count, 1, "同一页还有待批方向，不重复提")
    }

    // MARK: - 重复点：不重付

    func testRepeatedApprovalAndConcurrentExecutionPayOnce() async throws {
        try (12...14).forEach { try fragment("丁事\($0)", subject: "丁", day: $0) }
        var writerCalls = 0
        let j = job(caller: { _, _ in
            writerCalls += 1
            return "{\"items\":[],\"reason\":\"没有新事实\"}"
        })
        _ = await CatalogSession(job: j).daily(now: Date())
        let p = try directionProposal()
        try await approve(p.id)
        try await approve(p.id)

        let runner = CatalogRunner(defaults: UserDefaults(suiteName: "xctest-direction-\(UUID().uuidString)")!)
        async let a = runner.start(job: j) { await $0.directions(p.id) }
        async let b = runner.start(job: j) { await $0.directions(p.id) }
        _ = await (a, b)
        _ = await CatalogSession(job: j).directions(p.id)

        XCTAssertEqual(writerCalls, 1, "认领在锁里记开始时间：重复批、重复点、并发都只付一次")
    }

    // MARK: - 手动：说一次就进 agent；正文没批不落页

    func testManualTopicRunsAgentOnceWithoutDirectionAndWaitsForContentApproval() async throws {
        let m = try fragment("一起看了电影", subject: "电影")
        let backend = FakeCatalogBackend { n, _ in
            n == 1 ? .toolCalls([CatalogTestKit.call("search_fragments", "{\"terms\":[\"电影\"]}")])
                : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, """
                {"items":[{"type":"new_page","path":"楼层/事/电影","kind":"事","title":"电影","records":[{"text":"2026-10-12 一起看了电影","fragments":["f1"]}]}]}
                """)])
        }
        let report = await CatalogSession(job: job(backend: backend)).organizeTopic("电影")

        XCTAssertEqual(backend.requests.count, 2, "说一次就直接进 agent")
        XCTAssertEqual(report.proposals, 1)
        XCTAssertEqual(store.list().count, 1)
        let p = try XCTUnwrap(store.list().first)
        XCTAssertNil(p.items.first { $0.change.direction != nil }, "不出现重复批方向")
        XCTAssertEqual(p.request?.text, "整理一个主题：电影")
        XCTAssertEqual(p.request?.profileId, pid)
        XCTAssertFalse(wiki.pageExists("楼层/事/电影"), "正文没批不落页")
        XCTAssertNil(try memory(m.id)?.organizedAt)

        try await approve(p.id)
        XCTAssertTrue(wiki.pageExists("楼层/事/电影"))
        XCTAssertEqual(try memory(m.id)?.organizedPage, "楼层/事/电影")
    }

    // MARK: - {助手}的建议：先批方向

    func testAssistantSuggestionNeedsDirectionApprovalFirst() async throws {
        try fragment("云桥城地图画好了", subject: "云桥城")
        let backend = FakeCatalogBackend { n, _ in
            n == 1 ? .toolCalls([CatalogTestKit.call("search_fragments", "{\"terms\":[\"云桥城\"]}")])
                : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, """
                {"items":[{"type":"new_page","path":"楼层/地点/云桥城","kind":"地点","title":"云桥城","records":[{"text":"2026-10-12 地图画好了","fragments":["f1"]}]}]}
                """)])
        }
        let args = "{\"path\":\"/楼层/地点/云桥城.md\",\"reason\":\"刚聊到新地图\"}"

        let r = WikiSuggestTool.execute(inputJSON: args, wiki: wiki, profileId: pid)
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(backend.requests.isEmpty, "提方向不调模型")
        let p = try directionProposal()
        XCTAssertEqual(p.origin, .assistant)
        let d = try XCTUnwrap(p.items.first?.change.direction)
        XCTAssertEqual(d.path, "楼层/地点/云桥城")
        XCTAssertEqual(d.action, .newPage)
        XCTAssertEqual(d.mode, .agent)
        XCTAssertEqual(d.reason, "刚聊到新地图")
        XCTAssertEqual(p.items.first?.state, .pending)

        XCTAssertFalse(WikiSuggestTool.execute(inputJSON: args, wiki: wiki, profileId: pid).isError)
        XCTAssertEqual(store.list().count, 1, "同一页有待批方向不重复交")
        XCTAssertTrue(WikiSuggestTool.execute(inputJSON: "{\"path\":\"随便/页\",\"reason\":\"x\"}", wiki: wiki, profileId: pid).isError)
        XCTAssertTrue(WikiSuggestTool.execute(inputJSON: "{\"path\":\"楼层/地点/别处\"}", wiki: wiki, profileId: pid).isError)

        let j = job(backend: backend)
        _ = await CatalogSession(job: j).directions(p.id)
        XCTAssertTrue(backend.requests.isEmpty, "没批不执行")

        try await approve(p.id)
        let run = await CatalogSession(job: j).directions(p.id)
        XCTAssertEqual(backend.requests.count, 2, "批了才查、写（agent）")
        XCTAssertTrue(try XCTUnwrap(backend.requests.first?.history.first?.content).contains("为什么提这个方向：刚聊到新地图"))
        XCTAssertEqual(run.proposals, 1)
        let content = try XCTUnwrap(contentProposals().first)
        XCTAssertEqual(content.origin, .assistant)
        XCTAssertEqual(content.directionRef?.proposalId, p.id)
        XCTAssertFalse(wiki.pageExists("楼层/地点/云桥城"))
        try await approve(content.id)
        XCTAssertTrue(wiki.pageExists("楼层/地点/云桥城"))
    }

    // MARK: - covered-only：不改正文，批了才打标；stale

    func testCoveredOnlyDoesNotTouchPageAndMarksOnlyAfterApproval() async throws {
        try wiki.save(WikiPage(path: "楼层/地点/云桥城", kind: .place, triggers: ["云桥城"], hook: "提到云桥城时", title: "云桥城",
                               now: "画了地图（自 2026-10 起）。"))
        let raw = try XCTUnwrap(wiki.readRaw("楼层/地点/云桥城"))
        let m = try fragment("云桥城地图画好了", subject: "云桥城夜市")
        let j = job(caller: { _, _ in "{\"items\":[],\"covered\":[\"f1\"]}" })
        _ = await CatalogSession(job: j).daily(now: Date())
        let p = try directionProposal()
        XCTAssertEqual(p.items.first?.change.direction?.action, .update, "单条碰上已有页就提更新，不受 3 条门槛")

        try await approve(p.id)
        _ = await CatalogSession(job: j).directions(p.id)
        let content = try XCTUnwrap(contentProposals().first)
        XCTAssertEqual(content.items.map(\.change), [.confirmCovered(path: "楼层/地点/云桥城")])
        XCTAssertNil(try memory(m.id)?.organizedAt, "待批时不打标")
        XCTAssertTrue(CatalogMaterial.pendingFragmentIds(store).contains(m.id), "待批不重复发现")

        try await approve(content.id)
        XCTAssertEqual(wiki.readRaw("楼层/地点/云桥城"), raw, "不改页正文")
        XCTAssertEqual(try memory(m.id)?.organizedPage, "楼层/地点/云桥城")
    }

    func testContentGoesStaleWhenPageChangesBeforeSecondApproval() async throws {
        try wiki.save(WikiPage(path: "楼层/地点/云桥城", kind: .place, triggers: ["云桥城"], hook: "", title: "云桥城"))
        let m = try fragment("云桥城地图画好了", subject: "云桥城")
        let n = try fragment("云桥城夜市开张", subject: "云桥城", day: 13)
        let j = job(caller: { _, _ in
            "{\"items\":[{\"type\":\"append\",\"path\":\"楼层/地点/云桥城\",\"records\":[{\"text\":\"2026-10-12 地图画好了\",\"fragments\":[\"f1\"]}]}],\"covered\":[\"f2\"]}"
        })
        _ = await CatalogSession(job: j).daily(now: Date())
        try await approve(try directionProposal().id)
        _ = await CatalogSession(job: j).directions(try directionProposal().id)
        let content = try XCTUnwrap(contentProposals().first)

        var hand = try XCTUnwrap(wiki.read("楼层/地点/云桥城"))
        hand.now = "她手改了"
        try wiki.saveRaw(hand.markdown, path: "楼层/地点/云桥城")
        let out = try await approve(content.id)

        XCTAssertEqual(out.items.first?.state, .stale, "页已变，不硬盖")
        XCTAssertEqual(wiki.read("楼层/地点/云桥城")?.now, "她手改了")
        XCTAssertNil(try memory(m.id)?.organizedAt)
        XCTAssertNil(try memory(n.id)?.organizedAt)
    }

    // MARK: - 单条就够：留池可召回；新证据能归页

    func testSingleStaysRecallableAndJoinsPageWithNewEvidence() async throws {
        let first = try (12...14).map { try fragment("喜欢纸帆船\($0)", subject: "纸帆船", day: $0).id }
        var reply = "{\"items\":[],\"single\":[\"f1\",\"f2\",\"f3\"]}"
        let j = job(caller: { _, _ in reply })
        _ = await CatalogSession(job: j).daily(now: Date())
        let p = try directionProposal()
        try await approve(p.id)
        let run = await CatalogSession(job: j).directions(p.id)

        XCTAssertEqual(run.single, 3)
        XCTAssertEqual(run.proposals, 0, "单条就够不造正文提案")
        XCTAssertTrue(try XCTUnwrap(store.load(p.id)?.items.first?.change.direction?.result).hasPrefix("单条就够 3 条"))
        for id in first { XCTAssertEqual(try memory(id)?.isSingleEnough, true) }
        let snapshot = await CatalogMaterial.snapshot(profileId: pid, container: container, embedder: CatalogFakeEmbedder.unavailable())
        let tools = CatalogAgentTools(wiki: wiki, memoryRoot: root, fragments: snapshot, embedder: CatalogFakeEmbedder.unavailable())
        let found = await tools.execute(name: "search_fragments", argumentsJSON: "{\"terms\":[\"纸帆船\"]}", now: Date())
        XCTAssertTrue(found.text.contains("喜欢纸帆船12") && found.text.contains("单条就够"), "单条就够仍能召回，不是驳回")

        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertEqual(store.list().count, 1, "单条就够的自己不会再被提")

        let fresh = try fragment("纸帆船换了蓝色帆", subject: "纸帆船", day: 15)
        _ = await CatalogSession(job: j).daily(now: Date())
        let again = try XCTUnwrap(store.list().first { $0.id != p.id })
        XCTAssertEqual(Set(again.items.first?.change.direction?.clues ?? []), Set(first + [fresh.id]), "新证据把单条就够的带回来重新归组")
        reply = """
        {"items":[{"type":"new_page","path":"楼层/主题/纸帆船","kind":"主题","title":"纸帆船","records":[
        {"text":"2026-10-12 喜欢纸帆船","fragments":["f1","f2","f3"]},{"text":"2026-10-15 换了蓝色帆","fragments":["f4"]}]}]}
        """
        try await approve(again.id)
        _ = await CatalogSession(job: j).directions(again.id)
        try await approve(try XCTUnwrap(contentProposals().first).id)
        for id in first + [fresh.id] { XCTAssertEqual(try memory(id)?.organizedPage, "楼层/主题/纸帆船", "有新证据时能归进页") }
    }

    // MARK: - 确实没材料：不造假提案、不打标、释放占用

    func testNoMaterialReleasesOccupancyWithoutMarks() async throws {
        let ids = try (12...14).map { try fragment("闲聊\($0)", subject: "闲聊", day: $0).id }
        let j = job(caller: { _, _ in "{\"items\":[],\"reason\":\"都是闲聊，没有长期事实\"}" })
        _ = await CatalogSession(job: j).daily(now: Date())
        let p = try directionProposal()
        try await approve(p.id)
        let run = await CatalogSession(job: j).directions(p.id)

        XCTAssertEqual(run.proposals, 0)
        XCTAssertEqual(store.list().count, 1, "不造假提案")
        XCTAssertEqual(store.load(p.id)?.items.first?.change.direction?.result, "没有可写的材料：都是闲聊，没有长期事实")
        for id in ids { XCTAssertNil(try memory(id)?.organizedAt) }
        XCTAssertTrue(CatalogMaterial.pendingFragmentIds(store).isDisjoint(with: ids), "释放占用")
    }

    // MARK: - 失败 / 停止

    func testCancelDuringWriteLeavesNothingAndNeverResumes() async throws {
        let ids = try (12...14).map { try fragment("戊事\($0)", subject: "戊", day: $0).id }
        var session: CatalogSession!
        var calls = 0
        let j = job(caller: { _, _ in
            calls += 1
            await MainActor.run { session.cancel() }
            return "{\"items\":[{\"type\":\"new_page\",\"path\":\"楼层/主题/戊\",\"records\":[{\"text\":\"戊\",\"fragments\":[\"f1\"]}]}]}"
        })
        _ = await CatalogSession(job: j).daily(now: Date())
        let p = try directionProposal()
        try await approve(p.id)
        session = CatalogSession(job: j)
        let run = await session.directions(p.id)

        XCTAssertTrue(run.cancelled)
        XCTAssertEqual(run.proposals, 0)
        XCTAssertEqual(store.load(p.id)?.items.first?.change.direction?.result, "停了，没交正文")
        for id in ids { XCTAssertNil(try memory(id)?.organizedAt) }
        _ = await CatalogSession(job: j).directions(p.id)
        XCTAssertEqual(calls, 1, "停了不自动续跑")
    }

    func testCancelBeforeExecutionRecordsStopped() async throws {
        try (12...14).forEach { try fragment("己事\($0)", subject: "己", day: $0) }
        var calls = 0
        let j = job(caller: { _, _ in calls += 1; return nil })
        _ = await CatalogSession(job: j).daily(now: Date())
        let p = try directionProposal()
        try await approve(p.id)
        let session = CatalogSession(job: j)
        session.cancel()
        let run = await session.directions(p.id)

        XCTAssertTrue(run.cancelled)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(store.load(p.id)?.items.first?.change.direction?.result, "停了，没执行")
    }

    func testAgentFailureAndGiveUpRecordResultWithoutProposal() async throws {
        for (path, backend, expected) in [
            ("楼层/地点/坏了", FakeCatalogBackend { _, _ in .failed("后端坏了") }, "出错：后端坏了"),
            ("楼层/地点/不交", FakeCatalogBackend { _, _ in .finished("我不想交") }, "到顶了也没交，没出正文"),
        ] {
            XCTAssertFalse(WikiSuggestTool.execute(inputJSON: "{\"path\":\"\(path)\",\"reason\":\"测试\"}", wiki: wiki, profileId: pid).isError)
            let p = try XCTUnwrap(store.list().first { $0.items.first?.change.direction?.path == path })
            try await approve(p.id)
            let run = await CatalogSession(job: job(backend: backend, maxRounds: 2)).directions(p.id)
            XCTAssertEqual(run.proposals, 0)
            XCTAssertEqual(store.load(p.id)?.items.first?.change.direction?.result, expected)
        }
        XCTAssertTrue(contentProposals().isEmpty)
    }

    // MARK: - 旧数据：非种子旧正文提案照常当第二批审

    func testLegacyContentProposalStillApprovesAsSecondBatch() async throws {
        try wiki.save(WikiPage(path: "楼层/人/小慧", kind: .person, triggers: ["小慧"], hook: "", title: "小慧"))
        let version = try XCTUnwrap(wiki.version(of: "楼层/人/小慧"))
        let id = UUID().uuidString
        let json = """
        {"id":"\(id)","origin":"manual","createdAt":1800000000,"incomplete":false,"items":[{"id":"\(UUID().uuidString)","state":"pending",
        "change":{"appendRecords":{"path":"楼层/人/小慧","lines":["2026-10-12 搬家（出处：碎片 1）"]}},"fragmentIds":[],"cites":[],"baseVersion":"\(version)"}]}
        """
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.folder.appendingPathComponent(id + ".json"))
        let legacy = try XCTUnwrap(store.load(id))
        XCTAssertNil(legacy.directionRef)
        XCTAssertNil(legacy.request)

        let out = try await approve(id)
        XCTAssertEqual(out.items.first?.state, .approved)
        XCTAssertEqual(wiki.read("楼层/人/小慧")?.records, ["2026-10-12 搬家（出处：碎片 1）"])
    }

    // MARK: - 返工 ③：写模块拿完整底图

    /// 第 9 段：日常写手两次都没过硬查，正文照样进审计台，条目上标着没过的项；批了原样落页，不截字
    func testDailyContentFailingHardChecksTwiceReachesReviewFlagged() async throws {
        try (12...14).forEach { try fragment("灯塔第\($0)天", subject: "灯塔", day: $0) }
        let long = "2026-10-12 第一次跟着领航员把灯塔航线从头到尾走完一整圈，还记下了每个浮标的编号"
        let reply = page("楼层/主题/灯塔", records: [long])
        var calls = 0
        let j = job(caller: { _, _ in
            calls += 1
            return reply
        })
        _ = await CatalogSession(job: j).daily(now: Date())
        let p = try directionProposal()
        try await approve(p.id)
        _ = await CatalogSession(job: j).directions(p.id)
        XCTAssertEqual(calls, 2, "只给一次重写")
        let content = try XCTUnwrap(contentProposals().first)
        let flags = try XCTUnwrap(content.items.first?.checks)
        XCTAssertTrue(flags.contains { $0.contains("超过 30 字") }, "\(flags)")
        XCTAssertEqual(store.load(content.id)?.items.first?.checks, flags, "存盘带着标记")
        XCTAssertEqual(content.revision, "重写一次后仍有没过的", "标明修订实际走到哪一步")
        try await approve(content.id)
        XCTAssertTrue(try XCTUnwrap(wiki.read("楼层/主题/灯塔")?.records.first).hasPrefix(long + "（出处："))
    }

    /// 整稿只剩一条关系不对的连线：照样成提案，连线原样挂在来源页上给她看，不执行
    func testDailyHeldLinkAloneStillReachesReview() async throws {
        try wiki.save(WikiPage(path: "楼层/人/小慧", kind: .person, triggers: ["小慧"], hook: "", title: "小慧", now: "室友（自 2026-09 起）。"))
        try (12...14).forEach { try fragment("灯塔第\($0)天", subject: "灯塔", day: $0) }
        let reply = "{\"items\":[{\"type\":\"link\",\"path\":\"楼层/人/小慧\",\"to\":\"楼层/主题/灯塔\",\"relation\":\"取代\",\"why\":\"常一起去\"}]}"
        var calls = 0
        let j = job(caller: { _, _ in
            calls += 1
            return reply
        })
        _ = await CatalogSession(job: j).daily(now: Date())
        let p = try directionProposal()
        try await approve(p.id)
        _ = await CatalogSession(job: j).directions(p.id)
        XCTAssertEqual(calls, 2)
        let content = try XCTUnwrap(contentProposals().first)
        XCTAssertEqual(content.items, [])
        XCTAssertEqual(content.unapplied?.map(\.page), ["楼层/人/小慧"])
        XCTAssertTrue(content.unapplied?.first?.raw.contains(#""relation":"取代""#) == true)
        XCTAssertEqual(content.status, .pending, "没看过就算待阅")
        XCTAssertEqual(content.revision, "重写一次后仍有没过的")
        XCTAssertEqual(wiki.read("楼层/人/小慧")?.links, [], "只展示，不执行")
    }

    func testWriterAndAgentReceiveFullFloorBaseBeyondOldTruncation() async throws {
        let suite = "xctest-direction-floor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let presets = PresetManager(root: root.appendingPathComponent("blobs", isDirectory: true), defaults: defaults)
        var profile = Profile(id: pid, name: "灯塔", emoji: "", description: "", userName: "阿禾", assistantName: "岚")
        var instance = presets.instantiate(templateId: Preset.balanced.id, for: profile.id)
        profile.presetId = instance.id
        let tail = "尾部事实：《云桥城》灯塔的钥匙藏在第三层。"
        let at = instance.prompts.firstIndex { $0.id == PromptSlot.chatHistoryId } ?? instance.prompts.count
        instance.prompts.insert(PromptSlot(id: "custom-tail", name: "自建设定", content: String(repeating: "航线记录。", count: 700) + tail), at: at)
        try presets.persistNew(instance)
        let runner = CatalogRunner(defaults: defaults)
        runner.attach(presetManager: presets)
        let floor = runner.writerFloorPrompt(profile: profile)
        XCTAssertFalse(CatalogFloorPrompt.text(profile: profile, defaults: defaults).contains(tail), "旧五段截断看不到自建槽")
        XCTAssertTrue(floor.contains(tail))

        try (12...14).forEach { try fragment("灯塔第\($0)天", subject: "灯塔", day: $0) }
        var writerInput = ""
        let backend = FakeCatalogBackend { _, _ in .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, "{\"items\":[],\"reason\":\"测试\"}")]) }
        var j = job(caller: { _, user in writerInput = user; return "{\"items\":[],\"reason\":\"测试\"}" }, backend: backend)
        j.floorPrompt = floor
        _ = await CatalogSession(job: j).daily(now: Date())
        let p = try directionProposal()
        try await approve(p.id)
        _ = await CatalogSession(job: j).directions(p.id)
        XCTAssertTrue(writerInput.contains(tail), "批了方向的写手实际收到 3000 字之后、自建槽里的事实")

        _ = await CatalogSession(job: j).organizeTopic("灯塔")
        XCTAssertTrue(try XCTUnwrap(backend.requests.first?.history.first?.content).contains(tail), "手动 agent 实际开场也有")
    }

    // MARK: - 返工 ④：手动入口的 covered-only 与 single

    func testManualTopicCoveredOnlyLinksTheReadPage() async throws {
        try wiki.save(WikiPage(path: "楼层/地点/云桥城", kind: .place, triggers: ["云桥城"], hook: "", title: "云桥城", now: "地图画好了。"))
        let raw = try XCTUnwrap(wiki.readRaw("楼层/地点/云桥城"))
        let m = try fragment("云桥城地图画好了", subject: "云桥城")
        let backend = FakeCatalogBackend { n, _ in
            n == 1 ? .toolCalls([CatalogTestKit.call("read_wiki", "{\"path\":\"楼层/地点/云桥城\"}"),
                                 CatalogTestKit.call("search_fragments", "{\"terms\":[\"云桥城\"]}")])
                : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, "{\"items\":[],\"covered\":[\"f1\"]}")])
        }
        _ = await CatalogSession(job: job(backend: backend)).organizeTopic("云桥城")

        let content = try XCTUnwrap(store.list().first)
        XCTAssertEqual(content.items.map(\.change), [.confirmCovered(path: "楼层/地点/云桥城")], "点名入口没有预分配页，covered 挂在实际读过的页上")
        XCTAssertEqual(content.items.first?.covered, [m.id])
        XCTAssertNil(try memory(m.id)?.organizedAt)
        try await approve(content.id)
        XCTAssertEqual(wiki.readRaw("楼层/地点/云桥城"), raw)
        XCTAssertEqual(try memory(m.id)?.organizedPage, "楼层/地点/云桥城")
    }

    func testSingleCountsFragmentsActuallyProvidedToTheAgent() async throws {
        let boat = try fragment("喜欢纸帆船", subject: "纸帆船")
        let other = try fragment("灯塔漆成白色", subject: "灯塔", day: 13)
        let reply = "{\"items\":[],\"single\":[\"f1\",\"f2\",\"f3\"]}"
        let backend = FakeCatalogBackend { n, _ in
            n % 2 == 1 ? .toolCalls([CatalogTestKit.call("search_fragments", "{\"terms\":[\"纸帆船\"]}")])
                : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, reply)])
        }
        let report = await CatalogSession(job: job(backend: backend)).organizeTopic("纸帆船")
        XCTAssertEqual(report.single, 1, "点名入口没有预分配线索，按实际搜到给过它的碎片认")
        XCTAssertEqual(try memory(boat.id)?.isSingleEnough, true)
        XCTAssertNil(try memory(other.id)?.organizedAt, "没给过它的编号不认")

        let fresh = try fragment("纸帆船换了新帆", subject: "纸帆船", day: 14)
        XCTAssertFalse(WikiSuggestTool.execute(inputJSON: "{\"path\":\"楼层/物/纸帆船\",\"reason\":\"测试\"}", wiki: wiki, profileId: pid).isError)
        let p = try directionProposal()
        XCTAssertEqual(p.items.first?.change.direction?.clues, [], "助手方向是空线索")
        try await approve(p.id)
        let run = await CatalogSession(job: job(backend: backend)).directions(p.id)
        XCTAssertGreaterThanOrEqual(run.single, 1)
        XCTAssertEqual(try memory(fresh.id)?.isSingleEnough, true, "空线索方向也按实际给过的碎片认 single")
        XCTAssertNil(try memory(other.id)?.organizedAt)
    }

    // MARK: - 返工 ⑤：编辑进同一把锁

    func testEditInterleavedWithClaimNeverOverwritesRanAtOrPaysTwice() async throws {
        try (12...14).forEach { try fragment("甲事\($0)", subject: "甲", day: $0) }
        try (15...17).forEach { try fragment("乙事\($0)", subject: "乙", day: $0) }
        var writerCalls = 0
        let j = job(caller: { _, _ in writerCalls += 1; return "{\"items\":[],\"reason\":\"测试\"}" })
        _ = await CatalogSession(job: j).daily(now: Date())
        let p = try directionProposal()
        let a = try XCTUnwrap(p.items.first { $0.change.direction?.title == "甲" })
        let b = try XCTUnwrap(p.items.first { $0.change.direction?.title == "乙" })
        try await approve(p.id, [a.id])

        var draft = WikiProposalDraft(b.change)
        draft.title = "乙（改过）"
        async let edited = WikiProposalReview.edit(p.id, itemId: b.id, change: draft.apply(to: b.change), judgment: nil, store: store)
        async let run = CatalogSession(job: j).directions(p.id)
        _ = try await edited
        _ = await run

        let after = try XCTUnwrap(store.load(p.id))
        let da = try XCTUnwrap(after.items.first { $0.id == a.id }?.change.direction)
        XCTAssertNotNil(da.ranAt, "编辑没有覆盖认领")
        XCTAssertNotNil(da.result, "编辑没有覆盖结果")
        XCTAssertEqual(after.items.first { $0.id == b.id }?.change.direction?.title, "乙（改过）")
        XCTAssertEqual(after.items.first { $0.id == b.id }?.state, .pending)
        _ = await CatalogSession(job: j).directions(p.id)
        XCTAssertEqual(writerCalls, 1, "不重复付费")
        do {
            _ = try await WikiProposalReview.edit(p.id, itemId: a.id, change: a.change, judgment: nil, store: store)
            XCTFail("已批的不能再改")
        } catch WikiProposalStore.ProposalError.notPending {}
    }

    // MARK: - 返工 ⑥：执行前没跑成、上次中断

    func testNotRunBeforeExecutionRecordsReasonAndConsumes() async throws {
        let floorStore = WikiProposalStore(wiki: WikiStore(profileId: pid))
        let d = WikiProposal.Direction(path: "楼层/主题/甲", title: "甲", action: .newPage, reason: "测试", mode: .daily)
        let item = WikiProposal.Item(state: .approved, change: .direction(d))
        let p = WikiProposal(origin: .scheduled, createdAt: Date(), items: [item])
        try floorStore.save(p)
        let suite = "xctest-direction-c3off-\(UUID().uuidString)"
        let off = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { off.removePersistentDomain(forName: suite) }
        MemoryWriterSettings.set(.c3, false, defaults: off)
        let profile = Profile(id: pid, name: "测试", emoji: "", description: "", userName: "甲", assistantName: "乙")
        await CatalogRunner(defaults: off).runDirections(proposalId: p.id, itemIds: [item.id], profile: profile).value
        let closed = try XCTUnwrap(floorStore.load(p.id)?.items.first?.change.direction)
        XCTAssertEqual(closed.result, "C3 关着，没执行")
        XCTAssertNotNil(closed.ranAt, "保留已消费标记")

        try (12...14).forEach { try fragment("乙事\($0)", subject: "乙", day: $0) }
        var writerCalls = 0
        let j = job(caller: { _, _ in writerCalls += 1; return nil })
        _ = await CatalogSession(job: j).daily(now: Date())
        let queued = try directionProposal()
        try await approve(queued.id)
        let runner = CatalogRunner(defaults: UserDefaults(suiteName: "xctest-direction-q-\(UUID().uuidString)")!)
        await CatalogLock.shared.acquire(pid)
        let task = runner.runDirections(job: j, proposalId: queued.id, itemIds: Set(queued.items.map(\.id)))
        while !runner.isRunning { await Task.yield() }
        runner.cancel()
        await CatalogLock.shared.release(pid)
        await task.value
        XCTAssertEqual(store.load(queued.id)?.items.first?.change.direction?.result, "排队时点了停，没执行")
        XCTAssertEqual(writerCalls, 0)
        _ = await CatalogSession(job: j).directions(queued.id)
        XCTAssertEqual(writerCalls, 0, "已消费，不再执行")
    }

    func testColdStartFinishesInterruptedDirectionsWithoutRerunning() async throws {
        let launch = Date()
        func direction(_ title: String, ranAt: Date) -> WikiProposal.Item {
            var d = WikiProposal.Direction(path: "楼层/主题/\(title)", title: title, action: .newPage, reason: "测试", mode: .daily)
            d.ranAt = ranAt
            return WikiProposal.Item(state: .approved, change: .direction(d))
        }
        let delivered = direction("已交", ranAt: launch.addingTimeInterval(-60))
        let lost = direction("没交", ranAt: launch.addingTimeInterval(-60))
        let current = direction("这次在跑", ranAt: launch.addingTimeInterval(5))
        let p = WikiProposal(origin: .scheduled, createdAt: launch.addingTimeInterval(-120), items: [delivered, lost, current])
        try store.save(p)
        let content = WikiProposal(origin: .scheduled, createdAt: launch.addingTimeInterval(-30), title: "已交",
                                   items: [.init(change: .confirmCovered(path: "楼层/主题/已交"), baseVersion: "v")],
                                   directionRef: .init(proposalId: p.id, itemId: delivered.id))
        try store.save(content)

        let fixed = try await WikiProposalReview.finishInterrupted(store: store, before: launch)

        XCTAssertEqual(fixed, 2)
        let after = try XCTUnwrap(store.load(p.id)).items.map { $0.change.direction! }
        XCTAssertEqual(after[0].result, "交了 1 条正文等批（上次运行中断前已交）")
        XCTAssertEqual(after[0].contentProposalId, content.id)
        XCTAssertEqual(after[1].result, "上次运行中断，没交正文")
        XCTAssertNil(after[2].result, "这次进程里正在跑的不动")
        XCTAssertTrue(after.allSatisfy { $0.ranAt != nil }, "保留已消费标记")
        var calls = 0
        _ = await CatalogSession(job: job(caller: { _, _ in calls += 1; return nil })).directions(p.id)
        XCTAssertEqual(calls, 0, "不重发请求")
    }

    // MARK: - 返工 ⑦：改过的钩子是写模块的硬输入

    func testEditedHookReachesWriterAndAgentAndLandsInContent() async throws {
        try wiki.save(WikiPage(path: "楼层/地点/云桥城", kind: .place, triggers: ["云桥城"], hook: "旧钩子", title: "云桥城"))
        try (12...14).forEach { try fragment("甲事\($0)", subject: "甲", day: $0) }
        try fragment("云桥城夜市", subject: "云桥城", day: 15)
        var writerUsers: [String] = []
        let j = job(caller: { _, user in
            writerUsers.append(user)
            return user.contains("标题：甲")
                ? "{\"items\":[{\"type\":\"new_page\",\"path\":\"楼层/主题/甲\",\"kind\":\"主题\",\"title\":\"甲\",\"hook\":\"模型自己写的\",\"records\":[{\"text\":\"2026-10-12 甲\",\"fragments\":[\"f1\"]}]}]}"
                : "{\"items\":[{\"type\":\"append\",\"path\":\"楼层/地点/云桥城\",\"records\":[{\"text\":\"2026-10-15 夜市\",\"fragments\":[\"f4\"]}]}]}"
        })
        _ = await CatalogSession(job: j).daily(now: Date())
        let p = try directionProposal()
        for item in p.items {
            var draft = WikiProposalDraft(item.change)
            draft.hook = item.change.direction?.title == "甲" ? "提到甲的时候先看" : "说云桥城夜市时先看"
            try await WikiProposalReview.edit(p.id, itemId: item.id, change: draft.apply(to: item.change), judgment: nil, store: store)
        }
        try await approve(p.id)
        _ = await CatalogSession(job: j).directions(p.id)

        XCTAssertTrue(writerUsers.contains { $0.contains("【定好的钩子】提到甲的时候先看") })
        XCTAssertTrue(writerUsers.contains { $0.contains("【定好的钩子】说云桥城夜市时先看") })
        let changes = contentProposals().flatMap { $0.items.map(\.change) }
        XCTAssertTrue(changes.contains { if case .newPage(let page) = $0 { page.hook == "提到甲的时候先看" } else { false } }, "新开页用定好的钩子")
        XCTAssertTrue(changes.contains(.retag(path: "楼层/地点/云桥城", oldHook: "旧钩子", newHook: "说云桥城夜市时先看",
                                              oldTriggers: ["云桥城"], newTriggers: ["云桥城"])), "已有页补一条改钩子，照样等批")

        let backend = FakeCatalogBackend { n, _ in
            n == 1 ? .toolCalls([CatalogTestKit.call("search_fragments", "{\"terms\":[\"甲\"]}")]) : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, """
            {"items":[{"type":"new_page","path":"楼层/物/纸帆船","kind":"物","title":"纸帆船","hook":"模型的","records":[{"text":"2026-10-12 甲","fragments":["f1"]}]}]}
            """)])
        }
        XCTAssertFalse(WikiSuggestTool.execute(inputJSON: "{\"path\":\"楼层/物/纸帆船\",\"reason\":\"测试\"}", wiki: wiki, profileId: pid).isError)
        let suggestion = try XCTUnwrap(store.list().first { $0.origin == .assistant && $0.items.first?.change.direction != nil })
        let item = try XCTUnwrap(suggestion.items.first)
        var draft = WikiProposalDraft(item.change)
        draft.hook = "提到纸帆船时先看"
        try await WikiProposalReview.edit(suggestion.id, itemId: item.id, change: draft.apply(to: item.change), judgment: nil, store: store)
        try await approve(suggestion.id)
        _ = await CatalogSession(job: job(backend: backend)).directions(suggestion.id)
        XCTAssertTrue(try XCTUnwrap(backend.requests.first?.history.first?.content).contains("定好的钩子：提到纸帆船时先看"))
        let agentContent = try XCTUnwrap(store.list().first { $0.directionRef?.proposalId == suggestion.id })
        guard case .newPage(let page) = agentContent.items.first?.change else { return XCTFail("应是新开页") }
        XCTAssertEqual(page.hook, "提到纸帆船时先看")
    }
}
