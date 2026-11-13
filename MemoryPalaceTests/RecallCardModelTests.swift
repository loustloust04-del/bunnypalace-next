import MemoryCore
import XCTest
@testable import 记忆花园

/// P1：卡的数据层（纯值 + 纯函数）。夹具虚构，不碰 SwiftData。
final class RecallCardModelTests: XCTestCase {
    private enum K {
        static let page = RecallDeliveryItem.Kind.page
        static let card = RecallDeliveryItem.Kind.card
        static let fragment = RecallDeliveryItem.Kind.fragment
        static let legacyFragment = RecallDeliveryItem.Kind.legacyFragment
        static let pinned = RecallDeliveryItem.Kind.pinned
        static let rootIndex = RecallDeliveryItem.Kind.rootIndex
        static let selfMemory = RecallDeliveryItem.Kind.selfMemory
        static let previousWindow = RecallDeliveryItem.Kind.previousWindow
        static let a2 = RecallDeliveryItem.Kind.a2
        static let timeline = RecallDeliveryItem.Kind.timeline
        static let pending = RecallDeliveryItem.Kind.pending
        static let anniversary = RecallDeliveryItem.Kind.anniversary
        static let journal = RecallDeliveryItem.Kind.journal
        static let expiredReminder = RecallDeliveryItem.Kind.expiredReminder
    }

    private func gate(off: String? = nil, triggerOff: Bool = false, legacy: Bool = false,
                      choices: [String: Bool] = ["timeline": true, "pending": true, "selfMemory": true,
                                                 "archive": true, "previousWindow": true, "pinned": true],
                      hiddenFragments: Int = 0, hiddenTimeline: Int = 0) -> RecallGateSnapshot {
        RecallGateSnapshot(off: off, participates: off == nil, triggerOff: triggerOff, legacy: legacy,
                           choices: choices, a2Checked: true,
                           hiddenFragments: hiddenFragments, hiddenTimeline: hiddenTimeline)
    }

    private func item(_ kind: String, ref: String = "ref", shown: String = "短文", tokens: Int = 10,
                      members: [String]? = nil, trimmed: Bool? = nil) -> RecallDeliveryItem {
        RecallDeliveryItem(kind: kind, ref: ref, shown: shown, tokens: tokens, members: members, trimmed: trimmed)
    }

    private func delivery(_ items: [RecallDeliveryItem], route: String = "api",
                          gate: RecallGateSnapshot? = nil) -> RecallDelivery {
        RecallDelivery(id: "fictional-delivery", route: route, items: items, gate: gate ?? self.gate())
    }

    private func receipt(_ delivery: RecallDelivery?, selected: [RecallItem] = [], reads: [RecallReadReceipt] = [],
                         attempts: [RecallAttempt] = [], suppressions: [RecallSuppression] = [],
                         tuning: RecallTuning = RecallTestTuning.make()) -> RecallTurnReceipt {
        var receipt = RecallTurnReceipt(decision: RecallTurnDecision(
            turnId: "fictional-turn", branchAnchor: "fictional-branch", origin: .user, gateReason: .search,
            tuning: tuning, topicAnchor: "", selected: selected, candidates: selected,
            suppressions: suppressions, ignored: [], thawed: [], stateAfterResponse: .init()))
        receipt.delivery = delivery
        receipt.reads = reads
        receipt.attempts = attempts
        return receipt
    }

    private func source(_ path: String = "f", kind: RecallSourceRef.Kind = .fragment) -> RecallSourceRef {
        RecallSourceRef(profileId: "fictional", kind: kind, path: path, version: "v1")
    }

    private func picked(_ kind: RecallSourceRef.Kind, _ path: String, _ text: String) -> RecallItem {
        RecallItem(source: source(path, kind: kind), text: text, identities: [], tokenCost: 10)
    }

    private func read(_ layer: String, target: String = "", status: String = "success",
                      count: Int? = nil, next: RecallReadReceipt.Next? = nil, gate: String? = nil) -> RecallReadReceipt {
        RecallReadReceipt(toolCallId: UUID().uuidString, turnId: "fictional-turn", layer: layer, target: target,
                          status: status, next: next, returnedCount: count, gate: gate)
    }

