import XCTest
import SwiftData
@testable import 记忆花园

/// 洞 7：跨楼层通知点了没反应。
/// 病根是 `ContentView.consumePendingPushTarget` 按「当前楼层」scoped fetch——
/// 推送 chat_id 是全库 unique 的 Conversation.id，属于别的楼层时查不到 → 静默 return。
/// 这里钉死解析器三 case（同楼层 / 异楼层 / 不存在）+ 两个 terminal 分支。
final class PushTargetResolverTests: XCTestCase {

    let floorA = "xctest-push-A"
    let floorB = "xctest-push-B"
    var container: ModelContainer!
    var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        container = try! ModelContainer(
            for: Conversation.self, MessageNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    @MainActor
    @discardableResult
    private func seed(id: String, profileId: String, currentNodeId: String = "n1") -> Conversation {
        let conv = Conversation(id: id, title: "推送落点", createTime: Date(), updateTime: Date(),
                                currentNodeId: currentNodeId, provider: "cc-bridge", profileId: profileId)
        context.insert(conv)
        try? context.save()
        return conv
    }

    /// case 1：对话就在当前楼层 → 直接导航
    @MainActor
    func testResolveSameProfileNavigates() throws {
        seed(id: "conv-same", profileId: floorA)
        let r = PushTargetResolver.resolve(
            chatId: "conv-same", currentProfileId: floorA,
            knownProfileIds: [floorA, floorB], in: context
        )
        XCTAssertEqual(r, .navigate(conversationId: "conv-same", nodeId: "n1"))
    }

    /// case 2：对话在别的楼层 → 要求先切楼层（修前这里返回 .conversationMissing = 静默失败）
    @MainActor
    func testResolveCrossProfileAsksForSwitch() throws {
        seed(id: "conv-cross", profileId: floorA)
        let r = PushTargetResolver.resolve(
            chatId: "conv-cross", currentProfileId: floorB,
            knownProfileIds: [floorA, floorB], in: context
        )
        XCTAssertEqual(r, .switchProfile(profileId: floorA, conversationId: "conv-cross"),
                       "推送 id 属于别的楼层时必须要求切楼层，不能当作对话不存在")
    }

    /// case 3：全库都没有 → terminal，调用方消费 pending key 并给可见反馈
    @MainActor
    func testResolveMissingConversation() throws {
        seed(id: "conv-other", profileId: floorA)
        let r = PushTargetResolver.resolve(
            chatId: "conv-nope", currentProfileId: floorA,
            knownProfileIds: [floorA, floorB], in: context
        )
        XCTAssertEqual(r, .conversationMissing)
    }

    /// 对话在，但它的楼层已经被删掉了 → terminal（不能无限切一个不存在的楼层）
    @MainActor
    func testResolveDeletedProfileIsTerminal() throws {
        seed(id: "conv-orphan", profileId: floorA)
        let r = PushTargetResolver.resolve(
            chatId: "conv-orphan", currentProfileId: floorB,
            knownProfileIds: [floorB], in: context
        )
        XCTAssertEqual(r, .profileMissing(profileId: floorA))
    }

    /// 空壳对话（没有 currentNodeId）→ terminal，没有可落点的消息
    @MainActor
    func testResolveEmptyConversationIsTerminal() throws {
        seed(id: "conv-empty", profileId: floorA, currentNodeId: "")
        let r = PushTargetResolver.resolve(
            chatId: "conv-empty", currentProfileId: floorA,
            knownProfileIds: [floorA], in: context
        )
        XCTAssertEqual(r, .conversationEmpty(conversationId: "conv-empty"))
    }
}
