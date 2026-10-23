import SwiftUI

#if os(iOS)
import UIKit
import UserNotifications

/// 远程推送（APNs）：请求授权（老用户启动时 / 新用户引导完成页）+ 注册 → 拿 device token 发给 hub。
/// hub 在「小克主动发消息/nudge 且你不在看」时经 APNs 推过来（即使 app 关着）。
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LaunchSplash.install(fromPush: launchOptions?[.remoteNotification] != nil)
        LaunchMarks.note(launchOptions?[.remoteNotification] != nil ? "launch.push" : application.applicationState == .background ? "launch.bg" : "launch.fg")   // 秒连尺子：启动来源
        // #042：锁屏来电要读的钥匙串条目改成「首次解锁后可读」；锁着冷启动改不了，等解锁回调补跑
        if application.isProtectedDataAvailable { KeychainStore.migrateAccessibility() }
        if Self.skipsAuthorization { return true }
        UNUserNotificationCenter.current().delegate = self
        NativeCallCoordinator.shared.configure()
        // 首启不弹：还没走完引导的，授权挪到引导完成页（OnboardingFlowView.doneStep）再请求。
        if UserDefaults.standard.bool(forKey: "onboardingCompletedV1") { Self.requestAuthorization() }
        return true
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        KeychainStore.migrateAccessibility()
    }

    /// 请求通知授权，同意后注册 APNs。已决定过的用户系统不会再弹，只回结果。
    static func requestAuthorization() {
        if skipsAuthorization { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    private static var skipsAuthorization: Bool {
        #if DEBUG
        // [PROBE 脚手架] 诊断模式跳过通知授权（新模拟器权限弹窗挡录屏/挡机器人 tap）
        if ProcessInfo.processInfo.arguments.contains("--pop-tuner-probe") { return true }
        #endif
        #if DEBUG || PERF_BENCH
        if UITestHooks.active { return true }
        #endif
        return false
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // 模拟器（Apple Silicon）也能拿到真 APNs token——不上报，推送只给真机。
        #if !targetEnvironment(simulator)
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        CCBridgeWebSocketClient.shared.sendPushToken(hex)
        #endif
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // 注册失败（模拟器/无网络等）——静默，下次启动重试。
    }

    /// 前台到达也弹横幅（小克主动找你，前台也该看到）。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// 点通知 → 记下 chat_id + 发通知请求打开对应会话（ContentView 消费）。
    /// 存 UserDefaults 兜冷启动（ContentView 还没监听时），发通知兜热启动（已在前台监听）。
    /// response-only 冷启动在此标记并立即撤罩；scene 配置交由 SwiftUI 管理。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        LaunchSplash.silenceForNotification()
        await MainActor.run { LaunchSplash.notificationLaunch() }
        guard let chatId = response.notification.request.content.userInfo["chat_id"] as? String else { return }
        UserDefaults.standard.set(chatId, forKey: "pendingPushChatId")
        await MainActor.run {
            NotificationCenter.default.post(name: .pushConversationRequested, object: nil)
        }
    }
}
#endif
