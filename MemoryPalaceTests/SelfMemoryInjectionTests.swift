import XCTest
@testable import 记忆花园

/// 第二刀 B3：「我的记忆」常驻注入——五级 + 最近 N 条全文、其余目录、预算；插槽里排在档案前面；记账分开。
final class SelfMemoryInjectionTests: XCTestCase {

    private func mem(_ name: String, importance: Int = 3, created: Date = Date(), superseded: Date? = nil, body: String = "正文") -> SelfMemory {
        SelfMemory(slug: SelfMemoryStore.slugify(name), name: name, description: "关于\(name)", type: "user",
                   importance: importance, origin: "self", created: created, source: nil, superseded: superseded, body: body)
    }

    func testFiveLevelAndRecentFullRestIndexed() {
        let base = Date()
        let list = [mem("五级", importance: 5, created: base.addingTimeInterval(-9000), body: "五级正文")]
            + (0..<7).map { i in mem("普通\(i)", created: base.addingTimeInterval(TimeInterval(-i * 60)), body: "普通正文\(i)") }
            + [mem("失效", superseded: base, body: "失效正文")]
        let b = SelfMemoryInjection.build(list, recentCount: 5, budget: 100_000)
        XCTAssertTrue(b.text.hasPrefix("[我的记忆]"))
        XCTAssertTrue(b.text.contains("五级正文"))
        XCTAssertTrue(b.text.contains("普通正文0") && b.text.contains("普通正文4"))
        XCTAssertFalse(b.text.contains("普通正文5"), "第 6 条起只进目录")
        XCTAssertTrue(b.text.contains("关于普通5"))
        XCTAssertFalse(b.text.contains("失效正文") || b.text.contains("关于失效"), "已失效不注入")
        XCTAssertEqual(b.fullCount, 6)
        XCTAssertEqual(b.indexCount, 2)
        XCTAssertTrue(b.text.contains("fs_read"))
    }

    func testRespectsBudget() {
        let list = (0..<5).map { mem("m\($0)", body: String(repeating: "长", count: 400)) }
        let b = SelfMemoryInjection.build(list, recentCount: 5, budget: 300)
        XCTAssertLessThanOrEqual(b.tokens, 320)
        XCTAssertLessThan(b.fullCount, 5)
    }

    func testEmptyGivesNoBlock() {
        XCTAssertEqual(SelfMemoryInjection.build([], recentCount: 5, budget: 1000).text, "")
    }

    // MARK: - 全文候选（常驻页「为什么带」用）：抽出来前后输出逐字不变

