import Foundation

/// 查聊天卡片写法（粟粟 10-03：卡片说明不全塞系统提示词，模型要发卡前自己查）。
/// 返回的文字就是 ChatCardPromptGuide.text 里对应那几段（同一份），CC 那边是 MCP 同名工具（cc-bridge/card-guide.ts）
enum CardGuideTool {
    static let toolName = "card_guide"

    static var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "查聊天卡片的写法。要在回复里发卡片（待办、骰子、计时器、图表、音乐、生词、时间线、提问 / 表单、html 网页卡）之前先调它，kinds 传要用的种类，按返回的格式写。不发卡片不用调。",
            properties: [
                "kinds": ["type": "array", "items": ["type": "string", "enum": ChatCardPromptGuide.kinds],
                          "description": "要查的卡片种类，可以一次查几种"],
            ],
            required: ["kinds"]
        )
    }

    static func execute(inputJSON: String) -> (text: String, isError: Bool) {
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any]
        let kinds = (args?["kinds"] as? [Any])?.compactMap { $0 as? String } ?? []
        return (ChatCardPromptGuide.guide(for: kinds), false)   // 参数坏了就全给，别让模型卡住
    }

    /// 这一轮发出去的工具里有没有它（有才在系统提示里只放目录；工具定义可能是平铺的也可能包在 function 里）
    static func isOffered(in tools: [[String: Any]]?) -> Bool {
        guard let tools else { return false }
        return tools.contains { tool in
            (tool["name"] as? String) == toolName
                || ((tool["function"] as? [String: Any])?["name"] as? String) == toolName
        }
    }
}
