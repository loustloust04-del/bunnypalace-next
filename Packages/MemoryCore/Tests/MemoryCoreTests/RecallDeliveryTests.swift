import XCTest
@testable import MemoryCore

/// plan `plan-memory-receipt.md` §2.1 / §2.5 / §3「P1 包」：delivery 组装、key 格式、回执 v1 → v2。
final class RecallDeliveryTests: XCTestCase {
    private func gate(hiddenFragments: Int = 0, hiddenTimeline: Int = 0) -> RecallGateSnapshot {
        RecallGateSnapshot(off: nil, participates: true, triggerOff: false, legacy: false,
                           choices: ["timeline": true, "pending": true, "selfMemory": true,
                                     "archive": true, "previousWindow": true, "pinned": true],
                           a2Checked: true, hiddenFragments: hiddenFragments, hiddenTimeline: hiddenTimeline)
    }

    private func unit(_ text: String, kind: String = RecallDeliveryItem.Kind.fragment, ref: String = "memory:r1",
                      shown: String = "短文", tokens: Int = 7, members: [String]? = nil,
                      segment: RecallDeliveryUnit.Segment = .memoryStable) -> RecallDeliveryUnit {
        RecallDeliveryUnit(kind: kind, ref: ref, version: nil, text: text, tokens: tokens,
                           shown: shown, members: members, segment: segment)
    }

    private func decision(turnId: String = "t1", gateReason: RecallTurnDecision.GateReason = .search) -> RecallTurnDecision {
        RecallTurnDecision(turnId: turnId, branchAnchor: "b1", origin: .user, gateReason: gateReason,
                           tuning: RecallTestTuning.make(), topicAnchor: "云桥城",
                           selected: [], candidates: [], suppressions: [], ignored: [], thawed: [],
                           stateAfterResponse: RecallConversationState(effectiveTurn: 1, branchAnchor: "b1", topicAnchor: "云桥城"))
    }

    // MARK: - build

    func testBuildDropsNoneAndMarksPartialTrimmed() {
        let units = [unit("甲"), unit("乙"), unit("丙")]
        let delivery = MemoryDelivery.build(units: units, route: "api", gate: gate()) { candidate in
            switch candidate.text {
            case "甲": return .full
            case "乙": return .partial
            default: return .none
            }
        }
        XCTAssertEqual(delivery.items.map(\.ref), ["memory:r1", "memory:r1"], "none 丢掉")
        XCTAssertEqual(delivery.items.map(\.trimmed), [nil, true], "full 不标、partial 标截断")
        XCTAssertEqual(delivery.route, "api")
        XCTAssertEqual(delivery.gate, gate())
    }

    func testShownTruncatedTo60AndMembersTo50() {
        // 多码元字符：按标量 / UTF-16 截都会切在字符中间，只有按 Character 截才对
        let emoji = "👩‍👩‍👧"
        let shown = String(repeating: emoji, count: 61)
        let members = (0..<60).map { "m\($0)" }
        let delivery = MemoryDelivery.build(units: [unit("甲", shown: shown, members: members)], route: "api", gate: gate()) { _ in .full }
        let item = delivery.items[0]
        XCTAssertEqual(item.shown, String(repeating: emoji, count: 60), "shown 按 Character 截 60")
        XCTAssertEqual(item.shown.count, 60)
        XCTAssertEqual(item.members, (0..<50).map { "m\($0)" }, "members 截 50")
        XCTAssertEqual(item.tokens, 7)
    }

    func testIdStableForSameItemsAndChangesWithContent() {
        let units = [unit("甲"), unit("乙")]
        let first = MemoryDelivery.build(units: units, route: "api", gate: gate()) { _ in .full }
        let second = MemoryDelivery.build(units: units, route: "api", gate: gate()) { _ in .full }
        XCTAssertEqual(first.id, second.id, "同 items 同 id")
        XCTAssertEqual(first.id.count, 16, "SHA-256 前 16 hex")
        XCTAssertEqual(first.id, first.id.lowercased())

        let changed = MemoryDelivery.build(units: [unit("甲", shown: "改过的短文"), unit("乙")], route: "api", gate: gate()) { _ in .full }
        XCTAssertNotEqual(first.id, changed.id, "内容变 id 变")
    }

    func testKeyMatchesBenchSourceFormat() {
        let page = RecallSourceRef(profileId: "p", conversationId: "c", kind: .page, path: "人物/岚舟.md", version: "v9")
        XCTAssertEqual(MemoryDelivery.key(page), MemoryBenchRecallReader.key(page: "人物/岚舟.md", version: "v9"))
        let card = RecallSourceRef(profileId: "p", conversationId: "c", kind: .card, path: "人物/航图", version: "v3")
        XCTAssertEqual(MemoryDelivery.key(card), MemoryBenchRecallReader.key(card: "人物/航图", version: "v3"))
        let uuid = "6F0E0C1B-0000-4000-8000-00000000ABCD"
        let fragment = RecallSourceRef(profileId: "p", conversationId: "c", kind: .fragment, path: uuid, version: "whatever")
        XCTAssertEqual(MemoryDelivery.key(fragment), "memory:\(uuid)", "碎片只认 id，与 bench 同式")
    }

