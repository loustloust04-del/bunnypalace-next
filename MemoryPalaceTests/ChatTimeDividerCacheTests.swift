import XCTest
@testable import 记忆花园

/// 分割线按路径缓存（#027）：同一批节点复用，路径一变就重算且结果等于直接算
final class ChatTimeDividerCacheTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func node(_ id: String, hours: Double?) -> MessageNode {
        MessageNode(id: id, role: "user", content: id, contentType: "text",
                    createTime: hours.map { base.addingTimeInterval($0 * 3600) },
                    parentId: nil, childrenIds: [], conversationId: "c")
    }

    private func direct(_ path: [MessageNode]) -> [String: Date] {
        ChatTimeDivider.dividers(for: path.map { ($0.id, $0.createTime) })
    }

    func testSameNodesReuseResult() {
        let path = [node("a", hours: 0), node("b", hours: 1), node("c", hours: 5)]
        var cache = ChatTimeDividerCache()
        XCTAssertEqual(cache.dividers(for: path), direct(path))
        XCTAssertEqual(cache.builds, 1)
        XCTAssertEqual(cache.dividers(for: path), direct(path))
        XCTAssertEqual(cache.dividers(for: Array(path)), direct(path), "重新拼出来的数组、节点没换也算命中")
        XCTAssertEqual(cache.builds, 1)
    }

    func testPathChangesRebuild() {
        let a = node("a", hours: 0), b = node("b", hours: 1), c = node("c", hours: 5), d = node("d", hours: 9)
        var cache = ChatTimeDividerCache()
        var builds = 0
        for path in [[a, b, c], [a, b, c, d], [a, c, d], [a, d, c], [a, b, node("c", hours: 2)], []] {
            XCTAssertEqual(cache.dividers(for: path), direct(path), path.map(\.id).joined())
            builds += 1
            XCTAssertEqual(cache.builds, builds, "追加 / 删除 / 换顺序 / 同 id 换了节点都要重算")
        }
    }

    func testResetForcesRebuild() {
        let path = [node("a", hours: 0), node("b", hours: 4)]
        var cache = ChatTimeDividerCache()
        _ = cache.dividers(for: path)
        cache.reset()
        XCTAssertEqual(cache.dividers(for: path), direct(path))
        XCTAssertEqual(cache.builds, 2, "reset 后同一批节点也重算")
    }

    func testResetDropsStrongReferences() {
        var cache = ChatTimeDividerCache()
        weak var released: MessageNode?
        autoreleasepool {
            let path = [node("a", hours: 0)]
            released = path[0]
            _ = cache.dividers(for: path)
        }
        XCTAssertNotNil(released, "缓存持有")
        autoreleasepool { cache.reset() }
        XCTAssertNil(released, "reset 后放掉")
    }

    func testEmptyPathNeedsNoBuild() {
        var cache = ChatTimeDividerCache()
        XCTAssertEqual(cache.dividers(for: []), [:])
        XCTAssertEqual(cache.builds, 0)
    }
}
