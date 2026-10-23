import XCTest
@testable import 记忆花园

@MainActor
final class Page0GroupChatTests: XCTestCase {
    private func state(_ body: (Page0LocalState) throws -> Void) rethrows {
        let suite = "Page0GroupChatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(Page0LocalState(defaults: defaults, profileId: "floor"))
    }
    private func conversation(_ id: String, _ time: Double, pinned: Bool = false) -> Page0ListMerge.ConversationEntry {
        .init(id: id, isPinned: pinned, updateTime: Date(timeIntervalSince1970: time))
    }
    private func room(_ id: String, _ time: Double) -> Page0ListMerge.RoomEntry {
        .init(id: id, updatedAt: Date(timeIntervalSince1970: time))
    }
    func testPinnedSegmentStaysAheadOfRooms() {
        let items = Page0ListMerge.merge(conversations: [conversation("p", 1, pinned: true), conversation("c", 5)], rooms: [room("r", 10)], hasMorePages: false)
        XCTAssertEqual(items, [.conversation("p"), .room("r"), .conversation("c")])
    }
    func testRoomsInsertByActivityAndTiesKeepConversationFirst() {
        let items = Page0ListMerge.merge(conversations: [conversation("a", 10), conversation("b", 5)], rooms: [room("old", 5), room("new", 8)], hasMorePages: false)
        XCTAssertEqual(items, [.conversation("a"), .room("new"), .conversation("b"), .room("old")])
    }
    func testOlderRoomsWaitForNextPage() {
        XCTAssertEqual(Page0ListMerge.merge(conversations: [conversation("a", 10)], rooms: [room("r", 1)], hasMorePages: true), [.conversation("a")])
        XCTAssertEqual(Page0ListMerge.merge(conversations: [conversation("p", 10, pinned: true)], rooms: [room("r", 20)], hasMorePages: true), [.conversation("p")])
    }
    func testFullyLoadedRoomsAppendIncludingEmptyConversationList() {
        XCTAssertEqual(Page0ListMerge.merge(conversations: [conversation("a", 10)], rooms: [room("r", 1)], hasMorePages: false), [.conversation("a"), .room("r")])
        XCTAssertEqual(Page0ListMerge.merge(conversations: [], rooms: [room("r", 1)], hasMorePages: false), [.room("r")])
    }
    func testReadBaselineUnreadCapAndFloorIsolation() {
        state { store in
            store.establishBaseline(roomId: "r", nextSeq: 12)
            XCTAssertEqual(store.unreadCount(roomId: "r", nextSeq: 12), 0)
            store.establishBaseline(roomId: "r", nextSeq: 200)
            XCTAssertEqual(store.unreadCount(roomId: "r", nextSeq: 200), 188)
            XCTAssertEqual(Page0LocalState.unreadLabel(188), "99+")
            XCTAssertEqual(Page0LocalState.unreadLabel(99), "99")
            store.markRead(roomId: "r", sequence: 199)
            store.markRead(roomId: "r", sequence: 3)
            XCTAssertEqual(store.unreadCount(roomId: "r", nextSeq: 200), 0)
            XCTAssertEqual(store.unreadCount(roomId: "r", nextSeq: 1), 0)
            XCTAssertTrue(Page0LocalState(defaults: store.defaults, profileId: "other").readSequences.isEmpty)
        }
    }
    func testDeletingFolderOnlyClearsItsRoomMappings() {
        state { store in
            store.roomFolders = ["a": "folder", "b": "other", "c": "folder"]
            store.removeFolder("folder")
            XCTAssertEqual(store.roomFolders, ["b": "other"])
        }
    }
    func testRoomTitleTrimsAndBlankRemovesOverride() {
        state { store in
            store.setRoomTitle("  自定义群名\n", roomId: "r")
            store.setRoomTitle("保留", roomId: "other")
            let reloaded = Page0LocalState(defaults: store.defaults, profileId: store.profileId)
            XCTAssertEqual(reloaded.roomTitles["r"], "自定义群名")
            store.setRoomTitle(" \n\t ", roomId: "r")
            XCTAssertNil(reloaded.roomTitles["r"])
            XCTAssertEqual(reloaded.roomTitles["other"], "保留")
        }
    }

    func testRoomAppearancesRoundTripAllKinds() throws {
        try state { store in
            for kind in [GroupAppearance.Kind.members, .image, .emoji, .symbol] {
                let appearance = GroupAppearance(kind: kind, emoji: "🌸", symbol: "leaf", colorHex: "#CF9A8A")
                try store.setRoomAppearance(appearance, roomId: kind.rawValue)
                let reloaded = Page0LocalState(defaults: store.defaults, profileId: store.profileId)
                XCTAssertEqual(reloaded.roomAppearances[kind.rawValue], appearance)
            }
            XCTAssertEqual(store.roomAppearances.count, 4)
            try store.setRoomAppearance(GroupAppearance(), roomId: "symbol")
            XCTAssertEqual(store.roomAppearances["symbol"], GroupAppearance())
            XCTAssertEqual(store.roomAppearances["emoji"]?.kind, .emoji)
        }
    }

    func testRoomCustomizationsAreIsolatedByFloor() throws {
        try state { store in
            let other = Page0LocalState(defaults: store.defaults, profileId: "other")
            store.setRoomTitle("楼层一", roomId: "r")
            let appearance = GroupAppearance(kind: .symbol, emoji: "🌸", symbol: "heart", colorHex: "#D4A5A5")
            try store.setRoomAppearance(appearance, roomId: "r")
            XCTAssertTrue(other.roomTitles.isEmpty)
            XCTAssertTrue(other.roomAppearances.isEmpty)
            other.setRoomTitle("楼层二", roomId: "r")
            try other.setRoomAppearance(GroupAppearance(), roomId: "r")
            XCTAssertEqual(store.roomTitles["r"], "楼层一")
            XCTAssertEqual(store.roomAppearances["r"], appearance)
            XCTAssertEqual(other.roomTitles["r"], "楼层二")
            XCTAssertEqual(other.roomAppearances["r"], GroupAppearance())
        }
    }
}
