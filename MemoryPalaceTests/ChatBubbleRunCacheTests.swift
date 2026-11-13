import XCTest
@testable import 记忆花园

final class ChatBubbleRunCacheTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func node(_ id: String, role: String = "assistant", hours: Double = 0) -> MessageNode {
        MessageNode(id: id, role: role, content: id, contentType: "text",
                    createTime: base.addingTimeInterval(hours * 3600),
                    parentId: nil, childrenIds: [], conversationId: "c")
    }

    private func layouts(_ cache: inout ChatBubbleRunCache, _ path: [MessageNode],
                         showsTime: Bool = false) -> [String: ChatBubbleRunCache.Layout] {
        let dividers = showsTime ? ChatTimeDivider.dividers(for: path.map { ($0.id, $0.createTime) }) : [:]
        return cache.layouts(for: path, dividers: dividers, includesTimeDividers: showsTime)
    }

    func testSenderRunsUseSmallGapsAndOnlyFinalTails() {
        let path = [node("a"), node("b"), node("c", role: "user"), node("d", role: "user"), node("e")]
        var cache = ChatBubbleRunCache()
        let result = layouts(&cache, path)
        XCTAssertEqual(result["a"], .init(spacingBefore: 0, hasTail: false))
        XCTAssertEqual(result["b"], .init(spacingBefore: 4, hasTail: true))
        XCTAssertEqual(result["c"], .init(spacingBefore: 16, hasTail: false))
        XCTAssertEqual(result["d"], .init(spacingBefore: 4, hasTail: true))
        XCTAssertEqual(result["e"], .init(spacingBefore: 16, hasTail: true))
    }

    func testAppendingSwitchingAndDeletingRestorePreviousTail() {
        let a = node("a"), b = node("b"), c = node("c"), user = node("user", role: "user")
        var cache = ChatBubbleRunCache()
        XCTAssertEqual(layouts(&cache, [a, b])["b"]?.hasTail, true)
        let appended = layouts(&cache, [a, b, c])
        XCTAssertEqual(appended["b"]?.hasTail, false)
        XCTAssertEqual(appended["c"], .init(spacingBefore: 4, hasTail: true))
        let branch = layouts(&cache, [a, user])
        XCTAssertEqual(branch["a"]?.hasTail, true)
        XCTAssertEqual(branch["user"], .init(spacingBefore: 16, hasTail: true))
        XCTAssertNil(branch["b"])
        XCTAssertEqual(layouts(&cache, [a]), ["a": .init(spacingBefore: 0, hasTail: true)])
        XCTAssertEqual(layouts(&cache, []), [:])
    }

    func testReplacingSameIDWithDifferentNodeInvalidatesGrouping() {
        let a = node("a"), b = node("b")
        var cache = ChatBubbleRunCache()
        XCTAssertEqual(layouts(&cache, [a, b])["a"]?.hasTail, false)
        let replacement = node("b", role: "user")
        let result = layouts(&cache, [a, replacement])
        XCTAssertEqual(result["a"]?.hasTail, true)
        XCTAssertEqual(result["b"], .init(spacingBefore: 16, hasTail: true))
    }

    func testSystemNoticesBreakSenderRuns() {
        let path = [node("a"), node("s1", role: "system"), node("s2", role: "system"), node("b")]
        var cache = ChatBubbleRunCache()
        let result = layouts(&cache, path)
        XCTAssertEqual(result["a"]?.hasTail, true)
        XCTAssertEqual(result["s1"]?.spacingBefore, 16)
        XCTAssertEqual(result["s2"]?.spacingBefore, 16)
        XCTAssertEqual(result["b"], .init(spacingBefore: 16, hasTail: true))
    }

    func testVisibleTimeDividerBreaksRunAndOwnsSpacing() {
        let path = [node("a"), node("b", hours: 2), node("c", hours: 5)]
        var cache = ChatBubbleRunCache()
        let visible = layouts(&cache, path, showsTime: true)
        XCTAssertEqual(visible["a"]?.hasTail, false)
        XCTAssertEqual(visible["b"], .init(spacingBefore: 4, hasTail: true))
        XCTAssertEqual(visible["c"], .init(spacingBefore: 0, hasTail: true))
        let hidden = layouts(&cache, path)
        XCTAssertEqual(hidden["b"]?.hasTail, false)
        XCTAssertEqual(hidden["c"], .init(spacingBefore: 4, hasTail: true))
        XCTAssertEqual(layouts(&cache, path, showsTime: true)["b"]?.hasTail, true)
    }

    func testStreamingContentDoesNotRebuildNeighborCache() {
        let path = [node("a"), node("b")]
        var cache = ChatBubbleRunCache()
        _ = layouts(&cache, path)
        path[1].content = "追加的流式正文"
        let result = layouts(&cache, Array(path))
        XCTAssertEqual(result["a"]?.hasTail, false)
        XCTAssertEqual(result["b"], .init(spacingBefore: 4, hasTail: true))
        XCTAssertEqual(cache.builds, 1)
    }

    func testResetReleasesOldProfileNodes() {
        var cache = ChatBubbleRunCache()
        weak var retained: MessageNode?
        autoreleasepool {
            let message = node("old-profile")
            retained = message
            _ = layouts(&cache, [message])
        }
        XCTAssertNotNil(retained)
        autoreleasepool { cache.reset() }
        XCTAssertNil(retained)
        XCTAssertEqual(layouts(&cache, [node("new-profile")]),
                       ["new-profile": .init(spacingBefore: 0, hasTail: true)])
    }
}
