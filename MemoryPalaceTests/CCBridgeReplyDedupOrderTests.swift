import XCTest
@testable import 记忆花园

/// reply 帧的「已收」标记必须落在投递之后：进程死在投递前（09-17 冷启动看门狗），
/// 下次 replay 还能补上；没接线的帧不算收过。
final class CCBridgeReplyDedupOrderTests: XCTestCase {
    private let key = "ccSeenReplyIds"
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "CCBridgeReplyDedupOrderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func frame(_ replyId: String, requestId: String? = nil, streaming: Bool = false) -> String {
        var obj: [String: Any] = ["type": "reply", "chat_id": "C1", "content": "hi", "reply_id": replyId, "mp_msg_id": "s_" + replyId]
        if let requestId { obj["message_id"] = requestId }
        if streaming { obj["streaming"] = true }
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func seen(_ replyId: String) -> Bool {
        (defaults.dictionary(forKey: key) as? [String: Double])?[replyId] != nil
    }

    private func waitUntil(timeout: TimeInterval = 2, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return cond()
    }

    func testFrameWithoutHandlerIsNotMarkedSeen() {
        let client = CCBridgeWebSocketClient(dedupDefaults: defaults)
        client.onProactiveMessage = nil
        let id = "t-nohandler-\(UUID().uuidString.prefix(8))"
        client.handleIncoming(frame(id))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(seen(id), "没接线 = 没落地，不能标已收")
    }

    func testDeliveredThenMarkedSeen() {
        let client = CCBridgeWebSocketClient(dedupDefaults: defaults)
        let id = "t-deliver-\(UUID().uuidString.prefix(8))"
        let delivered = expectation(description: "delivered")
        client.onProactiveMessage = { chatId, _, _, _, _, _, ccId, _, callReply in
            XCTAssertEqual(chatId, "C1")
            XCTAssertEqual(ccId, "s_\(id)")
            XCTAssertEqual(callReply?.requestId, "user-1")
            XCTAssertEqual(callReply?.streaming, true)
            delivered.fulfill()
        }
        client.handleIncoming(frame(id, requestId: "user-1", streaming: true))
        wait(for: [delivered], timeout: 2)
        XCTAssertTrue(waitUntil { self.seen(id) }, "投递后应标已收")
    }

    func testReplayOfDeliveredReplyIsDropped() {
        let client = CCBridgeWebSocketClient(dedupDefaults: defaults)
        let id = "t-replay-\(UUID().uuidString.prefix(8))"
        var count = 0
        client.onProactiveMessage = { _, _, _, _, _, _, _, _, _ in count += 1 }
        client.handleIncoming(frame(id))
        XCTAssertTrue(waitUntil { self.seen(id) })
        client.handleIncoming(frame(id))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(count, 1, "已收过的 replay 静默丢")
    }
}
