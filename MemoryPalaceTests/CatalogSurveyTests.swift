import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 第 11 段：新用户三问 → 同一个种子任务机制（答案落进目标楼层 → 目录批 → 逐页写 → 正文批）。夹具全是虚构，临时目录
@MainActor
final class CatalogSurveyTests: XCTestCase {
    private let pid = "xctest-catalog-survey"
    private var base: URL!
    private var root: URL!
    private var container: ModelContainer!
    private var wiki: WikiStore { WikiStore(root: root.appendingPathComponent("wiki")) }
    private var store: WikiProposalStore { WikiProposalStore(wiki: wiki) }
    private var tasks: CatalogSeedTaskStore { CatalogSeedTaskStore(wiki: wiki) }
    private var me: String { CatalogTestKit.names.user }
    private let slotPath = PromptFolder.path(for: .slot(presetId: "preset-1", slotId: "custom-slot"))

    private let answers = CatalogSurvey.answers(["阿青", "自己在做离线阅读工具「纸舟」，算创业", "晚上十点以后别催我"])
    private let answered = Date()
    private var day: String { CatalogSurvey.day(answered) }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-survey-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("memory", isDirectory: true)
        container = try ModelContainer(for: Memory.self, Conversation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        container = nil
    }

    // MARK: - 夹具

    private func job(_ model: SeedModel, blocked: String? = nil) -> CatalogJob {
        model.wiki = wiki
        var j = CatalogTestKit.job(pid: pid, root: root, container: container, backend: model.backend)
        j.floorBase = CatalogFloorBase(sections: [.init(path: slotPath, name: "自建槽", text: "PROMPT_ONLY_MARKER 阿青住在云桥城", isEnabled: true)])
        j.seedModel = "remote:test-credential/fake-model"
        j.seedBlocked = blocked
        return j
    }

    private func create(_ id: String = UUID().uuidString, answers: [CatalogSurvey.Answer]? = nil, blocked: CatalogSurvey.Blocker? = nil) async throws -> (id: String, outcome: CatalogSurvey.Outcome) {
        let outcome = try await CatalogSurvey.create(taskId: id, profileId: pid, answers: answers ?? self.answers, wiki: wiki, blocked: blocked, now: answered)
        return (id, outcome)
    }

    private func card(_ title: String, _ gist: String, _ mentions: [(String, String)] = [], aboutUser: Bool = true, group: String = "{{user}}") -> [String: Any] {
        ["title": title, "gist": gist, "mentions": mentions.map { ["name": $0.0, "group": $0.1] }, "about_user": aboutUser, "group": group]
    }

    private func newPage(_ path: String, _ kind: String, _ title: String, _ text: String, _ sources: [String]) -> [[String: Any]] {
        [["type": "new_page", "path": path, "kind": kind, "title": title, "now": text,
          "records": [["text": "\(day) " + text, "sources": sources]]]]
    }

    private func outline(_ id: String) -> WikiProposal? { store.load(id) }

    private func contents(_ id: String) -> [WikiProposal] {
        store.list().filter { $0.directionRef?.proposalId == id && $0.id != id }
    }

    private func item(_ outline: WikiProposal, _ title: String) throws -> WikiProposal.Item {
        try XCTUnwrap(outline.items.first { $0.change.direction?.title == title })
    }

    private func approve(_ id: String, _ items: Set<String>? = nil) async throws {
        try await WikiProposalReview.approve(id, itemIds: items, store: store, profileId: pid, context: ModelContext(container))
    }

    private func sent(_ model: SeedModel) -> String {
        model.backend.requests.map { r in ([r.system] + r.history.map(\.content) + r.toolTurns.flatMap(\.results).map(\.text)).joined() }.joined()
    }

