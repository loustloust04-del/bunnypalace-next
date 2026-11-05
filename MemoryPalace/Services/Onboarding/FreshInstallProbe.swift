import Foundation

// MARK: - 小芽引导 · 新装判定（plan-onboarding-xiaoya-impl §5.1）
// `onboarding.xiaoyaV1`：nil 未判定 / started 新装在走引导 / done 走完 / upgraded 老用户。启动只判一次，写了就不再判。
// 最大的坑（research §4）：用过 App 但没走完旧六页的老用户（onboardingCompletedV1 == false）绝不能被拉进新引导——
// 只认「什么都没有」的机器：楼层只有种子、没对话、没自建 API 卡、卡库空。

enum FreshInstallProbe {
    enum Decision: String {
        case started, upgraded
    }

    /// 启动时自动种 / 只播一次的 API 卡（Claude Code / Codex 桥、示例卡、本机模型、GPT OAuth），不算她建的
    static let autoCredentialIds: Set<String> = [
        "cc-bridge", "codex-bridge", APICredential.exampleId, APICredential.localId, "chatgpt-oauth",
    ]
    /// 首启种子楼层（对话空间）
    static let seedFloorIds: Set<String> = [Profile.seedProfiles[0].id]

    /// 纯函数。nil = 这次不判（楼层列表 / 卡库读坏、对话数读不出来），下次启动再判。
    /// 对话数是闭包：前面几条已经能定的（老用户绝大多数）不去碰库
    static func decide(profilesTrusted: Bool, legacyCompleted: Bool, profileIds: [String], credentialIds: [String],
                       cardIds: [String], cardsTrusted: Bool, conversationCount: () -> Int?) -> Decision? {
        // 卡库读坏时 cards 是空数组，不等于「卡库空」（sol #7）：不知道就不判
        guard profilesTrusted, cardsTrusted else { return nil }
        if legacyCompleted { return .upgraded }
        guard Set(profileIds).isSubset(of: seedFloorIds) else { return .upgraded }
        guard let empty = libraryLooksEmpty(credentialIds: credentialIds, cardIds: cardIds, cardsTrusted: cardsTrusted,
                                            conversationCount: conversationCount) else { return nil }
        return empty ? .started : .upgraded
    }

    /// 楼层列表以外的三样证据：没自建 API 卡、卡库空、没对话。nil = 不知道（卡库读坏 / 对话数读不出来）
    static func libraryLooksEmpty(credentialIds: [String], cardIds: [String], cardsTrusted: Bool,
                                  conversationCount: () -> Int?) -> Bool? {
        guard cardsTrusted else { return nil }
        guard Set(credentialIds).isSubset(of: autoCredentialIds),
              cardIds.allSatisfy({ $0 == CardSample.id }) else { return false }
        guard let count = conversationCount() else { return nil }
        return count == 0
    }

    /// 启动接线：判过（键有值）就什么都不做；判出来写进键并返回，交给 App 决定开不开剧本
    static func runOnce(defaults: UserDefaults, profilesTrusted: Bool, profileIds: [String], credentialIds: [String],
                        cardIds: [String], cardsTrusted: Bool, conversationCount: () -> Int?) -> Decision? {
        guard defaults.string(forKey: XiaoyaScriptRunner.onboardingKey) == nil,
              let decision = decide(profilesTrusted: profilesTrusted,
                                    legacyCompleted: defaults.bool(forKey: XiaoyaScriptRunner.legacyCompletedKey),
                                    profileIds: profileIds, credentialIds: credentialIds, cardIds: cardIds,
                                    cardsTrusted: cardsTrusted, conversationCount: conversationCount) else { return nil }
        defaults.set(decision.rawValue, forKey: XiaoyaScriptRunner.onboardingKey)
        return decision
    }
}

// MARK: - 推送授权时机（§5.2 / H11）
// 老用户（旧键真 / 判成 upgraded）和走完新引导的：启动就请求。新装正在走引导的：等剧本收尾（end / ghost）再请求。
// 还没判出来（列表读坏那次）的也先不弹，跟旧版「没走完引导不弹」一致。

enum PushGate {
    static func requestsAtLaunch(legacyCompleted: Bool, xiaoyaState: String?) -> Bool {
        legacyCompleted || xiaoyaState == "done" || xiaoyaState == FreshInstallProbe.Decision.upgraded.rawValue
    }

    static func requestsAtLaunch(_ defaults: UserDefaults) -> Bool {
        requestsAtLaunch(legacyCompleted: defaults.bool(forKey: XiaoyaScriptRunner.legacyCompletedKey),
                         xiaoyaState: defaults.string(forKey: XiaoyaScriptRunner.onboardingKey))
    }
}
