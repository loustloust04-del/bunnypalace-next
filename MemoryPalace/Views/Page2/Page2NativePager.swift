#if os(iOS)
import SwiftUI
import UIKit

struct Page2NativePager<Content: View>: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    let selection: Binding<Int>
    let pageCount: Int
    let editing: Bool
    let presentation: Page2PagingPresentation
    /// 末页往左交给右边竖条（#085，只有桌面主页面用；文件夹里不交）
    var trailingHandoff = false
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(content: Page2HostedContent(content: content(), environment: environment),
                                    selection: selection, pageCount: pageCount, editing: editing,
                                    presentation: presentation)
        controller.trailingHandoff = trailingHandoff
        return controller
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        withTransaction(context.transaction) {
            controller.configure(content: Page2HostedContent(content: content(), environment: environment),
                                 selection: selection, pageCount: pageCount, editing: editing)
        }
    }

    final class Controller: UIViewController, UIScrollViewDelegate {
        private let scroll = HomeScrollView()
        private let host: UIHostingController<Page2HostedContent<Content>>
        private let presentation: Page2PagingPresentation
        private var selection: Int
        private var pageCount: Int
        private var selectionBinding: Binding<Int>
        private var laidOutSize: CGSize = .zero
        var trailingHandoff: Bool {
            get { scroll.allowsTrailingHandoff }
            set { scroll.allowsTrailingHandoff = newValue }
        }

        init(content: Page2HostedContent<Content>, selection: Binding<Int>, pageCount: Int, editing: Bool,
             presentation: Page2PagingPresentation) {
            host = UIHostingController(rootView: content)
            self.selection = selection.wrappedValue; self.selectionBinding = selection; self.pageCount = pageCount
            self.presentation = presentation
            scroll.allowsLeadingHandoff = !editing
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            scroll.backgroundColor = .clear
            scroll.isPagingEnabled = true
            scroll.panGestureRecognizer.name = "page2.paging"
            scroll.decelerationRate = .fast
            scroll.alwaysBounceHorizontal = true
            scroll.alwaysBounceVertical = false
            scroll.showsHorizontalScrollIndicator = false
            scroll.showsVerticalScrollIndicator = false
            scroll.delaysContentTouches = false
            scroll.keyboardDismissMode = .onDrag
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.delegate = self
            presentation.scrollView = scroll
            scroll.mayReceive = { [weak presentation] in presentation?.mayReceive($0) ?? true }
            scroll.mayBegin = { [weak presentation] in presentation?.mayBegin() ?? true }
            scroll.accessibilityIdentifier = "page2.native-pager"
            view.addSubview(scroll)
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            addChild(host)
            scroll.addSubview(host.view)
            host.didMove(toParent: self)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            layoutPages()
        }
        func configure(content: Page2HostedContent<Content>, selection: Binding<Int>, pageCount: Int,
                       editing: Bool) {
            #if DEBUG || PERF_BENCH
            Page2StripProbe.hit("nativePagerRootAssign")
            #endif
            host.rootView = content
            selectionBinding = selection
            let requestedPage = selection.wrappedValue
            let changedPage = self.selection != requestedPage
            self.selection = requestedPage; self.pageCount = pageCount
            scroll.allowsLeadingHandoff = !editing
            guard isViewLoaded else { return }
            layoutPages()
            let target = CGPoint(x: CGFloat(selectionBinding.wrappedValue) * laidOutSize.width, y: 0)
            if changedPage, !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating, laidOutSize.width > 0,
               abs(scroll.contentOffset.x - target.x) > 0.5 {
                presentation.trace?("PAGE command from=\(scroll.contentOffset.x) requested=\(selectionBinding.wrappedValue)")
                presentation.isScrolling = true
                scroll.setContentOffset(target,
                                        animated: !UIAccessibility.isReduceMotionEnabled)
                if UIAccessibility.isReduceMotionEnabled { settle("reduced-motion") }
            }
        }
        private func layoutPages() {
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let widthChanged = size.width != laidOutSize.width
            scroll.frame = view.bounds
            let canvas = CGSize(width: CGFloat(pageCount) * size.width, height: size.height)
            if scroll.contentSize != canvas { scroll.contentSize = canvas }
            if host.view.frame.size != canvas { host.view.frame = CGRect(origin: .zero, size: canvas) }
            laidOutSize = size
            if widthChanged {
                scroll.setContentOffset(CGPoint(x: CGFloat(selection) * size.width, y: 0), animated: false)
                presentation.isScrolling = false
            }
            updatePresentation()
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            presentation.trace?("PAGE begin offset=\(scrollView.contentOffset) width=\(scrollView.bounds.width) canvas=\(scrollView.contentSize)")
            presentation.isScrolling = true
        }
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            presentation.trace?("PAGE release offset=\(scrollView.contentOffset) target=\(targetContentOffset.pointee) velocity=\(velocity) touches=\(scrollView.panGestureRecognizer.numberOfTouches)")
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { updatePresentation() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { settle("drag") }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle("deceleration") }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle("animation") }
        private func updatePresentation() {
            guard scroll.bounds.width > 0 else { return }
            let description = "第\(selection + 1)页，共\(pageCount)页"
            if scroll.accessibilityValue != description { scroll.accessibilityValue = description }
            let progress = presentation.libraryEnabled ? min(1, max(0, scroll.contentOffset.x / scroll.bounds.width - CGFloat(pageCount - 2))) : 0
            if presentation.libraryProgress != progress { presentation.libraryProgress = progress }
            presentation.chromeMotion.update(progress: progress, width: scroll.bounds.width)
        }
        private func settle(_ reason: String) {
            guard scroll.bounds.width > 0 else { return }
            presentation.trace?("PAGE settle reason=\(reason) offset=\(scroll.contentOffset.x) width=\(scroll.bounds.width) tracking=\(scroll.isTracking) dragging=\(scroll.isDragging) decelerating=\(scroll.isDecelerating)")
            guard !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else { return }
            let index = max(0, min(pageCount - 1, Int((scroll.contentOffset.x / scroll.bounds.width).rounded())))
            let target = CGPoint(x: CGFloat(index) * scroll.bounds.width, y: 0)
            if abs(scroll.contentOffset.x - target.x) > 0.5 {
                presentation.isScrolling = true
                scroll.setContentOffset(target, animated: !UIAccessibility.isReduceMotionEnabled)
                if !UIAccessibility.isReduceMotionEnabled { return }
            }
            presentation.trace?("PAGE settled index=\(index)")
            selection = index
            selectionBinding.wrappedValue = index
            presentation.isScrolling = false
            scroll.accessibilityValue = "第\(index + 1)页，共\(pageCount)页"
            if Page2TouchEvents.shared.activeSource(in: scroll.window) != nil || scroll.window?.gestureRecognizers?.contains(where: { ($0 as? Page2PrimaryTouchRecognizer)?.dragging == true }) == true {
                scroll.panGestureRecognizer.isEnabled = false
                scroll.panGestureRecognizer.isEnabled = true
            }
        }
    }

    final class HomeScrollView: UIScrollView, UIGestureRecognizerDelegate {
        var mayReceive: (UITouch) -> Bool = { _ in true }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            mayReceive(touch)
        }
        var allowsLeadingHandoff = true
        var allowsTrailingHandoff = false
        var mayBegin: () -> Bool = { true }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === panGestureRecognizer {
                guard mayBegin() else { return false }
                let velocity = panGestureRecognizer.velocity(in: self)
                guard abs(velocity.x) > abs(velocity.y) else { return false }
                if allowsLeadingHandoff && contentOffset.x <= 0.5 && velocity.x > 0 { return false }
                // 末页（资源库）再往左：让给右边竖条，和首页往右让给外层翻页对称（编辑态不让）
                if allowsTrailingHandoff, allowsLeadingHandoff, Page2StripPan.shared.isEnabled, velocity.x < 0,
                   contentOffset.x >= contentSize.width - bounds.width - 0.5 { return false }
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
    }
}
#endif