    /// 假模型照真模型那样写名字（它看到的就是名字）：落盘应当回到 {{user}}/…
    /// 三份本人答案：首轮两张薄页卡和漏掉的「称呼」补问后仍没归好，统一进待归类；单份纸舟不开实体页，也不折入触发词。
    private func standard(_ model: SeedModel) {
        model.userName = me
        model.cards = [
            "问卷/称呼": card("想让我叫阿青", "想让我叫阿青"),
            "问卷/在做什么": card("在做离线阅读工具纸舟", "自己在做离线阅读工具纸舟，算创业", [("纸舟", "项目")]),
            "问卷/应该知道的": card("晚上十点后别催", "晚上十点以后别催"),
        ]
        for path in Array(model.cards.keys) { model.cards[path]?["when"] = [day] }
        model.userPages = [("在做的事", "{{user}}/在做的事", ["问卷/在做什么"]), ("作息", "{{user}}/作息", ["问卷/应该知道的"])]
        model.pages = [
            "{{user}}/待归类": [[
                "type": "new_page", "path": "\(me)/待归类", "kind": "用户", "title": "还没归类的",
                "now": "想让我叫阿青；在做离线阅读工具纸舟；晚上十点以后不想被催。",
                "records": [
                    ["text": "\(day) 想让我叫阿青", "sources": ["问卷/称呼"]],
                    ["text": "\(day) 自己在做离线阅读工具纸舟", "sources": ["问卷/在做什么"]],
                    ["text": "\(day) 晚上十点以后不想被催", "sources": ["问卷/应该知道的"]],
                ],
            ]],
        ]
    }

    // MARK: - 答案落进目标楼层 → 目录批 → 逐页写 → 正文批；出处只认这次的答案

