import MemoryCore
import XCTest
@testable import 记忆花园

final class RecallTurnStateTests: XCTestCase {
    private let weights = RecallTokenWeights(documents: [], tuning: RecallTestTuning.make())

    private func item(_ path: String = "人/林栖", version: String = "v1", identities: [String] = ["林栖"], cost: Int = 10) -> RecallItem {
        RecallItem(source: RecallSourceRef(profileId: "岚舟", conversationId: "星砚", kind: .page, path: path, version: version),
                   text: "[[\(path)]] 云桥城的合成资料 \(version)", identities: identities, tokenCost: cost)
    }

    private func prepare(_ text: String, turn: String = "u1", state: RecallConversationState = .init(),
                         candidates: [RecallItem] = [], existing: RecallTurnDecision? = nil,
                         budget: Int = 100, enabled: Bool = true, branch: String = "branch",
                         tuning: RecallTuning = RecallTestTuning.make(),
                         resolve: ((RecallItem) -> RecallItem?)? = nil) -> RecallTurnDecision {
        RecallTurnState.prepare(turnId: turn, branchAnchor: branch, text: text, state: state,
                                existingDecision: existing, enabled: enabled, tuning: tuning, weights: weights, budget: budget,
                                resolve: resolve ?? { $0 }, search: { _ in candidates })
    }

    private func respond(_ decision: RecallTurnDecision, state: inout RecallConversationState) -> RecallTurnReceipt {
        var receipt = RecallTurnReceipt(decision: decision)
        let id = receipt.beginAttempt()
        receipt.markAttempt(id, status: .submitted)
        XCTAssertTrue(receipt.recordResponse(attemptId: id, state: &state, currentTurnId: decision.turnId,
                                             currentBranchAnchor: decision.branchAnchor))
        return receipt
    }

    func testNFKCLengthCountsOnlyLettersAndDigits() {
        for text in ["嗯", "好呀！", "💫🙂！", "ＡＢ１２".dropLast().description, "a1。💫"] {
            let decision = prepare(text, candidates: [item()])
            XCTAssertEqual(decision.gateReason, .shortInput, text)
            XCTAssertTrue(decision.selected.isEmpty)
            XCTAssertEqual(decision.stateAfterResponse.effectiveTurn, 0)
        }
        XCTAssertEqual(prepare("ＡＢ１２", candidates: [item()]).gateReason, .search)
        XCTAssertEqual(RecallLexical.meaningfulLength("ＡＢ１２ 💫"), 4)
        XCTAssertEqual(RecallLexical.meaningfulLength("1️⃣2️⃣3️⃣4️⃣"), 4)
        XCTAssertEqual(prepare("1️⃣2️⃣3️⃣4️⃣", candidates: [item()]).gateReason, .search)
        XCTAssertEqual(prepare("1️⃣2️⃣3️⃣", candidates: [item()]).gateReason, .shortInput)
        XCTAssertEqual(prepare("👩‍💻👨‍👩‍👧‍👦", candidates: [item()]).gateReason, .shortInput)
    }

    func testRetrospectiveGrammarPrecedesShortGateWithoutThawingEverything() {
        for text in ["刚才", "刚才呢", "刚刚？", "今早呢", "昨晚呢", "上周一", "上周天呢", "上个月", "昨天？", "上次呢", "记得吗", "还记得吗", "之前说过什么", "我提过云桥城", "[[人/林栖]]", "来源:人/林栖"] {
            XCTAssertTrue(RecallLexical.retrospective(text), text)
            XCTAssertEqual(prepare(text).gateReason, .search, text)
        }
        for text in ["昨天气球", "刚才气球", "刚刚好", "今早气球", "上周八", "上个月亮", "👩‍💻", "1️⃣", "记忆宫殿", "回忆录", "我说现在", "2026-02-30", "2026-13-02", "2026-10-99"] {
            XCTAssertFalse(RecallLexical.retrospective(text), text)
        }
        XCTAssertTrue(RecallLexical.retrospective("2026年10月28日"))
        XCTAssertTrue(RecallLexical.retrospective("2024-02-29"))
        XCTAssertFalse(RecallLexical.retrospective("2025-02-29"))
    }

    func testPreviewAndCancelledAttemptCannotCreatePendingOrAdvance() {
        let initial = RecallConversationState()
        let decision = prepare("林栖的云桥城计划", state: initial, candidates: [item()])
        XCTAssertEqual(initial, RecallConversationState())
        XCTAssertEqual(decision.selected, [item()])
        XCTAssertEqual(decision.stateAfterResponse.pending, [item()])
        var receipt = RecallTurnReceipt(decision: decision)
        let id = receipt.beginAttempt()
        receipt.markAttempt(id, status: .submitted)
        receipt.finishAttempt(id: id, status: .cancelled)
        var state = initial
        XCTAssertFalse(receipt.recordResponse(attemptId: id, state: &state, currentTurnId: "u1", currentBranchAnchor: "branch"))
        XCTAssertEqual(state, initial)
        XCTAssertEqual(RecallTurnState.recover(receipts: [receipt], branchAnchor: "branch").effectiveTurn, 0)
    }

