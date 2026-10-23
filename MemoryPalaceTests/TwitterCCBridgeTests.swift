import XCTest
import SwiftData
@testable import 记忆花园

/// 小克（ccrp）经 hub 用本地推特：`twitter_cmd` 帧 → 对应楼层跑 TwitterAITool → `twitter_result`。
@MainActor
final class TwitterCCBridgeTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var mediaRoot: URL!
    private let floorA = "xctest-ccb-a"
    private let floorB = "xctest-ccb-b"
    private var profiles: [Profile] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: Conversation.self, TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self,
            TwitterBookmarkFolder.self, TwitterFollow.self, TwitterLike.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        mediaRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-ccb-\(UUID().uuidString)")
        profiles = [
            Profile(id: floorA, name: "A 楼", emoji: "🌿", description: "", userName: "禾禾", assistantName: "小克"),
            Profile(id: floorB, name: "B 楼", emoji: "🌸", description: "", userName: "禾禾", assistantName: "莉莉"),
        ]
        context.insert(Conversation(id: "chat-b", title: "B 的会话", createTime: .now, updateTime: .now,
                                    currentNodeId: "", profileId: floorB))
        try context.save()
    }

    override func tearDownWithError() throws {
        if let mediaRoot { try? FileManager.default.removeItem(at: mediaRoot) }
        context = nil; container = nil; mediaRoot = nil
        try super.tearDownWithError()
    }

    private func send(_ input: [String: Any], chatId: String? = nil, enabled: Bool = true) -> [String: Any] {
        var frame: [String: Any] = ["type": "twitter_cmd", "id": "req-1", "input": input]
        if let chatId { frame["chat_id"] = chatId }
        return TwitterCCBridge.handle(frame, profiles: profiles, currentProfileId: floorA,
                                      context: context, mediaRoot: mediaRoot, enabled: enabled)
    }

    func testPostsOnTheCurrentFloorAsThatFloorsAI() throws {
        let r = send(["action": "post", "text": "小克来了"])
        XCTAssertEqual(r["type"] as? String, "twitter_result")
        XCTAssertEqual(r["id"] as? String, "req-1", "回包带原 id，hub 才能对上等着的请求")
        XCTAssertEqual(r["ok"] as? Bool, true, r["result"] as? String ?? "")
        let ai = try XCTUnwrap(TwitterAccounts.aiAccounts(profileId: floorA, context: context).first)
        XCTAssertEqual(ai.displayName, "小克")
        XCTAssertEqual(try context.fetch(TwitterQueries.localTimeline(profileId: floorA)).first?.text, "小克来了")
    }

    func testChatIdPicksThatConversationsFloor() throws {
        XCTAssertEqual(send(["action": "post", "text": "在 B 楼"], chatId: "chat-b")["ok"] as? Bool, true)
        XCTAssertEqual(TwitterAccounts.aiAccounts(profileId: floorB, context: context).first?.displayName, "莉莉")
        XCTAssertTrue(try context.fetch(TwitterQueries.localTimeline(profileId: floorA)).isEmpty, "不串楼")
    }

    func testErrors() {
        XCTAssertEqual(send(["action": "post", "text": "x"], chatId: "nope")["ok"] as? Bool, false)
        XCTAssertEqual(send(["action": "fly"])["ok"] as? Bool, false)
        let off = send(["action": "timeline"], enabled: false)
        XCTAssertEqual(off["ok"] as? Bool, false)
        XCTAssertTrue((off["result"] as? String ?? "").contains("关掉"))
    }
}