    func testAnswersBecomeOutlineThenApprovedPagesThenWikiCitingOnlyTheAnswers() async throws {
        let model = SeedModel()
        standard(model)
        let created = try await create()
        XCTAssertEqual(created.outcome, .started)
        let skeleton = try XCTUnwrap(tasks.load(created.id))
        XCTAssertEqual(skeleton.entry, .survey)
        XCTAssertEqual(skeleton.profileId, pid, "任务绑在目标楼层")
        XCTAssertEqual(skeleton.answers, answers)
        XCTAssertNil(skeleton.modelKey, "答完时还没问模型，不绑模型")
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertTrue(model.backend.requests.isEmpty, "存答案不调模型")

        let first = await CatalogSession(job: job(model)).resumeSeed(created.id)
        XCTAssertEqual(first.failures, [], first.summary)
        let saved = try XCTUnwrap(outline(created.id))
        XCTAssertEqual(saved.title, "种子目录 · 新用户三问")
        XCTAssertEqual(saved.items.compactMap { $0.change.direction?.path }, ["{{user}}/待归类"], "薄页和漏卡统一落待归类，不新开单份纸舟实体页")
        XCTAssertTrue(saved.items.allSatisfy { $0.state == .pending && $0.change.direction?.mode == .seed })
        let pending = try XCTUnwrap(saved.items.first)
        XCTAssertEqual(Set(pending.change.direction?.sources ?? []), Set(answers.map(\.path)), "三份答案全部落页，称呼不再漏掉")
        XCTAssertEqual(pending.change.direction?.kind, .user)
        XCTAssertEqual(pending.change.direction?.aliases, [], "取消折入后，低门槛项目名不挂到待归类页")
        XCTAssertEqual(store.list().count, 1, "答完问卷不等于批了目录：批之前没有正文提案")
        XCTAssertTrue(wiki.pagePaths().isEmpty, "目录没批不写")
        XCTAssertEqual(tasks.load(created.id)?.modelKey, "remote:test-credential/fake-model", "头一回真跑才绑模型")
        XCTAssertFalse(sent(model).contains("PROMPT_ONLY_MARKER"), "三问只读这次的答案，不读 Prompt")
        let opening = try XCTUnwrap(model.backend.requests.first?.history.first?.content)
        XCTAssertTrue(opening.hasPrefix("【这一批 3 份】"), opening.prefix(80).description)
        for question in CatalogSurvey.questions { XCTAssertTrue(opening.contains(" · 问卷 · \(question.title) · "), question.title) }
        XCTAssertTrue(opening.contains("答题日期：\(day)") && opening.contains("答：自己在做离线阅读工具「纸舟」，算创业"), "每份答案带答题日期交给模型")
        XCTAssertEqual(saved.seedSkipped?.filter { $0.hasPrefix("没归进目录") } ?? [], [])

        try await approve(created.id, [pending.id])
        let before = model.backend.requests.count
        let second = await CatalogSession(job: job(model)).resumeSeed(created.id)
        XCTAssertEqual(second.failures, [], second.summary)
        let pageRequests = Array(model.backend.requests[before...])
        XCTAssertEqual(pageRequests.count, 1, "三份答案归入同一获批页，不另写单份纸舟实体页")
        for request in pageRequests {
            XCTAssertEqual(request.history.count, 1)
            XCTAssertTrue(request.toolTurns.isEmpty, "出目录那段不回灌")
            let opening = request.history[0].content
            for answer in answers { XCTAssertFalse(opening.contains("答：\(answer.text)"), "已有卡时不发送答案全文：\(answer.key)") }
        }
        let pages = contents(created.id)
        XCTAssertEqual(Set(pages.compactMap(\.title)), ["还没归类的"])
        XCTAssertTrue(wiki.pagePaths().isEmpty, "正文没批不落 wiki")
        let doing = try XCTUnwrap(pages.first { $0.directionRef?.itemId == pending.id })
        guard case .newPage(let page) = doing.items[0].change else { return XCTFail() }
        let suffix = "\(day)#\(created.id.prefix(8))"
        let label = "问卷「在做什么」\(suffix)"
        XCTAssertEqual(page.records.count, answers.count)
        for answer in answers {
            XCTAssertTrue(page.records.contains { $0.hasPrefix(day + " · ") && $0.hasSuffix("（问卷/\(answer.key)）") })
        }
        // CatalogItems 原有「空 triggers 回退页标题」不属于折入；这里只核对额外折入词为空。
        XCTAssertEqual(page.triggers.filter { $0 != page.title }, [], "低门槛项目名不再补入正文提案触发词")
        XCTAssertEqual(Set(doing.items[0].cites.compactMap(\.name)), Set(answers.map(\.key)), "每条答案都有对应出处，不因合入待归类而丢失")
        let cite = try XCTUnwrap(doing.items[0].cites.first { $0.name == "在做什么" })
        XCTAssertEqual(cite.layer, CatalogSurvey.layer)
        XCTAssertEqual(cite.filePath, CatalogSurvey.sourcePath(created.id), "出处指向这次问卷的原答案文件")
        XCTAssertEqual(cite.day, day)
        XCTAssertEqual(CatalogSurvey.resolve(label, wiki: wiki)?.answer.text, "自己在做离线阅读工具「纸舟」，算创业", "出处查得到这次的答案原话")
        XCTAssertEqual(WikiProposalDisplay.citeText(cite, titles: [:]), "问卷 · \(day) · 在做什么")

        for content in pages { try await approve(content.id) }
        XCTAssertEqual(Set(wiki.pagePaths()), ["{{user}}/待归类"], "只落获批待归类页；名字路径落回 {{user}}")
        let stored = try XCTUnwrap(wiki.read("{{user}}/待归类"))
        XCTAssertEqual(stored.triggers.filter { $0 != stored.title }, [], "批准后的页头也没有额外折入词")
        XCTAssertFalse(sent(model).contains("{{user}}"), "发给模型的路径一律是名字")
        XCTAssertTrue(sent(model).contains("\(me)/待归类"))
        XCTAssertEqual(tasks.load(created.id)?.state, .complete)
        XCTAssertNil(CatalogSeed.completion(wiki: wiki), "三问不写种子完成标记")

        let run = try XCTUnwrap(saved.run)
        let text = try String(contentsOf: wiki.root.appendingPathComponent(run.path), encoding: .utf8)
        XCTAssertTrue(text.contains("问卷答案") && text.contains("晚上十点以后别催我"), "整理记录里看得到这次的答案")
    }