    func testShortRoundPreservesActivePendingAndCooldownWithoutSearch() {
        var state = RecallConversationState()
        _ = respond(prepare("林栖的云桥城计划", candidates: [item()]), state: &state)
        state.cooldowns = [.init(source: item("地点/云桥城").source, untilTurn: 4)]
        var calls = 0
        let decision = RecallTurnState.prepare(turnId: "u2", branchAnchor: "branch", text: "🙂嗯", state: state,
                                               tuning: RecallTestTuning.make(), weights: weights, budget: 100, resolve: { $0 }, search: { _ in calls += 1; return [] })
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(decision.selected.isEmpty)
        XCTAssertEqual(decision.stateAfterResponse.active, state.active)
        XCTAssertEqual(decision.stateAfterResponse.pending, state.pending)
        XCTAssertEqual(decision.stateAfterResponse.cooldowns, state.cooldowns)
        XCTAssertEqual(decision.stateAfterResponse.effectiveTurn, 1)
    }

    func testExactIdentityKeepsSameVersionWithZeroSearch() {
        var state = RecallConversationState()
        _ = respond(prepare("林栖的云桥城计划", candidates: [item()]), state: &state)
        var calls = 0
        let decision = RecallTurnState.prepare(turnId: "u2", branchAnchor: "branch", text: "林栖后来怎么安排", state: state,
                                               tuning: RecallTestTuning.make(), weights: weights, budget: 100, resolve: { $0 }, search: { _ in calls += 1; return [] })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(decision.gateReason, .kept)
        XCTAssertEqual(decision.selected, [item()])
        XCTAssertTrue(decision.stateAfterResponse.pending.isEmpty, "Continuation is evidence against ignored-push cooldown")
    }

    func testTwoValidTokensAndIDFOverlapThreshold() {
        let common = Set(["cedar", "maple"])
        let corpus = RecallTokenWeights(tokenDocuments: Array(repeating: common, count: 10))
        XCTAssertEqual(corpus.weight("cedar"), 1, accuracy: 0.000001)
        XCTAssertEqual(corpus.weight("quartz"), log(11.0) + 1, accuracy: 0.000001)
        XCTAssertTrue(corpus.continues("cedar maple", anchor: "cedar maple quartz", active: [], tuning: RecallTestTuning.make()))
        XCTAssertFalse(corpus.continues("cedar willow", anchor: "cedar maple", active: [], tuning: RecallTestTuning.make()), "One shared word is insufficient")
        XCTAssertFalse(corpus.continues("cedar maple willow birch", anchor: "cedar maple quartz topaz", active: [], tuning: RecallTestTuning.make()), "Two common words cannot outweigh distinct rare words")
        XCTAssertFalse(corpus.continues("a b 12", anchor: "a b 12", active: [], tuning: RecallTestTuning.make()))
        XCTAssertFalse(RecallLexical.names(["art"], in: "party nearby", tuning: RecallTestTuning.make()))
        XCTAssertTrue(RecallLexical.names(["ART"], in: "the art plan", tuning: RecallTestTuning.make()))
    }

    func testCorpusWeightsStayLazyForShortDisabledReplayAndColdSearch() {
        var builds = 0
        func corpus() -> RecallTokenWeights { builds += 1; return weights }
        let initial = prepare("林栖的云桥城计划", candidates: [item()])
        var active = initial.stateAfterResponse
        active.branchAnchor = "branch"
        for (text, state, enabled, existing) in [
            ("🙂", active, true, nil),
            ("林栖的云桥城计划", active, false, nil),
            ("工具续轮", active, true, Optional(initial)),
            ("云桥城的新话题", RecallConversationState(), true, nil)
        ] {
            _ = RecallTurnState.prepare(turnId: "u1", branchAnchor: "branch", text: text, state: state,
                existingDecision: existing, enabled: enabled, tuning: RecallTestTuning.make(),
                weights: corpus(), budget: 100, resolve: { $0 }, search: { _ in [] })
        }
        XCTAssertEqual(builds, 0)
        let kept = RecallTurnState.prepare(turnId: "u2", branchAnchor: "branch", text: "林栖后来如何安排", state: active,
            tuning: RecallTestTuning.make(), weights: corpus(), budget: 100, resolve: { $0 }, search: { _ in [] })
        XCTAssertEqual(kept.gateReason, .kept)
        XCTAssertEqual(builds, 1)
    }

