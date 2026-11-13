import XCTest
@testable import 记忆花园

final class ChatSampleTests: XCTestCase {
    private func step(result: String? = "ok", error: Bool = false, input: String = "{}") -> ChatToolStep {
        ChatToolStep(id: "search-1", name: "fs_search", inputJSON: input, result: result,
                     isError: error, integration: nil, icon: nil)
    }

    func testNonAdjacentResultsPairWithoutLosingTextOrOrphans() {
        let use = MessageSegment.toolUse(id: "a", name: "fs_read", inputJSON: "{}", integrationName: nil, iconName: nil)
        let result = MessageSegment.toolResult(toolUseId: "a", text: "result", isError: false, integrationName: nil)
        let orphan = MessageSegment.toolResult(toolUseId: "missing", text: "orphan", isError: true, integrationName: nil)
        XCTAssertEqual(ChatToolTimeline.pairedSegments([use, .text("说明"), result, orphan]),
                       [use, result, .text("说明"), orphan])
    }

    func testRepeatedResultIsPreservedAsAnOrphan() {
        let use = MessageSegment.toolUse(id: "a", name: "fs_read", inputJSON: "{}", integrationName: nil, iconName: nil)
        let first = MessageSegment.toolResult(toolUseId: "a", text: "first", isError: false, integrationName: nil)
        let extra = MessageSegment.toolResult(toolUseId: "a", text: "extra", isError: true, integrationName: nil)
        XCTAssertEqual(ChatToolTimeline.pairedSegments([use, .text("说明"), first, extra]), [use, first, .text("说明"), extra])
    }

    func testActualFileSearchArgumentsAndResultCount() {
        let search = step(result: "notes/a.md: 第一条\nnotes/b.md: 第二条", input: "{\"keyword\":\"加密卡\"}")
        XCTAssertEqual(search.action, "搜索「加密卡」")
        XCTAssertEqual(search.status, "2 条结果")
        XCTAssertEqual(step(result: "无命中").status, "0 条结果")
        XCTAssertEqual(ChatSystemMessage.noticeText("⚠️ 失败 123"), "失败 123")
    }

