import XCTest
@testable import 记忆花园

/// #026：历史窗口只对窗口里的消息读附件。对照 = 改前的算法（全量物化 `buildAPIMessages(Int.max)` 再按同一个起点切），
/// 三种窗口（不超窗 / 滑动窗 / 摘要锚定）× 图片配额用满，逐字段相等；窗口外的附件不读（大附件计时）。
@MainActor
final class HistoryWindowMaterializeTests: XCTestCase {

    let pid = "xctest-history-window"
    private var savedDefaults: [String: Any?] = [:]
    private let keys = ["maxImagesToModel", "imageTranscriptionEnabled", "mem_master", "mem_content_summary"]

    override func setUp() {
        super.setUp()
        for k in keys { savedDefaults[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set(3, forKey: "maxImagesToModel")
        UserDefaults.standard.set(true, forKey: "imageTranscriptionEnabled")
        UserDefaults.standard.set(true, forKey: "mem_master")
        UserDefaults.standard.set(true, forKey: "mem_content_summary")
    }

    override func tearDown() {
        for k in keys {
            if let v = savedDefaults[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        FileLibraryStore.ListCache.forget(profileId: pid)
        try? FileManager.default.removeItem(at: FileLibraryStore.libraryRoot(profileId: pid).deletingLastPathComponent())
        FileLibraryStore.forgetSlug(profileId: pid)
        super.tearDown()
    }

    /// 长路径：普通往返、带图（部分有描述）、带文件、引用、卡片事件、工具轮、空正文 user（被过滤）
    private func makeVM(count: Int, fileBytes: Int = 16) -> (ConversationViewModel, String) {
        let vm = ConversationViewModel()
        vm.startDraftConversation(profileId: pid)
        let conv = vm.selectedConversation!
        var nodes: [MessageNode] = []
        for i in 0..<count {
            let role = i % 2 == 0 ? "user" : "assistant"
            let node = MessageNode(id: "n\(i)", role: role, content: role == "user" ? "问题 \(i)" : "<think>想</think>回答 \(i)",
                                   contentType: "text", createTime: Date(), parentId: nil, childrenIds: [],
                                   conversationId: conv.id, profileId: pid)
            if role == "user" {
                if i % 10 == 0 { node.content = "" }                          // 空正文 → 不进历史
                if i % 6 == 2 {
                    node.setSegments([.image(name: "img\(i).jpg", type: "图片", data: Data(repeating: UInt8(i % 255), count: 32))],
                                     conversationTitle: "t")
                    if i % 12 == 2 { node.setImageDesc("一张图 \(i)", for: "img\(i).jpg") }
                }
                if i % 8 == 4 {
                    node.setSegments([.fileData(name: "f\(i).bin", mime: "application/octet-stream",
                                                data: Data(repeating: 7, count: fileBytes))], conversationTitle: "t")
                }
                if i % 14 == 6 { node.replyQuote = "引用 \(i)" }
                if i % 16 == 8 { node.cardEventsData = try? JSONEncoder().encode([ChatCardEvent(text: "事件 \(i)")]) }
            } else if i % 9 == 3 {
                node.content = ""                                                  // tool-only assistant
                node.setSegments([.toolUse(id: "t\(i)", name: "fs_read", inputJSON: #"{"path":"a.md"}"#, integrationName: nil, iconName: nil)])
            }
            nodes.append(node)
        }
        vm.currentPath = nodes
        return (vm, conv.id)
    }

    private func assertSame(_ a: [ConversationViewModel.APIMessage], _ b: [ConversationViewModel.APIMessage],
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.map(\.id), b.map(\.id), file: file, line: line)
        XCTAssertEqual(a.map(\.role), b.map(\.role), file: file, line: line)
        XCTAssertEqual(a.map { Array($0.content.utf8) }, b.map { Array($0.content.utf8) }, file: file, line: line)
        // 发送契约：除了每次随机生成的 id，附件的每个字段 + 原始字节
        func wire(_ m: [ConversationViewModel.APIMessage]) -> [[String]] {
            m.map { $0.images.map { [$0.name, $0.kind.rawValue, $0.typeDescription, $0.extractedText, "\($0.byteCount)",
                                     $0.mimeType ?? "-", $0.imageData?.base64EncodedString() ?? "-",
                                     $0.fileData?.base64EncodedString() ?? "-", $0.storedRef ?? "-"] }.map { $0.joined(separator: "|") } }
        }
        XCTAssertEqual(wire(a), wire(b), file: file, line: line)
    }

    /// 不由被测函数生成的固定预期：窗口里引用头 / 卡片事件 / 工具摘要 / 旧图换描述 / 新图带原图 / 文件带字节都在
    func testWindowFixedExpectations() {
        let (vm, _) = makeVM(count: 300)
        let byId = Dictionary(uniqueKeysWithValues: vm.buildWindowedAPIMessages(depth: 40).map { ($0.id, $0) })
        XCTAssertEqual(byId["n286"]?.content, "> 引用 286\n\n问题 286")                                   // 286 % 14 == 6
        let cardEvent = ChatCardEventPrompt.prefix([ChatCardEvent(text: "事件 264")])                       // 264 % 16 == 8
        XCTAssertFalse(cardEvent.isEmpty)
        XCTAssertEqual(byId["n264"]?.content, cardEvent + "问题 264")
        XCTAssertEqual(byId["n295"]?.content, "<think>想</think>回答 295")                                 // 普通 assistant 原样
        // 273 % 9 == 3：工具轮——正文不再带前缀，调用挂成回合（#089 P0-b）；没有结果的补一个错误结果
        XCTAssertEqual(byId["n273"]?.content, "")
        XCTAssertEqual(byId["n273"]?.toolRounds.first?.calls.map(\.name), ["fs_read"])
        XCTAssertEqual(byId["n273"]?.toolRounds.first?.results.first?.text, ToolReplay.missingResultText)
        XCTAssertEqual(byId["n266"]?.content, "[图片: 一张图 266]\n问题 266")                              // 有描述的旧图换文字
        XCTAssertEqual(byId["n266"]?.images.count, 0)
        XCTAssertEqual(byId["n296"]?.images.first?.imageData, Data(repeating: UInt8(296 % 255), count: 32)) // 最近的图带原图
        XCTAssertEqual(byId["n292"]?.images.first?.fileData, Data(repeating: 7, count: 16))                // 292 % 8 == 4
        XCTAssertNil(byId["n290"], "空正文 user 不进历史")
        XCTAssertNil(byId["n10"], "窗口外")
    }

    func testNotOverWindowEqualsFull() {
        let (vm, _) = makeVM(count: 30)
        assertSame(vm.buildWindowedAPIMessages(depth: 40), vm.buildAPIMessages(maxMessages: .max))
    }

    func testSlidingWindowEqualsOldSlice() {
        let (vm, _) = makeVM(count: 300)
        for excluding in [nil, "n299", "n150"] as [String?] {
            let full = vm.buildAPIMessages(excluding: excluding, maxMessages: .max)
            XCTAssertGreaterThan(full.count, 40)
            assertSame(vm.buildWindowedAPIMessages(excluding: excluding, depth: 40), Array(full.suffix(40)))
            XCTAssertTrue(full.suffix(40).contains { !$0.images.isEmpty }, "窗口里要有附件，配额 / 描述规则才被覆盖")
        }
    }

    func testAnchoredWindowEqualsOldSlice() throws {
        let (vm, convId) = makeVM(count: 300)
        let fullCount = vm.buildAPIMessages(maxMessages: .max).count
        let covered = fullCount - 55                                               // 窗口 55：在 [depth, depth×2] 里 → 锚定
        SummaryFileStore.save(ContextSummary(summary: "摘要", coveredCount: covered, updatedAt: Date()),
                              conversationId: convId, profileId: pid, conversationTitle: "t")
        let start = try XCTUnwrap(ConversationViewModel.anchoredWindowStart(fullCount: fullCount, covered: covered, depth: 40))
        let windowed = vm.buildWindowedAPIMessages(depth: 40)
        XCTAssertEqual(windowed.count, 55)
        assertSame(windowed, Array(vm.buildAPIMessages(maxMessages: .max).dropFirst(start)))
    }

    func testBuildAPIMessagesDefaultSuffixUnchanged() {
        let (vm, _) = makeVM(count: 120)
        assertSame(vm.buildAPIMessages(), Array(vm.buildAPIMessages(maxMessages: .max).suffix(40)))
    }

    /// 窗口外的附件不读：每个用户消息挂一个 256KB 文件，全量要读 ~37MB，窗口只读最后 40 条里的
    func testOutsideWindowAttachmentsNotRead() {
        let (vm, _) = makeVM(count: 1200, fileBytes: 256 * 1024)
        func ms(_ block: () -> Void) -> Double {
            let t0 = CFAbsoluteTimeGetCurrent(); block(); return (CFAbsoluteTimeGetCurrent() - t0) * 1000
        }
        // 附件真的外置成了 ref（落盘失败会保留内联字节，那就不是在比读盘）
        let refCount = vm.currentPath.filter { ($0.segments ?? []).contains { if case .fileDataRef = $0 { return true }; return false } }.count
        XCTAssertGreaterThan(refCount, 100)
        _ = vm.buildAPIMessages(maxMessages: .max)                                  // 预热文件系统缓存，两边公平
        // 交错跑三轮取最小，避开一次调度抖动
        var full = Double.infinity, windowed = Double.infinity
        for _ in 0..<3 {
            windowed = min(windowed, ms { _ = vm.buildWindowedAPIMessages(depth: 40) })
            full = min(full, ms { _ = vm.buildAPIMessages(maxMessages: .max) })
        }
        print(String(format: "[HISTBENCH] nodes=1200 fullMaterialize=%.1fms windowed=%.1fms", full, windowed))
        XCTAssertLessThan(windowed, full / 3, "窗口版不该再读全路径的附件")
    }
}
