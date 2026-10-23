#if DEBUG
import Foundation
import SwiftData

/// [PAGE0 seed] 列表打磨截图用样例：CC（默认 / 编号 / 在文件夹里）、codex、API、导入档案、未读、一个带说明的文件夹。
/// 触发：`--page0-list-seed`。每次清掉自己的 id 前缀重建，不碰别的对话。
enum Page0ListSeed {
    private static let prefix = "page0seed-"

    static var isActive: Bool { CommandLine.arguments.contains("--page0-list-seed") }

    /// 群聊内页截图用的假消息（不连 hub）：连发、跨时段、代码块、@、自己的、已删除
    static func roomMessages(_ room: AgoraRoomSummary) -> [AgoraMessage] {
        guard isActive else { return [] }
        let actors = room.members.map(\.actorId)
        func a(_ i: Int) -> String { actors.isEmpty ? room.ownerActorId : actors[min(i, actors.count - 1)] }
        let me = room.ownerActorId
        let now = Date()
        let script: [(String, Double, String, Bool, Bool)] = [
            (me, -60 * 24 * 11, "明天把群聊内页改了吧", false, false),
            (a(0), -95, "看了一下，文件夹卡片那几朵花是按 id 定随机的，所以每次打开都一样。", false, false),
            (a(0), -94.5, "要不要我顺手把群聊也接上同一套点点花？", false, false),
            (a(1), -93, "好呀 🌷 不过先别动 @seed2 那边的分页", false, false),
            (a(2), -92, "收到，分页只加了兜底排序：\n\n```swift\nsortBy + [SortDescriptor(\\.id)]\n```", false, false),
            (me, -90, "那就这么定", false, false),
            (me, -89.8, "@seed0 花做成开关", true, false),
            (a(0), -40, "我先列了一下两边的差别：\n\n1. 气泡模式有尾巴、按段落拆泡\n2. 群聊有连发合并、@ 补全\n\n建议抽一个共用的气泡行，列表和输入栏各管各的。", false, false),
            (a(1), -38, "这条我说错了", false, true),
        ]
        return script.enumerated().map { i, item in
            let (actor, minutes, text, edited, deleted) = item
            let at = now.addingTimeInterval(minutes * 60)
            return AgoraMessage(id: prefix + "msg-\(room.id)-\(i)", roomId: room.id, seq: i + 1, actorId: actor,
                                clientMessageId: "seed-\(i)", content: deleted ? "" : text, createdAt: at,
                                editedAt: edited ? at.addingTimeInterval(60) : nil, isDeleted: deleted,
                                deletedAt: deleted ? at : nil)
        }
    }

    static func roomTyping(_ room: AgoraRoomSummary) -> [String: AgoraTypingPresence] {
        guard isActive, let member = room.members.first else { return [:] }
        return [member.actorId: AgoraTypingPresence(roomId: room.id, actorId: member.actorId, membershipId: member.id,
                                                    handle: member.handle, displayName: member.displayName,
                                                    isTyping: true, updatedAt: Date())]
    }

    @MainActor
    static func rooms(profileId pid: String) -> [AgoraRoomSummary] {
        guard isActive else { return [] }
        let state = Page0LocalState(defaults: .standard, profileId: pid)
        let stored = ProfileManager.loadProfiles().first { $0.id == pid }?.assistantName ?? ""
        let charName = stored.isEmpty ? "助手" : stored
        let specs: [(String, String, Double, Bool, Int)] = [
            ("garden", "花园议事厅", 2, false, 106),
            ("dm", charName, 15, true, 4),
            ("code", "代码讨论", 90, false, 8),
            ("old", "去年夏天", 60 * 24 * 400, false, 2)
        ]
        let result = specs.map { key, title, minutes, isDM, nextSeq in
            let id = prefix + "room-" + key
            let date = Date().addingTimeInterval(-minutes * 60)
            let names = isDM ? [charName] : ["小克", charName, "Codex"]
            let members = names.enumerated().map { index, name in
                AgoraMember(id: id + "-member-\(index)", roomId: id, actorId: "seed-actor-\(index)",
                            handle: "seed\(index)", displayName: name, avatarRef: nil, role: .member,
                            executorKind: .ccBridge, isEnabled: true, joinedAt: date)
            }
            return AgoraRoomSummary(id: id, floorId: pid, title: title, ownerActorId: "seed-owner",
                                    isDM: isDM, dmPeerActorId: isDM ? members.first?.actorId : nil,
                                    nextSeq: nextSeq, isEnabled: true, createdAt: date, updatedAt: date,
                                    memberCount: members.count, members: members)
        }
        var folders = state.roomFolders
        folders[prefix + "room-code"] = prefix + "folder-code"
        state.roomFolders = folders
        for room in result { state.markRead(roomId: room.id, sequence: room.nextSeq - 1) }
        var sequences = state.readSequences
        sequences[prefix + "room-garden"] = 3
        state.readSequences = sequences
        return result
    }

