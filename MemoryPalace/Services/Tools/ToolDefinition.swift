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

    init(family: Family, deferMCP: Bool, profileId: String? = nil) {
        self.family = family
        self.deferMCP = deferMCP
        self.profileId = profileId
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

    static func render(_ defs: [ToolDefinition], family: ToolGateContext.Family) -> [[String: Any]] {
        switch family {
        case .openAI: return defs.map(openAI)
        case .anthropic: return defs.map(anthropic)
        }
    }
}
