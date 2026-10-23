import XCTest
@testable import 记忆花园

/// 第二刀 A1：档案不分冷热——钉住在前、其余按创建时间新→旧，已失效单列。
final class MemoryArchiveOrderTests: XCTestCase {

    private func mem(_ content: String, created: TimeInterval, pinned: Bool = false, superseded: TimeInterval? = nil) -> Memory {
        let m = Memory(content: content, category: "fact", profileId: "xctest-archive-order", isUserExplicit: pinned)
        m.createdAt = Date(timeIntervalSince1970: created)
        m.supersededAt = superseded.map { Date(timeIntervalSince1970: $0) }
        return m
    }

    func testPinnedFirstThenNewestAndSupersededSeparate() {
        let list = [mem("旧", created: 100), mem("新", created: 300), mem("钉住", created: 50, pinned: true),
                    mem("失效早", created: 200, superseded: 400), mem("失效晚", created: 210, superseded: 500)]
        let r = MemoryArchiveOrder.split(list)
        XCTAssertEqual(r.active.map(\.content), ["钉住", "新", "旧"])
        XCTAssertEqual(r.superseded.map(\.content), ["失效晚", "失效早"])
    }
}
