import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - 取景数学（纯函数，TwitterCropMathTests 覆盖）

/// 任意比例取景框的裁剪数学。`AvatarCropMath` 只会正方形，横幅是 3:1，另写一份。
/// 坐标模型：图以 displayScale 显示（刚好盖满取景框 × zoom），图中心 = 取景框中心 + offset。
enum TwitterCropMath {
    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 6

    /// 图要**盖满**取景框：宽高两个方向取大的那个比例。
    static func displayScale(imageSize: CGSize, frame: CGSize, zoom: CGFloat) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 0 }
        return max(frame.width / imageSize.width, frame.height / imageSize.height) * zoom
    }

    /// 取景框落在源图上的矩形（源图像素坐标，左上角原点）。
    static func cropRect(imageSize: CGSize, frame: CGSize, zoom: CGFloat, offset: CGSize) -> CGRect {
        let s = displayScale(imageSize: imageSize, frame: frame, zoom: zoom)
        guard s > 0 else { return .zero }
        let x = (imageSize.width * s / 2 - offset.width - frame.width / 2) / s
        let y = (imageSize.height * s / 2 - offset.height - frame.height / 2) / s
        return CGRect(x: x, y: y, width: frame.width / s, height: frame.height / s)
    }

    /// 拖动边界：取景框必须始终被图盖住，不露空。
    static func clampOffset(_ offset: CGSize, imageSize: CGSize, frame: CGSize, zoom: CGFloat) -> CGSize {
        let s = displayScale(imageSize: imageSize, frame: frame, zoom: zoom)
        let maxX = max(0, (imageSize.width * s - frame.width) / 2)
        let maxY = max(0, (imageSize.height * s - frame.height) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }

    /// 以某一点为中心缩放后的新偏移（点和偏移都相对取景框中心）。
    /// 手指下那一点在图上的位置 (p - offset) / zoom 缩放前后不变——两指中间那块才会「钉」在手指下面，
    /// 不会往框中心滑（粟粟：「双指缩放还是有点诡异」）。
    static func zoomedOffset(_ offset: CGSize, from z0: CGFloat, to z1: CGFloat, around point: CGSize) -> CGSize {
        guard z0 > 0 else { return offset }
        let k = z1 / z0
        return CGSize(width: point.width - (point.width - offset.width) * k,
                      height: point.height - (point.height - offset.height) * k)
    }

    /// 把 cropRect 那一块画满 outputSize 的位图，出 JPEG。走平台 draw，EXIF 朝向自动处理。
    static func render(image: PlatformImage, cropRect: CGRect, outputSize: CGSize) -> Data? {
        guard cropRect.width > 0, cropRect.height > 0 else { return nil }
        let kx = outputSize.width / cropRect.width
        let ky = outputSize.height / cropRect.height
        #if canImport(UIKit)
        let drawRect = CGRect(x: -cropRect.minX * kx, y: -cropRect.minY * ky,
                              width: image.size.width * kx, height: image.size.height * ky)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: outputSize, format: format)
            .image { _ in image.draw(in: drawRect) }
            .jpegData(compressionQuality: 0.88)
        #else
        // AppKit 画布原点在左下，y 要从下往上算
        let drawRect = CGRect(x: -cropRect.minX * kx, y: -(image.size.height - cropRect.maxY) * ky,
                              width: image.size.width * kx, height: image.size.height * ky)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(outputSize.width), pixelsHigh: Int(outputSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = outputSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
        #endif
    }
}

// MARK: - 取景界面

/// 选完图先取景：拖动挪位置、双指缩放，框外压暗。头像圆框，横幅 3:1 框。
/// 粟粟 2026-09-24：「选头像/banner 不能左右移动，很痛苦」。
struct TwitterCropSheet: View {
    enum Shape { case avatar, banner }

    let image: PlatformImage
    let shape: Shape
    let onCrop: (Data) -> Void
    let onCancel: () -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    #if os(macOS)
    /// 捏合开始时的状态：整个捏合过程都从它算，不累积误差
    @State private var pinch: (zoom: CGFloat, offset: CGSize, anchor: CGSize)?
    /// 拖动按每帧增量累加（不按起点算）：捏合中途松开一根手指时不会跳
    @State private var lastDrag: CGSize = .zero
    #endif

