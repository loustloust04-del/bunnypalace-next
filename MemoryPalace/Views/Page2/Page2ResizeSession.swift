#if os(iOS)
import SwiftUI

@MainActor @Observable
final class Page2ResizeSession {
    private(set) var sourceID: UUID?
    private(set) var preview: Page2Layout?
    private(set) var visualFrame: CGRect?
    @ObservationIgnored private var baseline: Page2Layout?
    @ObservationIgnored private var initialFrame = CGRect.zero
    @ObservationIgnored private var initialSize = CGSize.zero
    @ObservationIgnored private var sizes: [(Page2Span, CGSize)] = []
    @ObservationIgnored private var capacity = ""
    @ObservationIgnored private var labelHeight: CGFloat = 0
    @ObservationIgnored private var contentBounds = CGRect.zero
    @ObservationIgnored private var requestedSpan = Page2Span.small
    @ObservationIgnored private var valid = true
    @ObservationIgnored private var failure: String?

    var board: Page2Board? { preview?.boards.first { $0.capacityKey == capacity } }

    func begin(_ id: UUID, layout: Page2Layout, board: Page2Board, frame: CGRect,
               metrics: Page2SystemMetrics, labelHeight: CGFloat, bounds: CGRect) -> Bool {
        guard sourceID == nil, let item = layout.item(id), ["widget", "stack"].contains(item.kind) else { return false }
        self.baseline = layout; self.preview = layout; self.capacity = board.capacityKey
        self.initialFrame = frame; self.labelHeight = labelHeight; self.contentBounds = bounds
        initialSize = CGSize(width: metrics.width(item.span), height: metrics.height(item.span))
        sizes = Page2Span.widgetSizes.map { ($0, CGSize(width: metrics.width($0), height: metrics.height($0))) }
        requestedSpan = item.span; valid = true; failure = nil
        visualFrame = frame; sourceID = id
        return true
    }

    func update(_ translation: CGSize) {
        guard let sourceID, let baseline, let small = sizes.first?.1, let large = sizes.last?.1 else { return }
        guard translation.width.isFinite, translation.height.isFinite else { return }
        let proposed = CGSize(width: min(large.width, max(small.width, initialSize.width + translation.width)),
                              height: min(large.height, max(small.height, initialSize.height + translation.height)))
        let pressedInset: CGFloat = abs(translation.width) + abs(translation.height) > 3 ? 6 : 0
        let shown = CGSize(width: proposed.width - pressedInset, height: proposed.height - pressedInset + labelHeight)
        visualFrame = CGRect(x: max(contentBounds.minX, min(initialFrame.minX, contentBounds.maxX - shown.width)),
                             y: max(contentBounds.minY, min(initialFrame.minY, contentBounds.maxY - shown.height)),
                             width: shown.width, height: shown.height)
        func distance(_ size: CGSize) -> CGFloat {
            let x = (proposed.width - size.width) / max(1, large.width - small.width)
            let y = (proposed.height - size.height) / max(1, large.height - small.height)
            return x * x + y * y
        }
        guard let nearest = sizes.min(by: { distance($0.1) < distance($1.1) }), nearest.0 != requestedSpan else { return }
        if let current = sizes.first(where: { $0.0 == requestedSpan }), distance(current.1) - distance(nearest.1) < 0.06 { return }
        requestedSpan = nearest.0
        do {
            preview = try Page2GridEngine.resizing(sourceID, to: requestedSpan, in: baseline)
            valid = true; failure = nil
        } catch { valid = false; failure = error.localizedDescription }
    }

    func finish(in home: Page2HomeStore) {
        guard let sourceID, let baseline else { return }
        defer { cancel() }
        guard home.layout == baseline else { home.errorMessage = "主屏已更新，这次尺寸调整已取消。"; return }
        guard valid else { home.errorMessage = failure; return }
        if baseline.item(sourceID)?.span != requestedSpan { _ = home.change(sourceID, span: requestedSpan) }
    }

    func cancelIfChanged(_ layout: Page2Layout) {
        if sourceID != nil, let baseline, baseline != layout { cancel() }
    }

    func cancel() {
        sourceID = nil; preview = nil; visualFrame = nil; baseline = nil
        sizes.removeAll(); failure = nil; valid = true
    }
}
#endif
