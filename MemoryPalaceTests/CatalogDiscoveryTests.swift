import XCTest
import SwiftData
@testable import 记忆花园

/// C2/C3 v2 第 8b 段 · 自动发现的另外几路线索：A4 时间轴连续出现的新话题（两种分拣都接）、页上 valid_until 到期复核、
/// 人设变化只手动、A4-only 方向批了就开页；没有新碎片照样看，A4 没准备好不挡别的。夹具全是虚构
@MainActor
final class CatalogDiscoveryTests: XCTestCase {

    private let pid = "xctest-catalog-discovery"
    private let names = MemoryExtractor.Names(userName: "小鹿", assistantName: "星砚")
    private var root: URL!
    private var wiki: WikiStore!
    private var store: WikiProposalStore!
    private var container: ModelContainer!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-discovery-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - 夹具

    private func at(_ day: Int, month: Int = 10, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    /// A4 一天一条：主调写成了（headline 非空）才算；kind = 这天那一项是 A2 段还是没压缩的
    private func a4(_ day: Int, _ topics: [String], month: Int = 10, headline: String? = "过得挺满",
                    kind: TimelineDayRecord.Item.Kind = .segment) throws {
        let start = at(day, month: month, hour: 15)
        let item = TimelineDayRecord.Item(kind: kind, conversationId: "conv-\(month)-\(day)", window: "窗口", title: "一段", start: start,
                                          end: start.addingTimeInterval(600), from: nil, to: nil)
        try save(TimelineDayRecord(date: MemoryDay.key(start), headline: headline, topics: topics, items: [item]))
    }

    private func save(_ record: TimelineDayRecord) throws {
        try TimelineStore.mutateMonth(String(record.date.prefix(7)), in: TimelineStore.dir(root: root)) { m in
            m.days.removeAll { $0.date == record.date }
            m.days.append(record)
            m.days.sort { $0.date < $1.date }
        }
    }

    private func logs(_ text: String) -> Int {
        MemoryWriteLog.flush()
        return MemoryWriteLog.entries(profileId: pid).filter { $0.note.contains(text) }.count
    }

    @discardableResult
    private func fragment(_ content: String, subject: String?, tags: [String] = [], day: Int = 12) throws -> Memory {
        let ctx = ModelContext(container)
        let m = Memory(content: content, category: "fact", keywords: tags, profileId: pid)
        m.subject = subject
        m.occurredDay = "2026-10-\(day)"
        m.createdAt = Date(timeIntervalSince1970: 1_800_000_000 + Double(day))
        m.reviewedAt = Date()
        ctx.insert(m)
        try ctx.save()
        return m
    }

    private func job(sorter: CatalogSettings.Sorter = .code, caller: @escaping SessionSegmentWriter.Caller = { _, _ in nil },
                     backend: FakeCatalogBackend? = nil) -> CatalogJob {
        var j = CatalogTestKit.job(pid: pid, root: root, container: container, caller: caller, backend: backend)
        j.names = names
        j.sorter = sorter
        return j
    }

    private func directions() -> [WikiProposal.Direction] {
        store.list().flatMap { $0.items.compactMap(\.change.direction) }
    }

    private func directionProposal(_ path: String) throws -> WikiProposal {
        try XCTUnwrap(store.list().first { $0.items.contains { $0.change.direction?.path == path } })
    }

    private func approve(_ id: String) async throws {
        try await WikiProposalReview.approve(id, store: store, profileId: pid, context: ModelContext(container))
    }

    private func contentProposals() -> [WikiProposal] {
        store.list().filter { !$0.items.contains { $0.change.direction != nil } }
    }

    // MARK: - 时间轴 · 代码基线

    func testNoNewFragmentsButATopicOnTwoDaysStillProposesAConcreteDirection() async throws {
        try a4(20, ["毕设", "搬家"])
        try a4(21, ["毕设进度", "毕设"])
        try a4(22, ["看电影"])
        var calls = 0
        let backend = FakeCatalogBackend { _, _ in .failed("自动不该调 agent") }
        let j = job(caller: { _, _ in
            calls += 1
            return nil
        }, backend: backend)

        let report = await CatalogSession(job: j).daily(now: at(22))

        XCTAssertEqual(calls, 0, "代码基线：自动发现全程零模型调用")
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(report.proposals, 1, report.summary)
        let ds = directions()
        XCTAssertEqual(ds.map(\.path), ["楼层/主题/毕设"], "只出现一天的（搬家 / 毕设进度 / 看电影）不提")
        let d = try XCTUnwrap(ds.first)
        XCTAssertEqual(d.action, .newPage)
        XCTAssertEqual(d.mode, .daily)
        XCTAssertTrue(d.clues.isEmpty, "只来自时间轴，没有碎片线索")
        XCTAssertFalse(d.basis?.isEmpty ?? true)
        XCTAssertTrue(d.reason.contains("10-20") && d.reason.contains("10-21"), "理由写明哪两天：\(d.reason)")
    }

    func testTopicOnOneDayOrOnDaysWithAGapIsNotProposed() async throws {
        try a4(18, ["潜水"])
        try a4(20, ["潜水"])
        try a4(22, ["潜水", "陶艺"])

        let report = await CatalogSession(job: job()).daily(now: at(22))

        XCTAssertTrue(directions().isEmpty)
        XCTAssertNotNil(report.skipped, report.summary)
    }

    func testTopicThatLiterallyHitsAnExistingPageIsNotProposed() async throws {
        try wiki.save(WikiPage(path: "楼层/项目/毕业设计", kind: .project, triggers: ["毕设"], hook: "", title: "毕业设计"))
        try wiki.save(WikiPage(path: "楼层/人/饼干", kind: .person, triggers: [], hook: "", title: "饼干"))
        try a4(21, ["毕设", "饼干体检", "陶艺展"])
        try a4(22, ["毕设", "饼干体检", "陶艺展"])

        _ = await CatalogSession(job: job()).daily(now: at(22))

        XCTAssertEqual(directions().map(\.path), ["楼层/主题/陶艺展"], "触发词 / 标题字面对上已有页的不提")
    }

    /// 一段 A2 从 21 号晚上聊到 22 号白天：两天都有消息，A4 两天各一条（后一天标接前一天），两天的话题都算
    func testOneSegmentAcrossTwoDaysWithMessagesOnBothCountsAsTwoDays() async throws {
        let times = [at(21, hour: 21), at(21, hour: 23), at(22, hour: 9), at(22, hour: 10)]
        let messages = times.enumerated().map { TimelineSkeleton.Message(id: "m\($0.offset)", date: $0.element) }
        let seg = SessionSegment(kind: .rolling, title: "夜跑路线", start: times[0], end: times[3], from: 0, to: 4, lastNodeId: "m3",
                                 story: "", quotes: "", pending: "", isTail: false)
        let w = TimelineSkeleton.Window(conversationId: "conv-run", title: "夜跑", messages: messages,
                                        summary: SessionSummary(conversationId: "conv-run", title: "夜跑", compressedCount: 4, segments: [seg], updatedAt: Date()))
        let built = TimelineSkeleton.build([w], days: ["2026-10-21", "2026-10-22"])
        XCTAssertEqual(built["2026-10-22"]?.items.first?.continued, true, "夹具：后一天确实标了接前一天")
        for date in ["2026-10-21", "2026-10-22"] {
            try save(TimelineDayRecord(date: date, headline: "夜跑", topics: ["夜跑"], items: built[date]!.items))
        }

        _ = await CatalogSession(job: job()).daily(now: at(22))

        XCTAssertEqual(directions().map(\.path), ["楼层/主题/夜跑"], "按有消息的记忆日算连续，不因为接前一天就整天不算")
    }

    func testSameRunIsProposedOnceAndAgainOnlyAfterABreak() async throws {
        try a4(20, ["毕设"])
        try a4(21, ["毕设"])
        let j = job()
        _ = await CatalogSession(job: j).daily(now: at(21))
        _ = await CatalogSession(job: j).daily(now: at(21))
        XCTAssertEqual(directions().count, 1, "待批的方向不重复提")

        let first = try directionProposal("楼层/主题/毕设")
        try await WikiProposalReview.reject(first.id, store: store, context: ModelContext(container))
        try a4(22, ["毕设"])
        _ = await CatalogSession(job: j).daily(now: at(22))
        XCTAssertEqual(directions().count, 1, "驳回之后同一段连续往后延，不再提")

        try a4(25, ["毕设"])
        try a4(26, ["毕设"])
        _ = await CatalogSession(job: j).daily(now: at(26))
        let ds = directions()
        XCTAssertEqual(ds.count, 2, "断过之后又连续出现，再提一次")
        XCTAssertTrue(ds.contains { $0.reason.contains("10-25") && $0.reason.contains("10-26") })
    }

    func testTooFewFragmentsLeaveTheTopicToTheTimeline() async throws {
        try a4(21, ["毕设"])
        try a4(22, ["毕设"])
        let two = try (12...13).map { try fragment("毕设第\($0)天", subject: "毕设", day: $0).id }

        _ = await CatalogSession(job: job()).daily(now: at(22))

        let ds = directions()
        XCTAssertEqual(ds.count, 1)
        XCTAssertTrue(ds[0].clues.isEmpty, "碎片还没凑够 3 条：普通开页不提，只来自时间轴的照样提")
        XCTAssertFalse(ds[0].clues.contains(where: two.contains))
    }

    func testFragmentsAlreadyOpeningTheTopicWin() async throws {
        try a4(21, ["毕设"])
        try a4(22, ["毕设"])
        let three = try (12...14).map { try fragment("毕设第\($0)天", subject: "毕设", day: $0).id }

        _ = await CatalogSession(job: job()).daily(now: at(22))

        let ds = directions()
        XCTAssertEqual(ds.count, 1, "碎片分拣这轮已经提了这个主题：时间轴不再另提一条")
        XCTAssertEqual(Set(ds[0].clues), Set(three))
        XCTAssertNil(ds[0].basis)
    }

    func testA4OnlyDirectionApprovedOpensAPageWithoutThreeFragments() async throws {
        try a4(21, ["陶艺展"])
        try a4(22, ["陶艺展"])
        var users: [String] = []
        let j = job(caller: { _, user in
            users.append(user)
            return """
            {"items":[{"type":"new_page","path":"楼层/主题/陶艺展","kind":"主题","title":"陶艺展","hook":"当小鹿说起陶艺展时先看这页","now":"在准备成都的陶艺展（时间未注明）。"}]}
            """
        })
        _ = await CatalogSession(job: j).daily(now: at(22))
        let direction = try directionProposal("楼层/主题/陶艺展")
        XCTAssertTrue(users.isEmpty)

        try await approve(direction.id)
        let run = await CatalogSession(job: j).directions(direction.id, now: at(22))

        XCTAssertEqual(users.count, 1, "批了才查原料、写一次")
        XCTAssertTrue(users[0].contains("【为什么提这个方向】") && users[0].contains("陶艺展"), "写手知道这是时间轴提的")
        XCTAssertEqual(run.proposals, 1, run.summary)
        let content = try XCTUnwrap(contentProposals().first)
        XCTAssertTrue(content.items.contains { $0.change.isNewPage }, "A4-only 批了就算点名开页：没有碎片也照交新开页")
        XCTAssertFalse(wiki.pageExists("楼层/主题/陶艺展"), "正文没批，wiki 不变")

        try await approve(content.id)
        XCTAssertTrue(wiki.pageExists("楼层/主题/陶艺展"))
    }

    func testOrdinaryAutomaticNewPagesStillNeedThreeFragments() async throws {
        try (12...13).forEach { try fragment("陶艺第\($0)次", subject: "陶艺", day: $0) }
        _ = await CatalogSession(job: job()).daily(now: at(22))
        XCTAssertTrue(directions().isEmpty, "没有时间轴，两条碎片不开页")
    }

    // MARK: - A4 没准备好不挡别的

    func testUnreadableTimelineDoesNotBlockFragmentsOrExpiry() async throws {
        try FileManager.default.createDirectory(at: TimelineStore.dir(root: root).appendingPathComponent("2026-10.md", isDirectory: true),
                                                withIntermediateDirectories: true)
        try wiki.save(WikiPage(path: "楼层/项目/毕设", kind: .project, triggers: [], hook: "", title: "毕设",
                               now: "交互装置，开题答辩（到 2026-10-20）。", validUntil: "2026-10-20"))
        try (12...14).forEach { try fragment("纸帆船第\($0)次", subject: "纸帆船", day: $0) }

        let report = await CatalogSession(job: job()).daily(now: at(22))

        XCTAssertEqual(Set(directions().map(\.path)), ["楼层/主题/纸帆船", "楼层/项目/毕设"], report.summary)
        MemoryWriteLog.flush()
        XCTAssertTrue(MemoryWriteLog.entries(profileId: pid).contains { !$0.ok && $0.note.contains("没准备好") }, "记下 A4 这一路没准备好")
    }

    /// 主调是 nil 分三种：今天还没到时候、这天没有 A2 标题（只有没压缩的）都不算失败；过了的日子有 A2 标题却没主调才记，状态没变不再记
    func testOnlyRealHeadlineFailuresAreLoggedAndOnlyWhenTheyChange() async throws {
        try a4(20, ["毕设"])
        try a4(21, ["毕设"], headline: nil)
        try a4(19, ["散步"], headline: nil, kind: .uncompressed)
        try a4(22, ["毕设"], headline: nil)
        let j = job()

        _ = await CatalogSession(job: j).daily(now: at(22))
        _ = await CatalogSession(job: j).daily(now: at(22))

        XCTAssertTrue(directions().isEmpty, "没写成主调的日子话题不算：20 号单独一天")
        XCTAssertEqual(logs("主调却没写成"), 1, "同一状态只记一次")
        MemoryWriteLog.flush()
        let notes = MemoryWriteLog.entries(profileId: pid).map(\.note).filter { $0.contains("主调却没写成") }
        XCTAssertTrue(notes.allSatisfy { $0.contains("2026-10-21") && !$0.contains("2026-10-19") && !$0.contains("2026-10-22") }, "\(notes)")

        try a4(19, ["散步"], headline: nil, kind: .segment)
        _ = await CatalogSession(job: j).daily(now: at(22))
        XCTAssertEqual(logs("主调却没写成"), 2, "状态变了再记一次")
    }

    /// 十天没打开、或旧日主调今天才补写成：那段连续早就不在最近几天里，照样看到
    func testDayBackfilledTenDaysLaterIsStillSeen() async throws {
        try a4(10, ["潜水"])
        try a4(11, ["潜水"], headline: nil)
        let j = job()
        _ = await CatalogSession(job: j).daily(now: at(12))
        XCTAssertTrue(directions().isEmpty)

        try a4(11, ["潜水"])
        _ = await CatalogSession(job: j).daily(now: at(22))

        let d = try XCTUnwrap(directions().first)
        XCTAssertEqual(d.path, "楼层/主题/潜水")
        XCTAssertTrue(d.reason.contains("10-10") && d.reason.contains("10-11"), d.reason)
    }

    /// 天天都在聊的话题（超过 30 天）：同一段连续只提一次，驳回后往后延也不再提；来源身份按完整历史的起始日
    func testTopicRunningOverThirtyDaysIsProposedOnlyOnce() async throws {
        for day in 10...30 { try a4(day, ["工作"], month: 9) }
        for day in 1...20 { try a4(day, ["工作"]) }
        let j = job()
        _ = await CatalogSession(job: j).daily(now: at(20))
        _ = await CatalogSession(job: j).daily(now: at(20))
        XCTAssertEqual(directions().count, 1, "一次最多看一批日子，看不完的下次看；同一段只提一条")
        let first = try directionProposal("楼层/主题/工作")
        XCTAssertEqual(first.items.first?.change.direction?.basis, ["A4「工作」自 2026-09-10 起连续"])
        try await WikiProposalReview.reject(first.id, store: store, context: ModelContext(container))

        for day in 21...22 { try a4(day, ["工作"]) }
        _ = await CatalogSession(job: j).daily(now: at(22))
        XCTAssertEqual(directions().count, 1, "驳回之后同一段往后延：起始日没变，不再提")
    }

    // MARK: - valid_until 到期复核

    func testExpiredPageProposesReviewOnceAndUnknownDeadlinesStayQuiet() async throws {
        try wiki.save(WikiPage(path: "楼层/项目/毕设", kind: .project, triggers: [], hook: "", title: "毕设",
                               now: "交互装置，开题答辩（到 2026-10-20）。", validUntil: "2026-10-20"))
        try wiki.save(WikiPage(path: "楼层/主题/日语", kind: .topic, triggers: [], hook: "", title: "日语",
                               now: "报了 12 月考试（到 2026-12-01）。", validUntil: "2026-12-01"))
        try wiki.save(WikiPage(path: "楼层/人/饼干", kind: .person, triggers: [], hook: "", title: "饼干", now: "体检约在（到 2026-10-01）。"))
        let before = wiki.versionSnapshot()
        var users: [String] = []
        let j = job(caller: { _, user in
            users.append(user)
            return """
            {"items":[{"type":"rewrite_now","path":"楼层/项目/毕设","now":"交互装置，开题答辩过了，中期检查（到 2026-11-30）。","valid_until":"2026-11-30"}]}
            """
        })

        _ = await CatalogSession(job: j).daily(now: at(22))
        _ = await CatalogSession(job: j).daily(now: at(22))

        XCTAssertTrue(users.isEmpty, "自动发现零模型调用")
        let ds = directions()
        XCTAssertEqual(ds.map(\.path), ["楼层/项目/毕设"], "旧页没有期限的不猜（正文里写了也不算）；没到期的不提；待批的不重复提")
        XCTAssertEqual(ds[0].action, .update)
        XCTAssertTrue(ds[0].reason.contains("2026-10-20"), ds[0].reason)
        XCTAssertEqual(wiki.versionSnapshot(), before, "只提复核，不删、不改")

        let direction = try directionProposal("楼层/项目/毕设")
        try await approve(direction.id)
        _ = await CatalogSession(job: j).directions(direction.id, now: at(22))
        XCTAssertEqual(users.count, 1)
        XCTAssertTrue(users[0].contains("2026-10-20"), "写手知道是到期复核")
        XCTAssertEqual(wiki.versionSnapshot(), before, "正文没批，wiki 不变")

        let content = try XCTUnwrap(contentProposals().first)
        try await approve(content.id)
        XCTAssertEqual(wiki.read("楼层/项目/毕设")?.validUntil, "2026-11-30")

        _ = await CatalogSession(job: j).daily(now: at(22))
        XCTAssertEqual(directions().count, 1, "新期限没到：不再提")
        _ = await CatalogSession(job: j).daily(now: at(2, month: 12))
        XCTAssertTrue(directions().contains { $0.reason.contains("2026-11-30") }, "新期限过了再提")
    }

    func testValidUntilFollowsTheDeadlineWrittenInNowAndRoundTrips() throws {
        var page = WikiPage(path: "楼层/项目/毕设", kind: .project, triggers: ["毕设"], hook: "", title: "毕设",
                            now: "中期检查（到 2026-11-30）。", validUntil: "2026-11-30")
        XCTAssertEqual(WikiPage.parse(page.markdown, path: page.path), page, "序列化往返")
        page.validUntil = nil
        XCTAssertNil(WikiPage.parse(page.markdown, path: page.path).validUntil, "旧页没有这个字段 = nil，读的时候不从正文猜")
        let handwritten = "---\n类: 项目\n触发词: []\n钩子: \n有效到: 下周\n---\n# 毕设\n\n## 现在\n中期检查。\n"
        let parsed = WikiPage.parse(handwritten, path: page.path)
        XCTAssertNil(parsed.validUntil)
        XCTAssertTrue(parsed.markdown.contains("有效到: 下周"), "没有替换的时候，认不出的手写值原样留着")

        try wiki.save(WikiPage(path: "楼层/项目/毕设", kind: .project, triggers: [], hook: "", title: "毕设", now: "开题。"))
        var sources = CatalogSources()
        sources.versions["楼层/项目/毕设"] = wiki.version(of: "楼层/项目/毕设")
        let json = """
        {"items":[{"type":"rewrite_now","path":"楼层/项目/毕设","now":"中期检查（到 2026-11-30）。","valid_until":"2026-12-31"},
        {"type":"new_page","path":"楼层/主题/日语","kind":"主题","title":"日语","now":"报了考试（到 2026-12-01），听力课（到 2026-11-15）。"}]}
        """
        let got = try XCTUnwrap(CatalogItems.parse(json, sources: sources, wiki: wiki))
        guard case .rewriteNow(_, _, _, let until) = got.items[0].change else { return XCTFail() }
        XCTAssertEqual(until, "2026-11-30", "写手给的不是正文里的到期日：按正文定")
        XCTAssertTrue(got.unapplied.contains { $0.reason.contains("valid_until") }, "对不上的原样留给她看")
        guard case .newPage(let new) = got.items[1].change else { return XCTFail() }
        XCTAssertEqual(new.validUntil, "2026-11-15", "写手漏填：按正文里最早的到期日")

        try wiki.save(new)
        try wiki.rebuildIndexes(affecting: [new.path])
        XCTAssertTrue(wiki.layerLines("楼层/主题").contains { $0.contains("2026-11-15") }, "代码生成的索引带上期限")
    }

    /// 写手漏填 valid_until：新正文还写着「到 某天」，期限就还在；只改期限、正文没变也算有变化；审计台手改日期也照正文走
    func testOmittedOrHandEditedDeadlineFollowsTheText() async throws {
        try wiki.save(WikiPage(path: "楼层/项目/毕设", kind: .project, triggers: [], hook: "", title: "毕设",
                               now: "中期检查（到 2026-11-30）。", validUntil: "2026-11-30"))
        try wiki.save(WikiPage(path: "楼层/项目/作品集", kind: .project, triggers: [], hook: "", title: "作品集", now: "投递截止（到 2026-12-20）。"))
        var sources = CatalogSources()
        sources.versions = wiki.versionSnapshot()
        let json = """
        {"items":[{"type":"rewrite_now","path":"楼层/项目/毕设","now":"中期检查（到 2026-11-30），导师要求加用户测试。"},
        {"type":"rewrite_now","path":"楼层/项目/作品集","now":"投递截止（到 2026-12-20）。"}]}
        """
        let got = try XCTUnwrap(CatalogItems.parse(json, sources: sources, wiki: wiki))
        XCTAssertEqual(got.items.count, 2, "作品集：正文没变、期限从无到有，也算有变化")
        let p = WikiProposal(origin: .scheduled, createdAt: at(22), items: got.items)
        try store.save(p)

        let item = p.items[0]
        var draft = WikiProposalDraft(item.change)
        draft.now = "中期检查（到 2026-12-15），导师要求加用户测试。"
        try store.edit(p.id, itemId: item.id, change: draft.apply(to: item.change), judgment: nil)
        try await approve(p.id)

        XCTAssertEqual(wiki.read("楼层/项目/毕设")?.validUntil, "2026-12-15", "审计台改了日期：期限跟着正文")
        XCTAssertEqual(wiki.read("楼层/项目/作品集")?.validUntil, "2026-12-20")
    }

    /// 页上原来手写了认不出的「有效到: 下周」：批了新期限以后只有新的那个生效，原写法换个键名留着
    func testInvalidHandwrittenDeadlineIsReplacedNotWinning() async throws {
        try wiki.saveRaw("---\n类: 项目\n触发词: []\n钩子: \n有效到: 下周\n---\n# 毕设\n\n## 现在\n中期检查。\n", path: "楼层/项目/毕设")
        let item = WikiProposal.Item(change: .rewriteNow(path: "楼层/项目/毕设", old: "中期检查。", new: "中期检查（到 2026-11-30）。", until: "2026-11-30"),
                                     baseVersion: wiki.version(of: "楼层/项目/毕设"))
        let p = WikiProposal(origin: .scheduled, createdAt: at(22), items: [item])
        try store.save(p)
        try await approve(p.id)

        let raw = try XCTUnwrap(wiki.readRaw("楼层/项目/毕设"))
        XCTAssertEqual(wiki.read("楼层/项目/毕设")?.validUntil, "2026-11-30")
        XCTAssertEqual(raw.components(separatedBy: "\n").filter { WikiPage.metaKey($0) == WikiPage.validUntilKey }.count, 1, raw)
        XCTAssertTrue(raw.contains("下周"), "被换掉的手写原文还在，只是不参与解析")
    }

    /// 驳回了到期复核、页没改：提案满 30 天清掉以后，同一页同一个期限也不再提
    func testHandledExpirySurvivesProposalPurge() async throws {
        try wiki.save(WikiPage(path: "楼层/项目/毕设", kind: .project, triggers: [], hook: "", title: "毕设",
                               now: "开题答辩（到 2026-10-20）。", validUntil: "2026-10-20"))
        let j = job()
        _ = await CatalogSession(job: j).daily(now: at(22))
        let first = try directionProposal("楼层/项目/毕设")
        try await WikiProposalReview.reject(first.id, store: store, context: ModelContext(container), now: at(22))

        _ = await CatalogSession(job: j).daily(now: at(30, month: 12))

        XCTAssertNil(store.load(first.id), "夹具：旧提案已经清掉")
        XCTAssertTrue(directions().isEmpty, "已处理的来源身份另存着，不跟着提案丢")
    }

    // MARK: - 人设变化：只手动

    func testPersonaChangeRunsOnlyWhenSheAsks() async throws {
        try wiki.save(WikiPage(path: "楼层/小鹿/身体", kind: .user, triggers: [], hook: "", title: "身体", now: "近视 500 度。"))
        let before = wiki.versionSnapshot()
        let backend = FakeCatalogBackend { n, _ in
            n == 1 ? .toolCalls([CatalogTestKit.call("read_wiki", "{\"path\":\"楼层/小鹿/身体\"}")])
                : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, """
                {"items":[{"type":"rewrite_now","path":"楼层/小鹿/身体","now":"做了近视手术（详见人设）。"}]}
                """)])
        }
        let j = job(backend: backend)

        _ = await CatalogSession(job: j).daily(now: at(22))
        XCTAssertTrue(backend.requests.isEmpty, "不监听人设：自动那次不碰")

        let report = await CatalogSession(job: j).personaChanged(now: at(22))

        XCTAssertFalse(backend.requests.isEmpty, "她点了才跑")
        XCTAssertTrue(backend.requests[0].history[0].content.contains("刚改过人设"))
        XCTAssertEqual(report.proposals, 1, report.summary)
        let p = try XCTUnwrap(store.list().first)
        XCTAssertNil(p.items.first { $0.change.direction != nil }, "手动请求本身就是方向授权，不再出方向等批")
        XCTAssertEqual(p.origin, .manual)
        XCTAssertEqual(p.request?.text, CatalogSession.personaRequest)
        XCTAssertEqual(wiki.versionSnapshot(), before, "正文没批，wiki 不变")
    }

    // MARK: - 时间轴 · 模型分拣

    func testModelSorterReadsTopicsAndItsTimelineProposalsBecomeDirections() async throws {
        try a4(21, ["毕设"])
        try a4(22, ["毕设", "搬家"])
        var users: [String] = []
        let j = job(sorter: .model, caller: { _, user in
            users.append(user)
            return users.count == 1
                ? #"{"fragments":[],"timeline_proposals":[{"kind":"宠物","title":"毕设","path":"楼层/项目/毕设","days":["2026-10-21","2026-10-22"]}]}"#
                : #"{"fragments":[],"timeline_proposals":[{"kind":"项目","title":"毕设","path":"楼层/项目/毕设","days":["2026-10-21","2026-10-22"],"reason":"连续两天在赶"}]}"#
        })

        _ = await CatalogSession(job: j).daily(now: at(22))

        XCTAssertEqual(users.count, 2, "不合格给一次重写")
        XCTAssertTrue(users[0].contains("2026-10-21 · 话题：毕设") && users[0].contains("搬家"), "A4 时间轴那一栏是每天的话题")
        XCTAssertTrue(users[1].contains("timeline_proposals[0]"), "重写回灌原因")
        let d = try XCTUnwrap(directions().first)
        XCTAssertEqual(d.path, "楼层/项目/毕设")
        XCTAssertEqual(d.kind, .project)
        XCTAssertEqual(d.action, .newPage)
        XCTAssertTrue(d.clues.isEmpty)
        XCTAssertEqual(d.basis, ["A4「毕设」自 2026-10-21 起连续"], "和代码基线同一种来源身份")
        XCTAssertTrue(d.reason.hasPrefix("模型") && d.reason.contains("连续两天在赶"), d.reason)
    }

    /// 模型的时间轴提案按来源去重：同一来源换个路径也不再提；断开后新的连续段可以再提
    func testModelTimelineDedupesBySourceNotPath() async throws {
        try a4(20, ["毕设"])
        try a4(21, ["毕设"])
        var reply = #"{"fragments":[],"timeline_proposals":[{"kind":"项目","title":"毕设","path":"楼层/项目/毕设","days":["2026-10-20","2026-10-21"]}]}"#
        var calls = 0
        let j = job(sorter: .model, caller: { _, _ in
            calls += 1
            return reply
        })
        _ = await CatalogSession(job: j).daily(now: at(21))
        let first = try directionProposal("楼层/项目/毕设")
        try await WikiProposalReview.reject(first.id, store: store, context: ModelContext(container))

        try a4(22, ["毕设"])
        reply = #"{"fragments":[],"timeline_proposals":[{"kind":"主题","title":"毕设","path":"楼层/主题/毕设","days":["2026-10-21","2026-10-22"]}]}"#
        _ = await CatalogSession(job: j).daily(now: at(22))
        XCTAssertEqual(directions().count, 1, "同一段连续换个路径也算同一来源")

        try a4(25, ["毕设"])
        try a4(26, ["毕设"])
        reply = #"{"fragments":[],"timeline_proposals":[{"kind":"项目","title":"毕设","path":"楼层/项目/毕设","days":["2026-10-25","2026-10-26"]}]}"#
        _ = await CatalogSession(job: j).daily(now: at(26))
        XCTAssertEqual(directions().count, 2, "断开后新的连续段是新来源，可以再提")
        XCTAssertEqual(calls, 3)
    }

    /// 模型把同一个主题放到两个目标（碎片开新页 + 时间轴另开一页）：回灌一次让它统一，算在那一次重写里
    func testModelUsingTwoTargetsForOneTopicIsAskedToUnifyOnce() async throws {
        try a4(21, ["毕设"])
        try a4(22, ["毕设"])
        try (12...14).forEach { try fragment("毕设第\($0)天", subject: "毕设", day: $0) }
        let new = #"{"kind":"项目","title":"毕设","path":"楼层/项目/毕设"}"#
        let fragments = (1...3).map { #"{"f":"f\#($0)","new":\#(new)}"# }.joined(separator: ",")
        var users: [String] = []
        let j = job(sorter: .model, caller: { _, user in
            users.append(user)
            let timeline = users.count == 1
                ? #"[{"kind":"主题","title":"毕设","path":"楼层/主题/毕设","days":["2026-10-21","2026-10-22"]}]"#
                : #"[{"kind":"项目","title":"毕设","path":"楼层/项目/毕设","days":["2026-10-21","2026-10-22"]}]"#
            return #"{"fragments":[\#(fragments)],"timeline_proposals":\#(timeline)}"#
        })

        _ = await CatalogSession(job: j).daily(now: at(22))

        XCTAssertEqual(users.count, 2)
        XCTAssertTrue(users[1].contains("不止一个目标"), "回灌：同一个主题统一成一个目标")
        XCTAssertEqual(directions().map(\.path), ["楼层/项目/毕设"], "统一以后只剩一条方向")
    }

    func testModelSorterIsNotCalledWithoutFragmentsOrTimeline() async throws {
        var calls = 0
        _ = await CatalogSession(job: job(sorter: .model, caller: { _, _ in
            calls += 1
            return nil
        })).daily(now: at(22))
        XCTAssertEqual(calls, 0)
    }

    func testModelTimelineProposalIsCheckedAgainstTheGivenDays() {
        let raw = #"{"fragments":[],"timeline_proposals":[{"kind":"项目","title":"毕设","path":"楼层/项目/毕设","days":["2026-10-22"]}]}"#
        guard case .failure(let f) = CatalogModelSorter.check(raw, pool: [], pages: []) else { return XCTFail("时间轴是暂无却提了") }
        XCTAssertTrue(f.message.contains("暂无"))
        let day = CatalogTimeline.Day(date: "2026-10-22", topics: ["毕设"])
        guard case .success(let ok) = CatalogModelSorter.check(raw, pool: [], pages: [], timeline: [day]) else { return XCTFail() }
        XCTAssertEqual(ok.grouped.timeline.map(\.path), ["楼层/项目/毕设"])
        XCTAssertEqual(ok.grouped.timeline.first?.days, ["2026-10-22"])
        let existing = [WikiInjectionSnapshot.Page(path: "楼层/项目/毕设", title: "毕设", triggers: [], hook: "", now: "")]
        guard case .failure = CatalogModelSorter.check(raw, pool: [], pages: existing, timeline: [day]) else { return XCTFail("已有的页不能提开页") }
        let madeUp = raw.replacingOccurrences(of: "2026-10-22", with: "2026-09-01")
        guard case .failure(let g) = CatalogModelSorter.check(madeUp, pool: [], pages: [], timeline: [day]) else { return XCTFail("编的日期") }
        XCTAssertTrue(g.message.contains("时间轴里没有"))
    }

}
