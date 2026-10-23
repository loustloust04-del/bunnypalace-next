import XCTest
@testable import 记忆花园

/// page1 表情回应（粟粟 10-01：长按菜单顶上换成表情，照群聊抄；只存本机）
@MainActor
final class ChatReactionStoreTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "ChatReactionStoreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testToggleAddsThenRemoves() {
        let store = ChatReactionStore(defaults: freshDefaults())
        store.toggle("❤️", on: "n1")
        XCTAssertEqual(store.reactions(for: "n1"), ["❤️"])
        store.toggle("❤️", on: "n1")
        XCTAssertEqual(store.reactions(for: "n1"), [], "同一个再点一次取消")
        XCTAssertNil(store.byNode["n1"], "空了就不留空数组")
    }

    func testKeepsTapOrderPerMessage() {
        let store = ChatReactionStore(defaults: freshDefaults())
        store.toggle("👍", on: "n1")
        store.toggle("🔥", on: "n1")
        store.toggle("😂", on: "n2")
        XCTAssertEqual(store.reactions(for: "n1"), ["👍", "🔥"])
        XCTAssertEqual(store.reactions(for: "n2"), ["😂"])
    }

    func testPersistsAcrossLaunches() {
        let defaults = freshDefaults()
        ChatReactionStore(defaults: defaults).toggle("🎉", on: "n9")
        XCTAssertEqual(ChatReactionStore(defaults: defaults).reactions(for: "n9"), ["🎉"])
    }

    // MARK: - 捎带给模型（§13，粟粟 10-01：要）

    private let target = ChatReactionTarget(nodeId: "n1", conversationId: "c1", snippet: "今天天气不错", isAssistant: true)

    func testReactionGoesToOutbox() {
        let box = ChatCardEventOutbox(defaults: freshDefaults())
        let store = ChatReactionStore(defaults: freshDefaults())
        store.toggle("❤️", on: target, outbox: box)
        XCTAssertEqual(store.reactions(for: "n1"), ["❤️"])
        XCTAssertEqual(box.events(for: "c1").map(\.text), ["对你那条「今天天气不错」回了 ❤️"])
    }

    func testUndoBeforeSendingLeavesNothing() {
        let box = ChatCardEventOutbox(defaults: freshDefaults())
        let store = ChatReactionStore(defaults: freshDefaults())
        store.toggle("❤️", on: target, outbox: box)
        store.toggle("❤️", on: target, outbox: box)
        XCTAssertEqual(box.events(for: "c1"), [], "还没发出去就撤掉，模型不会看到")
    }

    func testUndoAfterSendingTellsTheModel() {
        let box = ChatCardEventOutbox(defaults: freshDefaults())
        let store = ChatReactionStore(defaults: freshDefaults())
        store.toggle("❤️", on: target, outbox: box)
        _ = box.drain("c1")
        store.toggle("❤️", on: target, outbox: box)
        XCTAssertEqual(box.events(for: "c1").map(\.text), ["收回了对你那条「今天天气不错」的 ❤️"])
    }

    func testOwnMessageWording() {
        let box = ChatCardEventOutbox(defaults: freshDefaults())
        let mine = ChatReactionTarget(nodeId: "n2", conversationId: "c1", snippet: "我说的", isAssistant: false)
        ChatReactionStore(defaults: freshDefaults()).toggle("👍", on: mine, outbox: box)
        XCTAssertEqual(box.events(for: "c1").map(\.text), ["对自己那条「我说的」回了 👍"])
    }

    func testSnippetIsShortSingleLine() {
        XCTAssertEqual(ChatReactionTarget.snippet(from: "  第一行\n第二行  "), "第一行 第二行")
        XCTAssertEqual(ChatReactionTarget.snippet(from: String(repeating: "长", count: 30)), String(repeating: "长", count: 20) + "…")
    }

    func testEmojiBarMatchesGroupChat() {
        XCTAssertEqual(ChatReactionStore.emojis, ["👍", "❤️", "😂", "👀", "🎉", "🔥", "😢", "🤔", "✅", "🙏", "💯", "❌"])
    }
}