    func testCJKIdentityBoundariesControlBothKeepingAndThawing() {
        var singleHan = RecallTestTuning.make()
        singleHan.minimumHanTermLength = 1
        var longerHan = RecallTestTuning.make()
        longerHan.minimumHanTermLength = 3
        let cases: [(String, String, RecallTuning, Bool)] = [
            ("山田", "请讲 山田 的近况", RecallTestTuning.make(), true),
            ("山田", "请讲 山田屋 的近况", RecallTestTuning.make(), false),
            ("山田", "请讲山田屋的近况", RecallTestTuning.make(), false),
            ("山田", "请讲 山田 的近况", longerHan, false),
            ("猫", "请讲 猫 的近况", RecallTestTuning.make(), false),
            ("猫", "请讲 猫 的近况", singleHan, true),
            ("猫", "请讲 熊猫 的近况", singleHan, false)
        ]
        for (identity, text, tuning, matches) in cases {
            let page = item("人/\(identity)", identities: [identity])
            var active = RecallConversationState()
            active.branchAnchor = "branch"
            active.active = [page]
            active.pending = [page]
            active.topicAnchor = "quartz topaz"
            let keep = prepare(text, state: active, tuning: tuning)
            XCTAssertEqual(keep.gateReason, matches ? .kept : .search, text)
            XCTAssertEqual(keep.selected, matches ? [page] : [], text)
            XCTAssertEqual(keep.ignored, matches ? [] : [page.source], text)

            var frozen = RecallConversationState()
            frozen.branchAnchor = "branch"
            frozen.cooldowns = [.init(source: page.source, untilTurn: 4, identities: [identity])]
            let thaw = prepare(text, state: frozen, candidates: [page], tuning: tuning)
            XCTAssertEqual(thaw.selected, matches ? [page] : [], text)
            XCTAssertEqual(thaw.thawed, matches ? [page.source] : [], text)
            XCTAssertEqual(thaw.stateAfterResponse.cooldowns.count, matches ? 0 : 1, text)
            let withoutCandidate = prepare(text, state: frozen, tuning: tuning)
            XCTAssertEqual(withoutCandidate.thawed, matches ? [page.source] : [], text)
        }
    }

    func testSourceOperatorsShareGateAndExactTargetingIncludingSingleHanTitles() {
        let page = item(identities: [])
        let neighbor = item("人/林栖屋", identities: [])
        let single = item("猫", identities: ["猫"])
        var frozen = RecallConversationState()
        frozen.branchAnchor = "branch"
        frozen.cooldowns = [page, neighbor, single].map { .init(source: $0.source, untilTurn: 4) }
        for prefix in ["source:", "source：", "来源:", "来源：", "页:", "页：", "fragment:", "fragment：", "碎片:", "碎片："] {
            for gap in ["", " "] {
                let decision = prepare(prefix + gap + page.source.path, state: frozen, candidates: [page, neighbor, single])
                XCTAssertEqual(decision.gateReason, .search, prefix)
                XCTAssertEqual(decision.selected, [page], prefix)
                XCTAssertEqual(decision.thawed, [page.source], prefix)
            }
            let short = prepare(prefix + "猫", state: frozen, candidates: [page, single])
            XCTAssertEqual(short.gateReason, .search, prefix)
            XCTAssertEqual(short.selected, [single], prefix)
            var active = RecallConversationState()
            active.branchAnchor = "branch"
            active.active = [single]
            active.topicAnchor = "quartz topaz"
            let kept = prepare(prefix + "猫", state: active)
            XCTAssertEqual(kept.gateReason, .kept, prefix)
            XCTAssertEqual(kept.selected, [single], prefix)
        }
        for text in ["[[人/林栖]]", "memory/wiki/人/林栖.md"] {
            XCTAssertEqual(prepare(text, state: frozen, candidates: [page, neighbor]).selected, [page], text)
        }
        for text in ["页:人/林栖屋", "来源:人/林栖屋"] {
            XCTAssertEqual(prepare(text, state: frozen, candidates: [page, neighbor]).selected, [neighbor], text)
        }
        for text in ["网页:猫", "resource:猫", "my_source:猫", "页:猫屋", "memory/wiki/猫.md.backup"] {
            let decision = prepare(text, state: frozen, candidates: [single])
            XCTAssertTrue(decision.thawed.isEmpty, text)
            XCTAssertTrue(decision.selected.isEmpty, text)
            var active = RecallConversationState()
            active.branchAnchor = "branch"
            active.active = [single]
            active.topicAnchor = "quartz topaz"
            var openGate = RecallTestTuning.make()
            openGate.minimumEffectiveLength = 1
            XCTAssertEqual(prepare(text, state: active, tuning: openGate).gateReason, .search, text)
        }
        var highGate = RecallTestTuning.make()
        highGate.minimumEffectiveLength = 100
        for text in ["网页:猫", "resource:猫", "my_source:猫", "memory/wiki/猫.md.backup"] {
            XCTAssertEqual(prepare(text, tuning: highGate).gateReason, .shortInput, text)
        }
    }

