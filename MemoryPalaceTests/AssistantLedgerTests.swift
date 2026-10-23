import XCTest
@testable import 记忆花园

/// 小芽 v2 账本 / 旧历史兼容 / 盖章闸门 / 权限包（plan-小芽-v2 §4，astra A1/B4/C2/C6）
@MainActor
final class AssistantLedgerTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private let suite = "xiaoya-tests-\(UUID().uuidString)"

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xiaoya-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeEngine(_ messages: [AssistantChatMessage] = []) throws -> AssistantEngine {
        let store = AssistantChatStore(fileURL: dir.appendingPathComponent("history.json"))
        store.save(messages)
        return AssistantEngine(store: store, ledger: AssistantLedger(fileURL: dir.appendingPathComponent("ledger.json")),
                               packDefaults: defaults)
    }

    private func slotChange(after: String = "华丽") -> AssistantChange {
        .updatePresetSlot(profileId: "floor-A", presetId: "p1", slotId: "slot1", slotName: "文风", before: "简洁", after: after)
    }

    // MARK: 旧历史兼容（A1）

    func testV1HistoryDecodesAndPendingBecomesLegacy() throws {
        let v1 = """
        [{"id":"\(UUID().uuidString)","isUser":false,"text":"写好了","createdAt":770000000,
          "actions":[{"id":"\(UUID().uuidString)","kind":"addWorldBookEntry","title":"世界书「花园」加条目",
                      "detail":"keys=[铃]","payloadJSON":"{\\"bookId\\":\\"x\\"}"}]},
         {"id":"\(UUID().uuidString)","isUser":true,"text":"好","createdAt":770000001}]
        """
        let msgs = try JSONDecoder().decode([AssistantChatMessage].self, from: Data(v1.utf8))
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].actions.first?.status, .legacy)
        XCTAssertNil(msgs[0].actions.first?.change)
        XCTAssertEqual(msgs[1].actions, [])
    }

    func testV2RoundTrip() throws {
        var msg = AssistantChatMessage(isUser: false, text: "t")
        msg.actions = [AssistantAction(change: slotChange()),
                       AssistantAction(change: .deleteWorldBookEntry(profileId: "f", bookId: "b", bookName: "花园",
                                                                     entry: FakeAssistantWorkspace.entry("k", "v"), index: 2))]
        let back = try JSONDecoder().decode([AssistantChatMessage].self, from: JSONEncoder().encode([msg]))
        XCTAssertEqual(back, [msg])
        XCTAssertEqual(back[0].actions[0].status, .pending)
    }

    func testCorruptHistoryIsMovedAsideNotOverwritten() throws {
        let url = dir.appendingPathComponent("history.json")
        try Data("{不是 json".utf8).write(to: url)
        XCTAssertEqual(AssistantChatStore(fileURL: url).load(), [])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("history.corrupt-") }, "原文件应改名留底：\(names)")
    }

    // MARK: 账本

    func testLedgerPersistsAndMarksUndone() throws {
        let url = dir.appendingPathComponent("ledger.json")
        let ledger = AssistantLedger(fileURL: url)
        let actionId = UUID()
        let entry = try ledger.record(actionId: actionId, receipt: slotChange())
        try ledger.markUndone(entry.id)
        let reloaded = AssistantLedger(fileURL: url)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertTrue(reloaded.entry(id: entry.id)?.undone == true)
        XCTAssertEqual(reloaded.entries.last?.undoOf, entry.id)
        XCTAssertEqual(reloaded.entry(forAction: actionId)?.id, entry.id, "按提案找的是原始那笔，不是撤销记录")
    }

    func testLedgerTrimsToMaxEntries() throws {
        let ledger = AssistantLedger(fileURL: dir.appendingPathComponent("ledger.json"))
        for _ in 0..<(AssistantLedger.maxEntries + 5) { try ledger.record(actionId: UUID(), receipt: slotChange()) }
        XCTAssertEqual(ledger.entries.count, AssistantLedger.maxEntries)
    }

    // MARK: 盖章闸门（B4）

    func testStampOnlyOnceAndUndoFlow() throws {
        let action = AssistantAction(change: slotChange())
        let engine = try makeEngine([AssistantChatMessage(isUser: false, text: "", actions: [action])])
        let ws = FakeAssistantWorkspace.seeded()
        XCTAssertEqual(engine.stageState.base, .awaitingStamp)
        XCTAssertTrue(engine.stamp(action.id, in: ws))
        XCTAssertFalse(engine.stamp(action.id, in: ws), "双击只落一次")
        XCTAssertEqual(ws.presets["p1"]?.prompts[0].content, "华丽")
        let stamped = engine.messages[0].actions[0]
        XCTAssertEqual(stamped.status, .approved)
        XCTAssertTrue(engine.canUndo(stamped))
        XCTAssertEqual(engine.stageState.base, .idle, "处理完的卡不能让她一直等盖章")
        if case .done = engine.undo(action.id, in: ws, force: false) {} else { XCTFail() }
        XCTAssertEqual(engine.messages[0].actions[0].status, .undone)
        XCTAssertEqual(ws.presets["p1"]?.prompts[0].content, "简洁")
        XCTAssertFalse(engine.canUndo(engine.messages[0].actions[0]))
    }

    func testDiscardedAndLegacyCannotBeStamped() throws {
        let fresh = AssistantAction(change: slotChange())
        let legacy = AssistantAction(kind: .updatePresetSlot, title: "旧", detail: "", payloadJSON: "{}")
        let engine = try makeEngine([AssistantChatMessage(isUser: false, text: "", actions: [fresh, legacy])])
        let ws = FakeAssistantWorkspace.seeded()
        engine.discard(fresh.id)
        XCTAssertFalse(engine.stamp(fresh.id, in: ws))
        XCTAssertFalse(engine.stamp(legacy.id, in: ws))
        XCTAssertEqual(ws.presets["p1"]?.prompts[0].content, "简洁")
    }

    func testPackClosedAfterProposalBlocksStamp() throws {
        let action = AssistantAction(change: slotChange())
        let engine = try makeEngine([AssistantChatMessage(isUser: false, text: "", actions: [action])])
        defaults.set(false, forKey: XiaoyaPack.creation.storageKey)
        XCTAssertFalse(engine.stamp(action.id, in: FakeAssistantWorkspace.seeded()))
        XCTAssertEqual(engine.messages[0].actions[0].status, .failed)
    }

    func testStaleProposalFailsWithReason() throws {
        let action = AssistantAction(change: slotChange())
        let engine = try makeEngine([AssistantChatMessage(isUser: false, text: "", actions: [action])])
        let ws = FakeAssistantWorkspace.seeded()
        ws.presets["p1"]?.prompts[0].content = "她手动改过"
        XCTAssertFalse(engine.stamp(action.id, in: ws))
        XCTAssertEqual(engine.messages[0].actions[0].status, .failed)
        XCTAssertEqual(engine.messages[0].actions[0].failure, "这个插槽在这之后被改过，让小芽重新看一眼")
    }

    func testWireHistoryReportsStatus() throws {
        let action = AssistantAction(change: slotChange())
        let engine = try makeEngine([
            AssistantChatMessage(isUser: false, text: "改好了", actions: [action]),
            AssistantChatMessage(isUser: true, text: "再来一个"),
        ])
        engine.discard(action.id)
        let wire = engine.wireHistory()
        // 备注不进小芽自己的话（小模型会照抄成正文），挂在下一句用户话前面
        XCTAssertEqual(wire[0].content, "改好了")
        XCTAssertTrue(wire[1].content.contains("用户没要"))
        XCTAssertTrue(wire[1].content.hasSuffix("再来一个"))
    }

    /// v3 §4：编辑以前的话 = 这句起往后全删、原文回填；后面盖过章的卡数出来给确认框
    func testRewindTruncatesAndCountsStamped() throws {
        let stamped = AssistantAction(change: slotChange())
        let pending = AssistantAction(change: slotChange())
        let first = AssistantChatMessage(isUser: true, text: "改一下插槽")
        let second = AssistantChatMessage(isUser: true, text: "再改一次")
        let engine = try makeEngine([
            first,
            AssistantChatMessage(isUser: false, text: "好", actions: [stamped]),
            second,
            AssistantChatMessage(isUser: false, text: "好", actions: [pending]),
        ])
        XCTAssertTrue(engine.stamp(stamped.id, in: FakeAssistantWorkspace.seeded()))
        XCTAssertEqual(engine.stampedCount(from: first.id), 1)
        XCTAssertEqual(engine.stampedCount(from: second.id), 0)
        XCTAssertEqual(engine.rewind(to: second.id), "再改一次")
        XCTAssertEqual(engine.messages.count, 2)
        XCTAssertNil(engine.rewind(to: UUID()))
    }

    func testLocalHistoryMergesFollowUpOnly() throws {
        let followUp = try makeEngine([
            AssistantChatMessage(isUser: true, text: "早"),
            AssistantChatMessage(isUser: false, text: "早呀"),
            AssistantChatMessage(isUser: true, text: "帮我写一个新的角色卡"),
            AssistantChatMessage(isUser: false, text: "要写新角色卡，我得先知道角色名？"),
            AssistantChatMessage(isUser: true, text: "随便！你自己随意"),
        ])
        XCTAssertEqual(followUp.localHistory().map(\.content), ["帮我写一个新的角色卡。补充：随便！你自己随意"])
        XCTAssertEqual(followUp.localHistory().map(\.role), ["user"])

        let afterProposal = try makeEngine([
            AssistantChatMessage(isUser: true, text: "改插槽"),
            AssistantChatMessage(isUser: false, text: "改好了看看？", actions: [AssistantAction(change: slotChange())]),
            AssistantChatMessage(isUser: true, text: "今天好累"),
        ])
        XCTAssertEqual(afterProposal.localHistory().map(\.content), ["今天好累"])
        XCTAssertEqual(try makeEngine([AssistantChatMessage(isUser: true, text: "嗨")]).localHistory().map(\.content), ["嗨"])
    }

    func testFakeProposalClaimIsCaught() {
        let reply = "叫她「小满」吧～看预览卡片，喜欢就点应用～[提案「角色卡 · 小满」：用户已盖章，已生效]"
        let faked = AssistantEngine.vetReply(reply, madeProposal: false)
        XCTAssertFalse(faked.text.contains("[提案"))
        XCTAssertTrue(faked.claimedWithoutProposal)
        let honest = AssistantEngine.vetReply("看看预览卡片～", madeProposal: true)
        XCTAssertEqual(honest.text, "看看预览卡片～")
        XCTAssertFalse(honest.claimedWithoutProposal)
        XCTAssertFalse(AssistantEngine.vetReply("今天天气不错", madeProposal: false).claimedWithoutProposal)
    }

    // MARK: 权限包（C6）

    func testPackPolicyDefaultsWhenKeyMissing() {
        XCTAssertTrue(XiaoyaPackPolicy.isEnabled(.creation, defaults: defaults))
        defaults.set(false, forKey: XiaoyaPack.read.storageKey)
        XCTAssertFalse(XiaoyaPackPolicy.isEnabled(.read, defaults: defaults))
    }

    func testEveryToolBelongsToAPack() {
        for def in AssistantTools.allDefinitions {
            let name = (def["function"] as? [String: Any])?["name"] as? String ?? ""
            XCTAssertNotNil(XiaoyaPack.of(tool: name), "\(name) 没归包，会被当成未知工具")
        }
        XCTAssertNil(XiaoyaPack.of(tool: "rm_rf"))
    }
}
