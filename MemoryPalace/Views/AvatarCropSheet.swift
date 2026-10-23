import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
// PlatformImage / Image(platformImage:) 共用声明在 MessageSegmentsView.swift

// MARK: - 裁剪数学（纯函数，AvatarCropMathTests 覆盖）

enum AvatarCropMath {
    /// 用户在裁剪框里的缩放/拖动 → 源图坐标系的裁剪正方形。
    /// 坐标模型：图以 displayScale = (circleDiameter / 图短边) × zoom 显示，
    /// 图中心 = 视图中心 + offset，圆心 = 视图中心。
    static func cropRect(imageSize: CGSize, circleDiameter: CGFloat, zoom: CGFloat, offset: CGSize) -> CGRect {
        let s = displayScale(imageSize: imageSize, circleDiameter: circleDiameter, zoom: zoom)
        let x = (imageSize.width * s / 2 - offset.width - circleDiameter / 2) / s
        let y = (imageSize.height * s / 2 - offset.height - circleDiameter / 2) / s
        let side = circleDiameter / s
        return CGRect(x: x, y: y, width: side, height: side)
    }

    static func displayScale(imageSize: CGSize, circleDiameter: CGFloat, zoom: CGFloat) -> CGFloat {
        circleDiameter / min(imageSize.width, imageSize.height) * zoom
    }

    /// 拖动边界：圆必须始终被图盖住。返回 clamp 后的 offset。
    static func clampOffset(_ offset: CGSize, imageSize: CGSize, circleDiameter: CGFloat, zoom: CGFloat) -> CGSize {
        let s = displayScale(imageSize: imageSize, circleDiameter: circleDiameter, zoom: zoom)
        let maxX = max(0, (imageSize.width * s - circleDiameter) / 2)
        let maxY = max(0, (imageSize.height * s - circleDiameter) / 2)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 6

    /// 裁剪渲染：源图 draw(in:) 进 512×512 位图（变换让 cropRect 映射满幅）。
    /// 走平台 draw 自动处理 EXIF 朝向，不走 CGImage.cropping。输出 JPEG(0.85)。
    static func renderCrop(image: PlatformImage, cropRect: CGRect, outputSide: CGFloat = 512) -> Data? {
        guard cropRect.width > 0 else { return nil }
        let k = outputSide / cropRect.width
        let drawRect = CGRect(
            x: -cropRect.minX * k,
            y: -cropRect.minY * k,
            width: image.size.width * k,
            height: image.size.height * k
        )
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: outputSide, height: outputSide), format: format)
            .image { _ in image.draw(in: drawRect) }
        return rendered.jpegData(compressionQuality: 0.85)
        #else
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(outputSide), pixelsHigh: Int(outputSide),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = CGSize(width: outputSide, height: outputSide)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        CGRect(x: 0, y: 0, width: outputSide, height: outputSide).fill()
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        #endif
    }
}

// MARK: - 裁剪 Sheet（双端共用）

/// 圆形头像裁剪：pinch 缩放 + 拖动，确认输出 512×512 JPEG。
struct AvatarCropSheet: View {
    let image: PlatformImage
    let onCrop: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1
    @State private var zoomAnchor: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAnchor: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height) - 48
            let s = AvatarCropMath.displayScale(imageSize: image.size, circleDiameter: d, zoom: zoom)

            ZStack {
                Color.black.ignoresSafeArea()

                Image(platformImage: image)
                    .resizable()
                    .frame(width: image.size.width * s, height: image.size.height * s)
                    .offset(offset)

                // 圈外调暗 + 白描边（destinationOut 挖孔）
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        Circle()
                            .frame(width: d, height: d)
                            .blendMode(.destinationOut)
                    )
                    .compositingGroup()
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: d, height: d)
                    .allowsHitTesting(false)

                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        Button(action: { dismiss() }) {
                            Text("取消")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(.horizontal, 22)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(Color.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)

                        Button(action: { confirm(circleDiameter: d) }) {
                            Text("确认")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 26)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(Theme.branchIndicator))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 24)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        zoom = min(max(zoomAnchor * value.magnification, AvatarCropMath.minZoom), AvatarCropMath.maxZoom)
                        offset = AvatarCropMath.clampOffset(offset, imageSize: image.size, circleDiameter: d, zoom: zoom)
                    }
                    .onEnded { _ in
                        zoomAnchor = zoom
                        offsetAnchor = offset
                    }
                    .simultaneously(
                        with: DragGesture()
                            .onChanged { value in
                                let raw = CGSize(width: offsetAnchor.width + value.translation.width,
                                                 height: offsetAnchor.height + value.translation.height)
                                offset = AvatarCropMath.clampOffset(raw, imageSize: image.size, circleDiameter: d, zoom: zoom)
                            }
                            .onEnded { _ in
                                offsetAnchor = offset
                            }
                    )
            )
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
        #if os(iOS)
        .presentationDragIndicator(.hidden)
        #endif
    }

    private func confirm(circleDiameter: CGFloat) {
        let rect = AvatarCropMath.cropRect(imageSize: image.size, circleDiameter: circleDiameter,
                                           zoom: zoom, offset: offset)
        if let data = AvatarCropMath.renderCrop(image: image, cropRect: rect) {
            onCrop(data)
        }
        dismiss()
    }
}

