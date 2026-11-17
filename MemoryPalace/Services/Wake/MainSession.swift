import Foundation
import SwiftData
import SwiftUI

extension Notification.Name {
    /// 自己醒来往某个对话里插了一条（object: 对话 id）：对话列表刷一下
    static let wakeDidDeliver = Notification.Name("wakeDidDeliver")
}

/// 对话列表那边的 mainsession（单独一个修饰器：侧栏 body 那条链再多一个 onReceive 编译器就类型检查不过来）：
/// - 常驻（粟粟 11-16「main 应该常驻」）：列表出现 / 切楼层时，这一层没有就马上建一条
/// - 收 `.wakeDidDeliver` 就刷列表
struct MainSessionListSupport: ViewModifier {
    let refresh: () -> Void
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .wakeDidDeliver)) { _ in refresh() }
            .task(id: profileManager?.currentProfile.id) { keep() }
    }

    private func keep() {
        guard let profileManager else { return }
        let before = profileManager.currentProfile.mainSessionId
        let main = MainSession.ensure(profileId: profileManager.currentProfile.id, profileManager: profileManager, context: modelContext)
        if main?.id != before { refresh() }
    }
}

/// 每层一条 mainsession（plan-floor-main-thread）：AI 自己醒来做的事默认发到这里，别的窗口靠〔状态〕知道（`WakeRecent`）。
/// 排在置顶对话上面（`pinnedAt` = 远未来，列表本来就按它倒序浮顶）、删不掉、取消不了置顶、改不了名；
/// 在它里面发 `/clear` = 存档换新：原来那条变普通对话（内容、记忆都在），新建一条空的顶上
@MainActor
enum MainSession {
    static let title = "main session"
    static let clearCommand = "/clear"
    /// 远未来：比任何真置顶时间都晚，永远排第一
    static let pinDate = Date.distantFuture

    /// 判定只看置顶时间（列表行、菜单里不用再查楼层）
    nonisolated static func isMain(_ conversation: Conversation) -> Bool {
        isMainPin(conversation.pinnedAt)
    }

    nonisolated static func isMainPin(_ pinnedAt: Date?) -> Bool {
        guard let pinnedAt else { return false }
        return pinnedAt.timeIntervalSinceReferenceDate > pinDate.timeIntervalSinceReferenceDate - 1
    }

    /// 拿这一层的 mainsession，没有（或在回收站里）就建一条。楼层列表只读（读坏了）时不建：存不下 id，每次启动都会多建一条
    @discardableResult
    static func ensure(profileId: String, profileManager: ProfileManager?, context: ModelContext) -> Conversation? {
        guard let profileManager, !profileManager.isReadOnly,
              var profile = profileManager.profiles.first(where: { $0.id == profileId }) else { return nil }
        if let id = profile.mainSessionId,
           let existing = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first,
           !existing.isTrashed {
            // 名字跟着改（11-17 前叫「mainsession」，粟粟要带空格）；改不了名，不会覆盖她起的
            if !isMain(existing) || existing.title != title { existing.pinnedAt = pinDate; existing.title = title; try? context.save() }
            return existing
        }
        let conversation = create(profileId: profileId, context: context)
        profile.mainSessionId = conversation.id
        do {
            try profileManager.updateProfileChecked(profile)
        } catch {
            // 楼层存不下 id：这条不留（不然下次又建一条，越积越多）
            context.delete(conversation)
            try? context.save()
            return nil
        }
        return conversation
    }

    /// `/clear`：只在 mainsession 里认。原来那条改成「main session · 到 M月d日」、取消置顶；新建空的接上。回新的那条
    @discardableResult
    static func clear(_ conversation: Conversation, profileManager: ProfileManager?, context: ModelContext, now: Date = Date()) -> Conversation? {
        guard isMain(conversation), let profileManager,
              var profile = profileManager.profiles.first(where: { $0.id == conversation.profileId }) else { return nil }
        conversation.pinnedAt = nil
        conversation.title = "\(title) · 到 \(archiveDay(now))"
        conversation.updateTime = now
        let fresh = create(profileId: conversation.profileId, context: context)
        profile.mainSessionId = fresh.id
        try? profileManager.updateProfileChecked(profile)
        return fresh
    }

    /// 没有行首图标的列表行（纯标题行、Mac 侧栏）用：前面带个小标；有图标的行图标直接换成星星
    nonisolated static func listTitle(_ conversation: Conversation) -> String {
        isMain(conversation) ? "✦ \(conversation.title)" : conversation.title
    }

    static func isClearCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == clearCommand
    }

    private static func create(profileId: String, context: ModelContext) -> Conversation {
        let rootId = UUID().uuidString
        let now = Date()
        let conversation = Conversation(id: UUID().uuidString, title: title, createTime: now, updateTime: now,
                                        currentNodeId: rootId, provider: "api", profileId: profileId)
        conversation.pinnedAt = pinDate
        context.insert(conversation)
        context.insert(MessageNode(id: rootId, role: "system", content: "", contentType: "text", createTime: now,
                                   parentId: nil, childrenIds: [], conversationId: conversation.id, profileId: profileId))
        try? context.save()
        return conversation
    }

    private static func archiveDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }
}