    private func targetJSON(_ target: RecallTool.Target) -> String {
        RecallTool.json(target)
    }

    func testGroupsAll14KindsInFixedOrder() {
        let kinds = [K.page, K.card, K.fragment, K.legacyFragment, K.pinned, K.rootIndex,
                     K.selfMemory, K.previousWindow, K.a2, K.timeline, K.pending, K.anniversary, K.journal,
                     K.expiredReminder]
        let model = RecallCardModel.make(receipt: receipt(delivery(kinds.map { item($0) })), legacyHits: 0,
                                        mode: .inline, assistantName: "小克")
        XCTAssertEqual(model.shape, .card)
        XCTAssertEqual(model.groups.map(\.kind), kinds, "分项顺序固定")
        XCTAssertEqual(model.groups.map(\.rows.count), Array(repeating: 1, count: 14))
        XCTAssertEqual(model.groups.first { $0.kind == K.selfMemory }?.name, "小克的记忆")
        XCTAssertEqual(model.groups.first { $0.kind == K.journal }?.unit, "篇")
        XCTAssertEqual(model.groups.filter(\.isHit).map(\.kind), [K.page, K.card, K.fragment, K.legacyFragment])
    }

    func testUnknownKindFallsIntoOthers() {
        let model = RecallCardModel.make(receipt: receipt(delivery([item(K.page), item("futureKind"), item("futureKind")])),
                                        legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.groups.map(\.kind), [K.page, RecallCardModel.otherKind])
        XCTAssertEqual(model.groups.last?.name, "其他")
        XCTAssertEqual(model.groups.last?.rows.count, 2)
        XCTAssertEqual(model.groups.last?.isHit, false, "未知种类不触发出卡")
        XCTAssertEqual(model.hitCount, 1)
    }

    func testFoldedLineSkipsZeroAndSumsTokens() {
        let model = RecallCardModel.make(receipt: receipt(delivery([
            item(K.timeline, tokens: 100), item(K.timeline, tokens: 100),
            item(K.selfMemory, shown: "全文 3 · 目录 2", tokens: 50), item(K.page, tokens: 30),
        ])), legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.foldedLine, "带了 档案页 1 页 · 助手的记忆 5 条 · 时间轴 2 条 · ≈ 280 token")
    }

    func testAggregateCountsComeFromShown() {
        let model = RecallCardModel.make(receipt: receipt(delivery([
            item(K.selfMemory, shown: "全文 3 · 目录 2", tokens: 40),
            item(K.rootIndex, shown: "根索引 4 行", tokens: 20),
            item(K.previousWindow, shown: "上个窗口 3 条", tokens: 30),
            item(K.expiredReminder, shown: "已过期 2 项", tokens: 5),
            item(K.page, shown: "页", tokens: 10),
        ])), legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.groups.map { $0.rows.count }, [1, 1, 1, 1, 1], "生产每种聚合只产一个单位")
        XCTAssertEqual(model.groups.map(\.count), [1, 4, 5, 3, 2], "计数按 shown：全文+目录 / 根索引行 / 上窗条 / 已过期项")
        XCTAssertEqual(model.foldedLine,
                       "带了 档案页 1 页 · 档案目录 4 行 · 助手的记忆 5 条 · 上个窗口 3 条 · 过期提醒 2 项 · ≈ 105 token")
    }

    func testTrimmedMarksLineAndTotal() {
        let model = RecallCardModel.make(receipt: receipt(delivery([
            item(K.page, tokens: 30, trimmed: true), item(K.timeline, tokens: 100, trimmed: true),
        ])), legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.groups.flatMap(\.rows).map(\.trimmed), [true, true])
        XCTAssertTrue(model.foldedLine.hasSuffix("（本机截断，实际更少）"))
        XCTAssertTrue(model.foldedLine.contains("≈ 130 token"), "tokens 不换算")
    }

    func testTuningAndSuppressionLine() {
        let suppression = RecallSuppression(source: source(), reason: .budget)
        let model = RecallCardModel.make(receipt: receipt(delivery([item(K.page)]), suppressions: [suppression, suppression]),
                                        legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.tuningLine, "档案触发 开 · 一轮最多 3 页 · 冷却 3 句 · 最多翻 3 次 · 超预算 2")
        var noCooldown = RecallTestTuning.make()
        noCooldown.cooldownEnabled = false
        let local = RecallCardModel.make(receipt: receipt(delivery([item(K.page)], route: "local"), tuning: noCooldown),
                                        legacyHits: 0, mode: .inline)
        XCTAssertEqual(local.tuningLine, "档案触发 开 · 一轮最多 3 页 · 最多翻 3 次 · 本机")
    }

