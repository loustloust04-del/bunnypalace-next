import Foundation

// MARK: - Prompt Slot

struct PromptSlot: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var role: String = "system"           // "system" | "user" | "assistant"
    var content: String = ""
    var isSystemPrompt: Bool = true       // true=内置/骨架槽（UI 锁定不可删）；是否注入只看 isEnabled
    var isEnabled: Bool = true
    var isMarker: Bool = false            // 占位符（由角色卡/记忆/对话填充）
    var injectionDepth: Int = 0           // 0=按顺序，>0=从对话末尾数第 N 层插入（④a 起：只对 absolute 生效，见 effectivePosition）
    var injectionOrder: Int = 100         // 排序优先级（④a 起：只管 absolute 同深度内先后；序列顺序看 sequenceIndex）
    var forbidOverrides: Bool = false     // 角色卡能否覆盖
    // ④a：下面两个是可选新字段，synthesized Codable 对 Optional 走 decodeIfPresent，旧数据缺键安全得 nil
    var injectionPosition: InjectionPosition? = nil  // nil=旧数据：depth>0 视为 absolute，否则 relative
    var sequenceIndex: Int? = nil                    // 插槽序列位置，只经 SlotOrder 读写；nil=旧数据按 injectionOrder 排

    /// relative=按序列位置（以对话历史 marker 为界）；absolute=按深度插进历史（depth=0 在最新一条之后）
    enum InjectionPosition: String, Codable, Hashable {
        case relative, absolute
        // 认不出的值按 relative 读，不让一个字段毁掉整份预设解码
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = raw == Self.absolute.rawValue ? .absolute : .relative
        }
    }

    var effectivePosition: InjectionPosition { injectionPosition ?? (injectionDepth > 0 ? .absolute : .relative) }
    var isAbsolute: Bool { effectivePosition == .absolute }

    // Well-known marker identifiers
    static let mainId = "main"
    static let personaDescriptionId = "personaDescription"
    static let charDescriptionId = "charDescription"
    static let charPersonalityId = "charPersonality"
    static let scenarioId = "scenario"
    static let dialogueExamplesId = "dialogueExamples"
    static let memoryInjectionId = "memoryInjection"
    static let chatHistoryId = "chatHistory"
    static let contextSummaryId = "contextSummary"
    static let userProfileId = "userProfile"
    static let timelineId = "contextTimeline"
    static let jailbreakId = "jailbreak"
    static let worldInfoBeforeId = "worldInfoBefore"
    static let worldInfoAfterId = "worldInfoAfter"
    /// 卡级 depth_prompt 物化出的插槽：id 本身就是「来源是卡」的标记，也用来防重复加
    static let cardDepthPromptId = "cardDepthPrompt"

    /// 锁死槽：UI 不给开关（其余内置 marker 可开关，注入只看 isEnabled）
    var isLocked: Bool { id == Self.mainId || id == Self.chatHistoryId }
}

// MARK: - Sampling Parameters

struct SamplingParams: Codable, Hashable {
    var temperature: Double = 0.7
    var topP: Double = 0.95
    var topK: Int = 0                     // 0=不发
    var maxTokens: Int = 4096
    var frequencyPenalty: Double = 0
    var presencePenalty: Double = 0
    var contextDepth: Int = 40            // 对话历史条数
    // 新增参数
    var maxContextSize: Int = 100000      // 上下文窗口上限
    var seed: Int = -1                    // -1=随机
    var reasoningEffort: String = "auto"  // "low"/"medium"/"high"/"auto"
    var verbosity: String = "auto"        // "auto"/"concise"/"verbose"
    var streaming: Bool = true
    var squashSystemMessages: Bool = false // 合并连续 system 消息
    var postProcessingMode: String = "none" // "none" | "merge" | "strict"
    var continuePrefill: Bool = false     // 续写时用 assistant prefill
    var continuePostfix: String = " "
    // ⚠️ 可选型：synthesized Codable 对非可选新字段在老数据上会 decode 失败（preset 全量丢失），Bool? 缺 key 安全得 nil
    var cacheFriendly: Bool? = nil        // 缓存命中优化：易变段下沉 system 尾部，nil/false = 关
    var maxTokensAuto: Bool? = nil        // 输出上限按模型自动；nil = 老数据，按「4096 即自动」解读（OutputTokenCap）
}

