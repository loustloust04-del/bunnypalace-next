// MP fork: ||剧透|| 粒子遮罩（research-chat-cards §12）。
// 纯逻辑：哪些剧透还藏着；粒子层的数值测试按 docs/spec-dust-cleanroom.md B.5 补在末尾。mac: `swift test --filter SpoilerDustTests`

import CoreGraphics
import Foundation
@testable import SwiftStreamingMarkdown
import XCTest

final class SpoilerDustTests: XCTestCase {

  private func paragraph(_ text: String) -> NSMutableAttributedString {
    MarkdownParserImpl.renderables(for: text, config: .default).compactMap {
      if case .paragraph(_, let content) = $0 { return content }
      return nil
    }.first ?? NSMutableAttributedString()
  }

  // MARK: - 还藏着的剧透

  func testHiddenSpoilersAreGroupedPerSpoiler() {
    let p = paragraph("A ||一**二**三|| B ||四|| C")
    let hidden = SpoilerRevealState.hiddenSpoilers(in: p)
    XCTAssertEqual(hidden.count, 2, "一个 ||…|| 一组，中间换了字体也不拆")
    let ns = p.string as NSString
    XCTAssertEqual(ns.substring(with: hidden[0].range), "一二三")
    XCTAssertEqual(ns.substring(with: hidden[1].range), "四")
    XCTAssertNotEqual(hidden[0].url, hidden[1].url)
  }

  func testSpoilerKeepsOriginalColorAndHasNoGreyBlock() {
    let p = paragraph("{color:green}绿||藏||{/color}")
    let hidden = SpoilerRevealState.hiddenSpoilers(in: p)
    XCTAssertEqual(hidden.first?.color, InlineExtensionStyle.namedColor("green"), "点用字本来的颜色")
    let at = (p.string as NSString).range(of: "藏").location
    XCTAssertNil(p.attribute(.backgroundColor, at: at, effectiveRange: nil), "灰块换成粒子了")
  }

  func testRevealedSpoilerIsNoLongerHidden() {
    let storage = NSTextStorage(attributedString: paragraph("||甲|| 和 ||乙||"))
    var state = SpoilerRevealState()
    state.contentDidChange(to: storage.string)
    let first = SpoilerRevealState.hiddenSpoilers(in: storage)[0]
    XCTAssertNotNil(state.reveal(first.url, in: storage))
    let left = SpoilerRevealState.hiddenSpoilers(in: storage)
    XCTAssertEqual(left.count, 1)
    XCTAssertEqual((storage.string as NSString).substring(with: left[0].range), "乙")
  }
}

// MARK: - 粒子层数值（docs/spec-dust-cleanroom.md B.5，按 spec 净室实现 #007）

extension SpoilerDustTests {
  private var lines: [CGRect] {
    [CGRect(x: 40, y: 2, width: 220, height: 18), CGRect(x: 0, y: 24, width: 300, height: 18), CGRect(x: 0, y: 46, width: 120, height: 18)]
  }

  // MARK: 揭开半径 / 时长

