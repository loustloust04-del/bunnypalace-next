import Foundation

/// 工具调用过闸的结果（审批卡，粟粟 10-03）：放行用哪份参数，或者回给模型的拒绝说明
enum ToolGate: Equatable {
    case proceed(String)
    case deny(String)
}

enum PermissionGate {
    /// 一个决定 → 放行 / 拒绝，以及要不要写进对话授权（true 允许 / false 拒绝 / nil 不写）。
    /// 老弹窗的允许 / 拒绝照旧记下；卡上的「允许这一次 / 拒绝 / 改了再允许」只管这一次
    static func outcome(_ decision: PermissionPromptCenter.Decision, domain: PermissionDomain,
                        originalArgs: String) -> (gate: ToolGate, record: Bool?) {
        switch decision {
        case .allowed:
            return (.proceed(originalArgs), true)
        case .allowedOnce:
            return (.proceed(originalArgs), nil)
        case .modified(let json):
            guard (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] != nil else {
                return (.deny("permission_denied：改过的参数不是合法 JSON，本次未执行。"), nil)
            }
            return (.proceed(json), nil)
        case .denied:
            return (.deny("permission_denied：用户本次未允许「\(domain.displayName)」。可以请用户到 设置→权限 调整。"), false)
        case .deniedOnce:
            return (.deny("permission_denied：用户拒绝了这次「\(domain.displayName)」调用，本次未执行。"), nil)
        case .timedOut:
            return (.deny("permission_denied：等待用户确认「\(domain.displayName)」超时，本次未执行。可以稍后再试。"), nil)
        }
    }
}

/// 审批卡上显示什么：跑命令显示完整命令（能改），其余参数一项一项列（长值截断，完整参数另展开）
struct ApprovalPreview {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    static let maxValueLength = 160

    let toolName: String
    let argumentsJSON: String
    /// run_command 的完整命令（不截断）
    let command: String?
    /// 其余参数，按名字排序
    let rows: [Row]

    init(toolName: String, argumentsJSON: String) {
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        let object = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let isCommand = toolName == RunCommandTool.toolName
        command = isCommand ? object["command"] as? String : nil
        rows = object.keys.sorted()
            .filter { !(isCommand && $0 == "command") }
            .map { Row(label: $0, value: Self.short(Self.text(object[$0]))) }
    }

    /// 这次只有跑命令能改（粟粟 10-03）
    var canEditCommand: Bool { command != nil }

    /// 参数排版好的完整 JSON（「完整参数」展开看）
    var prettyJSON: String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return argumentsJSON }
        return text
    }

    static func replacingCommand(in argumentsJSON: String, with command: String) -> String? {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] else { return nil }
        object["command"] = command
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case nil: return ""
        case let v?:
            guard JSONSerialization.isValidJSONObject(v),
                  let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(v)" }
            return String(data: data, encoding: .utf8) ?? "\(v)"
        }
    }

    private static func short(_ s: String) -> String {
        s.count > maxValueLength ? String(s.prefix(maxValueLength)) + "…" : s
    }
}