    func testGateCopyMasterWindowSlotLegacyChoicesTrigger() {
        func model(_ gate: RecallGateSnapshot,
                   items: [RecallDeliveryItem] = [RecallDeliveryItem(kind: K.page, ref: "p", shown: "页", tokens: 1,
                                                                     members: nil, trimmed: nil)]) -> RecallCardModel {
            RecallCardModel.make(receipt: receipt(delivery(items, gate: gate)), legacyHits: 0, mode: .inline)
        }
        XCTAssertEqual(model(gate(off: "master")).gateNotes, ["记忆总开关关着，这轮没带记忆"])
        XCTAssertEqual(model(gate(off: "window")).gateNotes, ["这个窗口不参与记忆，这轮没带记忆"])
        XCTAssertEqual(model(gate(off: "slot")).gateNotes, ["预设里记忆插槽关着：档案 / 钉住 / 助手的记忆 / 上窗没带"])
        XCTAssertEqual(model(gate(legacy: true)).gateLine, "老窗口，按楼层默认带")
        XCTAssertEqual(model(gate(choices: ["timeline": false, "pending": true, "selfMemory": true,
                                           "archive": true, "previousWindow": true, "pinned": false])).gateLine,
                       "本窗划掉了：时间轴 · 钉住")
        XCTAssertEqual(model(gate(triggerOff: true), items: [item(K.legacyFragment)]).gateLine,
                       "档案触发关着，碎片按旧规则带")
        XCTAssertNil(model(gate(triggerOff: true)).gateLine, "没有 legacy 碎片时不写这句")
    }

    func testHiddenCountsCopyUsesCandidatesWording() {
        let model = RecallCardModel.make(receipt: receipt(delivery(
            [item(K.fragment), item(K.timeline)],
            gate: gate(hiddenFragments: 2, hiddenTimeline: 3))), legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.groups.first { $0.kind == K.fragment }?.note,
                       "另有 2 条碎片来自已删 / 不参与的窗，没带")
        XCTAssertEqual(model.groups.first { $0.kind == K.timeline }?.note,
                       "时间轴另有 3 项来自已删 / 不参与的窗，没带")
        XCTAssertFalse(model.groups.compactMap(\.note).joined().contains("少带了"), "候选数不写「少带了」")
    }

    func testCardShownOnlyForHitItemsOrReads() {
        XCTAssertEqual(RecallCardModel.make(receipt: receipt(delivery([item(K.timeline)])), legacyHits: 0, mode: .inline).shape,
                       .hidden, "只有常驻项不出卡")
        XCTAssertEqual(RecallCardModel.make(receipt: receipt(delivery([item(K.page)])), legacyHits: 0, mode: .inline).shape, .card)
        XCTAssertEqual(RecallCardModel.make(receipt: receipt(delivery([]), reads: [read("A4")]), legacyHits: 0, mode: .inline).shape,
                       .card, "只有读也出卡")
    }

    func testResidentOnlyItemsDoNotShowCard() {
        let model = RecallCardModel.make(receipt: receipt(delivery([
            item(K.pinned), item(K.rootIndex), item(K.selfMemory), item(K.a2), item(K.timeline),
            item(K.pending), item(K.anniversary), item(K.journal), item(K.expiredReminder),
        ])), legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.shape, .hidden)
        XCTAssertEqual(model.hitCount, 0)
    }

    func testNCountsHitItemsPlusGoodReads() {
        let model = RecallCardModel.make(receipt: receipt(
            delivery([item(K.page), item(K.fragment)]),
            reads: [read("A4", count: 3), read("A4", count: 0), read("L2", status: "invalidTarget", count: 0)]),
            legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.hitCount, 3, "2 想起项 + 1 条翻到了的读")
        XCTAssertEqual(model.label, "想起来了 3 件事")
    }

