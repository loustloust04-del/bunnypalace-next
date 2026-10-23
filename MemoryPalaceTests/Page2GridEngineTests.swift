import XCTest
#if PAGE2_CORE_FIXTURE
@testable import Page2Core
#else
@testable import 记忆花园
#endif

final class Page2GridEngineTests: XCTestCase {
    private func filled(_ count: Int = 24) -> (Page2Board, [Page2Item]) {
        var board = Page2Board()
        let items = (0..<count).map { Page2Item.app("tool-\($0)") }
        for item in items {
            let slot = Page2GridEngine.firstVacancy(for: item, in: &board, items: items)
            board.placements.append(slot)
        }
        return (board, items)
    }

    func testResizePreviewPreservesItemsAcrossBoardCapacities() throws {
        let widget = Page2Item.widget("todo")
        let items = [widget] + (0..<20).map { Page2Item.app("tool-\($0)") }
        var layout = Page2Layout()
        layout.items = items
        layout.boards = [(4, 6), (6, 4)].map { columns, rows in
            var board = Page2Board(columns: columns, rows: rows)
            for item in items { board.placements.append(Page2GridEngine.firstVacancy(for: item, in: &board, items: items)) }
            return board
        }
        let original = layout
        let grown = try Page2GridEngine.resizing(widget.id, to: .large, in: layout)
        XCTAssertEqual(layout, original)
        XCTAssertEqual(grown.items.map(\.id), original.items.map(\.id))
        XCTAssertEqual(grown.item(widget.id)?.span, .large)
        XCTAssertTrue(Page2GridEngine.validate(grown))
        XCTAssertEqual(grown.boards.map(\.capacityKey), ["4x6", "6x4"])
    }

    func testResizeReflowsHiddenToolsWithoutLosingTheirData() throws {
        let widget = Page2Item.widget("todo")
        var hidden = Page2Item.app("hidden")
        hidden.configuration = ["preserved": "yes"]
        let untouched = Page2Item.app("elsewhere")
        var layout = Page2Layout()
        layout.items = [widget, hidden, untouched]
        let page = layout.boards[0].pages[0].id
        layout.boards[0].placements = [.init(id: widget.id, pageID: page, row: 0, column: 0),
                                       .init(id: hidden.id, pageID: page, row: 0, column: 2),
                                       .init(id: untouched.id, pageID: page, row: 5, column: 3)]
        layout.boards.append(Page2GridEngine.project(layout.boards[0], columns: 6, rows: 4, items: layout.items))
        let original = layout
        for span in [Page2Span.medium, .large] {
            let grown = try Page2GridEngine.resizing(widget.id, to: span, in: layout)
            XCTAssertEqual(grown.item(widget.id)?.span, span)
            XCTAssertEqual(grown.item(hidden.id), hidden)
            XCTAssertEqual(Set(grown.items.map(\.id)), Set(layout.items.map(\.id)))
            XCTAssertEqual(grown.boards[0].placements.first { $0.id == untouched.id }, layout.boards[0].placements.last)
            XCTAssertTrue(Page2GridEngine.validate(grown))
        }
        XCTAssertEqual(layout, original)
    }

    func testResizeStackUpdatesEveryMemberTogether() throws {
        let a = Page2Item.widget("vocab"), b = Page2Item.widget("todo")
        let stack = Page2Item(kind: "stack", span: .small, children: [a.id, b.id])
        var layout = Page2Layout()
        layout.items = [stack, a, b]
        layout.boards[0].placements = [.init(id: stack.id, pageID: layout.boards[0].pages[0].id, row: 0, column: 0)]
        let result = try Page2GridEngine.resizing(stack.id, to: .large, in: layout)
        XCTAssertEqual(result.items.map(\.span), [.large, .large, .large])
        XCTAssertTrue(Page2GridEngine.validate(result))
        XCTAssertThrowsError(try Page2GridEngine.resizing(stack.id, to: .icon, in: layout))
    }

    func testStackHoverEligibilityMatchesSizesAndTenMemberLimit() {
        for a in Page2Span.widgetSizes {
            for b in Page2Span.widgetSizes {
                XCTAssertEqual(Page2Item.widget("todo", span: a).canStack(with: .widget("calendar", span: b)), a == b)
            }
            let full = Page2Item(kind: "stack", span: a, children: (0..<10).map { _ in UUID() })
            XCTAssertFalse(Page2Item.widget("todo", span: a).canStack(with: full))
            let nine = Page2Item(kind: "stack", span: a, children: Array(full.children.prefix(9)))
            XCTAssertTrue(Page2Item.widget("todo", span: a).canStack(with: nine))
        }
        XCTAssertFalse(Page2Item.app("calendar").canStack(with: .widget("todo")))
    }

