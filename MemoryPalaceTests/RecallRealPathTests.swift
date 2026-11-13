import MemoryCore
import XCTest
import SwiftData
import Network
@testable import 记忆花园

/// Loopback HTTP drives the production VM/router/provider pipeline; no live model or device.
@MainActor
final class RecallRealPathTests: XCTestCase {
    private typealias Server = ScriptedHTTPServer
    private var harness: PromptRealPathHarness?
    private var cleanups: [() -> Void] = []
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = try XCTUnwrap(TestHostIsolation.home).appendingPathComponent("recall-real-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        RequestBodyTap.handler = nil
        if let harness {
            harness.viewModel.cancelAssistantTurn(context: harness.context, drainQueued: false)
        }
        cleanups.forEach { $0() }
        cleanups = []
        await harness?.tearDown()
        harness = nil
        if let sandbox { try FileManager.default.removeItem(at: sandbox) }
    }

    private func make(baseURL: String, tools: Bool = false, cacheFriendly: Bool = false) async throws -> PromptRealPathHarness {
        let h = try await PromptRealPathHarness.make(PromptScenario(
            name: "recall-real-path", profileId: "xctest-recall-real-path-\(UUID().uuidString)",
            cacheFriendly: cacheFriendly, cardToolsSupported: tools, voiceHint: false, memoryFixtures: false
        ))
        harness = h
        RecallTuningStore.save(RecallTestTuning.make(), profileId: h.profile.id)
        cleanups.append { RecallTuningStore.reset(profileId: h.profile.id) }
        h.overrideDefault("imageTranscriptionEnabled", false)
        var credential = try XCTUnwrap(h.providerManager.credentials.first { $0.id == h.model.credentialId })
        credential.baseURL = baseURL
        h.providerManager.updateCredential(credential)
        h.viewModel.providerRouter.retryDelay = { _ in 0 }
        h.viewModel.providerRouter.ledger = UsageLedger(fileURL: sandbox.appendingPathComponent("usage.jsonl"))
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.recallStateData = nil
        for node in try h.context.fetch(FetchDescriptor<MessageNode>()) {
            node.recallReceiptData = nil
            if node.role == "user" { node.content = "星砚在云桥城整理林栖的地图" }
            if node.role == "assistant" { node.content = "岚舟整理了云桥城的地图" }
        }
        for memory in try h.context.fetch(FetchDescriptor<Memory>()) {
            memory.content = "林栖与星砚在云桥城整理地图"
        }
        try h.context.save()
        return h
    }

    private func scripted(_ respond: @escaping (Int, Data) -> Server.Response) throws -> Server {
        let server = try Server(responding: respond)
        try server.start()
        cleanups.append { server.stop() }
        return server
    }

    private func held() throws -> HeldStreamServer {
        let server = try HeldStreamServer()
        try server.start()
        cleanups.append { server.stop() }
        return server
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 8,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
        guard condition() else { throw URLError(.timedOut) }
    }

    @discardableResult
    private func send(_ h: PromptRealPathHarness) throws -> MessageNode {
        XCTAssertTrue(h.viewModel.sendMessage("林栖在云桥城的地图计划怎样了？", model: h.model,
                                             profile: h.profile, preset: h.preset,
                                             providerManager: h.providerManager, context: h.context))
        return try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
    }

    private static let textChunk = OutputTokenCapTests.sse([
        #"data: {"choices":[{"delta":{"content":"岚舟整理了林栖的地图"}}]}"#
    ])

