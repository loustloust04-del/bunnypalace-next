import XCTest
@testable import 记忆花园

/// AvatarCropMath 纯函数特征测试：默认居中 / 横图取中央 / 放大缩小区域 / 偏移方向 / clamp 边界。
final class AvatarCropMathTests: XCTestCase {

    // 方图 1000、圆 300、zoom 1、无偏移 → 整张图（短边铺满圆）
    func testSquareImageDefaultCoversWholeImage() {
        let r = AvatarCropMath.cropRect(imageSize: CGSize(width: 1000, height: 1000),
                                        circleDiameter: 300, zoom: 1, offset: .zero)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    }

    // 横图 2000×1000 → 默认取水平居中的 1000 方块
    func testLandscapeDefaultTakesCenterSquare() {
        let r = AvatarCropMath.cropRect(imageSize: CGSize(width: 2000, height: 1000),
                                        circleDiameter: 300, zoom: 1, offset: .zero)
        XCTAssertEqual(r, CGRect(x: 500, y: 0, width: 1000, height: 1000))
    }

    // zoom 2 → 裁剪区缩到一半、仍居中
    func testZoomShrinksCropRegion() {
        let r = AvatarCropMath.cropRect(imageSize: CGSize(width: 1000, height: 1000),
                                        circleDiameter: 300, zoom: 2, offset: .zero)
        XCTAssertEqual(r, CGRect(x: 250, y: 250, width: 500, height: 500))
    }

    // 图往右拖（offset.x > 0）→ 裁剪区在源图里往左移
    func testDragRightMovesCropLeft() {
        let centered = AvatarCropMath.cropRect(imageSize: CGSize(width: 2000, height: 1000),
                                               circleDiameter: 300, zoom: 1, offset: .zero)
        let dragged = AvatarCropMath.cropRect(imageSize: CGSize(width: 2000, height: 1000),
                                              circleDiameter: 300, zoom: 1,
                                              offset: CGSize(width: 60, height: 0))
        XCTAssertLessThan(dragged.minX, centered.minX)
        XCTAssertEqual(dragged.minY, centered.minY)
        XCTAssertEqual(dragged.width, centered.width)
    }

    // clamp：方图 zoom 1 没有可拖空间（短边正好铺满圆）→ 任意偏移都归零
    func testClampSquareAtZoom1HasNoSlack() {
        let c = AvatarCropMath.clampOffset(CGSize(width: 80, height: -120),
                                           imageSize: CGSize(width: 1000, height: 1000),
                                           circleDiameter: 300, zoom: 1)
        XCTAssertEqual(c, .zero)
    }

    // clamp：横图水平有富余、垂直没有；超界收到边界值
    func testClampLandscapeHorizontalSlackOnly() {
        // s = 0.3，横向富余 = (2000×0.3 − 300)/2 = 150
        let c = AvatarCropMath.clampOffset(CGSize(width: 999, height: 50),
                                           imageSize: CGSize(width: 2000, height: 1000),
                                           circleDiameter: 300, zoom: 1)
        XCTAssertEqual(c.width, 150)
        XCTAssertEqual(c.height, 0)
    }

    // 往返一致：cropRect 输出始终落在源图内（clamp 后的任意 offset/zoom）
    func testCropRectStaysInsideImageAfterClamp() {
        let size = CGSize(width: 1600, height: 900)
        for zoom in [CGFloat(1), 1.7, 3, 6] {
            for raw in [CGSize(width: 500, height: -500), CGSize(width: -37, height: 12)] {
                let off = AvatarCropMath.clampOffset(raw, imageSize: size, circleDiameter: 280, zoom: zoom)
                let r = AvatarCropMath.cropRect(imageSize: size, circleDiameter: 280, zoom: zoom, offset: off)
                XCTAssertGreaterThanOrEqual(r.minX, -0.001, "zoom=\(zoom) off=\(off)")
                XCTAssertGreaterThanOrEqual(r.minY, -0.001, "zoom=\(zoom) off=\(off)")
                XCTAssertLessThanOrEqual(r.maxX, size.width + 0.001, "zoom=\(zoom) off=\(off)")
                XCTAssertLessThanOrEqual(r.maxY, size.height + 0.001, "zoom=\(zoom) off=\(off)")
            }
        }
    }

    // 渲染冒烟：纯色图裁出 512×512 JPEG，能解码回平台图
    func testRenderCropProduces512Jpeg() throws {
        let size = CGSize(width: 800, height: 600)
        #if canImport(UIKit)
        let src = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        #else
        let src = NSImage(size: size, flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        #endif
        let rect = AvatarCropMath.cropRect(imageSize: size, circleDiameter: 300, zoom: 1, offset: .zero)
        let data = try XCTUnwrap(AvatarCropMath.renderCrop(image: src, cropRect: rect))
        let out = try XCTUnwrap(PlatformImage(data: data))
        XCTAssertEqual(out.size.width, 512, accuracy: 1)
        XCTAssertEqual(out.size.height, 512, accuracy: 1)
    }
}