    func testEveryWidgetSizeCrossingKeepsWidgetsOnPage() throws {
        for rows in [6, 8] {
            for sourceSpan in Page2Span.widgetSizes {
                for targetSpan in Page2Span.widgetSizes where sourceSpan.rows + targetSpan.rows <= rows {
                    for sourceIsStack in [false, true] {
                        var board = Page2Board(columns: 4, rows: rows)
                        let page = board.pages[0].id
                        let source = Page2Item(kind: sourceIsStack ? "stack" : "widget", widgetKind: "todo", span: sourceSpan)
                        let target = Page2Item.widget("calendar", span: targetSpan)
                        var items = [source, target]
                        board.placements = [.init(id: source.id, pageID: page, row: 0, column: 0),
                                            .init(id: target.id, pageID: page, row: sourceSpan.rows, column: 0)]
                        let free = 4 * rows - sourceSpan.rows * sourceSpan.columns - targetSpan.rows * targetSpan.columns
                        for n in 0..<free {
                            let icon = Page2Item.app("filler-\(n)"); items.append(icon)
                            board.placements.append(Page2GridEngine.firstVacancy(for: icon, in: &board, items: items))
                        }
                        XCTAssertEqual(board.pages.count, 1)
                        let baseline = board
                        for row in 0...(rows - sourceSpan.rows) {
                            for column in 0...(4 - sourceSpan.columns) {
                                do {
                                    let moved = try Page2GridEngine.placeWhileDragging(source, on: page, row: row, column: column, in: baseline, items: items)
                                    XCTAssertEqual(moved.pages, baseline.pages, "\(sourceSpan) across \(targetSpan), row \(row), column \(column)")
                                    XCTAssertTrue(moved.placements.allSatisfy { $0.pageID == page })
                                    XCTAssertTrue(Page2GridEngine.validate(moved, items: items))
                                } catch { XCTAssertEqual(error as? Page2GridError, .invalidPosition) }
                            }
                        }
                        let bottom = try Page2GridEngine.placeWhileDragging(source, on: page, row: rows - sourceSpan.rows, column: 0, in: baseline, items: items)
                        XCTAssertEqual(bottom.placements.first { $0.id == target.id }?.pageID, page)
                        let returned = try Page2GridEngine.placeWhileDragging(source, on: page, row: 0, column: 0, in: bottom, items: items)
                        XCTAssertEqual(returned.pages, baseline.pages)
                        XCTAssertTrue(Page2GridEngine.validate(returned, items: items))
                    }
                }
            }
        }
    }

    func testLargeWidgetCrossesMultipleSmallWidgetsWithoutEvictingThem() throws {
        var board = Page2Board()
        let page = board.pages[0].id
        let source = Page2Item.widget("calendar", span: .large)
        let a = Page2Item.widget("todo"), b = Page2Item.widget("vocab")
        let items = [source, a, b]
        board.placements = [.init(id: source.id, pageID: page, row: 0, column: 0),
                            .init(id: a.id, pageID: page, row: 4, column: 0),
                            .init(id: b.id, pageID: page, row: 4, column: 2)]
        let moved = try Page2GridEngine.placeWhileDragging(source, on: page, row: 2, column: 0, in: board, items: items)
        XCTAssertEqual(moved.pages, board.pages)
        XCTAssertEqual(Set(moved.placements.filter { $0.row == 0 }.map(\.id)), Set([a.id, b.id]))
        XCTAssertTrue(Page2GridEngine.validate(moved, items: items))
    }

    func testTwoLargeWidgetsCannotEvictEachOtherFromPhonePage() throws {
        var board = Page2Board()
        let first = board.pages[0].id, second = board.appendPage()
        let a = Page2Item.widget("todo", span: .large), b = Page2Item.widget("calendar", span: .large)
        board.placements = [.init(id: a.id, pageID: first, row: 0, column: 0),
                            .init(id: b.id, pageID: second, row: 0, column: 0)]
        let original = board
        XCTAssertThrowsError(try Page2GridEngine.placeWhileDragging(a, on: second, row: 2, column: 0, in: board, items: [a,b])) {
            XCTAssertEqual($0 as? Page2GridError, .invalidPosition)
        }
        XCTAssertEqual(board, original)
    }

    func testLargeWidgetCrossingMatchesNativeSamePageReflow() throws {
        var board = Page2Board()
        let page = board.pages[0].id
        let widget = Page2Item.widget("calendar", span: .large)
        let photo = Page2Item.app("photos"), left = Page2Item.app("left"), right = Page2Item.app("right")
        let items = [widget, photo, left, right]
        board.placements = [.init(id: left.id, pageID: page, row: 0, column: 0),
                            .init(id: right.id, pageID: page, row: 0, column: 2),
                            .init(id: photo.id, pageID: page, row: 1, column: 1),
                            .init(id: widget.id, pageID: page, row: 2, column: 0)]
        board = try Page2GridEngine.placeWhileDragging(photo, on: page, row: 5, column: 1, in: board, items: items)
        XCTAssertEqual(board.placements.first { $0.id == widget.id }?.row, 0)
        XCTAssertEqual(board.placements.first { $0.id == left.id }?.row, 4)
        XCTAssertEqual(board.placements.first { $0.id == right.id }?.row, 4)
        board = try Page2GridEngine.placeWhileDragging(photo, on: page, row: 1, column: 1, in: board, items: items)
        XCTAssertEqual(board.placements.first { $0.id == widget.id }?.row, 2)
        XCTAssertEqual(board.placements.first { $0.id == left.id }?.row, 1)
        XCTAssertEqual(board.placements.first { $0.id == right.id }?.row, 1)
        board = try Page2GridEngine.placeWhileDragging(photo, on: page, row: 4, column: 1, in: board, items: items)
        XCTAssertEqual(board.placements.first { $0.id == widget.id }?.row, 0)
        XCTAssertEqual(board.pages.count, 1)
        XCTAssertTrue(Page2GridEngine.validate(board, items: items))
    }

    func testFullPageWidgetCrossingKeepsEveryItemOnSamePage() throws {
        for span in Page2Span.widgetSizes {
            var board = Page2Board()
            let page = board.pages[0].id
            let widget = Page2Item.widget("todo", span: span)
            let apps = (0..<(24 - span.rows * span.columns)).map { Page2Item.app("tool-\($0)") }
            let items = [widget] + apps
            board.placements = [.init(id: widget.id, pageID: page, row: 0, column: 0)]
            for app in apps { board.placements.append(Page2GridEngine.firstVacancy(for: app, in: &board, items: items)) }
            let source = apps.last!
            let result = try Page2GridEngine.placeWhileDragging(source, on: page, row: 0, column: 0, in: board, items: items)
            XCTAssertEqual(result.pages.count, 1)
            XCTAssertEqual(Set(result.placements.map(\.id)), Set(items.map(\.id)))
            XCTAssertTrue(Page2GridEngine.validate(result, items: items))
            XCTAssertThrowsError(try Page2GridEngine.placeWhileDragging(source, on: page, row: 0, column: 0,
                                                                       in: board, items: items, reserved: [widget.id]))
        }
    }

