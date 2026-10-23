import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Sticker Settings Page

/// 设置 · 贴纸：贴纸库统计 + 画笔（画板的笔 / 颜色 / 纸）+ 贴纸包导入导出。
///
/// 一份 body 两端共用（plan-settings-merge-x 刀 3）：容器走 `SettingsSectionList(.list)`，字号走 `settingsMetrics`；
/// 只剩两处系统能力分支（第 4 类）——导出落地 `NSSavePanel` vs 分享面板、导入选文件 `NSOpenPanel` vs `.fileImporter`。
struct StickerPage: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m

    @State private var stickerAssetCount: Int = 0
    @State private var placedStickerCount: Int = 0
    @State private var stickerDiskUsage: String = ""
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showFileImporter = false
    @State private var statusMessage: String? = nil

    var body: some View {
        SettingsSectionList(.list) {
            Section("贴纸库") {
                HStack(spacing: 20) {
                    stickerStat("贴纸资产", value: "\(stickerAssetCount)")
                    stickerStat("已贴数量", value: "\(placedStickerCount)")
                    stickerStat("磁盘占用", value: stickerDiskUsage)
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            BrushSettingsSection()
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

            Section("贴纸数据") {
                Text("导出包含贴纸资产（图片+描边）和画布布局（位置/旋转/缩放）。导入后贴纸归位。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)

                HStack(spacing: 12) {
                    // 两颗钮的皮在原语层分叉：iOS 胶囊原样，mac 灰底 chip（🎩 裁：保 J2 口径，页里不堆 #if）
                    Button(action: exportPack) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                                .font(m.caption)
                            Text(isExporting ? "导出中..." : "导出贴纸包")
                                .font(m.secondary.weight(.medium))
                        }
                        .settingsCapsuleLabel(filled: true)
                    }
                    .settingsActionButton()
                    .disabled(isExporting)

                    Button(action: beginImport) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down")
                                .font(m.caption)
                            Text(isImporting ? "导入中..." : "导入贴纸包")
                                .font(m.secondary.weight(.medium))
                        }
                        .settingsCapsuleLabel(filled: false)
                    }
                    .settingsActionButton()
                    .disabled(isImporting)
                }

                if let msg = statusMessage {
                    Text(msg)
                        .font(m.caption)
                        .foregroundColor(Theme.branchIndicator)
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("贴纸")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { loadStats() }
        #if os(iOS)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "stickerpack") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            importPack(result: result)
        }
        #endif
    }

    private func stickerStat(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(m.sectionHeader)
                .foregroundColor(Theme.textPrimary)
            Text(label)
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
    }

    private func loadStats() {
        guard let pid = profileManager?.currentProfile.id else { return }
        let pidCopy = pid

        let assetDesc = FetchDescriptor<StickerAsset>(
            predicate: #Predicate<StickerAsset> { a in a.profileId == pidCopy }
        )
        stickerAssetCount = (try? modelContext.fetch(assetDesc))?.count ?? 0

        let placedDesc = FetchDescriptor<PlacedSticker>(
            predicate: #Predicate<PlacedSticker> { s in s.profileId == pidCopy }
        )
        placedStickerCount = (try? modelContext.fetch(placedDesc))?.count ?? 0

        let dir = StickerFileManager.stickerDirectory(profileId: pid)
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            let totalBytes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
            if totalBytes < 1024 * 1024 {
                stickerDiskUsage = "\(totalBytes / 1024) KB"
            } else {
                stickerDiskUsage = String(format: "%.1f MB", Double(totalBytes) / 1024 / 1024)
            }
        } else {
            stickerDiskUsage = "0 KB"
        }
    }

    private func exportPack() {
        guard let pid = profileManager?.currentProfile.id else { return }
        isExporting = true
        statusMessage = nil
        Task {
            do {
                let url = try await StickerPackExporter.export(profileId: pid, context: modelContext)
                await MainActor.run {
                    isExporting = false
                    #if os(macOS)
                    let panel = NSSavePanel()
                    panel.allowsOtherFileTypes = true
                    panel.nameFieldStringValue = "贴纸包.stickerpack"
                    if panel.runModal() == .OK, let dest = panel.url {
                        do {
                            // 面板已确认覆盖意图，同名先删再移（moveItem 不覆盖）
                            if FileManager.default.fileExists(atPath: dest.path) {
                                try FileManager.default.removeItem(at: dest)
                            }
                            try FileManager.default.moveItem(at: url, to: dest)
                            statusMessage = "导出成功！"
                        } catch {
                            statusMessage = "导出失败：\(error.localizedDescription)"
                        }
                    }
                    #else
                    // iOS 分享面板
                    let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let root = scene.windows.first?.rootViewController {
                        if let popover = activityVC.popoverPresentationController {
                            popover.sourceView = root.view
                            popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
                        }
                        root.present(activityVC, animated: true)
                    }
                    #endif
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    statusMessage = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 选文件：mac 同步开 `NSOpenPanel`，iOS 亮 `.fileImporter`；选中后两端汇进同一个 `importPack(result:)`
    private func beginImport() {
        #if os(macOS)
        // 楼层 ID 在开面板前冻结（合流前就是这个时序；模态期间切了楼层也导进原来那层）
        guard let pid = profileManager?.currentProfile.id else { return }
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.message = "选择贴纸包文件（.stickerpack）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importPack(result: .success([url]), profileId: pid)
        #else
        showFileImporter = true
        #endif
    }

    private func importPack(result: Result<[URL], Error>, profileId: String? = nil) {
        guard let pid = profileId ?? profileManager?.currentProfile.id else { return }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            statusMessage = nil
            Task {
                do {
                    let counts = try await StickerPackImporter.importPack(url: url, profileId: pid, context: modelContext)
                    await MainActor.run {
                        isImporting = false
                        statusMessage = "导入成功！\(counts.assets) 个贴纸，\(counts.placements) 个布局"
                        loadStats()
                    }
                } catch {
                    await MainActor.run {
                        isImporting = false
                        statusMessage = "导入失败：\(error.localizedDescription)"
                    }
                }
            }
        case .failure(let error):
            statusMessage = "选择文件失败：\(error.localizedDescription)"
        }
    }
}
