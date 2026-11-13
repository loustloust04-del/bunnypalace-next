import Foundation

enum TurnStatusTool {
    static let toolName = "set_turn_status"
    static let maxLength = 20
    static let definition = ToolDefinition(
        name: toolName,
        description: "干活时可以用它给顶栏写一句俏皮的自我状态，比如「拉磨中」。可选，别为它单独占一轮，和其它工具同一轮并行调用。状态仅在本轮内存中有效，不更新资料卡。",
        properties: ["status": ["type": "string", "description": "本轮自我状态，20字以内，不含换行。", "maxLength": maxLength]],
        required: ["status"]
    )

    private struct Arguments: Decodable { let status: String }

    static func text(from argumentsJSON: String) -> String? {
        guard let args = try? JSONDecoder().decode(Arguments.self, from: Data(argumentsJSON.utf8)) else { return nil }
        var text = ""
        var count = 0
        for character in args.status {
            if count == 0, character.isWhitespace { continue }
            guard count < maxLength else { break }
            text.append(character.isNewline ? " " : character)
            count += 1
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
