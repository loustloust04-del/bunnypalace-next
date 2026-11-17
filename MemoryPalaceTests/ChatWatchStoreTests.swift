import XCTest
@testable import 记忆花园

/// plan-chat-watch-together W1：小窗每个对话各记各的，最多 50 个
final class ChatWatchStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "chat-watch-\(UUID().uuidString)")
    }

    func testPerConversationRoundTripAndClear() {
        let a = ChatWatchState(open: true, url: "https://youtu.be/x", height: 260, position: 12, updatedAt: Date())
        ChatWatchStore.save(a, for: "A", defaults: defaults)
        XCTAssertEqual(ChatWatchStore.load("A", defaults: defaults), a)
        XCTAssertNil(ChatWatchStore.load("B", defaults: defaults))
        ChatWatchStore.save(nil, for: "A", defaults: defaults)
        XCTAssertNil(ChatWatchStore.load("A", defaults: defaults))
    }

    func testKeepsMostRecentFifty() {
        let base = Date()
        for i in 0..<55 {
            let s = ChatWatchState(open: true, url: nil, height: 220, position: nil, updatedAt: base.addingTimeInterval(Double(i)))
            ChatWatchStore.save(s, for: "c\(i)", defaults: defaults)
        }
        XCTAssertNil(ChatWatchStore.load("c0", defaults: defaults))
        XCTAssertNil(ChatWatchStore.load("c4", defaults: defaults))
        XCTAssertNotNil(ChatWatchStore.load("c5", defaults: defaults))
        XCTAssertNotNil(ChatWatchStore.load("c54", defaults: defaults))
    }
}
