import MemoryCore
import XCTest
@testable import 记忆花园

/// 记忆实验台界面那几样纯值（plan-memory-lab §4）：方块的数、「想起来了」三条路、参数的说法。全是编的。
final class MemoryLabPageTests: XCTestCase {
    private let pid = "fictional-lab"

    private func ref(_ kind: RecallSourceRef.Kind, _ path: String) -> RecallSourceRef {
        RecallSourceRef(profileId: pid, kind: kind, path: path, version: "v1")
    }

    private func item(_ source: RecallSourceRef, _ text: String, _ identities: [String]) -> RecallItem {
        RecallItem(source: source, text: text, identities: identities, tokenCost: 30)
    }

    private func record(text: String, push: Bool = true, pull: Bool = true, reply: String? = "好。",
                        selected: [RecallItem] = [], candidates: [RecallItem] = [], suppressions: [RecallSuppression] = [],
                        delivered: [RecallDeliveryItem] = [], reads: [RecallReadReceipt] = [],
                        gate: RecallTurnDecision.GateReason = .search) -> MemoryLabRecord {
        var tuning = RecallTuning.defaults
        tuning.archiveTriggerEnabled = push
        let decision = RecallTurnDecision(turnId: "t", branchAnchor: "memory-lab", origin: .user, gateReason: gate, tuning: tuning,
                                          topicAnchor: text, selected: selected, candidates: candidates, suppressions: suppressions,
                                          ignored: [], thawed: [], stateAfterResponse: RecallConversationState())
        var receipt = RecallTurnReceipt(decision: decision)
        receipt.delivery = RecallDelivery(id: "d", route: "api", items: delivered,
                                          gate: RecallGateSnapshot(off: nil, participates: true, triggerOff: !push, legacy: false,
                                                                   choices: [:], a2Checked: false, hiddenFragments: 0, hiddenTimeline: 0))
        receipt.reads = reads
        return MemoryLabRecord(id: UUID().uuidString, input: .init(text: text, at: Date()),
                               params: .init(items: [MemoryLabRecord.Item.pinned: true], everyRound: false, systemPush: push,
                                             recallTool: pull, tuning: tuning, model: .init(id: "c/m", name: "编的模型")),
                               happened: .init(receipt: receipt, reply: reply))
    }

    func testPulse() {
        XCTAssertEqual(AuditStation.labPulse(.init()), AuditStationPulse(figure: nil, label: "还没说过"))
        XCTAssertEqual(AuditStation.labPulse(.init(count: 12, up: 5, down: 2)), AuditStationPulse(figure: "12", label: "句 · 👍 5"))
    }

    func testWikiIndexIsCarriedByPushOrEveryRound() {
        var p = MemoryLabParams(timeline: false, pending: false, selfMemory: false, rootIndex: false, previousWindow: false,
                                pinned: false, everyRound: false, tuning: RecallTestTuning.make(archiveTriggerEnabled: false),
                                recallTool: false, modelId: "")
        XCTAssertFalse(p.rootIndexCarried)
        p.systemPush = true
        XCTAssertTrue(p.rootIndexCarried)
        XCTAssertTrue(p.windowChoices.archive, "和真聊天新窗口的「档案」同一个口径")
        p.systemPush = false
        p.everyRound = true
        XCTAssertTrue(p.rootIndexCarried)
    }