    func testContainmentLocatorUsesPerSegmentCursor() {
        let segments: [RecallDeliveryUnit.Segment: String] = [
            .memoryStable: "甲\n乙\n甲\n乙",
            .timeline: "丙",
        ]
        let locate = MemoryDelivery.containmentLocator(segments) { $0 }
        let first = unit("甲")
        let second = unit("乙")
        XCTAssertEqual(locate(first), .full)
        XCTAssertEqual(locate(second), .full)
        XCTAssertEqual(locate(first), .full, "第二处出现")
        XCTAssertEqual(locate(second), .full, "第二处出现")
        XCTAssertEqual(locate(first), .none, "同文两单位只认两次出现")
        XCTAssertEqual(locate(unit("丁", segment: .timeline)), .none, "段里没有")
        XCTAssertEqual(locate(unit("丙", segment: .timeline)), .full, "游标按段各算各的")
        XCTAssertEqual(locate(unit("缺失", segment: .contextSummary)), .none, "没有这一段")

        let transform = MemoryDelivery.containmentLocator([.memoryStable: "去掉了提示"]) { _ in "" }
        XCTAssertEqual(transform(unit("甲")), .none, "变换后为空不算命中")

        // transform 作用在单位文本上，不是段文本：段里只有原文，单位文本带着提示词
        let hinted = MemoryDelivery.containmentLocator([.memoryStable: "甲"]) {
            $0.replacingOccurrences(of: "<hint>", with: "")
        }
        XCTAssertEqual(hinted(unit("甲<hint>")), .full, "去掉提示后能在段里找到")
        let untransformed = MemoryDelivery.containmentLocator([.memoryStable: "甲"]) { $0 }
        XCTAssertEqual(untransformed(unit("甲<hint>")), .none, "不去掉提示就找不到")
    }

    // MARK: - 回执 v1 → v2

    private let v1JSON = """
    {"schemaVersion":1,"decision":{"turnId":"t1","branchAnchor":"b1","origin":"user","gateReason":"search",
    "tuning":{"schemaVersion":1},"topicAnchor":"云桥城","selected":[],"candidates":[],"suppressions":[],
    "ignored":[],"thawed":[],"stateAfterResponse":{"schemaVersion":1,"effectiveTurn":1,"branchAnchor":"b1",
    "topicAnchor":"云桥城","active":[],"pending":[],"cooldowns":[]}},
    "attempts":[{"id":"a1","status":"responded","receivedResponse":true}],
    "reads":[{"toolCallId":"tool-1","turnId":"t1","layer":"A2","target":"x","status":"success"}]}
    """

