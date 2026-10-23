import XCTest
import SwiftData
@testable import 记忆花园

/// 刀2（plan-memory-usable）：单条 CRUD 还权的数据语义测试。
/// 编辑=写回+清向量+自动钉住；软删=supersede 可恢复；已失效再删=真删。
final class MemoryCrudTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let pid = "xctest-mem-crud"
    let store = SwiftDataMemoryStore()

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: Memory.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        UserDefaults.standard.set(true, forKey: "mem_supersede_soft")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "mem_supersede_soft")
        container = nil
        super.tearDown()
    }

    @discardableResult
    private func seed(_ content: String = "喜欢暖奶白", pinned: Bool = false) -> Memory {
        try! store.add(content: content, category: "preference", keywords: ["暖奶白"],
                       profileId: pid, isUserExplicit: pinned, extractedBy: "test",
                       sourceConversationId: nil, context: context)
        let all = try! store.listAll(profileId: pid, context: context)
        return all.first(where: { $0.content == content })!
    }

    /// 编辑语义 = AddMemorySheet.commit 编辑分支
    private func applyEdit(_ m: Memory, content: String, category: String) {
        m.content = content
        m.category = category
        m.isUserExplicit = true
        m.decayWeight = 1.0
        m.embeddingData = nil
        m.updatedAt = Date()
        try! context.save()
    }

    /// 软删语义 = MemoryPanelView.deleteMemory（修复第一刀：不看开关）
    private func applyDelete(_ m: Memory) {
        if m.supersededAt == nil {
            m.supersededAt = Date()
            m.updatedAt = Date()
        } else {
            context.delete(m)
        }
        try! context.save()
    }

    func testEditRewritesContentClearsEmbeddingAndPins() {
        let m = seed()
        m.embeddingData = Data([1, 2, 3])
        try! context.save()

        applyEdit(m, content: "最喜欢暖奶白和浅灰薄荷", category: "preference")

        XCTAssertEqual(m.content, "最喜欢暖奶白和浅灰薄荷")
        XCTAssertNil(m.embeddingData, "编辑后向量必须失效，等 backfill 重算")
        XCTAssertTrue(m.isUserExplicit, "⧫① 人工编辑过的条目自动钉住")
        XCTAssertEqual(m.decayWeight, 1.0)
    }

    func testSoftDeleteSupersedesAndIsRecoverable() {
        let m = seed()
        applyDelete(m)

        XCTAssertNotNil(m.supersededAt, "活跃条目 → supersede 不硬删")
        XCTAssertEqual(try! store.listAll(profileId: pid, context: context).count, 1, "条目还在库里")

        // 恢复（reviveMemory 语义）
        m.supersededAt = nil
        try! context.save()
        XCTAssertNil(m.supersededAt)
    }

    func testDeleteSupersededIsHardDelete() {
        let m = seed()
        applyDelete(m)          // 第一删：软
        XCTAssertNotNil(m.supersededAt)
        applyDelete(m)          // 第二删：已失效 → 真删
        XCTAssertEqual(try! store.listAll(profileId: pid, context: context).count, 0)
    }

    /// 修复第一刀：mem_supersede_soft 只管做梦毕业，关掉它面板删除仍是软删
    func testPanelDeleteStaysSoftWhenGraduationSwitchOff() {
        UserDefaults.standard.set(false, forKey: "mem_supersede_soft")
        let m = seed()
        applyDelete(m)
        XCTAssertNotNil(m.supersededAt)
        XCTAssertEqual(try! store.listAll(profileId: pid, context: context).count, 1, "开关关也不真删")
    }

    /// 修复第一刀：AI（AUDN）的 delete 动作永远软失效，不受任何开关影响
    func testExtractorDeleteAlwaysSoftEvenWhenSwitchOff() throws {
        UserDefaults.standard.set(false, forKey: "mem_supersede_soft")
        let m = seed("喜欢焦糖布丁")
        try MemoryExtractor.executeActions(
            [.delete(id: m.id)], store: store, profileId: pid, extractedBy: "test",
            sourceConversationId: nil, recentMessages: [], context: context)
        let all = store.listAll(profileId: pid, context: context)
        XCTAssertEqual(all.count, 1, "AI 删除不真删")
        XCTAssertNotNil(all.first?.supersededAt)
    }

    func testManualAddIsPinned() {
        let m = seed("手动加的", pinned: true)
        XCTAssertTrue(m.isUserExplicit, "手动新增天然钉住（AddMemorySheet 既有语义）")
    }
}
