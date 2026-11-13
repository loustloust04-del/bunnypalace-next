import MemoryCore
import XCTest
@testable import 记忆花园

extension RecallViewerTests {
    private func receipt(items: [RecallItem] = [], reads: [RecallReadReceipt] = []) -> RecallTurnReceipt {
        var receipt = RecallTurnReceipt(decision: .init(
            turnId: "fictional-turn", branchAnchor: "fictional-branch", origin: .user, gateReason: .search,
            tuning: RecallTestTuning.make(), topicAnchor: "", selected: items, candidates: items,
            suppressions: [], ignored: [], thawed: [], stateAfterResponse: .init()))
        receipt.reads = reads
        return receipt
    }

    func testReceiptCardGroupsDeliveredSnapshotsAndExcludesCandidates() throws {
        let pageText = "[档案·本轮相关]\n[[人/林栖]] 林栖的航线\n现在：云桥城"
        let cardText = "[档案·本轮相关]\n条目：沿河航行\n要点：带地图\n下钻：memory/cc/航线.md|c1"
        let fragmentText = "[关于星砚·本轮相关]\n[林栖的地图]\n另一行原文"
        let page = RecallItem(source: .init(profileId: "fictional", kind: .page, path: "人/林栖", version: "p1"),
                              text: pageText, identities: ["林栖"], tokenCost: 30)
        let card = RecallItem(source: .init(profileId: "fictional", kind: .card, path: "memory/cc/航线.md", version: "c1"),
                              text: cardText, identities: [], tokenCost: 30)
        let fragment = RecallItem(source: .init(profileId: "fictional", kind: .fragment, path: "fragment", version: "f1"),
                                  text: fragmentText, identities: [], tokenCost: 20)
        let nextPage = RecallItem(source: .init(profileId: "fictional", kind: .page, path: "地/云桥城", version: "p2"),
                                  text: "[档案·本轮相关]\n[[地/云桥城]] 云桥城", identities: [], tokenCost: 10)
        let unselected = RecallItem(source: .init(profileId: "fictional", kind: .fragment, path: "budget", version: "f2"),
                                    text: "未发送的候选", identities: [], tokenCost: 500)
        let proposal = RecallTurnDecision(turnId: "fictional-turn", branchAnchor: "fictional-branch", origin: .user,
                                          gateReason: .search, tuning: RecallTestTuning.make(), topicAnchor: "",
                                          selected: [card, page, fragment, nextPage], candidates: [card, page, fragment, nextPage, unselected],
                                          suppressions: [.init(source: unselected.source, reason: .budget)],
                                          ignored: [], thawed: [], stateAfterResponse: .init())
        var saved = RecallTurnReceipt(decision: proposal.recordingDelivery([card, page, fragment, nextPage]))
        saved.injectionRecord = .init(tokens: 900, stableCount: 3, hitCount: 4, at: Date(timeIntervalSince1970: 1))
        let decoded = try JSONDecoder().decode(RecallTurnReceipt.self, from: JSONEncoder().encode(saved))
        let model = RecallCardModel.make(receipt: decoded, legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.shape, .card)
        XCTAssertTrue(model.oldLedger, "v1 旧账")
        XCTAssertEqual(model.groups.map(\.kind),
                       [RecallDeliveryItem.Kind.page, RecallDeliveryItem.Kind.card, RecallDeliveryItem.Kind.fragment])
        XCTAssertEqual(model.groups.map { $0.rows.count }, [2, 1, 1])
        XCTAssertEqual(model.groups[1].rows.first?.title, "沿河航行")
        XCTAssertEqual(model.groups[0].rows.map(\.title), ["[[人/林栖]] 林栖的航线", "[[地/云桥城]] 云桥城"])
        XCTAssertEqual(model.groups[2].rows.first?.title, "[林栖的地图]")
        XCTAssertEqual(model.groups.flatMap(\.rows).map(\.text), [pageText, nextPage.text, cardText, fragmentText])
        XCTAssertFalse(model.groups.flatMap(\.rows).map(\.text).contains(unselected.text), "候选不画")
        XCTAssertEqual(model.hitCount, 4)

        guard case .receipt(let legacyModel) = RecallCardPresentation.make(receipt: decoded, legacyHitsEmpty: false, mode: .inline) else {
            return XCTFail("Selected snapshots must be visible")
        }
        XCTAssertEqual(legacyModel.groups.map(\.kind), [.page, .card, .fragment], "旧视图继续只画 selected 分组")
        XCTAssertEqual(legacyModel.groups[1].rows.first?.detail, "memory/cc/航线.md|c1")
        XCTAssertEqual(legacyModel.groups.flatMap(\.rows).map(\.text), [pageText, nextPage.text, cardText, fragmentText])
        XCTAssertEqual(legacyModel.injectionRecord?.tokens, 900)
        XCTAssertEqual(legacyModel.injectionRecord?.stableCount, 3)
        XCTAssertEqual(legacyModel.injectionRecord?.hitCount, 4)
        XCTAssertEqual(RecallCardPresentation.make(receipt: decoded, legacyHitsEmpty: false, mode: .sheet), .receipt(legacyModel))
    }