    func testHorizontalDragUsesSourceHoleInsteadOfUnrelatedHoleAbove() throws {
        var board = Page2Board()
        let source = Page2Item.app("reading"), neighbor = Page2Item.app("browser")
        let page = board.pages[0].id
        board.placements = [.init(id: source.id, pageID: page, row: 1, column: 1),
                            .init(id: neighbor.id, pageID: page, row: 1, column: 2)]
        let result = try Page2GridEngine.placeWhileDragging(source, on: page, row: 1, column: 2, in: board, items: [source, neighbor])
        XCTAssertEqual(result.placements.first { $0.id == neighbor.id }, .init(id: neighbor.id, pageID: page, row: 1, column: 1))
        XCTAssertFalse(result.placements.contains { $0.row == 0 })
    }

    func testDraggingThroughOccupiedIconsPreservesTheirOrder() throws {
        let (board, items) = filled(8)
        let page = board.pages[0].id
        let result = try Page2GridEngine.placeWhileDragging(items[0], on: page, row: 1, column: 2, in: board, items: items)
        for index in 1...6 {
            let position = try XCTUnwrap(result.placements.first { $0.id == items[index].id })
            XCTAssertEqual(position.row * board.columns + position.column, index - 1)
        }
        XCTAssertEqual(result.placements.first { $0.id == items[7].id }, board.placements[7])
        XCTAssertTrue(Page2GridEngine.validate(result, items: items))
    }

    func testDragReflowStopsAtExistingHole() throws {
        var board = Page2Board()
        let items = (0..<3).map { Page2Item.app("tool-\($0)") }
        let page = board.pages[0].id
        board.placements = [.init(id: items[0].id, pageID: page, row: 0, column: 0),
                            .init(id: items[1].id, pageID: page, row: 0, column: 1),
                            .init(id: items[2].id, pageID: page, row: 0, column: 3)]
        let result = try Page2GridEngine.placeWhileDragging(items[0], on: page, row: 0, column: 3, in: board, items: items)
        XCTAssertEqual(result.placements.first { $0.id == items[1].id }, board.placements[1])
        XCTAssertEqual(result.placements.first { $0.id == items[2].id }?.column, 2)
        XCTAssertFalse(result.placements.contains { $0.row == 0 && $0.column == 0 })
    }

    func testDragReflowCannotDisplaceReservedTarget() throws {
        let (board, items) = filled(8)
        XCTAssertThrowsError(try Page2GridEngine.placeWhileDragging(items[0], on: board.pages[0].id, row: 0, column: 2,
                                                                   in: board, items: items, reserved: [items[2].id]))
    }

    func testDraggingAcrossCellBoundaryHasHysteresis() {
        XCTAssertEqual(Page2GridEngine.dragIndex(position: 54, step: 100, current: 0, maximum: 3), 0)
        XCTAssertEqual(Page2GridEngine.dragIndex(position: 59, step: 100, current: 0, maximum: 3), 1)
        XCTAssertEqual(Page2GridEngine.dragIndex(position: 49, step: 100, current: 1, maximum: 3), 1)
        XCTAssertEqual(Page2GridEngine.dragIndex(position: 41, step: 100, current: 1, maximum: 3), 0)
        XCTAssertEqual(Page2GridEngine.dragIndex(position: 310, step: 100, current: 0, maximum: 3), 3)
        XCTAssertEqual(Page2GridEngine.dragIndex(position: -80, step: 100, current: 0, maximum: 3), 0)
    }

    func testInitialInsertionUsesReadingOrderRatherThanDiagonalPacking() {
        let (board, _) = filled(8)
        XCTAssertEqual(board.placements.map(\.row), [0, 0, 0, 0, 1, 1, 1, 1])
        XCTAssertEqual(board.placements.map(\.column), [0, 1, 2, 3, 0, 1, 2, 3])
    }

    func testBlankRowsSurviveMoveAndCodableRoundtrip() throws {
        let (board, items) = filled(1)
        let moved = try Page2GridEngine.place(items[0], on: board.pages[0].id, row: 4, column: 3, in: board, items: items)
        let decoded = try JSONDecoder().decode(Page2Board.self, from: JSONEncoder().encode(moved))
        XCTAssertEqual(decoded.placements[0].row, 4)
        XCTAssertEqual(decoded.placements[0].column, 3)
        XCTAssertEqual(decoded.placements.count, 1)
    }

    func testSmallWidgetHasFourAdjacentIconSlots() throws {
        var board = Page2Board()
        let widget = Page2Item.widget("todo")
        let apps = (0..<4).map { Page2Item.app("\($0)") }
        let items = [widget] + apps
        board.placements = [Page2Placement(id: widget.id, pageID: board.pages[0].id, row: 0, column: 0)]
        for (index, app) in apps.enumerated() {
            board.placements.append(Page2Placement(id: app.id, pageID: board.pages[0].id, row: index / 2, column: 2 + index % 2))
        }
        XCTAssertTrue(Page2GridEngine.validate(board, items: items))
    }

