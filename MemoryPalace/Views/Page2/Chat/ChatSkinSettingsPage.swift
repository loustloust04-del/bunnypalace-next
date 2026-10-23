#if os(iOS)
import SwiftUI
import PhotosUI

/// 设置 → 子应用 →「聊天（css自定义）」
///
/// 总开关控制这个 app 上不上 Page2 桌面（⧫ 粟粟：app 图标 lite 不露，但这一页两种模式都在）。
struct ChatSkinSettingsPage: View {
    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?
    @State private var showImporter = false
    @State private var importError: String?
    @State private var importedName: String?
    @State private var skinName: String? = ChatSkinStore.activeSkinName()
    @State private var confirmImport = false
    // 基础项：控件照外观页抄，值是聊天（css自定义）自己的（⧫ 粟粟：原生和 wkweb 不能一份）
    @AppStorage(ChatSkinStore.fontScaleKey) private var fontScale = ChatSkinStore.fontScaleDefault
    @AppStorage(ChatSkinStore.bgOpacityKey) private var bgOpacity = 1.0
    @State private var bgItem: PhotosPickerItem?
    @State private var bgThumb: UIImage? = Self.loadThumb()

    private var enabled: Bool { toolManager?.tool(byId: "cssChat")?.isEnabled ?? false }

    var body: some View {
        List {
            Section {
                Toggle("在桌面显示", isOn: Binding(
                    get: { enabled },
                    set: { toolManager?.setEnabled("cssChat", $0) }
                ))
                .tint(Theme.branchIndicator)
            } footer: {
                Text("开了之后 Page2 桌面上会出现「聊天（css自定义）」。它和主聊天是同一批对话，只是换一套皮肤看。")
            }

            Section {
                fontScaleRow
                backgroundRows
            } header: {
                Text("基础")
            } footer: {
                Text("只改这个子应用，主聊天不受影响。CSS 里写了同样的东西（比如 --mp-font-scale）以 CSS 为准。")
            }

            Section {
                NavigationLink {
                    ChatCSSEditorPage()
                } label: {
                    HStack {
                        Text("CSS")
                            .font(.system(size: Theme.F.body))
                        Spacer()
                        Text(skinName ?? "默认")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                Button {
                    if skinName != nil { confirmImport = true } else { showImporter = true }
                } label: {
                    Label("导入皮肤…", systemImage: "square.and.arrow.down")
                }
                if skinName != nil {
                    Button("恢复默认皮肤", role: .destructive) {
                        ChatSkinStore.clearActiveSkin()
                    }
                }
            } header: {
                Text("皮肤")
            } footer: {
                Text("CSS 就是当前皮肤本身，改完保存，聊天页马上生效。\n"
                     + "导入吃 KakaoTalk 的 .ktheme，也吃我们自己的 .mpskin —— 是同一种格式，"
                     + "所以现成的 KakaoTalk 主题拿来就能用。"
                     + "只读取聊天相关的部分（气泡、背景、输入栏）；主题里给好友列表、密码锁做的那些会忽略。")
            }
        }
        // 从聊天页 ⋯ 弹 sheet 进来时吃不到设置树的薄荷 tint，自己补（不许系统蓝）
        .tint(Theme.branchIndicator)
        .navigationTitle("聊天（css自定义）")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ChatSkinStore.didChange)) { _ in
            skinName = ChatSkinStore.activeSkinName()
        }
        .onChange(of: fontScale) { _, _ in ChatSkinStore.notifyChanged() }
        .onChange(of: bgOpacity) { _, _ in ChatSkinStore.notifyChanged() }
        .onChange(of: bgItem) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                    do {
                        try ChatSkinStore.saveUserBackground(img)
                        bgThumb = Self.loadThumb()
                    } catch { importError = error.localizedDescription }
                }
                bgItem = nil
            }
        }
        .confirmationDialog("导入会替换掉当前皮肤和你写的 CSS", isPresented: $confirmImport,
                            titleVisibility: .visible) {
            Button("继续导入", role: .destructive) { showImporter = true }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.zip, .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let r = try ChatSkinImporter.install(from: url)
                    importedName = r.author.isEmpty ? r.name : "\(r.name) · \(r.author)"
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let e):
                importError = e.localizedDescription
            }
        }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) { Button("好") { importError = nil } } message: { Text(importError ?? "") }
        .alert("导入成功", isPresented: Binding(
            get: { importedName != nil }, set: { if !$0 { importedName = nil } }
        )) { Button("好") { importedName = nil } } message: {
            Text("\(importedName ?? "")\n聊天（css自定义）已经换上了。")
        }
    }

    /// 抄外观页「聊天字号」那一格（AppearanceSettingsTab 文本段）
    private var fontScaleRow: some View {
        VStack(spacing: 8) {
            HStack {
                Text("聊天字号")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(Int((fontScale * 100).rounded()))%")
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
            }
            HStack(spacing: 12) {
                Button { fontScale = max(0.5, fontScale - 0.1) } label: {
                    Image(systemName: "textformat.size.smaller")
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                Slider(value: $fontScale, in: 0.5...2.0, step: 0.05)
                    .tint(Theme.branchIndicator)
                Button { fontScale = min(2.0, fontScale + 0.1) } label: {
                    Image(systemName: "textformat.size.larger")
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            if fontScale != ChatSkinStore.fontScaleDefault {
                Button { fontScale = ChatSkinStore.fontScaleDefault } label: {
                    Text("重置默认")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    /// 抄外观「聊天背景」的选图 + 透明度（ChatBackgroundSections），图存 ChatSkins/user-bg.jpg
    @ViewBuilder
    private var backgroundRows: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $bgItem, matching: .images) {
                Text(bgThumb == nil ? "从照片选背景图" : "换一张背景图")
                    .foregroundColor(Theme.branchIndicator)
            }
            Spacer()
            if let bgThumb {
                Image(uiImage: bgThumb)
                    .resizable().scaledToFill()
                    .frame(width: 44, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        if bgThumb != nil {
            VStack(spacing: 6) {
                HStack {
                    Text("背景透明度")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text("\(Int((bgOpacity * 100).rounded()))%")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                }
                Slider(value: $bgOpacity, in: 0...1, step: 0.01)
                    .tint(Theme.branchIndicator)
            }
            Button("移除背景图", role: .destructive) {
                ChatSkinStore.removeUserBackground()
                bgThumb = nil
            }
        }
    }

    private static func loadThumb() -> UIImage? {
        guard ChatSkinStore.hasUserBackground,
              let img = UIImage(contentsOfFile: ChatSkinStore.userBackgroundURL.path) else { return nil }
        return img.preparingThumbnail(of: CGSize(width: 132, height: 90)) ?? img
    }
}
#endif
