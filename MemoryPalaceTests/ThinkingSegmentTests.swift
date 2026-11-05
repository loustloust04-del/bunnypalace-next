import XCTest
@testable import 记忆花园

/// thinking 回传 §3.2 / §4：思考块 → 段、段编解码兼容（老版本读新格式 / 新版本读老格式）、普通回复只挂思考段不改正文的走法
final class ThinkingSegmentTests: XCTestCase {

    // MARK: - 编解码

    func testRedactedDataRoundTrips() throws {
        let segs: [MessageSegment] = [.thinking(text: "摘要", signature: "sig"), .thinking(text: "", signature: nil, redactedData: "ENC")]
        let data = try JSONEncoder().encode(segs)
        XCTAssertEqual(try JSONDecoder().decode([MessageSegment].self, from: data), segs)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""kind":"thinking""#), "redacted 仍是 thinking 这个 kind，不加新 kind")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode([MessageSegment.thinking(text: "a", signature: nil)]), as: UTF8.self)
            .contains("redactedData"), "没有 redacted 不写这个 key")
    }

    func testOldFormatStillDecodes() throws {
        let old = Data(#"[{"kind":"thinking","text":"旧","signature":"s"},{"kind":"text","text":"正文"}]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([MessageSegment].self, from: old),
                       [.thinking(text: "旧", signature: "s"), .text("正文")])
    }

    /// 老版本 app 的解码只认 kind / text / signature：新格式（多一个 redactedData）照样整组解开，redacted 读成一段空思考
    func testOldDecoderReadsNewFormat() throws {
        struct OldSegment: Decodable {
            enum K: String, CodingKey { case kind, text, signature }
            let kind: String
            let text: String
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: K.self)
                kind = try c.decode(String.self, forKey: .kind)
                text = try c.decode(String.self, forKey: .text)
                _ = try c.decodeIfPresent(String.self, forKey: .signature)
            }
        }
        let data = try JSONEncoder().encode([MessageSegment.thinking(text: "", signature: nil, redactedData: "ENC"), .text("正文")])
        let old = try JSONDecoder().decode([OldSegment].self, from: data)
        XCTAssertEqual(old.map(\.kind), ["thinking", "text"])
        XCTAssertEqual(old.first?.text, "")
    }

    // MARK: - 普通回复只挂思考段

    /// astra #4：普通回复挂思考存成 [.text(正文), 思考…]——新版本按 content 走纯文本，老版本（没有这条判断）照分段渲染也看得到正文
    func testAttachedThinkingReplyShape() {
        let attached: [MessageSegment] = [.text("正文"), .thinking(text: "想", signature: "s")]
        XCTAssertTrue(attached.isAttachedThinkingReply)
        XCTAssertFalse(attached.hasRenderableSegments, "新版本：正文在 content，照旧走纯文本")
        let voice = attached + [.audioRef(name: "a", mime: "audio/mpeg", path: "p", duration: 1, script: nil)]
        XCTAssertTrue(voice.isAttachedThinkingReply, "之后挂了语音条也还是这个形状")
        XCTAssertFalse(voice.hasRenderableSegments)
        XCTAssertEqual(attached.attachedThinkingText, "想")

        // 老版本的判断：只排除 audioRef → 走分段渲染；段里有正文，不会只剩思考
        let oldRenderable = attached.contains { if case .audioRef = $0 { return false } else { return true } }
        XCTAssertTrue(oldRenderable)
        XCTAssertEqual(attached.compactMap { if case .text(let s) = $0 { return s } else { return nil } }, ["正文"], "老版本看得到正文")

        // 卡片脚本只改 content：新版本一律以 content 为准，不读段里那份副本
        XCTAssertEqual(ChatCardIndex.visibleText(content: "改过的正文", segments: attached), "改过的正文")
        XCTAssertEqual(ChatSelectionText.body(content: "改过的正文", segments: attached, isUser: false, cacheKey: "xctest-attached"),
                       "改过的正文", "复制不重复、取 content")
    }

    /// astra #5：导入的分段（只有思考 / 思考在正文前）照旧分段渲染、朗读照旧只念正文段，不把 <<<THINK>>> 正文漏出来
    func testImportedSegmentsBehaveAsBefore() {
        let thinkingOnly: [MessageSegment] = [.thinking(text: "导入的思考", signature: "s")]
        XCTAssertFalse(thinkingOnly.isAttachedThinkingReply)
        XCTAssertTrue(thinkingOnly.hasRenderableSegments, "导入的只有思考：照旧分段渲染")
        XCTAssertNil(thinkingOnly.attachedThinkingText)
        let imported: [MessageSegment] = [.thinking(text: "想", signature: "s"), .text("正文")]
        XCTAssertFalse(imported.isAttachedThinkingReply)
        XCTAssertTrue(imported.hasRenderableSegments)
        XCTAssertFalse(([.text("a"), .thinking(text: "t", signature: nil), .text("b")] as [MessageSegment]).isAttachedThinkingReply)
        XCTAssertFalse(([.text("a")] as [MessageSegment]).isAttachedThinkingReply, "没有思考段不算")

        let node = MessageNode(id: "xctest-imported-think", role: "assistant", content: ClaudeImporter.flattenSegmentsForSearch(thinkingOnly),
                               contentType: "segmented", createTime: nil, parentId: nil, childrenIds: [], conversationId: "c")
        node.setSegments(thinkingOnly)
        XCTAssertTrue(node.content.contains("<<<THINK>>>"), "前提：导入写的 content 带标记")
        XCTAssertEqual(SpeechService.speakableText(from: node), "", "朗读不念导入的思考")

        let plain = MessageNode(id: "xctest-attached-speech", role: "assistant", content: "正文", contentType: "text", createTime: nil,
                                parentId: nil, childrenIds: [], conversationId: "c")
        plain.setSegments([.text("正文"), .thinking(text: "想", signature: "s")])
        XCTAssertEqual(SpeechService.speakableText(from: plain), "正文", "普通回复挂思考：念正文一遍")
    }

    /// astra #6：页 2 思考行——原生摘要跟「思考过程」设置，CC / 标签跟 CC 开关，流式时不出原生的
    func testThinkingLineGates() {
        XCTAssertEqual(DisclosureKind.thinkingLine(tagOrCC: nil, showCC: false, native: "摘要", showNative: true, streaming: false), "摘要",
                       "关 CC 思考不连累原生摘要")
        XCTAssertNil(DisclosureKind.thinkingLine(tagOrCC: nil, showCC: true, native: "摘要", showNative: false, streaming: false), "思考过程隐藏")
        XCTAssertNil(DisclosureKind.thinkingLine(tagOrCC: nil, showCC: true, native: "摘要", showNative: true, streaming: true), "流式时不出")
        XCTAssertEqual(DisclosureKind.thinkingLine(tagOrCC: "cc", showCC: true, native: "摘要", showNative: true, streaming: false), "cc")
        XCTAssertEqual(DisclosureKind.thinkingLine(tagOrCC: "cc", showCC: false, native: nil, showNative: true, streaming: false), nil)
    }

    func testNativeThinkingTextSkipsEmpty() {
        XCTAssertNil(([.thinking(text: "", signature: "s"), .thinking(text: "", signature: nil, redactedData: "E")] as [MessageSegment]).nativeThinkingText)
        XCTAssertEqual(([.thinking(text: "甲", signature: "s"), .thinking(text: " ", signature: "t"), .thinking(text: "乙", signature: "u")]
                        as [MessageSegment]).nativeThinkingText, "甲\n\n乙")
    }

    /// 历史回放不带思考（Q1-A）：节点里多了思考段，回合拆分和不带时一模一样
    func testToolReplayIgnoresThinkingSegments() throws {
        let plain: [MessageSegment] = [.text("先说"), .toolUse(id: "t1", name: "fs_read", inputJSON: "{}", integrationName: nil, iconName: nil),
                                       .toolResult(toolUseId: "t1", text: "r", isError: false, integrationName: nil), .text("最后")]
        let withThinking: [MessageSegment] = [.thinking(text: "想", signature: "s"), .text("先说"), .thinking(text: "", signature: "p"),
                                              .toolUse(id: "t1", name: "fs_read", inputJSON: "{}", integrationName: nil, iconName: nil),
                                              .toolResult(toolUseId: "t1", text: "r", isError: false, integrationName: nil),
                                              .thinking(text: "收尾", signature: "q"), .text("最后")]
        let a = try XCTUnwrap(ToolReplay.rounds(from: plain)), b = try XCTUnwrap(ToolReplay.rounds(from: withThinking))
        XCTAssertEqual(a.map(\.text), b.map(\.text))
        XCTAssertEqual(a.map { $0.calls.map(\.id) }, b.map { $0.calls.map(\.id) })
        XCTAssertEqual(a.map { $0.results.map(\.text) }, b.map { $0.results.map(\.text) })
        XCTAssertEqual(ToolReplay.rounds(from: [.thinking(text: "想", signature: "s")])?.count, 0, "只有思考段 = 没有工具回合")
    }

    // MARK: - 落段（VM 的两个纯函数）

    func testReplySegmentsOrder() {
        let blocks = [
            ReplyBlock(raw: ["type": "thinking", "thinking": "想", "signature": "s0"], complete: true),
            ReplyBlock(raw: ["type": "text", "text": "说"], complete: true),
            ReplyBlock(raw: ["type": "thinking", "thinking": "", "signature": "s1"], complete: true),
            ReplyBlock(raw: ["type": "tool_use", "id": "t", "name": "fs_read", "input": [String: Any]()], complete: true),
        ]
        XCTAssertEqual(ConversationViewModel.replySegments(blocks, text: "说"),
                       [.thinking(text: "想", signature: "s0"), .text("说"), .thinking(text: "", signature: "s1")])
        XCTAssertEqual(ConversationViewModel.replySegments([], text: "说"), [.text("说")], "OpenAI 兼容：和以前一样只有正文")
        XCTAssertEqual(ConversationViewModel.replySegments([], text: ""), [])
    }

    func testAttachThinkingPlainAndToolNode() throws {
        let thinking: [MessageSegment] = [.thinking(text: "想", signature: "s")]
        let plain = MessageNode(id: "n1", role: "assistant", content: "正文", contentType: "text", createTime: nil, parentId: nil,
                                childrenIds: [], conversationId: "c")
        ConversationViewModel.attachThinking(thinking, to: plain, base: nil)
        XCTAssertEqual(plain.segments, [.text("正文")] + thinking, "正文段在前（老版本也看得到正文）")
        XCTAssertEqual(plain.content, "正文")
        XCTAssertEqual(plain.contentType, "text")

        let failed = MessageNode(id: "n4", role: "assistant", content: "⚠️ 出错了", contentType: "text", createTime: nil, parentId: nil,
                                 childrenIds: [], conversationId: "c")
        ConversationViewModel.attachThinking(thinking, to: failed, base: nil)
        XCTAssertEqual(failed.segments, [.text("⚠️ 出错了")] + thinking, "正文只剩报错也挂（审查 #2）：思考不丢")
        XCTAssertEqual(failed.segments?.isAttachedThinkingReply, true, "照旧按 content 渲染：正文拆出报错胶囊，没正文不画空泡")
        XCTAssertEqual(failed.segments?.attachedThinkingText, "想")

        for content in ["", "（已停止）"] {
            let bare = MessageNode(id: "n5", role: "assistant", content: content, contentType: "text", createTime: nil, parentId: nil,
                                   childrenIds: [], conversationId: "c")
            ConversationViewModel.attachThinking(thinking, to: bare, base: nil)
            XCTAssertEqual(bare.segments, [.text(content)] + thinking, "只有思考 / 已停止：\(content)")
            XCTAssertEqual(ChatCardIndex.visibleText(content: bare.content, segments: bare.segments), content)
        }

        let tool = MessageNode(id: "n2", role: "assistant", content: "", contentType: "segmented", createTime: nil, parentId: nil,
                               childrenIds: [], conversationId: "c")
        tool.setSegments([.toolUse(id: "t", name: "fs_read", inputJSON: "{}", integrationName: nil, iconName: nil), .text("最后")])
        ConversationViewModel.attachThinking(thinking, to: tool, base: 1)
        XCTAssertEqual(tool.segments?.count, 3)
        XCTAssertEqual(tool.segments?[1], thinking[0], "插在这次回复追加的正文前面")

        let empty = MessageNode(id: "n3", role: "assistant", content: "x", contentType: "text", createTime: nil, parentId: nil,
                                childrenIds: [], conversationId: "c")
        ConversationViewModel.attachThinking([], to: empty, base: nil)
        XCTAssertNil(empty.segmentsData, "没有思考块不写 segments")
    }
}