    func testFullPageDisplacementKeepsEveryItem() throws {
        let (board, items) = filled()
        let moved = try Page2GridEngine.place(items[0], on: board.pages[0].id, row: 2, column: 2, in: board, items: items)
        XCTAssertTrue(Page2GridEngine.validate(moved, items: items))
        XCTAssertEqual(Set(moved.placements.map(\.id)), Set(items.map(\.id)))
        XCTAssertEqual(moved.pages.count, 1)
    }

    func testGrowingWidgetCreatesStableOverflowPage() throws {
        let (board, original) = filled()
        var items = original
        items[0].kind = "widget"
        items[0].widgetKind = "calendar"
        items[0].span = .large
        let a = try Page2GridEngine.place(items[0], on: board.pages[0].id, row: 0, column: 0, in: board, items: items)
        let b = try Page2GridEngine.place(items[0], on: board.pages[0].id, row: 0, column: 0, in: board, items: items)
        XCTAssertEqual(a, b, "Repeated hover from the same snapshot must be identical, including generated page IDs")
        XCTAssertGreaterThan(a.pages.count, 1)
        XCTAssertTrue(Page2GridEngine.validate(a, items: items))
    }

    func testReservedToolCannotBeDisplaced() {
        let (board, items) = filled(2)
        let target = board.placements[1]
        XCTAssertThrowsError(try Page2GridEngine.place(items[0], on: target.pageID, row: target.row, column: target.column,
                                                     in: board, items: items, reserved: [items[1].id])) { error in
            XCTAssertEqual(error as? Page2GridError, .reservedPosition)
        }
    }

    func testInvalidEdgeAndOverlapRejected() {
        let (board, items) = filled(2)
        XCTAssertThrowsError(try Page2GridEngine.place(items[0], on: board.pages[0].id, row: 6, column: 0, in: board, items: items))
        var overlap = board
        overlap.placements[1].row = overlap.placements[0].row
        overlap.placements[1].column = overlap.placements[0].column
        XCTAssertFalse(Page2GridEngine.validate(overlap, items: items))
    }

    func testCapacityProjectionRetainsAllInstances() {
        let (board, items) = filled(31)
        let projected = Page2GridEngine.project(board, columns: 6, rows: 4, items: items)
        XCTAssertTrue(Page2GridEngine.validate(projected, items: items))
        XCTAssertEqual(projected.placements.count, items.count)
    }

    func testDeterministicMovementSequencePreservesInvariants() throws {
        var (board, items) = filled(37)
        for step in 0..<500 {
            let item = items[(step * 17) % items.count]
            let page = board.pages[(step * 7) % board.pages.count].id
            board = try Page2GridEngine.place(item, on: page, row: (step * 11) % 6, column: (step * 3) % 4, in: board, items: items)
            XCTAssertTrue(Page2GridEngine.validate(board, items: items), "step \(step)")
        }
    }

    func testUnknownWidgetKindRoundtripsWithoutDroppingOtherItems() throws {
        var layout = Page2Layout()
        let item = Page2Item.widget("futureWidget")
        layout.items = [item]
        layout.boards[0].placements = [Page2Placement(id: item.id, pageID: layout.boards[0].pages[0].id, row: 2, column: 1)]
        let decoded = try JSONDecoder().decode(Page2Layout.self, from: JSONEncoder().encode(layout))
        XCTAssertTrue(Page2GridEngine.validate(decoded))
        XCTAssertEqual(decoded.items.first?.widgetKind, "futureWidget")
    }
}