    func testPagedReadCountsTowardNInModelAndSummary() throws {
        let paged = receipt(delivery([]), reads: [read("A4", status: "partial", count: 20, next: .init(hasMore: true, cursorIssued: true))])
        let model = RecallCardModel.make(receipt: paged, legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.shape, .card)
        XCTAssertEqual(model.hitCount, 1, "partial 也是读到了内容，计入 N")
        XCTAssertEqual(model.label, "想起来了 1 件事")
        XCTAssertEqual(model.reads.map(\.status), ["翻到 20 条，还有"])

        let data = try JSONEncoder().encode(paged)
        XCTAssertEqual(RecallCardSummary.make(receiptData: data, legacyHits: 0, mode: .inline, streaming: false),
                       .init(hasRecall: true, label: "想起来了 1 件事"))
    }

    func testFailedReadsOnlyShowCardWithNoHitLabel() {
        let model = RecallCardModel.make(receipt: receipt(delivery([]), reads: [read("A4", status: "invalidTarget", count: 0)]),
                                        legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.shape, .card)
        XCTAssertEqual(model.hitCount, 0)
        XCTAssertEqual(model.label, "想起来了 · 没翻到")
    }

    func testStreamingNExcludesReads() {
        let signed = receipt(delivery([item(K.page)]), reads: [read("A4", count: 2)])
        XCTAssertEqual(RecallCardModel.make(receipt: signed, legacyHits: 0, mode: .inline).hitCount, 2)
        XCTAssertEqual(RecallCardModel.make(receipt: signed, legacyHits: 0, mode: .inline, streaming: true).hitCount, 1)

        let readsOnly = receipt(delivery([]), reads: [read("A4", count: 2)])
        XCTAssertEqual(RecallCardModel.make(receipt: readsOnly, legacyHits: 0, mode: .inline, streaming: true).label,
                       "想起来了", "流式中只有读：不先说「没翻到」")
        XCTAssertEqual(RecallCardModel.make(receipt: readsOnly, legacyHits: 0, mode: .inline).label, "想起来了 1 件事")
    }

    func testNotSentWhenAllAttemptsFailedIgnoringInherited() {
        var receipt = receipt(delivery([item(K.page)]),
                             attempts: [RecallAttempt(id: "a", status: .failed),
                                        RecallAttempt(id: "b", status: .cancelled)])
        receipt.inheritedEffective = true
        let model = RecallCardModel.make(receipt: receipt, legacyHits: 0, mode: .inline)
        XCTAssertTrue(model.notSent, "全 failed / cancelled 且没有 receivedResponse")
        XCTAssertEqual(model.label, "想起来了 1 件事（没发成）")

        let succeeded = RecallCardModel.make(receipt: self.receipt(delivery([item(K.page)]),
                                                                  attempts: [RecallAttempt(id: "a", status: .failed),
                                                                             RecallAttempt(id: "b", status: .responded,
                                                                                           receivedResponse: true)]),
                                             legacyHits: 0, mode: .inline)
        XCTAssertFalse(succeeded.notSent)
        XCTAssertEqual(succeeded.label, "想起来了 1 件事")
    }

    func testInterruptedAndMultiAttemptNotes() {
        let model = RecallCardModel.make(receipt: receipt(
            delivery([item(K.page)]),
            attempts: [RecallAttempt(id: "a", status: .interrupted, receivedResponse: true),
                       RecallAttempt(id: "b", status: .failed)]),
            legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.notes, ["回复中途停了", "请求了 2 次（含工具续轮 / 重试）"])
    }

