import SwiftUI

/// 「＋」面板点 📎：最近文件横滑 + 「文件库」/「手机里的文件」两个入口（plan-input-file-mention）。
/// 尺寸 / 勾选照 PhotoStripPanel（80pt 方格、2.5 描边、勾），方块是文件库同款 tile。两端共用。
struct FileStripPanel: View {
    let profileId: String
    /// 勾选顺序 = 附加顺序
    @Binding var pickedPaths: [String]
    let onOpenLibrary: () -> Void
    let onOpenSystemFiles: () -> Void

    @State private var files: [FileLibraryStore.FileMeta] = []
    @State private var loaded = false

    private var side: CGFloat { FileLibraryUI.size(80) }

    private var systemFilesTitle: String {
        #if os(macOS)
        "电脑上的文件"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad 里的文件" : "手机里的文件"
        #endif
    }

    private var systemFilesSubtitle: String {
        #if os(macOS)
        "从 Finder 里选"
        #else
        "系统「文件」"
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近文件")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("文件库 · 按修改时间")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
                HStack(alignment: .top, spacing: 10) {
                    if loaded && files.isEmpty {
                        emptyCell
                    }
                    ForEach(files, id: \.path) { f in cell(f) }
                    if !files.isEmpty { allFilesCell }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: side + 36)

            HStack(spacing: 10) {
                entry(symbol: "folder", title: "文件库", subtitle: "搜索、浏览全部", action: onOpenLibrary)
                    .accessibilityIdentifier("file-strip-library")
                entry(symbol: systemFilesSymbol, title: systemFilesTitle, subtitle: systemFilesSubtitle, action: onOpenSystemFiles)
                    .accessibilityIdentifier("file-strip-system")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background {
            #if os(iOS)
            Color.clear
                .glassEffect(.regular.tint(Color.black.opacity(0.01)),
                             in: .rect(cornerRadii: .init(topLeading: 16, topTrailing: 16)))
                .ignoresSafeArea(.container, edges: .bottom)
            #else
            Color.clear
                .shellGlass(in: .rect(cornerRadii: .init(topLeading: 16, topTrailing: 16)), tint: 0.15)
            #endif
        }
        .task(id: profileId) {
            files = await FileMention.recentFiles(profileId: profileId)
            loaded = true
        }
    }

    private var systemFilesSymbol: String {
        #if os(macOS)
        "desktopcomputer"
        #else
        "iphone"
        #endif
    }

    private func cell(_ f: FileLibraryStore.FileMeta) -> some View {
        let isSelected = pickedPaths.contains(f.path)
        let radius = side * 0.28
        let folder = (FileLibraryDisplay.parentFolder(f.path) as NSString).lastPathComponent
        let isImage = FileLibraryDisplay.kind(of: f.path) == .image
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                FileLibraryTile.file(f.path, profileId: profileId, side: 80, modifiedAt: f.modifiedAt)
                    .overlay(alignment: .bottom) {
                        if !isImage && !folder.isEmpty {
                            Text(folder)
                                .font(.system(size: 9))
                                .foregroundColor(Theme.textMuted)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.bottom, 7)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(isSelected ? Theme.branchIndicator : Color.clear, lineWidth: 2.5)
                    )
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, Theme.branchIndicator)
                        .offset(x: -4, y: 4)
                }
            }
            Text(FileLibraryDisplay.fileName(f.path))
                .font(.system(size: 11.5))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(FileLibraryDisplay.timeText(f.modifiedAt))
                .font(.system(size: 10.5))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
        }
        .frame(width: side, alignment: .leading)
        .contentShape(Rectangle())
        // 横滑 ScrollView 里 Button 的 tap 会被滚动手势吞（swiftui-ui 规则），同 PhotoStripPanel 用 onTapGesture
        .onTapGesture {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            if let i = pickedPaths.firstIndex(of: f.path) {
                pickedPaths.remove(at: i)
            } else {
                pickedPaths.append(f.path)
            }
        }
        .accessibilityIdentifier("file-strip-cell")
    }

    private var allFilesCell: some View {
        placeholderCell(symbol: "folder", text: "全部文件")
            .contentShape(Rectangle())
            .onTapGesture { onOpenLibrary() }
    }

    private var emptyCell: some View {
        placeholderCell(symbol: "doc", text: "文件库里还没有文件", wide: true)
    }

    private func placeholderCell(symbol: String, text: String, wide: Bool = false) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundColor(Theme.textMuted.opacity(0.5))
            Text(text)
                .font(.system(size: 9.5))
                .foregroundColor(Theme.textMuted.opacity(0.7))
        }
        .frame(width: wide ? side * 2 + 10 : side, height: side)
        .background(RoundedRectangle(cornerRadius: side * 0.28, style: .continuous).fill(Theme.accent.opacity(0.08)))
    }

    private func entry(symbol: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.textPrimary.opacity(0.06)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.mainBg.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(FileLibraryUI.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
