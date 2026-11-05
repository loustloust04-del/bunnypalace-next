import SwiftUI
import PhotosUI

// MARK: - 挑头像 + 名字卡（§11-7；小样 design-onboarding-xiaoya-v2.html C 的 avatarCard + nameCard）
// 小样里「你」是两张卡（先头像、再称呼）；粟粟加了「Ta」也要挑，合成一人一张：上半挑头像、下半挑名字，底下一行预览。
// 不想挑：头像默认第一个，名字点「先叫『你』」/「先不改名」。只交答案（头像交种子；相册的图只在内存里交出去），写楼层是剧本的事。

struct XiaoyaFaceCardView: View {
    let target: XiaoyaFaceTarget
    let answer: XiaoyaCardAnswer?
    let context: XiaoyaCardContext
    let onAnswer: (XiaoyaCardAnswer) -> Void

    @State private var batch = UInt32.random(in: 1...99_999)
    /// 选中第几个；nil = 相册那张
    @State private var selected: Int? = 0
    @State private var photo: Data?
    @State private var chips: [String] = []
    @State private var picked = ""
    @State private var custom = ""
    @State private var cropPayload: AvatarCropPayload?
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    #endif

    private var faces: [XiaoyaAvatarSeed] { GardenAvatar.batch(batch) }
    private var isUser: Bool { target == .user }
    private var name: String {
        let typed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? picked : typed
    }

    var body: some View {
        if case .face(let done) = answer {
            XiaoyaCardFrame(kicker: kicker) {
                XiaoyaCardSummary(text: XiaoyaCardAnswer.face(done).summary) { answeredAvatar(done) }
                    .padding(.top, 6)
            }
        } else {
            XiaoyaCardFrame(kicker: kicker, question: isUser ? "挑一个你的头像" : "给 Ta 挑个头像") {
                avatarGrid
                XiaoyaCardActions(topPadding: 12) {
                    Button("换一批 ↻") { batch &+= 1; selected = 0; photo = nil }
                        .buttonStyle(.xiaoya(.secondary))
                    photoButton
                }
                namePart
                preview
                XiaoyaCardActions {
                    Button(isUser ? "就叫这个" : "就这样") { submit(name) }
                        .buttonStyle(.xiaoya(.primary))
                        .disabled(name.isEmpty)
                    Button(isUser ? "先叫「你」" : "先不改名") { submit("") }
                        .buttonStyle(.xiaoya(.secondary))
                }
                XiaoyaHint("随时能在「设置 › 通用」换掉。")
            }
            .onAppear { if chips.isEmpty { reshuffleNames() } }
            .sheet(item: $cropPayload) { payload in
                AvatarCropSheet(image: payload.image) { data in
                    photo = data
                    selected = nil
                }
            }
            #if os(iOS)
            .onChange(of: photoItem) { _, item in loadPhoto(item) }
            #endif
        }
    }

    private var kicker: String { isUser ? "你" : "Ta" }

    // MARK: 头像

