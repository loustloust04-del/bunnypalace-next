import Foundation

/// #089 P0-b：过去回合的工具调用按 API 原生结构回放（替代以前写进 assistant 正文的「〔我在本对话做过的文件操作〕」前缀——
/// 模型照着那个文本格式伪造调用，又分不清真假）。
/// 一个 assistant 节点 = 若干工具回合 + 最后的正文（节点 content，组装层照常处理）。
struct ToolReplayRound {
    /// 这一轮调工具前说的话（可空）
    var text: String
    var calls: [ToolCallBlock]
    var results: [ToolResultBlock]
    /// 这一轮里 ask_user 的回答原文（resume 时同一段 Q/A 另存成一条真实用户消息，回放时去重用）
    var askAnswer: String?
}

enum ToolReplay {
    /// 过去回合的结果只留开头这么多字节（当轮工具循环照旧完整）。规则只看结果本身，回合结束后字节不再变，缓存稳
    static let historyResultCapBytes = 2048
    static let toolOnlyPlaceholder = "（这一轮只调用了工具）"
    static let missingResultText = "（没有执行结果：中途停止）"

    // MARK: - 节点 → 回合

    /// 无工具 → []；有不可回放的调用（空 id / 空名字，导入的老对话）→ nil，整个节点退回纯文字
    static func rounds(from segments: [MessageSegment]?, archivePath: (_ toolUseId: String, _ toolName: String) -> String? = { _, _ in nil })
        -> [ToolReplayRound]? {
        guard let segments else { return [] }
        var rounds: [ToolReplayRound] = []
        var current = ToolReplayRound(text: "", calls: [], results: [])
        var pendingText = ""
        // 按原始 id 配对（清洗后的 id 可能撞车，不能拿它当结果表的键）
        var resultsByOriginal: [String: (text: String, raw: String, isError: Bool)] = [:]
        var originalIds: [String] = []   // 和 current.calls 下标对齐
        var askOriginals: Set<String> = []
        var usedIds: Set<String> = []

        func close() {
            guard !current.calls.isEmpty else { return }
            current.results = zip(current.calls, originalIds).map { call, original in
                resultsByOriginal[original].map { ToolResultBlock(toolUseId: call.id, text: $0.text, isError: $0.isError) }
                    ?? ToolResultBlock(toolUseId: call.id, text: missingResultText, isError: true)
            }
            // ask_user 的回答用没截断的原文去重（Q/A 超 2KB 时截过的永远对不上用户消息全文）
            let answers = originalIds.filter(askOriginals.contains).compactMap { resultsByOriginal[$0] }.filter { !$0.isError }.map(\.raw)
            current.askAnswer = answers.isEmpty ? nil : answers.joined(separator: "\n\n")
            rounds.append(current)
            current = ToolReplayRound(text: "", calls: [], results: [])
            originalIds = []
        }

        for seg in segments {
            switch seg {
            case .text(let t):
                close()
                if !t.isEmpty { pendingText += (pendingText.isEmpty ? "" : "\n\n") + t }
            case .toolUse(let id, let name, let inputJSON, _, _):
                guard var safeId = sanitizedId(id), isValidToolName(name) else { return nil }
                // 清洗后撞了（call:1 / call/1、前 64 位相同）→ 加序号，线上 id 仍唯一
                let base = safeId
                var n = 2
                while usedIds.contains(safeId) {
                    let suffix = "_\(n)"
                    safeId = String(base.prefix(64 - suffix.count)) + suffix
                    n += 1
                }
                usedIds.insert(safeId)
                if current.calls.isEmpty {
                    current.text = pendingText
                    pendingText = ""
                }
                if name == AskUserTool.toolName { askOriginals.insert(id) }
                current.calls.append(ToolCallBlock(id: safeId, name: name, argumentsJSON: inputJSON))
                originalIds.append(id)
            case .toolResult(let useId, let text, let isError, _):
                guard let idx = originalIds.firstIndex(of: useId) else { continue }
                resultsByOriginal[useId] = (historyResultText(text, archivePath: archivePath(useId, current.calls[idx].name)), text, isError)
            default:
                continue
            }
        }
        close()
        return rounds
    }

    /// Anthropic 要求 ^[a-zA-Z0-9_-]+$；别家给的 id 有别的字符就换成 `_`（use 和 result 同一个映射，配对不断）
    static func sanitizedId(_ id: String) -> String? {
        guard !id.isEmpty else { return nil }
        return String(id.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" }.prefix(64))
    }

    static func isValidToolName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// 过去回合的结果：超过 2KB 截开头 + 一句去哪取原文
    static func historyResultText(_ text: String, archivePath: String?) -> String {
        let total = text.utf8.count
        guard total > historyResultCapBytes else { return text }
        var head = ""
        var used = 0
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > historyResultCapBytes { break }
            head.append(ch)
            used += n
        }
        let kb = String(format: "%.1f", Double(total - used) / 1024)
        if let path = ToolResultOffload.embeddedPath(in: text) ?? archivePath {
            return head + "\n…[已省略 \(kb) KB，原结果在 \(path)，需要时用 fs_read 读；读不到就重新调用]"
        }
        return head + "\n…[已省略 \(kb) KB，需要时重新调用]"
    }