    func testThreeRoadsGroupPushedAndListNearMisses() {
        let fact = ref(.fragment, UUID().uuidString), page = ref(.page, "地点/槐序巷皮影作坊"), late = ref(.page, "人/林栖")
        let factItem = item(fact, "岚舟的皮影课改到周四晚上", ["岚舟"])
        let pageItem = item(page, "[[地点/槐序巷皮影作坊]]\n掌柜姓顾", ["皮影"])
        let lateItem = item(late, "[[人/林栖]]\n岚舟的皮影老师", ["林栖"])
        let r = record(text: "岚舟的皮影课改到周几了",
                       selected: [factItem, pageItem], candidates: [factItem, pageItem, lateItem],
                       suppressions: [RecallSuppression(source: late, reason: .pageLimit)],
                       delivered: [
                           .init(kind: RecallDeliveryItem.Kind.fragment, ref: MemoryDelivery.key(fact), shown: "岚舟的皮影课改到周四晚上", tokens: 20),
                           .init(kind: RecallDeliveryItem.Kind.page, ref: MemoryDelivery.key(page), shown: "槐序巷皮影作坊", tokens: 40),
                           .init(kind: RecallDeliveryItem.Kind.pinned, ref: "pinned", shown: "钉住 1 条", tokens: 8),
                           .init(kind: RecallDeliveryItem.Kind.cardIndex, ref: "cardIndex", shown: "卡的目录 3 组", tokens: 12),
                       ])
        let recall = MemoryLabRecall.make(r, assistant: "星砚")
        XCTAssertEqual(recall.pushed.map(\.name), ["C2 原子事实", "档案页"])
        XCTAssertEqual(recall.pushed.first?.rows.first?.note, "聊到「岚舟」")
        XCTAssertEqual(recall.pushed.last?.rows.first?.text, pageItem.text, "点开看推送进去的那一块原样")
        XCTAssertEqual(recall.missed, [.init(title: "人/林栖", note: "页数上限", text: lateItem.text)], "没聊到林栖：只写原因")
        XCTAssertEqual(recall.everyRound.map(\.name), ["钉住的", "记忆条目的目录"], "名字和参数卡上的 chip / app 现在的叫法一样")
        XCTAssertEqual(recall.count, 2)
        XCTAssertNil(recall.pushEmpty)
        XCTAssertEqual(recall.pullEmpty, "这句没去翻")
    }

    func testEmptyRoadsSayWhy() {
        let off = MemoryLabRecall.make(record(text: "嗯", push: false, pull: false, reply: nil), assistant: "星砚")
        XCTAssertEqual(off.pushEmpty, "关着")
        XCTAssertEqual(off.pullEmpty, "关着")
        XCTAssertEqual(off.everyRoundEmpty, "勾着的这时都是空的")
        XCTAssertEqual(off.count, 0)
        let short = MemoryLabRecall.make(record(text: "嗯", reply: nil, gate: .shortInput), assistant: "星砚")
        XCTAssertEqual(short.pushEmpty, "太短的不找")
        XCTAssertEqual(short.pullEmpty, "没问成模型，没翻")
    }

    func testDifferencesInWords() {
        typealias Item = MemoryLabRecord.Item
        let text = MemoryLabWords.differences([
            .init(key: Item.rootIndex, settings: "false", lab: "true"),
            .init(key: Item.systemPush, settings: "false", lab: "true"),
            .init(key: Item.recallTool, settings: "true", lab: "false"),
            .init(key: Item.tuningPrefix + RecallTuning.Field.maximumPages.rawValue, settings: "3", lab: "1"),
            .init(key: Item.model, settings: "a/x", lab: "c/m"),
        ], assistant: "星砚", model: { $0 == "c/m" ? "编的模型" : $0 })
        XCTAssertEqual(text, "wiki 目录 勾上 · 自动推送 开 · 星砚主动翻 关 · 一轮最多几页 1 · 模型 编的模型")
    }

    func testRecordedParamsRoundTrip() throws {
        var p = MemoryLabParams(timeline: true, pending: false, selfMemory: true, rootIndex: false, previousWindow: true,
                                pinned: true, everyRound: false, tuning: RecallTestTuning.make(archiveTriggerEnabled: true),
                                recallTool: true, modelId: "c/m")
        p.tuning.maximumPages = 1
        let back = try XCTUnwrap(MemoryLabParams(recorded: p.recorded(model: nil, provider: nil, settings: p)))
        XCTAssertEqual(back, p, "相邻两句比参数靠它还原")
    }

    // MARK: - 第二片：测试集（plan-memory-lab-2）

