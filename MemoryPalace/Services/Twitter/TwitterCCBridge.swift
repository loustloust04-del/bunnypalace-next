import Foundation
import SwiftData

/// 小克（ccrp，hub spawn 的常驻 CC）用本地推特（粟粟 2026-09-24「让 ccrp 也能连 twi」）。
///
/// 走 pocket 同款路子：CC 调 MCP 工具 `local_twitter` → mcp-server POST hub `/twitter/cmd`
/// → hub 发 `twitter_cmd` 帧给 app → 这里在对应楼层跑 `TwitterAITool` → 回 `twitter_result`。
/// 工具行为跟楼层 AI 在聊天里用的完全同一套，只是换了个入口。
///
/// 楼层：帧里带 `chat_id`（CC 会话 id）就用那个会话所在的楼层，不带就用 app 当前楼层。
/// AI 身份：该楼层的 assistantName / 头像（跟聊天路径一致：assistantAvatar ?? cover）。
enum TwitterCCBridge {
    static let commandType = "twitter_cmd"
    static let resultType = "twitter_result"

    @MainActor
    static func handle(_ frame: [String: Any], profiles: [Profile], currentProfileId: String,
                       context: ModelContext, mediaRoot: URL? = nil,
                       level: (String) -> PermissionLevel = { PermissionCenter.level(.twitter, profileId: $0) }) -> [String: Any] {
        let id = frame["id"] as? String ?? ""
        func reply(_ ok: Bool, _ text: String) -> [String: Any] {
            ["type": resultType, "id": id, "ok": ok, "result": text]
        }
        var profileId = currentProfileId
        if let chatId = frame["chat_id"] as? String, !chatId.isEmpty {
            let desc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == chatId })
            guard let conv = (try? context.fetch(desc))?.first else {
                return reply(false, "找不到 chat_id 对应的会话；不填 chat_id 就用 app 当前楼层")
            }
            profileId = conv.profileId
        }
        guard let profile = profiles.first(where: { $0.id == profileId }) else {
            return reply(false, "找不到楼层 \(profileId)")
        }
        // 先找楼层再查那一层的权限（atrium P3⑤0）；电脑那边没法弹卡问，「每次询问」按不允许（⑤a）
        switch level(profileId) {
        case .bypass:
            break
        case .askOnce:
            return reply(false, "这个人的推特权限是「每次询问」，电脑那边没法问，按不允许处理")
        case .notAllowed:
            // atrium P3⑥a：没装推特 App 挡住的，说清原因
            if let app = PermissionCenter.blockingApp(.twitter, profileId: profileId) {
                #if os(macOS)
                return reply(false, "\(profile.name) 的\(PermissionCenter.notInstalledLabel(app))（设置 → 右栏）")
                #else
                return reply(false, "\(profile.name) 的\(PermissionCenter.notInstalledLabel(app))（TA 的人页 › 权限）")
                #endif
            }
            #if os(macOS)
            return reply(false, "用户没允许 \(profile.name) 用推特（设置 → 权限 → 这一层）")
            #else
            return reply(false, "用户没允许 \(profile.name) 用推特（TA 的人页 › 权限）")
            #endif
        }

        let input = frame["input"] as? [String: Any] ?? [:]
        guard let data = try? JSONSerialization.data(withJSONObject: input),
              let json = String(data: data, encoding: .utf8) else {
            return reply(false, "参数不是 JSON object")
        }
        let r = TwitterAITool.execute(inputJSON: json, profileId: profileId, aiName: profile.assistantName,
                                      aiAvatar: profile.assistantAvatarData ?? profile.coverImageData,
                                      context: context, mediaRoot: mediaRoot)
        return reply(!r.isError, r.text)
    }
}
