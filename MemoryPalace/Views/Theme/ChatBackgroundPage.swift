import SwiftUI
#if os(iOS)
import PhotosUI
#endif

/// 聊天背景页（两端共用一份 body）：编辑一套主题的背景图 + 透明度 / 遮罩 / 位置 + 壁纸下气泡半透明。
///
/// **改主题 ≠ 应用主题**（粟粟 09-16）：`themeId == nil` = 外观页入口，编辑当前主题；给定 `themeId` = 主题列表长按进来，编辑那一套，不切换当前主题。
///
/// plan-theme-decouple M3.4：背景的事全在这一页。「壁纸下气泡自动半透明」从高级外观搬来（它只在有背景图时生效）；
/// 「撤销」回到进页时的图 + 参数——换图 / 移除会立刻删掉原文件，所以进页先给原图留一份备份，离页再删（kimi 应改 4）。
/// 「重置为默认」= 参数归零，两个按钮都留。「纯净背景」不在这（它改的是颜色，住颜色页）。
/// 三段正文抽在 `ChatBackgroundSections`，「新建主题」页（`ThemeColorsPage(creating:)`）嵌同一份。
struct ChatBackgroundPage: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(\.dismiss) private var dismiss
    /// nil = 编辑当前主题（外观页入口）；给定 = 编辑那一套（主题列表长按），不切换当前主题
    let fixedThemeId: String?
    @State private var snapshot: BackgroundSnapshot?
    @State private var didAppear = false
    @State private var showBuiltInPrompt = false
    @State private var copiedThemeId: String?

    init(themeId: String? = nil) {
        self.fixedThemeId = themeId
    }

    private struct BackgroundSnapshot {
        let themeId: String
        let style: ThemeBackgroundStyle?
        let imageFileName: String?
        /// 原图的备份文件名（在 ThemeAssets 目录里），撤销时从它复制回来
        let backupFileName: String?
    }

    private var manager: ThemeManager { themeManager ?? ThemeManager.shared }
    private var themeId: String { copiedThemeId ?? fixedThemeId ?? manager.selectedThemeId }
    private var theme: AppThemeDefinition { manager.themeDefinition(id: themeId) ?? manager.selectedTheme }

    private var canUndo: Bool {
        guard let snapshot, snapshot.themeId == themeId else { return false }
        return snapshot.style != theme.backgroundStyle || snapshot.imageFileName != theme.backgroundImageFileName
    }

    var body: some View {
        let _ = manager.themeChangeID

        SettingsSectionList(.list) {
            ChatBackgroundSections(themeId: themeId)

            Section {
                Button("重置为默认") {
                    manager.resetBackgroundAdjustments(for: themeId)
                }
                .foregroundColor(Theme.branchIndicator)

                #if os(macOS)
                Button("撤销本次修改") { undo() }
                    .foregroundColor(Theme.branchIndicator)
                    .disabled(!canUndo)
                #endif
            } footer: {
                Text("「撤销」= 回到进这页时的图和参数（换错了图能救回来）；「重置为默认」= 透明度、遮罩、位置归默认值。")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        .disabled(theme.isBuiltIn)
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ThemeBackgroundView(
                fill: Theme.sidebarBg,
                imageURL: manager.currentBackgroundImageURL,
                scheme: manager.activeScheme,
                backgroundStyle: manager.currentBackgroundStyle
            )
            .ignoresSafeArea()
        }
        #if os(iOS)
        .navigationTitle("聊天背景")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("撤销") { undo() }
                    .foregroundColor(Theme.branchIndicator)
                    .disabled(!canUndo)
            }
        }
        #endif
        .alert("内置主题不能改", isPresented: $showBuiltInPrompt) {
            Button("复制一份") { copyAndContinue() }
            Button("算了", role: .cancel) { dismiss() }
        } message: {
            Text(fixedThemeId == nil
                 ? "复制一份「\(theme.name)」再改？复制完自动切过去。"
                 : "复制一份「\(theme.name)」再改？当前主题不变。")
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            takeSnapshot()
            if theme.isBuiltIn { showBuiltInPrompt = true }
        }
        .onChange(of: manager.selectedThemeId) { _, _ in
            guard fixedThemeId == nil else { return }   // 列表入口的靶子固定，不跟选中走
            discardBackup()
            takeSnapshot()
        }
        .onDisappear {
            discardBackup()
        }
    }

    // MARK: - 快照 / 撤销 / 复制

    private func takeSnapshot() {
        var backup: String?
        if let fileName = theme.backgroundImageFileName {
            backup = try? ThemeAssetStore.copyBackgroundImage(named: fileName, for: "undo-\(themeId)")
        }
        snapshot = BackgroundSnapshot(
            themeId: themeId,
            style: theme.backgroundStyle,
            imageFileName: theme.backgroundImageFileName,
            backupFileName: backup
        )
    }

    private func discardBackup() {
        if let backup = snapshot?.backupFileName {
            ThemeAssetStore.removeBackgroundImage(named: backup)
        }
        snapshot = nil
    }

    private func undo() {
        guard let snapshot, snapshot.themeId == themeId else { return }
        if theme.backgroundImageFileName != snapshot.imageFileName {
            if let backup = snapshot.backupFileName, let url = ThemeAssetStore.url(for: backup) {
                // 从备份复制回一份新文件；备份本身留到离页再删
                try? manager.setBackgroundImage(from: url, for: themeId)
            } else if snapshot.imageFileName == nil {
                manager.clearBackgroundImage(for: themeId)
            }
        }
        manager.replaceBackgroundStyle(snapshot.style, for: themeId)
    }

    private func copyAndContinue() {
        let selectAfter = fixedThemeId == nil
        if let newId = manager.saveThemeCopy(from: themeId, name: "", select: selectAfter), !selectAfter {
            copiedThemeId = newId
        }
        discardBackup()
        takeSnapshot()
    }
}