    /// wiki 已有页只能当更新目标（对齐合进锚），出处仍只能是这次的答案；页正文不进出卡的批
    func testExistingWikiPageIsOnlyAnUpdateTargetCitingTheAnswers() async throws {
        // C-3 数据合同：已有页带「事实域」才能当更新目标（旧 nil 域页按设计不更新，见 review-seed-polish-C.md）
        try wiki.save(WikiPage(path: "地点/云桥城", kind: .place, hook: "提到云桥城", title: "云桥城", now: "云桥城有座旧码头。", factDomain: .realWorld))
        let model = SeedModel()
        model.cards = ["问卷/在做什么": card("在云桥城做纸舟", "在云桥城做离线阅读工具纸舟", [("云桥城", "地点")])]
        model.merge = [["into": "wiki:地点/云桥城", "names": ["云桥城"]]]
        let created = try await create()
        let report = await CatalogSession(job: job(model)).resumeSeed(created.id)
        XCTAssertEqual(report.failures, [])
        let saved = try XCTUnwrap(outline(created.id))
        let cloud = try XCTUnwrap(item(saved, "云桥城").change.direction)
        XCTAssertEqual(cloud.action, .update)
        XCTAssertEqual(cloud.path, "地点/云桥城")
        XCTAssertEqual(cloud.sources, ["问卷/在做什么"], "出处只能是答案")
        XCTAssertFalse(sent(model).contains("云桥城有座旧码头"), "wiki 页正文不进出卡的批")
    }

    // MARK: - 已有同名页：只交更新提案，不覆盖

    func testExistingSamePageOnlyGetsAnUpdateProposal() async throws {
        let path = "{{user}}/在做的事"
        let old = WikiPage(path: path, kind: .user, hook: "提到工作", title: "在做的事", now: "在一家书店上班。", records: ["2026-09-01 在书店上班（出处：用户编辑）"], factDomain: .realWorld)
        try wiki.save(old)
        let before = try String(contentsOf: wiki.root.appendingPathComponent(path + ".md"), encoding: .utf8)
        let model = SeedModel()
        model.cards = ["问卷/在做什么": card("在做纸舟", "自己在做纸舟")]
        model.userPages = [("在做的事", path, ["问卷/在做什么"])]
        model.pages = [
            path: newPage(path, "用户", "在做的事", "自己在做纸舟", ["问卷/在做什么"])
                + [["type": "append", "path": path, "records": [["text": "\(day) 自己在做离线阅读工具纸舟", "sources": ["问卷/在做什么"]]]]],
            "主题/待归类": newPage("主题/待归类", "主题", "还没归类的", "想让我叫阿青；晚上十点以后别催我", ["问卷/称呼", "问卷/应该知道的"]),
        ]
        let created = try await create()
        let first = await CatalogSession(job: job(model)).resumeSeed(created.id)
        XCTAssertEqual(first.failures, [])
        let saved = try XCTUnwrap(outline(created.id))
        // 目录按正式来源份数降序：两份漏卡的待归类在前，一份原料的已有页更新在后，不再假定 first 是更新。
        XCTAssertEqual(saved.items.compactMap { $0.change.direction?.path }, ["主题/待归类", path])
        let fallback = try XCTUnwrap(saved.items.first?.change.direction)
        XCTAssertEqual(fallback.action, .newPage)
        XCTAssertEqual(Set(fallback.sources ?? []), ["问卷/称呼", "问卷/应该知道的"])
        let target = try XCTUnwrap(saved.items.first { $0.change.direction?.path == path })
        XCTAssertEqual(target.change.direction?.action, .update, "同名已有页即使只有一份更新原料也保留")
        XCTAssertEqual(target.change.direction?.sources, ["问卷/在做什么"])
        try await approve(created.id)
        let written = await CatalogSession(job: job(model)).resumeSeed(created.id)
        XCTAssertEqual(written.failures, [])
        let proposals = contents(created.id)
        XCTAssertEqual(proposals.count, 2, "待归类和已有页更新均有正文提案")
        let content = try XCTUnwrap(proposals.first { $0.directionRef?.itemId == target.id })
        XCTAssertEqual(content.items.map(\.change.kindLabel), ["追加记录"], "已有页的整页新开被扔，只剩更新")
        XCTAssertEqual(content.items[0].baseVersion, tasks.load(created.id)?.read[CatalogSeedMaterials.wikiPath(path)])
        XCTAssertEqual(try String(contentsOf: wiki.root.appendingPathComponent(path + ".md"), encoding: .utf8), before, "批之前一个字不动")

        try await approve(content.id)
        let after = try XCTUnwrap(wiki.read(path))
        XCTAssertEqual(after.now, "在一家书店上班。", "不覆盖已有的「现在」")
        XCTAssertEqual(Array(after.records.prefix(old.records.count)), old.records)
        XCTAssertEqual(after.records.count, old.records.count + 1)
        XCTAssertTrue(after.records.last?.hasSuffix("（问卷/在做什么）") == true)
        XCTAssertEqual(after.triggers, [], "已有页没有被强加折入触发词")
    }

