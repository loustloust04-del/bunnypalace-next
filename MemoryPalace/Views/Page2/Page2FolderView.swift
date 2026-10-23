#if os(iOS)
import SwiftUI

struct Page2FolderView: View {
    let folderID: UUID
    let editing: Bool
    let origin: CGPoint
    var originSide: CGFloat = 68
    var initialPage = 0
    var previewItems: [Page2Item]? = nil
    var incomingIndex: Int? = nil
    var incomingID: UUID? = nil
    var incomingPage = 0
    var onPreviewPage: ((Int) -> Void)? = nil
    var onPreviewPaging: ((Bool) -> Void)? = nil
    var onOpen: (String) -> Void
    var onClose: () -> Void
    var onBeginClose: () -> Void = {}
    var onBeginEditing: () -> Void
    var onExternalDrag: (UIGestureRecognizer.State, Page2Item, CGPoint, CGRect) -> Bool
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    @State private var home = Page2HomeStore.shared
    @State private var name = ""
    private var page: Int {
        get { paging.selectedPage }
        nonmutating set { paging.selectedPage = newValue }
    }
    @State private var appeared = false
    @State private var motion = Page2FolderMotionState()
    @State private var paging = Page2PagingPresentation()
    @State private var location = Page2DragLocation()
    @State private var draggedID: UUID?
    @State private var orderPages: [[UUID]]?
    @State private var dragBaseline: Page2Layout?
    @State private var pendingDrop: CGPoint?
    @State private var pageAnchor: CGPoint?
    @State private var offset = CGSize.zero
    @State private var outside = false
    @State private var edgeSince = Date.distantPast
    @State private var edgeDirection = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var naming: Bool
    private var folder: Page2Item? { home.layout.item(folderID) }
    private var basePages: [[UUID]] {
        if let previewItems, folder?.kind != "folder" { return [previewItems.map(\.id)] }
        return folder?.childPages ?? []
    }
    private var arrangedPages: [[UUID]] { orderPages ?? basePages }
    private var shownPages: [[UUID]] {
        guard let incomingID else { return arrangedPages }
        return Page2FolderPages.inserting(incomingID, page: incomingPage, slot: incomingIndex ?? 0, into: arrangedPages)
    }
    private var children: [Page2Item] {
        shownPages.flatMap { $0 }.compactMap { home.layout.item($0) }.filter {
            guard let tool = tools?.tool(byId: $0.toolID ?? "") else { return false }
            return tool.isEnabled && tools?.isVisibleInCurrentMode(tool) == true
        }
    }
    private var isPreview: Bool { previewItems != nil }
    private var initialName: String { folder?.kind == "folder" ? (folder?.title ?? "文件夹") : "文件夹" }
    private var count: Int { max(1, shownPages.count) }
    private var displayPage: Int { paging.selectionInitialized ? page : (isPreview ? incomingPage : min(initialPage, count - 1)) }
    private var displayedPages: Int { max(count, max(1, basePages.count) + (editing ? 1 : 0)) }

