#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct Page2HomeView: View {
    @Binding var selectedToolId: String
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @Environment(\.colorScheme) private var inheritedScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastViewport: CGSize = .zero
    @State private var homeGlobalMinY: CGFloat = 0
    @State private var isKeyboardVisible = false
    @State private var pageScene = Page2SceneState.shared
    @State private var home = Page2HomeStore.shared
    @State private var appearance = Page2AppearanceStore.shared
    @State private var drag = Page2DragCoordinator()
    @State private var resize = Page2ResizeSession()
    @State private var editing = false
    private var currentPageID: UUID? {
        get { paging.currentPageID }
        nonmutating set { paging.currentPageID = newValue }
    }
    private var showsLibrary: Bool {
        get { paging.showsLibrary }
        nonmutating set { paging.showsLibrary = newValue }
    }
    @State private var showsSearch = false
    @State private var searchClosing = false
    @State private var searchPillFrame: CGRect = .zero
    @State private var searchPull: CGFloat = 0
    @State private var showsWidgets = false
    @State private var showsAppPicker = false
    @State private var showsAppearance = false
    @State private var showsWallpaper = false
    @State private var showsPages = false
    @State private var menuItem: Page2Item?
    @State private var containerItem: Page2Item?
    @State private var stackItem: Page2Item?
    @State private var stackOrigin: CGRect = .zero
    @State private var stackDragOutside = false
    @State private var folderItem: Page2Item?
    @State private var folderPresentationID = UUID()
    @State private var stackPresentationID = UUID()
    @State private var folderClosing = false
    @State private var folderGlancePages: [UUID: Int] = [:]
    @State private var configuringWidget: Page2Item?
    @State private var iconTool: RightPanelTool?
    @State private var workingBoard: Page2Board?
    @State private var paging = Page2PagingPresentation()
    @State private var gridSize: CGSize = .zero
    @State private var gridOrigin: CGPoint = .zero
    /// perf-flash C3b：dock / dock 图标 / 搜索胶囊的窗口坐标改由 UIKit 探针在用时现量（见 WindowFrameProbe）
    @State private var dockProbe = WindowFrameProbe()
    @State private var dockIconProbes = WindowFrameProbeSet()
    @State private var searchPillProbe = WindowFrameProbe()
    @State private var folderDragOutside = false
    @State private var topSafeArea: CGFloat = 0
    @State private var pendingRelease: CGPoint?
    @State private var resetConfirmation = false
    private var modalPresented: Bool {
        showsWidgets || showsAppPicker || showsAppearance || showsWallpaper || showsPages || resetConfirmation ||
        menuItem != nil || containerItem != nil || presentedStack != nil || configuringWidget != nil || iconTool != nil ||
        home.errorMessage != nil || appearance.errorMessage != nil
    }
    private var previewFolderID: UUID? {
        guard drag.folderPreview, let source = drag.sourceID, home.layout.item(source) != nil,
              let target = drag.mergeTarget, let item = home.layout.item(target), ["app", "folder"].contains(item.kind) else { return nil }
        return target
    }
    private var hasCommittedFolder: Bool {
        guard let id = folderItem?.id else { return false }
        return home.layout.item(id)?.kind == "folder"
    }
    private var presentedFolderID: UUID? {
        if let id = folderItem?.id, home.layout.item(id)?.kind == "folder" { return id }
        return previewFolderID
    }
    private var presentedStack: Page2Item? {
        guard let id = stackItem?.id, let item = home.layout.item(id), item.kind == "stack" else { return nil }
        return item
    }
    private var metrics: Page2SystemMetrics { Page2SystemMetrics(width: gridSize.width, height: gridSize.height) }
    private var gutter: CGFloat { max(0, (gridSize.width - metrics.contentWidth) / 2) }
    private let gap: CGFloat = 0

    private var columns: Int { metrics.columns }
    private var rows: Int { max(4, min(6, Int((gridSize.height + metrics.verticalGap - 20) / metrics.rowPitch))) }
    private var board: Page2Board { resize.board ?? workingBoard ?? home.board(columns: columns, rows: rows) }
    private var visiblePages: [Page2Page] { board.pages.filter { !$0.isHidden } }
    private var pageID: UUID { currentPageID.flatMap { id in visiblePages.first(where: { $0.id == id })?.id } ?? visiblePages[0].id }
    private var pageIndex: Int { visiblePages.firstIndex { $0.id == pageID } ?? 0 }
    private var cellSize: CGSize {
        CGSize(width: metrics.columnPitch, height: metrics.rowPitch)
    }
    private var reserved: Set<UUID> { Set(home.layout.rootItems.filter { !isVisible($0) }.map(\.id)) }

    var body: some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let _ = PerfCount.hit("page2HomeBody")
        #endif
        presentedHome
        .alert("主屏", isPresented: Binding(get: { home.errorMessage != nil }, set: { if !$0 { home.errorMessage = nil } })) {
            if home.recoveryRequired {
                Button("重试读取") { home.retryLoad() }
                Button("备份并恢复旧桌面") { home.recover(toolIDs: tools?.pinnedTools.map(\.id) ?? [], dockIDs: []) }
            }
            Button("知道了", role: .cancel) { home.errorMessage = nil }
        } message: { Text(home.errorMessage ?? "") }
        .alert("主屏外观", isPresented: Binding(get: { appearance.errorMessage != nil }, set: { if !$0 { appearance.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { appearance.errorMessage = nil }
        } message: { Text(appearance.errorMessage ?? "") }
        .confirmationDialog("恢复默认主屏布局？壁纸和图标保持不变。", isPresented: $resetConfirmation) {
            Button("恢复默认布局", role: .destructive) { home.reset(toolIDs: tools?.pinnedTools.map(\.id) ?? []) }
        }
    }

    private var presentedHome: some View {
        activeHome
        .sheet(isPresented: $showsWidgets) {
            Page2WidgetGallery { item in
                _ = home.insert(item, capacity: board.capacityKey, pageID: pageID)
                showsLibrary = false
                editing = true
                showsWidgets = false
            }
        }
        .sheet(isPresented: $showsAppPicker) {
            NavigationStack {
                Page2LibraryView(addingToHome: true, onOpen: openTool, onAdd: { tool in
                    if home.insert(.app(tool.id), capacity: board.capacityKey, pageID: pageID) {
                        editing = true
                        showsAppPicker = false
                    }
                })
                .navigationTitle("添加应用").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showsAppPicker = false } } }
            }
        }
        .sheet(isPresented: $showsAppearance) { Page2AppearanceEditor().presentationDetents([.height(appearance.displayed.rendering == "tinted" ? 390 : 290)]).presentationBackground(.clear).presentationDragIndicator(.hidden) }
        .sheet(isPresented: $showsWallpaper) { Page2WallpaperEditor() }
        .sheet(item: $configuringWidget) { Page2WidgetConfigurationView(item: $0) }
        .sheet(item: $iconTool) { Page2IconEditor(tool: $0) }
        .sheet(item: $containerItem) { item in
            Page2ContainerEditor(containerID: item.id, onOpen: openTool)
        }
        .fullScreenCover(isPresented: $showsPages) { Page2PagesEditor(capacity: board.capacityKey, currentID: pageID) { currentPageID = $0 } }
        .sheet(item: $menuItem) { item in itemMenu(item) .presentationDetents([.medium]) }
    }

    private var homeSurface: some View {
        ZStack {
            mainContent
                .opacity(showsSearch && !searchClosing ? 0 : 1)
                .blur(radius: showsSearch && !searchClosing ? 20 : ((presentedFolderID != nil && !folderDragOutside && !folderClosing) || (presentedStack != nil && !stackDragOutside) ? 4 : searchPull * 20))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: folderClosing)
                .scaleEffect(showsSearch && !searchClosing ? 0.96 : 1 - searchPull * 0.04)
                .allowsHitTesting(!showsSearch && !hasCommittedFolder && presentedStack == nil)
                .accessibilityHidden(showsSearch || presentedFolderID != nil || presentedStack != nil)
                .ignoresSafeArea(.keyboard)
            if showsSearch {
                Page2SearchView(sourceFrame: searchPillFrame, topInset: topSafeArea, closing: searchClosing,
                                onOpen: { id in showsSearch = false; searchClosing = false; openTool(id) }, onDismiss: dismissSearch,
                                onClosed: { if searchClosing { showsSearch = false; searchClosing = false; searchPull = 0 } })
                    .transition(.identity)
                    .zIndex(3)
            }
        }
        .overlay { folderOverlay }
        .overlay { stackOverlay }
        .overlay(alignment: .topLeading) { dragCarrier }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9), value: drag.folderPreview)
        .background {
            Page2WallpaperView(appearance: appearance.displayed, animated: true)
                .overlay {
                    Page2LibraryBackdrop(presentation: paging, scheme: appearance.displayed.isLightBackdrop ? .light : .dark)
                }
                .ignoresSafeArea()
        }
        .accessibilityIdentifier("page2.free-home")
        .environment(\.isPage2Active, pageScene.isActive && scenePhase != .background)
        .environment(\.page2Date, pageScene.date)
        .environment(\.colorScheme, appearance.displayed.luminosity == "dark" ? .dark : (appearance.displayed.luminosity == "light" ? .light : inheritedScheme))
    }

    @ViewBuilder private var folderOverlay: some View {
        if let id = presentedFolderID {
            let session = folderPresentationID
            let preview = folderItem?.id != id
            Page2FolderView(folderID: id, editing: editing, origin: folderOrigin(id), originSide: dockIconSide,
                            initialPage: folderGlancePages[id] ?? 0, previewItems: preview ? pendingFolderItems : nil,
                            incomingIndex: preview ? drag.folderInsertionIndex : nil,
                            incomingID: preview ? drag.sourceID : nil, incomingPage: drag.folderPage,
                            onPreviewPage: { if folderPresentationID == session { drag.selectFolderPage($0) } },
                            onPreviewPaging: { if folderPresentationID == session { drag.folderPaging = $0 } },
                            onOpen: openTool,
                            onClose: { if folderPresentationID == session, folderItem?.id == id { closeFolder() } },
                            onBeginClose: { if folderPresentationID == session { folderClosing = true } },
                            onBeginEditing: { if folderPresentationID == session { editing = true } },
                            onExternalDrag: { state, child, point, frame in
                guard folderPresentationID == session else { return false }
                return folderDragChanged(state, child, point, frame)
            })
            .id(session)
            .transition(preview ? .opacity : .identity)
        }
    }
    @ViewBuilder private var stackOverlay: some View {
        if let item = presentedStack {
            let session = stackPresentationID
            Page2StackEditor(containerID: item.id, origin: stackOrigin,
                             onClose: { if stackPresentationID == session { if stackDragOutside { cancelDrag() }; closeStack() } },
                             onExternalDrag: { state, child, point, frame in
                guard stackPresentationID == session else { return false }
                return stackDragChanged(state, child: child, at: point, frame: frame, container: item.id)
            })
            .id(session)
        }
    }

    private var homeLifecycle: some View {
        homeSurface
        .task {
            guard let tools else { return }
            home.bootstrap(toolIDs: tools.pinnedTools.map(\.id), dockIDs: Page2DesktopManager.shared.dockToolIds ?? Array(tools.pinnedTools.prefix(4).map(\.id)))
            home.ensureBoard(columns: columns, rows: rows)
        }
        .onChange(of: dynamicType) { _, _ in capacityChanged() }
        .onChange(of: profiles?.currentProfile.id) { _, _ in cancelDrag() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { resetTransientPresentation() } else { pageScene.date = Date() }
        }
        .onChange(of: pageScene.isActive) { _, active in
            if !active { resetTransientPresentation() } else if Page2DateRule.shouldWrite(old: pageScene.date, now: Date()) { pageScene.date = Date() }
        }
        .task(id: pageScene.isActive && scenePhase != .background) {
            guard pageScene.isActive && scenePhase != .background else { return }
            while !Task.isCancelled {
                let next = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date().addingTimeInterval(86400)
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                guard !Task.isCancelled else { break }
                if Page2DateRule.shouldWrite(old: pageScene.date, now: Date()) { pageScene.date = Date() }
            }
        }
    }

    private var homeDragEvents: some View {
        homeLifecycle
        .onAppear {
            topSafeArea = PagingViewController.topSafeAreaInset
            updateStatusBar()
        }
        .onChange(of: drag.sourceID) { _, source in paging.libraryEnabled = source == nil }
        .onChange(of: drag.folderPaging) { _, scrolling in
            if !scrolling, let pendingRelease { self.pendingRelease = nil; finishDrag(at: pendingRelease) }
        }
        .onChange(of: paging.isScrolling) { _, scrolling in
            if scrolling && drag.sourceID != nil { drag.suspendPaging() }
            if !scrolling, drag.sourceID != nil { updateDrag(drag.point) }
            if !scrolling, let pendingRelease { self.pendingRelease = nil; finishDrag(at: pendingRelease) }
        }
        .onChange(of: editing) { _, value in if !value { folderGlancePages.removeAll(); resize.cancel() }; updateStatusBar() }
        .onChange(of: home.layout) { _, layout in layoutChanged(layout) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in isKeyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in isKeyboardVisible = false }
        .onChange(of: previewFolderID) { _, id in if id != nil && folderItem == nil { folderPresentationID = UUID(); folderClosing = false } }
    }

    private var observedHome: some View {
        homeDragEvents
        .onChange(of: stackItem?.id) { _, _ in updateStatusBar() }
        .onChange(of: modalPresented) { _, presented in if presented { resize.cancel() } }
        .onChange(of: appearance.displayed.wallpaper) { _, _ in updateStatusBar() }
        .onChange(of: appearance.displayed.wantsDarkForeground) { _, _ in updateStatusBar() }
        .onChange(of: appearance.displayed.dimming) { _, _ in updateStatusBar() }
        .onDisappear(perform: leaveHome)
    }

    private func leaveHome() {
        resetTransientPresentation()
        pageScene.isEditing = false
        pageScene.prefersLightStatusBar = false
        PagingViewController.refreshStatusBar()
    }

    private var activeHome: some View {
        observedHome
        .task(id: drag.sourceID) {
            while drag.sourceID != nil && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, drag.sourceID != nil else { break }
                guard !paging.isScrolling && !drag.folderPaging else { continue }
                updateDrag(drag.point)
                let direction = drag.edge(at: drag.point, width: gridSize.width)
                if direction != 0 { turnPage(direction, adding: true) }
            }
        }
    }

    private var pagePosition: Int { showsLibrary ? visiblePages.count : pageIndex }

    private var mainContent: some View {
        GeometryReader { geometry in
            Page2GestureContainer(editing: editing, library: showsLibrary, isPaging: { paging.isScrolling || !paging.stackScrolling.isEmpty }, isDragging: { drag.sourceID != nil }, paging: paging, enabled: pageScene.isActive && scenePhase == .active && !hasCommittedFolder && !showsSearch && !modalPresented && resize.sourceID == nil, available: { !modalPresented && !showsSearch && !hasCommittedFolder && resize.sourceID == nil && paging.stackScrolling.isEmpty }, excludesTouchAt: resizeHandleContains, excludesSearchAt: stackContains,
                                  coordinateInset: 32, dockHeight: dockIconSide + 2 * metrics.dockVerticalInset, location: drag.location, onTap: editTapped,
                                  onSnapshot: { drag.previewImage = $0 }, menuAt: dragTarget, menuFor: contextMenu, onSecondaryTap: secondaryTapped, onPress: pressChanged, onPan: panChanged, probeState: probeState) {
                ZStack(alignment: .topLeading) {
                    Page2NativePager(selection: Binding(get: { pagePosition }, set: selectPage), pageCount: visiblePages.count + (drag.sourceID == nil ? 1 : 0), editing: editing,
                                     presentation: paging, trailingHandoff: true) {
                        HStack(spacing: 0) {
                            ForEach(visiblePages) { page in
                                VStack(spacing: 0) {
                                    Color.clear.frame(height: 32)
                                    grid(on: page.id).frame(width: geometry.size.width, height: gridSize.height, alignment: .topLeading)
                                    Spacer(minLength: 0)
                                }.frame(width: geometry.size.width, height: geometry.size.height)
                                .accessibilityHidden(showsLibrary || page.id != pageID)
                            }
                            if drag.sourceID == nil { Page2LibraryView(isActive: showsLibrary, onOpen: openTool, onAdd: { tool in
                                _ = home.insert(.app(tool.id), capacity: board.capacityKey, pageID: pageID)
                                showsLibrary = false
                                editing = true
                            }, onBeginDrag: { showsLibrary = false; editing = false })
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .accessibilityHidden(!showsLibrary) }
                        }
                        .frame(width: geometry.size.width * CGFloat(visiblePages.count + (drag.sourceID == nil ? 1 : 0)), height: geometry.size.height, alignment: .topLeading)
                    }
                    Page2PagingChrome(presentation: paging) {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            pageControl.padding(.bottom, 24)
                            dock
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .onDrop(of: [UTType.text], isTargeted: nil) { providers, location in
                    receiveDrop(providers, at: CGPoint(x: location.x, y: location.y - 32))
                }
            }
            .padding(.bottom, -metrics.dockBottomExtension)
            .overlay(alignment: .top) {
                // 不能在这里直接读 `geometry.frame(in: .global)`：外层翻页每帧平移 page2 容器、全局 frame 每帧变，
                // GeometryReader 闭包就每帧重跑，把 GestureContainer / NativePager 两层托管连同所有桌面页的玻璃网格
                // 一起重建（真机探针：两次翻页两层各 ~200 次 update、grid body 90 次/s；docs/research-page2-ios-hangs.md §3）。
                // 只要 minY，走 onGeometryChange 去重：翻页时 minY 不变就不触发。
                topBar
                    .offset(y: max(22, topSafeArea / 2 + 2) - homeGlobalMinY - 16)
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { homeGlobalMinY = $0 }
            .onAppear { lastViewport = geometry.size; setViewport(geometry.size); topSafeArea = PagingViewController.topSafeAreaInset }
            .onChange(of: geometry.size) { _, size in viewportChanged(size) }
            .onChange(of: showsLibrary) { _, active in if !active { setViewport(geometry.size) } }
        }
        .coordinateSpace(name: "page2-home")
    }

    /// 视口量尺的键盘守卫（照 `ContentView:675` 那套配方）：这层在 `.ignoresSafeArea(.keyboard)` 外面，键盘一弹量到的
    /// 就是被压矮的高 → 行数变 → `ensureBoard` 投影一张新容量的板、所有玻璃图标整批重建（真机 trace 0.85s hang，
    /// docs/research-page2-ios-hangs.md §3）。「同宽 + 变矮一大截」延后一拍再认：那时 keyboardWillShow 必已到，
    /// 键盘引起的忽略；真缩窗（Stage Manager / 转屏）照收。变高、变宽一律立刻认。
    private func viewportChanged(_ size: CGSize) {
        if size.width == lastViewport.width, size.height < lastViewport.height - 100 {
            DispatchQueue.main.async {
                guard !isKeyboardVisible else { return }
                lastViewport = size
                setViewport(size)
            }
            return
        }
        lastViewport = size
        setViewport(size)
    }

    private func setViewport(_ size: CGSize) {
        guard !showsSearch && !showsLibrary && presentedFolderID == nil && presentedStack == nil else { return }
        gridOrigin = CGPoint(x: 0, y: 32)
        setGridSize(CGSize(width: size.width, height: max(1, size.height - Page2SystemMetrics(width: size.width, height: size.height).iconSide - (appearance.displayed.largeIcons ? 12 : 0) - 118)))
    }
    private var pageSpring: Animation? { reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86) }

    private var topBar: some View {
        HStack {
            if editing {
                Menu {
                    Button("添加应用", systemImage: "plus.app") { showsAppPicker = true }
                    Button("添加小组件", systemImage: "plus.rectangle") { showsWidgets = true }
                    Button("自定", systemImage: "paintpalette") { showsAppearance = true }
                    Button("更换壁纸", systemImage: "photo") { showsWallpaper = true }
                    Button("编辑页面", systemImage: "square.grid.2x2") { showsPages = true }
                    Button("导入旧桌面组件", systemImage: "square.and.arrow.down") { home.importLegacy(capacity: board.capacityKey) }
                    Button("恢复默认布局", systemImage: "arrow.counterclockwise", role: .destructive) { resetConfirmation = true }
                    Button("撤销上次摆放", systemImage: "arrow.uturn.backward") { home.undo() }.disabled(home.previousLayout == nil)
                } label: { Text("编辑").frame(width: 44, height: 18) }
                .modifier(Page2EditingButtonStyle()).controlSize(.small).accessibilityIdentifier("page2.edit-menu")
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
            Spacer()
            if editing {
                Button {
                    cancelDrag()
                    editing = false
                    home.cleanEmptyPages(capacity: board.capacityKey)
                } label: { Text("完成").frame(width: 44, height: 18) }
                .modifier(Page2EditingButtonStyle()).controlSize(.small)
            } else {
                Menu {
                    Button("编辑主屏", systemImage: "square.grid.3x3") { editing = true; showsLibrary = false }
                    Button("添加小组件", systemImage: "plus.rectangle") { showsWidgets = true }
                    Button("主屏外观", systemImage: "paintpalette") { showsAppearance = true }
                    Button("导入旧桌面组件", systemImage: "square.and.arrow.down") { home.importLegacy(capacity: board.capacityKey) }
                    Button("恢复默认布局", systemImage: "arrow.counterclockwise", role: .destructive) { resetConfirmation = true }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 32) }
                .buttonStyle(.glass).accessibilityLabel("主屏选项")
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, max(36, gridSize.width * 50 / 440))
        .frame(height: 32)
        .opacity(editing && !showsLibrary ? 1 : 0)
        .allowsHitTesting(editing && !showsLibrary)
    }

    private func grid(on page: UUID) -> some View {
        Page2GridView(home: home, drag: drag, resize: resize, board: board, pageID: page, editing: editing, gridSize: gridSize, iconSide: dockIconSide, showLabels: !appearance.displayed.largeIcons,
                      frame: { frame($0, at: $1) }, isVisible: isVisible, title: title,
                      cell: { cell($0, visible: $1, interactive: $2) },
                      editLayout: { editing = true }, editItem: { menuItem = $0 }, resizeItem: resizeChanged)
    }

    @ViewBuilder private var dragCarrier: some View {
        if let id = drag.sourceID, let item = home.layout.item(id) {
            Page2DragCarrierView(location: drag.location, item: item, tool: tools?.tool(byId: item.toolID ?? ""),
                                 iconSide: metrics.iconSide, size: itemSize(item), offset: drag.offset,
                                 dockRect: dockDropRect, image: drag.previewImage, overFolder: drag.folderHoverTarget != nil && !drag.folderPreview)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    @ViewBuilder private func cell(_ item: Page2Item, visible: Bool, interactive: Bool) -> some View {
        if !visible {
            VStack(spacing: 5) { Image(systemName: "eye.slash"); Text("保留位置").font(.caption2) }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        } else if item.kind == "app", let tool = tools?.tool(byId: item.toolID ?? "") {
            Page2AppIcon(tool: tool, side: metrics.iconSide, interactive: interactive, editing: editing && drag.sourceID != item.id && resize.sourceID != item.id) { openTool(tool.id) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(interactive)
        } else if item.kind == "widget" {
            VStack(spacing: 4) {
                Page2WidgetHost(item: item, preview: false, onOpen: openTool)
                    .frame(height: widgetHeight(item))

                if !appearance.displayed.largeIcons { Text(title(item)).font(.system(size: 12)).modifier(Page2DesktopLabel()) }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("page2.widget.\(item.widgetKind ?? item.id.uuidString)")
            .modifier(Page2EditingMotion(enabled: editing && drag.sourceID != item.id && resize.sourceID != item.id, seed: Int(item.id.uuid.0), amplitude: 0.3, pivotHeight: metrics.height(item.span)))
                .allowsHitTesting(interactive)
        } else if item.kind == "stack" {
            Page2StackView(item: item, height: widgetHeight(item), showLabel: !appearance.displayed.largeIcons, onOpen: openTool, onScrolling: { active in
                paging.trace?("STACK scrolling=\(active) id=\(item.id)")
                if active { paging.stackScrolling.insert(item.id) } else { paging.stackScrolling.remove(item.id) }
            })
            .accessibilityIdentifier("page2.stack.\(item.id.uuidString)")
            .modifier(Page2EditingMotion(enabled: editing && drag.sourceID != item.id && resize.sourceID != item.id, seed: Int(item.id.uuid.0), amplitude: 0.3, pivotHeight: metrics.height(item.span)))
            .allowsHitTesting(interactive)
        } else if item.kind == "folder" {
            VStack(spacing: 5) {
                Page2FolderIcon(pages: item.childPages.map { $0.compactMap { home.layout.item($0) } }, side: dockIconSide, page: drag.folderHoverTarget == item.id ? Page2FolderPages.appendPosition(in: item.childPages).page : (folderGlancePages[item.id] ?? 0))
                if !appearance.displayed.largeIcons { Text(item.title).font(.system(size: 12)).lineLimit(1).modifier(Page2DesktopLabel()) }
            }
            .contentShape(Rectangle())
            .modifier(Page2EditingMotion(enabled: editing && drag.sourceID != item.id && resize.sourceID != item.id, seed: Int(item.id.uuid.0), pivotHeight: dockIconSide))
            .onTapGesture { if drag.sourceID == nil { openFolder(item) } }
            .accessibilityElement(children: .ignore).accessibilityLabel(item.title)
            .accessibilityIdentifier("page2.folder.\(item.id.uuidString)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if drag.sourceID == nil { openFolder(item) } }
            .allowsHitTesting(drag.sourceID == nil)
        } else {
            Text("暂不支持的组件").font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(Page2WidgetSurface())
        }
    }

    private var pageControl: some View {
        Page2HomePageControl(presentation: paging, pages: visiblePages, currentID: pageID, editing: editing) {
            if editing { showsPages = true } else { presentSearch() }
        }
        .background(WindowFrameProbeView(probe: searchPillProbe))
    }
    private func selectPage(_ index: Int) {
        showsLibrary = index == visiblePages.count
        if visiblePages.indices.contains(index) {
            let id = visiblePages[index].id
            currentPageID = id
            if drag.sourceID != nil {
                drag.selectPage(id, in: board)
                if let preview = drag.preview { workingBoard = preview }
                ensureTrailingPage()
            }
        }
    }

    private var dockIconSide: CGFloat { metrics.iconSide + (appearance.displayed.largeIcons ? 12 : 0) }

    private var dockItems: [Page2Item] {
        (drag.dockPreview ?? home.layout.dockItemIDs ?? [])
            .filter { drag.dockPreview != nil || $0 != drag.sourceID }
            .compactMap(home.layout.item).filter(isVisible)
    }
    private var dockSpacing: CGFloat { max(16, (gridSize.width - 72 - dockIconSide * 4) / 3) }
    private func dockFrame(_ id: UUID) -> CGRect? {
        guard let rect = dockIconProbes[id]?.windowFrame, let origin = drag.location.windowPoint(for: .zero) else { return nil }
        return rect.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    private var dock: some View {
        ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
            ZStack {
                GlassEffectContainer(spacing: 0) { dockIcons }
                dockBadges
            }
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: dockItems.map(\.id))
        }
        .frame(height: dockIconSide + 2 * metrics.dockVerticalInset)
        .onDrop(of: [UTType.text], isTargeted: nil) { providers in receiveDockDrop(providers, before: nil) }
        .background { Page2DockSurface(cornerRadius: metrics.dockCornerRadius) }
        .background(WindowFrameProbeView(probe: dockProbe))
        .accessibilityIdentifier("page2.dock")
        .padding(.horizontal, 18).padding(.bottom, -metrics.dockBottomExtension)
    }

    private var dockIcons: some View {
        HStack(spacing: dockSpacing) {
            ForEach(dockItems) { item in
                Group {
                    if drag.sourceID == item.id { Color.clear.accessibilityHidden(true) }
                    else if item.kind == "folder" || drag.mergeTarget == item.id {
                        Button {
                            if drag.sourceID == nil, item.kind == "folder" { openFolder(item) }
                        } label: {
                            Color.clear.frame(width: dockIconSide, height: dockIconSide)
                                .overlay { Page2FolderIcon(pages: item.kind == "folder" ? item.childPages.map { $0.compactMap { home.layout.item($0) } } : [[item]], side: dockIconSide) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .modifier(Page2EditingMotion(enabled: editing, seed: Int(item.id.uuid.0), pivotHeight: dockIconSide))
                        .accessibilityLabel(item.kind == "folder" ? item.title : "文件夹")
                        .accessibilityIdentifier("page2.folder.\(item.id.uuidString)")
                    } else if let tool = tools?.tool(byId: item.toolID ?? "") {
                        Page2AppIcon(tool: tool, side: metrics.iconSide, label: false, interactive: !editing && drag.sourceID == nil, editing: editing) { openTool(tool.id) }
                    }
                }
                .frame(width: dockIconSide, height: dockIconSide)
                .transition(.identity)
                .background(WindowFrameProbeView(probe: dockIconProbes.probe(for: item.id)))
            }
        }
        .frame(minWidth: max(0, gridSize.width - 72)).padding(.horizontal, 18).padding(.vertical, metrics.dockVerticalInset)
    }

    private var dockBadges: some View {
        HStack(spacing: dockSpacing) {
            ForEach(dockItems) { item in
                Color.clear.frame(width: dockIconSide, height: dockIconSide).allowsHitTesting(false)
                    .overlay(alignment: .topLeading) {
                        if drag.sourceID != item.id {
                            Page2RemoveBadge(label: "从 Dock 移除\(title(item))", editing: editing) { home.remove(item.id) }
                                .offset(x: Page2RemoveBadge.originOffset, y: Page2RemoveBadge.originOffset)
                                .transition(.identity)
                        }
                    }
                    .modifier(Page2EditingMotion(enabled: editing && drag.sourceID != item.id,
                                                 seed: item.kind == "app" && drag.mergeTarget != item.id ? (tools?.tool(byId: item.toolID ?? "")?.order ?? 0) : Int(item.id.uuid.0),
                                                 pivotHeight: dockIconSide))
                    .transition(.identity)
            }
        }.frame(minWidth: max(0, gridSize.width - 72)).padding(.horizontal, 18).padding(.vertical, metrics.dockVerticalInset)
    }

    /// 长按失效排查（粟粟 10-14 Air，疑竖条后台相关）：enabled / available 的每一项 + 外壳竖条状态
    private func probeState() -> String {
        let shell = Page2AppShell.shared, scene = Page2SceneState.shared
        return "home: sceneActive=\(pageScene.isActive) phase=\(scenePhase) folder=\(hasCommittedFolder) search=\(showsSearch) resize=\(resize.sourceID != nil) " +
            "scrolling=\(paging.isScrolling) stacks=\(paging.stackScrolling.count) library=\(showsLibrary) " +
            "modal=\(modalPresented)[w=\(showsWidgets) pick=\(showsAppPicker) look=\(showsAppearance) wall=\(showsWallpaper) pages=\(showsPages) reset=\(resetConfirmation) " +
            "menuItem=\(menuItem != nil) container=\(containerItem != nil) stack=\(presentedStack != nil) config=\(configuringWidget != nil) icon=\(iconTool != nil) " +
            "homeErr=\(home.errorMessage != nil) lookErr=\(appearance.errorMessage != nil)] " +
            "shell: strip=\(shell.stripProgress) stripOpen=\(scene.stripOpen) stripMoving=\(scene.stripTransitioning) stripPan=\(Page2StripPan.shared.isEnabled) " +
            "motion=\(shell.motion != nil) switcher=\(shell.showsSwitcher) open=\(shell.stack.openApps.count) appCover=\(scene.hidesStatusBarForApp) editing=\(scene.isEditing)"
    }

    private func dragTarget(at point: CGPoint) -> Page2DragTarget? {
        guard !showsLibrary, let (item, rect) = hit(point) else { return nil }
        let icon = ["app", "folder"].contains(item.kind)
        let preview = icon ? CGRect(x: rect.midX - dockIconSide / 2, y: rect.minY, width: dockIconSide, height: dockIconSide) : CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: metrics.height(item.span))
        return Page2DragTarget(id: item.id, frame: rect, snapshotRequired: !["app", "folder", "widget", "stack"].contains(item.kind), previewFrame: preview)
    }

    private func contextMenu(_ id: UUID) -> UIMenu? {
        guard let item = home.layout.item(id) else { return nil }
        var actions: [UIMenuElement] = []
        if home.layout.dockItemIDs?.contains(id) != true && ["app", "widget", "stack"].contains(item.kind) {
            let sizes = (item.toolID == nil ? [] : [Page2Span.icon]) + Page2Span.widgetSizes
            let options = sizes.map { span in
                UIAction(title: span.title, image: UIImage(systemName: span == .icon ? "app" : (span.columns == span.rows ? "square.grid.2x2" : "rectangle")), state: item.span == span ? .on : .off) { _ in
                    _ = home.change(item.id, span: span)
                }
            }
            actions.append(UIMenu(options: [.displayAsPalette, .displayInline], children: options))
        }
        actions.append(UIAction(title: "编辑主屏幕", image: UIImage(systemName: "square.grid.3x3")) { _ in editing = true; showsLibrary = false })
        if item.kind == "widget" {
            actions.append(UIAction(title: "编辑小组件", image: UIImage(systemName: "slider.horizontal.3")) { _ in configuringWidget = item })
        }
        if item.kind == "stack" {
            actions.append(UIAction(title: "编辑叠放", image: UIImage(systemName: "square.stack")) { _ in openStack(item) })
            let recent = UserDefaults.standard.string(forKey: "page2RecentTool_v1") ?? ""
            if item.configuration["widgetSuggestions"] != "false", item.children.count < 10,
               !item.children.contains(where: { home.layout.item($0)?.toolID == recent }),
               let tool = tools?.tool(byId: recent), tool.isEnabled {
                actions.append(UIAction(title: "添加“\(tool.name)”建议组件", image: UIImage(systemName: "plus")) { _ in
                    _ = home.addWidget(.widget(recent, span: item.span), toStack: item.id)
                })
            }
        }
        if let tool = tools?.tool(byId: item.toolID ?? "") {
            actions.append(UIAction(title: "更换图标", image: UIImage(systemName: "paintbrush")) { _ in iconTool = tool })
        }
        if item.kind == "folder" {
            actions.append(UIAction(title: "重新命名", image: UIImage(systemName: "pencil")) { _ in editing = true; openFolder(item) })
        }
        actions.append(UIAction(title: home.layout.dockItemIDs?.contains(id) == true ? "从 Dock 移除" : "从主屏移除", image: UIImage(systemName: "minus.circle"), attributes: .destructive) { _ in home.remove(item.id) })
        return UIMenu(children: actions)
    }
    private func secondaryTapped(_ point: CGPoint) {
        guard drag.sourceID != nil, let item = hit(point)?.0, item.kind == "folder" else { return }
        drag.openFolder(item.id, frame: folderPreviewFrame)
    }

    private func itemMenu(_ item: Page2Item) -> some View {
        NavigationStack {
            List {
                if ["app", "widget", "stack"].contains(item.kind) {
                    Section("显示为") {
                        ForEach((item.toolID == nil ? [] : [Page2Span.icon]) + Page2Span.widgetSizes, id: \.self) { span in
                            Button(span.title) { _ = home.change(item.id, span: span); menuItem = nil }
                        }
                    }
                }
                if item.kind == "widget" {
                    Button("编辑小组件", systemImage: "slider.horizontal.3") {
                        menuItem = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { configuringWidget = item }
                    }
                }
                if let tool = tools?.tool(byId: item.toolID ?? "") {
                    Button("更换图标", systemImage: "paintbrush") { menuItem = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { iconTool = tool } }
                    Button("钉到 Dock", systemImage: "pin") { _ = home.moveToDock(item.id, at: home.layout.dockItems.count); menuItem = nil }
                }
                if item.isContainer {
                    Button("编辑内容", systemImage: "square.stack") { menuItem = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if item.kind == "stack" { openStack(item) } else { containerItem = item } } }
                }
                Section("移动到空位") {
                    ForEach(emptyPositions(for: item), id: \.self) { value in
                        Button("第\(value / board.columns + 1)行，第\(value % board.columns + 1)列") {
                            if let next = try? Page2GridEngine.place(item, on: pageID, row: value / board.columns,
                                                                    column: value % board.columns, in: board, items: home.layout.rootItems, reserved: reserved) {
                                _ = home.commit(next, basedOn: home.layout)
                            }
                            menuItem = nil
                        }
                    }
                }
                Button("从主屏移除", systemImage: "minus.circle", role: .destructive) { home.remove(item.id); menuItem = nil }
            }
            .navigationTitle(title(item)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { menuItem = nil } } }
        }
    }

    private func emptyPositions(for item: Page2Item) -> [Int] {
        (0..<(board.columns * board.rows)).filter { n in
            let p = Page2Placement(id: item.id, pageID: pageID, row: n / board.columns, column: n % board.columns)
            return Page2GridEngine.fits(item.span, row: p.row, column: p.column, board: board) && board.placements.allSatisfy { other in
                guard other.id != item.id, let otherItem = home.layout.item(other.id) else { return true }
                return !Page2GridEngine.overlaps(p, item.span, other, otherItem.span)
            }
        }
    }

    private func isVisible(_ item: Page2Item) -> Bool {
        if item.isContainer { return item.children.contains { id in home.layout.item(id).map(isVisible) ?? false } }
        guard let id = item.toolID else { return true }
        guard let tool = tools?.tool(byId: id) else { return false }
        return tool.isEnabled && tools?.isVisibleInCurrentMode(tool) == true
    }

    private func title(_ item: Page2Item) -> String {
        if !item.title.isEmpty { return item.title }
        return tools?.tool(byId: item.toolID ?? "")?.name ?? Page2WidgetCatalog.name(item.widgetKind ?? "")
    }

    private func widgetHeight(_ item: Page2Item) -> CGFloat {
        if resize.sourceID == item.id, let rect = resize.visualFrame { return rect.height - (appearance.displayed.largeIcons ? 0 : 20) }
        return metrics.height(item.span)
    }
    private func itemSize(_ item: Page2Item) -> CGSize {
        if resize.sourceID == item.id, let rect = resize.visualFrame { return rect.size }
        let largeIcon = ["app", "folder"].contains(item.kind) && appearance.displayed.largeIcons
        return CGSize(width: largeIcon ? max(metrics.width(item.span), metrics.iconSide + 12) : metrics.width(item.span),
                      height: largeIcon ? metrics.iconSide + 12 : metrics.height(item.span) + (appearance.displayed.largeIcons ? 0 : 20))
    }
    private func frame(_ item: Page2Item, at p: Page2Placement) -> CGRect {
        if resize.sourceID == item.id, let rect = resize.visualFrame { return rect }
        return CGRect(origin: CGPoint(x: gutter + CGFloat(p.column) * cellSize.width + (metrics.width(item.span) - itemSize(item).width) / 2 + gap / 2, y: CGFloat(p.row) * cellSize.height + gap / 2), size: itemSize(item))
    }
    private func stackContains(_ point: CGPoint) -> Bool {
        guard let (item, rect) = hit(point), item.kind == "stack" else { return false }
        return point.y < rect.minY + metrics.height(item.span)
    }
    private func resizeHandleContains(_ point: CGPoint) -> Bool {
        guard editing, !showsLibrary, drag.sourceID == nil else { return false }
        for placement in board.placements where placement.pageID == pageID {
            guard let item = (resize.preview ?? home.layout).item(placement.id), isVisible(item), ["widget", "stack"].contains(item.kind) else { continue }
            let rect = frame(item, at: placement)
            let hit = CGRect(x: rect.maxX - 31, y: rect.maxY - (appearance.displayed.largeIcons ? 0 : 20) - 31, width: 44, height: 44)
            if hit.contains(point) { return true }
        }
        return false
    }
    private func resizeChanged(_ item: Page2Item, state: UIGestureRecognizer.State, translation: CGSize) {
        switch state {
        case .began:
            guard editing, drag.sourceID == nil, let placement = board.placements.first(where: { $0.id == item.id }) else { return }
            _ = resize.begin(item.id, layout: home.layout, board: board, frame: frame(item, at: placement), metrics: metrics,
                             labelHeight: appearance.displayed.largeIcons ? 0 : 20,
                             bounds: CGRect(x: gutter, y: 0, width: metrics.contentWidth, height: gridSize.height))
        case .changed:
            if resize.sourceID == item.id { resize.update(translation) }
        case .ended:
            guard resize.sourceID == item.id else { return }
            resize.update(translation)
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) { resize.finish(in: home) }
        case .cancelled, .failed:
            if resize.sourceID == item.id { withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) { resize.cancel() } }
        default: break
        }
    }
    private func hit(_ point: CGPoint) -> (Page2Item, CGRect)? {
        for item in home.layout.dockItems where isVisible(item) {
            if let rect = dockFrame(item.id), rect.contains(point) { return (item, rect) }
        }
        for p in (drag.preview ?? board).placements where p.pageID == pageID {
            if let item = home.layout.item(p.id), isVisible(item), frame(item, at: p).contains(point) { return (item, frame(item, at: p)) }
        }
        return nil
    }
    private func pressChanged(_ state: UIGestureRecognizer.State, _ point: CGPoint) {
        switch state {
        case .began:
            guard !showsLibrary else { return }
            editing = true
            if let (item, rect) = hit(point) {
                drag.begin(item.id, at: point, frame: rect, layout: home.layout, board: board)
                ensureTrailingPage()
            }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .changed: updateDrag(point)
        case .ended:
            let tapped = !drag.moved ? drag.sourceID.flatMap { home.layout.item($0) } : nil
            finishDrag(at: point)
            _ = tapped
        case .cancelled, .failed: cancelDrag()
        default: break
        }
    }
    private func panChanged(_ state: UIGestureRecognizer.State, _ point: CGPoint, _ translation: CGSize, _ velocity: CGSize) {
        if editing && !showsLibrary {
            if state == .began, let (item, rect) = hit(CGPoint(x: point.x - translation.width, y: point.y - translation.height)) {
                drag.begin(item.id, at: CGPoint(x: point.x - translation.width, y: point.y - translation.height), frame: rect, layout: home.layout, board: board)
            }
            if drag.sourceID != nil {
                if state == .changed { updateDrag(point) }
                else if state == .ended { finishDrag(at: point) }
                else if state == .cancelled { cancelDrag() }
                return
            }
        }
        if !editing && !showsLibrary {
            if state == .changed { searchPull = min(1, max(0, translation.height / 160)) }
            if state == .ended {
                if translation.height > 55 || velocity.height > 500 { presentSearch() }
                else { withAnimation(pageSpring) { searchPull = 0 } }
            } else if state == .cancelled { withAnimation(pageSpring) { searchPull = 0 } }
            return
        }
    }
    private func presentSearch() {
        // 胶囊起点在打开那一刻量一次（原来就是搜索期间冻结、收起动画回到同一处）
        if let frame = searchPillProbe.windowFrame { searchPillFrame = frame }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.32)) { searchClosing = false; showsSearch = true; searchPull = 0 }
    }
    private func dismissSearch() {
        guard showsSearch, !searchClosing else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) { searchClosing = true; searchPull = 0 }
    }
    private var dockDropRect: CGRect {
        guard let origin = drag.location.windowPoint(for: .zero), let dock = dockProbe.windowFrame else { return .zero }
        return dock.offsetBy(dx: -origin.x, dy: -origin.y)
    }
    private func finishDrag(at point: CGPoint) {
        guard !drag.location.isLanding else { return }
        if paging.isScrolling || drag.folderPaging { pendingRelease = point; return }
        paging.trace?("DROP point=\(point) dock=\(dockDropRect) frames=\(home.layout.dockItems.compactMap { dockFrame($0.id) }) source=\(String(describing: drag.sourceID))")
        if dockDropRect.contains(point), !drag.folderPreview {
            updateDrag(point)
            if drag.prepareFolderDrop() == nil {
                paging.trace?("DOCK insertion=\(String(describing: drag.dockInsertion)) canLand=\(drag.canLand) baseline=\(drag.snapshot == home.layout)")
                if let id = drag.sourceID, let rect = dockFrame(id), drag.dockInsertion != nil {
                    drag.location.land(at: CGPoint(x: rect.minX + drag.offset.width, y: rect.minY + drag.offset.height)) {
                        guard drag.sourceID == id else { return }
                        drag.finishDock(store: home); workingBoard = nil
                    }
                } else { drag.finishDock(store: home); workingBoard = nil }
                return
            }
        }
        updateDrag(point)
        let valid = CGRect(origin: .zero, size: gridSize).contains(point) || dockDropRect.contains(point) || (drag.folderPreview && folderPreviewFrame?.contains(point) == true)
        if valid, let source = drag.sourceID, let target = drag.prepareStackDrop(),
           let targetItem = home.layout.item(target), let placement = (drag.preview ?? board).placements.first(where: { $0.id == target }) {
            let rect = frame(targetItem, at: placement)
            drag.location.land(at: CGPoint(x: rect.minX + drag.offset.width, y: rect.minY + drag.offset.height)) {
                guard drag.sourceID == source else { return }
                drag.finish(store: home, valid: true); workingBoard = nil
            }
            return
        }
        if valid, let source = drag.sourceID, let item = home.layout.item(source), item.kind == "app",
           let target = drag.prepareFolderDrop(), let targetItem = home.layout.item(target) {
            let remainsOpen = drag.folderPreview
            if remainsOpen, let resolved = drag.resolvedFolderPosition(), resolved.page != drag.folderPage {
                drag.selectFolderPage(resolved.page, slot: resolved.slot)
                pendingRelease = point
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard drag.sourceID == source, pendingRelease != nil, !drag.folderPaging else { return }
                    pendingRelease = nil
                    finishDrag(at: point)
                }
                return
            }
            let closedPosition = targetItem.kind == "folder" ? Page2FolderPages.appendPosition(in: targetItem.childPages) : (page: 0, slot: 1)
            let index = remainsOpen ? (drag.resolvedFolderPosition()?.slot ?? 0) : closedPosition.slot
            let slot: CGRect?
            if remainsOpen, let panel = folderPreviewFrame {
                slot = Page2FolderGeometry.childFrame(index, in: panel)
            } else if let rect = dockFrame(target), home.layout.dockItemIDs?.contains(target) == true {
                slot = Page2FolderGeometry.miniatureFrame(index, side: dockIconSide).offsetBy(dx: rect.minX, dy: rect.minY)
            } else if let placement = (drag.preview ?? board).placements.first(where: { $0.id == target }) {
                let targetFrame = frame(targetItem, at: placement)
                slot = Page2FolderGeometry.miniatureFrame(index, side: dockIconSide).offsetBy(dx: targetFrame.minX, dy: targetFrame.minY)
            } else { slot = nil }
            guard let slot else { cancelDrag(); return }
            let sourceSide = itemSize(item).width
            let targetPoint = CGPoint(x: slot.midX - sourceSide / 2 + drag.offset.width,
                                      y: slot.minY + slot.width / 2 - sourceSide / 2 + drag.offset.height)
            drag.location.land(at: targetPoint, scale: slot.width / sourceSide, absorbing: !remainsOpen) {
                guard drag.sourceID == source else { return }
                paging.trace?("DOCK merge completion moved=\(drag.moved) same=\(drag.snapshot == home.layout) sourceDock=\(home.layout.dockItemIDs?.contains(source) == true) targetDock=\(home.layout.dockItemIDs?.contains(target) == true)")
                let committed = drag.finish(store: home, valid: true)
                paging.trace?("DOCK merge saved=\(committed) error=\(home.errorMessage ?? "none")")
                workingBoard = nil
                if committed,
                   let folder = home.layout.items.first(where: { $0.kind == "folder" && $0.children.contains(source) && ($0.id == target || $0.children.contains(target)) }) {
                    if remainsOpen { folderItem = folder }
                    else { folderGlancePages[folder.id] = closedPosition.page }
                }
            }
            return
        }
        if valid, drag.canLand, let id = drag.sourceID, let item = home.layout.item(id), let placement = drag.destination {
            let target = frame(item, at: placement)
            drag.location.land(at: CGPoint(x: target.minX + drag.offset.width, y: target.minY + drag.offset.height)) {
                guard drag.sourceID == id else { return }
                drag.finish(store: home, valid: true)
                workingBoard = nil
            }
        } else {
            drag.finish(store: home, valid: valid)
            workingBoard = nil
        }
    }

    private func openStack(_ item: Page2Item) {
        guard home.layout.item(item.id)?.kind == "stack", let placement = board.placements.first(where: { $0.id == item.id }) else { return }
        let rect = frame(item, at: placement)
        if let origin = drag.location.windowPoint(for: rect.origin) { stackOrigin = CGRect(origin: origin, size: rect.size) }
        if stackItem?.id == item.id { return }
        stackPresentationID = UUID()
        stackItem = item
    }
    private func stackDragChanged(_ state: UIGestureRecognizer.State, child: Page2Item, at point: CGPoint, frame: CGRect, container: UUID) -> Bool {
        guard stackItem?.id == container, let origin = drag.location.windowPoint(for: .zero) else { return false }
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        drag.location.update(local: local, window: point)
        if state == .began {
            guard drag.sourceID == nil, let draft = home.extractedLayout(child.id, from: container),
                  let draftBoard = draft.boards.first(where: { $0.capacityKey == board.capacityKey }) else { return false }
            let size = itemSize(child)
            let offset = CGPoint(x: (point.x - frame.minX) / max(1, frame.width) * size.width,
                                 y: (point.y - frame.minY) / max(1, frame.height) * size.height)
            drag.begin(child.id, at: local, frame: CGRect(x: local.x - offset.x, y: local.y - offset.y, width: size.width, height: size.height),
                       layout: draft, board: draftBoard, container: container, baseline: home.layout)
            guard drag.sourceID == child.id else { return false }
            stackDragOutside = true; editing = true; updateDrag(local)
            return true
        }
        guard drag.sourceID == child.id else { return false }
        if state == .changed { updateDrag(local) }
        else if state == .ended { finishDrag(at: local); closeStack() }
        else if state == .cancelled || state == .failed { cancelDrag(); stackDragOutside = false }
        return true
    }

    private func folderDragChanged(_ state: UIGestureRecognizer.State, _ child: Page2Item, _ point: CGPoint, _ sourceFrame: CGRect) -> Bool {
        guard let origin = drag.location.windowPoint(for: .zero) else { return false }
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        drag.location.update(local: local, window: point)
        if state == .began {
            guard drag.sourceID == nil, let container = folderItem?.id,
                  let draft = home.extractedLayout(child.id, from: container),
                  let draftBoard = draft.boards.first(where: { $0.capacityKey == board.capacityKey }) else { return false }
            drag.begin(child.id, at: local, frame: sourceFrame.offsetBy(dx: -origin.x, dy: -origin.y),
                       layout: draft, board: draftBoard, container: container, baseline: home.layout)
            guard drag.sourceID == child.id else { return false }
            folderDragOutside = true; editing = true; updateDrag(local)
            return true
        }
        guard drag.sourceID == child.id else { return false }
        if state == .changed { updateDrag(local) }
        else if state == .ended { updateDrag(local); finishDrag(at: local); closeFolder() }
        else if state == .cancelled || state == .failed { cancelDrag() }
        return true
    }

    private func folderOrigin(_ id: UUID) -> CGPoint {
        if home.layout.dockItemIDs?.contains(id) == true, let live = dockIconProbes[id]?.windowFrame {
            // 应用库打开时 dock 随 chrome 左移 progress×宽（Page2ChromeSlide），锚点要的是主屏静止态的位置：
            // 反算回去（原来靠 libraryProgress==0 时冻结 .global 帧，astra R2 G1）
            let sample = paging.chromeMotion.sample
            let rect = live.offsetBy(dx: sample.progress * sample.width, dy: 0)
            return CGPoint(x: rect.midX, y: rect.minY + dockIconSide / 2)
        }
        if let item = home.layout.item(id), let placement = (drag.preview ?? board).placements.first(where: { $0.id == id }) {
            let rect = frame(item, at: placement)
            if let point = drag.location.windowPoint(for: CGPoint(x: rect.midX, y: rect.minY + dockIconSide / 2)) { return point }
        }
        let bounds = PagingViewController.sharedScrollView?.window?.bounds ?? .zero
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private var pendingFolderItems: [Page2Item]? {
        guard let targetID = drag.mergeTarget, drag.sourceID != nil,
              let target = home.layout.item(targetID) else { return nil }
        return target.kind == "folder" ? target.children.compactMap { home.layout.item($0) } : [target]
    }
    private var folderPreviewFrame: CGRect? {
        guard let window = PagingViewController.sharedScrollView?.window else { return nil }
        let origin = CGPoint(x: drag.location.windowPoint.x - drag.point.x, y: drag.location.windowPoint.y - drag.point.y)
        return Page2FolderGeometry.panel(in: window.bounds.size).offsetBy(dx: -origin.x, dy: -origin.y)
    }

    private func editTapped(_ point: CGPoint) {
        guard let item = hit(point)?.0 else { return }
        if item.kind == "folder" { openFolder(item) } else { menuItem = item }
    }
    private func openFolder(_ item: Page2Item) {
        guard home.layout.item(item.id)?.kind == "folder" else { return }
        if folderItem?.id == item.id && !folderClosing { return }
        folderPresentationID = UUID()
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9)) { folderClosing = false; folderItem = item }
    }
    private func closeFolder() {
        if let id = folderItem?.id { folderGlancePages[id] = 0 }
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) { folderItem = nil; folderClosing = false; folderDragOutside = false; folderPresentationID = UUID() }
    }

    private func closeStack() {
        stackItem = nil; stackDragOutside = false; stackPresentationID = UUID()
    }
    private func layoutChanged(_ layout: Page2Layout) {
        resize.cancelIfChanged(layout)
        if drag.sourceID != nil && !drag.matches(layout) {
            let notify = drag.moved
            cancelDrag()
            if notify { home.errorMessage = "主屏已更新，这次拖动已取消。" }
        }
        if let id = folderItem?.id, layout.item(id)?.kind != "folder" { closeFolder() }
        if let id = stackItem?.id, layout.item(id)?.kind != "stack" { closeStack() }
    }
    private func resetTransientPresentation() {
        cancelDrag(); closeFolder(); closeStack()
        showsSearch = false; searchClosing = false; searchPull = 0
        paging.stackScrolling.removeAll()
    }

    private func decodeDrop(_ text: String) -> Page2IncomingItem? {
        let parts = text.split(separator: ":").map(String.init)
        if parts.count == 2, tools?.tool(byId: parts[1]) != nil {
            if parts[0] == "dock" { return .dock(parts[1]) }
            if parts[0] == "library" { return .library(parts[1]) }
        }
        if parts.count == 3, parts[0] == "folder", let container = UUID(uuidString: parts[1]), let child = UUID(uuidString: parts[2]) {
            return .folder(container: container, child: child)
        }
        return nil
    }

    private func receiveDrop(_ providers: [NSItemProvider], at point: CGPoint) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        let destinationPage = pageID
        let capacity = board.capacityKey
        let column = max(0, min(board.columns - 1, Int((point.x - gutter) / cellSize.width)))
        let row = max(0, min(board.rows - 1, Int(point.y / cellSize.height)))
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String else { return }
            Task { @MainActor in
                guard let incoming = decodeDrop(text) else { return }
                _ = home.receive(incoming, capacity: capacity, pageID: destinationPage, row: row, column: column, reserved: reserved)
                showsLibrary = false
                editing = true
            }
        }
        return true
    }

    private func receiveDockDrop(_ providers: [NSItemProvider], before target: String?) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String else { return }
            Task { @MainActor in
                guard let incoming = decodeDrop(text) else { return }
                let tool: String?
                switch incoming {
                case .dock(let id), .library(let id): tool = id
                case .folder(_, let child): tool = home.layout.item(child)?.toolID
                }
                guard let tool else { return }
                var ids = home.layout.dockIDs.filter { $0 != tool }
                ids.insert(tool, at: target.flatMap { ids.firstIndex(of: $0) } ?? ids.count)
                home.setDock(ids)
            }
        }
        return true
    }

    private func updateDrag(_ point: CGPoint) {
        guard !paging.isScrolling && !drag.folderPaging else { return }
        if dockDropRect.contains(point), !drag.folderPreview {
            let frames = home.layout.dockItems.compactMap { item -> (UUID, CGRect)? in dockFrame(item.id).map { (item.id, $0) } }
            drag.updateDock(at: point, frames: frames, ids: home.layout.dockItemIDs ?? [])
            return
        }
        let frames = (drag.preview ?? board).placements.filter { $0.pageID == pageID }.compactMap { p -> (UUID, CGRect)? in
            guard let item = home.layout.item(p.id) else { return nil }
            return (p.id, frame(item, at: p))
        }
        drag.update(at: point, board: board, pageID: pageID, cellSize: cellSize, gutter: gutter + gap / 2, reserved: reserved, frames: frames, folderFrame: folderPreviewFrame)
    }
    private func ensureTrailingPage() {
        guard drag.sourceID != nil else { return }
        paging.libraryEnabled = false
        var next = drag.preview ?? board
        if let last = next.pages.last(where: { !$0.isHidden }), next.placements.contains(where: { $0.pageID == last.id }) { _ = next.appendPage() }
        workingBoard = next
    }
    private func turnPage(_ direction: Int, adding: Bool = false) {
        if showsLibrary { if direction < 0 { showsLibrary = false }; return }
        let next = pageIndex + direction
        if visiblePages.indices.contains(next) { currentPageID = visiblePages[next].id }
        else if direction > 0 {
            if adding {
                var candidate = board
                currentPageID = candidate.appendPage()
                workingBoard = candidate
            } else { showsLibrary = true }
        }
    }
    private func cancelDrag() {
        resize.cancel()
        if let snapshot = drag.snapshot, let id = drag.sourceID,
           let source = snapshot.boards.first(where: { $0.capacityKey == board.capacityKey })?.placements.first(where: { $0.id == id }) {
            currentPageID = source.pageID
        }
        pendingRelease = nil
        folderDragOutside = false; stackDragOutside = false
        drag.cancel(); workingBoard = nil
        paging.libraryEnabled = true
    }
    private func updateStatusBar() {
        let value = appearance.displayed
        pageScene.isEditing = editing || stackItem != nil
        pageScene.prefersLightStatusBar = !value.wantsDarkForeground
        PagingViewController.refreshStatusBar()
    }
    private func setGridSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if size != gridSize {
            let previousCapacity = "\(columns)x\(rows)"
            let widthChanged = gridSize.width != size.width
            gridSize = size
            if widthChanged || "\(columns)x\(rows)" != previousCapacity { capacityChanged() }
        }
    }
    private func capacityChanged() { cancelDrag(); home.ensureBoard(columns: columns, rows: rows) }
    private func openTool(_ id: String) {
        cancelDrag()
        let shell = Page2AppShell.shared
        shell.captureSnapshot(of: "home")
        shell.launchFrames[id] = nil
        if let item = home.layout.rootItems.first(where: { $0.toolID == id && $0.kind == "app" }),
           home.layout.dockItemIDs?.contains(item.id) == true || board.placements.contains(where: { $0.id == item.id && $0.pageID == pageID }) {
            let center = folderOrigin(item.id)
            let side = metrics.iconSide
            shell.launchFrames[id] = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        }
        UserDefaults.standard.set(id, forKey: "page2RecentTool_v1")
        selectedToolId = id
    }
}
#endif
