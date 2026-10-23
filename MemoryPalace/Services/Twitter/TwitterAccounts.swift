import Foundation
import SwiftData

enum TwitterAccountsError: Error, Equatable {
    case emptyName
}

/// 一个楼层里的多个推特账号（粟粟 2026-09-24：要能切换账号）。
///
/// 每条推文带 `accountId`，时间线、主页、书签都只看**当前账号**。
/// 「当前」存在账号行的 `isActive` 上；一个都没标时按最早导入的那个算——
/// 多账号之前的老数据就是这个情况，不用迁移也能认出当前账号。
enum TwitterAccounts {

    static func all(profileId: String, context: ModelContext) -> [TwitterArchiveAccount] {
        (try? context.fetch(TwitterQueries.accounts(profileId: profileId))) ?? []
    }

    /// 当前账号。只在**我的号**里挑——AI 的号再早建也不会被当成当前账号。
    static func active(profileId: String, context: ModelContext) -> TwitterArchiveAccount? {
        let rows = userAccounts(profileId: profileId, context: context)
        return rows.first(where: \.isActive) ?? rows.first
    }

    /// 切到这个账号。同楼层其它账号的标记清掉，保证只有一个当前。
    static func activate(_ account: TwitterArchiveAccount, context: ModelContext) throws {
        guard account.ownerKind != ownerAI else { return }   // AI 的号不能被切成当前账号
        for row in userAccounts(profileId: account.profileId, context: context) {
            row.isActive = row.persistentModelID == account.persistentModelID
        }
        try context.save()
    }

    /// 新建一个空白账号（不导存档，只自己发推），并切过去。
    @discardableResult
    static func createLocal(displayName: String, screenName: String, profileId: String,
                            context: ModelContext) throws -> TwitterArchiveAccount {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TwitterAccountsError.emptyName }
        var handle = screenName.trimmingCharacters(in: .whitespacesAndNewlines)
        while handle.hasPrefix("@") { handle.removeFirst() }
        let acc = TwitterArchiveAccount(profileId: profileId, accountId: "local-" + UUID().uuidString,
                                        screenName: handle, displayName: name, sourceName: "新建")
        context.insert(acc)
        try activate(acc, context: context)
        return acc
    }

    /// 多账号之前的老推文 `accountId` 是空的：归给当前账号，不然切了账号筛选后它们就看不见了。
    /// 只查空 id 的行（有条件的 fetch），不全表扫。
    static func adoptOrphans(profileId: String, context: ModelContext) throws {
        guard let owner = active(profileId: profileId, context: context) else { return }
        let orphans = try context.fetch(FetchDescriptor<TweetEntry>(predicate: #Predicate {
            $0.profileId == profileId && $0.accountId == ""
        }))
        guard !orphans.isEmpty else { return }
        for t in orphans { t.accountId = owner.accountId }
        try context.save()
    }

    static let ownerUser = "user"
    static let ownerAI = "ai"

    /// 我的号（能切换、能当当前账号的）。
    static func userAccounts(profileId: String, context: ModelContext) -> [TwitterArchiveAccount] {
        all(profileId: profileId, context: context).filter { $0.ownerKind != ownerAI }
    }

    /// 楼层 AI 的号（可以不止一个——粟粟：「ai 也可以开很多号」）。
    static func aiAccounts(profileId: String, context: ModelContext) -> [TwitterArchiveAccount] {
        all(profileId: profileId, context: context).filter { $0.ownerKind == ownerAI }
    }

    /// 楼层 AI 的主号：没有就建，有就把名字、头像跟 AI 资料对齐。
    /// 新建时本楼层我的每个号都默认关注它——不然「关注」时间线里看不到 AI 说话。
    @discardableResult
    static func ensureAIAccount(name: String, avatarJPEG: Data?, profileId: String, context: ModelContext,
                                mediaDir: URL) throws -> TwitterArchiveAccount {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let acc: TwitterArchiveAccount
        if let existing = aiAccounts(profileId: profileId, context: context).first(where: \.syncsWithAIProfile) {
            acc = existing
            if !displayName.isEmpty { acc.displayName = displayName }
        } else {
            let suffix = UUID().uuidString.prefix(6).lowercased()
            acc = TwitterArchiveAccount(profileId: profileId, accountId: "ai-" + UUID().uuidString,
                                        screenName: "ai_\(suffix)",
                                        displayName: displayName.isEmpty ? "AI" : displayName,
                                        sourceName: "楼层 AI")
            acc.ownerKind = ownerAI
            acc.syncsWithAIProfile = true
            context.insert(acc)
            for me in userAccounts(profileId: profileId, context: context) {
                try TwitterFollows.follow(acc, by: me, context: context)
            }
        }
        if let avatarJPEG {
            // 头像没变就不重写文件（每次调工具都会走这里）
            let digest = String(avatarJPEG.count) + "-" + String(avatarJPEG.prefix(64).reduce(0) { ($0 &* 31) &+ Int($1) })
            if digest != acc.aiAvatarDigest {
                try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
                let fileName = "ai-avatar-\(UUID().uuidString).jpg"
                try avatarJPEG.write(to: mediaDir.appendingPathComponent(fileName), options: .atomic)
                acc.avatarFileName = fileName
                acc.aiAvatarDigest = digest
            }
        }
        try context.save()
        return acc
    }

    /// AI 自己另开一个号（不跟 AI 资料同步）。
    @discardableResult
    static func createAIAccount(displayName: String, screenName: String, profileId: String,
                                context: ModelContext) throws -> TwitterArchiveAccount {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TwitterAccountsError.emptyName }
        var handle = screenName.trimmingCharacters(in: .whitespacesAndNewlines)
        while handle.hasPrefix("@") { handle.removeFirst() }
        let acc = TwitterArchiveAccount(profileId: profileId, accountId: "ai-" + UUID().uuidString,
                                        screenName: handle, displayName: name, sourceName: "楼层 AI")
        acc.ownerKind = ownerAI
        context.insert(acc)
        try context.save()
        return acc
    }

    /// 当前账号的 id；楼层里还没有账号时是空串（发的推先挂空，建了账号后被 `adoptOrphans` 认领）。
    static func activeId(profileId: String, context: ModelContext) -> String {
        active(profileId: profileId, context: context)?.accountId ?? ""
    }
}
