import XCTest
import CoreGraphics
#if PAGE2_CORE_FIXTURE
@testable import Page2Core
#else
@testable import 记忆花园
#endif

final class Page2FolderClosingTests: XCTestCase {
    func testClosingMatchesObservedNativePanelSizes() {
        let samples: [(time: Double, width: Double, height: Double)] = [
            (0.065894534, 243.333333333, 272.000000000),
            (0.104228534, 182.000000000, 200.666666667),
            (0.160894534, 124.000000000, 132.000000000),
            (0.252561534, 82.666666667, 83.333333333),
            (0.437561534, 69.333333333, 69.333333333)
        ]
        for sample in samples {
            let remaining = Page2FolderClosing.remaining(sample.time / Page2FolderClosing.duration)
            XCTAssertEqual(68 + (334.666666667 - 68) * remaining, sample.width, accuracy: 4)
            XCTAssertEqual(69.333333333 + (377.333333333 - 69.333333333) * remaining, sample.height, accuracy: 4)
        }
    }
    func testClosingMovesEarlyAndFinishesWithoutOvershoot() {
        let values = (0...100).map { Page2FolderClosing.remaining(Double($0) / 100) }
        XCTAssertEqual(values.first, 1)
        XCTAssertEqual(values.last, 0)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 >= $1 })
        XCTAssertLessThan(Page2FolderClosing.remaining(0.25), 0.4)
        XCTAssertEqual(Page2FolderClosing.remaining(-1), 1)
        XCTAssertEqual(Page2FolderClosing.remaining(2), 0)
    }
    func testFolderEntryKeepsDockApproachOpenUntilIconEntersPanel() {
        let panel = CGRect(x: 50, y: 280, width: 340, height: 380)
        var entry = Page2FolderEntry(origin: CGPoint(x: 120, y: 840))
        for point in [CGPoint(x: 120, y: 840), CGPoint(x: 122, y: 815), CGPoint(x: 160, y: 730)] {
            for _ in 0..<120 { XCTAssertTrue(entry.contains(point, panel: panel)) }
        }
        XCTAssertFalse(entry.entered)
        XCTAssertTrue(entry.contains(CGPoint(x: 160, y: 640), panel: panel))
        XCTAssertTrue(entry.entered)
        XCTAssertFalse(entry.contains(CGPoint(x: 160, y: 730), panel: panel))
    }

    func testFolderEntryAllowsLeavingAwayFromPanelBeforeEntry() {
        let panel = CGRect(x: 50, y: 280, width: 340, height: 380)
        var entry = Page2FolderEntry(origin: CGPoint(x: 120, y: 840))
        XCTAssertFalse(entry.contains(CGPoint(x: 120, y: 900), panel: panel))
        XCTAssertFalse(entry.contains(CGPoint(x: 420, y: 730), panel: panel))
    }

}
