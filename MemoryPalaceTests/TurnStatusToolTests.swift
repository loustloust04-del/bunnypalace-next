import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class TurnStatusToolTests: XCTestCase {
    func testSanitizesNewlinesAndLimitsWholeCharacters() throws {
        let emoji = "👩🏽‍💻"
        let text = "  拉\r\n磨\u{2028}中" + String(repeating: emoji, count: 21)
        let json = String(decoding: try JSONEncoder().encode(["status": text]), as: UTF8.self)
        XCTAssertEqual(TurnStatusTool.text(from: json), "拉 磨 中" + String(repeating: emoji, count: 15))
        for invalid in ["{}", "[]", #"{"status":7}"#, #"{"status":" \n\t"}"#, "not-json"] {
            XCTAssertNil(TurnStatusTool.text(from: invalid))
        }
    }

    func testOnlyMasterAndModelGateStatusTool() async throws {
        try await withHarness { h, model in
            h.overrideDefault(PermissionDomain.fileLibrary.storageKey, PermissionLevel.notAllowed.rawValue)
            var drawer = ToolDrawerState.defaults
            drawer.set(.off, for: TurnStatusTool.toolName, profileId: nil)
            let gate = ToolGateContext(family: .openAI, deferMCP: false, drawer: drawer)
            XCTAssertEqual(ToolRegistry.availability(of: TurnStatusTool.toolName, gate), true)
            XCTAssertTrue(ToolRegistry.inlineDefinitions(gate).contains { $0.name == TurnStatusTool.toolName })
            XCTAssertFalse(try XCTUnwrap(ToolDrawerCatalog.item(named: TurnStatusTool.toolName)).canToggle)
            let offered = h.viewModel.toolInjection(for: model, providerManager: h.providerManager,
                                                   conversation: h.viewModel.selectedConversation, profileId: h.profile.id, silent: true)
            XCTAssertTrue(offered.offered?.contains(TurnStatusTool.toolName) == true)
            for type in [ProviderType.ccBridge, .localMLX] {
                let other = h.addCard(type: type, modelId: "unsupported-turn-status")
                let result = h.viewModel.toolInjection(for: other, providerManager: h.providerManager,
                                                      conversation: h.viewModel.selectedConversation, profileId: h.profile.id, silent: true)
                XCTAssertNil(result.tools)
                XCTAssertFalse(result.systemHint.contains(TurnStatusTool.toolName))
            }
            h.overrideDefault(PermissionDomain.toolsMaster.storageKey, PermissionLevel.notAllowed.rawValue)
            XCTAssertEqual(ToolRegistry.availability(of: TurnStatusTool.toolName, gate), false)
            XCTAssertNil(h.viewModel.toolInjection(for: model, providerManager: h.providerManager,
                                                  conversation: h.viewModel.selectedConversation, profileId: h.profile.id, silent: true).tools)
        }
        let h = try await PromptRealPathHarness.make(.init(name: "status-card-off", memoryEnabled: false,
                                                          cardToolsSupported: false, voiceHint: false, memoryFixtures: false))
        XCTAssertNil(h.viewModel.toolInjection(for: h.model, providerManager: h.providerManager,
                                              conversation: h.viewModel.selectedConversation, profileId: h.profile.id, silent: true).tools)
        await h.tearDown()
    }

    func testStatusLivesOnlyInItsTurnAndNeverUpdatesProfileCard() async throws {
        let replies = try (0...3).map { try TurnStatusStreamFixture.reply("在烤\n量子曲奇\($0)") }
        let final = TurnStatusStreamFixture.finalReply
        let server = try ScriptedHTTPServer { index, _ in
            guard replies.indices.contains(index) else {
                return (500, "text/plain", Data("Unexpected turn-status request".utf8))
            }
            return (200, "text/event-stream", index == 1 ? final : replies[index])
        }
        try server.start()
        defer { server.stop() }
        try await withHarness(server: server) { h, model in
            let vm = h.viewModel
            let conversation = try XCTUnwrap(vm.selectedConversation)
            h.overrideDefault(PermissionDomain.fileLibrary.storageKey, PermissionLevel.notAllowed.rawValue)
            let cardURL = FileLibraryStore.memoryRoot(profileId: h.profile.id).appendingPathComponent("profile-card.md")
            let cardBefore = try? Data(contentsOf: cardURL)
            try await self.sendAndWaitForQuestion(h, model: model)
            let firstTurn = try XCTUnwrap(vm.currentTurnID)
            XCTAssertEqual(vm.turnStatus(for: conversation.id), "在烤 量子曲奇0")
            XCTAssertNil(PermissionPromptCenter.shared.pendingRequest, "临时状态不能触发文件库审批")
            XCTAssertEqual(try? Data(contentsOf: cardURL), cardBefore)
            let firstNode = try XCTUnwrap(vm.currentTurnNode(for: conversation.id)).id
            vm.resumeUserQuestion()
            XCTAssertEqual(vm.currentTurnID, firstTurn, "问问题续答仍是同一轮，不依赖assistant节点id")
            XCTAssertNotEqual(vm.currentTurnNode(for: conversation.id)?.id, firstNode)
            try await self.waitUntil { !vm.assistantTurnInFlight }
            XCTAssertNil(vm.turnStatus(for: conversation.id))
            XCTAssertNil(vm.currentTurnID)
            XCTAssertEqual(server.requestBodies.count, 2, "首轮及问问题续答各发一次，不应混入后台请求")
            let secondRequestIndex = server.requestBodies.count

            try await self.sendAndWaitForQuestion(h, model: model)
            XCTAssertNotEqual(vm.currentTurnID, firstTurn)
            XCTAssertEqual(vm.turnStatus(for: conversation.id), "在烤 量子曲奇2")
            XCTAssertEqual(server.requestBodies.count, secondRequestIndex + 1)
            let other = Conversation(id: UUID().uuidString, title: "另一条合成对话", createTime: Date(),
                                     updateTime: Date(), currentNodeId: "", profileId: h.profile.id)
            h.context.insert(other)
            vm.selectedConversation = other
            XCTAssertNil(vm.turnStatus(for: other.id))
            XCTAssertNil(vm.turnStatus(for: conversation.id))
            vm.selectedConversation = conversation
            XCTAssertNil(vm.turnStatus(for: conversation.id), "切回不能复活已清理的短句")
            vm.cancelAssistantTurn(context: h.context)
            XCTAssertNil(vm.turnStatus(for: conversation.id))

            try await self.sendAndWaitForQuestion(h, model: model)
            XCTAssertEqual(vm.turnStatus(for: conversation.id), "在烤 量子曲奇3")
            NotificationCenter.default.post(name: .profileWillSwitch, object: nil)
            XCTAssertNil(vm.turnStatus(for: conversation.id))
            XCTAssertNil(vm.currentTurnID)
            XCTAssertTrue(vm.turnActivities.isEmpty)
            vm.selectedConversation = conversation
            XCTAssertEqual(try? Data(contentsOf: cardURL), cardBefore)

            let bodies = server.requestBodies
            XCTAssertEqual(bodies.count, 4)
            let first = try JSONDecoder().decode(Request.self, from: bodies[0])
            let second = try JSONDecoder().decode(Request.self, from: bodies[secondRequestIndex])
            XCTAssertEqual(first.stream, true)
            XCTAssertEqual(second.stream, true)
            XCTAssertEqual(try self.toolDefinitions(in: bodies[0]), try self.toolDefinitions(in: bodies[secondRequestIndex]),
                           "状态内容不能改变下一轮工具定义（含完整参数 schema）")
            XCTAssertFalse(second.messages.filter { $0.role == "system" }.contains { $0.content?.contains("量子曲奇") == true },
                           "临时状态不能污染提示词前缀")
        }
    }

    func testStopAndFailedContinuationClearStatus() async throws {
        let reply = try TurnStatusStreamFixture.reply("在等口味")
        let failure = Data(#"{"error":{"message":"synthetic terminal failure","type":"invalid_request_error"}}"#.utf8)
        let server = try ScriptedHTTPServer { index, _ in
            index < 2 ? (200, "text/event-stream", reply) : (400, "application/json", failure)
        }
        try server.start()
        defer { server.stop() }
        try await withHarness(server: server) { h, model in
            let vm = h.viewModel
            let cid = try XCTUnwrap(vm.selectedConversation?.id)
            let cardURL = FileLibraryStore.memoryRoot(profileId: h.profile.id).appendingPathComponent("profile-card.md")
            let cardBefore = try? Data(contentsOf: cardURL)
            try await self.sendAndWaitForQuestion(h, model: model)
            let stoppedTurn = try XCTUnwrap(vm.currentTurnID)
            XCTAssertEqual(vm.turnStatus(for: cid), "在等口味")
            vm.cancelAssistantTurn(context: h.context)
            XCTAssertNil(vm.turnStatus(for: cid))
            XCTAssertNil(vm.currentTurnID)
            XCTAssertNil(vm.pendingUserQuestion)

            try await self.sendAndWaitForQuestion(h, model: model)
            XCTAssertNotEqual(vm.currentTurnID, stoppedTurn)
            XCTAssertEqual(vm.turnStatus(for: cid), "在等口味")
            vm.resumeUserQuestion()
            try await self.waitUntil { !vm.assistantTurnInFlight }
            XCTAssertNil(vm.turnStatus(for: cid))
            XCTAssertNil(vm.currentTurnID)
            XCTAssertNil(vm.pendingUserQuestion)
            XCTAssertTrue(vm.currentPath.last?.content.contains("synthetic terminal failure") == true,
                          "必须由真实 HTTP 错误收口，不能把普通完成误当失败")
            XCTAssertEqual(server.requestBodies.count, 3)
            XCTAssertEqual(try? Data(contentsOf: cardURL), cardBefore)
        }
    }

    func testLateCancelledStreamCannotWriteNewTurnStatus() async throws {
        let old = try TurnStatusStreamFixture.reply("过期短句")
        let current = try TurnStatusStreamFixture.reply("新一轮在营业")
        let releaseOld = DispatchSemaphore(value: 0)
        let server = try ScriptedHTTPServer { index, _ in
            if index == 0 { _ = releaseOld.wait(timeout: .now() + 5) }
            return (200, "text/event-stream", index == 0 ? old : current)
        }
        try server.start()
        defer { releaseOld.signal(); server.stop() }
        try await withHarness(server: server) { h, model in
            let vm = h.viewModel
            let cid = try XCTUnwrap(vm.selectedConversation?.id)
            XCTAssertTrue(vm.sendMessage("旧一轮", model: model, profile: h.profile, preset: h.preset,
                                         providerManager: h.providerManager, context: h.context))
            try await self.waitUntil { server.requestBodies.count == 1 }
            let oldTurn = vm.currentTurnID
            vm.cancelAssistantTurn(context: h.context)
            XCTAssertNil(vm.turnStatus(for: cid))
            XCTAssertTrue(vm.sendMessage("新一轮", model: model, profile: h.profile, preset: h.preset,
                                         providerManager: h.providerManager, context: h.context))
            releaseOld.signal()
            try await self.waitUntil { vm.pendingUserQuestion != nil }
            XCTAssertNotEqual(vm.currentTurnID, oldTurn)
            XCTAssertEqual(vm.turnStatus(for: cid), "新一轮在营业")
            XCTAssertFalse(vm.turnActivity(for: cid)?.steps.contains { $0.detail.inputJSON.contains("过期短句") } == true)
        }
    }

    func testPendingActionSurvivesOldCleanupAndRetainsToolDetails() {
        var activity = TurnActivity(maxRounds: 8)
        activity.startRound(1, thinking: "先确认需要查什么")
        activity.startTool(.init(id: "old", name: "mcp_search", argumentsJSON: "{}"))
        activity.startTool(.init(id: "new", name: "fs_read", argumentsJSON: #"{"path":"notes.txt"}"#))
        activity.finishTool("old")
        XCTAssertEqual(activity.pendingTool?.id, "new")
        XCTAssertTrue(activity.pendingAction?.contains("notes.txt") == true)
        activity.observe(.toolUse(id: "new", name: "fs_read", inputJSON: #"{"path":"notes.txt"}"#, integrationName: "文件库", iconName: nil))
        activity.observe(.toolResult(toolUseId: "new", text: "合成文件正文", isError: false, integrationName: "文件库"))
        activity.finishTool("new")
        XCTAssertNil(activity.pendingTool)
        XCTAssertEqual(activity.steps.first?.detail.result, "合成文件正文")
        XCTAssertEqual(activity.thoughts, ["先确认需要查什么"])
    }

    private func sendAndWaitForQuestion(_ h: PromptRealPathHarness, model: ProviderModel) async throws {
        XCTAssertTrue(h.viewModel.sendMessage("帮我选一种饼干", model: model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        try await waitUntil { h.viewModel.pendingUserQuestion != nil }
    }

    private func withHarness(server: ScriptedHTTPServer? = nil,
                             run: (PromptRealPathHarness, ProviderModel) async throws -> Void) async throws {
        let h = try await PromptRealPathHarness.make(.init(name: "turn-status", memoryEnabled: false,
                                                          voiceHint: false, memoryFixtures: false))
        // 共用夹具有历史图片；关闭并由 tearDown 还原转写，避免续答完成后额外发无 tools 的后台请求。
        h.overrideDefault("imageTranscriptionEnabled", false)
        var model = h.model
        var extraCredential: String?
        if let server {
            let id = "xctest-turn-status-\(UUID().uuidString)"
            model = ProviderModel(credentialId: id, modelId: "gpt-4o", name: "Turn Status Test")
            h.providerManager.addCredential(APICredential(id: id, name: "Turn Status Test", emoji: "",
                                                          type: .openaiCompatible, baseURL: server.baseURL, models: [model]))
            h.providerManager.setApiKey("test-key", for: id)
            h.viewModel.selectedConversation?.selectedModelId = model.id
            extraCredential = id
        }
        defer { if let extraCredential { h.providerManager.removeCredential(id: extraCredential) } }
        do {
            try await run(h, model)
            h.viewModel.cancelAssistantTurn(context: h.context)
            await h.tearDown()
        } catch {
            h.viewModel.cancelAssistantTurn(context: h.context)
            await h.tearDown()
            throw error
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("真实工具循环未到达预期状态")
        throw URLError(.timedOut)
    }

    private func toolDefinitions(in body: Data) throws -> Data {
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try XCTUnwrap(request["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == TurnStatusTool.toolName })
        return try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])
    }
    private struct Request: Decodable {
        let stream: Bool?
        let messages: [Message]
        struct Message: Decodable {
            let role: String
            let content: String?
            private enum CodingKeys: String, CodingKey { case role, content }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                role = try container.decode(String.self, forKey: .role)
                content = role == "system" ? try container.decodeIfPresent(String.self, forKey: .content) : nil
            }
        }
    }
}
