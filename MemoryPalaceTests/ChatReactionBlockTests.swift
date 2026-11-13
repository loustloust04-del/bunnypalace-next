import XCTest
@testable import 记忆花园

/// T4：回应锚到单泡。存储 key 按泡分，旧整条 key 向后兼容可读。
@MainActor
final class ChatReactionBlockTests: XCTestCase {
    private let outbox = ChatCardEventOutbox(defaults: UserDefaults(suiteName: "test-reaction-outbox-\(UUID().uuidString)")!)


    private func store() -> ChatReactionStore {
        ChatReactionStore(defaults: UserDefaults(suiteName: "test-reactions-\(UUID().uuidString)")!, key: "chatReactions")
    }

    private func target(nodeId: String = "n1", block: Int? = nil) -> ChatReactionTarget {
        ChatReactionTarget(nodeId: nodeId, conversationId: "c1", snippet: "hi", isAssistant: false, blockIndex: block)
    }

    func testBlockKeyFormat() {
        XCTAssertEqual(ChatReactionStore.key(for: target(block: 0)), "n1#0")
        XCTAssertEqual(ChatReactionStore.key(for: target(block: 2)), "n1#2")
        XCTAssertEqual(ChatReactionStore.key(for: target(block: nil)), "n1", "整条消息保持旧 key")
    }

    func testToggleWritesBlockKey() {
        let s = store()
        s.toggle("👍", on: target(block: 1), outbox: outbox)
        XCTAssertEqual(s.reactions(for: target(block: 1)), ["👍"])
        XCTAssertEqual(s.reactions(for: target(block: 0)), [], "别的泡不受影响")
        XCTAssertEqual(s.reactions(for: target(block: nil)), [], "整条 key 不被块写入污染")
    }

    func testLegacyNodeDataReadableOnFirstBlockOnly() {
        let s = store()
        // 旧数据：直接写整条 key（模拟 T4 前版本）
        XCTAssertTrue(s.toggle("❤️", on: "n1"))
        XCTAssertEqual(s.reactions(for: target(block: 0)), ["❤️"], "旧数据在第 0 个泡可读")
        XCTAssertEqual(s.reactions(for: target(block: 1)), [], "第 1 个泡不冒旧徽标")
        XCTAssertEqual(s.reactions(for: target(block: nil)), ["❤️"])
    }

    func testBlockToggleDoesNotClobberLegacy() {
        let s = store()
        XCTAssertTrue(s.toggle("❤️", on: "n1"))
        s.toggle("👍", on: target(block: 0), outbox: outbox)
        XCTAssertEqual(s.reactions(for: target(block: 0)), ["👍"], "块 key 优先")
        XCTAssertEqual(s.byNode["n1"], ["❤️"], "旧数据原地保留")
    }

    func testToggleOffRemovesBlockReaction() {
        let s = store()
        s.toggle("👍", on: target(block: 0), outbox: outbox)
        XCTAssertEqual(s.reactions(for: target(block: 0)), ["👍"])
        s.toggle("👍", on: target(block: 0), outbox: outbox)
        XCTAssertEqual(s.reactions(for: target(block: 0)), [])
    }
}