    func testV1ReceiptDecodesWithNilV2Fields() throws {
        let receipt = try JSONDecoder().decode(RecallTurnReceipt.self, from: Data(v1JSON.utf8))
        XCTAssertEqual(receipt.schemaVersion, 1, "旧账的版本照读")
        XCTAssertNil(receipt.delivery, "v1 没有 delivery")
        XCTAssertNil(receipt.inheritedEffective, "v1 不继承")
        XCTAssertNil(receipt.attempts[0].deliveryId)
        XCTAssertNil(receipt.reads[0].returnedCount)
        XCTAssertNil(receipt.reads[0].gate)
        XCTAssertTrue(receipt.hasEffectiveResponse, "v1 照旧看 attempts")
        XCTAssertEqual(receipt.decision.turnId, "t1")

        // 重编码回 v1 形状：五个新键缺省（合成 Codable 的 encodeIfPresent），版本照写 1
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1, "解码出的 1 原样写回")
        XCTAssertNil(object["delivery"])
        XCTAssertNil(object["inheritedEffective"])
        let attempts = try XCTUnwrap(object["attempts"] as? [[String: Any]])
        let reads = try XCTUnwrap(object["reads"] as? [[String: Any]])
        XCTAssertNil(attempts.first?["deliveryId"])
        XCTAssertNil(reads.first?["returnedCount"])
        XCTAssertNil(reads.first?["gate"])
    }

    func testV2ReceiptDecodesIntoV1Shape() throws {
        var receipt = RecallTurnReceipt(decision: decision())
        receipt.inheritedEffective = false
        receipt.delivery = MemoryDelivery.build(units: [unit("甲")], route: "api", gate: gate(hiddenFragments: 2)) { _ in .partial }
        let data = try JSONEncoder().encode(receipt)

        /// 只认 v1 键的旁证：v2 多出来的键必须被旧形状忽略，不能炸。
        struct V1Shape: Decodable {
            let schemaVersion: Int
            struct Decision: Decodable { let turnId: String; let gateReason: String }
            let decision: Decision
            struct Attempt: Decodable { let id: String; let status: String; let receivedResponse: Bool }
            let attempts: [Attempt]
            struct Read: Decodable { let toolCallId: String; let status: String }
            let reads: [Read]
        }
        receipt.attempts.append(RecallAttempt(id: "a2", status: .submitted, receivedResponse: false, deliveryId: receipt.delivery?.id))
        receipt.reads.append(RecallReadReceipt(toolCallId: "tool-2", turnId: "t1", layer: "A2", target: "y",
                                               returnedCount: 0, gate: "master"))
        let data2 = try JSONEncoder().encode(receipt)
        let v1 = try JSONDecoder().decode(V1Shape.self, from: data2)
        XCTAssertEqual(v1.schemaVersion, 2)
        XCTAssertEqual(v1.decision.turnId, "t1")
        XCTAssertEqual(v1.attempts.map(\.id), ["a2"])
        XCTAssertEqual(v1.reads.map(\.toolCallId), ["tool-2"])

        let round = try JSONDecoder().decode(RecallTurnReceipt.self, from: data)
        XCTAssertEqual(round.delivery, receipt.delivery, "delivery 字节往返")
        XCTAssertEqual(round.delivery?.gate.hiddenFragments, 2)
        XCTAssertEqual(round.delivery?.items.first?.trimmed, true)
        XCTAssertEqual(round.schemaVersion, 2)
        XCTAssertEqual(round.inheritedEffective, false)
    }

    /// 旧 build 视角：kind 是字符串常量，新 build 写的新种类（journal / 以后再加的）解码不炸、原串保留。
    func testUnknownKindDecodes() throws {
        let delivery = MemoryDelivery.build(units: [unit("甲", kind: "futureKind"), unit("乙", kind: RecallDeliveryItem.Kind.journal)],
                                            route: "api", gate: gate()) { _ in .full }
        let decoded = try JSONDecoder().decode(RecallDelivery.self, from: JSONEncoder().encode(delivery))
        XCTAssertEqual(decoded.items.map(\.kind), ["futureKind", "journal"])
        XCTAssertEqual(RecallDeliveryItem.Kind.journal, "journal")
        XCTAssertEqual(decoded.items.map(\.shown), ["短文", "短文"])
    }

    func testInheritedEffectiveCountsForRecordResponseAndRecover() {
        var receipt = RecallTurnReceipt(decision: decision())
        let id = receipt.beginAttempt()
        receipt.markAttempt(id, status: .submitted)
        XCTAssertFalse(receipt.hasEffectiveResponse, "没有首次有效事件前不算生效")

        receipt.inheritedEffective = true
        XCTAssertTrue(receipt.hasEffectiveResponse, "继承来的生效照算")
        var state = RecallConversationState()
        let applied = receipt.recordResponse(attemptId: id, state: &state, currentTurnId: "t1", currentBranchAnchor: "b1")
        XCTAssertFalse(applied, "已生效 → 不重复推进")
        XCTAssertEqual(state, RecallConversationState(), "状态没被碰")
        XCTAssertEqual(receipt.attempts[0].status, .responded)

        let recovered = RecallTurnState.recover(receipts: [receipt], branchAnchor: "b1", clearActive: false)
        XCTAssertEqual(recovered.effectiveTurn, 1, "这一轮照计")
        XCTAssertEqual(recovered.lastAppliedTurnId, "t1")

        var plain = RecallTurnReceipt(decision: decision(turnId: "t2"))
        plain.inheritedEffective = false
        let notCounted = RecallTurnState.recover(receipts: [plain], branchAnchor: "b1", clearActive: false)
        XCTAssertEqual(notCounted.effectiveTurn, 0, "没生效的回复不计轮")
        XCTAssertNil(notCounted.lastAppliedTurnId)

        // 重生成：新回复 attempts 为空，只靠 inherited 记这一轮
        var regen = RecallTurnReceipt(decision: decision(turnId: "t1"))
        regen.inheritedEffective = true
        XCTAssertTrue(regen.attempts.isEmpty)
        let regenState = RecallTurnState.recover(receipts: [regen], branchAnchor: "b1", clearActive: false)
        XCTAssertEqual(regenState.effectiveTurn, 1, "空 attempts + inherited 照计轮")
        XCTAssertEqual(regenState.lastAppliedTurnId, "t1")

        // disabled 分支：继承的生效照样认这一轮已应用，但不推进轮次
        var disabled = RecallTurnReceipt(decision: decision(turnId: "t3", gateReason: .disabled))
        disabled.inheritedEffective = true
        let disabledState = RecallTurnState.recover(receipts: [disabled], branchAnchor: "b1", clearActive: false)
        XCTAssertEqual(disabledState.effectiveTurn, 0, "disabled 不推进轮次")
        XCTAssertEqual(disabledState.lastAppliedTurnId, "t3", "继承的生效照认")
    }
}
