import XCTest
@testable import 记忆花园

/// 浮窗吸边代数：吸屏界（格线）/ 吸邻窗起边 / 贴邻窗终边留缝 / 缩放只动在动的边 / 钳制。
/// 几何基线：1194×834 浮窗模式，令牌 136/300 → 左格线 192、右格线 922（1194 − (28+136+28+52+28)）。
@MainActor
final class PanelSnapTests: XCTestCase {
    static let suiteName = "xctest-panel-snap"
    var defaults: UserDefaults!
    var layout: IPadPanelLayout!
    let land = CGSize(width: 1194, height: 834)
    typealias F = IPadPanelLayout.WindowFrame

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        layout = IPadPanelLayout(defaults: defaults)
        layout.gridSpecOverride = WidgetGridSpec(small: 136, medium: 300)
        layout.mode = .floating
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    func testFloatingGridLanes() {
        XCTAssertEqual(layout.leftInset(in: land), 192)
        XCTAssertEqual(layout.rightInset(in: land), 272)
    }

    /// 起边离左格线 8pt → 吸到 192 并画竖辅助线
    func testMoveSnapsToScreenLane() {
        layout.open("a")
        let r = layout.magnetize(move: F(x: 200, y: 100, w: 300, h: 300), id: "a", in: land)
        XCTAssertEqual(r.x, 192)
        XCTAssertEqual(r.y, 100)
        XCTAssertTrue(layout.snapGuides.contains(.init(vertical: true, at: 192)))
    }

    /// 起边对齐邻窗起边
    func testMoveSnapsToNeighborStart() {
        layout.open("a"); layout.open("b")
        layout.frames["a"] = F(x: 300, y: 100, w: 300, h: 300)
        let r = layout.magnetize(move: F(x: 305, y: 500, w: 200, h: 200), id: "b", in: land)
        XCTAssertEqual(r.x, 300)
        XCTAssertEqual(r.y, 500)
        XCTAssertTrue(layout.snapGuides.contains(.init(vertical: true, at: 300)))
    }

    /// 贴邻窗终边留 10pt 缝：辅助线画在邻窗那条边上
    func testMoveSnapsToNeighborEndWithGap() {
        layout.open("a"); layout.open("b")
        layout.frames["a"] = F(x: 300, y: 100, w: 300, h: 300)
        let r = layout.magnetize(move: F(x: 612, y: 500, w: 200, h: 200), id: "b", in: land)
        XCTAssertEqual(r.x, 610)
        XCTAssertTrue(layout.snapGuides.contains(.init(vertical: true, at: 600)))
    }

    /// 离谁都远：不动、不画线
    func testMoveFarFromEverythingDoesNothing() {
        layout.open("a")
        let f = F(x: 400, y: 300, w: 200, h: 200)
        let r = layout.magnetize(move: f, id: "a", in: land)
        XCTAssertEqual(r, f)
        XCTAssertTrue(layout.snapGuides.isEmpty)
    }

    /// 缩放只动在动的那条边：拖右边贴邻窗起边留缝 → 只改宽，x / 高不动（吸完 240 正好不低于最小宽）
    func testResizeSnapsOnlyMovingEdge() {
        layout.open("a"); layout.open("b")
        layout.frames["a"] = F(x: 300, y: 100, w: 300, h: 300)
        let r = layout.magnetize(resize: F(x: 50, y: 100, w: 235, h: 200),
                                 movingEdges: [.trailing, .bottom], id: "b", in: land)
        XCTAssertEqual(r.w, 240)
        XCTAssertEqual(r.x, 50)
        XCTAssertEqual(r.h, 200)
        XCTAssertTrue(layout.snapGuides.contains(.init(vertical: true, at: 300)))
    }

    /// 吸过去会低于最小尺寸 → 不吸
    func testResizeRefusesSnapBelowMinimum() {
        layout.open("a"); layout.open("b")
        layout.frames["a"] = F(x: 300, y: 100, w: 300, h: 300)
        let r = layout.magnetize(resize: F(x: 296, y: 100, w: 242, h: 200),
                                 movingEdges: [.leading, .bottom], id: "b", in: land)
        XCTAssertEqual(r.x, 296)
        XCTAssertEqual(r.w, 242)
    }

    /// mac 拖一条边（A2a-4，astra F12）：只那一条边参与——右边贴邻窗留缝吸上去，底边离邻窗顶 6pt 也**不**吸
    func testResizeSingleEdgeIgnoresOtherAxis() {
        layout.open("a"); layout.open("b")
        layout.frames["a"] = F(x: 300, y: 306, w: 300, h: 300)
        let r = layout.magnetize(resize: F(x: 50, y: 100, w: 235, h: 200),
                                 movingEdges: [.trailing], id: "b", in: land)
        XCTAssertEqual(r.w, 240)
        XCTAssertEqual(r.h, 200)
        XCTAssertEqual(r.y, 100)
        XCTAssertEqual(layout.snapGuides, [.init(vertical: true, at: 300)])
        // 只拖底边：横轴不吸，底贴邻窗顶留缝 → 高 196
        let r2 = layout.magnetize(resize: F(x: 50, y: 100, w: 235, h: 200),
                                  movingEdges: [.bottom], id: "b", in: land)
        XCTAssertEqual(r2.w, 235)
        XCTAssertEqual(r2.h, 196)
        XCTAssertEqual(layout.snapGuides, [.init(vertical: false, at: 306)])
    }

    /// 钳制：尺寸不低于下限、不超可用区；拖出屏外时标题栏留 80pt 可见
    func testClamped() {
        let r = layout.clamped(F(x: -1000, y: 900, w: 100, h: 100), in: land)
        XCTAssertEqual(r.w, 240)
        XCTAssertEqual(r.h, 180)
        XCTAssertEqual(r.x, 80 - 240)
        XCTAssertEqual(r.y, 834 - 44)
    }

    func testClampedCapsToAvailableArea() {
        let r = layout.clamped(F(x: 0, y: 0, w: 5000, h: 5000), in: land)
        XCTAssertEqual(r.w, 1194 - 24)
        XCTAssertEqual(r.h, 834 - 24)
    }

    /// 没记过位置的窗：对话窗贴左满高；工具窗靠右按层级序号级联
    func testDefaultFrames() {
        let conv = layout.defaultFrame(for: IPadPanelLayout.convWindowId, in: land)
        XCTAssertEqual(conv.x, 12)
        XCTAssertEqual(conv.w, 320)
        XCTAssertEqual(conv.h, 834 - 24)
        layout.open("a"); layout.open("b")
        let a = layout.defaultFrame(for: "a", in: land)
        let b = layout.defaultFrame(for: "b", in: land)
        XCTAssertEqual(b.x, a.x - 26)
        XCTAssertEqual(b.y, a.y + 26)
    }
}
