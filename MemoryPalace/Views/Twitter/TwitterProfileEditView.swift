import SwiftUI
import SwiftData
import PhotosUI

/// 编辑个人资料。照推特的编辑页：横幅和头像上各一个相机钮，下面四个字段带字数。
struct TwitterProfileEditView: View {
    let profileId: String
    let account: TwitterArchiveAccount?
    let mediaDir: URL
    let accent: Color
    let onDone: () -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var draft = TwitterProfileDraft(displayName: "", screenName: "", bio: "",
                                                   location: "", website: "")
    @State private var avatarItem: PhotosPickerItem?
    @State private var bannerItem: PhotosPickerItem?
    /// 已选、已压缩、还没存的图。存之前只在这里预览
    @State private var newAvatar: Data?
    @State private var newBanner: Data?
    @State private var dropBanner = false
    @State private var busy = false
    /// 选完图等着取景的那张（粟粟 2026-09-24：要能拖动、缩放取景）
    @State private var cropping: CropJob?

    private struct CropJob: Identifiable {
        let id = UUID()
        let image: PlatformImage
        let shape: TwitterCropSheet.Shape
    }
    @State private var errorText: String?
    @State private var confirmingRestore = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    bannerEditor
                    avatarEditor
                        .offset(y: -36)
                        .padding(.leading, 16)
                        .padding(.bottom, -24)
                        .zIndex(1)
                    VStack(spacing: 0) {
                        field("名字", text: $draft.displayName, limit: TwitterProfileEditor.Limit.name)
                        field("用户名", text: $draft.screenName, limit: 15, prefix: "@")
                        field("简介", text: $draft.bio, limit: TwitterProfileEditor.Limit.bio, multiline: true)
                        field("位置", text: $draft.location, limit: TwitterProfileEditor.Limit.location)
                        field("网站", text: $draft.website, limit: TwitterProfileEditor.Limit.website)
                    }
                    if TwitterProfileEditor.canRestoreFromArchive(profileId: profileId, context: modelContext) {
                        // 改乱了、或者被旧的手改挡住了存档资料，一键回到存档原样
                        Button("恢复成存档里的资料") { confirmingRestore = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 15))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 16)
                            .padding(.top, 20)
                    }
                    if let errorText {
                        Text(errorText).font(.footnote).foregroundStyle(Theme.danger).padding(16)
                    }
                }
            }
        }
        .frame(minWidth: 340, minHeight: 520)
        .background(Theme.mainBg)
        .onAppear { draft = TwitterProfileEditor.load(profileId: profileId, context: modelContext) }
        .confirmationDialog("恢复成存档里的资料？", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("恢复") {
                do {
                    try TwitterProfileEditor.restoreFromArchive(profileId: profileId, context: modelContext)
                    TwitterHaptics.success()
                    onDone()
                } catch { errorText = "恢复不了：\(error.localizedDescription)" }
            }
        } message: {
            Text("名字、用户名、简介、位置、网站、头像、横幅都换回最近一次导入的存档里的样子。")
        }
        .onChange(of: avatarItem) { _, item in
            load(item, shape: .avatar)
        }
        .onChange(of: bannerItem) { _, item in
            load(item, shape: .banner)
        }
        #if os(iOS)
        // 取景使用独立全屏画布，避免叠在资料 sheet 上的浮动卡片参与手势。
        .fullScreenCover(item: $cropping) { cropView($0) }
        #else
        .sheet(item: $cropping) { cropView($0) }
        #endif
    }

    private func cropView(_ job: CropJob) -> some View {
        TwitterCropSheet(image: job.image, shape: job.shape,
                         onCrop: { data in
                             if job.shape == .avatar {
                                 newAvatar = data
                             } else {
                                 newBanner = data
                                 dropBanner = false
                             }
                             cropping = nil
                         },
                         onCancel: { cropping = nil })
    }

    private var header: some View {
        HStack {
            Button("取消", action: onDone).buttonStyle(.plain).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("编辑个人资料").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("保存", action: save)
                .buttonStyle(.borderedProminent).tint(Theme.textPrimary)
                .disabled(busy || draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: - 图

    private var bannerEditor: some View {
        ZStack {
            Group {
                if let newBanner, let img = PlatformImage(data: newBanner) {
                    picture(img)
                } else if !dropBanner, let name = account?.bannerFileName {
                    TwitterMediaImage(url: mediaDir.appendingPathComponent(name))
                } else {
                    Rectangle().fill(accent)
                }
            }
            .frame(height: 120).frame(maxWidth: .infinity).clipped()
            // 压一层暗色，相机钮才看得清（推特也是这么做的）
            Color.black.opacity(0.3)
            HStack(spacing: 18) {
                PhotosPicker(selection: $bannerItem, matching: .images) { roundIcon("camera") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("换横幅")
                if newBanner != nil || (!dropBanner && account?.bannerFileName != nil) {
                    Button { newBanner = nil; bannerItem = nil; dropBanner = true } label: { roundIcon("xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("去掉横幅")
                }
            }
        }
        .frame(height: 120)
    }

    private var avatarEditor: some View {
        PhotosPicker(selection: $avatarItem, matching: .images) {
            ZStack {
                Group {
                    if let newAvatar, let img = PlatformImage(data: newAvatar) {
                        picture(img)
                    } else {
                        TwitterAvatarView(account: account, mediaDir: mediaDir, size: 72, accent: accent)
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(Circle())
                Circle().fill(Color.black.opacity(0.3)).frame(width: 72, height: 72)
                roundIcon("camera")
            }
            .overlay(Circle().stroke(Theme.mainBg, lineWidth: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("换头像")
    }

    private func picture(_ img: PlatformImage) -> some View {
        #if os(macOS)
        Image(nsImage: img).resizable().scaledToFill()
        #else
        Image(uiImage: img).resizable().scaledToFill()
        #endif
    }

    private func roundIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Color.black.opacity(0.5), in: Circle())
    }

    // MARK: - 字段

    /// 推特编辑页的字段：小标签在上、输入在下、右上角字数。
    private func field(_ label: String, text: Binding<String>, limit: Int,
                       prefix: String? = nil, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(text.wrappedValue.count) / \(limit)")
                    .foregroundStyle(text.wrappedValue.count > limit ? Theme.danger : Theme.textMuted)
            }
            .font(.footnote)
            .foregroundStyle(Theme.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if let prefix { Text(prefix).foregroundStyle(Theme.textMuted) }
                if multiline {
                    TextField("", text: text, axis: .vertical).lineLimit(2...6)
                } else {
                    TextField("", text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.textMuted.opacity(0.3)))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - 动作

    /// 选完图 → 先缩到长边 2048（相册原图动辄 4000px，整张进取景界面太吃内存）→ 弹取景。
    /// 取景出来的已经是最终尺寸（头像 400、横幅 1500×500），不再二次缩。
    private func load(_ item: PhotosPickerItem?, shape: TwitterCropSheet.Shape) {
        guard let item else { return }
        busy = true
        Task {
            defer {
                busy = false
                // 清掉选择，同一张图再选一次也能触发
                if shape == .avatar { avatarItem = nil } else { bannerItem = nil }
            }
            do {
                guard let raw = try await item.loadTransferable(type: Data.self) else { return }
                // 解码放后台别卡主线程
                let shrunk = await Task.detached(priority: .userInitiated) {
                    TwitterImageShrinker.jpeg(from: raw, maxPixel: TwitterImageShrinker.postPixel)
                }.value
                guard let shrunk, let image = PlatformImage(data: shrunk) else {
                    errorText = "这张图读不出来，换一张试试。"
                    return
                }
                cropping = CropJob(image: image, shape: shape)
            } catch { errorText = "取图失败：\(error.localizedDescription)" }
        }
    }

    private func save() {
        do {
            try TwitterProfileEditor.save(draft, avatar: newAvatar, banner: newBanner,
                                          removeBanner: dropBanner, profileId: profileId,
                                          context: modelContext, mediaDir: mediaDir)
            TwitterHaptics.success()
            onDone()
        } catch TwitterProfileEditorError.emptyName {
            errorText = "名字不能为空。"
        } catch {
            errorText = "存不上：\(error.localizedDescription)"
        }
    }
}
