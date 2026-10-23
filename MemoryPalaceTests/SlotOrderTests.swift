import XCTest
import SwiftData
@testable import 记忆花园

/// ④a 统一排序入口 SlotOrder：旧数据兼容读、拖动写回、酒馆 100001 组导入、absolute depth、导出往返、卡 depth_prompt。
final class SlotOrderTests: XCTestCase {

    // MARK: - 夹具

    private func profile() -> Profile {
        Profile(name: "测试", emoji: "🧪", description: "", userName: "禾禾", assistantName: "小岚",
                systemPrompt: "系统指令", characterDescription: "角色设定")
    }

    private func slot(_ id: String, _ content: String = "", role: String = "system", marker: Bool = false,
                      depth: Int = 0, order: Int = 100, position: PromptSlot.InjectionPosition? = nil) -> PromptSlot {
        PromptSlot(id: id, name: id, role: role, content: content, isSystemPrompt: marker, isMarker: marker,
                   injectionDepth: depth, injectionOrder: order, injectionPosition: position)
    }

    private func baseSlots() -> [PromptSlot] {
        [
            PromptSlot(id: PromptSlot.mainId, name: "系统指令", role: "system", isSystemPrompt: true, injectionOrder: 0),
            PromptSlot(id: PromptSlot.charDescriptionId, name: "助手设定", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 20),
            slot("custom", "自定义段", order: 30),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "对话历史", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 60),
            PromptSlot(id: PromptSlot.jailbreakId, name: "后置提醒", role: "system", content: "后置段", isSystemPrompt: true, injectionOrder: 70),
        ]
    }

    private let history: [(role: String, content: String)] = [("user", "第一句"), ("assistant", "第二句"), ("user", "最新一句")]

    private func tagged(_ slots: [PromptSlot], cacheFriendly: Bool = false) -> [TaggedSegment] {
        var preset = Preset(name: "t")
        preset.prompts = slots
        preset.sampling.cacheFriendly = cacheFriendly
        return PromptAssembler.assembleTagged(preset: preset, profile: profile(), memories: [], chatHistory: history).segments
    }

    private func index(_ segments: [TaggedSegment], _ text: String) -> Int? {
        segments.firstIndex { $0.content.contains(text) }
    }

    private func lastHistory(_ segments: [TaggedSegment]) -> Int? {
        segments.lastIndex { $0.source == .chatHistory }
    }

    private func stPreset(prompts: [[String: Any]], order: Any?, extensions: [String: Any]? = nil) throws -> Data {
        var json: [String: Any] = ["prompts": prompts]
        if let order { json["prompt_order"] = order }
        if let extensions { json["extensions"] = extensions }
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func stPrompt(_ id: String, position: Int? = nil, depth: Int = 0, order: Int? = nil) -> [String: Any] {
        var p: [String: Any] = ["identifier": id, "name": id, "role": "system", "content": "内容\(id)", "injection_depth": depth]
        if let position { p["injection_position"] = position }
        if let order { p["injection_order"] = order }
        return p
    }

    // MARK: - 旧数据兼容读

    func testLegacyReadFollowsInjectionOrderAndDerivesPosition() throws {
        let legacy = Data(#"[{"id":"b","name":"b","role":"system","content":"","isSystemPrompt":false,"isEnabled":true,"isMarker":false,"injectionDepth":3,"injectionOrder":20,"forbidOverrides":false},{"id":"a","name":"a","role":"system","content":"","isSystemPrompt":false,"isEnabled":true,"isMarker":false,"injectionDepth":0,"injectionOrder":10,"forbidOverrides":false}]"#.utf8)
        let slots = try JSONDecoder().decode([PromptSlot].self, from: legacy)
        XCTAssertNil(slots[0].sequenceIndex)
        XCTAssertNil(slots[0].injectionPosition)
        XCTAssertEqual(slots[0].effectivePosition, .absolute, "旧 depth>0 → absolute")
        XCTAssertEqual(slots[1].effectivePosition, .relative, "旧 depth=0 → relative")
        XCTAssertEqual(SlotOrder.ordered(slots).map(\.id), ["a", "b"], "没有 sequenceIndex 按 injectionOrder")
        let normalized = SlotOrder.normalized(slots)
        XCTAssertEqual(normalized.map(\.id), ["a", "b"])
        XCTAssertEqual(normalized.map(\.sequenceIndex), [0, 1])
        XCTAssertEqual(SlotOrder.normalized(normalized), normalized, "幂等")
        // 认不出的位置值不毁整份解码
        let odd = Data(#"{"id":"x","name":"x","injectionPosition":"weird","isSystemPrompt":false,"isEnabled":true,"isMarker":false,"injectionDepth":0,"injectionOrder":1,"forbidOverrides":false,"role":"system","content":""}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PromptSlot.self, from: odd).injectionPosition, .relative)
    }

    func testMixedReadKeepsUnsequencedArrayPosition() {
        var slots = SlotOrder.normalized([slot("a", order: 0), slot("b", order: 1), slot("c", order: 2)])
        slots.insert(slot("new", order: 999), at: 1)   // 旧迁移按数组位插进来的无序号槽
        XCTAssertEqual(SlotOrder.ordered(slots).map(\.id), ["a", "new", "b", "c"])
        XCTAssertEqual(SlotOrder.normalized(slots).map(\.sequenceIndex), [0, 1, 2, 3])
    }

    // MARK: - 拖动写回后发送顺序真的变了

    func testDragChangesAssembledSendOrder() throws {
        let slots = SlotOrder.normalized(baseSlots())
        var preset = Preset(name: "t")
        preset.prompts = slots
        let before = PromptAssembler.assemble(preset: preset, profile: profile(), memories: [], chatHistory: history)
        let sp0 = try XCTUnwrap(before.systemPrompt)
        XCTAssertLessThan(try XCTUnwrap(sp0.range(of: "自定义段")).lowerBound, try XCTUnwrap(sp0.range(of: "后置段")).lowerBound)

        // iOS onMove：custom（第 2 行）挪到最后
        preset.prompts = SlotOrder.moving(preset.prompts, fromOffsets: IndexSet(integer: 2), toOffset: preset.prompts.count)
        XCTAssertEqual(preset.prompts.map(\.id).last, "custom")
        XCTAssertEqual(preset.prompts.map(\.sequenceIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(preset.prompts.first { $0.id == "custom" }?.injectionOrder, 30, "拖动不改 injectionOrder")
        let segs = PromptAssembler.assembleTagged(preset: preset, profile: profile(), memories: [], chatHistory: history).segments
        XCTAssertGreaterThan(try XCTUnwrap(index(segs, "自定义段")), try XCTUnwrap(lastHistory(segs)), "拖到历史后 → 注入到历史后")
        let after = PromptAssembler.assemble(preset: preset, profile: profile(), memories: [], chatHistory: history)
        let sp1 = try XCTUnwrap(after.systemPrompt)
        XCTAssertGreaterThan(try XCTUnwrap(sp1.range(of: "自定义段")).lowerBound, try XCTUnwrap(sp1.range(of: "后置段")).lowerBound,
                             "实发 systemPrompt 里的先后也跟着变")

        // mac 拖放：挪回 main 后面
        preset.prompts = SlotOrder.moving(preset.prompts, slotId: "custom", toIndex: 1)
        XCTAssertEqual(preset.prompts.map(\.id), [PromptSlot.mainId, "custom", PromptSlot.charDescriptionId, PromptSlot.chatHistoryId, PromptSlot.jailbreakId])
        let segs2 = tagged(preset.prompts)
        XCTAssertLessThan(try XCTUnwrap(index(segs2, "自定义段")), try XCTUnwrap(index(segs2, "角色设定")))
    }

    func testPresetManagerPersistsDraggedOrder() throws {
        let suite = "SlotOrderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let manager = PresetManager(root: root, defaults: defaults)
        var preset = Preset(name: "拖动")
        preset.prompts = [slot("b", order: 20), slot("a", order: 10)]
        manager.save(preset)
        XCTAssertEqual(manager.preset(byId: preset.id)?.prompts.map(\.id), ["a", "b"], "落盘即按读顺序归一")
        var edited = try XCTUnwrap(manager.preset(byId: preset.id))
        edited.prompts = SlotOrder.moving(edited.prompts, fromOffsets: IndexSet(integer: 0), toOffset: 2)
        manager.save(edited)
        let reloaded = try XCTUnwrap(PresetManager(root: root, defaults: defaults).preset(byId: preset.id))
        XCTAssertEqual(reloaded.prompts.map(\.id), ["b", "a"])
        XCTAssertEqual(reloaded.prompts.map(\.sequenceIndex), [0, 1])
        // 新增插槽排末尾；改深度推位置
        var added = reloaded
        added.prompts = SlotOrder.appending(slot("c", order: 0), to: added.prompts)
        XCTAssertEqual(added.prompts.map(\.id), ["b", "a", "c"])
        SlotOrder.setDepth(2, of: &added.prompts[2])
        XCTAssertEqual(added.prompts[2].injectionPosition, .absolute)
        SlotOrder.setDepth(0, of: &added.prompts[2])
        XCTAssertEqual(added.prompts[2].injectionPosition, .relative)
    }

    // MARK: - 酒馆 prompt_order

    func testImportUsesGlobal100001GroupNotLast() throws {
        let data = try stPreset(prompts: [stPrompt("a"), stPrompt("b"), stPrompt("c"), stPrompt(PromptSlot.chatHistoryId)], order: [
            ["character_id": 100001, "order": [
                ["identifier": "c", "enabled": true],
                ["identifier": PromptSlot.chatHistoryId, "enabled": true],
                ["identifier": "a", "enabled": false],
            ]],
            ["character_id": 100000, "order": [["identifier": "b", "enabled": true], ["identifier": "a", "enabled": true]]],
        ] as [[String: Any]])
        let (preset, notes) = try Preset.importSillyTavernJSON(data)
        XCTAssertEqual(notes, [])
        XCTAssertEqual(preset.prompts.map(\.id), ["c", PromptSlot.chatHistoryId, "a", "b"], "顺序按 100001 组，不按 prompts 也不取 .last")
        XCTAssertEqual(preset.prompts.map(\.isEnabled), [true, true, false, false], "组里没列的 b 关闭")
        XCTAssertEqual(preset.prompts.map(\.sequenceIndex), [0, 1, 2, 3])
        XCTAssertEqual(preset.rawJSONData, data, "其他组原样留在原文里")
        // c 在历史前、a 关了不发
        let segs = tagged(preset.prompts)
        XCTAssertLessThan(try XCTUnwrap(index(segs, "内容c")), try XCTUnwrap(segs.firstIndex { $0.source == .chatHistory }))
        XCTAssertNil(index(segs, "内容a"))
    }

    func testImportAnomaliesFallBackAndReport() throws {
        let prompts = [stPrompt("a"), stPrompt("b")]
        let cases: [(String, Any?)] = [
            ("缺组", [["character_id": 100000, "order": [["identifier": "b", "enabled": false]]]] as [[String: Any]]),
            ("多组", [["character_id": 100001, "order": [["identifier": "b", "enabled": false]]],
                     ["character_id": "100001", "order": [["identifier": "a", "enabled": false]]]] as [[String: Any]]),
            ("缺引用", [["character_id": 100001, "order": [["identifier": "b", "enabled": false], ["identifier": "ghost", "enabled": true]]]] as [[String: Any]]),
            ("重复引用", [["character_id": 100001, "order": [["identifier": "b", "enabled": false], ["identifier": "b", "enabled": true]]]] as [[String: Any]]),
            ("没有 prompt_order", nil),
        ]
        for (name, order) in cases {
            let (preset, notes) = try Preset.importSillyTavernJSON(try stPreset(prompts: prompts, order: order))
            XCTAssertFalse(notes.isEmpty, "\(name) 要报告")
            XCTAssertEqual(preset.prompts.map(\.id), ["a", "b"], "\(name) 兜底用文件顺序")
            XCTAssertEqual(preset.prompts.map(\.isEnabled), [true, true], "\(name) 兜底全开，不套任何组（含 .last）")
        }
        XCTAssertTrue(try Preset.importSillyTavernJSON(try stPreset(prompts: prompts, order: cases[2].1)).notes.joined().contains("ghost"))
    }

    // MARK: - absolute depth

    func testAbsoluteDepthZeroLandsAfterLatestHistory() throws {
        var slots = baseSlots()
        slots.append(slot("tail", "尾注段", role: "user", depth: 0, order: 100, position: .absolute))
        slots.append(slot("tailFirst", "更早尾注", role: "user", depth: 0, order: 50, position: .absolute))
        slots.append(slot("deep", "深一层", role: "user", depth: 1, order: 100, position: .absolute))
        slots.append(slot("legacyDeep", "旧深度", role: "user", depth: 2, order: 100))            // 旧数据 depth>0 → absolute
        slots.append(slot("relative3", "相对段", role: "system", depth: 3, order: 10, position: .relative)) // 显式 relative 忽略 depth
        let segs = tagged(slots)
        let last = try XCTUnwrap(lastHistory(segs))
        XCTAssertEqual(segs[last].content, "最新一句")
        XCTAssertEqual(index(segs, "更早尾注"), last + 1, "depth=0 在最新一条之后；同深度 order 小的在前")
        XCTAssertEqual(index(segs, "尾注段"), last + 2)
        XCTAssertEqual(index(segs, "深一层"), last - 1, "depth=1 在最新一条之前")
        XCTAssertEqual(try XCTUnwrap(index(segs, "旧深度")) + 1, index(segs, "第二句"), "旧 depth=2 仍按倒数第 2 条之前")
        XCTAssertLessThan(try XCTUnwrap(index(segs, "相对段")), try XCTUnwrap(segs.firstIndex { $0.source == .chatHistory }))

        // 实发层（assemble）：user 角色的 depth=0 就是 messages 最后一条
        var preset = Preset(name: "t")
        preset.prompts = slots
        let sent = PromptAssembler.assemble(preset: preset, profile: profile(), memories: [], chatHistory: history)
        XCTAssertEqual(sent.messages.last?.content, "尾注段")
        XCTAssertEqual(sent.messages.suffix(3).map(\.content), ["最新一句", "更早尾注", "尾注段"])
    }

    /// 现状记录（④b 修）：assemble() 把所有 system 段抽成前缀，absolute system 段也进 systemPrompt，不在 messages 里
    func testAbsoluteSystemSegmentIsStillHoistedByAssemble() throws {
        var slots = baseSlots()
        slots.append(slot("sysTail", "系统尾注", role: "system", depth: 0, position: .absolute))
        let segs = tagged(slots)
        XCTAssertEqual(index(segs, "系统尾注"), try XCTUnwrap(lastHistory(segs)) + 1, "检查器分段位置正确")
        var preset = Preset(name: "t")
        preset.prompts = slots
        let sent = PromptAssembler.assemble(preset: preset, profile: profile(), memories: [], chatHistory: history)
        XCTAssertTrue(sent.systemPrompt?.contains("系统尾注") == true)
        XCTAssertFalse(sent.messages.contains { $0.content.contains("系统尾注") })
    }

    func testCacheFriendlyVolatileStaysBeforeLatestWithDepthZero() throws {
        var slots = baseSlots()
        slots.append(slot("tail", "尾注段", role: "user", depth: 0, position: .absolute))
        slots.append(slot("clock", "现在是 {{time}}", role: "system", depth: 0, position: .absolute))
        var preset = Preset(name: "t")
        preset.prompts = slots
        preset.sampling.cacheFriendly = true
        let segs = PromptAssembler.assembleTagged(preset: preset, profile: profile(), memories: [], chatHistory: history,
                                                  volatileNote: "今天的日记").segments
        let last = try XCTUnwrap(lastHistory(segs))
        let volatileIdx = try XCTUnwrap(segs.firstIndex { $0.source == .volatileContext })
        XCTAssertEqual(volatileIdx, last - 1, "动态段仍在最新一条之前")
        XCTAssertNotNil(index(segs, "现在是"), "absolute 的时间宏槽按深度注入，不下沉")
        XCTAssertFalse(segs[volatileIdx].content.contains("现在是"))
        XCTAssertGreaterThan(try XCTUnwrap(index(segs, "尾注段")), last)
    }

    // MARK: - 导出往返

    func testExportRoundTripsInjectionPositionAndExtensions() throws {
        let raw = try stPreset(prompts: [stPrompt("r"), stPrompt("abs0", position: 1, depth: 0, order: 7), stPrompt("abs3", position: 1, depth: 3, order: 9)],
                               order: [["character_id": 100000, "order": [["identifier": "r", "enabled": true]]],
                                       ["character_id": 100001, "order": [["identifier": "abs3", "enabled": true],
                                                                          ["identifier": "r", "enabled": false],
                                                                          ["identifier": "abs0", "enabled": true]]]] as [[String: Any]],
                               extensions: ["regex_scripts": [["scriptName": "规则"]], "SPreset": ["x": 1]] as [String: Any])
        let imported = try Preset.importSillyTavernJSON(raw).preset
        XCTAssertEqual(imported.prompts.map(\.effectivePosition), [.absolute, .relative, .absolute])
        let exported = try XCTUnwrap(imported.toSillyTavernJSON())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let prompts = try XCTUnwrap(json["prompts"] as? [[String: Any]])
        XCTAssertEqual(prompts.map { $0["identifier"] as? String }, ["abs3", "r", "abs0"])
        XCTAssertEqual(prompts.map { $0["injection_position"] as? Int }, [1, 0, 1], "按真实位置写，不再固定 0")
        let ext = try XCTUnwrap(json["extensions"] as? [String: Any])
        XCTAssertNotNil(ext["regex_scripts"]); XCTAssertNotNil(ext["SPreset"])
        let groups = try XCTUnwrap(json["prompt_order"] as? [[String: Any]])
        XCTAssertEqual(groups.compactMap { SlotOrder.characterId($0["character_id"]) }, [100000, 100001], "其他组原样带回，100001 只一份")

        let again = try Preset.importSillyTavernJSON(exported)
        XCTAssertEqual(again.notes, [])
        XCTAssertEqual(again.preset.prompts.map(\.id), imported.prompts.map(\.id))
        XCTAssertEqual(again.preset.prompts.map(\.effectivePosition), imported.prompts.map(\.effectivePosition))
        XCTAssertEqual(again.preset.prompts.map(\.injectionDepth), [3, 0, 0])
        XCTAssertEqual(again.preset.prompts.map(\.injectionOrder), [9, imported.prompts[1].injectionOrder, 7])
        XCTAssertEqual(again.preset.prompts.map(\.isEnabled), [true, false, true])
    }

    // MARK: - 卡级 depth_prompt

    private func cardJSON(_ depthPrompt: [String: Any]?) throws -> Data {
        var data: [String: Any] = ["name": "深度角色", "first_mes": "你好"]
        if let depthPrompt { data["extensions"] = ["depth_prompt": depthPrompt] }
        return try JSONSerialization.data(withJSONObject: ["spec": "chara_card_v2", "spec_version": "2.0", "data": data])
    }

    func testCardDepthPromptAppendsOnceAndSkipsEmpty() throws {
        let json = try cardJSON(["prompt": "记住{{char}}怕黑", "depth": 2, "role": "user"])
        let once = SlotOrder.appendingCardDepthPrompt(cardJSON: json, to: .balanced)
        let twice = SlotOrder.appendingCardDepthPrompt(cardJSON: json, to: once)
        XCTAssertEqual(twice.prompts.filter { $0.id == PromptSlot.cardDepthPromptId }.count, 1, "不重复加")
        let added = try XCTUnwrap(once.prompts.last)
        XCTAssertEqual(added.id, PromptSlot.cardDepthPromptId)
        XCTAssertEqual(added.name, "角色深度提示")
        XCTAssertEqual(added.role, "user")
        XCTAssertEqual(added.injectionDepth, 2)
        XCTAssertEqual(added.injectionOrder, 100)
        XCTAssertEqual(added.injectionPosition, .absolute)
        XCTAssertEqual(once.prompts.compactMap(\.sequenceIndex), Array(0..<once.prompts.count))
        for empty in [try cardJSON(["prompt": "  \n", "depth": 4, "role": "system"]), try cardJSON(nil)] {
            XCTAssertEqual(SlotOrder.appendingCardDepthPrompt(cardJSON: empty, to: .balanced).prompts.count, Preset.balanced.prompts.count)
        }
        XCTAssertEqual(SlotOrder.appendingCardDepthPrompt(cardJSON: nil, to: .balanced).prompts.count, Preset.balanced.prompts.count)
        // 发送副本：宏展开、落在倒数第 2 条之前
        let segs = tagged(once.prompts)
        let idx = try XCTUnwrap(index(segs, "记住小岚怕黑"))
        XCTAssertEqual(segs[idx + 1].content, "第二句")
    }

    @MainActor
    func testFloorMaterializationAddsDepthPromptOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SlotOrderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let schema = Schema([Conversation.self, MessageNode.self, WorldBook.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let cards = CharacterCardManager(root: root.appendingPathComponent("cards"), defaults: defaults)
        let initial = Profile(id: "original", name: "原楼层", emoji: "", description: "", userName: "你", assistantName: "助手")
        let profiles = ProfileManager(container: container, profiles: [initial], currentProfile: initial, loadError: nil,
                                      root: root.appendingPathComponent("blobs"), defaults: defaults, sideEffectsEnabled: false)
        let presets = PresetManager(root: root.appendingPathComponent("blobs"), defaults: defaults)
        profiles.characterCardManager = cards
        let service = CharacterFloorService(cards: cards, profiles: profiles, presets: presets)

        let card = CharacterCard(from: try TavernCard.parseJSON(data: try cardJSON(["prompt": "深度提示正文", "depth": 3, "role": "system"])))
        try cards.add(card)
        let first = try await service.enter(card: card)
        let second = try await service.enter(card: card)
        XCTAssertEqual(first.id, second.id)
        let instance = try XCTUnwrap(presets.preset(byId: first.presetId))
        let depthSlots = instance.prompts.filter { $0.id == PromptSlot.cardDepthPromptId }
        XCTAssertEqual(depthSlots.count, 1)
        XCTAssertEqual(depthSlots.first?.injectionDepth, 3)
        XCTAssertEqual(depthSlots.first?.role, "system")
        XCTAssertFalse(presets.templates.contains { $0.prompts.contains { $0.id == PromptSlot.cardDepthPromptId } }, "只进楼层实例，不污染模板")

        let plain = CharacterCard(from: try TavernCard.parseJSON(data: try cardJSON(["prompt": "", "depth": 4, "role": "system"])))
        try cards.add(plain)
        let plainFloor = try await service.enter(card: plain)
        XCTAssertFalse(try XCTUnwrap(presets.preset(byId: plainFloor.presetId)).prompts.contains { $0.id == PromptSlot.cardDepthPromptId })
    }
}
