import SwiftUI

struct CharacterCoverTile: View {
    let name: String
    let imageData: Data?
    let subtitle: String
    var isCurrent = false
    var hasWorldBook = false
    var hasRegex = false
    var hasScripts = false
    var highlighted = false
    /// 第二批 B9：app 自带的示例卡
    var isSample = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 图片只占封面提案，不让原图尺寸撑开两列网格。
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.accent)
                .aspectRatio(1 / 0.82, contentMode: .fit)
                .overlay {
                    if let imageData, let image = platformImage(imageData) {
                        GeometryReader { g in
                            image.resizable().scaledToFill()
                                .frame(width: g.size.width, height: g.size.height)
                                .clipped()
                        }
                    } else {
                        Text(String(name.first(where: { $0.isLetter || $0.isNumber }) ?? "·"))
                            .font(.system(size: 42, weight: .light, design: .serif))
                            .foregroundColor(Theme.branchIndicator)
                    }
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        if isCurrent {
                            Text("当前楼层")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.branchIndicator)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Theme.mainBg, in: Capsule())
                        }
                        if isSample {
                            Text("示例")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Theme.mainBg, in: Capsule())
                        }
                    }
                    .padding(8)
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasWorldBook || hasRegex {
                        HStack(spacing: 6) {
                            if hasWorldBook { Image(systemName: "book").accessibilityLabel("带世界书") }
                            if hasRegex { Image(systemName: "textformat.abc").accessibilityLabel("带正则") }
                        }
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .padding(6)
                        .background(Theme.mainBg, in: Capsule())
                        .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.branchIndicator.opacity(highlighted ? 1 : 0), lineWidth: 3)
                }
            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if hasScripts {
                Text("· 交互还不完整")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }
}
