import XCTest
import SwiftData
@testable import 记忆花园

/// 假模型：不看提示词文案，直接看盘上的任务状态作答——清单里没读的都 read；没目录就交目录；
/// 已批、还没交正文的目录项逐页交（按路径从 pages 取条目）。请求超过 limit 次就报错，测试不会挂死
@MainActor
final class SeedModel {
    var wiki: WikiStore!
    var outline: [[String: Any]] = []
    var pages: [String: [[String: Any]]] = [:]
    var emptyReason: String?
    /// 先回几次纯文字（不调工具）
    var textFirst = 0
    var limit = 80
    /// 第 n 次请求直接失败（服务商原话）
    var fail: (Int) -> String? = { _ in nil }
    /// 第 n 次请求交页时换一套条目（nil = 用 pages）
    var pageOverride: (Int) -> [String: [[String: Any]]]? = { _ in nil }
    /// 第 n 次请求交页的参数是坏 JSON
    var badPageArgs: (Int) -> Bool = { _ in false }
    /// 交页时另带的字段（coverage / preservation）
    var pageExtra: [String: Any] = [:]
    /// 写正文那段对话里第 n 次请求直接这样回（nil = 照常交页）
    var pageEvent: (Int, String) -> AssistantBackendEvent? = { _, _ in nil }
    private(set) var lastCalls: [ToolCallBlock] = []
    lazy var backend = FakeCatalogBackend { [unowned self] n, request in self.reply(n, request) }

    static func args(_ call: ToolCallBlock) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
    }

    static func call(_ name: String, _ args: [String: Any]) -> ToolCallBlock {
        let data = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
        return CatalogTestKit.call(name, String(decoding: data, as: UTF8.self))
    }

    /// 写正文那段对话的开场里写着这一页的 item
    static func pageItem(_ request: AssistantBackendRequest) -> String? {
        guard let opening = request.history.first?.content, let r = opening.range(of: "【这一页】item=") else { return nil }
        return String(opening[r.upperBound...].prefix { $0 != " " })
    }

    func reply(_ n: Int, _ request: AssistantBackendRequest) -> AssistantBackendEvent? {
        if n > limit { return .failed("假模型：请求太多") }
        if let message = fail(n) { return .failed(message) }
        if textFirst > 0 {
            textFirst -= 1
            return .finished("我先想想")
        }
        guard let task = CatalogSeedTaskStore(wiki: wiki).all().first else { return .failed("假模型：没有任务") }
        let calls = request.toolTurns.flatMap(\.calls)
        let read = Set(calls.filter { $0.name == "read" }.compactMap { Self.args($0)["path"] as? String })
        let unread = task.materials.map(\.path).filter { !read.contains($0) }
        let out: [ToolCallBlock]
        if let page = Self.pageItem(request), let saved = WikiProposalStore(wiki: wiki).load(task.id) {
            // 写正文：每项单开一段对话，只交开场里那一项
            guard let item = saved.items.first(where: { $0.id == page }), let d = item.change.direction else { return .failed("假模型：没有这一项") }
            if let event = pageEvent(n, item.id) { return event }
            let pages = pageOverride(n) ?? self.pages
            out = [badPageArgs(n) ? CatalogTestKit.call("submit_proposal", "{\"phase\":\"page\",\"item\":\"\(item.id)\",\"items\":[")
                : Self.call("submit_proposal", (["phase": "page", "item": item.id, "items": pages[d.path] ?? []] as [String: Any]).merging(pageExtra) { a, _ in a })]
        } else if !unread.isEmpty {
            out = unread.map { Self.call("read", ["path": $0]) }
        } else if let saved = WikiProposalStore(wiki: wiki).load(task.id) {
            let pages = pageOverride(n) ?? self.pages
            let bad = badPageArgs(n)
            out = CatalogSeedTask.unwritten(saved).compactMap { item in
                item.change.direction.map {
                    bad ? CatalogTestKit.call("submit_proposal", "{\"phase\":\"page\",\"item\":\"\(item.id)\",\"items\":[")
                        : Self.call("submit_proposal", (["phase": "page", "item": item.id, "items": pages[$0.path] ?? []] as [String: Any]).merging(pageExtra) { a, _ in a })
                }
            }
        } else {
            var args: [String: Any] = ["phase": "outline", "outline": outline]
            if let emptyReason { args["reason"] = emptyReason }
            out = [Self.call("submit_proposal", args)]
        }
        lastCalls = out
        return out.isEmpty ? .finished("没什么要写") : .toolCalls(out)
    }
}

@MainActor
private final class Gate {
    var release: CheckedContinuation<Void, Never>?
}

@MainActor
private final class Counter {
    var value = 0
    func bump() { value += 1 }
}

private final class Box: @unchecked Sendable {
    var count = 0
    var failAt: Int?
    var rollbackFails = false
}

@MainActor
private func XCTAssertThrowsErrorAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await body()
        XCTFail("应该抛错", file: file, line: line)
    } catch {}
}

@MainActor
final class CatalogSeedTaskTests: XCTestCase {
    private let pid = "xctest-catalog-seedtask"
    /// 记忆根放在临时夹的子目录里：「记忆备份」建在它旁边，不碰系统临时目录
    private var base: URL!
    private var root: URL!
    private var container: ModelContainer!
    private var wiki: WikiStore { WikiStore(root: root.appendingPathComponent("wiki")) }
    private var store: WikiProposalStore { WikiProposalStore(wiki: wiki) }
    private var tasks: CatalogSeedTaskStore { CatalogSeedTaskStore(wiki: wiki) }
    private let slotPath = PromptFolder.path(for: .slot(presetId: "preset-1", slotId: "custom-slot"))
    private let tailFact = "尾部事实：阿青养了一只叫纸鸢的猫"

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-seedtask-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("memory", isDirectory: true)
        container = try ModelContainer(for: Memory.self, Conversation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        container = nil
    }

    // MARK: - 夹具（全是虚构）

