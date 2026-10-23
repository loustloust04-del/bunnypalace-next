#if os(iOS)
import SwiftUI
import PhotosUI

struct GroupEditSheet: View {
    let room: AgoraRoomSummary
    let viewModel: AgoraViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(GroupRoomStyle.backgroundKey) private var globalBackground = ""
    @AppStorage(GroupRoomStyle.othersKey) private var globalOthers = ""
    @AppStorage(GroupRoomStyle.mineKey) private var globalMine = ""
    @State private var name: String
    @State private var appearance: GroupAppearance
    @State private var newAvatar: Data?
    @State private var avatarItem: PhotosPickerItem?
    @State private var busy = false
    @State private var errorText: String?
    @State private var cropping: CropJob?
    @State private var loadTask: Task<Void, Never>?

    private struct CropJob: Identifiable {
        let id = UUID()
        let image: PlatformImage
    }

    init(room: AgoraRoomSummary, viewModel: AgoraViewModel) {
        self.room = room
        self.viewModel = viewModel
        _name = State(initialValue: room.floorId == viewModel.floorId ? viewModel.roomTitles[room.id] ?? "" : "")
        _appearance = State(initialValue: viewModel.appearance(for: room))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(room.title, text: $name)
                } header: {
                    VStack(spacing: 16) {
                        preview.frame(maxWidth: .infinity)
                        Text("群名").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.bottom, 10)
                }
                Section("群头像") {
                    Picker("头像类型", selection: $appearance.kind) {
                        Text("成员").tag(GroupAppearance.Kind.members)
                        Text("图片").tag(GroupAppearance.Kind.image)
                        Text("emoji").tag(GroupAppearance.Kind.emoji)
                        Text("图标").tag(GroupAppearance.Kind.symbol)
                    }
                    .pickerStyle(.segmented)
                    switch appearance.kind {
                    case .members:
                        EmptyView()
                    case .image:
                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            Label("从相册选", systemImage: "photo")
                        }
                        .disabled(busy)
                    case .emoji:
                        TextField("点这里，切到 emoji 键盘挑一个", text: $appearance.emoji)
                            .onChange(of: appearance.emoji) { _, new in
                                if new.count > 1, let last = new.last { appearance.emoji = String(last) }
                            }
                    case .symbol:
                        symbolGrid
                        colorRow
                    }
                }
                Section {
                    GroupColorSwatchRow(title: "背景", options: GroupRoomStyle.backgrounds,
                                        selection: $appearance.backgroundHex,
                                        fallback: GroupRoomStyle.background(GroupRoomStyle.stored(globalBackground)),
                                        nilName: "跟随设置")
                    GroupColorSwatchRow(title: "对方气泡", options: GroupRoomStyle.others,
                                        selection: $appearance.othersBubbleHex,
                                        fallback: GroupRoomStyle.othersColor(GroupRoomStyle.stored(globalOthers)),
                                        nilName: "跟随设置")
                    GroupColorSwatchRow(title: "我的气泡", options: GroupRoomStyle.mine,
                                        selection: $appearance.mineBubbleHex,
                                        fallback: GroupRoomStyle.mineColor(GroupRoomStyle.stored(globalMine)),
                                        nilName: "跟随设置")
                } header: {
                    Text("聊天外观")
                } footer: {
                    Text("第一格是跟随「设置 › 群聊 › 聊天外观」，选别的只改这个群。")
                }
                if busy { ProgressView("正在读取图片…") }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(Theme.danger)
                }
            }
            .navigationTitle("编辑群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { loadTask?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: save)
                        .disabled(busy || (appearance.kind == .image && newAvatar == nil && viewModel.avatarData(for: room) == nil))
                }
            }
        }
        // 「从相册选」和光标别用系统蓝
        .tint(Theme.textPrimary)
        .onChange(of: avatarItem) { _, item in load(item) }
        .onChange(of: viewModel.floorId) { _, _ in
            loadTask?.cancel()
            dismiss()
        }
        .fullScreenCover(item: $cropping) { job in
            TwitterCropSheet(image: job.image, shape: .avatar,
                             onCrop: { data in
                                 newAvatar = data
                                 cropping = nil
                             }, onCancel: { cropping = nil })
        }
        .interactiveDismissDisabled(busy)
    }

    private var avatarPreview: some View {
        GroupAvatarView(room: room, appearance: appearance,
                        imageData: newAvatar ?? viewModel.avatarData(for: room), size: 76)
    }

    @ViewBuilder
    private var preview: some View {
        if appearance.kind == .image {
            PhotosPicker(selection: $avatarItem, matching: .images) { avatarPreview }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel("换群头像")
        } else {
            avatarPreview
        }
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
            ForEach(FolderPalette.symbols, id: \.self) { name in
                Image(systemName: name)
                    .font(.system(size: 15))
                    .foregroundColor(appearance.symbol == name ? FolderPalette.color(appearance.colorHex) : Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appearance.symbol == name ? Color.clear : Color.primary.opacity(0.04))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.branchIndicator.opacity(appearance.symbol == name ? 0.6 : 0), lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { appearance.symbol = name }
            }
        }
        .padding(.vertical, 4)
    }

    private var colorRow: some View {
        HStack(spacing: 14) {
            ForEach(FolderPalette.hexes, id: \.self) { hex in
                Circle()
                    .fill(FolderPalette.color(hex))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(appearance.colorHex == hex ? 0.45 : 0), lineWidth: 2).padding(-4))
                    .contentShape(Circle())
                    .onTapGesture { appearance.colorHex = hex }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        loadTask?.cancel()
        busy = true
        errorText = nil
        loadTask = Task {
            defer {
                busy = false
                // 清掉选择，同一张图再选一次也能触发。
                avatarItem = nil
            }
            do {
                guard let raw = try await item.loadTransferable(type: Data.self) else {
                    errorText = "这张图读不出来，换一张试试。"
                    return
                }
                let shrunk = await Task.detached(priority: .userInitiated) {
                    TwitterImageShrinker.jpeg(from: raw, maxPixel: TwitterImageShrinker.postPixel)
                }.value
                guard !Task.isCancelled else { return }
                guard let shrunk, let image = PlatformImage(data: shrunk) else {
                    errorText = "这张图读不出来，换一张试试。"
                    return
                }
                cropping = CropJob(image: image)
            } catch {
                if !Task.isCancelled { errorText = "取图失败：\(error.localizedDescription)" }
            }
        }
    }

    private func save() {
        do {
            try viewModel.saveCustomization(for: room, title: name, appearance: appearance,
                                            avatar: appearance.kind == .image ? newAvatar : nil)
            dismiss()
        } catch {
            errorText = "存不上：\(error.localizedDescription)"
        }
    }
}
#endif
