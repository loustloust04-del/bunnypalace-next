import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// C2/C3 v2 第 8a 段 · 分拣：代码基线（默认，零模型）对着此刻的 wiki 索引字面比对 + 没对上的按 subject 开新页；
/// 模型分拣可选（校验 + 一次重写）；两种交同一种方向提案。夹具全是虚构
@MainActor
final class CatalogSortingTests: XCTestCase {

    private let pid = "xctest-catalog-sorting"
    private let names = MemoryExtractor.Names(userName: "小鹿", assistantName: "星砚")
    private var root: URL!
    private var wiki: WikiStore!
    private var store: WikiProposalStore!
    private var container: ModelContainer!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-sorting-\(UUID().uuidString)", isDirectory: true)
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

    private func f(_ subject: String?, _ tags: [String], _ content: String = "正文", single: Bool = false) -> CatalogFragment {
        var x = CatalogFragment(id: UUID(), content: content, category: "fact", day: "2026-10-12")
        x.subject = subject
        x.keywords = tags
        if single { x.organizedAt = Date() }
        return x
    }

    private func page(_ path: String, _ title: String, _ triggers: [String] = []) -> WikiInjectionSnapshot.Page {
        WikiInjectionSnapshot.Page(path: path, title: title, triggers: triggers, hook: "", now: "")
    }

    private var blocked: [String] { [names.user, names.char] }