    private func cc(_ name: String, type: String, title: String, body: String) throws {
        let dir = root.appendingPathComponent("cc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(title)\ntype: \(type)\n---\n\(body)".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private var longSlot: String { String(repeating: "设定填充。", count: 700) + tailFact }

    private func job(_ model: SeedModel, deps: CatalogAgent.Deps? = nil) -> CatalogJob {
        model.wiki = wiki
        var j = CatalogTestKit.job(pid: pid, root: root, container: container, backend: model.backend)
        j.floorBase = CatalogFloorBase(sections: [.init(path: slotPath, name: "自建槽", text: longSlot, isEnabled: true)])
        j.seedModel = "remote:test-credential/fake-model"
        j.seedDeps = deps
        return j
    }

    private func newPage(_ path: String, _ kind: String, _ title: String, _ text: String, _ sources: [String]) -> [[String: Any]] {
        [["type": "new_page", "path": path, "kind": kind, "title": title, "now": text,
          "records": [["text": "日期未注明 " + text, "sources": sources]]]]
    }

    private func entry(_ path: String, _ kind: String, _ title: String, _ sources: [String]) -> [String: Any] {
        ["path": path, "kind": kind, "title": title, "hook": "提到\(title)的时候先看这页", "sources": sources]
    }

    private func seedOutline() -> WikiProposal? {
        store.list().first { CatalogSeedDrafts.isOutline($0) }
    }

    private func contents(_ id: String) -> [WikiProposal] {
        store.list().filter { $0.directionRef?.proposalId == id && $0.id != id }
    }

    private func item(_ outline: WikiProposal, _ title: String) -> WikiProposal.Item {
        outline.items.first { $0.change.direction?.title == title }!
    }

    private func approve(_ id: String, _ items: Set<String>? = nil) async throws {
        try await WikiProposalReview.approve(id, itemIds: items, store: store, profileId: pid, context: ModelContext(container))
    }

    private func reject(_ id: String, _ items: Set<String>? = nil) async throws {
        try await WikiProposalReview.reject(id, itemIds: items, store: store, context: ModelContext(container))
    }

    private func readCalls(_ model: SeedModel) -> [String] {
        model.backend.requests.last?.toolTurns.flatMap(\.calls).filter { $0.name == "read" }.compactMap { SeedModel.args($0)["path"] as? String } ?? []
    }

    private func sent(_ model: SeedModel) -> String {
        model.backend.requests.map { r in (r.history.map(\.content) + r.toolTurns.flatMap(\.results).map(\.text)).joined() }.joined()
    }

    /// 四份原料：两份 user 同说阿青（合一页）、一份 project 讲两件事（拆两页）、wiki 已有一页（只能更新）
    private func standardFixture(_ model: SeedModel) throws {
        try cc("user_a.md", type: "user", title: "阿青的作息", body: "阿青每天早上七点去码头看船。")
        try cc("user_b.md", type: "user", title: "阿青的爱好", body: "阿青收集《灯塔航线》的纸质海图。")
        try cc("project_c.md", type: "project", title: "两个项目", body: "纸舟是离线阅读工具。灯塔是天气小组件。")
        try cc("feedback_x.md", type: "feedback", title: "回复风格", body: "FEEDBACK_ONLY_MARKER 回答先给结论")
        try cc("private_y.md", type: "user", title: "私密", body: "PRIVATE_ONLY_MARKER")
        try wiki.save(WikiPage(path: "楼层/地点/云桥城", kind: .place, hook: "提到云桥城", title: "云桥城", now: "云桥城有座旧码头。"))
        model.outline = [
            entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md", "memory/cc/user_b.md", slotPath]),
            entry("工程/项目/纸舟", "项目", "纸舟", ["memory/cc/project_c.md"]),
            entry("工程/项目/灯塔", "项目", "灯塔", ["memory/cc/project_c.md"]),
            entry("楼层/地点/云桥城", "地点", "云桥城", ["memory/wiki/楼层/地点/云桥城.md", "memory/cc/user_a.md"]),
        ]
        model.pages = [
            "楼层/人/阿青": newPage("楼层/人/阿青", "人", "阿青", "阿青每天早上七点去码头看船，收集纸质海图，养了猫纸鸢",
                                  ["memory/cc/user_a.md", "memory/cc/user_b.md", slotPath]),
            "工程/项目/纸舟": newPage("工程/项目/纸舟", "项目", "纸舟", "纸舟是离线阅读工具", ["memory/cc/project_c.md"]),
            "工程/项目/灯塔": newPage("工程/项目/灯塔", "项目", "灯塔", "灯塔是天气小组件", ["memory/cc/project_c.md"]),
            "楼层/地点/云桥城": [["type": "append", "path": "楼层/地点/云桥城",
                                "records": [["text": "日期未注明 阿青每天早上去云桥城码头看船", "sources": ["memory/cc/user_a.md"]],
                                            ["text": "没出处的一行", "sources": ["memory/cc/不存在.md"]]]]],
        ]
    }

    // MARK: - 一个 agent：全读一次 → 目录暂停 → 同任务逐页写 → 正文再批 → 完成按整份目录

    func testOneTaskReadsOnceOutlinePausesWritesApprovedPagesAndCompletesByWholeOutline() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let pagesBefore = wiki.pagePaths()

        let first = await CatalogSession(job: job(model)).seed(entry: .persona)
        XCTAssertEqual(first.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(outline.items.count, 4)
        XCTAssertTrue(outline.items.allSatisfy { $0.state == .pending && $0.change.direction?.mode == .seed })
        XCTAssertEqual(item(outline, "阿青").change.direction?.sources, ["memory/cc/user_a.md", "memory/cc/user_b.md", slotPath], "两份 user 文件和 Prompt 合一页")
        XCTAssertEqual(item(outline, "云桥城").change.direction?.action, .update)
        XCTAssertNotNil(outline.run)
        XCTAssertEqual(store.list().count, 1, "目录批之前没有正文提案")
        XCTAssertEqual(wiki.pagePaths(), pagesBefore)
        let task = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertEqual(task.modelKey, "remote:test-credential/fake-model")
        let materials = task.materials.map(\.path)
        XCTAssertTrue(materials.contains("memory/wiki/INDEX.md"))
        XCTAssertTrue(materials.contains("memory/wiki/楼层/地点/INDEX.md"), "下层分组索引也是原料")
        let requestsAfterOutline = model.backend.requests.count
        let opening = try XCTUnwrap(model.backend.requests.first?.history.first?.content)
        XCTAssertTrue(opening.contains("跳过 1 份私人文件（private_）"))
        for marker in ["PRIVATE_ONLY_MARKER", "private_y.md"] { XCTAssertFalse(sent(model).contains(marker), marker) }
        XCTAssertTrue(materials.contains("memory/cc/feedback_x.md"), "feedback 不按类型扔，交给模型按内容分")
        XCTAssertTrue(sent(model).contains("FEEDBACK_ONLY_MARKER"))
        let readResults = model.backend.requests.last?.toolTurns.flatMap(\.results).map(\.text) ?? []
        XCTAssertTrue(readResults.contains { $0.contains(longSlot) }, "Prompt 自建槽 3000 字之后的事实完整进了实际请求")
        XCTAssertEqual(readCalls(model).sorted(), materials.sorted(), "每份只读一次")

        let aqing = item(outline, "阿青").id, paper = item(outline, "纸舟").id
        try await approve(outline.id, [aqing, paper])
        XCTAssertEqual(model.backend.requests.count, requestsAfterOutline, "批之前、批这一步本身都不调模型")
        let second = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(second.failures, [])
        let resumed = model.backend.requests[requestsAfterOutline]
        XCTAssertEqual(resumed.history.count, 1, "写正文每页单开一段对话：只有这一页的开场")
        XCTAssertTrue(resumed.toolTurns.isEmpty, "出目录那段的回合（全部 read 回执）不回灌")
        let pageOpening = resumed.history[0].content
        XCTAssertTrue(pageOpening.contains("【这一页】item=\(aqing)"))
        for kept in ["阿青每天早上七点去码头看船。", "阿青收集《灯塔航线》的纸质海图。", tailFact, "楼层/地点/云桥城", "工程/项目/纸舟"] {
            XCTAssertTrue(pageOpening.contains(kept), "这一项的原料全文（read 回执那一版）+ 整份目录：\(kept)")
        }
        for dropped in ["纸舟是离线阅读工具", "FEEDBACK_ONLY_MARKER", "云桥城有座旧码头", "PRIVATE_ONLY_MARKER"] {
            XCTAssertFalse(pageOpening.contains(dropped), "别的原料不进这一页：\(dropped)")
        }
        let pageRequests = model.backend.requests[requestsAfterOutline...]
        XCTAssertTrue(pageRequests.allSatisfy { $0.toolTurns.flatMap(\.calls).allSatisfy { $0.name != "read" } }, "批后不重读原料")
        XCTAssertTrue(pageRequests.allSatisfy { $0.tools.count == 1 }, "写正文只给交页的工具")
        XCTAssertEqual(pageRequests.count, 2, "两页各一段对话、各一轮")
        XCTAssertTrue(pageRequests.last?.history[0].content.contains("【这一页】item=\(paper)") ?? false)
        var pages = contents(outline.id)
        XCTAssertEqual(Set(pages.compactMap(\.title)), ["阿青", "纸舟"], "只写获批的项")
        XCTAssertNil(CatalogSeed.completion(wiki: wiki), "剩下目录还待批，不完成")
        XCTAssertEqual(wiki.pagePaths(), pagesBefore, "正文没批不落页")
        let aqingContent = try XCTUnwrap(pages.first { $0.title == "阿青" })
        guard case .newPage(let page) = aqingContent.items[0].change else { return XCTFail() }
        XCTAssertEqual(page.records, ["日期未注明 阿青每天早上七点去码头看船，收集纸质海图，养了猫纸鸢（出处：CC memory/cc/user_a.md；CC memory/cc/user_b.md；Prompt 自建槽）"])
        XCTAssertEqual(page.kind, .person)
        XCTAssertEqual(page.hook, "提到阿青的时候先看这页")

        try await approve(aqingContent.id)
        XCTAssertTrue(wiki.pageExists("楼层/人/阿青"), "第二批批了才写进 wiki")

        let refreshed = try XCTUnwrap(seedOutline())
        try await reject(refreshed.id, [item(refreshed, "灯塔").id])
        try await approve(refreshed.id, [item(refreshed, "云桥城").id])
        let third = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(third.failures, [])
        pages = contents(outline.id)
        let cloud = try XCTUnwrap(pages.first { $0.title == "云桥城" })
        XCTAssertEqual(cloud.items.map(\.change.kindLabel), ["追加记录", "改钩子 / 触发词"], "已有页只出更新；目录定的钩子补一条改钩子")
        guard case .appendRecords(_, let lines) = cloud.items[0].change else { return XCTFail() }
        XCTAssertEqual(lines, ["日期未注明 阿青每天早上去云桥城码头看船（出处：CC memory/cc/user_a.md）"], "坏出处那行进不了提案")
        let done = try XCTUnwrap(CatalogSeed.completion(wiki: wiki), "目录处理完、获批页都交了正文 = 完成（正文还待批也算）")
        XCTAssertEqual(done.taskId, outline.id)
        XCTAssertEqual(tasks.load(outline.id)?.state, .complete)

        MemoryWriteLog.flush()
        let runs = try FileManager.default.contentsOfDirectory(atPath: wiki.root.appendingPathComponent(".runs").path)
        XCTAssertEqual(runs.count, 1, "批了接着写同一份整理记录：\(runs)")
        let runText = try String(contentsOf: wiki.root.appendingPathComponent(".runs/" + runs[0]), encoding: .utf8)
        let logs = MemoryWriteLog.entries(profileId: pid).filter { $0.note.hasPrefix("种子 · 第") }
        XCTAssertFalse(logs.isEmpty)
        for log in logs {
            let link = try XCTUnwrap(log.run)
            XCTAssertEqual(link.path, ".runs/" + runs[0])
            XCTAssertTrue(runText.contains("<a id=\"\(try XCTUnwrap(link.anchor))\"></a>"), "每轮日志点开到这一轮")
        }
    }

    // MARK: - 存储：本任务的目录和正文都在 .proposals/<任务 id>/，旧的顶层提案照样能读

    /// 第八类「用户」：她本人的页挂在 楼层/{用户}/ 下，目录照收（不预设子页）
    func testOutlineAcceptsTheUserKind() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let mine = "楼层/\(CatalogTestKit.names.user)/作息"
        model.outline.append(entry(mine, "用户", "作息", ["memory/cc/user_a.md"]))

        let report = await CatalogSession(job: job(model)).seed(entry: .persona)

        XCTAssertEqual(report.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        let d = try XCTUnwrap(outline.items.compactMap(\.change.direction).first { $0.path == mine })
        XCTAssertEqual(d.kind, .user)
    }

    func testSeedProposalsLiveInTheTaskFolderAndOldTopLevelOnesStillLoad() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id, [item(outline, "纸舟").id])
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let folder = wiki.root.appendingPathComponent(".proposals/\(outline.id)")
        let content = try XCTUnwrap(contents(outline.id).first)
        for id in [outline.id, content.id] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(id + ".json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: wiki.root.appendingPathComponent(".proposals/\(id).json").path))
        }
        let old = WikiProposal(origin: .manual, createdAt: Date(), items: [.init(change: .newPage(page: WikiPage(path: "楼层/主题/面包", title: "面包")))])
        try store.save(old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wiki.root.appendingPathComponent(".proposals/\(old.id).json").path))
        XCTAssertEqual(store.load(old.id)?.items, old.items)
        XCTAssertEqual(Set(store.list().map(\.id)), [outline.id, content.id, old.id])
        try await approve(content.id)
        XCTAssertTrue(wiki.pageExists("工程/项目/纸舟"), "任务文件夹里的正文照常批")
    }

    // MARK: - 失败 / 停 / 重启续跑、上下文超长

    func testFailureAndStopAreNotCompleteAndRestartContinuesSameTask() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id)
        let before = model.backend.requests.count
        model.fail = { n in n == before + 1 ? "网关超时 504" : nil }
        let failed = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(failed.failures.count, 1)
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
        XCTAssertEqual(tasks.load(outline.id)?.state, .stopped)
        model.fail = { _ in nil }

        let session = CatalogSession(job: job(model))
        session.onProgress = { _, round in if round > 0 { session.cancel() } }
        let stopped = await session.resumeSeed(outline.id)
        XCTAssertTrue(stopped.cancelled)
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))

        let restarted = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(restarted.failures, [])
        XCTAssertEqual(contents(outline.id).count, 4)
        XCTAssertNotNil(CatalogSeed.completion(wiki: wiki))
        XCTAssertTrue(model.backend.requests[before...].allSatisfy { $0.toolTurns.flatMap(\.calls).allSatisfy { $0.name != "read" } }, "重启续跑不重读")
        let again = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(again.skipped, "这个种子任务不在了，或已经结束")
        XCTAssertEqual(contents(outline.id).count, 4, "重复点不重复交")
    }

    func testStopRightAfterTheLastPageDoesNotComplete() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id, [item(outline, "纸舟").id])
        try await reject(outline.id)
        var session: CatalogSession!
        let deps = CatalogAgent.Deps(makeBackend: { model.backend }, gate: { _ in nil }, roundTurn: { _ in
            if model.lastCalls.contains(where: { SeedModel.args($0)["phase"] as? String == "page" }) { session.cancel() }
            return nil
        })
        session = CatalogSession(job: job(model, deps: deps))
        let report = await session.resumeSeed(outline.id)
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(contents(outline.id).count, 1, "最后一页交上了")
        XCTAssertNil(CatalogSeed.completion(wiki: wiki), "交完最后一页就点了停 = 不是正常结束，不记完成")
        XCTAssertNotEqual(tasks.load(outline.id)?.state, .complete)
        let settled = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(settled.failures, [])
        XCTAssertNotNil(CatalogSeed.completion(wiki: wiki), "再点继续，正常结束后才记完成")
    }

    private func assertCancelDuringCompletionMarker(afterWrite: Bool) async throws {
        let model = SeedModel()
        model.outline = [entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md"])]
        model.pages = ["楼层/人/阿青": newPage("楼层/人/阿青", "人", "阿青", "阿青喜欢海图", ["memory/cc/user_a.md"])]
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        let previous = Date(timeIntervalSince1970: 1_800_000_000)
        try CatalogSeed.finish(wiki: wiki, at: previous, taskId: UUID().uuidString)
        _ = await CatalogSession(job: job(model)).seed()
        let id = try XCTUnwrap(seedOutline()).id
        try await approve(id)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let reached = expectation(description: afterWrite ? "完成标记已写入" : "完成标记写入前")
        let release = DispatchSemaphore(value: 0)
        let session = CatalogSession(job: job(model), finishSeed: { wiki, date, task in
            if !afterWrite {
                reached.fulfill()
                release.wait()
            }
            try CatalogSeed.finish(wiki: wiki, at: date, taskId: task)
            if afterWrite {
                reached.fulfill()
                release.wait()
            }
        })
        let running = Task { await session.resumeSeed(id, now: now) }
        await fulfillment(of: [reached], timeout: 5)
        session.cancel()
        release.signal()
        let report = await running.value
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(CatalogSeed.completion(wiki: wiki)?.at, previous, "完成标记恢复原样")
        XCTAssertNotEqual(tasks.load(id)?.state, .complete, "任务快照退回没完成")
        XCTAssertEqual(contents(id).count, 1)
    }

    func testCancelBeforeCompletionMarkerWriteRestoresPreviousState() async throws {
        try await assertCancelDuringCompletionMarker(afterWrite: false)
    }

    func testCancelAfterCompletionMarkerWriteRestoresPreviousState() async throws {
        try await assertCancelDuringCompletionMarker(afterWrite: true)
    }

    func testPersistenceFailuresDoNotCompleteOrAskTheModel() async throws {
        let model = SeedModel()
        model.outline = [entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md"])]
        model.pages = ["楼层/人/阿青": newPage("楼层/人/阿青", "人", "阿青", "阿青喜欢海图", ["memory/cc/user_a.md"])]
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        try Data("不是文件夹".utf8).write(to: wiki.root.appendingPathComponent(WikiStore.proposalsFolder))
        let blocked = await CatalogSession(job: job(model)).seed()
        XCTAssertTrue(blocked.failures.first?.hasPrefix("种子任务没存成，没开始问模型") ?? false, "\(blocked.failures)")
        XCTAssertEqual(model.backend.requests.count, 0, "任务存不上就不发付费请求")
        try FileManager.default.removeItem(at: wiki.root.appendingPathComponent(WikiStore.proposalsFolder))

        _ = await CatalogSession(job: job(model)).seed()
        let id = try XCTUnwrap(seedOutline()).id
        try await approve(id)
        try FileManager.default.createDirectory(at: CatalogSeed.stateURL(wiki), withIntermediateDirectories: true)
        let report = await CatalogSession(job: job(model)).resumeSeed(id)
        XCTAssertTrue(report.failures.contains { $0.hasPrefix("完成标记没写上") }, "\(report.failures)")
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
        XCTAssertNotEqual(tasks.load(id)?.state, .complete, "标记没写上，快照也不记完成")
    }

    func testCancelBeforeAnythingSendsNoRequestAndKeepsPreviousCompletion() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let previous = Date(timeIntervalSince1970: 1_800_000_000)
        try CatalogSeed.finish(wiki: wiki, at: previous, taskId: UUID().uuidString)
        let session = CatalogSession(job: job(model))
        session.cancel()
        let report = await session.seed()
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(model.backend.requests.count, 0)
        XCTAssertEqual(CatalogSeed.completion(wiki: wiki)?.at, previous)
    }

    func testPrivateNamesStayOutOfProposalsLogsRunRecordAndRequests() async throws {
        let model = SeedModel()
        try standardFixture(model)
        for name in ["private_x.md", "PRIVATE_diary_key.md", "Private_z.md"] {
            try cc(name, type: "user", title: "私密", body: "PRIVATE_BODY_MARKER")
        }
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id)
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        MemoryWriteLog.flush()
        let logs = MemoryWriteLog.entries(profileId: pid).map(\.note)
        XCTAssertTrue(logs.contains { $0.contains("跳过 4 份私人文件（private_）") })
        let run = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(XCTUnwrap(outline.run), wiki: wiki)), encoding: .utf8)
        let proposals = String(decoding: try JSONEncoder().encode(store.list()), as: UTF8.self)
        let checkpoint = String(decoding: try JSONEncoder().encode(tasks.load(outline.id)), as: UTF8.self)
        for artifact in [sent(model), logs.joined(), run, proposals, checkpoint] {
            for leak in ["private_x.md", "PRIVATE_diary_key.md", "Private_z.md", "private_y.md", "PRIVATE_BODY_MARKER", "PRIVATE_ONLY_MARKER"] {
                XCTAssertFalse(artifact.contains(leak), leak)
            }
        }
    }

    func testContextTooLongShowsPlainWordsWithProviderTextAndIsNotComplete() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let raw = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long: 250000 tokens > 200000 maximum\"}}"
        model.fail = { n in n == 1 ? raw : nil }
        let report = await CatalogSession(job: job(model)).seed()
        let note = try XCTUnwrap(report.failures.first)
        XCTAssertTrue(note.hasPrefix("出目录这一轮要一次读完全部原料，加起来超过 假模型 一次能读的长度（约 200000 token），种子还没完成"), note)
        XCTAssertTrue(note.contains(raw), "附服务商原文")
        XCTAssertFalse(note.contains("上下文深度"), "不给聊天那套建议")
        XCTAssertNil(seedOutline())
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
        XCTAssertEqual(model.backend.requests.count, 1, "不自动换模型、不分批重试")
        let task = try XCTUnwrap(tasks.all().first, "首次付费请求前任务已经存下")
        XCTAssertEqual(task.status(outline: nil), .reading, "能续跑")
        let resumed = await CatalogSession(job: job(model)).resumeSeed(task.id)
        XCTAssertEqual(resumed.failures, [])
        XCTAssertEqual(tasks.all().count, 1, "续的是同一个任务")
        XCTAssertNotNil(seedOutline())
    }

    /// 一页的原料本身就超过模型上下文：照实报（种子自己的说法，不是聊天那套「调上下文深度」），不裁原料、不记完成，这一页的对话留着能续
    func testPageWhoseMaterialsAreTooLongFailsWithSeedWordsAndKeepsThePage() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id, [item(outline, "阿青").id])
        let before = model.backend.requests.count
        let chat = "对话太长了，超过这个模型一次能读的长度。把预设里的「上下文深度」调小，或先压缩一下上下文。原文：prompt is too long: 201605 tokens > 200000 maximum（api.anthropic.com · claude-haiku-4-5 · HTTP 400）"
        model.fail = { n in n > before ? chat : nil }
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let note = try XCTUnwrap(report.failures.first)
        XCTAssertTrue(note.hasPrefix("「阿青」这一页列的原料太长，超过 假模型 一次能读的长度（约 200000 token），这一页还没写"), note)
        XCTAssertTrue(note.contains("可以放弃这个种子任务，重新播种时在目录批之前给这一项少列几份原料，或先在 C3 设置里换上下文更大的模型再重新播种"), note)
        XCTAssertTrue(note.contains("服务商原话：prompt is too long: 201605 tokens > 200000 maximum"))
        XCTAssertFalse(note.contains("上下文深度"))
        XCTAssertEqual(model.backend.requests.count, before + 1, "不裁原料重试")
        XCTAssertTrue(model.backend.requests[before].history[0].content.contains(tailFact), "原料没有被悄悄裁掉")
        let task = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertEqual(task.page?.item, item(outline, "阿青").id, "这一页的对话留着")
        XCTAssertEqual(task.status(outline: seedOutline()), .writable(1))
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))

        // 报错里给的路真走得通：原任务换模型续不了；放弃 → 换了模型重新播种 → 新目录批之前能给这一项少列几份原料
        model.fail = { _ in nil }
        var bigger = job(model)
        bigger.seedModel = "remote:test-credential/bigger-model"
        let switched = await CatalogSession(job: bigger).resumeSeed(outline.id)
        XCTAssertTrue(switched.failures.first?.contains("种子不换模型") ?? false, "原任务绑了模型，换模型续不了")
        let abandoned = await CatalogSession(job: bigger).abandonSeed(outline.id)
        XCTAssertEqual(abandoned.failures, [])
        _ = await CatalogSession(job: bigger).seed()
        let reseeded = try XCTUnwrap(seedOutline())
        XCTAssertNotEqual(reseeded.id, outline.id)
        XCTAssertEqual(tasks.load(reseeded.id)?.modelKey, "remote:test-credential/bigger-model")
        let entry = try XCTUnwrap(CatalogSeedDrafts.entries(wiki: wiki).first { $0.kind == .outline(reseeded.id) })
        let trimmed = entry.content.replacingOccurrences(of: "- memory/cc/user_b.md\n", with: "")
        XCTAssertNotEqual(trimmed, entry.content)
        try await CatalogSeedDrafts.save(entry, text: trimmed, baseline: entry.content, wiki: wiki)
        XCTAssertFalse(item(try XCTUnwrap(seedOutline()), "阿青").change.direction?.sources?.contains("memory/cc/user_b.md") ?? true, "批之前能给这一项少列原料")
    }

    /// 旧格式 checkpoint（批完接着同一段对话写、没有 page 字段，history 里有旧的控制消息、turns 里有旧的写页回合）：
    /// 点「继续」按新方式写——旧 history 只拿来取 read 回执，不整段回灌
    func testLegacyCheckpointResumesWithPerPageConversation() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let aqing = item(outline, "阿青").id
        try await approve(outline.id, [aqing])
        var old = try XCTUnwrap(tasks.load(outline.id))
        old.history.append(.init(role: "user", content: "（系统：粟粟批了目录。已批、待写：\n- item=\(aqing) · 楼层/人/阿青）"))
        old.turns.append(.init(calls: [.init(id: "old-page", name: "submit_proposal", argumentsJSON: "{\"phase\":\"page\",\"item\":\"\(aqing)\",\"items\":[]}", truncated: false)],
                               results: [.init(toolUseId: "old-page", text: "「阿青」没有能用的条目", isError: true)]))
        old.state = .stopped
        old.note = "这次完整种子材料超出当前模型上下文，尚未完成（第 9 轮 · 模型 假模型）"
        let file = tasks.folder(outline.id).appendingPathComponent(CatalogSeedTaskStore.fileName)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.seedTaskForTest.encode(old)) as? [String: Any])
        json.removeValue(forKey: "page")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let legacy = try XCTUnwrap(tasks.load(outline.id), "旧格式照样能读")
        XCTAssertNil(legacy.page)
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        let request = model.backend.requests[before]
        XCTAssertEqual(request.history.count, 1)
        XCTAssertTrue(request.toolTurns.isEmpty, "旧的长 history / turns 不回灌")
        XCTAssertFalse(request.history[0].content.contains("（系统：粟粟批了目录"))
        XCTAssertTrue(request.history[0].content.contains("阿青每天早上七点去码头看船。"), "原料从旧回合的 read 回执里取")
        XCTAssertTrue(request.history[0].content.contains(tailFact))
        let content = try XCTUnwrap(contents(outline.id).first { $0.directionRef?.itemId == aqing })
        guard case .newPage(let page) = content.items[0].change else { return XCTFail() }
        XCTAssertEqual(page.records, ["日期未注明 阿青每天早上七点去码头看船，收集纸质海图，养了猫纸鸢（出处：CC memory/cc/user_a.md；CC memory/cc/user_b.md；Prompt 自建槽）"], "出处校验照旧")
        let after = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertEqual(after.history.count, old.history.count, "旧 history 原样留着，不再往里接")
        XCTAssertNil(after.page, "写完这一页清掉")
    }

    func testContextLimitAndProviderTextForSeedNotes() {
        XCTAssertEqual(CatalogSeedPrompts.contextLimit("prompt is too long: 201605 tokens > 200000 maximum"), 200000)
        XCTAssertEqual(CatalogSeedPrompts.contextLimit("This model's maximum context length is 128000 tokens"), 128000)
        XCTAssertNil(CatalogSeedPrompts.contextLimit("input is too long for requested model"))
        XCTAssertEqual(CatalogSeedPrompts.providerText("对话太长了。把预设里的「上下文深度」调小。原文：prompt is too long"), "prompt is too long")
        let note = CatalogSeedPrompts.pageContextNote(title: "阿青", round: 3, model: "M", raw: "input is too long for requested model")
        XCTAssertEqual(note, "「阿青」这一页列的原料太长，超过 M 一次能读的长度，这一页还没写（第 3 轮）。可以放弃这个种子任务，重新播种时在目录批之前给这一项少列几份原料，或先在 C3 设置里换上下文更大的模型再重新播种。服务商原话：input is too long for requested model")
        XCTAssertTrue(CatalogSeedPrompts.contextNote(round: 1, model: "M", raw: "x").contains("可以放弃这个种子任务，先在 C3 设置里换上下文更大的模型，再重新播种"))
    }

    // MARK: - astra 审 60f9ea823

    /// P1：要更新的已有页只认白名单里的 read 回执；链接到 private_ 的页没读过，不读盘补，明确停下
    func testUpdateTargetLinkedToPrivateFileIsNeverSent() async throws {
        let model = SeedModel()
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        try cc("private_x.md", type: "user", title: "私密", body: "PRIVATE_LINKED_MARKER")
        let dir = wiki.root.appendingPathComponent("楼层/人")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("秘密.md"), withDestinationURL: root.appendingPathComponent("cc/private_x.md"))
        model.outline = [entry("楼层/人/秘密", "人", "秘密", ["memory/cc/user_a.md"])]
        model.pages = ["楼层/人/秘密": [["type": "append", "path": "楼层/人/秘密", "records": [["text": "日期未注明 阿青喜欢海图", "sources": ["memory/cc/user_a.md"]]]]]]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(outline.items.first?.change.direction?.action, .update)
        try await approve(outline.id)
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let note = try XCTUnwrap(report.failures.first)
        XCTAssertTrue(note.contains("「秘密」要更新的已有页 楼层/人/秘密 不在这次读过的原料里"), note)
        XCTAssertEqual(model.backend.requests.count, before, "停在开对话之前，一个请求都没发")
        XCTAssertFalse(sent(model).contains("PRIVATE_LINKED_MARKER"))
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
    }

    /// P2：read 回执的参数解析和执行 read 时同一个（围栏包裹也认）；读过、版本不空却找不到正文 = checkpoint 不一致，不当成文件没了
    func testReadReceiptParsingMatchesExecutionAndMissingTextIsInconsistent() throws {
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .cc, modelName: "M", createdAt: Date(), run: .init(path: "x", anchor: nil))
        task.materials = [.init(path: "memory/cc/a.md", name: "a", layer: "CC", version: "v1"), .init(path: "memory/cc/b.md", name: "b", layer: "CC", version: "v2")]
        task.read = ["memory/cc/a.md": "v1", "memory/cc/b.md": "v2"]
        let fenced = "```json\n{\"path\":\"memory/cc/a.md\"}\n```"
        task.turns = [.init(calls: [.init(id: "r1", name: "read", argumentsJSON: fenced, truncated: false)],
                            results: [.init(toolUseId: "r1", text: "【memory/cc/a.md · CC · a】\n阿青喜欢海图。", isError: false)])]
        XCTAssertEqual(CatalogSeedTools.parse(fenced)?.path, "memory/cc/a.md")
        XCTAssertEqual(task.readText("memory/cc/a.md"), "阿青喜欢海图。", "围栏包裹的 read 也取得回回执")
        let d = WikiProposal.Direction(path: "楼层/人/阿青", title: "阿青", hook: "", kind: .person, action: .newPage, reason: "种子目录", mode: .seed,
                                       sources: ["memory/cc/a.md", "memory/cc/b.md"])
        let item = WikiProposal.Item(change: .direction(d))
        let outline = WikiProposal(id: task.id, origin: .seed, createdAt: Date(), title: "种子目录", items: [item])
        guard case .failure(let problem) = CatalogAgent.pageOpening(item, outline: outline, task: task) else { return XCTFail() }
        XCTAssertTrue(problem.note.hasPrefix("checkpoint 不一致：「阿青」列着的 memory/cc/b.md 读过"), problem.note)
        task.read["memory/cc/b.md"] = ""
        guard case .success(let page) = CatalogAgent.pageOpening(item, outline: outline, task: task) else { return XCTFail() }
        XCTAssertTrue(page.text.contains("阿青喜欢海图。"))
        XCTAssertTrue(page.text.contains("【memory/cc/b.md · CC · b】\n（这份读的时候已经不在了，不能当出处）"), "真没了才这样写")
    }

    private func pageSession(_ item: String, opening: String, pending: CatalogSeedTask.Turn? = nil) -> CatalogSeedTask.PageSession {
        .init(item: item, history: [.init(role: "user", content: opening)], turns: [], pending: pending)
    }

    /// P2：先对账处理还有效的 pending（不重新问模型）；别的目录项变了不重开这一页的对话
    func testPendingIsSettledFirstAndOtherItemsDoNotRestartThePage() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let aqing = item(outline, "阿青").id, paper = item(outline, "纸舟").id, lamp = item(outline, "灯塔").id
        try await approve(outline.id, [aqing, paper])
        var task = try XCTUnwrap(tasks.load(outline.id))
        let call = SeedModel.call("submit_proposal", ["phase": "page", "item": aqing, "items": model.pages["楼层/人/阿青"]!])
        task.page = pageSession(aqing, opening: "旧开场", pending: .init(calls: [.init(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON, truncated: false)], results: []))
        try tasks.save(task)
        try await approve(outline.id, [lamp])
        let before = model.backend.requests.count
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertNotNil(contents(outline.id).first { $0.directionRef?.itemId == aqing }, "收到、没处理完的那轮照现在的目录项处理掉")
        let asked = model.backend.requests[before...].compactMap(SeedModel.pageItem)
        XCTAssertFalse(asked.contains(aqing), "阿青那页不重新问模型")
        XCTAssertEqual(Set(asked), [paper, lamp])

        // 一页的对话停在半路（没有 pending），批了别的项：接着原来那段对话，不重开
        let refreshed = try XCTUnwrap(seedOutline())
        let cloud = item(refreshed, "云桥城").id
        var again = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertNil(again.page, "写完的页不留对话")
        model.outline = []
        again.state = .stopped
        try tasks.save(again)
        try await approve(outline.id, [cloud])
        var mid = try XCTUnwrap(tasks.load(outline.id))
        mid.page = pageSession(cloud, opening: "这一页原来的开场 · 【这一页】item=\(cloud) ·")
        try tasks.save(mid)
        let before2 = model.backend.requests.count
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(model.backend.requests[before2].history.first?.content, "这一页原来的开场 · 【这一页】item=\(cloud) ·", "旧会话（没有 key）接着用")
    }

    /// P2：这一页要重开时，第一稿和修改要求一起迁到新开场（新任务存了要求；旧 checkpoint 从回合里找回；找不回就清掉残留修订稿）
    func testRevisionDraftAndAsksMoveIntoTheNewOpening() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let aqing = item(outline, "阿青").id
        try await approve(outline.id, [aqing])
        var task = try XCTUnwrap(tasks.load(outline.id))
        task.revisionDrafts = [aqing: "{\"phase\":\"page\",\"item\":\"\(aqing)\",\"items\":[\"FIRST_DRAFT_MARKER\"]}"]
        task.revisionAsks = [aqing: "- 记录要写日期"]
        let snapshot = task
        XCTAssertEqual(CatalogAgent.revision(for: aqing, task: snapshot)?.asks, "- 记录要写日期")
        var legacy = task
        legacy.revisionAsks = nil
        legacy.turns.append(.init(calls: [.init(id: "old", name: "submit_proposal", argumentsJSON: "{\"phase\":\"page\",\"item\":\"\(aqing)\"}", truncated: false)],
                                  results: [.init(toolUseId: "old", text: "「阿青」这几处没过检查。只改这几处，别的照旧，整页重交：\n- 旧要求：出处写全", isError: true)]))
        XCTAssertEqual(CatalogAgent.revision(for: aqing, task: legacy)?.asks, "- 旧要求：出处写全", "旧 checkpoint 从回合回执里找回修改要求")
        try tasks.save(task)
        let before = model.backend.requests.count
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let opening = try XCTUnwrap(model.backend.requests[before].history.first?.content)
        XCTAssertTrue(opening.contains("【这一页之前交过一稿，没过检查】"))
        XCTAssertTrue(opening.contains("- 记录要写日期") && opening.contains("FIRST_DRAFT_MARKER"))

        // 找不回修改要求的残留修订稿：清掉，按第一稿重新来
        let fresh = SeedModel()
        try standardFixture(fresh)
        var orphan = try XCTUnwrap(tasks.load(outline.id))
        let paper = item(outline, "纸舟").id
        orphan.revisionDrafts = [paper: "{}"]
        orphan.state = .stopped
        try tasks.save(orphan)
        try await approve(outline.id, [paper])
        let before2 = fresh.backend.requests.count
        _ = await CatalogSession(job: job(fresh)).resumeSeed(outline.id)
        XCTAssertFalse(fresh.backend.requests[before2].history[0].content.contains("之前交过一稿"))
        XCTAssertNil(tasks.load(outline.id)?.revisionDrafts?[paper])
    }

    /// P2：同一页连续 3 轮没交出合格的这一页就停（存 checkpoint，不记完成，不再自动请求）；点继续重新数。单页工具只收这一项的 page
    func testPageStopsAfterThreeRoundsWithoutProgressAndSchemaIsStrict() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let aqing = item(outline, "阿青").id
        try await approve(outline.id, [aqing])
        var turn = 0
        model.pageEvent = { _, _ in
            turn += 1
            switch turn % 3 {
            case 1: return .toolCalls([SeedModel.call("submit_proposal", ["phase": "outline", "outline": []])])
            case 2: return .finished("我想想")
            default: return .toolCalls([SeedModel.call("submit_proposal", ["phase": "page", "item": "别的", "items": []])])
            }
        }
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(model.backend.requests.count, before + 3, "第 3 轮没进展就停，不再请求")
        let note = try XCTUnwrap(report.failures.first)
        XCTAssertTrue(note.hasPrefix("「阿青」这一页连续 3 轮没交出能用的正文"), note)
        XCTAssertTrue(note.contains("可以点「继续这个种子任务」再试"))
        let task = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertEqual(task.page?.stalls, 3)
        XCTAssertEqual(task.state, .stopped)
        XCTAssertEqual(task.note, note, "C3 页显示的原因")
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
        let tool = try XCTUnwrap(model.backend.requests[before].tools.first?["function"] as? [String: Any])
        let params = try XCTUnwrap(tool["parameters"] as? [String: Any])
        let props = try XCTUnwrap(params["properties"] as? [String: Any])
        XCTAssertEqual((props["phase"] as? [String: Any])?["enum"] as? [String], ["page"])
        XCTAssertEqual((props["item"] as? [String: Any])?["enum"] as? [String], [aqing])
        XCTAssertEqual(params["required"] as? [String], ["phase", "item", "items"])
        XCTAssertNil(props["outline"])

        model.pageEvent = { _, _ in nil }
        let again = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(again.failures, [], "点继续重新数，照常写完")
        XCTAssertNotNil(contents(outline.id).first { $0.directionRef?.itemId == aqing })
    }

    /// P3：那一页已经交上了（回退交上一稿 / 崩溃前存下的正文对上）：单页对话不留，随结算一起存
    func testLeftoverPageSessionIsClearedOnSettle() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let aqing = item(outline, "阿青").id
        try await approve(outline.id, [aqing])
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        var task = try XCTUnwrap(tasks.load(outline.id))
        task.page = pageSession(aqing, opening: "残留", pending: .init(calls: [], results: []))
        try tasks.save(task)
        try await reject(outline.id, Set(["纸舟", "灯塔", "云桥城"].map { item(outline, $0).id }))
        let before = model.backend.requests.count
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(model.backend.requests.count, before, "那页早交上了，不再问模型")
        XCTAssertNil(tasks.load(outline.id)?.page)
        XCTAssertEqual(tasks.load(outline.id)?.state, .complete)
    }

    // MARK: - 崩溃窗口：收到的调用先落盘，续跑对账已经存下的产物，不重新问模型

    func testPendingTurnIsReplayedAndSavedContentIsAdoptedWithoutAskingTheModelAgain() async throws {
        for alreadySaved in [false, true] {
            try? FileManager.default.removeItem(at: base)
            let model = SeedModel()
            model.outline = [entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md"])]
            try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
            _ = await CatalogSession(job: job(model)).seed()
            let outline = try XCTUnwrap(seedOutline())
            let target = item(outline, "阿青").id
            try await approve(outline.id)
            var task = try XCTUnwrap(tasks.load(outline.id))
            let args = String(decoding: try JSONSerialization.data(withJSONObject: [
                "phase": "page", "item": target, "items": newPage("楼层/人/阿青", "人", "阿青", "阿青喜欢海图", ["memory/cc/user_a.md"]),
            ]), as: UTF8.self)
            task.pending = .init(calls: [.init(id: "call-crash", name: "submit_proposal", argumentsJSON: args, truncated: false)], results: [])
            try tasks.save(task)
            let commit = CatalogSeedTask.commitId(task: outline.id, call: "call-crash", item: target)
            if alreadySaved {
                var saved = WikiProposal(id: commit, origin: .seed, createdAt: Date(), title: "阿青",
                                         items: [.init(change: .newPage(page: WikiPage(path: "楼层/人/阿青", kind: .person, title: "阿青",
                                                                                         records: ["日期未注明 阿青喜欢海图（出处：CC memory/cc/user_a.md）"])),
                                                       cites: [.init(layer: "CC", filePath: "memory/cc/user_a.md")])],
                                         directionRef: .init(proposalId: outline.id, itemId: target))
                saved.seedTask = outline.id
                try store.save(saved)
            }
            let before = model.backend.requests.count
            let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
            XCTAssertEqual(report.failures, [], "alreadySaved=\(alreadySaved)")
            XCTAssertEqual(model.backend.requests.count, before, "收到过的那一轮直接处理，不重新问模型")
            XCTAssertEqual(contents(outline.id).map(\.id), [commit], "按稳定提交 id 只有一份")
            XCTAssertEqual(store.load(outline.id)?.items.first?.change.direction?.contentProposalId, commit)
            XCTAssertNil(tasks.load(outline.id)?.pending)
            XCTAssertNotNil(CatalogSeed.completion(wiki: wiki))
        }
    }

    func testResumeReconcilesSavedOutlineAndUnlinkedContent() async throws {
        let model = SeedModel()
        model.outline = [entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md"])]
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        var task = try XCTUnwrap(tasks.load(outline.id))
        task.outlineSaved = false
        try tasks.save(task)
        try await approve(outline.id)
        var content = WikiProposal(origin: .seed, createdAt: Date(), title: "阿青",
                                   items: [.init(change: .newPage(page: WikiPage(path: "楼层/人/阿青", title: "阿青", records: ["日期未注明 x（出处：CC memory/cc/user_a.md）"])),
                                                 cites: [.init(layer: "CC", filePath: "memory/cc/user_a.md")])],
                                   directionRef: .init(proposalId: outline.id, itemId: outline.items[0].id))
        content.seedTask = outline.id
        try store.save(content)
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(model.backend.requests.count, before, "目录和正文都对上了，不重交、不重付")
        XCTAssertEqual(store.load(outline.id)?.items.first?.change.direction?.contentProposalId, content.id)
        XCTAssertTrue(tasks.load(outline.id)?.outlineSaved ?? false)
        XCTAssertNotNil(CatalogSeed.completion(wiki: wiki))
    }

    // MARK: - provider 内容块：存进 checkpoint，续轮原样回灌

    func testProviderContentBlocksSurviveCheckpointAndReplay() async throws {
        let model = SeedModel()
        model.outline = [entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md"])]
        model.pages = ["楼层/人/阿青": newPage("楼层/人/阿青", "人", "阿青", "阿青喜欢海图", ["memory/cc/user_a.md"])]
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        func extras() -> AssistantTurnExtras {
            let blocks: [[String: Any]] = [["type": "thinking", "thinking": "先读清单", "signature": "sig-abc"],
                                           ["type": "redacted_thinking", "data": "ZW5j"],
                                           ["type": "text", "text": "我先读原料"]]
                + model.lastCalls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": SeedModel.args($0)] }
            var reasoning = ReasoningCapture()
            reasoning.field = "reasoning_details"
            reasoning.text = "推一下"
            reasoning.details = [["type": "reasoning.text", "text": "推一下", "index": 0]]
            return AssistantTurnExtras(assistantContent: blocks, thinkingTokens: 42, reasoning: reasoning)
        }
        model.backend.tokens = { _ in ["我先读原料"] }
        let deps = CatalogAgent.Deps(makeBackend: { model.backend }, gate: { _ in nil }, roundTurn: { _ in extras() })
        _ = await CatalogSession(job: job(model, deps: deps)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let saved = try XCTUnwrap(tasks.load(outline.id)?.turns.first?.toolTurn)
        let encoded = try JSONDecoder().decode(CatalogSeedTask.Turn.self, from: JSONEncoder().encode(CatalogSeedTask.Turn(saved))).toolTurn
        for turn in [saved, encoded] {
            let content = try XCTUnwrap(turn.assistantContent)
            XCTAssertEqual(content.first?["signature"] as? String, "sig-abc")
            XCTAssertEqual(content[1]["data"] as? String, "ZW5j")
            XCTAssertEqual(turn.thinkingTokens, 42)
            XCTAssertEqual(turn.reasoning?.field, "reasoning_details")
            XCTAssertTrue(NSArray(array: turn.reasoning?.details ?? []).isEqual(to: [["type": "reasoning.text", "text": "推一下", "index": 0]]))
            XCTAssertEqual(turn.text, "我先读原料")
            XCTAssertTrue(NSArray(array: AnthropicProvider.toolTurnAssistantContent(turn)).isEqual(to: content), "Anthropic 续轮原样回灌")
        }
        try await approve(outline.id)
        let before = model.backend.requests.count
        // 这一页先交一稿没有可用条目的，下一轮请求出错停下：这一页自己的对话存进 checkpoint
        let good = model.pages
        model.pages = [:]
        model.fail = { n in n == before + 2 ? "假模型：断了" : nil }
        _ = await CatalogSession(job: job(model, deps: deps)).resumeSeed(outline.id)
        let first = model.backend.requests[before]
        XCTAssertTrue(first.toolTurns.isEmpty, "写正文单开一段对话，出目录那段的回合不回灌")
        XCTAssertEqual(first.history.count, 1)
        let pageTurn = try XCTUnwrap(tasks.load(outline.id)?.page?.turns.first?.toolTurn)
        XCTAssertEqual(pageTurn.thinkingTokens, 42)
        model.pages = good
        model.fail = { _ in nil }
        _ = await CatalogSession(job: job(model, deps: deps)).resumeSeed(outline.id)
        let replayed = try XCTUnwrap(model.backend.requests[before + 2].toolTurns.first)
        XCTAssertTrue(NSArray(array: replayed.assistantContent ?? []).isEqual(to: pageTurn.assistantContent ?? []), "重启续跑这一页的请求里原样带回")
        XCTAssertEqual(replayed.reasoning?.text, "推一下")
        XCTAssertEqual(replayed.text, "我先读原料")
        XCTAssertNotNil(CatalogSeed.completion(wiki: wiki))
        var plain = saved
        plain.assistantContent = nil
        XCTAssertEqual(AnthropicProvider.toolTurnAssistantContent(plain).first?["text"] as? String, "我先读原料", "没有内容块时正文也回灌")
    }

    // MARK: - 续跑合并、模型绑定、不设替代闸门

    func testResumeQueueCoalescesAndDoesNotRetryAfterFailure() {
        var queue = CatalogSeedResumeQueue()
        XCTAssertTrue(queue.request("t"))
        XCTAssertFalse(queue.request("t"), "还在排队的不再排第二个")
        queue.began("t")
        XCTAssertFalse(queue.request("t"))
        XCTAssertFalse(queue.finished("t", ok: false), "失败后排着的旧请求不自动再付费跑")
        XCTAssertTrue(queue.request("t"))
        queue.began("t")
        _ = queue.request("t")
        XCTAssertTrue(queue.finished("t", ok: true), "正常结束、跑的时候又有新审批，才再续一次")
        XCTAssertTrue(queue.request("t"))
        queue.began("t")
        XCTAssertFalse(queue.finished("t", ok: true), "没有新审批就不再续")

        let pending = WikiProposal(origin: .seed, createdAt: Date(), items: [.init(change: .newPage(page: WikiPage(path: "楼层/人/阿青", title: "阿青")))])
        var approved = pending
        approved.items[0].state = .approved
        XCTAssertTrue(WikiProposalDetailPage.decided(pending, approved))
        XCTAssertFalse(WikiProposalDetailPage.decided(approved, approved), "两个窗口重复批：第二次没有新审批，不续跑")
    }

    func testModelIdentityBindsTaskAndSeedNeverFallsBack() async throws {
        let model = SeedModel()
        try standardFixture(model)
        var blocked = job(model)
        blocked.seedBlocked = "本机模型没下"
        let refused = await CatalogSession(job: blocked).seed()
        XCTAssertTrue(refused.failures.first?.contains("种子不换别的模型") ?? false)
        XCTAssertEqual(model.backend.requests.count, 0)
        XCTAssertTrue(tasks.all().isEmpty)

        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id, [item(outline, "纸舟").id])
        let before = model.backend.requests.count
        var other = job(model)
        other.seedModel = "remote:another-credential/fake-model"
        let switched = await CatalogSession(job: other).resumeSeed(outline.id)
        XCTAssertTrue(switched.failures.first?.contains("种子不换模型") ?? false, "同显示名、不同模型也拦")
        XCTAssertEqual(model.backend.requests.count, before)
        var renamed = job(model)
        renamed.modelName = "改了个名字"
        let same = await CatalogSession(job: renamed).resumeSeed(outline.id)
        XCTAssertEqual(same.failures, [], "只改显示名不拦")
        XCTAssertEqual(contents(outline.id).count, 1)
    }

    func testTextRepliesAreNudgedNotStopped() async throws {
        let model = SeedModel()
        model.outline = [entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md"])]
        model.textFirst = 3
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        let report = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(report.failures, [])
        XCTAssertNotNil(seedOutline(), "连着几轮不调工具也只是提醒，不硬停")
    }

    // MARK: - 正文：实质内容、读到的版本、获批原料、同任务连线

    func testEmptyOrHookOnlyPageDoesNotCountAsWritten() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.limit = 12
        model.pages["工程/项目/纸舟"] = [["type": "new_page", "path": "工程/项目/纸舟", "kind": "项目", "title": "纸舟", "now": "纸舟是阅读工具",
                                      "records": [["text": "没出处", "sources": ["memory/cc/不存在.md"]]]]]
        model.pages["楼层/地点/云桥城"] = [["type": "retag", "path": "楼层/地点/云桥城", "hook": "新钩子", "triggers": ["云桥城"]]]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id, [item(outline, "纸舟").id, item(outline, "云桥城").id])
        try await reject(outline.id)
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertFalse(report.failures.isEmpty, "假模型交不出合格正文，最后服务商报错才停")
        XCTAssertTrue(contents(outline.id).isEmpty, "空页、只改钩子都不算这页写好了")
        XCTAssertTrue(CatalogSeedTask.unwritten(store.load(outline.id)).count == 2)
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
        let errors = model.backend.requests.last?.toolTurns.last?.results.map(\.text).joined() ?? ""
        XCTAssertTrue(errors.contains("没有带出处的事实正文"))
    }

    /// 第 9 段：种子交页同样硬查——没过给一次重写，还没过照样交批、条目上标出，记录不截字
    func testSeedPageFailingHardCheckGetsOneRewriteThenGoesToReviewFlagged() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let long = "纸舟是离线阅读工具，能把整本书连同插图和批注一起存到手机上，没网的地铁里也能接着看"
        model.pages["工程/项目/纸舟"] = newPage("工程/项目/纸舟", "项目", "纸舟", long, ["memory/cc/project_c.md"])
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let paper = item(outline, "纸舟").id
        try await approve(outline.id, [paper])
        try await reject(outline.id)
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        let content = try XCTUnwrap(contents(outline.id).first)
        guard case .newPage(let page) = content.items[0].change else { return XCTFail() }
        XCTAssertTrue(page.records[0].hasPrefix("日期未注明 " + long + "（出处："), "不截字")
        XCTAssertTrue(content.items[0].checks?.contains { $0.contains("超过 30 字") } ?? false)
        let results = model.backend.requests.last?.toolTurns.flatMap(\.results) ?? []
        XCTAssertEqual(results.filter { $0.isError && $0.text.contains("没过检查") }.count, 1, "同一目录项只给一次重写")
        XCTAssertEqual(tasks.load(outline.id)?.revisionDrafts.map { Array($0.keys) }, [paper])
        XCTAssertEqual(content.revision, "重写一次后仍有没过的")
    }

    /// 种子修订之后，只要不是被取消，结果用不了（出错、坏参数、交上来的没有能用的条目）都交已存的第一稿当提案，带标记和原因，不要第三稿
    func testSeedRevisionThatCannotBeUsedDeliversTheFirstDraft() async throws {
        let long = "纸舟是离线阅读工具，能把整本书连同插图和批注一起存到手机上，没网的地铁里也能接着看"
        let cases: [(name: String, setup: (SeedModel, Int) -> Void, why: String)] = [
            ("出错", { model, before in model.fail = { n in n == before + 2 ? "网关超时 504" : nil } }, "那轮出错（网关超时 504）"),
            ("坏参数", { model, before in model.badPageArgs = { n in n == before + 2 } }, "那次参数不是合格的 JSON"),
            ("交空", { model, before in model.pageOverride = { n in n >= before + 2 ? ["工程/项目/纸舟": []] : nil } }, "那次交的没有能用的内容"),
        ]
        for c in cases {
            try? FileManager.default.removeItem(at: base)
            let model = SeedModel()
            try standardFixture(model)
            model.pages["工程/项目/纸舟"] = newPage("工程/项目/纸舟", "项目", "纸舟", long, ["memory/cc/project_c.md"])
            _ = await CatalogSession(job: job(model)).seed()
            let outline = try XCTUnwrap(seedOutline(), c.name)
            let paper = item(outline, "纸舟").id
            try await approve(outline.id, [paper])
            try await reject(outline.id)
            let before = model.backend.requests.count
            c.setup(model, before)
            _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
            let content = try XCTUnwrap(contents(outline.id).first, c.name)
            XCTAssertTrue(content.revision?.contains(c.why) == true && content.revision?.hasSuffix("交的是第一稿") == true, "\(c.name)：\(content.revision ?? "nil")")
            guard case .newPage(let page) = content.items[0].change else { return XCTFail(c.name) }
            XCTAssertTrue(page.records[0].hasPrefix("日期未注明 " + long + "（出处："), c.name)
            XCTAssertTrue(content.items[0].checks?.isEmpty == false, c.name)
            XCTAssertLessThanOrEqual(model.backend.requests.count - before, 3, "\(c.name)：交页、修订，之后最多再问一次就停在等批，不要第三稿")
            let asked = (model.backend.requests.last?.toolTurns.flatMap(\.results) ?? []).filter { $0.isError && $0.text.contains("改了重交") }
            XCTAssertTrue(asked.isEmpty, "\(c.name)：不再要求重交")
        }
    }

    func testAllItemsOfAPageUseTheVersionReadByTheTask() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let readVersion = try XCTUnwrap(tasks.load(outline.id)?.read["memory/wiki/楼层/地点/云桥城.md"])
        try await approve(outline.id, [item(outline, "云桥城").id])
        try await reject(outline.id)
        try wiki.saveRaw("---\n钩子: 她改过的钩子\n---\n# 云桥城\n\n## 现在\n她手改的一版\n", path: "楼层/地点/云桥城")
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let cloud = try XCTUnwrap(contents(outline.id).first)
        XCTAssertEqual(cloud.items.map(\.baseVersion), [readVersion, readVersion], "补出的改钩子也用读到的那一版，不拿现在的")
        guard case .retag(_, let oldHook, let newHook, _, _) = cloud.items[1].change else { return XCTFail() }
        XCTAssertEqual(oldHook, "提到云桥城", "旧钩子按读到的那一版")
        XCTAssertEqual(newHook, "提到云桥城的时候先看这页")
        let mine = wiki.readRaw("楼层/地点/云桥城")
        try await approve(cloud.id)
        XCTAssertEqual(store.load(cloud.id)?.items.map(\.state), [.stale, .stale])
        XCTAssertEqual(wiki.readRaw("楼层/地点/云桥城"), mine, "她的新改动不被钩子盖掉")
    }

    func testSourcesAreLimitedToTheApprovedItemAndEditsShareTheSeedCheck() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.pages["工程/项目/纸舟"] = [["type": "new_page", "path": "工程/项目/纸舟", "kind": "项目", "title": "纸舟", "now": "纸舟",
                                      "records": [["text": "日期未注明 纸舟是离线阅读工具", "sources": ["memory/cc/project_c.md"]],
                                                  ["text": "日期未注明 阿青看船", "sources": ["memory/cc/user_a.md"]]]]]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let paper = item(outline, "纸舟")
        let entry = try XCTUnwrap(CatalogSeedDrafts.entries(wiki: wiki).first { $0.kind == .outline(outline.id) })
        let unread = entry.content.replacingOccurrences(of: "- memory/cc/project_c.md\n\n## 3", with: "- memory/cc/不存在.md\n\n## 3")
        XCTAssertNotEqual(unread, entry.content)
        await XCTAssertThrowsErrorAsync { try await CatalogSeedDrafts.save(entry, text: unread, baseline: entry.content, wiki: self.wiki) }
        guard case .direction(var d) = paper.change else { return XCTFail() }
        d.sources = ["memory/cc/private_y.md"]
        await XCTAssertThrowsErrorAsync {
            try await CatalogSeedDrafts.saveChange(outline.id, itemId: paper.id, change: .direction(d), baseline: paper.change, wiki: self.wiki)
        }
        try await approve(outline.id, [paper.id])
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let content = try XCTUnwrap(contents(outline.id).first)
        guard case .newPage(let page) = content.items[0].change else { return XCTFail() }
        XCTAssertEqual(page.records, ["日期未注明 纸舟是离线阅读工具（出处：CC memory/cc/project_c.md）"], "引用这一项目录之外的原料的行扔掉")
        var stripped = page
        stripped.records = ["日期未注明 纸舟是离线阅读工具"]
        await XCTAssertThrowsErrorAsync {
            try await CatalogSeedDrafts.saveChange(content.id, itemId: content.items[0].id, change: .newPage(page: stripped),
                                                   baseline: content.items[0].change, wiki: self.wiki)
        }
        var moved = page
        moved.path = "工程/项目/别处"
        let saved = try await CatalogSeedDrafts.saveChange(content.id, itemId: content.items[0].id, change: .newPage(page: moved),
                                                           baseline: content.items[0].change, wiki: wiki)
        XCTAssertEqual(saved.items[0].change.targetPath, "工程/项目/纸舟", "审计台改不了正文的页路径")
    }

    func testFileLibrarySaveComparesBaselineInsideTheLock() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let entry = try XCTUnwrap(CatalogSeedDrafts.entries(wiki: wiki).first { $0.kind == .outline(outline.id) })
        let lighthouse = item(outline, "灯塔")
        guard case .direction(var audited) = lighthouse.change else { return XCTFail() }
        audited.hook = "审计台改的钩子"
        let st = store
        let gate = Gate()
        let holder = Task { @MainActor in
            try await WikiProposalReview.exclusive(st) {
                await withCheckedContinuation { gate.release = $0 }
                try st.edit(outline.id, itemId: lighthouse.id, change: .direction(audited), judgment: nil)
            }
        }
        while gate.release == nil { await Task.yield() }
        let edited = entry.content.replacingOccurrences(of: "钩子: 提到灯塔的时候先看这页", with: "钩子: 文件库改的钩子")
        let wk = wiki
        let saver = Task { @MainActor in try await CatalogSeedDrafts.save(entry, text: edited, baseline: entry.content, wiki: wk) }
        for _ in 0..<20 { await Task.yield() }
        gate.release?.resume()
        try await holder.value
        do {
            try await saver.value
            XCTFail("等锁期间被改过，要拒")
        } catch let e as CatalogSeedDrafts.EditError {
            XCTAssertEqual(e, .conflict)
        }
        XCTAssertEqual(store.load(outline.id).flatMap { item($0, "灯塔").change.direction?.hook }, "审计台改的钩子", "审计台的新内容没被盖掉")
    }

    private func linkedPages(rejectTargetFirst: Bool) async throws -> WikiPage? {
        let model = SeedModel()
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青每天去码头。")
        model.outline = [entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md"]), entry("楼层/地点/码头", "地点", "码头", ["memory/cc/user_a.md"])]
        var aqing = newPage("楼层/人/阿青", "人", "阿青", "阿青每天去码头", ["memory/cc/user_a.md"])
        aqing[0]["links"] = [["to": "楼层/地点/码头", "relation": "补充", "why": "常去"]]
        model.pages = ["楼层/人/阿青": aqing, "楼层/地点/码头": newPage("楼层/地点/码头", "地点", "码头", "阿青常去的码头", ["memory/cc/user_a.md"])]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id)
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let all = contents(outline.id)
        let a = try XCTUnwrap(all.first { $0.title == "阿青" })
        let b = try XCTUnwrap(all.first { $0.title == "码头" })
        guard case .newPage(let draft) = a.items[0].change else { XCTFail(); return nil }
        XCTAssertEqual(draft.links.map(\.target), ["楼层/地点/码头"], "同任务获批的目录页可以连，不当成不存在")
        if rejectTargetFirst { try await reject(b.id) }
        try await approve(a.id)
        return wiki.read("楼层/人/阿青")
    }

    func testLinkToAnApprovedOutlinePageIsKeptWhileItsContentIsPending() async throws {
        let page = try await linkedPages(rejectTargetFirst: false)
        XCTAssertEqual(page?.links.map(\.target), ["楼层/地点/码头"], "目标正文还在等批，连线留着")
    }

    func testLinkIsDroppedAtReviewWhenTheTargetWillNeverExist() async throws {
        let page = try await linkedPages(rejectTargetFirst: true)
        XCTAssertNotNil(page)
        XCTAssertEqual(page?.links, [], "目标正文驳回了，批这一页时去掉连线")
    }

    // MARK: - 符号链接 / 各层索引

    func testSymlinkedWikiPagesAndFoldersAreNeverRead() async throws {
        let model = SeedModel()
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        try cc("private_x.md", type: "user", title: "私密", body: "PRIVATE_LINK_MARKER")
        let w = wiki
        try w.save(WikiPage(path: "楼层/人/阿青", kind: .person, title: "阿青", now: "她写的"))
        try w.save(WikiPage(path: "楼层/地点/云桥城", kind: .place, title: "云桥城", now: "旧码头"))
        try w.setGroupHook("楼层/地点", hook: "说到地方先看这组")
        let other = base.appendingPathComponent("other-floor", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try "# 别层\nOTHER_FLOOR_MARKER".write(to: other.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)
        try "# 外面\nOUTSIDE_MARKER".write(to: other.appendingPathComponent("folder/外面.md"), atomically: true, encoding: .utf8)
        let fm = FileManager.default
        try fm.createSymbolicLink(at: w.root.appendingPathComponent("楼层/人/秘密.md"), withDestinationURL: root.appendingPathComponent("cc/private_x.md"))
        try fm.createSymbolicLink(at: w.root.appendingPathComponent("楼层/人/别层.md"), withDestinationURL: other.appendingPathComponent("page.md"))
        try fm.createSymbolicLink(at: w.root.appendingPathComponent("楼层/链接夹"), withDestinationURL: other.appendingPathComponent("folder"))
        model.outline = [entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md"])]
        _ = await CatalogSession(job: job(model)).seed()
        let task = try XCTUnwrap(tasks.all().first)
        let paths = task.materials.map(\.path)
        XCTAssertTrue(paths.contains("memory/wiki/楼层/人/阿青.md"))
        XCTAssertTrue(paths.contains("memory/wiki/楼层/地点/INDEX.md"))
        for bad in ["秘密", "别层", "链接夹", "外面"] { XCTAssertFalse(paths.contains { $0.contains(bad) }, bad) }
        let everything = sent(model)
        for marker in ["PRIVATE_LINK_MARKER", "OTHER_FLOOR_MARKER", "OUTSIDE_MARKER", "秘密", "别层", "链接夹"] {
            XCTAssertFalse(everything.contains(marker), marker)
        }
        XCTAssertTrue(everything.contains("说到地方先看这组"), "下层分组的钩子在它那层的索引里")

        let linkedRoot = base.appendingPathComponent("linked-memory", isDirectory: true)
        try fm.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedRoot.appendingPathComponent("wiki"), withDestinationURL: w.root)
        let refused = try CatalogSeedMaterials.gather(floorBase: nil, memoryRoot: linkedRoot, wiki: WikiStore(root: linkedRoot.appendingPathComponent("wiki")))
        XCTAssertTrue(refused.items.isEmpty, "wiki 根本身是链接就一份都不读")
        XCTAssertTrue(refused.skipped.contains { $0.contains("wiki 文件夹是链接") })
    }

    // MARK: - 工具：白名单、交目录前必须读完、非法目标、没批的不写

    func testReadWhitelistOutlineGuardsAndPageTargets() async throws {
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        let outsider = root.appendingPathComponent("secret.md")
        try "SECRET_MARKER".write(to: outsider, atomically: true, encoding: .utf8)
        var unapproved = ""
        let backend = FakeCatalogBackend { n, request in
            switch n {
            case 1:
                return .toolCalls([SeedModel.call("read", ["path": "memory/cc/../secret.md"]), SeedModel.call("read", ["path": "memory/wiki/INDEX.md"]),
                                   SeedModel.call("submit_proposal", ["phase": "outline", "outline": [["path": "楼层/人/阿青", "kind": "人", "title": "阿青", "sources": ["memory/cc/user_a.md"]]]])])
            case 2:
                return .toolCalls([SeedModel.call("read", ["path": "memory/cc/user_a.md"]), SeedModel.call("read", ["path": "memory/cc/user_a.md"]),
                                   SeedModel.call("read", ["path": self.slotPath])])
            case 3:
                return .toolCalls([SeedModel.call("submit_proposal", ["phase": "outline", "outline": [
                    ["path": "../越界", "kind": "人", "title": "越界", "sources": ["memory/cc/user_a.md"]],
                    ["path": "楼层/动物/猫", "kind": "动物", "title": "猫", "sources": ["memory/cc/user_a.md"]],
                    ["path": "楼层/人/没读", "kind": "人", "title": "没读", "sources": ["memory/cc/secret.md"]],
                    ["path": "楼层/人/阿青", "kind": "人", "title": "阿青", "sources": ["memory/cc/user_a.md"]],
                    ["path": "楼层/地点/码头", "kind": "地点", "title": "码头", "sources": ["memory/cc/user_a.md"]],
                ]])])
            default:
                let approved = SeedModel.pageItem(request) ?? ""
                return .toolCalls([
                    SeedModel.call("submit_proposal", ["phase": "page", "item": unapproved, "items": []]),
                    SeedModel.call("submit_proposal", ["phase": "page", "item": approved, "items": [
                        ["type": "new_page", "path": "楼层/地点/别处", "kind": "地点", "title": "别处", "records": [["text": "x", "sources": ["memory/cc/user_a.md"]]]],
                        ["type": "new_page", "path": "楼层/人/阿青", "kind": "物", "title": "随便", "records": [["text": "日期未注明 阿青喜欢海图", "sources": ["memory/cc/user_a.md"]]]],
                    ]]),
                ])
            }
        }
        var j = CatalogTestKit.job(pid: pid, root: root, container: container, backend: backend)
        j.floorBase = CatalogFloorBase(sections: [.init(path: slotPath, name: "自建槽", text: "槽里的字", isEnabled: false)])
        _ = await CatalogSession(job: j).seed()
        let results = backend.requests.dropFirst().compactMap { $0.toolTurns.last?.results }
        XCTAssertTrue(results[0][0].isError && results[0][0].text.contains("不在这次的原料清单里"))
        XCTAssertTrue(results[0][1].isError, "wiki 没有页时根索引不在清单里")
        XCTAssertTrue(results[0][2].isError && results[0][2].text.contains("还有"), "没读完不能交目录")
        XCTAssertTrue(results[1][1].text.contains("已经读过了"))
        XCTAssertFalse(backend.requests.flatMap { $0.toolTurns.flatMap(\.results).map(\.text) }.joined().contains("SECRET_MARKER"))
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(outline.items.compactMap { $0.change.direction?.path }, ["楼层/人/阿青", "楼层/地点/码头"], "非法路径 / 非七类 / 没读的原料都进不了目录")
        unapproved = item(outline, "码头").id
        try await approve(outline.id, [item(outline, "阿青").id])
        _ = await CatalogSession(job: j).resumeSeed(outline.id)
        let content = try XCTUnwrap(contents(outline.id).first { $0.directionRef?.itemId == item(outline, "阿青").id })
        XCTAssertEqual(content.items.compactMap(\.change.targetPath), ["楼层/人/阿青"], "别的页的条目扔掉")
        guard case .newPage(let page) = content.items[0].change else { return XCTFail() }
        XCTAssertEqual(page.kind, .person, "类按目录")
        XCTAssertEqual(page.title, "阿青")
        XCTAssertFalse(contents(outline.id).contains { $0.directionRef?.itemId == unapproved }, "没批的不写")
        XCTAssertEqual(wiki.pagePaths(), [], "agent 写不到正式 wiki")
    }

    func testNoArtificialCapsFullMaterialsReachTheRequest() async throws {
        let model = SeedModel()
        let huge = String(repeating: "阿青在码头记了一行航海日志。", count: 4_000) + "最后一行：阿青把海图交给了灯塔守。"
        for i in 0..<12 { try cc("user_\(i).md", type: "user", title: "日志 \(i)", body: huge) }
        model.outline = [entry("楼层/人/阿青", "人", "阿青", (0..<12).map { "memory/cc/user_\($0).md" })]
        let report = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(report.failures, [])
        let results = model.backend.requests.last?.toolTurns.flatMap(\.results).map(\.text) ?? []
        XCTAssertEqual(results.filter { $0.hasSuffix(huge) }.count, 12, "每份 \(huge.count) 字原样全进同一个请求，不截尾、不摘要")
        XCTAssertNotNil(seedOutline())
    }

    /// 走查 P2：逐项驳回目录，中间那几下不续记录、不记日志；批完那一下只记一行结算，旗标照实
    func testOutlineDecisionsLogOneSettlingRowWithAccurateFlag() async throws {
        let model = SeedModel()
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青每天早上看船。")
        model.outline = ["阿青", "纸舟", "灯塔"].map { entry("楼层/主题/\($0)", "主题", $0, ["memory/cc/user_a.md"]) }
        model.pages = ["楼层/主题/阿青": newPage("楼层/主题/阿青", "主题", "阿青", "阿青每天早上看船", ["memory/cc/user_a.md"])]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id, [item(outline, "阿青").id])
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        MemoryWriteLog.flush()
        let before = MemoryWriteLog.entries(profileId: pid).count
        let runs = wiki.root.appendingPathComponent(".runs")
        let runFile = runs.appendingPathComponent(try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: runs.path).first))
        let runBefore = try String(contentsOf: runFile, encoding: .utf8)

        try await reject(outline.id, [item(outline, "纸舟").id])
        let middle = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(middle.skipped, "目录还有 1 项待批")
        MemoryWriteLog.flush()
        XCTAssertEqual(MemoryWriteLog.entries(profileId: pid).count, before, "目录还有待批、也没批出要写的页：不记日志")
        XCTAssertEqual(try String(contentsOf: runFile, encoding: .utf8), runBefore, "也不往整理记录里续一节")

        try await reject(outline.id, [item(outline, "灯塔").id])
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        MemoryWriteLog.flush()
        let all = MemoryWriteLog.entries(profileId: pid)
        let added = Array(all.prefix(all.count - before))   // 新的在前
        XCTAssertEqual(added.count, 1, "批完那一下只记一行：\(added.map(\.note))")
        XCTAssertTrue(added.first?.note.hasPrefix("种子完成") == true)
        XCTAssertEqual(added.first?.ok, true)
        XCTAssertEqual(tasks.load(outline.id)?.state, .complete)

        let next = SeedModel()
        next.outline = [entry("楼层/主题/面包", "主题", "面包", ["memory/cc/user_a.md"])]
        _ = await CatalogSession(job: job(next)).seed()
        let second = try XCTUnwrap(store.list().first { CatalogSeedDrafts.isOutline($0) && $0.id != outline.id })
        try await reject(second.id)
        MemoryWriteLog.flush()
        let mark = MemoryWriteLog.entries(profileId: pid).count
        _ = await CatalogSession(job: job(next)).resumeSeed(second.id)
        MemoryWriteLog.flush()
        let latest = MemoryWriteLog.entries(profileId: pid)
        let ended = Array(latest.prefix(latest.count - mark))
        XCTAssertEqual(ended.map(\.note), ["种子：目录全部驳回，没有获批的页，不记完成"])
        XCTAssertEqual(ended.first?.ok, false, "什么都没写，不标「写好了」")
    }

    func testEmptyOutlineAndAllRejectedEndWithoutCompletion() async throws {
        let model = SeedModel()
        try cc("user_a.md", type: "user", title: "回复规矩", body: "你要先给结论。")
        model.emptyReason = "原料全是回复规矩，没有事实"
        let empty = await CatalogSession(job: job(model)).seed()
        XCTAssertFalse(empty.failures.isEmpty)
        XCTAssertNil(seedOutline())
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
        XCTAssertNil(tasks.open(proposals: store), "空目录结束了，不挡新种子")
        XCTAssertNotNil(tasks.all().first?.endedAt)

        let next = SeedModel()
        next.outline = [entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md"])]
        _ = await CatalogSession(job: job(next)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await reject(outline.id)
        _ = await CatalogSession(job: job(next)).resumeSeed(outline.id)
        XCTAssertNil(CatalogSeed.completion(wiki: wiki), "目录全驳回不记完成")
        XCTAssertEqual(tasks.load(outline.id)?.state, .ended)
    }

    // MARK: - 清旧（一次性 cutover）

    private struct LegacyState: Codable { var completedAt: Date }

    private func legacyFixture() throws -> (created: String, touched: String, sameName: String, linker: String, manual: String) {
        let w = wiki
        try w.save(WikiPage(path: "楼层/主题/电影", kind: .topic, title: "电影", now: "旧种子写的"))
        try w.saveRaw("旧种子写的第二版", path: "楼层/主题/电影")
        try w.save(WikiPage(path: "楼层/地点/云桥城", kind: .place, title: "云桥城", now: "她自己写的", records: ["旧种子追加的一行"]))
        try w.save(WikiPage(path: "楼层/偏好/电影", kind: .topic, title: "电影", now: "同名的非种子页"))
        try w.save(WikiPage(path: "楼层/人/阿青", kind: .person, title: "阿青", now: "她写的",
                            links: [.init(target: "楼层/主题/电影", relation: .supplement, why: "")]))
        try w.rebuildAllIndexes()
        try WikiStore.writeAtomic(JSONEncoder().encode(LegacyState(completedAt: Date())), to: CatalogSeed.stateURL(w))
        var approved = WikiProposal(origin: .seed, createdAt: Date(), title: "CC 记忆播种", items: [
            .init(change: .newPage(page: WikiPage(path: "楼层/主题/电影", title: "电影"))),
            .init(change: .appendRecords(path: "楼层/地点/云桥城", lines: ["旧种子追加的一行"])),
        ])
        approved.items[0].state = .approved
        approved.items[1].state = .approved
        var rejected = WikiProposal(origin: .seed, createdAt: Date(), items: [.init(change: .newPage(page: WikiPage(path: "楼层/主题/纸舟", title: "纸舟")))])
        rejected.items[0].state = .rejected
        let pending = WikiProposal(origin: .seed, createdAt: Date(), items: [.init(change: .newPage(page: WikiPage(path: "楼层/偏好/电影", title: "电影")))])
        let manual = WikiProposal(origin: .manual, createdAt: Date(), items: [.init(change: .newPage(page: WikiPage(path: "楼层/主题/面包", title: "面包")))])
        for p in [approved, rejected, pending, manual] { try store.save(p) }
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        return ("楼层/主题/电影", "楼层/地点/云桥城", "楼层/偏好/电影", "楼层/人/阿青", manual.id)
    }

    func testLegacyCleanupBacksUpThenDeletesExactlyThreeKindsAndListsTouchedPages() async throws {
        let f = try legacyFixture()
        let w = wiki
        let before = try MemoryRegeneration.inventory(w.root)
        let touchedData = try Data(contentsOf: try w.pageURL(f.touched))
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.historyURL(f.created).path))

        let result = try XCTUnwrap(try CatalogSeedCleanup.run(memoryRoot: root, wiki: w, now: Date()))
        XCTAssertTrue(result.plan.stateFile)
        XCTAssertEqual(result.plan.pages, [f.created])
        XCTAssertEqual(result.plan.proposals.count, 3)
        XCTAssertEqual(result.plan.touched, [f.touched])
        XCTAssertEqual(result.plan.danglingLinks, [f.linker])
        XCTAssertFalse(w.pageExists(f.created))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.historyURL(f.created).path), "种子新建页的专属历史一起删")
        XCTAssertFalse(MemoryRegeneration.itemExists(CatalogSeed.stateURL(w)))
        XCTAssertEqual(store.list().map(\.id), [f.manual], "非种子提案留着")
        XCTAssertEqual(try Data(contentsOf: try w.pageURL(f.touched)), touchedData, "旧种子改过的非种子页不回滚、不动")
        XCTAssertTrue(w.pageExists(f.sameName), "同名的非种子页不靠标题误删")
        XCTAssertEqual(w.read(f.linker)?.links.first?.target, f.created, "连线不擅自改")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("cc/user_a.md").path))
        XCTAssertFalse(w.layerMarkdown("楼层").contains("[[楼层/主题/"), "索引按留下的页重建")
        XCTAssertTrue(result.summary.contains(f.touched))
        XCTAssertTrue(MemoryRegeneration.backups(memoryRoot: root).contains(result.backup))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.backup.appendingPathComponent(CatalogSeedCleanup.listFileName).path))
        XCTAssertNil(try CatalogSeedCleanup.run(memoryRoot: root, wiki: w, now: Date()), "只做一次")

        try MemoryRegeneration.restore(backup: result.backup, memoryRoot: root, now: Date().addingTimeInterval(5))
        XCTAssertEqual(try MemoryRegeneration.inventory(w.root), before, "能从备份原样恢复")
    }

    func testCleanupFailureDeletesNothingAndSeedDoesNotStart() async throws {
        let f = try legacyFixture()
        let w = wiki
        let before = try MemoryRegeneration.inventory(w.root)
        struct Boom: Error {}
        XCTAssertThrowsError(try CatalogSeedCleanup.run(memoryRoot: root, wiki: w, now: Date(), copy: { _, _ in throw Boom() }))
        XCTAssertThrowsError(try CatalogSeedCleanup.run(memoryRoot: root, wiki: w, now: Date(), copy: { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            try Data("多出来的".utf8).write(to: to.appendingPathComponent("坏.txt"))
        }), "备份对不上")
        XCTAssertEqual(try MemoryRegeneration.inventory(w.root), before, "备份失败一个都不删")
        XCTAssertTrue(w.pageExists(f.created))

        let blocker = MemoryRegeneration.backupRoot(memoryRoot: root)
        try? FileManager.default.removeItem(at: blocker)
        try Data("不是文件夹".utf8).write(to: blocker)
        let model = SeedModel()
        let report = await CatalogSession(job: job(model)).seed()
        XCTAssertTrue(report.failures.first?.hasPrefix("清旧种子没成，一个都没删") ?? false)
        XCTAssertEqual(model.backend.requests.count, 0)
        XCTAssertEqual(try MemoryRegeneration.inventory(w.root).filter { !$0.key.hasPrefix(".runs/") }, before, "只多了这次的整理记录")
    }

    func testCleanupRollsBackMovesAndIndexesOrKeepsTheTrashWithPaths() async throws {
        let f = try legacyFixture()
        let w = wiki
        let before = try MemoryRegeneration.inventory(w.root)
        let box = Box()
        let move: MemoryRegeneration.FileOp = { from, to in
            box.count += 1
            if box.count == box.failAt { throw CocoaError(.fileWriteNoPermission) }
            if box.rollbackFails, from.path.contains(".seed-cleanup-"), to.lastPathComponent == ".seed-state.json" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: from, to: to)
        }
        box.failAt = 3
        XCTAssertThrowsError(try CatalogSeedCleanup.run(memoryRoot: root, wiki: w, now: Date(), move: move)) {
            XCTAssertFalse($0 is CatalogSeedCleanup.CleanupError, "都挪回去了 = 普通失败")
        }
        XCTAssertEqual(try MemoryRegeneration.inventory(w.root), before, "挪到一半失败：逐样挪回，一个都没删")

        box.count = 0
        box.failAt = nil
        struct IndexBoom: Error {}
        XCTAssertThrowsError(try CatalogSeedCleanup.run(memoryRoot: root, wiki: w, now: Date().addingTimeInterval(1), move: move,
                                                        rebuild: { wiki in
            try Data("改坏的索引".utf8).write(to: wiki.folderURL("楼层").appendingPathComponent(WikiStore.indexFileName))
            throw IndexBoom()
        }))
        XCTAssertEqual(try MemoryRegeneration.inventory(w.root), before, "索引重建失败也整体回滚，索引恢复原样")

        box.count = 0
        box.failAt = 4
        box.rollbackFails = true
        var thrown: Error?
        XCTAssertThrowsError(try CatalogSeedCleanup.run(memoryRoot: root, wiki: w, now: Date().addingTimeInterval(2), move: move)) { thrown = $0 }
        guard case .partial(_, let notRestored, let trash, let backup)? = thrown as? CatalogSeedCleanup.CleanupError else { return XCTFail("\(String(describing: thrown))") }
        XCTAssertEqual(notRestored, [CatalogSeed.stateURL(w).path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash), "回滚不全：暂存夹留着")
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: trash)).contains { $0.hasSuffix(".seed-state.json") }, "没挪回的原件就在暂存夹里")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup))
        let message = thrown?.localizedDescription ?? ""
        XCTAssertTrue(message.contains(trash) && message.contains(backup) && !message.contains("一个都没删"))
        XCTAssertTrue(w.pageExists(f.created), "能挪回的都挪回了")
    }

    // MARK: - 文件库同一份草稿：能看能改，审计台看到同一份，改完重新校验

    func testFileLibraryDraftsEditTheSameProposalAndRevalidate() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        var outline = try XCTUnwrap(seedOutline())
        let paperId = item(outline, "纸舟").id
        try await approve(outline.id, [paperId])

        var entries = CatalogSeedDrafts.entries(wiki: wiki)
        let outlineEntry = try XCTUnwrap(entries.first { $0.kind == .outline(outline.id) })
        XCTAssertTrue(outlineEntry.editable)
        let edited = outlineEntry.content
            .replacingOccurrences(of: "路径: 工程/项目/灯塔", with: "路径: 工程/小组件/灯塔天气")
            .replacingOccurrences(of: "标题: 灯塔", with: "标题: 灯塔天气")
            .replacingOccurrences(of: "钩子: 提到灯塔的时候先看这页", with: "钩子: 说到天气小组件时看这页")
        try await CatalogSeedDrafts.save(outlineEntry, text: edited, baseline: outlineEntry.content, wiki: wiki)
        outline = try XCTUnwrap(store.load(outline.id))
        let lighthouse = try XCTUnwrap(item(outline, "灯塔天气").change.direction)
        XCTAssertEqual(lighthouse.path, "工程/小组件/灯塔天气", "审计台读的就是改过的同一份")
        XCTAssertEqual(lighthouse.hook, "说到天气小组件时看这页")

        do {
            try await CatalogSeedDrafts.save(outlineEntry, text: edited, baseline: outlineEntry.content, wiki: wiki)
            XCTFail("别处改过要拒")
        } catch let e as CatalogSeedDrafts.EditError { XCTAssertEqual(e, .conflict) }
        let fresh = try XCTUnwrap(CatalogSeedDrafts.entries(wiki: wiki).first { $0.kind == .outline(outline.id) })
        let touchApproved = fresh.content.replacingOccurrences(of: "标题: 纸舟", with: "标题: 纸舟二")
        do {
            try await CatalogSeedDrafts.save(fresh, text: touchApproved, baseline: fresh.content, wiki: wiki)
            XCTFail("已批的只读")
        } catch let e as CatalogSeedDrafts.EditError { XCTAssertEqual(e, .readOnly("第 2 项「纸舟」已批了，只读")) }
        let badKind = fresh.content.replacingOccurrences(of: "类: 地点", with: "类: 动物")
        await XCTAssertThrowsErrorAsync { try await CatalogSeedDrafts.save(fresh, text: badKind, baseline: fresh.content, wiki: self.wiki) }

        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        entries = CatalogSeedDrafts.entries(wiki: wiki)
        let pageEntry = try XCTUnwrap(entries.first { if case .page = $0.kind { return true } else { return false } })
        XCTAssertTrue(pageEntry.editable)
        let newNow = pageEntry.content.replacingOccurrences(of: "纸舟是离线阅读工具\n", with: "纸舟是离线阅读工具，支持全文检索\n")
        XCTAssertNotEqual(newNow, pageEntry.content)
        try await CatalogSeedDrafts.save(pageEntry, text: newNow, baseline: pageEntry.content, wiki: wiki)
        guard case .page(let proposalId, let iid) = pageEntry.kind,
              case .newPage(let page) = store.load(proposalId)?.items.first(where: { $0.id == iid })?.change else { return XCTFail() }
        XCTAssertEqual(page.now, "纸舟是离线阅读工具，支持全文检索")
        let saved = try XCTUnwrap(CatalogSeedDrafts.entries(wiki: wiki).first { $0.path == pageEntry.path })
        for broken in [saved.content.replacingOccurrences(of: "（出处：CC memory/cc/project_c.md）", with: ""),
                       saved.content.replacingOccurrences(of: "CC memory/cc/project_c.md", with: "CC memory/cc/别的.md")] {
            await XCTAssertThrowsErrorAsync { try await CatalogSeedDrafts.save(saved, text: broken, baseline: saved.content, wiki: self.wiki) }
        }

        let seen = Dictionary((store.load(proposalId)?.items ?? []).map { ($0.id, $0.change) }, uniquingKeysWith: { a, _ in a })
        try await CatalogSeedDrafts.save(saved, text: saved.content.replacingOccurrences(of: "支持全文检索", with: "支持离线全文检索"),
                                         baseline: saved.content, wiki: wiki)
        do {
            try await WikiProposalReview.approve(proposalId, seen: seen, store: store, profileId: pid, context: ModelContext(container))
            XCTFail("不能沿旧预览无声批准后来改过的内容")
        } catch let e as WikiProposalStore.ProposalError { XCTAssertEqual(e, .changed(iid)) }
    }

    func testDraftFolderSitsUnderWikiAndAssistantFsStaysReadOnly() async throws {
        let model = SeedModel()
        model.outline = [entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md"])]
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        _ = await CatalogSession(job: job(model)).seed()
        let entries = CatalogSeedDrafts.entries(wiki: wiki)
        XCTAssertEqual(entries.count, 1)
        var index: [String: FileLibraryDisplay.FolderContents] = [FileLibraryMemoryFolder.wikiFolder: .init(folders: [], files: [])]
        FileLibrarySeedFolder.merge(entries, into: &index)
        XCTAssertEqual(index[FileLibraryMemoryFolder.wikiFolder]?.folders.first?.path, CatalogSeedDrafts.root)
        XCTAssertEqual(index[CatalogSeedDrafts.root]?.folders.map(\.path), [entries[0].folder])
        XCTAssertEqual(index[entries[0].folder]?.files.map(\.path), [entries[0].path])
        XCTAssertEqual(FileLibrarySeedFolder.displayName(CatalogSeedDrafts.root, entries: entries), "种子待批")
        let id = try XCTUnwrap(seedOutline()).id
        for path in ["memory/wiki/.proposals/\(id)/\(id).json", "memory/wiki/楼层/人/阿青.md", "memory/wiki/.proposals/\(id)/task.json"] {
            let input = String(decoding: try JSONSerialization.data(withJSONObject: ["path": path, "content": "x"]), as: UTF8.self)
            XCTAssertTrue(FileLibraryTools.execute(name: FileLibraryTools.Name.write.rawValue, inputJSON: input, profileId: pid).isError,
                          "主聊天 fs 对 memory 仍只读：\(path)")
        }
    }

    // MARK: - 留存、预算

    func testPurgeKeepsOpenTasksAndRemovesEndedOnesIncludingThoseWithoutOutline() async throws {
        let old = Date().addingTimeInterval(-40 * 86_400)
        let empty = SeedModel()
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        empty.emptyReason = "全是规矩"
        _ = await CatalogSession(job: job(empty)).seed(now: old)
        let ended = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(ended.state, .ended)

        let stuck = SeedModel()
        stuck.fail = { _ in "网关超时" }
        _ = await CatalogSession(job: job(stuck)).seed(now: old.addingTimeInterval(1))
        let open = try XCTUnwrap(tasks.all().first { $0.id != ended.id })
        XCTAssertEqual(open.status(outline: nil), .reading)

        store.purgeFinished()
        XCTAssertNil(tasks.load(ended.id), "没有目录的结束任务按结束时间满 30 天也清掉")
        XCTAssertNotNil(tasks.load(open.id), "还能续跑的任务不清")

        let model = SeedModel()
        model.outline = [entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md"])]
        model.pages = ["楼层/人/阿青": newPage("楼层/人/阿青", "人", "阿青", "阿青喜欢海图", ["memory/cc/user_a.md"])]
        let abandon = await CatalogSession(job: job(model)).abandonSeed(open.id)
        XCTAssertEqual(abandon.failures, [])
        _ = await CatalogSession(job: job(model)).seed()
        let id = try XCTUnwrap(seedOutline()).id
        try await approve(id)
        var finished = try XCTUnwrap(store.load(id))
        finished.finishedAt = old
        try store.save(finished)
        XCTAssertEqual(store.purgeFinished(), 0, "获批的页还没写，任务快照和目录都留着")
        XCTAssertNotNil(tasks.load(id))
        _ = await CatalogSession(job: job(model), finishSeed: { wiki, _, task in try CatalogSeed.finish(wiki: wiki, at: old, taskId: task) }).resumeSeed(id, now: old)
        XCTAssertNotNil(CatalogSeed.completion(wiki: wiki))
        finished = try XCTUnwrap(store.load(id))
        finished.finishedAt = old
        try store.save(finished)
        let content = try XCTUnwrap(contents(id).first)
        try await reject(content.id)
        var processed = try XCTUnwrap(store.load(content.id))
        processed.finishedAt = old
        try store.save(processed)
        XCTAssertEqual(store.purgeFinished(), 2)
        XCTAssertNil(tasks.load(id), "结束了、文件夹空了，连任务快照一起清")
    }

    func testSeedUsesItsOwnDepsWithoutDailyWriteBudget() async throws {
        let model = SeedModel()
        model.outline = [entry("楼层/人/阿青", "人", "阿青", ["memory/cc/user_a.md"])]
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        let seedGates = Counter()
        var j = job(model, deps: CatalogAgent.Deps(makeBackend: { model.backend }, gate: { _ in
            await seedGates.bump()
            return nil
        }))
        j.agentDeps = CatalogAgent.Deps(makeBackend: { model.backend }, gate: { _ in "写入预算用完" })
        let report = await CatalogSession(job: j).seed()
        XCTAssertNil(report.blocked)
        XCTAssertNotNil(seedOutline())
        XCTAssertEqual(seedGates.value, model.backend.requests.count, "每轮都过种子的闸（只有全局总闸），不过日常写入预算")
    }

    /// 第 10 段：种子交页走同一个来源检查；工具定义带诊断字段；沿正文提案的 run 链接打开的那一份记录里有交审诊断（输入 = 这一项的原料路径）
    func testSeedPageRunRecordCarriesSourceCheckAndDiagnostics() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.pageExtra = ["coverage": [["input": "memory/cc/user_a.md", "at": "记录"], ["input": "memory/cc/没读.md", "at": "记录"]]]
        _ = await CatalogSession(job: job(model)).seed(entry: .persona)
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id, [item(outline, "云桥城").id])
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])

        let submit = try XCTUnwrap(model.backend.requests.first?.tools.first { ($0["function"] as? [String: Any])?["name"] as? String == "submit_proposal" })
        let properties = (((submit["function"] as? [String: Any])?["parameters"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(properties["coverage"])
        XCTAssertNotNil(properties["preservation"])
        let cloud = try XCTUnwrap(contents(outline.id).first)
        XCTAssertEqual(cloud.items.first?.change.kindLabel, "追加记录", "坏出处那行丢了，合法的照交")
        let link = try XCTUnwrap(cloud.run)
        let text = try String(contentsOf: try XCTUnwrap(CatalogRunRecord.resolve(link, wiki: wiki)), encoding: .utf8)
        let diag = try XCTUnwrap(text.components(separatedBy: "<a id=\"").first { $0.contains("种子交页「云桥城」") && $0.contains("交审诊断") })
        for part in ["丢了 1 处", "记录没有可用出处", "- memory/cc/user_a.md：「记录」", "不是这次给的输入，不算：\n- memory/cc/没读.md",
                     "没交代（未评估）：memory/wiki/楼层/地点/云桥城.md", "这次没改已有页的「现在」"] {
            XCTAssertTrue(diag.contains(part), part)
        }
    }
}

private extension JSONEncoder {
    /// 和 CatalogSeedTaskStore 同一套日期编码（旧格式 checkpoint 夹具用）
    static var seedTaskForTest: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}
