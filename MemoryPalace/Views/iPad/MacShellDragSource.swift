#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacShellMenuItem {
    let title: String
    let action: () -> Void
    var checked = false
}

/// Only covers the drag surface; close buttons and window-move areas are siblings.
struct MacShellDragSource: NSViewRepresentable {
    let title: String
    var pasteboardType: NSPasteboard.PasteboardType = .init(UTType.toolTab.identifier)
    var payload: String?
    var onBegin: () -> Void = {}
    var onEnd: (Bool) -> Void = { _ in }
    var onClick: (Int) -> Void = { _ in }
    var onPressChanged: (Bool) -> Void = { _ in }
    var onLongPress: (() -> Void)?
    var menuItems: [MacShellMenuItem] = []
    var preview: (() -> NSImage?)? = nil
    var onMenu: ((CGPoint) -> Void)? = nil
    var clickMenuItems: [MacShellMenuItem] = []
    var keyboardActivatable = false

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        if view.source?.title != title { view.setAccessibilityLabel(title) }
        if keyboardActivatable && view.source?.keyboardActivatable != true {
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(clickMenuItems.isEmpty ? .button : .popUpButton)
        } else if !keyboardActivatable && view.source?.keyboardActivatable == true {
            view.setAccessibilityElement(false)
        }
        view.source = self
    }

    static func dismantleNSView(_ view: DragView, coordinator: ()) {
        view.cancelPress()
        // AppKit still owns an active drag after its source leaves the SwiftUI tree.
    }

    final class DragView: NSView, NSDraggingSource {
        var source: MacShellDragSource?
        private var down: NSEvent?
        private var dragging = false
        private var longPressed = false
        private var pressTask: DispatchWorkItem?
        private var endDrag: ((Bool) -> Void)?
        private var dragLifetime: DragView?

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: source?.payload == nil ? .arrow : .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
            down = event
            source?.onPressChanged(true)
            longPressed = false
            if source?.onLongPress != nil {
                let task = DispatchWorkItem { [weak self] in
                    guard let self, self.down != nil, !self.dragging else { return }
                    self.longPressed = true
                    self.source?.onLongPress?()
                }
                pressTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let down, let source else { return }
            let dx = event.locationInWindow.x - down.locationInWindow.x
            let dy = event.locationInWindow.y - down.locationInWindow.y
            guard hypot(dx, dy) >= 4 else { return }
            cancelPress()
            guard let payload = source.payload else { return }
            dragging = true
            // A successful drop may remove this view before AppKit delivers endedAt.
            dragLifetime = self
            endDrag = source.onEnd
            let item = NSPasteboardItem()
            item.setString(payload, forType: source.pasteboardType)
            let drag = NSDraggingItem(pasteboardWriter: item)
            let preview = source.preview?() ?? previewImage(title: source.title)
            let start = convert(down.locationInWindow, from: nil)
            drag.setDraggingFrame(NSRect(x: start.x - preview.size.width / 2,
                                         y: start.y - preview.size.height / 2,
                                         width: preview.size.width, height: preview.size.height), contents: preview)
            source.onBegin()
            let session = beginDraggingSession(with: [drag], event: down, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        override func mouseUp(with event: NSEvent) {
            cancelPress()
            defer { down = nil }
            guard !dragging, !longPressed, down != nil,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            if let items = source?.clickMenuItems, !items.isEmpty {
                popUp(items, event: nil)
            } else {
                source?.onClick(event.clickCount)
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            cancelPress()
            down = nil
            guard let items = source?.menuItems, !items.isEmpty else { super.rightMouseDown(with: event); return }
            source?.onMenu?(event.locationInWindow)
            popUp(items, event: event)
        }

        override var acceptsFirstResponder: Bool { source?.keyboardActivatable == true }

        override func keyDown(with event: NSEvent) {
            if source?.keyboardActivatable == true,
               [36, 49].contains(event.keyCode),
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                _ = accessibilityPerformPress()
            } else { super.keyDown(with: event) }
        }

        override func accessibilityPerformPress() -> Bool {
            guard let source, source.keyboardActivatable else { return false }
            if !source.clickMenuItems.isEmpty { popUp(source.clickMenuItems, event: nil) }
            else { source.onClick(1) }
            return true
        }

        private func popUp(_ items: [MacShellMenuItem], event: NSEvent?) {
            let menu = NSMenu()
            let actions = items.map { item -> MenuAction in
                let target = MenuAction(item.action)
                let row = NSMenuItem(title: item.title, action: #selector(MenuAction.invoke), keyEquivalent: "")
                row.target = target
                row.state = item.checked ? .on : .off
                menu.addItem(row)
                return target
            }
            withExtendedLifetime(actions) {
                if let event { NSMenu.popUpContextMenu(menu, with: event, for: self) }
                else { menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.maxY), in: self) }
            }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            down = nil
            let end = endDrag
            endDrag = nil
            end?(operation != [])
            dragLifetime = nil
        }

        func cancelPress() {
            pressTask?.cancel()
            pressTask = nil
            source?.onPressChanged(false)
        }

        private func previewImage(title: String) -> NSImage {
            let attributes: [NSAttributedString.Key: NSObject] = [
                .font: NSFont.systemFont(ofSize: ShellStyle.bodySize, weight: .medium),
                .foregroundColor: NSColor(Theme.textPrimary)
            ]
            let label = NSAttributedString(string: title, attributes: attributes)
            let size = NSSize(width: min(220, max(84, label.size().width + 32)), height: ShellStyle.tabHeight)
            let image = NSImage(size: size)
            image.lockFocus()
            let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let shape = NSBezierPath(roundedRect: rect, xRadius: ShellStyle.tabRadius, yRadius: ShellStyle.tabRadius)
            NSColor(ShellStyle.background).setFill(); shape.fill()
            NSColor(ShellStyle.selection).setFill(); shape.fill()
            NSColor(ShellStyle.hairline).setStroke(); shape.lineWidth = ShellStyle.hairlineWidth; shape.stroke()
            label.draw(in: NSRect(x: 16, y: 9, width: size.width - 32, height: 18))
            image.unlockFocus()
            return image
        }
    }

    private final class MenuAction: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
}
#endif
