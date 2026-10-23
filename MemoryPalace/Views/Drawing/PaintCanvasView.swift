import SwiftUI
import QuartzCore
#if os(iOS)
import UIKit
import PencilKit
#else
import AppKit
import CoreImage
#endif

/// 颜料层画布：接触摸 / 鼠标 → DrawingBoardModel；显示 = 颜料位图 + 实时笔迹 + 水彩晕开
#if os(iOS)
final class PaintCanvasUIView: UIView, PaintCanvasDisplay {
    private let paintLayer = CALayer()
    private let liveLayer = CAShapeLayer()
    private let revealLayer = CALayer()
    weak var model: DrawingBoardModel?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        // 输入走手势识别器而不是裸 touches：落笔即 began，按 UIKit 仲裁 sheet 的下拉手势就让位
        //（裸 touches 会被 sheet 的拖动截胡、touchesCancelled，笔画只剩开头一小段）
        addGestureRecognizer(DrawGestureRecognizer(canvas: self))
        backgroundColor = .clear
        for l in [paintLayer, revealLayer, liveLayer] { layer.addSublayer(l) }
        // 水彩颜料层和纸正片叠底（纸纹透上来）
        paintLayer.compositingFilter = "multiplyBlendMode"
        revealLayer.compositingFilter = "multiplyBlendMode"
        liveLayer.compositingFilter = "multiplyBlendMode"
        paintLayer.contentsGravity = .resize
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        paintLayer.frame = bounds; liveLayer.frame = bounds
        CATransaction.commit()
    }


    func showPaint(_ image: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        paintLayer.contents = image
        CATransaction.commit()
    }

    func showLive(_ path: CGPath?, color: CGColor, fill: Bool, lineWidth: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        liveLayer.opacity = 1
        liveLayer.path = path
        liveLayer.fillColor = fill ? color : nil
        liveLayer.strokeColor = fill ? nil : color
        liveLayer.lineWidth = lineWidth
        CATransaction.commit()
    }

    func reveal(_ stroke: RenderedStroke, completion: @escaping () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        revealLayer.frame = stroke.rect
        revealLayer.contents = stroke.image
        revealLayer.opacity = 0
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [weak self] in
            completion()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self?.revealLayer.contents = nil
            CATransaction.commit()
        }
        revealLayer.opacity = 1
        liveLayer.opacity = 0
        CATransaction.commit()
    }
}

/// 颜料层 + 线稿层（PencilKit）装在同一个 UIKit 容器里：自写笔刷时线稿层关交互，触摸按 UIKit 规则落到下面的颜料层
/// （两个 representable 叠 ZStack 的话 SwiftUI 宿主会吞掉穿透的触摸）
final class DrawingCanvasContainer: UIView {
    let paint = PaintCanvasUIView()
    let pencil = PKCanvasView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addSubview(paint)
        addSubview(pencil)
        pencil.backgroundColor = .clear
        pencil.isOpaque = false
        pencil.drawingPolicy = .anyInput
        pencil.isScrollEnabled = false
        pencil.contentInsetAdjustmentBehavior = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        paint.frame = bounds
        pencil.frame = bounds
    }
}

/// 画笔输入：单指 / Pencil，落笔立刻 began（先于 sheet 的拖动识别，把它挤掉）
final class DrawGestureRecognizer: UIGestureRecognizer {
    private weak var canvas: PaintCanvasUIView?
    private var t0: TimeInterval = 0
    private var tracking: UITouch?

    init(canvas: PaintCanvasUIView) {
        self.canvas = canvas
        super.init(target: nil, action: nil)
        delaysTouchesBegan = false
        cancelsTouchesInView = false
    }

    private func point(_ t: UITouch) -> BrushPoint {
        let p = t.preciseLocation(in: view)
        let pressure: CGFloat? = t.type == .pencil && t.maximumPossibleForce > 0 ? t.force / t.maximumPossibleForce : nil
        return BrushPoint(x: p.x, y: p.y, t: t.timestamp - t0, p: pressure)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracking == nil, let t = touches.first else { return }
        tracking = t
        t0 = t.timestamp
        MainActor.assumeIsolated { canvas?.model?.begin(point(t)) }
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracking, touches.contains(t) else { return }
        let pts = (event.coalescedTouches(for: t) ?? [t]).map(point)
        MainActor.assumeIsolated { canvas?.model?.move(pts) }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracking, touches.contains(t) else { return }
        MainActor.assumeIsolated { canvas?.model?.end() }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracking, touches.contains(t) else { return }
        MainActor.assumeIsolated { canvas?.model?.end() }
        state = .cancelled
    }

