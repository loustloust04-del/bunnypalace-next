import XCTest
@testable import 记忆花园

/// 画板笔刷引擎（docs/plan-page1-note-drawing.md §D）：同种子同输出、边界输入不崩、导出按内容裁边、画稿往返。
final class BrushEngineTests: XCTestCase {
    private let canvas = CGSize(width: 400, height: 300)

    private func stroke(_ tool: PaintTool, seed: UInt64 = 42, points n: Int = 40, water: CGFloat = 0.9) -> PaintStroke {
        let pts = (0..<n).map { i -> BrushPoint in
            let t = CGFloat(i) / CGFloat(max(1, n - 1))
            return BrushPoint(x: 60 + t * 260, y: 150 + sin(t * .pi * 2) * 40, t: Double(i) * 0.016, p: nil)
        }
        return PaintStroke(tool: tool, color: "#3a6fb0", size: 24, water: water, seed: seed, points: pts)
    }

    private func pixels(_ img: CGImage) -> Data {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Data(bytes: ctx.data!, count: img.width * img.height * 4)
    }

    func testSameSeedSameWatercolor() throws {
        let field = NoiseField(canvas: canvas, seed: 7)
        let a = try XCTUnwrap(BrushEngine.render(stroke(.watercolor), field: field, canvas: canvas, paper: .cold))
        let b = try XCTUnwrap(BrushEngine.render(stroke(.watercolor), field: NoiseField(canvas: canvas, seed: 7), canvas: canvas, paper: .cold))
        XCTAssertEqual(a.rect, b.rect)
        XCTAssertEqual(pixels(a.image), pixels(b.image))
        let c = try XCTUnwrap(BrushEngine.render(stroke(.watercolor, seed: 43), field: field, canvas: canvas, paper: .cold))
        XCTAssertNotEqual(pixels(a.image), pixels(c.image), "换种子应当换一笔的样子")
    }

    func testWatercolorHasDarkerRimThanCenter() throws {
        let s = stroke(.watercolor, water: 0.3)
        let r = try XCTUnwrap(BrushEngine.render(s, field: NoiseField(canvas: canvas, seed: 1), canvas: canvas, paper: .cream))
        let px = pixels(r.image), w = r.image.width, h = r.image.height
        // 竖着穿过笔画中段一列：最大不透明度应出现在边上，而不是正中（干边积色）
        let x = w / 2
        let alphas = (0..<h).map { Int(px[(($0 * w) + x) * 4 + 3]) }
        let filled = alphas.enumerated().filter { $0.element > 10 }.map(\.offset)
        let top = try XCTUnwrap(filled.first), bottom = try XCTUnwrap(filled.last)
        let c = (top + bottom) / 2
        let mid = alphas[(c - 3)...(c + 3)].reduce(0, +) / 7
        let edge = max(alphas[top...min(bottom, top + 12)].max()!, alphas[max(top, bottom - 12)...bottom].max()!)
        XCTAssertGreaterThan(edge, mid)
    }

    func testDegenerateStrokesDoNotCrash() {
        let field = NoiseField(canvas: canvas, seed: 3)
        for tool in [PaintTool.watercolor, .pen, .nib] {
            XCTAssertNotNil(BrushEngine.render(stroke(tool, points: 1), field: field, canvas: canvas, paper: .grid), "\(tool) 单点")
            var empty = stroke(tool); empty.points = []
            XCTAssertNil(BrushEngine.render(empty, field: field, canvas: canvas, paper: .grid))
            var outside = stroke(tool); outside.points = outside.points.map { BrushPoint(x: $0.x + 5000, y: $0.y, t: $0.t, p: nil) }
            XCTAssertNil(BrushEngine.render(outside, field: field, canvas: canvas, paper: .grid), "\(tool) 全在画布外")
        }
    }

    func testPressureWidensPen() {
        var light = stroke(.pen), heavy = stroke(.pen)
        light.points = light.points.map { BrushPoint(x: $0.x, y: $0.y, t: $0.t, p: 0.1) }
        heavy.points = heavy.points.map { BrushPoint(x: $0.x, y: $0.y, t: $0.t, p: 1) }
        let wl = BrushEngine.samples(light).map(\.w).reduce(0, +), wh = BrushEngine.samples(heavy).map(\.w).reduce(0, +)
        XCTAssertGreaterThan(wh, wl * 2)
    }

    @MainActor
    func testEmptyExportAndDocumentRoundTrip() throws {
        let model = DrawingBoardModel(canvasSize: canvas)
        XCTAssertNil(model.export(), "空画布不导出")
        let doc = DrawingDocument(canvasWidth: canvas.width, canvasHeight: canvas.height, paper: .magnet, noiseSeed: 9,
                                  strokes: [stroke(.watercolor), stroke(.nib)], pencilKit: nil)
        let data = try XCTUnwrap(doc.encoded())
        let back = try XCTUnwrap(DrawingDocument.decode(data))
        XCTAssertEqual(back.strokes.count, 2)
        XCTAssertEqual(back.paper, .magnet)
        XCTAssertEqual(back.strokes[0].points, doc.strokes[0].points)
    }
}
