import XCTest
@testable import 记忆花园

/// B1 改卡同步楼层的判定 + B6 卡楼层称呼回退 + B2 空槽预览。纯函数，不碰真库
final class TavernSyncTests: XCTestCase {
    private func card(description: String = "旧描述", system: String = "旧系统", post: String = "旧后置",
                      examples: String = "旧示例") -> CharacterCard {
        var card = CharacterCard(name: "阿澄", description: description, personality: "温和", scenario: "海边", firstMes: "")
        card.mesExample = examples
        card.systemPrompt = system
        card.postHistoryInstructions = post
        return card
    }

    private func floor(from card: CharacterCard) -> Profile {
        Profile(id: "p1", name: "阿澄", emoji: "", description: "", userName: "你", assistantName: "阿澄",
                systemPrompt: card.systemPrompt, characterDescription: card.description,
                characterPersonality: card.personality, scenario: card.scenario,
                chatExamples: card.mesExample, postInstructions: card.postHistoryInstructions)
    }

    private func instance(main: String, jailbreak: String) -> Preset {
        var preset = Preset.balanced
        preset.ownerProfileId = "p1"
        preset.prompts = preset.prompts.map { slot in
            var slot = slot
            if slot.id == PromptSlot.mainId { slot.content = main }
            if slot.id == PromptSlot.jailbreakId { slot.content = jailbreak }
            return slot
        }
        return preset
    }

    private func content(_ preset: Preset?, _ id: String) -> String? {
        preset?.prompts.first { $0.id == id }?.content
    }

    func testUntouchedSlotsAndProfileFieldsAreSynced() {
        let old = card()
        var new = old
        new.description = "新描述"
        new.systemPrompt = "新系统"
        new.postHistoryInstructions = "新后置"
        let outcome = TavernSync.apply(card: new, sources: [old], profile: floor(from: old),
                                       preset: instance(main: "旧系统", jailbreak: "旧后置"), template: .balanced)
        XCTAssertEqual(outcome.profile.characterDescription, "新描述")
        XCTAssertEqual(outcome.profile.systemPrompt, "新系统")
        XCTAssertEqual(outcome.profile.postInstructions, "新后置")
        XCTAssertEqual(content(outcome.preset, PromptSlot.mainId), "新系统")
        XCTAssertEqual(content(outcome.preset, PromptSlot.jailbreakId), "新后置")
        XCTAssertTrue(outcome.skipped.isEmpty)
    }

    func testEditedSlotIsKeptAndReported() {
        let old = card()
        var new = old
        new.systemPrompt = "新系统"
        let outcome = TavernSync.apply(card: new, sources: [old], profile: floor(from: old),
                                       preset: instance(main: "我自己改的", jailbreak: "旧后置"), template: .balanced)
        XCTAssertEqual(content(outcome.preset, PromptSlot.mainId), "我自己改的")
        XCTAssertEqual(outcome.skipped.count, 1)
    }

    func testEditedSlotIsSilentWhenCardFieldUnchanged() {
        let old = card()
        var new = old
        new.description = "新描述"
        let outcome = TavernSync.apply(card: new, sources: [old], profile: floor(from: old),
                                       preset: instance(main: "我自己改的", jailbreak: "旧后置"), template: .balanced)
        XCTAssertEqual(content(outcome.preset, PromptSlot.mainId), "我自己改的")
        XCTAssertTrue(outcome.skipped.isEmpty, "卡这一栏没变，槽不同是她自己改的，不算没覆盖")
    }

