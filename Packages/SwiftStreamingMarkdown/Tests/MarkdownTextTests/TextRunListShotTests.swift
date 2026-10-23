// MP fork: 列表并簇（T15）对照图——同一份文档 merge 关（真 SwiftUI 树：序号 / 圆点由 OrderedListView / UnorderedListView
// 画，段落视图摆在 SwiftUI 排出的位置）和 merge 开（一个段落簇视图，标记由布局片段画）各出一张 PNG，再出一张差异图。
// 只出图、报差异像素，不判过不过（逐行几何由 TextRunGeometryTests 判）。
// swift build 不编 asset catalog，圆点颜色（Primary450，SwiftUI 树和段落簇都用它）在测试里是透明的。出图前：
//   swift build --build-tests
//   B=.build/arm64-apple-macosx/debug/SwiftStreamingMarkdown_SwiftStreamingMarkdown.bundle
//   xcrun actool Sources/MarkdownText/Resources/Assets.xcassets --compile $B --platform macosx --minimum-deployment-target 15.0
//   /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string mpmd.test.resources" $B/Info.plist
//   MP_CROSSLIST_SHOTS=<目录> swift test --skip-build --filter TextRunListShot
// （重新 build 会把 Info.plist 写回去，所以最后一步要 --skip-build）
#if os(macOS)

import AppKit
@testable import SwiftStreamingMarkdown
import SwiftUI
import Testing

@Suite("Text run list shots (mac)")
@MainActor
struct TextRunListShotTests {
  private let scale: CGFloat = 2
  private let width: CGFloat = 343

