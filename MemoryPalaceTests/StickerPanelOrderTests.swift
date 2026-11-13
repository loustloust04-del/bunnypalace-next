import XCTest
@testable import 记忆花园

final class StickerPanelOrderTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func testPinnedFirstThenRecentThenOriginalOrder() {
        var order = StickerPanelOrder()
        order.touch(c)
        order.touch(b)          // recent: b, c
        order.togglePin(d)      // pinned: d
        XCTAssertEqual(order.sorted([a, b, c, d]) { $0 }, [d, b, c, a])
    }

    func testPinnedItemNotRepeatedByRecent() {
        var order = StickerPanelOrder()
        order.togglePin(a)
        order.touch(a)
        order.touch(b)
        XCTAssertEqual(order.sorted([c, b, a]) { $0 }, [a, b, c])
    }

    func testTogglePinTwiceUnpins() {
        var order = StickerPanelOrder()
        order.togglePin(a)
        XCTAssertTrue(order.isPinned(a))
        order.togglePin(a)
        XCTAssertFalse(order.isPinned(a))
        XCTAssertEqual(order.sorted([b, a]) { $0 }, [b, a])
    }

    func testTouchMovesToFrontWithoutDuplicates() {
        var order = StickerPanelOrder()
        order.touch(a); order.touch(b); order.touch(a)
        XCTAssertEqual(order.recent, [a, b])
    }

    func testPruneDropsDeletedIds() {
        var order = StickerPanelOrder()
        order.togglePin(a); order.touch(b); order.touch(c)
        order.prune(keeping: [c])
        XCTAssertEqual(order.pinned, [])
        XCTAssertEqual(order.recent, [c])
    }

    func testManualOrderWinsAndNewItemsGoFirst() {
        var order = StickerPanelOrder()
        order.togglePin(a); order.touch(b)
        order.setManual([c, a, b])
        XCTAssertEqual(order.pinned, [])
        XCTAssertEqual(order.sorted([a, b, c, d]) { $0 }, [d, c, a, b])
        order.touch(b)
        XCTAssertEqual(order.sorted([a, b, c]) { $0 }, [c, a, b], "手动排过后贴一次不再自动挪")
        order.togglePin(b)
        XCTAssertEqual(order.sorted([a, b, c]) { $0 }, [b, c, a], "手动排过后置顶 = 挪到最前")
    }

    func testOldFileWithoutManualStillDecodes() throws {
        let json = #"{"pinned":[],"recent":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(StickerPanelOrder.self, from: Data(json.utf8)), StickerPanelOrder())
    }

    func testSaveAndLoadRoundTrip() {
        var order = StickerPanelOrder()
        order.togglePin(a); order.touch(b)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("panel-order-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        order.save(to: url)
        XCTAssertEqual(StickerPanelOrder.load(from: url), order)
        XCTAssertEqual(StickerPanelOrder.load(from: url.appendingPathExtension("missing")), StickerPanelOrder())
    }
}
