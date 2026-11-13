import XCTest
@testable import MemoryCore

/// plan `plan-memory-participation.md` §2.2 真值表逐格钉住。
final class MemoryParticipationTests: XCTestCase {
    /// 任意快照（也用于 legacy 字段的机械映射用例）。
    private func choices(timeline: Bool = true, pending: Bool = true, selfMemory: Bool = true,
                         archive: Bool = true, previousWindow: Bool = true,
                         pinned: Bool = true) -> EffectiveMemoryParticipation.Choices {
        EffectiveMemoryParticipation.Choices(
            timeline: timeline, pending: pending, selfMemory: selfMemory,
            archive: archive, previousWindow: previousWindow, pinned: pinned)
    }

    /// 真实 legacy 形状（`MemoryWindowChoices.legacy()`）：previousWindow 恒假，
    /// archive / pinned 同取 C 勾。
    private func legacyChoices(timeline: Bool = true, pending: Bool = true, selfMemory: Bool = true,
                               c: Bool = true) -> EffectiveMemoryParticipation.Choices {
        EffectiveMemoryParticipation.Choices(
            timeline: timeline, pending: pending, selfMemory: selfMemory,
            archive: c, previousWindow: false, pinned: c)
    }

    private func switches(master: Bool = true, window: Bool = true, slot: Bool = true,
                          choices: EffectiveMemoryParticipation.Choices? = nil,
                          legacy: EffectiveMemoryParticipation.Choices? = nil,
                          a2Checked: Bool = true,
                          archiveTrigger: Bool = true) -> EffectiveMemoryParticipation.Switches {
        EffectiveMemoryParticipation.Switches(
            master: master, window: window, slot: slot,
            choices: choices,
            legacy: legacy ?? legacyChoices(),
            a2Checked: a2Checked, archiveTrigger: archiveTrigger)
    }

    // MARK: - 第一行：master 关

    func testMasterOffTurnsEverythingOffAndKeepsNothingForTools() {
        let s = switches(master: false, choices: choices())
        let p = EffectiveMemoryParticipation(s)
        XCTAssertEqual(p.off, .master, "master 关的原因")
        XCTAssertFalse(p.on, "master 关 = 整体关")
        XCTAssertFalse(p.participates, "Z 段 / 工具 / 写侧也关")
        XCTAssertFalse(p.archive, "X 碎片")
        XCTAssertFalse(p.pinned, "X 钉住")
        XCTAssertFalse(p.pages, "X 页 / 触发")
        XCTAssertFalse(p.fullText, "X 原文兜底")
        XCTAssertFalse(p.selfMemory, "X 自记忆")
        XCTAssertFalse(p.previousWindow, "Z7 上窗")
        XCTAssertFalse(p.timeline, "Z 时间轴")
        XCTAssertFalse(p.pending, "Z 待续")
        XCTAssertFalse(p.anniversary, "Z 纪念日")
        XCTAssertFalse(p.a2Summary, "A2 注入")
        XCTAssertFalse(p.writeTools, "写工具下发")
        XCTAssertFalse(p.a2Write, "A2 写")
        XCTAssertEqual(p.switches, s, "原料原样保留")
        XCTAssertEqual(p.choices, choices(), "choices 解析 = 输入")
    }

    // MARK: - 第二行：本窗关参与

    func testWindowOffTurnsEverythingOffIncludingA2AndTools() {
        let s = switches(window: false, choices: choices())
        let p = EffectiveMemoryParticipation(s)
        XCTAssertEqual(p.off, .window, "本窗关的原因")
        XCTAssertFalse(p.on, "本窗关 = 整体关")
        XCTAssertFalse(p.participates, "Z 段 / 工具 / 写侧也关")
        XCTAssertFalse(p.archive, "X 碎片")
        XCTAssertFalse(p.pinned, "X 钉住")
        XCTAssertFalse(p.pages, "X 页 / 触发")
        XCTAssertFalse(p.fullText, "X 原文兜底")
        XCTAssertFalse(p.selfMemory, "X 自记忆")
        XCTAssertFalse(p.previousWindow, "Z7 上窗")
        XCTAssertFalse(p.timeline, "Z 时间轴（现状是带，P2 改）")
        XCTAssertFalse(p.pending, "Z 待续（现状是带，P2 改）")
        XCTAssertFalse(p.anniversary, "Z 纪念日")
        XCTAssertFalse(p.a2Summary, "A2 注入（现状是带，P2 改）")
        XCTAssertFalse(p.writeTools, "写工具下发（现状是发，P2 改）")
        XCTAssertFalse(p.a2Write, "A2 写（现状会写，P2 改）")
        XCTAssertEqual(p.switches, s, "原料原样保留")
        XCTAssertEqual(p.choices, choices(), "choices 解析 = 输入")
    }

