import SwiftUI
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
import SwiftStreamingMarkdown  // 流式重写 Phase 2：iOS 文件预览换 fork 渲染
#endif

// MARK: - File Library Panel (右栏文件库 tab)

struct FileLibraryPanelView: View {
    @Environment(\.chatMetrics) private var metrics
    @Environment(RightPanelNavigator.self) private var desktopNavigator: RightPanelNavigator?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    #if os(iOS)
    @Environment(\.page2AppShellTool) private var shellTool
    #endif

    @State private var files: [FileLibraryStore.FileMeta] = []
    /// 楼层记忆树（memory/ 虚拟路径，第二刀返工：当普通文件夹显示，只读；self/ 可编辑）。reload 时后台读
    @State private var memoryFiles: [FileLibraryStore.FileMeta] = []
    @State private var editingSelfMemory: SelfMemoryTarget? = nil
    /// 修全局卡顿：reload / 外部变更检查都在后台扫盘，回主线程只按最新一次的结果落状态
    @State private var reloadGeneration = 0
    @State private var externalCheckInFlight = false
    /// 外部变更检查只在面板真被看着时跑：page2 里切走 / 切回聊天时面板还挂着、不会 onDisappear（口罩实测每 5 秒一次 ~120ms）
    @State private var panelOnScreen = false
    @Environment(\.scenePhase) private var externalWatchScenePhase
    #if os(iOS)
    @Environment(\.page2AppActive) private var externalWatchAppActive
    #else
    /// page2 外壳只在 iOS；mac 面板一直算可见
    private let externalWatchAppActive = true
    #endif
    private var externalWatchActive: Bool {
        panelOnScreen && externalWatchAppActive && externalWatchScenePhase == .active
    }
    @State private var showNewFileAlert = false
    @State private var newFileName = ""
    @State private var deletingPath: String? = nil
    @State private var renamingPath: String? = nil
    @State private var renameTargetName = ""
    @State private var editingFile: EditingFile? = nil
    @State private var quickLookURL: URL? = nil
    /// R2-3b：vocab/ 词条笔记的双链点击弹词卡（不开 md 文件）。
    @State private var wikiWordCard: WikiWordCard? = nil

    struct WikiWordCard: Identifiable {
        let word: String
        var id: String { word }
    }
    #if os(iOS)
    @State private var imagePreview: LibraryImagePreview? = nil
    #endif
    @State private var previews: [String: String] = [:]   // path → 内容预览（reload 时预读）
    /// 下面四样都在 reload / 换排序时一次算好，body 和行只读
    @State private var displays: [String: FileLibraryDisplay.Entry] = [:]
    @State private var sortedFiles: [FileLibraryStore.FileMeta] = []
    @State private var folderIndex: [String: FileLibraryDisplay.FolderContents] = [:]
    @State private var fileTree: [FileTreeNode] = []
    @State private var recentFiles: [FileLibraryStore.FileMeta] = []
    /// 文件夹（含子文件夹）里最近改的 3 个文件：磨砂文件夹里露出的纸
    @State private var folderRecent: [String: [FileLibraryStore.FileMeta]] = [:]
    /// 楼层 `.memorypalace/folder-styles.json`，reload 时读一次；没记录的文件夹走默认
    @State private var folderLooks: [String: FileLibraryFolderLook] = [:]
    /// 长按「外观…」打开的文件夹
    @State private var appearanceFolder: AppearanceTarget? = nil
    /// 外观面板里那行提示（iCloud 没下载 / 表读不了时这次没改成）
    @State private var appearanceNotice: String? = nil
    struct AppearanceTarget: Identifiable { let id: String }
    @State private var operationError: String?
    @State private var searchText = ""
    @AppStorage("assistantName") private var assistantName = "助手"
    @FocusState private var searchFocused: Bool
    @AppStorage("fileLibrarySortMode") private var sortModeRaw = FileLibrarySortMode.modified.rawValue
    @AppStorage("fileLibraryViewMode") private var viewModeRaw = FileLibraryViewMode.cards.rawValue
    @State private var collapsedFolderPaths: Set<String> = []
    @State private var lastKnownFingerprint = ""
    /// 外部改动（别的设备 / iCloud）：新旧 fingerprint 行 diff 出来的路径
    @State private var externalChangedPaths: [String] = []
    /// "" = 根
    @State private var currentFolder = ""
    /// 刚被改过的文件（树里那行淡绿底，5 秒后褪）
    @State private var flashPaths: Set<String> = []
    /// 开盒转场要的格子位置 / 每层滚动位置（不触发刷新）
    @State private var flightFrames = FileLibraryFlightFrames()
    /// 开盒 / 返回转场的状态（body 不读它被观察的属性，转场不连累整页重算）
    @State private var flightState = FileLibraryFlightState()
    /// iOS 顶栏标题显示的文件夹：回到根时留着上一个名字（淡出时不先变空）
    @State private var titleFolder = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    struct EditingFile: Identifiable { let id = UUID(); let path: String; let content: String; let modifiedAt: Date?; var readOnly = false }
    struct SelfMemoryTarget: Identifiable { let slug: String; var id: String { slug } }