// MARK: - Preset

struct Preset: Identifiable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var description: String = ""
    var isBuiltIn: Bool = false           // 内置预设不可删除
    var ownerProfileId: String? = nil     // nil=模板（选择器可见）；非 nil=某楼层的实例
    var rawJSONData: Data?              // 导入原文；排序与注入留给第 ④ 步
    var sourceTemplateId: String? = nil   // 实例的来源模板 id（选择器高亮/切回复用）
    var sampling: SamplingParams = SamplingParams()
    var prompts: [PromptSlot] = []

    // 格式模板（角色卡数据填入 marker 前的包装格式）
    var characterFormat: String = "[角色设定]\n{{description}}\n{{personality}}"
    var scenarioFormat: String = "[当前场景]\n{{scenario}}"
    var personaFormat: String = "[用户信息]\n{{persona}}"
    var regexScripts: [RegexScript] = []     // 预设绑定的正则脚本
}

// MARK: - Built-in Presets

extension Preset {
    /// 默认插槽骨架（三个预设共用）
    private static var defaultSlots: [PromptSlot] {
        [
            PromptSlot(id: PromptSlot.mainId, name: "⭐ 系统指令", role: "system",
                       isSystemPrompt: true, isMarker: false, injectionOrder: 0),
            PromptSlot(id: PromptSlot.personaDescriptionId, name: "🧑 用户描述", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 10),
            PromptSlot(id: PromptSlot.worldInfoBeforeId, name: "🌍 世界书(前)", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 19),
            PromptSlot(id: PromptSlot.charDescriptionId, name: "📝 助手设定", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 20),
            PromptSlot(id: PromptSlot.worldInfoAfterId, name: "🌍 世界书(后)", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 21),
            PromptSlot(id: PromptSlot.scenarioId, name: "📖 背景设定", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 30),
            PromptSlot(id: PromptSlot.timelineId, name: "📅 时间轴", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 38),
            PromptSlot(id: PromptSlot.userProfileId, name: "🌙 用户画像", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 39),
            PromptSlot(id: PromptSlot.memoryInjectionId, name: "🧠 记忆", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 40),
            PromptSlot(id: PromptSlot.dialogueExamplesId, name: "💬 对话示例", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 50),
            PromptSlot(id: PromptSlot.contextSummaryId, name: "📝 上下文摘要", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 55),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "📜 对话历史", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 60),
            PromptSlot(id: PromptSlot.jailbreakId, name: "📌 后置提醒", role: "system",
                       isSystemPrompt: true, isMarker: false, injectionDepth: 0, injectionOrder: 70),
        ]
    }

    static let balanced = Preset(
        id: "built-in-balanced",
        name: "默认",
        description: "通用预设，可自由调整参数",
        isBuiltIn: true,
        sampling: SamplingParams(temperature: 0.7, topP: 0.95, maxTokens: 4096, contextDepth: 40),
        prompts: defaultSlots
    )

    static let allBuiltIn: [Preset] = [balanced]
}

// MARK: - SillyTavern JSON Import/Export

extension Preset {

    /// 内置 marker identifier 列表
    private static let builtInMarkers: Set<String> = [
        PromptSlot.mainId, PromptSlot.chatHistoryId, PromptSlot.charDescriptionId,
        PromptSlot.charPersonalityId, PromptSlot.scenarioId, PromptSlot.personaDescriptionId,
        PromptSlot.dialogueExamplesId, PromptSlot.memoryInjectionId, PromptSlot.jailbreakId,
        PromptSlot.contextSummaryId, PromptSlot.userProfileId, PromptSlot.timelineId,
        PromptSlot.worldInfoBeforeId, PromptSlot.worldInfoAfterId, "enhanceDefinitions", "nsfw",
    ]