    // MARK: - 第三行：本窗划掉某项（choices 给值）

    func testChoicesArchiveOffDropsArchiveAndPagesButNotPinned() {
        let p = EffectiveMemoryParticipation(
            switches(choices: choices(archive: false, pinned: true)))
        XCTAssertTrue(p.on, "整体仍开")
        XCTAssertFalse(p.archive, "划掉 archive → 碎片 / 根索引不带")
        XCTAssertFalse(p.pages, "划掉 archive → 页不带（触发开也不带）")
        XCTAssertFalse(p.fullText, "原文兜底跟页")
        XCTAssertTrue(p.pinned, "pinned 独立于 archive，照 choices.pinned")
        XCTAssertTrue(p.writeTools, "写工具不受划项影响")
        XCTAssertTrue(p.a2Write, "A2 写不受划项影响")
    }

    func testChoicesPinnedOffDropsOnlyPinned() {
        let p = EffectiveMemoryParticipation(
            switches(choices: choices(archive: true, pinned: false)))
        XCTAssertFalse(p.pinned, "划掉 pinned → 钉住不带")
        XCTAssertTrue(p.archive, "archive 独立于 pinned，照 choices.archive")
        XCTAssertTrue(p.pages, "archive 开 + 触发开 → 页带")
    }

    func testChoicesSelfMemoryOffKeepsPreviousWindow() {
        let p = EffectiveMemoryParticipation(
            switches(choices: choices(selfMemory: false, previousWindow: true)))
        XCTAssertFalse(p.selfMemory, "只划 selfMemory → 自记忆假")
        XCTAssertTrue(p.previousWindow, "previousWindow 照 choices")
        XCTAssertTrue(p.participates, "划项不动 participates")
        XCTAssertTrue(p.writeTools, "划项不动写工具")
        XCTAssertTrue(p.a2Write, "划项不动 A2 写")
    }

    func testChoicesPreviousWindowOffKeepsSelfMemory() {
        let p = EffectiveMemoryParticipation(
            switches(choices: choices(selfMemory: true, previousWindow: false)))
        XCTAssertFalse(p.previousWindow, "只划 previousWindow → Z7 假")
        XCTAssertTrue(p.selfMemory, "selfMemory 照 choices")
    }

    func testChoicesTimelineOffWithPendingOnKeepsAnniversary() {
        let p = EffectiveMemoryParticipation(
            switches(choices: choices(timeline: false, pending: true)))
        XCTAssertFalse(p.timeline, "划掉 timeline")
        XCTAssertTrue(p.pending, "pending 照 choices")
        XCTAssertTrue(p.anniversary, "只划一项 → 纪念日照带")
    }

    func testChoicesPendingOffWithTimelineOnKeepsAnniversary() {
        let p = EffectiveMemoryParticipation(
            switches(choices: choices(timeline: true, pending: false)))
        XCTAssertFalse(p.pending, "只划 pending → 待续假")
        XCTAssertTrue(p.timeline, "timeline 照 choices")
        XCTAssertTrue(p.anniversary, "只划一项 → 纪念日照带")
    }

    func testChoicesTimelineAndPendingOffDropsAnniversary() {
        let p = EffectiveMemoryParticipation(
            switches(choices: choices(timeline: false, pending: false)))
        XCTAssertFalse(p.timeline, "划掉 timeline")
        XCTAssertFalse(p.pending, "划掉 pending")
        XCTAssertFalse(p.anniversary, "两项都划 → 纪念日不带")
    }

    // MARK: - 第四行：老窗（choices 缺席 = legacy）

    func testLegacyWindowFollowsLegacyForArchiveAndPinnedButPagesIgnoreArchiveCheck() {
        let p = EffectiveMemoryParticipation(
            switches(choices: nil, legacy: legacyChoices(c: false), archiveTrigger: true))
        XCTAssertFalse(p.archive, "archive 跟 legacy.archive")
        XCTAssertFalse(p.pinned, "pinned 跟 legacy.pinned（同取 C）")
        XCTAssertTrue(p.pages, "legacy 不看 archive 勾，触发开就带（roundInputs 现状）")
        XCTAssertTrue(p.fullText, "原文兜底 = pages")
        XCTAssertFalse(p.previousWindow, "legacy.previousWindow = false")
        XCTAssertTrue(p.timeline, "legacy.timeline = A4 勾")
        XCTAssertTrue(p.pending, "legacy.pending = A4 勾")
        XCTAssertTrue(p.anniversary, "A4 勾 → 纪念日带")
        XCTAssertTrue(p.selfMemory, "legacy.selfMemory = B4 勾")
        XCTAssertTrue(p.writeTools, "写工具不受 legacy 影响")
        XCTAssertTrue(p.a2Write, "A2 写不受 legacy 影响")
    }

