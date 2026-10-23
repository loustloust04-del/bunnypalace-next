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

    @AppStorage(DebugRenderSettings.themeBackgroundModeKey)
    private var rawMode: String = DebugThemeBackgroundMode.original.rawValue

    private var mode: DebugThemeBackgroundMode {
        DebugThemeBackgroundMode(rawValue: rawMode) ?? .original
    }

    var body: some View {
        Group {
            switch mode {
            case .original, .zstackLayer:
                // zstackLayer 模式下 ContentView 会把本 view 挪到 ZStack 底层（不再走 .background），
                // 本 body 的内部实现照旧（GeometryReader + clipped）。
                originalBody
            case .noGeometryReader:
                noGeometryReaderBody
            case .grIgnoresSafeArea:
                grIgnoresSafeAreaBody
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 原版 (也给 zstackLayer 模式复用)

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

    // MARK: - A. 不用 GeometryReader，ZStack + flex frame

    private var noGeometryReaderBody: some View {
        ZStack {
            fill
            if let imageURL {
                ThemeBackgroundArtworkFlex(
                    url: imageURL,
                    backgroundStyle: backgroundStyle
                )
                .overlay(overlayGradient)
                .opacity(backgroundStyle.resolvedOpacity(for: scheme))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - B. GeometryReader 自己 ignoresSafeArea

    private var grIgnoresSafeAreaBody: some View {
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
        .ignoresSafeArea()
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

// MARK: - Artwork (flex frame 版，模式 A 用)

private struct ThemeBackgroundArtworkFlex: View {
    let url: URL
    let backgroundStyle: ThemeBackgroundStyle

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(
            x: backgroundStyle.resolvedOffsetX,
            y: backgroundStyle.resolvedOffsetY
        )
        .clipped()
        .allowsHitTesting(false)
    }
}
