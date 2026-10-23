import SwiftUI
import os

/// 删除消息时整条散成灰再消失（research-chat-cards §12，学 Telegram ChatHistoryListNode 的删除动画）。
/// 每行挂一个看不见的锚点（MessageDustAnchor）；删的那一刻按锚点在屏幕上的位置截下这一行，
/// 交给 window 上的 Metal 覆盖层去散，数据照常立刻删（行马上让位，灰在上面飘完自己收）。
/// 减弱动态效果 / 没截到 / mac：退回普通淡出。
@MainActor
enum MessageDust {
    static let log = Logger(subsystem: "MemoryPalace", category: "dust")

    static func vanish(key: String, delete: @escaping () -> Void) {
        #if os(iOS)
        if let reason = tryDust(key: key) {
            log.notice("dust fallback: \(reason, privacy: .public)")
        } else {
            delete()
            return
        }
        #endif
        withAnimation(.easeOut(duration: 0.25)) { delete() }
    }

    /// 多选批量删（research-multi-select-bubbles §3）：看得见的几条各散一次灰（屏外的截不到、直接删），
    /// 数据只删一次。一条都没散成（屏外 / 减弱动态 / mac）就整体淡出
    static func vanish(keys: [String], delete: @escaping () -> Void) {
        #if os(iOS)
        var dusted = 0
        for key in keys where dusted < maxBatchDust && tryDust(key: key) == nil { dusted += 1 }
        if dusted > 0 {
            delete()
            return
        }
        #endif
        withAnimation(.easeOut(duration: 0.25)) { delete() }
    }

    /// 一屏顶多十来条；每条截图要画一遍列表层，封顶防选了几百条时卡一下
    private static let maxBatchDust = 16

    #if os(iOS)
    /// 散成灰成功返回 nil；退回淡出时返回原因（日志：subsystem MemoryPalace / category dust）
    private static func tryDust(key: String) -> String? {
        if UIAccessibility.isReduceMotionEnabled { return "reduce-motion" }
        guard let anchor = MessageDustAnchorRegistry.anchor(for: key) else { return "no-anchor" }
        guard let shot = MessageSnapshot.capture(anchor) else { return "no-snapshot" }
        guard DustOverlayView.show(shot) else { return "overlay-failed" }
        log.notice("dust start: \(shot.frameInWindow.debugDescription, privacy: .public) clip \(shot.clipInWindow.debugDescription, privacy: .public) opaque \(MessageSnapshot.opaqueFraction(shot.image), privacy: .public)")
        return nil
    }
    #endif
}

#if os(iOS)
import UIKit
import MetalKit

// MARK: - 锚点

enum MessageDustAnchorRegistry {
    private static let anchors = NSMapTable<NSString, UIView>.strongToWeakObjects()

    static func anchor(for key: String) -> UIView? {
        guard let view = anchors.object(forKey: key as NSString), view.window != nil else { return nil }
        return view
    }

    static func register(_ view: UIView, key: String) { anchors.setObject(view, forKey: key as NSString) }

    static func unregister(_ view: UIView, key: String) {
        if anchors.object(forKey: key as NSString) === view { anchors.removeObject(forKey: key as NSString) }
    }
}

/// 行背景里的透明锚点：只提供「这一行在屏幕上的哪」
struct MessageDustAnchor: UIViewRepresentable {
    let key: String

    final class AnchorView: UIView {
        var key = "" {
            didSet {
                guard key != oldValue else { return }
                MessageDustAnchorRegistry.unregister(self, key: oldValue)
                if window != nil { MessageDustAnchorRegistry.register(self, key: key) }
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { MessageDustAnchorRegistry.register(self, key: key) }
            else { MessageDustAnchorRegistry.unregister(self, key: key) }
        }
    }

    func makeUIView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.key = key
        return v
    }

    func updateUIView(_ view: AnchorView, context: Context) { view.key = key }
}

// MARK: - 截图

struct MessageSnapshot {
    let image: CGImage
    /// 截下来的这块在 window 里的位置（只含屏幕上看得见的部分）
    let frameInWindow: CGRect
    /// 灰能飘的范围（列表在 window 里的可见区），出了就裁掉
    let clipInWindow: CGRect
    weak var window: UIWindow?

