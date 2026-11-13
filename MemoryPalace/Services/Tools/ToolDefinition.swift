import Foundation

/// 统一工具定义：一份 spec，双家 schema 渲染（plan-pi-style-toolbase P0.1）。
/// 只管「模型看到什么」——执行分发仍在 ConversationViewModel 的 tool_use 回调
/// （各工具执行深度耦合 turn 状态：payload/熔断计数/UI 元数据，统一签名收益小风险大，见 plan §修订）。
struct ToolDefinition {
    let name: String
    let description: String
    /// JSON-schema properties 原样字典（含 enum/items 等嵌套，渲染器不解释只包装）
    let properties: [String: Any]
    let required: [String]
}

/// 注入门控输入。各工具的开关（文件库/心声/recall/搜索）由 enabledIf 闭包自己读单例，
/// 这里只装「按调用点变化」的量。
struct ToolGateContext {
    enum Family { case openAI, anthropic }
    let family: Family
    /// MCP 工具数超阈值 → 元工具目录模式
    let deferMCP: Bool
    /// 当前楼层：按楼层门控的工具用（死亡天平只给授权过的楼层）
    let profileId: String?
    /// 工具抽屉快照（#093）；默认 = 没改过，分法和抽屉之前一样
    let drawer: ToolDrawerState
    /// 当前楼层用户名：定义里提到 wiki 本人那组（落盘 {{user}}）的工具按它显示（suggest_wiki_direction）
    let userName: String
    /// 本窗记忆参与（`EffectiveMemoryParticipation.writeTools`）：关参与窗不下发 remember / edit_memory /
    /// forget_memory / pending_notes / suggest_wiki_direction。默认 true = 抽屉预览等无会话处全开
    let memoryWriteTools: Bool

    init(family: Family, deferMCP: Bool, profileId: String? = nil, drawer: ToolDrawerState = .defaults, userName: String = "",
         memoryWriteTools: Bool = true) {
        self.family = family
        self.deferMCP = deferMCP
        self.profileId = profileId
        self.drawer = drawer
        self.userName = userName
        self.memoryWriteTools = memoryWriteTools
    }
}

/// 工具抽屉（#093）里一个内建工具的三态：直接给 / 收在〔更多工具〕/ 关
enum ToolDrawerMode: String, Codable, CaseIterable {
    case inline, tucked, off
}

/// 工具抽屉快照：只存改过的。解析顺序 本楼层覆盖 → 全局 → 注册表默认（默认在 ToolRegistry.defaultMode，这里不认识工具）。
/// 纯值类型（mp-code 也编这个文件）；读写 UserDefaults 在 ToolDrawerStore
struct ToolDrawerState: Equatable {
    var global: [String: ToolDrawerMode]
    /// profileId → 本楼层覆盖
    var floors: [String: [String: ToolDrawerMode]]

    static let defaults = ToolDrawerState(global: [:], floors: [:])

    /// nil = 没改过，用注册表默认
    func override(_ name: String, profileId: String?) -> ToolDrawerMode? {
        if let profileId, let m = floors[profileId]?[name] { return m }
        return global[name]
    }

    /// 本楼层自己改过的（nil = 跟随全局）
    func floorOverride(_ name: String, profileId: String) -> ToolDrawerMode? {
        floors[profileId]?[name]
    }

    /// nil = 删掉这条（全局 → 回默认；楼层 → 跟随全局）
    mutating func set(_ mode: ToolDrawerMode?, for name: String, profileId: String?) {
        if let profileId {
            var floor = floors[profileId] ?? [:]
            floor[name] = mode
            floors[profileId] = floor.isEmpty ? nil : floor
        } else {
            global[name] = mode
        }
    }

    // MARK: 存取（JSON）：不认识的档位读的时候丢掉，不报错

    private struct Wire: Codable {
        var global: [String: String]
        var floors: [String: [String: String]]
    }

    func encoded() -> Data {
        let wire = Wire(global: global.mapValues(\.rawValue), floors: floors.mapValues { $0.mapValues(\.rawValue) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(wire)) ?? Data()
    }

    static func decoded(_ data: Data?) -> ToolDrawerState {
        guard let data, let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return .defaults }
        let floors = wire.floors.mapValues { $0.compactMapValues(ToolDrawerMode.init(rawValue:)) }.filter { !$0.value.isEmpty }
        return ToolDrawerState(global: wire.global.compactMapValues(ToolDrawerMode.init(rawValue:)), floors: floors)
    }
}

/// 双家渲染器：输出形状与迁移前各工具手写版本逐字节一致（golden fixture 钉死）。
enum ToolSchemaRenderer {
    /// OpenAI: {type:function, function:{name,description,parameters}}
    static func openAI(_ d: ToolDefinition) -> [String: Any] {
        ["type": "function", "function": [
            "name": d.name, "description": d.description,
            "parameters": ["type": "object", "properties": d.properties, "required": d.required]
        ] as [String: Any]]
    }

    /// Anthropic: {name,description,input_schema}
    static func anthropic(_ d: ToolDefinition) -> [String: Any] {
        ["name": d.name, "description": d.description,
         "input_schema": ["type": "object", "properties": d.properties, "required": d.required] as [String: Any]]
    }

    /// 通用调用者可以交 OpenAI 定义；原生 Anthropic / server 工具保持原样。
    static func anthropic(_ tools: [[String: Any]]) -> [[String: Any]] {
        guard tools.contains(where: { $0["type"] as? String == "function" }) else { return tools }
        return tools.map { tool in
            guard tool["type"] as? String == "function", let function = tool["function"] as? [String: Any] else { return tool }
            var native = tool
            native.removeValue(forKey: "type")
            native.removeValue(forKey: "function")
            native["name"] = function["name"]
            native["description"] = function["description"]
            native["input_schema"] = function["parameters"]
            return native
        }
    }

    static func render(_ defs: [ToolDefinition], family: ToolGateContext.Family) -> [[String: Any]] {
        switch family {
        case .openAI: return defs.map(openAI)
        case .anthropic: return defs.map(anthropic)
        }
    }
}
