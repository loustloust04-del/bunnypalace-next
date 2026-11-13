import SwiftUI

// 全量备份导出页 / 导入页共用的块

/// 标题栏 + 分隔线 + 滚动区；尺寸和背景由调用方加
struct BackupSheetFrame<Content: View>: View {
    let title: String
    let closeDisabled: Bool
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .disabled(closeDisabled)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider().opacity(0.15)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { content }
                    .padding(24)
            }
        }
    }
}

struct BackupProgressBlock: View {
    let title: String
    let fraction: Double
    let section: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ProgressView()
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Theme.branchIndicator)
            Text("当前：\(section)")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
            Text(note)
                .font(.caption)
                .foregroundColor(Theme.textMuted)
        }
    }
}

struct BackupStatusTitle: View {
    let systemImage: String
    let color: Color
    let title: String

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.textPrimary)
        }
    }
}

/// 失败页：标题 + 错误原文 + 说明 + 「重来」/「关闭」
struct BackupFailedBlock: View {
    let title: String
    let error: String?
    let note: String
    let retryTitle: String
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BackupStatusTitle(systemImage: "exclamationmark.triangle.fill", color: .orange, title: title)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
            }
            Text(note)
                .font(.caption)
                .foregroundColor(Theme.textMuted)

            Spacer(minLength: 10)

            HStack(spacing: 10) {
                Button(action: onRetry) {
                    Text(retryTitle).backupButtonFace(Theme.accent, Theme.textPrimary)
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                } label: {
                    Text("关闭").backupButtonFace(Theme.accent.opacity(0.5), Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension View {
    /// 底部并排按钮的样子
    func backupButtonFace(_ fill: Color, _ foreground: Color) -> some View {
        frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .foregroundColor(foreground)
    }
}
