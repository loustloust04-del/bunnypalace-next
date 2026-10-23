#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// Custom drawing only: NSScrollView still owns position, hit testing and accessibility.
/// Overlay placement leaves the content width untouched. AppKit owns visibility:
/// reveal while scrolling, then fade out; only the four-point thumb is custom drawn.
class MacSlimScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard isEnabled, knobProportion < 1 else { return }
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let vertical = bounds.height > bounds.width
        let thickness: CGFloat = 4
        let thumb = vertical
            ? NSRect(x: knob.midX - thickness / 2, y: knob.minY, width: thickness, height: knob.height)
            : NSRect(x: knob.minX, y: knob.midY - thickness / 2, width: knob.width, height: thickness)
        NSColor.secondaryLabelColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).fill()
    }

    /// Replacing the scroller must not replace the clip/document view or reset its position.
    static func install(in scroll: NSScrollView) {
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        if scroll.hasVerticalScroller, let old = scroll.verticalScroller, !(old is MacSlimScroller) {
            scroll.verticalScroller = replacement(for: old)
        }
        if scroll.hasHorizontalScroller, let old = scroll.horizontalScroller, !(old is MacSlimScroller) {
            scroll.horizontalScroller = replacement(for: old)
        }
    }

    private static func replacement(for old: NSScroller) -> MacSlimScroller {
        let scroller = MacSlimScroller(frame: old.frame)
        scroller.scrollerStyle = .overlay
        scroller.controlSize = old.controlSize
        scroller.target = old.target
        scroller.action = old.action
        scroller.doubleValue = old.doubleValue
        scroller.knobProportion = old.knobProportion
        scroller.isEnabled = old.isEnabled
        return scroller
    }
}

/// Keep native knob dragging, but use our painter rather than the system overlay layer.
final class MacDockScrollThumb: MacSlimScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { false }
    override var wantsUpdateLayer: Bool { false }
    weak var owner: MacDockScrollModel?
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0.01 ? super.hitTest(point) : nil
    }
    override func mouseDown(with event: NSEvent) {
        owner?.setTracking(true)
        defer { owner?.setTracking(false) }
        super.mouseDown(with: event)
    }
}

/// Geometry comes from SwiftUI's public ScrollGeometry, not its virtualized AppKit
/// document view. Updating the thumb does not write SwiftUI view state on every wheel event.
@MainActor
final class MacDockScrollModel {
    struct Metrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var viewport: CGFloat = 0
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        var extent: CGFloat { max(0, content + top + bottom) }
        var travel: CGFloat { max(0, extent - viewport) }
        var fraction: Double { travel > 0 ? Double(min(1, max(0, (offset + top) / travel))) : 0 }
    }
    private(set) var metrics = Metrics()
    private weak var thumb: MacDockScrollThumb?
    private var onScroll: ((CGFloat) -> Void)?
    private var fade: DispatchWorkItem?
    private var tracking = false
    #if DEBUG
    private var probeSamples = 0
    #endif

    func attach(_ thumb: MacDockScrollThumb, onScroll: @escaping (CGFloat) -> Void) {
        let fresh = self.thumb !== thumb
        self.thumb = thumb
        self.onScroll = onScroll
        thumb.owner = self
        thumb.target = self
        thumb.action = #selector(scrollFromThumb)
        thumb.scrollerStyle = .legacy
        if fresh {
            thumb.alphaValue = 0; thumb.wantsLayer = true
            #if DEBUG
            ShellProbe.keep("[PROBE dock.geometry.attach] model=\(ObjectIdentifier(self)) thumb=\(ObjectIdentifier(thumb))")
            #endif
        }
        refresh()
    }

    func update(_ next: Metrics) {
        let moved = abs(next.offset - metrics.offset) > 0.01
        #if DEBUG
        if (moved || probeSamples == 0), probeSamples < 12 {
            probeSamples += 1
            ShellProbe.keep("[PROBE dock.geometry.update] model=\(ObjectIdentifier(self)) offset=\(next.offset) content=\(next.content) viewport=\(next.viewport) top=\(next.top) bottom=\(next.bottom) fraction=\(next.fraction)")
        }
        #endif
        metrics = next
        refresh()
        if moved { reveal() }
    }

    private func refresh() {
        guard let thumb else { return }
        thumb.isEnabled = metrics.travel > 0
        thumb.knobProportion = min(1, metrics.viewport / max(1, metrics.extent))
        let changed = thumb.doubleValue != metrics.fraction
        thumb.doubleValue = metrics.fraction
        thumb.needsDisplay = true
        if changed { NSAccessibility.post(element: thumb, notification: .valueChanged) }
        if !thumb.isEnabled { fade?.cancel(); thumb.alphaValue = 0 }
    }

    func setTracking(_ active: Bool) { tracking = active; reveal() }

    private func reveal() {
        guard let thumb, thumb.isEnabled else { return }
        fade?.cancel()
        thumb.layer?.removeAllAnimations()
        thumb.alphaValue = 1
        guard !tracking else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.tracking, let thumb = self.thumb else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                thumb.animator().alphaValue = 0
            }
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    @objc private func scrollFromThumb() {
        guard let thumb else { return }
        var fraction = thumb.doubleValue
        switch thumb.hitPart {
        case .incrementPage: fraction += Double(metrics.viewport * 0.9 / max(1, metrics.travel))
        case .decrementPage: fraction -= Double(metrics.viewport * 0.9 / max(1, metrics.travel))
        case .incrementLine: fraction += Double(20 / max(1, metrics.travel))
        case .decrementLine: fraction -= Double(20 / max(1, metrics.travel))
        default: break
        }
        onScroll?(-metrics.top + CGFloat(min(1, max(0, fraction))) * metrics.travel)
    }

    func detach() {
        fade?.cancel()
        thumb?.target = nil
        thumb?.action = nil
        thumb?.owner = nil
        thumb = nil
        onScroll = nil
    }
    deinit { fade?.cancel() }
}

