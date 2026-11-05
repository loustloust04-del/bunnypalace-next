import XCTest
import SwiftData
@testable import 记忆花园

final class CatalogFakeEmbedder: MemoryEmbedding, @unchecked Sendable {
    var isReady = true
    var revision = 7
    var vectors: [String: [Float]] = [:]
    private(set) var calls: [String] = []
    static func unavailable() -> CatalogFakeEmbedder {
        let embedder = CatalogFakeEmbedder()
        embedder.isReady = false
        return embedder
    }
    func embed(_ text: String) -> [Float]? {
        calls.append(text)
        return vectors[text]
    }
}

@MainActor
final class CatalogRetrievalTests: XCTestCase {
    private var root: URL!
    private var container: ModelContainer!
    private let pid = "catalog-p0-floor"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-p0-\(UUID().uuidString)")
        let schema = Schema([Memory.self, Conversation.self, MessageNode.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func time(_ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 20))!
    }

    private func files(_ id: String, day: Int = 12) throws {
        let start = time(day)
        try TimelineStore.seedLegacy(TimelineEntry(start: start, end: start.addingTimeInterval(600), conversationId: id,
                                               title: "编造航行日", text: "- 模型船配色改用水性颜料", pending: "", day: MemoryDay.key(start)),
                                 in: TimelineStore.dir(root: root))
        let segment = SessionSegment(kind: .rolling, title: "云桥城航线", start: start, end: start.addingTimeInterval(600), from: 4, to: 9,
                                     lastNodeId: "synthetic-node", story: "云桥城航线每局轮流领航", quotes: "", pending: "")
        try SessionSummaryStore.save(SessionSummary(conversationId: id, title: "编造航行日", compressedCount: 9, segments: [segment], updatedAt: start),
                                     in: SessionSummaryStore.dir(root: root))
    }

    func testChineseSubstringFindsSingleFragmentWithAndWithoutKeywords() async {
        let cases: [(String, [String])] = [
            ("云桥城地图画好了", []),
            ("我在看云桥城地图画好了", []),
            ("云桥城地图画好了", ["云桥城"]),
        ]
        for (content, keywords) in cases {
            var target = CatalogFragment(id: UUID(), content: content, category: "fact", day: "2026-10-12")
            target.keywords = keywords
            let result = await CatalogRetrieval(memoryRoot: root, fragments: [target], embedder: CatalogFakeEmbedder.unavailable())
                .search(["云桥城"], fragmentsOnly: true)
            XCTAssertEqual(result.fragments.map(\.id), [target.id], "单碎片不能因中文切词或 IDF 丢掉命中")
            XCTAssertEqual(result.receipt.evidence().fragments, [target.content])
        }
    }

    func testChineseSubstringFindsOnlyTargetAmongUnrelatedFragments() async {
        let target = CatalogFragment(id: UUID(), content: "云桥城地图画好了", category: "fact", day: "2026-10-12")
        let unrelated = ["云", "桥", "城", "云 船 桥 船 城", "墨水瓶换好了"].map {
            CatalogFragment(id: UUID(), content: $0, category: "fact", day: "2026-10-12")
        }
        let result = await CatalogRetrieval(memoryRoot: root, fragments: unrelated + [target], embedder: CatalogFakeEmbedder.unavailable())
            .search(["云桥城"], fragmentsOnly: true)
        XCTAssertEqual(result.fragments.map(\.id), [target.id], "单字或不相邻汉字不算云桥城")
        XCTAssertEqual(result.labels[target.id], "f6")
        XCTAssertEqual(result.receipt.evidence().fragments, [target.content])
    }

    func testChineseKeywordOnlyFragmentUsesQuerySegmentation() async {
        var target = CatalogFragment(id: UUID(), content: "航图装订完成", category: "fact", day: "2026-10-12")
        target.keywords = ["云桥城"]
        var unrelated = CatalogFragment(id: UUID(), content: "灯塔漆成白色", category: "fact", day: "2026-10-12")
        unrelated.keywords = ["云", "桥", "城"]
        let result = await CatalogRetrieval(memoryRoot: root, fragments: [unrelated, target], embedder: CatalogFakeEmbedder.unavailable())
            .search(["云桥城"], fragmentsOnly: true)
        XCTAssertEqual(result.fragments.map(\.id), [target.id])
        XCTAssertEqual(result.receipt.evidence().fragments, [target.content])
    }

