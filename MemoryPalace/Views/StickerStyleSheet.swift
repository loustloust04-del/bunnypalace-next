import SwiftUI

/// 描边 + 滤镜预览面板
struct StickerStyleSheet: View {
    let asset: StickerAsset
    let profileId: String
    let onApply: (BorderStyle, FilterStyle) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedBorder: BorderStyle
    @State private var selectedFilter: FilterStyle
    @State private var previewImage: Image?
    @State private var isRendering = false

    init(asset: StickerAsset, profileId: String, onApply: @escaping (BorderStyle, FilterStyle) -> Void) {
        self.asset = asset
        self.profileId = profileId
        self.onApply = onApply
        _selectedBorder = State(initialValue: BorderStyle(rawValue: asset.borderStyle) ?? .none)
        _selectedFilter = State(initialValue: FilterStyle(rawValue: asset.filterStyle) ?? .none)
    }

    private let borderColumns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    private let filterColumns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    var body: some View {
        VStack(spacing: 14) {
            // Header
            HStack {
                Text("贴纸样式")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textMuted)
            }

            // 预览
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.accent.opacity(0.2))
                    .frame(height: 100)
                if let img = previewImage {
                    img.resizable().aspectRatio(contentMode: .fit).frame(height: 90)
                } else {
                    ProgressView().scaleEffect(0.6)
                }
            }

            // 描边
            VStack(alignment: .leading, spacing: 6) {
                Text("描边")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                LazyVGrid(columns: borderColumns, spacing: 6) {
                    ForEach(BorderStyle.allCases, id: \.rawValue) { style in
                        borderOption(style)
                    }
                }
            }

            // 滤镜
            VStack(alignment: .leading, spacing: 6) {
                Text("滤镜")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                LazyVGrid(columns: filterColumns, spacing: 6) {
                    ForEach(FilterStyle.allCases, id: \.rawValue) { style in
                        filterOption(style)
                    }
                }
            }

            // 应用按钮
            Button(action: {
                onApply(selectedBorder, selectedFilter)
                dismiss()
            }) {
                Text(isRendering ? "渲染中..." : "应用")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.branchIndicator))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.sidebarBg)
        .onAppear { loadCurrentPreview() }
        .onChange(of: selectedBorder) { _, _ in renderPreview() }
        .onChange(of: selectedFilter) { _, _ in renderPreview() }
    }

    // MARK: - Border Option

    private func borderOption(_ style: BorderStyle) -> some View {
        let isActive = selectedBorder == style
        return Button { selectedBorder = style } label: {
            VStack(spacing: 2) {
                borderPreviewColor(style)
                    .frame(height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isActive ? Theme.branchIndicator : Theme.accent.opacity(0.3), lineWidth: isActive ? 2 : 0.5)
                    )
                Text(style.displayName)
                    .font(.system(size: 8))
                    .foregroundColor(isActive ? Theme.textPrimary : Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func borderPreviewColor(_ style: BorderStyle) -> some View {
        switch style {
        case .none: Color.gray.opacity(0.2)
        case .solidWhite: Color.white
        case .solidBlack: Color.black
        case .gradientRainbow:
            LinearGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple], startPoint: .leading, endPoint: .trailing)
        case .laser:
            LinearGradient(colors: [.purple, .cyan, .pink], startPoint: .leading, endPoint: .trailing)
        case .lace: Color(red: 1, green: 0.92, blue: 0.95)
        case .glitter:
            LinearGradient(colors: [.yellow, .orange, .yellow], startPoint: .leading, endPoint: .trailing)
        case .neon: Color(red: 0.2, green: 1, blue: 0.8)
        }
    }

    // MARK: - Filter Option

    private func filterOption(_ style: FilterStyle) -> some View {
        let isActive = selectedFilter == style
        return Button { selectedFilter = style } label: {
            VStack(spacing: 2) {
                filterPreviewIcon(style)
                    .frame(height: 32)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isActive ? Theme.branchIndicator.opacity(0.15) : Theme.mainBg.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isActive ? Theme.branchIndicator : .clear, lineWidth: 1.5)
                    )
                Text(style.displayName)
                    .font(.system(size: 9))
                    .foregroundColor(isActive ? Theme.textPrimary : Theme.textMuted)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func filterPreviewIcon(_ style: FilterStyle) -> some View {
        switch style {
        case .none:
            Image(systemName: "circle.slash")
                .font(.system(size: 14))
                .foregroundColor(Theme.textMuted)
        case .vintage:
            Image(systemName: "camera.filters")
                .font(.system(size: 14))
                .foregroundColor(.orange)
        case .holographic:
            Image(systemName: "rainbow")
                .font(.system(size: 14))
                .foregroundColor(.purple)
        case .pixel:
            Image(systemName: "squareshape.split.3x3")
                .font(.system(size: 14))
                .foregroundColor(.green)
        case .comic:
            Image(systemName: "theatermask.and.paintbrush")
                .font(.system(size: 14))
                .foregroundColor(.blue)
        }
    }

    // MARK: - Preview Rendering

    private func loadCurrentPreview() {
        if let data = StickerFileManager.loadImageCached(path: asset.thumbnailPath, profileId: profileId) {
            #if os(macOS)
            if let nsImage = NSImage(data: data) { previewImage = Image(nsImage: nsImage) }
            #else
            if let uiImage = UIImage(data: data) { previewImage = Image(uiImage: uiImage) }
            #endif
        }
    }

    private func renderPreview() {
        isRendering = true
        let sourcePath = asset.originalImagePath ?? asset.imagePath
        guard let sourceData = StickerFileManager.loadImage(path: sourcePath, profileId: profileId) else {
            isRendering = false
            return
        }

        Task.detached(priority: .userInitiated) {
            do {
                // 滤镜 → 描边（用缩略图大小加速）
                let filtered = try StickerFilterRenderer.applyFilter(on: sourceData, style: selectedFilter)
                let bordered = try StickerBorderRenderer.renderBorder(on: filtered, style: selectedBorder, width: CGFloat(asset.borderWidth))

                await MainActor.run {
                    #if os(macOS)
                    if let nsImage = NSImage(data: bordered) { previewImage = Image(nsImage: nsImage) }
                    #else
                    if let uiImage = UIImage(data: bordered) { previewImage = Image(uiImage: uiImage) }
                    #endif
                    isRendering = false
                }
            } catch {
                await MainActor.run { isRendering = false }
            }
        }
    }
}
