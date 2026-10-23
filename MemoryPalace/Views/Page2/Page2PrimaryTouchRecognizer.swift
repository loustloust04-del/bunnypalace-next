#if os(iOS)
import UIKit

final class Page2PrimaryTouchRecognizer: UIGestureRecognizer {
    weak var coordinateView: UIView?
    var onSecondaryEnd: ((UITouch) -> Void)?
    var editing = false
    var hasItem = false
    var hasMenu = false
    var onSecondaryTap: ((CGPoint) -> Void)?
    private var secondary: [ObjectIdentifier: CGPoint] = [:]
    var onMenu: (() -> Void)?
    var onTouchDown: ((CGPoint) -> Void)?
    var trace: ((String) -> Void)?
    private(set) var startPoint: CGPoint = .zero
    private(set) var point: CGPoint = .zero
    private(set) var windowPoint: CGPoint = .zero
    private(set) var touch: UITouch?
    private(set) var dragging = false
    private var started: TimeInterval = 0
    private var hold: DispatchWorkItem?
    private var arm: DispatchWorkItem?
    var active: Bool { state == .began || state == .changed }
    var elapsed: TimeInterval { (touch?.timestamp ?? started) - started }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil else {
            for extra in touches { secondary[ObjectIdentifier(extra)] = extra.location(in: coordinateView) }
            return
        }
        guard let first = touches.min(by: { $0.timestamp < $1.timestamp }), let view = coordinateView else { state = .failed; return }
        touch = first
        started = first.timestamp
        startPoint = first.location(in: view)
        update(first)
        onTouchDown?(startPoint)
        cancelsTouchesInView = true
        trace?("down item=\(hasItem) menu=\(hasMenu) editing=\(editing) point=\(point)")
        for extra in touches where extra !== first { ignore(extra, for: event) }
        if hasMenu {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .possible, self.touch != nil else { return }
                self.trace?("arm")
                self.state = .began
                self.onMenu?()
            }
            arm = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trace?("hold fired state=\(self.state.rawValue) enabled=\(self.isEnabled) touch=\(self.touch != nil)")
            guard (self.state == .possible || self.active), !self.dragging, let touch = self.touch else { return }
            self.update(touch)
            self.activate()
        }
        hold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (editing && hasItem ? 0.28 : (hasMenu ? 2.45 : 0.45)), execute: work)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for extra in touches where extra !== touch {
            trace?("SECOND move id=\(ObjectIdentifier(extra)) window=\(extra.location(in: coordinateView?.window))")
            if let start = secondary[ObjectIdentifier(extra)] {
                let point = extra.location(in: coordinateView)
                if hypot(point.x - start.x, point.y - start.y) >= 10 { secondary.removeValue(forKey: ObjectIdentifier(extra)) }
            }
        }
        guard let touch, touches.contains(touch) else { return }
        update(touch)
        if dragging { state = .changed; return }
        guard state == .possible || active,
              hypot(point.x - startPoint.x, point.y - startPoint.y) > 8 else { return }
        hold?.cancel(); arm?.cancel()
        if hasItem && (editing || (hasMenu && elapsed >= 0.32)) { activate() }
        else { state = active ? .cancelled : .failed }
    }
    private func activate() {
        hold?.cancel(); arm?.cancel()
        dragging = true
        cancelsTouchesInView = true
        state = state == .possible ? .began : .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for extra in touches where extra !== touch {
            onSecondaryEnd?(extra)
            if let start = secondary.removeValue(forKey: ObjectIdentifier(extra)) {
                let end = extra.location(in: coordinateView)
                if hypot(end.x - start.x, end.y - start.y) < 10 { onSecondaryTap?(end) }
            }
        }
        guard let touch, touches.contains(touch) else { return }
        update(touch)
        trace?("end state=\(state.rawValue) point=\(point)")
        hold?.cancel(); arm?.cancel()
        state = active ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for extra in touches {
            secondary.removeValue(forKey: ObjectIdentifier(extra))
            if extra !== touch { onSecondaryEnd?(extra) }
        }
        guard let touch, touches.contains(touch) else { return }
        trace?("cancel state=\(state.rawValue) menu=\(hasMenu)")
        hold?.cancel(); arm?.cancel()
        state = active ? .cancelled : .failed
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        hasMenu || (editing && hasItem) ? false : super.canBePrevented(by: preventingGestureRecognizer)
    }
    override func reset() {
        trace?("reset state=\(state.rawValue) menu=\(hasMenu)")
        hold?.cancel(); arm?.cancel()
        hold = nil; arm = nil
        touch = nil
        secondary.removeAll()
        hasItem = false
        hasMenu = false
        dragging = false
        super.reset()
    }
    private func update(_ touch: UITouch) {
        point = touch.location(in: coordinateView)
        windowPoint = touch.location(in: coordinateView?.window)
    }
}

#endif
