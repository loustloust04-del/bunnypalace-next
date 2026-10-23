import SwiftUI

/// 草稿箱（粟粟 2026-09-27）。点一份接着写；回复 / 引用的草稿标着对象。左滑或点垃圾桶删。
struct TwitterDraftsSheet: View {
    let drafts: [TwitterDraft]
    let accent: Color
    /// 回复草稿显示「回复 @谁」要的 handle，按推文 id 查
    var replyHandle: (String) -> String? = { _ in nil }
    var onPick: (TwitterDraft) -> Void = { _ in }
    var onDelete: (TwitterDraft) -> Void = { _ in }
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("草稿").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("完成", action: onClose).buttonStyle(.plain).foregroundStyle(accent)
            }
            .padding(16)
            Divider().opacity(0.4)
            if drafts.isEmpty {
                Text("没有草稿。写到一半点取消，可以存在这里。")
                    .font(.footnote).foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(drafts, id: \.draftId) { d in
                        Button { onPick(d) } label: { row(d) }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.mainBg)
                            .swipeActions {
                                Button("删除", role: .destructive) { onDelete(d) }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.mainBg)
    }

    private func row(_ d: TwitterDraft) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let pid = d.replyToTweetId {
                    Text("回复 " + (replyHandle(pid).map { "@\($0)" } ?? "一条推"))
                        .font(.footnote).foregroundStyle(Theme.textMuted)
                } else if d.quotedTweetId != nil {
                    Text("引用").font(.footnote).foregroundStyle(Theme.textMuted)
                }
                Text(d.text.isEmpty ? "（只有图）" : d.text)
                    .font(.system(size: 15)).foregroundStyle(Theme.textPrimary).lineLimit(3)
                HStack(spacing: 8) {
                    if !d.imageFileNames.isEmpty {
                        Label("\(d.imageFileNames.split(separator: "|").count)", systemImage: "photo")
                    }
                    Text(TwitterStamp.short(d.updatedAt))
                }
                .font(.footnote).foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 0)
            Button { onDelete(d) } label: {
                Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(Theme.textMuted)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除草稿")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