    func testChineseSubstringReachesA2AndA4WithSharedTokenizer() async throws {
        let id = "hanquery-window"
        try files(id)
        let start = time(12)
        try TimelineStore.seedLegacy(TimelineEntry(start: start, end: start.addingTimeInterval(600), conversationId: id,
                                               title: "虚构地图", text: "- 云桥城地图画好了", pending: "", day: MemoryDay.key(start)),
                                 in: TimelineStore.dir(root: root))
        let result = await CatalogRetrieval(memoryRoot: root, fragments: [], embedder: CatalogFakeEmbedder.unavailable())
            .search(["云桥城"])
        XCTAssertEqual(Set(result.aline.hits.map(\.layer)), [.a2, .a4])
        XCTAssertEqual(Set(result.aline.hits.map(\.conversationId)), [id])
        XCTAssertTrue(result.receipt.evidence().aline.contains("云桥城地图画好了"))
        XCTAssertTrue(result.receipt.evidence().aline.contains("云桥城航线每局轮流领航"))
    }

    func testShortHanNameRejectsSuffixInFragmentAndALineRecall() async throws {
        let target = CatalogFragment(id: UUID(), content: "张小明画好了航图", category: "fact", day: "2026-10-12")
        var suffix = CatalogFragment(id: UUID(), content: "小明整理了记录", category: "fact", day: "2026-10-12")
        suffix.keywords = ["小明"]
        let start = time(12)
        for (id, text) in [("whole-name-window", target.content), ("suffix-name-window", suffix.content)] {
            try TimelineStore.seedLegacy(TimelineEntry(start: start, end: start.addingTimeInterval(60), conversationId: id,
                                                   title: "虚构航图", text: "- " + text, pending: "", day: MemoryDay.key(start)),
                                     in: TimelineStore.dir(root: root))
        }
        let result = await CatalogRetrieval(memoryRoot: root, fragments: [suffix, target],
                                             embedder: CatalogFakeEmbedder.unavailable()).search(["张小明"])
        XCTAssertEqual(result.fragments.map(\.id), [target.id])
        XCTAssertEqual(result.aline.hits.map(\.conversationId), ["whole-name-window"])
        XCTAssertEqual(result.receipt.evidence().fragments, [target.content])
        XCTAssertFalse(result.receipt.evidence().aline.contains(suffix.content))
    }

    func testCombinedTitleRetrievesA2A4AndFiltersDateFloorAndDeletedWindows() async throws {
        let context = ModelContext(container)
        for (id, floor, trashed, day) in [("valid000-window", pid, false, 12), ("other000-window", "other", false, 12),
                                          ("trash000-window", pid, true, 12), ("early000-window", pid, false, 2)] {
            let conversation = Conversation(id: id, title: "虚构窗口", createTime: time(day), updateTime: time(day), currentNodeId: "", profileId: floor)
            conversation.isTrashed = trashed
            context.insert(conversation)
            try files(id, day: day)
        }
        try context.save()
        let ids = await CatalogMaterial.conversationIds(profileId: pid, container: container)
        let fake = CatalogFakeEmbedder()
        fake.isReady = false
        let search = CatalogRetrieval(memoryRoot: root, fragments: [], conversationIds: ids, embedder: fake)
        let range = DateInterval(start: time(10), end: time(13))
        let result = await search.search(["模型船配色与云桥城航线"], in: range)
        XCTAssertEqual(Set(result.aline.hits.map(\.layer)), [.a2, .a4])
        XCTAssertEqual(Set(result.aline.hits.map(\.conversationId)), ["valid000-window"])
        XCTAssertEqual(result.aline.hits.first { $0.layer == .a2 }?.messages, 4..<9)
        XCTAssertTrue(result.aline.hits.contains { $0.text.contains("每局轮流领航") })
        let negative = await search.search(["火山岩矿物学"], in: range)
        XCTAssertEqual(negative.aline.hits, [])
        XCTAssertEqual(negative.fragments, [])
    }

