import Foundation

// MARK: - 小芽 v2 · 带类型的改动（plan-小芽-v2 §4.1 v1.1，astra A2/B1/B3）
// 提案里存的就是这个：目标锚（楼层 / 预设 / 书 / 卡 id）+ 完整改前值 + 改后值。
// 盖章时核「现在 == 改前」才落地；撤销时核「现在 == 改后」，不等就要人确认覆盖。
// 卡片上的新旧对照也从它算，不另存展示文案。

struct SamplingChange: Codable, Equatable {
    var key: String      // temperature / topP / maxTokens / contextDepth
    var before: Double
    var after: Double
}

enum AssistantChange: Codable, Equatable {
    /// 卡 id 在提案时就定好，撤销按 id 删
    case createCharacter(card: CharacterCard)
    case updateCharacterField(cardId: String, cardName: String, field: String, before: String, after: String)
    /// newInstanceId 盖章后才有（回执里填上）
    case createPreset(profileId: String, templateId: String, templateName: String, name: String,
                      previousPresetId: String, newInstanceId: String?)
    case updatePresetSlot(profileId: String, presetId: String, slotId: String, slotName: String, before: String, after: String)
    case updatePresetSampling(profileId: String, presetId: String, presetName: String, changes: [SamplingChange])
    /// 条目 id 在提案时就定好
    case addWorldBookEntry(profileId: String, bookId: String, bookName: String, entry: WorldBookEntry)
    /// after = before 套上改动字段；没传的字段（如备注）天然不动
    case updateWorldBookEntry(profileId: String, bookId: String, bookName: String, before: WorldBookEntry, after: WorldBookEntry)
    case deleteWorldBookEntry(profileId: String, bookId: String, bookName: String, entry: WorldBookEntry, index: Int)
    /// P3 外观：只存要改的那几项；before = 提案时这几项的值
    case page2Appearance(before: Page2AppearancePatch, after: Page2AppearancePatch)
    /// before = nil 表示原来没自定义（撤销时删掉这一项、回到默认图标）
    case appIcon(toolId: String, toolName: String, before: Page2IconOverride?, after: Page2IconOverride)
    case stageTheme(before: String, after: String)

    var kind: AssistantAction.Kind {
        switch self {
        case .createCharacter: .createCharacter
        case .updateCharacterField: .updateCharacterField
        case .createPreset: .createPreset
        case .updatePresetSlot: .updatePresetSlot
        case .updatePresetSampling: .updatePresetSampling
        case .addWorldBookEntry: .addWorldBookEntry
        case .updateWorldBookEntry: .updateWorldBookEntry
        case .deleteWorldBookEntry: .deleteWorldBookEntry
        case .page2Appearance: .page2Appearance
        case .appIcon: .appIcon
        case .stageTheme: .stageTheme
        }
    }

    /// 楼层锚；卡库是全局的，没有
    var profileId: String? {
        switch self {
        case .createCharacter, .updateCharacterField, .page2Appearance, .appIcon, .stageTheme: nil
        case .createPreset(let p, _, _, _, _, _), .updatePresetSlot(let p, _, _, _, _, _),
             .updatePresetSampling(let p, _, _, _), .addWorldBookEntry(let p, _, _, _),
             .updateWorldBookEntry(let p, _, _, _, _), .deleteWorldBookEntry(let p, _, _, _, _):
            p
        }
    }

    var tier: AssistantAction.Tier {
        if case .deleteWorldBookEntry = self { return .destructive }
        return .reversible
    }
}

// MARK: - 展示

struct AssistantDiffField: Equatable, Identifiable {
    var id: String { label }
    var label: String
    var old: String?
    var new: String?
}

extension AssistantChange {
    var category: String {
        switch self {
        case .createCharacter: "卡库 · 新建"
        case .updateCharacterField: "卡库 · 改字段"
        case .createPreset: "预设 · 新建副本"
        case .updatePresetSlot: "预设 · 改插槽"
        case .updatePresetSampling: "预设 · 采样参数"
        case .addWorldBookEntry: "世界书 · 加条目"
        case .updateWorldBookEntry: "世界书 · 改条目"
        case .deleteWorldBookEntry: "世界书 · 删条目"
        case .page2Appearance: "外观 · 主屏"
        case .appIcon: "外观 · 图标"
        case .stageTheme: "外观 · 舞台"
        }
    }

