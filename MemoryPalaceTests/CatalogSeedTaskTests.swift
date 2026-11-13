import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 假模型：不看提示词文案，按请求种类作答——出目录阶段的三种独立请求（没有工具）按开场第一行显式认：
/// 【这一批…】= 要点卡（每份按 `cards[路径]` 出卡，没给的按默认）、【名字清单】= 对齐（回 `merge`）、【A 池 · 本人】= 聚类（`userPages` / `topics` / `theatre` / `pending` 的成员按路径换成标号）；
/// 认不出的请求直接让测试失败。标号 → 原料按稳定身份认：卡按（名字 + 正文）对快照、聚类按（卡标题 + 要点）对存下的卡，认不出 / 认出两份都让测试失败。
/// 写正文那段（带工具、开场里有 item）逐页交 `pages[路径]`。请求超过 limit 次就报错，测试不会挂死
@MainActor
final class SeedModel {
    var wiki: WikiStore!
    /// 原料路径 → 卡的字段（title / gist / mentions / about_user / group / fact_domain；缺的按默认：标题 = 名字、没有 mentions、不关于本人、组「主题」、域 realWorld）
    var cards: [String: [String: Any]] = [:]
    /// 对齐回复的 merge 数组
    var merge: [[String: Any]] = []
    /// 聚类：成员写原料路径，假模型换成标号；路径按它看到的写（设了 userName 就是名字）
    var userPages: [(title: String, path: String, members: [String])] = []
    var topics: [(title: String, path: String, members: [String])] = []
    var theatre: [(title: String, path: String, members: [String])] = []
    var pending: [(title: String, path: String, members: [String])] = []
    var pages: [String: [[String: Any]]] = [:]
    var limit = 80
    /// 第 n 次请求直接失败（服务商原话）
    var fail: (Int) -> String? = { _ in nil }
    /// 出目录阶段：第 n 次请求（种类 cards / align / cluster，开场全文）改回这个事件（nil = 照常）
    var notesReply: (Int, String, String) -> AssistantBackendEvent? = { _, _, _ in nil }
    /// 第 n 次请求交页时换一套条目（nil = 用 pages）
    var pageOverride: (Int) -> [String: [[String: Any]]]? = { _ in nil }
    /// 第 n 次请求交页的参数是坏 JSON
    var badPageArgs: (Int) -> Bool = { _ in false }
    /// 交页时另带的字段（coverage / preservation）
    var pageExtra: [String: Any] = [:]
    /// 设了就像真模型那样：路径照它看到的写（本人那组写名字）
    var userName: String?
    /// 写正文那段对话里第 n 次请求直接这样回（nil = 照常交页）
    var pageEvent: (Int, String) -> AssistantBackendEvent? = { _, _ in nil }
    private(set) var lastCalls: [ToolCallBlock] = []
    /// 出目录阶段收到的请求（序号、种类）
    private(set) var notesRequests: [(n: Int, kind: String)] = []
    lazy var backend = FakeCatalogBackend { [unowned self] n, request in self.reply(n, request) }

