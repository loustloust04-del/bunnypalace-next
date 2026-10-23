// 按 docs/spec-dust-cleanroom.md 净室实现（#007）
// 散成灰渲染器（spec A.4）：mac 上跑真 GPU，离屏画到贴图再读回像素做断言
import CoreGraphics
import Metal
import XCTest
@testable import 记忆花园

final class DustEffectTests: XCTestCase {
    private let canvas = CGSize(width: 360, height: 260)
    private let bubble = CGRect(x: 30, y: 170, width: 300, height: 64)
    private let scale = 2

    // MARK: - add

    func testAddRejectsEmptyAndNonFiniteFrames() throws {
        let r = try XCTUnwrap(DustEffectRenderer())
        let image = solidImage(width: 20, height: 20)
        XCTAssertFalse(r.add(frame: .zero, image: image))
        XCTAssertFalse(r.add(frame: CGRect(x: 0, y: 0, width: 100, height: 0), image: image))
        XCTAssertFalse(r.add(frame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10), image: image))
        XCTAssertFalse(r.add(frame: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10), image: image))
        XCTAssertTrue(r.isEmpty)
        XCTAssertTrue(r.add(frame: CGRect(x: 0, y: 0, width: 10, height: 10), image: image))
        XCTAssertFalse(r.isEmpty)
    }

    func testAcceptsHalfFloatExtendedSRGBSnapshot() throws {
        let r = try XCTUnwrap(DustEffectRenderer())
        let image = try XCTUnwrap(halfFloatImage(width: 40, height: 16))
        XCTAssertEqual(image.bitsPerComponent, 16)
        XCTAssertTrue(r.add(frame: CGRect(x: 0, y: 0, width: 20, height: 8), image: image))
        let pixels = try render(r)
        XCTAssertGreaterThan(alphaSum(pixels, in: CGRect(x: 0, y: 0, width: 20, height: 8)), 0, "转换后要画得出来")
    }

    func testHugeFrameCapsParticleCount() throws {
        let grid = try XCTUnwrap(DustEffectRenderer.grid(for: CGSize(width: 1200, height: 2000)))
        XCTAssertLessThanOrEqual(grid.cols * grid.rows, DustEffectRenderer.maxParticles)
        XCTAssertGreaterThan(grid.cols * grid.rows, DustEffectRenderer.maxParticles * 9 / 10, "封顶但别粗得过头")
        XCTAssertEqual(Double(grid.cols) / Double(grid.rows), 1200.0 / 2000.0, accuracy: 0.01, "格子是正方形")
        let small = try XCTUnwrap(DustEffectRenderer.grid(for: CGSize(width: 300, height: 64)))
        XCTAssertEqual(small.cols, 300, "小图 1pt 一颗")
        XCTAssertEqual(small.rows, 64)
    }

    /// 四象限不同色：t = 0 那帧要原样拼回截图（抓贴图上下 / 左右颠倒、uv 错位）
    func testFirstFrameReproducesSnapshotOrientation() throws {
        let r = try XCTUnwrap(DustEffectRenderer())
        let colors: [(UInt8, UInt8, UInt8)] = [(200, 60, 40), (40, 120, 200), (90, 180, 90), (230, 200, 60)]  // 左上 右上 左下 右下
        XCTAssertTrue(r.add(frame: bubble, image: quadrantImage(width: 600, height: 128, colors: colors)))
        let pixels = try render(r)
        let w = Int(canvas.width) * scale
        for (i, color) in colors.enumerated() {
            let right = i % 2 == 1, bottom = i >= 2
            for (fx, fy) in [(0.2, 0.25), (0.35, 0.4), (0.1, 0.1), (0.4, 0.45)] {
                let x = bubble.minX + bubble.width * (right ? 0.5 + fx : fx)
                let y = bubble.minY + bubble.height * (bottom ? 0.5 + fy : fy)
                let idx = (Int(y * CGFloat(scale)) * w + Int(x * CGFloat(scale))) * 4
                // BGRA
                XCTAssertEqual(Int(pixels[idx + 2]), Int(color.0), accuracy: 3, "象限 \(i) 红")
                XCTAssertEqual(Int(pixels[idx + 1]), Int(color.1), accuracy: 3, "象限 \(i) 绿")
                XCTAssertEqual(Int(pixels[idx + 0]), Int(color.2), accuracy: 3, "象限 \(i) 蓝")
                XCTAssertEqual(Int(pixels[idx + 3]), 255, accuracy: 3)
            }
        }
    }

    // MARK: - 时间轴

    func testRemovedNearDuration() throws {
        let r = try XCTUnwrap(DustEffectRenderer())
        XCTAssertTrue(r.add(frame: bubble, image: solidImage(width: 600, height: 128)))
        let queue = r.queue
        var t: Float = 0
        while !r.isEmpty, t < 5 {
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            r.encodeStep(into: cb, deltaTime: 1.0 / 60)
            cb.commit()
            t += 1.0 / 60
        }
        XCTAssertEqual(t, DustEffectRenderer.duration, accuracy: 0.05)
        XCTAssertLessThanOrEqual(DustEffectRenderer.duration, 2)
    }

    func testSweepStartsOnTheLeft() throws {
        let r = try XCTUnwrap(DustEffectRenderer())
        XCTAssertTrue(r.add(frame: bubble, image: solidImage(width: 600, height: 128)))
        let start = try render(r)
        try advance(r, to: 0.15)
        let early = try render(r)
        let leftQuarter = CGRect(x: bubble.minX, y: bubble.minY, width: bubble.width / 4, height: bubble.height)
        let rightHalf = CGRect(x: bubble.midX, y: bubble.minY, width: bubble.width / 2, height: bubble.height)
        XCTAssertGreaterThan(changedFraction(start, early, in: leftQuarter), 0.2, "左边已经起飞")
        XCTAssertLessThan(changedFraction(start, early, in: rightHalf), 0.01, "右半边还没动")
    }

    func testDustRisesAfterOneSecond() throws {
        let r = try XCTUnwrap(DustEffectRenderer())
        XCTAssertTrue(r.add(frame: bubble, image: solidImage(width: 600, height: 128)))
        try advance(r, to: 1.0)
        let pixels = try render(r)
        let (sum, centroidY) = alphaCentroidY(pixels)
        XCTAssertGreaterThan(sum, 0, "1 s 时还有灰")
        XCTAssertLessThan(centroidY, Double(bubble.minY), "整体飘到了起点上方")
    }

    func testLastFrameBeforeRemovalIsFullyTransparent() throws {
        let r = try XCTUnwrap(DustEffectRenderer())
        XCTAssertTrue(r.add(frame: bubble, image: solidImage(width: 600, height: 128)))
        var last: [UInt8] = []
        var steps = 0
        while steps < 600 {
            let cb = try XCTUnwrap(r.queue.makeCommandBuffer())
            r.encodeStep(into: cb, deltaTime: 1.0 / 60)
            cb.commit()
            steps += 1
            if r.isEmpty { break }
            last = try render(r)
        }
        XCTAssertTrue(r.isEmpty)
        XCTAssertFalse(last.isEmpty)
        XCTAssertEqual(alphaSum(last, in: CGRect(origin: .zero, size: canvas)), 0, "移除前最后一帧不能还看得见颗粒")
    }

    // MARK: - 工具

    private func advance(_ r: DustEffectRenderer, to seconds: Float) throws {
        var t: Float = 0
        while t + 1e-4 < seconds {
            let cb = try XCTUnwrap(r.queue.makeCommandBuffer())
            r.encodeStep(into: cb, deltaTime: 1.0 / 120)
            cb.commit()
            t += 1.0 / 120
        }
    }

    /// 画一帧到透明底的离屏贴图，读回 BGRA8
    private func render(_ r: DustEffectRenderer) throws -> [UInt8] {
        let w = Int(canvas.width) * scale, h = Int(canvas.height) * scale
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: DustEffectRenderer.pixelFormat, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = r.device.hasUnifiedMemory ? .shared : .managed
        let target = try XCTUnwrap(r.device.makeTexture(descriptor: desc))
        let cb = try XCTUnwrap(r.queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
        r.encodeDraw(into: enc, viewport: canvas)
        enc.endEncoding()
        if target.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return bytes
    }

    private func pixelRange(_ rect: CGRect) -> (xs: Range<Int>, ys: Range<Int>) {
        let w = Int(canvas.width) * scale, h = Int(canvas.height) * scale
        let x0 = max(0, Int(rect.minX) * scale), x1 = min(w, Int(rect.maxX) * scale)
        let y0 = max(0, Int(rect.minY) * scale), y1 = min(h, Int(rect.maxY) * scale)
        return (x0..<max(x0, x1), y0..<max(y0, y1))
    }

    private func alphaSum(_ px: [UInt8], in rect: CGRect) -> Int {
        let w = Int(canvas.width) * scale
        let (xs, ys) = pixelRange(rect)
        var sum = 0
        for y in ys { for x in xs { sum += Int(px[(y * w + x) * 4 + 3]) } }
        return sum
    }

    private func changedFraction(_ a: [UInt8], _ b: [UInt8], in rect: CGRect) -> Double {
        let w = Int(canvas.width) * scale
        let (xs, ys) = pixelRange(rect)
        var changed = 0
        for y in ys { for x in xs {
            let i = (y * w + x) * 4
            if abs(Int(a[i + 3]) - Int(b[i + 3])) > 8 { changed += 1 }
        } }
        return Double(changed) / Double(max(1, xs.count * ys.count))
    }

    /// alpha 加权的质心 y（点）
    private func alphaCentroidY(_ px: [UInt8]) -> (sum: Int, y: Double) {
        let w = Int(canvas.width) * scale, h = Int(canvas.height) * scale
        var sum = 0, sy = 0.0
        for y in 0..<h { for x in 0..<w {
            let a = Int(px[(y * w + x) * 4 + 3])
            sum += a
            sy += Double(a) * Double(y)
        } }
        return (sum, sum > 0 ? sy / Double(sum) / Double(scale) : .infinity)
    }

    private func solidImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.65, blue: 0.55, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// colors 依次是左上、右上、左下、右下（图像坐标，顶边在上）
    private func quadrantImage(width: Int, height: Int, colors: [(UInt8, UInt8, UInt8)]) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hw = width / 2, hh = height / 2
        // CGContext 原点在左下：图的上半是 y ∈ [hh, height)
        let quads = [CGRect(x: 0, y: hh, width: hw, height: hh), CGRect(x: hw, y: hh, width: hw, height: hh),
                     CGRect(x: 0, y: 0, width: hw, height: hh), CGRect(x: hw, y: 0, width: hw, height: hh)]
        for (rect, c) in zip(quads, colors) {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1))
            ctx.fill(rect)
        }
        return ctx.makeImage()!
    }

    /// 真机截图的格式：每通道 16 位浮点、扩展 sRGB，带一个超出 sRGB 的分量
    private func halfFloatImage(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.floatComponents.rawValue
                                      | CGImageByteOrderInfo.order16Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(colorSpace: space, components: [1.2, 0.3, -0.1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