@MainActor
final class Page2HomeStoreTests: XCTestCase {
    private func fixture() -> (UserDefaults, URL) {
        let suite = "ospage-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, FileManager.default.temporaryDirectory
            .appendingPathComponent(suite).appendingPathComponent("layout.json"))
    }

    func testFolderMergePreservesPreviewPlacementInOneSave() throws {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        var writes = 0
        let store = Page2HomeStore(defaults: defaults, fileURL: url) { data, url in
            writes += 1
            try data.write(to: url, options: .atomic)
        }
        store.bootstrap(toolIDs: [], dockIDs: [])
        let a = Page2Item.app("calendar"), b = Page2Item.app("memory")
        XCTAssertTrue(store.insert(a, capacity: "4x6"))
        XCTAssertTrue(store.insert(b, capacity: "4x6"))
        let before = store.layout
        let board = before.boards[0]
        let preview = try Page2GridEngine.place(a, on: board.pages[0].id, row: 0, column: 1, in: board, items: before.rootItems)
        let expected = try XCTUnwrap(preview.placements.first { $0.id == b.id })
        writes = 0
        XCTAssertTrue(store.combine(a.id, with: b.id, preview: preview))
        XCTAssertEqual(writes, 1)
        let folder = try XCTUnwrap(store.layout.rootItems.first { $0.kind == "folder" })
        let placed = try XCTUnwrap(store.layout.boards[0].placements.first { $0.id == folder.id })
        XCTAssertEqual(placed.column, expected.column)
        store.undo()
        XCTAssertEqual(store.layout, before)
    }

    func testExplicitEmptyLegacyDesktopRemainsEmpty() throws {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: ["calendar"], dockIDs: [])
        XCTAssertTrue(store.layout.items.isEmpty)
        let reloaded = Page2HomeStore(defaults: defaults, fileURL: url)
        reloaded.bootstrap(toolIDs: ["calendar", "memory"], dockIDs: ["calendar"])
        XCTAssertEqual(reloaded.layout, store.layout)
    }

    func testAllSixLegacyWidgetsKeepSizesAndOrder() {
        let (defaults, url) = fixture()
        defaults.set(Data("[{\"kind\":\"pet\",\"size\":\"small\"},{\"kind\":\"todo\",\"size\":\"large\"},{\"kind\":\"garden\",\"size\":\"medium\"},{\"kind\":\"contacts\",\"size\":\"small\"},{\"kind\":\"vocab\",\"size\":\"medium\"},{\"kind\":\"topicBox\",\"size\":\"medium\"}]".utf8), forKey: "dashboardWidgets_v2")
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: [], dockIDs: [])
        XCTAssertEqual(store.layout.items.compactMap(\.widgetKind), ["pet", "todo", "garden", "contacts", "vocab", "topicBox"])
        XCTAssertEqual(store.layout.items[1].span, .large)
        XCTAssertTrue(Page2GridEngine.validate(store.layout))
    }

    func testOneSavePerCommittedDropAndUndo() throws {
        let (defaults, url) = fixture()
        var writes = 0
        let store = Page2HomeStore(defaults: defaults, fileURL: url) { data, url in
            writes += 1
            try data.write(to: url, options: .atomic)
        }
        store.bootstrap(toolIDs: ["calendar"], dockIDs: [])
        let before = store.layout
        let board = before.boards[0]
        let item = before.items.last!
        let candidate = try Page2GridEngine.place(item, on: board.pages[0].id, row: 5, column: 3, in: board, items: before.rootItems)
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(store.commit(candidate, basedOn: before))
        XCTAssertEqual(writes, 2)
        store.undo()
        XCTAssertEqual(store.layout, before)
        XCTAssertEqual(writes, 3)
    }

    func testSaveFailureKeepsCommittedLayoutAndDock() {
        let (defaults, url) = fixture()
        var fail = false
        let store = Page2HomeStore(defaults: defaults, fileURL: url) { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        store.bootstrap(toolIDs: [], dockIDs: ["memory"])
        let previous = store.layout
        fail = true
        store.setDock(["calendar"])
        XCTAssertEqual(store.layout, previous)
        XCTAssertEqual(defaults.stringArray(forKey: "page2DockTools_v1"), ["memory"])
        XCTAssertNotNil(store.errorMessage)
    }

    func testLegacyDockMigrationKeepsHomeItemsAndStableSavedIdentity() throws {
        let (defaults, url) = fixture()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var old = Page2Layout()
        old.dockIDs = ["calendar", "memory"]
        try JSONEncoder().encode(old).write(to: url)
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        XCTAssertEqual(store.layout.dockItems.map(\.toolID), ["calendar", "memory"])
        XCTAssertTrue(store.layout.rootItems.isEmpty)
        let ids = store.layout.dockItemIDs
        store.setDock(["calendar", "memory"])
        let loaded = Page2HomeStore(defaults: defaults, fileURL: url)
        XCTAssertEqual(loaded.layout.dockItemIDs, ids)
        XCTAssertTrue(Page2GridEngine.validate(loaded.layout))
    }

    func testDockFolderCanBeCreatedMovedOutAndBackWithoutLosingChildren() throws {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: [], dockIDs: ["calendar", "memory"])
        let apps = store.layout.dockItems
        XCTAssertTrue(store.combine(apps[1].id, with: apps[0].id))
        let folder = try XCTUnwrap(store.layout.dockItems.first)
        XCTAssertEqual(folder.kind, "folder")
        XCTAssertEqual(Set(folder.children), Set(apps.map(\.id)))
        XCTAssertEqual(store.layout.dockItems.count, 1)
        XCTAssertTrue(store.layout.rootItems.isEmpty)
        var board = store.layout.boards[0]
        board = try Page2GridEngine.place(folder, on: board.pages[0].id, row: 3, column: 2,
                                          in: board, items: store.layout.rootItems + [folder])
        XCTAssertTrue(store.commitDockExtraction(folder.id, board: board, basedOn: store.layout))
        XCTAssertEqual(store.layout.rootItems.first?.id, folder.id)
        XCTAssertTrue(store.layout.dockItems.isEmpty)
        XCTAssertTrue(store.moveToDock(folder.id, at: 0))
        store.rename(folder.id, title: "常用")
        let loaded = Page2HomeStore(defaults: defaults, fileURL: url)
        XCTAssertEqual(loaded.layout.dockItems.first?.title, "常用")
        XCTAssertEqual(loaded.layout.item(folder.id)?.children, folder.children)
        XCTAssertTrue(Page2GridEngine.validate(loaded.layout))
    }

    func testHomeAppMergesIntoDockFolderAndLastChildRemovesEmptyDockFolder() throws {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: [], dockIDs: ["calendar"])
        let target = try XCTUnwrap(store.layout.dockItems.first)
        let source = Page2Item.app("memory")
        XCTAssertTrue(store.insert(source, capacity: "4x6"))
        XCTAssertTrue(store.combine(source.id, with: target.id))
        let folder = try XCTUnwrap(store.layout.dockItems.first)
        XCTAssertTrue(store.layout.rootItems.isEmpty)
        store.remove(source.id)
        XCTAssertEqual(store.layout.dockItems.first?.children, [target.id])
        store.remove(target.id)
        XCTAssertTrue(store.layout.dockItems.isEmpty)
        XCTAssertTrue(Page2GridEngine.validate(store.layout))
    }

    func testFullDockRejectsExtraAppAndStaleExtraction() throws {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: [], dockIDs: ["a", "b", "c", "d"])
        let source = Page2Item.app("e")
        XCTAssertTrue(store.insert(source, capacity: "4x6"))
        let before = store.layout
        XCTAssertFalse(store.moveToDock(source.id, at: 0))
        XCTAssertEqual(store.layout, before)
        let dock = store.layout.dockItems[0]
        store.setDock(["b", "a", "c", "d"])
        XCTAssertFalse(store.commitDockExtraction(dock.id, board: before.boards[0], basedOn: before))
        XCTAssertTrue(Page2GridEngine.validate(store.layout))
    }

    func testFolderToDockMovesChildInOneSaveAndUndoRestoresFolder() throws {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        var writes = 0
        let store = Page2HomeStore(defaults: defaults, fileURL: url) { data, url in writes += 1; try data.write(to: url) }
        store.bootstrap(toolIDs: [], dockIDs: ["c", "d"])
        let a = Page2Item.app("a"), b = Page2Item.app("b")
        XCTAssertTrue(store.insert(a, capacity: "4x6"))
        XCTAssertTrue(store.insert(b, capacity: "4x6"))
        XCTAssertTrue(store.combine(a.id, with: b.id))
        let before = store.layout, count = writes
        XCTAssertTrue(store.moveToDock(a.id, at: 1))
        XCTAssertEqual(writes, count + 1)
        XCTAssertEqual(store.layout.dockIDs, ["c", "a", "d"])
        XCTAssertEqual(store.layout.dockItems.first { $0.id == a.id }?.toolID, "a")
        XCTAssertFalse(store.layout.rootItems.contains { $0.id == a.id })
        XCTAssertTrue(Page2GridEngine.validate(store.layout))
        store.undo()
        XCTAssertEqual(store.layout, before)
    }

    func testFolderDragPreviewDoesNotSaveAndCommitsChosenPageAtomically() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("page2-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var writes = 0
        let store = Page2HomeStore(defaults: defaults, fileURL: url) { data, url in
            writes += 1; try data.write(to: url)
        }
        store.bootstrap(toolIDs: [], dockIDs: [])
        let apps = ["a", "b", "c"].map(Page2Item.app)
        for app in apps { XCTAssertTrue(store.insert(app, capacity: "4x6")) }
        XCTAssertTrue(store.combine(apps[0].id, with: apps[1].id))
        let folder = try XCTUnwrap(store.layout.rootItems.first { $0.kind == "folder" })
        let baseline = store.layout
        let before = writes
        let draft = try XCTUnwrap(store.extractedLayout(apps[0].id, from: folder.id))
        XCTAssertEqual(store.layout, baseline)
        XCTAssertEqual(writes, before)
        XCTAssertTrue(Page2GridEngine.validate(draft))
        var board = draft.boards[0]
        let page = board.appendPage()
        board = try Page2GridEngine.place(apps[0], on: page, row: 3, column: 2, in: board, items: draft.rootItems)
        XCTAssertTrue(store.commitExtraction(apps[0].id, from: folder.id, board: board, basedOn: baseline))
        XCTAssertEqual(writes, before + 1)
        XCTAssertEqual(store.layout.boards[0].placements.first { $0.id == apps[0].id }?.pageID, page)
        XCTAssertTrue(Page2GridEngine.validate(store.layout))
        XCTAssertFalse(store.commitExtraction(apps[0].id, from: folder.id, board: board, basedOn: baseline))
    }

    func testFolderExtractKeepsOneMemberFolderAndAllBoards() {
        let (defaults, url) = fixture()
        defaults.set("stitch", forKey: "page2DesktopStyle")
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: ["calendar", "memory"], dockIDs: [])
        store.ensureBoard(columns: 6, rows: 4)
        let apps = store.layout.items.filter { $0.kind == "app" }
        XCTAssertTrue(store.combine(apps[0].id, with: apps[1].id))
        let folder = store.layout.items.first { $0.kind == "folder" }!
        store.extract(apps[0].id, from: folder.id)
        XCTAssertEqual(store.layout.item(folder.id)?.children, [apps[1].id])
        XCTAssertTrue(Page2GridEngine.validate(store.layout))
        for board in store.layout.boards {
            XCTAssertTrue(board.placements.contains { $0.id == apps[0].id })
            XCTAssertTrue(board.placements.contains { $0.id == folder.id })
        }
    }

    func testCorruptFileNeverSilentlyOverwritten() throws {
        let (defaults, url) = fixture()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("invalid layout".utf8)
        try data.write(to: url)
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: ["calendar"], dockIDs: [])
        XCTAssertTrue(store.recoveryRequired)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
    func testWidgetResizePreviewDoesNotWriteAndCommitIsOneUndoStep() throws {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        var writes = 0
        let store = Page2HomeStore(defaults: defaults, fileURL: url) { data, url in
            writes += 1; try data.write(to: url, options: .atomic)
        }
        store.bootstrap(toolIDs: [], dockIDs: [])
        let widget = Page2Item.widget("todo")
        XCTAssertTrue(store.insert(widget, capacity: "4x6"))
        let baseline = store.layout, count = writes
        for span in [Page2Span.medium, .large, .small, .medium] {
            _ = try Page2GridEngine.resizing(widget.id, to: span, in: baseline)
        }
        XCTAssertEqual(writes, count)
        XCTAssertEqual(store.layout, baseline)
        XCTAssertTrue(store.change(widget.id, span: .medium))
        XCTAssertEqual(writes, count + 1)
        XCTAssertEqual(Page2HomeStore(defaults: defaults, fileURL: url).layout.item(widget.id)?.span, .medium)
        store.undo()
        XCTAssertEqual(store.layout, baseline)
    }

    func testDockToDesktopIsOneSaveAndRestoresWithUndo() {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        var saves = 0
        let store = Page2HomeStore(defaults: defaults, fileURL: url) { data, url in
            saves += 1
            try data.write(to: url, options: .atomic)
        }
        store.bootstrap(toolIDs: [], dockIDs: ["calendar"])
        let before = store.layout
        XCTAssertTrue(store.receive(.dock("calendar"), capacity: "4x6", pageID: before.boards[0].pages[0].id, row: 4, column: 3))
        XCTAssertEqual(saves, 2)
        XCTAssertTrue(store.layout.dockIDs.isEmpty)
        XCTAssertEqual(store.layout.boards[0].placements.first?.row, 4)
        store.undo()
        XCTAssertEqual(store.layout, before)
    }

    func testFolderDropRetainsChildIdentityAndSingleMemberFolder() {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: [], dockIDs: [])
        let a = Page2Item.app("calendar")
        let b = Page2Item.app("memory")
        XCTAssertTrue(store.insert(a, capacity: "4x6"))
        XCTAssertTrue(store.insert(b, capacity: "4x6"))
        XCTAssertTrue(store.combine(a.id, with: b.id))
        let folder = store.layout.items.first { $0.kind == "folder" }!
        let page = store.layout.boards[0].pages[0].id
        XCTAssertTrue(store.receive(.folder(container: folder.id, child: a.id), capacity: "4x6", pageID: page, row: 5, column: 3))
        XCTAssertEqual(store.layout.item(folder.id)?.children, [b.id])
        XCTAssertEqual(Set(store.layout.rootItems.map(\.id)), [a.id, folder.id])
        XCTAssertTrue(Page2GridEngine.validate(store.layout))
    }

    func testStacksFlattenAndRespectTenMemberLimit() throws {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: [], dockIDs: [])
        let widgets = ["todo", "calendar", "vocab", "reading"].map { Page2Item.widget($0) }
        for item in widgets { XCTAssertTrue(store.insert(item, capacity: "4x6")) }
        XCTAssertTrue(store.combine(widgets[0].id, with: widgets[1].id))
        XCTAssertTrue(store.combine(widgets[2].id, with: widgets[3].id))
        let stacks = store.layout.rootItems
        XCTAssertEqual(stacks.count, 2)
        XCTAssertTrue(store.combine(stacks[0].id, with: stacks[1].id))
        let stack = try XCTUnwrap(store.layout.rootItems.first)
        XCTAssertEqual(Set(stack.children), Set(widgets.map(\.id)))
        XCTAssertEqual(store.layout.items.filter { $0.kind == "stack" }.count, 1)
        for i in 4..<10 { XCTAssertTrue(store.addWidget(.widget("tool-\(i)"), toStack: stack.id)) }
        let before = store.layout
        XCTAssertFalse(store.addWidget(.widget("eleventh"), toStack: stack.id))
        XCTAssertFalse(store.addWidget(.widget("wrong-size", span: .large), toStack: stack.id))
        XCTAssertEqual(store.layout, before)
        XCTAssertTrue(Page2GridEngine.validate(store.layout))
    }

    func testStackOrderOptionsAndRemovalPersistAndRejectStaleEdits() throws {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: [], dockIDs: [])
        let a = Page2Item.widget("todo"), b = Page2Item.widget("calendar")
        XCTAssertTrue(store.insert(a, capacity: "4x6")); XCTAssertTrue(store.insert(b, capacity: "4x6"))
        XCTAssertTrue(store.combine(a.id, with: b.id))
        let stack = try XCTUnwrap(store.layout.rootItems.first)
        let baseline = store.layout
        XCTAssertTrue(store.commitStackOrder(stack.id, children: stack.children.reversed(), basedOn: baseline))
        XCTAssertFalse(store.commitStackOrder(stack.id, children: stack.children, basedOn: baseline))
        store.configure(stack.id, values: ["smartRotate": "false", "widgetSuggestions": "false"])
        let loaded = Page2HomeStore(defaults: defaults, fileURL: url)
        XCTAssertEqual(loaded.layout.item(stack.id)?.children, Array(stack.children.reversed()))
        XCTAssertEqual(loaded.layout.item(stack.id)?.configuration["smartRotate"], "false")
        loaded.remove(a.id)
        XCTAssertEqual(loaded.layout.rootItems.map(\.id), [b.id])
        XCTAssertTrue(Page2GridEngine.validate(loaded.layout))
    }

    func testStackRequiresMatchingSizesAndKeepsWidgetIDs() {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: [], dockIDs: [])
        let a = Page2Item.widget("todo")
        let b = Page2Item.widget("vocab")
        let c = Page2Item.widget("reading", span: .large)
        for item in [a, b, c] { XCTAssertTrue(store.insert(item, capacity: "4x6")) }
        XCTAssertFalse(store.combine(a.id, with: c.id))
        XCTAssertTrue(store.combine(a.id, with: b.id))
        XCTAssertTrue(Page2GridEngine.validate(store.layout))
        XCTAssertEqual(store.layout.items.first { $0.kind == "stack" }?.children, [b.id, a.id])
    }
    func testResizingStackUpdatesEveryMemberAndEveryBoard() {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: [], dockIDs: [])
        let a = Page2Item.widget("todo")
        let b = Page2Item.widget("vocab")
        _ = store.insert(a, capacity: "4x6")
        _ = store.insert(b, capacity: "4x6")
        _ = store.combine(a.id, with: b.id)
        store.ensureBoard(columns: 6, rows: 4)
        let stack = store.layout.rootItems.first!
        XCTAssertTrue(store.change(stack.id, span: .large))
        XCTAssertTrue(store.layout.items.allSatisfy { $0.span == .large })
        XCTAssertTrue(Page2GridEngine.validate(store.layout))
    }
}