    /// 只画列表本身（不带顶栏 / 输入框 / 浮层）：按列表到 window 的仿射把它画进这一块。
    /// 列表是整体旋转 180° 的反转列表，仿射从三个点现算，不假设方向
    static func capture(_ anchor: UIView) -> MessageSnapshot? {
        guard let window = anchor.window else { return nil }
        var source: UIView = window
        var node = anchor.superview
        while let cur = node {
            if cur is UIScrollView { source = cur; break }
            node = cur.superview
        }
        let clip = source.convert(source.bounds, to: window).intersection(window.bounds)
        let rect = anchor.convert(anchor.bounds, to: window).intersection(clip).integral
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }

        let origin = source.convert(CGPoint.zero, to: window)
        let ex = source.convert(CGPoint(x: 1, y: 0), to: window)
        let ey = source.convert(CGPoint(x: 0, y: 1), to: window)
        let toWindow = CGAffineTransform(a: ex.x - origin.x, b: ex.y - origin.y,
                                         c: ey.x - origin.x, d: ey.y - origin.y,
                                         tx: origin.x, ty: origin.y)
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            ctx.cgContext.concatenate(toWindow)
            source.drawHierarchy(in: source.bounds, afterScreenUpdates: false)
        }
        guard let cg = image.cgImage else { return nil }
        return MessageSnapshot(image: cg, frameInWindow: rect, clipInWindow: clip, window: window)
    }
}

extension MessageSnapshot {
    /// 截图里不透明像素占比（缩到 32×32 数）：0 = 截了个空白，灰也是透明的
    static func opaqueFraction(_ image: CGImage) -> Double {
        let n = 32
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return -1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        let px = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        var opaque = 0
        for i in 0..<(n * n) where px[i * 4 + 3] > 16 { opaque += 1 }
        return Double(opaque) / Double(n * n)
    }
}

// MARK: - 覆盖层

/// window 上的透明 Metal 视图，不接触摸；没有在散的就自己摘掉
final class DustOverlayView: MTKView, MTKViewDelegate {
    private static weak var current: DustOverlayView?
    private let renderer: DustEffectRenderer
    private var lastTime: CFTimeInterval?

    static func show(_ shot: MessageSnapshot) -> Bool {
        guard let window = shot.window else { return false }
        let overlay: DustOverlayView
        if let existing = current, existing.window === window, existing.frame == shot.clipInWindow {
            overlay = existing
        } else {
            guard let renderer = DustEffectRenderer() else {
                MessageDust.log.notice("dust: renderer nil (Metal / default library)")
                return false
            }
            current?.finish()
            overlay = DustOverlayView(frame: shot.clipInWindow, renderer: renderer)
            window.addSubview(overlay)
            current = overlay
        }
        let local = shot.frameInWindow.offsetBy(dx: -shot.clipInWindow.minX, dy: -shot.clipInWindow.minY)
        guard overlay.renderer.add(frame: local, image: shot.image) else {
            MessageDust.log.notice("dust: add failed \(local.debugDescription, privacy: .public)")
            if overlay.renderer.isEmpty { overlay.finish() }
            return false
        }
        overlay.isPaused = false
        return true
    }

    private init(frame: CGRect, renderer: DustEffectRenderer) {
        self.renderer = renderer
        super.init(frame: frame, device: renderer.device)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat = DustEffectRenderer.pixelFormat
        framebufferOnly = true
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 120
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func finish() {
        isPaused = true
        delegate = nil
        removeFromSuperview()
        if Self.current === self { Self.current = nil }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastTime.map { Float(min(max(now - $0, 0), 0.1)) } ?? 0
        lastTime = now
        guard let commandBuffer = renderer.queue.makeCommandBuffer() else { return }
        renderer.encodeStep(into: commandBuffer, deltaTime: dt)
        if let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            renderer.encodeDraw(into: encoder, viewport: bounds.size)
            encoder.endEncoding()
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
        if renderer.isEmpty { finish() }
    }
}
#endif
