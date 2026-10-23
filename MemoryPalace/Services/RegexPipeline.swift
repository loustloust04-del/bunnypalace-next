import Foundation

/// 正则跑在哪个阶段（卡库 ⑤a，plan §4.2）。与 placement（作用于谁）是两回事。
/// 旧规则没有阶段字段，按酒馆两个旧 flag 推导（不改存储）：
/// markdownOnly → 显示，promptOnly → 发送，两者都 false → 输入（普通）。
enum RegexPhase: Hashable {
    case display
    case send
    case input
}

extension RegexScript {
    var phases: Set<RegexPhase> {
        guard markdownOnly || promptOnly else { return [.input] }
        var result: Set<RegexPhase> = []
        if markdownOnly { result.insert(.display) }
        if promptOnly { result.insert(.send) }
        return result
    }
}

/// 解析后的一条有效规则：来源 + owner + 规则 id 组成复合 id，同一条不重复叠加
struct ResolvedRegexRule: Equatable {
    enum Source: String {
        case global
        case preset
        case card
        case profile
    }

    let source: Source
    let ownerId: String
    let script: RegexScript

    var compositeId: String { "\(source.rawValue):\(ownerId):\(script.id)" }
}

/// 三源 × 三阶段的正则执行链。
/// - 来源顺序（对齐酒馆 engine.js SCRIPT_TYPES）：全局 → 当前楼层预设实例 → 当前楼层绑定卡；
///   楼层没绑定卡时用楼层 Profile 上的旧规则（旧直导卡写进去的），绑定了就不再叠加。
/// - 卡规则只有 `extensionConsent == .allowed` 才生效；unknown / deferred 视为关闭，但不改规则自身 disabled。
/// - placement 只执行 1 用户 / 2 AI / 5 世界书；3 命令、6 推理保存但不执行。
enum RegexPipeline {
    static let userPlacement = 1
    static let assistantPlacement = 2
    static let worldInfoPlacement = 5

    /// 发送 / 入库路径拿不到 SwiftUI 环境：App 启动时挂上卡库（弱引用），VM 按当前楼层取绑定卡
    static weak var liveCards: CharacterCardManager?

    static func resolve(global: [RegexScript] = [], profile: Profile, preset: Preset?, cards: [CharacterCard]) -> [ResolvedRegexRule] {
        var rules = global.map { ResolvedRegexRule(source: .global, ownerId: "global", script: $0) }
        if let preset {
            rules += preset.regexScripts.map { ResolvedRegexRule(source: .preset, ownerId: preset.id, script: $0) }
        }
        if let card = cards.first(where: { $0.linkedProfileId == profile.id && $0.bindingState == .active }) {
            if card.extensionConsent == .allowed {
                rules += card.regexScripts.map { ResolvedRegexRule(source: .card, ownerId: card.id, script: $0) }
            }
        } else {
            rules += profile.regexScripts.map { ResolvedRegexRule(source: .profile, ownerId: profile.id, script: $0) }
        }
        var seen = Set<String>()
        return rules.filter { seen.insert($0.compositeId).inserted }
    }

    /// 显示 / 发送 / 输入共用的有效规则（按顺序）；全局来源 = GlobalRegexStore（⑤b）
    static func scripts(profile: Profile, preset: Preset?, cards: [CharacterCard],
                        global: [RegexScript] = GlobalRegexStore.shared.scripts) -> [RegexScript] {
        resolve(global: global, profile: profile, preset: preset, cards: cards).map(\.script)
    }

    /// 消息角色 → placement；system / tool 等不冒充 assistant，返回 nil = 不跑
    static func placement(forRole role: String) -> Int? {
        switch role {
        case "user": return userPlacement
        case "assistant": return assistantPlacement
        default: return nil
        }
    }

    /// 本阶段本 placement 该跑的规则（保序）。旧 min/maxDepth 只作用于发送阶段；编辑只跑 runOnEdit
    static func eligible(_ scripts: [RegexScript], phase: RegexPhase, placement: Int, depth: Int? = nil, isEdit: Bool = false) -> [RegexScript] {
        scripts.filter { script in
            guard !script.disabled, script.phases.contains(phase), script.placement.contains(placement) else { return false }
            if phase == .input && isEdit && !script.runOnEdit { return false }
            if phase == .send, let depth {
                if let min = script.minDepth, min >= 0, depth < min { return false }
                if let max = script.maxDepth, max >= 0, depth > max { return false }
            }
            return true
        }
    }

    /// 对一段文本跑一个阶段。没有该跑的规则时原样返回（不做任何宏展开）
    static func run(
        _ scripts: [RegexScript],
        text: String,
        phase: RegexPhase,
        placement: Int?,
        depth: Int? = nil,
        isEdit: Bool = false,
        userName: String = "",
        charName: String = ""
    ) -> String {
        guard let placement, !scripts.isEmpty else { return text }
        let active = eligible(scripts, phase: phase, placement: placement, depth: depth, isEdit: isEdit)
        guard !active.isEmpty else { return text }
        return RegexEngine.apply(
            scripts: active, text: text, messagePlacement: placement,
            isMarkdown: phase == .display, isPrompt: phase == .send,
            depth: phase == .send ? depth : 0,
            userName: userName, charName: charName)
    }

    /// 发送阶段的历史副本：宏展开后按消息深度（最新 = 0）跑发送规则；user / assistant 各按自己的 placement
    static func sendHistory(_ history: [(role: String, content: String)], scripts: [RegexScript], names: EffectiveCharacterContext) -> [(role: String, content: String)] {
        history.enumerated().map { index, message in
            let expanded = names.expand(message.content)
            let content = run(scripts, text: expanded, phase: .send, placement: placement(forRole: message.role),
                              depth: history.count - 1 - index, userName: names.userName, charName: names.charName)
            return (role: message.role, content: content)
        }
    }
}