    var title: String {
        switch self {
        case .createCharacter(let c): "「\(c.name)」"
        case .updateCharacterField(_, let name, let field, _, _): "「\(name)」的 \(Self.characterFieldLabel(field))"
        case .createPreset(_, _, let tpl, let name, _, _): "以「\(tpl)」为底新建「\(name)」"
        case .updatePresetSlot(_, _, _, let slot, _, _): "插槽「\(slot)」"
        case .updatePresetSampling(_, _, let name, _): "「\(name)」"
        case .addWorldBookEntry(_, _, let book, let e): "「\(book)」· \(Self.entryName(e))"
        case .updateWorldBookEntry(_, _, let book, let before, _): "「\(book)」· \(Self.entryName(before))"
        case .deleteWorldBookEntry(_, _, let book, let e, _): "「\(book)」· \(Self.entryName(e))"
        case .page2Appearance: "换个主屏样子"
        case .appIcon(_, let name, _, _): "「\(name)」的图标"
        case .stageTheme(_, let after): "换成「\(XiaoyaStageTheme(rawValue: after)?.title ?? after)」"
        }
    }

    var fields: [AssistantDiffField] {
        switch self {
        case .createCharacter(let c):
            return [("人设", c.description), ("性格", c.personality), ("场景", c.scenario), ("开场白", c.firstMes)]
                .filter { !$0.1.isEmpty }
                .map { AssistantDiffField(label: $0.0, old: nil, new: $0.1) }
        case .updateCharacterField(_, _, let field, let before, let after):
            return [AssistantDiffField(label: Self.characterFieldLabel(field), old: before, new: after)]
        case .createPreset:
            return [AssistantDiffField(label: "效果", old: nil, new: "当前楼层换成这份新副本（原预设不动）")]
        case .updatePresetSlot(_, _, _, _, let before, let after):
            return [AssistantDiffField(label: "内容", old: before, new: after)]
        case .updatePresetSampling(_, _, _, let changes):
            return changes.map { AssistantDiffField(label: $0.key, old: Self.number($0.before), new: Self.number($0.after)) }
        case .addWorldBookEntry(_, _, _, let e):
            var out = [AssistantDiffField(label: "关键词", old: nil, new: e.keys.joined(separator: ", ")),
                       AssistantDiffField(label: "内容", old: nil, new: e.content)]
            if !e.comment.isEmpty { out.append(AssistantDiffField(label: "备注", old: nil, new: e.comment)) }
            return out
        case .updateWorldBookEntry(_, _, _, let before, let after):
            var out: [AssistantDiffField] = []
            if before.keys != after.keys {
                out.append(AssistantDiffField(label: "关键词", old: before.keys.joined(separator: ", "), new: after.keys.joined(separator: ", ")))
            }
            if before.content != after.content { out.append(AssistantDiffField(label: "内容", old: before.content, new: after.content)) }
            if before.comment != after.comment { out.append(AssistantDiffField(label: "备注", old: before.comment, new: after.comment)) }
            return out
        case .deleteWorldBookEntry(_, _, _, let e, _):
            return [AssistantDiffField(label: "关键词", old: e.keys.joined(separator: ", "), new: nil),
                    AssistantDiffField(label: "内容", old: e.content, new: nil)]
        case .page2Appearance(let before, let after):
            return after.describe(against: before)
        case .appIcon(_, _, let before, let after):
            func text(_ o: Page2IconOverride?) -> String {
                guard let o else { return "默认" }
                if o.imageFile != nil { return "自己的图片" }
                return "\(o.symbol ?? "原符号") · \(Page2IconChoices.tints[o.tint] ?? o.tint)"
            }
            return [AssistantDiffField(label: "图标", old: text(before), new: text(after))]
        case .stageTheme(let before, let after):
            return [AssistantDiffField(label: "舞台", old: XiaoyaStageTheme(rawValue: before)?.title ?? before,
                                       new: XiaoyaStageTheme(rawValue: after)?.title ?? after)]
        }
    }

    static func characterFieldLabel(_ field: String) -> String {
        switch field {
        case "description": "人设"
        case "personality": "性格"
        case "scenario": "场景"
        case "firstMes": "开场白"
        case "mesExample": "对话示例"
        case "systemPrompt": "系统提示"
        case "postHistoryInstructions": "历史后指令"
        default: field
        }
    }

    private static func entryName(_ e: WorldBookEntry) -> String {
        if !e.comment.isEmpty { return "「\(e.comment)」" }
        return e.keys.first.map { "「\($0)」" } ?? "条目"
    }

    static func number(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(v)
    }
}
