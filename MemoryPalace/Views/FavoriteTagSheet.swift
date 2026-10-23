import SwiftUI
import SwiftData

/// 「收藏到标签」sheet（10-02 收藏标签组）：已有 tag 做成胶囊多选，底下一个输入框新建；
/// 点「完成」= 这条标星 + 写入勾选的 tag（不选也会收藏）。已经收藏过的再点进来就是改 tag。
struct FavoriteTagSheet: View {
    let target: FavoriteTags.Target
    /// 写完之后（收藏页刷新列表用）
    var onDone: (() -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var allTags: [String] = []
    @State private var selected: Set<String> = []
    @State private var newTagName = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("收藏到标签")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Text("可以选几个；不选也会收藏")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            }

            if allTags.isEmpty {
                Text("还没有标签，在下面新建一个")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
                    .padding(.vertical, 6)
            } else if allTags.count <= 12 {
                tagFlow
            } else {
                ScrollView { tagFlow }
                    .frame(height: 200)
            }

            HStack(spacing: 8) {
                TextField("新标签名…", text: $newTagName)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .onSubmit(addNewTag)
                Button("添加", action: addNewTag)
                    .disabled(FavoriteTags.normalized(newTagName).isEmpty)
            }

            Button(action: finish) {
                Text("完成")
                    .font(.system(size: Theme.F.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.branchIndicator)

            Button("取消") { dismiss() }
                .foregroundColor(Theme.textMuted)
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 340)
        #else
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        #endif
        .onAppear(perform: load)
    }

    private var tagFlow: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(allTags, id: \.self) { tag in
                Button {
                    if selected.contains(tag) { selected.remove(tag) } else { selected.insert(tag) }
                } label: {
                    FavoriteTagChip(title: tag, on: selected.contains(tag), showsCheck: true)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let current = FavoriteTags.tags(for: target, context: modelContext)
        selected = Set(current)
        allTags = FavoriteTags.allTags(profileId: target.profileId, context: modelContext)
        for tag in current where !allTags.contains(tag) { allTags.append(tag) }
    }

    private func addNewTag() {
        let name = FavoriteTags.normalized(newTagName)
        guard !name.isEmpty else { return }
        if !allTags.contains(name) { allTags.insert(name, at: 0) }
        selected.insert(name)
        newTagName = ""
    }

    private func finish() {
        var names = allTags.filter { selected.contains($0) }
        // 输了名字没点「添加」就点完成：也算选上
        let pending = FavoriteTags.normalized(newTagName)
        if !pending.isEmpty, !names.contains(pending) { names.append(pending) }
        markFavorite()
        FavoriteTags.set(names, for: target, context: modelContext)
        ToastCenter.shared.show(names.isEmpty ? "已收藏" : "已收藏到「\(names.joined(separator: "、"))」")
        onDone?()
        dismiss()
    }

    private func markFavorite() {
        if let nid = target.nodeId {
            var desc = FetchDescriptor<MessageNode>(predicate: #Predicate<MessageNode> { $0.id == nid })
            desc.fetchLimit = 1
            if let node = try? modelContext.fetch(desc).first { node.isFavorite = true }
        } else {
            let cid = target.conversationId
            var desc = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.id == cid })
            desc.fetchLimit = 1
            if let conv = try? modelContext.fetch(desc).first { conv.isFavorite = true }
        }
    }
}

/// 收藏标签胶囊：sheet 里多选、收藏页筛选两处同一个样子（选中 = 浅薄荷底 + 描边，字仍是正文色）
struct FavoriteTagChip: View {
    let title: String
    let on: Bool
    var count: Int? = nil
    var showsCheck = false

    var body: some View {
        HStack(spacing: 4) {
            if showsCheck && on {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
            }
            Text(title)
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .foregroundColor(Theme.textMuted)
            }
        }
        .font(.system(size: Theme.F.secondary, weight: on ? .semibold : .regular))
        .foregroundColor(on ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(on ? Theme.branchIndicator.opacity(0.22) : Color.primary.opacity(0.05)))
        .overlay(Capsule().stroke(on ? Theme.branchIndicator.opacity(0.7) : Color.clear, lineWidth: 1))
        .contentShape(Capsule())
    }
}

/// 收藏页行底下的 tag 小字（#灵感 #情话）
struct FavoriteTagLine: View {
    let tags: [String]

    var body: some View {
        Text(tags.map { "#\($0)" }.joined(separator: " "))
            .font(.caption2)
            .foregroundColor(Theme.textMuted)
            .lineLimit(1)
    }
}
