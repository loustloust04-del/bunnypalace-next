import Foundation

/// 问问题（官端 AskUserQuestion 同款）：模型弹选择卡收集用户决定，
/// 答案走标准 tool_result 回灌。执行侧特殊——不立即执行，暂停工具循环等用户点选
/// （pending 状态机在 ConversationViewModel，此处只管 schema/解析/拼文纯函数）。
enum AskUserTool {
    static let toolName = "ask_user"

    private static let toolDescription = """
    需要用户在几个选项中做选择、拿不准该往哪个方向继续、或想收集用户的具体偏好时，\
    用这个工具弹出选择卡。用户会看到问题和可点的选项，也可以自由输入答案代替选项，还可以跳过。\
    不要用于寒暄、闲聊、或答案显而易见的问题。
    """

    private static let properties: [String: Any] = [
        "questions": [
            "type": "array",
            "description": "1-4 个问题，逐题呈现给用户",
            "items": [
                "type": "object",
                "properties": [
                    "question": ["type": "string", "description": "完整的问题文本"],
                    "options": ["type": "array", "items": ["type": "string"], "description": "2-6 个候选项（纯文本短句）"],
                    "multiSelect": ["type": "boolean", "description": "true=可多选，默认单选"],
                ] as [String: Any],
                "required": ["question", "options"],
            ] as [String: Any],
        ] as [String: Any],
    ]
    private static let required = ["questions"]

    static var definition: ToolDefinition {
        ToolDefinition(name: toolName, description: toolDescription, properties: properties, required: required)
    }

    // MARK: - 解析

    struct ParsedQuestion: Equatable {
        let question: String
        let options: [String]
        let multiSelect: Bool
    }

    /// 参数校验失败回这句（isError result，模型自纠）
    static let invalidArgsMessage = "ask_user 参数无效：questions 需 1-4 个，每题需 question 文本 + 2-6 个纯文本 options"

    static func parse(inputJSON: String) -> [ParsedQuestion]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any],
              let raw = obj["questions"] as? [[String: Any]],
              (1...4).contains(raw.count) else { return nil }
        var parsed: [ParsedQuestion] = []
        for q in raw {
            guard let question = (q["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !question.isEmpty,
                  let options = q["options"] as? [String],
                  (2...6).contains(options.count),
                  options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { return nil }
            parsed.append(ParsedQuestion(
                question: question,
                options: options,
                multiSelect: q["multiSelect"] as? Bool ?? false
            ))
        }
        return parsed
    }

    // MARK: - 结构化答案（sheet 产出；API 路径映射回字符串，CC 桥要下标做键序驱动）

    enum AnswerValue: Equatable {
        case options([Int])   // 选项下标（单选 1 个，多选多个，按点选序）
        case text(String)     // 自由输入

        func displayString(options: [String]) -> String {
            switch self {
            case .text(let s): return s
            case .options(let idxs): return idxs.compactMap { options.indices.contains($0) ? options[$0] : nil }.joined(separator: "、")
            }
        }
    }

    /// CC 桥题面（hub 帧原样 = AskUserQuestion tool_input）→ ParsedQuestion。
    /// 比 parse 宽松：options 是 {label, description} 对象、数量 1+ 即收（CC 侧已校验过）。
    static func parseCCQuestions(_ raw: [[String: Any]]) -> [ParsedQuestion]? {
        var parsed: [ParsedQuestion] = []
        for q in raw {
            guard let question = (q["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !question.isEmpty,
                  let options = q["options"] as? [[String: Any]], !options.isEmpty else { return nil }
            let labels = options.compactMap { $0["label"] as? String }
            guard labels.count == options.count else { return nil }
            parsed.append(ParsedQuestion(question: question, options: labels, multiSelect: q["multiSelect"] as? Bool ?? false))
        }
        return parsed.isEmpty ? nil : parsed
    }

    // MARK: - 回灌拼文

    static let skippedAnswer = "（用户没有选择，跳过了这个问题）"

    /// answers 与 questions 按下标对齐；nil = 跳过。多选/自由输入都已是最终字符串。
    static func resultText(questions: [ParsedQuestion], answers: [String?]) -> String {
        zip(questions, answers).map { q, a in
            "Q: \(q.question)\nA: \(a ?? skippedAnswer)"
        }.joined(separator: "\n\n")
    }
}