    func testLegacyWindowTimelinePendingAndSelfMemoryFollowLegacy() {
        let p = EffectiveMemoryParticipation(
            switches(choices: nil,
                     legacy: legacyChoices(timeline: false, pending: false,
                                           selfMemory: true, c: true)))
        XCTAssertFalse(p.timeline, "legacy.timeline = false")
        XCTAssertFalse(p.pending, "legacy.pending = false")
        XCTAssertFalse(p.anniversary, "A4 两勾都假 → 纪念日不带")
        XCTAssertTrue(p.selfMemory, "legacy.selfMemory 真")
        XCTAssertTrue(p.archive, "legacy C 真 → 碎片带")
        XCTAssertTrue(p.pinned, "legacy C 真 → 钉住带")
        XCTAssertTrue(p.participates, "老窗照 participates")
        XCTAssertTrue(p.on, "老窗槽开 → on")
    }

    func testChoicesOverrideLegacyWhenPresent() {
        let p = EffectiveMemoryParticipation(
            switches(choices: choices(),
                     legacy: legacyChoices(timeline: false, pending: false,
                                           selfMemory: false, c: false)))
        XCTAssertFalse(p.isLegacy, "给了 choices 就不是老窗")
        XCTAssertTrue(p.archive, "archive 跟 choices（不跟 legacy）")
        XCTAssertTrue(p.pinned, "pinned 跟 choices")
        XCTAssertTrue(p.pages, "pages 跟 choices.archive + 触发")
        XCTAssertTrue(p.fullText, "fullText 跟 pages")
        XCTAssertTrue(p.selfMemory, "selfMemory 跟 choices")
        XCTAssertTrue(p.previousWindow, "previousWindow 跟 choices")
        XCTAssertTrue(p.timeline, "timeline 跟 choices")
        XCTAssertTrue(p.pending, "pending 跟 choices")
        XCTAssertTrue(p.anniversary, "anniversary 跟 choices")
        XCTAssertTrue(p.a2Summary, "A2 注入照楼层勾")
    }

    func testLegacyPreviousWindowAlwaysFalseEvenIfPassedTrue() {
        let p = EffectiveMemoryParticipation(
            switches(choices: nil, legacy: choices(previousWindow: true)))
        XCTAssertTrue(p.isLegacy, "无 choices = 老窗")
        XCTAssertFalse(p.previousWindow, "老窗钉死为假，不信任 legacy 传值")
    }

    func testLegacyWindowPagesFollowArchiveTriggerOnly() {
        let p = EffectiveMemoryParticipation(
            switches(choices: nil, legacy: legacyChoices(c: false), archiveTrigger: false))
        XCTAssertFalse(p.pages, "老窗 + 触发关 → 页不带")
        XCTAssertFalse(p.fullText, "老窗 + 触发关 → 原文兜底不带")
        XCTAssertFalse(p.archive, "碎片仍跟 legacy.archive")
    }

    // MARK: - 第五行：记忆槽关

    func testSlotOffDropsInjectionButKeepsZToolsAndWrite() {
        let s = switches(slot: false, choices: choices())
        let p = EffectiveMemoryParticipation(s)
        XCTAssertEqual(p.off, .slot, "槽关的原因")
        XCTAssertFalse(p.on, "槽关 = 整体关")
        XCTAssertTrue(p.participates, "槽关不动 master && window")
        XCTAssertFalse(p.archive, "X 碎片")
        XCTAssertFalse(p.pinned, "X 钉住")
        XCTAssertFalse(p.pages, "X 页 / 触发")
        XCTAssertFalse(p.fullText, "X 原文兜底")
        XCTAssertFalse(p.selfMemory, "X 自记忆")
        XCTAssertFalse(p.previousWindow, "Z7 上窗")
        XCTAssertTrue(p.timeline, "Z 时间轴是独立插槽，照带")
        XCTAssertTrue(p.pending, "Z 待续是独立插槽，照带")
        XCTAssertTrue(p.anniversary, "纪念日照带")
        XCTAssertTrue(p.a2Summary, "A2 注入是独立插槽，照勾")
        XCTAssertTrue(p.writeTools, "写工具不走槽，照发")
        XCTAssertTrue(p.a2Write, "A2 写不走槽，照写")
        XCTAssertFalse(p.switches.slot, "switches 原样保留")
        XCTAssertTrue(p.choices.archive, "choices 保持输入（未闸）")
    }

