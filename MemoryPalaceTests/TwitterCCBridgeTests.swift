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

    private func send(_ input: [String: Any], chatId: String? = nil, enabled: Bool = true,
                      levels: [String: PermissionLevel] = [:]) -> [String: Any] {
        var frame: [String: Any] = ["type": "twitter_cmd", "id": "req-1", "input": input]
        if let chatId { frame["chat_id"] = chatId }
        return TwitterCCBridge.handle(frame, profiles: profiles, currentProfileId: floorA,
                                      context: context, mediaRoot: mediaRoot,
                                      level: { levels[$0] ?? (enabled ? .bypass : .notAllowed) })
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
        XCTAssertTrue((off["result"] as? String ?? "").contains("没允许 A 楼 用推特"))
    }

    /// atrium P3⑤0：先按 chat_id 找楼层，再查那一层的推特权限（不看当前层）
    func testPermissionFollowsTheChatsFloor() throws {
        let bOff = send(["action": "post", "text": "B 不许"], chatId: "chat-b", levels: [floorA: .bypass, floorB: .notAllowed])
        XCTAssertEqual(bOff["ok"] as? Bool, false)
        XCTAssertTrue((bOff["result"] as? String ?? "").contains("没允许 B 楼 用推特"))
        XCTAssertTrue(try context.fetch(TwitterQueries.localTimeline(profileId: floorB)).isEmpty)

        let aOff = send(["action": "post", "text": "B 可以"], chatId: "chat-b", levels: [floorA: .notAllowed, floorB: .bypass])
        XCTAssertEqual(aOff["ok"] as? Bool, true, aOff["result"] as? String ?? "")
        XCTAssertEqual(try context.fetch(TwitterQueries.localTimeline(profileId: floorB)).first?.text, "B 可以")

        // 不带 chat_id = 当前层（A）
        XCTAssertEqual(send(["action": "timeline"], levels: [floorA: .notAllowed, floorB: .bypass])["ok"] as? Bool, false)
        // ⑤a：电脑那边没法问，askOnce 按不允许，文案说清
        let ask = send(["action": "post", "text": "问不了"], levels: [floorA: .askOnce])
        XCTAssertEqual(ask["ok"] as? Bool, false)
        XCTAssertTrue((ask["result"] as? String ?? "").contains("每次询问"))
        XCTAssertTrue(try context.fetch(TwitterQueries.localTimeline(profileId: floorA)).isEmpty, "askOnce 不执行")
    }

    /// atrium P3⑥a：chat_id 在 B 层、B 卸了推特 App → 档位允许也拒，文案说「没装 / 没开」；A 照旧
    func testUninstalledTwitterAppRejectsWithReason() throws {
        let perm = PermissionSandbox()
        let apps = Page2AppsSandbox()
        defer { apps.leave(); perm.leave() }
        Page2Apps.setFloor(false, for: "twitter", profileId: floorB)
        func handle(_ chatId: String?) -> [String: Any] {
            var frame: [String: Any] = ["type": "twitter_cmd", "id": "req-1", "input": ["action": "post", "text": "装了吗"]]
            if let chatId { frame["chat_id"] = chatId }
            return TwitterCCBridge.handle(frame, profiles: profiles, currentProfileId: floorA, context: context, mediaRoot: mediaRoot)
        }
        let b = handle("chat-b")
        XCTAssertEqual(b["ok"] as? Bool, false)
        XCTAssertTrue((b["result"] as? String ?? "").contains("B 楼 的\(PermissionCenter.notInstalledLabel("twitter"))"), b["result"] as? String ?? "")
        XCTAssertTrue(try context.fetch(TwitterQueries.localTimeline(profileId: floorB)).isEmpty)
        XCTAssertEqual(handle(nil)["ok"] as? Bool, true, "A 跟默认装着")
    }
}