    private var avatarGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(Array(faces.enumerated()), id: \.offset) { i, seed in
                XiaoyaAvatarChoice(on: selected == i, delay: Double(i) * 0.045) {
                    GardenAvatarView(seed: seed, size: Self.avatarSize)
                } action: {
                    selected = i
                }
            }
            if let photo, let image = PlatformImage(data: photo) {
                XiaoyaAvatarChoice(on: selected == nil, delay: 0) {
                    Image(platformImage: image).resizable().scaledToFill()
                        .frame(width: Self.avatarSize, height: Self.avatarSize).clipShape(Circle())
                } action: {
                    selected = nil
                }
            }
        }
        .id(batch)
        .padding(.top, 2)
    }

    static var avatarSize: CGFloat {
        #if os(macOS)
        60
        #else
        72
        #endif
    }

    @ViewBuilder
    private var photoButton: some View {
        #if os(iOS)
        PhotosPicker(selection: $photoItem, matching: .images) {
            Text("从相册选…")
        }
        .buttonStyle(.xiaoya(.text))
        #else
        Button("从相册选…") { pickOnMac() }
            .buttonStyle(.xiaoya(.text))
        #endif
    }

    #if os(iOS)
    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { @MainActor in
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                cropPayload = AvatarCropPayload(image: image, target: isUser ? .user : .assistant)
            }
            photoItem = nil
        }
    }
    #else
    private func pickOnMac() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .gif, .webP]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        cropPayload = AvatarCropPayload(image: image, target: isUser ? .user : .assistant)
    }
    #endif

    // MARK: 名字

    private var namePart: some View {
        XiaoyaField(label: isUser ? "我怎么叫你？" : "Ta 叫什么？") {
            VStack(alignment: .leading, spacing: 6) {
                XiaoyaFlowRow(spacing: 6, lineSpacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        XiaoyaChip(title: chip, on: custom.isEmpty && picked == chip) {
                            custom = ""
                            picked = chip
                        }
                    }
                }
                Button("再换几个 ↻") { reshuffleNames() }
                    .buttonStyle(.xiaoya(.text))
                XiaoyaInputBox {
                    TextField(isUser ? "或者自己写，比如：粟粟" : "或者自己写，比如：阿洛", text: $custom)
                        .textFieldStyle(.plain)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(.top, 4)
    }

    /// 随机 6 个，不出小芽、不出已经有的名字（楼层里的 Ta 名 / 她的称呼）
    private func reshuffleNames() {
        let taken = Set(context.takenNames + [AssistantPrompts.assistantName])
        let pool = XiaoyaScriptLines.namePool.filter { !taken.contains($0) && !chips.contains($0) }
        let fresh = Array(pool.shuffled().prefix(6))
        chips = fresh.count == 6 ? fresh : Array(XiaoyaScriptLines.namePool.filter { !taken.contains($0) }.shuffled().prefix(6))
        if !chips.contains(picked) { picked = "" }
    }

    // MARK: 预览 + 提交

    private var preview: some View {
        XiaoyaSkinReader { skin in
            HStack(spacing: 12) {
                currentAvatar(size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name.isEmpty ? "—" : name)
                        .font(.system(size: XiaoyaCardFont.body + 0.5, weight: .semibold))
                        .foregroundStyle(skin.ink)
                    Text(isUser ? "\(AssistantPrompts.assistantName)和以后新建的 Ta 都这么叫你"
                                : "这一层的 Ta 就叫这个；我还是叫\(AssistantPrompts.assistantName)")
                        .font(.system(size: XiaoyaCardFont.hint))
                        .foregroundStyle(skin.inkMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(skin.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(skin.line, lineWidth: 1))
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private func currentAvatar(size: CGFloat) -> some View {
        if selected == nil, let photo, let image = PlatformImage(data: photo) {
            Image(platformImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
        } else {
            let seeds = faces
            GardenAvatarView(seed: seeds[min(selected ?? 0, seeds.count - 1)], size: size)
        }
    }

    @ViewBuilder
    private func answeredAvatar(_ done: XiaoyaFaceAnswer) -> some View {
        if let seed = done.avatar {
            GardenAvatarView(seed: seed, size: 30)
        } else if let data = context.avatarData(done.target), let image = PlatformImage(data: data) {
            Image(platformImage: image).resizable().scaledToFill().frame(width: 30, height: 30).clipShape(Circle())
        } else {
            XiaoyaInitialAvatar(name: done.name.isEmpty ? (isUser ? "你" : "Ta") : done.name, size: 30)
        }
    }

    private func submit(_ name: String) {
        let seeds = faces
        if selected == nil, let photo {
            onAnswer(.face(XiaoyaFaceAnswer(target: target, avatar: nil, name: name, photo: photo)))
        } else {
            onAnswer(.face(XiaoyaFaceAnswer(target: target, avatar: seeds[min(selected ?? 0, seeds.count - 1)], name: name)))
        }
    }
}

/// 一个可选头像：选中描墨圈 + 右下角 ✓；换一批时弹一下（小样 avin）
private struct XiaoyaAvatarChoice<Face: View>: View {
    let on: Bool
    let delay: Double
    @ViewBuilder let face: () -> Face
    let action: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        XiaoyaSkinReader { skin in
            Button(action: action) {
                face()
                    .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 1))
                    .padding(4)
                    .overlay(Circle().stroke(on ? skin.ink : .clear, lineWidth: 2.5))
                    .overlay(alignment: .bottomTrailing) {
                        if on {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(skin.paper)
                                .frame(width: 20, height: 20)
                                .background(skin.ink, in: Circle())
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .scaleEffect(shown ? 1 : 0.6)
            .rotationEffect(.degrees(shown ? 0 : -12))
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { shown = true; return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.62).delay(delay)) { shown = true }
            }
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}