    private var aspect: CGFloat { shape == .avatar ? 1 : 3 }
    private var outputSize: CGSize {
        shape == .avatar ? CGSize(width: 400, height: 400) : CGSize(width: 1500, height: 500)
    }

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width - 32, (geo.size.height - 160) * aspect)
            let frame = CGSize(width: w, height: w / aspect)
            let s = TwitterCropMath.displayScale(imageSize: image.size, frame: frame, zoom: zoom)

            ZStack {
                Color.black.ignoresSafeArea()

                Image(platformImage: image)
                    .resizable()
                    .frame(width: image.size.width * s, height: image.size.height * s)
                    .offset(offset)
                    // 大图只在固定画布内变化，不能把 ZStack 和按钮一起撑大。
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .allowsHitTesting(false)

                // 框外压暗：destinationOut 挖出取景框
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    cutout(frame).blendMode(.destinationOut)
                }
                .compositingGroup()
                .allowsHitTesting(false)
                outline(frame).allowsHitTesting(false)

                #if os(iOS)
                TwitterCropTouchSurface(zoom: $zoom, offset: $offset, imageSize: image.size, cropFrame: frame)
                    .frame(width: geo.size.width, height: geo.size.height)
                #endif

                VStack {
                    Text(shape == .avatar ? "拖动、双指缩放调整头像 · 双击复位" : "拖动、双指缩放调整横幅 · 双击复位")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.top, 20)
                    Spacer()
                    HStack(spacing: 14) {
                        Button(action: onCancel) {
                            Text("取消")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 24).padding(.vertical, 10)
                                .background(Capsule().fill(Color.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        Button {
                            let rect = TwitterCropMath.cropRect(imageSize: image.size, frame: frame,
                                                                zoom: zoom, offset: offset)
                            if let data = TwitterCropMath.render(image: image, cropRect: rect, outputSize: outputSize) {
                                onCrop(data)
                            }
                        } label: {
                            Text("用这个")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 26).padding(.vertical, 10)
                                .background(Capsule().fill(Color.white))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 28)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            #if os(macOS)
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        // 第一帧记下起点：两指中点相对取景框中心的位置
                        let start = pinch ?? (zoom, offset, CGSize(width: value.startLocation.x - geo.size.width / 2,
                                                                   height: value.startLocation.y - geo.size.height / 2))
                        pinch = start
                        let z = min(max(start.zoom * value.magnification, TwitterCropMath.minZoom), TwitterCropMath.maxZoom)
                        zoom = z
                        offset = TwitterCropMath.clampOffset(
                            TwitterCropMath.zoomedOffset(start.offset, from: start.zoom, to: z, around: start.anchor),
                            imageSize: image.size, frame: frame, zoom: z)
                    }
                    .onEnded { _ in pinch = nil }
                    .simultaneously(with: DragGesture(minimumDistance: 2)   // 0 会把双击复位吞掉
                        .onChanged { value in
                            let delta = CGSize(width: value.translation.width - lastDrag.width,
                                               height: value.translation.height - lastDrag.height)
                            lastDrag = value.translation
                            // 捏合时只缩放不平移：两指的拖动交给缩放中心去处理，不然两套位移叠在一起乱跑
                            guard pinch == nil else { return }
                            offset = TwitterCropMath.clampOffset(
                                CGSize(width: offset.width + delta.width, height: offset.height + delta.height),
                                imageSize: image.size, frame: frame, zoom: zoom)
                        }
                        .onEnded { _ in lastDrag = .zero })
            )
            // 双击复位
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { zoom = 1; offset = .zero }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        #if os(iOS)
        // 只允许通过取消或确认离开取景。
        .interactiveDismissDisabled()
        #endif
    }

    @ViewBuilder private func cutout(_ frame: CGSize) -> some View {
        if shape == .avatar {
            Circle().frame(width: frame.width, height: frame.height)
        } else {
            Rectangle().frame(width: frame.width, height: frame.height)
        }
    }

    @ViewBuilder private func outline(_ frame: CGSize) -> some View {
        if shape == .avatar {
            Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: frame.width, height: frame.height)
        } else {
            Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: frame.width, height: frame.height)
        }
    }
}

#if os(iOS)
/// 同一条触摸流处理平移和捏合；手指数变化时重新取基线，不沿用旧中点。
private struct TwitterCropTouchSurface: UIViewRepresentable {
    @Binding var zoom: CGFloat
    @Binding var offset: CGSize
    let imageSize: CGSize
    let cropFrame: CGSize

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        let reset = UITapGestureRecognizer(target: view, action: #selector(TouchView.resetCrop))
        reset.numberOfTapsRequired = 2
        // 双击识别不能延迟松指通知，否则下一次触摸会沿用已经离开的手指。
        reset.delaysTouchesEnded = false
        view.addGestureRecognizer(reset)
        view.crop = self
        return view
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        uiView.crop = self
    }

    final class TouchView: UIView {
        var crop: TwitterCropTouchSurface?
        private var activeTouches = Set<UITouch>()
        private var previous: (center: CGPoint, distance: CGFloat)?

        private func snapshot() -> (center: CGPoint, distance: CGFloat)? {
            guard (1...2).contains(activeTouches.count) else { return nil }
            let points = activeTouches.map { $0.location(in: self) }
            guard points.count == 2 else { return (points[0], 0) }
            return (CGPoint(x: (points[0].x + points[1].x) / 2,
                            y: (points[0].y + points[1].y) / 2),
                    hypot(points[0].x - points[1].x, points[0].y - points[1].y))
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            activeTouches.formUnion(touches)
            previous = snapshot()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            let current = snapshot()
            defer { previous = current }
            guard let crop, let previous, let current else { return }
            let oldZoom = crop.zoom
            let ratio = previous.distance > 0 && current.distance > 0
                ? current.distance / previous.distance : 1
            let newZoom = min(max(oldZoom * ratio, TwitterCropMath.minZoom), TwitterCropMath.maxZoom)
            let anchor = CGSize(width: previous.center.x - bounds.midX,
                                height: previous.center.y - bounds.midY)
            let scaled = TwitterCropMath.zoomedOffset(crop.offset, from: oldZoom, to: newZoom, around: anchor)
            // 先围绕上一帧中点缩放，再跟随中点移动；平移只计算一次。
            crop.offset = TwitterCropMath.clampOffset(
                CGSize(width: scaled.width + current.center.x - previous.center.x,
                       height: scaled.height + current.center.y - previous.center.y),
                imageSize: crop.imageSize, frame: crop.cropFrame, zoom: newZoom)
            crop.zoom = newZoom
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            activeTouches.subtract(touches)
            // 两指变一指时，以剩下的手指当前位置重新开始，不产生中点跳变。
            previous = snapshot()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            activeTouches.subtract(touches)
            previous = snapshot()
        }

        @objc func resetCrop() {
            activeTouches.removeAll()
            previous = nil
            guard let crop else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                crop.zoom = 1
                crop.offset = .zero
            }
        }
    }
}
#endif
