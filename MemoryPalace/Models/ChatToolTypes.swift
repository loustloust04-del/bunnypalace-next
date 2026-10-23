import Foundation

/// 文件库工具循环用的结构化块。只在带工具的对话里出现，纯聊天路径不碰这些类型。

/// 模型本轮发起的一次工具调用。
struct ToolCallBlock {
    let id: String
    let name: String
    /// 原始 JSON 字符串（流式拼接得到）；审批卡上改过命令时换成改过的（粟粟 10-03）
    var argumentsJSON: String
    /// 输出上限截断时最后一个调用写到一半（plan-output-token-cap 2-1）：不执行，回灌说明
    var truncated = false
}

extension Array where Element == ToolCallBlock {
    /// 生成是顺序的，截断只可能落在最后一个调用上
    func markingLastTruncated(_ hit: Bool) -> [ToolCallBlock] {
        guard hit, !isEmpty else { return self }
        var calls = self
        calls[calls.count - 1].truncated = true
        return calls
    }
}

/// app 执行工具后的结果，回灌给模型。
struct ToolResultBlock {
    let toolUseId: String
    let text: String
    let isError: Bool
}

/// 一个工具回合：模型本轮的 tool_use(s) + app 执行后的 result(s)。
/// 按发生顺序追加在原始 messages 之后喂给下一轮请求（保持 use→result 严格配对）。
struct ToolTurn {
    let calls: [ToolCallBlock]
    let results: [ToolResultBlock]
}
