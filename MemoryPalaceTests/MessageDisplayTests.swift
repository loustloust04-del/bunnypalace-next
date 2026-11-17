import XCTest
import MemoryCore
@testable import 记忆花园

/// 「一条消息在对话列表里显示成什么」唯一出处（docs/plan-重构.md §3.5）：每种情况钉一条，
/// 钉的是旧页 BubbleView 搬过来之前的行为
final class MessageDisplayTests: XCTestCase {
    private var counter = 0

    private func node(_ role: String, _ content: String, type: String = "text",
                      segments: [MessageSegment]? = nil) -> MessageNode {
        counter += 1
        let node = MessageNode(id: "md-\(name)-\(counter)", role: role, content: content, contentType: type,
                               createTime: Date(), parentId: nil, childrenIds: [], conversationId: "c")
        if let segments { node.segmentsData = try? JSONEncoder().encode(segments) }
        return node
    }

    private func body(_ node: MessageNode, streaming: Bool = false, live: Bool = false,
                      showCCThinking: Bool = true) -> MessageDisplay.ArticleBody {
        MessageDisplay.articleBody(of: node, isStreaming: streaming, streamsLive: live,
                                   context: .init(scripts: [], userName: "禾禾", charName: "小岚",
                                                  showCCThinking: showCCThinking))
    }

    // MARK: 骨架

    func testSystemMessageIsOneCapsule() {
        let plain = MessageDisplay.frame(of: node("system", "已切换模型"), isStreaming: false)
        XCTAssertEqual(plain.system, .init(text: "已切换模型", isError: false))
        let warning = MessageDisplay.frame(of: node("system", "⚠ 余额不足"), isStreaming: false)
        XCTAssertEqual(warning.system, .init(text: "⚠ 余额不足", isError: true))
    }

    func testOrdinaryReplyHasBodyAndNoTail() {
        let frame = MessageDisplay.frame(of: node("assistant", "你好"), isStreaming: false)
        XCTAssertEqual(frame, MessageDisplay.Frame())
    }

    func testErrorOnlyReplyDropsTheBubble() {
        let frame = MessageDisplay.frame(of: node("assistant", ChatSystemMessage.errorLine("超时")), isStreaming: false)
        XCTAssertEqual(frame.tail, .error("超时"))
        XCTAssertFalse(frame.hasBody)
    }

    func testErrorAfterTextKeepsTheBubble() {
        let content = "写到一半\n\n" + ChatSystemMessage.errorLine("断了")
        let frame = MessageDisplay.frame(of: node("assistant", content), isStreaming: false)
        XCTAssertEqual(frame.tail, .error("断了"))
        XCTAssertTrue(frame.hasBody)
    }

    func testStoppedNoticeAndStreamingKeepsBody() {
        let stopped = node("assistant", "（已停止）")
        XCTAssertEqual(MessageDisplay.frame(of: stopped, isStreaming: false).tail, .notice("已停止"))
        XCTAssertFalse(MessageDisplay.frame(of: stopped, isStreaming: false).hasBody)
        XCTAssertTrue(MessageDisplay.frame(of: stopped, isStreaming: true).hasBody, "流式中不撤气泡")
    }

    func testUserMessageNeverSplitsATail() {
        let frame = MessageDisplay.frame(of: node("user", "（已停止）"), isStreaming: false)
        XCTAssertEqual(frame, MessageDisplay.Frame())
    }

    func testErrorInLastTextSegmentWins() {
        let segments: [MessageSegment] = [.toolUse(id: "t", name: "x", inputJSON: "{}", integrationName: nil, iconName: nil),
                                          .text(ChatSystemMessage.errorLine("工具挂了"))]
        let frame = MessageDisplay.frame(of: node("assistant", "正文", segments: segments), isStreaming: false)
        XCTAssertEqual(frame.tail, .error("工具挂了"))
        XCTAssertTrue(frame.hasBody, "去掉报错那段还剩工具段")
    }

    func testAbnormalOutcomeIsTheTailWhenNoErrorText() {
        let reply = node("assistant", "写到一半")
        reply.replyOutcome = ReplyOutcome.truncatedLength.rawValue
        XCTAssertEqual(MessageDisplay.frame(of: reply, isStreaming: false).tail, .outcome(.truncatedLength))
        reply.replyOutcome = ReplyOutcome.normal.rawValue
        XCTAssertNil(MessageDisplay.frame(of: reply, isStreaming: false).tail)
    }

    // MARK: 文章模式正文

    func testPlainMessagesAreMarkdown() {
        XCTAssertEqual(body(node("user", "**你好**")), .markdown("**你好**", thinking: nil))
        XCTAssertEqual(body(node("assistant", "回你")), .markdown("回你", thinking: nil))
    }

    func testThinkingTagIsPulledOutOfAssistantText() {
        guard case .markdown(let text, let thinking) = body(node("assistant", "[thinking]想一下[/thinking]\n\n答案")) else {
            return XCTFail("应该是 Markdown 正文")
        }
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "答案")
        XCTAssertEqual(thinking?.trimmingCharacters(in: .whitespacesAndNewlines), "想一下")
    }

    func testThinkingSourcesInOrder() {
        let cc = node("assistant", "答案")
        cc.ccThinking = "CC 的思考"
        XCTAssertEqual(body(cc), .markdown("答案", thinking: "CC 的思考"))
        XCTAssertEqual(body(cc, showCCThinking: false), .markdown("答案", thinking: nil))

        let native = node("assistant", "答案", segments: [.text("答案"), .thinking(text: "原生思考", signature: nil)])
        XCTAssertEqual(body(native), .markdown("答案", thinking: "原生思考"), "普通回复挂原生思考不算分段")
        XCTAssertEqual(body(native, streaming: true), .markdown("答案", thinking: nil), "流式中不出原生思考")
    }

    func testStreamingReplyReadsTheLiveBuffer() {
        XCTAssertEqual(body(node("assistant", ""), streaming: true, live: true), .streaming)
    }

    func testAssistantSegmentsAndHeartvoice() {
        let segments: [MessageSegment] = [.thinking(text: "先想", signature: nil), .text("再说")]
        XCTAssertEqual(body(node("assistant", "再说", segments: segments)), .segments(segments))
        XCTAssertEqual(body(node("assistant", "今天很开心", type: "heartvoice")), .heartvoice("今天很开心"))
        XCTAssertEqual(body(node("assistant", "💭 心声\n\n老格式")), .heartvoice("老格式"))
    }

    func testUserSegments() {
        let voice = MessageSegment.audioRef(name: "a.m4a", mime: "audio/mp4", path: "voice/a.m4a", duration: 3, script: "转写")
        XCTAssertEqual(body(node("user", "[语音 0:03] 转写", segments: [voice])), .userVoiceNote)
        XCTAssertEqual(body(node("user", "打的字\n[语音 0:03] 转写", segments: [.text("打的字"), voice])),
                       .markdown("打的字", thinking: nil), "文字 + 语音：气泡里只画打的字")
        let image = MessageSegment.imageRef(name: "p.png", type: "image/png", path: "img/p.png")
        XCTAssertEqual(body(node("user", "", segments: [image])), .empty, "只有附件：气泡里没东西")
        let complex: [MessageSegment] = [.text("看这个"), .file(name: "f", uuid: "u")]
        XCTAssertEqual(body(node("user", "看这个", segments: complex)), .segments(complex))
    }

    func testMemeWinsOverEverything() {
        let id = UUID()
        XCTAssertEqual(body(node("assistant", MemeToken.make(id))), .meme(id))
        XCTAssertEqual(body(node("user", MemeToken.make(id))), .meme(id))
    }
}