    // MARK: - A2 注入照楼层勾

    func testA2CheckedOffDropsA2SummaryOnly() {
        let p = EffectiveMemoryParticipation(
            switches(choices: choices(), a2Checked: false))
        XCTAssertTrue(p.on, "整体仍开")
        XCTAssertFalse(p.a2Summary, "楼层 A2 勾关 → 注入不带")
        XCTAssertTrue(p.archive, "X 碎片照带")
        XCTAssertTrue(p.pinned, "X 钉住照带")
        XCTAssertTrue(p.pages, "X 页照带")
        XCTAssertTrue(p.fullText, "X 原文兜底照带")
        XCTAssertTrue(p.selfMemory, "X 自记忆照带")
        XCTAssertTrue(p.previousWindow, "Z7 照带")
        XCTAssertTrue(p.timeline, "时间轴照带")
        XCTAssertTrue(p.pending, "待续照带")
        XCTAssertTrue(p.anniversary, "纪念日照带")
        XCTAssertTrue(p.writeTools, "写工具照发")
        XCTAssertTrue(p.a2Write, "A2 写照写")
    }

    func testLegacyA2CheckedOffDropsA2SummaryOnly() {
        let p = EffectiveMemoryParticipation(
            switches(choices: nil, legacy: legacyChoices(), a2Checked: false))
        XCTAssertTrue(p.on, "老窗整体仍开")
        XCTAssertFalse(p.a2Summary, "老窗也照楼层 A2 勾：勾关 → 不带")
        XCTAssertTrue(p.archive, "碎片照 legacy")
        XCTAssertTrue(p.timeline, "时间轴照 legacy")
        XCTAssertTrue(p.anniversary, "纪念日照 legacy")
        XCTAssertTrue(p.writeTools, "写工具照发")
        XCTAssertTrue(p.a2Write, "A2 写照写")
    }

    // MARK: - 第六行：触发关

    func testTriggerOffDropsPagesAndFullTextButKeepsArchive() {
        let p = EffectiveMemoryParticipation(
            switches(choices: choices(archive: true), archiveTrigger: false))
        XCTAssertFalse(p.pages, "触发关 → 页不带")
        XCTAssertFalse(p.fullText, "触发关 → 原文兜底不带")
        XCTAssertTrue(p.archive, "碎片 / 根索引照 archive")
        XCTAssertTrue(p.pinned, "钉住不受触发影响")
        XCTAssertTrue(p.selfMemory, "自记忆不受触发影响")
        XCTAssertTrue(p.previousWindow, "Z7 不受触发影响")
        XCTAssertTrue(p.timeline, "时间轴不受触发影响")
        XCTAssertTrue(p.pending, "待续不受触发影响")
        XCTAssertTrue(p.anniversary, "纪念日不受触发影响")
        XCTAssertTrue(p.writeTools, "写工具不受触发影响")
        XCTAssertTrue(p.a2Write, "A2 写不受触发影响")
    }

    // MARK: - 全划 + A2 关 + 触发关：只留 participates

    func testAllChoicesOffA2OffTriggerOffKeepsOnlyParticipation() {
        let p = EffectiveMemoryParticipation(
            switches(choices: choices(timeline: false, pending: false, selfMemory: false,
                                      archive: false, previousWindow: false, pinned: false),
                     a2Checked: false, archiveTrigger: false))
        XCTAssertTrue(p.on, "整体仍开")
        XCTAssertTrue(p.participates, "master && window 仍真")
        XCTAssertTrue(p.writeTools, "写工具照发")
        XCTAssertTrue(p.a2Write, "A2 写照写")
        XCTAssertFalse(p.archive, "X 碎片")
        XCTAssertFalse(p.pinned, "X 钉住")
        XCTAssertFalse(p.pages, "X 页")
        XCTAssertFalse(p.fullText, "X 原文兜底")
        XCTAssertFalse(p.selfMemory, "X 自记忆")
        XCTAssertFalse(p.previousWindow, "Z7")
        XCTAssertFalse(p.timeline, "Z 时间轴")
        XCTAssertFalse(p.pending, "Z 待续")
        XCTAssertFalse(p.anniversary, "Z 纪念日")
        XCTAssertFalse(p.a2Summary, "A2 注入")
    }

