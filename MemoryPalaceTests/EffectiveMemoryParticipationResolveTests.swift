import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// `EffectiveMemoryParticipation.resolve` 的接线（plan-memory-participation §2.3 / §4）：
/// master / 预设记忆槽 / 触发覆盖 / 本窗 choices 各自从哪里读，以及读不到时落到 legacy 的口径。
final class EffectiveMemoryParticipationResolveTests: XCTestCase {
    private let pid = "xctest-participation-resolve"
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "EffectiveMemoryParticipationResolveTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func resolve(_ conversation: Conversation? = nil, preset: Preset? = nil,
                         archiveTrigger: Bool? = nil) -> EffectiveMemoryParticipation {
        EffectiveMemoryParticipation.resolve(profileId: pid, conversation: conversation, preset: preset,
                                             defaults: defaults, archiveTrigger: archiveTrigger)
    }

    private func window(_ choices: MemoryWindowChoices?) -> Conversation {
        let c = Conversation(id: "resolve-window", title: "T", createTime: Date(), updateTime: Date(), currentNodeId: "")
        c.profileId = pid
        c.memoryWindowChoices = choices
        return c
    }

    // MARK: - master / slot

    func testMasterComesFromDefaults() {
        defaults.set(false, forKey: "mem_master")
        let off = resolve()
        XCTAssertEqual(off.off, .master, "mem_master = false：整体关的原因是 master")
        XCTAssertFalse(off.participates)

        defaults.set(true, forKey: "mem_master")
        let on = resolve()
        XCTAssertNil(on.off)
        XCTAssertTrue(on.participates)
    }

    func testSlotComesFromPresetMemorySlot() {
        defaults.set(true, forKey: "mem_master")
        XCTAssertNil(resolve().off, "preset 不给：槽视为开（预热 / recall 执行点的口径）")

        var disabled = Preset.balanced
        disabled.prompts = disabled.prompts.map { slot in
            guard slot.id == PromptSlot.memoryInjectionId else { return slot }
            var copy = slot
            copy.isEnabled = false
            return copy
        }
        let off = resolve(preset: disabled)
        XCTAssertEqual(off.off, .slot, "记忆槽关 = 整体关的原因是 slot")
        XCTAssertFalse(off.on)
        XCTAssertTrue(off.participates, "槽只影响 X / Z7，不影响 Z 段 / 工具 / 写侧")

        var plain = Preset.balanced
        plain.prompts = plain.prompts.map { slot in
            guard slot.id == PromptSlot.memoryInjectionId else { return slot }
            var copy = slot
            copy.isMarker = false
            return copy
        }
        XCTAssertEqual(resolve(preset: plain).off, .slot, "记忆槽被改成普通插槽同样视为关")
        XCTAssertNil(resolve(preset: Preset.balanced).off)
    }

    // MARK: - 触发开关覆盖

    func testArchiveTriggerOverrideBeatsStore() {
        defaults.set(true, forKey: "mem_master")
        RecallTuningStore.save(RecallTestTuning.make(archiveTriggerEnabled: false), profileId: pid, defaults: defaults)
        XCTAssertFalse(resolve().pages, "不传：跟 store")
        XCTAssertTrue(resolve(archiveTrigger: true).pages, "参数传 true 覆盖 store")

        RecallTuningStore.save(RecallTestTuning.make(archiveTriggerEnabled: true), profileId: pid, defaults: defaults)
        XCTAssertTrue(resolve().pages)
        XCTAssertFalse(resolve(archiveTrigger: false).pages, "参数传 false 覆盖 store")
    }

    // MARK: - 每轮全带

    /// 「每轮全带」读楼层那一勾（没写过 = 不勾），只听它自己；这个窗口划掉「档案」时不带，老窗不看 wiki 目录那一勾
    func testEveryRoundComesFromItsOwnFloorCheck() {
        defaults.set(true, forKey: "mem_master")
        XCTAssertFalse(resolve().everyRound, "没写过 = 不勾")
        XCTAssertTrue(resolve().cards, "老窗：批过的记忆条目是候选")
        for (key, value) in [("mem_inject_full", true), ("mem_inject_keyword", true), (MemoryOpenWindow.cKey, true)] {
            defaults.set(value, forKey: key)
            XCTAssertFalse(resolve().everyRound, "\(key) 不决定每轮全带")
        }
        for trigger in [true, false] {
            for root in [true, false] {
                RecallTuningStore.save(RecallTestTuning.make(archiveTriggerEnabled: trigger), profileId: pid, defaults: defaults)
                MemoryOpenWindowStore.save(.c, root, profileId: pid, defaults: defaults)
                MemoryOpenWindow.setEveryRound(true, profileId: pid, defaults: defaults)
                XCTAssertTrue(resolve().everyRound, "勾着：聊到才带 \(trigger) · wiki 目录 \(root) 都带")
                XCTAssertEqual(resolve().archive, root, "wiki 目录那一勾只管目录")
                XCTAssertEqual(resolve().pages, trigger)
                var crossed = MemoryWindowChoices(timeline: true, pending: true, selfMemory: true, archive: false,
                                                  previousWindow: false, pinned: true)
                XCTAssertFalse(resolve(window(crossed)).everyRound, "这个窗口划掉了档案")
                XCTAssertFalse(resolve(window(crossed)).cards)
                crossed.archive = true
                XCTAssertTrue(resolve(window(crossed)).everyRound)
                MemoryOpenWindow.setEveryRound(false, profileId: pid, defaults: defaults)
                XCTAssertFalse(resolve().everyRound)
                XCTAssertFalse(resolve(window(crossed)).everyRound)
            }
        }
        XCTAssertFalse(MemoryOpenWindow.everyRound(profileId: "另一层", defaults: defaults), "只管这一个楼层")
        defaults.set(false, forKey: "mem_master")
        MemoryOpenWindow.setEveryRound(true, profileId: pid, defaults: defaults)
        XCTAssertFalse(resolve().everyRound, "记忆总开关关着什么都不带")
    }

    /// 老窗的钉住只听楼层「钉住的」那一勾（没写过 = 开），不跟 wiki 目录那一勾
    func testLegacyPinnedFollowsThePinnedCheckOnly() {
        defaults.set(true, forKey: "mem_master")
        for root in [true, false] {
            MemoryOpenWindowStore.save(.c, root, profileId: pid, defaults: defaults)
            XCTAssertTrue(resolve().pinned, "wiki 目录 \(root)")
            MemoryWindowChoices.setDefault(.pinned, false, profileId: pid, defaults: defaults)
            XCTAssertFalse(resolve().pinned, "wiki 目录 \(root)")
            MemoryWindowChoices.setDefault(.pinned, true, profileId: pid, defaults: defaults)
        }
    }

    // MARK: - 本窗 choices / legacy

    /// P2-d：窗在回收站 = 本窗关参与（真值表「本窗关参与」含回收站）
    func testTrashedWindowCountsAsWindowOff() {
        defaults.set(true, forKey: "mem_master")
        let conv = window(nil)
        conv.isTrashed = true
        let trashed = resolve(conv)
        XCTAssertFalse(trashed.switches.window, "回收站里的窗不算参与")
        XCTAssertFalse(trashed.participates)
        XCTAssertEqual(trashed.off, .window)

        conv.isTrashed = false
        XCTAssertTrue(resolve(conv).participates, "拿出回收站照旧参与")
    }

    func testConversationChoicesWinAndMissingFallBackToLegacy() {
        defaults.set(true, forKey: "mem_master")
        MemoryOpenWindowStore.save(.c, true, profileId: pid, defaults: defaults)

        var mine = MemoryWindowChoices.allOff
        mine.pinned = true
        let stored = resolve(window(mine))
        XCTAssertFalse(stored.isLegacy)
        XCTAssertFalse(stored.choices.archive, "本窗划掉档案")
        XCTAssertTrue(stored.choices.pinned)
        XCTAssertFalse(stored.archive, "archive 跟本窗 choices，不跟楼层 C 勾")

        let legacy = MemoryWindowChoices.legacy(profileId: pid, defaults: defaults)
        XCTAssertTrue(legacy.archive, "同一份 defaults 里 C 勾着")
        let old = resolve(nil)
        XCTAssertTrue(old.isLegacy, "没有 choices = 老窗")
        XCTAssertEqual(old.choices, legacy.participationChoices, "老窗读 legacy 的转换值")
    }
}
