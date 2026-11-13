#if DEBUG
@testable import SwiftStreamingMarkdown
import XCTest

final class ParagraphLayoutProbeTests: XCTestCase {

  func testAllLinesInsideBoundsReportsNothing() {
    let lines: [(start: Int, maxY: CGFloat)] = [(0, 20), (12, 40.5), (24, 61)]
    XCTAssertEqual(ParagraphLayoutProbe.missingCount(lines: lines, laidOutEnd: 30, total: 30, height: 61), 0)
  }

  func testLastLineBelowBoundsCountsFromItsStart() {
    let lines: [(start: Int, maxY: CGFloat)] = [(0, 20), (12, 40.5), (24, 61)]
    // 视图只给了 60.67（像素取整缩了 1/3pt）：最后一行（24 起）排不下 → 少 6 字
    XCTAssertEqual(ParagraphLayoutProbe.missingCount(lines: lines, laidOutEnd: 30, total: 30, height: 60.67), 6)
  }

  func testFragmentsStoppingEarlyCountsTheTail() {
    let lines: [(start: Int, maxY: CGFloat)] = [(0, 20), (12, 40.5)]
    XCTAssertEqual(ParagraphLayoutProbe.missingCount(lines: lines, laidOutEnd: 24, total: 30, height: 60.67), 6)
  }

  func testFloatNoiseWithinToleranceIsIgnored() {
    let lines: [(start: Int, maxY: CGFloat)] = [(0, 61.005)]
    XCTAssertEqual(ParagraphLayoutProbe.missingCount(lines: lines, laidOutEnd: 10, total: 10, height: 61), 0)
  }
}
#endif
