import Foundation
import CryptoKit

struct ChatToolStep: Identifiable, Equatable {
    let id: String
    let name: String
    let inputJSON: String
    let result: String?
    let isError: Bool
    let integration: String?
    let icon: String?

    private struct DisplayArguments: Decodable {
        let keyword: String?
        let query: String?
        let path: String?
    }

    var action: String {
        // 只读取明确的非敏感显示字段；命令、密码和任意 MCP 参数不用于模型总结。
        let args = try? JSONDecoder().decode(DisplayArguments.self, from: Data(inputJSON.utf8))
        func value(_ text: String?) -> String {
            guard let text else { return "" }
            return String(text.replacingOccurrences(of: #"\{\{secret:[^}]+\}\}"#, with: "加密值", options: .regularExpression).prefix(80))
        }
        switch name {
        case "fs_search":
            let keyword = value(args?.keyword ?? args?.query)
            return keyword.isEmpty ? "搜索文件库" : "搜索「\(keyword)」"
        case "fs_read":
            let file = (value(args?.path) as NSString).lastPathComponent
            return file.isEmpty ? "读取文件" : "读取「\(file)」"
        case "fs_write": return "写入文件"
        case "fs_append": return "追加文件内容"
        case "fs_edit": return "修改文件"
        case "fs_rename": return "重命名文件"
        case "fs_delete": return "删除文件"
        case "fs_list": return "查看文件目录"
        case "card_guide": return "读取卡片说明"
        case "search_web": return "搜索网页"
        case "browse_url": return "阅读网页"
        case "run_command": return "运行命令"
        default: return integration.flatMap { $0.isEmpty ? nil : $0 } ?? name
        }
    }

    var status: String {
        if isError { return "失败" }
        guard let result else { return "进行中" }
        if name == "fs_search", !result.contains("[已截断") {
            let count = result == "无命中" ? 0 : result.split(whereSeparator: \.isNewline).count
            return "\(count) 条结果"
        }
        return "已完成"
    }

    var summaryAction: String {
        switch name {
        case "fs_search": return "搜索文件库"
        case "fs_read": return "读取文件"
        default: return action
        }
    }
    var symbol: String {
        if isError { return "exclamationmark.circle" }
        if let icon, !icon.isEmpty { return icon }
        switch name {
        case "fs_search", "search_web": return "magnifyingglass"
        case "fs_read", "card_guide": return "doc.text"
        case "fs_write", "fs_append": return "square.and.pencil"
        case "fs_list": return "folder"
        case "run_command": return "terminal"
        case "browse_url": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }
}

enum ChatToolTimeline {
    /// 非紧邻结果挪到自己的调用后；正文、思考等非工具段保持原序，孤儿结果保留。
    static func pairedSegments(_ segments: [MessageSegment]) -> [MessageSegment] {
        let useIDs = Set(segments.compactMap { segment -> String? in
            if case .toolUse(let id, _, _, _, _) = segment { return id }
            return nil
        })
        var results: [String: (index: Int, segment: MessageSegment)] = [:]
        for (index, segment) in segments.enumerated() {
            if case .toolResult(let id, _, _, _) = segment, useIDs.contains(id), results[id] == nil {
                results[id] = (index, segment)
            }
        }
        return segments.enumerated().flatMap { index, segment -> [MessageSegment] in
            if case .toolUse(let id, _, _, _, _) = segment {
                return [segment] + (results[id].map { [$0.segment] } ?? [])
            }
            if case .toolResult(let id, _, _, _) = segment, results[id]?.index == index { return [] }
            return [segment]
        }
    }

    static func fingerprint(_ steps: [ChatToolStep]) -> String {
        let data = (try? JSONEncoder().encode(steps.map { [$0.id, $0.name, $0.inputJSON, $0.result == nil ? "pending" : "complete", $0.result ?? "", String($0.isError)] })) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fallback(_ steps: [ChatToolStep]) -> String {
        let pending = steps.filter { $0.result == nil }.count
        let failures = steps.filter(\.isError).count
        if pending > 0 { return "正在使用工具 · \(steps.count) 个步骤" + (failures > 0 ? " · \(failures) 次失败" : "") }
        var ordered: [(String, Int)] = []
        for step in steps {
            let action = step.summaryAction
            if let index = ordered.firstIndex(where: { $0.0 == action }) { ordered[index].1 += 1 }
            else { ordered.append((action, 1)) }
        }
        let text = ordered.prefix(3).map { $0.0 + ($0.1 > 1 ? " \($0.1) 次" : "") }.joined(separator: "，")
        return text + (ordered.count > 3 ? "等 \(steps.count) 个步骤" : "") + (failures > 0 ? " · \(failures) 次失败" : "")
    }

    static func summaryPrompt(_ steps: [ChatToolStep]) -> String {
        // 不发送用户搜索词、文件路径、命令、原始输入输出或 provider 返回的错误文本。
        var order: [String] = []
        var counts: [String: (total: Int, failures: Int)] = [:]
        for step in steps {
            let action = String(step.summaryAction.prefix(40))
            if counts[action] == nil { order.append(action) }
            let previous = counts[action] ?? (0, 0)
            counts[action] = (previous.total + 1, previous.failures + (step.isError ? 1 : 0))
        }
        let rows = order.prefix(30).map { action in
            let count = counts[action] ?? (0, 0)
            return "\(action) · \(count.total) 次" + (count.failures > 0 ? " · \(count.failures) 次失败" : "")
        }
        let extra = order.count > 30 ? "\n另有 \(order.count - 30) 种工具动作" : ""
        return "共 \(steps.count) 个步骤，\(steps.filter(\.isError).count) 次失败\n" + rows.joined(separator: "\n") + extra
    }
}
