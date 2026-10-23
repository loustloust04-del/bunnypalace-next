import XCTest
@testable import 记忆花园

/// 内存工作台：mac 单测跑在粟粟真实的偏好域里，卡库 / 预设不能碰真的
@MainActor
final class FakeAssistantWorkspace: AssistantWorkspace {
    var profileId = "floor-A"
    var currentPresetId = "p1"
    var cardList: [CharacterCard] = []
    var presets: [String: Preset] = [:]
    var books: [String: [WorldBookEntry]] = [:]
    var failNextWorldBookSave = false
    var page2Appearance = Page2Appearance()
    var page2HomeIsFree = true
    var stageTheme = "mint"
    var failNextAppearanceSave = false

    func setCurrentPresetId(_ id: String) { currentPresetId = id }
    func card(id: String) -> CharacterCard? { cardList.first { $0.id == id } }
    func cards() -> [CharacterCard] { cardList }
    func addCard(_ card: CharacterCard) { cardList.append(card) }
    func updateCard(_ card: CharacterCard) {
        if let i = cardList.firstIndex(where: { $0.id == card.id }) { cardList[i] = card }
    }
    func deleteCard(id: String) { cardList.removeAll { $0.id == id } }
    func preset(id: String) -> Preset? { presets[id] }
    func savePreset(_ preset: Preset) { presets[preset.id] = preset }
    func instantiate(templateId: String, name: String) -> Preset {
        var p = presets[templateId]!
        p.id = "inst-\(presets.count)"
        p.name = name
        p.ownerProfileId = profileId
        presets[p.id] = p
        return p
    }
    func removeInstance(id: String) { presets[id] = nil }
    func worldBookEntries(bookId: String) -> [WorldBookEntry]? { books[bookId] }
    func setWorldBookEntries(bookId: String, _ entries: [WorldBookEntry]) throws {
        if failNextWorldBookSave { failNextWorldBookSave = false; throw AssistantStampError.invalid("存盘失败") }
        books[bookId] = entries
    }

    func savePage2Appearance(_ appearance: Page2Appearance) throws {
        if failNextAppearanceSave { failNextAppearanceSave = false; throw AssistantStampError.invalid("外观没有保存") }
        page2Appearance = appearance
    }
    func setStageTheme(_ raw: String) { stageTheme = raw }

    static func seeded() -> FakeAssistantWorkspace {
        let ws = FakeAssistantWorkspace()
        var preset = Preset(id: "p1", name: "日常")
        preset.prompts = [PromptSlot(id: "slot1", name: "文风", content: "简洁"),
                          PromptSlot(id: PromptSlot.mainId, name: "主提示", content: "骨架")]
        preset.sampling = SamplingParams(temperature: 0.7, topP: 0.95, maxTokens: 800, contextDepth: 40)
        ws.presets["p1"] = preset
        ws.presets["tpl"] = Preset(id: "tpl", name: "模板")
        ws.cardList = [CharacterCard(name: "小满", description: "旧人设", personality: "", scenario: "", firstMes: "")]
        ws.books["book"] = [entry("月见坂", "一条坡道", comment: "地名"), entry("神社", "坡顶的神社")]
        return ws
    }

    static func entry(_ key: String, _ content: String, comment: String = "") -> WorldBookEntry {
        var e = WorldBookEntry()
        e.keys = [key]
        e.content = content
        e.comment = comment
        return e
    }
}

/// 小芽 v2 盖章 / 撤销（plan-小芽-v2 §4.3/§4.4，astra 验收矩阵「写入 / 撤销」行）
@MainActor
final class AssistantStampTests: XCTestCase {

    func testCreateCharacterThenUndo() throws {
        let ws = FakeAssistantWorkspace.seeded()
        let card = CharacterCard(name: "阿澄", description: "d", personality: "", scenario: "", firstMes: "")
        _ = try AssistantStamp.apply(.createCharacter(card: card), in: ws)
        XCTAssertNotNil(ws.card(id: card.id))
        XCTAssertEqual(AssistantStamp.undo(.createCharacter(card: card), in: ws, force: false), .done("删掉了角色卡「阿澄」"))
        XCTAssertNil(ws.card(id: card.id))
    }

    func testDuplicateNameRefused() {
        let ws = FakeAssistantWorkspace.seeded()
        let dup = CharacterCard(name: "小满", description: "d", personality: "", scenario: "", firstMes: "")
        XCTAssertThrowsError(try AssistantStamp.apply(.createCharacter(card: dup), in: ws))
    }