    static func args(_ call: ToolCallBlock) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
    }

    static func call(_ name: String, _ args: [String: Any]) -> ToolCallBlock {
        let data = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
        return CatalogTestKit.call(name, String(decoding: data, as: UTF8.self))
    }

    static func json(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    /// 写正文那段对话的开场里写着这一页的 item
    static func pageItem(_ request: AssistantBackendRequest) -> String? {
        guard let opening = request.history.first?.content, let r = opening.range(of: "【这一页】item=") else { return nil }
        return String(opening[r.upperBound...].prefix { $0 != " " })
    }

    /// 出目录的三种请求；认不出 = nil（reply 里让测试失败）
    static func kind(_ request: AssistantBackendRequest) -> String? {
        let opening = request.history.first?.content ?? ""
        if opening.hasPrefix("【这一批") { return "cards" }
        if opening.hasPrefix("【名字清单】") { return "align" }
        if opening.hasPrefix("【A 池 · 本人】") || opening.hasPrefix("【第二轮 · 只补漏卡】") { return "cluster" }
        return nil
    }

    private func show(_ path: String) -> String { userName.map { WikiStore.shown(path, user: $0) } ?? path }

    /// 一份原料的默认标题（假模型和测试按它认成员）
    func title(_ path: String, task: CatalogSeedTask) -> String {
        if let t = cards[path]?["title"] as? String { return t }
        let name = task.materials.first { $0.path == path }?.name ?? path
        return String(name.prefix(20))
    }

    /// 批里的一份 → 快照里那一份（名字 + 正文都对上、只有一份）
    private func material(name: String, text: String, task: CatalogSeedTask) -> String? {
        let items = (try? task.snapshot(wiki: wiki)?.items()) ?? []
        let hits = items.filter { $0.name == name && $0.text == text && SeedNoteBatcher.cardable($0, entry: task.entry) }
        guard hits.count == 1 else {
            XCTFail("假模型：批里的「\(name)」在快照里对上 \(hits.count) 份（要正好一份）")
            return nil
        }
        return hits[0].path
    }

    fileprivate func cardsReply(_ request: String, task: CatalogSeedTask) -> String {
        // 重写那次的原因接在同一条 user 后面：先切掉，只看批本身
        let opening = request.components(separatedBy: "\n\n" + SeedNotePrompts.rewrite(reason: "").prefix(10)).first ?? request
        let pattern = try! NSRegularExpression(pattern: #"【(m\d+) · [^·\n]+ · (.+?) · \d+ 字 · 来源：[^\n]*】\n"#)
        let ns = opening as NSString
        let matches = pattern.matches(in: opening, range: NSRange(location: 0, length: ns.length))
        var out: [[String: Any]] = []
        for (i, m) in matches.enumerated() {
            let label = ns.substring(with: m.range(at: 1)), name = ns.substring(with: m.range(at: 2))
            let start = m.range.location + m.range.length
            let end = i + 1 < matches.count ? matches[i + 1].range.location - 2 : ns.length
            guard let path = material(name: name, text: ns.substring(with: NSRange(location: start, length: end - start)), task: task) else { continue }
            let given = cards[path] ?? [:]
            var card: [String: Any] = ["m": label, "title": title(path, task: task), "gist": given["gist"] ?? "要点：\(name)",
                                       "mentions": given["mentions"] ?? [], "about_user": given["about_user"] ?? false,
                                       "group": given["group"] ?? "主题", "fact_domain": given["fact_domain"] ?? "realWorld"]
            for key in ["when", "source_context", "slot_path"] {
                if let value = given[key] { card[key] = value }
            }
            if let group = card["group"] as? String { card["group"] = show(group) }
            out.append(card)
        }
        return Self.json(["cards": out])
    }

    /// 按生产池的稳定 c 标号还原身份，不用 L1，也不猜同标题卡的顺序。
    private func clusterReply(_ opening: String, task: CatalogSeedTask) -> String {
        let store = SeedNoteStore(wiki: wiki)
        let snapshot = (try? task.snapshot(wiki: wiki)?.items()) ?? []
        let cards = snapshot.filter { SeedNoteBatcher.cardable($0, entry: task.entry) }.compactMap { item -> SeedNoteCard? in
            guard var card = store.load(path: item.path, version: item.version) else { return nil }
            card.sourceContextIssue = card.contextIssue(for: item.sourceContext)
            return card
        }
        let aggregate = CatalogSeedNotes.aggregate(cards: cards, names: CatalogTestKit.names)
        let alignment = CatalogSeedTaskStore(wiki: wiki).loadNotes(SeedNoteAlignment.self, name: CatalogSeedTaskStore.alignedFileName, id: task.id) ?? SeedNoteAlignment(groups: [])
        let userPaths = Set(aggregate.userPaths).union(alignment.userPaths)
        let entityPaths = Set(alignment.groups.filter(CatalogSeedNotes.opensEntityPage).flatMap(\.paths))
        let realCards = cards.filter { $0.effectiveFactDomain == .realWorld }
        let pools = CatalogSeedNotes.clusterLabels(user: realCards.filter { userPaths.contains($0.path) },
            loose: realCards.filter { !userPaths.contains($0.path) && !entityPaths.contains($0.path) },
            theatre: cards.filter { $0.effectiveFactDomain == .inWorld },
            pending: cards.filter { $0.effectiveFactDomain != .realWorld && $0.effectiveFactDomain != .inWorld })
        let visible = Set(opening.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("- c") else { return nil }
            return line.dropFirst(2).components(separatedBy: " · ").first
        })
        let labels = Dictionary((pools.user + pools.loose + pools.theatre + pools.pending).filter { visible.contains($0.label) }.map { ($0.card.path, $0.label) }, uniquingKeysWith: { a, _ in a })
        func entries(_ list: [(title: String, path: String, members: [String])]) -> [[String: Any]] {
            list.map { ["title": $0.title, "path": show($0.path), "members": $0.members.compactMap { labels[$0] }] }
        }
        return Self.json(["user_pages": entries(userPages), "topics": entries(topics), "theatre": entries(theatre), "pending": entries(pending)])
    }

    func reply(_ n: Int, _ request: AssistantBackendRequest) -> AssistantBackendEvent? {
        if n > limit { return .failed("假模型：请求太多") }
        if let message = fail(n) { return .failed(message) }
        guard let task = CatalogSeedTaskStore(wiki: wiki).all().first else { return .failed("假模型：没有任务") }
        if request.tools.isEmpty {
            let opening = request.history.first?.content ?? ""
            guard let kind = Self.kind(request) else {
                XCTFail("假模型：认不出的出目录请求：\(opening.prefix(40))")
                return .failed("假模型：认不出的请求")
            }
            notesRequests.append((n, kind))
            if let forced = notesReply(n, kind, opening) { return forced }
            switch kind {
            case "cards": return .finished(cardsReply(opening, task: task))
            case "align": return .finished(Self.json(["merge": merge]))
            default: return .finished(clusterReply(opening, task: task))
            }
        }
        guard let page = Self.pageItem(request), let saved = WikiProposalStore(wiki: wiki).load(task.id) else { return .failed("假模型：不是写页请求") }
        // 写正文：每项单开一段对话，只交开场里那一项
        guard let item = saved.items.first(where: { $0.id == page }), let d = item.change.direction else { return .failed("假模型：没有这一项") }
        if let event = pageEvent(n, item.id) { return event }
        let pages = pageOverride(n) ?? self.pages
        let out = [badPageArgs(n) ? CatalogTestKit.call("submit_proposal", "{\"phase\":\"page\",\"item\":\"\(item.id)\",\"items\":[")
            : Self.call("submit_proposal", (["phase": "page", "item": item.id, "items": pages[d.path] ?? []] as [String: Any]).merging(pageExtra) { a, _ in a })]
        lastCalls = out
        return .toolCalls(out)
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

private final class TimeoutFlag: @unchecked Sendable {
    var on = false
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
    private let slotBasePath = PromptFolder.path(for: .slot(presetId: "preset-1", slotId: "custom-slot"))
    private var slotPath: String { slotBasePath + "#01" }
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
        j.floorBase = CatalogFloorBase(sections: [.init(path: slotBasePath, name: "自建槽", text: longSlot, isEnabled: true)])
        j.seedModel = "remote:test-credential/fake-model"
        j.seedDeps = deps
        return j
    }

    private func newPage(_ path: String, _ kind: String, _ title: String, _ text: String, _ sources: [String]) -> [[String: Any]] {
        [["type": "new_page", "path": path, "kind": kind, "title": title, "now": text,
          "records": [["text": "日期未注明 " + text, "sources": sources]]]]
    }

    /// 一张卡：标题 / 要点 / mentions（名字, 组）/ 是不是本人 / 整份归哪组
    private func card(_ title: String, _ gist: String, _ mentions: [(String, String)] = [], aboutUser: Bool = false, group: String = "主题") -> [String: Any] {
        ["title": title, "gist": gist, "mentions": mentions.map { ["name": $0.0, "group": $0.1] }, "about_user": aboutUser, "group": group, "fact_domain": "realWorld"]
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
        try await WikiProposalReview.reject(id, itemIds: items, store: store, profileId: pid, context: ModelContext(container))
    }

    /// 发给模型的全部文字（开场 / 历史 + 工具回执）
    private func sent(_ model: SeedModel) -> String {
        model.backend.requests.map { r in (r.history.map(\.content) + r.toolTurns.flatMap(\.results).map(\.text)).joined() }.joined()
    }

    /// 出目录阶段的请求（没有工具）
    private func notesRequests(_ model: SeedModel) -> [AssistantBackendRequest] {
        model.backend.requests.filter { $0.tools.isEmpty }
    }

    /// 四份原料 + 自建槽：三份同提阿青合一实体页；低量项目和反馈进 B 待归类；
    /// wiki 已有「云桥城」，单份正式原料也能更新。
    private func standardFixture(_ model: SeedModel) throws {
        try cc("user_a.md", type: "user", title: "阿青的作息", body: "阿青每天早上七点去码头看船。")
        try cc("user_b.md", type: "user", title: "阿青的爱好", body: "阿青收集《灯塔航线》的纸质海图。")
        try cc("project_c.md", type: "project", title: "两个项目", body: "纸舟是离线阅读工具。灯塔是天气小组件。")
        try cc("feedback_x.md", type: "feedback", title: "回复风格", body: "FEEDBACK_ONLY_MARKER 回答先给结论")
        try cc("private_y.md", type: "user", title: "私密", body: "PRIVATE_ONLY_MARKER")
        try wiki.save(WikiPage(path: "地点/云桥城", kind: .place, hook: "提到云桥城", title: "云桥城", now: "云桥城有座旧码头。", factDomain: .realWorld))
        model.cards = [
            "memory/cc/user_a.md": card("阿青的作息", "阿青每天早上七点去码头看船", [("阿青", "人"), ("云桥城", "地点")], group: "人"),
            "memory/cc/user_b.md": card("阿青的爱好", "阿青收集《灯塔航线》的纸质海图", [("阿青", "人")], group: "人"),
            "memory/cc/project_c.md": card("两个项目", "纸舟是离线阅读工具，灯塔是天气小组件", [("纸舟", "项目"), ("灯塔", "项目")], group: "项目"),
            "memory/cc/feedback_x.md": card("回复风格", "回答先给结论"),
            slotPath: card("自建槽设定", "阿青养了一只叫纸鸢的猫", [("阿青", "人")], group: "人"),
        ]
        model.merge = [["into": "wiki:地点/云桥城", "names": ["云桥城"]]]
        model.topics = [("还没归类的", "主题/待归类", ["memory/cc/project_c.md", "memory/cc/feedback_x.md"])]
        model.pages = [
            "人/阿青": newPage("人/阿青", "人", "阿青", "阿青每天早上七点去码头看船，收集纸质海图，养了猫纸鸢",
                                  ["memory/cc/user_a.md", "memory/cc/user_b.md", slotPath]),
            "主题/待归类": newPage("主题/待归类", "主题", "还没归类的", "纸舟是离线阅读工具", ["memory/cc/project_c.md"]),
            "地点/云桥城": [["type": "append", "path": "地点/云桥城",
                                "records": [["text": "日期未注明 阿青每天早上去云桥城码头看船", "sources": ["memory/cc/user_a.md"]],
                                            ["text": "没出处的一行", "sources": ["memory/cc/不存在.md"]]]]],
        ]
    }

    /// 单份实体不够开页；本人偏好卡由 A 池起页，保留后续交页 / 续跑消费者回归。
    private func aqingFixture(_ model: SeedModel, body: String = "阿青喜欢海图。") throws {
        try cc("user_a.md", type: "user", title: "阿青", body: body)
        try cc("user_preference.md", type: "user", title: "海图偏好", body: "本人喜欢纸质海图。")
        model.cards = ["memory/cc/user_a.md": card("阿青", "阿青喜欢海图", [("阿青", "人")], aboutUser: true, group: "人"),
                       slotPath: card("回复偏好", "本人希望简明回答", aboutUser: true),
                       "memory/cc/user_preference.md": card("海图偏好", "本人喜欢纸质海图", aboutUser: true)]
        model.userPages = [("阿青", "{{user}}/阿青", ["memory/cc/user_a.md", slotPath, "memory/cc/user_preference.md"])]
        model.pages = ["{{user}}/阿青": newPage("{{user}}/阿青", "{{user}}", "阿青", "阿青喜欢海图", ["memory/cc/user_a.md"])]
    }

    /// 只给确实要消费项目实体页的安全 / 编辑回归补足正式原料；标准夹具仍验证单份实体不开页。
    private func projectEntityFixture(_ model: SeedModel) throws {
        try standardFixture(model)
        try supportingCards(model, mentions: [("纸舟", "项目"), ("灯塔", "项目")])
        model.cards["memory/cc/feedback_x.md"] = card("回复风格", "阿青希望回答先给结论", [("阿青", "人")], group: "人")
        model.pages["项目/纸舟"] = newPage("项目/纸舟", "项目", "纸舟", "纸舟是离线阅读工具", ["memory/cc/project_c.md"])
        model.pages["项目/灯塔"] = newPage("项目/灯塔", "项目", "灯塔", "灯塔是天气小组件", ["memory/cc/project_c.md"])
    }

    private func supportingCards(_ model: SeedModel, mentions: [(String, String)]) throws {
        for i in 1...2 {
            let file = "support_\(i).md"
            try cc(file, type: "user", title: "补充原料\(i)", body: "虚构补充原料\(i)。")
            model.cards["memory/cc/" + file] = card("补充原料\(i)", "补充说明\(i)", mentions)
        }
    }

    private func salvageFixture(_ model: SeedModel) throws -> (job: CatalogJob, paths: [String]) {
        let paths = (1...4).map { "memory/cc/sketch_\($0).md" }
        for i in 1...4 {
            try cc("sketch_\(i).md", type: "user", title: "星砚笔记\(i)", body: "云桥城写生原料\(i)")
            model.cards[paths[i - 1]] = card("星砚笔记\(i)", "星砚在云桥城画第\(i)幅画", [("星砚", "人")], group: "人")
        }
        model.cards[slotPath] = card("云桥城写生计划", "星砚在云桥城写生", [("星砚", "人")], group: "人")
        var j = job(model)
        j.floorBase = CatalogFloorBase(sections: [.init(path: slotBasePath, name: "写生计划", text: "云桥城写生计划原料", isEnabled: true)])
        return (j, [slotPath] + paths)
    }

    func testDirectionRejectsNonRealUserPagesAndUnknownOrDifferentUpdateDomains() throws {
        let source = "memory/cc/林栖.md"
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .cc,
            modelName: "fake", modelKey: nil, createdAt: Date(), run: .init(path: ".runs/test.md", anchor: nil))
        task.read = [source: "v1"]
        var direction = WikiProposal.Direction(path: "{{user}}/云桥城", title: "云桥城", kind: .user,
            action: .newPage, reason: "虚构夹具", mode: .seed, sources: [source], factDomain: .inWorld)
        func failure(_ d: WikiProposal.Direction) -> String {
            switch CatalogSeedTools.checkDirection(d, task: task, wiki: wiki) {
            case .failure(let error): return error.localizedDescription
            case .success: XCTFail("应该拒绝 \(d.path)"); return ""
            }
        }
        XCTAssertTrue(failure(direction).contains("设定 / 待判页只能在主题组"))
        direction.path = "主题/云桥城"
        direction.kind = .topic
        direction.factDomain = .realWorld
        try wiki.save(WikiPage(path: direction.path, kind: .topic, title: "云桥城"))
        direction.action = .update
        XCTAssertTrue(failure(direction).contains("已有页没记事实域"))
        direction.factDomain = .inWorld
        try wiki.save(WikiPage(path: direction.path, kind: .topic, title: "云桥城", factDomain: .mixed))
        XCTAssertTrue(failure(direction).contains("页域不合"))
        try wiki.save(WikiPage(path: direction.path, kind: .topic, title: "云桥城", factDomain: .inWorld))
        XCTAssertEqual(try CatalogSeedTools.checkDirection(direction, task: task, wiki: wiki).get().factDomain, .inWorld)
        direction.factDomain = nil
        try wiki.save(WikiPage(path: direction.path, kind: .topic, title: "云桥城"))
        XCTAssertNil(try CatalogSeedTools.checkDirection(direction, task: task, wiki: wiki).get().factDomain)
    }

    func testCatalogDomainRoutingUsesOnlyRealAnchorsAndRealBackfillAndPlacesAllPools() async throws {
        let model = SeedModel()
        let real = "memory/cc/real.md", theatre = "memory/cc/theatre.md", candidate = "memory/cc/candidate.md"
        try cc("real.md", type: "user", title: "林栖造船", body: "林栖在云桥城修船。")
        try cc("theatre.md", type: "user", title: "设定林栖", body: "设定中岚舟和林栖在云桥城造船。")
        try cc("candidate.md", type: "user", title: "船厂见闻", body: "林栖带星砚去看船。")
        model.cards[real] = card("现实林栖", "林栖在云桥城修船", [("林栖", "人")])
        model.cards[theatre] = card("设定中岚舟造船", "设定中岚舟和林栖造船", [("林栖", "人")], aboutUser: true)
        model.cards[theatre]?["fact_domain"] = "inWorld"
        model.cards[candidate] = card("船厂见闻", "星砚看船")
        for (file, domain) in [("mixed.md", "mixed"), ("unknown.md", "unspecified")] {
            try cc(file, type: "user", title: "星砚的待判笔记", body: "星砚在云桥城的\(domain)记录。")
            model.cards["memory/cc/" + file] = card("待判的星砚", "星砚在云桥城的记录", aboutUser: true)
            model.cards["memory/cc/" + file]?["fact_domain"] = domain
        }
        try wiki.save(WikiPage(path: "人/林栖", kind: .person, title: "林栖", factDomain: .realWorld))
        model.theatre = [("林栖在设定中的造船生活", "主题/设定林栖", [theatre])]
        model.pending = [("星砚的写生记录", "主题/待判林栖", ["memory/cc/mixed.md", "memory/cc/unknown.md"])]
        let nonReal: [(String, SeedFactDomain?)] = [("旧林栖", nil), ("设定林栖", .inWorld), ("混合林栖", .mixed), ("待判林栖", .unspecified)]
        for (name, domain) in nonReal {
            try wiki.save(WikiPage(path: "主题/" + name, kind: .topic, title: name, factDomain: domain))
        }
        model.merge = [["into": "wiki:人/林栖", "names": ["林栖"]]]
        var j = job(model)
        j.floorBase = CatalogFloorBase(sections: [])
        let report = await CatalogSession(job: j).seed()
        XCTAssertEqual(report.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        let directions = outline.items.compactMap(\.change.direction)
        let realDirection = try XCTUnwrap(directions.first { $0.path == "人/林栖" })
        XCTAssertEqual(realDirection.sources, [real])
        XCTAssertEqual(realDirection.factDomain, .realWorld)
        XCTAssertEqual(realDirection.candidates?.map(\.path), [candidate])
        XCTAssertEqual(realDirection.candidates?.first?.factDomain, .realWorld)
        XCTAssertFalse(directions.contains { $0.path.hasPrefix("{{user}}/") })
        XCTAssertEqual(directions.first { $0.factDomain == .inWorld }?.sources, [theatre])
        XCTAssertEqual(directions.first { $0.factDomain == .unspecified }?.sources,
            ["memory/cc/mixed.md", "memory/cc/unknown.md"])
        let task = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertEqual(Set(directions.flatMap { $0.sources ?? [] }), Set(task.carded?.keys.map { $0 } ?? []))
        let align = try XCTUnwrap(notesRequests(model).first { $0.history[0].content.hasPrefix("【名字清单】") })
        XCTAssertTrue(align.history[0].content.contains("wiki:人/林栖（"))
        for (name, _) in nonReal { XCTAssertFalse(align.history[0].content.contains("wiki:主题/" + name)) }
        let clustered = try XCTUnwrap(tasks.loadNotes(SeedNoteClusters.self, name: CatalogSeedTaskStore.clusteredFileName, id: task.id))
        XCTAssertEqual(clustered.theatre.first?.paths, [theatre])
        XCTAssertEqual(clustered.pending.first?.factDomain, .unspecified)
        XCTAssertEqual(clustered.theatre.first?.title, "林栖在设定中的造船生活")
        XCTAssertEqual(clustered.pending.first?.title, "星砚的写生记录")
        XCTAssertEqual(directions.first { $0.factDomain == .inWorld }?.title, "林栖在设定中的造船生活")
        XCTAssertEqual(directions.first { $0.factDomain == .unspecified }?.title, "星砚的写生记录")
    }

    func testAuditCannotMoveInWorldDirectionOutOfTopics() async throws {
        let model = SeedModel()
        let source = "memory/cc/theatre.md"
        try cc("theatre.md", type: "user", title: "林栖的造船设定", body: "设定中林栖在云桥城造船。")
        model.cards[source] = card("林栖的造船设定", "林栖在云桥城造船")
        model.cards[source]?["fact_domain"] = "inWorld"
        var j = job(model)
        j.floorBase = CatalogFloorBase(sections: [])
        let report = await CatalogSession(job: j).seed()
        XCTAssertEqual(report.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        let original = try XCTUnwrap(outline.items.first)
        var edited = try XCTUnwrap(original.change.direction)
        XCTAssertEqual(edited.factDomain, .inWorld)
        edited.path = "人/林栖"
        edited.kind = .person
        do {
            try await CatalogSeedDrafts.saveChange(outline.id, itemId: original.id, change: .direction(edited),
                baseline: original.change, wiki: wiki)
            XCTFail("审计台不能把设定项移到实体组")
        } catch let error as CatalogSeedDrafts.EditError {
            XCTAssertEqual(error, .invalid("设定 / 待判页只能在主题组"))
        }
        XCTAssertEqual(store.load(outline.id)?.items.first?.change, original.change)
    }

    func testCatalogRelocatesEntityCollidingWithLegacyPageAndReportsIt() async throws {
        let model = SeedModel()
        try cc("real.md", type: "user", title: "林栖造船", body: "林栖在云桥城修船。")
        model.cards["memory/cc/real.md"] = card("林栖造船", "林栖在云桥城修船", [("林栖", "人")])
        try supportingCards(model, mentions: [("林栖", "人")])
        try wiki.save(WikiPage(path: "人/林栖", kind: .person, title: "林栖旧页"))
        var j = job(model)
        j.floorBase = CatalogFloorBase(sections: [])
        let report = await CatalogSession(job: j).seed()
        XCTAssertEqual(report.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(outline.items.first?.change.direction?.path, "人/林栖（现实）")
        XCTAssertEqual(outline.items.first?.change.direction?.action, .newPage)
        let record = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(XCTUnwrap(outline.run), wiki: wiki)), encoding: .utf8)
        XCTAssertTrue(record.contains("实体撞旧页另起路径 1 项"))
        MemoryWriteLog.flush()
        XCTAssertEqual(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).filter { $0.note.contains("实体撞旧页另起路径 1 项") }.count, 1)
        XCTAssertNil(wiki.read("人/林栖")?.factDomain)
    }

    func testOnlyLongTitleCardIsRewrittenAndCorrectedTitleIsSaved() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        let path = fixture.paths[2]
        let long = String(repeating: "舟", count: 23), short = String(repeating: "砚", count: 18)
        model.cards[path]?["title"] = long
        model.notesReply = { [unowned model] n, kind, _ in
            if n == 2 && kind == "cards" { model.cards[path]?["title"] = short }
            return nil
        }
        let report = await CatalogSession(job: fixture.job).seed()
        XCTAssertEqual(report.failures, [])
        let task = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(Set(try XCTUnwrap(task.carded).keys), Set(fixture.paths))
        let requests = notesRequests(model).filter { SeedModel.kind($0) == "cards" }
        XCTAssertEqual(requests.count, 2)
        let rewrite = requests[1].history[0].content
        XCTAssertTrue(rewrite.hasPrefix("【这一批 1 份】"))
        XCTAssertTrue(rewrite.contains("【m3 ·") && rewrite.contains("现在 23 字") && rewrite.contains("20 字"))
        XCTAssertTrue(rewrite.contains("云桥城写生原料2"))
        for marker in ["云桥城写生原料1", "云桥城写生原料3", "云桥城写生原料4", "云桥城写生计划原料"] { XCTAssertFalse(rewrite.contains(marker)) }
        let saved = try XCTUnwrap(SeedNoteStore(wiki: wiki).load(path: path, version: try XCTUnwrap(task.carded?[path])))
        XCTAssertEqual(saved.title, short)
        MemoryWriteLog.flush()
        XCTAssertFalse(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).contains { $0.note.contains("软检查提醒") })
    }

    func testStillLongTitleIsSavedUncutWithOneSoftNote() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        let path = fixture.paths[2], long = String(repeating: "舟", count: 23)
        model.cards[path]?["title"] = long
        let report = await CatalogSession(job: fixture.job).seed()
        XCTAssertEqual(report.failures, [])
        let task = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(task.carded?.count, 5)
        XCTAssertEqual(notesRequests(model).filter { SeedModel.kind($0) == "cards" }.count, 2)
        XCTAssertTrue(model.backend.requests[1].history[0].content.hasPrefix("【这一批 1 份】"))
        XCTAssertEqual(SeedNoteStore(wiki: wiki).load(path: path, version: try XCTUnwrap(task.carded?[path]))?.title, long)
        let outline = try XCTUnwrap(seedOutline())
        let run = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(XCTUnwrap(outline.run), wiki: wiki)), encoding: .utf8)
        XCTAssertTrue(run.contains("5 张合格（其中 1 张标题超长收下）· 1 张重写 · 0 张没出成"))
        XCTAssertTrue(run.contains("title 23 字（目标 20）"))
        MemoryWriteLog.flush()
        XCTAssertTrue(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).contains { $0.ok && $0.note.contains("软检查提醒 1 条") })
    }

    func testMissingGistKeepsFourCardsAndOutlineResumeDoesNotRetrySkippedMaterial() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        let path = fixture.paths[2]
        model.cards[path]?["gist"] = NSNull()
        let report = await CatalogSession(job: fixture.job).seed()
        XCTAssertEqual(report.failures, [])
        let task = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(task.carded?.count, 4)
        XCTAssertEqual(task.uncarded.map(\.path), [path])
        XCTAssertEqual(task.notes?.failedPaths, [path])
        let outline = try XCTUnwrap(seedOutline())
        let skipped = try XCTUnwrap(outline.seedSkipped?.first { $0.hasPrefix("没出成要点卡：星砚笔记2 · ") })
        XCTAssertTrue(skipped.contains("gist"), skipped)
        XCTAssertEqual(Set(outline.items.flatMap { $0.change.direction?.sources ?? [] }), Set(fixture.paths.filter { $0 != path }))
        let cardStore = SeedNoteStore(wiki: wiki)
        let beforeCards = fixture.paths.filter { $0 != path }.compactMap { cardStore.load(path: $0, version: task.carded?[$0] ?? "") }
        XCTAssertEqual(beforeCards.count, 4)
        MemoryWriteLog.flush()
        XCTAssertTrue(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).contains { $0.ok && $0.note.contains("1 份没出要点卡，先按其余出目录") })
        let before = model.backend.requests.count
        model.cards[path]?["gist"] = "星砚在云桥城画第二幅画"
        let resumed = await CatalogSession(job: fixture.job).resumeSeed(task.id)
        XCTAssertEqual(resumed.failures, [])
        XCTAssertEqual(model.backend.requests.count, before, "目录已交：续跑不再补失败原料")
        let finished = try XCTUnwrap(tasks.load(task.id))
        XCTAssertEqual(finished.carded?.count, 4)
        XCTAssertEqual(finished.notes?.failedPaths, [path])
        XCTAssertEqual(seedOutline()?.seedSkipped, outline.seedSkipped)
        for card in beforeCards { XCTAssertEqual(cardStore.load(path: card.path, version: card.version), card) }
    }

    func testRewrittenTitleAboveThirtyFailsOnlyThatMaterialAndStillSubmitsOutline() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        let path = fixture.paths[2]
        model.cards[path]?["title"] = String(repeating: "舟", count: 23)
        model.notesReply = { [unowned model] n, kind, _ in
            if n == 2 && kind == "cards" { model.cards[path]?["title"] = String(repeating: "砚", count: 33) }
            return nil
        }
        let report = await CatalogSession(job: fixture.job).seed()
        XCTAssertEqual(report.failures, [])
        let task = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(Set(try XCTUnwrap(task.carded).keys), Set(fixture.paths.filter { $0 != path }))
        XCTAssertEqual(task.notes?.failedPaths, [path])
        XCTAssertNil(SeedNoteStore(wiki: wiki).load(path: path, version: try XCTUnwrap(task.read[path])))
        let outline = try XCTUnwrap(seedOutline())
        let skipped = try XCTUnwrap(outline.seedSkipped?.first { $0.hasPrefix("没出成要点卡：星砚笔记2 · ") })
        XCTAssertTrue(skipped.contains("title") && skipped.contains("33"), skipped)
        XCTAssertFalse(outline.items.flatMap { $0.change.direction?.sources ?? [] }.contains(path))
        MemoryWriteLog.flush()
        XCTAssertTrue(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).contains { $0.ok && $0.note.contains("1 份没出要点卡，先按其余出目录") })
    }

    func testRewriteRequestFailureKeepsGoodCardsStopsAndResumesOnlyMissingMaterial() async throws {
        for mode in ["API", "blocked", "cancelled"] {
            try? FileManager.default.removeItem(at: root)
            let model = SeedModel()
            let fixture = try salvageFixture(model)
            let path = fixture.paths[2]
            model.cards[path]?["gist"] = NSNull()
            model.notesReply = { n, kind, _ in
                n == 2 && kind == "cards" && mode == "API" ? .failed("网关超时 504") : nil
            }
            let gates = Counter()
            var session: CatalogSession!
            let deps = CatalogAgent.Deps(makeBackend: { model.backend }, gate: { _ in
                await gates.bump()
                if await gates.value == 2 {
                    if mode == "blocked" { return "预算到顶" }
                    if mode == "cancelled" { await session.cancel() }
                }
                return nil
            })
            var seedJob = fixture.job
            seedJob.seedDeps = deps
            session = CatalogSession(job: seedJob)
            let report = await session.seed()
            if mode == "API" { XCTAssertEqual(report.failures.count, 1) }
            if mode == "blocked" { XCTAssertEqual(report.blocked, "预算到顶") }
            if mode == "cancelled" { XCTAssertTrue(report.cancelled) }
            XCTAssertNil(seedOutline(), mode)
            let task = try XCTUnwrap(tasks.all().first)
            XCTAssertEqual(task.state, .stopped, mode)
            XCTAssertEqual(task.carded?.count, 4, mode)
            XCTAssertEqual(task.uncarded.map(\.path), [path], mode)
            let reason = try XCTUnwrap(task.notes?.batches.first { !$0.ok }?.reason)
            let expected = mode == "API" ? "网关超时 504" : mode == "blocked" ? "被拦：预算到顶" : "停了"
            XCTAssertTrue(reason.contains(expected), reason)
            XCTAssertFalse(reason.contains("请求没有回复"), reason)
            XCTAssertEqual(model.backend.requests.count, mode == "API" ? 2 : 1, mode)
            let before = model.backend.requests.count
            model.cards[path]?["gist"] = "星砚在云桥城画第二幅画"
            model.notesReply = { _, _, _ in nil }
            let resumed = await CatalogSession(job: fixture.job).resumeSeed(task.id)
            XCTAssertEqual(resumed.failures, [], mode)
            let asked = model.backend.requests.dropFirst(before).filter { SeedModel.kind($0) == "cards" }
            XCTAssertEqual(asked.count, 1, mode)
            let opening = try XCTUnwrap(asked.first?.history.first?.content)
            XCTAssertTrue(opening.hasPrefix("【这一批 1 份】") && opening.contains("云桥城写生原料2"), opening)
            for marker in ["云桥城写生原料1", "云桥城写生原料3", "云桥城写生原料4", "云桥城写生计划原料"] {
                XCTAssertFalse(opening.contains(marker), marker)
            }
            XCTAssertEqual(tasks.load(task.id)?.carded?.count, 5, mode)
            XCTAssertNotNil(seedOutline(), mode)
        }
    }

    func testWholeBatchRewriteContextFailureNamesWholeBatchAndKeepsGoodCards() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        let path = fixture.paths[2]
        let raw = "prompt is too long: 250000 tokens > 200000 maximum"
        model.notesReply = { [unowned model] n, kind, _ in
            guard kind == "cards" else { return nil }
            if n == 1 {
                var cards = fixture.paths.enumerated().map { index, path -> [String: Any] in
                    var card = model.cards[path] ?? [:]
                    card["m"] = "m\(index + 1)"
                    return card
                }
                cards.append(cards[2])
                cards.append(cards[2])
                return .finished(SeedModel.json(["cards": cards]))
            }
            return .failed(raw)
        }
        let report = await CatalogSession(job: fixture.job).seed()
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(model.backend.requests.count, 2)
        XCTAssertTrue(model.backend.requests[1].history[0].content.hasPrefix("【这一批 5 份】"))
        let task = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(task.carded?.count, 4)
        XCTAssertEqual(task.uncarded.map(\.path), [path])
        let reason = try XCTUnwrap(task.notes?.batches.first { !$0.ok }?.reason)
        XCTAssertTrue(reason.contains("整批重写请求过长：") && reason.contains(raw), reason)
        XCTAssertFalse(reason.contains("没出卡原料的重写请求过长"), reason)
        XCTAssertFalse(reason.contains("请求没有回复"), reason)
        XCTAssertNil(seedOutline())
        model.notesReply = { _, _, _ in nil }
        let before = model.backend.requests.count
        let resumed = await CatalogSession(job: fixture.job).resumeSeed(task.id)
        XCTAssertEqual(resumed.failures, [])
        let asked = model.backend.requests.dropFirst(before).filter { SeedModel.kind($0) == "cards" }
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked.first?.history.first?.content.hasPrefix("【这一批 1 份】") == true)
        XCTAssertNotNil(seedOutline())
    }

    func testInvalidMentionIsDroppedAfterRewriteWithoutLosingTheCard() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        let path = fixture.paths[2]
        model.cards[path]?["mentions"] = [["name": "星砚", "group": "人"], ["name": "云桥城写生", "group": "梗"]]
        let report = await CatalogSession(job: fixture.job).seed()
        XCTAssertEqual(report.failures, [])
        let task = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(task.carded?.count, 5)
        let saved = try XCTUnwrap(SeedNoteStore(wiki: wiki).load(path: path, version: try XCTUnwrap(task.carded?[path])))
        XCTAssertEqual(saved.mentions, [.init(name: "星砚", group: "人")])
        MemoryWriteLog.flush()
        XCTAssertTrue(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).contains { $0.ok && $0.note.contains("软检查提醒 1 条") })
        let run = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(XCTUnwrap(seedOutline()?.run), wiki: wiki)), encoding: .utf8)
        XCTAssertTrue(run.contains("已丢掉该 mention"))
    }

    func testClusterStillLongTitleKeepsThePageAndLogsOneSoftNote() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        for path in fixture.paths { model.cards[path]?["mentions"] = [] }
        let long = String(repeating: "舟", count: 23)
        model.topics = [(long, "主题/云桥城写生", fixture.paths)]
        let report = await CatalogSession(job: fixture.job).seed()
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(model.notesRequests.map(\.kind), ["cards", "cluster", "cluster"])
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(outline.items.compactMap { $0.change.direction?.title }, [long])
        XCTAssertEqual(Set(outline.items[0].change.direction?.sources ?? []), Set(fixture.paths))
        let run = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(XCTUnwrap(outline.run), wiki: wiki)), encoding: .utf8)
        XCTAssertTrue(run.contains("title 23 字（目标 20）"))
        MemoryWriteLog.flush()
        XCTAssertTrue(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).contains { $0.ok && $0.note.contains("聚类：") && $0.note.contains("软检查提醒 1 条") })
    }

    // MARK: - 要点卡 → 代码聚出目录暂停 → 同任务逐页写 → 正文再批 → 完成按整份目录

    func testCardsThenOutlinePausesWritesApprovedPagesAndCompletesByWholeOutline() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let pagesBefore = wiki.pagePaths()

        let first = await CatalogSession(job: job(model)).seed(entry: .persona)
        XCTAssertEqual(first.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(outline.items.count, 3, "\(outline.items.compactMap { $0.change.direction?.path })")
        XCTAssertTrue(outline.items.allSatisfy { $0.state == .pending && $0.change.direction?.mode == .seed })
        let aq = try XCTUnwrap(item(outline, "阿青").change.direction)
        XCTAssertEqual(aq.sources, [slotPath, "memory/cc/user_a.md", "memory/cc/user_b.md"], "提到阿青的三份合一页，sources 精确升序")
        XCTAssertEqual(aq.path, "人/阿青")
        XCTAssertEqual(aq.kind, .person)
        XCTAssertEqual(aq.hook, "", "目录阶段钩子留空，写页时写手出")
        XCTAssertEqual(aq.reason, "3 份原料\n- 自建槽 · 设定填充。设定填充。设定 · 自建槽设定\n- 阿青的作息 · 阿青的作息\n- 阿青的爱好 · 阿青的爱好")
        let cloud = try XCTUnwrap(item(outline, "云桥城").change.direction)
        XCTAssertEqual(cloud.action, .update, "对齐合进 wiki 锚 → 更新已有页")
        XCTAssertEqual(cloud.path, "地点/云桥城")
        XCTAssertEqual(cloud.sources, ["memory/cc/user_a.md"])
        let projects = try XCTUnwrap(item(outline, "还没归类的").change.direction)
        XCTAssertEqual(projects.path, "主题/待归类")
        XCTAssertEqual(projects.sources, ["memory/cc/feedback_x.md", "memory/cc/project_c.md"])
        XCTAssertTrue(projects.aliases.isEmpty, "低门槛名字不挂成触发词")
        XCTAssertFalse(outline.items.contains { ["项目/纸舟", "项目/灯塔"].contains($0.change.direction?.path ?? "") })
        XCTAssertNotNil(outline.run)
        XCTAssertEqual(store.list().count, 1, "目录批之前没有正文提案")
        XCTAssertEqual(wiki.pagePaths(), pagesBefore)
        let task = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertEqual(task.modelKey, "remote:test-credential/fake-model")
        XCTAssertEqual(task.layout, 3)
        let materials = task.materials.map(\.path)
        XCTAssertTrue(materials.contains("memory/wiki/INDEX.md") && materials.contains("memory/wiki/地点/INDEX.md"), "wiki 索引也进快照")
        XCTAssertEqual(task.carded?.count, 5, "Prompt + 4 份 CC 都出了卡；wiki 不出卡")
        XCTAssertEqual(task.notes?.batches.map(\.ok), [true])
        XCTAssertTrue(task.notes?.aligned == true && task.notes?.clustered == true)
        let requestsAfterOutline = model.backend.requests.count
        XCTAssertEqual(requestsAfterOutline, 3, "一批卡 + 对齐 + 聚类（feedback 没实体进无实体池）")
        XCTAssertEqual(model.notesRequests.map(\.kind), ["cards", "align", "cluster"])
        for r in notesRequests(model) {
            XCTAssertEqual(r.history.count, 1, "每个请求独立：只有一条 user")
            XCTAssertTrue(r.toolTurns.isEmpty && r.tools.isEmpty)
        }
        XCTAssertTrue(task.skipped.contains { $0.contains("跳过 1 份私人文件（private_）") })
        for marker in ["PRIVATE_ONLY_MARKER", "private_y.md"] { XCTAssertFalse(sent(model).contains(marker), marker) }
        XCTAssertTrue(materials.contains("memory/cc/feedback_x.md"), "feedback 不按类型扔，交给模型按内容分")
        XCTAssertTrue(sent(model).contains("FEEDBACK_ONLY_MARKER"))
        XCTAssertTrue(notesRequests(model)[0].history[0].content.contains(longSlot), "Prompt 自建槽 3000 字之后的事实完整进了它那一批")
        XCTAssertFalse(notesRequests(model)[0].history[0].content.contains("云桥城有座旧码头"), "wiki 页不出卡、不进批")
        XCTAssertTrue(notesRequests(model)[1].history[0].content.contains("wiki:地点/云桥城（标题 云桥城"), "对齐名单带已有页的锚")
        XCTAssertTrue(outline.seedSkipped?.filter { $0.hasPrefix("没归进目录") }.isEmpty ?? true, "两池全覆盖")

        let aqing = item(outline, "阿青").id, paper = item(outline, "还没归类的").id
        try await approve(outline.id, [aqing, paper])
        XCTAssertEqual(model.backend.requests.count, requestsAfterOutline, "批之前、批这一步本身都不调模型")
        let second = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(second.failures, [])
        let resumed = model.backend.requests[requestsAfterOutline]
        XCTAssertEqual(resumed.history.count, 1, "写正文每页单开一段对话：只有这一页的开场")
        XCTAssertTrue(resumed.toolTurns.isEmpty)
        let pageOpening = resumed.history[0].content
        XCTAssertTrue(pageOpening.contains("【这一页】item=\(aqing)"))
        for kept in ["阿青的作息", "阿青的爱好", "自建槽设定", "阿青养了一只叫纸鸢的猫", "地点/云桥城", "主题/待归类"] {
            XCTAssertTrue(pageOpening.contains(kept), "这一项的卡和整份目录：\(kept)")
        }
        for dropped in ["阿青每天早上七点去码头看船。", "阿青收集《灯塔航线》的纸质海图。", tailFact, longSlot, "FEEDBACK_ONLY_MARKER", "云桥城有座旧码头", "PRIVATE_ONLY_MARKER"] {
            XCTAssertFalse(pageOpening.contains(dropped), "全文不进写页开场：\(dropped)")
        }
        let pageRequests = model.backend.requests[requestsAfterOutline...]
        XCTAssertEqual(pageRequests.count, 2, "两页各一段对话、各一轮")
        XCTAssertTrue(pageRequests.last?.history[0].content.contains("【这一页】item=\(paper)") ?? false)
        var pages = contents(outline.id)
        XCTAssertEqual(Set(pages.compactMap(\.title)), ["阿青", "还没归类的"], "只写获批的项")
        XCTAssertNil(CatalogSeed.completion(wiki: wiki), "剩下目录还待批，不完成")
        XCTAssertEqual(wiki.pagePaths(), pagesBefore, "正文没批不落页")
        let aqingContent = try XCTUnwrap(pages.first { $0.title == "阿青" })
        guard case .newPage(let page) = aqingContent.items[0].change else { return XCTFail() }
        XCTAssertEqual(Set(page.records), ["未注明 · 阿青的作息（memory/cc/user_a.md）", "未注明 · 阿青的爱好（memory/cc/user_b.md）", "未注明 · 自建槽设定（\(slotPath)）"])
        XCTAssertEqual(page.kind, .person)

        try await approve(aqingContent.id)
        XCTAssertTrue(wiki.pageExists("人/阿青"), "第二批批了才写进 wiki")
        let persisted = try XCTUnwrap(wiki.read("人/阿青"))
        let expectedEntries = try XCTUnwrap(item(outline, "阿青").change.direction?.sources).map { path in
            "\(path)|\(tasks.load(outline.id)!.carded![path]!)"
        }
        XCTAssertEqual(Set(page.entries ?? []), Set(expectedEntries))
        XCTAssertEqual(Set(persisted.entries ?? []), Set(expectedEntries), "实际审批后保留条目版本")
        let roundtrip = WikiPage.parse(try XCTUnwrap(wiki.readRaw("人/阿青")), path: "人/阿青")
        XCTAssertEqual(roundtrip.entries, persisted.entries)
        XCTAssertEqual(roundtrip.records, page.records)

        let refreshed = try XCTUnwrap(seedOutline())
        try await approve(refreshed.id, [item(refreshed, "云桥城").id])
        let third = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(third.failures, [])
        pages = contents(outline.id)
        let cloudContent = try XCTUnwrap(pages.first { $0.title == "云桥城" })
        XCTAssertEqual(cloudContent.items.map(\.change.kindLabel), ["追加记录"], "已有页只出更新；目录钩子是空的，不补改钩子")
        guard case .appendRecords(_, let lines) = cloudContent.items[0].change else { return XCTFail() }
        XCTAssertEqual(lines, ["未注明 · 阿青的作息（memory/cc/user_a.md）"], "append 模型记录丢弃，按获批原料生成")
        let done = try XCTUnwrap(CatalogSeed.completion(wiki: wiki), "目录处理完、获批页都交了正文 = 完成（正文还待批也算）")
        XCTAssertEqual(done.taskId, outline.id)
        XCTAssertEqual(tasks.load(outline.id)?.state, .complete)

        MemoryWriteLog.flush()
        let runs = try FileManager.default.contentsOfDirectory(atPath: wiki.root.appendingPathComponent(".runs").path)
        XCTAssertEqual(runs.count, 1, "批了接着写同一份整理记录：\(runs)")
        let runText = try String(contentsOf: wiki.root.appendingPathComponent(".runs/" + runs[0]), encoding: .utf8)
        for section in ["要点卡 · 切批", "要点卡 第 1 批（5 份） · 请求", "要点卡 第 1 批 · 校验", "聚合", "实体对齐 · 结果", "回扫候选", "聚类 · 结果", "## 目录"] {
            XCTAssertTrue(runText.contains(section), ".runs 每步一节：\(section)")
        }
        let logs = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).filter { $0.note.hasPrefix("种子 · ") }
        XCTAssertTrue(logs.contains { $0.note.hasPrefix("种子 · 交了目录 3 项") })
        for log in logs where log.note.hasPrefix("种子 · 第") {
            let link = try XCTUnwrap(log.run)
            XCTAssertEqual(link.path, ".runs/" + runs[0])
            XCTAssertTrue(runText.contains("<a id=\"\(try XCTUnwrap(link.anchor))\"></a>"), "每批 / 每轮日志点开到那一节")
        }
    }

    func testPromptNonPeopleStayInThresholdSummaryAndAlignmentWithoutOpeningPages() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        model.cards[slotPath] = card("人设名单", "林栖带着风铃去云桥广场", [
            ("林栖", "人"), ("风铃", "物"), ("纸舟", "工程"), ("云桥广场", "地点"), ("画展", "事"), ("灯塔", "项目")
        ])
        let report = await CatalogSession(job: fixture.job).seed()
        XCTAssertEqual(report.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(Set(outline.items.compactMap { $0.change.direction?.path }), ["人/林栖", "人/星砚"])
        let alignment = try XCTUnwrap(tasks.loadNotes(SeedNoteAlignment.self, name: CatalogSeedTaskStore.alignedFileName, id: outline.id))
        XCTAssertEqual(Set(alignment.groups.map(\.display)), ["林栖", "星砚", "风铃", "纸舟", "云桥广场", "画展", "灯塔"])
        let run = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(XCTUnwrap(outline.run), wiki: wiki)), encoding: .utf8)
        XCTAssertTrue(run.contains("够 3 份 / 已有页锚 1 个 · 人设层直开（人） 1 个 · 不够 3 份 5 个"))
    }

    func testThresholdRepartitionsActualClusterRequestAndEveryCardLandsWithoutAliases() async throws {
        let model = SeedModel()
        let low = "memory/cc/project_low.md", own = "memory/cc/user_own.md", lost = "memory/cc/user_lost.md"
        try cc("project_low.md", type: "project", title: "低量项目", body: "纸舟是离线阅读工具。")
        try cc("user_own.md", type: "user", title: "本人偏好", body: "我喜欢纸鸢。")
        try cc("user_lost.md", type: "user", title: "散落记录", body: "散页放在窗边。")
        model.cards[low] = card("低量项目", "纸舟是离线阅读工具", [("纸舟", "项目")])
        model.cards[own] = card("本人偏好", "本人喜欢纸鸢", [("纸鸢", "物")], aboutUser: true)
        model.cards[lost] = card("散落记录", "散页放在窗边", [("散页", "物")])
        let covered = (1...3).map { "memory/cc/entity_\($0).md" }
        for i in 1...3 {
            try cc("entity_\(i).md", type: "user", title: "星砚记录\(i)", body: "星砚写第\(i)份航海记录。")
            let mentions = [("星砚", "人")] + (i == 1 ? [("袖珍星图", "物")] : [])
            model.cards[covered[i - 1]] = card("星砚记录\(i)", "星砚写第\(i)份航海记录", mentions)
        }
        model.userPages = [("本人的爱好", "{{user}}/爱好", [own])]
        model.topics = [("离线阅读", "主题/离线阅读", [low]),
                        ("非法落页", "../散页", [lost])]
        model.pages = ["主题/待归类": newPage("主题/待归类", "主题", "还没归类的", "纸舟是离线阅读工具", [low])]
        var j = job(model)
        j.floorBase = CatalogFloorBase(sections: [])
        let report = await CatalogSession(job: j).seed()
        XCTAssertEqual(report.failures, [])

        let request = try XCTUnwrap(notesRequests(model).first { SeedModel.kind($0) == "cluster" })
        let pools = request.history[0].content.components(separatedBy: "【B 池")
        XCTAssertEqual(pools.count, 2)
        let a = try XCTUnwrap(pools.first), b = try XCTUnwrap(pools.last)
        XCTAssertTrue(a.contains("本人偏好"))
        XCTAssertTrue(b.contains("低量项目"), "about_user=false、所有实体不足 3 份，该卡进入 B 池")
        XCTAssertTrue(b.contains("散落记录"))
        XCTAssertFalse(b.contains("本人偏好"), "本人池优先，不能也进 B")
        for i in 1...3 { XCTAssertFalse(b.contains("星砚记录\(i)"), "仍被可开页实体正式覆盖的卡不进 B") }

        let outline = try XCTUnwrap(seedOutline())
        let directions = outline.items.compactMap(\.change.direction)
        XCTAssertEqual(Set(directions.map(\.path)), ["人/星砚", "{{user}}/待归类", "主题/待归类"])
        let topic = try XCTUnwrap(directions.first { $0.path == "主题/待归类" })
        XCTAssertEqual(Set(topic.sources ?? []), [low, lost])
        XCTAssertTrue(directions.allSatisfy { $0.aliases.isEmpty })
        let skipped = outline.seedSkipped?.filter { $0.hasPrefix("没归进目录") } ?? []
        XCTAssertTrue(skipped.isEmpty)

        try await approve(outline.id, [try XCTUnwrap(outline.items.first { $0.change.direction?.path == "主题/待归类" }).id])
        let written = await CatalogSession(job: j).resumeSeed(outline.id)
        XCTAssertEqual(written.failures, [])
        let proposal = try XCTUnwrap(contents(outline.id).first)
        guard case .newPage(let page) = proposal.items[0].change else { return XCTFail() }
        XCTAssertTrue(page.records.contains("未注明 · 低量项目（\(low)）"))
        XCTAssertFalse(page.triggers.contains("纸舟"), "不强塞低门槛名")
        try await approve(proposal.id)
        XCTAssertFalse(wiki.read("主题/待归类")?.triggers.contains("纸舟") ?? true)
    }

    func testFirstClusterRoundReassignsSwappedArraysSplitsMixedEntryAndFallsBackCopiedTitles() async throws {
        let model = SeedModel()
        let own = (1...6).map { "memory/cc/swap_own_\($0).md" }
        let loose = (1...6).map { "memory/cc/swap_loose_\($0).md" }
        for i in 1...6 {
            try cc("swap_own_\(i).md", type: "user", title: "本人写生\(i)", body: "本人第\(i)次观察云影。")
            try cc("swap_loose_\(i).md", type: "user", title: "风筝记录\(i)", body: "纸风筝第\(i)次飞过云桥。")
            model.cards[own[i - 1]] = card("本人写生\(i)", "本人观察第\(i)片云影", aboutUser: true)
            model.cards[loose[i - 1]] = card("风筝记录\(i)", "纸风筝第\(i)次起飞")
        }
        model.userPages = [("风筝记录1", "{{user}}/风筝", Array(loose.prefix(3)))]
        model.topics = [("本人写生1", "主题/写生", Array(own.prefix(3))),
                        ("云桥杂记", "主题/云桥杂记", Array(own.suffix(3)) + Array(loose.suffix(3)))]
        var j = job(model)
        j.floorBase = CatalogFloorBase(sections: [])
        let result = await CatalogSession(job: j).seed()
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(model.notesRequests.filter { $0.kind == "cluster" }.count, 1)
        let outline = try XCTUnwrap(seedOutline())
        let directions = outline.items.compactMap(\.change.direction)
        XCTAssertEqual(Set(directions.map(\.path)), ["{{user}}/写生", "主题/风筝", "{{user}}/云桥杂记", "主题/云桥杂记"])
        let expected = ["{{user}}/写生": Array(own.prefix(3)), "主题/风筝": Array(loose.prefix(3)),
                        "{{user}}/云桥杂记": Array(own.suffix(3)), "主题/云桥杂记": Array(loose.suffix(3))]
        for (path, sources) in expected {
            let direction = try XCTUnwrap(directions.first { $0.path == path })
            XCTAssertEqual(Set(direction.sources ?? []), Set(sources))
            XCTAssertEqual(direction.title, String(path.split(separator: "/").last!))
        }
        let clusters = try XCTUnwrap(tasks.loadNotes(SeedNoteClusters.self, name: CatalogSeedTaskStore.clusteredFileName, id: outline.id))
        XCTAssertEqual(clusters.normalizedPrefixCount, 0)
        XCTAssertEqual(clusters.reassignedPoolCount, 3)
        XCTAssertEqual(clusters.copiedTitleCount, 2)
        XCTAssertEqual(clusters.dropped, [])
        XCTAssertEqual(clusters.unplaced, [])
        let run = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(XCTUnwrap(outline.run), wiki: wiki)), encoding: .utf8)
        for line in ["改了前缀 3 条", "同数组改前缀 0 条", "跨数组归位 3 条", "title 抄了成员卡，改用页名 2 条"] {
            XCTAssertTrue(run.contains(line), line)
        }
        XCTAssertFalse(run.contains("丢掉的："))
    }

    func testSecondClusterRoundSendsOnlyMissingOriginalLabelsAndExistingPages() async throws {
        let model = SeedModel()
        let own = (1...4).map { "memory/cc/own_\($0).md" }
        let loose = (1...4).map { "memory/cc/loose_\($0).md" }
        for i in 1...4 {
            try cc("own_\(i).md", type: "user", title: "本人片段\(i)", body: "本人第\(i)次写生。")
            try cc("loose_\(i).md", type: "user", title: "风筝片段\(i)", body: "风筝第\(i)次起飞。")
            model.cards[own[i - 1]] = card("本人片段\(i)", "本人第\(i)次写生", aboutUser: true)
            model.cards[loose[i - 1]] = card("风筝片段\(i)", "风筝第\(i)次起飞")
        }
        model.userPages = [("写生", "{{user}}/写生", Array(own.prefix(3))), ("画具", "{{user}}/画具", [own[3]])]
        model.topics = [("风筝", "主题/风筝", Array(loose.prefix(3)))]
        var recoveryOpening: String?
        model.notesReply = { _, kind, opening in
            if kind == "cluster", opening.hasPrefix("【第二轮 · 只补漏卡】") {
                recoveryOpening = opening
                model.userPages = []
                model.topics = [("写生", "主题/写生", [own[3]]),
                                ("风筝片段4", "{{user}}/风筝", [loose[3]])]
            }
            return nil
        }
        var j = job(model)
        j.floorBase = CatalogFloorBase(sections: [])
        let result = await CatalogSession(job: j).seed()
        XCTAssertEqual(result.failures, [])
        let requests = notesRequests(model).filter { SeedModel.kind($0) == "cluster" }
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(requests.first?.history.first?.content)
        let second = try XCTUnwrap(recoveryOpening)
        let firstLines = first.components(separatedBy: "\n").filter { $0.hasPrefix("- c") }
        let secondLines = second.components(separatedBy: "\n").filter { $0.hasPrefix("- c") }
        XCTAssertEqual(secondLines.count, 2)
        for line in secondLines {
            XCTAssertTrue(firstLines.contains(line), "保持原编号和要点：\(line)")
            XCTAssertTrue(line.contains("片段4"))
        }
        for title in ["本人片段1", "本人片段2", "本人片段3", "风筝片段1", "风筝片段2", "风筝片段3"] {
            XCTAssertFalse(second.contains(title))
        }
        XCTAssertTrue(second.contains("/写生") && second.contains("主题/风筝") && second.contains("/画具"))
        let outline = try XCTUnwrap(seedOutline())
        let directions = outline.items.compactMap(\.change.direction)
        XCTAssertEqual(directions.count, 2)
        XCTAssertEqual(Set(directions.first { $0.path == "{{user}}/写生" }?.sources ?? []), Set(own))
        XCTAssertEqual(Set(directions.first { $0.path == "主题/风筝" }?.sources ?? []), Set(loose))
        let run = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(XCTUnwrap(outline.run), wiki: wiki)), encoding: .utf8)
        XCTAssertTrue(run.contains("第二轮补漏 · 问哪些") && run.contains("第二轮补漏 · 剩哪些"))
        let clusters = try XCTUnwrap(tasks.loadNotes(SeedNoteClusters.self, name: CatalogSeedTaskStore.clusteredFileName, id: outline.id))
        XCTAssertEqual(clusters.normalizedPrefixCount, 1)
        XCTAssertEqual(clusters.reassignedPoolCount, 1)
        XCTAssertEqual(clusters.copiedTitleCount, 1)
        XCTAssertEqual(clusters.dropped, [])
        for line in ["改了前缀 2 条", "同数组改前缀 1 条", "跨数组归位 1 条", "title 抄了成员卡，改用页名 1 条"] {
            XCTAssertTrue(run.contains(line), line)
        }
    }

    func testSecondClusterRoundStillMissingOrInvalidFallsBackToBothPools() async throws {
        for reply in [#"{"user_pages":[],"topics":[],"theatre":[],"pending":[]}"#, "不是 JSON"] {
            try? FileManager.default.removeItem(at: root)
            let model = SeedModel()
            try cc("own.md", type: "user", title: "本人记录", body: "本人喜欢写生。")
            try cc("loose.md", type: "user", title: "风筝记录", body: "风筝落在窗边。")
            model.cards["memory/cc/own.md"] = card("本人记录", "本人喜欢写生", aboutUser: true)
            model.cards["memory/cc/loose.md"] = card("风筝记录", "风筝落在窗边")
            model.notesReply = { _, kind, _ in kind == "cluster" ? .finished(reply) : nil }
            var j = job(model)
            j.floorBase = CatalogFloorBase(sections: [])
            let result = await CatalogSession(job: j).seed()
            XCTAssertEqual(result.failures, [])
            let outline = try XCTUnwrap(seedOutline())
            let directions = outline.items.compactMap(\.change.direction)
            XCTAssertEqual(Set(directions.map(\.path)), ["{{user}}/待归类", "主题/待归类"])
            XCTAssertTrue(directions.allSatisfy { $0.title == "还没归类的" })
            XCTAssertEqual(Set(directions.flatMap { $0.sources ?? [] }), ["memory/cc/own.md", "memory/cc/loose.md"])
            XCTAssertTrue(outline.seedSkipped?.filter { $0.hasPrefix("没归进目录") }.isEmpty ?? true)
        }
    }

    func testLowThresholdNameDoesNotInjectRetagOnExistingPage() async throws {
        let model = SeedModel()
        let source = "memory/cc/port.md"
        try cc("port.md", type: "user", title: "港口见闻", body: "云桥城码头有风帆标记。")
        try wiki.save(WikiPage(path: "地点/云桥城", kind: .place, triggers: ["旧码头"], title: "云桥城", factDomain: .realWorld))
        model.cards[source] = card("港口见闻", "码头有风帆标记", [("云桥城", "地点"), ("风帆标记", "物")])
        model.merge = [["into": "wiki:地点/云桥城", "names": ["云桥城"]]]
        model.pages = ["地点/云桥城": [["type": "append", "path": "地点/云桥城",
                                     "records": [["text": "日期未注明 码头有风帆标记", "sources": [source]]]]]]
        var j = job(model)
        j.floorBase = CatalogFloorBase(sections: [])
        let result = await CatalogSession(job: j).seed()
        XCTAssertEqual(result.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertTrue(item(outline, "云桥城").change.direction?.aliases.isEmpty ?? false)
        try await approve(outline.id)
        let resumed = await CatalogSession(job: j).resumeSeed(outline.id)
        XCTAssertEqual(resumed.failures, [])
        let proposal = try XCTUnwrap(contents(outline.id).first)
        XCTAssertEqual(proposal.items.map(\.change.kindLabel), ["追加记录"])
        try await approve(proposal.id)
        XCTAssertEqual(wiki.read("地点/云桥城")?.triggers, ["旧码头"])
    }


    /// 本人池：about_user 的卡由聚类起页（{{user}}/…），模型写名字、落盘回 {{user}}
    func testUserPoolBecomesUserPagesWrittenByName() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.cards["memory/cc/user_a.md"] = card("早起看船", "每天早上七点去码头看船", [("云桥城", "地点")], aboutUser: true, group: "{{user}}")
        model.userName = CatalogTestKit.names.user
        model.userPages = [("早起看船的习惯", "{{user}}/作息", ["memory/cc/user_a.md"])]

        let report = await CatalogSession(job: job(model)).seed(entry: .persona)

        XCTAssertEqual(report.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        let d = try XCTUnwrap(outline.items.compactMap(\.change.direction).first { $0.path == "{{user}}/待归类" }, "模型写名字，落盘是 {{user}}")
        XCTAssertEqual(d.kind, .user)
        XCTAssertEqual(d.title, "还没归类的")
        XCTAssertEqual(d.sources, ["memory/cc/user_a.md"])
        XCTAssertTrue(d.reason.hasPrefix("本人 · 1 份原料\n"))
        XCTAssertFalse(sent(model).contains("{{user}}"), "发给模型的一律是名字")
        XCTAssertTrue(notesRequests(model)[1].history[0].content.contains("\(CatalogTestKit.names.user)（本人）"), "对齐名单上的本人锚也显示名字")
    }

    /// 本人那组的 wiki 页：进快照（写页基线 / 原料页都取得到）、不出卡、对齐名单带它的锚；发给模型的没有 {{user}}
    func testUserBranchWikiPageIsSnapshotNotCardedAndShownByName() async throws {
        let model = SeedModel()
        try standardFixture(model)
        try wiki.save(WikiPage(path: "{{user}}/作息", kind: .user, triggers: ["早起"], title: "作息", now: "晚上十点以后不想被催。", factDomain: .realWorld))
        model.userName = CatalogTestKit.names.user
        let stored = CatalogSeedMaterials.wikiPath("{{user}}/作息")

        let report = await CatalogSession(job: job(model)).seed()

        XCTAssertEqual(report.failures, [])
        let task = try XCTUnwrap(tasks.all().first)
        XCTAssertTrue(task.materials.contains { $0.path == stored })
        XCTAssertNotNil(task.read[stored], "记在落盘路径上")
        XCTAssertNil(task.carded?[stored], "wiki 页不出卡")
        XCTAssertTrue(task.readText(stored, wiki: wiki)?.contains("晚上十点以后不想被催") ?? false)
        XCTAssertTrue(WikiProposalSources.receipts(task, wiki: wiki)[stored]?.contains("晚上十点以后不想被催") ?? false)
        XCTAssertFalse(notesRequests(model)[0].history[0].content.contains("晚上十点以后不想被催"), "wiki 页正文不进出卡的批")
        XCTAssertTrue(notesRequests(model)[1].history[0].content.contains("wiki:\(CatalogTestKit.names.user)/作息（标题 作息，触发词 早起）"), "锚按名字显示")
        XCTAssertFalse(sent(model).contains("{{user}}"), "发给模型的一律是名字")
        XCTAssertNotNil(seedOutline())
    }

    // MARK: - 要点卡：整批重写后仍没卡则拆单；失败原料续跑；同版本的卡复用；每份整份进批

    func testWholeBatchAndSingletonFailuresResumeOnlyUncardedMaterials() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.notesReply = { _, kind, _ in kind == "cards" ? .finished("我想想，先不出卡") : nil }

        let report = await CatalogSession(job: job(model)).seed()

        XCTAssertEqual(model.backend.requests.count, 7, "整批两次后每份各问一次，不再重写")
        let note = try XCTUnwrap(report.failures.first)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(note.hasPrefix("有 5 份原料没出要点卡，先停下了（点「继续这个种子任务」只重跑没出卡的原料）：\n"), note)
        XCTAssertTrue(note.contains("我想想，先不出卡"), note)
        XCTAssertEqual(note.components(separatedBy: "\n").filter { $0.hasPrefix("没出成要点卡：") }.count, 5)
        XCTAssertFalse(note.contains("请求没有回复"), note)
        XCTAssertNil(seedOutline())
        let stopped = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.note, note, "C3 页显示的原因")
        XCTAssertEqual(stopped.notes?.batches.map(\.ok), [false])
        XCTAssertEqual(stopped.notes?.failedPaths.count, 5)
        XCTAssertEqual(stopped.carded, [:])
        if case .reading(let carded, let total) = stopped.status(outline: nil) {
            XCTAssertEqual(carded, 0)
            XCTAssertEqual(total, 5)
            XCTAssertEqual(stopped.status(outline: nil).text, "还在出要点卡（0 / 5 份）、没交目录")
        } else { XCTFail("能续跑") }
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))

        model.notesReply = { _, _, _ in nil }
        let resumed = await CatalogSession(job: job(model)).resumeSeed(stopped.id)
        XCTAssertEqual(resumed.failures, [])
        XCTAssertEqual(model.backend.requests.count, 10, "续跑只重跑那一批 + 对齐 + 聚类")
        XCTAssertEqual(tasks.all().count, 1, "续的是同一个任务")
        let task = try XCTUnwrap(tasks.load(stopped.id))
        XCTAssertEqual(task.notes?.batches.map(\.ok), [true], "失败的批记录被重跑的替掉")
        XCTAssertEqual(task.carded?.count, 5)
        XCTAssertEqual(seedOutline()?.items.count, 3)
    }

    func testWholeBatchSplitRecoversSecondMaterialAndSkipsOnlyUnrecoverableSources() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        let recovered = fixture.paths[1]
        let raw = String(repeating: "模型原话", count: 40) + "不应进入原因的尾部"
        var cardCalls = 0
        model.notesReply = { _, kind, _ in
            guard kind == "cards" else { return nil }
            cardCalls += 1
            if cardCalls == 4 { return nil }
            return .finished(cardCalls <= 2 ? "整批不是 JSON" : raw)
        }
        var j = fixture.job
        j.seedDeps = CatalogAgent.Deps(makeBackend: { model.backend }, gate: { _ in nil }, roundCost: { _ in 0.01 })
        let report = await CatalogSession(job: j).seed()
        XCTAssertEqual(report.failures, [])
        let task = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(Set(try XCTUnwrap(task.carded).keys), [recovered])
        XCTAssertEqual(task.notes?.failedPaths, Set(fixture.paths.filter { $0 != recovered }))
        XCTAssertEqual(task.notes?.splitBatches, [.init(index: 1, recovered: 1)])
        let trace = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(task.run, wiki: wiki)), encoding: .utf8)
        XCTAssertTrue(trace.contains("第 1 批整批没出卡 · 拆成 5 份单问"))
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(outline.items.flatMap { $0.change.direction?.sources ?? [] }, [recovered])
        let skipped = try XCTUnwrap(outline.seedSkipped)
        XCTAssertEqual(skipped.count, 4)
        XCTAssertTrue(skipped.allSatisfy { $0.contains(String(raw.prefix(120))) && !$0.contains("不应进入原因的尾部") })
        let requests = notesRequests(model).filter { SeedModel.kind($0) == "cards" }
        XCTAssertEqual(requests.count, 7)
        XCTAssertEqual(task.rounds, model.backend.requests.count)
        for (index, request) in requests.dropFirst(2).enumerated() {
            let single = request.history[0].content
            XCTAssertTrue(single.hasPrefix("【这一批 1 份】"))
            XCTAssertTrue(single.contains("【m\(index + 1) ·"))
            XCTAssertFalse(single.contains(SeedNotePrompts.rewrite(reason: "")))
            XCTAssertEqual(trace.components(separatedBy: " · 拆单 m\(index + 1) · 请求").count - 1, 1)
        }
        MemoryWriteLog.flush()
        let cost = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).compactMap(\.costUSD).reduce(0, +)
        XCTAssertEqual(cost, Double(task.rounds) * 0.01, accuracy: 0.000001)
    }

    func testSameMaterialVersionReusesSavedCardsAcrossTasks() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let first = try XCTUnwrap(seedOutline())
        let before = model.backend.requests.count
        XCTAssertEqual(before, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: SeedNoteStore(wiki: wiki).folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.count, 5)
        let task = try XCTUnwrap(tasks.load(first.id))
        let saved = try XCTUnwrap(SeedNoteStore(wiki: wiki).load(path: "memory/cc/user_a.md", version: try XCTUnwrap(task.carded?["memory/cc/user_a.md"])))
        XCTAssertEqual(saved.title, "阿青的作息")
        XCTAssertEqual(saved.mentions.map(\.name), ["阿青", "云桥城"])
        XCTAssertEqual(saved.model, "假模型")

        _ = await CatalogSession(job: job(model)).abandonSeed(first.id)
        let abandoned = try XCTUnwrap(store.load(first.id))
        for item in abandoned.items {
            XCTAssertEqual(item.state, .rejected)
            XCTAssertEqual(item.reviewHistory?.last?.origin, .abandonedSeed)
            XCTAssertEqual(item.rejection?.reason, "")
        }
        let again = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(again.failures, [])
        XCTAssertEqual(model.backend.requests.count, before + 2, "同路径同版本的卡直接复用：第二个任务不再出卡，只对齐 + 聚类")
        XCTAssertEqual(model.notesRequests.suffix(2).map(\.kind), ["align", "cluster"])
        let second = try XCTUnwrap(store.list().first { CatalogSeedDrafts.isOutline($0) && $0.id != first.id })
        XCTAssertEqual(second.items.count, 3)
        XCTAssertEqual(tasks.load(second.id)?.carded?.count, 5)

        // 原料改了一个字：版本变了，这一份重出；别的照旧复用
        try cc("user_a.md", type: "user", title: "阿青的作息", body: "阿青每天早上七点半去码头看船。")
        _ = await CatalogSession(job: job(model)).abandonSeed(second.id)
        let mark = model.backend.requests.count
        _ = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(model.backend.requests.count, mark + 3)
        XCTAssertTrue(notesRequests(model)[notesRequests(model).count - 3].history[0].content.hasPrefix("【这一批 1 份】"), "只有改过的那一份重出卡")
    }

    func testEveryMaterialGoesWholeIntoItsOwnBatchWhenOversized() async throws {
        let model = SeedModel()
        let huge = String(repeating: "阿青在码头记了一行航海日志。", count: 4_000) + "最后一行：阿青把海图交给了灯塔守。"
        for i in 0..<12 { try cc("user_\(i).md", type: "user", title: "日志 \(i)", body: huge) }
        model.topics = [("航海日志", "主题/航海日志", (0..<12).map { "memory/cc/user_\($0).md" })]
        let report = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(report.failures, [])
        let batches = notesRequests(model).filter { SeedModel.kind($0) == "cards" }
        XCTAssertEqual(batches.count, 13, "12 份各超过一批的上限：各自一批，自建槽单独一批；不截尾、不摘要、不换模型")
        XCTAssertEqual(batches.filter { $0.history[0].content.components(separatedBy: huge).count == 2 }.count, 12, "每份 \(huge.count) 字原样全进它那一批")
        XCTAssertEqual(tasks.all().first?.notes?.batches.count, 13)
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(outline.items.first?.change.direction?.sources?.count, 12, "聚类把 12 份归到一页")
    }

    /// 单份原料本身超过模型上下文：只记这一批失败、别的批照出；续跑只重跑它
    func testOversizedMaterialOnlyFailsItsOwnBatchAndResumeRerunsIt() async throws {
        let model = SeedModel()
        for i in 0..<3 { try cc("user_\(i).md", type: "user", title: "日志 \(i)", body: "阿青第 \(i) 天去码头。") }
        try cc("user_huge.md", type: "user", title: "超长日志", body: String(repeating: "HUGE_MARKER 阿青记了一行。", count: 1_200))
        model.cards = ["memory/cc/user_huge.md": card("超长日志", "阿青记了很多行", [("阿青", "人")], group: "人")]
        model.topics = [("码头日志", "主题/码头日志", (0..<3).map { "memory/cc/user_\($0).md" }),
                        ("还没归类的", "主题/待归类", ["memory/cc/user_huge.md"])]
        let raw = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long: 250000 tokens > 200000 maximum\"}}"
        model.notesReply = { _, kind, opening in kind == "cards" && opening.contains("HUGE_MARKER") ? .failed(raw) : nil }

        let report = await CatalogSession(job: job(model)).seed()

        let note = try XCTUnwrap(report.failures.first)
        XCTAssertTrue(note.contains("批要点卡的原料（memory/cc/user_huge.md）超过 假模型 一次能读的长度（约 200000 token），这一批没出卡"), note)
        XCTAssertTrue(note.contains(raw), "附服务商原文")
        XCTAssertFalse(note.contains("上下文深度"), "不给聊天那套建议")
        XCTAssertEqual(model.backend.requests.count, 2, "两批：小的那批过了、超长那批失败就记下（请求本身失败不重写），不自动换模型")
        let task = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(task.carded?.count, 4, "别的批照出卡（3 份 CC + 自建槽）")
        XCTAssertEqual(task.notes?.batches.filter { !$0.ok }.map(\.paths), [["memory/cc/user_huge.md"]])
        XCTAssertNil(seedOutline())
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))

        model.notesReply = { _, _, _ in nil }
        let resumed = await CatalogSession(job: job(model)).resumeSeed(task.id)
        XCTAssertEqual(resumed.failures, [])
        XCTAssertEqual(tasks.all().count, 1, "续的是同一个任务")
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(Set(outline.items.compactMap { $0.change.direction?.path }), ["主题/待归类", "主题/码头日志"])
    }

    /// 175 份虚构原料各有一个单份实体，另有 88 份主实体 + 87 份主题：旧规则 177 项 / 350 引用，新规则 2 项 / 175 引用。
    func testRequestCountIsBatchesPlusTwoForManyMaterials() async throws {
        let model = SeedModel()
        for i in 0..<175 {
            try cc(String(format: "note_%03d.md", i), type: "user", title: "笔记 \(i)", body: String(repeating: "阿青第 \(i) 次出海，记下潮位和风向。", count: 40))
            let object = String(format: "云桥城物件%03d", i)
            let mentions = [(object, "物")] + (i % 2 == 0 ? [("阿青", "人")] : [])
            model.cards["memory/cc/" + String(format: "note_%03d.md", i)] = card(
                "笔记 \(i)", i % 2 == 0 ? "阿青出海记潮位" : "要点：笔记 \(i)", mentions, group: i % 2 == 0 ? "人" : "主题")
        }
        model.topics = [("出海杂记", "主题/出海杂记", (0..<175).filter { $0 % 2 == 1 }.map { "memory/cc/" + String(format: "note_%03d.md", $0) })]
        let report = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(report.failures, [])
        let task = try XCTUnwrap(tasks.all().first)
        let batches = try XCTUnwrap(task.notes?.batches.count)
        XCTAssertGreaterThanOrEqual(batches, 10)
        XCTAssertEqual(model.backend.requests.count, batches + 3, "批数 + 对齐 + 首轮聚类 + 漏卡补问")
        XCTAssertTrue(model.backend.requests.allSatisfy { $0.history.count == 1 && $0.toolTurns.isEmpty && $0.tools.isEmpty })
        XCTAssertEqual(task.carded?.count, 176)
        let outline = try XCTUnwrap(seedOutline())
        let directions = outline.items.compactMap { $0.change.direction }
        XCTAssertEqual(directions.count, 3, "实体页、主题页和漏卡待归类")
        let formal = directions.flatMap { $0.sources ?? [] }
        let expected = Set((0..<175).map { "memory/cc/" + String(format: "note_%03d.md", $0) }).union([slotPath])
        XCTAssertEqual(formal.count, 176)
        XCTAssertEqual(Set(formal), expected)
        XCTAssertEqual(formal.count, Set(formal).count, "每张卡都落且只落一次")
        XCTAssertTrue(formal.contains(slotPath))
        XCTAssertTrue(outline.seedSkipped?.filter { $0.hasPrefix("没归进目录") }.isEmpty ?? true)
        XCTAssertEqual(Set(directions.flatMap { $0.sources ?? [] }).count, 176)
        let aqing = try XCTUnwrap(outline.items.first { $0.change.direction?.path == "人/阿青" })
        let ad = try XCTUnwrap(aqing.change.direction)
        XCTAssertEqual(ad.sources?.count, 88)
        XCTAssertTrue(ad.aliases.isEmpty)
        let topic = try XCTUnwrap(directions.first { $0.path == "主题/出海杂记" })
        XCTAssertEqual(topic.sources?.count, 87)
        XCTAssertTrue(topic.aliases.isEmpty)
        XCTAssertEqual(ad.candidates?.count, 88, "常见名字字面命中吸进别的 87 份 + 自建槽：只记回扫候选，不升级成正式原料")
        XCTAssertTrue(ad.reason.hasPrefix("88 份原料 · 回扫候选 88 份\n"), String(ad.reason.prefix(40)))
        XCTAssertEqual(Set(directions.flatMap { ($0.sources ?? []) + ($0.candidates ?? []).map(\.path) }).count, 176, "读漏 0：正式原料 + 回扫候选盖住每一份")
        // 写阿青那一页：候选只给要点卡，不给全文，常见名字吸进来也撑不爆这一页
        let task2 = try XCTUnwrap(tasks.load(outline.id))
        guard case .success(let opened) = CatalogAgent.pageOpening(aqing, outline: outline, task: task2, wiki: wiki) else { return XCTFail() }
        XCTAssertTrue(opened.text.contains("【回扫候选】共 88 份"))
        XCTAssertFalse(opened.text.contains("阿青第 1 次出海"), "候选的全文不进写页请求")
        XCTAssertTrue(opened.text.contains(#""path":"memory/cc/note_001.md""#) && opened.text.contains("笔记 1：要点：笔记 1"), "候选只给卡标题 + 要点")
        XCTAssertFalse(opened.text.contains(longSlot), "自建槽也只是候选")
    }

    /// 软检查（gist 像流水账）只记日志不打回
    func testSoftChecksAreLoggedNotRejected() async throws {
        let model = SeedModel()
        try aqingFixture(model)
        model.cards["memory/cc/user_a.md"] = card("阿青的一天", "阿青先去码头，然后看船，之后买海图，接着回家，最后睡觉", [("阿青", "人")], aboutUser: true, group: "人")
        let report = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(report.failures, [])
        XCTAssertNotNil(seedOutline())
        MemoryWriteLog.flush()
        let run = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(XCTUnwrap(seedOutline()?.run), wiki: wiki)), encoding: .utf8)
        XCTAssertTrue(run.contains("软检查（只记不打回）") && run.contains("像流水账"))
    }

    /// 对齐、两轮聚类都没成：实体按原名、漏卡进各池待归类。
    func testAlignOrClusterFailureDoesNotBlockTheOutline() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.notesReply = { _, kind, _ in kind == "cards" ? nil : .finished("不想合") }
        let report = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(model.notesRequests.map(\.kind), ["cards", "align", "align", "cluster", "cluster", "cluster", "cluster"])
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(Set(outline.items.compactMap { $0.change.direction?.path }), ["人/阿青", "主题/待归类"])
        MemoryWriteLog.flush()
        let notes = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).map(\.note)
        XCTAssertTrue(notes.contains("种子 · 实体对齐没成，目录按原名"), "\(notes)")
        XCTAssertTrue(notes.contains("种子 · 聚类请求没成，已由各组待归类兜底"))
        let task = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertTrue(task.notes?.aligned == true && task.notes?.clustered == true, "结果（哪怕是没成）存下了，续跑不再问")
    }

    /// 停在对齐之后：续跑沿用存下的对齐结果，不再问对齐，只问聚类
    func testResumeSkipsFinishedNotesPhases() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.notesReply = { _, kind, _ in kind == "cluster" ? .failed("网关超时 504") : nil }
        let stopped = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(stopped.failures, [], "聚类请求失败只是聚不成页，不算出错")
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertTrue(outline.seedSkipped?.filter { $0.hasPrefix("没归进目录") }.isEmpty ?? true)
        let task = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tasks.notesFolder(task.id).appendingPathComponent(CatalogSeedTaskStore.alignedFileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tasks.notesFolder(task.id).appendingPathComponent(CatalogSeedTaskStore.clusteredFileName).path))
        let aligned = try XCTUnwrap(tasks.loadNotes(SeedNoteAlignment.self, name: CatalogSeedTaskStore.alignedFileName, id: task.id))
        XCTAssertEqual(aligned.groups.first { $0.key == "云桥城" }?.existingPage, "地点/云桥城")

        // 把目录和聚类结果拿掉、保留对齐：续跑只问聚类
        try FileManager.default.removeItem(at: tasks.notesFolder(task.id).appendingPathComponent(CatalogSeedTaskStore.clusteredFileName))
        try FileManager.default.removeItem(at: tasks.folder(task.id).appendingPathComponent(task.id + ".json"))
        var reset = task
        reset.outlineSaved = false
        reset.state = .stopped
        reset.notes?.clustered = false
        try tasks.save(reset)
        model.notesReply = { _, _, _ in nil }
        let before = model.backend.requests.count
        let resumed = await CatalogSession(job: job(model)).resumeSeed(task.id)
        XCTAssertEqual(resumed.failures, [])
        XCTAssertEqual(model.notesRequests.suffix(model.backend.requests.count - before).map(\.kind), ["cluster"], "卡和对齐都沿用存下的")
        XCTAssertNotNil(seedOutline())
    }

    func testResumeReclustersSavedPoolsThatOmitNewlyLooseLowThresholdCards() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let first = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(first.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        var task = try XCTUnwrap(tasks.load(outline.id))
        var cached = try XCTUnwrap(tasks.loadNotes(SeedNoteClusters.self, name: CatalogSeedTaskStore.clusteredFileName, id: task.id))
        let low = "memory/cc/project_c.md"
        // 模拟旧池缓存：留反馈卡为 unplaced，同时漏掉项目卡。
        cached.topics.removeAll { $0.paths.contains(low) }
        let feedback = try XCTUnwrap(SeedNoteStore(wiki: wiki).load(path: "memory/cc/feedback_x.md", version: task.read["memory/cc/feedback_x.md"] ?? ""))
        cached.unplaced = [feedback]
        XCTAssertTrue(cached.userPages.allSatisfy { !$0.paths.contains(low) })
        try tasks.saveNotes(cached, name: CatalogSeedTaskStore.clusteredFileName, id: task.id)
        try FileManager.default.removeItem(at: tasks.folder(task.id).appendingPathComponent(task.id + ".json"))
        task.outlineSaved = false
        task.state = .stopped
        XCTAssertEqual(task.notes?.clustered, true, "旧 checkpoint 声称聚类已完成")
        try tasks.save(task)

        let before = model.backend.requests.count
        let resumed = await CatalogSession(job: job(model)).resumeSeed(task.id)
        XCTAssertEqual(resumed.failures, [])
        let requests = Array(model.backend.requests.dropFirst(before))
        XCTAssertEqual(requests.compactMap(SeedModel.kind), ["cluster"], "覆盖集合不匹配时不能复用旧聚类；卡与对齐仍复用")
        let opening = try XCTUnwrap(requests.first?.history.first?.content)
        let b = try XCTUnwrap(opening.components(separatedBy: "【B 池").dropFirst().first)
        XCTAssertTrue(b.contains("两个项目"), "恢复时真正把新入池的卡发给聚类")
        let restored = try XCTUnwrap(seedOutline())
        let topic = try XCTUnwrap(item(restored, "还没归类的").change.direction)
        XCTAssertEqual(topic.path, "主题/待归类")
        XCTAssertEqual(Set(topic.sources ?? []), [low, "memory/cc/feedback_x.md"])
        XCTAssertTrue(topic.aliases.isEmpty)
        XCTAssertFalse(restored.seedSkipped?.contains { $0.hasPrefix("没归进目录") && $0.contains("两个项目") } ?? false)
    }

    /// 快照写不成就不发请求；快照不在了续不了
    func testSnapshotFailuresSendNoRequest() async throws {
        let model = SeedModel()
        try aqingFixture(model)
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        try Data("不是文件夹".utf8).write(to: wiki.root.appendingPathComponent(WikiStore.proposalsFolder))
        let blocked = await CatalogSession(job: job(model)).seed()
        XCTAssertTrue(blocked.failures.first?.hasPrefix("原料快照没存成，没开始问模型") ?? false, "\(blocked.failures)")
        XCTAssertEqual(model.backend.requests.count, 0, "快照存不上就不发付费请求")
        try FileManager.default.removeItem(at: wiki.root.appendingPathComponent(WikiStore.proposalsFolder))

        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id)
        try FileManager.default.removeItem(at: tasks.materialsFolder(outline.id))
        let before = model.backend.requests.count
        let gone = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertTrue(gone.failures.first?.contains("原料快照不在了") ?? false, "\(gone.failures)")
        XCTAssertEqual(model.backend.requests.count, before)
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
    }

    // MARK: - 返修（astra 10-24）：快照对账、上游重做失效下游、纯缓存续跑能停、闸、费用、同名原料、链接

    /// 快照写成了、任务没存上（清单 / 版本都空）：续跑从快照恢复清单和版本、先存任务再问模型，出处对得上
    func testResumeRecoversChecklistFromSnapshotWhenTaskWasNotSaved() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.fail = { n in n == 1 ? "网关超时 504" : nil }
        _ = await CatalogSession(job: job(model)).seed()
        var task = try XCTUnwrap(tasks.all().first)
        let expected = task.materials
        let expectedRead = task.read
        XCTAssertFalse(expected.isEmpty)
        task.materials = []
        task.read = [:]
        task.carded = nil
        task.notes = nil
        task.state = .stopped
        try tasks.save(task)
        model.fail = { _ in nil }
        var seenAtFirstRequest: CatalogSeedTask?
        let id = task.id
        let store = tasks
        model.notesReply = { _, kind, _ in
            if kind == "cards", seenAtFirstRequest == nil { seenAtFirstRequest = store.load(id) }
            return nil
        }

        let resumed = await CatalogSession(job: job(model)).resumeSeed(id)

        XCTAssertEqual(resumed.failures, [])
        XCTAssertEqual(seenAtFirstRequest?.materials, expected, "先把恢复的清单存进任务，再问模型")
        XCTAssertEqual(seenAtFirstRequest?.read, expectedRead)
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(outline.items.count, 3, "出处校验对得上：不是空目录")
        XCTAssertEqual(tasks.load(id)?.materials, expected)
    }

    /// 已开工的任务：快照 manifest 少一条 / 版本对不上 → 明确停，不问模型、不静默少读
    func testResumeStopsWhenSnapshotManifestDisagreesWithTask() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.fail = { n in n == 1 ? "网关超时 504" : nil }
        _ = await CatalogSession(job: job(model)).seed()
        let task = try XCTUnwrap(tasks.all().first)
        model.fail = { _ in nil }
        let manifest = tasks.materialsFolder(task.id).appendingPathComponent(CatalogSeedMaterials.manifestFileName)
        let original = try Data(contentsOf: manifest)
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [[String: Any]])
        let dropped = try XCTUnwrap(entries.removeLast()["path"] as? String)
        try JSONSerialization.data(withJSONObject: entries).write(to: manifest)
        XCTAssertNotNil(task.snapshot(wiki: wiki), "少一条的 manifest 自己验得过（每份正文都在）")
        let before = model.backend.requests.count

        let short = await CatalogSession(job: job(model)).resumeSeed(task.id)

        let note = try XCTUnwrap(short.failures.first)
        XCTAssertTrue(note.contains("原料快照和任务记的原料清单对不上") && note.contains("\(dropped) 在任务清单里、快照里没有") && note.contains("请放弃这个种子任务再重新播种"), note)
        XCTAssertEqual(model.backend.requests.count, before, "对不上不问模型")

        try original.write(to: manifest)
        var changed = try XCTUnwrap(tasks.load(task.id))
        changed.read["memory/cc/user_a.md"] = "别的版本"
        try tasks.save(changed)
        let version = await CatalogSession(job: job(model)).resumeSeed(task.id)
        XCTAssertTrue(version.failures.first?.contains("memory/cc/user_a.md 记的读到版本和快照里的不一样") ?? false, "\(version.failures)")
        XCTAssertEqual(model.backend.requests.count, before)
    }

    /// 目录没存成的任务：卡丢了要重出 → 对齐、聚类作废重做（失效先落盘）；只丢了对齐结果 → 重新对齐，聚类跟着重做
    func testRedoingUpstreamPhasesInvalidatesDownstreamResults() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let task = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertTrue(task.notes?.aligned == true && task.notes?.clustered == true)
        XCTAssertEqual(tasks.loadNotes(SeedNoteAlignment.self, name: CatalogSeedTaskStore.alignedFileName, id: task.id)?.groups.first { $0.key == "云桥城" }?.existingPage, "地点/云桥城")

        func unsave(_ edit: (inout CatalogSeedTask) -> Void) throws {
            try? FileManager.default.removeItem(at: tasks.folder(task.id).appendingPathComponent(task.id + ".json"))
            var reset = try XCTUnwrap(tasks.load(task.id))
            reset.outlineSaved = false
            reset.state = .stopped
            edit(&reset)
            try tasks.save(reset)
        }
        let lost = "memory/cc/project_c.md"
        try unsave { $0.carded?[lost] = nil }
        try FileManager.default.removeItem(at: SeedNoteStore(wiki: wiki).url(path: lost, version: try XCTUnwrap(task.read[lost])))
        model.merge = []
        var seen: [String: SeedNoteProgress] = [:]
        let store = tasks
        model.notesReply = { _, kind, _ in
            if seen[kind] == nil { seen[kind] = store.load(task.id)?.notes }
            return nil
        }
        var before = model.backend.requests.count
        let redone = await CatalogSession(job: job(model)).resumeSeed(task.id)
        XCTAssertEqual(redone.failures, [])
        XCTAssertEqual(model.notesRequests.suffix(model.backend.requests.count - before).map(\.kind), ["cards", "align", "cluster"], "卡重出 → 对齐、聚类跟着重做")
        XCTAssertEqual(seen["cards"]?.aligned, false, "失效先落盘再请求")
        XCTAssertEqual(seen["cards"]?.clustered, false)
        XCTAssertNil(tasks.loadNotes(SeedNoteAlignment.self, name: CatalogSeedTaskStore.alignedFileName, id: task.id)?.groups.first { $0.key == "云桥城" }?.existingPage,
                     "用的是新的对齐结果（这次没合并）")
        XCTAssertNotNil(seedOutline())

        try unsave { _ in }
        try FileManager.default.removeItem(at: tasks.notesFolder(task.id).appendingPathComponent(CatalogSeedTaskStore.alignedFileName))
        seen = [:]
        before = model.backend.requests.count
        let realigned = await CatalogSession(job: job(model)).resumeSeed(task.id)
        XCTAssertEqual(realigned.failures, [])
        XCTAssertEqual(model.notesRequests.suffix(model.backend.requests.count - before).map(\.kind), ["align", "cluster"], "只重新对齐：卡沿用、聚类跟着重做")
        XCTAssertEqual(seen["align"]?.clustered, false, "聚类作废先落盘")
    }

    /// 卡 / 对齐 / 聚类全沿用的续跑：中途点停 → .cancelled、不交目录、已完成的结果留着；再继续不问模型直接交目录
    func testPureCacheResumeCanBeStopped() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try FileManager.default.removeItem(at: tasks.folder(outline.id).appendingPathComponent(outline.id + ".json"))
        var reset = try XCTUnwrap(tasks.load(outline.id))
        reset.outlineSaved = false
        reset.state = .stopped
        try tasks.save(reset)
        let before = model.backend.requests.count

        let session = CatalogSession(job: job(model))
        session.onProgress = { _, round in if round > 0 { session.cancel() } }
        let stopped = await session.resumeSeed(outline.id)

        XCTAssertTrue(stopped.cancelled)
        XCTAssertEqual(model.backend.requests.count, before, "全沿用：没有新请求")
        XCTAssertNil(seedOutline(), "点了停不交目录")
        let kept = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertEqual(kept.state, .stopped, "停了，不是结束")
        XCTAssertTrue(kept.notes?.aligned == true && kept.notes?.clustered == true, "已完成的可恢复结果留着")
        XCTAssertEqual(kept.carded?.count, 5)

        let again = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(again.failures, [])
        XCTAssertEqual(model.backend.requests.count, before)
        XCTAssertEqual(seedOutline()?.items.count, 3)
    }

    /// 出卡 / 对齐 / 聚类各被闸拒：停在「被拦」，已出的结果留着；放开闸续跑只补没做的
    func testGateRefusalAtEachNotesPhaseStopsAndResumesWhereItLeft() async throws {
        for (phase, marker, sent) in [("cards", "【这一批", 0), ("align", "【名字清单】", 1), ("cluster", "【A 池 · 本人】", 2)] {
            try? FileManager.default.removeItem(at: root)
            let model = SeedModel()
            try standardFixture(model)
            let flag = TimeoutFlag()
            flag.on = true
            let deps = CatalogAgent.Deps(makeBackend: { model.backend }, gate: { payload in flag.on && payload.contains(marker) ? "预算到顶" : nil })
            let report = await CatalogSession(job: job(model, deps: deps)).seed()
            XCTAssertEqual(report.blocked, "预算到顶", phase)
            XCTAssertEqual(model.backend.requests.count, sent, "\(phase)：被拦的那次没发出去")
            let task = try XCTUnwrap(tasks.all().first)
            XCTAssertEqual(task.state, .stopped, phase)
            XCTAssertEqual(task.note, "被拦：预算到顶", phase)
            XCTAssertNil(seedOutline(), phase)
            XCTAssertEqual(task.carded?.count, phase == "cards" ? 0 : 5, phase)
            XCTAssertEqual(task.notes?.aligned, phase == "cluster", phase)
            if phase == "cards" {
                let reason = try XCTUnwrap(task.notes?.batches.first?.reason)
                XCTAssertTrue(reason.contains("被拦：预算到顶"), reason)
                XCTAssertFalse(reason.contains("请求没有回复"), reason)
            }

            flag.on = false
            let resumed = await CatalogSession(job: job(model, deps: deps)).resumeSeed(task.id)
            XCTAssertEqual(resumed.failures, [], phase)
            XCTAssertEqual(model.backend.requests.count, 3, "\(phase)：续跑只补没做的（卡 + 对齐 + 聚类各一次）")
            XCTAssertEqual(seedOutline()?.items.count, 3, phase)
        }
    }

    /// 每次真实请求只记一次费用：重写那次也记、请求失败带的费用不在阶段汇总里重记
    func testEachRequestCostIsLoggedExactlyOnce() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.notesReply = { n, kind, _ in
            switch kind {
            case "cards", "align": return n == 1 || n == 3 ? .finished("先不出") : nil
            default: return .failed("网关超时 504")
            }
        }
        let deps = CatalogAgent.Deps(makeBackend: { model.backend }, gate: { _ in nil }, roundCost: { _ in 0.01 })
        let report = await CatalogSession(job: job(model, deps: deps)).seed()
        XCTAssertEqual(report.failures, [])
        MemoryWriteLog.flush()
        let logs = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).filter { $0.note.hasPrefix("种子 · ") }
        let total = logs.compactMap(\.costUSD).reduce(0, +)
        XCTAssertEqual(total, Double(model.backend.requests.count) * 0.01, accuracy: 1e-9,
                       "重写与补漏请求也各记一次，不按旧阶段次数固定费用：\(logs.map { "\($0.note)=\($0.costUSD ?? -1)" })")
    }

    /// 同名原料 / 同标题卡：假模型按稳定身份认，聚合、聚类都不串
    func testSameNamedMaterialsAndSameTitledCardsStayApart() async throws {
        let model = SeedModel()
        try cc("sketch_a.md", type: "user", title: "写生记录", body: "星砚在旧码头写生。")
        try cc("sketch_b.md", type: "user", title: "写生记录", body: "云桥城的风很大。")
        try cc("wind_c.md", type: "user", title: "风一", body: "纸鸢飞起来了。")
        try cc("wind_d.md", type: "user", title: "风二", body: "傍晚风停了。")
        model.cards = [
            "memory/cc/sketch_a.md": card("写生记录", "星砚在旧码头写生", [("星砚", "人")], group: "人"),
            "memory/cc/sketch_b.md": card("写生记录", "云桥城风大", [("云桥城", "地点")], group: "地点"),
            "memory/cc/wind_c.md": card("风的记录", "纸鸢飞起来"),
            "memory/cc/wind_d.md": card("风的记录", "傍晚风停"),
        ]
        model.topics = [("风的记录", "主题/风", ["memory/cc/wind_c.md", "memory/cc/wind_d.md"]),
                        ("星砚", "主题/星砚", ["memory/cc/sketch_a.md"]),
                        ("云桥城", "主题/云桥城", ["memory/cc/sketch_b.md"])]
        model.notesReply = { _, kind, opening in
            if kind == "cluster", opening.hasPrefix("【第二轮 · 只补漏卡】") {
                model.topics = [("风的记录", "主题/风", ["memory/cc/wind_c.md", "memory/cc/wind_d.md", "memory/cc/sketch_a.md", "memory/cc/sketch_b.md"])]
            }
            return nil
        }
        let report = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(report.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        let byPath = Dictionary(outline.items.compactMap { $0.change.direction }.map { ($0.path, $0.sources ?? []) }, uniquingKeysWith: { a, _ in a })
        XCTAssertNil(byPath["主题/星砚"])
        XCTAssertNil(byPath["主题/云桥城"])
        XCTAssertEqual(Set(byPath["主题/风"] ?? []), ["memory/cc/wind_c.md", "memory/cc/wind_d.md", "memory/cc/sketch_a.md", "memory/cc/sketch_b.md"], "同标题卡按要点分清后，两个薄页合进风页")
    }

    /// 回扫候选不是原料：写页只给它那张卡（不给全文），写手拿它当出处的那一行进不了提案
    func testBackfillCandidateIsShownAsCardAndCannotBeCited() async throws {
        let model = SeedModel()
        try projectEntityFixture(model)
        model.pages["项目/灯塔"] = [["type": "new_page", "path": "项目/灯塔", "kind": "项目", "title": "灯塔", "now": "灯塔是天气小组件",
                                    "records": [["text": "日期未注明 灯塔是天气小组件", "sources": ["memory/cc/project_c.md"]],
                                                ["text": "日期未注明 有人收集灯塔航线海图", "sources": ["memory/cc/user_b.md"]]]]]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let lamp = item(outline, "灯塔")
        try await approve(outline.id, [lamp.id])
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        let opening = model.backend.requests[before].history[0].content
        XCTAssertTrue(opening.contains("【回扫候选】共 1 份") && opening.contains("阿青的爱好：阿青收集《灯塔航线》的纸质海图"), "候选给卡标题 + 要点")
        XCTAssertFalse(opening.contains("阿青收集《灯塔航线》的纸质海图。"), "候选的原文全文不进写页请求")
        let page = try XCTUnwrap(contents(outline.id).first)
        guard case .newPage(let written) = page.items[0].change else { return XCTFail() }
        XCTAssertEqual(Set(written.records.compactMap { line in (item(outline, "灯塔").change.direction?.sources ?? []).first { line.hasSuffix("（\($0)）") } }), Set(item(outline, "灯塔").change.direction?.sources ?? []), "正式原料全覆盖，候选不可引用")
    }

    /// astra 二审 P2：存目录那一步——读已存目录时点停 → 不交；写目录时点停 → 目录留在盘上，但这次返回 .cancelled
    func testCancelAroundOutlineSaveReturnsCancelled() async throws {
        for saved in [false, true] {
            try? FileManager.default.removeItem(at: root)
            let model = SeedModel()
            try standardFixture(model)
            _ = await CatalogSession(job: job(model)).seed()
            let first = try XCTUnwrap(seedOutline())
            try FileManager.default.removeItem(at: tasks.folder(first.id).appendingPathComponent(first.id + ".json"))
            var reset = try XCTUnwrap(tasks.load(first.id))
            reset.outlineSaved = false
            reset.state = .stopped
            try tasks.save(reset)
            let before = model.backend.requests.count

            let agent = CatalogAgent(deps: CatalogAgent.Deps(makeBackend: { model.backend }, gate: { _ in nil }), cancel: CatalogCancel())
            var seedJob = CatalogAgent.SeedJob(task: reset, snapshot: try tasks.loadSnapshot(first.id), wiki: wiki, names: CatalogTestKit.names,
                                               run: CatalogRunRecord(wiki: wiki, continuing: reset.run, topic: "种子", now: Date()))
            seedJob.onOutlineSave = { stage in if stage == saved { agent.cancel() } }
            let outcome = await agent.runSeed(seedJob)

            XCTAssertEqual(outcome.stop, .cancelled, "saved=\(saved)")
            XCTAssertEqual(model.backend.requests.count, before, "全沿用，不问模型")
            XCTAssertEqual(seedOutline() != nil, saved, saved ? "写完才点停：目录留在盘上" : "读的时候点停：不交目录")
            let task = try XCTUnwrap(tasks.load(first.id))
            XCTAssertEqual(task.outlineSaved, saved)
            XCTAssertEqual(task.state, .stopped)
        }
    }

    /// .cards 是指向别处的链接：这批记失败（卡没存成），链接那头一个字都不写
    func testLinkedCardsFolderFailsTheBatchAndWritesNothingOutside() async throws {
        let model = SeedModel()
        try aqingFixture(model)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: wiki.root.appendingPathComponent(SeedNoteStore.folderName), withDestinationURL: outside)
        let report = await CatalogSession(job: job(model)).seed()
        XCTAssertTrue(report.failures.first?.contains("卡没存成") ?? false, "\(report.failures)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertNil(seedOutline())
    }

    /// 快照验得过才算有：正文被改过 → pageOpening 停在这一页；详情页的原料也只认快照那一版
    func testPageOpeningAndReceiptsReadTheSnapshotVersion() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let task = try XCTUnwrap(tasks.load(outline.id))
        try cc("user_a.md", type: "user", title: "阿青的作息", body: "阿青改成八点去码头看船。")
        let receipts = WikiProposalSources.receipts(task, wiki: wiki)
        XCTAssertTrue(receipts["memory/cc/user_a.md"]?.contains("七点去码头看船") ?? false, "改了盘上的文件，详情页仍是提案读到的那一版")
        XCTAssertEqual(receipts.count, task.read.filter { !$0.value.isEmpty }.count, "快照里每份都取得到")
        guard case .success(let opened) = CatalogAgent.pageOpening(item(outline, "阿青"), outline: outline, task: task, wiki: wiki) else { return XCTFail() }
        XCTAssertTrue(opened.text.contains("七点去码头看船") && !opened.text.contains("八点"))

        let file = tasks.materialsFolder(task.id).appendingPathComponent("001.txt")
        let original = try Data(contentsOf: file)
        try Data("被动过".utf8).write(to: file)
        guard case .failure(let problem) = CatalogAgent.pageOpening(item(outline, "阿青"), outline: outline, task: task, wiki: wiki) else { return XCTFail() }
        XCTAssertTrue(problem.note.contains("原料快照里却找不到它的正文"), problem.note)
        XCTAssertTrue(WikiProposalSources.receipts(task, wiki: wiki).isEmpty, "快照验不过整份不认")
        try original.write(to: file)
        var gone = task
        gone.read["memory/cc/user_b.md"] = ""
        guard case .success(let page) = CatalogAgent.pageOpening(item(outline, "阿青"), outline: outline, task: gone, wiki: wiki) else { return XCTFail() }
        XCTAssertTrue(page.text.contains("（这份读的时候已经不在了，不能当出处）"), "版本空 = 读的时候真没了")
    }

    // MARK: - 旧流程（layout 2，一段对话全读）的种子作废

    /// 旧 checkpoint：问过模型的旧流程任务作废；新任务、三问答完还没开跑的旧任务不算
    func testOldLayoutCheckpointIsLegacyOnlyWhenItAskedTheModel() throws {
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .cc, modelName: "m", createdAt: Date(),
                                   run: CatalogRunLink(path: "x"))
        XCTAssertEqual(task.layout, 3)
        XCTAssertFalse(task.isLegacyLayout)
        task.layout = 2
        XCTAssertFalse(task.isLegacyLayout, "旧流程但还没问过模型（三问答完没开跑）：按新流程开跑")
        task.history = [.init(role: "user", content: "【这次的原料清单】")]
        XCTAssertTrue(task.isLegacyLayout)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        json["layout"] = nil
        let old = try JSONDecoder().decode(CatalogSeedTask.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.layout)
        XCTAssertTrue(old.isLegacyLayout, "更旧的「楼层/」格式也作废")
        XCTAssertTrue(CatalogSeedTask.legacyLayoutNote.contains("要点卡"))
    }

    /// 续跑旧流程的种子：不问模型、不写页，任务记成放弃，给一句清楚的话
    func testResumingLegacyLayoutSeedRetiresItWithClearNote() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        var task = try XCTUnwrap(tasks.load(outline.id))
        task.layout = 2
        task.history = [.init(role: "user", content: "【这次的原料清单】")]
        try tasks.save(task)
        try await approve(outline.id, [item(outline, "还没归类的").id])
        let requests = model.backend.requests.count
        let pages = wiki.pagePaths()

        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.notes, [CatalogSeedTask.legacyLayoutNote])
        XCTAssertEqual(model.backend.requests.count, requests, "不再问模型")
        XCTAssertEqual(wiki.pagePaths(), pages, "不写页")
        XCTAssertTrue(contents(outline.id).isEmpty, "没交正文")
        let retired = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertEqual(retired.state, .abandoned)
        XCTAssertEqual(retired.note, CatalogSeedTask.legacyLayoutNote)
        XCTAssertEqual(store.load(outline.id)?.pendingCount, 0, "剩下待批的目录项驳回")
    }

    /// 开新种子时挡着的是旧流程任务：先作废它，再照常开新的
    func testNewSeedRetiresOpenLegacyTaskAndStarts() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let old = try XCTUnwrap(seedOutline())
        var task = try XCTUnwrap(tasks.load(old.id))
        task.layout = 2
        task.history = [.init(role: "user", content: "【这次的原料清单】")]
        try tasks.save(task)

        let report = await CatalogSession(job: job(model)).seed()
        XCTAssertNil(report.skipped)
        XCTAssertTrue(report.notes.contains(CatalogSeedTask.legacyLayoutNote))
        XCTAssertEqual(tasks.load(old.id)?.state, .abandoned)
        XCTAssertEqual(tasks.all().count, 2, "开了新任务")
        XCTAssertEqual(tasks.all().first?.layout, CatalogSeedTask.currentLayout)
    }

    func testSeedProposalsLiveInTheTaskFolderAndOldTopLevelOnesStillLoad() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id, [item(outline, "还没归类的").id])
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let folder = wiki.root.appendingPathComponent(".proposals/\(outline.id)")
        let content = try XCTUnwrap(contents(outline.id).first)
        for id in [outline.id, content.id] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(id + ".json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: wiki.root.appendingPathComponent(".proposals/\(id).json").path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("materials/manifest.json").path), "原料快照在任务文件夹里")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes/aligned.json").path), "对齐 / 聚类结果也在")
        let old = WikiProposal(origin: .manual, createdAt: Date(), items: [.init(change: .newPage(page: WikiPage(path: "主题/面包", title: "面包")))])
        try store.save(old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wiki.root.appendingPathComponent(".proposals/\(old.id).json").path))
        XCTAssertEqual(store.load(old.id)?.items, old.items)
        XCTAssertEqual(Set(store.list().map(\.id)), [outline.id, content.id, old.id], "快照 / notes 文件不被当成提案")
        try await approve(content.id)
        XCTAssertTrue(wiki.pageExists("主题/待归类"), "任务文件夹里的正文照常批")
    }

    // MARK: - 失败 / 停 / 重启续跑

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
        XCTAssertEqual(contents(outline.id).count, 3)
        XCTAssertNotNil(CatalogSeed.completion(wiki: wiki))
        let again = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(again.skipped, "这个种子任务不在了，或已经结束")
        XCTAssertEqual(contents(outline.id).count, 3, "重复点不重复交")
    }

    func testStopRightAfterTheLastPageDoesNotComplete() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id, [item(outline, "还没归类的").id])
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
        try aqingFixture(model)
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
        try aqingFixture(model)
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
        let logs = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).map(\.note)
        XCTAssertTrue(logs.contains { $0.contains("跳过 4 份私人文件（private_）") })
        let run = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(XCTUnwrap(outline.run), wiki: wiki)), encoding: .utf8)
        let proposals = String(decoding: try JSONEncoder().encode(store.list()), as: UTF8.self)
        let checkpoint = String(decoding: try JSONEncoder().encode(tasks.load(outline.id)), as: UTF8.self)
        let manifest = try String(contentsOf: tasks.materialsFolder(outline.id).appendingPathComponent("manifest.json"), encoding: .utf8)
        for artifact in [sent(model), logs.joined(), run, proposals, checkpoint, manifest] {
            for leak in ["private_x.md", "PRIVATE_diary_key.md", "Private_z.md", "private_y.md", "PRIVATE_BODY_MARKER", "PRIVATE_ONLY_MARKER"] {
                XCTAssertFalse(artifact.contains(leak), leak)
            }
        }
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
        XCTAssertFalse(model.backend.requests[before].history[0].content.contains(tailFact), "写页失败也不悄悄把全文塞回开场")
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
        try await CatalogSeedDrafts.save(entry, text: trimmed, baseline: entry.content, wiki: wiki, profileId: pid, context: ModelContext(container))
        XCTAssertFalse(item(try XCTUnwrap(seedOutline()), "阿青").change.direction?.sources?.contains("memory/cc/user_b.md") ?? true, "批之前能给这一项少列原料")
    }

    func testContextLimitAndProviderTextForSeedNotes() {
        XCTAssertEqual(CatalogSeedPrompts.contextLimit("prompt is too long: 201605 tokens > 200000 maximum"), 200000)
        XCTAssertEqual(CatalogSeedPrompts.contextLimit("This model's maximum context length is 128000 tokens"), 128000)
        XCTAssertNil(CatalogSeedPrompts.contextLimit("input is too long for requested model"))
        XCTAssertEqual(CatalogSeedPrompts.providerText("对话太长了。把预设里的「上下文深度」调小。原文：prompt is too long"), "prompt is too long")
        let note = CatalogSeedPrompts.pageContextNote(title: "阿青", round: 3, model: "M", raw: "input is too long for requested model")
        XCTAssertEqual(note, "「阿青」这一页列的原料太长，超过 M 一次能读的长度，这一页还没写（第 3 轮）。可以放弃这个种子任务，重新播种时在目录批之前给这一项少列几份原料，或先在 C3 设置里换上下文更大的模型再重新播种。服务商原话：input is too long for requested model")
        let batch = CatalogSeedPrompts.batchContextNote(batch: 2, paths: ["memory/cc/a.md"], model: "M", raw: "x")
        XCTAssertTrue(batch.hasPrefix("第 2 批要点卡的原料（memory/cc/a.md）超过 M 一次能读的长度，这一批没出卡") && batch.contains("把这几份原料拆小"), batch)
    }

    // MARK: - astra 审 60f9ea823

    /// P1：要更新的已有页只认快照；链接到 private_ 的页没进快照，不读盘补，明确停下
    func testUpdateTargetLinkedToPrivateFileIsNeverSent() async throws {
        let model = SeedModel()
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        try cc("private_x.md", type: "user", title: "私密", body: "PRIVATE_LINKED_MARKER")
        try "---\n事实域: realWorld\n---\nPRIVATE_LINKED_MARKER".write(to: root.appendingPathComponent("cc/private_x.md"), atomically: true, encoding: .utf8)
        let dir = wiki.root.appendingPathComponent("人")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("秘密.md"), withDestinationURL: root.appendingPathComponent("cc/private_x.md"))
        model.cards = ["memory/cc/user_a.md": card("阿青", "阿青喜欢海图", [("秘密", "人")], group: "人")]
        try supportingCards(model, mentions: [("秘密", "人")])
        model.pages = ["人/秘密": [["type": "append", "path": "人/秘密", "records": [["text": "日期未注明 阿青喜欢海图", "sources": ["memory/cc/user_a.md"]]]]]]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(outline.items.first?.change.direction?.action, .update)
        try await approve(outline.id)
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let note = try XCTUnwrap(report.failures.first)
        XCTAssertTrue(note.contains("「秘密」要更新的已有页 人/秘密 不在这次的原料快照里"), note)
        XCTAssertEqual(model.backend.requests.count, before, "停在开对话之前，一个请求都没发")
        let task = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertFalse(task.materials.contains { $0.path == CatalogSeedMaterials.wikiPath("人/秘密") })
        XCTAssertFalse(sent(model).contains("PRIVATE_LINKED_MARKER"))
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
    }

    func testNilDomainLinkedTargetIsRejectedBeforeUpdate() throws {
        try cc("private_x.md", type: "user", title: "私密", body: "PRIVATE_LINKED_MARKER")
        let dir = wiki.root.appendingPathComponent("人")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("秘密.md"), withDestinationURL: root.appendingPathComponent("cc/private_x.md"))
        let direction = WikiProposal.Direction(path: "人/秘密", title: "秘密", kind: .person, action: .newPage,
            reason: "虚构夹具", mode: .seed, sources: ["memory/cc/user_a.md"], factDomain: .realWorld)
        switch CatalogSeedTools.checkDirection(direction, task: nil, wiki: wiki) {
        case .failure(let error): XCTAssertTrue(error.localizedDescription.contains("已有页没记事实域"))
        case .success: XCTFail("nil 域旧页不能作为更新目标")
        }
    }

    private func pageSession(_ item: String, opening: String, pending: CatalogSeedTask.Turn? = nil, key: String? = nil) -> CatalogSeedTask.PageSession {
        .init(item: item, history: [.init(role: "user", content: opening)], turns: [], pending: pending, key: key)
    }

    /// P2：先对账处理还有效的 pending（不重新问模型）；别的目录项变了不重开这一页的对话
    func testPendingIsSettledFirstAndOtherItemsDoNotRestartThePage() async throws {
        let model = SeedModel()
        try projectEntityFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let aqing = item(outline, "阿青").id, paper = item(outline, "纸舟").id, lamp = item(outline, "灯塔").id
        try await approve(outline.id, [aqing, paper])
        var task = try XCTUnwrap(tasks.load(outline.id))
        let call = SeedModel.call("submit_proposal", ["phase": "page", "item": aqing, "items": model.pages["人/阿青"]!])
        task.page = pageSession(aqing, opening: "旧开场", pending: .init(calls: [.init(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON, truncated: false)], results: []))
        try tasks.save(task)
        try await approve(outline.id, [lamp])
        let before = model.backend.requests.count
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertNotNil(contents(outline.id).first { $0.directionRef?.itemId == aqing }, "收到、没处理完的那轮照现在的目录项处理掉")
        let asked = model.backend.requests[before...].compactMap(SeedModel.pageItem)
        XCTAssertFalse(asked.contains(aqing), "阿青那页不重新问模型")
        XCTAssertEqual(Set(asked), [paper, lamp])

        // 一页的对话停在半路（没有 pending、key 是现在这一版），批了别的项：接着原来那段对话，不重开
        let refreshed = try XCTUnwrap(seedOutline())
        let cloud = item(refreshed, "云桥城").id
        var again = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertNil(again.page, "写完的页不留对话")
        again.state = .stopped
        try tasks.save(again)
        try await approve(outline.id, [cloud])
        var mid = try XCTUnwrap(tasks.load(outline.id))
        let cloudDirection = try XCTUnwrap(item(try XCTUnwrap(seedOutline()), "云桥城").change.direction)
        mid.page = pageSession(cloud, opening: "这一页原来的开场 · 【这一页】item=\(cloud) ·", key: CatalogAgent.pageKey(cloudDirection, task: mid))
        try tasks.save(mid)
        let before2 = model.backend.requests.count
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(model.backend.requests[before2].history.first?.content, "这一页原来的开场 · 【这一页】item=\(cloud) ·", "本项没变：接着用")
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
        var orphan = try XCTUnwrap(tasks.load(outline.id))
        let paper = item(outline, "还没归类的").id
        orphan.revisionDrafts = [paper: "{}"]
        orphan.state = .stopped
        try tasks.save(orphan)
        try await approve(outline.id, [paper])
        let before2 = model.backend.requests.count
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertFalse(model.backend.requests[before2].history[0].content.contains("之前交过一稿"))
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
        try await reject(outline.id, Set(outline.items.filter { $0.id != aqing }.map(\.id)))
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
            try aqingFixture(model)
            _ = await CatalogSession(job: job(model)).seed()
            let outline = try XCTUnwrap(seedOutline())
            let target = item(outline, "阿青").id
            try await approve(outline.id)
            var task = try XCTUnwrap(tasks.load(outline.id))
            let args = String(decoding: try JSONSerialization.data(withJSONObject: [
                "phase": "page", "item": target, "items": newPage("{{user}}/阿青", "{{user}}", "阿青", "阿青喜欢海图", ["memory/cc/user_a.md"]),
            ]), as: UTF8.self)
            task.page = pageSession(target, opening: "崩溃前的开场", pending: .init(calls: [.init(id: "call-crash", name: "submit_proposal", argumentsJSON: args, truncated: false)], results: []))
            try tasks.save(task)
            let commit = CatalogSeedTask.commitId(task: outline.id, call: "call-crash", item: target)
            if alreadySaved {
                var saved = WikiProposal(id: commit, origin: .seed, createdAt: Date(), title: "阿青",
                                         items: [.init(change: .newPage(page: WikiPage(path: "{{user}}/阿青", kind: .user, title: "阿青",
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
            XCTAssertNil(tasks.load(outline.id)?.page)
            XCTAssertNotNil(CatalogSeed.completion(wiki: wiki))
        }
    }

    func testResumeReconcilesSavedOutlineAndUnlinkedContent() async throws {
        let model = SeedModel()
        try aqingFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        var task = try XCTUnwrap(tasks.load(outline.id))
        task.outlineSaved = false
        try tasks.save(task)
        try await approve(outline.id)
        var content = WikiProposal(origin: .seed, createdAt: Date(), title: "阿青",
                                   items: [.init(change: .newPage(page: WikiPage(path: "{{user}}/阿青", title: "阿青", records: ["日期未注明 x（出处：CC memory/cc/user_a.md）"])),
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

    // MARK: - provider 内容块：写页那段存进 checkpoint，续轮原样回灌

    func testProviderContentBlocksSurviveCheckpointAndReplay() async throws {
        let model = SeedModel()
        try aqingFixture(model)
        func extras() -> AssistantTurnExtras {
            let blocks: [[String: Any]] = [["type": "thinking", "thinking": "先看原料", "signature": "sig-abc"],
                                           ["type": "redacted_thinking", "data": "ZW5j"],
                                           ["type": "text", "text": "我先写这一页"]]
                + model.lastCalls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": SeedModel.args($0)] }
            var reasoning = ReasoningCapture()
            reasoning.field = "reasoning_details"
            reasoning.text = "推一下"
            reasoning.details = [["type": "reasoning.text", "text": "推一下", "index": 0]]
            return AssistantTurnExtras(assistantContent: blocks, thinkingTokens: 42, reasoning: reasoning)
        }
        model.backend.tokens = { _ in ["我先写这一页"] }
        let deps = CatalogAgent.Deps(makeBackend: { model.backend }, gate: { _ in nil }, roundTurn: { _ in extras() })
        _ = await CatalogSession(job: job(model, deps: deps)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id)
        let before = model.backend.requests.count
        // 这一页先交一稿没有可用条目的，下一轮请求出错停下：这一页自己的对话存进 checkpoint
        let good = model.pages
        model.pages = [:]
        model.fail = { n in n == before + 2 ? "假模型：断了" : nil }
        _ = await CatalogSession(job: job(model, deps: deps)).resumeSeed(outline.id)
        let first = model.backend.requests[before]
        XCTAssertTrue(first.toolTurns.isEmpty, "写正文单开一段对话")
        XCTAssertEqual(first.history.count, 1)
        let saved = try XCTUnwrap(tasks.load(outline.id)?.page?.turns.first?.toolTurn)
        let encoded = try JSONDecoder().decode(CatalogSeedTask.Turn.self, from: JSONEncoder().encode(CatalogSeedTask.Turn(saved))).toolTurn
        for turn in [saved, encoded] {
            let content = try XCTUnwrap(turn.assistantContent)
            XCTAssertEqual(content.first?["signature"] as? String, "sig-abc")
            XCTAssertEqual(content[1]["data"] as? String, "ZW5j")
            XCTAssertEqual(turn.thinkingTokens, 42)
            XCTAssertEqual(turn.reasoning?.field, "reasoning_details")
            XCTAssertTrue(NSArray(array: turn.reasoning?.details ?? []).isEqual(to: [["type": "reasoning.text", "text": "推一下", "index": 0]]))
            XCTAssertEqual(turn.text, "我先写这一页")
            XCTAssertTrue(NSArray(array: AnthropicProvider.toolTurnAssistantContent(turn)).isEqual(to: content), "Anthropic 续轮原样回灌")
        }
        model.pages = good
        model.fail = { _ in nil }
        _ = await CatalogSession(job: job(model, deps: deps)).resumeSeed(outline.id)
        let replayed = try XCTUnwrap(model.backend.requests[before + 2].toolTurns.first)
        XCTAssertTrue(NSArray(array: replayed.assistantContent ?? []).isEqual(to: saved.assistantContent ?? []), "重启续跑这一页的请求里原样带回")
        XCTAssertEqual(replayed.reasoning?.text, "推一下")
        XCTAssertEqual(replayed.text, "我先写这一页")
        XCTAssertNotNil(CatalogSeed.completion(wiki: wiki))
        var plain = saved
        plain.assistantContent = nil
        XCTAssertEqual(AnthropicProvider.toolTurnAssistantContent(plain).first?["text"] as? String, "我先写这一页", "没有内容块时正文也回灌")
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

        let pending = WikiProposal(origin: .seed, createdAt: Date(), items: [.init(change: .newPage(page: WikiPage(path: "人/阿青", title: "阿青")))])
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
        try await approve(outline.id, [item(outline, "还没归类的").id])
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

    // MARK: - 正文：实质内容、快照里的版本、获批原料、同任务连线

    func testEmptyNowDoesNotCountAsWrittenEvenWithGeneratedRecords() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.limit = 12
        model.pages["主题/待归类"] = [["type": "new_page", "path": "主题/待归类", "kind": "主题", "title": "还没归类的", "now": "",
                                      "records": [["text": "没出处", "sources": ["memory/cc/不存在.md"]]]]]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id, [item(outline, "还没归类的").id])
        try await reject(outline.id)
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertFalse(report.failures.isEmpty, "假模型交不出合格正文，最后服务商报错才停")
        XCTAssertTrue(contents(outline.id).isEmpty, "代码记录不能把空「现在」变成可交审新页")
        XCTAssertEqual(CatalogSeedTask.unwritten(store.load(outline.id)).count, 1)
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
    }

    /// 「现在」仍需连贯段落：列表硬检查只重写一次，之后交审并保留首稿。
    func testSeedPageFailingHardCheckGetsOneRewriteThenGoesToReviewFlagged() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let long = "- 2026-10-01 纸舟上线"
        model.pages["主题/待归类"] = newPage("主题/待归类", "主题", "还没归类的", long, ["memory/cc/project_c.md"])
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let paper = item(outline, "还没归类的").id
        try await approve(outline.id, [paper])
        try await reject(outline.id)
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        let content = try XCTUnwrap(contents(outline.id).first)
        guard case .newPage(let page) = content.items[0].change else { return XCTFail() }
        XCTAssertEqual(page.now, long, "保留第一稿的列表边界，不靠模型记录触发检查")
        XCTAssertFalse(content.items[0].checks?.isEmpty ?? true)
        let results = model.backend.requests.last?.toolTurns.flatMap(\.results) ?? []
        XCTAssertEqual(results.filter { $0.isError && $0.text.contains("没过检查") }.count, 1, "同一目录项只给一次重写")
        XCTAssertEqual(tasks.load(outline.id)?.revisionDrafts.map { Array($0.keys) }, [paper])
        XCTAssertEqual(content.revision, "重写一次后仍有没过的")
    }

    /// 种子修订之后，只要不是被取消，结果用不了（出错、坏参数、交上来的没有能用的条目）都交已存的第一稿当提案，带标记和原因，不要第三稿
    func testSeedRevisionThatCannotBeUsedDeliversTheFirstDraft() async throws {
        let long = "- 2026-10-01 纸舟上线"
        let cases: [(name: String, setup: (SeedModel, Int) -> Void, why: String)] = [
            ("出错", { model, before in model.fail = { n in n == before + 2 ? "网关超时 504" : nil } }, "那轮出错（网关超时 504）"),
            ("坏参数", { model, before in model.badPageArgs = { n in n == before + 2 } }, "那次参数不是合格的 JSON"),
            ("交空", { model, before in model.pageOverride = { n in n >= before + 2 ? ["主题/待归类": []] : nil } }, "那次交的没有能用的内容"),
        ]
        for c in cases {
            try? FileManager.default.removeItem(at: base)
            let model = SeedModel()
            try standardFixture(model)
            model.pages["主题/待归类"] = newPage("主题/待归类", "主题", "还没归类的", long, ["memory/cc/project_c.md"])
            _ = await CatalogSession(job: job(model)).seed()
            let outline = try XCTUnwrap(seedOutline(), c.name)
            let paper = item(outline, "还没归类的").id
            try await approve(outline.id, [paper])
            try await reject(outline.id)
            let before = model.backend.requests.count
            c.setup(model, before)
            _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
            let content = try XCTUnwrap(contents(outline.id).first, c.name)
            XCTAssertTrue(content.revision?.contains(c.why) == true && content.revision?.hasSuffix("交的是第一稿") == true, "\(c.name)：\(content.revision ?? "nil")")
            guard case .newPage(let page) = content.items[0].change else { return XCTFail(c.name) }
            XCTAssertEqual(page.now, long, c.name)
            XCTAssertTrue(content.items[0].checks?.isEmpty == false, c.name)
            XCTAssertLessThanOrEqual(model.backend.requests.count - before, 3, "\(c.name)：交页、修订，之后最多再问一次就停在等批，不要第三稿")
            let asked = (model.backend.requests.last?.toolTurns.flatMap(\.results) ?? []).filter { $0.isError && $0.text.contains("改了重交") }
            XCTAssertTrue(asked.isEmpty, "\(c.name)：不再要求重交")
        }
    }

    func testAllItemsOfAPageUseTheVersionInTheSnapshot() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let readVersion = try XCTUnwrap(tasks.load(outline.id)?.read["memory/wiki/地点/云桥城.md"])
        let cloudItem = item(outline, "云桥城")
        guard case .direction(var d) = cloudItem.change else { return XCTFail() }
        d.hook = "提到云桥城的时候先看这页"
        _ = try store.edit(outline.id, itemId: cloudItem.id, change: .direction(d), judgment: nil)
        try await approve(outline.id, [cloudItem.id])
        try await reject(outline.id)
        try wiki.saveRaw("---\n钩子: 她改过的钩子\n---\n# 云桥城\n\n## 现在\n她手改的一版\n", path: "地点/云桥城")
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let cloud = try XCTUnwrap(contents(outline.id).first)
        XCTAssertEqual(cloud.items.map(\.baseVersion), [readVersion, readVersion], "补出的改钩子也用快照那一版，不拿现在的")
        guard case .retag(_, let oldHook, let newHook, _, _) = cloud.items[1].change else { return XCTFail() }
        XCTAssertEqual(oldHook, "提到云桥城", "旧钩子按快照那一版")
        XCTAssertEqual(newHook, "提到云桥城的时候先看这页")
        let mine = wiki.readRaw("地点/云桥城")
        try await approve(cloud.id)
        XCTAssertEqual(store.load(cloud.id)?.items.map(\.state), [.stale, .stale])
        XCTAssertEqual(wiki.readRaw("地点/云桥城"), mine, "她的新改动不被钩子盖掉")
    }

    func testSourcesAreLimitedToTheApprovedItemAndEditsShareTheSeedCheck() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.pages["主题/待归类"] = [["type": "new_page", "path": "主题/待归类", "kind": "主题", "title": "还没归类的", "now": "纸舟",
                                      "records": [["text": "日期未注明 纸舟是离线阅读工具", "sources": ["memory/cc/project_c.md"]],
                                                  ["text": "日期未注明 阿青看船", "sources": ["memory/cc/user_a.md"]]]]]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let paper = item(outline, "还没归类的")
        let entry = try XCTUnwrap(CatalogSeedDrafts.entries(wiki: wiki).first { $0.kind == .outline(outline.id) })
        let unread = entry.content.replacingOccurrences(of: "- memory/cc/project_c.md\n", with: "- memory/cc/不存在.md\n")
        XCTAssertNotEqual(unread, entry.content)
        await XCTAssertThrowsErrorAsync { try await CatalogSeedDrafts.save(entry, text: unread, baseline: entry.content, wiki: self.wiki, profileId: self.pid, context: ModelContext(self.container)) }
        guard case .direction(var d) = paper.change else { return XCTFail() }
        d.sources = ["memory/cc/private_y.md"]
        await XCTAssertThrowsErrorAsync {
            try await CatalogSeedDrafts.saveChange(outline.id, itemId: paper.id, change: .direction(d), baseline: paper.change, wiki: self.wiki)
        }
        try await approve(outline.id, [paper.id])
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let content = try XCTUnwrap(contents(outline.id).first)
        guard case .newPage(let page) = content.items[0].change else { return XCTFail() }
        XCTAssertEqual(Set(page.records), ["未注明 · 两个项目（memory/cc/project_c.md）", "未注明 · 回复风格（memory/cc/feedback_x.md）"], "模型记录全部丢弃，获批原料逐份生成")
        var stripped = page
        stripped.records = ["未注明 · 两个项目，纸舟是离线阅读工具"]
        await XCTAssertThrowsErrorAsync {
            try await CatalogSeedDrafts.saveChange(content.id, itemId: content.items[0].id, change: .newPage(page: stripped),
                                                   baseline: content.items[0].change, wiki: self.wiki)
        }
        var moved = page
        moved.path = "项目/别处"
        let saved = try await CatalogSeedDrafts.saveChange(content.id, itemId: content.items[0].id, change: .newPage(page: moved),
                                                           baseline: content.items[0].change, wiki: wiki)
        XCTAssertEqual(saved.items[0].change.targetPath, "主题/待归类", "审计台改不了正文的页路径")
    }

    func testFileLibrarySaveComparesBaselineInsideTheLock() async throws {
        let model = SeedModel()
        try projectEntityFixture(model)
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
        let edited = entry.content.replacingOccurrences(of: "标题: 灯塔\n钩子: \n", with: "标题: 灯塔\n钩子: 文件库改的钩子\n")
        XCTAssertNotEqual(edited, entry.content)
        let wk = wiki
        let saver = Task { @MainActor in try await CatalogSeedDrafts.save(entry, text: edited, baseline: entry.content, wiki: wk, profileId: self.pid, context: ModelContext(self.container)) }
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
        model.cards = ["memory/cc/user_a.md": card("阿青去码头", "阿青每天去码头", [("阿青", "人"), ("码头", "地点")], group: "人")]
        try supportingCards(model, mentions: [("阿青", "人"), ("码头", "地点")])
        var aqing = newPage("人/阿青", "人", "阿青", "阿青每天去码头", ["memory/cc/user_a.md"])
        aqing[0]["links"] = [["to": "地点/码头", "relation": "补充", "why": "常去"]]
        model.pages = ["人/阿青": aqing, "地点/码头": newPage("地点/码头", "地点", "码头", "阿青常去的码头", ["memory/cc/user_a.md"])]
        var j = job(model)
        j.floorBase = CatalogFloorBase(sections: [])
        _ = await CatalogSession(job: j).seed()
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(Set(outline.items.compactMap { $0.change.direction?.path }), ["人/阿青", "地点/码头"])
        try await approve(outline.id)
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let all = contents(outline.id)
        let a = try XCTUnwrap(all.first { $0.title == "阿青" })
        let b = try XCTUnwrap(all.first { $0.title == "码头" })
        guard case .newPage(let draft) = a.items[0].change else { XCTFail(); return nil }
        XCTAssertEqual(draft.links.map(\.target), ["地点/码头"], "同任务获批的目录页可以连，不当成不存在")
        if rejectTargetFirst { try await reject(b.id) }
        try await approve(a.id)
        return wiki.read("人/阿青")
    }

    func testLinkToAnApprovedOutlinePageIsKeptWhileItsContentIsPending() async throws {
        let page = try await linkedPages(rejectTargetFirst: false)
        XCTAssertEqual(page?.links.map(\.target), ["地点/码头"], "目标正文还在等批，连线留着")
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
        model.cards["memory/cc/user_a.md"] = card("阿青", "阿青喜欢海图", [("阿青", "人")], group: "人")
        try cc("private_x.md", type: "user", title: "私密", body: "PRIVATE_LINK_MARKER")
        let w = wiki
        try w.save(WikiPage(path: "人/阿青", kind: .person, title: "阿青", now: "她写的", factDomain: .realWorld))
        try w.save(WikiPage(path: "地点/云桥城", kind: .place, title: "云桥城", now: "旧码头"))
        model.merge = [["into": "wiki:人/阿青", "names": ["阿青"]]]
        try w.setGroupHook("地点", hook: "说到地方先看这组")
        let other = base.appendingPathComponent("other-floor", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try "# 别层\nOTHER_FLOOR_MARKER".write(to: other.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)
        try "# 外面\nOUTSIDE_MARKER".write(to: other.appendingPathComponent("folder/外面.md"), atomically: true, encoding: .utf8)
        let fm = FileManager.default
        try fm.createSymbolicLink(at: w.root.appendingPathComponent("人/秘密.md"), withDestinationURL: root.appendingPathComponent("cc/private_x.md"))
        try fm.createSymbolicLink(at: w.root.appendingPathComponent("人/别层.md"), withDestinationURL: other.appendingPathComponent("page.md"))
        try fm.createSymbolicLink(at: w.root.appendingPathComponent("人/链接夹"), withDestinationURL: other.appendingPathComponent("folder"))
        _ = await CatalogSession(job: job(model)).seed()
        let task = try XCTUnwrap(tasks.all().first)
        let paths = task.materials.map(\.path)
        XCTAssertTrue(paths.contains("memory/wiki/人/阿青.md"))
        XCTAssertTrue(paths.contains("memory/wiki/地点/INDEX.md"))
        for bad in ["秘密", "别层", "链接夹", "外面"] { XCTAssertFalse(paths.contains { $0.contains(bad) }, bad) }
        let everything = sent(model)
        for marker in ["PRIVATE_LINK_MARKER", "OTHER_FLOOR_MARKER", "OUTSIDE_MARKER", "秘密", "别层", "链接夹"] {
            XCTAssertFalse(everything.contains(marker), marker)
        }
        let snapshot = try XCTUnwrap(task.snapshot(wiki: w))
        XCTAssertTrue(snapshot.text("memory/wiki/INDEX.md")?.contains("说到地方先看这组") ?? false, "分组的钩子在根索引里（进快照、不进请求）")
        XCTAssertEqual(seedOutline()?.items.first { $0.change.direction?.path == "人/阿青" }?.change.direction?.action, .update, "已有页锚 → 更新")

        let linkedRoot = base.appendingPathComponent("linked-memory", isDirectory: true)
        try fm.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedRoot.appendingPathComponent("wiki"), withDestinationURL: w.root)
        let refused = try CatalogSeedMaterials.gather(floorBase: nil, memoryRoot: linkedRoot, wiki: WikiStore(root: linkedRoot.appendingPathComponent("wiki")))
        XCTAssertTrue(refused.items.isEmpty, "wiki 根本身是链接就一份都不读")
        XCTAssertTrue(refused.skipped.contains { $0.contains("wiki 文件夹是链接") })
    }

    // MARK: - 目录由代码把关（坏卡打回、路径 / 原料校验）；写页只认这一项的页、没批的不写

    func testBadCardFieldsGetRewrittenAndPageTargetsAreGuarded() async throws {
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        for i in 1...2 { try cc("user_support_\(i).md", type: "user", title: "海图补充\(i)", body: "阿青喜欢海图，常去码头。") }
        var unapproved = ""
        var seen: [String] = []
        let backend = FakeCatalogBackend { n, request in
            if request.tools.isEmpty {
                seen.append(SeedModel.kind(request) ?? "unknown")
                switch SeedModel.kind(request) {
                case "cards":
                    // 第一次：组写错、mentions 的组也错、标题太长；重写才合格
                    let bad = request.history[0].content.contains("上一次的回复不合格") == false
                    let title = bad ? String(repeating: "长", count: 21) : "阿青和码头"
                    return .finished(SeedModel.json(["cards": [
                        ["m": "m1", "title": "自建槽", "gist": "自建槽设定", "mentions": [], "about_user": false, "group": "主题", "fact_domain": "realWorld"],
                        ["m": "m2", "title": title, "gist": "阿青喜欢海图", "mentions": [["name": "阿青", "group": bad ? "朋友" : "人"], ["name": "码头", "group": "地点"]],
                         "about_user": false, "group": bad ? "动物" : "人", "fact_domain": "realWorld"],
                        ["m": "m3", "title": "海图补充1", "gist": "阿青常去码头", "mentions": [["name": "阿青", "group": "人"], ["name": "码头", "group": "地点"]], "about_user": false, "group": "人", "fact_domain": "realWorld"],
                        ["m": "m4", "title": "海图补充2", "gist": "阿青在码头看海图", "mentions": [["name": "阿青", "group": "人"], ["name": "码头", "group": "地点"]], "about_user": false, "group": "人", "fact_domain": "realWorld"],
                    ]]))
                case "align": return .finished(#"{"merge":[{"into":"阿青","names":["不存在的人"]}]}"#)
                default: return .finished(#"{"user_pages":[],"topics":[{"title":"自建槽","path":"../越界","members":["c1"]}],"theatre":[],"pending":[]}"#)
                }
            }
            let approved = SeedModel.pageItem(request) ?? ""
            return .toolCalls([
                SeedModel.call("submit_proposal", ["phase": "page", "item": unapproved, "items": []]),
                SeedModel.call("submit_proposal", ["phase": "page", "item": approved, "items": [
                    ["type": "new_page", "path": "地点/别处", "kind": "地点", "title": "别处", "records": [["text": "x", "sources": ["memory/cc/user_a.md"]]]],
                    ["type": "new_page", "path": "人/阿青", "kind": "物", "title": "随便", "now": "阿青喜欢海图", "records": [["text": "日期未注明 阿青喜欢海图", "sources": ["memory/cc/user_a.md"]]]],
                ]]),
            ])
        }
        var j = CatalogTestKit.job(pid: pid, root: root, container: container, backend: backend)
        j.floorBase = CatalogFloorBase(sections: [.init(path: slotBasePath, name: "自建槽", text: "槽里的字", isEnabled: false)])
        _ = await CatalogSession(job: j).seed()
        XCTAssertEqual(seen, ["cards", "cards", "align", "cluster", "cluster"], "坏卡重写一次，漏卡再问一轮")
        let rewrite = backend.requests[1].history[0].content
        for reason in ["m2 的 title 超过 20 字（现在 21 字）", "m2 的 group「动物」不在九组内", "的 group「朋友」不在"] {
            XCTAssertTrue(rewrite.contains(reason), "重写带原因：\(reason)")
        }
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(outline.items.compactMap { $0.change.direction?.path }, ["人/阿青", "地点/码头", "主题/待归类"])
        XCTAssertTrue(outline.seedSkipped?.filter { $0.hasPrefix("没归进目录") }.isEmpty ?? true)
        unapproved = item(outline, "码头").id
        try await approve(outline.id, [item(outline, "阿青").id])
        _ = await CatalogSession(job: j).resumeSeed(outline.id)
        let content = try XCTUnwrap(contents(outline.id).first { $0.directionRef?.itemId == item(outline, "阿青").id })
        XCTAssertEqual(content.items.compactMap(\.change.targetPath), ["人/阿青"], "别的页的条目扔掉")
        guard case .newPage(let page) = content.items[0].change else { return XCTFail() }
        XCTAssertEqual(page.kind, .person, "类按目录")
        XCTAssertEqual(page.title, "阿青")
        XCTAssertFalse(contents(outline.id).contains { $0.directionRef?.itemId == unapproved }, "没批的不写")
        XCTAssertEqual(wiki.pagePaths(), [], "agent 写不到正式 wiki")
    }

    /// 走查 P2：逐项驳回目录，中间不续整理记录、不重复写页；全部决定后任务照实结算。
    func testOutlineDecisionsDoNotRepeatWritingAndSettleOnlyWhenDecided() async throws {
        let model = SeedModel()
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青每天早上看船。")
        try cc("user_b.md", type: "user", title: "纸舟", body: "纸舟是离线阅读工具。")
        try cc("user_c.md", type: "user", title: "灯塔", body: "灯塔是天气小组件。")
        for (file, title) in [("user_a", "阿青"), ("user_b", "纸舟"), ("user_c", "灯塔")] {
            var members = ["memory/cc/\(file).md"]
            for i in 1...2 {
                let name = "\(file)_\(i).md"
                try cc(name, type: "user", title: "\(title)补充\(i)", body: "\(title)的第\(i)份补充。")
                members.append("memory/cc/" + name)
            }
            model.topics.append((title, "主题/" + title, members))
        }
        model.topics.append(("还没归类的", "主题/待归类", [slotPath]))
        model.pages = ["主题/阿青": newPage("主题/阿青", "主题", "阿青", "阿青每天早上看船", ["memory/cc/user_a.md"])]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(outline.items.count, 4)
        try await approve(outline.id, [item(outline, "阿青").id])
        try await reject(outline.id, [item(outline, "还没归类的").id])
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let beforeRequests = model.backend.requests.count
        let runs = wiki.root.appendingPathComponent(".runs")
        let runFile = runs.appendingPathComponent(try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: runs.path).first))
        let runBefore = try String(contentsOf: runFile, encoding: .utf8)

        try await reject(outline.id, [item(outline, "纸舟").id])
        MemoryWriteLog.flush()
        let middleBefore = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).count
        let middle = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(middle.skipped, "目录还有 1 项待批")
        MemoryWriteLog.flush()
        XCTAssertEqual(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).count, middleBefore, "目录还有待批、也没批出要写的页：不记日志")
        XCTAssertEqual(tasks.load(outline.id)?.state, .waiting)
        XCTAssertEqual(store.load(outline.id)?.pendingCount, 1)
        XCTAssertEqual(model.backend.requests.count, beforeRequests)
        XCTAssertEqual(try String(contentsOf: runFile, encoding: .utf8), runBefore, "也不往整理记录里续一节")

        try await reject(outline.id, [item(outline, "灯塔").id])
        MemoryWriteLog.flush()
        let before = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).count
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(model.backend.requests.count, beforeRequests)
        MemoryWriteLog.flush()
        let all = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        let added = Array(all.prefix(all.count - before))   // 新的在前
        XCTAssertEqual(added.count, 1, "批完那一下只记一行：\(added.map(\.note))")
        XCTAssertTrue(added.first?.note.hasPrefix("种子完成") == true)
        XCTAssertEqual(added.first?.ok, true)
        XCTAssertEqual(tasks.load(outline.id)?.state, .complete)

        let next = SeedModel()
        next.topics = [("面包", "主题/面包", ["memory/cc/user_a.md"])]
        _ = await CatalogSession(job: job(next)).seed()
        let second = try XCTUnwrap(store.list().first { CatalogSeedDrafts.isOutline($0) && $0.id != outline.id })
        try await reject(second.id)
        MemoryWriteLog.flush()
        let mark = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).count
        _ = await CatalogSession(job: job(next)).resumeSeed(second.id)
        MemoryWriteLog.flush()
        let latest = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        let ended = Array(latest.prefix(latest.count - mark))
        XCTAssertEqual(ended.map(\.note), ["种子：目录全部驳回，没有获批的页，不记完成"])
        XCTAssertEqual(ended.first?.ok, false, "什么都没写，不标「写好了」")
        XCTAssertEqual(tasks.load(second.id)?.state, .ended)
    }

    func testWikiOnlyFloorEndsWithoutRequests() async throws {
        let model = SeedModel()
        try wiki.save(WikiPage(path: "地点/云桥城", kind: .place, hook: "提到云桥城", title: "云桥城", now: "云桥城有座旧码头。"))
        var j = job(model)
        j.floorBase = CatalogFloorBase(sections: [])
        let report = await CatalogSession(job: j).seed()
        let reason = "目录是空的：没有可出要点卡的原料：Prompt 和 CC 记忆都是空的，已有 wiki 页只作更新基线"
        XCTAssertEqual(report.failures, [reason + "，不记完成"])
        XCTAssertTrue(model.backend.requests.isEmpty)
        let task = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(Set(task.materials.map(\.layer)), ["wiki"])
        XCTAssertTrue(task.cardable.isEmpty)
        XCTAssertTrue(task.uncarded.isEmpty)
        XCTAssertEqual(task.state, .ended)
        XCTAssertEqual(task.note, reason)
        XCTAssertNotNil(task.endedAt)
        XCTAssertNil(tasks.open(proposals: store), "没有可出卡原料的任务已结束，不留续跑入口")
        XCTAssertNil(seedOutline())
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
    }

    func testAllRejectedEndsWithoutCompletion() async throws {
        let next = SeedModel()
        try aqingFixture(next)
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
        try w.save(WikiPage(path: "主题/电影", kind: .topic, title: "电影", now: "旧种子写的"))
        try w.saveRaw("旧种子写的第二版", path: "主题/电影")
        try w.save(WikiPage(path: "地点/云桥城", kind: .place, title: "云桥城", now: "她自己写的", records: ["旧种子追加的一行"]))
        try w.save(WikiPage(path: "主题/偏好/电影", kind: .topic, title: "电影", now: "同名的非种子页"))
        try w.save(WikiPage(path: "人/阿青", kind: .person, title: "阿青", now: "她写的",
                            links: [.init(target: "主题/电影", relation: .supplement, why: "")]))
        try w.rebuildAllIndexes()
        try WikiStore.writeAtomic(JSONEncoder().encode(LegacyState(completedAt: Date())), to: CatalogSeed.stateURL(w))
        var approved = WikiProposal(origin: .seed, createdAt: Date(), title: "CC 记忆播种", items: [
            .init(change: .newPage(page: WikiPage(path: "主题/电影", title: "电影"))),
            .init(change: .appendRecords(path: "地点/云桥城", lines: ["旧种子追加的一行"])),
        ])
        approved.items[0].state = .approved
        approved.items[1].state = .approved
        var rejected = WikiProposal(origin: .seed, createdAt: Date(), items: [.init(change: .newPage(page: WikiPage(path: "主题/纸舟", title: "纸舟")))])
        rejected.items[0].state = .rejected
        let pending = WikiProposal(origin: .seed, createdAt: Date(), items: [.init(change: .newPage(page: WikiPage(path: "主题/偏好/电影", title: "电影")))])
        let manual = WikiProposal(origin: .manual, createdAt: Date(), items: [.init(change: .newPage(page: WikiPage(path: "主题/面包", title: "面包")))])
        for p in [approved, rejected, pending, manual] { try store.save(p) }
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        return ("主题/电影", "地点/云桥城", "主题/偏好/电影", "人/阿青", manual.id)
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
        XCTAssertFalse(w.layerMarkdown("主题").contains("[[\(f.created)]]"), "索引按留下的页重建")
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
            try Data("改坏的索引".utf8).write(to: wiki.folderURL("人").appendingPathComponent(WikiStore.indexFileName))
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
        try projectEntityFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        var outline = try XCTUnwrap(seedOutline())
        let paperId = item(outline, "纸舟").id
        try await approve(outline.id, [paperId])

        var entries = CatalogSeedDrafts.entries(wiki: wiki)
        let outlineEntry = try XCTUnwrap(entries.first { $0.kind == .outline(outline.id) })
        XCTAssertTrue(outlineEntry.editable)
        let edited = outlineEntry.content
            .replacingOccurrences(of: "路径: 项目/灯塔", with: "路径: 工程/小组件/灯塔天气")
            .replacingOccurrences(of: "标题: 灯塔\n钩子: \n", with: "标题: 灯塔天气\n钩子: 说到天气小组件时看这页\n")
        XCTAssertNotEqual(edited, outlineEntry.content)
        try await CatalogSeedDrafts.save(outlineEntry, text: edited, baseline: outlineEntry.content, wiki: wiki, profileId: pid, context: ModelContext(container))
        outline = try XCTUnwrap(store.load(outline.id))
        let lighthouse = try XCTUnwrap(item(outline, "灯塔天气").change.direction)
        XCTAssertEqual(lighthouse.path, "工程/小组件/灯塔天气", "审计台读的就是改过的同一份")
        XCTAssertEqual(lighthouse.hook, "说到天气小组件时看这页")
        // 文件库编辑器里显示的是名字：照名字改路径、拿显示的那份当基线，保存落回 {{user}}
        let user = CatalogTestKit.names.user
        let refreshed = try XCTUnwrap(CatalogSeedDrafts.entries(wiki: wiki).first { $0.kind == .outline(outline.id) })
        let shownBase = WikiStore.shown(refreshed.content, user: user)
        try await CatalogSeedDrafts.save(refreshed, text: shownBase.replacingOccurrences(of: "路径: 工程/小组件/灯塔天气", with: "路径: \(user)/灯塔天气"),
                                         baseline: shownBase, wiki: wiki, userName: user, profileId: pid, context: ModelContext(container))
        XCTAssertEqual(item(try XCTUnwrap(store.load(outline.id)), "灯塔天气").change.direction?.path, "{{user}}/灯塔天气")

        do {
            try await CatalogSeedDrafts.save(outlineEntry, text: edited, baseline: outlineEntry.content, wiki: wiki, profileId: pid, context: ModelContext(container))
            XCTFail("别处改过要拒")
        } catch let e as CatalogSeedDrafts.EditError { XCTAssertEqual(e, .conflict) }
        let fresh = try XCTUnwrap(CatalogSeedDrafts.entries(wiki: wiki).first { $0.kind == .outline(outline.id) })
        let touchApproved = fresh.content.replacingOccurrences(of: "标题: 纸舟", with: "标题: 纸舟二")
        do {
            try await CatalogSeedDrafts.save(fresh, text: touchApproved, baseline: fresh.content, wiki: wiki, profileId: pid, context: ModelContext(container))
            XCTFail("已批的只读")
        } catch let e as CatalogSeedDrafts.EditError {
            guard case .readOnly(let why) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(why.contains("「纸舟」已批了，只读"), why)
        }
        let badKind = fresh.content.replacingOccurrences(of: "类: 地点", with: "类: 动物")
        await XCTAssertThrowsErrorAsync { try await CatalogSeedDrafts.save(fresh, text: badKind, baseline: fresh.content, wiki: self.wiki, profileId: self.pid, context: ModelContext(self.container)) }

        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        entries = CatalogSeedDrafts.entries(wiki: wiki)
        let pageEntry = try XCTUnwrap(entries.first { if case .page = $0.kind { return true } else { return false } })
        XCTAssertTrue(pageEntry.editable)
        let newNow = pageEntry.content.replacingOccurrences(of: "纸舟是离线阅读工具\n", with: "纸舟是离线阅读工具，支持全文检索\n")
        XCTAssertNotEqual(newNow, pageEntry.content)
        try await CatalogSeedDrafts.save(pageEntry, text: newNow, baseline: pageEntry.content, wiki: wiki, profileId: pid, context: ModelContext(container))
        guard case .page(let proposalId, let iid) = pageEntry.kind,
              case .newPage(let page) = store.load(proposalId)?.items.first(where: { $0.id == iid })?.change else { return XCTFail() }
        XCTAssertEqual(page.now, "纸舟是离线阅读工具，支持全文检索")
        let saved = try XCTUnwrap(CatalogSeedDrafts.entries(wiki: wiki).first { $0.path == pageEntry.path })
        for broken in [saved.content.replacingOccurrences(of: "（memory/cc/project_c.md）", with: ""),
                       saved.content.replacingOccurrences(of: "memory/cc/project_c.md", with: "memory/cc/别的.md")] {
            await XCTAssertThrowsErrorAsync { try await CatalogSeedDrafts.save(saved, text: broken, baseline: saved.content, wiki: self.wiki, profileId: self.pid, context: ModelContext(self.container)) }
        }

        let seen = Dictionary((store.load(proposalId)?.items ?? []).map { ($0.id, $0.change) }, uniquingKeysWith: { a, _ in a })
        try await CatalogSeedDrafts.save(saved, text: saved.content.replacingOccurrences(of: "支持全文检索", with: "支持离线全文检索"),
                                         baseline: saved.content, wiki: wiki, profileId: pid, context: ModelContext(container))
        do {
            try await WikiProposalReview.approve(proposalId, seen: seen, store: store, profileId: pid, context: ModelContext(container))
            XCTFail("不能沿旧预览无声批准后来改过的内容")
        } catch let e as WikiProposalStore.ProposalError { XCTAssertEqual(e, .changed(iid)) }
    }

    func testDraftFolderSitsUnderWikiAndAssistantFsStaysReadOnly() async throws {
        let model = SeedModel()
        try aqingFixture(model)
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
        for path in ["memory/wiki/.proposals/\(id)/\(id).json", "memory/wiki/人/阿青.md", "memory/wiki/.proposals/\(id)/task.json",
                     "memory/wiki/.proposals/\(id)/materials/001.txt", "memory/wiki/.cards/x.json"] {
            let input = String(decoding: try JSONSerialization.data(withJSONObject: ["path": path, "content": "x"]), as: UTF8.self)
            XCTAssertTrue(FileLibraryTools.execute(name: FileLibraryTools.Name.write.rawValue, inputJSON: input, profileId: pid).isError,
                          "主聊天 fs 对 memory 仍只读：\(path)")
        }
    }

    // MARK: - 留存、预算

    func testPurgeKeepsOpenTasksAndRemovesEndedOnesIncludingThoseWithoutOutline() async throws {
        let old = Date().addingTimeInterval(-40 * 86_400)
        let empty = SeedModel()
        try wiki.save(WikiPage(path: "地点/旧港", kind: .place, title: "旧港", now: "虚构基线"))
        var emptyJob = job(empty)
        emptyJob.floorBase = CatalogFloorBase(sections: [])
        _ = await CatalogSession(job: emptyJob).seed(now: old)
        let ended = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(ended.state, .ended, "只有 wiki 基线、没有可出卡原料的任务结束")

        let stuck = SeedModel()
        try cc("user_a.md", type: "user", title: "阿青", body: "阿青喜欢海图。")
        try cc("user_b.md", type: "user", title: "阿青的船", body: "阿青有一条纸帆船。")   // 新原料：不能复用上一次的卡，得真的请求
        stuck.fail = { _ in "网关超时" }
        _ = await CatalogSession(job: job(stuck)).seed(now: old.addingTimeInterval(1))
        let open = try XCTUnwrap(tasks.all().first { $0.id != ended.id })
        guard case .reading = open.status(outline: nil) else { return XCTFail("出卡失败的任务能续跑") }

        store.purgeFinished()
        XCTAssertNil(tasks.load(ended.id), "没有目录的结束任务按结束时间满 30 天也清掉（连快照一起）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tasks.materialsFolder(ended.id).path))
        XCTAssertNotNil(tasks.load(open.id), "还能续跑的任务不清")

        let model = SeedModel()
        // 两份 CC 都还没出卡；user_a 不提实体，user_b 提到阿青。
        model.cards = ["memory/cc/user_b.md": card("阿青的船", "阿青有一条纸帆船", [("阿青", "人")], group: "人")]
        model.topics = [("还没归类的", "主题/待归类", ["memory/cc/user_a.md", "memory/cc/user_b.md", slotPath])]
        // user_a 只是「阿青」的回扫候选（卡上没提），出处只能写正式原料 user_b
        model.pages = ["主题/待归类": newPage("主题/待归类", "主题", "还没归类的", "阿青有一条纸帆船", ["memory/cc/user_b.md"])]
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: wiki.root.appendingPathComponent(SeedNoteStore.folderName).path), "卡是楼层级的，不随任务清")
    }

    func testSeedUsesItsOwnDepsWithoutDailyWriteBudget() async throws {
        let model = SeedModel()
        try aqingFixture(model)
        let seedGates = Counter()
        var j = job(model, deps: CatalogAgent.Deps(makeBackend: { model.backend }, gate: { _ in
            await seedGates.bump()
            return nil
        }))
        j.agentDeps = CatalogAgent.Deps(makeBackend: { model.backend }, gate: { _ in "写入预算用完" })
        let report = await CatalogSession(job: j).seed()
        XCTAssertNil(report.blocked)
        XCTAssertNotNil(seedOutline())
        XCTAssertEqual(seedGates.value, model.backend.requests.count, "每个请求都过种子的闸（只有全局总闸），不过日常写入预算")
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

        let cloud = try XCTUnwrap(contents(outline.id).first)
        XCTAssertEqual(cloud.items.first?.change.kindLabel, "追加记录", "坏出处那行丢了，合法的照交")
        let link = try XCTUnwrap(cloud.run)
        let text = try String(contentsOf: try XCTUnwrap(CatalogRunRecord.resolve(link, wiki: wiki)), encoding: .utf8)
        let diag = try XCTUnwrap(text.components(separatedBy: "<a id=\"").first { $0.contains("种子交页「云桥城」") && $0.contains("交审诊断") })
        for part in ["- memory/cc/user_a.md：「记录」", "不是这次给的输入，不算：\n- memory/cc/没读.md", "这次没改已有页的「现在」"] {
            XCTAssertTrue(diag.contains(part), part)
        }
    }

    // MARK: - 写一页：路径锁死在目录项上、坏连线只丢连线、超时原样再发一次

    private struct NotNewPage: Error {}
    private let dotPath = "物/星砚 · 笔墨"

    /// 目录项的路径里带「 · 」（卡上的名字就这么写、她已经批了）：岚舟那项留着待批
    private func dotFixture(_ model: SeedModel) throws {
        try cc("user_lan.md", type: "user", title: "岚舟的砚台", body: "岚舟收着一方星砚，每周日磨墨练字。")
        model.cards = ["memory/cc/user_lan.md": card("岚舟的砚台", "岚舟收着一方星砚，每周日磨墨练字", [("星砚 · 笔墨", "物"), ("岚舟", "人")], group: "人")]
        try supportingCards(model, mentions: [("星砚 · 笔墨", "物"), ("岚舟", "人")])
        model.cards[slotPath] = card("练字设定", "岚舟用星砚练字", [("星砚 · 笔墨", "物"), ("岚舟", "人")], group: "人")
    }

    /// 写手少抄了半截路径、还连到待批的项和不存在的页
    private func wrongPathPage(_ itemId: String) -> AssistantBackendEvent {
        var page = newPage("物/星砚", "物", "星砚", "岚舟每周日用星砚磨墨练字", ["memory/cc/user_lan.md"])
        page[0]["links"] = [["to": "人/岚舟", "relation": "补充", "why": "砚台的主人"],
                            ["to": "事/不存在的展", "relation": "补充", "why": "瞎连"]]
        return .toolCalls([SeedModel.call("submit_proposal", ["phase": "page", "item": itemId, "items": page])])
    }

    private func dotContent(_ outlineId: String, _ itemId: String) throws -> WikiPage {
        let content = try XCTUnwrap(contents(outlineId).first { $0.directionRef?.itemId == itemId }, "这一页交上了")
        XCTAssertEqual(content.items.count, 1)
        guard case .newPage(let page) = content.items.first?.change else { throw NotNewPage() }
        return page
    }

    func testPageUsesTheCatalogPathAndBadLinksOnlyDropTheLinks() async throws {
        let model = SeedModel()
        try dotFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let ink = item(outline, "星砚 · 笔墨").id
        XCTAssertEqual(item(outline, "星砚 · 笔墨").change.direction?.path, dotPath, "名字里有「 · 」照样成页，她批的就是这个路径")
        try await approve(outline.id, [ink])
        model.pageEvent = { _, id in self.wrongPathPage(id) }
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(model.backend.requests.count, before + 1, "交错的路径按目录项算，一轮就过，不打回")
        let page = try dotContent(outline.id, ink)
        XCTAssertEqual(page.path, dotPath, "路径锁死在目录项上")
        XCTAssertEqual(page.title, "星砚 · 笔墨", "标题按目录")
        XCTAssertTrue(page.records.contains("未注明 · 岚舟的砚台（memory/cc/user_lan.md）"), "记录采用卡标题与原料路径")
        XCTAssertEqual(page.links, [], "目标待批 / 不存在的连线去掉，页照收")
        MemoryWriteLog.flush()

        let request = model.backend.requests[before]
        let opening = try XCTUnwrap(request.history.first?.content)
        XCTAssertTrue(opening.contains("岚舟的砚台") && opening.contains("memory/cc/user_lan.md"))
        XCTAssertFalse(opening.contains("岚舟收着一方星砚，每周日磨墨练字。"))
        let tool = try XCTUnwrap(request.tools.first?["function"] as? [String: Any])
        let props = try XCTUnwrap((tool["parameters"] as? [String: Any])?["properties"] as? [String: Any])
        let entryProps = try XCTUnwrap(((props["items"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual((entryProps["path"] as? [String: Any])?["enum"] as? [String], [dotPath], "条目的 path 只能是这一项的")
        XCTAssertEqual((entryProps["type"] as? [String: Any])?["enum"] as? [String], ["new_page"], "新开页只给 new_page")
    }

    /// 真机那份旧 checkpoint 的形状：目录路径带「 · 」，单页对话里有两轮因为路径被打回的回合、stalls = 2，上一轮超时停下。
    /// 点继续：旧写法开的对话重开一次（新开场、stalls 清零），按锁死的路径一轮写成
    func testOldPageSessionWithDotPathRestartsAndWritesWithTheLockedPath() async throws {
        let model = SeedModel()
        try dotFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let ink = item(outline, "星砚 · 笔墨").id
        try await approve(outline.id, [ink])
        var task = try XCTUnwrap(tasks.load(outline.id))
        let currentKey = CatalogAgent.pageKey(try XCTUnwrap(item(outline, "星砚 · 笔墨").change.direction), task: task)
        let legacyKey = (["开场 3 · L1 条目"] + currentKey.components(separatedBy: "\n").dropFirst()).joined(separator: "\n")
        XCTAssertNotEqual(currentKey, legacyKey)
        func rejected(_ id: String) -> CatalogSeedTask.Turn {
            .init(calls: [.init(id: id, name: "submit_proposal", argumentsJSON: "{\"phase\":\"page\",\"item\":\"\(ink)\",\"items\":[]}", truncated: false)],
                  results: [.init(toolUseId: id, text: "「星砚 · 笔墨」没有能用的条目，按下面的原因改了重交：\n物/星砚：不是这个目录项的页（\(dotPath)）\n\(dotPath)：没有带出处的事实正文", isError: true)])
        }
        task.page = .init(item: ink, history: [.init(role: "user", content: "【整份目录】\n- \(dotPath) · 物 · 星砚 · 笔墨 · 已批\n\n【这一页】item=\(ink) · \(dotPath) · 物 · 新开页")],
                          turns: [rejected("r24"), rejected("r25")], pending: nil,
                          key: legacyKey, stalls: 2)
        task.state = .stopped
        task.note = "第 26 轮出错（写「星砚 · 笔墨」）：The request timed out.（api.anthropic.com · 假模型 · HTTP 200）"
        try tasks.save(task)
        XCTAssertEqual(task.status(outline: seedOutline()), .writable(1), "能点继续")

        model.pageEvent = { _, id in self.wrongPathPage(id) }
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(model.backend.requests.count, before + 1, "不卡在旧的打回上")
        let request = model.backend.requests[before]
        XCTAssertEqual(request.history.count, 1, "旧写法开的那段对话重开")
        XCTAssertTrue(request.toolTurns.isEmpty, "旧的两轮打回不回灌")
        XCTAssertTrue(request.history[0].content.contains("{\"path\":\"\(dotPath)\""))
        XCTAssertEqual(try dotContent(outline.id, ink).path, dotPath)
        XCTAssertNil(tasks.load(outline.id)?.page, "写完清掉这一页的对话")
    }

    func testTimedOutPageRoundIsSentAgainOnceThenStopsAndContinueWorks() async throws {
        let model = SeedModel()
        try dotFixture(model)
        let flag = TimeoutFlag()
        let timeout = "The request timed out.（api.anthropic.com · 假模型 · HTTP 200）"
        let deps = CatalogAgent.Deps(makeBackend: { model.backend }, gate: { _ in nil }, roundTimedOut: { _ in flag.on })
        let first = await CatalogSession(job: job(model, deps: deps)).seed()
        XCTAssertEqual(first.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        let ink = item(outline, "星砚 · 笔墨").id
        try await approve(outline.id, [ink])

        // 写一页：超时一次 → 原样再发一次就写成
        var timeouts = 1
        model.pageEvent = { _, _ in
            flag.on = timeouts > 0
            guard flag.on else { return nil }
            timeouts -= 1
            return .failed(timeout)
        }
        model.pages = [dotPath: newPage(dotPath, "物", "星砚 · 笔墨", "岚舟每周日用星砚磨墨练字", ["memory/cc/user_lan.md"])]
        var before = model.backend.requests.count
        let once = await CatalogSession(job: job(model, deps: deps)).resumeSeed(outline.id)
        XCTAssertEqual(once.failures, [])
        XCTAssertEqual(model.backend.requests.count, before + 2)
        XCTAssertEqual(model.backend.requests[before].history.map(\.content), model.backend.requests[before + 1].history.map(\.content))
        XCTAssertNotNil(contents(outline.id).first { $0.directionRef?.itemId == ink })
        MemoryWriteLog.flush()
        XCTAssertTrue(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).contains { $0.note.contains("请求超时，原样再发一次") })

        // 连着两次超时：只再发一次，停下（不记完成、这一页的对话留着），点继续接着写
        try await approve(outline.id, [item(outline, "岚舟").id])
        model.pages["人/岚舟"] = newPage("人/岚舟", "人", "岚舟", "岚舟收着一方星砚", ["memory/cc/user_lan.md"])
        timeouts = 2
        before = model.backend.requests.count
        let twice = await CatalogSession(job: job(model, deps: deps)).resumeSeed(outline.id)
        XCTAssertEqual(model.backend.requests.count, before + 2, "不无限重试")
        let note = try XCTUnwrap(twice.failures.first)
        XCTAssertTrue(note.contains("请求超时（写「岚舟」），已经原样再发过一次还是超时，先停下了"), note)
        XCTAssertTrue(note.contains("可以点「继续这个种子任务」") && note.contains(timeout), note)
        let stopped = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.page?.item, item(outline, "岚舟").id)
        XCTAssertEqual(stopped.page?.stalls, 0, "超时不算没进展")
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
        let resumed = await CatalogSession(job: job(model, deps: deps)).resumeSeed(outline.id)
        XCTAssertEqual(resumed.failures, [])
        XCTAssertNotNil(CatalogSeed.completion(wiki: wiki))
    }

    /// astra P1：两项共用一份原料，写 A 时模型把 B 的正文也交上来（路径写 B）：B 那条打回「这段只写本项」，不改成 A；
    /// 路径定死时新开页只能恰好一条；更新页同理（写到别的目录项的追加不收，路径写错但不是别的项的按本项纠正）
    func testEntriesForAnotherCatalogPageAreRejectedNotRelabeled() async throws {
        let model = SeedModel()
        try cc("user_lan.md", type: "user", title: "岚舟和星砚", body: "岚舟是港口的灯塔看守。星砚是岚舟收着的一方砚台。")
        try wiki.save(WikiPage(path: "地点/潮汐港", kind: .place, hook: "提到潮汐港", title: "潮汐港", now: "潮汐港有座灯塔。", factDomain: .realWorld))
        let lan = "人/岚舟", ink = "物/星砚", port = "地点/潮汐港"
        let src = ["memory/cc/user_lan.md"]
        model.cards = ["memory/cc/user_lan.md": card("岚舟和星砚", "岚舟看守灯塔，收着星砚", [("岚舟", "人"), ("星砚", "物"), ("潮汐港", "地点")], group: "人")]
        model.merge = [["into": "wiki:地点/潮汐港", "names": ["潮汐港"]]]
        try supportingCards(model, mentions: [("岚舟", "人"), ("星砚", "物")])
        var j = job(model)
        j.floorBase = CatalogFloorBase(sections: [])
        _ = await CatalogSession(job: j).seed()
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(Set(outline.items.compactMap { $0.change.direction?.path }), [lan, ink, port])
        let lanId = item(outline, "岚舟").id, portId = item(outline, "潮汐港").id
        try await approve(outline.id, [lanId])
        func submit(_ id: String, _ items: [[String: Any]]) -> AssistantBackendEvent {
            .toolCalls([SeedModel.call("submit_proposal", ["phase": "page", "item": id, "items": items])])
        }
        var round = 0
        model.pageEvent = { _, id in
            round += 1
            switch round {
            case 1: return submit(id, self.newPage(ink, "物", "星砚", "星砚是一方砚台", src))
            case 2: return submit(id, self.newPage("人/岚舟的家", "人", "岚舟", "岚舟看守灯塔", src) + self.newPage("人/守灯人", "人", "守灯人", "守灯人", src))
            default: return submit(id, self.newPage(ink, "物", "星砚", "星砚是一方砚台", src) + self.newPage(lan, "人", "岚舟", "岚舟是港口的灯塔看守", src))
            }
        }
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(model.backend.requests.count, before + 3)
        let receipts = model.backend.requests[before + 2].toolTurns.flatMap(\.results).map(\.text)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertTrue(receipts[0].contains("没有能用的条目") && receipts[0].contains("这段只写本项（\(lan)）；\(ink) 是另一页"), "只交了别的目录项的正文：打回，不收成本页：\(receipts[0])")
        XCTAssertTrue(receipts[1].contains("新开页只能交一条 new_page，这次交了 2 条"), receipts[1])
        let page = try dotContent(outline.id, lanId)
        XCTAssertEqual(page.path, lan)
        XCTAssertEqual(page.title, "岚舟")
        XCTAssertTrue(page.records.contains("未注明 · 岚舟和星砚（memory/cc/user_lan.md）"))
        XCTAssertFalse(contents(outline.id).contains { $0.items.contains { if case .newPage(let p) = $0.change { return p.records.contains { $0.contains("砚台") } } else { return false } } })

        try await approve(outline.id, [portId])
        model.pageEvent = { _, id in
            submit(id, [["type": "append", "path": ink, "records": [["text": "日期未注明 星砚收在潮汐港的屋里", "sources": src]]],
                        ["type": "append", "path": "地点/潮汐", "records": [["text": "日期未注明 岚舟在潮汐港看守灯塔", "sources": src]]]])
        }
        let again = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(again.failures, [])
        let update = try XCTUnwrap(contents(outline.id).first { $0.directionRef?.itemId == portId })
        let appended = update.items.compactMap { item -> [String]? in
            if case .appendRecords(let path, let lines) = item.change, path == port { return lines } else { return nil }
        }
        XCTAssertEqual(appended, [["未注明 · 岚舟和星砚（memory/cc/user_lan.md）"]], "按本目录正式原料生成追加，不采用模型 append 内容")
        XCTAssertTrue(update.items.allSatisfy { $0.change.targetPath == port })
    }

    /// astra P2：没有 key 的兼容会话 = 旧写法：先对账 pending（见上面 pending 那条），还要请求模型时按新开场重开，
    /// 第一稿和修改要求迁进来，stalls 清零
    func testPageSessionWithoutKeyReopensWithNewOpeningAndRevision() async throws {
        let model = SeedModel()
        try dotFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let ink = item(outline, "星砚 · 笔墨").id
        try await approve(outline.id, [ink])
        var task = try XCTUnwrap(tasks.load(outline.id))
        task.revisionDrafts = [ink: "{\"phase\":\"page\",\"item\":\"\(ink)\",\"items\":[\"FIRST_DRAFT_MARKER\"]}"]
        task.revisionAsks = [ink: "- 记录要写日期"]
        task.page = .init(item: ink, history: [.init(role: "user", content: "旧开场 · 【这一页】item=\(ink) · \(dotPath) · 物")],
                          turns: [.init(calls: [.init(id: "old", name: "submit_proposal", argumentsJSON: "{\"phase\":\"page\",\"item\":\"\(ink)\",\"items\":[]}", truncated: false)],
                                        results: [.init(toolUseId: "old", text: "「星砚 · 笔墨」没有能用的条目", isError: true)])],
                          pending: nil, key: nil, stalls: 2)
        task.state = .stopped
        try tasks.save(task)
        var round = 0
        model.pageEvent = { _, _ in
            round += 1
            return round <= 2 ? .finished("我再想想") : nil
        }
        model.pages = [dotPath: newPage(dotPath, "物", "星砚 · 笔墨", "岚舟每周日用星砚磨墨练字", ["memory/cc/user_lan.md"])]
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [], "stalls 清零：两轮只回字也不停")
        XCTAssertEqual(model.backend.requests.count, before + 3)
        let request = model.backend.requests[before]
        XCTAssertEqual(request.history.count, 1, "重开")
        XCTAssertTrue(request.toolTurns.isEmpty, "旧回合不回灌")
        let opening = request.history[0].content
        XCTAssertFalse(opening.contains("旧开场"))
        XCTAssertTrue(opening.contains("{\"path\":\"\(dotPath)\""), "新开场")
        XCTAssertTrue(opening.contains("【这一页之前交过一稿，没过检查】") && opening.contains("- 记录要写日期") && opening.contains("FIRST_DRAFT_MARKER"), "修订稿和要求迁进来")
        XCTAssertNotNil(contents(outline.id).first { $0.directionRef?.itemId == ink })
        XCTAssertNil(tasks.load(outline.id)?.page)
    }

    /// astra 复核 P1：另一页用原料文件路径写法（memory/wiki/<页>.md）也认得出是另一页，不改名收成本页
    func testWikiFileSpellingOfAnotherPageIsStillAnotherPage() async throws {
        let model = SeedModel()
        try cc("user_lan.md", type: "user", title: "岚舟", body: "岚舟是港口的灯塔看守。")
        try wiki.save(WikiPage(path: "物/星砚", kind: .thing, hook: "提到星砚", title: "星砚", now: "星砚是一方砚台。", factDomain: .realWorld))
        let lan = "人/岚舟", inkFile = "memory/wiki/物/星砚.md"
        model.cards = ["memory/cc/user_lan.md": card("岚舟", "岚舟是港口的灯塔看守", [("岚舟", "人"), ("星砚", "物")], group: "人")]
        try supportingCards(model, mentions: [("岚舟", "人")])
        model.merge = [["into": "wiki:物/星砚", "names": ["星砚"]]]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        XCTAssertEqual(item(outline, "星砚").change.direction?.action, .update, "同名已有页按更新列")
        let lanId = item(outline, "岚舟").id
        try await approve(outline.id, [lanId])
        var round = 0
        model.pageEvent = { _, id in
            round += 1
            let items = round == 1 ? self.newPage(inkFile, "物", "星砚", "星砚是岚舟收着的砚台", ["memory/cc/user_lan.md"])
                : self.newPage(lan, "人", "岚舟", "岚舟是港口的灯塔看守", ["memory/cc/user_lan.md"])
            return .toolCalls([SeedModel.call("submit_proposal", ["phase": "page", "item": id, "items": items])])
        }
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(model.backend.requests.count, before + 2)
        let receipt = try XCTUnwrap(model.backend.requests[before + 1].toolTurns.first?.results.first?.text)
        XCTAssertTrue(receipt.contains("这段只写本项（\(lan)）；物/星砚 是另一页"), receipt)
        let page = try dotContent(outline.id, lanId)
        XCTAssertTrue(page.records.contains("未注明 · 岚舟（memory/cc/user_lan.md）"), "收的是本项正式原料的卡")
    }

    /// astra 复核 P2：更新已有页，rewrite_now 写了完整路径、带出处的 append 少抄半截（不是别的页）：append 按本页纠正照收，不误删、不卡住
    func testUpdateWithFullAndShortenedPathsKeepsBothEntries() async throws {
        let model = SeedModel()
        try dotFixture(model)
        try wiki.save(WikiPage(path: dotPath, kind: .thing, hook: "提到星砚的时候先看这页", title: "星砚的笔墨", now: "岚舟有一方星砚。", factDomain: .realWorld))
        model.merge = [["into": "wiki:\(dotPath)", "names": ["星砚 · 笔墨"]]]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let ink = item(outline, "星砚的笔墨").id
        XCTAssertEqual(item(outline, "星砚的笔墨").change.direction?.action, .update, "合进 wiki 锚：标题按页、动作是更新")
        try await approve(outline.id, [ink])
        model.pageEvent = { _, id in
            .toolCalls([SeedModel.call("submit_proposal", ["phase": "page", "item": id, "items": [
                ["type": "rewrite_now", "path": self.dotPath, "now": "岚舟每周日用星砚磨墨练字。"],
                ["type": "append", "path": "物/星砚", "records": [["text": "日期未注明 岚舟每周日用星砚磨墨练字", "sources": ["memory/cc/user_lan.md"]]]],
            ]])])
        }
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(model.backend.requests.count, before + 1, "一轮就过，不打回")
        let content = try XCTUnwrap(contents(outline.id).first { $0.directionRef?.itemId == ink })
        XCTAssertTrue(content.items.allSatisfy { $0.change.targetPath == dotPath })
        XCTAssertTrue(content.items.contains { if case .rewriteNow = $0.change { return true } else { return false } })
        XCTAssertTrue(content.items.contains {
            if case .appendRecords(_, let lines) = $0.change { return lines.contains("未注明 · 岚舟的砚台（memory/cc/user_lan.md）") } else { return false }
        }, "少抄半截的 append 按本页纠正收下")
    }
    func testGeneratedRecordsSortDatesThenPathsTruncateTitlesAndKeepUnknownLast() async throws {
        let model = SeedModel()
        try aqingFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let task = try XCTUnwrap(tasks.load(outline.id))
        let direction = try XCTUnwrap(outline.items.first?.change.direction)
        let paths = try XCTUnwrap(direction.sources).sorted()
        XCTAssertEqual(paths.count, 3)
        let cards = SeedNoteStore(wiki: wiki)
        for (i, path) in paths.enumerated() {
            var saved = try XCTUnwrap(cards.load(path: path, version: try XCTUnwrap(task.carded?[path])))
            saved.title = i == 0 ? String(repeating: "长", count: 35) : "条目\(i)"
            saved.when = i < 2 ? ["2026-10-09", "2026-02-30", "2026-01-02", "昨天"] : ["很久以前"]
            try cards.save(saved)
        }
        let generated = CatalogSeedTools.generatedRecords(direction: direction, task: task, wiki: wiki)
        XCTAssertEqual(generated.map(\.path), paths)
        XCTAssertEqual(generated.map(\.line), [
            "2026-01-02 · \(String(repeating: "长", count: 30))（\(paths[0])）",
            "2026-01-02 · 条目1（\(paths[1])）",
            "未注明 · 条目2（\(paths[2])）",
        ])
        XCTAssertEqual(generated.compactMap(\.entry), paths.map { "\($0)|\(task.carded![$0]!)" })
        var earlier = try XCTUnwrap(cards.load(path: paths[1], version: task.carded![paths[1]]!))
        earlier.when = ["2025-12-31"]
        try cards.save(earlier)
        XCTAssertEqual(CatalogSeedTools.generatedRecords(direction: direction, task: task, wiki: wiki).map(\.path), [paths[1], paths[0], paths[2]])
    }

    func testMissingEntryCardFallsBackOnlyThatMaterialAndRecordsTrace() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let target = item(outline, "阿青")
        let task = try XCTUnwrap(tasks.load(outline.id))
        let path = "memory/cc/user_a.md"
        try FileManager.default.removeItem(at: SeedNoteStore(wiki: wiki).url(path: path, version: try XCTUnwrap(task.carded?[path])))
        guard case .success(let opening) = CatalogAgent.pageOpening(target, outline: outline, task: task, wiki: wiki) else { return XCTFail() }
        XCTAssertTrue(opening.text.contains("阿青每天早上七点去码头看船。"))
        XCTAssertFalse(opening.text.contains("阿青收集《灯塔航线》的纸质海图。"))
        XCTAssertFalse(opening.text.contains(longSlot))
        try await approve(outline.id, [target.id])
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let proposal = try XCTUnwrap(contents(outline.id).first)
        let trace = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(XCTUnwrap(proposal.run), wiki: wiki)), encoding: .utf8)
        XCTAssertTrue(trace.contains("条目卡缺失") && trace.contains("回退全文") && trace.contains(path))
    }

    func testApprovedSeedAppendKeepsPinnedCardVersionAndExistingEntries() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let path = "地点/云桥城"
        let source = "memory/cc/user_a.md"
        let oldRecord = "2020-01-01 · 岚舟到过云桥城（memory/cc/旧游记.md）"
        let oldEntry = "memory/cc/旧游记.md|old-version"
        try wiki.save(WikiPage(path: path, kind: .place, title: "云桥城", now: "旧码头",
                               records: [oldRecord], entries: [oldEntry], factDomain: .realWorld))
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let task = try XCTUnwrap(tasks.load(outline.id))
        let version = try XCTUnwrap(task.carded?[source])
        try await approve(outline.id, [item(outline, "云桥城").id])
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        let proposal = try XCTUnwrap(contents(outline.id).first)
        XCTAssertEqual(wiki.read(path)?.records, [oldRecord], "正文未批不能写记录或条目引用")
        XCTAssertEqual(wiki.read(path)?.entries, [oldEntry])

        try cc("user_a.md", type: "user", title: "岚舟的新安排", body: "岚舟改在周五去云桥城写生。")
        var newer = try XCTUnwrap(SeedNoteStore(wiki: wiki).load(path: source, version: version))
        newer.version = WikiStore.version(of: try Data(contentsOf: root.appendingPathComponent("cc/user_a.md")))
        newer.madeAt = newer.madeAt.addingTimeInterval(60)
        try SeedNoteStore(wiki: wiki).save(newer)
        XCTAssertNotEqual(newer.version, version)

        try await approve(proposal.id)
        let page = try XCTUnwrap(wiki.read(path))
        XCTAssertEqual(page.records, [oldRecord, "未注明 · 阿青的作息（\(source)）"])
        XCTAssertEqual(page.entries, [oldEntry, source + "|" + version], "必须使用本任务版本，不取当前原料或最新卡")
        try await approve(proposal.id)
        XCTAssertEqual(wiki.read(path)?.entries, page.entries, "重复批准不重复追加引用")
    }

    func testCanonicalRecordEditsPreserveSourcesAndLegacyChecks() throws {
        let path = "memory/cc/写生（副本）.md"
        let first = "未注明 · 岚舟的写生（\(path)）"
        let second = "2026-09-01 · 星砚整理画册（问卷/在做什么）"
        let legacy = "2026-09-01 看画册（出处：CC memory/cc/画册.md；用户编辑）"
        let original = [first, second, legacy]
        XCTAssertEqual(try CatalogSources.checkEdited(original, original: original, allowed: []), original)
        XCTAssertEqual(CatalogSources.split(first).labels, [path], "路径自己的中文括号不能截掉")
        let edited = first.replacingOccurrences(of: "岚舟的写生", with: "岚舟每周五写生")
        XCTAssertEqual(try CatalogSources.checkEdited([edited, second, legacy], original: original, allowed: []),
                       [edited, second, legacy])
        XCTAssertEqual(try CatalogSources.checkEdited([second], original: [first, second], allowed: []), [second])
        XCTAssertEqual(try CatalogSources.checkEdited([first, "星砚补充说明"], original: [first], allowed: []),
                       [first, "星砚补充说明（出处：用户编辑）"])
        XCTAssertThrowsError(try CatalogSources.checkEdited(["未注明 · 岚舟的写生"], original: [first], allowed: []))
        XCTAssertThrowsError(try CatalogSources.checkEdited(["未注明 · 岚舟的写生改在周五"], original: [first], allowed: []))
        for rewritten in ["补记：未注明 · 岚舟的写生，改在周五", "岚舟的写生"] {
            XCTAssertThrowsError(try CatalogSources.checkEdited([rewritten], original: [first], allowed: []))
        }
        XCTAssertThrowsError(try CatalogSources.checkEdited([first.replacingOccurrences(of: path, with: "memory/cc/别的.md")],
                                                           original: [first], allowed: []))
        XCTAssertThrowsError(try CatalogSources.checkEdited(["2026-09-01 看画册（出处：CC memory/cc/别的.md）"],
                                                           original: [legacy], allowed: []))
    }

    func testDeletingCodeRecordAndAddingUnrelatedManualRecordPreservesOtherSources() throws {
        let removed = "2026-09-01 · 岚舟每周五写生（memory/cc/写生.md）"
        let retained = "2026-09-01 · 星砚整理画册（memory/cc/画册.md）"
        let manual = "2026-09-01 · 云桥城开了一间新茶馆"
        let edited = try CatalogSources.checkEdited([retained, manual], original: [removed, retained], allowed: [])
        XCTAssertEqual(edited, [retained, manual + "（出处：用户编辑）"])
    }

    func testApprovedSeedAppendLogsCardSnapshotMismatchWithoutChangingRecords() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let path = "地点/云桥城"
        let source = "memory/cc/user_a.md"
        let oldEntry = "memory/cc/旧游记.md|old-version"
        let oldRecord = "2020-01-01 · 星砚到过云桥城（memory/cc/旧游记.md）"
        try wiki.save(WikiPage(path: path, kind: .place, title: "云桥城", now: "旧码头",
                               records: [oldRecord], entries: [oldEntry], factDomain: .realWorld))
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id, [item(outline, "云桥城").id])
        _ = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        let proposal = try XCTUnwrap(contents(outline.id).first)
        var task = try XCTUnwrap(tasks.load(outline.id))
        let snapshotVersion = try XCTUnwrap(task.read[source])
        let cardVersion = "mismatched-card-version"
        task.carded?[source] = cardVersion
        try tasks.save(task)
        let before = Set(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).map(\.id))

        try await approve(proposal.id)
        let page = try XCTUnwrap(wiki.read(path))
        XCTAssertEqual(page.records, [oldRecord, "未注明 · 阿青的作息（\(source)）"])
        XCTAssertEqual(page.entries, [oldEntry], "卡版本不一致仍只跳过引用，不造假引用也不丢记录")
        XCTAssertEqual(store.load(proposal.id)?.items.first?.state, .approved)
        let warnings = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).filter { !before.contains($0.id) && !$0.ok }
        XCTAssertEqual(warnings.count, 1)
        let warning = try XCTUnwrap(warnings.first)
        for context in [path, source, cardVersion, snapshotVersion] {
            XCTAssertTrue(warning.note.contains(context), "异常日志必须能定位页、原料和对不上的版本")
        }
    }

    func testGeneratedAppendDeduplicatesByPathAndKeepsOriginalRecord() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let source = "memory/cc/user_（作息）.md"
        try FileManager.default.moveItem(at: root.appendingPathComponent("cc/user_a.md"), to: root.appendingPathComponent("cc/user_（作息）.md"))
        model.cards[source] = model.cards.removeValue(forKey: "memory/cc/user_a.md")
        let existing = "2020-01-01 · 旧标题（\(source)）"
        try wiki.save(WikiPage(path: "地点/云桥城", kind: .place, title: "云桥城", now: "旧码头", records: [existing], factDomain: .realWorld))
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let task = try XCTUnwrap(tasks.load(outline.id))
        let direction = try XCTUnwrap(item(outline, "云桥城").change.direction)
        let parsed = try XCTUnwrap(CatalogSeedTools.parsePage(SeedModel.json(["items": [["type": "append", "path": direction.path, "records": [["text": "模型旧行", "sources": [source]]]]]]), sources: CatalogSeedTools.sources(task, allowed: Set(direction.sources ?? [])), wiki: wiki))
        let generated = CatalogSeedTools.page(parsed, direction: direction, task: task, wiki: wiki)
        XCTAssertFalse(generated.items.contains { if case .appendRecords = $0.change { return true }; return false })
        XCTAssertEqual(wiki.read("地点/云桥城")?.records, [existing])
    }
    func testModelRecordsAreDroppedWithoutLosingAnyApprovedSource() async throws {
        let model = SeedModel()
        try aqingFixture(model)
        model.pages["{{user}}/阿青"] = [["type": "new_page", "path": "{{user}}/阿青", "kind": "用户", "title": "阿青", "now": "阿青喜欢海图",
            "records": [["text": String(repeating: "MODEL_RECORD_ONLY_MARKER", count: 20), "sources": ["memory/cc/不存在.md"]]]]]
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        try await approve(outline.id)
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        let proposal = try XCTUnwrap(contents(outline.id).first)
        guard case .newPage(let page) = proposal.items[0].change else { return XCTFail() }
        let sources = try XCTUnwrap(outline.items.first?.change.direction?.sources)
        XCTAssertEqual(page.records.count, sources.count)
        XCTAssertEqual(Set(page.records.compactMap { line in sources.first { line.hasSuffix("（\($0)）") } }), Set(sources))
        XCTAssertFalse(page.records.contains { $0.contains("MODEL_RECORD_ONLY_MARKER") })
        XCTAssertTrue(proposal.items[0].checks?.isEmpty ?? true, "模型记录长度不再触发写作者修订")
        let trace = try String(contentsOf: XCTUnwrap(CatalogRunRecord.resolve(XCTUnwrap(proposal.run), wiki: wiki)), encoding: .utf8)
        XCTAssertTrue(trace.contains("记录由代码生成"))
    }
    func testBothClusterRoundsReceiveOnlyL0WithoutGists() async throws {
        let model = SeedModel()
        try aqingFixture(model)
        for path in Array(model.cards.keys) {
            model.cards[path]?["gist"] = "L1_GIST_MUST_NOT_REACH_CLUSTER_" + path
        }
        model.notesReply = { _, kind, _ in
            kind == "cluster" ? .finished(#"{"user_pages":[],"topics":[],"theatre":[],"pending":[]}"#) : nil
        }
        let report = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(report.failures, [])
        let clusters = model.backend.requests.filter { SeedModel.kind($0) == "cluster" }
        XCTAssertEqual(clusters.count, 2)
        for request in clusters {
            let input = try XCTUnwrap(request.history.first?.content)
            XCTAssertFalse(input.contains("L1_GIST_MUST_NOT_REACH_CLUSTER_"))
            for fields in model.cards.values {
                XCTAssertTrue(input.contains(try XCTUnwrap(fields["title"] as? String)))
            }
        }
        XCTAssertNotNil(seedOutline(), "补漏后仍有完整目录兜底")
    }
    func testPageReadReturnsOnlyApprovedSnapshotMaterialNotLiveOrAnotherItem() async throws {
        let model = SeedModel()
        try standardFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let target = item(outline, "阿青")
        try await approve(outline.id, [target.id])
        try cc("user_a.md", type: "user", title: "后来改的作息", body: "LIVE_CHANGED_MATERIAL_ONLY")
        var requested = false
        model.pageEvent = { _, _ in
            guard !requested else { return nil }
            requested = true
            return .toolCalls([
                ToolCallBlock(id: "read-approved", name: "read", argumentsJSON: SeedModel.json(["path": "memory/cc/user_a.md"]), truncated: false),
                ToolCallBlock(id: "read-other-item", name: "read", argumentsJSON: SeedModel.json(["path": "memory/cc/project_c.md"]), truncated: false),
                ToolCallBlock(id: "read-prompt", name: "read", argumentsJSON: SeedModel.json(["path": self.slotPath]), truncated: false),
            ])
        }
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        let afterRead = try XCTUnwrap(model.backend.requests.dropFirst(before + 1).first)
        let results = afterRead.toolTurns.flatMap(\.results)
        XCTAssertEqual(results.count, 3)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].text.contains("阿青每天早上七点去码头看船。"), "合法来源窄读任务快照，不读后来修改的 live CC")
        XCTAssertFalse(results[0].text.contains("LIVE_CHANGED_MATERIAL_ONLY"))
        let header = try XCTUnwrap(results[0].text.components(separatedBy: "\n").first)
        let labels = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(header.utf8)) as? NSDictionary)
        XCTAssertEqual(labels["layer"] as? String, "CC")
        XCTAssertEqual(labels["fact_domain"] as? String, "realWorld")
        XCTAssertTrue(labels["source_context"] is NSNull)
        let promptHeader = try XCTUnwrap(results[2].text.components(separatedBy: "\n").first)
        let promptLabels = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(promptHeader.utf8)) as? NSDictionary)
        XCTAssertEqual(promptLabels["layer"] as? String, "Prompt")
        XCTAssertEqual(promptLabels["fact_domain"] as? String, "realWorld")
        let context = try XCTUnwrap(promptLabels["source_context"] as? NSDictionary)
        XCTAssertEqual(context["slotName"] as? String, "自建槽")
        XCTAssertEqual(context["headingPath"] as? [String], [])
        XCTAssertTrue(results[1].isError, "另一目录项原料不属于本页可读范围")
        XCTAssertFalse(results[1].text.contains("纸舟是离线阅读工具"))
        XCTAssertFalse(results[1].text.contains("灯塔是天气小组件"))
        XCTAssertEqual(contents(outline.id).count, 1, "read 回执之后仍可正常交页")
    }
    func testDistinctSourceReadsAreProgressAndRejectedSubmissionExplainsWhy() async throws {
        let model = SeedModel()
        try aqingFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let target = item(outline, "阿青")
        let paths = try XCTUnwrap(target.change.direction?.sources).sorted()
        XCTAssertEqual(paths.count, 3)
        try await approve(outline.id, [target.id])
        var round = 0
        model.pageEvent = { _, id in
            round += 1
            if round <= paths.count {
                return .toolCalls([ToolCallBlock(id: "source-read-\(round)", name: "read",
                    argumentsJSON: SeedModel.json(["path": paths[round - 1]]), truncated: false)])
            }
            if round == paths.count + 1 {
                return .toolCalls([SeedModel.call("submit_proposal", ["phase": "page", "item": id, "items": [[
                    "type": "new_page", "path": "{{user}}/阿青", "kind": "用户", "title": "阿青",
                    "now": "阿青喜欢纸质海图（时间未注明）", "why": "这不是连线条目"
                ]]])])
            }
            return nil
        }
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(report.failures, [])
        let pageRequests = Array(model.backend.requests.dropFirst(before))
        XCTAssertEqual(pageRequests.count, paths.count + 2, "三份新来源读完还能交页，坏字段修复后可继续提交")
        for request in pageRequests.dropFirst().prefix(paths.count) {
            let receipt = try XCTUnwrap(request.toolTurns.last?.results.first)
            XCTAssertFalse(receipt.isError, "每次首次合法窄读都有成功回执")
        }
        let rejection = try XCTUnwrap(pageRequests.last?.toolTurns.last?.results.first)
        XCTAssertTrue(rejection.isError)
        XCTAssertTrue(rejection.text.contains("why") && rejection.text.contains("不收"), "保留字段拒收的真实原因，不退化成泛泛无正文")
        XCTAssertEqual(contents(outline.id).count, 1)
        XCTAssertNotNil(CatalogSeed.completion(wiki: wiki))
    }

    func testRepeatedSuccessfulReadStillStopsAfterThreeRoundsWithoutProgress() async throws {
        let model = SeedModel()
        try aqingFixture(model)
        _ = await CatalogSession(job: job(model)).seed()
        let outline = try XCTUnwrap(seedOutline())
        let target = item(outline, "阿青")
        let path = try XCTUnwrap(target.change.direction?.sources?.first)
        try await approve(outline.id, [target.id])
        var round = 0
        model.pageEvent = { _, _ in
            round += 1
            return .toolCalls([ToolCallBlock(id: "repeated-read-\(round)", name: "read",
                argumentsJSON: SeedModel.json(["path": path]), truncated: false)])
        }
        let before = model.backend.requests.count
        let report = await CatalogSession(job: job(model)).resumeSeed(outline.id)
        XCTAssertEqual(model.backend.requests.count - before, 4, "首次新来源算进展，随后同份成功读取三轮仍须停止")
        XCTAssertFalse(report.failures.isEmpty)
        XCTAssertEqual(tasks.load(outline.id)?.page?.stalls, 3)
        XCTAssertEqual(tasks.load(outline.id)?.state, .stopped)
        XCTAssertTrue(contents(outline.id).isEmpty)
        XCTAssertNil(CatalogSeed.completion(wiki: wiki))
        for request in model.backend.requests.dropFirst(before + 1) {
            let receipts = request.toolTurns.flatMap(\.results)
            XCTAssertFalse(receipts.isEmpty)
            XCTAssertTrue(receipts.allSatisfy { !$0.isError }, "停下原因是重复无进展，不是读取失败")
        }
    }
    func testPersonaSegmentsRespectParagraphBoundariesAndKeepOversizedBlocks() {
        let blocks = ["# 星砚\n住在灯塔", "星砚（阿砚）陪岚舟写生", "## 林栖\n修理木船", String(repeating: "长", count: 25)]
        let text = blocks[0] + "\n\n" + blocks[1] + "\n" + blocks[2] + "\n\n" + blocks[3]
        let result = CatalogSeedMaterials.personaItems(path: "prompt/人设", name: "人设", text: text, limit: 24)
        XCTAssertEqual(result.map(\.text), [blocks[0] + "\n\n" + blocks[1], blocks[2], blocks[3]])
        XCTAssertEqual(result.map(\.path), ["prompt/人设#01", "prompt/人设#02", "prompt/人设#03"])
        XCTAssertEqual(result.map(\.layer), ["Prompt", "Prompt", "Prompt"])
        XCTAssertEqual(result.map(\.name), ["人设 · 星砚", "人设 · 林栖", "人设 · " + String(repeating: "长", count: 12)])
        XCTAssertEqual(result.map(\.version), result.map { WikiStore.version(of: Data($0.text.utf8)) })
        XCTAssertEqual(result.map { $0.sourceContext?.headingPath }, [["星砚"], ["星砚", "林栖"], ["星砚", "林栖"]])
        XCTAssertEqual(CatalogSeedMaterials.personaItems(path: "prompt/人设", name: "人设", text: text, limit: 24), result)
        XCTAssertEqual(CatalogSeedMaterials.personaItems(path: "prompt/人设", name: "人设", text: text.replacingOccurrences(of: "\n", with: "\r\n"), limit: 24), result)
        XCTAssertTrue(CatalogSeedMaterials.personaItems(path: "prompt/空", name: "空", text: " \n\n\t").isEmpty)
        let disabled = CatalogSeedMaterials.personaItems(path: "prompt/旧", name: "旧设定", text: "林栖守着旧码头", isEnabled: false)
        XCTAssertEqual(disabled.first?.text, "林栖守着旧码头")
        XCTAssertEqual(disabled.map(\.name), ["旧设定（已关闭） · 林栖守着旧码头"])
        XCTAssertEqual(disabled.first?.sourceContext, .init(slotPath: "prompt/旧", slotName: "旧设定", headingPath: []))
    }

    func testPersonaHeadingStackNeverMergesSectionsOrInventsSkippedParents() throws {
        let text = """
        岚舟在槽头的正文

        # 岚舟 / 边界？ ###
        现实章节
        ### 星砚（*旅人*）！
        跳级章节

        无标题延续
        ## 林栖
        相邻同名第一节
        ## 林栖
        相邻同名第二节
        # 云桥城
        新的根节
        """
        let items = CatalogSeedMaterials.personaItems(path: "prompt/人设", name: "人设", text: text)
        let expected: [(String, [String])] = [
            ("岚舟在槽头的正文", []),
            ("现实章节", ["岚舟 / 边界？"]),
            ("跳级章节", ["岚舟 / 边界？", "星砚（*旅人*）！"]),
            ("无标题延续", ["岚舟 / 边界？", "星砚（*旅人*）！"]),
            ("相邻同名第一节", ["岚舟 / 边界？", "林栖"]),
            ("相邻同名第二节", ["岚舟 / 边界？", "林栖"]),
            ("新的根节", ["云桥城"])
        ]
        for (body, headings) in expected {
            let item = try XCTUnwrap(items.first { $0.text.contains(body) })
            XCTAssertEqual(item.sourceContext, .init(slotPath: "prompt/人设", slotName: "人设", headingPath: headings))
        }
        XCTAssertTrue(items.contains { $0.text.contains("跳级章节") && $0.text.contains("无标题延续") }, "同节小块仍合并")
        XCTAssertFalse(items.contains { $0.text.contains("相邻同名第一节") && $0.text.contains("相邻同名第二节") })
        XCTAssertFalse(items.contains { $0.text.contains("现实章节") && $0.text.contains("跳级章节") })
    }

    func testPersonaIndentedCodeAndLiteralTrailingHashKeepHeadingContext() {
        let indented = CatalogSeedMaterials.personaItems(path: "prompt/人设", name: "人设", text: "# 岚舟\n    # 代码不是标题\n正文")
        XCTAssertEqual(indented.map { $0.sourceContext?.headingPath }, [["岚舟"]])
        let trailingHash = CatalogSeedMaterials.personaItems(path: "prompt/人设", name: "人设", text: "# C#\n正文")
        XCTAssertEqual(trailingHash.first?.sourceContext?.headingPath, ["C#"])
    }

    func testPersonaFencesKeepFakeHeadingsAndBlankLinesInsideCurrentSection() throws {
        for mark in ["```", "~~~"] {
            let text = "# 岚舟\n\(mark)markdown\n## 伪标题\n\n\(mark.prefix(2))\n# 仍在围栏里\n\(mark)\n\n延续正文\n## 星砚\n真正子节"
            let items = CatalogSeedMaterials.personaItems(path: "prompt/人设", name: "人设", text: text, limit: 28)
            let fenced = try XCTUnwrap(items.first { $0.text.contains("## 伪标题") })
            XCTAssertTrue(fenced.text.contains("# 仍在围栏里"))
            XCTAssertTrue(fenced.text.contains("\n\n"))
            XCTAssertEqual(fenced.sourceContext?.headingPath, ["岚舟"])
            XCTAssertEqual(items.first { $0.text.contains("延续正文") }?.sourceContext?.headingPath, ["岚舟"])
            XCTAssertEqual(items.first { $0.text.contains("真正子节") }?.sourceContext?.headingPath, ["岚舟", "星砚"])
        }
        let unclosed = CatalogSeedMaterials.personaItems(path: "prompt/人设", name: "人设", text: "````\n# 岚舟\n```\n## 星砚")
        XCTAssertEqual(unclosed.first?.sourceContext?.headingPath, [])
        XCTAssertTrue(unclosed.first?.text.contains("## 星砚") == true)
        let tildeUnclosed = CatalogSeedMaterials.personaItems(path: "prompt/人设", name: "人设", text: "~~~~\n# 岚舟\n~~~\n## 星砚")
        XCTAssertEqual(tildeUnclosed.first?.sourceContext?.headingPath, [])
        XCTAssertTrue(tildeUnclosed.first?.text.contains("## 星砚") == true)
    }

    func testReusedLegacyCardsWithoutL2AreNotBackfilled() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        _ = await CatalogSession(job: fixture.job).seed()
        let task = try XCTUnwrap(tasks.all().first)
        let cards = SeedNoteStore(wiki: wiki)
        for material in task.materials where material.layer != "wiki" {
            let txt = cards.folder.appendingPathComponent(SeedNoteStore.key(path: material.path, version: material.version) + ".txt")
            try FileManager.default.removeItem(at: txt)
        }
        _ = await CatalogSession(job: fixture.job).abandonSeed(task.id)
        let result = await CatalogSession(job: fixture.job).seed()
        XCTAssertEqual(result.failures, [])
        for material in task.materials where material.layer != "wiki" {
            XCTAssertEqual(cards.load(path: material.path, version: material.version)?.version, material.version)
            XCTAssertNil(cards.original(path: material.path, version: material.version))
        }
    }

    func testChangedSnapshotBytesCannotPublishOriginalOrCard() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        let taskStore = tasks
        var corrupted = false
        model.notesReply = { [unowned model] _, kind, opening in
            guard kind == "cards", !corrupted, let task = taskStore.all().first else { return nil }
            let reply = model.cardsReply(opening, task: task)
            corrupted = true
            do {
                let snapshot = try taskStore.loadSnapshot(task.id)
                for entry in snapshot.entries {
                    try Data("被替换的正文".utf8).write(to: snapshot.folder.appendingPathComponent(entry.file), options: .atomic)
                }
            } catch { XCTFail("\(error)") }
            return .finished(reply)
        }
        _ = await CatalogSession(job: fixture.job).seed()
        let task = try XCTUnwrap(tasks.all().first)
        XCTAssertEqual(task.carded ?? [:], [:])
        let cards = SeedNoteStore(wiki: wiki)
        for material in task.materials where material.layer != "wiki" {
            XCTAssertNil(cards.load(path: material.path, version: material.version))
            XCTAssertNil(cards.original(path: material.path, version: material.version))
        }
        XCTAssertTrue(task.notes?.batches.contains { !$0.ok && $0.reason?.contains("冻结原料缺失或版本与卡不符") == true } == true)
    }

    func testNewL2SurvivesTaskRemovalAndKeepsExactPromptSegment() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        var j = fixture.job
        j.floorBase = .init(sections: [.init(path: slotBasePath, name: "写生计划",
            text: "# 星砚\n云桥城写生计划原料\n\n# 岚舟\n另一段不属于星砚", isEnabled: true)])
        model.cards[slotBasePath + "#02"] = card("岚舟的写生计划", "岚舟在云桥城写生")
        let result = await CatalogSession(job: j).seed()
        XCTAssertEqual(result.failures, [])
        let task = try XCTUnwrap(tasks.all().first)
        let snapshot = try tasks.loadSnapshot(task.id)
        let materials = try snapshot.items().filter { SeedNoteBatcher.cardable($0, entry: task.entry) }
        tasks.remove(task.id)
        let cards = SeedNoteStore(wiki: wiki)
        for material in materials {
            let original = try XCTUnwrap(cards.original(path: material.path, version: material.version))
            XCTAssertEqual(Data(original.text.utf8), Data(material.text.utf8))
            XCTAssertEqual(original.sourceContext, material.sourceContext)
            XCTAssertEqual(cards.load(path: material.path, version: material.version)?.version, material.version)
        }
        let prompt = try XCTUnwrap(materials.first { $0.path == slotPath })
        XCTAssertEqual(cards.original(path: prompt.path, version: prompt.version)?.text, "# 星砚\n云桥城写生计划原料")
        let second = try XCTUnwrap(materials.first { $0.path == slotBasePath + "#02" })
        XCTAssertEqual(cards.original(path: second.path, version: second.version)?.text, "# 岚舟\n另一段不属于星砚")
    }

    func testL2ConflictFailsOnlyThatCardWithoutPublishingJSON() async throws {
        let model = SeedModel()
        let fixture = try salvageFixture(model)
        let material = try XCTUnwrap(CatalogSeedMaterials.personaItems(path: slotBasePath, name: "写生计划", text: "云桥城写生计划原料").first)
        let cards = SeedNoteStore(wiki: wiki)
        try cards.saveOriginal(path: material.path, version: material.version, text: "冲突的旧原文", sourceContext: material.sourceContext)
        _ = await CatalogSession(job: fixture.job).seed()
        let task = try XCTUnwrap(tasks.all().first)
        XCTAssertNil(task.carded?[material.path])
        XCTAssertNil(cards.load(path: material.path, version: material.version))
        XCTAssertEqual(cards.original(path: material.path, version: material.version)?.text, "冲突的旧原文")
        XCTAssertTrue(task.notes?.batches.contains { !$0.ok && $0.paths.contains(material.path) && $0.reason?.contains("卡没存成") == true } == true)
    }

    func testNewCardsKeepFrozenContextDespiteModelSourceFieldsAndStoreDeclaredDomains() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let domains: [SeedFactDomain] = [.realWorld, .inWorld, .mixed, .unspecified]
        var expected: [String: SeedFactDomain] = [:]
        for (index, path) in model.cards.keys.sorted().enumerated() {
            let domain = domains[index % domains.count]
            expected[path] = domain
            model.cards[path]?["fact_domain"] = domain.rawValue
            model.cards[path]?["source_context"] = ["slotPath": "prompt/伪造", "slotName": "伪造", "headingPath": ["林栖"]]
            model.cards[path]?["slot_path"] = "prompt/伪造"
        }
        let result = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(result.failures, [])
        let task = try XCTUnwrap(tasks.all().first)
        let snapshot = try tasks.loadSnapshot(task.id)
        let cardStore = SeedNoteStore(wiki: wiki)
        for material in try snapshot.items() where SeedNoteBatcher.cardable(material, entry: task.entry) {
            let saved = try XCTUnwrap(cardStore.load(path: material.path, version: material.version))
            XCTAssertEqual(saved.factDomain, expected[material.path])
            XCTAssertEqual(saved.sourceContext, material.sourceContext)
        }
        XCTAssertNotNil(cardStore.load(path: slotPath, version: try XCTUnwrap(task.carded?[slotPath]))?.sourceContext)
        XCTAssertNil(cardStore.load(path: "memory/cc/user_a.md", version: try XCTUnwrap(task.carded?["memory/cc/user_a.md"]))?.sourceContext)
    }

    func testReusedCardsRecordContextIssuesWithoutRewritingCardBytes() async throws {
        let model = SeedModel()
        try standardFixture(model)
        let firstRun = await CatalogSession(job: job(model)).seed()
        XCTAssertEqual(firstRun.failures, [])
        var previous = try XCTUnwrap(seedOutline()).id
        let cardStore = SeedNoteStore(wiki: wiki)
        let frozen = try XCTUnwrap(tasks.load(previous)?.materials.first { $0.path == slotPath })
        XCTAssertEqual(cardStore.load(path: slotPath, version: frozen.version)?.sourceContext, frozen.sourceContext)
        XCTAssertEqual(cardStore.load(path: slotPath, version: frozen.version)?.factDomain, .realWorld)
        let cases: [(SeedNoteCard.ContextIssue, SeedFactDomain?)] = [(.missing, .realWorld), (.conflict, .realWorld), (.missing, nil), (.conflict, nil)]
        for (issue, domain) in cases {
            _ = await CatalogSession(job: job(model)).abandonSeed(previous)
            var reused = try XCTUnwrap(cardStore.load(path: slotPath, version: frozen.version))
            reused.sourceContext = issue == .missing ? nil : .init(slotPath: slotBasePath, slotName: "自建槽", headingPath: ["星砚"])
            reused.factDomain = domain
            try cardStore.save(reused)
            let url = cardStore.url(path: slotPath, version: frozen.version)
            let before = try Data(contentsOf: url)
            let beforeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
            XCTAssertEqual(beforeJSON["factDomain"] as? String, domain?.rawValue)
            let result = await CatalogSession(job: job(model)).seed()
            XCTAssertEqual(result.failures, [])
            let next = try XCTUnwrap(tasks.all().first { $0.id != previous && $0.state == .waiting })
            XCTAssertEqual(next.notes?.sourceContextIssues?[slotPath], issue)
            XCTAssertEqual(next.carded?[slotPath], frozen.version)
            let reusedOutline = try XCTUnwrap(store.load(next.id))
            let reusedDirections = reusedOutline.items.compactMap(\.change.direction)
            XCTAssertEqual(reusedDirections.first { ($0.sources ?? []).contains(slotPath) }?.factDomain, .unspecified)
            XCTAssertFalse(reusedDirections.filter { $0.path.hasPrefix("人/") || $0.path.hasPrefix("{{user}}/") }
                .contains { ($0.sources ?? []).contains(slotPath) })
            XCTAssertEqual(try Data(contentsOf: url), before)
            let afterJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(afterJSON["factDomain"] as? String, domain?.rawValue)
            XCTAssertEqual(cardStore.load(path: slotPath, version: frozen.version)?.factDomain, domain)
            previous = next.id
        }
    }

    func testLegacyFrozenPromptResumeDoesNotResegmentOrBackfillFromLiveFloor() async throws {
        let model = SeedModel()
        try standardFixture(model)
        model.fail = { n in n == 1 ? "离线" : nil }
        _ = await CatalogSession(job: job(model)).seed()
        var frozen = try XCTUnwrap(tasks.all().first)
        let snapshot = try tasks.loadSnapshot(frozen.id)
        var entries = snapshot.entries
        for i in entries.indices { entries[i].sourceContext = nil }
        for i in frozen.materials.indices { frozen.materials[i].sourceContext = nil }
        let manifest = snapshot.folder.appendingPathComponent(CatalogSeedMaterials.manifestFileName)
        try JSONEncoder().encode(entries).write(to: manifest)
        try tasks.save(frozen)
        let before = try Data(contentsOf: manifest)
        let original = try XCTUnwrap(snapshot.text(slotPath))
        model.fail = { _ in nil }
        var changed = job(model)
        changed.floorBase = .init(sections: [.init(path: slotBasePath, name: "人设", text: "# 云桥城\n## 星砚\n完全不同的现状", isEnabled: true)])
        let result = await CatalogSession(job: changed).resumeSeed(frozen.id)
        XCTAssertEqual(result.failures, [])
        let resumed = try XCTUnwrap(tasks.load(frozen.id))
        XCTAssertEqual(resumed.materials, frozen.materials)
        XCTAssertEqual(resumed.read, frozen.read)
        XCTAssertEqual(try tasks.loadSnapshot(frozen.id).text(slotPath), original)
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        let saved = try XCTUnwrap(SeedNoteStore(wiki: wiki).load(path: slotPath, version: try XCTUnwrap(frozen.read[slotPath])))
        XCTAssertNil(saved.sourceContext)
        XCTAssertEqual(resumed.notes?.sourceContextIssues?[slotPath], .missing)
    }

    func testPersonaSingleSegmentAliasReachesApprovedPageWithSegmentProvenance() async throws {
        let model = SeedModel()
        model.cards[slotPath] = [
            "title": "星砚是写生搭档", "gist": "星砚（阿砚）是岚舟的写生搭档",
            "mentions": [["name": "星砚", "group": "人", "aliases": ["阿砚", " 阿砚 "]]],
            "about_user": false, "group": "人"
        ]
        model.pages["人/星砚"] = [[
            "type": "new_page", "path": "人/星砚", "kind": "人", "title": "星砚",
            "triggers": ["星砚"], "hook": "当岚舟提到写生搭档时先看这页",
            "now": "星砚是岚舟的写生搭档（时间未注明），详见人设。"
        ]]
        var j = job(model)
        j.floorBase = CatalogFloorBase(sections: [.init(path: slotBasePath, name: "人设", text: "星砚（阿砚）是岚舟的写生搭档。", isEnabled: true)])
        let seeded = await CatalogSession(job: j).seed(entry: .persona)
        XCTAssertEqual(seeded.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        let direction = try XCTUnwrap(outline.items.first?.change.direction)
        XCTAssertEqual(outline.items.count, 1)
        XCTAssertEqual(direction.path, "人/星砚")
        XCTAssertEqual(direction.sources, [slotPath])
        XCTAssertEqual(direction.aliases, ["阿砚"])
        let task = try XCTUnwrap(tasks.load(outline.id))
        XCTAssertEqual(Set(task.read.keys), Set([slotPath]))
        XCTAssertEqual(task.carded, task.read)
        try await approve(outline.id)
        let written = await CatalogSession(job: j).resumeSeed(outline.id)
        XCTAssertEqual(written.failures, [])
        let proposal = try XCTUnwrap(contents(outline.id).first)
        guard case .newPage(let page) = try XCTUnwrap(proposal.items.first).change else { return XCTFail("缺新页") }
        XCTAssertEqual(page.triggers, ["星砚", "阿砚"])
        XCTAssertEqual(page.records, ["未注明 · 星砚是写生搭档（\(slotPath)）"])
        try await approve(proposal.id)
        XCTAssertEqual(wiki.read("人/星砚")?.triggers, ["星砚", "阿砚"])
    }

    func testUserNameMentionAliasDoesNotReachAlignmentOrApprovedTriggers() async throws {
        let model = SeedModel()
        model.cards[slotPath] = [
            "title": "星砚整理纸灯", "gist": "星砚负责整理纸灯材料",
            "mentions": [["name": "星砚", "group": "人", "aliases": ["岚舟"]]],
            "about_user": false, "group": "人"
        ]
        model.pages["人/星砚"] = [[
            "type": "new_page", "path": "人/星砚", "kind": "人", "title": "星砚",
            "triggers": ["星砚"], "now": "星砚负责整理纸灯材料（时间未注明），详见人设。"
        ]]
        var j = job(model)
        j.names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        j.floorBase = CatalogFloorBase(sections: [.init(path: slotBasePath, name: "人设", text: "星砚负责整理纸灯材料。", isEnabled: true)])
        let seeded = await CatalogSession(job: j).seed(entry: .persona)
        XCTAssertEqual(seeded.failures, [])
        let outline = try XCTUnwrap(seedOutline())
        let alignment = try XCTUnwrap(tasks.loadNotes(SeedNoteAlignment.self, name: CatalogSeedTaskStore.alignedFileName, id: outline.id))
        XCTAssertEqual(alignment.groups.map(\.display), ["星砚"])
        XCTAssertEqual(alignment.groups.first?.aliases, [])
        XCTAssertTrue(outline.items.allSatisfy { $0.change.direction?.aliases.isEmpty == true })
        let request = try XCTUnwrap(model.backend.requests.first { SeedModel.kind($0) == "align" })
        let input = try XCTUnwrap(request.history.first?.content)
        let anchors = try XCTUnwrap(input.range(of: "\n\n【锚】"))
        XCTAssertFalse(input[..<anchors.lowerBound].contains("岚舟"), "本人锚可保留，但本人名不进入实体对齐名单")
        try await approve(outline.id)
        let written = await CatalogSession(job: j).resumeSeed(outline.id)
        XCTAssertEqual(written.failures, [])
        let proposal = try XCTUnwrap(contents(outline.id).first)
        guard case .newPage(let page) = try XCTUnwrap(proposal.items.first).change else { return XCTFail("缺新页") }
        XCTAssertEqual(page.triggers, ["星砚"])
        try await approve(proposal.id)
        XCTAssertEqual(wiki.pagePaths(), ["人/星砚"])
        for path in wiki.pagePaths() {
            let approved = try XCTUnwrap(wiki.read(path))
            XCTAssertFalse(approved.triggers.contains { CatalogSeedNotes.isUser($0, names: j.names) })
        }
    }

    func testEntityAliasesAreKeptWhenUpdatingExistingPageWithOrWithoutRetags() async throws {
        for retagCount in 0...2 {
            try? FileManager.default.removeItem(at: root)
            let model = SeedModel()
            try wiki.save(WikiPage(path: "人/星砚", kind: .person, triggers: ["星砚", "砚老师"], hook: "当岚舟说写生时先看", title: "星砚", now: "写生搭档（详见人设）", factDomain: .realWorld))
            try cc("alias.md", type: "user", title: "阿砚带来新颜料", body: "阿砚带来一盒新颜料。")
            model.cards["memory/cc/alias.md"] = [
                "title": "阿砚带来新颜料", "gist": "阿砚带来新颜料", "mentions": [["name": "阿砚", "group": "人"]],
                "about_user": false, "group": "人"
            ]
            model.merge = [["into": "wiki:人/星砚", "names": ["阿砚"]]]
            model.pages["人/星砚"] = [
                ["type": "rewrite_now", "path": "人/星砚", "now": "星砚带来新颜料（时间未注明）。"]
            ] + (0..<retagCount).map { _ in ["type": "retag", "path": "人/星砚", "triggers": ["星砚"]] as [String: Any] }
            var j = job(model)
            j.floorBase = CatalogFloorBase(sections: [])
            let seeded = await CatalogSession(job: j).seed()
            XCTAssertEqual(seeded.failures, [])
            let outline = try XCTUnwrap(seedOutline())
            XCTAssertEqual(outline.items.first?.change.direction?.action, .update)
            try await approve(outline.id)
            let written = await CatalogSession(job: j).resumeSeed(outline.id)
            XCTAssertEqual(written.failures, [])
            let proposal = try XCTUnwrap(contents(outline.id).first)
            let tags = proposal.items.compactMap { item -> [String]? in
                guard case .retag(_, _, _, _, let triggers) = item.change else { return nil }
                return triggers
            }
            XCTAssertEqual(tags.count, max(1, retagCount))
            for triggers in tags { XCTAssertEqual(triggers, ["星砚", "砚老师", "阿砚"]) }
            try await approve(proposal.id)
            XCTAssertEqual(wiki.read("人/星砚")?.triggers, ["星砚", "砚老师", "阿砚"])
        }
    }

    private func factDomainFixture() throws -> CatalogSeedTask {
        let context = SeedSourceContext(slotPath: "prompt/虚构槽", slotName: "虚构槽「航线」",
                                        headingPath: ["云桥城", "码头 / 夜航"])
        let rows: [(String, SeedFactDomain?, SeedSourceContext?)] = [
            ("real", .realWorld, nil), ("setting", .inWorld, context), ("mixed", .mixed, context),
            ("unknown", .unspecified, nil), ("legacy", nil, nil), ("missing", nil, context),
            ("stale", .realWorld, context), ("conflict", .inWorld, context),
        ]
        let materials = CatalogSeedMaterials(items: rows.map { name, _, sourceContext in
            let text = "虚构原文：云桥城的\(name)航线。"
            return .init(path: "memory/cc/\(name).md", name: name, layer: sourceContext == nil ? "CC" : "Prompt",
                         text: text, version: WikiStore.version(of: Data(text.utf8)), sourceContext: sourceContext)
        })
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .cc, modelName: "fake",
                                   createdAt: Date(), run: .init(path: ".runs/test.md"))
        _ = try tasks.writeSnapshot(materials, id: task.id)
        task.materials = materials.items.map { .init(path: $0.path, name: $0.name, layer: $0.layer,
                                                   version: $0.version, sourceContext: $0.sourceContext) }
        task.read = Dictionary(uniqueKeysWithValues: materials.items.map { ($0.path, $0.version) })
        task.carded = [:]
        for (index, row) in rows.enumerated() where row.0 != "missing" {
            let material = materials.items[index]
            let card = SeedNoteCard(path: material.path, version: material.version, name: row.0, layer: material.layer,
                title: "云桥城\(row.0)", gist: "虚构航线的要点", mentions: [], aboutUser: false, group: "主题",
                when: ["2026-10-09"], model: "fake", madeAt: task.createdAt, run: task.run,
                sourceContext: row.0 == "stale" ? nil : row.2, factDomain: row.1)
            var saved = card
            if row.0 == "conflict" { saved.sourceContext?.headingPath = ["别的虚构章节"] }
            try SeedNoteStore(wiki: wiki).save(saved)
            task.carded?[material.path] = material.version
        }
        try tasks.save(task)
        return task
    }

    func testPageSourceJSONKeepsNestedContextDomainsAndMissingCardMetadata() throws {
        let task = try factDomainFixture()
        let prefix = "memory/cc/"
        let direction = WikiProposal.Direction(path: "主题/云桥城", title: "云桥城", kind: .topic,
            action: .newPage, reason: "虚构夹具", mode: .seed,
            sources: ["real", "setting", "missing", "unknown", "legacy", "stale", "conflict"].map { prefix + $0 + ".md" },
            candidates: [.init(path: prefix + "mixed.md", hits: ["云桥城"], factDomain: .realWorld)], factDomain: .inWorld)
        let item = WikiProposal.Item(state: .approved, change: .direction(direction))
        let outline = WikiProposal(origin: .seed, createdAt: task.createdAt, items: [item])
        let opening = try CatalogAgent.pageOpening(item, outline: outline, task: task, wiki: wiki).get().text
        let objects = try opening.components(separatedBy: "\n").compactMap { line -> NSDictionary? in
            guard let start = line.firstIndex(of: "{"), let end = line.lastIndex(of: "}") else { return nil }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line[start...end].utf8)) as? NSDictionary)
        }
        for (name, domain, layer) in [("real", "realWorld", "CC"), ("setting", "inWorld", "Prompt"),
                                       ("missing", "unspecified", "Prompt"), ("mixed", "realWorld", "Prompt"),
                                       ("unknown", "unspecified", "CC"), ("legacy", "unspecified", "CC"),
                                       ("stale", "unspecified", "Prompt"), ("conflict", "unspecified", "Prompt")] {
            let row = try XCTUnwrap(objects.first { ($0["path"] as? String) == prefix + name + ".md" })
            XCTAssertEqual(row["layer"] as? String, layer)
            XCTAssertEqual(row["fact_domain"] as? String, domain)
            if layer == "CC" {
                XCTAssertTrue(row["source_context"] is NSNull)
            } else {
                let context = try XCTUnwrap(row["source_context"] as? NSDictionary)
                XCTAssertEqual(context["slotName"] as? String, "虚构槽「航线」")
                XCTAssertEqual(context["headingPath"] as? [String], ["云桥城", "码头 / 夜航"])
            }
        }
        let target = try XCTUnwrap(objects.last { ($0["path"] as? String) == direction.path })
        XCTAssertEqual(target["fact_domain"] as? String, "inWorld")
        XCTAssertTrue(opening.contains("设定页的「现在」每句保留「设定中……」归因"))
        XCTAssertTrue(opening.contains("虚构原文：云桥城的missing航线。"))
        XCTAssertFalse(opening.contains("虚构原文：云桥城的mixed航线。"), "候选仍不给全文")
    }

    func testGeneratedRecordDomainsSurviveParsingAndPathDeduplication() throws {
        let task = try factDomainFixture()
        var direction = WikiProposal.Direction(path: "主题/云桥城", title: "云桥城", kind: .topic,
            action: .newPage, reason: "虚构夹具", mode: .seed, sources: task.materials.map(\.path), factDomain: .inWorld)
        let generated = CatalogSeedTools.generatedRecords(direction: direction, task: task, wiki: wiki)
        for (name, marker) in [("real", ""), ("setting", "设定 · "), ("mixed", "待判 · "),
                                ("unknown", "待判 · "), ("legacy", "待判 · "), ("missing", "待判 · "),
                                ("stale", "待判 · "), ("conflict", "待判 · ")] {
            let path = "memory/cc/\(name).md"
            let line = try XCTUnwrap(generated.first { $0.path == path }?.line)
            let title = name == "missing" ? name : "云桥城" + name
            let day = name == "missing" ? "未注明" : "2026-10-09"
            XCTAssertEqual(line, "\(day) · \(marker)\(title)（\(path)）")
            XCTAssertEqual(CatalogSources.split(line).labels, [path])
            XCTAssertTrue(CatalogChecks.recordText(line).contains(marker + title))
        }
        let parsed = CatalogItems.Parsed(items: [.init(change: .newPage(page: WikiPage(path: direction.path,
            title: "写手标题", now: "设定中云桥城有夜航。", factDomain: .realWorld)))], dropped: 0)
        let output = CatalogSeedTools.page(parsed, direction: direction, task: task, wiki: wiki)
        guard case .newPage(let page) = try XCTUnwrap(output.items.first).change else { return XCTFail() }
        XCTAssertEqual(page.factDomain, .inWorld, "页域取目录，不信写手自报")
        XCTAssertEqual(WikiPage.parse(page.markdown, path: page.path).records, generated.map(\.line))

        try wiki.save(page)
        let materials = CatalogSeedMaterials(items: task.materials.map { m in
            .init(path: m.path, name: m.name, layer: m.layer, text: task.readText(m.path, wiki: wiki)!,
                  version: m.version, sourceContext: m.sourceContext)
        } + [.init(path: CatalogSeedMaterials.wikiPath(page.path), name: page.title, layer: "wiki",
                   text: page.markdown, version: try XCTUnwrap(wiki.version(of: page.path)))])
        var update = task
        update.id = UUID().uuidString
        _ = try tasks.writeSnapshot(materials, id: update.id)
        update.read[CatalogSeedMaterials.wikiPath(page.path)] = wiki.version(of: page.path)
        direction.action = .update
        let revised = CatalogSeedTools.page(.init(items: [.init(change: .rewriteNow(path: page.path, old: page.now,
            new: "设定中云桥城的夜航延至月末。"))], dropped: 0), direction: direction, task: update, wiki: wiki)
        XCTAssertFalse(revised.items.contains { if case .appendRecords = $0.change { return true }; return false },
                       "设定 / 待判中间标记不改变按 path 去重")
        XCTAssertEqual(wiki.read(page.path)?.factDomain, .inWorld)
    }

    func testAuditChecksOnlyNewSourcesAgainstDirectionDomain() async throws {
        let task = try factDomainFixture()
        let real = WikiProposal.Direction(path: "{{user}}/航线", title: "航线", kind: .user,
            action: .newPage, reason: "虚构夹具", mode: .seed, sources: ["memory/cc/real.md"], factDomain: .realWorld)
        let setting = WikiProposal.Direction(path: "主题/航线（设定）", title: "航线（设定）", kind: .topic,
            action: .newPage, reason: "虚构夹具", mode: .seed, sources: ["memory/cc/missing.md"], factDomain: .inWorld)
        let outline = WikiProposal(id: task.id, origin: .seed, createdAt: task.createdAt,
            items: [.init(change: .direction(real)), .init(change: .direction(setting))], seedTask: task.id)
        try store.save(outline)
        for original in outline.items {
            var edited = try XCTUnwrap(original.change.direction)
            edited.sources?.append("memory/cc/setting.md")
            if edited.factDomain == .realWorld {
                do {
                    try await CatalogSeedDrafts.saveChange(outline.id, itemId: original.id, change: .direction(edited),
                        baseline: original.change, wiki: wiki)
                    XCTFail("设定卡不能加入现实页")
                } catch let error as CatalogSeedDrafts.EditError {
                    XCTAssertEqual(error, .invalid("第 2 份原料「云桥城setting」是设定卡，不能进现实页"))
                }
                XCTAssertEqual(store.load(outline.id)?.items.first?.change, original.change)
            } else {
                let saved = try await CatalogSeedDrafts.saveChange(outline.id, itemId: original.id, change: .direction(edited),
                    baseline: original.change, wiki: wiki)
                let current = try XCTUnwrap(saved.items.first { $0.id == original.id })
                XCTAssertEqual(current.change.direction?.sources, edited.sources, "旧的缺卡成员不重查")
                var card = try XCTUnwrap(SeedNoteStore(wiki: wiki).load(path: "memory/cc/setting.md",
                    version: try XCTUnwrap(task.read["memory/cc/setting.md"])))
                card.factDomain = .realWorld
                try SeedNoteStore(wiki: wiki).save(card)
                edited.hook = "提到夜航时看"
                let revised = try await CatalogSeedDrafts.saveChange(outline.id, itemId: original.id, change: .direction(edited),
                    baseline: current.change, wiki: wiki)
                XCTAssertEqual(revised.items.first { $0.id == original.id }?.change.direction?.hook, edited.hook,
                    "只改钩子不能重查已有成员的域")
            }
        }
    }

    func testNewSourceDomainGateUsesCurrentCardVersionAndFrozenContext() throws {
        var task = try factDomainFixture()
        task.carded?["memory/cc/real.md"] = "旧卡版本"
        let domains: [SeedFactDomain?] = [.realWorld, .inWorld, .mixed, .unspecified, nil]
        for domain in domains {
            let original = WikiProposal.Direction(path: "主题/航线", title: "航线", kind: .topic,
                action: .newPage, reason: "虚构夹具", mode: .seed, sources: ["memory/cc/legacy.md"], factDomain: domain)
            for name in ["real", "setting", "mixed", "unknown", "missing", "stale", "conflict"] {
                var edited = original
                edited.sources?.append("memory/cc/\(name).md")
                let accepted = domain == nil || (domain == .inWorld ? name == "setting"
                    : domain != .realWorld && name != "setting")
                if accepted {
                    let validated = try CatalogSeedDrafts.validate(.direction(edited), original: .init(change: .direction(original)),
                        task: task, wiki: wiki)
                    XCTAssertEqual(validated.direction?.sources, edited.sources)
                } else {
                    XCTAssertThrowsError(try CatalogSeedDrafts.validate(.direction(edited), original: .init(change: .direction(original)),
                        task: task, wiki: wiki), "\(domain!.rawValue) 不收 \(name)")
                }
            }
        }
    }

    func testSeedDraftEditingCannotChangeDirectionOrPageDomain() throws {
        let task = try factDomainFixture()
        let original = WikiProposal.Direction(path: "主题/云桥城", title: "云桥城", kind: .topic,
            action: .newPage, reason: "虚构夹具", mode: .seed, sources: ["memory/cc/setting.md"], factDomain: .inWorld)
        var changed = original
        changed.factDomain = .realWorld
        let direction = try CatalogSeedDrafts.validate(.direction(changed), original: .init(change: .direction(original)),
                                                       task: task, wiki: wiki)
        XCTAssertEqual(direction.direction?.factDomain, .inWorld)
        changed.path = "{{user}}/航线"
        XCTAssertThrowsError(try CatalogSeedDrafts.validate(.direction(changed), original: .init(change: .direction(original)),
                                                            task: task, wiki: wiki), "不能借改域绕过目录路径校验")
        let page = WikiPage(path: original.path, title: original.title, now: "设定中有夜航。",
                           records: ["2026-10-09 · 设定 · 夜航（memory/cc/setting.md）"], factDomain: .inWorld)
        let item = WikiProposal.Item(change: .newPage(page: page))
        for domain in [SeedFactDomain.realWorld, .mixed, .unspecified] {
            var edited = page
            edited.factDomain = domain
            edited.now = "设定中夜航延至月末。"
            guard case .newPage(let validated) = try CatalogSeedDrafts.validate(.newPage(page: edited), original: item,
                task: task, wiki: wiki) else { return XCTFail() }
            XCTAssertEqual(validated.factDomain, .inWorld)
            guard case .newPage(let parsed) = try CatalogSeedDrafts.parsePage(edited.markdown, item: item,
                task: task, wiki: wiki) else { return XCTFail() }
            XCTAssertEqual(parsed.factDomain, .inWorld)
            XCTAssertEqual(parsed.now, edited.now)
        }
        let withoutDomain = page.markdown.replacingOccurrences(of: "事实域: inWorld\n", with: "")
        guard case .newPage(let parsed) = try CatalogSeedDrafts.parsePage(withoutDomain, item: item,
            task: task, wiki: wiki) else { return XCTFail() }
        XCTAssertEqual(parsed.factDomain, .inWorld, "文本漏字段也保留原提案域")
    }

    func testEditedDirectionRejectsLiveTargetOutsideTaskSnapshotAndRecomputesAction() throws {
        let source = "memory/cc/虚构航线.md"
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .cc,
            modelName: "fictional", createdAt: Date(), run: .init(path: ".runs/fictional.md"))
        task.read = [source: "frozen-source"]
        let direction = WikiProposal.Direction(path: "主题/虚构新页", title: "虚构航线", kind: .topic,
            action: .newPage, reason: "虚构原料", mode: .seed, sources: [source])
        let item = WikiProposal.Item(change: .direction(direction))
        let target = "主题/虚构已存在页"
        try wiki.save(WikiPage(path: target, kind: .topic, title: "虚构已存在页"))
        var edited = direction
        edited.path = target
        XCTAssertThrowsError(try CatalogSeedDrafts.validate(.direction(edited), original: item, task: task, wiki: wiki)) { error in
            XCTAssertEqual(error.localizedDescription, "这页已存在但不在本次任务快照里，不能现场读活页")
        }
        task.read[CatalogSeedMaterials.wikiPath(target)] = wiki.version(of: target)
        let update = try CatalogSeedDrafts.validate(.direction(edited), original: item, task: task, wiki: wiki)
        XCTAssertEqual(update.direction?.action, .update)
        edited.path = "主题/虚构另一个新页"
        edited.action = .update
        let new = try CatalogSeedDrafts.validate(.direction(edited), original: item, task: task, wiki: wiki)
        XCTAssertEqual(new.direction?.action, .newPage)
    }

    func testEditedSeedPageAndAppendRequireAtLeastOneRecordButAllowManualRecords() throws {
        let path = "主题/虚构手写页"
        let page = WikiPage(path: path, kind: .topic, title: "虚构手写页", records: ["虚构旧记录（memory/cc/虚构航线.md）"])
        let item = WikiProposal.Item(change: .newPage(page: page))
        var empty = page
        empty.records = []
        XCTAssertThrowsError(try CatalogSeedDrafts.validate(.newPage(page: empty), original: item, task: nil, wiki: wiki))
        empty.records = ["全新虚构手写事实"]
        let manual = try CatalogSeedDrafts.validate(.newPage(page: empty), original: item, task: nil, wiki: wiki)
        guard case .newPage(let validated) = manual else { return XCTFail() }
        XCTAssertEqual(validated.records, ["全新虚构手写事实（出处：用户编辑）"])
        let version = try wiki.save(page)
        let append = WikiProposal.Item(change: .appendRecords(path: path, lines: page.records), baseVersion: version)
        XCTAssertThrowsError(try CatalogSeedDrafts.validate(.appendRecords(path: path, lines: []), original: append, task: nil, wiki: wiki))
        XCTAssertEqual(try CatalogSeedDrafts.validate(.appendRecords(path: path, lines: ["全新虚构手写事实"]), original: append, task: nil, wiki: wiki),
            .appendRecords(path: path, lines: ["全新虚构手写事实（出处：用户编辑）"]))
    }
}