    var body: some View {
        fileLibraryContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolPageBackground()
        .onAppear { panelOnScreen = true; reload(then: consumeDesktopTarget) }
        .onDisappear { panelOnScreen = false }
        .onChange(of: externalWatchAppActive) { _, active in if active { reload() } }
        .onChange(of: desktopNavigator?.pendingTarget) { _, _ in consumeDesktopTarget() }
        .onChange(of: viewModeRaw) { _, _ in if viewMode == .tree { crossfade(to: "") } }
        .onChange(of: sortModeRaw) { _, _ in rebuildDerived() }
        #if os(iOS)
        .onChange(of: currentFolder, initial: true) { _, folder in
            guard let shellTool else { return }
            Page2AppBackRegistry.shared.update(shellTool, canGoBack: !folder.isEmpty) { goUp() }
        }
        #endif
        // 切楼层前清空，避免持有旧楼层的文件元数据（仿 MemoryPanelView）
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            files = []
            previews = [:]
            displays = [:]
            sortedFiles = []
            folderIndex = [:]
            fileTree = []
            recentFiles = []
            folderRecent = [:]
            folderLooks = [:]
            appearanceFolder = nil
            appearanceNotice = nil
            collapsedFolderPaths = []
            lastKnownFingerprint = ""
            externalChangedPaths = []
            currentFolder = ""
            titleFolder = ""
            flightState.reset()
            flightFrames.reset()
        }
        // 小克通过工具写文件后实时刷新
        .onReceive(NotificationCenter.default.publisher(for: .fileLibraryDidChange)) { _ in reload() }
        // 修全局卡顿：外部变更检查只在面板可见时循环（不可见就停），扫盘和比对都在后台
        .task(id: externalWatchActive) {
            guard externalWatchActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                checkForExternalChanges()
            }
        }
        .alert("新建文件", isPresented: $showNewFileAlert) {
            TextField("文件名（可含 / 子目录）", text: $newFileName)
            Button("创建") { createFile() }
            Button("取消", role: .cancel) { newFileName = "" }
        } message: {
            Text("不写扩展名时会自动补 .md 后缀")
        }
        .alert("重命名文件", isPresented: Binding(get: { renamingPath != nil }, set: { if !$0 { renamingPath = nil } })) {
            TextField("新文件名或路径", text: $renameTargetName)
            Button("重命名") { confirmRename() }
            Button("取消", role: .cancel) { renamingPath = nil; renameTargetName = "" }
        } message: {
            Text("不写扩展名时会保留原扩展名")
        }
        .confirmationDialog(
            "删除文件",
            isPresented: Binding(get: { deletingPath != nil }, set: { if !$0 { deletingPath = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { confirmDelete() }
            Button("取消", role: .cancel) { deletingPath = nil }
        } message: {
            Text(deletingPath.map { "确定删除「\($0)」吗？不可恢复。" } ?? "")
        }
        .alert("文件操作失败", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("好", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .quickLookPreview($quickLookURL)
        #if os(iOS)
        .sheet(item: $imagePreview) { preview in
            AttachmentPreviewSheet(items: [.image(name: preview.name, data: preview.data)], initialIndex: 0)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
                .presentationCornerRadius(20)
        }
        #endif
        .sheet(item: $appearanceFolder, onDismiss: { appearanceNotice = nil }) { target in
            FileLibraryFolderAppearanceSheet(
                name: folderName(target.id),
                detail: folderDetail(path: target.id),
                sheets: folderSheets(target.id),
                notice: appearanceNotice,
                look: Binding(get: { folderLook(target.id) }, set: { setFolderLook($0, for: target.id) }),
                onReset: { setFolderLook(nil, for: target.id) }
            )
        }
        .sheet(item: $editingSelfMemory) { target in
            SelfMemoryEditSheet(profileId: profileId, slug: target.slug, onChange: { reload() })
        }
        .sheet(item: $editingFile) { f in
            editorSheet(for: f)
                .sheet(item: $wikiWordCard) { card in
                    VocabWordDetailSheet(word: card.word)
                }
        }
    }

    private func editorSheet(for f: EditingFile) -> FileEditorSheet {
        FileEditorSheet(path: f.path, initialContent: f.content, initialModifiedAt: f.modifiedAt, readOnly: f.readOnly,
            currentModifiedAt: {
                FileLibraryStore.modifiedAt(f.path, profileId: profileId)
            },
            reloadExternalContent: {
                let latest = try FileLibraryStore.read(f.path, profileId: profileId)
                return ReloadedFileContent(content: latest, modifiedAt: FileLibraryStore.modifiedAt(f.path, profileId: profileId))
            },
            onSave: { newContent, baselineContent in
                // R11：按**内容哈希**判冲突，不看 mtime。mtime 秒级精度，同秒两次写会漏；
                // 反过来「碰过但内容没变」（比如另一个工具原样重写）会误报，白丢用户一次编辑。
                if FileLibraryStore.hasExternalConflict(f.path, profileId: profileId, baselineContent: baselineContent) {
                    throw NSError(domain: "FileLibrary", code: -9, userInfo: [NSLocalizedDescriptionKey: "文件已在外部修改，请关闭重开后再保存。"])
                }
                try FileLibraryStore.write(f.path, content: newContent, profileId: profileId)
                reload()
            },
            onCancel: { editingFile = nil },
            onOpenWikiLink: { target in openWikiTarget(target) }
        )
    }

    // MARK: - Header

    /// 文件库 vs 书架 切换条（顶部）
    // 书架已独立成 page2「读书」工具（ReadingPanelView，2026-07-06 粟粟点的），
    // 本 panel 回归纯文件库。

    private var fileLibraryContent: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            iosTopBar
            #else
            if inFolderPage { folderNavBar } else { rootTopBar }
            #endif
            ZStack {
                FileLibraryScrollPage(key: pageKey, frames: flightFrames, initialOffset: flightFrames.offsets[pageKey] ?? 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if inFolderPage {
                            breadcrumb
                                .modifier(intro(.rest(0)))
                        } else {
                            titleBlock
                            searchField
                        }
                        if !externalChangedPaths.isEmpty {
                            fileLibraryExternalChangeBanner
                        }
                        mainContent
                    }
                    .padding(.bottom, 28)
                }
                .id(pageKey)
                .transition(AsymmetricTransition(
                    insertion: FileLibraryPageTransition(state: flightState, inserting: true),
                    removal: FileLibraryPageTransition(state: flightState, inserting: false)
                ))
            }
            .fileLibraryFlightAnchor("page", in: flightFrames)
        }
        .modifier(FileLibraryFlightOverlay(state: flightState, frames: flightFrames))
        .coordinateSpace(.named(FileLibraryFlightFrames.space))
    }

    /// 现在这一页：文件夹页 = 文件夹路径，根 / 树 / 搜索 = ""
    private var pageKey: String { inFolderPage ? currentFolder : "" }

    private static let outCurve = out(0.28)

    private static func out(_ duration: Double) -> Animation {
        FileLibraryFlightCurve.animation(duration)
    }

    /// 被点的文件夹中心在页面里的位置（换页缩放的原点）
    private func pageAnchor(_ shell: CGRect) -> UnitPoint {
        guard let page = flightFrames.last("page"), page.width > 0, page.height > 0 else { return .center }
        let midY = shell.minY + FileLibraryFolderCard.height * FileLibraryFolderCard.u / 2
        return UnitPoint(x: (shell.midX - page.minX) / page.width, y: (midY - page.minY) / page.height)
    }

    /// 开盒转场里刚换上的这页的入场（这页的内容 / 返回键 / 标题先藏着，下一帧按时间线错开淡入）
    private func intro(_ role: FileLibraryIntroStyle.Role) -> FileLibraryIntroStyle {
        FileLibraryIntroStyle(state: flightState, page: pageKey, role: role)
    }

    private static func nextFrame() async {
        try? await Task.sleep(for: .milliseconds(16))
    }

    /// 点开文件夹：卡片模式 + 拿得到袋子位置 → 开盒转场；否则交叉淡入
    private func openFolder(_ path: String, wasOpen: Bool) {
        guard flightState.flight == nil else { return }
        guard !reduceMotion, viewMode == .cards, let shell = flightFrames.live("shell:\(path)") else {
            crossfade(to: path)
            return
        }
        // mac 指针在上面时已经张开：省掉按下 → 张开那段（从 130ms 起）
        let next = FileLibraryFolderFlight(
            direction: .open,
            folder: path,
            name: folderName(path),
            look: folderLook(path),
            papers: flightPapers(path),
            lead: wasOpen ? 130 : 0,
            pressed: wasOpen ? 0 : 1,
            shell: shell
        )
        // 藏真袋子、上飞行层、换页一次提交；新页的内容先藏着，下一帧再亮出来按时间线错开淡入
        flightState.pageMotion = .open(pageAnchor(shell))
        flightState.begin(next)
        withAnimation(Self.outCurve) {
            flightState.introduce(path)
            navigate(to: path)
        }
        Task { @MainActor in
            await Self.nextFrame()
            guard flightState.flight?.id == next.id else { return }
            flightState.reveal()
            try? await Task.sleep(for: .milliseconds(Int(max(0, FileLibraryFolderFlight.openingMs - flightState.elapsed()))))
            guard flightState.flight?.id == next.id else { return }
            flightState.setMissing(Set(next.papers.indices.filter { flightFrames.live(next.papers[$0].target.anchor) == nil }))
            try? await Task.sleep(for: .milliseconds(Int(max(0, next.duration - flightState.elapsed()))))
            guard flightState.flight?.id == next.id else { return }
            flightState.end()
        }
    }

    /// 文件夹里露出的最近 3 张纸各自落到哪：直接在这层的 → 文件卡（全是图 = 图格）；在子文件夹里的 → 那个子文件夹的袋子
    private func flightPapers(_ folder: String) -> [FileLibraryFolderFlight.Paper] {
        let sheets = folderSheets(folder)
        let files = folderIndex[folder]?.files ?? []
        let gallery = !files.isEmpty && files.allSatisfy { FileLibraryDisplay.kind(of: $0.path) == .image }
        return Array((folderRecent[folder] ?? []).prefix(3).enumerated()).compactMap { slot, meta in
            guard slot < sheets.count else { return nil }
            let target: FileLibraryFolderFlight.Target
            if FileLibraryDisplay.parentFolder(meta.path) == folder {
                target = gallery ? .cell("card:\(meta.path)") : .card("card:\(meta.path)")
            } else {
                let child = meta.path.dropFirst(folder.count + 1).split(separator: "/").first.map(String.init) ?? ""
                target = .sub("shell:\(folder)/\(child)")
            }
            return FileLibraryFolderFlight.Paper(
                slot: slot,
                sheet: sheets[slot],
                face: paperFace(meta, lines: 5),
                badge: FileLibraryDisplay.badge(meta.path),
                target: target
            )
        }
    }

    /// 换页：只留现在这层和它祖先的滚动位置——回到上层 = 回原来滚到的地方，进新的一层 = 回顶
    private func navigate(to folder: String) {
        let here = currentFolder
        flightFrames.offsets = flightFrames.offsets.filter { key, _ in
            key.isEmpty || key == here || here.hasPrefix(key + "/")
        }
        if !folder.isEmpty { titleFolder = folder }
        currentFolder = folder
    }

    @ViewBuilder
    private var mainContent: some View {
        if files.isEmpty && memoryFiles.isEmpty && !isSearching {
            emptyState
        } else if isSearching {
            if filteredFiles.isEmpty { noResultsState } else { searchResults(filteredFiles) }
        } else if viewMode == .tree {
            treeView
        } else {
            folderBody
        }
    }

    private var searchActive: Bool { searchFocused || isSearching }

    private func searchResults(_ list: [FileLibraryStore.FileMeta]) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(list.count) 个结果")
                .font(FileLibraryUI.font(12))
                .monospacedDigit()
                .foregroundColor(Theme.textMuted)
                .padding(.horizontal, metrics.fileLibHeaderInsetH + 6)
                .padding(.top, 12)
                .padding(.bottom, 8)
            FileLibraryGroupCard {
                ForEach(Array(list.enumerated()), id: \.element.path) { index, meta in
                    let entry = display(meta.path)
                    let snippet = FileLibraryDisplay.snippet(in: entry.searchText, query: query)
                        ?? entry.summary
                        ?? byteCountText(meta.bytes)
                    fileItem(meta) {
                        FileLibraryRow(
                            tile: fileTile(meta),
                            title: highlighted(entry.title, query),
                            time: FileLibraryDisplay.timeText(meta.modifiedAt),
                            footnote: meta.path,
                            divider: index > 0,
                            minHeight: 76
                        ) {
                            Text(highlighted(snippet, query))
                        }
                    }
                }
            }
            .padding(.horizontal, metrics.fileLibHeaderInsetH)
        }
    }

    private func highlighted(_ text: String, _ query: String) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }
        var from = result.startIndex
        while from < result.endIndex,
              let range = result[from...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].backgroundColor = Theme.branchIndicator.opacity(0.25)
            result[range].foregroundColor = Theme.textPrimary
            from = range.upperBound
        }
        return result
    }

    private var inFolderPage: Bool { !currentFolder.isEmpty && !isSearching && viewMode != .tree }

    private var sortMode: FileLibrarySortMode { FileLibrarySortMode(rawValue: sortModeRaw) ?? .modified }

    private var folderContents: FileLibraryDisplay.FolderContents {
        folderIndex[currentFolder] ?? FileLibraryDisplay.FolderContents(folders: [], files: [])
    }

    #if os(iOS)
    /// iOS 顶栏：根页 / 文件夹页共用一条，右边玻璃胶囊不动；返回键 / 标题按在不在文件夹页淡入淡出（开盒转场里照时间线错开）
    private var iosTopBar: some View {
        ZStack {
            Text(folderName(titleFolder))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 96)
                .modifier(intro(.nav(visible: inFolderPage, at: 260, duration: 0.28, from: CGSize(width: 0, height: 4))))
                .accessibilityHidden(!inFolderPage)
            HStack {
                Button { goUp() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
                }
                .accessibilityLabel("返回")
                .modifier(intro(.nav(visible: inFolderPage, at: 220, duration: 0.26, from: CGSize(width: -10, height: 0))))
                .allowsHitTesting(inFolderPage)
                .accessibilityHidden(!inFolderPage)
                Spacer()
                glassActionCapsule
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }
    #else
    private var folderNavBar: some View {
        let parent = FileLibraryDisplay.parentFolder(currentFolder)
        return ZStack {
            Text(folderName(currentFolder))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 96)
            HStack {
                Button { goUp() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .medium))
                        Text(parent.isEmpty ? "文件库" : folderName(parent))
                            .font(.system(size: 16))
                            .lineLimit(1)
                    }
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: 110, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                moreMenu
            }
        }
        .frame(height: 44)
        .padding(.leading, metrics.fileLibHeaderInsetH - 4)
        .padding(.trailing, metrics.fileLibHeaderInsetH)
    }
    #endif

    private var breadcrumb: some View {
        let crumbs = FileLibraryDisplay.breadcrumb(currentFolder)
        return HStack(spacing: 4) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Text("/").foregroundColor(Theme.textMuted.opacity(0.6))
                }
                Text(crumb.name)
                    .fontWeight(index < crumbs.count - 1 ? .medium : .regular)
                    .foregroundColor(index < crumbs.count - 1 ? Theme.textPrimary : Theme.textMuted)
                    .lineLimit(1)
                    .onTapGesture { crossfade(to: crumb.path) }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, metrics.fileLibHeaderInsetH + 4)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var folderBody: some View {
        let contents = folderContents
        return VStack(alignment: .leading, spacing: 0) {
            if currentFolder.isEmpty {
                recentSection
                if !contents.folders.isEmpty {
                    FileLibrarySectionHeader(title: "文件夹") { viewControls }
                    folderSection(contents.folders)
                }
                if !contents.files.isEmpty {
                    FileLibrarySectionHeader(title: "没放进文件夹的") {
                        if contents.folders.isEmpty { viewControls }
                    }
                    fileSection(contents.files)
                }
            } else {
                folderToolRow(contents)
                    .modifier(intro(.rest(1)))
                if contents.folders.isEmpty && contents.files.isEmpty {
                    folderEmptyState
                        .modifier(intro(.rest(2)))
                }
                folderSection(contents.folders, order: 2)
                if !contents.folders.isEmpty && !contents.files.isEmpty {
                    Color.clear.frame(height: 14)
                }
                fileSection(contents.files, order: 2 + contents.folders.count)
            }
        }
    }

    private var recentSection: some View {
        let recent = recentFiles
        return VStack(alignment: .leading, spacing: 0) {
            FileLibrarySectionHeader(title: "最近") { EmptyView() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 11) {
                    ForEach(recent, id: \.path) { meta in
                        let kind = FileLibraryDisplay.kind(of: meta.path)
                        fileItem(meta) {
                            FileLibraryPaperCard(
                                paper: FileLibraryPaper(face: paperFace(meta, lines: 4, snapshot: false), badge: FileLibraryDisplay.badge(meta.path),
                                                        height: 148, compact: true, warm: kind == .html),
                                caption: kind == .image || kind == .binary ? FileLibraryDisplay.fileName(meta.path) : fileTitle(meta),
                                time: FileLibraryDisplay.timeText(meta.modifiedAt)
                            )
                            .frame(width: FileLibraryUI.size(118))
                        }
                    }
                }
                .padding(.horizontal, metrics.fileLibHeaderInsetH)
                .padding(.vertical, 6)
            }
            .padding(.vertical, -6)
        }
    }

    private var viewControls: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("排序", selection: $sortModeRaw) {
                    Text("最近更新").tag(FileLibrarySortMode.modified.rawValue)
                    Text("文件名").tag(FileLibrarySortMode.name.rawValue)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 3) {
                    Text(sortMode == .modified ? "最近更新" : "文件名")
                    Image(systemName: "chevron.down")
                        .font(FileLibraryUI.font(9, .semibold))
                }
                .font(FileLibraryUI.font(12))
                .foregroundColor(Theme.textPrimary)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            FileLibrarySegment(
                selection: $viewModeRaw,
                items: FileLibraryViewMode.allCases.map { .init(id: $0.rawValue, symbol: $0.iconName, title: $0.title) }
            )
        }
    }

    private func folderToolRow(_ contents: FileLibraryDisplay.FolderContents) -> some View {
        HStack(spacing: 8) {
            Text(contents.folders.isEmpty
                 ? "\(contents.files.count) 个文件"
                 : "\(contents.files.count) 个文件 · \(contents.folders.count) 个文件夹")
                .font(FileLibraryUI.font(12))
                .monospacedDigit()
                .foregroundColor(Theme.textMuted)
            Spacer(minLength: 8)
            viewControls
        }
        .padding(.horizontal, metrics.fileLibHeaderInsetH + 6)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func folderSection(_ folders: [FileLibraryDisplay.Folder], order: Int = 0) -> some View {
        if folders.isEmpty {
            EmptyView()
        } else if viewMode == .cards {
            LazyVGrid(columns: cardColumns, spacing: 24) {
                ForEach(Array(folders.enumerated()), id: \.element.path) { index, folder in
                    let anchor = "shell:\(folder.path)"
                    FileLibraryFolderButton(
                        name: folderName(folder.path),
                        detail: folderDetail(folder),
                        look: folderLook(folder.path),
                        sheets: folderSheets(folder.path),
                        shellMark: flightState.mark(anchor)
                    ) { wasOpen in openFolder(folder.path, wasOpen: wasOpen) }
                    .fileLibraryFlightAnchor(anchor, in: flightFrames)
                    .modifier(intro(.cell(anchor, order: order + index)))
                    .contextMenu {
                        folderContextMenu(for: folder.path)
                    } preview: {
                        folderCard(folder, pose: .open)
                            .frame(width: FileLibraryUI.size(200))
                            .padding(EdgeInsets(top: 40, leading: 24, bottom: 16, trailing: 24))
                            .background(Theme.mainBg)
                    }
                }
            }
            .padding(.horizontal, metrics.fileLibHeaderInsetH)
        } else {
            FileLibraryGroupCard {
                ForEach(Array(folders.enumerated()), id: \.element.path) { index, folder in
                    folderListRow(folder, divider: index > 0)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .onTapGesture { openFolder(folder.path, wasOpen: false) }
                }
            }
            .padding(.horizontal, metrics.fileLibHeaderInsetH)
        }
    }

    @ViewBuilder
    private func fileSection(_ list: [FileLibraryStore.FileMeta], order: Int = 0) -> some View {
        if list.isEmpty {
            EmptyView()
        } else if viewMode == .cards && list.allSatisfy({ FileLibraryDisplay.kind(of: $0.path) == .image }) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(Array(list.enumerated()), id: \.element.path) { index, meta in
                    if let url = FileLibraryStore.absoluteURL(meta.path, profileId: profileId) {
                        let anchor = "card:\(meta.path)"
                        fileItem(meta) {
                            FileLibraryGalleryCell(url: url, modifiedAt: meta.modifiedAt)
                                .fileLibraryFlightAnchor(anchor, in: flightFrames)
                                .modifier(FileLibraryFlightHide(mark: flightState.mark(anchor)))
                                .modifier(intro(.cell(anchor, order: order + index)))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, metrics.fileLibHeaderInsetH)
        } else if viewMode == .cards {
            LazyVGrid(columns: cardColumns, spacing: 16) {
                ForEach(Array(list.enumerated()), id: \.element.path) { index, meta in
                    fileItem(meta) {
                        paperCard(meta)
                            .modifier(intro(.cell("card:\(meta.path)", order: order + index)))
                    }
                }
            }
            .padding(.horizontal, metrics.fileLibHeaderInsetH)
        } else {
            FileLibraryGroupCard {
                ForEach(Array(list.enumerated()), id: \.element.path) { index, meta in
                    fileItem(meta) { fileListRow(meta, divider: index > 0) }
                }
            }
            .padding(.horizontal, metrics.fileLibHeaderInsetH)
        }
    }

    private var cardColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    }

    /// `snapshot: false`（「最近」那排）：HTML 也画文字纸，118 宽下拍的整页快照认不出字
    private func paperFace(_ meta: FileLibraryStore.FileMeta, lines: Int, snapshot: Bool = true) -> FileLibraryPaper.Face {
        let entry = display(meta.path)
        let body = Array(entry.lines.prefix(lines))
        switch FileLibraryDisplay.kind(of: meta.path) {
        case .markdown, .text:
            return .text(chips: entry.chips, title: entry.title, lines: body)
        case .html:
            guard snapshot else { return .text(chips: [], title: entry.title, lines: body) }
            return .html(path: meta.path, profileId: profileId, modifiedAt: meta.modifiedAt, title: entry.title, lines: body)
        case .image:
            if let url = FileLibraryStore.absoluteURL(meta.path, profileId: profileId) { return .image(url, modifiedAt: meta.modifiedAt) }
            return .binary(symbol: fileIconName(for: meta.path), size: byteCountText(meta.bytes))
        case .binary:
            return .binary(symbol: fileIconName(for: meta.path), size: byteCountText(meta.bytes))
        }
    }

    private func paperCard(_ meta: FileLibraryStore.FileMeta) -> FileLibraryPaperCard {
        let kind = FileLibraryDisplay.kind(of: meta.path)
        return FileLibraryPaperCard(
            paper: FileLibraryPaper(face: paperFace(meta, lines: 5), badge: FileLibraryDisplay.badge(meta.path)),
            caption: kind == .image || kind == .binary ? FileLibraryDisplay.fileName(meta.path) : nil,
            time: FileLibraryDisplay.timeText(meta.modifiedAt),
            anchor: "card:\(meta.path)",
            frames: flightFrames,
            flight: flightState,
            page: pageKey
        )
    }

    /// 文件夹显示名：记忆树那几层用中文名（AI 名字取楼层变量），其余照 FileLibraryFolderStyle
    private func folderName(_ path: String) -> String {
        FileLibraryMemoryFolder.displayName(path, assistantName: assistantDisplayName)
            ?? FileLibraryFolderStyle.displayName(forFolder: path)
    }

    private var assistantDisplayName: String {
        let n = profileManager?.currentProfile.assistantName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? "助手" : n
    }

    /// 空文件夹（目前只有空着的「自己的记忆」）不显示日期
    private func folderTime(_ folder: FileLibraryDisplay.Folder) -> String {
        folder.fileCount == 0 ? "" : FileLibraryDisplay.timeText(folder.latest)
    }

    private func folderLook(_ path: String) -> FileLibraryFolderLook {
        folderLooks[path] ?? FileLibraryFolderLook.defaultLook(forFolder: path)
    }

    /// 改外观：现读磁盘最新的表只改这一条再写回，成功后用磁盘那份刷新；nil = 恢复默认（删掉这条记录）。
    /// 表还没从 iCloud 下载 / 读不了 → 这次不改，面板里提示一行。
    private func setFolderLook(_ look: FileLibraryFolderLook?, for path: String) {
        do {
            switch try FileLibraryFolderStyleStore.update(path, to: look, profileId: profileId) {
            case .saved(let table):
                folderLooks = table
                appearanceNotice = nil
            case .notDownloaded:
                appearanceNotice = "iCloud 还在同步外观设置，稍后再改"
            case .unreadable:
                appearanceNotice = "外观设置文件暂时读不了（可能另一台设备正在写），稍后再改"
            }
        } catch {
            operationError = "外观保存失败：\(error.localizedDescription)"
        }
    }

    private func folderSheets(_ path: String) -> [FileLibraryFolderSheet] {
        (folderRecent[path] ?? []).map { meta in
            switch FileLibraryDisplay.kind(of: meta.path) {
            case .image:
                if let url = FileLibraryStore.absoluteURL(meta.path, profileId: profileId) {
                    return FileLibraryFolderSheet(id: meta.path, face: .image(url, modifiedAt: meta.modifiedAt))
                }
                return FileLibraryFolderSheet(id: meta.path, face: .text(title: FileLibraryDisplay.fileName(meta.path), lines: []))
            case .binary:
                return FileLibraryFolderSheet(id: meta.path, face: .text(title: FileLibraryDisplay.fileName(meta.path), lines: []))
            case .markdown, .html, .text:
                let entry = display(meta.path)
                return FileLibraryFolderSheet(id: meta.path, face: .text(title: entry.title, lines: Array(entry.lines.prefix(3))))
            }
        }
    }

    private func folderDetail(_ folder: FileLibraryDisplay.Folder) -> String {
        folder.fileCount == 0 ? folderCountText(folder) : "\(folderCountText(folder)) · \(FileLibraryDisplay.timeText(folder.latest))"
    }

    private func folderDetail(path: String) -> String {
        guard let folder = folderIndex[FileLibraryDisplay.parentFolder(path)]?.folders.first(where: { $0.path == path }) else { return "" }
        return folderDetail(folder)
    }

    private func folderCard(_ folder: FileLibraryDisplay.Folder, pose: FileLibraryFolderCard.Pose) -> FileLibraryFolderCard {
        FileLibraryFolderCard(
            name: folderName(folder.path),
            detail: folderDetail(folder),
            look: folderLook(folder.path),
            sheets: folderSheets(folder.path),
            pose: pose
        )
    }

    private func folderCountText(_ folder: FileLibraryDisplay.Folder) -> String {
        if folder.path == FileLibraryMemoryFolder.selfFolder { return "\(folder.fileCount) 条 · 可编辑" }
        if folder.imageCount == folder.fileCount { return "\(folder.fileCount) 张图" }
        return FileLibraryFolderStyle.system(folder.path) != nil ? "\(folder.fileCount) 个" : "\(folder.fileCount) 个文件"
    }

    private func folderListRow(_ folder: FileLibraryDisplay.Folder, divider: Bool) -> some View {
        let isSystem = FileLibraryFolderStyle.system(folder.path) != nil
        let name = folderName(folder.path)
        return FileLibraryRow(
            tile: FileLibraryTile(content: .folder(folderLook(folder.path), name: name), style: .plain),
            title: AttributedString(name),
            time: folderTime(folder),
            chevron: true,
            divider: divider,
            minHeight: 58
        ) {
            if isSystem {
                Text("\(Text(folder.name).font(FileLibraryUI.mono(11)).foregroundColor(Theme.textMuted.opacity(0.75))) · \(folderCountText(folder))")
                    .monospacedDigit()
            } else {
                Text(folderCountText(folder)).monospacedDigit()
            }
        }
    }

    private func fileTile(_ meta: FileLibraryStore.FileMeta, side: CGFloat = 36) -> FileLibraryTile {
        FileLibraryTile.file(meta.path, profileId: profileId, side: side, modifiedAt: meta.modifiedAt)
    }

    private func fileTitle(_ meta: FileLibraryStore.FileMeta) -> String {
        display(meta.path).title
    }

    /// 缓存里的显示数据；缓存还没有（刚出现的文件）就退回文件名，不现算正则
    private func display(_ path: String) -> FileLibraryDisplay.Entry {
        if let cached = displays[path] { return cached }
        let name = FileLibraryDisplay.fileName(path)
        let kind = FileLibraryDisplay.kind(of: path)
        let title = kind == .markdown || kind == .html ? (name as NSString).deletingPathExtension : name
        return FileLibraryDisplay.Entry(title: title, summary: nil, chips: [], lines: [], searchText: "")
    }

    private func fileListRow(_ meta: FileLibraryStore.FileMeta, divider: Bool) -> some View {
        FileLibraryRow(
            tile: fileTile(meta),
            title: AttributedString(fileTitle(meta)),
            time: FileLibraryDisplay.timeText(meta.modifiedAt),
            divider: divider
        ) {
            Text(display(meta.path).summary ?? byteCountText(meta.bytes))
        }
    }

    private func fileItem<Content: View>(_ meta: FileLibraryStore.FileMeta, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .contentShape(Rectangle())
            .onTapGesture { openFile(meta) }
            .contextMenu {
                fileContextMenu(for: meta.path)
            } preview: {
                longPressPreview(meta)
            }
    }

    #if os(macOS)
    private var rootTopBar: some View {
        HStack(spacing: 10) {
            Spacer()
            moreMenu
            Button { startNewFile() } label: {
                FileLibraryCircleLabel(symbol: "plus", tint: Theme.branchIndicator)
            }
            .buttonStyle(.plain)
            .help("新建文件")
        }
        .frame(height: 44)
        .padding(.horizontal, metrics.fileLibHeaderInsetH)
    }
    #endif

    #if os(iOS)
    /// 右上 ⋯ + ＋ 合进一个玻璃胶囊，尺寸颜色照 page1 聊天顶栏右侧
    private var glassActionCapsule: some View {
        HStack(spacing: 0) {
            Menu {
                Button { reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多")

            Button { startNewFile() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("新建文件")
        }
        .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .capsule)
    }
    #else
    private var moreMenu: some View {
        Menu {
            if inFolderPage {
                Button { startNewFile() } label: { Label("新建文件…", systemImage: "plus") }
            }
            Button { reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            Button { NSWorkspace.shared.open(FileLibraryStore.libraryRoot(profileId: profileId)) } label: {
                Label("在 Finder 中显示文件库", systemImage: "folder")
            }
        } label: {
            FileLibraryCircleLabel(symbol: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
    #endif

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("文件库")
                .font(.system(size: FileLibraryUI.titleSize, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text(files.isEmpty ? "还没有文件" : "\(files.count) 个文件 · \(FileLibraryStore.iCloudEnabled ? "存在 iCloud" : "存在本机")")
                .font(FileLibraryUI.font(12))
                .monospacedDigit()
                .foregroundColor(Theme.textMuted)
        }
        .padding(.horizontal, metrics.fileLibHeaderInsetH + 4)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    /// 聚焦 / 输入都不改高度、不收标题：只有右侧「取消」横向滑进来，挤窄搜索框
    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(FileLibraryUI.font(14, .medium))
                    .foregroundColor(Theme.textMuted)
                TextField("搜索文件名和内容", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(FileLibraryUI.font(15))
                    .foregroundColor(Theme.textPrimary)
                    .focused($searchFocused)
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(FileLibraryUI.font(14))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                }
                .buttonStyle(.plain)
                .opacity(searchText.isEmpty ? 0 : 1)
                .allowsHitTesting(!searchText.isEmpty)
            }
            .padding(.horizontal, 11)
            .frame(height: FileLibraryUI.size(38))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(searchActive ? Theme.mainBg : FileLibraryUI.fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.accent, lineWidth: searchActive ? 1 : 0)
            )
            if searchActive {
                Button("取消") {
                    searchText = ""
                    searchFocused = false
                }
                .font(FileLibraryUI.font(16))
                .foregroundColor(Theme.textPrimary)
                .buttonStyle(.plain)
                .fixedSize()
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(height: FileLibraryUI.size(38))
        .animation(.easeInOut(duration: 0.2), value: searchActive)
        .padding(.horizontal, metrics.fileLibHeaderInsetH)
        .padding(.bottom, 4)
    }

    private func startNewFile() {
        newFileName = currentFolder.isEmpty || !inFolderPage || FileLibraryMemoryFolder.isMemoryPath(currentFolder) ? "" : currentFolder + "/"
        showNewFileAlert = true
    }

    private var fileLibraryExternalChangeBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.textMuted)
                .frame(width: 7, height: 7)
            Group {
                if externalChangedPaths.count == 1, let path = externalChangedPaths.first {
                    Text("\(Text(display(path).title).fontWeight(.medium).foregroundColor(Theme.textPrimary)) 在外面改过了")
                } else {
                    Text("有 \(externalChangedPaths.count) 个文件在外面改过")
                }
            }
            .font(FileLibraryUI.font(13))
            .foregroundColor(Theme.textSecondary)
            .lineLimit(1)
            Spacer(minLength: 8)
            Button("刷新") { reload() }
                .font(FileLibraryUI.font(13, .semibold))
                .foregroundColor(Theme.textPrimary)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.mainBg))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(FileLibraryUI.hairline, lineWidth: 0.5))
        .padding(.horizontal, metrics.fileLibHeaderInsetH)
        .padding(.top, 8)
    }

    // MARK: - Browser

    private var treeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileLibrarySectionHeader(title: "全部") { viewControls }
            LazyVStack(spacing: 0) {
                ForEach(treeLines) { line in
                    treeRow(line)
                }
            }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.mainBg))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(FileLibraryUI.hairline, lineWidth: 0.5))
            .padding(.horizontal, metrics.fileLibHeaderInsetH)
        }
    }

    private var treeLines: [TreeLine] {
        var out: [TreeLine] = []
        func walk(_ nodes: [FileTreeNode], depth: Int, guides: [Bool]) {
            for (index, node) in nodes.enumerated() {
                let last = index == nodes.count - 1
                out.append(TreeLine(node: node, depth: depth, guides: guides, isLast: last))
                if node.kind == .folder && isTreeFolderExpanded(node) {
                    walk(node.children, depth: depth + 1, guides: depth == 0 ? [] : guides + [!last])
                }
            }
        }
        walk(fileTree, depth: 0, guides: [])
        return out
    }

    private func treeRow(_ line: TreeLine) -> some View {
        let node = line.node
        let isFolder = node.kind == .folder
        let tile: FileLibraryTile
        if isFolder {
            tile = FileLibraryTile(content: .folder(folderLook(node.path), name: folderName(node.path)), style: .plain, side: 26)
        } else if let meta = node.meta {
            tile = fileTile(meta, side: 26)
        } else {
            tile = FileLibraryTile(content: .badge(FileLibraryDisplay.badge(node.path)), style: .plain, side: 26)
        }
        let row = FileLibraryTreeRow(
            guides: line.guides,
            depth: line.depth,
            isLast: line.isLast,
            expanded: isFolder ? isTreeFolderExpanded(node) : nil,
            tile: tile,
            name: isFolder ? folderName(node.path) : node.meta.map(fileTitle) ?? node.name,
            trailing: isFolder ? "\(node.fileCount)" : FileLibraryDisplay.timeText(node.latest),
            highlighted: flashPaths.contains(node.path)
        )
        return Group {
            if isFolder {
                row.onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { toggleFolder(node.path) } }
            } else if let meta = node.meta {
                fileItem(meta) { row }
            } else {
                row
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            FileLibraryEmptyArt()
                .frame(width: 120, height: 96)
            Text("这里还空着")
                .font(FileLibraryUI.font(17, .semibold))
                .foregroundColor(Theme.textPrimary)
                .padding(.top, 20)
                .padding(.bottom, 6)
            Text("新建一篇笔记，或者在聊天里让\(assistantName)\n帮你写下来，会自动出现在这里。")
                .font(FileLibraryUI.font(13))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.textSecondary)
            Button { startNewFile() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(FileLibraryUI.font(13, .semibold))
                    Text("新建笔记")
                        .font(FileLibraryUI.font(14, .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .frame(height: FileLibraryUI.size(38))
                .background(Capsule().fill(Theme.branchIndicator))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 22)
        }
        .padding(.top, 50)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    private var folderEmptyState: some View {
        VStack(spacing: 0) {
            FileLibraryEmptyArt()
                .frame(width: 72, height: 58)
            Text(currentFolder == FileLibraryMemoryFolder.selfFolder ? "还没有记忆" : "这个文件夹空了")
                .font(FileLibraryUI.font(15, .semibold))
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 14)
            if currentFolder == FileLibraryMemoryFolder.selfFolder {
                Text("跟\(assistantDisplayName)说「记住…」，它会记在这里。")
                    .font(FileLibraryUI.font(13))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
        }
        .padding(.top, 50)
        .frame(maxWidth: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundColor(Theme.textMuted.opacity(0.36))
            Text("没有匹配的文件")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textMuted)
        }
        .padding(.top, 80)
        .frame(maxWidth: .infinity)
    }

    // MARK: - View Mode / Tree Helpers

    private var viewMode: FileLibraryViewMode {
        FileLibraryViewMode(rawValue: viewModeRaw) ?? .cards
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isTreeFolderExpanded(_ node: FileTreeNode) -> Bool {
        isSearching || !collapsedFolderPaths.contains(node.path)
    }

    private func toggleFolder(_ path: String) {
        if collapsedFolderPaths.contains(path) {
            collapsedFolderPaths.remove(path)
        } else {
            collapsedFolderPaths.insert(path)
        }
    }

    @ViewBuilder
    private func fileContextMenu(for path: String) -> some View {
        if FileLibraryMemoryFolder.isMemoryPath(path) {
            // 记忆树只读（自己的记忆点开编辑，不在这里改名 / 删）
            Button { copyPath(path) } label: { Label("复制路径", systemImage: "doc.on.doc") }
        } else {
            fileWriteContextMenu(for: path)
        }
    }

    @ViewBuilder
    private func fileWriteContextMenu(for path: String) -> some View {
        Button { startRename(path) } label: { Label("重命名", systemImage: "pencil") }
        Button { copyPath(path) } label: { Label("复制路径", systemImage: "doc.on.doc") }
        if let url = FileLibraryStore.absoluteURL(path, profileId: profileId) {
            ShareLink(item: url) { Label("分享…", systemImage: "square.and.arrow.up") }
        }
        #if os(macOS)
        Button { revealInFinder(path) } label: { Label("在 Finder 中显示", systemImage: "folder") }
        #endif
        Divider()
        Button(role: .destructive) { deletingPath = path } label: { Label("删除", systemImage: "trash") }
    }

    @ViewBuilder
    private func folderContextMenu(for path: String) -> some View {
        Button { appearanceFolder = AppearanceTarget(id: path) } label: { Label("外观…", systemImage: "paintpalette") }
        Button { copyPath(path) } label: { Label("复制路径", systemImage: "doc.on.doc") }
        #if os(macOS)
        Button { revealInFinder(path) } label: { Label("在 Finder 中显示", systemImage: "folder") }
        #endif
    }

    private func copyPath(_ path: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        #else
        UIPasteboard.general.string = path
        #endif
    }

    private func longPressPreview(_ meta: FileLibraryStore.FileMeta) -> some View {
        HStack(spacing: 12) {
            fileTile(meta)
            VStack(alignment: .leading, spacing: 3) {
                Text(fileTitle(meta))
                    .font(FileLibraryUI.font(15))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(meta.path) · \(byteCountText(meta.bytes))")
                    .font(FileLibraryUI.mono(11))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(FileLibraryDisplay.timeText(meta.modifiedAt))
                .font(FileLibraryUI.font(12))
                .monospacedDigit()
                .foregroundColor(Theme.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(width: 340)
        .background(Theme.mainBg)
    }

    private func fileBaseName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func byteCountText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func fileIconName(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "md", "markdown":
            return "doc.text"
        case "html", "htm":
            return "curlybraces.square"
        case "json", "css", "js":
            return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "webp", "heic":
            return "photo"
        case "pdf":
            return "doc.richtext"
        case "mp3", "m4a", "wav":
            return "waveform"
        case "mp4", "mov":
            return "film"
        case "zip":
            return "doc.zipper"
        case "docx", "xlsx", "pptx", "bin":
            return "doc"
        default:
            return "doc.plaintext"
        }
    }

    private func buildFileTree(from files: [FileLibraryStore.FileMeta]) -> [FileTreeNode] {
        final class Builder {
            let name: String
            let path: String
            var meta: FileLibraryStore.FileMeta?
            var children: [String: Builder] = [:]

            init(name: String, path: String, meta: FileLibraryStore.FileMeta? = nil) {
                self.name = name
                self.path = path
                self.meta = meta
            }
        }

        let root = Builder(name: "", path: "")
        for meta in files {
            let parts = meta.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var current = root
            var currentPath = ""
            for (index, part) in parts.enumerated() {
                currentPath = currentPath.isEmpty ? part : currentPath + "/" + part
                if index == parts.count - 1 {
                    current.children[part] = Builder(name: part, path: currentPath, meta: meta)
                } else {
                    if current.children[part] == nil {
                        current.children[part] = Builder(name: part, path: currentPath)
                    }
                    current = current.children[part]!
                }
            }
        }

        let byModified = sortMode == .modified
        func ordered(_ lhs: FileTreeNode, _ rhs: FileTreeNode) -> Bool {
            if lhs.kind != rhs.kind { return lhs.kind == .folder }
            if byModified, lhs.latest != rhs.latest { return lhs.latest > rhs.latest }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        func convert(_ builder: Builder) -> FileTreeNode {
            let convertedChildren = builder.children.values.map(convert).sorted(by: ordered)
            return FileTreeNode(
                name: builder.name,
                path: builder.path,
                kind: builder.meta == nil ? .folder : .file,
                meta: builder.meta,
                children: convertedChildren,
                fileCount: builder.meta == nil ? convertedChildren.reduce(0) { $0 + $1.fileCount } : 1,
                latest: builder.meta?.modifiedAt ?? convertedChildren.map(\.latest).max() ?? .distantPast
            )
        }

        return root.children.values.map(convert).sorted(by: ordered)
    }

    /// 5 秒一次的外部变更检查：枚举整库挪后台（以前在主线程，面板开着就每 5 秒卡一下）
    private func checkForExternalChanges() {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("FileLibraryPanelView.checkForExternalChanges") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        guard !profileId.isEmpty, !lastKnownFingerprint.isEmpty, !externalCheckInFlight else { return }
        externalCheckInFlight = true
        let pid = profileId
        let known = lastKnownFingerprint
        Task {
            let changed = await Task.detached(priority: .utility) { () async -> [String]? in
                let files = await FileLibraryStore.freshList(profileId: pid)
                return Self.changedPaths(known: known, current: Self.fingerprint(for: files))
            }.value
            externalCheckInFlight = false
            guard pid == profileId, let changed, changed != externalChangedPaths else { return }
            externalChangedPaths = changed
        }
    }

    /// 纯函数（后台跑）：指纹没变 = nil；变了 = 新增 / 删除 / 改动过的路径
    nonisolated private static func changedPaths(known: String, current: String) -> [String]? {
        guard current != known else { return nil }
        let before = Set(known.components(separatedBy: "\n"))
        let after = Set(current.components(separatedBy: "\n"))
        let paths = Set(before.symmetricDifference(after).map { $0.components(separatedBy: "|").dropLast(2).joined(separator: "|") })
        return paths.filter { !$0.isEmpty }.sorted()
    }

    nonisolated private static func fingerprint(for files: [FileLibraryStore.FileMeta]) -> String {
        files
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { meta in
                [meta.path, String(meta.bytes), String(meta.modifiedAt.timeIntervalSince1970)].joined(separator: "|")
            }
            .joined(separator: "\n")
    }
    // MARK: - Ops

    /// 修全局卡顿：扫盘（全库清单 + 记忆树计数 + 每个文件的预览）全在后台，回主线程只落状态；
    /// 连着点多次只认最后一次。`then`：落完状态再做的事（如打开指定文件）
    private func reload(then: (() -> Void)? = nil) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("FileLibraryPanelView.reload") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        reloadGeneration += 1
        let gen = reloadGeneration
        let pid = profileId
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> (files: [FileLibraryStore.FileMeta], memory: [FileLibraryStore.FileMeta], previews: [String: String], fingerprint: String) in
                let files = FileLibraryStore.list(profileId: pid)
                let memory = FileLibraryMemoryFolder.visible(FileLibraryStore.memoryList(profileId: pid))
                var p: [String: String] = [:]
                for meta in files where !FileLibraryStore.isBinaryPath(meta.path) {
                    let isHTML = FileLibraryDisplay.kind(of: meta.path) == .html
                    if let content = try? FileLibraryStore.readPreview(meta.path, maxBytes: isHTML ? 16384 : 4096, profileId: pid) {
                        p[meta.path] = FileLibraryDisplay.previewText(path: meta.path, raw: content)
                    }
                }
                for meta in memory where !FileLibraryStore.isBinaryPath(meta.path) {
                    if let content = try? FileLibraryStore.readAny(meta.path, profileId: pid, maxBytes: 4096).text {
                        p[meta.path] = FileLibraryDisplay.previewText(path: meta.path, raw: content)
                    }
                }
                return (files, memory, p, Self.fingerprint(for: files))
            }.value
            guard gen == reloadGeneration, pid == profileId else { return }
            applyReload(loaded.files, memory: loaded.memory, previews: loaded.previews, fingerprint: loaded.fingerprint)
            then?()
        }
    }

    private func applyReload(_ latestFiles: [FileLibraryStore.FileMeta], memory: [FileLibraryStore.FileMeta], previews p: [String: String], fingerprint: String) {
        memoryFiles = memory
        if !files.isEmpty {
            let before = Dictionary(files.map { ($0.path, $0.modifiedAt) }, uniquingKeysWith: { a, _ in a })
            let changed = Set(latestFiles.filter { before[$0.path] != $0.modifiedAt }.map(\.path))
            if !changed.isEmpty {
                flashPaths.formUnion(changed)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    withAnimation(.easeOut(duration: 0.8)) { flashPaths.subtract(changed) }
                }
            }
        }
        var d: [String: FileLibraryDisplay.Entry] = [:]
        for meta in latestFiles + memory {
            let preview = p[meta.path]
            if preview == previews[meta.path], let cached = displays[meta.path] {
                d[meta.path] = cached
            } else {
                d[meta.path] = FileLibraryDisplay.entry(path: meta.path, preview: preview)
            }
        }
        files = latestFiles
        previews = p
        displays = d
        folderLooks = FileLibraryFolderStyleStore.load(profileId: profileId)
        rebuildDerived()
        lastKnownFingerprint = fingerprint
        externalChangedPaths = []
    }

    private func sortedForDisplay(_ list: [FileLibraryStore.FileMeta]) -> [FileLibraryStore.FileMeta] {
        switch sortMode {
        case .modified:
            list.sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        case .name:
            list.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    /// 排序 / 文件夹分组 / 树：只依赖 files 和排序模式，不读盘不跑正则
    private func rebuildDerived() {
        let sorted = sortedForDisplay(files)
        let memorySorted = sortedForDisplay(memoryFiles)
        var index = FileLibraryDisplay.folderIndex(sorted)
        FileLibraryMemoryFolder.merge(FileLibraryDisplay.folderIndex(memorySorted), into: &index)
        for key in index.keys {
            switch sortMode {
            case .modified: index[key]?.folders.sort { $0.latest > $1.latest }
            case .name: index[key]?.folders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }
        }
        FileLibraryMemoryFolder.pinSelfFirst(&index)
        sortedFiles = sorted
        folderIndex = index
        fileTree = buildFileTree(from: sorted + memorySorted)
        let byModified = sortMode == .modified ? sorted : files.sorted { $0.modifiedAt > $1.modifiedAt }
        recentFiles = Array(byModified.prefix(4))
        var recent: [String: [FileLibraryStore.FileMeta]] = [:]
        for meta in byModified + memoryFiles.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            var folder = FileLibraryDisplay.parentFolder(meta.path)
            while !folder.isEmpty {
                if recent[folder, default: []].count < 3 { recent[folder, default: []].append(meta) }
                folder = FileLibraryDisplay.parentFolder(folder)
            }
        }
        folderRecent = recent
    }

    /// [[wiki link]] 跳转：精确路径 → basename 匹配 → 不存在则建 `目标.md` 并打开。
    /// R2-3b 例外：词条笔记（vocab/）语境的双链弹词卡，不走文件。
    private func openWikiTarget(_ target: String) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 在 vocab/ 笔记里点的裸词双链 → 词卡（词卡不依赖目标 md 存在，也不建文件）
        if editingFile?.path.hasPrefix("vocab/") == true, !trimmed.contains("/") {
            wikiWordCard = WikiWordCard(word: VocabCollector.normalize(trimmed))
            return
        }

        var path = trimmed
        if URL(fileURLWithPath: path).pathExtension.isEmpty { path += ".md" }

        if !FileLibraryStore.exists(path, profileId: profileId) {
            let wantedFull = path.lowercased()
            let wantedName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            let wantedBase = URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
            if let match = files.first(where: { meta in
                let name = URL(fileURLWithPath: meta.path).lastPathComponent.lowercased()
                let base = URL(fileURLWithPath: meta.path).deletingPathExtension().lastPathComponent.lowercased()
                return meta.path.lowercased() == wantedFull || name == wantedName || base == wantedBase
            }) {
                path = match.path
            } else {
                do {
                    try FileLibraryStore.write(path, content: "", profileId: profileId)
                    reload()
                } catch {
                    operationError = error.localizedDescription
                    return
                }
            }
        }

        // 从任何笔记解析落到 vocab/ 的双链（basename 匹配或显式路径）→ 也弹词卡
        if path.hasPrefix("vocab/"), path.hasSuffix(".md") {
            wikiWordCard = WikiWordCard(word: String(path.dropFirst("vocab/".count).dropLast(3)))
            return
        }

        do {
            let body = try FileLibraryStore.read(path, profileId: profileId)
            editingFile = EditingFile(path: path, content: body, modifiedAt: FileLibraryStore.modifiedAt(path, profileId: profileId))
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func consumeDesktopTarget() {
        guard let target = desktopNavigator?.pendingTarget, target.tool == "fileLibrary" else { return }
        desktopNavigator?.pendingTarget = nil
        guard let file = files.first(where: { $0.path == target.id }) else {
            operationError = "这份文件已不在当前楼层。"
            return
        }
        if viewMode != .tree { crossfade(to: FileLibraryDisplay.parentFolder(file.path)) }
        openFile(file)
    }

    /// 回上一层（iOS 左上返回钮 / page2 壳的返回 / mac 标题栏返回钮共用）：卡片模式记得这只袋子在父页哪儿 → 返回转场；否则交叉淡入。转场中按了不排队。
    private func goUp() {
        guard flightState.flight == nil, !currentFolder.isEmpty else { return }
        let folder = currentFolder
        let parent = FileLibraryDisplay.parentFolder(folder)
        guard !reduceMotion, viewMode == .cards, inFolderPage, let shell = flightFrames.last("shell:\(folder)") else {
            crossfade(to: parent)
            return
        }
        var next = FileLibraryFolderFlight(
            direction: .close,
            folder: folder,
            name: folderName(folder),
            look: folderLook(folder),
            papers: flightPapers(folder),
            lead: 0,
            pressed: 0,
            shell: shell
        )
        for (index, paper) in next.papers.enumerated() {
            if let rect = flightFrames.live(paper.target.anchor) { next.sources[index] = rect }
        }
        flightState.pageMotion = .close(pageAnchor(shell))
        flightState.begin(next)
        withAnimation(Self.outCurve) { navigate(to: parent) }
        Task { @MainActor in
            await Self.nextFrame()
            guard flightState.flight?.id == next.id else { return }
            try? await Task.sleep(for: .milliseconds(Int(max(0, next.duration - flightState.elapsed()))))
            guard flightState.flight?.id == next.id else { return }
            flightState.end()
        }
    }

    /// 不带飞行的换页（面包屑跳层、直达某个文件、切到树、减少动态效果）：两页交叉淡入
    private func crossfade(to folder: String) {
        guard folder != currentFolder else { return }
        withAnimation(.easeInOut(duration: 0.22)) { navigate(to: folder) }
    }

    private func openFile(_ meta: FileLibraryStore.FileMeta) {
        if FileLibraryMemoryFolder.isMemoryPath(meta.path) {
            openMemoryFile(meta)
            return
        }
        if FileLibraryStore.isBinaryPath(meta.path) {
            #if os(iOS)
            // 图片走 page1 同款照片预览（粟粟点名照抄）；其他二进制仍 QuickLook
            if FileLibraryStore.isImagePath(meta.path),
               let data = try? FileLibraryStore.readData(meta.path, profileId: profileId) {
                imagePreview = LibraryImagePreview(name: fileBaseName(meta.path), data: data)
                return
            }
            #endif
            if let url = FileLibraryStore.absoluteURL(meta.path, profileId: profileId) {
                quickLookURL = url
            } else {
                operationError = "文件不存在或无法访问：\(meta.path)"
            }
            return
        }
        do {
            let content = try FileLibraryStore.read(meta.path, profileId: profileId)
            editingFile = EditingFile(path: meta.path, content: content, modifiedAt: meta.modifiedAt)
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// 记忆树：自己的记忆 → 编辑页；其余 → 同一个查看器，只读（后台读，回来再弹）
    private func openMemoryFile(_ meta: FileLibraryStore.FileMeta) {
        if let slug = FileLibraryMemoryFolder.selfSlug(meta.path) {
            editingSelfMemory = SelfMemoryTarget(slug: slug)
            return
        }
        let pid = profileId
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                try? FileLibraryStore.memoryRead(meta.path, profileId: pid)
            }.value
            guard pid == profileId else { return }
            guard let text else {
                operationError = "读不出来：\(meta.path)"
                return
            }
            editingFile = EditingFile(path: meta.path, content: text, modifiedAt: nil, readOnly: true)
        }
    }

    private func createFile() {
        var name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFileName = ""
        guard !name.isEmpty else { return }
        guard !FileLibraryMemoryFolder.isMemoryPath(name) else {
            operationError = "「记忆」文件夹是只读的，新建不了文件"
            return
        }
        if URL(fileURLWithPath: name).pathExtension.isEmpty { name += ".md" }
        do {
            guard !FileLibraryStore.exists(name, profileId: profileId) else {
                throw NSError(domain: "FileLibrary", code: -2, userInfo: [NSLocalizedDescriptionKey: "文件已存在：\(name)"])
            }
            try FileLibraryStore.write(name, content: "", profileId: profileId)
            reload()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func confirmDelete() {
        guard let p = deletingPath else { return }
        do {
            try FileLibraryStore.delete(p, profileId: profileId)
            deletingPath = nil
            reload()
        } catch {
            deletingPath = nil
            operationError = error.localizedDescription
        }
    }

    private func startRename(_ path: String) {
        renamingPath = path
        renameTargetName = path
    }

    private func confirmRename() {
        guard let oldPath = renamingPath else { return }
        var newPath = renameTargetName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newPath.isEmpty && URL(fileURLWithPath: newPath).pathExtension.isEmpty {
            let oldExtension = URL(fileURLWithPath: oldPath).pathExtension
            if !oldExtension.isEmpty { newPath += ".\(oldExtension)" }
        }

        do {
            guard !newPath.isEmpty else { throw NSError(domain: "FileLibrary", code: -3, userInfo: [NSLocalizedDescriptionKey: "文件名不能为空"]) }
            try FileLibraryStore.rename(oldPath, to: newPath, profileId: profileId)
            renamingPath = nil
            renameTargetName = ""
            reload()
        } catch {
            renamingPath = nil
            operationError = error.localizedDescription
        }
    }

    #if os(macOS)
    private func revealInFinder(_ path: String) {
        guard let url = FileLibraryStore.resolve(path, profileId: profileId) else {
            operationError = "非法路径：\(path)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif

    private var filteredFiles: [FileLibraryStore.FileMeta] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sortedFiles }
        return sortedFiles.filter { meta in
            meta.path.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || previews[meta.path]?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

}

private enum FileLibrarySortMode: String {
    case modified
    case name
}

private enum FileLibraryViewMode: String, CaseIterable {
    case cards
    case list
    case tree

    var title: String {
        switch self {
        case .cards: "卡片"
        case .list: "列表"
        case .tree: "树"
        }
    }

    var iconName: String {
        switch self {
        case .cards: "square.grid.2x2"
        case .list: "list.bullet"
        case .tree: "list.bullet.indent"
        }
    }
}

private struct FileTreeNode: Identifiable {
    enum Kind { case folder, file }

    let name: String
    let path: String
    let kind: Kind
    let meta: FileLibraryStore.FileMeta?
    var children: [FileTreeNode]
    let fileCount: Int
    let latest: Date

    var id: String { path }
}

private struct TreeLine: Identifiable {
    let node: FileTreeNode
    let depth: Int
    let guides: [Bool]
    let isLast: Bool

    var id: String { node.path }
}


// MARK: - File Editor Sheet (预览 / raw 编辑切换)

struct FileEditorSheet: View {
    @Environment(\.chatMetrics) private var metrics
    /// 预览里「存成问题」要写进当前楼层的文件库（09-16 两端同走聊天渲染器后需要）
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    let path: String
    let initialContent: String
    let initialModifiedAt: Date?
    let currentModifiedAt: () -> Date?
    let reloadExternalContent: () throws -> ReloadedFileContent
    /// 第二个参数 = 编辑器认得的 baseline **内容**（R11 冲突判定用它算哈希，不再传 mtime）
    let onSave: (String, String) throws -> Void
    let onCancel: () -> Void
    /// [[wiki link]] 点击（自动保存已在 sheet 内完成后才上抛）
    let onOpenWikiLink: (String) -> Void
    /// 只读（记忆树）：只有预览，没有模式切换 / 保存 / 编辑菜单，不查外部改动
    let readOnly: Bool

    @State private var content: String
    @State private var savedContent: String
    @State private var mode: FileEditorMode

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    // 流式重写 Phase 2：跟全局字体设置同步（iOS markdown 预览用）
    @AppStorage("selectedFont") private var selectedFont: String = ""
    @AppStorage("fontScale") private var fontScale: Double = 1.2

    @State private var saveError: String?
    @State private var showCloseConfirmation = false
    @State private var findText = ""
    @State private var findIndex = 0
    @State private var markdownCommandName = ""
    @State private var markdownCommandToken = 0
    @State private var fileBrowseURL: FileBrowseTarget? = nil
    @State private var splitPreviewContent = ""
    @State private var splitDebounceTask: Task<Void, Never>? = nil
    @State private var baselineModifiedAt: Date?
    @State private var externalChangeState: FileEditorExternalChangeState = .none
    @State private var ignoredExternalModifiedAt: Date?
    // plan-file-editor-sheet：查找收进「…」、iPhone 键盘浮条、行号开关
    @AppStorage(FileEditorPreferences.showLineNumbersKey) private var showLineNumbers = FileEditorPreferences.showLineNumbersDefault
    @State private var findActive = false
    @State private var replaceActive = false
    @State private var replaceText = ""
    @FocusState private var findFocus: FileEditorFindField?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(FileEditorPreferences.keyboardBarStyleKey) private var keyboardBarStyleRaw = FileEditorKeyboardBarStyle.defaultStyle.rawValue
    @AppStorage(FileEditorPreferences.formatBarExpandedKey) private var formatBarExpanded = FileEditorPreferences.formatBarExpandedDefault
    @State private var keyboardVisible = false
    @State private var sourceFindPresented = false
    #endif

    init(
        path: String,
        initialContent: String,
        initialModifiedAt: Date?,
        readOnly: Bool = false,
        currentModifiedAt: @escaping () -> Date?,
        reloadExternalContent: @escaping () throws -> ReloadedFileContent,
        onSave: @escaping (String, String) throws -> Void,
        onCancel: @escaping () -> Void,
        onOpenWikiLink: @escaping (String) -> Void = { _ in }
    ) {
        self.path = path
        self.initialContent = initialContent
        self.initialModifiedAt = initialModifiedAt
        self.currentModifiedAt = currentModifiedAt
        self.reloadExternalContent = reloadExternalContent
        self.onSave = onSave
        self.onCancel = onCancel
        self.onOpenWikiLink = onOpenWikiLink
        self.readOnly = readOnly
        _content = State(initialValue: initialContent)
        _savedContent = State(initialValue: initialContent)
        _mode = State(initialValue: readOnly ? .preview : FileEditorKind(path: path).initialMode)
        _baselineModifiedAt = State(initialValue: initialModifiedAt)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if usesTopChrome {
                    topChrome
                } else if let externalChangeBanner {
                    // iPhone = 纸 + 字：分段 / 查找 / 格式三行都收走，只有外部改动提示（有事才出）
                    externalChangeBanner
                }

                switch mode {
                case .live:
                    MarkdownWebEditorView(
                        content: $content,
                        findQuery: findText.trimmingCharacters(in: .whitespacesAndNewlines),
                        findIndex: findIndex,
                        replaceText: replaceText,
                        showsLineNumbers: showLineNumbers,
                        hidesKeyboardAccessory: true,
                        command: markdownCommand,
                        onRequestSave: { save() },
                        onOpenFind: { openFind(replace: false) },
                        onReplaceDone: { findIndex = $0 },
                        onOpenWikiLink: { target in
                            // 跳转前自动保存，失败不跳（不丢字）
                            if content != savedContent {
                                save()
                                guard saveError == nil else { return }
                            }
                            onOpenWikiLink(target)
                        }
                    )
                case .preview:
                    if kind == .html {
                        HTMLPreviewWebView(
                            content: content,
                            onOpenLink: { fileBrowseURL = FileBrowseTarget(url: $0) }
                        )
                        .ignoresSafeArea(edges: .bottom)
                    } else {
                        markdownPreview
                    }
                case .split:
                    splitEditor
                case .source:
                    sourceEditor
                }
            }
            .background(Theme.mainBg)
            #if os(iOS)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !usesTopChrome { bottomBar }
            }
            #endif
            .navigationTitle(path)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // 顶栏区 / 正文 / 浮条下面同一张纸（10-02 实机：三块颜色不一）
            .toolbarBackground(Theme.mainBg, for: .navigationBar)
            #endif
            .toolbar { toolbarContent }
        }
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .confirmationDialog("要保存修改吗？", isPresented: $showCloseConfirmation, titleVisibility: .visible) {
            Button("保存") { save(closeAfterSuccess: true) }
            Button("不保存", role: .destructive) { onCancel() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("关闭前还有未保存的修改。")
        }
        #if os(macOS)
        .frame(width: 720, height: 640)
        #else
        .presentationBackground(Theme.mainBg)
        #endif
        .onChange(of: findText) { _, _ in clampFindIndex() }
        .onChange(of: content) { _, _ in clampFindIndex() }
        .onChange(of: mode) { _, newMode in
            // 切模式会重建 WebView，残留的命令 token 会被新页面当成新命令重放
            //（toggle 类命令重放一次=格式消失、再切回来又出现）
            markdownCommandToken = 0
            markdownCommandName = ""
            if !FileEditorTools.ownFindAvailable(kind: kind, mode: newMode) { closeFind() }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        #endif
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in
            checkExternalChangeForOpenFile()
        }
        .sheet(item: $fileBrowseURL) { target in
            MiniBrowserView(initialURL: target.url)
        }
    }

    private var kind: FileEditorKind {
        FileEditorKind(path: path)
    }

    private var availableModes: [FileEditorMode] {
        if readOnly { return [.preview] }
        return switch kind {
        case .markdown:
            [.live, .preview, .source]
        case .html:
            [.preview, .split, .source]
        case .text:
            [.source]
        }
    }

    private var externalChangeBanner: AnyView? {
        guard externalChangeState != .none else { return nil }
        let hasUnsavedChanges = content != savedContent
        let message: String
        switch externalChangeState {
        case .none:
            return nil
        case .modified:
            message = hasUnsavedChanges
                ? "文件已在外部修改。重新载入会覆盖当前未保存编辑。"
                : "文件已在外部修改。重新载入可查看最新版本。"
        case .deleted:
            message = "文件已在外部删除或移动。保存可能重新创建文件。"
        }

        return AnyView(
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                Text(message)
                    .font(.system(size: Theme.F.caption, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if externalChangeState.isModified {
                    Button("重新载入") { reloadExternalVersion() }
                        .font(.system(size: Theme.F.caption, weight: .semibold))
                        .foregroundColor(Theme.branchIndicator)
                        .buttonStyle(.plain)
                }
                Button(externalChangeState.isTrashed ? "知道了" : "继续编辑") { ignoreExternalChange() }
                    .font(.system(size: Theme.F.caption, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.accent.opacity(0.34))
        )
    }

    private var markdownPreview: some View {
        let split = MarkdownFrontmatter.split(content)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            // 文件头属性块（她 09-16：原样当正文排着「这个属性都没渲染」）。没有 frontmatter 时 fields 为空、整块不出
            FrontmatterCard(fields: split.fields)
            // MarkdownUI 退役第二刀（09-16 她「总之全都用 iOS 聊天的这个新版 md 器」）：两端同走聊天那个包装。
            // 与聊天的三处差别：不挂划线锚（`nodeId: nil`——文件会被改写，锚不稳）、
            // 不做 $NVDA 链接化（文件是任意内容，`$PATH` 这种会变成假 ticker，R-MD #1）；
            // 收生词与「存成问题」照常（profileId 非空）
            ChatMarkdownView(
                text: split.body,
                fontName: selectedFont,
                scale: CGFloat(fontScale),
                nodeId: nil,
                profileId: profileId,
                linkifyTickers: false
            )
            .chatCardRenderer(nodeId: nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// W4 分屏（HTML）：源码 + 预览对半，敲码 300ms 后预览重渲。
    /// macOS 左右、iOS 上下；预览复用 HTMLPreviewWebView（含本地模式联网策略/错误条/链接进 mini browser）
    @ViewBuilder
    private var splitEditor: some View {
        let panes = Group {
            sourceEditor
            Divider()
            HTMLPreviewWebView(
                content: splitPreviewContent,
                onOpenLink: { fileBrowseURL = FileBrowseTarget(url: $0) }
            )
            .ignoresSafeArea(edges: .bottom)
        }
        let layout = metrics.fileLibSplitAxis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
        layout { panes }
        .onAppear { splitPreviewContent = content }
        .onChange(of: content) { _, latest in
            splitDebounceTask?.cancel()
            splitDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                splitPreviewContent = latest
            }
        }
    }

    private var sourceEditor: some View {
        TextEditor(text: $content)
            .font(.system(size: Theme.F.body))
            .scrollContentBackground(.hidden)
            .padding(8)
            #if os(iOS)
            .findNavigator(isPresented: $sourceFindPresented)
            #endif
    }

    private var markdownCommand: MarkdownWebEditorCommand? {
        guard markdownCommandToken > 0 else { return nil }
        return MarkdownWebEditorCommand(name: markdownCommandName, token: markdownCommandToken)
    }

    private var markdownFormatBar: some View {
        ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
            HStack(spacing: 10) {
                Menu {
                    Button("标题 1") { sendMarkdownCommand("heading1") }
                    Button("标题 2") { sendMarkdownCommand("heading2") }
                    Button("标题 3") { sendMarkdownCommand("heading3") }
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 24)
                }
                .menuStyle(.borderlessButton)
                .help("标题")

                formatButton("bold", command: "bold", help: "粗体")
                formatButton("italic", command: "italic", help: "斜体")
                formatButton("link", command: "link", help: "链接")
                formatButton("chevron.left.forwardslash.chevron.right", command: "code", help: "行内代码")

                Divider()
                    .frame(height: 18)

                formatButton("list.bullet", command: "bulletList", help: "无序列表")
                formatButton("list.number", command: "orderedList", help: "有序列表")
                formatButton("checklist", command: "taskList", help: "任务列表")
                formatButton("quote.opening", command: "quote", help: "引用")

                Divider()
                    .frame(height: 18)

                formatButton("curlybraces", command: "codeBlock", help: "代码块")
                formatButton("tablecells", command: "table", help: "表格")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(Theme.mainBg.opacity(0.78))
    }

    private func formatButton(_ systemName: String, command: String, help: String) -> some View {
        Button { sendMarkdownCommand(command) } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.textPrimary)
        .help(help)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted.opacity(0.7))
            TextField("在文件中查找", text: $findText)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textPrimary)
                .focused($findFocus, equals: .find)
            Text(findStatusText)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .frame(minWidth: 42, alignment: .trailing)
            Button { previousFindMatch() } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(findMatches.isEmpty)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            Button { nextFindMatch() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(findMatches.isEmpty)
            .keyboardShortcut("g", modifiers: .command)
            if !findText.isEmpty {
                Button { findText = ""; findIndex = 0 } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted.opacity(0.65))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.sidebarBg.opacity(0.55))
    }

    // MARK: - 两套排布（plan-file-editor-sheet）

    /// mac / iPad 宽屏：排布不动（分段 / 查找 / 格式条留顶部）；iPhone：纸 + 字，工具进「…」和键盘浮条
    private var usesTopChrome: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    private var fileName: String {
        (path as NSString).lastPathComponent
    }

    @ViewBuilder
    private var topChrome: some View {
        if !readOnly {
            Picker("", selection: $mode) {
                ForEach(availableModes, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .tint(Theme.branchIndicator)
        }

        // 查找只在 md 实时模式能高亮跳转；别的模式原来只显示命中数、↑↓ 不跳，干脆不出
        if FileEditorTools.ownFindAvailable(kind: kind, mode: mode) {
            findBar
            if replaceActive {
                replaceBar
            }
        }
        if let externalChangeBanner {
            externalChangeBanner
        }
        if kind == .markdown && mode == .live {
            markdownFormatBar
        }

        Divider()
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭") { close() }
                .foregroundColor(Theme.textMuted)
        }
        #if os(iOS)
        if !usesTopChrome {
            ToolbarItem(placement: .principal) { titleWithMode }
                .sharedBackgroundVisibility(.hidden)
        }
        if !readOnly {
            ToolbarItem(placement: .topBarTrailing) { editorMenu }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        #else
        if !readOnly {
            ToolbarItem(placement: .primaryAction) { editorMenu }
        }
        #endif
        if !readOnly {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .foregroundColor(Theme.branchIndicator)
                    .disabled(content == savedContent)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    /// iPhone 顶栏中间：文件名 + 下一行小灰字「实时 ⌄」（点开三选一）
    private var titleWithMode: some View {
        VStack(spacing: 1) {
            Text(fileName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if availableModes.count > 1 {
                Menu {
                    modePicker
                } label: {
                    HStack(spacing: 3) {
                        Text(mode.title)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                }
                .tint(Theme.textMuted)
            }
        }
        .frame(maxWidth: 220)
    }

    private var modePicker: some View {
        Picker("显示", selection: $mode) {
            ForEach(availableModes, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.inline)
    }

    private var editorMenu: some View {
        Menu {
            if FileEditorTools.findMenuAvailable(kind: kind, mode: mode, usesTopChrome: usesTopChrome) {
                Section {
                    Button { openFind(replace: false) } label: {
                        Label("查找", systemImage: "magnifyingglass")
                    }
                    Button { openFind(replace: true) } label: {
                        Label("查找并替换", systemImage: "arrow.left.arrow.right")
                    }
                }
            }
            if (!usesTopChrome && availableModes.count > 1) || kind == .markdown {
                Section("显示") {
                    if !usesTopChrome && availableModes.count > 1 {
                        modePicker
                    }
                    if kind == .markdown {
                        Toggle(isOn: $showLineNumbers) {
                            Label("行号", systemImage: "list.number")
                        }
                    }
                }
            }
            Section {
                Button { copyAll() } label: {
                    Label("复制全文", systemImage: "doc.on.doc")
                }
                ShareLink(
                    item: FileEditorShareFile(name: fileName, content: content),
                    preview: SharePreview(fileName)
                ) {
                    Label("分享…", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .tint(Theme.textSecondary)
        .accessibilityLabel("更多")
    }

    /// mac / iPad 宽屏「查找并替换」：查找条下面多一行
    private var replaceBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted.opacity(0.7))
            TextField("替换为", text: $replaceText)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textPrimary)
                .focused($findFocus, equals: .replace)
                .onSubmit { replaceNext() }
            Button("替换") { replaceNext() }
                .buttonStyle(.plain)
                .font(.system(size: Theme.F.caption, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .disabled(findMatches.isEmpty)
            Button("全部替换") { replaceAll() }
                .buttonStyle(.plain)
                .font(.system(size: Theme.F.caption, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .disabled(findMatches.isEmpty)
            Button {
                replaceActive = false
                replaceText = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted.opacity(0.65))
            }
            .buttonStyle(.plain)
            .help("收起替换")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.sidebarBg.opacity(0.55))
    }

    #if os(iOS)
    private var keyboardBarStyle: FileEditorKeyboardBarStyle {
        FileEditorKeyboardBarStyle(stored: keyboardBarStyleRaw)
    }

    /// iPhone 底部浮条：查找条 / 格式浮条 / 只有收键盘，同一个位置互斥
    @ViewBuilder
    private var bottomBar: some View {
        let barKind = FileEditorTools.bottomBar(mode: mode, keyboardVisible: keyboardVisible && !sourceFindPresented, findActive: findActive)
        Group {
            switch barKind {
            case .none:
                EmptyView()
            case .find:
                FileEditorFloatingFindBar(
                    findText: $findText,
                    replaceText: $replaceText,
                    showsReplace: replaceActive,
                    status: findStatusText,
                    hasMatches: !findMatches.isEmpty,
                    focus: $findFocus,
                    onPrevious: { previousFindMatch() },
                    onNext: { nextFindMatch() },
                    onReplace: { replaceNext() },
                    onReplaceAll: { replaceAll() },
                    onDone: { closeFind() }
                )
            case .format, .dismissOnly:
                FileEditorFormatBar(
                    style: keyboardBarStyle,
                    expanded: $formatBarExpanded,
                    showsFormatKeys: barKind == .format,
                    onCommand: { sendMarkdownCommand($0) },
                    onDismissKeyboard: { dismissKeyboard() }
                )
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.18), value: barKind)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    #endif

    private func openFind(replace: Bool) {
        #if os(iOS)
        if !usesTopChrome && mode == .source {
            sourceFindPresented = true
            return
        }
        #endif
        guard FileEditorTools.ownFindAvailable(kind: kind, mode: mode) else { return }
        if replace { replaceActive = true }
        findActive = true
        let field: FileEditorFindField = replace && !findText.isEmpty ? .replace : .find
        // iPhone 的查找条这一帧才插进来，下一轮再给焦点
        DispatchQueue.main.async { findFocus = field }
    }

    /// 「完成」：清空高亮 + 收起
    private func closeFind() {
        findText = ""
        findIndex = 0
        replaceText = ""
        replaceActive = false
        findActive = false
        findFocus = nil
        #if os(iOS)
        // 查找框的键盘正在收，别让格式浮条闪一下
        keyboardVisible = false
        #endif
    }

    private func replaceNext() {
        guard !findMatches.isEmpty else { return }
        sendMarkdownCommand("replaceNext")
    }

    private func replaceAll() {
        guard !findMatches.isEmpty else { return }
        sendMarkdownCommand("replaceAll")
    }

    private func copyAll() {
        #if os(iOS)
        UIPasteboard.general.string = content
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        #endif
    }

    private var findMatches: [Range<String.Index>] {
        let query = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var matches: [Range<String.Index>] = []
        var searchRange = content.startIndex..<content.endIndex
        while let range = content.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            matches.append(range)
            searchRange = range.upperBound..<content.endIndex
        }
        return matches
    }

    private var findStatusText: String {
        let count = findMatches.count
        guard count > 0 else { return findText.isEmpty ? "" : "0" }
        return "\(min(findIndex + 1, count))/\(count)"
    }

    private func nextFindMatch() {
        let count = findMatches.count
        guard count > 0 else { return }
        findIndex = (findIndex + 1) % count
    }

    private func previousFindMatch() {
        let count = findMatches.count
        guard count > 0 else { return }
        findIndex = (findIndex - 1 + count) % count
    }

    private func clampFindIndex() {
        let count = findMatches.count
        if count == 0 {
            findIndex = 0
        } else if findIndex >= count {
            findIndex = count - 1
        }
    }

    private func sendMarkdownCommand(_ command: String) {
        markdownCommandName = command
        markdownCommandToken += 1
    }

    private func checkExternalChangeForOpenFile() {
        guard !readOnly else { return }
        switch externalChangeState {
        case .deleted:
            return
        case .modified(let modifiedAt) where ignoredExternalModifiedAt == modifiedAt:
            return
        default:
            break
        }

        guard let baselineModifiedAt else {
            if currentModifiedAt() == nil {
                externalChangeState = .deleted
            }
            return
        }

        guard let modifiedAt = currentModifiedAt() else {
            externalChangeState = .deleted
            return
        }

        if modifiedAt > baselineModifiedAt.addingTimeInterval(0.5), ignoredExternalModifiedAt != modifiedAt {
            externalChangeState = .modified(modifiedAt)
        }
    }

    private func reloadExternalVersion() {
        do {
            let reloaded = try reloadExternalContent()
            content = reloaded.content
            savedContent = reloaded.content
            baselineModifiedAt = reloaded.modifiedAt
            externalChangeState = .none
            ignoredExternalModifiedAt = nil
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func ignoreExternalChange() {
        if case .modified(let modifiedAt) = externalChangeState {
            ignoredExternalModifiedAt = modifiedAt
        }
        externalChangeState = .none
    }

    private func save(closeAfterSuccess: Bool = false) {
        do {
            try onSave(content, savedContent)
            savedContent = content
            baselineModifiedAt = currentModifiedAt()
            externalChangeState = .none
            ignoredExternalModifiedAt = nil
            saveError = nil
            if closeAfterSuccess { onCancel() }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func close() {
        if content == savedContent {
            onCancel()
        } else {
            showCloseConfirmation = true
        }
    }
}

struct ReloadedFileContent {
    let content: String
    let modifiedAt: Date?
}

enum FileEditorExternalChangeState: Equatable {
    case none
    case modified(Date)
    case deleted

    var isModified: Bool {
        if case .modified = self { return true }
        return false
    }

    var isTrashed: Bool {
        if case .deleted = self { return true }
        return false
    }
}

enum FileEditorKind {
    case markdown
    case html
    case text

    init(path: String) {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "md", "markdown":
            self = .markdown
        case "html", "htm":
            self = .html
        default:
            self = .text
        }
    }

    var initialMode: FileEditorMode {
        switch self {
        case .markdown:
            .live
        case .html:
            .preview
        case .text:
            .source
        }
    }
}

#if os(iOS)
private struct LibraryImagePreview: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
}
#endif

struct FileBrowseTarget: Identifiable {
    let id = UUID()
    let url: URL
}

enum FileEditorMode: String, Hashable {
    case live
    case preview
    case split
    case source

    var title: String {
        switch self {
        case .live:
            "实时"
        case .preview:
            "预览"
        case .split:
            "分屏"
        case .source:
            "源码"
        }
    }
}

// MARK: - 二进制文件缩略图（ImageIO 降采样，避免大图整张进内存）

struct FileThumbnailView: View {
    let url: URL
    private let key: NSString

    @State private var image: CGImage?

    /// 解过的缩略图：同一张图再出现（开盒转场的飞行纸、返回后的格子）直接拿，不先闪白
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 48 << 20
        return cache
    }()

    /// `modifiedAt`：调用方手里有文件元数据就传，省得每次建视图都去读一次文件修改时间
    init(url: URL, modifiedAt: Date? = nil) {
        self.url = url
        key = Self.cacheKey(url, modifiedAt: modifiedAt)
        _image = State(initialValue: Self.cache.object(forKey: key))
    }

    /// 路径 + 修改时间：同路径的图被改过就不拿旧的
    private static func cacheKey(_ url: URL, modifiedAt: Date?) -> NSString {
        let modified = modifiedAt ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
    }

    var body: some View {
        Group {
            if let image {
                #if os(macOS)
                Image(nsImage: NSImage(cgImage: image, size: .zero))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #else
                Image(uiImage: UIImage(cgImage: image))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #endif
            } else {
                Color.white
            }
        }
        .task(id: key) {
            if let cached = Self.cache.object(forKey: key) {
                image = cached
                return
            }
            guard let decoded = await Self.thumbnail(for: url) else {
                image = nil
                return
            }
            Self.cache.setObject(decoded, forKey: key, cost: decoded.bytesPerRow * decoded.height)
            image = decoded
        }
    }

    private static func thumbnail(for url: URL) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}
