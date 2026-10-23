import XCTest
@testable import 记忆花园

/// 对象投影：待办卡接真待办（research-chat-cards §14）
@MainActor
final class TodoCardProjectionTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "TodoCardProjectionTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private struct Env {
        let todos: TodoManager
        let links: ChatTodoLinkStore
        let outbox: ChatCardEventOutbox
        var actions: TodoCardActions { TodoCardActions(todos: todos, links: links, outbox: outbox) }
    }

    private func env() -> Env {
        Env(todos: TodoManager(defaults: freshDefaults()), links: ChatTodoLinkStore(defaults: freshDefaults()),
            outbox: ChatCardEventOutbox(defaults: freshDefaults()))
    }

    private func card(_ items: [(String, Bool)], date: String? = nil, title: String = "周末") -> TodoCard {
        TodoCard(id: "t-1", title: title, items: items.map { .init(text: $0.0, done: $0.1) }, date: date)
    }

    // MARK: - Task 1：小改

    func testAddReturnsId() {
        let m = TodoManager(defaults: freshDefaults())
        let id = m.add("买花", date: "2026-10-01")
        XCTAssertEqual(m.items.first?.id, id)
        XCTAssertNil(m.add("   "), "空白不加")
    }

    func testDayKeyValidation() {
        XCTAssertTrue(TodoManager.isValidDayKey("2026-10-01"))
        XCTAssertFalse(TodoManager.isValidDayKey("2026-13-01"))
        XCTAssertFalse(TodoManager.isValidDayKey("明天"))
    }

    func testTodoCardDateIsOptionalAndLenient() {
        guard case .todo(let t)? = ChatCard.parse(language: "card-todo", code: #"{"id":"t-1","date":"2026-10-02","items":[{"text":"a"}]}"#)
        else { return XCTFail() }
        XCTAssertEqual(t.date, "2026-10-02")
        guard case .todo(let bad)? = ChatCard.parse(language: "card-todo", code: #"{"id":"t-1","date":"下周","items":[{"text":"a"}]}"#)
        else { return XCTFail("日期写坏了卡片照样能用") }
        XCTAssertNil(bad.date)
    }

    func testNoDateEncodesExactlyAsBefore() {
        let block = ChatCard.todo(TodoCard(id: "t-1", title: "T", items: [.init(text: "a", done: false)])).blockText
        XCTAssertEqual(block, "```card-todo\n{\"id\":\"t-1\",\"items\":[{\"done\":false,\"text\":\"a\"}],\"title\":\"T\"}\n```")
    }

    // MARK: - 关联存储

    func testLinksPersistPerConversationAndCard() {
        let d = freshDefaults()
        let store = ChatTodoLinkStore(defaults: d)
        let id = UUID()
        store.link(" 买牛奶 ", to: id, conversationId: "c1", cardId: "t-1")
        XCTAssertEqual(ChatTodoLinkStore(defaults: d).links(conversationId: "c1", cardId: "t-1")[ChatTodoLinkStore.key("买牛奶")], id)
        XCTAssertEqual(store.links(conversationId: "c2", cardId: "t-1"), [:], "别的对话不串")
        XCTAssertEqual(store.links(conversationId: "c1", cardId: "t-2"), [:])
    }

    // MARK: - 投影状态

    func testProjectionStates() {
        let e = env()
        let id = e.todos.add("买牛奶")!
        let links = [ChatTodoLinkStore.key("买牛奶"): id, ChatTodoLinkStore.key("洗衣服"): UUID()]
        XCTAssertEqual(TodoCardProjection.state(of: .init(text: "买牛奶", done: false), links: links, todos: e.todos.items),
                       .linked(e.todos.items[0]))
        XCTAssertEqual(TodoCardProjection.state(of: .init(text: "洗衣服", done: false), links: links, todos: e.todos.items),
                       .removed, "关联的待办被删了")
        XCTAssertEqual(TodoCardProjection.state(of: .init(text: "新的", done: false), links: links, todos: e.todos.items), .unlinked)
    }

    // MARK: - 整张加入

    func testAddAllWritesTodosWithDateAndDoneAndTellsModel() {
        let e = env()
        let n = e.actions.addAll(card([("买牛奶", false), ("洗衣服", true)], date: "2026-10-03"), conversationId: "c1", today: "2026-10-01")
        XCTAssertEqual(n, 2)
        XCTAssertEqual(e.todos.items.map(\.text), ["买牛奶", "洗衣服"])
        XCTAssertEqual(e.todos.items.map(\.date), ["2026-10-03", "2026-10-03"])
        XCTAssertEqual(e.todos.items.map(\.done), [false, true], "模型写成 done 的项照样勾上")
        XCTAssertEqual(e.links.links(conversationId: "c1", cardId: "t-1").count, 2)
        XCTAssertEqual(e.outbox.events(for: "c1").map(\.text), ["把待办卡「周末」加进了我的待办（2 项）"])
    }

    func testAddAllDefaultsToTodayAndSkipsAlreadyLinked() {
        let e = env()
        _ = e.actions.addAll(card([("买牛奶", false)]), conversationId: "c1", today: "2026-10-01")
        let n = e.actions.addAll(card([("买牛奶", false), ("洗衣服", false)]), conversationId: "c1", today: "2026-10-01")
        XCTAssertEqual(n, 1, "已经加过的不重复加")
        XCTAssertEqual(e.todos.items.map(\.text), ["买牛奶", "洗衣服"])
        XCTAssertEqual(e.todos.items.map(\.date), ["2026-10-01", "2026-10-01"])
    }

    func testCardWithoutIdCannotLink() {
        let e = env()
        var c = card([("a", false)])
        c.id = nil
        XCTAssertEqual(e.actions.addAll(c, conversationId: "c1", today: "2026-10-01"), 0)
        XCTAssertTrue(e.todos.items.isEmpty)
    }

    func testAddOneLinksSingleItem() {
        let e = env()
        _ = e.actions.addAll(card([("买牛奶", false)]), conversationId: "c1", today: "2026-10-01")
        e.actions.addOne(.init(text: "洗衣服", done: false), card: card([("买牛奶", false), ("洗衣服", false)]),
                         conversationId: "c1", today: "2026-10-01")
        XCTAssertEqual(e.todos.items.map(\.text), ["买牛奶", "洗衣服"])
        XCTAssertEqual(e.outbox.events(for: "c1").last?.text, "把「洗衣服」加进了我的待办")
    }

    // MARK: - 勾选

    func testToggleChangesRealTodoAndBackAndForthCancels() {
        let e = env()
        _ = e.actions.addAll(card([("买牛奶", false)]), conversationId: "c1", today: "2026-10-01")
        _ = e.outbox.drain("c1")
        let id = e.todos.items[0].id
        e.actions.toggle(id, text: "买牛奶", conversationId: "c1")
        XCTAssertTrue(e.todos.items[0].done)
        XCTAssertEqual(e.outbox.events(for: "c1").map(\.text), ["勾掉了待办「买牛奶」"])
        e.actions.toggle(id, text: "买牛奶", conversationId: "c1")
        XCTAssertFalse(e.todos.items[0].done)
        XCTAssertEqual(e.outbox.events(for: "c1"), [], "还没发出去就点回来：抵掉")
    }

    func testToggleAfterSendingReportsUndo() {
        let e = env()
        _ = e.actions.addAll(card([("买牛奶", true)]), conversationId: "c1", today: "2026-10-01")
        _ = e.outbox.drain("c1")
        e.actions.toggle(e.todos.items[0].id, text: "买牛奶", conversationId: "c1")
        XCTAssertEqual(e.outbox.events(for: "c1").map(\.text), ["把待办「买牛奶」改回没做"])
    }

    func testToggleOnDeletedTodoDoesNothing() {
        let e = env()
        e.actions.toggle(UUID(), text: "没了", conversationId: "c1")
        XCTAssertEqual(e.outbox.events(for: "c1"), [])
    }

    // MARK: - 加一项

    func testAddNewItemWhenLinked() {
        let e = env()
        _ = e.actions.addAll(card([("买牛奶", false)]), conversationId: "c1", today: "2026-10-01")
        _ = e.outbox.drain("c1")
        e.actions.addNewItem("倒垃圾", card: card([("买牛奶", false)]), conversationId: "c1", today: "2026-10-01")
        XCTAssertEqual(e.todos.items.map(\.text), ["买牛奶", "倒垃圾"])
        XCTAssertNotNil(e.links.links(conversationId: "c1", cardId: "t-1")[ChatTodoLinkStore.key("倒垃圾")])
        XCTAssertEqual(e.outbox.events(for: "c1"), [], "新版本卡会进输入框，不用再捎带")
    }
}
