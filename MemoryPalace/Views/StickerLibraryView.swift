import SwiftUI
import SwiftData

/// 右栏贴纸库 Gallery
struct StickerLibraryView: View {
    var viewModel: ConversationViewModel
    var stickerVM: StickerViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(RightPanelNavigator.self) private var desktopNavigator: RightPanelNavigator?
    @State private var desktopSticker: StickerAsset?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var showImportSheet = false
    @State private var showNoteEditor = false
    @State private var showDrawingBoard = false
    @State private var continueDrawingId: UUID?
    @State private var editingStyleAsset: StickerAsset?
    @State private var renamingAsset: StickerAsset?
    @State private var renameText = ""
    @State private var searchText = ""
    @State private var hasAppeared = false

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    private func consumeDesktopTarget() {
        guard let target = desktopNavigator?.pendingTarget, target.tool == "sticker" else { return }
        desktopNavigator?.pendingTarget = nil
        desktopSticker = stickerVM.stickerAssets.first { $0.id.uuidString == target.id && $0.profileId == profileManager?.currentProfile.id }
    }

    private var filteredAssets: [StickerAsset] {
        let assets = stickerVM.stickerAssets
        guard !searchText.isEmpty else { return assets }
        let query = searchText.lowercased()
        return assets.filter {
            $0.name.lowercased().contains(query) ||
            $0.tags.contains(where: { $0.lowercased().contains(query) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：搜索 + 操作按钮
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                    TextField("搜索贴纸...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.mainBg.opacity(0.6))
                )

                stickerActionButton("photo.badge.plus") { showImportSheet = true }
                stickerActionButton("note.text.badge.plus") { NoteEditorView.present { showNoteEditor = true } }
                stickerActionButton("paintbrush.pointed") { showDrawingBoard = true }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            if filteredAssets.isEmpty {
                emptyState
            } else {
                // Gallery 网格
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Array(filteredAssets.enumerated()), id: \.element.id) { index, asset in
                            Group {
                                if asset.isNote {
                                    NoteThumbnailView(
                                        asset: asset,
                                        index: index,
                                        hasAppeared: hasAppeared
                                    )
                                } else {
                                    StickerThumbnailView(
                                        asset: asset,
                                        profileId: profileManager?.currentProfile.id ?? "",
                                        index: index,
                                        hasAppeared: hasAppeared
                                    )
                                }
                            }
                            .onTapGesture {
                                placeStickerFromTap(asset: asset)
                            }
                            .contextMenu {
                                Button { placeStickerFromTap(asset: asset) } label: {
                                    Label("添加到对话", systemImage: "plus.circle")
                                }
                                Divider()
                                Button(action: { renameSticker(asset) }) {
                                    Label("重命名", systemImage: "pencil")
                                }
                                if asset.isNote {
                                    Button {
                                        #if os(macOS)
                                        stickerVM.saveNoteAsPNG(content: asset.noteContent ?? "", style: asset.noteStyle ?? "yellow_square")
                                        #else
                                        stickerVM.shareNoteAsPNG(content: asset.noteContent ?? "", style: asset.noteStyle ?? "yellow_square")
                                        #endif
                                    } label: {
                                        Label("导出为图片", systemImage: "square.and.arrow.up")
                                    }
                                } else {
                                    if StickerFileManager.hasDrawing(id: asset.id, profileId: asset.profileId) {
                                        Button { continueDrawingId = asset.id } label: {
                                            Label("继续画", systemImage: "paintbrush.pointed")
                                        }
                                    }
                                    Button { editingStyleAsset = asset } label: {
                                        Label("修改样式", systemImage: "paintbrush")
                                    }
                                }
                                Divider()
                                Button(role: .destructive) {
                                    stickerVM.deleteAsset(asset, context: modelContext)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(10)
                }
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { consumeDesktopTarget() }
        .onChange(of: desktopNavigator?.pendingTarget) { _, _ in consumeDesktopTarget() }
        .sheet(item: $desktopSticker) { asset in
            VStack(spacing: 20) {
                Text(asset.name).font(.title2)
                if asset.isNote { Text(asset.noteContent ?? "").padding(24) }
                else {
                    StickerThumbnailView(asset: asset, profileId: profileManager?.currentProfile.id ?? "", index: 0, hasAppeared: true)
                        .frame(width: 240, height: 280)
                }
                Button("完成") { desktopSticker = nil }
            }.padding(24)
        }
        .onAppear {
            if let pid = profileManager?.currentProfile.id {
                stickerVM.loadLibrary(profileId: pid, context: modelContext)
            }
            // 触发飘入动画
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    hasAppeared = true
                }
            }
        }
        .sheet(isPresented: $showImportSheet) {
            if let pid = profileManager?.currentProfile.id {
                StickerImportSheet(profileId: pid, stickerVM: stickerVM)
            }
        }
        .alert("重命名", isPresented: Binding(
            get: { renamingAsset != nil },
            set: { if !$0 { renamingAsset = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("确定") {
                if let asset = renamingAsset {
                    stickerVM.renameAsset(assetId: asset.id, newName: renameText, context: modelContext)
                }
                renamingAsset = nil
            }
            Button("取消", role: .cancel) { renamingAsset = nil }
        }
        .noteEditor(isPresented: $showNoteEditor, spec: BrushSettings.load().noteDefault, text: "") { text, spec in
            // 便签存入贴纸库（不直接贴画布，用户从库里拖）
            guard let pid = profileManager?.currentProfile.id else { return }
            stickerVM.createNoteAsset(content: text, style: spec.raw, profileId: pid, context: modelContext)
        }
        .drawingBoard(isPresented: $showDrawingBoard) { png, doc in
            guard let pid = profileManager?.currentProfile.id else { return }
            stickerVM.saveDrawing(png: png, document: doc, profileId: pid, context: modelContext)
        }
        .continueDrawing(assetId: $continueDrawingId, profileId: profileManager?.currentProfile.id,
                         stickerVM: stickerVM, context: modelContext)
        .sheet(item: $editingStyleAsset) { asset in
            if let pid = profileManager?.currentProfile.id {
                StickerStyleSheet(asset: asset, profileId: pid) { border, filter in
                    Task {
                        await stickerVM.updateStyle(
                            asset: asset, borderStyle: border, borderWidth: CGFloat(asset.borderWidth),
                            filterStyle: filter, profileId: pid, context: modelContext
                        )
                    }
                }
            }
        }
    }

    private func stickerActionButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textMuted)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.mainBg.opacity(0.6))
                )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            AppIconView(name: "ri-emoji-sticker", size: 32,
                        tint: Theme.textMuted.opacity(0.4))
            Text(searchText.isEmpty ? "还没有贴纸" : "没有匹配的贴纸")
                .font(.system(size: 13))
                .foregroundColor(Theme.textMuted)
            if searchText.isEmpty {
                Text("点击上方按钮导入图片")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted.opacity(0.6))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// 点击贴纸直接放到当前对话画布中央（两端；mac 面 3.3 补齐，右键「添加到对话」同一函数）
    private func placeStickerFromTap(asset: StickerAsset) {
        guard let convId = viewModel.selectedConversation?.id,
              let pid = profileManager?.currentProfile.id else { return }
        let y = max(200, CGFloat(viewModel.currentPath.count) * 50)
        if asset.isNote {
            stickerVM.placeNote(
                content: asset.noteContent ?? "", style: asset.noteStyle ?? "yellow_square",
                conversationId: convId, position: CGPoint(x: 200, y: y),
                nearestMessageId: viewModel.currentPath.first?.id,
                profileId: pid, context: modelContext
            )
        } else {
            stickerVM.placeSticker(
                assetId: asset.id, conversationId: convId,
                position: CGPoint(x: 200, y: y),
                nearestMessageId: viewModel.currentPath.first?.id,
                profileId: pid, context: modelContext
            )
        }
    }

    private func renameSticker(_ asset: StickerAsset) {
        renameText = asset.name
        renamingAsset = asset
    }

}

// MARK: - Sticker Thumbnail (Gallery Item)

struct StickerThumbnailView: View {
    let asset: StickerAsset
    let profileId: String
    let index: Int
    let hasAppeared: Bool

    @State private var thumbnailImage: Image?
    // 每个贴纸固定的微旋转角度
    private var tiltAngle: Double {
        // 基于 id 生成确定性的微旋转
        let hash = abs(asset.id.hashValue)
        return Double(hash % 11) - 5.0  // -5° 到 +5°
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let img = thumbnailImage {
                    img
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 80)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accent.opacity(0.3))
                        .frame(height: 80)
                        .overlay(
                            ProgressView()
                                .scaleEffect(0.5)
                        )
                }
            }
            Text(asset.name)
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
        }
        .rotationEffect(.degrees(hasAppeared ? tiltAngle : Double.random(in: -30...30)))
        .scaleEffect(hasAppeared ? 1.0 : 0.3)
        .opacity(hasAppeared ? 1.0 : 0)
        .offset(
            x: hasAppeared ? 0 : CGFloat.random(in: -100...100),
            y: hasAppeared ? 0 : CGFloat.random(in: -100...100)
        )
        .animation(
            .spring(response: 0.5, dampingFraction: 0.65)
                .delay(Double(index) * 0.03),
            value: hasAppeared
        )
        .onDrag {
            NSItemProvider(object: asset.id.uuidString as NSString)
        }
        .task(id: "\(asset.thumbnailPath)_\(asset.borderStyle)_\(asset.filterStyle)") { loadThumbnail() }
        .onReceive(NotificationCenter.default.publisher(for: .stickerImageUpdated)) { n in
            if n.object as? UUID == asset.id { loadThumbnail() }
        }
    }

    private func loadThumbnail() {
        DispatchQueue.global(qos: .userInitiated).async {
            if let data = StickerFileManager.loadImageCached(path: asset.thumbnailPath, profileId: profileId) {
                #if os(macOS)
                if let nsImage = NSImage(data: data) {
                    let img = Image(nsImage: nsImage)
                    DispatchQueue.main.async { thumbnailImage = img }
                }
                #else
                if let uiImage = UIImage(data: data) {
                    let img = Image(uiImage: uiImage)
                    DispatchQueue.main.async { thumbnailImage = img }
                }
                #endif
            }
        }
    }
}

