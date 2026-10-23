import XCTest
@testable import 记忆花园

/// B27 世界书插槽承载（worldInfoBefore/After）特征测试。
final class WorldInfoSlotTests: XCTestCase {

    // MARK: - 夹具

    private func makeProfile() -> Profile {
        Profile(name: "测试", emoji: "🧪", description: "", userName: "禾禾", assistantName: "小岚",
                systemPrompt: "系统指令", characterDescription: "角色设定")
    }

    private func makeSlots(includeWorldInfo: Bool = true,
                           beforeEnabled: Bool = true,
                           afterEnabled: Bool = true,
                           worldInfoAfterOrder: Int = 21) -> [PromptSlot] {
        var slots: [PromptSlot] = [
            PromptSlot(id: PromptSlot.mainId, name: "系统指令", role: "system",
                       isSystemPrompt: true, isMarker: false, injectionOrder: 0),
            PromptSlot(id: PromptSlot.charDescriptionId, name: "助手设定", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 20),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "对话历史", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 60),
        ]
        if includeWorldInfo {
            slots.append(PromptSlot(id: PromptSlot.worldInfoBeforeId, name: "世界书(前)", role: "system",
                                    isSystemPrompt: true, isEnabled: beforeEnabled, isMarker: true, injectionOrder: 19))
            slots.append(PromptSlot(id: PromptSlot.worldInfoAfterId, name: "世界书(后)", role: "system",
                                    isSystemPrompt: true, isEnabled: afterEnabled, isMarker: true, injectionOrder: worldInfoAfterOrder))
        }
        return slots
    }

    private func makeEntry(_ content: String, _ position: WorldBookEntry.InsertionPosition,
                       constant: Bool = true, keys: [String] = [], order: Int = 100) -> WorldBookEntry {
        var e = WorldBookEntry()
        e.content = content
        e.position = position
        e.isConstant = constant
        e.keys = keys
        e.insertionOrder = order
        return e
    }

    private func assemble(slots: [PromptSlot], entries: [WorldBookEntry],
                          history: [(role: String, content: String)] = [("user", "你好"), ("assistant", "嗯")],
                          cacheFriendly: Bool = false) -> [TaggedSegment] {
        var preset = Preset(name: "t")
        preset.prompts = slots
        preset.sampling.cacheFriendly = cacheFriendly
        return PromptAssembler.assembleTagged(preset: preset, profile: makeProfile(), memories: [],
                                              chatHistory: history, worldBooks: [], globalEntries: entries).segments
    }

    private func indexOfWorldBook(_ segments: [TaggedSegment], containing text: String) -> Int? {
        segments.firstIndex { seg in
            if case .worldBook = seg.source { return seg.content.contains(text) }
            return false
        }
    }

    // MARK: - 插槽位承载（修复本体）

    func testAfterSlotDraggedBehindHistoryInjectsAfterHistory() {
        let slots = makeSlots(worldInfoAfterOrder: 70)   // 拖到对话历史(60)之后
        let segs = assemble(slots: slots, entries: [makeEntry("龙国正史", .afterCharDef)])

        let worldIdx = indexOfWorldBook(segs, containing: "龙国正史")
        let lastHistoryIdx = segs.lastIndex { $0.source == .chatHistory }
        XCTAssertNotNil(worldIdx)
        XCTAssertNotNil(lastHistoryIdx)
        XCTAssertGreaterThan(worldIdx!, lastHistoryIdx!, "worldInfoAfter 拖到历史后，世界书段必须跟着去历史后")
    }

    func testDefaultSlotPositionKeepsEntriesBesideCharDef() {
        let segs = assemble(slots: makeSlots(), entries: [
            makeEntry("前置设定", .beforeCharDef),
            makeEntry("后置设定", .afterCharDef),
        ])
        let beforeIdx = indexOfWorldBook(segs, containing: "前置设定")
        let afterIdx = indexOfWorldBook(segs, containing: "后置设定")
        let charIdx = segs.firstIndex { $0.source == .slot(id: PromptSlot.charDescriptionId, name: "助手设定") }
        XCTAssertNotNil(beforeIdx); XCTAssertNotNil(afterIdx); XCTAssertNotNil(charIdx)
        XCTAssertLessThan(beforeIdx!, charIdx!, "默认插槽位 19：before 桶在 charDef 前")
        XCTAssertGreaterThan(afterIdx!, charIdx!, "默认插槽位 21：after 桶在 charDef 后")
    }

    func testBucketKeepsAscendingInsertionOrder() {
        let segs = assemble(slots: makeSlots(), entries: [
            makeEntry("排序200", .afterCharDef, order: 200),
            makeEntry("排序100", .afterCharDef, order: 100),
        ])
        let idx100 = indexOfWorldBook(segs, containing: "排序100")
        let idx200 = indexOfWorldBook(segs, containing: "排序200")
        XCTAssertNotNil(idx100); XCTAssertNotNil(idx200)
        XCTAssertLessThan(idx100!, idx200!, "桶内 insertionOrder 升序（酒馆同）")
    }

    // MARK: - 关 marker / 无 marker

    func testDisabledMarkerDropsItsBucketOnly() {
        let slots = makeSlots(beforeEnabled: false)
        let segs = assemble(slots: slots, entries: [
            makeEntry("前置设定", .beforeCharDef),
            makeEntry("后置设定", .afterCharDef),
        ])
        XCTAssertNil(indexOfWorldBook(segs, containing: "前置设定"), "关 worldInfoBefore：before 桶整桶不注入（酒馆 skip 语义）")
        XCTAssertNotNil(indexOfWorldBook(segs, containing: "后置设定"), "after 桶不连坐")
    }

    func testMissingMarkerFallsBackBesideCharDef() {
        let slots = makeSlots(includeWorldInfo: false)
        let segs = assemble(slots: slots, entries: [
            makeEntry("前置设定", .beforeCharDef),
            makeEntry("后置设定", .afterCharDef),
        ])
        let beforeIdx = indexOfWorldBook(segs, containing: "前置设定")
        let afterIdx = indexOfWorldBook(segs, containing: "后置设定")
        let charIdx = segs.firstIndex { $0.source == .slot(id: PromptSlot.charDescriptionId, name: "助手设定") }
        XCTAssertNotNil(beforeIdx); XCTAssertNotNil(afterIdx); XCTAssertNotNil(charIdx)
        XCTAssertLessThan(beforeIdx!, charIdx!, "无 marker：退回 charDef 旁兜底，条目不丢")
        XCTAssertGreaterThan(afterIdx!, charIdx!)
    }

    // MARK: - cacheFriendly 与其他 position 不受影响

    func testCacheFriendlySinksKeywordEntryKeepsConstant() {
        let segs = assemble(slots: makeSlots(),
                            entries: [
                                makeEntry("常驻设定", .beforeCharDef, constant: true),
                                makeEntry("触发设定", .beforeCharDef, constant: false, keys: ["龙"]),
                            ],
                            history: [("user", "我想聊龙")],
                            cacheFriendly: true)
        XCTAssertNotNil(indexOfWorldBook(segs, containing: "常驻设定"), "常驻条目随插槽进前缀")
        XCTAssertNil(indexOfWorldBook(segs, containing: "触发设定"), "关键词命中条目不以 worldBook 段出现")
        let volatileSeg = segs.first { $0.source == .volatileContext }
        XCTAssertNotNil(volatileSeg)
        XCTAssertTrue(volatileSeg!.content.contains("触发设定"), "关键词命中条目下沉 volatile 伪 user 段")
    }

    func testAtDepthEntryUnaffectedBySlots() {
        let segs = assemble(slots: makeSlots(), entries: [makeEntry("深度条目", .atDepth)])
        let idx = indexOfWorldBook(segs, containing: "深度条目")
        XCTAssertNotNil(idx, "atDepth 条目不归两插槽管，照常深度注入")
    }

    // MARK: - 世界书预算闸（SC-B4 刀3）

    func testWorldBookBudgetGateDefaultUnlimited() {
        UserDefaults.standard.removeObject(forKey: "wb_inject_budget")
        defer { UserDefaults.standard.removeObject(forKey: "wb_inject_budget") }
        let segs = assemble(slots: makeSlots(), entries: [
            makeEntry(String(repeating: "长条目甲", count: 50), .afterCharDef, order: 1),
            makeEntry(String(repeating: "长条目乙", count: 50), .afterCharDef, order: 2),
        ])
        XCTAssertNotNil(indexOfWorldBook(segs, containing: "长条目甲"))
        XCTAssertNotNil(indexOfWorldBook(segs, containing: "长条目乙"), "默认 0 = 无限 = 全注（现状）")
    }

    func testWorldBookBudgetGateTrimsByPriority() {
        UserDefaults.standard.set(450, forKey: "wb_inject_budget")
        defer { UserDefaults.standard.removeObject(forKey: "wb_inject_budget") }
        // 每条 ~200 字 CJK ≈ 400 tok：预算 450 只装得下第一条（按 insertionOrder 优先）
        let segs = assemble(slots: makeSlots(), entries: [
            makeEntry(String(repeating: "优先条目", count: 50), .afterCharDef, order: 1),
            makeEntry(String(repeating: "靠后条目", count: 50), .afterCharDef, order: 2),
        ])
        XCTAssertNotNil(indexOfWorldBook(segs, containing: "优先条目"), "insertionOrder 小者优先进预算")
        XCTAssertNil(indexOfWorldBook(segs, containing: "靠后条目"), "超预算裁尾")
    }
}
