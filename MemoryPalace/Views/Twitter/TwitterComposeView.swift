import SwiftUI
import PhotosUI

/// 写一条 / 回复一条 / 引用一条 / 改一条。主时间线的发推钮、详情页的回复钮、转发菜单的「引用」、「编辑」共用。
///
/// 草稿（粟粟 2026-09-27）：写了东西点取消，问存不存草稿；新推的框左上有「草稿」入口。
/// 从草稿打开的，发出去以后那份草稿就删掉；再存就是更新那一份。
struct TwitterComposeView: View {
    let account: TwitterArchiveAccount?
    let mediaDir: URL
    let accent: Color
    /// 非 nil = 回复这一条，顶上显示被回复的那条
    var replyingTo: TweetEntry?
    /// 非 nil = 引用这一条，输入框下面显示引用卡片
    var quoting: TweetEntry?
    /// 被回复 / 被引用那条的作者（本站的号，比如 AI 的）。`account` 是「我」，发的人；两个别混
    /// （粟粟 2026-09-25：回复预览里别人的头像变成了我的）
    var parentAuthor: TwitterArchiveAccount? = nil
    /// 存草稿用：楼层。空 = 不提供草稿（比如测试 / 预览）
    var profileId: String = ""
    /// 非 nil = 改这一条：预填原文，按钮叫「保存」，不能加图，不存草稿
    var editing: TweetEntry? = nil
    /// 从这份草稿接着写
    var resume: TwitterDraft? = nil
    /// 新推的框里点「草稿」
    var onOpenDrafts: (() -> Void)? = nil
    /// 正文 + 已压缩的图（最多四张）
    let onPost: (String, [Data]) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var images: [Data] = []
    @State private var loading = false
    @FocusState private var focused: Bool
    @State private var askingDraft = false
    /// 点过发布：框关掉时（= 发成功了）再删草稿；发失败框还开着，草稿不能先没了
    @State private var submitted = false
    @Environment(\.modelContext) private var modelContext

    private var draftsOn: Bool { !profileId.isEmpty && editing == nil }
    private var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }
    /// 改的时候没动过就不用问
    private var dirty: Bool {
        if let editing { return draft != editing.text }
        if let resume { return draft != resume.text || images != TwitterDrafts.images(of: resume, mediaDir: mediaDir) }
        return hasContent
    }

    private var canPost: Bool {
        !loading && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("取消", action: cancel).buttonStyle(.plain).foregroundStyle(Theme.textPrimary)
                if let onOpenDrafts, draftsOn, replyingTo == nil, quoting == nil {
                    Button("草稿", action: onOpenDrafts).buttonStyle(.plain).foregroundStyle(accent)
                        .padding(.leading, 12)
                }
                Spacer()
                Button(editing != nil ? "保存" : replyingTo == nil ? "发布" : "回复") { submit() }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(editing != nil ? !(canPost || (editing?.mediaCount ?? 0) > 0) || loading : !canPost)
            }
            .confirmationDialog("存成草稿？", isPresented: $askingDraft, titleVisibility: .visible) {
                Button(resume == nil ? "存草稿" : "更新草稿") { saveDraft() }
                Button(resume == nil ? "不存" : "不改草稿", role: .destructive, action: onCancel)
                Button("接着写", role: .cancel) {}
            }

            if let parent = replyingTo {
                // 推特回复页的样子：上面是被回复的那条，竖线连到自己的头像
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 4) {
                        TwitterAvatarView(account: parentAuthor, mediaDir: mediaDir, size: 40, accent: accent,
                                          otherName: parent.originalAuthorName)
                        Rectangle().fill(Theme.textMuted.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(parent.originalAuthorName ?? parentAuthor?.displayName ?? "我")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(parent.text).font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                            .lineLimit(4)
                        if let handle = parent.originalAuthorHandle ?? parentAuthor?.screenName, !handle.isEmpty {
                            HStack(spacing: 3) {
                                Text("回复")
                                Text("@\(handle)").foregroundStyle(accent)
                            }
                            .font(.footnote).foregroundStyle(Theme.textMuted)
                            .padding(.top, 6)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 10) {
                TwitterAvatarView(account: account, mediaDir: mediaDir, size: 40, accent: accent)
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $draft)
                        .font(.system(size: 18))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .overlay(alignment: .topLeading) {
                            if draft.isEmpty {
                                Text(placeholder)
                                    .font(.system(size: 18))
                                    .foregroundStyle(Theme.textMuted)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    if !images.isEmpty { imageStrip }
                    if let quoting { quotePreview(quoting) }
                }
            }

            Divider().opacity(0.4)
            HStack(spacing: 14) {
                if editing == nil {
                PhotosPicker(selection: $picked,
                             maxSelectionCount: max(1, TwitterComposer.maxImages - images.count),
                             matching: .images) {
                    Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .disabled(images.count >= TwitterComposer.maxImages)
                .accessibilityLabel("加图")
                }
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("加 # 话题，之后能搜到。").font(.footnote).foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 320, minHeight: 320)
        .background(Theme.mainBg)
        .onAppear {
            focused = true
            if let editing, draft.isEmpty { draft = editing.text }
            if let resume, draft.isEmpty, images.isEmpty {
                draft = resume.text
                images = TwitterDrafts.images(of: resume, mediaDir: mediaDir)
            }
        }
        .onChange(of: picked) { _, items in load(items) }
        .onDisappear {
            // 从草稿发出去的：草稿用完了
            if submitted, let resume { try? TwitterDrafts.delete(resume, mediaDir: mediaDir, context: modelContext) }
        }
    }

    private func cancel() {
        submitted = false
        if draftsOn && hasContent && dirty { askingDraft = true } else { onCancel() }
    }

    private func submit() {
        submitted = true
        onPost(draft, images)
    }

    private func saveDraft() {
        do {
            try TwitterDrafts.save(text: draft, images: images, replyingTo: replyingTo?.tweetId,
                                   quoting: quoting?.tweetId, accountId: account?.accountId ?? "",
                                   profileId: profileId, mediaDir: mediaDir, context: modelContext,
                                   existing: resume)
            TwitterHaptics.success()
        } catch {
            TwitterHaptics.failure()
        }
        onCancel()
    }

    private var placeholder: String {
        if editing != nil { return "改成……" }
        if replyingTo != nil { return "发布你的回复" }
        if quoting != nil { return "添加评论" }
        return "有什么新鲜事？"
    }

    private var imageStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, data in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            #if os(macOS)
                            if let img = NSImage(data: data) { Image(nsImage: img).resizable().scaledToFill() }
                            #else
                            if let img = UIImage(data: data) { Image(uiImage: img).resizable().scaledToFill() }
                            #endif
                        }
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button { images.remove(at: i) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.black.opacity(0.6), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                        .accessibilityLabel("去掉这张")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func quotePreview(_ q: TweetEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(q.originalAuthorName ?? parentAuthor?.displayName ?? "我")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text(q.text).font(.system(size: 14)).foregroundStyle(Theme.textSecondary).lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.textMuted.opacity(0.3)))
    }

    /// 相册原图几 MB，长边缩到 2048 转 JPEG 再存；解码放后台别卡主线程。
    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        loading = true
        Task {
            defer { loading = false; picked = [] }
            for item in items {
                guard images.count < TwitterComposer.maxImages,
                      let raw = try? await item.loadTransferable(type: Data.self) else { continue }
                let shrunk = await Task.detached(priority: .userInitiated) {
                    TwitterImageShrinker.jpeg(from: raw, maxPixel: TwitterImageShrinker.postPixel)
                }.value
                if let shrunk { images.append(shrunk) }
            }
        }
    }
}