// MARK: - Note Thumbnail (便签预览)

struct NoteThumbnailView: View {
    let asset: StickerAsset
    let index: Int
    let hasAppeared: Bool

    private var tiltAngle: Double {
        let hash = abs(asset.id.hashValue)
        return Double(hash % 11) - 5.0
    }

    var body: some View {
        VStack(spacing: 4) {
            NoteView(spec: NoteSpec(raw: asset.noteStyle), text: asset.noteContent ?? "", width: 168)
                .scaleEffect(0.45)
                .frame(width: 80, height: 74)
                .clipped()
                .allowsHitTesting(false)

            Text(asset.name)
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
        }
        .rotationEffect(.degrees(hasAppeared ? tiltAngle : Double.random(in: -30...30)))
            .scaleEffect(hasAppeared ? 1.0 : 0.3)
            .opacity(hasAppeared ? 1.0 : 0)
            .offset(
                x: hasAppeared ? 0 : CGFloat.random(in: -100...100),
                y: hasAppeared ? 0 : CGFloat.random(in: -100...100)
            )
            .animation(
                .spring(response: 0.5, dampingFraction: 0.65)
                    .delay(Double(index) * 0.03),
                value: hasAppeared
            )
            .onDrag {
                NSItemProvider(object: asset.id.uuidString as NSString)
            }
    }
}
