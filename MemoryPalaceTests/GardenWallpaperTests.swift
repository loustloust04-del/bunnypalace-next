import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import 记忆花园

/// 花园四季壁纸（#036）：场景按位对齐小样、光照随时刻 / 季节、版面在三种屏幕形状下铺满地面、静帧能出图
final class GardenWallpaperTests: XCTestCase {
    func testHashMatchesPrototype() {
        // 参考值由 docs/design-garden-seasons-wallpaper.html 里的 JS hash 算出
        XCTAssertEqual(GardenMath.hash(0, 0), 0, accuracy: 1e-12)
        XCTAssertEqual(GardenMath.hash(1, 2, 3, 4), 0.738666779594, accuracy: 1e-11)
        XCTAssertEqual(GardenMath.hash(-7, 5, 16, 6), 0.403414321132, accuracy: 1e-11)
        XCTAssertEqual(GardenMath.hash(47, 18, 0, 21), 0.710462972987, accuracy: 1e-11)
        XCTAssertEqual(GardenMath.hash(112, 111, 27, 11), 0.487090407172, accuracy: 1e-11)
    }

    func testSceneMatchesPrototype() {
        // 小样里 objVox / 水格 / 叶子 / 火盆的数量和坐标校验和（Σ 3x+5y+7z）
        let scene = GardenScene.shared
        XCTAssertEqual(scene.objects.count, 2465)
        XCTAssertEqual(scene.waterCells.count, 614)
        XCTAssertEqual(scene.leaves.count, 449)
        XCTAssertEqual(scene.fires.count, 2)
        XCTAssertEqual(scene.objects.reduce(0) { $0 + $1.x * 3 + $1.y * 5 + $1.z * 7 }, 530_700)
    }

    func testEnvironmentFollowsTimeAndSeason() {
        let noon = GardenEnvironment(hour: 12.5, season: 1)
        XCTAssertGreaterThan(noon.sunI, 0.5)
        XCTAssertTrue(noon.isDaylight)
        let lateNight = GardenEnvironment(hour: 23, season: 1)
        XCTAssertGreaterThan(lateNight.night, 0.9)
        XCTAssertFalse(lateNight.isDaylight)
        XCTAssertGreaterThan(lateNight.lights, 0.9)
        let winter = GardenEnvironment(hour: 12, season: 3)
        XCTAssertEqual(winter.leafA, 0, accuracy: 1e-9)
        XCTAssertEqual(winter.snow, 1, accuracy: 1e-9)
        let spring = GardenEnvironment(hour: 12, season: 0)
        XCTAssertEqual(spring.snow, 0, accuracy: 1e-9)
        XCTAssertEqual(spring.bloom, 1, accuracy: 1e-9)
    }

