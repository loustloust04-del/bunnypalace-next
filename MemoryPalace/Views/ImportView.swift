import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 导入聊天记录（#043）：一个入口收 Claude（新旧三代）/ ChatGPT / Gemini（#047，实验性）的 zip、文件夹、单个文件，自动识别。
/// 选包 → 识别中 → 预览（勾选每类去哪）→ 导入中 → 完成。小样：docs/design-import-ui.html
struct ImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var session = ImportSession()
    @State private var showFilePicker = false
    @State private var showHowTo = false
    /// 下载页里已经在浏览器打开过的包（链接可能只能用一次，提醒别重复点）
    @State private var openedPackages: Set<String> = []
    /// ②在花园里登录自动下（#059）：点开风险说明 / 正在用的下载器（关下载页就丢，登录跟着丢）
    @State private var showAutoDownloadRisk = false
    @State private var downloader: ClaudeExportDownloader?
    /// 过期按这个时间判：点按钮时刷新（页面停久了清单会过期）
    @State private var downloadCheckedAt = Date()

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        let _ = themeManager?.themeChangeID
        Group {
            #if os(iOS)
            iOSBody
            #else
            macOSBody
            #endif
        }
        .fileImporter(
            isPresented: $showFilePicker,
            // .data：AI Studio 的文件没有扩展名
            allowedContentTypes: [.zip, .json, .folder, .html, .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): session.open(urls, container: modelContext.container, profileId: profileId)
            case .failure(let error): session.fail("选文件出错：\(error.localizedDescription)")
            }
        }
        .interactiveDismissDisabled(session.isBusy)
        .onAppear { ImportSession.cleanupStaleStaging() }
        .onDisappear {
            closeDownloader()
            session.reset()
        }
        .onChange(of: session.phase) { _, phase in
            if phase != .download { closeDownloader() }
            if phase == .download { downloadCheckedAt = Date() }
            if phase == .scanning { openedPackages = [] }
        }
        .onChange(of: downloader?.isFinished ?? false) { _, finished in
            if finished { importDownloaded() }
        }
    }

    // MARK: - 容器

    #if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            List { content }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Theme.sidebarBg)
                .navigationTitle("导入聊天记录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                            .foregroundColor(session.isBusy ? Theme.textMuted : Theme.branchIndicator)
                            .disabled(session.isBusy)
                    }
                }
        }
    }
    #else
    private var macOSBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text("导入聊天记录")
                    .font(.title3.weight(.medium))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("关闭") { dismiss() }
                    .disabled(session.isBusy)
            }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 440, idealHeight: 560)
        .background(Theme.mainBg)
    }
    #endif

    // MARK: - 各状态

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle: pickContent
        case .scanning: busyGroup("正在识别", "正在解开导出包…大包要十几秒。")
        case .preview: previewContent
        case .download: downloadContent
        case .importing: importingContent
        case .done: doneContent
        case .failed(let message): failedContent(message)
        }
    }

    @ViewBuilder
    private var pickContent: some View {
        group(nil) {
            Text("选 Claude、ChatGPT 或 Gemini 的导出包，或 RikkaHub、Kelivo 的备份 zip。zip、解压出来的文件夹、单个导出文件都行（AI Studio 的文件没有扩展名也行），可以一次多选。")
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        primaryButton("选择导出包", enabled: true) { showFilePicker = true }
        group("怎么拿到导出包", footer: "只在本机读文件，不联网。") {
            DisclosureGroup("Claude", isExpanded: $showHowTo) {
                howToText("claude.ai › 设置 › 隐私 › 导出数据。邮件里的链接 24 小时内有效；新版会给好几个 zip，全部下载后一起选进来（或选它们所在的文件夹）。")
            }
            .font(.system(size: Theme.F.body))
            .foregroundColor(Theme.textPrimary)
            DisclosureGroup("ChatGPT") {
                howToText("两种导法，都能导：\n① 全包（带图片和上传的文件）：privacy.openai.com › Download my data。邮件里下载的大 zip 里套着好几个 zip，直接选外面那个。\n② 只有对话：chatgpt.com › 设置 › 数据控制 › 导出数据。邮件里下载 zip，直接选这个 zip。")
            }
            .font(.system(size: Theme.F.body))
            .foregroundColor(Theme.textPrimary)
            DisclosureGroup("Gemini（实验性）") {
                howToText("takeout.google.com 里只勾「我的活动」，在它的选项里只留 Gemini Apps，格式选 JSON（HTML 也能读，但更容易认不全）。下载的 zip 直接选进来。导出里没有会话编号的问答，会按时间间隔推测分段。")
            }
            .font(.system(size: Theme.F.body))
            .foregroundColor(Theme.textPrimary)
            DisclosureGroup("AI Studio（实验性）") {
                howToText("AI Studio 的对话存在 Google Drive 的「Google AI Studio」文件夹里：把文件下载下来直接选（没有扩展名也行），或者用 Takeout 导出 Drive 后选 zip。")
            }
            .font(.system(size: Theme.F.body))
            .foregroundColor(Theme.textPrimary)
            DisclosureGroup("RikkaHub（实验性）") {
                howToText("在 RikkaHub（安卓）的备份设置里导出本地备份，记得包含数据库；把 zip 传到这台设备再选它。设置和 API key 不会导入。")
            }
            .font(.system(size: Theme.F.body))
            .foregroundColor(Theme.textPrimary)
            DisclosureGroup("Kelivo") {
                howToText("Kelivo › 设置 › 数据备份：在「备份管理」里勾上「聊天记录」，要带图片再勾「文件」（新版在「备份与导入内容」里勾，供应商、MCP 这些不用勾，反正不导）；然后「本地备份」›「导出为文件」，把 zip 传到这台设备再选它。新旧两代备份都认，设置和 API key 不会导入。")
            }
            .font(.system(size: Theme.F.body))
            .foregroundColor(Theme.textPrimary)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let scan = session.scan {
            let p = session.preview
            if session.hasClaude {
                group("识别到 · Claude", footer: libraryFootnote(scan)) {
                    if !scan.claudeFiles.isEmpty {
                        checkRow("对话", claudeDetail(scan), isOn: $session.selection.claudeConversations)
                    }
                    if !scan.designChatFiles.isEmpty {
                        checkRow("设计对话", "\(scan.designChatFiles.count) 段 → 本楼层"
                                 + (p.designProjects.isEmpty ? "" : "，归进同名文件夹"),
                                 isOn: $session.selection.designChats)
                    }
                    if !p.projects.isEmpty {
                        checkRow("项目", "\(p.projects.count) 个 → 本楼层文件夹（带说明）；项目文档进文件库「Claude 项目」",
                                 isOn: $session.selection.projects)
                    }
                    if !p.memoryDrafts.isEmpty || !p.memoryFiles.isEmpty {
                        checkRow("记忆", memoryDetail(p), isOn: $session.selection.memories)
                    }
                    if !scan.artifactDirs.isEmpty {
                        checkRow("Artifacts", "\(scan.artifactDirs.count) 个，只取当前版本 → 文件库「Claude Artifacts」",
                                 isOn: $session.selection.artifacts)
                    }
                }
            }
            ForEach(session.presentSources) { source in
                group("识别到 · \(source.label)", footer: source.footnote(scan, p)) {
                    ForEach(source.shownRows(scan, p), id: \.row.key) { item in
                        checkRow(item.row.title, item.detail, isOn: $session.selection[item.row.key])
                    }
                }
            }
            let notes = previewNotes(scan)
            if !notes.isEmpty {
                group(nil) {
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if session.claudeManifest != nil, !scan.missingFromManifest.isEmpty {
                secondaryButton("去下载没选到的包") { session.showDownload() }
            }
            let conflicts = session.conflictReport
            if !conflicts.isEmpty {
                group("已在其他楼层 · \(conflicts.total) 段", footer: conflictFooter(conflicts)) {
                    ForEach(conflicts.floors, id: \.profileId) { conflictRow($0) }
                    Picker("已在其他楼层的", selection: $session.copyConflicts) {
                        Text("跳过").tag(false)
                        Text("复制一份到本楼层").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            group("已有对话怎么处理") {
                toggleRow("叠加导入",
                          "本地已有的对话，用文件里的版本更新：补上新消息，标题和改过的消息也以文件为准。导入前留快照，可在导入历史撤回。关掉则已有对话不动。",
                          isOn: $session.merge)
            }
            primaryButton("开始导入", enabled: !session.nothingSelected) {
                let floors = Dictionary((profileManager?.profiles ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                session.start(container: modelContext.container, profileId: profileId, floorNames: floors)
            }
            secondaryButton("重新选") {
                session.reset()
                showFilePicker = true
            }
        }
    }

    /// 预览页冲突分组的一行：哪个楼层几段，楼层还在就能「去看看」（切过去、关掉导入页）
    @ViewBuilder
    private func conflictRow(_ floor: ImportConflictReport.Floor) -> some View {
        let profile = profileManager?.profiles.first { $0.id == floor.profileId }
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.map { "「\($0.name)」\(floor.count) 段" } ?? "已删除的楼层 \(floor.count) 段")
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if profile == nil {
                    Text("删楼层时没删数据：你看不到它们，但它们会挡住导入。")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if floor.trashed > 0 {
                    Text("其中 \(floor.trashed) 段在那边的回收站里")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                }
            }
            Spacer()
            if let profile {
                Button("去看看") {
                    profileManager?.switchTo(profile)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.branchIndicator)
            }
        }
    }

    private func conflictFooter(_ report: ImportConflictReport) -> String {
        var text = session.copyConflicts
            ? "复制：本楼层多一份，原楼层不动，可在导入历史撤回。"
            : "跳过：这些对话留在原楼层，本楼层看不到也搜不到。"
        if report.copiedHere > 0 { text += "其中 \(report.copiedHere) 段本楼层已经有副本，选复制也不会再多一份。" }
        return text
    }

    /// 「已在其他楼层」说在哪几个楼层（#061）
    private func conflictDetail(_ c: ImportCounts) -> String {
        let names = Dictionary((profileManager?.profiles ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var deleted = 0
        var parts: [String] = []
        for (pid, count) in c.conflictsByProfile.sorted(by: { $0.value > $1.value }) {
            if let name = names[pid] { parts.append("「\(name)」\(count)") } else { deleted += count }
        }
        if deleted > 0 { parts.append("已删除的楼层 \(deleted)") }
        var text = parts.isEmpty ? "" : parts.joined(separator: "、") + "。"
        if c.conflictsTrashed > 0 { text += "其中 \(c.conflictsTrashed) 段在那边的回收站里。" }
        if deleted > 0 { text += "已删除楼层里的是删楼层时没删的数据，看不到，但会挡住导入。" }
        text += "这些没动。"
        // 预览里没查到的那几段是消息 id 撞了别的楼层，预览不显示复制选项（sol #1）
        let unseen = c.conflicts - session.previewConflicts
        if session.previewConflicts > 0 { text += "想要一份就重新导入，在「已在其他楼层」那一段选「复制一份到本楼层」。" }
        if unseen > 0 { text += "其中 \(unseen) 段是里面的消息撞了别的楼层，导入前查不出来，只能跳过。" }
        return text
    }

    @ViewBuilder
    private var importingContent: some View {
        group("正在导入", footer: "大包要几分钟，别关这个页面。") {
            VStack(alignment: .leading, spacing: 8) {
                Text(session.stage?.rawValue ?? "准备中")
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                ProgressView(value: max(session.stageProgress, 0.02))
                    .tint(Theme.branchIndicator)
                ForEach(session.stages, id: \.self) { stage in
                    let index = session.stages.firstIndex(of: stage) ?? 0
                    let current = session.stage.flatMap { session.stages.firstIndex(of: $0) } ?? 0
                    Text(stage.rawValue)
                        .font(.system(size: Theme.F.secondary, weight: index == current ? .medium : .regular))
                        .foregroundColor(index < current ? Theme.textMuted : index == current ? Theme.textPrimary : Theme.textSecondary)
                        .strikethrough(index < current, color: Theme.textMuted)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var doneContent: some View {
        let s = session.summary
        let c = s.conversations
        if let failure = s.failure {
            group("没导完") {
                let lines = s.failures.isEmpty ? [(step: s.failedStep ?? "", message: failure)] : s.failures
                Text(lines.map { "「\($0.step)」这步出错：\($0.message)。" }.joined(separator: "\n")
                     + "\n已经导进来的部分可以在导入历史撤回。")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        let conversationRows = [
            ResultLine(title: "新增", count: c.added, detail: nil),
            ResultLine(title: "复制为副本", count: c.copied, detail: "原本在其他楼层，复制了一份到本楼层；原楼层没动。"),
            ResultLine(title: "更新", count: c.updated, detail: "本地已有，用文件里的版本更新了（可撤回）。"),
            ResultLine(title: "本地已有，跳过", count: c.skipped, detail: nil),
            ResultLine(title: "已在其他楼层", count: c.conflicts, detail: conflictDetail(c)),
            ResultLine(title: "未导入", count: c.ignored, detail: "空白草稿或没有有效内容。"),
        ].filter { $0.count > 0 }
        if !conversationRows.isEmpty {
            group("对话") {
                ForEach(conversationRows) { resultRow($0.title, "\($0.count)", $0.detail) }
            }
        }
        if s.foldersCreated + s.foldersExisting > 0 {
            group("文件夹") {
                if s.foldersCreated > 0 { resultRow("新建", "\(s.foldersCreated)", "项目指令放进了「文件夹说明」。") }
                if s.foldersExisting > 0 { resultRow("已有，没动", "\(s.foldersExisting)", nil) }
            }
        }
        if let r = s.rikkaHub, r.foldersCreated + r.foldersExisting + r.memoriesAdded + r.memoriesExisting > 0 {
            group("RikkaHub 文件夹和记忆") {
                if r.foldersCreated > 0 { resultRow("新建文件夹", "\(r.foldersCreated)", "按助手 / RikkaHub 文件夹分，说明留空。") }
                if r.foldersExisting > 0 { resultRow("文件夹已有，没动", "\(r.foldersExisting)", nil) }
                if r.memoriesAdded > 0 { resultRow("新增记忆", "\(r.memoriesAdded) 条", "来源记为 RikkaHub 导入，没钉住，园丁会照常整理。") }
                if r.memoriesExisting > 0 { resultRow("记忆已有，跳过", "\(r.memoriesExisting) 条", nil) }
            }
        }
        if s.memoriesAdded + s.memoriesExisting > 0 {
            group("花园记忆") {
                if s.memoriesAdded > 0 { resultRow("新增", "\(s.memoriesAdded) 条", "来源记为 Claude 导入，没钉住，园丁会照常整理。") }
                if s.memoriesExisting > 0 { resultRow("已有，跳过", "\(s.memoriesExisting) 条", nil) }
            }
        }
        let lib = s.library
        if lib.written + lib.existing + lib.failed.count + s.librarySkipped.count > 0 {
            group("文件库") {
                if lib.written > 0 { resultRow("写入", "\(lib.written) 个文件", nil) }
                if lib.existing > 0 { resultRow("同名已有，没覆盖", "\(lib.existing)", nil) }
                if !s.librarySkipped.isEmpty { resultRow("跳过", "\(s.librarySkipped.count)", "不是文本文件，或缺当前版本。") }
                if !lib.failed.isEmpty { resultRow("写失败", "\(lib.failed.count)", lib.failed.prefix(3).joined(separator: "、")) }
            }
        }
        let partial = s.failure != nil || !lib.failed.isEmpty
        let rikkaAdded = (s.rikkaHub?.foldersCreated ?? 0) + (s.rikkaHub?.memoriesAdded ?? 0)
        if conversationRows.isEmpty && s.foldersCreated + s.memoriesAdded + lib.written + rikkaAdded == 0 && !partial
            && s.librarySkipped.isEmpty {
            group(nil) {
                Text("没有新变化：这些内容本楼层都已经有了。")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        if !s.warnings.isEmpty {
            group("注意事项") {
                DisclosureGroup("\(s.warnings.reduce(0) { $0 + $1.count }) 条，点开看") {
                    ForEach(s.warnings, id: \.title) { w in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(w.title)（\(w.count)）")
                                .font(.system(size: Theme.F.secondary))
                                .foregroundColor(Theme.textPrimary)
                            if !w.examples.isEmpty {
                                Text(w.examples.joined(separator: "、"))
                                    .font(.system(size: Theme.F.caption))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textSecondary)
            }
        }
        group(nil, footer: "可在 数据与备份 › 导入历史 整次撤回（对话、记忆、文件夹一起撤）；文件库里的文件不随撤回删除。") {
            ForEach(s.notes, id: \.self) { note in
                Text(note)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        primaryButton("完成", enabled: true) { dismiss() }
        if partial {
            secondaryButton("重新选") {
                session.reset()
                showFilePicker = true
            }
        }
    }

    @ViewBuilder
    private func failedContent(_ message: String) -> some View {
        group("没导成") {
            Text(message)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        primaryButton("重新选", enabled: true) {
            session.reset()
            showFilePicker = true
        }
    }

    // MARK: - 下载清单里的包（#059 ①：系统浏览器下，链接不复制、不进日志）

    @ViewBuilder
    private var downloadContent: some View {
        if let manifest = session.claudeManifest {
            if manifest.isExpired(now: downloadCheckedAt) {
                group("从 claude.ai 下载导出包") {
                    Text("这份清单已经过期（\(exportedAt(manifest))，链接 24 小时内有效）。回 claude.ai › 设置 › 隐私 › 导出数据 重新导出，邮件里会有新的清单和链接。")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                group("从 claude.ai 下载导出包", footer: "要先在浏览器里登录 claude.ai。下好的 zip 在「下载」文件夹（iPhone / iPad 在「文件 › 下载」），回来点「下好了」把它们一起选进来。") {
                    Text(downloadHeader(manifest))
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(manifest.packages) { downloadRow($0) }
                }
                if downloader?.hasStarted != true {
                    primaryButton("下好了，选文件夹导入", enabled: true) {
                        session.reset()
                        showFilePicker = true
                    }
                }
                autoDownloadSection(manifest)
            }
            secondaryButton(session.scan == nil ? "重新选" : "返回预览") {
                if session.scan == nil {
                    session.reset()
                    showFilePicker = true
                } else {
                    session.leaveDownload()
                }
            }
        }
    }

    private func downloadRow(_ package: ClaudeExportManifest.Package) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(package.categoryName)
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(package.isNeeded ? Theme.textPrimary : Theme.textMuted)
                Text(package.filename)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
            Spacer()
            if !package.isNeeded {
                Text("不用下")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            } else if let scan = session.scan, !scan.missingFromManifest.contains(package.filename) {
                Text("这次选进来了")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            } else if let downloader, downloader.hasStarted {
                downloadStatus(downloader.statuses[package.id] ?? .waiting)
            } else if openedPackages.contains(package.id) {
                Text("已在浏览器打开")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            } else {
                Button("在浏览器里下载") {
                    downloadCheckedAt = Date()
                    guard session.claudeManifest?.isExpired(now: downloadCheckedAt) == false else { return }
                    openedPackages.insert(package.id)
                    openURL(package.url)
                }
                .font(.system(size: Theme.F.secondary, weight: .medium))
                .foregroundColor(Theme.branchIndicator)
                .buttonStyle(.plain)
            }
        }
    }

    private func downloadStatus(_ status: ClaudeExportDownloader.Status) -> some View {
        let text: String
        var color = Theme.textMuted
        switch status {
        case .waiting: text = "等待"
        case .downloading(let f): text = f > 0 ? "下载中 \(Int(f * 100))%" : "下载中"
        case .done: text = "下好了"
        case .failed(let failure):
            text = failure.message
            color = Theme.danger
        }
        return Text(text)
            .font(.system(size: Theme.F.caption))
            .foregroundColor(color)
            .multilineTextAlignment(.trailing)
    }

    /// ②：默认收起；看过风险说明点「我了解，继续」才开登录页（粟粟 10-10 D3）
    @ViewBuilder
    private func autoDownloadSection(_ manifest: ClaudeExportManifest) -> some View {
        if let downloader {
            if !downloader.hasStarted || downloader.needsLogin {
                group("在花园里登录 claude.ai", footer: "卡住了（Cloudflare 验证转圈、Google 登录被拒）？点「关掉」，改用上面的浏览器下载。") {
                    if downloader.needsLogin {
                        Text("还没登录上：登好再点「登好了，开始下载」。")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.danger)
                    }
                    ClaudeLoginWebView(webView: downloader.webView)
                        .frame(height: 460)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                primaryButton("登好了，开始下载", enabled: true) {
                    downloadCheckedAt = Date()
                    if !manifest.isExpired(now: downloadCheckedAt) { downloader.start() }
                }
                secondaryButton("关掉") {
                    closeDownloader()
                    showAutoDownloadRisk = false
                }
            } else if downloader.isRunning {
                busyGroup("正在下载", "一个一个下到花园的临时目录，全部下完自动进预览。")
                secondaryButton("停下") {
                    closeDownloader()
                    showAutoDownloadRisk = false
                }
            } else if downloader.downloaded.isEmpty {
                group(nil) {
                    Text("一个都没下下来。链接可能已经用过或过期，回 claude.ai 重新导出后再试，或者关掉这里、改用浏览器下载。")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                secondaryButton("关掉") {
                    closeDownloader()
                    showAutoDownloadRisk = false
                }
            }
        } else {
            group(nil) {
                DisclosureGroup("在花园里登录 claude.ai 自动下载（有风险）", isExpanded: $showAutoDownloadRisk) {
                    howToText("会在花园里打开 claude.ai 的登录页。你的登录只在这个页面开着时有效，关掉就丢，不会存下来，也不会给 AI 用。\n用 Google 账号登录可能会被拒绝，换邮箱验证码登录；Cloudflare 验证可能卡住。\n每个链接可能只能用一次，下失败了要回 claude.ai 重新导出。")
                    HStack(spacing: 16) {
                        Spacer()
                        Button("算了") { showAutoDownloadRisk = false }
                            .foregroundColor(Theme.textSecondary)
                        Button("我了解，继续") {
                            downloader = ClaudeExportDownloader(manifest: manifest, only: session.scan.map { Set($0.missingFromManifest) })
                        }
                            .foregroundColor(Theme.branchIndicator)
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: Theme.F.secondary))
                    .padding(.top, 6)
                }
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textPrimary)
            }
        }
    }

    private func closeDownloader() {
        downloader?.close()
        downloader = nil
    }

    /// ②全下完：有下好的就扫进预览（没下下来的在预览里灰字说）；一个都没有就留在下载页
    private func importDownloaded() {
        guard let downloader, !downloader.downloaded.isEmpty else { return }
        let (dir, files) = downloader.handOff()
        let missing = downloader.failed
        closeDownloader()
        session.openDownloaded(dir, files: files, missing: missing, container: modelContext.container, profileId: profileId)
    }

    private func exportedAt(_ manifest: ClaudeExportManifest) -> String {
        manifest.createdAt.map { "导出于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "清单没写导出时间"
    }

    private func downloadHeader(_ manifest: ClaudeExportManifest) -> String {
        let left = manifest.hoursLeft().map { $0 < 1 ? "，不到 1 小时就过期" : "，还剩约 \($0) 小时" } ?? "，链接导出后 24 小时内有效"
        return exportedAt(manifest) + left + "。每个链接可能只能用一次，点过一次就别再点；下失败了只能回 claude.ai 重新导出。"
    }

    private struct ResultLine: Identifiable {
        let title: String
        let count: Int
        let detail: String?
        var id: String { title }
    }

    // MARK: - 文案

    private func claudeDetail(_ scan: ExportPackageScan) -> String {
        let mb = Double(session.preview.claudeBytes) / 1_048_576
        var text = "\(scan.claudeConversationCount) 段 · \(scan.claudeFiles.count) 个文件"
        if mb >= 1 { text += String(format: " · %.0f MB", mb) }
        text += " → 本楼层"
        if scan.duplicateConversationCount > 0 {
            text += "（\(scan.duplicateConversationCount) 段在多个文件里都有，会合成一段）"
        }
        return text
    }

    private func memoryDetail(_ p: ImportPreview) -> String {
        var parts: [String] = []
        if !p.memoryDrafts.isEmpty { parts.append("约 \(p.memoryDrafts.count) 条 → 花园记忆") }
        if !p.memoryFiles.isEmpty { parts.append("\(p.memoryFiles.count) 个记忆文件 → 文件库「Claude 记忆」") }
        return parts.joined(separator: "；")
    }

    private func libraryFootnote(_ scan: ExportPackageScan) -> String? {
        let p = session.preview
        guard !p.projects.isEmpty || !p.memoryFiles.isEmpty || !scan.artifactDirs.isEmpty else { return nil }
        let place = p.libraryInICloud ? "iCloud" : "本机"
        let floor = profileManager?.currentProfile.name ?? "本楼层"
        return "文件库：「\(floor)」的文件库（\(place)）。同名文件已存在时不覆盖。"
    }

    private func previewNotes(_ scan: ExportPackageScan) -> [String] {
        var notes: [String] = []
        var ignored = scan.ignoredLabels
        if session.hasClaude { ignored.append("系统注入文本") }
        if session.preview.gemini.otherProductCount > 0 {
            ignored.append("其他 Google 产品的活动 \(session.preview.gemini.otherProductCount) 条")
        }
        if !ignored.isEmpty { notes.append("不导入：\(ignored.joined(separator: "、"))。") }
        if !scan.missingFromManifest.isEmpty {
            notes.append("清单里有、但这次没选到：\(scan.missingFromManifest.joined(separator: "、"))")
        }
        if !session.downloadMissing.isEmpty {
            notes.append("这几个包没下下来：\(session.downloadMissing.joined(separator: "、"))。链接可能已经用过或过期，要的话回 claude.ai 重新导出。")
        }
        if !scan.unrecognized.isEmpty {
            notes.append("没认出来：\(scan.unrecognized.prefix(5).joined(separator: "、"))")
        }
        if !scan.emptyFiles.isEmpty {
            notes.append("空文件：\(scan.emptyFiles.prefix(5).joined(separator: "、"))")
        }
        if !scan.rikkaHubSettingsOnly.isEmpty {
            notes.append("只有设置、没带聊天数据库的 RikkaHub 备份，不导入：\(scan.rikkaHubSettingsOnly.joined(separator: "、"))")
        }
        if !scan.kelivoSettingsOnly.isEmpty {
            notes.append("没勾聊天记录、只有设置的 Kelivo 备份，不导入：\(scan.kelivoSettingsOnly.joined(separator: "、"))")
        }
        notes += session.preview.notes
        return notes
    }

    // MARK: - 小部件（iOS 是 List 的 Section / 行，mac 是卡片）

    @ViewBuilder
    private func group<C: View>(_ title: String?, footer: String? = nil, @ViewBuilder _ rows: () -> C) -> some View {
        #if os(iOS)
        Section {
            rows()
        } header: {
            if let title { Text(title) }
        } footer: {
            if let footer { Text(footer).font(.system(size: Theme.F.caption)) }
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)
        #else
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: Theme.F.secondary, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 10) { rows() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.sidebarBg))
            if let footer {
                Text(footer)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        #endif
    }

    private func checkRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Theme.F.label))
                    .foregroundColor(isOn.wrappedValue ? Theme.branchIndicator : Theme.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Text(detail)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.branchIndicator)
                #if os(macOS)
                .toggleStyle(.switch)
                .controlSize(.small)
                #endif
        }
    }

    private func resultRow(_ title: String, _ value: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(value)
                .font(.system(size: Theme.F.secondary, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private func busyGroup(_ title: String, _ text: String) -> some View {
        group(title) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func howToText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.F.caption))
            .foregroundColor(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func primaryButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        #if os(iOS)
        Section {
            Button(action: action) {
                HStack { Spacer(); Text(title); Spacer() }
                    .font(.system(size: Theme.F.body, weight: .semibold))
                    .foregroundColor(.white)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .listRowBackground(enabled ? Theme.branchIndicator : Theme.textMuted)
        }
        .listRowSeparator(.hidden)
        #else
        HStack {
            Spacer()
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .tint(Theme.branchIndicator)
                .disabled(!enabled)
        }
        #endif
    }

    @ViewBuilder
    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        #if os(iOS)
        Section {
            Button(action: action) {
                HStack { Spacer(); Text(title); Spacer() }
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.branchIndicator)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        #else
        HStack {
            Spacer()
            Button(title, action: action)
        }
        #endif
    }
}