    func testUpdateFieldChecksBeforeAndUndoDetectsLaterEdit() throws {
        let ws = FakeAssistantWorkspace.seeded()
        let id = ws.cardList[0].id
        let change = AssistantChange.updateCharacterField(cardId: id, cardName: "小满", field: "description", before: "旧人设", after: "新人设")
        _ = try AssistantStamp.apply(change, in: ws)
        XCTAssertEqual(ws.card(id: id)?.description, "新人设")
        // 盖章后粟粟又手动改了 → 撤销先报冲突，force 才覆盖
        ws.cardList[0].description = "她自己改的"
        XCTAssertEqual(AssistantStamp.undo(change, in: ws, force: false),
                       .conflict("这之后又被改过，撤销会把那些改动一起覆盖掉"))
        XCTAssertEqual(ws.card(id: id)?.description, "她自己改的")
        if case .done = AssistantStamp.undo(change, in: ws, force: true) {} else { XCTFail() }
        XCTAssertEqual(ws.card(id: id)?.description, "旧人设")
    }

    func testStaleBeforeRefusesStamp() {
        let ws = FakeAssistantWorkspace.seeded()
        let id = ws.cardList[0].id
        ws.cardList[0].description = "提案之后被改过"
        let change = AssistantChange.updateCharacterField(cardId: id, cardName: "小满", field: "description", before: "旧人设", after: "新人设")
        XCTAssertThrowsError(try AssistantStamp.apply(change, in: ws)) { error in
            XCTAssertEqual(error as? AssistantStampError, .changedSince("这个字段"))
        }
        XCTAssertEqual(ws.card(id: id)?.description, "提案之后被改过")
    }

    /// 空旧值是合法数据（astra B1）：场景原本为空也能改、也能撤回空
    func testEmptyBeforeIsValid() throws {
        let ws = FakeAssistantWorkspace.seeded()
        let id = ws.cardList[0].id
        let change = AssistantChange.updateCharacterField(cardId: id, cardName: "小满", field: "scenario", before: "", after: "夏天")
        _ = try AssistantStamp.apply(change, in: ws)
        if case .done = AssistantStamp.undo(change, in: ws, force: false) {} else { XCTFail() }
        XCTAssertEqual(ws.card(id: id)?.scenario, "")
    }

    func testSlotChangeAnchorsToPresetNotJustFloor() {
        let ws = FakeAssistantWorkspace.seeded()
        let change = AssistantChange.updatePresetSlot(profileId: "floor-A", presetId: "p1", slotId: "slot1", slotName: "文风", before: "简洁", after: "华丽")
        ws.currentPresetId = "tpl"   // 同一层换了预设
        XCTAssertThrowsError(try AssistantStamp.apply(change, in: ws))
        XCTAssertEqual(ws.presets["p1"]?.prompts[0].content, "简洁")
    }

    func testLockedSlotRefused() {
        let ws = FakeAssistantWorkspace.seeded()
        let change = AssistantChange.updatePresetSlot(profileId: "floor-A", presetId: "p1", slotId: PromptSlot.mainId, slotName: "主提示", before: "骨架", after: "x")
        XCTAssertThrowsError(try AssistantStamp.apply(change, in: ws))
    }

    func testStaleFloorRefused() {
        let ws = FakeAssistantWorkspace.seeded()
        ws.profileId = "floor-B"
        let change = AssistantChange.updatePresetSlot(profileId: "floor-A", presetId: "p1", slotId: "slot1", slotName: "文风", before: "简洁", after: "华丽")
        XCTAssertThrowsError(try AssistantStamp.apply(change, in: ws)) { XCTAssertEqual($0 as? AssistantStampError, .staleFloor) }
        XCTAssertEqual(AssistantStamp.undo(change, in: ws, force: true), .failed("这是别的楼层的改动，切回那层再撤销"))
    }

    func testSamplingIntegerAndUndo() throws {
        let ws = FakeAssistantWorkspace.seeded()
        let change = AssistantChange.updatePresetSampling(profileId: "floor-A", presetId: "p1", presetName: "日常", changes: [
            SamplingChange(key: "temperature", before: 0.7, after: 0.9),
            SamplingChange(key: "maxTokens", before: 800, after: 1200),
        ])
        _ = try AssistantStamp.apply(change, in: ws)
        XCTAssertEqual(ws.presets["p1"]?.sampling.temperature, 0.9)
        XCTAssertEqual(ws.presets["p1"]?.sampling.maxTokens, 1200)
        if case .done = AssistantStamp.undo(change, in: ws, force: false) {} else { XCTFail() }
        XCTAssertEqual(ws.presets["p1"]?.sampling.maxTokens, 800)
    }