    @discardableResult
    private func insert(_ content: String, subject: String?, tags: [String], day: Int = 12) throws -> Memory {
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

    private func memory(_ id: UUID) throws -> Memory? {
        try ModelContext(container).fetch(FetchDescriptor<Memory>()).first { $0.id == id }
    }

    private func job(sorter: CatalogSettings.Sorter = .code, caller: @escaping SessionSegmentWriter.Caller = { _, _ in nil }) -> CatalogJob {
        var j = CatalogTestKit.job(pid: pid, root: root, container: container, caller: caller)
        j.names = names
        j.sorter = sorter
        return j
    }

    private func directions() -> [WikiProposal.Direction] {
        store.list().flatMap { $0.items.compactMap(\.change.direction) }
    }

    // MARK: - 代码基线

    func testCookieGainingWeightGoesToTheCookiePageNotHerBodyPage() {
        let pages = [page("人/饼干", "饼干"), page("{{user}}/身体", "身体", ["过敏"])]
        let cookie = f("饼干", ["猫", "体重"], "又胖了半斤")
        let cookieByContent = f(nil, ["称重"], "饼干今天称了六公斤")
        let allergy = f("小鹿", ["花生"], "对花生过敏")
        let oldSingle = f("饼干", ["猫"], single: true)

        let grouped = CatalogSorter.group([cookie, cookieByContent, allergy, oldSingle], pages: pages, blocked: blocked, user: names.user)

        XCTAssertEqual(grouped.topics.map(\.path), ["人/饼干", "{{user}}/身体"])
        XCTAssertEqual(grouped.topics[0].fragmentIds, [cookie.id, cookieByContent.id, oldSingle.id], "subject / content 字面对上都归；单条就够的跟着新证据回来")
        XCTAssertTrue(grouped.topics[0].existing)
        XCTAssertTrue(grouped.topics[0].reason.contains("subject「饼干」") && grouped.topics[0].reason.contains("content「饼干」"),
                      "理由写明哪个字段的哪个词：\(grouped.topics[0].reason)")
        XCTAssertEqual(grouped.topics[1].fragmentIds, [allergy.id], "触发词对上她的页")
        XCTAssertEqual(grouped.unclear, 0)
    }

    func testOnlySinglesDoNotMakeAGroup() {
        let pages = [page("人/饼干", "饼干")]
        let grouped = CatalogSorter.group([f("饼干", [], single: true)], pages: pages, blocked: blocked, user: names.user)
        XCTAssertTrue(grouped.topics.isEmpty)
    }

    func testTanakaOpensOnlyWithTheThirdFragment() {
        let two = [f("田中老师", ["日语"], "日语课老师"), f("田中老师", ["上课"], "每周三上课")]
        XCTAssertTrue(CatalogSorter.group(two, pages: [], blocked: blocked, user: names.user).topics.isEmpty, "两条不开页")

        let three = two + [f("田中老师", ["N2"], "布置了 N2 模拟题")]
        let grouped = CatalogSorter.group(three, pages: [], blocked: blocked, user: names.user)
        XCTAssertEqual(grouped.topics.count, 1)
        let t = grouped.topics[0]
        XCTAssertEqual(t.title, "田中老师")
        XCTAssertFalse(t.existing)
        XCTAssertEqual(t.fragmentIds, three.map(\.id))
        XCTAssertTrue(t.reason.contains("田中老师") && t.reason.contains("3"))
    }

    func testHittingTwoPagesIsUnclearAndLeftAlone() {
        let pages = [page("人/饼干", "饼干"), page("{{user}}/身体", "身体", ["过敏"])]
        let both = f(nil, ["过敏"], "饼干也对鸡肉过敏")
        let grouped = CatalogSorter.group([both], pages: pages, blocked: blocked, user: names.user)
        XCTAssertTrue(grouped.topics.isEmpty)
        XCTAssertEqual(grouped.unclear, 1)
    }

    /// C2 探针实况（10-22，subject 修好后）：subject 是干净的名字；tags 里泛词（习惯 / 计划 / 睡眠 / 职场）各出现 ≥3 次
    func testNewPagesComeFromSubjectsNeverFromGenericTags() {
        let me = "岚舟"
        let pool = [
            f("豆包", ["豆包", "肾脏", "习惯"], "体检发现肌酐偏高，要长期吃肾脏处方粮"),
            f("豆包", ["豆包", "吸尘器", "计划"], "一听到吸尘器就钻进床底"),
            f("豆包", ["豆包", "猫", "睡眠"], "搬家期间一直躲在纸箱里"),
            f("林栖", ["林栖", "陶艺", "职场"], "在云桥城开陶艺工作室"),
            f("林栖", ["林栖", "借书", "习惯"], "借给岚舟的书一年没还"),
            f("林栖", ["林栖", "陶艺展", "计划"], "下个月去成都参加陶艺展"),
            f("半盏", ["半盏", "旧书店", "睡眠"], "每周六下午固定去"),
            f("半盏", ["半盏", "职场"], "老板会留旧杂志"),
            f("半盏", ["半盏", "步行", "计划"], "新家步行十分钟"),
            f(me, ["熬夜", "睡眠", "习惯"], "经常凌晨两三点才睡"),
            f(me, ["职场", "周报", "委屈"], "替同事代写了周报"),
            f(me, ["拖延", "习惯", "职场"], "做设计拖到截止前一晚"),
            f(me, ["潜水证", "计划", "睡眠"], "明年春天考潜水证"),
        ]

        let grouped = CatalogSorter.group(pool, pages: [], blocked: [me, "星砚"], user: me)

        XCTAssertEqual(Set(grouped.topics.map(\.title)), ["豆包", "林栖", "半盏", "岚舟本人"])
        for word in ["习惯", "计划", "睡眠", "职场"] {
            XCTAssertFalse(grouped.topics.contains { $0.title == word || $0.path.hasSuffix("/" + word) }, "泛词 tag 不开页：\(word)")
        }
        let mine = grouped.topics.first { $0.group }
        XCTAssertEqual(mine?.path, "{{user}}", "她本人：不以名字开页、不按方面拆，提整理分组交写手")
        XCTAssertFalse(mine?.existing ?? true)
        XCTAssertEqual(mine?.fragmentIds.count, 4)
    }

    func testLegacyFragmentsWithoutSubjectStillGroupByFirstKeyword() {
        let pool = [f(nil, ["纸帆船", "蓝色"]), f(nil, ["纸帆船"]), f(nil, ["纸帆船", "比赛"])]
        let grouped = CatalogSorter.group(pool, pages: [], blocked: blocked, user: names.user)
        XCTAssertEqual(grouped.topics.map(\.title), ["纸帆船"])
        XCTAssertTrue(CatalogSorter.title(f(nil, [])).hasPrefix("未命名碎片 "))
    }

    func testSubjectInsideALongerPageTitleStillOpensItsOwnPage() {
        let pages = [page("事/上海旅行", "上海旅行")]
        let pool = [f("上海", [], "a"), f("上海", [], "b"), f("上海", [], "c")]
        XCTAssertEqual(CatalogSorter.group(pool, pages: pages, blocked: blocked, user: names.user).topics.map(\.title), ["上海"],
                       "页标题包含 subject 不等于碎片对上了那页")
    }

    func testAssistantOrBlockedSubjectsNeverBorrowATagToOpenAPage() {
        let assistant = (0..<3).map { _ in f(names.char, ["计划", "提醒"]) }
        let stop = (0..<3).map { _ in f("随便", ["计划"]) }
        let legacy = (0..<3).map { _ in f(nil, ["纸帆船"]) }
        let grouped = CatalogSorter.group(assistant + stop + legacy, pages: [], blocked: blocked + ["随便"], user: names.user)
        XCTAssertEqual(grouped.topics.map(\.title), ["纸帆船"], "只有真没 subject 的旧碎片按关键词")
    }

    func testSubjectsAreComparedAfterWidthCaseAndSpaceNormalization() {
        let pool = [f("ＡＩ", []), f("ai", []), f("AI", []), f("Project  X", []), f("project x", []), f(" Project X", []),
                    f("ＬＵ", []), f("lu", []), f("Lu ", [])]
        let grouped = CatalogSorter.group(pool, pages: [], blocked: ["Lu"], user: "Lu")
        XCTAssertEqual(Set(grouped.topics.map(\.title)), ["ＡＩ", "Project  X", "Lu本人"], "显示保留第一次出现的原文")
        XCTAssertTrue(grouped.topics.allSatisfy { $0.fragmentIds.count == 3 })
    }

    /// 用户新建一页、加了触发词，下一轮碎片就能归进去（不改代码、不改 C2）
    func testPageSheCreatesIsUsedNextRound() async throws {
        var calls = 0
        let j = job(caller: { _, _ in
            calls += 1
            return nil
        })
        let first = try insert("周六去上了陶艺课，捏了一个杯子", subject: "小鹿", tags: ["陶艺", "周末"])

        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertTrue(directions().isEmpty, "没有页、只有一条：不提方向")

        try wiki.save(WikiPage(path: "{{user}}/手作", kind: .user, triggers: ["陶艺"], hook: "", title: "手作"))
        let second = try insert("陶艺课换了新老师", subject: "小鹿", tags: ["课程"], day: 13)
        let report = await CatalogSession(job: j).daily(now: Date())

        XCTAssertEqual(calls, 0, "代码基线零模型调用")
        XCTAssertEqual(report.proposals, 1, report.summary)
        let d = try XCTUnwrap(directions().first)
        XCTAssertEqual(d.path, "{{user}}/手作")
        XCTAssertEqual(d.action, .update)
        XCTAssertEqual(Set(d.clues), [first.id, second.id])
        XCTAssertTrue(d.reason.contains("陶艺"), d.reason)
        XCTAssertEqual(wiki.read("{{user}}/手作")?.kind, .user, "第八类读写往返")
    }

    // MARK: - 模型分拣

    private func modelFixture() throws -> (cookie: Memory, tanaka: [Memory], single: Memory, stash: Memory) {
        try wiki.save(WikiPage(path: "人/饼干", kind: .person, triggers: ["饼干"], hook: "", title: "饼干"))
        let cookie = try insert("又胖了半斤", subject: "饼干", tags: ["体重"], day: 12)
        let tanaka = try (13...15).map { try insert("日语课第\($0)次", subject: "田中老师", tags: ["日语"], day: $0) }
        let single = try insert("血型是 O 型", subject: "小鹿", tags: ["血型"], day: 16)
        let stash = try insert("想学潜水", subject: "小鹿", tags: ["潜水"], day: 17)
        return (cookie, tanaka, single, stash)
    }

    private let goodReply = """
    {"fragments":[{"f":"f1","page":"人/饼干"},
    {"f":"f2","new":{"kind":"人","title":"田中老师","path":"人/田中老师","aliases":["田中"]}},
    {"f":"f3","new":{"kind":"人","title":"田中老师","path":"人/田中老师"}},
    {"f":"f4","new":{"kind":"人","title":"田中老师","path":"人/田中老师"}},
    {"f":"f5","single":true},{"f":"f6","stash":"小鹿"}],"timeline_proposals":[]}
    """

    func testModelSorterRewritesOnceWithReasonsThenProposesSameDirections() async throws {
        let fx = try modelFixture()
        var users: [String] = []
        let bad = """
        {"fragments":[{"f":"f1","page":"人/曲奇"},{"f":"f2","new":{"kind":"宠物","title":"x","path":"主题/宠物/x"}}]}
        """
        let good = goodReply
        let j = job(sorter: .model, caller: { _, user in
            users.append(user)
            return users.count == 1 ? bad : good
        })

        let report = await CatalogSession(job: j).daily(now: Date())

        XCTAssertEqual(users.count, 2, "不过给一次重写")
        XCTAssertTrue(users[0].contains("暂无"), "A4 时间轴这一栏先写暂无")
        XCTAssertTrue(users[0].contains("人/饼干"), "实时索引送给模型")
        XCTAssertTrue(users[1].contains("不在 wiki 索引里") && users[1].contains("八类") && users[1].contains("没判"), "重写回灌每条原因")
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.single, 1)
        let ds = directions()
        XCTAssertEqual(ds.map(\.path).sorted(), ["人/田中老师", "人/饼干"])
        let cookie = try XCTUnwrap(ds.first { $0.path == "人/饼干" })
        XCTAssertEqual(cookie.action, .update)
        XCTAssertEqual(cookie.clues, [fx.cookie.id])
        XCTAssertTrue(cookie.reason.hasPrefix("模型"))
        let tanaka = try XCTUnwrap(ds.first { $0.path == "人/田中老师" })
        XCTAssertEqual(tanaka.action, .newPage)
        XCTAssertEqual(tanaka.kind, .person)
        XCTAssertEqual(tanaka.aliases, ["田中"])
        XCTAssertEqual(tanaka.clues, fx.tanaka.map(\.id))
        XCTAssertTrue(ds.allSatisfy { $0.mode == .daily }, "后面的两批审批不变")
        XCTAssertNotNil(try memory(fx.single.id)?.organizedAt, "single 走现有的单条就够打标")
        XCTAssertNil(try memory(fx.single.id)?.organizedPage)
        XCTAssertNil(try memory(fx.stash.id)?.organizedAt, "暂存留在池里")
    }