final class Page2FolderPagesTests: XCTestCase {
    func testLegacyFolderDecodesIntoNineItemPages() throws {
        let children = (0..<10).map { _ in UUID() }
        let legacy = Page2Item(kind: "folder", children: children)
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("folderPages"))
        let decoded = try JSONDecoder().decode(Page2Item.self, from: data)
        XCTAssertEqual(decoded.childPages, [Array(children.prefix(9)), [children[9]]])
    }
    func testPartialPagesSurvivePersistenceWithoutPacking() throws {
        let a = UUID(), b = UUID(), c = UUID()
        var folder = Page2Item(kind: "folder", children: [a, b, c])
        folder.setFolderPages([[a], [b, c]])
        let decoded = try JSONDecoder().decode(Page2Item.self, from: JSONEncoder().encode(folder))
        XCTAssertEqual(decoded.childPages, [[a], [b, c]])
        XCTAssertEqual(decoded.children, [a, b, c])
    }
    func testInsertionOverflowPreservesEveryMemberAndOrder() {
        let ids = (0..<18).map { _ in UUID() }, incoming = UUID()
        let pages = Page2FolderPages.inserting(incoming, page: 0, slot: 4, into: [Array(ids.prefix(9)), Array(ids.suffix(9))])
        XCTAssertEqual(pages.map(\.count), [9, 9, 1])
        XCTAssertEqual(pages.flatMap { $0 }, Array(ids.prefix(4)) + [incoming] + Array(ids.dropFirst(4)))
    }
    func testMovingBetweenPartialPagesLeavesOthersOnTheirPage() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(Page2FolderPages.inserting(a, page: 1, slot: 1, into: [[a, b], [c]]), [[b], [c, a]])
    }
    func testRemovingFromLegacyFolderDoesNotPullFromNextPage() {
        let ids = (0..<11).map { _ in UUID() }
        var folder = Page2Item(kind: "folder", children: ids)
        folder.removeChildren([ids[0]])
        XCTAssertEqual(folder.childPages, [Array(ids[1..<9]), Array(ids[9..<11])])
    }
    func testInvalidPageMembershipAndCapacityAreRejected() {
        let apps = (0..<10).map { Page2Item.app("\($0)") }
        var folder = Page2Item(kind: "folder", children: apps.map(\.id))
        var layout = Page2Layout()
        layout.items = apps + [folder]
        layout.boards[0].placements = [.init(id: folder.id, pageID: layout.boards[0].pages[0].id, row: 0, column: 0)]
        XCTAssertTrue(Page2GridEngine.validate(layout))
        folder.folderPages = [apps.map(\.id)]
        layout.items[10] = folder
        XCTAssertFalse(Page2GridEngine.validate(layout))
        folder.folderPages = [[apps[0].id], Array(apps.dropFirst().map(\.id))]
        layout.items[10] = folder
        XCTAssertTrue(Page2GridEngine.validate(layout))
        folder.folderPages = [[apps[0].id], Array(apps.dropLast().map(\.id))]
        layout.items[10] = folder
        XCTAssertFalse(Page2GridEngine.validate(layout))
    }
}

