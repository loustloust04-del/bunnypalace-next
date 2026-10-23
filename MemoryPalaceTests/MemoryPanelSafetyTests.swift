import XCTest
@testable import 记忆花园

/// #067 第一步：删除确认的分流、小克的记忆「完成」判脏、预览与实发同一个记忆分层函数。
final class MemoryPanelSafetyTests: XCTestCase {

    private func mem(_ content: String, superseded: Bool = false, pinned: Bool = false) -> Memory {
        let m = Memory(content: content, category: "fact", profileId: "xctest-panel-safety", isUserExplicit: pinned)
        m.supersededAt = superseded ? Date(timeIntervalSince1970: 100) : nil
        return m
    }

    // MARK: - 删除分流

    func testActiveOnlyNoConfirm() {
        let a = mem("活1"), b = mem("活2")
        let plan = MemoryDeletePlan.plan([a, b])
        XCTAssertEqual(plan.supersede, [a.id, b.id])
        XCTAssertTrue(plan.purge.isEmpty)
        XCTAssertFalse(plan.needsConfirm)
    }

    func testSupersededOnlyNeedsConfirm() {
        let x = mem("失效1", superseded: true), y = mem("失效2", superseded: true)
        let plan = MemoryDeletePlan.plan([x, y])
        XCTAssertTrue(plan.supersede.isEmpty)
        XCTAssertEqual(plan.purge, [x.id, y.id])
        XCTAssertTrue(plan.needsConfirm)
        XCTAssertEqual(MemoryDeletePlan.confirmTitle(plan), "永久删除 2 条已失效的记忆？")
        XCTAssertEqual(MemoryDeletePlan.confirmButton(plan), "永久删除 2 条，不能恢复")
    }

    func testMixedSaysBothCounts() {
        let a = mem("活"), b = mem("活2"), x = mem("失效", superseded: true)
        let plan = MemoryDeletePlan.plan([a, x, b])
        XCTAssertEqual(plan.supersede, [a.id, b.id])
        XCTAssertEqual(plan.purge, [x.id])
        XCTAssertTrue(plan.needsConfirm)
        let title = MemoryDeletePlan.confirmTitle(plan)
        XCTAssertTrue(title.contains("2 条移到已失效"), title)
        XCTAssertTrue(title.contains("1 条已失效的永久删除"), title)
        XCTAssertEqual(MemoryDeletePlan.confirmButton(plan), "永久删除 1 条，不能恢复")
    }

    // MARK: - 小克的记忆编辑页判脏

    private func selfMemory() -> SelfMemory {
        SelfMemory(slug: "cat", name: "cat", description: "关于猫", type: "user", importance: 3, origin: "self",
                   created: Date(timeIntervalSince1970: 0), source: nil, superseded: nil, body: "正文")
    }

    func testUnchangedFormIsClean() {
        let m = selfMemory()
        XCTAssertFalse(SelfMemoryEditView.hasUnsavedEdits(m, description: "关于猫", type: "user", importance: 3, body: "正文"))
    }

    func testAnyFieldChangeIsDirty() {
        let m = selfMemory()
        XCTAssertTrue(SelfMemoryEditView.hasUnsavedEdits(m, description: "关于狗", type: "user", importance: 3, body: "正文"))
        XCTAssertTrue(SelfMemoryEditView.hasUnsavedEdits(m, description: "关于猫", type: "project", importance: 3, body: "正文"))
        XCTAssertTrue(SelfMemoryEditView.hasUnsavedEdits(m, description: "关于猫", type: "user", importance: 5, body: "正文"))
        XCTAssertTrue(SelfMemoryEditView.hasUnsavedEdits(m, description: "关于猫", type: "user", importance: 3, body: "改了"))
    }

    // MARK: - 预览与实发同一个分层函数

    private func profile(_ userName: String) -> Profile {
        Profile(name: "测试", emoji: "🧪", description: "", userName: userName, assistantName: "小克",
                systemPrompt: "系统指令", characterDescription: "")
    }

    func testLayersPutSelfMemoryBeforeArchive() {
        let layers = PromptAssembler.memoryLayers(profile: profile("猫"), selfMemory: "[我的记忆]\n记得喂猫",
                                                  memories: [mem("钉住的档案", pinned: true)], recentMessages: [], budget: nil)
        XCTAssertTrue(layers.stable.hasPrefix("[我的记忆]"), layers.stable)
        XCTAssertTrue(layers.stable.contains("[关于猫]"), layers.stable)
    }

    func testLayersSelfMemoryOnly() {
        let layers = PromptAssembler.memoryLayers(profile: profile("猫"), selfMemory: "[我的记忆]\n记得喂猫",
                                                  memories: [], recentMessages: [], budget: nil)
        XCTAssertEqual(layers.stable, "[我的记忆]\n记得喂猫")
        XCTAssertEqual(layers.volatile, "")
    }

    /// 实发 cacheFriendly 组装里的记忆常驻段 == memoryLayers 的常驻层（预览拿到的就是实发那段）
    func testAssembledStableSegmentMatchesLayers() {
        var preset = Preset(name: "t")
        preset.prompts = [
            PromptSlot(id: PromptSlot.mainId, name: "系统指令", role: "system", isSystemPrompt: true, injectionOrder: 0),
            PromptSlot(id: PromptSlot.memoryInjectionId, name: "记忆", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 40),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "对话历史", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 60),
        ]
        preset.sampling.cacheFriendly = true
        let archive = [mem("钉住的档案", pinned: true)]
        let selfText = "[我的记忆]\n记得喂猫"
        let segments = PromptAssembler.assembleTagged(preset: preset, profile: profile("猫"), memories: archive,
                                                      chatHistory: [("user", "你好")], selfMemory: selfText, memoryBudget: 5000).segments
        let layers = PromptAssembler.memoryLayers(profile: profile("猫"), selfMemory: selfText, memories: archive,
                                                  recentMessages: ["你好"], budget: 5000)
        XCTAssertTrue(segments.contains { $0.source == .memory && $0.content == layers.stable })
    }
}
