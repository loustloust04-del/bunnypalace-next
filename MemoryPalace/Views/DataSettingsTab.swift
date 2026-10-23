import SwiftUI
import SwiftData

// MARK: - Data Settings Tab

struct DataSettingsTab: View {
    /// 备份照样带有声书数据；只有粟粟的 Debug 包里有有声书，别的包文案不提（#096）
    private static var audiobookMention: String {
        return ""
    }
    @Environment(\.settingsMetrics) private var m
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @AppStorage("exportMode") private var exportMode = "lightweight"
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"

    @State private var isExportingAll = false
    @State private var exportProgress: Double = 0
    @State private var exportTotal: Int = 0

    @State private var isExportingAllProfiles = false
    @State private var exportAllProfilesProgress: Double = 0
    @State private var exportAllProfilesTotal: Int = 0
    /// 批量导出完成报告（失败计数可见，不再静默吞 write 错误）
    @State private var exportResultMessage: String?

    @State private var showImporter = false
    @State private var showBackfill = false

    // 时间机器(plan-time-machine)
    @AppStorage(BackupStore.isEnabledKey) private var backupAutoEnabled = false
    @State private var showRestoreSheet = false
    @State private var showBackupOnboarding = false
    @State private var backupSummary: (count: Int, totalBytes: Int) = (0, 0)
    @State private var backupProgress: (processed: Int, total: Int)? = nil
    @State private var backupRunning = false
    @State private var backupDoneMessage: String? = nil

    // 全量备份（G-D）
    @State private var showGlobalExportSheet = false
    @State private var showGlobalImportSheet = false

    // Claude 数据清除（P5：切换到 segments 格式前一次性清干净）
    @State private var wipeConfirm = false
    @State private var wipePreview: ClaudeDataWiper.Preview? = nil
    @State private var wipeResultMessage: String? = nil
    @State private var isWiping = false

    private var currentProfileId: String {
        profileManager?.currentProfile.id ?? ""
    }

    private func refreshWipePreview() {
        wipePreview = try? ClaudeDataWiper.preview(
            profileId: currentProfileId,
            context: modelContext
        )
    }

    private func runClaudeWipe() {
        isWiping = true
        let pid = currentProfileId
        let ctx = modelContext
        DispatchQueue.global(qos: .userInitiated).async {
            let bgCtx = ModelContext(ctx.container)
            do {
                let result = try ClaudeDataWiper.wipe(profileId: pid, context: bgCtx)
                DispatchQueue.main.async {
                    wipeResultMessage = "已清除 \(result.conversationCount) 条对话 · \(result.nodeCount) 条消息 · \(result.importRecordCount) 条导入记录。现在可以重新导入。"
                    wipePreview = nil
                    isWiping = false
                }
            } catch {
                DispatchQueue.main.async {
                    wipeResultMessage = "清除失败：\(error.localizedDescription)"
                    isWiping = false
                }
            }
        }
    }

    // MARK: - 同步（跨设备 · 文件态同步层）

    @State private var syncToggle = false
    @State private var syncBusy = false
    @State private var syncStatus: String? = nil

