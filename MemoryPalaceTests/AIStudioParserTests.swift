import XCTest
@testable import 记忆花园

/// #047：AI Studio chunkedPrompt 文件解析。全部合成样本，结构依据 docs/research-import-gemini.md §1.3，不是 Google 真实导出。
final class AIStudioParserTests: XCTestCase {

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])

    private func file(_ chunks: [[String: Any]], system: String? = "你是助手", extra: [String: Any] = [:]) -> [String: Any] {
        var root: [String: Any] = [
            "runSettings": ["model": "models/gemini-2.5-pro", "temperature": 0.7, "topK": 40, "safetySettings": [["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "OFF"]]],
            "chunkedPrompt": ["chunks": chunks],
        ]
        if let system { root["systemInstruction"] = ["text": system] }
        for (k, v) in extra { root[k] = v }
        return root
    }

    private func parse(_ root: [String: Any], fileName: String = "我的提示", bom: Bool = false) throws -> GeminiImportResult {
        var data = try JSONSerialization.data(withJSONObject: root)
        if bom { data = Data(GeminiImportSupport.utf8BOM) + data }
        return try AIStudioParser.parse(data: data, fileName: fileName)
    }

    private func segments(_ node: ImportedNodePayload) throws -> [MessageSegment] {
        try JSONDecoder().decode([MessageSegment].self, from: XCTUnwrap(node.segmentsData))
    }

    private func meta(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    func testDetection() {
        XCTAssertTrue(AIStudioParser.isAIStudio(file([])))
        XCTAssertFalse(AIStudioParser.isAIStudio(["contents": [["role": "user", "parts": [["text": "hi"]]]]]), "Gemini API 请求体不是 AI Studio 文件")
        XCTAssertFalse(AIStudioParser.isAIStudio([["header": "Gemini Apps"]]))
        XCTAssertThrowsError(try AIStudioParser.parse(data: Data("{\"mapping\":{}}".utf8), fileName: "x"))
        XCTAssertThrowsError(try AIStudioParser.parse(data: Data("not json".utf8), fileName: "x"))
    }

    func testBasicConversationWithBOMAndExtensionlessName() throws {
        let r = try parse(file([
            ["role": "user", "text": "你好", "createTime": "2025-06-15T10:30:00Z", "tokenCount": 2],
            ["role": "model", "text": "你好呀", "createTime": "2025-06-15T10:30:05.5Z", "finishReason": "STOP"],
        ]), fileName: "Trip plan v1.5", bom: true)
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(p.provider, "aistudio")
        XCTAssertEqual(p.title, "Trip plan v1.5", "无扩展名文件名里的点不当扩展名剥")
        XCTAssertEqual(p.nodes.map(\.role), ["user", "assistant"])
        XCTAssertEqual(try segments(p.nodes[1]), [.text("你好呀")])
        XCTAssertEqual(p.nodes[1].parentId, p.nodes[0].id)
        XCTAssertEqual(p.currentNodeId, p.nodes[1].id)
        XCTAssertEqual(p.createTime, GeminiImportSupport.parseISO("2025-06-15T10:30:00Z"))
        XCTAssertEqual(p.updateTime.timeIntervalSince(p.createTime), 5.5, accuracy: 0.001)
        XCTAssertTrue(p.id.hasSuffix("-aistudio"))
        XCTAssertNotEqual(p.id.prefix(8), "aistudio", "附件目录按 id 前 8 位分，前缀不能是固定串")
        XCTAssertTrue(p.nodes.allSatisfy { $0.id.hasPrefix(p.id + "/") })
        let chunkMeta = try meta(p.nodes[1].sourceMetadata)["chunks"] as? [[String: Any]]
        XCTAssertEqual(chunkMeta?.first?["finishReason"] as? String, "STOP")
    }

    func testJsonExtensionStrippedFromTitle() throws {
        let r = try parse(file([["role": "user", "text": "hi"]]), fileName: "Notes.json")
        XCTAssertEqual(r.payloads.first?.title, "Notes")
    }

    func testSystemInstructionAndSettingsGoToMetadataOnly() throws {
        let r = try parse(file([["role": "user", "text": "hi"]], extra: ["futureField": ["x": 1]]))
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(p.nodes.count, 1, "系统指令不变成消息")
        let m = try meta(p.sourceMetadata)
        XCTAssertEqual((m["systemInstruction"] as? [String: Any])?["text"] as? String, "你是助手")
        XCTAssertEqual((m["runSettings"] as? [String: Any])?["model"] as? String, "models/gemini-2.5-pro")
        XCTAssertNotNil(m["futureField"], "未知根字段保留")
        XCTAssertNil(m["chunkedPrompt"])
    }

    func testConsecutiveModelChunksMergeKeepingSegmentOrder() throws {
        let r = try parse(file([
            ["role": "user", "text": "画只猫"],
            ["role": "model", "text": "先想想", "isThought": true, "thoughtSignatures": ["sig"]],
            ["role": "model", "text": "这是猫："],
            ["role": "model", "inlineImage": ["mimeType": "image/png", "data": png.base64EncodedString()]],
            ["role": "model", "driveImage": ["id": "drive-1"]],
        ]))
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(p.nodes.count, 2)
        XCTAssertEqual(try segments(p.nodes[1]), [
            .thinking(text: "先想想", signature: nil),
            .text("这是猫："),
            .image(name: "image-3.png", type: "image/png", data: png),
            .file(name: "Drive 图片", uuid: "drive-1"),
        ])
        XCTAssertEqual(p.nodes[1].id, p.id + "/1", "消息 id 用第一个 chunk 的下标")
        let chunks = try XCTUnwrap(try meta(p.nodes[1].sourceMetadata)["chunks"] as? [[String: Any]])
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[0]["thoughtSignatures"] as? [String], ["sig"])
        XCTAssertEqual((chunks[2]["inlineImage"] as? [String: Any])?["data"] as? String, "<base64 16 chars>", "元数据不重复存图片")
        XCTAssertEqual(r.attachmentPlaceholderCount, 1)
    }

    func testPartsShape() throws {
        let r = try parse(file([
            ["role": "user", "parts": [["text": "看图"], ["inlineData": ["mimeType": "image/jpeg", "data": png.base64EncodedString()]]]],
            ["role": "model", "parts": [["text": "思考中", "thought": true, "thoughtSignature": "s"], ["text": "是图"]]],
        ]))
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(try segments(p.nodes[0]), [.text("看图"), .image(name: "image-0-1.jpeg", type: "image/jpeg", data: png)])
        XCTAssertEqual(try segments(p.nodes[1]), [.thinking(text: "思考中", signature: nil), .text("是图")])
    }

    func testUnknownRoleKeptHidden() throws {
        let r = try parse(file([
            ["role": "user", "text": "a"],
            ["role": "function", "text": "{\"ok\":true}"],
            ["role": "model", "text": "b"],
        ]))
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(p.nodes.map(\.role), ["user", "function", "assistant"], "不认识的角色不默认当用户")
        XCTAssertEqual(p.nodes[1].sourceVisibility, "hidden")
        XCTAssertEqual(r.unknownRoleCount, 1)
        XCTAssertEqual(countDisplayableNodes(p.nodes), 2)
    }

    func testToolChunksKeptAsHiddenMessages() throws {
        let r = try parse(file([
            ["role": "user", "text": "查天气"],
            ["role": "model", "functionCall": ["name": "weather", "args": ["city": "京都"]]],
            ["role": "function", "functionResponse": ["name": "weather", "response": ["sky": "晴"]]],
            ["role": "model", "text": "晴天"],
        ]))
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(p.nodes.map(\.role), ["user", "assistant", "function", "assistant"])
        XCTAssertEqual(p.nodes[1].sourceVisibility, "hidden")
        XCTAssertEqual(p.nodes[2].sourceVisibility, "hidden")
        XCTAssertEqual(r.unsupportedMessageCount, 2)
        XCTAssertEqual(r.unknownRoleCount, 0)
        let raw = try XCTUnwrap(try meta(p.nodes[2].sourceMetadata)["chunks"] as? [[String: Any]])
        XCTAssertNotNil(raw.first?["functionResponse"], "原始 chunk 留在元数据里")
        XCTAssertEqual(countDisplayableNodes(p.nodes), 2)
    }

    func testOnlyUnsupportedContentYieldsNoPayload() throws {
        let r = try parse(file([["role": "model", "functionCall": ["name": "x"]]]))
        XCTAssertTrue(r.payloads.isEmpty)
        XCTAssertEqual(r.unsupportedMessageCount, 1)
    }

    func testSameOpeningTextDifferentImageGetsDifferentId() throws {
        func opening(_ bytes: [UInt8]) -> [[String: Any]] {
            [["role": "user", "parts": [["text": "描述这张图"], ["inlineData": ["mimeType": "image/png", "data": Data(bytes).base64EncodedString()]]]]]
        }
        let cat = try parse(file(opening([1, 2, 3])), fileName: "图")
        let dog = try parse(file(opening([4, 5, 6])), fileName: "图")
        XCTAssertNotEqual(cat.payloads.first?.id, dog.payloads.first?.id)
    }

    func testMissingAndBadCreateTime() throws {
        let r = try parse(file([
            ["role": "user", "text": "a"],
            ["role": "model", "text": "b", "createTime": "not a time"],
        ]))
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertNil(p.nodes[0].createTime, "缺时间不填导入时间")
        XCTAssertNil(p.nodes[1].createTime)
        XCTAssertEqual(p.createTime, .distantPast)
        XCTAssertEqual(r.unreadableTimeCount, 1)
    }

    func testBadAndOversizedImagesBecomePlaceholders() throws {
        let huge = String(repeating: "A", count: AIStudioParser.maxInlineImageBytes / 3 * 4 + 8)
        let r = try parse(file([
            ["role": "user", "inlineImage": ["mimeType": "image/png", "data": ""]],
            ["role": "model", "inlineImage": ["mimeType": "image/png", "data": huge]],
        ]))
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(try segments(p.nodes[0]), [.file(name: "image-0.png", uuid: "")])
        XCTAssertEqual(try segments(p.nodes[1]), [.file(name: "image-1.png", uuid: "")])
        XCTAssertEqual(r.droppedImageCount, 2)
    }

    func testErrorOnlyChunkShowsErrorAndEmptyChunksSkipped() throws {
        let r = try parse(file([
            ["role": "user", "text": "a"],
            ["role": "model", "errorMessage": "Internal error"],
            ["role": "user", "text": ""],
        ]))
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(p.nodes.count, 2)
        XCTAssertEqual(try segments(p.nodes[1]), [.text("⚠️ Internal error")])
    }

    func testEmptyChunksYieldNoPayload() throws {
        XCTAssertTrue(try parse(file([])).payloads.isEmpty)
    }

    func testConversationIdStableWhenChatContinues() throws {
        let first: [[String: Any]] = [["role": "user", "text": "开场", "createTime": "2025-06-15T10:30:00Z"], ["role": "model", "text": "回"]]
        let a = try parse(file(first), fileName: "旧名")
        let b = try parse(file(first + [["role": "user", "text": "续聊"]]), fileName: "新名")
        XCTAssertEqual(a.payloads.first?.id, b.payloads.first?.id, "续聊后重新下载还是同一段对话")
        XCTAssertTrue(Set(a.payloads[0].nodes.map(\.id)).isSubset(of: Set(b.payloads[0].nodes.map(\.id))))
    }

    func testSameOpeningWithoutTimeDistinguishedByFileName() throws {
        let chunks: [[String: Any]] = [["role": "user", "text": "hi"]]
        XCTAssertNotEqual(try parse(file(chunks), fileName: "A").payloads.first?.id, try parse(file(chunks), fileName: "B").payloads.first?.id)
    }

    func testTitleFallsBackToFirstPrompt() throws {
        let r = try parse(file([["role": "user", "text": "帮我规划一次去京都的旅行\n第二行"]]), fileName: "Untitled prompt")
        XCTAssertEqual(r.payloads.first?.title, "帮我规划一次去京都的旅行")
    }
}