    override func reset() {
        super.reset()
        tracking = nil
    }

    /// 别的手势（sheet 下拉、外层翻页）都拦不住它
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool { false }
}

struct PaintCanvasRepresentable: UIViewRepresentable {
    let model: DrawingBoardModel

    func makeUIView(context: Context) -> DrawingCanvasContainer {
        let v = DrawingCanvasContainer()
        v.paint.model = model
        model.attach(v.paint)
        v.pencil.drawing = model.lastDrawing
        v.pencil.delegate = context.coordinator
        model.pencilView = v.pencil
        model.syncPencilKitTool()
        // 橡皮：同一笔也擦颜料层（和 PencilKit 的位图橡皮一起识别）
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.erase(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        v.pencil.addGestureRecognizer(pan)
        context.coordinator.eraserPan = pan
        return v
    }

    func updateUIView(_ uiView: DrawingCanvasContainer, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        let model: DrawingBoardModel
        weak var eraserPan: UIPanGestureRecognizer?
        private var t0 = Date()
        init(_ model: DrawingBoardModel) { self.model = model }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            MainActor.assumeIsolated { model.pencilDidChange(canvasView.drawing) }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            g !== eraserPan || MainActor.assumeIsolated { model.tool == .eraser }
        }

        @objc func erase(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            let p = g.location(in: v)
            MainActor.assumeIsolated {
                switch g.state {
                case .began:
                    t0 = Date()
                    model.begin(BrushPoint(x: p.x, y: p.y, t: 0, p: nil))
                case .changed:
                    model.move([BrushPoint(x: p.x, y: p.y, t: Date().timeIntervalSince(t0), p: nil)])
                default:
                    model.end()
                }
            }
        }
    }
}
#else
final class PaintCanvasNSView: NSView, PaintCanvasDisplay {
    private let paintLayer = CALayer()
    private let liveLayer = CAShapeLayer()
    private let revealLayer = CALayer()
    weak var model: DrawingBoardModel?
    private var t0: TimeInterval = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        for l in [paintLayer, revealLayer, liveLayer] {
            layer?.addSublayer(l)
            l.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
        }
        paintLayer.contentsGravity = .resize
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        paintLayer.frame = bounds; liveLayer.frame = bounds
        CATransaction.commit()
    }

    private func point(_ e: NSEvent) -> BrushPoint {
        let p = convert(e.locationInWindow, from: nil)
        let pressure: CGFloat? = e.subtype == .tabletPoint ? CGFloat(e.pressure) : nil
        return BrushPoint(x: p.x, y: p.y, t: e.timestamp - t0, p: pressure)
    }

    override func mouseDown(with e: NSEvent) { t0 = e.timestamp; model?.begin(point(e)) }
    override func mouseDragged(with e: NSEvent) { model?.move([point(e)]) }
    override func mouseUp(with e: NSEvent) { model?.end() }

    func showPaint(_ image: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        paintLayer.contents = image
        CATransaction.commit()
    }

    func showLive(_ path: CGPath?, color: CGColor, fill: Bool, lineWidth: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        liveLayer.opacity = 1
        liveLayer.path = path
        liveLayer.fillColor = fill ? color : nil
        liveLayer.strokeColor = fill ? nil : color
        liveLayer.lineWidth = lineWidth
        CATransaction.commit()
    }

    func reveal(_ stroke: RenderedStroke, completion: @escaping () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        revealLayer.frame = stroke.rect
        revealLayer.contents = stroke.image
        revealLayer.opacity = 0
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setCompletionBlock { [weak self] in
            completion()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self?.revealLayer.contents = nil
            CATransaction.commit()
        }
        revealLayer.opacity = 1
        liveLayer.opacity = 0
        CATransaction.commit()
    }
}

struct PaintCanvasRepresentable: NSViewRepresentable {
    let model: DrawingBoardModel

    func makeNSView(context: Context) -> PaintCanvasNSView {
        let v = PaintCanvasNSView()
        v.model = model
        model.attach(v)
        return v
    }

    func updateNSView(_ nsView: PaintCanvasNSView, context: Context) {}
}
#endif
