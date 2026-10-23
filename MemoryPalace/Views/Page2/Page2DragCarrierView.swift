#if os(iOS)
import SwiftUI
import UIKit

struct Page2DragVisual: View {
    let item: Page2Item
    let tool: RightPanelTool?
    let iconSide: CGFloat
    let size: CGSize
    let image: UIImage?
    var overDock: Bool
    var overFolder = false
    var landing = false
    var landingScale: CGFloat = 1
    var absorbing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    private var widget: Page2Item? {
        if item.kind == "widget" { return item }
        guard item.kind == "stack" else { return nil }
        let members = item.children.compactMap { Page2HomeStore.shared.layout.item($0) }.filter { child in
            guard let id = child.toolID else { return true }
            guard let tool = tools?.tool(byId: id) else { return false }
            return tool.isEnabled && tools?.isVisibleInCurrentMode(tool) == true
        }
        let selected = item.configuration["activeChild"].flatMap(UUID.init(uuidString:))
        return members.first { $0.id == selected } ?? members.first
    }


    var body: some View {
        GlassEffectContainer(spacing: 0) {
            Group {
                if item.kind == "app", let tool {
                    Page2AppIcon(tool: tool, side: size.width, label: false, followsIconSize: false, interactive: false)
                } else if item.kind == "folder" {
                    Page2FolderIcon(pages: [(item.childPages.first ?? []).compactMap { Page2HomeStore.shared.layout.item($0) }], side: size.width)
                } else if let widget {
                    Page2WidgetHost(item: widget, preview: false, onOpen: { _ in })
                        .frame(width: size.width, height: max(0, size.height - (Page2AppearanceStore.shared.displayed.largeIcons ? 0 : 20)))
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Text(item.title.isEmpty ? "小组件" : item.title).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(Page2WidgetSurface())
                }
            }
        }
        .compositingGroup()
        .frame(width: size.width, height: size.height, alignment: .top)
        .overlay(alignment: .top) {
            if item.kind == "app" {
                RoundedRectangle(cornerRadius: size.width * 0.26 + 2.25, style: .continuous)
                    .strokeBorder(.white.opacity(0.94), lineWidth: 2.25)
                    .frame(width: size.width + 4.5, height: size.width + 4.5)
                    .offset(y: -2.25)
                    .opacity(overFolder && !landing ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: overFolder && !landing)
            }
        }
        .modifier(Page2DragScale(scale: reduceMotion ? 1 : (landing ? landingScale : (overDock ? 0.82 : (["app", "folder"].contains(item.kind) ? 1.11 : 1.05))),
                                 iconHeight: ["app", "folder"].contains(item.kind) ? size.width : size.height).ignoredByLayout())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: overDock)
        .shadow(color: .black.opacity(landing && absorbing ? 0 : 0.35), radius: landing && absorbing ? 0 : 8, y: landing && absorbing ? 0 : 4)
        .animation(reduceMotion ? nil : (absorbing ? Page2FolderDropMotion.animation : .easeOut(duration: 0.22)), value: landing)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct Page2DragCarrierView: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    let location: Page2DragLocation
    let item: Page2Item
    let tool: RightPanelTool?
    let iconSide: CGFloat
    let size: CGSize
    let offset: CGSize
    let dockRect: CGRect
    let image: UIImage?
    var overFolder = false

    func makeUIViewController(context: Context) -> Controller {
        Controller(location: location, item: item, tool: tool, iconSide: iconSide, size: size,
                   offset: offset, dockRect: dockRect, image: image, overFolder: overFolder, environment: environment)
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configure(item: item, tool: tool, iconSide: iconSide, size: size, offset: offset,
                             dockRect: dockRect, image: image, overFolder: overFolder, environment: environment)
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.stopRefresh()
        controller.stopLandingAnimation()
        controller.location.removeObserver(owner: controller.observerID)
    }

    final class Controller: UIViewController {
        let observerID = UUID()
        let location: Page2DragLocation
        private var item: Page2Item
        private var tool: RightPanelTool?
        private var iconSide: CGFloat
        private var size: CGSize
        private var offset: CGSize
        private var dockRect: CGRect
        private var image: UIImage?
        private var overFolder: Bool
        private var environment: EnvironmentValues
        private var overDock = false
        private var landingRequest: UUID?
        private var landingAnimator: UIViewPropertyAnimator?
        private var refresh: Page2DragRefresh?
        private let host: UIHostingController<Page2HostedContent<Page2DragVisual>>

