#if PERSONAL_APPS
#if os(iOS)
import SwiftUI
import UIKit

@MainActor final class TutuChatMessageClock: ObservableObject {
    @Published var now = CACurrentMediaTime()
    private let driver = TutuChatAnimationDriver()
    init() { driver.onFrame = { [weak self] in self?.now = $0 } }
    func run(until deadline: Double) {
        now = CACurrentMediaTime()
        if deadline > now { driver.run(until: deadline) } else { driver.stop() }
    }
    func stop() { driver.stop() }
}

struct TutuChatMessagePosition: UIViewRepresentable {
    var changed: (CGFloat) -> Void
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.changed = changed; view.report() }
    final class Probe: UIView {
        var changed: ((CGFloat) -> Void)?
        private var previous: CGFloat?
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        func report() {
            guard let window, let views = PagingViewController.tutuUnlockSnapshotViews() else { return }
            func field(_ root: UIView) -> UITextView? {
                if let field = root as? UITextView { return field }
                for child in root.subviews { if let result = field(child) { return result } }
                return nil
            }
            guard let field = field(views.input) else { return }
            let inputY = field.convert(field.bounds, to: window).midY
            let rowY = convert(bounds, to: window).midY
            let value = inputY - rowY
            guard previous != value else { return }
            previous = value
            DispatchQueue.main.async { [weak self] in self?.changed?(value) }
        }
    }
}

struct TutuChatLaceReveal: ViewModifier {
    let percent: Double?
    func body(content: Content) -> some View {
        if let percent, percent < 100 {
            content.mask {
                let a = max(0, min(1, percent / 100)), b = max(0, min(1, (percent + 15) / 100))
                let top = max(0, min(1, (percent + 15) / 15))
                LinearGradient(stops: [
                    .init(color: .white.opacity(top), location: 0),
                    .init(color: .white.opacity(top), location: a),
                    .init(color: .clear, location: b), .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        } else { content }
    }
}

struct TutuChatRecallEntrance: ViewModifier {
    let nodeID: String
    @StateObject private var clock = TutuChatMessageClock()
    private var entry: TutuChatAnimationTimeline.Entry? {
        let value = TutuChatAnimationTimeline.shared.entries[nodeID]
        return value?.settled == false ? value : nil
    }
    func body(content: Content) -> some View {
        let begin = entry?.intro == true ? entry?.sentAt.map { $0 + 0.65 } : entry?.recallAt
        let duration = entry?.intro == true ? 0.3 : 0.35
        let progress = begin.map { TutuChatAnimation.span(clock.now, $0, $0 + duration) } ?? 1
        content.opacity(TutuChatAnimation.smooth(progress))
            .offset(y: entry?.intro == true ? 0 : 6 * (1 - TutuChatAnimation.outCubic(progress)))
            .onChange(of: begin, initial: true) { _, begin in clock.run(until: begin.map { $0 + duration } ?? 0) }
            .onDisappear { clock.stop() }
    }
}
#endif
#endif