    // MARK: - Off 优先级

    func testOffPriorityPrefersMasterOverWindow() {
        let p = EffectiveMemoryParticipation(switches(master: false, window: false))
        XCTAssertEqual(p.off, .master, "master 假且 window 假 → .master")
        XCTAssertFalse(p.participates, "participates 也假")
    }

    func testOffPriorityPrefersWindowOverSlot() {
        let p = EffectiveMemoryParticipation(switches(window: false, slot: false))
        XCTAssertEqual(p.off, .window, "window 假且 slot 假 → .window")
        XCTAssertFalse(p.participates, "participates 也假")
    }

    // MARK: - 第七行：来源窗隐藏集

    private func window(_ id: String, trashed: Bool = false,
                        memoryEnabled: Bool = true) -> ConversationWindow {
        ConversationWindow(
            id: id, profileId: "p", title: id,
            createTime: Date(timeIntervalSince1970: 0),
            updateTime: Date(timeIntervalSince1970: 0),
            isTrashed: trashed, memoryEnabled: memoryEnabled)
    }

    func testHiddenSourcesPicksTrashedWindow() {
        let hidden = EffectiveMemoryParticipation.hiddenSources([
            window("kept"), window("deleted", trashed: true)
        ])
        XCTAssertEqual(hidden, ["deleted"], "已删窗进隐藏集")
    }

    func testHiddenSourcesPicksMemoryOffWindow() {
        let hidden = EffectiveMemoryParticipation.hiddenSources([
            window("kept"), window("off", memoryEnabled: false)
        ])
        XCTAssertEqual(hidden, ["off"], "关参与窗进隐藏集")
    }

    func testHiddenSourcesEmptyWhenAllOpen() {
        let hidden = EffectiveMemoryParticipation.hiddenSources([window("a"), window("b")])
        XCTAssertTrue(hidden.isEmpty, "都开 → 空集")
    }

    func testHiddenSourcesFiltersMixedList() {
        let hidden = EffectiveMemoryParticipation.hiddenSources([
            window("a"),
            window("trashed", trashed: true),
            window("off", memoryEnabled: false),
            window("both", trashed: true, memoryEnabled: false),
            window("b")
        ])
        XCTAssertEqual(hidden, ["trashed", "off", "both"], "混合窗列表只挑两类")
    }

    // MARK: - 回执门控快照（plan-memory-receipt §2.1）

    func testGateSnapshotOffTriggerLegacyChoices() {
        for (caseSwitches, reason) in [(switches(master: false, choices: choices()), "master"),
                                       (switches(window: false, choices: choices()), "window"),
                                       (switches(slot: false, choices: choices()), "slot")] {
            let gate = RecallGateSnapshot(EffectiveMemoryParticipation(caseSwitches), hiddenFragments: 4, hiddenTimeline: 7)
            XCTAssertEqual(gate.off, reason)
            XCTAssertEqual(gate.participates, reason == "slot", "participates 只看 master 和窗")
            XCTAssertEqual(gate.hiddenFragments, 0, "关着不数碎片")
            XCTAssertEqual(gate.hiddenTimeline, reason == "slot" ? 7 : 0, "时间轴 / 待续只看 participates，槽关照数")
        }

        let legacy = EffectiveMemoryParticipation(switches(
            choices: nil, legacy: legacyChoices(timeline: false, pending: true, selfMemory: false, c: true), archiveTrigger: false))
        let gate = RecallGateSnapshot(legacy, hiddenFragments: 2, hiddenTimeline: 5)
        XCTAssertNil(gate.off)
        XCTAssertTrue(gate.triggerOff, "触发关")
        XCTAssertTrue(gate.legacy, "老窗")
        XCTAssertTrue(gate.participates)
        XCTAssertEqual(gate.choices, ["timeline": false, "pending": true, "selfMemory": false,
                                      "archive": true, "previousWindow": false, "pinned": true], "解析后六项")
        XCTAssertEqual(gate.a2Checked, true)
        XCTAssertEqual(gate.hiddenFragments, 2, "开着照数")
        XCTAssertEqual(gate.hiddenTimeline, 5)

        let modern = RecallGateSnapshot(EffectiveMemoryParticipation(switches(choices: choices(), a2Checked: false)),
                                        hiddenFragments: 0, hiddenTimeline: 0)
        XCTAssertFalse(modern.legacy)
        XCTAssertFalse(modern.a2Checked)
        XCTAssertFalse(modern.triggerOff)
        XCTAssertEqual(modern.choices.count, 6)
    }
}