    @MainActor
    func testToolSummaryBackupRoundTripAndLegacyMissingField() throws {
        let node = MessageNode(id: "chat-sample-backup", role: "assistant", content: "正文", contentType: "text",
                               createTime: Date(), parentId: nil, childrenIds: [],
                               conversationId: "sample", profileId: "test")
        node.toolSummaries = ["group-fingerprint": "在文件库搜了两次"]
        let document = FullNodeDocument(model: node)
        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(FullNodeDocument.self, from: encoded)
        XCTAssertEqual(decoded.toNodeModel().toolSummaries, node.toolSummaries)
        var legacy = document
        legacy.toolSummariesData = nil
        let legacyBytes = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: legacyBytes, as: UTF8.self).contains("toolSummariesData"))
        XCTAssertTrue(try JSONDecoder().decode(FullNodeDocument.self, from: legacyBytes).toNodeModel().toolSummaries.isEmpty)
    }

    func testFingerprintChangesAfterResultOrInputChanges() {
        let original = ChatToolTimeline.fingerprint([step()])
        XCTAssertNotEqual(original, ChatToolTimeline.fingerprint([step(result: nil)]))
        XCTAssertNotEqual(ChatToolTimeline.fingerprint([step(result: nil)]), ChatToolTimeline.fingerprint([step(result: "")]))
        XCTAssertNotEqual(original, ChatToolTimeline.fingerprint([step(error: true)]))
        XCTAssertNotEqual(original, ChatToolTimeline.fingerprint([step(input: "{\"query\":\"new\"}")]))
        XCTAssertEqual(original, ChatToolTimeline.fingerprint([step()]))
    }

    func testSummaryNeverIncludesSearchTermsOrCommandSecrets() {
        let secret = "private-token-123"
        let search = step(result: secret, input: "{\"query\":\"\(secret)\",\"password\":\"\(secret)\"}")
        let command = ChatToolStep(id: "cmd", name: "run_command", inputJSON: "{\"command\":\"echo \(secret)\"}",
                                   result: secret, isError: false, integration: nil, icon: nil)
        let prompt = ChatToolTimeline.summaryPrompt([search, command])
        XCTAssertFalse(prompt.contains(secret))
        XCTAssertTrue(prompt.contains("搜索文件库"))
        XCTAssertTrue(prompt.contains("运行命令"))
        let longPrompt = ChatToolTimeline.summaryPrompt(Array(repeating: search, count: 45))
        XCTAssertTrue(longPrompt.contains("共 45 个步骤"))
        XCTAssertTrue(longPrompt.contains("搜索文件库 · 45 次"))
        XCTAssertFalse(longPrompt.contains(secret))
    }

    func testFallbackDoesNotHideFailureOrPretendPendingIsComplete() {
        XCTAssertTrue(ChatToolTimeline.fallback([step(error: true)]).contains("失败"))
        XCTAssertTrue(ChatToolTimeline.fallback([step(result: nil)]).contains("正在"))
        XCTAssertTrue(ChatToolTimeline.fallback([step(), step()]).contains("2 次"))
    }

    func testErrorCapsulePreservesPartialReplyAndUserContent() {
        let err = ChatSystemMessage.errorLine
        XCTAssertEqual(ChatSystemMessage.split(err("服务不可用"), legacy: false), .init(body: "", error: "服务不可用"))
        XCTAssertEqual(ChatSystemMessage.split("正文\n\n" + err("服务不可用"), legacy: false), .init(body: "正文", error: "服务不可用"))
        XCTAssertNil(ChatSystemMessage.split("这一句里有 ⚠️ 示例", legacy: true).error)
        XCTAssertEqual(ChatSystemMessage.removingTrailingError(from: [.text("正文"), .text(err("失败"))], legacy: false), [.text("正文")])
        XCTAssertEqual(ChatSystemMessage.removingTrailingError(from: [.text("正文\n\n" + err("失败"))], legacy: false), [.text("正文")])
        XCTAssertEqual(ChatSystemMessage.split("（已停止）", legacy: false).notice, "已停止")
        XCTAssertEqual(ChatSystemMessage.removingTrailingError(from: [.text("正文"), .text("（已停止）")], legacy: false), [.text("正文")])
    }

    /// plan-send-notice-marker B：新消息里 AI 自己写的「⚠️ 」是正文；老消息照旧按报错拆
    func testPlainWarningIsBodyUnlessLegacy() {
        XCTAssertEqual(ChatSystemMessage.split("⚠️ 注意别烫手", legacy: false), .init(body: "⚠️ 注意别烫手", error: nil))
        XCTAssertEqual(ChatSystemMessage.split("先说正文\n\n⚠️ 注意别烫手", legacy: false).error, nil)
        XCTAssertEqual(ChatSystemMessage.removingTrailingError(from: [.text("正文"), .text("⚠️ 提醒")], legacy: false).count, 2)
        XCTAssertEqual(ChatSystemMessage.split("⚠️ 服务不可用", legacy: true), .init(body: "", error: "服务不可用"))
        XCTAssertEqual(ChatSystemMessage.split("正文\n\n⚠️ 服务不可用", legacy: true), .init(body: "正文", error: "服务不可用"))
        XCTAssertEqual(ChatSystemMessage.removingTrailingError(from: [.text("正文"), .text("⚠️ 失败")], legacy: true), [.text("正文")])
        XCTAssertTrue(ChatSystemMessage.usesLegacyMarker(Date(timeIntervalSince1970: 1_794_185_000)))
        XCTAssertFalse(ChatSystemMessage.usesLegacyMarker(Date(timeIntervalSince1970: 1_794_187_000)))
        XCTAssertTrue(ChatSystemMessage.usesLegacyMarker(nil), "没时间的老导入消息按老规矩")
    }
}
