import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - GlobalImportSheet (G-D.2)
//
// 全量备份导入 sheet。
// 阶段：选文件 → peek 预览 → 双重确认 → staging build → 提示重启
// **主位永不被破坏**直到用户重启后 PendingImportApplier 跑 Phase 2。

struct GlobalImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .pickFile
    @State private var pickedURL: URL?
    @State private var manifest: GlobalExportManifest?
    @State private var progress = GlobalBackupProgress()
    @State private var errorMessage: String?

    @State private var isPresentingFileImporter: Bool = false
    @State private var showConfirm1: Bool = false
    @State private var showConfirm2: Bool = false

    enum Phase {
        case pickFile           // 等用户选文件
        case peeking            // 解析 manifest
        case preview            // 显示备份信息 + 双重确认
        case staging            // staging build 进度
        case finished           // 已落 flag，提示重启
        case failed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch phase {
                    case .pickFile:
                        pickFileContent
                    case .peeking:
                        peekingContent
                    case .preview:
                        previewContent
                    case .staging:
                        stagingContent
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
        .frame(width: 480, height: 520)
        #endif
        .background(Theme.mainBg)
        .interactiveDismissDisabled(phase == .staging)
        .fileImporter(
            isPresented: $isPresentingFileImporter,
            // .data 兜底 — UTI .mpb 没注册到 Info.plist 之前（G-E 阶段），
            // 系统不按扩展名识别 .mpb 文件，导致选择器禁选。
            // .data 允许任何文件；非法包靠 GlobalImporter.peek 拒绝。
            allowedContentTypes: [.memoryPalaceBackup, .zip, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                pickedURL = url
                runPeek(url: url)
            case .failure(let err):
                errorMessage = err.localizedDescription
                phase = .failed
            }
        }
        .alert("覆盖确认", isPresented: $showConfirm1) {
            Button("继续", role: .destructive) { showConfirm2 = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这将**完全覆盖**当前所有数据（对话、记忆、贴纸、文件库、设置）。继续吗？")
        }
        .alert("最后确认", isPresented: $showConfirm2) {
            Button("开始导入", role: .destructive) { runStaging() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销。导入过程中当前数据不会被改动，只在重启 app 时完成切换。")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("从备份恢复")
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
            .disabled(phase == .staging || phase == .peeking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Pick File

    private var pickFileContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选择一个 .mpb 备份文件")
                .font(.system(size: 14))
                .foregroundColor(Theme.textPrimary)
            Text("导入会覆盖当前所有数据。导入过程在临时区构建，失败时当前库不变。")
                .font(.caption)
                .foregroundColor(Theme.textMuted)

            Spacer(minLength: 10)

            Button {
                isPresentingFileImporter = true
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "folder")
                    Text("选择文件")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                .foregroundColor(Theme.textPrimary)
            }
            .buttonStyle(.plain)

            // [Bunny patch BP-004] 重签证书下文件选择器不可用：从私密链接下载进沙盒后走同一条 peek 流程
            BunnyRemoteImportRow { url in
                pickedURL = url
                runPeek(url: url)
            }
        }
    }

    // MARK: - Peeking

    private var peekingContent: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在解析备份文件...")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewContent: some View {
        if let m = manifest {
            VStack(alignment: .leading, spacing: 16) {
                Text("备份信息")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)

                VStack(alignment: .leading, spacing: 6) {
                    statsRow("导出时间", m.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    statsRow("来自设备", m.device)
                    statsRow("app 版本", "\(m.appVersion) (\(m.appBuild))")
                    statsRow("楼层数", "\(m.stats.profileCount)")
                    statsRow("对话", "\(m.stats.conversationCount) 条 / \(m.stats.messageNodeCount) 节点")
                    statsRow("记忆", "\(m.stats.memoryNoteCount) 笔记 / \(m.stats.memoryCount) 原子档案")
                    statsRow("贴纸", "\(m.stats.stickerAssetCount) 张 / \(formatBytes(m.stats.stickerAssetBytes))")
                    statsRow("有声书", "\(m.stats.audiobookCount) 本 / \(formatBytes(m.stats.audiobookFileBytes))")
                    statsRow("文件库", "\(m.stats.filesystemFileCount) 文件")
                    statsRow("AI 记忆树", m.includes.memoryTree ? "已包含" : "未包含")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.4)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("⚠️ 导入会完全覆盖当前所有数据")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("导入过程使用临时区，构建失败时当前库不变。staging 成功后必须重启 app 完成切换。重启之前当前数据仍然完整。")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }

                Spacer(minLength: 10)

                HStack(spacing: 10) {
                    Button {
                        pickedURL = nil
                        manifest = nil
                        phase = .pickFile
                    } label: {
                        Text("换文件")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                            .foregroundColor(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showConfirm1 = true
                    } label: {
                        Text("开始导入")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func statsRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundColor(Theme.textMuted)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
    }

    // MARK: - Staging

    private var stagingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ProgressView()
                Text("正在构建导入数据...")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
            }
            ProgressView(value: progress.overallFraction)
                .progressViewStyle(.linear)
                .tint(Theme.branchIndicator)
            Text("当前：\(displaySectionName(progress.currentSection))")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
            Text("当前数据未被改动。此阶段完成后会要求重启 app 完成切换。")
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
                Text("导入数据已就绪")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }

            Text("staging 已写好，主位数据未动。需要重启 app 才能完成切换。")
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
            Text("重启后 app 会在启动时自动完成 Phase 2（约 5-30 秒）。如果中途崩了 / 拔电，下次启动会接着完成；任何时候可以选择「放弃恢复原状」。")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
            Text("恢复完成后，此前的云端同步缓存不再导入；新的同步以本机数据为起点。")
                .font(.caption)
                .foregroundColor(Theme.textMuted)

            Spacer(minLength: 10)

            #if os(macOS)
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Spacer()
                    Text("立即重启 app")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.branchIndicator))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            #else
            VStack(spacing: 10) {
                Text("请从 App Switcher（上滑屏幕底部）退出 app，然后重新打开。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))

                Button {
                    dismiss()
                } label: {
                    Text("我知道了")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.branchIndicator))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            #endif
        }
    }

    // MARK: - Failed

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("导入失败")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
            }
            Text("当前数据未被改动。可以稍后重试或换一个文件。")
                .font(.caption)
                .foregroundColor(Theme.textMuted)

            Spacer(minLength: 10)

            HStack(spacing: 10) {
                Button {
                    pickedURL = nil
                    manifest = nil
                    errorMessage = nil
                    phase = .pickFile
                } label: {
                    Text("重选文件")
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

    private func runPeek(url: URL) {
        phase = .peeking
        Task.detached {
            // 获取 security-scoped URL（iOS 选择文件库外文件需要）
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                let m = try GlobalImporter.peek(at: url)
                await MainActor.run {
                    self.manifest = m
                    self.phase = .preview
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.phase = .failed
                }
            }
        }
    }

    private func runStaging() {
        guard let url = pickedURL else { return }
        phase = .staging
        Task {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try await GlobalImporter.runStaging(from: url, progress: progress)
                await MainActor.run {
                    phase = .finished
                }
            } catch {
                await MainActor.run {
                    GlobalImporter.rollback(workspace: nil)
                    errorMessage = error.localizedDescription
                    phase = .failed
                }
            }
        }
    }

    private func displaySectionName(_ raw: String) -> String {
        switch raw {
        case "validate": return "校验包完整性"
        case "swiftdata": return "构建对话和记忆"
        case "userdefaults": return "准备楼层和设置"
        case "stickers": return "准备贴纸"
        case "audiobooks": return "准备有声书"
        case "themes": return "准备主题"
        case "filelibrary": return "准备文件库"
        default: return raw.isEmpty ? "准备中" : raw
        }
    }

    private func formatBytes(_ b: Int) -> String {
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
        return String(format: "%.1f MB", Double(b) / 1024 / 1024)
    }
}
