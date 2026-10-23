#if os(macOS)
import SwiftUI

/// Only user navigation changes intent. Content growth is not a request to leave
/// or regain the tail. Opening a session lands at the bottom and follows (09-25 plan-mac-code-mode-gaps §5);
/// the scroll-to-bottom button does the same.
struct MacCodingScrollPolicy {
    private(set) var followsTail = false
    enum Source { case user, layout, programmatic }
    mutating func observe(distanceToBottom: CGFloat, source: Source) {
        guard source == .user else { return }
        followsTail = distanceToBottom <= 2
    }
    func shouldFollow(isUserScrolling: Bool) -> Bool { followsTail && !isUserScrolling }
    mutating func explicitNavigation() { followsTail = false }
    mutating func follow() { followsTail = true }
}

struct MacCodingTranscriptScroll<Content: View>: View {
    let sessionKey: String
    let revision: UInt64
    let focusSeq: Int?
    @ViewBuilder var content: Content
    @State private var position = ScrollPosition()
    @State private var policy = MacCodingScrollPolicy()
    @State private var userScrolling = false
    /// 离底超过一屏才出回底钮；只在越线时写，别每像素刷 body
    @State private var farFromBottom = false
    /// 打开即回底只做一次（换会话时外面 `.id(meta.key)` 重建本视图，自然重置）
    @State private var landedAtBottom = false
    // Latest geometry is used at gesture end without invalidating the body per pixel.
    @State private var measurement = LatestGeometry()
    private final class LatestGeometry { var distance: CGFloat = .infinity }
    private struct Geometry: Equatable {
        let offset: CGFloat
        let content: CGSize
        let viewport: CGSize
        let topInset: CGFloat
        let bottomInset: CGFloat
        var distance: CGFloat { max(0, content.height + bottomInset - offset - viewport.height) }
    }

    var body: some View {
        ScrollView {
            content
        }
        .scrollPosition($position)
        .defaultScrollAnchor(policy.shouldFollow(isUserScrolling: userScrolling) ? .bottom : nil, for: .sizeChanges)
        .onScrollGeometryChange(for: Geometry.self) { geometry in
            Geometry(offset: geometry.contentOffset.y, content: geometry.contentSize,
                     viewport: geometry.containerSize, topInset: geometry.contentInsets.top,
                     bottomInset: geometry.contentInsets.bottom)
        } action: { old, new in
            measurement.distance = new.distance
            let far = new.distance > new.viewport.height
            if far != farFromBottom { farFromBottom = far }
            // 打开即回底：等第一次量到内容再滚；⌘K 搜索点进来的（带 focusSeq）照旧去命中那条
            if !landedAtBottom, new.content.height > 0 {
                landedAtBottom = true
                if focusSeq == nil {
                    policy.follow()
                    position.scrollTo(edge: .bottom)
                }
            }
            let userMoved = userScrolling && old.offset != new.offset
                && old.content == new.content && old.viewport == new.viewport
                && old.topInset == new.topInset && old.bottomInset == new.bottomInset
            policy.observe(distanceToBottom: new.distance, source: userMoved ? .user : .layout)
        }
        .onScrollPhaseChange { _, new in
            #if DEBUG
            ShellProbe.keep("[PROBE coding.scroll.phase] \(new)")
            #endif
            let wasUserScrolling = userScrolling
            userScrolling = new == .tracking || new == .interacting || new == .decelerating
            if wasUserScrolling, new == .idle, measurement.distance.isFinite {
                // Lazy rows can be measured during the gesture. Its final position,
                // not an intermediate size change, decides whether to resume following.
                policy.observe(distanceToBottom: measurement.distance, source: .user)
                if policy.followsTail { position.scrollTo(edge: .bottom) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // 和普通聊天同一颗、同一个位置（CardFlowView.scrollToBottomOverlay mac 16/16）
            ScrollToBottomButton(isVisible: farFromBottom) {
                policy.follow()
                withAnimation { position.scrollTo(edge: .bottom) }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        }
        .onChange(of: focusSeq) { _, _ in policy.explicitNavigation() }
        .onChange(of: revision) { _, _ in
            #if DEBUG
            ShellProbe.keep("[PROBE coding.scroll.refresh] follow=\(policy.followsTail) revision=\(revision)")
            #endif
            if policy.shouldFollow(isUserScrolling: userScrolling) { position.scrollTo(edge: .bottom) }
        }
        .onAppear {
            #if DEBUG
            ShellProbe.keep("[PROBE coding.scroll.mount] key=\(sessionKey)")
            #endif
        }
        .onDisappear {
            #if DEBUG
            ShellProbe.keep("[PROBE coding.scroll.unmount] key=\(sessionKey)")
            #endif
        }
    }
}
#endif