    /// 从酒馆 Chat Completion Preset JSON 导入
    static func fromSillyTavernJSON(_ data: Data) throws -> Preset {
        try importSillyTavernJSON(data).preset
    }

    /// 同上，另带导入报告：prompt_order 缺 100001 组 / 多份 / 引用缺失时 notes 非空，调用方给提示
    static func importSillyTavernJSON(_ data: Data) throws -> (preset: Preset, notes: [String]) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Preset", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无效的 JSON 格式"])
        }

        // 尝试从文件名或 prompts[0].name 推导预设名
        let firstName = (json["prompts"] as? [[String: Any]])?.first?["name"] as? String
        var preset = Preset(name: firstName ?? "导入的预设")
        preset.rawJSONData = data

        // 1. 采样参数
        var s = SamplingParams()
        s.temperature = json["temperature"] as? Double ?? 0.7
        s.topP = json["top_p"] as? Double ?? 0.95
        s.topK = json["top_k"] as? Int ?? 0
        s.maxTokens = json["openai_max_tokens"] as? Int ?? 4096
        s.frequencyPenalty = json["frequency_penalty"] as? Double ?? 0
        s.presencePenalty = json["presence_penalty"] as? Double ?? 0
        s.maxContextSize = json["openai_max_context"] as? Int ?? 100000
        s.seed = json["seed"] as? Int ?? -1
        s.reasoningEffort = json["reasoning_effort"] as? String ?? "auto"
        s.verbosity = json["verbosity"] as? String ?? "auto"
        s.streaming = json["stream_openai"] as? Bool ?? true
        s.squashSystemMessages = json["squash_system_messages"] as? Bool ?? false
        s.continuePrefill = json["continue_prefill"] as? Bool ?? false
        s.continuePostfix = json["continue_postfix"] as? String ?? " "
        preset.sampling = s

        // 2. 格式模板
        if let sf = json["scenario_format"] as? String, !sf.isEmpty {
            preset.scenarioFormat = sf
        }
        if let pf = json["personality_format"] as? String, !pf.isEmpty {
            preset.characterFormat = pf
        }

        // 3. Prompts
        let stPrompts = json["prompts"] as? [[String: Any]] ?? []

        // 4. prompt_order（④a）：按酒馆 global 策略只认 character_id=100001 那组，见下方 SlotOrder.globalPromptOrder

        // 5. 转换每个 prompt
        var slots: [PromptSlot] = []
        for (index, stPrompt) in stPrompts.enumerated() {
            let identifier = stPrompt["identifier"] as? String ?? UUID().uuidString
            let name = stPrompt["name"] as? String ?? ""
            let role = stPrompt["role"] as? String ?? "system"
            let content = stPrompt["content"] as? String ?? ""
            let isSystem = stPrompt["system_prompt"] as? Bool ?? true
            let depth = stPrompt["injection_depth"] as? Int ?? 0
            let order = stPrompt["injection_order"] as? Int ?? (100 + index)
            let forbid = stPrompt["forbid_overrides"] as? Bool ?? false
            // 酒馆缺键即 relative（depth 被忽略），不套旧的 depth>0 推断
            let position: PromptSlot.InjectionPosition = (stPrompt["injection_position"] as? Int) == 1 ? .absolute : .relative

            let slot = PromptSlot(
                id: identifier,
                name: name,
                role: role,
                content: content,
                isSystemPrompt: isSystem,
                isEnabled: true,
                isMarker: builtInMarkers.contains(identifier),
                injectionDepth: depth,
                injectionOrder: order,
                forbidOverrides: forbid,
                injectionPosition: position
            )
            slots.append(slot)
        }

        // 顺序和开关按 100001 组；选不出唯一可用的组 → 原行为兜底（文件顺序、全开）并报告，绝不取 .last。
        // 其他组原样留在 rawJSONData 里，不启用
        let pick = SlotOrder.globalPromptOrder(json["prompt_order"], promptIds: slots.map(\.id))
        if let entries = pick.entries {
            preset.prompts = SlotOrder.applyingPromptOrder(entries, to: slots)
        } else {
            preset.prompts = SlotOrder.normalized(slots)
        }

        // 4. 正则脚本
        if let ext = json["extensions"] as? [String: Any],
           let scripts = ext["regex_scripts"] as? [[String: Any]] {
            preset.regexScripts = scripts.map { RegexScript(from: $0) }
        }

        return (preset: preset, notes: pick.notes)
    }

    /// 导出为酒馆兼容 JSON
    func toSillyTavernJSON() -> Data? {
        var json: [String: Any] = [:]

        // 采样参数
        json["temperature"] = sampling.temperature
        json["top_p"] = sampling.topP
        json["top_k"] = sampling.topK
        json["openai_max_tokens"] = sampling.maxTokens
        json["frequency_penalty"] = sampling.frequencyPenalty
        json["presence_penalty"] = sampling.presencePenalty
        json["openai_max_context"] = sampling.maxContextSize
        json["seed"] = sampling.seed
        json["reasoning_effort"] = sampling.reasoningEffort
        json["verbosity"] = sampling.verbosity
        json["stream_openai"] = sampling.streaming
        json["squash_system_messages"] = sampling.squashSystemMessages
        json["continue_prefill"] = sampling.continuePrefill
        json["continue_postfix"] = sampling.continuePostfix

        // 格式模板
        json["scenario_format"] = scenarioFormat
        json["personality_format"] = characterFormat

        // Prompts（④a：序列顺序与位置都经 SlotOrder）
        let orderedSlots = SlotOrder.ordered(prompts)
        json["prompts"] = orderedSlots.map { slot -> [String: Any] in
            var p: [String: Any] = [:]
            p["identifier"] = slot.id
            p["name"] = slot.name
            p["role"] = slot.role
            p["content"] = slot.content
            p["system_prompt"] = slot.isSystemPrompt
            p["injection_position"] = slot.isAbsolute ? 1 : 0
            p["injection_depth"] = slot.injectionDepth
            p["injection_order"] = slot.injectionOrder
            p["forbid_overrides"] = slot.forbidOverrides
            return p
        }

        // Prompt order：100001 组按当前序列写；原文里其他 character_id 的组原样带回（酒馆 global 策略不读它们）
        let raw = rawJSONData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let otherGroups = (raw?["prompt_order"] as? [[String: Any]] ?? []).filter {
            SlotOrder.characterId($0["character_id"]) != SlotOrder.globalCharacterId
        }
        json["prompt_order"] = otherGroups + [
            [
                "character_id": SlotOrder.globalCharacterId,
                "order": orderedSlots.map { slot -> [String: Any] in
                    ["identifier": slot.id, "enabled": slot.isEnabled]
                }
            ] as [String : Any]
        ]

        // extensions：导入原文里有就合回去（regex_scripts / tavern_helper 等未编辑子树保真）
        if let extensions = raw?["extensions"] as? [String: Any] {
            json["extensions"] = extensions
        }

        return try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// 序列化为 JSON string（原始模式显示用）
    func toJSONString() -> String {
        guard let data = toSillyTavernJSON(),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// 从 JSON string 解析（原始模式粘贴用）
    static func fromJSONString(_ string: String) throws -> Preset {
        guard let data = string.data(using: .utf8) else {
            throw NSError(domain: "Preset", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无效的文本"])
        }
        return try fromSillyTavernJSON(data)
    }
}