    @MainActor
    static func injectIfNeeded(container: ModelContainer, profileId pid: String) {
        guard isActive else { return }
        UserDefaults.standard.set(true, forKey: AgoraFeatureGate.key)
        let ctx = ModelContext(container)
        let p = prefix
        try? ctx.delete(model: Conversation.self, where: #Predicate { $0.id.starts(with: p) })
        try? ctx.delete(model: MessageNode.self, where: #Predicate { $0.conversationId.starts(with: p) })
        try? ctx.delete(model: ConversationTag.self, where: #Predicate { $0.id.starts(with: p) })

        let folder = ConversationTag(name: "码", emoji: "🎯", order: 0, profileId: pid)
        folder.id = prefix + "folder-code"
        folder.symbol = "chevron.left.forwardslash.chevron.right"
        folder.colorHex = "#7FB39A"
        folder.instructions = "这里都是写代码的对话，回答直接给专业级方案。"
        ctx.insert(folder)
        let heart = ConversationTag(name: "嘿嘿", emoji: "❤️", order: 1, profileId: pid)
        heart.id = prefix + "folder-heart"
        ctx.insert(heart)

        let rows: [(id: String, title: String, provider: String, session: String?, unread: Int, minutesAgo: Double,
                    folder: String?, reply: String)] = [
            ("cc-running", "记忆模块体检和衰减引擎", "api", "mp-cc", 0, 3, nil, "我先看 DecayEngine 的阈值比较。"),
            ("todo", "今天的待办", "api", nil, 2, 30, nil, "剩下三项里「回邮件」最急，我先帮你起个草稿？"),
            ("cc-52", "记忆…梳理", "api", "mp-cc-52", 3, 60 * 24, folder.id, "衰减阈值我调回 0.35 了，hot 层现在 41 条。"),
            ("cc-66", "色色，塑料球，附子", "api", "mp-cc-66", 0, 60 * 26, nil, "好，那今晚先到这，明天接着看附子那段。"),
            ("codex", "推特书签分页重写", "api", "mp-codex-3", 0, 60 * 48, folder.id, "分页游标改成 sortIndex 了，测试 12/12 过。"),
            ("weekend", "周末去哪", "api", nil, 0, 60 * 24 * 4, nil, "植物园那条线人少，下午四点光线最好。"),
            ("archive", "意识，哲学，记忆，语言", "chatgpt", nil, 0, 60 * 24 * 300, nil, "维特根斯坦会说，这里的「记住」本身就是一种用法。"),
        ]
        for r in rows {
            let cid = prefix + r.id
            let t = Date().addingTimeInterval(-r.minutesAgo * 60)
            let userNode = MessageNode(id: cid + "-u", role: "user", content: "（样例提问）", contentType: "text",
                                       createTime: t, parentId: nil, childrenIds: [cid + "-a"], conversationId: cid, profileId: pid)
            let replyNode = MessageNode(id: cid + "-a", role: "assistant", content: r.reply, contentType: "text",
                                        createTime: t, parentId: userNode.id, childrenIds: [], conversationId: cid, profileId: pid)
            let conv = Conversation(id: cid, title: r.title, createTime: t, updateTime: t,
                                    currentNodeId: replyNode.id, provider: r.provider, profileId: pid)
            conv.ccBridgeSessionName = r.session
            conv.unreadCount = r.unread
            conv.nodeCount = 2
            conv.folderId = r.folder
            [userNode, replyNode].forEach(ctx.insert)
            ctx.insert(conv)
        }
        try? ctx.save()
        print("[PAGE0 seed] seeded \(rows.count) conv + 2 folders into \(pid)")
    }
}
#endif