    @ViewBuilder
    private var syncSectionContent: some View {
        Toggle(isOn: $syncToggle) {
            VStack(alignment: .leading, spacing: 2) {
                Text("同步模式（实验 · 当前楼层）")
                    .font(m.action)
                    .foregroundColor(Theme.textPrimary)
                Text(LocalMode.isOn
                     ? "本地模式开启中：所有数据只存本机，同步不可用。"
                     : "此楼层的聊天记录经 iCloud 在多设备间合并同步（需各设备登录同一 Apple ID）。附件随行建议同时开启文件库的 iCloud 同步。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
        }
        .tint(Theme.branchIndicator)
        .disabled(LocalMode.isOn || syncBusy)
        .onAppear { syncToggle = SyncStore.isEnabled(profileId: currentProfileId) }
        .onChange(of: syncToggle) { _, enabled in
            guard enabled != SyncStore.isEnabled(profileId: currentProfileId) else { return }
            applySyncToggle(enabled)
        }
        .searchAnchor("leaf-data-sync")

        Button {
            runSyncNow()
        } label: {
            Text(syncBusy ? "同步中…" : "立即同步")
                .font(m.action)
                .foregroundColor(syncToggle && !syncBusy ? Theme.branchIndicator : Theme.textMuted)
        }
        .buttonStyle(.plain)
        .disabled(!syncToggle || syncBusy)

        if let syncStatus {
            Text(syncStatus)
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }

        // 跨设备接入：同步按楼层 id 走，对端楼层 id 不同则永不相遇——先把对方楼层"领养"过来
        Button {
            // 必须先预热容器：iOS 的 ubiquity URL 不初始化，扫描永远空（口罩机实测）；
            // 预热同时让这个 Apple ID 正式"立户"容器，对端裸路径写入才会被系统认领上传
            syncBusy = true
            syncStatus = "正在连接 iCloud…"
            FileLibraryStore.primeICloudContainer { available in
                syncBusy = false
                guard available else {
                    syncStatus = "iCloud 不可用：请确认已登录 iCloud 且 iCloud Drive 已开启。"
                    return
                }
                syncStatus = nil
                remoteFloors = SyncStore.discoverRemoteFloors().filter { info in
                    !(profileManager?.profiles.contains { $0.id == info.profileId } ?? false)
                }
                showAdoptDialog = true
            }
        } label: {
            Text("接入其他设备的楼层…")
                .font(m.action)
                .foregroundColor(Theme.branchIndicator)
        }
        .buttonStyle(.plain)
        .disabled(syncBusy)
        .confirmationDialog("接入 iCloud 里的楼层", isPresented: $showAdoptDialog, titleVisibility: .visible) {
            ForEach(remoteFloors, id: \.profileId) { info in
                Button("\(info.emoji) \(info.name)") { adoptFloor(info) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(remoteFloors.isEmpty
                 ? "iCloud 里暂无其他设备发布的楼层。对方设备需已打开同步模式；首次同步的文档可能还在上传路上（几分钟），稍后再试。"
                 : "选择要接入的楼层：本机会创建同名楼层并拉取它的聊天记录。")
        }
    }

    @State private var remoteFloors: [SyncStore.FloorInfo] = []
    @State private var showAdoptDialog = false

    /// 领养远端楼层：同 id 建本地 Profile → 开同步 → 立即拉取
    private func adoptFloor(_ info: SyncStore.FloorInfo) {
        guard let pm = profileManager else { return }
        let profile = Profile(
            id: info.profileId, name: info.name, emoji: info.emoji,
            description: "", userName: userName, assistantName: assistantName
        )
        pm.addProfile(profile)
        SyncStore.setEnabled(true, profileId: info.profileId)
        SyncEngine.shared.start(profileId: info.profileId, container: pm.container)
        syncToggle = true
        syncBusy = true
        syncStatus = "正在拉取「\(info.name)」…"
        guard let container = profileManager?.container else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let bgContext = ModelContext(container)
            let r = SyncStore.syncNow(profileId: info.profileId, context: bgContext) { text in
                DispatchQueue.main.async { syncStatus = text }
            }
            DispatchQueue.main.async {
                syncBusy = false
                var text = "已接入：导入 \(r.imported.conversationsCreated) 对话 / \(r.imported.nodesInserted) 条消息。"
                if r.imported.documentsDownloading > 0 {
                    text += " 还有 \(r.imported.documentsDownloading) 个在 iCloud 下载中，稍后点「立即同步」补齐。"
                }
                text += crossProfileConflictSuffix(r.imported.conversationsSkippedCrossProfile)
                syncStatus = text
            }
        }
    }

    private func applySyncToggle(_ enabled: Bool) {
        let pid = currentProfileId
        guard !pid.isEmpty else { return }
        if !enabled {
            SyncStore.setEnabled(false, profileId: pid)
            SyncEngine.shared.stop()
            syncStatus = "已关闭同步。云端文档保留，本机数据不受影响。"
            return
        }
        syncBusy = true
        syncStatus = "正在连接 iCloud…"
        FileLibraryStore.primeICloudContainer { available in
            guard available, SyncStore.syncRoot(profileId: pid) != nil else {
                syncToggle = false
                syncBusy = false
                syncStatus = "iCloud 不可用：请确认已登录 iCloud 且 iCloud Drive 已开启。"
                return
            }
            SyncStore.setEnabled(true, profileId: pid)
            if let profile = profileManager?.currentProfile {
                SyncStore.publishFloorInfo(profileId: pid, name: profile.name, emoji: profile.emoji)
            }
            if let container = profileManager?.container {
                SyncEngine.shared.start(profileId: pid, container: container)
            }
            runSyncNow(initial: true)
        }
    }

    private func runSyncNow(initial: Bool = false) {
        let pid = currentProfileId
        guard SyncStore.isEnabled(profileId: pid), let container = profileManager?.container else { return }
        syncBusy = true
        syncStatus = initial ? "首次全量导出中（大楼层要几分钟，UI 不卡可以继续用）…" : "同步中…"
        // 后台 context：大楼层全量导出在主线程会卡死 UI（Mac 实测事故）
        DispatchQueue.global(qos: .userInitiated).async {
            let bgContext = ModelContext(container)
            let r = SyncStore.syncNow(profileId: pid, context: bgContext) { text in
                DispatchQueue.main.async { syncStatus = text }
            }
            DispatchQueue.main.async {
                syncBusy = false
                var text = "已同步：导入 \(r.imported.conversationsCreated) 新对话 / \(r.imported.nodesInserted) 条消息；导出 \(r.exported.exported) 个对话文档。"
                if r.imported.documentsDownloading > 0 {
                    text += " 还有 \(r.imported.documentsDownloading) 个文档在 iCloud 下载中，稍后再点一次。"
                }
                text += crossProfileConflictSuffix(r.imported.conversationsSkippedCrossProfile)
                syncStatus = text
            }
        }
    }

    // MARK: - 存储（A4：清理系统缓存 + 整理媒体数据）

    @State private var cacheFreedMessage: String? = nil
    @State private var sweepConfirm = false
    @State private var isSweeping = false
    @State private var sweepProgress = ""
    @State private var sweepResultMessage: String? = nil

    @ViewBuilder
    private var timeMachineSectionContent: some View {
        Toggle(isOn: Binding(
            get: { backupAutoEnabled },
            set: { newVal in
                if newVal && !backupAutoEnabled {
                    showBackupOnboarding = true
                } else {
                    backupAutoEnabled = newVal
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("自动备份")
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                Text("切后台时把对话快照写到 iCloud, 保留最近 30 天")
                    #if os(macOS)
                    .font(ShellStyle.secondaryFont)
                    #else
                    .font(.caption)
                    #endif
                    .foregroundColor(Theme.textMuted)
            }
        }
        .tint(Theme.branchIndicator)
        .searchAnchor("leaf-data-autobackup")

        Button(action: { runBackupNow() }) {
            HStack {
                Image(systemName: "arrow.down.circle")
                VStack(alignment: .leading, spacing: 2) {
                    Text("立即备份一次")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Text("手动跑一次, 增量(没变的对话不重写)")
                        #if os(macOS)
                        .font(ShellStyle.secondaryFont)
                        #else
                        .font(.caption)
                        #endif
                        .foregroundColor(Theme.textMuted)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(backupRunning)

        Button(action: { showRestoreSheet = true }) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                VStack(alignment: .leading, spacing: 2) {
                    Text("查看备份 / 还原")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    if backupSummary.count > 0 {
                        Text("\(backupSummary.count) 份 · 共 \(formatBackupSize(backupSummary.totalBytes))")
                            #if os(macOS)
                            .font(ShellStyle.secondaryFont)
                            #else
                            .font(.caption)
                            #endif
                            .foregroundColor(Theme.textMuted)
                    } else {
                        Text("还没有备份")
                            #if os(macOS)
                            .font(ShellStyle.secondaryFont)
                            #else
                            .font(.caption)
                            #endif
                            .foregroundColor(Theme.textMuted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(Theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatBackupSize(_ b: Int) -> String {
        if b < 1024 * 1024 { return String(format: "%.0f KB", Double(b) / 1024) }
        return String(format: "%.1f MB", Double(b) / 1024 / 1024)
    }

    private func refreshBackupSummary() {
        let entries = BackupStore.listBackups()
        backupSummary = (entries.count, entries.reduce(0) { $0 + $1.totalSizeBytes })
    }

    private var backupProgressView: some View {
        VStack(spacing: 20) {
            Text("正在备份")
                #if os(macOS)
                .font(ShellStyle.bodyFont.weight(.semibold))
                #else
                .font(.headline)
                #endif
            if let p = backupProgress {
                ProgressView(value: p.total == 0 ? 0 : Double(p.processed), total: Double(max(1, p.total)))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 300)
                Text("\(p.processed) / \(p.total) 对话")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            } else {
                ProgressView()
            }
            Text("把所有对话快照写到 iCloud, 别关 app")
                #if os(macOS)
                .font(ShellStyle.secondaryFont)
                #else
                .font(.caption)
                #endif
                .foregroundColor(Theme.textMuted)
        }
        .padding(40)
        .interactiveDismissDisabled(true)
        #if os(macOS)
        .frame(width: 360, height: 220)
        #endif
    }

    private func triggerFirstBackup() { runBackupNow(firstTime: true) }

    private func runBackupNow(firstTime: Bool = false) {
        backupProgress = (0, 0)
        backupRunning = true
        let container = modelContext.container
        DispatchQueue.global(qos: .userInitiated).async {
            let bgCtx = ModelContext(container)
            let result = BackupStore.snapshotIfNeeded(context: bgCtx, force: true) { processed, total in
                DispatchQueue.main.async {
                    backupProgress = (processed, total)
                }
            }
            BackupStore.pruneOldBackups()
            DispatchQueue.main.async {
                backupRunning = false
                refreshBackupSummary()
                if let err = result.error {
                    backupDoneMessage = "备份未完成: \(err)\n\n你可以稍后在「查看备份/还原」里手动检查。"
                } else {
                    let prefix = firstTime ? "✅ 首次备份完成" : "✅ 备份完成"
                    backupDoneMessage = "\(prefix)\n写入 \(result.written) 对话, 跳过 \(result.skipped) 条\n约 \(formatBackupSize(result.totalSizeBytes))"
                }
            }
        }
    }

    @ViewBuilder
    private var storageSectionContent: some View {
        searchIndexRow

        Button {
            let freed = StorageMaintenance.cleanSystemCaches()
            cacheFreedMessage = "已释放 \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .file))（临时文件 / 缩略图 / 网络缓存）"
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("清理系统缓存")
                    .font(m.action)
                    .foregroundColor(Theme.textPrimary)
                Text("临时文件、HTML 缩略图、网络缓存。都可再生，随时可清。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
        }
        .buttonStyle(.plain)
        .searchAnchor("leaf-data-cache")
        .alert("清理完成", isPresented: Binding(get: { cacheFreedMessage != nil }, set: { if !$0 { cacheFreedMessage = nil } })) {
            Button("好") { cacheFreedMessage = nil }
        } message: {
            Text(cacheFreedMessage ?? "")
        }

        Button {
            sweepConfirm = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(isSweeping ? "整理中…\(sweepProgress)" : "整理媒体数据")
                    .font(m.action)
                    .foregroundColor(isSweeping ? Theme.textMuted : Theme.textPrimary)
                Text("历史消息里的内联附件迁出到文件库（数据库瘦身），并删除文件库 attachments 里无人引用的孤儿文件。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
        }
        .buttonStyle(.plain)
        .disabled(isSweeping)
        .confirmationDialog("整理媒体数据？", isPresented: $sweepConfirm, titleVisibility: .visible) {
            Button("开始整理", role: .destructive) { runMediaSweep() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("attachments 目录里没有任何消息引用的文件会被删除（手动放进去的也算）。迁移本身不删任何数据。")
        }
        .alert("整理完成", isPresented: Binding(get: { sweepResultMessage != nil }, set: { if !$0 { sweepResultMessage = nil } })) {
            Button("好") { sweepResultMessage = nil }
        } message: {
            Text(sweepResultMessage ?? "")
        }
    }

    /// S5 全文索引：状态 + 重建（无损，不用二次确认）
    private var searchIndexRow: some View {
        let state = SearchIndexer.shared.state
        let status: String
        let building: Bool
        switch state.status {
        case .idle:
            status = "等待建立"
            building = false
        case .building(let progress):
            status = "建立中 \(Int(progress * 100))%"
            building = true
        case .ready:
            let size = SearchIndexer.shared.readyStore?.fileSizeBytes() ?? 0
            status = "已就绪 · \(state.docCount) 条 · 占用 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
            building = false
        case .failed(let reason):
            status = "失败：\(reason)"
            building = false
        }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("搜索索引")
                    .font(m.action)
                    .foregroundColor(Theme.textPrimary)
                Text("让全文搜索更快，占用一些存储空间")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                Text(status)
                    .font(m.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button("重建") { SearchIndexer.shared.rebuild() }
                .buttonStyle(.bordered)
                .tint(Theme.textPrimary)
                .disabled(building)
        }
        .searchAnchor("leaf-data-searchindex")
    }

    private func runMediaSweep() {
        isSweeping = true
        sweepProgress = ""
        Task { @MainActor in
            let result = await StorageMaintenance.sweepMedia(context: modelContext) { sweepProgress = $0 }
            isSweeping = false
            sweepResultMessage = "扫描 \(result.conversationsScanned) 条对话；迁移 \(result.nodesMigrated) 条消息的附件到文件库；清理孤儿文件 \(result.orphansDeleted) 个（\(ByteCountFormatter.string(fromByteCount: Int64(result.orphanBytes), countStyle: .file))）。"
            NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
        }
    }

    @ViewBuilder
    private var claudeWipeSectionContent: some View {
        if let msg = wipeResultMessage {
            Text(msg)
                #if os(macOS)
                .font(ShellStyle.secondaryFont)
                #else
                .font(.caption)
                #endif
                .foregroundColor(Theme.textMuted)
        } else if isWiping {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                #if os(macOS)
                Text("清除中...").font(ShellStyle.secondaryFont).foregroundColor(Theme.textMuted)
                #else
                Text("清除中...").font(.caption).foregroundColor(Theme.textMuted)
                #endif
            }
        } else {
            Button {
                refreshWipePreview()
                wipeConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("清空本楼层 Claude 导入数据")
                }
                .font(m.secondary)
                .foregroundColor(Theme.danger)
            }
            .buttonStyle(.plain)
        }

        Text("用于切换到新 segments 格式前清理旧导入。只清 Claude（含导入时顺带建的记忆和文件夹），不动 ChatGPT / API / 预设 / 你自己的记忆。")
            #if os(macOS)
            .font(ShellStyle.secondaryFont)
            #else
            .font(.caption)
            #endif
            .foregroundColor(Theme.textMuted)
    }

    private var wipeAlertMessage: String {
        guard let p = wipePreview else { return "将清除本楼层所有 Claude 导入数据。" }
        return "本楼层将删除 \(p.conversationCount) 条 Claude 对话 · \(p.nodeCount) 条消息 · \(p.importRecordCount) 条导入记录。\n\n不可撤销。"
    }

    var body: some View {
        Group {
            pageBody
        }
        .task { refreshBackupSummary() }
        .sheet(isPresented: $showRestoreSheet, onDismiss: { refreshBackupSummary() }) {
            RestoreSheet()
        }
        .sheet(isPresented: $showGlobalExportSheet) {
            if let pm = profileManager {
                GlobalExportSheet(profileManager: pm)
            }
        }
        .sheet(isPresented: $showGlobalImportSheet) {
            GlobalImportSheet()
        }
        .alert("开启自动备份", isPresented: $showBackupOnboarding) {
            Button("取消", role: .cancel) {}
            Button("开启") {
                backupAutoEnabled = true
                triggerFirstBackup()
            }
        } message: {
            Text("时间机器会在你切后台时自动写一份对话快照到 iCloud。\n\n约占用 50-200 MB, 保留最近 30 天(macOS Time Machine 同款稀疏: 7 天内每天 / 7-30 天每周)。\n出事时能从这里回到某天的状态。\n\n点开启会立即跑一次首次备份。")
        }
        .sheet(isPresented: $backupRunning) {
            backupProgressView
        }
        .alert("备份完成", isPresented: Binding(
            get: { backupDoneMessage != nil },
            set: { if !$0 { backupDoneMessage = nil } }
        )) {
            Button("好") { backupDoneMessage = nil }
        } message: {
            Text(backupDoneMessage ?? "")
        }
        .alert("批量导出", isPresented: Binding(
            get: { exportResultMessage != nil },
            set: { if !$0 { exportResultMessage = nil } }
        )) {
            Button("好", role: .cancel) { exportResultMessage = nil }
        } message: {
            Text(exportResultMessage ?? "")
        }
        .alert("清空 Claude 数据", isPresented: $wipeConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { runClaudeWipe() }
        } message: {
            Text(wipeAlertMessage)
        }
    }

    /// 两端共用的一份 body（刀 3 合流：主干取原 iOS 真身，mac 独有的活按钮 / 脚注按 §2.4 例外包回来）
    var pageBody: some View {
        // 搜索锚点：命中叶子条目时滚到那一行
        ScrollViewReader { anchorProxy in
        SettingsSectionList(.list) {
            Section("导入") {
                Button(action: { showImporter = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("导入对话")
                        Spacer()
                    }
                    .font(m.secondary)
                    .foregroundColor(Theme.branchIndicator)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .searchAnchor("leaf-data-import")

                // #057 粟粟 10-14 暂停：代码保留，入口灰掉
                Button(action: { showBackfill = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.badge.arrow.down")
                        Text("补原图")
                        Spacer()
                        Text("暂停")
                    }
                    .font(m.secondary)
                    .foregroundColor(Theme.textMuted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(true)
                .searchAnchor("leaf-data-backfill")

                Text("支持 ChatGPT / Claude 导出包（zip / 文件夹 / json）。导出包里没给的图先留占位")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("导出对话数据") {
                VStack(spacing: 4) {
                    ExportModeRow(title: "轻量模式", description: "自动选择最长分支导出", isSelected: exportMode == "lightweight") {
                        exportMode = "lightweight"
                    }
                    ExportModeRow(title: "全面模式", description: "导出时可选路径，分支用折叠显示", isSelected: exportMode == "full") {
                        exportMode = "full"
                    }
                }

                if isExportingAll {
                    VStack(spacing: 6) {
                        ProgressView(value: exportProgress, total: Double(exportTotal))
                            .tint(Theme.branchIndicator)
                        Text("导出中 \(Int(exportProgress))/\(exportTotal)")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                } else {
                    #if os(macOS)
                    // mac 走 NSOpenPanel 真能导（iOS 侧还没有对应的展示器，见 #else）
                    Button(action: { exportAllConversations() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up.on.square")
                                .font(ShellStyle.secondaryFont)
                            Text("导出本楼层对话")
                                .font(ShellStyle.secondaryFont)
                        }
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    #else
                    // iOS 批量导出未实现（exportAllConversations 在 iOS 是 no-op）
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up.on.square")
                        Text("导出本楼层对话")
                        Spacer()
                        Text("即将支持")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.accent.opacity(0.4)))
                    }
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textMuted)
                    .searchAnchor("leaf-data-exportfloor")
                    #endif
                }

                if isExportingAllProfiles {
                    VStack(spacing: 6) {
                        ProgressView(value: exportAllProfilesProgress, total: Double(exportAllProfilesTotal))
                            .tint(Theme.branchIndicator)
                        Text("全部楼层导出中 \(Int(exportAllProfilesProgress))/\(exportAllProfilesTotal)")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                } else {
                    #if os(macOS)
                    Button(action: { exportAllProfilesData() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "archivebox")
                                .font(ShellStyle.secondaryFont)
                            Text("导出全部对话")
                                .font(ShellStyle.secondaryFont)
                        }
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    #else
                    // iOS 批量导出未实现（exportAllProfilesData 在 iOS 是 no-op）——
                    // 死按钮换明示，别让用户点了没反应以为是 bug
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox")
                        Text("导出全部对话")
                        Spacer()
                        Text("即将支持")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.accent.opacity(0.4)))
                    }
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textMuted)
                    .searchAnchor("leaf-data-exportall")
                    #endif
                }

                #if os(macOS)
                // 侧栏右键菜单是 mac-only 交互，iOS 没有右键
                Text("右键对话可单独导出为 Markdown")
                    .font(ShellStyle.secondaryFont)
                    .foregroundColor(Theme.textMuted)
                #endif
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                Button {
                    showGlobalExportSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("导出全量备份")
                                .font(m.secondary)
                                .foregroundColor(Theme.branchIndicator)
                            Text("整包打成 .mpb 单文件 — 换机或备灾用")
                                .font(.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .searchAnchor("leaf-data-backup")

                Button {
                    showGlobalImportSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("从备份恢复")
                                .font(m.secondary)
                                .foregroundColor(.orange)
                            Text("覆盖当前所有数据；重启后完成切换")
                                .font(.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .searchAnchor("leaf-data-restore")
            } header: {
                Text("全量备份")
            } footer: {
                Text("包含楼层、对话、记忆、贴纸、\(Self.audiobookMention)文件库、主题。API key 不进包（导入后需重输）。")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                ImportHistoryView(profileId: profileManager?.currentProfile.id ?? "")
            } header: {
                Text("导入历史").searchAnchor("leaf-data-history")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("同步") {
                syncSectionContent
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // section 级条目的锚点挂在 header 上（这一节的行归「自动备份」等叶子条目）
            Section {
                timeMachineSectionContent
            } header: {
                Text("⏰ 时间机器").searchAnchor("leaf-data-timemachine")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                storageSectionContent
            } header: {
                Text("存储").searchAnchor("leaf-data-storage")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                claudeWipeSectionContent
            } header: {
                Text("开发（危险操作）").searchAnchor("leaf-data-danger")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("数据与备份")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .settingsAnchorScroll(anchorProxy)
        .sheet(isPresented: $showImporter) {
            ImportView()
                #if os(iOS)
                .presentationDetents([.large])
                #endif
        }
        .sheet(isPresented: $showBackfill) {
            ImageBackfillView()
                #if os(iOS)
                .presentationDetents([.large])
                #endif
        }
        }
    }

    private func exportAllConversations() {
        #if os(iOS)
        return // iOS: 暂不支持批量导出
        #else
        let panel = NSOpenPanel()
        panel.title = "选择导出文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        let pid = profileManager?.currentProfile.id ?? ""
        var descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\Conversation.updateTime, order: .reverse)]
        )
        descriptor.predicate = #Predicate<Conversation> { conv in conv.profileId == pid && conv.isTrashed == false }
        guard let conversations = try? modelContext.fetch(descriptor) else { return }

        let convData = conversations.map { (id: $0.id, title: $0.title, currentNodeId: $0.currentNodeId) }
        let mode: ExportPathMode = exportMode == "full" ? .fullTree : .longest
        let uName = userName
        let aName = assistantName
        let container = modelContext.container
        let scopedPid = pid

        exportTotal = convData.count
        exportProgress = 0
        isExportingAll = true

        DispatchQueue.global(qos: .userInitiated).async {
            let bgContext = ModelContext(container)
            var usedNames = Set<String>()
            var failCount = 0

            for (i, data) in convData.enumerated() {
                let cid = data.id
                let convDescriptor = FetchDescriptor<Conversation>(
                    predicate: #Predicate<Conversation> { conv in conv.id == cid && conv.profileId == scopedPid }
                )
                guard let conversation = try? bgContext.fetch(convDescriptor).first else { continue }

                let markdown = MarkdownExporter.loadAndExport(
                    conversation: conversation,
                    context: bgContext,
                    mode: mode,
                    userName: uName,
                    assistantName: aName
                )

                let baseName = MarkdownExporter.sanitizedFileName(data.title)
                var fileName = baseName
                var counter = 1
                while usedNames.contains(fileName) {
                    fileName = "\(baseName)-\(counter)"
                    counter += 1
                }
                usedNames.insert(fileName)

                let fileURL = folderURL.appendingPathComponent("\(fileName).md")
                do {
                    try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
                } catch {
                    failCount += 1
                }

                DispatchQueue.main.async { exportProgress = Double(i + 1) }
            }

            let failed = failCount
            DispatchQueue.main.async {
                isExportingAll = false
                exportResultMessage = failed > 0 ? "导出完成，\(failed) 个文件写入失败" : "导出完成"
            }
        }
        #endif
    }

    /// 遍历所有楼层，按「根目录/{楼层名}/*.md」输出。
    private func exportAllProfilesData() {
        #if os(iOS)
        return // iOS: 暂不支持批量导出
        #else
        guard let profileManager else { return }
        let profiles = profileManager.profiles
        guard !profiles.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = "选择导出根目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let rootURL = panel.url else { return }

        let mode: ExportPathMode = exportMode == "full" ? .fullTree : .longest
        exportAllProfilesTotal = profiles.count
        exportAllProfilesProgress = 0
        isExportingAllProfiles = true

        let unifiedContainer = modelContext.container
        DispatchQueue.global(qos: .userInitiated).async {
            var failCount = 0
            for (profileIndex, profile) in profiles.enumerated() {
                // 路线 B 单 container：用 unified container + profileId predicate 遍历
                let bgContext = ModelContext(unifiedContainer)
                let pid = profile.id

                var descriptor = FetchDescriptor<Conversation>(
                    sortBy: [SortDescriptor(\Conversation.updateTime, order: .reverse)]
                )
                descriptor.predicate = #Predicate<Conversation> { conv in conv.profileId == pid && conv.isTrashed == false }
                guard let conversations = try? bgContext.fetch(descriptor) else {
                    DispatchQueue.main.async { exportAllProfilesProgress = Double(profileIndex + 1) }
                    continue
                }

                let folderName = MarkdownExporter.sanitizedFileName(profile.name)
                let profileFolder = rootURL.appendingPathComponent(folderName, isDirectory: true)
                try? FileManager.default.createDirectory(at: profileFolder, withIntermediateDirectories: true)

                var usedNames = Set<String>()
                let uName = profile.userName.isEmpty ? "你" : profile.userName
                let aName = profile.assistantName.isEmpty ? "助手" : profile.assistantName

                for conv in conversations {
                    let markdown = MarkdownExporter.loadAndExport(
                        conversation: conv,
                        context: bgContext,
                        mode: mode,
                        userName: uName,
                        assistantName: aName
                    )

                    let baseName = MarkdownExporter.sanitizedFileName(conv.title)
                    var fileName = baseName
                    var counter = 1
                    while usedNames.contains(fileName) {
                        fileName = "\(baseName)-\(counter)"
                        counter += 1
                    }
                    usedNames.insert(fileName)

                    let fileURL = profileFolder.appendingPathComponent("\(fileName).md")
                    do {
                        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
                    } catch {
                        failCount += 1
                    }
                }

                DispatchQueue.main.async { exportAllProfilesProgress = Double(profileIndex + 1) }
            }

            let failed = failCount
            DispatchQueue.main.async {
                isExportingAllProfiles = false
                exportResultMessage = failed > 0 ? "导出完成，\(failed) 个文件写入失败" : "导出完成"
            }
        }
        #endif
    }
}

// MARK: - Export Mode Row

struct ExportModeRow: View {
    @Environment(\.settingsMetrics) private var m
    let title: String
    let description: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(m.body)
                    .foregroundColor(isSelected ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Text(description)
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Theme.accent.opacity(0.4) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