    var body: some View {
        GeometryReader { geometry in
            let panel = Page2FolderGeometry.panel(in: geometry.size)
            let width = panel.width
            Page2GestureContainer(editing: editing, library: false, isPaging: { paging.isScrolling }, isDragging: { draggedID != nil }, paging: paging, enabled: scenePhase == .active && motion.closingFrom == nil, location: location,
                                  onTap: { _ in naming = false }, onSnapshot: { _ in },
                                  menuAt: { target(at: $0, panel: panel) }, menuFor: contextMenu,
                                  onPress: { state, point in
                                      gesture(state, at: point, start: point, panel: panel)
                                  }, onPan: { _, _, _, _ in }) {
                ZStack {
                    Color.black.opacity(appeared && !outside && !(motion.closingFrom != nil && motion.phase > 0) ? 0.08 : 0)
                        .contentShape(Rectangle()).onTapGesture { close() }
                    VStack(spacing: 22) {
                        title(width: width).modifier(Page2FolderTitleReveal(phase: reduceMotion ? 1 : motion.phase, closingFrom: motion.closingFrom))
                        Page2NativePager(selection: Binding(get: { displayPage }, set: selectPage), pageCount: displayedPages, editing: editing,
                                         presentation: paging) {
                            HStack(spacing: 0) {
                                ForEach(0..<displayedPages, id: \.self) { index in
                                    folderPage(index, panel: panel)
                                        .modifier(Page2FolderContentExpansion(phase: reduceMotion ? 1 : motion.phase, panel: panel, side: originSide, closingFrom: motion.closingFrom).ignoredByLayout())
                                        .animation(reduceMotion ? nil : .linear(duration: motion.duration), value: motion.phase)
                                        .accessibilityHidden(index != displayPage)
                                }
                            }.frame(width: width * CGFloat(displayedPages), height: panel.height)
                        }
                        .frame(width: width, height: panel.height)
                        .overlay(alignment: .bottom) {
                            if displayedPages > 1 {
                                HStack(spacing: 8) {
                                    ForEach(0..<displayedPages, id: \.self) { index in
                                        Circle().fill(.white.opacity(index == displayPage ? 1 : 0.35)).frame(width: 7, height: 7)
                                    }
                                }.padding(.bottom, 20).allowsHitTesting(false).modifier(Page2FolderTitleReveal(phase: reduceMotion ? 1 : motion.phase, closingFrom: motion.closingFrom))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 42))
                        .onTapGesture { naming = false; saveName() }
                        .background { Color.clear.glassEffect(.clear, in: .rect(cornerRadius: 42)).allowsHitTesting(false) }
                        .modifier(Page2FolderPanelExpansion(phase: reduceMotion ? 1 : motion.phase, panel: panel, origin: origin, side: originSide, closingFrom: motion.closingFrom).ignoredByLayout())
                    }
                    .contentShape(Rectangle()).onTapGesture { }
                    .allowsHitTesting(motion.closingFrom == nil)
                    .opacity(appeared && !outside ? 1 : 0)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2 - 42)
                    .animation(reduceMotion ? nil : .linear(duration: motion.duration), value: motion.phase)

                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .overlay(alignment: .topLeading) {
                if let draggedID, !outside, let child = home.layout.item(draggedID) {
                    Page2DragCarrierView(location: location, item: child, tool: tools?.tool(byId: child.toolID ?? ""),
                                         iconSide: iconSide(panel), size: CGSize(width: iconSide(panel), height: iconSide(panel) + 20),
                                         offset: offset, dockRect: .zero, image: nil)
                        .allowsHitTesting(false)
                }
            }
            .task(id: draggedID) {
                guard draggedID != nil else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    if !outside && !paging.isScrolling { move(at: location.localPoint, panel: panel) }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityAction(.escape) { close() }
        .onAppear(perform: beginAppearance)
        .onChange(of: paging.isScrolling) { _, active in
            if isPreview { onPreviewPaging?(active) }
            if active { edgeDirection = 0; pageAnchor = location.localPoint }
            else if let pendingDrop {
                self.pendingDrop = nil
                finish(at: pendingDrop, panel: Page2FolderGeometry.panel(in: location.coordinateView?.bounds.size ?? .zero))
            }
        }
        .onChange(of: incomingPage) { _, value in if isPreview { page = value } }
        .onChange(of: incomingID) { old, value in
            if value == nil, let old { page = folder?.childPages.firstIndex(where: { $0.contains(old) }) ?? min(page, count - 1) }
        }
        .onChange(of: home.layout) { _, value in
            if draggedID != nil, let dragBaseline, dragBaseline != value { cancel(); home.errorMessage = "主屏已更新，这次拖动已取消。" }
        }
        .onChange(of: scenePhase) { _, value in if value != .active { cancel() } }
        .onChange(of: folderID) { _, _ in
            if motion.closingFrom != nil { motion.generation = UUID(); motion.closingFrom = nil; motion.phase = 1 }
            name = initialName
        }
        .onChange(of: naming) { _, active in if !active { saveName() } }
        .onDisappear { motion.active = false; motion.generation = UUID(); cancel(); saveName() }
        .onChange(of: folder == nil) { _, removed in if removed { onClose() } }
    }

    private func beginAppearance() {
        motion.active = true; motion.generation = UUID(); motion.closingFrom = nil; motion.phase = 0
        appeared = true; outside = false
        paging.libraryEnabled = false
        name = initialName
        page = isPreview ? incomingPage : min(initialPage, count - 1)
        paging.selectionInitialized = true
        let generation = motion.generation
        DispatchQueue.main.async {
            guard motion.active, motion.generation == generation, motion.closingFrom == nil else { return }
            motion.openedAt = CACurrentMediaTime()
            withAnimation(reduceMotion ? nil : .linear(duration: Page2FolderExpansion.duration)) { motion.phase = 1 }
        }
    }

    @ViewBuilder private func title(width: CGFloat) -> some View {
        if editing {
            HStack(spacing: 8) {
                TextField("文件夹", text: $name)
                    .font(.system(size: 28, weight: .semibold))
                    .focused($naming).submitLabel(.done)
                    .onSubmit { saveName(); naming = false }
                Button { name = ""; naming = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("清除文件夹名称")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).frame(width: width + 16, height: 62)
            .background { Color.clear.glassEffect(.clear, in: .capsule).allowsHitTesting(false) }
            .disabled(isPreview).contentShape(Capsule())
            .onTapGesture { if !isPreview { naming = true } }
        } else {
            Text(name).font(.system(size: 28, weight: .semibold)).modifier(Page2DesktopLabel())
                .frame(width: width + 16, height: 62).contentShape(Capsule())
                .onLongPressGesture { if !isPreview { onBeginEditing(); naming = true } }
        }
    }

    private func folderPage(_ index: Int, panel: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            GlassEffectContainer(spacing: 0) {
                ForEach(children.filter { displayedIndex($0.id) / 9 == index }) { child in
                    if let tool = tools?.tool(byId: child.toolID ?? "") {
                        let frame = childFrame(displayedIndex(child.id), panel: panel).offsetBy(dx: -panel.minX, dy: -panel.minY)
                        Group {
                            if draggedID == child.id || incomingID == child.id { Color.clear.accessibilityHidden(true) }
                            else {
                                Page2AppIcon(tool: tool, side: iconSide(panel), followsIconSize: false, interactive: !editing, editing: editing) {
                                    close(); onOpen(tool.id)
                                }
                            }
                        }
                        .frame(width: frame.width, height: frame.height, alignment: .top)
                        .position(x: frame.midX, y: frame.midY)
                        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.85), value: frame)
                    }
                }
            }
            Group {
                ForEach(children.filter { displayedIndex($0.id) / 9 == index }.filter { $0.id != draggedID && $0.id != incomingID }) { child in
                    if let tool = tools?.tool(byId: child.toolID ?? "") {
                        let frame = childFrame(displayedIndex(child.id), panel: panel).offsetBy(dx: -panel.minX, dy: -panel.minY)
                        Color.clear.frame(width: frame.width, height: frame.height).allowsHitTesting(false)
                            .overlay(alignment: .topLeading) {
                                Page2RemoveBadge(label: "从文件夹移除\(tool.name)", editing: editing) { home.remove(child.id) }
                                    .offset(x: Page2RemoveBadge.originOffset, y: Page2RemoveBadge.originOffset)
                            }
                            .modifier(Page2EditingMotion(enabled: editing, seed: tool.order, pivotHeight: iconSide(panel)))
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
        }.frame(width: panel.width, height: panel.height, alignment: .topLeading)
    }

    private func contextMenu(_ id: UUID) -> UIMenu? {
        guard !isPreview, let item = home.layout.item(id) else { return nil }
        return UIMenu(children: [
            UIAction(title: "编辑主屏幕", image: UIImage(systemName: "square.grid.3x3")) { _ in onBeginEditing() },
            UIAction(title: "从文件夹移除", image: UIImage(systemName: "minus.circle"), attributes: .destructive) { _ in home.remove(item.id) }
        ])
    }
    private func displayedIndex(_ id: UUID) -> Int {
        for (page, ids) in shownPages.enumerated() {
            if let slot = ids.firstIndex(of: id) { return page * 9 + slot }
        }
        return 0
    }
    private func selectPage(_ index: Int) {
        let changed = page != index
        page = index
        if isPreview { if incomingPage != index { onPreviewPage?(index) }; return }
        guard changed, let draggedID else { return }
        let slot = arrangedPages.indices.contains(index) ? arrangedPages[index].filter { $0 != draggedID }.count : 0
        orderPages = Page2FolderPages.inserting(draggedID, page: index, slot: slot, into: arrangedPages)
        pageAnchor = location.localPoint
    }
    private func iconSide(_ panel: CGRect) -> CGFloat { Page2FolderGeometry.iconSide(in: panel) }
    private func childFrame(_ index: Int, panel: CGRect) -> CGRect { Page2FolderGeometry.childFrame(index, in: panel) }
    private func target(at point: CGPoint, panel: CGRect) -> Page2DragTarget? {
        guard !isPreview, !outside else { return nil }
        for child in children where displayedIndex(child.id) / 9 == page {
            let frame = childFrame(displayedIndex(child.id), panel: panel)
            if frame.contains(point) {
                return Page2DragTarget(id: child.id, frame: frame, snapshotRequired: false,
                                       previewFrame: CGRect(origin: frame.origin, size: CGSize(width: frame.width, height: frame.width)))
            }
        }
        return nil
    }
    private func gesture(_ state: UIGestureRecognizer.State, at point: CGPoint, start: CGPoint, panel: CGRect) {
        if state == .began, let target = target(at: start, panel: panel) {
            naming = false
            onBeginEditing()
            draggedID = target.id
            orderPages = basePages
            dragBaseline = home.layout
            pendingDrop = nil; pageAnchor = nil
            offset = CGSize(width: start.x - target.frame.minX, height: start.y - target.frame.minY)
            edgeDirection = 0
        } else if state == .began {
            let titleFrame = CGRect(x: panel.minX - 8, y: panel.minY - 84, width: panel.width + 16, height: 62)
            if titleFrame.contains(start) { onBeginEditing(); naming = true }
            else if panel.contains(start) { onBeginEditing() }
        }
        guard draggedID != nil else { return }
        if state == .began || state == .changed { move(at: point, panel: panel) }
        if state == .ended { finish(at: point, panel: panel) }
        else if state == .cancelled || state == .failed { cancel() }
    }
    private func finish(at point: CGPoint, panel: CGRect) {
        guard let draggedID, let child = home.layout.item(draggedID), !location.isLanding else { return }
        if outside {
            external(.ended, child: child, point: point, panel: panel)
            clearDrag()
            return
        }
        if paging.isScrolling { pendingDrop = point; return }
        let pages = arrangedPages
        let frame = childFrame(displayedIndex(draggedID), panel: panel)
        location.land(at: CGPoint(x: frame.minX + offset.width, y: frame.minY + offset.height)) {
            guard self.draggedID == draggedID else { return }
            if let baseline = dragBaseline, pages.filter({ !$0.isEmpty }) != folder?.childPages {
                _ = home.commitFolderPages(folderID, pages: pages, basedOn: baseline)
            }
            page = home.layout.item(folderID)?.childPages.firstIndex(where: { $0.contains(draggedID) }) ?? min(page, count - 1)
            clearDrag()
        }
    }
    private func clearDrag() {
        location.cancelLanding()
        draggedID = nil; orderPages = nil; dragBaseline = nil
        pendingDrop = nil; pageAnchor = nil; outside = false; edgeDirection = 0
    }
    private func cancel() {
        if outside, let draggedID, let child = home.layout.item(draggedID) {
            external(.cancelled, child: child, point: location.localPoint,
                     panel: Page2FolderGeometry.panel(in: location.coordinateView?.bounds.size ?? .zero))
        }
        clearDrag()
    }
    private func move(at point: CGPoint, panel: CGRect) {
        guard !paging.isScrolling, !location.isLanding, let draggedID, let child = home.layout.item(draggedID) else { return }
        if outside { if !external(.changed, child: child, point: point, panel: panel) { clearDrag() }; return }
        let center = CGPoint(x: point.x - offset.width + iconSide(panel) / 2, y: point.y - offset.height + iconSide(panel) / 2)
        if !panel.insetBy(dx: -12, dy: -12).contains(center) {
            outside = external(.began, child: child, point: point, panel: panel)
            if !outside { clearDrag() }
            return
        }
        let direction = center.x < panel.minX + 18 ? -1 : (center.x > panel.maxX - 18 ? 1 : 0)
        if direction != edgeDirection { edgeDirection = direction; edgeSince = Date() }
        if direction != 0, Date().timeIntervalSince(edgeSince) > 0.65 {
            selectPage(max(0, min(displayedPages - 1, page + direction))); edgeSince = Date()
        }
        if let pageAnchor {
            if hypot(point.x - pageAnchor.x, point.y - pageAnchor.y) < 8 { return }
            self.pageAnchor = nil
        }
        let rawSlot = Page2FolderGeometry.insertionSlot(at: center, in: panel)
        let count = arrangedPages.indices.contains(page) ? arrangedPages[page].filter { $0 != draggedID }.count : 0
        let next = Page2FolderPages.inserting(draggedID, page: page, slot: min(rawSlot, count), into: arrangedPages)
        if next != orderPages { orderPages = next }

    }
    @discardableResult
    private func external(_ state: UIGestureRecognizer.State, child: Page2Item, point: CGPoint, panel: CGRect) -> Bool {
        guard let window = location.windowPoint(for: point) else { return false }
        let frame = CGRect(x: window.x - offset.width, y: window.y - offset.height,
                           width: iconSide(panel), height: iconSide(panel) + 20)
        return onExternalDrag(state, child, window, frame)
    }
    private func saveName() {
        guard !isPreview else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if let folder, !trimmed.isEmpty, trimmed != folder.title { home.rename(folderID, title: trimmed) }
    }
    private func close() {
        guard !isPreview, draggedID == nil, motion.closingFrom == nil else { return }
        naming = false; saveName()
        if reduceMotion { page = 0; onClose(); return }
        let current = motion.openedAt.map { min(1, max(0, (CACurrentMediaTime() - $0) / Page2FolderExpansion.duration)) } ?? 0
        let generation = UUID()
        motion.generation = generation
        var reset = Transaction(animation: nil); reset.disablesAnimations = true
        withTransaction(reset) { motion.closingFrom = current; motion.phase = 0 }
        DispatchQueue.main.async {
            guard motion.active, motion.generation == generation else { return }
            withAnimation(.linear(duration: Page2FolderClosing.duration), completionCriteria: .logicallyComplete) {
                motion.phase = 1
                onBeginClose()
            } completion: {
                guard motion.active, motion.generation == generation else { return }
                page = 0
                onClose()
            }
        }
    }
}
#endif