struct MacDockScrollIndicator: NSViewRepresentable {
    let model: MacDockScrollModel
    let onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> MacDockScrollThumb {
        let view = MacDockScrollThumb()
        model.attach(view, onScroll: onScroll)
        return view
    }
    func updateNSView(_ nsView: MacDockScrollThumb, context: Context) {
        model.attach(nsView, onScroll: onScroll)
    }
    static func dismantleNSView(_ nsView: MacDockScrollThumb, coordinator: ()) {
        nsView.owner?.detach()
    }
}

struct MacDockScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var position = ScrollPosition()
    @State private var scrollbar = MacDockScrollModel()

    var body: some View {
        ScrollView(.vertical) {
            content.frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .onScrollGeometryChange(for: MacDockScrollModel.Metrics.self) { geometry in
            .init(offset: geometry.contentOffset.y, content: geometry.contentSize.height,
                  viewport: geometry.containerSize.height,
                  top: geometry.contentInsets.top, bottom: geometry.contentInsets.bottom)
        } action: { _, metrics in
            scrollbar.update(metrics)
        }
        .overlay(alignment: .trailing) {
            MacDockScrollIndicator(model: scrollbar, onScroll: { position.scrollTo(y: $0) })
                .frame(width: 12)
        }
    }
}

/// Mounted at the workspace/settings boundaries. Coalesces layout/SwiftUI updates into
/// one next-run-loop discovery; no scroll observers, event monitors or polling timers.
/// Web content owns its own scrolling and is deliberately excluded.
struct MacScrollbars: NSViewRepresentable {
    final class Installer: NSView {
        private var scheduled = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
        }
        override func layout() {
            super.layout()
            schedule()
        }
        func schedule() {
            guard !scheduled, window != nil else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard let root = self.window?.contentView else { return }
                Self.install(below: root)
            }
        }
        private static func install(below view: NSView) {
            guard !(view is WKWebView) else { return }
            if let scroll = view as? NSScrollView { MacSlimScroller.install(in: scroll) }
            for child in view.subviews { install(below: child) }
        }
    }
    func makeNSView(context: Context) -> Installer { Installer() }
    func updateNSView(_ nsView: Installer, context: Context) { nsView.schedule() }
}
#endif
