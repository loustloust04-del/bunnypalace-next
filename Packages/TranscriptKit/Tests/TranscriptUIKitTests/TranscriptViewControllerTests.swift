#if canImport(UIKit)
import UIKit
import XCTest
import TranscriptCore
@testable import TranscriptUIKit

/// 列表这层只是引擎的执行器。这里验的是「执行得对」：系统列表里每个 cell 的位置、滚动位置，
/// 和引擎里那一份逐项相同。保位规则本身在 TranscriptCoreTests 里验。
@MainActor
final class TranscriptViewControllerTests: XCTestCase {
    private struct Block: TranscriptRowRenderer {
        let height: CGFloat
        let reuseIdentifier = "block"
        func height(width: CGFloat) -> CGFloat { height }
        @MainActor func makeView() -> UIView { UIView() }
        @MainActor func configure(_ view: UIView, width: CGFloat) { view.backgroundColor = .systemGray }
    }

    private func row(_ id: String, _ height: CGFloat, version: Int = 0) -> TranscriptRow {
        TranscriptRow(id: id, version: version, gapBefore: 10, estimatedHeight: 50, renderer: Block(height: height))
    }

    private func makeController(rows: [TranscriptRow]) async throws -> TranscriptViewController {
        let controller = TranscriptViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        controller.setInsets(start: 90, end: 60)
        controller.setRows(rows)
        try await settle(controller)
        return controller
    }

    /// 等后台量高度的结果都回来
    private func settle(_ controller: TranscriptViewController) async throws {
        for _ in 0..<200 {
            let layout = controller.engine.layout
            if layout.rows.indices.allSatisfy({ layout.height(at: $0).tier != .estimated }) {
                controller.view.layoutIfNeeded()
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("高度 2 秒内没量完")
    }

    /// 等动画（滑入、键盘滑动）做到头。超载的机器上动画回报会晚，所以按条件等，不按固定时长
    private func wait(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                      until condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("5 秒内没等到：\(what)", file: file, line: line)
    }

    private func assertMatchesEngine(_ controller: TranscriptViewController, file: StaticString = #filePath, line: UInt = #line) {
        let scroll = controller.scrollView
        let layout = controller.engine.layout
        XCTAssertEqual(scroll.contentSize.height, layout.contentLength, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(scroll.contentOffset.y, controller.engine.offset, accuracy: 0.01, "位置和引擎的那份不一致", file: file, line: line)
        guard let collection = scroll as? UICollectionView else { return XCTFail("不是 collection view", file: file, line: line) }
        XCTAssertFalse(collection.indexPathsForVisibleItems.isEmpty, file: file, line: line)
        for indexPath in collection.indexPathsForVisibleItems {
            guard let cell = collection.cellForItem(at: indexPath) else { continue }
            let expected = layout.frame(at: indexPath.item)
            XCTAssertEqual(cell.frame.minY, expected.minY, accuracy: 0.01, "第 \(indexPath.item) 行", file: file, line: line)
            XCTAssertEqual(cell.frame.height, expected.height, accuracy: 0.01, "第 \(indexPath.item) 行", file: file, line: line)
        }
    }

    func testOpensPinnedToNewestWithMeasuredHeights() async throws {
        let controller = try await makeController(rows: (0..<200).map { row("r\($0)", CGFloat(60 + $0 % 7 * 20)) })
        XCTAssertEqual(controller.scrollView.contentOffset.y, -90, "打开就在最新消息：位置 = 负的起点内缩")
        XCTAssertTrue(controller.engine.isFollowing)
        assertMatchesEngine(controller)
    }

    func testJumpThenGrowthBelowKeepsWhatIsOnScreen() async throws {
        var rows = (0..<200).map { row("r\($0)", 100) }
        let controller = try await makeController(rows: rows)

        controller.submit(.scrollToRow(id: "r50", alignment: .center, animated: false))
        controller.view.layoutIfNeeded()
        XCTAssertFalse(controller.engine.isFollowing)
        assertMatchesEngine(controller)

        let collection = try XCTUnwrap(controller.scrollView as? UICollectionView)
        let index = try XCTUnwrap(controller.engine.layout.index(of: "r50"))
        let before = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: index, section: 0))).frame.minY - collection.contentOffset.y

        rows[0] = row("r0", 400, version: 1)          // 屏幕外最新的一行长高了 300
        controller.setRows(rows)
        try await settle(controller)

        let after = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: index, section: 0))).frame.minY - collection.contentOffset.y
        XCTAssertEqual(after, before, accuracy: 0.01, "正在看的那一行在屏幕上的位置没动")
        assertMatchesEngine(controller)
    }

    func testNewMessageWhileFollowingStaysPinned() async throws {
        var rows = (0..<30).map { row("r\($0)", 100) }
        let controller = try await makeController(rows: rows)
        rows.insert(row("new", 140), at: 0)
        controller.setRows(rows)
        XCTAssertEqual(controller.engine.offset, -90, "引擎里的位置一直钉在最新消息")
        // 新行先按估的高度（50）插进来，量出真高度（140）以后多出来的 90 先藏在屏幕外、再滑进来
        try await settle(controller)
        try await wait("滑入做完") { controller.scrollView.contentOffset.y == -90 }
        assertMatchesEngine(controller)
    }

    func testKeyboardPadSlidesAndFinishes() async throws {
        let controller = try await makeController(rows: (0..<30).map { row("r\($0)", 100) })
        let motion = TranscriptEngine.KeyboardMotion(duration: 0.05, curve: 7)
        controller.submit(.setLeadingPad(300, reason: .keyboard(motion)))
        XCTAssertEqual(controller.engine.layout.leadingPad, 300)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.scrollView.contentOffset.y, -90, accuracy: 0.01, "滑完回到最新消息")
        assertMatchesEngine(controller)

        controller.submit(.setLeadingPad(0, reason: .keyboard(motion)))
        XCTAssertEqual(controller.engine.layout.leadingPad, 300, "收起：滑的过程中垫块还留着")
        try await wait("动画做完的回报到了，垫块塌掉") { controller.engine.layout.leadingPad == 0 }
        XCTAssertEqual(controller.scrollView.contentOffset.y, -90, accuracy: 0.01)
        assertMatchesEngine(controller)
    }
}
#endif