    private func store() throws -> MemoryLabStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lab-sets-ui-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return MemoryLabStore(memoryRoot: root)
    }

    private func said(_ text: String, _ verdict: MemoryLabRecord.Verdict? = nil, at: TimeInterval) -> MemoryLabRecord {
        MemoryLabRecord(id: UUID().uuidString, input: .init(text: text, at: Date(timeIntervalSince1970: at)),
                        judgment: verdict.map { .init(verdict: $0) })
    }

    func testSegmentsCountAndDeckFollowsVerdicts() throws {
        let store = try store()
        let records = [said("岚舟生日哪天", .up, at: 1), said("星砚搬完家了吗", at: 2), said("槐序巷那家糖水铺叫什么", .down, at: 3),
                       said("栎川镇降温了吗", at: 4)]
        for r in records { try store.save(r) }
        let set = try store.createSet(name: "生活琐事")
        for r in records { try store.add(recordId: r.id, toSet: set.id) }
        let entries = store.entries(inSet: set.id)
        XCTAssertEqual(MemoryLabPicks.counts(entries), [.unseen: 2, .up: 1, .down: 1])
        XCTAssertEqual(MemoryLabPicks.deck(entries, .unseen).map(\.text), ["星砚搬完家了吗", "栎川镇降温了吗"], "按挑进的先后")
        XCTAssertEqual(MemoryLabPicks.deck(entries, .up).map(\.text), ["岚舟生日哪天"])
    }

    func testThumbTapMovesTheCard() {
        typealias V = MemoryLabRecord.Verdict
        XCTAssertEqual(MemoryLabPicks.verdict(after: .up, current: nil), V.up, "没看过点 👍 → 👍 段")
        XCTAssertEqual(MemoryLabPicks.verdict(after: .down, current: nil), V.down)
        XCTAssertEqual(MemoryLabPicks.verdict(after: .down, current: .up), V.down, "👍 段点 👎 = 改判")
        XCTAssertNil(MemoryLabPicks.verdict(after: .up, current: .up), "点同一个 = 回到没看过")
        XCTAssertNil(MemoryLabPicks.verdict(after: .down, current: .down))
    }

    func testSkipGoesToTheEndAndUndoComesBackOnTop() throws {
        let store = try store()
        let records = [said("岚舟生日哪天", at: 1), said("星砚搬完家了吗", at: 2), said("栎川镇冷不冷", at: 3)]
        for r in records { try store.save(r) }
        let set = try store.createSet(name: "生活琐事")
        for r in records { try store.add(recordId: r.id, toSet: set.id) }
        let deck = MemoryLabPicks.deck(store.entries(inSet: set.id), .unseen)
        let ids = deck.map(\.id)
        var skipped = MemoryLabPicks.skipping(ids[0], in: [])
        XCTAssertEqual(MemoryLabPicks.ordered(deck, skipped: skipped, front: nil).map(\.id), [ids[1], ids[2], ids[0]], "跳过 = 放到这一段最后")
        skipped = MemoryLabPicks.skipping(ids[1], in: skipped)
        XCTAssertEqual(MemoryLabPicks.ordered(deck, skipped: skipped, front: nil).map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(MemoryLabPicks.ordered(deck, skipped: [ids[0]], front: ids[1]).map(\.id), [ids[1], ids[2], ids[0]],
                       "撤回的那张回到最上面")
    }

    func testPickMenuChecksFollowTheSets() throws {
        let store = try store()
        let a = said("岚舟生日哪天", at: 1), b = said("星砚搬完家了吗", at: 2)
        try store.save(a)
        try store.save(b)
        let daily = try store.createSet(name: "生活琐事"), people = try store.createSet(name: "人和地方")
        try store.add(recordId: a.id, toSet: daily.id)
        try store.add(recordId: a.id, toSet: people.id)
        XCTAssertEqual(MemoryLabPicks.sets(for: a, in: store.membership()), [daily.id, people.id],
                       "页面手上那条还没有 sentenceId 也认得出：句子的键就是它自己的编号")
        XCTAssertEqual(MemoryLabPicks.sets(for: b, in: store.membership()), [])
        try store.remove(sentenceId: a.sentence, fromSet: daily.id)
        XCTAssertEqual(MemoryLabPicks.sets(for: a, in: store.membership()), [people.id], "拿出后那一份不再打勾")
        try store.deleteSet(id: people.id)
        XCTAssertEqual(MemoryLabPicks.sets(for: a, in: store.membership()), [])
        XCTAssertNotNil(store.record(id: a.id), "删集子不删记录")
    }

    // MARK: - 第三片：一组参数（plan-memory-lab-3）

    private func labParams(push: Bool = true, pages: Int = 3, model: String = "c/m") -> MemoryLabParams {
        var tuning = RecallTestTuning.make(archiveTriggerEnabled: push)
        tuning.maximumPages = pages
        return MemoryLabParams(timeline: true, pending: false, selfMemory: false, rootIndex: false, previousWindow: true,
                               pinned: true, everyRound: false, tuning: tuning, recallTool: true, modelId: model)
    }

    func testGroupNames() {
        let page1 = MemoryLabParamSet(id: "g1", name: "推送最多 1 页")
        XCTAssertEqual(MemoryLabGroupWords.name(of: MemoryLabParamSet.currentId, groups: [page1]), "现在的设置")
        XCTAssertEqual(MemoryLabGroupWords.name(of: "g1", groups: [page1]), "推送最多 1 页")
        XCTAssertEqual(MemoryLabGroupWords.name(of: "gone", groups: [page1]), "删掉的一组")
        XCTAssertEqual(MemoryLabGroupWords.name(of: nil, groups: [page1]), "改过的参数")
    }

    func testShelfAndPendingLines() {
        let set = MemoryLabSet(id: "s", name: "生活琐事")
        let groups = [MemoryLabParamSet(id: "g1", name: "原子事实全带")]
        XCTAssertEqual(MemoryLabGroupWords.shelfLine(.init(set: set, count: 3, up: 0, down: 0, unseen: 3), groups: groups), "3 句")
        XCTAssertEqual(MemoryLabGroupWords.shelfLine(.init(set: set, count: 3, up: 1, down: 0, unseen: 2, latestAt: Date(),
                                                           latestParamsId: "g1"), groups: groups), "最近 · 原子事实全带")
        XCTAssertEqual(MemoryLabGroupWords.shelfLine(.init(set: set, count: 3, up: 1, down: 0, unseen: 2, latestAt: Date(),
                                                           latestParamsId: nil), groups: groups), "最近 · 改过的参数")
        XCTAssertNil(MemoryLabGroupWords.pendingLine(.init(count: 4, ran: 4)))
        XCTAssertEqual(MemoryLabGroupWords.pendingLine(.init(count: 4, ran: 1, notRun: 3)), "还有 3 句没跑")
        XCTAssertEqual(MemoryLabGroupWords.pendingLine(.init(count: 4, ran: 2, notRun: 2, failed: 2)), "2 句没问成")
        XCTAssertEqual(MemoryLabGroupWords.pendingLine(.init(count: 4, ran: 1, notRun: 3, failed: 1)), "还有 3 句没跑，其中 1 句没问成")
    }

    @MainActor
    func testSwitchingGroupsAndWhatCountsAsChanged() throws {
        let settings = labParams()
        let saved = labParams(pages: 1)
        let groups = MemoryLabGroups()
        groups.settings = settings
        groups.groups = [MemoryLabParamSet(id: "g1", name: "推送最多 1 页",
                                           params: saved.recorded(model: nil, provider: nil, settings: settings))]
        groups.select(MemoryLabParamSet.currentId)
        XCTAssertEqual(groups.name, "现在的设置")
        XCTAssertEqual(groups.runId, MemoryLabParamSet.currentId, "没改 = 记这一组")
        groups.select("g1")
        XCTAssertEqual(groups.params, saved, "换过去 = 页面上的值换成这组存的值")
        XCTAssertFalse(groups.changed)
        XCTAssertEqual(groups.runId, "g1")
        groups.params?.pinned = false
        XCTAssertTrue(groups.changed)
        XCTAssertNil(groups.runId, "在一组上改过没存 = 不算任何一组")
        groups.select("gone")
        XCTAssertEqual(groups.groupId, MemoryLabParamSet.currentId, "找不到的组回到「现在的设置」")
    }

    @MainActor
    func testModelIsTheBenchsOwnChoiceNotPartOfAGroup() {
        let settings = labParams(model: "")
        let groups = MemoryLabGroups()
        groups.settings = settings
        groups.groups = [MemoryLabParamSet(id: "g1", name: "推送最多 1 页",
                                           params: labParams(pages: 1, model: "c/stored").recorded(model: nil, provider: nil, settings: settings))]
        groups.select(MemoryLabParamSet.currentId)
        let pid = "xctest-lab-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: MemoryLabRunner.modelKey(pid)) }
        groups.pickModel("c/m", profileId: pid)
        XCTAssertFalse(groups.changed, "选模型永远不算改过")
        XCTAssertEqual(groups.runId, MemoryLabParamSet.currentId)
        XCTAssertEqual(UserDefaults.standard.string(forKey: MemoryLabRunner.modelKey(pid)), "c/m", "台子按楼层记住")
        groups.select("g1")
        XCTAssertEqual(groups.params?.modelId, "c/m", "换一组不动模型，组里存的模型不看")
        XCTAssertFalse(groups.changed)
        XCTAssertEqual(groups.runId, "g1")
        groups.select(MemoryLabParamSet.currentId)
        XCTAssertEqual(groups.params?.modelId, "c/m", "换回「现在的设置」模型也还在")
        groups.params?.tuning.maximumPages = 9
        XCTAssertEqual(groups.changes.map(\.key), [MemoryLabRecord.Item.tuningPrefix + RecallTuning.Field.maximumPages.rawValue],
                       "「改过」只比记忆参数")
    }

    func testNotRunSentencesStayOutOfTheDeck() throws {
        let store = try store()
        var ran = said("岚舟生日哪天", .up, at: 1)
        ran.paramsId = "g1"
        ran.happened = .init(reply: "三月九号。")
        let other = said("星砚搬完家了吗", at: 2)
        try store.save(ran)
        try store.save(other)
        let set = try store.createSet(name: "生活琐事")
        try store.add(recordId: ran.id, toSet: set.id)
        try store.add(recordId: other.id, toSet: set.id)
        let entries = store.entries(inSet: set.id, paramsId: "g1")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(MemoryLabPicks.counts(entries), [.up: 1], "这组下没跑过的那句不算进三段")
        XCTAssertEqual(MemoryLabPicks.deck(entries, .unseen).count, 0)

        // 这组下问过但没问成的：照样上牌堆（看得到原因），算「没看过」
        var failed = said(other.input.text, at: 3)
        failed.sentenceId = other.sentence
        failed.paramsId = "g1"
        failed.happened = .init(error: "连不上：编的出错")
        try store.save(failed)
        let again = store.entries(inSet: set.id, paramsId: "g1")
        XCTAssertEqual(MemoryLabPicks.deck(again, .unseen).map(\.record?.happened?.error), ["连不上：编的出错"])
        XCTAssertEqual(MemoryLabGroupWords.pendingLine(store.runSummary(inSet: set.id, paramsId: "g1")), "1 句没问成")
    }

    func testFreeChatListsOnlySentencesSaidThere() {
        let original = said("岚舟生日哪天", at: 1)
        var picked = original
        picked.sentenceId = original.id
        var replayed = said("岚舟生日哪天", at: 2)
        replayed.sentenceId = original.id
        let other = said("星砚搬完家了吗", at: 3)
        XCTAssertEqual(MemoryLabPicks.freeChat([picked, replayed, other]).map(\.id), [original.id, other.id],
                       "被挑进测试集的原句还在，重放出来的不列")
    }

    @MainActor
    func testEnteringASetCarriesTheHomeGroupAndItsEdits() {
        let settings = labParams()
        let groups = MemoryLabGroups()
        groups.settings = settings
        groups.groups = [MemoryLabParamSet(id: "g1", name: "推送最多 1 页",
                                           params: labParams(pages: 1).recorded(model: nil, provider: nil, settings: settings))]
        var edited = labParams(pages: 1)
        edited.pinned = false
        groups.adopt(.init(groupId: "g1", params: edited))
        XCTAssertEqual(groups.groupId, "g1", "用首页此刻的组")
        XCTAssertEqual(groups.params, edited, "改过没存的也带过去")
        XCTAssertTrue(groups.changed, "到测试集页就是「先存成一组」")
        groups.adopt(.init(groupId: "g1", params: labParams(pages: 1)))
        XCTAssertFalse(groups.changed)
    }
}