    func testV1ReceiptShowsSelectedAsOldLedger() {
        let page = picked(.page, "人/林栖", "[档案·本轮相关]\n[[人/林栖]] 林栖的航线")
        let card = picked(.card, "memory/cc/航线.md", "[档案·本轮相关]\n条目：沿河航行\n下钻：memory/cc/航线.md|c1")
        let fragment = picked(.fragment, "f1", "[关于星砚·本轮相关]\n[林栖的地图]")
        let model = RecallCardModel.make(receipt: receipt(nil, selected: [card, page, fragment]), legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.shape, .card)
        XCTAssertTrue(model.oldLedger)
        XCTAssertEqual(RecallCardModel.oldLedgerNote, "旧账：只记了档案触发那部分")
        XCTAssertEqual(model.groups.map(\.kind), [K.page, K.card, K.fragment])
        XCTAssertEqual(model.groups.map { $0.rows.count }, [1, 1, 1])
        XCTAssertEqual(model.groups[0].rows[0].title, "[[人/林栖]] 林栖的航线")
        XCTAssertEqual(model.groups[1].rows[0].title, "沿河航行")
        XCTAssertEqual(model.groups[1].rows[0].text, card.text)
        XCTAssertEqual(model.groups[2].rows[0].title, "[林栖的地图]")
        XCTAssertEqual(model.hitCount, 3)

        let empty = RecallCardModel.make(receipt: receipt(nil), legacyHits: 2, mode: .inline)
        XCTAssertEqual(empty.shape, .legacy)
        XCTAssertEqual(empty.label, "想起来了 2 件事（旧记录）")
    }

    func testHitsOnlyMessageUsesLegacyLabel() {
        let model = RecallCardModel.make(receipt: nil, legacyHits: 3, mode: .inline)
        XCTAssertEqual(model.shape, .legacy)
        XCTAssertEqual(model.label, "想起来了 3 件事（旧记录）")
        XCTAssertEqual(RecallCardModel.make(receipt: nil, legacyHits: 0, mode: .inline).shape, .hidden)
    }

    func testDefaultConfigLegacyFragmentVsResidentOnly() throws {
        // 粟粟默认楼层：触发关、selected 空、delivery 非空（research §0-1）
        let fragmentOnly = receipt(delivery([item(K.legacyFragment, ref: "f", shown: "碎片")],
                                            gate: gate(triggerOff: true)))
        let model = RecallCardModel.make(receipt: fragmentOnly, legacyHits: 3, mode: .inline)
        XCTAssertEqual(model.shape, .card, "有 legacyFragment 就出卡")
        XCTAssertEqual(model.hitCount, 1)
        XCTAssertEqual(model.label, "想起来了 1 件事")
        let data = try JSONEncoder().encode(fragmentOnly)
        XCTAssertEqual(RecallCardSummary.make(receiptData: data, legacyHits: 3, mode: .inline, streaming: false),
                       .init(hasRecall: true, label: "想起来了 1 件事"))

        let residentOnly = receipt(delivery([item(K.timeline), item(K.selfMemory, shown: "全文 2 · 目录 1")],
                                            gate: gate(triggerOff: true)))
        let hidden = RecallCardModel.make(receipt: residentOnly, legacyHits: 3, mode: .inline)
        XCTAssertEqual(hidden.shape, .hidden, "常驻项不触发出卡，也不回落旧卡（回落只对无回执 / v1 空回执）")
        let residentData = try JSONEncoder().encode(residentOnly)
        XCTAssertEqual(RecallCardSummary.make(receiptData: residentData, legacyHits: 3, mode: .inline, streaming: false),
                       .init(hasRecall: false, label: ""))
    }

    func testCCReturnsNoCard() {
        let model = RecallCardModel.make(receipt: receipt(delivery([item(K.page)], route: "ccBridge"), reads: [read("A4", count: 1)]),
                                        legacyHits: 1, mode: .inline)
        XCTAssertEqual(model.shape, .hidden, "CC 不出卡，也不回落旧卡")
    }

    func testReadTargetHumanizedPerLayerAndUnparsableFallsBack() {
        let reads = [
            read("A4", target: targetJSON(RecallTool.Target(tree: "a", layer: "date", date: "2026-11-08")), count: 1),
            read("A3", target: targetJSON(RecallTool.Target(tree: "a", layer: "window", conversationId: "abcdef123456")), count: 2),
            read("A2", target: targetJSON(RecallTool.Target(tree: "a", layer: "segment", segment: 3)), count: 1),
            read("原文", target: targetJSON(RecallTool.Target(tree: "a", layer: "search", query: "云桥城", scope: "a")), count: 4),
            read("wiki页", target: targetJSON(RecallTool.Target(tree: "c", layer: "page",
                                                               page: .init(profileId: "fictional", path: "地点/云桥城"))), count: 1),
            read("L1", count: 1),
            read("L2", count: 1),
            read("原文", target: "not-json", count: 1),
        ]
        let model = RecallCardModel.make(receipt: receipt(delivery([]), reads: reads), legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.reads.map(\.title), [
            "A4 · 11-08", "A3 · 窗口 abcdef12", "A2 · 第 3 段", "搜「云桥城」（范围 a）",
            "档案页 · 云桥城", "要点卡", "L2 原文", "原文",
        ])
    }