// MARK: - 设置入口（通用 tab「气泡标签」section，两端共用）

enum AvatarTarget: String, Identifiable {
    case user, assistant
    var id: String { rawValue }
    var label: String { self == .user ? "你的头像" : "AI 头像" }
}

struct AvatarCropPayload: Identifiable {
    let id = UUID()
    let image: PlatformImage
    let target: AvatarTarget
}

/// 「你的头像 / AI 头像」两行：圆形预览 + 选择照片（iOS PhotosPicker / macOS NSOpenPanel）+ 移除。
/// 确认裁剪后走 profileManager.updateProfile 正路落 Profile 字段。
struct AvatarSettingsRows: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var cropPayload: AvatarCropPayload?
    #if os(iOS)
    @State private var userPhotoItem: PhotosPickerItem?
    @State private var assistantPhotoItem: PhotosPickerItem?
    #endif

    var body: some View {
        VStack(spacing: 10) {
            row(.user)
            row(.assistant)
        }
        .sheet(item: $cropPayload) { payload in
            AvatarCropSheet(image: payload.image) { data in
                save(data, for: payload.target)
            }
        }
        #if os(iOS)
        .onChange(of: userPhotoItem) { _, item in load(item, for: .user) }
        .onChange(of: assistantPhotoItem) { _, item in load(item, for: .assistant) }
        #endif
    }

    @ViewBuilder
    private func row(_ target: AvatarTarget) -> some View {
        HStack(spacing: 10) {
            if let data = avatarData(target), let img = PlatformImage(data: data) {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
            } else {
                AvatarBox(size: 36)
            }

            Text(target.label)
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textPrimary)

            Spacer()

            #if os(iOS)
            PhotosPicker(selection: photoBinding(target), matching: .images) {
                pillLabel("选择照片", prominent: true)
            }
            .buttonStyle(.plain)
            #else
            Button("选择照片", action: { pickOnMac(target) })
                .buttonStyle(MacSettingsButton())
            #endif

            if avatarData(target) != nil {
                #if os(macOS)
                Button("移除", action: { save(nil, for: target) })
                    .buttonStyle(MacSettingsButton())
                #else
                Button(action: { save(nil, for: target) }) {
                    pillLabel("移除", prominent: false)
                }
                .buttonStyle(.plain)
                #endif
            }
        }
    }

    private func pillLabel(_ title: String, prominent: Bool) -> some View {
        Text(title)
            .font(.system(size: Theme.F.secondary, weight: .medium))
            .foregroundColor(prominent ? .white : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(prominent ? Theme.branchIndicator : Theme.accent.opacity(0.7)))
    }

    private func avatarData(_ target: AvatarTarget) -> Data? {
        guard let p = profileManager?.currentProfile else { return nil }
        return target == .user ? p.userAvatarData : p.assistantAvatarData
    }

    private func save(_ data: Data?, for target: AvatarTarget) {
        guard let pm = profileManager else { return }
        var p = pm.currentProfile
        if target == .user { p.userAvatarData = data } else { p.assistantAvatarData = data }
        pm.updateProfile(p)
    }

    #if os(iOS)
    private func photoBinding(_ target: AvatarTarget) -> Binding<PhotosPickerItem?> {
        target == .user ? $userPhotoItem : $assistantPhotoItem
    }

    private func load(_ item: PhotosPickerItem?, for target: AvatarTarget) {
        guard let item else { return }
        Task { @MainActor in
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                cropPayload = AvatarCropPayload(image: img, target: target)
            }
            if target == .user { userPhotoItem = nil } else { assistantPhotoItem = nil }
        }
    }
    #else
    private func pickOnMac(_ target: AvatarTarget) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .gif, .webP]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        cropPayload = AvatarCropPayload(image: img, target: target)
    }
    #endif
}
