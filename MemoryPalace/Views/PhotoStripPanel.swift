#if os(iOS)
import SwiftUI
import Photos
import UIKit

struct PhotoStripPanel: View {
    @Binding var selectedAttachments: [PendingChatAttachment]
    @Binding var pickedAssetIds: Set<String>
    @Binding var triggerAttach: Bool

    @State private var authStatus: PHAuthorizationStatus = .notDetermined
    @State private var assets: [PHAsset] = []
    @State private var thumbnails: [String: UIImage] = [:]

    private let thumbSize: CGFloat = 80
    private let maxPhotos = 10

    @State private var showFullPicker = false
    @State private var showCamera = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
                HStack(spacing: 8) {
                    cameraCell
                    allPhotosCell

                    switch authStatus {
                    case .authorized, .limited:
                        ForEach(assets, id: \.localIdentifier) { asset in
                            photoCell(asset)
                        }
                    case .notDetermined:
                        requestAccessButton
                    default:
                        deniedPlaceholder
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .frame(height: thumbSize + 24)
        .frame(maxWidth: .infinity)
        .background {
            Color.clear
                .glassEffect(.regular.tint(Color.black.opacity(0.01)),
                             in: .rect(cornerRadii: .init(topLeading: 16, topTrailing: 16)))
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .onAppear { checkAuth() }
        .onChange(of: triggerAttach) { _, _ in
            attachSelected()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCapture { image in
                if let jpeg = image.jpegData(compressionQuality: 0.82),
                   let att = try? PendingChatAttachment.image(name: "拍照.jpg", typeDescription: "图片", mimeType: "image/jpeg", data: jpeg) {
                    selectedAttachments.append(att)
                }
            }
            .ignoresSafeArea()
            .background(Color.black)
        }
        .sheet(isPresented: $showFullPicker) {
            FullPhotosPicker(selectedAttachments: $selectedAttachments)
        }
    }

    @ViewBuilder
    private var cameraCell: some View {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showCamera = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                    Text("拍照")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                }
                .frame(width: thumbSize, height: thumbSize)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
    }

    private var allPhotosCell: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showFullPicker = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
                Text("全部照片")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
            }
            .frame(width: thumbSize, height: thumbSize)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func attachSelected() {
        let picked = assets.filter { pickedAssetIds.contains($0.localIdentifier) }
        guard !picked.isEmpty else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let targetSize = CGSize(width: 1200, height: 1200)
        for (i, asset) in picked.enumerated() {
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options
            ) { image, _ in
                guard let image, let jpeg = image.jpegData(compressionQuality: 0.82) else { return }
                DispatchQueue.main.async {
                    if let att = try? PendingChatAttachment.image(
                        name: "照片 \(i + 1).jpg", typeDescription: "图片", mimeType: "image/jpeg", data: jpeg
                    ) {
                        selectedAttachments.append(att)
                    }
                }
            }
        }
        pickedAssetIds.removeAll()
    }

    private func photoCell(_ asset: PHAsset) -> some View {
        let isSelected = pickedAssetIds.contains(asset.localIdentifier)
        return ZStack(alignment: .topTrailing) {
            Group {
                if let thumb = thumbnails[asset.localIdentifier] {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Theme.accent.opacity(0.1))
                        .overlay(ProgressView().scaleEffect(0.5))
                }
            }
            .frame(width: thumbSize, height: thumbSize)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Theme.branchIndicator : Color.clear, lineWidth: 2.5)
            )

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white, Theme.branchIndicator)
                    .offset(x: -4, y: 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if isSelected {
                pickedAssetIds.remove(asset.localIdentifier)
            } else {
                pickedAssetIds.insert(asset.localIdentifier)
            }
        }
        .task {
            guard thumbnails[asset.localIdentifier] == nil else { return }
            let size = CGSize(width: thumbSize * 2, height: thumbSize * 2)
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.isNetworkAccessAllowed = true
            opts.resizeMode = .fast
            let img = await withCheckedContinuation { cont in
                PHImageManager.default().requestImage(
                    for: asset, targetSize: size, contentMode: .aspectFill, options: opts
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if !isDegraded { cont.resume(returning: image) }
                }
            }
            if let img { thumbnails[asset.localIdentifier] = img }
        }
    }

    private var requestAccessButton: some View {
        Button {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async {
                    authStatus = status
                    if status == .authorized || status == .limited { fetchRecent() }
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 22))
                    .foregroundColor(Theme.textMuted.opacity(0.4))
                Text("允许访问相册")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
            }
            .frame(width: thumbSize * 2 + 8, height: thumbSize)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var deniedPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 22))
                .foregroundColor(Theme.textMuted.opacity(0.3))
            Text("相册权限未开启")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted.opacity(0.5))
        }
        .frame(width: thumbSize * 2 + 8, height: thumbSize)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.06)))
    }

    private func checkAuth() {
        authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authStatus == .authorized || authStatus == .limited { fetchRecent() }
    }

    private func fetchRecent() {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = maxPhotos
        let result = PHAsset.fetchAssets(with: .image, options: opts)
        var list: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
    }
}

// MARK: - Camera

struct CameraCapture: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture
        init(_ parent: CameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Full Photos Picker

import PhotosUI

struct FullPhotosPicker: View {
    @Binding var selectedAttachments: [PendingChatAttachment]
    @State private var items: [PhotosPickerItem] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PhotosPicker(selection: $items, maxSelectionCount: 10, matching: .images) {
            Text("选择照片")
        }
        .photosPickerStyle(.inline)
        .onChange(of: items) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                for (i, item) in newItems.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let jpeg = image.jpegData(compressionQuality: 0.82),
                       let att = try? PendingChatAttachment.image(name: "照片 \(i + 1).jpg", typeDescription: "图片", mimeType: "image/jpeg", data: jpeg) {
                        await MainActor.run { selectedAttachments.append(att) }
                    }
                }
                await MainActor.run {
                    items = []
                    dismiss()
                }
            }
        }
    }
}
#endif
