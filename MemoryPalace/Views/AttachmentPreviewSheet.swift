#if os(iOS)
import SwiftUI
import UIKit
import Photos
import QuickLook

struct AttachmentPreviewSheet: View {
    let items: [BubbleAttachmentItem]
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var showSaveConfirm = false
    @State private var saveError: String?
    @State private var tempURLs: [URL] = []
    @State private var quickLookURL: URL?

    init(items: [BubbleAttachmentItem], initialIndex: Int) {
        self.items = items
        self.initialIndex = initialIndex
        self._currentIndex = State(initialValue: initialIndex)
    }

    private var isCurrentImage: Bool {
        guard currentIndex < items.count else { return false }
        if case .image = items[currentIndex] { return true }
        return false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    previewContent(item)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // 顶部渐变遮罩
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.88), .black.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 150)
                .allowsHitTesting(false)
                Spacer()
            }
            .ignoresSafeArea()

            // 按钮层
            VStack {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
                    }

                    Spacer()

                    Text("\(currentIndex + 1) / \(items.count)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .capsule)

                    Spacer()

                    Menu {
                        if isCurrentImage {
                            Button {
                                saveToPhotos()
                            } label: {
                                Label("保存到相册", systemImage: "photo.badge.arrow.down")
                            }
                        }
                        Button {
                            saveToFiles()
                        } label: {
                            Label("保存到文件", systemImage: "folder.badge.plus")
                        }
                        Button {
                            openInQuickLook()
                        } label: {
                            Label("用系统预览打开", systemImage: "eye")
                        }
                        Button {
                            shareItem()
                        } label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
                    }
                }
                .compositingGroup()
                .padding(.horizontal, 16)
                .padding(.top, 19)

                Spacer()
            }
        }
        .alert("已保存", isPresented: $showSaveConfirm) {
            Button("好") {}
        }
        .alert("保存失败", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .quickLookPreview($quickLookURL, in: tempURLs)
        .onAppear { prepareTempFiles() }
        .onDisappear { cleanupTempFiles() }
        .macEscapeToDismiss { dismiss() }   // S1-5
    }

    @ViewBuilder
    private func previewContent(_ item: BubbleAttachmentItem) -> some View {
        switch item {
        case .image(_, let data):
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        case .file(let name, let type, _):
            fileCard(name: name, type: type)
        case .fileData(let name, let mime, _):
            fileCard(name: name, type: mime)
        }
    }

    @ViewBuilder
    private func fileCard(name: String, type: String?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.5))
            Text(name)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
            if let type {
                Text(type)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
            }
            Button("用系统预览打开") { openInQuickLook() }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .capsule)
        }
    }

    private func prepareTempFiles() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preview_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURLs = items.map { item in
            switch item {
            case .image(let name, let data):
                let url = dir.appendingPathComponent(name)
                try? data.write(to: url)
                return url
            case .file(let name, _, let content):
                let url = dir.appendingPathComponent(name)
                if let content, let data = content.data(using: .utf8) {
                    try? data.write(to: url)
                }
                return url
            case .fileData(let name, _, let data):
                let url = dir.appendingPathComponent(name)
                try? data.write(to: url)   // C2：写真字节 → QuickLook/saveToFiles 拿到真文件
                return url
            }
        }
    }

    private func cleanupTempFiles() {
        if let first = tempURLs.first {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        }
    }

    private func openInQuickLook() {
        guard currentIndex < tempURLs.count else { return }
        quickLookURL = tempURLs[currentIndex]
    }

    private func saveToPhotos() {
        guard currentIndex < items.count else { return }
        if case .image(_, let data) = items[currentIndex],
           let image = UIImage(data: data) {
            // 带 completion 的保存（权限被拒/失败不再弹"已保存"假成功）
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        showSaveConfirm = true
                    } else {
                        saveError = error?.localizedDescription ?? "保存失败（检查相册权限）"
                    }
                }
            }
        }
    }

    /// 最顶层已 present 的 VC。预览 sheet 自己挂在 root 上，从 root present 会「already presenting」失败，
    /// 必须 present 到这个最顶层 VC（即预览 sheet 自己）上。
    private func topPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    private func saveToFiles() {
        guard currentIndex < tempURLs.count else { return }
        let url = tempURLs[currentIndex]
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let picker = UIDocumentPickerViewController(forExporting: [url])
        topPresenter()?.present(picker, animated: true)
    }

    private func shareItem() {
        guard currentIndex < items.count else { return }
        var shareItems: [Any] = []
        switch items[currentIndex] {
        case .image(_, let data):
            if let image = UIImage(data: data) { shareItems.append(image) }
        case .file(let name, _, _):
            shareItems.append(name)
        case .fileData:
            // 分享真文件 URL（已在 prepareTempFiles 写好真字节）
            if currentIndex < tempURLs.count { shareItems.append(tempURLs[currentIndex]) }
        }
        guard !shareItems.isEmpty else { return }
        let ac = UIActivityViewController(activityItems: shareItems, applicationActivities: nil)
        guard let presenter = topPresenter() else { return }
        // iPad：popover 需锚点，否则崩
        ac.popoverPresentationController?.sourceView = presenter.view
        ac.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        presenter.present(ac, animated: true)
    }
}
#endif
