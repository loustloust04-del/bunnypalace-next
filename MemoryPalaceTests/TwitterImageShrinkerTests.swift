import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import 记忆花园

/// 相册里挑的图动辄 4000px、几 MB，当头像存盘太浪费，存前要缩。
final class TwitterImageShrinkerTests: XCTestCase {

    private func png(width: Int, height: Int) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func pixelSize(_ data: Data) throws -> (Int, Int) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    func testShrinksLongEdgeKeepingAspect() throws {
        let out = try XCTUnwrap(TwitterImageShrinker.jpeg(from: try png(width: 2000, height: 1000), maxPixel: 500))
        let (w, h) = try pixelSize(out)
        XCTAssertEqual(w, 500)
        XCTAssertEqual(h, 250)
    }

    func testDoesNotUpscaleSmallImages() throws {
        let out = try XCTUnwrap(TwitterImageShrinker.jpeg(from: try png(width: 120, height: 80), maxPixel: 500))
        let (w, h) = try pixelSize(out)
        XCTAssertEqual(w, 120)
        XCTAssertEqual(h, 80)
    }

    func testReturnsNilForGarbage() {
        XCTAssertNil(TwitterImageShrinker.jpeg(from: Data([0, 1, 2, 3]), maxPixel: 500))
    }
}
