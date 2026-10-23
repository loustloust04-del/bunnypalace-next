#if os(iOS)
import SwiftUI

@MainActor
@Observable
final class Page2DragCoordinator {
    private(set) var sourceID: UUID?
    private(set) var snapshot: Page2Layout?
    private var baseline: Page2Layout?
    private var sourceContainer: UUID?
    private(set) var preview: Page2Board?
    private(set) var destination: Page2Placement?
    private(set) var dockPreview: [UUID]?
    private(set) var dockInsertion: Int?
    var previewImage: UIImage?
    let location = Page2DragLocation()
    var point: CGPoint {
        get { location.localPoint }
        set { location.localPoint = newValue }
    }
    private(set) var offset: CGSize = .zero
    private(set) var mergeTarget: UUID?
    private(set) var folderPreview = false
    private(set) var folderInsertionIndex: Int?
    private(set) var folderPage = 0
    var folderPaging = false
    private var folderOpeningPoint: CGPoint = .zero
    private var folderEntry: Page2FolderEntry?
    private(set) var moved = false
    var message: String?
    private var startPoint: CGPoint = .zero
    private var hoverTarget: UUID?
    private var hoverAnchor: CGPoint = .zero
    private var hoverSince = Date.distantPast
    private var edgeDirection = 0
    private var edgeSince = Date.distantPast
    private var lastCell: String?
    private var validDestination = true
    private var sourceSize: CGSize = .zero
    var folderHoverTarget: UUID? {
        guard let sourceID, snapshot?.item(sourceID)?.kind == "app" else { return nil }
        return hoverTarget
    }
    var canLand: Bool { moved && validDestination && mergeTarget == nil }

    func begin(_ id: UUID, at point: CGPoint, frame: CGRect, layout: Page2Layout, board: Page2Board, container: UUID? = nil, baseline: Page2Layout? = nil) {
        guard sourceID == nil else { return }
        sourceID = id
        sourceSize = frame.size
        snapshot = layout
        self.baseline = baseline ?? layout
        sourceContainer = container
        preview = board
        self.point = point
        startPoint = point
        offset = CGSize(width: point.x - frame.minX, height: point.y - frame.minY)
        destination = board.placements.first { $0.id == id }
        mergeTarget = nil
        moved = container != nil
        lastCell = nil
        validDestination = true
    }

