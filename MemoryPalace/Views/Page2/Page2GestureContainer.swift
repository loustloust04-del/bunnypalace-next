#if os(iOS)
import SwiftUI
import UIKit

struct Page2HostedContent<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues
    var body: some View { content.environment(\.self, environment) }
}

struct Page2GestureContainer<Content: View>: UIViewControllerRepresentable {
    @Environment(\.self) private var inheritedEnvironment
    var editing: Bool
    var library: Bool
    var isPaging: () -> Bool
    var isDragging: () -> Bool = { false }
    var paging: Page2PagingPresentation? = nil
    var enabled = true
    var available: () -> Bool = { true }
    var excludesTouchAt: (CGPoint) -> Bool = { _ in false }
    var excludesSearchAt: (CGPoint) -> Bool = { _ in false }
    var coordinateInset: CGFloat = 0
    var dockHeight: CGFloat = 0
    let location: Page2DragLocation
    var onTap: (CGPoint) -> Void
    var onSnapshot: (UIImage?) -> Void
    var menuAt: (CGPoint) -> Page2DragTarget?
    var menuFor: ((UUID) -> UIMenu?)? = nil
    var onSecondaryTap: ((CGPoint) -> Void)? = nil
    var onPress: (UIGestureRecognizer.State, CGPoint) -> Void
    var onPan: (UIGestureRecognizer.State, CGPoint, CGSize, CGSize) -> Void
    var probeState: (() -> String)? = nil
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> UIHostingController<Page2HostedContent<Content>> {
        let host = UIHostingController(rootView: Page2HostedContent(content: content(), environment: inheritedEnvironment))
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.clipsToBounds = true
        configure(context.coordinator, view: host.view)
        context.coordinator.attach(to: host.view, outerScroll: PagingViewController.sharedScrollView)
        if inheritedEnvironment.launchPage2Target == "home" {
            inheritedEnvironment.launchPageSignal?.note("gestureReady")
        }
        return host
    }
    func updateUIViewController(_ host: UIHostingController<Page2HostedContent<Content>>, context: Context) {
        withTransaction(context.transaction) {
            host.rootView = Page2HostedContent(content: content(), environment: inheritedEnvironment)
        }
        configure(context.coordinator, view: host.view)
        context.coordinator.attach(to: host.view, outerScroll: PagingViewController.sharedScrollView)
        if inheritedEnvironment.launchPage2Target == "home" {
            inheritedEnvironment.launchPageSignal?.note("gestureReady")
        }
    }
    private func configure(_ driver: Page2GestureDriver, view: UIView) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PAGE2_UI_TOUCH_TRACE"] == "1", driver.trace == nil {
            let inset = coordinateInset
            driver.trace = { message in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("gesture.trace")
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                if let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.seekToEnd(); try? handle.write(contentsOf: Data("\(Date().timeIntervalSince1970) inset=\(inset) \(message)\n".utf8)); try? handle.close()
                }
            }
        }
        #endif
        location.coordinateView = view
        location.coordinateInset = coordinateInset
        driver.setOuterDragLock = PagingViewController.setPage2DragLocked
        driver.location = location
        driver.coordinateInset = coordinateInset
        driver.dockHeight = dockHeight
        driver.editing = editing
        driver.library = library
        driver.enabled = enabled
        driver.available = available
        driver.excludesTouchAt = excludesTouchAt
        driver.excludesSearchAt = excludesSearchAt
        driver.isPaging = isPaging
        driver.isDragging = isDragging
        paging?.trace = driver.trace
        driver.pager = { [weak paging] in paging?.scrollView }
        paging?.mayReceive = { [weak driver] in driver?.mayReceivePaging($0) ?? true }
        paging?.mayBegin = { [weak driver] in driver?.mayBeginPaging ?? true }
        driver.onTap = onTap
        driver.onSnapshot = onSnapshot
        driver.menuAt = menuAt
        driver.menuFor = menuFor
        driver.onSecondaryTap = onSecondaryTap
        driver.onPress = onPress
        driver.onPan = onPan
        driver.probeState = probeState
        driver.synchronize()
    }
    static func dismantleUIViewController(_ host: UIHostingController<Page2HostedContent<Content>>, coordinator: Page2GestureDriver) {
        let cancel = coordinator.onPress
        coordinator.detach()
        DispatchQueue.main.async { cancel?(.cancelled, .zero) }
    }
    func makeCoordinator() -> Page2GestureDriver { Page2GestureDriver() }
}
#endif
