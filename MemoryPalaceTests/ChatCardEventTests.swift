import XCTest
import SwiftData
@testable import 记忆花园

/// 待捎带箱（research-chat-cards §13）：网页卡的 report 和表情回应先存着，下次发消息挂到那条用户消息上带给模型
@MainActor
final class ChatCardEventTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "ChatCardEventTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - 箱子

    func testAddPersistsPerConversation() {
        let d = freshDefaults()
        let box = ChatCardEventOutbox(defaults: d)
        box.add("测验 7/10", conversationId: "c1")
        box.add("别的对话", conversationId: "c2")
        let reread = ChatCardEventOutbox(defaults: d)
        XCTAssertEqual(reread.events(for: "c1").map(\.text), ["测验 7/10"])
        XCTAssertEqual(reread.events(for: "c2").map(\.text), ["别的对话"])
    }

    func testSameKeyReplaces() {
        let box = ChatCardEventOutbox(defaults: freshDefaults())
        box.add("旧", conversationId: "c", key: "k")
        box.add("别的", conversationId: "c")
        box.add("新", conversationId: "c", key: "k")
        XCTAssertEqual(box.events(for: "c").map(\.text), ["别的", "新"])
    }

    func testCapDropsOldest() {
        let box = ChatCardEventOutbox(defaults: freshDefaults())
        for i in 0..<(ChatCardEventOutbox.maxPerConversation + 2) { box.add("e\(i)", conversationId: "c") }
        let texts = box.events(for: "c").map(\.text)
        XCTAssertEqual(texts.count, ChatCardEventOutbox.maxPerConversation)
        XCTAssertEqual(texts.first, "e2")
    }

    func testRemoveByKeyAndId() {
        let box = ChatCardEventOutbox(defaults: freshDefaults())
        box.add("a", conversationId: "c", key: "ka")
        box.add("b", conversationId: "c")
        XCTAssertTrue(box.remove(key: "ka", conversationId: "c"))
        XCTAssertFalse(box.remove(key: "ka", conversationId: "c"))
        let id = box.events(for: "c")[0].id
        box.remove(id: id, conversationId: "c")
        XCTAssertEqual(box.events(for: "c"), [])
    }

    func testDrainEmptiesThatConversationOnly() {
        let d = freshDefaults()
        let box = ChatCardEventOutbox(defaults: d)
        box.add("a", conversationId: "c1")
        box.add("b", conversationId: "c2")
        XCTAssertEqual(box.drain("c1").map(\.text), ["a"])
        XCTAssertEqual(box.events(for: "c1"), [])
        XCTAssertEqual(ChatCardEventOutbox(defaults: d).events(for: "c1"), [], "清空也落盘")
        XCTAssertEqual(box.events(for: "c2").map(\.text), ["b"])
    }

    // MARK: - 拼给模型

    func testPromptPrefix() {
        XCTAssertEqual(ChatCardEventPrompt.prefix([]), "")
        let events = [ChatCardEvent(text: "测验 7/10"), ChatCardEvent(text: "对「你好」回了 ❤️")]
        XCTAssertEqual(ChatCardEventPrompt.prefix(events), "[附带事件]\n- 测验 7/10\n- 对「你好」回了 ❤️\n\n")
    }

    func testNodeRoundTrip() {
        let node = MessageNode(id: "n", role: "user", content: "hi", contentType: "text", createTime: nil,
                               parentId: nil, childrenIds: [], conversationId: "c")
        XCTAssertEqual(node.cardEvents, [])
        XCTAssertNil(node.cardEventsData)
        let events = [ChatCardEvent(text: "x")]
        node.cardEvents = events
        XCTAssertEqual(node.cardEvents, events)
        node.cardEvents = []
        XCTAssertNil(node.cardEventsData, "空就不存")
    }

    /// 全量备份要带上捎带的事件（和卡库的 cardVariablesData / cardEditedAt 并存）
    func testBackupCoversAndRoundTripsCardEvents() {
        let node = MessageNode(id: "n", role: "user", content: "hi", contentType: "text", createTime: nil,
                               parentId: nil, childrenIds: [], conversationId: "c")
        node.cardEvents = [ChatCardEvent(text: "测验 7/10")]
        node.cardEditedAt = Date()
        let doc = FullNodeDocument(model: node)
        XCTAssertTrue(Set(SchemaCoverageCheck.modelFieldNames(node)).isSuperset(of: ["cardEventsData", "cardEditedAt", "cardVariablesData"]))
        XCTAssertTrue(Set(SchemaCoverageCheck.documentFieldNames(sample: doc)).isSuperset(of: ["cardEventsData", "cardEditedAt"]))
        XCTAssertEqual(doc.toNodeModel().cardEvents.map(\.text), ["测验 7/10"])
    }

    // MARK: - 发送

    func testSendAttachesEventsAndHistoryCarriesThem() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let credentialId = "xctest-card-events-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "gpt-4o", name: "Card Events Test")
        let providerManager = ProviderManager()
        providerManager.addCredential(APICredential(id: credentialId, name: "Card Events Test", emoji: "🧪",
                                                    type: .openaiCompatible, baseURL: "http://127.0.0.1:9", models: [model]))
        providerManager.setApiKey("test-key", for: credentialId)
        defer { providerManager.removeCredential(id: credentialId) }
        let budget = GlobalBudgetStore.shared
        let snapshot = (budget.enabled, budget.isBudgetSet, budget.budgetUSD, budget.spentUSD)
        budget.setEnabled(true)
        budget.setBudgetUSD(100)
        budget.resetSpent()
        defer {
            budget.setEnabled(snapshot.0)
            if snapshot.1 { budget.setBudgetUSD(snapshot.2) } else { budget.clearBudget() }
            budget.resetSpent(); budget.commitSpend(snapshot.3)
        }
        let profile = Profile(id: "xctest-card-events-profile", name: "Test", emoji: "🧪", description: "",
                              userName: "User", assistantName: "Assistant")
        let vm = ConversationViewModel()
        let box = ChatCardEventOutbox(defaults: freshDefaults())
        vm.cardEventOutbox = box
        vm.startDraftConversation(profileId: profile.id)
        vm.selectedConversation?.memoryEnabled = false
        let convId = try XCTUnwrap(vm.selectedConversation?.id)
        box.add("测验 7/10", conversationId: convId)

        XCTAssertTrue(vm.sendMessage("下一组", model: model, profile: profile, preset: Preset.balanced,
                                     providerManager: providerManager, context: context))
        let user = try XCTUnwrap(vm.currentPath.last { $0.role == "user" })
        XCTAssertEqual(user.cardEvents.map(\.text), ["测验 7/10"])
        XCTAssertEqual(box.events(for: convId), [], "发出去就清空")
        XCTAssertEqual(user.content, "下一组", "正文不动，事件另存")

        let history = vm.buildAPIMessages()
        let sent = try XCTUnwrap(history.first { $0.id == user.id })
        XCTAssertEqual(sent.content, "[附带事件]\n- 测验 7/10\n\n下一组")

        var deadline = Date().addingTimeInterval(15)   // 连不上的端口：等流式失败收尾
        while vm.assistantTurnInFlight, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }

        // 编辑重发：那一轮捎带的事件跟着新版本走；箱子里新攒的不被吃掉
        box.add("新攒的", conversationId: convId)
        XCTAssertTrue(vm.editAndResend(user.id, newText: "下一组（改）", attachments: [], replyToId: nil, replyQuote: nil,
                                       model: model, profile: profile, preset: Preset.balanced,
                                       providerManager: providerManager, context: context))
        let edited = try XCTUnwrap(vm.currentPath.last { $0.role == "user" })
        XCTAssertNotEqual(edited.id, user.id)
        XCTAssertEqual(edited.cardEvents.map(\.text), ["测验 7/10"])
        XCTAssertEqual(box.events(for: convId).map(\.text), ["新攒的"])
        deadline = Date().addingTimeInterval(15)
        while vm.assistantTurnInFlight, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }
}
