import Foundation
import SwiftData
#if os(iOS)
import UIKit
#endif

// MARK: - [Bunny patch BP-009] Caelum 的语音条：进后台不再卡在「生成中」
//
// 大肥兔修过（7f2c6c4df VoiceMessageWriter）：语音条合成中切走 App，iOS 几秒后冻结 / 回收进程，
// 收尾没跑 → 占位行「🎤 语音条生成中…」永久卡住。上游没有这层，这里补上：
//   1. 开始合成时申请后台执行时间（beginBackgroundTask），并把 nodeId + 脚本记进 UserDefaults；
//   2. 合成结束（成功或失败）清掉记录、归还后台时间；
//   3. App 回前台 / 回到桌面时扫记录：消息还挂着占位行、也不在合成中的，按楼层当前语音配置重新生成。

@MainActor
enum BunnyVoiceResume {
    private static let key = "bunny.voice.pending"   // [nodeId: script]
    static weak var profiles: ProfileManager?
    private static var observing = false
    #if os(iOS)
    private static var bgTasks: [String: UIBackgroundTaskIdentifier] = [:]
    #endif

    private static var pending: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func begin(nodeId: String, script: String) {
        var p = pending; p[nodeId] = script; pending = p
        #if os(iOS)
        if bgTasks[nodeId] == nil {
            bgTasks[nodeId] = UIApplication.shared.beginBackgroundTask(withName: "voice-note-\(nodeId.prefix(8))") {
                Task { @MainActor in BunnyVoiceResume.releaseBackgroundTask(nodeId) }
            }
        }
        #endif
    }

    static func end(nodeId: String) {
        var p = pending; p.removeValue(forKey: nodeId); pending = p
        releaseBackgroundTask(nodeId)
    }

    private static func releaseBackgroundTask(_ nodeId: String) {
        #if os(iOS)
        if let t = bgTasks.removeValue(forKey: nodeId), t != .invalid { UIApplication.shared.endBackgroundTask(t) }
        #endif
    }

    /// 桌面钩子里调：记住 ProfileManager、挂一次「回前台」监听，并立刻扫一遍
    static func attach(_ profiles: ProfileManager) {
        self.profiles = profiles
        if !observing {
            observing = true
            #if os(iOS)
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in BunnyVoiceResume.resumeIfNeeded() }
            }
            #endif
        }
        resumeIfNeeded()
    }

    static func resumeIfNeeded() {
        guard let profiles, !pending.isEmpty else { return }
        let context = profiles.container.mainContext
        for (nodeId, script) in pending {
            let nid = nodeId
            guard let node = (try? context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == nid })))?.first else {
                end(nodeId: nodeId); continue                                  // 消息没了
            }
            let stillWaiting = node.content.contains(VoiceMessageWriter.placeholderLine)
            guard stillWaiting else { end(nodeId: nodeId); continue }          // 已经生成或已标失败
            guard let profile = profiles.profiles.first(where: { $0.id == node.profileId }),
                  let setup = VoiceMessageWriter.voiceSetup(for: profile) else { continue }
            VoiceMessageWriter.generate(script: script, nodeId: nodeId, setup: setup,
                                        speaker: profile.assistantName, voiceName: profile.voiceName, context: context)
        }
    }
}
