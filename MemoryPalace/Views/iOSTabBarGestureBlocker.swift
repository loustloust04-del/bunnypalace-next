#if os(iOS)
import SwiftUI
import UIKit

/// 包住 tab 栏 SwiftUI 内容的 UIKit 容器 —— hc.view 就是 tab 栏内容的真实 superview。
/// 在 hc.view 上挂一个 UIPanGestureRecognizer（blockerPan），让水平 paging 容器（路线 C：
/// `PagingViewController.scrollView`）的 panGestureRecognizer 调 `require(toFail: blockerPan)`。
///
/// 历史：原本目标是 TabView(.page) 底层的 UICollectionView 的 pan，路线 C 改造后 paging 容器
/// 是 UIKit UIScrollView，target 换成 `PagingViewController.sharedScrollView`。
///
/// 为什么不用 .background/.overlay：SwiftUI 的 background/overlay 在 UIKit 层是
/// **sibling** 而不是内容的 superview，gesture 不在 touch 的祖先链上 → 收不到 touch。
/// 必须用 UIViewControllerRepresentable + UIHostingController 让 UIView 真正变成
/// 内容的 superview。
///
/// 手指落在 tab 栏：blockerPan begin 并 recognized、永不 fail → 水平翻页 pan 被锁
/// 手指落在别处：blockerPan 不 tracking，依赖对水平翻页 pan 无约束 → 翻页正常
struct TabBarGestureContainer<Content: View>: UIViewControllerRepresentable {
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let hc = UIHostingController(rootView: content())
        hc.view.backgroundColor = .clear
        hc.sizingOptions = .intrinsicContentSize   // 让容器 size fit SwiftUI 内容

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.noop)
        )
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false           // 不拦 Button 点击
        pan.delaysTouchesBegan = false             // Button 立刻收到 touchDown
        pan.delaysTouchesEnded = false             // Button 立刻收到 touchUp → tap 不等 pan 决策，响应灵敏
        hc.view.addGestureRecognizer(pan)
        context.coordinator.blockerPan = pan

        DispatchQueue.main.async {
            context.coordinator.attachDependency(from: hc.view)
        }
        return hc
    }

    func updateUIViewController(_ hc: UIHostingController<Content>, context: Context) {
        hc.rootView = content()
        DispatchQueue.main.async {
            context.coordinator.attachDependency(from: hc.view)
        }
    }

    /// 显式告诉 SwiftUI 布局用 intrinsic 高度（sizingOptions 在某些场景不生效）
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiViewController: UIHostingController<Content>,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let fit = uiViewController.sizeThatFits(in: CGSize(
            width: width,
            height: UIView.layoutFittingCompressedSize.height
        ))
        return CGSize(width: width, height: fit.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var blockerPan: UIPanGestureRecognizer?
        private weak var attachedScrollView: UIScrollView?

        @objc func noop() {}

        /// 拿 PagingViewController.sharedScrollView 的 pan，加 require(toFail: blockerPan)。
        /// 第一次调用时 PagingVC 可能还没 viewDidLoad（sharedScrollView == nil），等
        /// updateUIViewController 再次 trigger 时会成功 attach。
        func attachDependency(from view: UIView) {
            guard let pan = blockerPan,
                  let scrollView = PagingViewController.sharedScrollView else { return }
            if scrollView === attachedScrollView { return }
            scrollView.panGestureRecognizer.require(toFail: pan)
            attachedScrollView = scrollView
        }

        /// 只允许和「blocker view 子孙」上的 gesture 同时识别（即 tab 栏内部
        /// SwiftUI ScrollView 的 pan），不允许和外层水平 paging 的 scrollView pan 同时 ——
        /// 不然 require(toFail:) 被旁路，就会翻页。
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard let blockerView = g.view, let otherView = other.view else { return false }
            var ancestor: UIView? = otherView
            while let a = ancestor {
                if a === blockerView { return true }
                ancestor = a.superview
            }
            return false
        }
    }
}
#endif
