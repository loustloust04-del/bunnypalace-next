#if os(iOS)
import SwiftUI
import UIKit

struct Page2StackPager: UIViewControllerRepresentable {
    let items: [Page2Item]
    let selectedID: UUID
    let onSelect: (UUID) -> Void
    let onScrolling: (Bool) -> Void
    let onOpen: (String) -> Void
    @Environment(\.self) private var environment

    func makeUIViewController(context: Context) -> Controller {
        Controller(items: items, selectedID: selectedID, environment: environment,
                   onSelect: onSelect, onScrolling: onScrolling, onOpen: onOpen)
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configure(items: items, selectedID: selectedID, environment: environment)
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.stop() }

    final class Controller: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        private var items: [Page2Item]
        private var selectedID: UUID
        private var inherited: EnvironmentValues
        private let onSelect: (UUID) -> Void
        private let onScrolling: (Bool) -> Void
        private let onOpen: (String) -> Void
        private var transitioning = false

        init(items: [Page2Item], selectedID: UUID, environment: EnvironmentValues,
             onSelect: @escaping (UUID) -> Void, onScrolling: @escaping (Bool) -> Void, onOpen: @escaping (String) -> Void) {
            self.items = items; self.selectedID = selectedID; self.inherited = environment
            self.onSelect = onSelect; self.onScrolling = onScrolling; self.onOpen = onOpen
            super.init(transitionStyle: .scroll, navigationOrientation: .vertical, options: [.interPageSpacing: 8])
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.clipsToBounds = true
            view.layer.cornerRadius = 24
            dataSource = self; delegate = self
            applySelection()
        }
        func configure(items: [Page2Item], selectedID: UUID, environment: EnvironmentValues) {
            self.items = items; self.selectedID = selectedID; inherited = environment
            if isViewLoaded && !transitioning { applySelection() }
        }
        private func page(_ item: Page2Item) -> Page {
            Page(item: item, environment: inherited, onOpen: onOpen)
        }
        private func applySelection() {
            guard let item = items.first(where: { $0.id == selectedID }) ?? items.first else { return }
            if let visible = viewControllers?.first as? Page, visible.itemID == item.id {
                visible.configure(item: item, environment: inherited, onOpen: onOpen)
            } else { setViewControllers([page(item)], direction: .forward, animated: false) }
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            adjacent(to: viewController, delta: -1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            adjacent(to: viewController, delta: 1)
        }
        private func adjacent(to controller: UIViewController, delta: Int) -> UIViewController? {
            guard items.count > 1, let id = (controller as? Page)?.itemID, let index = items.firstIndex(where: { $0.id == id }) else { return nil }
            return page(items[(index + delta + items.count) % items.count])
        }
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            transitioning = true; onScrolling(true)
        }
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            if completed, let id = (viewControllers?.first as? Page)?.itemID, items.contains(where: { $0.id == id }) {
                selectedID = id; onSelect(id)
            }
            applySelection(); onScrolling(false)
        }
        func stop() { dataSource = nil; delegate = nil; onScrolling(false) }
    }

    final class Page: UIHostingController<Page2HostedContent<Page2WidgetHost>> {
        let itemID: UUID
        init(item: Page2Item, environment: EnvironmentValues, onOpen: @escaping (String) -> Void) {
            itemID = item.id
            super.init(rootView: Page2HostedContent(content: Page2WidgetHost(item: item, onOpen: onOpen), environment: environment))
            safeAreaRegions = []
            view.backgroundColor = .clear
            view.clipsToBounds = true
        }
        required init?(coder: NSCoder) { nil }
        func configure(item: Page2Item, environment: EnvironmentValues, onOpen: @escaping (String) -> Void) {
            rootView = Page2HostedContent(content: Page2WidgetHost(item: item, onOpen: onOpen), environment: environment)
        }
    }
}
#endif