    func testEmptyCardFieldMeansSlotKeptTemplateText() {
        let old = card(system: "")
        var new = old
        new.systemPrompt = "新系统"
        var template = Preset.balanced
        template.prompts = template.prompts.map { slot in
            var slot = slot
            if slot.id == PromptSlot.mainId { slot.content = "模板原文" }
            return slot
        }
        let outcome = TavernSync.apply(card: new, sources: [old], profile: floor(from: old),
                                       preset: instance(main: "模板原文", jailbreak: "旧后置"), template: template)
        XCTAssertEqual(content(outcome.preset, PromptSlot.mainId), "新系统", "导卡时卡字段空 → 槽是模板原文，也算没改过")

        let cleared = TavernSync.apply(card: old, sources: [new], profile: floor(from: new),
                                       preset: instance(main: "新系统", jailbreak: "旧后置"), template: template)
        XCTAssertEqual(content(cleared.preset, PromptSlot.mainId), "模板原文", "卡字段清空 → 槽回到模板原文（makeFloor 同口径）")
    }

    func testForbidOverridesSlotIsNeverTouched() {
        let old = card()
        var new = old
        new.systemPrompt = "新系统"
        var preset = instance(main: "旧系统", jailbreak: "旧后置")
        if let index = preset.prompts.firstIndex(where: { $0.id == PromptSlot.mainId }) { preset.prompts[index].forbidOverrides = true }
        let outcome = TavernSync.apply(card: new, sources: [old], profile: floor(from: old), preset: preset, template: .balanced)
        XCTAssertEqual(content(outcome.preset, PromptSlot.mainId), "旧系统")
        XCTAssertTrue(outcome.skipped.isEmpty)
    }

    func testOriginalCardCountsAsSource() {
        let original = card()
        var declined = original
        declined.systemPrompt = "第二版"
        var latest = declined
        latest.systemPrompt = "第三版"
        // 第二版没同步：楼层还停在原件；改第三版时 previous = 第二版，原件也要算来源
        let outcome = TavernSync.apply(card: latest, sources: [declined, original], profile: floor(from: original),
                                       preset: instance(main: "旧系统", jailbreak: "旧后置"), template: .balanced)
        XCTAssertEqual(content(outcome.preset, PromptSlot.mainId), "第三版")
    }

    func testNoInstanceStillSyncsProfile() {
        let old = card()
        var new = old
        new.scenario = "山里"
        let outcome = TavernSync.apply(card: new, sources: [old], profile: floor(from: old), preset: nil, template: nil)
        XCTAssertEqual(outcome.profile.scenario, "山里")
        XCTAssertNil(outcome.preset)
    }

    func testTouchesFloorAndNeedsSync() {
        let old = card()
        var renamed = old
        renamed.name = "新名字"
        renamed.creatorNotes = "备注"
        XCTAssertFalse(TavernSync.touchesFloor(old: old, new: renamed))
        var edited = old
        edited.mesExample = "新示例"
        XCTAssertTrue(TavernSync.touchesFloor(old: old, new: edited))
        XCTAssertFalse(TavernSync.needsSync(card: old, profile: floor(from: old)))
        XCTAssertTrue(TavernSync.needsSync(card: edited, profile: floor(from: old)))
    }

    func testUserNameFallback() {
        XCTAssertEqual(TavernSync.userName(["粟粟", "全局"]), "粟粟")
        XCTAssertEqual(TavernSync.userName(["你", "全局"]), "全局", "楼层还是默认「你」= 没填")
        XCTAssertEqual(TavernSync.userName(["  ", nil, "引导填的"]), "引导填的")
        XCTAssertEqual(TavernSync.userName([nil, "", "你"]), "你")
        XCTAssertEqual(TavernSync.userName([]), "你")
    }

    func testCardFieldPreview() {
        let profile = floor(from: card(examples: ""))
        XCTAssertEqual(TavernSync.cardFieldPreview(slotId: PromptSlot.charDescriptionId, profile: profile)?.text, "旧描述")
        XCTAssertNil(TavernSync.cardFieldPreview(slotId: PromptSlot.dialogueExamplesId, profile: profile), "楼层上没示例就不预览")
        XCTAssertNil(TavernSync.cardFieldPreview(slotId: PromptSlot.mainId, profile: profile))
        var long = profile
        long.characterDescription = String(repeating: "长", count: 400)
        XCTAssertEqual(TavernSync.cardFieldPreview(slotId: PromptSlot.charDescriptionId, profile: long)?.text.count, 301)
    }
}
