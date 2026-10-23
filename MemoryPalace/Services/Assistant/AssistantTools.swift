import Foundation
import SwiftData

// MARK: - 小芽助手 · 工具包（plan-小芽助手.md §4.3）
// 读工具立即执行返回数据；写工具（propose_*）只生成带类型改动的 AssistantAction 提案，
// 由面板卡片经人盖章后走 AssistantStamp 落地。执行器全程不做任何写操作。
// v2（plan-小芽-v2 §4.5）：每个工具属于一个权限包，关掉的包连定义都不发，执行层再拦一次。

struct AssistantEnv {
    let profileManager: ProfileManager
    let presetManager: PresetManager
    let cardManager: CharacterCardManager
    let providerManager: ProviderManager
    let modelContext: ModelContext

    var profileId: String { profileManager.currentProfile.id }
}

struct AssistantToolOutcome {
    let resultText: String
    let isError: Bool
    var action: AssistantAction? = nil
    /// 模型调了不存在 / 没开放的工具（舞台切 Nope）
    var refused = false
}

enum AssistantTools {

    // MARK: - 工具定义（OpenAI tool calling 格式）

    /// 按权限包过滤后的定义（关掉的包，模型根本看不见那些工具）
    static var definitions: [[String: Any]] {
        allDefinitions.filter { def in
            guard let name = (def["function"] as? [String: Any])?["name"] as? String,
                  let pack = XiaoyaPack.of(tool: name) else { return false }
            return XiaoyaPackPolicy.isEnabled(pack)
        }
    }

    /// 本机模型只挂用得上的那组工具（plan-小芽-v3 §5）：15 个工具的定义约 2000 token，是手机上慢的大头。
    /// 按她这句 + 小芽上一句里的关键词挑，挑不出再看她在哪页，都没有就全挂——宁可慢，不能少了该用的工具
    static func localSubset(for text: String, page: String) -> [[String: Any]] {
        let groups = localGroups.filter { group in group.keywords.contains { text.localizedCaseInsensitiveContains($0) } }
        let chosen = groups.isEmpty ? localGroups.filter { !page.isEmpty && $0.page == page } : groups
        guard !chosen.isEmpty else { return definitions }
        let names = Set(chosen.flatMap(\.tools))
        return definitions.filter { names.contains(toolName($0)) }
    }

    /// 本机那份定义：提案工具补一句「细节自己编」——小模型爱反问，不补 1.7B 只有 4/6 会真交（云端不加，大模型该问就问）
    static func localDefinitions(for text: String, page: String) -> [[String: Any]] {
        localSubset(for: text, page: page).map { def in
            guard toolName(def).hasPrefix("propose_"), var function = def["function"] as? [String: Any],
                  let description = function["description"] as? String else { return def }
            function["description"] = description + "用户没给的细节你自己编好填上，不要反问用户。"
            var patched = def
            patched["function"] = function
            return patched
        }
    }

    private struct LocalGroup {
        let tools: [String]
        let keywords: [String]
        var page: String = ""
    }

    private static let localGroups: [LocalGroup] = [
        LocalGroup(tools: ["read_character", "propose_create_character", "propose_update_character_field"],
                   keywords: ["角色", "人设", "开场白", "卡库"], page: "cardLibrary"),
        LocalGroup(tools: ["list_world_books", "read_world_book", "propose_add_worldbook_entry",
                           "propose_update_worldbook_entry", "propose_delete_worldbook_entry"],
                   keywords: ["世界书", "条目", "设定"], page: "worldBook"),
        LocalGroup(tools: ["read_current_preset", "propose_update_preset_slot", "propose_update_preset_sampling", "propose_create_preset"],
                   keywords: ["预设", "插槽", "采样", "温度", "prompt", "提示词"], page: "preset"),
        LocalGroup(tools: ["query_memories"], keywords: ["记得", "记忆", "记住"], page: "memory"),
        LocalGroup(tools: ["read_appearance", "propose_stage_theme", "propose_page2_appearance", "propose_app_icon"],
                   keywords: ["外观", "主屏", "壁纸", "图标", "舞台", "主题", "深色", "暗色", "亮色", "好看"]),
    ]

