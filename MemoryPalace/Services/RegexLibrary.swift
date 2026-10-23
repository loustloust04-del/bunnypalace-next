import Foundation

/// 一条规则归谁管（卡库 ⑤b 正则页）：写回时按 owner 落到各自存储，不改存储格式
enum RegexRuleOwner: Hashable {
    case global
    case preset(id: String)
    case card(id: String)
    case profile(id: String)
}

/// 正则页的一组：全局 / 当前楼层预设 / 当前楼层绑定卡（没绑卡时是楼层旧规则）
struct RegexLibraryGroup: Identifiable, Equatable {
    let owner: RegexRuleOwner
    /// 组标题里来源后面那段：预设名 / 卡名 / 楼层名；全局为 nil
    let ownerName: String?
    let rules: [RegexScript]
    /// 只有角色卡组有：许可状态（unknown / deferred = 卡规则整组不执行）
    let consent: CharacterCard.ExtensionConsent?

    var id: RegexRuleOwner { owner }

    var sourceLabel: String {
        switch owner {
        case .global: "全局"
        case .preset: "预设"
        case .card: "角色卡"
        case .profile: "楼层"
        }
    }

    var title: String {
        ([sourceLabel] + (ownerName.map { [$0] } ?? []) + ["\(rules.count) 条"]).joined(separator: " · ")
    }

    var cardAllowed: Bool { consent == nil || consent == .allowed }
}

/// 正则页 / 编辑页的纯逻辑（阶段 ↔ 旧 flags、深度 ↔ maxDepth、不执行的 placement、测试区同引擎）
enum RegexLibrary {
    /// 保存但不会执行的 placement：0 酒馆废弃 MD_DISPLAY、3 命令、4 legacy sendAs、6 推理
    static let unsupportedPlacements: Set<Int> = [0, 3, 4, 6]

    static func hasUnsupportedPlacement(_ script: RegexScript) -> Bool {
        script.placement.contains { unsupportedPlacements.contains($0) }
    }

    /// 和 RegexPipeline.resolve 同一判定：楼层当前有效绑定的卡
    static func boundCard(profile: Profile, cards: [CharacterCard]) -> CharacterCard? {
        cards.first { $0.linkedProfileId == profile.id && $0.bindingState == .active }
    }

    /// 顺序与执行链一致：全局 → 当前楼层预设 → 绑定卡（没绑卡时楼层旧规则）
    static func groups(global: [RegexScript], profile: Profile, preset: Preset?, cards: [CharacterCard]) -> [RegexLibraryGroup] {
        var result = [RegexLibraryGroup(owner: .global, ownerName: nil, rules: global, consent: nil)]
        if let preset {
            result.append(RegexLibraryGroup(owner: .preset(id: preset.id), ownerName: preset.name, rules: preset.regexScripts, consent: nil))
        }
        if let card = boundCard(profile: profile, cards: cards) {
            result.append(RegexLibraryGroup(owner: .card(id: card.id), ownerName: card.name, rules: card.regexScripts, consent: card.extensionConsent))
        } else {
            result.append(RegexLibraryGroup(owner: .profile(id: profile.id), ownerName: profile.name, rules: profile.regexScripts, consent: nil))
        }
        return result
    }

    // MARK: 阶段 ↔ 旧 flags

    enum PhaseChoiceError: Error, Equatable {
        case empty
        case unsupported

        var message: String {
            switch self {
            case .empty: "至少打开一个阶段"
            case .unsupported: "这个组合暂时不支持"
            }
        }
    }

    /// 显示 = markdownOnly，发送 = promptOnly，输入 = 两者都 false；显示 + 发送 = 两者都 true（酒馆原义）。
    /// 旧 flags 表达不了的组合（带「输入」的混合）不改存储格式，直接拒
    static func flags(for phases: Set<RegexPhase>) -> Result<(markdownOnly: Bool, promptOnly: Bool), PhaseChoiceError> {
        switch phases {
        case []: .failure(.empty)
        case [.display]: .success((true, false))
        case [.send]: .success((false, true))
        case [.input]: .success((false, false))
        case [.display, .send]: .success((true, true))
        default: .failure(.unsupported)
        }
    }

    // MARK: 深度 ↔ maxDepth

