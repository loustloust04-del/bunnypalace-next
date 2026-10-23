import XCTest
import SwiftData
@testable import 记忆花园

/// plan-page0-list-polish：标题清洗 / 标签→文件夹迁移 / 文件夹说明注入位置 / session 短名。
final class Page0ListPolishTests: XCTestCase {

    // MARK: - 标题清洗

    func testCardFenceBecomesLabel() {
        let raw = "```card-todo\n{\"id\":\"t-5540\",\"items\":[{\"text\":\"回邮件\"}]}\n```\n今天先做这些"
        XCTAssertEqual(ConversationTitler.sanitizedFallback(firstUser: raw), "[待办] 今天先做这些")
    }

    func testCardFenceWithJSONOnInfoLine() {
        let raw = "```card-todo {\"id\":\"t-1\",\"items\":[]}\n```"
        XCTAssertEqual(ConversationTitler.sanitizedFallback(firstUser: raw), "[待办]")
    }

    func testCodeFenceKeepsCodeDropsMarkers() {
        XCTAssertEqual(ConversationTitler.plainText("看这段 ```swift\nlet a = 1\n``` 为什么报错"), "看这段 let a = 1 为什么报错")
    }

    func testMarkdownStripped() {
        XCTAssertEqual(ConversationTitler.plainText("## 标题\n- **加粗** 和 `代码`\n> 引用 [链接](https://x.com)"),
                       "标题 加粗 和 代码 引用 链接")
    }

    func testLongTitleTruncatedByDisplayWidth() {
        let title = ConversationTitler.sanitizedFallback(firstUser: String(repeating: "记", count: 30))
        XCTAssertEqual(title, String(repeating: "记", count: 20) + "…")
        let ascii = ConversationTitler.sanitizedFallback(firstUser: String(repeating: "a", count: 50))
        XCTAssertEqual(ascii, String(repeating: "a", count: 40) + "…")
    }

    func testEmptyFallsBackToPlaceholder() {
        XCTAssertEqual(ConversationTitler.sanitizedFallback(firstUser: "  \n "), ConversationTitler.placeholderTitle)
    }

    func testCleanModelTitle() {
        XCTAssertEqual(ConversationTitler.cleanModelTitle("标题：「衰减引擎阈值修复」。\n解释……"), "衰减引擎阈值修复")
        XCTAssertEqual(ConversationTitler.cleanModelTitle("\"周末去植物园\""), "周末去植物园")
    }

    // MARK: - session 短名

    func testSessionShortName() {
        XCTAssertEqual(ConversationRow.sessionShortName("mp-cc"), "cc")
        XCTAssertEqual(ConversationRow.sessionShortName("mp-cc-52"), "cc-52")
        XCTAssertEqual(ConversationRow.sessionShortName("mp-cc-decode-2"), "cc-decode-2")
        XCTAssertEqual(ConversationRow.sessionShortName("mp-codex-3"), "codex-3")
        XCTAssertEqual(ConversationRow.sessionShortName("custom"), "custom")
    }

    // MARK: - 标签 → 文件夹迁移

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, ConversationTag.self, FavoriteItem.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func conv(_ id: String, _ ctx: ModelContext) -> Conversation {
        let c = Conversation(id: id, title: id, createTime: Date(), updateTime: Date(), currentNodeId: "", provider: "api", profileId: "p")
        ctx.insert(c)
        return c
    }

    func testMigrationPicksEarliestTagAndKeepsExistingFolder() throws {
        let ctx = try makeContext()
        let tagA = ConversationTag(name: "A", profileId: "p"), tagB = ConversationTag(name: "B", profileId: "p")
        ctx.insert(tagA); ctx.insert(tagB)
        let c1 = conv("c1", ctx), c2 = conv("c2", ctx), c3 = conv("c3", ctx)
        c3.folderId = tagB.id
        let later = FavoriteItem(conversationId: "c1", tagId: tagA.id, contentPreview: "", profileId: "p")
        later.createTime = Date(timeIntervalSince1970: 200)
        let earlier = FavoriteItem(conversationId: "c1", tagId: tagB.id, contentPreview: "", profileId: "p")
        earlier.createTime = Date(timeIntervalSince1970: 100)
        let bubble = FavoriteItem(nodeId: "n1", conversationId: "c2", tagId: tagA.id, contentPreview: "", profileId: "p")
        let c3Item = FavoriteItem(conversationId: "c3", tagId: tagA.id, contentPreview: "", profileId: "p")
        let orphan = FavoriteItem(conversationId: "c2", tagId: "deleted-tag", contentPreview: "", profileId: "p")
        [later, earlier, bubble, c3Item, orphan].forEach(ctx.insert)
        try ctx.save()

        XCTAssertEqual(try FolderMigration.migrate(context: ctx), 1)
        XCTAssertEqual(c1.folderId, tagB.id, "多个标签取最早挂上的")
        XCTAssertNil(c2.folderId, "气泡级收藏 / 已删标签不算归属")
        XCTAssertEqual(c3.folderId, tagB.id, "已有 folderId 不覆盖")
        XCTAssertEqual(try FolderMigration.migrate(context: ctx), 0, "幂等")
    }

    // MARK: - 文件夹说明注入

    func testFolderInstructionsFollowCharDescription() {
        var preset = Preset(name: "t")
        preset.prompts = [
            PromptSlot(id: PromptSlot.mainId, name: "系统指令", role: "system", isSystemPrompt: true, isMarker: false, injectionOrder: 0),
            PromptSlot(id: PromptSlot.charDescriptionId, name: "助手设定", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 20),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "对话历史", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 60),
        ]
        let profile = Profile(name: "测试", emoji: "🧪", description: "", userName: "禾禾", assistantName: "小岚",
                              systemPrompt: "系统指令", characterDescription: "角色设定")
        let segments = PromptAssembler.assembleTagged(preset: preset, profile: profile, memories: [],
                                                      chatHistory: [("user", "你好")], folderInstructions: "只聊代码").segments
        guard let folderIdx = segments.firstIndex(where: { $0.source == .folder }),
              let charIdx = segments.firstIndex(where: { $0.source == .slot(id: PromptSlot.charDescriptionId, name: "助手设定") }) else {
            return XCTFail("缺文件夹段或角色描述段")
        }
        XCTAssertEqual(folderIdx, charIdx + 1)
        XCTAssertTrue(segments[folderIdx].content.contains("只聊代码"))
        XCTAssertEqual(segments[folderIdx].role, "system")

        let without = PromptAssembler.assembleTagged(preset: preset, profile: profile, memories: [], chatHistory: [("user", "你好")]).segments
        XCTAssertFalse(without.contains { $0.source == .folder })
    }
}