    func testCreatePresetReceiptAndUndo() throws {
        let ws = FakeAssistantWorkspace.seeded()
        let change = AssistantChange.createPreset(profileId: "floor-A", templateId: "tpl", templateName: "模板", name: "新的",
                                                  previousPresetId: "p1", newInstanceId: nil)
        let receipt = try AssistantStamp.apply(change, in: ws)
        guard case .createPreset(_, _, _, _, _, let newId?) = receipt else { return XCTFail("回执没带新实例 id") }
        XCTAssertEqual(ws.currentPresetId, newId)
        if case .done = AssistantStamp.undo(receipt, in: ws, force: false) {} else { XCTFail() }
        XCTAssertEqual(ws.currentPresetId, "p1")
        XCTAssertNil(ws.presets[newId])
    }

    func testCreatePresetUndoRefusedAfterSwitchingAway() throws {
        let ws = FakeAssistantWorkspace.seeded()
        let receipt = try AssistantStamp.apply(.createPreset(profileId: "floor-A", templateId: "tpl", templateName: "模板", name: "新的",
                                                             previousPresetId: "p1", newInstanceId: nil), in: ws)
        ws.currentPresetId = "tpl"
        if case .failed = AssistantStamp.undo(receipt, in: ws, force: true) {} else { XCTFail() }
    }

    func testAddEntryThenUndoById() throws {
        let ws = FakeAssistantWorkspace.seeded()
        let entry = FakeAssistantWorkspace.entry("铃", "檐下的铃")
        let change = AssistantChange.addWorldBookEntry(profileId: "floor-A", bookId: "book", bookName: "花园", entry: entry)
        _ = try AssistantStamp.apply(change, in: ws)
        XCTAssertEqual(ws.books["book"]?.count, 3)
        XCTAssertThrowsError(try AssistantStamp.apply(change, in: ws), "同一条不能加两次")
        if case .done = AssistantStamp.undo(change, in: ws, force: false) {} else { XCTFail() }
        XCTAssertEqual(ws.books["book"]?.map(\.content), ["一条坡道", "坡顶的神社"])
    }

    /// 只改内容：备注原样保留（astra B1，旧实现会无条件把备注清空）
    func testUpdateEntryKeepsUntouchedFields() throws {
        let ws = FakeAssistantWorkspace.seeded()
        let before = ws.books["book"]![0]
        var after = before
        after.content = "傍晚的石阶坡道"
        let change = AssistantChange.updateWorldBookEntry(profileId: "floor-A", bookId: "book", bookName: "花园", before: before, after: after)
        _ = try AssistantStamp.apply(change, in: ws)
        XCTAssertEqual(ws.books["book"]?[0].comment, "地名")
        XCTAssertEqual(change.fields.map(\.label), ["内容"])
        if case .done = AssistantStamp.undo(change, in: ws, force: false) {} else { XCTFail() }
        XCTAssertEqual(ws.books["book"]?[0], before)
    }

    func testDeleteEntryIsDestructiveAndUndoRestoresPosition() throws {
        let ws = FakeAssistantWorkspace.seeded()
        let target = ws.books["book"]![0]
        let change = AssistantChange.deleteWorldBookEntry(profileId: "floor-A", bookId: "book", bookName: "花园", entry: target, index: 0)
        XCTAssertEqual(change.tier, .destructive)
        let receipt = try AssistantStamp.apply(change, in: ws)
        XCTAssertEqual(ws.books["book"]?.count, 1)
        if case .done = AssistantStamp.undo(receipt, in: ws, force: false) {} else { XCTFail() }
        XCTAssertEqual(ws.books["book"]?.first, target)
    }

    func testWorldBookSaveFailureLeavesNothingHalfDone() {
        let ws = FakeAssistantWorkspace.seeded()
        ws.failNextWorldBookSave = true
        let change = AssistantChange.addWorldBookEntry(profileId: "floor-A", bookId: "book", bookName: "花园",
                                                       entry: FakeAssistantWorkspace.entry("铃", "x"))
        XCTAssertThrowsError(try AssistantStamp.apply(change, in: ws))
        XCTAssertEqual(ws.books["book"]?.count, 2)
    }
}
