import Foundation

enum Page2GridError: Error, LocalizedError, Equatable {
    case invalidLayout, invalidPosition, reservedPosition, missingItem

    var errorDescription: String? {
        switch self {
        case .invalidLayout: return "布局无法保存，已保留原来的主屏。"
        case .invalidPosition: return "这个位置放不下，试试其他空位。"
        case .reservedPosition: return "这个位置为隐藏的工具保留。"
        case .missingItem: return "这个项目已经不在主屏上。"
        }
    }
}

enum Page2GridEngine {
    static func validate(_ layout: Page2Layout) -> Bool {
        guard layout.version == 1, Set(layout.items.map(\.id)).count == layout.items.count,
              !layout.boards.isEmpty,
              Set(layout.boards.map(\.capacityKey)).count == layout.boards.count else { return false }
        let ids = Set(layout.items.map(\.id))
        let childIDs = layout.items.flatMap(\.children)
        let dock = layout.dockItemIDs ?? []
        guard Set(dock).count == dock.count, Set(dock).isSubset(of: ids), Set(dock).isDisjoint(with: childIDs),
              dock.allSatisfy({ ["app", "folder"].contains(layout.item($0)?.kind ?? "") }) else { return false }
        guard Set(childIDs).count == childIDs.count, Set(childIDs).isSubset(of: ids) else { return false }
        for item in layout.items {
            guard !item.children.contains(item.id) else { return false }
            if let pages = item.folderPages {
                guard item.kind == "folder", !pages.isEmpty,
                      pages.allSatisfy({ !$0.isEmpty && $0.count <= 9 }), pages.flatMap({ $0 }) == item.children else { return false }
            }
            if item.kind == "folder" {
                guard item.span == .icon, !item.children.isEmpty,
                      item.children.allSatisfy({ layout.item($0)?.kind == "app" }) else { return false }
            } else if item.kind == "stack" {
                guard item.children.count >= 2,
                      item.children.allSatisfy({ layout.item($0)?.kind == "widget" && layout.item($0)?.span == item.span }) else { return false }
            } else if !item.children.isEmpty { return false }
            if item.kind == "app" && (item.toolID == nil || item.span != .icon) { return false }
            if item.kind == "widget" && (item.widgetKind == nil || !Page2Span.widgetSizes.contains(item.span)) { return false }
        }
        return layout.boards.allSatisfy { validate($0, items: layout.rootItems) }
    }

    static func validate(_ board: Page2Board, items: [Page2Item]) -> Bool {
        guard board.columns >= 4, board.columns <= 6, board.rows >= 4, board.rows <= 8,
              !board.pages.isEmpty, board.pages.contains(where: { !$0.isHidden }),
              Set(board.pages.map(\.id)).count == board.pages.count,
              Set(board.placements.map(\.id)) == Set(items.map(\.id)),
              board.placements.count == items.count else { return false }
        var occupied = Set<String>()
        for placement in board.placements {
            guard let item = items.first(where: { $0.id == placement.id }),
                  board.pages.contains(where: { $0.id == placement.pageID }),
                  fits(item.span, row: placement.row, column: placement.column, board: board) else { return false }
            for row in placement.row..<(placement.row + item.span.rows) {
                for column in placement.column..<(placement.column + item.span.columns) {
                    guard occupied.insert("\(placement.pageID)-\(row)-\(column)").inserted else { return false }
                }
            }
        }
        return true
    }

    static func resizing(_ id: UUID, to span: Page2Span, in layout: Page2Layout,
                         widgetKind: String? = nil) throws -> Page2Layout {
        guard let index = layout.items.firstIndex(where: { $0.id == id }), layout.items[index].kind != "folder" else { throw Page2GridError.missingItem }
        guard span == .icon || Page2Span.widgetSizes.contains(span) else { throw Page2GridError.invalidPosition }
        var candidate = layout
        if candidate.items[index].kind == "stack" {
            guard Page2Span.widgetSizes.contains(span) else { throw Page2GridError.invalidPosition }
            let children = Set(candidate.items[index].children)
            for i in candidate.items.indices where children.contains(candidate.items[i].id) { candidate.items[i].span = span }
        } else if span == .icon {
            guard candidate.items[index].toolID != nil else { throw Page2GridError.invalidPosition }
            candidate.items[index].kind = "app"
        } else {
            candidate.items[index].kind = "widget"
            candidate.items[index].widgetKind = widgetKind ?? candidate.items[index].widgetKind ?? candidate.items[index].toolID
        }
        candidate.items[index].span = span
        for i in candidate.boards.indices {
            guard let old = candidate.boards[i].placements.first(where: { $0.id == id }) else { continue }
            let row = min(old.row, candidate.boards[i].rows - span.rows)
            let column = min(old.column, candidate.boards[i].columns - span.columns)
            candidate.boards[i] = try place(candidate.items[index], on: old.pageID, row: row, column: column,
                                            in: candidate.boards[i], items: candidate.rootItems)
        }
        guard validate(candidate) else { throw Page2GridError.invalidLayout }
        return candidate
    }

