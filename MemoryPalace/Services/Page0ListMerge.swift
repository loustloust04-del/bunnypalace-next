import Foundation

enum PageZeroListItem: Hashable, Identifiable {
    case conversation(String)
    case room(String)
    var id: String {
        switch self {
        case .conversation(let id): return "conversation:\(id)"
        case .room(let id): return "room:\(id)"
        }
    }
}

/// 输入为已排序的分页快照；不读取数据库，也不改变分页游标。
enum Page0ListMerge {
    struct ConversationEntry {
        let id: String
        let isPinned: Bool
        let updateTime: Date
    }
    struct RoomEntry {
        let id: String
        let updatedAt: Date
    }
    static func merge(conversations: [ConversationEntry], rooms: [RoomEntry], hasMorePages: Bool) -> [PageZeroListItem] {
        let sortedRooms = rooms.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
        var result: [PageZeroListItem] = []
        var roomIndex = 0
        for conversation in conversations {
            if !conversation.isPinned {
                while roomIndex < sortedRooms.count && sortedRooms[roomIndex].updatedAt > conversation.updateTime {
                    result.append(.room(sortedRooms[roomIndex].id))
                    roomIndex += 1
                }
            }
            result.append(.conversation(conversation.id))
        }
        if !hasMorePages {
            result.append(contentsOf: sortedRooms.dropFirst(roomIndex).map { .room($0.id) })
        }
        return result
    }
}
