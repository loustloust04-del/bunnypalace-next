#if os(iOS)
import SceneKit
import SpriteKit
import UIKit

/// 电脑屏幕贴图（小样 drawCrt）：暗屏 + 像素绿字 + 光标 + 扫描线 + 滚动亮带 + 四角暗角，扫描线只在这里。
/// 静的部分（字、扫描线、暗角）各画成一张图，动的只有光标闪、亮带走、整体亮度，每帧只改几个节点属性。
final class TerminalCRTScreen {
    struct Row: Equatable {
        let text: String
        let color: UInt
    }

    let material = SCNMaterial()
    private let scene: SKScene
    private let size: CGSize
    private let baseline: CGFloat
    private let text = SKSpriteNode()
    private let cursor = SKSpriteNode()
    private let band = SKSpriteNode()
    private var content: (title: String, rows: [Row])?

    /// 一体机 320 × 240，笔记本 / 台式屏更扁 320 × 196
    init(tall: Bool) {
        size = CGSize(width: 320, height: tall ? 240 : 196)
        baseline = tall ? 52 : 44
        scene = SKScene(size: size)
        scene.backgroundColor = TerminalSceneBuilder.color(0x0b100d)
        scene.scaleMode = .fill
        // 没有自己的动画，节点全由场景的渲染回调显式改：一直停着，SpriteKit 不跑自己的更新循环
        scene.isPaused = true
        // SceneKit 把 SKScene 贴到几何上是上下颠倒的：整层翻一次，翻回来
        let layer = SKNode()
        layer.yScale = -1
        layer.position = CGPoint(x: 0, y: size.height)
        scene.addChild(layer)
        let full = { (node: SKSpriteNode, z: CGFloat) in
            node.anchorPoint = .zero
            node.size = self.size
            node.zPosition = z
            layer.addChild(node)
        }
        full(text, 1)
        full(cursor, 1)
        let lines = SKSpriteNode(texture: SKTexture(image: Self.scanlines(size)))
        full(lines, 2)
        band.texture = SKTexture(image: Self.bandImage(width: size.width))
        band.anchorPoint = CGPoint(x: 0, y: 0.5)
        band.size = CGSize(width: size.width, height: 60)
        band.zPosition = 3
        layer.addChild(band)
        let vignette = SKSpriteNode(texture: SKTexture(image: Self.vignette(size)))
        full(vignette, 4)

        material.lightingModel = .constant
        material.diffuse.contents = scene
    }

    /// 字变了才重画（主机名 / Agent 行）
    func setContent(title: String, rows: [Row]) {
        if let content, content.title == title, content.rows == rows { return }
        content = (title, rows)
        text.texture = SKTexture(image: Self.textImage(size, title: title, rows: rows, y0: baseline))
        cursor.texture = SKTexture(image: Self.cursorImage(size, y: baseline + 46 + CGFloat(rows.count) * 28))
    }

    /// power 0 = 黑屏（只剩扫描线和暗角），1 = 亮；`time` 驱动光标闪和亮带，nil = 停着（光标亮、不走亮带）
    func update(power: Float, time: TimeInterval?) {
        let p = CGFloat(power)
        text.alpha = p
        let blinkOn = time.map { Int($0 / 0.52) % 2 == 1 } ?? true
        cursor.alpha = blinkOn ? p : 0
        if let time, p > 0 {
            let travel = Double(size.height + 80)
            let y = (time / 0.018).truncatingRemainder(dividingBy: travel) - 40
            band.isHidden = false
            band.alpha = p
            band.position = CGPoint(x: 0, y: size.height - CGFloat(y))
        } else {
            band.isHidden = true
        }
    }

    // MARK: 画图

    private static func renderer(_ size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    private static func glow(_ color: UIColor, blur: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = .zero
        return shadow
    }

    private static func draw(_ string: String, at point: CGPoint, font: UIFont, color: UIColor, blur: CGFloat) {
        (string as NSString).draw(at: CGPoint(x: point.x, y: point.y - font.ascender),
                                  withAttributes: [.font: font, .foregroundColor: color,
                                                   .shadow: glow(TerminalSceneBuilder.color(0x87D6B0), blur: blur)])
    }

    private static let titleFont = UIFont(name: "Menlo-Bold", size: 22) ?? .monospacedSystemFont(ofSize: 22, weight: .bold)
    private static let rowFont = UIFont(name: "Menlo", size: 17) ?? .monospacedSystemFont(ofSize: 17, weight: .regular)

    private static func textImage(_ size: CGSize, title: String, rows: [Row], y0: CGFloat) -> UIImage {
        renderer(size).image { _ in
            draw(title, at: CGPoint(x: 26, y: y0), font: titleFont, color: TerminalSceneBuilder.color(0xa6ecc8), blur: 10)
            for (i, row) in rows.enumerated() {
                draw(row.text, at: CGPoint(x: 26, y: y0 + 40 + CGFloat(i) * 28), font: rowFont,
                     color: TerminalSceneBuilder.color(row.color), blur: 6)
            }
            draw("> ", at: CGPoint(x: 26, y: y0 + 46 + CGFloat(rows.count) * 28), font: rowFont,
                 color: TerminalSceneBuilder.color(0x87D6B0), blur: 6)
        }
    }

    private static func cursorImage(_ size: CGSize, y: CGFloat) -> UIImage {
        renderer(size).image { _ in
            let x = 26 + ("> " as NSString).size(withAttributes: [.font: rowFont]).width
            draw("█", at: CGPoint(x: x, y: y), font: rowFont, color: TerminalSceneBuilder.color(0x87D6B0), blur: 6)
        }
    }

    private static func scanlines(_ size: CGSize) -> UIImage {
        renderer(size).image { context in
            context.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.38).cgColor)
            var y: CGFloat = 0
            while y < size.height {
                context.cgContext.fill(CGRect(x: 0, y: y, width: size.width, height: 1.2))
                y += 3
            }
        }
    }

    private static func bandImage(width: CGFloat) -> UIImage {
        renderer(CGSize(width: width, height: 60)).image { context in
            let mint = TerminalSceneBuilder.color(0x87D6B0)
            let colors = [mint.withAlphaComponent(0), mint.withAlphaComponent(0.07), mint.withAlphaComponent(0)].map(\.cgColor) as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) else { return }
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 60), options: [])
        }
    }

    private static func vignette(_ size: CGSize) -> UIImage {
        renderer(size).image { context in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let colors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.75).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            context.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 70, endCenter: center,
                                                 endRadius: hypot(center.x, center.y) * 1.05, options: [.drawsAfterEndLocation])
        }
    }
}
#endif