    static func place(_ item: Page2Item, on pageID: UUID, row: Int, column: Int,
                      in original: Page2Board, items: [Page2Item], reserved: Set<UUID> = []) throws -> Page2Board {
        guard original.pages.contains(where: { $0.id == pageID }),
              fits(item.span, row: row, column: column, board: original) else { throw Page2GridError.invalidPosition }
        var board = original
        board.placements.removeAll { $0.id == item.id }
        let destination = Page2Placement(id: item.id, pageID: pageID, row: row, column: column)
        let conflicts = board.placements.filter { p in
            guard let other = items.first(where: { $0.id == p.id }) else { return false }
            return overlaps(destination, item.span, p, other.span)
        }.sorted { lhs, rhs in lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row }
        guard conflicts.allSatisfy({ !reserved.contains($0.id) }) else { throw Page2GridError.reservedPosition }
        let conflictIDs = Set(conflicts.map(\.id))
        board.placements.removeAll { conflictIDs.contains($0.id) }
        board.placements.append(destination)
        for old in conflicts {
            guard let displaced = items.first(where: { $0.id == old.id }) else { throw Page2GridError.missingItem }
            let slot = firstVacancy(for: displaced, in: &board, items: items, startingAt: pageID,
                                    preferredRow: old.row, preferredColumn: old.column)
            board.placements.append(slot)
        }
        guard validate(board, items: items) else { throw Page2GridError.invalidLayout }
        return board
    }

    static func placeWhileDragging(_ item: Page2Item, on pageID: UUID, row: Int, column: Int,
                                   in original: Page2Board, items: [Page2Item], reserved: Set<UUID> = []) throws -> Page2Board {
        let proposed = Page2Placement(id: item.id, pageID: pageID, row: row, column: column)
        if original.placements.contains(where: { placement in
               guard placement.id != item.id, let other = items.first(where: { $0.id == placement.id }), other.span != .icon else { return false }
               return overlaps(proposed, item.span, placement, other.span)
           }) {
            return try crossWidgets(item, destination: proposed, in: original, items: items, reserved: reserved)
        }
        guard item.span == .icon, ["app", "folder"].contains(item.kind),
              let source = original.placements.first(where: { $0.id == item.id && $0.pageID == pageID }),
              fits(item.span, row: row, column: column, board: original) else {
            return try place(item, on: pageID, row: row, column: column, in: original, items: items, reserved: reserved)
        }
        let destination = row * original.columns + column
        let start = source.row * original.columns + source.column
        if start == destination { return original }
        let preferred = start < destination ? -1 : 1
        for direction in [preferred, -preferred] {
            var board = original
            board.placements.removeAll { $0.id == item.id }
            var chain: [Page2Placement] = []
            var cursor = destination
            while (0..<(board.rows * board.columns)).contains(cursor) {
                let probe = Page2Placement(id: item.id, pageID: pageID, row: cursor / board.columns, column: cursor % board.columns)
                let occupied = board.placements.first { placement in
                    guard let other = items.first(where: { $0.id == placement.id }) else { return false }
                    return overlaps(probe, .icon, placement, other.span)
                }
                guard let occupied else {
                    for old in chain.reversed() {
                        guard let index = board.placements.firstIndex(where: { $0.id == old.id }) else { throw Page2GridError.invalidLayout }
                        let next = old.row * board.columns + old.column + direction
                        board.placements[index].row = next / board.columns
                        board.placements[index].column = next % board.columns
                    }
                    board.placements.append(Page2Placement(id: item.id, pageID: pageID, row: row, column: column))
                    guard validate(board, items: items) else { throw Page2GridError.invalidLayout }
                    return board
                }
                guard !reserved.contains(occupied.id), let other = items.first(where: { $0.id == occupied.id }),
                      other.span == .icon, ["app", "folder"].contains(other.kind) else { break }
                chain.append(occupied)
                cursor += direction
            }
        }
        return try place(item, on: pageID, row: row, column: column, in: original, items: items, reserved: reserved)
    }

