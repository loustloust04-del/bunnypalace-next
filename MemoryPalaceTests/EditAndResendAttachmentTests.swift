import XCTest
import SwiftData
@testable import 记忆花园

/// editAndResend 带附件 / 引用 + 失败不动（plan-edit-attachments §4 D3）。
/// 模型指向连不上的本地端口：节点同步建好，流式很快失败收尾，不发真请求。
@MainActor
final class EditAndResendAttachmentTests: XCTestCase {

    struct Fixture {
        let context: ModelContext
        let viewModel: ConversationViewModel
        let providerManager: ProviderManager
        let model: ProviderModel
        let profile: Profile
        let preset: Preset
        let credentialId: String
    }

    private var budgetSnapshot: (enabled: Bool, isSet: Bool, budget: Double, spent: Double)?
    private var fixture: Fixture?

    override func tearDown() async throws {
        if let f = fixture {
            await waitForTurn(f.viewModel)
            if let convId = f.viewModel.selectedConversation?.id {
                AttachmentStore.deleteConversationAttachments(conversationId: convId, profileId: f.profile.id)
            }
            f.providerManager.removeCredential(id: f.credentialId)
        }
        if let b = budgetSnapshot {
            let store = GlobalBudgetStore.shared
            store.setEnabled(b.enabled)
            if b.isSet { store.setBudgetUSD(b.budget) } else { store.clearBudget() }
            store.resetSpent()
            store.commitSpend(b.spent)
        }
    }

    private func makeFixture() throws -> Fixture {
        let store = GlobalBudgetStore.shared
        budgetSnapshot = (store.enabled, store.isBudgetSet, store.budgetUSD, store.spentUSD)
        store.setEnabled(true)
        store.setBudgetUSD(100)
        store.resetSpent()

        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let credentialId = "xctest-edit-attach-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "gpt-4o", name: "Edit Attach Test")
        let providerManager = ProviderManager()
        providerManager.addCredential(APICredential(id: credentialId, name: "Edit Attach Test", emoji: "🧪",
                                                    type: .openaiCompatible, baseURL: "http://127.0.0.1:9", models: [model]))
        providerManager.setApiKey("test-key", for: credentialId)
        let profile = Profile(id: "xctest-edit-attach-profile", name: "Test", emoji: "🧪", description: "",
                              userName: "User", assistantName: "Assistant")
        let viewModel = ConversationViewModel()
        viewModel.startDraftConversation(profileId: profile.id)
        viewModel.selectedConversation?.memoryEnabled = false
        let f = Fixture(context: context, viewModel: viewModel, providerManager: providerManager, model: model,
                        profile: profile, preset: Preset.balanced, credentialId: credentialId)
        fixture = f
        return f
    }