extension Page2HomeStoreTests {
    func testIncomingItemCanCommitToAnEmptyFolderPageAndReload() throws {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); defaults.removePersistentDomain(forName: url.deletingLastPathComponent().lastPathComponent) }
        var writes = 0
        let store = Page2HomeStore(defaults: defaults, fileURL: url) { data, url in writes += 1; try data.write(to: url) }
        store.bootstrap(toolIDs: [], dockIDs: [])
        let apps = ["a", "b", "c"].map(Page2Item.app)
        for app in apps { XCTAssertTrue(store.insert(app, capacity: "4x6")) }
        XCTAssertTrue(store.combine(apps[0].id, with: apps[1].id))
        let folder = try XCTUnwrap(store.layout.rootItems.first { $0.kind == "folder" })
        let before = store.layout, count = writes
        XCTAssertTrue(store.combine(apps[2].id, with: folder.id, insertionIndex: 0, folderPage: 1))
        XCTAssertEqual(writes, count + 1)
        XCTAssertEqual(store.layout.item(folder.id)?.childPages, [[apps[1].id, apps[0].id], [apps[2].id]])
        XCTAssertEqual(Page2HomeStore(defaults: defaults, fileURL: url).layout, store.layout)
        store.undo()
        XCTAssertEqual(store.layout, before)
    }
    func testInternalPagesRejectConcurrentChangeAndWriteFailure() throws {
        let (defaults, url) = fixture()
        defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); defaults.removePersistentDomain(forName: url.deletingLastPathComponent().lastPathComponent) }
        var fail = false, writes = 0
        let store = Page2HomeStore(defaults: defaults, fileURL: url) { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            writes += 1; try data.write(to: url)
        }
        store.bootstrap(toolIDs: [], dockIDs: [])
        let a = Page2Item.app("a"), b = Page2Item.app("b")
        XCTAssertTrue(store.insert(a, capacity: "4x6")); XCTAssertTrue(store.insert(b, capacity: "4x6"))
        XCTAssertTrue(store.combine(a.id, with: b.id))
        let folder = try XCTUnwrap(store.layout.rootItems.first { $0.kind == "folder" }), baseline = store.layout
        let count = writes
        fail = true
        XCTAssertFalse(store.commitFolderPages(folder.id, pages: [[b.id], [a.id]], basedOn: baseline))
        XCTAssertEqual(store.layout, baseline); XCTAssertEqual(writes, count)
        fail = false
        store.rename(folder.id, title: "Renamed")
        let renamed = store.layout, renamedWrites = writes
        XCTAssertFalse(store.commitFolderPages(folder.id, pages: [[b.id], [a.id]], basedOn: baseline))
        XCTAssertEqual(store.layout, renamed); XCTAssertEqual(writes, renamedWrites)
    }
}