    func testTemporalGrammarOpensSearchWithoutKeepingOrThawingUnrelatedIdentity() {
        let page = item()
        var active = RecallConversationState()
        active.branchAnchor = "branch"
        active.active = [page]
        active.topicAnchor = "quartz topaz"
        var frozen = RecallConversationState()
        frozen.branchAnchor = "branch"
        frozen.cooldowns = [.init(source: page.source, untilTurn: 4, identities: page.identities)]
        for text in ["刚才呢", "刚刚", "今早", "昨晚", "上周一", "上周日", "上个月"] {
            let changed = prepare(text, state: active)
            XCTAssertEqual(changed.gateReason, .search, text)
            XCTAssertTrue(changed.selected.isEmpty, text)
            let blocked = prepare(text, state: frozen, candidates: [page])
            XCTAssertEqual(blocked.gateReason, .search, text)
            XCTAssertTrue(blocked.thawed.isEmpty, text)
            XCTAssertTrue(blocked.selected.isEmpty, text)
        }
    }

    func testKeepRevalidatesVersionPermissionAndBudgetWithoutRefill() {
        for mode in 0..<3 {
            var state = RecallConversationState()
            _ = respond(prepare("林栖的云桥城计划", candidates: [item()]), state: &state)
            var searches = 0
            let decision = RecallTurnState.prepare(turnId: "u2", branchAnchor: "branch", text: "林栖后来怎么安排", state: state,
                                                   tuning: RecallTestTuning.make(), weights: weights, budget: mode == 2 ? 9 : 100,
                                                   resolve: { old in mode == 0 ? nil : mode == 1 ? self.item(version: "v2") : old },
                                                   search: { _ in searches += 1; return [self.item("地点/云桥城")] })
            XCTAssertEqual(searches, 0)
            XCTAssertEqual(decision.gateReason, .kept)
            XCTAssertTrue(decision.selected.isEmpty)
            XCTAssertTrue(decision.stateAfterResponse.active.isEmpty)
            XCTAssertEqual(decision.suppressions.first?.reason, mode == 2 ? .budget : .unavailable)
        }
    }

    func testDiscussedPageDoesNotEnterCooldownOnLaterTopicChange() {
        var state = RecallConversationState()
        _ = respond(prepare("林栖的云桥城计划", candidates: [item()]), state: &state)
        _ = respond(prepare("林栖后来怎么安排", turn: "u2", state: state), state: &state)
        let change = prepare("另一个独立的新问题", turn: "u3", state: state)
        XCTAssertTrue(change.ignored.isEmpty)
        XCTAssertTrue(change.stateAfterResponse.cooldowns.isEmpty)
    }

    func testThreeEffectiveTurnCooldownAndRestartBoundary() throws {
        var state = RecallConversationState()
        let first = respond(prepare("林栖的云桥城计划", candidates: [item()]), state: &state)
        let secondDecision = prepare("另一个独立的新问题", turn: "u2", state: state, candidates: [item()])
        XCTAssertEqual(state.effectiveTurn, 1, "Preview does not confirm ignored")
        XCTAssertTrue(secondDecision.selected.isEmpty)
        XCTAssertEqual(secondDecision.stateAfterResponse.cooldowns.first?.untilTurn, 4)
        let second = respond(secondDecision, state: &state)
        let roundtrip = try JSONDecoder().decode([RecallTurnReceipt].self, from: JSONEncoder().encode([first, second]))
        state = RecallTurnState.recover(receipts: roundtrip, branchAnchor: "branch", clearActive: false)
        XCTAssertEqual(state.effectiveTurn, 2)
        for n in 3...4 {
            let d = prepare("另外一个完全独立问题", turn: "u\(n)", state: state, candidates: [item()])
            XCTAssertTrue(d.selected.isEmpty, "n, n+1, n+2 all suppressed")
            XCTAssertEqual(d.suppressions.first?.reason, .cooldown)
            _ = respond(d, state: &state)
        }
        let released = prepare("另外一个完全独立问题", turn: "u5", state: state, candidates: [item()])
        XCTAssertEqual(released.selected, [item()], "n+3 naturally expires")
    }

