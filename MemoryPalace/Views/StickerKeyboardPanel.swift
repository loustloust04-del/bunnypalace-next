import SwiftUI
import SwiftData
import PhotosUI

/// 「+」/ 贴纸面板 — 工具栏胶囊 + 玻璃卡片。iOS 像键盘一样贴底（overlay）；mac 面 4.1 跨端后顶替输入条，同一套。
/// iOS 独有：相册 strip（PHAsset）、触觉、sheet detents；mac 独有：系统 PhotosPicker、右栏「贴纸库」颗（⧫12）。
struct StickerKeyboardPanel: View {
    var stickerVM: StickerViewModel
    var viewModel: ConversationViewModel
    var showCard: Bool = true
    var onDismiss: () -> Void
    var onStickerTap: (() -> Void)? = nil
    @Binding var selectedAttachments: [PendingChatAttachment]
    /// 📞 打电话（plan-voice-note M6，iOS）：nil = 不出这颗（mac 通话本来就是 iOS-only）
    var onCallStart: (() -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var showNoteEditor = false
    @State private var showTodoComposer = false   // ➕ 新建待办卡片（research-chat-cards §4.6）
    @State private var showDiceComposer = false   // ➕ 新建骰子卡片（§8.1）
    @State private var showTimerComposer = false  // ➕ 新建计时器卡片（§8.2）
    @State private var showDrawingBoard = false
    @State private var showAttachmentImporter = false
    @State private var attachmentError: String?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pickedAssetIds: Set<String> = []
    @State private var triggerAttach: Bool = false
    @State private var showPhotoStrip: Bool = true
    /// 📎：最近文件横条（plan-input-file-mention；不再直接弹系统文件单）
    @State private var showFileStrip = false
    @State private var pickedFilePaths: [String] = []
    @State private var showLibraryPicker = false
    @State private var panelHeight: CGFloat = 260
    @State private var dragOffset: CGFloat = 0
    @State private var showStylePicker = false
    @Bindable private var styleManager = StyleManager.shared

    private let minHeight: CGFloat = 160

    /// 贴纸网格是否显示：文件条开着时让位（mac 宿主 showCard 恒真，靠这条切换）
    private var cardVisible: Bool { showCard && !showFileStrip }
    private let maxHeight: CGFloat = 420

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    var body: some View {
        VStack(spacing: 12) {
            // 工具栏（和输入框同款 rect 玻璃）
            HStack(spacing: 0) {
                // 键盘按钮（左侧）
                Button(action: onDismiss) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                #if os(macOS)
                .buttonStyle(.plain)   // mac 默认按钮样式画灰底方块（粟粟走查 5），44pt 点击区靠 contentShape 保留
                #endif

                // 工具图标横向滚动（卡片入口加多后一行放不下，不能把右边的「附加 / 完成」挤出去）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        #if os(iOS)
                        toolButton("photo", isActive: !showCard && showPhotoStrip) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if showCard {
                                    onStickerTap?()
                                    showPhotoStrip = true
                                } else {
                                    showPhotoStrip.toggle()
                                }
                                if showPhotoStrip {
                                    showFileStrip = false
                                    pickedFilePaths.removeAll()
                                }
                            }
                        }
                        #else
                        // mac 没有 PhotoStripPanel（PHAsset）：相册走系统 PhotosPicker，失败汇总弹「附件读取失败」（面 4.1a，R7 B1）
                        PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 6, matching: .images) {
                            toolIcon("photo")
                        }
                        .buttonStyle(.plain)
                        .help("从相册添加图片")
                        #endif

                        toolButton("paperclip", isActive: showFileStrip) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                #if os(iOS)
                                if showCard {
                                    onStickerTap?()
                                    showFileStrip = true
                                } else {
                                    showFileStrip.toggle()
                                }
                                #else
                                // mac 宿主不传 showCard（贴纸网格常显）：文件条打开时网格让位（cardVisible），不碰贴纸状态
                                showFileStrip.toggle()
                                #endif
                                if showFileStrip {
                                    showPhotoStrip = false
                                    pickedAssetIds.removeAll()
                                } else {
                                    pickedFilePaths.removeAll()
                                }
                            }
                        }
                        .accessibilityIdentifier("panel-paperclip")
                        #if os(iOS)
                        // 第三颗：打电话（收起面板 → 通话页，原输入框长按 waveform 拨号已删）
                        if let onCallStart {
                            toolButton("phone") { onCallStart() }
                                .accessibilityLabel("打电话")
                        }
                        #endif
                        toolButton("square.fill.on.circle.fill", isActive: cardVisible) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showPhotoStrip = false
                                showFileStrip = false
                                pickedFilePaths.removeAll()
                                onStickerTap?()
                            }
                        }
                        #if os(macOS)
                        // 打开右栏「贴纸」工具（导入 / 重命名 / 管理在那边；⧫12，mac 独有一颗——iOS 面板网格只拖拽）
                        toolButton("square.grid.2x2") {
                            NotificationCenter.default.post(name: .showStickerLibrary, object: nil)
                        }
                        .help("贴纸库")
                        #endif
                        toolButton("note.text.badge.plus") { NoteEditorView.present { showNoteEditor = true } }
                            .accessibilityLabel("便利贴")
                        #if os(iOS)
                        toolButton("checklist") { showTodoComposer = true }
                        toolButton("dice") { showDiceComposer = true }
                        toolButton("timer") { showTimerComposer = true }
                        #endif
                        toolButton("paintbrush.pointed") { showDrawingBoard = true }
                            .accessibilityLabel("画画")
                        toolButton("sparkles", isActive: !(viewModel.selectedConversation?.currentStyleId.isEmpty ?? true)) {
                            showStylePicker = true
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

                if !pickedFilePaths.isEmpty {
                    Button(action: {
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        let paths = pickedFilePaths
                        pickedFilePaths.removeAll()
                        attachLibraryFiles(paths)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 10, weight: .semibold))
                            Text("附加 \(pickedFilePaths.count) 个")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.branchIndicator))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("file-strip-attach")
                    .padding(.trailing, 4)
                } else if !pickedAssetIds.isEmpty {
                    // 选了图片就显示「附加」——独立于贴纸编辑模式，否则选了加不进
                    Button(action: {
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        triggerAttach.toggle()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 10, weight: .semibold))
                            Text("附加 \(pickedAssetIds.count) 张")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.branchIndicator))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                } else if stickerVM.isEditingStickers {
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            stickerVM.isEditingStickers = false
                            stickerVM.selectedPlacedStickerId = nil
                            pickedAssetIds.removeAll()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                            Text("完成")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.branchIndicator))
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .keyboardShortcut(.cancelAction)   // L4c：Esc 退出贴纸编辑模式
                    #endif
                    .padding(.trailing, 4)
                }
            }
            .frame(height: 44)                                            // 固定一行高
            .padding(.horizontal, 4)
            #if os(iOS)
            .glassEffect(.regular.tint(Color.black.opacity(0.01)).interactive(), in: .rect(cornerRadius: 20))
            #else
            .shellGlass(in: .rect(cornerRadius: 20), tint: 0.15, interactive: true)
            #endif
            .padding(.horizontal, 16)

            // 玻璃卡片（像键盘贴底，顶部圆角底部直角，延伸到屏幕底边）
            // 始终在 layout 里，用高度动画收起（避免 if 移除导致工具栏穿模跳动）
            VStack(spacing: 0) {
                // 拖拽条（真的可拖）
                Capsule()
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragOffset = value.translation.height
                            }
                            .onEnded { value in
                                panelHeight = max(minHeight, min(maxHeight, panelHeight - dragOffset))
                                dragOffset = 0
                            }
                    )

                // 贴纸网格
                if stickerVM.stickerAssets.isEmpty {
                    VStack(spacing: 6) {
                        AppIconView(name: "ri-emoji-sticker", size: 24,
                                    tint: Theme.textMuted.opacity(0.3))
                        Text("还没有贴纸")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(stickerVM.stickerAssets, id: \.id) { asset in
                                PanelStickerCell(asset: asset, profileId: profileManager?.currentProfile.id ?? "")
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                    }
                }
            }
            .frame(height: cardVisible ? max(minHeight, min(maxHeight, panelHeight - dragOffset)) : 0)
            .frame(maxWidth: .infinity)
            .clipped()
            .opacity(cardVisible ? 1 : 0)
            .background {
                if cardVisible {
                    #if os(iOS)
                    Color.clear
                        .glassEffect(.regular.tint(Color.black.opacity(0.01)).interactive(),
                                     in: .rect(cornerRadii: .init(topLeading: 16, topTrailing: 16)))
                        .ignoresSafeArea(.container, edges: .bottom)
                    #else
                    Color.clear
                        .shellGlass(in: .rect(cornerRadii: .init(topLeading: 16, topTrailing: 16)), tint: 0.15, interactive: true)
                    #endif
                }
            }

            #if os(iOS)
            if !showCard && showPhotoStrip {
                PhotoStripPanel(selectedAttachments: $selectedAttachments, pickedAssetIds: $pickedAssetIds, triggerAttach: $triggerAttach)
            }
            #endif
            if showFileStrip, let pid = profileManager?.currentProfile.id {
                FileStripPanel(profileId: pid, pickedPaths: $pickedFilePaths,
                               onOpenLibrary: { showLibraryPicker = true },
                               onOpenSystemFiles: { showAttachmentImporter = true })
            }
        }
        // 与输入条同宽同轴：输入条已夹到 contentMaxWidth，面板若还满宽就会跟它错位
        // （面板是从输入条弹出来的，视觉上得对齐）
        .frame(maxWidth: Theme.contentMaxWidth)
        .onAppear {
            if let pid = profileManager?.currentProfile.id {
                stickerVM.loadLibrary(profileId: pid, context: modelContext)
            }
        }
        .noteEditor(isPresented: $showNoteEditor, spec: BrushSettings.load().noteDefault, text: "") { text, spec in
            placeNewNote(text, spec)
        }
        #if os(iOS)
        .sheet(isPresented: $showTodoComposer) {
            TodoCardComposer(takenIds: Set(viewModel.cardIndex.keys)) { card in
                selectedAttachments = ConversationViewModel.staging(.todo(card), into: selectedAttachments)
            }
        }
        .sheet(isPresented: $showDiceComposer) {
            DiceCardComposer(takenIds: Set(viewModel.cardIndex.keys)) { card in
                selectedAttachments = ConversationViewModel.staging(.dice(card), into: selectedAttachments)
            }
        }
        .sheet(isPresented: $showTimerComposer) {
            TimerCardComposer(takenIds: Set(viewModel.cardIndex.keys)) { card in
                selectedAttachments = ConversationViewModel.staging(.timer(card), into: selectedAttachments)
            }
        }
        #endif
        .drawingBoard(isPresented: $showDrawingBoard) { png, doc in
            guard let pid = profileManager?.currentProfile.id else { return }
            stickerVM.saveDrawing(png: png, document: doc, profileId: pid, context: modelContext)
        }
        .sheet(isPresented: $showLibraryPicker) {
            if let pid = profileManager?.currentProfile.id {
                FileLibraryPickerSheet(profileId: pid) { attachLibraryFiles($0) }
            }
        }
        .sheet(isPresented: $showStylePicker) {
            StyleManagerView(viewModel: viewModel, manager: styleManager)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
        }
        .onChange(of: selectedPhotoItems) { _, items in
            handlePhotoSelection(items)
        }
        .fileImporter(
            isPresented: $showAttachmentImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true,
            onCompletion: handleAttachmentImport
        )
        .alert("附件读取失败", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("好") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
    }

    /// 新便利贴直接贴到对话里最新那条消息旁边（粟粟 10-11「难编辑」：不再先进库再拖）；没开对话就进贴纸库
    private func placeNewNote(_ text: String, _ spec: NoteSpec) {
        guard let pid = profileManager?.currentProfile.id else { return }
        guard let convId = viewModel.selectedConversation?.id, let last = viewModel.currentPath.last,
              let y = stickerVM.bubblePositions[last.id] else {
            stickerVM.createNoteAsset(content: text, style: spec.raw, profileId: pid, context: modelContext)
            return
        }
        stickerVM.placeNote(content: text, style: spec.raw, conversationId: convId,
                            position: CGPoint(x: 150 + CGFloat.random(in: -30...30), y: y),
                            nearestMessageId: last.id, profileId: pid, context: modelContext)
    }

    private func handleAttachmentImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var imported: [PendingChatAttachment] = []
            var failures: [String] = []
            for url in urls {
                do {
                    imported.append(try AttachmentTextExtractor.extract(from: url))
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            selectedAttachments.append(contentsOf: imported)
            if !failures.isEmpty {
                attachmentError = failures.joined(separator: "\n")
            }
        case .failure(let error):
            attachmentError = error.localizedDescription
        }
    }

    /// 文件库文件 → 附件（和系统文件单同一条抽取，后台读；失败汇总进同一个 alert）
    private func attachLibraryFiles(_ paths: [String]) {
        guard !paths.isEmpty, let pid = profileManager?.currentProfile.id else { return }
        let key = FileMention.composerKey(viewModel)
        Task {
            let r = await FileMention.attach(paths: paths, profileId: pid)
            guard FileMention.composerKey(viewModel) == key else {
                ToastCenter.shared.show("换了对话，文件没加上")
                return
            }
            selectedAttachments.append(contentsOf: r.attachments)
            if !r.failures.isEmpty { attachmentError = r.failures.joined(separator: "\n") }
        }
    }

    /// 系统 PhotosPicker 的回流（mac 相册颗；iOS 相册走 PhotoStripPanel，这条不触发）：失败逐张汇总弹出，不静默丢
    private func handlePhotoSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            let result = await PhotoAttachmentImporter.attachments(from: items)
            await MainActor.run {
                selectedAttachments.append(contentsOf: result.imported)
                selectedPhotoItems = []
                if !result.failures.isEmpty {
                    attachmentError = result.failures.joined(separator: "\n")
                }
            }
        }
    }

    private func toolButton(_ icon: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolIcon(icon, isActive: isActive) }
            #if os(macOS)
            .buttonStyle(.plain)   // 同走查 5：mac 默认样式灰底方块，只留图标
            #endif
    }

    private func toolIcon(_ icon: String, isActive: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(isActive ? Theme.branchIndicator : Theme.textSecondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - Panel Sticker Cell（可拖拽）

struct PanelStickerCell: View {
    let asset: StickerAsset
    let profileId: String
    @State private var image: Image?

    var body: some View {
        Group {
            if asset.isNote {
                NoteView(spec: NoteSpec(raw: asset.noteStyle), text: asset.noteContent ?? "", width: 168)
                    .scaleEffect(0.4)
                    .frame(width: 68, height: 62)
                    .clipped()
                    .allowsHitTesting(false)
            } else if let img = image {
                img.resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 65)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accent.opacity(0.15))
                    .frame(height: 55)
                    .overlay(ProgressView().scaleEffect(0.4))
            }
        }
        .onDrag { NSItemProvider(object: asset.id.uuidString as NSString) }
        .task { if image == nil { load() } }
        .onReceive(NotificationCenter.default.publisher(for: .stickerImageUpdated)) { n in
            if n.object as? UUID == asset.id { load() }
        }
    }

    private func load() {
        guard !asset.isNote else { return }
        if let data = StickerFileManager.loadImageCached(path: asset.thumbnailPath, profileId: profileId),
           let platformImage = PlatformImage(data: data) {
            image = Image(platformImage: platformImage)
        }
    }
}

extension Notification.Name {
    /// 打开右栏「贴纸」工具（ContentView 消费）；原声明在已退役的 StickerToolbar（面 4.2）
    static let showStickerLibrary = Notification.Name("showStickerLibrary")
}
