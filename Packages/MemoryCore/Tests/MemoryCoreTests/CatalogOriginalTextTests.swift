import XCTest
@testable import MemoryCore

final class CatalogOriginalTextTests: XCTestCase {
    private func message(_ role: String, _ content: String, contentType: String = "text",
                         segments: [ConversationSegment]? = nil) -> ConversationMessage {
        ConversationMessage(id: "n", conversationId: "c", role: role, content: content,
                            segments: segments, contentType: contentType)
    }

    func testOnlyTextSegmentsFormTheBody() {
        let node = message("assistant", "旧扁平正文",
                           segments: [.text("甲"), .other, .text("乙")])
        XCTAssertEqual(CatalogOriginalText.body(of: node), "甲\n\n乙")
    }

    func testAudioRefOnlyAssistantKeepsFlatContent() {
        XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", "星灯港正文", segments: [.audioRef])), "星灯港正文")
        XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", "星灯港正文", contentType: "segmented",
                                                           segments: [.audioRef])), "",
                       "结构化音频不是取回扁平正文的通行证")
    }

    func testUnreadableStructuredBodyNeverFallsBackToFlatContent() {
        // app 侧把「segmentsData 有值却解不开」映射成空分段，口径与 nil 不同
        XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", "云桥城", segments: [])), "")
        XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", "云桥城", contentType: "segmented")), "")
        XCTAssertEqual(CatalogOriginalText.body(of: message("tool", "云桥城")), "")
    }

    func testThinkingMarkersAreStripped() {
        for content in ["<<<THINK>>>云桥城<<</THINK>>>星灯港正文",
                        "[THINKING]云桥城[/THINKING]星灯港正文",
                        " <think>云桥城</think>星灯港正文"] {
            XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", content)), "星灯港正文")
            XCTAssertEqual(CatalogOriginalText.body(of: message("user", content)), "星灯港正文")
        }
        for content in ["<<<THINK>>>云桥城", "[thinking]云桥城", "<think>云桥城"] {
            XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", content)), "")
        }
        XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", "虚构正文引用 <think> 标签")),
                       "虚构正文引用 <think> 标签")
    }

    func testCleanerStillRemovesAnnotations() {
        XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", "改写前的正文【12†L1-L2】还带引用")), "改写前的正文还带引用")
        XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", "正文【turn0search3】")), "正文")
    }

    /// `body(of:cacheKey:)`：同一缓存键、源串变了要重算（`hit.source == text`），与不缓存版输出一致
    func testCacheKeyOverloadRecomputesWhenSourceChanges() {
        let key = "node-\(UUID().uuidString)"
        XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", "改写前的正文【12†L1-L2】还带引用"), cacheKey: key),
                       "改写前的正文还带引用")
        XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", "改写后的正文，没有标记"), cacheKey: key),
                       "改写后的正文，没有标记")
        XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", "又改了一次【turn0search3】"), cacheKey: key),
                       "又改了一次")
        XCTAssertEqual(CatalogOriginalText.body(of: message("assistant", "改写前的正文【12†L1-L2】还带引用")),
                       "改写前的正文还带引用", "两条重载输出一致")
    }

    /// cacheKey 规矩：键相同但源串变了要重算（`hit.source == text`）
    func testSameCacheKeyDifferentSourceRecomputes() {
        let key = "node-\(UUID().uuidString)"
        XCTAssertEqual(ContentCleaner.clean("改写前的正文【12†L1-L2】还带引用", cacheKey: key), "改写前的正文还带引用")
        XCTAssertEqual(ContentCleaner.clean("改写后的正文，没有标记", cacheKey: key), "改写后的正文，没有标记")
        XCTAssertEqual(ContentCleaner.clean("又改了一次【turn0search3】", cacheKey: key), "又改了一次")
        XCTAssertEqual(ContentCleaner.visibleText("[thinking]云[/thinking]星灯港", isUser: false, cacheKey: key), "星灯港")
        XCTAssertEqual(ContentCleaner.extractThinking(from: "[thinking]云[/thinking]星灯港").thinking, "云")
    }
}