    // MARK: - 给副模型看的文字 / 纯文字退路

    /// 一行动作摘要：fs_search("密码")、card_guide
    static func callSummary(_ calls: [ToolCallBlock]) -> String {
        calls.map { call in
            let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
            let target = (args["path"] as? String) ?? (args["keyword"] as? String).map { "\"\($0)\"" } ?? ""
            return target.isEmpty ? call.name : "\(call.name)(\(target))"
        }.joined(separator: "、")
    }

    /// 记忆提取 / 上下文摘要的输入：中性标记，不是第一人称、不像模型自己的输出
    static func sideModelText(content: String, rounds: [ToolReplayRound]) -> String {
        let calls = rounds.flatMap(\.calls)
        guard !calls.isEmpty else { return content }
        let marker = "[调用了 \(callSummary(calls))]"
        return content.isEmpty ? marker : marker + "\n" + content
    }

    static func systemRecord(_ rounds: [ToolReplayRound]) -> String {
        "〔系统记录（客户端自动生成，不是你写的，你不要写这种格式）：上一轮实际调用了 \(callSummary(rounds.flatMap(\.calls)))〕"
    }

    /// 不发工具块的请求（本轮没下发工具 / 不支持的 provider）：assistant 只留正文（空了给占位），
    /// 调用记录挪到下一条用户消息开头的〔系统记录〕
    static func textFallback(_ ordered: [PromptMessage], only: (PromptMessage) -> Bool = { _ in true }) -> [PromptMessage] {
        var result = ordered
        var pendingRecord: String?
        for idx in result.indices {
            if result[idx].role == "assistant", !result[idx].toolRounds.isEmpty, only(result[idx]) {
                pendingRecord = systemRecord(result[idx].toolRounds)
                if result[idx].content.isEmpty { result[idx].content = toolOnlyPlaceholder }
                result[idx].toolRounds = []
            } else if result[idx].role == "user", let record = pendingRecord {
                result[idx].content = record + "\n" + result[idx].content
                pendingRecord = nil
            } else if result[idx].role == "assistant" {
                pendingRecord = nil
            }
        }
        return result
    }

    /// 只有 Anthropic / OpenAI 兼容发真工具块；别家（ChatGPT 登录、本机模型）退纯文字——实发和检查器预览共用这一步
    static func orderedForProvider(_ type: ProviderType?, _ ordered: [PromptMessage]) -> [PromptMessage] {
        guard type != .anthropic, type != .openaiCompatible, ordered.contains(where: { !$0.toolRounds.isEmpty }) else { return ordered }
        return textFallback(ordered)
    }

    // MARK: - 线上

    /// ask_user 的 Q/A 已在 tool_result 里：紧随的用户消息里同一段去掉（整块相同删块；是最新一条时后面贴了写作风格，只去掉开头那段）
    static func strippingAskAnswer(_ chunks: [(text: String, attachments: [PendingChatAttachment])], ask: String)
        -> (chunks: [(text: String, attachments: [PendingChatAttachment])], matched: Bool) {
        var out: [(text: String, attachments: [PendingChatAttachment])] = []
        var matched = false
        for chunk in chunks {
            if !matched, chunk.attachments.isEmpty, chunk.text == ask {
                matched = true
            } else if !matched, chunk.text.hasPrefix(ask + "\n") {
                matched = true
                let rest = String(chunk.text.dropFirst(ask.count + 1))
                if !rest.isEmpty || !chunk.attachments.isEmpty { out.append((rest, chunk.attachments)) }
            } else {
                out.append(chunk)
            }
        }
        return (out, matched)
    }

    /// 线上要发的历史：没下发客户端工具 → 全部退纯文字；某条回复里调过这一轮不在清单里的工具（关了的 MCP、换了平台）
    /// 且包不回 tool_invoke → 只这条退纯文字（API 认不认「历史里有没定义的工具名」没实测，不赌）
    static func wireOrdered(_ ordered: [PromptMessage], toolNames: Set<String>) -> [PromptMessage] {
        guard !toolNames.isEmpty else { return textFallback(ordered) }
        return textFallback(ordered) { message in
            message.toolRounds.contains { round in
                round.calls.contains { !toolNames.contains(wireCall($0, toolNames: toolNames).name) }
            }
        }
    }

    /// 本轮下发的客户端工具名（server tool 如 web_search 不算）
    static func clientToolNames(_ tools: [[String: Any]]?) -> Set<String> {
        Set((tools ?? []).filter { $0["type"] == nil || ($0["type"] as? String) == "function" }.compactMap { tool in
            (tool["name"] as? String) ?? ((tool["function"] as? [String: Any])?["name"] as? String)
        })
    }

    /// 收起的工具当时是经 tool_invoke 调的，节点里存的是内层名字——按当时实际发的包回去
    static func wireCall(_ call: ToolCallBlock, toolNames: Set<String>) -> ToolCallBlock {
        guard !toolNames.contains(call.name), toolNames.contains(MetaTools.invokeName) else { return call }
        return ToolCallBlock(id: call.id, name: MetaTools.invokeName,
                             argumentsJSON: ConversationViewModel.rewrapInvoke(name: call.name, argumentsJSON: call.argumentsJSON))
    }
}
