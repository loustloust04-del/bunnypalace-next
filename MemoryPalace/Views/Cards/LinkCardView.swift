import SwiftUI
import SwiftStreamingMarkdown

/// 外链卡（research-chat-cards §7.1）：头图 + 标题 + 站点图标 · 域名；点 = 聊天里点链接的同一行为
struct LinkCardView: View {
    let url: URL
    let label: String?
    @Environment(\.openURL) private var openURL
    @AppStorage(LocalMode.key) private var localMode = true
    @State private var preview: LinkPreview?

    init(url: URL, label: String?) {
        self.url = url
        self.label = label
        // 首帧就用能同步拿到的结果（缓存 / 简版），不先闪骨架再变高（终审 I4）
        _preview = State(initialValue: LinkPreviewStore.shared.immediate(url))
    }

    private var title: String { preview?.title ?? label ?? url.absoluteString }

    /// 头图宽高比（og:image 常见的 1200×630）
    static let bannerAspect: CGFloat = 1200.0 / 630.0

    var body: some View {
        Button { openURL(url) } label: {
            VStack(alignment: .leading, spacing: 0) {
                // 头图：按网页预览图的通用比例 1.91:1（og:image 1200×630）占位，图片等比铺满、裁掉多出的边。
                // 以前是把图硬拉成 16:9（非 16:9 的图会变形），骨架又只有 120 高（图出来时卡片跳一下）
                if let file = preview?.imageFile, let image = Self.image(at: LinkPreviewStore.shared.imageURL(file)) {
                    Color.clear
                        .aspectRatio(Self.bannerAspect, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay { image.resizable().scaledToFill() }
                        .clipped()
                } else if preview == nil {
                    Rectangle().fill(CodeBlockStyle.stroke.opacity(0.35))                      // 抓取中骨架：和头图同比例
                        .aspectRatio(Self.bannerAspect, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if let file = preview?.iconFile, let icon = Self.image(at: LinkPreviewStore.shared.imageURL(file)) {
                            icon.resizable().frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
                        } else {
                            Image(systemName: "link").font(.system(size: 11)).foregroundStyle(CodeBlockStyle.label)
                        }
                        Text(url.host ?? url.absoluteString)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(CodeBlockStyle.label)
                            .lineLimit(1)
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .mintCard()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("复制链接") { PlatformClipboard.copyString(url.absoluteString) }
            Button("打开") { openURL(url) }
        }
        .task(id: "\(url.absoluteString)|\(localMode)") {
            if let now = LinkPreviewStore.shared.immediate(url) { preview = now }
            let loaded = await LinkPreviewStore.shared.preview(for: url)
            guard !Task.isCancelled else { return }
            preview = loaded
        }
    }

    private static func image(at fileURL: URL) -> Image? {
        #if os(macOS)
        NSImage(contentsOf: fileURL).map { Image(nsImage: $0) }
        #else
        UIImage(contentsOfFile: fileURL.path).map { Image(uiImage: $0) }
        #endif
    }
}