  func testRevealRadiusCoversEveryCorner() {
    for point in [CGPoint(x: 150, y: 33), CGPoint(x: 2, y: 50), CGPoint(x: 255, y: 5)] {
      let r = SpoilerDustMath.revealRadius(from: point, rects: lines)
      for rect in lines {
        for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
          XCTAssertGreaterThanOrEqual(r, hypot(corner.x - point.x, corner.y - point.y))
        }
      }
    }
    XCTAssertEqual(SpoilerDustMath.revealRadius(from: .zero, rects: []), SpoilerDustMath.minRevealRadius)
    XCTAssertGreaterThan(SpoilerDustMath.minRevealRadius, 0)
  }

  func testRevealDurationRangeAndCenterIsLongest() {
    let union = lines.reduce(CGRect.null) { $0.union($1) }
    let center = SpoilerDustMath.revealDuration(from: CGPoint(x: union.midX, y: union.midY), rects: lines)
    let edge = SpoilerDustMath.revealDuration(from: CGPoint(x: 1, y: 33), rects: lines)
    let corner = SpoilerDustMath.revealDuration(from: CGPoint(x: 299, y: 63), rects: lines)
    for d in [center, edge, corner, SpoilerDustMath.revealDuration(from: .zero, rects: [])] {
      XCTAssertGreaterThanOrEqual(d, 0.35)
      XCTAssertLessThanOrEqual(d, 0.55)
    }
    XCTAssertGreaterThanOrEqual(center, edge)
    XCTAssertGreaterThanOrEqual(edge, corner)
    XCTAssertGreaterThan(center, corner, "中间和角上要真的有差别")
  }

  // MARK: 密度

  func testDensityScalesWithAreaAndIsCapped() {
    XCTAssertEqual(SpoilerDustMath.visibleCount(area: 0), 0)
    let small = SpoilerDustMath.visibleCount(area: 1000)
    XCTAssertGreaterThan(small, 0)
    XCTAssertEqual(SpoilerDustMath.visibleCount(area: 2000) / small, 2, accuracy: 0.05)
    XCTAssertEqual(SpoilerDustMath.visibleCount(area: 1e7), SpoilerDustMath.maxVisible)
    XCTAssertEqual(SpoilerDustMath.visibleCount(area: 1e9), SpoilerDustMath.maxVisible)
    // 每平方点零点几颗
    XCTAssertGreaterThan(SpoilerDustMath.density, 0.1)
    XCTAssertLessThan(SpoilerDustMath.density, 1)
  }

  // MARK: 静态点图

  func testStaticDotsAreDeterministicAndStayInside() {
    let a = SpoilerDustMath.staticDots(in: lines)
    let b = SpoilerDustMath.staticDots(in: lines)
    XCTAssertFalse(a.isEmpty)
    XCTAssertEqual(a, b, "同输入两次完全相同（重排版不闪）")
    for dot in a {
      XCTAssertTrue(lines.contains { $0.insetBy(dx: -1, dy: -1).contains(dot.center) })
      XCTAssertTrue((0..<SpoilerDustMath.staticShadeOpacities.count).contains(dot.shade))
    }
    let area = lines.reduce(0.0) { $0 + Double($1.width * $1.height) }
    let expected = SpoilerDustMath.visibleCount(area: area) * SpoilerDustMath.staticDensityFactor
    XCTAssertEqual(Double(a.count), expected, accuracy: expected * 0.02 + 3, "静态版密度略低于会动的版本")
  }

  func testStaticDotsSkipTooNarrowRects() {
    XCTAssertTrue(SpoilerDustMath.staticDots(in: [CGRect(x: 0, y: 0, width: 1, height: 18)]).isEmpty)
    XCTAssertTrue(SpoilerDustMath.staticDots(in: [CGRect(x: 0, y: 0, width: 80, height: 1)]).isEmpty)
    XCTAssertTrue(SpoilerDustMath.staticDots(in: []).isEmpty)
  }

  // MARK: 一颗点的一生

  func testLifeEnvelopeFadesInThenOut() {
    let (values, locations) = SpoilerDustMath.lifeEnvelope
    XCTAssertEqual(values.count, locations.count)
    XCTAssertEqual(values.first, 0, "出生时透明（淡入）")
    XCTAssertEqual(values.last, 0, "死前透明（淡出）")
    XCTAssertEqual(locations.first, 0)
    XCTAssertEqual(locations.last, 1)
    for i in 1..<locations.count { XCTAssertGreaterThan(locations[i], locations[i - 1], "locations 单调递增") }
    let peak = values.indices.max { values[$0] < values[$1] }!
    XCTAssertTrue(peak > 0 && peak < values.count - 1, "峰在寿命中间")
    XCTAssertGreaterThan(values[peak], 0.9)
  }

  // MARK: 粒子层（CAEmitterLayer）

  func testEmittersAreClippedToTheirLineRects() {
    let layer = SpoilerDustLayer(animated: true)
    layer.contentsScale = 2
    layer.frame = CGRect(x: 0, y: 0, width: 320, height: 70)
    layer.update(rects: lines + [CGRect(x: 0, y: 70, width: 1, height: 18)], color: CGColor(gray: 0.2, alpha: 1))
    XCTAssertEqual(layer.emitterLayers.count, lines.count, "太窄的矩形不撒")
    let area = lines.reduce(0.0) { $0 + Double($1.width * $1.height) }
    var visible = 0.0
    for (rect, emitter) in zip(lines, layer.emitterLayers) {
      XCTAssertTrue(emitter.masksToBounds, "点不出它所属的行矩形")
      XCTAssertTrue(rect.insetBy(dx: -1.5, dy: -1.5).contains(emitter.frame))
      for cell in emitter.emitterCells ?? [] {
        visible += Double(cell.birthRate * cell.lifetime)
        XCTAssertLessThanOrEqual(cell.velocity + cell.velocityRange, 20, "慢慢漂")
      }
    }
    XCTAssertEqual(visible, SpoilerDustMath.visibleCount(area: area), accuracy: 1, "同时可见数 = 出生率 × 寿命")
    if NSClassFromString("CAEmitterBehavior") != nil {
      XCTAssertTrue(layer.hasPullBehavior, "能拿到就挂上吸附")
      for cell in layer.emitterLayers[0].emitterCells ?? [] { XCTAssertEqual(cell.alphaSpeed, 0, "能拿到就用「先淡入再淡出」，不走退化") }
    }
  }

  func testColorChangeReplacesLiveDotsImmediately() {
    let layer = SpoilerDustLayer(animated: true)
    layer.contentsScale = 3
    layer.update(rects: lines, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    let before = layer.emitterLayers
    let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
    layer.update(rects: lines, color: blue)
    XCTAssertEqual(layer.emitterLayers.count, before.count)
    for old in before { XCTAssertNil(old.superlayer, "旧色的点不能留到自然死亡") }
    for emitter in layer.emitterLayers {
      for cell in emitter.emitterCells ?? [] {
        XCTAssertEqual(cell.color?.components?[2] ?? 0, 1, accuracy: 1e-6)
      }
    }
    // 只是宽度变了：不换发射器
    let kept = layer.emitterLayers
    layer.update(rects: lines.map { $0.insetBy(dx: 5, dy: 0) }, color: blue)
    XCTAssertTrue(zip(kept, layer.emitterLayers).allSatisfy { $0 === $1 })
  }

  func testStreamingUpdatesDoNotJitterEmitters() {
    let layer = SpoilerDustLayer(animated: true)
    layer.contentsScale = 2
    layer.update(rects: lines, color: CGColor(gray: 0.1, alpha: 1))
    let first = layer.emitterLayers
    let frames = first.map(\.frame)
    let seeds = first.map(\.seed)
    func inkRate(_ e: CAEmitterLayer) -> Float { e.emitterCells?.first { $0.name == "ink" }?.birthRate ?? -1 }
    let rates = first.map(inkRate)
    // 每个 token 只把最后一行加宽一点点：≤1pt 的几何、<10% 的出生率都不写
    var grown = lines
    grown[2].size.width += 0.8
    layer.update(rects: grown, color: CGColor(gray: 0.1, alpha: 1))
    XCTAssertEqual(layer.emitterLayers.map(\.frame), frames)
    XCTAssertEqual(layer.emitterLayers.map(inkRate), rates)
    // 明显变宽才写
    grown[2].size.width += 40
    layer.update(rects: grown, color: CGColor(gray: 0.1, alpha: 1))
    XCTAssertEqual(layer.emitterLayers[2].frame.width, grown[2].width, accuracy: 1e-6)
    XCTAssertGreaterThan(inkRate(layer.emitterLayers[2]), rates[2] * 1.1)
    // 折出新的一行：已有发射器原样保留，只在尾部加
    layer.update(rects: grown + [CGRect(x: 0, y: 68, width: 60, height: 18)], color: CGColor(gray: 0.1, alpha: 1))
    XCTAssertEqual(layer.emitterLayers.count, 4)
    XCTAssertTrue(zip(first, layer.emitterLayers).allSatisfy { $0 === $1 })
    // 换色整批重建：种子按行序号，跟原来一样
    layer.update(rects: grown, color: CGColor(gray: 0.6, alpha: 1))
    XCTAssertFalse(layer.emitterLayers[0] === first[0])
    XCTAssertEqual(layer.emitterLayers.map(\.seed), seeds)
    XCTAssertEqual(Set(seeds).count, seeds.count, "各行种子不同")
  }

  func testUsableRectsDropNonFiniteOrigins() {
    let bad = [CGRect(x: CGFloat.nan, y: 0, width: 50, height: 18), CGRect(x: 0, y: CGFloat.infinity, width: 50, height: 18)]
    XCTAssertTrue(SpoilerDustMath.usableRects(bad).isEmpty)
    XCTAssertTrue(SpoilerDustMath.staticDots(in: bad + [CGRect(x: 1e300, y: 0, width: 50, height: 18)]).allSatisfy { $0.center.x.isFinite })
  }

  func testWithoutPrivateBehaviorsNothingCrashesAndCompletionFires() {
    let saved = SpoilerEmitterBehavior.factory
    SpoilerEmitterBehavior.factory = { _ in nil }
    defer { SpoilerEmitterBehavior.factory = saved }
    let layer = SpoilerDustLayer(animated: true)
    layer.contentsScale = 2
    layer.frame = CGRect(x: 0, y: 0, width: 320, height: 70)
    layer.update(rects: lines, color: CGColor(gray: 0.1, alpha: 1))
    XCTAssertEqual(layer.emitterLayers.count, lines.count)
    XCTAssertFalse(layer.hasPullBehavior)
    for emitter in layer.emitterLayers {
      for cell in emitter.emitterCells ?? [] { XCTAssertLessThan(cell.alphaSpeed, 0, "退化：只淡出") }
    }
    let mask = SpoilerTextRevealMask(bounds: layer.bounds, spoilerRects: lines)
    let done = expectation(description: "completion")
    layer.reveal(at: CGPoint(x: 150, y: 33), textMask: mask) { done.fulfill() }
    XCTAssertTrue(layer.isRevealing)
    layer.update(rects: [], color: CGColor(gray: 0.5, alpha: 1))
    XCTAssertEqual(layer.rects, lines, "揭开过程中不再响应 update")
    wait(for: [done], timeout: 1)
  }

  func testRevealWithBehaviorsCompletes() {
    let layer = SpoilerDustLayer(animated: true)
    layer.contentsScale = 2
    layer.frame = CGRect(x: 0, y: 0, width: 320, height: 70)
    layer.update(rects: lines, color: CGColor(gray: 0.1, alpha: 1))
    let point = CGPoint(x: 150, y: 33)
    let start = Date()
    let done = expectation(description: "completion")
    layer.reveal(at: point, textMask: SpoilerTextRevealMask(bounds: layer.bounds, spoilerRects: lines)) { done.fulfill() }
    XCTAssertNotNil(layer.mask, "圆里的点要被挖掉")
    for emitter in layer.emitterLayers { XCTAssertEqual(emitter.birthRate, 0, "揭开后不再补点") }
    wait(for: [done], timeout: 1.5)
    XCTAssertEqual(Date().timeIntervalSince(start), SpoilerDustMath.revealDuration(from: point, rects: lines), accuracy: 0.15)
  }

  func testReducedMotionRevealCrossFades() {
    let layer = SpoilerDustLayer(animated: false)
    layer.contentsScale = 2
    layer.frame = CGRect(x: 0, y: 0, width: 320, height: 70)
    layer.update(rects: lines, color: CGColor(gray: 0.1, alpha: 1))
    XCTAssertTrue(layer.emitterLayers.isEmpty)
    XCTAssertEqual(layer.staticDotLayers.count, SpoilerDustMath.staticShadeOpacities.count)
    let start = Date()
    let done = expectation(description: "completion")
    layer.reveal(at: .zero, textMask: SpoilerTextRevealMask(bounds: layer.bounds, spoilerRects: lines)) { done.fulfill() }
    wait(for: [done], timeout: 1)
    XCTAssertEqual(Date().timeIntervalSince(start), SpoilerDustMath.reducedMotionRevealDuration, accuracy: 0.15)
  }

  func testPresentationCopyKeepsState() {
    let layer = SpoilerDustLayer(animated: true)
    layer.update(rects: lines, color: CGColor(gray: 0.1, alpha: 1))
    let copy = SpoilerDustLayer(layer: layer)
    XCTAssertEqual(copy.rects, lines)
    XCTAssertFalse(copy.isRevealing)
    XCTAssertNotNil(SpoilerTextRevealMask(layer: SpoilerTextRevealMask(bounds: .zero, spoilerRects: [])))
  }
}
