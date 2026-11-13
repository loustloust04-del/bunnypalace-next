import Foundation
import SwiftData

// MARK: - [Bunny patch BP-007] 桌面出现时的兔兔钩子（唯一插入点：Page2HomeView 的 .task）
//
// 1. 老用户桌面补 Console 图标（只跑一次）
// 2. 后台同步：药品柜（≥60 秒一次）、经期与刻痕（≥10 分钟一次）、推特（≥30 分钟一次）。都需要先在 Console 设置里连上网关。

@MainActor
enum BunnyLaunchHooks {
    static func onHomeAppear(tools: RightPanelToolManager, profiles: ProfileManager?) {
        BunnyDesktopMigration.runIfNeeded(tools: tools)
        if let profiles { BunnyVoiceResume.attach(profiles) }   // Caelum 语音条：回前台续跑卡住的「生成中」
        guard let profiles, BunnyGateway.isConfigured else { return }
        let context = profiles.container.mainContext
        let pid = profiles.currentProfile.id
        Task { @MainActor in
            await BunnyMedsSync.runIfDue(context: context, profileId: pid)
            await BunnyCycleSync.runIfDue(context: context, profileId: pid)
            await BunnyIntimacySync.runIfDue(context: context, profileId: pid)
            _ = await BunnyTwitterSync.runIfDue(profileId: pid, context: context)
        }
    }
}
