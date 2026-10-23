import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - 文件库设置（注入提示词模板可编辑）
//
// 一份 body 两端共用（plan-settings-merge 刀 1）：三张卡走 `SettingsCard`，模板区走 `SettingsGroup`，字号走 `settingsMetrics`。
// 只剩：外滚（iOS 自带 ScrollView / mac 由 SettingsView.macScroll 提供）、Finder / Obsidian 按钮 vs 文件 App 说明 两处平台例外。

struct FileLibrarySettingsTab: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage("fileLibraryInjectionTemplate") private var template = ""
    @AppStorage("fileLibraryEnabled") private var fileLibraryEnabled = true
    @AppStorage("topicBoxInjectionEnabled") private var topicBoxInjection = true
    @AppStorage(CCMemorySync.enabledKey) private var ccMemoryEnabled = false
    @AppStorage(CCMemorySync.profileKey) private var ccMemoryProfileId = ""
    @State private var ccMemoryStatus = ""
    @State private var showCCMemoryBrowser = false
    @AppStorage(AttachmentStore.compressImagesKey) private var compressImages = false
    #if os(iOS)
    @AppStorage(FileEditorPreferences.keyboardBarStyleKey) private var editorBarStyle = FileEditorKeyboardBarStyle.defaultStyle.rawValue
    #endif

    var body: some View {
        #if os(iOS)
        // 搜索锚点：命中叶子条目时滚到那张卡
        ScrollViewReader { anchorProxy in
            ScrollView { content }
                .background(Theme.sidebarBg)
                .navigationTitle("文件库")
                .navigationBarTitleDisplayMode(.inline)
                .settingsAnchorScroll(anchorProxy)
        }
        #else
        content
        #endif
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用文件库")
                            .font(m.rowTitle)
                            .foregroundColor(Theme.textPrimary)
                        Text("「不允许」= 不给模型下发 fs_* 工具，也不注入文件库说明；「每次询问」= 真调用时按对话问一次。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer(minLength: 8)
                    PermissionLevelPicker(domain: .fileLibrary)
                }
            }
            .searchAnchor("leaf-file-enable")

            #if os(iOS)
            // 新设置放第二张卡，不追加到页面底部（mac 没有键盘浮条）
            SettingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("编辑器键盘浮条")
                            .font(m.rowTitle)
                            .foregroundColor(Theme.textPrimary)
                        Text("打字时键盘上方格式条的样子")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer(minLength: 8)
                    Picker("编辑器键盘浮条", selection: Binding(
                        get: { FileEditorKeyboardBarStyle(stored: editorBarStyle) },
                        set: { editorBarStyle = $0.rawValue }
                    )) {
                        ForEach(FileEditorKeyboardBarStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .searchAnchor("leaf-file-editorbar")
            #endif


            ccMemorySyncCard

            SettingsCard {
                Toggle(isOn: $compressImages) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("聊天图片压缩入库")
                            .font(m.rowTitle)
                            .foregroundColor(Theme.textPrimary)
                        Text("聊天附件图片落盘到文件库时压缩（长边 2048px / JPEG）。关闭则存原图。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .tint(Theme.branchIndicator)
            }
            .searchAnchor("leaf-file-compress")

            storageLocationSection

            SettingsGroup("注入提示词模板", divider: true, anchor: "leaf-file-injecttemplate") {
                TextEditor(text: $template)
                    .font(m.caption.monospaced())
                    .frame(minHeight: 220)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
                    .scrollContentBackground(.hidden)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.5), lineWidth: 0.5))

                if !template.isEmpty {
                    Button("恢复默认") { template = "" }
                        .foregroundColor(.red.opacity(0.7))
                        .font(m.secondary)
                        .buttonStyle(.plain)
                }

                Text("留空使用默认模板。占位符：{{files}}（文件清单）、{{fileContents}}（本对话涉及文件的当前最终内容）。系统会自动用 <文件库>…</文件库> 包裹整段。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted.opacity(0.7))
            }

            #if os(iOS)
            Spacer(minLength: 0)
            #endif
        }
        #if os(iOS)
        .padding(16)
        #endif
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - CC 小克的记忆同步（plan-cc-memory-sync）

    @ViewBuilder
    private var ccMemorySyncCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { ccMemoryEnabled }, set: { setCCMemorySync($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("同步 CC 的记忆")
                            .font(m.rowTitle)
                            .foregroundColor(Theme.textPrimary)
                        Text("把 Claude Code 那边的 memory 同步到所选楼层的 memory/cc/（只读），AI 用文件工具能翻到。日记相关的不同步。需要连着 Mac 上的桥。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .tint(Theme.branchIndicator)

                if ccMemoryEnabled {
                    HStack {
                        Text("同步到楼层")
                            .font(m.body)
                            .foregroundColor(Theme.textSecondary)
                        Spacer(minLength: 8)
                        Picker("同步到楼层", selection: Binding(get: { ccMemoryProfileId }, set: { switchCCMemoryFloor(to: $0) })) {
                            ForEach(profileManager?.profiles ?? []) { p in
                                Text("\(p.emoji) \(p.name)").tag(p.id)
                            }
                        }
                        .labelsHidden()
                        .tint(Theme.branchIndicator)
                    }
                    HStack {
                        Text(ccMemoryStatus)
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                        Spacer(minLength: 8)
                        Button("立即同步") { CCMemorySync.requestManifest() }
                            .font(m.secondary)
                            .foregroundColor(Theme.branchIndicator)
                            .buttonStyle(.plain)
                    }
                    // 文件库页不显示记忆树 → 这里给一个只读入口
                    Button {
                        showCCMemoryBrowser = true
                    } label: {
                        HStack {
                            Text("查看同步过来的文件")
                                .font(m.body)
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchAnchor("leaf-file-ccmemory")
        .sheet(isPresented: $showCCMemoryBrowser) {
            MemoryTreeBrowserSheet(profileId: ccMemoryProfileId, onlyFolder: CCMemorySync.subdir)
        }
        .onAppear(perform: refreshCCMemoryStatus)
        .onReceive(NotificationCenter.default.publisher(for: CCMemorySync.didChange)) { _ in refreshCCMemoryStatus() }
    }

    private func setCCMemorySync(_ on: Bool) {
        if on {
            if ccMemoryProfileId.isEmpty {
                // D1 默认粟粟常用那层；这台设备上没有就用当前楼层
                let ids = (profileManager?.profiles ?? []).map(\.id)
                ccMemoryProfileId = ids.contains(CCMemorySync.defaultProfileId)
                    ? CCMemorySync.defaultProfileId
                    : (profileManager?.currentProfile.id ?? "")
            }
            ccMemoryEnabled = true
        } else {
            ccMemoryEnabled = false
            CCMemorySync.removeLocal(profileId: ccMemoryProfileId)
        }
        CCMemorySync.connected()
        refreshCCMemoryStatus()
    }

    private func switchCCMemoryFloor(to newId: String) {
        guard newId != ccMemoryProfileId else { return }
        CCMemorySync.removeLocal(profileId: ccMemoryProfileId)
        ccMemoryProfileId = newId
        CCMemorySync.requestManifest()
    }

    private func refreshCCMemoryStatus() {
        let d = UserDefaults.standard
        let at = d.double(forKey: CCMemorySync.lastSyncKey)
        guard at > 0 else { ccMemoryStatus = "还没同步过"; return }
        let when = Date(timeIntervalSince1970: at).formatted(.dateTime.month().day().hour().minute())
        ccMemoryStatus = "上次同步：\(when) · \(d.integer(forKey: CCMemorySync.lastCountKey)) 个文件"
    }

    @State private var iCloudToggle = FileLibraryStore.iCloudEnabled
    @State private var iCloudBusy = false
    @State private var iCloudStatus: String? = nil

    private var storageLocationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $iCloudToggle) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud 同步（实验）")
                        .font(m.rowTitle)
                        .foregroundColor(Theme.textPrimary)
                    Text("文件库放进 iCloud Drive：Mac 上可用 Obsidian 直接打开，两台设备共用一份。记忆树（memory/）始终留在本机。")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .tint(Theme.branchIndicator)
            .disabled(iCloudBusy)
            .onChange(of: iCloudToggle) { _, enabled in
                guard enabled != FileLibraryStore.iCloudEnabled else { return }
                applyICloudToggle(enabled)
            }
            .searchAnchor("leaf-file-icloud")

            if let iCloudStatus {
                Text(iCloudStatus)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }

            Divider().opacity(0.3)

            Text("本机文件位置")
                .font(m.sectionHeader)
                .foregroundColor(Theme.textPrimary)
                .searchAnchor("leaf-file-location")

            Text(currentLocationText)
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .textSelection(.enabled)

            #if os(macOS)
            HStack(spacing: 16) {
                Button("在 Finder 中显示") {
                    revealCurrentFolder()
                }
                Button("在 Obsidian 打开") {
                    openInObsidian()
                }
            }
            .font(m.secondary)
            .foregroundColor(Theme.branchIndicator)
            .buttonStyle(.plain)
            #else
            Text("可在系统“文件”App 的“记忆宫殿 / floors”里查看每个楼层的 filesystem 文件夹。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted.opacity(0.7))
            #endif
        }
        .padding(m.cardPadding)
        .background(RoundedRectangle(cornerRadius: m.cardCorner).fill(m.cardFill))
    }

    private var currentLocationText: String {
        guard let profile = profileManager?.currentProfile else {
            return "文件 / 记忆宫殿 / floors"
        }
        return FileLibraryStore.displayLocation(profileId: profile.id)
    }

    /// 开 = 预热容器 → 本地复制到云 → 翻 flag；关 = 云复制回本地 → 翻 flag。复制保守不删源。
    private func applyICloudToggle(_ enabled: Bool) {
        iCloudBusy = true
        iCloudStatus = enabled ? "正在连接 iCloud…" : "正在迁回本地…"
        FileLibraryStore.primeICloudContainer { available in
            if enabled && !available {
                iCloudToggle = false
                iCloudBusy = false
                iCloudStatus = "iCloud 不可用：请确认已登录 iCloud 且 iCloud Drive 已开启。"
                return
            }
            Task.detached(priority: .userInitiated) {
                let local = FileLibraryStore.localDocumentsBaseRoot()
                let cloud = FileLibraryStore.iCloudFloorsRoot()
                var summary = "迁移失败"
                if let cloud {
                    let result = enabled
                        ? FileLibraryStore.migrateFloors(from: local, to: cloud)
                        : FileLibraryStore.migrateFloors(from: cloud, to: local)
                    UserDefaults.standard.set(enabled, forKey: FileLibraryStore.iCloudEnabledKey)
                    summary = "已\(enabled ? "迁入 iCloud" : "迁回本地")：\(result.floors) 层楼 · \(result.filesCopied) 个文件"
                    if result.conflicts > 0 { summary += " · \(result.conflicts) 处冲突已留副本" }
                    summary += "。原位置文件保留作备份。"
                }
                await MainActor.run {
                    iCloudBusy = false
                    iCloudStatus = summary
                    NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
                }
            }
        }
    }

    #if os(macOS)
    private func revealCurrentFolder() {
        guard let profile = profileManager?.currentProfile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([FileLibraryStore.libraryRoot(profileId: profile.id)])
    }

    /// 把当前楼层文件库作为 vault 文件夹交给 Obsidian（大纲/backlinks/图谱让 Obsidian 自己做，不仿制）。
    /// 未装 Obsidian 时退化成 Finder 显示。
    private func openInObsidian() {
        guard let profile = profileManager?.currentProfile else { return }
        let folder = FileLibraryStore.libraryRoot(profileId: profile.id)
        guard let obsidian = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") else {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: obsidian, configuration: NSWorkspace.OpenConfiguration())
    }
    #endif
}
