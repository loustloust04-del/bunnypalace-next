import XCTest
import SwiftData
@testable import 记忆花园

/// 修复第一刀·刀2：失效记忆按时间聚批（同一分钟 ≥3 条 = 一批），复活语义。
final class MemoryRevivalTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let pid = "xctest-revival"
    let base = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: Memory.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func mem(_ content: String, deadAt offset: TimeInterval?, pinned: Bool = false) -> Memory {
        let m = Memory(content: content, category: "fact", keywords: [], profileId: pid, isUserExplicit: pinned)
        m.supersededAt = offset.map { base.addingTimeInterval($0) }
        context.insert(m)
        return m
    }

    func testSameMinuteThreeIsOneBatch() {
        let ms = [mem("a", deadAt: 0), mem("b", deadAt: 1), mem("c", deadAt: 2)]
        let (batches, scattered) = MemoryRevival.group(ms)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].memories.count, 3)
        XCTAssertEqual(batches[0].start, base)
        XCTAssertTrue(scattered.isEmpty)
    }

    func testTwoIsScattered() {
        let (batches, scattered) = MemoryRevival.group([mem("a", deadAt: 0), mem("b", deadAt: 5)])
        XCTAssertTrue(batches.isEmpty)
        XCTAssertEqual(scattered.count, 2)
    }

    func testClustersSplitAcrossWindow() {
        let ms = [mem("a", deadAt: 0), mem("b", deadAt: 30), mem("c", deadAt: 59),
                  mem("d", deadAt: 3600), mem("e", deadAt: 3601), mem("f", deadAt: 3602),
                  mem("g", deadAt: 7200)]
        let (batches, scattered) = MemoryRevival.group(ms)
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches.first?.start, base.addingTimeInterval(3600), "新批在前")
        XCTAssertEqual(scattered.map(\.content), ["g"])
    }

    func testActiveMemoriesExcluded() {
        let ms = [mem("活的", deadAt: nil), mem("a", deadAt: 0), mem("b", deadAt: 1), mem("c", deadAt: 2)]
        let (batches, scattered) = MemoryRevival.group(ms)
        XCTAssertEqual(batches.first?.memories.count, 3)
        XCTAssertFalse((batches.flatMap(\.memories) + scattered).contains { $0.content == "活的" })
    }

    func testReviveClearsSupersededAt() {
        let ms = [mem("a", deadAt: 0), mem("b", deadAt: 1)]
        MemoryRevival.revive(ms)
        XCTAssertTrue(ms.allSatisfy { $0.supersededAt == nil })
    }
}
