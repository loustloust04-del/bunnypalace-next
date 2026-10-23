import SwiftUI

/// 输入框正上方的「@ 文件库文件」候选（和 CC 斜杠浮板同一挂载位，plan-input-file-mention）。
/// 只在有命中时挂；mac 的 ↑↓ 高亮由宿主传 `highlighted`。
struct FileMentionSuggestions: View {
    let hits: [FileLibraryStore.FileMeta]
    let profileId: String
    var highlighted: Int? = nil
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("文件库")
                Spacer()
                Text("\(hits.count) 个")
            }
            .font(.system(size: 11.5))
            .foregroundColor(Theme.textMuted)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 4)

            ForEach(Array(hits.enumerated()), id: \.element.path) { i, f in
                Button { onPick(f.path) } label: { row(f, on: i == highlighted) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("file-mention-\(i)")
            }
        }
        .padding(6)
        .shellGlass(in: .rect(cornerRadius: 18), tint: 0.15)
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(FileLibraryUI.hairline, lineWidth: 0.5).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }

    private func row(_ f: FileLibraryStore.FileMeta, on: Bool) -> some View {
        let folder = FileLibraryDisplay.parentFolder(f.path)
        let time = FileLibraryDisplay.timeText(f.modifiedAt)
        return HStack(spacing: 10) {
            FileLibraryTile.file(f.path, profileId: profileId, side: 36, modifiedAt: f.modifiedAt)
            VStack(alignment: .leading, spacing: 1) {
                Text(FileLibraryDisplay.fileName(f.path))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folder.isEmpty ? time : "\(folder) · \(time)")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            #if os(macOS)
            if on {
                Text("↩")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
            }
            #endif
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(on ? Theme.textPrimary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
    }
}
