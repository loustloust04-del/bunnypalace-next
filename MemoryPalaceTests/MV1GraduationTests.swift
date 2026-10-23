import XCTest
import SwiftData
@testable import 记忆花园

/// MV1 碎片毕业 + 画像反馈 特征测试。
/// in-memory ModelContainer；不调网络 LLM，只测纯函数层 + supersede 行为对下游列表的影响。
final class MV1GraduationTests: XCTestCase {

    let pid = "xctest-mv1"
    var container: ModelContainer!
    var context: ModelContext!
    let store = SwiftDataMemoryStore()

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Memory.self, configurations: config)
        context = ModelContext(container)
        UserDefaults.standard.removeObject(forKey: "mem_supersede_soft")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "mem_supersede_soft")
        container = nil
        super.tearDown()
    }

    // MARK: - 刀1：buildPrompt 喂画像

    func testBuildPromptIncludesProfileWhenProvided() {
        let dream = UserProfileDream(text: "禾禾是独立开发者，喜欢暖奶白配色。", sourceCount: 5, updatedAt: Date())
        let prompt = MemoryExtractor.buildPrompt(existingMemories: [], profile: dream, systemPrompt: "")
        XCTAssertTrue(prompt.contains("禾禾是独立开发者"), "画像全文应注入 {{PROFILE}} 占位符")
        // MV2 后规则 11 措辞扩展为"画像或当前记忆里已涵盖" — 只匹配稳定核心串"已涵盖的别 add"
        XCTAssertTrue(prompt.contains("已经涵盖的别 add"), "「已涵盖的别 add」规则应在 prompt 中")
    }

    func testBuildPromptFallsBackWhenNoProfile() {
        let prompt = MemoryExtractor.buildPrompt(existingMemories: [], profile: nil, systemPrompt: "")
        // 占位符被替换为"无"，不应仍带原始 {{PROFILE}}
        XCTAssertFalse(prompt.contains("{{PROFILE}}"), "占位符应被替换")
        XCTAssertTrue(prompt.contains("的画像（已凝成的整体认知）"), "画像段标题仍在")
    }

    func testBuildPromptEmptyTextFallsBackToNone() {
        let dream = UserProfileDream(text: "", sourceCount: 0, updatedAt: Date())
        let prompt = MemoryExtractor.buildPrompt(existingMemories: [], profile: dream, systemPrompt: "")
        XCTAssertFalse(prompt.contains("{{PROFILE}}"))
    }

    // MARK: - 刀2：毕业行为对下游列表的影响

    /// 模拟 dreamIfNeeded 的 consumedIds 过滤逻辑（钉住免疫）
    private func consumedIdsAfterFilter(_ memories: [Memory]) -> [UUID] {
        memories.filter { !$0.isUserExplicit }.map(\.id)
    }

    func testConsumedIdsExcludesPinned() throws {
        let auto1 = try store.add(content: "用户喜欢拿铁", category: "preference", keywords: [],
                                  profileId: pid, isUserExplicit: false, extractedBy: "t",
                                  sourceConversationId: nil, context: context)
        let auto2 = try store.add(content: "用户养了只猫", category: "fact", keywords: [],
                                  profileId: pid, isUserExplicit: false, extractedBy: "t",
                                  sourceConversationId: nil, context: context)
        let pinned = try store.add(content: "用户女儿叫小米", category: "relationship", keywords: [],
                                   profileId: pid, isUserExplicit: true, extractedBy: "t",
                                   sourceConversationId: nil, context: context)
        let memories = store.listHotAndWarm(profileId: pid, context: context)
        let consumed = consumedIdsAfterFilter(memories)
        XCTAssertEqual(consumed.count, 2, "钉住碎片不进毕业候选")
        XCTAssertTrue(consumed.contains(auto1.id))
        XCTAssertTrue(consumed.contains(auto2.id))
        XCTAssertFalse(consumed.contains(pinned.id))
    }

    func testGraduatedMemoriesDropOutOfHotAndWarm() throws {
        let mem = try store.add(content: "用户最近聊咖啡", category: "context", keywords: [],
                                profileId: pid, isUserExplicit: false, extractedBy: "t",
                                sourceConversationId: nil, context: context)
        XCTAssertEqual(store.listHot(profileId: pid, context: context).count, 1)
        XCTAssertEqual(store.listHotAndWarm(profileId: pid, context: context).count, 1)
        try store.supersede(id: mem.id, context: context)
        // 毕业后从 push（listHot）和 recall L1 候选（listHotAndWarm）双双退出——这是"彻底退役"决策
        XCTAssertTrue(store.listHot(profileId: pid, context: context).isEmpty, "毕业后退出 push 注入")
        XCTAssertTrue(store.listHotAndWarm(profileId: pid, context: context).isEmpty, "毕业后退出 recall L1 候选")
        // 但 listAll 仍可见（面板灰条），信息不丢
        XCTAssertEqual(store.listAll(profileId: pid, context: context).count, 1, "listAll 仍可见，原文与档案兜底")
    }

    func testPinnedSurvivesEvenIfMistakenlySuperseded() throws {
        // 防御层：即使开发者意外把钉住扔进毕业，钉住条本身已被 consumedIdsAfterFilter 挡掉
        // 但作为最后一道防线核实：listAll 不过滤，钉住永远可见
        let pinned = try store.add(content: "用户女儿叫小米", category: "relationship", keywords: [],
                                   profileId: pid, isUserExplicit: true, extractedBy: "t",
                                   sourceConversationId: nil, context: context)
        XCTAssertEqual(consumedIdsAfterFilter([pinned]).count, 0)
        XCTAssertEqual(store.listHot(profileId: pid, context: context).count, 1, "钉住未被毕业仍在 hot")
    }
}
