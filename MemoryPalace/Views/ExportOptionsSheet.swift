import SwiftUI
import SwiftData

struct ExportOptionsSheet: View {
    let conversation: Conversation
    var viewModel: ConversationViewModel
    let userName: String
    let assistantName: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: ExportPathMode = .longest
    @State private var exportError: String?

    /// Whether the conversation is currently loaded in the ViewModel
    private var isConversationLoaded: Bool {
        viewModel.selectedConversation?.id == conversation.id && !viewModel.currentPath.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("导出选项")
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            Text(conversation.title)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)

            VStack(spacing: 4) {
                exportOption(
                    title: "最长分支",
                    description: "自动选择最长的对话路径",
                    mode: .longest
                )

                if isConversationLoaded {
                    exportOption(
                        title: "当前显示路径",
                        description: "导出当前正在查看的路径",
                        mode: .current
                    )
                }

                exportOption(
                    title: "主路径",
                    description: "导出 ChatGPT 默认的主路径",
                    mode: .mainPath
                )

                exportOption(
                    title: "完整树",
                    description: "所有分支，非主线用折叠显示",
                    mode: .fullTree
                )
            }

            HStack {
                Button("取消") { dismiss() }
                    .foregroundColor(Theme.textMuted)
                    .buttonStyle(.plain)

                Spacer()

                Button(action: { performExport() }) {
                    Text("导出")
                        .font(.system(size: Theme.F.secondary, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Theme.branchIndicator)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 320)
        .alert("导出失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func exportOption(title: String, description: String, mode: ExportPathMode) -> some View {
        Button(action: { selectedMode = mode }) {
            HStack(spacing: 8) {
                Image(systemName: selectedMode == mode ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(selectedMode == mode ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)
                    Text(description)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedMode == mode ? Theme.accent.opacity(0.4) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func performExport() {
        let markdown: String

        if selectedMode == .current && isConversationLoaded {
            // Use ViewModel's loaded data for current path
            markdown = viewModel.exportMarkdown(
                mode: .current,
                userName: userName,
                assistantName: assistantName
            )
        } else if (selectedMode == .mainPath || selectedMode == .longest || selectedMode == .fullTree) && isConversationLoaded {
            // Can use ViewModel data for these too
            markdown = viewModel.exportMarkdown(
                mode: selectedMode,
                userName: userName,
                assistantName: assistantName
            )
        } else {
            // Load from context (conversation not displayed)
            markdown = MarkdownExporter.loadAndExport(
                conversation: conversation,
                context: modelContext,
                mode: selectedMode,
                userName: userName,
                assistantName: assistantName
            )
        }

        // Save file（失败必须可见——写盘失败照样 dismiss 是"假成功"，R-B4/P1-19）
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "导出 Markdown"
        panel.nameFieldStringValue = "\(MarkdownExporter.sanitizedFileName(conversation.title)).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            dismiss()
        } catch {
            exportError = "写入失败：\(error.localizedDescription)"
        }
        #else
        // iOS: 写 tmp 后走系统分享面板（原先写完 tmp 就结束，导出是黑洞）
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(MarkdownExporter.sanitizedFileName(conversation.title)).md")
        do {
            try markdown.write(to: tmpURL, atomically: true, encoding: .utf8)
        } catch {
            exportError = "写入失败：\(error.localizedDescription)"
            return
        }
        let activityVC = UIActivityViewController(activityItems: [tmpURL], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            var presenter = root
            while let presented = presenter.presentedViewController { presenter = presented }
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            }
            presenter.present(activityVC, animated: true)
        }
        #endif
    }
}
