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
                       enabled: Bool = PermissionCenter.capabilityEnabled(.twitter)) -> [String: Any] {
        let id = frame["id"] as? String ?? ""
        func reply(_ ok: Bool, _ text: String) -> [String: Any] {
            ["type": resultType, "id": id, "ok": ok, "result": text]
        }
        guard enabled else { return reply(false, "用户在设置-权限里关掉了推特工具") }

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
