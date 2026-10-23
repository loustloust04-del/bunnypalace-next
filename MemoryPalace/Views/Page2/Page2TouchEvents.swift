#if os(iOS)
import UIKit
import ObjectiveC.runtime

struct Page2TouchSample {
    let id: ObjectIdentifier
    let phase: UITouch.Phase
    let windowPoint: CGPoint
    let timestamp: TimeInterval
    let beganInside: Bool
}

@MainActor
protocol Page2TouchEventConsumer: AnyObject {
    var touchView: UIView? { get }
    var touchSourceID: ObjectIdentifier? { get }
    var acceptsTouchEvents: Bool { get }
    func receiveTouchSamples(_ samples: [Page2TouchSample])
    func cancelTouchInput()
}

@MainActor
final class Page2TouchEvents {
    static let shared = Page2TouchEvents()
    private final class Subscription {
        weak var consumer: Page2TouchEventConsumer?
        init(_ consumer: Page2TouchEventConsumer) { self.consumer = consumer }
    }
    struct Delivery {
        let token: UUID
        let window: ObjectIdentifier
        let samples: [Page2TouchSample]
    }
    private var subscriptions: [UUID: Subscription] = [:]
    private var sources: [ObjectIdentifier: (owner: UUID, touch: ObjectIdentifier)] = [:]
    private var installed = false

    func subscribe(_ consumer: Page2TouchEventConsumer) -> UUID {
        if !installed,
           let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
           let observer = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.page2_sendEvent(_:))) {
            method_exchangeImplementations(original, observer)
            installed = true
        }
        let token = UUID()
        subscriptions[token] = Subscription(consumer)
        return token
    }
    func unsubscribe(_ token: UUID) {
        subscriptions.removeValue(forKey: token)
        sources = sources.filter { $0.value.owner != token }
    }
    func claim(_ source: ObjectIdentifier, window: UIWindow, token: UUID) -> Bool {
        let key = ObjectIdentifier(window)
        guard sources[key] == nil || sources[key]?.owner == token else { return false }
        sources[key] = (token, source)
        return true
    }
    func release(_ token: UUID) { sources = sources.filter { $0.value.owner != token } }
    func activeSource(in window: UIWindow?) -> ObjectIdentifier? {
        window.flatMap { sources[ObjectIdentifier($0)]?.touch }
    }

    func capture(_ event: UIEvent) -> [Delivery] {
        guard !subscriptions.isEmpty, event.type == .touches else { return [] }
        var result: [Delivery] = []
        let expired = subscriptions.compactMap { $0.value.consumer == nil ? $0.key : nil }
        for token in expired { unsubscribe(token) }
        for (token, subscription) in subscriptions {
            guard let consumer = subscription.consumer, consumer.acceptsTouchEvents,
                  let view = consumer.touchView, let window = view.window,
                  window.windowScene?.activationState == .foregroundActive else { continue }
            let source = consumer.touchSourceID
            let samples = (event.allTouches ?? []).compactMap { touch -> Page2TouchSample? in
                let id = ObjectIdentifier(touch)
                if let source {
                    guard id == source, touch.phase != .stationary else { return nil }
                } else {
                    guard touch.phase == .began, touch.window === window,
                          touch.view?.isDescendant(of: view) == true else { return nil }
                }
                let sameScene = touch.window?.windowScene === window.windowScene
                return Page2TouchSample(id: id, phase: sameScene ? touch.phase : .cancelled,
                                        windowPoint: sameScene ? touch.location(in: window) : .zero,
                                        timestamp: touch.timestamp, beganInside: source == nil)
            }
            if !samples.isEmpty { result.append(Delivery(token: token, window: ObjectIdentifier(window), samples: samples)) }
        }
        return result
    }
    func deliver(_ packets: [Delivery]) {
        for packet in packets {
            guard let consumer = subscriptions[packet.token]?.consumer else { continue }
            guard consumer.acceptsTouchEvents else { consumer.cancelTouchInput(); continue }
            guard let window = consumer.touchView?.window, ObjectIdentifier(window) == packet.window,
                  window.windowScene?.activationState == .foregroundActive else { consumer.cancelTouchInput(); continue }
            consumer.receiveTouchSamples(packet.samples)
        }
    }
}

extension UIApplication {
    @objc fileprivate dynamic func page2_sendEvent(_ event: UIEvent) {
        let packets = Page2TouchEvents.shared.capture(event)
        page2_sendEvent(event)
        Page2TouchEvents.shared.deliver(packets)
    }
}
#endif