    func testExistingPageNotReadCannotBeListed() throws {
        let path = "{{user}}/在做的事"
        try wiki.save(WikiPage(path: path, kind: .user, hook: "", title: "在做的事", now: "在书店上班。"))
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .survey, modelName: "", createdAt: Date(), run: .init(path: ".runs/x.md"))
        task.materials = [.init(path: "问卷/在做什么", name: "平时在做什么", layer: CatalogSurvey.layer, version: "v1")]
        task.read = ["问卷/在做什么": "v1"]
        let d = WikiProposal.Direction(path: path, title: "在做的事", hook: "", kind: .user, action: .newPage, reason: "种子目录", mode: .seed, sources: ["问卷/在做什么"])
        guard case .failure(let error) = CatalogSeedTools.checkDirection(d, task: task, wiki: wiki) else { return XCTFail("不在快照里的已有页不能列") }
        XCTAssertTrue(error.localizedDescription.contains("原料快照里没有它"), error.localizedDescription)
        task.read[CatalogSeedMaterials.wikiPath(path)] = "page-v"
        guard case .success(let ok) = CatalogSeedTools.checkDirection(d, task: task, wiki: wiki) else { return XCTFail() }
        XCTAssertEqual(ok.action, .update)
    }

    // MARK: - 出处回查：任务、提案、整理记录清掉以后还查得回原答案；每次问卷分得开

    func testRecordSourcesStillResolveAfterTasksProposalsAndRunRecordsAreCleaned() async throws {
        let model = SeedModel()
        standard(model)
        let created = try await create()
        _ = await CatalogSession(job: job(model)).resumeSeed(created.id)
        try await approve(created.id)
        _ = await CatalogSession(job: job(model)).resumeSeed(created.id)
        for content in contents(created.id) { try await approve(content.id) }
        let source = wiki.root.appendingPathComponent(CatalogSurvey.sourcePath(created.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        for folder in [WikiStore.proposalsFolder, CatalogRunRecord.folderName] {
            try FileManager.default.removeItem(at: wiki.root.appendingPathComponent(folder))
        }
        XCTAssertNil(tasks.load(created.id), "任务、提案、整理记录都清掉了")
        XCTAssertEqual(Set(wiki.pagePaths()), ["{{user}}/待归类"], "三份答案全落同一待归类页，不再丢称呼或新开单份项目页")
        let page = try XCTUnwrap(wiki.read("{{user}}/待归类"))
        XCTAssertEqual(page.triggers.filter { $0 != page.title }, [], "清理后仍只有既有标题默认词，没有折入触发词")
        XCTAssertEqual(page.records.count, answers.count)
        var resolvedKeys = Set<String>()
        for record in page.records {
            let key = try XCTUnwrap(answers.first { record.hasSuffix("（\(CatalogSurvey.prefix)\($0.key)）") }?.key, record)
            let label = CatalogSurvey.label(CatalogSurvey.cite(key: key, taskId: created.id, day: day))
            do {
                let found = try XCTUnwrap(CatalogSurvey.resolve(label, wiki: wiki), label)
                XCTAssertEqual(found.source.taskId, created.id)
                XCTAssertEqual(found.source.day, day)
                XCTAssertTrue(answers.contains(found.answer), "\(label) 查回的是这次问卷的原答案")
                resolvedKeys.insert(found.answer.key)
            }
        }
        XCTAssertEqual(resolvedKeys, Set(answers.map(\.key)), "任务清理后，三条原答案全部仍能回查，不能靠空循环通过")

        let again = try await create(answers: CatalogSurvey.answers(["阿青", "换成在学日语", ""]))
        let first = CatalogSurvey.label(CatalogSurvey.cite(key: "在做什么", taskId: created.id, day: day))
        let second = CatalogSurvey.label(CatalogSurvey.cite(key: "在做什么", taskId: again.id, day: day))
        XCTAssertNotEqual(first, second, "多次重走出处名不重复")
        XCTAssertEqual(CatalogSurvey.resolve(second, wiki: wiki)?.answer.text, "换成在学日语")
        XCTAssertEqual(CatalogSurvey.resolve(first, wiki: wiki)?.answer.text, "自己在做离线阅读工具「纸舟」，算创业")
    }

    // MARK: - 全空 / 没模型 / 重复回调

    func testBlankOrSkippedAnswersCreateNothing() async throws {
        XCTAssertTrue(CatalogSurvey.answers(["", "  ", "\n"]).isEmpty)
        XCTAssertTrue(XiaoyaSurveyAnswer().answers.isEmpty)
        let created = try await create(answers: [])
        XCTAssertEqual(created.outcome, .empty)
        XCTAssertNil(tasks.load(created.id))
        XCTAssertTrue(tasks.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wiki.root.appendingPathComponent(".runs").path), "全空不留记录、不编造")
    }

    func testNoModelKeepsTheAnswersForLaterAndBindsTheModelOnTheFirstRealRun() async throws {
        let created = try await create(blocked: .noModel)
        XCTAssertEqual(created.outcome, .later(.noModel))
        let task = try XCTUnwrap(tasks.load(created.id))
        XCTAssertEqual(task.state, .stopped)
        XCTAssertEqual(task.note, "还没生成：\(CatalogSurvey.Blocker.noModel.reason)。\(CatalogSurvey.Blocker.noModel.fix)", "C3 页按原因给恢复提示")
        XCTAssertTrue(task.status(outline: nil).isOpen, "C3 页能看到、能「继续这个种子任务」")

        let model = SeedModel()
        standard(model)
        let blocked = await CatalogSession(job: job(model, blocked: "本机模型没下")).resumeSeed(created.id)
        XCTAssertEqual(blocked.failures.count, 1)
        XCTAssertTrue(model.backend.requests.isEmpty, "所选模型用不了就不问别的模型")
        XCTAssertNil(tasks.load(created.id)?.modelKey)

        let later = await CatalogSession(job: job(model)).resumeSeed(created.id)
        XCTAssertEqual(later.failures, [], later.summary)
        XCTAssertNotNil(outline(created.id), "配好模型再继续：照常出目录等批")
        XCTAssertEqual(tasks.load(created.id)?.modelKey, "remote:test-credential/fake-model")
    }

    func testTheSameTaskIdIsCreatedOnceAndKeepsTheFirstAnswers() async throws {
        let id = UUID().uuidString
        _ = try await create(id)
        let again = try await create(id, answers: CatalogSurvey.answers(["阿白", "", ""]))
        XCTAssertEqual(again.outcome, .started)
        XCTAssertEqual(tasks.all().count, 1)
        XCTAssertEqual(tasks.load(id)?.answers, answers, "重复回调不覆盖、不多建")
        let runs = try FileManager.default.contentsOfDirectory(atPath: wiki.root.appendingPathComponent(".runs").path)
        XCTAssertEqual(runs.count, 1)
    }

    // MARK: - 不动别的数据

    func testSurveyLeavesOtherWikiDataAndOldSeedStateAlone() async throws {
        try wiki.save(WikiPage(path: "地点/云桥城", kind: .place, hook: "提到云桥城", title: "云桥城", now: "云桥城有座旧码头。"))
        let manual = WikiProposal(origin: .manual, createdAt: Date(), items: [.init(change: .newPage(page: WikiPage(path: "主题/面包", title: "面包")))])
        try store.save(manual)
        try WikiStore.writeAtomic(Data(#"{"completedAt":0}"#.utf8), to: CatalogSeed.stateURL(wiki))
        let pageBefore = try Data(contentsOf: wiki.root.appendingPathComponent("地点/云桥城.md"))

        let model = SeedModel()
        standard(model)
        let created = try await create()
        _ = await CatalogSession(job: job(model)).resumeSeed(created.id)
        try await approve(created.id)
        _ = await CatalogSession(job: job(model)).resumeSeed(created.id)

        XCTAssertEqual(try Data(contentsOf: wiki.root.appendingPathComponent("地点/云桥城.md")), pageBefore)
        XCTAssertEqual(store.load(manual.id)?.items, manual.items, "别的提案原样")
        XCTAssertTrue(CatalogSeed.isLegacyState(wiki: wiki), "三问不跑清旧种子")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("记忆备份").path), "三问不做备份搬迁")
    }
}

