#if os(macOS)
import XCTest
import AppKit
@testable import 记忆花园

@MainActor
final class MacSlimScrollerTests: XCTestCase {
    func testInstallationPreservesDocumentAndScrollPositionAndIsIdempotent() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 2000))
        scroll.documentView = document
        scroll.contentView.scroll(to: NSPoint(x: 80, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin
        MacSlimScroller.install(in: scroll)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.verticalScroller is MacSlimScroller)
        XCTAssertTrue(scroll.horizontalScroller is MacSlimScroller)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertEqual(scroll.contentSize.width, scroll.bounds.width, accuracy: 0.5,
                       "Overlay scrollers must not steal Dock width")
        XCTAssertEqual(scroll.contentSize.height, scroll.bounds.height, accuracy: 0.5)
        XCTAssertTrue(scroll.documentView === document)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        let vertical = scroll.verticalScroller
        let horizontal = scroll.horizontalScroller
        MacSlimScroller.install(in: scroll)
        XCTAssertTrue(scroll.verticalScroller === vertical)
        XCTAssertTrue(scroll.horizontalScroller === horizontal)
        XCTAssertNotNil(vertical?.target)
        XCTAssertNotNil(vertical?.action)
    }

    func testThumbPaintIsThinAndTrackIsTransparent() {
        let scroller = MacDockScrollThumb(frame: NSRect(x: 0, y: 0, width: 10, height: 200))
        scroller.scrollerStyle = .legacy
        scroller.isEnabled = true
        scroller.knobProportion = 0.25
        scroller.doubleValue = 0.5
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: scroller.bounds.size).fill(using: .copy)
        scroller.draw(scroller.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let painted = (0..<200).map { y in
            (0..<10).filter { bitmap.colorAt(x: $0, y: y)!.alphaComponent > 0.01 }.count
        }
        XCTAssertEqual(painted.max(), 4, "Only the four-point thumb should paint, not a native track")
        XCTAssertTrue(painted.contains(0), "The rest of the track stays transparent")
    }

    func testDockThumbFollowsPublicGeometryAndDrivesScrollingThenFades() async {
        let model = MacDockScrollModel()
        model.update(.init(offset: 0, content: 600, viewport: 200))
        let thumb = MacDockScrollThumb(frame: NSRect(x: 0, y: 0, width: 12, height: 200))
        var requested: CGFloat?
        model.attach(thumb) { requested = $0 }
        XCTAssertEqual(thumb.alphaValue, 0)
        model.update(.init(offset: 200, content: 600, viewport: 200))
        XCTAssertEqual(thumb.alphaValue, 1)
        XCTAssertEqual(thumb.doubleValue, 0.5, accuracy: 0.001)
        thumb.doubleValue = 0.25
        XCTAssertTrue(thumb.sendAction(thumb.action, to: thumb.target))
        XCTAssertEqual(requested, 100)
        XCTAssertEqual((thumb.accessibilityValue() as? NSNumber)?.doubleValue, 0.25)
        model.setTracking(true)
        try? await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(thumb.alphaValue, 1, "Dragging must keep the thumb visible")
        model.setTracking(false)
        try? await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(thumb.alphaValue, 0)
        model.detach()
        XCTAssertNil(thumb.target)
        XCTAssertNil(thumb.owner)
    }

    func testDockContentInsetsAndRubberBandingUseTheScrollGeometryRange() {
        let model = MacDockScrollModel()
        let thumb = MacDockScrollThumb(frame: NSRect(x: 0, y: 0, width: 12, height: 200))
        var requested: CGFloat?
        model.attach(thumb) { requested = $0 }
        defer { model.detach() }
        model.update(.init(offset: -40, content: 600, viewport: 200, top: 20, bottom: 30))
        XCTAssertEqual(thumb.doubleValue, 0)
        model.update(.init(offset: 500, content: 600, viewport: 200, top: 20, bottom: 30))
        XCTAssertEqual(thumb.doubleValue, 1)
        thumb.doubleValue = 0.5
        XCTAssertTrue(thumb.sendAction(thumb.action, to: thumb.target))
        XCTAssertEqual(requested, 205)
        model.update(.init(offset: 0, content: 100, viewport: 200))
        XCTAssertFalse(thumb.isEnabled)
        XCTAssertEqual(thumb.alphaValue, 0)
    }

    func testRetainedButDisabledSystemScrollersAreNotReplaced() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let vertical = scroll.verticalScroller
        let horizontal = scroll.horizontalScroller
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        MacSlimScroller.install(in: scroll)
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertTrue(scroll.verticalScroller === vertical)
        XCTAssertTrue(scroll.horizontalScroller === horizontal)
    }

    func testHiddenIndicatorsAreNotIntroduced() {
        let scroll = NSScrollView()
        MacSlimScroller.install(in: scroll)
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertFalse(scroll.hasHorizontalScroller)
    }
}
#endif
