#if os(iOS)
import SwiftUI

struct AgoraMentionInboxSheet: View {
    @Bindable var viewModel: AgoraViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var retryingIds = Set<String>()

    private let states: [AgoraMentionState] = [.pending, .claimed, .failed, .completed]

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.mentions.isEmpty {
                    ContentUnavailableView(
                        "暂无提及任务",
                        systemImage: "at",
                        description: Text("在消息里 @成员 后，处理状态会显示在这里。")
                    )
                } else {
                    List {
                        ForEach(states, id: \.rawValue) { state in
                            let items = viewModel.mentions.filter { $0.state == state }
                            if !items.isEmpty {
                                Section("\(title(for: state)) · \(items.count)") {
                                    ForEach(items) { mention in
                                        mentionRow(mention)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await viewModel.refreshMentions() }
                }
            }
            .background(Theme.mainBg)
            .navigationTitle("提及收件箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refreshMentions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新提及状态")
                }
            }
        }
        .task { await viewModel.refreshMentions() }
        .presentationBackground(Theme.mainBg)
    }

    @ViewBuilder
    private func mentionRow(_ mention: AgoraMention) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: icon(for: mention.state))
                    .foregroundStyle(color(for: mention.state))
                    .accessibilityHidden(true)
                Text("@\(mention.targetMember.handle)")
                    .font(.subheadline.weight(.semibold))
                Text(title(for: mention.state))
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text("来源 #\(mention.sourceSeq)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }

            Text(mention.sourcePreview)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)

            HStack(alignment: .firstTextBaseline) {
                Text("尝试 \(mention.attemptCount) 次")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                if let error = mention.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                }
                Spacer()
                if mention.state == .failed {
                    Button {
                        retry(mention)
                    } label: {
                        if retryingIds.contains(mention.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("重试", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(retryingIds.contains(mention.id))
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func retry(_ mention: AgoraMention) {
        guard retryingIds.insert(mention.id).inserted else { return }
        Task {
            await viewModel.retryMention(id: mention.id)
            retryingIds.remove(mention.id)
            await viewModel.refreshMentions()
        }
    }

    private func title(for state: AgoraMentionState) -> String {
        switch state {
        case .pending: "等待中"
        case .claimed: "处理中"
        case .failed: "失败"
        case .completed: "已完成"
        }
    }

    private func icon(for state: AgoraMentionState) -> String {
        switch state {
        case .pending: "clock"
        case .claimed: "ellipsis.bubble"
        case .failed: "exclamationmark.triangle"
        case .completed: "checkmark.circle"
        }
    }

    private func color(for state: AgoraMentionState) -> Color {
        switch state {
        case .pending, .claimed: Theme.branchIndicator
        case .failed: Theme.danger
        case .completed: Theme.textMuted
        }
    }
}
#endif