    private static func crossWidgets(_ item: Page2Item, destination: Page2Placement,
                                     in original: Page2Board, items: [Page2Item], reserved: Set<UUID>) throws -> Page2Board {
        guard fits(item.span, row: destination.row, column: destination.column, board: original) else { throw Page2GridError.invalidPosition }
        let source = original.placements.first { $0.id == item.id && $0.pageID == destination.pageID } ?? destination
        let pageItems = original.placements.filter { $0.pageID == destination.pageID && $0.id != item.id }
        func mask(_ placement: Page2Placement, _ span: Page2Span) -> UInt64 {
            var value: UInt64 = 0
            for row in placement.row..<(placement.row + span.rows) {
                for column in placement.column..<(placement.column + span.columns) { value |= UInt64(1) << (row * original.columns + column) }
            }
            return value
        }
        var occupied = mask(destination, item.span)
        for placement in pageItems where reserved.contains(placement.id) {
            guard let other = items.first(where: { $0.id == placement.id }) else { throw Page2GridError.missingItem }
            let fixed = mask(placement, other.span)
            guard occupied & fixed == 0 else { throw Page2GridError.reservedPosition }
            occupied |= fixed
        }
        let widgets = pageItems.compactMap { placement -> (Page2Placement, Page2Item)? in
            guard !reserved.contains(placement.id), let other = items.first(where: { $0.id == placement.id }), other.span != .icon else { return nil }
            return (placement, other)
        }.sorted { a, b in
            let aArea = a.1.span.rows * a.1.span.columns, bArea = b.1.span.rows * b.1.span.columns
            return aArea == bArea ? (a.0.row == b.0.row ? a.0.column < b.0.column : a.0.row < b.0.row) : aArea > bArea
        }
        let candidates = widgets.map { old, widget -> [(Page2Placement, UInt64)] in
            let displaced = overlaps(destination, item.span, old, widget.span)
            let targetRow = displaced ? 2 * source.row + item.span.rows : 2 * old.row + widget.span.rows
            let targetColumn = displaced ? 2 * source.column + item.span.columns : 2 * old.column + widget.span.columns
            var slots: [(Page2Placement, UInt64)] = []
            for row in 0...(original.rows - widget.span.rows) {
                for column in 0...(original.columns - widget.span.columns) {
                    let slot = Page2Placement(id: widget.id, pageID: destination.pageID, row: row, column: column)
                    let cells = mask(slot, widget.span)
                    if cells & occupied == 0 { slots.append((slot, cells)) }
                }
            }
            func distance(_ slot: Page2Placement) -> Int { abs(2 * slot.row + widget.span.rows - targetRow) + abs(2 * slot.column + widget.span.columns - targetColumn) }
            return slots.sorted { a, b in
                let da = distance(a.0), db = distance(b.0)
                return da == db ? (a.0.row == b.0.row ? a.0.column < b.0.column : a.0.row < b.0.row) : da < db
            }
        }
        var selected: [Page2Placement] = []
        var failed = Set<UInt64>()
        func arrange(_ index: Int, _ taken: UInt64) -> Bool {
            if index == widgets.count { return true }
            let key = taken | (UInt64(index) << 56)
            guard !failed.contains(key) else { return false }
            for (slot, cells) in candidates[index] where cells & taken == 0 {
                selected.append(slot)
                if arrange(index + 1, taken | cells) { return true }
                selected.removeLast()
            }
            failed.insert(key)
            return false
        }
        guard arrange(0, occupied) else { throw Page2GridError.invalidPosition }
        var board = original
        let movedIDs = Set(selected.map(\.id) + [item.id])
        board.placements.removeAll { movedIDs.contains($0.id) }
        let placed = selected + [destination]
        let displaced = board.placements.filter { placement in
            guard let other = items.first(where: { $0.id == placement.id }) else { return false }
            return placed.contains { target in
                guard let targetItem = items.first(where: { $0.id == target.id }) else { return false }
                return overlaps(target, targetItem.span, placement, other.span)
            }
        }.sorted { a, b in a.row == b.row ? a.column < b.column : a.row < b.row }
        let displacedIDs = Set(displaced.map(\.id))
        board.placements.removeAll { displacedIDs.contains($0.id) }
        board.placements.append(contentsOf: placed)
        for old in displaced {
            guard let other = items.first(where: { $0.id == old.id }) else { throw Page2GridError.missingItem }
            board.placements.append(firstVacancy(for: other, in: &board, items: items, startingAt: destination.pageID,
                                                 preferredRow: old.row, preferredColumn: old.column))
        }
        guard validate(board, items: items) else { throw Page2GridError.invalidLayout }
        return board
    }