  private func config(merge: Bool) -> MarkdownRenderConfig {
    func fonts(_ size: CGFloat, _ weight: PlatformFont.Weight) -> TextFonts {
      let normal = PlatformFont.systemFont(ofSize: size, weight: weight)
      let bold = PlatformFont.systemFont(ofSize: size, weight: .bold)
      return TextFonts(normal: normal, italic: NSFontManager.shared.convert(normal, toHaveTrait: .italicFontMask),
                       bold: bold, boldItalic: NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask),
                       preferredLetterSpacing: nil, preferredLineHeight: nil)
    }
    let ink = NSColor(red: 0.24, green: 0.22, blue: 0.20, alpha: 1)
    let body = fonts(13.5 * 1.2, .regular)
    let h3 = fonts(15 * 1.2, .semibold)
    return MarkdownRenderConfig(
      headingStyle: .init(h1Font: fonts(20 * 1.2, .bold), h2Font: fonts(17 * 1.2, .semibold), h3Font: h3, h4Font: h3, h5Font: h3, h6Font: h3, textColor: ink),
      orderedListStyle: .init(textFonts: body, textColor: ink),
      paragraphStyle: .init(textFonts: body, textColor: ink),
      citationConfig: .init(isEnabled: false, font: PlatformFont.systemFont(ofSize: 12), textColor: ink, backgroundColor: .white),
      mergesTextRuns: merge)
  }

  private func root(_ markdown: String, _ config: MarkdownRenderConfig) -> some View {
    BlockView(renderables: MarkdownParserImpl.renderables(for: markdown, config: config))
      .environment(\.markdownConfig, config)
      .environment(\.colorScheme, .light)
      .frame(width: width, alignment: .topLeading)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// 真 SwiftUI 树里各段落视图的框和内容
  private func hostedParagraphs(_ markdown: String, _ config: MarkdownRenderConfig) -> (CGSize, [(NSMutableAttributedString, CGFloat?, CGRect)]) {
    let hosting = NSHostingView(rootView: root(markdown, config))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 3000), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = hosting
    defer { window.close() }
    let size = hosting.fittingSize
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    var result: [(NSMutableAttributedString, CGFloat?, CGRect)] = []
    func walk(_ view: NSView) {
      if let paragraph = view as? ParagraphNSView {
        result.append((paragraph.paragraphContents, paragraph.lineSpacing, paragraph.convert(paragraph.bounds, to: hosting)))
      }
      view.subviews.forEach(walk)
    }
    walk(hosting)
    return (size, result)
  }

  /// 不进窗口的段落视图自己画（进了窗口的 TextKit 2 视图走图层，cacheDisplay 拍不到）
  private func paragraphImage(_ contents: NSMutableAttributedString, lineSpacing: CGFloat?, size: CGSize) -> CGImage? {
    let view = ParagraphNSView.make()
    view.appearance = NSAppearance(named: .aqua)
    view.frame = CGRect(origin: .zero, size: size)
    view.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: false)
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.cgImage
  }

  private func canvas(_ size: CGSize) -> CGContext {
    let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    return ctx
  }

  /// 把图贴到画布上（frame 是 y 向下的点坐标）
  private func paste(_ image: CGImage, in frame: CGRect, canvasHeight: CGFloat, on ctx: CGContext) {
    let rect = CGRect(x: frame.minX * scale, y: (canvasHeight - frame.maxY) * scale, width: frame.width * scale, height: frame.height * scale)
    ctx.draw(image, in: rect)
  }

  /// merge 关：ImageRenderer 出 SwiftUI 画的序号 / 圆点（段落视图在 ImageRenderer 里是黄底占位），
  /// 抹掉占位，再把各段落视图贴到 SwiftUI 排出的框里
  private func offImage(_ markdown: String) -> CGImage? {
    let config = config(merge: false)
    let (size, paragraphs) = hostedParagraphs(markdown, config)
    let renderer = ImageRenderer(content: root(markdown, config))
    renderer.scale = scale
    guard let markers = renderer.cgImage else { return nil }
    let ctx = canvas(size)
    ctx.draw(markers, in: CGRect(x: 0, y: 0, width: markers.width, height: markers.height))
    // 占位和段落视图同框：先整框抹白（左右只放宽 0.5pt，圆点离文字 1pt），残边再按黄 / 红两色抹
    ctx.setFillColor(NSColor.white.cgColor)
    for (_, _, frame) in paragraphs {
      let r = frame.insetBy(dx: -0.5, dy: -1)
      ctx.fill(CGRect(x: r.minX * scale, y: (size.height - r.maxY) * scale, width: r.width * scale, height: r.height * scale))
    }
    if let data = ctx.data {
      let pixels = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * ctx.height)
      for (_, _, frame) in paragraphs {
        let x0 = max(0, Int((frame.minX - 1) * scale)), x1 = min(ctx.width, Int((frame.maxX + 1) * scale))
        // CGContext 的内存是从上往下排的
        let y0 = max(0, Int((frame.minY - 1) * scale)), y1 = min(ctx.height, Int((frame.maxY + 1) * scale))
        for y in y0..<y1 {
          for x in x0..<x1 {
            let i = y * ctx.bytesPerRow + x * 4
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if r > 180 && b < 140 && (g > 150 || g < 110) {
              pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255; pixels[i + 3] = 255
            }
          }
        }
      }
    }
    for (contents, lineSpacing, frame) in paragraphs {
      if let image = paragraphImage(contents, lineSpacing: lineSpacing, size: frame.size) {
        paste(image, in: frame, canvasHeight: size.height, on: ctx)
      }
    }
    return ctx.makeImage()
  }

  /// merge 开：一个段落簇视图
  private func onImage(_ markdown: String) -> (CGImage?, Int) {
    let config = config(merge: true)
    let (size, paragraphs) = hostedParagraphs(markdown, config)
    let ctx = canvas(size)
    for (contents, lineSpacing, frame) in paragraphs {
      if let image = paragraphImage(contents, lineSpacing: lineSpacing, size: frame.size) {
        paste(image, in: frame, canvasHeight: size.height, on: ctx)
      }
    }
    return (ctx.makeImage(), paragraphs.count)
  }

  private struct Diff {
    let image: CGImage?
    let differing: Int
    let total: Int
  }

  /// 差异图：两张叠成淡灰底，通道差 > 64 的像素标洋红
  private func diff(_ a: CGImage, _ b: CGImage) -> Diff {
    let w = max(a.width, b.width), h = max(a.height, b.height)
    func pixels(_ image: CGImage) -> [UInt8] {
      var buffer = [UInt8](repeating: 255, count: w * h * 4)
      let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.draw(image, in: CGRect(x: 0, y: h - image.height, width: image.width, height: image.height))
      return buffer
    }
    let pa = pixels(a), pb = pixels(b)
    var out = [UInt8](repeating: 255, count: w * h * 4)
    var differing = 0
    for i in stride(from: 0, to: pa.count, by: 4) {
      let d = max(abs(Int(pa[i]) - Int(pb[i])), abs(Int(pa[i + 1]) - Int(pb[i + 1])), abs(Int(pa[i + 2]) - Int(pb[i + 2])))
      if d > 64 {
        differing += 1
        out[i] = 230; out[i + 1] = 0; out[i + 2] = 140; out[i + 3] = 255
      } else {
        let luminance = UInt8(min(255, 200 + Int(min(pa[i], pb[i])) / 5))
        out[i] = luminance; out[i + 1] = luminance; out[i + 2] = luminance; out[i + 3] = 255
      }
    }
    let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return Diff(image: ctx.makeImage(), differing: differing, total: w * h)
  }

  private func write(_ image: CGImage?, to path: String) throws {
    guard let image else { return }
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }

  @Test("merge off / on / diff PNGs")
  func shots() throws {
    NSApplication.shared.appearance = NSAppearance(named: .aqua)
    let dir = ProcessInfo.processInfo.environment["MP_CROSSLIST_SHOTS"] ?? NSTemporaryDirectory()
    let docs: [(String, String)] = [
      ("unordered", TextRunGeometryTests.unorderedDoc),
      ("ordered", TextRunGeometryTests.orderedDoc),
      ("nested", TextRunGeometryTests.nestedDoc),
      ("multi-paragraph", TextRunGeometryTests.multiParagraphItemDoc),
      ("mixed", TextRunGeometryTests.mixedDoc),
    ]
    print("[SHOT] bullet color \(PlatformColor(Color.Theme.Foreground.Primary.Primary450))")
    for (name, markdown) in docs {
      let off = try #require(offImage(markdown))
      let (onImage, views) = onImage(markdown)
      let on = try #require(onImage)
      #expect(views == 1, "\(name): merge on should be one view")
      let d = diff(off, on)
      try write(off, to: "\(dir)/\(name)-off.png")
      try write(on, to: "\(dir)/\(name)-on.png")
      try write(d.image, to: "\(dir)/\(name)-diff.png")
      print("[SHOT] \(name) \(off.width)x\(off.height) vs \(on.width)x\(on.height) differing=\(d.differing)/\(d.total) (\(String(format: "%.3f", Double(d.differing) * 100 / Double(d.total)))%)")
    }
  }
}

#endif