    func testReviewedDomainAndBackfillStayWithinFloorWithoutGraphSweep() async throws {
        let context = ModelContext(container)
        var expected: [UUID] = []
        var excluded: [UUID] = []
        for index in 0..<8 {
            let memory = Memory(content: "编造碎片\(index)", category: "fact", profileId: index == 5 ? "other" : pid)
            memory.occurredDay = index == 3 ? "2026-09-30" : index == 6 ? nil : "2026-10-12"
            memory.reviewedAt = index == 2 ? nil : time(12)
            if index == 0 { memory.organizedAt = time(12); memory.organizedPage = "楼层/主题/航线" }
            if index == 1 { memory.organizeRejectedAt = time(12) }
            if index == 4 { memory.supersededAt = time(12) }
            context.insert(memory)
            if [0, 1, 7].contains(index) { expected.append(memory.id) } else { excluded.append(memory.id) }
        }
        try context.save()
        let fake = CatalogFakeEmbedder()
        for index in [0, 1, 7] { fake.vectors["编造碎片\(index)"] = [1, 0] }
        let snapshot = await CatalogMaterial.snapshot(profileId: pid, container: container, embedder: fake)
        XCTAssertEqual(Set(snapshot.map(\.id)), Set(expected))
        XCTAssertTrue(snapshot.contains { $0.status.contains("已整理") })
        XCTAssertTrue(snapshot.contains { $0.status == "整理时驳回" })
        XCTAssertEqual(Set(fake.calls), ["编造碎片0", "编造碎片1", "编造碎片7"])
        let fresh = try ModelContext(container).fetch(FetchDescriptor<Memory>())
        XCTAssertTrue(fresh.filter { expected.contains($0.id) }.allSatisfy { $0.embeddingRevision == 7 && $0.relatedIds.isEmpty })
        XCTAssertTrue(fresh.filter { excluded.contains($0.id) }.allSatisfy { $0.embeddingData == nil })
        let pending = await CatalogMaterial.pending(profileId: pid, container: container, wiki: WikiStore(root: root.appendingPathComponent("wiki")))
        XCTAssertEqual(pending.map(\.id), [expected[2]])
    }

    func testVectorOnlyFragmentReachesActualWriterInputAndKeepsOriginalFNumber() async throws {
        let unrelated = CatalogFragment(id: UUID(), content: "蓝石收藏盒", category: "fact", day: "2026-10-12")
        var target = CatalogFragment(id: UUID(), content: "银帆每逢周末停泊北湾", category: "fact", day: "2026-10-12")
        target.embeddingData = MemoryVector.data(from: [1, 0])
        target.embeddingRevision = 7
        let fake = CatalogFakeEmbedder()
        fake.vectors["远航安排"] = [1, 0]
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let topic = CatalogSorter.Topic(path: "楼层/主题/远航", title: "远航安排", kind: .topic, existing: false)
        let material = await CatalogWriter.material(topic, fragments: [], floorPrompt: "", wiki: wiki, memoryRoot: root, now: time(18),
                                                     snapshot: [unrelated, target, target], embedder: fake)
        var actual = ""
        let run = CatalogRunRecord(wiki: wiki, topic: "远航安排", kind: "P0 路径烟测")
        let parsed = try await CatalogWriter.write(material, names: .init(userName: "{u}", assistantName: "{c}"), wiki: wiki, caller: { _, user in
            actual = user
            return "{\"items\":[{\"type\":\"new_page\",\"path\":\"楼层/主题/远航\",\"kind\":\"主题\",\"title\":\"远航\",\"records\":[{\"text\":\"银帆周末停泊北湾\",\"fragments\":[\"f2\"]}]}]}"
        }, drafts: nil, run: run)
        let fragmentLine = try XCTUnwrap(actual.components(separatedBy: "\n").first { $0.hasPrefix("- f2 · ") })
        XCTAssertTrue(fragmentLine.hasPrefix("- f2 · 2026-10-12 · 没整理 · "))
        XCTAssertTrue(fragmentLine.hasSuffix(" · " + target.content))
        XCTAssertFalse(actual.contains("f3 ·"))
        XCTAssertEqual(parsed?.items.first?.fragmentIds, [target.id])
        XCTAssertEqual(fake.calls, ["远航安排"], "同一查询只算一次，不因重复 UUID 算两次")
        await run.flush()
        let evidence = CatalogRunRecord.searchEvidence(in: try String(contentsOf: run.url, encoding: .utf8))
        XCTAssertEqual(evidence.flatMap(\.fragments), [target.content])
        XCTAssertEqual(evidence.flatMap(\.assigned), [])
    }

    func testAssetUnavailableIsNotReportedAsVectorZeroHits() async {
        let fake = CatalogFakeEmbedder()
        fake.isReady = false
        let fragment = CatalogFragment(id: UUID(), content: "银帆停泊北湾", category: "fact", day: "2026-10-12")
        let output = await CatalogRetrieval(memoryRoot: root, fragments: [fragment], embedder: fake).search(["火山岩矿物学"])
        XCTAssertEqual(output.fragments, [])
        XCTAssertTrue(output.vectorStatus.contains("不可用"))
        XCTAssertEqual(fake.calls, [])
        XCTAssertEqual(output.receipt.evidence().searchedChars, 0)
    }

