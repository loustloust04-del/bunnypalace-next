import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 被系统回收后回来不播开屏（plan-bg-keepalive §2.1）：进后台把离开时间写进 scene session，
/// 冷启动连上 scene 时读一次就清。她在多任务里划掉 app 时 session 被丢弃，标记跟着没了。
enum LaunchResumeMarker {
    static let key = "mp.resume.leftAt"
    /// Q1 A：离开 10 分钟内跳开屏
    static let window: TimeInterval = 600

    static func shouldSkipSplash(leftAt: Date?, now: Date, window: TimeInterval = window) -> Bool {
        guard let leftAt else { return false }
        let away = now.timeIntervalSince(leftAt)
        return away >= 0 && away <= window
    }

    static func record(_ info: inout [String: Any]?, at date: Date) {
        var updated = info ?? [:]
        updated[key] = date.timeIntervalSince1970
        info = updated
    }

    /// 读后即清：一个标记只跳一次
    static func take(_ info: inout [String: Any]?, now: Date) -> Bool {
        let raw = info?.removeValue(forKey: key) as? Double
        return shouldSkipSplash(leftAt: raw.map(Date.init(timeIntervalSince1970:)), now: now)
    }
}

/// 冷启动回到上次的页 / 对话（plan-bg-keepalive §2.2）的进程级状态
@MainActor
enum LastLocationResume {
    /// 一个进程只恢复一次：切楼层整树重建（.id(profileId)）不再来
    static var attempted = false
    /// atrium 点人切层时写目标 profileId：新树按 `ProfileResume` 落回那层上次的页 / 对话。
    /// 推送 / 来电 / 导入 / 小芽这些切层路径不写，走现状（page1 托底草稿）
    static var pendingProfileSwitch: String?
    /// 恢复到列表页时，挡掉「列表页上选中对话就翻回聊天页」那一次（只认恢复的那条对话）
    private static var holdListPage: String?
    /// 托底草稿要填回的字。输入条在分页子 HC 里拿不到 SceneStorage，装载这个草稿时取走
    private static var newChatText: (conversationId: String, text: String)?

    static func holdListPageOnce(for conversationId: String) { holdListPage = conversationId }

    /// 不管对不对得上都清掉：只吃一次
    static func takeListPageHold(for conversationId: String?) -> Bool {
        defer { holdListPage = nil }
        return holdListPage != nil && holdListPage == conversationId
    }

    /// 不管对不对得上都清掉：只吃一次
    static func takeProfileSwitch(to profileId: String) -> Bool {
        defer { pendingProfileSwitch = nil }
        return pendingProfileSwitch == profileId
    }

    static func putNewChatText(_ text: String, for conversationId: String) {
        newChatText = (conversationId, text)
    }

    static func takeNewChatText(for conversationId: String?) -> String? {
        guard let pending = newChatText, pending.conversationId == conversationId else { return nil }
        newChatText = nil
        return pending.text
    }
}

#if os(iOS)
extension LaunchResumeMarker {
    @MainActor private static var observers: [NSObjectProtocol] = []

    @MainActor static func startRecording() {
        guard observers.isEmpty else { return }
        // willResignActive 而不是 didEnterBackground：系统在进后台那一刻就存 session，晚于那一刻写的要等下一次进后台才进盘
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let now = Date()
                for scene in UIApplication.shared.connectedScenes { record(&scene.session.userInfo, at: now) }
            }
        })
        // 回到前台就作废：之后在前台崩了不算「被系统回收」。冷启动的 consume 在 scene 连接时已做完
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for scene in UIApplication.shared.connectedScenes { scene.session.userInfo?.removeValue(forKey: key) }
            }
        })
    }

    @MainActor static func consume(_ session: UISceneSession) -> Bool {
        take(&session.userInfo, now: Date())
    }
}

/// 挂在 ContentView 上：页号 / 当前对话变了就写 SceneStorage（草稿对话记空），同时按楼层写一份 `ProfileResume`。
/// 订阅放在这个 modifier 里，翻页不会让 ContentView.body 重算（iOSPage 只由 PageSync 读）。
struct LastLocationPersistence: ViewModifier {
    @Binding var page: Int
    @Binding var savedPage: Int
    @Binding var savedConversationId: String
    let viewModel: ConversationViewModel
    let profileId: String
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    func body(content: Content) -> some View {
        content
            .onChange(of: page) { _, newPage in
                savedPage = newPage
                recordForProfile(page: newPage, conversationId: currentConversationId)
            }
            .onChange(of: currentConversationId) { _, id in
                savedConversationId = id
                recordForProfile(page: page, conversationId: id)
            }
    }

    private var currentConversationId: String {
        viewModel.isDraftConversation ? "" : viewModel.selectedConversation?.id ?? ""
    }

    /// 切层时旧 VM 先被清空选中对话：那时 currentProfile 已是新层，旧树这次变化不能盖掉旧层的记录
    private func recordForProfile(page: Int, conversationId: String) {
        guard !profileId.isEmpty, profileManager?.currentProfile.id == profileId else { return }
        ProfileResume().save(.init(page: page, conversationId: conversationId), for: profileId)
    }
}
#endif