    func testTargetedThawDoesNotReleaseOtherSourcesOrNewVersions() {
        let a = item(), b = item("地点/云桥城", identities: ["云桥城"])
        var state = RecallConversationState()
        state.branchAnchor = "branch"
        state.effectiveTurn = 2
        state.cooldowns = [.init(source: a.source, untilTurn: 4), .init(source: b.source, untilTurn: 4)]
        let generic = prepare("昨天？", turn: "u3", state: state, candidates: [a, b])
        XCTAssertTrue(generic.selected.isEmpty)
        XCTAssertEqual(generic.stateAfterResponse.cooldowns.count, 2)
        let named = prepare("请再讲林栖的近况", turn: "u3", state: state, candidates: [a, b])
        XCTAssertEqual(named.selected, [a])
        XCTAssertEqual(named.stateAfterResponse.cooldowns.map(\.source), [b.source])
        let source = prepare("[[人/林栖]]", turn: "u3", state: state, candidates: [a, b])
        XCTAssertEqual(source.selected, [a])
        let newVersion = prepare("另一个独立的新问题", turn: "u3", state: state, candidates: [item(version: "v2")])
        XCTAssertEqual(newVersion.selected.map(\.source.version), ["v2"], "Old-version cooldown never freezes a new source version")
    }

    func testRetryRegenerationAndContinuationRevalidateWithoutRejudgeOrDoubleCommit() {
        var state = RecallConversationState()
        let original = prepare("林栖的云桥城计划", candidates: [item()])
        var receipt = respond(original, state: &state)
        var searches = 0
        let replay = RecallTurnState.prepare(turnId: "u1", branchAnchor: "rebased", text: "完全不同的工具摘要", state: state,
                                             existingDecision: original, tuning: RecallTestTuning.make(), weights: weights, budget: 9, resolve: { $0 },
                                             search: { _ in searches += 1; return [] })
        XCTAssertEqual(searches, 0)
        XCTAssertEqual(replay.origin, .continuation)
        XCTAssertEqual(replay.topicAnchor, original.topicAnchor)
        XCTAssertEqual(replay.branchAnchor, "rebased")
        XCTAssertEqual(replay.stateAfterResponse.effectiveTurn, 1)
        XCTAssertTrue(replay.selected.isEmpty)
        receipt.decision = replay
        let retry = receipt.beginAttempt(id: "retry")
        receipt.markAttempt(retry, status: .submitted)
        state.effectiveTurn = 4
        state.lastAppliedTurnId = "u4"
        XCTAssertFalse(receipt.recordResponse(attemptId: retry, state: &state, currentTurnId: "u1", currentBranchAnchor: "rebased"))
        XCTAssertEqual(state.effectiveTurn, 4)
        receipt.finishAttempt(id: retry, status: .cancelled)
        XCTAssertEqual(receipt.attempts.last?.status, .interrupted)
        XCTAssertTrue(receipt.hasEffectiveResponse)
    }

    func testFailedFirstAttemptRetryCommitsOnlyFirstEffectiveEvent() {
        var state = RecallConversationState()
        var receipt = RecallTurnReceipt(decision: prepare("林栖的云桥城计划", candidates: [item()]))
        let first = receipt.beginAttempt(id: "first")
        receipt.markAttempt(first, status: .submitted)
        receipt.finishAttempt(id: first, status: .failed)
        XCTAssertFalse(receipt.hasEffectiveResponse)
        let second = receipt.beginAttempt(id: "second")
        receipt.markAttempt(second, status: .submitted)
        XCTAssertTrue(receipt.recordResponse(attemptId: second, state: &state, currentTurnId: "u1", currentBranchAnchor: "branch"))
        XCTAssertFalse(receipt.recordResponse(attemptId: second, state: &state, currentTurnId: "u1", currentBranchAnchor: "branch"))
        XCTAssertEqual(state.effectiveTurn, 1)
        XCTAssertEqual(state.pending, [item()])
    }

    func testRecoveryUsesSelectedPathReceiptsAndRejectsLateBranchEvent() {
        var state = RecallConversationState()
        let a = respond(prepare("林栖的云桥城计划", candidates: [item()]), state: &state)
        let b = respond(prepare("另外一个完全独立问题", turn: "u2", state: state), state: &state)
        let pathA = RecallTurnState.recover(receipts: [a, a], branchAnchor: "new-branch")
        XCTAssertEqual(pathA.effectiveTurn, 1)
        XCTAssertTrue(pathA.active.isEmpty)
        XCTAssertTrue(pathA.pending.isEmpty)
        XCTAssertTrue(pathA.cooldowns.isEmpty, "Sibling branch ignored evidence is absent")
        XCTAssertEqual(RecallTurnState.recover(receipts: [a, b], branchAnchor: "other").cooldowns.count, 1)
        var late = RecallTurnReceipt(decision: prepare("林栖的云桥城计划", turn: "late", candidates: [item()]))
        let id = late.beginAttempt()
        late.markAttempt(id, status: .submitted)
        var restored = pathA
        XCTAssertFalse(late.recordResponse(attemptId: id, state: &restored, currentTurnId: "late", currentBranchAnchor: "new-branch"))
        XCTAssertFalse(late.hasEffectiveResponse)
        XCTAssertEqual(restored, pathA)
    }

