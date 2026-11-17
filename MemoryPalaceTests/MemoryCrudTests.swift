import XCTest
import SwiftData
@testable import 记忆花园

/// 刀2（plan-memory-usable）：单条 CRUD 还权的数据语义测试。
/// 软删=supersede 可恢复；已失效再删=真删。编辑 / 新加（11-15 起不自动钉）的测试在 `MemoryEntryActionsTests`。
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
    private func seed(_ content: String = "喜欢暖奶白") -> Memory {
        try! store.add(content: content, category: "preference", keywords: ["暖奶白"],
                       profileId: pid, isUserExplicit: false, extractedBy: "test",
                       sourceConversationId: nil, context: context)
        let all = try! store.listAll(profileId: pid, context: context)
        return all.first(where: { $0.content == content })!
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
}