    func testReadTargetsDecodeProductionSnakeCase() {
        // 生产写进 `read.target` 的是 `RecallTool.json`（snake_case）；夹具用字面量，不经过编码器。
        let reads = [
            read("A3", target: #"{"tree":"a","layer":"window","conversation_id":"abcdef123456","last_node_id":"node-1"}"#, count: 2),
            read("原文", target: #"{"tree":"a","layer":"window","conversation_id":"0123456789aa"}"#, count: 1),
            read("wiki页", target: #"{"tree":"c","layer":"page","page":{"profile_id":"fictional","path":"地点/云桥城"}}"#, count: 1),
            read("A4", target: #"{"tree":"a","layer":"date","date":"2026-11-08"}"#, count: 1),
        ]
        let model = RecallCardModel.make(receipt: receipt(delivery([]), reads: reads), legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.reads.map(\.title), [
            "A3 · 窗口 abcdef12", "原文 · 窗口 01234567", "档案页 · 云桥城", "A4 · 11-08",
        ], "snake_case 的 conversation_id / profile_id 必须解出来")
    }

    func testReadStatusCopyIncludingGateAndV1NilCount() {
        let reads = [
            read("A4", count: 2, next: .init(hasMore: true, cursorIssued: true)),
            read("A4", count: 0),
            read("A4", count: nil),
            read("A4", status: "invalidTarget", count: 0),
            read("A4", status: "stale", count: 0),
            read("A4", status: "unavailable", count: 0),
            read("A4", status: "limited", count: 0),
            read("A4", count: 1, gate: "master"),
            read("A4", status: "partial", count: 4),
        ]
        let model = RecallCardModel.make(receipt: receipt(delivery([]), reads: reads), legacyHits: 0, mode: .inline)
        XCTAssertEqual(model.reads.map(\.status), [
            "翻到 2 条，还有", "没找到", "翻了", "目标不对", "已过期，没读", "不可用",
            "到本轮上限，没翻", "翻到 1 条（记忆关着，只能翻原文）", "翻到 4 条",
        ])
    }

    func testDigestMatchesFullDecodeSummary() throws {
        let signed = receipt(delivery([item(K.page), item(K.timeline)], gate: gate(hiddenTimeline: 1)),
                            reads: [read("A4", count: 3), read("A4", status: "invalidTarget", count: 0)],
                            attempts: [RecallAttempt(id: "a", status: .responded, receivedResponse: true)])
        let data = try JSONEncoder().encode(signed)
        let decodedReceipt = try JSONDecoder().decode(RecallTurnReceipt.self, from: data)
        let full = RecallCardModel.make(receipt: decodedReceipt, legacyHits: 0, mode: .inline)
        let digest = try JSONDecoder().decode(RecallCardDigest.self, from: data)
        XCTAssertEqual(digest.tally, RecallCardModel.tally(hitItems: 1, reads: decodedReceipt.reads,
                                                           attempts: decodedReceipt.attempts))
        let summary = RecallCardSummary.make(receiptData: data, legacyHits: 0, mode: .inline, streaming: false)
        XCTAssertEqual(summary.hasRecall, true)
        XCTAssertEqual(summary.label, full.label)
        XCTAssertEqual(summary.label, "想起来了 2 件事")
        let streaming = RecallCardSummary.make(receiptData: data, legacyHits: 0, mode: .inline, streaming: true)
        XCTAssertEqual(streaming.label, "想起来了 1 件事")
        XCTAssertEqual(RecallCardSummary.make(receiptData: nil, legacyHits: 4, mode: .inline, streaming: false),
                       .init(hasRecall: true, label: "想起来了 4 件事（旧记录）"))
        XCTAssertEqual(RecallCardSummary.make(receiptData: data, legacyHits: 0, mode: .hidden, streaming: false),
                       .init(hasRecall: false, label: ""))
    }
}
