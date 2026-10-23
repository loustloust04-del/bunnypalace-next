import XCTest
@testable import 记忆花园

/// 头像 / 横幅取景（粟粟 2026-09-24：「选头像/banner 不能左右移动，很痛苦」）。
/// 取景框任意比例：头像 1:1 圆框，横幅 3:1。图始终盖满取景框，能拖能缩放。
final class TwitterCropMathTests: XCTestCase {

    private let banner = CGSize(width: 300, height: 100)

    func testImageCoversTheFrameAtZoomOne() {
        // 竖图放进 3:1 横框：按宽度铺满
        let s = TwitterCropMath.displayScale(imageSize: CGSize(width: 1000, height: 2000), frame: banner, zoom: 1)
        XCTAssertEqual(s, 0.3, accuracy: 1e-9)
        // 横得更厉害的图：按高度铺满
        XCTAssertEqual(TwitterCropMath.displayScale(imageSize: CGSize(width: 4000, height: 500), frame: banner, zoom: 1),
                       0.2, accuracy: 1e-9)
    }

    func testCenteredCropTakesTheMiddleBand() {
        let r = TwitterCropMath.cropRect(imageSize: CGSize(width: 1000, height: 2000), frame: banner,
                                         zoom: 1, offset: .zero)
        XCTAssertEqual(r.origin.x, 0, accuracy: 1e-6)
        XCTAssertEqual(r.width, 1000, accuracy: 1e-6)
        XCTAssertEqual(r.height, 1000.0 / 3, accuracy: 1e-6)
        XCTAssertEqual(r.midY, 1000, accuracy: 1e-6, "居中取中间那一条")
    }

    func testDraggingDownRevealsTheTopOfTheImage() {
        // 图往下拖 = 取景框相对图往上走
        let r = TwitterCropMath.cropRect(imageSize: CGSize(width: 1000, height: 2000), frame: banner,
                                         zoom: 1, offset: CGSize(width: 0, height: 250))
        XCTAssertEqual(r.midY, 1000 - 250 / 0.3, accuracy: 1e-6)
    }

    func testClampKeepsTheFrameCovered() {
        let img = CGSize(width: 1000, height: 2000)
        // 竖向可拖 (2000*0.3 - 100)/2 = 250；横向铺满没有余量
        let c = TwitterCropMath.clampOffset(CGSize(width: 80, height: 999), imageSize: img, frame: banner, zoom: 1)
        XCTAssertEqual(c.width, 0, accuracy: 1e-9)
        XCTAssertEqual(c.height, 250, accuracy: 1e-9)
        let r = TwitterCropMath.cropRect(imageSize: img, frame: banner, zoom: 1, offset: c)
        XCTAssertEqual(r.minY, 0, accuracy: 1e-6, "拖到头正好贴着图的上沿，不露空")
    }

    func testZoomingInNarrowsTheCrop() {
        let r = TwitterCropMath.cropRect(imageSize: CGSize(width: 1000, height: 2000), frame: banner,
                                         zoom: 2, offset: .zero)
        XCTAssertEqual(r.width, 500, accuracy: 1e-6)
        XCTAssertEqual(r.midX, 500, accuracy: 1e-6)
    }

    func testSquareFrameMatchesAvatarBehaviour() {
        let r = TwitterCropMath.cropRect(imageSize: CGSize(width: 1200, height: 800), frame: CGSize(width: 200, height: 200),
                                         zoom: 1, offset: .zero)
        XCTAssertEqual(r, CGRect(x: 200, y: 0, width: 800, height: 800))
    }

    func testRenderProducesTheRequestedPixelSize() throws {
        let img = try XCTUnwrap(TwitterCropMathTests.solidImage(width: 1000, height: 2000))
        let data = try XCTUnwrap(TwitterCropMath.render(image: img, cropRect: CGRect(x: 0, y: 0, width: 1000, height: 1000.0 / 3),
                                                        outputSize: CGSize(width: 1500, height: 500)))
        let rendered = try XCTUnwrap(PlatformImage(data: data))
        #if canImport(UIKit)
        let px = CGSize(width: rendered.size.width * rendered.scale, height: rendered.size.height * rendered.scale)
        #else
        let rep = try XCTUnwrap(rendered.representations.first)
        let px = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        #endif
        XCTAssertEqual(px, CGSize(width: 1500, height: 500))
    }

    // MARK: 以手指为中心缩放（粟粟：「双指缩放还是有点诡异」）

    func testZoomAroundFrameCenterScalesTheOffset() {
        // 中心不动：原来偏了 (10, -20)，放大 2 倍后偏移也跟着翻倍——否则画面会往中心滑
        let o = TwitterCropMath.zoomedOffset(CGSize(width: 10, height: -20), from: 1, to: 2, around: .zero)
        XCTAssertEqual(o.width, 20, accuracy: 1e-9)
        XCTAssertEqual(o.height, -40, accuracy: 1e-9)
    }

    func testZoomKeepsThePointUnderTheFingersStill() {
        // 两指中点在框中心右边 100：那一点缩放前后都应该还在手指下面
        let p = CGSize(width: 100, height: 0)
        let before = CGSize(width: 30, height: 0)
        let after = TwitterCropMath.zoomedOffset(before, from: 1, to: 3, around: p)
        // 图上对应手指的那一点，相对图中心的位置 = (p - offset) / zoom，缩放前后必须相等
        XCTAssertEqual((p.width - before.width) / 1, (p.width - after.width) / 3, accuracy: 1e-9)
    }

    func testZoomOutToOneWithNoFingerOffsetReturnsToCenter() {
        let o = TwitterCropMath.zoomedOffset(CGSize(width: 40, height: 40), from: 2, to: 1, around: .zero)
        XCTAssertEqual(o, CGSize(width: 20, height: 20))
    }

    static func solidImage(width: Int, height: Int) -> PlatformImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: CGSize(width: width, height: height))
        #endif
    }
}
