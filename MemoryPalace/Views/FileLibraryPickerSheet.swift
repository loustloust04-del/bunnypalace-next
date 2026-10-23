import SwiftUI

/// 附件面板「文件库」入口：搜索 + 多选的轻量选择单（plan-input-file-mention）。
/// 清单 / 搜索口径同 @ 候选（只比名字和文件夹）；不复用 page2 的 FileLibraryPanelView。
struct FileLibraryPickerSheet: View {
    let profileId: String
    let onAttach: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var files: [FileLibraryStore.FileMeta] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var picked: [String] = []
    /// 按 query 在后台排好的结果（勾选不重排，sol 审 #7）
    @State private var shown: [FileLibraryStore.FileMeta] = []

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty {
                    ContentUnavailableView(files.isEmpty ? "文件库里还没有文件" : "没有名字对得上的文件",
                                           systemImage: "doc")
                } else {
                    List(shown, id: \.path) { f in row(f) }
                        .listStyle(.plain)
                }
            }
            .navigationTitle("文件库")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: "搜文件名 / 文件夹")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "附加" : "附加 \(picked.count) 个") {
                        onAttach(picked)
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .task {
            files = await FileMention.allFiles(profileId: profileId)
            shown = files
            loaded = true
        }
        .task(id: query) {
            guard loaded else { return }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let all = files
            var result = all
            if !q.isEmpty {
                result = await Task.detached(priority: .userInitiated) {
                    FileMention.rank(all, query: q, limit: nil)
                }.value
            }
            guard !Task.isCancelled else { return }
            shown = result
        }
    }

    private func row(_ f: FileLibraryStore.FileMeta) -> some View {
        let isPicked = picked.contains(f.path)
        let folder = FileLibraryDisplay.parentFolder(f.path)
        let time = FileLibraryDisplay.timeText(f.modifiedAt)
        return Button {
            if let i = picked.firstIndex(of: f.path) {
                picked.remove(at: i)
            } else {
                picked.append(f.path)
            }
        } label: {
            HStack(spacing: 12) {
                FileLibraryTile.file(f.path, profileId: profileId, side: 36, modifiedAt: f.modifiedAt)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FileLibraryDisplay.fileName(f.path))
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(folder.isEmpty ? time : "\(folder) · \(time)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isPicked ? AnyShapeStyle(Theme.branchIndicator) : AnyShapeStyle(Theme.textMuted.opacity(0.4)))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
