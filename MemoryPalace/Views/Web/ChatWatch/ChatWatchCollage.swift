#if os(iOS)
import UIKit

/// 一起看的画面拼成一张（plan-watch-together-v2 V4，借 salle-obscure §7.3）：
/// 格宽 640、缝 2 像素、黑底，每格左上烧片内时间码；格数见 `ChatWatchPerception.collageGrid`
enum ChatWatchCollage {
    static let cellWidth: CGFloat = 640
    static let gap: CGFloat = 2

    static func render(_ frames: [(time: Double, jpeg: Data)]) -> Data? {
        let images = frames.compactMap { f in UIImage(data: f.jpeg).map { (time: f.time, image: $0) } }
        guard let first = images.first?.image, first.size.width > 0 else { return nil }
        let cellHeight = (cellWidth * first.size.height / first.size.width).rounded()
        let (cols, rows) = ChatWatchPerception.collageGrid(images.count)
        let size = CGSize(width: CGFloat(cols) * cellWidth + CGFloat(cols - 1) * gap,
                          height: CGFloat(rows) * cellHeight + CGFloat(rows - 1) * gap)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let label: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 26, weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        let collage = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (i, item) in images.enumerated() {
                let cell = CGRect(x: CGFloat(i % cols) * (cellWidth + gap), y: CGFloat(i / cols) * (cellHeight + gap),
                                  width: cellWidth, height: cellHeight)
                item.image.draw(in: fit(item.image.size, in: cell))
                let text = NSAttributedString(string: ChatWatchPerception.clock(item.time), attributes: label)
                let box = CGRect(x: cell.minX, y: cell.minY, width: text.size().width + 16, height: text.size().height + 8)
                UIColor.black.withAlphaComponent(0.6).setFill()
                ctx.fill(box)
                text.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4))
            }
        }
        return collage.jpegData(compressionQuality: 0.7)
    }

    /// 「看这里」3+1（v2 V6，借 salle-obscure §7.7）：上排三小张 = 往前几十秒的切镜帧，下面一大张 = 按下那一刻
    static func renderLookHere(earlier: [(time: Double, jpeg: Data)], now: (time: Double, jpeg: Data)) -> Data? {
        guard let main = UIImage(data: now.jpeg), main.size.width > 0 else { return nil }
        let small = earlier.suffix(3).compactMap { f in UIImage(data: f.jpeg).map { (time: f.time, image: $0) } }
        let smallWidth: CGFloat = 400
        let width = smallWidth * 3 + gap * 2
        let aspect = main.size.height / main.size.width
        let smallHeight = small.isEmpty ? 0 : (smallWidth * aspect).rounded()
        let mainHeight = (width * aspect).rounded()
        let size = CGSize(width: width, height: smallHeight + (small.isEmpty ? 0 : gap) + mainHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (i, item) in small.enumerated() {
                let cell = CGRect(x: CGFloat(i) * (smallWidth + gap), y: 0, width: smallWidth, height: smallHeight)
                item.image.draw(in: fit(item.image.size, in: cell))
                stamp(item.time, at: cell.origin, size: 22, in: ctx)
            }
            let mainRect = CGRect(x: 0, y: size.height - mainHeight, width: width, height: mainHeight)
            main.draw(in: fit(main.size, in: mainRect))
            stamp(now.time, at: mainRect.origin, size: 30, in: ctx)
        }
        return image.jpegData(compressionQuality: 0.75)
    }

    private static func stamp(_ time: Double, at origin: CGPoint, size: CGFloat, in ctx: UIGraphicsImageRendererContext) {
        let text = NSAttributedString(string: ChatWatchPerception.clock(time), attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .bold), .foregroundColor: UIColor.white,
        ])
        let box = CGRect(x: origin.x, y: origin.y, width: text.size().width + 16, height: text.size().height + 8)
        UIColor.black.withAlphaComponent(0.6).setFill()
        ctx.fill(box)
        text.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4))
    }

    private static func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}
#endif