    func testDisabledClearsActiveAndPendingButPreservesCooldown() {
        var state = RecallConversationState()
        _ = respond(prepare("林栖的云桥城计划", candidates: [item()]), state: &state)
        state.cooldowns = [.init(source: item("地点/云桥城").source, untilTurn: 4)]
        let decision = prepare("林栖的后续近况", turn: "u2", state: state, candidates: [item()], enabled: false)
        XCTAssertEqual(decision.gateReason, .disabled)
        XCTAssertTrue(decision.selected.isEmpty)
        XCTAssertTrue(decision.stateAfterResponse.active.isEmpty)
        XCTAssertTrue(decision.stateAfterResponse.pending.isEmpty)
        XCTAssertEqual(decision.stateAfterResponse.cooldowns, state.cooldowns)
        XCTAssertEqual(decision.stateAfterResponse.effectiveTurn, 1)
    }

    func testPageLimitAndBudgetAreAppliedToExactPayloadItems() {
        let candidates = (1...4).map { item("主题/合成\($0)") }
        let decision = prepare("合成资料的独立问题", candidates: candidates)
        XCTAssertEqual(decision.selected.count, 3)
        XCTAssertEqual(decision.suppressions.last?.reason, .pageLimit)
        let budget = prepare("合成资料的独立问题", candidates: candidates, budget: 19)
        XCTAssertEqual(budget.selected.count, 1)
        XCTAssertEqual(budget.stateAfterResponse.active, budget.selected)
        XCTAssertEqual(budget.selected.first?.text, candidates.first?.text)
    }

    func testDuplicationRemapsAllScopedFacts() {
        var state = RecallConversationState()
        var receipt = respond(prepare("林栖的云桥城计划", candidates: [item()]), state: &state)
        receipt.reads = [.init(toolCallId: "tool", turnId: "u1", layer: "fragment", target: "u1")]
        let copy = receipt.remapped(from: "星砚", conversationId: "new-window", nodeIds: ["u1": "new-u1", "branch": "new-branch"])
        XCTAssertEqual(copy.decision.turnId, "new-u1")
        XCTAssertEqual(copy.decision.branchAnchor, "new-branch")
        XCTAssertEqual(copy.decision.selected.first?.source.conversationId, "new-window")
        XCTAssertEqual(copy.decision.stateAfterResponse.pending.first?.source.conversationId, "new-window")
        XCTAssertEqual(copy.decision.stateAfterResponse.lastAppliedTurnId, "new-u1")
        XCTAssertEqual(copy.reads.first?.target, "new-u1")
        XCTAssertTrue(copy.hasEffectiveResponse)
    }

    func testStructuredReadTargetsRemapWithCopiedConversation() throws {
        var receipt = RecallTurnReceipt(decision: prepare("林栖的云桥城计划"))
        let target = RecallTool.Target(tree: "a", layer: "messages", conversationId: "old-window",
            lastNodeId: "last", fromNodeId: "from", toNodeIdExclusive: "to")
        receipt.reads = [.init(toolCallId: "call", turnId: "u1", layer: "原文", target: RecallTool.json(target),
                              returnedRange: [target], next: .init(hasMore: true, cursorIssued: true))]
        let copy = receipt.remapped(from: "old-window", conversationId: "new-window",
                                    nodeIds: ["u1": "new-u1", "from": "new-from", "to": "new-to", "last": "new-last"])
        let read = try XCTUnwrap(copy.reads.first)
        let remapped = try RecallTool.decoder.decode(RecallTool.Target.self, from: Data(read.target.utf8))
        XCTAssertEqual(read.turnId, "new-u1")
        XCTAssertEqual(remapped.conversationId, "new-window")
        XCTAssertEqual(remapped.fromNodeId, "new-from")
        XCTAssertEqual(remapped.toNodeIdExclusive, "new-to")
        XCTAssertEqual(remapped.lastNodeId, "new-last")
        XCTAssertEqual(read.returnedRange, [remapped])
        XCTAssertEqual(read.next, .init(hasMore: true, cursorIssued: true))
    }

