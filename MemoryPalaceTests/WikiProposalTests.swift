import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// C3 整理提案（plan-memory-c3-catalog 2.3 / 第五节）：存取、逐条 / 整批批、驳回、页已变、同页连续条目、分组调整、碎片标记、清理
@MainActor
final class WikiProposalTests: XCTestCase {

    private let pid = "xctest-wiki-proposal"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!
    private var wiki: WikiStore!
    private var store: WikiProposalStore!
    private var context: ModelContext!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-proposal-\(UUID().uuidString)", isDirectory: true)
        wiki = WikiStore(root: root)
        store = WikiProposalStore(wiki: wiki)
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    private func fragment(_ content: String) -> Memory {
        let m = Memory(content: content, category: "fact", profileId: pid)
        m.occurredDay = "2026-10-12"
        m.importance = 3
        context.insert(m)
        return m
    }

    private func fresh(_ id: UUID) throws -> Memory? {
        let other = ModelContext(context.container)
        return try other.fetch(FetchDescriptor<Memory>(predicate: #Predicate { $0.id == id })).first
    }

    private func proposal(_ items: [WikiProposal.Item], created: Date? = nil) throws -> WikiProposal {
        let p = WikiProposal(origin: .scheduled, createdAt: created ?? t0, items: items)
        try store.save(p)
        return p
    }

    private let xiaohui = WikiPage(path: "人/小慧", kind: .person, triggers: ["小慧"], hook: "她提到小慧时",
                                   title: "小慧", now: "室友（自 2026-09 起）", records: ["2026-10-01 认识"])

    // MARK: - 存取

    func testCodableRoundTripAndList() throws {
        let item = WikiProposal.Item(change: .rewriteNow(path: "人/小慧", old: "旧", new: "新"), judgment: .conflict,
                                     fragmentIds: [UUID()], cites: [.init(layer: "A2", day: "2026-10-12", windowId: "w1", segment: 3, messageFrom: 4, messageTo: 9)],
                                     baseVersion: "abc")
        var p = try proposal([item, .init(change: .regroup(layer: "主题", groups: [.init(path: "人", hook: "h")],
                                                            moves: [.init(from: "主题/a", to: "人/a")]), baseVersion: nil)])
        p.title = "电影"
        p.incomplete = true
        p.origin = .topic
        try store.save(p)
        XCTAssertEqual(store.load(p.id), p)

        let newer = try proposal([.init(change: .appendRecords(path: "主题/x", lines: ["y"]), baseVersion: nil)], created: t0.addingTimeInterval(60))
        XCTAssertEqual(store.list().map(\.id), [newer.id, p.id], "新→旧")
        XCTAssertEqual(store.pendingItemCount(), 3)
        XCTAssertNil(store.load("../x"))
    }

    func testDirectionFactDomainSurvivesProposalStorageAndLegacyJSONStaysUnknown() throws {
        let direction = WikiProposal.Direction(path: "主题/云桥城", title: "云桥城", kind: .topic,
            action: .newPage, reason: "林栖的设定", mode: .seed, sources: ["m/林栖"], factDomain: .inWorld)
        let saved = try proposal([.init(change: .direction(direction))])
        XCTAssertEqual(store.load(saved.id)?.items.first?.change.direction?.factDomain, .inWorld)
        let raw = #"{"path":"主题/云桥城","title":"云桥城","hook":"","aliases":[],"action":"newPage","reason":"旧目录","clues":[],"mode":"seed"}"#
        let legacy = try JSONDecoder().decode(WikiProposal.Direction.self, from: Data(raw.utf8))
        XCTAssertNil(legacy.factDomain)
    }

    func testLegacyReviewJSONWithoutConversionsRemainsReadable() throws {
        let raw = #"{"id":"fictional-old-review","at":0,"kind":"rejected","fragmentMarks":[]}"#
        let record = try JSONDecoder().decode(WikiProposal.ReviewRecord.self, from: Data(raw.utf8))
        XCTAssertEqual(record.id, "fictional-old-review")
        XCTAssertEqual(record.kind, .rejected)
        XCTAssertEqual(record.origin, .user)
        XCTAssertNil(record.conversions)
        XCTAssertNil(record.rejection)
        XCTAssertEqual(try JSONDecoder().decode(WikiProposal.ReviewRecord.self, from: JSONEncoder().encode(record)), record)
    }

    func testStatusFromItems() {
        var p = WikiProposal(origin: .manual, createdAt: t0, items: [
            .init(change: .appendRecords(path: "主题/a", lines: []), baseVersion: nil),
            .init(change: .appendRecords(path: "主题/b", lines: []), baseVersion: nil),
        ])
        XCTAssertEqual(p.status, .pending)
        p.items[0].state = .stale
        XCTAssertEqual(p.status, .partial)
        p.items[1].state = .rejected
        XCTAssertEqual(p.status, .done)
    }

    func testEdit() async throws {
        let v0 = try wiki.save(xiaohui)
        let item = WikiProposal.Item(change: .appendRecords(path: xiaohui.path, lines: ["草稿"]), baseVersion: v0)
        let p = try proposal([item])
        let edited = try store.edit(p.id, itemId: item.id, change: .appendRecords(path: xiaohui.path, lines: ["改过的一行"]), judgment: .coexist)
        XCTAssertEqual(edited.items[0].judgment, .coexist)
        XCTAssertEqual(store.load(p.id)?.items[0].change, .appendRecords(path: xiaohui.path, lines: ["改过的一行（出处：用户编辑）"]), "她自己写的标「用户编辑」")
        try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(wiki.read(xiaohui.path)?.records, ["2026-10-01 认识", "改过的一行（出处：用户编辑）"])
        XCTAssertThrowsError(try store.edit(p.id, itemId: item.id, change: item.change, judgment: nil)) {
            XCTAssertEqual($0 as? WikiProposalStore.ProposalError, .notPending(item.id))
        }
    }

    // MARK: - 批

    func testApprovalAndManualSaveShareCanonicalFloorLock() async throws {
        let version = try wiki.save(xiaohui)
        let p = try proposal([.init(change: .appendRecords(path: xiaohui.path, lines: ["批准追加"]), baseVersion: version)])
        let wiki = wiki!, store = store!, context = context!, path = xiaohui.path
        let original = try XCTUnwrap(wiki.readRaw(path))
        var edited = xiaohui
        edited.now = "人工改稿"
        var approvedPage = xiaohui
        approvedPage.records.append("批准追加")
        let alias = root.appendingPathComponent("同楼层别名")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let editorStore = WikiStore(root: alias)
        let gate = CatalogLock()
        await gate.acquire("hold")
        let entered = expectation(description: "共用写锁已持有")
        let crossed = expectation(description: "持锁时不能批准或人工保存")
        crossed.isInverted = true
        var holding = false
        var events: [String] = []
        let holder = Task {
            try await WikiProposalReview.exclusive(wiki: wiki) {
                holding = true
                events.append("enter")
                entered.fulfill()
                await gate.acquire("hold")
                events.append("exit")
                holding = false
                await gate.release("hold")
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let approval = Task {
            let result = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0,
                saveMarks: { context in
                    if holding { crossed.fulfill() }
                    events.append("approve")
                    try context.save()
                })
            if holding { crossed.fulfill() }
            return result
        }
        let manual = Task { () -> Bool in
            do {
                try await WikiEditing.save(edited.markdown, baseline: original, store: editorStore, path: path)
                if holding { crossed.fulfill() }
                events.append("save")
                return true
            } catch {
                if holding { crossed.fulfill() }
                return false
            }
        }
        await fulfillment(of: [crossed], timeout: 0.2)
        await gate.release("hold")
        try await holder.value
        let reviewed = try await approval.value
        let saved = await manual.value
        XCTAssertEqual(Array(events.prefix(2)), ["enter", "exit"])
        XCTAssertEqual(reviewed.items[0].state, saved ? .stale : .approved)
        XCTAssertEqual(wiki.readRaw(path), saved ? edited.markdown : approvedPage.markdown)
        XCTAssertEqual(wiki.read(path)?.records, saved ? xiaohui.records : xiaohui.records + ["批准追加"])
        let history = wiki.history(path)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(wiki.historyText(path, entry: try XCTUnwrap(history.first).name), original)
    }

    func testDifferentFloorLocksCanBeHeldTogether() async throws {
        let first = wiki!
        let second = WikiStore(root: root.appendingPathComponent("另一楼层"))
        let gate = CatalogLock()
        await gate.acquire("hold")
        let entered = expectation(description: "不同楼层同时持锁")
        entered.expectedFulfillmentCount = 2
        var active = 0
        var peak = 0
        let tasks = [first, second].map { wiki in
            Task {
                try await WikiProposalReview.exclusive(wiki: wiki) {
                    active += 1
                    peak = max(peak, active)
                    entered.fulfill()
                    await gate.acquire("hold")
                    active -= 1
                    await gate.release("hold")
                }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(peak, 2)
        await gate.release("hold")
        for task in tasks { try await task.value }
    }

    func testFloorLockIsReleasedAfterFailure() async throws {
        enum Failure: Error { case expected }
        do {
            try await WikiProposalReview.exclusive(store) { throw Failure.expected }
            XCTFail("应传回锁内错误")
        } catch Failure.expected { }
        try wiki.save(xiaohui)
        try await WikiEditing.save("错误后的人工保存", baseline: xiaohui.markdown, store: wiki, path: xiaohui.path)
        XCTAssertEqual(wiki.readRaw(xiaohui.path), "错误后的人工保存")
    }

    func testPageMarkdownPreviewDistinguishesDeclaredDomainsFromLegacyUnknown() {
        let labels: [(SeedFactDomain?, String)] = [
            (.realWorld, "现实"), (.inWorld, "设定"), (.mixed, "混合待判"),
            (.unspecified, "未判"), (nil, "未记录"),
        ]
        for (domain, label) in labels {
            let page = WikiPage(path: "主题/云桥城", title: "云桥城", now: "虚构航线概览。", factDomain: domain)
            let preview = WikiProposalDisplay.pageMarkdown(page)
            XCTAssertEqual(preview.components(separatedBy: "\n").first, "事实域：\(label)")
        }
    }

    private func seedProposal(_ items: [WikiProposal.Item], domain: SeedFactDomain?) throws -> WikiProposal {
        let task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .cc, modelName: "fake",
                                   createdAt: t0, run: .init(path: ".runs/test.md"))
        try CatalogSeedTaskStore(wiki: wiki).save(task)
        let path = try XCTUnwrap(items.first?.change.targetPath)
        let direction = WikiProposal.Direction(path: path, title: "云桥城", kind: .topic,
            action: items.first?.change.isNewPage == true ? .newPage : .update,
            reason: "虚构夹具", mode: .seed, sources: ["memory/cc/云桥城.md"], factDomain: domain)
        let outline = WikiProposal(id: task.id, origin: .seed, createdAt: t0,
            items: [.init(state: .approved, change: .direction(direction))], seedTask: task.id)
        try store.save(outline)
        let content = WikiProposal(origin: .seed, createdAt: t0, items: items, seedTask: task.id)
        try store.save(content)
        return content
    }

    func testSeedApprovalChecksCurrentPageDomainForEveryUpdateButAllowsLegacyDirections() async throws {
        let domains: [(SeedFactDomain?, SeedFactDomain?)] = [
            (.inWorld, .realWorld), (nil, .realWorld), (.realWorld, .inWorld), (.mixed, .unspecified),
            (.inWorld, .inWorld), (.realWorld, .realWorld), (nil, nil), (.inWorld, nil),
        ]
        let target = "主题/云桥城"
        let linked = "主题/纸舟"
        try wiki.save(WikiPage(path: linked, title: "纸舟", factDomain: .inWorld))
        for (pageDomain, directionDomain) in domains {
            for operation in 0..<4 {
                let original = WikiPage(path: target, kind: .topic, triggers: ["云桥城"], hook: "当提到码头时看",
                    title: "云桥城", now: "虚构旧概览。", records: [], factDomain: pageDomain)
                let version = try wiki.saveRaw(original.markdown, path: target, now: t0)
                var expected = original
                let change: WikiProposal.Change
                switch operation {
                case 0:
                    let line = "2026-10-09 · 设定 · 夜航（memory/cc/云桥城.md）"
                    change = .appendRecords(path: target, lines: [line])
                    expected.records = [line]
                case 1:
                    change = .rewriteNow(path: target, old: original.now, new: "设定中云桥城有夜航。")
                    expected.now = "设定中云桥城有夜航。"
                case 2:
                    let link = WikiPage.Link(target: linked, relation: .supplement, why: "虚构航线")
                    change = .link(from: target, link: link)
                    expected.links = [link]
                default:
                    change = .retag(path: target, oldHook: original.hook, newHook: "当提到夜航时看",
                                    oldTriggers: original.triggers, newTriggers: ["云桥城", "夜航"])
                    expected.hook = "当提到夜航时看"
                    expected.triggers = ["云桥城", "夜航"]
                }
                let p = try seedProposal([.init(change: change, baseVersion: version)], domain: directionDomain)
                if pageDomain == nil, directionDomain != nil, operation == 3 {
                    let taskId = try XCTUnwrap(p.seedTask)
                    try FileManager.default.removeItem(at: CatalogSeedTaskStore(wiki: wiki).folder(taskId)
                        .appendingPathComponent(CatalogSeedTaskStore.fileName))
                }
                let before = Set(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).map(\.id))
                let approved = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
                let mismatch = directionDomain != nil && pageDomain != directionDomain
                XCTAssertEqual(approved.items.first?.state, mismatch ? .stale : .approved)
                let reviewed = try XCTUnwrap(approved.items.first)
                let persisted = try XCTUnwrap(store.load(p.id)?.items.first)
                XCTAssertEqual(persisted.staleReason, reviewed.staleReason)
                if mismatch {
                    XCTAssertTrue(reviewed.staleReason?.contains("页域不合") == true)
                    XCTAssertEqual(WikiProposalDetailPage(proposalId: p.id, viewModel: nil).statusLabel(reviewed, .stale),
                                   reviewed.staleReason)
                } else {
                    XCTAssertNil(reviewed.staleReason)
                }
                XCTAssertEqual(wiki.read(target), mismatch ? original : expected)
                if mismatch { XCTAssertEqual(wiki.version(of: target), version, "拒收不能落页或重标旧页") }
                let warnings = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).filter {
                    !before.contains($0.id) && !$0.ok && $0.note.contains("页域不合")
                }
                XCTAssertEqual(warnings.count, mismatch ? 1 : 0)
                if mismatch {
                    XCTAssertEqual(warnings.first?.note, reviewed.staleReason)
                }
            }
        }
    }

    func testSeedNewPageFillsOnlyMissingDomainFromDirectionAndLogsTheRepair() async throws {
        let rows: [(SeedFactDomain?, SeedFactDomain?, SeedFactDomain?)] = [
            (nil, .inWorld, .inWorld), (.realWorld, .inWorld, nil), (nil, nil, nil),
            (.inWorld, .inWorld, .inWorld), (.realWorld, nil, .realWorld),
        ]
        for (index, row) in rows.enumerated() {
            let path = "主题/云桥城\(index)"
            let page = WikiPage(path: path, title: "云桥城", now: "设定中有夜航。", factDomain: row.0)
            let p = try seedProposal([.init(change: .newPage(page: page))], domain: row.1)
            let before = Set(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).map(\.id))
            let done = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
            let mismatch = row.0 != nil && row.1 != nil && row.0 != row.1
            XCTAssertEqual(done.items.first?.state, mismatch ? .stale : .approved)
            if mismatch {
                let reviewed = try XCTUnwrap(done.items.first)
                XCTAssertTrue(reviewed.staleReason?.contains("页域不合") == true)
                XCTAssertEqual(store.load(p.id)?.items.first?.staleReason, reviewed.staleReason)
                XCTAssertEqual(WikiProposalDetailPage(proposalId: p.id, viewModel: nil).statusLabel(reviewed, .stale),
                               reviewed.staleReason)
            }
            XCTAssertEqual(wiki.pageExists(path), !mismatch)
            XCTAssertEqual(wiki.read(path)?.factDomain, row.2)
            let warnings = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).filter {
                !before.contains($0.id) && !$0.ok && $0.note.contains("页域不合")
            }
            XCTAssertEqual(warnings.count, mismatch ? 1 : 0)
            if mismatch {
                XCTAssertEqual(warnings.first?.note, "种子批准「\(path)」：页域不合（页 现实 / 目录项 设定），没改页")
            }
            let repairs = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).filter {
                !before.contains($0.id) && $0.note.contains("旧正文未记页域")
            }
            XCTAssertEqual(repairs.count, row.0 == nil && row.1 != nil ? 1 : 0)
            if let repair = repairs.first { XCTAssertTrue(repair.ok) }
        }
    }

    func testSeedApprovalUsesReferencedDirectionBeforeMatchingPath() async throws {
        let domains: [SeedFactDomain?] = [.inWorld, nil]
        for (index, domain) in domains.enumerated() {
            let path = "主题/云桥城引用\(index)"
            let page = WikiPage(path: path, title: "云桥城", now: "设定中有夜航。", factDomain: .inWorld)
            var content = try seedProposal([.init(change: .newPage(page: page))], domain: .realWorld)
            let taskId = try XCTUnwrap(content.seedTask)
            var outline = try XCTUnwrap(store.load(taskId))
            var referenced = try XCTUnwrap(outline.items.first?.change.direction)
            referenced.factDomain = domain
            let second = WikiProposal.Item(state: .approved, change: .direction(referenced))
            outline.items.append(second)
            try store.save(outline)
            content.directionRef = .init(proposalId: outline.id, itemId: second.id)
            try store.save(content)
            let done = try await WikiProposalReview.approve(content.id, store: store, profileId: pid, context: context, now: t0)
            XCTAssertEqual(done.items.first?.state, .approved)
            XCTAssertEqual(wiki.read(path), page)
        }
    }

    func testApproveAllNewPageThenFollowUps() async throws {
        let f1 = fragment("小慧是室友"), f2 = fragment("小慧会做饭"), f3 = fragment("小慧喜欢猫"), untouched = fragment("无关")
        try context.save()
        let link = WikiPage.Link(target: "地点/五楼", relation: .supplement, why: "一起住")
        let p = try proposal([
            .init(change: .newPage(page: xiaohui), fragmentIds: [f1.id, f2.id], baseVersion: nil),
            .init(change: .appendRecords(path: xiaohui.path, lines: ["2026-10-12 喜欢猫（到 2026-10-22）"]), judgment: .coexist, fragmentIds: [f3.id], baseVersion: nil),
            .init(change: .link(from: xiaohui.path, link: link), baseVersion: nil),
            .init(change: .retag(path: xiaohui.path, oldHook: "她提到小慧时", newHook: "她提到小慧、室友时", oldTriggers: ["小慧"], newTriggers: ["小慧", "慧慧"]), baseVersion: nil),
        ])
        XCTAssertEqual(store.pendingItemCount(), 4)

        let done = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(done.items.map(\.state), [.approved, .approved, .approved, .approved])
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.finishedAt, t0)
        XCTAssertEqual(store.pendingItemCount(), 0)

        let page = try XCTUnwrap(wiki.read(xiaohui.path))
        XCTAssertEqual(page.records, ["2026-10-01 认识", "2026-10-12 喜欢猫（到 2026-10-22）"])
        XCTAssertEqual(page.links, [link])
        XCTAssertEqual(page.hook, "她提到小慧、室友时")
        XCTAssertEqual(page.triggers, ["小慧", "慧慧"])
        XCTAssertEqual(page.now, "室友（自 2026-09 起）")

        for f in [f1, f2, f3] {
            let m = try XCTUnwrap(fresh(f.id), "显式 save 过，别的 context 读得到")
            XCTAssertEqual(m.organizedAt, t0)
            XCTAssertEqual(m.organizedPage, xiaohui.path)
            XCTAssertNil(m.organizeRejectedAt)
        }
        XCTAssertNil(try fresh(untouched.id)?.organizedAt)

        let layer = try String(contentsOf: wiki.folderURL("人").appendingPathComponent(WikiStore.indexFileName), encoding: .utf8)
        XCTAssertTrue(layer.contains("- [[人/小慧]] 小慧 — 她提到小慧、室友时"))
        XCTAssertNotNil(try? String(contentsOf: root.appendingPathComponent(WikiStore.indexFileName), encoding: .utf8))

        MemoryWriteLog.flush()
        let log = try XCTUnwrap(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).first)
        XCTAssertEqual(log.writer, "C3")
        XCTAssertEqual(log.note, "整理提案批了 4 条 · 写了 1 页")
    }

    func testPartialApproveCarriesBaseVersion() async throws {
        let v0 = try wiki.save(xiaohui)
        let a = WikiProposal.Item(change: .appendRecords(path: xiaohui.path, lines: ["甲"]), baseVersion: v0)
        let b = WikiProposal.Item(change: .rewriteNow(path: xiaohui.path, old: xiaohui.now, new: "新的现在"), judgment: .conflict, baseVersion: v0)
        let p = try proposal([a, b])

        let after1 = try await WikiProposalReview.approve(p.id, itemIds: [a.id], store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(after1.status, .partial)
        XCTAssertNil(after1.finishedAt)
        XCTAssertEqual(after1.items[1].baseVersion, wiki.version(of: xiaohui.path), "同页后面的待批条目跟上新版本")

        let after2 = try await WikiProposalReview.approve(p.id, itemIds: [b.id], store: store, profileId: pid, context: context, now: t0.addingTimeInterval(1))
        XCTAssertEqual(after2.items.map(\.state), [.approved, .approved])
        XCTAssertEqual(wiki.read(xiaohui.path)?.records, ["2026-10-01 认识", "甲"])
        XCTAssertEqual(wiki.read(xiaohui.path)?.now, "新的现在")
        XCTAssertEqual(wiki.history(xiaohui.path).count, 2, "每次覆盖都存一版")
    }

    func testStaleWhenPageChanged() async throws {
        let f = fragment("x")
        try context.save()
        let v0 = try wiki.save(xiaohui)
        var hand = xiaohui
        hand.now = "她手改了"
        try wiki.saveRaw(hand.markdown, path: xiaohui.path)

        let p = try proposal([
            .init(change: .appendRecords(path: xiaohui.path, lines: ["不该写"]), fragmentIds: [f.id], baseVersion: v0),
            .init(change: .newPage(page: xiaohui), baseVersion: nil),
            .init(change: .appendRecords(path: "人/不存在", lines: ["x"]), baseVersion: "v"),
            .init(change: .appendRecords(path: "别处/x", lines: ["x"]), baseVersion: nil),
        ])
        let out = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(out.items.map(\.state), [.stale, .stale, .stale, .stale])
        XCTAssertTrue(out.items.allSatisfy { $0.staleReason == nil })
        XCTAssertEqual(WikiProposalDetailPage(proposalId: p.id, viewModel: nil).statusLabel(out.items[0], .stale),
                       WikiProposalDisplay.ItemStatus.stale.label)
        XCTAssertEqual(out.status, .done)
        XCTAssertEqual(wiki.read(xiaohui.path), hand, "不硬盖")
        XCTAssertNil(try fresh(f.id)?.organizedAt)
        XCTAssertNil(try fresh(f.id)?.organizeRejectedAt)
        MemoryWriteLog.flush()
        XCTAssertTrue(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).isEmpty, "一条没批成不记日志")
    }

    func testTwoProposalsSamePage() async throws {
        let v0 = try wiki.save(xiaohui)
        let first = try proposal([.init(change: .appendRecords(path: xiaohui.path, lines: ["一"]), baseVersion: v0)])
        let second = try proposal([.init(change: .appendRecords(path: xiaohui.path, lines: ["二"]), baseVersion: v0)])
        try await WikiProposalReview.approve(first.id, store: store, profileId: pid, context: context, now: t0)
        let out = try await WikiProposalReview.approve(second.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(out.items[0].state, .stale, "后一份对不上的置灰")
        XCTAssertEqual(wiki.read(xiaohui.path)?.records, ["2026-10-01 认识", "一"])
    }

    // MARK: - 批的顺序（astra 10-16 #2）

    func testMarkSaveFailureLeavesItemPending() async throws {
        struct Boom: Error {}
        let f = fragment("小慧是室友")
        try context.save()
        let p = try proposal([.init(change: .newPage(page: xiaohui), fragmentIds: [f.id], baseVersion: nil)])

        do {
            try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0, saveMarks: { _ in throw Boom() })
            XCTFail("打标存不成应该抛")
        } catch is Boom {}

        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending, "碎片没标成，条目不变成已批")
        XCTAssertNil(store.load(p.id)?.finishedAt)
        XCTAssertNil(try fresh(f.id)?.organizedAt)
        XCTAssertNil(f.organizedAt, "context 里改的字段也改回去")
        XCTAssertNil(f.organizedPage)
        let receipts = await Task.detached { [wiki = wiki!] in wiki.deletions() }.value
        let deletion = try XCTUnwrap(receipts.first)
        XCTAssertEqual(deletion.reason, "批准补偿")
        XCTAssertEqual(deletion.phase, .deleted)
        XCTAssertFalse(wiki.pageExists(xiaohui.path))
        let copy = try XCTUnwrap(wiki.historyText(xiaohui.path, entry: deletion.historyEntry))
        XCTAssertEqual(WikiStore.version(of: Data(copy.utf8)), deletion.deletedVersion)
    }

    func testRegroupFailureMidwayRollsBack() async throws {
        try wiki.save(WikiPage(path: "主题/电影/甲", title: "甲", records: ["1"]), now: t0)
        try wiki.save(WikiPage(path: "主题/电影/甲", title: "甲", records: ["1", "2"]), now: t0.addingTimeInterval(1))
        try wiki.save(WikiPage(path: "主题/身体", title: "身体", links: [.init(target: "主题/电影/甲", relation: .citation, why: "")]))
        // 挪历史那一步会撞上：新位置历史的上一层是个文件
        let blocker = wiki.historyURL("主题/电影/国产")
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker)
        let p = try proposal([.init(change: .regroup(layer: "主题/电影", groups: [.init(path: "主题/电影/国产", hook: "她聊国产片时")],
                                                       moves: [.init(from: "主题/电影/甲", to: "主题/电影/国产/甲")]), baseVersion: nil)])
        let histories = try wiki.relativeFiles(WikiStore.historyFolder)

        do {
            try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
            XCTFail("挪历史失败应该抛")
        } catch {}

        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending, "条目保持待批")
        XCTAssertEqual(wiki.read("主题/电影/甲")?.records, ["1", "2"], "页挪回原处")
        XCTAssertFalse(wiki.pageExists("主题/电影/国产/甲"))
        XCTAssertEqual(wiki.history("主题/电影/甲").count, 1, "历史还在原处")
        XCTAssertFalse(wiki.folderExists("主题/电影/国产"), "新建的分组删掉")
        XCTAssertEqual(wiki.read("主题/身体")?.links.first?.target, "主题/电影/甲")
        XCTAssertEqual(try wiki.relativeFiles(WikiStore.historyFolder), histories)
        XCTAssertNil(SafeWiki.names(in: [WikiStore.proposalsFolder, p.id, "images"], under: wiki.root))
    }

    // MARK: - covered（astra 10-16 #7）

    func testCoveredMarkedOnApproveButNotRejectedOnReject() async throws {
        let used = fragment("用了的"), covered = fragment("页上写过的"), other = fragment("没用上的")
        try context.save()
        let v0 = try wiki.save(xiaohui)
        var a = WikiProposal.Item(change: .appendRecords(path: xiaohui.path, lines: ["甲"]), fragmentIds: [used.id], baseVersion: v0)
        a.covered = [covered.id]
        let p = try proposal([a])
        XCTAssertEqual(CatalogMaterial.pendingFragmentIds(store), [used.id, covered.id], "covered 的待批时也不再送分拣")

        try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(try fresh(used.id)?.organizedPage, xiaohui.path)
        XCTAssertEqual(try fresh(covered.id)?.organizedPage, xiaohui.path, "covered 的批了一起标")
        XCTAssertNil(try fresh(other.id)?.organizedAt)

        let u2 = fragment("u2"), c2 = fragment("c2")
        try context.save()
        var b = WikiProposal.Item(change: .appendRecords(path: xiaohui.path, lines: ["乙"]), fragmentIds: [u2.id], baseVersion: wiki.version(of: xiaohui.path))
        b.covered = [c2.id]
        let q = try proposal([b])
        try await WikiProposalReview.reject(q.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(try fresh(u2.id)?.organizeRejectedAt, t0)
        XCTAssertNil(try fresh(c2.id)?.organizeRejectedAt, "驳回只连带明确引用的")
    }

    // MARK: - 驳回

    func testRejectWaitsForFloorLockBeforeMarkingFragments() async throws {
        let fragment = fragment("锁内驳回的虚构碎片")
        try context.save()
        let p = try proposal([.init(change: .newPage(page: xiaohui), fragmentIds: [fragment.id])])
        let wiki = wiki!, store = store!, context = context!, now = t0
        let gate = CatalogLock()
        await gate.acquire("hold")
        let entered = expectation(description: "楼层写锁已持有")
        let crossed = expectation(description: "持锁时不能驳回或标碎片")
        crossed.isInverted = true
        var holding = false
        let holder = Task {
            try await WikiProposalReview.exclusive(wiki: wiki) {
                holding = true
                entered.fulfill()
                await gate.acquire("hold")
                holding = false
                await gate.release("hold")
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let rejection = Task {
            let result = try await WikiProposalReview.reject(p.id, store: store, profileId: pid, context: context, now: now)
            if holding { crossed.fulfill() }
            return result
        }
        await fulfillment(of: [crossed], timeout: 0.2)
        XCTAssertNil(fragment.organizeRejectedAt)
        XCTAssertNil(try fresh(fragment.id)?.organizeRejectedAt)
        XCTAssertEqual(store.load(p.id)?.items.first?.state, .pending)

        await gate.release("hold")
        try await holder.value
        let rejected = try await rejection.value
        XCTAssertEqual(rejected.items.first?.state, .rejected)
        XCTAssertEqual(fragment.organizeRejectedAt, now)
        XCTAssertEqual(try fresh(fragment.id)?.organizeRejectedAt, now)
    }

    func testReject() async throws {
        let f1 = fragment("a"), f2 = fragment("b")
        try context.save()
        let a = WikiProposal.Item(change: .newPage(page: xiaohui), fragmentIds: [f1.id], baseVersion: nil)
        let b = WikiProposal.Item(change: .newPage(page: WikiPage(path: "人/阿明", title: "阿明")), fragmentIds: [f2.id], baseVersion: nil)
        let p = try proposal([a, b])

        let r1 = try await WikiProposalReview.reject(p.id, itemIds: [a.id], store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(r1.items.map(\.state), [.rejected, .pending])
        XCTAssertEqual(try fresh(f1.id)?.organizeRejectedAt, t0)
        XCTAssertNil(try fresh(f1.id)?.organizedAt)
        XCTAssertNil(try fresh(f2.id)?.organizeRejectedAt)
        XCTAssertFalse(wiki.pageExists(xiaohui.path))

        let r2 = try await WikiProposalReview.reject(p.id, store: store, profileId: pid, context: context, now: t0.addingTimeInterval(9))
        XCTAssertEqual(r2.status, .done)
        XCTAssertEqual(r2.finishedAt, t0.addingTimeInterval(9))
        XCTAssertEqual(try fresh(f2.id)?.organizeRejectedAt, t0.addingTimeInterval(9))
        XCTAssertTrue(wiki.pagePaths().isEmpty)
    }

    // MARK: - 分组调整

    func testRegroupMovesPagesHistoryLinksAndFragments() async throws {
        try wiki.save(WikiPage(path: "主题/电影/甲", title: "甲", records: ["1"]), now: t0)
        try wiki.save(WikiPage(path: "主题/电影/甲", title: "甲", records: ["1", "2"]), now: t0.addingTimeInterval(1))
        try wiki.save(WikiPage(path: "主题/电影/乙", title: "乙"))
        try wiki.save(WikiPage(path: "主题/身体", title: "身体",
                               links: [.init(target: "主题/电影/甲", relation: .citation, why: "看过"),
                                       .init(target: "主题/电影/乙", relation: .resonance, why: "")]))
        let f = fragment("甲好看")
        f.organizedAt = t0
        f.organizedPage = "主题/电影/甲"
        let other = fragment("别的")
        other.organizedAt = t0
        other.organizedPage = "主题/身体"
        try context.save()

        let p = try proposal([.init(change: .regroup(layer: "主题/电影", groups: [.init(path: "主题/电影/国产", hook: "她聊国产片时")],
                                                       moves: [.init(from: "主题/电影/甲", to: "主题/电影/国产/甲")]), baseVersion: nil)])
        let cacheVersion = WikiInjectionCache.shared.version
        let out = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0.addingTimeInterval(10))
        XCTAssertEqual(out.items[0].state, .approved)

        XCTAssertGreaterThan(WikiInjectionCache.shared.version, cacheVersion)
        XCTAssertFalse(wiki.pageExists("主题/电影/甲"))
        XCTAssertEqual(wiki.read("主题/电影/国产/甲")?.records, ["1", "2"])
        XCTAssertEqual(wiki.history("主题/电影/国产/甲").count, 1, "历史跟着挪")
        XCTAssertTrue(wiki.history("主题/电影/甲").isEmpty)
        XCTAssertEqual(wiki.read("主题/身体")?.links.map(\.target), ["主题/电影/国产/甲", "主题/电影/乙"])
        XCTAssertEqual(wiki.groupHook("主题/电影/国产"), "她聊国产片时")
        XCTAssertEqual(try fresh(f.id)?.organizedPage, "主题/电影/国产/甲")
        XCTAssertEqual(try fresh(other.id)?.organizedPage, "主题/身体")
        let layer = try String(contentsOf: wiki.folderURL("主题/电影").appendingPathComponent(WikiStore.indexFileName), encoding: .utf8)
        XCTAssertTrue(layer.contains("- [[主题/电影/国产/]] 国产 — 她聊国产片时（1 页）"))
        XCTAssertTrue(layer.contains("- [[主题/电影/乙]] 乙"))
        XCTAssertTrue(try String(contentsOf: wiki.folderURL("").appendingPathComponent(WikiStore.indexFileName), encoding: .utf8)
                        .contains("- [[主题/身体]]"), "全量重建")
    }

    func testRegroupMovesFolder() async throws {
        try wiki.save(WikiPage(path: "主题/电影/甲", title: "甲"), now: t0)
        try wiki.save(WikiPage(path: "主题/电影/甲", title: "甲", now: "改"), now: t0.addingTimeInterval(1))
        try wiki.save(WikiPage(path: "主题/身体", title: "身体", links: [.init(target: "主题/电影/甲", relation: .citation, why: "")]))
        let p = try proposal([.init(change: .regroup(layer: "主题", groups: [.init(path: "主题/爱好", hook: "她聊爱好时")],
                                                       moves: [.init(from: "主题/电影", to: "主题/爱好/电影")]), baseVersion: nil)])
        try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(wiki.pagePaths(), ["主题/爱好/电影/甲", "主题/身体"])
        XCTAssertEqual(wiki.history("主题/爱好/电影/甲").count, 1)
        XCTAssertEqual(wiki.read("主题/身体")?.links.first?.target, "主题/爱好/电影/甲")
    }

    func testRegroupStaleWhenSourceMissingOrTargetTaken() async throws {
        try wiki.save(WikiPage(path: "主题/a", title: "a"))
        try wiki.save(WikiPage(path: "主题/组/a", title: "a"))
        let p = try proposal([
            .init(change: .regroup(layer: "主题", groups: [], moves: [.init(from: "主题/没有", to: "主题/组/没有")]), baseVersion: nil),
            .init(change: .regroup(layer: "主题", groups: [], moves: [.init(from: "主题/a", to: "主题/组/a")]), baseVersion: nil),
            .init(change: .regroup(layer: "", groups: [], moves: [.init(from: "主题", to: "工程/主题")]), baseVersion: nil),
        ])
        let out = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(out.items.map(\.state), [.stale, .stale, .stale])
        XCTAssertEqual(wiki.pagePaths(), ["主题/a", "主题/组/a"])
    }

    // MARK: - 清理

    func testPurgeFinished() throws {
        var old = WikiProposal(origin: .manual, createdAt: t0, items: [.init(state: .approved, change: .appendRecords(path: "主题/a", lines: []), baseVersion: nil)])
        old.finishedAt = t0
        var recent = WikiProposal(origin: .manual, createdAt: t0, items: [.init(state: .rejected, change: .appendRecords(path: "主题/a", lines: []), baseVersion: nil)])
        recent.finishedAt = t0.addingTimeInterval(20 * 86_400)
        let pending = WikiProposal(origin: .manual, createdAt: t0, items: [.init(change: .appendRecords(path: "主题/a", lines: []), baseVersion: nil)])
        for p in [old, recent, pending] { try store.save(p) }

        XCTAssertEqual(store.purgeFinished(now: t0.addingTimeInterval(31 * 86_400)), 1)
        XCTAssertEqual(Set(store.list().map(\.id)), [recent.id, pending.id])
    }
}
