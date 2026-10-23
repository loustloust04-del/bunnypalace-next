import Foundation

/// 工具调用预检（《minis对比》A1 / 洞 1，2026-08-25）。
///
/// 病根：`fs_write` 的参数取值 helper 把缺失字段一律降成空串（`d[k] as? String ?? ""`），
/// 模型发一个合法 JSON `{"path":"日记.md"}`（缺 content）→ MP 不报错不拒绝，**直接把已有文件写成空**。
/// JSON 整体解析失败时还会降成空字典继续往下走，同样能清空文件。
///
/// 修法：在**所有 executor 之前**做一次确定性校验，失败作为 `isError` 结果回灌，让模型自己重发。
/// 第一版只做「确定性拒绝」，不做模糊修复（不猜参数、不补默认值）——修复会把模型的错误变成我们的错误。
///
/// 约束来源：内建工具走 `ToolRegistry` 的 `ToolDefinition.required`；MCP 工具走各自 schema 的 `required`。
enum ToolCallPreflight {

    /// 「空串是合法语义」的字段白名单：`fs_edit` 用空 new_string 表示删除命中内容。
    /// 加白名单要有真实语义理由，不是为了让某个模型的坏调用通过。
    private static let emptyStringAllowed: Set<String> = ["new_string"]

    struct Failure {
        let code: String       // missing_param / invalid_json
        let message: String    // 回灌给模型的自愈提示
    }

    /// nil = 通过。非 nil = 拒绝执行，把 message 作为 isError 结果回灌。
    /// - Parameters:
    ///   - name: 工具名
    ///   - argumentsJSON: 模型给的原始参数字符串
    ///   - required: 该工具的必填字段（调用方从注册表/schema 取；nil = 查不到约束，只校验 JSON 合法性）
    static func check(name: String, argumentsJSON: String, required: [String]?) -> Failure? {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)

        // ① JSON 必须能解析成对象。空字符串/"{}" 视为空参数（合法，交给 required 判定）。
        var args: [String: Any] = [:]
        if !trimmed.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
                return Failure(code: "invalid_json",
                               message: "\(name) 的参数不是合法 JSON，未执行。请重新发送一次完整的参数对象。")
            }
            guard let dict = parsed as? [String: Any] else {
                return Failure(code: "invalid_json",
                               message: "\(name) 的参数必须是 JSON 对象（{...}），未执行。")
            }
            args = dict
        }

        // ② required 字段：缺失 / null / 空串（除白名单）一律拒
        guard let required, !required.isEmpty else { return nil }
        let missing = required.filter { key in
            guard let v = args[key], !(v is NSNull) else { return true }
            if let s = v as? String, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return !emptyStringAllowed.contains(key)
            }
            return false
        }
        guard !missing.isEmpty else { return nil }
        return Failure(code: "missing_param",
                       message: "\(name) 缺少必填参数：\(missing.joined(separator: "、"))。未执行——请带上完整参数重新调用（缺参数时不要执行写入类操作）。")
    }

    /// 取某个工具的 required 约束：内建 → 注册表；MCP → server 的 tool schema；查不到 → nil（只校 JSON）。
    @MainActor
    static func requiredFields(for name: String, mcpServerIds: [String]) -> [String]? {
        if let d = ToolRegistry.all.first(where: { $0.definition.name == name })?.definition {
            return d.required
        }
        if let t = MCPProvider.shared.enabledTools(for: mcpServerIds).first(where: { $0.tool.name == name }) {
            let schema = t.tool.schemaAny()
            if let req = schema["required"] as? [String] { return req }
            if let inner = schema["input_schema"] as? [String: Any], let req = inner["required"] as? [String] { return req }
            return []
        }
        return nil
    }
}
