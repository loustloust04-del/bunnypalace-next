#if os(macOS)
import Foundation

/// 编程会话的一条消息 → 聊天页那套渲染器（`MessageSegmentsView`）吃的段序列。
/// 纯函数、无副作用、不碰 SwiftData —— 这是「code 界面跟聊天界面一样」的桥：有了它，
/// 详情页不用自己画正文 / thinking / 工具卡，直接复用聊天页那套（plan-coding-detail-as-chat §2.1）。
///
/// 放在 Views 而不是 Services/CodingSessions：那个目录整个编进随包命令行 `mp-code`（project.yml `targets.mp-code`），
/// 而 `MessageSegment` 是 app 的渲染模型，CLI 没有也用不着。
enum CodingMessageSegments {
    /// 顺序跟换壳前一致：thinking → 正文 → 工具调用。
    ///
    /// 图片**不**进段：`MessageSegmentsView` 的 `.image` 分支是 `EmptyView`（聊天页把图画在气泡外），
    /// 编程会话继续用自己的 `CodingImageStrip`——它带预览和导出。
    static func segments(for message: CodingMessage) -> [MessageSegment] {
        var result: [MessageSegment] = []
        if let thinking = message.thinking, !thinking.isEmpty {
            result.append(.thinking(text: thinking, signature: nil))
        }
        if !message.text.isEmpty {
            result.append(.text(message.text))
        }
        for call in message.toolCalls {
            // use 与 result 必须**紧邻**：合卡靠「下一段是不是同 id 的 toolResult」（MessageSegmentsView 的 items）。
            // 好几家 adapter 的 tool id 是空串（Cursor 恒空），紧邻就能保证配对正确，不依赖 id 唯一（R-CD Q1）
            result.append(.toolUse(id: call.id, name: call.name, inputJSON: call.input ?? "",
                                   integrationName: nil, iconName: nil))
            if let output = call.output, !output.isEmpty {
                result.append(.toolResult(toolUseId: call.id, text: output, isError: call.isError,
                                          integrationName: nil))
            }
        }
        return result
    }

    /// 工具卡折叠行跟在工具名后面那句（`Bash · cd /Users/…`）。她 09-15：「保留折叠，点击展开」——
    /// 折叠着也要能扫出跑了什么，否则一屏十个 Bash 长一个样。
    /// 口径**单源**在 `CodingParse.makePreview`，别在卡片里另挑一份 key 清单（R-CD #3：会漂）
    static func toolSummary(name: String, inputJSON: String) -> String? {
        guard !inputJSON.isEmpty, inputJSON != "{}" else { return nil }
        let parsed = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) ?? inputJSON
        let preview = CodingParse.makePreview(parsed)
        return preview.isEmpty ? nil : preview
    }
}
#endif
