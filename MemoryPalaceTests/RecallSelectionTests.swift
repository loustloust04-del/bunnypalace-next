import MemoryCore
import XCTest
@testable import 记忆花园

final class RecallSelectionTests: XCTestCase {
    private let profileId = "recall-fictional-岚舟"
    private let keys = ["mem_inject_keyword", "mem_inject_full", "mem_inject_vector", "mem_inject_graph", "mem_inject_catalog", MemoryOpenWindow.cKey]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.set(false, forKey: key)
        }
        UserDefaults.standard.set(true, forKey: "mem_inject_full")
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func profile() -> Profile {
        Profile(id: profileId, name: "云桥城", emoji: "", description: "", userName: "岚舟", assistantName: "星砚")
    }

    private func page(_ name: String = "林栖", version: String = "v1", now: String = "在云桥城筹备合成展览") -> WikiInjectionSnapshot.Page {
        .init(path: "人/\(name)", title: name, triggers: [], hook: "谈到\(name)的计划", now: now, version: version)
    }

    private func inputs(pages: [WikiInjectionSnapshot.Page] = [], memories: [Memory] = [], budget: Int = 1_000) -> MemoryInjector.RoundInputs {
        .init(memories: memories, selfMemory: nil, archiveBudget: budget, wiki: .init(pages: pages))
    }

    private func select(_ text: String, turn: String = "u1", state: RecallConversationState = .init(),
                        previous: RecallTurnDecision? = nil, inputs: MemoryInjector.RoundInputs,
                        recent: [String] = [], enabled: Bool = true,
                        tuning: RecallTuning = RecallTestTuning.make()) -> (decision: RecallTurnDecision, layers: RecallMemoryLayers) {
        RecallSelection.prepare(profile: profile(), conversationId: "fictional-window", turnId: turn,
                                branchAnchor: "branch", text: text, state: state, existingDecision: previous,
                                inputs: inputs, recentMessages: recent, now: Date(timeIntervalSince1970: 1_800_000_000), tuning: tuning, enabled: enabled)
    }

    private func commit(_ decision: RecallTurnDecision, state: inout RecallConversationState) {
        var receipt = RecallTurnReceipt(decision: decision)
        let attempt = receipt.beginAttempt()
        receipt.markAttempt(attempt, status: .submitted)
        XCTAssertTrue(receipt.recordResponse(attemptId: attempt, state: &state,
                                             currentTurnId: decision.turnId, currentBranchAnchor: decision.branchAnchor))
    }

    func testRealSelectorStoresExactRenderedVersionedPayloadAndKeepsOnlyActive() {
        let snapshot = inputs(pages: [page(), page("合成人物")])
        let first = select("林栖的计划进展怎么样", inputs: snapshot)
        XCTAssertEqual(first.decision.selected.map(\.source.path), ["人/林栖"])
        XCTAssertEqual(first.decision.selected.first?.source.version, "v1")
        XCTAssertEqual(first.decision.selected.first?.source.conversationId, "fictional-window")
        XCTAssertEqual(first.decision.selected.first?.text, first.layers.volatile)
        XCTAssertEqual(first.decision.selected.first?.tokenCost, Memory.estimateTokens(first.layers.volatile))
        var state = RecallConversationState()
        commit(first.decision, state: &state)
        let kept = select("林栖后来还谈到合成人物吗", turn: "u2", state: state, inputs: snapshot)
        XCTAssertEqual(kept.decision.gateReason, .kept)
        XCTAssertEqual(kept.layers.pages.map(\.page.path), ["人/林栖"], "A keep cannot refill from another current X1 hit")
        XCTAssertEqual(kept.decision.selected.first?.text, kept.layers.volatile)
    }

    func testTopicResetNeverScansPreviousUserIdentity() {
        let snapshot = inputs(pages: [page()])
        let first = select("林栖的计划进展怎么样", inputs: snapshot)
        var state = RecallConversationState()
        commit(first.decision, state: &state)
        let changed = select("请讨论完全独立的问题", turn: "u2", state: state, inputs: snapshot,
                             recent: ["林栖的计划进展怎么样", "请讨论完全独立的问题"])
        XCTAssertEqual(changed.decision.gateReason, .search)
        XCTAssertTrue(changed.layers.pages.isEmpty)
        XCTAssertTrue(changed.layers.volatile.isEmpty)
        XCTAssertEqual(changed.decision.topicAnchor, "请讨论完全独立的问题")
        XCTAssertEqual(changed.decision.stateAfterResponse.cooldowns.first?.untilTurn, 4)
    }

    func testKeepDropsChangedMissingAndOverBudgetPagesWithoutRefilling() {
        let first = select("林栖的计划进展怎么样", inputs: inputs(pages: [page()]))
        var state = RecallConversationState()
        commit(first.decision, state: &state)
        let changed = select("林栖后来怎样安排", turn: "u2", state: state, inputs: inputs(pages: [page(version: "v2")]))
        XCTAssertEqual(changed.decision.gateReason, .kept)
        XCTAssertTrue(changed.layers.volatile.isEmpty)
        XCTAssertEqual(changed.decision.suppressions.first?.reason, .unavailable)
        let removed = select("林栖后来怎样安排", turn: "u2", state: state, inputs: inputs())
        XCTAssertTrue(removed.layers.pages.isEmpty)
        let budget = select("林栖后来怎样安排", turn: "u2", state: state, inputs: inputs(pages: [page()], budget: 1))
        XCTAssertTrue(budget.layers.volatile.isEmpty)
        XCTAssertEqual(budget.decision.suppressions.first?.reason, .budget)
    }

    func testFragmentRetainDropsOnceIncorporatedAndDoesNotLeakOtherFloor() {
        let fragment = Memory(content: "林栖正在筹备云桥城合成展览", category: "fact", profileId: profileId)
        fragment.occurredDay = "2026-10-28"
        fragment.reviewedAt = Date()
        fragment.subject = "林栖"
        let otherFloor = Memory(content: "另一楼层的合成资料不可见", category: "fact", profileId: "other-floor")
        otherFloor.occurredDay = "2026-10-28"
        otherFloor.reviewedAt = Date()
        let first = select("林栖的计划进展怎么样", inputs: inputs(memories: [fragment, otherFloor]))
        XCTAssertEqual(first.decision.selected.map(\.source.path), [fragment.id.uuidString])
        XCTAssertEqual(first.decision.selected.first?.text, first.layers.volatile)
        XCTAssertFalse(first.layers.volatile.contains("另一楼层"))
        var state = RecallConversationState()
        commit(first.decision, state: &state)
        fragment.organizedPage = "人/林栖"
        let retained = select("林栖后来怎样安排", turn: "u2", state: state, inputs: inputs(memories: [fragment]))
        XCTAssertEqual(retained.decision.gateReason, .kept)
        XCTAssertTrue(retained.decision.selected.isEmpty)
        XCTAssertTrue(retained.layers.hits.isEmpty)
    }

    func testReplayRevalidatesBudgetButDoesNotRejudgeDifferentText() {
        let first = select("林栖的计划进展怎么样", inputs: inputs(pages: [page()]))
        let replay = select("工具摘要提到合成人物", previous: first.decision,
                            inputs: inputs(pages: [page(), page("合成人物")], budget: 1))
        XCTAssertEqual(replay.decision.origin, .continuation)
        XCTAssertEqual(replay.decision.topicAnchor, first.decision.topicAnchor)
        XCTAssertTrue(replay.layers.volatile.isEmpty)
        XCTAssertEqual(replay.decision.stateAfterResponse.effectiveTurn, 1)
    }

    func testRootAndPinnedPayloadConsumeKeepAllowance() {
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)
        let pinned = Memory(content: "岚舟明确钉住的一条合成设置", category: "fact", profileId: profileId, isUserExplicit: true)
        let snapshot = WikiInjectionSnapshot(indexLines: ["- [[人/林栖]] 林栖"], pages: [page()])
        let full = MemoryInjector.RoundInputs(memories: [pinned], selfMemory: nil, archiveBudget: 1_000, wiki: snapshot)
        let first = select("林栖的计划进展怎么样", inputs: full)
        var state = RecallConversationState()
        commit(first.decision, state: &state)
        let tight = MemoryInjector.RoundInputs(memories: [pinned], selfMemory: nil,
                                               archiveBudget: Memory.estimateTokens(first.layers.stable), wiki: snapshot)
        let kept = select("林栖后来怎样安排", turn: "u2", state: state, inputs: tight)
        XCTAssertTrue(kept.layers.stable.contains("钉住"))
        XCTAssertTrue(kept.layers.volatile.isEmpty)
        XCTAssertLessThanOrEqual(Memory.estimateTokens(kept.layers.stable), tight.archiveBudget)
    }

    func testArchiveSwitchDisablesAllXOutputWithoutDisablingRootOrLegacyFragments() {
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)
        let snapshot = WikiInjectionSnapshot(indexLines: ["- [[人/林栖]] 林栖"], pages: [page()])
        let full = MemoryInjector.RoundInputs(memories: [], selfMemory: nil, archiveBudget: 1000, wiki: snapshot)
        let first = select("林栖的计划进展怎么样", inputs: full)
        var state = RecallConversationState()
        commit(first.decision, state: &state)
        let off = RecallTestTuning.make(archiveTriggerEnabled: false)
        let stopped = select("林栖后来怎样安排", turn: "u2", state: state, inputs: full, tuning: off)
        XCTAssertEqual(stopped.decision.gateReason, .disabled)
        XCTAssertTrue(stopped.decision.selected.isEmpty)
        XCTAssertTrue(stopped.decision.candidates.isEmpty)
        XCTAssertTrue(stopped.decision.stateAfterResponse.active.isEmpty)
        XCTAssertTrue(stopped.layers.pages.isEmpty)
        XCTAssertEqual(stopped.layers.stable, WikiInjection.indexBlock(snapshot, user: profile().userName))
        XCTAssertEqual(stopped.layers.volatile, "")
        XCTAssertEqual(WikiInjection.hits(snapshot, recent: ["林栖"], excluding: [], tuning: off), [])
        UserDefaults.standard.set(false, forKey: MemoryOpenWindow.cKey)
        let triggerOnly = select("林栖的计划进展怎么样", inputs: full)
        XCTAssertEqual(triggerOnly.decision.selected.map(\.source.path), ["人/林栖"])
        XCTAssertEqual(triggerOnly.layers.stable, "")
        let fragment = Memory(content: "云桥城合成展览", category: "fact", profileId: profileId)
        fragment.occurredDay = "2026-10-28"
        fragment.reviewedAt = Date()
        fragment.keywords = ["cloudbridge"]
        UserDefaults.standard.set(false, forKey: "mem_inject_full")
        UserDefaults.standard.set(true, forKey: "mem_inject_keyword")
        let legacy = select("完全不同的问题", inputs: inputs(memories: [fragment]),
                            recent: ["cloudbridge", "完全不同的问题"], tuning: off)
        XCTAssertTrue(legacy.decision.selected.isEmpty)
        XCTAssertEqual(legacy.layers.hits.map(\.memoryId), [fragment.id])
        XCTAssertTrue(legacy.layers.volatile.contains(fragment.content))
        let withoutHistory = select("完全不同的问题", inputs: inputs(memories: [fragment]),
                                    recent: ["完全不同的问题"], tuning: off)
        XCTAssertTrue(withoutHistory.layers.hits.isEmpty)
    }

    func testDisabledThenShortRoundCannotResurrectActive() {
        let snapshot = inputs(pages: [page()])
        let first = select("林栖的计划进展怎么样", inputs: snapshot)
        var state = RecallConversationState()
        commit(first.decision, state: &state)
        let disabled = select("林栖后来怎样安排", turn: "u2", state: state, inputs: snapshot, enabled: false)
        commit(disabled.decision, state: &state)
        let skipped = select("🙂", turn: "u3", state: state, inputs: snapshot)
        XCTAssertEqual(skipped.decision.gateReason, .shortInput)
        XCTAssertTrue(skipped.decision.stateAfterResponse.active.isEmpty)
        XCTAssertTrue(skipped.decision.stateAfterResponse.pending.isEmpty)
        XCTAssertTrue(skipped.layers.volatile.isEmpty)
    }

    func testWarmSnapshotRejectsPrivateAndSymlinksAndRebuildsPublicIndex() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("recall-fictional-\(UUID().uuidString)")
        let wiki = WikiStore(root: temporary.appendingPathComponent("wiki"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try wiki.save(WikiPage(path: "人/林栖", title: "林栖", now: "云桥城的合成资料"))
        try wiki.save(WikiPage(path: "人/private_合成", title: "禁止出站的合成页"))
        try WikiStore.writeAtomic(Data("# stale\n- [[人/private_合成]] 禁止出站的合成页\n- [[人/已删除]] 旧行".utf8),
                                  to: wiki.root.appendingPathComponent(WikiStore.indexFileName))
        let outside = temporary.appendingPathComponent("outside.md")
        try Data("# 链接合成资料".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: wiki.root.appendingPathComponent("人/链接.md"), withDestinationURL: outside)
        let cache = WikiInjectionCache()
        let warmed = try await cache.warm(temporary.path, { wiki })
        XCTAssertEqual(warmed.snapshot.pages.map(\.path), ["人/林栖"])
        XCTAssertFalse(warmed.snapshot.pages[0].version.isEmpty)
        XCTAssertEqual(warmed.snapshot.pages[0].version, wiki.version(of: "人/林栖"))
        let index = WikiInjection.indexBlock(warmed.snapshot)
        XCTAssertTrue(index.contains("## 人（1 页）"))
        XCTAssertTrue(index.contains("[[人/林栖]]"))
        XCTAssertFalse(index.contains("private_"))
        XCTAssertFalse(index.contains("已删除"))
        XCTAssertFalse(index.contains("链接"))
        XCTAssertFalse(warmed.snapshot.pages[0].lexicalDocument.isEmpty)
    }
    func testRetokenizesWhenFloorWordLengthsChange() {
        let snapshot = WikiInjectionSnapshot(
            pages: [.init(path: "主题/合成", title: "合成", triggers: [], hook: "", now: "",
                          version: "lexical-v1", document: "cedar maple")])
        let input = MemoryInjector.RoundInputs(memories: [], selfMemory: nil, archiveBudget: 1_000, wiki: snapshot)
        var state = RecallConversationState()
        var tuning = RecallTestTuning.make()
        tuning.minimumLatinTermLength = 3
        tuning.minimumSharedTerms = 2
        state.branchAnchor = "branch"
        state.active = [.init(source: .init(profileId: profileId, conversationId: "fictional-window",
                                            kind: .page, path: "主题/合成", version: "lexical-v1"),
                              text: "合成载荷", identities: [], tokenCost: 1)]
        state.topicAnchor = "cedar maple"
        XCTAssertEqual(select("cedar maple", turn: "u2", state: state, inputs: input, tuning: tuning).decision.gateReason, .kept)
        tuning.minimumLatinTermLength = 8
        XCTAssertEqual(select("cedar maple", turn: "u2", state: state, inputs: input, tuning: tuning).decision.gateReason, .search)
    }

    func testExpiredPinnedReminderSurvivesShortGateWithoutChangingStablePayload() throws {
        let expiry = try XCTUnwrap(FragmentPool.validUntilDate("2026-10-28"))
        let pinned = Memory(content: "林栖在云桥城筹备星图展览", category: "fact", profileId: profileId, isUserExplicit: true)
        pinned.validUntil = expiry
        let input = inputs(memories: [pinned])
        func selection(at now: Date) -> (decision: RecallTurnDecision, layers: RecallMemoryLayers) {
            RecallSelection.prepare(profile: profile(), conversationId: "fictional-window", turnId: "u1",
                                    branchAnchor: "branch", text: "🙂", state: .init(), existingDecision: nil,
                                    inputs: input, recentMessages: [], now: now, tuning: RecallTestTuning.make())
        }
        let before = selection(at: expiry.addingTimeInterval(-1))
        let after = selection(at: expiry.addingTimeInterval(1))
        XCTAssertEqual(before.layers.stable, after.layers.stable)
        XCTAssertTrue(before.layers.volatile.isEmpty)
        XCTAssertEqual(after.decision.gateReason, .shortInput)
        XCTAssertTrue(after.decision.selected.isEmpty, "Z 的有效期提醒不制造 X 推送")
        XCTAssertTrue(after.layers.volatile.contains(pinned.content))
        XCTAssertTrue(after.layers.volatile.contains("已过期"))
        XCTAssertLessThanOrEqual(Memory.estimateTokens(after.layers.stable + after.layers.volatile), input.archiveBudget)
    }

    private func fullTextInputs(_ f: RecallFullTextFixture, _ text: String, budget: Int = 4_000,
                                memories: [Memory] = []) async -> MemoryInjector.RoundInputs {
        let (snapshot, candidates) = await f.fetch(text)
        return .init(memories: memories, selfMemory: nil, archiveBudget: budget, wiki: snapshot, fullText: candidates)
    }

    func testFullTextNowAndRecordsSelectPagesButRenderOnlyHookAndNow() async throws {
        let f = try RecallFullTextFixture(profileId: profileId)
        try f.page("主题/合成航线", now: "cedar maple 当前航线", validUntil: "2020-01-01")
        try f.page("主题/合成记录", now: "记录页现在", records: ["cedar maple 不出站的历史"])
        let input = await fullTextInputs(f, "cedar maple")
        let result = select("cedar maple", inputs: input)
        XCTAssertEqual(Set(result.decision.selected.map(\.source.path)), ["主题/合成航线", "主题/合成记录"])
        XCTAssertTrue(result.layers.volatile.contains("cedar maple 当前航线"))
        XCTAssertTrue(result.layers.volatile.contains("合成钩子"))
        XCTAssertTrue(result.layers.volatile.contains("2020-01-01（已过期）"))
        XCTAssertFalse(result.layers.volatile.contains("不出站的历史"))
        XCTAssertTrue(result.decision.selected.allSatisfy { $0.source.kind == .page })
        await f.clean()
    }

    func testApprovedL1OnlyCardRendersExactL0L1AndAllPublicTargetsWithoutParentBody() async throws {
        let f = try RecallFullTextFixture(profileId: profileId)
        let card = try f.card(gist: "Orivale 的合成路线", mentions: [.init(name: "Orivale", group: "人", aliases: ["Veloria"])])
        try f.page(cards: [card])
        try f.page("项目/合成第二父页", now: "第二父页绝不扩展", cards: [card])
        let input = await fullTextInputs(f, "Orivale")
        let result = select("Orivale", inputs: input)
        XCTAssertEqual(result.decision.selected.map(\.source.kind), [.card])
        XCTAssertEqual(result.decision.selected.first?.source.path, card.path)
        XCTAssertEqual(result.decision.selected.first?.source.version, card.version)
        XCTAssertTrue(result.layers.volatile.contains(card.title))
        XCTAssertTrue(result.layers.volatile.contains(card.gist))
        XCTAssertTrue(result.layers.volatile.contains("Veloria"))
        XCTAssertTrue(result.layers.volatile.contains(card.path + "|" + card.version))
        XCTAssertTrue(result.layers.volatile.contains("[[主题/合成父页]]"))
        XCTAssertTrue(result.layers.volatile.contains("[[项目/合成第二父页]]"))
        XCTAssertFalse(result.layers.volatile.contains("父页当前正文"))
        XCTAssertFalse(result.layers.volatile.contains("第二父页绝不扩展"))
        let alias = select("Veloria", inputs: await fullTextInputs(f, "Veloria"))
        XCTAssertEqual(alias.decision.selected.map(\.source.path), [card.path])
        await f.clean()
    }

    func testX1SuppressesX2WhileX3StillSupplementsAndPinnedSourceAppearsOnlyInZ() async throws {
        let f = try RecallFullTextFixture(profileId: profileId)
        let card = try f.card(gist: "cedar maple 自动卡")
        try f.page(cards: [card])
        try f.page("人/合成人物", title: "Orivale", now: "X1 人物现在")
        let fragment = Memory(content: "合成碎片补充", category: "fact", profileId: profileId)
        fragment.occurredDay = "2026-10-28"
        fragment.reviewedAt = Date()
        let pinned = Memory(content: "钉住的合成来源", category: "fact", profileId: profileId, isUserExplicit: true)
        let text = "Orivale cedar maple"
        let input = await fullTextInputs(f, text, memories: [fragment, pinned])
        let result = select(text, inputs: input)
        XCTAssertTrue(result.decision.selected.contains { $0.source.path == "人/合成人物" })
        XCTAssertFalse(result.decision.selected.contains { $0.source.kind == .card })
        XCTAssertTrue(result.layers.volatile.contains(fragment.content))
        XCTAssertFalse(result.layers.volatile.contains(pinned.content))
        XCTAssertTrue(result.layers.stable.contains(pinned.content))
        let x2 = select("cedar maple", inputs: await fullTextInputs(f, "cedar maple", memories: [fragment]))
        XCTAssertEqual(x2.decision.selected.map(\.source.kind), [.card, .fragment])
        await f.clean()
    }

    func testPagesAndIndependentCardsShareThreeSlotsAndWholeBlockBudget() async throws {
        let f = try RecallFullTextFixture(profileId: profileId)
        let card = try f.card()
        try f.page("主题/合成甲", now: "cedar maple orivale 甲页")
        try f.page("主题/合成乙", now: "cedar maple orivale 乙页")
        try f.page(cards: [card])
        let second = try f.card("memory/cc/合成第二卡.md")
        try f.page("项目/合成另一父页", cards: [second])
        try f.page("地点/合成空甲")
        try f.page("地点/合成空乙")
        let input = await fullTextInputs(f, "cedar maple orivale")
        let result = select("cedar maple orivale", inputs: input)
        XCTAssertEqual(result.decision.selected.filter { $0.source.kind == .page }.count, 2)
        XCTAssertEqual(result.decision.selected.filter { $0.source.kind == .card }.count, 1)
        XCTAssertEqual(result.decision.stateAfterResponse.active, result.decision.selected)
        let oneCard = try XCTUnwrap(result.decision.candidates.first { $0.source.kind == .card })
        let tight = select("cedar maple orivale", inputs: await fullTextInputs(f, "cedar maple orivale", budget: 1))
        XCTAssertEqual(tight.decision.selected, [])
        XCTAssertTrue(tight.decision.suppressions.contains { $0.source == oneCard.source && $0.reason == .budget })
        XCTAssertEqual(tight.layers.volatile, "")
        await f.clean()
    }

    func testCardsSharingParentEachConsumeSlotAndSelectedParentCoversItsCards() async throws {
        let f = try RecallFullTextFixture(profileId: profileId)
        let cards = try (0..<4).map { try f.card("memory/cc/合成卡\($0).md") }
        try f.page(cards: cards)
        let result = select("cedar maple", inputs: await fullTextInputs(f, "cedar maple"))
        XCTAssertEqual(result.decision.selected.map(\.source.kind), [.card, .card, .card])
        try f.page(now: "cedar maple orivale 父页现在", cards: cards)
        let parent = select("cedar maple orivale", inputs: await fullTextInputs(f, "cedar maple orivale"))
        XCTAssertEqual(parent.decision.selected.map(\.source.path), ["主题/合成父页"])
        XCTAssertFalse(parent.layers.volatile.contains("条目："))
        await f.clean()
    }

    func testSnapshotMismatchBuildingAndRetainedCardValidityWithoutRefill() async throws {
        let f = try RecallFullTextFixture(profileId: profileId)
        try f.page(now: "cedar maple 旧页")
        var input = await fullTextInputs(f, "cedar maple")
        input.wiki?.pages[0].version = "different-generation"
        XCTAssertEqual(select("cedar maple", inputs: input).layers.volatile, "")
        let card = try f.card()
        try f.page(cards: [card])
        input = await fullTextInputs(f, "cedar maple")
        let first = select("cedar maple", inputs: input)
        var state = RecallConversationState()
        commit(first.decision, state: &state)
        let text = "cedar maple veloria orivale"
        let (snapshot, candidates) = await f.fetch(text, keeping: state.active.map(\.source))
        XCTAssertEqual(candidates.hits, [], "本轮证据覆盖不足，不是新命中")
        XCTAssertEqual(candidates.kept.map(\.path), [card.path])
        let retained = MemoryInjector.RoundInputs(memories: [], selfMemory: nil, archiveBudget: 4_000,
                                                  wiki: snapshot, fullText: candidates)
        let kept = select(text, turn: "u2", state: state, inputs: retained)
        XCTAssertEqual(kept.decision.gateReason, .kept)
        XCTAssertEqual(kept.decision.selected.map(\.source.path), [card.path])
        XCTAssertTrue(kept.layers.volatile.contains(card.gist))
        var timedOut = retained
        timedOut.fullText = .init(profileId: candidates.profileId, text: text, terms: [], weights: [:],
                                  status: .init(state: .empty, epoch: 0), hits: [], kept: candidates.kept)
        let afterTimeout = select(text, turn: "u2", state: state, inputs: timedOut)
        XCTAssertEqual(afterTimeout.decision.gateReason, .kept)
        XCTAssertEqual(afterTimeout.decision.selected, kept.decision.selected)
        var changed = retained
        changed.wiki?.pages[0].version = "different-parent-version"
        let stale = select(text, turn: "u2", state: state, inputs: changed)
        XCTAssertEqual(stale.decision.selected, [])
        XCTAssertEqual(stale.decision.suppressions.map(\.reason), [.unavailable])
        try f.page()
        let (revokedSnapshot, revokedCandidates) = await f.fetch(text, keeping: state.active.map(\.source))
        let revoked = select(text, turn: "u2", state: state,
                             inputs: .init(memories: [], selfMemory: nil, archiveBudget: 4_000,
                                           wiki: revokedSnapshot, fullText: revokedCandidates))
        XCTAssertEqual(revoked.decision.selected, [])
        XCTAssertEqual(revoked.decision.suppressions.map(\.reason), [.unavailable])
        let batch = input.fullText!
        input.fullText = .init(profileId: batch.profileId, text: batch.text, terms: batch.terms, weights: batch.weights,
                               status: .init(state: .building, epoch: batch.status.epoch), hits: batch.hits)
        XCTAssertEqual(select("cedar maple", inputs: input).layers.volatile, "")
        await f.clean()
    }

    func testEditsAndReferenceRevocationStopOldPayloadAtCandidateBoundary() async throws {
        let f = try RecallFullTextFixture(profileId: profileId)
        let card = try f.card()
        try f.page(now: "cedar maple 旧正文", cards: [card])
        let before = select("cedar maple", inputs: await fullTextInputs(f, "cedar maple"))
        XCTAssertTrue(before.layers.volatile.contains("旧正文"))
        try f.page(now: "veloria orivale 新正文")
        let after = select("cedar maple", inputs: await fullTextInputs(f, "cedar maple"))
        XCTAssertEqual(after.layers.volatile, "")
        XCTAssertEqual(SeedNoteStore(wiki: f.wiki).load(path: card.path, version: card.version), card)
        let fresh = select("veloria orivale", inputs: await fullTextInputs(f, "veloria orivale"))
        XCTAssertTrue(fresh.layers.volatile.contains("新正文"))
        await f.clean()
    }

    func testIneligibleSourcesNeverReachVolatileLayer() async throws {
        let f = try RecallFullTextFixture(profileId: profileId)
        let current = try f.card(gist: "cedar maple 公开要点\n[[人/private_合成]]")
        _ = try f.card(version: "v0", gist: "cedar maple 禁止旧版")
        _ = try f.card("memory/cc/合成孤卡.md", gist: "cedar maple 禁止孤卡")
        let privateCard = try f.card("memory/cc/PrIvAtE_合成.md", gist: "cedar maple 禁止私密")
        let escaping = try f.card("memory/../合成.md", gist: "cedar maple 禁止逃逸")
        let linked = try f.card("memory/cc/合成链接.md", gist: "cedar maple 禁止链接")
        let outside = f.root.appendingPathComponent("outside.json")
        try Data("cedar maple 禁止外部".utf8).write(to: outside)
        let folder = f.wiki.root.deletingLastPathComponent().appendingPathComponent("cc")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("合成链接.md"), withDestinationURL: outside)
        try f.page(cards: [current, privateCard, escaping, linked])
        try f.page("人/PRIVATE_合成", now: "cedar maple 禁止私密页")
        try FileManager.default.createSymbolicLink(at: f.wiki.root.appendingPathComponent("主题/合成链接页.md"), withDestinationURL: outside)
        let other = try RecallFullTextFixture()
        try other.page(now: "cedar maple 禁止跨层")
        _ = await other.fetch("cedar maple")
        let result = select("cedar maple", inputs: await fullTextInputs(f, "cedar maple"))
        XCTAssertEqual(result.decision.selected.map(\.source.path), [current.path])
        XCTAssertTrue(result.layers.volatile.contains("公开要点"))
        XCTAssertFalse(result.layers.volatile.contains("禁止"))
        XCTAssertFalse(result.layers.volatile.lowercased().contains("private_"))
        await f.clean()
        await other.clean()
    }

    func testUnrelatedCurrentSentenceNeverBorrowsHistoryOrPrefixTopHit() async throws {
        let f = try RecallFullTextFixture(profileId: profileId)
        try f.page(now: "cedar maple 上一题")
        let input = await fullTextInputs(f, "unrelated veloria")
        let result = select("unrelated veloria", inputs: input, recent: ["cedar maple", "unrelated veloria"])
        XCTAssertEqual(result.layers.volatile, "")
        try f.page(now: "cedarling maple 不是完整词")
        let prefix = select("cedar maple", inputs: await fullTextInputs(f, "cedar maple"))
        XCTAssertEqual(prefix.layers.volatile, "")
        await f.clean()
    }

    func testOverBudgetX1DoesNotBlockAffordableX2Card() async throws {
        let f = try RecallFullTextFixture(profileId: profileId)
        let card = try f.card(gist: "orivale cedar maple")
        try f.page(cards: [card])
        try f.page("人/合成大页", title: "Orivale", now: String(repeating: "合成正文", count: 200))
        let result = select("orivale cedar maple", inputs: await fullTextInputs(f, "orivale cedar maple", budget: 300))
        XCTAssertEqual(result.decision.selected.map(\.source.path), [card.path])
        XCTAssertTrue(result.decision.suppressions.contains { $0.source.path == "人/合成大页" && $0.reason == .budget })
        XCTAssertTrue(result.layers.volatile.contains(card.gist))
        await f.clean()
    }

    func testFirstSendBeforeWikiExistsDoesNotPoisonLaterApprovedCardSearch() async throws {
        let f = try RecallFullTextFixture(profileId: profileId)
        try FileManager.default.removeItem(at: f.wiki.root)
        let empty = select("cedar maple", inputs: await fullTextInputs(f, "cedar maple"))
        XCTAssertEqual(empty.layers.volatile, "")
        let card = try f.card()
        try f.page(cards: [card])
        let populated = select("cedar maple", inputs: await fullTextInputs(f, "cedar maple"))
        XCTAssertEqual(populated.decision.selected.map(\.source.path), [card.path])
        XCTAssertTrue(populated.layers.volatile.contains(card.gist))
        await f.clean()
    }

    func testNewPendingCooldownSuppressesSubstringX1ButStillAllowsX2() async throws {
        let f = try RecallFullTextFixture(profileId: profileId)
        let card = try f.card(gist: "party cedar maple")
        try f.page(cards: [card])
        try f.page("人/合成子串页", title: "art", now: "完全不同的合成旧题")
        let first = select("art 合成旧题", inputs: await fullTextInputs(f, "art 合成旧题"))
        var state = RecallConversationState()
        commit(first.decision, state: &state)
        XCTAssertEqual(state.pending.map(\.source.path), ["人/合成子串页"])
        let text = "party cedar maple"
        let result = select(text, turn: "u2", state: state, inputs: await fullTextInputs(f, text))
        XCTAssertEqual(result.decision.gateReason, .search)
        XCTAssertEqual(result.decision.ignored.map(\.path), ["人/合成子串页"])
        XCTAssertEqual(result.decision.selected.map(\.source.path), [card.path])
        XCTAssertTrue(result.decision.suppressions.contains { $0.source.path == "人/合成子串页" && $0.reason == .cooldown })
        XCTAssertTrue(result.layers.volatile.contains(card.gist))
        await f.clean()
    }

}