    func testCopyPreservesReadTargetsAndRangesFromAnotherWindow() throws {
        var receipt = RecallTurnReceipt(decision: prepare("林栖的云桥城计划"))
        let target = RecallTool.Target(tree: "a", layer: "window", conversationId: "other-window")
        let range = RecallTool.Target(tree: "a", layer: "messages", conversationId: "other-window",
            lastNodeId: "other-last", fromNodeId: "other-from", toNodeIdExclusive: "other-to")
        receipt.reads = [.init(toolCallId: "call", turnId: "u1", layer: "A3", target: RecallTool.json(target),
                              returnedRange: [range])]
        let copy = receipt.remapped(from: "old-window", conversationId: "new-window", nodeIds: ["u1": "new-u1"])
        let read = try XCTUnwrap(copy.reads.first)
        let copiedTarget = try RecallTool.decoder.decode(RecallTool.Target.self, from: Data(read.target.utf8))
        XCTAssertEqual(copiedTarget, target)
        XCTAssertEqual(read.returnedRange, [range])
        XCTAssertEqual(read.turnId, "new-u1")

        let ownWindow = RecallTool.Target(tree: "a", layer: "window", conversationId: "old-window")
        receipt.reads = [.init(toolCallId: "call", turnId: "u1", layer: "A3", target: RecallTool.json(ownWindow),
                              returnedRange: [range])]
        let ownCopy = receipt.remapped(from: "old-window", conversationId: "new-window", nodeIds: ["u1": "new-u1"])
        let copiedWindow = try RecallTool.decoder.decode(RecallTool.Target.self, from: Data(ownCopy.reads[0].target.utf8))
        XCTAssertEqual(copiedWindow.conversationId, "new-window")
        XCTAssertEqual(ownCopy.reads[0].returnedRange, [range])
    }