    func testSeasonFromDate() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        func season(_ m: Int, _ d: Int) throws -> Double {
            let date = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 9, minute: 30)))
            let c = GardenEnvironment.clock(date, calendar: cal)
            XCTAssertEqual(c.hour, 9.5, accuracy: 1e-9)
            return c.season
        }
        XCTAssertTrue((0..<1).contains(try season(4, 20)))
        XCTAssertTrue((1..<2).contains(try season(7, 20)))
        XCTAssertTrue((2..<3).contains(try season(10, 8)))
        XCTAssertTrue((3..<4).contains(try season(1, 15)))
    }

    func testLayoutCoversBottomCornersWithGround() {
        for (w, h) in [(390.0, 844.0), (430.0, 932.0), (820.0, 1180.0), (1180.0, 820.0), (844.0, 390.0), (360.0, 200.0)] {
            let lay = GardenRenderer.layout(width: w, height: h)
            for px in [0.0, w] {
                let g = lay.groundCell(px, h)
                XCTAssertTrue(g.x >= 0 && g.y >= 0 && g.x < Double(GardenScene.n) && g.y < Double(GardenScene.n),
                              "\(Int(w))×\(Int(h)) 底角 x=\(Int(px)) 落在地面外：\(g)")
            }
        }
    }

    func testLightBackdropRules() {
        XCTAssertTrue(Page2Appearance.isLightBackdrop("mist", daylight: false))
        XCTAssertTrue(Page2Appearance.isLightBackdrop("flora", daylight: false))
        XCTAssertTrue(Page2Appearance.isLightBackdrop("garden", daylight: true))
        XCTAssertFalse(Page2Appearance.isLightBackdrop("garden", daylight: false))
        XCTAssertFalse(Page2Appearance.isLightBackdrop("dusk", daylight: true))
        XCTAssertFalse(Page2Appearance.isLightBackdrop("ios26", daylight: true))
        XCTAssertTrue(Page2Appearance.isPaleGlass("mist", daylight: false))
        XCTAssertTrue(Page2Appearance.isPaleGlass("garden", daylight: true))
        XCTAssertFalse(Page2Appearance.isPaleGlass("flora", daylight: true))
        XCTAssertEqual(Page2AppearancePatch.wallpapers["garden"], "花园四季")
        XCTAssertNoThrow(try Page2AppearancePatch(wallpaper: "garden").validate())
        XCTAssertEqual(Page2Appearance().wallpaper, "garden")
        var stale = Page2Appearance()
        stale.wallpaper = "ios26"
        XCTAssertEqual(stale.resolvedWallpaper, "garden")
    }

    func testRenderProducesFrameAndExportsSamples() throws {
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("garden-samples")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let samples: [(String, Double, Double)] = [("spring-0736", 7.6, 0), ("summer-1230", 12.5, 1), ("autumn-1700", 17, 2), ("winter-2130", 21.5, 3)]
        for (name, hour, season) in samples {
            let start = Date()
            let image = try XCTUnwrap(GardenRenderer.render(width: 390, height: 844, scale: 2, hour: hour, season: season))
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(image.width, 780)
            XCTAssertEqual(image.height, 1688)
            XCTAssertLessThan(elapsed, 5, "\(name) 出图 \(elapsed)s")
            let url = out.appendingPathComponent("\(name).png")
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            print("[garden] \(name) \(String(format: "%.0f", elapsed * 1000))ms → \(url.path)")
        }
    }

    // MARK: - #039 动画版部件

    /// 把图画进已知格式（RGBA8 预乘）的缓冲；内存第 0 行是图的最上一行
    private func pixels(_ image: CGImage, width: Int, height: Int, draw: ((CGContext) -> Void)? = nil) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        draw?(ctx)
        return data
    }

    func testPartsGeometryAndLayers() throws {
        let shapes: [(Double, Double)] = [(390, 844), (430, 932), (820, 1180), (1180, 820), (844, 390)]
        for (w, h) in shapes {
            for (hour, season) in [(12.5, 1.0), (23.0, 1.0), (21.5, 3.0), (17.0, 2.0)] {
                let start = Date()
                let parts = try XCTUnwrap(GardenRenderer.renderParts(width: w, height: h, scale: 2, hour: hour, season: season))
                let elapsed = Date().timeIntervalSince(start)
                XCTAssertLessThan(elapsed, 5)
                let tag = "\(Int(w))×\(Int(h)) \(hour)h s\(season)"
                let base = try XCTUnwrap(parts.base)
                XCTAssertEqual(base.width, Int(w * 2)); XCTAssertEqual(base.height, Int(h * 2))
                let rect = try XCTUnwrap(parts.waterRect, tag)
                let water = try XCTUnwrap(parts.water, tag)
                XCTAssertNotNil(parts.front, tag)
                XCTAssertNotNil(parts.waterPath, tag)
                // 横带按 2pt 切：裁片原点和尺寸都落在整像素上
                for v in [rect.minX, rect.minY, rect.width, rect.height] { XCTAssertEqual(v * 2, (v * 2).rounded(), accuracy: 1e-9, tag) }
                XCTAssertEqual(water.width, Int(rect.width * 2), tag)
                XCTAssertEqual(water.height, Int(rect.height * 2), tag)
                XCTAssertTrue(CGRect(x: 0, y: 0, width: w, height: h).contains(rect), tag)
                // 池子里不透明（横带晃起来不露出底下的倒影），池子外透明
                let lay = GardenRenderer.layout(width: w, height: h)
                let cell = GardenScene.shared.waterCells[GardenScene.shared.waterCells.count / 2]
                let cx = lay.ox + Double(cell.x - cell.y) * lay.s, cy = lay.oy + Double(cell.x + cell.y + 1) * lay.s / 2
                let px = try pixels(water, width: water.width, height: water.height)
                let ix = Int((cx - rect.minX) * 2), iy = Int((cy - rect.minY) * 2)
                XCTAssertEqual(px[(iy * water.width + ix) * 4 + 3], 255, "\(tag) 池心不透明")
                XCTAssertEqual(px[3], 0, "\(tag) 裁片左上角在池外")
                // 天际线：每列都被地面 / 山盖到，云至少有一部分在天上
                XCTAssertTrue(parts.skyline.allSatisfy { $0 > 0 && $0 <= h }, tag)
                for c in parts.clouds { XCTAssertLessThan(c.y + c.box.minY, parts.skyAt(c.x), "\(tag) 云整朵在天际线下") }
                XCTAssertEqual(parts.clouds.count, 7)
                XCTAssertEqual(parts.lines.count, 22)
                XCTAssertEqual(parts.ripples.map(\.count), [GardenParts.rippleCycles, GardenParts.rippleCycles])
                let env = parts.env
                if env.night > 0.05 { XCTAssertEqual(parts.stars.count, 80, tag); XCTAssertEqual(parts.golds.count, 6, tag) } else { XCTAssertTrue(parts.stars.isEmpty, tag) }
                if env.lights * 0.32 > 0.003 { XCTAssertFalse(parts.halos.isEmpty, tag); XCTAssertNotNil(parts.halo, tag) }
                if env.sunI > 0.3 { XCTAssertFalse(parts.glints.isEmpty, "\(tag) 正午有碎光") }
                if hour == 23 && season == 1 { XCTAssertEqual(parts.fireflies.count, 10, tag) }
                if season == 3 { XCTAssertTrue(parts.fireflies.isEmpty, "\(tag) 冬天没有萤火") }
                print("[garden] parts \(tag) \(String(format: "%.0f", elapsed * 1000))ms water \(rect)")
            }
        }
    }

    /// 底图 + 水裁片 + 前景裁片叠回去 = 底图本身：证明两张裁片和底图对齐、收尾柔光 / 暗角一致（动画层静止时看不出拼缝）
    func testPartsRecomposeToBase() throws {
        for (hour, season) in [(12.5, 1.0), (21.5, 3.0), (17.0, 2.0)] {
            let parts = try XCTUnwrap(GardenRenderer.renderParts(width: 390, height: 844, scale: 2, hour: hour, season: season))
            let base = try XCTUnwrap(parts.base), water = try XCTUnwrap(parts.water), front = try XCTUnwrap(parts.front), rect = try XCTUnwrap(parts.waterRect)
            let w = base.width, h = base.height
            let plain = try pixels(base, width: w, height: h)
            let stacked = try pixels(base, width: w, height: h) { ctx in
                let r = CGRect(x: rect.minX * 2, y: Double(h) - rect.maxY * 2, width: rect.width * 2, height: rect.height * 2)
                ctx.draw(water, in: r)
                ctx.draw(front, in: r)
            }
            var total = 0, big = 0, n = 0
            let x0 = Int(rect.minX * 2), x1 = Int(rect.maxX * 2), y0 = Int(rect.minY * 2), y1 = Int(rect.maxY * 2)
            for y in y0..<y1 { for x in x0..<x1 { for c in 0..<3 {
                let d = abs(Int(plain[(y * w + x) * 4 + c]) - Int(stacked[(y * w + x) * 4 + c]))
                total += d; n += 1
                if d > 24 { big += 1 }
            } } }
            let mean = Double(total) / Double(n)
            print("[garden] recompose \(hour)h s\(season): mean \(String(format: "%.2f", mean)) big \(big)/\(n)")
            XCTAssertLessThan(mean, 1.0)
            XCTAssertLessThan(Double(big) / Double(n), 0.01)
        }
    }

    /// 动画层在 t0 的样子叠回底图 = v1 静帧 `render`（水面以外：水面上的细纹 / 涟漪 / 碎光是动画层，这里不画；暗角最后盖）。
    /// 证明星 / 金星 / 云 / 火盆光晕的位置、相位、遮挡都对，静帧 → 动画版那一下换不出跳变（含横屏夜景：被山挡住的星不该冒出来）
    func testPartsAtT0MatchStill() throws {
        for (w, h, hour, season) in [(390.0, 844.0, 21.5, 3.0), (844.0, 390.0, 23.0, 1.0), (390.0, 844.0, 17.0, 2.0), (1180.0, 820.0, 2.0, 0.0)] {
            let tag = "\(Int(w))×\(Int(h)) \(hour)h s\(season)"
            let parts = try XCTUnwrap(GardenRenderer.renderParts(width: w, height: h, scale: 2, hour: hour, season: season))
            let still = try XCTUnwrap(GardenRenderer.render(width: w, height: h, scale: 2, hour: hour, season: season, t: GardenParts.t0))
            let base = try XCTUnwrap(parts.base), rect = try XCTUnwrap(parts.waterRect)
            let pw = base.width, ph = base.height
            let t = GardenParts.t0
            func srgb(_ c: GardenRGB, _ a: Double) -> CGColor { CGColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: a) }
            let composed = try pixels(base, width: pw, height: ph) { ctx in
                ctx.translateBy(x: 0, y: CGFloat(ph)); ctx.scaleBy(x: 2, y: -2)
                for st in parts.stars where parts.inOpenSky(st.x, st.y, st.r) {
                    ctx.setFillColor(srgb(st.color, st.alpha * (st.lo + st.amp * sin(st.omega * t + st.phase))))
                    ctx.fillEllipse(in: CGRect(x: st.x - st.r, y: st.y - st.r, width: st.r * 2, height: st.r * 2))
                }
                if let gold = parts.goldStar {
                    for st in parts.golds where parts.inOpenSky(st.x, st.y, parts.goldBox.width / 2) {
                        ctx.saveGState(); ctx.setAlpha(st.alpha * (st.lo + st.amp * sin(st.omega * t + st.phase)))
                        GardenRenderer.drawUpright(ctx, gold, in: parts.goldBox.offsetBy(dx: st.x, dy: st.y)); ctx.restoreGState()
                    }
                }
                ctx.saveGState(); ctx.addPath(parts.skyPath); ctx.clip()
                for c in parts.clouds { GardenRenderer.drawUpright(ctx, c.image, in: c.box.offsetBy(dx: c.x, dy: c.y)) }
                ctx.restoreGState()
                if let halo = parts.halo {
                    let flicker = 0.88 + 0.12 * sin(t * 9.3) * sin(t * 5.1)
                    for g in parts.halos {
                        ctx.saveGState(); ctx.setAlpha(flicker)
                        GardenRenderer.drawUpright(ctx, halo, in: parts.haloBox.offsetBy(dx: g.x, dy: g.y)); ctx.restoreGState()
                    }
                }
                if let vignette = parts.vignette {
                    ctx.interpolationQuality = .high
                    GardenRenderer.drawUpright(ctx, vignette, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
            }
            let target = try pixels(still, width: pw, height: ph)
            let water = CGRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2)
            var total = 0, big = 0, n = 0
            for y in 0..<ph { for x in 0..<pw where !water.contains(CGPoint(x: x, y: y)) { for c in 0..<3 {
                let d = abs(Int(composed[(y * pw + x) * 4 + c]) - Int(target[(y * pw + x) * 4 + c]))
                total += d; n += 1
                if d > 24 { big += 1 }
            } } }
            let mean = Double(total) / Double(n)
            print("[garden] t0 \(tag): mean \(String(format: "%.3f", mean)) big \(big)/\(n) stars \(parts.stars.filter { parts.inOpenSky($0.x, $0.y, $0.r) }.count)/\(parts.stars.count)")
            XCTAssertLessThan(mean, 0.5, tag)
            XCTAssertLessThan(Double(big) / Double(n), 0.002, tag)
        }
    }

    func testFallPathsFollowPrototype() {
        for f in GardenParts.falls {
            for i in [0, 3, f.count - 1] {
                let per = GardenParts.fallPeriod(f, i)
                XCTAssertTrue(per >= f.period * 0.8 && per <= f.period * 1.4)
                XCTAssertTrue((0..<1).contains(GardenParts.fallPhase0(f, i)))
                XCTAssertEqual(GardenParts.fallPoint(f, i, 0, width: 390, height: 844).y, -10, accuracy: 1e-9)
                XCTAssertEqual(GardenParts.fallPoint(f, i, 1, width: 390, height: 844).y, 854, accuracy: 1e-9)
                // 小样：x = (hash(i, seed, 3)·1.3 − 0.15)·W + ph·W·0.18 + sin(ph·12 + i)·W·0.03
                let ph = 0.37
                let x = (GardenMath.hash(i, f.seed, 3) * 1.3 - 0.15) * 390 + ph * 390 * 0.18 + sin(ph * 12 + Double(i)) * 390 * 0.03
                XCTAssertEqual(GardenParts.fallPoint(f, i, ph, width: 390, height: 844).x, x, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(GardenParts.fallAlpha(0), 0, accuracy: 1e-9)
        XCTAssertEqual(GardenParts.fallAlpha(0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(GardenParts.fallAlpha(1), 0, accuracy: 1e-9)
    }

    /// #051：时钟网格。整屏合成 = 基准（水组每拍）；慢组是基准的整数分之一、不超设计上限；停过之后不跳
    func testClockGridStaysWithinBudget() {
        let design = [30, 15, 10]
        for lowPower in [false, true] {
            let base = GardenParts.clockBase(lowPower: lowPower)
            XCTAssertEqual(base, lowPower ? 20 : 30)
            XCTAssertEqual(GardenParts.clockStride(fps: 30, base: base), 1)
            for fps in design {
                let stride = GardenParts.clockStride(fps: fps, base: base)
                XCTAssertGreaterThanOrEqual(stride, 1)
                XCTAssertLessThanOrEqual(Double(base) / Double(stride), Double(fps) + 1e-9, "fps \(fps) lowPower \(lowPower)")
            }
        }
        XCTAssertEqual(GardenParts.clockStride(fps: 15, base: 30), 2)
        XCTAssertEqual(GardenParts.clockStride(fps: 10, base: 30), 3)
        XCTAssertEqual(GardenParts.clockStride(fps: 15, base: 20), 2)
        XCTAssertEqual(GardenParts.clockStride(fps: 10, base: 20), 2)
        XCTAssertEqual(GardenParts.clockStep(1.0 / 30, base: 30), 1.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(GardenParts.clockStep(4, base: 30), 2.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(GardenParts.clockStep(-1, base: 30), 0)
    }
}