    func testReceiptCountsOnlyVisibleBodyExcludingLabelsAndAssignedMaterial() {
        var receipt = CatalogSearchReceipt(vectorStatus: "不可用")
        receipt.append("日期、标题、来源说明\n")
        receipt.appendBody("编造航线正文", kind: .aline)
        let bodyEnd = receipt.text.count
        receipt.append("\n碎片 f8\n")
        receipt.appendBody("另一段虚构正文", kind: .fragment)
        XCTAssertEqual(receipt.evidence(visibleChars: bodyEnd - 2).aline, ["编造航线"])
        XCTAssertEqual(receipt.evidence(visibleChars: bodyEnd).searchedChars, "编造航线正文".count)
        XCTAssertEqual(receipt.evidence(visibleChars: bodyEnd).fragments, [])
        XCTAssertEqual(receipt.evidence().searchedChars, "编造航线正文另一段虚构正文".count)
    }
    func testDailyActualWriterAndSearchEvidence() async throws { try await runMode("daily") }
    func testOrganizeNowActualToolFeedbackAndSearchEvidence() async throws { try await runMode("now") }
    func testNamedTopicActualToolFeedbackAndSearchEvidence() async throws { try await runMode("topic") }

    private func runMode(_ mode: String) async throws {
        let id = "valid000-window"
        try files(id)
        let context = ModelContext(container)
        context.insert(Conversation(id: id, title: "编造航行日", createTime: time(12), updateTime: time(12), currentNodeId: "", profileId: pid))
        for index in 0..<3 {
            let memory = Memory(content: "云桥城航线采用编造船帆\(index)", category: "fact", profileId: pid)
            memory.subject = "模型船配色与云桥城航线"
            memory.occurredDay = "2026-10-12"
            memory.reviewedAt = time(12)
            memory.createdAt = time(12).addingTimeInterval(Double(index))
            context.insert(memory)
        }
        try context.save()
        let submit = """
        {"items":[{"type":"new_page","path":"楼层/主题/航线","kind":"主题","title":"航线","records":[
        {"text":"云桥城每局轮流领航","fragments":["f2"],"aline":[{"layer":"A2","window":"valid000","segment":1}]}]}]}
        """
        var writerInput = ""
        let backend = FakeCatalogBackend { round, _ in
            round == 1
                ? .toolCalls([CatalogTestKit.call("search_aline", "{\"terms\":[\"模型船配色与云桥城航线\"]}")])
                : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)])
        }
        var writerCalls = 0
        let caller: SessionSegmentWriter.Caller = { _, user in
            writerCalls += 1
            writerInput = user
            return submit
        }
        let job = CatalogTestKit.job(pid: pid, root: root, container: container, caller: caller, backend: backend)
        let session = CatalogSession(job: job)
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let store = WikiProposalStore(wiki: wiki)
        var report: CatalogRunReport
        switch mode {
        case "daily":
            report = await session.daily(now: time(18))
            XCTAssertEqual(writerCalls, 0, "自动先只提方向，不搜不写")
            let direction = try XCTUnwrap(store.list().first)
            XCTAssertEqual(direction.items.first?.change.direction?.path, "楼层/主题/模型船配色与云桥城航线")
            try await WikiProposalReview.approve(direction.id, store: store, profileId: pid, context: ModelContext(container))
            report = await CatalogSession(job: job).directions(direction.id, now: time(18))
        case "now": report = await session.organizeNow(now: time(18))
        default: report = await session.organizeTopic("模型船配色与云桥城航线", now: time(18))
        }
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.proposals, 1)
        let actual = mode == "daily" ? writerInput : backend.requests.flatMap(\.toolTurns).flatMap(\.results).map(\.text).joined()
        XCTAssertTrue(actual.contains("云桥城航线每局轮流领航"))
        XCTAssertTrue(actual.contains("模型船配色改用水性颜料"))
        let proposal = try XCTUnwrap(store.list().first { $0.items.contains { $0.change.direction == nil } })
        XCTAssertEqual(proposal.items.first?.cites.first?.segment, 1)
        XCTAssertEqual(proposal.items.first?.cites.first?.messageFrom, 4)
        let folder = wiki.root.appendingPathComponent(CatalogRunRecord.folderName)
        let runs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let evidence = try runs.flatMap { CatalogRunRecord.searchEvidence(in: try String(contentsOf: $0, encoding: .utf8)) }
        XCTAssertTrue(evidence.flatMap(\.aline).contains { $0.contains("每局轮流领航") })
        XCTAssertEqual(evidence.flatMap(\.assigned).count, mode == "topic" ? 0 : 3)
        print("[P0 SMOKE] \(mode): writer received A2/A4, proposal cites A2#1 messages 4..<9; searched=\(evidence.reduce(0) { $0 + $1.searchedChars }), assigned=\(evidence.reduce(0) { $0 + $1.assignedChars })")
    }
    func testOrganizeNowContinuesAfterLiveMixedNewAndPageAssignments() async throws {
        let context = ModelContext(container)
        for index in 0..<2 {
            let start = time(12 + index)
            let id = index == 0 ? "c3movie1-smoke-window" : "c3movie2-smoke-window"
            let title = index == 0 ? "电影与诺兰" : "电影与王家卫"
            let story = index == 0
                ? "电影讨论中，测试用户说喜欢《星际穿越》和《盗梦空间》，偏爱诺兰对时间结构的处理；电影让他想起家人与承诺。"
                : "电影讨论中，测试用户说《重庆森林》的城市色彩很吸引自己，最近也开始关注王家卫，喜欢不同导演各有风格，不是放弃诺兰。"
            let segment = SessionSegment(kind: .closeout, title: title, start: start, end: start.addingTimeInterval(1800),
                                         from: 0, to: 8, lastNodeId: nil, story: story,
                                         quotes: index == 0 ? "测试用户：电影里我喜欢诺兰的时间叙事。" : "测试用户：王家卫电影的色彩也很打动我。",
                                         pending: "继续看电影并比较导演风格")
            try WindowSummaryStore.save(SessionSummary(conversationId: id, title: title, compressedCount: 0,
                                                       segments: [segment], updatedAt: start), in: root)
            try TimelineStore.seedLegacy(TimelineEntry(start: start, end: start.addingTimeInterval(1800), conversationId: id,
                                                   title: title, text: "- " + story, pending: "继续看电影", day: MemoryDay.key(start)),
                                     in: TimelineStore.dir(root: root))
            context.insert(Conversation(id: id, title: title, createTime: start, updateTime: start, currentNodeId: "", profileId: pid))
        }
        let texts = [
            "2026-10-12 电影：看完《星际穿越》，喜欢诺兰把时间和亲情交织起来的讲法。这天开始做持续更新的电影观影计划，准备跨片比较导演。",
            "2026-10-13 电影：重看《盗梦空间》，对诺兰电影中的开放式结尾很感兴趣。继续更新同一电影观影计划，把它与前一天的《星际穿越》作比较。",
            "2026-10-14 电影：看了《重庆森林》，喜欢王家卫的色彩和城市气氛。同一电影观影计划加入王家卫，下一步继续对照诺兰和王家卫。"
        ]
        var ids: [UUID] = []
        for (index, text) in texts.enumerated() {
            let memory = Memory(content: text, category: "fact", keywords: ["电影", "导演", "诺兰", "王家卫"], profileId: pid)
            memory.subject = "电影观影计划"
            memory.occurredDay = "2026-10-\(12 + index)"
            memory.importance = 3
            memory.reviewedAt = time(18)
            context.insert(memory)
            ids.append(memory.id)
        }
        try context.save()
        let submit = """
        {"items":[{"type":"new_page","path":"楼层/主题/电影观影计划","kind":"事","title":"电影观影计划","records":[
        {"text":"观影计划对照导演风格","fragments":["f1","f2","f3"],"aline":[{"layer":"A4","window":"c3movie1"}]}]}]}
        """
        let backend = FakeCatalogBackend { round, _ in
            round == 1
                ? .toolCalls([CatalogTestKit.call("search_aline", "{\"terms\":[\"电影\",\"跨片比较\"]}")])
                : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)])
        }
        var modelCalls = 0
        var job = CatalogTestKit.job(pid: pid, root: root, container: container, caller: { _, _ in
            modelCalls += 1
            return nil
        }, backend: backend)
        job.names = .init(userName: "测试用户", assistantName: "测试助手")
        job.floorPrompt = "这里只包含人工模拟数据。电影是持续变化的兴趣主题；电影、导演和看片讨论一起整理，保留日期与出处，不编造事实。"
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let eligible = await CatalogMaterial.pending(profileId: pid, container: container, wiki: wiki)
        XCTAssertEqual(eligible.map(\.id), ids)
        let report = await CatalogSession(job: job).organizeNow(now: time(18))
        let grouped = CatalogSorter.group(eligible, pages: [], blocked: [job.names.user, job.names.char])
        print("[P0 FIX1] eligible=\(eligible.count), topics=\(grouped.topics.count), agentRequests=\(backend.requests.count), proposals=\(report.proposals)")
        XCTAssertEqual(grouped.topics.map(\.path), ["楼层/主题/电影观影计划"])
        XCTAssertEqual(modelCalls, 0, "现在整理按碎片标题列主题，不再调分拣模型")
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.proposals, 1)
        XCTAssertEqual(backend.requests.count, 2)
        for text in texts { XCTAssertTrue(backend.requests.first?.history.first?.content.contains(text) == true) }
        let feedback = backend.requests.flatMap(\.toolTurns).flatMap(\.results).map(\.text).joined()
        XCTAssertTrue(feedback.contains("偏爱诺兰对时间结构的处理"))
        let proposals = WikiProposalStore(wiki: wiki).list()
        XCTAssertEqual(proposals.first?.items.first?.fragmentIds, ids)
        XCTAssertEqual(proposals.first?.items.first?.cites.first?.windowId, "c3movie1-smoke-window")
        let runPath = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: wiki.root.appendingPathComponent(CatalogRunRecord.folderName),
                                                                          includingPropertiesForKeys: nil).first)
        let evidence = CatalogRunRecord.searchEvidence(in: try String(contentsOf: runPath, encoding: .utf8))
        XCTAssertEqual(evidence.flatMap(\.assigned), texts)
        XCTAssertTrue(evidence.flatMap(\.aline).contains { $0.contains("偏爱诺兰对时间结构的处理") })
    }

    // MARK: - P2：从已留 Memory 快照到实际 C3 消费者的归因

    private func attributedSnapshot() async throws -> [CatalogFragment] {
        let rows: [(String, String?, String?)] = [
            ("雨岬钟楼使用铜色指针", "雨岬钟楼", "用户自述"),
            ("灯塔航线定为三轮领航", "灯塔航线", "用户自述"),
            ("纸鸢承诺下次陪青穗试航灯塔航线", "纸鸢与灯塔航线", "AI 承诺"),
            ("纸鸢认为灯塔航线的配色清爽", "灯塔航线配色", "AI 观察"),
            ("青穗说灯塔航线不再经过南湾", nil, nil),
        ]
        let context = ModelContext(container)
        for (index, row) in rows.enumerated() {
            let memory = Memory(content: row.0, category: "fact",
                                keywords: index == 0 ? ["钟楼"] : ["灯塔航线", "领航"], profileId: pid)
            memory.subject = row.1
            memory.speaker = row.2
            memory.occurredDay = "2026-10-12"
            memory.createdAt = time(12).addingTimeInterval(Double(index))
            memory.reviewedAt = time(12)
            context.insert(memory)
        }
        try context.save()
        let snapshot = await CatalogMaterial.snapshot(profileId: pid, container: container, embedder: CatalogFakeEmbedder.unavailable())
        let pending = await CatalogMaterial.pending(profileId: pid, container: container, wiki: WikiStore(root: root.appendingPathComponent("wiki")))
        XCTAssertEqual(snapshot, pending, "自动待分拣和手动检索都从所属 context 读取同一归因值")
        XCTAssertEqual(snapshot.map(\.content), rows.map { $0.0 })
        XCTAssertEqual(snapshot.map(\.subject), rows.map { $0.1 })
        XCTAssertEqual(snapshot.map(\.speaker), rows.map { $0.2 })
        XCTAssertEqual(snapshot.last?.keywords, ["灯塔航线", "领航"])
        return snapshot
    }

    private func assertAttributedBlock(_ text: String, snapshot: [CatalogFragment], index: Int, retrieved: Bool,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let subjects = ["雨岬钟楼", "灯塔航线", "纸鸢与灯塔航线", "灯塔航线配色", "未知"]
        let speakers = ["用户自述", "用户自述", "AI 承诺", "AI 观察", "未知"]
        let lines = text.components(separatedBy: "\n")
        let fragment = snapshot[index]
        guard let bodyIndex = lines.firstIndex(where: { $0.contains(fragment.content) && $0.contains("f\(index + 1)") }) else {
            return XCTFail("原编号及正文必须进入实际输入", file: file, line: line)
        }
        let entry = lines[bodyIndex]
        XCTAssertTrue(entry.contains(subjects[index]), "本条实际输入缺主体", file: file, line: line)
        XCTAssertTrue(entry.contains(speakers[index]), "本条实际输入缺发言归因", file: file, line: line)
        let classification = retrieved ? fragment.status : fragment.category
        XCTAssertTrue(entry.contains(fragment.day), "日期与本条归因、正文必须同行", file: file, line: line)
        XCTAssertTrue(entry.contains(classification), "状态或类别与本条归因、正文必须同行", file: file, line: line)
    }

    private var attributionSubmit: String {
        """
        {"items":[{"type":"new_page","path":"楼层/主题/灯塔航线","kind":"主题","title":"灯塔航线","records":[
          {"text":"虚构航线的约定与状态","fragments":["f2","f3","f4","f5"]}
        ]}]}
        """
    }

    func testSavedAttributionReachesActualAutomaticWriterWithOriginalLabels() async throws {
        let snapshot = try await attributedSnapshot()
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let names = MemoryExtractor.Names(userName: "青穗", assistantName: "纸鸢")

        let topic = CatalogSorter.Topic(path: "楼层/主题/灯塔航线", title: "灯塔航线", kind: .topic, existing: false)
        let assigned = [snapshot[1], snapshot[4]]
        let material = await CatalogWriter.material(topic, fragments: assigned, floorPrompt: "", wiki: wiki, memoryRoot: root,
                                                     now: time(18), snapshot: snapshot, embedder: CatalogFakeEmbedder.unavailable())
        let run = CatalogRunRecord(wiki: wiki, topic: "灯塔航线", kind: "虚构归因回归")
        var writerInput = ""
        let parsed = try await CatalogWriter.write(material, names: names, wiki: wiki, caller: { [attributionSubmit] _, user in
            writerInput = user
            return attributionSubmit
        }, drafts: nil, run: run)
        for index in [1, 4] { assertAttributedBlock(writerInput, snapshot: snapshot, index: index, retrieved: false) }
        for index in [2, 3] { assertAttributedBlock(writerInput, snapshot: snapshot, index: index, retrieved: true) }
        XCTAssertFalse(writerInput.contains("- f1 ·"), "不因归因字段把无关碎片混进来")
        XCTAssertEqual(parsed?.items.first?.fragmentIds, Array(snapshot.dropFirst()).map(\.id))
        for index in 1...4 { XCTAssertEqual(material.sources.fragments["f\(index + 1)"], snapshot[index]) }
        XCTAssertNil(material.sources.fragments["f1"])
        await run.flush()
        let evidence = CatalogRunRecord.searchEvidence(in: try String(contentsOf: run.url, encoding: .utf8))
        XCTAssertEqual(evidence.flatMap(\.assigned), assigned.map(\.content))
        XCTAssertEqual(Set(evidence.flatMap(\.fragments)), Set([snapshot[2].content, snapshot[3].content]))
        XCTAssertEqual(evidence.reduce(0) { $0 + $1.searchedChars }, snapshot[2].content.count + snapshot[3].content.count)
        XCTAssertEqual(evidence.reduce(0) { $0 + $1.assignedChars }, assigned.reduce(0) { $0 + $1.content.count })
    }

    func testSavedAttributionReachesActualAgentOpeningAndBothToolFeedbacks() async throws {
        let snapshot = try await attributedSnapshot()
        let backend = FakeCatalogBackend { [attributionSubmit] round, _ in
            if round == 1 {
                return .toolCalls([
                    CatalogTestKit.call("search_fragments", "{\"terms\":[\"灯塔航线\"]}", id: "targeted"),
                    CatalogTestKit.call("search_aline", "{\"terms\":[\"灯塔航线\"],\"before\":\"2026-10-18\"}", id: "broad"),
                ])
            }
            return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, attributionSubmit)])
        }
        let agent = CatalogAgent(deps: .init(makeBackend: { backend }, gate: { _ in nil }))
        let outcome = await agent.run(.init(topic: "灯塔航线", fragmentIds: [snapshot[1].id, snapshot[4].id], profileId: pid,
                                            memoryRoot: root, names: .init(userName: "青穗", assistantName: "纸鸢"),
                                            floorPrompt: "", snapshot: snapshot, modelName: "虚构后端", maxRounds: 3,
                                            embedder: CatalogFakeEmbedder.unavailable()))
        XCTAssertEqual(outcome.stop, .submitted)
        XCTAssertEqual(backend.requests.count, 2)
        let opening = try XCTUnwrap(backend.requests.first?.history.first?.content)
        for index in [1, 4] { assertAttributedBlock(opening, snapshot: snapshot, index: index, retrieved: false) }
        XCTAssertFalse(opening.contains("- f3 ·"), "未分配的承诺只在实际追搜后出现")
        let feedbacks = try XCTUnwrap(backend.requests.last?.toolTurns.first?.results)
        XCTAssertEqual(feedbacks.map(\.toolUseId), ["targeted", "broad"])
        for feedback in feedbacks {
            XCTAssertFalse(feedback.isError)
            for index in 1...4 { assertAttributedBlock(feedback.text, snapshot: snapshot, index: index, retrieved: true) }
            XCTAssertFalse(feedback.text.contains("- f1 ·"))
        }
        XCTAssertEqual(outcome.items.first?.fragmentIds, Array(snapshot.dropFirst()).map(\.id))
        XCTAssertEqual(outcome.searchedChars, 2 * snapshot.dropFirst().reduce(0) { $0 + $1.content.count })
    }

    func testAttributionMetadataStaysOutsideSearchBodyBudgetAndSourceIntervals() async throws {
        let context = ModelContext(container)
        let memory = Memory(content: "灯塔航线" + String(repeating: "虚构海图", count: 45), category: "fact", profileId: pid)
        memory.subject = String(repeating: "虚构主体", count: 2000)
        memory.speaker = "AI 承诺"
        memory.occurredDay = "2026-10-12"
        memory.reviewedAt = time(12)
        context.insert(memory)
        try context.save()
        let snapshot = await CatalogMaterial.snapshot(profileId: pid, container: container, embedder: CatalogFakeEmbedder.unavailable())
        let fragment = try XCTUnwrap(snapshot.first)
        let tools = CatalogAgentTools(wiki: WikiStore(root: root.appendingPathComponent("wiki")), memoryRoot: root,
                                      fragments: snapshot, embedder: CatalogFakeEmbedder.unavailable())
        for name in ["search_fragments", "search_aline"] {
            let output = await tools.execute(name: name, argumentsJSON: "{\"terms\":[\"灯塔航线\"],\"before\":\"2026-10-18\"}", now: time(18))
            let receipt = try XCTUnwrap(output.receipt)
            XCTAssertGreaterThan(receipt.text.count, CatalogRetrieval.Limits.chars, "归因元数据不消耗 6000 字正文预算")
            XCTAssertTrue(receipt.text.contains(fragment.attributionText))
            XCTAssertTrue(receipt.text.contains("- f1 · 2026-10-12 · 没整理 · \(fragment.attributionText) · " + fragment.content))
            XCTAssertEqual(receipt.evidence().fragments, [fragment.content])
            XCTAssertEqual(receipt.bodyChars, fragment.content.count)
            let bodyStart = try XCTUnwrap(receipt.bodies.first?.range.lowerBound)
            XCTAssertTrue(receipt.prefix(bodyStart).text.contains(try XCTUnwrap(fragment.subject)), "主体必须位于正文区间前")
            XCTAssertTrue(receipt.prefix(bodyStart).text.contains(try XCTUnwrap(fragment.speaker)), "发言归因必须位于正文区间前")
            var hiddenSources = CatalogSources()
            receipt.prefix(bodyStart).register(in: &hiddenSources)
            XCTAssertTrue(hiddenSources.fragments.isEmpty, "只见元数据时不能登记正文出处")
            XCTAssertEqual(receipt.prefix(bodyStart).evidence().searchedChars, 0)
            let clipped = receipt.bodyPrefix(7)
            XCTAssertTrue(clipped.text.contains(fragment.attributionText), "正文截断不能先丢归因")
            XCTAssertEqual(clipped.evidence().fragments, [String(fragment.content.prefix(7))])
            var clippedSources = CatalogSources()
            clipped.register(in: &clippedSources)
            XCTAssertTrue(clippedSources.fragments.isEmpty, "正文只出现半截，整条不登记")
            var visibleSources = CatalogSources()
            receipt.register(in: &visibleSources)
            XCTAssertEqual(visibleSources.fragments["f1"]?.id, fragment.id)
            XCTAssertEqual(visibleSources.fragments["f1"]?.content, fragment.content, "完整看到正文后仍按 P1 登记原碎片快照")
            XCTAssertEqual(visibleSources.fragments["f1"]?.subject, fragment.subject)
            XCTAssertEqual(visibleSources.fragments["f1"]?.speaker, fragment.speaker)
        }
    }
}
