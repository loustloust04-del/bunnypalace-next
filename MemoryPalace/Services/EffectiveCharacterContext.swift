import Foundation

/// 有效角色 / 身份上下文（卡库 ③b 轻量版，plan §3.5）：当前楼层的角色名 + 用户名（persona 名）。
/// 消息正文里的 `{{char}}` / `{{user}}` 只在显示副本（原生气泡 / Page2 DTO / 分支预览）和发送副本
///（PromptAssembler 的对话历史）里展开，存储原文不动；其它宏原样留着。
/// persona 描述照旧走 personaDescription 插槽（MacroExpander），名字两边同源、同一套空值默认。
struct EffectiveCharacterContext: Equatable {
    let charName: String
    let userName: String

    /// 空名退回和 MacroExpander 一致的默认：用户「你」、角色「助手」
    init(charName: String, userName: String) {
        self.charName = charName.isEmpty ? "助手" : charName
        self.userName = userName.isEmpty ? "你" : userName
    }

    /// 楼层版：`{{user}}` 取 Profile.userName，空了退回 @AppStorage("userName")，再空「你」
    init(profile: Profile, defaults: UserDefaults = .standard) {
        let user = profile.userName.isEmpty ? (defaults.string(forKey: "userName") ?? "") : profile.userName
        self.init(charName: profile.assistantName, userName: user)
    }

    func expand(_ text: String) -> String {
        Self.expandNames(text, charName: charName, userName: userName)
    }

    /// 纯函数：一遍扫完只换 `{{char}}` / `{{user}}`（大小写不敏感，酒馆卡常写 `{{Char}}`），
    /// 换进去的名字不再二次展开；没有 `{{` 直接原样返回（气泡每次 body 都会过这里）。
    static func expandNames(_ text: String, charName: String, userName: String) -> String {
        guard text.contains("{{") else { return text }
        var out = ""
        var rest = text[...]
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            if let close = after.range(of: "}}") {
                let inner = after[..<close.lowerBound]
                if inner.utf8.count == 4 {
                    switch inner.lowercased() {
                    case "char": out += charName; rest = after[close.upperBound...]; continue
                    case "user": out += userName; rest = after[close.upperBound...]; continue
                    default: break
                    }
                }
            }
            out += "{{"
            rest = after
        }
        out += rest
        return out
    }
}

/// 卡库 ③-4 有效身份（plan §1.1 UserPersonaStore 行 / §3.5）：对话 personaId → 楼层 personaId → 楼层原有身份文本。
/// 指定了但身份库里找不到的那一级退回下一级，原因进 notes（检查器显示）。不改楼层原有身份文本的存储。
struct PersonaResolution: Equatable {
    enum Level: Equatable { case conversation, floor, floorText }

    let level: Level
    let persona: UserPersona?
    let notes: [String]

    static func resolve(conversationPersonaId: String?, floorPersonaId: String?, personas: [UserPersona]) -> PersonaResolution {
        var notes: [String] = []
        if let id = conversationPersonaId, !id.isEmpty {
            if let persona = personas.first(where: { $0.id == id }) { return .init(level: .conversation, persona: persona, notes: notes) }
            notes.append("这个对话指定的身份找不到了（\(id.prefix(8))），退回楼层的")
        }
        if let id = floorPersonaId, !id.isEmpty {
            if let persona = personas.first(where: { $0.id == id }) { return .init(level: .floor, persona: persona, notes: notes) }
            notes.append("楼层指定的身份找不到了（\(id.prefix(8))），退回楼层原本的身份")
        }
        return .init(level: .floorText, persona: nil, notes: notes)
    }

    /// 有效身份套到楼层副本上：`{{user}}` 名字（身份没名字就沿用楼层的）和身份描述（personaDescription 插槽原位）换成身份的
    func applied(to profile: Profile) -> Profile {
        guard let persona else { return profile }
        var copy = profile
        if !persona.name.isEmpty { copy.userName = persona.name }
        copy.userPersona = persona.description
        return copy
    }

    /// 显示用名字：有身份且有名字才覆盖，否则 nil（沿用楼层的）
    var displayUserName: String? {
        guard let name = persona?.name, !name.isEmpty else { return nil }
        return name
    }

    /// 检查器一行：用的哪个身份、从哪一级来
    var summary: String {
        guard let persona else { return "身份：楼层原本的身份" }
        let name = persona.name.isEmpty ? "（没名字，沿用楼层的名字）" : persona.name
        return "身份：\(name)（\(level == .conversation ? "这个对话指定" : "楼层指定")）"
    }
}
