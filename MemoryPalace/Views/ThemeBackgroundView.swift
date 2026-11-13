import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ThemeBackgroundView: View {
    let fill: Color
    let imageURL: URL?
    let scheme: ColorScheme
    var backgroundStyle: ThemeBackgroundStyle = ThemeBackgroundStyle()

    var body: some View {
        originalBody.allowsHitTesting(false)
    }

    private var originalBody: some View {
        GeometryReader { proxy in
            ZStack {
                fill
                if let imageURL {
                    ThemeBackgroundArtwork(
                        url: imageURL,
                        backgroundStyle: backgroundStyle,
                        canvasSize: proxy.size
                    )
                    .overlay(overlayGradient)
                    .opacity(backgroundStyle.resolvedOpacity(for: scheme))
                    .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    // MARK: - Gradient overlay

    private var overlayGradient: LinearGradient {
        LinearGradient(
            colors: overlayColors,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 系数与 ContentView.wallpaperGradientColors 同一组；乘 resolvedVeil（1 = 改动前强度，0 = 原图）
    private var overlayColors: [Color] {
        let veil = backgroundStyle.resolvedVeil
        if scheme == .dark {
            return [
                Color.black.opacity(0.42 * veil),
                Color.black.opacity(0.18 * veil),
                Color.black.opacity(0.50 * veil)
            ]
        }
        return [
            Color.white.opacity(0.18 * veil),
            Color.white.opacity(0.04 * veil),
            Color.white.opacity(0.24 * veil)
        ]
    }
}

// MARK: - Artwork (固定 canvasSize 版，原版 + 模式 B)

private struct ThemeBackgroundArtwork: View {
    let url: URL
    let backgroundStyle: ThemeBackgroundStyle
    let canvasSize: CGSize

    var body: some View {
        Group {
            #if os(macOS)
            MacBackgroundArtwork(url: url)
            #else
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
            } else {
                EmptyView()
            }
            #endif
        }
        .scaledToFill()
        .frame(width: canvasSize.width, height: canvasSize.height)
        .offset(
            x: backgroundStyle.resolvedOffsetX,
            y: backgroundStyle.resolvedOffsetY
        )
        .clipped()
        .allowsHitTesting(false)
    }
}