    func update(at point: CGPoint, board: Page2Board, pageID: UUID, cellSize: CGSize,
                gutter: CGFloat, reserved: Set<UUID>, frames: [(UUID, CGRect)], folderFrame: CGRect? = nil) {
        guard !location.isLanding, let id = sourceID, let snapshot, let item = snapshot.item(id) else { return }
        self.point = point
        dockPreview = nil
        dockInsertion = nil
        moved = moved || hypot(point.x - startPoint.x, point.y - startPoint.y) > 8
        let current = destination?.pageID == pageID ? destination : nil
        let column = Page2GridEngine.dragIndex(position: Double(point.x - offset.width - gutter), step: Double(cellSize.width),
                                               current: current?.column, maximum: board.columns - item.span.columns)
        let row = Page2GridEngine.dragIndex(position: Double(point.y - offset.height), step: Double(cellSize.height),
                                            current: current?.row, maximum: board.rows - item.span.rows)
        let cell = "\(pageID)-\(row)-\(column)"
        let center = CGPoint(x: point.x - offset.width + sourceSize.width / 2, y: point.y - offset.height + sourceSize.height / 2)
        if folderPreview {
            if let panel = folderFrame, folderEntry?.contains(center, panel: panel) == true {
                validDestination = true
                if !folderPaging, panel.contains(center), hypot(center.x - folderOpeningPoint.x, center.y - folderOpeningPoint.y) >= 8 {
                    let slot = min(folderPageCount, Page2FolderGeometry.insertionSlot(at: center, in: panel))
                    if folderInsertionIndex != slot { folderInsertionIndex = slot }
                }
                return
            }
            folderPreview = false
            folderInsertionIndex = nil
            mergeTarget = nil
            hoverTarget = nil
        }
        let target = frames.first { otherID, rect in
            guard otherID != id, !reserved.contains(otherID), let other = snapshot.item(otherID) else { return false }
            let compatible = (item.kind == "app" && ["app", "folder"].contains(other.kind)) ||
                item.canStack(with: other)
            return sourceContainer == nil && compatible && rect.insetBy(dx: rect.width * 0.24, dy: rect.height * 0.24).contains(center)
        }?.0
        if target != hoverTarget || hypot(center.x - hoverAnchor.x, center.y - hoverAnchor.y) > 10 {
            hoverTarget = target
            hoverAnchor = center
            hoverSince = Date()
            mergeTarget = nil
        }
        if let target {
            if mergeTarget != target && Date().timeIntervalSince(hoverSince) >= 0.7 {
                mergeTarget = target
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
            if item.kind == "app", mergeTarget == target, Date().timeIntervalSince(hoverSince) >= 1.15 {
                folderOpeningPoint = center
                folderEntry = Page2FolderEntry(origin: center)
                folderPreview = true
                selectAppendPage()
            }
            validDestination = true
            return
        }
        var base = preview ?? snapshot.boards.first { $0.capacityKey == board.capacityKey } ?? board
        for page in board.pages where !base.pages.contains(where: { $0.id == page.id }) { base.pages.append(page) }
        base.nextPageNumber = max(base.nextPageNumber, board.nextPageNumber)
        let proposed = Page2Placement(id: id, pageID: pageID, row: row, column: column)
        if let current, let occupied = base.placements.first(where: { placement in
            guard placement.id != id, let other = snapshot.item(placement.id),
                  item.span == other.span, !reserved.contains(placement.id) else { return false }
            let mergeable = (item.kind == "app" && ["app", "folder"].contains(other.kind)) ||
                item.canStack(with: other)
            return mergeable && Page2GridEngine.overlaps(proposed, item.span, placement, other.span)
        }), let rect = frames.first(where: { $0.0 == occupied.id })?.1 {
            let center = CGPoint(x: point.x - offset.width + sourceSize.width / 2, y: point.y - offset.height + sourceSize.height / 2)
            let horizontal = abs(column - current.column) >= abs(row - current.row)
            let passed: Bool
            if horizontal && column != current.column {
                passed = column > current.column ? center.x > rect.midX + 8 : center.x < rect.midX - 8
            } else {
                passed = row > current.row ? center.y > rect.midY + 8 : center.y < rect.midY - 8
            }
            if !passed { return }
        }
        if destination == proposed { validDestination = true; message = nil; return }
        guard lastCell != cell else { return }
        lastCell = cell
        do {
            preview = try Page2GridEngine.placeWhileDragging(item, on: pageID, row: row, column: column,
                                               in: base, items: snapshot.rootItems + snapshot.dockItems.filter { $0.id == id }, reserved: reserved)
            destination = Page2Placement(id: id, pageID: pageID, row: row, column: column)
            message = nil
            validDestination = true
            UISelectionFeedbackGenerator().selectionChanged()
        } catch {
            validDestination = false
            message = error.localizedDescription
        }
    }

    func updateDock(at point: CGPoint, frames: [(UUID, CGRect)], ids: [UUID]) {
        guard !location.isLanding else { return }
        guard let sourceID, let snapshot, let item = snapshot.item(sourceID),
              ["app", "folder"].contains(item.kind) else { leaveGrid(); return }
        self.point = point
        moved = moved || hypot(point.x - startPoint.x, point.y - startPoint.y) > 8
        let center = CGPoint(x: point.x - offset.width + sourceSize.width / 2, y: point.y - offset.height + sourceSize.height / 2)
        let target = frames.first { id, rect in
            id != sourceID && item.kind == "app" && sourceContainer == nil &&
                ["app", "folder"].contains(snapshot.item(id)?.kind ?? "") && rect.insetBy(dx: rect.width * 0.24, dy: rect.height * 0.24).contains(center)
        }?.0
        if target != hoverTarget || hypot(center.x - hoverAnchor.x, center.y - hoverAnchor.y) > 10 {
            hoverTarget = target; hoverAnchor = center; hoverSince = Date(); mergeTarget = nil
        }
        if let target {
            if mergeTarget != target && Date().timeIntervalSince(hoverSince) >= 0.7 { mergeTarget = target }
            if mergeTarget == target && Date().timeIntervalSince(hoverSince) >= 1.15 {
                folderOpeningPoint = center
                folderEntry = Page2FolderEntry(origin: center)
                folderPreview = true
                selectAppendPage()
            }
            validDestination = true
            return
        }
        folderPreview = false
        if dockPreview == nil, let originIndex = snapshot.dockItemIDs?.firstIndex(of: sourceID),
           abs(point.x - startPoint.x) < sourceSize.width / 2 {
            dockInsertion = originIndex
            validDestination = true
            return
        }
        var order = ids.filter { $0 != sourceID }
        guard order.count < 4 else { dockPreview = nil; dockInsertion = nil; validDestination = false; return }
        let index = order.firstIndex { id in frames.first { $0.0 == id }.map { point.x < $0.1.midX } ?? false } ?? order.count
        order.insert(sourceID, at: index)
        dockPreview = order
        dockInsertion = index
        validDestination = true
    }

    @discardableResult
    func finishDock(store: Page2HomeStore) -> Bool {
        defer { cancel() }
        guard moved, validDestination, let sourceID, let dockInsertion,
              (baseline ?? snapshot) == store.layout else { return false }
        return store.moveToDock(sourceID, at: dockInsertion)
    }

    private var folderPages: [[UUID]] {
        guard let mergeTarget, let item = snapshot?.item(mergeTarget) else { return [] }
        return item.kind == "folder" ? item.childPages : [[item.id]]
    }
    private var folderPageCount: Int { folderPages.indices.contains(folderPage) ? folderPages[folderPage].count : 0 }
    private func selectAppendPage() {
        let position = Page2FolderPages.appendPosition(in: folderPages)
        folderPage = position.page
        folderInsertionIndex = position.slot
    }
    func selectFolderPage(_ page: Int, slot: Int? = nil) {
        folderPage = page
        folderInsertionIndex = slot ?? folderPageCount
        folderOpeningPoint = CGPoint(x: point.x - offset.width + sourceSize.width / 2, y: point.y - offset.height + sourceSize.height / 2)
    }
    func resolvedFolderPosition() -> (page: Int, slot: Int)? {
        guard let sourceID else { return nil }
        let pages = Page2FolderPages.inserting(sourceID, page: folderPage, slot: folderInsertionIndex ?? folderPageCount, into: folderPages)
        for (page, ids) in pages.enumerated() {
            if let slot = ids.firstIndex(of: sourceID) { return (page, slot) }
        }
        return nil
    }
    func suspendPaging() {
        mergeTarget = nil; hoverTarget = nil; folderPreview = false
        edgeDirection = 0; lastCell = nil
    }
    func selectPage(_ page: UUID, in board: Page2Board) {
        guard sourceID != nil, destination?.pageID != page else { return }
        var next = preview ?? board
        for candidate in board.pages where !next.pages.contains(where: { $0.id == candidate.id }) { next.pages.append(candidate) }
        next.nextPageNumber = max(next.nextPageNumber, board.nextPageNumber)
        preview = next
        destination = nil
        moved = true
        validDestination = false
        lastCell = nil
    }

    func openFolder(_ id: UUID, frame: CGRect?) {
        guard sourceContainer == nil, let sourceID, snapshot?.item(sourceID)?.kind == "app", snapshot?.item(id)?.kind == "folder", id != sourceID else { return }
        guard !folderPreview || mergeTarget != id else { return }
        mergeTarget = id; hoverTarget = id; folderPreview = true; moved = true
        folderOpeningPoint = CGPoint(x: point.x - offset.width + sourceSize.width / 2, y: point.y - offset.height + sourceSize.height / 2)
        folderEntry = Page2FolderEntry(origin: folderOpeningPoint)
        if let frame, frame.contains(folderOpeningPoint) {
            folderPage = 0
            folderInsertionIndex = min(folderPageCount, Page2FolderGeometry.insertionSlot(at: folderOpeningPoint, in: frame))
        } else { selectAppendPage() }
        validDestination = true
    }

    func leaveGrid() {
        mergeTarget = nil
        folderPreview = false
        folderEntry = nil
        hoverTarget = nil
        validDestination = false
    }

    func edge(at point: CGPoint, width: CGFloat) -> Int {
        guard !location.isLanding else { return 0 }
        let direction = point.x < 24 ? -1 : (point.x > width - 24 ? 1 : 0)
        if direction != edgeDirection { edgeDirection = direction; edgeSince = Date() }
        guard direction != 0, Date().timeIntervalSince(edgeSince) >= 0.65 else { return 0 }
        edgeSince = Date()
        return direction
    }

    func prepareStackDrop() -> UUID? {
        guard moved, validDestination, sourceContainer == nil, let sourceID, let item = snapshot?.item(sourceID),
              let target = hoverTarget, let other = snapshot?.item(target), item.canStack(with: other) else { return nil }
        mergeTarget = target
        return target
    }

    func prepareFolderDrop() -> UUID? {
        guard moved, validDestination, sourceContainer == nil, let sourceID,
              snapshot?.item(sourceID)?.kind == "app",
              let target = folderPreview ? mergeTarget : hoverTarget else { return nil }
        mergeTarget = target
        return target
    }

    @discardableResult
    func finish(store: Page2HomeStore, valid: Bool) -> Bool {
        defer { cancel() }
        guard moved, valid, validDestination, let snapshot else { return false }
        if let sourceContainer, let sourceID, let baseline, let preview {
            return store.commitExtraction(sourceID, from: sourceContainer, board: preview, basedOn: baseline)
        } else if let mergeTarget, let sourceID, snapshot == store.layout {
            let dockMerge = snapshot.dockItemIDs?.contains(sourceID) == true && snapshot.dockItemIDs?.contains(mergeTarget) == true
            return store.combine(sourceID, with: mergeTarget, preview: dockMerge ? nil : preview, insertionIndex: folderInsertionIndex, folderPage: folderPreview ? folderPage : nil)
        } else if let preview, let sourceID, snapshot.dockItemIDs?.contains(sourceID) == true {
            return store.commitDockExtraction(sourceID, board: preview, basedOn: snapshot)
        } else if let preview { return store.commit(preview, basedOn: snapshot) }
        return false
    }

    func matches(_ layout: Page2Layout) -> Bool { (baseline ?? snapshot) == layout }

    func cancel() {
        location.cancelLanding()
        sourceID = nil
        previewImage = nil
        snapshot = nil
        baseline = nil
        sourceContainer = nil
        preview = nil
        destination = nil
        dockPreview = nil; dockInsertion = nil
        mergeTarget = nil
        folderPreview = false
        folderEntry = nil
        folderInsertionIndex = nil; folderPage = 0; folderPaging = false
        hoverTarget = nil
        edgeDirection = 0
        lastCell = nil
        message = nil
        moved = false
        validDestination = true
    }
}
#endif