    private func waitForTurn(_ vm: ConversationViewModel, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while vm.assistantTurnInFlight, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 先发一条垫底，再发带图的原消息，返回它
    private func sendOriginal(_ f: Fixture) async throws -> MessageNode {
        XCTAssertTrue(f.viewModel.sendMessage("第一条", model: f.model, profile: f.profile, preset: f.preset,
                                              providerManager: f.providerManager, context: f.context))
        await waitForTurn(f.viewModel)
        let img = try PendingChatAttachment.image(name: "a.jpg", typeDescription: "图片", mimeType: "image/jpeg",
                                                  data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]))
        XCTAssertTrue(f.viewModel.sendMessage("原话", model: f.model, profile: f.profile, preset: f.preset,
                                              providerManager: f.providerManager, context: f.context, attachments: [img]))
        await waitForTurn(f.viewModel)
        return try XCTUnwrap(f.viewModel.currentPath.last { $0.role == "user" && $0.content.hasPrefix("原话") })
    }

    private func edit(_ f: Fixture, _ node: MessageNode, text: String, attachments: [PendingChatAttachment] = [],
                      replyToId: String? = nil, replyQuote: String? = nil) -> Bool {
        f.viewModel.editAndResend(node.id, newText: text, attachments: attachments, replyToId: replyToId, replyQuote: replyQuote,
                                  model: f.model, profile: f.profile, preset: f.preset,
                                  providerManager: f.providerManager, context: f.context)
    }

    func testEditWithRestoredAttachmentsAndQuote() async throws {
        let f = try makeFixture()
        let original = try await sendOriginal(f)
        f.viewModel.beginEditing(original)
        let restored = try XCTUnwrap(f.viewModel.editingMessage?.restored)
        XCTAssertEqual(restored.text, "原话")
        XCTAssertEqual(restored.attachments.count, 1)
        XCTAssertNotNil(restored.attachments.first?.storedRef, "原图带着原 ref 回来")

        XCTAssertTrue(edit(f, original, text: "改了", attachments: restored.attachments, replyToId: "q1", replyQuote: "引文"))
        let newUser = try XCTUnwrap(f.viewModel.currentPath.last { $0.role == "user" })
        XCTAssertNotEqual(newUser.id, original.id)
        XCTAssertEqual(newUser.parentId, original.parentId, "新分支是原消息的兄弟")
        XCTAssertEqual(newUser.contentType, "segmented")
        XCTAssertTrue(newUser.content.hasPrefix("改了\n\n[图片附件："))
        XCTAssertEqual(newUser.replyToId, "q1")
        XCTAssertEqual(newUser.replyQuote, "引文")
        let origRef = original.segments?.compactMap { seg -> String? in
            if case .imageRef(_, _, let p) = seg { return p } else { return nil }
        }.first
        let newRef = newUser.segments?.compactMap { seg -> String? in
            if case .imageRef(_, _, let p) = seg { return p } else { return nil }
        }.first
        XCTAssertNotNil(origRef)
        XCTAssertEqual(newRef, origRef, "原图写回同一个文件，不另存一份")
    }

    func testBudgetBlockLeavesPathUntouched() async throws {
        let f = try makeFixture()
        let original = try await sendOriginal(f)
        let before = f.viewModel.currentPath.map(\.id)
        GlobalBudgetStore.shared.setBudgetUSD(0)
        XCTAssertFalse(edit(f, original, text: "改了"))
        XCTAssertEqual(f.viewModel.currentPath.map(\.id), before, "拦了就什么都不动，路径不截")
        XCTAssertNotNil(f.viewModel.budgetBlockedMessage)
    }

    func testBusyTurnRejects() async throws {
        let f = try makeFixture()
        let original = try await sendOriginal(f)
        f.viewModel.assistantTurnInFlight = true
        defer { f.viewModel.assistantTurnInFlight = false }
        XCTAssertFalse(edit(f, original, text: "改了"))
    }

    /// R1：老调用点（user 重新生成 / Page2）不传引用 → 不会把 vm 里草稿的引用塞进新节点
    func testLegacyCallerDoesNotConsumeDraftQuote() async throws {
        let f = try makeFixture()
        let original = try await sendOriginal(f)
        f.viewModel.quotingReplyTo = "draft-quote"
        f.viewModel.quotingPreview = "草稿引用"
        XCTAssertTrue(f.viewModel.editAndResend(original.id, newText: "重发", model: f.model, profile: f.profile, preset: f.preset,
                                                providerManager: f.providerManager, context: f.context))
        let newUser = try XCTUnwrap(f.viewModel.currentPath.last { $0.role == "user" })
        XCTAssertNil(newUser.replyToId)
        XCTAssertEqual(newUser.contentType, "text")
        XCTAssertEqual(f.viewModel.quotingReplyTo, "draft-quote", "草稿引用原样留着")
    }

    // MARK: - 第一条消息（老问题：以前第一条没有父节点，编辑必被拒）

    func testFirstMessageHangsUnderInvisibleRootAndIsEditable() async throws {
        let f = try makeFixture()
        XCTAssertTrue(f.viewModel.sendMessage("第一条", model: f.model, profile: f.profile, preset: f.preset,
                                              providerManager: f.providerManager, context: f.context))
        await waitForTurn(f.viewModel)
        let first = try XCTUnwrap(f.viewModel.currentPath.first { $0.role == "user" })
        XCTAssertNotNil(first.parentId, "第一条挂在隐形根下")
        XCTAssertNil(f.viewModel.branchInfoMap[first.id])

        XCTAssertTrue(edit(f, first, text: "第一条改过"))
        let newFirst = try XCTUnwrap(f.viewModel.currentPath.first { $0.role == "user" })
        XCTAssertNotEqual(newFirst.id, first.id)
        XCTAssertEqual(newFirst.parentId, first.parentId, "两个版本是隐形根下的兄弟")
        let info = try XCTUnwrap(f.viewModel.branchInfoMap[newFirst.id], "第一条自己身上要有切换器")
        XCTAssertEqual(info.branchNodeId, first.parentId)
        XCTAssertEqual(info.branchCount, 2)
        XCTAssertEqual(info.currentIndex, 1)
    }

    /// 老数据：第一条 parentId == nil → 编辑时挂到一个空的隐形根下再开分支
    func testLegacyRootlessFirstMessageGetsAdopted() async throws {
        let f = try makeFixture()
        XCTAssertTrue(f.viewModel.sendMessage("老第一条", model: f.model, profile: f.profile, preset: f.preset,
                                              providerManager: f.providerManager, context: f.context))
        await waitForTurn(f.viewModel)
        let first = try XCTUnwrap(f.viewModel.currentPath.first { $0.role == "user" })
        first.parentId = nil   // 模拟 09-26 之前的写法

        XCTAssertTrue(edit(f, first, text: "改过"))
        let rootId = try XCTUnwrap(first.parentId, "原第一条被挂到根下")
        let newFirst = try XCTUnwrap(f.viewModel.currentPath.first { $0.role == "user" })
        XCTAssertEqual(newFirst.parentId, rootId)
        XCTAssertEqual(f.viewModel.branchInfoMap[newFirst.id]?.branchCount, 2)
    }

    // MARK: - 分支挂位（plan-thinking-branch §1）：切换器挂在有多个版本的那条自己身上

    func testEditedMessageCarriesItsOwnBranchInfo() async throws {
        let f = try makeFixture()
        let original = try await sendOriginal(f)
        let parent = try XCTUnwrap(original.parentId)
        XCTAssertTrue(edit(f, original, text: "改了"))
        let newUser = try XCTUnwrap(f.viewModel.currentPath.last { $0.role == "user" })
        let info = try XCTUnwrap(f.viewModel.branchInfoMap[newUser.id])
        XCTAssertEqual(info.branchNodeId, parent)
        XCTAssertEqual(info.branchCount, 2)
        XCTAssertEqual(info.currentIndex, 1)
        XCTAssertNil(f.viewModel.branchInfoMap[parent], "分叉前面那条不再挂切换器")

        f.viewModel.switchBranch(at: info.branchNodeId, to: 0)
        let back = try XCTUnwrap(f.viewModel.currentPath.last { $0.role == "user" })
        XCTAssertEqual(back.id, original.id, "切回第一个版本")
        XCTAssertEqual(f.viewModel.branchInfoMap[original.id]?.currentIndex, 0)
    }

    func testRegeneratedReplyCarriesBranchInfo() async throws {
        let f = try makeFixture()
        _ = try await sendOriginal(f)
        let reply = try XCTUnwrap(f.viewModel.currentPath.last { $0.role == "assistant" })
        f.viewModel.regenerate(assistantNodeId: reply.id, model: f.model, profile: f.profile, preset: f.preset,
                               providerManager: f.providerManager, context: f.context)
        let newReply = try XCTUnwrap(f.viewModel.currentPath.last)
        XCTAssertNotEqual(newReply.id, reply.id)
        let info = try XCTUnwrap(f.viewModel.branchInfoMap[newReply.id])
        XCTAssertEqual(info.branchCount, 2)
        XCTAssertEqual(info.currentIndex, 1)
    }
}