/// 背景图 / 显示 / 气泡三段（不含 List、撤销、页面 chrome），编辑 `themeId` 那一套：`ChatBackgroundPage` 和「新建主题」页共用一份。
/// `embedded` = 嵌在别的页里：不画预览（新建主题页钉顶已有）、第一段带「聊天背景」标题。
struct ChatBackgroundSections: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(\.settingsMetrics) private var m
    /// 负向 key：true = 关闭自动半透明。key 缺省（false）= 行为保持原样（从高级外观搬来，语义不变）
    @AppStorage("disableAutoTransparentBubblesOnWallpaper") private var disableAutoTransparent: Bool = false
    let themeId: String
    var embedded = false
    @State private var showImageImporter = false
    @State private var imageImportError: String?
    #if os(iOS)
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

    private var manager: ThemeManager { themeManager ?? ThemeManager.shared }
    private var theme: AppThemeDefinition { manager.themeDefinition(id: themeId) ?? manager.selectedTheme }
    private var backgroundStyle: ThemeBackgroundStyle { manager.backgroundStyle(for: themeId) }
    private var scheme: ColorScheme { manager.activeScheme }

    var body: some View {
        let _ = manager.themeChangeID

        Section {
            if !embedded {
                ThemeChatPreview(
                    tokenSet: manager.previewTokenSet(for: themeId, scheme: scheme),
                    scheme: scheme,
                    backgroundImageURL: manager.backgroundImageURL(for: themeId),
                    backgroundStyle: backgroundStyle,
                    size: .pinned
                )
                .padding(.vertical, 4)
            }

            #if os(iOS)
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Text("从照片选背景图")
                    .foregroundColor(Theme.branchIndicator)
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task { await importPhotoItem(newItem) }
            }

            fileButton("从文件选背景图")
            #else
            fileButton("选择背景图片")
            #endif

            if theme.hasBackgroundImage {
                Button("移除背景图") {
                    manager.clearBackgroundImage(for: themeId)
                }
                .foregroundColor(Theme.danger)
            }
        } header: {
            if embedded { Text("聊天背景") }
        } footer: {
            Text(theme.hasBackgroundImage ? "背景图会跟着主题一起切换。" : "导入一张图片后，这个主题切换时会连背景一起切。")
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)

        if theme.hasBackgroundImage {
            Section("显示") {
                ThemeAdjustmentSliderRow(
                    title: "透明度",
                    subtitle: "拉满就是原图。",
                    range: ThemeBackgroundStyle.opacityRange,
                    value: opacityBinding,
                    leadingLabel: "更淡",
                    trailingLabel: "更明显",
                    valueText: percentText(opacityBinding.wrappedValue)
                )

                ThemeAdjustmentSliderRow(
                    title: "遮罩",
                    subtitle: "盖在背景图上的一层薄纱（浅色白、深色黑）。调低更透，调到 0 就是原图。",
                    range: ThemeBackgroundStyle.veilRange,
                    value: veilBinding,
                    leadingLabel: "原图",
                    trailingLabel: "更柔",
                    valueText: percentText(veilBinding.wrappedValue)
                )

                ThemeAdjustmentSliderRow(
                    title: "左右位置",
                    range: ThemeBackgroundStyle.horizontalOffsetRange,
                    value: offsetXBinding,
                    leadingLabel: "向左",
                    trailingLabel: "向右",
                    valueText: offsetText(offsetXBinding.wrappedValue)
                )

                ThemeAdjustmentSliderRow(
                    title: "上下位置",
                    range: ThemeBackgroundStyle.verticalOffsetRange,
                    value: offsetYBinding,
                    leadingLabel: "向上",
                    trailingLabel: "向下",
                    valueText: offsetText(offsetYBinding.wrappedValue)
                )
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }

        Section("气泡") {
            Toggle(isOn: Binding(
                get: { !disableAutoTransparent },
                set: { disableAutoTransparent = !$0; manager.notifyThemeChange() }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("壁纸下气泡自动半透明")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Text("有背景图时两种气泡底自动变透，让气泡融进壁纸。")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .tint(Theme.branchIndicator)
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)
    }

    /// 「从文件选」这一行自带 fileImporter + 导入失败弹窗（挂在行上，不挂 Section 组——组上会给每段各挂一份）
    private func fileButton(_ title: String) -> some View {
        Button(title) {
            showImageImporter = true
        }
        .foregroundColor(Theme.branchIndicator)
        .fileImporter(
            isPresented: $showImageImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    try manager.setBackgroundImage(from: url, for: themeId)
                } catch {
                    imageImportError = error.localizedDescription
                }
            case .failure(let error):
                imageImportError = error.localizedDescription
            }
        }
        .alert("背景图导入失败", isPresented: Binding(
            get: { imageImportError != nil },
            set: { if !$0 { imageImportError = nil } }
        )) {
            Button("好的") {
                imageImportError = nil
            }
        } message: {
            Text(imageImportError ?? "")
        }
    }

    // MARK: - 绑定

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { backgroundStyle.resolvedOpacity(for: scheme) },
            set: { manager.updateBackgroundOpacity($0, for: themeId) }
        )
    }

    private var veilBinding: Binding<Double> {
        Binding(
            get: { backgroundStyle.resolvedVeil },
            set: { manager.updateBackgroundVeil($0, for: themeId) }
        )
    }

    private var offsetXBinding: Binding<Double> {
        Binding(
            get: { Double(backgroundStyle.resolvedOffsetX) },
            set: { manager.updateBackgroundOffset(x: $0, for: themeId) }
        )
    }

    private var offsetYBinding: Binding<Double> {
        Binding(
            get: { Double(backgroundStyle.resolvedOffsetY) },
            set: { manager.updateBackgroundOffset(y: $0, for: themeId) }
        )
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func offsetText(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        if rounded == 0 {
            return "居中"
        }
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    #if os(iOS)
    private func importPhotoItem(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let preferredExtension = item.supportedContentTypes.first?.preferredFilenameExtension
            try manager.setBackgroundImage(
                data: data,
                preferredExtension: preferredExtension,
                for: themeId
            )
        } catch {
            imageImportError = error.localizedDescription
        }
    }
    #endif
}
