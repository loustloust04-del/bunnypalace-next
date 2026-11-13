import XCTest
@testable import 记忆花园

/// 体检剩下的小 bug（plan-铲屎-小bug 刀 C）
final class SmallBugFixTests: XCTestCase {
    // L-B12
    func testSearchFailureTextHidesEchoedKeyAndQuery() {
        let error = WebSearchProviderError.http(401, #"{"error":"bad key sk-test-1234567890","url":"https://api.example.com/search?api_key=sk-test-1234567890"}"#)
        let text = WebSearchToolService.failureText(error, apiKey: "sk-test-1234567890")
        XCTAssertTrue(text.hasPrefix("搜索失败: HTTP 401"), text)
        XCTAssertFalse(text.contains("sk-test-1234567890"), text)
        XCTAssertFalse(text.contains("api_key="), text)
        XCTAssertEqual(WebSearchToolService.failureText(WebSearchProviderError.empty, apiKey: nil), "搜索失败: 搜索结果为空")
    }

    // L-B8
    func testExportChildrenMapAppendsOrphansInIdOrder() {
        func node(_ id: String, parent: String?, children: [String] = []) -> MessageNode {
            MessageNode(id: id, role: "assistant", content: id, contentType: "text", createTime: Date(),
                        parentId: parent, childrenIds: children, conversationId: "c", profileId: "p")
        }
        var map: [String: MessageNode] = ["root": node("root", parent: nil, children: ["kept"]), "kept": node("kept", parent: "root")]
        // 漏挂：parentId 指向 root，但 root.childrenIds 里没有
        for id in ["o7", "o2", "o9", "o1", "o5", "o3", "o8", "o4", "o6"] { map[id] = node(id, parent: "root") }
        XCTAssertEqual(MarkdownExporter.buildEffectiveChildrenMap(nodeMap: map)["root"],
                       ["kept", "o1", "o2", "o3", "o4", "o5", "o6", "o7", "o8", "o9"])
    }

    // D-B3
    func testStickerTiltIsStableAndInRange() {
        XCTAssertEqual(StickerTilt.angle(for: "sticker-abc"), StickerTilt.angle(for: "sticker-abc"))
        XCTAssertEqual(StickerTilt.angle(for: "a"), 2)
        for i in 0..<200 { XCTAssertTrue((-5.0...5.0).contains(StickerTilt.angle(for: "id-\(i)"))) }
    }

    // D-B7
    func testFrontmatterAcceptsFullWidthColon() {
        let fields = MarkdownFrontmatter.fields("---\ntitle: 甲\n别名：乙\n---\n正文")
        XCTAssertEqual(fields, [.init(key: "title", value: "甲"), .init(key: "别名", value: "乙")])
    }

    // D-B8
    func testTradingFrontmatterCloseMustBeWholeLine() {
        let md = "---\nticker: AAPL\n----\nrating: buy\n---\n# 正文"
        XCTAssertEqual(TradingStore.parseFrontmatter(md)["rating"], "buy")
        XCTAssertEqual(TradingStore.stripFrontmatter(md), "# 正文")
        XCTAssertEqual(TradingStore.stripFrontmatter("---\nticker: AAPL\n---"), "")
    }

    // UI-B2 / UI-S8
    #if os(macOS)
    func testMacSearchSkipsRowsThePageDoesNotShow() {
        let hidden: Set<String> = ["leaf-appear-liststyle", "leaf-appear-livebg", "leaf-appear-metalflowers"]
        for query in ["列表样式", "液态金属背景", "白色小花"] {
            XCTAssertFalse(SettingsSearchEntry.filtered(for: query).contains { hidden.contains($0.id) }, query)
        }
        for query in ["更新", "反馈"] {
            XCTAssertFalse(SettingsSearchEntry.filtered(for: query).contains { $0.id == "page-about" }, query)
        }
        XCTAssertTrue(SettingsSearchEntry.filtered(for: "版本").contains { $0.id == "page-about" })
    }
    #endif
}