/// 第 11 段返工：真的 CatalogRunner.survey 入口判「现在能不能生成」——桥接卡不要钥匙；关着的按原因延期。只记排队，不真发请求
@MainActor
final class CatalogSurveyRunnerTests: XCTestCase {
    private let pid = "xctest-catalog-survey-runner"
    private var suite = ""
    private var defaults: UserDefaults!
    private var providers: ProviderManager!
    /// 运行器只弱引用楼层管理器：测试自己拿着
    private var profiles: ProfileManager!
    private var credentialId = ""
    private var runner: CatalogRunner!
    private var queued: [String] = []

    override func setUp() async throws {
        suite = "CatalogSurveyRunnerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let schema = Schema([Conversation.self, MessageNode.self, WorldBook.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let floor = Profile(id: pid, name: "三问楼层", emoji: "🌿", description: "", userName: "阿青", assistantName: "阿洛", systemPrompt: "")
        profiles = ProfileManager(container: container, profiles: [floor], currentProfile: floor, loadError: nil,
                                      root: FileManager.default.temporaryDirectory.appendingPathComponent("survey-runner-\(UUID().uuidString)"),
                                      defaults: defaults, sideEffectsEnabled: false)
        credentialId = "xctest-survey-bridge-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "bridge-model", name: "桥接模型")
        providers = ProviderManager()
        providers.addCredential(APICredential(id: credentialId, name: "桥接测试", emoji: "🌉", type: .ccBridge,
                                              baseURL: "http://127.0.0.1:9", models: [model]))
        defaults.set(model.id, forKey: CatalogModelRoute.key)
        runner = CatalogRunner(defaults: defaults)
        runner.attach(profileManager: profiles, providerManager: providers)
        queued = []
    }