    static func dragIndex(position: Double, step: Double, current: Int?, maximum: Int) -> Int {
        guard step > 0, position.isFinite, maximum >= 0 else { return 0 }
        let next = Int(max(0, min(Double(maximum), (position / step).rounded())))
        if let current, (0...maximum).contains(current) {
            let margin = min(8, step * 0.1)
            if position >= (Double(current) - 0.5) * step - margin,
               position <= (Double(current) + 0.5) * step + margin { return current }
        }
        return next
    }

    static func firstVacancy(for item: Page2Item, in board: inout Page2Board, items: [Page2Item],
                             startingAt pageID: UUID? = nil, preferredRow: Int? = nil,
                             preferredColumn: Int? = nil) -> Page2Placement {
        let start = pageID.flatMap { id in board.pages.firstIndex(where: { $0.id == id }) } ?? 0
        for page in board.pages.dropFirst(start) where !page.isHidden {
            var cells: [(row: Int, column: Int)] = []
            if item.span.rows > board.rows || item.span.columns > board.columns { break }
            for row in 0...(board.rows - item.span.rows) {
                for column in 0...(board.columns - item.span.columns) { cells.append((row, column)) }
            }
            if let preferredRow, let preferredColumn {
            cells.sort { a, b in
                let da = abs(a.row - preferredRow) + abs(a.column - preferredColumn)
                let db = abs(b.row - preferredRow) + abs(b.column - preferredColumn)
                return da == db ? (a.row == b.row ? a.column < b.column : a.row < b.row) : da < db
            }
            }
            for cell in cells {
                let candidate = Page2Placement(id: item.id, pageID: page.id, row: cell.row, column: cell.column)
                if board.placements.allSatisfy({ p in
                    guard let other = items.first(where: { $0.id == p.id }) else { return false }
                    return !overlaps(candidate, item.span, p, other.span)
                }) { return candidate }
            }
        }
        return Page2Placement(id: item.id, pageID: board.appendPage(), row: 0, column: 0)
    }

    static func project(_ original: Page2Board, columns: Int, rows: Int, items: [Page2Item]) -> Page2Board {
        var board = Page2Board(columns: columns, rows: rows)
        board.pages = original.pages
        board.id = original.id
        board.nextPageNumber = original.nextPageNumber
        for old in original.placements {
            guard let item = items.first(where: { $0.id == old.id }) else { continue }
            let existing = board.placements.allSatisfy { p in
                guard let other = items.first(where: { $0.id == p.id }) else { return false }
                return !overlaps(old, item.span, p, other.span)
            }
            if fits(item.span, row: old.row, column: old.column, board: board) && existing {
                board.placements.append(old)
            } else {
                let slot = firstVacancy(for: item, in: &board, items: items,
                                       startingAt: old.pageID, preferredRow: old.row, preferredColumn: old.column)
                board.placements.append(slot)
            }
        }
        return board
    }

    static func overlaps(_ a: Page2Placement, _ sa: Page2Span, _ b: Page2Placement, _ sb: Page2Span) -> Bool {
        a.pageID == b.pageID && a.row < b.row + sb.rows && b.row < a.row + sa.rows &&
            a.column < b.column + sb.columns && b.column < a.column + sa.columns
    }

    static func fits(_ span: Page2Span, row: Int, column: Int, board: Page2Board) -> Bool {
        row >= 0 && column >= 0 && span.rows > 0 && span.columns > 0 &&
            row + span.rows <= board.rows && column + span.columns <= board.columns
    }
}
