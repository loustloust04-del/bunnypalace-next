import XCTest
@testable import 记忆花园

/// 第二刀 C：档案段标签「[关于用户]」→「[关于{她的称呼}]」（粟粟 10-03 批），没设称呼用「对方」；「高级」限制可调。
final class ArchiveLabelTests: XCTestCase {

    private func profile(_ userName: String) -> Profile {
        Profile(name: "测试", emoji: "🧪", description: "", userName: userName, assistantName: "小克",
                systemPrompt: "系统指令", characterDescription: "")
    }

    func testLabelUsesUserName() {
        XCTAssertEqual(PromptAssembler.archiveLabel(profile("猫")), "关于猫")
        XCTAssertEqual(PromptAssembler.archiveLabel(profile("  ")), "关于对方")
    }

    func testAssembledArchiveHasNoUserWord() {
        var preset = Preset(name: "t")
        preset.prompts = [
            PromptSlot(id: PromptSlot.mainId, name: "系统指令", role: "system", isSystemPrompt: true, injectionOrder: 0),
            PromptSlot(id: PromptSlot.memoryInjectionId, name: "记忆", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 40),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "对话历史", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 60),
        ]
        let archive = [Memory(content: "钉住的档案", category: "fact", profileId: "xctest-label", isUserExplicit: true)]
        for cf in [false, true] {
            preset.sampling.cacheFriendly = cf
            let text = PromptAssembler.assembleTagged(preset: preset, profile: profile("猫"), memories: archive, chatHistory: [("user", "你好")])
                .segments.map(\.content).joined(separator: "\n")
            XCTAssertTrue(text.contains("[关于猫]"), "cacheFriendly=\(cf)")
            XCTAssertFalse(text.contains("[关于用户"), "cacheFriendly=\(cf)")
        }
    }

    func testAdvancedLimitsReadFromDefaults() {
        let d = UserDefaults.standard
        let keys = ["mem_self_recent_count", "mem_self_daily_limit", "mem_self_body_limit", "mem_self_budget_percent"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { v.map { d.set($0, forKey: k) } ?? d.removeObject(forKey: k) } }
        keys.forEach { d.removeObject(forKey: $0) }
        XCTAssertEqual([MemoryFlags.selfRecentCount, MemoryFlags.selfDailyLimit, MemoryFlags.selfBodyLimit, MemoryFlags.selfBudgetPercent], [5, 12, 800, 100])
        d.set(3, forKey: "mem_self_recent_count")
        d.set(150, forKey: "mem_self_budget_percent")
        XCTAssertEqual(MemoryFlags.selfRecentCount, 3)
        XCTAssertEqual(MemoryFlags.selfBudgetPercent, 100, "超过 100 截到 100")
    }
}