    func testModelSorterFailingTwiceProposesNothingAndLogs() async throws {
        let fx = try modelFixture()
        var calls = 0
        let j = job(sorter: .model, caller: { _, _ in
            calls += 1
            return "{\"fragments\":[{\"f\":\"f1\",\"page\":\"人/没有这页\"}]}"
        })

        let report = await CatalogSession(job: j).daily(now: Date())

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].contains("模型分拣"))
        XCTAssertTrue(directions().isEmpty, "本轮不提方向，也不退回代码基线")
        XCTAssertNil(try memory(fx.single.id)?.organizedAt)
        MemoryWriteLog.flush()
        XCTAssertTrue(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).contains { !$0.ok && $0.note.contains("模型分拣") })
    }

    func testRealWriteBudgetPreflightBlocksModelSorting() async throws {
        _ = try modelFixture()
        var j = job(sorter: .model)
        j.caller = FragmentModelRoute.caller(for: .local(modelId: "xctest-no-local-model"), providerManager: ProviderManager(), conversationId: "",
                                            profileId: pid, kind: .catalog, budgetExceeded: { true })
        let report = await CatalogSession(job: j).daily(now: Date())
        XCTAssertNotNil(report.blocked, "写入预算用完：生产 caller 的预算闸不发请求")
        XCTAssertTrue(directions().isEmpty)
    }

    func testSameInputIsNotSortedTwiceAndAnyIndexChangeSortsAgain() async throws {
        _ = try modelFixture()
        var calls = 0
        let stashAll = #"{"fragments":[{"f":"f1","stash":"饼干"},{"f":"f2","stash":"田中老师"},{"f":"f3","stash":"田中老师"},{"f":"f4","stash":"田中老师"},{"f":"f5","stash":"小鹿"},{"f":"f6","stash":"小鹿"}]}"#
        let j = job(sorter: .model, caller: { _, _ in
            calls += 1
            return stashAll
        })
        _ = await CatalogSession(job: j).daily(now: Date())
        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertEqual(calls, 1, "碎片、索引、模型、提示词都没变：不再付费")

        try wiki.save(WikiPage(path: "人/田中老师", kind: .person, triggers: [], hook: "", title: "田中老师"))
        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertEqual(calls, 2, "她新建一页，索引变了就重判")
    }

    /// 方向没存成：不记指纹，同样的输入下一轮照样重判
    func testFailedDirectionSaveDoesNotRecordFingerprint() async throws {
        _ = try modelFixture()
        var calls = 0
        let noSingle = goodReply.replacingOccurrences(of: #"{"f":"f5","single":true}"#, with: #"{"f":"f5","stash":"小鹿"}"#)
        let j = job(sorter: .model, caller: { _, _ in
            calls += 1
            return noSingle
        })
        let proposals = wiki.root.appendingPathComponent(WikiStore.proposalsFolder)
        try? FileManager.default.removeItem(at: proposals)
        try Data("挡住提案文件夹".utf8).write(to: proposals)

        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(directions().isEmpty, "方向没存成")
        XCTAssertFalse(FileManager.default.fileExists(atPath: CatalogModelSorter.fingerprintURL(wiki).path), "没存成不记指纹")

        try FileManager.default.removeItem(at: proposals)
        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertEqual(calls, 2, "同样的输入下一轮还会重新分拣")
        XCTAssertFalse(directions().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: CatalogModelSorter.fingerprintURL(wiki).path), "方向存下了才记指纹")
    }

    /// 模型提的具体用户页就是那一页，不被当成分组
    func testModelProposedUserPageKeepsItsExactPath() async throws {
        let ids = try (12...14).map { try insert("每天\($0 - 6)点起床", subject: "小鹿", tags: ["作息"], day: $0).id }
        var writer = ""
        let sortReply = #"{"fragments":[{"f":"f1","new":{"kind":"用户","title":"作息","path":"{{user}}/作息"}},{"f":"f2","new":{"kind":"用户","title":"作息","path":"{{user}}/作息"}},{"f":"f3","new":{"kind":"用户","title":"作息","path":"{{user}}/作息"},"why":"都在说起床时间"}]}"#
        let j = job(sorter: .model, caller: { system, user in
            if system.contains("分拣和提案") { return sortReply }
            writer = user
            return #"{"items":[{"type":"new_page","path":"{{user}}/作息","kind":"用户","title":"作息","records":[{"text":"2026-10-12 早起","fragments":["f1","f2","f3"]}]}]}"#
        })
        _ = await CatalogSession(job: j).daily(now: Date())
        let d = try XCTUnwrap(directions().first)
        XCTAssertEqual(d.path, "{{user}}/作息")
        XCTAssertEqual(d.kind, .user)
        XCTAssertNil(d.group)
        XCTAssertTrue(d.reason.contains("起床时间"), "模型的 why 进理由")
        let proposal = try XCTUnwrap(store.list().first)
        try await WikiProposalReview.approve(proposal.id, store: store, profileId: pid, context: ModelContext(container))
        _ = await CatalogSession(job: j).directions(proposal.id)
        XCTAssertTrue(writer.contains("小鹿/作息") && !writer.contains("整理分组") && !writer.contains("{{user}}"), "写手收到的就是这一页（本人那组显示成名字）")
        let content = try XCTUnwrap(store.list().first { $0.directionRef != nil })
        XCTAssertEqual(content.items.compactMap(\.change.targetPath), ["{{user}}/作息"])
        XCTAssertEqual(Set(content.items[0].fragmentIds), Set(ids))
    }

    /// 整理本人：分组下现有页（含同名页）全文和版本一起给写手；只能动给过全文的页，别的只能新开；每个新页都要 ≥3 条碎片出处
    func testGroupDirectionGivesFullTextAndEveryNewPageNeedsThree() async throws {
        try wiki.save(WikiPage(path: "{{user}}/身体", kind: .user, triggers: ["过敏"], hook: "", title: "身体", now: "正在吃抗过敏药（自 2026-09 起）。"))
        try wiki.save(WikiPage(path: "{{user}}/作息/晨间", kind: .user, triggers: [], hook: "", title: "晨间", now: "下一层页的现在。"))
        try wiki.save(WikiPage(path: "人/饼干", kind: .person, triggers: ["饼干"], hook: "", title: "饼干", now: "一只橘猫。"))
        let ids = try ["最近开始晨跑", "睡眠变好了", "每周跑三次"].enumerated().map { try insert($1, subject: "小鹿", tags: ["运动"], day: 12 + $0).id }
        var writer = ""
        let j = job(caller: { _, user in
            writer = user
            return """
            {"items":[
            {"type":"rewrite_now","path":"{{user}}/身体","now":"正在吃抗过敏药（自 2026-09 起），开始晨跑（自 2026-10 起）。"},
            {"type":"rewrite_now","path":"人/饼干","now":"被改坏的现在"},
            {"type":"new_page","path":"{{user}}/运动","kind":"用户","title":"运动","records":[{"text":"2026-10-12 晨跑","fragments":["f1","f2","f3"]}]},
            {"type":"new_page","path":"{{user}}/睡眠","kind":"用户","title":"睡眠","records":[{"text":"2026-10-13 睡眠变好","fragments":["f2"]}]}
            ]}
            """
        })

        _ = await CatalogSession(job: j).daily(now: Date())
        let d = try XCTUnwrap(directions().first)
        XCTAssertEqual(d.path, "{{user}}")
        XCTAssertEqual(d.group, true, "本人那组是分组方向")
        XCTAssertEqual(Set(d.clues), Set(ids))
        let proposal = try XCTUnwrap(store.list().first)
        try await WikiProposalReview.approve(proposal.id, store: store, profileId: pid, context: ModelContext(container))
        let run = await CatalogSession(job: j).directions(proposal.id)

        XCTAssertTrue(writer.contains("正在吃抗过敏药") && writer.contains("下一层页的现在"), "动笔前拿到分组下各页（含更深层）的旧正文")
        XCTAssertFalse(writer.contains("一只橘猫"))
        let content = try XCTUnwrap(store.list().first { $0.directionRef != nil }, run.summary)
        XCTAssertEqual(content.items.compactMap(\.change.targetPath).sorted(), ["{{user}}/身体", "{{user}}/运动"],
                       "没给全文的页不能改；不到 3 条的新页不交")
        XCTAssertNotNil(content.items.first { $0.change.targetPath == "{{user}}/身体" }?.baseVersion)
        let result = try XCTUnwrap(store.load(proposal.id)?.items.first?.change.direction?.result)
        XCTAssertTrue(result.contains("{{user}}/睡眠"), result)
    }

    /// 非分组方向：分拣时已经按 ≥3 条提过，写手只引一条碎片 / 原文 / A 线也照交
    func testNonGroupNewPageIsNotRecountedAfterWriting() async throws {
        _ = try (12...14).map { try insert("纸帆船第\($0)天", subject: "纸帆船", tags: [], day: $0).id }
        let j = job(caller: { _, _ in
            #"{"items":[{"type":"new_page","path":"主题/纸帆船","kind":"主题","title":"纸帆船","records":[{"text":"2026-10-12 x","fragments":["f1"]}]}]}"#
        })
        _ = await CatalogSession(job: j).daily(now: Date())
        let proposal = try XCTUnwrap(store.list().first)
        try await WikiProposalReview.approve(proposal.id, store: store, profileId: pid, context: ModelContext(container))
        _ = await CatalogSession(job: j).directions(proposal.id)
        XCTAssertNotNil(store.list().first { $0.directionRef != nil }, "只引 1 条碎片的新开页照交")
    }

    // MARK: - 整理分组：全文、本机裁剪、stale、covered

    /// 三条「小鹿」碎片走整理分组：她的身体页（给全文）+ 饼干页（不给）；daily → 批 → 写手
    private func runGroup(writer: @escaping (String) -> String) async throws -> (content: WikiProposal?, result: String, ids: [UUID]) {
        try wiki.save(WikiPage(path: "{{user}}/身体", kind: .user, triggers: ["过敏"], hook: "", title: "身体", now: "正在吃抗过敏药（自 2026-09 起）。"))
        try wiki.save(WikiPage(path: "人/饼干", kind: .person, triggers: ["饼干"], hook: "", title: "饼干", now: "一只橘猫。"))
        let ids = try ["最近开始晨跑", "睡眠变好了", "每周跑三次"].enumerated().map { try insert($1, subject: "小鹿", tags: ["运动"], day: 12 + $0).id }
        let j = job(caller: { _, user in writer(user) })
        _ = await CatalogSession(job: j).daily(now: Date())
        let direction = try XCTUnwrap(store.list().first)
        XCTAssertEqual(direction.items.first?.change.direction?.group, true)
        try await WikiProposalReview.approve(direction.id, store: store, profileId: pid, context: ModelContext(container))
        _ = await CatalogSession(job: j).directions(direction.id)
        let result = store.load(direction.id)?.items.first?.change.direction?.result ?? ""
        return (store.list().first { $0.directionRef != nil }, result, ids)
    }

    func testGroupFullTextSurvivesRealLocalAssemblyOrFailsInPlainWords() async throws {
        try wiki.save(WikiPage(path: "{{user}}/身体", kind: .user, triggers: ["过敏"], hook: "", title: "身体", now: "正在吃抗过敏药。"))
        let frags = [f("小鹿", [], "开始晨跑"), f("小鹿", [], "睡眠变好"), f("小鹿", [], "每周跑三次")]
        let topic = CatalogSorter.Topic(path: "{{user}}", title: "小鹿本人", kind: .user, existing: false, fragmentIds: frags.map(\.id), group: true)
        let wiki = self.wiki!
        let root = self.root!
        func material() async -> CatalogWriter.Material {
            await CatalogWriter.material(topic, fragments: frags, floorPrompt: "", wiki: wiki, memoryRoot: root, now: Date(),
                                         embedder: CatalogFakeEmbedder.unavailable())
        }
        // 写作规则本身已超出本机系统提示上限（第 9 段起本机直接报错，见 CatalogWriterTests），这里只验用户文本的真实裁法：
        // 系统提示原样过，用户文本按本机真实规则留尾
        let userTrim: (String, String) -> (system: String, user: String) = { system, user in
            (system, CatalogLocalTrim.apply("", user).user)
        }
        var sent: (system: String, user: String)?
        _ = try await CatalogWriter.write(await material(), names: names, wiki: wiki, caller: { system, user in
            sent = userTrim(system, user)
            return #"{"items":[]}"#
        }, drafts: nil, trim: userTrim)
        let raw = try XCTUnwrap(wiki.readRaw("{{user}}/身体"))
        XCTAssertTrue(try XCTUnwrap(sent).user.contains(raw), "本机真实裁剪之后，全文还在")

        try wiki.save(WikiPage(path: "{{user}}/身体", kind: .user, triggers: ["过敏"], hook: "", title: "身体",
                               now: String(repeating: "长", count: LocalChatProvider.totalBudget)))
        let longRaw = try XCTUnwrap(wiki.readRaw("{{user}}/身体"))
        var called = false
        do {
            _ = try await CatalogWriter.write(await material(), names: names, wiki: wiki, caller: { _, _ in
                called = true
                return nil
            }, drafts: nil, trim: userTrim)
            XCTFail("放不下全文必须失败")
        } catch let error as CatalogWriterError {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("{{user}}/身体") && text.contains("放不进") && text.contains("全文 \(longRaw.count) 字"), text)
        }
        XCTAssertFalse(called, "不裁剪、不分批，直接不发")
    }

    func testPageEditedAfterTheGroupReadGoesStale() async throws {
        let wiki = self.wiki!
        let run = try await runGroup { _ in
            if var hand = wiki.read("{{user}}/身体") {
                hand.now = "她读完以后手改了"
                try? wiki.saveRaw(hand.markdown, path: "{{user}}/身体")
            }
            return #"{"items":[{"type":"rewrite_now","path":"{{user}}/身体","now":"正在吃抗过敏药，开始晨跑。"}]}"#
        }
        let content = try XCTUnwrap(run.content)
        let out = try await WikiProposalReview.approve(content.id, store: store, profileId: pid, context: ModelContext(container))
        XCTAssertEqual(out.items.first?.state, .stale, "版本是读全文那一刻的，页变了不硬盖")
        XCTAssertEqual(wiki.read("{{user}}/身体")?.now, "她读完以后手改了")
    }

    func testGroupCoveredMustNameAPageWhoseFullTextWasGiven() async throws {
        let named = try await runGroup { _ in #"{"items":[],"covered":["f1"],"covered_page":"{{user}}/身体"}"# }
        let content = try XCTUnwrap(named.content)
        XCTAssertEqual(content.items.map(\.change), [.confirmCovered(path: "{{user}}/身体")])
        XCTAssertEqual(content.items.first?.covered, [named.ids[0]])
    }

    func testGroupCoveredOnAPageNotGivenIsNotAttached() async throws {
        let other = try await runGroup { _ in #"{"items":[],"covered":["f1"],"covered_page":"人/饼干"}"# }
        XCTAssertNil(other.content, "covered_page 不是给过全文的页：不挂，碎片留池")
        XCTAssertNil(try memory(other.ids[0])?.organizedAt)
    }

    // MARK: - 目标身份：页和分组是两个目标

    func testSameNamePageAndHerGroupAreSeparateTargetsInAnyOrder() {
        let pages = [page("{{user}}", "概要")]
        let onPage = [f(nil, [], "概要里写过的一件事"), f(nil, [], "概要里写过的另一件事")]
        let mine = [f("小鹿", [], "开始晨跑"), f("小鹿", [], "睡眠变好"), f("小鹿", [], "每周跑三次")]
        func ids(_ list: [UUID]?) -> Set<UUID> { Set(list ?? []) }
        for pool in [onPage + mine, mine + onPage] {
            let grouped = CatalogSorter.group(pool, pages: pages, blocked: blocked, user: names.user)
            XCTAssertEqual(Set(grouped.topics.map(\.target)), ["页:{{user}}", "分组:{{user}}"])
            XCTAssertEqual(ids(grouped.topics.first { !$0.group }?.fragmentIds), Set(onPage.map(\.id)))
            XCTAssertEqual(ids(grouped.topics.first { $0.group }?.fragmentIds), Set(mine.map(\.id)))
        }
    }

    // MARK: - 指纹：什么都没被扣下才记；现在整理不碰；regroup 不连带

    func testDirectionHeldByAPendingOneIsProposedAfterItIsResolved() async throws {
        try wiki.save(WikiPage(path: "人/饼干", kind: .person, triggers: ["饼干"], hook: "", title: "饼干"))
        let first = try insert("又胖了半斤", subject: "饼干", tags: [], day: 12)
        var sorts = 0
        let j = job(sorter: .model, caller: { system, _ in
            if system.contains("分拣和提案") {
                sorts += 1
                return #"{"fragments":[{"f":"f1","page":"人/饼干"}]}"#
            }
            return #"{"items":[{"type":"append","path":"人/饼干","records":[{"text":"2026-10-12 胖了","fragments":["f1"]}]}]}"#
        })
        _ = await CatalogSession(job: j).daily(now: Date())
        let pending = try XCTUnwrap(store.list().first)
        let second = try insert("开始减肥粮", subject: "饼干", tags: [], day: 13)

        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertEqual(sorts, 2)
        XCTAssertEqual(directions().count, 1, "饼干已有待批方向，这一轮的被扣下")

        try await WikiProposalReview.approve(pending.id, store: store, profileId: pid, context: ModelContext(container))
        _ = await CatalogSession(job: j).directions(pending.id)
        let content = try XCTUnwrap(store.list().first { $0.directionRef != nil })
        try await WikiProposalReview.approve(content.id, store: store, profileId: pid, context: ModelContext(container))
        XCTAssertNotNil(try memory(first.id)?.organizedPage)

        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertEqual(sorts, 3, "被扣下的那轮没记指纹，同样的输入照样重判")
        XCTAssertTrue(store.list().contains { $0.id != pending.id && $0.items.contains { $0.change.direction?.clues == [second.id] } })
    }

    func testOrganizeNowNeverReadsOrWritesTheFingerprint() async throws {
        _ = try modelFixture()
        var sorts = 0
        let stashAll = #"{"fragments":[{"f":"f1","stash":"饼干"},{"f":"f2","stash":"田中老师"},{"f":"f3","stash":"田中老师"},{"f":"f4","stash":"田中老师"},{"f":"f5","stash":"小鹿"},{"f":"f6","stash":"小鹿"}]}"#
        let j = job(sorter: .model, caller: { _, _ in
            sorts += 1
            return stashAll
        })
        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertEqual(sorts, 1)
        _ = await CatalogSession(job: j).organizeNow(now: Date())
        _ = await CatalogSession(job: j).organizeNow(now: Date())
        XCTAssertEqual(sorts, 3, "她主动点的现在整理每次照常分拣")
        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertEqual(sorts, 3, "现在整理没动自动那次记下的指纹")
    }

    func testRegroupFailingAloneStillRecordsTheSortFingerprint() async throws {
        _ = try modelFixture()
        for i in 0...WikiStore.layerLimit { try wiki.save(WikiPage(path: "人/人\(i)", kind: .person, triggers: [], hook: "", title: "人\(i)")) }
        var sorts = 0
        var regroups = 0
        let stashAll = #"{"fragments":[{"f":"f1","stash":"饼干"},{"f":"f2","stash":"田中老师"},{"f":"f3","stash":"田中老师"},{"f":"f4","stash":"田中老师"},{"f":"f5","stash":"小鹿"},{"f":"f6","stash":"小鹿"}]}"#
        let j = job(sorter: .model, caller: { system, _ in
            if system.contains("分拣和提案") {
                sorts += 1
                return stashAll
            }
            regroups += 1
            return "分不出来"
        })
        let first = await CatalogSession(job: j).daily(now: Date())
        XCTAssertGreaterThan(regroups, 0)
        XCTAssertFalse(first.failures.isEmpty, "分组调整失败")
        _ = await CatalogSession(job: j).daily(now: Date())
        XCTAssertEqual(sorts, 1, "分拣本身交付完了，regroup 失败不连带重付")
    }

    func testModelCheckCatchesWhatCodeCanJudge() {
        let pool = [f("饼干", []), f("田中老师", [])]
        let pages = [page("人/饼干", "饼干")]
        func problems(_ json: String) -> String {
            if case .failure(let failure) = CatalogModelSorter.check(json, pool: pool, pages: pages) { return failure.message }
            return ""
        }
        XCTAssertTrue(problems("不是 JSON").contains("JSON"))
        XCTAssertTrue(problems(#"{"fragments":[{"f":"f1","page":"人/饼干"}]}"#).contains("没判：f2"))
        XCTAssertTrue(problems(#"{"fragments":[{"f":"f1","page":"人/饼干"},{"f":"f1","single":true},{"f":"f2","single":true}]}"#).contains("不止一次"))
        XCTAssertTrue(problems(#"{"fragments":[{"f":"f1","page":"人/饼干","single":true},{"f":"f2","single":true}]}"#).contains("正好写一个"))
        XCTAssertTrue(problems(#"{"fragments":[{"f":"f1","new":{"kind":"人","title":"饼干","path":"人/饼干"}},{"f":"f2","single":true}]}"#).contains("已经有这页"))
        XCTAssertTrue(problems(#"{"fragments":[{"f":"f1","page":"人/饼干"},{"f":"f2","new":{"kind":"人","title":"田中","path":"别处/田中"}}]}"#).contains("不合法"))
        XCTAssertTrue(problems(#"{"fragments":[{"f":"f1","page":"人/饼干"},{"f":"f9","single":true},{"f":"f2","single":true}]}"#).contains("没有这条碎片"))
        XCTAssertTrue(problems(#"{"fragments":[{"f":"f1","page":"人/饼干"},{"f":"f2","new":{"kind":"人","path":"人/田中"}}]}"#).contains("缺 title"))
        XCTAssertTrue(problems(#"{"fragments":[{"f":"f1","new":{"kind":"人","title":"田中","path":"人/田中"}},{"f":"f2","new":{"kind":"物","title":"田中","path":"人/田中"}}]}"#).contains("不一致"))

        let ok = CatalogModelSorter.check(#"{"fragments":[{"f":"f1","page":"人/饼干"},{"f":"f2","new":{"kind":"用户","title":"日语","path":"{{user}}/日语"}}]}"#,
                                          pool: pool, pages: pages)
        guard case .success(let sorted) = ok else { return XCTFail("八类含「用户」，合格") }
        XCTAssertEqual(sorted.grouped.topics.map(\.path), ["人/饼干"], "新页不到 3 条不提")
        XCTAssertEqual(sorted.waiting, 1)
    }

    func testSorterDefaultsToCode() {
        let suite = "xctest-catalog-sorter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CatalogSettings.sorter(defaults), .code)
        defaults.set("model", forKey: CatalogSettings.sorterKey)
        XCTAssertEqual(CatalogSettings.sorter(defaults), .model)
        XCTAssertTrue(ConfigSchema.allScalarEntries.contains { $0.key == CatalogSettings.sorterKey }, "跟着配置导出")
    }
}
