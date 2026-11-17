import Foundation

/// 电脑文件夹楼层（docs/plan-folder-floor.md P1）：一个普通楼层，多连了一台「文件夹模式」的电脑（`Profile.folderHubId`）。
/// 界面全用人楼层的。这里只放两样：连着的那几层的登记（后台线程也能问），和连 / 不连时楼层要跟着改什么。
enum FolderFloor {
    struct Link: Equatable {
        /// `CCHubRegistry` 里那台的 id
        var hubId: String
        /// 那台的 hub_id：恢复备份 / 换设备后本机的 id 对不上时，靠它认回来
        var hubIdentity: String?
        /// 这一层用电脑上的哪个账号；nil = 那台的默认账号
        var account: String?
    }

    private static let lock = NSLock()
    private static var links: [String: Link] = [:]

    /// 楼层列表读出来 / 变了之后调。只有 app 根上那一个 `ProfileManager`（`tracksFolderFloors: true`）会调——
    /// 导入预览、测试里另建的实例不碰这份登记，不然会被它们的列表整表冲掉（kimi P1 审 #6）
    static func refresh(_ profiles: [Profile]) {
        var next: [String: Link] = [:]
        for p in profiles where p.isFolderFloor {
            next[p.id] = Link(hubId: p.folderHubId ?? "", hubIdentity: p.folderHubIdentity, account: p.folderAccount)
        }
        lock.withLock { links = next }
    }

    static func link(_ profileId: String) -> Link? {
        lock.withLock { links[profileId] }
    }

    /// 这一层连着电脑文件夹。背后关掉的几样（记忆提取 / 自己醒来 / 对话同步 / 时间机器备份 / 全量导出）都问它
    static func isFolder(_ profileId: String) -> Bool {
        link(profileId) != nil
    }

    /// 发消息带哪个账号：对话在连着文件夹的楼层里、而且就是发给这一层连的那台才带；别的情况 nil（帧和原来一样）
    static func account(for conversation: Conversation) -> String? {
        account(link: link(conversation.profileId), conversationHubId: CCHubRegistry.hubId(of: conversation),
                conversationHubIdentity: conversation.ccHubIdentity)
    }

    /// 「就是这一层连的那台」：本机 id 相同，或者身份（hub_id）相同——恢复备份 / 换设备后那台在本机换了 id，
    /// 新对话按身份认回去了，账号也要照带（kimi P1 审 #7）。身份是空的不算相同：两台都没报身份的电脑不是同一台
    static func account(link: Link?, conversationHubId: String, conversationHubIdentity: String?) -> String? {
        guard let link else { return nil }
        let sameIdentity = !(link.hubIdentity ?? "").isEmpty && link.hubIdentity == conversationHubIdentity
        return link.hubId == conversationHubId || sameIdentity ? link.account : nil
    }

    /// 连上一台：记下电脑、它的身份和账号，这一层的模型换成 CC 卡（之后新开的对话就是 CC 对话，发给这台）。
    /// 账号传 nil 或不在那台报的名单里 = 用那台的默认账号（存 nil）
    static func linked(_ profile: Profile, hubId: String, hubIdentity: String?, account: String?, ccModelId: String) -> Profile {
        var p = profile
        p.folderHubId = hubId
        p.folderHubIdentity = hubIdentity
        p.folderAccount = account
        p.preferredModel = ccModelId
        return p
    }

    /// 不连了：三项清掉。模型还是 CC 卡的话回到「跟随全局默认」——留着的话新对话会发到主电脑的家里去，不是她要的
    static func unlinked(_ profile: Profile, ccModelId: String) -> Profile {
        var p = profile
        p.folderHubId = nil
        p.folderHubIdentity = nil
        p.folderAccount = nil
        if p.preferredModel == ccModelId { p.preferredModel = "" }
        return p
    }

    /// 新 CC 对话连哪台（`CCHubRegistry.bindNewCCConversation`）：这一层连着的那台还在 → 它；
    /// 本机 id 对不上了但有一台身份相同 → 那台；都没有 → 待绑定（不回落到别的电脑）。不是文件夹楼层 = nil，走原来的规则
    static func hubForNewConversation(profileId: String, exists: (String) -> Bool, idForIdentity: (String) -> String?, unbound: String) -> String? {
        guard let link = link(profileId) else { return nil }
        if exists(link.hubId) { return link.hubId }
        if let identity = link.hubIdentity, !identity.isEmpty, let id = idForIdentity(identity) { return id }
        return unbound
    }

    /// 选择页上一台电脑的样子
    enum HubChoice: Equatable {
        /// 连着文件夹，能选
        case folder(path: String)
        /// 连上了，但它连的是家，不是文件夹
        case notFolder
        /// 没连上（不知道它是不是）
        case offline
    }

    static func choice(connected: Bool, hello: HubHello?) -> HubChoice {
        guard connected, let hello else { return .offline }
        guard let folder = hello.folder else { return .notFolder }
        return .folder(path: folder.path)
    }

    /// 路径开头的家目录写成 `~`（只为了显示短一点）
    static func displayPath(_ path: String) -> String {
        guard let r = path.range(of: #"^/Users/[^/]+"#, options: .regularExpression) else { return path }
        return "~" + path[r.upperBound...]
    }
}

extension Profile {
    /// 这一层连着电脑文件夹（空串不算）。登记、备份、导出都用这一个判断
    var isFolderFloor: Bool { !(folderHubId ?? "").isEmpty }
}