    private static func toolName(_ def: [String: Any]) -> String {
        (def["function"] as? [String: Any])?["name"] as? String ?? ""
    }

    static var allDefinitions: [[String: Any]] {
        baseDefinitions + appearanceDefinitions
    }

    /// P3 外观包：舞台两端都有；Page2 主屏只在 iOS（mac 没有 Page2 桌面）
    private static var appearanceDefinitions: [[String: Any]] {
        var defs: [[String: Any]] = [
            tool("read_appearance", description: "读取现在的外观：她的舞台主题；iOS 上还有 Page2 主屏的壁纸 / 图标外观 / 明暗 / 大图标 / 自定义图标，以及每一项能选的值。改外观前必读。", properties: [:]),
            tool("propose_stage_theme", description: "提案：换小芽窗口顶上的剪纸舞台。用户盖章后才换。", properties: [
                "theme": ["type": "string", "enum": XiaoyaStageTheme.allCases.map(\.rawValue),
                          "description": XiaoyaStageTheme.allCases.map { "\($0.rawValue)=\($0.title)" }.joined(separator: "，")]
            ], required: ["theme"]),
        ]
        #if os(iOS)
        defs += [
            tool("propose_page2_appearance", description: "提案：改 Page2 主屏外观。只传要改的项；卡片会给用户看换完的样子，盖章才换。", properties: [
                "wallpaper": ["type": "string", "enum": Array(Page2AppearancePatch.wallpapers.keys).sorted(),
                              "description": Page2AppearancePatch.wallpapers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "，")],
                "rendering": ["type": "string", "enum": ["default", "dark", "clear", "tinted"], "description": "图标外观：默认 / 深色 / 透明 / 着色"],
                "luminosity": ["type": "string", "enum": ["light", "dark", "auto"], "description": "明暗"],
                "largeIcons": ["type": "boolean", "description": "大图标"],
                "dimming": ["type": "number", "description": "明亮遮罩 0~0.85"],
                "tintHue": ["type": "number", "description": "着色时的色相 0~1（rendering=tinted 才有效）"],
                "tintSaturation": ["type": "number", "description": "着色时的饱和度 0~1"]
            ]),
            tool("propose_app_icon", description: "提案：改 Page2 上某个 app 的图标符号和颜色。", properties: [
                "toolId": ["type": "string", "description": "app 的 id（从 read_appearance 拿）"],
                "symbol": ["type": "string", "enum": Page2IconChoices.symbols, "description": "图标符号；不传就保留原图标只换颜色"],
                "tint": ["type": "string", "enum": Array(Page2IconChoices.tints.keys).sorted(),
                         "description": Page2IconChoices.tints.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "，")]
            ], required: ["toolId"]),
        ]
        #endif
        return defs
    }

    private static var baseDefinitions: [[String: Any]] {
        [
            tool("read_current_preset", description: "读取用户当前楼层正在用的预设：所有插槽（id/名称/角色/内容）和采样参数。改预设前必读。", properties: [:]),
            tool("read_character", description: "读取卡库角色卡。不传 name 时列出所有角色卡的名字和简介；传 name 返回完整字段。", properties: [
                "name": ["type": "string", "description": "角色卡名；不传则列出全部"]
            ]),
            tool("query_memories", description: "搜索当前楼层的原子档案（后台整理的关于用户的档案）。用户问「你还记得…」「我喜欢…」时用。", properties: [
                "keyword": ["type": "string", "description": "关键词；不传则返回最近的记忆"],
                "limit": ["type": "number", "description": "最多返回条数，默认 10，最大 20"]
            ]),
            tool("list_world_books", description: "列出当前楼层的世界书（名字 + 条目数）。", properties: [:]),
            tool("read_world_book", description: "读取某本世界书的全部条目（keys/内容/备注）。", properties: [
                "bookName": ["type": "string", "description": "世界书名"]
            ], required: ["bookName"]),
            // ── 写操作：全部走提案 ──
            tool("propose_create_character", description: "提案：在卡库新建一张角色卡。用户确认后才生效。", properties: [
                "name": ["type": "string", "description": "角色名"],
                "description": ["type": "string", "description": "完整人设（按写作规范分板块）"],
                "personality": ["type": "string", "description": "性格（三层结构）"],
                "scenario": ["type": "string", "description": "场景/背景"],
                "firstMes": ["type": "string", "description": "开场白"]
            ], required: ["name", "description"]),
            tool("propose_update_character_field", description: "提案：修改某张角色卡的单个字段。", properties: [
                "cardName": ["type": "string", "description": "角色卡名"],
                "field": ["type": "string", "enum": ["description", "personality", "scenario", "firstMes", "mesExample", "systemPrompt", "postHistoryInstructions"], "description": "要改的字段"],
                "content": ["type": "string", "description": "新内容（完整替换该字段）"]
            ], required: ["cardName", "field", "content"]),
            tool("propose_update_preset_slot", description: "提案：修改当前楼层预设实例的某个插槽内容。", properties: [
                "slotId": ["type": "string", "description": "插槽 id（从 read_current_preset 获取）"],
                "content": ["type": "string", "description": "新的插槽内容（完整替换）"]
            ], required: ["slotId", "content"]),
            tool("propose_update_preset_sampling", description: "提案：修改当前楼层预设实例的采样参数。只传要改的字段。", properties: [
                "temperature": ["type": "number", "description": "温度 0-2"],
                "topP": ["type": "number", "description": "0-1"],
                "maxTokens": ["type": "number", "description": "最大输出 token。改了就变成手动；4096 表示按模型自动"],
                "contextDepth": ["type": "number", "description": "对话历史条数"]
            ]),
            tool("propose_create_preset", description: "提案：以某模板为底给当前楼层新建一份预设副本并启用。", properties: [
                "templateId": ["type": "string", "description": "模板预设 id（从 read_current_preset 的 templates 信息获取）"],
                "name": ["type": "string", "description": "新预设名"]
            ], required: ["templateId", "name"]),
            tool("propose_add_worldbook_entry", description: "提案：给某本世界书加条目。", properties: [
                "bookName": ["type": "string", "description": "世界书名"],
                "keys": ["type": "array", "items": ["type": "string"], "description": "触发关键词"],
                "content": ["type": "string", "description": "条目内容"],
                "comment": ["type": "string", "description": "备注（可选）"]
            ], required: ["bookName", "keys", "content"]),
            tool("propose_update_worldbook_entry", description: "提案：修改世界书某条目。只传要改的字段。", properties: [
                "bookName": ["type": "string"],
                "entryId": ["type": "string", "description": "条目 id（从 read_world_book 获取）"],
                "keys": ["type": "array", "items": ["type": "string"]],
                "content": ["type": "string"],
                "comment": ["type": "string"]
            ], required: ["bookName", "entryId"]),
            tool("propose_delete_worldbook_entry", description: "提案：删除世界书某条目。", properties: [
                "bookName": ["type": "string"],
                "entryId": ["type": "string"]
            ], required: ["bookName", "entryId"]),
        ]
    }

    private static func tool(_ name: String, description: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return [
            "type": "function",
            "function": ["name": name, "description": description, "parameters": schema]
        ]
    }

    // MARK: - 执行（读立即做；写只出提案）

    @MainActor
    static func execute(name: String, argumentsJSON: String, env: AssistantEnv) -> AssistantToolOutcome {
        guard let pack = XiaoyaPack.of(tool: name) else {
            return AssistantToolOutcome(resultText: "未知工具: \(name)", isError: true, refused: true)
        }
        guard XiaoyaPackPolicy.isEnabled(pack) else {
            return AssistantToolOutcome(resultText: "「\(pack.title)」能力被用户关掉了，这件事做不了，如实告诉用户", isError: true, refused: true)
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        switch name {
        case "read_current_preset": return readCurrentPreset(env: env)
        case "read_character": return readCharacter(args: args, env: env)
        case "query_memories": return queryMemories(args: args, env: env)
        case "list_world_books": return listWorldBooks(env: env)
        case "read_world_book": return readWorldBook(args: args, env: env)
        case "propose_create_character": return proposeCreateCharacter(args: args, env: env)
        case "propose_update_character_field": return proposeUpdateCharacterField(args: args, env: env)
        case "propose_update_preset_slot": return proposeUpdatePresetSlot(args: args, env: env)
        case "propose_update_preset_sampling": return proposeUpdatePresetSampling(args: args, env: env)
        case "propose_create_preset": return proposeCreatePreset(args: args, env: env)
        case "propose_add_worldbook_entry": return proposeAddWorldBookEntry(args: args, env: env)
        case "propose_update_worldbook_entry": return proposeUpdateWorldBookEntry(args: args, env: env)
        case "propose_delete_worldbook_entry": return proposeDeleteWorldBookEntry(args: args, env: env)
        case "read_appearance": return readAppearance()
        case "propose_stage_theme": return proposeStageTheme(args: args)
        #if os(iOS)
        case "propose_page2_appearance": return proposePage2Appearance(args: args)
        case "propose_app_icon": return proposeAppIcon(args: args)
        #endif
        default:
            return AssistantToolOutcome(resultText: "未知工具: \(name)", isError: true, refused: true)
        }
    }

    // MARK: - 读工具

    private static func readCurrentPreset(env: AssistantEnv) -> AssistantToolOutcome {
        let profile = env.profileManager.currentProfile
        guard let preset = env.presetManager.preset(byId: profile.presetId) else {
            return AssistantToolOutcome(resultText: "当前楼层没有绑预设", isError: true)
        }
        var lines = ["当前楼层「\(profile.name)」的预设「\(preset.name)」(id=\(preset.id))：", "", "插槽："]
        for slot in SlotOrder.ordered(preset.prompts) {
            let state = slot.isEnabled ? "" : "（停用）"
            let marker = slot.isMarker ? "（占位符，由系统填充）" : ""
            lines.append("- id=\(slot.id) 「\(slot.name)」\(state)\(marker)")
            if !slot.content.isEmpty && !slot.isMarker {
                lines.append("  内容：\(truncate(slot.content, 300))")
            }
        }
        let s = preset.sampling
        lines.append("")
        lines.append("采样参数：temperature=\(s.temperature) topP=\(s.topP) maxTokens=\(s.isMaxTokensAuto ? "自动" : String(s.maxTokens)) contextDepth=\(s.contextDepth)")
        let templates = env.presetManager.templates.map { "\($0.name)(id=\($0.id))" }.joined(separator: "、")
        lines.append("可用模板：\(templates)")
        return AssistantToolOutcome(resultText: lines.joined(separator: "\n"), isError: false)
    }

    private static func readCharacter(args: [String: Any], env: AssistantEnv) -> AssistantToolOutcome {
        let cards = env.cardManager.cards
        guard let name = args["name"] as? String, !name.isEmpty else {
            if cards.isEmpty { return AssistantToolOutcome(resultText: "卡库是空的", isError: false) }
            let list = cards.map { "「\($0.name)」\(truncate($0.description, 60))" }.joined(separator: "\n")
            return AssistantToolOutcome(resultText: "卡库共 \(cards.count) 张：\n\(list)", isError: false)
        }
        guard let card = cards.first(where: { $0.name == name }) else {
            return AssistantToolOutcome(resultText: "没有找到叫「\(name)」的角色卡", isError: true)
        }
        let text = """
            「\(card.name)」
            description: \(truncate(card.description, 800))
            personality: \(truncate(card.personality, 800))
            scenario: \(truncate(card.scenario, 400))
            firstMes: \(truncate(card.firstMes, 400))
            mesExample: \(truncate(card.mesExample, 300))
            systemPrompt: \(truncate(card.systemPrompt, 300))
            postHistoryInstructions: \(truncate(card.postHistoryInstructions, 300))
            """
        return AssistantToolOutcome(resultText: text, isError: false)
    }

    private static func queryMemories(args: [String: Any], env: AssistantEnv) -> AssistantToolOutcome {
        let pid = env.profileId
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { $0.profileId == pid && $0.supersededAt == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let all = (try? env.modelContext.fetch(descriptor)) ?? []
        let keyword = (args["keyword"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let limit = max(1, min(20, (args["limit"] as? Int) ?? 10))
        let matched: [Memory]
        if keyword.isEmpty {
            matched = Array(all.prefix(limit))
        } else {
            matched = Array(all.filter {
                $0.content.localizedCaseInsensitiveContains(keyword)
                    || $0.keywords.contains { $0.localizedCaseInsensitiveContains(keyword) }
            }.prefix(limit))
        }
        if matched.isEmpty {
            return AssistantToolOutcome(resultText: keyword.isEmpty ? "这个楼层还没有记忆" : "没有找到含「\(keyword)」的记忆", isError: false)
        }
        let list = matched.map { "- [\($0.category)] \($0.content)" }.joined(separator: "\n")
        return AssistantToolOutcome(resultText: "找到 \(matched.count) 条记忆：\n\(list)", isError: false)
    }

    private static func listWorldBooks(env: AssistantEnv) -> AssistantToolOutcome {
        let books = fetchWorldBooks(env: env)
        if books.isEmpty { return AssistantToolOutcome(resultText: "当前楼层还没有世界书", isError: false) }
        let list = books.map { "「\($0.name)」\( $0.entries.count ) 条" }.joined(separator: "\n")
        return AssistantToolOutcome(resultText: list, isError: false)
    }

    private static func readWorldBook(args: [String: Any], env: AssistantEnv) -> AssistantToolOutcome {
        guard let book = findWorldBook(args: args, env: env) else {
            return AssistantToolOutcome(resultText: "没有找到这本世界书", isError: true)
        }
        var lines = ["「\(book.name)」共 \(book.entries.count) 条："]
        for entry in book.entries {
            lines.append("- id=\(entry.id.uuidString) keys=[\(entry.keys.joined(separator: ", "))]\(entry.isEnabled ? "" : "（停用）")")
            lines.append("  内容：\(truncate(entry.content, 200))")
            if !entry.comment.isEmpty { lines.append("  备注：\(entry.comment)") }
        }
        return AssistantToolOutcome(resultText: lines.joined(separator: "\n"), isError: false)
    }

    // MARK: - 写工具（只出提案，v2 带类型改动：完整改前值 + 改后值 + 目标锚）

    private static func proposeCreateCharacter(args: [String: Any], env: AssistantEnv) -> AssistantToolOutcome {
        guard let name = nonEmpty(args["name"]), let description = nonEmpty(args["description"]) else {
            return AssistantToolOutcome(resultText: "缺 name 或 description", isError: true)
        }
        if env.cardManager.cards.contains(where: { $0.name == name }) {
            return AssistantToolOutcome(resultText: "卡库已有叫「\(name)」的卡，要改它请用 propose_update_character_field", isError: true)
        }
        let card = CharacterCard(name: name, description: description,
                                 personality: args["personality"] as? String ?? "",
                                 scenario: args["scenario"] as? String ?? "",
                                 firstMes: args["firstMes"] as? String ?? "")
        return proposed(.createCharacter(card: card))
    }

    private static func proposeUpdateCharacterField(args: [String: Any], env: AssistantEnv) -> AssistantToolOutcome {
        guard let cardName = args["cardName"] as? String,
              let field = args["field"] as? String,
              let content = nonEmpty(args["content"]) else {
            return AssistantToolOutcome(resultText: "缺 cardName/field/content", isError: true)
        }
        guard let card = env.cardManager.cards.first(where: { $0.name == cardName }) else {
            return AssistantToolOutcome(resultText: "没有找到叫「\(cardName)」的角色卡", isError: true)
        }
        guard let oldValue = characterField(card, field) else {
            return AssistantToolOutcome(resultText: "字段 \(field) 不存在", isError: true)
        }
        if oldValue == content { return AssistantToolOutcome(resultText: "新内容和现在一样，不用改", isError: true) }
        return proposed(.updateCharacterField(cardId: card.id, cardName: card.name, field: field, before: oldValue, after: content))
    }

    private static func proposeUpdatePresetSlot(args: [String: Any], env: AssistantEnv) -> AssistantToolOutcome {
        guard let slotId = args["slotId"] as? String,
              let content = args["content"] as? String else {
            return AssistantToolOutcome(resultText: "缺 slotId 或 content", isError: true)
        }
        let profile = env.profileManager.currentProfile
        guard let preset = env.presetManager.preset(byId: profile.presetId),
              let slot = preset.prompts.first(where: { $0.id == slotId }) else {
            return AssistantToolOutcome(resultText: "没找到插槽 \(slotId)，先 read_current_preset 拿正确的 id", isError: true)
        }
        if slot.isLocked {
            return AssistantToolOutcome(resultText: "「\(slot.name)」是骨架槽，UI 锁定不可改", isError: true)
        }
        if slot.content == content { return AssistantToolOutcome(resultText: "新内容和现在一样，不用改", isError: true) }
        return proposed(.updatePresetSlot(profileId: profile.id, presetId: preset.id, slotId: slotId,
                                          slotName: slot.name, before: slot.content, after: content))
    }

    private static func proposeUpdatePresetSampling(args: [String: Any], env: AssistantEnv) -> AssistantToolOutcome {
        let profile = env.profileManager.currentProfile
        guard let preset = env.presetManager.preset(byId: profile.presetId) else {
            return AssistantToolOutcome(resultText: "当前楼层没有绑预设", isError: true)
        }
        var changes: [SamplingChange] = []
        for key in ["temperature", "topP", "maxTokens", "contextDepth"] {
            guard let raw = args[key] else { continue }
            guard let v = (raw as? NSNumber)?.doubleValue else {
                return AssistantToolOutcome(resultText: "\(key) 要是数字", isError: true)
            }
            if AssistantStamp.integerSamplingKeys.contains(key), v.rounded() != v {
                return AssistantToolOutcome(resultText: "\(key) 要是整数", isError: true)
            }
            let valid: Bool = switch key {
            case "temperature": (0...2).contains(v)
            case "topP": (0...1).contains(v)
            case "maxTokens": v >= 1
            default: v >= 0
            }
            if !valid { return AssistantToolOutcome(resultText: "\(key)=\(v) 超出范围", isError: true) }
            let before = AssistantStamp.samplingValue(preset.sampling, key) ?? 0
            if before != v { changes.append(SamplingChange(key: key, before: before, after: v)) }
        }
        if changes.isEmpty {
            return AssistantToolOutcome(resultText: "没有要改的采样字段（或新值和现在一样）", isError: true)
        }
        return proposed(.updatePresetSampling(profileId: profile.id, presetId: preset.id, presetName: preset.name, changes: changes))
    }

    private static func proposeCreatePreset(args: [String: Any], env: AssistantEnv) -> AssistantToolOutcome {
        guard let templateId = args["templateId"] as? String, let name = nonEmpty(args["name"]) else {
            return AssistantToolOutcome(resultText: "缺 templateId 或 name", isError: true)
        }
        guard let template = env.presetManager.preset(byId: templateId) else {
            return AssistantToolOutcome(resultText: "没找到模板 \(templateId)", isError: true)
        }
        let profile = env.profileManager.currentProfile
        return proposed(.createPreset(profileId: profile.id, templateId: templateId, templateName: template.name, name: name,
                                      previousPresetId: profile.presetId, newInstanceId: nil))
    }

    private static func proposeAddWorldBookEntry(args: [String: Any], env: AssistantEnv) -> AssistantToolOutcome {
        guard let book = findWorldBook(args: args, env: env) else {
            return AssistantToolOutcome(resultText: "没有找到这本世界书", isError: true)
        }
        guard let keys = args["keys"] as? [String], !keys.isEmpty, let content = nonEmpty(args["content"]) else {
            return AssistantToolOutcome(resultText: "缺 keys 或 content", isError: true)
        }
        var entry = WorldBookEntry()
        entry.keys = keys
        entry.content = content
        entry.comment = args["comment"] as? String ?? ""
        return proposed(.addWorldBookEntry(profileId: env.profileId, bookId: book.id.uuidString, bookName: book.name, entry: entry))
    }

    /// 只传要改的字段：没传的（如备注）在 after 里原样保留，盖章时不会被清空（astra B1）
    private static func proposeUpdateWorldBookEntry(args: [String: Any], env: AssistantEnv) -> AssistantToolOutcome {
        guard let book = findWorldBook(args: args, env: env),
              let entryId = args["entryId"] as? String,
              let entry = book.entries.first(where: { $0.id.uuidString == entryId }) else {
            return AssistantToolOutcome(resultText: "没找到条目，先 read_world_book 拿正确的 entryId", isError: true)
        }
        var after = entry
        if let keys = args["keys"] as? [String] {
            if keys.isEmpty { return AssistantToolOutcome(resultText: "keys 不能清空", isError: true) }
            after.keys = keys
        }
        if let content = args["content"] as? String {
            if content.isEmpty { return AssistantToolOutcome(resultText: "内容不能清空，要删整条请用 propose_delete_worldbook_entry", isError: true) }
            after.content = content
        }
        if let comment = args["comment"] as? String { after.comment = comment }
        if after == entry { return AssistantToolOutcome(resultText: "没有要改的字段", isError: true) }
        return proposed(.updateWorldBookEntry(profileId: env.profileId, bookId: book.id.uuidString, bookName: book.name,
                                              before: entry, after: after))
    }

    private static func proposeDeleteWorldBookEntry(args: [String: Any], env: AssistantEnv) -> AssistantToolOutcome {
        guard let book = findWorldBook(args: args, env: env),
              let entryId = args["entryId"] as? String,
              let index = book.entries.firstIndex(where: { $0.id.uuidString == entryId }) else {
            return AssistantToolOutcome(resultText: "没找到条目，先 read_world_book 拿正确的 entryId", isError: true)
        }
        return proposed(.deleteWorldBookEntry(profileId: env.profileId, bookId: book.id.uuidString, bookName: book.name,
                                              entry: book.entries[index], index: index))
    }

    // MARK: - 外观（P3）

    @MainActor
    private static func readAppearance() -> AssistantToolOutcome {
        var lines = ["舞台：\(XiaoyaStageTheme.current.title)（\(XiaoyaStageTheme.current.rawValue)）。可选："
                     + XiaoyaStageTheme.allCases.map { "\($0.rawValue)=\($0.title)" }.joined(separator: "，")]
        #if os(iOS)
        let free = (UserDefaults.standard.string(forKey: "page2HomePresentation_v1") ?? "free") == "free"
        if !free {
            lines.append("Page2 主屏：用户现在用的是针脚主屏，壁纸 / 图标外观这些设置不影响它，别提这类提案。")
        } else {
            let a = Page2AppearanceStore.shared.value
            lines.append("Page2 主屏：壁纸 \(a.wallpaper)，图标外观 \(a.rendering)，明暗 \(a.luminosity)，大图标 \(a.largeIcons ? "开" : "关")，明亮遮罩 \(a.dimming)，着色色相 \(a.tintHue) 饱和度 \(a.tintSaturation)")
            lines.append("壁纸可选：" + Page2AppearancePatch.wallpapers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "，"))
            lines.append("app（id=名字）：" + RightPanelToolManager.builtInTools.filter { !RightPanelToolManager.secretToolIds.contains($0.id) }.map { tool -> String in
                let custom = a.icons[tool.id].map { " [自定义 \($0.symbol ?? "图片") \($0.tint)]" } ?? ""
                return "\(tool.id)=\(tool.name)\(custom)"
            }.joined(separator: "，"))
        }
        #endif
        return AssistantToolOutcome(resultText: lines.joined(separator: "\n"), isError: false)
    }

    @MainActor
    private static func proposeStageTheme(args: [String: Any]) -> AssistantToolOutcome {
        guard let raw = args["theme"] as? String, let theme = XiaoyaStageTheme(rawValue: raw) else {
            return AssistantToolOutcome(resultText: "theme 只能是 " + XiaoyaStageTheme.allCases.map(\.rawValue).joined(separator: " / "), isError: true)
        }
        let current = XiaoyaStageTheme.current.rawValue
        if current == theme.rawValue { return AssistantToolOutcome(resultText: "现在就是这个舞台", isError: true) }
        return proposed(.stageTheme(before: current, after: theme.rawValue))
    }

    #if os(iOS)
    @MainActor
    private static func proposePage2Appearance(args: [String: Any]) -> AssistantToolOutcome {
        guard (UserDefaults.standard.string(forKey: "page2HomePresentation_v1") ?? "free") == "free" else {
            return AssistantToolOutcome(resultText: AssistantStamp.stitchedHome, isError: true)
        }
        let current = Page2AppearanceStore.shared.value
        let patch = Page2AppearancePatch(
            wallpaper: args["wallpaper"] as? String,
            rendering: args["rendering"] as? String,
            luminosity: args["luminosity"] as? String,
            largeIcons: args["largeIcons"] as? Bool,
            dimming: (args["dimming"] as? NSNumber)?.doubleValue,
            tintHue: (args["tintHue"] as? NSNumber)?.doubleValue,
            tintSaturation: (args["tintSaturation"] as? NSNumber)?.doubleValue
        ).dropping(unchangedFrom: current)
        do { try patch.validate() } catch {
            return AssistantToolOutcome(resultText: error.localizedDescription, isError: true)
        }
        if patch.isEmpty { return AssistantToolOutcome(resultText: "没有要改的项（或新值和现在一样）", isError: true) }
        return proposed(.page2Appearance(before: patch.currentValues(in: current), after: patch))
    }

    @MainActor
    private static func proposeAppIcon(args: [String: Any]) -> AssistantToolOutcome {
        guard (UserDefaults.standard.string(forKey: "page2HomePresentation_v1") ?? "free") == "free" else {
            return AssistantToolOutcome(resultText: AssistantStamp.stitchedHome, isError: true)
        }
        guard let toolId = args["toolId"] as? String,
              !RightPanelToolManager.secretToolIds.contains(toolId),
              let tool = RightPanelToolManager.builtInTools.first(where: { $0.id == toolId }) else {
            return AssistantToolOutcome(resultText: "没有这个 app，先 read_appearance 拿 id", isError: true)
        }
        let symbol = args["symbol"] as? String
        if let symbol, !Page2IconChoices.symbols.contains(symbol) {
            return AssistantToolOutcome(resultText: "symbol 只能从这些里选：" + Page2IconChoices.symbols.joined(separator: " / "), isError: true)
        }
        let tint = args["tint"] as? String ?? "sage"
        guard Page2IconChoices.tints[tint] != nil else {
            return AssistantToolOutcome(resultText: "tint 只能是 sage / rose / plum / graphite", isError: true)
        }
        let before = Page2AppearanceStore.shared.value.icons[toolId]
        let after = Page2IconOverride(symbol: symbol ?? before?.symbol, imageFile: nil, tint: tint)
        if before == after { return AssistantToolOutcome(resultText: "和现在一样，不用改", isError: true) }
        return proposed(.appIcon(toolId: toolId, toolName: tool.name, before: before, after: after))
    }
    #endif

    // MARK: - 私有帮手

    private static func proposed(_ change: AssistantChange) -> AssistantToolOutcome {
        let action = AssistantAction(change: change)
        return AssistantToolOutcome(resultText: "已生成提案「\(change.category)：\(change.title)」，等用户在界面上盖章后才生效。",
                                    isError: false, action: action)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    private static func fetchWorldBooks(env: AssistantEnv) -> [WorldBook] {
        let pid = env.profileId
        let descriptor = FetchDescriptor<WorldBook>(predicate: #Predicate<WorldBook> { $0.profileId == pid })
        return (try? env.modelContext.fetch(descriptor)) ?? []
    }

    private static func findWorldBook(args: [String: Any], env: AssistantEnv) -> WorldBook? {
        guard let name = args["bookName"] as? String else { return nil }
        return fetchWorldBooks(env: env).first(where: { $0.name == name })
    }

    static func characterField(_ card: CharacterCard, _ field: String) -> String? {
        switch field {
        case "description": return card.description
        case "personality": return card.personality
        case "scenario": return card.scenario
        case "firstMes": return card.firstMes
        case "mesExample": return card.mesExample
        case "systemPrompt": return card.systemPrompt
        case "postHistoryInstructions": return card.postHistoryInstructions
        default: return nil
        }
    }

    static func setCharacterField(_ card: inout CharacterCard, _ field: String, _ value: String) throws {
        switch field {
        case "description": card.description = value
        case "personality": card.personality = value
        case "scenario": card.scenario = value
        case "firstMes": card.firstMes = value
        case "mesExample": card.mesExample = value
        case "systemPrompt": card.systemPrompt = value
        case "postHistoryInstructions": card.postHistoryInstructions = value
        default: throw AssistantStampError.invalid("没有字段 \(field)")
        }
    }
}
