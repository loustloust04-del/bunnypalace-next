import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - GlobalExportSheet (G-D.1)
//
// 全量备份导出 sheet。
// 入口：DataSettingsTab → 「导出全局数据」按钮
// 流程：预览 stats → 用户点开始 → 后台 export → 完成显示文件路径（macOS）或 ShareLink（iOS）

struct GlobalExportSheet: View {
    /// 备份照样带有声书数据；只有粟粟的 Debug 包里有有声书，别的包文案不提（#096）
    private static var audiobookMention: String {
        #if PERSONAL_APPS
        #if DEBUG
        return "有声书、"
        #else
        return ""
        #endif
        #else
        return ""
        #endif
    }
    @Environment(\.dismiss) private var dismiss
    @Bindable var profileManager: ProfileManager

    @State private var includeMemoryTree: Bool = true
    @State private var phase: Phase = .preview
    @State private var progress = GlobalBackupProgress()
    @State private var resultURL: URL?
    @State private var errorMessage: String?

    /// 用于 fileExporter 的 binding（iOS 走 fileExporter；macOS 走 NSSavePanel）
    @State private var isPresentingFileExporter: Bool = false
    @State private var documentToExport: ExportDocument?

    enum Phase {
        case preview        // 显示统计 + 开关
        case exporting      // 进度条
        case finished       // 完成
        case failed         // 错误
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch phase {
                    case .preview:
                        previewContent
                    case .exporting:
                        exportingContent
                    case .finished:
                        finishedContent
                    case .failed:
                        failedContent
                    }
                }
                .padding(24)
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 460)
        #endif
        .background(Theme.mainBg)
        .interactiveDismissDisabled(phase == .exporting)
        #if os(iOS)
        .fileExporter(
            isPresented: $isPresentingFileExporter,
            document: documentToExport,
            contentType: .memoryPalaceBackup,
            defaultFilename: suggestedFilename()
        ) { result in
            switch result {
            case .success(let url):
                resultURL = url
                phase = .finished
            case .failure(let err):
                errorMessage = err.localizedDescription
                phase = .failed
            }
        }
        #endif
        .macEscapeToDismiss { dismiss() }   // S1-5
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("全量备份")
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
            .disabled(phase == .exporting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Preview

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("把整个记忆宫殿打包成单文件")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Text("包含所有楼层、对话、记忆、贴纸、\(Self.audiobookMention)文件库、主题。换机或备灾用。")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            }

            Toggle(isOn: $includeMemoryTree) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("一同导出 AI 记忆")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textPrimary)
                    Text("含 AI 的私密笔记。关掉则包不含 memory 子目录。")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .tint(Theme.branchIndicator)

            VStack(alignment: .leading, spacing: 4) {
                Text("不会进包")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
                Text("• API key / OAuth token / CC Bridge 配置（导入后需要重输/重连）")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
                Text("• 时间机器备份历史和跨设备同步状态（系统自动重建）")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            }

            Spacer(minLength: 10)

            Button {
                startExport()
            } label: {
                HStack {
                    Spacer()
                    Text("开始导出")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.branchIndicator))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Exporting

    private var exportingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ProgressView()
                Text("正在导出...")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
            }
            ProgressView(value: progress.overallFraction)
                .progressViewStyle(.linear)
                .tint(Theme.branchIndicator)
            Text("当前：\(displaySectionName(progress.currentSection))")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
            Text("整个过程不会动当前数据，导出完成才写出文件。请不要关闭 app。")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
        }
    }

    // MARK: - Finished

    private var finishedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Theme.branchIndicator)
                Text("导出完成")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }

            if let url = resultURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("文件位置")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                    Text(url.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }

            #if os(macOS)
            if let url = resultURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text("在 Finder 中显示")
                    }
                }
                .buttonStyle(.bordered)
            }
            #else
            if let url = resultURL {
                ShareLink(item: url) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("分享文件")
                    }
                }
            }
            #endif

            Spacer(minLength: 10)

            Button {
                dismiss()
            } label: {
                HStack {
                    Spacer()
                    Text("完成")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                .foregroundColor(Theme.textPrimary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Failed

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("导出失败")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
            }
            Text("当前数据未被改动，可以稍后重试。")
                .font(.caption)
                .foregroundColor(Theme.textMuted)

            Spacer(minLength: 10)

            HStack(spacing: 10) {
                Button {
                    phase = .preview
                    errorMessage = nil
                } label: {
                    Text("返回")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                        .foregroundColor(Theme.textPrimary)
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                } label: {
                    Text("关闭")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.5)))
                        .foregroundColor(Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Logic

    private func suggestedFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "MemoryPalace-Backup-\(f.string(from: Date())).mpb"
    }

    private func displaySectionName(_ raw: String) -> String {
        switch raw {
        case "config": return "导出设置"
        case "userdefaults": return "导出楼层和角色卡"
        case "swiftdata": return "导出对话和记忆"
        case "stickers": return "导出贴纸"
        case "audiobooks": return "导出有声书"
        case "themes": return "导出主题图"
        case "filelibrary": return "导出文件库"
        case "manifest+zip": return "打包"
        default: return raw
        }
    }

    private func startExport() {
        phase = .exporting
        let options = GlobalExporter.ExportConfig.Options(includeMemoryTree: includeMemoryTree)

        #if os(macOS)
        // macOS: NSSavePanel 选保存路径
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.memoryPalaceBackup]
        panel.nameFieldStringValue = suggestedFilename()
        panel.canCreateDirectories = true
        panel.title = "保存全量备份"
        guard panel.runModal() == .OK, let url = panel.url else {
            phase = .preview
            return
        }
        Task {
            do {
                let outURL = try await GlobalExporter.exportAll(
                    to: url,
                    profileManager: profileManager,
                    options: options,
                    progress: progress
                )
                await MainActor.run {
                    resultURL = outURL
                    phase = .finished
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    phase = .failed
                }
            }
        }
        #else
        // iOS: 先后台导出到 Caches 临时路径 → fileExporter 让用户选 location 移过去
        Task {
            do {
                let tempURL = StagingPaths.cachesRoot
                    .appendingPathComponent(suggestedFilename())
                try? FileManager.default.removeItem(at: tempURL)
                _ = try await GlobalExporter.exportAll(
                    to: tempURL,
                    profileManager: profileManager,
                    options: options,
                    progress: progress
                )
                await MainActor.run {
                    documentToExport = ExportDocument(url: tempURL)
                    isPresentingFileExporter = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    phase = .failed
                }
            }
        }
        #endif
    }
}

// MARK: - iOS .fileExporter Document Wrapper

#if os(iOS)
import UniformTypeIdentifiers

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.memoryPalaceBackup] }
    let url: URL

    init(url: URL) { self.url = url }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}
#else
// macOS 这边不用 FileDocument（走 NSSavePanel）
struct ExportDocument {
    let url: URL
}
#endif