    func testReceiptCardEmptyReceiptFallsBackOnlyWhenLegacyHitsExist() {
        var statsOnly = receipt()
        statsOnly.injectionRecord = .init(tokens: 200, stableCount: 2, hitCount: 0, at: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(RecallCardModel.make(receipt: statsOnly, legacyHits: 0, mode: .inline).shape, .hidden)
        XCTAssertEqual(RecallCardModel.make(receipt: statsOnly, legacyHits: 1, mode: .inline).shape, .legacy)
        XCTAssertEqual(RecallCardPresentation.make(receipt: statsOnly, legacyHitsEmpty: false, mode: .inline), .legacy)
        XCTAssertEqual(RecallCardPresentation.make(receipt: statsOnly, legacyHitsEmpty: true, mode: .sheet), .hidden)
    }

    func testReceiptCardDefaultConfigKeepsOldOuterSplit() {
        // 默认楼层：触发关、selected 空、delivery 非空；Presentation 的旧外层只认 selected / reads
        let choices = ["timeline": true, "pending": true, "selfMemory": true,
                       "archive": true, "previousWindow": true, "pinned": true]
        func withDelivery(_ items: [RecallDeliveryItem]) -> RecallTurnReceipt {
            var receipt = RecallTurnReceipt(decision: .init(
                turnId: "fictional-turn", branchAnchor: "fictional-branch", origin: .user, gateReason: .search,
                tuning: RecallTestTuning.make(), topicAnchor: "", selected: [], candidates: [],
                suppressions: [], ignored: [], thawed: [], stateAfterResponse: .init()))
            receipt.delivery = RecallDelivery(
                id: "fictional-delivery", route: "api", items: items,
                gate: .init(off: nil, participates: true, triggerOff: true, legacy: false, choices: choices,
                            a2Checked: true, hiddenFragments: 0, hiddenTimeline: 0))
            return receipt
        }

        let fragmentOnly = withDelivery([
            .init(kind: RecallDeliveryItem.Kind.legacyFragment, ref: "f", shown: "碎片", tokens: 5,
                  members: nil, trimmed: nil),
        ])
        XCTAssertEqual(RecallCardModel.make(receipt: fragmentOnly, legacyHits: 3, mode: .inline).shape, .card)
        XCTAssertEqual(RecallCardPresentation.make(receipt: fragmentOnly, legacyHitsEmpty: false, mode: .inline), .legacy,
                       "有旧 hits 走旧卡")

        let residentOnly = withDelivery([
            .init(kind: RecallDeliveryItem.Kind.timeline, ref: "t", shown: "时间轴", tokens: 5, members: nil, trimmed: nil),
            .init(kind: RecallDeliveryItem.Kind.selfMemory, ref: "self", shown: "全文 2 · 目录 1", tokens: 5,
                  members: nil, trimmed: nil),
        ])
        XCTAssertEqual(RecallCardModel.make(receipt: residentOnly, legacyHits: 3, mode: .inline).shape, .hidden)
        XCTAssertEqual(RecallCardPresentation.make(receipt: residentOnly, legacyHitsEmpty: false, mode: .inline), .legacy,
                       "常驻项不触发出卡，旧卡照旧")
        XCTAssertEqual(RecallCardPresentation.make(receipt: residentOnly, legacyHitsEmpty: true, mode: .inline), .hidden)
    }

    func testReceiptCardReadsOnlyPreservesFailureAndEmptyStatuses() {
        let reads: [RecallReadReceipt] = [
            .init(toolCallId: "success", turnId: "fictional-turn", layer: "wiki", target: "人/林栖"),
            .init(toolCallId: "empty", turnId: "fictional-turn", layer: "search", target: "云桥城", status: "empty"),
            .init(toolCallId: "failed", turnId: "fictional-turn", layer: "original", target: "fictional-id", status: "permission_denied")
        ]
        let model = RecallCardModel.make(receipt: receipt(reads: reads), legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.shape, .card)
        XCTAssertEqual(model.groups, [])
        XCTAssertEqual(model.reads.map(\.title), ["其它", "其它", "其它"], "未知 layer 兜底不显示英文原串")
        XCTAssertEqual(model.reads.map(\.status), ["翻了", "其它", "其它"], "未知状态兜底不显示英文原串")
        XCTAssertEqual(model.hitCount, 1, "v1 成功读没有条数按 1 条算（(returnedCount ?? 1) > 0）")
        XCTAssertEqual(model.label, "想起来了 1 件事")

        guard case .receipt(let legacy) = RecallCardPresentation.make(
            receipt: receipt(reads: reads), legacyHitsEmpty: false, mode: .inline) else {
            return XCTFail("只有读也要走旧卡的 receipt 分支")
        }
        XCTAssertEqual(legacy.groups, [])
        XCTAssertEqual(legacy.reads.map(\.status), ["success", "empty", "permission_denied"], "读状态原样透传")
        XCTAssertNil(legacy.injectionRecord)
    }

    func testReceiptCardHiddenOverridesNewAndLegacyMessages() {
        let read = RecallReadReceipt(toolCallId: "read", turnId: "fictional-turn", layer: "wiki", target: "人/林栖")
        XCTAssertEqual(RecallCardModel.make(receipt: receipt(reads: [read]), legacyHits: 0, mode: .hidden).shape, .hidden)
        XCTAssertEqual(RecallCardModel.make(receipt: nil, legacyHits: 2, mode: .hidden).shape, .hidden)
        XCTAssertEqual(RecallCardPresentation.make(receipt: receipt(reads: [read]), legacyHitsEmpty: false, mode: .hidden), .hidden)
        XCTAssertEqual(RecallCardPresentation.make(receipt: nil, legacyHitsEmpty: false, mode: .hidden), .hidden)
    }

    func testReceiptCardMessagesWithoutReceiptUseLegacyCard() {
        XCTAssertEqual(RecallCardModel.make(receipt: nil, legacyHits: 0, mode: .inline).shape, .hidden)
        let legacy = RecallCardModel.make(receipt: nil, legacyHits: 2, mode: .sheet)
        XCTAssertEqual(legacy.shape, .legacy)
        XCTAssertEqual(legacy.label, "想起来了 2 件事（旧记录）")
        XCTAssertEqual(RecallCardPresentation.make(receipt: nil, legacyHitsEmpty: false, mode: .inline), .legacy)
        XCTAssertEqual(RecallCardPresentation.make(receipt: nil, legacyHitsEmpty: true, mode: .sheet), .legacy)
    }
}
