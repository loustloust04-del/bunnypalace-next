import SwiftUI
import AVKit

/// 点图进全屏（粟粟 2026-09-27：图片要能横划）。左右划切下一张，双指缩放、双击放大/还原，
/// 视频直接播。黑底，右上关闭，顶上「2 / 4」。
struct TwitterMediaViewer: View {
    let media: [TweetMedia]
    let mediaDir: URL
    @State var index: Int
    var onClose: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            pager
            HStack {
                if media.count > 1 {
                    Text("\(index + 1) / \(media.count)")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.black.opacity(0.5), in: Capsule())
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var pager: some View {
        #if os(iOS)
        TabView(selection: $index) {
            ForEach(Array(media.enumerated()), id: \.offset) { i, m in
                page(m).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        #else
        // macOS 没有翻页式 TabView：左右箭头 + 键盘方向键
        page(media[index])
            .id(index)
            .overlay {
                HStack {
                    arrow("chevron.left", enabled: index > 0) { index -= 1 }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Spacer()
                    arrow("chevron.right", enabled: index < media.count - 1) { index += 1 }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .padding(.horizontal, 16)
            }
        #endif
    }

    @ViewBuilder private func page(_ m: TweetMedia) -> some View {
        let url = mediaDir.appendingPathComponent(m.fileName)
        if url.pathExtension.lowercased() == "mp4" {
            VideoPlayer(player: AVPlayer(url: url))
        } else {
            ZoomableImage(url: url)
        }
    }

    #if os(macOS)
    private func arrow(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(Color.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }
    #endif
}

/// 一张可缩放的图。放大后能拖着看；缩回 1 倍时拖动交还给翻页。
private struct ZoomableImage: View {
    let url: URL
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        TwitterMediaImage(url: url, contentMode: .fit)
            .scaleEffect(scale)
            .offset(offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { scale = min(max(base * $0.magnification, 1), 5) }
                    .onEnded { _ in
                        base = scale
                        if scale <= 1 { reset() }
                    }
            )
            // 只在放大时装拖动手势，不然会吃掉 TabView 的横划
            .simultaneousGesture(DragGesture()
                .onChanged { offset = CGSize(width: lastOffset.width + $0.translation.width,
                                             height: lastOffset.height + $0.translation.height) }
                .onEnded { _ in lastOffset = offset },
                including: scale > 1 ? .all : .subviews)
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3)) {
                    if scale > 1 { reset() } else { scale = 2.5; base = 2.5 }
                }
            }
    }

    private func reset() {
        scale = 1; base = 1; offset = .zero; lastOffset = .zero
    }
}