    private static let toolStartChunk = OutputTokenCapTests.sse([
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"fictional-dice","type":"function","function":{"name":"roll_dice","arguments":""}}]}}]}"#
    ])

    private static let toolTurn = OutputTokenCapTests.sse([
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"fictional-dice","type":"function","function":{"name":"roll_dice","arguments":"{\"options\":[\"岚舟\",\"星砚\"]}"}}]}}]}"#,
        #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        "data: [DONE]"
    ])

    func testPreviewDoesNotPersistReceiptStateOrExtraNodes() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let before = try h.context.fetch(FetchDescriptor<MessageNode>()).map { ($0.id, $0.content, $0.recallReceiptData) }
        let state = conversation.recallStateData
        for _ in 0..<2 {
            XCTAssertNotNil(h.viewModel.previewTurn(profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, globalModelId: h.model.id,
                                                   context: h.context, excludingNodeId: h.a2.id))
        }
        XCTAssertEqual(conversation.recallStateData, state)
        let after = Dictionary(uniqueKeysWithValues: try h.context.fetch(FetchDescriptor<MessageNode>()).map { ($0.id, $0) })
        XCTAssertEqual(after.count, before.count)
        for (id, content, receipt) in before {
            XCTAssertEqual(after[id]?.content, content)
            XCTAssertEqual(after[id]?.recallReceiptData, receipt)
        }
        XCTAssertEqual(server.requestBodies.count, 0)
    }

    func testTriggerWithoutRootWarmsBeforeSendingAndDisablingTriggerKeepsRoot() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        try await h.seedWiki([WikiPage(path: "人/林栖", hook: "云桥城的朋友", title: "林栖", now: "合成地图计划")])
        MemoryOpenWindowStore.save(.c, false, profileId: h.profile.id)
        let cache = WikiInjectionCache()
        h.viewModel.wikiInjectionCache = cache
        XCTAssertFalse(cache.isFresh(h.profile.id))
        var sent: [[String: Any]] = []
        RequestBodyTap.handler = { sent.append($0) }
        let first = try send(h)
        await h.waitForTurn()
        XCTAssertTrue(cache.isFresh(h.profile.id))
        XCTAssertEqual(first.recallReceipt?.decision.selected.map(\.source.path), ["人/林栖"])
        let firstBody = String(decoding: try JSONSerialization.data(withJSONObject: XCTUnwrap(sent.last)), as: UTF8.self)
        XCTAssertFalse(firstBody.contains(WikiInjection.indexTitle))
        MemoryOpenWindowStore.save(.c, true, profileId: h.profile.id)
        RecallTuningStore.save(RecallTestTuning.make(archiveTriggerEnabled: false), profileId: h.profile.id)
        let second = try send(h)
        await h.waitForTurn()
        XCTAssertEqual(second.recallReceipt?.decision.gateReason, .disabled)
        XCTAssertTrue(second.recallReceipt?.decision.selected.isEmpty == true)
        let secondBody = String(decoding: try JSONSerialization.data(withJSONObject: XCTUnwrap(sent.last)), as: UTF8.self)
        XCTAssertTrue(secondBody.contains(WikiInjection.indexTitle))
    }

    func testSubmittedReceiptAdvancesOnlyWhenFirstContentArrives() async throws {
        let server = try held()
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        XCTAssertNil(conversation.lastRealChatAt)
        var prepared: RecallTurnReceipt?
        RequestBodyTap.handler = { _ in
            prepared = h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt
        }
        let user = try send(h)
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        try await waitUntil("Request must persist its submitted attempt before receiving content") {
            server.hasRequest && assistant.recallReceipt?.attempts.last?.status == .submitted
        }
        RequestBodyTap.handler = nil
        XCTAssertEqual(prepared?.attempts.last?.status, .prepared, "Building the request records preparation, not submission")
        XCTAssertEqual(prepared?.hasEffectiveResponse, false)
        let submitted = try XCTUnwrap(assistant.recallReceipt)
        XCTAssertEqual(submitted.decision.turnId, user.id)
        XCTAssertEqual(submitted.attempts.count, 1)
        XCTAssertFalse(submitted.hasEffectiveResponse)
        let userReceipt = try XCTUnwrap(user.recallReceipt)
        XCTAssertEqual(userReceipt, RecallTurnReceipt(decision: userReceipt.decision),
                       "user 回执整份只剩 decision，不镜像 attempts / reads / delivery")
        XCTAssertEqual(conversation.recallState.effectiveTurn, 0)
        XCTAssertNil(conversation.lastRealChatAt, "提交请求还不算真实回复")
        let submittedTime = Date().addingTimeInterval(60)
        conversation.updateTime = submittedTime
        server.release(Self.textChunk)
        try await waitUntil("The first real content event must commit the turn") { assistant.recallReceipt?.hasEffectiveResponse == true }
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1)
        XCTAssertEqual(conversation.recallState.lastAppliedTurnId, user.id)
        XCTAssertEqual(assistant.recallReceipt?.attempts.last?.status, .responded)
        XCTAssertNotNil(conversation.lastRealChatAt, "第一条有效提供商响应打戳")
        XCTAssertGreaterThan(conversation.updateTime, submittedTime, "Receipt/state changes must advance the owning conversation's sync clock")
        server.finish()
        await h.waitForTurn()
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1)
        XCTAssertEqual(user.content, "林栖在云桥城的地图计划怎样了？")
    }

    func testCancellationBeforeFirstEventDoesNotAdvanceEffectiveTurn() async throws {
        let server = try held()
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        _ = try send(h)
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        try await waitUntil("Wait for a submitted request without provider content") {
            server.hasRequest && assistant.recallReceipt?.attempts.last?.status == .submitted
        }
        h.viewModel.cancelAssistantTurn(context: h.context, drainQueued: false)
        XCTAssertEqual(conversation.recallState.effectiveTurn, 0)
        XCTAssertNil(conversation.recallState.lastAppliedTurnId)
        XCTAssertEqual(assistant.recallReceipt?.attempts.last?.status, .cancelled)
        XCTAssertEqual(assistant.recallReceipt?.hasEffectiveResponse, false)
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
    }

    func testCancellationAfterFirstContentKeepsCommittedTurnAndMarksInterrupted() async throws {
        let server = try held()
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let user = try send(h)
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        try await waitUntil("Wait for the pending HTTP stream") { server.hasRequest }
        server.release(Self.textChunk)
        try await waitUntil("Receive content before cancelling") { assistant.recallReceipt?.hasEffectiveResponse == true }
        h.viewModel.cancelAssistantTurn(context: h.context, drainQueued: false)
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1)
        XCTAssertEqual(conversation.recallState.lastAppliedTurnId, user.id)
        XCTAssertEqual(assistant.recallReceipt?.attempts.last?.status, .interrupted)
        XCTAssertEqual(assistant.recallReceipt?.hasEffectiveResponse, true)
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
    }

    func testToolStartBeforeArgumentsIsEffectiveEvenWhenCancelledWhileWaiting() async throws {
        let server = try held()
        let h = try await make(baseURL: server.baseURL, tools: true)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        _ = try send(h)
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        try await waitUntil("Wait for submitted tool-capable request") { server.hasRequest }
        server.release(Self.toolStartChunk)
        try await waitUntil("A real tool-call start is effective before its arguments finish") {
            assistant.recallReceipt?.hasEffectiveResponse == true
        }
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1)
        XCTAssertTrue(h.viewModel.assistantTurnInFlight, "The server has not completed tool arguments")
        h.viewModel.cancelAssistantTurn(context: h.context, drainQueued: false)
        XCTAssertEqual(assistant.recallReceipt?.attempts.last?.status, .interrupted)
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1)
    }

    func testRegenerateReusesTurnDecisionWithoutIncrementingAgain() async throws {
        let server = try scripted { _, _ in
            .init(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.okText)
        }
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let user = try send(h)
        await h.waitForTurn()
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
        let originalAssistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        let original = try XCTUnwrap(originalAssistant.recallReceipt)
        XCTAssertTrue(original.hasEffectiveResponse)
        h.viewModel.regenerate(assistantNodeId: originalAssistant.id, model: h.model, profile: h.profile,
                               preset: h.preset, providerManager: h.providerManager, context: h.context)
        await h.waitForTurn()
        let regeneratedAssistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertNotEqual(regeneratedAssistant.id, originalAssistant.id)
        let regenerated = try XCTUnwrap(regeneratedAssistant.recallReceipt)
        XCTAssertEqual(regenerated.decision.turnId, original.decision.turnId)
        XCTAssertEqual(regenerated.decision.topicAnchor, original.decision.topicAnchor)
        XCTAssertEqual(regenerated.decision.tuning, original.decision.tuning)
        XCTAssertEqual(regenerated.decision.selected, original.decision.selected)
        XCTAssertEqual(regenerated.decision.turnId, user.id)
        let originalAttemptId = try XCTUnwrap(original.attempts.first?.id)
        XCTAssertEqual(originalAssistant.recallReceipt?.attempts.count, 1, "旧版本只记自己的 attempt（重读节点，不是重生成前的拷贝）")
        XCTAssertEqual(originalAssistant.recallReceipt?.attempts.first?.id, originalAttemptId)
        XCTAssertEqual(regenerated.attempts.count, 1, "新版本从空账开始，只记自己的 attempt")
        XCTAssertNotEqual(regenerated.attempts.first?.id, originalAttemptId, "重生成是新 attempt")
        XCTAssertTrue(regenerated.attempts.allSatisfy(\.receivedResponse))
        XCTAssertEqual(regenerated.inheritedEffective, true, "上一版已生效：新回复靠这一格算同一轮")
        let userReceipt = try XCTUnwrap(user.recallReceipt)
        XCTAssertEqual(userReceipt, RecallTurnReceipt(decision: userReceipt.decision),
                       "user 回执整份只剩 decision，不镜像 attempts / reads / delivery")
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1)
        XCTAssertEqual(server.requestBodies.count, 2)
    }

    func testToolContinuationUsesSameTurnWithSeparateAttempts() async throws {
        let server = try scripted { index, _ in
            .init(status: 200, contentType: "text/event-stream", body: index == 0 ? Self.toolTurn : OutputTokenCapTests.okText)
        }
        let h = try await make(baseURL: server.baseURL, tools: true)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        var requestStamps: [Date?] = []
        RequestBodyTap.handler = { _ in requestStamps.append(conversation.lastRealChatAt) }
        let user = try send(h)
        await h.waitForTurn()
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        let receipt = try XCTUnwrap(assistant.recallReceipt)
        XCTAssertEqual(server.requestBodies.count, 2, "The completed tool must return through the actual continuation request")
        XCTAssertEqual(receipt.decision.turnId, user.id)
        XCTAssertEqual(receipt.attempts.count, 2)
        XCTAssertEqual(Set(receipt.attempts.map(\.id)).count, 2)
        XCTAssertTrue(receipt.attempts.allSatisfy(\.receivedResponse))
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1)
        XCTAssertEqual(requestStamps.count, 2)
        XCTAssertNil(requestStamps.first.flatMap { $0 })
        let firstResponseStamp = try XCTUnwrap(requestStamps.last.flatMap { $0 })
        XCTAssertEqual(conversation.lastRealChatAt, firstResponseStamp, "工具续轮不能再次打戳")
        if server.requestBodies.count > 1 {
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: server.requestBodies[1]) as? [String: Any])
            let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
            XCTAssertTrue(messages.contains { $0["role"] as? String == "tool" }, "Continuation must include the real tool result")
        }
    }

    func testImportedConversationResponseDoesNotStampLiveChatTime() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.importBatchId = UUID()
        _ = try send(h)
        await h.waitForTurn()
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertTrue(assistant.recallReceipt?.hasEffectiveResponse == true)
        XCTAssertNil(conversation.lastRealChatAt, "非 live 窗即使真收到响应也不写最后聊戳")
    }

    func testLateResponseAfterSwitchingWindowsStampsOriginalWindow() async throws {
        let server = try held()
        let h = try await make(baseURL: server.baseURL)
        let original = try XCTUnwrap(h.viewModel.selectedConversation)
        let user = try send(h)
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        try await waitUntil("等待原窗请求提交") { server.hasRequest && assistant.recallReceipt?.attempts.last?.status == .submitted }
        let other = Conversation(id: "other-window", title: "星砚的另一窗", createTime: Date(), updateTime: Date(),
                                 currentNodeId: "", provider: "api", profileId: h.profile.id)
        h.context.insert(other)
        try h.context.save()
        h.viewModel.loadConversation(other, context: h.context)
        try await waitUntil("等待切窗清掉原节点表") { !h.viewModel.isLoading }
        XCTAssertFalse(h.viewModel.currentPath.contains { $0.id == user.id })
        server.release(Self.textChunk)
        server.finish()
        await h.waitForTurn()
        XCTAssertTrue(assistant.recallReceipt?.hasEffectiveResponse == true)
        XCTAssertNotNil(original.lastRealChatAt)
        XCTAssertNil(other.lastRealChatAt)
        XCTAssertEqual(h.viewModel.selectedConversation?.id, other.id)
    }

    func testAutomaticDraftFreezesAtCommitBeforeFirstRequest() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let source = try XCTUnwrap(h.viewModel.selectedConversation)
        source.lastRealChatAt = Date(timeIntervalSince1970: 100)
        try h.context.save()
        h.viewModel.startNewConversation(profileId: h.profile.id, fresh: true, cards: nil)
        let draft = try XCTUnwrap(h.viewModel.selectedConversation)
        XCTAssertNil(draft.memoryWindowChoicesData)
        XCTAssertNil(draft.previousWindowSnapshot)
        XCTAssertNil(h.viewModel.openWindowNote)
        MemoryWindowChoices.setDefault(.pending, false, profileId: h.profile.id)
        var requestSnapshot: PreviousWindowSnapshot?
        var requestChoices: MemoryWindowChoices?
        RequestBodyTap.handler = { _ in
            requestSnapshot = draft.previousWindowSnapshot
            requestChoices = draft.memoryWindowChoices
        }
        let user = try send(h)
        await h.waitForTurn()
        XCTAssertFalse(h.viewModel.isDraftConversation)
        XCTAssertEqual(requestChoices?.pending, false, "自动草稿按转正时而不是创建时默认冻结")
        XCTAssertEqual(requestSnapshot?.sourceId, source.id)
        XCTAssertEqual(requestSnapshot?.messages.last?.nodeId, source.currentNodeId)
        XCTAssertTrue(h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt?.hasEffectiveResponse == true)
        let saved = try XCTUnwrap(ModelContext(h.context.container).fetch(FetchDescriptor<Conversation>()).first { $0.id == draft.id })
        XCTAssertEqual(saved.memoryWindowChoices, requestChoices)
        XCTAssertEqual(saved.previousWindowSnapshot, requestSnapshot)
    }

    /// E2-7b：后台冻结没落定就发首句 → 组装必须等快照，实发 system 里有上个窗口
    func testAutomaticDraftFirstMessageWaitsForBackgroundFreeze() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let source = try XCTUnwrap(h.viewModel.selectedConversation)
        source.lastRealChatAt = Date(timeIntervalSince1970: 100)
        try h.context.save()
        PreviousWindowPicker.debugCaptureDelay = .milliseconds(200)
        defer { PreviousWindowPicker.debugCaptureDelay = nil }
        h.viewModel.startNewConversation(profileId: h.profile.id, fresh: true, cards: nil)
        let draft = try XCTUnwrap(h.viewModel.selectedConversation)
        var captured: [String: Any]?
        RequestBodyTap.handler = { captured = $0 }
        _ = try send(h)
        XCTAssertTrue(h.viewModel.isFreezing(draft.id), "首句发出去时后台冻结必须还没落定（夹具靠 200 ms 延迟）")
        try await waitUntil("provider 未构造真实发送 body") { captured != nil }
        XCTAssertTrue(systemText(try XCTUnwrap(captured)).contains("[上一个窗口]"), "组装必须先等快照落定")
        await h.waitForTurn()
        XCTAssertFalse(h.viewModel.isFreezing(draft.id))
    }

    /// E2-7b：显式 ⌘N 当场开冻结，纸条还没落定就发首句 → 同样要等
    func testExplicitNewWindowFirstMessageWaitsForBackgroundFreeze() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let source = try XCTUnwrap(h.viewModel.selectedConversation)
        source.lastRealChatAt = Date(timeIntervalSince1970: 100)
        try h.context.save()
        PreviousWindowPicker.debugCaptureDelay = .milliseconds(200)
        defer { PreviousWindowPicker.debugCaptureDelay = nil }
        h.viewModel.startNewConversation(profileId: h.profile.id, fresh: true, cards: nil, explicit: true, context: h.context)
        let draft = try XCTUnwrap(h.viewModel.selectedConversation)
        XCTAssertTrue(h.viewModel.isFreezing(draft.id), "⌘N 当场开冻结")
        var captured: [String: Any]?
        RequestBodyTap.handler = { captured = $0 }
        _ = try send(h)
        XCTAssertTrue(h.viewModel.isFreezing(draft.id), "首句发出去时后台冻结必须还没落定")
        try await waitUntil("provider 未构造真实发送 body") { captured != nil }
        XCTAssertTrue(systemText(try XCTUnwrap(captured)).contains("[上一个窗口]"), "组装必须先等快照落定")
        await h.waitForTurn()
        XCTAssertFalse(h.viewModel.isFreezing(draft.id))
    }

    /// 实发 body 里的 system 文本（顶层 system + messages 里 role=system 的合并）
    private func systemText(_ body: [String: Any]) -> String {
        func text(_ message: [String: Any]) -> String {
            if let content = message["content"] as? String { return content }
            return (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        let messages = body["messages"] as? [[String: Any]] ?? []
        let top = (body["system"] as? String)
            ?? (body["system"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return ([top] + messages.filter { $0["role"] as? String == "system" }.map(text)).joined(separator: "\n")
    }

    func testComposePromptKeepsPreviousWindowInSystemAndOutOfHistory() async throws {
        let h = try await make(baseURL: "http://127.0.0.1:9")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let source = Conversation(id: "previous-source", title: "云桥城布展", createTime: Date(), updateTime: Date(),
                                  currentNodeId: "previous-a", provider: "api", profileId: h.profile.id)
        h.context.insert(source)
        let marker = "星砚留在上个窗口的航图"
        conversation.memoryWindowChoices = .allOff
        conversation.memoryWindowChoices?.previousWindow = true
        conversation.previousWindowId = source.id
        conversation.previousWindowSnapshot = PreviousWindowSnapshot(sourceId: source.id, sourceTitle: source.title,
            leafId: source.currentNodeId, capturedAt: .distantPast,
            messages: [.init(nodeId: "previous-a", role: "assistant", createTime: nil, text: marker)])
        try h.context.save()
        let composed = h.viewModel.composePrompt(profile: h.profile, preset: h.preset, excludingNodeId: h.a2.id,
            context: h.context, globalEntries: [], fileLibraryHint: nil, mode: .preview)
        XCTAssertTrue(composed.ordered.contains { $0.role == "system" && $0.content.contains(marker) })
        XCTAssertFalse(composed.ordered.contains { $0.source == .chatHistory && $0.content.contains(marker) })
        XCTAssertFalse(composed.ordered.contains { $0.role != "system" && $0.content.contains(marker) })
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<MessageNode>()).contains { $0.id == "previous-a" })
    }

    func testTwoRecallReadsPersistThroughRealToolContinuationAndCallLimit() async throws {
        var windowId = "", fromId = ""
        let server = try scripted { index, _ in
            guard index == 0 else { return .init(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.okText) }
            let inputs = [
                RecallTool.Input(op: .window, conversationId: windowId),
                RecallTool.Input(op: .messages, conversationId: windowId, fromNodeId: fromId),
                RecallTool.Input(op: .search, query: "云桥城", scope: "a"),
            ]
            let calls = inputs.enumerated().map { i, input -> [String: Any] in
                ["index": i, "id": "fictional-recall-\(i)", "type": "function",
                 "function": ["name": "recall", "arguments": RecallTool.json(input)]]
            }
            let delta: [String: Any] = ["choices": [["delta": ["tool_calls": calls]]]]
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: delta), as: UTF8.self)
            return .init(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.sse([
                "data: " + line, #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, "data: [DONE]",
            ]))
        }
        let h = try await make(baseURL: server.baseURL, tools: true)
        windowId = try XCTUnwrap(h.viewModel.selectedConversation?.id)
        fromId = try XCTUnwrap(h.viewModel.currentPath.first { $0.role == "user" && !$0.isSyntheticRoot }?.id)
        var tuning = RecallTestTuning.make()
        tuning.maximumRecallCalls = 2
        tuning.originalPageMessages = 1
        RecallTuningStore.save(tuning, profileId: h.profile.id)
        let user = try send(h)
        await h.waitForTurn()
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        let receipt = try XCTUnwrap(h.viewModel.cachedRecallReceipt(assistant))
        XCTAssertEqual(receipt.reads.count, 3)
        XCTAssertEqual(receipt.reads.map(\.layer), ["A3", "原文", "原文"])
        XCTAssertEqual(receipt.reads.map(\.status), ["success", "partial", "limited"])
        XCTAssertEqual(receipt.reads.map(\.toolCallId), ["fictional-recall-0", "fictional-recall-1", "fictional-recall-2"])
        XCTAssertTrue(receipt.reads.allSatisfy { $0.turnId == receipt.decision.turnId })
        let targets = try receipt.reads.prefix(2).map { try RecallTool.decoder.decode(RecallTool.Target.self, from: Data($0.target.utf8)) }
        XCTAssertEqual(targets.map(\.conversationId), [windowId, windowId])
        XCTAssertEqual(targets.last?.fromNodeId, fromId)
        XCTAssertEqual(receipt.reads[1].returnedRange?.first?.conversationId, windowId)
        XCTAssertEqual(receipt.reads[1].returnedRange?.first?.fromNodeId, fromId)
        XCTAssertEqual(receipt.reads[1].returnedRange?.first?.lastNodeId, fromId)
        XCTAssertEqual(receipt.reads[1].next, .init(hasMore: true, cursorIssued: true))
        XCTAssertEqual(receipt.reads[2].returnedRange, [])
        XCTAssertEqual(receipt.reads[2].next, .init(hasMore: false, cursorIssued: false))
        XCTAssertEqual(user.recallReceipt?.reads, [], "user 回执只留 decision，不镜像读账")
        let fresh = ModelContext(h.context.container)
        let stored = try XCTUnwrap(fresh.fetch(FetchDescriptor<MessageNode>()).first { $0.id == assistant.id })
        XCTAssertEqual(stored.recallReceipt?.reads, receipt.reads)
        let body = try XCTUnwrap(server.requestBodies.last)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        let limit = try XCTUnwrap(messages.first { $0["tool_call_id"] as? String == "fictional-recall-2" })
        XCTAssertTrue((limit["content"] as? String)?.contains("本轮 recall 已到 2 次，目前读到 原文，余下可下一轮继续") == true)
        h.viewModel.regenerate(assistantNodeId: assistant.id, model: h.model, profile: h.profile, preset: h.preset,
                               providerManager: h.providerManager, context: h.context)
        await h.waitForTurn()
        let regenerated = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertNotEqual(regenerated.id, assistant.id)
        XCTAssertEqual(regenerated.recallReceipt?.reads, [])
        XCTAssertEqual(user.recallReceipt?.reads, [], "重生成不清 user 的 decision，也不加读账")
        XCTAssertEqual(assistant.recallReceipt?.reads, receipt.reads, "旧版本读账仍保留，不能被重生成清掉")
    }

    func testRecallErrorsConsumeTheSameFrozenCallBudget() async throws {
        let server = try scripted { index, _ in
            guard index == 0 else { return .init(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.okText) }
            let inputs = [
                #"{"query":"云桥城"}"#,
                #"{"op":"date","date":"2026-10-31","offset":99}"#,
                #"{"op":"date","date":"2026-10-31"}"#,
                #"{"op":"date","date":"2026-11-01"}"#,
            ]
            let calls = inputs.enumerated().map { i, input -> [String: Any] in
                ["index": i, "id": "fictional-error-recall-\(i)", "type": "function",
                 "function": ["name": "recall", "arguments": input]]
            }
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["tool_calls": calls]]]]), as: UTF8.self)
            return .init(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.sse([
                "data: " + line, #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, "data: [DONE]",
            ]))
        }
        let h = try await make(baseURL: server.baseURL, tools: true)
        var tuning = RecallTestTuning.make()
        tuning.maximumRecallCalls = 3
        RecallTuningStore.save(tuning, profileId: h.profile.id)
        _ = try send(h)
        await h.waitForTurn()
        let receipt = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt)
        XCTAssertEqual(receipt.reads.map(\.layer), ["原文", "A4", "A4", "A4"])
        XCTAssertEqual(receipt.reads.map(\.status), ["invalidTarget", "invalidTarget", "success", "limited"])
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(server.requestBodies.last)) as? [String: Any])
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        let limit = try XCTUnwrap(messages.first { $0["tool_call_id"] as? String == "fictional-error-recall-3" })
        XCTAssertTrue((limit["content"] as? String)?.contains("本轮 recall 已到 3 次") == true)
    }

    func test503RetryRecordsSeparateAttemptButOnlyOneEffectiveTurn() async throws {
        let server = try scripted { index, _ in
            index == 0
                ? .init(status: 503, contentType: "application/json", body: ChatRetryRouterTests.unavailable503)
                : .init(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.okText)
        }
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let user = try send(h)
        await h.waitForTurn()
        let receipt = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt)
        XCTAssertEqual(server.requestBodies.count, 2)
        XCTAssertEqual(receipt.decision.turnId, user.id)
        XCTAssertEqual(receipt.attempts.count, 2)
        XCTAssertEqual(receipt.attempts.first?.status, .failed)
        XCTAssertEqual(receipt.attempts.first?.receivedResponse, false)
        XCTAssertEqual(receipt.attempts.last?.status, .responded)
        XCTAssertEqual(receipt.attempts.last?.receivedResponse, true)
        XCTAssertEqual(Set(receipt.attempts.map(\.id)).count, 2)
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1)
    }

    func testLateFirstEventFromAbandonedBranchCannotOverwriteCurrentBranchState() async throws {
        let server = try held()
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let user = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        h.viewModel.regenerate(assistantNodeId: h.a2.id, model: h.model, profile: h.profile,
                               preset: h.preset, providerManager: h.providerManager, context: h.context)
        let lateAssistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        try await waitUntil("Regenerated branch must submit before branch navigation") {
            server.hasRequest && lateAssistant.recallReceipt?.attempts.last?.status == .submitted
        }
        let oldAnchor = try XCTUnwrap(lateAssistant.recallReceipt).decision.branchAnchor
        h.viewModel.switchBranch(at: user.id, to: 0)
        XCTAssertEqual(h.viewModel.currentPath.last?.id, h.a2.id)
        XCTAssertNotEqual(conversation.recallState.branchAnchor, oldAnchor)
        let branchState = conversation.recallState
        server.release(Self.textChunk)
        server.finish()
        await h.waitForTurn()
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
        XCTAssertEqual(conversation.recallState, branchState, "Old-branch callbacks must not apply active/cooldown/counter proposals")
        XCTAssertEqual(conversation.recallState.effectiveTurn, 0)
        XCTAssertEqual(h.viewModel.currentPath.last?.id, h.a2.id)
        XCTAssertEqual(lateAssistant.recallReceipt?.attempts.last?.status, .responded)
        XCTAssertEqual(lateAssistant.recallReceipt?.hasEffectiveResponse, true)
        h.viewModel.switchBranch(at: user.id, to: 1)
        XCTAssertEqual(h.viewModel.currentPath.last?.id, lateAssistant.id)
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1, "Returning to the original branch must recover its late response fact")
        XCTAssertEqual(conversation.recallState.lastAppliedTurnId, user.id)
    }

    /// P3 r2（Opus 建议 8）：重生成在首事件前取消——取消的 attempt 自身不算有效响应，
    /// 新回复靠 `inheritedEffective` 记「同一真实轮已生效」；切兄弟分支再切回，recover 仍只算这一轮一次
    func testRegenerateCancelledBeforeFirstEventKeepsInheritedRoundAfterBranchRecover() async throws {
        let server = try held()
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let user = try send(h)
        let firstAssistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        try await waitUntil("First request must submit") {
            server.hasRequest && firstAssistant.recallReceipt?.attempts.last?.status == .submitted
        }
        server.release(Self.textChunk)
        try await waitUntil("First reply must be effective") { firstAssistant.recallReceipt?.hasEffectiveResponse == true }
        server.finish()
        await h.waitForTurn()
        XCTAssertEqual(firstAssistant.recallReceipt?.hasEffectiveResponse, true)
        h.viewModel.regenerate(assistantNodeId: firstAssistant.id, model: h.model, profile: h.profile,
                               preset: h.preset, providerManager: h.providerManager, context: h.context)
        let regenerated = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        try await waitUntil("Regenerated request must submit before cancel") {
            server.hasRequest && regenerated.recallReceipt?.attempts.last?.status == .submitted
        }
        XCTAssertEqual(regenerated.recallReceipt?.inheritedEffective, true)
        h.viewModel.cancelAssistantTurn(context: h.context, drainQueued: false)
        XCTAssertEqual(regenerated.recallReceipt?.attempts.count, 1)
        XCTAssertEqual(regenerated.recallReceipt?.attempts.last?.status, .cancelled)
        XCTAssertEqual(regenerated.recallReceipt?.attempts.last?.receivedResponse, false, "首事件前取消的 attempt 自身不生效")
        XCTAssertEqual(regenerated.recallReceipt?.hasEffectiveResponse, true, "同一轮靠 inherited 记已生效")
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1)
        h.viewModel.switchBranch(at: user.id, to: 0)
        XCTAssertEqual(h.viewModel.currentPath.last?.id, firstAssistant.id)
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1, "旧回复自己的响应记一轮")
        h.viewModel.switchBranch(at: user.id, to: 1)
        XCTAssertEqual(h.viewModel.currentPath.last?.id, regenerated.id)
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1, "取消的重生成不算新的一轮；inherited 让同一轮只记一次")
        XCTAssertEqual(conversation.recallState.lastAppliedTurnId, user.id)
    }

    func testSelectedSiblingDoesNotInheritResponseFromSharedUserReceipt() async throws {
        let server = try scripted { _, _ in
            .init(status: 200, contentType: "text/event-stream", body: Self.textChunk)
        }
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let originalUser = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        h.viewModel.regenerate(assistantNodeId: h.a2.id, model: h.model, profile: h.profile,
                               preset: h.preset, providerManager: h.providerManager, context: h.context)
        await h.waitForTurn()
        let firstReply = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertEqual(firstReply.recallReceipt?.hasEffectiveResponse, true)
        XCTAssertEqual(firstReply.recallReceipt?.attempts.count, 1)
        XCTAssertEqual(originalUser.recallReceipt?.attempts.count, 0, "user 回执不再镜像 attempts")
        XCTAssertEqual(originalUser.recallReceipt?.hasEffectiveResponse, false, "user 回执恒未生效")
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1)
        h.viewModel.switchBranch(at: originalUser.id, to: 0)
        XCTAssertEqual(h.viewModel.currentPath.last?.id, h.a2.id)
        XCTAssertNil(h.a2.recallReceipt, "The original legacy branch never received this request")
        XCTAssertEqual(conversation.recallState.effectiveTurn, 0,
                       "A user's decision-only receipt must not invent a response on its unresponded sibling")
        XCTAssertTrue(conversation.recallState.cooldowns.isEmpty)
        h.viewModel.regenerate(assistantNodeId: h.a2.id, model: h.model, profile: h.profile,
                               preset: h.preset, providerManager: h.providerManager, context: h.context)
        await h.waitForTurn()
        XCTAssertEqual(conversation.recallState.effectiveTurn, 1,
                       "A real response on the selected path must commit even when a sibling already responded")
        let secondReply = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertEqual(secondReply.recallReceipt?.attempts.count, 1, "The legacy selected branch only records its own attempt")
        XCTAssertNil(secondReply.recallReceipt?.inheritedEffective, "Legacy sibling had no response fact to inherit")
        XCTAssertEqual(originalUser.recallReceipt?.attempts.count, 0)
    }

    func testSwitchingBranchesPreservesConversationUpdateTime() async throws {
        let server = try scripted { _, _ in
            .init(status: 200, contentType: "text/event-stream", body: Self.textChunk)
        }
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let user = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        h.viewModel.regenerate(assistantNodeId: h.a2.id, model: h.model, profile: h.profile,
                               preset: h.preset, providerManager: h.providerManager, context: h.context)
        await h.waitForTurn()
        let regenerated = try XCTUnwrap(h.viewModel.currentPath.last)
        let updateTime = conversation.updateTime
        h.viewModel.switchBranch(at: user.id, to: 0)
        XCTAssertEqual(h.viewModel.currentPath.last?.id, h.a2.id)
        XCTAssertEqual(conversation.updateTime, updateTime)
        h.viewModel.switchBranch(at: user.id, to: 1)
        XCTAssertEqual(h.viewModel.currentPath.last?.id, regenerated.id)
        XCTAssertEqual(conversation.updateTime, updateTime)
    }

    func testTuningChangeAppliesToNextUserButRegenerateKeepsItsSnapshot() async throws {
        let server = try scripted { _, _ in
            .init(status: 200, contentType: "text/event-stream", body: Self.textChunk)
        }
        let h = try await make(baseURL: server.baseURL)
        var tuning = RecallTestTuning.make()
        tuning.minimumEffectiveLength = 2
        RecallTuningStore.save(tuning, profileId: h.profile.id)
        defer { RecallTuningStore.reset(profileId: h.profile.id) }
        XCTAssertTrue(h.viewModel.sendMessage("云桥", model: h.model, profile: h.profile, preset: h.preset,
                                             providerManager: h.providerManager, context: h.context))
        await h.waitForTurn()
        let firstUser = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        let first = try XCTUnwrap(firstUser.recallReceipt)
        XCTAssertEqual(first.decision.gateReason, .search)
        XCTAssertEqual(first.decision.tuning, tuning)
        tuning.minimumEffectiveLength = 8
        RecallTuningStore.save(tuning, profileId: h.profile.id)
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        h.viewModel.regenerate(assistantNodeId: assistant.id, model: h.model, profile: h.profile,
                               preset: h.preset, providerManager: h.providerManager, context: h.context)
        await h.waitForTurn()
        let regenerated = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt)
        XCTAssertEqual(regenerated.decision.tuning, first.decision.tuning, "重生成沿用那一轮的 tuning 快照")
        XCTAssertEqual(regenerated.decision.gateReason, .search)
        XCTAssertTrue(h.viewModel.sendMessage("星砚云桥", model: h.model, profile: h.profile, preset: h.preset,
                                             providerManager: h.providerManager, context: h.context))
        await h.waitForTurn()
        let next = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" }?.recallReceipt)
        XCTAssertEqual(next.decision.tuning, tuning)
        XCTAssertEqual(next.decision.gateReason, .shortInput)
        XCTAssertEqual(conversationTurn(h), 1)
    }

    func testRepeatedComposeReusesDecodedReceiptsAndInvalidatesChangedBytes() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        _ = try send(h)
        await h.waitForTurn()
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        func compose() -> ConversationViewModel.ComposedPrompt {
            h.viewModel.composePrompt(profile: h.profile, preset: h.preset, excludingNodeId: assistant.id,
                                      context: h.context, globalEntries: [], fileLibraryHint: nil, mode: .preview)
        }
        let first = compose()
        let decoded = h.viewModel.recallReceiptDecodeCount
        let second = compose()
        XCTAssertEqual(h.viewModel.recallReceiptDecodeCount - decoded, 0)
        XCTAssertEqual(second.recallDecision, first.recallDecision)
        var receipt = try XCTUnwrap(assistant.recallReceipt)
        receipt.reads.append(.init(toolCallId: "fictional-read", turnId: receipt.decision.turnId, layer: "original", target: "林栖"))
        assistant.recallReceipt = receipt
        _ = compose()
        XCTAssertEqual(h.viewModel.recallReceiptDecodeCount - decoded, 1, "Receipt data changes invalidate only that node")
    }

    func testRecallCallFuseUsesTurnSnapshotAndNextTurnUsesNewTuning() async throws {
        let calls: [[String: Any]] = (0..<3).map { index in
            ["index": index, "id": "fictional-recall-\(index)", "type": "function",
             "function": ["name": RecallTool.toolName, "arguments": #"{"op":"search","scope":"a","query":"云桥城","exact":true}"#]]
        }
        let callJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [
            ["delta": ["tool_calls": calls]]
        ]]), as: UTF8.self)
        let batch = OutputTokenCapTests.sse(["data: " + callJSON,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, "data: [DONE]"])
        let server = try scripted { index, _ in
            .init(status: 200, contentType: "text/event-stream", body: index.isMultiple(of: 2) ? batch : Self.textChunk)
        }
        let h = try await make(baseURL: server.baseURL, tools: true)
        h.overrideDefault("mem_content_convhistory", true)
        var tuning = RecallTestTuning.make()
        tuning.maximumRecallCalls = 1
        RecallTuningStore.save(tuning, profileId: h.profile.id)
        var changedSettings = false
        RequestBodyTap.handler = { _ in
            guard !changedSettings else { return }
            changedSettings = true
            var next = tuning
            next.maximumRecallCalls = 2
            RecallTuningStore.save(next, profileId: h.profile.id)
        }
        let firstUser = try send(h)
        await h.waitForTurn()
        RequestBodyTap.handler = nil
        func results() throws -> [Bool] {
            let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
            return (assistant.segments ?? []).compactMap { segment in
                if case .toolResult(_, _, let error, let name) = segment, name == "回忆" { return error }
                return nil
            }
        }
        XCTAssertEqual(try results(), [false, true, true])
        XCTAssertEqual(firstUser.recallReceipt?.decision.tuning.maximumRecallCalls, 1)
        let secondUser = try send(h)
        await h.waitForTurn()
        XCTAssertEqual(try results(), [false, false, true])
        XCTAssertEqual(secondUser.recallReceipt?.decision.tuning.maximumRecallCalls, 2)
        XCTAssertEqual(server.requestBodies.count, 4)
    }

    func testLocalSystemTruncationReceiptsMatchActualWireIncludingPartialSource() async throws {
        let h = try await make(baseURL: "http://127.0.0.1:9")
        var preset = h.preset
        preset.prompts = [
            PromptSlot(id: PromptSlot.mainId, name: "合成规则", content: "合成规则"),
            PromptSlot(id: PromptSlot.memoryInjectionId, name: "记忆", isMarker: true),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "历史", isMarker: true)
        ]
        let page = WikiInjectionSnapshot.Page(path: "人/林栖", title: "林栖", triggers: [],
            hook: "云桥城的地图计划", now: String(repeating: "林栖在云桥城整理星图。", count: 20), version: "fictional-v1")
        let warmed = WikiInjectionCache.WarmedSnapshot(generation: 0, snapshot: .init(pages: [page]))
        let user = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        func compose(_ type: ProviderType?, mode: ConversationViewModel.ComposeMode) -> ConversationViewModel.ComposedPrompt {
            h.viewModel.composePrompt(profile: h.profile, preset: preset, excludingNodeId: h.a2.id,
                context: h.context, globalEntries: [], fileLibraryHint: nil, mode: mode, cardGuide: (.none, nil),
                warmedWiki: warmed, providerType: type)
        }
        let full = compose(nil, mode: .preview)
        let item = try XCTUnwrap(full.recallDecision.selected.first { $0.source.path == page.path })
        let fullSystem = try XCTUnwrap(PromptMessage.legacyShape(full.ordered).systemPrompt)
        let range = try XCTUnwrap(fullSystem.range(of: item.text))
        let itemOffset = fullSystem.distance(from: fullSystem.startIndex, to: range.lowerBound)
        let partialPadding = LocalChatProvider.systemBudget - itemOffset - item.text.count / 2
        XCTAssertGreaterThan(partialPadding, 0)
        for padding in [partialPadding, LocalChatProvider.systemBudget + 1] {
            user.recallReceiptData = nil
            h.a2.recallReceiptData = nil
            conversation.recallStateData = nil
            preset.prompts[0].content = "合成规则" + String(repeating: "岚", count: padding)
            let composed = compose(.localMLX, mode: .send)
            let legacy = PromptMessage.legacyShape(composed.ordered)
            let wire = LocalChatProvider.trimmed(system: legacy.systemPrompt ?? "", messages: legacy.messages, hasImages: false)
            let receipt = try XCTUnwrap(h.a2.recallReceipt)
            XCTAssertEqual(receipt.decision.candidates.first?.source.path, page.path)
            XCTAssertNil(MemoryInjectionMeter.load(profileId: h.profile.id), "组装不写 Meter：没响应就没有上一轮")
            let delivery = try XCTUnwrap(receipt.delivery)
            XCTAssertEqual(delivery.route, "local")
            let deliveredPage = delivery.items.first { $0.ref == MemoryDelivery.key(item.source) }
            if padding == partialPadding {
                let sent = try XCTUnwrap(receipt.decision.selected.first)
                XCTAssertEqual(sent.source, item.source)
                XCTAssertTrue(item.text.hasPrefix(sent.text))
                XCTAssertLessThan(sent.text.count, item.text.count)
                XCTAssertTrue(wire.system.contains(sent.text))
                XCTAssertEqual(receipt.decision.stateAfterResponse.pending, [sent])
                XCTAssertEqual(receipt.injectionRecord?.hitCount, 1)
                XCTAssertEqual(deliveredPage?.trimmed, true, "截了一半标 trimmed")
            } else {
                XCTAssertTrue(receipt.decision.selected.isEmpty)
                XCTAssertTrue(receipt.decision.stateAfterResponse.pending.isEmpty)
                XCTAssertFalse(wire.system.contains(item.text))
                XCTAssertEqual(receipt.injectionRecord?.hitCount, 0)
                XCTAssertEqual(receipt.injectionRecord?.tokens, 0)
                XCTAssertNil(deliveredPage, "整块掉在截断线外 = 不进账")
            }
            let actualMemory = LocalChatProvider.retainedSystemSegments(composed.segments)
                .filter { $0.source == .memory && !$0.content.isEmpty }.map(\.content).joined(separator: "\n\n")
            XCTAssertEqual(receipt.injectionRecord?.tokens, actualMemory.isEmpty ? 0 : Memory.estimateTokens(actualMemory))
            if !actualMemory.isEmpty { XCTAssertTrue(wire.system.contains(actualMemory)) }
        }
    }

    func testLocalTruncationDoesNotCreditStableDuplicateAsDeliveredRecall() async throws {
        let h = try await make(baseURL: "http://127.0.0.1:9")
        var preset = h.preset
        preset.sampling.cacheFriendly = false
        preset.prompts = [
            PromptSlot(id: PromptSlot.mainId, name: "合成规则", content: "合成规则"),
            PromptSlot(id: PromptSlot.memoryInjectionId, name: "记忆", isMarker: true),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "历史", isMarker: true)
        ]
        let page = WikiInjectionSnapshot.Page(path: "人/林栖", title: "林栖", triggers: [],
            hook: "云桥城的地图计划", now: "林栖在云桥城整理星图。", version: "fictional-duplicate-v1")
        let warmed = WikiInjectionCache.WarmedSnapshot(generation: 0, snapshot: .init(pages: [page]))
        let user = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        func compose(_ type: ProviderType?, mode: ConversationViewModel.ComposeMode) -> ConversationViewModel.ComposedPrompt {
            h.viewModel.composePrompt(profile: h.profile, preset: preset, excludingNodeId: h.a2.id,
                context: h.context, globalEntries: [], fileLibraryHint: nil, mode: mode, cardGuide: (.none, nil),
                warmedWiki: warmed, providerType: type)
        }
        let item = try XCTUnwrap(compose(nil, mode: .preview).recallDecision.selected.first { $0.source.path == page.path })
        let pinned = Memory(content: item.text, category: "fact", profileId: h.profile.id, isUserExplicit: true)
        h.context.insert(pinned)
        try h.context.save()
        let full = compose(nil, mode: .preview)
        let segment = try XCTUnwrap(full.segments.first { $0.source == .memory })
        let first = try XCTUnwrap(segment.content.range(of: item.text))
        let second = try XCTUnwrap(segment.content.range(of: item.text, range: first.upperBound..<segment.content.endIndex))
        let system = try XCTUnwrap(PromptMessage.legacyShape(full.ordered).systemPrompt)
        let memoryRange = try XCTUnwrap(system.range(of: segment.content))
        let secondOffset = system.distance(from: system.startIndex, to: memoryRange.lowerBound)
            + segment.content.distance(from: segment.content.startIndex, to: second.lowerBound)
        let padding = LocalChatProvider.systemBudget - secondOffset
        XCTAssertGreaterThan(padding, 0)
        preset.prompts[0].content += String(repeating: "岚", count: padding)
        let composed = compose(.localMLX, mode: .send)
        let legacy = PromptMessage.legacyShape(composed.ordered)
        let wire = LocalChatProvider.trimmed(system: legacy.systemPrompt ?? "", messages: legacy.messages, hasImages: false)
        XCTAssertTrue(wire.system.contains(item.text), "The stable copy survives, but the X copy starts at the truncation boundary")
        let receipt = try XCTUnwrap(h.a2.recallReceipt)
        XCTAssertEqual(receipt.decision.candidates.map(\.source), [item.source])
        XCTAssertTrue(receipt.decision.selected.isEmpty)
        XCTAssertTrue(receipt.decision.stateAfterResponse.pending.isEmpty)
        XCTAssertEqual(receipt.injectionRecord?.hitCount, 0)
        XCTAssertEqual(receipt.injectionRecord?.stableCount, 1)
        XCTAssertNil(MemoryInjectionMeter.load(profileId: h.profile.id), "组装不写 Meter")
        XCTAssertEqual(user.recallReceipt?.attempts.count, 0, "user 回执只留 decision")
    }

    func testX2CardReachesSystemReceiptMeterAndNeverReturnsToA2OrC2() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        try await h.seedWiki([WikiPage(path: "主题/合成父页", title: "合成父页", now: "父页不得扩展")])
        let pid = h.profile.id
        let card = try await Task.detached {
            let wiki = WikiStore(profileId: pid)
            let card = SeedNoteCard(path: "memory/cc/合成路线.md", version: "fictional-v1", name: "合成卡",
                                    layer: "CC", title: "合成航线卡", gist: "cedar maple 卡片独有载荷",
                                    mentions: [.init(name: "Orivale", group: "人")], aboutUser: false, group: "主题",
                                    when: [], model: "fixture", madeAt: Date(timeIntervalSince1970: 1_000), run: .init(path: "fixture"))
            try SeedNoteStore(wiki: wiki).save(card)
            try wiki.saveRaw(WikiPage(path: "主题/合成父页", title: "合成父页", now: "父页不得扩展",
                                     entries: [card.path + "|" + card.version]).markdown, path: "主题/合成父页")
            return card
        }.value
        var bodies: [[String: Any]] = []
        RequestBodyTap.handler = { bodies.append($0) }
        XCTAssertTrue(h.viewModel.sendMessage("cedar maple", model: h.model, profile: h.profile, preset: h.preset,
                                             providerManager: h.providerManager, context: h.context))
        let user = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        await h.waitForTurn()
        let receipt = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt)
        XCTAssertEqual(receipt.decision.selected.map(\.source.kind), [.card])
        let item = try XCTUnwrap(receipt.decision.selected.first)
        XCTAssertEqual(item.source.path, card.path)
        XCTAssertEqual(item.source.version, card.version)
        let messages = try XCTUnwrap(bodies.last?["messages"] as? [[String: Any]])
        let system = messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }.joined(separator: "\n")
        XCTAssertTrue(system.contains(item.text))
        XCTAssertTrue(system.contains(card.gist))
        XCTAssertTrue(system.contains(card.path + "|" + card.version))
        XCTAssertFalse(system.contains("父页不得扩展"))
        for message in messages where message["role"] as? String != "system" {
            XCTAssertFalse(String(describing: message["content"]).contains("卡片独有载荷"))
        }
        let a2 = h.viewModel.sessionMessages()
        let agentIds = Set(h.viewModel.currentPath.filter { $0.agentOrigin != nil }.map(\.id))
        let c2 = a2.filter { !agentIds.contains($0.id) }
        for source in [a2, c2] {
            XCTAssertTrue(source.contains { $0.id == user.id && $0.content == "cedar maple" })
            XCTAssertFalse(source.map(\.content).joined().contains("卡片独有载荷"))
        }
        XCTAssertEqual(receipt.injectionRecord, MemoryInjectionMeter.load(profileId: pid))
        XCTAssertEqual(receipt.injectionRecord?.hitCount, 1)
        XCTAssertEqual(receipt.decision.stateAfterResponse.active, [item])
        XCTAssertEqual(receipt.decision.stateAfterResponse.pending, [item])
        XCTAssertEqual(h.viewModel.selectedConversation?.recallState.active, [item])
        let preview = h.viewModel.composePrompt(profile: h.profile, preset: h.preset, excludingNodeId: nil,
                                               context: h.context, globalEntries: [], fileLibraryHint: nil, mode: .preview)
        XCTAssertEqual(preview.recallDecision.selected, [], "同步预览不读卡，不伪造 X2 候选")
        var changed = RecallTestTuning.make()
        changed.minimumLatinTermLength = 8
        RecallTuningStore.save(changed, profileId: pid)
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        h.viewModel.regenerate(assistantNodeId: assistant.id, model: h.model, profile: h.profile,
                               preset: h.preset, providerManager: h.providerManager, context: h.context)
        await h.waitForTurn()
        let regenerated = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt)
        XCTAssertEqual(regenerated.decision.tuning.minimumLatinTermLength, receipt.decision.tuning.minimumLatinTermLength)
        XCTAssertEqual(regenerated.decision.selected, [item], "同一真实轮的候选取回也使用历史 tuning，而非新设置")
        XCTAssertEqual(regenerated.inheritedEffective, true, "上一版已生效")
        XCTAssertEqual(h.viewModel.selectedConversation?.recallState.effectiveTurn, 1)
        RecallTuningStore.save(RecallTestTuning.make(), profileId: pid)
        XCTAssertTrue(h.viewModel.sendMessage("cedar maple veloria juniper", model: h.model, profile: h.profile, preset: h.preset,
                                             providerManager: h.providerManager, context: h.context))
        let continued = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        await h.waitForTurn()
        let kept = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt)
        XCTAssertEqual(kept.decision.gateReason, .kept)
        XCTAssertEqual(continued.recallReceipt?.attempts.count, 0, "user 回执只留 decision")
        XCTAssertEqual(kept.decision.selected, [item], "无合格新命中的保持轮仍核验并携带同版卡")
        let keptMessages = try XCTUnwrap(bodies.last?["messages"] as? [[String: Any]])
        let keptSystem = keptMessages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }.joined(separator: "\n")
        XCTAssertTrue(keptSystem.contains(item.text))
        XCTAssertEqual(h.viewModel.selectedConversation?.recallState.active, [item])
        XCTAssertEqual(kept.injectionRecord, MemoryInjectionMeter.load(profileId: pid))
        RecallTuningStore.save(changed, profileId: pid)
        XCTAssertTrue(h.viewModel.sendMessage("cedar maple", model: h.model, profile: h.profile, preset: h.preset,
                                             providerManager: h.providerManager, context: h.context))
        let next = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        await h.waitForTurn()
        XCTAssertEqual(next.recallReceipt?.decision.tuning.minimumLatinTermLength, 8)
        XCTAssertEqual(next.recallReceipt?.decision.selected, [])
    }

    /// P2-b：所有生产者吐的单位都核到了 wire 上（A2 / 时间轴 / 待续 / 纪念日 / B4 / 根索引 / 钉住 / Z7 / X），
    /// 逐单位对应 kind / ref / shown / wire 文本；cacheFriendly 开 / 关各跑一遍（开时 X 段独立成段，认段分支不同）
    func testDeliveryItemsAllOnWireForFullTurn() async throws {
        for cacheFriendly in [false, true] {
            let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
            let h = try await make(baseURL: server.baseURL, cacheFriendly: cacheFriendly)
            try h.seedMemoryFixtures()
            let pid = h.profile.id
            let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
            // Z7：上窗快照（源窗还活着，复核不改）
            let source = Conversation(id: "xctest-p2-prev-source", title: "上一窗", createTime: Date(timeIntervalSince1970: 1),
                                      updateTime: Date(timeIntervalSince1970: 1), currentNodeId: "", provider: "api", profileId: pid)
            source.memoryEnabled = true
            h.context.insert(source)
            conversation.previousWindowSnapshot = PreviousWindowSnapshot(
                sourceId: source.id, sourceTitle: "上一窗", leafId: "xctest-p2-leaf",
                capturedAt: Date(timeIntervalSince1970: 1),
                messages: [.init(nodeId: "xctest-p2-prev-1", role: "user", createTime: nil, text: "上窗说过的话")])
            conversation.previousWindowId = source.id
            conversation.memoryWindowChoices = MemoryWindowChoices(timeline: true, pending: true, selfMemory: true,
                                                                  archive: true, previousWindow: true, pinned: true)
            // 钉住
            h.context.insert(Memory(content: "钉住的事实：云桥城周日布展", category: "fact", profileId: pid, isUserExplicit: true))
            // B4 自己的记忆
            let selfDir = SelfMemoryStore.directory(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), checkPath: AppPaths.checked)
            cleanups.append { try? FileManager.default.removeItem(at: selfDir) }
            try SelfMemoryStore.save(SelfMemory(slug: SelfMemoryStore.slugify("布展习惯"), name: "布展习惯", description: "偏好",
                                               type: "user", importance: 5, origin: "asked",
                                               created: Date(timeIntervalSince1970: 1), body: "先排地图再排展位"),
                                     memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), checkPath: AppPaths.checked)
            // 纪念日
            let anniversaryRoot = AnniversaryStore.forProfile(pid).root
            cleanups.append { try? FileManager.default.removeItem(at: anniversaryRoot) }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            try AnniversaryStore.forProfile(pid).save(Anniversary(title: "云桥城周年", kind: .countdown,
                                                                  date: formatter.string(from: Date().addingTimeInterval(2 * 86400)),
                                                                  remindDays: 5))
            // 今天的日记（P0：日记不受记忆参与闸，日历隐私开就进账）
            let journalDay = DailyActivity.dayKey(PromptRealPathHarness.fixedNow, calendar: .current)
            let journalBody = "今天在云桥城画了一天地图，晚上和星砚吃了团子。"
            h.overrideDefault(CalendarPrivacy.journalVisibleKey(pid), true)
            h.overrideDefault(CalendarPrivacy.injectTodayJournalKey(pid), true)
            let journalRoot = JournalStore.forProfile(pid).root
            cleanups.append { try? FileManager.default.removeItem(at: journalRoot) }
            try JournalStore.forProfile(pid).overwriteBody(journalBody, date: journalDay,
                                                           newFileFrontmatter: ["date: \(journalDay)", "mood:"])
            // C：根索引 + X 命中
            var page = WikiPage(path: "地点/云桥城", title: "云桥城", now: "云桥城的地图计划记在旧本子上")
            page.triggers = ["林栖"]
            try await h.seedWiki([page])
            try h.context.save()

            var bodies: [[String: Any]] = []
            RequestBodyTap.handler = { bodies.append($0) }
            _ = try send(h)
            await h.waitForTurn()
            RequestBodyTap.handler = nil
            let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
            let delivery = try XCTUnwrap(assistant.recallReceipt?.delivery)
            XCTAssertEqual(delivery.route, "api", "cacheFriendly=\(cacheFriendly)")
            XCTAssertNil(delivery.gate.off, "cacheFriendly=\(cacheFriendly)")
            XCTAssertTrue(delivery.gate.participates, "cacheFriendly=\(cacheFriendly)")
            XCTAssertFalse(delivery.gate.triggerOff, "cacheFriendly=\(cacheFriendly)")
            let body = try XCTUnwrap(bodies.last)
            let wire = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
                .replacingOccurrences(of: "\\n", with: "\n")
            // 期望表按账的顺序：修好的核对口径下「账 = wire 逐项」，多一项 / 少一项 / 顺序错都红
            let conversationKey = String(conversation.id.prefix(8))
            let expectations: [(kind: String, refPrefix: String, shown: String, marker: String)] = [
                (RecallDeliveryItem.Kind.selfMemory, "selfMemory", "全文 1 · 目录 0", "先排地图再排展位"),
                (RecallDeliveryItem.Kind.rootIndex, "rootIndex", "根索引 3 行", "[C 档案 · 索引]"),
                (RecallDeliveryItem.Kind.pinned, "memory:", "钉住的事实：云桥城周日布展", "云桥城周日布展"),
                (RecallDeliveryItem.Kind.previousWindow, "previousWindow:", "上个窗口 1 条", "上窗说过的话"),
                (RecallDeliveryItem.Kind.page, "page:地点/云桥城|", "云桥城", "云桥城的地图计划记在旧本子上"),
                (RecallDeliveryItem.Kind.a2, "\(conversationKey)|xctest-node-out-of-window", "挤出视野的一段", "挤出视野的一段"),
                (RecallDeliveryItem.Kind.timeline, "2026-10-08", "聊了团子的体检", "聊了团子的体检"),
                (RecallDeliveryItem.Kind.timeline, "2026-10-09", "本窗口早先聊的（原文已不在窗口里）", "本窗口早先聊的（原文已不在窗口里）"),
                (RecallDeliveryItem.Kind.timeline, "2026-10-10", "（旧格式，没有主调）", "（旧格式，没有主调）"),
                (RecallDeliveryItem.Kind.timeline, "2026-10-10|\(PromptRealPathHarness.otherWindowId)", "给团子买了猫粮", "给团子买了猫粮"),
                (RecallDeliveryItem.Kind.pending, "pending:\(PromptRealPathHarness.otherWindowId)", "周末问团子吃不吃", "周末问团子吃不吃"),
                (RecallDeliveryItem.Kind.pending, "pending:\(conversation.id)", "本窗口待续：周三复诊", "本窗口待续：周三复诊"),
                (RecallDeliveryItem.Kind.anniversary, "anniversary", "云桥城周年", "云桥城周年"),
                (RecallDeliveryItem.Kind.journal, "journal:\(journalDay)", "今天的日记", "晚上和星砚吃了团子"),
            ]
            XCTAssertEqual(delivery.items.count, expectations.count,
                           "账上项数（cacheFriendly=\(cacheFriendly)）：\(delivery.items.map { "\($0.kind)|\($0.ref)|\($0.shown)" })")
            for (index, pair) in zip(delivery.items, expectations).enumerated() {
                XCTAssertEqual(pair.0.kind, pair.1.kind, "第 \(index) 项 kind（cacheFriendly=\(cacheFriendly)）")
                XCTAssertTrue(pair.0.ref.hasPrefix(pair.1.refPrefix), "第 \(index) 项 ref = \(pair.0.ref)")
                XCTAssertTrue(pair.0.shown.contains(pair.1.shown), "第 \(index) 项 shown = \(pair.0.shown)")
                XCTAssertTrue(wire.contains(pair.1.marker), "wire 上没有第 \(index) 项（\(pair.0.kind)）的 \(pair.1.marker)")
                XCTAssertNil(pair.0.trimmed, "第 \(index) 项（\(pair.0.kind)）整块在 wire 上")
            }
            await h.tearDown()
            harness = nil
        }
    }

    /// P0：本窗关参与、日历隐私开 → 账上只有今天的日记，没有记忆项（日记不受记忆参与闸）。
    func testJournalDeliveredWhenMemoryOffButCalendarOn() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let pid = h.profile.id
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.memoryEnabled = false
        let day = DailyActivity.dayKey(PromptRealPathHarness.fixedNow, calendar: .current)
        let body = "今天的日记只写在纸上：云桥城下了雨。"
        h.overrideDefault(CalendarPrivacy.journalVisibleKey(pid), true)
        h.overrideDefault(CalendarPrivacy.injectTodayJournalKey(pid), true)
        let journalRoot = JournalStore.forProfile(pid).root
        cleanups.append { try? FileManager.default.removeItem(at: journalRoot) }
        try JournalStore.forProfile(pid).overwriteBody(body, date: day, newFileFrontmatter: ["date: \(day)", "mood:"])
        try h.context.save()

        var bodies: [[String: Any]] = []
        RequestBodyTap.handler = { bodies.append($0) }
        _ = try send(h)
        await h.waitForTurn()
        RequestBodyTap.handler = nil

        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        let delivery = try XCTUnwrap(assistant.recallReceipt?.delivery)
        XCTAssertEqual(delivery.gate.off, "window", "本窗关参与")
        XCTAssertEqual(delivery.items.map(\.kind), [RecallDeliveryItem.Kind.journal], "账上只有日记一项，没有记忆项")
        let journal = try XCTUnwrap(delivery.items.first)
        XCTAssertEqual(journal.ref, "journal:\(day)")
        XCTAssertEqual(journal.shown, "今天的日记")
        XCTAssertNil(journal.trimmed)
        XCTAssertTrue(journal.tokens > 0)
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: try XCTUnwrap(bodies.last)), as: UTF8.self)
        XCTAssertTrue(wire.contains("云桥城下了雨"), "日记正文一字不差在 wire 上")
    }

    /// P2-b 必修 1：本机实发工具集是空集（不是 nil）→ assembler 把 B4 footer 换成空串、删 recall 指路句；
    /// 记忆单位必须和实发段（变换后）对齐，否则整批 `.none`。
    func testLocalDeliveryWithEmptyToolsAndB4CountsAllMemoryUnits() async throws {
        let h = try await make(baseURL: "http://127.0.0.1:9")
        let pid = h.profile.id
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.memoryWindowChoices = MemoryWindowChoices(timeline: false, pending: false, selfMemory: true,
                                                              archive: true, previousWindow: false, pinned: true)
        // B4：一条自己的记忆（原文带 footer）
        let selfDir = SelfMemoryStore.directory(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), checkPath: AppPaths.checked)
        cleanups.append { try? FileManager.default.removeItem(at: selfDir) }
        try SelfMemoryStore.save(SelfMemory(slug: SelfMemoryStore.slugify("布展习惯"), name: "布展习惯", description: "偏好",
                                           type: "user", importance: 5, origin: "asked",
                                           created: Date(timeIntervalSince1970: 1), body: "先排地图再排展位"),
                                 memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), checkPath: AppPaths.checked)
        // 钉住一条（stable）+ C 的一页 X
        h.context.insert(Memory(content: "钉住的事实：云桥城周日布展", category: "fact", profileId: pid, isUserExplicit: true))
        var page = WikiPage(path: "地点/云桥城", title: "云桥城", now: "云桥城的地图计划记在旧本子上")
        page.triggers = ["林栖"]
        try await h.seedWiki([page])
        try h.context.save()
        func compose() -> ConversationViewModel.ComposedPrompt {
            h.viewModel.composePrompt(profile: h.profile, preset: h.preset, excludingNodeId: h.a2.id,
                                      context: h.context, globalEntries: [], fileLibraryHint: nil, mode: .preview,
                                      cardGuide: (.full, []), providerType: .localMLX)
        }
        func assertFull(_ delivery: RecallDelivery, _ kinds: [String], _ label: String) {
            for kind in kinds {
                let items = delivery.items.filter { $0.kind == kind }
                XCTAssertFalse(items.isEmpty, "\(label)：\(kind) 没进账（实有 \(delivery.items.map(\.kind))）")
                XCTAssertTrue(items.allSatisfy { $0.trimmed == nil }, "\(label)：\(kind) 整块在 wire 上，不该 trimmed")
            }
        }
        // 触发开：self / rootIndex / pinned / X 页全部在账上
        let triggered = compose()
        XCTAssertEqual(triggered.delivery.route, "local")
        assertFull(triggered.delivery, [RecallDeliveryItem.Kind.selfMemory, RecallDeliveryItem.Kind.rootIndex,
                                       RecallDeliveryItem.Kind.pinned, RecallDeliveryItem.Kind.page], "触发开")
        // 触发关：legacy 碎片也在账上（同一条本机口径）
        let fragment = Memory(content: "合成碎片：云桥城地图带尺", category: "fact", profileId: pid)
        fragment.occurredDay = "2026-10-28"
        fragment.reviewedAt = Date()
        h.context.insert(fragment)
        try h.context.save()
        var tuning = RecallTestTuning.make()
        tuning.archiveTriggerEnabled = false
        RecallTuningStore.save(tuning, profileId: pid)
        let legacy = compose()
        assertFull(legacy.delivery, [RecallDeliveryItem.Kind.selfMemory, RecallDeliveryItem.Kind.rootIndex,
                                     RecallDeliveryItem.Kind.legacyFragment], "触发关")
    }

    /// P2-a 必修 2：触发关的内层 stable 命中不在这段 wire 上，不记账；内层过期提醒实际拼进 volatile，要单独进账
    func testTriggerOffNestedReminderAndStableHitAreDelivered() throws {
        let keys = ["mem_inject_keyword", "mem_inject_vector", "mem_inject_graph", "mem_inject_catalog", "mem_inject_full"]
        var savedDefaults: [String: Any] = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { savedDefaults[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        defer {
            for key in keys {
                if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.set(true, forKey: "mem_inject_full")
        let pid = "xctest-recall-nested-reminder"
        // 长称呼让常驻层的头部（`[关于…]`）比提醒本身贵：外层装不下那条钉住项，内层（无头部计费）装得下
        let profile = Profile(id: pid, name: "云桥城", emoji: "", description: "",
                             userName: String(repeating: "岚", count: 20), assistantName: "星砚")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pinned = Memory(content: "复诊", category: "fact", profileId: pid, isUserExplicit: true)
        pinned.validUntil = FragmentPool.validUntilDate("2026-10-22")
        let fragment = Memory(content: "云桥展", category: "fact", profileId: pid)
        fragment.occurredDay = "2026-10-28"
        fragment.reviewedAt = Date()
        var tuning = RecallTestTuning.make()
        tuning.archiveTriggerEnabled = false
        let pinnedPayload = MemoryInjector.injectionPayload(pinned, stable: true, catalog: false, now: now)
        let reminderLine = "- \(pinned.content)（已过期）"
        let reminderCost = Memory.estimateTokens("[已过期的钉住项]\n") + Memory.estimateTokens(reminderLine)
        let fragmentPayload = MemoryInjector.injectionPayload(fragment, stable: false, catalog: false, now: now)
        let headerCost = Memory.estimateTokens("[关于\(profile.userName)]\n")
        // 口径前提：外层 pinned 循环被头部挡下（外层装不下），内层 = 钉住行 + 提醒 + 碎片行装得下
        let budget = pinnedPayload.cost + reminderCost + fragmentPayload.cost
        XCTAssertGreaterThan(Memory.estimateTokens(pinnedPayload.text) + headerCost, budget, "外层得被头部挡下")
        XCTAssertLessThanOrEqual(reminderCost + fragmentPayload.cost, headerCost, "提醒 + 碎片行必须比头部便宜")
        var inputs = MemoryInjector.RoundInputs(memories: [pinned, fragment], selfMemory: nil, archiveBudget: budget)
        inputs.rootIndex = false
        let layers = RecallSelection.prepare(profile: profile, conversationId: "fictional-window", turnId: "u1",
                                             branchAnchor: "branch", text: "复诊和云桥展怎么安排",
                                             state: .init(), existingDecision: nil, inputs: inputs,
                                             recentMessages: ["复诊和云桥展怎么安排"], now: now, tuning: tuning).layers
        XCTAssertTrue(layers.volatile.contains("[已过期的钉住项]\n\(reminderLine)"), "提醒 prepend 在 volatile 首部")
        XCTAssertTrue(layers.volatile.contains(fragmentPayload.text), "碎片行在 wire 上")
        XCTAssertEqual(layers.units.map(\.kind), [RecallDeliveryItem.Kind.expiredReminder, RecallDeliveryItem.Kind.legacyFragment],
                       "只有真正拼进 volatile 的项进账（内层 stable 命中不在这段 wire 上）")
        XCTAssertEqual(layers.units.first?.members ?? [], [pinned.id.uuidString], "提醒点名的是那条钉住项")
        XCTAssertFalse(layers.units.contains { $0.text.contains(pinnedPayload.text) }, "内层 stable 命中不记账")
        let gate = RecallGateSnapshot(off: nil, participates: true, triggerOff: true, legacy: true, choices: [:],
                                      a2Checked: false, hiddenFragments: 0, hiddenTimeline: 0)
        let delivery = MemoryDelivery.build(units: layers.units, route: "api", gate: gate,
                                            locate: MemoryDelivery.containmentLocator([.memoryVolatile: layers.volatile], transform: { $0 }))
        XCTAssertEqual(delivery.items.map(\.kind), [RecallDeliveryItem.Kind.expiredReminder, RecallDeliveryItem.Kind.legacyFragment])
        XCTAssertTrue(delivery.items.allSatisfy { $0.trimmed == nil })
    }

    /// P2-b 步 2：本轮不发 recall 时，组装层把目录尾的指路句删掉；单位文本要过同一步，否则 contains 落空、账少项
    func testCatalogHintDroppedWhenRecallNotOfferedStillDelivered() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL, tools: true)
        h.overrideDefault("mem_inject_catalog", true)
        let pid = h.profile.id
        let fragment = Memory(content: "合成碎片：云桥城地图带尺", category: "fact", profileId: pid)
        fragment.occurredDay = "2026-11-01"
        fragment.reviewedAt = Date()
        h.context.insert(fragment)
        try h.context.save()
        ToolDrawerStore.shared.update { state in state.set(.off, for: RecallTool.toolName, profileId: nil) }

        var bodies: [[String: Any]] = []
        RequestBodyTap.handler = { bodies.append($0) }
        _ = try send(h)
        await h.waitForTurn()
        RequestBodyTap.handler = nil
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        let delivery = try XCTUnwrap(assistant.recallReceipt?.delivery)
        XCTAssertTrue(delivery.items.contains { $0.kind == RecallDeliveryItem.Kind.fragment && !$0.shown.isEmpty },
                      "目录碎片照记")
        let body = try XCTUnwrap(bodies.last)
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            .replacingOccurrences(of: "\\n", with: "\n")
        XCTAssertFalse(wire.contains("想看完整内容用 recall 工具查"), "没下发 recall：指路句删掉")
        XCTAssertTrue(wire.contains("合成碎片：云桥城地图带尺"), "碎片本体照发")
    }

    /// P2-a/b：触发关走 legacy 碎片注入，单位文本与 `tryAppend` 一字不差才能核到 wire 上
    func testTriggerOffLegacyFragmentsInDelivery() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let pid = h.profile.id
        var tuning = RecallTestTuning.make()
        tuning.archiveTriggerEnabled = false
        RecallTuningStore.save(tuning, profileId: pid)
        let fragment = Memory(content: "合成碎片：云桥城地图带尺", category: "fact", profileId: pid)
        fragment.occurredDay = "2026-11-01"
        fragment.reviewedAt = Date()
        h.context.insert(fragment)
        for node in h.viewModel.currentPath { node.recallReceipt = nil }
        try h.context.save()

        var bodies: [[String: Any]] = []
        RequestBodyTap.handler = { bodies.append($0) }
        _ = try send(h)
        await h.waitForTurn()
        RequestBodyTap.handler = nil
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        let delivery = try XCTUnwrap(assistant.recallReceipt?.delivery)
        XCTAssertTrue(delivery.gate.triggerOff)
        let legacy = delivery.items.filter { $0.kind == RecallDeliveryItem.Kind.legacyFragment }
        XCTAssertEqual(legacy.count, 1, "legacy 碎片一条")
        XCTAssertTrue(legacy.first?.shown.contains("合成碎片：云桥城地图带尺") ?? false)
        XCTAssertTrue(delivery.items.allSatisfy { $0.kind == RecallDeliveryItem.Kind.legacyFragment },
                      "触发关没有 X 项")
        let body = try XCTUnwrap(bodies.last)
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            .replacingOccurrences(of: "\\n", with: "\n")
        XCTAssertTrue(wire.contains("- 合成碎片：云桥城地图带尺 [事实]"), "wire 上是 tryAppend 那一行")
    }

    /// P2-b：CC 路由回执 route = ccBridge、清单空，gate 照记
    func testCCReceiptRouteCCWithEmptyItems() async throws {
        let h = try await make(baseURL: "http://127.0.0.1:9")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let user = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        let composed = h.viewModel.composePrompt(profile: h.profile, preset: h.preset, excludingNodeId: assistant.id,
                                                 context: h.context, globalEntries: [], fileLibraryHint: nil, mode: .send,
                                                 cardGuide: (.none, nil), conversation: conversation, providerType: .ccBridge)
        XCTAssertEqual(composed.delivery.route, "ccBridge")
        XCTAssertTrue(composed.delivery.items.isEmpty)
        XCTAssertTrue(composed.delivery.gate.participates)
        let receipt = try XCTUnwrap(assistant.recallReceipt)
        XCTAssertEqual(receipt.delivery, composed.delivery, "assistant 回执 = compose 算出的那份")
        XCTAssertEqual(user.recallReceipt?.delivery, composed.delivery)
        XCTAssertNil(receipt.injectionRecord, "CC 仍不记注入")
    }

    /// P2-b：工具续轮 / HTTP 重试各一个新 attempt，delivery id 与这一轮的重算不一致就是算错了
    func testToolContinuationAndRetryShareDeliveryId() async throws {
        let server = try scripted { index, _ in
            switch index {
            case 0: .init(status: 200, contentType: "text/event-stream", body: Self.toolTurn)
            case 1: .init(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.okText)
            case 2: .init(status: 503, contentType: "application/json", body: ChatRetryRouterTests.unavailable503)
            default: .init(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.okText)
            }
        }
        let h = try await make(baseURL: server.baseURL, tools: true)
        _ = try send(h)
        await h.waitForTurn()
        let first = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt)
        let firstDelivery = try XCTUnwrap(first.delivery)
        XCTAssertEqual(first.attempts.count, 2, "工具续轮两个 attempt")
        XCTAssertEqual(first.attempts.compactMap(\.deliveryId), [firstDelivery.id, firstDelivery.id],
                       "续轮沿用同一份 delivery")
        XCTAssertEqual(server.requestBodies.count, 2)

        _ = try send(h)
        await h.waitForTurn()
        let retried = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt)
        let retryDelivery = try XCTUnwrap(retried.delivery)
        XCTAssertEqual(retried.attempts.count, 2, "503 重试两个 attempt")
        XCTAssertEqual(retried.attempts.first?.status, .failed)
        XCTAssertEqual(retried.attempts.compactMap(\.deliveryId), [retryDelivery.id, retryDelivery.id],
                       "重试不重算 delivery")
        XCTAssertEqual(server.requestBodies.count, 4)
    }

    // MARK: - P3-a：账归属（plan-memory-receipt §2.2 / §2.5）

    /// `/trigger` 的新回复从空账开始：只继承「上一版已生效」，不再回落 user 回执带出上条 attempts / reads
    func testTriggerReplyDoesNotInheritPreviousReadsOrAttempts() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let user = try send(h)
        await h.waitForTurn()
        let firstReply = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        var carried = try XCTUnwrap(firstReply.recallReceipt)
        carried.reads.append(.init(toolCallId: "fictional-trigger-read", turnId: user.id, layer: "original", target: "林栖"))
        firstReply.recallReceipt = carried
        let firstAttempts = carried.attempts.count
        let firstMeter = try XCTUnwrap(MemoryInjectionMeter.load(profileId: h.profile.id), "首个有效响应写 Meter")
        XCTAssertEqual(firstMeter, carried.injectionRecord, "Meter = 首条回复的注入快照")
        let userDecision = try XCTUnwrap(user.recallReceipt?.decision)
        XCTAssertTrue(h.viewModel.triggerReply(model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await h.waitForTurn()
        let reply = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertNotEqual(reply.id, firstReply.id)
        let receipt = try XCTUnwrap(reply.recallReceipt)
        XCTAssertEqual(receipt.inheritedEffective, true, "上一版已生效：新回复只继承这一格")
        XCTAssertEqual(receipt.attempts.count, 1, "新回复只有自己的 attempt")
        XCTAssertEqual(receipt.decision.origin, .continuation, "同一真实轮：候选取回")
        XCTAssertEqual(receipt.reads, [], "不继承上一条的读账")
        XCTAssertEqual(firstReply.recallReceipt?.attempts.count, firstAttempts)
        XCTAssertEqual(firstReply.recallReceipt?.reads.count, 1)
        XCTAssertEqual(user.recallReceipt?.decision, userDecision, "/trigger 不动 user 的 decision")
        XCTAssertEqual(user.recallReceipt?.attempts.count, 0)
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: h.profile.id), firstMeter,
                       "/trigger 的 inherited 不重写 Meter（at 变了也算重写）")
    }

    /// 贴表情走 `/trigger` 同一条管线：新回复同样从空账开始
    func testReactionReplyStartsEmptyLedger() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.mode = .bubble
        let user = try send(h)
        await h.waitForTurn()
        let firstReply = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        var carried = try XCTUnwrap(firstReply.recallReceipt)
        carried.reads.append(.init(toolCallId: "fictional-reaction-read", turnId: user.id, layer: "original", target: "林栖"))
        firstReply.recallReceipt = carried
        let suite = "xctest-reaction-\(UUID().uuidString)"
        let outbox = ChatCardEventOutbox(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), key: "reaction-events")
        h.viewModel.cardEventOutbox = outbox
        outbox.add("回了 🍆", conversationId: conversation.id, key: "reaction:\(firstReply.id):🍆")
        XCTAssertEqual(h.viewModel.triggerReactionReply(model: h.model, profile: h.profile, preset: h.preset,
                                                        providerManager: h.providerManager, context: h.context), .sent)
        await h.waitForTurn()
        let reply = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        let receipt = try XCTUnwrap(reply.recallReceipt)
        XCTAssertEqual(receipt.inheritedEffective, true)
        XCTAssertEqual(receipt.attempts.count, 1, "贴表情的新回复只记自己的 attempt")
        XCTAssertEqual(receipt.reads, [], "不继承上一条的读账")
        XCTAssertEqual(user.recallReceipt?.attempts.count, 0)
        XCTAssertFalse(reply.cardEvents.isEmpty, "事件挂在新回复节点上")
    }

    /// 重生成继承「已生效」：不再推进轮次，也不再打最后聊戳
    func testRegenerateDoesNotRestampLastRealChatAt() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        _ = try send(h)
        await h.waitForTurn()
        let stamp = try XCTUnwrap(conversation.lastRealChatAt, "真实一轮响应后打戳")
        let turn = conversation.recallState.effectiveTurn
        let firstReply = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        let firstMeter = try XCTUnwrap(MemoryInjectionMeter.load(profileId: h.profile.id), "首个有效响应写 Meter")
        XCTAssertEqual(firstMeter, firstReply.recallReceipt?.injectionRecord)
        h.viewModel.regenerate(assistantNodeId: firstReply.id, model: h.model, profile: h.profile,
                               preset: h.preset, providerManager: h.providerManager, context: h.context)
        await h.waitForTurn()
        XCTAssertEqual(conversation.lastRealChatAt, stamp, "重生成不算又一次真实聊天")
        XCTAssertEqual(conversation.recallState.effectiveTurn, turn, "同一轮不重复推进")
        let reply = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertEqual(reply.recallReceipt?.inheritedEffective, true)
        XCTAssertEqual(reply.recallReceipt?.attempts.count, 1)
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: h.profile.id), firstMeter,
                       "重生成的 inherited 不重写 Meter（at 变了也算重写）")
    }

    /// §2.5 唯一行为差：user 回执不再镜像 → 路径上 assistant 没回执（legacy 兄弟）时，
    /// disabled 轮会真的按 RTS :368-370 清掉继承上下文，而不是像以前那样整条被排除（P3 r2 / Opus M2：走真实 send）
    func testDisabledTurnOnLegacySiblingClearsActiveOnRecover() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        try await h.seedWiki([WikiPage(path: "人/林栖", hook: "云桥城的朋友", title: "林栖", now: "合成地图计划")])
        _ = try send(h)
        await h.waitForTurn()
        let firstReply = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        let firstTurn = try XCTUnwrap(firstReply.recallReceipt)
        XCTAssertTrue(firstTurn.hasEffectiveResponse)
        XCTAssertFalse(firstTurn.decision.selected.isEmpty, "第一个真实轮带上了页")
        var tuning = RecallTestTuning.make()
        tuning.archiveTriggerEnabled = false
        RecallTuningStore.save(tuning, profileId: h.profile.id)
        let disabledUser = try send(h)
        await h.waitForTurn()
        let disabledReply = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        disabledReply.recallReceiptData = nil   // 模拟 P3 之前写下的 legacy 兄弟：只有 user 上有 decision
        try h.context.save()
        let legacy = try XCTUnwrap(disabledUser.recallReceipt)
        XCTAssertEqual(legacy.decision.gateReason, .disabled)
        XCTAssertEqual(legacy, RecallTurnReceipt(decision: legacy.decision),
                       "user 回执整份只剩 decision，不再镜像 attempts / reads / delivery")
        XCTAssertFalse(legacy.hasEffectiveResponse)

        // 第三轮走真实 send：compose 经 recallPathReceipts 把 [首轮已生效, disabled user 回执] 交给 recover
        RecallTuningStore.save(RecallTestTuning.make(), profileId: h.profile.id)
        var atRequest: RecallConversationState?
        RequestBodyTap.handler = { _ in atRequest = conversation.recallState }
        _ = try send(h)
        await h.waitForTurn()
        let recovered = try XCTUnwrap(atRequest)
        XCTAssertTrue(recovered.active.isEmpty,
                      "disabled 轮清掉继承的 active（旧行为：user 镜像有效 → 整条被排除，active 留着）")
        XCTAssertTrue(recovered.pending.isEmpty)
        XCTAssertEqual(recovered.topicAnchor, "")
        XCTAssertEqual(recovered.effectiveTurn, 1, "disabled 轮不计轮")
        XCTAssertNotEqual(recovered.lastAppliedTurnId, disabledUser.id, "未生效的 disabled 轮不打戳")
    }

    /// P3 r2（Opus M2）：上一条的包语义版——直接给 `RecallTurnState.recover` 喂 receipts，不经 VM 组装。
    /// 钉住 RTS disabled 分支的清除行为与「未生效不打戳」，与 VM 读者那一格分开。
    func testDisabledUserReceiptPackageSemanticsClearActive() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        try await h.seedWiki([WikiPage(path: "人/林栖", hook: "云桥城的朋友", title: "林栖", now: "合成地图计划")])
        _ = try send(h)
        await h.waitForTurn()
        let firstTurn = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt)
        XCTAssertTrue(firstTurn.hasEffectiveResponse)
        var tuning = RecallTestTuning.make()
        tuning.archiveTriggerEnabled = false
        RecallTuningStore.save(tuning, profileId: h.profile.id)
        let disabledUser = try send(h)
        await h.waitForTurn()
        let disabledReply = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        disabledReply.recallReceiptData = nil
        try h.context.save()
        let legacy = try XCTUnwrap(disabledUser.recallReceipt)
        let anchor = disabledUser.id
        let recovered = RecallTurnState.recover(receipts: [firstTurn, legacy],
                                                branchAnchor: conversation.recallState.branchAnchor, clearActive: false)
        XCTAssertTrue(recovered.active.isEmpty, "disabled 轮清掉继承的 active")
        XCTAssertTrue(recovered.pending.isEmpty)
        XCTAssertEqual(recovered.topicAnchor, "")
        XCTAssertEqual(recovered.effectiveTurn, 1, "disabled 轮不计轮")
        XCTAssertNotEqual(recovered.lastAppliedTurnId, anchor, "未生效的 disabled 轮不打戳")
    }

    // MARK: - P3-b：Meter 是回执投影

    /// 组装不再写 Meter；首事件前取消的一轮永远不写
    func testFailedBeforeFirstEventWritesNoMeter() async throws {
        let server = try held()
        let h = try await make(baseURL: server.baseURL)
        let pid = h.profile.id
        MemoryInjectionMeter.clear(profileId: pid)
        _ = try send(h)
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        try await waitUntil("Wait for a submitted request without provider content") {
            server.hasRequest && assistant.recallReceipt?.attempts.last?.status == .submitted
        }
        XCTAssertNotNil(assistant.recallReceipt?.injectionRecord, "组装照常把这一轮的注入快照存在回执上")
        XCTAssertNil(MemoryInjectionMeter.load(profileId: pid), "没有有效响应不写 Meter")
        h.viewModel.cancelAssistantTurn(context: h.context, drainQueued: false)
        XCTAssertNil(MemoryInjectionMeter.load(profileId: pid), "首事件前取消也不写")
    }

    /// 默认路径（触发关）不再漏记本轮碎片：Meter 的 hitCount 来自 delivery 的 legacy 碎片
    func testMeterCountsLegacyFragmentsWhenTriggerOff() async throws {
        let server = try scripted { _, _ in .init(status: 200, contentType: "text/event-stream", body: Self.textChunk) }
        let h = try await make(baseURL: server.baseURL)
        let pid = h.profile.id
        var tuning = RecallTestTuning.make()
        tuning.archiveTriggerEnabled = false
        RecallTuningStore.save(tuning, profileId: pid)
        let fragment = Memory(content: "合成碎片：云桥城地图带尺", category: "fact", profileId: pid)
        fragment.occurredDay = "2026-11-01"
        fragment.reviewedAt = Date()
        h.context.insert(fragment)
        try h.context.save()
        MemoryInjectionMeter.clear(profileId: pid)
        _ = try send(h)
        await h.waitForTurn()
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        let receipt = try XCTUnwrap(assistant.recallReceipt)
        let delivery = try XCTUnwrap(receipt.delivery)
        XCTAssertTrue(delivery.gate.triggerOff)
        XCTAssertFalse(delivery.items.isEmpty, "触发关这一轮带了碎片")
        XCTAssertTrue(delivery.items.allSatisfy { $0.kind == RecallDeliveryItem.Kind.legacyFragment })
        XCTAssertEqual(receipt.injectionRecord?.hitCount, delivery.items.count, "触发关也要数本轮碎片")
        XCTAssertEqual(receipt.injectionRecord?.conversationId, h.viewModel.selectedConversation?.id)
        XCTAssertEqual(receipt.injectionRecord, MemoryInjectionMeter.load(profileId: pid), "响应后 Meter = 回执快照")
    }

    private func conversationTurn(_ h: PromptRealPathHarness) -> Int {
        h.viewModel.selectedConversation?.recallState.effectiveTurn ?? -1
    }
}

