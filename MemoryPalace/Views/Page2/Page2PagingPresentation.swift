#if os(iOS)
import SwiftUI
import Combine

@MainActor @Observable
final class Page2PagingPresentation {
    @ObservationIgnored var trace: ((String) -> Void)?
    @ObservationIgnored weak var scrollView: UIScrollView?
    @ObservationIgnored var mayBegin: () -> Bool = { true }
    @ObservationIgnored var mayReceive: (UITouch) -> Bool = { _ in true }
    @ObservationIgnored var stackScrolling = Set<UUID>()
    var currentPageID: UUID?
    var showsLibrary = false
    var selectedPage = 0
    var selectionInitialized = false
    var libraryEnabled = true
    /// 翻页每帧写；不能成为 SwiftUI 主树的观察依赖：`Page2NativePager.configure → layoutPages → updatePresentation`
    /// 里那句 `!= progress` 的读会让 SwiftUI 把它记成 representable 的依赖，于是每帧 `updateUIViewController →
    /// host.rootView = content`，所有桌面页的 `Page2GridView` 带着新闭包整批重建（真机探针：两次翻页 grid body 1025 次、
    /// 全是 @self changed；docs/research-page2-ios-hangs.md §3）
    @ObservationIgnored var libraryProgress: CGFloat = 0
    var isScrolling = false
    @ObservationIgnored let chromeMotion = Page2ChromeMotion()
}

/// 仅显示修饰器订阅。Combine 属性的读取不会注册成 representable 的 Observation 依赖。
@MainActor
final class Page2ChromeMotion: ObservableObject {
    struct Sample: Equatable {
        var progress: CGFloat = 0
        var width: CGFloat = 0
    }
    @Published private(set) var sample = Sample()
    func update(progress: CGFloat, width: CGFloat) {
        let next = Sample(progress: progress, width: width)
        if sample != next { sample = next }
    }
}

struct Page2LibraryBackdrop: View {
    let presentation: Page2PagingPresentation
    let scheme: ColorScheme
    var body: some View {
        // perf-flash C3b / astra R2 G7：透明度自己订阅 chromeMotion（窄范围，只有这层跟着内层滑动更新）。
        // 原来读的是不被观察的 libraryProgress，靠搜索胶囊 .global 回调逐帧写 @State 顺带刷新整个主屏
        Page2LibraryBackdropFill(motion: presentation.chromeMotion, scheme: scheme)
    }
}

private struct Page2LibraryBackdropFill: View {
    @ObservedObject var motion: Page2ChromeMotion
    let scheme: ColorScheme
    var body: some View {
        Rectangle().fill(.ultraThinMaterial)
            .environment(\.colorScheme, scheme)
            .opacity(motion.sample.progress * 0.45)
    }
}

struct Page2PagingChrome<Content: View>: View {
    let presentation: Page2PagingPresentation
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().modifier(Page2ChromeSlide(motion: presentation.chromeMotion))
    }
}

private struct Page2ChromeSlide: ViewModifier {
    @ObservedObject var motion: Page2ChromeMotion
    func body(content: Content) -> some View {
        let sample = motion.sample
        content
            .offset(x: -sample.progress * sample.width)
            .opacity(sample.progress >= 0.999 ? 0 : 1)
            .allowsHitTesting(sample.progress <= 0.001)
            .accessibilityHidden(sample.progress >= 0.999)
            .animation(nil, value: sample)
    }
}

struct Page2HomePageControl: View {
    let presentation: Page2PagingPresentation
    let pages: [Page2Page]
    let currentID: UUID
    let editing: Bool
    var onActivate: () -> Void
    var body: some View {
        Button(action: onActivate) {
            Group {
                if editing || presentation.isScrolling {
                    HStack(spacing: 7) {
                        ForEach(pages) { page in
                            Circle().fill(.primary.opacity(page.id == currentID ? 1 : 0.35)).frame(width: 5, height: 5)
                        }
                    }
                } else { Label("搜索", systemImage: "magnifyingglass").font(.system(size: 14)) }
            }
            .modifier(Page2DesktopLabel())
            .frame(minWidth: 48, minHeight: 30).padding(.horizontal, 14)
            .background { Color.clear.glassEffect(.clear, in: .capsule).allowsHitTesting(false) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(editing ? "管理主屏页面" : "搜索应用")
        .accessibilityIdentifier("page2.page-control")
    }
}
#endif
