import XCTest
@testable import 记忆花园

/// #089 日志：伪造工具标记 / 没查就发复杂卡 / 缓存命中率
final class RequestBodyDiagTests: XCTestCase {

    func testFakeMarkers() {
        XCTAssertEqual(RequestBodyDiag.fakeMarkers(in: "〔我在本对话做过的文件操作〕\n· fs_read(a.md)\n好"), ["〔我在本对话做过的文件操作〕"])
        XCTAssertEqual(RequestBodyDiag.fakeMarkers(in: "〔系统记录：上一轮…〕"), ["〔系统记录"])
        XCTAssertTrue(RequestBodyDiag.fakeMarkers(in: "普通回复").isEmpty)
    }

    func testUncheckedCardKinds() {
        let text = "```card-dice\n{}\n```\n```card-chart\n{}\n```\n```card-chart\n{}\n```"
        XCTAssertEqual(RequestBodyDiag.uncheckedCardKinds(in: text, segments: nil), ["chart"], "四种静态卡不算，同种只记一次")
        let checked: [MessageSegment] = [.toolUse(id: "t", name: CardGuideTool.toolName, inputJSON: "{}", integrationName: nil, iconName: nil)]
        XCTAssertTrue(RequestBodyDiag.uncheckedCardKinds(in: text, segments: checked).isEmpty)
    }

    /// P2-c：坏卡（语言名对、JSON 解不开 / 缺字段）挑出来记日志
    func testMalformedCards() {
        let text = "```card-timer\n{\"id\":\"c-1\",\"title\":\"泡面\",\"seconds\":180}\n```\n```card-timer\n{坏的\n```\n```swift\nlet a = 1\n```"
        XCTAssertEqual(ChatCardExtractor.malformed(in: text), ["card-timer"])
        XCTAssertEqual(ChatCardExtractor.cards(in: text).count, 1)
    }

    @MainActor
    func testCacheHitMeter() {
        let meter = CacheHitMeter()
        XCTAssertNil(meter.record(conversationId: "c", usage: TokenUsage(inputTokens: 10, outputTokens: 1)), "没缓存字段不记")
        meter.record(conversationId: "c", usage: TokenUsage(inputTokens: 10, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 1000))
        let line = meter.record(conversationId: "c", usage: TokenUsage(inputTokens: 10, outputTokens: 1, cacheReadTokens: 3000, cacheWriteTokens: 0))
        XCTAssertEqual(line, "📦 缓存命中 最近 2 次：读 3000 / 写 1000（75%）")
    }
}