        init(location: Page2DragLocation, item: Page2Item, tool: RightPanelTool?, iconSide: CGFloat,
             size: CGSize, offset: CGSize, dockRect: CGRect, image: UIImage?, overFolder: Bool, environment: EnvironmentValues) {
            self.location = location; self.item = item; self.tool = tool; self.iconSide = iconSide
            self.size = size; self.offset = offset; self.dockRect = dockRect; self.image = image; self.overFolder = overFolder
            self.environment = environment
            host = UIHostingController(rootView: Page2HostedContent(content: Page2DragVisual(item: item, tool: tool, iconSide: iconSide, size: size, image: image, overDock: false, overFolder: overFolder), environment: environment))
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isOpaque = false
            view.clipsToBounds = false
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.isOpaque = false
            host.view.clipsToBounds = false
            host.view.isUserInteractionEnabled = false
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)
            refresh = Page2DragRefresh(view: view, layer: host.view.layer, location: location)
            location.observe(owner: observerID) { [weak self] in self?.move() }
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            move()
        }

        func configure(item: Page2Item, tool: RightPanelTool?, iconSide: CGFloat, size: CGSize,
                       offset: CGSize, dockRect: CGRect, image: UIImage?, overFolder: Bool, environment: EnvironmentValues) {
            let changed = self.item != item || self.tool != tool || self.iconSide != iconSide || self.size != size || self.image !== image || self.overFolder != overFolder
            self.item = item; self.tool = tool; self.iconSide = iconSide; self.size = size
            self.offset = offset; self.dockRect = dockRect; self.image = image; self.overFolder = overFolder; self.environment = environment
            if changed { updateContent() }
            if isViewLoaded { move() }
        }
        func stopRefresh() {
            refresh?.stop()
            refresh = nil
        }
        func stopLandingAnimation() {
            if landingAnimator?.state == .active { landingAnimator?.stopAnimation(true) }
            landingAnimator = nil
        }
        private func updateContent() {
            host.rootView = Page2HostedContent(content: Page2DragVisual(item: item, tool: tool, iconSide: iconSide, size: size, image: image, overDock: overDock, overFolder: overFolder, landing: location.isLanding, landingScale: location.landingScale, absorbing: location.absorbing), environment: environment)
        }
        private func move() {
            guard isViewLoaded, let window = view.window else { return }
            let next = item.kind == "app" && dockRect.contains(location.localPoint)
            if next != overDock { overDock = next; updateContent() }
            let point = view.convert(location.windowPoint, from: window)
            let center = CGPoint(x: point.x - offset.width + size.width / 2, y: point.y - offset.height + size.height / 2)
            if location.isLanding, let request = location.landingID {
                guard landingRequest != request else { return }
                landingRequest = request
                updateContent()
                if location.absorbing {
                    let timing = UICubicTimingParameters(controlPoint1: Page2FolderDropMotion.first, controlPoint2: Page2FolderDropMotion.second)
                    let animator = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0 : Page2FolderDropMotion.duration,
                                                          timingParameters: timing)
                    animator.addAnimations {
                        self.host.view.center = center
                        self.refresh?.moved()
                    }
                    animator.addCompletion { [weak self] position in
                        guard let self, position == .end else { return }
                        self.location.completeLanding(owner: self.observerID, request: request)
                    }
                    landingAnimator = animator
                    animator.startAnimation()
                } else {
                    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.24, delay: 0,
                                   usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                                   options: [.beginFromCurrentState, .allowUserInteraction]) {
                        self.host.view.center = center
                        self.refresh?.moved()
                    } completion: { [weak self] _ in
                        guard let self else { return }
                        self.location.completeLanding(owner: self.observerID, request: request)
                    }
                }
            } else {
                if landingRequest != nil { stopLandingAnimation() }
                landingRequest = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if host.view.bounds.size != size { host.view.bounds = CGRect(origin: .zero, size: size) }
                if host.view.center != center { host.view.center = center }
                CATransaction.commit()
                refresh?.moved()
            }
        }
    }
}
#endif