    override func tearDown() async throws {
        providers.removeCredential(id: credentialId)
        defaults.removePersistentDomain(forName: suite)
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    private func survey() async -> (taskId: String, outcome: CatalogSurvey.Outcome) {
        let taskId = UUID().uuidString
        let outcome = await runner.survey(CatalogSurvey.answers(["阿青", "在学日语", ""]), taskId: taskId, profileId: pid) { [weak self] id, _ in
            self?.queued.append(id)
        }
        return (taskId, outcome)
    }

    private func task(_ id: String) async -> CatalogSeedTask? {
        let pid = pid
        return await Task.detached { CatalogSeedTaskStore(wiki: WikiStore(profileId: pid)).load(id) }.value
    }

    func testBridgeModelWithoutAKeyStartsRightAway() async throws {
        XCTAssertFalse(providers.hasKey(for: credentialId), "桥接卡没有钥匙")
        let r = await survey()
        XCTAssertEqual(r.outcome, .started)
        XCTAssertEqual(queued, [r.taskId], "能跑就排队")
        let saved = await task(r.taskId)
        XCTAssertEqual(saved?.state, .reading)
        XCTAssertNil(saved?.note)
    }

    func testClosedSwitchesDeferWithTheirOwnRecoveryHint() async throws {
        defaults.set(false, forKey: "mem_write_c3")
        let c3 = await survey()
        XCTAssertEqual(c3.outcome, .later(.c3Off))
        let c3Task = await task(c3.taskId)
        XCTAssertEqual(c3Task?.note, "还没生成：\(CatalogSurvey.Blocker.c3Off.reason)。\(CatalogSurvey.Blocker.c3Off.fix)")
        XCTAssertTrue(XiaoyaScriptLines.surveyResult(c3.outcome).contains("把 C3 打开"), "小芽说清楚先打开 C3，不说「配好模型」")

        defaults.set(true, forKey: "mem_write_c3")
        defaults.set(false, forKey: "mem_master")
        let master = await survey()
        XCTAssertEqual(master.outcome, .later(.memoryOff))
        XCTAssertTrue(XiaoyaScriptLines.surveyResult(master.outcome).contains("记忆总开关"))
        XCTAssertTrue(queued.isEmpty, "关着不排队")
    }
}