    func testReadReceiptOldMissingRangeIsUnknownAndNewRangesSurvivePersistence() throws {
        let old = Data(#"{"toolCallId":"call","turnId":"u1","layer":"A4","target":"星砚","status":"success"}"#.utf8)
        let legacy = try JSONDecoder().decode(RecallReadReceipt.self, from: old)
        XCTAssertNil(legacy.returnedRange)
        XCTAssertNil(legacy.next)
        let row = RecallWikiRowTarget(page: .init(profileId: "岚舟", path: "人/星砚", version: "v1"),
                                             ordinal: 2, lineHash: "row-hash")
        let range = RecallTool.Target(tree: "c", layer: "entry", row: row)
        let read = RecallReadReceipt(toolCallId: "call", turnId: "u1", layer: "wiki页", target: "星砚",
                                     returnedRange: [range], next: .init(hasMore: true, cursorIssued: true))
        let stored = try JSONDecoder().decode(RecallReadReceipt.self, from: JSONEncoder().encode(read))
        XCTAssertEqual(stored.returnedRange?.first?.row?.page.path, "人/星砚")
        XCTAssertEqual(stored.returnedRange?.first?.row?.ordinal, 2)
        XCTAssertEqual(stored.next, .init(hasMore: true, cursorIssued: true))
        let copy = RecallTurnReceipt(decision: prepare("林栖的云桥城计划"))
        var original = copy
        original.reads = [stored]
        let remapped = original.remapped(from: "星砚", conversationId: "new-window", nodeIds: ["u1": "new-u1"])
        XCTAssertEqual(remapped.reads.first?.returnedRange, [range], "外部 wiki 定位不随对话拷贝改变")
    }

    func testInterruptedEffectiveSendRemainsRecoverable() {
        var state = RecallConversationState()
        var receipt = respond(prepare("林栖的云桥城计划", candidates: [item()]), state: &state)
        let attempt = receipt.attempts[0].id
        receipt.finishAttempt(id: attempt, status: .cancelled)
        XCTAssertEqual(receipt.attempts[0].status, .interrupted)
        let restored = RecallTurnState.recover(receipts: [receipt], branchAnchor: "branch", clearActive: false)
        XCTAssertEqual(restored.effectiveTurn, 1)
        XCTAssertEqual(restored.pending, [item()])
        XCTAssertEqual(restored.active, [item()])
    }

    func testFailedDisabledSendIsDurableClearOnlyBoundary() {
        var state = RecallConversationState()
        let first = respond(prepare("林栖的云桥城计划", candidates: [item()]), state: &state)
        var disabled = RecallTurnReceipt(decision: prepare("林栖后来怎样安排", turn: "u2", state: state, enabled: false))
        let attempt = disabled.beginAttempt()
        disabled.markAttempt(attempt, status: .submitted)
        disabled.finishAttempt(id: attempt, status: .failed)
        let recovered = RecallTurnState.recover(receipts: [first, disabled], branchAnchor: "branch", clearActive: false)
        XCTAssertEqual(recovered.effectiveTurn, 1)
        XCTAssertEqual(recovered.lastAppliedTurnId, "u1")
        XCTAssertTrue(recovered.active.isEmpty)
        XCTAssertTrue(recovered.pending.isEmpty)
        XCTAssertTrue(recovered.cooldowns.isEmpty)
        let afterReenable = prepare("🙂", turn: "u3", state: recovered)
        XCTAssertTrue(afterReenable.stateAfterResponse.active.isEmpty)
        XCTAssertTrue(afterReenable.stateAfterResponse.pending.isEmpty)
    }
    func testNondefaultTuningControlsGateOverlapPagesCooldownAndReplay() {
        var tuning = RecallTestTuning.make()
        tuning.minimumEffectiveLength = 8
        tuning.minimumSharedTerms = 1
        tuning.activeOverlapThreshold = 0.2
        tuning.maximumPages = 1
        tuning.cooldownTurns = 5
        XCTAssertEqual(prepare("ＡＢ１２", tuning: tuning).gateReason, .shortInput)
        XCTAssertEqual(prepare("昨天？", tuning: tuning).gateReason, .search)
        XCTAssertTrue(weights.continues("cedar willow", anchor: "cedar maple", active: [], tuning: tuning))
        tuning.activeOverlapThreshold = 0.9
        XCTAssertFalse(weights.continues("cedar willow", anchor: "cedar maple", active: [], tuning: tuning))
        let a = item(), b = item("地点/云桥城", identities: ["云桥城"])
        var state = RecallConversationState()
        let first = respond(prepare("林栖计划以及云桥城资料", candidates: [a, b], tuning: tuning), state: &state)
        XCTAssertEqual(first.decision.selected, [a])
        let ignored = prepare("完全独立的另外一个问题", turn: "u2", state: state, tuning: tuning)
        XCTAssertEqual(ignored.stateAfterResponse.cooldowns.first?.untilTurn, 6)
        let second = respond(ignored, state: &state)
        XCTAssertEqual(RecallTurnState.recover(receipts: [first, second], branchAnchor: "branch").cooldowns.first?.untilTurn, 6)
        let replay = prepare("无关", state: state, existing: first.decision, tuning: RecallTestTuning.make())
        XCTAssertEqual(replay.tuning, tuning)
        XCTAssertEqual(replay.stateAfterResponse.effectiveTurn, 1)
    }

    func testCooldownSwitchUsesZeroWithoutRewritingStoredTurnCount() throws {
        var tuning = RecallTestTuning.make()
        tuning.cooldownTurns = 9
        let page = item()
        var initial = RecallConversationState()
        _ = respond(prepare("林栖的合成计划", candidates: [page], tuning: tuning), state: &initial)
        let frozen = prepare("完全独立的另外一个问题", turn: "u2", state: initial, candidates: [page], tuning: tuning)
        XCTAssertTrue(frozen.selected.isEmpty)
        XCTAssertEqual(frozen.suppressions.first?.reason, .cooldown)
        tuning.cooldownEnabled = false
        let disabled = prepare("完全独立的另外一个问题", turn: "u2", state: initial, candidates: [page], tuning: tuning)
        var zero = tuning
        zero.cooldownEnabled = true
        zero.cooldownTurns = 0
        let explicitZero = prepare("完全独立的另外一个问题", turn: "u2", state: initial, candidates: [page], tuning: zero)
        XCTAssertEqual(disabled.selected, [page])
        XCTAssertEqual(disabled.selected, explicitZero.selected)
        XCTAssertEqual(disabled.stateAfterResponse, explicitZero.stateAfterResponse)
        XCTAssertEqual(disabled.tuning.cooldownTurns, 9)
        XCTAssertFalse(disabled.tuning.cooldownEnabled)
        let receipt = RecallTurnReceipt(decision: disabled)
        let reopened = try JSONDecoder().decode(RecallTurnReceipt.self, from: JSONEncoder().encode(receipt))
        XCTAssertEqual(reopened.decision.tuning.cooldownTurns, 9)
        var offState = initial
        let offReceipt = respond(disabled, state: &offState)
        var zeroState = initial
        let zeroReceipt = respond(explicitZero, state: &zeroState)
        XCTAssertEqual(RecallTurnState.recover(receipts: [offReceipt], branchAnchor: "branch"),
                       RecallTurnState.recover(receipts: [zeroReceipt], branchAnchor: "branch"))
        tuning.cooldownEnabled = true
        XCTAssertTrue(prepare("完全独立的另外一个问题", turn: "u2", state: initial, candidates: [page], tuning: tuning).selected.isEmpty)
    }

    func testContinuationEvidenceIsPerPendingSource() {
        let a = item(), b = item("地点/云桥城", identities: ["云桥城"])
        var state = RecallConversationState()
        _ = respond(prepare("林栖以及云桥城合成计划", candidates: [a, b]), state: &state)
        let kept = prepare("林栖后来如何安排", turn: "u2", state: state)
        XCTAssertEqual(kept.gateReason, .kept)
        XCTAssertEqual(kept.ignored, [b.source])
        XCTAssertEqual(kept.selected, [a])
        XCTAssertEqual(kept.stateAfterResponse.cooldowns.map(\.source), [b.source])
    }

}
