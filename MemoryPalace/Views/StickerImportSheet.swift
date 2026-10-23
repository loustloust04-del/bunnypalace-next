import SwiftUI
import SwiftData
import PhotosUI

/// 贴纸导入浮窗：选图 → 命名 → 抠图 → 保存
struct StickerImportSheet: View {
    let profileId: String
    var stickerVM: StickerViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var pendingURLs: [URL] = []
    @State private var stickerName = ""
    @State private var showNaming = false
    @State private var isProcessing = false
    @State private var isDone = false
    #if os(iOS)
    @State private var selectedPhotos: [PhotosPickerItem] = []
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isProcessing {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(stickerVM.importProgress ?? "处理中...")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                } else if isDone {
                    Spacer()
                    VStack(spacing: 8) {
                        if let errorMsg = stickerVM.importProgress {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(Theme.danger)
                            Text(errorMsg)
                                .font(.system(size: Theme.F.secondary))
                                .foregroundColor(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(Theme.branchIndicator)
                            Text("导入完成！")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textPrimary)
                        }
                    }
                    Spacer()
                    .onAppear {
                        let delay: TimeInterval = stickerVM.importProgress == nil ? 1 : 3
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { dismiss() }
                    }
                } else if showNaming {
                    namingView
                } else {
                    pickView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.sidebarBg)
            .navigationTitle("导入贴纸")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
            }
        }
        #if os(macOS)
        .frame(width: 320, height: 240)
        #endif
    }

    // MARK: - Pick Step

    private var pickView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 28))
                .foregroundColor(Theme.textMuted)

            Text("选择图片，自动抠图 + 白色描边")
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textSecondary)

            #if os(macOS)
            Button(action: pickImages) {
                Text("选择图片")
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.branchIndicator))
            }
            .buttonStyle(.plain)
            #else
            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 20, matching: .images) {
                Text("选择图片")
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.branchIndicator))
            }
            .onChange(of: selectedPhotos) { _, items in
                handlePhotoSelection(items)
            }
            #endif
            Spacer()
        }
    }

    // MARK: - Naming Step

    private var namingView: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(pendingURLs.count == 1 ? "给贴纸起个名字" : "给这组贴纸命名")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textSecondary)

            if pendingURLs.count == 1 {
                Text(pendingURLs[0].deletingPathExtension().lastPathComponent)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            } else {
                Text("\(pendingURLs.count) 张图片")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }

            TextField("贴纸名称", text: $stickerName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: Theme.F.body))
                .padding(.horizontal, 30)

            HStack(spacing: 12) {
                Button("返回") {
                    showNaming = false
                    pendingURLs = []
                    stickerName = ""
                }
                .foregroundColor(Theme.textMuted)

                Button(action: startImport) {
                    Text("开始导入")
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.branchIndicator))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private func pickImages() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "选择要做成贴纸的图片"

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        pendingURLs = urls
        stickerName = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : ""
        showNaming = true
        #endif
    }

    #if os(iOS)
    private func handlePhotoSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isProcessing = true
        stickerName = ""
        Task {
            var imageDataList: [Data] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    imageDataList.append(data)
                }
            }
            guard !imageDataList.isEmpty else {
                await MainActor.run { isProcessing = false }
                return
            }
            let name = stickerName.isEmpty ? "贴纸" : stickerName
            await stickerVM.importImageData(imageDataList, name: name, profileId: profileId, context: modelContext)
            await MainActor.run {
                isProcessing = false
                isDone = true
            }
        }
    }
    #endif

    private func startImport() {
        let name = stickerName.trimmingCharacters(in: .whitespacesAndNewlines)
        isProcessing = true
        showNaming = false
        Task {
            await stickerVM.importImages(
                urls: pendingURLs,
                name: name.isEmpty ? nil : name,
                profileId: profileId,
                context: modelContext
            )
            await MainActor.run {
                isProcessing = false
                isDone = true
            }
        }
    }
}
