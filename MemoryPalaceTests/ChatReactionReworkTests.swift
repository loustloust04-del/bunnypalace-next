import XCTest
import SwiftData
@testable import 记忆花园

/// 10-29 贴表情返工（审查 10 条）：取消 / 切分支 / 切对话 / 撤销 / 重新生成 / 收口顺序 / 严格 fence / 截断 / 开头匹配
@MainActor
final class ChatReactionReworkTests: XCTestCase {

    // MARK: #1 发送准备被取消：事件还回箱里

    func testCancelledPreparationReturnsEventsOnce() async throws {
        try await withHarness(server: nil) { h, model, outbox, store in
            let vm = h.viewModel
            let a2 = try XCTUnwrap(vm.currentPath.last)
            let cid = a2.conversationId
            store.toggle("❤️", on: ChatReactionTarget(node: a2), outbox: outbox, trigger: nil)
            let original = try XCTUnwrap(outbox.events(for: cid).first)
            XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, context: h.context), .sent)
            XCTAssertTrue(outbox.events(for: cid).isEmpty)
            vm.cancelAssistantTurn(context: h.context)   // 准备还没跑完就停
            XCTAssertEqual(vm.currentPath.last?.id, a2.id, "占位节点删掉")
            XCTAssertTrue(a2.childrenIds.isEmpty)
            let back = outbox.events(for: cid)
            XCTAssertEqual(back.map(\.id), [original.id], "原样还回、只还一次")
            XCTAssertEqual(back.first?.carried, true)
            XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, context: h.context), .nothingPending,
                           "还回来的只跟下一条走，不再单独触发")
        }
    }

    // MARK: #2 生成中切分支

    func testBranchSwitchDuringTurnTargetsReplyAncestorsAndKeepsSelection() async throws {
        let gate = DispatchSemaphore(value: 0)
        let server = try ScriptedHTTPServer { _, _ in
            _ = gate.wait(timeout: .now() + 20)
            return (200, "text/event-stream", Self.sse("```react\n👍\n```"))
        }
        try server.start()
        defer { server.stop(); gate.signal() }
        try await withHarness(server: server) { h, model, outbox, store in
            let vm = h.viewModel
            let conversation = try XCTUnwrap(vm.selectedConversation)
            let a2 = try XCTUnwrap(vm.currentPath.last)
            let u2 = try XCTUnwrap(vm.currentPath.dropLast().last)
            let a1 = try XCTUnwrap(vm.currentPath.first { $0.role == "assistant" })
            let sibling = MessageNode(id: "branch-\(UUID().uuidString)", role: "user", content: "另一条分支", contentType: "text",
                                      createTime: Date(), parentId: a1.id, childrenIds: [], conversationId: conversation.id,
                                      profileId: conversation.profileId)
            h.context.insert(sibling)
            a1.childrenIds.append(sibling.id)
            try h.context.save()
            try await reload(vm, conversation, h.context)
            XCTAssertEqual(vm.currentPath.last?.id, a2.id)

            store.toggle("❤️", on: ChatReactionTarget(node: a2), outbox: outbox, trigger: nil)
            XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, context: h.context), .sent)
            try await waitUntil { server.requestBodies.count == 1 }
            for index in 0..<2 where vm.currentPath.last?.id != sibling.id { vm.switchBranch(at: a1.id, to: index) }
            XCTAssertEqual(vm.currentPath.last?.id, sibling.id)
            gate.signal()
            try await waitUntil { !vm.assistantTurnInFlight }

            XCTAssertEqual(store.aiReactions(for: ChatReactionTarget(node: u2, blockIndex: 0, blockText: u2.content)), ["👍"],
                           "按回复自己的祖先链找，不贴到当前显示的分支上")
            XCTAssertTrue(store.aiReactions(for: ChatReactionTarget(node: sibling, blockIndex: 0, blockText: sibling.content)).isEmpty)
            XCTAssertTrue(a2.childrenIds.isEmpty, "空回复撤掉")
            XCTAssertEqual(vm.currentPath.last?.id, sibling.id, "撤的不是当前显示的末端：不动当前选择")
        }
    }

    // MARK: #3 生成中切到别的对话

    func testConversationSwitchDuringTurnSettlesOriginalTree() async throws {
        let gate = DispatchSemaphore(value: 0)
        let server = try ScriptedHTTPServer { _, _ in
            _ = gate.wait(timeout: .now() + 20)
            return (200, "text/event-stream", Self.sse("```react\n❤️\n```"))
        }
        try server.start()
        defer { server.stop(); gate.signal() }
        try await withHarness(server: server) { h, model, outbox, store in
            let vm = h.viewModel
            let original = try XCTUnwrap(vm.selectedConversation)
            let a2 = try XCTUnwrap(vm.currentPath.last)
            let u2 = try XCTUnwrap(vm.currentPath.dropLast().last)
            store.toggle("😂", on: ChatReactionTarget(node: a2), outbox: outbox, trigger: nil)
            XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, context: h.context), .sent)
            let replyId = try XCTUnwrap(vm.currentPath.last?.id)
            try await waitUntil { server.requestBodies.count == 1 }

            let other = Conversation(id: "other-\(UUID().uuidString)", title: "别的对话", createTime: Date(), updateTime: Date(),
                                     currentNodeId: "", provider: "api", profileId: original.profileId)
            let otherNode = MessageNode(id: "other-node-\(UUID().uuidString)", role: "user", content: "别的对话里的话",
                                        contentType: "text", createTime: Date(), parentId: nil, childrenIds: [],
                                        conversationId: other.id, profileId: original.profileId)
            other.currentNodeId = otherNode.id
            other.mode = .bubble
            h.context.insert(other)
            h.context.insert(otherNode)
            try h.context.save()
            try await reload(vm, other, h.context)
            gate.signal()
            try await waitUntil { !vm.assistantTurnInFlight }

            XCTAssertEqual(vm.selectedConversation?.id, other.id)
            XCTAssertEqual(vm.currentPath.map(\.id), [otherNode.id], "眼前这个对话的树没被动")
            var desc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == replyId })
            desc.fetchLimit = 1
            XCTAssertNil(try h.context.fetch(desc).first, "原对话里的空回复撤掉")
            XCTAssertTrue(a2.childrenIds.isEmpty)
            XCTAssertEqual(original.currentNodeId, a2.id)
            XCTAssertEqual(store.aiReactions(for: ChatReactionTarget(node: u2, blockIndex: 0, blockText: u2.content)), ["❤️"])
            XCTAssertEqual(outbox.events(for: original.id).map(\.text),
                           ["对你那条「回复二」回了 😂", "你给 ta 那条「第二条」回了 ❤️"])
            // 切回原对话再收尾：夹具 tearDown 按当前对话清附件，不切回会把 u1 的图留给后面的金样
            try await reload(vm, original, h.context)
        }
    }

    // MARK: #4 生成期间撤销

    func testUndoDuringSilentTurnIsNotOverwritten() async throws {
        let gate = DispatchSemaphore(value: 0)
        let server = try ScriptedHTTPServer { _, _ in
            _ = gate.wait(timeout: .now() + 20)
            return (200, "text/event-stream", Self.sse(""))
        }
        try server.start()
        defer { server.stop(); gate.signal() }
        try await withHarness(server: server) { h, model, outbox, store in
            let vm = h.viewModel
            let a2 = try XCTUnwrap(vm.currentPath.last)
            let target = ChatReactionTarget(node: a2)
            store.toggle("❤️", on: target, outbox: outbox, trigger: nil)
            XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, context: h.context), .sent)
            try await waitUntil { server.requestBodies.count == 1 }
            store.toggle("❤️", on: target, outbox: outbox, trigger: nil)   // 生成中撤掉
            gate.signal()
            try await waitUntil { !vm.assistantTurnInFlight }
            XCTAssertEqual(outbox.events(for: a2.conversationId).map(\.text), ["收回了对你那条「回复二」的 ❤️"],
                           "旧的「回了 ❤️」不能盖掉更新的撤销")
            XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, context: h.context), .nothingPending)
        }
    }

    func testUndoTimerDoesNotRetriggerRestoredReaction() async throws {
        let gate = DispatchSemaphore(value: 0)
        let server = try ScriptedHTTPServer { _, _ in
            _ = gate.wait(timeout: .now() + 20)
            return (200, "text/event-stream", Self.sse(""))
        }
        try server.start()
        defer { server.stop(); gate.signal() }
        try await withHarness(server: server) { h, model, outbox, store in
            let vm = h.viewModel
            let a2 = try XCTUnwrap(vm.currentPath.last)
            let target = ChatReactionTarget(node: a2)
            store.toggle("❤️", on: target, outbox: outbox, trigger: nil)
            XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, context: h.context), .sent)
            try await waitUntil { server.requestBodies.count == 1 }
            store.toggle("😂", on: target, outbox: outbox, trigger: nil)   // 生成中贴了又撤：箱子空、留下一个定时器
            store.toggle("😂", on: target, outbox: outbox, trigger: nil)
            XCTAssertTrue(outbox.events(for: a2.conversationId).isEmpty)
            gate.signal()
            try await waitUntil { !vm.assistantTurnInFlight }
            XCTAssertEqual(outbox.events(for: a2.conversationId).map(\.text), ["对你那条「回复二」回了 ❤️"])
            XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, context: h.context), .nothingPending,
                           "定时器到点不能把还回来的旧表情当新贴的再叫一次模型")
        }
    }

    func testRestoredReactionDroppedWhenNoLongerPresent() async throws {
        try await withHarness(server: nil) { h, model, outbox, store in
            let vm = h.viewModel
            let a2 = try XCTUnwrap(vm.currentPath.last)
            let cid = a2.conversationId
            let target = ChatReactionTarget(node: a2)
            store.toggle("❤️", on: target, outbox: outbox, trigger: nil)
            XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, context: h.context), .sent)
            store.toggle("❤️", on: target, outbox: outbox, trigger: nil)   // 撤掉，「收回了」又被别的消息带走
            _ = outbox.drain(cid)
            vm.cancelAssistantTurn(context: h.context)
            XCTAssertTrue(outbox.events(for: cid).isEmpty, "表情已经不在了：还回来的「回了 ❤️」核对后扔掉")
        }
    }

    // MARK: #5 重新生成静默

    func testSilentRegenerationDoesNotDuplicateEvents() async throws {
        let replies = [Self.sse("收到"), Self.sse("")]
        let server = try ScriptedHTTPServer { i, _ in (200, "text/event-stream", replies[min(i, 1)]) }
        try server.start()
        defer { server.stop() }
        try await withHarness(server: server) { h, model, outbox, store in
            let vm = h.viewModel
            let a2 = try XCTUnwrap(vm.currentPath.last)
            store.toggle("❤️", on: ChatReactionTarget(node: a2), outbox: outbox, trigger: nil)
            XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, context: h.context), .sent)
            try await waitUntil { !vm.assistantTurnInFlight }
            let first = try XCTUnwrap(vm.currentPath.last)
            XCTAssertEqual(first.content, "收到")
            vm.regenerate(assistantNodeId: first.id, model: model, profile: h.profile, preset: h.preset,
                          providerManager: h.providerManager, context: h.context)
            try await waitUntil { !vm.assistantTurnInFlight && server.requestBodies.count == 2 }
            let second = try XCTUnwrap(vm.currentPath.last)
            XCTAssertNotEqual(second.id, first.id)
            XCTAssertEqual(second.content, "（没有回复）", "父节点还有别的回复：保留这条分支")
            XCTAssertEqual(second.cardEvents.map(\.text), first.cardEvents.map(\.text), "重新生成复用历史里的事件")
            XCTAssertTrue(outbox.events(for: a2.conversationId).isEmpty, "没删掉承载事件的节点：一条都不入箱")
        }
    }

    // MARK: #6 先收口再存 / 再起旁路

    func testSilentTurnSettledBeforeNodeCountAndSave() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"想一想要不要回\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\"```react\\n❤️\\n```\"}}]}\n\ndata: [DONE]\n\n"
        let server = try ScriptedHTTPServer { _, _ in (200, "text/event-stream", Data(body.utf8)) }
        try server.start()
        defer { server.stop() }
        try await withHarness(server: server) { h, model, outbox, store in
            let vm = h.viewModel
            let conversation = try XCTUnwrap(vm.selectedConversation)
            let a2 = try XCTUnwrap(vm.currentPath.last)
            store.toggle("❤️", on: ChatReactionTarget(node: a2), outbox: outbox, trigger: nil)
            var finishedContent: [String] = []
            let token = NotificationCenter.default.addObserver(forName: .assistantTurnDidFinish, object: nil, queue: nil) { note in
                let id = note.userInfo?["nodeId"] as? String ?? ""
                MainActor.assumeIsolated { finishedContent.append(vm.currentPath.first { $0.id == id }?.content ?? "<gone>") }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, context: h.context), .sent)
            try await waitUntil { !vm.assistantTurnInFlight }
            XCTAssertEqual(vm.currentPath.last?.id, a2.id)
            let displayable = vm.currentPath.filter { ($0.role == "user" || $0.role == "assistant") && $0.hasDisplayableContent }.count
            XCTAssertEqual(conversation.nodeCount, displayable, "节点数在撤泡之后才算")
            XCTAssertEqual(finishedContent, ["<gone>"])
            // 另开一个 context 只看得到已存盘的：撤泡后的树已经落盘
            let fresh = ModelContext(h.context.container)
            let a2Id = a2.id
            let saved = try fresh.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == a2Id })).first
            XCTAssertEqual(saved?.childrenIds, [], "撤泡后的状态已经存盘")
        }
    }

    // MARK: #7 严格 fence

    func testOnlyStrictReactFencesAreConsumed() {
        let code = "示例：\n\n```reactjs\n❤️\n```\n\n```react-native\n👍\n```\n\n```react\nconst a = 1\n```\n\n```react ❤️\n```"
        XCTAssertEqual(ChatReactionIntent.parse(code), [])
        XCTAssertEqual(ChatReactionIntent.strip(code), code, "不合格的块原样留着")
        XCTAssertEqual(ChatReactionIntent.parse("```react\n❤️ 第二条\n```"), [.init(emoji: "❤️", hint: "第二条")])
        XCTAssertEqual(ChatReactionIntent.parse("```react\n❤️第二条\n```"), [], "emoji 后面要空一格")
        XCTAssertEqual(ChatReactionIntent.parse("```react\n❤️\n\n```"), [], "块里只能一行")

        let node = MessageNode(id: "n", role: "assistant", content: "```reactjs\n❤️\n```", contentType: "text", createTime: Date(),
                               parentId: nil, childrenIds: [], conversationId: "c", profileId: "p")
        XCTAssertEqual(ChatReactionIntent.consume(node), [])
        XCTAssertEqual(node.content, "```reactjs\n❤️\n```")
    }

    // MARK: #8 截断的块

    func testUnclosedTailIsHiddenWhileStreamingAndDroppedOnSettle() async throws {
        XCTAssertEqual(ChatReactionIntent.dropUnclosedTail("晚安\n```react\n❤"), "晚安")
        XCTAssertEqual(ChatReactionIntent.dropUnclosedTail("晚安\n```react"), "晚安")
        XCTAssertEqual(ChatReactionIntent.dropUnclosedTail("晚安\n```reactjs\nfoo"), "晚安\n```reactjs\nfoo")
        XCTAssertEqual(ChatReactionIntent.streamingVisible("好\n\n```react\n👍\n```\n\n还有"), "好\n\n还有")
        XCTAssertEqual(ChatReactionIntent.streamingVisible("好\n\n```react\n👍"), "好")

        let server = try ScriptedHTTPServer { _, _ in (200, "text/event-stream", Self.sse("晚安\n\n```react\n❤")) }
        try server.start()
        defer { server.stop() }
        try await withHarness(server: server) { h, model, outbox, store in
            let vm = h.viewModel
            XCTAssertTrue(vm.sendMessage("我去睡了", model: model, profile: h.profile, preset: h.preset,
                                         providerManager: h.providerManager, context: h.context))
            try await waitUntil { !vm.assistantTurnInFlight }
            let reply = try XCTUnwrap(vm.currentPath.last)
            let user = try XCTUnwrap(vm.currentPath.dropLast().last)
            XCTAssertEqual(reply.content, "晚安", "输出被截断：末尾没收尾的块丢掉")
            XCTAssertTrue(store.aiReactions(for: ChatReactionTarget(node: user, blockIndex: 0, blockText: user.content)).isEmpty)
        }
    }

    // MARK: #10 只按开头匹配

    func testHintMatchesMessageStartOnlyAndSkipsWhenNothingMatches() async throws {
        let replies = [Self.sse("记住了\n\n```react\n👍 第二\n```"), Self.sse("嗯\n\n```react\n❤️ 条\n```")]
        let server = try ScriptedHTTPServer { i, _ in (200, "text/event-stream", replies[min(i, 1)]) }
        try server.start()
        defer { server.stop() }
        try await withHarness(server: server) { h, model, outbox, store in
            let vm = h.viewModel
            let u2 = try XCTUnwrap(vm.currentPath.dropLast().last)
            XCTAssertTrue(vm.sendMessage("第三条", model: model, profile: h.profile, preset: h.preset,
                                         providerManager: h.providerManager, context: h.context))
            try await waitUntil { !vm.assistantTurnInFlight }
            let u3 = try XCTUnwrap(vm.currentPath.dropLast().last)
            XCTAssertEqual(store.aiReactions(for: ChatReactionTarget(node: u2, blockIndex: 0, blockText: u2.content)), ["👍"],
                           "开头是「第二」的那条")
            XCTAssertTrue(store.aiReactions(for: ChatReactionTarget(node: u3, blockIndex: 0, blockText: u3.content)).isEmpty)

            XCTAssertTrue(vm.sendMessage("晚安", model: model, profile: h.profile, preset: h.preset,
                                         providerManager: h.providerManager, context: h.context))
            try await waitUntil { !vm.assistantTurnInFlight && server.requestBodies.count == 2 }
            let all = vm.currentPath.filter { $0.role == "user" }
            XCTAssertTrue(all.allSatisfy { !store.aiReactions(for: ChatReactionTarget(node: $0, blockIndex: 0, blockText: $0.content)).contains("❤️") },
                          "「条」只在中间出现，不算开头：不贴，也不退回去贴最近那条")
            XCTAssertEqual(vm.currentPath.last?.content, "嗯")
        }
    }

    // MARK: 二审 B1：编辑重发也收口

    func testEditAndResendSettlesReactBlock() async throws {
        let server = try ScriptedHTTPServer { _, _ in (200, "text/event-stream", Self.sse("改好了\n\n```react\n👍\n```")) }
        try server.start()
        defer { server.stop() }
        try await withHarness(server: server) { h, model, outbox, store in
            let vm = h.viewModel
            let u2 = try XCTUnwrap(vm.currentPath.dropLast().last)
            XCTAssertTrue(vm.editAndResend(u2.id, newText: "第二条（改）", isEdit: true, model: model, profile: h.profile, preset: h.preset,
                                           providerManager: h.providerManager, context: h.context))
            try await waitUntil { !vm.assistantTurnInFlight && server.requestBodies.count == 1 }
            let reply = try XCTUnwrap(vm.currentPath.last)
            let edited = try XCTUnwrap(vm.currentPath.dropLast().last)
            XCTAssertEqual(edited.content, "第二条（改）")
            XCTAssertEqual(reply.content, "改好了", "react 块剥掉，不会带进记忆提取")
            XCTAssertEqual(store.aiReactions(for: ChatReactionTarget(node: edited, blockIndex: 0, blockText: edited.content)), ["👍"])
            XCTAssertTrue(vm.pendingReactionTurnIds.isEmpty)
        }
    }

    // MARK: 二审 B2：切楼层 / 工具退出 / 出错

    func testProfileSwitchCancelsTurnAndClearsRegistry() async throws {
        let gate = DispatchSemaphore(value: 0)
        let server = try ScriptedHTTPServer { _, _ in
            _ = gate.wait(timeout: .now() + 20)
            return (200, "text/event-stream", Self.sse("晚了"))
        }
        try server.start()
        defer { server.stop(); gate.signal() }
        try await withHarness(server: server) { h, model, outbox, store in
            let vm = h.viewModel
            let conversation = try XCTUnwrap(vm.selectedConversation)
            XCTAssertTrue(vm.sendMessage("在吗", model: model, profile: h.profile, preset: h.preset,
                                         providerManager: h.providerManager, context: h.context))
            try await waitUntil { server.requestBodies.count == 1 }
            XCTAssertEqual(vm.pendingReactionTurnIds.count, 1)
            NotificationCenter.default.post(name: .profileWillSwitch, object: nil)
            XCTAssertTrue(vm.pendingReactionTurnIds.isEmpty, "切楼层：旧回合停掉、登记清空")
            XCTAssertFalse(vm.assistantTurnInFlight)
            gate.signal()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(vm.pendingReactionTurnIds.isEmpty, "旧 stream 回来也不会留登记")
            AttachmentStore.deleteConversationAttachments(conversationId: conversation.id, profileId: conversation.profileId)
        }
    }

    func testToolExitAfterProfileSwitchLeavesNoRegistry() async throws {
        let first = try TurnStatusStreamFixture.reply("拉磨中")
        let server = try ScriptedHTTPServer { _, _ in (200, "text/event-stream", first) }
        try server.start()
        defer { server.stop() }
        try await withHarness(server: server, toolsSupported: nil) { h, model, outbox, store in
            let vm = h.viewModel
            let conversation = try XCTUnwrap(vm.selectedConversation)
            XCTAssertTrue(vm.sendMessage("帮我选", model: model, profile: h.profile, preset: h.preset,
                                         providerManager: h.providerManager, context: h.context))
            try await waitUntil { vm.pendingUserQuestion != nil }
            XCTAssertEqual(vm.pendingReactionTurnIds.count, 1)
            NotificationCenter.default.post(name: .profileWillSwitch, object: nil)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(vm.pendingReactionTurnIds.isEmpty, "工具循环因 generation 对不上退出：这一轮注销")
            XCTAssertFalse(vm.assistantTurnInFlight)
            AttachmentStore.deleteConversationAttachments(conversationId: conversation.id, profileId: conversation.profileId)
        }
    }

    func testErrorAfterPartialReactStripsBeforeWarning() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"晚安\\n\\n```react\\n👍\\n``\"}}]}\n\n"
            + "data: {\"error\":{\"message\":\"boom\"}}\n\n"
        let server = try ScriptedHTTPServer { _, _ in (200, "text/event-stream", Data(body.utf8)) }
        try server.start()
        defer { server.stop() }
        try await withHarness(server: server) { h, model, outbox, store in
            let vm = h.viewModel
            XCTAssertTrue(vm.sendMessage("睡了", model: model, profile: h.profile, preset: h.preset,
                                         providerManager: h.providerManager, context: h.context))
            try await waitUntil { !vm.assistantTurnInFlight }
            let reply = try XCTUnwrap(vm.currentPath.last)
            let user = try XCTUnwrap(vm.currentPath.dropLast().last)
            XCTAssertTrue(reply.content.hasPrefix("晚安\n\n⚠️"), reply.content)
            XCTAssertFalse(reply.content.contains("```"), "存下来的正文没有块残留")
            XCTAssertEqual(store.aiReactions(for: ChatReactionTarget(node: user, blockIndex: 0, blockText: user.content)), ["👍"],
                           "收尾 fence 只写出两个反引号：内容合法照样贴")
            XCTAssertTrue(vm.pendingReactionTurnIds.isEmpty)
        }
    }

    // MARK: 二审 B3 / B4 / #8：fence 尾随空白、CRLF、截断

    func testFenceTrailingWhitespaceCRLFAndCutClose() {
        XCTAssertEqual(ChatReactionIntent.parse("```react  \r\n❤️\r\n```\r\n"), [.init(emoji: "❤️", hint: "")])
        XCTAssertEqual(ChatReactionIntent.strip("好\r\n```react\t\r\n❤️ 第二\r\n``` \r\n"), "好")
        XCTAssertEqual(ChatReactionIntent.parse("```reactx\n❤️\n```"), [])
        XCTAssertEqual(ChatReactionIntent.dropUnclosedTail("晚安\r\n```react \r\n❤"), "晚安")
        XCTAssertEqual(ChatReactionIntent.streamingVisible("```react\r\n👍\r\n```"), "")
        // 收尾 fence 只写出 0–2 个反引号
        for tail in ["\n", "\n`", "\n``"] {
            let text = "晚安\n\n```react\n❤️ 第二" + tail
            XCTAssertEqual(ChatReactionIntent.parse(text), [.init(emoji: "❤️", hint: "第二")], tail)
            XCTAssertEqual(ChatReactionIntent.settle(text).text, "晚安", tail)
        }
        XCTAssertEqual(ChatReactionIntent.settle("```react\nnot emoji\n``").text, "```react\nnot emoji\n``", "内容不合法：留着")
    }

    func testUnclosedBlockKeepsPlainReactCode() {
        for code in ["看代码：\n```react\nconst x = 1", "看代码：\n```react\nconst x = 1\n", "```react\nimport React from 'react'\n`"] {
            XCTAssertEqual(ChatReactionIntent.settle(code).text, code)
            XCTAssertEqual(ChatReactionIntent.streamingVisible(code), code)
            XCTAssertEqual(ChatReactionIntent.parse(code), [])
        }
        XCTAssertEqual(ChatReactionIntent.settle("看\n```react\n").text, "看", "刚开头、内容还空：是表情协议")
    }

    // MARK: 二审 B5：流式藏尾块不把前面的正文一起藏掉

    func testStreamingKeepsFinishedTextBeforeReactTail() {
        XCTAssertEqual(BubbleModeRow.streamingVisibleBlocks("晚安\n\n```react\n❤️"), ["晚安"])
        XCTAssertEqual(BubbleModeRow.streamingVisibleBlocks("晚安\n\n```react\n❤️\n```\n\n还"), ["晚安"])
        XCTAssertEqual(BubbleModeRow.streamingVisibleBlocks("晚安\n\n```react\n❤️\n```\n\n还有\n\n下一"), ["晚安", "还有"])
        XCTAssertEqual(BubbleModeRow.streamingVisibleBlocks("还没写完"), [])
    }

    // MARK: - 工具

    static func sse(_ text: String) -> Data {
        guard !text.isEmpty else { return Data("data: [DONE]\n\n".utf8) }
        let content = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return Data("data: {\"choices\":[{\"delta\":{\"content\":\(content)}}]}\n\ndata: [DONE]\n\n".utf8)
    }

    private func reload(_ vm: ConversationViewModel, _ conversation: Conversation, _ context: ModelContext) async throws {
        vm.loadConversation(conversation, context: context)
        try await waitUntil { !vm.isLoading && vm.selectedConversation?.id == conversation.id && !vm.currentPath.isEmpty }
    }

    private func withHarness(server: ScriptedHTTPServer?, toolsSupported: Bool? = false,
                             run: (PromptRealPathHarness, ProviderModel, ChatCardEventOutbox, ChatReactionStore) async throws -> Void) async throws {
        let h = try await PromptRealPathHarness.make(.init(name: "reaction-rework", memoryEnabled: false, voiceHint: false,
                                                          memoryFixtures: false, bubbleMode: true))
        h.overrideDefault("imageTranscriptionEnabled", false)
        h.overrideDefault(PermissionDomain.fileLibrary.storageKey, PermissionLevel.notAllowed.rawValue)
        let suite = "ChatReactionReworkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let outbox = ChatCardEventOutbox(defaults: defaults)
        let store = ChatReactionStore(defaults: defaults)
        h.viewModel.cardEventOutbox = outbox
        h.viewModel.reactionStore = store
        var model = h.model
        var extra: String?
        if let server {
            let id = "xctest-reaction-rework-\(UUID().uuidString)"
            model = ProviderModel(credentialId: id, modelId: "gpt-4o", name: "Reaction Rework")
            h.providerManager.addCredential(APICredential(id: id, name: "Reaction Rework", emoji: "",
                                                          type: .openaiCompatible, baseURL: server.baseURL, models: [model],
                                                          toolsSupported: toolsSupported))
            h.providerManager.setApiKey("test-key", for: id)
            h.viewModel.selectedConversation?.selectedModelId = model.id
            extra = id
        }
        defer { if let extra { h.providerManager.removeCredential(id: extra) } }
        do {
            try await run(h, model, outbox, store)
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
        XCTFail("没等到预期状态")
        throw URLError(.timedOut)
    }
}
