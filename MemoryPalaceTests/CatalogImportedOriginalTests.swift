import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class CatalogImportedOriginalTests: XCTestCase {
    private let pid = "catalog-imported-synthetic"
    private var root: URL!
    private var container: ModelContainer!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-imported-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = Schema([Conversation.self, MessageNode.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testClaudeImporterExcludesThinkingToolsAndAttachmentExtractionOnBothPaths() async throws {
        let json = """
        [{"uuid":"claude-original","name":"虚构导入","chat_messages":[
          {"uuid":"claude-thinking","sender":"assistant","content":[{"type":"thinking","thinking":"虚构作品《云桥城》的内部推演"}]},
          {"uuid":"claude-use","sender":"assistant","content":[{"type":"tool_use","id":"call-1","name":"fiction_lookup","input":{"query":"云桥城"}}]},
          {"uuid":"claude-result","sender":"human","content":[{"type":"tool_result","tool_use_id":"call-1","content":"工具返回虚构《云桥城》"}]},
          {"uuid":"claude-attachment","sender":"human","content":[{"type":"text","text":"附件已收到"}],"attachments":[{"file_name":"fiction.txt","file_type":"text/plain","extracted_content":"附件中的云桥城"}]},
          {"uuid":"claude-mixed","sender":"assistant","content":[{"type":"text","text":"虚构正文：星灯港的桥会移动。"},{"type":"thinking","thinking":"云桥城推演"},{"type":"tool_use","id":"call-2","name":"fiction_lookup","input":{"query":"云桥城"}},{"type":"tool_result","tool_use_id":"call-2","content":"云桥城返回值"}]},
          {"uuid":"claude-visible","sender":"human","content":[{"type":"text","text":"我在写虚构作品《云桥城》，桥每晚移位。"}]}
        ]}]
        """
        let url = root.appendingPathComponent("claude.json")
        try Data(json.utf8).write(to: url)
        let payload = try XCTUnwrap(ClaudeImporter.makePayload(from: try ClaudeImporter.load(file: url)[0]))
        XCTAssertTrue(payload.nodes.first { $0.id == "claude-use" }!.content.contains("云桥城"))
        XCTAssertTrue(payload.nodes.first { $0.id == "claude-result" }!.content.contains("云桥城"))
        XCTAssertTrue(payload.nodes.first { $0.id == "claude-attachment" }!.content.contains("云桥城"))
        try await assertCatalog(payload, hiddenQuery: "云桥城", expectedIDs: ["claude-visible"],
                                visibleQuery: "星灯港", visibleID: "claude-mixed", visibleBody: "虚构正文：星灯港的桥会移动。")
    }

    func testChatGPTImporterFoldedToolAndThinkingRemainOutsideOriginalOnBothPaths() async throws {
        let json = """
        {"id":"chatgpt-original","title":"虚构导入","create_time":1,"current_node":"reply","mapping":{
          "question":{"id":"question","parent":null,"children":["analysis"],"message":{"id":"q","author":{"role":"user"},"content":{"content_type":"text","parts":["讲讲虚构的港口"]}}},
          "analysis":{"id":"analysis","parent":"question","children":["use"],"message":{"id":"a","author":{"role":"assistant"},"channel":"analysis","content":{"content_type":"text","parts":["云桥城内部推演"]}}},
          "use":{"id":"use","parent":"analysis","children":["result"],"message":{"id":"u","author":{"role":"assistant"},"recipient":"fiction_lookup","content":{"content_type":"code","text":"lookup('云桥城')"}}},
          "result":{"id":"result","parent":"use","children":["reply"],"message":{"id":"r","author":{"role":"tool","name":"fiction_lookup"},"content":{"content_type":"text","parts":["云桥城工具结果"]}}},
          "reply":{"id":"reply","parent":"result","children":[],"message":{"id":"f","author":{"role":"assistant"},"content":{"content_type":"text","parts":["虚构正文：星灯港的桥会移动。"]}}}
        }}
        """
        let raw = try JSONDecoder().decode(RawConversation.self, from: Data(json.utf8))
        let payload = try XCTUnwrap(ConversationImporter.makePayload(from: raw))
        let reply = try XCTUnwrap(payload.nodes.first { $0.id == "reply" })
        XCTAssertTrue(reply.content.contains("云桥城"), "正式导入器把内部链折进可见回复的扁平 content")
        XCTAssertNotNil(reply.segmentsData)
        try await assertCatalog(payload, hiddenQuery: "云桥城", expectedIDs: [], visibleQuery: "星灯港",
                                visibleID: "reply", visibleBody: "虚构正文：星灯港的桥会移动。")
    }

    func testIndexReceiptUsesCurrentNodeStructureRatherThanStoredFlattenedBody() async throws {
        var incoming = ImportedNodePayload(id: "current", role: "assistant", content: "云桥城旧索引污染",
                                           contentType: "segmented", createTime: nil, parentId: nil, childrenIds: [])
        incoming.segmentsData = try JSONEncoder().encode([MessageSegment.text("云桥城当前可见正文")])
        let payload = ImportedConversationPayload(id: "stale-original", title: "虚构旧索引", createTime: .distantPast,
                                                  updateTime: .distantPast, currentNodeId: incoming.id,
                                                  provider: "synthetic", nodes: [incoming])
        try await assertCatalog(payload, hiddenQuery: "旧索引污染", expectedIDs: [], visibleQuery: "云桥城",
                                visibleID: incoming.id, visibleBody: "云桥城当前可见正文")
    }

    func testRikkaHubImporterKeepsOnlyMessageTextOnBothPaths() async throws {
        let row = RikkaHubConversationRow(id: "rikka-original", assistantId: "synthetic-assistant", title: "虚构导入",
                                         createAt: nil, updateAt: nil, isPinned: false, customSystemPrompt: "",
                                         folderId: "", workspaceCwd: "")
        let message: [String: Any] = [
            "id": "reply", "role": "assistant", "createdAt": "2026-10-18T10:00:00",
            "parts": [
                ["type": "reasoning", "reasoning": "云桥城内部推演"],
                ["type": "tool", "toolCallId": "call", "toolName": "fiction_lookup", "input": "云桥城",
                 "output": [["type": "text", "text": "云桥城返回值"]]],
                ["type": "text", "text": "虚构正文：星灯港的桥会移动。"]
            ]
        ]
        var warnings = RikkaHubWarnings()
        let payload = try XCTUnwrap(RikkaHubPayloadBuilder.build(
            row: row, positions: [.init(messages: [message], selectIndex: 0)], assistantName: nil,
            timeZone: TimeZone(secondsFromGMT: 0)!, resolver: .init(stagingDir: root), warnings: &warnings))
        let reply = try XCTUnwrap(payload.nodes.first { $0.role == "assistant" })
        XCTAssertTrue(reply.content.contains("云桥城"))
        try await assertCatalog(payload, hiddenQuery: "云桥城", expectedIDs: [], visibleQuery: "星灯港",
                                visibleID: reply.id, visibleBody: "虚构正文：星灯港的桥会移动。")
    }

    func testKelivoImporterKeepsOnlyMessageTextOnBothPaths() async throws {
        let json = """
        {"version":1,"conversations":[{"id":"kelivo-original","title":"虚构导入","messageIds":["reply"]}],
         "messages":[{"id":"reply","conversationId":"kelivo-original","role":"assistant",
           "timestamp":"2026-10-18T10:00:00Z","parts":[
             {"kind":"reasoning","payload":"云桥城内部推演"},
             {"kind":"tool_call","payload":{"id":"call","name":"fiction_lookup","arguments":{"query":"云桥城"},"content":"云桥城返回值"}},
             {"kind":"text","payload":"虚构正文：星灯港的桥会移动。"}
           ]}]}
        """
        let parsed = try KelivoLegacyParser.parse(data: Data(json.utf8), timeZone: TimeZone(secondsFromGMT: 0)!)
        var stats = KelivoPayloadBuilder.Stats()
        let payload = try XCTUnwrap(KelivoPayloadBuilder.payload(try XCTUnwrap(parsed.conversations.first),
                                                                format: "synthetic", members: [], stats: &stats))
        let reply = try XCTUnwrap(payload.nodes.first { $0.role == "assistant" })
        XCTAssertTrue(reply.content.contains("云桥城"))
        try await assertCatalog(payload, hiddenQuery: "云桥城", expectedIDs: [], visibleQuery: "星灯港",
                                visibleID: reply.id, visibleBody: "虚构正文：星灯港的桥会移动。")
    }

    func testMissingCorruptEmptyAndUnknownStructureNeverFallsBackToFlattenedText() async throws {
        let visible = ImportedNodePayload(id: "visible", role: "user", content: "星灯港正文", contentType: "text",
                                          createTime: nil, parentId: nil, childrenIds: [])
        let missing = ImportedNodePayload(id: "missing", role: "assistant", content: "云桥城", contentType: "segmented",
                                          createTime: nil, parentId: nil, childrenIds: [])
        var bad = ImportedNodePayload(id: "bad", role: "assistant", content: "云桥城", contentType: "text",
                                     createTime: nil, parentId: nil, childrenIds: [])
        bad.segmentsData = Data("{broken".utf8)
        var empty = ImportedNodePayload(id: "empty", role: "user", content: "云桥城", contentType: "segmented",
                                       createTime: nil, parentId: nil, childrenIds: [])
        empty.segmentsData = Data("[]".utf8)
        var unknown = ImportedNodePayload(id: "unknown", role: "assistant", content: "云桥城", contentType: "text",
                                         createTime: nil, parentId: nil, childrenIds: [])
        unknown.segmentsData = Data("[{\"kind\":\"futureTool\",\"text\":\"云桥城\"}]".utf8)
        let payload = ImportedConversationPayload(id: "broken-original", title: "虚构边界", createTime: .distantPast,
                                                  updateTime: .distantPast, currentNodeId: visible.id, provider: "synthetic",
                                                  nodes: [missing, bad, empty, unknown, visible])
        try await assertCatalog(payload, hiddenQuery: "云桥城", expectedIDs: [], visibleQuery: "星灯港",
                                visibleID: visible.id, visibleBody: visible.content)
    }

    func testNativeThinkingAndToolsUseTheSameAllowlistWithoutReadingSideFields() throws {
        let segments: [MessageSegment] = [
            .text("星灯港正文【turn0search1】"), .thinking(text: "云桥城思考", signature: nil),
            .toolUse(id: "call", name: "云桥城工具", inputJSON: "云桥城输入", integrationName: nil, iconName: nil),
            .toolResult(toolUseId: "call", text: "云桥城结果", isError: false, integrationName: nil),
            .attachment(name: "云桥城附件", type: nil, extractedContent: "云桥城提取文字"),
            .audioRef(name: "云桥城音频", mime: "audio/mp4", path: "synthetic.m4a", duration: nil, script: "云桥城脚本")
        ]
        var incoming = ImportedNodePayload(id: "native", role: "assistant", content: "云桥城旧扁平正文", contentType: "text",
                                           createTime: nil, parentId: nil, childrenIds: [])
        incoming.segmentsData = try JSONEncoder().encode(segments)
        let node = makeImportedNode(incoming, conversationId: "native-original", profileId: pid)
        node.ccThinking = "云桥城旁路思考"
        node.thinkingSummary = "云桥城摘要"
        node.toolSummaries = ["call": "云桥城工具摘要"]
        node.sourceMetadata = Data("{\"text\":\"云桥城源元数据\"}".utf8)
        XCTAssertEqual(CatalogOriginalText.body(of: node), "星灯港正文")
        node.segmentsData = try JSONEncoder().encode([MessageSegment.thinking(text: "云桥城", signature: nil)])
        XCTAssertEqual(CatalogOriginalText.body(of: node), "")
        node.content = "星灯港正文"
        node.segmentsData = try JSONEncoder().encode([MessageSegment.audioRef(
            name: "voice", mime: "audio/mp4", path: "synthetic.m4a", duration: nil, script: "云桥城脚本")])
        XCTAssertEqual(CatalogOriginalText.body(of: node), "星灯港正文", "原生助手只挂语音时正文仍在 content")
        node.contentType = "segmented"
        XCTAssertEqual(CatalogOriginalText.body(of: node), "", "结构化音频不是取回扁平正文的通行证")
    }

    func testLegacyKnownThinkingBoundariesAndUnrecoverableUnmarkedToolText() {
        let node = MessageNode(id: "legacy", role: "assistant", content: "", contentType: "text", createTime: nil,
                               parentId: nil, childrenIds: [], conversationId: "legacy-original", profileId: pid)
        for role in ["assistant", "user"] {
            node.role = role
            for content in ["<<<THINK>>>云桥城<<</THINK>>>星灯港正文",
                            "[THINKING]云桥城[/THINKING]星灯港正文",
                            " <think>云桥城</think>星灯港正文"] {
                node.content = content
                XCTAssertEqual(CatalogOriginalText.body(of: node), "星灯港正文")
            }
            for content in ["<<<THINK>>>云桥城", "[thinking]云桥城", "<think>云桥城",
                            "星灯港<<</THINK>>>云桥城", "[thinking]嵌套[thinking]云桥城[/thinking]"] {
                node.content = content
                XCTAssertEqual(CatalogOriginalText.body(of: node), "")
            }
        }
        node.content = "虚构正文引用 <think> 标签"
        XCTAssertEqual(CatalogOriginalText.body(of: node), node.content, "正文中间的标签不猜测")
        node.content = "无边界的云桥城工具返回值"
        node.sourceMetadata = Data("{\"rikkahub\":{\"usage\":{\"totalTokens\":1}}}".utf8)
        XCTAssertEqual(CatalogOriginalText.body(of: node), node.content, "来源名和用量不能恢复丢失的正文/工具边界")
        node.role = "tool"
        XCTAssertEqual(CatalogOriginalText.body(of: node), "")
    }

    private func assertCatalog(_ payload: ImportedConversationPayload, hiddenQuery: String, expectedIDs: Set<String>,
                               visibleQuery: String, visibleID: String, visibleBody: String) async throws {
        let context = ModelContext(container)
        context.insert(makeImportedConversation(payload, profileId: pid))
        for incoming in payload.nodes {
            context.insert(makeImportedNode(incoming, conversationId: payload.id, profileId: pid))
        }
        try context.save()
        let store = try SearchIndexStore.open(at: root.appendingPathComponent("search.sqlite"))
        try store.apply(upserts: payload.nodes.map {
            .init(nodeId: $0.id, conversationId: payload.id, profileId: pid, role: $0.role, created: $0.createTime,
                  trashed: false, body: ContentCleaner.visibleText($0.content, isUser: $0.role == "user", cached: false), identifierKey: nil)
        }, epoch: store.epoch)
        for index in [nil, store] {
            let hidden = await SearchService.catalogContent(terms: [hiddenQuery], profileId: pid, container: container, index: index)
            XCTAssertEqual(Set(hidden.map(\.nodeId)), expectedIDs, "index=\(index != nil)：内部内容不得变成原文命中")
            let visible = await SearchService.catalogContent(terms: [visibleQuery], profileId: pid, container: container, index: index)
            XCTAssertEqual(visible.map(\.nodeId), [visibleID], "index=\(index != nil)：混合消息中的真实正文必须保留")
            XCTAssertEqual(visible.first?.body, visibleBody, "index=\(index != nil)：返回正文不能携带工具、思考或附件提取内容")
        }
    }
}
