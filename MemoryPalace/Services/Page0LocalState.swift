import Foundation

struct GroupAppearance: Codable, Equatable {
    enum Kind: String, Codable { case members, image, emoji, symbol }
    var kind: Kind = .members
    var emoji = "💬"
    var symbol = "person.2"
    var colorHex = "#7FB39A"
    /// 这个群单独的聊天颜色（编辑群聊 › 聊天外观）；nil = 跟随 设置 › 群聊 › 聊天外观
    var backgroundHex: String?
    var othersBubbleHex: String?
    var mineBubbleHex: String?
}

/// 仅本机的楼层偏好；群文件夹、群名和头像不进入备份、不跨设备。测试必须注入独立 suite。
struct Page0LocalState {
    let defaults: UserDefaults
    let profileId: String
    private func key(_ name: String) -> String { "\(name).\(profileId)" }

    var roomFolders: [String: String] {
        get { defaults.dictionary(forKey: key("agoraRoomFolder")) as? [String: String] ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: key("agoraRoomFolder")) }
    }
    var readSequences: [String: Int] {
        get { defaults.dictionary(forKey: key("agoraReadSeq")) as? [String: Int] ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: key("agoraReadSeq")) }
    }
    var roomTitles: [String: String] {
        defaults.dictionary(forKey: key("agoraRoomTitles")) as? [String: String] ?? [:]
    }
    var roomAppearances: [String: GroupAppearance] {
        guard let data = defaults.data(forKey: key("agoraRoomAppearances")) else { return [:] }
        return (try? JSONDecoder().decode([String: GroupAppearance].self, from: data)) ?? [:]
    }
    func setRoomTitle(_ title: String, roomId: String) {
        var values = roomTitles
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        values[roomId] = trimmed.isEmpty ? nil : trimmed
        defaults.set(values, forKey: key("agoraRoomTitles"))
    }
    func setRoomAppearance(_ appearance: GroupAppearance, roomId: String) throws {
        var values = roomAppearances
        values[roomId] = appearance
        defaults.set(try JSONEncoder().encode(values), forKey: key("agoraRoomAppearances"))
    }
    /// 本机表情回应（hub 还没有这个动作，只自己看得见）：roomId → messageId → [emoji]，按点的先后
    var reactions: [String: [String: [String]]] {
        defaults.dictionary(forKey: key("agoraReactions")) as? [String: [String: [String]]] ?? [:]
    }
    /// 点一次加上，同一个再点一次取消
    func toggleReaction(_ emoji: String, messageId: String, roomId: String) {
        var values = reactions
        var room = values[roomId] ?? [:]
        var list = room[messageId] ?? []
        if let index = list.firstIndex(of: emoji) { list.remove(at: index) } else { list.append(emoji) }
        room[messageId] = list.isEmpty ? nil : list
        values[roomId] = room.isEmpty ? nil : room
        defaults.set(values, forKey: key("agoraReactions"))
    }
    private func avatarURL(roomId: String) -> URL {
        StagingPaths.applicationSupportRoot
            .appendingPathComponent("GroupAvatars", isDirectory: true)
            .appendingPathComponent(profileId, isDirectory: true)
            .appendingPathComponent("\(roomId).jpg")
    }
    func roomAvatar(roomId: String) -> Data? {
        try? Data(contentsOf: avatarURL(roomId: roomId))
    }
    func saveRoomAvatar(_ data: Data, roomId: String) throws {
        let url = avatarURL(roomId: roomId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func removeFolder(_ id: String) {
        roomFolders = roomFolders.filter { $0.value != id }
    }
    func establishBaseline(roomId: String, nextSeq: Int) {
        guard readSequences[roomId] == nil else { return }
        markRead(roomId: roomId, sequence: max(0, nextSeq - 1))
    }
    func markRead(roomId: String, sequence: Int) {
        var values = readSequences
        values[roomId] = max(values[roomId] ?? 0, sequence)
        readSequences = values
    }
    func unreadCount(roomId: String, nextSeq: Int) -> Int {
        max(0, nextSeq - 1 - (readSequences[roomId] ?? max(0, nextSeq - 1)))
    }
    static func unreadLabel(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }

}