    /// 「只改最近 N 条」：N = maxDepth + 1；没设 / 负数 = 不限（nil）
    static func recentCount(maxDepth: Int?) -> Int? {
        guard let maxDepth, maxDepth >= 0 else { return nil }
        return maxDepth + 1
    }

    /// 最近 N 条 = 深度 0…N−1；空 / 0 = 不限
    static func maxDepth(recentCount: Int?) -> Int? {
        guard let recentCount, recentCount > 0 else { return nil }
        return recentCount - 1
    }

    // MARK: 测试区

    /// 按规则自己的阶段跑一遍生产执行链（RegexPipeline.run → RegexEngine.apply），规则关着也照试；
    /// placement 不含所选消息类型时原样返回
    static func preview(_ script: RegexScript, text: String, placement: Int, userName: String = "", charName: String = "") -> String {
        var trial = script
        trial.disabled = false
        let phases = trial.phases
        let phase: RegexPhase = phases.contains(.display) ? .display : (phases.contains(.send) ? .send : .input)
        return RegexPipeline.run([trial], text: text, phase: phase, placement: placement, userName: userName, charName: charName)
    }
}

// MARK: - 写回 owner

/// 规则写回所属 owner：全局 → GlobalRegexStore；预设 → 楼层预设实例（PresetManager.save）；
/// 卡 → 卡库（粟粟自己改的，不重置许可）；楼层旧规则 → ProfileManager
struct RegexOwnerStore {
    enum Failure: LocalizedError {
        case ownerMissing

        var errorDescription: String? { "这条规则所属的预设 / 卡 / 楼层已经不在了" }
    }

    let global: GlobalRegexStore
    let presets: PresetManager
    let cards: CharacterCardManager
    let profiles: ProfileManager

    func rules(of owner: RegexRuleOwner) -> [RegexScript]? {
        switch owner {
        case .global: global.scripts
        case .preset(let id): presets.preset(byId: id)?.regexScripts
        case .card(let id): cards.cards.first { $0.id == id }?.regexScripts
        case .profile(let id): profiles.profiles.first { $0.id == id }?.regexScripts
        }
    }

    func replaceRules(_ rules: [RegexScript], of owner: RegexRuleOwner) throws {
        switch owner {
        case .global:
            try global.save(rules)
        case .preset(let id):
            guard var preset = presets.preset(byId: id) else { throw Failure.ownerMissing }
            preset.regexScripts = rules
            presets.save(preset)
        case .card(let id):
            guard var card = cards.cards.first(where: { $0.id == id }) else { throw Failure.ownerMissing }
            card.regexScripts = rules
            try cards.update(card, resetsConsent: false)
        case .profile(let id):
            guard var profile = profiles.profiles.first(where: { $0.id == id }) else { throw Failure.ownerMissing }
            profile.regexScripts = rules
            profiles.updateProfile(profile)
        }
    }

    /// 同 id 原位替换，没有就追加到末尾
    func upsert(_ rule: RegexScript, in owner: RegexRuleOwner) throws {
        guard var rules = rules(of: owner) else { throw Failure.ownerMissing }
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        try replaceRules(rules, of: owner)
    }

    func delete(ruleId: String, in owner: RegexRuleOwner) throws {
        guard var rules = rules(of: owner) else { throw Failure.ownerMissing }
        guard let index = rules.firstIndex(where: { $0.id == ruleId }) else { return }
        rules.remove(at: index)
        try replaceRules(rules, of: owner)
    }

    /// 开关写回规则自身 disabled（和卡许可是两回事）
    func setEnabled(_ enabled: Bool, ruleId: String, in owner: RegexRuleOwner) throws {
        guard var rules = rules(of: owner), let index = rules.firstIndex(where: { $0.id == ruleId }) else { throw Failure.ownerMissing }
        rules[index].disabled = !enabled
        try replaceRules(rules, of: owner)
    }

    /// 整张卡的正则许可：启用 = allowed，停用 = deferred
    func setConsent(_ consent: CharacterCard.ExtensionConsent, cardId: String) throws {
        guard var card = cards.cards.first(where: { $0.id == cardId }) else { throw Failure.ownerMissing }
        card.extensionConsent = consent
        try cards.update(card)
    }
}