    private func day(_ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))!
    }

    private var fixedList: [SelfMemory] {
        [mem("alpha", importance: 5, created: day(10), body: "五级正文"),
         mem("beta", importance: 3, created: day(12), body: "乙"),
         mem("gamma", importance: 2, created: day(11), body: "丙"),
         mem("delta", importance: 3, created: day(9), body: "丁"),
         mem("gone", importance: 5, created: day(13), superseded: day(14), body: "失效")]
    }

    /// 逐字锁住输出：重要度 5 全文 → 最近 N 条全文（新→旧）→ 其余目录 → 尾注
    func testBuildTextVerbatim() {
        let list = fixedList
        let delta = list[3]
        let expected = ["[我的记忆]",
                        "### 关于alpha（5 级 · 10-10）\n五级正文",
                        "### 关于beta（3 级 · 10-12）\n乙",
                        "### 关于gamma（2 级 · 10-11）\n丙",
                        "目录（其余 1 条）：\n- 关于delta（3 级 · 10-09 · memory/self/\(delta.fileName)）",
                        SelfMemoryInjection.footer].joined(separator: "\n\n")
        let b = SelfMemoryInjection.build(list, recentCount: 2, budget: 100_000)
        XCTAssertEqual(b.text, expected)
        XCTAssertEqual(b.fullCount, 3)
        XCTAssertEqual(b.indexCount, 1)
        XCTAssertEqual(b.tokens, Memory.estimateTokens(expected))
        XCTAssertEqual(b.fullSlugs, Set([list[0].slug, list[1].slug, list[2].slug]))
    }

    func testFullCandidatesReasons() {
        let list = fixedList
        let c = SelfMemoryInjection.fullCandidates(list, recentCount: 2)
        XCTAssertEqual(c.map(\.memory.slug), [list[0].slug, list[1].slug, list[2].slug], "重要度 5 在前，再最近 2 条（新→旧）；失效的不算")
        XCTAssertEqual(c.map(\.reason), [.five, .recent, .recent])
        XCTAssertEqual(SelfMemoryInjection.fullCandidates(list, recentCount: 3).map(\.memory.slug).last, list[3].slug, "N 改了跟着变")
        XCTAssertEqual(SelfMemoryInjection.fullCandidates(list, recentCount: 0).map(\.reason), [.five])
    }

    /// fullSlugs 和全文块一一对应：预算装不下降成目录行的不在里面
    func testFullSlugsMatchFullBlocks() {
        let list = (0..<5).map { mem("m\($0)", created: day(10 + $0), body: String(repeating: "长", count: 60)) }
        let b = SelfMemoryInjection.build(list, recentCount: 5, budget: 300)
        XCTAssertGreaterThan(b.fullCount, 0)
        XCTAssertLessThan(b.fullCount, 5, "预算只够装几条全文")
        XCTAssertEqual(b.fullSlugs.count, b.fullCount)
        for m in list {
            let full = b.text.contains("### \(m.description)（")
            XCTAssertEqual(b.fullSlugs.contains(m.slug), full, m.slug)
        }
        XCTAssertTrue(SelfMemoryInjection.build([], recentCount: 5, budget: 1000).fullSlugs.isEmpty)
    }

    // MARK: - 插槽：我的记忆在档案前面，档案吃剩下的预算

    private func assemble(cacheFriendly: Bool, memories: [Memory], selfText: String?, budget: Int?) -> String {
        var preset = Preset(name: "t")
        preset.prompts = [
            PromptSlot(id: PromptSlot.mainId, name: "系统指令", role: "system", isSystemPrompt: true, injectionOrder: 0),
            PromptSlot(id: PromptSlot.memoryInjectionId, name: "记忆", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 40),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "对话历史", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 60),
        ]
        preset.sampling.cacheFriendly = cacheFriendly
        let profile = Profile(name: "测试", emoji: "🧪", description: "", userName: "猫", assistantName: "小克",
                              systemPrompt: "系统指令", characterDescription: "")
        return PromptAssembler.assembleTagged(preset: preset, profile: profile, memories: memories,
                                              chatHistory: [("user", "你好")], selfMemory: selfText, memoryBudget: budget)
            .segments.map(\.content).joined(separator: "\n")
    }

    func testSelfBlockBeforeArchiveInBothModes() {
        let archive = [Memory(content: "钉住的档案", category: "fact", profileId: "xctest-self-inj", isUserExplicit: true)]
        for cf in [false, true] {
            let all = assemble(cacheFriendly: cf, memories: archive, selfText: "[我的记忆]\n她明天复诊", budget: nil)
            let a = all.range(of: "[我的记忆]"), b = all.range(of: "钉住的档案")
            XCTAssertNotNil(a, "cacheFriendly=\(cf)")
            XCTAssertNotNil(b, "cacheFriendly=\(cf)")
            if let a, let b { XCTAssertLessThan(a.lowerBound, b.lowerBound, "我的记忆排在档案前面") }
        }
    }

    func testSelfBlockAloneWhenNoArchive() {
        XCTAssertTrue(assemble(cacheFriendly: false, memories: [], selfText: "[我的记忆]\nx", budget: nil).contains("[我的记忆]"))
    }

    func testArchiveUsesRemainingBudget() {
        let archive = [Memory(content: "钉住的档案", category: "fact", profileId: "xctest-self-inj", isUserExplicit: true)]
        let all = assemble(cacheFriendly: false, memories: archive, selfText: "[我的记忆]\nx", budget: 0)
        XCTAssertFalse(all.contains("钉住的档案"), "预算被我的记忆用完，档案装不下")
    }

    // MARK: - 记账

    func testMeterRecordsSelfPartSeparately() {
        let pid = "xctest-self-inj-meter"
        MemoryInjectionMeter.clear(profileId: pid)
        defer { MemoryInjectionMeter.clear(profileId: pid) }
        MemoryInjectionMeter.record(profileId: pid, hits: [], memories: [], selfTokens: 120, selfCount: 3)
        let r = MemoryInjectionMeter.load(profileId: pid)
        XCTAssertEqual(r?.selfTokens, 120)
        XCTAssertEqual(r?.selfCount, 3)
        XCTAssertEqual(r?.tokens, 0)
    }
}