/// The shared scripted server deliberately closes after its one body. These lifecycle tests
/// need an open stream whose first event can be released only after the VM has submitted.
private final class HeldStreamServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "RecallRealPathTests.HeldStreamServer")
    private let lock = NSLock()
    private var requested = false
    private var connection: NWConnection?

    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    var baseURL: String { "http://127.0.0.1:\(listener.port!.rawValue)/v1" }
    var hasRequest: Bool { lock.withLock { requested } }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connection = connection }
            connection.start(queue: self.queue)
            self.receive(on: connection, accumulated: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success else { throw URLError(.timedOut) }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connection }?.cancel()
    }

    func release(_ body: Data) {
        queue.async { [self] in
            guard let connection = lock.withLock({ self.connection }) else { return }
            // Pass URLSession's small-body sniff buffer without introducing an effective event.
            var payload = Data((": " + String(repeating: "x", count: 2048) + "\n\n").utf8)
            payload.append(body)
            connection.send(content: payload, completion: .contentProcessed { _ in })
        }
    }

    func finish() {
        queue.async { [self] in
            guard let connection = lock.withLock({ self.connection }) else { return }
            connection.send(content: Data("data: [DONE]\n\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            if let headersEnd = request.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: request[..<headersEnd.lowerBound], as: UTF8.self)
                let length = headers.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if request.distance(from: headersEnd.upperBound, to: request.endIndex) >= length {
                    connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8),
                                    completion: .contentProcessed { _ in })
                    self.lock.withLock { self.requested = true }
                    return
                }
            }
            if error != nil || complete { connection.cancel() }
            else { self.receive(on: connection, accumulated: request) }
        }
    }
}
